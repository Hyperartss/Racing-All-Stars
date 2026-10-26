shader_type spatial;
// Generated connector road: cross-fades (dithered) from the road texture of the
// track it leaves to the road texture of the track it joins, along its length
// (vertex COLOR.r = 0 .. 1). A texture may be a tile inside an atlas: rect = (u, v,
// w, h) in Godot UV space; w = 0 means "use the whole texture, repeating".
render_mode vertex_lighting, cull_disabled, specular_disabled;

uniform sampler2D tex_a : source_color, filter_nearest, repeat_enable;
uniform sampler2D tex_b : source_color, filter_nearest, repeat_enable;
uniform vec4 rect_a = vec4(0.0);
uniform vec4 rect_b = vec4(0.0);

vec3 sample_road(sampler2D t, vec4 r, vec2 uv) {
	if (r.z <= 0.0) {
		return texture(t, uv).rgb;
	}
	vec2 tuv = fract(uv * vec2(0.5, 0.6));
	return texture(t, r.xy + tuv * r.zw).rgb;
}

void fragment() {
	vec3 a = sample_road(tex_a, rect_a, UV);
	vec3 b = sample_road(tex_b, rect_b, UV);
	float d = fract(sin(dot(floor(FRAGCOORD.xy), vec2(12.9898, 78.233))) * 43758.5453);
	ALBEDO = mix(a, b, step(d, COLOR.r));
}
