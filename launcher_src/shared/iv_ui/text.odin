package iv_ui

// ---------------------------------------------------------------------------
// Rectangles for text. This package has no font and no idea how wide a letter is: the program passes a measuring
// procedure (the one of its own font: raylib's MeasureText, a bitmap font's table, a test's fixed width) in a Measure, and
// everything here asks it. Nothing is drawn and nothing is allocated; a string is only looked at.
//
//   measure := ui.Measure{size = my_text_size}      // my_text_size :: proc(user: rawptr, text: string) -> (w, h: int)
//   box  := ui.text_rect(measure, "Hello", button, .Center, .Center)   // where the text goes in the button
//   want := ui.hug(measure, "Hello", ui.Insets{8, 4, 8, 4})            // a button that is just big enough
// ---------------------------------------------------------------------------

// Reports the size of a piece of text on one line, in the units of the layout. `user` is what the program put in
// Measure.user (the font, a context): nil if it did not.
Text_Size_Proc :: #type proc(user: rawptr, text: string) -> (w, h: int)

Measure :: struct {
	size: Text_Size_Proc,
	user: rawptr,
}

// The size of `text` on one line, as a rectangle at the origin. (Empty if the Measure has no procedure.)
text_size :: proc(m: Measure, text: string) -> Rect {
	if m.size == nil {
		return Rect{}
	}
	w, h := m.size(m.user, text)
	return Rect{0, 0, w, h}
}

// Where one line of text goes inside `outer` (the box it takes up, to draw it at its x, y), placed by the alignments
// inside `outer` shrunk by `padding`.
text_rect :: proc(m: Measure, text: string, outer: Rect, horizontal: Align = .Start, vertical: Align = .Center, padding: Insets = {}) -> Rect {
	box := text_size(m, text)
	return place(pad(outer, padding), box.w, box.h, horizontal, vertical)
}

// The size of a box that hugs the text with `padding` around it (a button for a label), at least `min_w` wide and `min_h`
// high, at the origin.
hug :: proc(m: Measure, text: string, padding: Insets = {}, min_w := 0, min_h := 0) -> Rect {
	box := text_size(m, text)
	return Rect{0, 0, max(box.w + padding.left + padding.right, min_w), max(box.h + padding.top + padding.bottom, min_h)}
}

// The box of the widest of several labels (so that the buttons of a row can be the same width), with `padding`.
hug_widest :: proc(m: Measure, labels: []string, padding: Insets = {}, min_w := 0, min_h := 0) -> Rect {
	w, h := min_w, min_h
	for l in labels {
		b := hug(m, l, padding)
		w = max(w, b.w)
		h = max(h, b.h)
	}
	return Rect{0, 0, w, h}
}

// How many bytes of `text` (always a whole number of characters) fit in `max_w` on one line. For cutting a long name
// short ("Mountain Til..."): measure with `fit_len`, draw `text[:n]`. If the whole text fits the result is len(text).
fit_len :: proc(m: Measure, text: string, max_w: int) -> int {
	if m.size == nil {
		return 0
	}
	if w, _ := m.size(m.user, text); w <= max_w {
		return len(text)
	}
	best := 0
	for _, i in text { // `i` is where each character starts: text[:i] is the text without that character and the ones after
		if w, _ := m.size(m.user, text[:i]); w > max_w {
			break
		}
		best = i
	}
	return best
}

// Where a line of word-wrapped text ends: the text starting at byte `from` is broken at the last space that
// still fits in `max_w` (or inside a word that is wider than the line), and also at a newline. Returns the end of the line
// (the end of `text[from:end]` to draw) and where the next line starts (after the space or newline that was
// broken at). The loop of a paragraph:
//
//   at := 0
//   for at < len(text) {
//       end, next := ui.wrap_line(m, text, max_w, at)
//       draw(text[at:end]); at = next
//   }
wrap_line :: proc(m: Measure, text: string, max_w: int, from: int) -> (end, next: int) {
	if from >= len(text) {
		return len(text), len(text)
	}
	if m.size == nil {
		return len(text), len(text)
	}
	last_space := -1
	i := from
	for i < len(text) {
		c := text[i]
		if c == '\n' {
			return i, i + 1
		}
		if c == ' ' {
			last_space = i
		}
		// the next character boundary
		j := i + 1
		for j < len(text) && (text[j] & 0xC0) == 0x80 {
			j += 1
		}
		if w, _ := m.size(m.user, text[from:j]); w > max_w && i > from {
			if last_space > from {
				return last_space, last_space + 1
			}
			return i, i // a word wider than the line: break inside it
		}
		i = j
	}
	return len(text), len(text)
}

// The box of a paragraph of text wrapped to `max_w`: as wide as its longest line, as high as its lines are (each
// `line_h` high, or the height of the text if 0) with `gap` between lines. Counts the lines without storing them.
wrap_rect :: proc(m: Measure, text: string, max_w: int, line_h := 0, gap := 0) -> Rect {
	if m.size == nil {
		return Rect{}
	}
	widest, lines := 0, 0
	lh := line_h
	at := 0
	for {
		end, next := wrap_line(m, text, max_w, at)
		w, h := m.size(m.user, text[at:end])
		widest = max(widest, w)
		if lh == 0 {
			lh = h
		}
		lines += 1
		if next >= len(text) {
			break
		}
		at = max(next, at + 1) // (a line always uses up something)
	}
	return Rect{0, 0, widest, lines * lh + max(lines - 1, 0) * gap}
}

// The `index`-th line of a block of lines `line_h` high with `gap` between them, inside `r` (the line is as wide as `r`).
line_rect :: proc(r: Rect, index, line_h: int, gap := 0) -> Rect {
	return row_at(r, index, line_h, gap)
}
