package iv_debug

import ren "../iv_system/ren"
import text "../iv_text"
import ui "../iv_ui"

// ---------------------------------------------------------------------------
// Windows and the layout of what is in them: widgets go one under the other, each as wide as the window's contents; `row` puts the next few side by side.
// ---------------------------------------------------------------------------

// Starts a window and returns whether to put its contents in (false: it is collapsed or closed). Always call end_window after it. `rect` is where
// the window is the first time (after that it is wherever the user has moved it); `open`, if given, is the "shown" flag that the close button (Closable)
// clears.
window :: proc(ctx: ^Context, title: string, rect := ui.Rect{40, 40, 320, 360}, flags := Window_Flags{}, open: ^bool = nil) -> bool {
	id := make_id(ctx, title)
	w, exists := &ctx.windows[id]
	if !exists {
		fresh := Window {
			rect = rect,
		}
		ren.draw_list_init(&fresh.dl, ctx.allocator)
		ctx.z_counter += 1
		fresh.z = ctx.z_counter
		ctx.windows[id] = fresh
		w = &ctx.windows[id]
	}
	ctx.cur, ctx.cur_id = nil, 0
	ctx.dl = &ctx.overlay
	if open != nil && !open^ {
		return false
	}
	w.used = true
	w.flags = flags
	append(&ctx.order, id)
	ctx.cur, ctx.cur_id = w, id
	ren.draw_list_reset(&w.dl, ctx.screen.x, ctx.screen.y)
	ctx.dl = &w.dl
	ctx.in_overlay = false
	push_id(ctx, title)

	t := ctx.theme
	pad := t.pad
	title_h := 0 if .No_Title in flags else row_h(ctx) + 2
	if .Auto_Height in flags && !w.collapsed {
		w.rect.h = clamp(title_h + w.content_h + 2 * pad, title_h + 24, max(ctx.screen.y - w.rect.y, title_h + 24))
	}
	w.rect.w = max(w.rect.w, 90)
	w.rect.h = max(w.rect.h, title_h + 24)
	shown_h := title_h if w.collapsed && title_h > 0 else w.rect.h
	w.shown = {w.rect.x, w.rect.y, w.rect.w, shown_h}
	is_front := w.z == ctx.z_counter

	// the body and the frame
	fill(ctx, w.shown, t.window)
	outline(ctx, w.shown, t.border)

	// the title bar: collapse arrow, title, close button; a drag on the rest moves the window
	if title_h > 0 {
		bar := ui.Rect{w.rect.x, w.rect.y, w.rect.w, title_h}
		fill(ctx, bar, t.title_active if is_front else t.title)
		arrow := ui.Rect{bar.x, bar.y, title_h, title_h}
		ab := behavior(ctx, make_id(ctx, "##collapse"), arrow, true)
		if ab.clicked {
			w.collapsed = !w.collapsed
		}
		triangle(ctx, arrow, w.collapsed, t.title_text)
		right := bar.x + bar.w
		if .Closable in flags && open != nil {
			x := ui.Rect{bar.x + bar.w - title_h, bar.y, title_h, title_h}
			xb := behavior(ctx, make_id(ctx, "##close"), x, true)
			fill(ctx, x, t.widget_active if xb.held else (t.widget_hover if xb.hovered else with_alpha(t.widget, 0)))
			put_text_in(ctx, "x", x, t.title_text, .Center)
			if xb.clicked {
				open^ = false
			}
			right = x.x
		}
		label := ui.Rect{bar.x + title_h, bar.y, right - bar.x - title_h, title_h}
		put_text_in(ctx, shown_label(title), label, t.title_text)
		if .No_Move not_in flags {
			mid := make_id(ctx, "##move")
			mb := behavior(ctx, mid, label, true)
			if mb.pressed {
				w.grab = {int(ctx.input.mouse.x) - w.rect.x, int(ctx.input.mouse.y) - w.rect.y}
			}
			if mb.held {
				w.rect.x = clamp(int(ctx.input.mouse.x) - w.grab.x, 40 - w.rect.w, ctx.screen.x - 40)
				w.rect.y = clamp(int(ctx.input.mouse.y) - w.grab.y, 0, max(ctx.screen.y - title_h, 0))
				w.shown.x, w.shown.y = w.rect.x, w.rect.y
			}
		}
	}
	if w.collapsed && title_h > 0 {
		ctx.layout = {}
		return false
	}

	// the contents
	body := ui.Rect{w.rect.x, w.rect.y + title_h, w.rect.w, w.rect.h - title_h}
	content := ui.inset(body, pad)
	if w.content_h > content.h && .No_Scroll not_in flags {
		content.w -= t.scroll_w + 2
	}
	ctx.layout = Layout {
		content = content,
		x       = content.x,
		width   = content.w,
		y       = content.y - w.scroll,
		start_y = content.y - w.scroll,
		row_h   = row_h(ctx),
	}
	ren.push_clip(ctx.dl, content)

	// the grip that resizes it (drawn at the end of the window, over the contents; the drag is taken care of here)
	if .No_Resize not_in flags {
		grip := ui.Rect{w.rect.x + w.rect.w - 14, w.rect.y + w.rect.h - 14, 14, 14}
		gid := make_id(ctx, "##resize")
		gb := behavior(ctx, gid, grip, true)
		if gb.pressed {
			w.grab = {w.rect.x + w.rect.w - int(ctx.input.mouse.x), w.rect.y + w.rect.h - int(ctx.input.mouse.y)}
		}
		if gb.held {
			w.rect.w = max(int(ctx.input.mouse.x) + w.grab.x - w.rect.x, 120)
			if .Auto_Height not_in flags {
				w.rect.h = max(int(ctx.input.mouse.y) + w.grab.y - w.rect.y, title_h + 40)
			}
		}
	}
	return true
}

// Ends the window that window() began (call it whether window() returned true or false).
end_window :: proc(ctx: ^Context) {
	w := ctx.cur
	if w == nil {
		ctx.dl = &ctx.overlay
		return
	}
	flags := w.flags
	t := ctx.theme
	if !(w.collapsed && .No_Title not_in flags) && ctx.layout.content.w > 0 {
		end_row(ctx)
		ren.pop_clip(ctx.dl)
		l := &ctx.layout
		w.content_h = max(l.y - l.start_y, 0) + 0
		view := l.content.h
		max_scroll := max(w.content_h - view, 0)
		if ctx.mouse_window == ctx.cur_id && ctx.input.wheel != 0 && .No_Scroll not_in flags && ctx.modal == 0 {
			w.scroll -= int(ctx.input.wheel * f32(row_h(ctx) * 3))
			ctx.input.wheel = 0
		}
		w.scroll = clamp(w.scroll, 0, max_scroll)
		if max_scroll > 0 && .No_Scroll not_in flags {
			track := ui.Rect{w.rect.x + w.rect.w - t.scroll_w - 2, l.content.y, t.scroll_w, view}
			thumb := ui.thumb(track, w.content_h, view, w.scroll, true, 14)
			sid := make_id(ctx, "##scroll")
			sb := behavior(ctx, sid, track, true)
			if sb.pressed {
				ctx.drag.origin_x = f32(int(ctx.input.mouse.y) - thumb.y) if ui.contains(thumb, int(ctx.input.mouse.x), int(ctx.input.mouse.y)) else f32(thumb.h / 2)
			}
			if sb.held {
				w.scroll = clamp(ui.thumb_offset(track, w.content_h, view, int(ctx.input.mouse.y), int(ctx.drag.origin_x), true, 14), 0, max_scroll)
				thumb = ui.thumb(track, w.content_h, view, w.scroll, true, 14)
			}
			fill(ctx, thumb, t.scroll_hover if sb.hovered || sb.held else t.scroll)
		}
		if w.rect.w > 0 && .No_Resize not_in flags {
			g := ui.Rect{w.rect.x + w.rect.w - 12, w.rect.y + w.rect.h - 12, 10, 10}
			ren.draw_triangle(ctx.dl, {f32(g.x + g.w), f32(g.y)}, {f32(g.x + g.w), f32(g.y + g.h)}, {f32(g.x), f32(g.y + g.h)}, t.text_dim)
		}
	}
	pop_id(ctx)
	ctx.cur, ctx.cur_id = nil, 0
	ctx.dl = &ctx.overlay
}

// A small triangle in a square: pointing right (closed) or down (open).
@(private)
triangle :: proc(ctx: ^Context, r: ui.Rect, closed: bool, c: ren.Color) {
	s := min(r.w, r.h) / 3
	cx, cy := f32(r.x + r.w / 2), f32(r.y + r.h / 2)
	h := f32(s)
	if closed {
		ren.draw_triangle(ctx.dl, {cx - h / 2, cy - h}, {cx - h / 2, cy + h}, {cx + h, cy}, c)
	} else {
		ren.draw_triangle(ctx.dl, {cx - h, cy - h / 2}, {cx + h, cy - h / 2}, {cx, cy + h}, c)
	}
}

// ---- layout ------------------------------------------------------------------------------------------------------------------------

// The place of the next widget: as wide as the contents (or, in a row, its cell), `h` high (0: a row's height). Widgets call this; so can code that
// draws a widget of its own.
next_rect :: proc(ctx: ^Context, h := 0) -> ui.Rect {
	l := &ctx.layout
	height := h if h > 0 else l.row_h
	if l.cells > 0 {
		r := ui.columns(ui.Rect{l.x, l.row_y, l.width, l.row_h}, l.cell, l.cells, ctx.theme.spacing)
		l.cell += 1
		if l.cell >= l.cells {
			end_row(ctx)
		}
		l.last_rect = r
		return r
	}
	r := ui.Rect{l.x, l.y, l.width, height}
	l.y += height + ctx.theme.spacing
	l.last_rect = r
	return r
}

// The next `cells` widgets share one line, side by side, equally wide. (A row left short is closed by the next one or by end_window.)
row :: proc(ctx: ^Context, cells: int) {
	end_row(ctx)
	l := &ctx.layout
	l.cells = max(cells, 1)
	l.cell = 0
	l.row_y = l.y
	l.row_h = row_h(ctx)
}

// Closes a row that has fewer widgets than it was given cells for (the next widget goes under it).
end_row :: proc(ctx: ^Context) {
	l := &ctx.layout
	if l.cells > 0 {
		l.cells = 0
		l.y = l.row_y + l.row_h + ctx.theme.spacing
	}
}

in_row :: proc(ctx: ^Context) -> bool {
	return ctx.layout.cells > 0
}

// Moves the widgets to the right by one level (tree nodes do this themselves).
indent :: proc(ctx: ^Context, levels := 1) {
	end_row(ctx)
	d := ctx.theme.indent * levels
	ctx.layout.x += d
	ctx.layout.width -= d
	ctx.layout.indent += levels
}

unindent :: proc(ctx: ^Context, levels := 1) {
	end_row(ctx)
	d := ctx.theme.indent * levels
	ctx.layout.x -= d
	ctx.layout.width += d
	ctx.layout.indent -= levels
}

// Empty space of `px` px (0: a normal gap).
spacing :: proc(ctx: ^Context, px := 0) {
	end_row(ctx)
	ctx.layout.y += px if px > 0 else ctx.theme.spacing * 2
}

separator :: proc(ctx: ^Context) {
	end_row(ctx)
	l := &ctx.layout
	y := l.y + 2
	fill(ctx, {l.x, y, l.width, 1}, ctx.theme.border)
	l.y += 5 + ctx.theme.spacing
}

// What a labelled widget gives back: the rect for the widget itself, with the label drawn at its left (outside a row; in a row the whole cell is the
// widget's and the label is not shown). An empty label, or one that starts with "##", has no label column.
property :: proc(ctx: ^Context, label: string, id: ID) -> ui.Rect {
	r := ctx.layout
	was_row := r.cells > 0
	rect := next_rect(ctx)
	shown := shown_label(label)
	if was_row || len(shown) == 0 {
		if ctx.track_rects && id != 0 {
			ctx.rects[id] = rect
		}
		return rect
	}
	lw := clamp(int(f32(rect.w) * ctx.theme.label_ratio), ctx.theme.min_label_w, rect.w / 2)
	lab, field := ui.cut_left(rect, lw, ctx.theme.spacing)
	put_text_in(ctx, shown, lab, ctx.theme.text)
	if ctx.track_rects && id != 0 {
		ctx.rects[id] = field
	}
	return field
}

// ---- text --------------------------------------------------------------------------------------------------------------------------

// A line of text.
label :: proc(ctx: ^Context, s: string, color := ren.Color{}) {
	r := next_rect(ctx)
	put_text_in(ctx, s, r, color if color.a != 0 else ctx.theme.text)
}

// A line of dimmed text.
label_dim :: proc(ctx: ^Context, s: string) {
	label(ctx, s, ctx.theme.text_dim)
}

// Text wrapped to the width of the contents, as many lines as it takes.
text_wrapped :: proc(ctx: ^Context, s: string, color := ren.Color{}) {
	end_row(ctx)
	l := &ctx.layout
	lines := text.wrap(ctx.tf, s, l.width, ctx.size)
	c := color if color.a != 0 else ctx.theme.text
	for line in lines {
		r := ui.Rect{l.x, l.y, l.width, line_h(ctx)}
		put_text_in(ctx, line, r, c)
		l.y += line_h(ctx)
	}
	l.y += ctx.theme.spacing
}

// A name and a value, both just shown: `value` is dimmed.
label_value :: proc(ctx: ^Context, name, value: string) {
	field := property(ctx, name, 0)
	put_text_in(ctx, value, field, ctx.theme.text_dim)
}
