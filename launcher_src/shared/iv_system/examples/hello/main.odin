// A first program on iv_system: opens a window, says which backend it got and why, and draws a few things until the window
// is closed (or Esc is pressed, or `-frames N` frames have run: for a check without a person).
//
//   odin run iv_system/examples/hello -collection:shared=C:/Users/psivstar/Documents/proj/shared
//   odin run iv_system/examples/hello -collection:shared=... -- -frames 60
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"
import input "shared:iv_input"
import iv "shared:iv_system"
import "shared:iv_system/ren"
import ui "shared:iv_ui"

Signal :: enum {
	Quit,
}

// A 16 x 16 checkerboard of two colours, as the pixels of an RGBA8 texture.
checker_pixels :: proc() -> [16 * 16 * 4]u8 {
	px: [16 * 16 * 4]u8
	for y in 0 ..< 16 {
		for x in 0 ..< 16 {
			on := (x / 4 + y / 4) % 2 == 0
			c := [4]u8{240, 200, 60, 255} if on else [4]u8{40, 60, 120, 255}
			copy(px[(y * 16 + x) * 4:], c[:])
		}
	}
	return px
}

main :: proc() {
	max_frames := -1
	args := os.args
	for i in 1 ..< len(args) {
		if args[i] == "-frames" && i + 1 < len(args) {
			max_frames, _ = strconv.parse_int(args[i + 1])
		}
	}

	app, ok := iv.open({title = "iv_system hello", width = 800, height = 450, min_width = 320, min_height = 200})
	if !ok {
		fmt.eprintln("could not open a window")
		os.exit(1)
	}
	defer iv.close(app)

	fmt.printfln("window: %d x %d pixels, scale %.2f", app.window.size.x, app.window.size.y, app.window.dpi_scale)
	for a in app.report.attempts[:app.report.attempt_count] {
		fmt.printfln("  %v: %s", a.kind, a.probe.reason)
		if a.tried {
			fmt.printfln("    create -> %v", a.error)
		}
	}
	if ren.renderer_is_null(&app.renderer) {
		fmt.println("no backend could be created: the window runs without drawing")
	} else {
		fmt.printfln("backend: %s", app.renderer.backend.name)
	}

	// textures: a checkerboard sprite, and a small render target that is drawn once and shown many times
	px := checker_pixels()
	checker, _ := ren.texture_create(&app.renderer, {width = 16, height = 16, format = .RGBA8, filter = .Nearest, pixels = px[:]})
	badge, _ := ren.texture_create(&app.renderer, {width = 64, height = 64, format = .RGBA8, filter = .Linear, use = {.Render_Target}})

	ctx: input.Context(Signal)
	frames := 0
	start := time.now()
	for !app.window.close_requested {
		iv.pump(app, &ctx)
		if input.key_pressed(&ctx, .Escape) {
			break
		}
		t := f32(time.duration_seconds(time.since(start)))

		dl := ren.begin_frame(&app.renderer, ren.color_f(0.08, 0.09, 0.12))

		// the badge: drawn into its own texture, every frame (it could just as well be drawn once)
		{
			ren.scope_target(dl, badge, {64, 64})
			ren.draw_rect(dl, {0, 0, 64, 64}, ren.color_f(0.2, 0.5, 0.9, 1))
			ren.draw_rect_outline(dl, {0, 0, 64, 64}, 3, ren.WHITE)
			ren.draw_line(dl, {8, 8}, {56, 56}, 4, ren.color_f(1, 1, 1, 0.8))
			ren.draw_line(dl, {56, 8}, {8, 56}, 4, ren.color_f(1, 1, 1, 0.8))
		}

		// shapes, with alpha
		ren.draw_rect(dl, {20, 20, 200, 60}, ren.color_f(0.9, 0.3, 0.2))
		ren.draw_rect_outline(dl, {20, 20, 200, 60}, 2, ren.WHITE)
		ren.draw_rect(dl, {120, 40, 200, 60}, ren.color_f(0.2, 0.8, 0.5, 0.5))
		ren.draw_line(dl, {20, 130}, {400, 170}, 3, ren.color_f(0.3, 0.8, 0.5))
		ren.draw_triangle(dl, {450, 140}, {520, 20}, {590, 140}, ren.color_f(0.95, 0.8, 0.2))

		// the sprite, scaled up, bouncing; clipped to a panel
		panel := ui.Rect{20, 200, 360, 220}
		ren.draw_rect(dl, panel, ren.color_f(0.14, 0.15, 0.2))
		{
			ren.scope_clip(dl, panel)
			x := 20 + int((math.sin(t * 1.5) * 0.5 + 0.5) * 300)
			ren.draw_image(dl, checker, {x, 220, 128, 128})
			ren.draw_image(dl, checker, {x + 140, 300, 64, 64}, tint = ren.color_f(1, 0.5, 0.5, 0.8))
		}

		// the badge, three times, at different sizes and opacity
		for i in 0 ..< 3 {
			size := 64 + i * 32
			ren.scope_tint(dl, ren.color_f(1, 1, 1, 1 - 0.3 * f32(i)))
			ren.draw_image(dl, badge, {420 + i * 120, 220, size, size})
		}
		{
			ren.scope_blend(dl, .Additive)
			ren.draw_rect(dl, {420, 360, 300, 40}, ren.color_f(0.4, 0.1, 0.5, 1))
		}
		ren.end_frame(&app.renderer)

		frames += 1
		if max_frames >= 0 && frames >= max_frames {
			break
		}
		if ren.renderer_is_null(&app.renderer) {
			time.sleep(16 * time.Millisecond) // nothing paces the loop
		}
	}
	fmt.printfln("%d frames in %.2f s", frames, time.duration_seconds(time.since(start)))
}
