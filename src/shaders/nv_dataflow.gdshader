shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

// Emissive inlay shader for the kit's recessed trace channels.
//
// Static emissive geometry is the thing that dates a sci-fi environment fastest.
// A glowing line that never changes is a decal; a glowing line with packets
// running down it is infrastructure that is doing something, and the room reads
// as alive. It costs a fract() and an exp().
//
// The kit gives every emissive strip a UV whose U axis is measured in METRES
// along the strip, whichever way the strip is turned. So `flow_speed` here is a
// real speed in m/s and `packet_pitch` a real spacing in metres: a packet
// crossing a vertical pillar channel and one crossing a floor inlay move at the
// same rate and the room feels like one system.
//
// EMISSION (not unshaded ALBEDO) on purpose: it means SSIL picks the inlays up
// as bounce sources, so the teal actually spills onto nearby panels for free
// instead of being a flat sticker that lights nothing.

uniform vec3 flow_color : source_color = vec3(0.16, 0.78, 1.0);
uniform vec3 hostile_color : source_color = vec3(1.0, 0.09, 0.11);
uniform float energy : hint_range(0.0, 12.0) = 3.4;

uniform float flow_speed = 1.9;      // metres per second
uniform float packet_pitch = 2.6;    // metres between packet heads
uniform float packet_tail : hint_range(0.5, 20.0) = 5.0;
uniform float base_level : hint_range(0.0, 1.0) = 0.30;

uniform float breathe_amount : hint_range(0.0, 1.0) = 0.14;
uniform float breathe_speed = 0.55;

// 0 = system nominal (teal, smooth flow). 1 = hostile (red, stuttering, faster,
// running the other way). DESIGN.md reserves red for hostile, so this is the
// whole red-alert look in one uniform.
uniform float hostile : hint_range(0.0, 1.0) = 0.0;
// Independent dying-fixture flicker, driven per-instance from script.
uniform float flicker : hint_range(0.0, 1.0) = 0.0;

float hash11(float p) {
	return fract(sin(p * 78.233) * 43758.5453);
}

void fragment() {
	float s = UV.x;
	float dir = mix(1.0, -1.0, step(0.5, hostile));
	float speed = flow_speed * mix(1.0, 2.3, hostile) * dir;

	// Comet: sharp head at phase 0, exponential tail behind it.
	float phase = fract(s / packet_pitch - TIME * speed / packet_pitch);
	float packet = exp(-phase * packet_tail);
	// Hostile mode quantises the flow into hard steps — it stops looking like
	// data moving and starts looking like something scanning.
	float stutter = floor(TIME * 9.0) / 9.0;
	float hostile_phase = fract(s / (packet_pitch * 0.45) - stutter * 2.4);
	packet = mix(packet, step(0.62, hostile_phase), hostile);

	float level = base_level + packet * (1.0 - base_level);
	level *= 1.0 + sin(TIME * breathe_speed + s * 0.7) * breathe_amount;

	if (flicker > 0.001) {
		float f = hash11(floor(TIME * 22.0) + 3.7);
		level *= mix(1.0, smoothstep(0.30, 0.62, f) * 0.85 + 0.15, flicker);
	}

	vec3 col = mix(flow_color, hostile_color, hostile);

	ALBEDO = col * 0.03;
	ROUGHNESS = 0.42;
	METALLIC = 0.0;
	EMISSION = col * energy * max(level, 0.0);
}
