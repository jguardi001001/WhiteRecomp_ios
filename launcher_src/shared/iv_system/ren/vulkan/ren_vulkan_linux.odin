package ren_vulkan

import vk "vendor:vulkan"
import ren ".."

// ---------------------------------------------------------------------------
// The parts of the Vulkan backend that are different on each operating system: Linux here, where the window (SDL's:
// platform_sdl.odin) is a Wayland or an X11 one. See the Windows file.
// ---------------------------------------------------------------------------

LOADER_NAME :: "libvulkan.so.1"

// The kind of window the tests make surfaces for (the platform says which a real window is).
SURFACE_KIND :: ren.Surface_Kind.Wayland

// The instance extensions that make surfaces for Wayland and X11 windows (besides VK_KHR_surface): the ones the loader has
// are enabled.
SURFACE_EXTENSIONS :: [?]cstring{vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME, vk.KHR_XLIB_SURFACE_EXTENSION_NAME}

surface_kind_ok :: proc(kind: ren.Surface_Kind) -> bool {
	return kind == .Wayland || kind == .X11
}

// Wayland and X11 can only answer "can this queue family present?" for a given connection, and the probe has none (it
// runs before any window exists), so here it says yes; `create` asks the question again with the real surface
// (vkGetPhysicalDeviceSurfaceSupportKHR) and takes a device that really can.
presentation_supported :: proc(physical: vk.PhysicalDevice, queue_family: u32) -> bool {
	return true
}

Surface_Result :: struct {
	surface: vk.SurfaceKHR,
	result:  vk.Result,
}

// A surface for the window. Wayland: Native_Surface.window is the wl_surface, .display the wl_display; X11: .window the
// Window (an XID), .display the Display*.
create_surface :: proc(instance: vk.Instance, surface: ren.Native_Surface) -> Surface_Result {
	r: Surface_Result
	if surface.kind == .X11 {
		if vk.CreateXlibSurfaceKHR == nil {
			r.result = .ERROR_EXTENSION_NOT_PRESENT
			return r
		}
		info := vk.XlibSurfaceCreateInfoKHR {
			sType  = .XLIB_SURFACE_CREATE_INFO_KHR,
			dpy    = (^vk.XlibDisplay)(surface.display),
			window = vk.XlibWindow(uintptr(surface.window)),
		}
		r.result = vk.CreateXlibSurfaceKHR(instance, &info, nil, &r.surface)
		return r
	}
	if vk.CreateWaylandSurfaceKHR == nil {
		r.result = .ERROR_EXTENSION_NOT_PRESENT
		return r
	}
	info := vk.WaylandSurfaceCreateInfoKHR {
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = (^vk.wl_display)(surface.display),
		surface = (^vk.wl_surface)(surface.window),
	}
	r.result = vk.CreateWaylandSurfaceKHR(instance, &info, nil, &r.surface)
	return r
}
