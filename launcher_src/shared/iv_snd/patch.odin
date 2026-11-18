package iv_snd

import "core:math"

// ---------------------------------------------------------------------------
// Instrument patches.
//
// A patch describes one synthesized sound: two oscillators (or a two operator FM
// pair), an amplitude envelope, a filter with its own envelope, a pitch sweep and a
// vibrato. A patch is not an instrument by itself: an Instrument (instrument.odin)
// is a list of zones, and every zone has a patch. A zone that plays a synthesizer sound
// uses all of it; a zone that plays a recording uses the envelope, the filter, the
// loudness and the pan to shape it.
// ---------------------------------------------------------------------------

Waveform :: enum u8 {
	Sine,
	Triangle,
	Saw,
	Square, // pulse wave, width set by Osc.pulse
	Noise,
	Pluck, // a plucked string (Karplus-Strong): only for osc[0]; see Patch.string_decay / string_bright
}

Osc :: struct {
	wave:      Waveform,
	level:     f32, // 0..1 mix level
	semitones: f32, // tuning offset in semitones (12 = an octave up, 0.1 = slightly sharp)
	pulse:     f32, // pulse width of Square, 0.05..0.95 (0.5 = square)
}

// Attack / decay / release are times in seconds, sustain is a level 0..1.
// A patch whose amp envelope has sustain 0 dies away by itself (percussive).
Env :: struct {
	attack, decay, sustain, release: f32,
}

Filter_Mode :: enum u8 {
	Off,
	Low_Pass,
	High_Pass,
	Band_Pass,
}

Filter :: struct {
	mode:       Filter_Mode,
	cutoff:     f32, // Hz (before the envelope and key tracking)
	resonance:  f32, // 0..1
	env_amount: f32, // octaves the filter envelope adds at its peak (may be negative)
	key_track:  f32, // 0..1: how much the cutoff follows the pitch of the note (around middle C)
}

Patch :: struct {
	osc:                 [2]Osc,
	fm:                  f32, // > 0: osc[1] phase-modulates osc[0] (and is not heard itself); the index is scaled by filter_env
	amp_env:             Env,
	filter_env:          Env,
	filter:              Filter,
	pitch_env_semitones: f32, // pitch sweep at the start of a note (decays to 0)
	pitch_env_time:      f32, // seconds the sweep takes to settle
	vibrato_rate:        f32, // Hz
	vibrato_depth:       f32, // semitones
	vibrato_delay:       f32, // seconds before the vibrato fades in
	fixed_hz:            f32, // > 0: ignore the note's pitch and play this frequency (drums)
	volume:              f32, // patch loudness
	pan:                 f32, // -1 (left) .. 1 (right), added to the channel pan
	velocity_sens:       f32, // 0..1: how much the note velocity changes the loudness

	// -- added with the instrument library (older songs get the defaults of patch_base) --
	unison:              i32, // copies of osc[0] played together, slightly detuned (0 or 1 = just one, up to UNISON_MAX)
	unison_detune:       f32, // semitones: the copies are spread over +- this much (0.12 = 12 cents)
	chorus_depth:        f32, // a slow wobble of the pitch of the copies (or of osc[1] when there is no unison), measured as how many cycles of the note's wave it moves the phase: 0.2 is a gentle ensemble, above 0.4 it turns hollow; the copies wobble a third of a cycle apart
	chorus_rate:         f32, // Hz
	tremolo_depth:       f32, // 0..1: the loudness wobbles by this much
	tremolo_rate:        f32, // Hz
	string_decay:        f32, // Pluck waveform: seconds the string takes to die away (60 dB)
	string_bright:       f32, // Pluck waveform: 0 (soft, dull) .. 1 (hard, bright)

	// -- auto-pan --
	autopan_range:       [2]f32, // the two places the sound sweeps between, each -1 (left) .. 1 (right): [0] at the start of a sweep, [1] half way through
	autopan_speed:       f32, // sweeps (there and back) per second, Hz; 0 = off. The sweep is not tied to the notes, see Channel.ap_phase

	// -- drive --
	drive:               f32, // 0 = clean .. 1 = heavily overdriven: the sound is pushed into a soft saturation before the filter (an amp: put a low-pass after it for the speaker)
}

UNISON_MAX :: 5

// Parameters a Set_Patch_Param event can change while a song plays.
Patch_Param :: enum u8 {
	Volume,
	Pan,
	Osc0_Level,
	Osc1_Level,
	Osc1_Semitones,
	Pulse_Width,
	Fm_Index,
	Cutoff,
	Resonance,
	Filter_Env_Amount,
	Attack,
	Decay,
	Sustain,
	Release,
	Vibrato_Rate,
	Vibrato_Depth,
	Pitch_Env_Semitones,
	Pitch_Env_Time,
	Unison_Detune, // (the ones below were added later: new values at the end keep old songs working)
	Chorus_Depth,
	Chorus_Rate,
	Tremolo_Depth,
	Tremolo_Rate,
	String_Decay,
	String_Brightness,
	Unison_Voices, // number of detuned copies, 1..UNISON_MAX
	Autopan_From, // auto-pan: one end of the sweep, -1 (left) .. 1 (right)
	Autopan_To, // the other end
	Autopan_Speed, // sweeps per second (Hz), 0 = no auto-pan
	Drive, // overdrive, 0 (clean) .. 1
}

// Parameters that a song has changed on a channel with Set_Patch_Param. They stay in force for the notes of the
// channel (whichever zone plays them) until the channel gets another instrument.
Patch_Overrides :: struct {
	set: bit_set[Patch_Param],
	val: [Patch_Param]f32,
}

patch_apply_overrides :: proc(p: ^Patch, o: ^Patch_Overrides) {
	if o == nil {
		return
	}
	for param in o.set {
		patch_set_param(p, param, o.val[param])
	}
}

patch_set_param :: proc(p: ^Patch, param: Patch_Param, v: f32) {
	switch param {
	case .Volume:
		p.volume = max(v, 0)
	case .Pan:
		p.pan = clamp(v, -1, 1)
	case .Osc0_Level:
		p.osc[0].level = clamp(v, 0, 1)
	case .Osc1_Level:
		p.osc[1].level = clamp(v, 0, 1)
	case .Osc1_Semitones:
		p.osc[1].semitones = v
	case .Pulse_Width:
		p.osc[0].pulse = clamp(v, 0.05, 0.95)
	case .Fm_Index:
		p.fm = max(v, 0)
	case .Cutoff:
		p.filter.cutoff = clamp(v, 20, 20000)
	case .Resonance:
		p.filter.resonance = clamp(v, 0, 1)
	case .Filter_Env_Amount:
		p.filter.env_amount = v
	case .Attack:
		p.amp_env.attack = max(v, 0)
	case .Decay:
		p.amp_env.decay = max(v, 0)
	case .Sustain:
		p.amp_env.sustain = clamp(v, 0, 1)
	case .Release:
		p.amp_env.release = max(v, 0)
	case .Vibrato_Rate:
		p.vibrato_rate = max(v, 0)
	case .Vibrato_Depth:
		p.vibrato_depth = max(v, 0)
	case .Pitch_Env_Semitones:
		p.pitch_env_semitones = v
	case .Pitch_Env_Time:
		p.pitch_env_time = max(v, 0)
	case .Unison_Detune:
		p.unison_detune = clamp(v, 0, 1)
	case .Chorus_Depth:
		p.chorus_depth = clamp(v, 0, 1)
	case .Chorus_Rate:
		p.chorus_rate = clamp(v, 0, 20)
	case .Tremolo_Depth:
		p.tremolo_depth = clamp(v, 0, 1)
	case .Tremolo_Rate:
		p.tremolo_rate = clamp(v, 0, 20)
	case .String_Decay:
		p.string_decay = clamp(v, 0.05, 30)
	case .String_Brightness:
		p.string_bright = clamp(v, 0, 1)
	case .Unison_Voices:
		p.unison = i32(clamp(math.round_f32(v), 1, f32(UNISON_MAX)))
	case .Autopan_From:
		p.autopan_range[0] = clamp(v, -1, 1)
	case .Autopan_To:
		p.autopan_range[1] = clamp(v, -1, 1)
	case .Autopan_Speed:
		p.autopan_speed = clamp(v, 0, 20)
	case .Drive:
		p.drive = clamp(v, 0, 1)
	}
}

// The current value of a parameter (the counterpart of patch_set_param).
patch_get_param :: proc(p: Patch, param: Patch_Param) -> f32 {
	switch param {
	case .Volume:
		return p.volume
	case .Pan:
		return p.pan
	case .Osc0_Level:
		return p.osc[0].level
	case .Osc1_Level:
		return p.osc[1].level
	case .Osc1_Semitones:
		return p.osc[1].semitones
	case .Pulse_Width:
		return p.osc[0].pulse
	case .Fm_Index:
		return p.fm
	case .Cutoff:
		return p.filter.cutoff
	case .Resonance:
		return p.filter.resonance
	case .Filter_Env_Amount:
		return p.filter.env_amount
	case .Attack:
		return p.amp_env.attack
	case .Decay:
		return p.amp_env.decay
	case .Sustain:
		return p.amp_env.sustain
	case .Release:
		return p.amp_env.release
	case .Vibrato_Rate:
		return p.vibrato_rate
	case .Vibrato_Depth:
		return p.vibrato_depth
	case .Pitch_Env_Semitones:
		return p.pitch_env_semitones
	case .Pitch_Env_Time:
		return p.pitch_env_time
	case .Unison_Detune:
		return p.unison_detune
	case .Chorus_Depth:
		return p.chorus_depth
	case .Chorus_Rate:
		return p.chorus_rate
	case .Tremolo_Depth:
		return p.tremolo_depth
	case .Tremolo_Rate:
		return p.tremolo_rate
	case .String_Decay:
		return p.string_decay
	case .String_Brightness:
		return p.string_bright
	case .Unison_Voices:
		return f32(max(p.unison, 1))
	case .Autopan_From:
		return p.autopan_range[0]
	case .Autopan_To:
		return p.autopan_range[1]
	case .Autopan_Speed:
		return p.autopan_speed
	case .Drive:
		return p.drive
	}
	return 0
}

// ---- flat float form (used by the song file format) -------------------------------

PATCH_FLOATS :: 43 // the numbers a patch is stored as

Packer :: struct {
	a:    [PATCH_FLOATS]f32,
	n:    int,
	have: int, // how many numbers are real (the rest were missing)
}

pk_put :: proc(pk: ^Packer, v: f32) {
	if pk.n < PATCH_FLOATS {
		pk.a[pk.n] = v
		pk.n += 1
	}
}

pk_get :: proc(pk: ^Packer, default: f32) -> f32 {
	if pk.n < pk.have {
		v := pk.a[pk.n]
		pk.n += 1
		return v
	}
	return default
}

patch_pack :: proc(p: Patch) -> [PATCH_FLOATS]f32 {
	pk: Packer
	for o in p.osc {
		pk_put(&pk, f32(o.wave))
		pk_put(&pk, o.level)
		pk_put(&pk, o.semitones)
		pk_put(&pk, o.pulse)
	}
	pk_put(&pk, p.fm)
	for e in ([2]Env{p.amp_env, p.filter_env}) {
		pk_put(&pk, e.attack)
		pk_put(&pk, e.decay)
		pk_put(&pk, e.sustain)
		pk_put(&pk, e.release)
	}
	pk_put(&pk, f32(p.filter.mode))
	pk_put(&pk, p.filter.cutoff)
	pk_put(&pk, p.filter.resonance)
	pk_put(&pk, p.filter.env_amount)
	pk_put(&pk, p.filter.key_track)
	pk_put(&pk, p.pitch_env_semitones)
	pk_put(&pk, p.pitch_env_time)
	pk_put(&pk, p.vibrato_rate)
	pk_put(&pk, p.vibrato_depth)
	pk_put(&pk, p.vibrato_delay)
	pk_put(&pk, p.fixed_hz)
	pk_put(&pk, p.volume)
	pk_put(&pk, p.pan)
	pk_put(&pk, p.velocity_sens)
	// (added later; a reader that only knows the first 31 numbers ignores these)
	pk_put(&pk, f32(p.unison))
	pk_put(&pk, p.unison_detune)
	pk_put(&pk, p.chorus_depth)
	pk_put(&pk, p.chorus_rate)
	pk_put(&pk, p.tremolo_depth)
	pk_put(&pk, p.tremolo_rate)
	pk_put(&pk, p.string_decay)
	pk_put(&pk, p.string_bright)
	pk_put(&pk, p.autopan_range[0])
	pk_put(&pk, p.autopan_range[1])
	pk_put(&pk, p.autopan_speed)
	pk_put(&pk, p.drive)
	r: [PATCH_FLOATS]f32
	copy(r[:], pk.a[:PATCH_FLOATS])
	return r
}

// Missing values (a file that holds fewer numbers) keep the defaults.
patch_unpack :: proc(vals: []f32) -> Patch {
	p := patch_base()
	pk: Packer
	for i in 0 ..< min(len(vals), PATCH_FLOATS) {
		pk.a[i] = vals[i]
	}
	pk.have = min(len(vals), PATCH_FLOATS)
	pk.n = 0
	for i in 0 ..< 2 {
		p.osc[i].wave = Waveform(clamp(int(pk_get(&pk, 0)), 0, int(max(Waveform))))
		p.osc[i].level = pk_get(&pk, p.osc[i].level)
		p.osc[i].semitones = pk_get(&pk, 0)
		p.osc[i].pulse = pk_get(&pk, 0.5)
	}
	p.fm = pk_get(&pk, 0)
	envs: [2]Env
	for i in 0 ..< 2 {
		envs[i].attack = pk_get(&pk, 0.005)
		envs[i].decay = pk_get(&pk, 0.2)
		envs[i].sustain = pk_get(&pk, 0.8)
		envs[i].release = pk_get(&pk, 0.2)
	}
	p.amp_env = envs[0]
	p.filter_env = envs[1]
	p.filter.mode = Filter_Mode(clamp(int(pk_get(&pk, 0)), 0, int(max(Filter_Mode))))
	p.filter.cutoff = pk_get(&pk, 8000)
	p.filter.resonance = pk_get(&pk, 0.1)
	p.filter.env_amount = pk_get(&pk, 0)
	p.filter.key_track = pk_get(&pk, 0)
	p.pitch_env_semitones = pk_get(&pk, 0)
	p.pitch_env_time = pk_get(&pk, 0.05)
	p.vibrato_rate = pk_get(&pk, 5)
	p.vibrato_depth = pk_get(&pk, 0)
	p.vibrato_delay = pk_get(&pk, 0)
	p.fixed_hz = pk_get(&pk, 0)
	p.volume = pk_get(&pk, 0.3)
	p.pan = pk_get(&pk, 0)
	p.velocity_sens = pk_get(&pk, 0.7)
	p.unison = i32(pk_get(&pk, 0))
	p.unison_detune = pk_get(&pk, 0)
	p.chorus_depth = pk_get(&pk, 0)
	p.chorus_rate = pk_get(&pk, 0.4)
	p.tremolo_depth = pk_get(&pk, 0)
	p.tremolo_rate = pk_get(&pk, 5)
	p.string_decay = pk_get(&pk, 2)
	p.string_bright = pk_get(&pk, 0.5)
	p.autopan_range[0] = clamp(pk_get(&pk, 0), -1, 1)
	p.autopan_range[1] = clamp(pk_get(&pk, 0), -1, 1)
	p.autopan_speed = clamp(pk_get(&pk, 0), 0, 20)
	p.drive = clamp(pk_get(&pk, 0), 0, 1)
	return p
}

// ---- the built-in instruments ----------------------------------------------------

// A plain saw with a gentle envelope: the starting point of most patches below.
patch_base :: proc() -> Patch {
	return Patch {
		osc = {{wave = .Saw, level = 1, pulse = 0.5}, {wave = .Saw, level = 0, pulse = 0.5}},
		amp_env = {attack = 0.005, decay = 0.2, sustain = 0.8, release = 0.2},
		filter_env = {attack = 0.005, decay = 0.3, sustain = 0, release = 0.3},
		filter = {mode = .Off, cutoff = 8000, resonance = 0.1},
		pitch_env_time = 0.05,
		vibrato_rate = 5,
		volume = 0.3,
		velocity_sens = 0.7,
		chorus_rate = 0.4,
		tremolo_rate = 5,
		string_decay = 2,
		string_bright = 0.5,
	}
}

patch_piano :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.7, 0, 0.5}
	p.osc[1] = {.Triangle, 0.5, 12, 0.5}
	p.amp_env = {0.002, 1.6, 0.12, 0.35}
	p.filter = {.Low_Pass, 1400, 0.1, 2.6, 0.6}
	p.filter_env = {0.001, 0.45, 0.1, 0.3}
	return p
}

patch_epiano :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 12, 0.5}
	p.fm = 1.7
	p.amp_env = {0.002, 1.4, 0.2, 0.35}
	p.filter_env = {0.001, 0.55, 0.28, 0.3}
	p.volume = 0.35
	return p
}

patch_bell :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 21.7, 0.5}
	p.fm = 3.2
	p.amp_env = {0.001, 2.6, 0, 1.6}
	p.filter_env = {0.001, 1.3, 0, 0.6}
	p.volume = 0.3
	return p
}

patch_organ :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Square, 0.55, 0, 0.5}
	p.osc[1] = {.Square, 0.3, 12, 0.5}
	p.amp_env = {0.008, 0.02, 1, 0.06}
	p.filter = {.Low_Pass, 3800, 0.05, 0, 0.5}
	p.vibrato_depth = 0.06
	p.vibrato_delay = 0.2
	return p
}

patch_pluck :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.8, 0, 0.5}
	p.osc[1] = {.Square, 0.3, -12, 0.35}
	p.amp_env = {0.002, 0.9, 0.04, 0.2}
	p.filter = {.Low_Pass, 800, 0.15, 3, 0.5}
	p.filter_env = {0.001, 0.28, 0, 0.2}
	return p
}

patch_bass :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.9, 0, 0.5}
	p.osc[1] = {.Square, 0.7, -12, 0.5}
	p.amp_env = {0.003, 0.12, 0.8, 0.09}
	p.filter = {.Low_Pass, 230, 0.35, 2.4, 0.3}
	p.filter_env = {0.002, 0.2, 0.15, 0.1}
	p.volume = 0.4
	return p
}

patch_strings :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.55, -0.12, 0.5}
	p.osc[1] = {.Saw, 0.55, 0.12, 0.5}
	p.amp_env = {0.4, 0.3, 0.9, 0.7}
	p.filter = {.Low_Pass, 2200, 0.1, 0.8, 0.5}
	p.filter_env = {0.6, 1.2, 0.6, 0.5}
	p.vibrato_rate = 5.2
	p.vibrato_depth = 0.07
	p.vibrato_delay = 0.5
	p.volume = 0.22
	return p
}

patch_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 0.7, -0.07, 0.5}
	p.osc[1] = {.Saw, 0.35, 12.07, 0.5}
	p.amp_env = {0.9, 0.5, 0.85, 1.4}
	p.filter = {.Low_Pass, 1500, 0.2, 1.2, 0.4}
	p.filter_env = {1.2, 2.0, 0.5, 1}
	p.volume = 0.25
	return p
}

patch_brass :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.8, 0, 0.5}
	p.osc[1] = {.Saw, 0.6, 0.09, 0.5}
	p.amp_env = {0.05, 0.15, 0.85, 0.15}
	p.filter = {.Low_Pass, 1000, 0.15, 2.3, 0.4}
	p.filter_env = {0.07, 0.3, 0.5, 0.2}
	return p
}

patch_lead_square :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Square, 0.8, 0, 0.5}
	p.osc[1] = {.Square, 0.4, 0.08, 0.28}
	p.amp_env = {0.01, 0.1, 0.8, 0.12}
	p.filter = {.Low_Pass, 4500, 0.1, 0.5, 0.4}
	p.filter_env = {0.01, 0.2, 0.3, 0.2}
	p.vibrato_rate = 5.5
	p.vibrato_depth = 0.12
	p.vibrato_delay = 0.25
	p.volume = 0.25
	return p
}

patch_lead_saw :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.7, -0.1, 0.5}
	p.osc[1] = {.Saw, 0.7, 0.1, 0.5}
	p.amp_env = {0.01, 0.1, 0.85, 0.15}
	p.filter = {.Low_Pass, 3000, 0.2, 1.5, 0.5}
	p.filter_env = {0.01, 0.25, 0.4, 0.2}
	p.vibrato_depth = 0.1
	p.vibrato_delay = 0.3
	p.volume = 0.22
	return p
}

patch_flute :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Noise, 0.07, 0, 0.5}
	p.amp_env = {0.06, 0.1, 0.85, 0.12}
	p.filter = {.Low_Pass, 3600, 0.05, 0, 0.6}
	p.vibrato_depth = 0.1
	p.vibrato_delay = 0.3
	p.volume = 0.35
	return p
}

patch_reed :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Square, 0.9, 0, 0.18}
	p.osc[1] = {.Triangle, 0.4, 0, 0.5}
	p.amp_env = {0.04, 0.1, 0.85, 0.1}
	p.filter = {.Low_Pass, 2200, 0.2, 1, 0.5}
	p.filter_env = {0.05, 0.2, 0.5, 0.15}
	p.vibrato_depth = 0.08
	p.vibrato_delay = 0.2
	return p
}

patch_noise_fx :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Noise, 1, 0, 0.5}
	p.amp_env = {0.4, 0.5, 0.7, 0.8}
	p.filter = {.Band_Pass, 800, 0.5, 2, 0}
	p.filter_env = {0.8, 1.5, 0.3, 0.6}
	p.volume = 0.2
	return p
}

// ---- drums ------------------------------------------------------------------------

patch_kick :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Noise, 0.06, 0, 0.5}
	p.fixed_hz = 52
	p.pitch_env_semitones = 26
	p.pitch_env_time = 0.04
	p.amp_env = {0.001, 0.38, 0, 0.05}
	p.filter = {.Low_Pass, 3000, 0.1, 0, 0}
	p.volume = 0.9
	p.velocity_sens = 0.5
	return p
}

patch_snare :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 0.7, 0, 0.5}
	p.osc[1] = {.Noise, 1, 0, 0.5}
	p.fixed_hz = 190
	p.pitch_env_semitones = 6
	p.pitch_env_time = 0.03
	p.amp_env = {0.001, 0.2, 0, 0.05}
	p.filter = {.High_Pass, 900, 0.1, 0, 0}
	p.volume = 0.55
	return p
}

patch_hat :: proc(open: bool) -> Patch {
	p := patch_base()
	p.osc[0] = {.Noise, 1, 0, 0.5}
	p.osc[1].level = 0
	p.amp_env = {0.001, 0.045, 0, 0.02}
	if open {
		p.amp_env = {0.001, 0.32, 0, 0.12}
	}
	p.filter = {.High_Pass, 7000, 0.1, 0, 0}
	p.volume = 0.3
	return p
}

patch_tom :: proc(hz: f32) -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Noise, 0.05, 0, 0.5}
	p.fixed_hz = hz
	p.pitch_env_semitones = 10
	p.pitch_env_time = 0.07
	p.amp_env = {0.001, 0.32, 0, 0.08}
	p.volume = 0.7
	return p
}

patch_clap :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Noise, 1, 0, 0.5}
	p.osc[1].level = 0
	p.amp_env = {0.003, 0.14, 0, 0.06}
	p.filter = {.Band_Pass, 1500, 0.35, 0, 0}
	p.volume = 0.6
	return p
}

patch_cymbal :: proc(decay: f32) -> Patch {
	p := patch_base()
	p.osc[0] = {.Noise, 1, 0, 0.5}
	p.osc[1] = {.Square, 0.15, 0, 0.5}
	p.fixed_hz = 3300
	p.amp_env = {0.002, decay, 0, decay * 0.4}
	p.filter = {.High_Pass, 5200, 0.1, 0, 0}
	p.volume = 0.28
	return p
}

patch_rim :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 1, 0, 0.5}
	p.osc[1] = {.Noise, 0.2, 0, 0.5}
	p.fixed_hz = 1700
	p.amp_env = {0.001, 0.03, 0, 0.02}
	p.volume = 0.5
	return p
}

patch_cowbell :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Square, 0.6, 0, 0.5}
	p.osc[1] = {.Square, 0.6, 7.02, 0.5}
	p.fixed_hz = 560
	p.amp_env = {0.001, 0.18, 0, 0.05}
	p.filter = {.Band_Pass, 1000, 0.3, 0, 0}
	p.volume = 0.4
	return p
}

// Frequency in Hz of a MIDI key (69 = A4 = 440 Hz).
key_to_hz :: proc(key: f32) -> f32 {
	return 440 * math.pow_f32(f32(2), (key - 69) / 12)
}
