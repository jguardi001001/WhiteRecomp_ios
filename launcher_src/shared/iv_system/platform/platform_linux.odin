package platform

import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:strings"
import "core:sys/linux"
import input "../../iv_input"

// ---------------------------------------------------------------------------
// The Linux part of platform: Wayland only (no X11). One connection to the compositor is shared by all the program's
// windows; each window is an xdg_toplevel. Keys and text come through libxkbcommon (xkb_linux.odin), the mouse cursor
// through libwayland-cursor; both are loaded at run time and the layer works without them (positional keys and no typed
// text, no cursor image).
//
// What differs from Windows, and what the program notices:
//  * A window has no contents until something draws into it: a Wayland window appears when the first buffer is attached,
//    which the graphics backend does (so `hidden` cannot be honoured, and a program with no renderer shows nothing).
//  * The compositor chooses the size (configure events); the program chooses it only by drawing at another size. `size` is
//    in buffer pixels: the logical size the compositor talks in, times the integer scale of the monitor.
//  * Decorations: if the compositor offers xdg-decoration it draws the title bar (`decorated` is true). GNOME does not: the
//    window is then bare, and a custom title bar uses begin_move / begin_resize.
//  * Key repeat is the program's job on Wayland; poll makes the repeats from the compositor's rate and delay.
//
// To do: fractional scales (wp_fractional_scale + wp_viewporter), IME / compose (text-input-v3), clipboard (wl_data_device),
// cursor shapes of the program's choice, touch, gamepads (not a window system's matter), idle inhibition.
// ---------------------------------------------------------------------------

_Native :: struct {
	surface:             ^Wl_Surface,
	xdg_surface:         ^Xdg_Surface,
	toplevel:            ^Xdg_Toplevel,
	decoration:          ^Zxdg_Toplevel_Decoration,
	allocator:           runtime.Allocator,
	logical:             [2]int, // the size in the compositor's units (surface coordinates)
	scale:               int, // integer buffer scale: size = logical * scale
	has_preferred_scale: bool, // the compositor tells the scale itself (wl_surface v6): outputs are not asked
	pending:             [2]int, // from xdg_toplevel.configure; 0 = the program's choice
	pending_states:      bit_set[Toplevel_State; u32],
	configured:          bool, // the first xdg_surface.configure has come
	entered:             [dynamic]^Wl_Output, // the monitors the window is on
}

@(private)
Output :: struct {
	proxy:         ^Wl_Output,
	registry_name: u32,
	scale:         i32,
}

// The connection and everything that belongs to it, not to one window.
@(private)
Wayland :: struct {
	display:            ^Wl_Display,
	registry:           ^Wl_Registry,
	compositor:         ^Wl_Compositor,
	wm_base:            ^Xdg_Wm_Base,
	seat:               ^Wl_Seat,
	shm:                ^Wl_Shm,
	decoration_manager: ^Zxdg_Decoration_Manager,
	pointer:            ^Wl_Pointer,
	keyboard:           ^Wl_Keyboard,
	outputs:            [dynamic]Output,
	windows:            [dynamic]^Window,
	broken:             bool, // the connection failed: nothing works any more

	// who has the pointer and the keyboard
	pointer_focus:      ^Window,
	keyboard_focus:     ^Window,
	pointer_serial:     u32, // of the last enter: setting the cursor needs it
	button_serial:      u32, // of the last button press: starting a move or a resize needs it

	// scrolling of one pointer frame
	scroll:             [2]f32, // the continuous axes
	scroll_notches:     [2]i32, // the discrete ones
	scrolled:           bool,

	// key repeat (the compositor only says how fast; the program does it)
	repeat_code:        u32, // the evdev code of the key that repeats; 0 = none
	repeat_window:      ^Window,
	repeat_rate:        i32, // repeats per second; 0 = no repeat
	repeat_delay:       i32, // milliseconds before the first
	repeat_next:        f64,

	xkb:                Xkb,
	cursor:             Cursor,
}

@(private)
wl: Wayland

// ---- the cursor ------------------------------------------------------------------------------------------------------

@(private)
Cursor_Image :: struct {
	width, height:         u32,
	hotspot_x, hotspot_y:  u32,
	delay:                 u32,
}

@(private)
Cursor_Theme_Cursor :: struct {
	image_count: u32,
	images:      [^]^Cursor_Image,
	name:        cstring,
}

@(private)
Cursor_Procs :: struct {
	theme_load:       proc "c" (name: cstring, size: c.int, shm: ^Wl_Shm) -> rawptr,
	theme_destroy:    proc "c" (theme: rawptr),
	theme_get_cursor: proc "c" (theme: rawptr, name: cstring) -> ^Cursor_Theme_Cursor,
	image_get_buffer: proc "c" (image: ^Cursor_Image) -> ^Wl_Buffer,
}

@(private)
Cursor_Surface :: struct {
	surface:   ^Wl_Surface,
	hotspot_x: i32, // in surface units
	hotspot_y: i32,
}

@(private)
Cursor :: struct {
	procs:   Cursor_Procs,
	library: dynlib.Library,
	theme:   rawptr,
	shapes:  [Cursor_Shape]Cursor_Surface, // surface == nil: this theme has no such cursor
	ready:   bool,
}

CURSOR_SIZE :: 24

// The names a cursor theme may know each shape by (the freedesktop names, then the old X names).
@(private)
CURSOR_NAMES := [Cursor_Shape][3]cstring {
	.Default   = {"left_ptr", "default", "arrow"},
	.Hand      = {"pointer", "hand2", "hand1"},
	.Text      = {"text", "xterm", "ibeam"},
	.Crosshair = {"crosshair", "cross", "tcross"},
	.Resize_Horizontal = {"ew-resize", "sb_h_double_arrow", "col-resize"},
}

@(private = "file")
cursor_init :: proc() {
	if wl.shm == nil || wl.compositor == nil {
		return
	}
	cursor := &wl.cursor
	lib, ok := dynlib.load_library("libwayland-cursor.so.0")
	if !ok {
		return
	}
	if _, symbols_ok := dynlib.initialize_symbols(&cursor.procs, "libwayland-cursor.so.0", "wl_cursor_", ""); !symbols_ok {
		_ = dynlib.unload_library(lib)
		cursor.procs = {}
		return
	}
	cursor.library = lib
	scale := max_output_scale()
	cursor.theme = cursor.procs.theme_load(nil, CURSOR_SIZE * c.int(scale), wl.shm)
	if cursor.theme == nil {
		return
	}
	for shape in Cursor_Shape {
		image: ^Cursor_Image
		for name in CURSOR_NAMES[shape] {
			if found := cursor.procs.theme_get_cursor(cursor.theme, name); found != nil && found.image_count > 0 {
				image = found.images[0]
				break
			}
		}
		if image == nil {
			continue
		}
		buffer := cursor.procs.image_get_buffer(image)
		if buffer == nil {
			continue
		}
		surface := wl_compositor_create_surface(wl.compositor)
		wl_surface_set_buffer_scale(surface, i32(scale))
		wl_surface_attach(surface, buffer, 0, 0)
		wl_surface_damage_buffer(surface, 0, 0, i32(image.width), i32(image.height))
		wl_surface_commit(surface)
		cursor.shapes[shape] = {surface, i32(image.hotspot_x) / i32(scale), i32(image.hotspot_y) / i32(scale)}
		cursor.ready = true
	}
}

// Tells the compositor what the cursor over `w` is (it forgets it every time the pointer comes back, and keeps what is set
// while the pointer stays).
@(private = "file")
apply_cursor :: proc(w: ^Window) {
	if wl.pointer == nil || wl.pointer_focus != w || !wl.cursor.ready {
		return
	}
	if w.cursor_hidden {
		wl_pointer_set_cursor(wl.pointer, wl.pointer_serial, nil, 0, 0)
		return
	}
	shape := wl.cursor.shapes[w.cursor_shape]
	if shape.surface == nil {
		shape = wl.cursor.shapes[.Default]
	}
	wl_pointer_set_cursor(wl.pointer, wl.pointer_serial, shape.surface, shape.hotspot_x, shape.hotspot_y)
}

@(private = "file")
max_output_scale :: proc() -> int {
	scale := 1
	for o in wl.outputs {
		scale = max(scale, int(o.scale))
	}
	return scale
}

// ---- connecting -----------------------------------------------------------------------------------------------------

@(private)
registry_listener := Registry_Listener {
	global        = registry_global,
	global_remove = registry_global_remove,
}

@(private = "file")
registry_global :: proc "c" (data: rawptr, registry: ^Wl_Registry, name: u32, interface: cstring, version: u32) {
	context = runtime.default_context()
	switch string(interface) {
	case "wl_compositor":
		wl.compositor = (^Wl_Compositor)(wl_registry_bind(registry, name, &wl_compositor_interface, min(version, 6)))
	case "xdg_wm_base":
		wl.wm_base = (^Xdg_Wm_Base)(wl_registry_bind(registry, name, &xdg_wm_base_interface, min(version, 6)))
	case "wl_seat":
		if wl.seat == nil { // the first seat is the one that is used
			wl.seat = (^Wl_Seat)(wl_registry_bind(registry, name, &wl_seat_interface, min(version, 5)))
			wl_proxy_listen(wl.seat, &seat_listener, nil)
		}
	case "wl_shm":
		wl.shm = (^Wl_Shm)(wl_registry_bind(registry, name, &wl_shm_interface, 1))
	case "wl_output":
		output := (^Wl_Output)(wl_registry_bind(registry, name, &wl_output_interface, min(version, 3)))
		append(&wl.outputs, Output{proxy = output, registry_name = name, scale = 1})
		wl_proxy_listen(output, &output_listener, nil)
	case "zxdg_decoration_manager_v1":
		wl.decoration_manager = (^Zxdg_Decoration_Manager)(wl_registry_bind(registry, name, &zxdg_decoration_manager_v1_interface, 1))
	}
}

@(private = "file")
registry_global_remove :: proc "c" (data: rawptr, registry: ^Wl_Registry, name: u32) {
	context = runtime.default_context()
	for o, i in wl.outputs {
		if o.registry_name == name {
			unordered_remove(&wl.outputs, i)
			break
		}
	}
}

// Connects to the compositor named by WAYLAND_DISPLAY (once) and collects what it offers. false: no Wayland session, or
// one without the compositor and xdg-shell.
@(private = "file")
ensure_display :: proc() -> bool {
	if wl.display != nil {
		return !wl.broken
	}
	display := wl_display_connect(nil)
	if display == nil {
		return false
	}
	wl.display = display
	wl.registry = wl_display_get_registry(display)
	wl_proxy_listen(wl.registry, &registry_listener, nil)
	wl_display_roundtrip(display) // the globals
	if wl.compositor == nil || wl.wm_base == nil {
		wl_display_disconnect(display)
		wl = {}
		return false
	}
	wl_proxy_listen(wl.wm_base, &wm_base_listener, nil)
	wl_display_roundtrip(display) // what the seat and the outputs say about themselves
	wl_display_roundtrip(display) // the keymap and the key repeat rate
	cursor_init()
	return true
}

@(private = "file")
wm_base_listener := Wm_Base_Listener {
	ping = proc "c" (data: rawptr, wm_base: ^Xdg_Wm_Base, serial: u32) {
		xdg_wm_base_pong(wm_base, serial)
	},
}

// ---- outputs and the scale ---------------------------------------------------------------------------------------------

@(private = "file")
output_listener := Output_Listener {
	geometry    = proc "c" (data: rawptr, output: ^Wl_Output, x, y, physical_width, physical_height, subpixel: i32, make, model: cstring, transform: i32) {},
	mode        = proc "c" (data: rawptr, output: ^Wl_Output, flags: u32, width, height, refresh: i32) {},
	done        = proc "c" (data: rawptr, output: ^Wl_Output) {},
	scale       = output_scale,
	name        = proc "c" (data: rawptr, output: ^Wl_Output, name: cstring) {},
	description = proc "c" (data: rawptr, output: ^Wl_Output, description: cstring) {},
}

@(private = "file")
output_scale :: proc "c" (data: rawptr, output: ^Wl_Output, factor: i32) {
	context = runtime.default_context()
	for &o in wl.outputs {
		if o.proxy == output {
			o.scale = max(factor, 1)
		}
	}
	for w in wl.windows {
		refresh_scale(w)
	}
}

// The scale a window should have, from the monitors it is on (when the compositor does not say it itself).
@(private = "file")
refresh_scale :: proc(w: ^Window) {
	if w.has_preferred_scale || len(w.entered) == 0 {
		return
	}
	scale := 1
	for entered in w.entered {
		for o in wl.outputs {
			if o.proxy == entered {
				scale = max(scale, int(o.scale))
			}
		}
	}
	set_scale(w, scale)
}

@(private = "file")
set_scale :: proc(w: ^Window, scale: int) {
	if scale < 1 || scale == w.scale {
		return
	}
	w.scale = scale
	w.dpi_scale = f32(scale)
	wl_surface_set_buffer_scale(w.surface, i32(scale))
	w.size = w.logical * scale
	w.events += {.Dpi_Changed, .Resized}
}

@(private)
surface_listener := Surface_Listener {
	enter                      = proc "c" (data: rawptr, surface: ^Wl_Surface, output: ^Wl_Output) {
		context = runtime.default_context()
		if w := (^Window)(data); w != nil {
			append(&w.entered, output)
			refresh_scale(w)
		}
	},
	leave                      = proc "c" (data: rawptr, surface: ^Wl_Surface, output: ^Wl_Output) {
		context = runtime.default_context()
		if w := (^Window)(data); w != nil {
			for o, i in w.entered {
				if o == output {
					unordered_remove(&w.entered, i)
					break
				}
			}
		}
	},
	preferred_buffer_scale     = proc "c" (data: rawptr, surface: ^Wl_Surface, factor: i32) {
		context = runtime.default_context()
		if w := (^Window)(data); w != nil {
			w.has_preferred_scale = true
			set_scale(w, int(factor))
		}
	},
	preferred_buffer_transform = proc "c" (data: rawptr, surface: ^Wl_Surface, transform: u32) {},
}

// ---- the seat: pointer and keyboard ---------------------------------------------------------------------------------

@(private = "file")
seat_listener := Seat_Listener {
	capabilities = proc "c" (data: rawptr, seat: ^Wl_Seat, capabilities: u32) {
		context = runtime.default_context()
		has_pointer := capabilities & 1 != 0
		has_keyboard := capabilities & 2 != 0
		if has_pointer && wl.pointer == nil {
			wl.pointer = wl_seat_get_pointer(seat)
			wl_proxy_listen(wl.pointer, &pointer_listener, nil)
		} else if !has_pointer && wl.pointer != nil {
			wl_pointer_release(wl.pointer)
			wl.pointer, wl.pointer_focus = nil, nil
		}
		if has_keyboard && wl.keyboard == nil {
			wl.keyboard = wl_seat_get_keyboard(seat)
			wl_proxy_listen(wl.keyboard, &keyboard_listener, nil)
		} else if !has_keyboard && wl.keyboard != nil {
			wl_keyboard_release(wl.keyboard)
			wl.keyboard, wl.keyboard_focus = nil, nil
		}
	},
	name         = proc "c" (data: rawptr, seat: ^Wl_Seat, name: cstring) {},
}

@(private = "file")
window_of :: proc "contextless" (surface: ^Wl_Surface) -> ^Window {
	if surface == nil {
		return nil
	}
	return (^Window)(wl_proxy_get_user_data(proxy_of(surface)))
}

// the position in buffer pixels
@(private = "file")
pointer_position :: proc "contextless" (w: ^Window, x, y: Wl_Fixed) -> (f32, f32) {
	return fixed_to_f32(x) * f32(w.scale), fixed_to_f32(y) * f32(w.scale)
}

@(private)
pointer_listener := Pointer_Listener {
	enter                   = proc "c" (data: rawptr, pointer: ^Wl_Pointer, serial: u32, surface: ^Wl_Surface, x, y: Wl_Fixed) {
		context = runtime.default_context()
		w := window_of(surface)
		if w == nil {
			return
		}
		wl.pointer_focus = w
		wl.pointer_serial = serial
		w.mouse_inside = true
		apply_cursor(w)
		px, py := pointer_position(w, x, y)
		queue_input(w, {kind = .Mouse_Move, x = px, y = py})
	},
	leave                   = proc "c" (data: rawptr, pointer: ^Wl_Pointer, serial: u32, surface: ^Wl_Surface) {
		if w := window_of(surface); w != nil {
			w.mouse_inside = false
			if w == wl.pointer_focus {
				wl.pointer_focus = nil
			}
		}
	},
	motion                  = proc "c" (data: rawptr, pointer: ^Wl_Pointer, time: u32, x, y: Wl_Fixed) {
		context = runtime.default_context()
		if w := wl.pointer_focus; w != nil {
			px, py := pointer_position(w, x, y)
			queue_input(w, {kind = .Mouse_Move, x = px, y = py})
		}
	},
	button                  = proc "c" (data: rawptr, pointer: ^Wl_Pointer, serial, time, button, state: u32) {
		context = runtime.default_context()
		w := wl.pointer_focus
		if w == nil {
			return
		}
		pressed := state == 1
		if pressed {
			wl.button_serial = serial
		}
		b: input.Mouse_Button
		switch button { // linux/input-event-codes.h
		case 0x110:
			b = .Left
		case 0x111:
			b = .Right
		case 0x112:
			b = .Middle
		case 0x113, 0x116: // BTN_SIDE, BTN_BACK
			b = .Back
		case 0x114, 0x115: // BTN_EXTRA, BTN_FORWARD
			b = .Forward
		case:
			b = .Extra
		}
		queue_input(w, {kind = .Mouse_Down if pressed else .Mouse_Up, button = b})
	},
	axis                    = proc "c" (data: rawptr, pointer: ^Wl_Pointer, time, axis: u32, value: Wl_Fixed) {
		if axis < 2 { // 0 vertical, 1 horizontal
			wl.scroll[axis] += fixed_to_f32(value)
			wl.scrolled = true
		}
	},
	frame                   = proc "c" (data: rawptr, pointer: ^Wl_Pointer) {
		context = runtime.default_context()
		flush_scroll()
	},
	axis_source             = proc "c" (data: rawptr, pointer: ^Wl_Pointer, source: u32) {},
	axis_stop               = proc "c" (data: rawptr, pointer: ^Wl_Pointer, time, axis: u32) {},
	axis_discrete           = proc "c" (data: rawptr, pointer: ^Wl_Pointer, axis: u32, discrete: i32) {
		if axis < 2 {
			wl.scroll_notches[axis] += discrete
			wl.scrolled = true
		}
	},
	axis_value120           = proc "c" (data: rawptr, pointer: ^Wl_Pointer, axis: u32, value120: i32) {},
	axis_relative_direction = proc "c" (data: rawptr, pointer: ^Wl_Pointer, axis, direction: u32) {},
}

// One pointer frame of scrolling becomes one Wheel event: whole notches if the wheel reported them, else the continuous
// distance (a wheel notch is about 10 units). Wayland's axes point down and right; the input package's wheel points up.
@(private = "file")
flush_scroll :: proc() {
	if !wl.scrolled {
		return
	}
	if w := wl.pointer_focus; w != nil {
		vertical := -wl.scroll[0] / 10
		horizontal := wl.scroll[1] / 10
		if wl.scroll_notches[0] != 0 {
			vertical = -f32(wl.scroll_notches[0])
		}
		if wl.scroll_notches[1] != 0 {
			horizontal = f32(wl.scroll_notches[1])
		}
		if vertical != 0 || horizontal != 0 {
			queue_input(w, {kind = .Wheel, x = horizontal, y = vertical})
		}
	}
	wl.scroll = {}
	wl.scroll_notches = {}
	wl.scrolled = false
}

@(private)
keyboard_listener := Keyboard_Listener {
	keymap      = proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, format: u32, fd: i32, size: u32) {
		context = runtime.default_context()
		defer linux.close(linux.Fd(fd))
		if format != 1 || size == 0 || !xkb_load(&wl.xkb) { // 1 = xkb text v1
			return
		}
		mapped, errno := linux.mmap(0, uint(size), {.READ}, {.PRIVATE}, linux.Fd(fd), 0)
		if errno != .NONE {
			return
		}
		defer linux.munmap(mapped, uint(size))
		keymap := wl.xkb.procs.keymap_new_from_string(wl.xkb.ctx, cstring(mapped), XKB_KEYMAP_FORMAT_TEXT_V1, 0)
		xkb_set_keymap(&wl.xkb, keymap)
	},
	enter       = proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, serial: u32, surface: ^Wl_Surface, keys: ^Wl_Array) {
		wl.keyboard_focus = window_of(surface)
	},
	leave       = proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, serial: u32, surface: ^Wl_Surface) {
		context = runtime.default_context()
		if w := window_of(surface); w != nil {
			queue_input(w, {kind = .Focus_Lost}) // nothing may stay held
			if wl.keyboard_focus == w {
				wl.keyboard_focus = nil
			}
		}
		wl.repeat_code = 0
	},
	key         = proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, serial, time, code, state: u32) {
		context = runtime.default_context()
		w := wl.keyboard_focus
		if w == nil {
			return
		}
		pressed := state == 1
		if key := translate_key(&wl.xkb, code); key != .None {
			queue_input(w, {kind = .Key_Down if pressed else .Key_Up, key = key})
		}
		if pressed {
			if c := key_character(&wl.xkb, code); c != 0 {
				queue_input(w, {kind = .Char, char = c})
			}
			if wl.repeat_rate > 0 && key_repeats(&wl.xkb, code) {
				wl.repeat_code = code
				wl.repeat_window = w
				wl.repeat_next = time_seconds() + f64(wl.repeat_delay) / 1000
			}
		} else if wl.repeat_code == code {
			wl.repeat_code = 0
		}
	},
	modifiers   = proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, serial, depressed, latched, locked, group: u32) {
		context = runtime.default_context()
		if xkb_ready(&wl.xkb) {
			wl.xkb.procs.state_update_mask(wl.xkb.state, depressed, latched, locked, 0, 0, group)
		}
	},
	repeat_info = proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, rate, delay: i32) {
		wl.repeat_rate, wl.repeat_delay = rate, delay
	},
}

// The repeats of a held key that are due by `now` (the compositor sends none).
@(private)
make_key_repeats :: proc(now: f64) {
	if wl.repeat_code == 0 || wl.repeat_rate <= 0 || wl.repeat_window == nil {
		return
	}
	interval := 1 / f64(wl.repeat_rate)
	made := 0
	for now >= wl.repeat_next && made < 8 {
		w := wl.repeat_window
		if key := translate_key(&wl.xkb, wl.repeat_code); key != .None {
			queue_input(w, {kind = .Key_Repeat, key = key})
		}
		if c := key_character(&wl.xkb, wl.repeat_code); c != 0 {
			queue_input(w, {kind = .Char, char = c})
		}
		wl.repeat_next += interval
		made += 1
	}
	if made == 8 { // the program was away for long: no flood afterwards
		wl.repeat_next = now + interval
	}
}

// ---- windows ----------------------------------------------------------------------------------------------------------

@(private)
xdg_surface_listener := Xdg_Surface_Listener {
	configure = proc "c" (data: rawptr, surface: ^Xdg_Surface, serial: u32) {
		context = runtime.default_context()
		xdg_surface_ack_configure(surface, serial)
		if w := (^Window)(data); w != nil {
			apply_configure(w)
		}
	},
}

@(private)
toplevel_listener := Toplevel_Listener {
	configure        = proc "c" (data: rawptr, toplevel: ^Xdg_Toplevel, width, height: i32, states: ^Wl_Array) {
		w := (^Window)(data)
		if w == nil {
			return
		}
		w.pending = {int(width), int(height)}
		w.pending_states = {}
		for s in array_u32s(states) {
			if s >= 1 && s <= 9 {
				w.pending_states += {Toplevel_State(s)}
			}
		}
	},
	close            = proc "c" (data: rawptr, toplevel: ^Xdg_Toplevel) {
		if w := (^Window)(data); w != nil {
			w.close_requested = true
			w.events += {.Close_Requested}
		}
	},
	configure_bounds = proc "c" (data: rawptr, toplevel: ^Xdg_Toplevel, width, height: i32) {},
	wm_capabilities  = proc "c" (data: rawptr, toplevel: ^Xdg_Toplevel, capabilities: ^Wl_Array) {},
}

@(private = "file")
decoration_listener := Decoration_Listener {
	configure = proc "c" (data: rawptr, decoration: ^Zxdg_Toplevel_Decoration, mode: u32) {
		if w := (^Window)(data); w != nil {
			w.decorated = mode == DECORATION_MODE_SERVER_SIDE && !w.fullscreen && .No_Decorations not_in w.desc.flags
		}
	},
}

// The compositor's configure, applied once its xdg_surface.configure has closed the batch.
@(private)
apply_configure :: proc(w: ^Window) {
	states := w.pending_states
	w.fullscreen = .Fullscreen in states
	w.maximized = .Maximized in states
	if w.fullscreen {
		w.decorated = false
	}

	focused := .Activated in states
	if focused != w.focused {
		w.focused = focused
		if focused {
			w.events += {.Focus_Gained}
		} else {
			w.events += {.Focus_Lost}
			queue_input(w, {kind = .Focus_Lost})
		}
	}
	suspended := .Suspended in states
	if suspended != w.minimized {
		w.minimized = suspended
		w.events += {.Minimized if suspended else .Restored}
	}

	if w.pending.x > 0 && w.pending.y > 0 { // 0 x 0: the program chooses (it keeps the size it has)
		w.logical = w.pending
	}
	w.configured = true
	size := w.logical * w.scale
	if size != w.size {
		w.size = size
		w.events += {.Resized}
	}
}

// Makes the surface and the xdg objects of a window and waits for the compositor's first configure.
@(private = "file")
make_toplevel :: proc(w: ^Window, desc: Window_Desc) -> bool {
	w.desc = desc
	w.scale = max_output_scale()
	w.has_preferred_scale = false
	w.dpi_scale = f32(w.scale)
	w.logical = {max(desc.width, 1) / w.scale, max(desc.height, 1) / w.scale}
	w.size = w.logical * w.scale
	w.configured = false
	w.pending = {}
	w.pending_states = {}
	w.decorated = false

	w.surface = wl_compositor_create_surface(wl.compositor)
	wl_proxy_set_user_data(proxy_of(w.surface), w)
	wl_proxy_listen(w.surface, &surface_listener, w)
	wl_surface_set_buffer_scale(w.surface, i32(w.scale))

	w.xdg_surface = xdg_wm_base_get_xdg_surface(wl.wm_base, w.surface)
	wl_proxy_listen(w.xdg_surface, &xdg_surface_listener, w)
	w.toplevel = xdg_surface_get_toplevel(w.xdg_surface)
	wl_proxy_listen(w.toplevel, &toplevel_listener, w)

	xdg_toplevel_set_title(w.toplevel, strings.clone_to_cstring(desc.title, context.temp_allocator))
	app_id := desc.app_id if desc.app_id != "" else "iv_system"
	xdg_toplevel_set_app_id(w.toplevel, strings.clone_to_cstring(app_id, context.temp_allocator))
	set_size_limits(w)

	if wl.decoration_manager != nil {
		w.decoration = zxdg_decoration_manager_get_toplevel_decoration(wl.decoration_manager, w.toplevel)
		wl_proxy_listen(w.decoration, &decoration_listener, w)
		// without decorations the program draws its own title bar: ask the compositor for none of its own
		zxdg_toplevel_decoration_set_mode(w.decoration, DECORATION_MODE_CLIENT_SIDE if .No_Decorations in desc.flags else DECORATION_MODE_SERVER_SIDE)
	}
	w.maximized = false
	if .Maximized in desc.flags {
		xdg_toplevel_set_maximized(w.toplevel)
	}
	if .Fullscreen in desc.flags {
		xdg_toplevel_set_fullscreen(w.toplevel, nil)
	}

	append(&wl.windows, w)
	wl_surface_commit(w.surface) // an empty commit: the compositor answers with the first configure
	for _ in 0 ..< 3 {
		if w.configured {
			break
		}
		wl_display_roundtrip(wl.display)
	}
	w.events = {} // what the creation itself stirred up is not news
	clear(&w.input)
	return w.configured
}

// What the program asked for: the minimum size, and a fixed size.
@(private = "file")
set_size_limits :: proc(w: ^Window) {
	min_logical := [2]int{w.desc.min_width / w.scale, w.desc.min_height / w.scale}
	if .Fixed_Size in w.desc.flags {
		xdg_toplevel_set_min_size(w.toplevel, i32(w.logical.x), i32(w.logical.y))
		xdg_toplevel_set_max_size(w.toplevel, i32(w.logical.x), i32(w.logical.y))
	} else {
		xdg_toplevel_set_min_size(w.toplevel, i32(min_logical.x), i32(min_logical.y))
		xdg_toplevel_set_max_size(w.toplevel, 0, 0) // (0: no limit; matters when a fixed window is made resizable)
	}
}

// Takes the protocol objects away (the Window stays).
@(private = "file")
destroy_toplevel :: proc(w: ^Window) {
	for other, i in wl.windows {
		if other == w {
			unordered_remove(&wl.windows, i)
			break
		}
	}
	if wl.pointer_focus == w {
		wl.pointer_focus = nil
	}
	if wl.keyboard_focus == w {
		wl.keyboard_focus = nil
	}
	if wl.repeat_window == w {
		wl.repeat_code, wl.repeat_window = 0, nil
	}
	if w.decoration != nil {
		zxdg_toplevel_decoration_destroy(w.decoration)
	}
	if w.toplevel != nil {
		xdg_toplevel_destroy(w.toplevel)
	}
	if w.xdg_surface != nil {
		xdg_surface_destroy(w.xdg_surface)
	}
	if w.surface != nil {
		wl_surface_destroy(w.surface)
	}
	w.decoration, w.toplevel, w.xdg_surface, w.surface = nil, nil, nil, nil
	clear(&w.entered)
	if wl.display != nil {
		wl_display_flush(wl.display)
	}
}

// ---- the API ----------------------------------------------------------------------------------------------------------

// Makes a window. Fails if there is no Wayland session (WAYLAND_DISPLAY) or the compositor lacks xdg-shell. The window is
// on the screen once something is drawn into it.
create_window :: proc(desc: Window_Desc, allocator := context.allocator) -> (w: ^Window, ok: bool) {
	if !ensure_display() {
		return nil, false
	}
	w = new(Window, allocator)
	w.allocator = allocator
	w.input = make([dynamic]Input_Event, allocator)
	w.entered = make([dynamic]^Wl_Output, allocator)
	if !make_toplevel(w, desc) {
		destroy_toplevel(w)
		delete(w.input)
		delete(w.entered)
		free(w, allocator)
		return nil, false
	}
	return w, true
}

destroy_window :: proc(w: ^Window) {
	if w == nil {
		return
	}
	destroy_toplevel(w)
	allocator := w.allocator
	delete(w.input)
	delete(w.entered)
	free(w, allocator)
}

// Makes the protocol objects again with the same title, size and state; the `^Window` stays the same. Anything that was
// made for the old surface (a swapchain) is gone and must be made again.
recreate_window :: proc(w: ^Window) -> bool {
	desc := w.desc
	desc.width, desc.height = w.size.x, w.size.y
	desc.flags -= {.Fullscreen, .Maximized}
	if w.fullscreen {
		desc.flags += {.Fullscreen}
	}
	if w.maximized {
		desc.flags += {.Maximized}
	}
	destroy_toplevel(w)
	clear(&w.input)
	return make_toplevel(w, desc)
}

// Handles what the compositor has sent (for all windows) and returns what happened to `w` since the last call. Its keys and
// mouse are queued for feed_input.
poll :: proc(w: ^Window) -> Window_Events {
	if wl.display != nil && !wl.broken {
		pump_display()
		make_key_repeats(time_seconds())
	}
	if wl.broken && !w.close_requested {
		w.close_requested = true // the connection is gone: there is nothing to keep the window for
		w.events += {.Close_Requested}
	}
	events := w.events
	w.events = {}
	return events
}

// Sleeps until the compositor sends something or `timeout` seconds have passed (< 0: no limit), whichever is first; then poll. The repeats of a held
// key are made here (the compositor sends none), so a held key wakes it when the next repeat is due.
wait_events :: proc(w: ^Window, timeout: f64) {
	if wl.display == nil || wl.broken || len(w.input) > 0 || w.events != {} {
		return
	}
	limit := timeout
	if wl.repeat_code != 0 && wl.repeat_rate > 0 && wl.repeat_window != nil {
		due := max(wl.repeat_next - time_seconds(), 0)
		limit = due if limit < 0 else min(limit, due)
	}
	ms := i32(-1) if limit < 0 else i32(min(limit * 1000, 1e9))
	display := wl.display
	for wl_display_prepare_read(display) != 0 {
		wl_display_dispatch_pending(display)
	}
	wl_display_flush(display)
	fds := [1]linux.Poll_Fd{{fd = linux.Fd(wl_display_get_fd(display)), events = {.IN}}}
	if n, _ := linux.poll(fds[:], ms); n > 0 {
		wl_display_read_events(display)
	} else {
		wl_display_cancel_read(display)
	}
}

// (Window_Desc.background is not used here: the compositor shows nothing until the first frame.)
stop_background :: proc(w: ^Window) {}

// Reads the socket without blocking and runs the listeners of what arrived.
@(private = "file")
pump_display :: proc() {
	display := wl.display
	for wl_display_prepare_read(display) != 0 {
		wl_display_dispatch_pending(display) // events are already queued: they come first
	}
	wl_display_flush(display)
	fds := [1]linux.Poll_Fd{{fd = linux.Fd(wl_display_get_fd(display)), events = {.IN}}}
	if n, _ := linux.poll(fds[:], 0); n > 0 {
		wl_display_read_events(display)
	} else {
		wl_display_cancel_read(display)
	}
	wl_display_dispatch_pending(display)
	if wl_display_get_error(display) != 0 {
		wl.broken = true
	}
}

set_title :: proc(w: ^Window, title: string) {
	w.desc.title = title // not copied: keep it alive (a literal is fine)
	xdg_toplevel_set_title(w.toplevel, strings.clone_to_cstring(title, context.temp_allocator))
	wl_display_flush(wl.display)
}

// Asks for fullscreen on the monitor the window is on, and back. w.fullscreen changes when the compositor agrees (poll).
set_fullscreen :: proc(w: ^Window, on: bool) {
	if on {
		xdg_toplevel_set_fullscreen(w.toplevel, nil)
	} else {
		xdg_toplevel_unset_fullscreen(w.toplevel)
	}
	wl_display_flush(wl.display)
}

// A floating Wayland window is the size of what is drawn into it: this sets the size the program will draw at (in buffer
// pixels), and the graphics backend follows it. Ignored in fullscreen. w.size and .Resized report it.
set_size :: proc(w: ^Window, width, height: int) {
	if w.fullscreen || w.surface == nil {
		return
	}
	logical := [2]int{max(width, 1) / w.scale, max(height, 1) / w.scale}
	if logical == w.logical {
		return
	}
	w.logical = logical
	w.size = logical * w.scale
	w.events += {.Resized}
}

// Lets the user move the window with the pointer button that is down now (the compositor takes over until it is released).
begin_move :: proc(w: ^Window) {
	if w.toplevel != nil && wl.seat != nil {
		xdg_toplevel_move(w.toplevel, wl.seat, wl.button_serial)
		wl_display_flush(wl.display)
	}
}

// The same for resizing from an edge or corner.
begin_resize :: proc(w: ^Window, edge: Resize_Edge) {
	if w.toplevel == nil || wl.seat == nil {
		return
	}
	edges: u32 // xdg_toplevel.resize_edge: top 1, bottom 2, left 4, right 8, and the sums
	switch edge {
	case .Top:
		edges = 1
	case .Bottom:
		edges = 2
	case .Left:
		edges = 4
	case .Top_Left:
		edges = 5
	case .Bottom_Left:
		edges = 6
	case .Right:
		edges = 8
	case .Top_Right:
		edges = 9
	case .Bottom_Right:
		edges = 10
	}
	xdg_toplevel_resize(w.toplevel, wl.seat, wl.button_serial, edges)
	wl_display_flush(wl.display)
}

// A Wayland window shows when something is drawn into it, so there is nothing to show or hide.
set_visible :: proc(w: ^Window, visible: bool) {
}

// w.maximized follows when the compositor has done it (poll).
maximize :: proc(w: ^Window) {
	xdg_toplevel_set_maximized(w.toplevel)
	wl_display_flush(wl.display)
}

// Back from maximized to the size before. (Wayland has no "restore" from minimized: the compositor decides when a minimized window comes back.)
restore :: proc(w: ^Window) {
	xdg_toplevel_unset_maximized(w.toplevel)
	wl_display_flush(wl.display)
}

minimize :: proc(w: ^Window) {
	xdg_toplevel_set_minimized(w.toplevel)
	wl_display_flush(wl.display)
}

// Asks the compositor to draw the title bar and border (or not; the .No_Decorations flag). A compositor without xdg-decoration (GNOME) never does:
// then the window stays undecorated whatever is asked, and w.decorated says so (it changes when the compositor answers).
set_decorated :: proc(w: ^Window, on: bool) {
	if on {
		w.desc.flags -= {.No_Decorations}
	} else {
		w.desc.flags += {.No_Decorations}
	}
	if w.decoration != nil {
		zxdg_toplevel_decoration_set_mode(w.decoration, DECORATION_MODE_SERVER_SIDE if on else DECORATION_MODE_CLIENT_SIDE)
		wl_display_flush(wl.display)
	}
}

// Lets the user resize the window, or not (the .Fixed_Size flag).
set_resizable :: proc(w: ^Window, on: bool) {
	if on {
		w.desc.flags -= {.Fixed_Size}
	} else {
		w.desc.flags += {.Fixed_Size}
	}
	set_size_limits(w)
	wl_display_flush(wl.display)
}

// Wayland has no "above the other windows" for ordinary programs: only the flag is remembered.
set_always_on_top :: proc(w: ^Window, on: bool) {
	if on {
		w.desc.flags += {.Always_On_Top}
	} else {
		w.desc.flags -= {.Always_On_Top}
	}
}

// ---- the mouse cursor ----

set_cursor_visible :: proc(w: ^Window, visible: bool) {
	w.cursor_hidden = !visible
	apply_cursor(w)
}

set_cursor_shape :: proc(w: ^Window, shape: Cursor_Shape) {
	w.cursor_shape = shape
	apply_cursor(w)
}

// Wayland does not let a program move the pointer (that needs the compositor's permission: pointer-constraints): always
// false. A program that hides the cursor and draws its own does not need it.
set_mouse_position :: proc(w: ^Window, x, y: int) -> bool {
	return false
}

// ---- the clipboard ----
// To do: wl_data_device. Until then the clipboard is the program's own: text copied in one window can be pasted in another
// of this program, and nothing is shared with other programs.

@(private)
clipboard: [dynamic]u8

clipboard_text :: proc(w: ^Window, allocator := context.allocator) -> (text: string, ok: bool) {
	if len(clipboard) == 0 {
		return "", false
	}
	return strings.clone(string(clipboard[:]), allocator), true
}

set_clipboard_text :: proc(w: ^Window, text: string) -> bool {
	clear(&clipboard)
	append(&clipboard, text)
	return true
}

// ---- the folder dialog ----

// Asks the user for a folder. To do: there is no native dialog here yet (that would be the xdg-desktop-portal's FileChooser over D-Bus), so this always
// says "cancelled"; a program can fall back to a folder given on its command line.
pick_folder :: proc(w: ^Window, title: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return "", false
}

// The installed font families. To do: fontconfig. Until then there are none, and a program falls back to fonts of its own.
list_font_families :: proc(allocator := context.allocator) -> []Font_Family {
	return nil
}

// The bytes of a family's regular face. To do with list_font_families: always false here.
font_data :: proc(family: string, bold := false, allocator := context.allocator) -> (data: []u8, ok: bool) {
	return nil, false
}

// Asks the user where to save a file. To do, as pick_folder: no dialog yet, so this always says "cancelled".
pick_save_file :: proc(w: ^Window, title, suggested, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return "", false
}

// Asks whether to save unsaved changes. To do: no message box yet, so `ok` is always false (the caller has to ask some other way).
ask_yes_no :: proc(w: ^Window, title, text: string) -> (yes: bool, ok: bool) {
	return false, false
}

pick_program :: proc(w: ^Window, title, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return "", false
}

show_in_file_manager :: proc(path: string, is_dir: bool) -> bool {
	return false // (not done yet: xdg-open, or org.freedesktop.FileManager1's ShowItems)
}

run_program :: proc(program, args: string) -> bool {
	return false
}

move_to_trash :: proc(path: string) -> bool {
	return false // (not done yet: the freedesktop trash folder)
}

ask_save_changes :: proc(w: ^Window, title, text: string) -> (answer: Save_Answer, ok: bool) {
	return .Cancel, false
}

// ---- gamepads ----
// The joystick interface (/dev/input/js0 ..): one nonblocking read of events per pad per frame. The pads are taken to lay
// their buttons and axes out the way the Linux xpad driver does for an Xbox pad (the usual one; a PlayStation or Switch
// pad under another driver may differ: SDL's controller database is what fixes that, and is not here). A missing pad is
// looked for again once a second.

JS_EVENT_BUTTON :: 0x01
JS_EVENT_AXIS :: 0x02
JS_EVENT_INIT :: 0x80

@(private = "file")
Js_Pad :: struct {
	fd:         linux.Fd,
	open:       bool,
	next_scan:  f64,
	buttons:    [16]bool,
	axes:       [8]i16,
}

@(private = "file")
js_pads: [input.MAX_PADS]Js_Pad

read_gamepads :: proc(pads: ^[input.MAX_PADS]Pad_State) {
	now := time_seconds()
	for i in 0 ..< input.MAX_PADS {
		js := &js_pads[i]
		if !js.open {
			if now < js.next_scan {
				continue
			}
			js.next_scan = now + 1
			path := fmt_js_path(i)
			fd, errno := linux.open(path, {.NONBLOCK, .CLOEXEC})
			if errno != .NONE {
				continue
			}
			js.fd, js.open = fd, true
		}
		// 8 bytes an event: time u32, value i16, type u8, number u8
		buf: [8 * 64]u8
		for {
			n, errno := linux.read(js.fd, buf[:])
			if errno == .EAGAIN {
				break
			}
			if errno != .NONE || n <= 0 { // unplugged
				_ = linux.close(js.fd)
				js^ = {next_scan = now + 1}
				break
			}
			for offset := 0; offset + 8 <= n; offset += 8 {
				value := (^i16)(&buf[offset + 4])^
				kind := buf[offset + 6] & ~u8(JS_EVENT_INIT)
				number := int(buf[offset + 7])
				switch kind {
				case JS_EVENT_BUTTON:
					if number < len(js.buttons) {
						js.buttons[number] = value != 0
					}
				case JS_EVENT_AXIS:
					if number < len(js.axes) {
						js.axes[number] = value
					}
				}
			}
			if n < len(buf) {
				break
			}
		}
		if !js.open {
			continue
		}
		p := &pads[i]
		p.connected = true
		p.buttons[.Face_Down] = js.buttons[0]
		p.buttons[.Face_Right] = js.buttons[1]
		p.buttons[.Face_Left] = js.buttons[2]
		p.buttons[.Face_Up] = js.buttons[3]
		p.buttons[.Left_Shoulder] = js.buttons[4]
		p.buttons[.Right_Shoulder] = js.buttons[5]
		p.buttons[.Back] = js.buttons[6]
		p.buttons[.Start] = js.buttons[7]
		p.buttons[.Guide] = js.buttons[8]
		p.buttons[.Left_Stick] = js.buttons[9]
		p.buttons[.Right_Stick] = js.buttons[10]
		axis :: proc "contextless" (v: i16) -> f32 {
			return max(f32(v) / 32767, -1)
		}
		p.axes[.Left_X] = axis(js.axes[0])
		p.axes[.Left_Y] = axis(js.axes[1])
		p.axes[.Right_X] = axis(js.axes[3])
		p.axes[.Right_Y] = axis(js.axes[4])
		// the triggers rest at -32767 and go to +32767
		p.axes[.Left_Trigger] = (axis(js.axes[2]) + 1) / 2
		p.axes[.Right_Trigger] = (axis(js.axes[5]) + 1) / 2
		p.buttons[.Left_Trigger] = p.axes[.Left_Trigger] > 0.5
		p.buttons[.Right_Trigger] = p.axes[.Right_Trigger] > 0.5
		// the d-pad is a pair of axes (-1, 0, +1)
		p.buttons[.Dpad_Left] = js.axes[6] < -16384
		p.buttons[.Dpad_Right] = js.axes[6] > 16384
		p.buttons[.Dpad_Up] = js.axes[7] < -16384
		p.buttons[.Dpad_Down] = js.axes[7] > 16384
	}
}

@(private = "file")
fmt_js_path :: proc(i: int) -> cstring {
	paths := [?]cstring{"/dev/input/js0", "/dev/input/js1", "/dev/input/js2", "/dev/input/js3"}
	return paths[i]
}

// For whoever draws into the window: the wl_surface, and the wl_display it belongs to (a Vulkan WSI is given both).
native_handle :: proc(w: ^Window) -> Native_Handle {
	return {window = rawptr(w.surface), display = rawptr(wl.display)}
}

// Seconds since some fixed point (a monotonic clock): for timing frames.
time_seconds :: proc() -> f64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return f64(ts.time_sec) + f64(ts.time_nsec) / 1e9
}
