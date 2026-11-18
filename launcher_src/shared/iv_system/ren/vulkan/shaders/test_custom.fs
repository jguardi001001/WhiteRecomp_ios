#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;
uniform sampler2D tex_a; // the texels that are scaled
uniform sampler2D tex_b; // a second texture, a single texel
uniform vec4 tint;
uniform float k[3];
uniform int mode;
// Test shader for the custom shader support of the Vulkan backend (see custom_test.odin):
//   mode 0: r = tex_a.r * tint.r * k[2];  g, b = the pixel's column and row (from the top);  a = 1
//   mode 1: the colour of tex_b's texel, times fragColor
//   mode 2: a constant that does not fit in 8 bits (for the float targets)
void main() {
	if (mode == 1) {
		finalColor = texelFetch(tex_b, ivec2(0, 0), 0) * fragColor;
	} else if (mode == 2) {
		finalColor = vec4(1.5, -2.0, 0.25, 8.0);
	} else {
		finalColor = vec4(texture(tex_a, fragTexCoord).r * tint.r * k[2], floor(gl_FragCoord.x) / 255.0, floor(gl_FragCoord.y) / 255.0, 1.0);
	}
}
