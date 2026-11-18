package iv_debug

import input "../iv_input"

// An Input made from the state of an iv_input context, for a program that uses iv_input (call it after the frame's events are in the context). `dt` is
// the seconds since the last frame. The wheel is iv_input's vertical wheel (up is positive). The typed characters are valid until the context's next
// begin_frame.
input_from :: proc(ctx: ^input.Context($S), dt: f32) -> Input {
	in_: Input
	x, y := input.mouse_position(ctx)
	in_.mouse = {x, y}
	buttons := [Button]input.Mouse_Button {
		.Left   = .Left,
		.Right  = .Right,
		.Middle = .Middle,
	}
	for b in Button {
		in_.down[b] = input.mouse_down(ctx, buttons[b])
		in_.pressed[b] = input.mouse_pressed(ctx, buttons[b])
		in_.released[b] = input.mouse_released(ctx, buttons[b])
	}
	_, in_.wheel = input.wheel(ctx)
	in_.typed = input.typed(ctx)
	pairs := [Key]input.Key {
		.Enter     = .Enter,
		.Escape    = .Escape,
		.Tab       = .Tab,
		.Backspace = .Backspace,
		.Delete    = .Delete,
		.Left      = .Left,
		.Right     = .Right,
		.Up        = .Up,
		.Down      = .Down,
		.Home      = .Home,
		.End       = .End,
		.A         = .A,
		.C         = .C,
		.V         = .V,
		.X         = .X,
		.Z         = .Z,
	}
	for k in Key {
		if input.key_pressed(ctx, pairs[k]) || input.key_repeated(ctx, pairs[k]) {
			in_.keys += {k}
		}
	}
	mods := input.modifiers(ctx)
	in_.ctrl = .Ctrl in mods
	in_.shift = .Shift in mods
	in_.alt = .Alt in mods
	in_.dt = dt
	return in_
}
