package iv_debug

import "core:testing"

@(test)
a_text_area_takes_lines_and_moves_between_them :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.str = "one"
	rig.body = proc(rig: ^Rig) {
		if input_multiline(&rig.ctx, "text", &rig.str, 4) {
			rig.changed = true
		}
	}
	defer if rig.str != "one" {
		delete(rig.str)
	}
	settle(&rig)
	r := rig.ctx.rects[id_in("T", "text")]
	click(&rig, {f32(r.x + r.w - 20), f32(r.y + 6)})
	testing.expect(t, wants_keyboard(&rig.ctx))
	press_key(&rig, .End)
	press_key(&rig, .Enter) // a new line, the edit goes on
	testing.expect(t, wants_keyboard(&rig.ctx))
	type_text(&rig, "two")
	testing.expect_value(t, rig.str, "one\ntwo")
	press_key(&rig, .Up) // to the first line, at the same x
	press_key(&rig, .End)
	type_text(&rig, "!")
	testing.expect_value(t, rig.str, "one!\ntwo")
	press_key(&rig, .Down)
	press_key(&rig, .Home)
	type_text(&rig, ">")
	testing.expect_value(t, rig.str, "one!\n>two")
	press_key(&rig, .Enter, ctrl = true) // Ctrl+Enter ends it
	testing.expect(t, !wants_keyboard(&rig.ctx))
	testing.expect_value(t, rig.str, "one!\n>two")
}

@(test)
a_dropdown_can_be_filtered_by_typing :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.index = -1
	rig.body = proc(rig: ^Rig) {
		items := [?]string{"Iron plate", "Copper wire", "Regolith", "Iron ore"}
		if dropdown_ex(&rig.ctx, "pick", items[:], &rig.index, {filter = true, placeholder = "none"}) {
			rig.changed = true
		}
	}
	settle(&rig)
	click(&rig, at(&rig, "T", "pick"))
	testing.expect_value(t, rig.ctx.modal, id_in("T", "pick"))
	type_text(&rig, "ore")
	popup := rig.ctx.popup_rect
	frame(&rig, {})
	rh := row_h(&rig.ctx)
	testing.expect(t, rig.ctx.popup_rect.h < popup.h + 1)
	// only "Iron ore" matches "ore": its row is the first under the search field
	p := rig.ctx.popup_rect
	move_to(&rig, {f32(p.x + 20), f32(p.y + 1 + (rh + 4) + rh / 2)})
	press(&rig)
	release(&rig)
	testing.expect_value(t, rig.index, 3)
	testing.expect_value(t, rig.ctx.modal, 0)

	// Enter takes the first match
	rig.index = -1
	click(&rig, at(&rig, "T", "pick"))
	type_text(&rig, "wire")
	press_key(&rig, .Enter)
	testing.expect_value(t, rig.index, 1)
	testing.expect(t, !wants_keyboard(&rig.ctx))
}

@(test)
tabs_chips_and_list_views :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.body = proc(rig: ^Rig) {
		names := [?]string{"General", "Sources", "Recipe"}
		tab_bar(&rig.ctx, names[:], &rig.index)
		bits := u64(rig.count)
		chip_names := [?]string{"solid", "liquid", "ore", "metal"}
		if chips(&rig.ctx, chip_names[:], &bits) {
			rig.count = int(bits)
		}
		items := [?]string{"a", "b", "c", "d", "e", "f", "g", "h"}
		sel := rig.clicked
		if list_view(&rig.ctx, "things", len(items), &sel, 3, {items = items[:]}) {
			rig.clicked = sel
		}
	}
	settle(&rig)
	click(&rig, at(&rig, "T", 1, "tab")) // the second tab
	testing.expect_value(t, rig.index, 1)
	click(&rig, at(&rig, "T", 2, "tab"))
	testing.expect_value(t, rig.index, 2)
	click(&rig, at(&rig, "T", 0, "tab"))
	testing.expect_value(t, rig.index, 0)

	click(&rig, at(&rig, "T", 1, "chip"))
	click(&rig, at(&rig, "T", 3, "chip"))
	testing.expect_value(t, rig.count, 0b1010)
	click(&rig, at(&rig, "T", 1, "chip"))
	testing.expect_value(t, rig.count, 0b1000)

	// a list shows 3 of 8 rows; the wheel scrolls it; a click selects the row it hits
	list := rig.ctx.rects[id_in("T", "things")]
	rig.mouse = {f32(list.x + 20), f32(list.y + 8)}
	frame(&rig, {wheel = -1})
	rh := row_h(&rig.ctx)
	click(&rig, {f32(list.x + 20), f32(list.y + 1 + rh / 2)}) // the first row that shows
	testing.expect_value(t, rig.clicked, 2) // the wheel moved two rows
}
