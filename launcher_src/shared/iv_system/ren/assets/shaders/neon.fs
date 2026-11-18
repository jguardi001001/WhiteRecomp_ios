#version 330
// A neon sign look for lines (vector graphics, rectangle outlines, wireframes): draw the lines into a render target that has been cleared to transparent
// (or black), then draw this over it. Every line gets a hot, whitened core and two halos of its own colour (a tight bright one and a wide soft one), and
// the halos can flicker. The result is premultiplied (draw it with Blend.Premultiplied over the picture, or Opaque over black).
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0; // the lines: their colour (premultiplied by their alpha, which is what drawing into a cleared target leaves)
uniform vec2 texel; // 1 / the size of the texture in px
uniform float radius; // how far the wide halo reaches, in px (the tight one is a quarter of it)
uniform float tight_gain; // how bright the tight halo is, e.g. 1.2
uniform float wide_gain; // how bright the wide halo is, e.g. 0.8
uniform float core; // how white the lines themselves go, 0 (their own colour) to 1 (white in the middle)
uniform float saturation; // > 1 makes the halos more vivid than the lines (neon tubes glow in a stronger colour than they look)
uniform float flicker; // multiplies the halos: 1 steady; the program varies it (a hum, a failing tube)
out vec4 finalColor;
const int RINGS = 8;
const int TAPS = 12;
void main() {
	vec4 c = texture(texture0, fragTexCoord);
	float sigma_wide = max(radius * 0.5, 0.5);
	float sigma_tight = max(radius * 0.125, 0.5);
	float reach = radius * 1.5; // (out to three sigmas of the wide halo)
	// Gaussian blurs of the lines, two sizes at once. The taps are on rings (close together near the middle, where the tight halo lives), each tap weighs the
	// gaussian at its distance times the area it stands for, and the sums are divided by the weights.
	float cell = reach / float(RINGS * RINGS); // (the first ring)
	vec3 tight = c.rgb * (0.7854 * cell * cell);
	vec3 wide = tight;
	float wt_tight = 0.7854 * cell * cell;
	float wt_wide = wt_tight;
	float prev = 0.0;
	for (int i = 1; i <= RINGS; i++) {
		float f = float(i) / float(RINGS);
		float d = reach * f * f; // (quadratic spacing)
		float ring = d - prev;
		prev = d;
		float area = 6.2831853 * d * ring / float(TAPS);
		float w1 = exp(-(d * d) / (2.0 * sigma_tight * sigma_tight)) * area;
		float w2 = exp(-(d * d) / (2.0 * sigma_wide * sigma_wide)) * area;
		float a0 = float(i) * 2.399963; // (every ring turned by the golden angle: no spokes)
		for (int k = 0; k < TAPS; k++) {
			float a = a0 + 6.2831853 * float(k) / float(TAPS);
			vec3 s = texture(texture0, fragTexCoord + vec2(cos(a), sin(a)) * d * texel).rgb;
			tight += s * w1;
			wide += s * w2;
			wt_tight += w1;
			wt_wide += w2;
		}
	}
	// (scaled so that a line one px wide has a halo as bright as itself, times the gain, whatever the radius: the blur alone would make it faint)
	tight = tight / wt_tight * (2.5066 * sigma_tight);
	wide = wide / wt_wide * (2.5066 * sigma_wide);
	float lt = dot(tight, vec3(0.299, 0.587, 0.114));
	float lw = dot(wide, vec3(0.299, 0.587, 0.114));
	tight = mix(vec3(lt), tight, saturation);
	wide = mix(vec3(lw), wide, saturation);
	vec3 halo = (tight * tight_gain + wide * wide_gain) * flicker;
	float lum = max(c.r, max(c.g, c.b));
	vec3 hot = mix(c.rgb, vec3(lum), core); // (the line's own colour pulled to white by how bright it is)
	vec3 rgb = hot + halo;
	float a = clamp(max(max(rgb.r, rgb.g), max(rgb.b, c.a)), 0.0, 1.0);
	finalColor = vec4(min(rgb, vec3(a)), a);
}
