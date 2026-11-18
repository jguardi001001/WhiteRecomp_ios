package iv_text

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import ui "../iv_ui"

// ---- measuring ---------------------------------------------------------------------------------------------------------------------

// How wide `s` is on one line in px at the em `size`, not rounded. Readings are not counted. A '\n' is not a character here (see wrap for lines).
width_f :: proc(tf: ^Typeface, s: string, size: f32) -> f32 {
	pen: f32
	i := 0
	for i < len(s) {
		if _, nx, ok := tf_ruby_at(tf, s, i); ok {
			i = nx
			continue
		}
		r, n := utf8.decode_rune_in_string(s[i:])
		i += n
		pen += advance(tf, r, size)
	}
	return pen
}

// The same rounded up to a whole px.
width :: proc(tf: ^Typeface, s: string, size: f32) -> int {
	return int(math.ceil(width_f(tf, s, size) - 0.001))
}

// The width of the widest line of a text with '\n's, and its height as lines of `line_h` (default: line_height) with `gap` between them.
text_size :: proc(tf: ^Typeface, s: string, size: f32, line_h := 0, gap := 0) -> (w, h: int) {
	lh := line_h if line_h > 0 else line_height(tf, size)
	lines := strings.split(s, "\n", context.temp_allocator)
	for line in lines {
		w = max(w, width(tf, line, size))
	}
	n := len(lines)
	return w, n * lh + (n - 1) * gap
}

// The longest start of `s` that is at most `room` px wide (a reading goes with the letter before it). At least one character is taken when there is any
// (so that a loop that splits a text always moves on).
split :: proc(tf: ^Typeface, s: string, room: int, size: f32) -> (head, tail: string) {
	pen: f32
	i := 0
	for i < len(s) {
		if _, nx, ok := tf_ruby_at(tf, s, i); ok {
			i = nx
			continue
		}
		r, n := utf8.decode_rune_in_string(s[i:])
		adv := advance(tf, r, size)
		if i > 0 && int(math.ceil(pen + adv - 0.001)) > room {
			break
		}
		pen += adv
		i += n
		if _, nx, ok := tf_ruby_at(tf, s, i); ok { // the reading of this letter comes with it
			i = nx
		}
	}
	return s[:i], s[i:]
}

// Is this a character that a line may be broken at either side of (CJK has no spaces between words)?
@(private)
breaks_anywhere :: proc(r: rune) -> bool {
	switch {
	case r >= 0x2E80 && r <= 0x9FFF: // CJK radicals, kana, symbols, ideographs
		return true
	case r >= 0xF900 && r <= 0xFAFF, r >= 0xFF00 && r <= 0xFFEF, r >= 0x20000 && r <= 0x2FFFF, r >= 0xAC00 && r <= 0xD7AF:
		return true
	}
	return false
}

// Characters a line must not start with in Japanese and Chinese (closing brackets and stops): they stay on the line before.
@(private)
no_line_start :: proc(r: rune) -> bool {
	switch r {
	case '、', '。', '，', '．', '）', '」', '』', '】', '〕', '〉', '》', '！', '？', 'ー', '々', 'ぁ', 'ぃ', 'ぅ', 'ぇ', 'ぉ', 'っ', 'ゃ', 'ゅ', 'ょ', 'ゎ', ',', '.', '!', '?', ')', ']', ';', ':':
		return true
	}
	return false
}

// Word-wraps `s` to lines at most `max_w` px wide: at spaces, between characters of scripts without spaces, at every newline, and inside a word that is
// wider than a line. A line that ends at a space does not keep it. The lines are views into `s` (the slice is in the temp allocator unless given).
wrap :: proc(tf: ^Typeface, s: string, max_w: int, size: f32, allocator := context.temp_allocator) -> []string {
	ranges := wrap_ranges(tf, s, max_w, size)
	lines := make([]string, len(ranges), allocator)
	for r, i in ranges {
		lines[i] = s[r[0]:r[1]]
	}
	return lines
}

// The same as byte ranges of `s` (start, end): where each line is, for code that puts a cursor in wrapped text. The ranges are in order, and the
// characters between one line's end and the next's start are the newline or space the break was made at.
wrap_ranges :: proc(tf: ^Typeface, s: string, max_w: int, size: f32, allocator := context.temp_allocator) -> [][2]int {
	out := make([dynamic][2]int, allocator)
	at := 0
	for {
		nl := strings.index_byte(s[at:], '\n')
		end := len(s) if nl < 0 else at + nl
		wrap_paragraph(tf, s[:end], at, max_w, size, &out)
		if nl < 0 {
			break
		}
		at = end + 1
	}
	return out[:]
}

// Wraps the paragraph s[base:] (s ends where the paragraph does) into `out` as ranges of s.
@(private)
wrap_paragraph :: proc(tf: ^Typeface, p: string, base: int, max_w: int, size: f32, out: ^[dynamic][2]int) {
	start := base
	pen: f32
	break_at := -1 // where the next line would start if the line breaks here (a byte place)
	line_end := -1 // the end of the text of the line when it breaks at break_at (a space is left out)
	i := base
	if base >= len(p) {
		append(out, [2]int{base, base})
		return
	}
	for i < len(p) {
		if _, nx, ok := tf_ruby_at(tf, p, i); ok {
			i = nx
			continue
		}
		r, n := utf8.decode_rune_in_string(p[i:])
		adv := advance(tf, r, size)
		if r == ' ' {
			// a space is a place to break after; it may hang over the edge
			pen += adv
			i += n
			break_at, line_end = i, i - n
			continue
		}
		if int(math.ceil(pen + adv - 0.001)) > max_w && i > start {
			if break_at > start {
				append(out, [2]int{start, line_end})
				start = break_at
				i = start
				pen = 0
				break_at, line_end = -1, -1
				continue
			}
			// no place to break: break here
			append(out, [2]int{start, i})
			start = i
			pen = 0
			break_at, line_end = -1, -1
			continue
		}
		pen += adv
		i += n
		if _, nx, ok := tf_ruby_at(tf, p, i); ok { // the reading goes with the letter
			i = nx
		}
		if breaks_anywhere(r) && i < len(p) {
			next, _ := utf8.decode_rune_in_string(p[i:])
			if !no_line_start(next) {
				break_at, line_end = i, i
			}
		}
	}
	append(out, [2]int{start, len(p)})
}

// Where the character that starts at byte `at` of `s` begins, in px from the start of the text (at == len(s): the end).
x_at :: proc(tf: ^Typeface, s: string, at: int, size: f32) -> f32 {
	return width_f(tf, s[:clamp(at, 0, len(s))], size)
}

// The byte place of `s` (the start of a character, or the end) nearest to `x` px from the start of the text: where a click puts the cursor.
byte_near :: proc(tf: ^Typeface, s: string, x: f32, size: f32) -> int {
	pen: f32
	i := 0
	for i < len(s) {
		if _, nx, ok := tf_ruby_at(tf, s, i); ok {
			i = nx
			continue
		}
		r, n := utf8.decode_rune_in_string(s[i:])
		adv := advance(tf, r, size)
		if x < pen + adv / 2 {
			return i
		}
		pen += adv
		i += n
	}
	return len(s)
}

// ---- a measure for iv_ui ----------------------------------------------------------------------------------------------------------------

// A Measure: what iv_ui's layout asks to size boxes of text. `size` is the em. Keep the Measurer alive as long as the Measure is used.
Measurer :: struct {
	tf:   ^Typeface,
	size: f32,
}

// (The room for readings is in it when the typeface has furigana on.)
measurer_size :: proc(user: rawptr, text: string) -> (w, h: int) {
	m := (^Measurer)(user)
	w, h = text_size(m.tf, text, m.size)
	h += ruby_room(m.tf, text, m.size)
	return
}

measure_of :: proc(m: ^Measurer) -> ui.Measure {
	return {size = measurer_size, user = m}
}
