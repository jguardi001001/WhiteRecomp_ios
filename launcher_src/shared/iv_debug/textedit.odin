package iv_debug

import "core:strings"
import "core:unicode/utf8"
import ren "../iv_system/ren"
import text "../iv_text"
import ui "../iv_ui"

// ---------------------------------------------------------------------------
// Text editing: one field at a time has the keyboard (Context.edit). The same editor serves strings (input_string) and the typed entry of numbers (a
// click on a drag field).
// ---------------------------------------------------------------------------

Edit_State :: struct {
	id:      ID, // the field being edited, 0: none
	buf:     [dynamic]u8,
	cursor:  int, // byte places
	anchor:  int, // the other end of the selection (== cursor: none)
	scroll_x: f32, // how far the text is moved left to keep the caret in view
	scroll_line: int, // an area: the first line it shows
	moved:   f32, // the time of the last edit or move (the caret shows for a while after it)
	seen:    bool, // the field was called this frame (a field that is not called any more ends the edit)
	owned:   rawptr, // the last string input_string made (freed when it makes the next)
}

Edit_Result :: struct {
	changed:   bool, // the text is different
	committed: bool, // Enter, or a click elsewhere
	cancelled: bool, // Escape
}

edit_active :: proc(ctx: ^Context, id: ID) -> bool {
	return ctx.edit.id == id
}

// Starts editing the field `id` with `initial` in it (all selected, or the caret at its end).
edit_begin :: proc(ctx: ^Context, id: ID, initial: string, select_all := true) {
	e := &ctx.edit
	clear(&e.buf)
	append(&e.buf, ..transmute([]u8)initial)
	e.id = id
	e.cursor = len(e.buf)
	e.anchor = 0 if select_all else len(e.buf)
	e.scroll_x = 0
	e.moved = ctx.time
	e.owned = nil
	e.seen = true
}

edit_end :: proc(ctx: ^Context) {
	e := &ctx.edit
	e.id = 0
	e.owned = nil
	clear(&e.buf)
	e.cursor, e.anchor = 0, 0
}

edit_string :: proc(ctx: ^Context) -> string {
	return string(ctx.edit.buf[:])
}

@(private)
sel_range :: proc(e: ^Edit_State) -> (lo, hi: int) {
	return min(e.cursor, e.anchor), max(e.cursor, e.anchor)
}

@(private)
delete_range :: proc(e: ^Edit_State, lo, hi: int) {
	if hi > lo {
		remove_range(&e.buf, lo, hi)
	}
	e.cursor, e.anchor = lo, lo
}

@(private)
insert_text :: proc(e: ^Edit_State, s: string) {
	lo, hi := sel_range(e)
	delete_range(e, lo, hi)
	inject_at(&e.buf, lo, ..transmute([]u8)s)
	e.cursor = lo + len(s)
	e.anchor = e.cursor
}

@(private)
rune_before :: proc(buf: []u8, i: int) -> int {
	j := i - 1
	for j > 0 && !utf8.rune_start(buf[j]) {
		j -= 1
	}
	return max(j, 0)
}

@(private)
rune_after :: proc(buf: []u8, i: int) -> int {
	j := i + 1
	for j < len(buf) && !utf8.rune_start(buf[j]) {
		j += 1
	}
	return min(j, len(buf))
}

@(private)
is_word_byte :: proc(c: u8) -> bool {
	return c >= 0x80 || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

@(private)
word_before :: proc(buf: []u8, i: int) -> int {
	j := i
	for j > 0 && !is_word_byte(buf[j - 1]) {
		j -= 1
	}
	for j > 0 && is_word_byte(buf[j - 1]) {
		j -= 1
	}
	return j
}

@(private)
word_after :: proc(buf: []u8, i: int) -> int {
	j := i
	for j < len(buf) && !is_word_byte(buf[j]) {
		j += 1
	}
	for j < len(buf) && is_word_byte(buf[j]) {
		j += 1
	}
	return j
}

clipboard_text :: proc(ctx: ^Context) -> string {
	if ctx.clipboard_get != nil {
		return ctx.clipboard_get(ctx.clipboard_user)
	}
	return strings.to_string(ctx.clipboard)
}

clipboard_set :: proc(ctx: ^Context, s: string) {
	if ctx.clipboard_set != nil {
		ctx.clipboard_set(ctx.clipboard_user, s)
		return
	}
	strings.builder_reset(&ctx.clipboard)
	strings.write_string(&ctx.clipboard, s)
}

// The keys and the typed characters of a text being edited (the same for a line and for an area): inserts, deletes, moves the caret, copies and pastes.
// `multiline`: Enter makes a new line (Ctrl+Enter ends the edit). `skip` are keys the caller has handled itself.
@(private)
edit_keys :: proc(ctx: ^Context, multiline: bool, skip: Keys) -> (res: Edit_Result) {
	e := &ctx.edit
	inp := ctx.input
	before := len(e.buf)
	for c in inp.typed {
		if c >= 32 && c != 127 {
			bytes, n := utf8.encode_rune(c)
			b := bytes
			insert_text(e, string(b[:n]))
			e.moved = ctx.time
		}
	}
	k := inp.keys - skip
	if .Enter in k {
		if multiline && !inp.ctrl {
			insert_text(e, "\n")
			e.moved = ctx.time
		} else {
			res.committed = true
		}
	}
	if .Escape in k {
		res.cancelled = true
	}
	if .Backspace in k {
		lo, hi := sel_range(e)
		if hi > lo {
			delete_range(e, lo, hi)
		} else if e.cursor > 0 {
			from := word_before(e.buf[:], e.cursor) if inp.ctrl else rune_before(e.buf[:], e.cursor)
			delete_range(e, from, e.cursor)
		}
		e.moved = ctx.time
	}
	if .Delete in k {
		lo, hi := sel_range(e)
		if hi > lo {
			delete_range(e, lo, hi)
		} else if e.cursor < len(e.buf) {
			to := word_after(e.buf[:], e.cursor) if inp.ctrl else rune_after(e.buf[:], e.cursor)
			delete_range(e, e.cursor, to)
		}
		e.moved = ctx.time
	}
	if .Left in k {
		lo, hi := sel_range(e)
		if hi > lo && !inp.shift {
			edit_move(e, lo, false, ctx.time)
		} else {
			edit_move(e, word_before(e.buf[:], e.cursor) if inp.ctrl else rune_before(e.buf[:], e.cursor), inp.shift, ctx.time)
		}
	}
	if .Right in k {
		lo, hi := sel_range(e)
		if hi > lo && !inp.shift {
			edit_move(e, hi, false, ctx.time)
		} else {
			edit_move(e, word_after(e.buf[:], e.cursor) if inp.ctrl else rune_after(e.buf[:], e.cursor), inp.shift, ctx.time)
		}
	}
	if .Home in k {
		edit_move(e, 0, inp.shift, ctx.time)
	}
	if .End in k {
		edit_move(e, len(e.buf), inp.shift, ctx.time)
	}
	if inp.ctrl {
		if .A in k {
			e.anchor, e.cursor = 0, len(e.buf)
		}
		if .C in k || .X in k {
			lo, hi := sel_range(e)
			if hi > lo {
				clipboard_set(ctx, string(e.buf[lo:hi]))
				if .X in k {
					delete_range(e, lo, hi)
				}
			}
		}
		if .V in k {
			clip := clipboard_text(ctx)
			one_line, _ := strings.replace_all(clip, "\n", " ", context.temp_allocator)
			one_line, _ = strings.replace_all(one_line, "\r", "", context.temp_allocator)
			insert_text(e, one_line)
			e.moved = ctx.time
		}
	}
	e.cursor = clamp(e.cursor, 0, len(e.buf))
	e.anchor = clamp(e.anchor, 0, len(e.buf))
	res.changed = len(e.buf) != before
	return
}

@(private)
edit_move :: proc(e: ^Edit_State, to: int, extend: bool, now: f32) {
	e.cursor = to
	if !extend {
		e.anchor = to
	}
	e.moved = now
}

// Runs the field `id` that is being edited (see edit_begin) in the rect `r`: takes the mouse and the keys, draws it. Call it every frame while
// edit_active.
edit_field :: proc(ctx: ^Context, id: ID, r: ui.Rect) -> (res: Edit_Result) {
	e := &ctx.edit
	if e.id != id {
		return
	}
	e.seen = true
	t := ctx.theme
	inp := ctx.input
	area := ui.inset_xy(r, t.pad, 0)
	mx, my := int(inp.mouse.x), int(inp.mouse.y)
	buf := e.buf[:]
	before := len(e.buf)

	// the mouse: a press puts the caret (shift: extends the selection), a drag selects, a press elsewhere ends the edit
	if inp.pressed[.Left] {
		if ui.contains(r, mx, my) {
			e.cursor = text.byte_near(ctx.tf, string(buf), inp.mouse.x - f32(area.x) + e.scroll_x, ctx.size)
			if !inp.shift {
				e.anchor = e.cursor
			}
			e.moved = ctx.time
		} else {
			res.committed = true
			return
		}
	} else if ctx.active == id && inp.down[.Left] {
		e.cursor = text.byte_near(ctx.tf, string(buf), inp.mouse.x - f32(area.x) + e.scroll_x, ctx.size)
		e.moved = ctx.time
	}
	_ = my

	kr := edit_keys(ctx, false, {})
	res.committed = res.committed || kr.committed
	res.cancelled = res.cancelled || kr.cancelled
	buf = e.buf[:]
	e.cursor = clamp(e.cursor, 0, len(e.buf))
	e.anchor = clamp(e.anchor, 0, len(e.buf))
	res.changed = len(e.buf) != before || kr.changed

	// keep the caret in view
	str := string(e.buf[:])
	caret_x := text.x_at(ctx.tf, str, e.cursor, ctx.size)
	view := f32(max(area.w - 2, 1))
	if caret_x - e.scroll_x > view {
		e.scroll_x = caret_x - view
	}
	if caret_x < e.scroll_x {
		e.scroll_x = caret_x
	}
	total := text.width_f(ctx.tf, str, ctx.size)
	if total - e.scroll_x < view {
		e.scroll_x = max(total - view, 0)
	}

	// draw
	fill(ctx, r, t.field)
	outline(ctx, r, t.accent)
	ren.push_clip(ctx.dl, area)
	lo, hi := sel_range(e)
	if hi > lo {
		x0 := text.x_at(ctx.tf, str, lo, ctx.size)
		x1 := text.x_at(ctx.tf, str, hi, ctx.size)
		fill(ctx, {area.x + int(x0 - e.scroll_x), r.y + 2, max(int(x1 - x0), 1), r.h - 4}, t.selection)
	}
	ty := r.y + (r.h - line_h(ctx)) / 2
	text.draw(ctx.dl, ctx.tf, str, {area.x - int(e.scroll_x), ty}, ctx.size, t.text)
	since := ctx.time - e.moved
	if since < 0.5 || int(since * 2) % 2 == 0 {
		fill(ctx, {area.x + int(caret_x - e.scroll_x), r.y + 2, 1, r.h - 4}, t.accent)
	}
	ren.pop_clip(ctx.dl)
	return
}

// A field that shows and edits a string. The strings it makes are allocated with ctx.string_allocator; the one that was in the variable before the
// first edit is not freed (it may be a literal): free it yourself if you own it. Returns whether the string changed (it changes as you type).
input_string :: proc(ctx: ^Context, label: string, s: ^string) -> (changed: bool) {
	changed, _ = input_string_ex(ctx, label, s)
	return
}

// input_string that also says when the edit ended (Enter, a click elsewhere or Escape): for a value that must not be applied while it is typed (a key
// that renames something): edit a copy and use it when `ended`.
input_string_ex :: proc(ctx: ^Context, label: string, s: ^string) -> (changed, ended: bool) {
	id := make_id(ctx, label)
	field := property(ctx, label, id)
	return input_string_in(ctx, id, field, s)
}

input_string_in :: proc(ctx: ^Context, id: ID, field: ui.Rect, s: ^string) -> (changed, ended: bool) {
	t := ctx.theme
	b := behavior(ctx, id, field)
	if b.pressed && ctx.edit.id != id {
		if ctx.edit.id != 0 {
			edit_end(ctx)
		}
		edit_begin(ctx, id, s^, select_all = false)
	}
	if ctx.edit.id == id {
		res := edit_field(ctx, id, field)
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
			ended = true
		}
		return
	}
	fill(ctx, field, t.widget_hover if b.hovered else t.field)
	outline(ctx, field, t.border)
	put_text_in(ctx, s^, ui.inset_xy(field, t.pad, 0), t.text)
	return
}
