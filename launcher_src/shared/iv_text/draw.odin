package iv_text

import "core:math"
import "core:unicode/utf8"
import ren "../iv_system/ren"
import ui "../iv_ui"

// Draws `s` on one line with the top left of the line at `pos` (px of the target; the baseline is ascent px below pos.y) at the em `size`, in `color`;
// returns the width in px (not rounded). Readings (when tf.furigana is on, see set_furigana) are drawn in the ruby_height px above pos.y: leave room for
// them (ruby_room). A '\n' is not a line break here: draw_lines and draw_wrapped do lines.
draw :: proc(dl: ^ren.Draw_List, tf: ^Typeface, s: string, pos: [2]int, size: f32, color: ren.Color) -> f32 {
	if len(tf.sources) == 0 || len(s) == 0 {
		return 0
	}
	baseline := pos.y + ascent(tf, size)
	pen: f32
	ruby_end := f32(min(int)) // where the last reading ended: the next one stays to its right
	i := 0
	for i < len(s) {
		if _, nx, ok := tf_ruby_at(tf, s, i); ok { // a reading with no letter before it
			i = nx
			continue
		}
		r, n := utf8.decode_rune_in_string(s[i:])
		i += n
		info := glyph_info(tf, r)
		adv := info.adv * size
		if info.source >= 0 && r != ' ' && r != 0xA0 {
			draw_glyph(dl, tf, int(info.source), info.drawn, f32(pos.x) + pen, baseline, size, color)
		}
		if reading, nx, ok := tf_ruby_at(tf, s, i); ok {
			i = nx
			if tf.furigana {
				draw_reading(dl, tf, reading, f32(pos.x) + pen + adv / 2, pos.y, size, color, &ruby_end)
			}
		}
		pen += adv
	}
	return pen
}

// One glyph of the font `source` of the stack at the em `size` (the raster of that pixel size is made, and the glyph put in its atlas, the first time).
@(private)
draw_glyph :: proc(dl: ^ren.Draw_List, tf: ^Typeface, source: int, r: rune, x: f32, baseline: int, size: f32, color: ren.Color) {
	s := &tf.sources[source]
	ras := raster_at(tf, source, size * s.em_scale)
	if ras == nil {
		return
	}
	img, ok := raster_glyph(tf, ras, r)
	if !ok || ui.is_empty(img.src) {
		return
	}
	dy := int(math.round(s.dy * size))
	dst := ui.Rect{int(math.round(x)) + img.offset.x, baseline + img.offset.y + dy, img.src.w, img.src.h}
	ren.draw_image(dl, ras.atlas, dst, ren.uv_rect(img.src, ras.atlas_size, ras.atlas_size), color, .Coverage)
}

// A reading above a letter: centred over it (`centre`, px), kept to the right of the reading before it (`end`), with its bottom a gap above `line_top`.
@(private)
draw_reading :: proc(dl: ^ren.Draw_List, tf: ^Typeface, reading: string, centre: f32, line_top: int, size: f32, color: ren.Color, end: ^f32) {
	rs := size * tf.ruby_scale
	total: f32
	for r in reading {
		total += advance(tf, r, rs)
	}
	pen := max(centre - total / 2, end^)
	baseline := line_top - ruby_gap_px(tf, size) - descent(tf, rs)
	for r in reading {
		info := glyph_info(tf, r)
		if info.source >= 0 {
			draw_glyph(dl, tf, int(info.source), info.drawn, pen, baseline, rs, color)
		}
		pen += info.adv * rs
	}
	end^ = pen + 1
}

// Draws `s` aligned in `r` (the box of the line is at least the width of the text, placed by the alignments), returns where it went.
draw_aligned :: proc(
	dl: ^ren.Draw_List,
	tf: ^Typeface,
	s: string,
	r: ui.Rect,
	size: f32,
	color: ren.Color,
	horizontal := ui.Align.Start,
	vertical := ui.Align.Center,
) -> ui.Rect {
	room := ruby_room(tf, s, size)
	box := ui.place(r, width(tf, s, size), line_height(tf, size) + room, horizontal, vertical)
	draw(dl, tf, s, {box.x, box.y + room}, size, color)
	return box
}

// Draws the lines of a text with '\n's (or already wrapped: wrap's lines), the first with its top at pos.y; `line_h` (default: line_height) is the distance
// between the lines, `align` places each line in a column `width` px wide (0: at pos.x). A line that has readings is moved down by the room for them
// (the lines are as far apart as they would be without readings, plus that room for the lines that have some). Returns the height used.
draw_lines :: proc(
	dl: ^ren.Draw_List,
	tf: ^Typeface,
	lines: []string,
	pos: [2]int,
	size: f32,
	color: ren.Color,
	line_h := 0,
	column := 0,
	align := ui.Align.Start,
) -> int {
	lh := line_h if line_h > 0 else line_height(tf, size)
	y := pos.y
	for line in lines {
		room := ruby_room(tf, line, size)
		x := pos.x
		if column > 0 && align != .Start {
			x = pos.x + ui.place(ui.Rect{0, 0, column, 1}, width(tf, line, size), 1, align, .Start).x
		}
		draw(dl, tf, line, {x, y + room}, size, color)
		y += lh + room
	}
	return y - pos.y
}

// Wraps `s` to the width of `r` and draws it from the top of `r` (clipped to `r`); returns the height the text takes (more than r.h: it was cut).
draw_wrapped :: proc(
	dl: ^ren.Draw_List,
	tf: ^Typeface,
	s: string,
	r: ui.Rect,
	size: f32,
	color: ren.Color,
	line_h := 0,
	align := ui.Align.Start,
) -> int {
	lines := wrap(tf, s, r.w, size)
	ren.push_clip(dl, r)
	defer ren.pop_clip(dl)
	return draw_lines(dl, tf, lines, {r.x, r.y}, size, color, line_h, r.w, align)
}

// How high `s` wrapped to `max_w` is, with the room for readings of the lines that have them. (draw_wrapped's result without drawing.)
wrapped_height :: proc(tf: ^Typeface, s: string, max_w: int, size: f32, line_h := 0) -> int {
	lh := line_h if line_h > 0 else line_height(tf, size)
	h := 0
	for line in wrap(tf, s, max_w, size) {
		h += lh + ruby_room(tf, line, size)
	}
	return h
}
