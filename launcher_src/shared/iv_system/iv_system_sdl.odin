#+build linux, darwin
package iv_system

import "platform"
import "ren"

// The window as a ren.Native_Surface: what a backend draws into. The window is SDL's (platform_sdl.odin); its handles are
// the window system's: Wayland (wl_surface, wl_display), X11 (Window, Display*) or, on macOS, Cocoa (the CAMetalLayer of
// SDL's Metal view, the view).
native_surface :: proc(w: ^platform.Window) -> ren.Native_Surface {
	h := platform.native_handle(w)
	kind := ren.Surface_Kind.None
	if h.window != nil {
		switch h.kind {
		case .Wayland: kind = .Wayland
		case .X11: kind = .X11
		case .Cocoa: kind = .Cocoa
		case .Win32: kind = .Win32
		}
	}
	return ren.Native_Surface{kind = kind, window = h.window, display = h.display, width = w.size.x, height = w.size.y, dpi_scale = w.dpi_scale}
}
