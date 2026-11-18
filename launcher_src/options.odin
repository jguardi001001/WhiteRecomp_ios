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
// The page sources (the translated code) take only the compiler and the optimization level; the runtime takes all.
package launcher

import "core:fmt"
import "core:os"
import "core:strings"

OPT_LEVELS :: [4]string{"0 (Fastest)", "1 (Recommended)", "2", "3 (Slowest)"}
FPS_CHOICES :: [2]int{30, 60}

// the highest Cutscene Convert Threads: the cores less one (the game's own)
max_convert_threads :: proc() -> int {return max(1, os.get_processor_core_count() - 1)}

// the flags of the translated pages (gen/src, gen/match)
page_option_flags :: proc() -> []string {
	f := make([dynamic]string, context.temp_allocator)
	append(&f, fmt.tprintf("-O%d", clamp(settings.opt_level, 0, 3)))
	append(&f, "-w", "-fno-strict-aliasing", "-fwrapv")
	if compiler_is_clang() {append(&f, "-fno-addrsig")}
	return f[:]
}

// the flags of the runtime (and xrc_table.c): the options as defines
runtime_option_flags :: proc() -> []string {
	f := make([dynamic]string, context.temp_allocator)
	append(&f, fmt.tprintf("-O%d", clamp(settings.opt_level, 0, 3)), "-w")
	if compiler_is_clang() {append(&f, "-fno-addrsig")}
	append(&f, fmt.tprintf("-DXRC_FRAME_LIMIT=%d", settings.fps == 30 ? 30 : 60))
	if !settings.audio {append(&f, "-DXRC_NO_AUDIO")}
	if !settings.tools {append(&f, "-DXRC_NO_TOOLS")}
	if !settings.vulkan && ODIN_OS == .Windows {append(&f, "-DXRC_D3D9_DEFAULT")}
	if settings.skip_movies {append(&f, "-DXRC_SKIP_MOVIES")}
	append(&f, fmt.tprintf("-DXRC_MOVIE_THREADS=%d", clamp(settings.convert_threads, 1, max_convert_threads())))
	return f[:]
}

compiler_is_clang :: proc() -> bool {
	for c in compilers_get() {if c.path == settings.compiler {return c.clang}}
	return strings.contains(strings.to_lower(settings.compiler, context.temp_allocator), "clang")
}
