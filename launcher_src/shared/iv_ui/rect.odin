package iv_ui

// ---------------------------------------------------------------------------
// Rectangle math for user interfaces, and nothing else.
//
// This package draws nothing, reads no input, owns no state and imports nothing. Every procedure takes rectangles and
// numbers and gives back a new Rect (or two: the piece that was cut off and what is left), so a layout is a few lines of
// values flowing downwards:
//
//   screen := ui.make_rect(0, 0, w, h)
//   top, rest   := ui.cut_top(screen, 40)                // the title bar, and the rest
//   side, main  := ui.cut_left(ui.inset(rest, 8), 220)   // a side panel, and the main area
//   button      := ui.center(side, 120, 28)              // a button in the middle of the panel
//   label       := ui.text_rect(measure, "Save", button, .Center, .Center)
//
// Components (buttons, sliders, lists) are not in here: each program makes its own out of these, so each has its
// own look. Units are whatever the program lays out in (pixels, or cells), whole numbers.
// ---------------------------------------------------------------------------

Rect :: struct {
	x, y, w, h: int, // the top left corner and the size (w, h < 0 count as 0 where it matters)
}

// The space around something, or inside it.
Insets :: struct {
	left, top, right, bottom: int,
}

// Where a box sits inside a larger one along an axis: against the start (left, top), in the middle, against the end.
Align :: enum u8 {
	Start,
	Center,
	End,
}

// A side of a rectangle.
Side :: enum u8 {
	Left,
	Right,
	Top,
	Bottom,
}

// ---- making and measuring ------------------------------------------------------------------------------

make_rect :: proc "contextless" (x, y, w, h: int) -> Rect {
	return Rect{x, y, w, h}
}

// A rectangle from two opposite corners (the second corner is not inside it: x1 - x0 is its width).
from_corners :: proc "contextless" (x0, y0, x1, y1: int) -> Rect {
	return Rect{min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0)}
}

// The same size at the origin: the box of something that has not been placed yet.
sized :: proc "contextless" (w, h: int) -> Rect {
	return Rect{0, 0, w, h}
}

// The first x / y outside the rectangle (x + w, y + h).
right :: proc "contextless" (r: Rect) -> int {
	return r.x + r.w
}

bottom :: proc "contextless" (r: Rect) -> int {
	return r.y + r.h
}

center_x :: proc "contextless" (r: Rect) -> int {
	return r.x + r.w / 2
}

center_y :: proc "contextless" (r: Rect) -> int {
	return r.y + r.h / 2
}

// Nothing in it: no width or no height.
is_empty :: proc "contextless" (r: Rect) -> bool {
	return r.w <= 0 || r.h <= 0
}

contains :: proc "contextless" (r: Rect, px, py: int) -> bool {
	return px >= r.x && py >= r.y && px < r.x + r.w && py < r.y + r.h
}

// Is `inner` entirely inside `outer`?
contains_rect :: proc "contextless" (outer, inner: Rect) -> bool {
	return inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.w <= outer.x + outer.w && inner.y + inner.h <= outer.y + outer.h
}

overlaps :: proc "contextless" (a, b: Rect) -> bool {
	return !is_empty(a) && !is_empty(b) && a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// ---- moving and resizing ---------------------------------------------------------------------------

translate :: proc "contextless" (r: Rect, dx, dy: int) -> Rect {
	return Rect{r.x + dx, r.y + dy, r.w, r.h}
}

at :: proc "contextless" (r: Rect, x, y: int) -> Rect {
	return Rect{x, y, r.w, r.h}
}

with_size :: proc "contextless" (r: Rect, w, h: int) -> Rect {
	return Rect{r.x, r.y, w, h}
}

with_width :: proc "contextless" (r: Rect, w: int) -> Rect {
	return Rect{r.x, r.y, w, r.h}
}

with_height :: proc "contextless" (r: Rect, h: int) -> Rect {
	return Rect{r.x, r.y, r.w, h}
}

// ---- insets and padding ---------------------------------------------------------------------------------

// Shrinks by `d` on every side (the size never goes below zero; a rectangle that is too small collapses to its center).
inset :: proc "contextless" (r: Rect, d: int) -> Rect {
	return pad(r, Insets{d, d, d, d})
}

// Shrinks by dx on the left and right and dy at the top and bottom.
inset_xy :: proc "contextless" (r: Rect, dx, dy: int) -> Rect {
	return pad(r, Insets{dx, dy, dx, dy})
}

// Shrinks by a different amount on each side (padding).
pad :: proc "contextless" (r: Rect, p: Insets) -> Rect {
	x := r.x + p.left
	y := r.y + p.top
	w := r.w - p.left - p.right
	h := r.h - p.top - p.bottom
	if w < 0 {
		x += w / 2
		w = 0
	}
	if h < 0 {
		y += h / 2
		h = 0
	}
	return Rect{x, y, w, h}
}

// Grows by `d` on every side (the opposite of inset: a border, a margin, a shadow).
outset :: proc "contextless" (r: Rect, d: int) -> Rect {
	return Rect{r.x - d, r.y - d, r.w + 2 * d, r.h + 2 * d}
}

// Grows by a different amount on each side.
outset_by :: proc "contextless" (r: Rect, p: Insets) -> Rect {
	return Rect{r.x - p.left, r.y - p.top, r.w + p.left + p.right, r.h + p.top + p.bottom}
}

// ---- cutting pieces off ------------------------------------------------------------------------------
//
// Each takes a strip of the given size off one side and returns the strip and what is left. `gap` is a space that is
// left between the two (it is taken from what is left). A strip bigger than the rectangle is the whole rectangle,
// and what is left is empty.

cut_left :: proc "contextless" (r: Rect, amount: int, gap := 0) -> (cut, rest: Rect) {
	a := clamp(amount, 0, max(r.w, 0))
	g := clamp(gap, 0, max(r.w - a, 0))
	return Rect{r.x, r.y, a, r.h}, Rect{r.x + a + g, r.y, r.w - a - g, r.h}
}

cut_right :: proc "contextless" (r: Rect, amount: int, gap := 0) -> (cut, rest: Rect) {
	a := clamp(amount, 0, max(r.w, 0))
	g := clamp(gap, 0, max(r.w - a, 0))
	return Rect{r.x + r.w - a, r.y, a, r.h}, Rect{r.x, r.y, r.w - a - g, r.h}
}

cut_top :: proc "contextless" (r: Rect, amount: int, gap := 0) -> (cut, rest: Rect) {
	a := clamp(amount, 0, max(r.h, 0))
	g := clamp(gap, 0, max(r.h - a, 0))
	return Rect{r.x, r.y, r.w, a}, Rect{r.x, r.y + a + g, r.w, r.h - a - g}
}

cut_bottom :: proc "contextless" (r: Rect, amount: int, gap := 0) -> (cut, rest: Rect) {
	a := clamp(amount, 0, max(r.h, 0))
	g := clamp(gap, 0, max(r.h - a, 0))
	return Rect{r.x, r.y + r.h - a, r.w, a}, Rect{r.x, r.y, r.w, r.h - a - g}
}

cut :: proc "contextless" (r: Rect, side: Side, amount: int, gap := 0) -> (cut, rest: Rect) {
	switch side {
	case .Left:
		return cut_left(r, amount, gap)
	case .Right:
		return cut_right(r, amount, gap)
	case .Top:
		return cut_top(r, amount, gap)
	case .Bottom:
		return cut_bottom(r, amount, gap)
	}
	return {}, r
}

// Cuts off a fraction (0 .. 1) of the width or height instead of a fixed size.
cut_left_frac :: proc "contextless" (r: Rect, t: f32, gap := 0) -> (cut, rest: Rect) {
	return cut_left(r, int(f32(r.w) * clamp(t, 0, 1) + 0.5), gap)
}

cut_right_frac :: proc "contextless" (r: Rect, t: f32, gap := 0) -> (cut, rest: Rect) {
	return cut_right(r, int(f32(r.w) * clamp(t, 0, 1) + 0.5), gap)
}

cut_top_frac :: proc "contextless" (r: Rect, t: f32, gap := 0) -> (cut, rest: Rect) {
	return cut_top(r, int(f32(r.h) * clamp(t, 0, 1) + 0.5), gap)
}

cut_bottom_frac :: proc "contextless" (r: Rect, t: f32, gap := 0) -> (cut, rest: Rect) {
	return cut_bottom(r, int(f32(r.h) * clamp(t, 0, 1) + 0.5), gap)
}

// ---- dividing into equal parts ----------------------------------------------------------------------

// The `index`-th (from 0) of `count` columns side by side with `gap` between them. The columns together fill the width
// exactly (the odd pixels go to the first columns), so there are no cracks.
columns :: proc "contextless" (r: Rect, index, count: int, gap := 0) -> Rect {
	x, w := split_span(r.x, r.w, index, count, gap)
	return Rect{x, r.y, w, r.h}
}

// The `index`-th of `count` rows stacked with `gap` between them.
rows :: proc "contextless" (r: Rect, index, count: int, gap := 0) -> Rect {
	y, h := split_span(r.y, r.h, index, count, gap)
	return Rect{r.x, y, r.w, h}
}

// The cell at (`col`, `row`) of a grid of `cols` x `rows_n` cells.
grid_cell :: proc "contextless" (r: Rect, col, row, cols, rows_n: int, gap_x := 0, gap_y := 0) -> Rect {
	x, w := split_span(r.x, r.w, col, cols, gap_x)
	y, h := split_span(r.y, r.h, row, rows_n, gap_y)
	return Rect{x, y, w, h}
}

// Like `columns`, but the widths are in proportion to `weights` (1, 2, 1: the middle one twice as wide).
weighted_columns :: proc "contextless" (r: Rect, weights: []int, index: int, gap := 0) -> Rect {
	x, w := weighted_span(r.x, r.w, weights, index, gap)
	return Rect{x, r.y, w, r.h}
}

weighted_rows :: proc "contextless" (r: Rect, weights: []int, index: int, gap := 0) -> Rect {
	y, h := weighted_span(r.y, r.h, weights, index, gap)
	return Rect{r.x, y, r.w, h}
}

// The `index`-th item of a column of items of a fixed height (a list of rows, a palette): the first is at the top
// of `r`, and each is `gap` below the one before. Its width is the width of `r`.
row_at :: proc "contextless" (r: Rect, index, item_h: int, gap := 0) -> Rect {
	return Rect{r.x, r.y + index * (item_h + gap), r.w, item_h}
}

// The same side by side: items of a fixed width starting at the left of `r`.
column_at :: proc "contextless" (r: Rect, index, item_w: int, gap := 0) -> Rect {
	return Rect{r.x + index * (item_w + gap), r.y, item_w, r.h}
}

// How many items of `item` size (and `gap` between them) fit in `room`.
fit_count :: proc "contextless" (room, item: int, gap := 0) -> int {
	if item <= 0 {
		return 0
	}
	return max((room + gap) / (item + gap), 0)
}

@(private)
split_span :: proc "contextless" (start, length, index, count, gap: int) -> (pos, size: int) {
	if count <= 0 {
		return start, 0
	}
	i := clamp(index, 0, count - 1)
	space := max(length - gap * (count - 1), 0)
	base := space / count
	extra := space % count // the first `extra` parts are one wider
	pos = start + i * (base + gap) + min(i, extra)
	size = base + (1 if i < extra else 0)
	return
}

@(private)
weighted_span :: proc "contextless" (start, length: int, weights: []int, index, gap: int) -> (pos, size: int) {
	n := len(weights)
	if n == 0 {
		return start, 0
	}
	i := clamp(index, 0, n - 1)
	total := 0
	for w in weights {
		total += max(w, 0)
	}
	space := max(length - gap * (n - 1), 0)
	if total <= 0 {
		return start, 0
	}
	before := 0
	for k in 0 ..< i {
		before += max(weights[k], 0)
	}
	// the edges are rounded as positions, so the parts add up to the whole
	edge0 := space * before / total
	edge1 := space * (before + max(weights[i], 0)) / total
	return start + edge0 + i * gap, edge1 - edge0
}

// ---- placing a box inside another ------------------------------------------------------------------------

// A box of the size w x h inside `outer`, placed by the alignments (a box larger than `outer` overhangs evenly for
// Center, and on the end side for Start / End).
place :: proc "contextless" (outer: Rect, w, h: int, horizontal: Align = .Center, vertical: Align = .Center) -> Rect {
	return Rect{align_pos(outer.x, outer.w, w, horizontal), align_pos(outer.y, outer.h, h, vertical), w, h}
}

// The middle of `outer`.
center :: proc "contextless" (outer: Rect, w, h: int) -> Rect {
	return place(outer, w, h, .Center, .Center)
}

// `inner` (its size) moved inside `outer` by the alignments.
align :: proc "contextless" (outer, inner: Rect, horizontal: Align = .Center, vertical: Align = .Center) -> Rect {
	return place(outer, inner.w, inner.h, horizontal, vertical)
}

// The largest rectangle of the shape aw : ah that fits inside `outer` (a picture that must not be squeezed), placed by
// the alignments.
fit_aspect :: proc "contextless" (outer: Rect, aw, ah: int, horizontal: Align = .Center, vertical: Align = .Center) -> Rect {
	if aw <= 0 || ah <= 0 || is_empty(outer) {
		return place(outer, 0, 0, horizontal, vertical)
	}
	w := outer.w
	h := w * ah / aw
	if h > outer.h {
		h = outer.h
		w = h * aw / ah
	}
	return place(outer, w, h, horizontal, vertical)
}

// The smallest rectangle of the shape aw : ah that covers `outer` entirely (it overhangs on one axis), centered.
fill_aspect :: proc "contextless" (outer: Rect, aw, ah: int) -> Rect {
	if aw <= 0 || ah <= 0 || is_empty(outer) {
		return outer
	}
	w := outer.w
	h := w * ah / aw
	if h < outer.h {
		h = outer.h
		w = h * aw / ah
	}
	return place(outer, w, h, .Center, .Center)
}

@(private)
align_pos :: proc "contextless" (start, length, size: int, a: Align) -> int {
	switch a {
	case .Start:
		return start
	case .Center:
		return start + (length - size) / 2
	case .End:
		return start + length - size
	}
	return start
}

// ---- combining ---------------------------------------------------------------------------------------

// The part two rectangles share (empty, at the corner of `b`, if they share none).
intersect :: proc "contextless" (a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	if x1 <= x0 || y1 <= y0 {
		return Rect{x0, y0, 0, 0}
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

// The smallest rectangle that holds both (an empty one does not count). (Not called "union": that is a keyword.)
bounding :: proc "contextless" (a, b: Rect) -> Rect {
	if is_empty(a) {
		return b
	}
	if is_empty(b) {
		return a
	}
	x0 := min(a.x, b.x)
	y0 := min(a.y, b.y)
	x1 := max(a.x + a.w, b.x + b.w)
	y1 := max(a.y + a.h, b.y + b.h)
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

// `r` pushed inside `bounds` (a popup, a tooltip that must stay on the screen), and made smaller if it is larger than `bounds`.
keep_inside :: proc "contextless" (r, bounds: Rect) -> Rect {
	w := min(r.w, bounds.w)
	h := min(r.h, bounds.h)
	x := clamp(r.x, bounds.x, bounds.x + bounds.w - w)
	y := clamp(r.y, bounds.y, bounds.y + bounds.h - h)
	return Rect{x, y, w, h}
}

// A popup of w x h next to `anchor` (a menu under its button, a tooltip by a widget), on the preferred side if there is room
// for it inside `bounds` and on the opposite side if not, then kept inside `bounds`. `gap` is left between
// the two.
popup :: proc "contextless" (anchor: Rect, w, h: int, bounds: Rect, side: Side = .Bottom, gap := 0) -> Rect {
	try :: proc "contextless" (anchor: Rect, w, h: int, side: Side, gap: int) -> Rect {
		switch side {
		case .Bottom:
			return Rect{anchor.x, anchor.y + anchor.h + gap, w, h}
		case .Top:
			return Rect{anchor.x, anchor.y - h - gap, w, h}
		case .Right:
			return Rect{anchor.x + anchor.w + gap, anchor.y, w, h}
		case .Left:
			return Rect{anchor.x - w - gap, anchor.y, w, h}
		}
		return Rect{anchor.x, anchor.y, w, h}
	}
	opposite := [Side]Side {
		.Left   = .Right,
		.Right  = .Left,
		.Top    = .Bottom,
		.Bottom = .Top,
	}
	r := try(anchor, w, h, side, gap)
	if !contains_rect(bounds, r) {
		o := try(anchor, w, h, opposite[side], gap)
		if contains_rect(bounds, o) {
			r = o
		}
	}
	return keep_inside(r, bounds)
}

// ---- bars and thumbs ---------------------------------------------------------------------------------

// The handle of a scroll bar: where it is on `track` for a view that shows `view` of `content` units, scrolled `offset`
// units from the start. It is never shorter than `min_len`. `vertical` says which way the bar runs.
thumb :: proc "contextless" (track: Rect, content, view, offset: int, vertical := true, min_len := 12) -> Rect {
	length := track.h if vertical else track.w
	if content <= 0 || view >= content || length <= 0 {
		return track // nothing to scroll: the handle fills the track
	}
	size := clamp(length * view / content, min(min_len, length), length)
	room := length - size
	scroll_range := content - view
	pos := room * clamp(offset, 0, scroll_range) / scroll_range
	if vertical {
		return Rect{track.x, track.y + pos, track.w, size}
	}
	return Rect{track.x + pos, track.y, size, track.h}
}

// The scroll offset (units of content) that puts the handle's start at the position `at` (an x or y on the screen) along
// the track: what dragging a thumb does. `grab` is how far inside the handle the pointer took hold of it.
thumb_offset :: proc "contextless" (track: Rect, content, view: int, at: int, grab := 0, vertical := true, min_len := 12) -> int {
	length := track.h if vertical else track.w
	if content <= view || length <= 0 {
		return 0
	}
	size := clamp(length * view / content, min(min_len, length), length)
	room := length - size
	if room <= 0 {
		return 0
	}
	start := track.y if vertical else track.x
	p := clamp(at - grab - start, 0, room)
	return (content - view) * p / room
}

// The filled part of a bar (a progress bar, a slider's fill): `t` from 0 to 1 of the track from its start.
fill :: proc "contextless" (track: Rect, t: f32, vertical := false) -> Rect {
	k := clamp(t, 0, 1)
	if vertical {
		h := int(f32(track.h) * k + 0.5)
		return Rect{track.x, track.y + track.h - h, track.w, h} // fills upwards
	}
	return Rect{track.x, track.y, int(f32(track.w) * k + 0.5), track.h}
}

// A square handle centered at `t` (0 .. 1) along the track: where a slider's knob is.
knob :: proc "contextless" (track: Rect, t: f32, size: int, vertical := false) -> Rect {
	k := clamp(t, 0, 1)
	if vertical {
		return Rect{track.x + (track.w - size) / 2, track.y + int(f32(track.h - size) * (1 - k) + 0.5), size, size}
	}
	return Rect{track.x + int(f32(track.w - size) * k + 0.5), track.y + (track.h - size) / 2, size, size}
}

// Where along the track (0 .. 1) the position (`px` along the axis) is: what a click or a drag on a slider gives.
track_position :: proc "contextless" (track: Rect, px: int, vertical := false) -> f32 {
	if vertical {
		if track.h <= 0 {
			return 0
		}
		return clamp(1 - f32(px - track.y) / f32(track.h), 0, 1)
	}
	if track.w <= 0 {
		return 0
	}
	return clamp(f32(px - track.x) / f32(track.w), 0, 1)
}
