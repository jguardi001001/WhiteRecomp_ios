package main

import "core:math"
import "core:strings"
import rl "vendor:raylib"
import ui "shared:iv_ui"
import input "shared:iv_input"
import input_rl "shared:iv_input/raylib"

// ---------------------------------------------------------------------------
// Input of one frame, collected once in input_poll: the mouse in logical pixels,
// the typed characters (so that "H" and "$" work on any keyboard layout),
// and helpers for keys with auto-repeat.
// ---------------------------------------------------------------------------

BTN_L :: 0
BTN_R :: 1
BTN_M :: 2

Input :: struct {
	mx, my:                  int,
	dmx, dmy:                int, // mouse movement this frame
	down, pressed, released: [3]bool,
	dbl:                     bool, // the left button was pressed a second time quickly
	wheel_x, wheel_y:        f32, // whole notches (a precision touchpad's small steps are collected until they make one)
	chars:                   [dynamic]rune,
	ctrl, shift, alt:        bool,
	drops:                   [dynamic]string,
}

in_: Input

last_click_time: f64
last_click_x, last_click_y: int
wheel_acc: [2]f32
wheel_idle: int

// The mouse cursor the interface wants this frame (set while updating and drawing, applied at the end of the frame).
cursor_want: rl.MouseCursor
cursor_now: rl.MouseCursor

cursor_hint :: proc(c: rl.MouseCursor) {
	cursor_want = c
}

cursor_apply :: proc() {
	if cursor_want != cursor_now {
		rl.SetMouseCursor(cursor_want)
		cursor_now = cursor_want
	}
	cursor_want = .DEFAULT
}

// Reads this frame's input: the shared input module is told what raylib reports (input_rl.poll), and what the
// editor works with is worked out from it: the pointer in whole logical pixels, the wheel in notches, the double click,
// the typed characters, the modifiers. (Files dropped on the window are not input of the module: raylib hands them over.)
input_poll :: proc() {
	input_rl.poll(&ictx, ui_scale)
	nx := int(math.floor(ictx.mouse_x))
	ny := int(math.floor(ictx.mouse_y))
	in_.dmx = nx - in_.mx
	in_.dmy = ny - in_.my
	in_.mx = nx
	in_.my = ny
	buttons := [3]input.Mouse_Button{.Left, .Right, .Middle}
	for b in 0 ..< 3 {
		in_.down[b] = input.mouse_down(&ictx, buttons[b])
		in_.pressed[b] = input.mouse_pressed(&ictx, buttons[b])
		in_.released[b] = input.mouse_released(&ictx, buttons[b])
	}
	in_.dbl = false
	if in_.pressed[BTN_L] {
		t := now()
		if t - last_click_time < 0.4 && abs(in_.mx - last_click_x) < 5 && abs(in_.my - last_click_y) < 5 {
			in_.dbl = true
			last_click_time = 0
		} else {
			last_click_time = t
		}
		last_click_x = in_.mx
		last_click_y = in_.my
	}

	wx, wy := input.wheel(&ictx)
	if wx == 0 && wy == 0 {
		wheel_idle += 1
		if wheel_idle > 15 {
			wheel_acc = {}
		}
	} else {
		wheel_idle = 0
	}
	wheel_acc.x += wx
	wheel_acc.y += wy
	in_.wheel_x = math.trunc(wheel_acc.x)
	in_.wheel_y = math.trunc(wheel_acc.y)
	wheel_acc.x -= in_.wheel_x
	wheel_acc.y -= in_.wheel_y

	clear(&in_.chars)
	append(&in_.chars, ..input.typed(&ictx))
	mods := input.modifiers(&ictx)
	in_.ctrl = .Ctrl in mods
	in_.shift = .Shift in mods
	in_.alt = .Alt in mods

	for d in in_.drops {
		delete(d)
	}
	clear(&in_.drops)
	if rl.IsFileDropped() {
		files := rl.LoadDroppedFiles()
		for i in 0 ..< int(files.count) {
			append(&in_.drops, strings.clone_from_cstring(files.paths[i]))
		}
		rl.UnloadDroppedFiles(files)
	}
}

mouse_in :: proc(r: Rect) -> bool {
	return ui.contains(r, in_.mx, in_.my)
}
