// The build options (the Options tab; kept in settings.txt) and what they make of the game's build:
//   Compiler                  the C compiler (deps.odin finds them; Clang first: it makes the faster game)
//   Optimization Level        -O0 (the fastest build, the slowest game) .. -O3; 1 is the default
//   Audio                     OFF: -DXRC_NO_AUDIO -- no sound output, no mixing, no movie audio thread, no XAudio2
//                             (the game's own audio engine is a silent stand-in that only keeps its time)
//   Debug & Profile Tools     OFF: -DXRC_NO_TOOLS -- the XRC_PROFILE / XRC_TRACE_* / log switches cannot be turned on,
//                             nothing is printed (src/runtime/xrc_quiet.h) and on Windows there is no console window;
//                             ON: stack dumps and the profiler walk the guest's frame chain for every caller (free);
//                             a build with -DXRC_DEEP_STACKS (pages and runtime: tools/xrc_build.sh XRC_CFLAGS / XRC_DEFS)
//                             records each call instead -- exact, but ~35% slower, so not the launcher's
//   FPS                       -DXRC_FRAME_LIMIT=30|60
//   Graphics Driver           Vulkan, the default everywhere (the launcher always builds it in: -DXRC_VULKAN);
//                             D3D9 (Windows only): -DXRC_D3D9_DEFAULT -- the system's Direct3D 9, which is broken
//                             for now (the cutscene after the first fight never plays)
//   Cutscenes                 Auto-skip: -DXRC_SKIP_MOVIES (every movie skipped; the background conversion goes on)
//   Cutscene Convert Threads  -DXRC_MOVIE_THREADS=N: the CPUs and encoder threads of the background conversion;
//                             Convert Movies (movies.odin) runs the converter with as many (--threads N)
//   Graphics                  a preset of the three below (FXAA always): Ultrafast (no shadows, no anti-aliasing), Fast
//                             (512 shadows, 1x FXAA: off), Fancy (the default: 1024, 4x FXAA), Ultrafancy (8192, 8x
//                             FXAA); or Custom, which shows the three (indented) and keeps them as set
//   Shadow Resolution         the game's own arguments, as the retail launcher passes them: -Shadow=512..8192 (the
//   Anti-Aliasing             game's default 1024; Off: -Shadow=512 and XRC_NO_SHADOWS=1, nothing drawn into the
//                             shadow maps) and -MSAA=0|2|4|8 -- in WhiteRecomp.cfg (XRC_GAME_ARGS), not the build: a
//                             change rewrites the .cfg of a built game at once (build_game.odin). Anti-aliasing is two
//                             settings: Method MSAA (the game's -MSAA=Quality) or FXAA (the default: -MSAA=0 and
//                             XRC_FXAA=Quality, a filter on the 3D image before the HUD -- vk_d3d9.c), Quality 1x (off),
//                             2x, 4x (the default), 8x
//   Memory                    4 GB (the default) or 2 GB: the guest address space the game runs in; 2 GB is what the
//                             original exe gets (not large-address-aware): XRC_GUEST_2GB=1 in WhiteRecomp.cfg, no
//                             Build needed (src/runtime/xrc_rt.h's layout)
//   Experimental Optimizations -DXRC_EXPERIMENTAL: less-tested optimizations that may break things (xrc_rt.h)
//   Link-Time Optimization    -flto (Clang: -flto=thin, on Windows linked with lld; GCC: -flto=auto): optimizing
//                             across files
// Always: -march=native (the build runs on the machine that plays it) and -ffast-math -fno-associative-math when
// compiling (not linking: no flush-to-zero for the whole process; the x86 semantics the translated code needs -- NaN
// compares, conversions -- do not depend on it: src/include/xrc.h tests NaN on the bits; reassociation stays off: it
// cancels the game's own add-and-subtract rounding tricks, and the title menu disappears); on Linux without the distributions' hardening defaults
// (PIE, CET, stack protector: costs, and nothing to protect here)
// The page sources (the translated code) take only the compiler and the optimization level; the runtime takes all.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

OPT_LEVELS :: [4]string{"0 (Fastest)", "1 (Recommended)", "2", "3 (Slowest)"}
FPS_CHOICES :: [2]int{30, 60}

// the highest Cutscene Convert Threads: the cores less one (the game's own)
max_convert_threads :: proc() -> int {return max(1, os.get_processor_core_count() - 1)}

// the flags of every unit (pages and runtime): the host CPU, fast math, LTO, no Linux hardening
common_flags :: proc() -> []string {
	f := make([dynamic]string, context.temp_allocator)
	when ODIN_ARCH == .amd64 {append(&f, "-march=native")} else {append(&f, "-mcpu=native")}
	append(&f, "-ffast-math", "-fno-associative-math") // (reassociation folds the game's own rounding tricks: a broken title menu)
	when ODIN_OS == .Linux {append(&f, "-fno-pie", "-fcf-protection=none", "-fno-stack-protector")}
	if lto_on() {append(&f, lto_flag())}
	return f[:]
}

// the link's own: LTO (the optimization happens there), no PIE on Linux
link_option_flags :: proc() -> []string {
	f := make([dynamic]string, context.temp_allocator)
	when ODIN_OS == .Linux {append(&f, "-no-pie")}
	if lto_on() {
		append(&f, lto_flag(), fmt.tprintf("-O%d", clamp(settings.opt_level, 0, 3)))
		when ODIN_OS == .Windows {if compiler_is_clang() {append(&f, "-fuse-ld=lld")}}
	}
	return f[:]
}

lto_flag :: proc() -> string {return compiler_is_clang() ? "-flto=thin" : "-flto=auto"}

// Link-Time Optimization on and possible: on Windows Clang's needs LLVM's linker (lld) beside it (MinGW's GNU ld
// cannot read its objects); on Linux GNU ld reads them through LLVM's plugin
lto_on :: proc() -> bool {
	if !settings.lto {return false}
	when ODIN_OS != .Windows {return true}
	if !compiler_is_clang() {return true}
	return lld_path() != ""
}

lld_path :: proc() -> string {
	dir := filepath.dir(settings.compiler)
	for n in ([]string{"ld.lld.exe", "ld.lld"}) {
		if p := pjoin({dir, n}, context.temp_allocator); file_exists(p) {return p}
	}
	return ""
}

// the flags of the translated pages (gen/src, gen/match)
page_option_flags :: proc() -> []string {
	f := make([dynamic]string, context.temp_allocator)
	append(&f, fmt.tprintf("-O%d", clamp(settings.opt_level, 0, 3)))
	append(&f, ..common_flags())
	append(&f, "-w", "-fno-strict-aliasing", "-fwrapv")
	if compiler_is_clang() {append(&f, "-fno-addrsig")}
	return f[:]
}

// the flags of the runtime (and xrc_table.c): the options as defines
runtime_option_flags :: proc() -> []string {
	f := make([dynamic]string, context.temp_allocator)
	append(&f, fmt.tprintf("-O%d", clamp(settings.opt_level, 0, 3)), "-w")
	append(&f, ..common_flags())
	if compiler_is_clang() {append(&f, "-fno-addrsig")}
	append(&f, fmt.tprintf("-DXRC_FRAME_LIMIT=%d", settings.fps == 30 ? 30 : 60))
	if !settings.audio {append(&f, "-DXRC_NO_AUDIO")}
	if !settings.tools {append(&f, "-DXRC_NO_TOOLS")}
	if !settings.vulkan && ODIN_OS == .Windows {append(&f, "-DXRC_D3D9_DEFAULT")}
	if settings.skip_movies {append(&f, "-DXRC_SKIP_MOVIES")}
	if settings.experimental {append(&f, "-DXRC_EXPERIMENTAL")}
	append(&f, fmt.tprintf("-DXRC_MOVIE_THREADS=%d", clamp(settings.convert_threads, 1, max_convert_threads())))
	return f[:]
}

SHADOW_CHOICES :: [6]int{0, 512, 1024, 2048, 4096, 8192} // (8192: the most the retail launcher offers)
AA_QUALITIES :: [4]int{1, 2, 4, 8}

// Graphics: presets of Shadow Resolution and Anti-aliasing (FXAA always), or Custom -- those three options as set
Graphics_Preset :: struct {
	shadow_res, aa_quality: int,
}
GRAPHICS_ULTRAFAST :: 0
GRAPHICS_FAST :: 1
GRAPHICS_FANCY :: 2
GRAPHICS_ULTRAFANCY :: 3
GRAPHICS_CUSTOM :: 4
GRAPHICS_PRESETS :: [4]Graphics_Preset {
	{shadow_res = 0, aa_quality = 1}, // Ultrafast: no shadows, no anti-aliasing
	{shadow_res = 512, aa_quality = 1}, // Fast: 512 shadows, 1x FXAA (off)
	{shadow_res = 1024, aa_quality = 4}, // Fancy (the default: the game's own shadow size): 4x FXAA
	{shadow_res = 8192, aa_quality = 8}, // Ultrafancy: the most of both
}
GRAPHICS_KEYS :: [5]string{"ultrafast", "fast", "fancy", "ultrafancy", "custom"} // (in settings.txt)
GRAPHICS_NAMES :: [5]string{"Ultrafast (Worst Quality)", "Fast", "Fancy (DEFAULT)", "Ultrafancy", "Custom"}

// a preset's values into the three options (Custom: as they are)
graphics_apply :: proc() {
	if settings.graphics < 0 || settings.graphics > GRAPHICS_CUSTOM {settings.graphics = GRAPHICS_FANCY}
	if settings.graphics == GRAPHICS_CUSTOM {return}
	p := GRAPHICS_PRESETS
	settings.shadow_res = p[settings.graphics].shadow_res
	settings.aa_fxaa = true
	settings.aa_quality = p[settings.graphics].aa_quality
}

// the preset the three options make, else Custom
graphics_matching :: proc() -> int {
	for p, i in GRAPHICS_PRESETS {
		if settings.shadow_res == p.shadow_res && settings.aa_quality == p.aa_quality && (settings.aa_fxaa || p.aa_quality <= 1) {return i}
	}
	return GRAPHICS_CUSTOM
}

// the game's arguments for the options (XRC_GAME_ARGS)
game_args :: proc() -> string {
	msaa := settings.aa_fxaa || settings.aa_quality <= 1 ? 0 : settings.aa_quality
	return fmt.tprintf("-Shadow=%d -MSAA=%d", settings.shadow_res == 0 ? 512 : settings.shadow_res, msaa)
}

compiler_is_clang :: proc() -> bool {
	for c in compilers_get() {if c.path == settings.compiler {return c.clang}}
	return strings.contains(strings.to_lower(settings.compiler, context.temp_allocator), "clang")
}
