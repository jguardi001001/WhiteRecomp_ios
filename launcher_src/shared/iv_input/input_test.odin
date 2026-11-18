package iv_input

import "core:testing"

Test_Signal :: enum {
	UI_Confirm,
	UI_Back,
	Move_Left,
	Move_Right,
	Zoom_In,
	Save,
}

@(test)
test_key_signal :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal){make_binding(Test_Signal, .UI_Confirm, on_key(.Enter), on_pad_button(.Face_Down))}
	use_bindings(&ctx, &binds)

	begin_frame(&ctx)
	testing.expect(t, !signal_state(&ctx, .UI_Confirm), "nothing is down at the start")
	set_key_state(&ctx, .Enter, {.Down, .Pressed})
	testing.expect(t, signal_state(&ctx, .UI_Confirm))
	testing.expect(t, signal_pressed(&ctx, .UI_Confirm))
	testing.expect(t, !signal_released(&ctx, .UI_Confirm))

	begin_frame(&ctx) // the key stays down, the edge is over
	testing.expect(t, signal_state(&ctx, .UI_Confirm))
	testing.expect(t, !signal_pressed(&ctx, .UI_Confirm))

	set_key_state(&ctx, .Enter, {.Released})
	testing.expect(t, !signal_state(&ctx, .UI_Confirm))
	testing.expect(t, signal_released(&ctx, .UI_Confirm))

	// the second source of the same binding
	begin_frame(&ctx)
	set_pad_button_down(&ctx, 0, .Face_Down, true)
	testing.expect(t, signal_pressed(&ctx, .UI_Confirm), "a pad button works as well")
	testing.expect(t, !signal_pressed(&ctx, .UI_Back), "another signal does not")
}

@(test)
test_down_edges_are_worked_out :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	begin_frame(&ctx)
	set_key_down(&ctx, .A, true)
	testing.expect(t, key_pressed(&ctx, .A) && key_down(&ctx, .A))
	begin_frame(&ctx)
	set_key_down(&ctx, .A, true)
	testing.expect(t, key_down(&ctx, .A) && !key_pressed(&ctx, .A), "held is not pressed again")
	begin_frame(&ctx)
	set_key_down(&ctx, .A, false)
	testing.expect(t, key_released(&ctx, .A) && !key_down(&ctx, .A))
	begin_frame(&ctx)
	set_key_down(&ctx, .A, false)
	testing.expect(t, key_state(&ctx, .A) == {})
}

@(test)
test_a_tap_inside_one_frame :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal){make_binding(Test_Signal, .Zoom_In, on_key(.Z))}
	use_bindings(&ctx, &binds)
	begin_frame(&ctx)
	set_key_state(&ctx, .Z, {.Pressed, .Released})
	testing.expect(t, signal_pressed(&ctx, .Zoom_In), "a tap that is over in the same frame still counts")
	testing.expect(t, signal_released(&ctx, .Zoom_In))
	testing.expect(t, !signal_state(&ctx, .Zoom_In))
}

@(test)
test_the_table_is_read_live :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal){make_binding(Test_Signal, .Move_Left, on_key(.A)), make_binding(Test_Signal, .Move_Right, on_key(.D))}
	use_bindings(&ctx, &binds)

	begin_frame(&ctx)
	set_key_state(&ctx, .A, {.Down, .Pressed})
	testing.expect(t, signal_state(&ctx, .Move_Left))

	// rebinding while the program runs: the player moved the action to J
	testing.expect(t, rebind(&ctx, .Move_Left, on_key(.J)))
	testing.expect(t, !signal_state(&ctx, .Move_Left), "the old key no longer does it")
	set_key_state(&ctx, .J, {.Down, .Pressed})
	testing.expect(t, signal_state(&ctx, .Move_Left))

	// the program replaces the whole slice
	other := []Binding(Test_Signal){make_binding(Test_Signal, .Move_Left, on_key(.K))}
	binds = other
	testing.expect(t, !signal_state(&ctx, .Move_Left))
	set_key_state(&ctx, .K, {.Down})
	testing.expect(t, signal_state(&ctx, .Move_Left))
	testing.expect(t, !signal_state(&ctx, .Move_Right), "the new table has no binding of it")
}

@(test)
test_dynamic_table :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	table: [dynamic]Binding(Test_Signal)
	defer delete(table)
	use_bindings(&ctx, &table)
	begin_frame(&ctx)
	set_key_state(&ctx, .Space, {.Down, .Pressed})
	testing.expect(t, !signal_state(&ctx, .Zoom_In))
	append(&table, make_binding(Test_Signal, .Zoom_In, on_key(.Space)))
	testing.expect(t, signal_pressed(&ctx, .Zoom_In))
}

@(test)
test_modifiers :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal){make_binding(Test_Signal, .Save, on_key(.S, {.Ctrl}, true)), make_binding(Test_Signal, .Move_Left, on_key(.S))}
	use_bindings(&ctx, &binds)

	begin_frame(&ctx)
	set_key_state(&ctx, .S, {.Down, .Pressed})
	testing.expect(t, !signal_pressed(&ctx, .Save), "S alone is not Ctrl+S")
	testing.expect(t, signal_pressed(&ctx, .Move_Left), "a binding with no modifiers ignores what is held")

	begin_frame(&ctx)
	set_key_state(&ctx, .Left_Ctrl, {.Down, .Pressed})
	set_key_state(&ctx, .S, {.Down, .Pressed})
	testing.expect(t, modifiers(&ctx) == {.Ctrl})
	testing.expect(t, signal_pressed(&ctx, .Save), "Ctrl+S")

	begin_frame(&ctx)
	set_key_state(&ctx, .Left_Shift, {.Down, .Pressed})
	set_key_state(&ctx, .S, {.Down, .Pressed})
	testing.expect(t, !signal_pressed(&ctx, .Save), "Ctrl+Shift+S is not Ctrl+S when the binding is exact")
}

@(test)
test_axis_as_button :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal) {
		make_binding(Test_Signal, .Move_Left, on_pad_axis(.Left_X, .Negative)),
		make_binding(Test_Signal, .Move_Right, on_pad_axis(.Left_X, .Positive)),
		make_binding(Test_Signal, .Zoom_In, on_pad_axis(.Right_Trigger, .Positive, 0.3)),
	}
	use_bindings(&ctx, &binds)

	begin_frame(&ctx)
	set_pad_axis(&ctx, 0, .Left_X, -0.2)
	testing.expect(t, !signal_state(&ctx, .Move_Left), "inside the dead zone")
	begin_frame(&ctx)
	set_pad_axis(&ctx, 0, .Left_X, -0.9)
	testing.expect(t, signal_pressed(&ctx, .Move_Left))
	testing.expect(t, !signal_state(&ctx, .Move_Right))
	v := signal_axis(&ctx, .Move_Left, .Move_Right)
	testing.expect(t, v < -0.85 && v > -0.95, "the value is how far the stick is")
	begin_frame(&ctx)
	set_pad_axis(&ctx, 0, .Left_X, -0.95)
	testing.expect(t, signal_state(&ctx, .Move_Left) && !signal_pressed(&ctx, .Move_Left))
	begin_frame(&ctx)
	set_pad_axis(&ctx, 0, .Left_X, 0)
	testing.expect(t, signal_released(&ctx, .Move_Left) && !signal_state(&ctx, .Move_Left))

	begin_frame(&ctx)
	set_pad_axis(&ctx, 0, .Right_Trigger, 0.4)
	testing.expect(t, signal_pressed(&ctx, .Zoom_In), "a trigger with its own threshold")
}

@(test)
test_pad_selection :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal){make_binding(Test_Signal, .UI_Confirm, on_pad_button(.Face_Down, 2))}
	use_bindings(&ctx, &binds)
	begin_frame(&ctx)
	set_pad_button_down(&ctx, 0, .Face_Down, true)
	testing.expect(t, !signal_state(&ctx, .UI_Confirm), "the first pad is not the second")
	set_pad_button_down(&ctx, 1, .Face_Down, true)
	testing.expect(t, signal_state(&ctx, .UI_Confirm))
	set_pad_connected(&ctx, 1, false)
	testing.expect(t, !signal_state(&ctx, .UI_Confirm), "a pad that went away is let go")
}

@(test)
test_wheel_and_mouse :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal){make_binding(Test_Signal, .Zoom_In, on_wheel(.Vertical, .Positive)), make_binding(Test_Signal, .UI_Confirm, on_mouse(.Left))}
	use_bindings(&ctx, &binds)

	begin_frame(&ctx)
	set_mouse_position(&ctx, 100, 50)
	dx, dy := mouse_delta(&ctx)
	testing.expect(t, dx == 0 && dy == 0, "the first position is not a jump")
	begin_frame(&ctx)
	set_mouse_position(&ctx, 110, 45)
	dx, dy = mouse_delta(&ctx)
	testing.expect(t, dx == 10 && dy == -5)
	add_wheel(&ctx, 0, 2)
	testing.expect(t, signal_pressed(&ctx, .Zoom_In))
	testing.expect(t, signal_value(&ctx, .Zoom_In) == 2)
	begin_frame(&ctx)
	testing.expect(t, !signal_pressed(&ctx, .Zoom_In), "a wheel turn lasts one frame")
	set_mouse_down(&ctx, .Left, true)
	testing.expect(t, signal_pressed(&ctx, .UI_Confirm))
}

@(test)
test_typed_text :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	begin_frame(&ctx)
	push_char(&ctx, '$')
	push_char(&ctx, 'é')
	testing.expect(t, len(typed(&ctx)) == 2 && typed(&ctx)[1] == 'é')
	begin_frame(&ctx)
	testing.expect(t, len(typed(&ctx)) == 0)
	for _ in 0 ..< MAX_TYPED + 5 {
		push_char(&ctx, 'a')
	}
	testing.expect(t, len(typed(&ctx)) == MAX_TYPED, "too much typing in one frame is cut off, not overrun")
}

@(test)
test_repeat :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal){make_binding(Test_Signal, .Move_Right, on_key(.Right))}
	use_bindings(&ctx, &binds)
	begin_frame(&ctx)
	set_key_state(&ctx, .Right, {.Down, .Pressed})
	begin_frame(&ctx)
	testing.expect(t, !signal_repeated(&ctx, .Move_Right))
	set_key_repeat(&ctx, .Right)
	testing.expect(t, signal_repeated(&ctx, .Move_Right) && !signal_pressed(&ctx, .Move_Right))
}

@(test)
test_listen_for_a_new_binding :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	begin_frame(&ctx)
	_, found := listen(&ctx)
	testing.expect(t, !found, "nothing pressed")

	set_key_state(&ctx, .Left_Ctrl, {.Down, .Pressed})
	_, found = listen(&ctx)
	testing.expect(t, !found, "a modifier alone is not offered")
	set_key_state(&ctx, .F5, {.Down, .Pressed})
	src, ok := listen(&ctx)
	testing.expect(t, ok)
	k, is_key := src.(Key_Source)
	testing.expect(t, is_key && k.key == .F5 && k.mods == {}, "a plain key")
	src, ok = listen(&ctx, chord = true)
	k = src.(Key_Source)
	testing.expect(t, ok && k.key == .F5 && k.mods == {.Ctrl}, "with the modifiers that are held")

	begin_frame(&ctx)
	reset_state(&ctx)
	set_mouse_down(&ctx, .Right, true)
	src, ok = listen(&ctx)
	m, is_mouse := src.(Mouse_Source)
	testing.expect(t, ok && is_mouse && m.button == .Right)
}

@(test)
test_conflicts_and_text :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal){make_binding(Test_Signal, .UI_Back, on_key(.Escape)), make_binding(Test_Signal, .Save, on_key(.S, {.Ctrl, .Shift}))}
	use_bindings(&ctx, &binds)
	who, found := find_conflict(&ctx, on_key(.Escape), .Save)
	testing.expect(t, found && who == .UI_Back)
	_, found = find_conflict(&ctx, on_key(.Escape), .UI_Back)
	testing.expect(t, !found, "a signal does not conflict with itself")

	buf: [32]u8
	testing.expect(t, source_text(on_key(.S, {.Ctrl, .Shift}), buf[:]) == "Ctrl+Shift+S")
	testing.expect(t, source_text(on_mouse(.Left), buf[:]) == "Left Mouse")
	testing.expect(t, source_text(on_pad_axis(.Left_X, .Negative), buf[:]) == "Left Stick X-")
	testing.expect(t, source_text(on_wheel(.Vertical, .Positive), buf[:]) == "Wheel Up")
	small: [4]u8
	testing.expect(t, source_text(on_key(.Page_Down), small[:]) == "Page", "text that does not fit is cut off")
}

@(test)
test_reset_keeps_the_table :: proc(t: ^testing.T) {
	ctx: Context(Test_Signal)
	binds := []Binding(Test_Signal){make_binding(Test_Signal, .Save, on_key(.S))}
	use_bindings(&ctx, &binds)
	set_key_state(&ctx, .S, {.Down})
	reset_state(&ctx)
	testing.expect(t, !signal_state(&ctx, .Save))
	set_key_state(&ctx, .S, {.Down})
	testing.expect(t, signal_state(&ctx, .Save), "the bindings are still there")
}
