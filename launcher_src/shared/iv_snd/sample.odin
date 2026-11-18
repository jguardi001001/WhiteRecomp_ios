package iv_snd

import "core:math"
import "core:os"
import "core:sync"

// ---------------------------------------------------------------------------
// Samples: recordings (WAV files), the raw material of the sample zones of instruments.
//
// A Sample is only the sound: a mono recording (16 bit) and its sample rate. What
// turns it into something that can be played is a ZONE of an instrument
// (instrument.odin): it says which keys play the sample, at which key it sounds as
// recorded (its ROOT KEY, a MIDI key with a fraction: 60.25 = a quarter of a semitone
// above middle C) and whether it loops. Several zones, of one instrument or of
// several, may share one sample.
//
// FINDING THE ROOT KEY
//
// sample_detect_root_v1 looks at up to 24 of the loudest stretches of the recording,
// finds the fundamental frequency of each with the YIN method (the difference function
// is computed with exact integer arithmetic), and lets them vote: the pitch that most
// of the sound energy agrees on (within half a semitone) wins, and the root key is the
// average of the pitches that voted for it, rounded to 1/100 of a semitone. The result
// depends only on the 16 bit sample values and the sample rate.
//
// THE ROOT KEY NEVER CHANGES. Two promises are made:
//   * sample_detect_root_v1 is frozen: its results will not change in later versions of this
//     library. A better method would be added as _v2 and used for new zones only.
//   * a zone starts without a root key. The first time one is needed it is worked out and
//     FROZEN into the zone (zone_ensure_root), together with the version of the method;
//     the song file stores it, and a loaded root key is never worked out again.
// ---------------------------------------------------------------------------

ROOT_DETECT_VERSION :: u8(1) // the method used for new imports
MAX_SAMPLE_FRAMES :: 4_000_000 // longer recordings are cut (about 90 s at 44.1 kHz)

// A recording. Several songs and patches may share one (it counts its users).
Sample :: struct {
	label:        Patch_Label,
	rate:         int, // sample rate of the recording
	data:         []i16, // mono
	refs:         int, // number of owners (songs, projects)
	peak:         i32, // the loudest value in data (0 = not looked at yet, see sample_peak)
}

sample_frames :: proc(s: ^Sample) -> int {
	return len(s.data)
}

sample_name :: proc(s: ^Sample) -> string {
	return patch_label_string(&s.label)
}

sample_seconds :: proc(s: ^Sample) -> f32 {
	if s.rate <= 0 {
		return 0
	}
	return f32(len(s.data)) / f32(s.rate)
}

// A new sample made from mono 16 bit data (copied). It has one
// owner: call sample_release when done (adding it to a song gives the song its own share).
sample_new :: proc(data: []i16, rate: int, name: string) -> ^Sample {
	s := new(Sample)
	n := min(len(data), MAX_SAMPLE_FRAMES)
	s.data = make([]i16, n)
	copy(s.data, data[:n])
	s.rate = rate
	s.label = patch_label_make(name)
	s.refs = 1
	return s
}

sample_retain :: proc(s: ^Sample) {
	if s != nil {
		sync.atomic_add(&s.refs, 1)
	}
}

// Gives up one share; the last one frees the sample.
sample_release :: proc(s: ^Sample) {
	if s == nil {
		return
	}
	if sync.atomic_sub(&s.refs, 1) == 1 {
		delete(s.data)
		free(s)
	}
}

// Mixes a loaded sound down to mono and makes a sample of it.
sample_from_sfx :: proc(sfx: ^Sfx, name: string) -> ^Sample {
	frames := sfx_frames(sfx)
	data := make([]i16, frames, context.temp_allocator)
	for i in 0 ..< frames {
		v: f32
		if sfx.channels == 2 {
			v = (sfx.data[i * 2] + sfx.data[i * 2 + 1]) * 0.5
		} else {
			v = sfx.data[i]
		}
		data[i] = i16(clamp(math.round_f32(v * 32767), -32768, 32767))
	}
	return sample_new(data, sfx.rate, name)
}

// Reads a WAV file in memory (see sfx_from_wav for the formats).
sample_from_wav :: proc(bytes: []u8, name: string) -> (^Sample, bool) {
	sfx, ok := sfx_from_wav(bytes, context.temp_allocator)
	if !ok || sfx_frames(&sfx) < 2 {
		return nil, false
	}
	return sample_from_sfx(&sfx, name), true
}

sample_load_wav :: proc(path: string, name: string) -> (^Sample, bool) {
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}
	return sample_from_wav(bytes, name)
}

// ---- the root key ----------------------------------------------------------------------------

Root_Result :: struct {
	key:        f32, // MIDI key with fraction
	confidence: f32,
	pitched:    bool,
}

ROOT_MIN_WINDOW :: 2048
ROOT_MAX_FRAMES :: 24

// THE ROOT KEY METHOD, VERSION 1. FROZEN: do not change anything in this procedure (not
// the thresholds, not the order of the calculations): results stored by it and results
// computed again later must stay identical. Improvements go into a new procedure.
sample_detect_root_v1 :: proc(data: []i16, rate: int) -> Root_Result {
	res := Root_Result {
		key = 60,
	}
	n := len(data)
	if n < 512 || rate < 4000 {
		return res
	}
	tau_lo := max(int(f64(rate) / 4186.01), 2) // shortest period looked for (C8)
	tau_hi := int(math.ceil_f64(f64(rate) / 27.5)) // longest period looked for (A0)
	tau_hi = min(tau_hi, n / 2 - 2)
	if tau_hi <= tau_lo + 2 {
		return res
	}
	w := max(ROOT_MIN_WINDOW, tau_hi) // length of the stretch compared with itself
	if w + tau_hi > n {
		w = n - tau_hi
	}
	if w < 256 {
		return res
	}
	flen := w + tau_hi
	hop := w / 2
	count := (n - flen) / hop + 1

	// The energy of every stretch.
	energy := make([]i64, count)
	defer delete(energy)
	emax: i64 = 0
	for f in 0 ..< count {
		p := f * hop
		e: i64 = 0
		for j in 0 ..< w {
			x := i64(data[p + j])
			e += x * x
		}
		energy[f] = e
		emax = max(emax, e)
	}
	if emax == 0 {
		return res
	}

	// The loud ones (not more than 12 dB below the loudest), at most 24 of them spread evenly.
	cand: [dynamic]int
	defer delete(cand)
	for f in 0 ..< count {
		if energy[f] * 16 >= emax {
			append(&cand, f)
		}
	}
	chosen: [dynamic]int
	defer delete(chosen)
	if len(cand) <= ROOT_MAX_FRAMES {
		append(&chosen, ..cand[:])
	} else {
		for k in 0 ..< ROOT_MAX_FRAMES {
			append(&chosen, cand[k * len(cand) / ROOT_MAX_FRAMES])
		}
	}

	Vote :: struct {
		key:  f64,
		w:    f64,
		tier: int,
	}
	votes: [dynamic]Vote
	defer delete(votes)
	total_w: f64 = 0

	d := make([]i64, tau_hi + 1)
	defer delete(d)
	dn := make([]f64, tau_hi + 1)
	defer delete(dn)

	for f in chosen {
		p := f * hop
		total_w += math.sqrt_f64(f64(energy[f]))
		// Difference function.
		for tau in 1 ..= tau_hi {
			acc: i64 = 0
			for j in 0 ..< w {
				diff := i64(data[p + j]) - i64(data[p + j + tau])
				acc += diff * diff
			}
			d[tau] = acc
		}
		// Cumulative mean normalised difference.
		dn[0] = 1
		run: f64 = 0
		for tau in 1 ..= tau_hi {
			run += f64(d[tau])
			if run == 0 {
				dn[tau] = 1
			} else {
				dn[tau] = f64(d[tau]) * f64(tau) / run
			}
		}
		// First clear dip, followed down to its bottom.
		last := tau_hi - 1
		found := -1
		tier := 0
		t := tau_lo
		for t <= last {
			if dn[t] < 0.2 {
				for t + 1 <= last && dn[t + 1] < dn[t] {
					t += 1
				}
				found = t
				break
			}
			t += 1
		}
		if found < 0 { // no clear dip: the deepest one, if it is at least a faint one
			bestv := 2.0
			for t2 in tau_lo ..= last {
				if dn[t2] < bestv {
					bestv = dn[t2]
					found = t2
				}
			}
			tier = 1
			if bestv >= 0.45 {
				found = -1
			}
		}
		if found < 0 {
			continue
		}
		a := dn[found - 1]
		b := dn[found]
		c := dn[found + 1]
		off := 0.0
		den := a - 2 * b + c
		if den > 1e-12 {
			off = clamp(0.5 * (a - c) / den, -1.0, 1.0)
		}
		hz := f64(rate) / (f64(found) + off)
		key := 69 + 12 * math.log2_f64(hz / 440)
		append(&votes, Vote{key = key, w = math.sqrt_f64(f64(energy[f])) * (1 - clamp(b, 0.0, 1.0)), tier = tier})
	}

	// Use the clear ones if there are any, else the faint ones.
	use_tier := 1
	for v in votes {
		if v.tier == 0 {
			use_tier = 0
			break
		}
	}
	best_key: f64 = 0
	best_s: f64 = -1
	for vi in votes {
		if vi.tier != use_tier {
			continue
		}
		s: f64 = 0
		for vj in votes {
			if vj.tier == use_tier && abs(vj.key - vi.key) <= 0.5 {
				s += vj.w
			}
		}
		if s > best_s {
			best_s = s
			best_key = vi.key
		}
	}
	if best_s <= 0 {
		return res
	}
	sum_w: f64 = 0
	sum_k: f64 = 0
	for v in votes {
		if v.tier == use_tier && abs(v.key - best_key) <= 0.5 {
			sum_w += v.w
			sum_k += v.w * v.key
		}
	}
	if sum_w <= 0 {
		return res
	}
	root := clamp(math.round_f64(sum_k / sum_w * 100) / 100, 0.0, 127.0)
	res.key = f32(root)
	res.pitched = true
	res.confidence = f32(clamp(best_s / max(total_w, 1e-9), 0.0, 1.0))
	return res
}

// ---- playback ----------------------------------------------------------------------------------

// The value of the sample at a (fractional) frame position, 4 point cubic interpolation.
sample_read :: proc(s: ^Sample, pos: f64) -> f32 {
	n := len(s.data)
	i := int(pos)
	f := f32(pos - f64(i))
	i0 := clamp(i - 1, 0, n - 1)
	i1 := clamp(i, 0, n - 1)
	i2 := clamp(i + 1, 0, n - 1)
	i3 := clamp(i + 2, 0, n - 1)
	y0 := f32(s.data[i0]) * (1.0 / 32768.0)
	y1 := f32(s.data[i1]) * (1.0 / 32768.0)
	y2 := f32(s.data[i2]) * (1.0 / 32768.0)
	y3 := f32(s.data[i3]) * (1.0 / 32768.0)
	c1 := 0.5 * (y2 - y0)
	c2 := y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
	c3 := 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
	return ((c3 * f + c2) * f + c1) * f + y1
}
