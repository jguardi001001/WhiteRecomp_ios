// Immediate-mode widgets for the tools a programmer builds into a program: an in-game inspector, a data editor, a tweak panel, a profiler overlay. They are
// not for players: there is no skin, no animation and no gamepad navigation; the look is a plain dark theme (Theme) and every widget is one call that
// draws itself, reacts to the mouse and the keyboard, and returns what changed.
//
//   ctx: iv_debug.Context
//   iv_debug.init(&ctx, &typeface, 15)                              // a Typeface of iv_text; 15 = the em in px
//   ...
//   each frame:
//   iv_debug.begin_frame(&ctx, input, {window_w, window_h})         // `input` is an iv_debug.Input (input_iv.odin makes one from iv_input)
//   if iv_debug.window(&ctx, "Player", {20, 20, 320, 400}) {
//       iv_debug.inspect(&ctx, "player", &player)                   // every field of any struct, editable (inspect.odin)
//       if iv_debug.button(&ctx, "Heal") { player.hp = player.max_hp }
//       iv_debug.drag(&ctx, "gravity", &world.gravity, 0.05)
//       iv_debug.checkbox(&ctx, "god mode", &player.god)
//   }
//   iv_debug.end_window(&ctx)                                       // always, whether window() said true or not
//   iv_debug.end_frame(&ctx, dl)                                    // draws everything into the draw list, on top of what is there
//   if iv_debug.wants_mouse(&ctx) { /* the game ignores the mouse this frame */ }
//
// Windows may be dragged, resized, collapsed, scrolled, and raised by a click; their places are remembered by their titles. A widget is identified by its
// label (so two widgets in one window need different labels: "x##a" and "x##b" show "x" and differ; push_id gives a scope to a repeated group).
//
// Contents: context.odin (this, the frame, windows), layout.odin (windows' layout, rows, labels), widgets.odin (buttons, fields, lists, ...),
// textedit.odin (text fields), inspect.odin (the struct editor), input_iv.odin (making an Input from iv_input).
package iv_debug

import "base:runtime"
import "core:hash"
import "core:math"
import "core:strings"
import ren "../iv_system/ren"
import text "../iv_text"
import ui "../iv_ui"

ID :: u32

// The keys the widgets use (a text field, mostly).
Key :: enum u8 {
	Enter,
	Escape,
	Tab,
	Backspace,
	Delete,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	A,
	C,
	V,
	X,
	Z,
}

Keys :: bit_set[Key;u16]

Button :: enum u8 {
	Left,
	Right,
	Middle,
}

// What the program tells the widgets about this frame's input.
Input :: struct {
	mouse:    [2]f32, // in px of the target
	down:     [Button]bool, // held
	pressed:  [Button]bool, // went down this frame
	released: [Button]bool, // went up this frame
	wheel:    f32, // notches this frame, positive: up (content moves down)
	typed:    []rune, // characters typed this frame
	keys:     Keys, // pressed this frame (a held key that repeats counts at each repeat)
	ctrl:     bool,
	shift:    bool,
	alt:      bool,
	dt:       f32, // seconds since the last frame (the caret blinks, a tooltip waits)
}

Theme :: struct {
	window:        ren.Color,
	title:         ren.Color,
	title_active:  ren.Color,
	title_text:    ren.Color,
	border:        ren.Color,
	text:          ren.Color,
	text_dim:      ren.Color,
	widget:        ren.Color, // buttons, fields
	widget_hover:  ren.Color,
	widget_active: ren.Color,
	field:         ren.Color, // the inside of text fields and lists
	accent:        ren.Color, // checks, filled parts of sliders, the caret
	selection:     ren.Color,
	scroll:        ren.Color,
	scroll_hover:  ren.Color,
	error:         ren.Color,
	pad:           int, // inside a window and inside a widget
	spacing:       int, // between widgets
	scroll_w:      int,
	indent:        int,
	label_ratio:   f32, // the part of a row that its label takes
	min_label_w:   int,
}

theme_default :: proc() -> Theme {
	return {
		window = {24, 26, 32, 250},
		title = {40, 44, 54, 255},
		title_active = {52, 70, 110, 255},
		title_text = {235, 238, 245, 255},
		border = {70, 76, 92, 255},
		text = {222, 226, 234, 255},
		text_dim = {140, 148, 164, 255},
		widget = {50, 56, 70, 255},
		widget_hover = {64, 74, 96, 255},
		widget_active = {84, 110, 170, 255},
		field = {16, 18, 24, 255},
		accent = {92, 150, 255, 255},
		selection = {70, 110, 190, 160},
		scroll = {70, 78, 98, 200},
		scroll_hover = {100, 112, 140, 230},
		error = {255, 96, 96, 255},
		pad = 4,
		spacing = 3,
		scroll_w = 10,
		indent = 14,
		label_ratio = 0.42,
		min_label_w = 70,
	}
}

Window_Flag :: enum u8 {
	No_Title, // no title bar (it cannot be moved by it, collapsed or closed)
	No_Move,
	No_Resize,
	No_Scroll,
	Auto_Height, // as high as its contents (up to the target's height)
	Closable, // a close button (needs the `open` pointer of window())
}

Window_Flags :: bit_set[Window_Flag;u8]

// A window that is remembered by the id of its title.
Window :: struct {
	rect:      ui.Rect, // the whole window, title bar included (when it is collapsed, the height it has when open)
	shown:     ui.Rect, // what is on the screen now (the title bar only, when collapsed)
	scroll:    int,
	content_h: int, // how high the contents were last frame
	z:         int, // higher is in front
	flags:     Window_Flags,
	collapsed: bool,
	used:      bool, // window() was called this frame
	grab:      [2]int, // while moved or resized: where the mouse took hold
	dl:        ren.Draw_List, // what the window drew this frame
}

// How the widgets of a window are laid out.
Layout :: struct {
	content:   ui.Rect, // the visible part of the window's contents, on the screen (widgets are clipped to it)
	x:         int, // the left of the widgets (the indent is in it)
	width:     int, // how wide they are
	y:         int, // where the next one goes
	start_y:   int, // the top of the contents (scrolled)
	indent:    int,
	cells:     int, // in a row: how many widgets share it (0: not in a row)
	cell:      int, // the next one's place in it
	row_y:     int,
	row_h:     int,
	last_rect: ui.Rect, // what the last widget took (for tooltip and same-line things)
}

Context :: struct {
	tf:               ^text.Typeface,
	size:             f32, // the em of the text, px
	theme:            Theme,
	input:            Input,
	screen:           [2]int,
	time:             f32,
	string_allocator: runtime.Allocator, // what the strings the widgets make are allocated with (input_string)

	// what the mouse is doing
	hot:              ID, // the widget the mouse is over
	active:           ID, // the widget being pressed or dragged
	modal:            ID, // a widget that has a popup open: the others do not react
	modal_close:      bool, // the popup closes at the start of the next frame (so the click that closed it does not reach the widgets under it)
	modal_seen:       bool, // the widget that owns the popup was called this frame
	mouse_window:     ID, // the window the mouse is over (the front one), from the last frame's places
	popup_rect:       ui.Rect, // the rect of the open popup (last frame): the mouse is over it, not over a window
	popup_seen:       bool,
	hover_id:         ID, // for tooltips
	hover_since:      f32,
	hover_seen:       bool,
	last_id:          ID,
	last_hovered:     bool,

	// windows
	windows:          map[ID]Window,
	z_counter:        int,
	order:            [dynamic]ID, // windows called this frame
	cur:              ^Window,
	cur_id:           ID,
	layout:           Layout,
	dl:               ^ren.Draw_List, // where widgets draw now
	overlay:          ren.Draw_List, // popups and tooltips: drawn after every window
	in_overlay:       bool,
	id_stack:         [dynamic]ID,

	// state of widgets that has no place in the caller's data
	opens:            map[ID]bool, // tree nodes
	scrolls:          map[ID]int, // list boxes
	drag:             Drag_State,
	edit:             Edit_State,
	clipboard:        strings.Builder, // used when the program gives no clipboard procedures
	clipboard_get:    proc(user: rawptr) -> string, // (optional) the operating system's clipboard
	clipboard_set:    proc(user: rawptr, s: string),
	clipboard_user:   rawptr,
	allocator:        runtime.Allocator,
	started:          bool,

	// for tests of tools: with `track_rects` on, the rect of every widget (the part that answers the mouse) is kept by its id, for the frame
	track_rects:      bool,
	rects:            map[ID]ui.Rect,
}

Drag_State :: struct {
	origin_x: f32, // where the mouse was when the drag began
	value:    f64, // what the value was
	moved:    bool,
}

// ---- the context -------------------------------------------------------------------------------------------------------------------

// A context that draws with `tf` (a typeface of iv_text) at the em `size`.
init :: proc(ctx: ^Context, tf: ^text.Typeface, size: f32 = 15, allocator := context.allocator) {
	ctx.tf = tf
	ctx.size = size
	ctx.theme = theme_default()
	ctx.allocator = allocator
	ctx.string_allocator = allocator
	ctx.windows = make(map[ID]Window, allocator)
	ctx.order = make([dynamic]ID, allocator)
	ctx.id_stack = make([dynamic]ID, allocator)
	ctx.opens = make(map[ID]bool, allocator)
	ctx.scrolls = make(map[ID]int, allocator)
	ctx.rects = make(map[ID]ui.Rect, allocator)
	ctx.edit.buf = make([dynamic]u8, allocator)
	ctx.clipboard = strings.builder_make(allocator)
	ren.draw_list_init(&ctx.overlay, allocator)
}

destroy :: proc(ctx: ^Context) {
	for _, &w in ctx.windows {
		ren.draw_list_destroy(&w.dl)
	}
	delete(ctx.windows)
	delete(ctx.order)
	delete(ctx.id_stack)
	delete(ctx.opens)
	delete(ctx.scrolls)
	delete(ctx.rects)
	delete(ctx.edit.buf)
	strings.builder_destroy(&ctx.clipboard)
	ren.draw_list_destroy(&ctx.overlay)
	ctx^ = {}
}

// ---- the frame -----------------------------------------------------------------------------------------------------------------------

// Starts a frame. `screen` is the size of the target the widgets are drawn into.
begin_frame :: proc(ctx: ^Context, input: Input, screen: [2]int) {
	ctx.input = input
	ctx.screen = screen
	ctx.time += input.dt
	ctx.started = true
	ctx.hot = 0
	clear(&ctx.order)
	if ctx.modal_close {
		ctx.modal, ctx.modal_close = 0, false
	}

	// the window under the mouse: the front one of those drawn last frame
	ctx.mouse_window = 0
	best := min(int)
	mx, my := int(input.mouse.x), int(input.mouse.y)
	if !(ctx.popup_seen && ui.contains(ctx.popup_rect, mx, my)) {
		for id, w in ctx.windows {
			if w.used && w.z > best && ui.contains(w.shown, mx, my) {
				ctx.mouse_window = id
				best = w.z
			}
		}
	}
	for _, &w in ctx.windows {
		w.used = false
	}
	ctx.popup_seen = false
	if !ctx.hover_seen {
		ctx.hover_id = 0
	}
	ctx.hover_seen = false

	// a click raises the window it is in; a click on nothing ends a text edit (the field sees the press and commits)
	if input.pressed[.Left] || input.pressed[.Right] {
		if w, ok := &ctx.windows[ctx.mouse_window]; ok {
			ctx.z_counter += 1
			w.z = ctx.z_counter
		}
	}
	if !input.down[.Left] && ctx.active != 0 && !input.released[.Left] {
		ctx.active = 0 // (the button went up where nobody was looking)
	}
	ren.draw_list_reset(&ctx.overlay, screen.x, screen.y)
	ctx.dl = &ctx.overlay
	ctx.in_overlay = false
	ctx.cur = nil
	clear(&ctx.id_stack)
}

// Ends the frame: the bookkeeping, and then draw() (the windows back to front, then the popups, into `dl` on top of what is in it). A program that
// draws the picture more than once (a screenshot) calls end_frame once and draw() as often as needed.
end_frame :: proc(ctx: ^Context, dl: ^ren.Draw_List) {
	finish_frame(ctx)
	draw(ctx, dl)
}

// The bookkeeping of the end of a frame (without drawing).
finish_frame :: proc(ctx: ^Context) {
	if len(ctx.edit.buf) > 0 || ctx.edit.id != 0 {
		if !ctx.edit.seen {
			edit_end(ctx) // the field is gone (its window was closed): the edit is over
		}
		ctx.edit.seen = false
	}
	if ctx.modal != 0 && !ctx.modal_seen { // (the widget that has the popup is not called any more)
		ctx.modal = 0
	}
	ctx.modal_seen = false
	if !ctx.input.down[.Left] {
		ctx.active = 0
	}
}

// Puts what the frame drew into `dl`: the windows called this frame, back to front, then the popups and tooltips. May be called any number of times
// after the frame is made.
draw :: proc(ctx: ^Context, dl: ^ren.Draw_List) {
	ids := make([dynamic]ID, context.temp_allocator)
	for id in ctx.order {
		append(&ids, id)
	}
	// back to front: sort by z (a few windows: insertion sort)
	for i in 1 ..< len(ids) {
		j := i
		for j > 0 && ctx.windows[ids[j - 1]].z > ctx.windows[ids[j]].z {
			ids[j - 1], ids[j] = ids[j], ids[j - 1]
			j -= 1
		}
	}
	for id in ids {
		w := &ctx.windows[id]
		append_list(dl, &w.dl)
	}
	append_list(dl, &ctx.overlay)
}

// Does the debug interface want the mouse this frame (it is over a window or a popup, or something is being dragged)? A program ignores its own mouse
// handling then.
wants_mouse :: proc(ctx: ^Context) -> bool {
	return ctx.mouse_window != 0 || ctx.active != 0 || ctx.modal != 0 || (ctx.popup_seen && ui.contains(ctx.popup_rect, int(ctx.input.mouse.x), int(ctx.input.mouse.y)))
}

// wants_mouse for a pointer at `p` as it is now, asked before this frame's windows are built (the program's own update runs first and must know whether the
// pointer is over a window as the windows were drawn last frame, not where the pointer was then).
wants_mouse_at :: proc(ctx: ^Context, p: [2]f32) -> bool {
	if ctx.active != 0 || ctx.modal != 0 {
		return true
	}
	mx, my := int(p.x), int(p.y)
	if ctx.popup_seen && ui.contains(ctx.popup_rect, mx, my) {
		return true
	}
	for _, w in ctx.windows {
		if w.used && ui.contains(w.shown, mx, my) {
			return true
		}
	}
	return false
}

// Is a text field being edited (the keyboard belongs to the interface)?
wants_keyboard :: proc(ctx: ^Context) -> bool {
	return ctx.edit.id != 0
}

// Puts what a draw list holds after what another has, as if it had been drawn into `dst` now: with dst's current target, offset, tint and clip (the debug
// interface draws into lists of its own so that windows can be put in order; no shader commands are in them).
@(private)
append_list :: proc(dst, src: ^ren.Draw_List) {
	if len(src.commands) == 0 {
		return
	}
	off := ren.current_offset(dst)
	tint := ren.current_tint(dst)
	target := ren.current_target(dst)
	clip := ren.current_clip(dst)
	base := u32(len(dst.vertices))
	first := u32(len(dst.indices))
	for v in src.vertices {
		append(&dst.vertices, ren.Vertex{pos = v.pos + off, uv = v.uv, color = ren.color_mul(v.color, tint)})
	}
	for i in src.indices {
		append(&dst.indices, base + i)
	}
	for c in src.commands {
		cmd := c
		cmd.first_index += first
		cmd.target = target
		cmd.clip = ui.intersect(ui.translate(c.clip, int(off.x), int(off.y)), clip)
		append(&dst.commands, cmd)
	}
}

// ---- ids ---------------------------------------------------------------------------------------------------------------------------

// The id of a label in the scope that is current (push_id). Everything after "##" is part of the id and not shown.
make_id :: proc(ctx: ^Context, label: string) -> ID {
	seed: u32 = 2166136261
	if n := len(ctx.id_stack); n > 0 {
		seed = ctx.id_stack[n - 1]
	}
	h := hash.fnv32a(transmute([]u8)id_key(label), seed)
	return h if h != 0 else 1
}

@(private)
id_key :: proc(label: string) -> string {
	if i := strings.index(label, "###"); i >= 0 {
		return label[i:] // (only what follows "###" makes the id: the shown part may change)
	}
	return label
}

// The id a widget gets when it is called inside the scopes `path[:len-1]` (windows' titles, tree nodes, push_id, push_id_int) with the label `path[len-1]`:
// strings and ints, for tools that test or drive an interface from outside (with Context.track_rects).
id_in :: proc(path: ..any) -> ID {
	h: u32 = 2166136261
	for p in path {
		switch v in p {
		case string:
			h = hash.fnv32a(transmute([]u8)id_key(v), h)
		case int:
			n := u64(v)
			bytes := ([^]u8)(&n)[:8]
			h = hash.fnv32a(bytes, h)
		}
		if h == 0 {
			h = 1
		}
	}
	return h
}

push_id :: proc(ctx: ^Context, label: string) {
	append(&ctx.id_stack, make_id(ctx, label))
}

push_id_int :: proc(ctx: ^Context, n: int) {
	seed: u32 = 2166136261
	if k := len(ctx.id_stack); k > 0 {
		seed = ctx.id_stack[k - 1]
	}
	v := u64(n)
	bytes := ([^]u8)(&v)[:8]
	h := hash.fnv32a(bytes, seed)
	append(&ctx.id_stack, h if h != 0 else 1)
}

pop_id :: proc(ctx: ^Context) {
	if len(ctx.id_stack) > 0 {
		pop(&ctx.id_stack)
	}
}

// What of a label is shown: up to "##". ("###" also: only what follows it makes the id, so a label that shows a count can keep its id.)
shown_label :: proc(label: string) -> string {
	if i := strings.index(label, "##"); i >= 0 {
		return label[:i]
	}
	return label
}

// ---- measures and drawing helpers ---------------------------------------------------------------------------------------------------

line_h :: proc(ctx: ^Context) -> int {
	return text.line_height(ctx.tf, ctx.size)
}

// The height of a row of widgets.
row_h :: proc(ctx: ^Context) -> int {
	return line_h(ctx) + 2 * ctx.theme.pad - 2
}

text_w :: proc(ctx: ^Context, s: string) -> int {
	return text.width(ctx.tf, s, ctx.size)
}

fill :: proc(ctx: ^Context, r: ui.Rect, c: ren.Color) {
	ren.draw_rect(ctx.dl, r, c)
}

outline :: proc(ctx: ^Context, r: ui.Rect, c: ren.Color) {
	ren.draw_rect_outline(ctx.dl, r, 1, c)
}

// Draws `s` with its line's top left at (x, y).
put_text :: proc(ctx: ^Context, s: string, x, y: int, c: ren.Color) -> int {
	return int(text.draw(ctx.dl, ctx.tf, s, {x, y}, ctx.size, c))
}

// Draws `s` centred vertically in `r`, from `x`, cut at the right edge of `r`.
put_text_in :: proc(ctx: ^Context, s: string, r: ui.Rect, c: ren.Color, align := ui.Align.Start) {
	if len(s) == 0 || r.w <= 0 {
		return
	}
	w := text_w(ctx, s)
	x := r.x
	switch align {
	case .Start:
	case .Center:
		x = r.x + (r.w - w) / 2
	case .End:
		x = r.x + r.w - w
	}
	if w > r.w { // too wide: start at the left, clipped
		x = r.x
	}
	y := r.y + (r.h - line_h(ctx)) / 2
	ren.push_clip(ctx.dl, r)
	text.draw(ctx.dl, ctx.tf, s, {x, y}, ctx.size, c)
	ren.pop_clip(ctx.dl)
}

with_alpha :: proc(c: ren.Color, a: u8) -> ren.Color {
	return {c.r, c.g, c.b, a}
}

// Is a pixel of the mouse inside the rect of a widget and visible, and is the widget one the mouse may act on now?
@(private)
hover_ok :: proc(ctx: ^Context, r: ui.Rect, chrome := false) -> bool {
	mx, my := int(ctx.input.mouse.x), int(ctx.input.mouse.y)
	if !ui.contains(r, mx, my) {
		return false
	}
	if ctx.in_overlay {
		return true
	}
	if ctx.modal != 0 || ctx.cur == nil || ctx.cur_id != ctx.mouse_window {
		return false
	}
	return chrome || ui.contains(ctx.layout.content, mx, my)
}

Behavior :: struct {
	hovered:  bool,
	pressed:  bool, // went down on it this frame
	held:     bool, // being held (it was pressed on it)
	released: bool, // went up this frame (after being pressed on it)
	clicked:  bool, // released while the mouse is still on it
}

// The mouse's dealings with one widget: press on it, hold, release on it.
behavior :: proc(ctx: ^Context, id: ID, r: ui.Rect, chrome := false) -> (b: Behavior) {
	b.hovered = hover_ok(ctx, r, chrome) && (ctx.active == 0 || ctx.active == id)
	if ctx.track_rects {
		ctx.rects[id] = r
	}
	ctx.last_id = id
	ctx.last_hovered = b.hovered
	if b.hovered {
		ctx.hot = id
		ctx.hover_seen = true
		if ctx.hover_id != id {
			ctx.hover_id = id
			ctx.hover_since = ctx.time
		}
		if ctx.active == 0 && ctx.input.pressed[.Left] {
			ctx.active = id
			b.pressed = true
		}
	}
	if ctx.active == id {
		b.held = ctx.input.down[.Left]
		if ctx.input.released[.Left] {
			ctx.active = 0
			b.released = true
			b.clicked = hover_ok(ctx, r, chrome)
			b.held = false
		}
	}
	return
}

@(private)
rounded :: proc(v: f32) -> int {
	return int(math.round(v))
}
