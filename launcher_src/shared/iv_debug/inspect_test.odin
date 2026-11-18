package iv_debug

import "core:testing"
import ren "../iv_system/ren"
import ui "../iv_ui"

Kind :: enum {
	Small,
	Medium,
	Large,
}

Flag :: enum {
	A,
	B,
	C,
}

Inner :: struct {
	x: int,
	y: f32,
}

Thing :: struct {
	count:  int `debug:"range=0:10"`,
	ratio:  f32,
	on:     bool,
	name:   string,
	kind:   Kind,
	flags:  bit_set[Flag],
	pos:    [2]f32,
	tint:   ren.Color,
	inner:  Inner,
	list:   [dynamic]int,
	secret: int `debug:"hide"`,
	locked: int `debug:"readonly"`,
	scores: map[string]int,
	small:  i8,
	big:    u64,
}

@(private = "file")
thing_rig :: proc(rig: ^Rig, thing: ^Thing) {
	rig_open(rig)
	rig.flags = {.Auto_Height}
	rig.user = thing
	rig.body = proc(rig: ^Rig) {
		if inspect(&rig.ctx, "thing", (^Thing)(rig.user)) {
			rig.changed = true
		}
	}
	settle(rig)
	frame(rig, {})
}

@(private = "file")
cell :: proc(rig: ^Rig, id: ID, i, n: int) -> [2]f32 {
	r := rig.ctx.rects[id]
	c := ui.columns(r, i, n, 2)
	return {f32(c.x + c.w / 2), f32(c.y + c.h / 2)}
}

@(private = "file")
drag_by :: proc(rig: ^Rig, from: [2]f32, dx: f32) {
	move_to(rig, from)
	press(rig)
	hold(rig, {from.x + dx, from.y})
	release(rig)
}

@(test)
tags_hide_and_protect_fields_and_ranges_limit_them :: proc(t: ^testing.T) {
	thing := Thing {
		secret = 7,
		locked = 8,
	}
	rig: Rig
	thing_rig(&rig, &thing)
	defer rig_close(&rig)

	_, has_secret := rig.ctx.rects[id_in("T", "thing", "secret")]
	_, has_locked := rig.ctx.rects[id_in("T", "thing", "locked")]
	_, has_count := rig.ctx.rects[id_in("T", "thing", "count")]
	testing.expect(t, !has_secret, "hide: not shown")
	testing.expect(t, !has_locked, "readonly: shown as text, no widget")
	testing.expect(t, has_count)

	drag_by(&rig, at(&rig, "T", "thing", "count"), 400) // 400 px at 0.25: 100, but the tag says 0 to 10
	testing.expect_value(t, thing.count, 10)
	testing.expect(t, rig.changed)
	testing.expect_value(t, thing.secret, 7)
	testing.expect_value(t, thing.locked, 8)
}

@(test)
numbers_booleans_strings_and_enums_are_edited_in_place :: proc(t: ^testing.T) {
	thing := Thing {
		name = "old",
	}
	rig: Rig
	thing_rig(&rig, &thing)
	defer rig_close(&rig)
	defer if thing.name != "old" {
		delete(thing.name)
	}

	// a float
	drag_by(&rig, at(&rig, "T", "thing", "ratio"), 20)
	testing.expectf(t, abs(thing.ratio - 1) < 0.001, "ratio %v", thing.ratio)

	// a bool
	click(&rig, at(&rig, "T", "thing", "on"))
	testing.expect(t, thing.on)

	// a string
	p := at(&rig, "T", "thing", "name")
	click(&rig, p)
	press_key(&rig, .End)
	type_text(&rig, "er")
	press_key(&rig, .Enter)
	testing.expect_value(t, thing.name, "older")

	// an enum, from its drop-down
	click(&rig, at(&rig, "T", "thing", "kind"))
	popup := rig.ctx.popup_rect
	rh := row_h(&rig.ctx)
	move_to(&rig, {f32(popup.x + 10), f32(popup.y + 1 + 2 * rh + rh / 2)})
	press(&rig)
	release(&rig)
	testing.expect_value(t, thing.kind, Kind.Large)

	// narrow integers keep to their type; unsigned ones do not go below 0
	drag_by(&rig, at(&rig, "T", "thing", "small"), 5000)
	testing.expect_value(t, thing.small, 127)
	drag_by(&rig, at(&rig, "T", "thing", "big"), -5000)
	testing.expect_value(t, thing.big, 0)
	drag_by(&rig, at(&rig, "T", "thing", "big"), 400)
	testing.expect_value(t, thing.big, 100)
}

@(test)
vectors_colors_and_rows_of_parts :: proc(t: ^testing.T) {
	thing := Thing {
		tint = {10, 20, 30, 255},
	}
	rig: Rig
	thing_rig(&rig, &thing)
	defer rig_close(&rig)

	// the second part of a [2]f32
	drag_by(&rig, cell(&rig, id_in("T", "thing", "pos"), 1, 2), 40)
	testing.expect_value(t, thing.pos[0], 0)
	testing.expectf(t, abs(thing.pos[1] - 2) < 0.001, "pos %v", thing.pos)

	// the green part of a color: 20 px at 0.5 a px
	r := rig.ctx.rects[id_in("T", "thing", "tint")]
	_, rest := ui.cut_left(r, r.h + 4, 2)
	c := ui.columns(rest, 1, 4, 2)
	drag_by(&rig, {f32(c.x + c.w / 2), f32(c.y + c.h / 2)}, 20)
	testing.expect_value(t, thing.tint, ren.Color{10, 30, 30, 255})
	drag_by(&rig, {f32(c.x + c.w / 2), f32(c.y + c.h / 2)}, 4000) // stays a byte
	testing.expect_value(t, thing.tint[1], 255)
}

@(test)
structs_bit_sets_lists_and_maps_open_as_trees :: proc(t: ^testing.T) {
	thing := Thing{}
	rig: Rig
	thing_rig(&rig, &thing)
	defer rig_close(&rig)
	defer delete(thing.list)

	// a nested struct is closed until it is opened
	_, has_x := rig.ctx.rects[id_in("T", "thing", "inner", "x")]
	testing.expect(t, !has_x)
	click(&rig, at(&rig, "T", "thing", "inner"))
	drag_by(&rig, at(&rig, "T", "thing", "inner", "x"), 40)
	testing.expect_value(t, thing.inner.x, 10)

	// a bit set: a check box for each of its values
	click(&rig, at(&rig, "T", "thing", "flags"))
	click(&rig, at(&rig, "T", "thing", "flags", "B"))
	testing.expect_value(t, thing.flags, bit_set[Flag]{.B})
	click(&rig, at(&rig, "T", "thing", "flags", "A"))
	testing.expect_value(t, thing.flags, bit_set[Flag]{.A, .B})
	click(&rig, at(&rig, "T", "thing", "flags", "B"))
	testing.expect_value(t, thing.flags, bit_set[Flag]{.A})

	// a dynamic array grows and shrinks
	click(&rig, at(&rig, "T", "thing", "list [0]###list"))
	click(&rig, at(&rig, "T", "thing", "###list", "+ add"))
	click(&rig, at(&rig, "T", "thing", "###list", "+ add"))
	click(&rig, at(&rig, "T", "thing", "###list", "+ add"))
	testing.expect_value(t, len(thing.list), 3)
	testing.expect_value(t, thing.list[2], 0)
	click(&rig, at(&rig, "T", "thing", "###list", "- remove last"))
	testing.expect_value(t, len(thing.list), 2)
}

@(test)
map_values_can_be_changed_in_place :: proc(t: ^testing.T) {
	thing := Thing{}
	thing.scores = make(map[string]int)
	thing.scores["a"] = 5
	thing.scores["b"] = 7
	rig: Rig
	thing_rig(&rig, &thing)
	defer rig_close(&rig)
	defer delete(thing.scores)

	click(&rig, at(&rig, "T", "thing", "###scores"))
	drag_by(&rig, at(&rig, "T", "thing", "###scores", "a", "a"), 20)
	testing.expect_value(t, thing.scores["a"], 10)
	testing.expect_value(t, thing.scores["b"], 7)
}
