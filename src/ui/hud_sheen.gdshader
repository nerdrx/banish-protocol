shader_type canvas_item;
render_mode unshaded, blend_add;

// NULLVOID HUD sheen — the thing that makes a corner cluster read as *projected
// light* rather than as a rectangle of text pasted onto the frame.
//
// Laid over a HUD cluster as a transparent ColorRect. Additive, and everything
// it adds is a few thousandths of a unit, because the readouts underneath have
// to stay legible in a game whose whole look is near-black.
//
// Three things, all in the rect's own UV space:
//   1. fine horizontal scanlines, drawn in *screen* pixels so they do not
//      stretch when a cluster is a different size;
//   2. a slow diagonal sweep, the reflection of something moving past the
//      projection plane;
//   3. a corner falloff plus a top-to-bottom brightness ramp, which is the
//      cheap read of perspective: a projected panel is brighter at the edge
//      nearest the projector.
//
// Cost: no texture fetches at all. This is arithmetic on a few hundred pixels
// per cluster.

uniform vec4 tint : source_color = vec4(0.36, 0.86, 1.0, 1.0);
uniform float sheen_strength : hint_range(0.0, 0.3) = 0.030;
uniform float scanline_strength : hint_range(0.0, 0.3) = 0.028;
// Scanline pitch in screen pixels.
uniform float scanline_pitch : hint_range(1.0, 12.0) = 3.0;
// Seconds per sweep pass. Long: this is peripheral vision furniture.
uniform float sweep_period : hint_range(1.0, 30.0) = 6.5;
uniform float sweep_width : hint_range(0.02, 1.0) = 0.16;
// Which way the projection falls off. 1 = brighter at the top edge.
uniform float perspective : hint_range(-1.0, 1.0) = 0.55;
// Where the edge mask starts biting, 0..1 of the way out from the centre. Low
// values give a soft oval with no findable edge, which is what a HUD cluster
// needs. High values keep the sheen flat across the rect right up to its border,
// which is what a framed console panel needs — there the panel's own border is
// the edge, and a sweep should cross it cleanly rather than dissolve short of it.
uniform float mask_start : hint_range(0.0, 0.98) = 0.25;
// Master, so a whole HUD can be dimmed by one gameplay state.
uniform float amount : hint_range(0.0, 2.0) = 1.0;
// Interface degradation, 0..1. Adds a rolling band of lost signal.
uniform float degrade : hint_range(0.0, 1.0) = 0.0;

float hash11(float p) {
	return fract(sin(p * 78.233) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;

	// --- scanlines, in screen pixels ---------------------------------------
	float scan = 0.5 + 0.5 * sin(FRAGCOORD.y * (6.2831853 / scanline_pitch));
	float lines = scan * scanline_strength;

	// --- diagonal sweep -----------------------------------------------------
	// A single band travelling across the cluster on a long period. `fract` of
	// the phase gives the gap between passes for free.
	float phase = fract(TIME / sweep_period);
	float along = (uv.x * 0.72 + uv.y * 0.28);
	float band = 1.0 - smoothstep(0.0, sweep_width, abs(along - (phase * 1.6 - 0.3)));
	float sweep = band * band * sheen_strength * 1.8;

	// --- perspective ramp + edge falloff ------------------------------------
	// The falloff starts almost at the centre. An earlier revision faded only
	// the outer fifth and the result was a visible glowing *rectangle* over each
	// cluster — the exact "game HUD panel" look this is meant to avoid. A sheen
	// has to have no findable edge, so the mask is nearly a radial gradient.
	float ramp = mix(1.0, 1.0 - uv.y, clamp(perspective, 0.0, 1.0))
			* mix(1.0, uv.y, clamp(-perspective, 0.0, 1.0));
	vec2 edge = abs(uv - vec2(0.5)) * 2.0;
	float inside = (1.0 - smoothstep(mask_start, 1.0, edge.x))
			* (1.0 - smoothstep(max(mask_start - 0.1, 0.0), 1.0, edge.y));

	// No constant term. Anything uniform across the rect is a box, and a box is
	// what we are not drawing.
	float value = (lines + sweep) * ramp * inside;

	// --- degradation: a rolling dropout band --------------------------------
	if (degrade > 0.001) {
		float row = floor(FRAGCOORD.y / 3.0);
		float roll = fract(TIME * 0.35);
		float dist = abs(fract(uv.y - roll) - 0.5);
		float dropout = step(0.46, dist) * step(1.0 - degrade * 0.8, hash11(row));
		value = value * (1.0 - dropout * 0.9) + dropout * degrade * 0.06;
	}

	// Alpha carries the value, and this is not cosmetic.
	//
	// Until M4.7 this wrote alpha 1.0, which is harmless when the additive blend
	// lands on an opaque backbuffer — the alpha channel of the screen is not
	// looked at. The interface now renders into a TRANSPARENT SubViewport (the
	// CRT tube), where `dst.a += 1.0` turns every sheen rect into a solid black
	// rectangle over the world. Writing the sheen's own value into alpha makes
	// the rect as transparent as it is dark, which is what it always meant.
	COLOR = vec4(tint.rgb * value * amount, clamp(value * amount, 0.0, 1.0));
}
