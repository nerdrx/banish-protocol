shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

// Muzzle heat distortion — a screen-space UV ripple on a billboard quad.
//
// The breaker is a cutter, not a gun: it puts enough energy into a surface to
// vaporise it, and the air in front of the emitter should shimmer. This is the
// cheapest cinematic upgrade in the whole filmic menu — one quad, one noise
// fetch, one screen fetch — and it does something none of the lighting work can
// do, which is make the air itself a visible participant.
//
// Deliberately colourless. A heat haze that tints is a flame; the breaker is
// not on fire, it is boiling a hole in a wall. All it does is bend what is
// behind it, and the darkness law is untouched because nothing is added.

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D ripple_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform float strength : hint_range(0.0, 0.12) = 0.020;
uniform float scale = 3.2;
uniform float speed = 1.9;
// Rises: hot air goes up, and a ripple that scrolls sideways reads as water.
uniform float rise = 2.4;
// Master, so the game can ramp it with breaker heat.
uniform float amount : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	// Soft round mask so the quad has no visible edge. This is the entire
	// difference between "heat haze" and "a rectangle of wobble".
	vec2 c = UV * 2.0 - 1.0;
	float mask = pow(clamp(1.0 - length(c), 0.0, 1.0), 1.6);
	if (mask < 0.002) {
		discard;
	}

	// Two counter-scrolling samples: a single scroll reads as a moving texture,
	// two beating against each other read as turbulence.
	vec2 uv0 = UV * scale + vec2(TIME * speed * 0.21, -TIME * speed * rise * 0.1);
	vec2 uv1 = UV * scale * 1.7 - vec2(TIME * speed * 0.13, TIME * speed * rise * 0.16);
	float nx = texture(ripple_noise, uv0).r - 0.5;
	float ny = texture(ripple_noise, uv1).r - 0.5;

	vec2 offset = vec2(nx, ny) * strength * mask * amount;
	ALBEDO = texture(screen_tex, clamp(SCREEN_UV + offset, vec2(0.001), vec2(0.999))).rgb;
	ALPHA = mask;
}
