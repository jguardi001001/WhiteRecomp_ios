// Which backends exist and in what order they are tried. It is the one place that imports every backend, so `ren` itself
// and each backend stay free of each other (a program that wants only the CPU backend imports that one directly).
// The package is named ren_auto, in the way ren_vulkan is.
package ren_auto

import ren ".."
import vulkan "../vulkan"

// The backends that are written. To add one: import it and put its factory here. (ren/opengl and ren/software are not
// written: importing them does not compile. A kind in `order` that has no factory here is skipped, and the report says so
// by not listing it.)
factories :: proc() -> [1]ren.Factory {
	return {vulkan.factory()}
}

// Tries the backends in `order` (empty = ren.DEFAULT_ORDER: Vulkan so far) and returns the renderer
// of the first that works; see ren.create_first for the report and the "null renderer" when none does.
create :: proc(
	surface: ren.Native_Surface,
	order: []ren.Backend_Kind = nil,
	allocator := context.allocator,
) -> (
	r: ren.Renderer,
	report: ren.Create_Report,
	ok: bool,
) {
	f := factories()
	if len(order) == 0 {
		return ren.create_first(surface, f[:], ren.DEFAULT_ORDER[:], allocator)
	}
	return ren.create_first(surface, f[:], order, allocator)
}
