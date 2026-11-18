package iv_input

// ---------------------------------------------------------------------------
// The names of things that can be pressed. They are the module's own: nothing here refers to any window library, SDL,
// the operating system or a particular game. Whatever gathers the hardware's input (raylib, SDL, Win32 messages, a test)
// translates its own codes into these and reports them with the set_* procedures of state.odin.
// ---------------------------------------------------------------------------

// What one button (a key, a mouse button, a gamepad button) is doing in this frame. A button that is held has .Down; the
// frame in which it went down also has .Pressed, the frame in which it went up has .Released (and not .Down), and a
// key that the operating system repeats while it is held has .Repeat in the frames that make a repeat. A very short tap
// can be .Pressed and .Released in the same frame.
State_Flag :: enum u8 {
	Down,
	Pressed,
	Released,
	Repeat,
}

State :: bit_set[State_Flag;u8]

Modifier :: enum u8 {
	Shift,
	Ctrl,
	Alt,
	Super, // the Windows key, the command key
}

Modifiers :: bit_set[Modifier;u8]

// Keys by what they are called, not by where they sit (the layout does not matter to a program that asks for .Z).
Key :: enum u16 {
	None,
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
	Num_0, // the digits of the top row
	Num_1,
	Num_2,
	Num_3,
	Num_4,
	Num_5,
	Num_6,
	Num_7,
	Num_8,
	Num_9,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	F13,
	F14,
	F15,
	F16,
	F17,
	F18,
	F19,
	F20,
	F21,
	F22,
	F23,
	F24,
	Escape,
	Enter,
	Tab,
	Space,
	Backspace,
	Delete,
	Insert,
	Home,
	End,
	Page_Up,
	Page_Down,
	Left,
	Right,
	Up,
	Down,
	Left_Shift,
	Right_Shift,
	Left_Ctrl,
	Right_Ctrl,
	Left_Alt,
	Right_Alt,
	Left_Super,
	Right_Super,
	Caps_Lock,
	Scroll_Lock,
	Num_Lock,
	Print_Screen,
	Pause,
	Menu,
	Apostrophe,
	Comma,
	Minus,
	Period,
	Slash,
	Semicolon,
	Equal,
	Left_Bracket,
	Backslash,
	Right_Bracket,
	Grave, // the key of the tilde (~) and the back tick
	Kp_0, // the number pad
	Kp_1,
	Kp_2,
	Kp_3,
	Kp_4,
	Kp_5,
	Kp_6,
	Kp_7,
	Kp_8,
	Kp_9,
	Kp_Decimal,
	Kp_Divide,
	Kp_Multiply,
	Kp_Subtract,
	Kp_Add,
	Kp_Enter,
	Kp_Equal,
}

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
	Back, // the side buttons
	Forward,
	Extra,
}

// Gamepad buttons by the place on the pad, the way an Xbox pad lays them out. (Face_Down is A on an Xbox pad and
// the cross on a PlayStation pad.)
Gamepad_Button :: enum u8 {
	Face_Down,
	Face_Right,
	Face_Left,
	Face_Up,
	Dpad_Up,
	Dpad_Down,
	Dpad_Left,
	Dpad_Right,
	Left_Shoulder, // LB
	Right_Shoulder, // RB
	Left_Trigger, // LT (pulled all the way; the axis has the amount)
	Right_Trigger,
	Back, // select
	Guide,
	Start,
	Left_Stick, // L3: the stick, pressed
	Right_Stick,
}

// -1 .. 1 for the sticks (left and up are negative, as on the screen) and 0 .. 1 for the triggers.
Gamepad_Axis :: enum u8 {
	Left_X,
	Left_Y,
	Right_X,
	Right_Y,
	Left_Trigger,
	Right_Trigger,
}

Wheel_Axis :: enum u8 {
	Vertical,
	Horizontal,
}

// The way along an axis (or the wheel) that counts.
Direction :: enum u8 {
	Positive,
	Negative,
}

// A key's name for a menu or a list of bindings: "Esc", "Page Down", "A", "Num 5", "Kp 5".
key_name :: proc "contextless" (k: Key) -> string {
	#partial switch k {
	case .None:
		return ""
	case .Num_0 ..= .Num_9:
		return NUM_NAMES[int(k) - int(Key.Num_0)]
	case .Kp_0 ..= .Kp_9:
		return KP_NAMES[int(k) - int(Key.Kp_0)]
	case .F1 ..= .F24:
		return F_NAMES[int(k) - int(Key.F1)]
	case .A ..= .Z:
		return LETTER_NAMES[int(k) - int(Key.A)]
	case .Escape:
		return "Esc"
	case .Enter:
		return "Enter"
	case .Tab:
		return "Tab"
	case .Space:
		return "Space"
	case .Backspace:
		return "Backspace"
	case .Delete:
		return "Del"
	case .Insert:
		return "Ins"
	case .Home:
		return "Home"
	case .End:
		return "End"
	case .Page_Up:
		return "Page Up"
	case .Page_Down:
		return "Page Down"
	case .Left:
		return "Left"
	case .Right:
		return "Right"
	case .Up:
		return "Up"
	case .Down:
		return "Down"
	case .Left_Shift:
		return "Left Shift"
	case .Right_Shift:
		return "Right Shift"
	case .Left_Ctrl:
		return "Left Ctrl"
	case .Right_Ctrl:
		return "Right Ctrl"
	case .Left_Alt:
		return "Left Alt"
	case .Right_Alt:
		return "Right Alt"
	case .Left_Super:
		return "Left Super"
	case .Right_Super:
		return "Right Super"
	case .Caps_Lock:
		return "Caps Lock"
	case .Scroll_Lock:
		return "Scroll Lock"
	case .Num_Lock:
		return "Num Lock"
	case .Print_Screen:
		return "Print Screen"
	case .Pause:
		return "Pause"
	case .Menu:
		return "Menu"
	case .Apostrophe:
		return "'"
	case .Comma:
		return ","
	case .Minus:
		return "-"
	case .Period:
		return "."
	case .Slash:
		return "/"
	case .Semicolon:
		return ";"
	case .Equal:
		return "="
	case .Left_Bracket:
		return "["
	case .Backslash:
		return "\\"
	case .Right_Bracket:
		return "]"
	case .Grave:
		return "`"
	case .Kp_Decimal:
		return "Kp ."
	case .Kp_Divide:
		return "Kp /"
	case .Kp_Multiply:
		return "Kp *"
	case .Kp_Subtract:
		return "Kp -"
	case .Kp_Add:
		return "Kp +"
	case .Kp_Enter:
		return "Kp Enter"
	case .Kp_Equal:
		return "Kp ="
	}
	return ""
}

mouse_button_name :: proc "contextless" (b: Mouse_Button) -> string {
	switch b {
	case .Left:
		return "Left Mouse"
	case .Right:
		return "Right Mouse"
	case .Middle:
		return "Middle Mouse"
	case .Back:
		return "Mouse Back"
	case .Forward:
		return "Mouse Forward"
	case .Extra:
		return "Mouse Extra"
	}
	return ""
}

gamepad_button_name :: proc "contextless" (b: Gamepad_Button) -> string {
	switch b {
	case .Face_Down:
		return "A"
	case .Face_Right:
		return "B"
	case .Face_Left:
		return "X"
	case .Face_Up:
		return "Y"
	case .Dpad_Up:
		return "D-pad Up"
	case .Dpad_Down:
		return "D-pad Down"
	case .Dpad_Left:
		return "D-pad Left"
	case .Dpad_Right:
		return "D-pad Right"
	case .Left_Shoulder:
		return "LB"
	case .Right_Shoulder:
		return "RB"
	case .Left_Trigger:
		return "LT"
	case .Right_Trigger:
		return "RT"
	case .Back:
		return "Back"
	case .Guide:
		return "Guide"
	case .Start:
		return "Start"
	case .Left_Stick:
		return "L3"
	case .Right_Stick:
		return "R3"
	}
	return ""
}

gamepad_axis_name :: proc "contextless" (a: Gamepad_Axis) -> string {
	switch a {
	case .Left_X:
		return "Left Stick X"
	case .Left_Y:
		return "Left Stick Y"
	case .Right_X:
		return "Right Stick X"
	case .Right_Y:
		return "Right Stick Y"
	case .Left_Trigger:
		return "LT"
	case .Right_Trigger:
		return "RT"
	}
	return ""
}

@(private)
NUM_NAMES := [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
@(private)
KP_NAMES := [10]string{"Kp 0", "Kp 1", "Kp 2", "Kp 3", "Kp 4", "Kp 5", "Kp 6", "Kp 7", "Kp 8", "Kp 9"}
@(private)
F_NAMES := [24]string{"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24"}
@(private)
LETTER_NAMES := [26]string{"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"}
