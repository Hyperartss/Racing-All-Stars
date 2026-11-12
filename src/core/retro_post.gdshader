shader_type canvas_item;
// Console framebuffer look: reduce each channel to `levels` steps (31 = 5-bit like
// the Saturn's RGB555 / Dreamcast's RGB565 green 63), with an optional 4x4 ordered
// dither before the cut, light scanlines and a saturation tweak.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform vec3 levels = vec3(31.0, 31.0, 31.0);
uniform float dither = 0.0;
uniform float scanlines = 0.0;
uniform float saturation = 1.0;

float bayer4(vec2 p) {
	int x = int(mod(p.x, 4.0));
	int y = int(mod(p.y, 4.0));
	int i = x + y * 4;
	float m[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
		3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	return m[i] / 16.0 - 0.5;
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(l), c, saturation);
	vec2 px = FRAGCOORD.xy;
	c += bayer4(px) * dither / levels;
	c = floor(clamp(c, 0.0, 1.0) * levels + 0.5) / levels;
	if (scanlines > 0.0 && mod(px.y, 2.0) >= 1.0) {
		c *= 1.0 - scanlines;
	}
	COLOR = vec4(c, 1.0);
}
