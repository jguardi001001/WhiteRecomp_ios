#version 450
// Reference GLSL for ui_textured.frag.spvasm: materials Solid (a 1x1 white texture is bound) and Textured.
layout(location = 0) in vec2 inUV;
layout(location = 1) in vec4 inColor;
layout(location = 0) out vec4 outColor;
layout(set = 0, binding = 0) uniform sampler2D tex;
void main() { outColor = inColor * texture(tex, inUV); }
