shader_type spatial;
// Generated connector road: cross-fades from Mario Raceway asphalt to Resort Island's
// plank/sand road along its length (vertex COLOR.r = 0 asphalt .. 1 island).
render_mode vertex_lighting, cull_disabled, specular_disabled;

uniform sampler2D tex_a : source_color, filter_nearest, repeat_enable;
uniform sampler2D tex_b : source_color, filter_nearest, repeat_enable;
// Island road tile inside its atlas: (u, v, w, h) in Godot UV space.
uniform vec4 rect_b = vec4(0.0, 0.5, 0.25, 0.25);

void fragment() {
	vec3 a = texture(tex_a, UV).rgb;
	vec2 tuv = fract(UV * vec2(0.5, 0.6));
	vec3 b = texture(tex_b, rect_b.xy + tuv * rect_b.zw).rgb;
	// N64-style dithered blend instead of a smooth fade.
	float d = fract(sin(dot(floor(FRAGCOORD.xy), vec2(12.9898, 78.233))) * 43758.5453);
	float w = step(d, COLOR.r);
	ALBEDO = mix(a, b, w);
}
