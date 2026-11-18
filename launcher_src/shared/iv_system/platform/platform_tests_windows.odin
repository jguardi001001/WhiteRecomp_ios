package platform

import "core:log"
import win32 "core:sys/windows"
import "core:testing"
import input "../../iv_input"

// These make a real (hidden) window and post it the messages the operating system would send, so the whole path
// message -> queue -> input.Context is checked without a person at the keyboard.

Test_Signal :: enum {
	Jump,
}

@(private = "file")
open_hidden :: proc(t: ^testing.T) -> ^Window {
	w, ok := create_window({title = "platform test", width = 320, height = 200, flags = {.Hidden}})
	testing.expect(t, ok)
	return w
}

@(private = "file")
post :: proc(w: ^Window, msg: u32, wparam: uintptr, lparam: int = 0) {
	win32.PostMessageW(w.hwnd, msg, win32.WPARAM(wparam), win32.LPARAM(lparam))
}

@(test)
window_has_a_client_size :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	testing.expect_value(t, w.size, [2]int{320, 200}) // the client area, not the outer frame
	testing.expect(t, w.dpi_scale >= 1)
	h := native_handle(w)
	testing.expect(t, h.window != nil && h.display != nil)
	testing.expect_value(t, poll(w), Window_Events{}) // nothing happened since creation
}

@(test)
keys_reach_the_input_context :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	ctx: input.Context(Test_Signal)

	post(w, win32.WM_KEYDOWN, win32.VK_F5)
	post(w, win32.WM_KEYDOWN, win32.VK_LEFT)
	poll(w)
	feed_input(w, &ctx)
	testing.expect(t, input.key_pressed(&ctx, .F5))
	testing.expect(t, input.key_down(&ctx, .Left))

	// next frame: held, not pressed again
	poll(w)
	feed_input(w, &ctx)
	testing.expect(t, input.key_down(&ctx, .F5) && !input.key_pressed(&ctx, .F5))

	// the operating system repeats a held key (bit 30 of lParam says "was down")
	post(w, win32.WM_KEYDOWN, win32.VK_LEFT, 1 << 30)
	poll(w)
	feed_input(w, &ctx)
	testing.expect(t, input.key_repeated(&ctx, .Left))

	post(w, win32.WM_KEYUP, win32.VK_F5)
	poll(w)
	feed_input(w, &ctx)
	testing.expect(t, input.key_released(&ctx, .F5) && !input.key_down(&ctx, .F5))
}

@(test)
left_and_right_modifiers_differ :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	ctx: input.Context(Test_Signal)

	post(w, win32.WM_KEYDOWN, win32.VK_CONTROL, 1 << 24) // the extended bit: the right Ctrl
	post(w, win32.WM_KEYDOWN, win32.VK_LCONTROL)
	post(w, win32.WM_KEYDOWN, win32.VK_RETURN, 1 << 24) // the number pad's Enter
	poll(w)
	feed_input(w, &ctx)
	testing.expect(t, input.key_down(&ctx, .Right_Ctrl))
	testing.expect(t, input.key_down(&ctx, .Left_Ctrl))
	testing.expect(t, input.key_down(&ctx, .Kp_Enter) && !input.key_down(&ctx, .Enter))
	testing.expect(t, .Ctrl in input.modifiers(&ctx))
}

@(test)
every_letter_and_digit_has_a_key :: proc(t: ^testing.T) {
	for c in 'A' ..= 'Z' {
		testing.expect_value(t, translate_key(win32.WPARAM(c), 0), input.Key(int(input.Key.A) + int(c - 'A')))
	}
	for c in '0' ..= '9' {
		testing.expect_value(t, translate_key(win32.WPARAM(c), 0), input.Key(int(input.Key.Num_0) + int(c - '0')))
	}
	testing.expect_value(t, translate_key(win32.VK_F12, 0), input.Key.F12)
	testing.expect_value(t, translate_key(win32.VK_NUMPAD7, 0), input.Key.Kp_7)
	testing.expect_value(t, translate_key(win32.VK_OEM_3, 0), input.Key.Grave)
	testing.expect_value(t, translate_key(0xFF, 0), input.Key.None) // unknown keys are dropped
}

@(test)
typed_text_and_surrogates :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	ctx: input.Context(Test_Signal)

	post(w, win32.WM_CHAR, 'h')
	post(w, win32.WM_CHAR, 0xE9) // é
	post(w, win32.WM_CHAR, 9) // Tab is a key, not text
	post(w, win32.WM_CHAR, 0xD83D) // 😀 (U+1F600) as a surrogate pair
	post(w, win32.WM_CHAR, 0xDE00)
	poll(w)
	feed_input(w, &ctx)
	typed := input.typed(&ctx)
	testing.expect_value(t, len(typed), 3)
	if len(typed) == 3 {
		testing.expect_value(t, typed[0], 'h')
		testing.expect_value(t, typed[1], 'é')
		testing.expect_value(t, typed[2], rune(0x1F600))
	}
}

@(test)
mouse_position_buttons_and_wheel :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	ctx: input.Context(Test_Signal)

	post(w, win32.WM_MOUSEMOVE, 0, 40 | (25 << 16))
	post(w, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, 40 | (25 << 16))
	post(w, win32.WM_MOUSEWHEEL, uintptr(u32(i32(240)) << 16)) // two notches away from the user
	poll(w)
	feed_input(w, &ctx)
	x, y := input.mouse_position(&ctx)
	testing.expect_value(t, x, 40)
	testing.expect_value(t, y, 25)
	testing.expect(t, input.mouse_pressed(&ctx, .Left))
	_, wheel_y := input.wheel(&ctx)
	testing.expect_value(t, wheel_y, 2)

	post(w, win32.WM_LBUTTONUP, 0, 40 | (25 << 16))
	post(w, win32.WM_XBUTTONDOWN, win32.MK_XBUTTON1 | (uintptr(win32.XBUTTON1) << 16))
	poll(w)
	feed_input(w, &ctx)
	testing.expect(t, input.mouse_released(&ctx, .Left))
	testing.expect(t, input.mouse_pressed(&ctx, .Back))
}

@(test)
losing_focus_releases_everything :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	ctx: input.Context(Test_Signal)

	post(w, win32.WM_KEYDOWN, win32.VK_LEFT)
	poll(w)
	feed_input(w, &ctx)
	testing.expect(t, input.key_down(&ctx, .Left))

	post(w, win32.WM_KILLFOCUS, 0)
	events := poll(w)
	testing.expect(t, .Focus_Lost in events)
	feed_input(w, &ctx)
	testing.expect(t, !input.key_down(&ctx, .Left)) // no key stays stuck
}

@(test)
close_button_asks_instead_of_destroying :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	post(w, win32.WM_CLOSE, 0)
	events := poll(w)
	testing.expect(t, .Close_Requested in events)
	testing.expect(t, w.close_requested)
	testing.expect(t, win32.IsWindow(w.hwnd) == true) // still there: the program decides
}

@(test)
resizing_reports_the_new_client_size :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	poll(w)
	win32.SetWindowPos(w.hwnd, nil, 0, 0, 500, 400, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE)
	events := poll(w)
	testing.expect(t, .Resized in events)
	client: win32.RECT
	win32.GetClientRect(w.hwnd, &client)
	testing.expect_value(t, w.size, [2]int{int(client.right), int(client.bottom)})
	testing.expect(t, w.size.x > 320 && w.size.x <= 500)
}

@(test)
recreate_keeps_the_window_object :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	old := w.hwnd
	testing.expect(t, recreate_window(w))
	testing.expect(t, w.hwnd != nil && w.hwnd != old)
	testing.expect_value(t, w.size, [2]int{320, 200})
	testing.expect_value(t, w.desc.title, "platform test")
	// and it still receives messages
	post(w, win32.WM_CLOSE, 0)
	testing.expect(t, .Close_Requested in poll(w))
}

@(test)
clock_runs_forward :: proc(t: ^testing.T) {
	a := time_seconds()
	b := time_seconds()
	testing.expect(t, b >= a)
}

@(test)
the_mouse_cursor_is_tracked_and_controlled :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	testing.expect(t, !w.mouse_inside)
	// (a posted move cannot be told from a real one, but Windows then finds that the real cursor is not over this hidden
	// window and ends the "inside" at once: so the state is set by hand and only the leaving is posted)
	w.mouse_inside = true
	set_cursor_shape(w, .Hand)
	testing.expect_value(t, w.cursor_shape, Cursor_Shape.Hand)
	set_cursor_visible(w, false)
	testing.expect(t, w.cursor_hidden)
	set_cursor_visible(w, true)
	set_cursor_shape(w, .Default)
	post(w, win32.WM_MOUSELEAVE, 0)
	poll(w)
	testing.expect(t, !w.mouse_inside)
}

@(test)
text_goes_to_the_clipboard_and_back :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	// (the user's own clipboard is put back afterwards)
	before, had := clipboard_text(w, context.temp_allocator)
	defer if had {
		set_clipboard_text(w, before)
	}
	if !set_clipboard_text(w, "plancol: ünï © 日本語 ✓") {
		log.warn("skipped: the clipboard could not be opened (another program holds it)")
		return
	}
	text, ok := clipboard_text(w, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, text, "plancol: ünï © 日本語 ✓")
}

@(test)
gamepads_are_reported_to_the_input_context :: proc(t: ^testing.T) {
	ctx: input.Context(Test_Signal)
	pads: [input.MAX_PADS]Pad_State
	pads[1].connected = true
	pads[1].buttons[.Face_Down] = true
	pads[1].buttons[.Dpad_Left] = true
	pads[1].axes[.Left_X] = 0.5
	pads[1].axes[.Right_Trigger] = 1
	input.begin_frame(&ctx)
	apply_gamepads(&ctx, &pads)
	testing.expect(t, !input.pad_is_connected(&ctx, 0))
	testing.expect(t, input.pad_is_connected(&ctx, 1))
	testing.expect(t, .Pressed in input.pad_state(&ctx, 1, .Face_Down))
	testing.expect(t, .Down in input.pad_state(&ctx, 1, .Dpad_Left))
	testing.expect_value(t, input.pad_axis(&ctx, 1, .Left_X), 0.5)
	testing.expect_value(t, input.pad_axis(&ctx, 1, .Right_Trigger), 1)

	// next frame: held, not pressed again; then released
	input.begin_frame(&ctx)
	apply_gamepads(&ctx, &pads)
	testing.expect(t, input.pad_state(&ctx, 1, .Face_Down) == {.Down})
	pads[1].buttons[.Face_Down] = false
	input.begin_frame(&ctx)
	apply_gamepads(&ctx, &pads)
	testing.expect(t, .Released in input.pad_state(&ctx, 1, .Face_Down))

	// and the real thing at least runs (no pad is needed)
	w := open_hidden(t)
	if w != nil {
		defer destroy_window(w)
		feed_input(w, &ctx)
	}
}

@(test)
window_can_be_hidden_shown_and_maximized :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	set_visible(w, true)
	testing.expect(t, win32.IsWindowVisible(w.hwnd) == true)
	set_visible(w, false)
	testing.expect(t, win32.IsWindowVisible(w.hwnd) == false)
	maximize(w)
	testing.expect(t, win32.IsZoomed(w.hwnd) == true)
	set_size(w, 300, 200) // (a maximized window keeps its state: nothing to assert, it must not fail)
	poll(w)
}

@(private = "file")
test_caption :: proc(w: ^Window, x, y: int, user: rawptr) -> Hit_Region {
	return .Caption if y < 30 else .Client
}

// What Windows is told when it asks WM_NCHITTEST about a point (client pixels) of the window.
@(private = "file")
ask_hit :: proc(win: ^Window, x, y: int) -> win32.LRESULT {
	p := win32.POINT{i32(x), i32(y)}
	win32.ClientToScreen(win.hwnd, &p)
	lparam := win32.LPARAM(int(u16(p.x)) | int(u16(p.y)) << 16)
	return win32.SendMessageW(win.hwnd, win32.WM_NCHITTEST, 0, lparam)
}

@(test)
window_without_decorations_is_all_client_and_answers_hit_tests :: proc(t: ^testing.T) {
	w, ok := create_window({title = "no frame", width = 320, height = 200, flags = {.Hidden, .No_Decorations}})
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer destroy_window(w)
	testing.expect(t, !w.decorated)
	testing.expect_value(t, w.size, [2]int{320, 200})
	r: win32.RECT
	win32.GetWindowRect(w.hwnd, &r)
	testing.expect_value(t, int(r.right - r.left), 320) // no frame around the client area
	testing.expect_value(t, int(r.bottom - r.top), 200)

	set_hit_test(w, test_caption)
	testing.expect_value(t, ask_hit(w, 160, 15), win32.LRESULT(win32.HTCAPTION)) // what the program calls its title bar
	testing.expect_value(t, ask_hit(w, 160, 100), win32.LRESULT(win32.HTCLIENT))
	testing.expect_value(t, ask_hit(w, 2, 100), win32.LRESULT(win32.HTLEFT)) // the edges resize
	testing.expect_value(t, ask_hit(w, 2, 2), win32.LRESULT(win32.HTTOPLEFT))
	testing.expect_value(t, ask_hit(w, 160, 198), win32.LRESULT(win32.HTBOTTOM))

	set_resizable(w, false) // a fixed window has no resize edges, but still a caption
	testing.expect_value(t, ask_hit(w, 2, 100), win32.LRESULT(win32.HTCLIENT))
	testing.expect_value(t, ask_hit(w, 160, 15), win32.LRESULT(win32.HTCAPTION))
}

@(test)
decorations_can_be_removed_and_added_again :: proc(t: ^testing.T) {
	w := open_hidden(t)
	if w == nil {
		return
	}
	defer destroy_window(w)
	testing.expect(t, w.decorated)
	r: win32.RECT
	win32.GetWindowRect(w.hwnd, &r)
	testing.expect(t, int(r.right - r.left) > 320) // a frame around the client area

	set_decorated(w, false)
	testing.expect(t, !w.decorated)
	win32.GetWindowRect(w.hwnd, &r)
	testing.expect_value(t, int(r.right - r.left), 320)
	poll(w)
	testing.expect_value(t, w.size, [2]int{320, 200}) // the client area keeps its size

	set_decorated(w, true)
	testing.expect(t, w.decorated)
	poll(w)
	testing.expect_value(t, w.size, [2]int{320, 200})
}

@(test)
window_can_start_maximized_and_be_restored :: proc(t: ^testing.T) {
	w, ok := create_window({title = "maximized", width = 320, height = 200, flags = {.Hidden, .Maximized}})
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer destroy_window(w)
	set_visible(w, true) // the first showing is the maximized one
	poll(w)
	testing.expect(t, w.maximized)
	testing.expect(t, win32.IsZoomed(w.hwnd) == true)
	restore(w)
	poll(w)
	testing.expect(t, !w.maximized)
	testing.expect(t, win32.IsZoomed(w.hwnd) == false)
	toggle_maximize(w)
	poll(w)
	testing.expect(t, w.maximized)
}
