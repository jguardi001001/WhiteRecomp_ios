package ren_vulkan

import "base:runtime"
import "core:log"
import "core:mem"
import vk "vendor:vulkan"
import ren ".."
import ui "../../../iv_ui"

// ---------------------------------------------------------------------------
// Textures. create_texture / update_texture return at once: the texels go into a staging buffer now and are copied
// into the image at the start of the next frame (see record_uploads). A texture made with no pixels is cleared to
// transparent black the same way, so its contents are never undefined.
// ---------------------------------------------------------------------------

@(private = "file")
vk_format :: proc "contextless" (f: ren.Pixel_Format) -> vk.Format {
	switch f {
	case .RGBA8:
		return .R8G8B8A8_UNORM
	case .R8:
		return .R8_UNORM
	case .RG8:
		return .R8G8_UNORM
	case .RGBA16F:
		return .R16G16B16A16_SFLOAT
	case .RGBA32F:
		return .R32G32B32A32_SFLOAT
	}
	return .UNDEFINED
}

backend_create_texture :: proc(b: ^ren.Backend, desc: ren.Texture_Desc) -> (ren.Texture, bool) {
	s := (^State)(b.data)
	if s.lost {
		return 0, false
	}
	handle, ok := make_texture(s, desc)
	return ren.Texture(handle), ok
}

make_texture :: proc(s: ^State, desc: ren.Texture_Desc) -> (handle: u32, ok: bool) {
	if desc.width <= 0 || desc.height <= 0 {
		return 0, false
	}
	is_target := .Render_Target in desc.use
	if is_target && desc.format != .RGBA8 && desc.format != .RGBA16F && desc.format != .RGBA32F {
		log.warn("ren_vulkan: only RGBA8, RGBA16F and RGBA32F textures can be render targets")
		return 0, false
	}
	byte_count := desc.width * desc.height * ren.pixel_size(desc.format)
	if len(desc.pixels) != 0 && len(desc.pixels) != byte_count {
		log.warnf("ren_vulkan: a %dx%d texture needs %d bytes of pixels, got %d", desc.width, desc.height, byte_count, len(desc.pixels))
		return 0, false
	}

	// a filter the format cannot do (32-bit floats on some GPUs) is nearest instead
	filter := desc.filter
	if filter == .Linear {
		props: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(s.physical, vk_format(desc.format), &props)
		if .SAMPLED_IMAGE_FILTER_LINEAR not_in props.optimalTilingFeatures {
			log.warnf("ren_vulkan: %v cannot be filtered linearly here: nearest instead", desc.format)
			filter = .Nearest
		}
	}

	slot := Texture_Slot {
		size      = {desc.width, desc.height},
		format    = desc.format,
		vk_format = vk_format(desc.format),
		filter    = filter,
		sampler   = s.samplers[filter][desc.wrap],
		layout    = .UNDEFINED,
		is_target = is_target,
	}

	usage := vk.ImageUsageFlags{.SAMPLED, .TRANSFER_DST, .TRANSFER_SRC} // SRC: read_texture can read any texture
	if is_target {
		usage += {.COLOR_ATTACHMENT}
	}
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = vk_format(desc.format),
		extent        = {u32(desc.width), u32(desc.height), 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if vk.CreateImage(s.device, &image_info, nil, &slot.image) != .SUCCESS {
		return 0, false
	}
	failed := true
	defer if failed {
		free_garbage(s, Garbage{image = slot.image, view = slot.view, memory = slot.memory, set = slot.set})
	}

	reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(s.device, slot.image, &reqs)
	type_index, found := find_memory_type(s, reqs.memoryTypeBits, {.DEVICE_LOCAL})
	if !found {
		return 0, false
	}
	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = reqs.size,
		memoryTypeIndex = type_index,
	}
	if vk.AllocateMemory(s.device, &alloc, nil, &slot.memory) != .SUCCESS {
		return 0, false
	}
	vk.BindImageMemory(s.device, slot.image, slot.memory, 0)

	// a gray texture reads as gray in all three colour channels (and opaque), a gray + alpha texture the same with its alpha
	// in alpha: what shaders written for raylib's textures expect
	components := vk.ComponentMapping{}
	#partial switch desc.format {
	case .R8:
		components = {.R, .R, .R, .ONE}
	case .RG8:
		components = {.R, .R, .R, .G}
	}
	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = slot.image,
		viewType = .D2,
		format = vk_format(desc.format),
		components = components,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	if vk.CreateImageView(s.device, &view_info, nil, &slot.view) != .SUCCESS {
		return 0, false
	}

	set_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = s.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &s.set_layout,
	}
	if vk.AllocateDescriptorSets(s.device, &set_info, &slot.set) != .SUCCESS {
		log.errorf("ren_vulkan: out of texture slots (at most %d textures)", MAX_TEXTURES)
		return 0, false
	}
	image_descriptor := vk.DescriptorImageInfo {
		sampler     = slot.sampler,
		imageView   = slot.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = slot.set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &image_descriptor,
	}
	vk.UpdateDescriptorSets(s.device, 1, &write, 0, nil)

	// the first contents: the pixels given, or transparent black
	upload := Upload {
		region = {0, 0, desc.width, desc.height},
	}
	if len(desc.pixels) != 0 {
		staging, staged := stage_pixels(s, desc.pixels)
		if !staged {
			return 0, false
		}
		upload.staging = staging
	}

	handle = ren.pool_add(&s.textures, slot)
	if handle == 0 {
		destroy_buffer(s, &upload.staging)
		return 0, false
	}
	upload.texture = handle
	append(&s.uploads, upload)
	failed = false
	return handle, true
}

// A host-visible buffer holding a copy of the pixels.
@(private = "file")
stage_pixels :: proc(s: ^State, pixels: []u8) -> (b: Buffer, ok: bool) {
	b, ok = create_buffer(s, vk.DeviceSize(len(pixels)), {.TRANSFER_SRC}, host = true)
	if !ok {
		return {}, false
	}
	mem.copy(b.mapped, raw_data(pixels), len(pixels))
	return b, true
}

backend_update_texture :: proc(b: ^ren.Backend, t: ren.Texture, region: ui.Rect, pixels: []u8) -> bool {
	s := (^State)(b.data)
	slot := ren.pool_get(&s.textures, u32(t))
	if slot == nil || s.lost {
		return false
	}
	if region.x < 0 || region.y < 0 || region.w <= 0 || region.h <= 0 || region.x + region.w > slot.size.x || region.y + region.h > slot.size.y {
		return false
	}
	if len(pixels) != region.w * region.h * ren.pixel_size(slot.format) {
		return false
	}
	staging, ok := stage_pixels(s, pixels)
	if !ok {
		return false
	}
	append(&s.uploads, Upload{texture = u32(t), staging = staging, region = region})
	return true
}

backend_destroy_texture :: proc(b: ^ren.Backend, t: ren.Texture) {
	s := (^State)(b.data)
	slot := ren.pool_get(&s.textures, u32(t))
	if slot == nil {
		return
	}
	// uploads that have not been recorded yet will never be needed (the GPU has not seen their staging buffers)
	kept := 0
	for &u in s.uploads {
		if u.texture == u32(t) {
			destroy_buffer(s, &u.staging)
		} else {
			s.uploads[kept] = u
			kept += 1
		}
	}
	resize(&s.uploads, kept)

	// the image may still be in use by frames in flight
	defer_destroy(s, Garbage{image = slot.image, view = slot.view, memory = slot.memory, set = slot.set})
	ren.pool_remove(&s.textures, u32(t))
}

// Copies the waiting texels into their images with the barriers around them; called with a command buffer that is being
// recorded (at the start of a frame, or in a one-time command buffer).
record_uploads :: proc(s: ^State, cmd: vk.CommandBuffer) {
	for &u in s.uploads {
		slot := ren.pool_get(&s.textures, u.texture)
		if slot == nil {
			destroy_buffer(s, &u.staging)
			continue
		}

		// to TRANSFER_DST: from nothing (a new image), or after the last time the image was read or drawn into
		if slot.layout == .UNDEFINED {
			image_barrier(cmd, slot.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL, {.TOP_OF_PIPE}, {.TRANSFER}, {}, {.TRANSFER_WRITE})
		} else {
			image_barrier(
				cmd,
				slot.image,
				slot.layout,
				.TRANSFER_DST_OPTIMAL,
				{.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
				{.TRANSFER},
				{.SHADER_SAMPLED_READ, .COLOR_ATTACHMENT_WRITE},
				{.TRANSFER_WRITE},
			)
		}

		subresource := vk.ImageSubresourceLayers {
			aspectMask = {.COLOR},
			layerCount = 1,
		}
		if u.staging.buffer != 0 {
			copy_region := vk.BufferImageCopy {
				imageSubresource = subresource,
				imageOffset      = {i32(u.region.x), i32(u.region.y), 0},
				imageExtent      = {u32(u.region.w), u32(u.region.h), 1},
			}
			vk.CmdCopyBufferToImage(cmd, u.staging.buffer, slot.image, .TRANSFER_DST_OPTIMAL, 1, &copy_region)
		} else {
			clear_value := vk.ClearColorValue {
				float32 = {0, 0, 0, 0},
			}
			range := vk.ImageSubresourceRange {
				aspectMask = {.COLOR},
				levelCount = 1,
				layerCount = 1,
			}
			vk.CmdClearColorImage(cmd, slot.image, .TRANSFER_DST_OPTIMAL, &clear_value, 1, &range)
		}

		// back to being read by the fragment shader (and drawn into, for a render target)
		image_barrier(
			cmd,
			slot.image,
			.TRANSFER_DST_OPTIMAL,
			.SHADER_READ_ONLY_OPTIMAL,
			{.TRANSFER},
			{.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
			{.TRANSFER_WRITE},
			{.SHADER_SAMPLED_READ, .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
		)
		slot.layout = .SHADER_READ_ONLY_OPTIMAL

		// the staging buffer is read by the GPU until this frame has finished
		if u.staging.buffer != 0 {
			defer_destroy(s, Garbage{buffer = u.staging.buffer, memory = u.staging.memory}, used_by_current_frame = true)
		}
	}
	clear(&s.uploads)
}

// Copies pending uploads right now (a one-time command buffer, waits for the GPU).
flush_uploads :: proc(s: ^State) -> bool {
	if len(s.uploads) == 0 {
		return true
	}
	cmd, ok := begin_once(s)
	if !ok {
		return false
	}
	record_uploads(s, cmd)
	return end_once(s, cmd)
}

backend_read_texture :: proc(b: ^ren.Backend, t: ren.Texture, allocator: runtime.Allocator) -> (img: ren.Texture_Image, ok: bool) {
	s := (^State)(b.data)
	if s.lost {
		return {}, false
	}
	vk.DeviceWaitIdle(s.device) // what is drawn so far has finished
	if !flush_uploads(s) {
		return {}, false
	}
	slot := ren.pool_get(&s.textures, u32(t))
	if slot == nil {
		return {}, false
	}

	byte_count := slot.size.x * slot.size.y * ren.pixel_size(slot.format)
	readback, made := create_buffer(s, vk.DeviceSize(byte_count), {.TRANSFER_DST}, host = true)
	if !made {
		return {}, false
	}
	defer destroy_buffer(s, &readback)

	cmd, began := begin_once(s)
	if !began {
		return {}, false
	}
	image_barrier(
		cmd,
		slot.image,
		slot.layout,
		.TRANSFER_SRC_OPTIMAL,
		{.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
		{.TRANSFER},
		{.SHADER_SAMPLED_READ, .COLOR_ATTACHMENT_WRITE},
		{.TRANSFER_READ},
	)
	copy_region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent      = {u32(slot.size.x), u32(slot.size.y), 1},
	}
	vk.CmdCopyImageToBuffer(cmd, slot.image, .TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &copy_region)
	image_barrier(
		cmd,
		slot.image,
		.TRANSFER_SRC_OPTIMAL,
		slot.layout,
		{.TRANSFER},
		{.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
		{.TRANSFER_READ},
		{.SHADER_SAMPLED_READ, .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
	)
	if !end_once(s, cmd) {
		return {}, false
	}

	img = ren.Texture_Image {
		width  = slot.size.x,
		height = slot.size.y,
		format = slot.format,
		pixels = make([]u8, byte_count, allocator),
	}
	mem.copy(raw_data(img.pixels), readback.mapped, byte_count)
	return img, true
}
