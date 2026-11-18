package main

// Names of keys.

NOTE_NAMES := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

is_black_key :: proc(key: int) -> bool {
	switch key % 12 {
	case 1, 3, 6, 8, 10:
		return true
	}
	return false
}

// "C4" (middle C is key 60).
key_label :: proc(key: int) -> string {
	k := clamp(key, 0, 127)
	return tprint_key(k)
}

tprint_key :: proc(k: int) -> string {
	buf := make([]u8, 5, context.temp_allocator)
	n := 0
	name := NOTE_NAMES[k % 12]
	for i in 0 ..< len(name) {
		buf[n] = name[i]
		n += 1
	}
	oct := k / 12 - 1
	if oct < 0 {
		buf[n] = '-'
		n += 1
		oct = -oct
	}
	buf[n] = u8('0' + oct)
	n += 1
	return string(buf[:n])
}
