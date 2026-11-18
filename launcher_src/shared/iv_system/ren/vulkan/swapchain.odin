package ren_vulkan

import "core:fmt"
import "core:log"
import vk "vendor:vulkan"

// ---------------------------------------------------------------------------
// The swapchain: the images the window shows. It is made when the backend is, and made again when the window's size
// changes (or the window system says the old one is out of date).
// ---------------------------------------------------------------------------

Swapchain_Result :: enum u8 {
	Ok,
	Zero_Size, // the window is minimized (or has no area): nothing can be drawn
	Failed,
}

present_mode_name :: proc(m: vk.PresentModeKHR) -> string {
	#partial switch m {
	case .MAILBOX:
		return "mailbox"
	case .FIFO:
		return "fifo (vsync)"
	case .FIFO_RELAXED:
		return "fifo relaxed"
	case .IMMEDIATE:
		return "immediate"
	}
	return "other"
}

@(private = "file")
choose_format :: proc(s: ^State) -> (vk.SurfaceFormatKHR, bool) {
	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(s.physical, s.surface, &count, nil)
	if count == 0 {
		return {}, false
	}
	formats := make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(s.physical, s.surface, &count, raw_data(formats))
	// UNORM, not sRGB: the colours given to ren are written as they are, the way the other backends will write them
	for wanted in ([?]vk.Format{.B8G8R8A8_UNORM, .R8G8B8A8_UNORM}) {
		for f in formats[:count] {
			if f.format == wanted && f.colorSpace == .SRGB_NONLINEAR {
				return f, true
			}
		}
	}
	return formats[0], true
}

@(private = "file")
choose_present_mode :: proc(s: ^State) -> vk.PresentModeKHR {
	count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(s.physical, s.surface, &count, nil)
	modes := make([]vk.PresentModeKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(s.physical, s.surface, &count, raw_data(modes))
	for wanted in present_mode_order {
		for m in modes[:count] {
			if m == wanted {
				return m
			}
		}
	}
	return .FIFO // the only one every implementation has
}

// What the surface says its size is (or the size ren was told, for a window system that leaves the choice to us).
@(private = "file")
surface_extent :: proc(s: ^State, caps: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if caps.currentExtent.width != max(u32) {
		return caps.currentExtent
	}
	return vk.Extent2D {
		width = clamp(u32(max(s.window_size.x, 0)), caps.minImageExtent.width, caps.maxImageExtent.width),
		height = clamp(u32(max(s.window_size.y, 0)), caps.minImageExtent.height, caps.maxImageExtent.height),
	}
}

// Makes the swapchain if there is none or it is out of date. Cheap when nothing changed (one surface query).
ensure_swapchain :: proc(s: ^State) -> Swapchain_Result {
	caps: vk.SurfaceCapabilitiesKHR
	if res := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(s.physical, s.surface, &caps); res != .SUCCESS {
		if res == .ERROR_DEVICE_LOST {
			s.lost = true
		}
		return .Failed
	}
	extent := surface_extent(s, caps)
	if extent.width == 0 || extent.height == 0 {
		return .Zero_Size
	}
	if s.swapchain != 0 && !s.dirty && extent == s.extent {
		return .Ok
	}
	return create_swapchain(s, caps, extent)
}

@(private = "file")
create_swapchain :: proc(s: ^State, caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) -> Swapchain_Result {
	surface_format, have_format := choose_format(s)
	if !have_format {
		log.error("ren_vulkan: the surface offers no formats")
		return .Failed
	}
	mode := choose_present_mode(s)

	// one more than the minimum so that the driver is never starved; a mailbox wants a third to swap with
	image_count := caps.minImageCount + 1
	if mode == .MAILBOX {
		image_count = max(image_count, 3)
	}
	if caps.maxImageCount > 0 {
		image_count = min(image_count, caps.maxImageCount)
	}

	alpha := vk.CompositeAlphaFlagsKHR{.OPAQUE}
	if .OPAQUE not_in caps.supportedCompositeAlpha {
		for flag in vk.CompositeAlphaFlagKHR {
			if flag in caps.supportedCompositeAlpha {
				alpha = {flag}
				break
			}
		}
	}

	// nothing may still be using the old images
	vk.DeviceWaitIdle(s.device)

	old := s.swapchain
	info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = s.surface,
		minImageCount    = image_count,
		imageFormat      = surface_format.format,
		imageColorSpace  = surface_format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = alpha,
		presentMode      = mode,
		clipped          = true,
		oldSwapchain     = old,
	}
	new_swapchain: vk.SwapchainKHR
	if res := vk.CreateSwapchainKHR(s.device, &info, nil, &new_swapchain); res != .SUCCESS {
		log.errorf("ren_vulkan: creating the swapchain failed: %v", res)
		if res == .ERROR_DEVICE_LOST {
			s.lost = true
		}
		return .Failed
	}
	destroy_swapchain_images(s)
	if old != 0 {
		vk.DestroySwapchainKHR(s.device, old, nil)
	}
	s.swapchain = new_swapchain
	s.format = surface_format.format
	s.extent = extent
	s.present_mode = mode
	s.dirty = false

	count: u32
	vk.GetSwapchainImagesKHR(s.device, s.swapchain, &count, nil)
	resize(&s.images, int(count))
	vk.GetSwapchainImagesKHR(s.device, s.swapchain, &count, raw_data(s.images))
	resize(&s.views, int(count))
	resize(&s.render_finished, int(count))
	resize(&s.image_layouts, int(count))
	for i in 0 ..< int(count) {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = s.images[i],
			viewType = .D2,
			format = s.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		if vk.CreateImageView(s.device, &view_info, nil, &s.views[i]) != .SUCCESS {
			return .Failed
		}
		sem_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		if vk.CreateSemaphore(s.device, &sem_info, nil, &s.render_finished[i]) != .SUCCESS {
			return .Failed
		}
		s.image_layouts[i] = .UNDEFINED
	}

	// the window's pipelines are made for the swapchain's format (kept per format: a new swapchain of the same one needs none)
	warm_window_pipelines(s)
	if s.name != "" && old == 0 {
		log.infof("ren_vulkan: swapchain %dx%d, %d images, %v, present mode %s", extent.width, extent.height, count, s.format, present_mode_name(mode))
	}
	return .Ok
}

// The views and the semaphores of the current swapchain's images (the images belong to the swapchain).
destroy_swapchain_images :: proc(s: ^State) {
	for v in s.views {
		if v != 0 {
			vk.DestroyImageView(s.device, v, nil)
		}
	}
	for sem in s.render_finished {
		if sem != 0 {
			vk.DestroySemaphore(s.device, sem, nil)
		}
	}
	clear(&s.views)
	clear(&s.render_finished)
	clear(&s.images)
	clear(&s.image_layouts)
}

// What the backend reports for logs: "Vulkan 1.3, AMD Radeon (TM) Graphics, fifo (vsync)".
describe :: proc(s: ^State, device_name: string, api_version: u32) -> string {
	return fmt.aprintf(
		"Vulkan %d.%d, %s, %s",
		vk.API_VERSION_MAJOR(api_version),
		vk.API_VERSION_MINOR(api_version),
		device_name,
		present_mode_name(s.present_mode),
		allocator = s.allocator,
	)
}
