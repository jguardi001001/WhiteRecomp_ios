// Build: the game from the bundled sources, with the computer's own C compiler (deps.odin), into the data dir:
//   1. checks the player's ffxiiiimg.exe (the version the code was translated from)
//   2. unpacks the sources (src/: gen/, runtime/, include/, ffmpeg/; files that did not change are left alone)
//   3. compiles them on every core into obj/ (a file whose object is newer than it, and than include/xrc.h, with the
//      same compiler and flags as last time, is not compiled again)
//   4. links WhiteRecomp (.exe) beside the launcher -- with FFmpeg's static libraries (the movies; LGPL 2.1+): the
//      bundled ones (src/ffmpeg), or the player's own build if the data dir has one in ffmpeg/ -- and writes
//      WhiteRecomp.cfg beside it: where the player's install, its exe and the saves are (the game reads it at start,
//      so it starts with a double click)
// The same steps as tools/xrc_build.sh, with the Options tab's choices (options.odin). Windows builds the reference
// target (the real Direct3D 9 -- or Vulkan --, input and windows of Windows); Linux the Vulkan one (an SDL2 window).
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

REFERENCE :: ODIN_OS == .Windows

@(private = "file")
Unit :: struct {
	src, obj: string,
	flags:    []string,
}

@(private = "file")
mtime :: proc(p: string) -> time.Time {
	fi, err := os.stat(p, context.temp_allocator)
	if err != nil {return {}}
	return fi.modification_time
}

build_task :: proc(t: ^Task) {
	game := settings.game_dir
	exe := game_exe(game)
	set_status(t, 0, "Checking the game")
	if ok, why := check_game_exe(exe); !ok {
		logf(t, "%s cannot be used: %s.", exe, why)
		t.failed = true
		return
	}
	cc := dep_get(.Compiler).path
	if cc == "" {
		log_line(t, "No C compiler that can build the game: install one first.")
		t.failed = true
		return
	}
	logf(t, "Game: %s", game)
	logf(t, "Compiler: %s", cc)

	// 2. the sources
	src := data_path("src")
	n := bundle_extract(t, src, {"gen/", "runtime/", "include/", "ffmpeg/", "vulkan/"})
	if n < 0 {t.failed = true; return}
	if cancelled(t) {return}
	logf(t, "Sources: %s (%d files changed)", src, n)

	// 3. compile
	obj := data_path("obj")
	_ = os.make_directory_all(obj)
	inc := pjoin({src, "include"}, context.temp_allocator)
	rt := pjoin({src, "runtime"}, context.temp_allocator)
	units := make([dynamic]Unit, context.temp_allocator)
	page_flags := make([dynamic]string, context.temp_allocator)
	append(&page_flags, ..arch_flags())
	append(&page_flags, ..page_option_flags())
	append(&page_flags, "-I", inc)
	rt_flags := make([dynamic]string, context.temp_allocator)
	append(&rt_flags, ..arch_flags())
	append(&rt_flags, ..runtime_option_flags())
	// FFmpeg: the player's own build in the data dir's ffmpeg/ (LGPL: they may relink the game with a modified FFmpeg;
	// the launcher never writes there), else the bundled one
	ffdir := pjoin({src, "ffmpeg"}, context.temp_allocator)
	if own := data_path("ffmpeg"); file_exists(pjoin({own, "lib", "libavcodec.a"}, context.temp_allocator)) {
		ffdir = own
		logf(t, "FFmpeg: your own build in %s", own)
	}
	append(&rt_flags, "-I", inc, "-I", rt, "-I", pjoin({ffdir, "include"}, context.temp_allocator))
	append(&rt_flags, "-DXRC_VULKAN", "-I", pjoin({src, "vulkan", "include"}, context.temp_allocator))
	when REFERENCE {append(&rt_flags, "-DXRC_REFERENCE")}
	logf(t, "Options: %v", runtime_option_flags())
	if list, err := os.read_all_directory_by_path(pjoin({src, "gen", "src"}, context.temp_allocator), context.temp_allocator); err == nil {
		for e in list {
			if strings.has_suffix(e.name, ".c") {
				append(&units, Unit{e.fullpath, pjoin({obj, strings.concatenate({e.name[:len(e.name) - 2], ".o"}, context.temp_allocator)}, context.temp_allocator), page_flags[:]})
			}
		}
	}
	append(&units, Unit{pjoin({src, "gen", "xrc_table.c"}, context.temp_allocator), pjoin({obj, "xrc_table.o"}, context.temp_allocator), rt_flags[:]})
	// the byte-matched functions (ff xrcmatch): page flags, and the runtime's header (xrc_rt.h)
	match_flags := make([dynamic]string, context.temp_allocator)
	append(&match_flags, ..page_flags[:])
	append(&match_flags, "-I", rt)
	if list, err := os.read_all_directory_by_path(pjoin({src, "gen", "match"}, context.temp_allocator), context.temp_allocator); err == nil {
		for e in list {
			if strings.has_suffix(e.name, ".c") {
				append(&units, Unit{e.fullpath, pjoin({obj, strings.concatenate({"m_", e.name[:len(e.name) - 2], ".o"}, context.temp_allocator)}, context.temp_allocator), match_flags[:]})
			}
		}
	}
	if list, err := os.read_all_directory_by_path(rt, context.temp_allocator); err == nil {
		for e in list {
			if !strings.has_suffix(e.name, ".c") {continue}
			if strings.has_prefix(e.name, "ref_") && !REFERENCE {continue}
			append(&units, Unit{e.fullpath, pjoin({obj, strings.concatenate({"rt_", e.name[:len(e.name) - 2], ".o"}, context.temp_allocator)}, context.temp_allocator), rt_flags[:]})
		}
	}
	slice.sort_by(units[:], proc(a, b: Unit) -> bool {return a.src < b.src})

	// the compiler and flags of the objects there, per kind (the pages / the runtime): different ones rebuild that
	// kind (an option such as Audio rebuilds only the runtime; another compiler, everything)
	page_stamp := fmt.tprintf("%s|%v|%v", cc, page_flags[:], REFERENCE)
	rt_stamp := fmt.tprintf("%s|%v|%v", cc, rt_flags[:], REFERENCE)
	page_stamp_file := pjoin({obj, "pages.stamp"}, context.temp_allocator)
	rt_stamp_file := pjoin({obj, "runtime.stamp"}, context.temp_allocator)
	old_page, _ := os.read_entire_file(page_stamp_file, context.temp_allocator)
	old_rt, _ := os.read_entire_file(rt_stamp_file, context.temp_allocator)
	same_page, same_rt := string(old_page) == page_stamp, string(old_rt) == rt_stamp
	// the headers an object depends on: the pages only xrc.h; the runtime, the table and the matched functions also
	// the runtime's own (src/runtime/*.h: a change there rebuilds them all)
	header := mtime(pjoin({inc, "xrc.h"}, context.temp_allocator))
	rt_header := header
	if hs, err := os.read_all_directory_by_path(rt, context.temp_allocator); err == nil {
		for h in hs {
			if strings.has_suffix(h.name, ".h") && time.diff(rt_header, h.modification_time) > 0 {rt_header = h.modification_time}
		}
	}
	todo := make([dynamic]Unit, context.temp_allocator)
	for u in units {
		ot := mtime(u.obj)
		is_page := raw_data(u.flags) == raw_data(page_flags[:])
		same := same_page if is_page else same_rt
		if raw_data(u.flags) != raw_data(rt_flags[:]) && !is_page {same = same_page} // (the matched functions: the page flags' kind)
		hdr := header if is_page else rt_header
		if same && time.diff(mtime(u.src), ot) > 0 && time.diff(hdr, ot) > 0 {continue}
		append(&todo, u)
	}
	_ = os.remove(page_stamp_file) // (until this build's objects are all made)
	_ = os.remove(rt_stamp_file)
	_ = os.remove(pjoin({obj, "build.stamp"}, context.temp_allocator)) // (the old single stamp)
	logf(t, "Compiling %d of %d files on %d cores", len(todo), len(units), os.get_processor_core_count())
	Job :: struct {
		t:      ^Task,
		cc:     string,
		list:   []Unit,
		next:   int,
		done:   int,
		failed: bool,
	}
	job := Job{t = t, cc = cc, list = todo[:]}
	worker :: proc(th: ^thread.Thread) {
		j := (^Job)(th.data)
		for !cancelled(j.t) && !sync.atomic_load(&j.failed) {
			k := sync.atomic_add(&j.next, 1)
			if k >= len(j.list) {return}
			u := j.list[k]
			args := make([dynamic]string, context.temp_allocator)
			append(&args, j.cc)
			append(&args, ..u.flags)
			append(&args, "-c", u.src, "-o", u.obj)
			out := strings.builder_make(context.temp_allocator)
			_ = os.remove(u.obj)
			code, started := run(j.t, args[:], mode = .Quiet, capture = &out)
			if !cancelled(j.t) && (!started || code != 0) {
				sync.atomic_store(&j.failed, true)
				logf(j.t, "%s does not compile:", filepath.base(u.src))
				lines := strings.split_lines(strings.to_string(out), context.temp_allocator)
				for l, i in lines {
					if i >= 30 {log_line(j.t, "  ..."); break}
					log_line(j.t, l)
				}
			}
			d := sync.atomic_add(&j.done, 1) + 1
			set_status(j.t, 0.1 + 0.8 * f32(d) / f32(len(j.list)), "Compiling: %d of %d (%s)", d, len(j.list), filepath.base(u.src))
			free_all(context.temp_allocator)
		}
	}
	threads := make([dynamic]^thread.Thread, context.temp_allocator)
	for _ in 0 ..< max(1, os.get_processor_core_count()) {
		th := thread.create(worker)
		th.data = &job
		th.init_context = context
		thread.start(th)
		append(&threads, th)
	}
	for th in threads {thread.join(th); thread.destroy(th)}
	if cancelled(t) {return}
	if job.failed {t.failed = true; return}
	_ = os.write_entire_file(page_stamp_file, transmute([]u8)page_stamp)
	_ = os.write_entire_file(rt_stamp_file, transmute([]u8)rt_stamp)

	// 4. link (the objects through a response file: the command line of 230 paths is long on Windows)
	set_status(t, 0.92, "Linking")
	gdir := game_out_dir()
	out_exe := pjoin({gdir, strings.concatenate({GAME_NAME, EXE_SUFFIX}, context.temp_allocator)}, context.temp_allocator)
	rsp := strings.builder_make(context.temp_allocator)
	for u in units {
		p, _ := strings.replace_all(u.obj, "\\", "/", context.temp_allocator)
		fmt.sbprintf(&rsp, "\"%s\"\n", p)
	}
	rsp_file := pjoin({obj, "link.rsp"}, context.temp_allocator)
	_ = os.write_entire_file(rsp_file, rsp.buf[:])
	args := make([dynamic]string, context.temp_allocator)
	append(&args, cc)
	append(&args, ..arch_flags())
	append(&args, "-o", out_exe, strings.concatenate({"@", rsp_file}, context.temp_allocator))
	// FFmpeg (static, in dependency order), then what it needs of the system
	for l in ([]string{"libavformat.a", "libavcodec.a", "libswresample.a", "libavutil.a"}) {
		append(&args, pjoin({ffdir, "lib", l}, context.temp_allocator))
	}
	append(&args, ..FFMPEG_SYS_LIBS)
	append(&args, ..link_libs())
	// Debug & Profile Tools OFF: nothing is printed (xrc_quiet.h), so no console window either (a GUI program; its
	// entry point stays main)
	when ODIN_OS == .Windows {if !settings.tools {append(&args, "-Wl,--subsystem,windows")}}
	if code, started := run(t, args[:]); !started || code != 0 {
		log_line(t, "Linking failed.")
		when ODIN_OS == .Windows {logf(t, "(If WhiteRecomp is running, close it and Build again: Windows cannot replace a running program.)")}
		t.failed = true
		return
	}
	// the movie converter the game runs in the background for movies without their MP4 (Windows: tools/bink2mp4.exe)
	when ODIN_OS == .Windows {_ = bundle_extract(t, data_dir, {"tools/"})}
	if !write_cfg(gdir) {
		logf(t, "Cannot write %s in %s.", GAME_NAME + ".cfg", gdir)
		t.failed = true
		return
	}
	_ = os.make_directory_all(data_path("cdrive"))
	logf(t, "Built %s", out_exe)
	set_status(t, 1, "Built")
}

GAME_NAME :: "WhiteRecomp"

// where the game is built: the launcher's own folder
game_out_dir :: proc() -> string {
	d, err := os.get_executable_directory(context.temp_allocator)
	if err != nil || d == "" {return data_path("game")}
	return d
}

// WhiteRecomp.cfg: the built game's settings, NAME=value lines it puts in its environment at start
// (src/runtime/xrc_rt.c load_cfg): the player's install (its C:\FINAL FANTASY XIII), its exe, the saves (the launcher's
// cdrive), the movie converter and the ffmpeg it runs for the movies without their MP4 (host_movie_convert.c), and the
// game's own arguments (Shadow Resolution, Anti-Aliasing: XRC_GAME_ARGS)
write_cfg :: proc(gdir: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# WhiteRecomp's settings, written by the launcher's Build (the environment overrides them)\n")
	fmt.sbprintf(&b, "XRC_GAME_DIR=%s\n", settings.game_dir)
	fmt.sbprintf(&b, "XRC_EXE=%s\n", game_exe(settings.game_dir))
	fmt.sbprintf(&b, "XRC_CDRIVE=%s\n", data_path("cdrive"))
	when ODIN_OS == .Windows {
		fmt.sbprintf(&b, "XRC_MOVIE_CONVERTER=%s\n", data_path("tools", "bink2mp4.exe"))
		if ff := dep_get(.FFmpeg); ff.can_encode && ff.path != "" {fmt.sbprintf(&b, "XRC_MOVIE_FFMPEG=%s\n", ff.path)}
	}
	fmt.sbprintf(&b, "XRC_GAME_ARGS=%s\n", game_args())
	if settings.shadow_res == 0 {fmt.sbprintf(&b, "XRC_NO_SHADOWS=1\n")}
	return os.write_entire_file(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator), b.buf[:]) == nil
}
