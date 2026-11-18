// A library of the named assets a program draws with: custom shaders and TrueType fonts. The ones that come with iv_system (builtin.odin) and the
// ones the program brings are the same thing: one map of shaders by name, one map of fonts by name, filled by the same procedures; nothing marks an
// entry as built in, and a program can replace any of them by adding one of the same name.
//
//   lib: ren_assets.Library
//   ren_assets.library_init(&lib)
//   ren_assets.add_builtins(&lib, &renderer)                        // bloom, blur, neon ... and the fonts that come with the library
//   my, _ := ren_assets.shader_add(&lib, &renderer, "my_wobble", {spirv = MY_SPV[:], uniform_size = size_of(My_Uniforms), sampler_count = 1})
//   ren_assets.shader_add_file(&lib, &renderer, "tint", "assets/tint.spv", uniform_size = 16, sampler_count = 1)   // a .spv file from disk
//   s, _ := ren_assets.shader_get(&lib, "neon")                      // either kind: just a ren.Shader
//   font := ren_assets.font_make(&lib, &renderer, "orbitron_bold", 18)
//
// A shader of the program's own is made from GLSL with iv_system/tools/glsl_to_spv.py (see ren.Shader_Desc for what the shader may declare), either at
// build time into an Odin file (a SPIR-V array to pass to shader_add) or into .spv files that are loaded at run time.
package ren_assets

import "core:mem"
import "core:os"
import "core:strings"
import ren ".."
import ren_ttf "../ttf"

// A shader of the library. `samplers` are the names of its textures in order (what draw_shader's `textures` are), for documentation and for
// programs that bind by name (sampler_index); it may be empty.
Shader_Entry :: struct {
	name:          string,
	shader:        ren.Shader,
	uniform_size:  int,
	sampler_count: int,
	samplers:      []string,
}

// A font of the library: the bytes of the .ttf file (they must stay as they are: the fonts made from them point into them).
Font_Entry :: struct {
	name:  string,
	data:  []u8,
	owned: bool, // the library made the copy of `data` and frees it
}

Library :: struct {
	shaders:   map[string]Shader_Entry,
	fonts:     map[string]Font_Entry,
	allocator: mem.Allocator,
}

library_init :: proc(lib: ^Library, allocator := context.allocator) {
	lib.allocator = allocator
	lib.shaders = make(map[string]Shader_Entry, allocator)
	lib.fonts = make(map[string]Font_Entry, allocator)
}

// Frees everything the library owns and destroys its shaders in `r` (the renderer they were made for; nil: do not destroy them).
library_destroy :: proc(lib: ^Library, r: ^ren.Renderer) {
	names := make([dynamic]string, context.temp_allocator)
	for name in lib.shaders {
		append(&names, name)
	}
	for name in names {
		shader_remove(lib, r, name)
	}
	clear(&names)
	for name in lib.fonts {
		append(&names, name)
	}
	for name in names {
		font_remove(lib, name)
	}
	delete(lib.shaders)
	delete(lib.fonts)
	lib^ = {}
}

// ---- shaders ------------------------------------------------------------------------------------------------------------------

// Makes the shader and puts it in the library under `name` (replacing, and destroying, one of that name). `samplers` names the textures in order.
// false: the backend could not make it (a backend that cannot run shaders, or the SPIR-V does not fit), and the library is as it was.
shader_add :: proc(lib: ^Library, r: ^ren.Renderer, name: string, desc: ren.Shader_Desc, samplers: []string = nil) -> (ren.Shader, bool) {
	s, ok := ren.shader_create(r, desc)
	if !ok {
		return 0, false
	}
	shader_remove(lib, r, name)
	entry := Shader_Entry {
		name          = strings.clone(name, lib.allocator),
		shader        = s,
		uniform_size  = desc.uniform_size,
		sampler_count = desc.sampler_count,
	}
	if len(samplers) > 0 {
		entry.samplers = make([]string, len(samplers), lib.allocator)
		for n, i in samplers {
			entry.samplers[i] = strings.clone(n, lib.allocator)
		}
	}
	lib.shaders[entry.name] = entry
	return s, true
}

// A shader from the bytes of a SPIR-V file (.spv: little-endian 32-bit words, what glslang writes). The bytes are not kept.
shader_add_spv :: proc(
	lib: ^Library,
	r: ^ren.Renderer,
	name: string,
	spv: []u8,
	uniform_size: int,
	sampler_count: int,
	samplers: []string = nil,
) -> (
	ren.Shader,
	bool,
) {
	if len(spv) < 20 || len(spv) % 4 != 0 {
		return 0, false
	}
	words := make([]u32, len(spv) / 4, context.temp_allocator)
	for i in 0 ..< len(words) {
		words[i] = u32(spv[4 * i]) | u32(spv[4 * i + 1]) << 8 | u32(spv[4 * i + 2]) << 16 | u32(spv[4 * i + 3]) << 24
	}
	if words[0] != 0x07230203 { // (the magic number of SPIR-V)
		return 0, false
	}
	return shader_add(lib, r, name, {spirv = words, uniform_size = uniform_size, sampler_count = sampler_count}, samplers)
}

// A shader from a .spv file on disk.
shader_add_file :: proc(
	lib: ^Library,
	r: ^ren.Renderer,
	name: string,
	path: string,
	uniform_size: int,
	sampler_count: int,
	samplers: []string = nil,
) -> (
	ren.Shader,
	bool,
) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return 0, false
	}
	return shader_add_spv(lib, r, name, data, uniform_size, sampler_count, samplers)
}

shader_get :: proc(lib: ^Library, name: string) -> (ren.Shader, bool) {
	if e, ok := lib.shaders[name]; ok {
		return e.shader, true
	}
	return 0, false
}

// The entry of a shader (its uniform size, sampler count and sampler names), nil if there is none by that name.
shader_info :: proc(lib: ^Library, name: string) -> ^Shader_Entry {
	if _, ok := lib.shaders[name]; !ok {
		return nil
	}
	return &lib.shaders[name]
}

// The index of the sampler called `sampler` in the shader `name` (the place of its texture in draw_shader's list), -1 if there is none.
sampler_index :: proc(lib: ^Library, name, sampler: string) -> int {
	if e := shader_info(lib, name); e != nil {
		for n, i in e.samplers {
			if n == sampler {
				return i
			}
		}
	}
	return -1
}

// Takes a shader out of the library and destroys it in `r` (nil: only forgets it).
shader_remove :: proc(lib: ^Library, r: ^ren.Renderer, name: string) {
	e, ok := lib.shaders[name]
	if !ok {
		return
	}
	delete_key(&lib.shaders, name)
	if r != nil {
		ren.shader_destroy(r, e.shader)
	}
	for n in e.samplers {
		delete(n, lib.allocator)
	}
	delete(e.samplers, lib.allocator)
	delete(e.name, lib.allocator)
}

// ---- fonts ------------------------------------------------------------------------------------------------------------------

// Puts a font in the library under `name` (replacing one of that name). `ttf` must stay as it is while the library and the fonts made from it live
// (a #load is fine), unless `copy` is true: then the library keeps a copy of its own.
font_add :: proc(lib: ^Library, name: string, ttf: []u8, copy := false) {
	font_remove(lib, name)
	entry := Font_Entry {
		name = strings.clone(name, lib.allocator),
		data = ttf,
	}
	if copy {
		entry.data = make([]u8, len(ttf), lib.allocator)
		for b, i in ttf {
			entry.data[i] = b
		}
		entry.owned = true
	}
	lib.fonts[entry.name] = entry
}

// A font from a .ttf file on disk (the library keeps the bytes).
font_add_file :: proc(lib: ^Library, name: string, path: string) -> bool {
	data, err := os.read_entire_file(path, lib.allocator)
	if err != nil {
		return false
	}
	font_add(lib, name, data)
	e := &lib.fonts[name]
	e.owned = true
	return true
}

// The bytes of a font file of the library.
font_data :: proc(lib: ^Library, name: string) -> ([]u8, bool) {
	if e, ok := lib.fonts[name]; ok {
		return e.data, true
	}
	return nil, false
}

// A font of the library made at `em_px` pixels (see ren_ttf.create_em), nil if there is none by that name. Destroy it with ren_ttf.destroy.
font_make :: proc(lib: ^Library, r: ^ren.Renderer, name: string, em_px: f32, atlas_size := 1024, fallback: rune = '?') -> ^ren.Font {
	data, ok := font_data(lib, name)
	if !ok {
		return nil
	}
	f, made := ren_ttf.create_em(r, data, em_px, atlas_size, fallback)
	return f if made else nil
}

font_remove :: proc(lib: ^Library, name: string) {
	e, ok := lib.fonts[name]
	if !ok {
		return
	}
	delete_key(&lib.fonts, name)
	if e.owned {
		delete(e.data, lib.allocator)
	}
	delete(e.name, lib.allocator)
}
