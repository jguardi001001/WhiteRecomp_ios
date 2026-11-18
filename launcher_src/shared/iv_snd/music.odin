package iv_snd

import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// Music data: a song.
//
// A song is a set of tracks, each a list of timed events (ticks). It carries its own
// instruments (Song.instruments, see instrument.odin) and the recordings the sample
// zones of those play (Song.samples). Events play notes, change what a channel plays
// (Set_Instrument), move controllers (volume, pan, reverb ...), bend the pitch, change
// the tempo, or change one parameter of a channel's instrument while it plays
// (Set_Patch_Param: filter sweeps and the like). There are CHANNELS (128) channels; a channel
// plays one instrument at a time, and any channel can play any instrument.
// ---------------------------------------------------------------------------

// The order of the kinds is the order events are handled in when several share a
// tick: instrument setup first, notes last, note-offs before note-ons.
Event_Kind :: enum u8 {
	Tempo, // a = microseconds per quarter note
	Set_Instrument, // a = index into Song.instruments
	Control, // a = controller number, b = value 0..127
	Set_Patch_Param, // a = Patch_Param, v = new value
	Pitch_Bend, // a = -8192..8191
	Note_Off, // a = key
	Note_On, // a = key, b = velocity 1..127
}

Event :: struct {
	tick:    u32,
	kind:    Event_Kind,
	channel: u8, // 0..CHANNELS-1 (an event for a channel the synthesizer does not have is ignored)
	fx:      u16, // Note_On only: 1 + the index of the note's own effects in Song.note_fx (0 = none), see note_fx.odin
	a:       i32,
	b:       i32,
	v:       f32,
}

Track :: struct {
	name:   string,
	events: [dynamic]Event,
}

// A short name for an instrument (fixed size, NUL padded: no allocation).
PATCH_LABEL_LEN :: 24
Patch_Label :: [PATCH_LABEL_LEN]u8

// A chunk of extra data stored in a song file under a 4 letter id. The library does not
// look inside: tools (the sound editor) keep their own settings here, and the
// chunks survive loading and saving.
Ext_Chunk :: struct {
	id:   [4]u8,
	data: [dynamic]u8,
}

Song :: struct {
	name:           string,
	ticks_per_beat: u32,
	tracks:         [dynamic]Track,
	instruments:    [dynamic]^Instrument, // what the channels can play (Set_Instrument events refer to them by index); the song owns them
	samples:        [dynamic]^Sample, // recordings the sample zones play (Zone.sample_id = index + 1); the song holds a share of each
	note_fx:        [dynamic]Note_Fx, // effects of single notes (vibrato, portamento) that Note_On events refer to with Event.fx
	graphs:         [dynamic]Fx_Graph, // the library of effect graphs (graph.odin); Instrument.graph picks one by number
	ext:            [dynamic]Ext_Chunk,
	loop_start:     u32, // tick the song jumps back to when it loops
	loop_end:       u32, // tick it loops at (0 = the end of the song)
	end_tick:       u32, // length of the song (0 = the last event)
	owns_strings:   bool, // the names were allocated (loaded from a file)
}

DEFAULT_TEMPO_US :: 500000 // 120 beats per minute

// ---- building songs in code ------------------------------------------------------

song_init :: proc(s: ^Song, name: string, bpm: f32 = 120, ticks_per_beat: u32 = 480) {
	s^ = {}
	s.name = name
	s.ticks_per_beat = ticks_per_beat
	t := song_add_track(s, "conductor")
	song_tempo(s, t, 0, bpm)
}

song_destroy :: proc(s: ^Song) {
	for &t in s.tracks {
		if s.owns_strings {
			delete(t.name)
		}
		delete(t.events)
	}
	delete(s.tracks)
	for i in s.instruments {
		instrument_destroy(i)
	}
	delete(s.instruments)
	for sm in s.samples {
		sample_release(sm)
	}
	delete(s.samples)
	delete(s.note_fx)
	fx_library_destroy(&s.graphs)
	for &c in s.ext {
		delete(c.data)
	}
	delete(s.ext)
	if s.owns_strings {
		delete(s.name)
	}
	s^ = {}
}

song_add_track :: proc(s: ^Song, name: string) -> int {
	append(&s.tracks, Track{name = name})
	return len(s.tracks) - 1
}

song_add_event :: proc(s: ^Song, track: int, e: Event) {
	append(&s.tracks[track].events, e)
}

// A note of `length` ticks: a Note_On at `tick` and a Note_Off at `tick + length`.
// (song_note_with_fx, in note_fx.odin, makes one with a vibrato and / or portamento of its own.)
song_note :: proc(s: ^Song, track: int, tick, length: u32, channel, key: int, velocity: int = 100) {
	song_add_event(s, track, Event{tick = tick, kind = .Note_On, channel = u8(channel), a = i32(key), b = i32(clamp(velocity, 1, 127))})
	song_add_event(s, track, Event{tick = tick + max(length, 1), kind = .Note_Off, channel = u8(channel), a = i32(key)})
}

song_control :: proc(s: ^Song, track: int, tick: u32, channel, cc, value: int) {
	song_add_event(s, track, Event{tick = tick, kind = .Control, channel = u8(channel), a = i32(cc), b = i32(value)})
}

song_bend :: proc(s: ^Song, track: int, tick: u32, channel, value: int) {
	song_add_event(s, track, Event{tick = tick, kind = .Pitch_Bend, channel = u8(channel), a = i32(clamp(value, -8192, 8191))})
}

song_tempo :: proc(s: ^Song, track: int, tick: u32, bpm: f32) {
	us := i32(60_000_000 / max(bpm, 1))
	song_add_event(s, track, Event{tick = tick, kind = .Tempo, a = us})
}

patch_label_make :: proc(name: string) -> Patch_Label {
	l: Patch_Label
	n := min(len(name), PATCH_LABEL_LEN - 1)
	for i in 0 ..< n {
		l[i] = name[i]
	}
	return l
}

// The text of a label (it points into `l`).
patch_label_string :: proc(l: ^Patch_Label) -> string {
	n := 0
	for n < PATCH_LABEL_LEN && l[n] != 0 {
		n += 1
	}
	return string(l[:n])
}

// ---- extension chunks ---------------------------------------------------------------

song_ext_get :: proc(s: ^Song, id: string) -> []u8 {
	for &c in s.ext {
		if string(c.id[:]) == id {
			return c.data[:]
		}
	}
	return nil
}

// Stores (a copy of) `data` under the 4 letter `id`, replacing an older chunk.
song_ext_set :: proc(s: ^Song, id: string, data: []u8) {
	if len(id) != 4 {
		return
	}
	song_ext_remove(s, id)
	c := Ext_Chunk{}
	for i in 0 ..< 4 {
		c.id[i] = id[i]
	}
	append(&c.data, ..data)
	append(&s.ext, c)
}

song_ext_remove :: proc(s: ^Song, id: string) {
	for i := 0; i < len(s.ext); i += 1 {
		if string(s.ext[i].id[:]) == id {
			delete(s.ext[i].data)
			ordered_remove(&s.ext, i)
			return
		}
	}
}

// A deep copy that owns all its memory (free it with song_destroy).
song_clone :: proc(s: ^Song, allocator := context.allocator) -> Song {
	c: Song
	c.tracks.allocator = allocator
	c.instruments.allocator = allocator
	c.samples.allocator = allocator
	c.note_fx.allocator = allocator
	c.ext.allocator = allocator
	c.name = strings.clone(s.name, allocator)
	c.ticks_per_beat = s.ticks_per_beat
	c.loop_start = s.loop_start
	c.loop_end = s.loop_end
	c.end_tick = s.end_tick
	c.owns_strings = true
	for &t in s.tracks {
		nt := Track {
			name = strings.clone(t.name, allocator),
		}
		nt.events.allocator = allocator
		append(&nt.events, ..t.events[:])
		append(&c.tracks, nt)
	}
	append(&c.note_fx, ..s.note_fx[:])
	for sm in s.samples {
		sample_retain(sm)
		append(&c.samples, sm)
	}
	for i in s.instruments {
		append(&c.instruments, instrument_clone(i))
	}
	c.graphs = fx_library_clone(s.graphs[:])
	for &x in s.ext {
		nx := Ext_Chunk {
			id = x.id,
		}
		nx.data.allocator = allocator
		append(&nx.data, ..x.data[:])
		append(&c.ext, nx)
	}
	return c
}

song_param :: proc(s: ^Song, track: int, tick: u32, channel: int, param: Patch_Param, value: f32) {
	song_add_event(s, track, Event{tick = tick, kind = .Set_Patch_Param, channel = u8(channel), a = i32(param), v = value})
}

event_less :: proc(x, y: Event) -> bool {
	if x.tick != y.tick {
		return x.tick < y.tick
	}
	return x.kind < y.kind
}

// Sort every track by time (events at the same tick keep a sensible order) and
// work out the song length. Call after adding events in any order.
song_finish :: proc(s: ^Song) {
	last: u32 = 0
	for &t in s.tracks {
		slice.stable_sort_by(t.events[:], event_less)
		if len(t.events) > 0 {
			last = max(last, t.events[len(t.events) - 1].tick)
		}
	}
	if s.end_tick < last {
		s.end_tick = last
	}
}

// ---- timing ----------------------------------------------------------------------

// Length of the song in seconds, following its tempo changes.
song_duration_seconds :: proc(s: ^Song) -> f64 {
	Change :: struct {
		tick: u32,
		us:   i32,
	}
	changes: [dynamic]Change
	defer delete(changes)
	for &t in s.tracks {
		for e in t.events {
			if e.kind == .Tempo {
				append(&changes, Change{e.tick, e.a})
			}
		}
	}
	slice.sort_by(changes[:], proc(x, y: Change) -> bool {return x.tick < y.tick})

	end := s.end_tick
	for &t in s.tracks {
		if len(t.events) > 0 {
			end = max(end, t.events[len(t.events) - 1].tick)
		}
	}
	tpb := f64(max(s.ticks_per_beat, 1))
	secs: f64 = 0
	tick: f64 = 0
	us := f64(DEFAULT_TEMPO_US)
	for c in changes {
		if f64(c.tick) >= f64(end) {
			break
		}
		secs += (f64(c.tick) - tick) * us / 1e6 / tpb
		tick = f64(c.tick)
		us = f64(c.us)
	}
	secs += (f64(end) - tick) * us / 1e6 / tpb
	return secs
}

// ---- tempo map ----------------------------------------------------------------------

Tempo_Point :: struct {
	tick:    u32,
	us:      i32, // microseconds per beat from this tick on
	seconds: f64, // time of the tick
}

// The tempo changes of the song in time order, starting with one at tick 0, with the
// time of each in seconds. Free with delete.
song_tempo_map :: proc(s: ^Song, allocator := context.allocator) -> []Tempo_Point {
	changes: [dynamic]Tempo_Point
	changes.allocator = allocator
	for &t in s.tracks {
		for e in t.events {
			if e.kind == .Tempo {
				append(&changes, Tempo_Point{tick = e.tick, us = max(e.a, 1)})
			}
		}
	}
	slice.stable_sort_by(changes[:], proc(x, y: Tempo_Point) -> bool {return x.tick < y.tick})
	// A later change at the same tick wins; make sure tick 0 has one.
	out: [dynamic]Tempo_Point
	out.allocator = allocator
	append(&out, Tempo_Point{tick = 0, us = DEFAULT_TEMPO_US})
	for c in changes {
		if c.tick == out[len(out) - 1].tick {
			out[len(out) - 1].us = c.us
		} else {
			append(&out, c)
		}
	}
	delete(changes)
	tpb := f64(max(s.ticks_per_beat, 1))
	for i in 1 ..< len(out) {
		prev := out[i - 1]
		out[i].seconds = prev.seconds + f64(out[i].tick - prev.tick) * f64(prev.us) / 1e6 / tpb
	}
	return out[:]
}

song_tick_to_seconds :: proc(s: ^Song, tick: u32) -> f64 {
	m := song_tempo_map(s, context.temp_allocator)
	i := 0
	for i + 1 < len(m) && m[i + 1].tick <= tick {
		i += 1
	}
	return m[i].seconds + f64(tick - m[i].tick) * f64(m[i].us) / 1e6 / f64(max(s.ticks_per_beat, 1))
}

song_seconds_to_tick :: proc(s: ^Song, seconds: f64) -> u32 {
	m := song_tempo_map(s, context.temp_allocator)
	i := 0
	for i + 1 < len(m) && m[i + 1].seconds <= seconds {
		i += 1
	}
	ticks := (seconds - m[i].seconds) * 1e6 * f64(max(s.ticks_per_beat, 1)) / f64(m[i].us)
	return m[i].tick + u32(max(ticks, 0))
}

// The last tick of the song: its end_tick or the last event.
song_length_ticks :: proc(s: ^Song) -> u32 {
	end := s.end_tick
	for &t in s.tracks {
		if len(t.events) > 0 {
			end = max(end, t.events[len(t.events) - 1].tick)
		}
	}
	return end
}

// Name of a MIDI key such as "C4" (for debugging output).
key_name :: proc(key: int) -> string {
	names := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
	return names[((key % 12) + 12) % 12]
}

// Beats per minute of a tempo in microseconds per quarter note.
tempo_to_bpm :: proc(us: i32) -> f32 {
	return f32(60_000_000) / f32(max(us, 1))
}

