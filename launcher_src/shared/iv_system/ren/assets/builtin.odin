package ren_assets

import ren ".."

// ---------------------------------------------------------------------------
// What comes with iv_system: shaders (compiled from shaders/*.fs by build_shaders.bat into shaders_spv.odin) and fonts (fonts/*.ttf, #load-ed, licenses in
// fonts/LICENSES.txt). They are put in a Library by the same procedures a program uses for its own (shader_add, font_add): after add_builtins the
// library does not know which is which. A program that wants only some of them adds those (add_builtin_shader, add_builtin_font); the font data of the
// ones it does not add is not referenced, so it does not go into the program.
//
// Shaders (the uniforms are the structs of shaders_spv.odin; the effects of effects.odin run them for you):
//   "bloom_extract"  texture0 = scene                         keeps what is brighter than a threshold
//   "blur"           texture0                                 separable Gaussian blur, one direction per draw
//   "bloom_combine"  texture0 = scene, bloom0, bloom1         the scene plus two sizes of glow
//   "neon"           texture0 = lines                         neon sign look for lines: white-hot cores and two halos of the lines' own colours
// Fonts: "liberation_sans_bold", "noto_sans_regular", "orbitron_bold".
// ---------------------------------------------------------------------------

Builtin_Shader :: struct {
	name:          string,
	spirv:         []u32,
	uniform_size:  int,
	sampler_count: int,
	samplers:      []string,
}

// The table the builtin shaders are added from (a program may add its own the same way: it is just a list of descriptions).
BUILTIN_SHADERS := [?]Builtin_Shader {
	{"bloom_extract", BLOOM_EXTRACT_SPV[:], BLOOM_EXTRACT_UNIFORM_SIZE, BLOOM_EXTRACT_SAMPLER_COUNT, {"texture0"}},
	{"blur", BLUR_SPV[:], BLUR_UNIFORM_SIZE, BLUR_SAMPLER_COUNT, {"texture0"}},
	{"bloom_combine", BLOOM_COMBINE_SPV[:], BLOOM_COMBINE_UNIFORM_SIZE, BLOOM_COMBINE_SAMPLER_COUNT, {"texture0", "bloom0", "bloom1"}},
	{"neon", NEON_SPV[:], NEON_UNIFORM_SIZE, NEON_SAMPLER_COUNT, {"texture0"}},
}

add_builtin_shader :: proc(lib: ^Library, r: ^ren.Renderer, name: string) -> bool {
	for b in BUILTIN_SHADERS {
		if b.name == name {
			_, ok := shader_add(lib, r, b.name, {spirv = b.spirv, uniform_size = b.uniform_size, sampler_count = b.sampler_count}, b.samplers)
			return ok
		}
	}
	return false
}

// Adds every builtin shader. false if any could not be made (a backend that cannot run shaders makes none); the others are added all the same.
add_builtin_shaders :: proc(lib: ^Library, r: ^ren.Renderer) -> bool {
	all := true
	for b in BUILTIN_SHADERS {
		_, ok := shader_add(lib, r, b.name, {spirv = b.spirv, uniform_size = b.uniform_size, sampler_count = b.sampler_count}, b.samplers)
		all &&= ok
	}
	return all
}

@(private)
FONT_LIBERATION_SANS_BOLD := #load("fonts/LiberationSans-Bold.ttf")
@(private)
FONT_NOTO_SANS_REGULAR := #load("fonts/NotoSans-Regular.ttf")
@(private)
FONT_ORBITRON_BOLD := #load("fonts/Orbitron-Bold.ttf")

BUILTIN_FONT_NAMES :: [?]string{"liberation_sans_bold", "noto_sans_regular", "orbitron_bold"}

add_builtin_font :: proc(lib: ^Library, name: string) -> bool {
	switch name {
	case "liberation_sans_bold":
		font_add(lib, name, FONT_LIBERATION_SANS_BOLD)
	case "noto_sans_regular":
		font_add(lib, name, FONT_NOTO_SANS_REGULAR)
	case "orbitron_bold":
		font_add(lib, name, FONT_ORBITRON_BOLD)
	case:
		return false
	}
	return true
}

add_builtin_fonts :: proc(lib: ^Library) {
	for name in BUILTIN_FONT_NAMES {
		add_builtin_font(lib, name)
	}
}

// Everything: all the builtin shaders and fonts.
add_builtins :: proc(lib: ^Library, r: ^ren.Renderer) -> bool {
	add_builtin_fonts(lib)
	return add_builtin_shaders(lib, r)
}
