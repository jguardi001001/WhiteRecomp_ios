package ren_vulkan

import vk "vendor:vulkan"
import ren ".."

// ---------------------------------------------------------------------------
// The parts of the Vulkan backend that are different on each operating system: the name of the loader library, the
// extension that makes surfaces for windows, and how a surface is made from a window. (Wayland and Cocoa/MoltenVK get
// their own files later.)
// ---------------------------------------------------------------------------

LOADER_NAME :: "vulkan-1.dll"

// The kind of window this file makes surfaces for.
SURFACE_KIND :: ren.Surface_Kind.Win32

// The instance extensions a window system needs, besides VK_KHR_surface.
SURFACE_EXTENSION :: cstring(vk.KHR_WIN32_SURFACE_EXTENSION_NAME)

// Can this queue family of this device present to a window of this system? (Answered before any window exists, which is
// what lets the probe run without one.)
presentation_supported :: proc(physical: vk.PhysicalDevice, queue_family: u32) -> bool {
	return bool(vk.GetPhysicalDeviceWin32PresentationSupportKHR(physical, queue_family))
}

Surface_Result :: struct {
	surface: vk.SurfaceKHR,
	result:  vk.Result,
}

// A surface for the window.
create_surface :: proc(instance: vk.Instance, surface: ren.Native_Surface) -> Surface_Result {
	info := vk.Win32SurfaceCreateInfoKHR {
		sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
		hinstance = vk.HINSTANCE(surface.display),
		hwnd      = vk.HWND(surface.window),
	}
	r: Surface_Result
	r.result = vk.CreateWin32SurfaceKHR(instance, &info, nil, &r.surface)
	return r
}
