package ren_vulkan

import "core:log"
import vk "vendor:vulkan"

// ---------------------------------------------------------------------------
// Memory: finding a memory type, buffers, one-time commands, and the deferred destruction of things the GPU may still use.
// Each buffer and image has its own allocation (simple; fine for a 2D renderer with a few hundred textures. Vulkan allows
// about 4000 allocations per device: a sub-allocator is the first thing to add if that ever matters).
// ---------------------------------------------------------------------------

find_memory_type :: proc(s: ^State, type_bits: u32, wanted: vk.MemoryPropertyFlags) -> (index: u32, ok: bool) {
	for i in 0 ..< s.memory_props.memoryTypeCount {
		if type_bits & (1 << i) != 0 && wanted <= s.memory_props.memoryTypes[i].propertyFlags {
			return i, true
		}
	}
	return 0, false
}

// `host` memory is visible to the CPU (and coherent, so no flushes) and stays mapped; otherwise it is device-local.
create_buffer :: proc(s: ^State, size: vk.DeviceSize, usage: vk.BufferUsageFlags, host: bool) -> (b: Buffer, ok: bool) {
	info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	if vk.CreateBuffer(s.device, &info, nil, &b.buffer) != .SUCCESS {
		return {}, false
	}
	reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(s.device, b.buffer, &reqs)

	wanted := vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT} if host else vk.MemoryPropertyFlags{.DEVICE_LOCAL}
	type_index, found := find_memory_type(s, reqs.memoryTypeBits, wanted)
	if !found {
		vk.DestroyBuffer(s.device, b.buffer, nil)
		return {}, false
	}
	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = reqs.size,
		memoryTypeIndex = type_index,
	}
	if vk.AllocateMemory(s.device, &alloc, nil, &b.memory) != .SUCCESS {
		vk.DestroyBuffer(s.device, b.buffer, nil)
		return {}, false
	}
	vk.BindBufferMemory(s.device, b.buffer, b.memory, 0)
	if host {
		if vk.MapMemory(s.device, b.memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &b.mapped) != .SUCCESS {
			vk.FreeMemory(s.device, b.memory, nil)
			vk.DestroyBuffer(s.device, b.buffer, nil)
			return {}, false
		}
	}
	b.size = size
	return b, true
}

destroy_buffer :: proc(s: ^State, b: ^Buffer) {
	if b.buffer != 0 {
		vk.DestroyBuffer(s.device, b.buffer, nil)
	}
	if b.memory != 0 {
		vk.FreeMemory(s.device, b.memory, nil) // also unmaps
	}
	b^ = {}
}

// ---- deferred destruction ------------------------------------------------------------------------------------------

// Hands things to be destroyed when no frame in flight can use them any more. `used_by_current_frame`: the frame being
// recorded right now (not submitted yet, so not counted in frame_count) uses it too.
defer_destroy :: proc(s: ^State, g: Garbage, used_by_current_frame := false) {
	g := g
	g.frame = s.frame_count + (1 if used_by_current_frame else 0)
	append(&s.garbage, g)
}

free_garbage :: proc(s: ^State, g: Garbage) {
	if g.set != 0 {
		set := g.set
		vk.FreeDescriptorSets(s.device, s.descriptor_pool, 1, &set)
	}
	if g.view != 0 {
		vk.DestroyImageView(s.device, g.view, nil)
	}
	if g.image != 0 {
		vk.DestroyImage(s.device, g.image, nil)
	}
	if g.buffer != 0 {
		vk.DestroyBuffer(s.device, g.buffer, nil)
	}
	if g.memory != 0 {
		vk.FreeMemory(s.device, g.memory, nil)
	}
}

// Called when a frame slot has just been waited for: frames 0 .. frame_count - FRAMES_IN_FLIGHT have finished.
collect_garbage :: proc(s: ^State) {
	completed := u64(0)
	if s.frame_count + 1 >= FRAMES_IN_FLIGHT {
		completed = s.frame_count + 1 - FRAMES_IN_FLIGHT
	}
	kept := 0
	for g in s.garbage {
		if g.frame <= completed {
			free_garbage(s, g)
		} else {
			s.garbage[kept] = g
			kept += 1
		}
	}
	resize(&s.garbage, kept)
}

// ---- one-time commands -----------------------------------------------------------------------------------------------

// A command buffer to record into; end_once submits it and waits until it has finished.
begin_once :: proc(s: ^State) -> (cmd: vk.CommandBuffer, ok: bool) {
	alloc := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = s.once_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if vk.AllocateCommandBuffers(s.device, &alloc, &cmd) != .SUCCESS {
		return nil, false
	}
	begin := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(cmd, &begin) != .SUCCESS {
		vk.FreeCommandBuffers(s.device, s.once_pool, 1, &cmd)
		return nil, false
	}
	return cmd, true
}

end_once :: proc(s: ^State, cmd: vk.CommandBuffer) -> bool {
	cmd := cmd
	defer vk.FreeCommandBuffers(s.device, s.once_pool, 1, &cmd)
	if vk.EndCommandBuffer(cmd) != .SUCCESS {
		return false
	}
	submit := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd,
	}
	if res := vk.QueueSubmit(s.queue, 1, &submit, 0); res != .SUCCESS {
		if res == .ERROR_DEVICE_LOST {
			s.lost = true
		}
		log.errorf("ren_vulkan: queue submit failed: %v", res)
		return false
	}
	if res := vk.QueueWaitIdle(s.queue); res != .SUCCESS {
		if res == .ERROR_DEVICE_LOST {
			s.lost = true
		}
		return false
	}
	return true
}

// ---- barriers -----------------------------------------------------------------------------------------------------

// One layout transition of a whole colour image, with the stages and accesses it separates.
image_barrier :: proc(
	cmd: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_access, dst_access: vk.AccessFlags2,
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = src_stage,
		srcAccessMask       = src_access,
		dstStageMask        = dst_stage,
		dstAccessMask       = dst_access,
		oldLayout           = old_layout,
		newLayout           = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
}

// A memory dependency between two uses of the same attachment (no layout change).
memory_barrier :: proc(
	cmd: vk.CommandBuffer,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_access, dst_access: vk.AccessFlags2,
) {
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = src_stage,
		srcAccessMask = src_access,
		dstStageMask  = dst_stage,
		dstAccessMask = dst_access,
	}
	dep := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
}
