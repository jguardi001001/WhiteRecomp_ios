// iv_system: windows, input and 2D rendering, in three packages that do not know each other:
//
//   iv_system/platform   the operating system's window and its events (Windows so far)
//   iv_system/ren        backend-agnostic 2D rendering (a draw list + a Backend interface)
//   iv_system/ren/vulkan the Vulkan backend; ren/auto chooses between backends
//
// This package, the root, is the thin glue that connects them for a program that wants all three: it makes the window,
// asks ren/auto for the best backend that works on it, and keeps the two in step (resizing, recreating the window when a
// backend needs a fresh one). A program that wants something else (SDL for the window, only the CPU backend) skips this
// package and uses the pieces directly.
//
//   app, ok := iv.open({title = "Hello", width = 1280, height = 720})
//   defer iv.close(app)
//   ctx: input.Context(My_Signal)
//   for !app.window.close_requested {
//       iv.pump(app, &ctx)                                  // window events, input, resizing
//       dl := ren.begin_frame(&app.renderer, ren.BLACK)
//       ren.draw_rect(dl, {10, 10, 100, 40}, ren.WHITE)
//       ren.end_frame(&app.renderer)
//   }
package iv_system

import input "../iv_input"
import "platform"
import "ren"
import "ren/auto"

App :: struct {
	window:   ^platform.Window,
	renderer: ren.Renderer, // always valid; a "null" renderer (ren.renderer_is_null) when no backend works
	report:   ren.Create_Report, // what was tried, and why each backend was or was not chosen
}

// Makes the window and the best renderer that works on it. `ok` is false only if the window cannot be made; with no
// working backend the program still has its window and a null renderer (check ren.renderer_is_null and app.report).
open :: proc(desc: platform.Window_Desc, order: []ren.Backend_Kind = nil, allocator := context.allocator) -> (app: ^App, ok: bool) {
	w, made := platform.create_window(desc, allocator)
	if !made {
		return nil, false
	}
	app = new(App, allocator)
	app.window = w

	order := order
	if len(order) == 0 {
		order = ren.DEFAULT_ORDER[:]
	}
	for {
		app.renderer, app.report, _ = auto.create(native_surface(w), order, allocator)
		if !app.report.needs_new_window {
			break
		}
		// a backend that ties the window to itself failed: a fresh window, and the backends that are left
		ren.renderer_destroy(&app.renderer)
		if !platform.recreate_window(w) {
			app.renderer = {}
			ren.renderer_init(&app.renderer, {}, w.size.x, w.size.y, allocator)
			break
		}
		order = order[app.report.next_index:]
	}
	return app, true
}

close :: proc(app: ^App) {
	if app == nil {
		return
	}
	ren.renderer_destroy(&app.renderer)
	platform.destroy_window(app.window)
	free(app)
}

// Once per frame: the operating system's messages, the frame's input into `ctx`, and the renderer told about a new size.
// Returns what happened to the window.
pump :: proc(app: ^App, ctx: ^input.Context($S)) -> platform.Window_Events {
	events := platform.poll(app.window)
	platform.feed_input(app.window, ctx)
	if .Resized in events {
		ren.resize(&app.renderer, app.window.size.x, app.window.size.y)
	}
	return events
}
