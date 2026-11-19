// LZMA decoding (the "LZMA1" of 7-Zip and xz; the .lzma format that `xz --format=lzma` writes), for the launcher's
// bundle (launcher/bundle.odin; tools/ff/bundle.odin and launcher/build.sh make it).
//
// The whole output is one buffer whose size is known beforehand (the bundle's index has it), so the buffer is also the
// dictionary: no window, a match is a copy from earlier in the output. Follows the LZMA specification's reference
// decoder (LzmaSpec.cpp in the LZMA SDK, public domain). A corrupt stream returns false; it never reads or writes out
// of bounds.
package lzma

PROB_INIT :: 1024
NUM_STATES :: 12
POS_BITS_MAX :: 4
END_POS_MODEL :: 14
FULL_DISTANCES :: 128
ALIGN_BITS :: 4
MATCH_MIN :: 2

@(private)
Len_Dec :: struct {
	choice, choice2: u16,
	low, mid:        [1 << POS_BITS_MAX << 3]u16,
	high:            [256]u16,
}

@(private)
Dec :: struct {
	src:                         []u8,
	ip:                          int,
	range, code:                 u32,
	bad:                         bool,
	is_match:                    [NUM_STATES << POS_BITS_MAX]u16,
	is_rep, is_rep_g0:           [NUM_STATES]u16,
	is_rep_g1, is_rep_g2:        [NUM_STATES]u16,
	is_rep0_long:                [NUM_STATES << POS_BITS_MAX]u16,
	pos_slot:                    [4][64]u16,
	pos_dec:                     [1 + FULL_DISTANCES - END_POS_MODEL]u16,
	align:                       [1 << ALIGN_BITS]u16,
	len_dec, rep_len_dec:        Len_Dec,
}

@(private)
normalize :: #force_inline proc "contextless" (d: ^Dec) {
	if d.range < 1 << 24 {
		d.range <<= 8
		if d.ip < len(d.src) {
			d.code = d.code << 8 | u32(d.src[d.ip])
			d.ip += 1
		} else {
			d.code <<= 8
			d.bad = true
		}
	}
}

@(private)
bit :: #force_inline proc "contextless" (d: ^Dec, p: ^u16) -> u32 {
	v := u32(p^)
	bound := (d.range >> 11) * v
	r: u32
	if d.code < bound {
		d.range = bound
		p^ = u16(v + ((2048 - v) >> 5))
		r = 0
	} else {
		d.range -= bound
		d.code -= bound
		p^ = u16(v - (v >> 5))
		r = 1
	}
	normalize(d)
	return r
}

@(private)
direct :: proc "contextless" (d: ^Dec, n: uint) -> u32 {
	res: u32
	for _ in 0 ..< n {
		d.range >>= 1
		d.code -= d.range
		t := 0 - (d.code >> 31)
		d.code += d.range & t
		if d.code == d.range {d.bad = true}
		normalize(d)
		res = res << 1 + t + 1
	}
	return res
}

@(private)
tree :: #force_inline proc "contextless" (d: ^Dec, probs: [^]u16, n: uint) -> u32 {
	m: u32 = 1
	for _ in 0 ..< n {m = m << 1 + bit(d, &probs[m])}
	return m - (1 << n)
}

@(private)
tree_rev :: #force_inline proc "contextless" (d: ^Dec, probs: [^]u16, n: uint) -> u32 {
	m: u32 = 1
	sym: u32
	for i in 0 ..< n {
		b := bit(d, &probs[m])
		m = m << 1 + b
		sym |= b << i
	}
	return sym
}

@(private)
length :: proc "contextless" (d: ^Dec, l: ^Len_Dec, ps: u32) -> u32 {
	if bit(d, &l.choice) == 0 {return tree(d, raw_data(l.low[ps << 3:]), 3)}
	if bit(d, &l.choice2) == 0 {return 8 + tree(d, raw_data(l.mid[ps << 3:]), 3)}
	return 16 + tree(d, raw_data(l.high[:]), 8)
}

// Decodes a .lzma stream (13-byte header: properties, dictionary size, uncompressed size) into out, which must be
// exactly the uncompressed size. The header's size may be "unknown" (all ones: xz's, ended by the end marker).
decode :: proc(src: []u8, out: []u8) -> bool {
	if len(src) < 13 {return false}
	props := u32(src[0])
	if props >= 9 * 5 * 5 {return false}
	lc := uint(props % 9)
	props /= 9
	lp := uint(props % 5)
	pb := uint(props / 5)
	known: u64
	for i in 0 ..< 8 {known |= u64(src[5 + i]) << (8 * uint(i))}
	if known != max(u64) && known != u64(len(out)) {return false}
	return decode_raw(src[13:], out, lc, lp, pb)
}

@(private)
decode_raw :: proc(src: []u8, out: []u8, lc, lp, pb: uint) -> bool #no_bounds_check {
	d := new(Dec)
	defer free(d)
	lit := make([]u16, 0x300 << (lc + lp))
	defer delete(lit)
	{
		p := ([^]u16)(&d.is_match)
		n := (size_of(Dec) - offset_of(Dec, is_match)) / 2
		for i in 0 ..< n {p[i] = PROB_INIT}
		for &v in lit {v = PROB_INIT}
	}
	d.src = src
	if len(src) < 5 || src[0] != 0 {return false}
	d.range = max(u32)
	d.code = u32(src[1]) << 24 | u32(src[2]) << 16 | u32(src[3]) << 8 | u32(src[4])
	d.ip = 5
	if d.code == d.range {return false}

	size := len(out)
	op := 0
	rep0, rep1, rep2, rep3: u32
	state: u32
	pb_mask := u32(1) << pb - 1
	lp_mask := u32(1) << lp - 1
	for op < size {
		if d.bad {return false}
		ps := u32(op) & pb_mask
		if bit(d, &d.is_match[state << POS_BITS_MAX + ps]) == 0 {
			prev: u32 = op > 0 ? u32(out[op - 1]) : 0
			ls := (u32(op) & lp_mask) << lc + prev >> (8 - lc)
			probs := raw_data(lit[0x300 * ls:])
			sym: u32 = 1
			if state >= 7 {
				mb := u32(out[op - int(rep0) - 1]) // (rep0 < op: checked when it was set)
				for sym < 0x100 {
					m := (mb >> 7) & 1
					mb <<= 1
					b := bit(d, &probs[(1 + m) << 8 + sym])
					sym = sym << 1 | b
					if m != b {break}
				}
			}
			for sym < 0x100 {sym = sym << 1 | bit(d, &probs[sym])}
			out[op] = u8(sym)
			op += 1
			state = state < 4 ? 0 : state < 10 ? state - 3 : state - 6
			continue
		}
		n: u32
		if bit(d, &d.is_rep[state]) != 0 {
			if op == 0 {return false}
			if bit(d, &d.is_rep_g0[state]) == 0 {
				if bit(d, &d.is_rep0_long[state << POS_BITS_MAX + ps]) == 0 { 	// a "short rep": one byte
					state = state < 7 ? 9 : 11
					out[op] = out[op - int(rep0) - 1]
					op += 1
					continue
				}
			} else {
				dist: u32
				if bit(d, &d.is_rep_g1[state]) == 0 {
					dist = rep1
				} else {
					if bit(d, &d.is_rep_g2[state]) == 0 {
						dist = rep2
					} else {
						dist = rep3
						rep3 = rep2
					}
					rep2 = rep1
				}
				rep1 = rep0
				rep0 = dist
			}
			n = length(d, &d.rep_len_dec, ps)
			state = state < 7 ? 8 : 11
		} else {
			rep3 = rep2
			rep2 = rep1
			rep1 = rep0
			n = length(d, &d.len_dec, ps)
			state = state < 7 ? 7 : 10
			// the distance
			slot := tree(d, raw_data(d.pos_slot[min(n, 3)][:]), 6)
			dist := slot
			if slot >= 4 {
				nd := uint(slot >> 1 - 1)
				dist = (2 | slot & 1) << nd
				if slot < END_POS_MODEL {
					dist += tree_rev(d, raw_data(d.pos_dec[dist - slot:]), nd)
				} else {
					dist += direct(d, nd - ALIGN_BITS) << ALIGN_BITS
					dist += tree_rev(d, raw_data(d.align[:]), ALIGN_BITS)
				}
			}
			if dist == max(u32) {break} // the end marker (before the output is full: short)
			rep0 = dist
			if int(rep0) >= op {return false}
		}
		n += MATCH_MIN
		if int(n) > size - op {return false}
		from := op - int(rep0) - 1
		if rep0 >= n { 	// (no overlap: a plain copy)
			copy(out[op:op + int(n)], out[from:from + int(n)])
			op += int(n)
		} else {
			for _ in 0 ..< n {
				out[op] = out[from]
				op += 1
				from += 1
			}
		}
	}
	return op == size && !d.bad
}
