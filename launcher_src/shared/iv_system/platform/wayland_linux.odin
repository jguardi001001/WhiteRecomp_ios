package platform

import "core:c"

// ---------------------------------------------------------------------------
// The Wayland protocol, as far as platform_linux.odin uses it: bindings to libwayland-client (the wire protocol, the event
// queue, the objects), and the generated parts a protocol has, written by hand: the `wl_interface` tables of the protocols
// that are not in libwayland itself (xdg-shell, xdg-decoration), the request functions, and the listener structs.
//
// libwayland-client is linked (not loaded at run time): a program on Wayland has it, and the Vulkan loader needs the very
// same `wl_display` this layer connects (VK_KHR_wayland_surface is given the display and the surface proxy, so the protocol
// connection cannot be a private implementation).
//
// How to read it: every Wayland object is a `Proxy`; a request is `wl_proxy_marshal_flags(proxy, opcode, interface of the new
// object (or nil), version, flags, arguments...)` and an event arrives in a listener, a struct of C procedures in the order of
// the protocol's events. The opcodes and event orders are the protocol XML's (wayland.xml, xdg-shell.xml,
// xdg-decoration-unstable-v1.xml); see the numbers in the comments.
// ---------------------------------------------------------------------------

foreign import wayland_client "system:wayland-client"

// ---- the library ---------------------------------------------------------------------------------------------

Wl_Message :: struct {
	name:      cstring,
	signature: cstring, // "2iu?os": an optional since-version, then one letter per argument (? = may be null)
	types:     [^]^Wl_Interface, // one per argument: the interface of an object / new_id argument, else nil
}

Wl_Interface :: struct {
	name:         cstring,
	version:      c.int,
	method_count: c.int, // requests
	methods:      [^]Wl_Message,
	event_count:  c.int,
	events:       [^]Wl_Message,
}

Wl_Array :: struct {
	size:  c.size_t,
	alloc: c.size_t,
	data:  rawptr,
}

Wl_Fixed :: distinct i32 // 24.8 fixed point

fixed_to_f32 :: proc "contextless" (f: Wl_Fixed) -> f32 {
	return f32(f) / 256
}

// every object is a proxy; the typed names only keep arguments apart
Proxy :: struct {}
Wl_Display :: struct {}
Wl_Registry :: struct {}
Wl_Compositor :: struct {}
Wl_Surface :: struct {}
Wl_Seat :: struct {}
Wl_Pointer :: struct {}
Wl_Keyboard :: struct {}
Wl_Output :: struct {}
Wl_Shm :: struct {}
Wl_Buffer :: struct {}
Xdg_Wm_Base :: struct {}
Xdg_Surface :: struct {}
Xdg_Toplevel :: struct {}
Zxdg_Decoration_Manager :: struct {}
Zxdg_Toplevel_Decoration :: struct {}

MARSHAL_FLAG_DESTROY :: 1

@(default_calling_convention = "c")
foreign wayland_client {
	wl_display_connect :: proc(name: cstring) -> ^Wl_Display ---
	wl_display_disconnect :: proc(display: ^Wl_Display) ---
	wl_display_get_fd :: proc(display: ^Wl_Display) -> c.int ---
	wl_display_roundtrip :: proc(display: ^Wl_Display) -> c.int ---
	wl_display_dispatch_pending :: proc(display: ^Wl_Display) -> c.int ---
	wl_display_flush :: proc(display: ^Wl_Display) -> c.int ---
	wl_display_prepare_read :: proc(display: ^Wl_Display) -> c.int ---
	wl_display_read_events :: proc(display: ^Wl_Display) -> c.int ---
	wl_display_cancel_read :: proc(display: ^Wl_Display) ---
	wl_display_get_error :: proc(display: ^Wl_Display) -> c.int ---

	wl_proxy_marshal_flags :: proc(proxy: ^Proxy, opcode: u32, interface: ^Wl_Interface, version: u32, flags: u32, #c_vararg args: ..any) -> ^Proxy ---
	wl_proxy_add_listener :: proc(proxy: ^Proxy, implementation: rawptr, data: rawptr) -> c.int ---
	wl_proxy_get_version :: proc(proxy: ^Proxy) -> u32 ---
	wl_proxy_set_user_data :: proc(proxy: ^Proxy, data: rawptr) ---
	wl_proxy_get_user_data :: proc(proxy: ^Proxy) -> rawptr ---

	// the interfaces of the core protocol, which libwayland-client carries
	wl_registry_interface: Wl_Interface
	wl_compositor_interface: Wl_Interface
	wl_surface_interface: Wl_Interface
	wl_seat_interface: Wl_Interface
	wl_pointer_interface: Wl_Interface
	wl_keyboard_interface: Wl_Interface
	wl_output_interface: Wl_Interface
	wl_shm_interface: Wl_Interface
	wl_callback_interface: Wl_Interface
}

// ---- the interfaces that are not in the library ----------------------------------------------------------------------
// (what wayland-scanner would generate from xdg-shell.xml and xdg-decoration-unstable-v1.xml)

xdg_wm_base_interface: Wl_Interface
xdg_positioner_interface: Wl_Interface
xdg_surface_interface: Wl_Interface
xdg_toplevel_interface: Wl_Interface
xdg_popup_interface: Wl_Interface
zxdg_decoration_manager_v1_interface: Wl_Interface
zxdg_toplevel_decoration_v1_interface: Wl_Interface

@(private = "file")
no_types: [8]^Wl_Interface // for the messages that have no object arguments

@(private = "file")
types_get_xdg_surface: [2]^Wl_Interface
@(private = "file")
types_create_positioner: [1]^Wl_Interface
@(private = "file")
types_get_toplevel: [1]^Wl_Interface
@(private = "file")
types_get_popup: [3]^Wl_Interface
@(private = "file")
types_set_parent: [1]^Wl_Interface
@(private = "file")
types_seat_serial: [2]^Wl_Interface // (seat, serial)
@(private = "file")
types_seat_serial_x: [3]^Wl_Interface // (seat, serial, edges)
@(private = "file")
types_menu: [4]^Wl_Interface // (seat, serial, x, y)
@(private = "file")
types_set_fullscreen: [1]^Wl_Interface
@(private = "file")
types_positioner_serial: [2]^Wl_Interface // (positioner, serial)
@(private = "file")
types_decoration: [2]^Wl_Interface

@(private = "file")
xdg_wm_base_methods: [4]Wl_Message
@(private = "file")
xdg_wm_base_events: [1]Wl_Message
@(private = "file")
xdg_positioner_methods: [10]Wl_Message
@(private = "file")
xdg_surface_methods: [5]Wl_Message
@(private = "file")
xdg_surface_events: [1]Wl_Message
@(private = "file")
xdg_toplevel_methods: [14]Wl_Message
@(private = "file")
xdg_toplevel_events: [4]Wl_Message
@(private = "file")
xdg_popup_methods: [3]Wl_Message
@(private = "file")
xdg_popup_events: [3]Wl_Message
@(private = "file")
deco_manager_methods: [2]Wl_Message
@(private = "file")
deco_methods: [3]Wl_Message
@(private = "file")
deco_events: [1]Wl_Message

@(init)
init_interfaces :: proc "contextless" () {
	none := raw_data(no_types[:])

	// xdg_wm_base (version 6)
	types_create_positioner = {&xdg_positioner_interface}
	types_get_xdg_surface = {&xdg_surface_interface, &wl_surface_interface}
	xdg_wm_base_methods = {
		{"destroy", "", none},
		{"create_positioner", "n", raw_data(types_create_positioner[:])},
		{"get_xdg_surface", "no", raw_data(types_get_xdg_surface[:])},
		{"pong", "u", none},
	}
	xdg_wm_base_events = {{"ping", "u", none}}
	xdg_wm_base_interface = {"xdg_wm_base", 6, 4, raw_data(xdg_wm_base_methods[:]), 1, raw_data(xdg_wm_base_events[:])}

	// xdg_positioner (never made here; the table only has to exist because xdg_wm_base and xdg_popup name it)
	xdg_positioner_methods = {
		{"destroy", "", none},
		{"set_size", "ii", none},
		{"set_anchor_rect", "iiii", none},
		{"set_anchor", "u", none},
		{"set_gravity", "u", none},
		{"set_constraint_adjustment", "u", none},
		{"set_offset", "ii", none},
		{"set_reactive", "3", none},
		{"set_parent_size", "3ii", none},
		{"set_parent_configure", "3u", none},
	}
	xdg_positioner_interface = {"xdg_positioner", 6, 10, raw_data(xdg_positioner_methods[:]), 0, nil}

	// xdg_surface (version 6)
	types_get_toplevel = {&xdg_toplevel_interface}
	types_get_popup = {&xdg_popup_interface, &xdg_surface_interface, &xdg_positioner_interface}
	xdg_surface_methods = {
		{"destroy", "", none},
		{"get_toplevel", "n", raw_data(types_get_toplevel[:])},
		{"get_popup", "n?oo", raw_data(types_get_popup[:])},
		{"set_window_geometry", "iiii", none},
		{"ack_configure", "u", none},
	}
	xdg_surface_events = {{"configure", "u", none}}
	xdg_surface_interface = {"xdg_surface", 6, 5, raw_data(xdg_surface_methods[:]), 1, raw_data(xdg_surface_events[:])}

	// xdg_toplevel (version 6)
	types_set_parent = {&xdg_toplevel_interface}
	types_seat_serial = {&wl_seat_interface, nil}
	types_seat_serial_x = {&wl_seat_interface, nil, nil}
	types_menu = {&wl_seat_interface, nil, nil, nil}
	types_set_fullscreen = {&wl_output_interface}
	xdg_toplevel_methods = {
		{"destroy", "", none},
		{"set_parent", "?o", raw_data(types_set_parent[:])},
		{"set_title", "s", none},
		{"set_app_id", "s", none},
		{"show_window_menu", "ouii", raw_data(types_menu[:])},
		{"move", "ou", raw_data(types_seat_serial[:])},
		{"resize", "ouu", raw_data(types_seat_serial_x[:])},
		{"set_max_size", "ii", none},
		{"set_min_size", "ii", none},
		{"set_maximized", "", none},
		{"unset_maximized", "", none},
		{"set_fullscreen", "?o", raw_data(types_set_fullscreen[:])},
		{"unset_fullscreen", "", none},
		{"set_minimized", "", none},
	}
	xdg_toplevel_events = {
		{"configure", "iia", none},
		{"close", "", none},
		{"configure_bounds", "4ii", none},
		{"wm_capabilities", "5a", none},
	}
	xdg_toplevel_interface = {"xdg_toplevel", 6, 14, raw_data(xdg_toplevel_methods[:]), 4, raw_data(xdg_toplevel_events[:])}

	// xdg_popup (never made here either)
	types_positioner_serial = {&xdg_positioner_interface, nil}
	xdg_popup_methods = {
		{"destroy", "", none},
		{"grab", "ou", raw_data(types_seat_serial[:])},
		{"reposition", "3ou", raw_data(types_positioner_serial[:])},
	}
	xdg_popup_events = {{"configure", "iiii", none}, {"popup_done", "", none}, {"repositioned", "3u", none}}
	xdg_popup_interface = {"xdg_popup", 6, 3, raw_data(xdg_popup_methods[:]), 3, raw_data(xdg_popup_events[:])}

	// zxdg_decoration_manager_v1 and zxdg_toplevel_decoration_v1 (version 1)
	types_decoration = {&zxdg_toplevel_decoration_v1_interface, &xdg_toplevel_interface}
	deco_manager_methods = {{"destroy", "", none}, {"get_toplevel_decoration", "no", raw_data(types_decoration[:])}}
	zxdg_decoration_manager_v1_interface = {"zxdg_decoration_manager_v1", 1, 2, raw_data(deco_manager_methods[:]), 0, nil}
	deco_methods = {{"destroy", "", none}, {"set_mode", "u", none}, {"unset_mode", "", none}}
	deco_events = {{"configure", "u", none}}
	zxdg_toplevel_decoration_v1_interface = {"zxdg_toplevel_decoration_v1", 1, 3, raw_data(deco_methods[:]), 1, raw_data(deco_events[:])}
}

// ---- requests ---------------------------------------------------------------------------------------------------
// (wayland-scanner writes these as inline functions; the opcode is the request's position in its interface)

@(private)
proxy_of :: #force_inline proc "contextless" (p: rawptr) -> ^Proxy {
	return (^Proxy)(p)
}

@(private)
version_of :: #force_inline proc "contextless" (p: rawptr) -> u32 {
	return wl_proxy_get_version(proxy_of(p))
}

wl_display_get_registry :: proc "contextless" (d: ^Wl_Display) -> ^Wl_Registry {
	return (^Wl_Registry)(wl_proxy_marshal_flags(proxy_of(d), 1, &wl_registry_interface, version_of(d), 0, rawptr(nil)))
}

// Makes the object of the `name` the registry announced, speaking at `version` (at most what it announced).
wl_registry_bind :: proc "contextless" (r: ^Wl_Registry, name: u32, interface: ^Wl_Interface, version: u32) -> rawptr {
	return rawptr(wl_proxy_marshal_flags(proxy_of(r), 0, interface, version, 0, name, interface.name, version, rawptr(nil)))
}

wl_compositor_create_surface :: proc "contextless" (c: ^Wl_Compositor) -> ^Wl_Surface {
	return (^Wl_Surface)(wl_proxy_marshal_flags(proxy_of(c), 0, &wl_surface_interface, version_of(c), 0, rawptr(nil)))
}

wl_surface_destroy :: proc "contextless" (s: ^Wl_Surface) {
	wl_proxy_marshal_flags(proxy_of(s), 0, nil, version_of(s), MARSHAL_FLAG_DESTROY)
}

wl_surface_attach :: proc "contextless" (s: ^Wl_Surface, buffer: ^Wl_Buffer, x, y: i32) {
	wl_proxy_marshal_flags(proxy_of(s), 1, nil, version_of(s), 0, rawptr(buffer), x, y)
}

wl_surface_commit :: proc "contextless" (s: ^Wl_Surface) {
	wl_proxy_marshal_flags(proxy_of(s), 6, nil, version_of(s), 0)
}

wl_surface_set_buffer_scale :: proc "contextless" (s: ^Wl_Surface, scale: i32) {
	if version_of(s) >= 3 {
		wl_proxy_marshal_flags(proxy_of(s), 8, nil, version_of(s), 0, scale)
	}
}

wl_surface_damage_buffer :: proc "contextless" (s: ^Wl_Surface, x, y, w, h: i32) {
	if version_of(s) >= 4 {
		wl_proxy_marshal_flags(proxy_of(s), 9, nil, version_of(s), 0, x, y, w, h)
	}
}

wl_seat_get_pointer :: proc "contextless" (s: ^Wl_Seat) -> ^Wl_Pointer {
	return (^Wl_Pointer)(wl_proxy_marshal_flags(proxy_of(s), 0, &wl_pointer_interface, version_of(s), 0, rawptr(nil)))
}

wl_seat_get_keyboard :: proc "contextless" (s: ^Wl_Seat) -> ^Wl_Keyboard {
	return (^Wl_Keyboard)(wl_proxy_marshal_flags(proxy_of(s), 1, &wl_keyboard_interface, version_of(s), 0, rawptr(nil)))
}

// (wl_pointer and wl_keyboard have a `release` request since version 3 / 3; before that the proxy is only destroyed)
wl_pointer_release :: proc "contextless" (p: ^Wl_Pointer) {
	if version_of(p) >= 3 {
		wl_proxy_marshal_flags(proxy_of(p), 1, nil, version_of(p), MARSHAL_FLAG_DESTROY)
	}
}

wl_keyboard_release :: proc "contextless" (k: ^Wl_Keyboard) {
	if version_of(k) >= 3 {
		wl_proxy_marshal_flags(proxy_of(k), 0, nil, version_of(k), MARSHAL_FLAG_DESTROY)
	}
}

wl_pointer_set_cursor :: proc "contextless" (p: ^Wl_Pointer, serial: u32, surface: ^Wl_Surface, hotspot_x, hotspot_y: i32) {
	wl_proxy_marshal_flags(proxy_of(p), 0, nil, version_of(p), 0, serial, rawptr(surface), hotspot_x, hotspot_y)
}

xdg_wm_base_destroy :: proc "contextless" (b: ^Xdg_Wm_Base) {
	wl_proxy_marshal_flags(proxy_of(b), 0, nil, version_of(b), MARSHAL_FLAG_DESTROY)
}

xdg_wm_base_get_xdg_surface :: proc "contextless" (b: ^Xdg_Wm_Base, s: ^Wl_Surface) -> ^Xdg_Surface {
	return (^Xdg_Surface)(wl_proxy_marshal_flags(proxy_of(b), 2, &xdg_surface_interface, version_of(b), 0, rawptr(nil), rawptr(s)))
}

xdg_wm_base_pong :: proc "contextless" (b: ^Xdg_Wm_Base, serial: u32) {
	wl_proxy_marshal_flags(proxy_of(b), 3, nil, version_of(b), 0, serial)
}

xdg_surface_destroy :: proc "contextless" (s: ^Xdg_Surface) {
	wl_proxy_marshal_flags(proxy_of(s), 0, nil, version_of(s), MARSHAL_FLAG_DESTROY)
}

xdg_surface_get_toplevel :: proc "contextless" (s: ^Xdg_Surface) -> ^Xdg_Toplevel {
	return (^Xdg_Toplevel)(wl_proxy_marshal_flags(proxy_of(s), 1, &xdg_toplevel_interface, version_of(s), 0, rawptr(nil)))
}

xdg_surface_ack_configure :: proc "contextless" (s: ^Xdg_Surface, serial: u32) {
	wl_proxy_marshal_flags(proxy_of(s), 4, nil, version_of(s), 0, serial)
}

xdg_toplevel_destroy :: proc "contextless" (t: ^Xdg_Toplevel) {
	wl_proxy_marshal_flags(proxy_of(t), 0, nil, version_of(t), MARSHAL_FLAG_DESTROY)
}

xdg_toplevel_set_title :: proc "contextless" (t: ^Xdg_Toplevel, title: cstring) {
	wl_proxy_marshal_flags(proxy_of(t), 2, nil, version_of(t), 0, title)
}

xdg_toplevel_set_app_id :: proc "contextless" (t: ^Xdg_Toplevel, app_id: cstring) {
	wl_proxy_marshal_flags(proxy_of(t), 3, nil, version_of(t), 0, app_id)
}

xdg_toplevel_move :: proc "contextless" (t: ^Xdg_Toplevel, seat: ^Wl_Seat, serial: u32) {
	wl_proxy_marshal_flags(proxy_of(t), 5, nil, version_of(t), 0, rawptr(seat), serial)
}

xdg_toplevel_resize :: proc "contextless" (t: ^Xdg_Toplevel, seat: ^Wl_Seat, serial: u32, edges: u32) {
	wl_proxy_marshal_flags(proxy_of(t), 6, nil, version_of(t), 0, rawptr(seat), serial, edges)
}

xdg_toplevel_set_max_size :: proc "contextless" (t: ^Xdg_Toplevel, w, h: i32) {
	wl_proxy_marshal_flags(proxy_of(t), 7, nil, version_of(t), 0, w, h)
}

xdg_toplevel_set_min_size :: proc "contextless" (t: ^Xdg_Toplevel, w, h: i32) {
	wl_proxy_marshal_flags(proxy_of(t), 8, nil, version_of(t), 0, w, h)
}

xdg_toplevel_set_maximized :: proc "contextless" (t: ^Xdg_Toplevel) {
	wl_proxy_marshal_flags(proxy_of(t), 9, nil, version_of(t), 0)
}

xdg_toplevel_unset_maximized :: proc "contextless" (t: ^Xdg_Toplevel) {
	wl_proxy_marshal_flags(proxy_of(t), 10, nil, version_of(t), 0)
}

xdg_toplevel_set_fullscreen :: proc "contextless" (t: ^Xdg_Toplevel, output: ^Wl_Output) {
	wl_proxy_marshal_flags(proxy_of(t), 11, nil, version_of(t), 0, rawptr(output))
}

xdg_toplevel_unset_fullscreen :: proc "contextless" (t: ^Xdg_Toplevel) {
	wl_proxy_marshal_flags(proxy_of(t), 12, nil, version_of(t), 0)
}

xdg_toplevel_set_minimized :: proc "contextless" (t: ^Xdg_Toplevel) {
	wl_proxy_marshal_flags(proxy_of(t), 13, nil, version_of(t), 0)
}

zxdg_decoration_manager_destroy :: proc "contextless" (m: ^Zxdg_Decoration_Manager) {
	wl_proxy_marshal_flags(proxy_of(m), 0, nil, version_of(m), MARSHAL_FLAG_DESTROY)
}

zxdg_decoration_manager_get_toplevel_decoration :: proc "contextless" (m: ^Zxdg_Decoration_Manager, t: ^Xdg_Toplevel) -> ^Zxdg_Toplevel_Decoration {
	return (^Zxdg_Toplevel_Decoration)(
		wl_proxy_marshal_flags(proxy_of(m), 1, &zxdg_toplevel_decoration_v1_interface, version_of(m), 0, rawptr(nil), rawptr(t)),
	)
}

zxdg_toplevel_decoration_destroy :: proc "contextless" (d: ^Zxdg_Toplevel_Decoration) {
	wl_proxy_marshal_flags(proxy_of(d), 0, nil, version_of(d), MARSHAL_FLAG_DESTROY)
}

zxdg_toplevel_decoration_set_mode :: proc "contextless" (d: ^Zxdg_Toplevel_Decoration, mode: u32) {
	wl_proxy_marshal_flags(proxy_of(d), 1, nil, version_of(d), 0, mode)
}

// ---- events: the listeners ---------------------------------------------------------------------------------------
// A listener is a struct of C procedures in the order of the interface's events; libwayland calls entry i for opcode i.
// Every entry must be filled (a nil one would be called, and crash, if the compositor sends that event).

wl_proxy_listen :: proc "contextless" (proxy: rawptr, listener: rawptr, data: rawptr) {
	wl_proxy_add_listener(proxy_of(proxy), listener, data)
}

Registry_Listener :: struct {
	global:        proc "c" (data: rawptr, registry: ^Wl_Registry, name: u32, interface: cstring, version: u32),
	global_remove: proc "c" (data: rawptr, registry: ^Wl_Registry, name: u32),
}

Surface_Listener :: struct {
	enter:                      proc "c" (data: rawptr, surface: ^Wl_Surface, output: ^Wl_Output),
	leave:                      proc "c" (data: rawptr, surface: ^Wl_Surface, output: ^Wl_Output),
	preferred_buffer_scale:     proc "c" (data: rawptr, surface: ^Wl_Surface, factor: i32), // since 6
	preferred_buffer_transform: proc "c" (data: rawptr, surface: ^Wl_Surface, transform: u32), // since 6
}

Output_Listener :: struct {
	geometry:    proc "c" (
		data: rawptr,
		output: ^Wl_Output,
		x, y, physical_width, physical_height, subpixel: i32,
		make, model: cstring,
		transform: i32,
	),
	mode:        proc "c" (data: rawptr, output: ^Wl_Output, flags: u32, width, height, refresh: i32),
	done:        proc "c" (data: rawptr, output: ^Wl_Output),
	scale:       proc "c" (data: rawptr, output: ^Wl_Output, factor: i32), // since 2
	name:        proc "c" (data: rawptr, output: ^Wl_Output, name: cstring), // since 4
	description: proc "c" (data: rawptr, output: ^Wl_Output, description: cstring), // since 4
}

Seat_Listener :: struct {
	capabilities: proc "c" (data: rawptr, seat: ^Wl_Seat, capabilities: u32), // bit 0 pointer, 1 keyboard, 2 touch
	name:         proc "c" (data: rawptr, seat: ^Wl_Seat, name: cstring),
}

Pointer_Listener :: struct {
	enter:                   proc "c" (data: rawptr, pointer: ^Wl_Pointer, serial: u32, surface: ^Wl_Surface, x, y: Wl_Fixed),
	leave:                   proc "c" (data: rawptr, pointer: ^Wl_Pointer, serial: u32, surface: ^Wl_Surface),
	motion:                  proc "c" (data: rawptr, pointer: ^Wl_Pointer, time: u32, x, y: Wl_Fixed),
	button:                  proc "c" (data: rawptr, pointer: ^Wl_Pointer, serial, time, button, state: u32),
	axis:                    proc "c" (data: rawptr, pointer: ^Wl_Pointer, time, axis: u32, value: Wl_Fixed), // since 1
	frame:                   proc "c" (data: rawptr, pointer: ^Wl_Pointer), // since 5
	axis_source:             proc "c" (data: rawptr, pointer: ^Wl_Pointer, source: u32),
	axis_stop:               proc "c" (data: rawptr, pointer: ^Wl_Pointer, time, axis: u32),
	axis_discrete:           proc "c" (data: rawptr, pointer: ^Wl_Pointer, axis: u32, discrete: i32),
	axis_value120:           proc "c" (data: rawptr, pointer: ^Wl_Pointer, axis: u32, value120: i32), // since 8
	axis_relative_direction: proc "c" (data: rawptr, pointer: ^Wl_Pointer, axis, direction: u32), // since 9
}

Keyboard_Listener :: struct {
	keymap:      proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, format: u32, fd: i32, size: u32),
	enter:       proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, serial: u32, surface: ^Wl_Surface, keys: ^Wl_Array),
	leave:       proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, serial: u32, surface: ^Wl_Surface),
	key:         proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, serial, time, key, state: u32),
	modifiers:   proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, serial, depressed, latched, locked, group: u32),
	repeat_info: proc "c" (data: rawptr, keyboard: ^Wl_Keyboard, rate, delay: i32), // since 4
}

Wm_Base_Listener :: struct {
	ping: proc "c" (data: rawptr, wm_base: ^Xdg_Wm_Base, serial: u32),
}

Xdg_Surface_Listener :: struct {
	configure: proc "c" (data: rawptr, surface: ^Xdg_Surface, serial: u32),
}

Toplevel_Listener :: struct {
	configure:        proc "c" (data: rawptr, toplevel: ^Xdg_Toplevel, width, height: i32, states: ^Wl_Array),
	close:            proc "c" (data: rawptr, toplevel: ^Xdg_Toplevel),
	configure_bounds: proc "c" (data: rawptr, toplevel: ^Xdg_Toplevel, width, height: i32), // since 4
	wm_capabilities:  proc "c" (data: rawptr, toplevel: ^Xdg_Toplevel, capabilities: ^Wl_Array), // since 5
}

Decoration_Listener :: struct {
	configure: proc "c" (data: rawptr, decoration: ^Zxdg_Toplevel_Decoration, mode: u32), // 1 client side, 2 server side
}

// xdg_toplevel's states (the `states` array of configure holds u32s of these)
Toplevel_State :: enum u32 {
	Maximized    = 1,
	Fullscreen   = 2,
	Resizing     = 3,
	Activated    = 4,
	Tiled_Left   = 5,
	Tiled_Right  = 6,
	Tiled_Top    = 7,
	Tiled_Bottom = 8,
	Suspended    = 9,
}

DECORATION_MODE_CLIENT_SIDE :: 1
DECORATION_MODE_SERVER_SIDE :: 2

// what the compositor's wl_array of u32 holds
array_u32s :: proc "contextless" (a: ^Wl_Array) -> []u32 {
	if a == nil || a.data == nil || a.size == 0 {
		return nil
	}
	return ([^]u32)(a.data)[:a.size / size_of(u32)]
}
