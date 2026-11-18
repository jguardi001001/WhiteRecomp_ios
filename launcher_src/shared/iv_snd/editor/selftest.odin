package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import snd "shared:iv_snd"

// ---------------------------------------------------------------------------
// odin run shared/iv_snd/editor -collection:shared=shared -- --selftest
//
// Checks, without opening a window, that the project model does not lose anything:
// song -> project -> song keeps every note and renders to the same audio, the PSNG file
// round-trips (tracks and names too), and what the effect graphs and the tracks promise holds.
// ---------------------------------------------------------------------------

st_fail: int

check :: proc(ok: bool, what: string, args: ..any) {
	if !ok {
		st_fail += 1
		fmt.printf("FAIL: ")
		fmt.printfln(what, ..args)
	}
}

event_key_less :: proc(a, b: snd.Event) -> bool {
	if a.tick != b.tick {
		return a.tick < b.tick
	}
	if a.kind != b.kind {
		return a.kind < b.kind
	}
	if a.channel != b.channel {
		return a.channel < b.channel
	}
	if a.a != b.a {
		return a.a < b.a
	}
	if a.b != b.b {
		return a.b < b.b
	}
	return a.v < b.v
}

// An instrument as it is written to a file (to compare two of them).
instrument_bytes :: proc(inst: ^snd.Instrument) -> string {
	w: snd.Writer
	w.buf.allocator = context.temp_allocator
	snd.instrument_encode(&w, inst)
	return string(w.buf[:])
}

songs_equal :: proc(name: string, x, y: ^snd.Song) {
	check(x.ticks_per_beat == y.ticks_per_beat, "%s: ticks per beat", name)
	check(x.loop_start == y.loop_start && x.loop_end == y.loop_end, "%s: loop points", name)
	check(len(x.tracks) == len(y.tracks), "%s: track count %d vs %d", name, len(x.tracks), len(y.tracks))
	check(len(x.instruments) == len(y.instruments), "%s: instrument count %d vs %d", name, len(x.instruments), len(y.instruments))
	check(len(x.samples) == len(y.samples), "%s: sample count", name)
	for i in 0 ..< min(len(x.instruments), len(y.instruments)) {
		check(instrument_bytes(x.instruments[i]) == instrument_bytes(y.instruments[i]), "%s: instrument %d (%s) differs", name, i, snd.instrument_name(x.instruments[i]))
	}
	for ti in 0 ..< min(len(x.tracks), len(y.tracks)) {
		a := slice.clone(x.tracks[ti].events[:], context.temp_allocator)
		b := slice.clone(y.tracks[ti].events[:], context.temp_allocator)
		slice.stable_sort_by(a, event_key_less)
		slice.stable_sort_by(b, event_key_less)
		check(len(a) == len(b), "%s: track %d has %d vs %d events", name, ti, len(a), len(b))
		if len(a) == len(b) {
			for k in 0 ..< len(a) {
				if a[k] != b[k] {
					check(false, "%s: track %d event %d differs: %v vs %v", name, ti, k, a[k], b[k])
					break
				}
			}
		}
		check(x.tracks[ti].name == y.tracks[ti].name, "%s: track %d name", name, ti)
	}
}

samples_equal :: proc(name: string, a, b: []f32) {
	check(len(a) == len(b), "%s: audio length", name)
	worst: f32 = 0
	for i in 0 ..< min(len(a), len(b)) {
		worst = max(worst, abs(a[i] - b[i]))
	}
	check(worst < 1e-6, "%s: audio differs by %f", name, worst)
}


// ---- samples, root keys and the instrument library ------------------------------------------

// Renders one note of a patch on its own (the sound effect path) and returns the left channel.
render_patch_note :: proc(p: snd.Patch, key: int, seconds: f32, hold: f32) -> []i16 {
	a := new(snd.Audio)
	defer free(a)
	snd.audio_init(a, 44100)
	defer snd.audio_shutdown(a)
	a.master = 1
	snd.sfx_play_patch(a, p, key, hold, 0.8)
	frames := int(seconds * 44100)
	buf := make([]f32, frames * 2)
	defer delete(buf)
	pos := 0
	for pos < frames {
		n := min(frames - pos, 1024)
		snd.audio_render(a, buf[pos * 2:(pos + n) * 2])
		pos += n
	}
	out := make([]i16, frames)
	for i in 0 ..< frames {
		out[i] = i16(clamp(buf[i * 2] * 32767, -32768, 32767))
	}
	return out
}

// The same for one note of an instrument (the key picks the zone).
render_instrument_note :: proc(inst: ^snd.Instrument, key: int, seconds: f32, hold: f32) -> []i16 {
	a := new(snd.Audio)
	defer free(a)
	snd.audio_init(a, 44100)
	defer snd.audio_shutdown(a)
	a.master = 1
	snd.sfx_play_instrument(a, inst, key, hold, 0.8)
	frames := int(seconds * 44100)
	buf := make([]f32, frames * 2)
	defer delete(buf)
	pos := 0
	for pos < frames {
		n := min(frames - pos, 1024)
		snd.audio_render(a, buf[pos * 2:(pos + n) * 2])
		pos += n
	}
	out := make([]i16, frames)
	for i in 0 ..< frames {
		out[i] = i16(clamp(buf[i * 2] * 32767, -32768, 32767))
	}
	return out
}

// A tone defined with whole numbers only, so it is the same on every computer.
int_tone :: proc(kind: int, period: int, count: int) -> []i16 {
	d := make([]i16, count)
	for i in 0 ..< count {
		ph := i % period
		switch kind {
		case 0: // square
			d[i] = 20000 if ph * 2 < period else -20000
		case 1: // saw
			d[i] = i16(-20000 + 40000 * ph / period)
		case 2: // triangle
			h := ph * 2 / period
			x := ph * 2 % period
			v := 40000 * x / period
			d[i] = i16(-20000 + v) if h == 0 else i16(20000 - v)
		}
	}
	return d
}

run_sample_tests :: proc() {
	// The root key method is frozen: these results were recorded when it was written and
	// must never change (a failure here means the method was altered).
	Frozen :: struct {
		kind, period: int,
		key:          f32,
	}
	frozen := [?]Frozen{{0, 100, 69.04}, {1, 200, 57.04}, {2, 150, 62.02}, {0, 37, 86.26}, {1, 733, 34.55}, {2, 1000, 29.18}}
	for f in frozen {
		d := int_tone(f.kind, f.period, 44100)
		r := snd.sample_detect_root_v1(d, 44100)
		hz := 44100.0 / f64(f.period)
		exact := 69 + 12 * math.log2(hz / 440)
		check(r.pitched, "root: tone %v not pitched", f)
		check(abs(f64(r.key) - exact) < 0.1, "root: tone %v found %.2f, exact %.2f", f, r.key, exact)
		check(r.key == f.key, "root: FROZEN RESULT CHANGED for tone %v: %.2f (recorded %.2f)", f, r.key, f.key)
		delete(d)
	}

	// Sounds without a pitch.
	silence := make([]i16, 30000)
	check(!snd.sample_detect_root_v1(silence, 44100).pitched, "root: silence")
	delete(silence)
	noise := make([]i16, 44100)
	seed: u32 = 99
	for i in 0 ..< len(noise) {
		seed ~= seed << 13
		seed ~= seed >> 17
		seed ~= seed << 5
		noise[i] = i16(i32(seed) >> 17)
	}
	rn := snd.sample_detect_root_v1(noise, 44100)
	check(!rn.pitched && rn.key == 60, "root: noise gives C4 (%v)", rn)
	delete(noise)

	// Through a WAV file: import, instrument, save, load, render.
	ed_init()
	tone := int_tone(1, 168, 44100) // saw, 262.5 Hz: about C4
	fl := make([]f32, len(tone))
	for i in 0 ..< len(tone) {
		fl[i] = f32(tone[i]) / 32768
	}
	wav := snd.wav_encode(fl, 1, 44100)
	delete(fl)
	check(os.write_entire_file("selftest_tone.wav", wav) == nil, "write wav")
	delete(wav)
	ed.cur_track = 0
	check(file_import_wav("selftest_tone.wav"), "import wav")
	_ = os.remove("selftest_tone.wav")
	check(len(ed.p.samples) == 1 && len(ed.p.instruments) == 1, "import makes a recording and an instrument")
	inst := ed.p.instruments[0]
	check(len(inst.zones) == 1 && inst.zones[0].source == .Sample, "the instrument is one zone that plays a recording")
	sm := ed.p.samples[0]
	z0 := inst.zones[0]
	check(z0.pitched && z0.has_root && z0.root_known && abs(z0.root_key - 60.1) < 0.2 && z0.root_version == 1, "imported root %.2f", z0.root_key)
	check(z0.sample_id == 1 && z0.sample == sm && z0.key_lo == 0 && z0.key_hi == 127, "the zone holds all keys and names the recording")
	check(track_instrument(0) == 0 && track_label(0) == "selftest_tone", "name '%s'", track_label(0))
	root_before := z0.root_key
	frames_before := len(sm.data)
	data_before := slice.clone(sm.data) // as imported (the WAV file may round the numbers)
	defer delete(data_before)

	// A played note comes out at the right pitch: key 60 at the root, key 72 an octave up, key 48 an octave down.
	for k in ([]int{48, 60, 72, 79}) {
		out := render_instrument_note(inst, k, 1.0, 0.9)
		r := snd.sample_detect_root_v1(out, 44100)
		want := f32(k)
		check(r.pitched && abs(r.key - want) < 0.15, "sample played at key %d sounds at %.2f", k, r.key)
		delete(out)
	}

	// Save, load: the recording, the root key and the audio come back unchanged.
	ed.p.notes = nil
	ed.cursor_key = 64
	ed.cursor_tick = 0
	ed.cur_track = 0
	check(ed_insert_note(), "insert note on the sampler")
	song_a := project_to_song(&ed.p, .Save)
	audio_a := snd.render_song(&song_a, 2)
	check(file_save("selftest_s.psng"), "save with a recording")
	ed_set_project(project_new(), "")
	check(file_load("selftest_s.psng"), "load with a recording")
	check(len(ed.p.samples) == 1 && len(ed.p.instruments) == 1, "recording and instrument loaded")
	if len(ed.p.samples) == 1 && len(ed.p.instruments) == 1 {
		sl := ed.p.samples[0]
		zl := ed.p.instruments[0].zones[0]
		check(zl.has_root && zl.root_key == root_before && zl.root_version == 1 && len(sl.data) == frames_before, "root %.2f frames %d", zl.root_key, len(sl.data))
		check(slice.equal(sl.data, data_before), "recording data changed in the file")
		song_b := project_to_song(&ed.p, .Save)
		audio_b := snd.render_song(&song_b, 2)
		samples_equal("sampler project", audio_a, audio_b)
		peak: f32 = 0
		for v in audio_b {
			peak = max(peak, abs(v))
		}
		check(peak > 0.05, "the sampler is audible (peak %f)", peak)
		delete(audio_b)
		snd.song_destroy(&song_b)
	}
	_ = os.remove("selftest_s.psng")
	delete(audio_a)
	snd.song_destroy(&song_a)

	// The root key belongs to the zone: changing it is undone with the rest of the project.
	ed_set_project(project_new(), "")
	ed.cur_track = 0
	tone2 := int_tone(0, 100, 20000)
	smp := snd.sample_new(tone2, 44100, "t2")
	delete(tone2)
	ed_edit(false)
	ed_set_track_instrument(0, snd.instrument_from_sample(smp, "t2"), false)
	snd.sample_release(smp)
	ed_edit(false) // a snapshot has its own copy of the instrument
	snd.zone_set_root(&ed.p.instruments[0].zones[0], 50)
	check(ed.p.instruments[0].zones[0].root_key == 50 && ed.p.instruments[0].zones[0].root_version == 0, "root edited")
	ed_undo()
	check(ed.p.instruments[0].zones[0].root_key != 50, "undo restores the root (%.2f)", ed.p.instruments[0].zones[0].root_key)

	// The library: instruments of synth zones and of sample zones.
	for i in 0 ..< snd.library_count() {
		li := snd.library_instrument(i)
		name := snd.library_name(i)
		check(len(name) > 0 && len(name) <= 23, "library name '%s'", name)
		check(snd.instrument_name(li) == name, "library %s: the instrument is named like its entry", name)
		check(len(li.zones) > 0 && snd.instrument_has_samples(li) == snd.library_has_samples(i), "library %s: zones", name)
		for lz in li.zones {
			pk: [snd.PATCH_FLOATS]f32 = snd.patch_pack(lz.patch)
			q: snd.Patch = snd.patch_unpack(pk[:])
			pk2: [snd.PATCH_FLOATS]f32 = snd.patch_pack(q)
			check(pk2 == pk, "library %s: pack round trip", name)
		}
		out := render_instrument_note(li, inst_test_key(li), 1.2, 0.8)
		peak: i16 = 0
		for v in out {
			peak = max(peak, abs(v))
		}
		check(peak > 800 && peak < 30000, "library %s: peak %d", name, peak)
		delete(out)
		snd.instrument_destroy(li)
	}
	// Plucked strings are in tune over the whole range.
	pz := snd.library_instrument(0)
	for i in 0 ..< snd.library_count() {
		if snd.library_category(i) == .Plucked {
			snd.instrument_destroy(pz)
			pz = snd.library_instrument(i)
			break
		}
	}
	for k in ([]int{36, 48, 60, 72, 84, 96}) {
		out := render_instrument_note(pz, k, 0.5, 0.5)
		r := snd.sample_detect_root_v1(out, 44100)
		check(r.pitched && abs(r.key - f32(k)) < 0.15, "pizzicato key %d sounds at %.2f", k, r.key)
		delete(out)
	}
	snd.instrument_destroy(pz)

	// The drum kit of the library plays recordings: every key has a zone, 15 different sounds, the hats choke each other.
	di, dfound := snd.library_find("Standard Drums")
	check(dfound && snd.library_has_samples(di), "Standard Drums plays recordings")
	kit := snd.library_instrument(di)
	holes := 0
	for k in 0 ..< 128 {
		if snd.instrument_find_zone(kit, k) == nil {
			holes += 1
		}
	}
	check(holes == 0, "the drum kit has a zone for every key (%d holes)", holes)
	seen: [dynamic]^snd.Sample
	seen.allocator = context.temp_allocator
	for zz in kit.zones {
		check(zz.sample != nil && len(zz.sample.data) > 100 && !zz.pitched && zz.one_shot, "drum zone %d..%d", zz.key_lo, zz.key_hi)
		if !slice.contains(seen[:], zz.sample) {
			append(&seen, zz.sample)
		}
	}
	check(len(seen) == snd.DRUM_SOUNDS, "%d different drum recordings", len(seen))
	hat_c := snd.instrument_find_zone(kit, 42)
	hat_o := snd.instrument_find_zone(kit, 46)
	check(hat_c.group > 0 && hat_c.group == hat_o.group && hat_c.sample != hat_o.sample, "hats choke each other")
	check(snd.instrument_find_zone(kit, 36).sample != snd.instrument_find_zone(kit, 38).sample, "kick and snare differ")
	snd.instrument_destroy(kit)
	fmt.printfln("samples: root detection, import, file round trip, %d library instruments checked", snd.library_count())
}

// ---- the delay effect ---------------------------------------------------------------------------

// Renders the project in the editor as the song that would be played.
render_project :: proc(seconds: f32) -> []f32 {
	song := project_to_song(&ed.p, .Play_Once)
	defer snd.song_destroy(&song)
	return snd.render_song(&song, seconds)
}

// The first frame (of one side, 0 = left 1 = right) where `a` and `b` differ, or -1.
first_diff :: proc(a, b: []f32, side: int) -> int {
	for i in 0 ..< min(len(a), len(b)) / 2 {
		if abs(a[i * 2 + side] - b[i * 2 + side]) > 1e-6 {
			return i
		}
	}
	return -1
}

// ---- samplers: a recording per key range --------------------------------------------------

// Energy of the left channel of a rendered song.
song_energy :: proc(s: ^snd.Song, seconds: f32) -> f64 {
	buf := snd.render_song(s, seconds, 44100, false)
	defer delete(buf)
	e: f64 = 0
	for i := 0; i < len(buf); i += 2 {
		e += f64(buf[i]) * f64(buf[i])
	}
	return e
}

write_tone_wav :: proc(path: string, kind, period: int) {
	tone := int_tone(kind, period, 22050)
	fl := make([]f32, len(tone))
	for i in 0 ..< len(tone) {
		fl[i] = f32(tone[i]) / 32768
	}
	wav := snd.wav_encode(fl, 1, 44100)
	check(os.write_entire_file(path, wav) == nil, "write %s", path)
	delete(tone)
	delete(fl)
	delete(wav)
}

run_sampler_tests :: proc() {
	// The synth: a zone plays its recording as it is, whatever the key; a pitched zone follows the key.
	ta := int_tone(1, 168, 44100) // saw, about C4 (key 60.1)
	tb := int_tone(1, 84, 44100) // an octave up (key 72.1)
	sa := snd.sample_new(ta, 44100, "low")
	sb := snd.sample_new(tb, 44100, "high")
	delete(ta)
	delete(tb)
	mk :: proc(sa, sb: ^snd.Sample, zones: int) -> ^snd.Instrument {
		inst := snd.instrument_empty("test sampler")
		snd.instrument_add_zone(inst, snd.zone_sample(36, 40, sa)) // unpitched, five keys
		snd.instrument_add_zone(inst, snd.zone_sample(41, 41, sb, pitched = true, one_shot = false))
		snd.instrument_add_zone(inst, snd.zone_sample(50, 52, sb, volume = 0.5, group = 1))
		if zones > 3 {
			snd.instrument_add_zone(inst, snd.zone_sample(36, 127, sb)) // never reached for 36..40 (the first zone that holds a key wins)
		}
		return inst
	}
	s: snd.Song
	snd.song_init(&s, "sampler", 120)
	inst := mk(sa, sb, 4)
	idx := snd.song_add_instrument(&s, inst)
	check(idx == 0 && len(s.instruments) == 1 && len(s.samples) == 2 && len(inst.zones) == 4, "sampler added with its recordings")
	check(inst.zones[0].sample == sa && inst.zones[1].sample == sb && inst.zones[0].sample_id == 1 && inst.zones[1].sample_id == 2, "zones are resolved")
	check(!inst.zones[0].has_root, "an unpitched zone has no root key (it never needs one)")
	check(inst.zones[1].has_root && inst.zones[1].root_version == 1 && abs(inst.zones[1].root_key - 72.1) < 0.3, "a pitched zone got its root key, found once (%.2f)", inst.zones[1].root_key)
	frozen_root := inst.zones[1].root_key
	snd.instruments_resolve(s.instruments[:], s.samples[:])
	check(inst.zones[1].root_key == frozen_root, "resolving again keeps the root key")
	for k in ([]int{36, 38, 40}) {
		_, z, ok := snd.instrument_note(inst, k)
		check(ok && z == &inst.zones[0], "key %d is in zone 0", k)
		out := render_instrument_note(inst, k, 0.8, 0.7)
		r := snd.sample_detect_root_v1(out, 44100)
		check(r.pitched && abs(r.key - 60.1) < 0.3, "unpitched zone: key %d sounds at %.2f", k, r.key)
		delete(out)
	}
	{
		out := render_instrument_note(inst, 41, 0.8, 0.7) // the high recording (72.1) played at key 41: 31 semitones down
		r := snd.sample_detect_root_v1(out, 44100)
		check(r.pitched && abs(r.key - 41.1) < 0.4, "pitched zone: key 41 sounds at %.2f", r.key)
		delete(out)
	}
	{
		_, _, ok_gap := snd.instrument_note(inst, 45)
		check(ok_gap, "key 45 is held by the catch-all zone")
		small := snd.instrument_empty("small") // (not in a song: its zones name the recording by number)
		snd.instrument_add_zone(small, snd.zone_sample(36, 40, sa))
		small.zones[0].sample_id = 1
		snd.instruments_resolve([]^snd.Instrument{small}, []^snd.Sample{sa})
		_, _, ok := snd.instrument_note(small, 60)
		check(!ok, "a key that no zone holds is silent")
		snd.instrument_destroy(small)
	}

	// Through the sequencer, on an ordinary channel: unmapped keys are silent.
	s2: snd.Song
	snd.song_init(&s2, "sampler song", 120)
	i2 := snd.song_add_instrument(&s2, mk(sa, sb, 3))
	snd.song_set_instrument(&s2, 0, 0, 3, i2)
	snd.song_note(&s2, 0, 0, 240, 3, 38, 100)
	snd.song_finish(&s2)
	check(song_energy(&s2, 1.0) > 1, "the sampler plays on channel 4")

	s3: snd.Song
	snd.song_init(&s3, "sampler gap", 120)
	i3 := snd.song_add_instrument(&s3, mk(sa, sb, 3))
	snd.song_set_instrument(&s3, 0, 0, 3, i3)
	snd.song_note(&s3, 0, 0, 240, 3, 60, 100) // (no zone holds key 60)
	snd.song_finish(&s3)
	check(song_energy(&s3, 1.0) == 0, "an unmapped key is silent")

	// The file keeps the sampler: same zones, root keys (found and set by hand) and loops, same sound.
	z2 := &s2.instruments[0].zones[1]
	snd.zone_set_root(z2, 70.25)
	z2.loop_on = true
	z2.loop_start = 1000
	z2.loop_end = 20000
	s2.instruments[0].zones[2].patch.filter = {.Low_Pass, 1234, 0.2, 0, 0} // (zones 0 and 1 share a patch, zone 2 has its own)
	bytes := snd.song_encode(&s2, context.temp_allocator)
	check(string(bytes[0:4]) == "PSNG" && bytes[4] == snd.SONG_VERSION && snd.SONG_VERSION == 4, "version 4 is written")
	back, ok := snd.song_decode(bytes)
	check(ok && len(back.instruments) == 1 && len(back.instruments[0].zones) == 3 && len(back.samples) == 2, "the sampler survives the file")
	if ok && len(back.instruments) == 1 && len(back.instruments[0].zones) == 3 {
		for i in 0 ..< 3 {
			a := s2.instruments[0].zones[i]
			b := back.instruments[0].zones[i]
			check(a.source == b.source && snd.patch_pack(a.patch) == snd.patch_pack(b.patch), "zone %d source and patch after the file", i)
			check(a.key_lo == b.key_lo && a.key_hi == b.key_hi && a.sample_id == b.sample_id && a.pitched == b.pitched && a.one_shot == b.one_shot && a.tune == b.tune && a.volume == b.volume && a.pan == b.pan && a.group == b.group, "zone %d differs after the file", i)
			check(a.has_root == b.has_root && a.root_key == b.root_key && a.root_version == b.root_version && a.root_known == b.root_known, "zone %d root key after the file", i)
			check(a.loop_on == b.loop_on && a.loop_start == b.loop_start && a.loop_end == b.loop_end, "zone %d loop after the file", i)
		}
		bz := back.instruments[0].zones[1]
		check(bz.has_root && bz.root_key == 70.25 && bz.root_version == 0 && bz.loop_on && bz.loop_end == 20000, "the hand-set root key and the loop come back")
		check(back.instruments[0].zones[0].sample != nil && back.instruments[0].zones[0].sample == back.samples[0], "zones find their recordings after loading")
		check(abs(song_energy(&back, 1.0) - song_energy(&s2, 1.0)) < 1e-6, "the loaded sampler sounds the same")
	}
	snd.song_destroy(&back)
	c2 := snd.song_clone(&s2)
	check(len(c2.instruments) == 1 && c2.instruments[0] != s2.instruments[0] && len(c2.instruments[0].zones) == 3, "clone owns its instrument")
	snd.song_destroy(&c2)
	snd.song_destroy(&s2)
	snd.song_destroy(&s3)
	snd.song_destroy(&s)

	// Zones of both kinds of source in one instrument: a synth sound on the low keys, a recording above.
	{
		mix := snd.instrument_empty("mixed")
		snd.instrument_add_zone(mix, snd.zone_synth(0, 35, snd.patch_pluck()))
		snd.instrument_add_zone(mix, snd.zone_sample(36, 40, sa))
		ms: snd.Song
		snd.song_init(&ms, "mixed", 120)
		mi := snd.song_add_instrument(&ms, mix)
		check(mi == 0 && len(ms.samples) == 1 && mix.zones[0].sample == nil && mix.zones[0].gain == 1 && mix.zones[1].sample == sa, "a synth zone has no recording")
		check(snd.instrument_makeup(mix) == "mixed" && snd.instrument_has_synth(mix) && snd.instrument_has_samples(mix), "an instrument of both sources")
		_, zlow, oklow := snd.instrument_note(mix, 30)
		_, zhigh, okhigh := snd.instrument_note(mix, 38)
		_, _, okgap := snd.instrument_note(mix, 60)
		check(oklow && zlow.source == .Synth && okhigh && zhigh.source == .Sample && !okgap, "the key picks the source of the sound")
		for k in ([]int{30, 38}) {
			out := render_instrument_note(mix, k, 0.6, 0.4)
			peak: i16 = 0
			for v in out {
				peak = max(peak, abs(v))
			}
			check(peak > 800, "mixed instrument: key %d is audible (peak %d)", k, peak)
			delete(out)
		}
		{
			out := render_instrument_note(mix, 38, 0.8, 0.7) // the recording zone is unpitched: it sounds as recorded
			r := snd.sample_detect_root_v1(out, 44100)
			check(r.pitched && abs(r.key - 60.1) < 0.3, "mixed instrument: the recording zone sounds at %.2f", r.key)
			delete(out)
		}
		snd.song_set_instrument(&ms, 0, 0, 2, mi)
		snd.song_note(&ms, 0, 0, 240, 2, 30, 100)
		snd.song_note(&ms, 0, 240, 240, 2, 38, 100)
		snd.song_finish(&ms)
		check(song_energy(&ms, 1.0) > 1, "the mixed instrument plays in a song")
		mbytes := snd.song_encode(&ms, context.temp_allocator)
		mback, mok := snd.song_decode(mbytes)
		check(mok && len(mback.instruments) == 1 && len(mback.instruments[0].zones) == 2, "the mixed instrument survives the file")
		if mok && len(mback.instruments) == 1 && len(mback.instruments[0].zones) == 2 {
			mz := mback.instruments[0].zones
			check(mz[0].source == .Synth && mz[1].source == .Sample && mz[1].sample == mback.samples[0], "mixed: sources after the file")
			check(snd.patch_pack(mz[0].patch) == snd.patch_pack(snd.patch_pluck()), "mixed: the synth zone's patch comes back")
			check(abs(song_energy(&mback, 1.0) - song_energy(&ms, 1.0)) < 1e-6, "the loaded mixed instrument sounds the same")
		}
		snd.song_destroy(&mback)
		snd.song_destroy(&ms)
	}
	snd.sample_release(sa)
	snd.sample_release(sb)

	// The editor: a sampler on a channel, recordings from files, a folder of them, root key and loop, saving, pruning.
	ed_init()
	ed.cur_track = 0
	snd.score_add_track(&ed.p, "plain") // (a second track that plays the default instrument)
	kdir :: "selftest_kit_dir" // (a folder of its own: importing a folder takes every WAV file in it)
	_ = os.make_directory_all(kdir)
	write_tone_wav("selftest_kit_dir/kit1.wav", 1, 168)
	write_tone_wav("selftest_kit_dir/kit2.wav", 2, 100)
	write_tone_wav("selftest_kit_dir/kit3.wav", 0, 120)
	ed_set_track_instrument(ed.cur_track, snd.instrument_empty("my sampler"))
	check(track_instrument(0) == 0 && len(ed.p.instruments) == 1 && track_label(0) == "my sampler" && snd.instrument_makeup(track_inst(0)) == "empty", "the new instrument is the instrument of track 1")
	open_sampler_editor(0)
	sampler_ed_import_one("selftest_kit_dir/kit1.wav")
	sampler_ed_import_folder("selftest_kit_dir/kit1.wav") // all three files of the folder, on the keys after the first
	si := track_inst(0)
	check(len(si.zones) == 4 && len(ed.p.samples) == 4, "zones and recordings (%d, %d)", len(si.zones), len(ed.p.samples))
	if len(si.zones) == 4 {
		check(si.zones[0].key_lo == 36 && si.zones[1].key_lo == 37 && si.zones[3].key_lo == 39, "keys are handed out one after the other")
		check(si.zones[1].sample != nil && snd.sample_name(si.zones[1].sample) == "kit1", "first of the folder is kit1 (%s)", snd.sample_name(si.zones[1].sample))
		check(zone_key_label(si, 38) == "kit2" && zone_key_label(si, 100) == "", "the key column shows the recordings")
		check(track_key_labels(0) == si && track_key_labels(1) == nil, "only a sampler with unpitched zones labels the keys")
	}
	// Root key and loop of a zone: "follows the key" finds the root once, h l change it, the loop is a seamless one.
	sampler_ed.sel = 0
	sampler_ed.field = int(Sampler_Field.Pitched)
	sampler_ed_adjust(1, false)
	z := &track_inst(0).zones[0]
	check(z.pitched && z.has_root && z.root_known && z.root_version == 1 && abs(z.root_key - 60.1) < 0.3, "the root key is found when a zone starts to follow the key (%.2f)", z.root_key)
	found_root := z.root_key
	sampler_ed.field = int(Sampler_Field.Root)
	sampler_ed_adjust(1, false)
	z = &track_inst(0).zones[0]
	check(abs(z.root_key - (found_root + 1)) < 0.011 && z.root_version == 0, "h l change the root key by a semitone (%.2f)", z.root_key)
	sampler_ed.field = int(Sampler_Field.Loop)
	sampler_ed_adjust(1, false)
	z = &track_inst(0).zones[0]
	check(z.loop_on && z.loop_end > z.loop_start && z.loop_end <= len(z.sample.data), "a loop was found (%d..%d)", z.loop_start, z.loop_end)
	loop_start, loop_end := z.loop_start, z.loop_end
	modal_close()
	// Undo takes the zones back, redo restores them.
	ed_undo()
	check(len(track_inst(0).zones) < 4, "undo takes the zones back")
	ed_redo()
	check(len(track_inst(0).zones) == 4, "redo brings them back")
	// Deleting a zone leaves a recording that nothing plays; saving drops it.
	open_sampler_editor(0)
	sampler_ed.sel = 3
	sampler_ed_delete_zone()
	modal_close()
	check(len(track_inst(0).zones) == 3, "zone deleted")
	// A zone with a synth sound can be added, and a zone switches between a recording and a synth sound.
	open_sampler_editor(0)
	sampler_ed_add_synth()
	szi := track_inst(0)
	check(len(szi.zones) == 4 && szi.zones[3].source == .Synth && szi.zones[3].key_lo == 39 && szi.zones[3].key_hi == 127, "a synth zone was added after the last key")
	sampler_ed.sel = 3
	sampler_ed.field = int(Sampler_Field.Source)
	sampler_ed_adjust(1, false)
	check(szi.zones[3].source == .Sample && szi.zones[3].sample != nil, "the zone now plays a recording")
	sampler_ed_adjust(1, false)
	check(szi.zones[3].source == .Synth && szi.zones[3].sample == nil && snd.patch_pack(szi.zones[3].patch) == snd.patch_pack(snd.patch_piano()), "the zone is a synth sound again")
	open_patch_editor(0, 3)
	patch_ed.sel = 0
	check(patch_ed_zone() == &szi.zones[3] && len(patch_ed_rows()) == len(PARAM_ROWS), "the patch editor edits the zone and shows all rows of a synth sound")
	open_patch_editor(0, 0)
	check(len(patch_ed_rows()) < len(PARAM_ROWS), "the patch editor leaves out the oscillator rows of a recording zone")
	modal_close()
	open_sampler_editor(0)
	sampler_ed.sel = 3
	sampler_ed_delete_zone()
	modal_close()
	check(len(track_inst(0).zones) == 3, "synth zone deleted")
	check(file_save("selftest_kit.psng"), "save the sampler project")
	check(len(ed.p.samples) == 3, "a recording nothing uses is not kept (%d)", len(ed.p.samples))
	ed_set_project(project_new(), "")
	check(file_load("selftest_kit.psng"), "load the sampler project")
	ed.cur_track = 0
	check(snd.instrument_has_samples(track_inst(0)) && len(track_inst(0).zones) == 3, "the instrument comes back from the file")
	if snd.instrument_has_samples(track_inst(0)) && len(track_inst(0).zones) == 3 {
		lz := track_inst(0).zones[0]
		check(lz.pitched && lz.has_root && lz.loop_on && lz.loop_start == loop_start && lz.loop_end == loop_end, "root key and loop come back from the file")
	}
	ed.cursor_key = 38
	ed.cursor_tick = 0
	check(ed_insert_note(), "insert a note")
	ps := project_to_song(&ed.p, .Play_Once)
	check(song_energy(&ps, 1.0) > 1, "the project plays its sampler")
	snd.song_destroy(&ps)
	_ = os.remove_all(kdir)
	_ = os.remove("selftest_kit.psng")
}

// ---- MIDI files ----------------------------------------------------------------------------------

run_midi_tests :: proc() {
	// A MIDI file: a program change on channel 1 and a drum hit on channel 10.
	track := []u8{
		0x00, 0xC0, 40, // program 40 (Violin) on channel 1
		0x00, 0x90, 60, 100, // note on
		0x81, 0x70, 0x80, 60, 0, // 240 ticks later: note off
		0x00, 0x99, 36, 100, // a kick on channel 10
		0x78, 0x89, 36, 0, // 120 ticks later: note off
		0x00, 0xFF, 0x2F, 0x00, // end of track
	}
	mid: [dynamic]u8
	mid.allocator = context.temp_allocator
	append(&mid, 'M', 'T', 'h', 'd', 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0) // format 0, one track, 480 ticks
	append(&mid, 'M', 'T', 'r', 'k', 0, 0, 0, u8(len(track)))
	append(&mid, ..track)
	ms, mok := snd.song_from_midi(mid[:])
	check(mok, "a MIDI file loads")
	if mok {
		check(len(ms.instruments) == 2, "MIDI: %d instruments", len(ms.instruments))
		if len(ms.instruments) == 2 {
			check(snd.instrument_name(ms.instruments[0]) == "Violin" && ms.instruments[0].zones[0].source == .Synth, "MIDI: the program became a plain instrument")
			check(snd.instrument_name(ms.instruments[1]) == "Standard Drums" && snd.instrument_has_samples(ms.instruments[1]), "MIDI: channel 10 got the drum kit")
		}
		check(song_energy(&ms, 1.0) > 1, "MIDI: it plays")
		mp := project_from_song(&ms) // opened in the editor: a track per channel that plays notes, named after its instrument
		check(len(mp.tracks) == 2 && len(mp.notes) == 2, "MIDI: two tracks, two notes (%d, %d)", len(mp.tracks), len(mp.notes))
		if len(mp.tracks) == 2 {
			check(name_str(&mp.tracks[0].name) == "Violin" && name_str(&mp.tracks[1].name) == "Standard Drums", "MIDI: tracks are named '%s', '%s'", name_str(&mp.tracks[0].name), name_str(&mp.tracks[1].name))
			check(mp.tracks[0].inst == 0 && mp.tracks[1].inst == 1, "MIDI: track instruments")
		}
		a1 := snd.render_song(&ms, 2)
		mp2 := project_to_song(&mp, .Play_Once)
		a2 := snd.render_song(&mp2, 2)
		samples_equal("MIDI: through a score", a1, a2)
		delete(a1)
		delete(a2)
		snd.song_destroy(&mp2)
		project_free(&mp)
		data := snd.song_encode(&ms, context.temp_allocator)
		mb, mbok := snd.song_decode(data)
		check(mbok, "MIDI: saved as a song file")
		if mbok {
			songs_equal("MIDI (file)", &ms, &mb)
		}
		snd.song_destroy(&mb)
	}
	snd.song_destroy(&ms)
	fmt.println("MIDI import: programs become instruments, the drum channel gets the kit")
}

run_delay_tests :: proc() {
	SR :: 44100
	ed_init()
	ed.cursor_key = 64
	check(ed_insert_note(), "delay: insert a note")
	base := render_project(4)
	defer delete(base)

	// Settings that nobody sends anything to change nothing at all.
	snd.score_master_set_step(&ed.p.master, .Delay_Time, 40)
	snd.score_master_set_step(&ed.p.master, .Delay_Feedback, 90)
	snd.score_master_set_step(&ed.p.master, .Delay_Ping_Pong, 1)
	snd.score_master_set_step(&ed.p.master, .Delay_Sync, 3)
	check(master_value(.Time) == 40 && master_value(.Sync) == 3, "delay: settings are stored")
	silent := render_project(4)
	check(first_diff(base, silent, 0) < 0 && first_diff(base, silent, 1) < 0, "delay: send 0 changes the audio")
	delete(silent)

	// Centred, free time: both sides get the first echo 400 ms after the note.
	snd.score_master_set_step(&ed.p.master, .Delay_Ping_Pong, 0)
	snd.score_master_set_step(&ed.p.master, .Delay_Sync, 0)
	track_set_mix(0, .Delay, 1)
	check(track_mix(0, .Delay) == 1, "delay: the track's send is stored")
	wet := render_project(4)
	want := 40 * SR / 100
	fl := first_diff(base, wet, 0)
	fr := first_diff(base, wet, 1)
	check(abs(fl - want) <= 3 && abs(fr - want) <= 3, "delay: echo at frame %d / %d, wanted %d", fl, fr, want)
	delete(wet)

	// Ping-pong: the first echo is on the left, the second on the right.
	snd.score_master_set_step(&ed.p.master, .Delay_Ping_Pong, 1)
	pp := render_project(4)
	fl = first_diff(base, pp, 0)
	fr = first_diff(base, pp, 1)
	check(abs(fl - want) <= 3, "delay: ping-pong, left echo at %d, wanted %d", fl, want)
	check(abs(fr - 2 * want) <= 3, "delay: ping-pong, right echo at %d, wanted %d", fr, 2 * want)
	delete(pp)
	snd.score_master_set_step(&ed.p.master, .Delay_Ping_Pong, 0)

	// Tempo sync: a quarter note (sync value 5) at 120 and at 90 beats per minute.
	snd.score_master_set_step(&ed.p.master, .Delay_Sync, 5)
	sy := render_project(4)
	fl = first_diff(base, sy, 0)
	check(abs(fl - SR / 2) <= 3, "delay: sync at 120 BPM, echo at %d, wanted %d", fl, SR / 2)
	delete(sy)
	ed_set_tempo(0, 90)
	track_set_mix(0, .Delay, 0)
	base90 := render_project(4)
	track_set_mix(0, .Delay, 1)
	sy90 := render_project(4)
	fl = first_diff(base90, sy90, 0)
	check(abs(fl - SR * 2 / 3) <= 3, "delay: sync at 90 BPM, echo at %d, wanted %d", fl, SR * 2 / 3)
	delete(base90)
	delete(sy90)

	check(abs(snd.delay_resolve_seconds(0.38, 0, 120) - 0.38) < 1e-6, "delay: free time")
	check(abs(snd.delay_resolve_seconds(0.38, 4, 120) - 0.375) < 1e-6, "delay: dotted eighth at 120")
	check(snd.delay_resolve_seconds(9, 0, 120) <= snd.DELAY_MAX_SECONDS, "delay: time is limited")
	fmt.println("delay: send 0 silent, echo timing, ping-pong, tempo sync checked")
}

// The test songs are the .psng files in testdata/tracks (next to this source). They are read from disk when a check runs and are not compiled into the
// editor, and they are not part of iv_snd either: a program that uses the library brings its own music.
Song_File :: struct {
	name: string,
	data: []u8,
}

TEST_SONG_DIR :: #directory + "testdata/tracks"

// Reads every test song (free the result with free_song_files).
load_song_files :: proc() -> []Song_File {
	files: [dynamic]Song_File
	infos, err := os.read_all_directory_by_path(TEST_SONG_DIR, context.allocator)
	if err != nil {
		return nil
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	for info in infos {
		if !strings.has_suffix(info.name, ".psng") {
			continue
		}
		data, rerr := os.read_entire_file(info.fullpath, context.allocator)
		if rerr == nil {
			append(&files, Song_File{strings.clone(info.name), data})
		}
	}
	return files[:]
}

free_song_files :: proc(files: []Song_File) {
	for f in files {
		delete(f.name)
		delete(f.data)
	}
	delete(files)
}

Test_Song :: struct {
	name: string,
	song: snd.Song,
}

// How many Note_On events a song has.
note_ons_total :: proc(s: ^snd.Song) -> int {
	n := 0
	for &tr in s.tracks {
		for e in tr.events {
			if e.kind == .Note_On {
				n += 1
			}
		}
	}
	return n
}

run_selftest :: proc() -> bool {
	ed_init()
	// The game's songs (the .psng files embedded in the game, loaded here the same way) and the
	// snd package's example song.
	test_songs: [dynamic]Test_Song
	defer delete(test_songs)
	song_files := load_song_files()
	defer free_song_files(song_files)
	check(len(song_files) > 0, "the test songs in %s were found", TEST_SONG_DIR)
	for f in song_files {
		s, sok := snd.song_decode(f.data)
		check(sok, "decode %s", f.name)
		append(&test_songs, Test_Song{f.name, s})
	}
	append(&test_songs, Test_Song{"demo", demo_song()})
	for ts in test_songs {
		name := ts.name
		orig := ts.song
		defer snd.song_destroy(&orig)

		// Song -> project -> song: no note is lost and the sound is the same.
		p := project_from_song(&orig)
		back := project_to_song(&p, .Save)
		on_orig := note_ons_total(&orig)
		check(on_orig == note_ons_total(&back) && on_orig == len(p.notes), "%s: %d note-ons in the song, %d after the round trip, %d notes in the project", name, on_orig, note_ons_total(&back), len(p.notes))
		// (a song with effect graphs also holds one variant of an instrument per graph it plays through, so it has more than the score)
		check((len(p.instruments) == len(orig.instruments) || (len(orig.graphs) > 0 && len(p.instruments) < len(orig.instruments))) && back.ticks_per_beat == orig.ticks_per_beat, "%s: instruments and ticks per beat", name)
		check(back.loop_start == orig.loop_start && back.loop_end == orig.loop_end, "%s: loop points", name)
		a0 := snd.render_song(&orig, 6)
		b0 := snd.render_song(&back, 6)
		samples_equal(name, a0, b0)
		delete(a0)
		delete(b0)

		// Through the file format: the tracks (names too), the notes and the sound stay.
		snd.song_ext_set(&back, "EDIT", []u8{1, 2, 3})
		data := snd.song_encode(&back)
		loaded, lok := snd.song_decode(data)
		check(lok, "%s: decode", name)
		p2 := project_from_song(&loaded)
		check(len(p2.tracks) == len(p.tracks) && len(p2.notes) == len(p.notes), "%s: %d tracks and %d notes after the file, %d and %d before", name, len(p2.tracks), len(p2.notes), len(p.tracks), len(p.notes))
		for ti in 0 ..< min(len(p.tracks), len(p2.tracks)) {
			check(name_str(&p.tracks[ti].name) == name_str(&p2.tracks[ti].name), "%s: track %d name '%s' vs '%s'", name, ti, name_str(&p.tracks[ti].name), name_str(&p2.tracks[ti].name))
			check(p.tracks[ti].inst == p2.tracks[ti].inst, "%s: track %d instrument", name, ti)
		}
		back2 := project_to_song(&p2, .Save)
		check(string(snd.song_ext_get(&loaded, "EDIT")) == "\x01\x02\x03", "%s: EDIT chunk kept", name)
		a := snd.render_song(&orig, 6)
		b := snd.render_song(&back2, 6)
		samples_equal(fmt.tprintf("%s (file)", name), a, b)
		delete(a)
		delete(b)

		// The editor's tempo map agrees with the library's.
		ed_set_project(p2, "")
		end := project_end(&ed.p)
		for t in ([]u32{0, 1000, end / 3, end}) {
			ours := tick_to_seconds(t)
			theirs := snd.song_tick_to_seconds(&orig, t)
			check(abs(ours - theirs) < 1e-9, "%s: tempo map at %d: %f vs %f", name, t, ours, theirs)
		}
		// Mute and solo (what the M and S switches do) keep the notes out of the song that is played.
		if len(ed.p.notes) > 0 {
			c := ed.p.notes[0].track
			mine := track_note_count(c)
			ed.p.tracks[c].mute = true
			ms := project_to_song(&ed.p, .Play_Once)
			check(note_ons_total(&ms) == len(ed.p.notes) - mine, "%s: muted track %d still plays notes (%d of %d)", name, c + 1, note_ons_total(&ms), len(ed.p.notes) - mine)
			snd.song_destroy(&ms)
			ed.p.tracks[c].mute = false
			ed.p.tracks[c].solo = true
			ss := project_to_song(&ed.p, .Play_Once)
			check(note_ons_total(&ss) == mine && mine > 0, "%s: solo track %d: %d notes play, it has %d", name, c + 1, note_ons_total(&ss), mine)
			snd.song_destroy(&ss)
			ed.p.tracks[c].solo = false
		}
		fmt.printfln("%s: %d notes, %d tracks, %d instruments, %d bytes", name, len(ed.p.notes), len(ed.p.tracks), len(ed.p.instruments), len(data))

		delete(data)
		snd.song_destroy(&back)
		snd.song_destroy(&back2)
		snd.song_destroy(&loaded)
		project_free(&p)
	}

	// Editing and undo.
	ed_init()
	ed.cursor_key = 64
	check(ed_insert_note(), "insert")
	ed.cursor_tick = 480
	check(ed_insert_note(), "insert 2")
	check(len(ed.p.notes) == 2, "two notes")
	sel_all(false)
	check(ed_move_targets(120, 2), "move")
	check(ed.p.notes[0].start == 120 && ed.p.notes[0].key == 66, "moved note")
	ed_delete_targets()
	check(len(ed.p.notes) == 0, "deleted")
	ed_undo()
	check(len(ed.p.notes) == 2, "undo delete")
	ed_redo()
	check(len(ed.p.notes) == 0, "redo delete")
	ed_undo()

	// Instrument and mixer helpers.
	ed_add_track() // (a second track)
	harp, hfound := snd.library_find("Harp")
	check(hfound, "the library has a Harp")
	check(track_instrument(0) == -1 && track_label(0) == "Basic Piano", "a track without an instrument plays the default one")
	ed_set_track_instrument(0, snd.library_instrument(harp))
	check(track_instrument(0) == 0 && track_label(0) == "Harp" && len(ed.p.instruments) == 1, "instrument set")
	track_set_mix(0, .Volume, 90.0 / 127)
	check(abs(track_mix(0, .Volume) - 90.0 / 127) < 1e-6 && track_mix(0, .Pan) == 0, "mixer settings")
	ed_edit(false)
	dflt := ed_inst_for_edit(1) // the default instrument is copied into the project when it is to be changed
	check(track_instrument(1) == 1 && snd.instrument_name(dflt) == "Basic Piano" && len(ed.p.instruments) == 2, "default instrument copied for editing")
	ed_set_track_instrument(1, snd.library_instrument(harp)) // the same synth instrument again: shared, the copy is dropped
	check(track_instrument(1) == 0 && len(ed.p.instruments) == 1, "an identical instrument is shared (%d)", len(ed.p.instruments))
	ed_set_tempo(0, 90)
	check(abs(bpm_at(0) - 90) < 0.01, "tempo")

	// Save, load.
	path := "selftest.psng"
	check(file_save(path), "save")
	ed_set_project(project_new(), "")
	check(file_load(path), "load")
	check(track_instrument(0) == 0 && track_label(0) == "Harp" && len(ed.p.notes) == 2 && len(ed.p.tracks) == 2 && abs(bpm_at(0) - 90) < 0.01, "loaded project")
	check(abs(track_mix(0, .Volume) - 90.0 / 127) < 1e-6, "the mixer settings come back")
	_ = os.remove(path)

	run_sample_tests()
	run_sampler_tests()
	run_midi_tests()
	run_delay_tests()
	run_export_tests()
	run_graph_tests()
	run_score_tests()
	run_graph_ui_tests()
	run_key_tests()
	run_logic_tests()

	_ = math.PI
	if st_fail == 0 {
		fmt.println("selftest: all good")
	}
	return st_fail == 0
}
