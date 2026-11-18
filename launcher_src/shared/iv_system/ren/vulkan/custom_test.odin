package ren_vulkan

import "base:runtime"
import "core:testing"
import ren ".."

// ---------------------------------------------------------------------------
// Custom shaders, the extra texture formats and the wrap modes. Like ren_vulkan_test.odin these draw into render targets and
// read the texels back, and are skipped without Vulkan 1.3.
// ---------------------------------------------------------------------------

make_custom_shader :: proc(t: ^testing.T, f: ^Fixture) -> ren.Shader {
	shader, ok := ren.shader_create(&f.renderer, {spirv = TEST_CUSTOM_SPV[:], uniform_size = TEST_CUSTOM_UNIFORM_SIZE, sampler_count = TEST_CUSTOM_SAMPLER_COUNT})
	testing.expect(t, ok)
	return shader
}

uniform_bytes :: proc(u: ^Test_Custom_Uniforms) -> []u8 {
	return ([^]u8)(u)[:size_of(Test_Custom_Uniforms)]
}

@(test)
custom_shader_gets_uniforms_textures_and_pixel_coordinates :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	shader := make_custom_shader(t, &f)

	// tex_a: 2 x 1, red channel 100 | 200
	texels_a := [8]u8{100, 0, 0, 255, 200, 0, 0, 255}
	tex_a, _ := ren.texture_create(&f.renderer, {width = 2, height = 1, format = .RGBA8, filter = .Nearest, pixels = texels_a[:]})
	texel_b := [4]u8{10, 20, 30, 255}
	tex_b, _ := ren.texture_create(&f.renderer, {width = 1, height = 1, format = .RGBA8, filter = .Nearest, pixels = texel_b[:]})
	target := make_target(t, &f, 8, 4)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, target, {8, 4})
	// three commands of one shader with different uniforms in one frame: each reads its own bytes (dynamic offsets)
	u0 := Test_Custom_Uniforms {
		tint = {0.5, 0, 0, 0},
		k    = {0, 0, 1},
		mode = 0,
	}
	ren.draw_shader(dl, shader, {0, 0, 4, 4}, {tex_a, tex_b}, uniform_bytes(&u0)) // the left half: modes 0
	u1 := u0
	u1.k[2] = 2 // twice as much
	ren.draw_shader(dl, shader, {4, 0, 2, 4}, {tex_a, tex_b}, uniform_bytes(&u1))
	u2 := Test_Custom_Uniforms {
		mode = 1,
	}
	ren.draw_shader(dl, shader, {6, 0, 2, 2}, {tex_a, tex_b}, uniform_bytes(&u2), tint = ren.Color{255, 128, 0, 255}) // mode 1: tex_b * fragColor
	ren.pop_target(dl)
	finish(t, &f)

	img := read(t, &f, target)
	// mode 0, left half: uv 0..1 over 4 pixels: pixels 0, 1 sample 100, pixels 2, 3 sample 200; r = texel * 0.5 * 1
	expect_pixel(t, img, 0, 0, {50, 0, 0, 255})
	expect_pixel(t, img, 1, 1, {50, 1, 1, 255}) // g = the column, b = the row, from the top
	expect_pixel(t, img, 2, 3, {100, 2, 3, 255})
	expect_pixel(t, img, 3, 2, {100, 3, 2, 255})
	// the second command: 2 pixels wide, the uv spans the whole texture, k = 2: 100 * 0.5 * 2 and 200 * 0.5 * 2
	expect_pixel(t, img, 4, 0, {100, 4, 0, 255})
	expect_pixel(t, img, 5, 0, {200, 5, 0, 255})
	// mode 1: the texel of tex_b times the vertex colour (255, 128, 0): (10, 10, 0)
	expect_pixel(t, img, 6, 0, {10, 10, 0, 255})
	expect_pixel(t, img, 7, 1, {10, 10, 0, 255})
	expect_pixel(t, img, 6, 3, {0, 0, 0, 0}) // below the third command: untouched
}

@(test)
custom_shader_can_be_destroyed_and_bad_ones_are_refused :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	shader := make_custom_shader(t, &f)
	target := make_target(t, &f, 2, 2)
	u := Test_Custom_Uniforms {
		mode = 2,
	}

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, target, {2, 2})
	ren.draw_shader(dl, shader, {0, 0, 2, 2}, nil, uniform_bytes(&u)) // (no textures given: the shader's samplers get the white texture)
	ren.pop_target(dl)
	finish(t, &f)
	expect_pixel(t, read(t, &f, target), 0, 0, {255, 0, 64, 255}) // (1.5, -2, 0.25, 8) clamped by an 8 bit target

	ren.shader_destroy(&f.renderer, shader)
	dl = ren.begin_frame(&f.renderer)
	ren.push_target(dl, target, {2, 2})
	ren.draw_shader(dl, shader, {0, 0, 2, 2}, nil, uniform_bytes(&u)) // destroyed: dropped, not a crash
	ren.pop_target(dl)
	finish(t, &f)

	_, ok := ren.shader_create(&f.renderer, {})
	testing.expect(t, !ok) // no code
	_, ok = ren.shader_create(&f.renderer, {spirv = TEST_CUSTOM_SPV[:], sampler_count = ren.MAX_SHADER_TEXTURES + 1})
	testing.expect(t, !ok)
	_, ok = ren.shader_create(&f.renderer, {spirv = TEST_CUSTOM_SPV[:], uniform_size = 1 << 20})
	testing.expect(t, !ok) // more uniforms than a descriptor can have
}

@(test)
float_targets_keep_values_that_do_not_fit_in_a_byte :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	shader := make_custom_shader(t, &f)
	u := Test_Custom_Uniforms {
		mode = 2,
	}

	for format in ([?]ren.Pixel_Format{.RGBA32F, .RGBA16F}) {
		target, ok := ren.texture_create(&f.renderer, {width = 2, height = 2, format = format, filter = .Nearest, use = {.Render_Target}})
		testing.expect(t, ok)
		dl := ren.begin_frame(&f.renderer)
		ren.push_target(dl, target, {2, 2})
		{
			ren.scope_blend(dl, .Opaque) // (no blending: the values are written as they are)
			ren.draw_shader(dl, shader, {0, 0, 2, 2}, nil, uniform_bytes(&u))
		}
		ren.pop_target(dl)
		finish(t, &f)
		img := read(t, &f, target)
		testing.expect_value(t, len(img.pixels), 2 * 2 * ren.pixel_size(format))
		values: [4]f32
		if format == .RGBA32F {
			values = ([^][4]f32)(raw_data(img.pixels))[0]
		} else {
			half := ([^][4]f16)(raw_data(img.pixels))[0]
			values = {f32(half[0]), f32(half[1]), f32(half[2]), f32(half[3])}
		}
		testing.expectf(t, values == {1.5, -2, 0.25, 8}, "%v read back %v", format, values)
	}
}

@(test)
gray_and_gray_alpha_textures_read_like_raylib_s :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	gray, _ := ren.texture_create(&f.renderer, {width = 1, height = 1, format = .R8, filter = .Nearest, pixels = []u8{100}})
	gray_alpha, _ := ren.texture_create(&f.renderer, {width = 1, height = 1, format = .RG8, filter = .Nearest, pixels = []u8{100, 200}})
	target := make_target(t, &f, 2, 1)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, target, {2, 2})
	{
		ren.scope_blend(dl, .Opaque)
		ren.draw_image(dl, gray, {0, 0, 1, 1}) // r = g = b = the gray, opaque
		ren.draw_image(dl, gray_alpha, {1, 0, 1, 1}) // the alpha in alpha
	}
	ren.pop_target(dl)
	finish(t, &f)
	img := read(t, &f, target)
	expect_pixel(t, img, 0, 0, {100, 100, 100, 255})
	expect_pixel(t, img, 1, 0, {100, 100, 100, 200})
}

@(test)
repeat_wrap_tiles_the_texture :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	texels := [8]u8{255, 0, 0, 255, 0, 255, 0, 255} // red | green
	tiled, _ := ren.texture_create(&f.renderer, {width = 2, height = 1, format = .RGBA8, filter = .Nearest, wrap = .Repeat, pixels = texels[:]})
	clamped, _ := ren.texture_create(&f.renderer, {width = 2, height = 1, format = .RGBA8, filter = .Nearest, wrap = .Clamp, pixels = texels[:]})
	target := make_target(t, &f, 4, 2)

	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, target, {4, 2})
	two := ren.UV_Rect{{0, 0}, {2, 1}} // the texture twice across
	ren.draw_image(dl, tiled, {0, 0, 4, 1}, uv = two)
	ren.draw_image(dl, clamped, {0, 1, 4, 1}, uv = two)
	ren.pop_target(dl)
	finish(t, &f)
	img := read(t, &f, target)
	expect_pixel(t, img, 0, 0, {255, 0, 0, 255}) // red green red green
	expect_pixel(t, img, 1, 0, {0, 255, 0, 255})
	expect_pixel(t, img, 2, 0, {255, 0, 0, 255})
	expect_pixel(t, img, 3, 0, {0, 255, 0, 255})
	expect_pixel(t, img, 0, 1, {255, 0, 0, 255}) // clamped: red green, then the last texel (green) for the rest
	expect_pixel(t, img, 1, 1, {0, 255, 0, 255})
	expect_pixel(t, img, 2, 1, {0, 255, 0, 255})
	expect_pixel(t, img, 3, 1, {0, 255, 0, 255})
}

@(test)
built_in_materials_draw_into_float_targets_too :: proc(t: ^testing.T) {
	f: Fixture
	if !open_fixture(t, &f) {
		return
	}
	defer close_fixture(&f)
	target, ok := ren.texture_create(&f.renderer, {width = 2, height = 2, format = .RGBA16F, filter = .Nearest, use = {.Render_Target}})
	testing.expect(t, ok)
	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, target, {2, 2})
	ren.draw_rect(dl, {0, 0, 2, 2}, ren.Color{255, 0, 0, 255})
	ren.pop_target(dl)
	finish(t, &f)
	img := read(t, &f, target)
	half := ([^][4]f16)(raw_data(img.pixels))[0]
	testing.expect_value(t, [4]f32{f32(half[0]), f32(half[1]), f32(half[2]), f32(half[3])}, [4]f32{1, 0, 0, 1})
	_ = runtime.Allocator{}
}
