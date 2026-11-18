package iv_datafile

import "core:os"
import "core:strings"
import "core:testing"

@(test)
lines_words_and_numbers :: proc(t: ^testing.T) {
	rest := "# a note\n\nitem  iron_ore \t 64 1.5 yes\n  quest q1\n"
	n := 0
	for line in next_line(&rest) {
		line := line
		kind, _ := next_word(&line)
		switch kind {
		case "item":
			name, _ := next_word(&line)
			testing.expect_value(t, name, "iron_ore")
			testing.expect_value(t, next_int(&line), 64)
			testing.expect_value(t, next_f32(&line), 1.5)
			testing.expect_value(t, next_bool(&line), true)
			testing.expect_value(t, next_int(&line, 7), 7) // nothing left: the default
		case "quest":
			id, _ := next_word(&line)
			testing.expect_value(t, id, "q1")
		case:
			testing.fail(t)
		}
		n += 1
	}
	testing.expect_value(t, n, 2)
}

@(test)
fields_and_raw_text_round_trip :: proc(t: ^testing.T) {
	f: [3]string
	testing.expect_value(t, fields("a\tb c\td\te", f[:]), 3)
	testing.expect_value(t, f[0], "a")
	testing.expect_value(t, f[1], "b c")
	testing.expect_value(t, f[2], "d\te") // the last one keeps the rest

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fields(&b, "EN", "key", "a \\n is two characters")
	write_words(&b, "item", "iron", "64")
	testing.expect_value(t, strings.to_string(b), "EN\tkey\ta \\n is two characters\nitem iron 64\n") // nothing is escaped
	rest := strings.to_string(b)
	line, _ := next_line(&rest)
	testing.expect_value(t, fields(line, f[:]), 3)
	testing.expect_value(t, f[2], "a \\n is two characters")
}

@(test)
binary_round_trip_with_chunks :: proc(t: ^testing.T) {
	w: Writer
	writer_init(&w)
	defer writer_destroy(&w)
	write_header(&w, "TEST", 3)
	m := begin_chunk(&w, "NUMS", 2)
	write_u8(&w, 200)
	write_i16(&w, -1234)
	write_u32(&w, 0xDEADBEEF)
	write_i64(&w, -9_000_000_000)
	write_f32(&w, 1.25)
	write_f64(&w, -2.5)
	write_bool(&w, true)
	write_varint(&w, 300)
	end_chunk(&w, m)
	m2 := begin_chunk(&w, "TEXT")
	write_string(&w, "héllo")
	write_slice(&w, []i32{1, 2, 3})
	end_chunk(&w, m2)
	seal(&w)

	body, ok := unseal(w.data[:])
	testing.expect(t, ok)
	r := reader(body)
	magic, version, hok := read_header(&r)
	testing.expect(t, hok && magic == tag("TEST") && version == 3)

	seen := 0
	for c in next_chunk(&r) {
		cr := reader(c.data)
		switch tag_string(c.tag) {
		case "NUMS":
			testing.expect_value(t, c.version, 2)
			testing.expect_value(t, read_u8(&cr), 200)
			testing.expect_value(t, read_i16(&cr), -1234)
			testing.expect_value(t, read_u32(&cr), 0xDEADBEEF)
			testing.expect_value(t, read_i64(&cr), -9_000_000_000)
			testing.expect_value(t, read_f32(&cr), 1.25)
			testing.expect_value(t, read_f64(&cr), -2.5)
			testing.expect_value(t, read_bool(&cr), true)
			testing.expect_value(t, read_varint(&cr), 300)
			testing.expect(t, at_end(&cr) && !cr.failed)
		case "TEXT":
			testing.expect_value(t, read_string(&cr), "héllo")
			s := read_slice(&cr, i32)
			defer delete(s)
			testing.expect_value(t, len(s), 3)
			testing.expect_value(t, s[2], 3)
			testing.expect(t, !cr.failed)
		case:
			testing.fail(t)
		}
		seen += 1
	}
	testing.expect_value(t, seen, 2)
	testing.expect(t, !r.failed)
}

@(test)
reader_never_reads_past_the_end :: proc(t: ^testing.T) {
	// a chunk that an older program reads: it asks for fields the file does not have
	w: Writer
	writer_init(&w)
	defer writer_destroy(&w)
	write_u16(&w, 7)
	r := reader(w.data[:])
	testing.expect_value(t, read_u16(&r), 7)
	testing.expect(t, !r.failed)
	testing.expect_value(t, read_u32(&r), 0) // nothing left: zero and failed
	testing.expect(t, r.failed)
	testing.expect_value(t, read_string(&r), "")

	// a string that claims more bytes than there are
	bad := []u8{0xFF, 0x7F, 'a'}
	r2 := reader(bad)
	testing.expect_value(t, read_string(&r2), "")
	testing.expect(t, r2.failed)

	// a chunk whose length runs past the end ends the loop
	trunc := []u8{'A', 'B', 'C', 'D', 1, 0, 100, 0, 0, 0, 1, 2}
	r3 := reader(trunc)
	_, got := next_chunk(&r3)
	testing.expect(t, !got && r3.failed)
}

@(test)
checksum_catches_damage :: proc(t: ^testing.T) {
	w: Writer
	writer_init(&w)
	defer writer_destroy(&w)
	write_header(&w, "TEST", 1)
	write_string(&w, "important")
	seal(&w)
	_, ok := unseal(w.data[:])
	testing.expect(t, ok)
	w.data[8] ~= 0x01
	_, ok = unseal(w.data[:])
	testing.expect(t, !ok)
	_, ok = unseal(nil)
	testing.expect(t, !ok)
}

@(test)
save_and_load_a_file :: proc(t: ^testing.T) {
	path := "iv_datafile_test_tmp/dir/file.bin"
	defer {
		os.remove("iv_datafile_test_tmp/dir/file.bin")
		os.remove("iv_datafile_test_tmp/dir")
		os.remove("iv_datafile_test_tmp")
	}
	testing.expect(t, save_file(path, []u8{1, 2, 3}))
	testing.expect(t, save_file(path, []u8{4, 5})) // over the old one
	d, ok := load_file(path)
	defer delete(d)
	testing.expect(t, ok)
	testing.expect_value(t, len(d), 2)
	testing.expect_value(t, d[0], 4)
	testing.expect(t, !os.exists(strings.concatenate({path, ".tmp"}, context.temp_allocator)))
	_, missing := load_file("iv_datafile_test_tmp/nothing.bin")
	testing.expect(t, !missing)
}
