package iv_snd

import "core:math"

// ---------------------------------------------------------------------------
// The sequencer walks through a song in real time (in audio samples, so it is
// sample accurate) and fires the events into a synthesizer. The audio is
// rendered in pieces between consecutive events, so a note starts exactly at
// the sample where it is due.
// ---------------------------------------------------------------------------

MAX_TRACKS :: 256 // event tracks of a song that play (further ones are ignored)

// Controller 85 (any channel, in any track) with a value of 64 or more tells the
// sequencer to leave notes sounding when the song loops back, instead of releasing
// them. That lets a pad or drone ring through the join of a loop without a dip; the
// song must then end the notes itself (note-offs at or before the loop end).
CC_LOOP_KEEP_NOTES :: 85

Sequencer :: struct {
	song:            ^Song,
	cursors:         [MAX_TRACKS]int, // next event of every track
	ntracks:         int,
	playing:         bool,
	paused:          bool,
	looping:         bool,
	keep_notes:      bool, // CC_LOOP_KEEP_NOTES: notes survive the jump back
	finished:        bool, // set when a song that does not loop has ended
	pos_ticks:       f64,
	fired_to:        f64, // events up to this tick have been handled
	tempo_us:        f64,
	speed:           f64, // playback speed multiplier
	sample_rate:     f64,
	samples_per_tick: f64,
	loop_start:      f64,
	loop_end:        f64, // tick the song loops (or ends) at
}

seq_update_tempo :: proc(q: ^Sequencer) {
	tpb := f64(max(q.song.ticks_per_beat, 1))
	q.samples_per_tick = q.sample_rate * (q.tempo_us / 1e6) / tpb / q.speed
}

// Start `song` from the beginning.
seq_start :: proc(q: ^Sequencer, song: ^Song, sample_rate: f64, loop: bool) {
	q^ = {}
	q.song = song
	q.sample_rate = sample_rate
	q.speed = 1
	q.looping = loop
	q.tempo_us = f64(DEFAULT_TEMPO_US)
	q.ntracks = min(len(song.tracks), MAX_TRACKS)
	q.playing = true
	q.fired_to = -1
	seq_setup_loop(q)
	seq_update_tempo(q)
}

// Works out where the song loops or ends (used when starting and when the song changes).
seq_setup_loop :: proc(q: ^Sequencer) {
	song := q.song
	end := song.end_tick
	for i in 0 ..< q.ntracks {
		evs := song.tracks[i].events
		if len(evs) > 0 {
			end = max(end, evs[len(evs) - 1].tick)
		}
	}
	q.loop_end = f64(song.loop_end)
	if song.loop_end == 0 || song.loop_end > end {
		q.loop_end = f64(end)
	}
	q.loop_start = f64(song.loop_start)
	if q.loop_start >= q.loop_end {
		q.loop_start = 0
	}
}

// Dispatches, in time order, every event that is not a note and lies before `tick`
// (the instrument setup, tempo, controllers, bends): what a player that jumps into
// the middle of a song has to catch up on. Notes before `tick` are skipped; "all notes
// off" controllers are ignored, so notes that are sounding are left alone.
seq_chase :: proc(q: ^Sequencer, syn: ^Synth, tick: f64) {
	cur: [MAX_TRACKS]int
	for {
		best := -1
		for ti in 0 ..< q.ntracks {
			evs := q.song.tracks[ti].events
			c := cur[ti]
			// Skip notes.
			for c < len(evs) && f64(evs[c].tick) < tick && (evs[c].kind == .Note_On || evs[c].kind == .Note_Off) {
				c += 1
			}
			cur[ti] = c
			if c < len(evs) && f64(evs[c].tick) < tick {
				if best < 0 || event_less(evs[c], q.song.tracks[best].events[cur[best]]) {
					best = ti
				}
			}
		}
		if best < 0 {
			break
		}
		e := q.song.tracks[best].events[cur[best]]
		cur[best] += 1
		if e.kind == .Control && (e.a == 120 || e.a == 123) {
			continue
		}
		seq_dispatch(q, syn, e)
	}
}

// Jumps to `tick` (right after seq_start): catches up on the setup events, then
// plays from there. A tick at or past the end of the loop starts from the beginning.
seq_seek :: proc(q: ^Sequencer, syn: ^Synth, tick: f64) {
	t := tick
	if t >= q.loop_end || t < 0 {
		t = 0
	}
	seq_chase(q, syn, t)
	for ti in 0 ..< q.ntracks {
		evs := q.song.tracks[ti].events
		c := 0
		for c < len(evs) && f64(evs[c].tick) < t {
			c += 1
		}
		q.cursors[ti] = c
	}
	q.pos_ticks = t
	q.fired_to = t - 1
}

// Swaps the song of a running sequencer for an edited version of it, without
// restarting: playback goes on from the current tick. The setup events before it are
// handled again (so a changed instrument or volume takes effect for the next notes);
// notes already sounding are not touched. The old song is not used afterwards.
seq_replace_song :: proc(q: ^Sequencer, syn: ^Synth, song: ^Song, loop: bool) {
	synth_forget_instruments(syn) // the channels point into the old song's instruments
	q.song = song
	q.looping = loop
	q.ntracks = min(len(song.tracks), MAX_TRACKS)
	seq_setup_loop(q)
	if q.pos_ticks >= q.loop_end {
		q.pos_ticks = q.loop_start
		q.fired_to = q.pos_ticks - 1
	}
	// Tempo in force at the current tick.
	q.tempo_us = f64(DEFAULT_TEMPO_US)
	syn.tempo_bpm = f32(60e6 / f64(DEFAULT_TEMPO_US))
	q.keep_notes = false
	seq_chase(q, syn, math.floor_f64(q.fired_to) + 1)
	// Notes at or before fired_to have already sounded: continue after them.
	for ti in 0 ..< q.ntracks {
		evs := song.tracks[ti].events
		c := 0
		for c < len(evs) && f64(evs[c].tick) < math.floor_f64(q.fired_to) + 1 {
			c += 1
		}
		q.cursors[ti] = c
	}
	seq_update_tempo(q)
}

seq_stop :: proc(q: ^Sequencer) {
	q.playing = false
	q.paused = false
}

// Where the playback head is, in seconds (follows tempo changes only roughly: it
// uses the current tempo for the whole elapsed time).
seq_seconds :: proc(q: ^Sequencer) -> f64 {
	if q.song == nil {
		return 0
	}
	return q.pos_ticks * q.samples_per_tick / q.sample_rate
}

// Handles the events of every track that are due at `pos_ticks`.
seq_fire_due :: proc(q: ^Sequencer, syn: ^Synth) {
	pos := q.pos_ticks + 1e-6
	q.fired_to = pos
	for pass in 0 ..< 2 {
		for ti in 0 ..< q.ntracks {
			evs := q.song.tracks[ti].events
			c := q.cursors[ti]
			for c < len(evs) && f64(evs[c].tick) <= pos {
				e := evs[c]
				if (pass == 0) != (e.kind == .Note_On) {
					seq_dispatch(q, syn, e, ti, c)
				}
				c += 1
			}
			if pass == 1 {
				q.cursors[ti] = c
			}
		}
	}
}

// The tick a note that starts with the Note_On at index `index` of track `track` ends at: that of the next
// Note_Off of the same channel and key in the track, or of the same key started again (which lets the old
// one go). A note that nothing ends lasts until the song ends or loops. The vibrato and portamento of a
// note are laid out over this length.
seq_note_end_tick :: proc(q: ^Sequencer, track, index: int) -> f64 {
	evs := q.song.tracks[track].events
	e := evs[index]
	for i in index + 1 ..< len(evs) {
		x := evs[i]
		if x.channel == e.channel && x.a == e.a && (x.kind == .Note_Off || x.kind == .Note_On) {
			return f64(max(x.tick, e.tick))
		}
	}
	return max(q.loop_end, f64(e.tick))
}

// `track` and `index` say where the event is in the song (needed to find out how long a note with
// effects lasts); -1 = not known, the note then has no effects.
seq_dispatch :: proc(q: ^Sequencer, syn: ^Synth, e: Event, track := -1, index := -1) {
	ch := int(e.channel)
	switch e.kind {
	case .Tempo:
		q.tempo_us = f64(max(e.a, 1))
		seq_update_tempo(q)
		syn.tempo_bpm = f32(60e6 / q.tempo_us) // a tempo-synced delay follows it
	case .Set_Instrument:
		inst: ^Instrument = nil
		if e.a >= 0 && int(e.a) < len(q.song.instruments) {
			inst = q.song.instruments[e.a]
		}
		synth_set_instrument(syn, ch, inst, int(e.a))
	case .Control:
		if e.a == CC_LOOP_KEEP_NOTES {
			q.keep_notes = e.b >= 64
		}
		synth_control(syn, ch, int(e.a), int(e.b))
	case .Set_Patch_Param:
		if e.a >= 0 && e.a <= i32(max(Patch_Param)) {
			synth_set_param(syn, ch, Patch_Param(e.a), e.v)
		}
	case .Pitch_Bend:
		synth_bend(syn, ch, int(e.a))
	case .Note_Off:
		synth_note_off(syn, ch, int(e.a))
	case .Note_On:
		if e.fx > 0 && int(e.fx) <= len(q.song.note_fx) && track >= 0 && index >= 0 {
			ticks := seq_note_end_tick(q, track, index) - f64(e.tick)
			secs := f32(ticks * q.samples_per_tick / q.sample_rate) // at the tempo the note starts at
			synth_note_on_fx(syn, ch, int(e.a), int(e.b), &q.song.note_fx[e.fx - 1], max(secs, 0.001))
		} else {
			synth_note_on(syn, ch, int(e.a), int(e.b))
		}
	}
}

// Ticks until the next thing happens: the next event, or the loop / song end.
seq_next_tick :: proc(q: ^Sequencer) -> f64 {
	next := q.loop_end
	for ti in 0 ..< q.ntracks {
		evs := q.song.tracks[ti].events
		c := q.cursors[ti]
		if c < len(evs) {
			next = min(next, f64(evs[c].tick))
		}
	}
	return next
}

// Jump back to the loop start. Notes still sounding are released (unless the song
// asked to keep them with CC_LOOP_KEEP_NOTES).
seq_wrap :: proc(q: ^Sequencer, syn: ^Synth) {
	if !q.keep_notes {
		synth_all_off(syn, false)
	}
	for ti in 0 ..< q.ntracks {
		evs := q.song.tracks[ti].events
		c := 0
		for c < len(evs) && f64(evs[c].tick) < q.loop_start {
			c += 1
		}
		q.cursors[ti] = c
	}
	q.pos_ticks = q.loop_start
	q.fired_to = q.loop_start - 1
}

// Renders `n` samples: runs the song and adds the sound to the buffers.
seq_render :: proc(q: ^Sequencer, syn: ^Synth, l, r, send, dsend: []f32, n: int) {
	done := 0
	guard := 0
	for done < n {
		if !q.playing || q.paused || q.song == nil {
			synth_render(syn, l[done:], r[done:], send[done:], dsend[done:], n - done)
			return
		}

		seq_fire_due(q, syn)

		if q.pos_ticks >= q.loop_end {
			if q.looping && q.loop_end - q.loop_start >= 1 {
				seq_wrap(q, syn)
				guard += 1
				if guard > 8 { // a degenerate loop: do not spin
					q.playing = false
				}
				continue
			}
			// End of the song: let the notes ring out.
			synth_all_off(syn, false)
			q.playing = false
			q.finished = true
			continue
		}
		guard = 0

		next := seq_next_tick(q)
		frames_f := math.ceil((next - q.pos_ticks) * q.samples_per_tick)
		frames := int(clamp(frames_f, 1, f64(n - done)))
		synth_render(syn, l[done:], r[done:], send[done:], dsend[done:], frames)
		q.pos_ticks += f64(frames) / q.samples_per_tick
		done += frames
	}
}
