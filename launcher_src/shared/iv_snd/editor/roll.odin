package main

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import snd "shared:iv_snd"
import ui "shared:iv_ui"

// ---------------------------------------------------------------------------
// The piano roll: layout, drawing, keyboard and mouse editing.
// ---------------------------------------------------------------------------

ROW_H_DEFAULT :: 14 // height of a key row in pixels
ROW_H_MIN :: 8
ROW_H_MAX :: 32
SIDE_W :: 292
TRANSPORT_H :: 54
STATUS_H :: 24
VEL_H :: 88 // the velocity lane with its scroll bar
RULER_H :: 28
SCROLL_W :: 12
KEYS_W :: 66
KEYS_KIT_W :: 176

HEADER_H :: 26 // the title of a section of the side panel
TRACK_ROW_H :: 36
INSPECTOR_ROW :: 28

Layout :: struct {
	menubar, transport, status: Rect,
	roll:                       Rect, // the whole piano roll area
	ruler, keys, grid, vel:     Rect,
	hbar, vbar:                 Rect, // scroll bars
	side, tracks:               Rect,
	inspector:                  Rect, // the sliders of the current track
	track_rows:                 int, // tracks visible in the list
}

lay: Layout

// Where everything goes, worked out from the size of the window with the shared `ui` package's cuts: each cut takes a
// strip off a rectangle and gives back the strip and what is left.
layout_update :: proc() {
	ed.row_h = clamp(ed.row_h, ROW_H_MIN, ROW_H_MAX)
	l: Layout
	rest := ui.make_rect(0, 0, win_w, win_h)
	l.menubar, rest = ui.cut_top(rest, MENU_H)
	l.transport, rest = ui.cut_top(rest, TRANSPORT_H)
	l.status, rest = ui.cut_bottom(rest, STATUS_H)
	body := ui.with_height(rest, max(rest.h, 60))
	l.side, l.roll = ui.cut_right(body, min(SIDE_W, win_w / 3))

	// The roll: the keys on the left, the scroll bar on the right, and between them the ruler, the grid, the velocity
	// lane and the scroll bar of the time.
	keys_w := KEYS_W
	if track_key_labels(ed.cur_track) != nil { // a sampler with unpitched zones: the keys carry the names of their recordings
		keys_w = KEYS_KIT_W
	}
	keys_w = min(keys_w, l.roll.w / 3)
	keys_col, middle := ui.cut_left(l.roll, keys_w)
	vbar_col: ui.Rect
	vbar_col, middle = ui.cut_right(middle, SCROLL_W)
	middle.w = max(middle.w, 16)
	vel_h := min(VEL_H, body.h / 4)
	l.ruler, middle = ui.cut_top(middle, RULER_H)
	bottom_strip, grid := ui.cut_bottom(middle, vel_h)
	l.hbar, l.vel = ui.cut_bottom(bottom_strip, SCROLL_W)
	l.grid = ui.with_height(grid, max(grid.h, ed.row_h))
	l.vbar = ui.with_height(ui.at(vbar_col, vbar_col.x, l.grid.y), l.grid.h)
	l.keys = ui.with_height(ui.at(keys_col, keys_col.x, l.grid.y), l.grid.h)

	// Side panel: the tracks on top, the sliders of the current track at the bottom.
	insp_h := HEADER_H + 4 * INSPECTOR_ROW + 82
	room := l.side.h - insp_h - HEADER_H
	ntr := clamp(room / TRACK_ROW_H, 1, max(len(ed.p.tracks), 1))
	l.track_rows = ntr
	l.tracks, _ = ui.cut_top(l.side, HEADER_H + ntr * TRACK_ROW_H + 2)
	l.inspector, _ = ui.cut_bottom(l.side, insp_h)
	lay = l
	ed.roll_rows = max(l.grid.h / ed.row_h, 1)
	ed.roll_ticks = max(l.grid.w * int(ed.p.tpb) / max(ed.beat_px, 1), 1)
}

// ---- coordinates ------------------------------------------------------------------------------------

floor_div :: proc(a, b: int) -> int {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) {
		q -= 1
	}
	return q
}

tick_to_x :: proc(t: int) -> int {
	return lay.grid.x + floor_div((t - ed.scroll_tick) * ed.beat_px, int(ed.p.tpb))
}

x_to_tick :: proc(x: int) -> int {
	return ed.scroll_tick + floor_div((x - lay.grid.x) * int(ed.p.tpb), max(ed.beat_px, 1))
}

key_to_y :: proc(k: int) -> int {
	return lay.grid.y + (ed.scroll_key - k) * ed.row_h
}

y_to_key :: proc(y: int) -> int {
	return ed.scroll_key - floor_div(y - lay.grid.y, ed.row_h)
}

snap_floor :: proc(t: int) -> int {
	g := int(grid_ticks())
	return max(floor_div(t, g) * g, 0)
}

snap_round :: proc(t: int) -> int {
	g := int(grid_ticks())
	return max(floor_div(t + g / 2, g) * g, 0)
}

// ---- view ------------------------------------------------------------------------------------------------

// The lowest key row that can be at the top of the view.
min_scroll_key :: proc() -> int {
	return min(ed.roll_rows - 1, 127)
}

// Scrolls so that the cursor is visible.
roll_keep_cursor_visible :: proc() {
	margin := int(grid_ticks()) * 2
	ct := int(ed.cursor_tick)
	if ct < ed.scroll_tick + margin {
		ed.scroll_tick = max(ct - margin, 0)
	}
	if ct + int(insert_len()) > ed.scroll_tick + ed.roll_ticks - margin {
		ed.scroll_tick = max(ct + int(insert_len()) + margin - ed.roll_ticks, 0)
	}
	if ed.cursor_key > ed.scroll_key - 1 {
		ed.scroll_key = min(ed.cursor_key + 1, 127)
	}
	if ed.cursor_key < ed.scroll_key - ed.roll_rows + 2 {
		ed.scroll_key = min(ed.cursor_key + ed.roll_rows - 2, 127)
	}
	ed.scroll_key = clamp(ed.scroll_key, min_scroll_key(), 127)
}

cursor_goto :: proc(tick: u32, key: int) {
	ed.sel_active = false
	ed.cursor_tick = tick
	ed.cursor_key = clamp(key, 0, 127)
	roll_keep_cursor_visible()
}

// Moves the cursor. With `extend` (Shift) the notes in the rectangle from where the cursor was when the
// extending started to the cursor are selected; any other move ends that.
cursor_move :: proc(dt: int, dk: int, sound := true, extend := false) {
	if extend {
		if !ed.sel_active {
			ed.sel_active = true
			ed.anchor_tick = ed.cursor_tick
			ed.anchor_key = ed.cursor_key
		}
	} else {
		ed.sel_active = false
	}
	ed.cursor_tick = u32(max(int(ed.cursor_tick) + dt, 0))
	nk := clamp(ed.cursor_key + dk, 0, 127)
	moved_key := nk != ed.cursor_key
	ed.cursor_key = nk
	if extend {
		sel_rect(ed.anchor_tick, ed.cursor_tick, ed.anchor_key, ed.cursor_key)
	}
	if moved_key && sound {
		audition(ed.cur_track, ed.cursor_key, ed.def_vel)
	}
	roll_keep_cursor_visible()
}

// Moves the notes (the selected ones, or the one under the cursor) and the cursor with them. The moves
// made while Alt is held down are one step of undo.
nudge_targets :: proc(dt: int, dk: int) {
	ed.sel_active = false
	if len(targets()) == 0 {
		ed_say("Nothing to move: select notes, or put the cursor on one")
		return
	}
	if !move_snapshot {
		ed_edit()
		move_snapshot = true
	}
	if ed_move_targets(dt, dk) {
		ed_changed()
		ed.cursor_tick = u32(max(int(ed.cursor_tick) + dt, 0))
		ed.cursor_key = clamp(ed.cursor_key + dk, 0, 127)
		if dk != 0 {
			audition(ed.cur_track, ed.cursor_key, ed.def_vel)
		}
	}
	roll_keep_cursor_visible()
}

move_snapshot: bool

set_ui_scale :: proc(s: f32) {
	ui_set_scale(s)
	ed_say("Interface size %d%%", int(ui_scale * 100 + 0.5))
}

// Scrolls the roll so that notes of the current track are in view: called when another track becomes the current
// one, since tracks live in different registers and play at different times. Nothing moves if one is already in view.
roll_focus_track :: proc() {
	lo, hi := 128, -1
	first := max(u32)
	top := ed.scroll_key
	bottom := ed.scroll_key - ed.roll_rows + 1
	visible := false
	for n in ed.p.notes {
		if n.track != ed.cur_track {
			continue
		}
		k := int(n.key)
		lo = min(lo, k)
		hi = max(hi, k)
		first = min(first, n.start)
		if k <= top && k >= bottom && int(n.start) < ed.scroll_tick + ed.roll_ticks && int(n.start + note_span(n)) > ed.scroll_tick {
			visible = true
		}
	}
	if hi < 0 || visible {
		return
	}
	mid := (lo + hi) / 2
	ed.scroll_key = clamp(mid + ed.roll_rows / 2, min_scroll_key(), 127)
	ed.cursor_key = clamp(mid, 0, 127)
	bar := int(bar_ticks())
	ed.scroll_tick = int(first) / bar * bar
	ed.cursor_tick = first
}

// ---- drawing -----------------------------------------------------------------------------------------------

roll_draw :: proc() {
	g := lay.grid
	rh := ed.row_h
	fill(lay.roll, COL_BG1)
	saved := clip_to(g)

	// Rows: black keys darker, a bright line at every C.
	first_key := y_to_key(g.y)
	last_key := y_to_key(g.y + g.h - 1)
	for k := last_key; k <= first_key; k += 1 {
		y := key_to_y(k)
		if k < 0 || k > 127 {
			fill(Rect{g.x, y, g.w, rh}, ROLL_OUTSIDE)
			continue
		}
		fill(Rect{g.x, y, g.w, rh}, ROLL_BLACK if is_black_key(k) else ROLL_WHITE)
		if k % 12 == 0 {
			hline(g.x, g.x + g.w - 1, y + rh - 1, Color{255, 255, 255, 60})
		} else {
			hline(g.x, g.x + g.w - 1, y + rh - 1, Color{255, 255, 255, 9})
		}
	}

	// Time lines: every other bar a little lighter, grid steps (faint), beats, bars.
	t0 := ed.scroll_tick
	t1 := ed.scroll_tick + ed.roll_ticks + 1
	gt := int(grid_ticks())
	tpb := int(ed.p.tpb)
	bar := int(bar_ticks())
	for b := floor_div(t0, bar); b * bar <= t1; b += 1 {
		if b >= 0 && b % 2 == 1 {
			x0 := tick_to_x(b * bar)
			x1 := tick_to_x((b + 1) * bar)
			fill(Rect{x0, g.y, x1 - x0, g.h}, Color{255, 255, 255, 6})
		}
	}
	if gt * ed.beat_px / tpb >= 6 {
		for t := floor_div(t0, gt) * gt; t <= t1; t += gt {
			if t >= 0 && t % tpb != 0 {
				vline(tick_to_x(t), g.y, g.y + g.h - 1, GRID_SUB)
			}
		}
	}
	for t := floor_div(t0, tpb) * tpb; t <= t1; t += tpb {
		if t < 0 {
			continue
		}
		x := tick_to_x(t)
		if t % bar == 0 {
			vline(x, g.y, g.y + g.h - 1, GRID_BAR)
		} else if ed.beat_px >= 12 {
			vline(x, g.y, g.y + g.h - 1, GRID_BEAT)
		}
	}
	// The row of the cursor.
	if ed.cursor_key >= 0 && ed.cursor_key <= 127 {
		fill(Rect{g.x, key_to_y(ed.cursor_key), g.w, rh}, Color{255, 255, 255, 11})
	}
	// Loop and song end.
	if ed.p.loop_end > ed.p.loop_start {
		x0 := tick_to_x(int(ed.p.loop_start))
		x1 := tick_to_x(int(ed.p.loop_end))
		fill(Rect{x0, g.y, x1 - x0, g.h}, with_alpha(COL_ACCENT, 0.07))
		fill(Rect{x0, g.y, 2, g.h}, with_alpha(COL_ACCENT, 0.85))
		fill(Rect{x1 - 2, g.y, 2, g.h}, with_alpha(COL_ACCENT, 0.85))
	}
	if ed.p.end_tick > 0 {
		x := tick_to_x(int(ed.p.end_tick))
		fill(Rect{x, g.y, 2, g.h}, with_alpha(COL_RED, 0.55))
	}

	// Notes: the other tracks first, as faint ghosts if they are switched on, then the current track.
	for pass in 0 ..< 2 {
		if pass == 0 && !ed.ghost_tracks {
			continue
		}
		for n in ed.p.notes {
			cur := n.track == ed.cur_track
			if (pass == 1) != cur {
				continue
			}
			draw_note(n, cur)
		}
	}

	// The rectangle of a selection that is being extended with the keys.
	if ed.sel_active {
		x0 := tick_to_x(int(min(ed.anchor_tick, ed.cursor_tick)))
		x1 := tick_to_x(int(max(ed.anchor_tick, ed.cursor_tick) + insert_len()))
		ya := max(ed.anchor_key, ed.cursor_key)
		yb := min(ed.anchor_key, ed.cursor_key)
		r := Rect{x0, key_to_y(ya), x1 - x0, (ya - yb + 1) * rh}
		fill(r, with_alpha(COL_ACCENT, 0.12))
		frame(r, with_alpha(COL_ACCENT, 0.9))
	}
	// The cursor: where the next note goes.
	{
		x0 := tick_to_x(int(ed.cursor_tick))
		x1 := tick_to_x(int(ed.cursor_tick + insert_len()))
		r := Rect{x0, key_to_y(ed.cursor_key), max(x1 - x0, 4), rh}
		fill(r, with_alpha(COL_ACCENT, 0.18))
		frame(r, COL_ACCENT)
		frame(ui.inset(r, 1), Color{0, 0, 0, 90})
	}

	// Rubber band while dragging.
	if drag.kind == .Band {
		r := band_rect()
		fill(r, with_alpha(COL_ACCENT, 0.14))
		frame(r, with_alpha(COL_ACCENT, 0.95))
	}

	// The play head.
	if play_active {
		x := tick_to_x(int(play_pos()))
		fill(Rect{x - 3, g.y, 6, g.h}, with_alpha(COL_PLAY, 0.10))
		fill(Rect{x, g.y, 2, g.h}, COL_PLAY)
	}
	clip_restore(saved)

	draw_keys()
	draw_ruler()
	draw_vel_lane()
	draw_scrollbars()
}

note_rect :: proc(n: Note) -> Rect {
	x0 := tick_to_x(int(n.start))
	x1 := tick_to_x(int(n.start + note_span(n)))
	return Rect{x0, key_to_y(int(n.key)) + 1, max(x1 - x0, 4), ed.row_h - 2}
}

draw_note :: proc(n: Note, current: bool) {
	r := note_rect(n)
	g := lay.grid
	if r.x > g.x + g.w || r.x + r.w < g.x || r.y + r.h < g.y || r.y > g.y + g.h {
		return
	}
	base := track_color(n.track)
	if !current {
		// Another track: a faint ghost with an outline.
		fill(r, with_alpha(base, 0.14 if !n.sel else 0.3))
		frame(r, with_alpha(base, 0.55))
		return
	}
	vel := f32(n.vel) / 127
	col := mix(darken(base, 0.55), base, 0.4 + 0.6 * vel)
	if n.sel {
		col = lighten(base, 0.38)
	} else if drag.kind == .None && !ui_blocked && mouse_in(r) {
		col = lighten(col, 0.1)
	}
	if r.w < 7 || r.h < 8 {
		fill(r, col)
	} else {
		fill_round(r, 2, darken(base, 0.62))
		inner := ui.inset(r, 1)
		fill_round(inner, 2, col)
		gradient_v(Rect{inner.x + 1, inner.y, max(inner.w - 2, 1), max(inner.h / 2, 1)}, Color{255, 255, 255, 46}, Color{255, 255, 255, 0})
	}
	if n.sel {
		frame_round(r, 2, Color{255, 255, 255, 235})
	}
	if n.len == 0 {
		// An open note (no note-off): it fades out to the right to show that it goes on.
		end := min(r.x + r.w + 90, g.x + g.w)
		if end > r.x + r.w {
			gradient_h(Rect{r.x + r.w, r.y + 2, end - r.x - r.w, max(r.h - 4, 1)}, with_alpha(base, 0.55), with_alpha(base, 0))
		}
	}
	if r.w >= 36 && r.h >= 12 {
		text_in(r, key_label(int(n.key)), Color{16, 18, 24, 215}, .Small, .Left, 5)
	}
}

draw_keys :: proc() {
	k := lay.keys
	saved := clip_to(k)
	fill(k, COL_BG0)
	kit := track_key_labels(ed.cur_track) // the sampler whose zones name the keys, if any
	drums := kit != nil
	rh := ed.row_h
	first_key := y_to_key(k.y)
	last_key := y_to_key(k.y + k.h - 1)
	for key := last_key; key <= first_key; key += 1 {
		if key < 0 || key > 127 {
			continue
		}
		y := key_to_y(key)
		row := Rect{k.x, y, k.w - 1, rh}
		black := is_black_key(key)
		if drums {
			fill(row, COL_BG2 if black else COL_BG1)
			hline(k.x, k.x + k.w - 2, y + rh - 1, Color{255, 255, 255, 14})
			if nm := zone_key_label(kit, key); nm != "" {
				text_in(row, nm, COL_TEXT if key == ed.cursor_key else COL_DIM, .Small, .Left, 8)
			}
		} else {
			gradient_h(row, KEY_WHITE_TOP, KEY_WHITE_BOTTOM)
			if black {
				bar := Rect{k.x, y, int(f32(k.w) * 0.62), rh}
				fill_round(bar, 2, KEY_BLACK)
				gradient_v(Rect{bar.x + 1, bar.y + 1, max(bar.w - 4, 1), max(rh / 2 - 1, 1)}, Color{255, 255, 255, 30}, Color{255, 255, 255, 0})
			} else if key % 12 == 0 || key % 12 == 5 { // a line where two white keys meet
				hline(k.x, k.x + k.w - 2, y + rh - 1, Color{110, 116, 132, 255})
			}
			if key % 12 == 0 {
				text_in(row, key_label(key), Color{60, 66, 82, 255}, .Small, .Right, 5)
			}
		}
		if key == ed.cursor_key {
			fill(row, with_alpha(COL_ACCENT, 0.5))
		}
	}
	vline(k.x + k.w - 1, k.y, k.y + k.h - 1, COL_LINE)
	clip_restore(saved)
}

draw_ruler :: proc() {
	r := lay.ruler
	band := Rect{0, r.y, lay.roll.w, r.h}
	gradient_v(band, COL_BG3, COL_BG2)
	hline(0, lay.roll.w - 1, r.y + r.h - 1, COL_LINE)
	// The corner above the keys shows the current track.
	corner := Rect{0, r.y, lay.keys.w, r.h}
	fill(corner, COL_BG2)
	vline(corner.w - 1, r.y, r.y + r.h - 1, COL_LINE)
	chip := Rect{8, r.y + (r.h - 12) / 2, 6, 12}
	fill_round(chip, 2, track_color(ed.cur_track))
	text_in(Rect{18, r.y, corner.w - 18, r.h}, name_str(&ed.p.tracks[ed.cur_track].name), COL_TEXT, .Small, .Left, 4)

	saved := clip_to(r)
	tpb := int(ed.p.tpb)
	bar := int(bar_ticks())
	t0 := ed.scroll_tick
	t1 := ed.scroll_tick + ed.roll_ticks + 1
	// Loop region.
	if ed.p.loop_end > ed.p.loop_start {
		x0 := tick_to_x(int(ed.p.loop_start))
		x1 := tick_to_x(int(ed.p.loop_end))
		fill(Rect{x0, r.y + r.h - 9, x1 - x0, 7}, with_alpha(COL_ACCENT, 0.9))
		fill(Rect{x0, r.y + r.h - 9, 2, 9}, COL_ACCENT)
		fill(Rect{x1 - 2, r.y + r.h - 9, 2, 9}, COL_ACCENT)
	}
	bar_px := bar * ed.beat_px / max(tpb, 1)
	label_step := max((44 + bar_px - 1) / max(bar_px, 1), 1)
	for t := floor_div(t0, tpb) * tpb; t <= t1; t += tpb {
		if t < 0 {
			continue
		}
		x := tick_to_x(t)
		if t % bar == 0 {
			vline(x, r.y + 4, r.y + r.h - 1, Color{255, 255, 255, 90})
			if (t / bar) % label_step == 0 {
				text(x + 5, r.y + 5, fmt.tprintf("%d", t / bar + 1), COL_TEXT, .Small)
			}
		} else if ed.beat_px >= 10 {
			vline(x, r.y + r.h - 6, r.y + r.h - 1, Color{255, 255, 255, 50})
		}
	}
	// Song end.
	if ed.p.end_tick > 0 {
		x := tick_to_x(int(ed.p.end_tick))
		fill(Rect{x, r.y + 3, 2, r.h - 3}, COL_RED)
		fill(Rect{x - 6, r.y + 3, 6, 6}, COL_RED)
	}
	// The cursor (a small arrow) and the play head.
	cx := f32(tick_to_x(int(ed.cursor_tick)))
	ay := f32(r.y + r.h - 10)
	triangle(cx - 5, ay, cx + 6, ay, cx, ay + 8, COL_ACCENT)
	if play_active {
		px := tick_to_x(int(play_pos()))
		fill(Rect{px, r.y, 2, r.h}, COL_PLAY)
		triangle(f32(px) - 5, f32(r.y), f32(px) + 7, f32(r.y), f32(px) + 1, f32(r.y) + 8, COL_PLAY)
	}
	clip_restore(saved)
}

draw_vel_lane :: proc() {
	v := lay.vel
	area := Rect{0, v.y, lay.roll.w, v.h + SCROLL_W}
	fill(area, COL_BG0)
	hline(0, lay.roll.w - 1, v.y, COL_LINE)
	vline(lay.keys.w - 1, v.y, v.y + v.h - 1, COL_LINE)
	text_in(Rect{0, v.y + 4, lay.keys.w - 4, 14}, "VELOCITY", COL_FAINT, .Small, .Right, 4)
	saved := clip_to(v)
	top := v.y + 6
	span := v.h - 10
	for f in ([?]f32{0.25, 0.5, 0.75, 1}) { // guide lines
		hline(v.x, v.x + v.w - 1, v.y + v.h - 4 - int(f * f32(span)), Color{255, 255, 255, 12 if f < 1 else 24})
	}
	bar := int(bar_ticks())
	for t := floor_div(ed.scroll_tick, bar) * bar; t <= ed.scroll_tick + ed.roll_ticks; t += bar {
		if t >= 0 {
			vline(tick_to_x(t), v.y, v.y + v.h - 1, Color{255, 255, 255, 16})
		}
	}
	_ = top
	for n in ed.p.notes {
		if n.track != ed.cur_track {
			continue
		}
		x := tick_to_x(int(n.start))
		if x < v.x - 4 || x > v.x + v.w + 4 {
			continue
		}
		h := span * int(n.vel) / 127
		ty := v.y + v.h - 4 - h
		col := track_color(n.track)
		if n.sel {
			col = lighten(col, 0.4)
		}
		fill(Rect{x, ty, 2, v.y + v.h - 4 - ty}, with_alpha(col, 0.9))
		circle(x + 1, ty, 3.5 if n.sel else 3, col)
		if n.sel {
			circle(x + 1, ty, 1.5, Color{255, 255, 255, 255})
		}
	}
	clip_restore(saved)
}

// Scroll bar geometry: the thumb of the vertical bar (keys) and of the horizontal one (time).
vbar_thumb :: proc() -> Rect {
	b := lay.vbar
	th := max(b.h * ed.roll_rows / 128, 18)
	room := max(b.h - th, 1)
	top := min(ed.scroll_key, 127)
	pos := (127 - top) * room / max(128 - ed.roll_rows, 1)
	return Rect{b.x + 2, b.y + clamp(pos, 0, room), b.w - 4, th}
}

hbar_span :: proc() -> int {
	return max(int(project_end(&ed.p)) + 4 * int(bar_ticks()), ed.scroll_tick + ed.roll_ticks)
}

hbar_thumb :: proc() -> Rect {
	b := lay.hbar
	span := hbar_span()
	tw := max(b.w * ed.roll_ticks / span, 24)
	room := max(b.w - tw, 1)
	pos := ed.scroll_tick * room / max(span - ed.roll_ticks, 1)
	return Rect{b.x + clamp(pos, 0, room), b.y + 2, tw, b.h - 4}
}

draw_scrollbars :: proc() {
	b := lay.vbar
	fill(b, COL_BG0)
	vline(b.x, b.y, b.y + b.h - 1, COL_LINE)
	draw_thumb(vbar_thumb(), drag.kind == .Scroll_V || (drag.kind == .None && hover(vbar_thumb())))
	h := lay.hbar
	fill(Rect{0, h.y, lay.roll.w, h.h}, COL_BG0)
	fill(Rect{b.x, h.y, b.w, h.h}, COL_BG0)
	draw_thumb(hbar_thumb(), drag.kind == .Scroll_H || (drag.kind == .None && hover(hbar_thumb())))
}

// ---- mouse ---------------------------------------------------------------------------------------------------

Drag_Kind :: enum {
	None,
	Move,
	Resize,
	Band,
	Pan,
	Ruler,
	Vel,
	Scroll_V,
	Scroll_H,
}

Drag_Note :: struct {
	idx:   int,
	start: u32,
	len:   u32,
	key:   u8,
}

Drag :: struct {
	kind:             Drag_Kind,
	notes:            [dynamic]Drag_Note,
	press_x, press_y: int,
	org_tick:         int,
	org_key:          int,
	changed:          bool,
	vel_note:         int,
	pan_y:            int, // vertical pixels dragged that have not yet made a whole row
}

drag: Drag

band_rect :: proc() -> Rect {
	x0 := min(drag.press_x, in_.mx)
	y0 := min(drag.press_y, in_.my)
	x1 := max(drag.press_x, in_.mx)
	y1 := max(drag.press_y, in_.my)
	return Rect{x0, y0, x1 - x0 + 1, y1 - y0 + 1}
}

// The note under a pixel: one of the current track, or, when the other tracks are shown, one of those (clicking it
// switches to its track).
note_at_pixel :: proc(px, py: int) -> int {
	for pass in 0 ..< 2 {
		if pass == 1 && !ed.ghost_tracks {
			break
		}
		for i := len(ed.p.notes) - 1; i >= 0; i -= 1 {
			n := ed.p.notes[i]
			if (n.track == ed.cur_track) != (pass == 0) {
				continue
			}
			r := note_rect(n)
			r.y -= 1
			r.h += 2
			if ui.contains(r, px, py) {
				return i
			}
		}
	}
	return -1
}

// The right edge of a note, where a drag resizes it.
resize_zone :: proc(r: Rect) -> int {
	return r.x + r.w - min(7, max(r.w / 3, 3))
}

drag_capture :: proc() {
	clear(&drag.notes)
	for i in targets() {
		n := ed.p.notes[i]
		append(&drag.notes, Drag_Note{i, n.start, n.len, n.key})
	}
}

select_note_with_click :: proc(i: int) {
	n := ed.p.notes[i]
	if n.track != ed.cur_track { // a note of another track (shown as a ghost): its track becomes the current one
		sel_clear()
		ed.cur_track = clamp(n.track, 0, len(ed.p.tracks) - 1)
		ed.p.notes[i].sel = true
		return
	}
	if in_.shift {
		ed.p.notes[i].sel = !ed.p.notes[i].sel
	} else if !n.sel {
		sel_clear()
		ed.p.notes[i].sel = true
	}
}

roll_mouse :: proc() {
	g := lay.grid

	// Finish or continue a drag first.
	if drag.kind != .None {
		roll_drag_update()
		return
	}

	// The mouse cursor shows what a click would do.
	if mouse_in(g) {
		if i := note_at_pixel(in_.mx, in_.my); i >= 0 {
			if ed.p.notes[i].track == ed.cur_track && in_.mx >= resize_zone(note_rect(ed.p.notes[i])) {
				cursor_hint(.RESIZE_EW)
			} else {
				cursor_hint(.POINTING_HAND)
			}
		} else {
			cursor_hint(.CROSSHAIR)
		}
	} else if mouse_in(lay.ruler) || mouse_in(lay.keys) {
		cursor_hint(.POINTING_HAND)
	} else if mouse_in(lay.vel) {
		cursor_hint(.RESIZE_NS)
	}

	// Wheel.
	over_roll := mouse_in(lay.roll)
	if over_roll {
		if in_.ctrl && in_.wheel_y != 0 {
			before := x_to_tick(in_.mx)
			for _ in 0 ..< int(abs(in_.wheel_y)) {
				if in_.wheel_y > 0 {
					ed.beat_px = min(ed.beat_px * 5 / 4 + 1, 320)
				} else {
					ed.beat_px = max(ed.beat_px * 4 / 5, 6)
				}
			}
			after := x_to_tick(in_.mx)
			ed.scroll_tick = max(ed.scroll_tick + before - after, 0)
		} else if in_.alt && in_.wheel_y != 0 { // taller / shorter rows
			ed.row_h = clamp(ed.row_h + int(in_.wheel_y) * 2, ROW_H_MIN, ROW_H_MAX)
			layout_update()
			ed.scroll_key = clamp(ed.scroll_key, min_scroll_key(), 127)
		} else if in_.shift && in_.wheel_y != 0 {
			ed.scroll_tick = max(ed.scroll_tick - int(in_.wheel_y * 2 * f32(ed.p.tpb)), 0)
		} else if in_.wheel_y != 0 {
			ed.scroll_key = clamp(ed.scroll_key + int(in_.wheel_y * 3), min_scroll_key(), 127)
		}
		if in_.wheel_x != 0 {
			ed.scroll_tick = max(ed.scroll_tick + int(in_.wheel_x * 2 * f32(ed.p.tpb)), 0)
		}
	}

	if in_.pressed[BTN_M] && mouse_in(g) {
		drag = Drag {
			kind    = .Pan,
			press_x = in_.mx,
			press_y = in_.my,
		}
		return
	}

	// Scroll bars.
	if in_.pressed[BTN_L] && mouse_in(lay.vbar) {
		drag = Drag {
			kind = .Scroll_V,
		}
		roll_drag_update()
		return
	}
	if in_.pressed[BTN_L] && mouse_in(lay.hbar) {
		drag = Drag {
			kind = .Scroll_H,
		}
		roll_drag_update()
		return
	}

	// Ruler: set the cursor (and the play position while playing).
	if in_.pressed[BTN_L] && mouse_in(lay.ruler) {
		drag.kind = .Ruler
		ed.cursor_tick = u32(snap_round(x_to_tick(in_.mx)))
		if play_active {
			play_start(ed.cursor_tick)
		}
		return
	}

	// Piano keys: set the cursor key and sound it.
	if in_.pressed[BTN_L] && mouse_in(lay.keys) {
		ed.cursor_key = clamp(y_to_key(in_.my), 0, 127)
		audition(ed.cur_track, ed.cursor_key, ed.def_vel)
		return
	}

	// Velocity lane.
	if in_.pressed[BTN_L] && mouse_in(lay.vel) {
		best := -1
		bd := 1000
		for n, i in ed.p.notes {
			if n.track != ed.cur_track {
				continue
			}
			d := abs(tick_to_x(int(n.start)) + 1 - in_.mx)
			if d < bd || (d == bd && n.sel) {
				bd = d
				best = i
			}
		}
		if best >= 0 && bd <= 6 {
			drag = Drag {
				kind     = .Vel,
				vel_note = best,
			}
			if !ed.p.notes[best].sel {
				sel_clear()
				ed.p.notes[best].sel = true
			}
			ed_edit(false)
			roll_drag_update()
		}
		return
	}

	if !mouse_in(g) {
		return
	}

	// Right button deletes the note under the pointer.
	if in_.pressed[BTN_R] {
		if i := note_at_pixel(in_.mx, in_.my); i >= 0 {
			ed_edit()
			ordered_remove(&ed.p.notes, i)
		}
		return
	}

	if in_.pressed[BTN_L] {
		tick := snap_floor(x_to_tick(in_.mx))
		key := clamp(y_to_key(in_.my), 0, 127)
		if i := note_at_pixel(in_.mx, in_.my); i >= 0 {
			select_note_with_click(i)
			ed.cursor_tick = ed.p.notes[i].start
			ed.cursor_key = int(ed.p.notes[i].key)
			r := note_rect(ed.p.notes[i])
			drag = Drag {
				kind     = .Move,
				press_x  = in_.mx,
				press_y  = in_.my,
				org_tick = tick,
				org_key  = key,
			}
			if in_.mx >= resize_zone(r) {
				drag.kind = .Resize
			}
			drag_capture()
			audition(ed.p.notes[i].track, int(ed.p.notes[i].key), int(ed.p.notes[i].vel))
		} else if in_.dbl {
			ed.cursor_tick = u32(tick)
			ed.cursor_key = key
			if ed_insert_note() {
				audition(ed.cur_track, ed.cursor_key, ed.def_vel)
			}
		} else {
			ed.cursor_tick = u32(tick)
			ed.cursor_key = key
			if !in_.shift {
				sel_clear()
			}
			ed.sel_active = false
			drag = Drag {
				kind    = .Band,
				press_x = in_.mx,
				press_y = in_.my,
			}
		}
	}
}

roll_drag_update :: proc() {
	switch drag.kind {
	case .None:
	case .Pan:
		if in_.down[BTN_M] {
			cursor_hint(.RESIZE_ALL)
			ed.scroll_tick = max(ed.scroll_tick - in_.dmx * int(ed.p.tpb) / max(ed.beat_px, 1), 0)
			// Vertical motion is added up until it makes whole rows, so a slow drag scrolls too.
			drag.pan_y += in_.dmy
			rows := drag.pan_y / ed.row_h
			if rows != 0 {
				drag.pan_y -= rows * ed.row_h
				ed.scroll_key = clamp(ed.scroll_key + rows, min_scroll_key(), 127)
			}
		} else {
			drag.kind = .None
		}
	case .Ruler:
		if in_.down[BTN_L] {
			ed.cursor_tick = u32(snap_round(x_to_tick(in_.mx)))
		} else {
			drag.kind = .None
		}
	case .Scroll_V:
		if in_.down[BTN_L] {
			b := lay.vbar
			th := vbar_thumb().h
			room := max(b.h - th, 1)
			frac := clamp(in_.my - b.y - th / 2, 0, room)
			ed.scroll_key = clamp(127 - frac * max(128 - ed.roll_rows, 1) / room, min_scroll_key(), 127)
		} else {
			drag.kind = .None
		}
	case .Scroll_H:
		if in_.down[BTN_L] {
			b := lay.hbar
			tw := hbar_thumb().w
			room := max(b.w - tw, 1)
			frac := clamp(in_.mx - b.x - tw / 2, 0, room)
			ed.scroll_tick = max(frac * max(hbar_span() - ed.roll_ticks, 1) / room, 0)
		} else {
			drag.kind = .None
		}
	case .Band:
		if !in_.down[BTN_L] {
			r := band_rect()
			if r.w > 3 || r.h > 3 {
				t0 := x_to_tick(r.x)
				t1 := x_to_tick(r.x + r.w)
				k0 := y_to_key(r.y)
				k1 := y_to_key(r.y + r.h)
				sel_rect(u32(max(t0, 0)), u32(max(t1, 0)), k1, k0)
			}
			drag.kind = .None
		}
	case .Move, .Resize:
		if !in_.down[BTN_L] {
			drag.kind = .None
			move_snapshot = false
			return
		}
		cursor_hint(.RESIZE_EW if drag.kind == .Resize else .RESIZE_ALL)
		tick := snap_floor(x_to_tick(in_.mx))
		key := clamp(y_to_key(in_.my), 0, 127)
		dt := tick - drag.org_tick
		dk := key - drag.org_key
		if drag.kind == .Resize {
			dk = 0
		}
		if dt == 0 && dk == 0 && !drag.changed {
			return
		}
		if !drag.changed {
			ed_edit()
			drag.changed = true
		}
		// Keep the group inside the allowed range.
		for d in drag.notes {
			if drag.kind == .Move {
				dt = max(dt, -int(d.start))
				dk = clamp(dk, -int(d.key), 127 - int(d.key))
			}
		}
		for d in drag.notes {
			if d.idx >= len(ed.p.notes) {
				continue
			}
			n := &ed.p.notes[d.idx]
			if drag.kind == .Move {
				if int(n.key) != int(d.key) + dk {
					audition(n.track, int(d.key) + dk, int(n.vel))
				}
				n.start = u32(int(d.start) + dt)
				n.key = u8(int(d.key) + dk)
			} else {
				base := int(d.len) if d.len > 0 else int(grid_ticks())
				n.len = u32(max(base + dt, 1))
			}
		}
		ed_changed()
	case .Vel:
		if !in_.down[BTN_L] || drag.vel_note >= len(ed.p.notes) { // (the note may be gone: undo or delete while dragging)
			drag.kind = .None
			return
		}
		cursor_hint(.RESIZE_NS)
		v := lay.vel
		span := max(v.h - 10, 1)
		val := clamp((v.y + v.h - 4 - in_.my) * 127 / span, 1, 127)
		ref := ed.p.notes[drag.vel_note].vel
		for &n in ed.p.notes {
			if n.sel && n.track == ed.cur_track {
				n.vel = u8(clamp(int(n.vel) + val - int(ref), 1, 127))
			}
		}
		ed.p.notes[drag.vel_note].vel = u8(val)
		ed.def_vel = val
		ed_changed()
	}
}

// ---- keyboard ---------------------------------------------------------------------------------------------

// What an arrow key does: moves the cursor (Shift: and selects the notes it passes over), or with Alt
// moves the selected notes.
arrow_move :: proc(dt, dk: int) {
	if in_.alt {
		nudge_targets(dt, dk)
	} else {
		cursor_move(dt, dk, true, in_.shift)
	}
}

// The keys that work in every view (the roll and the effect graph): the Ctrl combinations, the function keys, Tab
// for the next track. Which key does what is the table of keymap.odin (key_bindings), and each of these signals runs the
// Action of GLOBAL_COMMANDS. Returns true if the keys of the view should not look at this frame's input (Ctrl held).
global_keys :: proc() -> bool {
	for sig in Signal.Cmd_Palette ..= Signal.Cmd_Scale_Down {
		if sig == .Cmd_Undo || sig == .Cmd_Redo {
			if rep(sig) { // (undo and redo go on while the key is held)
				run_action(GLOBAL_COMMANDS[sig])
				break
			}
		} else if hit(sig) {
			run_action(GLOBAL_COMMANDS[sig])
			break
		}
	}
	return in_.ctrl
}

roll_keys :: proc() {
	if !in_.alt {
		move_snapshot = false // the next Alt + arrow starts a new step of undo
	}
	if global_keys() {
		// (Ctrl + a key that only the roll knows:)
		if in_.ctrl {
			if hit(.Roll_Select_All) {
				run_action(.Edit_Select_All)
			} else if hit(.Roll_Duplicate) {
				run_action(.Edit_Duplicate)
			} else if hit(.Roll_Copy) {
				run_action(.Edit_Yank)
			} else if hit(.Roll_Paste) {
				run_action(.Edit_Paste)
			} else if hit(.Roll_Cut) {
				ed_yank()
				ed_delete_targets()
			} else if rep(.Nav_Right) || rep(.Nav_Left) {
				dir := 1 if rep(.Nav_Right) else -1
				cursor_move(dir * int(bar_ticks()), 0) // a bar
			} else if rep(.Nav_Up) || rep(.Nav_Down) {
				dir := 1 if rep(.Nav_Up) else -1
				cursor_move(0, dir * 12) // an octave
			}
		}
		return
	}
	n := max(ed.count, 1)
	g := int(grid_ticks())
	bar := int(bar_ticks())

	if rep(.Nav_Left) {
		arrow_move(-g * n, 0)
	}
	if rep(.Nav_Right) {
		arrow_move(g * n, 0)
	}
	if rep(.Nav_Up) {
		arrow_move(0, n)
	}
	if rep(.Nav_Down) {
		arrow_move(0, -n)
	}
	if rep(.Nav_Page_Up) {
		cursor_move(0, 12)
	}
	if rep(.Nav_Page_Down) {
		cursor_move(0, -12)
	}
	if hit(.Nav_Home) {
		cursor_goto(0, ed.cursor_key)
	}
	if hit(.Nav_End) {
		cursor_goto(project_end(&ed.p), ed.cursor_key)
	}
	if rep(.Nav_Delete) || rep(.Nav_Backspace) {
		run_action(.Edit_Delete)
	}
	if hit(.Nav_Confirm) {
		run_action(.Edit_Insert)
	}
	if hit(.Nav_Cancel) {
		if play_active {
			play_halt()
		} else {
			sel_clear()
		}
		ed.count = 0
	}

	for c in in_.chars {
		digit := c >= '0' && c <= '9'
		if digit && (c != '0' || ed.count > 0) {
			ed.count = min(ed.count * 10 + int(c - '0'), 9999)
			continue
		}
		n = max(ed.count, 1)
		ed.count = 0
		switch c {
		case 'h':
			cursor_move(-g * n, 0)
		case 'l':
			cursor_move(g * n, 0)
		case 'j':
			cursor_move(0, -n)
		case 'k':
			cursor_move(0, n)
		case 'H':
			cursor_move(-bar * n, 0)
		case 'L':
			cursor_move(bar * n, 0)
		case 'J':
			cursor_move(0, -12 * n)
		case 'K':
			cursor_move(0, 12 * n)
		case '0':
			run_action(.View_Goto_Start)
		case '$':
			run_action(.View_Goto_End)
		case 'w':
			jump_note(true, n)
		case 'b':
			jump_note(false, n)
		case 'i', 'o':
			run_action(.Edit_Insert)
		case 'a':
			if ed_insert_note() {
				audition(ed.cur_track, ed.cursor_key, ed.def_vel)
			}
			cursor_move(int(insert_len()), 0, false)
		case 'x':
			run_action(.Edit_Delete)
		case 's':
			if i := note_at(ed.cursor_tick, ed.cursor_key); i >= 0 {
				ed.p.notes[i].sel = !ed.p.notes[i].sel
			}
		case 'y':
			run_action(.Edit_Yank)
		case 'p':
			run_action(.Edit_Paste)
		case 'u':
			run_action(.Edit_Undo)
		case 'q':
			run_action(.Edit_Quantize)
		case '<':
			ed_resize_targets(-g * n)
		case '>':
			ed_resize_targets(g * n)
		case '-':
			ed_velocity_targets(-VEL_STEP * n)
		case '+', '=':
			ed_velocity_targets(VEL_STEP * n)
		case '[':
			run_action(.View_Grid_Prev)
		case ']':
			run_action(.View_Grid_Next)
		case '{':
			run_action(.Track_Prev)
		case '}':
			run_action(.Track_Next)
		case 'M':
			run_action(.Track_Mute)
		case 'S':
			run_action(.Track_Solo)
		case ' ':
			run_action(.Play_Toggle)
		case 't':
			run_action(.Song_Tempo)
		case ',':
			run_action(.Loop_Start)
		case '.':
			run_action(.Loop_End)
		case 'z':
			run_action(.View_Zoom_In)
		case 'Z':
			run_action(.View_Zoom_Out)
		case ':':
			run_action(.Palette)
		case '?':
			run_action(.Help_Keys)
		}
	}
}

// Moves the cursor to the start of the next / previous note of the current track.
jump_note :: proc(forward: bool, count: int) {
	for _ in 0 ..< count {
		best := -1
		for n, i in ed.p.notes {
			if n.track != ed.cur_track {
				continue
			}
			if forward {
				if n.start > ed.cursor_tick && (best < 0 || n.start < ed.p.notes[best].start) {
					best = i
				}
			} else {
				if n.start < ed.cursor_tick && (best < 0 || n.start > ed.p.notes[best].start) {
					best = i
				}
			}
		}
		if best < 0 {
			break
		}
		cursor_goto(ed.p.notes[best].start, int(ed.p.notes[best].key))
	}
}

_ :: math
_ :: rl
_ :: snd
