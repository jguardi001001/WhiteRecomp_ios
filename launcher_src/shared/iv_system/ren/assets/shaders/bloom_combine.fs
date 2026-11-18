#version 330
// Bloom, last step: the scene plus the blurred bright parts (two sizes of glow: a tight one and a wide one).
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0; // the scene
uniform sampler2D bloom0; // the tight glow (the first level)
uniform sampler2D bloom1; // the wide glow (the second level)
uniform float intensity0; // how much of each is added
uniform float intensity1;
uniform vec3 tint; // multiplies the glow (1, 1, 1 for the colours of the scene)
out vec4 finalColor;
void main() {
	vec4 s = texture(texture0, fragTexCoord);
	vec3 glow = (texture(bloom0, fragTexCoord).rgb * intensity0 + texture(bloom1, fragTexCoord).rgb * intensity1) * tint;
	finalColor = vec4(s.rgb + glow, s.a);
}
