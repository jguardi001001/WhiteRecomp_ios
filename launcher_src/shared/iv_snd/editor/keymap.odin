package main

import input "shared:iv_input"

// ---------------------------------------------------------------------------
// The editor's signals and what they are bound to.
//
// The shared `input` package knows no keys of its own: this file is where this program says what it listens for (Signal)
// and which keys, mouse buttons and gamepad buttons make each (key_bindings). The table is an ordinary slice that the
// program owns; the module reads it on every query, so changing it at run time (a keyboard settings dialog) changes the
// keys at once. The typed letters of the roll (h j k l, x, y, p, ...) are not signals: they are characters, and
// come from input.typed.
// ---------------------------------------------------------------------------

Signal :: enum {
	// Moving about in lists, menus, dialogs, text fields and the roll.
	Nav_Confirm, // Enter
	Nav_Cancel, // Esc
	Nav_Up,
	Nav_Down,
	Nav_Left,
	Nav_Right,
	Nav_Page_Up,
	Nav_Page_Down,
	Nav_Home,
	Nav_End,
	Nav_Tab, // from one field to the next
	Nav_Backspace,
	Nav_Delete,
	Menu_Toggle, // F10: the menu bar from the keyboard
	// Commands that work in every view (see global_keys). Each runs the Action in GLOBAL_COMMANDS.
	Cmd_Palette,
	Cmd_Save,
	Cmd_Save_As,
	Cmd_Open,
	Cmd_New,
	Cmd_Export_Wav,
	Cmd_Quit,
	Cmd_Undo,
	Cmd_Redo,
	Cmd_Instrument,
	Cmd_Patch,
	Cmd_Effects,
	Cmd_Track_Next,
	Cmd_Track_Prev,
	Cmd_Help,
	Cmd_Play_From_Start,
	Cmd_Loop_Toggle,
	Cmd_Scale_Up,
	Cmd_Scale_Down,
	// Ctrl commands that only the roll has.
	Roll_Select_All,
	Roll_Duplicate,
	Roll_Copy,
	Roll_Paste,
	Roll_Cut,
}

// The Action each of the global commands runs.
GLOBAL_COMMANDS := #partial [Signal]Action {
	.Cmd_Palette         = .Palette,
	.Cmd_Save            = .File_Save,
	.Cmd_Save_As         = .File_Save_As,
	.Cmd_Open            = .File_Open,
	.Cmd_New             = .File_New,
	.Cmd_Export_Wav      = .File_Export_Wav,
	.Cmd_Quit            = .File_Quit,
	.Cmd_Undo            = .Edit_Undo,
	.Cmd_Redo            = .Edit_Redo,
	.Cmd_Instrument      = .Track_Instrument,
	.Cmd_Patch           = .Track_Patch,
	.Cmd_Effects         = .View_Effects,
	.Cmd_Track_Next      = .Track_Next,
	.Cmd_Track_Prev      = .Track_Prev,
	.Cmd_Help            = .Help_Keys,
	.Cmd_Play_From_Start = .Play_Start,
	.Cmd_Loop_Toggle     = .Play_Loop_Toggle,
	.Cmd_Scale_Up        = .View_Scale_Up,
	.Cmd_Scale_Down      = .View_Scale_Down,
}

// What the keys are bound to when the editor starts. (There are no defaults inside the input module: this is the
// program's own table.) Several lines may name one signal. Arrow keys and the like count with any modifier held (Shift
// extends a selection); "exact" keeps Ctrl+S and Ctrl+Shift+S, Tab and Shift+Tab apart.
B :: input.make_binding

DEFAULT_KEY_BINDINGS := [?]input.Binding(Signal) {
	B(Signal, .Nav_Confirm, input.on_key(.Enter), input.on_key(.Kp_Enter)),
	B(Signal, .Nav_Cancel, input.on_key(.Escape)),
	B(Signal, .Nav_Up, input.on_key(.Up)),
	B(Signal, .Nav_Down, input.on_key(.Down)),
	B(Signal, .Nav_Left, input.on_key(.Left)),
	B(Signal, .Nav_Right, input.on_key(.Right)),
	B(Signal, .Nav_Page_Up, input.on_key(.Page_Up)),
	B(Signal, .Nav_Page_Down, input.on_key(.Page_Down)),
	B(Signal, .Nav_Home, input.on_key(.Home)),
	B(Signal, .Nav_End, input.on_key(.End)),
	B(Signal, .Nav_Tab, input.on_key(.Tab)),
	B(Signal, .Nav_Backspace, input.on_key(.Backspace)),
	B(Signal, .Nav_Delete, input.on_key(.Delete)),
	B(Signal, .Menu_Toggle, input.on_key(.F10)),
	B(Signal, .Cmd_Palette, input.on_key(.P, {.Ctrl})),
	B(Signal, .Cmd_Save, input.on_key(.S, {.Ctrl}, true)),
	B(Signal, .Cmd_Save_As, input.on_key(.S, {.Ctrl, .Shift}, true)),
	B(Signal, .Cmd_Open, input.on_key(.O, {.Ctrl})),
	B(Signal, .Cmd_New, input.on_key(.N, {.Ctrl})),
	B(Signal, .Cmd_Export_Wav, input.on_key(.E, {.Ctrl})),
	B(Signal, .Cmd_Quit, input.on_key(.Q, {.Ctrl})),
	B(Signal, .Cmd_Undo, input.on_key(.Z, {.Ctrl}, true)),
	B(Signal, .Cmd_Redo, input.on_key(.Z, {.Ctrl, .Shift}, true), input.on_key(.R, {.Ctrl}), input.on_key(.Y, {.Ctrl})),
	B(Signal, .Cmd_Instrument, input.on_key(.I, {.Ctrl})),
	B(Signal, .Cmd_Patch, input.on_key(.T, {.Ctrl})),
	B(Signal, .Cmd_Effects, input.on_key(.G, {.Ctrl})),
	B(Signal, .Cmd_Track_Next, input.on_key(.Tab, {}, true)),
	B(Signal, .Cmd_Track_Prev, input.on_key(.Tab, {.Shift}, true)),
	B(Signal, .Cmd_Help, input.on_key(.F1)),
	B(Signal, .Cmd_Play_From_Start, input.on_key(.F5)),
	B(Signal, .Cmd_Loop_Toggle, input.on_key(.F6)),
	B(Signal, .Cmd_Scale_Up, input.on_key(.F11)),
	B(Signal, .Cmd_Scale_Down, input.on_key(.F12)),
	B(Signal, .Roll_Select_All, input.on_key(.A, {.Ctrl})),
	B(Signal, .Roll_Duplicate, input.on_key(.D, {.Ctrl})),
	B(Signal, .Roll_Copy, input.on_key(.C, {.Ctrl})),
	B(Signal, .Roll_Paste, input.on_key(.V, {.Ctrl})),
	B(Signal, .Roll_Cut, input.on_key(.X, {.Ctrl})),
}

// Everything the program asks the input module goes through this one context.
ictx: input.Context(Signal)
key_bindings: []input.Binding(Signal)

keymap_init :: proc() {
	key_bindings = make([]input.Binding(Signal), len(DEFAULT_KEY_BINDINGS))
	copy(key_bindings, DEFAULT_KEY_BINDINGS[:])
	input.use_bindings(&ictx, &key_bindings)
}

// Did the signal start in this frame (a press, without the repeats of a held key)?
hit :: proc(s: Signal) -> bool {
	return input.signal_pressed(&ictx, s)
}

// Did it start in this frame, or is the operating system repeating it because the key is held? (cursor keys, lists)
rep :: proc(s: Signal) -> bool {
	return input.signal_repeated(&ictx, s)
}

// A key press, including the repeats while the key is held.
kp :: proc(k: input.Key) -> bool {
	return input.key_repeated(&ictx, k)
}

// A key press without repeats.
k1 :: proc(k: input.Key) -> bool {
	return input.key_pressed(&ictx, k)
}
