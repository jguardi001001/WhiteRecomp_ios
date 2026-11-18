#version 450
// Reference GLSL for ui.vert.spvasm (the SPIR-V is what the backend loads).
layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;
layout(location = 0) out vec2 outUV;
layout(location = 1) out vec4 outColor;
layout(push_constant) uniform PC { vec2 scale; vec2 offset; } pc;
void main() {
    gl_Position = vec4(inPos * pc.scale + pc.offset, 0.0, 1.0);
    outUV = inUV;
    outColor = inColor;
}
