package iv_input

import "core:testing"
import ui "../iv_ui"

NAV_DT :: f32(1.0 / 60)
NAV_WINDOW :: [2]f32{800, 600}

// What a frame submits (nil: nothing, not even `nav_begin`).
Nav_Fill :: proc(ctx: ^Context(Test_Signal))

nav_empty :: proc(ctx: ^Context(Test_Signal)) {
	nav_begin(ctx, NAV_WINDOW) // (a screen with nothing on it)
}

// Two buttons, one under the other.
nav_two :: proc(ctx: ^Context(Test_Signal)) {
	nav_begin(ctx, NAV_WINDOW)
	nav_rect(ctx, ui.Rect{10, 10, 40, 20})
	nav_rect(ctx, ui.Rect{10, 50, 40, 20})
}

// ... the second of them is the one the cursor starts on.
nav_two_default_second :: proc(ctx: ^Context(Test_Signal)) {
	nav_begin(ctx, NAV_WINDOW)
	nav_rect(ctx, ui.Rect{10, 10, 40, 20})
	nav_rect(ctx, ui.Rect{10, 50, 40, 20}, default = true)
}

// ... and the same on another screen (a dialog opened over it, say).
nav_two_other_screen :: proc(ctx: ^Context(Test_Signal)) {
	nav_begin(ctx, NAV_WINDOW)
	nav_screen(ctx, 2)
	nav_rect(ctx, ui.Rect{10, 10, 40, 20})
	nav_rect(ctx, ui.Rect{10, 50, 40, 20}, default = true)
}

// Three buttons in a row.
nav_row :: proc(ctx: ^Context(Test_Signal)) {
	nav_begin(ctx, NAV_WINDOW)
	nav_rect(ctx, ui.Rect{0, 0, 20, 10})
	nav_rect(ctx, ui.Rect{40, 0, 20, 10})
	nav_rect(ctx, ui.Rect{80, 0, 20, 10})
}

// One button and a list that scrolls.
nav_one_scrolling :: proc(ctx: ^Context(Test_Signal)) {
	nav_begin(ctx, NAV_WINDOW)
	nav_scrolls(ctx)
	nav_rect(ctx, ui.Rect{0, 0, 20, 10})
}

nav_one :: proc(ctx: ^Context(Test_Signal)) {
	nav_begin(ctx, NAV_WINDOW)
	nav_rect(ctx, ui.Rect{0, 0, 20, 10})
}

// A slider (number 7, its knob at x = 30) and a button under it.
nav_with_slider :: proc(ctx: ^Context(Test_Signal)) {
	nav_begin(ctx, NAV_WINDOW)
	nav_slider(ctx, ui.Rect{0, 0, 100, 10}, 7, 30)
	nav_rect(ctx, ui.Rect{0, 20, 100, 10})
}

// One frame: the devices as they are set (the `.Pressed` of a button the test just set is cleared by `begin_frame`, the `.Down` is not), and
// what `fill` submits.
nav_frame :: proc(ctx: ^Context(Test_Signal), fill: Nav_Fill) -> Nav_Change {
	begin_frame(ctx)
	if fill != nil {
		fill(ctx)
	}
	return update_nav(ctx, NAV_DT)
}

// Plugs a gamepad in, leaves it be for the frames in which it is let settle (and its resting axes are read), then presses a button: the
// gamepad becomes the main input (what that frame says).
nav_wake :: proc(ctx: ^Context(Test_Signal), fill: Nav_Fill) -> Nav_Change {
	set_pad_connected(ctx, 0, true)
	for _ in 0 ..< 8 {
		nav_frame(ctx, fill)
	}
	set_pad_button_state(ctx, 0, .Face_Down, {.Down, .Pressed})
	change := nav_frame(ctx, fill)
	set_pad_button_state(ctx, 0, .Face_Down, {})
	return change
}

@(test)
test_nav_pick_goes_to_the_nearest_rectangle_that_way :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_row(&ctx)
	nav_rect(&ctx, ui.Rect{0, 30, 20, 10}) // (under the first)
	n := &ctx.nav
	from := [2]f32{10, 5} // on the first button
	testing.expect_value(t, nav_pick(n, from, 0, {1, 0}), 1)
	testing.expect_value(t, nav_pick(n, from, 0, {0, 1}), 3)
	testing.expect_value(t, nav_pick(n, from, 0, {-1, 0}), -1) // nothing to the left
	testing.expect_value(t, nav_pick(n, from, 0, {0, -1}), -1) // nor above
	// From the third: left is the second (the fourth is off to the side and far).
	testing.expect_value(t, nav_pick(n, {90, 5}, 2, {-1, 0}), 1)
	// The stronger axis counts.
	testing.expect_value(t, nav_pick(n, from, 0, {1, 0.3}), 1)
}

@(test)
test_nav_rectangles_with_no_size_are_not_added_and_the_buffer_is_bounded :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_begin(&ctx, NAV_WINDOW)
	nav_rect(&ctx, ui.Rect{0, 0, 0, 10})
	nav_rect(&ctx, ui.Rect{0, 0, 10, 0})
	testing.expect_value(t, ctx.nav.count, 0)
	for _ in 0 ..< NAV_RECT_MAX + 10 {
		nav_rect(&ctx, ui.Rect{0, 0, 4, 4})
	}
	testing.expect_value(t, ctx.nav.count, NAV_RECT_MAX)
}

@(test)
test_nav_a_gamepad_that_is_only_found_is_not_the_main_input_until_it_is_used :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	testing.expect_value(t, nav_frame(&ctx, nav_empty), Nav_Change.None) // none plugged in
	testing.expect(t, !nav_active(&ctx))
	testing.expect_value(t, nav_pad(&ctx), -1)

	set_pad_connected(&ctx, 0, true)
	for _ in 0 ..< 8 { // (the frames in which it is let settle, and the one that reads where its axes rest)
		testing.expect_value(t, nav_frame(&ctx, nav_empty), Nav_Change.None)
	}
	testing.expect_value(t, nav_pad(&ctx), 0) // found, not used
	testing.expect(t, !nav_active(&ctx))

	set_mouse_position(&ctx, 123, 45)
	set_pad_button_state(&ctx, 0, .Face_Down, {.Down, .Pressed})
	testing.expect_value(t, nav_frame(&ctx, nav_empty), Nav_Change.Entered)
	testing.expect(t, nav_active(&ctx))
	testing.expect_value(t, nav_position(&ctx), [2]f32{123, 45}) // it starts where the mouse is
	testing.expect_value(t, nav_pointer(&ctx), [2]f32{123, 45})

	set_pad_connected(&ctx, 0, false)
	set_mouse_position(&ctx, 1, 1)
	testing.expect_value(t, nav_frame(&ctx, nav_empty), Nav_Change.Left)
	testing.expect(t, !nav_active(&ctx))
	testing.expect_value(t, nav_pad(&ctx), -1)
	testing.expect_value(t, nav_pointer(&ctx), [2]f32{1, 1}) // the mouse again
}

@(test)
test_nav_a_moved_stick_wakes_a_gamepad_too :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	set_pad_connected(&ctx, 0, true)
	set_pad_axis(&ctx, 0, .Left_Trigger, -1) // (a trigger that rests at -1: that is not use)
	for _ in 0 ..< 8 {
		testing.expect_value(t, nav_frame(&ctx, nav_empty), Nav_Change.None)
	}
	testing.expect(t, !nav_active(&ctx))
	set_pad_axis(&ctx, 0, .Left_X, 1)
	testing.expect_value(t, nav_frame(&ctx, nav_empty), Nav_Change.Entered)
}

@(test)
test_nav_the_cursor_comes_up_on_the_first_rectangle_and_the_dpad_moves_it :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	testing.expect_value(t, nav_wake(&ctx, nav_two), Nav_Change.Entered)
	testing.expect(t, nav_cursor(&ctx).visible)
	testing.expect_value(t, nav_focus(&ctx), 0)
	testing.expect_value(t, nav_position(&ctx), [2]f32{30, 20}) // the middle of the first

	set_pad_button_state(&ctx, 0, .Dpad_Down, {.Down, .Pressed})
	nav_frame(&ctx, nav_two)
	testing.expect_value(t, nav_focus(&ctx), 1)
	testing.expect_value(t, nav_position(&ctx), [2]f32{30, 60})
}

@(test)
test_nav_no_rectangles_no_cursor_and_the_default_one_when_they_come_back :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_two)
	testing.expect(t, nav_cursor(&ctx).visible)

	nav_frame(&ctx, nav_empty) // (a screen is on its way out)
	testing.expect(t, !nav_cursor(&ctx).visible)
	testing.expect_value(t, nav_focus(&ctx), -1)

	nav_frame(&ctx, nav_two_default_second) // (and the next one is there)
	testing.expect(t, nav_cursor(&ctx).visible)
	testing.expect_value(t, nav_focus(&ctx), 1)
	testing.expect_value(t, nav_position(&ctx), [2]f32{30, 60})
}

@(test)
test_nav_a_frame_with_no_submission_has_no_rectangles :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_two)
	nav_frame(&ctx, nil)
	testing.expect(t, !nav_cursor(&ctx).visible)
	testing.expect_value(t, nav_focus(&ctx), -1)
}

@(test)
test_nav_another_screen_puts_the_cursor_on_its_default_rectangle :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_two)
	testing.expect_value(t, nav_focus(&ctx), 0)
	nav_frame(&ctx, nav_two) // (the same screen again: the cursor stays)
	testing.expect_value(t, nav_focus(&ctx), 0)
	nav_frame(&ctx, nav_two_other_screen)
	testing.expect_value(t, nav_focus(&ctx), 1)
}

@(test)
test_nav_a_held_direction_steps_at_once_then_repeats :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_row)
	set_pad_button_state(&ctx, 0, .Dpad_Right, {.Down, .Pressed})
	nav_frame(&ctx, nav_row) // pushed: a step now
	testing.expect_value(t, nav_focus(&ctx), 1)
	for _ in 0 ..< 10 { // 10 frames is 0.17 s: before the first repeat (0.32 s)
		nav_frame(&ctx, nav_row)
	}
	testing.expect_value(t, nav_focus(&ctx), 1)
	for _ in 0 ..< 12 { // ... and now past it
		nav_frame(&ctx, nav_row)
	}
	testing.expect_value(t, nav_focus(&ctx), 2)
	set_pad_button_state(&ctx, 0, .Dpad_Right, {}) // let go
	nav_frame(&ctx, nav_row)
	set_pad_button_state(&ctx, 0, .Dpad_Left, {.Down, .Pressed}) // a new push steps at once
	nav_frame(&ctx, nav_row)
	testing.expect_value(t, nav_focus(&ctx), 1)
}

@(test)
test_nav_a_list_that_scrolls_turns_the_wheel_when_there_is_no_more_that_way :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_one_scrolling)
	set_pad_button_state(&ctx, 0, .Dpad_Down, {.Down, .Pressed})
	nav_frame(&ctx, nav_one_scrolling)
	testing.expect_value(t, nav_wheel(&ctx), f32(-1)) // down
	set_pad_button_state(&ctx, 0, .Dpad_Down, {})
	nav_frame(&ctx, nav_one_scrolling)
	set_pad_button_state(&ctx, 0, .Dpad_Up, {.Down, .Pressed})
	nav_frame(&ctx, nav_one_scrolling)
	testing.expect_value(t, nav_wheel(&ctx), f32(1)) // up
	set_pad_button_state(&ctx, 0, .Dpad_Up, {})
	nav_frame(&ctx, nav_one_scrolling)
	set_pad_button_state(&ctx, 0, .Dpad_Down, {.Down, .Pressed})
	nav_frame(&ctx, nav_one) // (a screen that does not scroll)
	testing.expect_value(t, nav_wheel(&ctx), f32(0))
}

@(test)
test_nav_left_and_right_turn_a_slider_and_up_and_down_leave_it :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_with_slider)
	testing.expect_value(t, nav_focus(&ctx), 0)
	testing.expect_value(t, nav_position(&ctx), [2]f32{30, 5}) // on the knob, not in the middle

	set_pad_button_state(&ctx, 0, .Dpad_Right, {.Down, .Pressed})
	nav_frame(&ctx, nav_with_slider)
	slider, dir, ok := nav_slider_step(&ctx)
	testing.expect(t, ok)
	testing.expect_value(t, slider, 7)
	testing.expect_value(t, dir, 1)
	testing.expect_value(t, nav_focus(&ctx), 0) // still on the slider
	set_pad_button_state(&ctx, 0, .Dpad_Right, {})
	nav_frame(&ctx, nav_with_slider)
	_, _, ok = nav_slider_step(&ctx)
	testing.expect(t, !ok) // (only the frame of the turn has it)

	set_pad_button_state(&ctx, 0, .Dpad_Left, {.Down, .Pressed})
	nav_frame(&ctx, nav_with_slider)
	_, dir, _ = nav_slider_step(&ctx)
	testing.expect_value(t, dir, -1)
	set_pad_button_state(&ctx, 0, .Dpad_Left, {})
	nav_frame(&ctx, nav_with_slider)

	set_pad_button_state(&ctx, 0, .Dpad_Down, {.Down, .Pressed}) // down goes on to the next one
	nav_frame(&ctx, nav_with_slider)
	testing.expect_value(t, nav_focus(&ctx), 1)
	_, _, ok = nav_slider_step(&ctx)
	testing.expect(t, !ok)
}

@(test)
test_nav_the_real_mouse_takes_the_cursor_where_it_is :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_two)
	set_mouse_position(&ctx, 35, 62)
	nav_frame(&ctx, nav_two)
	testing.expect_value(t, nav_position(&ctx), [2]f32{35, 62})
	testing.expect_value(t, nav_cursor(&ctx).at, [2]f32{35, 62})
	testing.expect_value(t, nav_focus(&ctx), 1) // the second button is under it

	// Over nothing: no rectangle, and the D-pad goes on from where the mouse is.
	set_mouse_position(&ctx, 300, 300)
	nav_frame(&ctx, nav_two)
	testing.expect_value(t, nav_focus(&ctx), -1)
	set_pad_button_state(&ctx, 0, .Dpad_Up, {.Down, .Pressed})
	nav_frame(&ctx, nav_two)
	testing.expect_value(t, nav_focus(&ctx), 1)
	testing.expect_value(t, nav_position(&ctx), [2]f32{30, 60})
}

@(test)
test_nav_with_no_rectangles_the_cursor_is_free_only_where_the_program_says_so :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_empty)
	testing.expect_value(t, nav_position(&ctx), [2]f32{400, 300}) // (the middle of the window: no mouse was heard from)
	testing.expect(t, !nav_cursor(&ctx).visible)
	set_pad_button_state(&ctx, 0, .Dpad_Right, {.Down, .Pressed})
	for _ in 0 ..< 30 {
		nav_frame(&ctx, nav_empty)
	}
	testing.expect_value(t, nav_position(&ctx), [2]f32{400, 300}) // it does not move

	nav_free_cursor(&ctx, true)
	for _ in 0 ..< 30 {
		nav_frame(&ctx, nav_empty)
	}
	testing.expect(t, nav_cursor(&ctx).visible)
	pos := nav_position(&ctx)
	testing.expect(t, pos.x > 400 && pos.y == 300)
	ctx.nav.pos = {10000, 10000}
	nav_frame(&ctx, nav_empty)
	testing.expect_value(t, nav_position(&ctx), [2]f32{799, 599}) // kept in the window
}

@(test)
test_nav_with_no_rectangles_the_cursor_rests_where_the_program_says :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_empty)
	nav_rest_at(&ctx, [2]f32{111, 222})
	nav_frame(&ctx, nav_empty)
	testing.expect_value(t, nav_position(&ctx), [2]f32{111, 222})
	nav_rest_at(&ctx, nil)
	ctx.nav.pos = {5, 5}
	nav_frame(&ctx, nav_empty)
	testing.expect_value(t, nav_position(&ctx), [2]f32{5, 5}) // (stays where it was)
}

@(test)
test_nav_the_cursor_can_be_switched_off_and_the_rest_keeps_working :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_two)
	testing.expect(t, nav_cursor(&ctx).visible)
	nav_show_cursor(&ctx, false)
	testing.expect(t, !nav_cursor(&ctx).visible)
	set_pad_button_state(&ctx, 0, .Dpad_Down, {.Down, .Pressed})
	nav_frame(&ctx, nav_two)
	testing.expect_value(t, nav_focus(&ctx), 1) // (it still moves)
	nav_show_cursor(&ctx, true)
	testing.expect(t, nav_cursor(&ctx).visible)
}

moved_rect: [2]int

nav_moved :: proc(ctx: ^Context(Test_Signal)) {
	nav_begin(ctx, NAV_WINDOW)
	nav_rect(ctx, ui.Rect{moved_rect.x, moved_rect.y, 20, 10})
}

@(test)
test_nav_the_cursor_stays_on_a_rectangle_that_moves :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	moved_rect = {10, 10}
	nav_wake(&ctx, nav_moved)
	for _ in 0 ..< 60 { // (the picture of the cursor has glided there)
		nav_frame(&ctx, nav_moved)
	}
	testing.expect_value(t, nav_position(&ctx), [2]f32{20, 15})
	testing.expect_value(t, nav_cursor(&ctx).at, [2]f32{20, 15})

	moved_rect = {30, 14} // the picture was made again, the rectangle is somewhere else now
	nav_moved(&ctx)
	nav_end(&ctx)
	testing.expect_value(t, nav_position(&ctx), [2]f32{40, 19})
	testing.expect_value(t, nav_cursor(&ctx).at, [2]f32{40, 19}) // (the picture went with it)
	testing.expect_value(t, nav_focus(&ctx), 0)
}

@(test)
test_nav_other_rectangles_take_the_cursor_where_it_is :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_two)
	set_pad_button_state(&ctx, 0, .Dpad_Down, {.Down, .Pressed})
	nav_frame(&ctx, nav_two)
	testing.expect_value(t, nav_focus(&ctx), 1)
	set_pad_button_state(&ctx, 0, .Dpad_Down, {})

	// Three rectangles now (a list got another row): the cursor stays at (30, 60), which the last one holds.
	nav_begin(&ctx, NAV_WINDOW)
	nav_rect(&ctx, ui.Rect{10, 10, 40, 20})
	nav_rect(&ctx, ui.Rect{200, 200, 10, 10})
	nav_rect(&ctx, ui.Rect{10, 50, 40, 20})
	nav_end(&ctx)
	testing.expect_value(t, nav_focus(&ctx), 2)
	testing.expect_value(t, nav_position(&ctx), [2]f32{30, 60})

	// And when none holds that point, the nearest one has it.
	nav_begin(&ctx, NAV_WINDOW)
	nav_rect(&ctx, ui.Rect{300, 300, 10, 10})
	nav_rect(&ctx, ui.Rect{30, 100, 10, 10})
	nav_end(&ctx)
	testing.expect_value(t, nav_focus(&ctx), 1)

	// The same number of rectangles again: the cursor stays on its rectangle, wherever it went.
	nav_begin(&ctx, NAV_WINDOW)
	nav_rect(&ctx, ui.Rect{300, 300, 10, 10})
	nav_rect(&ctx, ui.Rect{400, 400, 10, 10})
	nav_end(&ctx)
	testing.expect_value(t, nav_focus(&ctx), 1)
	testing.expect_value(t, nav_position(&ctx), [2]f32{405, 405})
}

@(test)
test_nav_the_right_stick_turns_the_wheel_or_zooms :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_empty)
	set_pad_axis(&ctx, 0, .Right_Y, -1) // up
	nav_frame(&ctx, nav_empty)
	testing.expect_value(t, nav_wheel(&ctx), f32(1))
	nav_frame(&ctx, nav_empty) // held: no step yet
	testing.expect_value(t, nav_wheel(&ctx), f32(0))

	nav_stick_zoom(&ctx, true)
	nav_frame(&ctx, nav_empty)
	testing.expect_value(t, nav_wheel(&ctx), f32(0))
	testing.expect(t, nav_zoom(&ctx) > 0.99) // all the way up
	set_pad_axis(&ctx, 0, .Right_Y, 0.1) // inside the dead zone
	nav_frame(&ctx, nav_empty)
	testing.expect_value(t, nav_zoom(&ctx), f32(0))
}

@(test)
test_nav_the_left_stick_is_a_dpad_only_while_the_dpad_is_not_held :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	set_pad_connected(&ctx, 0, true)
	nav_frame(&ctx, nav_empty) // (found)
	set_pad_axis(&ctx, 0, .Left_X, 0.9)
	set_pad_axis(&ctx, 0, .Left_Y, -0.2) // inside the dead zone of a direction
	testing.expect_value(t, nav_direction(&ctx), [2]f32{1, 0})
	set_pad_button_state(&ctx, 0, .Dpad_Down, {.Down})
	testing.expect_value(t, nav_direction(&ctx), [2]f32{0, 1})
	s := nav_stick(&ctx)
	testing.expect(t, s.x > 0.5 && s.x <= 1)
	set_pad_axis(&ctx, 0, .Left_X, 0.1)
	set_pad_axis(&ctx, 0, .Left_Y, 0.1)
	testing.expect_value(t, nav_stick(&ctx), [2]f32{})
}

@(test)
test_nav_reset_state_keeps_the_gamepad_cursor :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	nav_wake(&ctx, nav_two)
	reset_state(&ctx)
	testing.expect(t, nav_active(&ctx))
	testing.expect_value(t, ctx.nav.count, 2)
}
