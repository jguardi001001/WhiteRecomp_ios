package iv_input

// ---------------------------------------------------------------------------
// The state of every input device, as the program that uses this module reports it.
//
// The module never asks the hardware anything. Once per frame the program says what the devices are doing (from raylib,
// SDL, window messages, a recording, a test: it does not matter) and then asks about *signals* (bindings.odin), the things
// its own code cares about ("confirm", "jump", "pan the camera"):
//
//   Signal :: enum { UI_Confirm, UI_Back, Jump }            // the program's own names
//   ctx: input.Context(Signal)
//   binds := []input.Binding(Signal){                       // the program's own bindings, see bindings.odin
//       input.make_binding(Signal, .UI_Confirm, input.on_key(.Enter), input.on_pad_button(.Face_Down)),
//   }
//   input.use_bindings(&ctx, &binds)
//
//   // every frame:
//   input.begin_frame(&ctx)
//   input.set_key_state(&ctx, .A, {.Down, .Pressed})        // keyboard key A was pressed in this frame and is held
//   input.set_mouse_position(&ctx, 120, 80)
//   if input.signal_pressed(&ctx, .UI_Confirm) { ... }
//
// A frame, in order: begin_frame, then every set_* the backend has, then (for a gamepad that moves a cursor, nav.odin) the
// rectangles it may be on and update_nav, then the queries.
// ---------------------------------------------------------------------------

MAX_PADS :: 4
MAX_TYPED :: 32 // characters typed in one frame (more are dropped)

// All the state. Make one (`ctx: input.Context(My_Signal)`); the zero value is ready to use. `S` is the enum of the
// program's own signals.
Context :: struct($S: typeid) {
	keys:          [Key]State,
	mouse:         [Mouse_Button]State,
	pad_buttons:   [MAX_PADS][Gamepad_Button]State,
	pad_axes:      [MAX_PADS][Gamepad_Axis]f32,
	pad_axes_prev: [MAX_PADS][Gamepad_Axis]f32, // the values of the frame before (for the edges of axes that act as buttons)
	pad_connected: [MAX_PADS]bool,
	mouse_x:       f32,
	mouse_y:       f32,
	mouse_dx:      f32,
	mouse_dy:      f32,
	have_mouse:    bool, // a position was reported at least once (the first one is not a jump)
	wheel_x:       f32,
	wheel_y:       f32,
	typed:         [MAX_TYPED]rune,
	typed_count:   int,
	bindings:      ^[]Binding(S), // the program's own table (use_bindings): read on every query, so changing it changes the bindings at once
	bindings_dyn:  ^[dynamic]Binding(S), // the same, for a table that is a dynamic array
	nav:           Nav, // the gamepad as a pointer: rectangles in, a cursor out (nav.odin)
}

// Starts a frame: what happened in the last one is over. Pressed, Released and Repeat flags are cleared (a button that
// is held stays .Down), the mouse movement, the wheel and the typed characters are zeroed, and the axes are remembered
// so that a stick can act as a button.
begin_frame :: proc "contextless" (ctx: ^Context($S)) {
	for &s in ctx.keys {
		s &= {.Down}
	}
	for &s in ctx.mouse {
		s &= {.Down}
	}
	for p in 0 ..< MAX_PADS {
		for &s in ctx.pad_buttons[p] {
			s &= {.Down}
		}
	}
	ctx.pad_axes_prev = ctx.pad_axes
	ctx.mouse_dx = 0
	ctx.mouse_dy = 0
	ctx.wheel_x = 0
	ctx.wheel_y = 0
	ctx.typed_count = 0
}

// Forgets everything (every button up, no pad connected). The bindings stay, and so does the gamepad cursor (nav.odin). For when the window loses the focus, so
// that no key stays stuck.
reset_state :: proc "contextless" (ctx: ^Context($S)) {
	b, d, n := ctx.bindings, ctx.bindings_dyn, ctx.nav
	ctx^ = {}
	ctx.bindings, ctx.bindings_dyn, ctx.nav = b, d, n
}

// ---- reporting: keyboard -----------------------------------------------------------------------------

// Sets what a key is doing, as the backend knows it: {.Down, .Pressed} (it went down in this frame), {.Down} (held),
// {.Released} (it went up in this frame), {} (up).
set_key_state :: proc "contextless" (ctx: ^Context($S), key: Key, state: State) {
	ctx.keys[key] = state
}

// For a backend that only knows whether the key is down: the Pressed and Released of the frame are worked out from the
// change.
set_key_down :: proc "contextless" (ctx: ^Context($S), key: Key, down: bool) {
	ctx.keys[key] = next_state(ctx.keys[key], down)
}

// The operating system repeated the key (it is held): .Repeat is added (and .Down). The module's "repeated" queries count it.
set_key_repeat :: proc "contextless" (ctx: ^Context($S), key: Key) {
	ctx.keys[key] += {.Down, .Repeat}
}

// A character was typed (the text the keys make on the user's layout: "$", "é"): what a text box wants.
push_char :: proc "contextless" (ctx: ^Context($S), c: rune) {
	if ctx.typed_count < MAX_TYPED {
		ctx.typed[ctx.typed_count] = c
		ctx.typed_count += 1
	}
}

// ---- reporting: mouse -------------------------------------------------------------------------------

set_mouse_state :: proc "contextless" (ctx: ^Context($S), button: Mouse_Button, state: State) {
	ctx.mouse[button] = state
}

set_mouse_down :: proc "contextless" (ctx: ^Context($S), button: Mouse_Button, down: bool) {
	ctx.mouse[button] = next_state(ctx.mouse[button], down)
}

// Where the pointer is, in whatever units the program works in (pixels of the window, of its own scaled layout). The
// movement since the last report is worked out here; the first report is not a jump.
set_mouse_position :: proc "contextless" (ctx: ^Context($S), x, y: f32) {
	if ctx.have_mouse {
		ctx.mouse_dx += x - ctx.mouse_x
		ctx.mouse_dy += y - ctx.mouse_y
	}
	ctx.have_mouse = true
	ctx.mouse_x = x
	ctx.mouse_y = y
}

// The wheel turned (positive y: away from the user, up). Reports of one frame are added up.
add_wheel :: proc "contextless" (ctx: ^Context($S), x, y: f32) {
	ctx.wheel_x += x
	ctx.wheel_y += y
}

// ---- reporting: gamepads (`pad` is 0 .. MAX_PADS-1) -------------------------------------------------------

set_pad_connected :: proc "contextless" (ctx: ^Context($S), pad: int, connected: bool) {
	if pad < 0 || pad >= MAX_PADS {
		return
	}
	ctx.pad_connected[pad] = connected
	if !connected {
		ctx.pad_buttons[pad] = {}
		ctx.pad_axes[pad] = {}
		ctx.pad_axes_prev[pad] = {}
	}
}

set_pad_button_state :: proc "contextless" (ctx: ^Context($S), pad: int, button: Gamepad_Button, state: State) {
	if pad >= 0 && pad < MAX_PADS {
		ctx.pad_buttons[pad][button] = state
	}
}

set_pad_button_down :: proc "contextless" (ctx: ^Context($S), pad: int, button: Gamepad_Button, down: bool) {
	if pad >= 0 && pad < MAX_PADS {
		ctx.pad_buttons[pad][button] = next_state(ctx.pad_buttons[pad][button], down)
	}
}

set_pad_axis :: proc "contextless" (ctx: ^Context($S), pad: int, axis: Gamepad_Axis, value: f32) {
	if pad >= 0 && pad < MAX_PADS {
		ctx.pad_axes[pad][axis] = clamp(value, -1, 1)
	}
}

// ---- asking about devices ---------------------------------------------------------------------------

key_state :: proc "contextless" (ctx: ^Context($S), key: Key) -> State {
	return ctx.keys[key]
}

key_down :: proc "contextless" (ctx: ^Context($S), key: Key) -> bool {
	return .Down in ctx.keys[key]
}

key_pressed :: proc "contextless" (ctx: ^Context($S), key: Key) -> bool {
	return .Pressed in ctx.keys[key]
}

key_released :: proc "contextless" (ctx: ^Context($S), key: Key) -> bool {
	return .Released in ctx.keys[key]
}

// Pressed, or repeated by the operating system while it is held (what a text box or a list wants).
key_repeated :: proc "contextless" (ctx: ^Context($S), key: Key) -> bool {
	return card(ctx.keys[key] & {.Pressed, .Repeat}) > 0
}

mouse_state :: proc "contextless" (ctx: ^Context($S), button: Mouse_Button) -> State {
	return ctx.mouse[button]
}

mouse_down :: proc "contextless" (ctx: ^Context($S), button: Mouse_Button) -> bool {
	return .Down in ctx.mouse[button]
}

mouse_pressed :: proc "contextless" (ctx: ^Context($S), button: Mouse_Button) -> bool {
	return .Pressed in ctx.mouse[button]
}

mouse_released :: proc "contextless" (ctx: ^Context($S), button: Mouse_Button) -> bool {
	return .Released in ctx.mouse[button]
}

mouse_position :: proc "contextless" (ctx: ^Context($S)) -> (x, y: f32) {
	return ctx.mouse_x, ctx.mouse_y
}

mouse_delta :: proc "contextless" (ctx: ^Context($S)) -> (dx, dy: f32) {
	return ctx.mouse_dx, ctx.mouse_dy
}

wheel :: proc "contextless" (ctx: ^Context($S)) -> (x, y: f32) {
	return ctx.wheel_x, ctx.wheel_y
}

pad_state :: proc "contextless" (ctx: ^Context($S), pad: int, button: Gamepad_Button) -> State {
	if pad < 0 || pad >= MAX_PADS {
		return {}
	}
	return ctx.pad_buttons[pad][button]
}

pad_axis :: proc "contextless" (ctx: ^Context($S), pad: int, axis: Gamepad_Axis) -> f32 {
	if pad < 0 || pad >= MAX_PADS {
		return 0
	}
	return ctx.pad_axes[pad][axis]
}

pad_is_connected :: proc "contextless" (ctx: ^Context($S), pad: int) -> bool {
	return pad >= 0 && pad < MAX_PADS && ctx.pad_connected[pad]
}

// The characters typed in this frame (valid until the next begin_frame).
typed :: proc "contextless" (ctx: ^Context($S)) -> []rune {
	return ctx.typed[:ctx.typed_count]
}

// The modifiers that are down (either key of each).
modifiers :: proc "contextless" (ctx: ^Context($S)) -> Modifiers {
	m: Modifiers
	if .Down in ctx.keys[.Left_Shift] || .Down in ctx.keys[.Right_Shift] {
		m += {.Shift}
	}
	if .Down in ctx.keys[.Left_Ctrl] || .Down in ctx.keys[.Right_Ctrl] {
		m += {.Ctrl}
	}
	if .Down in ctx.keys[.Left_Alt] || .Down in ctx.keys[.Right_Alt] {
		m += {.Alt}
	}
	if .Down in ctx.keys[.Left_Super] || .Down in ctx.keys[.Right_Super] {
		m += {.Super}
	}
	return m
}

@(private)
next_state :: proc "contextless" (old: State, down: bool) -> State {
	was := .Down in old
	switch {
	case down && !was:
		return {.Down, .Pressed}
	case down:
		return {.Down}
	case was:
		// (pressed and released between two frames -- a quick click while the program draws few frames: the press
		// is kept, or the frame never sees it)
		return .Pressed in old ? {.Pressed, .Released} : {.Released}
	}
	return {}
}
