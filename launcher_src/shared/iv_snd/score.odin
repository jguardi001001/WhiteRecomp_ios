package iv_snd

import "core:fmt"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// The score: a song as a musician thinks of it, for programs that edit songs.
//
// A Song (music.odin) is what the sequencer plays: lists of events with channels and controller numbers,
// in the manner of the file format the first versions of this library were made around. A Score has none of
// that. It is a list of TRACKS, and a track is one sequence of notes with its own instrument and its own
// mixer settings (volume, pan, reverb send, delay send). A track has no limit on how many notes sound at once:
// chords, overlapping notes, the same key struck again before it was let go. Tracks are not channels, and there
// is no controller number anywhere.
//
//   Score --score_to_song--> Song --> Sequencer / file        (channels are handed out here, one or more per track)
//   Score <--score_from_song-- Song (a PSNG file, a MIDI file)
//
// score_to_song gives every track as many channels ("lanes") as it needs so that notes of one track never
// cut each other off: a note goes on the first lane that has no note of the same key still sounding. Playing a
// score is therefore the same as playing the notes on a keyboard with unlimited voices (the synthesizer's
// voice pool, MAX_VOICES, is the only limit, and it takes the quietest voice when it runs out).
//
// What a score keeps that is not notes, for any file it was made from:
//   * the tempo changes (Score.tempo) and the settings of the shared reverb and delay (Score.master);
//   * for a track, the events that change things while the song plays and that no program of this library
//     edits (a volume sweep, a filter sweep, a change of instrument half way): Score_Track.extra. They are
//     carried through unchanged, so a song made some other way plays the same after it went through a score.
// The notes themselves are single records (start, length, key, velocity), not pairs of events.
// ---------------------------------------------------------------------------

Score_Name :: [32]u8

score_name_make :: proc(s: string) -> Score_Name {
	n: Score_Name
	for i in 0 ..< min(len(s), len(n) - 1) {
		n[i] = s[i]
	}
	return n
}

score_name_str :: proc(n: ^Score_Name) -> string {
	i := 0
	for i < len(n) && n[i] != 0 {
		i += 1
	}
	return string(n[:i])
}

Score_Note :: struct {
	start: u32, // ticks
	len:   u32, // ticks; 0 = no end (sounds until the song ends or loops)
	track: int,
	key:   u8, // 0..127
	vel:   u8, // 1..127
	fx:    u16, // effects of this note (vibrato, portamento): number in Score.note_fx, 0 = none
	sel:   bool, // a mark for editors to keep a selection in; the library ignores it
}

Mix_Field :: enum u8 {
	Volume,
	Pan,
	Reverb,
	Delay,
}

// What a track's mixer settings are until somebody sets them (what a synthesizer channel starts with).
TRACK_VOLUME_DEFAULT :: f32(100.0 / 127.0)
TRACK_PAN_DEFAULT :: f32(0)
TRACK_REVERB_DEFAULT :: f32(0.25)
TRACK_DELAY_DEFAULT :: f32(0)

Score_Track :: struct {
	name:   Score_Name,
	inst:   int, // index in Score.instruments; -1 = the default instrument (Basic Piano)
	volume: f32, // 0..1
	pan:    f32, // -1 (left) .. 1 (right)
	reverb: f32, // 0..1 of this track goes into the shared reverb
	delay:  f32, // 0..1 of it goes into the shared delay (echo)
	graph:  int, // the effect graph the whole track is played through: its number in Score.graphs (1 = the first), 0 = none
	set:    bit_set[Mix_Field], // the settings somebody has set: only those are written to a song (the rest are the synthesizer's own defaults)
	mute:   bool,
	solo:   bool,
	extra:  [dynamic]Event, // events that go on while the song plays (see above); `channel` is ignored
}

Master_Field :: enum u8 {
	Room,
	Damping,
	Delay_Time,
	Delay_Feedback,
	Delay_Tone,
	Delay_Ping_Pong,
	Delay_Sync,
}

// The settings of the reverb and the delay that every track can send to (they belong to the whole song).
// Only the fields in `set` are written to a song.
Score_Master :: struct {
	room:            f32, // 0 (small) .. 1 (huge)
	damping:         f32, // 0 (bright) .. 1 (dark)
	delay_time:      f32, // seconds, in steps of 10 ms from 10 ms to 1.27 s (used when delay_sync is 0)
	delay_feedback:  f32, // 0 .. 1 (of the most the delay allows)
	delay_tone:      f32, // 0 (bright echoes) .. 1 (dark)
	delay_ping_pong: bool,
	delay_sync:      int, // 0 = free time, 1..DELAY_SYNC_COUNT = a note length at the song's tempo
	set:             bit_set[Master_Field],
}

Score_Tempo :: struct {
	tick: u32,
	us:   i32, // microseconds per beat
}

Score :: struct {
	name:         Score_Name,
	tpb:          u32, // ticks per beat
	tracks:       [dynamic]Score_Track,
	notes:        [dynamic]Score_Note, // all the notes of all the tracks (Score_Note.track)
	tempo:        [dynamic]Score_Tempo, // tempo changes by tick (at most one per tick; the tempo before the first is 120)
	master:       Score_Master,
	global_extra: [dynamic]Event, // events that belong to no track and that no program edits (carried through)
	instruments:  [dynamic]^Instrument, // the score owns them (their `graph` is not used: a track names its graph itself)
	graphs:       [dynamic]Fx_Graph, // the library of effect graphs (graph.odin): any number of tracks can play through the same one
	samples:      [dynamic]^Sample, // recordings that sample zones play (Zone.sample_id = index + 1); the score holds a share of each
	note_fx:      [dynamic]Note_Fx, // effects of single notes (Score_Note.fx = index + 1)
	ext:          [dynamic]Ext_Chunk, // chunks of a file that nothing here knows (kept)
	loop_start:   u32,
	loop_end:     u32, // 0 = no loop
	end_tick:     u32, // 0 = the end of the last note
}

master_default :: proc() -> Score_Master {
	return Score_Master{room = 0.52, damping = 0.375, delay_time = 0.38, delay_feedback = 0.42, delay_tone = 0.35}
}

score_track_new :: proc(name: string) -> Score_Track {
	return Score_Track {
		name = score_name_make(name),
		inst = -1,
		volume = TRACK_VOLUME_DEFAULT,
		pan = TRACK_PAN_DEFAULT,
		reverb = TRACK_REVERB_DEFAULT,
		delay = TRACK_DELAY_DEFAULT,
	}
}

// A new score: 120 beats per minute and one empty track.
score_new :: proc() -> Score {
	p: Score
	p.name = score_name_make("untitled")
	p.tpb = 480
	p.master = master_default()
	append(&p.tracks, score_track_new("track 1"))
	append(&p.tempo, Score_Tempo{0, DEFAULT_TEMPO_US})
	return p
}

score_free :: proc(p: ^Score) {
	for &t in p.tracks {
		delete(t.extra)
	}
	delete(p.tracks)
	delete(p.notes)
	delete(p.tempo)
	delete(p.global_extra)
	for i in p.instruments {
		instrument_destroy(i)
	}
	delete(p.instruments)
	fx_library_destroy(&p.graphs)
	for sm in p.samples {
		sample_release(sm)
	}
	delete(p.samples)
	delete(p.note_fx)
	for &c in p.ext {
		delete(c.data)
	}
	delete(p.ext)
	p^ = {}
}

ext_chunk_copy :: proc(x: Ext_Chunk) -> Ext_Chunk {
	n := Ext_Chunk {
		id = x.id,
	}
	append(&n.data, ..x.data[:])
	return n
}

score_clone :: proc(p: ^Score) -> Score {
	c := p^
	c.tracks = nil
	c.notes = nil
	c.tempo = nil
	c.global_extra = nil
	c.instruments = nil
	c.graphs = fx_library_clone(p.graphs[:])
	c.samples = nil
	c.note_fx = nil
	c.ext = nil
	for &t in p.tracks {
		nt := t
		nt.extra = nil
		append(&nt.extra, ..t.extra[:])
		append(&c.tracks, nt)
	}
	append(&c.notes, ..p.notes[:])
	append(&c.tempo, ..p.tempo[:])
	append(&c.global_extra, ..p.global_extra[:])
	for sm in p.samples {
		sample_retain(sm)
		append(&c.samples, sm)
	}
	for i in p.instruments {
		append(&c.instruments, instrument_clone(i))
	}
	instruments_resolve(c.instruments[:], c.samples[:])
	append(&c.note_fx, ..p.note_fx[:])
	for &x in p.ext {
		append(&c.ext, ext_chunk_copy(x))
	}
	return c
}

// ---- editing helpers ------------------------------------------------------------------------------

// The setting of a mixer field, snapped to what the synthesizer can tell apart (127 steps), and remembered as set.
score_track_set_mix :: proc(t: ^Score_Track, field: Mix_Field, v: f32) {
	q: f32
	switch field {
	case .Volume, .Reverb, .Delay:
		q = f32(int(clamp(v, 0, 1) * 127 + 0.5)) / 127
	case .Pan:
		q = f32(int(clamp(v, -1, 1) * 63 + 64.5) - 64) / 63
	}
	switch field {
	case .Volume:
		t.volume = q
	case .Pan:
		t.pan = q
	case .Reverb:
		t.reverb = q
	case .Delay:
		t.delay = q
	}
	t.set += {field}
}

// Puts a mixer setting back to what a synthesizer channel starts with, and makes it "not set" (nothing is written to a song for it).
score_track_reset_mix :: proc(t: ^Score_Track, field: Mix_Field) {
	v := score_track_mix_default(field)
	switch field {
	case .Volume:
		t.volume = v
	case .Pan:
		t.pan = v
	case .Reverb:
		t.reverb = v
	case .Delay:
		t.delay = v
	}
	t.set -= {field}
}

score_track_mix :: proc(t: ^Score_Track, field: Mix_Field) -> f32 {
	switch field {
	case .Volume:
		return t.volume
	case .Pan:
		return t.pan
	case .Reverb:
		return t.reverb
	case .Delay:
		return t.delay
	}
	return 0
}

score_track_mix_default :: proc(field: Mix_Field) -> f32 {
	switch field {
	case .Volume:
		return TRACK_VOLUME_DEFAULT
	case .Pan:
		return TRACK_PAN_DEFAULT
	case .Reverb:
		return TRACK_REVERB_DEFAULT
	case .Delay:
		return TRACK_DELAY_DEFAULT
	}
	return 0
}

// The instrument a track plays (the default instrument when it has none of the score's). Do not change it.
score_track_instrument :: proc(p: ^Score, ti: int) -> ^Instrument {
	if ti >= 0 && ti < len(p.tracks) {
		if i := p.tracks[ti].inst; i >= 0 && i < len(p.instruments) {
			return p.instruments[i]
		}
	}
	return default_instrument()
}

// ---- the library of effect graphs ------------------------------------------------------------------

// The graph a track is played through, or nil (none, or a number the library does not have).
score_track_graph :: proc(p: ^Score, ti: int) -> ^Fx_Graph {
	if ti >= 0 && ti < len(p.tracks) {
		return fx_library_get(p.graphs[:], p.tracks[ti].graph)
	}
	return nil
}

// Makes a new graph (Input wired to Output: it changes nothing yet) and returns its number.
score_graph_add :: proc(p: ^Score, name := "Graph") -> int {
	return fx_library_add(&p.graphs, name, fx_graph_default())
}

// Copies a graph of the library (under a new name) and returns the number of the copy. 0 if there is no such graph.
score_graph_duplicate :: proc(p: ^Score, number: int) -> int {
	src := fx_library_get(p.graphs[:], number)
	if src == nil {
		return 0
	}
	c := fx_graph_clone(src)
	return fx_library_add(&p.graphs, fx_graph_name(src), c)
}

// Takes a graph out of the library: the tracks that played through it play dry now, and the numbers after it go down.
score_graph_remove :: proc(p: ^Score, number: int) {
	if number < 1 || number > len(p.graphs) {
		return
	}
	fx_library_remove(&p.graphs, number)
	for &t in p.tracks {
		t.graph = fx_number_after_remove(t.graph, number)
	}
}

// How many tracks play through a graph.
score_graph_users :: proc(p: ^Score, number: int) -> int {
	n := 0
	for &t in p.tracks {
		if t.graph == number && number > 0 {
			n += 1
		}
	}
	return n
}

score_add_track :: proc(p: ^Score, name: string) -> int {
	append(&p.tracks, score_track_new(name))
	return len(p.tracks) - 1
}

// Removes a track and its notes.
score_remove_track :: proc(p: ^Score, ti: int) {
	if ti < 0 || ti >= len(p.tracks) {
		return
	}
	delete(p.tracks[ti].extra)
	ordered_remove(&p.tracks, ti)
	for i := len(p.notes) - 1; i >= 0; i -= 1 {
		if p.notes[i].track == ti {
			ordered_remove(&p.notes, i)
		} else if p.notes[i].track > ti {
			p.notes[i].track -= 1
		}
	}
}

// Puts a tempo change at `tick` (replacing the one that is there).
score_set_tempo :: proc(p: ^Score, tick: u32, bpm: f32) {
	us := i32(60_000_000 / max(bpm, 1))
	for &t in p.tempo {
		if t.tick == tick {
			t.us = us
			return
		}
	}
	append(&p.tempo, Score_Tempo{tick, us})
	slice.stable_sort_by(p.tempo[:], proc(a, b: Score_Tempo) -> bool {return a.tick < b.tick})
}

// The last tick of the score: its end_tick, or where the last note or event ends.
score_end :: proc(p: ^Score) -> u32 {
	end := p.end_tick
	for n in p.notes {
		end = max(end, n.start + n.len)
	}
	for t in p.tempo {
		end = max(end, t.tick)
	}
	for &t in p.tracks {
		for e in t.extra {
			end = max(end, e.tick)
		}
	}
	for e in p.global_extra {
		end = max(end, e.tick)
	}
	return end
}

// Drops the instruments no track plays and renumbers the rest. Done when an instrument is replaced and
// before saving, so that the song holds only what it plays.
score_prune_instruments :: proc(p: ^Score) {
	n := len(p.instruments)
	used := make([]bool, n, context.temp_allocator)
	for &t in p.tracks {
		if t.inst >= 0 && t.inst < n {
			used[t.inst] = true
		}
		for e in t.extra {
			if e.kind == .Set_Instrument && int(e.a) >= 0 && int(e.a) < n {
				used[e.a] = true
			}
		}
	}
	remap := make([]i32, n, context.temp_allocator)
	kept: [dynamic]^Instrument
	for i in 0 ..< n {
		if used[i] {
			remap[i] = i32(len(kept))
			append(&kept, p.instruments[i])
		}
	}
	if len(kept) == n {
		delete(kept)
		return
	}
	for i in 0 ..< n {
		if !used[i] {
			instrument_destroy(p.instruments[i])
		}
	}
	for &t in p.tracks {
		if t.inst >= 0 && t.inst < n {
			t.inst = int(remap[t.inst])
		} else {
			t.inst = -1
		}
		keep := 0
		for e in t.extra {
			ev := e
			if ev.kind == .Set_Instrument {
				if int(ev.a) < 0 || int(ev.a) >= n {
					continue // refers to nothing
				}
				ev.a = remap[ev.a]
			}
			t.extra[keep] = ev
			keep += 1
		}
		resize(&t.extra, keep)
	}
	delete(p.instruments)
	p.instruments = kept
}

// Drops the recordings nothing uses any more (the zones of the instruments name the ones that are used)
// and renumbers the rest. Done before saving, so that replaced or deleted recordings do not stay in the file.
score_prune_samples :: proc(p: ^Score) {
	n := len(p.samples)
	used := make([]bool, n, context.temp_allocator)
	for i in p.instruments {
		for &z in i.zones {
			if z.source == .Sample && z.sample_id > 0 && int(z.sample_id) <= n {
				used[z.sample_id - 1] = true
			}
		}
	}
	remap := make([]i32, n + 1, context.temp_allocator)
	kept: [dynamic]^Sample
	for i in 0 ..< n {
		if used[i] {
			append(&kept, p.samples[i])
			remap[i + 1] = i32(len(kept))
		}
	}
	if len(kept) == n {
		delete(kept)
		return
	}
	for i in 0 ..< n {
		if !used[i] {
			sample_release(p.samples[i])
		}
	}
	for i in p.instruments {
		for &z in i.zones {
			if z.source != .Sample {
				z.sample_id = 0 // (a synth zone that used to play a recording)
			} else if z.sample_id > 0 && int(z.sample_id) <= n {
				z.sample_id = remap[z.sample_id]
			}
		}
	}
	delete(p.samples)
	p.samples = kept
	instruments_resolve(p.instruments[:], p.samples[:])
}

// ---- mixer settings <-> the numbers a song stores ------------------------------------------------------

SCORE_CC_VOLUME :: 7
SCORE_CC_PAN :: 10
SCORE_CC_REVERB :: 91
SCORE_CC_ROOM :: 92
SCORE_CC_DAMPING :: 93

// Whether a controller event is one of the settings a score keeps as fields (of a track or of the master).
@(private = "file")
cc_is_track_field :: proc(cc: i32) -> bool {
	return cc == SCORE_CC_VOLUME || cc == SCORE_CC_PAN || cc == SCORE_CC_REVERB || cc == CC_DELAY_SEND
}

@(private = "file")
cc_is_master_field :: proc(cc: i32) -> bool {
	return cc == SCORE_CC_ROOM || cc == SCORE_CC_DAMPING || (cc >= CC_DELAY_TIME && cc <= CC_DELAY_SYNC)
}

@(private = "file")
cc_is_global :: proc(cc: i32) -> bool {
	return cc_is_master_field(cc) || cc == CC_LOOP_KEEP_NOTES
}

// ---- Song -> Score -------------------------------------------------------------------------------------

@(private = "file")
Chan_State :: struct {
	inst:   int,
	vals:   [Mix_Field]f32,
	set:    bit_set[Mix_Field],
	extra:  [dynamic]Event, // channel zeroed
	used:   bool, // events of the channel were seen
}

@(private = "file")
chan_state_equal :: proc(a, b: ^Chan_State) -> bool {
	if a.inst != b.inst || a.set != b.set || len(a.extra) != len(b.extra) {
		return false
	}
	for f in Mix_Field {
		if a.set >= {f} && a.vals[f] != b.vals[f] {
			return false
		}
	}
	for e, i in a.extra {
		if e != b.extra[i] {
			return false
		}
	}
	return true
}

// A chunk "SCOR" that score_to_song writes with a saved song: how the channels were handed out, so that a score
// that is saved and opened again has the same tracks, names and all (even empty tracks). Per track: its name,
// the first channel it uses and how many it uses. A song without it (or any channel it does not cover) gets its
// tracks from the song's own tracks and channels.
SCOR_CHUNK :: "SCOR"

// Makes a score of a song: the notes become single records, tracks are found as described in the comment on
// score_to_song's counterpart below, and what a score cannot hold as a field is kept as extra events.
score_from_song :: proc(s: ^Song) -> Score {
	p: Score
	p.name = score_name_make(s.name)
	p.tpb = max(s.ticks_per_beat, 1)
	p.loop_start = s.loop_start
	p.loop_end = s.loop_end
	p.end_tick = s.end_tick
	p.master = master_default()
	for sm in s.samples {
		sample_retain(sm)
		append(&p.samples, sm)
	}
	for i in s.instruments {
		append(&p.instruments, instrument_clone(i))
	}
	instruments_resolve(p.instruments[:], p.samples[:])
	p.graphs = fx_library_clone(s.graphs[:])
	append(&p.note_fx, ..s.note_fx[:])
	scor: []u8
	for &x in s.ext {
		if string(x.id[:]) == SCOR_CHUNK {
			scor = x.data[:]
		} else {
			append(&p.ext, ext_chunk_copy(x))
		}
	}

	// ---- 1. the state of every channel (and the events that belong to no channel) ----
	Ev :: struct {
		e:  Event,
		st: int,
	}
	all: [dynamic]Ev
	all.allocator = context.temp_allocator
	for &st, si in s.tracks {
		for e in st.events {
			append(&all, Ev{e, si})
		}
	}
	slice.stable_sort_by(all[:], proc(a, b: Ev) -> bool {return event_less(a.e, b.e)})

	states := make([]Chan_State, 256, context.temp_allocator)
	for &c in states {
		c.inst = -1
		c.vals[.Volume] = TRACK_VOLUME_DEFAULT
		c.vals[.Pan] = TRACK_PAN_DEFAULT
		c.vals[.Reverb] = TRACK_REVERB_DEFAULT
		c.vals[.Delay] = TRACK_DELAY_DEFAULT
		c.extra.allocator = context.temp_allocator
	}
	for item in all {
		e := item.e
		ch := int(e.channel)
		switch e.kind {
		case .Note_On, .Note_Off:
		case .Tempo:
			if n := len(p.tempo); n > 0 && p.tempo[n - 1].tick == e.tick {
				p.tempo[n - 1].us = max(e.a, 1)
			} else {
				append(&p.tempo, Score_Tempo{e.tick, max(e.a, 1)})
			}
		case .Control:
			if cc_is_global(e.a) {
				if e.tick == 0 && cc_is_master_field(e.a) {
					score_master_from_cc(&p.master, e.a, e.b)
				} else {
					append(&p.global_extra, e)
				}
				continue
			}
			c := &states[ch]
			c.used = true
			if e.tick == 0 && cc_is_track_field(e.a) {
				switch e.a {
				case SCORE_CC_VOLUME:
					c.vals[.Volume] = f32(e.b) / 127
					c.set += {.Volume}
				case SCORE_CC_PAN:
					c.vals[.Pan] = clamp((f32(e.b) - 64) / 63, -1, 1)
					c.set += {.Pan}
				case SCORE_CC_REVERB:
					c.vals[.Reverb] = f32(e.b) / 127
					c.set += {.Reverb}
				case CC_DELAY_SEND:
					c.vals[.Delay] = f32(e.b) / 127
					c.set += {.Delay}
				}
			} else {
				x := e
				x.channel = 0
				append(&c.extra, x)
			}
		case .Set_Instrument:
			c := &states[ch]
			c.used = true
			if e.tick == 0 {
				c.inst = int(e.a) if e.a >= 0 && int(e.a) < len(p.instruments) else -1
			} else {
				x := e
				x.channel = 0
				append(&c.extra, x)
			}
		case .Set_Patch_Param, .Pitch_Bend:
			c := &states[ch]
			c.used = true
			x := e
			x.channel = 0
			append(&c.extra, x)
		}
	}

	// ---- 2. the notes: pair every note-on with its note-off, per song track, channel and key ----
	Raw_Note :: struct {
		n:  Score_Note,
		st: int,
		ch: int,
	}
	raw: [dynamic]Raw_Note
	raw.allocator = context.temp_allocator
	for &st, si in s.tracks {
		evs := make([]Event, len(st.events), context.temp_allocator)
		copy(evs, st.events[:])
		slice.stable_sort_by(evs, event_less)
		open := make(map[int][dynamic]int, 16, context.temp_allocator) // (channel * 128 + key) -> notes waiting for their note-off
		for e in evs {
			ch := int(e.channel)
			key := int(e.a & 127)
			k := ch * 128 + key
			#partial switch e.kind {
			case .Note_On:
				append(&raw, Raw_Note{Score_Note{start = e.tick, len = 0, key = u8(key), vel = u8(clamp(e.b, 1, 127)), fx = e.fx if int(e.fx) <= len(s.note_fx) else 0}, si, ch})
				list := open[k]
				list.allocator = context.temp_allocator
				append(&list, len(raw) - 1)
				open[k] = list
			case .Note_Off:
				if list, found := open[k]; found && len(list) > 0 {
					ni := list[0]
					l2 := list
					ordered_remove(&l2, 0)
					open[k] = l2
					raw[ni].n.len = max(e.tick - raw[ni].n.start, 1)
				}
			}
		}
	}

	// ---- 3. the tracks ----
	chan_track: [256]int // channel -> track (a track from "SCOR"), -1 = not decided
	for i in 0 ..< 256 {
		chan_track[i] = -1
	}
	if len(scor) > 0 {
		r := Reader {
			data = scor,
			ok   = true,
		}
		n := int(r_varlen(&r))
		for _ in 0 ..< n {
			if !r.ok {
				break
			}
			name := r_str(&r, context.temp_allocator)
			base := int(r_varlen(&r))
			lanes := int(r_varlen(&r))
			if !r.ok || base < 0 || base > 255 || lanes < 1 {
				break
			}
			t := score_track_new(name)
			st := &states[base]
			t.inst = st.inst
			t.set = st.set
			t.volume = st.vals[.Volume]
			t.pan = st.vals[.Pan]
			t.reverb = st.vals[.Reverb]
			t.delay = st.vals[.Delay]
			append(&t.extra, ..st.extra[:])
			ti := len(p.tracks)
			append(&p.tracks, t)
			for c in base ..< min(base + lanes, 256) {
				chan_track[c] = ti
			}
		}
	}
	// The rest: a track per (song track, channel) with notes, joined with others of the same song track whose channels are set up alike.
	Unit :: struct {
		st, ch: int,
	}
	units: [dynamic]Unit
	units.allocator = context.temp_allocator
	for rn in raw {
		if chan_track[rn.ch] >= 0 {
			continue
		}
		found := false
		for u in units {
			if u.st == rn.st && u.ch == rn.ch {
				found = true
			}
		}
		if !found {
			append(&units, Unit{rn.st, rn.ch})
		}
	}
	slice.sort_by(units[:], proc(a, b: Unit) -> bool {return a.st < b.st || (a.st == b.st && a.ch < b.ch)})
	unit_track := make([]int, len(units), context.temp_allocator)
	made: [dynamic]Unit // (the unit that made each of the tracks below, for comparing states)
	made.allocator = context.temp_allocator
	made_track: [dynamic]int
	made_track.allocator = context.temp_allocator
	for u, ui in units {
		track := -1
		for m, mi in made {
			if m.st == u.st && chan_state_equal(&states[m.ch], &states[u.ch]) {
				track = made_track[mi]
				break
			}
		}
		if track < 0 {
			base := ""
			if u.st < len(s.tracks) {
				base = s.tracks[u.st].name
			}
			if base == "" || base == "conductor" || base == "track" { // (a song track without a name: the track is named after its instrument)
				base = "track"
				if inst := states[u.ch].inst; inst >= 0 && inst < len(p.instruments) {
					base = instrument_name(p.instruments[inst])
				}
			}
			name := base
			for k := 2; ; k += 1 {
				clash := false
				for &t in p.tracks {
					if score_name_str(&t.name) == name {
						clash = true
					}
				}
				if !clash {
					break
				}
				name = fmt.tprintf("%s %d", base, k)
			}
			t := score_track_new(name)
			st := &states[u.ch]
			t.inst = st.inst
			t.set = st.set
			t.volume = st.vals[.Volume]
			t.pan = st.vals[.Pan]
			t.reverb = st.vals[.Reverb]
			t.delay = st.vals[.Delay]
			append(&t.extra, ..st.extra[:])
			track = len(p.tracks)
			append(&p.tracks, t)
			append(&made, u)
			append(&made_track, track)
		}
		unit_track[ui] = track
	}
	for rn in raw {
		n := rn.n
		if chan_track[rn.ch] >= 0 {
			n.track = chan_track[rn.ch]
		} else {
			for u, ui in units {
				if u.st == rn.st && u.ch == rn.ch {
					n.track = unit_track[ui]
					break
				}
			}
		}
		append(&p.notes, n)
	}
	if len(p.tracks) == 0 {
		append(&p.tracks, score_track_new("track 1"))
	}
	score_split_graphs(&p)
	return p
}

// A song's instrument names the graph it plays through; a score's TRACK does, and its instruments are only sounds.
// So the instruments that differ only in their graph become one instrument, and the tracks that played through
// them name the graph themselves. (Nothing happens to a song without graphs.)
score_split_graphs :: proc(p: ^Score) {
	any := false
	for i in p.instruments {
		any ||= i.graph != 0
	}
	if !any {
		return
	}
	n := len(p.instruments)
	graph_of := make([]int, n, context.temp_allocator)
	remap := make([]int, n, context.temp_allocator)
	in_extra := make([]bool, n, context.temp_allocator) // (a change of instrument half way names it: it has to stay an instrument)
	for &t in p.tracks {
		for e in t.extra {
			if e.kind == .Set_Instrument && e.a >= 0 && int(e.a) < n {
				in_extra[e.a] = true
			}
		}
	}
	kept: [dynamic]^Instrument
	for i in 0 ..< n {
		g := p.instruments[i].graph
		graph_of[i] = g if g >= 1 && g <= len(p.graphs) else 0
		p.instruments[i].graph = 0
		found := -1
		for k, ki in kept {
			if instrument_same_sound(k, p.instruments[i]) {
				found = ki
				break
			}
		}
		if found < 0 && !in_extra[i] && instrument_same_sound(default_instrument(), p.instruments[i]) { // the default instrument: tracks on it have none of their own
			remap[i] = -1
			instrument_destroy(p.instruments[i])
			continue
		}
		if found >= 0 {
			remap[i] = found
			instrument_destroy(p.instruments[i])
		} else {
			remap[i] = len(kept)
			append(&kept, p.instruments[i])
		}
	}
	delete(p.instruments)
	p.instruments = kept
	for &t in p.tracks {
		if t.inst >= 0 && t.inst < n {
			t.graph = graph_of[t.inst]
			t.inst = remap[t.inst]
		}
		for &e in t.extra {
			if e.kind == .Set_Instrument && e.a >= 0 && int(e.a) < n {
				e.a = i32(remap[e.a])
			}
		}
	}
}

score_master_from_cc :: proc(m: ^Score_Master, cc, value: i32) {
	v := int(clamp(value, 0, 127))
	switch cc {
	case SCORE_CC_ROOM:
		score_master_set_step(m, .Room, v)
	case SCORE_CC_DAMPING:
		score_master_set_step(m, .Damping, v)
	case CC_DELAY_TIME:
		score_master_set_step(m, .Delay_Time, v)
	case CC_DELAY_FEEDBACK:
		score_master_set_step(m, .Delay_Feedback, v)
	case CC_DELAY_TONE:
		score_master_set_step(m, .Delay_Tone, v)
	case CC_DELAY_STEREO:
		score_master_set_step(m, .Delay_Ping_Pong, 1 if v >= 64 else 0)
	case CC_DELAY_SYNC:
		score_master_set_step(m, .Delay_Sync, v)
	}
}

// The settings of the shared reverb and delay change in whole steps (what the synthesizer can tell apart): 0..127
// for a fraction, 1..127 tens of milliseconds for the echo time, 0 or 1 for ping-pong, 0..DELAY_SYNC_COUNT for the sync.
score_master_step_range :: proc(f: Master_Field) -> (lo, hi: int) {
	switch f {
	case .Room, .Damping, .Delay_Feedback, .Delay_Tone:
		return 0, 127
	case .Delay_Time:
		return 1, 127
	case .Delay_Ping_Pong:
		return 0, 1
	case .Delay_Sync:
		return 0, DELAY_SYNC_COUNT
	}
	return 0, 127
}

score_master_step :: proc(m: ^Score_Master, f: Master_Field) -> int {
	switch f {
	case .Room:
		return int(m.room * 127 + 0.5)
	case .Damping:
		return int(m.damping * 127 + 0.5)
	case .Delay_Feedback:
		return int(m.delay_feedback * 127 + 0.5)
	case .Delay_Tone:
		return int(m.delay_tone * 127 + 0.5)
	case .Delay_Time:
		return clamp(int(m.delay_time * 100 + 0.5), 1, 127)
	case .Delay_Ping_Pong:
		return 1 if m.delay_ping_pong else 0
	case .Delay_Sync:
		return clamp(m.delay_sync, 0, DELAY_SYNC_COUNT)
	}
	return 0
}

// Sets a setting (and so makes it one that is written to a song).
score_master_set_step :: proc(m: ^Score_Master, f: Master_Field, step: int) {
	lo, hi := score_master_step_range(f)
	v := clamp(step, lo, hi)
	fr := f32(v) / 127
	switch f {
	case .Room:
		m.room = fr
	case .Damping:
		m.damping = fr
	case .Delay_Feedback:
		m.delay_feedback = fr
	case .Delay_Tone:
		m.delay_tone = fr
	case .Delay_Time:
		m.delay_time = 0.01 * f32(v)
	case .Delay_Ping_Pong:
		m.delay_ping_pong = v != 0
	case .Delay_Sync:
		m.delay_sync = v
	}
	m.set += {f}
}

// ---- Score -> Song -------------------------------------------------------------------------------------

Score_Mode :: enum {
	Save, // everything, the song as it is stored
	Play_Loop, // what the sequencer plays: mute and solo applied, the loop points kept
	Play_Once, // same, but plays through to the end (loop points removed)
}

// How many lanes (channels) each track needs so that no two notes of the same key in it cut each other off,
// and, if `lane_of` is given, the lane of every note (parallel to p.notes).
score_lanes :: proc(p: ^Score, lane_of: []u8 = nil) -> [dynamic]int {
	counts: [dynamic]int
	counts.allocator = context.temp_allocator
	resize(&counts, len(p.tracks))
	for &c in counts {
		c = 1
	}
	// Notes of each track in time order.
	Key :: struct {
		track: int,
		start: u32,
		idx:   int,
	}
	sorted := make([]Key, len(p.notes), context.temp_allocator)
	for n, i in p.notes {
		sorted[i] = Key{n.track, n.start, i}
	}
	slice.sort_by(sorted, proc(a, b: Key) -> bool {
		if a.track != b.track {
			return a.track < b.track
		}
		if a.start != b.start {
			return a.start < b.start
		}
		return a.idx < b.idx
	})

	LANES_MAX :: 16
	busy: [LANES_MAX][128]u32
	cur_track := -1
	nlanes := 0
	for key in sorted {
		ni := key.idx
		n := p.notes[ni]
		if n.track < 0 || n.track >= len(p.tracks) {
			continue
		}
		if n.track != cur_track {
			cur_track = n.track
			busy = {}
			nlanes = 0
		}
		lane := -1
		for k in 0 ..< nlanes {
			if busy[k][n.key] <= n.start {
				lane = k
				break
			}
		}
		if lane < 0 {
			if nlanes < LANES_MAX {
				lane = nlanes
				nlanes += 1
			} else {
				lane = LANES_MAX - 1
			}
		}
		busy[lane][n.key] = n.start + n.len if n.len > 0 else max(u32)
		counts[n.track] = max(counts[n.track], nlanes)
		if lane_of != nil {
			lane_of[ni] = u8(lane)
		}
	}
	return counts
}

// An instrument of the song that plays a sound of the score through a graph of the library (what the synthesizer
// knows: an instrument names a graph). The sound is p.instruments[inst] (-1 = the default instrument); with no graph
// that is the instrument itself, otherwise a copy of it that names the graph (made once per sound and graph).
Instrument_Variant :: struct {
	inst, graph, index: int,
}

song_instrument_for :: proc(s: ^Song, p: ^Score, variants: ^[dynamic]Instrument_Variant, inst, graph: int) -> int {
	if graph < 1 || graph > len(s.graphs) {
		return inst if inst >= 0 && inst < len(p.instruments) else -1
	}
	src := inst if inst >= 0 && inst < len(p.instruments) else -1
	for v in variants {
		if v.inst == src && v.graph == graph {
			return v.index
		}
	}
	c := instrument_clone(p.instruments[src] if src >= 0 else default_instrument())
	c.graph = graph
	append(&s.instruments, c)
	instruments_resolve(s.instruments[len(s.instruments) - 1:], s.samples[:])
	append(variants, Instrument_Variant{src, graph, len(s.instruments) - 1})
	return len(s.instruments) - 1
}

// Makes a song (which owns its memory: free it with song_destroy) from a score. Every track gets as many channels as
// it needs (score_lanes), in order, all playing the track's instrument with its mixer settings.
score_to_song :: proc(p: ^Score, mode: Score_Mode) -> Song {
	s: Song
	s.owns_strings = true
	s.name = strings.clone(score_name_str(&p.name))
	s.ticks_per_beat = p.tpb
	s.end_tick = p.end_tick
	if mode != .Play_Once {
		s.loop_start = p.loop_start
		s.loop_end = p.loop_end
	}
	for sm in p.samples {
		sample_retain(sm)
		append(&s.samples, sm)
	}
	for i in p.instruments {
		c := instrument_clone(i)
		c.graph = 0 // (a track names its graph; see song_instrument_for)
		append(&s.instruments, c)
	}
	instruments_resolve(s.instruments[:], s.samples[:])
	s.graphs = fx_library_clone(p.graphs[:])
	variants: [dynamic]Instrument_Variant
	variants.allocator = context.temp_allocator
	append(&s.note_fx, ..p.note_fx[:])
	if mode == .Save {
		for &x in p.ext {
			if string(x.id[:]) != SCOR_CHUNK {
				append(&s.ext, ext_chunk_copy(x))
			}
		}
	}

	// The first song track holds what belongs to the whole song.
	conductor := Track {
		name = strings.clone("conductor"),
	}
	for t in p.tempo {
		append(&conductor.events, Event{tick = t.tick, kind = .Tempo, a = t.us})
	}
	m := &p.master
	if .Room in m.set {
		append(&conductor.events, Event{kind = .Control, a = SCORE_CC_ROOM, b = i32(clamp(m.room, 0, 1) * 127 + 0.5)})
	}
	if .Damping in m.set {
		append(&conductor.events, Event{kind = .Control, a = SCORE_CC_DAMPING, b = i32(clamp(m.damping, 0, 1) * 127 + 0.5)})
	}
	if .Delay_Time in m.set {
		append(&conductor.events, Event{kind = .Control, a = CC_DELAY_TIME, b = clamp(i32(m.delay_time * 100 + 0.5), 1, 127)})
	}
	if .Delay_Feedback in m.set {
		append(&conductor.events, Event{kind = .Control, a = CC_DELAY_FEEDBACK, b = i32(clamp(m.delay_feedback, 0, 1) * 127 + 0.5)})
	}
	if .Delay_Tone in m.set {
		append(&conductor.events, Event{kind = .Control, a = CC_DELAY_TONE, b = i32(clamp(m.delay_tone, 0, 1) * 127 + 0.5)})
	}
	if .Delay_Ping_Pong in m.set {
		append(&conductor.events, Event{kind = .Control, a = CC_DELAY_STEREO, b = 127 if m.delay_ping_pong else 0})
	}
	if .Delay_Sync in m.set {
		append(&conductor.events, Event{kind = .Control, a = CC_DELAY_SYNC, b = i32(clamp(m.delay_sync, 0, DELAY_SYNC_COUNT))})
	}
	append(&conductor.events, ..p.global_extra[:])
	append(&s.tracks, conductor)

	any_solo := false
	for &t in p.tracks {
		any_solo ||= t.solo
	}
	lane_of := make([]u8, len(p.notes), context.temp_allocator)
	lanes := score_lanes(p, lane_of)

	// The channels, handed out in order.
	base_of := make([]int, len(p.tracks), context.temp_allocator)
	next := 0
	for ti in 0 ..< len(p.tracks) {
		base_of[ti] = min(next, CHANNELS - 1)
		next += lanes[ti]
	}

	scor: Writer
	scor.buf.allocator = context.temp_allocator
	w_varlen(&scor, u32(len(p.tracks)))
	for &t, ti in p.tracks {
		st := Track {
			name = strings.clone(score_name_str(&t.name)),
		}
		song_inst := song_instrument_for(&s, p, &variants, t.inst, t.graph)
		for lane in 0 ..< lanes[ti] {
			ch := u8(min(base_of[ti] + lane, CHANNELS - 1))
			if song_inst >= 0 {
				append(&st.events, Event{tick = 0, kind = .Set_Instrument, channel = ch, a = i32(song_inst)})
			}
			if .Volume in t.set {
				append(&st.events, Event{kind = .Control, channel = ch, a = SCORE_CC_VOLUME, b = i32(clamp(t.volume, 0, 1) * 127 + 0.5)})
			}
			if .Pan in t.set {
				append(&st.events, Event{kind = .Control, channel = ch, a = SCORE_CC_PAN, b = clamp(i32(clamp(t.pan, -1, 1) * 63 + 64.5), 0, 127)})
			}
			if .Reverb in t.set {
				append(&st.events, Event{kind = .Control, channel = ch, a = SCORE_CC_REVERB, b = i32(clamp(t.reverb, 0, 1) * 127 + 0.5)})
			}
			if .Delay in t.set {
				append(&st.events, Event{kind = .Control, channel = ch, a = CC_DELAY_SEND, b = i32(clamp(t.delay, 0, 1) * 127 + 0.5)})
			}
			for e in t.extra {
				x := e
				x.channel = ch
				if x.kind == .Set_Instrument && t.graph != 0 && x.a >= 0 && int(x.a) < len(p.instruments) { // (the track's graph goes on playing after a change of instrument)
					x.a = i32(song_instrument_for(&s, p, &variants, int(x.a), t.graph))
				}
				append(&st.events, x)
			}
		}
		append(&s.tracks, st)
		w_str(&scor, score_name_str(&t.name))
		w_varlen(&scor, u32(base_of[ti]))
		w_varlen(&scor, u32(lanes[ti]))
	}
	for n, ni in p.notes {
		if n.track < 0 || n.track >= len(p.tracks) {
			continue
		}
		t := &p.tracks[n.track]
		if mode != .Save && (t.mute || (any_solo && !t.solo)) {
			continue
		}
		ch := u8(min(base_of[n.track] + int(lane_of[ni]), CHANNELS - 1))
		st := &s.tracks[1 + n.track]
		append(&st.events, Event{tick = n.start, kind = .Note_On, channel = ch, a = i32(n.key), b = i32(n.vel), fx = n.fx})
		if n.len > 0 {
			append(&st.events, Event{tick = n.start + n.len, kind = .Note_Off, channel = ch, a = i32(n.key)})
		}
	}
	if mode == .Save {
		song_ext_set(&s, SCOR_CHUNK, scor.buf[:])
	}
	song_finish(&s)
	return s
}
