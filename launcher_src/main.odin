// The launcher: builds this project's FINAL FANTASY XIII port on the player's computer, from the sources it carries
// (bundle.odin) and the player's own game (game.odin). Its window has two tabs:
//   Home     where the game is, what the computer still needs (deps.odin: each with an Install button; an install
//            that needs administrator asks for it then, for that program alone), what is running (task.odin: progress,
//            a log, Cancel), and in the bottom right corner the three buttons:
//              Build           the game, with the computer's C compiler and the options (build_game.odin)
//              Convert Movies  the Bink movies to MP4, once (movies.odin)
//              Discard Movies  frees the space of the Bink movies that have their MP4 (movies.odin)
//   Options  how the game is built (options.odin): compiler, optimization, audio, tools, FPS, graphics, cutscenes
// Without any C compiler, a dialog says where to get one. The look and the controls: widgets.odin.
//
// Build: launcher/build.sh (packs the sources with `ff bundle`, then odin build). Uses shared/ (the iv_* libraries).
package launcher

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import input "shared:iv_input"
import iv "shared:iv_system"
import "shared:iv_system/platform"
import "shared:iv_system/ren"
import ren_assets "shared:iv_system/ren/assets"
import ui "shared:iv_ui"

Signal :: enum {
	None,
}

// ---------------------------------------------------------------------------------------------- state
Game_State :: struct {
	checked:   bool,
	ok:        bool,
	why:       string,
	to_convert, discardable, kept: int,
	free_bytes: i64,
}
game_mutex: sync.Mutex
game_state: Game_State

// Finds the game if the settings have none, checks its exe and counts its movies; then what is installed.
check_all_task :: proc(t: ^Task) {
	if !is_game_dir(settings.game_dir) {
		set_status(t, -1, "Looking for FINAL FANTASY XIII")
		if d := find_game(); d != "" {
			settings.game_dir = d
			save_settings()
		}
	}
	refresh_game(t)
	check_deps_task(t)
}

refresh_game :: proc(t: ^Task) {
	g := Game_State{checked = true}
	if !is_game_dir(settings.game_dir) {
		g.why = settings.game_dir == "" ? "not found: choose its folder" : "that folder has no white_data/prog/win/bin/ffxiiiimg.exe"
	} else {
		set_status(t, -1, "Checking the game")
		ok, why := check_game_exe(game_exe(settings.game_dir))
		g.ok = ok
		g.why = strings.clone(why)
		if ok {
			for m in list_movies(settings.game_dir) {
				if !m.stub && !m.discarded && !m.has_mp4 {g.to_convert += 1}
			}
			g.discardable, g.free_bytes, g.kept = discard_plan(settings.game_dir)
		}
		logf(t, "Game: %s (%s)", settings.game_dir, ok ? "ready" : why)
	}
	sync.mutex_lock(&game_mutex)
	game_state = g
	sync.mutex_unlock(&game_mutex)
}

get_game :: proc() -> Game_State {
	sync.mutex_lock(&game_mutex)
	defer sync.mutex_unlock(&game_mutex)
	return game_state
}

wake_window :: proc() {} // (the window redraws every frame)

// ---------------------------------------------------------------------------------------------- main
Tab :: enum {
	Home,
	Options,
}
tab: Tab
confirm_discard: bool
no_compiler_dialog: int // 0 not decided yet, 1 showing, 2 closed
log_scroll: int // lines up from the end
frame_wheel: int // this frame's wheel steps
game_running: bool // the game started by Run is running (game_windows.odin / game_posix.odin: start_game)

// the built game beside the launcher (build_game.odin), "" if there is none yet
built_game :: proc() -> string {
	exe := pjoin({game_out_dir(), GAME_NAME + EXE_SUFFIX}, context.temp_allocator)
	return file_exists(exe) ? exe : ""
}

main :: proc() {
	quiet_child_errors()
	init_paths()
	load_settings()
	if !bundle_open() {
		fmt.eprintln("WhiteRecomp: its bundled sources are missing or damaged")
		os.exit(1)
	}

	// --check / --build: without a window, the log to stdout (for scripts and for testing)
	for a in os.args[1:] {
		if a == "--build" {
			task_start("Checking", check_all_task)
			thread_join_task()
			task_start("Build", proc(t: ^Task) {build_task(t)})
			last := ""
			for sync.atomic_load(&task.running) {
				sync.mutex_lock(&task.mutex)
				if task.status != last {last = strings.clone(task.status); fmt.println(last)}
				sync.mutex_unlock(&task.mutex)
				time.sleep(2 * time.Second)
			}
			for l in task.log {fmt.println(l)}
			os.exit(task.failed ? 1 : 0)
		}
		if a == "--check" {
			task_start("Checking", check_all_task)
			thread_join_task()
			for l in task.log {fmt.println(l)}
			gs := get_game()
			fmt.printfln("game ok %v, %d movies to convert, %d discardable (%.1f GB), %d kept", gs.ok, gs.to_convert, gs.discardable, f64(gs.free_bytes) / 1e9, gs.kept)
			for c in compilers_get() {fmt.printfln("compiler: %s (%s)%s", c.label, c.path, c.path == settings.compiler ? " -- chosen" : "")}
			fmt.printfln("options: %v", runtime_option_flags())
			os.exit(0)
		}
	}

	app, ok := iv.open({title = "WhiteRecomp", width = 900, height = 640, min_width = 760, min_height = 560, background = [3]u8{WIN_BG.r, WIN_BG.g, WIN_BG.b}})
	if !ok {
		fmt.eprintln("WhiteRecomp: could not open a window")
		os.exit(1)
	}
	defer iv.close(app)

	// Segoe UI (Windows' own) where it is, else the bundled Noto Sans / Liberation Sans
	lib: ren_assets.Library
	ren_assets.library_init(&lib)
	ren_assets.add_builtin_font(&lib, "noto_sans_regular")
	ren_assets.add_builtin_font(&lib, "liberation_sans_bold")
	regular, semibold := "noto_sans_regular", "liberation_sans_bold"
	when ODIN_OS == .Windows {
		fonts := pjoin({os.get_env("WINDIR", context.temp_allocator), "Fonts"}, context.temp_allocator)
		if ren_assets.font_add_file(&lib, "segoe", pjoin({fonts, "segoeui.ttf"}, context.temp_allocator)) {regular = "segoe"}
		if ren_assets.font_add_file(&lib, "segoe_sb", pjoin({fonts, "seguisb.ttf"}, context.temp_allocator)) {semibold = "segoe_sb"}
	}
	g := Gui{s = max(app.window.dpi_scale, 1), win = app.window}
	g.font = ren_assets.font_make(&lib, &app.renderer, regular, 14 * g.s)
	g.small = ren_assets.font_make(&lib, &app.renderer, regular, 12 * g.s)
	g.bold = ren_assets.font_make(&lib, &app.renderer, semibold, 14 * g.s)
	g.big = ren_assets.font_make(&lib, &app.renderer, semibold, 20 * g.s)

	task_start("Checking", check_all_task)

	ctx: input.Context(Signal)
	for !app.window.close_requested {
		iv.pump(app, &ctx)
		mx, my := input.mouse_position(&ctx)
		g.mouse = {int(mx), int(my)}
		g.clicked = input.mouse_pressed(&ctx, .Left)
		g.down = input.mouse_down(&ctx, .Left)
		if no_compiler_dialog == 0 && sync.atomic_load(&deps_checked) && !sync.atomic_load(&task.running) {
			no_compiler_dialog = len(compilers_get()) == 0 ? 1 : 2
		}
		pick_poll()
		g.modal = confirm_discard || no_compiler_dialog == 1 || browser_is_open()
		_, wy := input.wheel(&ctx)
		frame_wheel = int(wy * 3)
		if !g.modal {log_scroll = max(0, log_scroll + frame_wheel)}

		g.dl = ren.begin_frame(&app.renderer, WIN_BG)
		g.screen = {0, 0, app.window.size.x, app.window.size.y}
		gui_begin(&g)
		draw_window(&g, app.window)
		gui_end(&g)
		ren.end_frame(&app.renderer)
		if ren.renderer_is_null(&app.renderer) {time.sleep(16 * time.Millisecond)}
		free_all(context.temp_allocator)
	}
	task_cancel()
	if task.th != nil {thread_join_task()}
}

thread_join_task :: proc() {
	for sync.atomic_load(&task.running) {time.sleep(10 * time.Millisecond)}
}

draw_window :: proc(g: ^Gui, w: ^platform.Window) {
	body := ui.inset_xy(g.screen, px(g, 24), px(g, 12))
	bar, rest := ui.cut_top(body, px(g, 40))
	tab = Tab(tabs(g, bar, {"Home", "Options"}, int(tab)))
	_, rest = ui.cut_top(rest, px(g, 16))
	switch tab {
	case .Home:
		draw_home(g, w, rest)
	case .Options:
		draw_options(g, rest)
	}
	if confirm_discard {draw_confirm(g, get_game())}
	if no_compiler_dialog == 1 {draw_no_compiler(g)}
	if browser_is_open() {draw_browser(g, frame_wheel)}
}

// ---------------------------------------------------------------------------------------------- Home
draw_home :: proc(g: ^Gui, w: ^platform.Window, r: ui.Rect) {
	running := sync.atomic_load(&task.running)
	gs := get_game()

	// the buttons: the bottom right corner (Build the larger; Run, green, at its right once the game is built)
	bottom, top := ui.cut_bottom(r, px(g, 44))
	_, top = ui.cut_bottom(top, px(g, 16))
	exe := built_game()
	playing := sync.atomic_load(&game_running)
	if exe != "" {
		run_r: ui.Rect
		run_r, bottom = ui.cut_right(bottom, px(g, 120), px(g, 8))
		run_r = ui.Rect{run_r.x, run_r.y, run_r.w, px(g, 44)}
		if button(g, run_r, playing ? "Running…" : "Run", !running && !playing, f = g.bold, green = true) {
			if !start_game(exe, game_out_dir()) {
				task_start("Run", proc(t: ^Task) {logf(t, "Could not start %s.", built_game()); t.failed = true})
			}
		}
		tooltip_zone(g, "run", run_r, playing ? "The game is running." : running ? "Wait for the current task to finish." : fmt.tprintf("Starts %s.", exe))
	}
	build_r, rest := ui.cut_right(bottom, px(g, 150), px(g, 8))
	build_r = ui.Rect{build_r.x, build_r.y, build_r.w, px(g, 44)}
	conv_r, rest2 := ui.cut_right(rest, px(g, 140), px(g, 8))
	disc_r, left := ui.cut_right(rest2, px(g, 140), px(g, 8))
	conv_r = ui.Rect{conv_r.x, conv_r.y + px(g, 6), conv_r.w, px(g, 32)}
	disc_r = ui.Rect{disc_r.x, disc_r.y + px(g, 6), disc_r.w, px(g, 32)}

	cc_ok := dep_get(.Compiler).path != ""
	ff := dep_get(.FFmpeg)
	can_build := !running && gs.ok && cc_ok && !playing
	can_convert := !running && gs.ok && ff.can_encode && gs.to_convert > 0 && ODIN_OS == .Windows
	can_discard := !running && gs.ok && gs.discardable > 0
	if button(g, disc_r, "Discard Movies", can_discard) {confirm_discard = true}
	if button(g, conv_r, "Convert Movies", can_convert) {
		task_start("Convert Movies", proc(t: ^Task) {convert_task(t); refresh_game(t)})
	}
	if button(g, build_r, "Build", can_build, primary = true, f = g.bold) {
		task_start("Build", proc(t: ^Task) {build_task(t)})
	}
	// why a button cannot be pressed (or what it would do)
	busy := running ? "Wait for the current task to finish." : ""
	tooltip_zone(g, "build", build_r, busy != "" ? busy : playing ? "Close the game first: it cannot be rebuilt while it runs." : !gs.ok ? "Needs the game: choose its folder." : !cc_ok ? "Needs a C compiler." : "Builds the game with the options of the Options tab.")
	conv_tip := ODIN_OS != .Windows ? "Converting the movies works on Windows only for now." : busy != "" ? busy : !gs.ok ? "Needs the game." : !ff.can_encode ? "Needs FFmpeg with its H.264 encoder (install it above)." : gs.to_convert == 0 ? "Every movie is converted." : fmt.tprintf("Converts the %d movies that have no MP4 yet (it can be cancelled and continued later).", gs.to_convert)
	tooltip_zone(g, "convert", conv_r, conv_tip)
	disc_tip := busy != "" ? busy : !gs.ok ? "Needs the game." : gs.discardable == 0 ? "Nothing to discard: no Bink movie has its MP4 yet." : fmt.tprintf("Frees %.1f GB: the Bink movies that have their MP4.", f64(gs.free_bytes) / 1e9)
	tooltip_zone(g, "discard", disc_r, disc_tip)
	if running {
		cr := ui.Rect{left.x, conv_r.y, px(g, 100), conv_r.h}
		if button(g, cr, "Cancel") {task_cancel()}
	}

	// the game
	gc, after := ui.cut_top(top, px(g, 68))
	card(g, gc)
	gi := ui.inset_xy(gc, px(g, 16), px(g, 12))
	browse, info := ui.cut_right(gi, px(g, 110), px(g, 12))
	if button(g, ui.center(browse, browse.w, px(g, 32)), "Browse…", !running) {
		browse_for_game(w) // (folder_pick.odin)
	}
	l1, l2 := ui.cut_top(info, info.h / 2)
	label(g, g.bold, "Game folder", l1, TEXT)
	loc := settings.game_dir != "" ? settings.game_dir : "not found"
	if gs.checked && !gs.ok {loc = fmt.tprintf("%s — %s", loc, gs.why)}
	label(g, g.font, loc, l2, gs.ok || !gs.checked ? DIM : BAD)
	_, after = ui.cut_top(after, px(g, 10))

	// what the computer needs
	rows := len(Dep_Kind)
	dc, after2 := ui.cut_top(after, px(g, 40) + rows * px(g, 48))
	card(g, dc)
	di := ui.inset_xy(dc, px(g, 16), px(g, 10))
	dh, drows := ui.cut_top(di, px(g, 28))
	label(g, g.bold, "Requirements", dh, TEXT)
	if button(g, {dh.x + dh.w - px(g, 110), dh.y, px(g, 110), px(g, 28)}, "Check again", !running, f = g.small) {
		task_start("Checking", check_all_task)
	}
	for k, i in Dep_Kind {
		d := dep_get(k)
		row := ui.Rect{drows.x, drows.y + i * px(g, 48), drows.w, px(g, 48)}
		inst, text := ui.cut_right(row, px(g, 250), px(g, 12))
		have := d.path != "" && (k != .FFmpeg || d.can_encode)
		dot(g, text.x + px(g, 5), text.y + px(g, 15), !deps_checked ? FAINT : have ? GOOD : d.path != "" ? WARN : BAD)
		name := k == .Compiler && have ? fmt.tprintf("%s — %s", d.name, compiler_label(d.path)) : fmt.tprintf("%s — %s", d.name, d.purpose)
		label(g, g.font, name, {text.x + px(g, 20), text.y + px(g, 4), text.w - px(g, 20), px(g, 22)}, TEXT)
		note := !deps_checked ? "checking…" : d.note
		label(g, g.small, note, {text.x + px(g, 20), text.y + px(g, 26), text.w - px(g, 20), px(g, 18)}, DIM)
		if deps_checked && !have {
			br := ui.center(inst, inst.w, px(g, 32))
			if d.install != nil {
				how := d.needs_admin ? fmt.tprintf("%s (asks for admin)", d.install_how) : d.install_how
				if button(g, br, how, !running, f = g.small) {
					task_start(d.install_how, install_dep_task, rawptr(uintptr(k)))
				}
			} else if d.install_how != "" {
				label(g, g.small, d.install_how, br, WARN, center = true)
			}
		}
	}
	_, after2 = ui.cut_top(after2, px(g, 10))

	// what is running: name, progress, status, the log
	draw_task(g, after2, running)
}

compiler_label :: proc(path: string) -> string {
	for c in compilers_get() {if c.path == path {return c.label}}
	return path
}

draw_task :: proc(g: ^Gui, r: ui.Rect, running: bool) {
	if r.h < px(g, 60) {return}
	card(g, r)
	inner := ui.inset_xy(r, px(g, 16), px(g, 12))
	sync.mutex_lock(&task.mutex)
	defer sync.mutex_unlock(&task.mutex)
	head, rest := ui.cut_top(inner, px(g, 22))
	state := running ? "" : task.failed ? " — failed" : task.name != "" ? " — done" : ""
	name := task.name != "" ? task.name : "Activity"
	label(g, g.bold, fmt.tprintf("%s%s", name, state), head, running || task.name == "" ? TEXT : task.failed ? BAD : GOOD)
	pb, rest2 := ui.cut_top(rest, px(g, 14))
	prog := task.progress
	if !running && prog < 0 {prog = 0}
	progress_bar(g, ui.Rect{pb.x, pb.y + px(g, 5), pb.w, px(g, 3)}, prog, running)
	st, logr := ui.cut_top(rest2, px(g, 20))
	label(g, g.small, task.status, st, DIM)
	_, logr = ui.cut_top(logr, px(g, 6))

	// the log, newest at the bottom (the wheel scrolls back)
	round_box(g, logr, px(g, 4), LOG_BG, CARD_BORDER)
	li := ui.inset_xy(logr, px(g, 10), px(g, 6))
	lh := g.small.line_height
	rows := max(1, li.h / lh)
	log_scroll = min(log_scroll, max(0, len(task.log) - rows))
	last := len(task.log) - log_scroll
	first := max(0, last - rows)
	{
		ren.scope_clip(g.dl, logr)
		for i in first ..< last {
			label(g, g.small, task.log[i], {li.x, li.y + (i - first) * lh, li.w, lh}, TEXT)
		}
	}
}

// ---------------------------------------------------------------------------------------------- Options
CUTSCENE_TIP :: "FINAL FANTASY XIII's cutscenes are Bink 2 videos, which this port cannot play directly: each one is converted to an MP4 once (Convert Movies on the Home tab does them all; while you play, the game also converts the missing ones in the background, quietly, one at a time). A cutscene that has no MP4 yet is skipped.\n\nPlay if converted: a cutscene plays once its MP4 exists, and is skipped until then.\nAuto-skip: every cutscene is skipped, even the converted ones (for replays and speedruns). The background conversion goes on, so they are ready if you switch back (with a new Build)."

draw_options :: proc(g: ^Gui, r: ui.Rect) {
	running := sync.atomic_load(&task.running)
	active := !running
	head, rest := ui.cut_top(r, px(g, 24))
	label(g, g.font, running ? "The options can be changed once the current task has finished." : "These apply the next time you press Build.", head, DIM)
	_, rest = ui.cut_top(rest, px(g, 8))
	nrows := 8
	row_h := px(g, 50)
	oc, _ := ui.cut_top(rest, nrows * row_h + px(g, 16))
	card(g, oc)
	oi := ui.inset_xy(oc, px(g, 20), px(g, 8))
	label_w := px(g, 230)
	ctrl_w := px(g, 270)
	changed := false
	row := 0
	next_row :: proc(g: ^Gui, oi: ui.Rect, row: ^int, row_h, label_w, ctrl_w: int, name: string) -> (whole, ctrl, note: ui.Rect) {
		y := oi.y + row^ * row_h
		whole = {oi.x, y, oi.w, row_h}
		if row^ > 0 {ren.draw_rect(g.dl, {oi.x, y, oi.w, 1}, CARD_BORDER)}
		label(g, g.font, name, {oi.x, y, label_w, row_h}, TEXT)
		ctrl = {oi.x + label_w, y + (row_h - px(g, 32)) / 2, ctrl_w, px(g, 32)}
		note = {ctrl.x + ctrl_w + px(g, 16), y, oi.w - label_w - ctrl_w - px(g, 16), row_h}
		row^ += 1
		return
	}

	// Compiler
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Compiler:")
		cs := compilers_get()
		if len(cs) == 0 {
			label(g, g.font, deps_checked ? "No C compiler found" : "Looking for compilers…", ctrl, deps_checked ? BAD : DIM)
			if deps_checked && button(g, {note.x, ctrl.y, px(g, 150), ctrl.h}, "Where to get one", active) {no_compiler_dialog = 1}
		} else {
			names := make([]string, len(cs), context.temp_allocator)
			sel := 0
			for c, i in cs {
				names[i] = c.label
				if c.path == settings.compiler {sel = i}
			}
			if n, ch := dropdown(g, "compiler", ctrl, names, sel, active = active); ch {select_compiler(cs[n].path); changed = true}
			label(g, g.small, cs[sel].path, note, DIM)
		}
	}
	// Optimization Level
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Optimization Level:")
		levels := OPT_LEVELS
		if n, ch := dropdown(g, "opt", ctrl, levels[:], settings.opt_level, active = active); ch {settings.opt_level = n; changed = true}
		label(g, g.small, "Higher: a slower build, a faster game", note, DIM)
	}
	// Audio
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Audio:")
		if on, ch := toggle(g, ctrl, settings.audio, active); ch {settings.audio = on; changed = true}
		label(g, g.small, settings.audio ? "Music, sound and voices" : "No audio work at all (play your own music)", note, DIM)
	}
	// Debug & Profile Tools
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Debug & Profile Tools:")
		if on, ch := toggle(g, ctrl, settings.tools, active); ch {settings.tools = on; changed = true}
		label(g, g.small, "Tracing, logs and the profiler (for developers)", note, DIM)
	}
	// FPS
	{
		_, ctrl, _ := next_row(g, oi, &row, row_h, label_w, ctrl_w, "FPS:")
		fps := FPS_CHOICES
		names := []string{"30", "60"}
		sel := settings.fps == 30 ? 0 : 1
		if n, ch := dropdown(g, "fps", ctrl, names, sel, active = active); ch {settings.fps = fps[n]; changed = true}
	}
	// Graphics Driver
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Graphics Driver:")
		when ODIN_OS == .Windows {
			names := []string{"Vulkan (Recommended)", "D3D9"}
			sel := settings.vulkan ? 0 : 1
			if n, ch := dropdown(g, "gfx", ctrl, names, sel, active = active); ch {settings.vulkan = n == 0; changed = true}
			label(g, g.small, sel == 0 ? "The port's Vulkan renderer" : "Windows' Direct3D 9: broken for now (stops after the first fight)", note, sel == 0 ? DIM : WARN)
		} else {
			_, _ = dropdown(g, "gfx", ctrl, {"Vulkan"}, 0, active = active) // (the only one there)
			label(g, g.small, "The port's Vulkan renderer", note, DIM)
		}
	}
	// Cutscenes (with its tooltip over the whole row)
	{
		whole, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Cutscenes:")
		names := []string{"Play if converted", "Auto-skip"}
		if n, ch := dropdown(g, "cutscenes", ctrl, names, settings.skip_movies ? 1 : 0, active = active); ch {settings.skip_movies = n == 1; changed = true}
		label(g, g.small, "Hover for how cutscenes work", note, DIM)
		tooltip_zone(g, "cutscenes", whole, CUTSCENE_TIP)
	}
	// Cutscene Convert Threads
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Cutscene Convert Threads:")
		n_max := max_convert_threads()
		names := make([]string, n_max, context.temp_allocator)
		for i in 0 ..< n_max {names[i] = i == 0 ? "1 (DEFAULT)" : fmt.tprintf("%d", i + 1)}
		sel := clamp(settings.convert_threads, 1, n_max) - 1
		if n, ch := dropdown(g, "threads", ctrl, names, sel, active = active); ch {settings.convert_threads = n + 1; changed = true}
		label(g, g.small, "CPU threads for converting (Convert Movies and in the background)", note, DIM)
	}
	if changed {save_settings()}
}

// ---------------------------------------------------------------------------------------------- dialogs
dialog_box :: proc(g: ^Gui, w, h: int) -> ui.Rect {
	ren.draw_rect(g.dl, g.screen, ren.Color{0, 0, 0, 77})
	box := ui.center(g.screen, w, h)
	for k in 1 ..= 6 {fill_round(g, ui.translate(ui.outset(box, k), 0, k), px(g, 8) + k, ren.Color{0, 0, 0, 6})}
	round_box(g, box, px(g, 8), ren.Color{255, 255, 255, 255}, ren.Color{200, 200, 200, 255})
	return box
}

// the dialog's button row: a light grey strip at its bottom
dialog_buttons :: proc(g: ^Gui, box: ui.Rect) -> ui.Rect {
	strip := ui.Rect{box.x + 1, box.y + box.h - px(g, 80), box.w - 2, px(g, 80) - px(g, 8)}
	ren.draw_rect(g.dl, strip, WIN_BG)
	fill_round(g, {box.x + 1, box.y + box.h - px(g, 16), box.w - 2, px(g, 15)}, px(g, 7), WIN_BG)
	ren.draw_rect(g.dl, {box.x + 1, strip.y, box.w - 2, 1}, CARD_BORDER)
	return ui.Rect{box.x + px(g, 24), strip.y + px(g, 24), box.w - px(g, 48), px(g, 32)}
}

draw_confirm :: proc(g: ^Gui, gs: Game_State) {
	g.in_modal = true
	defer g.in_modal = false
	box := dialog_box(g, px(g, 520), px(g, 250))
	in_ := ui.inset_xy(box, px(g, 24), px(g, 22))
	ren.draw_text(g.dl, g.big, "Discard the old movies?", {in_.x, in_.y}, TEXT)
	y := in_.y + g.big.line_height + px(g, 12)
	text := fmt.tprintf("%d Bink movies (.wmp) that have their MP4 are cut down to their header, freeing %.1f GB. The game keeps playing the MP4s; to get the originals back, verify the game's files in Steam.", gs.discardable, f64(gs.free_bytes) / 1e9)
	if gs.kept > 0 {text = fmt.tprintf("%s %d movies without an MP4 are kept whole.", text, gs.kept)}
	paragraph(g, g.font, text, {in_.x, y, in_.w, 0}, TEXT, px(g, 2))
	btns := dialog_buttons(g, box)
	yes, no := ui.columns(btns, 0, 2, px(g, 8)), ui.columns(btns, 1, 2, px(g, 8))
	if button(g, yes, "Discard", primary = true) {
		confirm_discard = false
		task_start("Discard Movies", proc(t: ^Task) {discard_task(t); refresh_game(t)})
	}
	if button(g, no, "Keep them") {confirm_discard = false}
}

draw_no_compiler :: proc(g: ^Gui) {
	g.in_modal = true
	defer g.in_modal = false
	box := dialog_box(g, px(g, 580), px(g, 380))
	in_ := ui.inset_xy(box, px(g, 24), px(g, 22))
	ren.draw_text(g.dl, g.big, "A C compiler is needed", {in_.x, in_.y}, TEXT)
	y := in_.y + g.big.line_height + px(g, 12)
	y += paragraph(g, g.font, "The launcher builds the game on your computer, and that needs a C compiler (Clang or GCC). None was found. Install one, then press Check again.", {in_.x, y, in_.w, 0}, TEXT, px(g, 2))
	y += px(g, 12)
	lh := g.font.line_height + px(g, 10)
	when ODIN_OS == .Windows {
		x := in_.x + px(g, 12)
		ren.draw_text(g.dl, g.bold, "Windows", {in_.x, y}, TEXT); y += lh
		w := link(g, x, y, "LLVM-MinGW (Clang: the best choice)", "https://github.com/mstorsjo/llvm-mingw/releases")
		ren.draw_text(g.dl, g.small, "  the ucrt-x86_64 zip, or: winget install MartinStorsjo.LLVM-MinGW.UCRT", {x + w, y + px(g, 2)}, DIM); y += lh
		link(g, x, y, "MSYS2 (GCC or Clang)", "https://www.msys2.org/"); y += lh
	} else {
		x := in_.x + px(g, 12)
		ren.draw_text(g.dl, g.bold, "Linux", {in_.x, y}, TEXT); y += lh
		w := link(g, x, y, "Clang (the best choice)", "https://clang.llvm.org/get_started.html")
		ren.draw_text(g.dl, g.small, "  e.g. sudo apt install clang  /  sudo dnf install clang", {x + w, y + px(g, 2)}, DIM); y += lh
		w = link(g, x, y, "GCC", "https://gcc.gnu.org/install/")
		ren.draw_text(g.dl, g.small, "  e.g. sudo apt install build-essential", {x + w, y + px(g, 2)}, DIM); y += lh
	}
	btns := dialog_buttons(g, box)
	d := dep_get(.Compiler)
	running := sync.atomic_load(&task.running)
	cols := d.install != nil ? 3 : 2
	i := 0
	if d.install != nil {
		if button(g, ui.columns(btns, i, cols, px(g, 8)), "Install it for me", !running, primary = true) {
			no_compiler_dialog = 0
			task_start(d.install_how, install_dep_task, rawptr(uintptr(Dep_Kind.Compiler)))
		}
		i += 1
	}
	if button(g, ui.columns(btns, i, cols, px(g, 8)), "Check again", !running, primary = d.install == nil) {
		no_compiler_dialog = 0
		task_start("Checking", check_all_task)
	}
	if button(g, ui.columns(btns, i + 1, cols, px(g, 8)), "Close") {no_compiler_dialog = 2}
}
