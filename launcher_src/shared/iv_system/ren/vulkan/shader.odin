package ren_vulkan

import "core:log"
import vk "vendor:vulkan"
import ren ".."

// ---------------------------------------------------------------------------
// Custom fragment shaders (ren.Shader_Desc). ren's vertex shader and vertex format are used with them, so the shader sees
// fragTexCoord and fragColor; its own inputs are one uniform block (set 0, binding 0: a dynamic uniform buffer, the bytes
// of draw_shader's `uniforms`, scalar layout) and the sampler2Ds (set 1, bindings 0 .. n - 1). The uniforms of every command
// of a frame live in one buffer, at the offsets the draw list made (aligned to ren.UNIFORM_ALIGN).
// ---------------------------------------------------------------------------

backend_create_shader :: proc(b: ^ren.Backend, desc: ren.Shader_Desc) -> (ren.Shader, bool) {
	s := (^State)(b.data)
	if s.lost || len(desc.spirv) == 0 {
		return 0, false
	}
	if desc.sampler_count < 0 || desc.sampler_count > ren.MAX_SHADER_TEXTURES {
		log.warnf("ren_vulkan: a shader may sample 0 .. %d textures, not %d", ren.MAX_SHADER_TEXTURES, desc.sampler_count)
		return 0, false
	}
	if desc.uniform_size < 0 || vk.DeviceSize(desc.uniform_size) > s.ubo_range {
		log.warnf("ren_vulkan: a shader's uniforms may be %d bytes at most, not %d", s.ubo_range, desc.uniform_size)
		return 0, false
	}
	if desc.uniform_size > 0 && !s.scalar_layout {
		log.warn("ren_vulkan: this device cannot do scalar uniform block layouts (scalarBlockLayout)")
		return 0, false
	}

	slot := Shader_Slot {
		uniform_size  = desc.uniform_size,
		sampler_count = desc.sampler_count,
	}
	failed := true
	defer if failed {
		free_shader_slot(s, &slot)
	}

	module_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(desc.spirv) * size_of(u32),
		pCode    = raw_data(desc.spirv),
	}
	if res := vk.CreateShaderModule(s.device, &module_info, nil, &slot.module); res != .SUCCESS {
		log.warnf("ren_vulkan: a custom shader was refused: %v", res)
		return 0, false
	}

	bindings: [ren.MAX_SHADER_TEXTURES]vk.DescriptorSetLayoutBinding
	for i in 0 ..< desc.sampler_count {
		bindings[i] = {
			binding         = u32(i),
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags      = {.FRAGMENT},
		}
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(desc.sampler_count),
		pBindings    = raw_data(bindings[:]),
	}
	if vk.CreateDescriptorSetLayout(s.device, &layout_info, nil, &slot.set_layout) != .SUCCESS {
		return 0, false
	}
	set_layouts := [2]vk.DescriptorSetLayout{s.ubo_set_layout, slot.set_layout}
	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 2,
		pSetLayouts            = raw_data(set_layouts[:]),
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &PUSH_RANGE,
	}
	if vk.CreatePipelineLayout(s.device, &pipeline_layout_info, nil, &slot.pipeline_layout) != .SUCCESS {
		return 0, false
	}

	handle := ren.pool_add(&s.shaders, slot)
	if handle == 0 {
		return 0, false
	}
	failed = false
	return ren.Shader(handle), true
}

@(private = "file")
free_shader_slot :: proc(s: ^State, slot: ^Shader_Slot) {
	if slot.pipeline_layout != 0 {
		vk.DestroyPipelineLayout(s.device, slot.pipeline_layout, nil)
	}
	if slot.set_layout != 0 {
		vk.DestroyDescriptorSetLayout(s.device, slot.set_layout, nil)
	}
	if slot.module != 0 {
		vk.DestroyShaderModule(s.device, slot.module, nil)
	}
	slot^ = {}
}

backend_destroy_shader :: proc(b: ^ren.Backend, shader: ren.Shader) {
	s := (^State)(b.data)
	slot := ren.pool_get(&s.shaders, u32(shader))
	if slot == nil {
		return
	}
	vk.DeviceWaitIdle(s.device) // frames in flight may still use its pipelines
	destroy_shader_pipelines(s, u32(shader))
	free_shader_slot(s, slot)
	ren.pool_remove(&s.shaders, u32(shader))
}
