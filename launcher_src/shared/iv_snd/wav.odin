package iv_snd

// Writes the 44 byte header of a 16-bit PCM WAV file for `frames` frames of `channels` channels into the
// start of `out` (which must have room for it).
wav_write_header :: proc(out: []u8, frames, channels, rate: int) {
	data_len := frames * channels * 2
	put32 :: proc(o: []u8, at: int, v: u32) {
		o[at] = u8(v)
		o[at + 1] = u8(v >> 8)
		o[at + 2] = u8(v >> 16)
		o[at + 3] = u8(v >> 24)
	}
	put16 :: proc(o: []u8, at: int, v: u16) {
		o[at] = u8(v)
		o[at + 1] = u8(v >> 8)
	}
	copy(out[0:4], "RIFF")
	put32(out, 4, u32(36 + data_len))
	copy(out[8:16], "WAVEfmt ")
	put32(out, 16, 16)
	put16(out, 20, 1)
	put16(out, 22, u16(channels))
	put32(out, 24, u32(rate))
	put32(out, 28, u32(rate * channels * 2))
	put16(out, 32, u16(channels * 2))
	put16(out, 34, 16)
	copy(out[36:40], "data")
	put32(out, 40, u32(data_len))
}

// 16-bit PCM WAV file bytes from float samples (interleaved when stereo), for
// dumping what the synthesizer produced.
wav_encode :: proc(samples: []f32, channels, rate: int, allocator := context.allocator) -> []u8 {
	out := make([]u8, 44 + len(samples) * 2, allocator)
	wav_write_header(out, len(samples) / max(channels, 1), channels, rate)
	p := 44
	for x in samples {
		v := cast(u16)i16(clamp(x, -1, 1) * 32767)
		out[p] = u8(v)
		out[p + 1] = u8(v >> 8)
		p += 2
	}
	return out
}
