package ren

import ui "../../iv_ui"

// ---------------------------------------------------------------------------
// The plain data of the renderer: what a color is, what a vertex is, what a draw command is. Nothing here knows a GPU
// or a window. The draw list (draw_list.odin) fills these, a backend (Vulkan, later OpenGL and a CPU one) consumes them.
// ---------------------------------------------------------------------------

Vec2 :: [2]f32

Color :: [4]u8 // r, g, b, a; not premultiplied

WHITE :: Color{255, 255, 255, 255}
BLACK :: Color{0, 0, 0, 255}
TRANSPARENT :: Color{0, 0, 0, 0}

// A color from floats (0 .. 1, clamped).
color_f :: proc "contextless" (r, g, b: f32, a: f32 = 1) -> Color {
	to_u8 :: proc "contextless" (v: f32) -> u8 {
		return u8(clamp(v, 0, 1) * 255 + 0.5)
	}
	return Color{to_u8(r), to_u8(g), to_u8(b), to_u8(a)}
}

// Component-wise product (each channel a * b / 255): tinting a color with another.
color_mul :: proc "contextless" (a, b: Color) -> Color {
	m :: proc "contextless" (x, y: u8) -> u8 {
		return u8((int(x) * int(y) + 127) / 255)
	}
	return Color{m(a.r, b.r), m(a.g, b.g), m(a.b, b.b), m(a.a, b.a)}
}

// The one vertex format. Rectangles, text, sprites and lines all become triangles made of these (20 bytes each).
Vertex :: struct {
	pos:   Vec2, // in pixels of the target, after offsets
	uv:    Vec2, // 0 .. 1 in the texture (ignored by .Solid)
	color: Color, // already tinted
}

// How what is drawn mixes with what is there.
Blend :: enum u8 {
	Alpha, // src.rgb * src.a + dst.rgb * (1 - src.a)
	Opaque, // src replaces dst
	Additive, // dst + src.rgb * src.a
	Premultiplied, // src.rgb + dst.rgb * (1 - src.a): for a source whose colours already have its alpha in them (what Alpha leaves in a transparent target)
	Modulate, // dst.rgb * src.rgb, alpha unchanged: dimming what is there (a source of (k, k, k) makes it k of itself)
}

// What the fragment stage does. A fixed set on purpose (no user shaders in the public API): every backend, the CPU one
// included, can implement all of them, so a program looks the same wherever it runs.
Material :: enum u8 {
	Solid, // the vertex color; the texture is ignored
	Textured, // the texture's rgba times the vertex color
	Coverage, // a one-channel texture (R8) is the alpha: vertex color with alpha * coverage (bitmap fonts)
	Sdf, // a one-channel signed distance field: smoothed edge (resolution-independent text)
}

// ---- handles ---------------------------------------------------------------------------------------------

// What a backend gives out for textures: an index and a generation packed in a u32, so that a destroyed texture's
// handle is refused (stale) instead of pointing at whatever took its slot. 0 is "none". See handle.odin.
Texture :: distinct u32

Pixel_Format :: enum u8 {
	RGBA8, // 4 bytes per pixel
	R8, // 1 byte per pixel: coverage or distance (.Coverage, .Sdf), or a gray
	RG8, // 2 bytes per pixel (a gray and an alpha, for instance)
	RGBA16F, // 8 bytes per pixel: four half floats (IEEE binary16), for simulation textures
	RGBA32F, // 16 bytes per pixel: four floats
}

// What happens to a texture coordinate outside 0 .. 1.
Wrap :: enum u8 {
	Clamp, // the edge texel
	Repeat, // the texture tiles
}

Filter :: enum u8 {
	Nearest,
	Linear,
}

Texture_Use :: enum u8 {
	Render_Target, // can be drawn into (push_target)
	Dynamic, // will be updated often (texture_update)
}

Texture_Desc :: struct {
	width, height: int,
	format:        Pixel_Format,
	filter:        Filter,
	wrap:          Wrap,
	use:           bit_set[Texture_Use;u8],
	pixels:        []u8, // the first contents (width * height * bytes per pixel, rows from the top); empty = undefined/black
}

pixel_size :: proc "contextless" (f: Pixel_Format) -> int {
	switch f {
	case .RGBA8:
		return 4
	case .R8:
		return 1
	case .RG8:
		return 2
	case .RGBA16F:
		return 8
	case .RGBA32F:
		return 16
	}
	return 0
}

// A rectangle of a texture, in 0 .. 1.
UV_Rect :: struct {
	min, max: Vec2,
}

FULL_UV :: UV_Rect{{0, 0}, {1, 1}}

// The texture rectangle `src` (in texels) of a texture of w * h texels, as UVs.
uv_rect :: proc "contextless" (src: ui.Rect, tex_w, tex_h: int) -> UV_Rect {
	if tex_w <= 0 || tex_h <= 0 {
		return FULL_UV
	}
	fw, fh := f32(tex_w), f32(tex_h)
	return UV_Rect{{f32(src.x) / fw, f32(src.y) / fh}, {f32(src.x + src.w) / fw, f32(src.y + src.h) / fh}}
}

// ---- custom shaders ------------------------------------------------------------------------------------------------

// A fragment shader of the program's own, drawn with draw_shader (see draw_list.odin). Made from SPIR-V by shader_create.
// The built-in materials are the ones a backend of every kind can draw; a custom shader is a promise only some can keep
// (the Vulkan backend can; a CPU backend cannot run a shader), so a program that uses them needs such a backend.
Shader :: distinct u32

// The most textures one custom shader can sample.
MAX_SHADER_TEXTURES :: 16

// How custom shaders see the world, in GLSL (compiled to SPIR-V by the program; iv_system/tools/glsl_to_spv.py does it for
// shaders written the way raylib's are):
//   layout(location = 0) in vec2 fragTexCoord;   the UV of the quad at this pixel
//   layout(location = 1) in vec4 fragColor;      the vertex colour (tinted)
//   layout(location = 0) out vec4 finalColor;
//   layout(set = 0, binding = 0, scalar) uniform Uniforms { ... };         `uniform_size` bytes, packed like C (scalar layout)
//   layout(set = 1, binding = N) uniform sampler2D name;                   the N-th texture of draw_shader's list
// gl_FragCoord is the pixel of the target (+ 0.5), counted from the top left like every other row in ren.
Shader_Desc :: struct {
	spirv:         []u32, // the fragment shader
	uniform_size:  int, // bytes of the uniform block, 0 for none
	sampler_count: int, // sampler2D bindings 0 .. count - 1
}

// ---- commands --------------------------------------------------------------------------------------------

// One batch: a run of the index buffer that is drawn with one state. The draw list merges neighbours with the same state,
// so a backend issues one draw call per command.
Command :: struct {
	first_index: u32,
	index_count: u32,
	texture:     Texture, // 0 = none (.Solid)
	target:      Texture, // 0 = the window
	material:    Material,
	blend:       Blend,
	clip:        ui.Rect, // in pixels of the target, already inside it

	// a custom shader draw (draw_shader): `material` and `texture` are not used. Such a command is never merged with another.
	shader:         Shader, // 0 = a built-in material
	uniform_offset: u32, // where its uniforms are in Draw_List.uniform_data (aligned to UNIFORM_ALIGN)
	uniform_size:   u32,
	texture_first:  u32, // where its textures are in Draw_List.shader_textures
	texture_count:  u32,
}

// Where each command's uniforms start in Draw_List.uniform_data: a multiple of this (the largest alignment a GPU asks of the
// offset of a dynamic uniform buffer).
UNIFORM_ALIGN :: 256
