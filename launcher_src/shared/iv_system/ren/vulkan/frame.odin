package ren_vulkan

import "core:log"
import "core:mem"
import vk "vendor:vulkan"
import ren ".."
import ui "../../../iv_ui"

// ---------------------------------------------------------------------------
// A frame: take the next swapchain image, copy the draw list's vertices and indices into this frame's buffers, record the
// commands (texture uploads, then one scissor + pipeline + descriptor set + indexed draw per ren.Command, switching
// render targets where the commands do), submit, present.
// ---------------------------------------------------------------------------

// How long a frame waits for the window system to hand out an image before it gives up and is skipped.
ACQUIRE_TIMEOUT_NS :: 1_000_000_000

backend_resize :: proc(b: ^ren.Backend, width, height: int) {
	s := (^State)(b.data)
	s.window_size = {width, height}
	// the swapchain itself is made again at the next frame, from what the surface says its size is
}

// What a frame needs while its commands are being recorded.
@(private = "file")
Pass :: struct {
	s:              ^State,
	frame:          ^Frame,
	list:           ^ren.Draw_List,
	cmd:            vk.CommandBuffer,
	target_format:  vk.Format, // of the open pass's target
	push:           Push_Constants, // what the open pass pushed (pushed again when the pipeline layout changes)
	layout:         vk.PipelineLayout, // the layout the sets below were bound with
	shader_draws:   int, // custom shader commands so far in this frame (their texture sets come from a pool of MAX_SHADER_DRAWS)
	image_view:     vk.ImageView, // the swapchain image's view
	has_geometry:   bool, // the vertex and index buffers hold the list
	active:         bool, // a pass (a stretch of drawing into one target) is open
	skipping:       bool, // ... for a target that cannot be drawn into: its commands are dropped
	target:         ren.Texture, // of the open pass; 0 = the window
	target_slot:    ^Texture_Slot,
	extent:         [2]int, // of the open pass's target
	window_started: bool, // the window has had its first pass (the one that clears)
	keep_window:    bool, // the first window pass keeps what was in the image instead of clearing
	pipeline:       vk.Pipeline, // what is bound now
	set:            vk.DescriptorSet,
}

backend_render :: proc(b: ^ren.Backend, list: ^ren.Draw_List) -> ren.Present_Result {
	s := (^State)(b.data)
	if s.lost {
		return .Device_Lost
	}

	switch ensure_swapchain(s) {
	case .Ok:
	case .Zero_Size:
		return .Skipped
	case .Failed:
		return .Device_Lost if s.lost else .Skipped
	}

	frame := &s.frames[s.frame_index]

	// the frame slot's last use must be over before its buffers and command buffer are touched
	if res := vk.WaitForFences(s.device, 1, &frame.fence, true, max(u64)); res != .SUCCESS {
		if res == .ERROR_DEVICE_LOST {
			s.lost = true
			return .Device_Lost
		}
		return .Skipped
	}
	collect_garbage(s)
	vk.ResetDescriptorPool(s.device, frame.sets_pool, {}) // (the custom shader commands of this slot's last frame are over)

	// With a timeout: a window system that stops sending frame callbacks to a hidden window (Wayland does) would otherwise
	// block the program here for ever.
	image_index: u32
	#partial switch res := vk.AcquireNextImageKHR(s.device, s.swapchain, ACQUIRE_TIMEOUT_NS, frame.image_available, 0, &image_index); res {
	case .SUCCESS, .SUBOPTIMAL_KHR:
	case .TIMEOUT, .NOT_READY:
		return .Skipped
	case .ERROR_DEVICE_LOST:
		s.lost = true
		return .Device_Lost
	case:
		s.dirty = true // out of date: made again, and no frame this time
		return .Skipped
	}
	vk.ResetFences(s.device, 1, &frame.fence)

	// ---- the geometry ----
	vertex_bytes := len(list.vertices) * size_of(ren.Vertex)
	index_bytes := len(list.indices) * size_of(u32)
	has_geometry := ensure_frame_buffers(s, frame, vertex_bytes, index_bytes)
	if has_geometry && vertex_bytes > 0 {
		mem.copy(frame.vertices.mapped, raw_data(list.vertices), vertex_bytes)
		mem.copy(frame.indices.mapped, raw_data(list.indices), index_bytes)
	}
	if len(list.uniform_data) > 0 {
		if ensure_frame_uniforms(s, frame, len(list.uniform_data)) {
			mem.copy(frame.uniforms.mapped, raw_data(list.uniform_data), len(list.uniform_data))
		} else {
			has_geometry = false // no room for the uniforms: nothing is drawn (the commands need them)
		}
	}

	// ---- the commands ----
	vk.ResetCommandPool(s.device, frame.pool, {})
	begin := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(frame.cmd, &begin)
	record_uploads(s, frame.cmd)

	image := s.images[image_index]
	_, wants_clear := list.clear.?
	keep := !wants_clear && s.image_layouts[image_index] == .PRESENT_SRC_KHR
	image_barrier(
		frame.cmd,
		image,
		.PRESENT_SRC_KHR if keep else .UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
		{},
		{.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
	)

	p := Pass {
		s            = s,
		frame        = frame,
		list         = list,
		cmd          = frame.cmd,
		image_view   = s.views[image_index],
		has_geometry = has_geometry,
		keep_window  = keep,
	}
	if has_geometry && vertex_bytes > 0 {
		offset := vk.DeviceSize(0)
		vk.CmdBindVertexBuffers(frame.cmd, 0, 1, &frame.vertices.buffer, &offset)
		vk.CmdBindIndexBuffer(frame.cmd, frame.indices.buffer, 0, .UINT32)
	}

	for &c in list.commands {
		if !p.active || c.target != p.target {
			if p.active {
				end_pass(&p)
			}
			begin_pass(&p, c.target)
		}
		draw_command(&p, &c)
	}
	if p.active {
		end_pass(&p)
	}
	if !p.window_started { // nothing was drawn to the window: it is still cleared
		begin_pass(&p, 0)
		end_pass(&p)
	}

	image_barrier(
		frame.cmd,
		image,
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.BOTTOM_OF_PIPE},
		{.COLOR_ATTACHMENT_WRITE},
		{},
	)
	s.image_layouts[image_index] = .PRESENT_SRC_KHR
	vk.EndCommandBuffer(frame.cmd)

	// ---- submit and present ----
	wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &frame.image_available,
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &frame.cmd,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &s.render_finished[image_index],
	}
	if res := vk.QueueSubmit(s.queue, 1, &submit, frame.fence); res != .SUCCESS {
		log.errorf("ren_vulkan: submitting a frame failed: %v", res)
		if res == .ERROR_DEVICE_LOST {
			s.lost = true
			return .Device_Lost
		}
		return .Skipped
	}
	s.frame_index = (s.frame_index + 1) % FRAMES_IN_FLIGHT
	s.frame_count += 1

	present := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &s.render_finished[image_index],
		swapchainCount     = 1,
		pSwapchains        = &s.swapchain,
		pImageIndices      = &image_index,
	}
	#partial switch res := vk.QueuePresentKHR(s.queue, &present); res {
	case .SUCCESS:
		return .Presented
	case .SUBOPTIMAL_KHR:
		return .Presented // shown; a changed size is noticed by ensure_swapchain
	case .ERROR_DEVICE_LOST:
		s.lost = true
		return .Device_Lost
	case:
		s.dirty = true // out of date
		return .Skipped
	}
}

// Room in this frame's buffers for what the list holds (they only grow). false: no memory, the frame draws nothing.
@(private = "file")
ensure_frame_buffers :: proc(s: ^State, f: ^Frame, vertex_bytes, index_bytes: int) -> bool {
	grow :: proc(s: ^State, b: ^Buffer, needed: int, usage: vk.BufferUsageFlags) -> bool {
		if needed <= int(b.size) {
			return true
		}
		destroy_buffer(s, b) // this frame slot's last use has finished (its fence was waited for)
		size := max(needed, 64 * 1024)
		made, ok := create_buffer(s, vk.DeviceSize(size), usage, host = true)
		if !ok {
			log.errorf("ren_vulkan: no memory for a %d byte buffer", size)
			return false
		}
		b^ = made
		return true
	}
	// twice what is needed, so that a growing list does not reallocate every frame
	if !grow(s, &f.vertices, vertex_bytes if vertex_bytes <= int(f.vertices.size) else vertex_bytes * 2, {.VERTEX_BUFFER}) {
		return false
	}
	return grow(s, &f.indices, index_bytes if index_bytes <= int(f.indices.size) else index_bytes * 2, {.INDEX_BUFFER})
}

// ---- passes: stretches of drawing into one target -------------------------------------------------------------------

@(private = "file")
begin_pass :: proc(p: ^Pass, target: ren.Texture) {
	s := p.s
	p.active = true
	p.skipping = false
	p.target = target
	p.target_slot = nil
	p.pipeline = 0
	p.set = 0

	view: vk.ImageView
	load_op := vk.AttachmentLoadOp.LOAD
	clear_value: vk.ClearValue

	if target == 0 {
		view = p.image_view
		p.target_format = s.format
		p.extent = {int(s.extent.width), int(s.extent.height)}
		if !p.window_started {
			p.window_started = true
			if c, has := p.list.clear.?; has {
				load_op = .CLEAR
				clear_value.color.float32 = {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
			} else if !p.keep_window {
				load_op = .CLEAR // an image that was never drawn to has nothing to keep
			}
		}
	} else {
		slot := ren.pool_get(&s.textures, u32(target))
		if slot == nil || !slot.is_target {
			p.skipping = true // a stale handle, or a texture made without .Render_Target: its commands are dropped
			return
		}
		p.target_slot = slot
		p.target_format = slot.vk_format
		view = slot.view
		p.extent = slot.size
		image_barrier(
			p.cmd,
			slot.image,
			.SHADER_READ_ONLY_OPTIMAL,
			.COLOR_ATTACHMENT_OPTIMAL,
			{.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
			{.COLOR_ATTACHMENT_OUTPUT},
			{.SHADER_SAMPLED_READ, .COLOR_ATTACHMENT_WRITE},
			{.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
		)
		slot.layout = .COLOR_ATTACHMENT_OPTIMAL
	}

	attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = load_op,
		storeOp     = .STORE,
		clearValue  = clear_value,
	}
	area := vk.Rect2D {
		extent = {u32(p.extent.x), u32(p.extent.y)},
	}
	info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = area,
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &attachment,
	}
	vk.CmdBeginRendering(p.cmd, &info)

	viewport := vk.Viewport {
		width    = f32(p.extent.x),
		height   = f32(p.extent.y),
		maxDepth = 1,
	}
	vk.CmdSetViewport(p.cmd, 0, 1, &viewport)

	// pixels -> clip space: x' = x * 2/w - 1, y' = y * 2/h - 1 (Vulkan's y points down, like the screen)
	p.push = Push_Constants {
		scale  = {2 / f32(p.extent.x), 2 / f32(p.extent.y)},
		offset = {-1, -1},
	}
	p.layout = s.pipeline_layout
	vk.CmdPushConstants(p.cmd, s.pipeline_layout, {.VERTEX}, 0, PUSH_CONSTANTS_SIZE, &p.push)
}

@(private = "file")
end_pass :: proc(p: ^Pass) {
	p.active = false
	if p.skipping {
		return
	}
	vk.CmdEndRendering(p.cmd)
	if p.target_slot != nil {
		// the target can be sampled by what comes next, or drawn into again
		image_barrier(
			p.cmd,
			p.target_slot.image,
			.COLOR_ATTACHMENT_OPTIMAL,
			.SHADER_READ_ONLY_OPTIMAL,
			{.COLOR_ATTACHMENT_OUTPUT},
			{.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
			{.COLOR_ATTACHMENT_WRITE},
			{.SHADER_SAMPLED_READ, .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
		)
		p.target_slot.layout = .SHADER_READ_ONLY_OPTIMAL
	} else {
		// the window may be drawn into again by a later pass (blending reads what is there)
		memory_barrier(p.cmd, {.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_WRITE}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE})
	}
}

// Sets the scissor to the command's clip (inside the target); false if nothing of it is left.
@(private = "file")
set_scissor :: proc(p: ^Pass, c: ^ren.Command) -> bool {
	clip := ui.intersect(c.clip, ui.Rect{0, 0, p.extent.x, p.extent.y})
	if ui.is_empty(clip) {
		return false
	}
	scissor := vk.Rect2D {
		offset = {i32(clip.x), i32(clip.y)},
		extent = {u32(clip.w), u32(clip.h)},
	}
	vk.CmdSetScissor(p.cmd, 0, 1, &scissor)
	return true
}

// Makes `layout` the one the sets and the pipeline are bound with: a different layout invalidates the sets that were bound (so
// they are bound again) and the push constants are pushed again to be sure.
@(private = "file")
use_layout :: proc(p: ^Pass, layout: vk.PipelineLayout) {
	if p.layout != layout {
		p.layout = layout
		p.set = 0
		vk.CmdPushConstants(p.cmd, layout, {.VERTEX}, 0, PUSH_CONSTANTS_SIZE, &p.push)
	}
}

@(private = "file")
draw_command :: proc(p: ^Pass, c: ^ren.Command) {
	s := p.s
	if p.skipping || !p.has_geometry || c.index_count == 0 {
		return
	}
	if c.shader != 0 {
		draw_custom(p, c)
		return
	}

	// the texture: none (a texture-less material) binds the white one
	texture := ren.Texture(s.white) if c.texture == 0 else c.texture
	if texture == c.target && c.target != 0 {
		return // a texture cannot be read while it is drawn into
	}
	slot := ren.pool_get(&s.textures, u32(texture))
	if slot == nil {
		return // a stale handle: dropped
	}
	if !set_scissor(p, c) {
		return
	}

	pipeline, made := get_pipeline(s, {format = p.target_format, material = c.material, blend = c.blend})
	if !made {
		return
	}
	use_layout(p, s.pipeline_layout)
	if pipeline != p.pipeline {
		vk.CmdBindPipeline(p.cmd, .GRAPHICS, pipeline)
		p.pipeline = pipeline
	}
	if slot.set != p.set {
		set := slot.set
		vk.CmdBindDescriptorSets(p.cmd, .GRAPHICS, s.pipeline_layout, 0, 1, &set, 0, nil)
		p.set = slot.set
	}
	// the indices already hold absolute vertex numbers (the draw list added the base), so the vertex offset is 0
	vk.CmdDrawIndexed(p.cmd, c.index_count, 1, c.first_index, 0, 0)
}

// A command of a custom shader: its uniforms are at c.uniform_offset in the frame's uniform buffer (a dynamic offset), its
// textures go in a descriptor set made for this one command.
@(private = "file")
draw_custom :: proc(p: ^Pass, c: ^ren.Command) {
	s := p.s
	shader := ren.pool_get(&s.shaders, u32(c.shader))
	if shader == nil || p.shader_draws >= MAX_SHADER_DRAWS {
		return
	}
	if !set_scissor(p, c) {
		return
	}
	pipeline, made := get_pipeline(s, {format = p.target_format, shader = u32(c.shader), blend = c.blend})
	if !made {
		return
	}

	// the texture set: one image per sampler of the shader; a missing one, or one that is being drawn into, is the white texture
	set_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = p.frame.sets_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &shader.set_layout,
	}
	texture_set: vk.DescriptorSet
	if vk.AllocateDescriptorSets(s.device, &set_info, &texture_set) != .SUCCESS {
		return
	}
	p.shader_draws += 1
	images: [ren.MAX_SHADER_TEXTURES]vk.DescriptorImageInfo
	writes: [ren.MAX_SHADER_TEXTURES]vk.WriteDescriptorSet
	white := ren.pool_get(&s.textures, s.white)
	for i in 0 ..< shader.sampler_count {
		slot := white
		if u32(i) < c.texture_count {
			wanted := p.list.shader_textures[int(c.texture_first) + i]
			if wanted != 0 && wanted != c.target {
				if found := ren.pool_get(&s.textures, u32(wanted)); found != nil {
					slot = found
				}
			}
		}
		images[i] = {
			sampler     = slot.sampler,
			imageView   = slot.view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
		writes[i] = {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = texture_set,
			dstBinding      = u32(i),
			descriptorCount = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			pImageInfo      = &images[i],
		}
	}
	if shader.sampler_count > 0 {
		vk.UpdateDescriptorSets(s.device, u32(shader.sampler_count), raw_data(writes[:]), 0, nil)
	}

	use_layout(p, shader.pipeline_layout)
	if pipeline != p.pipeline {
		vk.CmdBindPipeline(p.cmd, .GRAPHICS, pipeline)
		p.pipeline = pipeline
	}
	sets := [2]vk.DescriptorSet{p.frame.ubo_set, texture_set}
	offset := c.uniform_offset
	vk.CmdBindDescriptorSets(p.cmd, .GRAPHICS, shader.pipeline_layout, 0, 2, raw_data(sets[:]), 1, &offset)
	p.set = 0 // (the next built-in command binds its own set again)
	vk.CmdDrawIndexed(p.cmd, c.index_count, 1, c.first_index, 0, 0)
}

// Room in this frame's uniform buffer for `bytes` (and for the range of the descriptor past the last offset), and the
// descriptor pointed at the buffer if it is a new one.
@(private = "file")
ensure_frame_uniforms :: proc(s: ^State, f: ^Frame, bytes: int) -> bool {
	needed := vk.DeviceSize(bytes) + s.ubo_range
	if needed > f.uniforms.size {
		destroy_buffer(s, &f.uniforms)
		size := max(needed * 2, 4 * s.ubo_range)
		made, ok := create_buffer(s, size, {.UNIFORM_BUFFER}, host = true)
		if !ok {
			log.errorf("ren_vulkan: no memory for a %d byte uniform buffer", size)
			return false
		}
		f.uniforms = made
	}
	if f.ubo_bound != f.uniforms.buffer {
		info := vk.DescriptorBufferInfo {
			buffer = f.uniforms.buffer,
			offset = 0,
			range  = s.ubo_range,
		}
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = f.ubo_set,
			dstBinding      = 0,
			descriptorCount = 1,
			descriptorType  = .UNIFORM_BUFFER_DYNAMIC,
			pBufferInfo     = &info,
		}
		vk.UpdateDescriptorSets(s.device, 1, &write, 0, nil)
		f.ubo_bound = f.uniforms.buffer
	}
	return true
}
