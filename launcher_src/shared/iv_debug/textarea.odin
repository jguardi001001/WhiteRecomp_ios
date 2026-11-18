package iv_debug

import "core:strings"
import text "../iv_text"
import ren "../iv_system/ren"
import ui "../iv_ui"

// ---------------------------------------------------------------------------
// A text of several lines. It wraps to the width of its box; Enter makes a new line (Ctrl+Enter, Escape or a click elsewhere end the edit); Up and
// Down move between the wrapped lines; the wheel scrolls.
// ---------------------------------------------------------------------------

// The index of the line (of wrap_ranges) that byte place `c` is in: the last line that starts at or before it.
@(private)
line_of_byte :: proc(ranges: [][2]int, c: int) -> int {
	at := 0
	for r, i in ranges {
		if r[0] <= c {
			at = i
		} else {
			break
		}
	}
	return at
}

// Runs the area `id` being edited (edit_begin) in `r`: the mouse, the keys, drawing.
edit_area :: proc(ctx: ^Context, id: ID, r: ui.Rect) -> (res: Edit_Result) {
	e := &ctx.edit
	if e.id != id {
		return
	}
	e.seen = true
	t := ctx.theme
	inp := ctx.input
	area := ui.inset_xy(r, 4, 3)
	area.w -= 7 // (room for the scroll bar)
	lh := line_h(ctx)
	visible := max(area.h / lh, 1)
	mx, my := int(inp.mouse.x), int(inp.mouse.y)
	before := len(e.buf)
	str := string(e.buf[:])
	ranges := text.wrap_ranges(ctx.tf, str, area.w, ctx.size)

	at_point :: proc(ctx: ^Context, str: string, ranges: [][2]int, area: ui.Rect, lh: int, first: int, p: [2]f32) -> int {
		line := clamp(first + (int(p.y) - area.y) / lh, 0, len(ranges) - 1)
		start, end := ranges[line][0], ranges[line][1]
		return start + text.byte_near(ctx.tf, str[start:end], p.x - f32(area.x), ctx.size)
	}

	// the mouse
	if ui.contains(r, mx, my) && inp.wheel != 0 {
		e.scroll_line -= int(inp.wheel) * 2
		ctx.input.wheel = 0
	}
	if inp.pressed[.Left] {
		if ui.contains(r, mx, my) {
			e.cursor = at_point(ctx, str, ranges, area, lh, e.scroll_line, inp.mouse)
			if !inp.shift {
				e.anchor = e.cursor
			}
			e.moved = ctx.time
		} else {
			res.committed = true
			return
		}
	} else if ctx.active == id && inp.down[.Left] {
		e.cursor = at_point(ctx, str, ranges, area, lh, e.scroll_line, inp.mouse)
		e.moved = ctx.time
	}

	// the keys that move between lines
	skip: Keys
	cur_line := line_of_byte(ranges, e.cursor)
	x_in_line := text.width_f(ctx.tf, str[ranges[cur_line][0]:min(e.cursor, len(str))], ctx.size)
	if .Up in inp.keys {
		skip += {.Up}
		if cur_line > 0 {
			ln := ranges[cur_line - 1]
			edit_move(e, ln[0] + text.byte_near(ctx.tf, str[ln[0]:ln[1]], x_in_line, ctx.size), inp.shift, ctx.time)
		} else {
			edit_move(e, 0, inp.shift, ctx.time)
		}
	}
	if .Down in inp.keys {
		skip += {.Down}
		if cur_line + 1 < len(ranges) {
			ln := ranges[cur_line + 1]
			edit_move(e, ln[0] + text.byte_near(ctx.tf, str[ln[0]:ln[1]], x_in_line, ctx.size), inp.shift, ctx.time)
		} else {
			edit_move(e, len(str), inp.shift, ctx.time)
		}
	}
	if .Home in inp.keys {
		skip += {.Home}
		edit_move(e, ranges[cur_line][0], inp.shift, ctx.time)
	}
	if .End in inp.keys {
		skip += {.End}
		edit_move(e, ranges[cur_line][1], inp.shift, ctx.time)
	}
	kr := edit_keys(ctx, true, skip)
	res.committed = kr.committed
	res.cancelled = kr.cancelled
	res.changed = len(e.buf) != before

	// the text may have changed: wrap again and keep the caret in view
	str = string(e.buf[:])
	ranges = text.wrap_ranges(ctx.tf, str, area.w, ctx.size)
	e.cursor = clamp(e.cursor, 0, len(str))
	e.anchor = clamp(e.anchor, 0, len(str))
	cur_line = line_of_byte(ranges, e.cursor)
	if cur_line < e.scroll_line {
		e.scroll_line = cur_line
	}
	if cur_line >= e.scroll_line + visible {
		e.scroll_line = cur_line - visible + 1
	}
	e.scroll_line = clamp(e.scroll_line, 0, max(len(ranges) - visible, 0))

	// draw
	fill(ctx, r, t.field)
	outline(ctx, r, t.accent)
	ren.push_clip(ctx.dl, ui.inset(r, 1))
	lo, hi := sel_range(e)
	for row in 0 ..< visible {
		i := e.scroll_line + row
		if i >= len(ranges) {
			break
		}
		start, end := ranges[i][0], ranges[i][1]
		y := area.y + row * lh
		if hi > lo && hi > start && lo <= end {
			a := max(lo, start)
			b := min(hi, end)
			x0 := text.width_f(ctx.tf, str[start:a], ctx.size)
			x1 := text.width_f(ctx.tf, str[start:b], ctx.size)
			if hi > end { // the selection goes on to the next line: it shows a little past the end
				x1 += 4
			}
			fill(ctx, {area.x + int(x0), y, max(int(x1 - x0), 1), lh}, t.selection)
		}
		text.draw(ctx.dl, ctx.tf, str[start:end], {area.x, y}, ctx.size, t.text)
	}
	since := ctx.time - e.moved
	if (since < 0.5 || int(since * 2) % 2 == 0) && cur_line >= e.scroll_line && cur_line < e.scroll_line + visible {
		start := ranges[cur_line][0]
		cx := text.width_f(ctx.tf, str[start:e.cursor], ctx.size)
		fill(ctx, {area.x + int(cx), area.y + (cur_line - e.scroll_line) * lh, 1, lh}, t.accent)
	}
	if len(ranges) > visible {
		track := ui.Rect{r.x + r.w - 7, r.y + 2, 5, r.h - 4}
		fill(ctx, ui.thumb(track, len(ranges), visible, e.scroll_line, true, 8), t.scroll)
	}
	ren.pop_clip(ctx.dl)
	return
}

// A text of several lines in a box `rows` lines high, with its label (if it shows) above. The string is changed as it is typed (see input_string for how
// the new strings are made and freed). True when it changed.
input_multiline :: proc(ctx: ^Context, label: string, s: ^string, rows := 5) -> (changed: bool) {
	t := ctx.theme
	id := make_id(ctx, label)
	if len(shown_label(label)) > 0 {
		self_label(ctx, shown_label(label))
	}
	r := next_rect(ctx, rows * line_h(ctx) + 8)
	b := behavior(ctx, id, r)
	if b.pressed && ctx.edit.id != id {
		if ctx.edit.id != 0 {
			edit_end(ctx)
		}
		edit_begin(ctx, id, s^, select_all = false)
		ctx.edit.scroll_line = 0
	}
	if ctx.edit.id == id {
		res := edit_area(ctx, id, r)
		if res.changed {
			e := &ctx.edit
			fresh := strings.clone(string(e.buf[:]), ctx.string_allocator)
			if e.owned != nil && rawptr(raw_data(s^)) == e.owned {
				delete(s^, ctx.string_allocator)
			}
			s^ = fresh
			e.owned = rawptr(raw_data(fresh)) if len(fresh) > 0 else nil
			changed = true
		}
		if res.committed || res.cancelled {
			edit_end(ctx)
		}
		return
	}
	// not edited: the wrapped text, scrolled by the wheel
	fill(ctx, r, t.widget_hover if b.hovered else t.field)
	outline(ctx, r, t.border)
	area := ui.inset_xy(r, 4, 3)
	area.w -= 7
	lh := line_h(ctx)
	visible := max(area.h / lh, 1)
	lines := text.wrap(ctx.tf, s^, area.w, ctx.size)
	first := ctx.scrolls[id]
	if b.hovered && ctx.input.wheel != 0 {
		first -= int(ctx.input.wheel) * 2
		ctx.input.wheel = 0
	}
	first = clamp(first, 0, max(len(lines) - visible, 0))
	ctx.scrolls[id] = first
	ren.push_clip(ctx.dl, ui.inset(r, 1))
	for row in 0 ..< visible {
		i := first + row
		if i >= len(lines) {
			break
		}
		text.draw(ctx.dl, ctx.tf, lines[i], {area.x, area.y + row * lh}, ctx.size, t.text)
	}
	if len(lines) > visible {
		track := ui.Rect{r.x + r.w - 7, r.y + 2, 5, r.h - 4}
		fill(ctx, ui.thumb(track, len(lines), visible, first, true, 8), t.scroll)
	}
	ren.pop_clip(ctx.dl)
	return
}
