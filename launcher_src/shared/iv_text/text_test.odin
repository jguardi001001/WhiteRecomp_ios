package iv_text

import "core:testing"
import ren "../iv_system/ren"
import ui "../iv_ui"

LIBERATION :: #load("testdata/LiberationSans-Bold.ttf")
ORBITRON :: #load("testdata/Orbitron-Bold.ttf")

// A renderer with no GPU behind it: textures are numbers, so fonts can be made and text can be drawn into a draw list and looked at.
@(private = "file")
fake_texture :: proc(b: ^ren.Backend, desc: ren.Texture_Desc) -> (ren.Texture, bool) {
	rig := (^Rig)(b.data)
	rig.counter += 1
	return ren.Texture(rig.counter), true
}

@(private = "file")
fake_update :: proc(b: ^ren.Backend, t: ren.Texture, region: ui.Rect, pixels: []u8) -> bool {
	rig := (^Rig)(b.data)
	rig.updates += 1
	return true
}

@(private = "file")
fake_destroy :: proc(b: ^ren.Backend, t: ren.Texture) {
}

@(private = "file")
Rig :: struct {
	r:       ren.Renderer,
	tf:      Typeface,
	counter: int, // atlases made
	updates: int, // glyphs put into an atlas
}

// The renderer and the typeface, with no fonts.
@(private = "file")
rig_start :: proc(rig: ^Rig) {
	ren.renderer_init(&rig.r, ren.Backend{data = rig, create_texture = fake_texture, update_texture = fake_update, destroy_texture = fake_destroy}, 400, 200)
	typeface_init(&rig.tf, &rig.r)
}

@(private = "file")
rig_open :: proc(rig: ^Rig, fonts: ..[]u8) {
	rig_start(rig)
	for f in fonts {
		typeface_add(&rig.tf, f)
	}
}

@(private = "file")
rig_close :: proc(rig: ^Rig) {
	typeface_destroy(&rig.tf)
	ren.renderer_destroy(&rig.r)
}

@(test)
widths_follow_the_em_and_do_not_need_a_gpu :: proc(t: ^testing.T) {
	tf: Typeface
	typeface_init(&tf, nil)
	defer typeface_destroy(&tf)
	_, ok := typeface_add(&tf, LIBERATION)
	testing.expect(t, ok)
	_, bad := typeface_add(&tf, []u8{1, 2, 3, 4})
	testing.expect(t, !bad)

	w20 := width_f(&tf, "Hello", 20)
	w40 := width_f(&tf, "Hello", 40)
	testing.expectf(t, abs(w40 - 2 * w20) < 0.001, "twice the em, twice the width: %v %v", w20, w40)
	testing.expect(t, w20 > 40 && w20 < 70)
	testing.expect(t, width_f(&tf, "WWWW", 20) > width_f(&tf, "iiii", 20)) // proportional
	testing.expect_value(t, width_f(&tf, "", 20), 0)
	testing.expect_value(t, width(&tf, "Hello", 20), int(w20) + 1 if w20 != f32(int(w20)) else int(w20))
	testing.expect(t, line_height(&tf, 20) >= 20 && line_height(&tf, 20) <= 30)
	testing.expect(t, ascent(&tf, 20) > 14 && ascent(&tf, 20) < line_height(&tf, 20))

	// a '\n' makes a line: size of a text of two lines
	w, h := text_size(&tf, "Hello\nHi", 20)
	testing.expect_value(t, w, width(&tf, "Hello", 20))
	testing.expect_value(t, h, 2 * line_height(&tf, 20))
	_, h3 := text_size(&tf, "a\nb\n", 20, gap = 3) // a trailing newline starts an empty third line
	testing.expect_value(t, h3, 3 * line_height(&tf, 20) + 6)
}

@(test)
readings_take_no_room_and_stay_with_their_letter :: proc(t: ^testing.T) {
	tf: Typeface
	typeface_init(&tf, nil)
	defer typeface_destroy(&tf)
	typeface_add(&tf, LIBERATION)

	testing.expect(t, has_ruby("a{{x}}b") && !has_ruby("a{{x b") && !has_ruby("plain"))
	r, next, ok := ruby_at("a{{xy}}b", 1)
	testing.expect(t, ok && r == "xy" && next == 7)
	_, _, no := ruby_at("a{{xy}}b", 0)
	testing.expect(t, !no)
	testing.expect_value(t, width_f(&tf, "a{{xyz}}b", 20), width_f(&tf, "ab", 20))
	s := strip_ruby("a{{xyz}}b{{q}}")
	defer delete(s)
	testing.expect_value(t, s, "ab")

	// a split never separates a reading from its letter
	head, tail := split(&tf, "ab{{xyz}}cd", width(&tf, "ab", 20), 20)
	testing.expect_value(t, head, "ab{{xyz}}")
	testing.expect_value(t, tail, "cd")

	// room above the line only when readings are drawn and the text has one
	testing.expect_value(t, ruby_room(&tf, "a{{x}}", 20), 0) // furigana is off until the program turns it on
	set_furigana(&tf, true)
	testing.expect_value(t, ruby_room(&tf, "plain", 20), 0)
	room := ruby_room(&tf, "a{{x}}", 20)
	testing.expectf(t, room > 5 && room < 20, "room %d", room)
	testing.expect_value(t, ruby_room_all(&tf, 20, "plain", "a{{x}}"), room)
	testing.expect_value(t, width_f(&tf, "a{{xyz}}b", 20), width_f(&tf, "ab", 20)) // laid out the same with them on
	set_furigana(&tf, false)
	testing.expect_value(t, ruby_room(&tf, "a{{x}}", 20), 0)
}

@(test)
wrap_breaks_at_spaces_and_inside_long_words :: proc(t: ^testing.T) {
	tf: Typeface
	typeface_init(&tf, nil)
	defer typeface_destroy(&tf)
	typeface_add(&tf, LIBERATION)

	max_w := width(&tf, "gamma delta", 20) + 2
	lines := wrap(&tf, "alpha beta gamma delta", max_w, 20)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0], "alpha beta")
	testing.expect_value(t, lines[1], "gamma delta")
	for l in lines {
		testing.expect(t, width(&tf, l, 20) <= max_w)
	}

	// an explicit newline, and an empty line
	lines = wrap(&tf, "one\n\ntwo", 1000, 20)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[1], "")

	// a word wider than the line is cut inside; every part fits
	narrow := width(&tf, "WWW", 20)
	lines = wrap(&tf, "WWWWWWWWW", narrow, 20)
	testing.expect(t, len(lines) >= 3)
	total := 0
	for l in lines {
		testing.expectf(t, width(&tf, l, 20) <= narrow, "%q is %d", l, width(&tf, l, 20))
		total += len(l)
	}
	testing.expect_value(t, total, 9)

	// text without spaces (Japanese) breaks between characters, and a stop does not start a line
	cjk := wrap(&tf, "あいうえおかきくけこ", 1, 20) // the primary font has no glyphs: all fall back to '?', each of one width
	testing.expect(t, len(cjk) >= 2)
}

@(test)
cursor_places_agree_with_the_widths :: proc(t: ^testing.T) {
	tf: Typeface
	typeface_init(&tf, nil)
	defer typeface_destroy(&tf)
	typeface_add(&tf, LIBERATION)
	s := "Hello"
	testing.expect_value(t, x_at(&tf, s, 0, 20), 0)
	testing.expect_value(t, x_at(&tf, s, len(s), 20), width_f(&tf, s, 20))
	for at in 0 ..= len(s) {
		x := x_at(&tf, s, at, 20)
		testing.expect_value(t, byte_near(&tf, s, x, 20), at)
		testing.expect_value(t, byte_near(&tf, s, x + 0.2, 20), at) // a little to the right of a boundary: still that one
	}
	testing.expect_value(t, byte_near(&tf, s, -50, 20), 0)
	testing.expect_value(t, byte_near(&tf, s, 5000, 20), len(s))
}

@(test)
characters_come_from_the_first_font_that_has_them :: proc(t: ^testing.T) {
	tf: Typeface
	typeface_init(&tf, nil)
	defer typeface_destroy(&tf)
	typeface_add(&tf, ORBITRON) // a Latin-only display font
	typeface_add(&tf, LIBERATION, em_scale = 0.5)

	latin := glyph_info(&tf, 'A')
	testing.expect_value(t, latin.source, 0)
	cyr := glyph_info(&tf, 'Ж') // Orbitron has no Cyrillic: Liberation draws it, at half the em
	testing.expect_value(t, cyr.source, 1)
	plain := Typeface{}
	_ = plain
	testing.expectf(t, cyr.adv > 0.2 && cyr.adv < 0.6, "half-size Cyrillic advance %v", cyr.adv)
	nothing := glyph_info(&tf, '\U0001F600') // no font: the '?' of the first font that has one
	testing.expect_value(t, nothing.drawn, '?')
	testing.expect(t, has_glyph(&tf, 'Ж') && !has_glyph(&tf, '\U0001F600'))
}

@(test)
text_is_drawn_into_the_draw_list :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig, LIBERATION)
	defer rig_close(&rig)
	dl := ren.begin_frame(&rig.r)

	w := draw(dl, &rig.tf, "Hello", {10, 20}, 20, ren.WHITE)
	testing.expect(t, abs(w - width_f(&rig.tf, "Hello", 20)) < 0.001)
	// one quad per visible letter (a space has none), all inside the line's box
	testing.expect_value(t, len(dl.vertices), 5 * 4)
	top := 20
	bottom := 20 + line_height(&rig.tf, 20) + 6 // (descenders and rounding)
	for v in dl.vertices {
		testing.expectf(t, v.pos.x >= 10 && v.pos.x <= 10 + w + 2, "x %v", v.pos.x)
		testing.expectf(t, v.pos.y >= f32(top) && v.pos.y <= f32(bottom), "y %v", v.pos.y)
	}
	before := len(dl.vertices)
	draw(dl, &rig.tf, "a b", {0, 0}, 20, ren.WHITE)
	testing.expect_value(t, len(dl.vertices) - before, 2 * 4)
	testing.expect_value(t, draw(dl, &rig.tf, "", {0, 0}, 20, ren.WHITE), 0)
	testing.expect_value(t, rig.counter, 1) // one font, one atlas, made once

	// a second size is a second font; the same size again is the same one
	draw(dl, &rig.tf, "x", {0, 0}, 32, ren.WHITE)
	draw(dl, &rig.tf, "y", {0, 0}, 32, ren.WHITE)
	testing.expect_value(t, rig.counter, 2)
	// sizes that round to the same pixel size share a font
	draw(dl, &rig.tf, "x", {0, 0}, 32.2, ren.WHITE)
	testing.expect_value(t, rig.counter, 2)
}

@(test)
readings_are_drawn_small_above_their_letter :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig, LIBERATION)
	defer rig_close(&rig)
	dl := ren.begin_frame(&rig.r)

	set_furigana(&rig.tf, true)
	room := ruby_room(&rig.tf, "a{{x}}", 40)
	draw(dl, &rig.tf, "a{{x}}", {0, room}, 40, ren.WHITE)
	testing.expect_value(t, len(dl.vertices), 2 * 4) // the letter and its reading
	// the reading's quad is above the letter's top (y < room) and smaller than it
	small, big: ui.Rect
	for q in 0 ..< 2 {
		lo, hi := dl.vertices[q * 4].pos, dl.vertices[q * 4 + 2].pos
		r := ui.Rect{int(lo.x), int(lo.y), int(hi.x - lo.x), int(hi.y - lo.y)}
		if q == 1 {
			small = r
		} else {
			big = r
		}
	}
	testing.expectf(t, small.h < big.h, "reading %v letter %v", small, big)
	testing.expectf(t, small.y + small.h <= room + 2, "the reading sits in the room above the line: %v, room %d", small, room)

	// not drawn when readings are off
	set_furigana(&rig.tf, false)
	dl2 := ren.begin_frame(&rig.r)
	draw(dl2, &rig.tf, "a{{x}}", {0, 0}, 40, ren.WHITE)
	testing.expect_value(t, len(dl2.vertices), 4)
}

@(test)
wrapped_text_draws_inside_its_box_and_measures_like_iv_ui :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig, LIBERATION)
	defer rig_close(&rig)
	dl := ren.begin_frame(&rig.r)

	box := ui.Rect{10, 10, 100, 80}
	h := draw_wrapped(dl, &rig.tf, "one two three four five six seven", box, 16, ren.WHITE)
	lines := wrap(&rig.tf, "one two three four five six seven", box.w, 16)
	testing.expect_value(t, h, len(lines) * line_height(&rig.tf, 16))
	testing.expect_value(t, wrapped_height(&rig.tf, "one two three four five six seven", box.w, 16), h)
	testing.expect(t, len(dl.commands) > 0 && dl.commands[0].clip == box, "clipped to the box")

	m := Measurer{&rig.tf, 16}
	measure := measure_of(&m)
	size := ui.text_size(measure, "Hello")
	testing.expect_value(t, size.w, width(&rig.tf, "Hello", 16))
	testing.expect_value(t, size.h, line_height(&rig.tf, 16))
	hugged := ui.hug(measure, "Hello", ui.Insets{4, 2, 4, 2})
	testing.expect_value(t, hugged.w, size.w + 8)

	// aligned in a box
	r := draw_aligned(dl, &rig.tf, "Hi", ui.Rect{0, 0, 200, 100}, 16, ren.WHITE, .Center, .Center)
	testing.expect_value(t, r.x + r.w / 2, 100)
	testing.expect(t, abs(r.y + r.h / 2 - 50) <= 1)
}

@(test)
wrap_ranges_say_where_each_line_is :: proc(t: ^testing.T) {
	tf: Typeface
	typeface_init(&tf, nil)
	defer typeface_destroy(&tf)
	typeface_add(&tf, LIBERATION)
	s := "alpha beta\n\ngamma"
	ranges := wrap_ranges(&tf, s, 1000, 20)
	testing.expect_value(t, len(ranges), 3)
	testing.expect_value(t, s[ranges[0][0]:ranges[0][1]], "alpha beta")
	testing.expect_value(t, ranges[1][0], ranges[1][1]) // the empty line is a place too
	testing.expect_value(t, s[ranges[2][0]:ranges[2][1]], "gamma")
	narrow := wrap_ranges(&tf, "aaa bbb ccc", width(&tf, "aaa bbb", 20) + 1, 20)
	testing.expect_value(t, len(narrow), 2)
	testing.expect_value(t, narrow[1][0], 8)

	// literal: the braces are letters, not a reading
	tf.literal = true
	testing.expect(t, width_f(&tf, "a{{x}}b", 20) > width_f(&tf, "ab", 20) + 10)
	_, _, is_reading := tf_ruby_at(&tf, "a{{x}}b", 1)
	testing.expect(t, !is_reading)
}

// The font stack is the program's to set, and to set again: the first font that has a character draws it.
@(test)
the_font_stack_can_be_replaced_and_skips_what_is_not_a_font :: proc(t: ^testing.T) {
	tf: Typeface
	typeface_init(&tf, nil)
	defer typeface_destroy(&tf)

	added := typeface_set_fonts(&tf, {{data = ORBITRON}, {data = []u8{1, 2, 3, 4}}, {data = LIBERATION, em_scale = 0.5}})
	testing.expect_value(t, added, 2) // the bytes that are not a font are left out
	testing.expect_value(t, len(tf.sources), 2)
	testing.expect_value(t, glyph_info(&tf, 'A').source, 0)
	testing.expect_value(t, glyph_info(&tf, 'Ж').source, 1) // only the second has Cyrillic
	orbitron_a := glyph_info(&tf, 'A').adv

	// the other way round: Liberation first, at the full em
	added = typeface_set_fonts(&tf, {{data = LIBERATION}, {data = ORBITRON}})
	testing.expect_value(t, added, 2)
	a := glyph_info(&tf, 'A')
	testing.expect_value(t, a.source, 0)
	testing.expect(t, a.adv != orbitron_a, "what was remembered of the old stack is gone")
	testing.expect_value(t, glyph_info(&tf, 'Ж').source, 0)

	testing.expect_value(t, typeface_set_fonts(&tf, {}), 0)
	testing.expect_value(t, glyph_info(&tf, 'A').source, -1) // no fonts at all
	testing.expect_value(t, line_height(&tf, 20), 0)
}

// The cache of which font draws a character has a fixed size: the characters used longest ago are forgotten and found again when they are needed.
@(test)
the_character_cache_is_bounded :: proc(t: ^testing.T) {
	tf: Typeface
	typeface_init(&tf, nil, glyph_cache = 8)
	defer typeface_destroy(&tf)
	typeface_add(&tf, ORBITRON)
	typeface_add(&tf, LIBERATION)

	first := glyph_info(&tf, 'A')
	cyr := glyph_info(&tf, 'Ж')
	for r in 'a' ..= 'z' {
		glyph_info(&tf, r)
		testing.expect(t, tf.glyphs.count <= 8)
	}
	testing.expect_value(t, tf.glyphs.count, 8)
	testing.expect_value(t, glyph_info(&tf, 'A'), first) // forgotten and worked out again: the same answer
	testing.expect_value(t, glyph_info(&tf, 'Ж'), cyr)
	testing.expect_value(t, glyph_info(&tf, '\U0001F600').drawn, '?')
}

// The pictures of the letters are in an atlas of cells: the glyphs used longest ago give their cells to new ones, when a frame is over.
@(test)
glyph_pictures_are_cached_and_the_least_recently_used_give_up_their_cells :: proc(t: ^testing.T) {
	rig: Rig
	rig_start(&rig)
	defer rig_close(&rig)
	typeface_add(&rig.tf, LIBERATION, atlas_size = 256) // at 20 px a cell is 32 texels: 8 x 8 = 64 glyphs
	dl := ren.begin_frame(&rig.r)

	upper := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	draw(dl, &rig.tf, upper, {0, 0}, 20, ren.WHITE)
	testing.expect_value(t, rig.updates, 26)
	draw(dl, &rig.tf, upper, {0, 30}, 20, ren.WHITE) // the same letters again: already in the atlas
	testing.expect_value(t, rig.updates, 26)
	testing.expect_value(t, rig.counter, 1)
	typeface_frame_end(&rig.tf)

	draw(dl, &rig.tf, "abcdefghijklmnopqrstuvwxyz0123456789", {0, 0}, 20, ren.WHITE) // 62 of the 64 cells are taken
	testing.expect_value(t, rig.updates, 62)
	typeface_frame_end(&rig.tf)

	draw(dl, &rig.tf, "!#$%&*+-/:;<=>?@", {0, 0}, 20, ren.WHITE) // 16 more: the 14 least recently used (A to N) lose their cells
	testing.expect_value(t, rig.updates, 78)
	typeface_frame_end(&rig.tf)

	draw(dl, &rig.tf, "Z", {0, 0}, 20, ren.WHITE) // not given up
	testing.expect_value(t, rig.updates, 78)
	draw(dl, &rig.tf, "A", {0, 0}, 20, ren.WHITE) // was: drawn again
	testing.expect_value(t, rig.updates, 79)
}

// What was drawn in the frame keeps its cell: a frame that needs more glyphs than the atlas has cells draws what fits, not the wrong letters.
@(test)
a_glyph_of_the_current_frame_is_never_replaced :: proc(t: ^testing.T) {
	rig: Rig
	rig_start(&rig)
	defer rig_close(&rig)
	typeface_add(&rig.tf, LIBERATION, atlas_size = 256) // 64 cells at 20 px
	dl := ren.begin_frame(&rig.r)

	b := make([]u8, 90, context.temp_allocator)
	for i in 0 ..< 90 {
		b[i] = u8('!' + i) // 90 different characters
	}
	draw(dl, &rig.tf, string(b), {0, 0}, 20, ren.WHITE)
	testing.expect_value(t, rig.updates, 64)
	testing.expect_value(t, len(dl.vertices), 64 * 4) // the rest was not drawn (and no letter was drawn with a picture that is another's)

	typeface_frame_end(&rig.tf) // a new frame: the cells are free to be given again
	draw(dl, &rig.tf, string(b[64:]), {0, 0}, 20, ren.WHITE)
	testing.expect_value(t, rig.updates, 90)
}

// A big size is made in a bigger atlas, so that it still has room for glyphs.
@(test)
a_big_size_gets_a_bigger_atlas :: proc(t: ^testing.T) {
	rig: Rig
	rig_open(&rig, LIBERATION)
	defer rig_close(&rig)
	dl := ren.begin_frame(&rig.r)
	testing.expect_value(t, draw(dl, &rig.tf, "Ag", {0, 0}, 160, ren.WHITE) > 100, true)
	testing.expect_value(t, len(dl.vertices), 2 * 4)
}
