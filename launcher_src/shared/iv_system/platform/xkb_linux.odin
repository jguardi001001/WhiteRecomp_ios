package platform

import "core:c"
import "core:dynlib"
import input "../../iv_input"

// ---------------------------------------------------------------------------
// Keyboards on Wayland: the compositor sends raw key codes (evdev) and the keymap as text; libxkbcommon turns them into
// what the user's layout says: which letter a key is, which character it types. libxkbcommon is loaded when the first
// keymap arrives (a Wayland system has it), and everything works without it, except that no text is typed: keys are then
// named by where they sit on a US keyboard.
// ---------------------------------------------------------------------------

Xkb_Rule_Names :: struct {
	rules, model, layout, variant, options: cstring,
}

// The functions of libxkbcommon that are used (loaded by name: `xkb_` + the field's name).
Xkb_Procs :: struct {
	context_new:                  proc "c" (flags: u32) -> rawptr,
	context_unref:                proc "c" (ctx: rawptr),
	keymap_new_from_string:       proc "c" (ctx: rawptr, text: cstring, format: u32, flags: u32) -> rawptr,
	keymap_new_from_names:        proc "c" (ctx: rawptr, names: ^Xkb_Rule_Names, flags: u32) -> rawptr,
	keymap_unref:                 proc "c" (keymap: rawptr),
	keymap_key_repeats:           proc "c" (keymap: rawptr, key: u32) -> c.int,
	keymap_key_get_syms_by_level: proc "c" (keymap: rawptr, key: u32, layout: u32, level: u32, syms: ^[^]u32) -> c.int,
	state_new:                    proc "c" (keymap: rawptr) -> rawptr,
	state_unref:                  proc "c" (state: rawptr),
	state_update_mask:            proc "c" (state: rawptr, depressed, latched, locked, depressed_layout, latched_layout, locked_layout: u32) -> u32,
	state_key_get_utf32:          proc "c" (state: rawptr, key: u32) -> u32,
	state_key_get_layout:         proc "c" (state: rawptr, key: u32) -> u32,
}

XKB_KEYMAP_FORMAT_TEXT_V1 :: 1

Xkb :: struct {
	procs:   Xkb_Procs,
	library: dynlib.Library,
	loaded:  bool, // the library is there and `procs` are filled
	ctx:     rawptr,
	keymap:  rawptr, // nil until the compositor sends one
	state:   rawptr,
}

// Loads libxkbcommon (once) and makes the context. false: not available, keys are then positional.
xkb_load :: proc(x: ^Xkb) -> bool {
	if x.loaded {
		return true
	}
	lib, ok := dynlib.load_library("libxkbcommon.so.0")
	if !ok {
		return false
	}
	if _, symbols_ok := dynlib.initialize_symbols(&x.procs, "libxkbcommon.so.0", "xkb_", ""); !symbols_ok {
		_ = dynlib.unload_library(lib)
		x.procs = {}
		return false
	}
	x.library = lib
	x.ctx = x.procs.context_new(0)
	if x.ctx == nil {
		_ = dynlib.unload_library(lib)
		x.procs = {}
		return false
	}
	x.loaded = true
	return true
}

// Takes a keymap (the compositor's text, or one made from layout names) and makes the state for it; the old ones go.
xkb_set_keymap :: proc(x: ^Xkb, keymap: rawptr) {
	if x.state != nil {
		x.procs.state_unref(x.state)
		x.state = nil
	}
	if x.keymap != nil {
		x.procs.keymap_unref(x.keymap)
	}
	x.keymap = keymap
	if keymap != nil {
		x.state = x.procs.state_new(keymap)
	}
}

xkb_destroy :: proc(x: ^Xkb) {
	if !x.loaded {
		return
	}
	xkb_set_keymap(x, nil)
	x.procs.context_unref(x.ctx)
	_ = dynlib.unload_library(x.library)
	x^ = {}
}

xkb_ready :: proc(x: ^Xkb) -> bool {
	return x.loaded && x.keymap != nil && x.state != nil
}

// ---- keys ---------------------------------------------------------------------------------------------------------

// A key by where it sits (the Linux input event codes of linux/input-event-codes.h, the way a US keyboard names them).
evdev_key :: proc "contextless" (code: u32) -> input.Key {
	switch code {
	case 1:
		return .Escape
	case 2 ..= 10:
		return input.Key(u32(input.Key.Num_1) + code - 2) // 1 .. 9
	case 11:
		return .Num_0
	case 12:
		return .Minus
	case 13:
		return .Equal
	case 14:
		return .Backspace
	case 15:
		return .Tab
	case 16:
		return .Q
	case 17:
		return .W
	case 18:
		return .E
	case 19:
		return .R
	case 20:
		return .T
	case 21:
		return .Y
	case 22:
		return .U
	case 23:
		return .I
	case 24:
		return .O
	case 25:
		return .P
	case 26:
		return .Left_Bracket
	case 27:
		return .Right_Bracket
	case 28:
		return .Enter
	case 29:
		return .Left_Ctrl
	case 30:
		return .A
	case 31:
		return .S
	case 32:
		return .D
	case 33:
		return .F
	case 34:
		return .G
	case 35:
		return .H
	case 36:
		return .J
	case 37:
		return .K
	case 38:
		return .L
	case 39:
		return .Semicolon
	case 40:
		return .Apostrophe
	case 41:
		return .Grave
	case 42:
		return .Left_Shift
	case 43:
		return .Backslash
	case 44:
		return .Z
	case 45:
		return .X
	case 46:
		return .C
	case 47:
		return .V
	case 48:
		return .B
	case 49:
		return .N
	case 50:
		return .M
	case 51:
		return .Comma
	case 52:
		return .Period
	case 53:
		return .Slash
	case 54:
		return .Right_Shift
	case 55:
		return .Kp_Multiply
	case 56:
		return .Left_Alt
	case 57:
		return .Space
	case 58:
		return .Caps_Lock
	case 59 ..= 68:
		return input.Key(u32(input.Key.F1) + code - 59) // F1 .. F10
	case 69:
		return .Num_Lock
	case 70:
		return .Scroll_Lock
	case 71 ..= 73:
		return input.Key(u32(input.Key.Kp_7) + code - 71) // Kp 7 8 9
	case 74:
		return .Kp_Subtract
	case 75 ..= 77:
		return input.Key(u32(input.Key.Kp_4) + code - 75)
	case 78:
		return .Kp_Add
	case 79 ..= 81:
		return input.Key(u32(input.Key.Kp_1) + code - 79)
	case 82:
		return .Kp_0
	case 83:
		return .Kp_Decimal
	case 87:
		return .F11
	case 88:
		return .F12
	case 96:
		return .Kp_Enter
	case 97:
		return .Right_Ctrl
	case 98:
		return .Kp_Divide
	case 99:
		return .Print_Screen
	case 100:
		return .Right_Alt
	case 102:
		return .Home
	case 103:
		return .Up
	case 104:
		return .Page_Up
	case 105:
		return .Left
	case 106:
		return .Right
	case 107:
		return .End
	case 108:
		return .Down
	case 109:
		return .Page_Down
	case 110:
		return .Insert
	case 111:
		return .Delete
	case 117:
		return .Kp_Equal
	case 119:
		return .Pause
	case 125:
		return .Left_Super
	case 126:
		return .Right_Super
	case 127:
		return .Menu
	case 183 ..= 194:
		return input.Key(u32(input.Key.F13) + code - 183) // F13 .. F24
	}
	return .None
}

// The key for an evdev code, with the letters named by the user's layout: on a German keyboard the key that sits where a US
// keyboard has Y is Z, and a program that asks for .Z must get it. Everything else is named by position.
translate_key :: proc(x: ^Xkb, code: u32) -> input.Key {
	key := evdev_key(code)
	if key >= .A && key <= .Z && xkb_ready(x) {
		xkb_code := code + 8 // xkb's key codes start 8 above evdev's
		layout := x.procs.state_key_get_layout(x.state, xkb_code)
		syms: [^]u32
		if x.procs.keymap_key_get_syms_by_level(x.keymap, xkb_code, layout, 0, &syms) > 0 {
			sym := syms[0]
			switch {
			case sym >= 'a' && sym <= 'z':
				return input.Key(u32(input.Key.A) + sym - 'a')
			case sym >= 'A' && sym <= 'Z':
				return input.Key(u32(input.Key.A) + sym - 'A')
			}
		}
	}
	return key
}

// The character a key types in the current state (shift, layout, dead keys not included), or 0 for a key that types none.
key_character :: proc(x: ^Xkb, code: u32) -> rune {
	if !xkb_ready(x) {
		return 0
	}
	c := x.procs.state_key_get_utf32(x.state, code + 8)
	if c < 32 || c == 127 { // the control characters (Tab, Enter, Backspace, and Ctrl + a letter) are keys, not text
		return 0
	}
	return rune(c)
}

// Does the keymap say this key repeats when held? (Modifiers, Caps Lock and the like do not.)
key_repeats :: proc(x: ^Xkb, code: u32) -> bool {
	if xkb_ready(x) {
		return x.procs.keymap_key_repeats(x.keymap, code + 8) != 0
	}
	key := evdev_key(code)
	#partial switch key {
	case .None, .Left_Shift, .Right_Shift, .Left_Ctrl, .Right_Ctrl, .Left_Alt, .Right_Alt, .Left_Super, .Right_Super, .Caps_Lock, .Num_Lock, .Scroll_Lock:
		return false
	}
	return true
}
