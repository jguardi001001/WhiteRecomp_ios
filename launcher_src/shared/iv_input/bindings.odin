package iv_input

// ---------------------------------------------------------------------------
// Signals and bindings.
//
// A signal is something the program wants to know ("UI_Confirm", "Jump"): an enum of the program's own, which this module
// never sees. A binding says which sources make the signal: a key (with modifiers if you like), a mouse button, the
// wheel, a gamepad button, a gamepad axis pulled past a threshold. This module has no default bindings at all:
// the program owns a table of them (a slice or a dynamic array of Binding), hands the module a *pointer* to it
// (use_bindings), and may edit it whenever it likes (a settings screen that rebinds a key): every query reads the table as it
// is at that moment.
//
// A signal may have several bindings (a second Binding with the same signal) and a binding up to MAX_SOURCES sources; the
// signal is down when any of them is.
// ---------------------------------------------------------------------------

MAX_SOURCES :: 4
DEFAULT_AXIS_THRESHOLD :: f32(0.5)

// A key, with the modifiers that have to be held (none: whatever is held does not matter). With `exact` no other
// modifier may be held ("Ctrl+S" should not answer to Ctrl+Shift+S).
Key_Source :: struct {
	key:   Key,
	mods:  Modifiers,
	exact: bool,
}

Mouse_Source :: struct {
	button: Mouse_Button,
}

// A turn of the wheel in a direction (a pulse of one frame: it is Pressed and Down in the frames the wheel moves).
Wheel_Source :: struct {
	axis:      Wheel_Axis,
	direction: Direction,
}

// A gamepad button. `pad` 0 is any gamepad, 1 is the first, 2 the second, and so on.
Pad_Button_Source :: struct {
	button: Gamepad_Button,
	pad:    u8,
}

// A gamepad axis in one direction (the stick pushed left, a trigger pulled): it is down when the axis is past `threshold`
// (0 means DEFAULT_AXIS_THRESHOLD), and its value is how far it is.
Pad_Axis_Source :: struct {
	axis:      Gamepad_Axis,
	direction: Direction,
	threshold: f32,
	pad:       u8,
}

// Nil is no source (an empty slot).
Source :: union {
	Key_Source,
	Mouse_Source,
	Wheel_Source,
	Pad_Button_Source,
	Pad_Axis_Source,
}

// One line of the table: a signal and what makes it.
Binding :: struct($S: typeid) {
	signal:  S,
	sources: [MAX_SOURCES]Source,
}

on_key :: proc "contextless" (key: Key, mods: Modifiers = {}, exact := false) -> Source {
	return Key_Source{key, mods, exact}
}

on_mouse :: proc "contextless" (button: Mouse_Button) -> Source {
	return Mouse_Source{button}
}

on_wheel :: proc "contextless" (axis: Wheel_Axis, direction: Direction) -> Source {
	return Wheel_Source{axis, direction}
}

on_pad_button :: proc "contextless" (button: Gamepad_Button, pad: u8 = 0) -> Source {
	return Pad_Button_Source{button, pad}
}

on_pad_axis :: proc "contextless" (axis: Gamepad_Axis, direction: Direction, threshold: f32 = DEFAULT_AXIS_THRESHOLD, pad: u8 = 0) -> Source {
	return Pad_Axis_Source{axis, direction, threshold, pad}
}

// A binding of `signal` to these sources (the first MAX_SOURCES count). The type of the signals is named first, since
// Odin cannot tell it from an enum value written as .Name:  input.make_binding(Signal, .Jump, input.on_key(.Space)).
make_binding :: proc "contextless" ($S: typeid, signal: S, sources: ..Source) -> Binding(S) {
	b := Binding(S){signal = signal}
	for s, i in sources {
		if i >= MAX_SOURCES {
			break
		}
		b.sources[i] = s
	}
	return b
}

// ---- the table the program owns ----------------------------------------------------------------------

// Tells the module where the program's bindings are. The module keeps the *pointer*: replace the slice, change an
// element, point it at other storage: the next query uses what is there.
use_bindings :: proc {
	use_bindings_slice,
	use_bindings_dynamic,
}

use_bindings_slice :: proc "contextless" (ctx: ^Context($S), table: ^[]Binding(S)) {
	ctx.bindings = table
	ctx.bindings_dyn = nil
}

use_bindings_dynamic :: proc "contextless" (ctx: ^Context($S), table: ^[dynamic]Binding(S)) {
	ctx.bindings_dyn = table
	ctx.bindings = nil
}

// The table in use (empty if none was given).
bindings :: proc "contextless" (ctx: ^Context($S)) -> []Binding(S) {
	if ctx.bindings != nil {
		return ctx.bindings^
	}
	if ctx.bindings_dyn != nil {
		return ctx.bindings_dyn^[:]
	}
	return nil
}

// Puts `source` in slot `slot` (0 .. MAX_SOURCES-1) of a binding, replacing what was there.
bind_source :: proc "contextless" (b: ^Binding($S), slot: int, source: Source) {
	if slot >= 0 && slot < MAX_SOURCES {
		b.sources[slot] = source
	}
}

// Empties every slot of every binding of `signal`, then gives its first binding this one source. (What a settings screen
// does when the player rebinds an action to one key.) Returns false if the table has no binding of the signal.
rebind :: proc "contextless" (ctx: ^Context($S), signal: S, source: Source) -> bool {
	found := false
	for &b in bindings(ctx) {
		if b.signal != signal {
			continue
		}
		b.sources = {}
		if !found {
			b.sources[0] = source
			found = true
		}
	}
	return found
}

source_equal :: proc "contextless" (a, b: Source) -> bool {
	return a == b
}

// The signal other than `ignore` that already uses `source`, if any (so that a settings screen can warn).
find_conflict :: proc "contextless" (ctx: ^Context($S), source: Source, ignore: S) -> (signal: S, found: bool) {
	for b in bindings(ctx) {
		if b.signal == ignore {
			continue
		}
		for s in b.sources {
			if s != nil && s == source {
				return b.signal, true
			}
		}
	}
	return {}, false
}

// ---- asking about signals ----------------------------------------------------------------------------

// What a signal is doing: the flags of all its sources put together (any source down: .Down; any one pressed in this frame:
// .Pressed; and so on).
signal_flags :: proc "contextless" (ctx: ^Context($S), signal: S) -> State {
	flags: State
	for b in bindings(ctx) {
		if b.signal != signal {
			continue
		}
		for s in b.sources {
			if s == nil {
				continue
			}
			f, _ := source_state(ctx, s)
			flags += f
		}
	}
	return flags
}

// Is the signal down (held)? The one to ask for a "hold" action.
signal_state :: proc "contextless" (ctx: ^Context($S), signal: S) -> bool {
	return .Down in signal_flags(ctx, signal)
}

signal_down :: signal_state

// Did the signal start in this frame (one of its sources was pressed)?
signal_pressed :: proc "contextless" (ctx: ^Context($S), signal: S) -> bool {
	return .Pressed in signal_flags(ctx, signal)
}

signal_released :: proc "contextless" (ctx: ^Context($S), signal: S) -> bool {
	return .Released in signal_flags(ctx, signal)
}

// Pressed, or repeated by the operating system while held (menus, text fields, lists).
signal_repeated :: proc "contextless" (ctx: ^Context($S), signal: S) -> bool {
	return card(signal_flags(ctx, signal) & {.Pressed, .Repeat}) > 0
}

// How strongly the signal is on, 0 .. 1 (more for a wheel that turned several notches): 1 for a button that is down, the
// amount for an axis past its threshold. The largest of its sources.
signal_value :: proc "contextless" (ctx: ^Context($S), signal: S) -> f32 {
	v: f32
	for b in bindings(ctx) {
		if b.signal != signal {
			continue
		}
		for s in b.sources {
			if s == nil {
				continue
			}
			_, x := source_state(ctx, s)
			v = max(v, x)
		}
	}
	return v
}

// A value from -1 to 1 made of two signals (left and right, a stick that is bound on both sides).
signal_axis :: proc "contextless" (ctx: ^Context($S), negative, positive: S) -> f32 {
	return signal_value(ctx, positive) - signal_value(ctx, negative)
}

// What one source is doing, and how strongly. (For code that wants to look at a source by itself, e.g. a
// settings screen's "press a key" box; the signal procedures use it.)
source_state :: proc "contextless" (ctx: ^Context($S), source: Source) -> (flags: State, value: f32) {
	switch s in source {
	case Key_Source:
		f := ctx.keys[s.key]
		if f == {} {
			return {}, 0
		}
		m := modifiers(ctx)
		if s.mods - m != {} || (s.exact && m != s.mods) {
			return {}, 0
		}
		return f, 1 if .Down in f else 0
	case Mouse_Source:
		f := ctx.mouse[s.button]
		return f, 1 if .Down in f else 0
	case Wheel_Source:
		v := ctx.wheel_y if s.axis == .Vertical else ctx.wheel_x
		if s.direction == .Negative {
			v = -v
		}
		if v > 0 {
			return {.Down, .Pressed}, v
		}
		return {}, 0
	case Pad_Button_Source:
		f: State
		for p in 0 ..< MAX_PADS {
			if s.pad == 0 || int(s.pad) == p + 1 {
				f += ctx.pad_buttons[p][s.button]
			}
		}
		return f, 1 if .Down in f else 0
	case Pad_Axis_Source:
		th := s.threshold if s.threshold > 0 else DEFAULT_AXIS_THRESHOLD
		sign := f32(1) if s.direction == .Positive else -1
		f: State
		best: f32
		for p in 0 ..< MAX_PADS {
			if !(s.pad == 0 || int(s.pad) == p + 1) {
				continue
			}
			now := ctx.pad_axes[p][s.axis] * sign
			before := ctx.pad_axes_prev[p][s.axis] * sign
			if now >= th {
				f += {.Down}
				best = max(best, now)
				if before < th {
					f += {.Pressed}
				}
			} else if before >= th {
				f += {.Released}
			}
		}
		return f, min(best, 1)
	}
	return {}, 0
}

// ---- finding out what the player pressed (for a screen that rebinds) ------------------------------------

// The first thing that was pressed in this frame, as a source: a key, a mouse button, a wheel turn, a gamepad button, a
// gamepad axis pushed past its threshold. Keys that are only modifiers (Shift, Ctrl, Alt, Super) are not offered
// unless `modifier_keys` is set; with `chord` the modifiers that are held come with the key (Ctrl+S). Check for the
// key that cancels (Escape) before calling this.
listen :: proc "contextless" (ctx: ^Context($S), chord := false, modifier_keys := false) -> (source: Source, found: bool) {
	for k in Key {
		if k == .None || .Pressed not_in ctx.keys[k] {
			continue
		}
		if !modifier_keys && is_modifier_key(k) {
			continue
		}
		m: Modifiers
		if chord {
			m = modifiers(ctx)
			if mod, ok := modifier_of(k); ok {
				m -= {mod}
			}
		}
		return Key_Source{k, m, false}, true
	}
	for b in Mouse_Button {
		if .Pressed in ctx.mouse[b] {
			return Mouse_Source{b}, true
		}
	}
	if ctx.wheel_y > 0 {
		return Wheel_Source{.Vertical, .Positive}, true
	}
	if ctx.wheel_y < 0 {
		return Wheel_Source{.Vertical, .Negative}, true
	}
	if ctx.wheel_x > 0 {
		return Wheel_Source{.Horizontal, .Positive}, true
	}
	if ctx.wheel_x < 0 {
		return Wheel_Source{.Horizontal, .Negative}, true
	}
	for p in 0 ..< MAX_PADS {
		for b in Gamepad_Button {
			if .Pressed in ctx.pad_buttons[p][b] {
				return Pad_Button_Source{b, 0}, true
			}
		}
		for a in Gamepad_Axis {
			for d in Direction {
				src := Pad_Axis_Source{a, d, DEFAULT_AXIS_THRESHOLD, 0}
				f, _ := source_state(ctx, src)
				if .Pressed in f {
					return src, true
				}
			}
		}
	}
	return nil, false
}

is_modifier_key :: proc "contextless" (k: Key) -> bool {
	_, ok := modifier_of(k)
	return ok
}

modifier_of :: proc "contextless" (k: Key) -> (Modifier, bool) {
	#partial switch k {
	case .Left_Shift, .Right_Shift:
		return .Shift, true
	case .Left_Ctrl, .Right_Ctrl:
		return .Ctrl, true
	case .Left_Alt, .Right_Alt:
		return .Alt, true
	case .Left_Super, .Right_Super:
		return .Super, true
	}
	return {}, false
}

// ---- the names of sources (for a settings screen) -------------------------------------------------------

// The text of a source: "Ctrl+Shift+S", "Left Mouse", "Wheel Up", "LT", "Left Stick X-". Written into `buf` (no
// allocation); what does not fit is cut off. The returned string is a slice of `buf`.
source_text :: proc "contextless" (source: Source, buf: []u8) -> string {
	n := 0
	put :: proc "contextless" (buf: []u8, n: ^int, s: string) {
		for i in 0 ..< len(s) {
			if n^ < len(buf) {
				buf[n^] = s[i]
				n^ += 1
			}
		}
	}
	switch s in source {
	case Key_Source:
		if .Ctrl in s.mods {
			put(buf, &n, "Ctrl+")
		}
		if .Alt in s.mods {
			put(buf, &n, "Alt+")
		}
		if .Shift in s.mods {
			put(buf, &n, "Shift+")
		}
		if .Super in s.mods {
			put(buf, &n, "Super+")
		}
		put(buf, &n, key_name(s.key))
	case Mouse_Source:
		put(buf, &n, mouse_button_name(s.button))
	case Wheel_Source:
		switch {
		case s.axis == .Vertical && s.direction == .Positive:
			put(buf, &n, "Wheel Up")
		case s.axis == .Vertical:
			put(buf, &n, "Wheel Down")
		case s.direction == .Positive:
			put(buf, &n, "Wheel Right")
		case:
			put(buf, &n, "Wheel Left")
		}
	case Pad_Button_Source:
		put(buf, &n, gamepad_button_name(s.button))
	case Pad_Axis_Source:
		put(buf, &n, gamepad_axis_name(s.axis))
		put(buf, &n, "+" if s.direction == .Positive else "-")
	}
	return string(buf[:n])
}
