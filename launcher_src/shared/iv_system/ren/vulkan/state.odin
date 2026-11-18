package ren_vulkan

import "base:runtime"
import vk "vendor:vulkan"
import ren ".."
import ui "../../../iv_ui"

// ---------------------------------------------------------------------------
// Everything one Vulkan backend owns, and the constants that shape it.
// ---------------------------------------------------------------------------

// How many frames the CPU may record ahead of the GPU. Each has its own command buffer, fence, acquire semaphore and
// vertex / index buffers.
FRAMES_IN_FLIGHT :: 2

// What render target textures are made of (the window uses what the swapchain gives).
RENDER_TARGET_FORMAT :: vk.Format.R8G8B8A8_UNORM

// How many textures can exist at once (one descriptor set each; the pool is a fixed size).
MAX_TEXTURES :: 2048

// The presentation modes in order of preference; the first one the window system offers is used.
//   MAILBOX  the newest finished frame replaces the one waiting: no tearing, the lowest latency, runs as fast as it can
//   FIFO     plain vsync: no tearing, the frame rate is the monitor's. Every driver has it.
//   IMMEDIATE  no waiting: tears. Not in the list by default; add it (before .FIFO) to get it.
// FIFO is the last resort because it is the only mode the Vulkan specification guarantees.
present_mode_order := [?]vk.PresentModeKHR{.MAILBOX, .FIFO}

// A buffer with its own memory, optionally mapped for good.
Buffer :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
	mapped: rawptr, // non-nil for the host-visible ones made with mapped = true
}

// One frame in flight.
Frame :: struct {
	pool:            vk.CommandPool,
	cmd:             vk.CommandBuffer,
	image_available: vk.Semaphore, // signalled by vkAcquireNextImageKHR
	fence:           vk.Fence, // signalled when the frame's commands have finished (starts signalled)
	vertices:        Buffer,
	indices:         Buffer,
	uniforms:        Buffer, // the uniforms of the frame's custom shader commands
	ubo_set:         vk.DescriptorSet, // binds `uniforms` (dynamic offset per command)
	ubo_bound:       vk.Buffer, // the buffer ubo_set currently describes
	sets_pool:       vk.DescriptorPool, // the texture sets of the custom shader commands; reset every frame
}

// The most custom shader commands a frame can have (one texture descriptor set each).
MAX_SHADER_DRAWS :: 4096

// How many bytes of uniforms one custom shader can have (the range of the dynamic uniform buffer descriptor).
UBO_RANGE_WANTED :: 65536

Texture_Slot :: struct {
	image:     vk.Image,
	view:      vk.ImageView,
	memory:    vk.DeviceMemory,
	set:       vk.DescriptorSet, // the sampler + view, bound when a command uses this texture
	size:      [2]int,
	format:    ren.Pixel_Format,
	vk_format: vk.Format,
	filter:    ren.Filter,
	sampler:   vk.Sampler,
	layout:    vk.ImageLayout, // as of the end of the commands recorded so far
	is_target: bool,
}

// Texels waiting to be copied into a texture at the start of the next frame (or at the next read_texture).
Upload :: struct {
	texture: u32, // the pool handle
	staging:  Buffer, // buffer == 0: no data, clear the region to transparent black instead
	region:   ui.Rect,
}

// Things to destroy once the GPU can no longer be using them: after the frames in flight that were submitted when it was
// queued have finished. Fields that are 0 are skipped.
Garbage :: struct {
	frame:  u64, // the number of frames submitted when it was queued
	buffer: vk.Buffer,
	image:  vk.Image,
	view:   vk.ImageView,
	memory: vk.DeviceMemory,
	set:    vk.DescriptorSet,
}

// What a pipeline is made for: the format it draws into, the shader and the blend mode. (Pipelines are made when first
// needed and kept; a few are made at startup.)
Pipeline_Key :: struct {
	format:   vk.Format,
	shader:   u32, // 0 = a built-in material (below), else the handle of a custom shader
	material: ren.Material, // built-in only; .Solid is never used (it is .Textured)
	blend:    ren.Blend,
}

// A custom fragment shader (ren.Shader_Desc) and what its commands need.
Shader_Slot :: struct {
	module:          vk.ShaderModule,
	uniform_size:    int,
	sampler_count:   int,
	set_layout:      vk.DescriptorSetLayout, // set 1: the samplers
	pipeline_layout: vk.PipelineLayout, // set 0: uniforms, set 1: samplers; the vertex push constants
}

State :: struct {
	allocator:        runtime.Allocator,
	name:             string, // owned; the backend's name for logs
	lost:             bool, // the device was lost: everything fails from here on

	// instance, device
	instance:         vk.Instance,
	surface:          vk.SurfaceKHR,
	physical:         vk.PhysicalDevice,
	device:           vk.Device,
	queue:            vk.Queue,
	queue_family:     u32,
	memory_props:     vk.PhysicalDeviceMemoryProperties,

	// the swapchain (made again when the window's size changes)
	swapchain:        vk.SwapchainKHR,
	format:           vk.Format,
	extent:           vk.Extent2D,
	present_mode:     vk.PresentModeKHR,
	images:           [dynamic]vk.Image,
	views:            [dynamic]vk.ImageView,
	image_layouts:    [dynamic]vk.ImageLayout, // UNDEFINED until first drawn, then PRESENT_SRC_KHR
	render_finished:  [dynamic]vk.Semaphore, // one per swapchain image
	dirty:            bool, // the swapchain must be made again before the next frame
	window_size:      [2]int, // what ren.resize last said (used if the surface does not say)

	// what draws
	set_layout:       vk.DescriptorSetLayout,
	pipeline_layout:  vk.PipelineLayout,
	descriptor_pool:  vk.DescriptorPool,
	samplers:         [ren.Filter][ren.Wrap]vk.Sampler,
	ubo_set_layout:   vk.DescriptorSetLayout, // set 0 of the custom shaders: one dynamic uniform buffer
	ubo_pool:         vk.DescriptorPool,
	ubo_range:        vk.DeviceSize, // what a custom shader's uniform block can be at most
	scalar_layout:    bool, // the device has scalarBlockLayout (custom shaders with uniforms need it)
	shaders:          ren.Pool(Shader_Slot),
	vertex_shader:    vk.ShaderModule,
	fragment_shaders: [ren.Material]vk.ShaderModule, // Solid shares Textured's
	pipelines:        map[Pipeline_Key]vk.Pipeline,

	// frames and what is waiting
	frames:           [FRAMES_IN_FLIGHT]Frame,
	frame_index:      int, // the slot the next frame uses
	frame_count:      u64, // frames submitted so far
	once_pool:        vk.CommandPool, // for the one-time commands of read_texture
	garbage:          [dynamic]Garbage,
	uploads:          [dynamic]Upload,

	// textures
	textures:         ren.Pool(Texture_Slot),
	white:            u32, // a 1x1 white texture: what .Solid draws sample, and what a texture-less command binds
}

// The shader a material uses (Solid is Textured with a white texture).
shader_material :: proc "contextless" (m: ren.Material) -> ren.Material {
	if m == .Solid {
		return .Textured
	}
	return m
}
