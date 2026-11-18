package ren_vulkan

import "core:log"
import "core:time"
import vk "vendor:vulkan"
import ren ".."

// ---------------------------------------------------------------------------
// What draws: the descriptor layout (one combined image sampler), the pipeline layout (+ push constants for the
// pixel -> clip space scale and offset), the shaders (shaders.odin) and the pipelines: one for each (target format, shader,
// blend) that is used. The built-in shaders are the three of the materials; a custom shader (shader.odin) adds its own.
// ---------------------------------------------------------------------------

PUSH_CONSTANTS_SIZE :: 16 // vec2 scale, vec2 offset

Push_Constants :: struct {
	scale:  [2]f32,
	offset: [2]f32,
}

#assert(size_of(Push_Constants) == PUSH_CONSTANTS_SIZE)

@(private = "file")
make_shader :: proc(s: ^State, code: []u32) -> (m: vk.ShaderModule, ok: bool) {
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code) * size_of(u32),
		pCode    = raw_data(code),
	}
	if res := vk.CreateShaderModule(s.device, &info, nil, &m); res != .SUCCESS {
		log.errorf("ren_vulkan: a shader module was refused: %v", res)
		return 0, false
	}
	return m, true
}

// Samplers, layouts, descriptor pools and the shader modules.
create_draw_objects :: proc(s: ^State) -> bool {
	for filter in ren.Filter {
		for wrap in ren.Wrap {
			mode := vk.Filter.NEAREST if filter == .Nearest else vk.Filter.LINEAR
			address := vk.SamplerAddressMode.CLAMP_TO_EDGE if wrap == .Clamp else vk.SamplerAddressMode.REPEAT
			info := vk.SamplerCreateInfo {
				sType        = .SAMPLER_CREATE_INFO,
				magFilter    = mode,
				minFilter    = mode,
				mipmapMode   = .NEAREST,
				addressModeU = address,
				addressModeV = address,
				addressModeW = address,
				maxLod       = 0.25,
			}
			if vk.CreateSampler(s.device, &info, nil, &s.samplers[filter][wrap]) != .SUCCESS {
				return false
			}
		}
	}

	binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &binding,
	}
	if vk.CreateDescriptorSetLayout(s.device, &layout_info, nil, &s.set_layout) != .SUCCESS {
		return false
	}

	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &s.set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &PUSH_RANGE,
	}
	if vk.CreatePipelineLayout(s.device, &pipeline_layout_info, nil, &s.pipeline_layout) != .SUCCESS {
		return false
	}

	// the texture descriptor sets of all textures
	pool_size := vk.DescriptorPoolSize {
		type            = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = MAX_TEXTURES,
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = MAX_TEXTURES,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	if vk.CreateDescriptorPool(s.device, &pool_info, nil, &s.descriptor_pool) != .SUCCESS {
		return false
	}

	// custom shaders: set 0 is one dynamic uniform buffer per frame
	ubo_binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .UNIFORM_BUFFER_DYNAMIC,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	ubo_layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &ubo_binding,
	}
	if vk.CreateDescriptorSetLayout(s.device, &ubo_layout_info, nil, &s.ubo_set_layout) != .SUCCESS {
		return false
	}
	ubo_pool_size := vk.DescriptorPoolSize {
		type            = .UNIFORM_BUFFER_DYNAMIC,
		descriptorCount = FRAMES_IN_FLIGHT,
	}
	ubo_pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = FRAMES_IN_FLIGHT,
		poolSizeCount = 1,
		pPoolSizes    = &ubo_pool_size,
	}
	if vk.CreateDescriptorPool(s.device, &ubo_pool_info, nil, &s.ubo_pool) != .SUCCESS {
		return false
	}
	for &f in s.frames {
		alloc := vk.DescriptorSetAllocateInfo {
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = s.ubo_pool,
			descriptorSetCount = 1,
			pSetLayouts        = &s.ubo_set_layout,
		}
		if vk.AllocateDescriptorSets(s.device, &alloc, &f.ubo_set) != .SUCCESS {
			return false
		}
		sets_size := vk.DescriptorPoolSize {
			type            = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = MAX_SHADER_DRAWS * ren.MAX_SHADER_TEXTURES,
		}
		sets_info := vk.DescriptorPoolCreateInfo {
			sType         = .DESCRIPTOR_POOL_CREATE_INFO,
			maxSets       = MAX_SHADER_DRAWS,
			poolSizeCount = 1,
			pPoolSizes    = &sets_size,
		}
		if vk.CreateDescriptorPool(s.device, &sets_info, nil, &f.sets_pool) != .SUCCESS {
			return false
		}
	}

	limits: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(s.physical, &limits)
	s.ubo_range = vk.DeviceSize(min(u32(UBO_RANGE_WANTED), limits.limits.maxUniformBufferRange))

	ok: bool
	if s.vertex_shader, ok = make_shader(s, VERTEX_SPV[:]); !ok {
		return false
	}
	if s.fragment_shaders[.Textured], ok = make_shader(s, FRAGMENT_TEXTURED_SPV[:]); !ok {
		return false
	}
	if s.fragment_shaders[.Coverage], ok = make_shader(s, FRAGMENT_COVERAGE_SPV[:]); !ok {
		return false
	}
	if s.fragment_shaders[.Sdf], ok = make_shader(s, FRAGMENT_SDF_SPV[:]); !ok {
		return false
	}
	s.fragment_shaders[.Solid] = s.fragment_shaders[.Textured]

	// the formats everything uses most are made now (the rest when first drawn into)
	for blend in ren.Blend {
		for material in ([?]ren.Material{.Textured, .Coverage, .Sdf}) {
			if _, made := get_pipeline(s, {format = RENDER_TARGET_FORMAT, material = material, blend = blend}); !made {
				return false
			}
		}
	}
	return true
}

@(private)
PUSH_RANGE := vk.PushConstantRange {
	stageFlags = {.VERTEX},
	offset     = 0,
	size       = PUSH_CONSTANTS_SIZE,
}

// The pipeline for a key, made now if it was not needed before.
get_pipeline :: proc(s: ^State, key: Pipeline_Key) -> (vk.Pipeline, bool) {
	key := key
	if key.shader == 0 && key.material == .Solid {
		key.material = .Textured // (Solid is Textured with the white texture)
	}
	if p, found := s.pipelines[key]; found {
		return p, true
	}
	fragment: vk.ShaderModule
	layout := s.pipeline_layout
	if key.shader == 0 {
		fragment = s.fragment_shaders[key.material]
	} else {
		slot := ren.pool_get(&s.shaders, key.shader)
		if slot == nil {
			return 0, false
		}
		fragment = slot.module
		layout = slot.pipeline_layout
	}
	made_at := time.tick_now()
	p, ok := make_pipeline(s, fragment, layout, key.blend, key.format)
	if !ok {
		return 0, false
	}
	log.debugf("ren_vulkan: made a pipeline (shader %d, material %v, blend %v, format %v) in %.1f ms", key.shader, key.material, key.blend, key.format, time.duration_milliseconds(time.tick_since(made_at)))
	s.pipelines[key] = p
	return p, true
}

// Makes the pipelines of the window's format now (so that the first frame does not stall on them).
warm_window_pipelines :: proc(s: ^State) {
	for blend in ren.Blend {
		for material in ([?]ren.Material{.Textured, .Coverage, .Sdf}) {
			get_pipeline(s, {format = s.format, material = material, blend = blend})
		}
	}
}

// Destroys every pipeline of a custom shader (it is being destroyed).
destroy_shader_pipelines :: proc(s: ^State, shader: u32) {
	for key, p in s.pipelines {
		if key.shader == shader {
			vk.DestroyPipeline(s.device, p, nil)
			delete_key(&s.pipelines, key)
		}
	}
}

destroy_pipelines :: proc(s: ^State) {
	for _, p in s.pipelines {
		vk.DestroyPipeline(s.device, p, nil)
	}
	delete(s.pipelines)
	s.pipelines = nil
}

@(private)
make_pipeline :: proc(s: ^State, fragment: vk.ShaderModule, layout: vk.PipelineLayout, blend: ren.Blend, format: vk.Format) -> (p: vk.Pipeline, ok: bool) {
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = s.vertex_shader, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fragment, pName = "main"},
	}

	// the one vertex format: ren.Vertex { pos [2]f32, uv [2]f32, color [4]u8 }
	binding := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = size_of(ren.Vertex),
		inputRate = .VERTEX,
	}
	attributes := [3]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(ren.Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(ren.Vertex, uv))},
		{location = 2, binding = 0, format = .R8G8B8A8_UNORM, offset = u32(offset_of(ren.Vertex, color))},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding,
		vertexAttributeDescriptionCount = u32(len(attributes)),
		pVertexAttributeDescriptions    = raw_data(attributes[:]),
	}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	viewport := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1, // both set when drawing
	}
	raster := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {}, // 2D: whatever way a triangle faces, it is drawn
		frontFace   = .COUNTER_CLOCKWISE,
		lineWidth   = 1,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}
	switch blend {
	case .Alpha:
		// colour: src * a + dst * (1 - a);  alpha: src.a + dst.a * (1 - src.a)
		attachment.blendEnable = true
		attachment.srcColorBlendFactor = .SRC_ALPHA
		attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
		attachment.colorBlendOp = .ADD
		attachment.srcAlphaBlendFactor = .ONE
		attachment.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA
		attachment.alphaBlendOp = .ADD
	case .Additive:
		// colour: dst + src * a;  alpha: unchanged
		attachment.blendEnable = true
		attachment.srcColorBlendFactor = .SRC_ALPHA
		attachment.dstColorBlendFactor = .ONE
		attachment.colorBlendOp = .ADD
		attachment.srcAlphaBlendFactor = .ZERO
		attachment.dstAlphaBlendFactor = .ONE
		attachment.alphaBlendOp = .ADD
	case .Premultiplied:
		// colour: src + dst * (1 - a);  alpha: src.a + dst.a * (1 - src.a)
		attachment.blendEnable = true
		attachment.srcColorBlendFactor = .ONE
		attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
		attachment.colorBlendOp = .ADD
		attachment.srcAlphaBlendFactor = .ONE
		attachment.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA
		attachment.alphaBlendOp = .ADD
	case .Modulate:
		// colour: dst * src;  alpha: unchanged
		attachment.blendEnable = true
		attachment.srcColorBlendFactor = .ZERO
		attachment.dstColorBlendFactor = .SRC_COLOR
		attachment.colorBlendOp = .ADD
		attachment.srcAlphaBlendFactor = .ZERO
		attachment.dstAlphaBlendFactor = .ONE
		attachment.alphaBlendOp = .ADD
	case .Opaque:
		attachment.blendEnable = false
	}
	color_blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &attachment,
	}

	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states[:]),
	}

	// dynamic rendering: the attachment's format is part of the pipeline, there is no render pass object
	format := format
	rendering := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &format,
	}

	info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering,
		stageCount          = u32(len(stages)),
		pStages             = raw_data(stages[:]),
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport,
		pRasterizationState = &raster,
		pMultisampleState   = &multisample,
		pColorBlendState    = &color_blend,
		pDynamicState       = &dynamic_info,
		layout              = layout,
	}
	if res := vk.CreateGraphicsPipelines(s.device, 0, 1, &info, nil, &p); res != .SUCCESS {
		log.errorf("ren_vulkan: creating a pipeline failed: %v", res)
		return 0, false
	}
	return p, true
}
