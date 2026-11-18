// The directory is input/raylib (import "shared:input/raylib"), but the package is named input_raylib: a package named
// `raylib` would collide with vendor:raylib in any program that imports both.
package iv_input_raylib

import input ".."
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// The one place that connects `input` (which knows no hardware) to raylib. Programs that use raylib call `poll` once per frame
// and everything else goes through the `input` package; programs that use something else write their own poll
// and do not use this package. (It is a package of its own so that `input` stays free of any dependency.)
//
//   ctx: input.Context(My_Signal)
//   ...
//   import input_rl "shared:iv_input/raylib"
//   input_rl.poll(&ctx)                          // each frame, after the window has been given its events
//   if input.signal_pressed(&ctx, .Jump) { ... }
// ---------------------------------------------------------------------------

// Starts a frame (input.begin_frame) and reports what raylib knows: every key, the mouse buttons, the position (divided by
// `mouse_scale`, for a program that lays out in scaled units), the wheel, the characters typed and every
// gamepad that is connected. raylib's own Pressed / Released / repeat of the frame are passed on as they are.
poll :: proc(ctx: ^input.Context($S), mouse_scale: f32 = 1) {
	input.begin_frame(ctx)

	for rk, k in KEY_MAP {
		if rk == .KEY_NULL {
			continue
		}
		s: input.State
		if rl.IsKeyDown(rk) {
			s += {.Down}
		}
		if rl.IsKeyPressed(rk) {
			s += {.Down, .Pressed}
		}
		if rl.IsKeyReleased(rk) {
			s += {.Released}
		}
		if rl.IsKeyPressedRepeat(rk) {
			s += {.Down, .Repeat}
		}
		input.set_key_state(ctx, k, s)
	}

	for rb, b in MOUSE_MAP {
		s: input.State
		if rl.IsMouseButtonDown(rb) {
			s += {.Down}
		}
		if rl.IsMouseButtonPressed(rb) {
			s += {.Down, .Pressed}
		}
		if rl.IsMouseButtonReleased(rb) {
			s += {.Released}
		}
		input.set_mouse_state(ctx, b, s)
	}
	m := rl.GetMousePosition()
	scale := mouse_scale if mouse_scale > 0 else 1
	input.set_mouse_position(ctx, m.x / scale, m.y / scale)
	w := rl.GetMouseWheelMoveV()
	input.add_wheel(ctx, w.x, w.y)

	for {
		c := rl.GetCharPressed()
		if c == 0 {
			break
		}
		input.push_char(ctx, c)
	}

	for p in 0 ..< input.MAX_PADS {
		id := i32(p)
		there := rl.IsGamepadAvailable(id)
		input.set_pad_connected(ctx, p, there)
		if !there {
			continue
		}
		for rb, b in PAD_BUTTON_MAP {
			s: input.State
			if rl.IsGamepadButtonDown(id, rb) {
				s += {.Down}
			}
			if rl.IsGamepadButtonPressed(id, rb) {
				s += {.Down, .Pressed}
			}
			if rl.IsGamepadButtonReleased(id, rb) {
				s += {.Released}
			}
			input.set_pad_button_state(ctx, p, b, s)
		}
		for ra, a in PAD_AXIS_MAP {
			input.set_pad_axis(ctx, p, a, rl.GetGamepadAxisMovement(id, ra))
		}
	}
}

// ---- translating names (for code that still holds raylib's) ------------------------------------------------

key_to_raylib :: proc(k: input.Key) -> rl.KeyboardKey {
	return KEY_MAP[k]
}

// The module's key for a raylib key (.None if the module has none).
key_from_raylib :: proc(rk: rl.KeyboardKey) -> input.Key {
	if rk == .KEY_NULL {
		return .None
	}
	for v, k in KEY_MAP {
		if v == rk {
			return k
		}
	}
	return .None
}

mouse_to_raylib :: proc(b: input.Mouse_Button) -> rl.MouseButton {
	return MOUSE_MAP[b]
}

pad_button_to_raylib :: proc(b: input.Gamepad_Button) -> rl.GamepadButton {
	return PAD_BUTTON_MAP[b]
}

pad_button_from_raylib :: proc(rb: rl.GamepadButton) -> (b: input.Gamepad_Button, ok: bool) {
	for v, k in PAD_BUTTON_MAP {
		if v == rb {
			return k, true
		}
	}
	return {}, false
}

KEY_MAP := [input.Key]rl.KeyboardKey {
	.None          = .KEY_NULL,
	.A             = .A,
	.B             = .B,
	.C             = .C,
	.D             = .D,
	.E             = .E,
	.F             = .F,
	.G             = .G,
	.H             = .H,
	.I             = .I,
	.J             = .J,
	.K             = .K,
	.L             = .L,
	.M             = .M,
	.N             = .N,
	.O             = .O,
	.P             = .P,
	.Q             = .Q,
	.R             = .R,
	.S             = .S,
	.T             = .T,
	.U             = .U,
	.V             = .V,
	.W             = .W,
	.X             = .X,
	.Y             = .Y,
	.Z             = .Z,
	.Num_0         = .ZERO,
	.Num_1         = .ONE,
	.Num_2         = .TWO,
	.Num_3         = .THREE,
	.Num_4         = .FOUR,
	.Num_5         = .FIVE,
	.Num_6         = .SIX,
	.Num_7         = .SEVEN,
	.Num_8         = .EIGHT,
	.Num_9         = .NINE,
	.F1            = .F1,
	.F2            = .F2,
	.F3            = .F3,
	.F4            = .F4,
	.F5            = .F5,
	.F6            = .F6,
	.F7            = .F7,
	.F8            = .F8,
	.F9            = .F9,
	.F10           = .F10,
	.F11           = .F11,
	.F12           = .F12,
	.F13           = .KEY_NULL, // (raylib has no keys past F12)
	.F14           = .KEY_NULL,
	.F15           = .KEY_NULL,
	.F16           = .KEY_NULL,
	.F17           = .KEY_NULL,
	.F18           = .KEY_NULL,
	.F19           = .KEY_NULL,
	.F20           = .KEY_NULL,
	.F21           = .KEY_NULL,
	.F22           = .KEY_NULL,
	.F23           = .KEY_NULL,
	.F24           = .KEY_NULL,
	.Escape        = .ESCAPE,
	.Enter         = .ENTER,
	.Tab           = .TAB,
	.Space         = .SPACE,
	.Backspace     = .BACKSPACE,
	.Delete        = .DELETE,
	.Insert        = .INSERT,
	.Home          = .HOME,
	.End           = .END,
	.Page_Up       = .PAGE_UP,
	.Page_Down     = .PAGE_DOWN,
	.Left          = .LEFT,
	.Right         = .RIGHT,
	.Up            = .UP,
	.Down          = .DOWN,
	.Left_Shift    = .LEFT_SHIFT,
	.Right_Shift   = .RIGHT_SHIFT,
	.Left_Ctrl     = .LEFT_CONTROL,
	.Right_Ctrl    = .RIGHT_CONTROL,
	.Left_Alt      = .LEFT_ALT,
	.Right_Alt     = .RIGHT_ALT,
	.Left_Super    = .LEFT_SUPER,
	.Right_Super   = .RIGHT_SUPER,
	.Caps_Lock     = .CAPS_LOCK,
	.Scroll_Lock   = .SCROLL_LOCK,
	.Num_Lock      = .NUM_LOCK,
	.Print_Screen  = .PRINT_SCREEN,
	.Pause         = .PAUSE,
	.Menu          = .KB_MENU,
	.Apostrophe    = .APOSTROPHE,
	.Comma         = .COMMA,
	.Minus         = .MINUS,
	.Period        = .PERIOD,
	.Slash         = .SLASH,
	.Semicolon     = .SEMICOLON,
	.Equal         = .EQUAL,
	.Left_Bracket  = .LEFT_BRACKET,
	.Backslash     = .BACKSLASH,
	.Right_Bracket = .RIGHT_BRACKET,
	.Grave         = .GRAVE,
	.Kp_0          = .KP_0,
	.Kp_1          = .KP_1,
	.Kp_2          = .KP_2,
	.Kp_3          = .KP_3,
	.Kp_4          = .KP_4,
	.Kp_5          = .KP_5,
	.Kp_6          = .KP_6,
	.Kp_7          = .KP_7,
	.Kp_8          = .KP_8,
	.Kp_9          = .KP_9,
	.Kp_Decimal    = .KP_DECIMAL,
	.Kp_Divide     = .KP_DIVIDE,
	.Kp_Multiply   = .KP_MULTIPLY,
	.Kp_Subtract   = .KP_SUBTRACT,
	.Kp_Add        = .KP_ADD,
	.Kp_Enter      = .KP_ENTER,
	.Kp_Equal      = .KP_EQUAL,
}

MOUSE_MAP := [input.Mouse_Button]rl.MouseButton {
	.Left    = .LEFT,
	.Right   = .RIGHT,
	.Middle  = .MIDDLE,
	.Back    = .BACK,
	.Forward = .FORWARD,
	.Extra   = .EXTRA,
}

PAD_BUTTON_MAP := [input.Gamepad_Button]rl.GamepadButton {
	.Face_Down      = .RIGHT_FACE_DOWN,
	.Face_Right     = .RIGHT_FACE_RIGHT,
	.Face_Left      = .RIGHT_FACE_LEFT,
	.Face_Up        = .RIGHT_FACE_UP,
	.Dpad_Up        = .LEFT_FACE_UP,
	.Dpad_Down      = .LEFT_FACE_DOWN,
	.Dpad_Left      = .LEFT_FACE_LEFT,
	.Dpad_Right     = .LEFT_FACE_RIGHT,
	.Left_Shoulder  = .LEFT_TRIGGER_1,
	.Right_Shoulder = .RIGHT_TRIGGER_1,
	.Left_Trigger   = .LEFT_TRIGGER_2,
	.Right_Trigger  = .RIGHT_TRIGGER_2,
	.Back           = .MIDDLE_LEFT,
	.Guide          = .MIDDLE,
	.Start          = .MIDDLE_RIGHT,
	.Left_Stick     = .LEFT_THUMB,
	.Right_Stick    = .RIGHT_THUMB,
}

PAD_AXIS_MAP := [input.Gamepad_Axis]rl.GamepadAxis {
	.Left_X        = .LEFT_X,
	.Left_Y        = .LEFT_Y,
	.Right_X       = .RIGHT_X,
	.Right_Y       = .RIGHT_Y,
	.Left_Trigger  = .LEFT_TRIGGER,
	.Right_Trigger = .RIGHT_TRIGGER,
}
