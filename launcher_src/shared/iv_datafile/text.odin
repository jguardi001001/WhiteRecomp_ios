// Reading and writing the data of a program: text files made of lines (data packs, settings, save files) and a small binary format of tagged chunks.
//
// Text files. They are made of lines, one thing a line; blank lines and lines that start with # are notes. A line is one of two kinds:
//   words   a first word that says what the line is, then words and numbers split by spaces or tabs (next_word, next_int, next_f32, next_bool)
//   fields  fields split by tabs, for things with spaces in them (fields)
// Text is raw: there are no escape codes. A field may hold anything except a tab and a line break; the last field of a line takes the rest of it.
//
//   rest := string(data)
//   for line in iv_datafile.next_line(&rest) {
//       line := line
//       switch kind, _ := iv_datafile.next_word(&line); kind {
//       case "item":  name, _ := iv_datafile.next_word(&line); stack := iv_datafile.next_int(&line, 1)
//       }
//   }
//
// Binary files (binary.odin): a Writer and a Reader of numbers and strings, chunks with a tag and a version so that a reader skips what it does
// not know (a new program version can add chunks and old files still load), and a checksum. File helpers (file.odin) write a file so that a crash
// leaves the old one whole.
//
// Nothing here knows what a program stores; it is the grammar of the files, not their contents.
package iv_datafile

import "core:strconv"
import "core:strings"

// The next line that is not blank or a note, trimmed (unless `trim` is false: then only an empty line is blank). For
// `for line in iv_datafile.next_line(&rest)`.
next_line :: proc(rest: ^string, trim := true) -> (line: string, ok: bool) {
	for l in strings.split_lines_iterator(rest) {
		s := strings.trim_space(l) if trim else l
		if len(s) == 0 || s[0] == '#' {
			continue
		}
		return s, true
	}
	return "", false
}

// The next word of a line (words are separated by spaces and tabs); the line is left with what comes after it.
next_word :: proc(s: ^string) -> (word: string, ok: bool) {
	i := 0
	for i < len(s^) && (s^[i] == ' ' || s^[i] == '\t') {
		i += 1
	}
	if i >= len(s^) {
		s^ = ""
		return "", false
	}
	j := i
	for j < len(s^) && s^[j] != ' ' && s^[j] != '\t' {
		j += 1
	}
	word = s^[i:j]
	s^ = s^[j:]
	return word, true
}

// The next word as a whole number (`default` when there is none or it is not one).
next_int :: proc(s: ^string, default: i32 = 0) -> i32 {
	w, ok := next_word(s)
	if !ok {
		return default
	}
	v, pok := strconv.parse_int(w)
	return i32(v) if pok else default
}

// The next word as a number (`default` when there is none or it is not one).
next_f32 :: proc(s: ^string, default: f32 = 0) -> f32 {
	w, ok := next_word(s)
	if !ok {
		return default
	}
	v, pok := strconv.parse_f32(w)
	return v if pok else default
}

// The next word as a truth value: true / yes / on / 1 and false / no / off / 0 (`default` for anything else).
next_bool :: proc(s: ^string, default := false) -> bool {
	w, ok := next_word(s)
	if !ok {
		return default
	}
	switch w {
	case "true", "yes", "on", "1":
		return true
	case "false", "no", "off", "0":
		return false
	}
	return default
}

// Splits a line of fields at its tabs into `out`; the last one gets the rest of the line (tabs and all). Returns how many it
// filled. The fields are views into the line.
fields :: proc(line: string, out: []string) -> int {
	rest := line
	n := 0
	for n < len(out) - 1 {
		t := strings.index_byte(rest, '\t')
		if t < 0 {
			break
		}
		out[n] = rest[:t]
		rest = rest[t + 1:]
		n += 1
	}
	if n < len(out) {
		out[n] = rest
		n += 1
	}
	return n
}

// Writes one line of words to the builder: the words separated by a space, ending with a newline. (A word must not hold a space: the reader splits at it.)
write_words :: proc(b: ^strings.Builder, words: ..string) {
	for w, i in words {
		if i > 0 {
			strings.write_byte(b, ' ')
		}
		strings.write_string(b, w)
	}
	strings.write_byte(b, '\n')
}

// Writes one line of fields to the builder: the fields separated by a tab, ending with a newline. The fields are written as they are, so one must not
// hold a tab or a line break (the reader splits and ends the line there).
write_fields :: proc(b: ^strings.Builder, fields: ..string) {
	for f, i in fields {
		if i > 0 {
			strings.write_byte(b, '\t')
		}
		strings.write_string(b, f)
	}
	strings.write_byte(b, '\n')
}
