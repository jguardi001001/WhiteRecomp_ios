package main

import "core:math"
import rl "vendor:raylib"
import ui "shared:iv_ui"

// ---------------------------------------------------------------------------
// The look: a dark palette, one color per track, and the small widgets every part of the
// interface draws with (buttons, sliders, scroll bars, dialog frames, icons).
// ---------------------------------------------------------------------------

// Surfaces, from the darkest (wells, inputs) to the lightest (hovered buttons).
COL_BG0 :: Color{16, 17, 21, 255}
COL_BG1 :: Color{27, 29, 35, 255}
COL_BG2 :: Color{37, 40, 48, 255}
COL_BG3 :: Color{50, 54, 64, 255}
COL_BG4 :: Color{68, 74, 87, 255}
COL_LINE :: Color{9, 10, 12, 255} // dark separators
COL_LINE2 :: Color{58, 63, 75, 255} // light separators and outlines

COL_TEXT :: Color{224, 227, 234, 255}
COL_DIM :: Color{146, 152, 168, 255}
COL_FAINT :: Color{94, 100, 115, 255}

COL_ACCENT :: Color{60, 156, 255, 255}
COL_ACCENT_DIM :: Color{34, 84, 144, 255}
COL_PLAY :: Color{255, 176, 46, 255} // the play head
COL_GREEN :: Color{70, 214, 124, 255}
COL_MUTE :: Color{238, 170, 54, 255}
COL_SOLO :: Color{70, 204, 228, 255}
COL_RED :: Color{240, 88, 88, 255}

// The piano roll.
ROLL_WHITE :: Color{36, 39, 47, 255} // the rows of white keys
ROLL_BLACK :: Color{28, 30, 37, 255} // the rows of black keys
ROLL_OUTSIDE :: Color{19, 20, 24, 255} // above the highest and below the lowest key
GRID_SUB :: Color{255, 255, 255, 12}
GRID_BEAT :: Color{255, 255, 255, 28}
GRID_BAR :: Color{255, 255, 255, 70}
KEY_WHITE_TOP :: Color{240, 242, 247, 255}
KEY_WHITE_BOTTOM :: Color{206, 210, 220, 255}
KEY_BLACK :: Color{30, 32, 38, 255}

// Every track has a color; it shows on the notes, the track list and the faders. Neighbouring
// tracks are far apart on the color wheel.
track_color :: proc(ti: int) -> Color {
	hue := f32((ti * 7) % 16) * 22.5 + 8
	return rl.ColorFromHSV(hue, 0.58, 0.96)
}

// ---- hovering ------------------------------------------------------------------------------------

in_modal_draw: bool // the dialog layer is being drawn: its widgets react to the mouse

// Is the mouse over `r` and free to react (no menu or dialog above it)?
hover :: proc(r: Rect) -> bool {
	return mouse_in(r) && (!ui_blocked || in_modal_draw)
}

// ---- widgets ------------------------------------------------------------------------------------------

draw_button :: proc(r: Rect, label: string, primary := false, enabled := true) {
	h := enabled && hover(r)
	if h {
		cursor_hint(.POINTING_HAND)
	}
	down := h && in_.down[BTN_L]
	col: Color
	if primary {
		col = COL_ACCENT
		if h {
			col = lighten(col, 0.14)
		}
		if down {
			col = darken(col, 0.18)
		}
	} else {
		col = COL_BG3
		if h {
			col = COL_BG4
		}
		if down {
			col = COL_BG2
		}
	}
	fill_round(r, 4, col)
	if !primary {
		frame_round(r, 4, COL_LINE2)
	}
	tc := COL_TEXT
	if primary {
		tc = Color{255, 255, 255, 255}
	}
	if !enabled {
		tc = COL_FAINT
	}
	text_in(r, label, tc, .Ui, .Center, 4)
}

// A button that is lit while `on`.
draw_toggle :: proc(r: Rect, label: string, on: bool, col := COL_ACCENT, id := Font_Id.Ui) {
	h := hover(r)
	bg := COL_BG3
	if on {
		bg = mix(COL_BG2, col, 0.38)
	}
	if h {
		bg = lighten(bg, 0.07)
	}
	fill_round(r, 4, bg)
	frame_round(r, 4, col if on else COL_LINE2)
	tc := lighten(col, 0.35) if on else COL_DIM
	text_in(r, label, tc, id, .Center, 2)
}

// A small round-cornered flag in a list row (the M and S switches).
draw_flag :: proc(r: Rect, letter: string, on: bool, col: Color) {
	h := hover(r)
	if h {
		cursor_hint(.POINTING_HAND)
	}
	if on {
		fill_round(r, 3, col)
		text_in(r, letter, Color{20, 22, 26, 255}, .Bold, .Center, 0)
	} else {
		fill_round(r, 3, COL_BG3 if !h else COL_BG4)
		text_in(r, letter, COL_DIM, .Bold, .Center, 0)
	}
}

// A horizontal slider: a groove with a filled part and a knob at t (0..1). With `bipolar` the fill runs from the middle.
draw_slider :: proc(r: Rect, t: f32, col: Color, active: bool, bipolar := false) {
	cy := r.y + r.h / 2
	fill_round(Rect{r.x, cy - 2, r.w, 4}, 2, COL_BG0)
	kx := r.x + int(clamp(t, 0, 1) * f32(r.w))
	if bipolar {
		mid := r.x + r.w / 2
		a := min(mid, kx)
		b := max(mid, kx)
		fill(Rect{a, cy - 2, max(b - a, 1), 4}, col)
		fill(Rect{mid, cy - 4, 1, 8}, COL_FAINT)
	} else {
		fill_round(Rect{r.x, cy - 2, max(kx - r.x, 2), 4}, 2, col)
	}
	circle(kx, cy, 6.5, Color{0, 0, 0, 110})
	circle(kx, cy, 5.5, lighten(col, 0.55) if active else Color{226, 229, 236, 255})
	circle(kx, cy, 2.5, col)
}

// The thumb of a scroll bar.
draw_thumb :: proc(r: Rect, hot: bool) {
	fill_round(r, 3, COL_ACCENT if hot else COL_BG4)
}

// ---- dialogs -----------------------------------------------------------------------------------------

DIALOG_TITLE_H :: 32

// Darkens everything behind a dialog.
draw_overlay :: proc() {
	fill(Rect{0, 0, win_w, win_h}, Color{4, 5, 8, 165})
}

// The frame of a dialog: shadow, panel, title bar. Returns the area inside, below the title.
draw_dialog :: proc(r: Rect, title: string) -> Rect {
	shadow(r, 8, 22)
	fill_round(r, 8, COL_BG1)
	fill_round(Rect{r.x, r.y, r.w, DIALOG_TITLE_H + 8}, 8, COL_BG2)
	fill(Rect{r.x, r.y + DIALOG_TITLE_H, r.w, 8}, COL_BG1)
	hline(r.x + 1, r.x + r.w - 2, r.y + DIALOG_TITLE_H, COL_LINE)
	frame_round(r, 8, COL_LINE2)
	text_in(Rect{r.x, r.y, r.w, DIALOG_TITLE_H}, title, COL_TEXT, .Bold, .Left, 14)
	return Rect{r.x + 14, r.y + DIALOG_TITLE_H + 12, r.w - 28, r.h - DIALOG_TITLE_H - 24}
}

// The background of a row in a list.
draw_row :: proc(r: Rect, selected, hovered: bool, accent := COL_ACCENT) {
	if selected {
		fill(r, with_alpha(accent, 0.26))
		fill(Rect{r.x, r.y, 3, r.h}, accent)
	} else if hovered {
		fill(r, COL_BG3)
	}
}

// ---- lines and icons ------------------------------------------------------------------------------------

line_f :: proc(x0, y0, x1, y1: f32, thick: f32, c: Color) {
	rl.DrawLineEx(rl.Vector2{x0 * ui_scale, y0 * ui_scale}, rl.Vector2{x1 * ui_scale, y1 * ui_scale}, max(thick * ui_scale, 1), c)
}

icon_play :: proc(cx, cy: int, size: f32, c: Color) {
	x := f32(cx)
	y := f32(cy)
	triangle(x - size * 0.36, y - size * 0.5, x - size * 0.36, y + size * 0.5, x + size * 0.56, y, c)
}

icon_stop :: proc(cx, cy: int, size: f32, c: Color) {
	s := int(size * 0.9)
	fill_round(Rect{cx - s / 2, cy - s / 2, s, s}, 2, c)
}

icon_to_start :: proc(cx, cy: int, size: f32, c: Color) {
	x := f32(cx)
	y := f32(cy)
	fill(Rect{cx - int(size * 0.5), cy - int(size * 0.5), 2, int(size)}, c)
	triangle(x + size * 0.5, y - size * 0.5, x + size * 0.5, y + size * 0.5, x - size * 0.3, y, c)
}

icon_loop :: proc(cx, cy: int, size: f32, c: Color) {
	w := int(size * 1.15)
	h := int(size * 0.8)
	r := Rect{cx - w / 2, cy - h / 2, w, h}
	frame_round(r, h / 2, c)
	frame_round(ui.inset(r, 1), max(h / 2 - 1, 1), c)
	// an arrow head on the top edge, a gap at the other end
	fill(Rect{cx - 3, cy + h / 2 - 1, 7, 3}, COL_BG2)
	x := f32(cx + 1)
	y := f32(r.y + 1)
	triangle(x, y - 3.5, x, y + 3.5, x + 5, y, c)
}

icon_check :: proc(cx, cy: int, size: f32, c: Color) {
	x := f32(cx)
	y := f32(cy)
	line_f(x - size * 0.4, y, x - size * 0.1, y + size * 0.32, 1.6, c)
	line_f(x - size * 0.1, y + size * 0.32, x + size * 0.45, y - size * 0.34, 1.6, c)
}

icon_plus :: proc(cx, cy: int, size: f32, c: Color) {
	x := f32(cx)
	y := f32(cy)
	line_f(x - size * 0.5, y, x + size * 0.5, y, 1.6, c)
	line_f(x, y - size * 0.5, x, y + size * 0.5, 1.6, c)
}

// A chevron pointing left (dir -1) or right (dir 1).
icon_chevron :: proc(cx, cy: int, size: f32, dir: int, c: Color) {
	x := f32(cx)
	y := f32(cy)
	d := f32(dir)
	line_f(x - d * size * 0.25, y - size * 0.45, x + d * size * 0.25, y, 1.6, c)
	line_f(x + d * size * 0.25, y, x - d * size * 0.25, y + size * 0.45, 1.6, c)
}

_ :: math
