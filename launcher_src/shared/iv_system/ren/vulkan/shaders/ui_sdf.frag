#version 450
// Reference GLSL for ui_sdf.frag.spvasm: material Sdf (an R8 signed distance field, 0.5 at the edge).
layout(location = 0) in vec2 inUV;
layout(location = 1) in vec4 inColor;
layout(location = 0) out vec4 outColor;
layout(set = 0, binding = 0) uniform sampler2D tex;
void main() {
    float d = texture(tex, inUV).r;
    float w = max(fwidth(d), 0.0001);
    outColor = vec4(inColor.rgb, inColor.a * smoothstep(0.5 - w, 0.5 + w, d));
}
