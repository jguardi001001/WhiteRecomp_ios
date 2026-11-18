package iv_snd

import "core:math"

// ---------------------------------------------------------------------------
// Sound effects: short recorded sounds (WAV) played on a pool of voices, plus
// "patch notes" made with the synthesizer itself (handy for blips and beeps).
// ---------------------------------------------------------------------------

MAX_SFX_VOICES :: 32

// A loaded sound: 32-bit float samples, interleaved when stereo.
Sfx :: struct {
	data:     []f32,
	channels: int, // 1 or 2
	rate:     int, // sample rate of the recording
}

sfx_frames :: proc(s: ^Sfx) -> int {
	if s.channels <= 0 {
		return 0
	}
	return len(s.data) / s.channels
}

sfx_destroy :: proc(s: ^Sfx, allocator := context.allocator) {
	delete(s.data, allocator)
	s^ = {}
}

// Reads a RIFF/WAVE file in memory: PCM 8/16/24/32-bit or 32-bit float, mono or stereo.
sfx_from_wav :: proc(bytes: []u8, allocator := context.allocator) -> (Sfx, bool) {
	if len(bytes) < 12 || string(bytes[0:4]) != "RIFF" || string(bytes[8:12]) != "WAVE" {
		return {}, false
	}
	format, channels, rate, bits: int
	data_off, data_len := -1, 0
	p := 12
	for p + 8 <= len(bytes) {
		id := string(bytes[p:p + 4])
		sz := int(u32(bytes[p + 4]) | u32(bytes[p + 5]) << 8 | u32(bytes[p + 6]) << 16 | u32(bytes[p + 7]) << 24)
		body := p + 8
		if id == "fmt " && body + 16 <= len(bytes) {
			format = int(u32(bytes[body]) | u32(bytes[body + 1]) << 8)
			channels = int(u32(bytes[body + 2]) | u32(bytes[body + 3]) << 8)
			rate = int(u32(bytes[body + 4]) | u32(bytes[body + 5]) << 8 | u32(bytes[body + 6]) << 16 | u32(bytes[body + 7]) << 24)
			bits = int(u32(bytes[body + 14]) | u32(bytes[body + 15]) << 8)
			if format == 0xFFFE && sz >= 26 && body + 26 <= len(bytes) { // extensible: real format in the sub-format
				format = int(u32(bytes[body + 24]) | u32(bytes[body + 25]) << 8)
			}
		} else if id == "data" {
			data_off = body
			data_len = min(sz, len(bytes) - body)
			break
		}
		p = body + sz + (sz & 1)
	}
	if data_off < 0 || channels < 1 || channels > 2 || rate <= 0 {
		return {}, false
	}
	bytes_per := bits / 8
	if bytes_per < 1 || bytes_per > 4 || (format != 1 && format != 3) || (format == 3 && bits != 32) {
		return {}, false
	}
	count := data_len / bytes_per
	count -= count % channels
	out := make([]f32, count, allocator)
	for i in 0 ..< count {
		q := data_off + i * bytes_per
		v: f32
		switch {
		case format == 3:
			v = transmute(f32)(u32(bytes[q]) | u32(bytes[q + 1]) << 8 | u32(bytes[q + 2]) << 16 | u32(bytes[q + 3]) << 24)
		case bits == 8:
			v = (f32(bytes[q]) - 128) / 128
		case bits == 16:
			v = f32(i16(u16(bytes[q]) | u16(bytes[q + 1]) << 8)) / 32768
		case bits == 24:
			x := i32(u32(bytes[q]) << 8 | u32(bytes[q + 1]) << 16 | u32(bytes[q + 2]) << 24) // sign in the top bits
			v = f32(x >> 8) / 8388608
		case:
			x := i32(u32(bytes[q]) | u32(bytes[q + 1]) << 8 | u32(bytes[q + 2]) << 16 | u32(bytes[q + 3]) << 24)
			v = f32(x) / 2147483648
		}
		out[i] = v
	}
	return Sfx{data = out, channels = channels, rate = rate}, true
}

Sfx_Handle :: struct {
	index:  int,
	serial: u32,
}

Sfx_Voice :: struct {
	active: bool,
	serial: u32,
	sfx:    ^Sfx,
	pos:    f64, // position in source frames
	step:   f64, // source frames per output frame
	gl, gr: f32,
	loop:   bool,
}

// Mixes the active sound effect voices into l and r (adds; does not clear).
sfx_voices_render :: proc(voices: []Sfx_Voice, l, r: []f32, n: int) {
	for &v in voices {
		if !v.active {
			continue
		}
		s := v.sfx
		frames := sfx_frames(s)
		if frames < 2 {
			v.active = false
			continue
		}
		for i in 0 ..< n {
			ip := int(v.pos)
			if ip >= frames - 1 {
				if v.loop {
					v.pos -= f64(frames - 1)
					ip = int(v.pos)
				} else {
					v.active = false
					break
				}
			}
			f := f32(v.pos - f64(ip))
			xl, xr: f32
			if s.channels == 1 {
				a := s.data[ip]
				b := s.data[ip + 1]
				xl = a + (b - a) * f
				xr = xl
			} else {
				al := s.data[ip * 2]
				bl := s.data[ip * 2 + 2]
				ar := s.data[ip * 2 + 1]
				br := s.data[ip * 2 + 3]
				xl = al + (bl - al) * f
				xr = ar + (br - ar) * f
			}
			l[i] += xl * v.gl
			r[i] += xr * v.gr
			v.pos += v.step
		}
	}
}

// Constant power pan: -1 left .. 1 right.
pan_gains :: proc(pan: f32) -> (f32, f32) {
	ang := (clamp(pan, -1, 1) + 1) * f32(math.PI) * 0.25
	return math.cos_f32(ang), math.sin_f32(ang)
}
