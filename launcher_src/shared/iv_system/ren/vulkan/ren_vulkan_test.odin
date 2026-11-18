package ren_vulkan

import "core:log"
import "core:testing"
import vk "vendor:vulkan"
import platform "../../platform"
import ren ".."
import ui "../../../iv_ui"

// ---------------------------------------------------------------------------
// The tests that need no Vulkan: the probe and the checks create makes before touching the GPU.
// The ones that draw make a hidden window with a real swapchain, draw into render-target textures and read the texels back,
// so every blend mode, material, clip and target switch is checked against exact pixels. They are skipped (and say so) on a
// computer without Vulkan 1.3.
// ---------------------------------------------------------------------------

@(test)
probe_answers_without_a_window :: proc(t: ^testing.T) {
	p := probe()
	// Either answer is right, depending on the computer; what must hold is that it says why.
	testing.expect(t, p.reason != "")
	if p.available {
		testing.expect(t, p.device != "")
	}
	log.infof("probe: available=%v  %s", p.available, p.reason)
}

@(test)
create_checks_the_surface_first :: proc(t: ^testing.T) {
	_, err := create({kind = .None})
	testing.expect_value(t, err, ren.Create_Error.Unsupported_Surface)
	_, err = create({kind = SURFACE_KIND}) // no window handle
	testing.expect_value(t, err, ren.Create_Error.Unsupported_Surface)
}

@(test)
present_modes_prefer_mailbox_then_vsync :: proc(t: ^testing.T) {
	testing.expect_value(t, present_mode_order[0], vk.PresentModeKHR.MAILBOX)
	testing.expect_value(t, present_mode_order[1], vk.PresentModeKHR.FIFO)
	testing.expect_value(t, len(present_mode_order), 2) // immediate (tearing) is opt-in
}

// ---- a window and a renderer ------------------------------------------------------------------------------------

Fixture :: struct {
	window:   ^platform.Window,
	renderer: ren.Renderer,
	report:   ren.Create_Report,
}

// Opens the fixture, or returns false (and says why) if this computer has no usable Vulkan.
open_fixture :: proc(t: ^testing.T, f: ^Fixture, width := 256, height := 256) -> bool {
	if !probe().available {
		log.warnf("skipped: %s", probe().reason)
		return false
	}
	w, ok := platform.create_window({title = "ren_vulkan test", width = width, height = height, flags = {.Hidden}})
	if !testing.expect(t, ok, "a window") {
		return false
	}
	f.window = w
	h := platform.native_handle(w)
	surface := ren.Native_Surface {
		kind      = SURFACE_KIND,
		window    = h.window,
		display   = h.display,
		width     = w.size.x,
		height    = w.size.y,
		dpi_scale = w.dpi_scale,
	}
	factories := [1]ren.Factory{factory()}
	made: bool
	f.renderer, f.report, made = ren.create_first(surface, factories[:], []ren.Backend_Kind{.Vulkan})
	if !testing.expect(t, made, "the Vulkan backend") {
		platform.destroy_window(w)
		return false
	}
	return true
}

close_fixture :: proc(f: ^Fixture) {
	ren.renderer_destroy(&f.renderer)
	platform.destroy_window(f.window)
}

make_target :: proc(t: ^testing.T, f: ^Fixture, w, h: int) -> ren.Texture {
	tex, ok := ren.texture_create(&f.renderer, {width = w, height = h, format = .RGBA8, filter = .Nearest, use = {.Render_Target}})
	testing.expect(t, ok)
	return tex
}

// Draws the frame, and reports whether it reached the screen.
finish :: proc(t: ^testing.T, f: ^Fixture) {
	result := ren.end_frame(&f.renderer)
	testing.expect_value(t, result, ren.Present_Result.Presented)
}

read :: proc(t: ^testing.T, f: ^Fixture, tex: ren.Texture) -> ren.Texture_Image {
	img, ok := ren.texture_read(&f.renderer, tex, context.temp_allocator)
	testing.expect(t, ok)
	return img
}

pixel :: proc(img: ren.Texture_Image, x, y: int) -> [4]u8 {
	i := (y * img.width + x) * 4
	return {img.pixels[i], img.pixels[i + 1], img.pixels[i + 2], img.pixels[i + 3]}
}

// Is each channel within `tol` of what is expected?
near :: proc(got, want: [4]u8, tol := 2) -> bool {
	for i in 0 ..< 4 {
		if abs(int(got[i]) - int(want[i])) > tol {
			return false
		}
	}
	return true
}

expect_pixel :: proc(t: ^testing.T, img: ren.Texture_Image, x, y: int, want: [4]u8, tol := 2, loc := #caller_location) {
	got := pixel(img, x, y)
	if !near(got, want, tol) {
		testing.expectf(t, false, "pixel (%d, %d) is %v, expected %v", x, y, got, want, loc = loc)
	}
}

RED :: ren.Color{255, 0, 0, 255}
GREEN :: ren.Color{0, 255, 0, 255}
BLUE :: ren.Color{0, 0, 255, 255}

// ---- the tests ----------------------------------------------------------------------------------------------------

@(test)
backend_presents_frames_and_reports_itself :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	log.infof("backend: %s", f.renderer.backend.name)
	testing.expect_value(t, f.renderer.backend.kind, ren.Backend_Kind.Vulkan)
	for i in 0 ..< 8 { // more frames than frames in flight and swapchain images
		dl := ren.begin_frame(&f.renderer, ren.color_f(0.1 * f32(i), 0.2, 0.3))
		ren.draw_rect(dl, {10, 10, 50, 50}, RED)
		finish(t, &f)
	}
}

@(test)
rectangle_in_a_target :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	tex := make_target(t, &f, 16, 16)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {16, 16})
	ren.draw_rect(dl, {4, 2, 8, 6}, RED)
	ren.pop_target(dl)
	finish(t, &f)

	img := read(t, &f, tex)
	testing.expect_value(t, img.width, 16)
	expect_pixel(t, img, 0, 0, {0, 0, 0, 0}) // a new target is transparent black
	expect_pixel(t, img, 3, 5, {0, 0, 0, 0}) // just left of the rectangle
	expect_pixel(t, img, 4, 2, {255, 0, 0, 255}) // its first pixel
	expect_pixel(t, img, 11, 7, {255, 0, 0, 255}) // its last pixel
	expect_pixel(t, img, 12, 7, {0, 0, 0, 0}) // just right of it
	expect_pixel(t, img, 8, 8, {0, 0, 0, 0}) // just below it
}

@(test)
blend_modes :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	tex := make_target(t, &f, 8, 4)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {8, 4})
	ren.draw_rect(dl, {0, 0, 8, 4}, BLUE) // the background

	half_white := ren.Color{255, 255, 255, 128}
	ren.draw_rect(dl, {0, 0, 2, 4}, half_white) // alpha (the default)
	{
		ren.scope_blend(dl, .Additive)
		ren.draw_rect(dl, {2, 0, 2, 4}, ren.Color{255, 0, 0, 255}) // blue + red
	}
	{
		ren.scope_blend(dl, .Opaque)
		ren.draw_rect(dl, {4, 0, 2, 4}, ren.Color{10, 20, 30, 40}) // replaces everything, alpha too
	}
	ren.pop_target(dl)
	finish(t, &f)

	img := read(t, &f, tex)
	expect_pixel(t, img, 0, 1, {128, 128, 255, 255}) // 50% white over blue
	expect_pixel(t, img, 2, 1, {255, 0, 255, 255}) // additive
	expect_pixel(t, img, 4, 1, {10, 20, 30, 40}) // opaque
	expect_pixel(t, img, 6, 1, {0, 0, 255, 255}) // untouched
}

@(test)
premultiplied_and_modulate_blends :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	tex := make_target(t, &f, 8, 2)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {8, 2})
	ren.draw_rect(dl, {0, 0, 8, 2}, ren.Color{100, 100, 200, 255}) // the background
	{
		ren.scope_blend(dl, .Premultiplied)
		ren.draw_rect(dl, {0, 0, 2, 2}, ren.Color{50, 0, 0, 128}) // red already halved: 50 + 100 * (1 - 0.5) = 100, 0 + 50, 0 + 100
	}
	{
		ren.scope_blend(dl, .Modulate)
		ren.draw_rect(dl, {2, 0, 2, 2}, ren.Color{128, 128, 128, 77}) // half of what is there; the alpha of the source and of the target are not used
	}
	ren.pop_target(dl)
	finish(t, &f)
	img := read(t, &f, tex)
	expect_pixel(t, img, 0, 0, {100, 50, 100, 255})
	expect_pixel(t, img, 2, 0, {50, 50, 100, 255})
	expect_pixel(t, img, 5, 0, {100, 100, 200, 255}) // untouched
}

@(test)
alpha_blend_into_transparent_keeps_alpha :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	tex := make_target(t, &f, 4, 4)
	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {4, 4})
	ren.draw_rect(dl, {0, 0, 4, 4}, ren.Color{255, 0, 0, 128})
	ren.pop_target(dl)
	finish(t, &f)
	img := read(t, &f, tex)
	// colour 255 * 128/255 = 128 (it is not premultiplied back), alpha 128
	expect_pixel(t, img, 1, 1, {128, 0, 0, 128})
}

@(test)
clip_and_offset_and_tint :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	tex := make_target(t, &f, 16, 16)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {16, 16})
	{
		ren.scope_clip(dl, {4, 4, 6, 6}) // only (4..9, 4..9) shows
		ren.draw_rect(dl, {0, 0, 16, 16}, RED)
	}
	{
		ren.scope_offset(dl, {10, 0})
		ren.scope_tint(dl, ren.Color{0, 255, 0, 255}) // white * green tint = green
		ren.draw_rect(dl, {0, 12, 4, 4}, ren.WHITE) // at (10, 12) .. (13, 15)
	}
	ren.pop_target(dl)
	finish(t, &f)

	img := read(t, &f, tex)
	expect_pixel(t, img, 3, 5, {0, 0, 0, 0})
	expect_pixel(t, img, 4, 4, {255, 0, 0, 255})
	expect_pixel(t, img, 9, 9, {255, 0, 0, 255})
	expect_pixel(t, img, 10, 9, {0, 0, 0, 0})
	expect_pixel(t, img, 10, 12, {0, 255, 0, 255})
	expect_pixel(t, img, 13, 15, {0, 255, 0, 255})
	expect_pixel(t, img, 9, 12, {0, 0, 0, 0})
}

@(test)
textured_quads_sample_texels :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	// 2 x 2: red green / blue white
	texels := [16]u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}
	sprite, ok := ren.texture_create(&f.renderer, {width = 2, height = 2, format = .RGBA8, filter = .Nearest, pixels = texels[:]})
	testing.expect(t, ok)
	tex := make_target(t, &f, 4, 4)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {4, 4})
	ren.draw_image(dl, sprite, {0, 0, 4, 4}) // each texel becomes 2 x 2 pixels
	ren.pop_target(dl)
	finish(t, &f)

	img := read(t, &f, tex)
	expect_pixel(t, img, 0, 0, {255, 0, 0, 255})
	expect_pixel(t, img, 1, 1, {255, 0, 0, 255})
	expect_pixel(t, img, 2, 0, {0, 255, 0, 255})
	expect_pixel(t, img, 3, 1, {0, 255, 0, 255})
	expect_pixel(t, img, 0, 2, {0, 0, 255, 255})
	expect_pixel(t, img, 3, 3, {255, 255, 255, 255})

	// what the sprite is read back as: the texels it was made with
	back := read(t, &f, sprite)
	testing.expect_value(t, len(back.pixels), 16)
	expect_pixel(t, back, 1, 0, {0, 255, 0, 255}, 0)
}

@(test)
tint_multiplies_the_texture :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	texel := [4]u8{255, 255, 255, 255}
	white, _ := ren.texture_create(&f.renderer, {width = 1, height = 1, format = .RGBA8, pixels = texel[:]})
	tex := make_target(t, &f, 2, 2)
	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {2, 2})
	ren.draw_image(dl, white, {0, 0, 2, 2}, tint = ren.Color{200, 100, 50, 255})
	ren.pop_target(dl)
	finish(t, &f)
	expect_pixel(t, read(t, &f, tex), 0, 0, {200, 100, 50, 255})
}

@(test)
coverage_and_sdf_materials :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	// one-channel textures: 0 0 | 255 255 (the left half has no coverage, the right half full)
	texels := [4]u8{0, 255, 0, 255}
	mask, ok := ren.texture_create(&f.renderer, {width = 2, height = 2, format = .R8, filter = .Nearest, pixels = texels[:]})
	testing.expect(t, ok)
	zero, one := [1]u8{0}, [1]u8{255}
	far, _ := ren.texture_create(&f.renderer, {width = 1, height = 1, format = .R8, filter = .Nearest, pixels = zero[:]})
	inside, _ := ren.texture_create(&f.renderer, {width = 1, height = 1, format = .R8, filter = .Nearest, pixels = one[:]})
	cover := make_target(t, &f, 2, 2)
	sdf := make_target(t, &f, 2, 2)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, cover, {2, 2})
	ren.draw_image(dl, mask, {0, 0, 2, 2}, tint = RED, material = .Coverage)
	ren.pop_target(dl)
	ren.push_target(dl, sdf, {2, 2})
	// a distance field that is the same everywhere (two 1x1 textures): the shader smooths the edge over the screen-space
	// derivative of the distance, and on a texture with a jump (like `mask`) the derivative at the jump is not zero
	ren.draw_image(dl, far, {0, 0, 1, 2}, tint = GREEN, material = .Sdf)
	ren.draw_image(dl, inside, {1, 0, 1, 2}, tint = GREEN, material = .Sdf)
	ren.pop_target(dl)
	finish(t, &f)

	img := read(t, &f, cover)
	expect_pixel(t, img, 0, 0, {0, 0, 0, 0}) // no coverage: nothing drawn
	expect_pixel(t, img, 1, 0, {255, 0, 0, 255}) // full coverage
	img = read(t, &f, sdf)
	expect_pixel(t, img, 0, 0, {0, 0, 0, 0}) // far outside the edge
	expect_pixel(t, img, 1, 1, {0, 255, 0, 255}) // well inside
}

@(test)
updating_a_texture :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	atlas, ok := ren.texture_create(&f.renderer, {width = 4, height = 4, format = .RGBA8, filter = .Nearest, use = {.Dynamic}})
	testing.expect(t, ok)

	green := [4]u8{0, 255, 0, 255}
	testing.expect(t, ren.texture_update(&f.renderer, atlas, ui.Rect{2, 1, 1, 1}, green[:]))
	testing.expect(t, !ren.texture_update(&f.renderer, atlas, ui.Rect{3, 3, 2, 2}, green[:])) // sticks out
	testing.expect(t, !ren.texture_update(&f.renderer, atlas, ui.Rect{0, 0, 1, 1}, green[:2])) // too few bytes

	// the update is drawn in the same frame that follows it
	tex := make_target(t, &f, 4, 4)
	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {4, 4})
	ren.draw_image(dl, atlas, {0, 0, 4, 4})
	ren.pop_target(dl)
	finish(t, &f)
	img := read(t, &f, tex)
	expect_pixel(t, img, 2, 1, {0, 255, 0, 255}) // the texel that was written
	expect_pixel(t, img, 1, 1, {0, 0, 0, 0}) // the rest is still clear

	// and a second update, after frames have gone by
	blue := [4]u8{0, 0, 255, 255}
	testing.expect(t, ren.texture_update(&f.renderer, atlas, ui.Rect{0, 0, 1, 1}, blue[:]))
	dl = ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {4, 4})
	ren.draw_image(dl, atlas, {0, 0, 4, 4})
	ren.pop_target(dl)
	finish(t, &f)
	expect_pixel(t, read(t, &f, tex), 0, 0, {0, 0, 255, 255})
}

@(test)
targets_can_be_drawn_with_and_into_in_one_frame :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	a := make_target(t, &f, 4, 4)
	b := make_target(t, &f, 4, 4)

	dl := ren.begin_frame(&f.renderer, ren.color_f(0.2, 0.2, 0.2))
	ren.draw_rect(dl, {0, 0, 20, 20}, BLUE) // the window
	ren.push_target(dl, a, {4, 4})
	ren.draw_rect(dl, {0, 0, 4, 4}, RED) // a is red
	ren.pop_target(dl)
	ren.push_target(dl, b, {4, 4})
	ren.draw_image(dl, a, {0, 0, 4, 4}) // b gets a (drawn earlier in this frame)
	ren.draw_rect(dl, {0, 0, 2, 2}, GREEN) // and a green corner
	ren.pop_target(dl)
	ren.push_target(dl, a, {4, 4}) // a again: its contents are kept, not cleared
	ren.draw_rect(dl, {2, 2, 2, 2}, BLUE)
	ren.draw_image(dl, a, {0, 0, 4, 4}, tint = GREEN) // a texture cannot be read while it is drawn into: skipped
	ren.pop_target(dl)
	ren.draw_image(dl, a, {30, 30, 4, 4}) // and the window samples a
	finish(t, &f)

	img_b := read(t, &f, b)
	expect_pixel(t, img_b, 3, 3, {255, 0, 0, 255})
	expect_pixel(t, img_b, 0, 0, {0, 255, 0, 255})
	img_a := read(t, &f, a)
	expect_pixel(t, img_a, 0, 0, {255, 0, 0, 255})
	expect_pixel(t, img_a, 3, 3, {0, 0, 255, 255})
}

@(test)
stale_and_invalid_textures_draw_nothing :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	texel := [4]u8{255, 255, 255, 255}
	gone, _ := ren.texture_create(&f.renderer, {width = 1, height = 1, format = .RGBA8, pixels = texel[:]})
	not_a_target, _ := ren.texture_create(&f.renderer, {width = 4, height = 4, format = .RGBA8})
	tex := make_target(t, &f, 4, 4)
	ren.texture_destroy(&f.renderer, gone)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, tex, {4, 4})
	ren.draw_image(dl, gone, {0, 0, 4, 4}) // destroyed: dropped
	ren.draw_image(dl, ren.Texture(0xFFFFF), {0, 0, 4, 4}) // never existed: dropped
	ren.pop_target(dl)
	ren.push_target(dl, not_a_target, {4, 4}) // cannot be drawn into: dropped
	ren.draw_rect(dl, {0, 0, 4, 4}, RED)
	ren.pop_target(dl)
	ren.push_target(dl, ren.Texture(0x12345), {4, 4}) // stale target: dropped
	ren.draw_rect(dl, {0, 0, 4, 4}, RED)
	ren.pop_target(dl)
	finish(t, &f)

	expect_pixel(t, read(t, &f, tex), 0, 0, {0, 0, 0, 0})
	expect_pixel(t, read(t, &f, not_a_target), 0, 0, {0, 0, 0, 0})
	_, readable := ren.texture_read(&f.renderer, gone, context.temp_allocator)
	testing.expect(t, !readable)
}

@(test)
bad_texture_descriptions_are_refused :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	_, ok := ren.texture_create(&f.renderer, {width = 0, height = 4, format = .RGBA8})
	testing.expect(t, !ok)
	_, ok = ren.texture_create(&f.renderer, {width = 4, height = 4, format = .R8, use = {.Render_Target}})
	testing.expect(t, !ok) // only RGBA8 targets
	few := [3]u8{1, 2, 3}
	_, ok = ren.texture_create(&f.renderer, {width = 4, height = 4, format = .RGBA8, pixels = few[:]})
	testing.expect(t, !ok)
}

@(test)
a_big_list_grows_the_buffers :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	tex := make_target(t, &f, 200, 200)
	for round in 0 ..< 3 { // grows, then fits, over frames of both slots
		count := 5000 * (round + 1)
		dl := ren.begin_frame(&f.renderer)
		ren.push_target(dl, tex, {200, 200})
		for i in 0 ..< count {
			c := ren.Color{u8(i % 256), u8(round * 60), 0, 255}
			ren.draw_rect(dl, {i % 200, (i / 200) % 200, 1, 1}, c)
		}
		ren.pop_target(dl)
		finish(t, &f)
	}
	img := read(t, &f, tex)
	last := 15000 - 1
	expect_pixel(t, img, last % 200, (last / 200) % 200, {u8(last % 256), 120, 0, 255})
}

@(test)
textures_come_and_go_over_many_frames :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	texel := [4]u8{9, 9, 9, 255}
	for frame in 0 ..< 60 {
		tex, ok := ren.texture_create(&f.renderer, {width = 1, height = 1, format = .RGBA8, pixels = texel[:]})
		testing.expect(t, ok)
		dl := ren.begin_frame(&f.renderer)
		ren.draw_image(dl, tex, {0, 0, 10, 10})
		ren.texture_destroy(&f.renderer, tex) // destroyed before the frame that uses it is even submitted
		finish(t, &f)
		_ = frame
	}
	testing.expect_value(t, f.renderer.backend.data != nil, true)
	state := (^State)(f.renderer.backend.data)
	testing.expect(t, len(state.garbage) <= 3 * FRAMES_IN_FLIGHT) // the old ones were freed, not piled up
}

@(test)
the_window_can_be_resized_and_hidden :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	state := (^State)(f.renderer.backend.data)

	dl := ren.begin_frame(&f.renderer)
	ren.draw_rect(dl, {0, 0, 10, 10}, RED)
	finish(t, &f)
	first := state.extent

	platform.set_size(f.window, 340, 200)
	platform.poll(f.window)
	ren.resize(&f.renderer, f.window.size.x, f.window.size.y)
	for _ in 0 ..< 3 { // the swapchain is made again at the next frame
		dl = ren.begin_frame(&f.renderer)
		ren.draw_rect(dl, {0, 0, 10, 10}, RED)
		finish(t, &f)
	}
	testing.expect(t, state.extent != first)
	testing.expect_value(t, int(state.extent.width), f.window.size.x)
	testing.expect_value(t, int(state.extent.height), f.window.size.y)
}

@(test)
the_present_mode_follows_the_preference_list :: proc(t: ^testing.T) {
	saved := present_mode_order
	defer present_mode_order = saved

	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	default_mode := (^State)(f.renderer.backend.data).present_mode
	close_fixture(&f)
	log.infof("default present mode: %s", present_mode_name(default_mode))
	// mailbox where the window system has it, else vsync; never the tearing one unless asked
	testing.expect(t, default_mode == .MAILBOX || default_mode == .FIFO)

	present_mode_order = {.FIFO, .FIFO} // an unusual list: the first entry that is offered wins
	if open_fixture(t, &f) {
		testing.expect_value(t, (^State)(f.renderer.backend.data).present_mode, vk.PresentModeKHR.FIFO)
		close_fixture(&f)
	}
	present_mode_order = {.IMMEDIATE, .FIFO} // opted in to tearing; falls back to FIFO if not offered
	if open_fixture(t, &f) {
		mode := (^State)(f.renderer.backend.data).present_mode
		testing.expect(t, mode == .IMMEDIATE || mode == .FIFO)
		close_fixture(&f)
	}
}

@(test)
a_window_can_go_fullscreen_and_back :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	state := (^State)(f.renderer.backend.data)

	// what a program's loop does: poll, tell the renderer about a new size, draw a frame (the window is mapped by the
	// frames, which is when a Wayland compositor acts on a request like this)
	run_frames :: proc(t: ^testing.T, f: ^Fixture, count: int) {
		for _ in 0 ..< count {
			events := platform.poll(f.window)
			if .Resized in events {
				ren.resize(&f.renderer, f.window.size.x, f.window.size.y)
			}
			dl := ren.begin_frame(&f.renderer)
			ren.draw_rect(dl, {0, 0, 10, 10}, RED)
			ren.end_frame(&f.renderer) // (a frame may be skipped while the size changes)
		}
	}
	run_frames(t, &f, 3)
	windowed := f.window.size

	platform.set_fullscreen(f.window, true)
	run_frames(t, &f, 12)
	testing.expect(t, f.window.fullscreen)
	testing.expect_value(t, int(state.extent.width), f.window.size.x) // the swapchain follows the window
	testing.expect_value(t, int(state.extent.height), f.window.size.y)
	testing.expect(t, f.window.size != windowed)

	platform.set_fullscreen(f.window, false)
	run_frames(t, &f, 12)
	testing.expect(t, !f.window.fullscreen)
	testing.expect_value(t, int(state.extent.width), f.window.size.x)
	testing.expect_value(t, int(state.extent.height), f.window.size.y)
	finish(t, &f)
}

@(test)
creating_and_destroying_twice :: proc(t: ^testing.T) {
	for _ in 0 ..< 2 {
		f: Fixture
		if !open_fixture(t, &f) {
			return
		}
		dl := ren.begin_frame(&f.renderer)
		ren.draw_rect(dl, {0, 0, 4, 4}, RED)
		finish(t, &f)
		close_fixture(&f)
	}
}

@(test)
factory_fits_the_choice_logic :: proc(t: ^testing.T) {
	f := factory()
	testing.expect_value(t, f.kind, ren.Backend_Kind.Vulkan)
	testing.expect(t, f.probe != nil && f.create != nil)
	testing.expect(t, !f.fresh_window)
	// without a window handle create fails cleanly and create_first goes on without a backend
	factories := [1]ren.Factory{f}
	r, report, ok := ren.create_first({kind = .None, width = 64, height = 64}, factories[:], ren.DEFAULT_ORDER[:])
	defer ren.renderer_destroy(&r)
	testing.expect(t, !ok)
	testing.expect(t, ren.renderer_is_null(&r))
	testing.expect(t, !report.needs_new_window)
}
