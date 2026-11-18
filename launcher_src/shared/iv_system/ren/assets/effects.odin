package ren_assets

import "core:math"
import ren ".."
import ui "../../../iv_ui"

// ---------------------------------------------------------------------------
// Effects made of the library's shaders: they look the shaders up by name in a Library when they run (so a program that adds shaders of its own under the
// names "bloom_extract", "blur", "bloom_combine" or "neon" changes what these effects do), and record their passes in a draw list in order.
// The effects need a renderer that can run custom shaders (Vulkan).
//
// A scene for them is a texture that was drawn into as a render target (ren.Texture_Use.Render_Target):
//   ren.push_target(dl, scene, {w, h});  ... draw the picture ...;  ren.pop_target(dl)
//   ren_assets.bloom_apply(dl, &bloom, scene, window_rect)           // draws the scene with its bright parts glowing, into the target that is current
// ---------------------------------------------------------------------------

@(private)
uniform_bytes :: proc(p: ^$T) -> []u8 {
	return ([^]u8)(p)[:size_of(T)]
}

// ---- bloom ---------------------------------------------------------------------------------------------------------------------

BLOOM_LEVELS :: 2 // sizes of glow: half the scene's size and a quarter of it

Bloom_Params :: struct {
	threshold: f32, // the brightness from which a pixel glows (the largest of r, g, b, 0 to 1)
	knee:      f32, // the width of the soft edge of the threshold
	intensity: [BLOOM_LEVELS]f32, // how much of the tight glow and of the wide one is added
	tint:      [3]f32, // multiplies the glow
	spread:    f32, // how far apart the taps of the blur are (1 = as the filter is; more makes the glow wider and coarser)
}

BLOOM_DEFAULT :: Bloom_Params {
	threshold = 0.65,
	knee      = 0.25,
	intensity = {0.9, 0.7},
	tint      = {1, 1, 1},
	spread    = 1,
}

// The textures of a bloom for scenes of one size (make it again when the scene changes size).
Bloom :: struct {
	lib:   ^Library, // where the shaders are looked up (it must outlive the bloom)
	size:  [BLOOM_LEVELS][2]int,
	a, b:  [BLOOM_LEVELS]ren.Texture, // a level and a texture to blur through
	width: int, // the scene's size
	height: int,
}

bloom_create :: proc(lib: ^Library, r: ^ren.Renderer, width, height: int) -> (b: Bloom, ok: bool) {
	b.lib, b.width, b.height = lib, width, height
	for i in 0 ..< BLOOM_LEVELS {
		div := 2 << uint(i)
		b.size[i] = {max(width / div, 1), max(height / div, 1)}
		desc := ren.Texture_Desc {
			width  = b.size[i].x,
			height = b.size[i].y,
			format = .RGBA8,
			filter = .Linear,
			wrap   = .Clamp,
			use    = {.Render_Target},
		}
		made_a, a_ok := ren.texture_create(r, desc)
		made_b, b_ok := ren.texture_create(r, desc)
		b.a[i], b.b[i] = made_a, made_b
		if !a_ok || !b_ok {
			bloom_destroy(r, &b)
			return {}, false
		}
	}
	return b, true
}

bloom_destroy :: proc(r: ^ren.Renderer, b: ^Bloom) {
	for i in 0 ..< BLOOM_LEVELS {
		ren.texture_destroy(r, b.a[i])
		ren.texture_destroy(r, b.b[i])
	}
	b^ = {}
}

// Draws `scene` into `dst` (a rectangle of the current target) with its bright parts glowing. false: a shader of the effect is missing from the library
// (nothing is drawn).
bloom_apply :: proc(dl: ^ren.Draw_List, b: ^Bloom, scene: ren.Texture, dst: ui.Rect, params := BLOOM_DEFAULT) -> bool {
	extract, e_ok := shader_get(b.lib, "bloom_extract")
	blur, b_ok := shader_get(b.lib, "blur")
	combine, c_ok := shader_get(b.lib, "bloom_combine")
	if !(e_ok && b_ok && c_ok) || b.a[0] == 0 {
		return false
	}
	ren.push_blend(dl, .Opaque)
	defer ren.pop_blend(dl)

	// the bright parts, at half size
	w0, h0 := b.size[0].x, b.size[0].y
	ex := Bloom_Extract_Uniforms {
		threshold = params.threshold,
		knee      = max(params.knee, 0.001),
	}
	ren.push_target(dl, b.a[0], {w0, h0})
	ren.draw_shader(dl, extract, {0, 0, w0, h0}, {scene}, uniform_bytes(&ex))
	ren.pop_target(dl)
	blur_pass(dl, blur, b, 0, params.spread)

	// the same at a quarter: the half-size glow shrunk (the linear filter averages it), blurred twice
	w1, h1 := b.size[1].x, b.size[1].y
	ren.push_target(dl, b.a[1], {w1, h1})
	ren.draw_image(dl, b.a[0], {0, 0, w1, h1}, ren.FULL_UV, ren.WHITE, .Textured)
	ren.pop_target(dl)
	blur_pass(dl, blur, b, 1, params.spread)
	blur_pass(dl, blur, b, 1, params.spread * 1.5)

	cu := Bloom_Combine_Uniforms {
		intensity0 = params.intensity[0],
		intensity1 = params.intensity[1],
		tint       = params.tint,
	}
	ren.draw_shader(dl, combine, dst, {scene, b.a[0], b.a[1]}, uniform_bytes(&cu))
	return true
}

// One horizontal and one vertical blur of level `i` (the result is back in b.a[i]).
@(private)
blur_pass :: proc(dl: ^ren.Draw_List, blur: ren.Shader, b: ^Bloom, i: int, spread: f32) {
	w, h := b.size[i].x, b.size[i].y
	hu := Blur_Uniforms {
		step_uv = {spread / f32(w), 0},
	}
	ren.push_target(dl, b.b[i], {w, h})
	ren.draw_shader(dl, blur, {0, 0, w, h}, {b.a[i]}, uniform_bytes(&hu))
	ren.pop_target(dl)
	vu := Blur_Uniforms {
		step_uv = {0, spread / f32(h)},
	}
	ren.push_target(dl, b.a[i], {w, h})
	ren.draw_shader(dl, blur, {0, 0, w, h}, {b.b[i]}, uniform_bytes(&vu))
	ren.pop_target(dl)
}

// ---- neon -----------------------------------------------------------------------------------------------------------------------

Neon_Params :: struct {
	radius:     f32, // how far the wide halo reaches, in px of the lines' texture (the tight one is a quarter of it)
	tight_gain: f32, // how bright the tight halo is
	wide_gain:  f32, // how bright the wide halo is
	core:       f32, // how white the lines themselves go (0 = their own colour, 1 = white)
	saturation: f32, // more than 1: the halos are more vivid than the lines
	flicker:    f32, // multiplies the halos: 1 steady (see neon_flicker)
}

NEON_DEFAULT :: Neon_Params {
	radius     = 10,
	tight_gain = 0.85,
	wide_gain  = 0.75,
	core       = 0.5,
	saturation = 1.3,
	flicker    = 1,
}

// The neon look for `lines`, a texture (`size` px) of lines drawn into a render target that was cleared to transparent (make it with the Linear
// filter: the halos sample between its texels): draws the result into `dst`
// of the current target, with `blend` (Premultiplied: over what is there; Opaque: replacing it). false: the shader is missing from the library.
neon_apply :: proc(
	dl: ^ren.Draw_List,
	lib: ^Library,
	lines: ren.Texture,
	size: [2]int,
	dst: ui.Rect,
	params := NEON_DEFAULT,
	blend := ren.Blend.Premultiplied,
) -> bool {
	neon, ok := shader_get(lib, "neon")
	if !ok || size.x <= 0 || size.y <= 0 {
		return false
	}
	u := Neon_Uniforms {
		texel      = {1 / f32(size.x), 1 / f32(size.y)},
		radius     = params.radius,
		tight_gain = params.tight_gain,
		wide_gain  = params.wide_gain,
		core       = params.core,
		saturation = params.saturation,
		flicker    = params.flicker,
	}
	ren.push_blend(dl, blend)
	ren.draw_shader(dl, neon, dst, {lines}, uniform_bytes(&u))
	ren.pop_blend(dl)
	return true
}

// A flicker for Neon_Params.flicker at `time` seconds: mostly 1, with a quick irregular shimmer of up to `amount` (a few hundredths: a hum; more: a
// tube that is failing).
neon_flicker :: proc(time: f32, amount: f32 = 0.06) -> f32 {
	n := math.sin_f32(time * 37.1) * math.sin_f32(time * 11.7 + 1.3) + 0.5 * math.sin_f32(time * 91.7)
	return 1 - amount * clamp(n * 0.5 + 0.5, 0, 1)
}
