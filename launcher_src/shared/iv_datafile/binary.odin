package iv_datafile

import "core:hash"
import "core:math"
import "core:mem"
import "core:strings"

// ---------------------------------------------------------------------------
// A binary format made of chunks.
//
// A file is a header (a 4-letter magic and a version), any number of chunks, and a checksum. A chunk is a 4-letter tag, a version of its own, a length, and
// its bytes. A reader asks for the chunks one after another and takes the ones it knows; the length lets it step over the rest, so a file that a newer
// version of the program wrote (with chunks added) still loads in an older one, and a chunk that grows by fields at its end stays readable (a reader
// that finds the bytes short gets zeros and `failed`, see Reader). Numbers are little-endian whatever the machine.
//
//   w: iv_datafile.Writer
//   iv_datafile.writer_init(&w)
//   defer iv_datafile.writer_destroy(&w)
//   iv_datafile.write_header(&w, "SAVE", 3)
//   m := iv_datafile.begin_chunk(&w, "PLYR", 1)
//   iv_datafile.write_string(&w, "Ada");  iv_datafile.write_f32(&w, 12.5);  iv_datafile.write_i32(&w, 40)
//   iv_datafile.end_chunk(&w, m)
//   iv_datafile.seal(&w)                                  // adds the checksum
//   iv_datafile.save_file("save.dat", w.data[:])
//
//   data, _ := iv_datafile.load_file("save.dat");  body, ok := iv_datafile.unseal(data)       // false: damaged
//   r := iv_datafile.reader(body)
//   magic, version, _ := iv_datafile.read_header(&r)
//   for c in iv_datafile.next_chunk(&r) {
//       cr := iv_datafile.reader(c.data)
//       switch c.tag { case "PLYR": name := iv_datafile.read_string(&cr); ... }
//   }
// ---------------------------------------------------------------------------

Tag :: [4]u8

// A tag from a 4-letter string ("PLYR"; shorter is padded with spaces, longer is cut).
tag :: proc(s: string) -> Tag {
	t := Tag{' ', ' ', ' ', ' '}
	for i in 0 ..< min(len(s), 4) {
		t[i] = s[i]
	}
	return t
}

// The tag as a string (in the temp allocator).
tag_string :: proc(t: Tag) -> string {
	t := t
	return strings.clone(string(t[:]), context.temp_allocator)
}

// ---- writing -------------------------------------------------------------------------------------------------------------------

Writer :: struct {
	data: [dynamic]u8,
}

writer_init :: proc(w: ^Writer, allocator := context.allocator) {
	w.data = make([dynamic]u8, allocator)
}

writer_destroy :: proc(w: ^Writer) {
	delete(w.data)
	w^ = {}
}

write_u8 :: proc(w: ^Writer, v: u8) {
	append(&w.data, v)
}

write_bool :: proc(w: ^Writer, v: bool) {
	append(&w.data, 1 if v else 0)
}

write_u16 :: proc(w: ^Writer, v: u16) {
	append(&w.data, u8(v), u8(v >> 8))
}

write_u32 :: proc(w: ^Writer, v: u32) {
	append(&w.data, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

write_u64 :: proc(w: ^Writer, v: u64) {
	write_u32(w, u32(v))
	write_u32(w, u32(v >> 32))
}

write_i8 :: proc(w: ^Writer, v: i8) {
	write_u8(w, u8(v))
}

write_i16 :: proc(w: ^Writer, v: i16) {
	write_u16(w, u16(v))
}

write_i32 :: proc(w: ^Writer, v: i32) {
	write_u32(w, u32(v))
}

write_i64 :: proc(w: ^Writer, v: i64) {
	write_u64(w, u64(v))
}

write_f32 :: proc(w: ^Writer, v: f32) {
	write_u32(w, transmute(u32)v)
}

write_f64 :: proc(w: ^Writer, v: f64) {
	write_u64(w, transmute(u64)v)
}

// A whole number in as few bytes as it takes (7 bits a byte; the high bit says "more follows"): for lengths and counts, most of which are small.
write_varint :: proc(w: ^Writer, v: u64) {
	v := v
	for v >= 0x80 {
		append(&w.data, u8(v) | 0x80)
		v >>= 7
	}
	append(&w.data, u8(v))
}

write_bytes :: proc(w: ^Writer, b: []u8) {
	append(&w.data, ..b)
}

// A length (a varint) and the bytes of the string.
write_string :: proc(w: ^Writer, s: string) {
	write_varint(w, u64(len(s)))
	append(&w.data, ..transmute([]u8)s)
}

write_tag :: proc(w: ^Writer, t: Tag) {
	t := t
	append(&w.data, ..t[:])
}

// The start of a chunk (see end_chunk).
Chunk_Mark :: struct {
	length_at: int,
}

// Starts a chunk: its tag, its version and a length that end_chunk fills in. Chunks may be nested (a chunk's bytes can hold chunks).
begin_chunk :: proc(w: ^Writer, t: string, version: u16 = 1) -> Chunk_Mark {
	write_tag(w, tag(t))
	write_u16(w, version)
	at := len(w.data)
	write_u32(w, 0)
	return {at}
}

end_chunk :: proc(w: ^Writer, m: Chunk_Mark) {
	n := u32(len(w.data) - m.length_at - 4)
	w.data[m.length_at] = u8(n)
	w.data[m.length_at + 1] = u8(n >> 8)
	w.data[m.length_at + 2] = u8(n >> 16)
	w.data[m.length_at + 3] = u8(n >> 24)
}

// The start of a file: a magic (4 letters: what the file is) and a version of the whole format.
write_header :: proc(w: ^Writer, magic: string, version: u16) {
	write_tag(w, tag(magic))
	write_u16(w, version)
}

// Ends the file: appends the checksum of everything written so far.
seal :: proc(w: ^Writer) {
	write_u32(w, hash.crc32(w.data[:]))
}

// The bytes of a sealed file without its checksum, if the checksum is right (false: the file is damaged or was not sealed).
unseal :: proc(data: []u8) -> (body: []u8, ok: bool) {
	if len(data) < 4 {
		return nil, false
	}
	n := len(data) - 4
	want := u32(data[n]) | u32(data[n + 1]) << 8 | u32(data[n + 2]) << 16 | u32(data[n + 3]) << 24
	if hash.crc32(data[:n]) != want {
		return nil, false
	}
	return data[:n], true
}

// ---- reading -------------------------------------------------------------------------------------------------------------------

// Reads from bytes. It never reads past the end: a number asked for where too few bytes are left comes out as zero, a string as "", and `failed` is
// set (and stays set), so a reader can ask for everything and look once at the end. That is also what makes a chunk that has grown fields at its
// end readable by the older program that does not ask for them.
Reader :: struct {
	data:   []u8,
	pos:    int,
	failed: bool,
}

reader :: proc(data: []u8) -> Reader {
	return {data = data}
}

remaining :: proc(r: ^Reader) -> int {
	return len(r.data) - r.pos
}

at_end :: proc(r: ^Reader) -> bool {
	return r.pos >= len(r.data)
}

@(private)
take :: proc(r: ^Reader, n: int) -> []u8 {
	if n < 0 || r.pos + n > len(r.data) {
		r.failed = true
		r.pos = len(r.data)
		return nil
	}
	b := r.data[r.pos:r.pos + n]
	r.pos += n
	return b
}

read_u8 :: proc(r: ^Reader) -> u8 {
	b := take(r, 1)
	return b[0] if b != nil else 0
}

read_bool :: proc(r: ^Reader) -> bool {
	return read_u8(r) != 0
}

read_u16 :: proc(r: ^Reader) -> u16 {
	b := take(r, 2)
	return u16(b[0]) | u16(b[1]) << 8 if b != nil else 0
}

read_u32 :: proc(r: ^Reader) -> u32 {
	b := take(r, 4)
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24 if b != nil else 0
}

read_u64 :: proc(r: ^Reader) -> u64 {
	lo := u64(read_u32(r))
	hi := u64(read_u32(r))
	return lo | hi << 32
}

read_i8 :: proc(r: ^Reader) -> i8 {
	return i8(read_u8(r))
}

read_i16 :: proc(r: ^Reader) -> i16 {
	return i16(read_u16(r))
}

read_i32 :: proc(r: ^Reader) -> i32 {
	return i32(read_u32(r))
}

read_i64 :: proc(r: ^Reader) -> i64 {
	return i64(read_u64(r))
}

read_f32 :: proc(r: ^Reader) -> f32 {
	return transmute(f32)read_u32(r)
}

read_f64 :: proc(r: ^Reader) -> f64 {
	return transmute(f64)read_u64(r)
}

read_varint :: proc(r: ^Reader) -> u64 {
	v: u64
	shift: uint
	for {
		b := take(r, 1)
		if b == nil || shift > 63 {
			r.failed = true
			return 0
		}
		v |= u64(b[0] & 0x7F) << shift
		if b[0] & 0x80 == 0 {
			return v
		}
		shift += 7
	}
}

// `n` bytes, as a view into the data being read.
read_bytes :: proc(r: ^Reader, n: int) -> []u8 {
	return take(r, n)
}

// A string written by write_string, as a view into the data being read (clone it to keep it past the data).
read_string :: proc(r: ^Reader) -> string {
	n := read_varint(r)
	if n > u64(remaining(r)) {
		r.failed = true
		r.pos = len(r.data)
		return ""
	}
	return string(take(r, int(n)))
}

// The same, as a copy.
read_string_clone :: proc(r: ^Reader, allocator := context.allocator) -> string {
	s := read_string(r)
	if len(s) == 0 {
		return ""
	}
	c := make([]u8, len(s), allocator)
	copy(c, transmute([]u8)s)
	return string(c)
}

// The magic and the version at the start of a file (ok = false: too short).
read_header :: proc(r: ^Reader) -> (magic: Tag, version: u16, ok: bool) {
	b := take(r, 4)
	if b == nil {
		return {}, 0, false
	}
	copy(magic[:], b)
	version = read_u16(r)
	return magic, version, !r.failed
}

Chunk :: struct {
	tag:     Tag,
	version: u16,
	data:    []u8, // its bytes: a view into the data being read (reader(data) reads them)
}

// The next chunk, for `for c in iv_datafile.next_chunk(&r)`; false at the end, or when a chunk's length runs past the end of the data (r.failed is set then).
next_chunk :: proc(r: ^Reader) -> (c: Chunk, ok: bool) {
	if at_end(r) {
		return {}, false
	}
	b := take(r, 4)
	if b == nil {
		return {}, false
	}
	copy(c.tag[:], b)
	c.version = read_u16(r)
	n := int(read_u32(r))
	c.data = take(r, n)
	if r.failed {
		return {}, false
	}
	return c, true
}

// ---- helpers for the common shapes -----------------------------------------------------------------------------------------------

// A slice of plain values (numbers, structs of numbers), written as their bytes: a count and the memory. Only for data whose layout does not change
// between machines and versions of the program (f32 and the integers are fine; write a struct field by field if it may change).
write_slice :: proc(w: ^Writer, s: []$T) where size_of(T) > 0 {
	write_varint(w, u64(len(s)))
	append(&w.data, ..mem.slice_to_bytes(s))
}

// What write_slice wrote, as a new slice (the caller deletes it).
read_slice :: proc(r: ^Reader, $T: typeid, allocator := context.allocator) -> []T where size_of(T) > 0 {
	n := read_varint(r)
	if n > u64(remaining(r) / size_of(T)) {
		r.failed = true
		r.pos = len(r.data)
		return nil
	}
	out := make([]T, int(n), allocator)
	b := take(r, int(n) * size_of(T))
	if len(b) > 0 {
		mem.copy(raw_data(out), raw_data(b), len(b))
	}
	return out
}

// Rounds a float to the nearest integer for storing a fixed-point value (`scale` steps to 1).
quantize :: proc(v: f32, scale: f32) -> i32 {
	return i32(math.round(v * scale))
}
