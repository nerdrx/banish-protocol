shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled,
		fog_disabled, specular_disabled;

// NULLVOID world-space prompt ring — the keycap and channel gauge that float at
// an interactable rather than in the middle of your screen.
//
// M3.8 moves interaction prompts out of the HUD and onto the object (DESIGN.md
// "diegetic program-shell UI"). This is the frame they are drawn in: a hairline
// keycap ring with corner brackets, and the channel arc that fills it while you
// hold E. The letter itself is a Label3D parented in front of this quad.
//
// Additive and depth-write-free, so several of these can overlap in a corridor
// without sorting artefacts, and so they read as projected light rather than as
// decals hanging in the air.

// Facing is handled by WorldPrompt, which turns the whole node — quad, keycap
// and title together — to face the lens each frame. Billboarding the quad here
// as well would be a no-op at best and would tear the group apart at worst.
uniform vec4 tint : source_color = vec4(0.36, 0.86, 1.0, 1.0);
uniform vec4 warn_tint : source_color = vec4(1.0, 0.62, 0.26, 1.0);
// 0..1 channel fill.
uniform float progress : hint_range(0.0, 1.0) = 0.0;
// Master fade — distance, view angle and the spawn-in ramp all multiply here.
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
// 1 while the prompt can actually be acted on; 0 tints it amber and drops the
// keycap ring, which is how "UPLINK LOCKED" reads different from "HOLD E".
uniform float ready : hint_range(0.0, 1.0) = 1.0;
// Idle breathing weight. Frozen by the caller during automated captures.
uniform float breathe : hint_range(0.0, 1.0) = 0.0;

const float RING_RADIUS = 0.30;

// Anti-aliased band around `radius`, `width` thick.
float ring(float d, float radius, float width) {
	float edge = fwidth(d) * 1.5 + 0.0008;
	return 1.0 - smoothstep(width, width + edge, abs(d - radius));
}

void fragment() {
	vec2 p = UV - vec2(0.5);
	float d = length(p);
	// atan gives -PI..PI; rotate so 0 is straight up and the arc fills clockwise,
	// which is the direction every other gauge in this game fills.
	float angle = fract((atan(p.x, -p.y) / 6.2831853) + 1.0);

	vec3 colour = mix(warn_tint.rgb, tint.rgb, ready);

	// --- keycap ring, always present ---------------------------------------
	float track = ring(d, RING_RADIUS, 0.006) * 0.30;

	// --- channel arc --------------------------------------------------------
	float arc = ring(d, RING_RADIUS, 0.016)
			* step(angle, max(progress, 0.0))
			* (0.55 + 0.45 * ready);

	// The head of the fill, so a channel in progress has a bright leading point
	// exactly like the Cycles ring does.
	float head = 0.0;
	if (progress > 0.001 && progress < 0.999) {
		float delta = abs(angle - progress);
		delta = min(delta, 1.0 - delta);
		head = ring(d, RING_RADIUS, 0.03) * (1.0 - smoothstep(0.0, 0.03, delta));
	}

	// --- corner brackets ----------------------------------------------------
	// Four L-shapes just outside the ring. They are what makes the thing read as
	// a targeting frame rather than as a progress donut.
	vec2 a = abs(p);
	float outer = 0.40;
	float arm = 0.13;
	float thickness = 0.010;
	float bracket =
			(1.0 - smoothstep(thickness, thickness + 0.006, abs(a.x - outer))) * step(a.y, arm)
			+ (1.0 - smoothstep(thickness, thickness + 0.006, abs(a.y - outer))) * step(a.x, arm);
	bracket = clamp(bracket, 0.0, 1.0) * (0.26 + 0.14 * breathe);

	// --- the plate the glyph sits on ----------------------------------------
	// A faint inner wash. Additive, so it lifts the letter off the wall behind
	// without ever becoming a solid badge.
	float plate = (1.0 - smoothstep(0.0, RING_RADIUS - 0.02, d)) * 0.055;

	float value = (track + arc + head * 0.9 + bracket + plate) * alpha;
	ALBEDO = colour * value * (2.2 + breathe * 0.4);
	ALPHA = clamp(value * 3.0, 0.0, 1.0);
}
