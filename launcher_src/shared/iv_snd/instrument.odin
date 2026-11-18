package iv_snd

import "core:math"

// ---------------------------------------------------------------------------
// Instruments.
//
// An instrument is what a channel of a song plays, and every instrument is built the same way: a list of
// ZONES laid out on the keyboard, in the manner of a SoundFont. A zone says which keys it plays (key_lo to
// key_hi) and WHERE ITS SOUND COMES FROM, which is one of two things:
//
//   Synth    a set of parameters for the synthesizer (a Patch, see patch.odin): oscillators, envelopes, a
//            filter, effects. The zone plays that sound at the pitch of the key.
//
//   Sample   a recording (PCM samples, the WAV files: sample_id is the number + 1 in Song.samples; one
//            recording may be used by any number of zones, in any number of instruments). The zone's patch
//            then carries what shapes the recording: the envelope, the filter, the loudness, the pan and the
//            auto-pan (its oscillator settings are not used).
//
// So an instrument that is "just a synth sound" is one Synth zone over all 128 keys, a drum kit is a row of
// Sample zones, and an instrument may mix the two (a recorded attack on the low keys, a synth pad above).
//
// More about a zone:
//
//   * the ROOT KEY (Sample zones): the key at which the recording sounds as it was recorded. It may be left
//     unset (has_root = false); the first time it is needed it is worked out from the recording
//     (sample_detect_root_v1, see sample.odin) and FROZEN into the zone for good. A zone that is not
//     `pitched` never needs one;
//   * `pitched` (Sample zones): the recording follows the key (played faster for higher keys, relative to its
//     root key), like an ordinary sampled instrument. Off (the default): every key of the zone plays the
//     recording as it is, as for the pieces of a drum kit. A Synth zone always follows the key;
//   * LOOP (Sample zones): loop_on, loop_start and loop_end (in frames of the recording): while the key is
//     held the sound repeats between the two points;
//   * `one_shot`: plays to its end and ignores the note-off (drums). Off: the note-off releases it (a looping
//     recording needs that, or it would never stop);
//   * `tune` (semitones), `volume` and `pan` balance the zones against each other (the patch has its own
//     volume and pan too), and a choke `group` (1..255): notes of one group on one channel cut each other off
//     (an open hi-hat is stopped by a closed one). Recordings are also normalised to the same loudness.
//
// The first zone that holds a key plays it; a key that no zone holds stays silent.
//
// Songs hold a list of instruments (Song.instruments) and a Set_Instrument event gives a channel one.
// The instrument library (library.odin) is the catalogue of ready-made instruments.
// ---------------------------------------------------------------------------

Zone_Source :: enum u8 {
	Synth, // the sound is the synthesizer patch of the zone
	Sample, // the sound is a recording (sample_id), shaped by the patch of the zone
}

ZONE_MAX :: 256 // zones of an instrument

Zone :: struct {
	key_lo:       u8, // the first key (0..127) the zone plays on
	key_hi:       u8, // the last key
	source:       Zone_Source,
	patch:        Patch, // Synth: the sound. Sample: what shapes the recording (see above)
	sample_id:    i32, // Sample: recording number sample_id - 1 of the song (0 = none: the zone is silent)
	pitched:      bool, // Sample: the recording follows the key, relative to its root key; off: the same sound on every key
	one_shot:     bool, // plays to its end, note-offs are ignored
	tune:         f32, // semitones
	volume:       f32, // 1 = as loud as the patch (a Sample zone: as the normalised recording)
	pan:          f32, // -1..1, added to the pan of the patch
	group:        u8, // choke group, 0 = none
	has_root:     bool, // Sample: root_key is valid; false: not worked out yet (done when it is first needed)
	root_key:     f32, // MIDI key (with a fraction) at which the recording sounds as recorded
	root_version: u8, // which method found root_key (0 = set by hand)
	root_known:   bool, // the root key is a real finding (found by the detection or set by hand), not the default
	loop_on:      bool, // Sample: the sound repeats between loop_start and loop_end while the key is held
	loop_start:   int, // in frames
	loop_end:     int,

	// -- set at run time (instruments_resolve), never stored --
	sample:       ^Sample, // Sample zones: the recording
	gain:         f32, // the normalising gain of the recording (1 for a Synth zone)
}

Instrument :: struct {
	name:  Patch_Label,
	zones: [dynamic]Zone,
	graph: int, // the effect graph the sound of this instrument is played through: its number in the library (Song.graphs; 1 = the first), 0 = none (graph.odin)
}

// ---- making instruments --------------------------------------------------------------

// The patch of a new Sample zone: quick and dry, so the recording is heard as it is.
sample_zone_patch :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1].level = 0
	p.amp_env = {0.001, 0.1, 1, 0.08}
	p.vibrato_depth = 0
	p.volume = 1
	p.velocity_sens = 0.6
	return p
}

// A Synth zone for keys `key_lo` to `key_hi` that plays `patch`.
zone_synth :: proc(key_lo, key_hi: int, patch: Patch, tune: f32 = 0, volume: f32 = 1, pan: f32 = 0, group := 0) -> Zone {
	return Zone {
		key_lo = u8(clamp(min(key_lo, key_hi), 0, 127)),
		key_hi = u8(clamp(max(key_lo, key_hi), 0, 127)),
		source = .Synth,
		patch = patch,
		tune = tune,
		volume = volume,
		pan = clamp(pan, -1, 1),
		group = u8(clamp(group, 0, 255)),
		gain = 1,
	}
}

// A Sample zone for keys `key_lo` to `key_hi` that plays `sample` (song_add_instrument fills in sample_id).
// Its patch is sample_zone_patch(); change zone.patch for another envelope or filter.
zone_sample :: proc(key_lo, key_hi: int, sample: ^Sample, pitched := false, one_shot := true, tune: f32 = 0, volume: f32 = 1, pan: f32 = 0, group := 0) -> Zone {
	return Zone {
		key_lo = u8(clamp(min(key_lo, key_hi), 0, 127)),
		key_hi = u8(clamp(max(key_lo, key_hi), 0, 127)),
		source = .Sample,
		patch = sample_zone_patch(),
		pitched = pitched,
		one_shot = one_shot,
		tune = tune,
		volume = volume,
		pan = clamp(pan, -1, 1),
		group = u8(clamp(group, 0, 255)),
		sample = sample,
		gain = 1,
	}
}

// A Sample zone with the settings a new zone starts with (it plays nothing until it has a recording).
zone_default :: proc() -> Zone {
	return Zone{key_lo = 36, key_hi = 36, source = .Sample, patch = sample_zone_patch(), one_shot = true, volume = 1, gain = 1}
}

// An instrument without zones: add them with instrument_add_zone.
instrument_empty :: proc(name: string) -> ^Instrument {
	i := new(Instrument)
	i.name = patch_label_make(name)
	return i
}

// An instrument that is one synthesizer sound over all keys (the caller owns it, or gives it to a song with
// song_add_instrument).
instrument_synth :: proc(patch: Patch, name: string) -> ^Instrument {
	i := instrument_empty(name)
	append(&i.zones, zone_synth(0, 127, patch))
	return i
}

instrument_add_zone :: proc(inst: ^Instrument, z: Zone) -> bool {
	if len(inst.zones) >= ZONE_MAX {
		return false
	}
	append(&inst.zones, z)
	return true
}

// An instrument that plays one recording on all keys, following the key like an ordinary sampled
// instrument (it sounds as recorded at its root key, which is worked out now and then fixed).
instrument_from_sample :: proc(sm: ^Sample, name: string) -> ^Instrument {
	i := instrument_empty(name)
	z := zone_sample(0, 127, sm, pitched = true, one_shot = false)
	z.patch.amp_env = {0.002, 0.1, 1, 0.12}
	z.patch.velocity_sens = 0.5
	zone_resolve(&z, sm)
	append(&i.zones, z)
	return i
}

instrument_clone :: proc(i: ^Instrument) -> ^Instrument {
	n := new(Instrument)
	n.name = i.name
	append(&n.zones, ..i.zones[:])
	n.graph = i.graph
	return n
}

// Whether two instruments make the same sound (the same name and zones; the graph they play through is not compared).
instrument_same_sound :: proc(a, b: ^Instrument) -> bool {
	if a.name != b.name || len(a.zones) != len(b.zones) {
		return false
	}
	for i in 0 ..< len(a.zones) {
		if a.zones[i] != b.zones[i] {
			return false
		}
	}
	return true
}

instrument_destroy :: proc(i: ^Instrument) {
	if i == nil {
		return
	}
	delete(i.zones)
	free(i)
}

instrument_name :: proc(i: ^Instrument) -> string {
	return patch_label_string(&i.name)
}

// Whether any zone of the instrument plays a recording / a synthesizer patch.
instrument_has_samples :: proc(i: ^Instrument) -> bool {
	for &z in i.zones {
		if z.source == .Sample {
			return true
		}
	}
	return false
}

instrument_has_synth :: proc(i: ^Instrument) -> bool {
	for &z in i.zones {
		if z.source == .Synth {
			return true
		}
	}
	return false
}

// A word for what the instrument is made of: "synth", "samples", "mixed" or "empty".
instrument_makeup :: proc(i: ^Instrument) -> string {
	s, p := instrument_has_synth(i), instrument_has_samples(i)
	if s && p {
		return "mixed"
	}
	if s {
		return "synth"
	}
	if p {
		return "samples"
	}
	return "empty"
}

// The first zone of the instrument that plays a synthesizer patch, or nil.
instrument_first_synth_zone :: proc(i: ^Instrument) -> ^Zone {
	for &z in i.zones {
		if z.source == .Synth {
			return &z
		}
	}
	return nil
}

// The speed of the auto-pan sweep of the instrument (the first zone that has one), 0 = none. The sweep
// belongs to the channel, not to the notes.
instrument_autopan_speed :: proc(i: ^Instrument) -> f32 {
	for &z in i.zones {
		if z.patch.autopan_speed > 0 {
			return z.patch.autopan_speed
		}
	}
	return 0
}

// ---- using them ------------------------------------------------------------------------

// The zone that plays `key` (the first one that holds it), or nil.
instrument_find_zone :: proc(inst: ^Instrument, key: int) -> ^Zone {
	if inst == nil {
		return nil
	}
	for &z in inst.zones {
		if key >= int(z.key_lo) && key <= int(z.key_hi) {
			return &z
		}
	}
	return nil
}

// What a note plays: the patch for the voice and the zone it comes from. ok is false if nothing plays (no zone
// holds the key, or a Sample zone has no recording).
instrument_note :: proc(inst: ^Instrument, key: int) -> (patch: Patch, zone: ^Zone, ok: bool) {
	z := instrument_find_zone(inst, key)
	if z == nil || (z.source == .Sample && z.sample == nil) {
		return {}, nil, false
	}
	return zone_patch(z), z, true
}

// The patch that plays zone `z`: the patch of the zone with its tuning, loudness (including the gain that
// normalises a recording) and pan. `over` (may be nil) holds parameters that a song has changed on the channel
// (Set_Patch_Param); they replace the values of the patch before the zone's own settings are applied.
zone_patch :: proc(z: ^Zone, over: ^Patch_Overrides = nil) -> Patch {
	p := z.patch
	patch_apply_overrides(&p, over)
	p.osc[0].semitones += z.tune
	p.osc[1].semitones += z.tune
	p.volume = p.volume * z.volume * z.gain
	p.pan = clamp(p.pan + z.pan, -1, 1)
	return p
}

// The loudest value of a recording (cached in the sample), 1..32768.
sample_peak :: proc(s: ^Sample) -> i32 {
	if s.peak <= 0 {
		pk: i32 = 1
		for v in s.data {
			pk = max(pk, abs(i32(v)))
		}
		s.peak = pk
	}
	return s.peak
}

// ---- root key and loop of a zone -------------------------------------------------------------

// Works out the root key of the zone's recording and fixes it in the zone, unless the zone has one already.
zone_ensure_root :: proc(z: ^Zone) {
	if z.has_root || z.sample == nil {
		return
	}
	r := sample_detect_root_v1(z.sample.data, z.sample.rate)
	z.root_key = r.key
	z.root_known = r.pitched
	z.root_version = ROOT_DETECT_VERSION
	z.has_root = true
}

// The nearest whole key of the root and how far the recording is from it in cents (-50..50).
zone_root_note :: proc(z: ^Zone) -> (key: int, cents: int) {
	rk: f32 = 60
	if z.has_root {
		rk = z.root_key
	}
	k := int(math.round_f32(rk))
	c := int(math.round_f32((rk - f32(k)) * 100))
	return k, c
}

// Sets the root key by hand (the editor lets the user correct a wrong guess).
zone_set_root :: proc(z: ^Zone, key: f32) {
	z.root_key = clamp(math.round_f32(key * 100) / 100, 0, 127)
	z.root_version = 0
	z.root_known = true
	z.has_root = true
}

// Looks for a seamless loop in the last part of a pitched recording (a whole number of
// periods that start and end on the same rising zero crossing, with the best matching
// waveform) and switches the loop of the zone on. Returns false if there is no sensible loop.
zone_find_loop :: proc(z: ^Zone) -> bool {
	s := z.sample
	if s == nil {
		return false
	}
	zone_ensure_root(z)
	n := len(s.data)
	if !z.root_known || n < 1024 {
		return false
	}
	hz := f64(key_to_hz(z.root_key))
	period := f64(s.rate) / hz
	if period < 4 || period * 8 > f64(n) {
		return false
	}
	x := s.data
	tail := max(s.rate / 100, 8)
	e := n - 1 - tail
	for e > n / 2 && !(x[e - 1] < 0 && x[e] >= 0) {
		e -= 1
	}
	if e <= n / 2 {
		return false
	}
	m := max(int(math.round_f64(f64(e) * 0.4 / period)), 4)
	s0 := e - int(math.round_f64(f64(m) * period))
	if s0 < 2 {
		return false
	}
	k := min(max(int(period), 16), 512)
	k = min(k, n - 1 - e)
	lo := max(s0 - int(period / 2), 1)
	hi := min(s0 + int(period / 2), e - int(3 * period))
	if hi < lo {
		return false
	}
	best := -1
	best_err: i64 = max(i64)
	for pass in 0 ..< 2 {
		for st in lo ..= hi {
			if pass == 0 && !(x[st - 1] < 0 && x[st] >= 0) {
				continue
			}
			err: i64 = 0
			for j in 0 ..< k {
				dd := i64(x[st + j]) - i64(x[e + j])
				err += dd * dd
			}
			if err < best_err {
				best_err = err
				best = st
			}
		}
		if best >= 0 {
			break
		}
	}
	if best < 0 {
		return false
	}
	z.loop_start = best
	z.loop_end = e
	z.loop_on = true
	return true
}

// ---- resolving ------------------------------------------------------------------------------

// Looks up the recording of a zone and works out its gain; a pitched Sample zone also gets its root key
// (worked out once and then fixed). A Synth zone has no recording (`sm` is ignored).
zone_resolve :: proc(z: ^Zone, sm: ^Sample) {
	z.gain = 1
	if z.source != .Sample {
		z.sample = nil
		return
	}
	z.sample = sm
	if sm == nil {
		return
	}
	pk := max(f32(sample_peak(sm)) / 32768, 0.01)
	z.gain = clamp(0.35 / pk, 0.05, 3)
	z.loop_start = clamp(z.loop_start, 0, len(sm.data))
	z.loop_end = clamp(z.loop_end, 0, len(sm.data))
	if z.pitched {
		zone_ensure_root(z)
	}
}

// Looks up the recordings (sample_id = index + 1 in `samples`) of the Sample zones of the instruments.
// Editors call it after they change zones or recordings.
instruments_resolve :: proc(insts: []^Instrument, samples: []^Sample) {
	for i in insts {
		for &z in i.zones {
			sm: ^Sample = nil
			if z.sample_id > 0 && int(z.sample_id) <= len(samples) {
				sm = samples[z.sample_id - 1]
			}
			zone_resolve(&z, sm)
		}
	}
}

// ---- in songs -----------------------------------------------------------------------------------

// Adds a recording to the song (the song takes its own share of it) and returns its index.
song_add_sample :: proc(s: ^Song, sm: ^Sample) -> int {
	sample_retain(sm)
	append(&s.samples, sm)
	return len(s.samples) - 1
}

// Makes the Sample zones of `inst` point (sample_id) at the song's recordings, adding the recordings the song
// does not have yet (once each; the song takes its own share).
song_attach_samples :: proc(s: ^Song, inst: ^Instrument) {
	for &z in inst.zones {
		if z.sample == nil {
			continue
		}
		idx := -1
		for sm, i in s.samples {
			if sm == z.sample {
				idx = i
				break
			}
		}
		if idx < 0 {
			idx = song_add_sample(s, z.sample)
		}
		z.sample_id = i32(idx + 1)
	}
}

// Gives an instrument to the song (the song owns it from now on) and returns its index. The recordings
// its zones point to (Zone.sample) are added to the song too, once each.
song_add_instrument :: proc(s: ^Song, inst: ^Instrument) -> int {
	song_attach_samples(s, inst)
	append(&s.instruments, inst)
	instruments_resolve(s.instruments[len(s.instruments) - 1:], s.samples[:])
	return len(s.instruments) - 1
}

// Makes a synth instrument of `patch` in the song and returns its index.
song_add_synth :: proc(s: ^Song, patch: Patch, name: string) -> int {
	return song_add_instrument(s, instrument_synth(patch, name))
}

// The channel plays instrument number `instrument` of the song from `tick` on.
song_set_instrument :: proc(s: ^Song, track: int, tick: u32, channel, instrument: int) {
	song_add_event(s, track, Event{tick = tick, kind = .Set_Instrument, channel = u8(channel), a = i32(instrument)})
}

// Name of instrument `index` of the song ("" if there is none).
song_instrument_name :: proc(s: ^Song, index: int) -> string {
	if index < 0 || index >= len(s.instruments) {
		return ""
	}
	return instrument_name(s.instruments[index])
}

// ---- the instrument every channel starts with ---------------------------------------------------

default_instrument_store: Instrument
default_instrument_ready: bool

// A plain piano-like synth instrument: what a channel plays until the song gives it another.
default_instrument :: proc() -> ^Instrument {
	if !default_instrument_ready {
		default_instrument_store.name = patch_label_make("Basic Piano")
		append(&default_instrument_store.zones, zone_synth(0, 127, patch_piano()))
		default_instrument_ready = true
	}
	return &default_instrument_store
}

// ---- instruments that are library entries ------------------------------------------------------

// Are two recordings the same sound? (The same object, or the same rate and frames.)
sample_same :: proc(a, b: ^Sample) -> bool {
	if a == b {
		return true
	}
	if a == nil || b == nil || a.rate != b.rate || len(a.data) != len(b.data) {
		return false
	}
	for v, i in a.data {
		if v != b.data[i] {
			return false
		}
	}
	return true
}

// Do two instruments sound the same: the same zones, with the same settings, patches and recordings?
// (The name and the numbers that tie a zone to the recordings of a song do not count.)
instruments_same :: proc(a, b: ^Instrument) -> bool {
	if len(a.zones) != len(b.zones) {
		return false
	}
	for i in 0 ..< len(a.zones) {
		x, y := &a.zones[i], &b.zones[i]
		if x.key_lo != y.key_lo || x.key_hi != y.key_hi || x.source != y.source || x.pitched != y.pitched || x.one_shot != y.one_shot {
			return false
		}
		if x.tune != y.tune || x.volume != y.volume || x.pan != y.pan || x.group != y.group {
			return false
		}
		if x.has_root != y.has_root || x.root_key != y.root_key || x.root_version != y.root_version || x.root_known != y.root_known {
			return false
		}
		if x.loop_on != y.loop_on || x.loop_start != y.loop_start || x.loop_end != y.loop_end {
			return false
		}
		if patch_pack(x.patch) != patch_pack(y.patch) {
			return false
		}
		if x.source == .Sample && !sample_same(x.sample, y.sample) {
			return false
		}
	}
	return true
}

// Is `inst` exactly a library entry that plays recordings (an unchanged "Standard Drums", say)? Such an
// instrument is saved in a song as the name of the entry alone, and not with its recordings. (Entries
// without recordings are small, so they are always saved in full.) Returns the library index.
instrument_library_ref :: proc(inst: ^Instrument) -> (lib: int, ok: bool) {
	i, found := library_find(instrument_name(inst))
	if !found || !library_has_samples(i) {
		return 0, false
	}
	fresh := library_instrument(i)
	defer instrument_destroy(fresh) // (the recordings belong to the library's cache)
	return i, instruments_same(inst, fresh)
}

// ---- file format ----------------------------------------------------------------------------

ZONE_PITCHED :: 1
ZONE_ONE_SHOT :: 2
ZONE_HAS_ROOT :: 4
ZONE_ROOT_KNOWN :: 8
ZONE_LOOP :: 16
ZONE_SAMPLE :: 32 // the zone plays a recording (else a synthesizer patch)
ZONE_SAME_PATCH :: 64 // the patch is the one of the zone before (it is not stored again)

// One instrument: string name, varlen zone count, then per zone: u8 key_lo, u8 key_hi, u8 flags (ZONE_*),
// f32 tune, f32 volume, f32 pan, u8 group, [varlen float count and the patch numbers, unless ZONE_SAME_PATCH],
// and for a ZONE_SAMPLE zone: varlen sample number + 1, [f32 root key, u8 root version if ZONE_HAS_ROOT],
// [varlen loop start, varlen loop end if ZONE_LOOP].
// `sample_map` (may be empty) renumbers the recordings: the zone's recording number n is written as sample_map[n - 1] + 1.
instrument_encode :: proc(w: ^Writer, inst: ^Instrument, sample_map: []i32 = nil) {
	w_str(w, instrument_name(inst))
	w_varlen(w, u32(len(inst.zones)))
	prev: [PATCH_FLOATS]f32
	for z, zi in inst.zones {
		fl := patch_pack(z.patch)
		flags: u8 = 0
		if z.pitched {
			flags |= ZONE_PITCHED
		}
		if z.one_shot {
			flags |= ZONE_ONE_SHOT
		}
		if z.has_root {
			flags |= ZONE_HAS_ROOT
		}
		if z.root_known {
			flags |= ZONE_ROOT_KNOWN
		}
		if z.loop_on {
			flags |= ZONE_LOOP
		}
		if z.source == .Sample {
			flags |= ZONE_SAMPLE
		}
		if zi > 0 && fl == prev {
			flags |= ZONE_SAME_PATCH
		}
		w_u8(w, z.key_lo)
		w_u8(w, z.key_hi)
		w_u8(w, flags)
		w_f32(w, z.tune)
		w_f32(w, z.volume)
		w_f32(w, z.pan)
		w_u8(w, z.group)
		if flags & ZONE_SAME_PATCH == 0 {
			w_varlen(w, PATCH_FLOATS)
			for v in fl {
				w_f32(w, v)
			}
		}
		prev = fl
		if z.source != .Sample {
			continue
		}
		id := z.sample_id
		if id > 0 && int(id) <= len(sample_map) {
			id = sample_map[id - 1] + 1
		}
		w_varlen(w, u32(max(id, 0)))
		if z.has_root {
			w_f32(w, z.root_key)
			w_u8(w, z.root_version)
		}
		if z.loop_on {
			w_varlen(w, u32(z.loop_start))
			w_varlen(w, u32(z.loop_end))
		}
	}
}

instrument_decode :: proc(r: ^Reader) -> ^Instrument {
	inst := new(Instrument)
	inst.name = patch_label_make(r_str(r, context.temp_allocator))
	nz := int(r_varlen(r))
	prev := patch_base()
	for _ in 0 ..< nz {
		if !r.ok {
			break
		}
		z := zone_default()
		z.key_lo = r_u8(r) & 127
		z.key_hi = r_u8(r) & 127
		flags := r_u8(r)
		z.source = .Sample if flags & ZONE_SAMPLE != 0 else .Synth
		z.pitched = flags & ZONE_PITCHED != 0
		z.one_shot = flags & ZONE_ONE_SHOT != 0
		z.root_known = flags & ZONE_ROOT_KNOWN != 0
		z.tune = r_f32(r)
		z.volume = r_f32(r)
		z.pan = clamp(r_f32(r), -1, 1)
		z.group = r_u8(r)
		if flags & ZONE_SAME_PATCH != 0 {
			z.patch = prev
		} else {
			nf := int(r_varlen(r))
			if !r.ok || nf > 4096 {
				r.ok = false
				break
			}
			vals := make([]f32, nf, context.temp_allocator)
			for i in 0 ..< nf {
				vals[i] = r_f32(r)
			}
			z.patch = patch_unpack(vals)
		}
		prev = z.patch
		if z.source == .Sample {
			z.sample_id = i32(r_varlen(r))
			if flags & ZONE_HAS_ROOT != 0 {
				z.has_root = true
				z.root_key = clamp(r_f32(r), 0, 127)
				z.root_version = r_u8(r)
			}
			if flags & ZONE_LOOP != 0 {
				z.loop_on = true
				z.loop_start = int(r_varlen(r))
				z.loop_end = int(r_varlen(r))
			}
		} else {
			z.gain = 1
		}
		if r.ok && len(inst.zones) < ZONE_MAX {
			append(&inst.zones, z)
		}
	}
	return inst
}
