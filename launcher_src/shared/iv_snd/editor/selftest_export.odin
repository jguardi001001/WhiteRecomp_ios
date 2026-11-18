package main

import "core:fmt"
import "core:os"
import snd "shared:iv_snd"

// ---------------------------------------------------------------------------
// More of --selftest: the WAV export, the encoder, the per-frame info cache of the side panel and the small
// editing rules that the interface relies on. No window is needed.
// ---------------------------------------------------------------------------

st_called: bool

wav_u32 :: proc(b: []u8, at: int) -> u32 {
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

wav_i16 :: proc(b: []u8, at: int) -> int {
	return int(i16(u16(b[at]) | u16(b[at + 1]) << 8))
}

// Checks the header of a WAV file written by the exporter and returns its number of frames.
check_wav :: proc(what: string, b: []u8) -> int {
	check(len(b) >= 44, "%s: file has a header (%d bytes)", what, len(b))
	if len(b) < 44 {
		return 0
	}
	check(string(b[0:4]) == "RIFF" && string(b[8:16]) == "WAVEfmt " && string(b[36:40]) == "data", "%s: chunk names", what)
	check(wav_u32(b, 4) == u32(len(b) - 8), "%s: RIFF size %d, file %d", what, wav_u32(b, 4), len(b))
	check(wav_u32(b, 40) == u32(len(b) - 44), "%s: data size %d, file %d", what, wav_u32(b, 40), len(b))
	check(wav_u32(b, 24) == EXPORT_RATE && b[22] == 2 && b[34] == 16, "%s: 44100 Hz, 2 channels, 16 bit", what)
	return (len(b) - 44) / 4
}

// A project with one short note on a dry track (no reverb), so the sound after it ends is silent soon.
dry_note_project :: proc() {
	ed_init()
	ed.cursor_key = 69
	ed.note_len = 480
	check(ed_insert_note(), "dry project: insert a note")
	track_set_mix(0, .Reverb, 0)
}

run_export_tests :: proc() {
	path := "selftest_export.wav"
	defer os.remove(path)

	// ---- the encoder ----
	{
		samples := []f32{0, 0.5, -0.5, 1.5, -2, 1}
		b := snd.wav_encode(samples, 2, 44100)
		defer delete(b)
		check(len(b) == 44 + 12, "encode: size %d", len(b))
		check(wav_u32(b, 4) == u32(36 + 12) && wav_u32(b, 40) == 12 && wav_u32(b, 24) == 44100 && wav_u32(b, 28) == 44100 * 4, "encode: header")
		check(wav_i16(b, 44) == 0 && wav_i16(b, 46) == 16383 && wav_i16(b, 48) == -16383, "encode: values")
		check(wav_i16(b, 50) == 32767 && wav_i16(b, 52) == -32767 && wav_i16(b, 54) == 32767, "encode: clipping")
	}

	// ---- play once: the file ends when the sound after the last note has died away ----
	dry_note_project()
	ps := project_to_song(&ed.p, .Play_Once)
	dur := snd.song_duration_seconds(&ps)
	snd.song_destroy(&ps)
	content := int(dur * EXPORT_RATE)
	check(export_blocking(path, 0), "export once")
	check(!export_job.active, "export once: the job is finished")
	data, err := os.read_entire_file(path, context.allocator)
	check(err == nil, "export once: the file can be read")
	frames := check_wav("export once", data)
	check(frames > content, "export once: %d frames, the song alone is %d", frames, content)
	check(frames < content + int(2.0 * EXPORT_RATE), "export once: the silent tail was not cut (%d frames, song %d)", frames, content)
	peak := 0
	for i in 0 ..< frames {
		peak = max(peak, abs(wav_i16(data, 44 + i * 4)))
	}
	check(peak > 1000, "export once: there is sound (peak %d)", peak)
	last_zero := true
	for i in max(frames - 100, 0) ..< frames {
		last_zero &&= wav_i16(data, 44 + i * 4) == 0
	}
	check(last_zero, "export once: the file ends in silence")
	delete(data)

	// ---- with a reverb the tail is longer than a note, but never longer than EXPORT_TAIL ----
	track_set_mix(0, .Reverb, 100.0 / 127)
	check(export_blocking(path, 0), "export with reverb")
	data, err = os.read_entire_file(path, context.allocator)
	frames2 := check_wav("export with reverb", data)
	check(frames2 > frames && frames2 <= content + int(EXPORT_TAIL * EXPORT_RATE), "export with reverb: %d frames (dry: %d)", frames2, frames)
	delete(data)

	// ---- loops: the loop section is repeated and the sound fades out ----
	ed.p.loop_start = 0
	ed.p.loop_end = 1920 // four beats: two seconds at the default tempo
	check(export_blocking(path, 2), "export loops")
	data, err = os.read_entire_file(path, context.allocator)
	frames3 := check_wav("export loops", data)
	want := int((0 + 2.0 * 2 + EXPORT_FADE) * EXPORT_RATE)
	check(frames3 == want, "export loops: %d frames, wanted %d", frames3, want)
	check(abs(wav_i16(data, 44 + (frames3 - 1) * 4)) < 5, "export loops: the sound has faded out (%d)", wav_i16(data, 44 + (frames3 - 1) * 4))
	delete(data)

	// ---- a cancelled export leaves nothing behind ----
	_ = os.remove(path)
	check(export_begin(path, 64), "export begin") // (64 rounds of the loop: far more than one time slice of rendering)
	check(modal_kind == .Progress && export_job.active, "export begin: the progress dialog is open")
	check(!export_begin(path, 0), "a second export cannot start while one runs")
	export_step()
	check(export_job.active && export_job.done > 0 && export_job.done < export_job.frames, "export step: a slice was rendered (%d of %d frames)", export_job.done, export_job.frames)
	check(export_progress() > 0 && export_progress() < 1, "export progress is between 0 and 1")
	modal_close() // (what Esc in the dialog does)
	check(!export_job.active && modal_kind == .None, "export cancel: stopped, dialog closed")
	check(!os.exists(path), "export cancel: no file written")
	ed_init()
}

run_logic_tests :: proc() {
	// What waits for a save is run when the save worked, and forgotten when it did not.
	after_save = proc() {st_called = true}
	st_called = false
	finish_after_save(false)
	check(!st_called && after_save == nil, "a failed or cancelled save does not run what waited for it, and forgets it")
	after_save = proc() {st_called = true}
	finish_after_save(true)
	check(st_called && after_save == nil, "a save that worked runs what waited for it")

	// Moving a fader changes the song without cutting the notes that sound, and drags are one step of undo.
	ed_init()
	ed.need_release = false
	steps := len(ed.undo)
	track_set_mix(0, .Volume, 80.0 / 127)
	check(!ed.need_release, "a fader does not release sounding notes")
	check(len(ed.undo) == steps + 1 && abs(track_mix(0, .Volume) - 80.0 / 127) < 1e-6, "a fader change is an undo step")
	track_set_mix(0, .Volume, 81.0 / 127, false)
	track_set_mix(0, .Volume, 82.0 / 127, false)
	check(len(ed.undo) == steps + 1 && abs(track_mix(0, .Volume) - 82.0 / 127) < 1e-6, "the rest of a drag adds no undo steps")
	ed_undo()
	check(track_mix(0, .Volume) == snd.TRACK_VOLUME_DEFAULT, "undo of the drag restores the value from before it (%f)", track_mix(0, .Volume))

	// The side panel's one-pass count agrees with the lookups the editing code uses.
	song_files := load_song_files()
	defer free_song_files(song_files)
	for name in ([]string{"mountain_tile.psng", "orbital_drift.psng", "ring_light.psng", "title_theme.psng"}) {
		for f in song_files {
			if f.name != name {
				continue
			}
			s, ok := snd.song_decode(f.data)
			check(ok, "info: decode %s", name)
			p := project_from_song(&s)
			snd.song_destroy(&s)
			ed_set_project(p, "")
			info_update()
			for t in 0 ..< len(ed.p.tracks) {
				check(track_counts[t] == track_note_count(t), "%s: info note count of track %d", name, t)
			}
		}
	}
	ed_init()
}

_ :: fmt
