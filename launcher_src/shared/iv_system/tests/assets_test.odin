package iv_system_tests

import "core:testing"
import ren "../ren"
import assets "../ren/assets"
import ren_ttf "../ren/ttf"
import vk "../ren/vulkan"

// ---------------------------------------------------------------------------
// The library of shaders and fonts (ren/assets), the builtin ones and the bloom and neon effects made of them. Skipped without Vulkan 1.3.
// ---------------------------------------------------------------------------

@(test)
library_holds_builtin_and_user_shaders_alike :: proc(t: ^testing.T) {
	f: vk.Fixture
	if !vk.open_fixture(t, &f) {
		return
	}
	defer vk.close_fixture(&f)
	lib: assets.Library
	assets.library_init(&lib)
	defer assets.library_destroy(&lib, &f.renderer)

	testing.expect(t, assets.add_builtins(&lib, &f.renderer))
	for name in ([?]string{"bloom_extract", "blur", "bloom_combine", "neon"}) {
		_, ok := assets.shader_get(&lib, name)
		testing.expectf(t, ok, "builtin shader %s", name)
	}
	testing.expect_value(t, assets.sampler_index(&lib, "bloom_combine", "bloom1"), 2)
	testing.expect_value(t, assets.sampler_index(&lib, "bloom_combine", "nothing"), -1)

	// a shader of the program's own goes through the same procedure into the same map; here it is the neon shader's SPIR-V under another name
	neon := assets.shader_info(&lib, "neon")
	if !testing.expect(t, neon != nil) {
		return
	}
	before := len(lib.shaders)
	mine, ok := assets.shader_add(
		&lib,
		&f.renderer,
		"my_neon",
		{spirv = assets.NEON_SPV[:], uniform_size = neon.uniform_size, sampler_count = neon.sampler_count},
		{"lines"},
	)
	testing.expect(t, ok && mine != 0)
	testing.expect_value(t, len(lib.shaders), before + 1)
	testing.expect_value(t, assets.sampler_index(&lib, "my_neon", "lines"), 0)

	// adding under a name that is taken replaces it (a program can override a builtin)
	old, _ := assets.shader_get(&lib, "neon")
	replaced, rok := assets.shader_add(&lib, &f.renderer, "neon", {spirv = assets.NEON_SPV[:], uniform_size = neon.uniform_size, sampler_count = 1})
	testing.expect(t, rok && replaced != 0)
	testing.expect_value(t, len(lib.shaders), before + 1)
	_ = old

	// bad SPIR-V bytes are refused and change nothing
	junk := [?]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
	_, bad := assets.shader_add_spv(&lib, &f.renderer, "junk", junk[:], 0, 0)
	testing.expect(t, !bad)
	_, has_junk := assets.shader_get(&lib, "junk")
	testing.expect(t, !has_junk)

	// a .spv file's bytes load too
	bytes := ([^]u8)(raw_data(assets.BLUR_SPV[:]))[:len(assets.BLUR_SPV) * 4]
	_, spv_ok := assets.shader_add_spv(&lib, &f.renderer, "blur_from_bytes", bytes, assets.BLUR_UNIFORM_SIZE, assets.BLUR_SAMPLER_COUNT)
	testing.expect(t, spv_ok)

	assets.shader_remove(&lib, &f.renderer, "my_neon")
	_, still := assets.shader_get(&lib, "my_neon")
	testing.expect(t, !still)
}

@(test)
library_fonts_are_made_by_name :: proc(t: ^testing.T) {
	f: vk.Fixture
	if !vk.open_fixture(t, &f) {
		return
	}
	defer vk.close_fixture(&f)
	lib: assets.Library
	assets.library_init(&lib)
	defer assets.library_destroy(&lib, &f.renderer)
	assets.add_builtin_fonts(&lib)

	for name in assets.BUILTIN_FONT_NAMES {
		font := assets.font_make(&lib, &f.renderer, name, 20)
		if !testing.expectf(t, font != nil, "font %s", name) {
			continue
		}
		w, _ := ren.font_measure(font, "Hello")
		testing.expectf(t, w > 20 && w < 120, "%s: Hello is %d px wide", name, w)
		ren_ttf.destroy(font)
	}
	testing.expect(t, assets.font_make(&lib, &f.renderer, "nope", 20) == nil)

	// a font of the program's own is in the same map
	data, _ := assets.font_data(&lib, "orbitron_bold")
	assets.font_add(&lib, "mine", data)
	font := assets.font_make(&lib, &f.renderer, "mine", 20)
	testing.expect(t, font != nil)
	ren_ttf.destroy(font)
}

// A scene of 64 x 64: black with a bright square at (8..15, 8..15) (so a flipped read shows up) and a dim gray one that must not glow.
draw_bloom_scene :: proc(dl: ^ren.Draw_List, scene: ren.Texture) {
	ren.push_target(dl, scene, {64, 64})
	ren.push_blend(dl, .Opaque)
	ren.draw_rect(dl, {0, 0, 64, 64}, ren.BLACK)
	ren.draw_rect(dl, {8, 8, 8, 8}, ren.WHITE)
	ren.draw_rect(dl, {40, 40, 8, 8}, ren.Color{60, 60, 60, 255})
	ren.pop_blend(dl)
	ren.pop_target(dl)
}

@(test)
bloom_makes_bright_parts_glow :: proc(t: ^testing.T) {
	f: vk.Fixture
	if !vk.open_fixture(t, &f) {
		return
	}
	defer vk.close_fixture(&f)
	lib: assets.Library
	assets.library_init(&lib)
	defer assets.library_destroy(&lib, &f.renderer)
	assets.add_builtin_shaders(&lib, &f.renderer)

	scene := vk.make_target(t, &f, 64, 64)
	out := vk.make_target(t, &f, 64, 64)
	bloom, ok := assets.bloom_create(&lib, &f.renderer, 64, 64)
	if !testing.expect(t, ok) {
		return
	}
	defer assets.bloom_destroy(&f.renderer, &bloom)

	dl := ren.begin_frame(&f.renderer)
	draw_bloom_scene(dl, scene)
	ren.push_target(dl, out, {64, 64})
	testing.expect(t, assets.bloom_apply(dl, &bloom, scene, {0, 0, 64, 64}))
	ren.pop_target(dl)
	vk.finish(t, &f)

	img := vk.read(t, &f, out)
	// the bright square is still there, and brighter around it than before (black): a glow, at the right place (not mirrored)
	testing.expect(t, vk.pixel(img, 11, 11).r >= 250, "the square stays")
	near_glow := vk.pixel(img, 18, 11) // 3 px right of the square
	testing.expectf(t, near_glow.r > 10, "glow next to the square: %v", near_glow)
	mirrored := vk.pixel(img, 11, 52) // where a flipped glow would be
	testing.expectf(t, mirrored.r < 5, "nothing at the mirrored place: %v", mirrored)
	far := vk.pixel(img, 60, 3)
	testing.expectf(t, far.r < 5, "dark far away: %v", far)
	// the dim square is under the threshold: it does not glow (its surroundings stay black, the square itself is as it was)
	testing.expect(t, vk.pixel(img, 44, 44).r >= 58 && vk.pixel(img, 44, 44).r <= 66)
	testing.expectf(t, vk.pixel(img, 52, 44).r < 8, "no glow round the dim square: %v", vk.pixel(img, 52, 44))
}

@(test)
neon_gives_lines_a_hot_core_and_a_halo :: proc(t: ^testing.T) {
	f: vk.Fixture
	if !vk.open_fixture(t, &f) {
		return
	}
	defer vk.close_fixture(&f)
	lib: assets.Library
	assets.library_init(&lib)
	defer assets.library_destroy(&lib, &f.renderer)
	assets.add_builtin_shaders(&lib, &f.renderer)

	lines := vk.make_target(t, &f, 64, 64)
	out := vk.make_target(t, &f, 64, 64)

	dl := ren.begin_frame(&f.renderer)
	// one horizontal red line, 1 px high, across the upper part (y = 16)
	ren.push_target(dl, lines, {64, 64})
	ren.push_blend(dl, .Opaque)
	ren.draw_rect(dl, {0, 0, 64, 64}, ren.TRANSPARENT)
	ren.pop_blend(dl)
	ren.draw_rect(dl, {4, 16, 56, 1}, ren.Color{255, 0, 0, 255})
	ren.pop_target(dl)
	ren.push_target(dl, out, {64, 64})
	ren.push_blend(dl, .Opaque)
	ren.draw_rect(dl, {0, 0, 64, 64}, ren.BLACK)
	ren.pop_blend(dl)
	params := assets.NEON_DEFAULT
	params.radius = 8
	testing.expect(t, assets.neon_apply(dl, &lib, lines, {64, 64}, {0, 0, 64, 64}, params))
	ren.pop_target(dl)
	vk.finish(t, &f)

	img := vk.read(t, &f, out)
	core := vk.pixel(img, 30, 16)
	testing.expectf(t, core.r >= 250 && core.g > 60, "the core is red pulled toward white: %v", core)
	halo1 := vk.pixel(img, 30, 18) // 2 px away
	halo4 := vk.pixel(img, 30, 21) // 5 px away
	testing.expectf(t, halo1.r > 40 && halo1.r > halo1.g, "a red halo next to the line: %v", halo1)
	testing.expectf(t, halo4.r > 3 && halo4.r < halo1.r, "the halo fades with distance: %v then %v", halo1, halo4)
	above := vk.pixel(img, 30, 14) // symmetric about the line
	testing.expectf(t, abs(int(above.r) - int(halo1.r)) <= 6, "the halo is even on both sides: %v vs %v", above, halo1)
	far := vk.pixel(img, 30, 50)
	testing.expectf(t, far.r < 3, "dark far away: %v", far)
	// the halo does not turn the line another colour: green stays low away from the core
	testing.expect(t, halo4.g <= halo4.r)
}
