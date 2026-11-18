package main

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"
import snd "shared:iv_snd"
import ui "shared:iv_ui"

// ---------------------------------------------------------------------------
// The transport bar, the track list with the faders of the current track,
// and the status bar.
// ---------------------------------------------------------------------------

tracks_scroll: int

// ---- transport -----------------------------------------------------------------------------------

Transport_Rects :: struct {
	start, play, loop:          Rect,
	pos, tempo, sig:            Rect,
	grid_dn, grid_lbl, grid_up: Rect,
	vel:                        Rect,
	follow, sound:              Rect,
}

// Where everything of the transport bar is: a strip is cut into pieces from the left, and the parts that no longer fit the
// window are left empty (zero size).
transport_rects :: proc() -> Transport_Rects {
	tr: Transport_Rects
	strip := ui.pad(lay.transport, ui.Insets{12, 8, 12, 8})
	tr.start, strip = ui.cut_left(strip, 38, 4)
	tr.play, strip = ui.cut_left(strip, 50, 4)
	tr.loop, strip = ui.cut_left(strip, 38, 18)
	if strip.w >= 204 {
		tr.pos, strip = ui.cut_left(strip, 204, 8)
	}
	if strip.w >= 88 {
		tr.tempo, strip = ui.cut_left(strip, 88, 6)
	}
	if strip.w >= 56 {
		tr.sig, strip = ui.cut_left(strip, 56, 18)
	}
	if strip.w >= 150 {
		cluster: ui.Rect
		cluster, strip = ui.cut_left(strip, 126, 8)
		tr.grid_dn, cluster = ui.cut_left(cluster, 24, 2)
		tr.grid_lbl, tr.grid_up = ui.cut_left(cluster, 74, 2)
	}
	if strip.w >= 76 {
		tr.vel, strip = ui.cut_left(strip, 76, 18)
	}
	if strip.w >= 76 {
		tr.follow, strip = ui.cut_left(strip, 76, 6)
	}
	if strip.w >= 70 {
		tr.sound, strip = ui.cut_left(strip, 70)
	}
	return tr
}

transport_update :: proc() {
	tr := transport_rects()
	if in_.wheel_y != 0 {
		if mouse_in(tr.grid_lbl) || mouse_in(tr.grid_dn) || mouse_in(tr.grid_up) {
			ed.grid_idx = clamp(ed.grid_idx + int(in_.wheel_y), 0, len(GRIDS) - 1)
		} else if mouse_in(tr.vel) {
			ed.def_vel = clamp(ed.def_vel + int(in_.wheel_y) * 4, 1, 127)
		} else if mouse_in(tr.tempo) {
			ed_set_tempo(ed.cursor_tick, clamp(bpm_at(ed.cursor_tick) + in_.wheel_y, 10, 400))
		}
	}
	if !in_.pressed[BTN_L] {
		return
	}
	switch {
	case mouse_in(tr.start):
		play_halt()
		cursor_goto(0, ed.cursor_key)
	case mouse_in(tr.play):
		run_action(.Play_Toggle)
	case mouse_in(tr.loop):
		run_action(.Play_Loop_Toggle)
	case mouse_in(tr.pos):
		run_action(.View_Goto_Bar)
	case mouse_in(tr.tempo):
		run_action(.Song_Tempo)
	case mouse_in(tr.sig):
		run_action(.Song_Beats_Per_Bar)
	case mouse_in(tr.grid_dn):
		ed.grid_idx = max(ed.grid_idx - 1, 0)
	case mouse_in(tr.grid_up):
		ed.grid_idx = min(ed.grid_idx + 1, len(GRIDS) - 1)
	case mouse_in(tr.grid_lbl): // (the label goes round, so every grid can be reached by clicking it)
		ed.grid_idx = (ed.grid_idx + 1) % len(GRIDS)
	case mouse_in(tr.vel):
		run_action(.Edit_Vel_Set)
	case mouse_in(tr.follow):
		run_action(.Follow_Toggle)
	case mouse_in(tr.sound):
		run_action(.Audition_Toggle)
	}
}

// A round-cornered button for an icon; returns the color to draw the icon in.
icon_button :: proc(r: Rect, on: bool, col: Color) -> Color {
	h := hover(r)
	if h {
		cursor_hint(.POINTING_HAND)
	}
	down := h && in_.down[BTN_L]
	bg := COL_BG3
	if on {
		bg = col
	}
	if h {
		bg = lighten(bg, 0.1)
	}
	if down {
		bg = darken(bg, 0.18)
	}
	fill_round(r, 5, bg)
	frame_round(r, 5, lighten(col, 0.25) if on else COL_LINE2)
	return Color{18, 20, 26, 255} if on else COL_TEXT
}

// A small dark display with a caption: the readouts of the transport bar.
lcd :: proc(r: Rect, caption, value: string, value_col := COL_TEXT, align := Align.Center) {
	if r.w <= 0 {
		return
	}
	h := hover(r)
	if h {
		cursor_hint(.POINTING_HAND)
	}
	fill_round(r, 4, COL_BG0)
	frame_round(r, 4, COL_LINE2 if h else COL_LINE)
	text(r.x + 8, r.y + 7, caption, COL_FAINT, .Small)
	text_in(Rect{r.x, r.y + 15, r.w, r.h - 17}, value, value_col, .Mono_Big, align, 8 if align == .Left else 4)
}

transport_draw :: proc() {
	t := lay.transport
	gradient_v(t, COL_BG3, COL_BG2)
	hline(0, win_w - 1, t.y + t.h - 1, COL_LINE)
	hline(0, win_w - 1, t.y, COL_LINE2)
	tr := transport_rects()

	fg := icon_button(tr.start, false, COL_ACCENT)
	icon_to_start(tr.start.x + tr.start.w / 2, tr.start.y + tr.start.h / 2, 13, fg)
	fg = icon_button(tr.play, play_active, COL_GREEN)
	if play_active {
		icon_stop(tr.play.x + tr.play.w / 2, tr.play.y + tr.play.h / 2, 14, fg)
	} else {
		icon_play(tr.play.x + tr.play.w / 2, tr.play.y + tr.play.h / 2, 16, COL_GREEN)
	}
	fg = icon_button(tr.loop, ed.loop_on, COL_ACCENT)
	icon_loop(tr.loop.x + tr.loop.w / 2, tr.loop.y + tr.loop.h / 2, 15, fg)

	pos := play_pos()
	if tr.pos.w > 0 {
		lcd(tr.pos, "BAR  BEAT  TICK", pos_text(pos), COL_PLAY if play_active else COL_TEXT, .Left)
		text(tr.pos.x + 134, tr.pos.y + 7, "TIME", COL_FAINT, .Small)
		text_in(Rect{tr.pos.x + 124, tr.pos.y + 15, tr.pos.w - 124, tr.pos.h - 17}, time_text(tick_to_seconds(pos)), COL_DIM, .Mono, .Right, 10)
	}
	lcd(tr.tempo, "TEMPO", fmt.tprintf("%.1f", bpm_at(pos)))
	lcd(tr.sig, "SIG", fmt.tprintf("%d/4", ed.beats_per_bar))

	if tr.grid_lbl.w > 0 {
		fg = icon_button(tr.grid_dn, false, COL_ACCENT)
		icon_chevron(tr.grid_dn.x + tr.grid_dn.w / 2, tr.grid_dn.y + tr.grid_dn.h / 2, 10, -1, fg)
		fg = icon_button(tr.grid_up, false, COL_ACCENT)
		icon_chevron(tr.grid_up.x + tr.grid_up.w / 2, tr.grid_up.y + tr.grid_up.h / 2, 10, 1, fg)
		lcd(tr.grid_lbl, "GRID", GRIDS[ed.grid_idx].label)
	}
	lcd(tr.vel, "VELOCITY", vel_text(ed.def_vel))
	if tr.follow.w > 0 {
		draw_toggle(tr.follow, "FOLLOW", ed.follow, COL_ACCENT)
		if hover(tr.follow) {
			cursor_hint(.POINTING_HAND)
		}
	}
	if tr.sound.w > 0 {
		draw_toggle(tr.sound, "SOUND", ed.audition_on, COL_GREEN)
		if hover(tr.sound) {
			cursor_hint(.POINTING_HAND)
		}
	}
}

// ---- side panels ---------------------------------------------------------------------------------------

track_row_rect :: proc(i: int) -> Rect {
	return Rect{lay.tracks.x, lay.tracks.y + HEADER_H + i * TRACK_ROW_H, lay.tracks.w, TRACK_ROW_H}
}

// The M (mute) and S (solo) switches of a row.
ms_rects :: proc(row: Rect) -> (m, s: Rect) {
	w := 22
	h := 16
	s = Rect{row.x + row.w - 12 - w, row.y + (row.h - h) / 2, w, h}
	m = Rect{s.x - 4 - w, s.y, w, h}
	return
}

track_add_rect :: proc() -> Rect {
	return Rect{lay.tracks.x + lay.tracks.w - 32, lay.tracks.y + 3, 22, HEADER_H - 6}
}

Slider_Def :: struct {
	label:   string,
	field:   Mix_Field,
	action:  Action,
	bipolar: bool,
}

INSPECTOR_SLIDERS := [4]Slider_Def {
	{"Volume", .Volume, .Track_Volume, false},
	{"Pan", .Pan, .Track_Pan, true},
	{"Reverb", .Reverb, .Track_Reverb, false},
	{"Delay", .Delay, .Track_Delay, false},
}

insp_row_rect :: proc(i: int) -> Rect {
	return Rect{lay.inspector.x, lay.inspector.y + HEADER_H + 4 + i * INSPECTOR_ROW, lay.inspector.w, INSPECTOR_ROW}
}

// The groove of a slider (inside its row).
insp_track_rect :: proc(i: int) -> Rect {
	r := insp_row_rect(i)
	return Rect{r.x + 14 + 58, r.y, r.w - 14 - 58 - 14 - 42, r.h}
}

// The buttons under the faders: the instrument and its sound; the graph of effects the track plays through (a button
// that shows its name and picks another) and the graph editor.
insp_buttons :: proc() -> (instrument, edit, effects, open: Rect) {
	r := lay.inspector
	y := r.y + r.h - 70
	w := (r.w - 14 * 2 - 8) / 2
	instrument = Rect{r.x + 14, y, w, 26}
	edit = Rect{r.x + 14 + w + 8, y, w, 26}
	open = Rect{r.x + r.w - 14 - 56, y + 34, 56, 26}
	effects = Rect{r.x + 14, y + 34, open.x - 6 - (r.x + 14), 26}
	return
}

fader: struct {
	active:  bool,
	row:     int,
	started: bool, // the first change (which makes the undo step) has been made
}

// The text of a mixer value: "70%", "L40".
mix_text :: proc(field: Mix_Field, v: f32) -> string {
	if field == .Pan {
		pct := int(abs(v) * 100 + 0.5)
		if pct == 0 {
			return "C"
		}
		return fmt.tprintf("%s%d", "L" if v < 0 else "R", pct)
	}
	return fmt.tprintf("%d%%", int(v * 100 + 0.5))
}

fader_set_from_mouse :: proc() {
	d := INSPECTOR_SLIDERS[fader.row]
	tr := insp_track_rect(fader.row)
	t := clamp(f32(in_.mx - tr.x) / f32(max(tr.w, 1)), 0, 1)
	v := t
	if d.bipolar {
		v = t * 2 - 1
		if abs(v) < 0.04 { // a notch at the center
			v = 0
		}
	}
	tmp := ed.p.tracks[ed.cur_track] // (a copy: what the value would be after snapping, to see whether it changed)
	snd.score_track_set_mix(&tmp, d.field, v)
	if snd.score_track_mix(&tmp, d.field) != track_mix(ed.cur_track, d.field) || !(d.field in ed.p.tracks[ed.cur_track].set) {
		track_set_mix(ed.cur_track, d.field, v, !fader.started)
		fader.started = true
	}
}

track_reset_mix :: proc(ti: int, field: Mix_Field) {
	if ti < 0 || ti >= len(ed.p.tracks) {
		return
	}
	ed_edit(false)
	snd.score_track_reset_mix(&ed.p.tracks[ti], field)
}

side_update :: proc() {
	// A fader being dragged.
	if fader.active {
		if in_.down[BTN_L] {
			cursor_hint(.RESIZE_EW)
			fader_set_from_mouse()
		} else {
			fader.active = false
		}
		return
	}

	// Tracks.
	ntr := len(ed.p.tracks)
	tracks_scroll = clamp(tracks_scroll, 0, max(ntr - lay.track_rows, 0))
	if mouse_in(lay.tracks) && in_.wheel_y != 0 {
		tracks_scroll = clamp(tracks_scroll - int(in_.wheel_y), 0, max(ntr - lay.track_rows, 0))
	}
	if ed.cur_track < tracks_scroll {
		tracks_scroll = ed.cur_track
	} else if ed.cur_track >= tracks_scroll + lay.track_rows {
		tracks_scroll = ed.cur_track - lay.track_rows + 1
	}

	if in_.pressed[BTN_L] || in_.pressed[BTN_R] {
		// "+" in the title adds a track.
		if in_.pressed[BTN_L] && mouse_in(track_add_rect()) {
			run_action(.Track_Add)
			return
		}
		for i in 0 ..< lay.track_rows {
			ti := i + tracks_scroll
			if ti >= ntr {
				break
			}
			r := track_row_rect(i)
			if !mouse_in(r) {
				continue
			}
			t := &ed.p.tracks[ti]
			m, s := ms_rects(r)
			if mouse_in(m) {
				t.mute = !t.mute
				mixer_changed()
			} else if mouse_in(s) {
				t.solo = !t.solo
				mixer_changed()
			} else {
				ed.cur_track = ti
				if in_.dbl {
					run_action(.Track_Rename)
				}
			}
		}
		// The faders of the track: drag to change, double-click to reset, right click to type a number.
		for i in 0 ..< 4 {
			r := insp_row_rect(i)
			if !mouse_in(r) {
				continue
			}
			d := INSPECTOR_SLIDERS[i]
			if in_.pressed[BTN_R] {
				run_action(d.action)
			} else if in_.dbl {
				track_reset_mix(ed.cur_track, d.field)
			} else {
				fader = {
					active = true,
					row    = i,
				}
				fader_set_from_mouse()
			}
			return
		}
		if in_.pressed[BTN_L] {
			ib, eb, fb, ob := insp_buttons()
			if mouse_in(ib) {
				run_action(.Track_Instrument)
			} else if mouse_in(eb) {
				run_action(.Track_Patch)
			} else if mouse_in(fb) {
				run_action(.Track_Graph)
			} else if mouse_in(ob) {
				run_action(.View_Effects)
			}
		}
	}

	// The wheel over a fader adjusts it.
	if in_.wheel_y != 0 {
		for i in 0 ..< 4 {
			if mouse_in(insp_row_rect(i)) {
				step := f32(0.04) if !in_.shift else f32(0.01)
				d := INSPECTOR_SLIDERS[i]
				if d.bipolar {
					step *= 2
				}
				track_set_mix(ed.cur_track, d.field, track_mix(ed.cur_track, d.field) + in_.wheel_y * step)
			}
		}
	}
	// The mouse cursor.
	for i in 0 ..< 4 {
		if mouse_in(insp_row_rect(i)) {
			cursor_hint(.RESIZE_EW)
		}
	}
	ib, eb, fb, ob := insp_buttons()
	if mouse_in(ib) || mouse_in(eb) || mouse_in(fb) || mouse_in(ob) || mouse_in(track_add_rect()) {
		cursor_hint(.POINTING_HAND)
	}
}

section_header :: proc(r: Rect, title: string, right := "") {
	gradient_v(r, COL_BG3, COL_BG2)
	hline(r.x, r.x + r.w - 1, r.y + r.h - 1, COL_LINE)
	hline(r.x, r.x + r.w - 1, r.y, COL_LINE2)
	text_in(r, title, COL_DIM, .Bold, .Left, 12)
	if right != "" {
		text_in(r, right, COL_FAINT, .Small, .Right, 40)
	}
}

side_draw :: proc() {
	s := lay.side
	info_update()
	fill(s, COL_BG1)
	vline(s.x, s.y, s.y + s.h - 1, COL_LINE)

	// ---- tracks ----
	tp := lay.tracks
	section_header(Rect{tp.x + 1, tp.y, tp.w - 1, HEADER_H}, "TRACKS", fmt.tprintf("%d", len(ed.p.tracks)) if len(ed.p.tracks) > lay.track_rows else "")
	add := track_add_rect()
	fg := icon_button(add, false, COL_ACCENT)
	icon_plus(add.x + add.w / 2, add.y + add.h / 2, 9, fg)
	saved := clip_to(Rect{tp.x + 1, tp.y + HEADER_H, tp.w - 1, tp.h - HEADER_H})
	for i in 0 ..< lay.track_rows {
		ti := i + tracks_scroll
		if ti >= len(ed.p.tracks) {
			break
		}
		t := &ed.p.tracks[ti]
		r := track_row_rect(i)
		r.x += 1
		r.w -= 1
		cur := ti == ed.cur_track
		col := track_color(ti)
		draw_row(r, cur, hover(r), col)
		m, sb := ms_rects(r)
		empty := track_counts[ti] == 0 if ti < len(track_counts) else true
		chip := Rect{r.x + 12, r.y + 6, 5, r.h - 12}
		fill_round(chip, 2, col if (!empty || cur) else with_alpha(col, 0.35))
		tc := COL_TEXT if (!empty || cur) else COL_DIM
		if t.mute {
			tc = COL_FAINT
		}
		text_in(Rect{r.x + 24, r.y + 3, m.x - r.x - 28, 16}, name_str(&t.name), tc, .Ui, .Left, 2)
		cnt := track_counts[ti] if ti < len(track_counts) else 0
		sub := track_label(ti)
		if cnt > 0 {
			sub = fmt.tprintf("%s  -  %d note%s", sub, cnt, "" if cnt == 1 else "s")
		}
		fx := ""
		if g := snd.score_track_graph(&ed.p, ti); g != nil && !snd.fx_is_trivial(g) {
			fx = "  [fx]"
		}
		text_in(Rect{r.x + 24, r.y + 18, m.x - r.x - 28, 14}, fmt.tprintf("%s%s", sub, fx), COL_FAINT, .Small, .Left, 2)
		draw_flag(m, "M", t.mute, COL_MUTE)
		draw_flag(sb, "S", t.solo, COL_SOLO)
		hline(r.x, r.x + r.w - 1, r.y + r.h - 1, Color{255, 255, 255, 8})
	}
	// A thin scroll bar when not all tracks fit.
	if lay.track_rows < len(ed.p.tracks) {
		area := Rect{tp.x + tp.w - 5, tp.y + HEADER_H, 4, lay.track_rows * TRACK_ROW_H}
		th := max(area.h * lay.track_rows / len(ed.p.tracks), 14)
		pos := tracks_scroll * (area.h - th) / max(len(ed.p.tracks) - lay.track_rows, 1)
		fill_round(Rect{area.x, area.y + pos, area.w, th}, 2, COL_BG4)
	}
	clip_restore(saved)

	// ---- the faders of the current track ----
	ip := lay.inspector
	ti := ed.cur_track
	col := track_color(ti)
	fill(Rect{ip.x + 1, ip.y, ip.w - 1, ip.h}, COL_BG1)
	hdr := Rect{ip.x + 1, ip.y, ip.w - 1, HEADER_H}
	section_header(hdr, "")
	fill_round(Rect{ip.x + 12, ip.y + 6, 5, HEADER_H - 12}, 2, col)
	text_in(Rect{ip.x + 1, ip.y, ip.w - 1, HEADER_H}, name_str(&ed.p.tracks[ti].name), COL_TEXT, .Bold, .Left, 24)
	for i in 0 ..< 4 {
		d := INSPECTOR_SLIDERS[i]
		r := insp_row_rect(i)
		v := track_mix(ti, d.field)
		active := (fader.active && fader.row == i) || hover(r)
		text_in(Rect{r.x + 14, r.y, 58, r.h}, d.label, COL_DIM, .Ui, .Left, 0)
		t := v if !d.bipolar else (v + 1) * 0.5
		draw_slider(insp_track_rect(i), t, col, active, d.bipolar)
		text_in(Rect{r.x + r.w - 14 - 42, r.y, 42, r.h}, mix_text(d.field, v), COL_TEXT if active else COL_DIM, .Mono, .Right, 0)
	}
	ib, eb, fb, ob := insp_buttons()
	draw_button(ib, "Instrument...")
	draw_button(eb, "Edit sound...")
	fx_name := "Effects: none"
	if g := snd.score_track_graph(&ed.p, ti); g != nil {
		fx_name = fmt.tprintf("Fx: %s", snd.fx_graph_name(g))
	}
	draw_button(fb, fx_name)
	draw_button(ob, "Edit", ed.view == .Graph)
}

// ---- status bar ------------------------------------------------------------------------------------------------

status_draw :: proc() {
	s := lay.status
	fill(s, COL_BG2)
	hline(0, win_w - 1, s.y, COL_LINE)
	x := 10
	if play_active { // (the only badge: what the transport does; the editor itself has no modes)
		w := text_width("PLAYING", .Small) + 16
		r := Rect{x, s.y + 4, w, s.h - 8}
		fill_round(r, 4, COL_GREEN)
		text_in(r, "PLAYING", Color{14, 40, 24, 255}, .Small, .Center, 0)
		x += w + 8
	}
	if ed.count > 0 {
		cs := fmt.tprintf("%d", ed.count)
		w := text_width(cs, .Mono) + 14
		r := Rect{x, s.y + 4, w, s.h - 8}
		fill_round(r, 4, COL_ACCENT_DIM)
		text_in(r, cs, COL_TEXT, .Mono, .Center, 0)
		x += w + 8
	}
	m := ed_msg_text()
	hint := false
	if m == "" {
		m = "F1 help   Ctrl+P commands"
		hint = true
	}

	// Right: key, position, selection.
	key := ed.cursor_key
	info := fmt.tprintf("%s   %s   Track %d", key_label(key), pos_text(ed.cursor_tick), ed.cur_track + 1)
	if n := sel_count(); n > 0 {
		info = fmt.tprintf("%d selected   %s", n, info)
	}
	if !audio_on {
		info = fmt.tprintf("NO AUDIO   %s", info)
	}
	iw := text_width(info, .Mono)
	text_in(Rect{s.x, s.y, s.w, s.h}, info, COL_DIM, .Mono, .Right, 12)
	text_in(Rect{x, s.y, max(s.w - x - iw - 30, 10), s.h}, m, COL_FAINT if hint else COL_TEXT, .Ui, .Left, 0)
}

_ :: rl
_ :: strings
