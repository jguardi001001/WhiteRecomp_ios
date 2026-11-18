package iv_debug

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import ren "../iv_system/ren"
import ui "../iv_ui"

// ---------------------------------------------------------------------------
// The inspector: an editor for any value, made from its type. A program that has a struct of tuning numbers, an item definition or a level's entities
// gets a working data editor in one call; a field that needs a hint carries a `debug` tag:
//
//   Enemy :: struct {
//       name:   string,
//       hp:     int     `debug:"range=0:500"`,
//       speed:  f32     `debug:"range=0:20 speed=0.1"`,
//       tint:   [4]u8,                        // an array of four u8 shows as a color when the tag says so: `debug:"color"`
//       id:     u32     `debug:"readonly"`,
//       cache:  [64]f32 `debug:"hide"`,
//   }
//   iv_debug.inspect(&ctx, "enemy", &enemy)
//
// Tags (words separated by spaces): range=lo:hi, speed=n (the change per px of a drag), readonly, hide, color.
// What it edits: integers and floats (any size up to 64 bits), booleans, enums (a drop-down), strings, bit sets (a check box per bit), fixed arrays,
// slices and dynamic arrays (the elements; a dynamic array can grow and shrink), maps (the values; the keys are shown), structs (a tree), and colors
// ([4]u8 with the `color` tag, and ren.Color) and ui.Rect. Pointers, unions, procedures and the like are shown as text.
// ---------------------------------------------------------------------------

Field_Tag :: struct {
	hide:      bool,
	readonly:  bool,
	color:     bool,
	has_range: bool,
	lo, hi:    f64,
	speed:     f64,
}

parse_tag :: proc(tag: string) -> (t: Field_Tag) {
	spec := reflect.struct_tag_get(reflect.Struct_Tag(tag), "debug")
	for word in strings.fields_iterator(&spec) {
		switch {
		case word == "hide":
			t.hide = true
		case word == "readonly":
			t.readonly = true
		case word == "color":
			t.color = true
		case strings.has_prefix(word, "range="):
			parts := strings.split(word[len("range="):], ":", context.temp_allocator)
			if len(parts) == 2 {
				lo, ok1 := strconv.parse_f64(parts[0])
				hi, ok2 := strconv.parse_f64(parts[1])
				if ok1 && ok2 {
					t.has_range, t.lo, t.hi = true, lo, hi
				}
			}
		case strings.has_prefix(word, "speed="):
			if s, ok := strconv.parse_f64(word[len("speed="):]); ok {
				t.speed = s
			}
		}
	}
	return
}

// Edits the value `v` points to, as a tree of widgets named `name`. Returns true if anything was changed.
inspect :: proc(ctx: ^Context, name: string, v: ^$T) -> bool {
	return inspect_any(ctx, name, any{v, typeid_of(T)}, {}, true)
}

// The same for a value given as an `any` whose data pointer points at the value itself (a field of a struct that is being walked, for example).
inspect_any :: proc(ctx: ^Context, name: string, v: any, tag: Field_Tag, open_first := false) -> (changed: bool) {
	if v.data == nil || v.id == nil {
		return false
	}
	ti := type_info_of(v.id)
	base := runtime.type_info_base(ti)
	if tag.readonly {
		label_value(ctx, name, fmt.tprint(v))
		return false
	}

	// types with a look of their own
	switch v.id {
	case ren.Color:
		return color_edit(ctx, name, (^ren.Color)(v.data))
	case ui.Rect:
		r := (^ui.Rect)(v.data)
		return rect_edit(ctx, name, r)
	}

	#partial switch info in base.variant {
	case runtime.Type_Info_Integer:
		return inspect_integer(ctx, name, v.data, base.size, info.signed, tag)
	case runtime.Type_Info_Float:
		return inspect_float(ctx, name, v.data, base.size, tag)
	case runtime.Type_Info_Boolean:
		on := read_int(v.data, base.size, false) != 0
		if checkbox(ctx, name, &on) {
			write_int(v.data, base.size, 1 if on else 0)
			return true
		}
		return false
	case runtime.Type_Info_Enum:
		return inspect_enum(ctx, name, v, info, base.size)
	case runtime.Type_Info_String:
		if info.is_cstring {
			label_value(ctx, name, fmt.tprint(v))
			return false
		}
		return input_string(ctx, name, (^string)(v.data))
	case runtime.Type_Info_Bit_Set:
		return inspect_bit_set(ctx, name, v.data, base.size, info)
	case runtime.Type_Info_Array:
		return inspect_array(ctx, name, v.data, info, tag, open_first)
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(v.data)
		return inspect_elements(ctx, name, raw.data, raw.len, info.elem, info.elem_size, false, nil, open_first)
	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(v.data)
		return inspect_elements(ctx, name, raw.data, raw.len, info.elem, info.elem_size, true, raw, open_first, info.elem.align)
	case runtime.Type_Info_Struct:
		return inspect_struct(ctx, name, v.data, info, open_first)
	case runtime.Type_Info_Map:
		return inspect_map(ctx, name, v, open_first)
	}
	label_value(ctx, name, fmt.tprint(v))
	return false
}

// ---- numbers -----------------------------------------------------------------------------------------------------------------------

@(private)
read_int :: proc(data: rawptr, size: int, signed: bool) -> i64 {
	switch size {
	case 1:
		return i64((^i8)(data)^) if signed else i64((^u8)(data)^)
	case 2:
		return i64((^i16)(data)^) if signed else i64((^u16)(data)^)
	case 4:
		return i64((^i32)(data)^) if signed else i64((^u32)(data)^)
	case 8:
		return (^i64)(data)^
	}
	return 0
}

@(private)
write_int :: proc(data: rawptr, size: int, v: i64) {
	switch size {
	case 1:
		(^u8)(data)^ = u8(v)
	case 2:
		(^u16)(data)^ = u16(v)
	case 4:
		(^u32)(data)^ = u32(v)
	case 8:
		(^u64)(data)^ = u64(v)
	}
}

@(private)
int_range :: proc(size: int, signed: bool) -> (lo, hi: f64) {
	switch size {
	case 1:
		if signed {
			return -128, 127
		}
		return 0, 255
	case 2:
		if signed {
			return -32768, 32767
		}
		return 0, 65535
	case 4:
		if signed {
			return -2147483648, 2147483647
		}
		return 0, 4294967295
	}
	if signed {
		return -9.223372036854775808e18, 9.223372036854775807e18
	}
	return 0, 1.8446744073709551615e19
}

@(private)
inspect_integer :: proc(ctx: ^Context, name: string, data: rawptr, size: int, signed: bool, tag: Field_Tag) -> bool {
	if size > 8 {
		label_value(ctx, name, "(integer too wide)")
		return false
	}
	id := make_id(ctx, name)
	r := property(ctx, name, id)
	lo, hi := int_range(size, signed)
	if tag.has_range {
		lo, hi = max(lo, tag.lo), min(hi, tag.hi)
	}
	f: f64
	if size == 8 && !signed {
		f = f64((^u64)(data)^)
	} else {
		f = f64(read_int(data, size, signed))
	}
	if drag_scalar(ctx, id, r, &f, tag.speed if tag.speed != 0 else 0.25, lo, hi, true) {
		write_int(data, size, i64(f))
		return true
	}
	return false
}

@(private)
inspect_float :: proc(ctx: ^Context, name: string, data: rawptr, size: int, tag: Field_Tag) -> bool {
	if size != 4 && size != 8 {
		label_value(ctx, name, "(half or wide float)")
		return false
	}
	id := make_id(ctx, name)
	r := property(ctx, name, id)
	lo, hi: f64 = -1e300, 1e300
	if tag.has_range {
		lo, hi = tag.lo, tag.hi
	}
	f := f64((^f32)(data)^) if size == 4 else (^f64)(data)^
	if drag_scalar(ctx, id, r, &f, tag.speed if tag.speed != 0 else 0.05, lo, hi, false) {
		if size == 4 {
			(^f32)(data)^ = f32(f)
		} else {
			(^f64)(data)^ = f
		}
		return true
	}
	return false
}

// Four whole numbers in a row: x, y, width, height.
rect_edit :: proc(ctx: ^Context, label: string, r: ^ui.Rect) -> (changed: bool) {
	id := make_id(ctx, label)
	field := property(ctx, label, id)
	push_id(ctx, label)
	defer pop_id(ctx)
	parts := [4]^int{&r.x, &r.y, &r.w, &r.h}
	for i in 0 ..< 4 {
		push_id_int(ctx, i)
		if drag_in(ctx, make_id(ctx, "r"), ui.columns(field, i, 4, 2), parts[i], 0.5) {
			changed = true
		}
		pop_id(ctx)
	}
	return
}

// ---- enums and bit sets ----------------------------------------------------------------------------------------------------------------

enum_names_of :: proc(id: typeid) -> []string {
	return reflect.enum_field_names(id)
}

enum_values_of :: proc(id: typeid) -> []i64 {
	vals := reflect.enum_field_values(id)
	out := make([]i64, len(vals), context.temp_allocator)
	for v, i in vals {
		out[i] = i64(v)
	}
	return out
}

@(private)
inspect_enum :: proc(ctx: ^Context, name: string, v: any, info: runtime.Type_Info_Enum, size: int) -> bool {
	signed := true
	if bi, ok := runtime.type_info_base(info.base).variant.(runtime.Type_Info_Integer); ok {
		signed = bi.signed
	}
	current := read_int(v.data, size, signed)
	index := -1
	for val, i in info.values {
		if i64(val) == current {
			index = i
			break
		}
	}
	if index < 0 { // a value that has no name: shown as its number, with the names to choose from
		names := make([]string, len(info.names) + 1, context.temp_allocator)
		copy(names, info.names)
		names[len(info.names)] = fmt.tprintf("(%d)", current)
		idx := len(info.names)
		if dropdown(ctx, name, names, &idx) && idx < len(info.names) {
			write_int(v.data, size, i64(info.values[idx]))
			return true
		}
		return false
	}
	if dropdown(ctx, name, info.names, &index) {
		write_int(v.data, size, i64(info.values[index]))
		return true
	}
	return false
}

@(private)
inspect_bit_set :: proc(ctx: ^Context, name: string, data: rawptr, size: int, info: runtime.Type_Info_Bit_Set) -> (changed: bool) {
	bits: u64
	switch size {
	case 1:
		bits = u64((^u8)(data)^)
	case 2:
		bits = u64((^u16)(data)^)
	case 4:
		bits = u64((^u32)(data)^)
	case 8:
		bits = (^u64)(data)^
	}
	if !tree_node(ctx, name, false) {
		return false
	}
	defer tree_pop(ctx)
	count := int(info.upper - info.lower) + 1
	names: []string
	values: []i64
	if info.elem != nil {
		if _, is_enum := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Enum); is_enum {
			names = enum_names_of(info.elem.id)
			values = enum_values_of(info.elem.id)
		}
	}
	n := len(names) if names != nil else count
	for i in 0 ..< n {
		bit_value := values[i] if values != nil else info.lower + i64(i)
		bit := uint(bit_value - info.lower)
		if bit >= 64 {
			continue
		}
		on := bits & (u64(1) << bit) != 0
		label_text := names[i] if names != nil else fmt.tprintf("%d", bit_value)
		if checkbox(ctx, label_text, &on) {
			if on {
				bits |= u64(1) << bit
			} else {
				bits &~= u64(1) << bit
			}
			changed = true
		}
	}
	if changed {
		switch size {
		case 1:
			(^u8)(data)^ = u8(bits)
		case 2:
			(^u16)(data)^ = u16(bits)
		case 4:
			(^u32)(data)^ = u32(bits)
		case 8:
			(^u64)(data)^ = bits
		}
	}
	return
}

// ---- aggregates -------------------------------------------------------------------------------------------------------------------------

@(private)
is_number_type :: proc(ti: ^runtime.Type_Info) -> (is_float: bool, ok: bool) {
	b := runtime.type_info_base(ti)
	#partial switch info in b.variant {
	case runtime.Type_Info_Float:
		return true, b.size == 4
	case runtime.Type_Info_Integer:
		return false, false
	}
	return false, false
}

@(private)
inspect_array :: proc(ctx: ^Context, name: string, data: rawptr, info: runtime.Type_Info_Array, tag: Field_Tag, open_first: bool) -> (changed: bool) {
	// a few f32: one row of number fields
	if is_f32, ok := is_number_type(info.elem); ok && is_f32 && info.count <= 4 {
		return drag_vec(ctx, name, ([^]f32)(data)[:info.count], tag.speed if tag.speed != 0 else 0.05, tag.lo if tag.has_range else -1e300, tag.hi if tag.has_range else 1e300)
	}
	// four bytes marked as a color
	if tag.color && info.count == 4 && info.elem.size == 1 {
		return color_edit(ctx, name, (^ren.Color)(data))
	}
	return inspect_elements(ctx, name, data, info.count, info.elem, info.elem_size, false, nil, open_first)
}

@(private)
inspect_elements :: proc(
	ctx: ^Context,
	name: string,
	data: rawptr,
	count: int,
	elem: ^runtime.Type_Info,
	elem_size: int,
	growable: bool,
	raw: ^runtime.Raw_Dynamic_Array,
	open_first: bool,
	elem_align := 0,
) -> (
	changed: bool,
) {
	title := fmt.tprintf("%s [%d]###%s", name, count, name)
	if open_first && !tree_known(ctx, title) {
		set_tree_open(ctx, title, true)
	}
	if !tree_node(ctx, title) {
		return false
	}
	defer tree_pop(ctx)
	for i in 0 ..< count {
		ptr := rawptr(uintptr(data) + uintptr(i * elem_size))
		push_id_int(ctx, i)
		if inspect_any(ctx, fmt.tprintf("[%d]", i), any{ptr, elem.id}, {}) {
			changed = true
		}
		pop_id(ctx)
	}
	if growable && raw != nil {
		row(ctx, 2)
		if button(ctx, "+ add") {
			dynamic_append_zero(raw, elem_size, elem_align)
			changed = true
		}
		if button(ctx, "- remove last") && raw.len > 0 {
			raw.len -= 1
			changed = true
		}
	}
	return
}

@(private)
tree_known :: proc(ctx: ^Context, label: string) -> bool {
	_, ok := ctx.opens[make_id(ctx, label)]
	return ok
}

// Grows a dynamic array by one element of zeros.
@(private)
dynamic_append_zero :: proc(raw: ^runtime.Raw_Dynamic_Array, elem_size, elem_align: int) {
	if raw.len >= raw.cap {
		newcap := max(raw.cap * 2, 4)
		runtime.__dynamic_array_reserve(raw, elem_size, max(elem_align, 1), newcap)
	}
	if raw.len < raw.cap {
		runtime.mem_zero(rawptr(uintptr(raw.data) + uintptr(raw.len * elem_size)), elem_size)
		raw.len += 1
	}
}

@(private)
inspect_struct :: proc(ctx: ^Context, name: string, data: rawptr, info: runtime.Type_Info_Struct, open_first: bool) -> (changed: bool) {
	if open_first && !tree_known(ctx, name) {
		set_tree_open(ctx, name, true)
	}
	if !tree_node(ctx, name) {
		return false
	}
	defer tree_pop(ctx)
	for i in 0 ..< int(info.field_count) {
		tag := parse_tag(info.tags[i])
		if tag.hide {
			continue
		}
		ptr := rawptr(uintptr(data) + info.offsets[i])
		if inspect_any(ctx, info.names[i], any{ptr, info.types[i].id}, tag) {
			changed = true
		}
	}
	return
}

@(private)
inspect_map :: proc(ctx: ^Context, name: string, v: any, open_first: bool) -> (changed: bool) {
	n := reflect.length(v)
	title := fmt.tprintf("%s {{%d}}###%s", name, n, name)
	if open_first && !tree_known(ctx, title) {
		set_tree_open(ctx, title, true)
	}
	if !tree_node(ctx, title) {
		return false
	}
	defer tree_pop(ctx)
	it := 0
	for key, value in reflect.iterate_map(v, &it) {
		key_text := fmt.tprint(key)
		push_id(ctx, key_text)
		if inspect_any(ctx, key_text, value, {}) {
			changed = true
		}
		pop_id(ctx)
	}
	return
}
