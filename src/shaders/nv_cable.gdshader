shader_type spatial;
render_mode world_vertex_coords, cull_disabled;

// HANGING MATTER.
//
// Every cable, festoon and bundle in the Partition is a tube mesh generated
// along a TRUE catenary (see `Hub._catenary`) rather than a hand-placed arc, and
// this shader is the second half of that: it gives the long, slack runs a
// barely-perceptible idle sway so they read as objects hanging in air rather
// than as geometry that happens to be curved.
//
// WHY A SHADER AND NOT A SCRIPT. A 16 m festoon is ~26 tube rings; swaying it on
// the CPU means rebuilding or re-transforming those every frame, for every run,
// forever, in a room that has twenty of them. Here the whole thing is one
// `sin()` in the vertex stage on geometry that is already being transformed, and
// the run costs exactly what a static cable costs.
//
// THE MOTION. First pendulum mode only: `sin(PI * t)` along the run, so the
// displacement is zero at both anchors and maximum at the sag. That constraint
// is the entire realism budget — a cable that moves at its fixing looks like a
// cable that has come loose. Lateral is the primary axis; a smaller vertical
// term at an irrational frequency ratio (0.618) keeps the two from ever beating
// into a visible loop.
//
// AMPLITUDE IS 1-3 cm AND MUST STAY THERE. This is air movement in a sealed
// maintenance bay, not wind. At 5 cm it becomes a flag and the room starts
// feeling like it is outdoors, which costs more than the sway buys.
//
// `frozen` pins TIME at 0 for capture and benchmark runs so a round-to-round
// comparison is not confounded by where the cables happened to be. Note that the
// frozen pose is NOT the rest pose: each run keeps `sin(sway_phase)`, so the
// captures still show every run displaced by a different amount, which is what a
// still photograph of a room full of hanging cable actually looks like.

uniform vec4 albedo : source_color = vec4(0.118, 0.124, 0.138, 1.0);
uniform float roughness_base : hint_range(0.0, 1.0) = 0.52;
uniform float metallic_base : hint_range(0.0, 1.0) = 0.42;
uniform float specular_base : hint_range(0.0, 1.0) = 0.5;

// Emissive path, for string-light bulbs: same shader so a bulb sways with the
// cable it is threaded onto. `breathe` matches `mat_emissive_amber`'s hum, which
// is the unregulated salvaged supply the whole camp runs off.
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform float breathe_amount : hint_range(0.0, 0.5) = 0.09;
uniform float breathe_speed = 0.33;

uniform vec3 anchor_a = vec3(0.0);
uniform vec3 anchor_b = vec3(0.0, 0.0, 1.0);
uniform vec3 sway_axis = vec3(1.0, 0.0, 0.0);
uniform float sway_amp = 0.0;
uniform float sway_period = 6.0;
uniform float sway_phase = 0.0;
uniform float frozen : hint_range(0.0, 1.0) = 0.0;

uniform vec3 alert_tint : source_color = vec3(1.0, 0.28, 0.30);
uniform float alert : hint_range(0.0, 1.0) = 0.0;

varying float v_sag;

void vertex() {
	vec3 ab = anchor_b - anchor_a;
	// Parameter along the run, taken in the horizontal plane so a vertical drop
	// with a coil at the bottom does not fold its own parameter back on itself.
	float t = clamp(dot(VERTEX - anchor_a, ab) / max(dot(ab, ab), 1e-4), 0.0, 1.0);
	float env = sin(t * PI);
	v_sag = env;
	float tm = TIME * (1.0 - frozen);
	float w = TAU / max(sway_period, 0.01);
	VERTEX += sway_axis * (sway_amp * env * sin(tm * w + sway_phase))
			+ vec3(0.0, 1.0, 0.0) * (sway_amp * 0.4 * env
					* sin(tm * w * 0.618 + sway_phase * 2.3));
}

void fragment() {
	ALBEDO = mix(albedo.rgb, alert_tint, alert * 0.35);
	ROUGHNESS = roughness_base;
	METALLIC = metallic_base;
	SPECULAR = specular_base;
	float et = TIME * (1.0 - frozen);
	float br = 1.0 + breathe_amount * sin(et * breathe_speed * TAU + sway_phase);
	vec3 emit = mix(emission_color, alert_tint, alert * 0.7);
	EMISSION = emit * emission_energy * br;
}
