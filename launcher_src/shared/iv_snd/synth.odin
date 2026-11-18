package iv_snd

import "core:math"

// ---------------------------------------------------------------------------
// The synthesizer: a pool of voices plus CHANNELS channels, and a bus with an effect graph per instrument that has one.
//
// Everything is preallocated, so rendering never allocates. Voices are mono
// (oscillators -> filter -> amplitude envelope) and are panned into a stereo
// pair of buffers when rendered; two "send" buffers collect the parts that go to
// the reverb and to the delay.
// ---------------------------------------------------------------------------

MAX_VOICES :: 256 // sounding notes at once (a new note takes the quietest or oldest fading one when they are all in use)
CHANNELS :: 128 // a song's events name a channel (0..127); a channel plays one instrument at a time
MAX_BUSES :: 64 // instruments of a song whose effect graph can play (by index in Song.instruments; the last is the editor's preview)
PREVIEW_BUS :: MAX_BUSES - 1
CTRL_RATE :: 32 // samples between control updates (filter, pitch, gains)
PLUCK_MAX_GAIN :: 0.9998 // loss per round of a plucked string never goes above this (see pluck_init)
PLUCK_MAX :: 2048 // longest string (in samples) of the Pluck waveform: lowest note about 22 Hz at 44.1 kHz

SINE_SIZE :: 2048
sine_table: [SINE_SIZE + 1]f32
tables_ready: bool

tables_init :: proc() {
	if tables_ready {
		return
	}
	for i in 0 ..= SINE_SIZE {
		sine_table[i] = math.sin_f32(f32(i) / f32(SINE_SIZE) * f32(math.TAU))
	}
	tables_ready = true
}

// Sine of a phase in 0..1 (table lookup with linear interpolation).
sine_lookup :: proc(phase: f32) -> f32 {
	x := phase * f32(SINE_SIZE)
	i := int(x)
	f := x - f32(i)
	i &= SINE_SIZE - 1
	return sine_table[i] + (sine_table[i + 1] - sine_table[i]) * f
}

// ---- envelopes ----------------------------------------------------------------------

Env_Stage :: enum u8 {
	Off,
	Attack,
	Decay,
	Sustain,
	Release,
}

Env_State :: struct {
	stage: Env_Stage,
	level: f32,
}

Env_Rates :: struct {
	attack_inc:   f32,
	decay_coef:   f32,
	sustain:      f32,
	release_coef: f32,
}

// `rate` is how many times per second the envelope is stepped.
env_rates :: proc(e: Env, rate: f32) -> Env_Rates {
	r: Env_Rates
	r.attack_inc = 1 / (max(e.attack, 0.001) * rate)
	r.decay_coef = math.exp_f32(-5 / (max(e.decay, 0.001) * rate))
	r.sustain = clamp(e.sustain, 0, 1)
	r.release_coef = math.exp_f32(-7 / (max(e.release, 0.003) * rate))
	return r
}

env_step :: proc(st: ^Env_State, r: ^Env_Rates) -> f32 {
	switch st.stage {
	case .Off:
		st.level = 0
	case .Attack:
		st.level += r.attack_inc
		if st.level >= 1 {
			st.level = 1
			st.stage = .Decay
		}
	case .Decay:
		st.level = r.sustain + (st.level - r.sustain) * r.decay_coef
		if st.level - r.sustain < 0.0005 {
			st.level = r.sustain
			st.stage = .Sustain
		}
	case .Sustain:
		st.level = r.sustain
	case .Release:
		st.level *= r.release_coef
		if st.level < 0.0003 {
			st.level = 0
			st.stage = .Off
		}
	}
	return st.level
}

env_release :: proc(st: ^Env_State) {
	if st.stage != .Off {
		st.stage = .Release
	}
}

// ---- voices and channels ----------------------------------------------------------

Voice :: struct {
	active:       bool,
	released:     bool, // the key is up (the sound may still be fading)
	held:         bool, // the key is up but the sustain pedal keeps it sounding
	one_shot:     bool, // plays to its end: note-offs are ignored (one-shot zones)
	group:        u8, // choke group (zones): a new note of the group on the channel lets the others go; 0 = none
	zoned:        bool, // the note comes from a zone of an instrument (else it was started with a bare patch)
	zone:         Zone, // that zone (zone.sample == nil: a synthesized note)
	fresh:        bool, // no gain smoothing needed yet
	channel:      u8,
	key:          u8,
	age:          u32,
	patch:        Patch,
	vel:          f32,
	hz:           f32,
	phase:        [2]f32,
	amp:          Env_State,
	amp_r:        Env_Rates,
	fil:          Env_State,
	fil_r:        Env_Rates,
	pitch_env:    f32, // current sweep in semitones
	pitch_coef:   f32, // sweep decay per control block
	vib_phase:    f32,
	vib_age:      f32,
	has_fx:       bool, // the note has effects of its own (note_fx.odin)
	fx:           Note_Fx,
	fx_len:       f32, // length of the note in seconds, which the effects are laid out over
	note_age:     f32, // seconds since the note started
	ic1, ic2:     f32, // filter state
	rng:          u32,
	bus:          i16, // the effect graph the note goes through (index into Synth.buses), -1 = straight to the mix
	gate_left:    i64, // samples until the note releases itself (< 0 = until note off)
	gl, gr, gs, gd: f32, // last gains (left, right, reverb send, delay send)

	// unison, chorus and tremolo
	uphase:       [UNISON_MAX]f32, // phases of the detuned copies of osc 0
	cphase:       [UNISON_MAX]f32, // phases of the slow wobble (chorus) of each copy, spread evenly over one cycle
	trem_phase:   f32,

	// sample playback
	spos:         f64, // position in the sample, in frames
	sample_done:  bool,

	// plucked string (Karplus-Strong): a ring of samples that is filtered every time round
	pl_buf:       [PLUCK_MAX]f32,
	pl_n:         int, // length of the ring
	pl_i:         int,
	pl_g:         f32, // loss per round
	pl_s:         f32, // weight of the older sample in the damping filter
	pl_eta:       f32, // all-pass coefficient (fine tuning of the length)
	pl_prev:      f32,
	pl_apx:       f32,
	pl_apy:       f32,
}

Channel :: struct {
	inst:       ^Instrument, // what the channel plays (nil: the default instrument)
	inst_index: i16, // its index in the song's instruments (its effect graph plays on the bus of that number), -1 = none
	over:       Patch_Overrides, // parameters the song changed (Set_Patch_Param) since the instrument was set
	volume:     f32, // CC 7
	expression: f32, // CC 11
	pan:        f32, // CC 10, -1..1
	mod:        f32, // CC 1, 0..1
	bend:       f32, // -1..1
	bend_range: f32, // semitones
	reverb:     f32, // CC 91, 0..1
	delay:      f32, // CC 94, 0..1 (0 = no delay, the default)
	sustain:    bool, // CC 64
	rpn_msb:    u8,
	rpn_lsb:    u8,

	// Auto-pan (Patch.autopan_*): the sweep belongs to the channel and runs all the time, whether notes
	// are sounding or not; a note just takes the place the sweep is at. It starts at the start of a song.
	ap_phase:   f64, // 0..1 along one sweep (there and back)
	ap_speed:   f32, // sweeps per second the channel's instrument asks for (Hz, 0 = none)
	ap_rate:    f32, // sweeps per second now (set at the start of every synth_render)
}

Synth :: struct {
	sample_rate: f32,
	voices:      [MAX_VOICES]Voice,
	channels:    [CHANNELS]Channel,
	age_counter: u32,

	// Effect graphs (graph.odin): the notes of an instrument with a graph are added up on its bus, the graph
	// processes that, and the result joins the mix. buses[i] belongs to instrument i of the song that plays.
	buses:       [MAX_BUSES]^Fx_Runtime,
	bus_l, bus_r: [MAX_BUSES][BLOCK]f32,

	// Settings of the shared reverb that songs can change (controllers 92 and 93);
	// the audio manager copies them into its reverb.
	reverb_feedback: f32, // room size: 0.7 (small) .. 0.97 (huge)
	reverb_damp:     f32, // high frequency damping: 0 (bright) .. 0.8 (dark)

	// Settings of the shared delay that songs can change (controllers 102 to 106, see
	// the list below); the audio manager copies them into its delay.
	delay_time:      f32, // seconds (used when delay_sync is 0)
	delay_sync:      int, // 0 = use delay_time, 1..DELAY_SYNC_COUNT = a note length at the song's tempo
	delay_feedback:  f32, // 0 .. DELAY_FEEDBACK_MAX
	delay_tone:      f32, // 0 (bright echoes) .. 1 (dark echoes)
	delay_ping_pong: bool, // the echoes bounce between left and right
	tempo_bpm:       f32, // tempo in force (set by the sequencer), for delay_sync
}

// ---- the delay effect ----
//
// A channel sends part of its sound to a shared stereo delay: controller 94 (0..127)
// is the amount, 0 by default, so nothing is delayed unless a song asks for it. The
// settings of the delay itself are shared by all channels (like the reverb's), and
// are set with controllers on any channel:
//
//   CC 94   delay send of this channel (0 = none)
//   CC 102  delay time: 10 ms * value, from 10 ms to 1.27 s  (used when CC 106 is 0)
//   CC 103  feedback: how much of each echo comes back, 0 .. 127 -> 0 .. 0.95
//   CC 104  tone: 0 = bright echoes .. 127 = dark echoes (each repeat gets duller)
//   CC 105  stereo: below 64 the echoes are centred, 64 and up they ping-pong left / right
//   CC 106  tempo sync: 0 = off, else the delay time is a note length at the song's tempo:
//           1 = 1/16, 2 = 1/8 triplet, 3 = 1/8, 4 = dotted 1/8, 5 = 1/4, 6 = dotted 1/4,
//           7 = 1/2, 8 = dotted 1/2, 9 = whole note (4 beats); more than 9 counts as 9
//
// (CC 102 to 119 are unassigned in the MIDI standard; 94 is the "effects 4 depth" send that
// many instruments, and the Roland GS standard, use for a delay.)
CC_DELAY_SEND :: 94
CC_DELAY_TIME :: 102
CC_DELAY_FEEDBACK :: 103
CC_DELAY_TONE :: 104
CC_DELAY_STEREO :: 105
CC_DELAY_SYNC :: 106

// A full send (CC 94 = 127) gives echoes as loud as the dry sound would be panned to the centre.
DELAY_SEND_GAIN :: f32(0.70710678)

DELAY_SYNC_COUNT :: 9
DELAY_SYNC_BEATS := [DELAY_SYNC_COUNT]f32{0.25, 1.0 / 3.0, 0.5, 0.75, 1, 1.5, 2, 3, 4}
DELAY_FEEDBACK_MAX :: f32(0.95)
DELAY_TIME_DEFAULT :: f32(0.38)
DELAY_FEEDBACK_DEFAULT :: f32(0.4)
DELAY_TONE_DEFAULT :: f32(0.35)

// The echo time in seconds for a free time `time` (seconds) and a sync setting `sync` (0 = free,
// 1..DELAY_SYNC_COUNT = a note length at tempo `bpm`).
delay_resolve_seconds :: proc(time: f32, sync: int, bpm: f32) -> f32 {
	t := time
	if sync > 0 {
		beats := DELAY_SYNC_BEATS[clamp(sync, 1, DELAY_SYNC_COUNT) - 1]
		t = beats * f32(60) / max(bpm, f32(1))
	}
	return clamp(t, f32(0.005), DELAY_MAX_SECONDS - f32(0.05))
}

// The delay time in seconds that the settings of `s` ask for right now.
synth_delay_seconds :: proc(s: ^Synth) -> f32 {
	return delay_resolve_seconds(s.delay_time, s.delay_sync, s.tempo_bpm)
}

synth_delay_defaults :: proc(s: ^Synth) {
	s.delay_time = DELAY_TIME_DEFAULT
	s.delay_sync = 0
	s.delay_feedback = DELAY_FEEDBACK_DEFAULT
	s.delay_tone = DELAY_TONE_DEFAULT
	s.delay_ping_pong = false
	s.tempo_bpm = f32(60e6 / f64(DEFAULT_TEMPO_US))
}

REVERB_FEEDBACK_DEFAULT :: f32(0.84)
REVERB_DAMP_DEFAULT :: f32(0.3)

synth_init :: proc(s: ^Synth, sample_rate: f32) {
	tables_init()
	s^ = {}
	s.sample_rate = sample_rate
	synth_reset(s)
}

channel_reset :: proc(c: ^Channel) {
	c^ = {}
	c.volume = 100.0 / 127.0
	c.expression = 1
	c.bend_range = 2
	c.reverb = 0.25
	c.rpn_msb = 127
	c.rpn_lsb = 127
	c.inst_index = -1
	c.inst = default_instrument()
	c.ap_speed = instrument_autopan_speed(c.inst)
}

// Silence everything and put all channels back to their defaults (done whenever a new
// song starts).
synth_reset :: proc(s: ^Synth) {
	for &v in s.voices {
		voice_free(&v)
	}
	for i in 0 ..< CHANNELS {
		channel_reset(&s.channels[i])
	}
	for i in 0 ..< MAX_BUSES {
		fx_runtime_destroy(s.buses[i])
		s.buses[i] = nil
	}
	s.reverb_feedback = REVERB_FEEDBACK_DEFAULT
	s.reverb_damp = REVERB_DAMP_DEFAULT
	synth_delay_defaults(s)
}

synth_active_voices :: proc(s: ^Synth) -> int {
	n := 0
	for &v in s.voices {
		if v.active {
			n += 1
		}
	}
	return n
}

// Starts a voice with an explicit patch on channel `ch`. `gate_secs` > 0 makes the
// note release by itself after that time (used for sound effects).
// `fx` gives the note a vibrato and / or portamento of its own, laid out over `fx_secs` seconds (the length
// of the note, which must be above 0: see note_fx.odin).
// `zone` (a zone of an instrument, see instrument_note; `patch` is then the zone's patch, see zone_patch) says
// whether the note plays a recording, whether it ignores its note-off and which choke group it is in (notes of
// the same group on a channel cut each other off).
synth_voice_start :: proc(s: ^Synth, ch: int, key: int, vel: f32, patch: Patch, zone: ^Zone = nil, gate_secs: f32 = -1, fx: ^Note_Fx = nil, fx_secs: f32 = 0) {
	one_shot := false
	group := 0
	if zone != nil {
		if zone.source == .Sample && zone.sample == nil {
			return // a zone without a recording is silent
		}
		one_shot = zone.one_shot
		group = int(zone.group)
	}

	// Same key again on the same channel: let the old one go.
	for &v in s.voices {
		if v.active && !v.released && int(v.channel) == ch && int(v.key) == key {
			voice_release(&v)
		}
	}

	// Choke group: the earlier notes of the group let go.
	if group > 0 {
		for &v in s.voices {
			if v.active && !v.released && int(v.channel) == ch && int(v.group) == group {
				voice_release(&v)
			}
		}
	}

	// Find a free voice, or steal one: prefer fading voices, then the oldest.
	idx := -1
	for i in 0 ..< MAX_VOICES {
		if !s.voices[i].active {
			idx = i
			break
		}
	}
	if idx < 0 {
		best: f32 = 1e9
		for i in 0 ..< MAX_VOICES {
			v := &s.voices[i]
			score: f32
			if v.released {
				score = v.amp.level
			} else {
				score = 2 + f32(v.age) * 1e-7
			}
			if score < best {
				best = score
				idx = i
			}
		}
	}

	v := &s.voices[idx]
	voice_free(v)
	v^ = {}
	v.active = true
	v.fresh = true
	v.channel = u8(ch)
	v.bus = -1
	if bi := int(s.channels[ch].inst_index); bi >= 0 && bi < MAX_BUSES && s.buses[bi] != nil {
		v.bus = i16(bi) // the instrument has an effect graph
	}
	v.key = u8(key)
	v.one_shot = one_shot
	v.group = u8(group)
	s.age_counter += 1
	v.age = s.age_counter
	v.patch = patch
	if zone != nil {
		v.zone = zone^
		v.zoned = true
	}
	sample_retain(v.zone.sample)
	v.vel = clamp(vel, 0, 1)
	if patch.fixed_hz > 0 {
		v.hz = patch.fixed_hz
	} else {
		v.hz = key_to_hz(f32(key))
	}
	rate := s.sample_rate
	v.amp_r = env_rates(patch.amp_env, rate)
	v.fil_r = env_rates(patch.filter_env, rate / f32(CTRL_RATE))
	v.amp = {.Attack, 0}
	v.fil = {.Attack, 0}
	v.pitch_env = patch.pitch_env_semitones
	v.pitch_coef = math.exp_f32(-f32(CTRL_RATE) / (max(patch.pitch_env_time, 0.001) * rate))
	v.rng = 0x9e3779b9 + u32(s.age_counter) * 0x85ebca6b
	if v.rng == 0 {
		v.rng = 1
	}
	v.gate_left = -1
	if gate_secs > 0 {
		v.gate_left = i64(gate_secs * rate)
	}
	if fx != nil && fx_secs > 0 && note_fx_active(fx) {
		v.has_fx = true
		v.fx = fx^
		v.fx_len = fx_secs
	}
	if patch.unison > 1 {
		for j in 1 ..< UNISON_MAX { // spread the starting phases so the copies do not add up in step
			x := v.rng
			x ~= x << 13
			x ~= x >> 17
			x ~= x << 5
			v.rng = x
			v.uphase[j] = f32(x >> 8) * (1.0 / 16777216.0)
		}
	}
	// The wobbles of the copies are a whole cycle apart in equal steps (3 copies: 120 degrees).
	// Then their sum keeps an even loudness, which is what makes a chorus sound smooth instead of pulsing.
	for j in 0 ..< UNISON_MAX {
		v.cphase[j] = f32(j) / f32(max(patch.unison, 1))
		v.cphase[j] -= math.floor_f32(v.cphase[j])
	}
	if patch.osc[0].wave == .Pluck && v.zone.sample == nil {
		pluck_init(v, rate)
	}
}

// Fills the string of a Pluck voice: noise, softened more or less depending on how
// hard the note is played, and works out the length and loss of the ring.
pluck_init :: proc(v: ^Voice, sr: f32) {
	p := &v.patch
	hz := max(v.hz, 20)
	bright := clamp(p.string_bright * (0.55 + 0.45 * v.vel), 0, 1)
	sw := 0.5 - 0.42 * bright // damping filter: y = (1 - sw) * x + sw * (x one round older)
	d := sr / hz // length of the ring that gives this pitch
	n := int(math.floor_f32(d - sw - 0.5))
	n = clamp(n, 2, PLUCK_MAX - 1)
	frac := clamp(d - sw - f32(n), 0.1, 1.9) // what the all-pass has to add
	v.pl_n = n
	v.pl_i = 0
	v.pl_s = sw
	v.pl_eta = (1 - frac) / (1 + frac)
	// Loss per round for the wanted decay time of the fundamental: the damping filter already
	// takes some of it, so only the rest is added.
	w := f32(math.TAU) * hz / sr
	mag := math.sqrt_f32(max((1 - sw) * (1 - sw) + sw * sw + 2 * sw * (1 - sw) * math.cos_f32(w), 0.01))
	// The damping filter loses less than the wanted decay at the fundamental only when the note is
	// low: for a high note (or a long ring) the correction `mag` pushes the gain above 1 for the
	// slow, low frequency components, which then grow every round until the string explodes. A
	// string must never gain energy, so the loss is kept just under 1 (it only matters where the
	// wanted decay cannot be reached anyway; every stable note is untouched).
	v.pl_g = min(math.exp_f32(-6.9078 / (max(p.string_decay, 0.05) * hz)) / mag, PLUCK_MAX_GAIN)

	// The first round: white noise, low-passed (brighter notes get less of it), no DC, fixed loudness.
	a := 0.1 + 0.9 * bright * bright
	y: f32 = 0
	mean: f32 = 0
	for i in 0 ..< n {
		x := v.rng
		x ~= x << 13
		x ~= x >> 17
		x ~= x << 5
		v.rng = x
		wn := f32(i32(x)) * (1.0 / 2147483648.0)
		y += a * (wn - y)
		v.pl_buf[i] = y
		mean += y
	}
	mean /= f32(n)
	energy: f32 = 0
	for i in 0 ..< n {
		v.pl_buf[i] -= mean
		energy += v.pl_buf[i] * v.pl_buf[i]
	}
	rms := math.sqrt_f32(energy / f32(n))
	k: f32 = 0.5 / max(rms, 1e-6)
	for i in 0 ..< n {
		v.pl_buf[i] *= k
	}
}

// One sample of the plucked string.
pluck_tick :: proc(v: ^Voice) -> f32 {
	cur := v.pl_buf[v.pl_i]
	lp := ((1 - v.pl_s) * cur + v.pl_s * v.pl_prev) * v.pl_g
	v.pl_prev = cur
	ap := v.pl_eta * lp + v.pl_apx - v.pl_eta * v.pl_apy
	v.pl_apx = lp
	v.pl_apy = ap
	v.pl_buf[v.pl_i] = ap
	v.pl_i += 1
	if v.pl_i >= v.pl_n {
		v.pl_i = 0
	}
	return cur
}

// Ends a voice. A voice that plays a sample holds a share of it (taken when the note
// starts), so the recording stays valid until the last note using it has died away,
// even if the song or editor that owned it is closed in the meantime.
voice_free :: proc(v: ^Voice) {
	if v.active && v.zone.sample != nil {
		sample_release(v.zone.sample)
	}
	v.active = false
}

voice_release :: proc(v: ^Voice) {
	v.released = true
	v.held = false
	env_release(&v.amp)
	env_release(&v.fil)
}

// ---- MIDI-style control -----------------------------------------------------------

synth_note_on :: proc(s: ^Synth, ch: int, key: int, vel: int) {
	synth_note_on_fx(s, ch, key, vel, nil, 0)
}

// A note with a vibrato and / or portamento of its own (`fx`, see note_fx.odin) over `length_secs`
// seconds: how long the note will be held (its effects follow that, not the sound).
synth_note_on_fx :: proc(s: ^Synth, ch: int, key: int, vel: int, fx: ^Note_Fx, length_secs: f32) {
	if ch < 0 || ch >= CHANNELS || key < 0 || key > 127 {
		return
	}
	c := &s.channels[ch]
	v := f32(clamp(vel, 1, 127)) / 127
	_, zone, ok := instrument_note(c.inst, key)
	if !ok {
		return // no zone plays the key
	}
	patch := zone_patch(zone, &c.over) // (Set_Patch_Param may have changed the patch)
	synth_voice_start(s, ch, key, v, patch, zone, -1, fx, length_secs)
}

synth_note_off :: proc(s: ^Synth, ch: int, key: int) {
	if ch < 0 || ch >= CHANNELS {
		return
	}
	c := &s.channels[ch]
	for &v in s.voices {
		if v.active && !v.released && int(v.channel) == ch && int(v.key) == key {
			if v.one_shot {
				continue // one-shot zones play out
			}
			if c.sustain {
				v.held = true
			} else {
				voice_release(&v)
			}
		}
	}
}

// The channel plays `inst` from now on (notes that are sounding go on with the one they started with).
// nil: the default instrument. `index` is the instrument's number in the song that plays (-1 = not one of a
// song's): the effect graph of that instrument, if it has one, processes the notes of the channel.
synth_set_instrument :: proc(s: ^Synth, ch: int, inst: ^Instrument, index := -1) {
	if ch < 0 || ch >= CHANNELS {
		return
	}
	c := &s.channels[ch]
	c.inst = inst if inst != nil else default_instrument()
	c.inst_index = i16(index) if inst != nil && index >= 0 && index < PREVIEW_BUS else -1
	c.over = {}
	c.ap_speed = instrument_autopan_speed(c.inst)
}

// Puts every channel back on the default instrument. Done before a song is swapped for another, since
// the channels point into the instruments of the song that goes away.
synth_forget_instruments :: proc(s: ^Synth) {
	for ch in 0 ..< CHANNELS {
		synth_set_instrument(s, ch, nil)
	}
}

synth_bend :: proc(s: ^Synth, ch: int, value: int) {
	if ch < 0 || ch >= CHANNELS {
		return
	}
	s.channels[ch].bend = clamp(f32(value) / 8192, -1, 1)
}

synth_control :: proc(s: ^Synth, ch: int, cc: int, value: int) {
	if ch < 0 || ch >= CHANNELS {
		return
	}
	c := &s.channels[ch]
	val := clamp(value, 0, 127)
	f := f32(val) / 127
	switch cc {
	case 1:
		c.mod = f
	case 6:
		if c.rpn_msb == 0 && c.rpn_lsb == 0 {
			c.bend_range = f32(val)
		}
	case 7:
		c.volume = f
	case 10:
		c.pan = clamp((f32(val) - 64) / 63, -1, 1)
	case 11:
		c.expression = f
	case 64:
		down := val >= 64
		c.sustain = down
		if !down {
			for &v in s.voices {
				if v.active && v.held && int(v.channel) == ch {
					voice_release(&v)
				}
			}
		}
	case 91:
		c.reverb = f
	case 92: // reverb size (global, whatever the channel): 0 = small room .. 127 = huge hall
		s.reverb_feedback = 0.70 + 0.27 * f
	case 93: // reverb damping (global): 0 = bright .. 127 = dark
		s.reverb_damp = 0.8 * f
	case CC_DELAY_SEND:
		c.delay = f
	case CC_DELAY_TIME: // global, whatever the channel
		s.delay_time = 0.01 * f32(max(val, 1))
	case CC_DELAY_FEEDBACK:
		s.delay_feedback = DELAY_FEEDBACK_MAX * f
	case CC_DELAY_TONE:
		s.delay_tone = f
	case CC_DELAY_STEREO:
		s.delay_ping_pong = val >= 64
	case CC_DELAY_SYNC:
		s.delay_sync = min(val, DELAY_SYNC_COUNT)
	case 100:
		c.rpn_lsb = u8(val)
	case 101:
		c.rpn_msb = u8(val)
	case 120:
		synth_channel_off(s, ch, true)
	case 121:
		c.expression = 1
		c.mod = 0
		c.bend = 0
		c.sustain = false
	case 123:
		synth_channel_off(s, ch, false)
	}
}

// Change one patch parameter of a channel (new notes and the ones sounding now).
synth_set_param :: proc(s: ^Synth, ch: int, param: Patch_Param, value: f32) {
	if ch < 0 || ch >= CHANNELS {
		return
	}
	c := &s.channels[ch]
	c.over.set += {param}
	c.over.val[param] = value
	if param == .Autopan_Speed {
		c.ap_speed = max(value, 0)
	}
	for &v in s.voices {
		if v.active && int(v.channel) == ch {
			voice_set_param(&v, param, value)
		}
	}
}

// Changes one parameter of a sounding note. A note that comes from a zone keeps the zone's tuning, loudness
// and pan on top of the new value.
voice_set_param :: proc(v: ^Voice, param: Patch_Param, value: f32) {
	patch_set_param(&v.patch, param, value)
	if !v.zoned {
		return
	}
	z := &v.zone
	#partial switch param {
	case .Volume:
		v.patch.volume = v.patch.volume * z.volume * z.gain
	case .Pan:
		v.patch.pan = clamp(v.patch.pan + z.pan, -1, 1)
	case .Osc1_Semitones:
		v.patch.osc[1].semitones += z.tune
	}
}

// Release (or, with `immediate`, cut) every note of a channel.
synth_channel_off :: proc(s: ^Synth, ch: int, immediate: bool) {
	for &v in s.voices {
		if v.active && int(v.channel) == ch {
			if immediate {
				voice_free(&v)
			} else {
				voice_release(&v)
			}
		}
	}
}

synth_all_off :: proc(s: ^Synth, immediate: bool) {
	for ch in 0 ..< CHANNELS {
		synth_channel_off(s, ch, immediate)
		s.channels[ch].sustain = false
	}
}

// ---- rendering ---------------------------------------------------------------------

poly_blep :: proc(t, dt: f32) -> f32 {
	if t < dt {
		x := t / dt
		return x + x - x * x - 1
	} else if t > 1 - dt {
		x := (t - 1) / dt
		return x * x + x + x + 1
	}
	return 0
}

// A soft saturation (a rational approximation of tanh, exactly +-1 from +-3 on): small signals pass almost
// unchanged, loud ones are rounded off towards +-1. Used by the overdrive (Patch.drive).
drive_shape :: #force_inline proc(x: f32) -> f32 {
	if x >= 3 {
		return 1
	}
	if x <= -3 {
		return -1
	}
	x2 := x * x
	return x * (27 + x2) / (27 + 9 * x2)
}

// One sample of a waveform at `phase` (0..1) with phase increment `dt`.
osc_sample :: proc(o: ^Osc, phase, dt: f32, rng: ^u32) -> f32 {
	switch o.wave {
	case .Sine:
		return sine_lookup(phase)
	case .Triangle:
		return 4 * abs(phase - 0.5) - 1
	case .Saw:
		return 2 * phase - 1 - poly_blep(phase, dt)
	case .Square:
		pw := clamp(o.pulse, 0.05, 0.95)
		v: f32 = 1 if phase < pw else -1
		v += poly_blep(phase, dt)
		t2 := phase - pw
		if t2 < 0 {
			t2 += 1
		}
		v -= poly_blep(t2, dt)
		return v
	case .Noise:
		x := rng^
		x ~= x << 13
		x ~= x >> 17
		x ~= x << 5
		rng^ = x
		return f32(i32(x)) * (1.0 / 2147483648.0)
	case .Pluck:
		return 0 // handled by the voice (it needs a string of its own), and only for osc 0
	}
	return 0
}

// Adds `n` samples (n <= CTRL_RATE) of one voice to the output buffers.
voice_render_block :: proc(s: ^Synth, v: ^Voice, l, r, send, dsend: []f32, off, n: int) {
	ch := &s.channels[v.channel]
	p := &v.patch
	sr := s.sample_rate
	inv_sr := 1 / sr

	// -- control rate values --
	vib := p.vibrato_depth + ch.mod * 0.5
	vib_amt: f32 = 0
	if vib > 0 {
		ramp: f32 = 1
		if p.vibrato_delay > 0 {
			ramp = clamp(v.vib_age / p.vibrato_delay, 0, 1)
		}
		vib_amt = vib * ramp * sine_lookup(v.vib_phase)
	}
	fx_semis: f32 = 0
	if v.has_fx { // the vibrato and portamento of the note itself, taken in the middle of this block
		fx_semis = note_fx_semitones(&v.fx, v.note_age + 0.5 * f32(n) * inv_sr, v.fx_len)
	}
	semis := v.pitch_env + ch.bend * ch.bend_range + vib_amt + fx_semis
	ratio := math.pow_f32(f32(2), semis / 12)

	smp := v.zone.sample
	wave0 := p.osc[0].wave
	use_fm := p.fm > 0 && smp == nil && wave0 != .Pluck

	// Detuned copies of osc 0 (unison), and the slow wobble of the detune (chorus).
	unison_n := 1
	if p.unison > 1 && smp == nil && wave0 != .Pluck && !use_fm {
		unison_n = min(int(p.unison), UNISON_MAX)
	}
	chorus_on := p.chorus_depth > 0
	// The chorus depth is the size of the wobble in cycles of the note's own wave, so the
	// wobble in semitones gets smaller as the note gets higher (a wobble of fixed size in
	// semitones would run high notes through many whole cycles and make them pulse).
	chorus_depth := min(p.chorus_depth * 108.77 * p.chorus_rate / max(v.hz, 8), 0.5)
	uinc: [UNISON_MAX]f32
	inc: [2]f32
	for i in 0 ..< 2 {
		st := p.osc[i].semitones
		if i == 1 && unison_n == 1 && chorus_on {
			st += chorus_depth * sine_lookup(v.cphase[0])
		}
		f := v.hz * ratio * math.pow_f32(f32(2), st / 12)
		inc[i] = clamp(f * inv_sr, 0, 0.45)
	}
	if unison_n > 1 {
		// The copies are not spread evenly (that would make them beat in a regular pulse):
		// their detunes follow the golden ratio, centred on the pitch of the note.
		offs: [UNISON_MAX]f32
		mean: f32 = 0
		for j in 0 ..< unison_n {
			u := f32(j) * 0.618034 + 0.1
			u -= math.floor_f32(u)
			offs[j] = u * 2 - 1
			mean += offs[j]
		}
		mean /= f32(unison_n)
		biggest: f32 = 0.001
		for j in 0 ..< unison_n {
			offs[j] -= mean
			biggest = max(biggest, abs(offs[j]))
		}
		for j in 0 ..< unison_n {
			det := offs[j] / biggest * p.unison_detune
			if chorus_on {
				det += chorus_depth * sine_lookup(v.cphase[j])
			}
			f := v.hz * ratio * math.pow_f32(f32(2), (p.osc[0].semitones + det) / 12)
			uinc[j] = clamp(f * inv_sr, 0, 0.45)
		}
	}

	// Sample playback speed: frames of the recording per output sample.
	sstep: f64 = 0
	if smp != nil {
		st := semis + p.osc[0].semitones
		if v.zone.pitched {
			st += f32(v.key) - (v.zone.root_key if v.zone.has_root else 60)
		}
		sstep = f64(smp.rate) / f64(sr) * f64(math.pow_f32(f32(2), st / 12))
	}

	fenv := env_step(&v.fil, &v.fil_r)

	// Filter coefficients.
	filter_on := p.filter.mode != .Off
	a1, a2, a3, k: f32
	if filter_on {
		oct := p.filter.env_amount * fenv + p.filter.key_track * (f32(v.key) - 60) / 12
		fc := p.filter.cutoff * math.pow_f32(f32(2), oct)
		fc = clamp(fc, 20, sr * 0.45)
		g := math.tan_f32(f32(math.PI) * fc / sr)
		res := clamp(p.filter.resonance, 0, 1)
		q := 0.6 + res * res * 14
		k = 1 / q
		a1 = 1 / (1 + g * (g + k))
		a2 = g * a1
		a3 = g * a2
	}

	fm_index := p.fm * fenv

	// Gains.
	vel_gain := (1 - p.velocity_sens) + p.velocity_sens * v.vel
	loud := ch.volume * ch.volume * ch.expression * ch.expression * p.volume * vel_gain
	if p.tremolo_depth > 0 {
		loud *= 1 - p.tremolo_depth * (0.5 + 0.5 * sine_lookup(v.trem_phase))
	}
	pan := clamp(ch.pan + p.pan, -1, 1)
	if p.autopan_speed > 0 {
		// The place the sweep is at in the middle of this block: it starts at autopan_range[0], reaches
		// autopan_range[1] half way round and is back after a whole round. It replaces the channel's
		// and the instrument's pan.
		ph := ch.ap_phase + f64(ch.ap_rate * (f32(off) + 0.5 * f32(n)) * inv_sr) - 0.25
		ph -= math.floor_f64(ph)
		sweep := 0.5 + 0.5 * sine_lookup(f32(ph)) // 0 at the start of a sweep, 1 half way
		pan = clamp(p.autopan_range[0] + (p.autopan_range[1] - p.autopan_range[0]) * sweep, -1, 1)
	}
	ang := (pan + 1) * f32(math.PI) * 0.25
	gl1 := loud * math.cos_f32(ang)
	gr1 := loud * math.sin_f32(ang)
	gs1 := loud * ch.reverb
	gd1 := loud * ch.delay * DELAY_SEND_GAIN
	if v.fresh {
		v.gl, v.gr, v.gs, v.gd = gl1, gr1, gs1, gd1
		v.fresh = false
	}
	use_delay := gd1 != 0 || v.gd != 0 // most voices have no delay: leave the buffer alone then
	dgl := (gl1 - v.gl) / f32(n)
	dgr := (gr1 - v.gr) / f32(n)
	dgs := (gs1 - v.gs) / f32(n)
	dgd := (gd1 - v.gd) / f32(n)

	// -- per sample --
	lvl0 := p.osc[0].level
	lvl1 := p.osc[1].level
	unison_norm: f32 = 1
	if unison_n > 1 {
		unison_norm = 1 / math.sqrt_f32(f32(unison_n))
	}
	// Overdrive: the gain grows with the square of `drive`, so the low settings stay gentle; the output is
	// scaled so that a full-scale wave stays at full scale.
	drive_on := p.drive > 0
	drive_gain := 1 + 40 * p.drive * p.drive
	drive_norm := 1 / drive_shape(drive_gain)
	for i in 0 ..< n {
		a := env_step(&v.amp, &v.amp_r)

		x: f32
		switch {
		case smp != nil:
			if !v.sample_done {
				x = sample_read(smp, v.spos) * lvl0
				v.spos += sstep
				if v.zone.loop_on && v.zone.loop_end > v.zone.loop_start {
					for v.spos >= f64(v.zone.loop_end) {
						v.spos -= f64(v.zone.loop_end - v.zone.loop_start)
					}
				} else if v.spos >= f64(len(smp.data) - 1) {
					v.sample_done = true
				}
			}
			if lvl1 > 0 {
				x += osc_sample(&p.osc[1], v.phase[1], inc[1], &v.rng) * lvl1
			}
		case wave0 == .Pluck:
			x = pluck_tick(v) * lvl0
			if lvl1 > 0 {
				x += osc_sample(&p.osc[1], v.phase[1], inc[1], &v.rng) * lvl1
			}
		case use_fm:
			m := sine_lookup(v.phase[1])
			ph := v.phase[0] + fm_index * m * f32(1.0 / math.TAU)
			ph -= math.floor_f32(ph)
			x = osc_sample(&p.osc[0], ph, inc[0], &v.rng) * lvl0
		case unison_n > 1:
			sum: f32 = 0
			for j in 0 ..< unison_n {
				sum += osc_sample(&p.osc[0], v.uphase[j], uinc[j], &v.rng)
				v.uphase[j] += uinc[j]
				if v.uphase[j] >= 1 {
					v.uphase[j] -= 1
				}
			}
			x = sum * lvl0 * unison_norm
			if lvl1 > 0 {
				x += osc_sample(&p.osc[1], v.phase[1], inc[1], &v.rng) * lvl1
			}
		case:
			x = osc_sample(&p.osc[0], v.phase[0], inc[0], &v.rng) * lvl0
			if lvl1 > 0 {
				x += osc_sample(&p.osc[1], v.phase[1], inc[1], &v.rng) * lvl1
			}
		}
		v.phase[0] += inc[0]
		if v.phase[0] >= 1 {
			v.phase[0] -= 1
		}
		v.phase[1] += inc[1]
		if v.phase[1] >= 1 {
			v.phase[1] -= 1
		}

		if drive_on {
			x = drive_shape(x * drive_gain) * drive_norm // overdrive (before the filter, as an amp before its speaker)
		}

		if filter_on {
			v3 := x - v.ic2
			v1 := a1 * v.ic1 + a2 * v3
			v2 := v.ic2 + a2 * v.ic1 + a3 * v3
			v.ic1 = 2 * v1 - v.ic1
			v.ic2 = 2 * v2 - v.ic2
			switch p.filter.mode {
			case .Low_Pass:
				x = v2
			case .Band_Pass:
				x = v1
			case .High_Pass:
				x = x - k * v1 - v2
			case .Off:
			}
		}

		y := x * a
		v.gl += dgl
		v.gr += dgr
		v.gs += dgs
		l[off + i] += y * v.gl
		r[off + i] += y * v.gr
		send[off + i] += y * v.gs
		if use_delay {
			v.gd += dgd
			dsend[off + i] += y * v.gd
		}
	}
	if !use_delay {
		v.gd = gd1
	}

	// -- housekeeping --
	v.pitch_env *= v.pitch_coef
	v.vib_phase += p.vibrato_rate * f32(n) * inv_sr
	v.vib_phase -= math.floor_f32(v.vib_phase)
	v.vib_age += f32(n) * inv_sr
	v.note_age += f32(n) * inv_sr
	if chorus_on {
		for j in 0 ..< UNISON_MAX {
			v.cphase[j] += p.chorus_rate * f32(n) * inv_sr
			v.cphase[j] -= math.floor_f32(v.cphase[j])
		}
	}
	if p.tremolo_depth > 0 {
		v.trem_phase += p.tremolo_rate * f32(n) * inv_sr
		v.trem_phase -= math.floor_f32(v.trem_phase)
	}
	if v.gate_left >= 0 {
		v.gate_left -= i64(n)
		if v.gate_left < 0 {
			voice_release(v)
		}
	}
	if v.amp.stage == .Off || (v.amp.stage == .Sustain && v.amp_r.sustain <= 0.0005) || v.sample_done {
		voice_free(v)
	}
}

// Adds `n` samples of every sounding voice to `l`, `r`, the reverb `send` and the delay
// send `dsend` (they are not cleared here).
synth_render :: proc(s: ^Synth, l, r, send, dsend: []f32, n: int) {
	// Auto-pan: the speed of every channel's sweep for this stretch: that of the channel's instrument,
	// or else (an instrument that was changed while its notes still sound, or a sound effect that
	// brings its own instrument) that of a sounding note.
	for &c in s.channels {
		c.ap_rate = c.ap_speed
	}
	for &v in s.voices {
		if v.active && s.channels[v.channel].ap_rate <= 0 && v.patch.autopan_speed > 0 {
			s.channels[v.channel].ap_rate = v.patch.autopan_speed
		}
	}
	defer for &c in s.channels { // the sweeps go on, with notes or without
		if c.ap_rate > 0 {
			c.ap_phase += f64(c.ap_rate) * f64(n) / f64(s.sample_rate)
			c.ap_phase -= math.floor_f64(c.ap_phase)
		}
	}
	nb := min(n, BLOCK)
	for b in 0 ..< MAX_BUSES { // the buses of the instruments that have an effect graph start empty
		if s.buses[b] != nil {
			for i in 0 ..< nb {
				s.bus_l[b][i] = 0
				s.bus_r[b][i] = 0
			}
		}
	}
	for &v in s.voices {
		if !v.active {
			continue
		}
		dl, dr := l, r
		if v.bus >= 0 && s.buses[v.bus] != nil {
			dl, dr = s.bus_l[v.bus][:], s.bus_r[v.bus][:]
		}
		off := 0
		for off < n && v.active {
			cnt := min(CTRL_RATE, n - off)
			voice_render_block(s, &v, dl, dr, send, dsend, off, cnt)
			off += cnt
		}
	}
	// The effect graphs: what the notes of an instrument made goes through its graph and joins the mix.
	for b in 0 ..< MAX_BUSES {
		if rt := s.buses[b]; rt != nil {
			fx_runtime_process(rt, s.bus_l[b][:nb], s.bus_r[b][:nb], l, r, nb, s.tempo_bpm)
		}
	}
}

// Gives the effect graphs of the song's instruments to the buses (graph.odin): bus i processes the notes of
// instrument i through the graph that instrument names (Instrument.graph, a number in Song.graphs; instruments that
// name the same graph each get a bus, and so each their own state). A bus whose graph is only edited keeps its state, so echoes and reverb tails go on; one whose
// instrument has no graph any more (or no longer exists) is dropped. Call it whenever a song starts or is
// replaced, from the thread that owns the synth (it allocates).
synth_graphs_sync :: proc(s: ^Synth, song: ^Song) {
	for b in 0 ..< PREVIEW_BUS {
		var_g: ^Fx_Graph = nil
		if song != nil && b < len(song.instruments) {
			if g := fx_library_get(song.graphs[:], song.instruments[b].graph); g != nil && !fx_is_trivial(g) {
				var_g = g
			}
		}
		switch {
		case var_g == nil:
			fx_runtime_destroy(s.buses[b])
			s.buses[b] = nil
		case s.buses[b] == nil:
			s.buses[b] = fx_runtime_new(var_g, s.sample_rate)
		case:
			fx_runtime_set(s.buses[b], var_g)
		}
	}
}
