shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled,
		fog_disabled, specular_disabled;

// NULLVOID — M12 SENSATION. The breaker's lash, at any range.
//
// WHY THIS SHADER EXISTS
//
// The lash used to be a box of constant WORLD thickness (0.045 m), which is a
// perfectly good way to draw a beam that is always about eight metres long. M12
// takes the cutter out to thirty, and constant world thickness at thirty metres
// is a hairline: the far half of the streak subtends almost no pixels, so the
// shot reads as a bright muzzle and a bright impact with nothing joining them.
// The user's report was that the weapon felt clunky at range; a beam you cannot
// see the middle of is a large part of that.
//
// Scaling the whole box up instead would make a point-blank shot enormous —
// which is the exact complaint PT1 already made ("the laser beam is wayyyy too
// thick") and which the 0.045 constant was walked back to fix. Both ends have to
// be right at once, and that is a per-vertex problem, not a constant.
//
// THE FIX: constant APPARENT width.
//
// Each vertex's thickness is scaled by that vertex's own distance from the eye,
// so every part of the streak subtends the same angle no matter how far down the
// beam it is. Near the muzzle the box is three millimetres across; thirty metres
// out it is seventeen centimetres; on screen they are the same width, and the
// beam reads as one continuous line at every range. `WIDTH_PER_METRE` is the
// half-angle in radians — the number that IS the on-screen thickness — and it is
// set to reproduce exactly what 0.045 m looked like at the old eight-metre
// range, so nothing about a close shot changed.
//
// The vertex's own Z carries its position along the beam, because the mesh is a
// BoxMesh built along +Z and re-sized per shot. Taking the axis point
// (0, 0, VERTEX.z) through MODELVIEW gives that point's view-space depth without
// the offset contaminating it — offsetting first and measuring after would make
// the beam's thickness depend on its own thickness.

uniform vec4 beam_colour : source_color = vec4(0.72, 0.96, 1.0, 1.0);
/// Driven per frame by Breaker._process as the streak fades out.
uniform float fade : hint_range(0.0, 1.0) = 1.0;
/// Radians of half-thickness per metre of depth. 0.0056 reproduces the M4.95/PT1
/// look (0.045 m at 8 m) at every range rather than at one range.
uniform float width_per_metre : hint_range(0.0, 0.05) = 0.0056;
/// A floor so the muzzle end never collapses to a degenerate quad, and a ceiling
/// so an absurd draw distance cannot produce a slab.
uniform float width_min : hint_range(0.0, 0.05) = 0.002;
uniform float width_max : hint_range(0.0, 1.0) = 0.20;

void vertex() {
	// Depth of THIS vertex's point on the beam axis, in view space. Godot's view
	// space looks down -Z, so the positive depth is the negated Z.
	vec4 axis_view = MODELVIEW_MATRIX * vec4(0.0, 0.0, VERTEX.z, 1.0);
	float depth = max(-axis_view.z, 0.05);
	float w = clamp(depth * width_per_metre, width_min, width_max);
	// The BoxMesh is authored 1 x 1 on its cross-section, so VERTEX.xy is +/-0.5
	// and multiplying by `w` makes the section exactly `w` across.
	VERTEX.xy *= w;
}

void fragment() {
	ALBEDO = beam_colour.rgb;
	ALPHA = beam_colour.a * fade;
}

// NO CROSS-SECTION FALLOFF, AND THIS IS A CORRECTION RATHER THAN A CHOICE.
//
// The first version of this shader carried `varying float v_across`, set to
// `length(VERTEX.xy) * 2.0` in the vertex stage, and used it to fade the beam's
// edges with a smoothstep. It rendered NOTHING, and it took a capture pipeline
// and several wasted photographs to notice why: a BoxMesh has eight corner
// vertices and no others, so every single vertex sits at |x| = |y| = 0.5 and the
// varying is the constant 1.414 across the entire surface. `smoothstep(0.65,
// 1.05, 1.414)` is 1.0, so the alpha was exactly zero at every fragment. A
// perfectly working beam, drawn perfectly transparently.
//
// The lesson is general: an interpolated varying can only vary if the mesh has
// vertices for it to vary BETWEEN. A radial falloff needs geometry with interior
// vertices (or a UV), and a box has neither in the direction that mattered.
//
// The falloff is not re-added via UV because it turns out not to be wanted: the
// streak is between three and seventeen centimetres across and is drawn
// additively over near-black, so its edges are already soft in the composite,
// and the glow pass rounds them further. A hard-edged primitive is the right
// amount of geometry for this effect.
