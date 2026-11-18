package ren

import "core:testing"
import ui "../../iv_ui"

new_list :: proc(w := 320, h := 200) -> Draw_List {
	dl: Draw_List
	draw_list_init(&dl)
	draw_list_reset(&dl, w, h)
	return dl
}

// The same drawing twice has the same signature (a frame that need not be shown); a moved, recoloured or extra rectangle, or another size, does not.
@(test)
signature_tells_frames_apart :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	frame :: proc(dl: ^Draw_List, x: int, c: Color, extra: bool, w := 320) {
		draw_list_reset(dl, w, 200, BLACK)
		push_clip(dl, {0, 0, 100, 100})
		draw_rect(dl, {x, 20, 30, 40}, c)
		pop_clip(dl)
		if extra {
			draw_rect(dl, {0, 0, 1, 1}, c)
		}
	}
	frame(&dl, 10, WHITE, false)
	a := draw_list_signature(&dl)
	frame(&dl, 10, WHITE, false)
	testing.expect_value(t, draw_list_signature(&dl), a)
	frame(&dl, 11, WHITE, false)
	testing.expect(t, draw_list_signature(&dl) != a, "a moved rectangle")
	frame(&dl, 10, BLACK, false)
	testing.expect(t, draw_list_signature(&dl) != a, "another colour")
	frame(&dl, 10, WHITE, true)
	testing.expect(t, draw_list_signature(&dl) != a, "one more rectangle")
	frame(&dl, 10, WHITE, false, 321)
	testing.expect(t, draw_list_signature(&dl) != a, "another window size")
}

@(test)
rect_makes_one_quad :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	draw_rect(&dl, {10, 20, 30, 40}, WHITE)
	testing.expect_value(t, len(dl.vertices), 4)
	testing.expect_value(t, len(dl.indices), 6)
	testing.expect_value(t, len(dl.commands), 1)
	testing.expect_value(t, dl.vertices[0].pos, Vec2{10, 20})
	testing.expect_value(t, dl.vertices[2].pos, Vec2{40, 60})
	testing.expect_value(t, dl.commands[0].clip, ui.Rect{0, 0, 320, 200})
}

@(test)
same_state_merges_and_changes_split :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	draw_rect(&dl, {0, 0, 5, 5}, WHITE)
	draw_rect(&dl, {10, 0, 5, 5}, BLACK)
	testing.expect_value(t, len(dl.commands), 1) // different colors, same state: one batch
	testing.expect_value(t, dl.commands[0].index_count, u32(12))

	push_blend(&dl, .Additive)
	draw_rect(&dl, {0, 0, 5, 5}, WHITE)
	pop_blend(&dl)
	testing.expect_value(t, len(dl.commands), 2)
	testing.expect_value(t, dl.commands[1].blend, Blend.Additive)
	testing.expect_value(t, dl.commands[1].first_index, u32(12))

	draw_rect(&dl, {0, 0, 5, 5}, WHITE) // back to alpha: a third batch
	testing.expect_value(t, len(dl.commands), 3)

	draw_image(&dl, Texture(7), {0, 0, 8, 8})
	draw_image(&dl, Texture(7), {8, 0, 8, 8})
	draw_image(&dl, Texture(9), {16, 0, 8, 8})
	testing.expect_value(t, len(dl.commands), 5) // texture 7 twice merged, then texture 9
}

@(test)
clip_nests_and_intersects :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	push_clip(&dl, {10, 10, 100, 100})
	push_clip(&dl, {60, 60, 100, 100}) // sticks out of the first
	draw_rect(&dl, {0, 0, 300, 300}, WHITE)
	testing.expect_value(t, dl.commands[0].clip, ui.Rect{60, 60, 50, 50})
	pop_clip(&dl)
	draw_rect(&dl, {0, 0, 300, 300}, WHITE)
	testing.expect_value(t, dl.commands[1].clip, ui.Rect{10, 10, 100, 100})
	pop_clip(&dl)
	testing.expect(t, draw_list_balanced(&dl))
}

@(test)
offset_moves_clips_and_vertices :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	push_offset(&dl, {100, 50})
	push_offset(&dl, {5, 5}) // adds up: (105, 55)
	draw_rect(&dl, {0, 0, 10, 10}, WHITE)
	testing.expect_value(t, dl.vertices[0].pos, Vec2{105, 55})
	push_clip(&dl, {0, 0, 20, 20}) // in the offset's coordinates
	draw_rect(&dl, {0, 0, 100, 100}, WHITE)
	testing.expect_value(t, dl.commands[1].clip, ui.Rect{105, 55, 20, 20})
	pop_clip(&dl)
	pop_offset(&dl)
	pop_offset(&dl)
	testing.expect(t, draw_list_balanced(&dl))
}

@(test)
tint_multiplies :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	push_tint(&dl, Color{255, 255, 255, 128})
	push_tint(&dl, Color{255, 0, 0, 128})
	draw_rect(&dl, {0, 0, 4, 4}, WHITE)
	testing.expect_value(t, dl.vertices[0].color, Color{255, 0, 0, 64})
	pop_tint(&dl)
	pop_tint(&dl)
}

@(test)
scoped_pushes_pop_themselves :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	{
		scope_clip(&dl, {0, 0, 50, 50})
		scope_offset(&dl, {1, 1})
		scope_tint(&dl, Color{255, 255, 255, 200})
		scope_blend(&dl, .Opaque)
		testing.expect_value(t, len(dl.clip_stack), 1)
		testing.expect_value(t, current_blend(&dl), Blend.Opaque)
	}
	testing.expect(t, draw_list_balanced(&dl))
	testing.expect_value(t, current_blend(&dl), Blend.Alpha)
}

@(test)
render_target_starts_clean :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	push_offset(&dl, {40, 40})
	push_clip(&dl, {0, 0, 10, 10})
	push_target(&dl, Texture(3), {64, 64})
	draw_rect(&dl, {1, 2, 8, 8}, WHITE)
	testing.expect_value(t, dl.vertices[0].pos, Vec2{1, 2}) // the window's offset does not apply
	testing.expect_value(t, dl.commands[0].target, Texture(3))
	testing.expect_value(t, dl.commands[0].clip, ui.Rect{0, 0, 64, 64})
	testing.expect_value(t, target_size(&dl), [2]int{64, 64})
	pop_target(&dl)
	testing.expect_value(t, target_size(&dl), [2]int{320, 200})
	testing.expect_value(t, current_offset(&dl), Vec2{40, 40})
	pop_clip(&dl)
	pop_offset(&dl)
	testing.expect(t, draw_list_balanced(&dl))
}

@(test)
unbalanced_pops_are_counted :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	pop_clip(&dl)
	testing.expect(t, !draw_list_balanced(&dl))
	draw_list_reset(&dl, 10, 10)
	push_clip(&dl, {0, 0, 1, 1})
	testing.expect(t, !draw_list_balanced(&dl)) // a push without its pop
}

@(test)
empty_things_draw_nothing :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	draw_rect(&dl, {0, 0, 0, 10}, WHITE)
	draw_rect(&dl, {0, 0, 10, -3}, WHITE)
	draw_rect(&dl, {0, 0, 10, 10}, TRANSPARENT)
	draw_line(&dl, {1, 1}, {1, 1}, 2, WHITE)
	draw_image(&dl, Texture(1), {0, 0, 0, 0})
	testing.expect_value(t, len(dl.commands), 0)
}

@(test)
lines_have_the_width :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	draw_line(&dl, {0, 10}, {20, 10}, 4, WHITE) // horizontal: 4 thick
	testing.expect_value(t, dl.vertices[0].pos, Vec2{0, 12}) // a + normal, the normal (-dy, dx) = (0, 20) scaled to half the width: (0, 2)
	testing.expect_value(t, dl.vertices[3].pos, Vec2{0, 8}) // a - normal
}

@(test)
outline_is_four_strips :: proc(t: ^testing.T) {
	dl := new_list()
	defer draw_list_destroy(&dl)
	draw_rect_outline(&dl, {0, 0, 20, 10}, 2, WHITE)
	testing.expect_value(t, len(dl.vertices), 16)
	testing.expect_value(t, len(dl.commands), 1)
}

@(test)
text_measures_and_draws_the_same :: proc(t: ^testing.T) {
	glyphs := [?]Glyph {
		{codepoint = 'A', src = {0, 0, 6, 8}, offset = {0, 0}, advance = 7},
		{codepoint = 'B', src = {6, 0, 6, 8}, offset = {0, 1}, advance = 7},
		{codepoint = '?', src = {12, 0, 6, 8}, offset = {0, 0}, advance = 7},
		{codepoint = ' ', advance = 4},
	}
	f := font_create({texture = Texture(5), atlas_size = {32, 8}, material = .Coverage, line_height = 10, glyphs = glyphs[:], fallback = '?'})
	defer font_destroy(f)

	w, h := font_measure(f, "AB A")
	testing.expect_value(t, w, 7 + 7 + 4 + 7)
	testing.expect_value(t, h, 10)
	w, h = font_measure(f, "AB\nA")
	testing.expect_value(t, w, 14)
	testing.expect_value(t, h, 20)
	w, _ = font_measure(f, "Z") // not in the table: the fallback's advance
	testing.expect_value(t, w, 7)

	m := ui.Measure {
		size = font_measure,
		user = f,
	}
	r := ui.text_size(m, "AB")
	testing.expect_value(t, r.w, 14)

	dl := new_list()
	defer draw_list_destroy(&dl)
	width := draw_text(&dl, f, "AB A", {100, 50}, WHITE)
	testing.expect_value(t, width, 25)
	testing.expect_value(t, len(dl.vertices), 12) // A, B, A (the space has no image)
	testing.expect_value(t, len(dl.commands), 1)
	testing.expect_value(t, dl.commands[0].material, Material.Coverage)
	testing.expect_value(t, dl.vertices[0].pos, Vec2{100, 50})
	testing.expect_value(t, dl.vertices[4].pos, Vec2{107, 51}) // B: pen 107, offset y 1
	testing.expect_value(t, dl.vertices[0].uv, Vec2{0, 0})
	testing.expect_value(t, dl.vertices[5].uv, Vec2{12.0 / 32.0, 0}) // B's right edge: 12 / 32
}

@(test)
pool_handles_go_stale :: proc(t: ^testing.T) {
	p: Pool(string)
	pool_init(&p)
	defer pool_destroy(&p)
	a := pool_add(&p, "a")
	b := pool_add(&p, "b")
	testing.expect(t, a != 0 && b != 0 && a != b)
	testing.expect_value(t, pool_get(&p, a)^, "a")
	testing.expect(t, pool_remove(&p, a))
	testing.expect(t, pool_get(&p, a) == nil) // stale
	testing.expect(t, !pool_remove(&p, a))
	c := pool_add(&p, "c") // takes a's slot with a new generation
	testing.expect(t, c != a)
	testing.expect(t, pool_get(&p, a) == nil)
	testing.expect_value(t, pool_get(&p, c)^, "c")
	testing.expect(t, pool_get(&p, 0) == nil)
	testing.expect(t, pool_get(&p, 999999) == nil)
	testing.expect_value(t, p.count, 2)
}

// ---- backend choice, with fake backends --------------------------------------------------------------------

Fake :: struct {
	available:    bool,
	create_error: Create_Error,
	created:      int,
}

fakes: [Backend_Kind]Fake

fake_render :: proc(b: ^Backend, list: ^Draw_List) -> Present_Result {
	(^int)(b.data)^ += len(list.commands)
	return .Presented
}

fake_factory :: proc(kind: Backend_Kind, fresh_window := false) -> Factory {
	f := Factory {
		kind         = kind,
		fresh_window = fresh_window,
	}
	switch kind {
	case .Vulkan:
		f.probe = proc() -> Probe {return {available = fakes[.Vulkan].available, reason = "fake"}}
		f.create = proc(s: Native_Surface) -> (Backend, Create_Error) {
			fakes[.Vulkan].created += 1
			return {kind = .Vulkan, render = fake_render}, fakes[.Vulkan].create_error
		}
	case .OpenGL:
		f.probe = proc() -> Probe {return {available = fakes[.OpenGL].available, reason = "fake"}}
		f.create = proc(s: Native_Surface) -> (Backend, Create_Error) {
			fakes[.OpenGL].created += 1
			return {kind = .OpenGL, render = fake_render}, fakes[.OpenGL].create_error
		}
	case .Software:
		f.probe = proc() -> Probe {return {available = fakes[.Software].available, reason = "fake"}}
		f.create = proc(s: Native_Surface) -> (Backend, Create_Error) {
			fakes[.Software].created += 1
			return {kind = .Software, render = fake_render}, fakes[.Software].create_error
		}
	}
	return f
}

@(test)
first_working_backend_wins :: proc(t: ^testing.T) {
	fakes = {}
	fakes[.Vulkan].available = false // no Vulkan here
	fakes[.OpenGL].available = true
	fakes[.Software].available = true
	factories := [?]Factory{fake_factory(.Vulkan), fake_factory(.OpenGL), fake_factory(.Software)}
	r, report, ok := create_first({width = 100, height = 50}, factories[:], FULL_ORDER[:])
	defer renderer_destroy(&r)
	testing.expect(t, ok)
	testing.expect_value(t, report.chosen, Backend_Kind.OpenGL)
	testing.expect_value(t, report.attempt_count, 2)
	testing.expect(t, !report.attempts[0].tried) // the probe said no, so create was not called
	testing.expect_value(t, fakes[.Vulkan].created, 0)
	testing.expect_value(t, fakes[.Software].created, 0)
	testing.expect_value(t, r.width, 100)
}

@(test)
failed_create_falls_through :: proc(t: ^testing.T) {
	fakes = {}
	fakes[.Vulkan] = {true, .Device_Failure, 0}
	fakes[.Software].available = true
	factories := [?]Factory{fake_factory(.Vulkan), fake_factory(.Software)}
	r, report, ok := create_first({}, factories[:], FULL_ORDER[:])
	defer renderer_destroy(&r)
	testing.expect(t, ok)
	testing.expect_value(t, report.chosen, Backend_Kind.Software)
	testing.expect_value(t, report.attempts[0].error, Create_Error.Device_Failure)
	testing.expect_value(t, fakes[.Vulkan].created, 1)
}

@(test)
fresh_window_backend_asks_for_a_new_window :: proc(t: ^testing.T) {
	fakes = {}
	fakes[.OpenGL] = {true, .Device_Failure, 0}
	fakes[.Software].available = true
	factories := [?]Factory{fake_factory(.Vulkan), fake_factory(.OpenGL, fresh_window = true), fake_factory(.Software)}
	r, report, ok := create_first({}, factories[:], FULL_ORDER[:])
	defer renderer_destroy(&r)
	testing.expect(t, !ok) // it did not carry on to Software with a burnt window
	testing.expect(t, report.needs_new_window)
	testing.expect_value(t, report.next_index, 2)
	testing.expect_value(t, fakes[.Software].created, 0)

	// the caller makes a new window and tries again with what is left
	r2, report2, ok2 := create_first({}, factories[:], FULL_ORDER[report.next_index:])
	defer renderer_destroy(&r2)
	testing.expect(t, ok2)
	testing.expect_value(t, report2.chosen, Backend_Kind.Software)
}

@(test)
nothing_working_gives_a_null_renderer :: proc(t: ^testing.T) {
	fakes = {}
	r, report, ok := create_first({width = 64, height = 64}, nil, FULL_ORDER[:])
	defer renderer_destroy(&r)
	testing.expect(t, !ok)
	testing.expect_value(t, report.attempt_count, 0)
	testing.expect(t, renderer_is_null(&r))
	dl := begin_frame(&r)
	draw_rect(dl, {0, 0, 10, 10}, WHITE) // drawing into a null renderer is harmless
	testing.expect_value(t, end_frame(&r), Present_Result.Skipped)
	_, made := texture_create(&r, {width = 4, height = 4})
	testing.expect(t, !made)
}

@(test)
frame_goes_to_the_backend :: proc(t: ^testing.T) {
	fakes = {}
	fakes[.Software].available = true
	factories := [?]Factory{fake_factory(.Software)}
	r, _, ok := create_first({width = 32, height = 32}, factories[:], FULL_ORDER[:])
	defer renderer_destroy(&r)
	testing.expect(t, ok)
	commands_seen := 0
	r.backend.data = &commands_seen
	dl := begin_frame(&r, BLACK)
	draw_rect(dl, {0, 0, 4, 4}, WHITE)
	draw_image(dl, Texture(2), {0, 0, 4, 4})
	testing.expect_value(t, end_frame(&r), Present_Result.Presented)
	testing.expect_value(t, commands_seen, 2)
	testing.expect_value(t, r.frames, u64(1))
	if c, has := dl.clear.?; has {
		testing.expect_value(t, c, BLACK)
	} else {
		testing.fail_now(t, "clear color lost")
	}
}
