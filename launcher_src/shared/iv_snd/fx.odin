package iv_snd

import "core:math"

// ---------------------------------------------------------------------------
// Effects: a small stereo reverb (Freeverb style: parallel damped comb filters
// into series allpass filters), a stereo delay, and the soft limiter on the master output.
// ---------------------------------------------------------------------------

COMB_TUNING := [8]int{1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617}
ALLPASS_TUNING := [4]int{556, 441, 341, 225}
STEREO_SPREAD :: 23

Comb :: struct {
	buf:   []f32,
	idx:   int,
	store: f32,
}

Allpass :: struct {
	buf: []f32,
	idx: int,
}

Reverb :: struct {
	combs:    [2][8]Comb,
	allpass:  [2][4]Allpass,
	feedback: f32, // room size
	damp:     f32, // high frequency damping
	wet:      f32, // output level
}

reverb_init :: proc(r: ^Reverb, sample_rate: f32) {
	scale := sample_rate / 44100
	for side in 0 ..< 2 {
		spread := side * STEREO_SPREAD
		for i in 0 ..< 8 {
			n := max(int(f32(COMB_TUNING[i] + spread) * scale), 8)
			r.combs[side][i] = Comb {
				buf = make([]f32, n),
			}
		}
		for i in 0 ..< 4 {
			n := max(int(f32(ALLPASS_TUNING[i] + spread) * scale), 8)
			r.allpass[side][i] = Allpass {
				buf = make([]f32, n),
			}
		}
	}
	r.feedback = 0.84
	r.damp = 0.3
	r.wet = 0.9
}

reverb_destroy :: proc(r: ^Reverb) {
	for side in 0 ..< 2 {
		for i in 0 ..< 8 {
			delete(r.combs[side][i].buf)
		}
		for i in 0 ..< 4 {
			delete(r.allpass[side][i].buf)
		}
	}
	r^ = {}
}

// Empties the reverb (silences its tail), e.g. when one piece of music replaces another.
reverb_clear :: proc(r: ^Reverb) {
	for side in 0 ..< 2 {
		for i in 0 ..< 8 {
			cb := &r.combs[side][i]
			for j in 0 ..< len(cb.buf) {
				cb.buf[j] = 0
			}
			cb.store = 0
		}
		for i in 0 ..< 4 {
			ap := &r.allpass[side][i]
			for j in 0 ..< len(ap.buf) {
				ap.buf[j] = 0
			}
		}
	}
}

// Feeds the mono `send` signal through the reverb and adds the result to l and r.
// The input is scaled so that a larger room (more feedback) has a longer tail but
// about the same loudness for sustained sounds.
reverb_process :: proc(r: ^Reverb, send, l, r_out: []f32, n: int) {
	in_gain := f32(0.03) * (1 - r.feedback) / (1 - REVERB_FEEDBACK_DEFAULT)
	for i in 0 ..< n {
		input := send[i] * in_gain
		for side in 0 ..< 2 {
			acc: f32 = 0
			for c in 0 ..< 8 {
				cb := &r.combs[side][c]
				out := cb.buf[cb.idx]
				cb.store = out * (1 - r.damp) + cb.store * r.damp
				if abs(cb.store) < 1e-20 {
					cb.store = 0
				}
				cb.buf[cb.idx] = input + cb.store * r.feedback
				cb.idx += 1
				if cb.idx >= len(cb.buf) {
					cb.idx = 0
				}
				acc += out
			}
			for a in 0 ..< 4 {
				ap := &r.allpass[side][a]
				bufout := ap.buf[ap.idx]
				out := -acc + bufout
				ap.buf[ap.idx] = acc + bufout * 0.5
				ap.idx += 1
				if ap.idx >= len(ap.buf) {
					ap.idx = 0
				}
				acc = out
			}
			if side == 0 {
				l[i] += acc * r.wet
			} else {
				r_out[i] += acc * r.wet
			}
		}
	}
}

// ---- delay -----------------------------------------------------------------------------------

DELAY_MAX_SECONDS :: f32(4) // the longest delay time (a whole note below 60 beats per minute is cut to it)

// A stereo delay (echo): the mono `send` signal goes into a delay line, comes out `time`
// seconds later, and a part of it (`feedback`) goes back in, so it repeats and fades. The
// repeats get duller each time round (`tone`), and in ping-pong mode they bounce between
// the left and the right side. The time glides to a new value instead of jumping, so
// changing it (or the tempo that a synced time follows) does not click.
Delay :: struct {
	buf:         [2][]f32, // left and right delay lines
	pos:         int, // next write position
	time:        f32, // delay now, in samples (glides towards `target`; < 0 = not set yet)
	target:      f32, // delay wanted, in samples
	feedback:    f32, // 0 .. DELAY_FEEDBACK_MAX
	tone:        f32, // 0 (bright) .. 1 (dark)
	ping_pong:   bool,
	wet:         f32, // output level
	lp:          [2]f32, // state of the tone filters
	sample_rate: f32,
}

delay_init :: proc(d: ^Delay, sample_rate: f32) {
	n := int(DELAY_MAX_SECONDS * sample_rate) + 8
	d.buf[0] = make([]f32, n)
	d.buf[1] = make([]f32, n)
	d.sample_rate = sample_rate
	d.time = -1
	d.target = DELAY_TIME_DEFAULT * sample_rate
	d.feedback = DELAY_FEEDBACK_DEFAULT
	d.tone = DELAY_TONE_DEFAULT
	d.wet = 1
}

delay_destroy :: proc(d: ^Delay) {
	delete(d.buf[0])
	delete(d.buf[1])
	d^ = {}
}

// Empties the delay (silences its repeats), e.g. when one piece of music replaces another.
delay_clear :: proc(d: ^Delay) {
	for side in 0 ..< 2 {
		for i in 0 ..< len(d.buf[side]) {
			d.buf[side][i] = 0
		}
	}
	d.lp = {}
}

// Takes the settings a synthesizer asks for (the audio manager does this for every block).
delay_set :: proc(d: ^Delay, seconds, feedback, tone: f32, ping_pong: bool) {
	d.target = clamp(seconds, 0.005, DELAY_MAX_SECONDS - 0.05) * d.sample_rate
	d.feedback = clamp(feedback, 0, DELAY_FEEDBACK_MAX)
	d.tone = clamp(tone, 0, 1)
	d.ping_pong = ping_pong
}

// Feeds the mono `send` signal through the delay and adds the echoes to l and r_out.
delay_process :: proc(d: ^Delay, send, l, r_out: []f32, n: int) {
	size := len(d.buf[0])
	if size == 0 {
		return
	}
	if d.time < 0 {
		d.time = d.target
	}
	glide := 1 / max(0.05 * d.sample_rate, 1) // the time follows its target with a time constant of 50 ms
	a := 1 - 0.9 * d.tone // one-pole low-pass in the feedback path: 1 = bright .. 0.1 = dark
	for i in 0 ..< n {
		d.time += (d.target - d.time) * glide

		// Both lines are read `time` samples behind the write position (linear interpolation).
		rp := f32(d.pos) - d.time
		if rp < 0 {
			rp += f32(size)
		}
		i0 := int(rp)
		frac := rp - f32(i0)
		if i0 >= size {
			i0 -= size
		}
		i1 := i0 + 1
		if i1 >= size {
			i1 = 0
		}
		dl := d.buf[0][i0] + (d.buf[0][i1] - d.buf[0][i0]) * frac
		dr := d.buf[1][i0] + (d.buf[1][i1] - d.buf[1][i0]) * frac

		d.lp[0] += a * (dl - d.lp[0])
		d.lp[1] += a * (dr - d.lp[1])
		if abs(d.lp[0]) < 1e-20 {
			d.lp[0] = 0
		}
		if abs(d.lp[1]) < 1e-20 {
			d.lp[1] = 0
		}
		fl := d.lp[0] * d.feedback
		fr := d.lp[1] * d.feedback

		in_l := send[i]
		in_r := send[i]
		if d.ping_pong {
			// The sound enters on the left; every repeat crosses over to the other side.
			in_l += fr
			in_r = fl
		} else {
			in_l += fl
			in_r += fr
		}
		d.buf[0][d.pos] = in_l
		d.buf[1][d.pos] = in_r
		d.pos += 1
		if d.pos >= size {
			d.pos = 0
		}

		l[i] += dl * d.wet
		r_out[i] += dr * d.wet
	}
}

// Transparent below 0.7, then smoothly squeezes towards 1 (never clips).
soft_clip :: proc(x: f32) -> f32 {
	a := abs(x)
	if a <= 0.7 {
		return x
	}
	t := math.exp_f32(-2 * (a - 0.7) / 0.3)
	o: f32 = 0.7 + 0.3 * (1 - t) / (1 + t) // 0.7 + 0.3 * tanh(...)
	if x < 0 {
		return -o
	}
	return o
}
