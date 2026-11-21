#+build linux, darwin
package platform

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import input "../../iv_input"

// ---------------------------------------------------------------------------
// The Linux and macOS part of platform: SDL2 (sdl2.odin loads it at run time) for the windows, their events, the
// keyboard, mouse and typed text, the cursor, the clipboard and the gamepads. What SDL does not do is in
// platform_linux.odin / platform_darwin.odin (the dialogs, the fonts, the file manager).
//
// The drawing stays the renderer's own: native_handle gives it the window system's handles -- on Linux SDL's
// wl_display + wl_surface (Wayland) or Display* + Window (X11), on macOS the CAMetalLayer of an SDL Metal view.
//
// Sizes: Window_Desc's width / height / min_* are taken at scale 1 (points: what SDL sizes windows in). `size` is in
// pixels, and dpi_scale is pixels per point (2 on a Retina screen, a Wayland output's scale), so a program that lays
// out at dpi_scale looks the same everywhere. Mouse positions are in pixels too.
//
// What differs from Windows: begin_move / begin_resize do nothing (SDL2 has no such call: a window without decorations
// is moved and resized through its hit test, which set_hit_test installs); stop_background does nothing.
// ---------------------------------------------------------------------------

_Native :: struct {
	sdl_window:  ^Sdl_Window,
	id:          u32,
	metal_view:  rawptr, // macOS: SDL's Metal view (its layer is what is drawn into)
	metal_layer: rawptr,
	scale:       f32, // pixels per point
	allocator:   runtime.Allocator,
	title:       string, // (desc.title, owned)
}

@(private = "file")
windows: [dynamic]^Window

@(private = "file")
cursors: [Cursor_Shape]^Sdl_Cursor

@(private = "file")
window_of_id :: proc(id: u32) -> ^Window {
	for w in windows {
		if w.id == id {
			return w
		}
	}
	return nil
}

// ---- windows ----

create_window :: proc(desc: Window_Desc, allocator := context.allocator) -> (w: ^Window, ok: bool) {
	if !sdl_load(desc.app_id) {
		fmt.eprintfln("iv_system: no window: %s", sdl.error)
		return nil, false
	}
	w = new(Window, allocator)
	w.desc = desc
	w.allocator = allocator
	w.title = strings.clone(desc.title, allocator)
	w.desc.title = w.title
	w.input = make([dynamic]Input_Event, allocator)
	if !make_sdl_window(w, desc.flags) {
		delete(w.input)
		delete(w.title, allocator)
		free(w, allocator)
		return nil, false
	}
	append(&windows, w)
	return w, true
}

// The SDL window of `w`, with the flags it starts with.
@(private = "file")
make_sdl_window :: proc(w: ^Window, flags: Window_Flags) -> bool {
	f: u32 = SDL_WINDOW_ALLOW_HIGHDPI
	if .Fixed_Size not_in flags {f |= SDL_WINDOW_RESIZABLE}
	if .No_Decorations in flags {f |= SDL_WINDOW_BORDERLESS}
	if .Hidden in flags {f |= SDL_WINDOW_HIDDEN}
	if .Maximized in flags {f |= SDL_WINDOW_MAXIMIZED}
	if .Fullscreen in flags {f |= SDL_WINDOW_FULLSCREEN_DESKTOP}
	if .Always_On_Top in flags {f |= SDL_WINDOW_ALWAYS_ON_TOP}
	// macOS: a Metal view; Linux: a Vulkan window (SDL then makes no EGL / GLX surface of its own). Without a Vulkan
	// loader SDL refuses the Vulkan flag: the window is made without it (the renderer says what is missing)
	gfx: u32 = SDL_WINDOW_VULKAN
	when ODIN_OS == .Darwin {gfx = SDL_WINDOW_METAL}
	title := strings.clone_to_cstring(w.title, context.temp_allocator)
	width, height := c.int(max(w.desc.width, 1)), c.int(max(w.desc.height, 1))
	win := sdl.CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, width, height, f | gfx)
	if win == nil {
		fmt.eprintfln("iv_system: SDL_CreateWindow: %s (again without the graphics flag)", sdl.GetError())
		win = sdl.CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, width, height, f)
	}
	if win == nil {
		fmt.eprintfln("iv_system: no window: %s", sdl.GetError())
		return false
	}
	w.sdl_window = win
	w.id = sdl.GetWindowID(win)
	when ODIN_OS == .Darwin {
		w.metal_view = sdl.Metal_CreateView(win)
		if w.metal_view != nil {
			w.metal_layer = sdl.Metal_GetLayer(w.metal_view)
		}
		if w.metal_layer == nil {
			fmt.eprintfln("iv_system: no Metal layer for the window: %s", sdl.GetError())
		}
	}
	if w.desc.min_width > 0 || w.desc.min_height > 0 {
		sdl.SetWindowMinimumSize(win, c.int(max(w.desc.min_width, 1)), c.int(max(w.desc.min_height, 1)))
	}
	sdl.StartTextInput()
	w.scale = 0
	w.focused = .No_Activate not_in flags && .Hidden not_in flags
	if .No_Decorations in flags {
		install_hit_test(w)
	}
	refresh(w)
	w.events = {} // (the first size is not a resize)
	if .No_Activate not_in flags && .Hidden not_in flags {
		sdl.RaiseWindow(win)
	}
	return true
}

@(private = "file")
drop_sdl_window :: proc(w: ^Window) {
	when ODIN_OS == .Darwin {
		if w.metal_view != nil {
			sdl.Metal_DestroyView(w.metal_view)
		}
	}
	w.metal_view, w.metal_layer = nil, nil
	if w.sdl_window != nil {
		sdl.DestroyWindow(w.sdl_window)
	}
	w.sdl_window, w.id = nil, 0
}

destroy_window :: proc(w: ^Window) {
	if w == nil {
		return
	}
	drop_sdl_window(w)
	for x, i in windows {
		if x == w {
			unordered_remove(&windows, i)
			break
		}
	}
	allocator := w.allocator
	delete(w.input)
	delete(w.title, allocator)
	free(w, allocator)
}

// A new SDL window in the place of the old one (a backend that tied the old one to itself failed), as it was: size,
// title, maximized, fullscreen.
recreate_window :: proc(w: ^Window) -> bool {
	flags := w.desc.flags - {.Maximized, .Fullscreen, .Hidden}
	if w.maximized {flags += {.Maximized}}
	if w.fullscreen {flags += {.Fullscreen}}
	if !w.decorated && !w.fullscreen {flags += {.No_Decorations}}
	w.desc.width = int(f32(w.size.x) / max(w.scale, 1))
	w.desc.height = int(f32(w.size.y) / max(w.scale, 1))
	drop_sdl_window(w)
	return make_sdl_window(w, flags)
}

// What the window is now (size, scale, focus, state), read from SDL; events for what changed.
@(private = "file")
refresh :: proc(w: ^Window) {
	win := w.sdl_window
	if win == nil {
		return
	}
	pw, ph, lw, lh: c.int
	sdl.GetWindowSize(win, &lw, &lh)
	when ODIN_OS == .Darwin {
		if sdl.Metal_GetDrawableSize != nil {sdl.Metal_GetDrawableSize(win, &pw, &ph)}
	}
	if pw <= 0 && sdl.GetWindowSizeInPixels != nil {sdl.GetWindowSizeInPixels(win, &pw, &ph)}
	when ODIN_OS != .Darwin {
		if pw <= 0 && sdl.Vulkan_GetDrawableSize != nil {sdl.Vulkan_GetDrawableSize(win, &pw, &ph)}
	}
	if pw <= 0 || ph <= 0 {pw, ph = lw, lh}
	scale: f32 = 1
	if lw > 0 {scale = max(f32(pw) / f32(lw), 1)}
	if scale != w.scale {
		first := w.scale == 0
		w.scale = scale
		w.dpi_scale = scale
		if !first {w.events += {.Dpi_Changed}}
	}
	size := [2]int{int(pw), int(ph)}
	if size != w.size {
		w.size = size
		w.events += {.Resized}
	}
	f := sdl.GetWindowFlags(win)
	minimized := f & SDL_WINDOW_MINIMIZED != 0
	if minimized != w.minimized {
		w.minimized = minimized
		if minimized {w.events += {.Minimized}} else {w.events += {.Restored}}
	}
	if !minimized {
		w.maximized = f & SDL_WINDOW_MAXIMIZED != 0
	}
	w.fullscreen = f & SDL_WINDOW_FULLSCREEN_DESKTOP != 0
	w.decorated = f & SDL_WINDOW_BORDERLESS == 0 && !w.fullscreen
}

// ---- events ----

// Takes every waiting event (for all windows: each gets its own) and returns what happened to `w` since the last poll.
poll :: proc(w: ^Window) -> Window_Events {
	if sdl.loaded {
		e: Sdl_Event
		for sdl.PollEvent(&e) != 0 {
			handle_event(&e)
		}
		for x in windows {
			refresh(x)
		}
	}
	events := w.events
	w.events = {}
	return events
}

// Waits for an event, at most `timeout` seconds (a program that draws only when something happens); it is left waiting
// for poll.
wait_events :: proc(w: ^Window, timeout: f64) {
	if sdl.loaded {
		sdl.WaitEventTimeout(nil, c.int(max(timeout, 0) * 1000))
	}
}

@(private = "file")
ev_u32 :: #force_inline proc(e: ^Sdl_Event, offset: int) -> u32 {return (^u32)(&e.bytes[offset])^}
@(private = "file")
ev_i32 :: #force_inline proc(e: ^Sdl_Event, offset: int) -> i32 {return (^i32)(&e.bytes[offset])^}
@(private = "file")
ev_f32 :: #force_inline proc(e: ^Sdl_Event, offset: int) -> f32 {return (^f32)(&e.bytes[offset])^}

@(private = "file")
handle_event :: proc(e: ^Sdl_Event) {
	switch e.type {
	case 0x100: // SDL_QUIT (macOS: Command+Q, the Dock's Quit): every window is asked
		for w in windows {request_close(w)}
	case 0x200: // SDL_WINDOWEVENT: windowID at 8, the event at 12
		w := window_of_id(ev_u32(e, 8))
		if w == nil {return}
		switch e.bytes[12] {
		case 10: w.mouse_inside = true // ENTER
		case 11: w.mouse_inside = false // LEAVE
		case 12: // FOCUS_GAINED
			if !w.focused {w.focused = true; w.events += {.Focus_Gained}}
		case 13: // FOCUS_LOST: nothing stays held
			if w.focused {w.focused = false; w.events += {.Focus_Lost}}
			queue_input(w, {kind = .Focus_Lost})
		case 14: request_close(w) // CLOSE
		}
	case 0x300, 0x301: // SDL_KEYDOWN / UP: windowID 8, repeat 13, scancode 16
		w := window_of_id(ev_u32(e, 8))
		if w == nil {return}
		key := translate_key(ev_i32(e, 16))
		if key == .None {return}
		if e.type == 0x301 {
			queue_input(w, {kind = .Key_Up, key = key})
		} else {
			kind := Input_Event_Kind.Key_Down
			if e.bytes[13] != 0 {kind = .Key_Repeat}
			queue_input(w, {kind = kind, key = key})
		}
	case 0x303: // SDL_TEXTINPUT: windowID 8, UTF-8 text at 12 (32 bytes)
		w := window_of_id(ev_u32(e, 8))
		if w == nil {return}
		n := 0
		for n < 32 && e.bytes[12 + n] != 0 {n += 1}
		text := string(e.bytes[12:12 + n])
		for r in text {
			if r != utf8.RUNE_ERROR && r >= 0x20 && r != 0x7f {queue_input(w, {kind = .Char, char = r})}
		}
	case 0x400: // SDL_MOUSEMOTION: windowID 8, x 20, y 24 (points)
		w := window_of_id(ev_u32(e, 8))
		if w == nil {return}
		w.mouse_inside = true
		queue_input(w, {kind = .Mouse_Move, x = f32(ev_i32(e, 20)) * w.scale, y = f32(ev_i32(e, 24)) * w.scale})
	case 0x401, 0x402: // SDL_MOUSEBUTTONDOWN / UP: windowID 8, button 16, x 20, y 24
		w := window_of_id(ev_u32(e, 8))
		if w == nil {return}
		button: input.Mouse_Button
		switch e.bytes[16] {
		case 1: button = .Left
		case 2: button = .Middle
		case 3: button = .Right
		case 4: button = .Back
		case 5: button = .Forward
		case: button = .Extra
		}
		queue_input(w, {kind = .Mouse_Move, x = f32(ev_i32(e, 20)) * w.scale, y = f32(ev_i32(e, 24)) * w.scale})
		kind := Input_Event_Kind.Mouse_Up
		if e.type == 0x401 {kind = .Mouse_Down}
		queue_input(w, {kind = kind, button = button})
	case 0x403: // SDL_MOUSEWHEEL: windowID 8, x 16, y 20, direction 24, preciseX 28 / preciseY 32 (2.0.18)
		w := window_of_id(ev_u32(e, 8))
		if w == nil {return}
		x, y := f32(ev_i32(e, 16)), f32(ev_i32(e, 20))
		if sdl.GetVersion != nil {
			v: [3]u8
			sdl.GetVersion(&v)
			if v[0] > 2 || v[1] > 0 || v[2] >= 18 { // (fractional notches: touchpads)
				x, y = ev_f32(e, 28), ev_f32(e, 32)
			}
		}
		if ev_u32(e, 24) == 1 {x, y = -x, -y} // SDL_MOUSEWHEEL_FLIPPED ("natural" scrolling): as the user turned it
		queue_input(w, {kind = .Wheel, x = x, y = y})
	case 0x653, 0x654: // SDL_CONTROLLERDEVICEADDED / REMOVED
		pads_changed = true
	}
}

// ---- the window's state ----

set_title :: proc(w: ^Window, title: string) {
	delete(w.title, w.allocator)
	w.title = strings.clone(title, w.allocator)
	w.desc.title = w.title
	sdl.SetWindowTitle(w.sdl_window, strings.clone_to_cstring(title, context.temp_allocator))
}

set_fullscreen :: proc(w: ^Window, on: bool) {
	sdl.SetWindowFullscreen(w.sdl_window, SDL_WINDOW_FULLSCREEN_DESKTOP if on else 0)
	refresh(w)
}

// The client area's size, in pixels.
set_size :: proc(w: ^Window, width, height: int) {
	s := max(w.scale, 1)
	sdl.SetWindowSize(w.sdl_window, c.int(math.round(f32(width) / s)), c.int(math.round(f32(height) / s)))
	refresh(w)
}

begin_move :: proc(w: ^Window) {}

begin_resize :: proc(w: ^Window, edge: Resize_Edge) {}

stop_background :: proc(w: ^Window) {}

set_visible :: proc(w: ^Window, visible: bool) {
	if visible {sdl.ShowWindow(w.sdl_window)} else {sdl.HideWindow(w.sdl_window)}
}

maximize :: proc(w: ^Window) {sdl.MaximizeWindow(w.sdl_window); refresh(w)}

restore :: proc(w: ^Window) {sdl.RestoreWindow(w.sdl_window); refresh(w)}

minimize :: proc(w: ^Window) {sdl.MinimizeWindow(w.sdl_window); refresh(w)}

set_decorated :: proc(w: ^Window, on: bool) {
	sdl.SetWindowBordered(w.sdl_window, b32(on))
	if !on {install_hit_test(w)}
	refresh(w)
}

set_resizable :: proc(w: ^Window, on: bool) {
	if sdl.SetWindowResizable != nil {sdl.SetWindowResizable(w.sdl_window, b32(on))}
	if on {w.desc.flags -= {.Fixed_Size}} else {w.desc.flags += {.Fixed_Size}}
}

set_always_on_top :: proc(w: ^Window, on: bool) {
	if sdl.SetWindowAlwaysOnTop != nil {sdl.SetWindowAlwaysOnTop(w.sdl_window, b32(on))}
}

// A window without decorations: SDL asks this where a point is (in points). The program's hit test says where its
// title bar is; the outer few pixels resize a resizable window.
@(private = "file")
hit_test_cb :: proc "c" (win: ^Sdl_Window, point: ^[2]c.int, data: rawptr) -> c.int {
	context = runtime.default_context()
	w := (^Window)(data)
	if w == nil || w.fullscreen {return 0}
	s := max(w.scale, 1)
	x, y := int(f32(point.x) * s), int(f32(point.y) * s)
	if .Fixed_Size not_in w.desc.flags && !w.maximized {
		edge := int(6 * s)
		left, right, top, bottom := x < edge, x >= w.size.x - edge, y < edge, y >= w.size.y - edge
		switch {
		case top && left: return 2 // SDL_HITTEST_RESIZE_TOPLEFT
		case top && right: return 4
		case bottom && right: return 6
		case bottom && left: return 8
		case top: return 3
		case right: return 5
		case bottom: return 7
		case left: return 9
		}
	}
	if w.hit_test != nil && w.hit_test(w, x, y, w.hit_test_user) == .Caption {
		return 1 // SDL_HITTEST_DRAGGABLE
	}
	return 0 // SDL_HITTEST_NORMAL
}

@(private = "file")
install_hit_test :: proc(w: ^Window) {
	if sdl.SetWindowHitTest != nil {
		sdl.SetWindowHitTest(w.sdl_window, rawptr(hit_test_cb), w)
	}
}

// ---- the mouse cursor ----

set_cursor_visible :: proc(w: ^Window, visible: bool) {
	w.cursor_hidden = !visible
	if sdl.loaded {sdl.ShowCursor(1 if visible else 0)}
}

set_cursor_shape :: proc(w: ^Window, shape: Cursor_Shape) {
	if w.cursor_shape == shape || !sdl.loaded {
		w.cursor_shape = shape
		return
	}
	w.cursor_shape = shape
	if cursors[shape] == nil {
		id: c.int
		switch shape {
		case .Default: id = 0 // SDL_SYSTEM_CURSOR_ARROW
		case .Text: id = 1 // IBEAM
		case .Crosshair: id = 3
		case .Resize_Horizontal: id = 7 // SIZEWE
		case .Hand: id = 11
		}
		cursors[shape] = sdl.CreateSystemCursor(id)
	}
	if cursors[shape] != nil {sdl.SetCursor(cursors[shape])}
}

// Moves the mouse cursor to (x, y) in client pixels.
set_mouse_position :: proc(w: ^Window, x, y: int) -> bool {
	if w.sdl_window == nil {return false}
	s := max(w.scale, 1)
	sdl.WarpMouseInWindow(w.sdl_window, c.int(f32(x) / s), c.int(f32(y) / s))
	return true
}

// ---- the clipboard ----

clipboard_text :: proc(w: ^Window, allocator := context.allocator) -> (text: string, ok: bool) {
	if !sdl.loaded {return "", false}
	t := sdl.GetClipboardText()
	if t == nil {return "", false}
	defer sdl.free(rawptr(t))
	if len(t) == 0 {return "", false}
	return strings.clone(string(t), allocator), true
}

set_clipboard_text :: proc(w: ^Window, text: string) -> bool {
	if !sdl.loaded {return false}
	return sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator)) == 0
}

// ---- gamepads (SDL's game controllers: its database maps Xbox, PlayStation, Switch and many other pads) ----

@(private = "file")
pads_changed := true
@(private = "file")
pad_handles: [input.MAX_PADS]^Sdl_Controller

read_gamepads :: proc(pads: ^[input.MAX_PADS]Pad_State) {
	if !sdl.loaded {return}
	if pads_changed {
		pads_changed = false
		for &h in pad_handles {
			if h != nil && !sdl.GameControllerGetAttached(h) {
				sdl.GameControllerClose(h)
				h = nil
			}
		}
		n := sdl.NumJoysticks()
		outer: for i in 0 ..< n {
			if !sdl.IsGameController(i) {continue}
			gc := sdl.GameControllerOpen(i) // (the same handle again for a pad already open, with a reference more)
			if gc == nil {continue}
			for h in pad_handles {
				if h == gc {sdl.GameControllerClose(gc); continue outer}
			}
			for &h in pad_handles {
				if h == nil {h = gc; continue outer}
			}
			sdl.GameControllerClose(gc)
		}
	}
	for h, i in pad_handles {
		if h == nil {continue}
		p := &pads[i]
		p.connected = true
		btn :: proc(h: ^Sdl_Controller, b: c.int) -> bool {return sdl.GameControllerGetButton(h, b) != 0}
		p.buttons[.Face_Down] = btn(h, 0)
		p.buttons[.Face_Right] = btn(h, 1)
		p.buttons[.Face_Left] = btn(h, 2)
		p.buttons[.Face_Up] = btn(h, 3)
		p.buttons[.Back] = btn(h, 4)
		p.buttons[.Guide] = btn(h, 5)
		p.buttons[.Start] = btn(h, 6)
		p.buttons[.Left_Stick] = btn(h, 7)
		p.buttons[.Right_Stick] = btn(h, 8)
		p.buttons[.Left_Shoulder] = btn(h, 9)
		p.buttons[.Right_Shoulder] = btn(h, 10)
		p.buttons[.Dpad_Up] = btn(h, 11)
		p.buttons[.Dpad_Down] = btn(h, 12)
		p.buttons[.Dpad_Left] = btn(h, 13)
		p.buttons[.Dpad_Right] = btn(h, 14)
		axis :: proc(h: ^Sdl_Controller, a: c.int) -> f32 {return max(f32(sdl.GameControllerGetAxis(h, a)) / 32767, -1)}
		// (SDL's y is down-positive already, as iv_input's)
		p.axes[.Left_X] = axis(h, 0)
		p.axes[.Left_Y] = axis(h, 1)
		p.axes[.Right_X] = axis(h, 2)
		p.axes[.Right_Y] = axis(h, 3)
		p.axes[.Left_Trigger] = max(axis(h, 4), 0)
		p.axes[.Right_Trigger] = max(axis(h, 5), 0)
		p.buttons[.Left_Trigger] = p.axes[.Left_Trigger] > 0.5
		p.buttons[.Right_Trigger] = p.axes[.Right_Trigger] > 0.5
	}
}

// ---- for the renderer ----

// The window system's handles: Linux Wayland: wl_surface (window), wl_display (display); X11: the Window (an XID, as a
// pointer-sized number) and the Display*; macOS: the CAMetalLayer of SDL's Metal view (window) and the view (display).
native_handle :: proc(w: ^Window) -> Native_Handle {
	when ODIN_OS == .Darwin {
		return {kind = .Cocoa, window = w.metal_layer, display = w.metal_view}
	} else {
		info: Sdl_Wm_Info
		sdl.GetVersion(&info.version)
		if w.sdl_window == nil || !sdl.GetWindowWMInfo(w.sdl_window, &info) {
			return {}
		}
		switch info.subsystem {
		case SDL_SYSWM_WAYLAND:
			return {kind = .Wayland, display = rawptr(info.info[0]), window = rawptr(info.info[1])}
		case SDL_SYSWM_X11:
			return {kind = .X11, display = rawptr(info.info[0]), window = rawptr(info.info[1])}
		}
		return {}
	}
}

// Seconds since some fixed point (monotonic): for timing frames.
time_seconds :: proc() -> f64 {
	@(static) base: time.Tick
	if base == {} {base = time.tick_now()}
	return time.duration_seconds(time.tick_since(base))
}

// ---- keys ----

// The key of an SDL scancode (USB HID usage numbers: positions on the keyboard, kVK_ / evdev alike).
@(private = "file")
translate_key :: proc(sc: i32) -> input.Key {
	switch sc {
	case 4 ..= 29: return input.Key(int(input.Key.A) + int(sc - 4))
	case 30 ..= 38: return input.Key(int(input.Key.Num_1) + int(sc - 30))
	case 39: return .Num_0
	case 40: return .Enter
	case 41: return .Escape
	case 42: return .Backspace
	case 43: return .Tab
	case 44: return .Space
	case 45: return .Minus
	case 46: return .Equal
	case 47: return .Left_Bracket
	case 48: return .Right_Bracket
	case 49, 50: return .Backslash
	case 51: return .Semicolon
	case 52: return .Apostrophe
	case 53: return .Grave
	case 54: return .Comma
	case 55: return .Period
	case 56: return .Slash
	case 57: return .Caps_Lock
	case 58 ..= 69: return input.Key(int(input.Key.F1) + int(sc - 58))
	case 70: return .Print_Screen
	case 71: return .Scroll_Lock
	case 72: return .Pause
	case 73: return .Insert
	case 74: return .Home
	case 75: return .Page_Up
	case 76: return .Delete
	case 77: return .End
	case 78: return .Page_Down
	case 79: return .Right
	case 80: return .Left
	case 81: return .Down
	case 82: return .Up
	case 83: return .Num_Lock
	case 84: return .Kp_Divide
	case 85: return .Kp_Multiply
	case 86: return .Kp_Subtract
	case 87: return .Kp_Add
	case 88: return .Kp_Enter
	case 89 ..= 97: return input.Key(int(input.Key.Kp_1) + int(sc - 89))
	case 98: return .Kp_0
	case 99: return .Kp_Decimal
	case 100: return .Backslash // (the ISO key left of Z)
	case 101, 118: return .Menu
	case 103: return .Kp_Equal
	case 104 ..= 115: return input.Key(int(input.Key.F13) + int(sc - 104))
	case 224: return .Left_Ctrl
	case 225: return .Left_Shift
	case 226: return .Left_Alt
	case 227: return .Left_Super
	case 228: return .Right_Ctrl
	case 229: return .Right_Shift
	case 230: return .Right_Alt
	case 231: return .Right_Super
	}
	return .None
}
