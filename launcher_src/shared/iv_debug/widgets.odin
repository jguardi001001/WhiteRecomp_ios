package iv_debug

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import ren "../iv_system/ren"
import ui "../iv_ui"

// ---------------------------------------------------------------------------
// The widgets. Each is one call that lays itself out in the current window, draws, reacts and returns what changed. A widget is known by its label.
// ---------------------------------------------------------------------------

// A button; true in the frame it is clicked.
button :: proc(ctx: ^Context, label: string) -> bool {
	id := make_id(ctx, label)
	r := next_rect(ctx)
	b := behavior(ctx, id, r)
	t := ctx.theme
	fill(ctx, r, t.widget_active if b.held else (t.widget_hover if b.hovered else t.widget))
	outline(ctx, r, t.border)
	put_text_in(ctx, shown_label(label), r, t.text, .Center)
	return b.clicked
}

// A check box with its label at its right; true when it was toggled.
checkbox :: proc(ctx: ^Context, label: string, v: ^bool) -> (changed: bool) {
	id := make_id(ctx, label)
	r := next_rect(ctx)
	b := behavior(ctx, id, r)
	t := ctx.theme
	if b.clicked {
		v^ = !v^
		changed = true
	}
	box := ui.Rect{r.x, r.y + 1, r.h - 2, r.h - 2}
	fill(ctx, box, t.widget_hover if b.hovered else t.field)
	outline(ctx, box, t.border)
	if v^ {
		fill(ctx, ui.inset(box, 4), t.accent)
	}
	put_text_in(ctx, shown_label(label), {r.x + box.w + 6, r.y, r.w - box.w - 6, r.h}, t.text)
	return
}

// One of several choices as a row of buttons-with-a-dot: `v^` is set to `value` when this one is clicked.
radio :: proc(ctx: ^Context, label: string, v: ^int, value: int) -> (changed: bool) {
	id := make_id(ctx, label)
	r := next_rect(ctx)
	b := behavior(ctx, id, r)
	t := ctx.theme
	if b.clicked && v^ != value {
		v^ = value
		changed = true
	}
	box := ui.Rect{r.x, r.y + 1, r.h - 2, r.h - 2}
	fill(ctx, box, t.widget_hover if b.hovered else t.field)
	outline(ctx, box, t.border)
	if v^ == value {
		fill(ctx, ui.inset(box, 4), t.accent)
	}
	put_text_in(ctx, shown_label(label), {r.x + box.w + 6, r.y, r.w - box.w - 6, r.h}, t.text)
	return
}

// ---- numbers -----------------------------------------------------------------------------------------------------------------------

// A number as text with at most `precision` decimals (trailing zeros left off).
format_number :: proc(v: f64, is_int: bool, precision := 3) -> string {
	if is_int {
		return fmt.tprintf("%d", i64(math.round(v)))
	}
	s := fmt.tprintf("%.*f", precision, v)
	if strings.contains_rune(s, '.') {
		s = strings.trim_right(s, "0")
		s = strings.trim_right(s, ".")
	}
	if s == "-0" {
		return "0"
	}
	return s
}

// A number field: drag sideways to change the value (shift: finer, ctrl: coarser), click without moving to type a value (Enter or a click elsewhere
// takes it, Escape leaves it). The shared part of drag, color_edit and the vectors. `speed` is the change per px.
drag_scalar :: proc(ctx: ^Context, id: ID, r: ui.Rect, v: ^f64, speed: f64, lo, hi: f64, is_int: bool, precision := 3, suffix := "") -> (changed: bool) {
	t := ctx.theme
	if ctx.edit.id == id {
		b := behavior(ctx, id, r)
		_ = b
		res := edit_field(ctx, id, r)
		if res.committed {
			if n, ok := strconv.parse_f64(strings.trim_space(edit_string(ctx))); ok {
				n = clamp(n, lo, hi)
				if is_int {
					n = math.round(n)
				}
				if n != v^ {
					v^ = n
					changed = true
				}
			}
			edit_end(ctx)
		} else if res.cancelled {
			edit_end(ctx)
		}
		return
	}
	b := behavior(ctx, id, r)
	if b.pressed {
		ctx.drag = {
			origin_x = ctx.input.mouse.x,
			value    = v^,
			moved    = false,
		}
	}
	if ctx.active == id && b.held {
		dx := ctx.input.mouse.x - ctx.drag.origin_x
		if abs(dx) >= 3 {
			ctx.drag.moved = true
		}
		if ctx.drag.moved {
			scale := 0.1 if ctx.input.shift else (10.0 if ctx.input.ctrl else 1.0)
			n := clamp(ctx.drag.value + f64(dx) * speed * scale, lo, hi)
			if is_int {
				n = math.round(n)
			}
			if n != v^ {
				v^ = n
				changed = true
			}
		}
	}
	if b.released && b.clicked && !ctx.drag.moved {
		edit_begin(ctx, id, format_number(v^, is_int, precision))
		return
	}
	fill(ctx, r, t.widget_active if b.held else (t.widget_hover if b.hovered else t.widget))
	outline(ctx, r, t.border)
	s := format_number(v^, is_int, precision)
	if len(suffix) > 0 {
		s = strings.concatenate({s, suffix}, context.temp_allocator)
	}
	put_text_in(ctx, s, r, t.text, .Center)
	return
}

// A number (any integer or float type): drag it or type it. `speed` is the change per px dragged (0: 0.05 for a float, 0.25 for an integer); the
// value is kept between `lo` and `hi` (and in the range of its type).
drag :: proc(ctx: ^Context, label: string, v: ^$T, speed: f64 = 0, lo: f64 = -1e300, hi: f64 = 1e300, precision := 3) -> bool where intrinsics.type_is_numeric(T) &&
	!intrinsics.type_is_complex(T) &&
	!intrinsics.type_is_quaternion(T) {
	id := make_id(ctx, label)
	r := property(ctx, label, id)
	return drag_in(ctx, id, r, v, speed, lo, hi, precision)
}

// drag in a rect of the caller's (a cell of a row, a part of a field).
drag_in :: proc(ctx: ^Context, id: ID, r: ui.Rect, v: ^$T, speed: f64 = 0, lo: f64 = -1e300, hi: f64 = 1e300, precision := 3) -> bool {
	f := f64(v^)
	is_int :: intrinsics.type_is_integer(T)
	sp := speed if speed != 0 else (0.25 if is_int else 0.05)
	low, high := lo, hi
	when is_int {
		low = max(low, f64(min(T)))
		high = min(high, f64(max(T)))
	}
	changed := drag_scalar(ctx, id, r, &f, sp, low, high, is_int, precision)
	if changed {
		v^ = T(f)
	}
	return changed
}

// A slider: the value follows the mouse along the bar while it is held.
slider :: proc(ctx: ^Context, label: string, v: ^$T, lo, hi: T, precision := 3) -> (changed: bool) where intrinsics.type_is_numeric(T) &&
	!intrinsics.type_is_complex(T) &&
	!intrinsics.type_is_quaternion(T) {
	id := make_id(ctx, label)
	r := property(ctx, label, id)
	t := ctx.theme
	b := behavior(ctx, id, r)
	span := f64(hi) - f64(lo)
	if b.held && span != 0 {
		frac := clamp((f64(ctx.input.mouse.x) - f64(r.x)) / f64(max(r.w, 1)), 0, 1)
		n := f64(lo) + frac * span
		is_int :: intrinsics.type_is_integer(T)
		when is_int {
			n = math.round(n)
		}
		if T(n) != v^ {
			v^ = T(n)
			changed = true
		}
	}
	fill(ctx, r, t.widget_hover if b.hovered else t.widget)
	frac := clamp((f64(v^) - f64(lo)) / span, 0, 1) if span != 0 else 0
	fill(ctx, {r.x, r.y, int(f64(r.w) * frac), r.h}, with_alpha(t.accent, 150))
	outline(ctx, r, t.border)
	put_text_in(ctx, format_number(f64(v^), intrinsics.type_is_integer(T), precision), r, t.text, .Center)
	return
}

// A row of number fields for the parts of a vector (any count; floats).
drag_vec :: proc(ctx: ^Context, label: string, v: []f32, speed: f64 = 0.05, lo: f64 = -1e300, hi: f64 = 1e300) -> (changed: bool) {
	id := make_id(ctx, label)
	r := property(ctx, label, id)
	push_id(ctx, label)
	defer pop_id(ctx)
	for i in 0 ..< len(v) {
		push_id_int(ctx, i)
		cell := ui.columns(r, i, len(v), 2)
		if drag_in(ctx, make_id(ctx, "v"), cell, &v[i], speed, lo, hi) {
			changed = true
		}
		pop_id(ctx)
	}
	return
}

// A color: a swatch and one number field for each of red, green, blue and alpha (0 to 255).
color_edit :: proc(ctx: ^Context, label: string, c: ^ren.Color) -> (changed: bool) {
	id := make_id(ctx, label)
	r := property(ctx, label, id)
	t := ctx.theme
	swatch, rest := ui.cut_left(r, r.h + 4, 2)
	// a checkerboard under the swatch shows the alpha
	fill(ctx, swatch, ren.Color{90, 90, 90, 255})
	fill(ctx, {swatch.x, swatch.y, swatch.w / 2, swatch.h / 2}, ren.Color{150, 150, 150, 255})
	fill(ctx, {swatch.x + swatch.w / 2, swatch.y + swatch.h / 2, swatch.w - swatch.w / 2, swatch.h - swatch.h / 2}, ren.Color{150, 150, 150, 255})
	fill(ctx, swatch, c^)
	outline(ctx, swatch, t.border)
	push_id(ctx, label)
	defer pop_id(ctx)
	parts := [4]^u8{&c[0], &c[1], &c[2], &c[3]}
	for i in 0 ..< 4 {
		push_id_int(ctx, i)
		if drag_in(ctx, make_id(ctx, "c"), ui.columns(rest, i, 4, 2), parts[i], 0.5, 0, 255) {
			changed = true
		}
		pop_id(ctx)
	}
	return
}

// ---- choices ---------------------------------------------------------------------------------------------------------------------

// A drop-down for an enum variable: the names of the enum's values.
dropdown_enum :: proc(ctx: ^Context, label: string, v: ^$E) -> bool where intrinsics.type_is_enum(E) {
	names := enum_names(E)
	values := enum_values(E)
	index := 0
	for val, i in values {
		if val == i64(v^) {
			index = i
			break
		}
	}
	if dropdown(ctx, label, names, &index) {
		v^ = E(values[index])
		return true
	}
	return false
}

// The names of an enum's values, in order (temp allocator).
enum_names :: proc($E: typeid) -> []string {
	return enum_names_of(typeid_of(E))
}

// The values of an enum, in order, as numbers (temp allocator).
enum_values :: proc($E: typeid) -> []i64 {
	return enum_values_of(typeid_of(E))
}

@(private)
self_label :: proc(ctx: ^Context, s: string) {
	label(ctx, s, ctx.theme.text_dim)
}

// ---- trees ----------------------------------------------------------------------------------------------------------------------------

// A line that opens and closes what is under it. When it returns true put the contents next and then call tree_pop.
//   if iv_debug.tree_node(&ctx, "Stats") { ...widgets...; iv_debug.tree_pop(&ctx) }
tree_node :: proc(ctx: ^Context, label: string, default_open := false) -> bool {
	id := make_id(ctx, label)
	if id not_in ctx.opens {
		ctx.opens[id] = default_open
	}
	r := next_rect(ctx)
	b := behavior(ctx, id, r)
	t := ctx.theme
	if b.clicked {
		ctx.opens[id] = !ctx.opens[id]
	}
	if b.hovered {
		fill(ctx, r, t.widget_hover)
	}
	open := ctx.opens[id]
	triangle(ctx, {r.x, r.y, r.h, r.h}, !open, t.text_dim)
	put_text_in(ctx, shown_label(label), {r.x + r.h, r.y, r.w - r.h, r.h}, t.text)
	if open {
		push_id(ctx, label)
		indent(ctx)
	}
	return open
}

tree_pop :: proc(ctx: ^Context) {
	unindent(ctx)
	pop_id(ctx)
}

// Is the tree node (by its label, in the current id scope) open?
tree_is_open :: proc(ctx: ^Context, label: string) -> bool {
	return ctx.opens[make_id(ctx, label)]
}

set_tree_open :: proc(ctx: ^Context, label: string, open: bool) {
	ctx.opens[make_id(ctx, label)] = open
}

// ---- showing values ---------------------------------------------------------------------------------------------------------------------

// A bar filled to `fraction` (0 to 1) with `overlay` text on it (a default of the percentage).
progress :: proc(ctx: ^Context, fraction: f32, overlay := "") {
	r := next_rect(ctx)
	t := ctx.theme
	f := clamp(fraction, 0, 1)
	fill(ctx, r, t.field)
	fill(ctx, {r.x, r.y, int(f32(r.w) * f), r.h}, with_alpha(t.accent, 190))
	outline(ctx, r, t.border)
	s := overlay if len(overlay) > 0 else fmt.tprintf("%d%%", int(f * 100 + 0.5))
	put_text_in(ctx, s, r, t.text, .Center)
}

// A line graph of `values` (oldest first) in a box `height` px high; lo == hi: the range follows the data.
plot :: proc(ctx: ^Context, label: string, values: []f32, height := 60, lo: f32 = 0, hi: f32 = 0) {
	t := ctx.theme
	if len(shown_label(label)) > 0 {
		self_label(ctx, shown_label(label))
	}
	r := next_rect(ctx, height)
	fill(ctx, r, t.field)
	outline(ctx, r, t.border)
	if len(values) < 2 {
		return
	}
	mn, mx := lo, hi
	if lo == hi {
		mn, mx = values[0], values[0]
		for v in values {
			mn = min(mn, v)
			mx = max(mx, v)
		}
		if mx == mn {
			mx = mn + 1
		}
	}
	inner := ui.inset(r, 2)
	point :: proc(inner: ui.Rect, i, n: int, v, mn, mx: f32) -> [2]f32 {
		x := f32(inner.x) + f32(inner.w) * f32(i) / f32(n - 1)
		y := f32(inner.y + inner.h) - f32(inner.h) * clamp((v - mn) / (mx - mn), 0, 1)
		return {x, y}
	}
	ren.push_clip(ctx.dl, r)
	for i in 1 ..< len(values) {
		a := point(inner, i - 1, len(values), values[i - 1], mn, mx)
		b := point(inner, i, len(values), values[i], mn, mx)
		ren.draw_line(ctx.dl, a, b, 1.5, t.accent)
	}
	put_text_in(ctx, format_number(f64(mx), false, 2), {r.x + 3, r.y, r.w - 6, line_h(ctx)}, t.text_dim)
	put_text_in(ctx, format_number(f64(mn), false, 2), {r.x + 3, r.y + r.h - line_h(ctx), r.w - 6, line_h(ctx)}, t.text_dim)
	ren.pop_clip(ctx.dl)
}

// A small text near the mouse after it rests on the last widget for a moment: call it right after the widget.
tooltip :: proc(ctx: ^Context, s: string) {
	if !ctx.last_hovered || ctx.hover_id != ctx.last_id || ctx.time - ctx.hover_since < 0.5 || len(s) == 0 {
		return
	}
	t := ctx.theme
	w := text_w(ctx, s) + 2 * t.pad
	h := line_h(ctx) + 2 * t.pad
	x := int(ctx.input.mouse.x) + 14
	y := int(ctx.input.mouse.y) + 18
	x = clamp(x, 0, max(ctx.screen.x - w, 0))
	y = clamp(y, 0, max(ctx.screen.y - h, 0))
	saved_dl, saved_in := ctx.dl, ctx.in_overlay
	ctx.dl, ctx.in_overlay = &ctx.overlay, true
	defer {ctx.dl, ctx.in_overlay = saved_dl, saved_in}
	box := ui.Rect{x, y, w, h}
	fill(ctx, box, ren.Color{12, 14, 18, 245})
	outline(ctx, box, t.border)
	put_text(ctx, s, x + t.pad, y + t.pad, t.text)
}
