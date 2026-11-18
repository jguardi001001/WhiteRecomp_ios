#version 330
// A separable Gaussian blur of 9 taps (5 fetches, using the linear filter between texels): draw it twice, once with `step_uv` along x and once along y.
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec2 step_uv; // the distance between taps in UV: (1 / width, 0) for a blur along x, (0, 1 / height) along y; bigger spreads it wider
out vec4 finalColor;
void main() {
	vec4 sum = texture(texture0, fragTexCoord) * 0.2270270270;
	sum += texture(texture0, fragTexCoord + step_uv * 1.3846153846) * 0.3162162162;
	sum += texture(texture0, fragTexCoord - step_uv * 1.3846153846) * 0.3162162162;
	sum += texture(texture0, fragTexCoord + step_uv * 3.2307692308) * 0.0702702703;
	sum += texture(texture0, fragTexCoord - step_uv * 3.2307692308) * 0.0702702703;
	finalColor = sum;
}
