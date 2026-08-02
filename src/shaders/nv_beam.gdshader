shader_type spatial;
render_mode blend_add, depth_draw_never, cull_front, unshaded, shadows_disabled;

// LIMBO PROTOCOL — the decryption beam, as geometry.
//
// The shipping beam is a SpotLight3D plus volumetric fog, and that is genuinely
// the right renderer-side answer: the fog scatters the light, so the shaft is
// physically derived and it interacts correctly with everything it passes. What
// it cannot do is have STRUCTURE. Volumetric fog gives an even cone with a gobo
// pattern projected through it; every torch in the game therefore looks like
// every other torch, and the beam has no near-field density, no dust motes
// swirling in the first metre, no falloff you can art-direct.
//
// So this cone mesh sits INSIDE the light, adds a little, and does the three
// things fog cannot:
//
//   * scrolling volumetric noise along the cone axis, so the shaft breathes
//   * a soft-particle fade against the depth buffer, so the cone does not cut a
//     hard ellipse into the floor where it intersects — the single most common
//     tell of a fake light shaft, and the reason `cull_front` is on: we draw
//     the BACK faces so the near cap never clips through the camera
//   * an artist-controlled radial and longitudinal profile
//
// It is additive and unshaded, so it is nearly free, and it must stay SUBTLE.
// A beam mesh you can see the polygons of is worse than no beam mesh. If in
// doubt, halve `energy` — the SpotLight is still doing the real work.
//
// ## Authoring frame (M4.95)
//
// The port was written for a cone authored along -Z, apex at origin, unit
// length. The shipping BeamCone (player.tscn) is instead a Godot CylinderMesh
// **frustum along its local +Y**: the NARROW near cap sits at -cone_half_height
// (the emitter end) and the WIDE far cap at +cone_half_height (down the throw).
// Rather than re-author the mesh in the scene — which would have to reconcile
// with the Optics tier-scaling in Player.apply_modules — the axis and the radial
// normalisation are expressed in that frame, driven by uniforms that describe the
// mesh. Everything below works in MODEL space (VERTEX in vertex() is pre-scale),
// so the node scale the tier-scaling applies is invisible to the profile: a
// wider/longer beam scales the geometry and the shader still fades cleanly at the
// rim and along the throw. Only these three uniforms change if the mesh does.

uniform vec3 beam_color : source_color = vec3(0.62, 0.82, 1.0);
uniform float energy : hint_range(0.0, 4.0) = 0.55;
// Radial profile: how hard the cone edge falls off. High = a tight core.
uniform float edge_power : hint_range(0.5, 8.0) = 2.6;
// Longitudinal profile: fade in over the first metre (so there is no disc at
// the lens) and out toward the end of the throw.
uniform float near_fade : hint_range(0.0, 1.0) = 0.10;
uniform float far_fade : hint_range(0.0, 1.0) = 0.55;

uniform sampler2D dust_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float noise_scale = 1.7;
uniform float noise_speed = 0.55;
uniform float noise_amount : hint_range(0.0, 1.0) = 0.55;
// Soft-particle distance in metres. Below this the beam fades against whatever
// it is intersecting.
uniform float soft_distance : hint_range(0.01, 2.0) = 0.55;

// --- mesh authoring, in model space ------------------------------------------
// Half the CylinderMesh height: the near cap is at y = -cone_half_height, the
// far cap at +cone_half_height.
uniform float cone_half_height = 4.5;
// Cap radii, so the radial coordinate can be normalised along the taper and the
// profile does not stretch. near = the CylinderMesh bottom_radius (emitter end),
// far = its top_radius.
uniform float cone_near_radius = 0.045;
uniform float cone_far_radius = 1.55;

uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

varying vec3 v_local;
varying float v_axis;   // 0 at the near (narrow) cap, 1 at the far (wide) cap

void vertex() {
	v_local = VERTEX;
	// The cone runs along +Y: map the local height to a 0..1 axis parameter,
	// narrow-near to wide-far. Pre-scale, so the Optics tier-scaling never moves
	// this.
	v_axis = clamp((VERTEX.y + cone_half_height) / max(2.0 * cone_half_height, 0.001),
			0.0, 1.0);
}

void fragment() {
	// Radial distance from the axis, normalised by the cone's radius at this
	// depth (which tapers from near to far), so the profile is constant along the
	// cone rather than stretching with the flare. The cone runs +Y, so the radial
	// plane is XZ.
	float rad_here = mix(cone_near_radius, cone_far_radius, v_axis);
	float r = length(v_local.xz) / max(rad_here, 0.001);
	float radial = pow(clamp(1.0 - r, 0.0, 1.0), edge_power);

	float along = smoothstep(0.0, near_fade, v_axis)
			* (1.0 - smoothstep(1.0 - far_fade, 1.0, v_axis));

	// Two noise layers scrolling at different rates along the axis. The beat
	// between them is what makes a shaft look like it has dust in it rather
	// than like it has a texture on it. The angular coordinate is the sweep
	// around the +Y axis, in the XZ plane.
	vec2 uv0 = vec2(atan(v_local.z, v_local.x) * 0.159, v_axis) * noise_scale;
	float n0 = texture(dust_noise, uv0 - vec2(0.0, TIME * noise_speed)).r;
	float n1 = texture(dust_noise, uv0 * 1.9 + vec2(0.13, -TIME * noise_speed * 0.63)).r;
	float dust = mix(1.0, clamp(n0 * n1 * 2.4, 0.0, 1.4), noise_amount);

	// --- soft particle -------------------------------------------------------
	// Reconstruct linear depth of whatever is already in the buffer and fade
	// out as the beam approaches it. Without this the cone intersects the floor
	// in a hard ellipse and the whole illusion collapses in one frame. VERTEX is
	// in VIEW space in the fragment stage, so -VERTEX.z is this fragment's own
	// linear depth in metres — the same units scene_z is reconstructed into.
	float d = texture(depth_tex, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float scene_z = -view.z;
	float frag_z = -VERTEX.z;
	float soft = clamp((scene_z - frag_z) / soft_distance, 0.0, 1.0);

	ALBEDO = vec3(0.0);
	EMISSION = beam_color * energy * radial * along * dust * soft;
	ALPHA = 1.0;
}
