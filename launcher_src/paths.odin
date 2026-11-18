// Where the launcher keeps things, its settings, and finding programs.
//   data dir:  Windows %LOCALAPPDATA%\ff13-launcher, macOS ~/Library/Application Support/ff13-launcher,
//              Linux $XDG_DATA_HOME/ff13-launcher (~/.local/share/ff13-launcher)
//     src/     the bundled sources, unpacked by Build      obj/   their objects
//     (the built game, WhiteRecomp / WhiteRecomp.exe with its WhiteRecomp.cfg, is beside the launcher: build_game.odin)
//     cdrive/  the game's C: drive (its saves and settings: the install itself is mapped in, XRC_GAME_DIR)
//     tools/   bundled tools (bink2mp4.exe)
//     ffmpeg/  (the player's, never written by the launcher) another FFmpeg build to link the game with: lib/ (libavformat.a,
//              libavcodec.a, libswresample.a, libavutil.a) and include/; without it, the bundled one (src/ffmpeg)
//     settings.txt
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""
PATH_SEP :: ";" when ODIN_OS == .Windows else ":"

data_dir: string

init_paths :: proc() {
	base := ""
	when ODIN_OS == .Windows {
		base = os.get_env("LOCALAPPDATA", context.allocator)
	} else when ODIN_OS == .Darwin {
		base = pjoin({os.get_env("HOME", context.temp_allocator), "Library", "Application Support"})
	} else {
		base = os.get_env("XDG_DATA_HOME", context.allocator)
		if base == "" {base = pjoin({os.get_env("HOME", context.temp_allocator), ".local", "share"})}
	}
	if base == "" {base = "."}
	data_dir = pjoin({base, "ff13-launcher"}, context.allocator)
	_ = os.make_directory_all(data_dir)
}

data_path :: proc(parts: ..string) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, data_dir)
	append(&all, ..parts)
	return pjoin(all[:], context.temp_allocator)
}

// filepath.join that returns only the path (in the temp allocator unless told)
pjoin :: proc(parts: []string, allocator := context.temp_allocator) -> string {
	s, _ := filepath.join(parts, allocator)
	return s
}

file_exists :: proc(p: string) -> bool {return os.exists(p) && !os.is_dir(p)}
dir_exists :: proc(p: string) -> bool {return os.is_dir(p)}

// A program's full path: an absolute path that exists, or a name searched for in PATH (with .exe on Windows).
find_program :: proc(name: string) -> string {
	if filepath.is_abs(name) {return strings.clone(name) if file_exists(name) else ""}
	exe := name
	when ODIN_OS == .Windows {
		if !strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".exe") {exe = strings.concatenate({name, ".exe"}, context.temp_allocator)}
	}
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, PATH_SEP, context.temp_allocator) {
		if dir == "" {continue}
		p := pjoin({strings.trim(dir, "\""), exe}, context.temp_allocator)
		if file_exists(p) {return strings.clone(p)}
	}
	return ""
}

// ---------------------------------------------------------------------------------------------- settings
// settings.txt: one "key value" per line. The build options (options.odin) are read when the game is built.
Settings :: struct {
	game_dir:        string, // the install ("FINAL FANTASY XIII", the folder with white_data)
	compiler:        string, // the C compiler's path ("": not chosen yet -- the best one found, Clang first)
	opt_level:       int, // -O0 .. -O3
	audio:           bool,
	tools:           bool, // the debugging and profiling switches (XRC_PROFILE, XRC_TRACE_*, ...)
	fps:             int, // 30 or 60
	vulkan:          bool, // Graphics Driver: Vulkan (else Direct3D 9; Linux: Vulkan always)
	skip_movies:     bool, // Cutscenes: Auto-skip
	convert_threads: int, // Cutscene Convert Threads
}
settings := Settings {
	opt_level       = 1,
	audio           = true,
	fps             = 60,
	vulkan          = ODIN_OS != .Windows,
	convert_threads = 1,
}

load_settings :: proc() {
	d, err := os.read_entire_file(data_path("settings.txt"), context.temp_allocator)
	if err != nil {return}
	for line in strings.split_lines(string(d), context.temp_allocator) {
		k, _, v := strings.partition(strings.trim_space(line), " ")
		v = strings.trim_space(v)
		n, n_ok := strconv.parse_int(v)
		switch k {
		case "game_dir":
			settings.game_dir = strings.clone(v)
		case "compiler":
			settings.compiler = strings.clone(v)
		case "opt_level":
			if n_ok && n >= 0 && n <= 3 {settings.opt_level = n}
		case "audio":
			settings.audio = v != "0"
		case "tools":
			settings.tools = v == "1"
		case "fps":
			if n_ok && (n == 30 || n == 60) {settings.fps = n}
		case "vulkan":
			settings.vulkan = v == "1" || ODIN_OS != .Windows
		case "skip_movies":
			settings.skip_movies = v == "1"
		case "convert_threads":
			if n_ok && n >= 1 {settings.convert_threads = n}
		}
	}
}

save_settings :: proc() {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "game_dir %s\n", settings.game_dir)
	fmt.sbprintf(&b, "compiler %s\n", settings.compiler)
	fmt.sbprintf(&b, "opt_level %d\n", settings.opt_level)
	fmt.sbprintf(&b, "audio %d\n", settings.audio ? 1 : 0)
	fmt.sbprintf(&b, "tools %d\n", settings.tools ? 1 : 0)
	fmt.sbprintf(&b, "fps %d\n", settings.fps)
	fmt.sbprintf(&b, "vulkan %d\n", settings.vulkan ? 1 : 0)
	fmt.sbprintf(&b, "skip_movies %d\n", settings.skip_movies ? 1 : 0)
	fmt.sbprintf(&b, "convert_threads %d\n", settings.convert_threads)
	_ = os.write_entire_file(data_path("settings.txt"), b.buf[:])
}
