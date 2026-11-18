package ren

import "core:hash/xxhash"
import "core:math"
import "core:slice"
import ui "../../iv_ui"

// ---------------------------------------------------------------------------
// The draw list: where every drawing call goes. It only RECORDS (vertices, indices, commands); it makes no GPU call, needs
// no window and no backend, so it can be tested on its own and every backend draws exactly what it holds.
//
//   dl := ren.begin_frame(&r, clear = ren.BLACK)
//   ren.push_clip(dl, panel); defer ren.pop_clip(dl)         // state that NESTS is a stack: clip, offset, tint, blend, target
//   ren.draw_rect(dl, button, ren.color_f(1, 0, 0))          // what is DRAWN is a typed call: the arguments are the meaning
//   ren.draw_text(dl, font, "Save", {button.x + 4, button.y}, ren.WHITE)
//   ren.end_frame(&r)
//
// Coordinates are pixels of the target (the window, or a texture pushed with push_target), y down, origin top left.
// ---------------------------------------------------------------------------

Target_Entry :: struct {
	texture: Texture,
	size:    [2]int,
}

Draw_List :: struct {
	vertices:     [dynamic]Vertex,
	indices:      [dynamic]u32,
	commands:     [dynamic]Command,
	uniform_data:    [dynamic]u8, // the uniforms of the custom shader commands, each at a multiple of UNIFORM_ALIGN
	shader_textures: [dynamic]Texture, // the textures of the custom shader commands
	clear:        Maybe(Color), // clear the window with this before drawing; nil = keep what is there
	width:        int, // the window's size in pixels (set by draw_list_reset)
	height:       int,

	// state stacks: every entry is the ACCUMULATED value (a pushed offset is already added to the one below)
	clip_stack:   [dynamic]ui.Rect, // in target pixels
	offset_stack: [dynamic]Vec2,
	tint_stack:   [dynamic]Color,
	blend_stack:  [dynamic]Blend,
	target_stack: [dynamic]Target_Entry,

	// how many pops had nothing to pop (a bug in the program: they are counted, not crashed on)
	underflows:   int,
}

draw_list_init :: proc(dl: ^Draw_List, allocator := context.allocator) {
	dl.vertices = make([dynamic]Vertex, allocator)
	dl.indices = make([dynamic]u32, allocator)
	dl.commands = make([dynamic]Command, allocator)
	dl.uniform_data = make([dynamic]u8, allocator)
	dl.shader_textures = make([dynamic]Texture, allocator)
	dl.clip_stack = make([dynamic]ui.Rect, allocator)
	dl.offset_stack = make([dynamic]Vec2, allocator)
	dl.tint_stack = make([dynamic]Color, allocator)
	dl.blend_stack = make([dynamic]Blend, allocator)
	dl.target_stack = make([dynamic]Target_Entry, allocator)
}

draw_list_destroy :: proc(dl: ^Draw_List) {
	delete(dl.vertices)
	delete(dl.indices)
	delete(dl.commands)
	delete(dl.uniform_data)
	delete(dl.shader_textures)
	delete(dl.clip_stack)
	delete(dl.offset_stack)
	delete(dl.tint_stack)
	delete(dl.blend_stack)
	delete(dl.target_stack)
	dl^ = {}
}

// Empties the list for a new frame (the memory is kept).
draw_list_reset :: proc(dl: ^Draw_List, width, height: int, clear: Maybe(Color) = nil) {
	clear_dynamic_array(&dl.vertices)
	clear_dynamic_array(&dl.indices)
	clear_dynamic_array(&dl.commands)
	clear_dynamic_array(&dl.uniform_data)
	clear_dynamic_array(&dl.shader_textures)
	clear_dynamic_array(&dl.clip_stack)
	clear_dynamic_array(&dl.offset_stack)
	clear_dynamic_array(&dl.tint_stack)
	clear_dynamic_array(&dl.blend_stack)
	clear_dynamic_array(&dl.target_stack)
	dl.clear = clear
	dl.width = width
	dl.height = height
	dl.underflows = 0
}

// A fingerprint of everything the list would draw (its vertices, indices, commands, uniforms, textures, size and clear colour). Two frames with the
// same signature put the same pixels on the screen, so a program that only shows a frame when its signature changed does no GPU work while
// nothing moves. (The contents of the textures are not part of it: a program that changes a texture in place must show the next frame anyway.)
draw_list_signature :: proc(dl: ^Draw_List) -> u64 {
	tail := [4]u64{u64(dl.width), u64(dl.height), 0, 0}
	if c, ok := dl.clear.?; ok {
		tail[2] = 1
		tail[3] = u64(transmute(u32)c)
	}
	h := hash(slice.to_bytes(tail[:]))
	h = mix(h, hash(slice.to_bytes(dl.vertices[:])))
	h = mix(h, hash(slice.to_bytes(dl.indices[:])))
	h = mix(h, hash(slice.to_bytes(dl.commands[:])))
	h = mix(h, hash(dl.uniform_data[:]))
	return mix(h, hash(slice.to_bytes(dl.shader_textures[:])))

	hash :: proc(b: []u8) -> u64 {
		return xxhash.XXH3_64(b) if len(b) > 0 else 0x2545F4914F6CDD1D // (xxhash will not take an empty slice)
	}
	mix :: proc(h, part: u64) -> u64 {
		return (h ~ part) * 0x9E3779B97F4A7C15 + 0x632BE59BD9B4E019
	}
}

// True when every push was popped and no pop was left without a push: what end_frame expects.
draw_list_balanced :: proc(dl: ^Draw_List) -> bool {
	return dl.underflows == 0 &&
		len(dl.clip_stack) == 0 &&
		len(dl.offset_stack) == 0 &&
		len(dl.tint_stack) == 0 &&
		len(dl.blend_stack) == 0 &&
		len(dl.target_stack) == 0
}

// ---- the current state ---------------------------------------------------------------------------------

// The size of the target being drawn into.
target_size :: proc(dl: ^Draw_List) -> [2]int {
	if n := len(dl.target_stack); n > 0 {
		return dl.target_stack[n - 1].size
	}
	return {dl.width, dl.height}
}

current_clip :: proc(dl: ^Draw_List) -> ui.Rect {
	if n := len(dl.clip_stack); n > 0 {
		return dl.clip_stack[n - 1]
	}
	s := target_size(dl)
	return ui.Rect{0, 0, s.x, s.y}
}

current_offset :: proc(dl: ^Draw_List) -> Vec2 {
	if n := len(dl.offset_stack); n > 0 {
		return dl.offset_stack[n - 1]
	}
	return {}
}

current_tint :: proc(dl: ^Draw_List) -> Color {
	if n := len(dl.tint_stack); n > 0 {
		return dl.tint_stack[n - 1]
	}
	return WHITE
}

current_blend :: proc(dl: ^Draw_List) -> Blend {
	if n := len(dl.blend_stack); n > 0 {
		return dl.blend_stack[n - 1]
	}
	return .Alpha
}

current_target :: proc(dl: ^Draw_List) -> Texture {
	if n := len(dl.target_stack); n > 0 {
		return dl.target_stack[n - 1].texture
	}
	return 0
}

// ---- the stacks (state that nests) -------------------------------------------------------------------------

// Moves everything drawn from here on by `by`. Offsets add up.
push_offset :: proc(dl: ^Draw_List, by: Vec2) {
	append(&dl.offset_stack, current_offset(dl) + by)
}

pop_offset :: proc(dl: ^Draw_List) {
	if len(dl.offset_stack) == 0 {
		dl.underflows += 1
		return
	}
	pop(&dl.offset_stack)
}

// Only what is inside `r` (in the current offset's coordinates) shows. Clips nest: the result is the intersection with the
// clip below.
push_clip :: proc(dl: ^Draw_List, r: ui.Rect) {
	off := current_offset(dl)
	abs_rect := ui.translate(r, int(math.round(off.x)), int(math.round(off.y)))
	append(&dl.clip_stack, ui.intersect(abs_rect, current_clip(dl)))
}

pop_clip :: proc(dl: ^Draw_List) {
	if len(dl.clip_stack) == 0 {
		dl.underflows += 1
		return
	}
	pop(&dl.clip_stack)
}

// Everything drawn from here on is multiplied by this color (alpha = opacity). Tints multiply.
push_tint :: proc(dl: ^Draw_List, tint: Color) {
	append(&dl.tint_stack, color_mul(current_tint(dl), tint))
}

pop_tint :: proc(dl: ^Draw_List) {
	if len(dl.tint_stack) == 0 {
		dl.underflows += 1
		return
	}
	pop(&dl.tint_stack)
}

push_blend :: proc(dl: ^Draw_List, b: Blend) {
	append(&dl.blend_stack, b)
}

pop_blend :: proc(dl: ^Draw_List) {
	if len(dl.blend_stack) == 0 {
		dl.underflows += 1
		return
	}
	pop(&dl.blend_stack)
}

// Draws into a texture (created with .Render_Target) of the given size instead of the window. Inside, the offset starts at
// 0 and the clip is the whole texture; tint and blend carry on.
push_target :: proc(dl: ^Draw_List, target: Texture, size: [2]int) {
	append(&dl.target_stack, Target_Entry{target, size})
	append(&dl.offset_stack, Vec2{})
	append(&dl.clip_stack, ui.Rect{0, 0, size.x, size.y})
}

pop_target :: proc(dl: ^Draw_List) {
	if len(dl.target_stack) == 0 {
		dl.underflows += 1
		return
	}
	pop(&dl.target_stack)
	pop_offset(dl)
	pop_clip(dl)
}

// The same pushes with the pop done at the end of the scope (Odin's deferred attributes):
//
//   ren.scope_clip(dl, panel)         // popped when the block that holds this line ends
//
@(deferred_in = _end_clip)
scope_clip :: proc(dl: ^Draw_List, r: ui.Rect) {
	push_clip(dl, r)
}

@(deferred_in = _end_offset)
scope_offset :: proc(dl: ^Draw_List, by: Vec2) {
	push_offset(dl, by)
}

@(deferred_in = _end_tint)
scope_tint :: proc(dl: ^Draw_List, tint: Color) {
	push_tint(dl, tint)
}

@(deferred_in = _end_blend)
scope_blend :: proc(dl: ^Draw_List, b: Blend) {
	push_blend(dl, b)
}

@(deferred_in = _end_target)
scope_target :: proc(dl: ^Draw_List, target: Texture, size: [2]int) {
	push_target(dl, target, size)
}

@(private)
_end_clip :: proc(dl: ^Draw_List, _: ui.Rect) {
	pop_clip(dl)
}
@(private)
_end_offset :: proc(dl: ^Draw_List, _: Vec2) {
	pop_offset(dl)
}
@(private)
_end_tint :: proc(dl: ^Draw_List, _: Color) {
	pop_tint(dl)
}
@(private)
_end_blend :: proc(dl: ^Draw_List, _: Blend) {
	pop_blend(dl)
}
@(private)
_end_target :: proc(dl: ^Draw_List, _: Texture, _: [2]int) {
	pop_target(dl)
}

// ---- emitting ----------------------------------------------------------------------------------------------

// Adds triangles to the list with the current state, and merges them into the last command if its state is the same. `idx`
// are indices into `verts`. Vertices are taken as the caller wrote them (positions local, colors untinted): the offset
// and the tint are applied here.
emit :: proc(dl: ^Draw_List, texture: Texture, material: Material, verts: []Vertex, idx: []u32) {
	emit_command(dl, texture, material, verts, idx, 0, nil, nil)
}

// The same for a command of a custom shader: its uniforms are copied (to the next multiple of UNIFORM_ALIGN of
// uniform_data) and its textures are listed; such a command is never merged into another.
emit_command :: proc(dl: ^Draw_List, texture: Texture, material: Material, verts: []Vertex, idx: []u32, shader: Shader, uniforms: []u8, textures: []Texture) {
	if len(verts) == 0 || len(idx) == 0 {
		return
	}
	off := current_offset(dl)
	tint := current_tint(dl)
	base := u32(len(dl.vertices))
	for v in verts {
		append(&dl.vertices, Vertex{pos = v.pos + off, uv = v.uv, color = color_mul(v.color, tint)})
	}
	first := u32(len(dl.indices))
	for i in idx {
		append(&dl.indices, base + i)
	}

	cmd := Command {
		first_index = first,
		index_count = u32(len(idx)),
		texture     = texture,
		target      = current_target(dl),
		material    = material,
		blend       = current_blend(dl),
		clip        = current_clip(dl),
	}
	if shader != 0 {
		cmd.shader = shader
		for len(dl.uniform_data) % UNIFORM_ALIGN != 0 {
			append(&dl.uniform_data, 0)
		}
		cmd.uniform_offset = u32(len(dl.uniform_data))
		cmd.uniform_size = u32(len(uniforms))
		append(&dl.uniform_data, ..uniforms)
		cmd.texture_first = u32(len(dl.shader_textures))
		cmd.texture_count = u32(len(textures))
		append(&dl.shader_textures, ..textures)
		append(&dl.commands, cmd)
		return
	}
	if n := len(dl.commands); n > 0 {
		last := &dl.commands[n - 1]
		if last.texture == cmd.texture &&
		   last.target == cmd.target &&
		   last.material == cmd.material &&
		   last.blend == cmd.blend &&
		   last.clip == cmd.clip &&
		   last.shader == 0 {
			last.index_count += cmd.index_count
			return
		}
	}
	append(&dl.commands, cmd)
}

@(private)
QUAD_INDICES := [6]u32{0, 1, 2, 0, 2, 3}

// A rectangle of one color.
draw_rect :: proc(dl: ^Draw_List, r: ui.Rect, color: Color) {
	if ui.is_empty(r) || color.a == 0 && current_blend(dl) != .Opaque {
		return
	}
	draw_rect_f(dl, f32(r.x), f32(r.y), f32(r.w), f32(r.h), color)
}

// The same with float coordinates (sub-pixel positions, for smooth movement).
draw_rect_f :: proc(dl: ^Draw_List, x, y, w, h: f32, color: Color) {
	if w <= 0 || h <= 0 {
		return
	}
	v := [4]Vertex {
		{pos = {x, y}, color = color},
		{pos = {x + w, y}, color = color},
		{pos = {x + w, y + h}, color = color},
		{pos = {x, y + h}, color = color},
	}
	emit(dl, 0, .Solid, v[:], QUAD_INDICES[:])
}

// The outline of a rectangle, drawn inside it, `thickness` pixels wide.
draw_rect_outline :: proc(dl: ^Draw_List, r: ui.Rect, thickness: int, color: Color) {
	if ui.is_empty(r) || thickness <= 0 {
		return
	}
	t := min(thickness, min(r.w, r.h) / 2 + 1)
	draw_rect(dl, {r.x, r.y, r.w, t}, color) // top
	draw_rect(dl, {r.x, r.y + r.h - t, r.w, t}, color) // bottom
	draw_rect(dl, {r.x, r.y + t, t, r.h - 2 * t}, color) // left
	draw_rect(dl, {r.x + r.w - t, r.y + t, t, r.h - 2 * t}, color) // right
}

// A texture (or a part of it, `uv`) stretched over `dst`, multiplied by `tint`. `material` is .Textured for a color
// image, .Coverage / .Sdf for a one-channel texture.
draw_image :: proc(dl: ^Draw_List, tex: Texture, dst: ui.Rect, uv := FULL_UV, tint := WHITE, material := Material.Textured) {
	if ui.is_empty(dst) {
		return
	}
	x, y, w, h := f32(dst.x), f32(dst.y), f32(dst.w), f32(dst.h)
	v := [4]Vertex {
		{pos = {x, y}, uv = {uv.min.x, uv.min.y}, color = tint},
		{pos = {x + w, y}, uv = {uv.max.x, uv.min.y}, color = tint},
		{pos = {x + w, y + h}, uv = {uv.max.x, uv.max.y}, color = tint},
		{pos = {x, y + h}, uv = {uv.min.x, uv.max.y}, color = tint},
	}
	emit(dl, tex, material, v[:], QUAD_INDICES[:])
}

draw_triangle :: proc(dl: ^Draw_List, a, b, c: Vec2, color: Color) {
	v := [3]Vertex{{pos = a, color = color}, {pos = b, color = color}, {pos = c, color = color}}
	idx := [3]u32{0, 1, 2}
	emit(dl, 0, .Solid, v[:], idx[:])
}

// A line of the given width (a rotated quad).
draw_line :: proc(dl: ^Draw_List, a, b: Vec2, thickness: f32, color: Color) {
	d := b - a
	length := math.sqrt(d.x * d.x + d.y * d.y)
	if length <= 0 || thickness <= 0 {
		return
	}
	n := Vec2{-d.y, d.x} * (thickness * 0.5 / length) // the normal, half a width long
	v := [4]Vertex {
		{pos = a + n, color = color},
		{pos = b + n, color = color},
		{pos = b - n, color = color},
		{pos = a - n, color = color},
	}
	emit(dl, 0, .Solid, v[:], QUAD_INDICES[:])
}

// A quad drawn by a custom shader (see Shader_Desc) instead of a built-in material: `dst` is where it goes, `uv` is what
// the shader gets as fragTexCoord over it, `tint` is fragColor, `textures` are the sampler2Ds 0 .. n-1 and `uniforms` the
// bytes of its uniform block (copied now: the memory may change at once). The current blend mode and clip apply.
draw_shader :: proc(dl: ^Draw_List, shader: Shader, dst: ui.Rect, textures: []Texture, uniforms: []u8, uv := FULL_UV, tint := WHITE) {
	if ui.is_empty(dst) || shader == 0 {
		return
	}
	x, y, w, h := f32(dst.x), f32(dst.y), f32(dst.w), f32(dst.h)
	v := [4]Vertex {
		{pos = {x, y}, uv = {uv.min.x, uv.min.y}, color = tint},
		{pos = {x + w, y}, uv = {uv.max.x, uv.min.y}, color = tint},
		{pos = {x + w, y + h}, uv = {uv.max.x, uv.max.y}, color = tint},
		{pos = {x, y + h}, uv = {uv.min.x, uv.max.y}, color = tint},
	}
	emit_command(dl, 0, .Solid, v[:], QUAD_INDICES[:], shader, uniforms, textures)
}

// Your own triangles drawn by a custom shader: one command for all of them (the triangles are drawn in order, a later one over
// an earlier one where they overlap). `verts` and `indices` are as in draw_mesh; the shader gets the vertex uv and colour.
draw_shader_mesh :: proc(dl: ^Draw_List, shader: Shader, verts: []Vertex, indices: []u32, textures: []Texture, uniforms: []u8) {
	if shader == 0 {
		return
	}
	emit_command(dl, 0, .Solid, verts, indices, shader, uniforms, textures)
}

// Anything else: your own triangles (`indices` index into `verts`; local positions, untinted colors), with a texture and
// material of your choice. The escape hatch for shapes this file does not have (circles, rounded corners, ...).
draw_mesh :: proc(dl: ^Draw_List, verts: []Vertex, indices: []u32, tex: Texture = 0, material := Material.Solid) {
	emit(dl, tex, material, verts, indices)
}
