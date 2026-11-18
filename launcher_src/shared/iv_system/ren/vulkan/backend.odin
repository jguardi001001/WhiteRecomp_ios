package ren_vulkan

import "core:log"
import vk "vendor:vulkan"
import ren ".."

// ---------------------------------------------------------------------------
// Making the backend for a window, and taking it apart again.
// ---------------------------------------------------------------------------

// Makes the backend for a window: instance, surface, the best device, queue, swapchain, pipelines, frames. Anything that
// fails frees what was made so far. The reasons are logged (core:log) and reported as an error value.
create :: proc(surface: ren.Native_Surface) -> (backend: ren.Backend, err: ren.Create_Error) {
	if surface.kind != SURFACE_KIND || surface.window == nil || surface.display == nil {
		return {}, .Unsupported_Surface
	}
	if !load_loader() {
		return {}, .Unavailable
	}

	s := new(State)
	s.allocator = context.allocator
	s.window_size = {surface.width, surface.height}
	s.textures = {}
	ren.pool_init(&s.textures)
	ren.pool_init(&s.shaders)
	built := false
	defer if !built {
		destroy_state(s)
	}

	instance, why := create_instance()
	if instance == nil {
		log.errorf("ren_vulkan: %s", why)
		return {}, .Unavailable
	}
	s.instance = instance

	// the surface first: which device can present is a question about it
	if res := create_surface(instance, surface); res.result != .SUCCESS {
		log.errorf("ren_vulkan: creating the surface failed: %v", res.result)
		return {}, .Device_Failure
	} else {
		s.surface = res.surface
	}

	candidate, reason, found := find_device(instance, s.surface)
	if !found {
		log.errorf("ren_vulkan: %s", reason)
		return {}, .Unavailable
	}
	s.physical = candidate.physical
	s.queue_family = candidate.queue_family
	vk.GetPhysicalDeviceMemoryProperties(s.physical, &s.memory_props)

	if !create_logical_device(s) {
		return {}, .Device_Failure
	}
	if !create_frames(s) || !create_draw_objects(s) {
		log.error("ren_vulkan: creating the frames and pipelines failed")
		return {}, .Device_Failure
	}

	// a texture of one white texel: what .Solid draws and texture-less commands bind
	white := [4]u8{255, 255, 255, 255}
	ok: bool
	s.white, ok = make_texture(s, ren.Texture_Desc{width = 1, height = 1, format = .RGBA8, filter = .Nearest, pixels = white[:]})
	if !ok {
		return {}, .Device_Failure
	}

	// the swapchain (and with it the window's pipelines); a minimized window has none yet, it is made at the first frame
	if ensure_swapchain(s) == .Failed {
		return {}, .Device_Failure
	}

	s.name = describe(s, candidate.name, candidate.api_version)
	built = true
	return make_backend(s), .None
}

make_backend :: proc(s: ^State) -> ren.Backend {
	return ren.Backend {
		kind = .Vulkan,
		name = s.name,
		data = s,
		resize = backend_resize,
		create_texture = backend_create_texture,
		update_texture = backend_update_texture,
		destroy_texture = backend_destroy_texture,
		create_shader = backend_create_shader,
		destroy_shader = backend_destroy_shader,
		render = backend_render,
		read_texture = backend_read_texture,
		destroy = backend_destroy,
	}
}

@(private = "file")
create_logical_device :: proc(s: ^State) -> bool {
	priority := f32(1)
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = s.queue_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	// scalar uniform block layouts (for custom shaders' uniforms), if the device has them
	f12_have := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
	}
	have := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &f12_have,
	}
	vk.GetPhysicalDeviceFeatures2(s.physical, &have)
	s.scalar_layout = bool(f12_have.scalarBlockLayout)
	f12 := vk.PhysicalDeviceVulkan12Features {
		sType             = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		scalarBlockLayout = b32(s.scalar_layout),
	}
	features := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &f12,
		dynamicRendering = true,
		synchronization2 = true,
	}
	extensions := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions[:]),
	}
	if res := vk.CreateDevice(s.physical, &info, nil, &s.device); res != .SUCCESS {
		log.errorf("ren_vulkan: creating the device failed: %v", res)
		return false
	}
	vk.load_proc_addresses_device(s.device)
	vk.GetDeviceQueue(s.device, s.queue_family, 0, &s.queue)
	return true
}

@(private = "file")
create_frames :: proc(s: ^State) -> bool {
	once_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.TRANSIENT},
		queueFamilyIndex = s.queue_family,
	}
	if vk.CreateCommandPool(s.device, &once_info, nil, &s.once_pool) != .SUCCESS {
		return false
	}
	for &f in s.frames {
		pool_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			queueFamilyIndex = s.queue_family,
		}
		if vk.CreateCommandPool(s.device, &pool_info, nil, &f.pool) != .SUCCESS {
			return false
		}
		alloc := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = f.pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}
		if vk.AllocateCommandBuffers(s.device, &alloc, &f.cmd) != .SUCCESS {
			return false
		}
		sem_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		if vk.CreateSemaphore(s.device, &sem_info, nil, &f.image_available) != .SUCCESS {
			return false
		}
		fence_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED}, // the first wait for this slot must not block
		}
		if vk.CreateFence(s.device, &fence_info, nil, &f.fence) != .SUCCESS {
			return false
		}
	}
	return true
}

backend_destroy :: proc(b: ^ren.Backend) {
	destroy_state(cast(^State)b.data)
	b^ = {}
}

// Frees everything a (possibly half-made) backend owns, in the reverse order of creation.
@(private = "file")
destroy_state :: proc(s: ^State) {
	if s == nil {
		return
	}
	allocator := s.allocator
	if s.device != nil {
		vk.DeviceWaitIdle(s.device)

		for &u in s.uploads {
			destroy_buffer(s, &u.staging)
		}
		for g in s.garbage {
			free_garbage(s, g)
		}
		for &slot in s.textures.slots {
			if slot.used {
				free_garbage(s, Garbage{image = slot.value.image, view = slot.value.view, memory = slot.value.memory, set = slot.value.set})
			}
		}
		for &f in s.frames {
			destroy_buffer(s, &f.vertices)
			destroy_buffer(s, &f.indices)
			destroy_buffer(s, &f.uniforms)
			if f.sets_pool != 0 {
				vk.DestroyDescriptorPool(s.device, f.sets_pool, nil)
			}
			if f.fence != 0 {
				vk.DestroyFence(s.device, f.fence, nil)
			}
			if f.image_available != 0 {
				vk.DestroySemaphore(s.device, f.image_available, nil)
			}
			if f.pool != 0 {
				vk.DestroyCommandPool(s.device, f.pool, nil) // frees its command buffer too
			}
		}
		if s.once_pool != 0 {
			vk.DestroyCommandPool(s.device, s.once_pool, nil)
		}

		destroy_pipelines(s)
		for &slot in s.shaders.slots {
			if slot.used {
				if slot.value.pipeline_layout != 0 {
					vk.DestroyPipelineLayout(s.device, slot.value.pipeline_layout, nil)
				}
				if slot.value.set_layout != 0 {
					vk.DestroyDescriptorSetLayout(s.device, slot.value.set_layout, nil)
				}
				if slot.value.module != 0 {
					vk.DestroyShaderModule(s.device, slot.value.module, nil)
				}
			}
		}
		if s.vertex_shader != 0 {
			vk.DestroyShaderModule(s.device, s.vertex_shader, nil)
		}
		for material in ([?]ren.Material{.Textured, .Coverage, .Sdf}) { // Solid shares Textured's
			if m := s.fragment_shaders[material]; m != 0 {
				vk.DestroyShaderModule(s.device, m, nil)
			}
		}
		if s.descriptor_pool != 0 {
			vk.DestroyDescriptorPool(s.device, s.descriptor_pool, nil)
		}
		if s.pipeline_layout != 0 {
			vk.DestroyPipelineLayout(s.device, s.pipeline_layout, nil)
		}
		if s.set_layout != 0 {
			vk.DestroyDescriptorSetLayout(s.device, s.set_layout, nil)
		}
		for filter in s.samplers {
			for sampler in filter {
				if sampler != 0 {
					vk.DestroySampler(s.device, sampler, nil)
				}
			}
		}
		if s.ubo_pool != 0 {
			vk.DestroyDescriptorPool(s.device, s.ubo_pool, nil)
		}
		if s.ubo_set_layout != 0 {
			vk.DestroyDescriptorSetLayout(s.device, s.ubo_set_layout, nil)
		}

		destroy_swapchain_images(s)
		if s.swapchain != 0 {
			vk.DestroySwapchainKHR(s.device, s.swapchain, nil)
		}
		vk.DestroyDevice(s.device, nil)
	}
	if s.surface != 0 {
		vk.DestroySurfaceKHR(s.instance, s.surface, nil)
	}
	if s.instance != nil {
		vk.DestroyInstance(s.instance, nil)
	}

	ren.pool_destroy(&s.textures)
	ren.pool_destroy(&s.shaders)
	ren.pool_destroy(&s.shaders)
	delete(s.images)
	delete(s.views)
	delete(s.image_layouts)
	delete(s.render_finished)
	delete(s.garbage)
	delete(s.uploads)
	delete(s.name, allocator)
	free(s, allocator)
}
