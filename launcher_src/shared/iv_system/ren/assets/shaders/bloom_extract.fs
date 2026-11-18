#version 330
// Bloom, step 1: keeps what is brighter than `threshold` (a soft edge `knee` wide, so that a pixel does not pop in and out as it crosses it).
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0; // the scene
uniform float threshold; // the brightness (the largest of r, g, b) from which a pixel glows, e.g. 0.7
uniform float knee; // the width of the soft edge, e.g. 0.2
out vec4 finalColor;
void main() {
	vec4 c = texture(texture0, fragTexCoord);
	float l = max(c.r, max(c.g, c.b));
	float soft = clamp(l - threshold + knee, 0.0, 2.0 * knee);
	soft = soft * soft / (4.0 * knee + 1e-5);
	float w = max(soft, l - threshold) / max(l, 1e-5);
	finalColor = vec4(c.rgb * max(w, 0.0), 1.0);
}
