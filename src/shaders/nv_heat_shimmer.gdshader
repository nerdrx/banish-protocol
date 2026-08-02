shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, depth_test_disabled;

// The Sentinel's purge arc, as a distortion rather than as a picture of one.
//
// A quarantine process discharging enough energy to delete a program is not
// something you draw a sprite of — it is something the air in front of it stops
// being transparent about. This refracts whatever is behind it: the wall, the
// crewmate standing in the wrong place, the player's own beam.
//
// Two reasons that is the right call for NULLVOID specifically:
//
//   * the swing has to read in a room that is almost entirely dark. An additive
//     flash reads as "a light came on"; a refraction reads as "something is
//     happening to the space", which is legible whether the room is lit or not.
//   * it cannot be mistaken for anything else on screen. Every other effect in
//     the game is emissive. This one is the only thing that bends.
//
// The arc is a QuadMesh laid flat in front of the creature and driven by
// `sweep`, which runs 0 -> 1 over the length of one swing. The distortion is a
// travelling band rather than a uniform wobble: energy leaves the emitter and
// crosses the arc, so the far edge is still calm while the near edge is already
// boiling.
//
// Cost: one screen fetch on a quad that is only ever alive for a fraction of a
// second, on at most one creature per room.

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;

// 0 -> 1 across one swing. At 0 and 1 the shader outputs nothing at all.
uniform float sweep : hint_range(0.0, 1.0) = 0.0;
// Peak refraction, in screen UV. Small: this is hot air, not a heat haze filter.
uniform float strength : hint_range(0.0, 0.08) = 0.017;
// How wide the travelling band is, as a fraction of the arc.
uniform float band : hint_range(0.05, 1.0) = 0.42;
// A whisper of the hostile colour rides the distortion, so the arc is not purely
// a refraction on a near-black wall (where there would be nothing to refract).
uniform vec3 tint : source_color = vec3(1.0, 0.16, 0.14);
uniform float tint_amount : hint_range(0.0, 1.0) = 0.14;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(41.13, 289.7))) * 43758.5453);
}

// Cheap value noise. Three octaves is enough for air; more just costs.
float turbulence(vec2 p) {
	float total = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 3; i++) {
		vec2 cell = floor(p);
		vec2 frac = smoothstep(0.0, 1.0, fract(p));
		float a = hash21(cell);
		float b = hash21(cell + vec2(1.0, 0.0));
		float c = hash21(cell + vec2(0.0, 1.0));
		float d = hash21(cell + vec2(1.0, 1.0));
		total += amplitude * mix(mix(a, b, frac.x), mix(c, d, frac.x), frac.y);
		p *= 2.03;
		amplitude *= 0.5;
	}
	return total;
}

void fragment() {
	// The travelling band. `sweep` carries its centre from one edge of the arc to
	// the other; outside it the quad is perfectly clear.
	float along = UV.x;
	float centre = mix(-band, 1.0 + band, sweep);
	float wave = 1.0 - smoothstep(0.0, band, abs(along - centre));
	// And a soft edge across the arc's width, so it does not end in a hard line.
	wave *= smoothstep(0.0, 0.22, UV.y) * smoothstep(1.0, 0.72, UV.y);
	// Fades in and out over the whole swing as well, so the first and last frames
	// are never a distortion appearing from nowhere.
	wave *= sin(clamp(sweep, 0.0, 1.0) * 3.14159);

	vec2 noise_uv = UV * vec2(7.0, 3.0) + vec2(TIME * 1.7, TIME * 0.9);
	vec2 offset = vec2(
			turbulence(noise_uv) - 0.5,
			turbulence(noise_uv + 31.7) - 0.5) * strength * wave;

	vec2 uv = clamp(SCREEN_UV + offset, vec2(0.0), vec2(1.0));
	vec3 behind = texture(screen_texture, uv).rgb;

	ALBEDO = mix(behind, behind + tint, tint_amount * wave);
	ALPHA = clamp(wave * 1.6, 0.0, 1.0);
}
