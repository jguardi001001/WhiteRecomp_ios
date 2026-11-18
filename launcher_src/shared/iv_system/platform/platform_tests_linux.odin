package platform

import "core:log"
import "core:testing"
import input "../../iv_input"

// ---------------------------------------------------------------------------
// Tests of the Wayland layer.
//  * the key tables and the layout logic need no compositor (only libxkbcommon and its keymap data; skipped without);
//  * the window tests need a Wayland session (WAYLAND_DISPLAY): run them under a compositor, for instance a headless one:
//      weston --backend=headless --socket=wayland-test &  WAYLAND_DISPLAY=wayland-test odin test iv_system/platform
//    They are skipped (and say so) without one;
//  * the input tests call the listeners with the events a compositor would send, so they check the whole path from the
//    protocol's events to an input.Context without a person at the keyboard.
// ---------------------------------------------------------------------------

Test_Signal :: enum {
	Jump,
}

// A keymap for a layout, from xkb's own data (the way a program without a compositor would make one).
make_keymap :: proc(x: ^Xkb, layout: cstring) -> bool {
	if !xkb_load(x) {
		return false
	}
	names := Xkb_Rule_Names {
		layout = layout,
	}
	keymap := x.procs.keymap_new_from_names(x.ctx, &names, 0)
	if keymap == nil {
		return false
	}
	xkb_set_keymap(x, keymap)
	return true
}

@(test)
evdev_codes_are_named :: proc(t: ^testing.T) {
	testing.expect_value(t, evdev_key(1), input.Key.Escape)
	testing.expect_value(t, evdev_key(2), input.Key.Num_1)
	testing.expect_value(t, evdev_key(10), input.Key.Num_9)
	testing.expect_value(t, evdev_key(11), input.Key.Num_0)
	testing.expect_value(t, evdev_key(28), input.Key.Enter)
	testing.expect_value(t, evdev_key(30), input.Key.A)
	testing.expect_value(t, evdev_key(44), input.Key.Z)
	testing.expect_value(t, evdev_key(57), input.Key.Space)
	testing.expect_value(t, evdev_key(59), input.Key.F1)
	testing.expect_value(t, evdev_key(68), input.Key.F10)
	testing.expect_value(t, evdev_key(87), input.Key.F11)
	testing.expect_value(t, evdev_key(183), input.Key.F13)
	testing.expect_value(t, evdev_key(194), input.Key.F24)
	testing.expect_value(t, evdev_key(71), input.Key.Kp_7)
	testing.expect_value(t, evdev_key(82), input.Key.Kp_0)
	testing.expect_value(t, evdev_key(96), input.Key.Kp_Enter)
	testing.expect_value(t, evdev_key(103), input.Key.Up)
	testing.expect_value(t, evdev_key(109), input.Key.Page_Down)
	testing.expect_value(t, evdev_key(125), input.Key.Left_Super)
	testing.expect_value(t, evdev_key(54), input.Key.Right_Shift)
	testing.expect_value(t, evdev_key(0), input.Key.None)
	testing.expect_value(t, evdev_key(500), input.Key.None)
	// every letter key is a letter, each once
	seen: [input.Key]int
	for code in u32(0) ..< 256 {
		seen[evdev_key(code)] += 1
	}
	for k in input.Key.A ..= input.Key.Z {
		testing.expectf(t, seen[k] == 1, "%v is named by %d codes", k, seen[k])
	}
}

@(test)
letters_follow_the_layout :: proc(t: ^testing.T) {
	x: Xkb
	defer xkb_destroy(&x)
	if !make_keymap(&x, "us") {
		log.warn("skipped: libxkbcommon or its keymap data are not there")
		return
	}
	testing.expect_value(t, translate_key(&x, 44), input.Key.Z) // the key where a US keyboard has Z
	testing.expect_value(t, translate_key(&x, 21), input.Key.Y)

	if make_keymap(&x, "de") { // German: Y and Z are swapped
		testing.expect_value(t, translate_key(&x, 44), input.Key.Y)
		testing.expect_value(t, translate_key(&x, 21), input.Key.Z)
	}
	if make_keymap(&x, "fr") { // French: A and Q, Z and W are swapped, M moved
		testing.expect_value(t, translate_key(&x, 16), input.Key.A)
		testing.expect_value(t, translate_key(&x, 30), input.Key.Q)
		testing.expect_value(t, translate_key(&x, 17), input.Key.Z)
	}
	if make_keymap(&x, "ru") { // not Latin: the keys keep their positional names
		testing.expect_value(t, translate_key(&x, 30), input.Key.A)
	}
	testing.expect_value(t, translate_key(&x, 1), input.Key.Escape) // non-letters are by position
	testing.expect_value(t, translate_key(&x, 57), input.Key.Space)
}

@(test)
keys_make_characters :: proc(t: ^testing.T) {
	x: Xkb
	defer xkb_destroy(&x)
	if !make_keymap(&x, "us") {
		log.warn("skipped: libxkbcommon or its keymap data are not there")
		return
	}
	testing.expect_value(t, key_character(&x, 30), 'a')
	testing.expect_value(t, key_character(&x, 2), '1')
	testing.expect_value(t, key_character(&x, 1), rune(0)) // Escape types nothing
	testing.expect_value(t, key_character(&x, 28), rune(0)) // nor does Enter (it is a key, not text)
	testing.expect_value(t, key_character(&x, 14), rune(0)) // nor Backspace
	// with Shift held (the compositor's modifiers event: depressed mask, bit 0)
	x.procs.state_update_mask(x.state, 1, 0, 0, 0, 0, 0)
	testing.expect_value(t, key_character(&x, 30), 'A')
	testing.expect_value(t, key_character(&x, 2), '!')
	x.procs.state_update_mask(x.state, 0, 0, 0, 0, 0, 0)

	if make_keymap(&x, "de") {
		testing.expect_value(t, key_character(&x, 44), 'y')
		testing.expect_value(t, key_character(&x, 26), 'ü')
	}
	testing.expect(t, key_repeats(&x, 30)) // letters repeat
	testing.expect(t, !key_repeats(&x, 42)) // Shift does not
	testing.expect(t, !key_repeats(&x, 58)) // nor Caps Lock
}

@(test)
without_xkb_keys_are_positional_and_silent :: proc(t: ^testing.T) {
	x: Xkb // never loaded
	testing.expect_value(t, translate_key(&x, 44), input.Key.Z)
	testing.expect_value(t, key_character(&x, 30), rune(0))
	testing.expect(t, key_repeats(&x, 30))
	testing.expect(t, !key_repeats(&x, 29)) // Ctrl
	testing.expect(t, !key_repeats(&x, 0))
}

// ---- a window under a compositor ----------------------------------------------------------------------------------

// Opens a window, or says why the test is skipped.
open_window :: proc(t: ^testing.T, desc: Window_Desc) -> ^Window {
	w, ok := create_window(desc)
	if !ok {
		log.warn("skipped: no Wayland session (WAYLAND_DISPLAY) or a compositor without xdg-shell")
		return nil
	}
	return w
}

@(test)
a_window_is_configured_at_creation :: proc(t: ^testing.T) {
	w := open_window(t, {title = "platform test", width = 320, height = 200})
	if w == nil {
		return
	}
	defer destroy_window(w)
	testing.expect(t, w.configured)
	testing.expect(t, w.scale >= 1)
	testing.expect_value(t, w.size, w.logical * w.scale)
	testing.expect(t, w.size.x > 0 && w.size.y > 0)
	testing.expect(t, w.dpi_scale >= 1)
	h := native_handle(w)
	testing.expect(t, h.window != nil && h.display != nil)
	testing.expect_value(t, poll(w), Window_Events{}) // nothing happened since creation
	log.infof("window: %v px (logical %v, scale %d), decorated=%v", w.size, w.logical, w.scale, w.decorated)
}

@(test)
titles_and_sizes_and_recreation :: proc(t: ^testing.T) {
	w := open_window(t, {title = "first", width = 320, height = 200, min_width = 100, min_height = 80, app_id = "iv_system.test"})
	if w == nil {
		return
	}
	defer destroy_window(w)
	set_title(w, "second")
	testing.expect_value(t, w.desc.title, "second")

	set_size(w, 400, 300) // the program's choice: it is the size it will draw at
	testing.expect_value(t, w.size, [2]int{400, 300} / w.scale * w.scale)
	testing.expect(t, .Resized in poll(w))

	old_surface := w.surface
	testing.expect(t, recreate_window(w))
	testing.expect(t, w.surface != nil && w.configured)
	_ = old_surface
	testing.expect_value(t, w.size, [2]int{400, 300} / w.scale * w.scale)
	testing.expect_value(t, w.desc.title, "second")
}

@(test)
several_windows_share_the_connection :: proc(t: ^testing.T) {
	a := open_window(t, {title = "a", width = 200, height = 100})
	if a == nil {
		return
	}
	defer destroy_window(a)
	b := open_window(t, {title = "b", width = 300, height = 150})
	if b == nil {
		return
	}
	testing.expect(t, a.surface != b.surface)
	testing.expect_value(t, native_handle(a).display, native_handle(b).display)
	testing.expect_value(t, len(wl.windows), 2)
	destroy_window(b)
	testing.expect_value(t, len(wl.windows), 1)
	poll(a)
}

@(test)
fullscreen_is_asked_for_and_reported :: proc(t: ^testing.T) {
	w := open_window(t, {title = "fullscreen", width = 320, height = 200})
	if w == nil {
		return
	}
	defer destroy_window(w)
	set_fullscreen(w, true)
	for _ in 0 ..< 4 { // the compositor answers with a configure
		wl_display_roundtrip(wl.display)
		poll(w)
	}
	if !w.fullscreen {
		log.warn("this compositor did not enter fullscreen (a headless one may not)")
		return
	}
	testing.expect(t, !w.decorated)
	set_fullscreen(w, false)
	for _ in 0 ..< 4 {
		wl_display_roundtrip(wl.display)
		poll(w)
	}
	// A compositor answers a state change of a window that has never shown a buffer only when it is first shown (weston
	// does not configure an unmapped window again), so "still fullscreen" is not a failure of this layer: the full round trip
	// is checked with a graphics backend in ren_vulkan's tests, where the window is drawn into.
	if w.fullscreen {
		log.warn("fullscreen was not left: this compositor waits for the window to be shown first")
	}
}

// ---- the compositor's events, fed to the listeners ---------------------------------------------------------------------

fixed :: proc(v: f32) -> Wl_Fixed {
	return Wl_Fixed(v * 256)
}

// Gives a window the pointer and keyboard focus, and a keymap, the way a compositor's enter events would.
focus :: proc(w: ^Window) {
	pointer_listener.enter(nil, nil, 7, w.surface, fixed(0), fixed(0))
	keyboard_listener.enter(nil, nil, 7, w.surface, nil)
	if !xkb_ready(&wl.xkb) {
		make_keymap(&wl.xkb, "us")
	}
	wl.repeat_rate, wl.repeat_delay = 25, 400
	_ = poll(w)
	clear(&w.input)
}

@(test)
pointer_events_reach_the_input_context :: proc(t: ^testing.T) {
	w := open_window(t, {title = "pointer", width = 320, height = 200})
	if w == nil {
		return
	}
	defer destroy_window(w)
	focus(w)
	ctx: input.Context(Test_Signal)

	pointer_listener.motion(nil, nil, 0, fixed(40.5), fixed(25))
	pointer_listener.button(nil, nil, 8, 0, 0x110, 1) // BTN_LEFT, pressed
	feed_input(w, &ctx)
	x, y := input.mouse_position(&ctx)
	testing.expect_value(t, x, 40.5 * f32(w.scale)) // in buffer pixels
	testing.expect_value(t, y, 25 * f32(w.scale))
	testing.expect(t, input.mouse_pressed(&ctx, .Left))
	testing.expect_value(t, wl.button_serial, u32(8)) // what begin_move needs

	pointer_listener.button(nil, nil, 9, 0, 0x110, 0)
	pointer_listener.button(nil, nil, 10, 0, 0x113, 1) // BTN_SIDE: the back button
	pointer_listener.button(nil, nil, 11, 0, 0x115, 1) // BTN_FORWARD
	feed_input(w, &ctx)
	testing.expect(t, input.mouse_released(&ctx, .Left))
	testing.expect(t, input.mouse_pressed(&ctx, .Back))
	testing.expect(t, input.mouse_pressed(&ctx, .Forward))

	// leaving: events of a pointer that is elsewhere are not this window's
	pointer_listener.leave(nil, nil, 12, w.surface)
	pointer_listener.motion(nil, nil, 0, fixed(1), fixed(1))
	feed_input(w, &ctx)
	x, _ = input.mouse_position(&ctx)
	testing.expect_value(t, x, 40.5 * f32(w.scale)) // unchanged
}

@(test)
scrolling_is_in_notches :: proc(t: ^testing.T) {
	w := open_window(t, {title = "scroll", width = 320, height = 200})
	if w == nil {
		return
	}
	defer destroy_window(w)
	focus(w)
	ctx: input.Context(Test_Signal)

	// a wheel: both a continuous value (10 per notch here) and the notch; the notch counts, once
	pointer_listener.axis(nil, nil, 0, 0, fixed(-10)) // vertical, scrolled up one notch
	pointer_listener.axis_discrete(nil, nil, 0, -1)
	pointer_listener.frame(nil, nil)
	feed_input(w, &ctx)
	_, wy := input.wheel(&ctx)
	testing.expect_value(t, wy, 1) // up is positive for the input package

	// a touchpad: only continuous values, 10 units to the notch
	pointer_listener.axis(nil, nil, 0, 0, fixed(25))
	pointer_listener.axis(nil, nil, 0, 1, fixed(-5)) // horizontal
	pointer_listener.frame(nil, nil)
	feed_input(w, &ctx)
	wx: f32
	wx, wy = input.wheel(&ctx)
	testing.expect_value(t, wy, -2.5)
	testing.expect_value(t, wx, -0.5)
}

@(test)
keyboard_events_reach_the_input_context :: proc(t: ^testing.T) {
	w := open_window(t, {title = "keys", width = 320, height = 200})
	if w == nil {
		return
	}
	defer destroy_window(w)
	focus(w)
	if !xkb_ready(&wl.xkb) {
		log.warn("skipped: no xkb")
		return
	}
	ctx: input.Context(Test_Signal)

	keyboard_listener.key(nil, nil, 1, 0, 30, 1) // the A key goes down
	keyboard_listener.key(nil, nil, 2, 0, 105, 1) // Left
	feed_input(w, &ctx)
	testing.expect(t, input.key_pressed(&ctx, .A))
	testing.expect(t, input.key_down(&ctx, .Left))
	typed := input.typed(&ctx)
	testing.expect_value(t, len(typed), 1)
	if len(typed) == 1 {
		testing.expect_value(t, typed[0], 'a')
	}

	// Shift: the modifiers event, then the same key types a capital
	keyboard_listener.modifiers(nil, nil, 3, 1, 0, 0, 0)
	keyboard_listener.key(nil, nil, 4, 0, 42, 1) // Left Shift
	keyboard_listener.key(nil, nil, 5, 0, 31, 1) // S
	feed_input(w, &ctx)
	testing.expect(t, input.key_down(&ctx, .Left_Shift) && .Shift in input.modifiers(&ctx))
	typed = input.typed(&ctx)
	if testing.expect_value(t, len(typed), 1) {
		testing.expect_value(t, typed[0], 'S')
	}

	keyboard_listener.key(nil, nil, 6, 0, 30, 0)
	feed_input(w, &ctx)
	testing.expect(t, input.key_released(&ctx, .A))

	// losing the keyboard releases everything
	keyboard_listener.leave(nil, nil, 7, w.surface)
	feed_input(w, &ctx)
	testing.expect(t, !input.key_down(&ctx, .Left) && !input.key_down(&ctx, .Left_Shift))
}

@(test)
held_keys_repeat_after_the_delay :: proc(t: ^testing.T) {
	w := open_window(t, {title = "repeat", width = 320, height = 200})
	if w == nil {
		return
	}
	defer destroy_window(w)
	focus(w)
	ctx: input.Context(Test_Signal)

	keyboard_listener.repeat_info(nil, nil, 10, 300) // 10 a second after 300 ms
	keyboard_listener.key(nil, nil, 1, 0, 30, 1)
	press_time := wl.repeat_next - 0.3 // the key went down at "now"
	feed_input(w, &ctx)
	testing.expect(t, !input.key_repeated(&ctx, .A) || input.key_pressed(&ctx, .A))

	make_key_repeats(press_time + 0.2) // inside the delay: nothing
	feed_input(w, &ctx)
	testing.expect(t, !input.key_repeated(&ctx, .A))

	make_key_repeats(press_time + 0.31) // the first repeat
	feed_input(w, &ctx)
	testing.expect(t, input.key_repeated(&ctx, .A))
	typed := input.typed(&ctx)
	testing.expect_value(t, len(typed), 1) // a repeat types the character again

	make_key_repeats(press_time + 0.65) // three more are due: they all arrive
	feed_input(w, &ctx)
	testing.expect_value(t, len(input.typed(&ctx)), 3)

	keyboard_listener.key(nil, nil, 2, 0, 30, 0) // released: no more
	make_key_repeats(press_time + 5)
	feed_input(w, &ctx)
	testing.expect(t, !input.key_repeated(&ctx, .A))

	// Shift does not repeat
	keyboard_listener.key(nil, nil, 3, 0, 42, 1)
	testing.expect_value(t, wl.repeat_code, u32(0))
}

@(test)
close_request_reaches_the_window :: proc(t: ^testing.T) {
	w := open_window(t, {title = "close", width = 320, height = 200})
	if w == nil {
		return
	}
	defer destroy_window(w)
	toplevel_listener.close(w, nil)
	events := poll(w)
	testing.expect(t, .Close_Requested in events)
	testing.expect(t, w.close_requested)
}

@(test)
configure_resizes_and_focuses :: proc(t: ^testing.T) {
	w := open_window(t, {title = "configure", width = 320, height = 200})
	if w == nil {
		return
	}
	defer destroy_window(w)
	poll(w)

	// the compositor's batch: toplevel.configure (size, states [activated]) then xdg_surface.configure
	states := [1]u32{u32(Toplevel_State.Activated)}
	array := Wl_Array{size = size_of(states), alloc = size_of(states), data = &states}
	toplevel_listener.configure(w, nil, i32(500), i32(300), &array)
	apply_configure(w) // (what xdg_surface.configure does after acknowledging: the test must not acknowledge a serial the compositor never sent)
	events := poll(w)
	testing.expect(t, .Resized in events)
	testing.expect(t, .Focus_Gained in events)
	testing.expect_value(t, w.logical, [2]int{500, 300})
	testing.expect_value(t, w.size, [2]int{500, 300} * w.scale)
	testing.expect(t, w.focused)

	// 0 x 0 means "your choice": the size stays; losing the activated state is losing focus
	array.size = 0
	toplevel_listener.configure(w, nil, 0, 0, &array)
	apply_configure(w)
	events = poll(w)
	testing.expect(t, .Focus_Lost in events)
	testing.expect(t, .Resized not_in events)
	testing.expect_value(t, w.logical, [2]int{500, 300})
}

@(test)
the_scale_follows_the_compositor :: proc(t: ^testing.T) {
	w := open_window(t, {title = "scale", width = 320, height = 200})
	if w == nil {
		return
	}
	defer destroy_window(w)
	poll(w)
	logical := w.logical

	surface_listener.preferred_buffer_scale(w, nil, 2) // the compositor says: scale 2
	events := poll(w)
	testing.expect(t, .Dpi_Changed in events && .Resized in events)
	testing.expect_value(t, w.scale, 2)
	testing.expect_value(t, w.dpi_scale, f32(2))
	testing.expect_value(t, w.size, logical * 2)
	testing.expect(t, w.has_preferred_scale)

	surface_listener.preferred_buffer_scale(w, nil, 2) // the same again: no news
	testing.expect_value(t, poll(w), Window_Events{})
}
