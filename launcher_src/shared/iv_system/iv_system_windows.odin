package iv_system

import "platform"
import "ren"

// The window as a ren.Native_Surface: what a backend draws into.
native_surface :: proc(w: ^platform.Window) -> ren.Native_Surface {
	h := platform.native_handle(w)
	return ren.Native_Surface{kind = .Win32, window = h.window, display = h.display, width = w.size.x, height = w.size.y, dpi_scale = w.dpi_scale}
}
