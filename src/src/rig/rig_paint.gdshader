shader_type spatial;
// Material for vertex-animated rigs: nearest-filtered texture, per-vertex light,
// alpha cut-out, and a "paint" colour swap (Sonic R-style alternate colours).
// Pixels whose hue is close to `src` are recoloured to `target`, keeping their
// shading (saturation/value scaled by target/src). `tint` multiplies everything.
render_mode vertex_lighting, cull_disabled, specular_disabled;

uniform sampler2D tex : source_color, filter_nearest, repeat_enable;
uniform bool use_alpha = false;
// Up to 4 independent colour swaps (e.g. fur + shoes on one texture).
uniform int swap_count = 0;
uniform vec3 src_hsv[4];
uniform vec3 dst_hsv[4];
uniform float hue_tol[4];
uniform float sat_min = 0.35;
uniform vec4 tint : source_color = vec4(1.0);

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	vec4 t = texture(tex, UV);
	vec3 col = t.rgb;
	vec3 h = rgb2hsv(col);
	for (int i = 0; i < swap_count; i++) {
		float dh = abs(h.x - src_hsv[i].x);
		dh = min(dh, 1.0 - dh);
		if (dh < hue_tol[i] && h.y > sat_min) {
			float s = clamp(h.y * dst_hsv[i].y / max(src_hsv[i].y, 0.01), 0.0, 1.0);
			float v = clamp(h.z * dst_hsv[i].z / max(src_hsv[i].z, 0.01), 0.0, 1.0);
			col = hsv2rgb(vec3(dst_hsv[i].x, s, v));
			break;
		}
	}
	ALBEDO = col * tint.rgb;
	ALPHA = use_alpha ? t.a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
