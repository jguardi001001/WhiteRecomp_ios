package main

// PlanCol sound editor: a keyboard-driven editor for PSNG song files with a piano roll (one track at a time), an
// instrument with an effect graph per track, a mixer and WAV export.
//
//   odin run shared/iv_snd/editor -o:speed -collection:shared=shared     (from the proj folder)
//   odin run shared/iv_snd/editor -o:speed -collection:shared=shared -- song.psng
//
//   snd_editor --selftest                          checks the project model without a window
//   snd_editor --export song.psng out.wav [loops]  renders a WAV file without a window and prints the time it took
//   snd_editor --shot out.png [options] [song]     draws the window once into a PNG (for checking the look)
//
// See shared/iv_snd/editor/README.md.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

pending_drop: string
shown_track: int // the track the roll was last set up for (see roll_focus_track)
window_title: string

load_drop :: proc() {
	play_halt()
	file_load(pending_drop)
}

main :: proc() {
	args := os.args
	keymap_init()
	if len(args) > 1 {
		switch args[1] {
		case "--selftest":
			os.exit(0 if run_selftest() else 1)
		case "--export":
			os.exit(cli_export(args[2:]))
		}
	}
	shot, shot_ok := shot_parse(args[1:])
	if !shot_ok {
		os.exit(2)
	}
	if shot.out != "" { // (enough frames for the scripted mouse input to play out)
		shot.frames = max(shot.frames, 3 + 3 * len(shot.clicks) + (5 if shot.has_drag else 0) + 3)
	}

	rl.SetTraceLogLevel(.ERROR) // (the font loader warns about glyphs a pixel taller than the font size; it does not matter)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(1280, 720, "PlanCol sound editor")
	defer rl.CloseWindow()
	rl.SetExitKey(.KEY_NULL)

	// The interface follows the scale of the display (125%, 150%, ...); F11 / F12 change it.
	dpi := rl.GetWindowScaleDPI()
	ui_scale = clamp(math.round(dpi.x * 4) / 4, 1, 3)
	if shot.scale > 0 {
		ui_scale = shot.scale
	}
	if shot.out == "" {
		mon := rl.GetCurrentMonitor()
		w := min(int(1280 * ui_scale), int(f32(rl.GetMonitorWidth(mon)) * 0.92))
		h := min(int(760 * ui_scale), int(f32(rl.GetMonitorHeight(mon)) * 0.9))
		if ui_scale > 1.01 {
			rl.SetWindowSize(i32(w), i32(h))
		}
	} else {
		rl.SetWindowSize(i32(shot.w), i32(shot.h))
	}
	rl.SetWindowMinSize(i32(800 * ui_scale), i32(580 * ui_scale))
	rl.SetTargetFPS(60)

	fonts_load()
	defer fonts_unload()
	ed_init()
	audio_start()
	defer audio_stop()

	if shot.song != "" {
		file_load(shot.song)
	} else if len(args) > 1 && !strings.has_prefix(args[1], "-") {
		file_load(args[1])
	}

	close_handled := false
	frame := 0
	for !quit_requested {
		// The close button of the window asks about unsaved work. (If the question is answered with Cancel, the next
		// click on the button asks again.)
		if !rl.WindowShouldClose() {
			close_handled = false
		} else if !close_handled {
			close_handled = true
			run_action(.File_Quit)
		}
		dt := rl.GetFrameTime()
		w := int(rl.GetScreenWidth())
		h := int(rl.GetScreenHeight())
		if w <= 0 || h <= 0 { // minimized
			rl.BeginDrawing()
			rl.EndDrawing()
			continue
		}
		win_w = int(math.ceil(f32(w) / ui_scale))
		win_h = int(math.ceil(f32(h) / ui_scale))

		input_poll()
		if shot.out != "" {
			shot_script(&shot, frame)
		}
		t_update := now()
		update(dt)
		t_update = now() - t_update

		rl.BeginDrawing()
		rl.ClearBackground(COL_BG0)
		clip_reset()
		t_draw := now()
		draw()
		rl.EndScissorMode()
		t_draw = now() - t_draw
		if shot.out != "" && frame >= 1 { // (the cost of the first frame includes loading)
			shot.update_ms += t_update * 1000
			shot.draw_ms += t_draw * 1000
			shot.worst_ms = max(shot.worst_ms, (t_update + t_draw) * 1000)
		}
		if shot.out != "" && frame == shot.frames {
			shot_save(&shot)
			quit_requested = true
		}
		rl.EndDrawing()
		cursor_apply()
		frame += 1

		// The window title shows the name and whether there is unsaved work.
		title := fmt.tprintf("%s%s - PlanCol sound editor", name_str(&ed.p.name), "*" if ed.dirty else "")
		if title != window_title {
			delete(window_title)
			window_title = strings.clone(title)
			rl.SetWindowTitle(strings.clone_to_cstring(title, context.temp_allocator))
		}
		free_all(context.temp_allocator)
	}
	if export_job.active {
		export_cleanup()
	}
}

update :: proc(dt: f32) {
	layout_update()
	info_update()
	ui_blocked = menu_open >= 0 || modal_kind != .None

	if len(in_.drops) > 0 && modal_kind == .None {
		path := in_.drops[0]
		if strings.to_lower(path_ext(path), context.temp_allocator) == ".wav" {
			file_import_wav(path) // a recording becomes the instrument of the track
		} else {
			delete(pending_drop)
			pending_drop = strings.clone(path)
			confirm_unsaved(load_drop)
		}
	}

	if export_job.active {
		export_step()
	}
	if modal_update() {
		// a dialog is open
	} else if menu_update() {
		// the menu is open
	} else {
		transport_update()
		side_update()
		if ed.view == .Graph {
			graph_mouse()
			graph_keys()
		} else {
			roll_mouse()
			roll_keys()
		}
	}
	play_update(dt)

	// Keep the cursor and the play head in view.
	if play_active && ed.follow && drag.kind == .None {
		x := tick_to_x(int(play_pos()))
		g := lay.grid
		if x > g.x + g.w - 20 || x < g.x {
			ed.scroll_tick = max(int(play_pos()) - ed.roll_ticks / 8, 0)
		}
	}
	ed.cur_track = clamp(ed.cur_track, 0, len(ed.p.tracks) - 1)
	if ed.cur_track != shown_track {
		shown_track = ed.cur_track
		roll_focus_track()
	}
	ed.cursor_key = clamp(ed.cursor_key, 0, 127)
	ed.scroll_tick = max(ed.scroll_tick, 0)
}

draw :: proc() {
	layout_update()
	if ed.view == .Graph {
		graph_draw()
	} else {
		roll_draw()
	}
	side_draw()
	transport_draw()
	status_draw()
	menu_draw_bar()
	if modal_kind != .None {
		draw_overlay()
		in_modal_draw = true
		modal_draw()
		in_modal_draw = false
	} else {
		menu_draw_drop()
	}
}

// ---- command line: --export ------------------------------------------------------------------------------

cli_export :: proc(args: []string) -> int {
	if len(args) < 2 {
		fmt.eprintln("usage: snd_editor --export song.psng out.wav [loops]")
		return 2
	}
	loops := 0
	if len(args) > 2 {
		if n, ok := strconv.parse_int(args[2]); ok {
			loops = n
		}
	}
	ed_init()
	if !file_load(args[0]) {
		fmt.eprintfln("could not read %s", args[0])
		return 1
	}
	t0 := now()
	if !export_blocking(args[1], loops) {
		fmt.eprintfln("could not write %s", args[1])
		return 1
	}
	fmt.printfln("wrote %s in %.2f s", args[1], now() - t0)
	return 0
}

// ---- command line: --shot (a picture of the window, to check the look without a person at the screen) ----------
//
//   snd_editor --shot out.png [--size 1280x760] [--scale 1.25] [--dialog palette|help|instrument|patch|sampler|delay|file|menu]
//              [--mouse x,y] [--select] [--play] [--frames 4] [song.psng]

Shot :: struct {
	out:    string,
	song:   string,
	w, h:   int,
	scale:  f32,
	dialog: string,
	mouse:  [2]int,
	has_mouse, select_all, play: bool,
	frames: int,
	track:   int,
	view:    string, // --view graph
	beat_px: int,
	update_ms, draw_ms, worst_ms: f64, // CPU time of the frames (--frames 120 gives an average)
	clicks:   [dynamic][2]int, // --click x,y (any number): left clicks, one every three frames
	drag:     [4]int, // --drag x0,y0,x1,y1: press, move, release
	has_drag: bool,
}

shot_parse :: proc(args: []string) -> (s: Shot, ok: bool) {
	s.w = 1280
	s.h = 760
	s.frames = 4
	ok = true
	i := 0
	for i < len(args) {
		a := args[i]
		next := i + 1 < len(args)
		switch {
		case a == "--shot" && next:
			s.out = args[i + 1]
			i += 1
		case a == "--size" && next:
			parts := strings.split(args[i + 1], "x", context.temp_allocator)
			if len(parts) == 2 {
				s.w, _ = strconv.parse_int(parts[0])
				s.h, _ = strconv.parse_int(parts[1])
			}
			i += 1
		case a == "--scale" && next:
			s.scale, _ = strconv.parse_f32(args[i + 1])
			i += 1
		case a == "--dialog" && next:
			s.dialog = args[i + 1]
			i += 1
		case a == "--mouse" && next:
			parts := strings.split(args[i + 1], ",", context.temp_allocator)
			if len(parts) == 2 {
				s.mouse[0], _ = strconv.parse_int(parts[0])
				s.mouse[1], _ = strconv.parse_int(parts[1])
				s.has_mouse = true
			}
			i += 1
		case a == "--frames" && next:
			s.frames, _ = strconv.parse_int(args[i + 1])
			i += 1
		case a == "--track" && next:
			s.track, _ = strconv.parse_int(args[i + 1])
			i += 1
		case a == "--view" && next:
			s.view = args[i + 1]
			i += 1
		case a == "--beat-px" && next:
			s.beat_px, _ = strconv.parse_int(args[i + 1])
			i += 1
		case a == "--click" && next:
			parts := strings.split(args[i + 1], ",", context.temp_allocator)
			if len(parts) == 2 {
				x, _ := strconv.parse_int(parts[0])
				y, _ := strconv.parse_int(parts[1])
				append(&s.clicks, [2]int{x, y})
			}
			i += 1
		case a == "--drag" && next:
			parts := strings.split(args[i + 1], ",", context.temp_allocator)
			if len(parts) == 4 {
				for j in 0 ..< 4 {
					s.drag[j], _ = strconv.parse_int(parts[j])
				}
				s.has_drag = true
			}
			i += 1
		case a == "--select":
			s.select_all = true
		case a == "--play":
			s.play = true
		case strings.has_prefix(a, "--"):
			if a != "--shot" {
				fmt.eprintfln("unknown option %s", a)
				return s, false
			}
		case:
			s.song = a
		}
		i += 1
	}
	return s, true
}

// Sets up what the picture shows, once the first frames have been laid out.
shot_script :: proc(s: ^Shot, frame: int) {
	if frame == 1 {
		if s.track > 0 {
			ed.cur_track = clamp(s.track - 1, 0, len(ed.p.tracks) - 1)
		}
		if s.view == "graph" {
			graph_ed_open()
		}
		if s.beat_px > 0 {
			ed.beat_px = s.beat_px
		}
		if s.select_all {
			sel_all(false)
		}
		switch s.dialog {
		case "palette":
			run_action(.Palette)
		case "help":
			run_action(.Help_Keys)
		case "graphs":
			run_action(.Track_Graph)
		case "instrument":
			run_action(.Track_Instrument)
		case "patch":
			open_patch_editor(ed.cur_track, 0)
		case "sampler":
			open_sampler_editor(ed.cur_track)
		case "delay":
			run_action(.Delay_Settings)
		case "file":
			run_action(.File_Open)
		case "prompt":
			run_action(.Song_Tempo)
		case "menu":
			menu_open = 1
			menu_sel = 2
		case "progress":
			export_begin("shot_progress.wav", 64)
		}
		if s.play {
			run_action(.Play_Start)
		}
	}
	if s.has_mouse {
		rl.SetMousePosition(i32(f32(s.mouse[0]) * ui_scale), i32(f32(s.mouse[1]) * ui_scale))
	}
	// Synthetic mouse input, fed straight into the editor's input state (nothing touches the real mouse).
	first := 3
	for c, i in s.clicks {
		f := first + i * 3
		if frame == f {
			shot_mouse(c.x, c.y, true, true, false)
		} else if frame == f + 1 {
			shot_mouse(c.x, c.y, false, false, true)
		}
	}
	if s.has_drag {
		f := first + len(s.clicks) * 3
		d := s.drag
		switch frame {
		case f:
			shot_mouse(d[0], d[1], true, true, false)
		case f + 1:
			shot_mouse((d[0] + d[2]) / 2, (d[1] + d[3]) / 2, false, true, false)
		case f + 2:
			shot_mouse(d[2], d[3], false, true, false)
		case f + 3:
			shot_mouse(d[2], d[3], false, false, true)
		}
	}
}

shot_mouse :: proc(x, y: int, pressed, down, released: bool) {
	in_.dmx = x - in_.mx
	in_.dmy = y - in_.my
	in_.mx = x
	in_.my = y
	in_.pressed[BTN_L] = pressed
	in_.down[BTN_L] = down
	in_.released[BTN_L] = released
}

shot_save :: proc(s: ^Shot) {
	img := rl.LoadImageFromScreen()
	defer rl.UnloadImage(img)
	if rl.ExportImage(img, strings.clone_to_cstring(s.out, context.temp_allocator)) {
		n := f64(max(s.frames, 1))
		fmt.printfln("wrote %s (%dx%d, interface scale %.2f); CPU per frame: update %.2f ms, draw %.2f ms, worst frame %.2f ms", s.out, img.width, img.height, ui_scale, s.update_ms / n, s.draw_ms / n, s.worst_ms)
		fmt.printfln(
			"state: grid %s, track %d of %d (volume %.2f, pan %.2f), undo steps %d, selected %d, notes %d, cursor tick %d key %s, loop %v, mute track1 %v, view %v, graphs %d, track graph nodes %d, wires %d",
			GRIDS[ed.grid_idx].label,
			ed.cur_track + 1,
			len(ed.p.tracks),
			track_mix(ed.cur_track, .Volume),
			track_mix(ed.cur_track, .Pan),
			len(ed.undo),
			sel_count(),
			len(ed.p.notes),
			ed.cursor_tick,
			key_label(ed.cursor_key),
			ed.loop_on,
			ed.p.tracks[0].mute,
			ed.view,
			len(ed.p.graphs),
			len(track_graph_or_empty(ed.cur_track).nodes),
			len(track_graph_or_empty(ed.cur_track).edges),
		)
	} else {
		fmt.eprintfln("could not write %s", s.out)
	}
}
