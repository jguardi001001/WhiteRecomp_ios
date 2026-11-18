package iv_debug

import "core:strings"
import ren "../iv_system/ren"
import ui "../iv_ui"

// ---------------------------------------------------------------------------
// Lists, drop-downs with a search field, tabs, toggles. Their rows can be drawn by the program (a picture and a name, an indented heading): a Row_Draw
// is called for each row that shows.
// ---------------------------------------------------------------------------

// Draws row `index` of a list or a drop-down in `r` (clipped to it). `selected` is the chosen row; `hovered` the one under the mouse. Called with
// hovered = false for the closed face of a drop-down.
Row_Draw :: #type proc(ctx: ^Context, r: ui.Rect, index: int, hovered, selected: bool, user: rawptr)

Dropdown_Opts :: struct {
	filter:      bool, // a search field at the top of the open list: only the items that contain what is typed show
	placeholder: string, // shown in the closed field when nothing is chosen (index < 0)
	row_h:       int, // the height of a row (0: the usual)
	max_rows:    int, // rows shown at once (0: 14)
	draw_row:    Row_Draw, // draws an item (nil: its text)
	user:        rawptr, // given to draw_row
}

// A drop-down list: shows the chosen item; a click opens the list over the other widgets. Returns true when the choice changed.
dropdown :: proc(ctx: ^Context, label: string, items: []string, index: ^int) -> bool {
	return dropdown_ex(ctx, label, items, index, {})
}

dropdown_ex :: proc(ctx: ^Context, label: string, items: []string, index: ^int, opts: Dropdown_Opts) -> (changed: bool) {
	id := make_id(ctx, label)
	field := property(ctx, label, id)
	t := ctx.theme
	b := behavior(ctx, id, field)
	open := ctx.modal == id
	rh := opts.row_h if opts.row_h > 0 else row_h(ctx)
	fill(ctx, field, t.widget_active if open else (t.widget_hover if b.hovered else t.widget))
	outline(ctx, field, t.border)
	face := ui.Rect{field.x + 1, field.y, field.w - field.h, field.h}
	if index^ >= 0 && index^ < len(items) {
		if opts.draw_row != nil {
			ren.push_clip(ctx.dl, face)
			opts.draw_row(ctx, face, index^, false, true, opts.user)
			ren.pop_clip(ctx.dl)
		} else {
			put_text_in(ctx, items[index^], ui.inset_xy(field, t.pad, 0), t.text)
		}
	} else {
		put_text_in(ctx, opts.placeholder, ui.inset_xy(field, t.pad, 0), t.text_dim)
	}
	triangle(ctx, {field.x + field.w - field.h, field.y, field.h, field.h}, false, t.text_dim)
	fid := id ~ 0x9E3779B9
	if b.clicked && !open {
		ctx.modal = id
		ctx.modal_close = false
		open = true
		if opts.filter {
			if ctx.edit.id != 0 {
				edit_end(ctx)
			}
			edit_begin(ctx, fid, "", select_all = false)
		}
	}
	if !open {
		return
	}
	ctx.modal_seen = true

	// which items show
	matches := make([dynamic]int, context.temp_allocator)
	needle := ""
	if opts.filter && ctx.edit.id == fid {
		needle = strings.to_lower(edit_string(ctx), context.temp_allocator)
	}
	for item, i in items {
		if len(needle) == 0 || strings.contains(strings.to_lower(item, context.temp_allocator), needle) {
			append(&matches, i)
		}
	}
	max_rows := opts.max_rows if opts.max_rows > 0 else 14
	rows := min(len(matches), max_rows)
	head := (rh + 4) if opts.filter else 0
	ph := rows * rh + 2 + head
	popup := ui.Rect{field.x, field.y + field.h + 1, field.w, ph}
	if popup.y + popup.h > ctx.screen.y && field.y - 1 - ph >= 0 {
		popup.y = field.y - 1 - ph
	}
	popup.w = max(popup.w, 60)
	ctx.popup_rect = popup
	ctx.popup_seen = true

	// the popup is drawn in the overlay and answers the mouse wherever it is
	saved_dl, saved_in := ctx.dl, ctx.in_overlay
	ctx.dl, ctx.in_overlay = &ctx.overlay, true
	defer {ctx.dl, ctx.in_overlay = saved_dl, saved_in}
	closing := false
	mx, my := int(ctx.input.mouse.x), int(ctx.input.mouse.y)
	scroll := ctx.scrolls[id]
	max_scroll := max(len(matches) - rows, 0)
	if ui.contains(popup, mx, my) && ctx.input.wheel != 0 {
		scroll = clamp(scroll - int(ctx.input.wheel), 0, max_scroll)
		ctx.input.wheel = 0
	}
	scroll = clamp(scroll, 0, max_scroll)
	ctx.scrolls[id] = scroll
	fill(ctx, popup, t.field)
	outline(ctx, popup, t.accent)
	pressed_outside := ctx.input.pressed[.Left] && !ui.contains(popup, mx, my)
	if opts.filter {
		fr := ui.Rect{popup.x + 2, popup.y + 2, popup.w - 4, rh}
		if ctx.edit.id == fid {
			res := edit_field(ctx, fid, fr)
			if .Enter in ctx.input.keys && len(matches) > 0 {
				if matches[0] != index^ {
					index^ = matches[0]
					changed = true
				}
				closing = true
			}
			if res.cancelled {
				closing = true
			}
		}
		if len(matches) == 0 {
			put_text_in(ctx, "(nothing matches)", {popup.x + 4, popup.y + head, popup.w - 8, rh}, t.text_dim)
		}
	}
	for row in 0 ..< rows {
		i := matches[row + scroll]
		item := ui.Rect{popup.x + 1, popup.y + 1 + head + row * rh, popup.w - 2, rh}
		hovered := ui.contains(item, mx, my)
		selected := i == index^
		if hovered || selected {
			fill(ctx, item, t.widget_hover if hovered else with_alpha(t.accent, 90))
		}
		if opts.draw_row != nil {
			ren.push_clip(ctx.dl, item)
			opts.draw_row(ctx, item, i, hovered, selected, opts.user)
			ren.pop_clip(ctx.dl)
		} else {
			put_text_in(ctx, items[i], ui.inset_xy(item, t.pad, 0), t.text)
		}
		if hovered && ctx.input.pressed[.Left] {
			if i != index^ {
				index^ = i
				changed = true
			}
			closing = true
		}
	}
	if max_scroll > 0 {
		track := ui.Rect{popup.x + popup.w - 6, popup.y + 1 + head, 5, rows * rh}
		fill(ctx, ui.thumb(track, len(matches), rows, scroll, true, 8), t.scroll)
	}
	if pressed_outside || .Escape in ctx.input.keys {
		closing = true
	}
	if closing {
		ctx.modal_close = true
		if ctx.edit.id == fid {
			edit_end(ctx)
		}
		ctx.scrolls[id] = 0
	}
	return
}

// ---- lists --------------------------------------------------------------------------------------------------------------------------

List_Opts :: struct {
	items:    []string, // the texts of the rows (when draw_row is nil)
	row_h:    int, // 0: the usual
	draw_row: Row_Draw,
	user:     rawptr,
}

// How much height is left in the window's contents under the widgets so far (for a list that fills the rest of a window; take `reserve` off for what
// comes after it).
remaining_height :: proc(ctx: ^Context, reserve := 0) -> int {
	l := &ctx.layout
	return max(l.content.y + l.content.h - l.y - reserve, 0)
}

// A box of `rows` rows of a list of `count` items; a click selects one (selected^ = its index), the wheel scrolls. Returns true when the selection changed.
// The label (if it shows) is drawn above the box. `scroll_to_selected` brings the selected row into view once (after a search, a new item).
list_view :: proc(ctx: ^Context, label: string, count: int, selected: ^int, height_rows: int, opts: List_Opts) -> (changed: bool) {
	t := ctx.theme
	id := make_id(ctx, label)
	if len(shown_label(label)) > 0 {
		self_label(ctx, shown_label(label))
	}
	rh := opts.row_h if opts.row_h > 0 else row_h(ctx)
	rows := max(height_rows, 1)
	r := next_rect(ctx, rows * rh + 2)
	b := behavior(ctx, id, r)
	fill(ctx, r, t.field)
	outline(ctx, r, t.border)
	scroll := ctx.scrolls[id]
	max_scroll := max(count - rows, 0)
	if b.hovered && ctx.input.wheel != 0 {
		scroll -= int(ctx.input.wheel) * 2
		ctx.input.wheel = 0
	}
	scroll = clamp(scroll, 0, max_scroll)
	ctx.scrolls[id] = scroll
	mx, my := int(ctx.input.mouse.x), int(ctx.input.mouse.y)
	ren.push_clip(ctx.dl, r)
	for row in 0 ..< rows {
		i := row + scroll
		if i >= count {
			break
		}
		item := ui.Rect{r.x + 1, r.y + 1 + row * rh, r.w - 2 - (7 if max_scroll > 0 else 0), rh}
		hovered := b.hovered && ui.contains(item, mx, my)
		if i == selected^ {
			fill(ctx, item, with_alpha(t.accent, 120))
		} else if hovered {
			fill(ctx, item, t.widget_hover)
		}
		if opts.draw_row != nil {
			ren.push_clip(ctx.dl, item)
			opts.draw_row(ctx, item, i, hovered, i == selected^, opts.user)
			ren.pop_clip(ctx.dl)
		} else if i < len(opts.items) {
			put_text_in(ctx, opts.items[i], ui.inset_xy(item, t.pad, 0), t.text)
		}
		if b.pressed && hovered && selected^ != i {
			selected^ = i
			changed = true
		}
	}
	if max_scroll > 0 {
		track := ui.Rect{r.x + r.w - 6, r.y + 1, 5, r.h - 2}
		fill(ctx, ui.thumb(track, count, rows, scroll, true, 8), t.scroll)
	}
	ren.pop_clip(ctx.dl)
	return
}

// Scrolls the list view of this label (in the current id scope) so that row `index` is the first one shown.
list_scroll_to :: proc(ctx: ^Context, label: string, index: int) {
	ctx.scrolls[make_id(ctx, label)] = max(index, 0)
}

// A box with a list of texts to choose from; a click selects. `rows` is how many show at once (the wheel scrolls).
list_box :: proc(ctx: ^Context, label: string, items: []string, selected: ^int, rows := 6) -> bool {
	return list_view(ctx, label, len(items), selected, rows, {items = items})
}

// ---- tabs and toggles ----------------------------------------------------------------------------------------------------------------

// A row of tabs: the one at `current^` is lit; a click on another makes it current (true).
tab_bar :: proc(ctx: ^Context, names: []string, current: ^int) -> (changed: bool) {
	t := ctx.theme
	row(ctx, len(names))
	for name, i in names {
		push_id_int(ctx, i)
		r := next_rect(ctx)
		b := behavior(ctx, make_id(ctx, "tab"), r)
		active := i == current^
		fill(ctx, r, t.accent if active else (t.widget_hover if b.hovered else t.widget))
		outline(ctx, r, t.border)
		put_text_in(ctx, name, r, t.text, .Center)
		if b.clicked && !active {
			current^ = i
			changed = true
		}
		pop_id(ctx)
	}
	return
}

// Toggle buttons that wrap at the width of the window, one for each name; `bits` has a bit for each (bit i is name i). True when one was clicked.
chips :: proc(ctx: ^Context, names: []string, bits: ^u64) -> (changed: bool) {
	end_row(ctx)
	t := ctx.theme
	l := &ctx.layout
	h := row_h(ctx) - 2
	x, y := l.x, l.y
	for name, i in names {
		w := text_w(ctx, name) + 2 * t.pad + 6
		if x + w > l.x + l.width && x > l.x {
			x = l.x
			y += h + t.spacing
		}
		r := ui.Rect{x, y, w, h}
		push_id_int(ctx, i)
		b := behavior(ctx, make_id(ctx, "chip"), r)
		pop_id(ctx)
		on := bits^ & (u64(1) << uint(i)) != 0
		fill(ctx, r, t.accent if on else (t.widget_hover if b.hovered else t.widget))
		outline(ctx, r, t.border)
		put_text_in(ctx, name, r, t.text, .Center)
		if b.clicked {
			bits^ ~= u64(1) << uint(i)
			changed = true
		}
		x += w + t.spacing
	}
	l.y = y + h + t.spacing
	l.last_rect = {l.x, y, l.width, h}
	return
}
