package ren_vulkan

import vk "vendor:vulkan"
import ren ".."

// ---------------------------------------------------------------------------
// The parts of the Vulkan backend that are different on each operating system (Wayland here; see the Windows file).
// ---------------------------------------------------------------------------

LOADER_NAME :: "libvulkan.so.1"

// The kind of window this file makes surfaces for.
SURFACE_KIND :: ren.Surface_Kind.Wayland

// The instance extension that makes surfaces for Wayland windows (besides VK_KHR_surface).
SURFACE_EXTENSION :: cstring(vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME)

// Wayland can only answer "can this queue family present?" for a given wl_display, and the probe has none (it runs before any
// window exists), so here it says yes; `create` asks the question again with the real surface (vkGetPhysicalDeviceSurfaceSupportKHR)
// and takes a device that really can.
presentation_supported :: proc(physical: vk.PhysicalDevice, queue_family: u32) -> bool {
	return true
}

Surface_Result :: struct {
	surface: vk.SurfaceKHR,
	result:  vk.Result,
}

// A surface for the window: Native_Surface.window is the wl_surface, .display the wl_display (the connection platform made).
create_surface :: proc(instance: vk.Instance, surface: ren.Native_Surface) -> Surface_Result {
	info := vk.WaylandSurfaceCreateInfoKHR {
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = (^vk.wl_display)(surface.display),
		surface = (^vk.wl_surface)(surface.window),
	}
	r: Surface_Result
	r.result = vk.CreateWaylandSurfaceKHR(instance, &info, nil, &r.surface)
	return r
}
