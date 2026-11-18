package main

import "core:fmt"
import "core:os"
import "core:strings"
import snd "shared:iv_snd"

// ---------------------------------------------------------------------------
// Loading and saving projects (PSNG files) and importing MIDI files.
//
// The editor keeps its own settings (grid, zoom, cursor, ...) in a PSNG chunk named
// "EDIT". The snd package keeps such chunks as they are and ignores them when playing.
// ---------------------------------------------------------------------------

EDIT_CHUNK_VERSION :: u8(2) // (version 1 also stored the current channel, which is gone)

edit_chunk_encode :: proc() -> []u8 {
	w: snd.Writer
	w.buf.allocator = context.temp_allocator
	snd.w_u8(&w, EDIT_CHUNK_VERSION)
	snd.w_varlen(&w, u32(ed.grid_idx))
	snd.w_varlen(&w, ed.beats_per_bar)
	snd.w_varlen(&w, u32(ed.beat_px))
	snd.w_varlen(&w, u32(max(ed.scroll_tick, 0)))
	snd.w_varlen(&w, u32(clamp(ed.scroll_key, 0, 127)))
	snd.w_varlen(&w, ed.cursor_tick)
	snd.w_varlen(&w, u32(clamp(ed.cursor_key, 0, 127)))
	snd.w_varlen(&w, u32(ed.cur_track))
	snd.w_varlen(&w, u32(ed.def_vel))
	snd.w_varlen(&w, ed.note_len)
	snd.w_varlen(&w, u32(ed.loop_on))
	return w.buf[:]
}

edit_chunk_apply :: proc(data: []u8) {
	if len(data) == 0 {
		return
	}
	r := snd.Reader {
		data = data,
		ok   = true,
	}
	version := snd.r_u8(&r)
	if version != EDIT_CHUNK_VERSION && version != 1 {
		return
	}
	grid := int(snd.r_varlen(&r))
	bpb := snd.r_varlen(&r)
	bpx := int(snd.r_varlen(&r))
	st := int(snd.r_varlen(&r))
	sk := int(snd.r_varlen(&r))
	ct := snd.r_varlen(&r)
	ck := int(snd.r_varlen(&r))
	tr := int(snd.r_varlen(&r))
	if version == 1 {
		snd.r_varlen(&r) // (the channel of version 1)
	}
	vel := int(snd.r_varlen(&r))
	nl := snd.r_varlen(&r)
	lp := snd.r_varlen(&r)
	if !r.ok {
		return
	}
	ed.grid_idx = clamp(grid, 0, len(GRIDS) - 1)
	ed.beats_per_bar = clamp(bpb, 1, 32)
	ed.beat_px = clamp(bpx, 8, 240)
	ed.scroll_tick = st
	ed.scroll_key = clamp(sk, 12, 127)
	ed.cursor_tick = ct
	ed.cursor_key = clamp(ck, 0, 127)
	ed.cur_track = clamp(tr, 0, len(ed.p.tracks) - 1)
	ed.def_vel = clamp(vel, 1, 127)
	ed.note_len = nl
	ed.loop_on = lp != 0
}

path_base :: proc(path: string) -> string {
	i := len(path)
	for i > 0 && path[i - 1] != '/' && path[i - 1] != '\\' {
		i -= 1
	}
	return path[i:]
}

path_ext :: proc(path: string) -> string {
	b := path_base(path)
	for i := len(b) - 1; i > 0; i -= 1 {
		if b[i] == '.' {
			return b[i:]
		}
	}
	return ""
}

// Opens a .psng or .mid file. Returns false (and says why) if it fails.
file_load :: proc(path: string) -> bool {
	s, ok := snd.song_load(path)
	if !ok {
		ed_say("Could not read %s", path_base(path))
		return false
	}
	defer snd.song_destroy(&s)
	p := project_from_song(&s)
	is_psng := strings.to_lower(path_ext(path), context.temp_allocator) == ".psng"
	edit := snd.song_ext_get(&s, "EDIT")
	if !is_psng {
		stem := path_base(path)
		if e := path_ext(path); e != "" {
			stem = stem[:len(stem) - len(e)]
		}
		p.name = name_make(stem)
	}
	ed_set_project(p, path if is_psng else "")
	edit_chunk_apply(edit)
	if !is_psng {
		ed.dirty = true
	}
	ed_say("Opened %s", path_base(path))
	return true
}

// Reads a WAV file and makes a sampler instrument of it for the current track: one pitched zone over all keys,
// so the recording is played faster or slower to follow the notes. Its root key is found automatically from
// the recording (once; it is stored in the zone and can be changed in the sampler editor, Ctrl+T).
file_import_wav :: proc(path: string) -> bool {
	stem := path_base(path)
	if e := path_ext(path); e != "" {
		stem = stem[:len(stem) - len(e)]
	}
	sm, ok := snd.sample_load_wav(path, stem)
	if !ok {
		ed_say("Could not read %s as a WAV file (PCM or float, mono or stereo)", path_base(path))
		return false
	}
	ed_edit(false)
	inst := snd.instrument_from_sample(sm, stem)
	root, cents := snd.zone_root_note(&inst.zones[0])
	known := inst.zones[0].root_known
	secs := snd.sample_seconds(sm)
	ed_set_track_instrument(ed.cur_track, inst, false) // (the project takes its own share of the recording)
	snd.sample_release(sm)
	if known {
		ed_say("Imported %s (%.1f s): root key %s %+dc", stem, secs, key_label(root), cents)
	} else {
		ed_say("Imported %s (%.1f s): no pitch found, root key set to C4 (Ctrl+T to change it)", stem, secs)
	}
	audition(ed.cur_track, 60, ed.def_vel)
	return true
}

file_save :: proc(path: string) -> bool {
	project_prune_instruments(&ed.p)
	project_prune_samples(&ed.p)
	s := project_to_song(&ed.p, .Save)
	defer snd.song_destroy(&s)
	snd.song_ext_set(&s, "EDIT", edit_chunk_encode())
	if !snd.song_save(&s, path) {
		ed_say("Could not write %s", path_base(path))
		return false
	}
	if ed.path != path {
		delete(ed.path)
		ed.path = strings.clone(path)
	}
	ed.dirty = false
	ed_say("Saved %s", path_base(path))
	return true
}

// ---- exporting WAV files ----------------------------------------------------------------------------
//
// An export renders the song with the real synthesizer into the bytes of a 16-bit stereo WAV file. It
// runs a few milliseconds per frame of the editor (export_step), so the window stays alive: a dialog
// shows the progress and Esc cancels. `loops` = 0 plays the song once through and stops when the sound
// after the last note has died away (at most EXPORT_TAIL seconds later); otherwise the loop section is
// repeated that many times and the sound fades out at the end.

EXPORT_RATE :: 44100
EXPORT_TAIL :: 4.0 // seconds of release after the last note (the most)
EXPORT_FADE :: 3 // seconds of fade-out after the last loop
EXPORT_CHUNK :: 2048 // frames rendered at a time
EXPORT_BUDGET :: 0.012 // seconds of rendering per frame of the editor
EXPORT_QUIET :: f32(2e-5) // below this (a fraction of full scale) a frame counts as silent
EXPORT_QUIET_FRAMES :: EXPORT_RATE * 3 / 10 // this many silent frames in a row end the tail

Export_Job :: struct {
	active:  bool,
	audio:   ^snd.Audio, // its own synthesizer: it does not touch the one that plays in the editor
	song:    snd.Song,
	path:    string,
	loops:   int,
	bytes:   []u8, // the file: a 44 byte header, then the frames
	frames:  int, // frames the file will have, at most
	content: int, // frames of the song itself (the tail after it may end early)
	done:    int, // frames rendered
	quiet:   int, // silent frames in a row since the song ended
	quiet_need: int, // how many it takes to end the tail (echoes leave gaps: see export_quiet_frames)
	started:  f64,
	scratch: [EXPORT_CHUNK * 2]f32,
}

export_job: Export_Job

// Starts an export (a dialog with a progress bar opens); it goes on in export_step.
export_begin :: proc(path: string, loops: int) -> bool {
	job := &export_job
	if job.active {
		return false
	}
	play_halt()
	job^ = {}
	job.loops = loops
	job.path = strings.clone(path)
	mode := Song_Mode.Play_Once if loops <= 0 else Song_Mode.Play_Loop
	job.song = project_to_song(&ed.p, mode)

	seconds: f64
	if loops <= 0 {
		seconds = snd.song_duration_seconds(&job.song)
		job.content = int(seconds * EXPORT_RATE)
		seconds += EXPORT_TAIL
	} else {
		le := job.song.loop_end
		if le == 0 {
			le = snd.song_length_ticks(&job.song)
		}
		ls := min(job.song.loop_start, le)
		t0 := tick_to_seconds(ls)
		t1 := tick_to_seconds(le)
		seconds = t0 + (t1 - t0) * f64(loops) + EXPORT_FADE
	}
	seconds = min(seconds, 60 * 30)
	job.frames = int(seconds * EXPORT_RATE)
	if loops > 0 {
		job.content = job.frames
	}
	job.quiet_need = export_quiet_frames()
	job.audio = new(snd.Audio)
	snd.audio_init(job.audio, EXPORT_RATE)
	snd.music_play(job.audio, &job.song, loops > 0)
	job.bytes = make([]u8, 44 + job.frames * 4)
	snd.wav_write_header(job.bytes, job.frames, 2, EXPORT_RATE)
	job.started = now()
	job.active = true
	open_progress()
	return true
}

// How many silent frames in a row end the tail of an export. Echoes leave silent gaps between them, so a project
// with a delay (the shared one, or an effect graph's) must be heard for longer than the longest gap.
export_quiet_frames :: proc() -> int {
	secs := f32(EXPORT_QUIET_FRAMES) / EXPORT_RATE
	slowest := f32(400)
	tmap_update()
	for t in ed.tmap {
		slowest = min(slowest, snd.tempo_to_bpm(t.us))
	}
	for t in ed.p.tracks {
		if t.delay > 0 {
			m := &ed.p.master
			secs = max(secs, snd.delay_resolve_seconds(m.delay_time, m.delay_sync, slowest) + 0.3)
			break
		}
	}
	for ti in 0 ..< len(ed.p.tracks) { // (the graphs that tracks play through)
		if g := snd.score_track_graph(&ed.p, ti); g != nil {
			for n in g.nodes {
				if n.kind == .Delay && !n.bypass {
					secs = max(secs, snd.delay_resolve_seconds(n.p[0] * 0.001, int(n.p[1] + 0.5), slowest) + 0.3)
				}
			}
		}
	}
	return int(min(secs, EXPORT_TAIL) * EXPORT_RATE)
}

export_cleanup :: proc() {
	job := &export_job
	if job.audio != nil {
		snd.audio_shutdown(job.audio)
		free(job.audio)
	}
	snd.song_destroy(&job.song)
	delete(job.bytes)
	delete(job.path)
	job^ = {}
}

export_cancel :: proc() {
	if export_job.active {
		export_cleanup()
		ed_say("Export cancelled")
	}
}

// 0..1
export_progress :: proc() -> f32 {
	return f32(export_job.done) / f32(max(export_job.frames, 1))
}

// Renders for a few milliseconds (EXPORT_BUDGET), or with `all` until the file is done. Writes the file when it is.
export_step :: proc(all := false) {
	job := &export_job
	if !job.active {
		return
	}
	t0 := now()
	fade := min(EXPORT_FADE * EXPORT_RATE, job.frames) if job.loops > 0 else 0
	stop := false
	for job.done < job.frames && !stop {
		n := min(EXPORT_CHUNK, job.frames - job.done)
		out := job.scratch[:n * 2]
		snd.audio_render(job.audio, out)
		for i in 0 ..< n {
			k := job.done + i
			l := out[i * 2]
			r := out[i * 2 + 1]
			if job.loops <= 0 && k >= job.content {
				if abs(l) < EXPORT_QUIET && abs(r) < EXPORT_QUIET {
					job.quiet += 1
				} else {
					job.quiet = 0
				}
			}
			if fade > 0 && k >= job.frames - fade {
				g := f32(job.frames - k) / f32(fade)
				l *= g
				r *= g
			}
			p := 44 + k * 4
			lv := cast(u16)i16(clamp(l, -1, 1) * 32767)
			rv := cast(u16)i16(clamp(r, -1, 1) * 32767)
			job.bytes[p] = u8(lv)
			job.bytes[p + 1] = u8(lv >> 8)
			job.bytes[p + 2] = u8(rv)
			job.bytes[p + 3] = u8(rv >> 8)
			if job.loops <= 0 && job.quiet >= job.quiet_need && k >= job.content + EXPORT_RATE / 2 {
				job.frames = k + 1 // the tail has died away: the file ends here
				job.done = k + 1
				stop = true
				break
			}
		}
		if !stop {
			job.done += n
		}
		if !all && now() - t0 > EXPORT_BUDGET {
			break
		}
	}
	if job.done < job.frames {
		return
	}
	// Done: put the real length in the header and write the file.
	snd.wav_write_header(job.bytes, job.frames, 2, EXPORT_RATE)
	path := strings.clone(job.path, context.temp_allocator)
	data := job.bytes[:44 + job.frames * 4]
	ok := os.write_entire_file(path, data) == nil
	secs := f64(job.frames) / EXPORT_RATE
	took := now() - job.started
	export_cleanup()
	if modal_kind == .Progress {
		modal_close()
	}
	if ok {
		ed_say("Exported %s (%s, rendered in %.1f s)", path_base(path), time_text(secs), took)
	} else {
		ed_say("Could not write %s", path_base(path))
	}
}

// Exports without a window, all at once (the command line: `snd_editor --export song.psng out.wav [loops]`).
export_blocking :: proc(path: string, loops: int) -> bool {
	if !export_begin(path, loops) {
		return false
	}
	export_step(true)
	return !export_job.active
}

_ :: fmt
