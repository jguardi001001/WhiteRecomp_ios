package iv_snd

import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Song files.
//
//  * The native binary format ("PSNG"): compact, delta-timed like MIDI, and it
//    stores the instruments of the song (lists of zones that play synth patches or
//    recordings) and the recordings the zones play.
//  * Import of Standard MIDI Files (.mid, formats 0 and 1), so songs can be
//    written in any sequencer. The MIDI program numbers are mapped onto ordinary
//    instruments of the song (see "MIDI programs" below); the loop points are taken
//    from "loopStart" / "loopEnd" markers or controller 111. Songs are not exported as MIDI.
//
// Layout of a PSNG file, version 4 (varlen = MIDI-style variable length integer):
//   "PSNG" u8 version
//   varlen ticks_per_beat, loop_start, loop_end, end_tick
//   string name                      (varlen length + bytes)
//   varlen instrument_count, then per instrument (instrument_encode in instrument.odin):
//     string name, varlen zone count and the zones (key range, flags, tuning, a patch of f32 values,
//     and for a zone that plays a recording: its number, root key, loop points)
//   varlen track_count, then per track: string name, varlen event_count, events
//   event: varlen delta_ticks, u8 kind (Event_Kind), u8 channel, payload by kind
//     (Set_Instrument: varlen index into the instrument list)
//   varlen chunk_count, then per chunk: 4 byte id, varlen length, bytes
//     "SAMP"  recordings (PCM only): varlen count, then per sample: string name, varlen rate,
//             varlen frame count, frames as 16 bit little endian numbers (mono). A zone refers to
//             a recording with its sample number + 1.
//     "LIBR"  instruments that are entries of the instrument library (library.odin), kept by name so
//             that their recordings are not stored in the file: varlen count, then per entry varlen
//             instrument index and the string name of the library entry. The instrument itself is
//             written with no zones; on loading it is replaced by a fresh copy of the library entry
//             (a name never changes and neither does the sound of an entry). Only entries that play
//             recordings (the drum kit) are written this way, and only when the song's instrument is
//             exactly the entry; the "SAMP" chunk then leaves out the recordings that only those use.
//     "NFX1"  effects of single notes (note_fx.odin): varlen count, then per effect f32 values
//             (varlen float count first, so more can be added), then varlen count of notes, then per note
//             varlen track, varlen index of its Note_On in the track, varlen index of the effect.
//     "FXG1"  the library of effect graphs (graph.odin): varlen count, then per graph its name and the graph
//             (nodes with their parameters, and wires); then varlen count of instruments that play through a
//             graph, and per instrument its varlen index and the varlen number of its graph (1 = the first).
//     any other id is kept as it is in Song.ext (the sound editor stores its own
//     settings in "EDIT"); programs that do not know a chunk simply ignore it.
//
// Only this version is read: files of other versions are refused.
// ---------------------------------------------------------------------------

SONG_MAGIC :: "PSNG"
SONG_VERSION :: u8(4)

// ---- byte writer / reader ----------------------------------------------------------

Writer :: struct {
	buf: [dynamic]u8,
}

w_u8 :: proc(w: ^Writer, v: u8) {
	append(&w.buf, v)
}

w_varlen :: proc(w: ^Writer, value: u32) {
	v := value
	tmp: [5]u8
	n := 0
	tmp[0] = u8(v & 0x7f)
	n = 1
	v >>= 7
	for v > 0 {
		tmp[n] = u8(v & 0x7f) | 0x80
		n += 1
		v >>= 7
	}
	for i := n - 1; i >= 0; i -= 1 {
		append(&w.buf, tmp[i])
	}
}

w_f32 :: proc(w: ^Writer, v: f32) {
	u := transmute(u32)v
	append(&w.buf, u8(u), u8(u >> 8), u8(u >> 16), u8(u >> 24))
}

w_str :: proc(w: ^Writer, s: string) {
	w_varlen(w, u32(len(s)))
	for i in 0 ..< len(s) {
		append(&w.buf, s[i])
	}
}

Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool,
}

r_u8 :: proc(r: ^Reader) -> u8 {
	if r.pos >= len(r.data) {
		r.ok = false
		return 0
	}
	v := r.data[r.pos]
	r.pos += 1
	return v
}

r_varlen :: proc(r: ^Reader) -> u32 {
	v: u32 = 0
	for _ in 0 ..< 5 {
		b := r_u8(r)
		v = (v << 7) | u32(b & 0x7f)
		if (b & 0x80) == 0 {
			return v
		}
	}
	r.ok = false
	return v
}

r_f32 :: proc(r: ^Reader) -> f32 {
	u := u32(r_u8(r)) | (u32(r_u8(r)) << 8) | (u32(r_u8(r)) << 16) | (u32(r_u8(r)) << 24)
	return transmute(f32)u
}

r_str :: proc(r: ^Reader, allocator := context.allocator) -> string {
	n := int(r_varlen(r))
	if n < 0 || r.pos + n > len(r.data) {
		r.ok = false
		return ""
	}
	s := strings.clone(string(r.data[r.pos:r.pos + n]), allocator)
	r.pos += n
	return s
}

// ---- native format ----------------------------------------------------------------

song_encode :: proc(s: ^Song, allocator := context.allocator) -> []u8 {
	w: Writer
	w.buf.allocator = allocator
	magic := SONG_MAGIC
	for i in 0 ..< len(magic) {
		w_u8(&w, magic[i])
	}
	w_u8(&w, SONG_VERSION)
	w_varlen(&w, s.ticks_per_beat)
	w_varlen(&w, s.loop_start)
	w_varlen(&w, s.loop_end)
	w_varlen(&w, s.end_tick)
	w_str(&w, s.name)

	// Instruments that are unchanged library entries with recordings are written by name (chunk "LIBR"), and
	// the recordings that only they use are left out of "SAMP". sample_map: old index -> index in the file, -1 = left out.
	lib_of := make([]int, len(s.instruments), context.temp_allocator) // library index + 1, 0 = written in full
	nlib := 0
	for inst, i in s.instruments {
		if li, ok := instrument_library_ref(inst); ok {
			lib_of[i] = li + 1
			nlib += 1
		}
	}
	sample_map := make([]i32, len(s.samples), context.temp_allocator)
	nsamples := len(s.samples)
	if nlib > 0 {
		in_lib := make([]bool, len(s.samples), context.temp_allocator)
		in_full := make([]bool, len(s.samples), context.temp_allocator)
		for inst, i in s.instruments {
			for z in inst.zones {
				if z.sample_id > 0 && int(z.sample_id) <= len(s.samples) {
					if lib_of[i] > 0 {
						in_lib[z.sample_id - 1] = true
					} else {
						in_full[z.sample_id - 1] = true
					}
				}
			}
		}
		nsamples = 0
		for k in 0 ..< len(s.samples) {
			if in_lib[k] && !in_full[k] {
				sample_map[k] = -1
			} else {
				sample_map[k] = i32(nsamples)
				nsamples += 1
			}
		}
	} else {
		for k in 0 ..< len(s.samples) {
			sample_map[k] = i32(k)
		}
	}

	w_varlen(&w, u32(len(s.instruments)))
	for inst, i in s.instruments {
		if lib_of[i] > 0 {
			w_str(&w, instrument_name(inst))
			w_varlen(&w, 0) // no zones: "LIBR" says what it is
		} else {
			instrument_encode(&w, inst, sample_map)
		}
	}

	w_varlen(&w, u32(len(s.tracks)))
	for &t in s.tracks {
		w_str(&w, t.name)
		w_varlen(&w, u32(len(t.events)))
		prev: u32 = 0
		for e in t.events {
			w_varlen(&w, e.tick - prev)
			prev = e.tick
			w_u8(&w, u8(e.kind))
			w_u8(&w, e.channel)
			switch e.kind {
			case .Set_Instrument:
				w_varlen(&w, u32(max(e.a, 0)))
			case .Tempo:
				w_varlen(&w, u32(e.a))
			case .Control:
				w_u8(&w, u8(e.a))
				w_u8(&w, u8(e.b))
			case .Set_Patch_Param:
				w_u8(&w, u8(e.a))
				w_f32(&w, e.v)
			case .Pitch_Bend:
				v := u32(e.a + 8192)
				w_u8(&w, u8(v & 0x7f))
				w_u8(&w, u8((v >> 7) & 0x7f))
			case .Note_Off:
				w_u8(&w, u8(e.a))
			case .Note_On:
				w_u8(&w, u8(e.a))
				w_u8(&w, u8(e.b))
			}
		}
	}

	// Chunks.
	nchunks := 0
	for &c in s.ext {
		if !chunk_is_builtin(c.id) {
			nchunks += 1
		}
	}
	nfx_notes := 0 // notes that have effects
	for &t in s.tracks {
		for e in t.events {
			if e.kind == .Note_On && e.fx > 0 && int(e.fx) <= len(s.note_fx) {
				nfx_notes += 1
			}
		}
	}
	has_note_fx := nfx_notes > 0
	if has_note_fx {
		nchunks += 1
	}
	fxg := fx_graphs_chunk(s) // the library of effect graphs and who uses which (graph.odin)
	if fxg != nil {
		nchunks += 1
	}
	has_samples := nsamples > 0
	if has_samples {
		nchunks += 1
	}
	if nlib > 0 {
		nchunks += 1
	}
	w_varlen(&w, u32(nchunks))
	if has_samples {
		sw: Writer
		sw.buf.allocator = context.temp_allocator
		w_varlen(&sw, u32(nsamples))
		for sm, k in s.samples {
			if sample_map[k] < 0 {
				continue
			}
			w_str(&sw, sample_name(sm))
			w_varlen(&sw, u32(sm.rate))
			w_varlen(&sw, u32(len(sm.data)))
			reserve(&sw.buf, len(sw.buf) + len(sm.data) * 2)
			for v in sm.data {
				u := u16(v)
				append(&sw.buf, u8(u), u8(u >> 8))
			}
		}
		w_chunk(&w, "SAMP", sw.buf[:])
	}
	if nlib > 0 {
		lw: Writer
		lw.buf.allocator = context.temp_allocator
		w_varlen(&lw, u32(nlib))
		for li, i in lib_of {
			if li > 0 {
				w_varlen(&lw, u32(i))
				w_str(&lw, library_name(li - 1))
			}
		}
		w_chunk(&w, "LIBR", lw.buf[:])
	}
	if has_note_fx {
		fw: Writer
		fw.buf.allocator = context.temp_allocator
		w_varlen(&fw, u32(len(s.note_fx)))
		for fx in s.note_fx {
			vals := note_fx_pack(fx)
			w_varlen(&fw, NOTE_FX_FLOATS)
			for v in vals {
				w_f32(&fw, v)
			}
		}
		w_varlen(&fw, u32(nfx_notes))
		for &t, ti in s.tracks {
			for e, ei in t.events {
				if e.kind == .Note_On && e.fx > 0 && int(e.fx) <= len(s.note_fx) {
					w_varlen(&fw, u32(ti))
					w_varlen(&fw, u32(ei))
					w_varlen(&fw, u32(e.fx - 1))
				}
			}
		}
		w_chunk(&w, "NFX1", fw.buf[:])
	}
	if fxg != nil {
		w_chunk(&w, "FXG1", fxg)
	}
	for &c in s.ext {
		if !chunk_is_builtin(c.id) {
			w_chunk(&w, string(c.id[:]), c.data[:])
		}
	}
	return w.buf[:]
}

// The chunks the library writes itself (an Ext_Chunk of such an id is not written).
chunk_is_builtin :: proc(id: [4]u8) -> bool {
	i := id
	return string(i[:]) == "SAMP" || string(i[:]) == "NFX1" || string(i[:]) == "LIBR" || string(i[:]) == "FXG1"
}

w_chunk :: proc(w: ^Writer, id: string, data: []u8) {
	for i in 0 ..< 4 {
		append(&w.buf, id[i])
	}
	w_varlen(w, u32(len(data)))
	append(&w.buf, ..data)
}

song_decode :: proc(data: []u8, allocator := context.allocator) -> (song: Song, ok: bool) {
	r := Reader {
		data = data,
		ok   = true,
	}
	if len(data) < 5 || string(data[0:4]) != SONG_MAGIC {
		return {}, false
	}
	r.pos = 4
	version := r_u8(&r)
	if version != SONG_VERSION {
		return {}, false
	}

	s: Song
	s.tracks.allocator = allocator
	s.instruments.allocator = allocator
	s.samples.allocator = allocator
	s.note_fx.allocator = allocator
	s.ext.allocator = allocator
	s.owns_strings = true
	s.ticks_per_beat = max(r_varlen(&r), 1)
	s.loop_start = r_varlen(&r)
	s.loop_end = r_varlen(&r)
	s.end_tick = r_varlen(&r)
	s.name = r_str(&r, allocator)

	ninst := int(r_varlen(&r))
	for _ in 0 ..< ninst {
		if !r.ok {
			break
		}
		append(&s.instruments, instrument_decode(&r))
	}

	ntracks := int(r_varlen(&r))
	for _ in 0 ..< ntracks {
		if !r.ok {
			break
		}
		t := Track {
			name = r_str(&r, allocator),
		}
		t.events.allocator = allocator
		nev := int(r_varlen(&r))
		tick: u32 = 0
		for _ in 0 ..< nev {
			if !r.ok {
				break
			}
			tick += r_varlen(&r)
			kind_raw := r_u8(&r)
			e: Event
			if int(kind_raw) > int(max(Event_Kind)) {
				r.ok = false
				break
			}
			e.kind = Event_Kind(kind_raw)
			e.tick = tick
			e.channel = r_u8(&r) // (the synthesizer ignores a channel it does not have)
			switch e.kind {
			case .Set_Instrument:
				e.a = i32(min(r_varlen(&r), 1 << 20))
			case .Tempo:
				e.a = i32(r_varlen(&r))
			case .Control:
				e.a = i32(r_u8(&r) & 127)
				e.b = i32(r_u8(&r) & 127)
			case .Set_Patch_Param:
				e.a = i32(r_u8(&r))
				e.v = r_f32(&r)
			case .Pitch_Bend:
				lo := i32(r_u8(&r) & 0x7f)
				hi := i32(r_u8(&r) & 0x7f)
				e.a = (hi << 7 | lo) - 8192
			case .Note_Off:
				e.a = i32(r_u8(&r) & 127)
			case .Note_On:
				e.a = i32(r_u8(&r) & 127)
				e.b = i32(r_u8(&r) & 127)
			}
			append(&t.events, e)
		}
		append(&s.tracks, t)
	}
	Lib_Ref :: struct {
		inst: int, // index in Song.instruments
		name: string, // the library entry
	}
	lib_refs: [dynamic]Lib_Ref
	lib_refs.allocator = context.temp_allocator
	fxg_body: []u8 // the effect graphs, applied once the instruments are final
	if r.ok {
		nchunks := int(r_varlen(&r))
		for _ in 0 ..< nchunks {
			if !r.ok {
				break
			}
			id: [4]u8
			for i in 0 ..< 4 {
				id[i] = r_u8(&r)
			}
			n := int(r_varlen(&r))
			if !r.ok || n < 0 || r.pos + n > len(r.data) {
				r.ok = false
				break
			}
			body := r.data[r.pos:r.pos + n]
			r.pos += n
			if string(id[:]) == "NFX1" {
				fr := Reader {
					data = body,
					ok   = true,
				}
				count := int(r_varlen(&fr))
				for _ in 0 ..< count {
					if !fr.ok {
						break
					}
					nf := int(r_varlen(&fr))
					vals := make([]f32, nf, context.temp_allocator)
					for i in 0 ..< nf {
						vals[i] = r_f32(&fr)
					}
					append(&s.note_fx, note_fx_unpack(vals))
				}
				nnotes := int(r_varlen(&fr))
				for _ in 0 ..< nnotes {
					if !fr.ok {
						break
					}
					ti := int(r_varlen(&fr))
					ei := int(r_varlen(&fr))
					fi := int(r_varlen(&fr))
					if fr.ok && ti < len(s.tracks) && ei < len(s.tracks[ti].events) && fi < len(s.note_fx) {
						e := &s.tracks[ti].events[ei]
						if e.kind == .Note_On {
							e.fx = u16(fi + 1)
						}
					}
				}
			} else if string(id[:]) == "FXG1" {
				fxg_body = body
			} else if string(id[:]) == "SAMP" {
				if !samples_decode(body, &s.samples) {
					r.ok = false
				}
			} else if string(id[:]) == "LIBR" {
				lr := Reader {
					data = body,
					ok   = true,
				}
				count := int(r_varlen(&lr))
				for _ in 0 ..< count {
					if !lr.ok {
						break
					}
					idx := int(r_varlen(&lr))
					append(&lib_refs, Lib_Ref{idx, r_str(&lr, context.temp_allocator)})
				}
				if !lr.ok {
					r.ok = false
				}
			} else {
				c := Ext_Chunk {
					id = id,
				}
				c.data.allocator = allocator
				append(&c.data, ..body)
				append(&s.ext, c)
			}
		}
	}
	// Instruments kept by name become fresh copies of their library entries (the recordings are the library's,
	// shared, and the song takes a share of each).
	for ref in lib_refs {
		if !r.ok {
			break
		}
		li, found := library_find(ref.name)
		if !found || ref.inst < 0 || ref.inst >= len(s.instruments) {
			r.ok = false
			break
		}
		instrument_destroy(s.instruments[ref.inst])
		fresh := library_instrument(li)
		song_attach_samples(&s, fresh)
		s.instruments[ref.inst] = fresh
	}
	if r.ok && fxg_body != nil && !fx_graphs_apply(fxg_body, &s) {
		r.ok = false
	}
	if !r.ok {
		song_destroy(&s)
		return {}, false
	}
	instruments_resolve(s.instruments[:], s.samples[:]) // (after all the chunks: the instruments may come before the samples)
	return s, true
}

// Reads the "SAMP" chunk.
samples_decode :: proc(body: []u8, into: ^[dynamic]^Sample) -> bool {
	sr := Reader {
		data = body,
		ok   = true,
	}
	count := int(r_varlen(&sr))
	for _ in 0 ..< count {
		if !sr.ok {
			break
		}
		sm := new(Sample)
		sm.refs = 1
		sm.label = patch_label_make(r_str(&sr, context.temp_allocator))
		sm.rate = int(r_varlen(&sr))
		frames := int(r_varlen(&sr))
		if !sr.ok || frames < 0 || frames > MAX_SAMPLE_FRAMES || sr.pos + frames * 2 > len(sr.data) || sm.rate <= 0 {
			sr.ok = false
			free(sm)
			break
		}
		sm.data = make([]i16, frames)
		for i in 0 ..< frames {
			sm.data[i] = i16(u16(sr.data[sr.pos]) | u16(sr.data[sr.pos + 1]) << 8)
			sr.pos += 2
		}
		append(into, sm)
	}
	return sr.ok
}

song_save :: proc(s: ^Song, path: string) -> bool {
	data := song_encode(s, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}

song_load :: proc(path: string, allocator := context.allocator) -> (Song, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	if len(data) >= 4 && string(data[0:4]) == "MThd" {
		return song_from_midi(data, allocator)
	}
	return song_decode(data, allocator)
}

// ---- Standard MIDI File import -----------------------------------------------------

be16 :: proc(d: []u8, p: int) -> u32 {
	return u32(d[p]) << 8 | u32(d[p + 1])
}

be32 :: proc(d: []u8, p: int) -> u32 {
	return u32(d[p]) << 24 | u32(d[p + 1]) << 16 | u32(d[p + 2]) << 8 | u32(d[p + 3])
}

song_from_midi :: proc(data: []u8, allocator := context.allocator) -> (song: Song, ok: bool) {
	if len(data) < 14 || string(data[0:4]) != "MThd" {
		return {}, false
	}
	hdr_len := int(be32(data, 4))
	ntrks := int(be16(data, 10))
	division := be16(data, 12)
	if (division & 0x8000) != 0 || division == 0 {
		return {}, false // SMPTE time is not supported
	}

	s: Song
	s.tracks.allocator = allocator
	s.instruments.allocator = allocator
	s.samples.allocator = allocator
	s.owns_strings = true
	s.name = strings.clone("midi", allocator)
	s.ticks_per_beat = division

	pos := 8 + hdr_len
	for _ in 0 ..< ntrks {
		if pos + 8 > len(data) || string(data[pos:pos + 4]) != "MTrk" {
			break
		}
		tlen := int(be32(data, pos + 4))
		start := pos + 8
		end := min(start + tlen, len(data))
		pos = start + tlen

		t := Track {
			name = strings.clone("track", allocator),
		}
		t.events.allocator = allocator
		r := Reader {
			data = data[:end],
			pos  = start,
			ok   = true,
		}
		tick: u32 = 0
		status: u8 = 0
		for r.pos < end && r.ok {
			tick += r_varlen(&r)
			b := r_u8(&r)
			if b >= 0x80 {
				status = b
			} else {
				r.pos -= 1 // running status: this byte is data
			}
			if status == 0xFF { // meta event
				mtype := r_u8(&r)
				mlen := int(r_varlen(&r))
				if r.pos + mlen > end {
					break
				}
				body := data[r.pos:r.pos + mlen]
				r.pos += mlen
				switch mtype {
				case 0x51:
					if mlen == 3 {
						us := i32(u32(body[0]) << 16 | u32(body[1]) << 8 | u32(body[2]))
						append(&t.events, Event{tick = tick, kind = .Tempo, a = us})
					}
				case 0x03:
					delete(t.name)
					t.name = strings.clone(string(body), allocator)
				case 0x01, 0x06:
					low := strings.to_lower(string(body), context.temp_allocator)
					if strings.contains(low, "loopstart") {
						s.loop_start = tick
					} else if strings.contains(low, "loopend") {
						s.loop_end = tick
					}
				case 0x2F:
					s.end_tick = max(s.end_tick, tick)
				}
				status = 0
				continue
			}
			if status == 0xF0 || status == 0xF7 { // sysex: skip
				n := int(r_varlen(&r))
				r.pos += n
				status = 0
				continue
			}
			if status < 0x80 {
				break
			}
			kind := status & 0xF0
			ch := status & 0x0F
			switch kind {
			case 0x80:
				key := r_u8(&r) & 127
				_ = r_u8(&r)
				append(&t.events, Event{tick = tick, kind = .Note_Off, channel = ch, a = i32(key)})
			case 0x90:
				key := r_u8(&r) & 127
				vel := r_u8(&r) & 127
				if vel == 0 {
					append(&t.events, Event{tick = tick, kind = .Note_Off, channel = ch, a = i32(key)})
				} else {
					append(&t.events, Event{tick = tick, kind = .Note_On, channel = ch, a = i32(key), b = i32(vel)})
				}
			case 0xA0:
				_ = r_u8(&r)
				_ = r_u8(&r)
			case 0xB0:
				cc := r_u8(&r) & 127
				val := r_u8(&r) & 127
				if cc == 111 {
					s.loop_start = tick
				} else {
					append(&t.events, Event{tick = tick, kind = .Control, channel = ch, a = i32(cc), b = i32(val)})
				}
			case 0xC0:
				prog := r_u8(&r) & 127
				// (a placeholder: midi_map_programs makes an instrument of it)
				append(&t.events, Event{tick = tick, kind = .Set_Instrument, channel = ch, a = i32(prog)})
			case 0xD0:
				_ = r_u8(&r)
			case 0xE0:
				lo := i32(r_u8(&r) & 127)
				hi := i32(r_u8(&r) & 127)
				append(&t.events, Event{tick = tick, kind = .Pitch_Bend, channel = ch, a = (hi << 7 | lo) - 8192})
			case:
				r.ok = false
			}
		}
		append(&s.tracks, t)
	}
	if len(s.tracks) == 0 {
		song_destroy(&s)
		return {}, false
	}
	midi_map_programs(&s)
	song_finish(&s)
	return s, true
}

// ---- MIDI programs: from General MIDI program numbers to instruments -------------------------------
//
// A MIDI file picks what a channel plays with program numbers (0..127) that mean a General MIDI sound. A song
// of this package has instruments instead, so the importer maps them: each program becomes an ordinary synth
// instrument named like the program (MIDI_PROGRAM_NAMES, midi_program_patch), made once per song. Nothing of
// the MIDI numbering stays in the song.
//

@(rodata)
MIDI_PROGRAM_NAMES := [128]string {
	"Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano", "Honky-tonk Piano",
	"Electric Piano 1", "Electric Piano 2", "Harpsichord", "Clavinet",
	"Celesta", "Glockenspiel", "Music Box", "Vibraphone",
	"Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
	"Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ",
	"Reed Organ", "Accordion", "Harmonica", "Tango Accordion",
	"Nylon Guitar", "Steel Guitar", "Jazz Guitar", "Clean Guitar",
	"Muted Guitar", "Overdriven Guitar", "Distortion Guitar", "Guitar Harmonics",
	"Acoustic Bass", "Finger Bass", "Pick Bass", "Fretless Bass",
	"Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
	"Violin", "Viola", "Cello", "Contrabass",
	"Tremolo Strings", "Pizzicato Strings", "Orchestral Harp", "Timpani",
	"String Ensemble 1", "String Ensemble 2", "Synth Strings 1", "Synth Strings 2",
	"Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
	"Trumpet", "Trombone", "Tuba", "Muted Trumpet",
	"French Horn", "Brass Section", "Synth Brass 1", "Synth Brass 2",
	"Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax",
	"Oboe", "English Horn", "Bassoon", "Clarinet",
	"Piccolo", "Flute", "Recorder", "Pan Flute",
	"Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
	"Lead 1 (square)", "Lead 2 (sawtooth)", "Lead 3 (calliope)", "Lead 4 (chiff)",
	"Lead 5 (charang)", "Lead 6 (voice)", "Lead 7 (fifths)", "Lead 8 (bass+lead)",
	"Pad 1 (new age)", "Pad 2 (warm)", "Pad 3 (polysynth)", "Pad 4 (choir)",
	"Pad 5 (bowed)", "Pad 6 (metallic)", "Pad 7 (halo)", "Pad 8 (sweep)",
	"FX 1 (rain)", "FX 2 (soundtrack)", "FX 3 (crystal)", "FX 4 (atmosphere)",
	"FX 5 (brightness)", "FX 6 (goblins)", "FX 7 (echoes)", "FX 8 (sci-fi)",
	"Sitar", "Banjo", "Shamisen", "Koto",
	"Kalimba", "Bagpipe", "Fiddle", "Shanai",
	"Tinkle Bell", "Agogo", "Steel Drums", "Woodblock",
	"Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
	"Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet",
	"Telephone Ring", "Helicopter", "Applause", "Gunshot",
}

// The synth patch a General MIDI program number is mapped onto when a MIDI file (or an old song file) is
// loaded. The mapping is a rough one by family: pianos, bells, organs, plucked and bowed strings, brass,
// reeds, pipes, leads, pads and effects each get one of the basic sounds of patch.odin.
midi_program_patch :: proc(program: int) -> Patch {
	switch program / 8 {
	case 0: // pianos
		switch program {
		case 4, 5:
			return patch_epiano()
		case 6, 7:
			return patch_pluck()
		}
		return patch_piano()
	case 1: // chromatic percussion
		return patch_bell()
	case 2: // organs
		return patch_organ()
	case 3: // guitars
		p := patch_pluck()
		if program >= 29 {
			p.filter.cutoff = 1800
			p.osc[1].level = 0.5
		}
		return p
	case 4: // basses
		return patch_bass()
	case 5: // strings
		if program == 46 {
			return patch_pluck()
		}
		return patch_strings()
	case 6: // ensemble
		if program >= 52 && program <= 54 {
			return patch_pad()
		}
		return patch_strings()
	case 7: // brass
		return patch_brass()
	case 8: // reeds
		return patch_reed()
	case 9: // pipes
		return patch_flute()
	case 10: // synth leads
		if program % 2 == 0 {
			return patch_lead_square()
		}
		return patch_lead_saw()
	case 11: // synth pads
		return patch_pad()
	case 12: // synth effects
		return patch_noise_fx()
	case 13: // ethnic
		return patch_pluck()
	case 14: // percussive
		return patch_bell()
	}
	return patch_noise_fx()
}

// A new synth instrument for a MIDI program number, named like the program.
midi_program_instrument :: proc(program: int) -> ^Instrument {
	pr := clamp(program, 0, 127)
	return instrument_synth(midi_program_patch(pr), MIDI_PROGRAM_NAMES[pr])
}

// Turns the program changes of a MIDI file (placeholder Set_Instrument events whose `a` is the program number)
// into instruments of the song and real Set_Instrument events that refer to them. On channel 10 a program is
// dropped (a drum channel plays drums whatever its program); if that channel plays notes, the library's
// "Standard Drums" is put on it at tick 0 (with a reverb send, unless the file sets one).
midi_map_programs :: proc(s: ^Song) {
	DEAD :: u8(255) // marks an event to remove
	known: [128]int // program -> index of the instrument made for it, -1 = not yet
	for i in 0 ..< 128 {
		known[i] = -1
	}
	for &t in s.tracks {
		for &e in t.events {
			if e.kind != .Set_Instrument {
				continue
			}
			if e.channel == 9 {
				e.channel = DEAD
				continue
			}
			prog := clamp(int(e.a), 0, 127)
			if known[prog] < 0 {
				known[prog] = song_add_instrument(s, midi_program_instrument(prog))
			}
			e.a = i32(known[prog])
		}
	}

	// Channel 10 plays drums: give it the standard kit if it has notes.
	first_note := max(u32)
	reverb_set := false
	for &t in s.tracks {
		for e in t.events {
			if e.channel != 9 {
				continue
			}
			#partial switch e.kind {
			case .Note_On:
				first_note = min(first_note, e.tick)
			case .Control:
				if e.a == 91 && e.tick == 0 {
					reverb_set = true
				}
			}
		}
	}
	if first_note != max(u32) && len(s.tracks) > 0 {
		if lib, ok := library_find("Standard Drums"); ok {
			di := song_add_instrument(s, library_instrument(lib))
			front: [2]Event
			n := 0
			front[n] = Event{tick = 0, kind = .Set_Instrument, channel = 9, a = i32(di)}
			n += 1
			if !reverb_set {
				front[n] = Event{tick = 0, kind = .Control, channel = 9, a = 91, b = 15}
				n += 1
			}
			inject_at(&s.tracks[0].events, 0, ..front[:n])
		}
	}

	for &t in s.tracks {
		keep := 0
		for e in t.events {
			if e.channel != DEAD {
				t.events[keep] = e
				keep += 1
			}
		}
		resize(&t.events, keep)
	}
}
