package iv_ui

import "core:testing"

@(test)
test_inset_and_pad :: proc(t: ^testing.T) {
	r := make_rect(10, 20, 100, 50)
	testing.expect_value(t, inset(r, 5), Rect{15, 25, 90, 40})
	testing.expect_value(t, inset_xy(r, 10, 2), Rect{20, 22, 80, 46})
	testing.expect_value(t, pad(r, Insets{1, 2, 3, 4}), Rect{11, 22, 96, 44})
	testing.expect_value(t, outset(r, 3), Rect{7, 17, 106, 56})
	testing.expect_value(t, outset_by(r, Insets{1, 2, 3, 4}), Rect{9, 18, 104, 56})
	// too small to inset: collapses in the middle, never negative
	tiny := inset(make_rect(0, 0, 10, 10), 20)
	testing.expect(t, tiny.w == 0 && tiny.h == 0 && tiny.x == 5 && tiny.y == 5, "collapsed to the center")
}

@(test)
test_cut :: proc(t: ^testing.T) {
	r := make_rect(0, 0, 100, 60)
	top, rest := cut_top(r, 10)
	testing.expect_value(t, top, Rect{0, 0, 100, 10})
	testing.expect_value(t, rest, Rect{0, 10, 100, 50})
	left, rest2 := cut_left(rest, 30, 4)
	testing.expect_value(t, left, Rect{0, 10, 30, 50})
	testing.expect_value(t, rest2, Rect{34, 10, 66, 50})
	right, rest3 := cut_right(rest2, 20)
	testing.expect_value(t, right, Rect{80, 10, 20, 50})
	testing.expect_value(t, rest3, Rect{34, 10, 46, 50})
	bot, rest4 := cut_bottom(rest3, 8, 2)
	testing.expect_value(t, bot, Rect{34, 52, 46, 8})
	testing.expect_value(t, rest4, Rect{34, 10, 46, 40})

	// more than there is: all of it, and nothing left
	all, none := cut_left(r, 500)
	testing.expect_value(t, all, r)
	testing.expect(t, is_empty(none))
	// fractions
	half, other := cut_left_frac(r, 0.5)
	testing.expect_value(t, half.w, 50)
	testing.expect_value(t, other.x, 50)
	// by side
	c, rr := cut(r, .Bottom, 10)
	testing.expect_value(t, c.y, 50)
	testing.expect_value(t, rr.h, 50)
}

@(test)
test_columns_fill_exactly :: proc(t: ^testing.T) {
	r := make_rect(5, 0, 100, 20)
	total := 0
	for i in 0 ..< 3 {
		c := columns(r, i, 3, 0)
		testing.expect_value(t, c.h, 20)
		total += c.w
	}
	testing.expect_value(t, total, 100)
	// the pieces touch and do not overlap
	a, b, c := columns(r, 0, 3), columns(r, 1, 3), columns(r, 2, 3)
	testing.expect_value(t, right(a), b.x)
	testing.expect_value(t, right(b), c.x)
	testing.expect_value(t, right(c), 105)
	// with gaps: 3 columns, gap 4: (100 - 8) = 92 to share
	a, b, c = columns(r, 0, 3, 4), columns(r, 1, 3, 4), columns(r, 2, 3, 4)
	testing.expect_value(t, b.x - right(a), 4)
	testing.expect_value(t, c.x - right(b), 4)
	testing.expect_value(t, a.w + b.w + c.w, 92)
	testing.expect_value(t, right(c), 105)

	rw := rows(make_rect(0, 0, 10, 10), 2, 3)
	testing.expect_value(t, rw, Rect{0, 7, 10, 3}) // 10 / 3: the first one is a pixel higher: 4, 3, 3
	testing.expect_value(t, rows(make_rect(0, 0, 10, 10), 0, 3).h, 4)

	g := grid_cell(make_rect(0, 0, 90, 60), 2, 1, 3, 2, 0, 0)
	testing.expect_value(t, g, Rect{60, 30, 30, 30})
	testing.expect_value(t, columns(r, 0, 0), Rect{5, 0, 0, 20}) // nothing to divide into: empty, no crash
}

@(test)
test_weighted :: proc(t: ^testing.T) {
	r := make_rect(0, 0, 100, 10)
	w := []int{1, 2, 1}
	a, b, c := weighted_columns(r, w, 0), weighted_columns(r, w, 1), weighted_columns(r, w, 2)
	testing.expect_value(t, a.w + b.w + c.w, 100)
	testing.expect_value(t, b.w, 50)
	testing.expect_value(t, right(a), b.x)
	testing.expect_value(t, right(b), c.x)
	a, b = weighted_columns(r, w, 0, 10), weighted_columns(r, w, 1, 10)
	testing.expect_value(t, b.x - right(a), 10)
	testing.expect_value(t, weighted_rows(make_rect(0, 0, 10, 100), w, 1, 0).h, 50)
}

@(test)
test_items :: proc(t: ^testing.T) {
	r := make_rect(10, 10, 80, 200)
	testing.expect_value(t, row_at(r, 0, 24, 2), Rect{10, 10, 80, 24})
	testing.expect_value(t, row_at(r, 3, 24, 2), Rect{10, 88, 80, 24})
	testing.expect_value(t, column_at(r, 2, 30, 5), Rect{80, 10, 30, 200})
	testing.expect_value(t, fit_count(100, 24, 2), 3)
	testing.expect_value(t, fit_count(102, 24, 2), 4)
	testing.expect_value(t, fit_count(10, 24), 0)
	testing.expect_value(t, fit_count(10, 0), 0)
}

@(test)
test_placing :: proc(t: ^testing.T) {
	outer := make_rect(100, 100, 200, 100)
	testing.expect_value(t, center(outer, 50, 20), Rect{175, 140, 50, 20})
	testing.expect_value(t, place(outer, 50, 20, .Start, .Start), Rect{100, 100, 50, 20})
	testing.expect_value(t, place(outer, 50, 20, .End, .End), Rect{250, 180, 50, 20})
	testing.expect_value(t, align(outer, make_rect(0, 0, 40, 40), .End, .Center), Rect{260, 130, 40, 40})

	f := fit_aspect(make_rect(0, 0, 200, 100), 1, 1) // a square in a wide box
	testing.expect_value(t, f, Rect{50, 0, 100, 100})
	f = fit_aspect(make_rect(0, 0, 100, 200), 2, 1)
	testing.expect_value(t, f, Rect{0, 75, 100, 50})
	c := fill_aspect(make_rect(0, 0, 200, 100), 1, 1)
	testing.expect_value(t, c, Rect{0, -50, 200, 200})
	testing.expect(t, is_empty(fit_aspect(outer, 0, 5)))
}

@(test)
test_combining :: proc(t: ^testing.T) {
	a := make_rect(0, 0, 10, 10)
	b := make_rect(5, 5, 10, 10)
	testing.expect_value(t, intersect(a, b), Rect{5, 5, 5, 5})
	testing.expect_value(t, bounding(a, b), Rect{0, 0, 15, 15})
	testing.expect(t, overlaps(a, b))
	testing.expect(t, !overlaps(a, make_rect(10, 0, 5, 5)), "touching is not overlapping")
	testing.expect(t, is_empty(intersect(a, make_rect(20, 20, 5, 5))))
	testing.expect_value(t, bounding(Rect{}, b), b)
	testing.expect(t, contains(a, 0, 0) && contains(a, 9, 9) && !contains(a, 10, 5), "the right and bottom edges are outside")
	testing.expect(t, contains_rect(a, make_rect(2, 2, 3, 3)) && !contains_rect(a, b))
	testing.expect_value(t, from_corners(10, 10, 0, 4), Rect{0, 4, 10, 6})
	testing.expect_value(t, translate(a, 3, -2), Rect{3, -2, 10, 10})
	testing.expect_value(t, with_width(a, 4), Rect{0, 0, 4, 10})
}

@(test)
test_keep_inside_and_popup :: proc(t: ^testing.T) {
	screen := make_rect(0, 0, 400, 300)
	testing.expect_value(t, keep_inside(make_rect(380, 290, 50, 30), screen), Rect{350, 270, 50, 30})
	testing.expect_value(t, keep_inside(make_rect(-10, -10, 50, 30), screen), Rect{0, 0, 50, 30})
	testing.expect_value(t, keep_inside(make_rect(0, 0, 500, 30), screen), Rect{0, 0, 400, 30}) // too wide: made narrower

	button := make_rect(20, 20, 80, 24)
	testing.expect_value(t, popup(button, 100, 60, screen, .Bottom, 2), Rect{20, 46, 100, 60})
	low := make_rect(20, 270, 80, 24) // no room below: it opens above
	testing.expect_value(t, popup(low, 100, 60, screen, .Bottom, 2), Rect{20, 208, 100, 60})
	edge := make_rect(350, 20, 40, 24) // sticks out on the right: pushed back inside
	testing.expect_value(t, popup(edge, 100, 60, screen, .Bottom).x, 300)
}

@(test)
test_thumbs :: proc(t: ^testing.T) {
	track := make_rect(0, 0, 10, 100)
	th := thumb(track, 400, 100, 0)
	testing.expect_value(t, th, Rect{0, 0, 10, 25})
	th = thumb(track, 400, 100, 300) // scrolled all the way
	testing.expect_value(t, th, Rect{0, 75, 10, 25})
	th = thumb(track, 400, 100, 150)
	testing.expect_value(t, th.y, 37)
	testing.expect_value(t, thumb(track, 50, 100, 0), track) // nothing to scroll
	testing.expect_value(t, thumb(track, 100000, 100, 0).h, 12) // never thinner than min_len
	testing.expect_value(t, thumb(make_rect(0, 0, 100, 10), 400, 100, 300, vertical = false), Rect{75, 0, 25, 10})

	// dragging it back gives the offset
	testing.expect_value(t, thumb_offset(track, 400, 100, 75), 300)
	testing.expect_value(t, thumb_offset(track, 400, 100, 0), 0)
	testing.expect_value(t, thumb_offset(track, 400, 100, 40, 3), (300 * 37) / 75)
	testing.expect_value(t, thumb_offset(track, 400, 100, 500), 300) // dragged past the end
}

@(test)
test_bars :: proc(t: ^testing.T) {
	track := make_rect(10, 10, 100, 8)
	testing.expect_value(t, fill(track, 0.25), Rect{10, 10, 25, 8})
	testing.expect_value(t, fill(track, 2), Rect{10, 10, 100, 8})
	testing.expect_value(t, fill(make_rect(0, 0, 8, 100), 0.5, true), Rect{0, 50, 8, 50})
	k := knob(track, 0.5, 10)
	testing.expect_value(t, k, Rect{55, 9, 10, 10})
	testing.expect_value(t, track_position(track, 60), 0.5)
	testing.expect_value(t, track_position(track, 0), 0)
	testing.expect_value(t, track_position(track, 999), 1)
	testing.expect_value(t, track_position(make_rect(0, 0, 8, 100), 25, true), 0.75)
}

// ---- text, with a font that is 8 wide and 10 high ----------------------------------------------------

fixed :: proc(user: rawptr, text: string) -> (w, h: int) {
	n := 0
	for _ in text {
		n += 1
	}
	return n * 8, 10
}

@(test)
test_text_boxes :: proc(t: ^testing.T) {
	m := Measure{size = fixed}
	testing.expect_value(t, text_size(m, "abc"), Rect{0, 0, 24, 10})
	testing.expect_value(t, text_size(m, "héé"), Rect{0, 0, 24, 10}) // characters, not bytes
	testing.expect_value(t, text_size(Measure{}, "abc"), Rect{}) // no measuring procedure: nothing

	button := make_rect(0, 0, 100, 30)
	testing.expect_value(t, text_rect(m, "abc", button, .Center, .Center), Rect{38, 10, 24, 10})
	testing.expect_value(t, text_rect(m, "abc", button, .Start, .Center, Insets{6, 0, 0, 0}), Rect{6, 10, 24, 10})
	testing.expect_value(t, hug(m, "abc", Insets{8, 4, 8, 4}), Rect{0, 0, 40, 18})
	testing.expect_value(t, hug(m, "a", Insets{}, 50, 0).w, 50)
	testing.expect_value(t, hug_widest(m, {"ab", "abcd", "a"}, Insets{2, 0, 2, 0}), Rect{0, 0, 36, 10})
}

@(test)
test_fit_len :: proc(t: ^testing.T) {
	m := Measure{size = fixed}
	testing.expect_value(t, fit_len(m, "hello", 100), 5)
	testing.expect_value(t, fit_len(m, "hello", 24), 3)
	testing.expect_value(t, fit_len(m, "hello", 7), 0)
	testing.expect_value(t, fit_len(m, "héllo", 16), 3) // 'h' and 'é' are 3 bytes: a cut never lands inside a character
}

@(test)
test_wrap :: proc(t: ^testing.T) {
	m := Measure{size = fixed}
	text := "one two three"
	// 8 characters per line: "one two" / "three"
	end, next := wrap_line(m, text, 64, 0)
	testing.expect_value(t, text[:end], "one two")
	testing.expect_value(t, next, 8)
	end, next = wrap_line(m, text, 64, next)
	testing.expect_value(t, text[8:end], "three")
	testing.expect_value(t, next, len(text))

	box := wrap_rect(m, text, 64)
	testing.expect_value(t, box, Rect{0, 0, 56, 20})
	testing.expect_value(t, wrap_rect(m, text, 64, 12, 2), Rect{0, 0, 56, 26}) // two lines of 12 and a gap of 2
	testing.expect_value(t, wrap_rect(m, "short", 640), Rect{0, 0, 40, 10})
	testing.expect_value(t, wrap_rect(m, "a\nb\nc", 640).h, 30) // newlines break lines

	// a word wider than the line is broken inside it, and every line uses up something
	long := "abcdefghijkl"
	lines := 0
	at := 0
	for at < len(long) {
		e, n := wrap_line(m, long, 40, at)
		testing.expect(t, e - at <= 5 && n > at, "progress and width")
		at = n
		lines += 1
	}
	testing.expect_value(t, lines, 3)
	testing.expect_value(t, wrap_rect(m, "", 100), Rect{0, 0, 0, 10}) // an empty text is one empty line
}
