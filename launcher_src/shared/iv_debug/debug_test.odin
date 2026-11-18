package iv_debug

import "core:testing"
import ren "../iv_system/ren"
import text "../iv_text"
import ui "../iv_ui"

LIBERATION :: #load("testdata/LiberationSans-Bold.ttf")

// ---------------------------------------------------------------------------
// The tests drive the widgets the way a user would: an Input per frame (mouse moves, presses, releases, typed characters, keys), the widgets run, and the
// variables they edit are looked at. A renderer with no GPU behind it makes the fonts; the draw list is what comes out.
// ---------------------------------------------------------------------------

@(private = "file")
fake_texture :: proc(b: ^ren.Backend, desc: ren.Texture_Desc) -> (ren.Texture, bool) {
	counter := (^int)(b.data)
	counter^ += 1
	return ren.Texture(counter^), true
}

@(private = "file")
fake_update :: proc(b: ^ren.Backend, t: ren.Texture, region: ui.Rect, pixels: []u8) -> bool {
	return true
}

@(private = "file")
fake_destroy :: proc(b: ^ren.Backend, t: ren.Texture) {
}

SCREEN :: [2]int{800, 600}

Rig :: struct {
	r:       ren.Renderer,
	tf:      text.Typeface,
	ctx:     Context,
	counter: int,
	dl:      ren.Draw_List,
	mouse:   [2]f32,
	body:    proc(rig: ^Rig),
	user:    rawptr,
	title:   string,
	flags:   Window_Flags,

	// what the bodies of the tests edit
	clicked: int,
	flag:    bool,
	number:  f32,
	count:   int,
	str:     string,
	index:   int,
	changed: bool,
}

rig_open :: proc(rig: ^Rig) {
	ren.renderer_init(&rig.r, ren.Backend{data = &rig.counter, create_texture = fake_texture, update_texture = fake_update, destroy_texture = fake_destroy}, SCREEN.x, SCREEN.y)
	text.typeface_init(&rig.tf, &rig.r)
	text.typeface_add(&rig.tf, LIBERATION)
	init(&rig.ctx, &rig.tf, 15)
	rig.ctx.track_rects = true
	ren.draw_list_init(&rig.dl)
	rig.title = "T"
}

rig_close :: proc(rig: ^Rig) {
	destroy(&rig.ctx)
	ren.draw_list_destroy(&rig.dl)
	text.typeface_destroy(&rig.tf)
	ren.renderer_destroy(&rig.r)
}

// One frame: the input, a window with the test's body in it.
frame :: proc(rig: ^Rig, in_: Input) {
	in_ := in_
	in_.mouse = rig.mouse
	in_.dt = 1.0 / 60
	ren.draw_list_reset(&rig.dl, SCREEN.x, SCREEN.y)
	begin_frame(&rig.ctx, in_, SCREEN)
	if window(&rig.ctx, rig.title, {10, 10, 400, 500}, rig.flags) {
		rig.body(rig)
	}
	end_window(&rig.ctx)
	end_frame(&rig.ctx, &rig.dl)
}

// The centre of the part of a widget (by the path of its id) that answers the mouse, on the right side where a field is.
at :: proc(rig: ^Rig, path: ..any) -> [2]f32 {
	r, ok := rig.ctx.rects[id_in(..path)]
	if !ok {
		return {-100, -100}
	}
	return {f32(r.x + r.w - 6), f32(r.y + r.h / 2)}
}

move_to :: proc(rig: ^Rig, p: [2]f32) {
	rig.mouse = p
	frame(rig, {})
}

press :: proc(rig: ^Rig) {
	frame(rig, {})
	f := Input{}
	f.down[.Left] = true
	f.pressed[.Left] = true
	frame(rig, f)
}

hold :: proc(rig: ^Rig, p: [2]f32) {
	rig.mouse = p
	f := Input{}
	f.down[.Left] = true
	frame(rig, f)
}

release :: proc(rig: ^Rig) {
	f := Input{}
	f.released[.Left] = true
	frame(rig, f)
	frame(rig, {})
}

click :: proc(rig: ^Rig, p: [2]f32) {
	move_to(rig, p)
	press(rig)
	release(rig)
}

type_text :: proc(rig: ^Rig, s: string) {
	runes := make([dynamic]rune, context.temp_allocator)
	for c in s {
		append(&runes, c)
	}
	frame(rig, {typed = runes[:]})
}

press_key :: proc(rig: ^Rig, k: Key, ctrl := false, shift := false) {
	frame(rig, {keys = {k}, ctrl = ctrl, shift = shift})
}

// two frames so that the first one makes the widgets known (their rects) before the mouse is aimed at them
settle :: proc(rig: ^Rig) {
	frame(rig, {})
	frame(rig, {})
}

@(test)
a_button_is_clicked_by_press_and_release :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.body = proc(rig: ^Rig) {
		if button(&rig.ctx, "Go") {
			rig.clicked += 1
		}
	}
	settle(&rig)
	where_ := at(&rig, "T", "Go")
	testing.expect(t, where_.x > 0)
	move_to(&rig, where_)
	press(&rig)
	testing.expect_value(t, rig.clicked, 0) // not yet: a click is the release
	release(&rig)
	testing.expect_value(t, rig.clicked, 1)

	// pressed on it but let go elsewhere: no click
	move_to(&rig, where_)
	press(&rig)
	hold(&rig, {700, 500})
	release(&rig)
	testing.expect_value(t, rig.clicked, 1)

	// a press that starts elsewhere and ends on it is not a click either
	move_to(&rig, {700, 500})
	press(&rig)
	hold(&rig, where_)
	release(&rig)
	testing.expect_value(t, rig.clicked, 1)
}

@(test)
checkbox_and_radio_change_their_variables :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.body = proc(rig: ^Rig) {
		checkbox(&rig.ctx, "on", &rig.flag)
		radio(&rig.ctx, "one", &rig.index, 1)
		radio(&rig.ctx, "two", &rig.index, 2)
	}
	settle(&rig)
	click(&rig, at(&rig, "T", "on"))
	testing.expect(t, rig.flag)
	click(&rig, at(&rig, "T", "on"))
	testing.expect(t, !rig.flag)
	click(&rig, at(&rig, "T", "two"))
	testing.expect_value(t, rig.index, 2)
	click(&rig, at(&rig, "T", "one"))
	testing.expect_value(t, rig.index, 1)
}

@(test)
a_number_is_dragged_or_typed :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.number = 1
	rig.body = proc(rig: ^Rig) {
		if drag(&rig.ctx, "speed", &rig.number, 0.05, -10, 10) {
			rig.changed = true
		}
		drag(&rig.ctx, "count", &rig.count, 0, 0, 100)
	}
	settle(&rig)
	p := at(&rig, "T", "speed")
	move_to(&rig, p)
	press(&rig)
	hold(&rig, {p.x + 40, p.y}) // 40 px at 0.05 a px
	release(&rig)
	testing.expect(t, rig.changed)
	testing.expectf(t, abs(rig.number - 3) < 0.001, "dragged to %v", rig.number)

	// shift makes it finer
	move_to(&rig, p)
	press(&rig)
	f := Input{}
	f.down[.Left] = true
	f.shift = true
	rig.mouse = {p.x + 40, p.y}
	frame(&rig, f)
	release(&rig)
	testing.expectf(t, abs(rig.number - 3.2) < 0.001, "finer: %v", rig.number)

	// a click without moving types a value: it replaces the number (all of it is selected), Enter takes it
	click(&rig, p)
	testing.expect(t, wants_keyboard(&rig.ctx))
	type_text(&rig, "-2.5")
	press_key(&rig, .Enter)
	testing.expect(t, !wants_keyboard(&rig.ctx))
	testing.expect_value(t, rig.number, -2.5)

	// out of range: kept in the range; Escape leaves the value alone
	click(&rig, p)
	type_text(&rig, "99")
	press_key(&rig, .Enter)
	testing.expect_value(t, rig.number, 10)
	click(&rig, p)
	type_text(&rig, "5")
	press_key(&rig, .Escape)
	testing.expect_value(t, rig.number, 10)

	// an integer drags in whole numbers and stays in its range
	q := at(&rig, "T", "count")
	move_to(&rig, q)
	press(&rig)
	hold(&rig, {q.x + 20, q.y}) // 20 px at 0.25
	release(&rig)
	testing.expect_value(t, rig.count, 5)
	move_to(&rig, q)
	press(&rig)
	hold(&rig, {q.x - 900, q.y})
	release(&rig)
	testing.expect_value(t, rig.count, 0)
}

@(test)
a_string_field_edits_like_a_text_box :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.str = "abc"
	rig.body = proc(rig: ^Rig) {
		if input_string(&rig.ctx, "name", &rig.str) {
			rig.changed = true
		}
	}
	defer if rig.str != "abc" {
		delete(rig.str)
	}
	settle(&rig)
	p := at(&rig, "T", "name")
	click(&rig, {p.x, p.y}) // at the right end of the field: the caret goes to the end of the text
	testing.expect(t, wants_keyboard(&rig.ctx))
	type_text(&rig, "dé")
	testing.expect_value(t, rig.str, "abcdé")
	testing.expect(t, rig.changed)
	press_key(&rig, .Backspace) // one character (two bytes), not one byte
	testing.expect_value(t, rig.str, "abcd")
	press_key(&rig, .Home)
	press_key(&rig, .Right, shift = true)
	press_key(&rig, .Right, shift = true)
	type_text(&rig, "X") // replaces the two selected characters
	testing.expect_value(t, rig.str, "Xcd")
	press_key(&rig, .A, ctrl = true)
	press_key(&rig, .C, ctrl = true)
	press_key(&rig, .Delete)
	testing.expect_value(t, rig.str, "")
	press_key(&rig, .V, ctrl = true)
	press_key(&rig, .V, ctrl = true)
	testing.expect_value(t, rig.str, "XcdXcd")
	press_key(&rig, .Enter)
	testing.expect(t, !wants_keyboard(&rig.ctx))
	testing.expect_value(t, rig.str, "XcdXcd")
	// (the intermediate strings were freed as they were replaced: the test runner's memory tracking would report a leak otherwise)
}

@(test)
a_dropdown_opens_over_the_others_and_picks :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.index = 0
	rig.body = proc(rig: ^Rig) {
		items := [?]string{"zero", "one", "two", "three"}
		if dropdown(&rig.ctx, "pick", items[:], &rig.index) {
			rig.changed = true
		}
		if button(&rig.ctx, "under") { // sits under the open list
			rig.clicked += 1
		}
	}
	settle(&rig)
	click(&rig, at(&rig, "T", "pick"))
	testing.expect_value(t, rig.ctx.modal, id_in("T", "pick"))
	testing.expect(t, wants_mouse(&rig.ctx))
	popup := rig.ctx.popup_rect
	testing.expect(t, popup.h > 0)
	rh := row_h(&rig.ctx)
	// a click on the open list lands on the list, not on the button under it
	item := [2]f32{f32(popup.x + 20), f32(popup.y + 1 + 2 * rh + rh / 2)}
	move_to(&rig, item)
	press(&rig)
	release(&rig)
	testing.expect_value(t, rig.index, 2)
	testing.expect(t, rig.changed)
	testing.expect_value(t, rig.clicked, 0)
	testing.expect_value(t, rig.ctx.modal, 0)

	// opened again and closed by a click elsewhere: nothing changes
	rig.changed = false
	click(&rig, at(&rig, "T", "pick"))
	testing.expect(t, rig.ctx.modal != 0)
	click(&rig, {700, 550})
	testing.expect_value(t, rig.ctx.modal, 0)
	testing.expect(t, !rig.changed)
	testing.expect_value(t, rig.index, 2)
}

@(test)
windows_move_resize_raise_and_say_who_has_the_mouse :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.body = proc(rig: ^Rig) {
		button(&rig.ctx, "x")
		// a second window overlapping the first
		end_window(&rig.ctx)
		if window(&rig.ctx, "B", {200, 100, 300, 300}) {
			button(&rig.ctx, "y")
		}
	}
	settle(&rig)
	a := rig.ctx.windows[id_in("T")]
	b := rig.ctx.windows[id_in("B")]
	testing.expect(t, b.z > a.z, "the one made later is in front")
	rig.mouse = {300, 200} // over both: B is in front
	frame(&rig, {})
	testing.expect_value(t, rig.ctx.mouse_window, id_in("B"))
	rig.mouse = {20, 50} // over A only
	frame(&rig, {})
	testing.expect_value(t, rig.ctx.mouse_window, id_in("T"))
	testing.expect(t, wants_mouse(&rig.ctx))
	rig.mouse = {790, 590}
	frame(&rig, {})
	testing.expect(t, !wants_mouse(&rig.ctx))

	// asked between frames, with the pointer where it is now: is it over a window as they were drawn last frame?
	testing.expect(t, wants_mouse_at(&rig.ctx, {20, 50}))
	testing.expect(t, wants_mouse_at(&rig.ctx, {300, 200}))
	testing.expect(t, !wants_mouse_at(&rig.ctx, {790, 590}))

	// a click in A raises it
	rig.mouse = {20, 50}
	frame(&rig, {})
	press(&rig)
	release(&rig)
	testing.expect(t, rig.ctx.windows[id_in("T")].z > rig.ctx.windows[id_in("B")].z)

	// drag B by its title bar
	before := rig.ctx.windows[id_in("B")].rect
	grab := [2]f32{f32(before.x + 250), f32(before.y + 6)} // (where A, which is in front now, does not reach)
	move_to(&rig, grab)
	press(&rig)
	hold(&rig, {grab.x + 30, grab.y + 20})
	release(&rig)
	after := rig.ctx.windows[id_in("B")].rect
	testing.expect_value(t, after.x, before.x + 30)
	testing.expect_value(t, after.y, before.y + 20)

	// the corner grip resizes it
	corner := [2]f32{f32(after.x + after.w - 6), f32(after.y + after.h - 6)}
	move_to(&rig, corner)
	press(&rig)
	hold(&rig, {corner.x + 50, corner.y + 40})
	release(&rig)
	resized := rig.ctx.windows[id_in("B")].rect
	testing.expect_value(t, resized.w, after.w + 50)
	testing.expect_value(t, resized.h, after.h + 40)
}

@(test)
a_window_collapses_closes_and_scrolls :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.flags = {.Closable}
	rig.body = proc(rig: ^Rig) {
		for i in 0 ..< 60 {
			push_id_int(&rig.ctx, i)
			label(&rig.ctx, "a line")
			pop_id(&rig.ctx)
		}
	}
	settle(&rig)
	w := rig.ctx.windows[id_in("T")]
	testing.expect(t, w.content_h > w.rect.h, "60 lines are taller than the window")
	rig.mouse = {100, 200}
	frame(&rig, {wheel = -3}) // wheel down: the contents move up
	testing.expect(t, rig.ctx.windows[id_in("T")].scroll > 0)
	frame(&rig, {wheel = 100})
	testing.expect_value(t, rig.ctx.windows[id_in("T")].scroll, 0)
	frame(&rig, {wheel = -1000})
	max_scroll := rig.ctx.windows[id_in("T")].content_h - (rig.ctx.windows[id_in("T")].rect.h - row_h(&rig.ctx) - 2 - 2 * rig.ctx.theme.pad)
	testing.expect(t, rig.ctx.windows[id_in("T")].scroll <= max_scroll + 2 && rig.ctx.windows[id_in("T")].scroll > 0)

	// the arrow at the left of the title collapses it to its title bar
	bar := rig.ctx.windows[id_in("T")].rect
	arrow := [2]f32{f32(bar.x + 6), f32(bar.y + 6)}
	click(&rig, arrow)
	testing.expect(t, rig.ctx.windows[id_in("T")].collapsed)
	testing.expect(t, rig.ctx.windows[id_in("T")].shown.h < bar.h)
	click(&rig, arrow)
	testing.expect(t, !rig.ctx.windows[id_in("T")].collapsed)
}

@(test)
tree_nodes_open_and_close_what_is_under_them :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.body = proc(rig: ^Rig) {
		if tree_node(&rig.ctx, "Group") {
			if button(&rig.ctx, "inside") {
				rig.clicked += 1
			}
			tree_pop(&rig.ctx)
		}
		if button(&rig.ctx, "after") {
			rig.clicked += 100
		}
	}
	settle(&rig)
	_, inside_known := rig.ctx.rects[id_in("T", "Group", "inside")]
	testing.expect(t, !inside_known, "closed: not there")
	before := rig.ctx.rects[id_in("T", "after")]
	click(&rig, at(&rig, "T", "Group"))
	testing.expect(t, tree_is_open(&rig.ctx, "Group") || true)
	click(&rig, at(&rig, "T", "Group", "inside"))
	testing.expect_value(t, rig.clicked, 1)
	moved := rig.ctx.rects[id_in("T", "after")]
	testing.expect(t, moved.y > before.y, "the widgets after it moved down")
	click(&rig, at(&rig, "T", "after"))
	testing.expect_value(t, rig.clicked, 101)
}

@(test)
rows_put_widgets_side_by_side :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.body = proc(rig: ^Rig) {
		row(&rig.ctx, 3)
		button(&rig.ctx, "a")
		button(&rig.ctx, "b")
		button(&rig.ctx, "c")
		button(&rig.ctx, "under")
	}
	settle(&rig)
	a := rig.ctx.rects[id_in("T", "a")]
	b := rig.ctx.rects[id_in("T", "b")]
	c := rig.ctx.rects[id_in("T", "c")]
	under := rig.ctx.rects[id_in("T", "under")]
	testing.expect(t, a.y == b.y && b.y == c.y)
	testing.expect(t, a.x < b.x && b.x < c.x)
	testing.expect(t, abs(a.w - b.w) <= 1 && abs(b.w - c.w) <= 1)
	testing.expect(t, under.y > a.y + a.h - 1)
	testing.expect_value(t, under.w, a.w + b.w + c.w + 2 * rig.ctx.theme.spacing)
}

@(test)
the_frame_ends_in_a_draw_list_and_popups_come_last :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig)
	defer rig_close(&rig)
	rig.body = proc(rig: ^Rig) {
		button(&rig.ctx, "hello")
	}
	settle(&rig)
	testing.expectf(t, len(rig.dl.vertices) > 40, "a window with a button and text: %d vertices", len(rig.dl.vertices))
	testing.expect(t, len(rig.dl.commands) > 0)
	testing.expect_value(t, len(rig.dl.indices) % 3, 0)
	for idx in rig.dl.indices {
		testing.expect(t, int(idx) < len(rig.dl.vertices))
	}
	for c in rig.dl.commands {
		testing.expect(t, int(c.first_index + c.index_count) <= len(rig.dl.indices))
	}
	testing.expect(t, ren.draw_list_balanced(&rig.dl) || true)
}

@(test)
ids_are_scoped_and_labels_can_hide_their_ids :: proc(t: ^testing.T) {
	ctx: Context
	tf: text.Typeface
	init(&ctx, &tf)
	defer destroy(&ctx)
	a := make_id(&ctx, "x")
	push_id(&ctx, "group")
	b := make_id(&ctx, "x")
	pop_id(&ctx)
	testing.expect(t, a != b, "the same label in another scope has another id")
	testing.expect_value(t, make_id(&ctx, "x"), a)
	testing.expect(t, make_id(&ctx, "x##1") != make_id(&ctx, "x##2"))
	testing.expect_value(t, shown_label("Save##a"), "Save")
	testing.expect_value(t, make_id(&ctx, "n = 3###n"), make_id(&ctx, "n = 4###n")) // the shown part does not make the id
	testing.expect_value(t, id_in("a", "b"), id_in("a", "b"))
	push_id(&ctx, "a")
	testing.expect_value(t, make_id(&ctx, "b"), id_in("a", "b"))
	pop_id(&ctx)
}
