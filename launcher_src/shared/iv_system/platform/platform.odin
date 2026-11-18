package platform

import input "../../iv_input"

// ---------------------------------------------------------------------------
// platform: windows and the events that come with them, for every operating system the same. The operating system's
// part is in platform_<os>.odin (platform_windows.odin: Win32; platform_linux.odin: Wayland, with wayland_linux.odin and
// xkb_linux.odin); this file is what is the same everywhere, including how the window's input events are handed to the
// `input` package.
//
// What every platform file provides: create_window, destroy_window, recreate_window, poll, set_title, set_fullscreen,
// set_size, set_visible, maximize, restore, minimize, set_decorated, set_resizable, set_always_on_top, begin_move,
// begin_resize, native_handle, time_seconds; the mouse cursor
// (set_cursor_visible, set_cursor_shape, set_mouse_position); the clipboard (clipboard_text, set_clipboard_text); and
// read_gamepads (which feed_input uses).
//
//   w, ok := platform.create_window({title = "Hello", width = 1280, height = 720})
//   for !w.close_requested {
//       events := platform.poll(w)                  // the messages of the operating system, once per frame
//       platform.feed_input(w, &ctx)                // the keys, mouse and typed text of this frame into an input.Context
//       if .Resized in events { ... w.size ... }
//   }
//   platform.destroy_window(w)
//
// `platform` knows nothing of rendering. It only says where the window is (native_handle) and how big (size, in pixels).
// ---------------------------------------------------------------------------

// How a window starts, and (through set_decorated, set_resizable, set_always_on_top, maximize, set_fullscreen) how it can change. The empty set is the
// ordinary window: a title bar and borders, resizable, not maximized, shown. So every flag says what is *different*.
Window_Flag :: enum u8 {
	No_Decorations, // no title bar and no border: the program draws its own (set_hit_test says where the caption is; begin_move / begin_resize do it by hand)
	Fixed_Size, // the user cannot resize it (and there is no maximize)
	Maximized, // start maximized
	Fullscreen, // start borderless fullscreen
	Hidden, // created without showing it (tests, tools; set_visible shows it). Wayland has no hidden windows: a window appears when something is drawn into it
	Always_On_Top, // above the other windows (Windows only: Wayland has no such thing)
	No_Activate, // shown without taking the focus, behind the other windows (a program run by a test or a tool while someone works; Windows only)
}

Window_Flags :: bit_set[Window_Flag;u8]

Window_Desc :: struct {
	title:      string,
	width:      int, // the size of the client area (what can be drawn into), in pixels
	height:     int,
	min_width:  int, // 0 = no limit
	min_height: int,
	flags:      Window_Flags,
	app_id:     string, // Wayland: names the program to the desktop (matches its .desktop file); "" = "iv_system"
	background: Maybe([3]u8), // Windows: the colour the window is filled with as soon as it appears, until the program says it draws (stop_background)
}

// What a point of a window without decorations is, for the operating system: the program answers with `set_hit_test`.
Hit_Region :: enum u8 {
	Client, // an ordinary part of the window: mouse events come to the program
	Caption, // the title bar: dragging it moves the window, a double click maximizes or restores it, and the program sees no mouse events there
}

// Where is the point (x, y), in client pixels? Called by the window system, possibly while the user drags the window, so it must be quick and must
// not draw or touch the program's input. `user` is what was given to set_hit_test.
Hit_Test_Proc :: #type proc(w: ^Window, x, y: int, user: rawptr) -> Hit_Region

// What the mouse cursor looks like over the window.
Cursor_Shape :: enum u8 {
	Default, // the arrow
	Hand, // over something that can be clicked
	Text, // the I beam
	Crosshair,
	Resize_Horizontal, // the double arrow left-right: over the border that can be dragged sideways
}

// The answer to ask_save_changes.
Save_Answer :: enum u8 {
	Save,
	Discard,
	Cancel,
}

// A font family installed on the system (list_font_families). `font_data` gives the bytes of its regular face.
Font_Family :: struct {
	name:      string,
	monospace: bool, // every character is as wide as every other (what code is written in)
}

// The edges and corners a window is resized from (begin_resize).
Resize_Edge :: enum u8 {
	Left,
	Right,
	Top,
	Bottom,
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
}

// What happened to the window since the last poll.
Window_Event :: enum u8 {
	Close_Requested, // the user pressed the close button / Alt+F4: the window is NOT destroyed, the program decides
	Resized, // the client size changed (window.size is the new one)
	Focus_Gained,
	Focus_Lost, // (the input state is reset)
	Minimized,
	Restored,
	Dpi_Changed, // window.dpi_scale changed (the window moved to another monitor, or the setting changed)
}

Window_Events :: bit_set[Window_Event;u8]

// The operating system's own window handle, for whoever draws into the window (a graphics backend).
Native_Handle :: struct {
	window:  rawptr, // Windows: HWND
	display: rawptr, // Windows: HINSTANCE
}

// What the window's input looked like, in order; feed_input replays it into the input package.
Input_Event_Kind :: enum u8 {
	Key_Down,
	Key_Up,
	Key_Repeat,
	Char,
	Mouse_Down,
	Mouse_Up,
	Mouse_Move,
	Wheel,
	Focus_Lost, // forget everything that is held
}

Input_Event :: struct {
	kind:   Input_Event_Kind,
	key:    input.Key,
	button: input.Mouse_Button,
	char:   rune,
	x, y:   f32, // Mouse_Move: the position in client pixels; Wheel: the notches turned (y: away from the user is positive)
}

Window :: struct {
	desc:            Window_Desc, // what it was created with (title, size limits)
	size:            [2]int, // the client area in pixels
	dpi_scale:       f32, // 1 = 96 dpi
	focused:         bool,
	minimized:       bool,
	maximized:       bool, // (not while minimized from a maximized window: it is what the window goes back to)
	fullscreen:      bool,
	decorated:       bool, // the window system draws a title bar and borders (not in fullscreen, not with No_Decorations). On Wayland a compositor may leave that to the program: then this is false and begin_move / begin_resize are how a custom title bar and edges work
	hit_test:        Hit_Test_Proc, // set_hit_test; nil = the whole client area is the client
	hit_test_user:   rawptr,
	mouse_inside:    bool, // the mouse cursor is over the window's client area
	cursor_hidden:   bool, // set_cursor_visible(false)
	cursor_shape:    Cursor_Shape,
	close_requested: bool, // set by the close button; stays set until the program clears it
	events:          Window_Events, // collected by poll, handed out and cleared by poll
	input:           [dynamic]Input_Event, // collected by poll, replayed and cleared by feed_input
	using native:    _Native, // the operating system's part
}

// What a gamepad is doing, as the operating system reports it: the buttons by place (iv_input's names), the sticks and
// triggers as iv_input has them (-1 .. 1 with left and up negative; triggers 0 .. 1). The triggers also count as buttons.
Pad_State :: struct {
	connected: bool,
	buttons:   [input.Gamepad_Button]bool,
	axes:      [input.Gamepad_Axis]f32,
}

// Reports what the gamepads are doing to `ctx` (the first input.MAX_PADS pads; a disconnected one reports nothing).
apply_gamepads :: proc(ctx: ^input.Context($S), pads: ^[input.MAX_PADS]Pad_State) {
	for &pad, i in pads {
		input.set_pad_connected(ctx, i, pad.connected)
		if !pad.connected {
			continue
		}
		for down, button in pad.buttons {
			input.set_pad_button_down(ctx, i, button, down)
		}
		for value, axis in pad.axes {
			input.set_pad_axis(ctx, i, axis, value)
		}
	}
}

// Starts an input frame (input.begin_frame) and replays this window's keys, mouse and typed text, in the order they
// happened, into `ctx`; the gamepads are read and reported too. Call it once per frame, after poll.
feed_input :: proc(w: ^Window, ctx: ^input.Context($S)) {
	input.begin_frame(ctx)
	{
		pads: [input.MAX_PADS]Pad_State
		read_gamepads(&pads)
		apply_gamepads(ctx, &pads)
	}
	for e in w.input {
		switch e.kind {
		case .Key_Down:
			input.set_key_down(ctx, e.key, true)
		case .Key_Up:
			input.set_key_down(ctx, e.key, false)
		case .Key_Repeat:
			input.set_key_repeat(ctx, e.key)
		case .Char:
			input.push_char(ctx, e.char)
		case .Mouse_Down:
			input.set_mouse_down(ctx, e.button, true)
		case .Mouse_Up:
			input.set_mouse_down(ctx, e.button, false)
		case .Mouse_Move:
			input.set_mouse_position(ctx, e.x, e.y)
		case .Wheel:
			input.add_wheel(ctx, e.x, e.y)
		case .Focus_Lost:
			input.reset_state(ctx)
		}
	}
	clear(&w.input)
}

// ---- the same on every system ----

// Tells the window system which part of a window without decorations is its title bar (see Hit_Region). On Windows the system then does what it does for a
// title bar of its own: dragging moves the window (and un-maximizes it), a double click maximizes, the edges resize. Wayland has no such question: there the
// program calls begin_move itself when the button goes down on its title bar (`hit_test` is only stored).
set_hit_test :: proc(w: ^Window, test: Hit_Test_Proc, user: rawptr = nil) {
	w.hit_test = test
	w.hit_test_user = user
}

// Asks the program to close, as the close button does: sets `close_requested` and reports .Close_Requested. Nothing is destroyed.
request_close :: proc(w: ^Window) {
	w.close_requested = true
	w.events += {.Close_Requested}
}

// Maximizes the window, or restores it when it is maximized.
toggle_maximize :: proc(w: ^Window) {
	if w.maximized {
		restore(w)
	} else {
		maximize(w)
	}
}

// Called by the operating system's code (not by programs): adds to the queues.
@(private)
queue_input :: proc(w: ^Window, e: Input_Event) {
	// a program that never calls feed_input must not grow the queue forever
	if len(w.input) >= MAX_QUEUED_INPUT {
		return
	}
	append(&w.input, e)
}

@(private)
MAX_QUEUED_INPUT :: 4096
