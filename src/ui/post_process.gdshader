shader_type canvas_item;
render_mode unshaded;

// Full-screen grade sitting on top of the 3D pass: vignette, film grain and a
// touch of lateral chromatic aberration. Kept deliberately restrained — these
// effects are here to make the darkness feel photographed rather than rendered,
// not to be noticed on their own.
//
// M4 will drive `damage` / `suffocation` from gameplay to push grain, aberration
// and the vignette hard during low-Cycles and corrupted states.

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;

uniform float vignette_intensity : hint_range(0.0, 2.0) = 0.85;
uniform float vignette_inner : hint_range(0.0, 1.0) = 0.32;
uniform float vignette_outer : hint_range(0.0, 1.5) = 0.86;
uniform float grain_amount : hint_range(0.0, 0.2) = 0.028;
uniform float grain_shadow_bias : hint_range(0.0, 1.0) = 0.65;
uniform float aberration : hint_range(0.0, 0.02) = 0.0015;
uniform float stress : hint_range(0.0, 1.0) = 0.0;

float hash13(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 centered = uv - vec2(0.5);
	float dist = length(centered);

	// Aberration scales with the square of the radius: clean centre, smeared
	// corners, the way a cheap wide lens behaves.
	float ab = aberration * (1.0 + stress * 3.0);
	vec2 offset = centered * ab * (0.25 + dist * dist * 2.4);

	vec3 color;
	color.r = texture(screen_texture, uv + offset).r;
	color.g = texture(screen_texture, uv).g;
	color.b = texture(screen_texture, uv - offset).b;

	// Vignette.
	float vig = 1.0 - smoothstep(vignette_inner, vignette_outer, dist);
	float amount = vignette_intensity * (1.0 + stress * 0.8);
	color *= mix(clamp(1.0 - amount, 0.0, 1.0), 1.0, vig);

	// Grain, weighted toward the shadows where a sensor actually struggles.
	float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
	float noise = hash13(vec3(FRAGCOORD.xy, TIME * 60.0)) - 0.5;
	float weight = mix(1.0, 1.0 - clamp(luma, 0.0, 1.0), grain_shadow_bias);
	color += noise * grain_amount * (1.0 + stress * 2.0) * weight;

	COLOR = vec4(color, 1.0);
}
