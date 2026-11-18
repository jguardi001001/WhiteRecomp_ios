// Convert Movies: every Bink 2 movie of the install (white_data/movie/*.wmp) to an MP4 next to it, once, with the
// bundled converter (tools/bink2mp4: the game's own bink2w32.dll decodes, FFmpeg encodes; see its source). The game
// then plays the MP4s (src/runtime/hle_bink.c). A movie that already has its MP4 is skipped, so it can be cancelled
// and run again. Windows only for now (the converter is a 32-bit Windows program around the game's Windows DLL).
//
// Discard Old Movies: frees the space of the .wmp files (about 40 GB) once their MP4s exist. Each .wmp is cut down to
// its first 4 KB instead of deleted: the game still opens the .wmp to find a movie, and reads the frame count and
// rate from its header; the pictures and sound come from the MP4. A movie without an MP4 is left whole.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

WMP_KEEP :: 4096 // bytes of a discarded .wmp that stay (its header)

Movie_File :: struct {
	wmp, mp4: string,
	size:     i64,
	has_mp4:  bool,
	discarded: bool, // already cut down
	stub:     bool, // a 16-byte placeholder of the install (no movie)
}

list_movies :: proc(game: string, allocator := context.temp_allocator) -> [dynamic]Movie_File {
	out := make([dynamic]Movie_File, allocator)
	dir := movie_dir(game)
	list, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return out}
	for e in list {
		if !strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".wmp") {continue}
		m := Movie_File{wmp = strings.clone(e.fullpath, allocator), size = e.size}
		m.mp4 = strings.concatenate({e.fullpath[:len(e.fullpath) - 4], ".mp4"}, allocator)
		m.has_mp4 = file_exists(m.mp4)
		m.stub = e.size <= 16
		m.discarded = !m.stub && e.size <= WMP_KEEP
		append(&out, m)
	}
	return out
}

// ---------------------------------------------------------------------------------------------- Convert Movies
@(private = "file")
Convert_State :: struct {
	total, done: int,
	current:     string,
}
@(private = "file")
conv: Convert_State

convert_task :: proc(t: ^Task) {
	when ODIN_OS != .Windows {
		log_line(t, "Converting the movies needs Windows for now (the converter runs the game's own Windows Bink DLL).")
		t.failed = true
		return
	} else {
		game := settings.game_dir
		ff := dep_get(.FFmpeg)
		if !ff.can_encode {
			log_line(t, "FFmpeg with an H.264 encoder (libx264) is needed: install it first.")
			t.failed = true
			return
		}
		todo := 0
		for m in list_movies(game) {
			if !m.stub && !m.discarded && !m.has_mp4 {todo += 1}
		}
		if todo == 0 {
			log_line(t, "Every movie already has its MP4.")
			set_status(t, 1, "Nothing to convert")
			return
		}
		if bundle_extract(t, data_dir, {"tools/"}) < 0 {t.failed = true; return}
		tool := data_path("tools", "bink2mp4.exe")
		dll := pjoin({game, "white_data", "prog", "win", "bin", "bink2w32.dll"}, context.temp_allocator)
		dir := movie_dir(game)
		conv = {total = todo}
		logf(t, "Converting %d movies (about an hour and a half of video; it can be cancelled and continued later)", todo)
		set_status(t, 0, "Converting: 0 of %d", todo)
		// as many encoder threads as the Options tab's Cutscene Convert Threads (as the game's background conversion)
		threads := fmt.tprintf("%d", clamp(settings.convert_threads, 1, max_convert_threads()))
		logf(t, "Converting with %s thread(s) (Options: Cutscene Convert Threads)", threads)
		code, started := run(t, {tool, "--dll", dll, "--ffmpeg", ff.path, "--threads", threads, "all", dir, dir}, on_line = proc(t: ^Task, line: string) {
			// "<in>: 1280x736 (out 1280x720), 5160 frames at 29.970 fps, 4 audio tracks -> <out>" starts one,
			// "  frame N / M (x fps)" is its progress, "  done in N s" ends it
			l := strings.trim_space(line)
			if strings.contains(l, " frames at ") && strings.contains(l, " -> ") {
				conv.current = filepath.base(l[:strings.index(l, ": ")])
				set_status(t, f32(conv.done) / f32(max(conv.total, 1)), "Converting %s: movie %d of %d", conv.current, conv.done + 1, conv.total)
				return
			}
			if strings.has_prefix(l, "done in") {conv.done += 1}
			if strings.has_prefix(l, "frame ") {
				parts := strings.fields(l, context.temp_allocator)
				if len(parts) >= 4 {
					f, _ := strconv.parse_f64(parts[1])
					n, _ := strconv.parse_f64(parts[3])
					if n > 0 {
						p := (f32(conv.done) + f32(f / n)) / f32(conv.total)
						set_status(t, p, "Converting %s: movie %d of %d, frame %d of %d", conv.current, conv.done + 1, conv.total, int(f), int(n))
					}
				}
			}
		})
		if cancelled(t) {return}
		if !started || code != 0 {
			log_line(t, "The converter failed.")
			t.failed = true
			return
		}
		set_status(t, 1, "Converted %d movies", conv.done)
	}
}

// ---------------------------------------------------------------------------------------------- Discard Old Movies
// What Discard would do (for its confirmation): movies it would cut down, the bytes it frees, movies it would keep.
discard_plan :: proc(game: string) -> (n: int, bytes: i64, kept: int) {
	for m in list_movies(game) {
		if m.stub || m.discarded {continue}
		if m.has_mp4 {
			n += 1
			bytes += m.size - WMP_KEEP
		} else {
			kept += 1
		}
	}
	return
}

discard_task :: proc(t: ^Task) {
	game := settings.game_dir
	freed: i64 = 0
	cut, kept := 0, 0
	list := list_movies(game)
	for m, i in list {
		if cancelled(t) {break}
		if m.stub || m.discarded {continue}
		if !m.has_mp4 {
			logf(t, "Kept %s: it has no MP4 yet", filepath.base(m.wmp))
			kept += 1
			continue
		}
		set_status(t, f32(i) / f32(len(list)), "Discarding %s", filepath.base(m.wmp))
		f, err := os.open(m.wmp, {.Read, .Write})
		if err == nil {
			err = os.truncate(f, WMP_KEEP)
			os.close(f)
		}
		if err != nil {
			logf(t, "Could not cut down %s: %v", filepath.base(m.wmp), err)
			t.failed = true
			continue
		}
		freed += m.size - WMP_KEEP
		cut += 1
	}
	logf(t, "Discarded %d old movies: %.1f GB freed%s", cut, f64(freed) / 1e9, kept > 0 ? fmt.tprintf(" (%d kept: convert them first)", kept) : "")
	set_status(t, 1, "%.1f GB freed", f64(freed) / 1e9)
}
