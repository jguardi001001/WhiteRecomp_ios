package iv_snd

import "core:math"
import "core:sync"

// ---------------------------------------------------------------------------
// The instrument library: every ready-made instrument of the package, in groups.
//
//   Basic     the plain all-round synth sounds (piano, e-piano, bell, organ, pluck, bass, strings, pad,
//             brass, leads, flute, reed, noise): what MIDI files are mapped onto when they are imported
//   Strings   synth strings in several moods (string machine, ensemble, slow, tremolo, ...)
//   Pads      warm, soft, analog, nebula and other long sounds
//   Keys      pianos, electric pianos, crystal piano, celesta, music box, lunar keys, frost keys, organ
//   Plucked   pizzicato strings, harp, nylon guitar (Karplus-Strong strings)
//   Bells     starlight chime, ring gong, singing bowl, frost chime
//   Leads     aurora, pulsar, halo lead, ion pluck
//   Bass      sub orbit, void drone, event horizon, dark matter
//   Effects   solar wind, comet, sonar ping, static hiss, dust shimmer
//   Drums     "Standard Drums" is a drum kit: an instrument with a recording (a sample zone) for each
//             drum sound, the synthesized drum sounds rendered once to PCM when first asked for
//
// Find an instrument by name with library_find: names never change, and neither does the sound
// of an entry (see below), so a song may rely on them.
//
// Entries are made fresh by library_instrument: an instrument of one synth zone (a Patch) or one
// that a procedure builds from zones of either source. A song carries its own copy of the ones it uses
// (Song.instruments), so nothing in the library may be changed in a way that alters the sound of
// an old song. New instruments may be added anywhere, but an existing entry must keep its name
// and sound.
//
//   inst := iv_snd.library_instrument(3)          // a new ^Instrument; the song takes it over:
//   idx := iv_snd.song_add_instrument(&song, inst)
//   iv_snd.song_set_instrument(&song, track, 0, channel, idx)
// ---------------------------------------------------------------------------

Lib_Category :: enum u8 {
	Basic,
	Strings,
	Pads,
	Keys,
	Plucked,
	Bells,
	Leads,
	Bass,
	Effects,
	Drums,
}

Lib_Entry :: struct {
	name:     string, // up to 23 letters
	category: Lib_Category,
	make:     proc() -> Patch, // an instrument of one synth zone over all keys: its patch (nil if `build` makes the instrument)
	build:    proc() -> ^Instrument, // an instrument built from zones (nil for a plain patch entry)
	samples:  bool, // the built instrument plays recordings
}

// Semitones of a frequency ratio (for the tuning of an FM modulator: ratio 3.5 = lib_ratio(3.5)).
lib_ratio :: proc(r: f32) -> f32 {
	return 12 * math.log2_f32(r)
}

LIBRARY := [?]Lib_Entry {
	// ---- basic ----
	{"Basic Piano", .Basic, patch_piano, nil, false},
	{"Basic E-Piano", .Basic, patch_epiano, nil, false},
	{"Basic Bell", .Basic, patch_bell, nil, false},
	{"Basic Organ", .Basic, patch_organ, nil, false},
	{"Basic Pluck", .Basic, patch_pluck, nil, false},
	{"Basic Bass", .Basic, patch_bass, nil, false},
	{"Basic Strings", .Basic, patch_strings, nil, false},
	{"Basic Pad", .Basic, patch_pad, nil, false},
	{"Basic Brass", .Basic, patch_brass, nil, false},
	{"Basic Square Lead", .Basic, patch_lead_square, nil, false},
	{"Basic Saw Lead", .Basic, patch_lead_saw, nil, false},
	{"Basic Flute", .Basic, patch_flute, nil, false},
	{"Basic Reed", .Basic, patch_reed, nil, false},
	{"Basic Noise", .Basic, patch_noise_fx, nil, false},
	// ---- strings ----
	{"Synth Strings", .Strings, lib_synth_strings, nil, false},
	{"String Ensemble", .Strings, lib_string_ensemble, nil, false},
	{"Solina Strings", .Strings, lib_solina_strings, nil, false},
	{"Slow Strings", .Strings, lib_slow_strings, nil, false},
	{"Tremolo Strings", .Strings, lib_tremolo_strings, nil, false},
	{"Staccato Strings", .Strings, lib_staccato_strings, nil, false},
	{"Cello Section", .Strings, lib_cello_section, nil, false},
	{"Violin Section", .Strings, lib_violin_section, nil, false},
	{"Glass Strings", .Strings, lib_glass_strings, nil, false},
	// ---- pads ----
	{"Warm Pad", .Pads, lib_warm_pad, nil, false},
	{"Soft Warm Pad", .Pads, lib_soft_warm_pad, nil, false},
	{"Analog Pad", .Pads, lib_analog_pad, nil, false},
	{"Velvet Pad", .Pads, lib_velvet_pad, nil, false},
	{"Sunrise Pad", .Pads, lib_sunrise_pad, nil, false},
	{"Dusk Pad", .Pads, lib_dusk_pad, nil, false},
	{"Choir Pad", .Pads, lib_choir_pad, nil, false},
	{"Nebula Pad", .Pads, lib_nebula_pad, nil, false},
	{"Europa Pad", .Pads, lib_europa_pad, nil, false},
	{"Aether Pad", .Pads, lib_aether_pad, nil, false},
	{"Cryo Pad", .Pads, lib_cryo_pad, nil, false},
	{"Deep Field Pad", .Pads, lib_deep_field_pad, nil, false},
	{"Fantasia", .Pads, lib_fantasia, nil, false},
	// ---- keys ----
	{"E-Piano (Rhodes)", .Keys, lib_epiano_rhodes, nil, false},
	{"E-Piano (Wurlitzer)", .Keys, lib_epiano_wurly, nil, false},
	{"E-Piano (FM)", .Keys, lib_epiano_fm, nil, false},
	{"E-Piano (Dream)", .Keys, lib_epiano_dream, nil, false},
	{"Crystal Piano", .Keys, lib_crystal_piano, nil, false},
	{"Celesta", .Keys, lib_celesta, nil, false},
	{"Music Box", .Keys, lib_music_box, nil, false},
	{"Soft Piano", .Keys, lib_soft_piano, nil, false},
	{"Bright Piano", .Keys, lib_bright_piano, nil, false},
	{"Honky-Tonk Piano", .Keys, lib_honky_piano, nil, false},
	{"Dream Keys", .Keys, lib_dream_keys, nil, false},
	{"Lunar Keys", .Keys, lib_lunar_keys, nil, false},
	{"Frost Keys", .Keys, lib_frost_keys, nil, false},
	{"Cathedral Organ", .Keys, lib_cathedral_organ, nil, false},
	// ---- plucked ----
	{"Pizzicato Strings", .Plucked, lib_pizzicato, nil, false},
	{"Pizzicato Section", .Plucked, lib_pizzicato_section, nil, false},
	{"Pizzicato Staccato", .Plucked, lib_pizzicato_staccato, nil, false},
	{"Pizzicato Bass", .Plucked, lib_pizzicato_bass, nil, false},
	{"Harp", .Plucked, lib_harp, nil, false},
	{"Nylon Guitar", .Plucked, lib_nylon_guitar, nil, false},
	{"Zero-G Harp", .Plucked, lib_zero_g_harp, nil, false},
	{"Kalimba", .Plucked, lib_kalimba, nil, false},
	{"Banjo", .Plucked, lib_banjo, nil, false},
	{"Overdrive Guitar", .Plucked, lib_overdrive_guitar, nil, false},
	// ---- bells ----
	{"Starlight", .Bells, lib_starlight, nil, false},
	{"Ring Gong", .Bells, lib_ring_gong, nil, false},
	{"Singing Bowl", .Bells, lib_singing_bowl, nil, false},
	{"Frost Chime", .Bells, lib_frost_chime, nil, false},
	// ---- leads ----
	{"Aurora", .Leads, lib_aurora, nil, false},
	{"Pulsar", .Leads, lib_pulsar, nil, false},
	{"Halo Lead", .Leads, lib_halo_lead, nil, false},
	{"Ion Pluck", .Leads, lib_ion_pluck, nil, false},
	// ---- bass ----
	{"Sub Orbit", .Bass, lib_sub_orbit, nil, false},
	{"Void Drone", .Bass, lib_void_drone, nil, false},
	{"Event Horizon", .Bass, lib_event_horizon, nil, false},
	{"Dark Matter", .Bass, lib_dark_matter, nil, false},
	{"Rubber Bass", .Bass, lib_rubber_bass, nil, false},
	// ---- effects ----
	{"Solar Wind", .Effects, lib_solar_wind, nil, false},
	{"Comet", .Effects, lib_comet, nil, false},
	{"Sonar Ping", .Effects, lib_sonar_ping, nil, false},
	{"Static Hiss", .Effects, lib_static_hiss, nil, false},
	{"Dust Shimmer", .Effects, lib_dust_shimmer, nil, false},
	// ---- drums ----
	{"Standard Drums", .Drums, nil, lib_standard_drums, true},
}

library_count :: proc() -> int {
	return len(LIBRARY)
}

library_name :: proc(i: int) -> string {
	return LIBRARY[clamp(i, 0, len(LIBRARY) - 1)].name
}

library_category :: proc(i: int) -> Lib_Category {
	return LIBRARY[clamp(i, 0, len(LIBRARY) - 1)].category
}

library_category_name :: proc(c: Lib_Category) -> string {
	switch c {
	case .Basic:
		return "Basic"
	case .Drums:
		return "Drums"
	case .Strings:
		return "Strings"
	case .Pads:
		return "Pads"
	case .Keys:
		return "Keys"
	case .Plucked:
		return "Plucked"
	case .Bells:
		return "Bells"
	case .Leads:
		return "Leads"
	case .Bass:
		return "Bass"
	case .Effects:
		return "Effects"
	}
	return ""
}

// The index of the instrument with this name (exact match), or false.
library_find :: proc(name: string) -> (index: int, ok: bool) {
	for e, i in LIBRARY {
		if e.name == name {
			return i, true
		}
	}
	return 0, false
}

// A fresh instrument made from library entry `i`. The caller owns it: give it to a song
// (song_add_instrument) or free it (instrument_destroy). The recordings of an entry are shared
// (cached) and stay alive for good.
library_instrument :: proc(i: int) -> ^Instrument {
	e := LIBRARY[clamp(i, 0, len(LIBRARY) - 1)]
	if e.build != nil {
		return e.build()
	}
	return instrument_synth(e.make(), e.name)
}

// Whether library entry `i` plays recordings (so a song that uses it carries them).
library_has_samples :: proc(i: int) -> bool {
	return LIBRARY[clamp(i, 0, len(LIBRARY) - 1)].samples
}

// ---- drums ----------------------------------------------------------------------------------------
//
// The drum kit is an instrument of sample zones. Its recordings are the 15 distinct drum sounds that the
// synthesizer makes (patch_kick and the others in patch.odin), rendered once, offline, to 16 bit PCM
// at 44.1 kHz, the first time the kit is asked for. The zones follow the General MIDI drum map:
// 35/36 kick, 37 rim, 38 and 40 snare, 39 clap, six toms, 42 and 44 closed hat, 46 open hat (the three
// hats choke each other), cymbals, 56 cowbell; every other key plays a closed hat.

DRUM_SOUNDS :: 15
DRUM_RATE :: 44100
DRUM_MAX_FRAMES :: DRUM_RATE * 5 / 2
@(rodata)
DRUM_TOM_KEYS := [6]int{41, 43, 45, 47, 48, 50}
@(rodata)
DRUM_SOUND_KEY := [DRUM_SOUNDS]int{36, 37, 38, 39, 41, 43, 45, 47, 48, 50, 42, 46, 49, 51, 56}
@(rodata)
DRUM_SOUND_NAMES := [DRUM_SOUNDS]string {
	"Kick",
	"Rim",
	"Snare",
	"Clap",
	"Tom 1",
	"Tom 2",
	"Tom 3",
	"Tom 4",
	"Tom 5",
	"Tom 6",
	"Hi-Hat Closed",
	"Hi-Hat Open",
	"Cymbal Long",
	"Cymbal Short",
	"Cowbell",
}

// Which of the 15 sounds the General MIDI drum map plays on `key`.
drum_sound_of_key :: proc(key: int) -> int {
	switch key {
	case 35, 36:
		return 0
	case 37:
		return 1
	case 38, 40:
		return 2
	case 39:
		return 3
	case 41:
		return 4
	case 43:
		return 5
	case 45:
		return 6
	case 47:
		return 7
	case 48:
		return 8
	case 50:
		return 9
	case 46:
		return 11
	case 49, 52, 55, 57:
		return 12
	case 51, 53, 59:
		return 13
	case 56:
		return 14
	}
	return 10
}

// The synthesizer patch that makes drum sound `id`.
drum_sound_patch :: proc(id: int) -> Patch {
	switch id {
	case 0:
		return patch_kick()
	case 1:
		return patch_rim()
	case 2:
		return patch_snare()
	case 3:
		return patch_clap()
	case 4 ..= 9:
		hz := 80 + 14 * f32(DRUM_TOM_KEYS[id - 4] - 41)
		return patch_tom(hz)
	case 11:
		return patch_hat(true)
	case 12:
		return patch_cymbal(1.3)
	case 13:
		return patch_cymbal(0.55)
	case 14:
		return patch_cowbell()
	}
	return patch_hat(false)
}

Drum_Cache_Entry :: struct {
	sample: ^Sample,
	peak:   f32, // the loudness the synthesizer made it at (before it was normalised)
}

drum_cache: [DRUM_SOUNDS]Drum_Cache_Entry
drum_lock: sync.Mutex // songs may be loaded on several threads

// Renders drum sound `id` with the synthesizer: one note on a channel panned hard left (so the left
// output is the whole sound), full velocity, played to its end. Returns the recording, normalised to a
// peak of 0.9, and the peak it had before.
drum_render :: proc(id: int) -> (^Sample, f32) {
	syn := new(Synth)
	defer free(syn)
	synth_init(syn, f32(DRUM_RATE))
	c := &syn.channels[0]
	c.reverb = 0
	c.delay = 0
	c.volume = 1
	c.pan = -1
	synth_voice_start(syn, 0, DRUM_SOUND_KEY[id], 1, drum_sound_patch(id))

	BLOCK :: 512
	out: [dynamic]f32
	defer delete(out)
	reserve(&out, DRUM_RATE)
	l, r, send, dsend: [BLOCK]f32
	for len(out) < DRUM_MAX_FRAMES {
		l = {}
		r = {}
		send = {}
		dsend = {}
		synth_render(syn, l[:], r[:], send[:], dsend[:], BLOCK)
		append(&out, ..l[:])
		if synth_active_voices(syn) == 0 {
			break
		}
	}
	pk: f32 = 0
	for v in out {
		pk = max(pk, abs(v))
	}
	if pk < 0.00001 {
		pk = 1
	}
	n := len(out)
	data := make([]i16, n, context.temp_allocator)
	for v, i in out {
		data[i] = i16(clamp(math.round_f32(v / pk * 0.9 * 32767), -32767, 32767))
	}
	for n > 2 && abs(i32(data[n - 1])) < 3 { // the silent end of the tail
		n -= 1
	}
	return sample_new(data[:n], DRUM_RATE, DRUM_SOUND_NAMES[id]), pk
}

// Drum sound `id` as a recording (rendered the first time, then kept) and its original loudness.
drum_sound :: proc(id: int) -> (^Sample, f32) {
	sync.mutex_lock(&drum_lock)
	defer sync.mutex_unlock(&drum_lock)
	e := &drum_cache[clamp(id, 0, DRUM_SOUNDS - 1)]
	if e.sample == nil {
		e.sample, e.peak = drum_render(clamp(id, 0, DRUM_SOUNDS - 1))
	}
	return e.sample, e.peak
}

// The General MIDI drum kit: sample zones over the rendered drum sounds.
lib_standard_drums :: proc() -> ^Instrument {
	inst := instrument_empty("Standard Drums")
	key := 0
	for key < 128 {
		id := drum_sound_of_key(key)
		last := key
		for last + 1 < 128 && drum_sound_of_key(last + 1) == id {
			last += 1
		}
		sm, pk := drum_sound(id)
		group := 1 if id == 10 || id == 11 else 0 // the hats choke each other
		// The recording is normalised to 0.9 and the zone gain makes that 0.35: the volume brings it
		// back to the loudness the synthesizer played the sound at.
		z := zone_sample(key, last, sm, pitched = false, one_shot = true, volume = pk / 0.35, group = group)
		zone_resolve(&z, sm)
		append(&inst.zones, z)
		key = last + 1
	}
	return inst
}

// ---- strings ------------------------------------------------------------------------------------

// The classic string machine: three detuned saws, a little chorus, a soft attack.
lib_synth_strings :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.6, 0, 0.5}
	p.osc[1] = {.Saw, 0.2, 12.05, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.2
	p.chorus_rate = 0.55
	p.amp_env = {0.25, 0.4, 0.9, 0.5}
	p.filter = {.Low_Pass, 3000, 0.1, 0.6, 0.6}
	p.filter_env = {0.3, 0.8, 0.7, 0.5}
	p.vibrato_rate = 5.2
	p.vibrato_depth = 0.03
	p.vibrato_delay = 0.6
	p.volume = 0.191
	p.velocity_sens = 0.4
	return p
}

// Five detuned saws and a darker body: a big, slow-moving section.
lib_string_ensemble :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.6, 0, 0.5}
	p.osc[1] = {.Triangle, 0.25, -12, 0.5}
	p.unison = 5
	p.unison_detune = 0
	p.chorus_depth = 0.22
	p.chorus_rate = 0.35
	p.amp_env = {0.5, 0.5, 0.9, 0.75}
	p.filter = {.Low_Pass, 2400, 0.1, 1.2, 0.6}
	p.filter_env = {0.6, 1.0, 0.65, 0.6}
	p.vibrato_rate = 5.5
	p.vibrato_depth = 0.05
	p.vibrato_delay = 0.7
	p.volume = 0.168
	p.velocity_sens = 0.35
	return p
}

// Bright and swirling: lots of chorus, a thin pulse on top.
lib_solina_strings :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.6, 0, 0.5}
	p.osc[1] = {.Square, 0.14, 12, 0.3}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.26
	p.chorus_rate = 0.8
	p.amp_env = {0.12, 0.3, 0.92, 0.35}
	p.filter = {.Low_Pass, 4800, 0.08, 0.4, 0.5}
	p.filter_env = {0.15, 0.6, 0.8, 0.4}
	p.volume = 0.221
	p.velocity_sens = 0.35
	return p
}

// A cinematic swell: the string sound takes over a second to arrive and just as long to leave.
lib_slow_strings :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.55, 0, 0.5}
	p.osc[1] = {.Triangle, 0.3, -12, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.2
	p.chorus_rate = 0.3
	p.amp_env = {1.4, 1.0, 0.95, 1.8}
	p.filter = {.Low_Pass, 1700, 0.1, 1.5, 0.5}
	p.filter_env = {1.8, 1.5, 0.6, 1.5}
	p.vibrato_rate = 5.0
	p.vibrato_depth = 0.05
	p.vibrato_delay = 1.5
	p.volume = 0.263
	p.velocity_sens = 0.3
	return p
}

// Strings bowed fast: the loudness shivers at about 8 Hz.
lib_tremolo_strings :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.6, 0, 0.5}
	p.osc[1] = {.Saw, 0.15, 12, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.2
	p.chorus_rate = 0.5
	p.amp_env = {0.2, 0.3, 0.95, 0.3}
	p.filter = {.Low_Pass, 3200, 0.1, 0.5, 0.6}
	p.filter_env = {0.2, 0.5, 0.8, 0.3}
	p.tremolo_depth = 0.55
	p.tremolo_rate = 8.5
	p.volume = 0.235
	p.velocity_sens = 0.4
	return p
}

// Short, detached bow strokes with a bit of bite at the start.
lib_staccato_strings :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.6, 0, 0.5}
	p.osc[1] = {.Saw, 0.15, 12, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.15
	p.chorus_rate = 0.6
	p.amp_env = {0.025, 0.18, 0.35, 0.1}
	p.filter = {.Low_Pass, 1800, 0.15, 2.0, 0.6}
	p.filter_env = {0.01, 0.15, 0.3, 0.1}
	p.volume = 0.303
	p.velocity_sens = 0.7
	return p
}

// A low, warm section with a cello-like vibrato.
lib_cello_section :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.6, 0, 0.5}
	p.osc[1] = {.Square, 0.2, -12, 0.4}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.18
	p.chorus_rate = 0.45
	p.amp_env = {0.12, 0.3, 0.9, 0.4}
	p.filter = {.Low_Pass, 1300, 0.15, 1.3, 0.5}
	p.filter_env = {0.15, 0.4, 0.6, 0.3}
	p.vibrato_rate = 5.0
	p.vibrato_depth = 0.12
	p.vibrato_delay = 0.35
	p.volume = 0.201
	p.velocity_sens = 0.5
	return p
}

// High and singing: a bright section with a lively vibrato.
lib_violin_section :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.65, 0, 0.5}
	p.osc[1] = {.Saw, 0.12, 12, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.2
	p.chorus_rate = 0.6
	p.amp_env = {0.1, 0.3, 0.9, 0.35}
	p.filter = {.Low_Pass, 3800, 0.12, 1.0, 0.7}
	p.filter_env = {0.12, 0.4, 0.7, 0.3}
	p.vibrato_rate = 5.8
	p.vibrato_depth = 0.14
	p.vibrato_delay = 0.4
	p.volume = 0.187
	p.velocity_sens = 0.5
	return p
}

// ---- pads -----------------------------------------------------------------------------------------

// Rounded and friendly: triangles with a saw underneath, the top rolled off.
lib_warm_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 0.7, 0, 0.5}
	p.osc[1] = {.Saw, 0.15, -12, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.2
	p.chorus_rate = 0.3
	p.amp_env = {1.0, 1.0, 0.85, 1.8}
	p.filter = {.Low_Pass, 1100, 0.15, 0.8, 0.4}
	p.filter_env = {1.2, 1.5, 0.6, 1.5}
	p.volume = 0.273
	p.velocity_sens = 0.3
	return p
}

// Even softer: almost sines, no edge at all.
lib_soft_warm_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 0.7, 0, 0.5}
	p.osc[1] = {.Triangle, 0.3, 12, 0.5}
	p.chorus_depth = 0.12
	p.chorus_rate = 0.25
	p.tremolo_depth = 0.08
	p.tremolo_rate = 0.3
	p.amp_env = {1.4, 1.0, 0.9, 2.2}
	p.filter = {.Low_Pass, 900, 0.1, 0.5, 0.4}
	p.filter_env = {1.6, 1.5, 0.7, 2.0}
	p.volume = 0.188
	p.velocity_sens = 0.25
	return p
}

// A pulse and a saw with a resonant sweep in the filter.
lib_analog_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Square, 0.5, 0, 0.4}
	p.osc[1] = {.Saw, 0.3, 12, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.2
	p.chorus_rate = 0.25
	p.amp_env = {0.9, 1.0, 0.85, 1.6}
	p.filter = {.Low_Pass, 1500, 0.28, 1.4, 0.4}
	p.filter_env = {0.9, 1.8, 0.45, 1.5}
	p.vibrato_rate = 0.4
	p.vibrato_depth = 0.06
	p.vibrato_delay = 1
	p.volume = 0.161
	p.velocity_sens = 0.3
	return p
}

// Dark and smooth with a slow shiver in the loudness.
lib_velvet_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 0.65, 0, 0.5}
	p.osc[1] = {.Sine, 0.4, -12, 0.5}
	p.amp_env = {1.2, 1.0, 0.9, 2.5}
	p.filter = {.Low_Pass, 700, 0.12, 0.7, 0.4}
	p.filter_env = {1.5, 1.5, 0.7, 2.0}
	p.tremolo_depth = 0.12
	p.tremolo_rate = 0.25
	p.volume = 0.216
	p.velocity_sens = 0.25
	return p
}

// Starts dark and opens up slowly, like light coming over a horizon.
lib_sunrise_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.55, 0, 0.5}
	p.osc[1] = {.Triangle, 0.3, 12, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.2
	p.chorus_rate = 0.3
	p.amp_env = {1.5, 1.0, 0.9, 2.5}
	p.filter = {.Low_Pass, 380, 0.18, 3.2, 0.3}
	p.filter_env = {3.0, 2.5, 0.8, 2.5}
	p.volume = 0.24
	p.velocity_sens = 0.3
	return p
}

// Low and slow, with a sub octave and a long, dim tail.
lib_dusk_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.4, 0, 0.5}
	p.osc[1] = {.Triangle, 0.5, -12, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.18
	p.chorus_rate = 0.2
	p.amp_env = {1.8, 1.0, 0.9, 3.0}
	p.filter = {.Low_Pass, 520, 0.15, 1.0, 0.3}
	p.filter_env = {2.0, 2.0, 0.6, 2.5}
	p.vibrato_rate = 0.3
	p.vibrato_depth = 0.05
	p.vibrato_delay = 2
	p.volume = 0.259
	p.velocity_sens = 0.25
	return p
}

// Voices singing "aah": detuned saws through a resonant filter, with a whisper of breath.
lib_choir_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.6, 0, 0.5}
	p.osc[1] = {.Noise, 0.03, 0, 0.5}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.2
	p.chorus_rate = 0.5
	p.amp_env = {0.6, 0.5, 0.9, 1.0}
	p.filter = {.Low_Pass, 1400, 0.42, 0.5, 0.3}
	p.filter_env = {0.7, 1.0, 0.7, 0.8}
	p.vibrato_rate = 5.0
	p.vibrato_depth = 0.1
	p.vibrato_delay = 0.8
	p.volume = 0.192
	p.velocity_sens = 0.3
	return p
}

// ---- keys ---------------------------------------------------------------------------------------------

// The warm bell of a tine piano: FM with equal ratio, the bark dies away, a gentle tremolo.
lib_epiano_rhodes :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 0.03, 0.5}
	p.fm = 1.5
	p.amp_env = {0.002, 2.2, 0.06, 0.3}
	p.filter_env = {0.001, 0.4, 0.22, 0.3}
	p.tremolo_depth = 0.14
	p.tremolo_rate = 4.8
	p.volume = 0.323
	p.velocity_sens = 0.8
	return p
}

// Reedy and nasal: a triangle carrier, higher FM, a filter that closes over the note.
lib_epiano_wurly :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 12, 0.5}
	p.fm = 2.0
	p.amp_env = {0.002, 1.3, 0.1, 0.25}
	p.filter = {.Low_Pass, 3800, 0.1, 0.8, 0.5}
	p.filter_env = {0.001, 0.2, 0.2, 0.2}
	p.tremolo_depth = 0.2
	p.tremolo_rate = 5.5
	p.volume = 0.604
	p.velocity_sens = 0.85
	return p
}

// A glassy FM electric piano in the style of the early digital synths.
lib_epiano_fm :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 0, 0.5}
	p.fm = 2.1
	p.amp_env = {0.001, 1.6, 0.1, 0.3}
	p.filter_env = {0.001, 0.5, 0.12, 0.3}
	p.volume = 0.353
	p.velocity_sens = 0.85
	return p
}

// A soft electric piano that drifts: the pitch of the modulator wobbles a little.
lib_epiano_dream :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 0.05, 0.5}
	p.fm = 1.0
	p.chorus_depth = 0.15
	p.chorus_rate = 0.6
	p.amp_env = {0.006, 2.6, 0.15, 0.8}
	p.filter_env = {0.002, 0.8, 0.3, 0.6}
	p.tremolo_depth = 0.18
	p.tremolo_rate = 3.2
	p.volume = 0.277
	p.velocity_sens = 0.6
	return p
}

// Bright and glassy: an inharmonic FM bell on a piano-length note.
lib_crystal_piano :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, lib_ratio(3.5), 0.5}
	p.fm = 2.4
	p.amp_env = {0.001, 3.0, 0, 0.9}
	p.filter_env = {0.001, 0.5, 0.04, 0.5}
	p.volume = 0.25
	p.velocity_sens = 0.7
	return p
}

// A small, pure metal chime.
lib_celesta :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, lib_ratio(4), 0.5}
	p.fm = 0.9
	p.amp_env = {0.001, 1.6, 0, 0.5}
	p.filter_env = {0.001, 0.25, 0, 0.3}
	p.volume = 0.3
	p.velocity_sens = 0.6
	return p
}

// Tinkling comb: a harder, shorter bell.
lib_music_box :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, lib_ratio(5.4), 0.5}
	p.fm = 1.8
	p.amp_env = {0.001, 1.1, 0, 0.3}
	p.filter_env = {0.001, 0.12, 0, 0.2}
	p.volume = 0.351
	p.velocity_sens = 0.6
	return p
}

// A felt-muted piano: round, close and quiet.
lib_soft_piano :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 0.8, 0, 0.5}
	p.osc[1] = {.Sine, 0.25, 12, 0.5}
	p.amp_env = {0.004, 2.2, 0.05, 0.4}
	p.filter = {.Low_Pass, 1100, 0.05, 1.4, 0.7}
	p.filter_env = {0.002, 0.5, 0.1, 0.3}
	p.volume = 0.387
	p.velocity_sens = 0.7
	return p
}

// A concert grand with the lid open.
lib_bright_piano :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.65, 0, 0.5}
	p.osc[1] = {.Triangle, 0.35, 12, 0.5}
	p.amp_env = {0.001, 1.8, 0.1, 0.3}
	p.filter = {.Low_Pass, 2600, 0.08, 2.0, 0.8}
	p.filter_env = {0.001, 0.4, 0.1, 0.3}
	p.volume = 0.484
	p.velocity_sens = 0.8
	return p
}

// A piano that has not been tuned for a while.
lib_honky_piano :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.6, 0, 0.5}
	p.osc[1] = {.Triangle, 0.3, 12, 0.5}
	p.unison = 3
	p.unison_detune = 0.22
	p.amp_env = {0.001, 1.4, 0.08, 0.25}
	p.filter = {.Low_Pass, 2200, 0.1, 2.2, 0.7}
	p.filter_env = {0.001, 0.35, 0.1, 0.25}
	p.volume = 0.547
	p.velocity_sens = 0.75
	return p
}

// A piano from a dream: soft attack, long ring, a little motion.
lib_dream_keys :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 0.7, 0, 0.5}
	p.osc[1] = {.Sine, 0.4, 12, 0.5}
	p.unison = 2
	p.unison_detune = 0
	p.chorus_depth = 0.15
	p.chorus_rate = 0.5
	p.amp_env = {0.03, 4.0, 0.2, 1.8}
	p.filter = {.Low_Pass, 1500, 0.05, 1.2, 0.7}
	p.filter_env = {0.02, 1.0, 0.3, 1.0}
	p.tremolo_depth = 0.08
	p.tremolo_rate = 3.0
	p.volume = 0.314
	p.velocity_sens = 0.6
	return p
}

// ---- plucked ---------------------------------------------------------------------------------------------

// A string plucked with a finger: Karplus-Strong.
lib_pizzicato :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Pluck, 1, 0, 0.5}
	p.osc[1].level = 0
	p.string_decay = 0.5
	p.string_bright = 0.6
	p.amp_env = {0.001, 5, 1, 0.07}
	p.volume = 0.626
	p.velocity_sens = 0.7
	return p
}

// The whole section plucking at once: a longer ring and a soft, short body underneath.
lib_pizzicato_section :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Pluck, 1, 0, 0.5}
	p.osc[1] = {.Triangle, 0.14, 12.07, 0.5}
	p.string_decay = 0.8
	p.string_bright = 0.45
	p.amp_env = {0.001, 0.9, 0, 0.08}
	p.volume = 0.563
	p.velocity_sens = 0.6
	return p
}

// Dry and clipped.
lib_pizzicato_staccato :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Pluck, 1, 0, 0.5}
	p.osc[1].level = 0
	p.string_decay = 0.2
	p.string_bright = 0.7
	p.amp_env = {0.001, 0.25, 0, 0.04}
	p.volume = 0.7
	p.velocity_sens = 0.7
	return p
}

// An upright bass plucked with the finger.
lib_pizzicato_bass :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Pluck, 1, 0, 0.5}
	p.osc[1].level = 0
	p.string_decay = 1.0
	p.string_bright = 0.3
	p.amp_env = {0.001, 5, 1, 0.1}
	p.filter = {.Low_Pass, 1200, 0.1, 0, 0.4}
	p.volume = 0.544
	p.velocity_sens = 0.6
	return p
}

// A harp string: bright start, a long ring.
lib_harp :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Pluck, 1, 0, 0.5}
	p.osc[1].level = 0
	p.string_decay = 2.6
	p.string_bright = 0.55
	p.amp_env = {0.001, 5, 1, 0.4}
	p.volume = 0.395
	p.velocity_sens = 0.6
	return p
}

// A nylon string guitar: softer and warmer than the harp.
lib_nylon_guitar :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Pluck, 1, 0, 0.5}
	p.osc[1].level = 0
	p.string_decay = 1.5
	p.string_bright = 0.4
	p.amp_env = {0.001, 5, 1, 0.15}
	p.filter = {.Low_Pass, 3500, 0.1, 0, 0.5}
	p.volume = 0.424
	p.velocity_sens = 0.65
	return p
}

// A glassy bell that blooms into a soft, shimmering pad (in the manner of the classic digital "Fantasia"):
// FM with the modulator an octave up and a few cents sharp, its index following the filter envelope from a
// bright strike down to a gentle glow while the key is held; the chorus slowly moves the modulator.
lib_fantasia :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 12.06, 0.5}
	p.fm = 2.6
	p.filter_env = {0.001, 0.7, 0.28, 1.8}
	p.filter = {.Low_Pass, 9000, 0.05, 0, 0}
	p.amp_env = {0.004, 1.4, 0.55, 2.4}
	p.chorus_depth = 0.12
	p.chorus_rate = 0.45
	p.vibrato_rate = 4.5
	p.vibrato_depth = 0.05
	p.vibrato_delay = 1.0
	p.volume = 0.227
	p.velocity_sens = 0.5
	return p
}

// A banjo: a very bright, short string with a thin, twangy top (the drum head has no low end; the
// high-pass follows the key, so low notes keep the same thin colour).
lib_banjo :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Pluck, 1, 0, 0.5}
	p.osc[1].level = 0
	p.string_decay = 0.7
	p.string_bright = 0.92
	p.amp_env = {0.001, 5, 1, 0.1}
	p.filter = {.High_Pass, 280, 0.25, 0, 1.0}
	p.volume = 0.64
	p.velocity_sens = 0.6
	return p
}

// An electric guitar through an overdriven amp: a bright string with a saw underneath that keeps the
// note singing once the string fades, pushed into the drive and rounded off by the speaker (low-pass).
lib_overdrive_guitar :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Pluck, 1, 0, 0.5}
	p.osc[1] = {.Saw, 0.25, 0.08, 0.5}
	p.string_decay = 3.0
	p.string_bright = 0.75
	p.drive = 0.65
	p.amp_env = {0.002, 1.5, 0.75, 0.12}
	p.filter = {.Low_Pass, 2800, 0.25, 0, 0.3}
	p.vibrato_rate = 5.5
	p.vibrato_depth = 0.12
	p.vibrato_delay = 0.5
	p.volume = 0.094
	p.velocity_sens = 0.5
	return p
}

// ---- the space instruments ------------------------------------------------------------------------

// Warm, wide, very slow cloud of detuned saws.
lib_nebula_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.5, -0.14, 0.5}
	p.osc[1] = {.Saw, 0.5, 0.14, 0.5}
	p.amp_env = {1.6, 1.0, 0.9, 6.0}
	p.filter = {.Low_Pass, 650, 0.15, 1.4, 0.3}
	p.filter_env = {2.5, 3.0, 0.5, 4.0}
	p.vibrato_rate = 0.35
	p.vibrato_depth = 0.1
	p.vibrato_delay = 2
	p.volume = 0.22
	p.velocity_sens = 0.4
	return p
}

// A deep, almost motionless tone, like empty space.
lib_void_drone :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 0.8, 0, 0.5}
	p.osc[1] = {.Triangle, 0.45, 12.04, 0.5}
	p.amp_env = {2.5, 1.0, 1.0, 6.0}
	p.filter = {.Low_Pass, 420, 0.2, 0.6, 0.2}
	p.filter_env = {3.0, 3.0, 0.8, 5.0}
	p.vibrato_rate = 0.2
	p.vibrato_depth = 0.05
	p.vibrato_delay = 3
	p.volume = 0.38
	p.velocity_sens = 0.3
	return p
}

// Glassy, inharmonic FM chime that ends as a pure sine.
lib_starlight :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 26.5, 0.5} // not a whole-number ratio: glassy, a little out of tune
	p.fm = 2.4
	p.amp_env = {0.002, 3.0, 0, 2.5}
	p.filter_env = {0.001, 0.8, 0, 1.0} // the FM index follows this: bright start, pure end
	p.volume = 0.26
	p.velocity_sens = 0.6
	return p
}

// Airy lead that swells in and shimmers.
lib_aurora :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 0.6, 0, 0.5}
	p.osc[1] = {.Sine, 0.35, 19.04, 0.5} // a twelfth up: a hint of a choir
	p.amp_env = {1.1, 0.6, 0.8, 2.5}
	p.filter = {.Low_Pass, 2600, 0.1, 0, 0.4}
	p.vibrato_rate = 4.6
	p.vibrato_depth = 0.16
	p.vibrato_delay = 1.0
	p.volume = 0.24
	p.velocity_sens = 0.4
	return p
}

// Filtered noise that rises and falls like a gust.
lib_solar_wind :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Noise, 1, 0, 0.5}
	p.osc[1].level = 0
	p.amp_env = {3.2, 1.5, 0.7, 4.0}
	p.filter = {.Band_Pass, 420, 0.55, 2.3, 0.6} // the note picks the colour of the gust
	p.filter_env = {3.8, 2.5, 0.4, 4.0}
	p.volume = 0.35
	p.velocity_sens = 0.3
	return p
}

// A huge metallic strike: low, long and clangy at first.
lib_ring_gong :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 17.31, 0.5} // ratio about 2.72
	p.fm = 3.0
	p.amp_env = {0.004, 7.0, 0, 5.5}
	p.filter_env = {0.002, 2.5, 0, 2.0}
	p.volume = 0.4
	p.velocity_sens = 0.6
	return p
}

// A cold, hollow pad: pulse plus triangle.
lib_europa_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Square, 0.35, 0, 0.38}
	p.osc[1] = {.Triangle, 0.5, 12.05, 0.5}
	p.amp_env = {1.4, 0.8, 0.85, 5.0}
	p.filter = {.Low_Pass, 1500, 0.3, 0.8, 0.3}
	p.filter_env = {2.0, 2.5, 0.5, 3.5}
	p.vibrato_rate = 0.5
	p.vibrato_depth = 0.08
	p.vibrato_delay = 1.5
	p.volume = 0.2
	p.velocity_sens = 0.4
	return p
}

// A short sonar-like blip, meant to be repeated.
lib_pulsar :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Square, 0.6, 0, 0.2}
	p.osc[1] = {.Triangle, 0.35, 12, 0.5}
	p.amp_env = {0.001, 0.16, 0, 0.12}
	p.filter = {.Low_Pass, 1200, 0.35, 2.2, 0.5}
	p.filter_env = {0.001, 0.14, 0, 0.1}
	p.pitch_env_semitones = -1.5 // a tiny upward chirp
	p.pitch_env_time = 0.03
	p.volume = 0.30
	p.velocity_sens = 0.6
	return p
}

// Soft FM music-box keys.
lib_lunar_keys :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 12, 0.5}
	p.fm = 1.0
	p.amp_env = {0.003, 2.4, 0, 1.0}
	p.filter_env = {0.001, 0.5, 0.12, 0.6}
	p.volume = 0.3
	p.velocity_sens = 0.65
	return p
}

// A round sub bass.
lib_sub_orbit :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 0.85, 0, 0.5}
	p.osc[1] = {.Triangle, 0.4, 12, 0.5}
	p.amp_env = {0.06, 0.4, 0.8, 0.7}
	p.filter = {.Low_Pass, 320, 0.15, 1.0, 0.3}
	p.filter_env = {0.03, 0.4, 0.2, 0.4}
	p.volume = 0.45
	return p
}

// A round, bouncy synth bass: a resonant low-pass that snaps open at the start of each note and
// quickly closes again (the "rubber" boing), over a square and a sine an octave below.
lib_rubber_bass :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Square, 0.7, 0, 0.5}
	p.osc[1] = {.Sine, 0.6, -12, 0.5}
	p.amp_env = {0.004, 0.5, 0.65, 0.09}
	p.filter = {.Low_Pass, 180, 0.6, 3.2, 0.5}
	p.filter_env = {0.003, 0.22, 0.15, 0.1}
	p.drive = 0.15
	p.volume = 0.334
	p.velocity_sens = 0.55
	return p
}

// A bright tone that streaks down into its pitch.
lib_comet :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 0.8, 0, 0.5}
	p.osc[1] = {.Sine, 0.35, 12, 0.5}
	p.pitch_env_semitones = 24 // starts two octaves up and falls into the note
	p.pitch_env_time = 0.4
	p.amp_env = {0.002, 1.8, 0, 1.4}
	p.filter = {.Low_Pass, 3500, 0.1, 0, 0}
	p.volume = 0.4
	return p
}

// ---- more space instruments (added later; the entries above are unchanged) ----------------------------------

// Thin, bright and shimmering: a string section heard through ice.
lib_glass_strings :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.5, 0, 0.5}
	p.osc[1] = {.Square, 0.2, 12, 0.2}
	p.unison = 3
	p.unison_detune = 0
	p.chorus_depth = 0.3
	p.chorus_rate = 0.7
	p.amp_env = {0.5, 0.5, 0.9, 0.9}
	p.filter = {.Low_Pass, 5200, 0.2, 0.5, 0.6}
	p.filter_env = {0.6, 0.8, 0.7, 0.8}
	p.vibrato_rate = 5.4
	p.vibrato_depth = 0.04
	p.vibrato_delay = 0.8
	p.volume = 0.2
	p.velocity_sens = 0.35
	return p
}

// A wide, airy pad of four detuned triangles that slowly brightens.
lib_aether_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 0.55, 0, 0.5}
	p.osc[1] = {.Saw, 0.12, 12, 0.5}
	p.unison = 4
	p.unison_detune = 0.18
	p.chorus_depth = 0.3
	p.chorus_rate = 0.3
	p.amp_env = {2.2, 1.0, 0.9, 6.0}
	p.filter = {.Low_Pass, 1800, 0.12, 1.4, 0.5}
	p.filter_env = {3.0, 3.0, 0.55, 4.0}
	p.vibrato_rate = 0.4
	p.vibrato_depth = 0.07
	p.vibrato_delay = 2
	p.volume = 0.274
	p.velocity_sens = 0.35
	return p
}

// A glassy FM pad: the overtones swell in and fade away again with every note.
lib_cryo_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 12.02, 0.5}
	p.fm = 0.9
	p.chorus_depth = 0.12
	p.chorus_rate = 0.25
	p.amp_env = {2.0, 1.0, 0.9, 5.0}
	p.filter_env = {3.2, 3.0, 0.45, 4.0}
	p.tremolo_depth = 0.08
	p.tremolo_rate = 0.35
	p.volume = 0.135
	p.velocity_sens = 0.35
	return p
}

// Dark and heavy: a slow rumble of low detuned saws behind a closed filter.
lib_deep_field_pad :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.5, 0, 0.5}
	p.osc[1] = {.Square, 0.3, -12, 0.45}
	p.unison = 3
	p.unison_detune = 0.1
	p.chorus_depth = 0.2
	p.chorus_rate = 0.2
	p.amp_env = {3.2, 1.0, 0.95, 7.0}
	p.filter = {.Low_Pass, 520, 0.25, 2.0, 0.3}
	p.filter_env = {4.0, 4.0, 0.5, 5.0}
	p.vibrato_rate = 0.3
	p.vibrato_depth = 0.06
	p.vibrato_delay = 3
	p.volume = 0.199
	p.velocity_sens = 0.3
	return p
}

// FM keys that start glassy and settle into a pure bell tone.
lib_frost_keys :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, lib_ratio(3), 0.5}
	p.fm = 1.3
	p.amp_env = {0.003, 1.8, 0, 1.2}
	p.filter_env = {0.001, 0.3, 0.05, 0.5}
	p.volume = 0.304
	p.velocity_sens = 0.65
	return p
}

// A quiet church organ: a mellow saw, a fifth and an octave up, a gentle tremulant.
lib_cathedral_organ :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.5, 0, 0.5}
	p.osc[1] = {.Sine, 0.4, 12, 0.5}
	p.unison = 2
	p.unison_detune = 0.06
	p.chorus_depth = 0.15
	p.chorus_rate = 0.5
	p.amp_env = {0.04, 0.2, 1.0, 0.35}
	p.filter = {.Low_Pass, 1900, 0.1, 0.3, 0.6}
	p.filter_env = {0.05, 0.3, 0.8, 0.3}
	p.tremolo_depth = 0.12
	p.tremolo_rate = 5.5
	p.volume = 0.176
	p.velocity_sens = 0.2
	return p
}

// A harp that rings for a long time, with a faint shimmer an octave up.
lib_zero_g_harp :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Pluck, 1, 0, 0.5}
	p.osc[1] = {.Sine, 0.07, 12, 0.5}
	p.string_decay = 4.5
	p.string_bright = 0.65
	p.amp_env = {0.001, 6, 1, 0.8}
	p.volume = 0.335
	p.velocity_sens = 0.6
	return p
}

// A thumb piano: a short, woody FM pluck.
lib_kalimba :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 24, 0.5}
	p.fm = 0.8
	p.amp_env = {0.001, 0.9, 0, 0.3}
	p.filter_env = {0.001, 0.12, 0, 0.1}
	p.volume = 0.248
	p.velocity_sens = 0.7
	return p
}

// A struck metal bowl: two almost equal tones that beat slowly against each other.
lib_singing_bowl :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 0.8, 0, 0.5}
	p.osc[1] = {.Sine, 0.4, 12.07, 0.5}
	p.amp_env = {0.01, 6.0, 0, 4.5}
	p.volume = 0.189
	p.velocity_sens = 0.6
	return p
}

// A high, brittle chime: five times the frequency in the modulator.
lib_frost_chime :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, lib_ratio(5.01), 0.5}
	p.fm = 1.6
	p.amp_env = {0.002, 2.2, 0, 1.6}
	p.filter_env = {0.001, 0.5, 0, 0.8}
	p.volume = 0.268
	p.velocity_sens = 0.6
	return p
}

// A soft, wide lead: detuned triangles with a late vibrato.
lib_halo_lead :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Triangle, 0.5, 0, 0.5}
	p.osc[1] = {.Saw, 0.15, 0.07, 0.5}
	p.unison = 3
	p.unison_detune = 0.1
	p.chorus_depth = 0.2
	p.chorus_rate = 0.45
	p.amp_env = {0.08, 0.3, 0.8, 0.9}
	p.filter = {.Low_Pass, 3200, 0.12, 0.8, 0.5}
	p.filter_env = {0.1, 0.5, 0.6, 0.6}
	p.vibrato_rate = 5.2
	p.vibrato_depth = 0.12
	p.vibrato_delay = 0.6
	p.volume = 0.279
	p.velocity_sens = 0.45
	return p
}

// A short synthetic pluck for arpeggios: the filter snaps shut after the attack.
lib_ion_pluck :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.55, 0, 0.5}
	p.osc[1] = {.Square, 0.25, 12, 0.3}
	p.amp_env = {0.002, 0.28, 0, 0.18}
	p.filter = {.Low_Pass, 650, 0.3, 3.0, 0.5}
	p.filter_env = {0.001, 0.2, 0, 0.12}
	p.volume = 0.435
	p.velocity_sens = 0.65
	return p
}

// A round bass with a punch of filter at the start of each note.
lib_event_horizon :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.5, 0, 0.5}
	p.osc[1] = {.Sine, 0.7, -12, 0.5}
	p.amp_env = {0.01, 0.5, 0.7, 0.3}
	p.filter = {.Low_Pass, 360, 0.25, 1.8, 0.3}
	p.filter_env = {0.005, 0.3, 0.15, 0.2}
	p.volume = 0.288
	p.velocity_sens = 0.5
	return p
}

// A huge, slow bass drone: five low saws that move against each other.
lib_dark_matter :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Saw, 0.55, 0, 0.5}
	p.osc[1] = {.Sine, 0.5, -12, 0.5}
	p.unison = 5
	p.unison_detune = 0.14
	p.chorus_depth = 0.15
	p.chorus_rate = 0.2
	p.amp_env = {0.9, 1.0, 1.0, 3.5}
	p.filter = {.Low_Pass, 240, 0.2, 1.0, 0.2}
	p.filter_env = {1.5, 2.0, 0.6, 2.5}
	p.volume = 0.303
	p.velocity_sens = 0.3
	return p
}

// A clean sonar ping that sinks a little in pitch as it fades.
lib_sonar_ping :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Sine, 0.9, 0, 0.5}
	p.osc[1] = {.Sine, 0.15, 12, 0.5}
	p.pitch_env_semitones = 0.6
	p.pitch_env_time = 0.15
	p.amp_env = {0.003, 2.2, 0, 1.4}
	p.volume = 0.258
	p.velocity_sens = 0.6
	return p
}

// A dry tick of high noise, like static or a tiny hi-hat.
lib_static_hiss :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Noise, 1, 0, 0.5}
	p.osc[1].level = 0
	p.amp_env = {0.001, 0.07, 0, 0.05}
	p.filter = {.High_Pass, 6500, 0.2, 0, 0}
	p.volume = 0.153
	p.velocity_sens = 0.7
	return p
}

// A glittering cloud of band-limited noise that swells in and out.
lib_dust_shimmer :: proc() -> Patch {
	p := patch_base()
	p.osc[0] = {.Noise, 1, 0, 0.5}
	p.osc[1].level = 0
	p.amp_env = {1.8, 1.5, 0.6, 3.0}
	p.filter = {.Band_Pass, 3800, 0.65, 1.2, 0.5}
	p.filter_env = {2.5, 2.0, 0.4, 3.0}
	p.tremolo_depth = 0.25
	p.tremolo_rate = 0.4
	p.volume = 0.11
	p.velocity_sens = 0.3
	return p
}
