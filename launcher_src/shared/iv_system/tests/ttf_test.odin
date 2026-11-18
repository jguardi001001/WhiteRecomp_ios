package iv_system_tests

import "core:testing"
import ren "../ren"
import vk "../ren/vulkan"
import ren_ttf "../ren/ttf"

// ---------------------------------------------------------------------------
// Tests that need more than one package of iv_system (they are here so that no package has to import what only its tests need):
// TrueType text drawn by the Vulkan backend. They use the fixtures of the Vulkan tests and are skipped without Vulkan 1.3.
// ---------------------------------------------------------------------------

LIBERATION_BOLD :: #load("../ren/ttf/testdata/LiberationSans-Bold.ttf")

@(test)
ttf_text_is_measured_and_drawn :: proc(t: ^testing.T) {
	f: vk.Fixture
	if !vk.open_fixture(t, &f) {
		return
	}
	defer vk.close_fixture(&f)
	font, ok := ren_ttf.create(&f.renderer, LIBERATION_BOLD, 24)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer ren_ttf.destroy(font)

	w_hello, h := ren.font_measure(font, "Hello")
	w_wide, _ := ren.font_measure(font, "WWWWW")
	w_thin, _ := ren.font_measure(font, "iiiii")
	testing.expect(t, w_hello > 40 && w_hello < 90)
	testing.expect(t, w_wide > w_hello && w_hello > w_thin) // proportional: W is wide, i is narrow
	testing.expect(t, h >= 24 && h <= 36)
	two_lines_w, two_lines_h := ren.font_measure(font, "Hello\nHi")
	testing.expect_value(t, two_lines_w, w_hello)
	testing.expect_value(t, two_lines_h, 2 * h)

	target := vk.make_target(t, &f, 100, 40)
	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, target, {100, 40})
	width := ren.draw_text(dl, font, "Hello", {4, 4}, ren.WHITE)
	testing.expect_value(t, width, w_hello)
	ren.pop_target(dl)
	vk.finish(t, &f)

	img := vk.read(t, &f, target)
	// white-ish pixels exist inside the text's box and none outside it
	inside, outside := 0, 0
	for y in 0 ..< 40 {
		for x in 0 ..< 100 {
			if vk.pixel(img, x, y).a > 128 {
				if x >= 4 && x < 4 + w_hello && y >= 4 && y < 4 + h {
					inside += 1
				} else {
					outside += 1
				}
			}
		}
	}
	testing.expectf(t, inside > 120, "%d text pixels", inside)
	testing.expect_value(t, outside, 0)

	// the same text again (the glyphs come from the atlas now) and a rune the font does not have (the fallback, '?')
	w_missing, _ := ren.font_measure(font, "\U0001F600")
	w_question, _ := ren.font_measure(font, "?")
	testing.expect_value(t, w_missing, w_question)
}

@(test)
ttf_atlas_that_is_full_draws_what_fits :: proc(t: ^testing.T) {
	f: vk.Fixture
	if !vk.open_fixture(t, &f) {
		return
	}
	defer vk.close_fixture(&f)
	font, ok := ren_ttf.create(&f.renderer, LIBERATION_BOLD, 24, atlas_size = 32) // room for a glyph or two
	if !testing.expect(t, ok) {
		return
	}
	defer ren_ttf.destroy(font)
	ren.font_measure(font, "ABCDEFGHIJ") // must not crash or loop when the atlas is full; the rest has no glyph
	dl := ren.begin_frame(&f.renderer)
	ren.draw_text(dl, font, "ABCDEFGHIJ", {0, 0}, ren.WHITE)
	vk.finish(t, &f)
}

@(test)
ttf_em_metrics_and_full_atlas :: proc(t: ^testing.T) {
	// no renderer is needed for the units and the advances
	testing.expect_value(t, ren_ttf.units_per_em(LIBERATION_BOLD), 2048)
	m: ren_ttf.Metrics
	if !testing.expect(t, ren_ttf.metrics_init(&m, LIBERATION_BOLD)) {
		return
	}
	a_w, w_ok := ren_ttf.metrics_advance(&m, 'W')
	a_i, i_ok := ren_ttf.metrics_advance(&m, 'i')
	testing.expect(t, w_ok && i_ok)
	testing.expect(t, a_w > 0.8 && a_w < 1.1, "W is about an em wide")
	testing.expect(t, a_i > 0.1 && a_i < 0.4, "i is narrow")
	_, has := ren_ttf.metrics_advance(&m, '\U0001F600')
	testing.expect(t, !has, "the font has no emoji")

	f: vk.Fixture
	if !vk.open_fixture(t, &f) {
		return
	}
	defer vk.close_fixture(&f)
	// an em of 40 px: the advance of a letter is its advance in em times 40
	font, ok := ren_ttf.create_em(&f.renderer, LIBERATION_BOLD, 40)
	if !testing.expect(t, ok) {
		return
	}
	defer ren_ttf.destroy(font)
	g, found := ren.glyph_of(font, 'W')
	testing.expect(t, found)
	testing.expectf(t, abs(g.advance - a_w * 40) < 0.01, "advance %v, wanted %v", g.advance, a_w * 40)
	testing.expect(t, !ren_ttf.is_full(font))

	small, sok := ren_ttf.create_em(&f.renderer, LIBERATION_BOLD, 40, atlas_size = 32)
	if !testing.expect(t, sok) {
		return
	}
	defer ren_ttf.destroy(small)
	for c in 'A' ..= 'J' {
		ren.glyph_of(small, c)
	}
	testing.expect(t, ren_ttf.is_full(small), "a 32 x 32 atlas cannot hold ten 40 px letters")
}
