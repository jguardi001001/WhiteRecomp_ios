package iv_system_tests

import "core:testing"
import debug "../../iv_debug"
import text "../../iv_text"
import ren "../ren"
import vk "../ren/vulkan"

// ---------------------------------------------------------------------------
// iv_text and iv_debug drawn by the real Vulkan backend (their own tests use a renderer with no GPU, which cannot show whether the pixels are right).
// Skipped without Vulkan 1.3.
// ---------------------------------------------------------------------------

@(test)
text_and_a_debug_window_reach_the_screen :: proc(t: ^testing.T) {
	f: vk.Fixture
	if !vk.open_fixture(t, &f) {
		return
	}
	defer vk.close_fixture(&f)
	tf: text.Typeface
	text.typeface_init(&tf, &f.renderer)
	defer text.typeface_destroy(&tf)
	_, ok := text.typeface_add(&tf, LIBERATION_BOLD)
	testing.expect(t, ok)

	target := vk.make_target(t, &f, 320, 240)
	ctx: debug.Context
	debug.init(&ctx, &tf, 14)
	defer debug.destroy(&ctx)

	value: f32 = 1.5
	flag := true
	dl := ren.begin_frame(&f.renderer)
	ren.push_target(dl, target, {320, 240})
	ren.push_blend(dl, .Opaque)
	ren.draw_rect(dl, {0, 0, 320, 240}, ren.BLACK)
	ren.pop_blend(dl)
	debug.begin_frame(&ctx, {mouse = {-10, -10}}, {320, 240})
	if debug.window(&ctx, "Tweaks", {10, 10, 300, 120}) {
		debug.drag(&ctx, "gravity", &value, 0.1)
		debug.checkbox(&ctx, "god mode", &flag)
	}
	debug.end_window(&ctx)
	debug.end_frame(&ctx, dl)
	ren.pop_target(dl)
	text.draw(dl, &tf, "not in the target", {0, 0}, 10, ren.WHITE) // (drawn to the window, not the target)
	vk.finish(t, &f)
	text.typeface_frame_end(&tf)

	img := vk.read(t, &f, target)
	// the window's body is not black, there is bright text (labels are 222 gray) in it, and the corner outside the window is still black
	bright, body := 0, 0
	for y in 10 ..< 130 {
		for x in 10 ..< 310 {
			p := vk.pixel(img, x, y)
			if p.r > 200 && p.g > 200 {
				bright += 1
			}
			if p.r > 10 || p.g > 10 || p.b > 10 {
				body += 1
			}
		}
	}
	testing.expectf(t, bright > 150, "text pixels in the window: %d", bright)
	testing.expectf(t, body > 300 * 100, "the window body is drawn: %d", body)
	corner := vk.pixel(img, 315, 235)
	testing.expect(t, corner.r < 5 && corner.g < 5 && corner.b < 5, "outside the window stays black")
}
