package ren_vulkan

import "core:dynlib"
import "core:os"
import "core:strings"
import vk "vendor:vulkan"
import ren ".."

// ---------------------------------------------------------------------------
// The parts of the Vulkan backend that are different on each operating system (macOS here: MoltenVK, Vulkan on top of Metal).
// The window's view is layer-hosting with a CAMetalLayer (platform_darwin.odin makes it and keeps its contentsScale), and the
// surface is made from that layer (VK_EXT_metal_surface). MoltenVK is a portability implementation: the instance enables
// VK_KHR_portability_enumeration (ren_vulkan.odin) and the device VK_KHR_portability_subset (backend.odin) when they are offered.
//
// Untested without a Mac: written against the Vulkan and MoltenVK documentation only.
// ---------------------------------------------------------------------------

// The name the probe reports when no loader is found (open_loader tries several, see there).
LOADER_NAME :: "libMoltenVK.dylib"

// The kind of window this file makes surfaces for.
SURFACE_KIND :: ren.Surface_Kind.Cocoa

// The instance extension that makes surfaces for CAMetalLayers (besides VK_KHR_surface).
SURFACE_EXTENSION :: cstring(vk.EXT_METAL_SURFACE_EXTENSION_NAME)

// Metal has no "can this queue present?" question without a layer: every MoltenVK queue family can present, and `create`
// asks again with the real surface anyway.
presentation_supported :: proc(physical: vk.PhysicalDevice, queue_family: u32) -> bool {
	return true
}

Surface_Result :: struct {
	surface: vk.SurfaceKHR,
	result:  vk.Result,
}

// A surface for the window: Native_Surface.window is the CAMetalLayer of the window's view (.display is the NSView).
create_surface :: proc(instance: vk.Instance, surface: ren.Native_Surface) -> Surface_Result {
	info := vk.MetalSurfaceCreateInfoEXT {
		sType  = .METAL_SURFACE_CREATE_INFO_EXT,
		pLayer = (^vk.CAMetalLayer)(surface.window),
	}
	r: Surface_Result
	r.result = vk.CreateMetalSurfaceEXT(instance, &info, nil, &r.surface)
	return r
}

// Loads the Vulkan library: $IV_VULKAN_LIB if it is set, then what an .app bundle ships in Contents/Frameworks (MoltenVK
// itself, or the Khronos loader), then the loader and MoltenVK where dyld, /usr/local (the LunarG SDK) and Homebrew put them.
open_loader :: proc() -> (lib: dynlib.Library, ok: bool) {
	if env, found := os.lookup_env("IV_VULKAN_LIB", context.temp_allocator); found && env != "" {
		if lib, ok = dynlib.load_library(env); ok {
			return
		}
	}
	if exe_dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		for name in ([?]string{"libMoltenVK.dylib", "libvulkan.1.dylib"}) {
			path := strings.concatenate({exe_dir, "/../Frameworks/", name}, context.temp_allocator)
			if lib, ok = dynlib.load_library(path); ok {
				return
			}
		}
	}
	for path in ([?]string{
		"libvulkan.1.dylib",
		"libMoltenVK.dylib",
		"/usr/local/lib/libvulkan.1.dylib",
		"/opt/homebrew/lib/libvulkan.1.dylib",
		"/opt/homebrew/lib/libMoltenVK.dylib",
	}) {
		if lib, ok = dynlib.load_library(path); ok {
			return
		}
	}
	return nil, false
}
