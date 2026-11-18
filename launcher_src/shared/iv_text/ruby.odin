package iv_text

import "core:math"
import "core:strings"

// ---------------------------------------------------------------------------
// Readings (ruby, furigana). A text carries the reading of a letter after it in double braces: "漢{{かん}}字{{じ}}". The braces and what is in them are
// not part of the line: they take no width, and a wrap or a split never puts a reading apart from its letter. With `Typeface.furigana` on, draw puts each reading
// small (Typeface.ruby_scale of the em) centred above its letter, in the ruby_height(...) pixels above the line; with it off they are not drawn (and
// a text should not be given room for them: ruby_room is 0). The program turns them on and off for the whole typeface (set_furigana(&tf, on): a setting
// of the player's), and everything that is laid out (width, split, wrap, cursor places) is the same either way. Typeface.literal is the third way: the
// braces are letters like the rest and nothing is a reading (what an editor that shows the raw text wants).
//
// The same markup works for any language and any kind of annotation (a pronunciation, a gloss). iv_i18n can take the readings out of a text before it
// gets here (a setting that turns them off).
// ---------------------------------------------------------------------------

// A reading that starts at byte i of s: what is in the braces, and where the text goes on.
ruby_at :: proc(s: string, i: int) -> (reading: string, next: int, ok: bool) {
	if i + 1 < len(s) && s[i] == '{' && s[i + 1] == '{' {
		end := strings.index(s[i + 2:], "}}")
		if end >= 0 {
			return s[i + 2:i + 2 + end], i + 2 + end + 2, true
		}
	}
	return "", i, false
}

// ruby_at for a typeface: with Typeface.literal on there are no readings (the braces are letters like the rest: for an editor that shows raw text).
tf_ruby_at :: proc(tf: ^Typeface, s: string, i: int) -> (reading: string, next: int, ok: bool) {
	if tf.literal {
		return "", i, false
	}
	return ruby_at(s, i)
}

// Does the text have a reading in it?
has_ruby :: proc(s: string) -> bool {
	i := strings.index(s, "{{")
	if i < 0 {
		return false
	}
	return strings.contains(s[i + 2:], "}}")
}

// The text with its readings left out (a new string; the caller deletes it).
strip_ruby :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if _, nx, ok := ruby_at(s, i); ok {
			i = nx
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

// The pixels above a line that a reading takes: its own height plus the gap to the letters.
ruby_height :: proc(tf: ^Typeface, size: f32) -> int {
	rs := size * tf.ruby_scale
	return ascent(tf, rs) + descent(tf, rs) + ruby_gap_px(tf, size)
}

// The gap between the bottom of a reading and the top of the line, in px.
ruby_gap_px :: proc(tf: ^Typeface, size: f32) -> int {
	return int(math.ceil(tf.ruby_gap * size))
}

// How much higher a line has to be for `s` to fit in it: ruby_height if readings are drawn (tf.furigana) and the text has one, else 0. Add it above the
// line (draw the text lower by it, or make the box that high).
ruby_room :: proc(tf: ^Typeface, s: string, size: f32) -> int {
	if tf.furigana && !tf.literal && has_ruby(s) {
		return ruby_height(tf, size)
	}
	return 0
}

// The most of ruby_room over several texts (the height a box needs to fit any of them).
ruby_room_all :: proc(tf: ^Typeface, size: f32, texts: ..string) -> int {
	n := 0
	for s in texts {
		n = max(n, ruby_room(tf, s, size))
	}
	return n
}
