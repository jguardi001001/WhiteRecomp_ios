package iv_snd

import "core:math"

// ---------------------------------------------------------------------------
// Effects of a single note (not of a channel, an instrument or the whole song).
//
// A note can carry a `Note_Fx`: a vibrato and up to two pitch curves (portamento).
// They are part of the note, so every note of a song can have different ones, or none.
//
//   * Vibrato: the pitch swings up and down around the note. It has a depth in semitones
//     (how far it swings to either side), a period in seconds (the time of one swing), and
//     the part of the note it is active in, as fractions of the note's length: `start` and
//     `end`, 0.0 = the moment the note starts, 1.0 = the moment its note-off comes. A short
//     fade (also a fraction, of the active part) keeps the start and the end smooth.
//
//   * Pitch curve (portamento): the pitch offset, in semitones from the note's own pitch,
//     follows a cubic Bezier curve over the note. A point of the curve is (x, y): x is how far
//     into the note it is (0.0 to 1.0 of the note's length), y the offset in semitones. The
//     curve begins at its first point and ends at its last; before the first point's x the
//     offset stays at the first point's y, after the last point's x it stays at the last
//     point's y. So the same curve can describe a slide into the note ("starting
//     portamento": it begins away from the pitch and arrives after a part of the note), a
//     slide away from it at the end ("trailing portamento": it stays on pitch, then leaves),
//     or anything in between (scoops, falls, a rise that overshoots). Two curves can be used
//     at once and their offsets add: a slide in and a slide out on the same note.
//
// The length of a note is the time between its Note_On and its Note_Off (see
// seq_note_end_tick for how the sequencer finds it). The effects follow the written length of
// the note, not the sound: when the key is up the vibrato is over and a curve holds its last
// value while the sound rings out.
//
// Limits: the effects change the pitch of oscillators and of sample playback. A plucked string
// (the Pluck waveform) gets its pitch from the length of the string when the note starts and so
// does not follow them. The tempo is taken as it is at the start of the note, so a tempo change
// in the middle of a note stretches it a little differently than these effects assume.
//
// Notes get their effects with song_note_with_fx; they are stored in Song.note_fx (the notes
// refer to them) and in the "NFX1" chunk of a song file.
// ---------------------------------------------------------------------------

NOTE_CURVES :: 2 // pitch curves a note can have at once

Note_Vibrato :: struct {
	semitones: f32, // pitch variance: the peak deviation to either side, in semitones (0 = no vibrato)
	period:    f32, // seconds for one full swing (0.15 is about 6.7 swings a second)
	start:     f32, // where the vibrato begins in the note, 0..1 of the note's length
	end:       f32, // where it ends, 0..1 (it needs end > start)
	fade:      f32, // 0..0.5: the part of the active time (a fraction of it) that fades in, and out again (0 = hard edges)
}

Pitch_Curve :: struct {
	on: bool,
	p:  [4][2]f32, // the four points of a cubic Bezier curve: (x = 0..1 of the note, y = semitones). p[0].x <= p[3].x.
}

Note_Fx :: struct {
	vibrato: Note_Vibrato,
	glide:   [NOTE_CURVES]Pitch_Curve, // portamento curves (their offsets add up)
}

// ---- making effects -----------------------------------------------------------------

// A vibrato of `semitones` depth and a `period` in seconds that is active from `start` to `end`
// (0..1 of the note), fading in and out over `fade` of that time.
note_vibrato :: proc(semitones, period: f32, start: f32 = 0, end: f32 = 1, fade: f32 = 0.1) -> Note_Vibrato {
	return Note_Vibrato{semitones = semitones, period = period, start = start, end = end, fade = fade}
}

// A pitch curve from its four Bezier points (x = 0..1 of the note, y = semitones).
pitch_curve :: proc(p0, p1, p2, p3: [2]f32) -> Pitch_Curve {
	return Pitch_Curve{on = true, p = {p0, p1, p2, p3}}
}

Glide_Shape :: enum u8 {
	Smooth, // eases out of the start and into the end, the way a voice or a string slides
	Linear, // a straight line
}

// A slide from the offset `y0` at `x0` to the offset `y1` at `x1` (x in 0..1 of the note).
glide_between :: proc(x0, y0, x1, y1: f32, shape := Glide_Shape.Smooth) -> Pitch_Curve {
	d := x1 - x0
	dy := y1 - y0
	switch shape {
	case .Linear:
		return pitch_curve({x0, y0}, {x0 + d / 3, y0 + dy / 3}, {x0 + 2 * d / 3, y0 + 2 * dy / 3}, {x1, y1})
	case .Smooth:
		return pitch_curve({x0, y0}, {x0 + d / 3, y0}, {x1 - d / 3, y1}, {x1, y1})
	}
	return {}
}

// Starting portamento: the note begins `semitones` away from its pitch (negative = below) and slides
// to it, arriving when `until` of the note's length has passed; the rest of the note is on pitch.
glide_in :: proc(semitones, until: f32, shape := Glide_Shape.Smooth) -> Pitch_Curve {
	return glide_between(0, semitones, until, 0, shape)
}

// Trailing portamento: the note stays on pitch until `from` of its length, then slides away and is
// `semitones` off (negative = below) when the note ends.
glide_out :: proc(semitones: f32, from: f32 = 0.7, shape := Glide_Shape.Smooth) -> Pitch_Curve {
	return glide_between(from, 0, 1, semitones, shape)
}

// ---- evaluating ---------------------------------------------------------------------

note_fx_active :: proc(fx: ^Note_Fx) -> bool {
	if fx.vibrato.semitones != 0 && fx.vibrato.period > 0 && fx.vibrato.end > fx.vibrato.start {
		return true
	}
	for &c in fx.glide {
		if c.on {
			return true
		}
	}
	return false
}

// The vibrato's offset in semitones `age` seconds into a note that is `length` seconds long.
note_vibrato_at :: proc(vb: ^Note_Vibrato, age, length: f32) -> f32 {
	if vb.semitones == 0 || vb.period <= 0 || length <= 0 {
		return 0
	}
	start := clamp(vb.start, 0, 1)
	end := clamp(vb.end, 0, 1)
	pos := age / length
	if end <= start || pos < start || pos >= end {
		return 0
	}
	amp := vb.semitones
	if vb.fade > 0 {
		f := clamp(vb.fade, 0, 0.5) * (end - start)
		e := clamp(min((pos - start) / f, (end - pos) / f), 0, 1)
		amp *= e * e * (3 - 2 * e)
	}
	phase := (age - start * length) / vb.period // the swing starts at the middle, going up: no jump when it begins
	phase -= math.floor_f32(phase)
	return amp * sine_lookup(phase)
}

bezier3 :: proc(a, b, c, d, s: f32) -> f32 {
	u := 1 - s
	return u * u * u * a + 3 * u * u * s * b + 3 * u * s * s * c + s * s * s * d
}

// The offset of a pitch curve at `x` (0..1 of the note), in semitones.
pitch_curve_at :: proc(c: ^Pitch_Curve, x: f32) -> f32 {
	if !c.on {
		return 0
	}
	x0 := c.p[0].x
	x3 := c.p[3].x
	if x <= x0 {
		return c.p[0].y
	}
	if x >= x3 {
		return c.p[3].y
	}
	// With the inner points inside [x0, x3] the x of the curve only ever grows, so the parameter
	// that belongs to `x` can be found by halving the interval.
	x1 := clamp(c.p[1].x, x0, x3)
	x2 := clamp(c.p[2].x, x0, x3)
	lo: f32 = 0
	hi: f32 = 1
	for _ in 0 ..< 12 {
		mid := (lo + hi) * 0.5
		if bezier3(x0, x1, x2, x3, mid) < x {
			lo = mid
		} else {
			hi = mid
		}
	}
	return bezier3(c.p[0].y, c.p[1].y, c.p[2].y, c.p[3].y, (lo + hi) * 0.5)
}

// The pitch offset of a note in semitones `age` seconds after it started, for a note that is
// `length` seconds long.
note_fx_semitones :: proc(fx: ^Note_Fx, age, length: f32) -> f32 {
	if length <= 0 {
		return 0
	}
	x := age / length
	st := note_vibrato_at(&fx.vibrato, age, length)
	for &c in fx.glide {
		st += pitch_curve_at(&c, x)
	}
	return st
}

// ---- in songs -----------------------------------------------------------------------

// Stores `fx` in the song (the same effects are stored only once) and returns the number the notes
// refer to (their Event.fx), or 0 if there is no room (65535 different effects are possible).
song_add_note_fx :: proc(s: ^Song, fx: Note_Fx) -> u16 {
	f := fx
	if !note_fx_active(&f) {
		return 0
	}
	for i in 0 ..< len(s.note_fx) {
		if s.note_fx[i] == fx {
			return u16(i + 1)
		}
	}
	if len(s.note_fx) >= 65535 {
		return 0
	}
	append(&s.note_fx, fx)
	return u16(len(s.note_fx))
}

// A note like song_note, with effects of its own.
song_note_with_fx :: proc(s: ^Song, track: int, tick, length: u32, channel, key: int, velocity: int, fx: Note_Fx) {
	song_add_event(s, track, Event{tick = tick, kind = .Note_On, channel = u8(channel), a = i32(key), b = i32(clamp(velocity, 1, 127)), fx = song_add_note_fx(s, fx)})
	song_add_event(s, track, Event{tick = tick + max(length, 1), kind = .Note_Off, channel = u8(channel), a = i32(key)})
}

// The effects of a Note_On event (ok is false if it has none).
song_event_fx :: proc(s: ^Song, e: Event) -> (fx: Note_Fx, ok: bool) {
	if e.kind != .Note_On || e.fx == 0 || int(e.fx) > len(s.note_fx) {
		return {}, false
	}
	return s.note_fx[e.fx - 1], true
}

// ---- file format --------------------------------------------------------------------

NOTE_FX_FLOATS :: 5 + NOTE_CURVES * 9

note_fx_pack :: proc(fx: Note_Fx) -> [NOTE_FX_FLOATS]f32 {
	r: [NOTE_FX_FLOATS]f32
	r[0] = fx.vibrato.semitones
	r[1] = fx.vibrato.period
	r[2] = fx.vibrato.start
	r[3] = fx.vibrato.end
	r[4] = fx.vibrato.fade
	for k in 0 ..< NOTE_CURVES {
		b := 5 + k * 9
		r[b] = 1 if fx.glide[k].on else 0
		for i in 0 ..< 4 {
			r[b + 1 + i * 2] = fx.glide[k].p[i].x
			r[b + 2 + i * 2] = fx.glide[k].p[i].y
		}
	}
	return r
}

// The effects from a list of numbers (a shorter list from an older program leaves the rest off).
note_fx_unpack :: proc(v: []f32) -> Note_Fx {
	get :: proc(v: []f32, i: int) -> f32 {
		return v[i] if i < len(v) else 0
	}
	fx: Note_Fx
	fx.vibrato = Note_Vibrato {
		semitones = get(v, 0),
		period    = get(v, 1),
		start     = get(v, 2),
		end       = get(v, 3),
		fade      = get(v, 4),
	}
	for k in 0 ..< NOTE_CURVES {
		b := 5 + k * 9
		fx.glide[k].on = get(v, b) != 0
		for i in 0 ..< 4 {
			fx.glide[k].p[i] = {get(v, b + 1 + i * 2), get(v, b + 2 + i * 2)}
		}
	}
	return fx
}
