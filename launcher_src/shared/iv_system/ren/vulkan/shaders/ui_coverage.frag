#version 450
// Reference GLSL for ui_coverage.frag.spvasm: material Coverage (an R8 texture is the alpha).
layout(location = 0) in vec2 inUV;
layout(location = 1) in vec4 inColor;
layout(location = 0) out vec4 outColor;
layout(set = 0, binding = 0) uniform sampler2D tex;
void main() { outColor = vec4(inColor.rgb, inColor.a * texture(tex, inUV).r); }
