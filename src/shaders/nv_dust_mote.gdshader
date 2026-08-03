shader_type spatial;

// BANISH PROTOCOL — a suspended dust grain.
//
// THE ONE THING THIS SHADER EXISTS TO DO
// "as if the air was dusty" (user request). A dust mote is not a light source
// and it is not a sprite: it is a speck of matter that is INVISIBLE until
// something illuminates it, and then it is exactly as bright as the light that
// found it. Every other way of doing this fails in the same direction:
//
//   * an UNSHADED additive quad (what GodRays.add_motes uses inside a shaft, and
//     correctly, because inside a shaft there is by definition light) is a
//     constant brightness. Scattered through a whole layer it becomes a field of
//     glowing specks floating in the dark, which in a game whose entire premise
//     is "the dark is the enemy" is a floodlight made of confetti;
//   * a NORMALLY LIT billboard is worse. Billboarding turns the quad to face the
//     camera, so its normal faces the camera too, so a beam raking in from the
//     side produces N·L ~= 0 and the mote stays black in the middle of a light
//     shaft. The one case that has to work is the one that breaks.
//
// So the lighting is written by hand, and it is written the way scattering
// actually behaves: a grain that small has no meaningful normal, it re-radiates
// what reaches it in every direction. `light()` accumulates ATTENUATION —
// which carries the spot cone, the distance falloff, the projector mask AND the
// shadow map — with only a whisper of directionality. The consequences fall out
// for free and they are the whole point:
//
//   the player's beam finds motes; god-ray shafts are full of them; a gobo's
//   slat shadows CARVE them, because the shadow term is in ATTENUATION; a
//   practical under a cowl lights the handful of grains right beside it; and a
//   dark corridor with no light in it has no visible dust at all.
//
// DARKNESS-LAW GUARDS, both load-bearing:
//   `ambient_light_disabled` — ambient is a flat lift, and a flat lift applied
//   to a few hundred camera-following quads is a grey scrim over the frame. A
//   mote in an unlit room must be exactly as black as the room.
//   `SCATTER` is small and the result is CLAMPED below the environment's glow
//   threshold (1.65). A blooming mote is a lens flare, and there are hundreds.
//
// No time-varying term appears anywhere in here. The motes drift because the
// particle system moves them; nothing pulses, and nothing flashes (pillar 7).

// NOTE the absence of `shadows_disabled`. Shadow reception is the expensive part
// of this shader and it is also the reason it is worth having: without it
// ATTENUATION loses the shadow term, and a gobo's slats stop cutting the motes —
// the beam would fill with an even haze instead of striping it. Striped dust is
// the shot. The per-instance meshes still never CAST (see DustAir).
render_mode blend_add, depth_draw_never, cull_disabled, ambient_light_disabled,
		specular_disabled;

// How much of the light that reaches a grain comes back out toward the camera.
// Small on purpose: this is a scattering coefficient, not a brightness dial, and
// the thing it is scaling is a light_energy in the 2-9 range.
uniform float scatter : hint_range(0.0, 2.0) = 0.62;
// THE CONE BOOST, and it is a deliberate cheat with a real justification.
//
// Physically, a grain scatters in proportion to the light that reaches it, and
// `ATTENUATION` already is that. Shipped that way the motes were technically
// correct and, in the frame, invisible: a beam crossing six metres of air read
// as empty, because the handful of grains actually inside the cone were only a
// little brighter than the ones outside it and the eye needs a much bigger step
// than that to register "the air is full of something".
//
// So the response to attenuation is made SUPERLINEAR. A grain deep inside a
// beam's core gets `att + boost * att^3`, a grain at the cone edge gets almost
// nothing extra, and a grain in the dark still gets exactly zero — which is the
// property that matters, because it is what keeps an unlit room unlit. The
// effect is that light does not merely reveal the dust, it PICKS OUT the shaft,
// which is what the reference frames look like and what every film crew with a
// hazer is doing on purpose.
uniform float cone_boost : hint_range(0.0, 8.0) = 5.0;
// Isotropic vs. facing. 1.0 is a pure sphere (correct for dust, and the reason
// side-lighting works); a little less than 1 keeps a faint sense that the near
// face of a grain is the lit one, which reads as texture rather than as noise.
uniform float isotropy : hint_range(0.0, 1.0) = 0.82;
// The ceiling. Below the glow HDR threshold in layer_environment.tres so a mote
// crossing a hero shaft brightens and never blooms.
uniform float cap : hint_range(0.0, 4.0) = 1.45;
// Grain tint. Dust in this world is machine dust: dark grey, very slightly warm,
// so it separates from the cold architecture it is floating in.
uniform vec3 tint : source_color = vec3(0.86, 0.83, 0.78);
// Master density/visibility, driven by the PHOTONICS dust row. Ramped in
// GDScript over ~1.5 s, never stepped — see DustAir.
uniform float opacity : hint_range(0.0, 1.0) = 1.0;


void vertex() {
	// Billboard by hand rather than through BILLBOARD_ENABLED, because the
	// particle system already owns the transform and the built-in mode fights
	// the emitter's own rotation. Column-swap on the model-view matrix is the
	// standard construction: keep the translation, replace the basis with the
	// camera's.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2],
			MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
}


void fragment() {
	// A round, soft-edged grain out of a square quad. A hard-edged square at
	// 1-3 cm is invisible as a square and visible as ALIASING, which crawls when
	// the camera moves and is the exact artefact that makes cheap particles read
	// as cheap.
	vec2 d = UV * 2.0 - 1.0;
	float grain = 1.0 - smoothstep(0.35, 1.0, length(d));
	if (grain <= 0.001) {
		discard;
	}
	// COLOR is the particle's own vertex colour: the process material's alpha
	// curve rides it, so a mote fades in at birth and out at death instead of
	// popping. That fade is the only animation on a mote and it is far slower
	// than 3 Hz.
	ALBEDO = vec3(0.0);
	ALPHA = grain * COLOR.a * opacity;
}


void light() {
	// Isotropic scattering. NOT a Lambert term: see the header. `ATTENUATION`
	// is doing all the interesting work — cone, falloff, projector mask, shadow.
	float facing = max(dot(NORMAL, LIGHT), 0.0);
	float att = ATTENUATION;
	// Superlinear in the cone core; identically zero where no light lands.
	float response = att + cone_boost * att * att * att;
	float k = mix(facing, 1.0, isotropy) * response * scatter;
	DIFFUSE_LIGHT += min(LIGHT_COLOR * k, vec3(cap)) * tint;
}
