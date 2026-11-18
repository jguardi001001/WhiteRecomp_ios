package ren

import "base:runtime"
import ui "../../iv_ui"

// ---------------------------------------------------------------------------
// ren: backend-agnostic 2D rendering.
//
//   program ──► Draw_List (draw_list.odin: records vertices, indices, commands) ──► Backend ──► the screen
//                pure Odin, no GPU                                                  Vulkan | OpenGL | CPU
//
// This file is the seam between the two halves: the Backend interface a graphics API implements, the Native_Surface
// that says where to draw (so `ren` does not import the platform layer and can run without a window), the Renderer that
// ties a draw list to a backend, and the choice of backend at startup (Factory, create_first).
// ---------------------------------------------------------------------------

Backend_Kind :: enum u8 {
	Vulkan, // written: ren/vulkan
	OpenGL, // not written: ren/opengl does not compile
	Software, // not written (ren/software does not compile): the CPU backend, the reference for what every other backend must draw
}

// The order tried by default: the best first. Only backends that are written are in it; OpenGL and Software join it, in that
// order, when they exist.
DEFAULT_ORDER := [?]Backend_Kind{.Vulkan}

// The order of the full design, for code that works with all the kinds (tests of the choice logic use fake backends).
FULL_ORDER := [?]Backend_Kind{.Vulkan, .OpenGL, .Software}

// ---- where to draw ----------------------------------------------------------------------------------------

Surface_Kind :: enum u8 {
	None, // no window: the CPU backend can draw into memory only (tests, screenshots)
	Win32,
	Wayland,
	Cocoa,
}

// What a backend needs of a window to draw into it. The platform layer makes one (iv_system.native_surface); anything
// else (SDL, GLFW, a test) can make one too.
Native_Surface :: struct {
	kind:      Surface_Kind,
	window:    rawptr, // Win32: HWND; Wayland: wl_surface; Cocoa: CAMetalLayer
	display:   rawptr, // Win32: HINSTANCE; Wayland: wl_display
	width:     int, // in pixels
	height:    int,
	dpi_scale: f32, // 1 = 96 dpi
}

// ---- the backend interface ----------------------------------------------------------------------------------

// What happened to a frame.
Present_Result :: enum u8 {
	Presented, // on the screen
	Skipped, // nothing was shown (window minimized or zero-sized, swapchain being rebuilt): not an error, draw again next frame
	Device_Lost, // the backend is unusable (driver reset, GPU removed): destroy the renderer and create a new one
}

// What a graphics API has to do. A backend fills this in (`data` is its own state) and the rest of the program only ever
// goes through the Renderer. A nil procedure means "not supported".
Backend :: struct {
	kind:            Backend_Kind,
	name:            string, // for logs: "Vulkan 1.3 (NVIDIA GeForce ...)"
	data:            rawptr,

	// The window's size in pixels changed (the swapchain / viewport follows).
	resize:          proc(b: ^Backend, width, height: int),
	create_texture:  proc(b: ^Backend, desc: Texture_Desc) -> (Texture, bool),
	// Replaces the texels of `region` (in texels) with `pixels` (region.w * region.h * pixel size, rows from the top).
	update_texture:  proc(b: ^Backend, t: Texture, region: ui.Rect, pixels: []u8) -> bool,
	destroy_texture: proc(b: ^Backend, t: Texture),
	// Custom fragment shaders (nil: this backend cannot run them).
	create_shader:   proc(b: ^Backend, desc: Shader_Desc) -> (Shader, bool),
	destroy_shader:  proc(b: ^Backend, s: Shader),
	// Draws the list into the window (and into any render targets it pushes) and shows it.
	render:          proc(b: ^Backend, list: ^Draw_List) -> Present_Result,
	// Waits for the GPU and copies the texels of a texture (usually a render target) to memory: for tests, screenshots and
	// for comparing backends. Slow, not for every frame. The pixels are the texture's own format, rows from the top.
	read_texture:    proc(b: ^Backend, t: Texture, allocator: runtime.Allocator) -> (Texture_Image, bool),
	destroy:         proc(b: ^Backend),
}

// ---- choosing a backend -----------------------------------------------------------------------------------

Create_Error :: enum u8 {
	None,
	Unavailable, // the probe said no (no driver, too old)
	Unsupported_Surface, // this backend cannot draw into this kind of window
	Device_Failure, // creating the device, swapchain or context failed
	Not_Implemented, // the backend is a stub so far
}

// The answer to "could this backend run on this computer", asked WITHOUT a window (so a failed probe costs nothing).
Probe :: struct {
	available: bool,
	reason:    string, // why not, or what was found; valid until the temp allocator is freed
	device:    string, // the graphics card's name, if known; the same lifetime
}

// How a graphics API plugs into the choice. A Factory is two procedures: probe and create.
Factory :: struct {
	kind:         Backend_Kind,
	probe:        proc() -> Probe,
	create:       proc(surface: Native_Surface) -> (Backend, Create_Error),
	// True if creating the backend ties the window to this API for good, so that a failed attempt leaves the window
	// unusable for the next one (OpenGL on Windows: SetPixelFormat can be called once per window). create_first then
	// stops and asks for a new window instead of carrying on with the old one.
	fresh_window: bool,
}

Attempt :: struct {
	kind:  Backend_Kind,
	probe: Probe,
	tried: bool, // create was called (the probe passed)
	error: Create_Error,
}

Create_Report :: struct {
	chosen:           Backend_Kind, // valid if create_first returned true
	attempts:         [len(Backend_Kind)]Attempt,
	attempt_count:    int,
	// create_first gave up early because a `fresh_window` backend failed on this window: make a new window and call again
	// with order[next_index:].
	needs_new_window: bool,
	next_index:       int,
}

// Tries the backends of `order` in turn and returns the renderer of the first one that works. A backend is skipped if no
// factory is given for it, if its probe says no, or if create fails; `report` says what happened to each. With nothing
// working the renderer is still valid but "null": it records draw lists and drops them (end_frame returns .Skipped).
create_first :: proc(
	surface: Native_Surface,
	factories: []Factory,
	order: []Backend_Kind,
	allocator := context.allocator,
) -> (
	r: Renderer,
	report: Create_Report,
	ok: bool,
) {
	for kind, index in order {
		f: Factory
		found := false
		for candidate in factories {
			if candidate.kind == kind && candidate.probe != nil && candidate.create != nil {
				f, found = candidate, true
				break
			}
		}
		if !found || report.attempt_count >= len(report.attempts) {
			continue
		}
		a := &report.attempts[report.attempt_count]
		report.attempt_count += 1
		a.kind = kind
		a.probe = f.probe()
		if !a.probe.available {
			continue
		}
		a.tried = true
		backend, err := f.create(surface)
		a.error = err
		if err != .None {
			if f.fresh_window {
				report.needs_new_window = true
				report.next_index = index + 1
				break
			}
			continue
		}
		renderer_init(&r, backend, surface.width, surface.height, allocator)
		report.chosen = kind
		return r, report, true
	}
	renderer_init(&r, {}, surface.width, surface.height, allocator)
	return r, report, false
}

// ---- the renderer -------------------------------------------------------------------------------------------

Renderer :: struct {
	backend: Backend, // all procedures nil for a null renderer
	list:    Draw_List,
	width:   int, // the window's size in pixels
	height:  int,
	frames:  u64,
}

renderer_init :: proc(r: ^Renderer, backend: Backend, width, height: int, allocator := context.allocator) {
	r.backend = backend
	r.width = width
	r.height = height
	draw_list_init(&r.list, allocator)
}

renderer_destroy :: proc(r: ^Renderer) {
	if r.backend.destroy != nil {
		r.backend.destroy(&r.backend)
	}
	draw_list_destroy(&r.list)
	r^ = {}
}

// Is there a real backend behind this renderer?
renderer_is_null :: proc(r: ^Renderer) -> bool {
	return r.backend.render == nil
}

// The window's size in pixels changed.
resize :: proc(r: ^Renderer, width, height: int) {
	r.width, r.height = width, height
	if r.backend.resize != nil {
		r.backend.resize(&r.backend, width, height)
	}
}

// Starts a frame and returns the list to draw into (never nil, also for a null renderer). `clear` is what the window is
// cleared with first (nil = keep what is there).
begin_frame :: proc(r: ^Renderer, clear: Maybe(Color) = BLACK) -> ^Draw_List {
	draw_list_reset(&r.list, r.width, r.height, clear)
	return &r.list
}

// Hands the list to the backend, which draws and shows it.
end_frame :: proc(r: ^Renderer) -> Present_Result {
	r.frames += 1
	if r.backend.render == nil {
		return .Skipped
	}
	return r.backend.render(&r.backend, &r.list)
}

// ---- textures -----------------------------------------------------------------------------------------------

texture_create :: proc(r: ^Renderer, desc: Texture_Desc) -> (Texture, bool) {
	if r.backend.create_texture == nil {
		return 0, false
	}
	return r.backend.create_texture(&r.backend, desc)
}

texture_update :: proc(r: ^Renderer, t: Texture, region: ui.Rect, pixels: []u8) -> bool {
	if r.backend.update_texture == nil {
		return false
	}
	return r.backend.update_texture(&r.backend, t, region, pixels)
}

// Makes a custom fragment shader (see Shader_Desc). false: this backend cannot run shaders, or the shader does not fit.
shader_create :: proc(r: ^Renderer, desc: Shader_Desc) -> (Shader, bool) {
	if r.backend.create_shader == nil {
		return 0, false
	}
	return r.backend.create_shader(&r.backend, desc)
}

shader_destroy :: proc(r: ^Renderer, s: Shader) {
	if r.backend.destroy_shader != nil && s != 0 {
		r.backend.destroy_shader(&r.backend, s)
	}
}

texture_destroy :: proc(r: ^Renderer, t: Texture) {
	if r.backend.destroy_texture != nil && t != 0 {
		r.backend.destroy_texture(&r.backend, t)
	}
}

// The texels of a texture read back from the GPU. `pixels` belongs to the caller (the allocator it passed).
Texture_Image :: struct {
	width, height: int,
	format:        Pixel_Format,
	pixels:        []u8,
}

// Reads a texture back (see Backend.read_texture). Blocks until the GPU is done.
texture_read :: proc(r: ^Renderer, t: Texture, allocator := context.allocator) -> (Texture_Image, bool) {
	if r.backend.read_texture == nil || t == 0 {
		return {}, false
	}
	return r.backend.read_texture(&r.backend, t, allocator)
}
