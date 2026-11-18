package iv_input

import "core:math"
import ui "../iv_ui"

// ---------------------------------------------------------------------------
// A gamepad as the pointer of a mouse-driven interface.
//
// The gamepad is reported like every other device (set_pad_connected, set_pad_button_state, set_pad_axis). On top of that the
// program says, every frame, WHERE on the screen the cursor of the gamepad may be: a buffer of rectangles (the buttons, rows and
// slots of the screen). The cursor is always at the middle of one of them. The module keeps up with which one it is on, and with
// the position of the cursor; the D-pad (or the left stick as a D-pad) moves it to the nearest rectangle in the direction pushed.
//
//   input.begin_frame(&ctx)
//   ... set_key_*, set_mouse_*, set_pad_* (or the backend's pump) ...
//
//   input.nav_begin(&ctx, window_size)                  // this frame's rectangles, in the px of the window
//   input.nav_rect(&ctx, new_game_button, default = true)    // (the one the cursor starts on: else the first)
//   input.nav_rect(&ctx, load_button)
//   input.nav_slider(&ctx, volume_rect, VOLUME, knob_x) // left and right turn it: nav_slider_step
//   change := input.update_nav(&ctx, dt)                // moves everything; tells when the gamepad becomes the main input
//
//   if input.nav_active(&ctx) { ... } // pad is the main input: ask nav_pointer (not the mouse) where the pointer is
//
// A gamepad that is only found does not count: it has to be used (a button, a stick or a trigger moved) first; then the module is
// ACTIVE (nav_active) until it is unplugged. The real mouse still works while it is: when it moves the cursor is where it is.
//
// No rectangles, no cursor: a frame without `nav_begin` is a frame with no rectangles, and so is a screen that is being changed.
// When rectangles come back the cursor is put on the one the program marked as the default (`default = true`), else the first.
// The rectangles of the frame before are not kept, but the cursor is: when the same number of rectangles comes back it stays on the
// one it was on (a list that scrolls, a menu that moves with its block); when the number is not the same it stays where it is and
// takes the rectangle that holds that point, or the nearest one.
//
// Nothing here touches a window. What the operating system has to be told (hide its cursor, put the real mouse where the cursor
// was) is the program's: `update_nav` returns a `Nav_Change`. The cursor is drawn by `iv_input/cursor` (on or off with
// `nav_show_cursor`; this module only says where and what).
// ---------------------------------------------------------------------------

NAV_RECT_MAX :: 256 // rectangles in a frame; more are ignored

// The knobs. `Nav_Config{}` (all zero) means NAV_DEFAULT_CONFIG; `nav_configure` changes them.
Nav_Config :: struct {
	deadzone:       f32, // how far a stick is pushed before it counts as a direction (as a D-pad, or as the wheel)
	stick_deadzone: f32, // ... and before `nav_stick` moves anything (the length then goes from 0 at this to 1 at the rim)
	zoom_deadzone:  f32, // ... and for the right stick's smooth zoom
	speed_min:      f32, // the free cursor's speed when it starts to move (px a second) ...
	speed_max:      f32, // ... and after `ramp` seconds of holding the direction
	ramp:           f32,
	wheel_repeat:   f32, // seconds between the steps of the wheel while the right stick is held
	cursor_rate:    f32, // the picture of the cursor closes the distance to its rectangle as 1 - e^(-rate * t): nine tenths in 0.08 s
	step_first:     f32, // seconds before a held direction steps again ...
	step_repeat:    f32, // ... and between the steps then
	cursor_height:  f32, // how high the arrow is, in px, at a size scale of 1
}

NAV_DEFAULT_CONFIG :: Nav_Config {
	deadzone       = 0.4,
	stick_deadzone = 0.2,
	zoom_deadzone  = 0.2,
	speed_min      = 70,
	speed_max      = 260,
	ramp           = 0.7,
	wheel_repeat   = 0.14,
	cursor_rate    = 30,
	step_first     = 0.32,
	step_repeat    = 0.12,
	cursor_height  = 28,
}

// What `update_nav` found out about the gamepad as the main input.
Nav_Change :: enum u8 {
	None,
	Entered, // a gamepad is the main input now: hide the system's cursor (the cursor starts where the mouse was, or in the middle)
	Left, // the mouse is the input again: show the system's cursor where `nav_position` is (put the real mouse there)
}

// One rectangle of the frame.
Nav_Rect :: struct {
	r:      ui.Rect,
	at:     [2]f32, // where the cursor goes on it: the middle (the knob's place on a slider)
	slider: int, // not 0: a slider (the number is the program's own)
}

// What a program needs to draw the cursor (iv_input/cursor does it).
Nav_Cursor :: struct {
	visible: bool,
	at:      [2]f32, // the tip, in px (it glides to its rectangle)
	hand:    bool, // a pointing hand, not an arrow
	height:  f32, // of the arrow at a size scale of 1
}

// The state of the gamepad cursor: part of the `Context` (`ctx.nav`). Everything has a use of its own below; the fields are open to read.
Nav :: struct {
	cfg:           Nav_Config,

	// what the program asks for (the procedures `nav_show_cursor`, `nav_free_cursor`, `nav_rest_at`, `nav_stick_zoom`, `nav_hand`)
	cursor_hidden: bool,
	free_ok:       bool,
	free_scale:    f32,
	rest:          [2]f32,
	has_rest:      bool,
	stick_zooms:   bool,
	hand:          bool,

	// the gamepad
	pad:           int, // the one in use (when `has_pad`)
	has_pad:       bool,
	awake:         bool, // it has been used since it was found
	active:        bool, // there is one and it is awake: the gamepad is the main input
	axes_rest:     [Gamepad_Axis]f32, // where its axes rest (triggers rest at -1 on some): read in the frames after it was found
	axes_rest_set: bool,
	axes_wait:     int, // frames to go before they are read

	// the cursor
	pos:           [2]f32, // where it is
	pos_prev:      [2]f32, // ... and where it was before this frame's `update_nav`
	draw_at:       [2]f32, // where its picture is (glides to `pos`)
	mouse_prev:    [2]f32, // where the real mouse was last frame
	snap:          bool, // `pos` is the middle of the rectangle it is on (else it follows the mouse)
	focus:         int, // the rectangle it is on, when `has_focus`
	has_focus:     bool,
	hold:          f32, // how long a direction has been held by the free cursor (it speeds up)
	dir:           [2]f32, // the direction held, for the repeat
	dir_t:         f32,
	wheel:         f32, // this frame's wheel (+1 up): the right stick, or a list that has no more rectangles that way
	wheel_t:       f32,
	zoom:          f32, // this frame's smooth zoom of the right stick, +1 up (while `stick_zooms`)
	slider:        int, // this frame's turn of a slider (`nav_slider_step`)
	slider_dir:    int,

	// the rectangles
	rects:         [NAV_RECT_MAX]Nav_Rect,
	count:         int,
	default_rect:  int,
	has_default:   bool,
	scrolls:       bool, // the screen has a list that scrolls
	screen:        int, // what the screen is: when it changes the cursor goes to the default rectangle
	screen_seen:   int,
	window:        [2]f32, // the window's size
	pending:       bool, // rectangles were submitted and are not yet taken in
	fresh:         bool, // ... this frame
	populated:     bool, // the last rectangles taken in were not none
	prev_count:    int,
}

// ---- what the program asks for -----------------------------------------------------------------------------------------------

// Changes the knobs.
nav_configure :: proc "contextless" (ctx: ^Context($S), cfg: Nav_Config) {
	ctx.nav.cfg = cfg
}

// Whether the cursor is drawn at all (on to start with). Only the picture: the cursor moves, and the rectangles work, either way.
nav_show_cursor :: proc "contextless" (ctx: ^Context($S), on: bool) {
	ctx.nav.cursor_hidden = !on
}

// With no rectangles, a free cursor (a map to point at, not a screen of buttons) that the stick and the D-pad move at a speed that grows while
// they are held. `scale` multiplies the speed (the size of the program's px in window px). Off to start with: no rectangles, no cursor.
nav_free_cursor :: proc "contextless" (ctx: ^Context($S), on: bool, scale: f32 = 1) {
	ctx.nav.free_ok = on
	ctx.nav.free_scale = scale
}

// Where the cursor is put while there are no rectangles and it is not free (the middle of a world that the wheel zooms about, say). `nil`:
// it stays where it was.
nav_rest_at :: proc "contextless" (ctx: ^Context($S), at: Maybe([2]f32)) {
	ctx.nav.rest, ctx.nav.has_rest = at.? // (nil: has_rest false)
}

// The right stick zooms smoothly (`nav_zoom`: how far it is pushed) in place of turning the wheel in steps (`nav_wheel`).
nav_stick_zoom :: proc "contextless" (ctx: ^Context($S), on: bool) {
	ctx.nav.stick_zooms = on
}

// The cursor is over something that can be clicked (the program says so every frame): the cursor is a pointing hand.
nav_hand :: proc "contextless" (ctx: ^Context($S), on: bool) {
	ctx.nav.hand = on
}

// ---- the rectangles of the frame ---------------------------------------------------------------------------------------------

// Starts this frame's rectangles (and forgets the last frame's). `window` is the window's size, in the px the rectangles and the mouse are in.
// Can be called more than once a frame (after the picture is made, to say where the rectangles went: see `nav_end`).
nav_begin :: proc "contextless" (ctx: ^Context($S), window: [2]f32) {
	n := &ctx.nav
	n.count = 0
	n.has_default = false
	n.scrolls = false
	n.screen = 0
	n.window = window
	n.pending = true
	n.fresh = true
}

// What the screen is, as a number of the program's own: when it changes with the rectangles still there (a dialog that opens over the
// screen) the cursor goes to the default rectangle, as if they had gone and come back.
nav_screen :: proc "contextless" (ctx: ^Context($S), id: int) {
	ctx.nav.screen = id
}

// The screen has a list that scrolls: when the D-pad is pushed up or down and there is no more rectangle that way, `nav_wheel` turns.
nav_scrolls :: proc "contextless" (ctx: ^Context($S)) {
	ctx.nav.scrolls = true
}

// Adds a rectangle (in the px of the window): the cursor goes to its middle. `default`: the cursor starts here when the rectangles
// come back (the first one marked wins; none marked: the first rectangle).
nav_rect :: proc "contextless" (ctx: ^Context($S), r: ui.Rect, default := false) {
	nav_push(&ctx.nav, r, {f32(r.x) + f32(r.w) / 2, f32(r.y) + f32(r.h) / 2}, 0, default)
}

// A slider: left and right turn it (`nav_slider_step`) and up and down go on. `slider` is the program's own number for it (not 0); the cursor
// goes to the knob, at `knob_x` (in px of the window), not to the middle. Submit it again as it turns: the cursor follows the knob.
nav_slider :: proc "contextless" (ctx: ^Context($S), r: ui.Rect, slider: int, knob_x: f32, default := false) {
	nav_push(&ctx.nav, r, {knob_x, f32(r.y) + f32(r.h) / 2}, slider, default)
}

// The rectangles are all in: the cursor stays with its rectangle (or finds another, see the top), now. `update_nav` does it for the rectangles
// it finds; call this after a second `nav_begin` of the frame.
nav_end :: proc "contextless" (ctx: ^Context($S)) {
	nav_commit(&ctx.nav)
}

@(private)
nav_push :: proc "contextless" (n: ^Nav, r: ui.Rect, at: [2]f32, slider: int, default: bool) {
	if n.count >= NAV_RECT_MAX || r.w <= 0 || r.h <= 0 {
		return
	}
	if default && !n.has_default {
		n.default_rect = n.count
		n.has_default = true
	}
	n.rects[n.count] = Nav_Rect{r, at, slider}
	n.count += 1
}

// ---- the frame ---------------------------------------------------------------------------------------------------------------

// Every frame, after the devices were reported and the rectangles submitted: finds a gamepad and sees whether it is in use, moves the cursor
// (a step to the next rectangle, a slider turned, the free cursor, the real mouse taking it) and the wheel. Returns what changed about the
// main input. Call it once a frame; the frame's rectangles are used up by it (a frame that does not submit any has none).
update_nav :: proc "contextless" (ctx: ^Context($S), dt: f32) -> Nav_Change {
	n := &ctx.nav
	if n.pending {
		nav_commit(n)
	}
	if !n.fresh {
		n.count = 0 // (nothing was submitted: nothing is on the screen)
		nav_commit(n)
	}
	n.fresh = false
	n.wheel = 0
	n.zoom = 0
	n.slider = 0
	n.pos_prev = n.pos

	mouse := [2]f32{ctx.mouse_x, ctx.mouse_y}
	change := nav_find_pad(ctx, mouse)
	if change == .Entered {
		n.populated = false // (the cursor has been out of sight: it comes up on the default rectangle)
		nav_commit(n)
	}
	if !n.active {
		return change
	}
	cfg := nav_conf(n)

	// The real mouse, if it moves, takes the cursor with it.
	moved := false
	if mouse != n.mouse_prev {
		moved = ctx.have_mouse && nav_inside(n, mouse)
		n.mouse_prev = mouse
	}
	if n.count > 0 {
		if moved {
			n.pos = mouse
			n.snap = false
			n.focus = nav_holding(n, mouse)
			n.has_focus = n.focus >= 0
			n.draw_at = mouse
			n.dir = {}
		} else {
			nav_step(n, nav_direction(ctx), dt)
		}
		// The cursor is on its rectangle at once; its picture glides.
		goal := n.pos
		k := 1 - math.exp_f32(-cfg.cursor_rate * dt)
		n.draw_at += (goal - n.draw_at) * k
		if abs(goal.x - n.draw_at.x) + abs(goal.y - n.draw_at.y) < 0.5 {
			n.draw_at = goal
		}
		n.pos_prev = goal
	} else if n.free_ok {
		if moved {
			n.pos = mouse
			n.pos_prev = mouse
		}
		d := nav_direction(ctx)
		if d == {} {
			n.hold = 0
		} else {
			n.hold += dt
			if d.x != 0 && d.y != 0 {
				d *= 0.70710678
			}
			scale := n.free_scale if n.free_scale > 0 else 1
			n.pos += d * math.lerp(cfg.speed_min, cfg.speed_max, min(n.hold / cfg.ramp, 1)) * scale * dt
		}
		if n.window != {} {
			n.pos.x = clamp(n.pos.x, 0, n.window.x - 1)
			n.pos.y = clamp(n.pos.y, 0, n.window.y - 1)
		}
		n.draw_at = n.pos
		n.dir = {}
	} else {
		if n.has_rest {
			n.pos = n.rest
			n.pos_prev = n.pos
		}
		n.dir = {}
	}

	// The right stick, up and down, is the wheel (a step at a time while it is held); or it zooms smoothly instead, as far as it is pushed
	// (the zoom keeps changing as long as it is held and settles on a level when it is let go).
	sy := pad_axis(ctx, n.pad, .Right_Y)
	if n.stick_zooms {
		n.wheel_t = 0
		if abs(sy) > cfg.zoom_deadzone {
			n.zoom = (abs(sy) - cfg.zoom_deadzone) / (1 - cfg.zoom_deadzone) * (1 if sy < 0 else -1)
		}
	} else if abs(sy) > cfg.deadzone {
		n.wheel_t -= dt
		if n.wheel_t <= 0 {
			n.wheel = 1 if sy < 0 else -1
			n.wheel_t = cfg.wheel_repeat
		}
	} else {
		n.wheel_t = 0
	}
	return change
}

// Takes the submitted rectangles in: the cursor stays with its rectangle (or finds another, or goes to the default one).
@(private)
nav_commit :: proc "contextless" (n: ^Nav) {
	n.pending = false
	if n.count == 0 {
		n.populated = false
		n.has_focus = false
		n.prev_count = 0
		n.dir = {}
		return
	}
	reseat := !n.populated || n.screen != n.screen_seen
	n.screen_seen = n.screen
	switch {
	case reseat:
		if !n.populated {
			n.draw_at = n.window / 2 // (it comes up from the middle of the window)
		}
		nav_focus_on(n, n.default_rect if n.has_default else 0)
		n.dir = {}
	case n.snap:
		i := n.focus
		if !n.has_focus || n.count != n.prev_count {
			i = nav_holding(n, n.pos)
			if i < 0 {
				i = nav_nearest(n, n.pos)
			}
		}
		before := n.pos
		nav_focus_on(n, i)
		n.draw_at += n.pos - before // (the picture goes with the rectangle: it does not glide after it)
		n.pos_prev = n.pos
	case:
		n.focus = nav_holding(n, n.pos) // (the mouse has it: the rectangle under it, if any)
		n.has_focus = n.focus >= 0
	}
	n.populated = true
	n.prev_count = n.count
}

@(private)
nav_conf :: proc "contextless" (n: ^Nav) -> Nav_Config {
	if n.cfg == (Nav_Config{}) {
		return NAV_DEFAULT_CONFIG
	}
	return n.cfg
}

@(private)
nav_inside :: proc "contextless" (n: ^Nav, p: [2]f32) -> bool {
	return n.window == {} || (p.x >= 0 && p.y >= 0 && p.x < n.window.x && p.y < n.window.y)
}

// The cursor is put on rectangle `i`.
@(private)
nav_focus_on :: proc "contextless" (n: ^Nav, i: int) {
	n.focus = i
	n.has_focus = true
	n.snap = true
	n.pos = n.rects[i].at
}

// The smallest rectangle that holds `p`, or -1.
@(private)
nav_holding :: proc "contextless" (n: ^Nav, p: [2]f32) -> int {
	best := -1
	best_area := max(int)
	for i in 0 ..< n.count {
		r := n.rects[i].r
		if p.x >= f32(r.x) && p.x < f32(r.x + r.w) && p.y >= f32(r.y) && p.y < f32(r.y + r.h) && r.w * r.h < best_area {
			best_area = r.w * r.h
			best = i
		}
	}
	return best
}

// The rectangle whose cursor point is nearest to `p`.
@(private)
nav_nearest :: proc "contextless" (n: ^Nav, p: [2]f32) -> int {
	best := 0
	best_d := f32(1e30)
	for i in 0 ..< n.count {
		d := n.rects[i].at - p
		if s := d.x * d.x + d.y * d.y; s < best_d {
			best_d = s
			best = i
		}
	}
	return best
}

// The rectangle nearest to `from` in direction `d` (the stronger axis of it), skipping `skip`, or -1: how far its near edge is along the way
// plus three times how far it is off to the side.
nav_pick :: proc "contextless" (n: ^Nav, from: [2]f32, skip: int, d: [2]f32) -> int {
	horizontal := abs(d.x) > abs(d.y)
	sign := f32(1)
	if horizontal && d.x < 0 || !horizontal && d.y < 0 {
		sign = -1
	}
	best := -1
	best_s := f32(1e30)
	for i in 0 ..< n.count {
		if i == skip {
			continue
		}
		r := n.rects[i].r
		x0, x1, y0, y1 := f32(r.x), f32(r.x + r.w), f32(r.y), f32(r.y + r.h)
		along, side: f32
		if horizontal {
			along = (x0 - from.x) if sign > 0 else (from.x - x1)
			side = max(y0 - from.y, from.y - y1, 0)
		} else {
			along = (y0 - from.y) if sign > 0 else (from.y - y1)
			side = max(x0 - from.x, from.x - x1, 0)
		}
		if along < 0 {
			continue
		}
		if score := along + 3 * side; score < best_s {
			best_s = score
			best = i
		}
	}
	return best
}

// What the cursor does this frame with its direction `d` (held or not): a step to another rectangle, or a slider turned.
@(private)
nav_step :: proc "contextless" (n: ^Nav, d: [2]f32, dt: f32) {
	if d == {} {
		n.dir = {}
		n.dir_t = 0
		return
	}
	cfg := nav_conf(n)
	step := false
	if d != n.dir {
		step = true
		n.dir_t = cfg.step_first
	} else {
		n.dir_t -= dt
		if n.dir_t <= 0 {
			step = true
			n.dir_t = cfg.step_repeat
		}
	}
	n.dir = d
	if !step {
		return
	}
	cur := n.focus if n.has_focus else -1
	if cur >= 0 && n.rects[cur].slider != 0 && abs(d.x) > abs(d.y) {
		// a slider: left and right turn it, up and down go on to the next one
		n.slider = n.rects[cur].slider
		n.slider_dir = 1 if d.x > 0 else -1
		return
	}
	if next := nav_pick(n, n.pos, cur, d); next >= 0 {
		nav_focus_on(n, next)
	} else if n.scrolls && abs(d.y) >= abs(d.x) {
		n.wheel = 1 if d.y < 0 else -1 // (nothing more that way on the screen: the list scrolls)
	}
}

// ---- the gamepad -------------------------------------------------------------------------------------------------------------

// Finds the gamepad in use (the one that is, else the first that is connected), sees whether it has been used, and says when the gamepad
// becomes the main input or stops being it.
@(private)
nav_find_pad :: proc "contextless" (ctx: ^Context($S), mouse: [2]f32) -> Nav_Change {
	n := &ctx.nav
	found := -1
	if n.has_pad && pad_is_connected(ctx, n.pad) {
		found = n.pad
	} else {
		for id in 0 ..< MAX_PADS {
			if pad_is_connected(ctx, id) {
				found = id
				break
			}
		}
	}
	if found != (n.pad if n.has_pad else -1) { // (another device, or none: it has to be used before it counts)
		n.awake = false
		n.axes_rest_set = false
		n.axes_wait = 4 // (the system has not read the device yet in the first frames: its axes say 0 until it has)
	}
	n.has_pad = found >= 0
	n.pad = max(found, 0)
	if n.has_pad && !n.awake {
		nav_check_awake(ctx)
	}
	// A device can be found that is not there to play with (a controller that is paired but switched off, something that only looks like one to
	// the system): the gamepad is the main input once it is used, not when it is just found.
	active := n.has_pad && n.awake
	if active == n.active {
		return .None
	}
	n.active = active
	n.hold = 0
	n.wheel_t = 0
	n.dir = {}
	if active {
		n.pos = mouse if ctx.have_mouse && nav_inside(n, mouse) else n.window / 2 // (it starts where the mouse is)
		n.pos_prev = n.pos
		n.mouse_prev = mouse
		return .Entered
	}
	return .Left
}

// A gamepad that is found but not used yet: any button, or an axis that has moved away from where it rests, wakes it.
@(private)
nav_check_awake :: proc "contextless" (ctx: ^Context($S)) {
	n := &ctx.nav
	if !n.axes_rest_set {
		if n.axes_wait > 0 {
			n.axes_wait -= 1
			return
		}
		for a in Gamepad_Axis {
			n.axes_rest[a] = pad_axis(ctx, n.pad, a)
		}
		n.axes_rest_set = true
		return
	}
	for b in Gamepad_Button {
		if .Down in pad_state(ctx, n.pad, b) {
			n.awake = true
			return
		}
	}
	for a in Gamepad_Axis {
		if abs(pad_axis(ctx, n.pad, a) - n.axes_rest[a]) > 0.5 {
			n.awake = true
			return
		}
	}
}

// The direction the D-pad and the left stick hold: -1, 0 or 1 on each axis (y down). The stick has a dead zone and counts only while the
// D-pad is not held.
@(private)
nav_direction :: proc "contextless" (ctx: ^Context($S)) -> [2]f32 {
	n := &ctx.nav
	d: [2]f32
	if !n.has_pad {
		return d
	}
	if .Down in pad_state(ctx, n.pad, .Dpad_Left) {
		d.x -= 1
	}
	if .Down in pad_state(ctx, n.pad, .Dpad_Right) {
		d.x += 1
	}
	if .Down in pad_state(ctx, n.pad, .Dpad_Up) {
		d.y -= 1
	}
	if .Down in pad_state(ctx, n.pad, .Dpad_Down) {
		d.y += 1
	}
	if d == {} {
		dead := nav_conf(n).deadzone
		sx := pad_axis(ctx, n.pad, .Left_X)
		sy := pad_axis(ctx, n.pad, .Left_Y)
		if abs(sx) > dead {
			d.x = 1 if sx > 0 else -1
		}
		if abs(sy) > dead {
			d.y = 1 if sy > 0 else -1
		}
	}
	return d
}

// ---- asking -------------------------------------------------------------------------------------------------------------------

// Is a gamepad the main input (found, and used)?
nav_active :: proc "contextless" (ctx: ^Context($S)) -> bool {
	return ctx.nav.active
}

// The gamepad in use (0 .. MAX_PADS-1), or -1 when there is none.
nav_pad :: proc "contextless" (ctx: ^Context($S)) -> int {
	return ctx.nav.pad if ctx.nav.has_pad else -1
}

// Where the cursor is, whether it is shown or not.
nav_position :: proc "contextless" (ctx: ^Context($S)) -> [2]f32 {
	return ctx.nav.pos
}

// Where the pointer is: the cursor while a gamepad is the main input, else the mouse.
nav_pointer :: proc "contextless" (ctx: ^Context($S)) -> [2]f32 {
	return ctx.nav.pos if ctx.nav.active else [2]f32{ctx.mouse_x, ctx.mouse_y}
}

// How far the pointer moved this frame: the cursor, or the mouse.
nav_pointer_delta :: proc "contextless" (ctx: ^Context($S)) -> [2]f32 {
	return ctx.nav.pos - ctx.nav.pos_prev if ctx.nav.active else [2]f32{ctx.mouse_dx, ctx.mouse_dy}
}

// The rectangle (of this frame's, in the order submitted) the cursor is on, or -1 (none: the mouse is over nothing, or there are none).
nav_focus :: proc "contextless" (ctx: ^Context($S)) -> int {
	return ctx.nav.focus if ctx.nav.has_focus && ctx.nav.populated else -1
}

// The wheel of the gamepad this frame (+1 up, -1 down, in steps): the right stick, or a list that has no more rectangles that way.
nav_wheel :: proc "contextless" (ctx: ^Context($S)) -> f32 {
	return ctx.nav.wheel
}

// How far the right stick is pushed up (+1) or down (-1) past its dead zone, while `nav_stick_zoom` is on.
nav_zoom :: proc "contextless" (ctx: ^Context($S)) -> f32 {
	return ctx.nav.zoom
}

// A slider was turned this frame: its number, and -1 (left) or 1 (right). The program turns it.
nav_slider_step :: proc "contextless" (ctx: ^Context($S)) -> (slider: int, dir: int, ok: bool) {
	return ctx.nav.slider, ctx.nav.slider_dir, ctx.nav.slider != 0
}

// The left stick as it is pushed, in any direction: the length is 0 inside the dead zone and goes to 1 at the rim.
nav_stick :: proc "contextless" (ctx: ^Context($S)) -> [2]f32 {
	n := &ctx.nav
	if !n.has_pad {
		return {}
	}
	dead := nav_conf(n).stick_deadzone
	s := [2]f32{pad_axis(ctx, n.pad, .Left_X), pad_axis(ctx, n.pad, .Left_Y)}
	m := math.sqrt_f32(s.x * s.x + s.y * s.y)
	if m < dead {
		return {}
	}
	return s / m * ((min(m, 1) - dead) / (1 - dead))
}

// What to draw: see iv_input/cursor.
nav_cursor :: proc "contextless" (ctx: ^Context($S)) -> Nav_Cursor {
	n := &ctx.nav
	shown := n.active && !n.cursor_hidden && (n.populated || n.free_ok)
	return Nav_Cursor{visible = shown, at = n.draw_at if n.populated else n.pos, hand = n.hand || n.populated, height = nav_conf(n).cursor_height}
}
