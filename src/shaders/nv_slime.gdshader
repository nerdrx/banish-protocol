shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley,
		specular_schlick_ggx, shadows_disabled;

// BANISH PROTOCOL — the Slime slot (ported from limbo-lookdev2 for M4.9).
//
// DESIGN.md: "the rig's organic sections render as translucent gel — glassy
// transmission, wet specular, an internal emissive glow bleeding through (crew:
// the player's phosphor colour inside their shell; Sentinel: deep red).
// Dark-first: glossy-wet darkness with light circulating under glass, never
// bright jelly."
//
// That last clause is the whole brief and it is why StandardMaterial3D's
// transmission/refraction is not enough. Godot's built-in refraction is a screen
// UV offset scaled by roughness, and its transmission is a diffuse wrap — put
// them together on a near-black material in a near-black room and you get a
// slightly shiny black lump, because there is no light BEHIND the object to
// transmit. Gel in a dark game has to carry its own light source.
//
// Four layers, all about depth rather than brightness:
//   1. REFRACTION of whatever is behind the surface, offset by the normal and
//      blurred by thickness — reads as a solid volume, not a shell.
//   2. INTERNAL GLOW at a virtual depth INSIDE the mesh, sampled along the view
//      ray so it slides under the surface as the camera moves ("light
//      circulating under glass"). An emission with no depth offset is paint.
//   3. A FRESNEL RIM to near-total reflection at grazing angles, the way glass
//      does — in a dark room the rim is often the only thing visible, which is
//      right: a crewmate at the edge of your beam reads as a wet outline.
//   4. ABSORPTION: Beer-Lambert, one exp() — the thicker the path, the more the
//      base colour eats the refraction. This is what keeps it from being a soap
//      bubble, and it is what keeps the pale interior Bone geometry countable at
//      1-2 m and swallowed to near-black by 8 m.

group_uniforms body;
// Near-black by law: the colour the gel absorbs TOWARD, not what it displays.
uniform vec4 gel_albedo : source_color = vec4(0.020, 0.026, 0.032, 1.0);
uniform float gel_roughness : hint_range(0.0, 1.0) = 0.06;
uniform float thickness : hint_range(0.0, 4.0) = 1.15;
uniform vec3 absorption : source_color = vec3(0.55, 0.30, 0.22);

group_uniforms internal;
// Crew: the player's phosphor colour. Sentinel: deep red. One uniform, two
// factions, and the material never needs duplicating.
uniform vec3 core_color : source_color = vec3(0.16, 0.78, 1.0);
uniform float core_energy : hint_range(0.0, 6.0) = 1.35;
// How far inside the surface the glow lives, in metres — the parallax is the
// difference between "glowing" and "lit from within".
uniform float core_depth : hint_range(0.0, 0.5) = 0.085;
uniform float core_scale = 5.5;
uniform float core_speed = 0.28;
uniform float core_contrast : hint_range(0.5, 8.0) = 3.2;
uniform sampler2D core_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

group_uniforms surface;
uniform float fresnel_power : hint_range(0.5, 8.0) = 3.4;
uniform float rim_energy : hint_range(0.0, 3.0) = 0.55;
uniform float refraction : hint_range(0.0, 0.2) = 0.038;
uniform float base_alpha : hint_range(0.0, 1.0) = 0.72;
// Perf valve: beyond this many metres the gel drops to a cheap opaque dark shell
// (no screen refraction, no veins) — the glass detail is invisible in the dark at
// range anyway, and this is what keeps a crowd of gel creatures on screen from
// stacking transmission cost. "Glass up close, dark shell beyond N."
uniform float glass_distance : hint_range(1.0, 30.0) = 6.5;

group_uniforms pulse;
// A slow heartbeat. Driven by Cycles for the crew, by the SCAN/PURGE state for
// the Sentinel (the red circulating between shell and bones as it charges).
uniform float pulse_amount : hint_range(0.0, 1.0) = 0.22;
uniform float pulse_hz = 0.42;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;

group_uniforms viewmodel;
// The first-person VIEWMODEL LENS. 1.0 is "the world's own projection" and is
// the default, so every creature wearing this shader is untouched; only the
// local player's own gel is ever told otherwise, by CrewAvatar._push_lens_scale.
// The Slime slot is the LARGEST surface on the crew body (12891 verts, the whole
// shell), so a lens that skipped it would tear the body in half. See
// nv_fp_lens.gdshaderinc for what the three lines do and why.
uniform float lens_scale = 1.0;

varying vec3 v_obj;

void vertex() {
	v_obj = VERTEX;
	if (!IN_SHADOW_PASS && lens_scale != 1.0) {
		PROJECTION_MATRIX[0][0] *= lens_scale;
		PROJECTION_MATRIX[1][1] *= lens_scale;
	}
}

void fragment() {
	vec3 n = normalize(NORMAL);
	float ndv = clamp(dot(n, normalize(VIEW)), 0.0, 1.0);
	float fres = pow(1.0 - ndv, fresnel_power);

	// Path length through the gel, approximated from incidence: through
	// `thickness` at normal incidence, through a great deal more at grazing —
	// dark edges and bright rims at once, the most recognisable property of glass.
	float path = thickness / max(ndv, 0.12);

	ROUGHNESS = gel_roughness;
	METALLIC = 0.0;

	if (length(VERTEX) > glass_distance) {
		// --- distance fallback (perf) -------------------------------------
		// A cheap opaque dark shell: no screen refraction, no vein sampling. Keeps
		// the wet-rim read so a silhouette at range is still glassy, but pays none
		// of the transmission cost.
		ALBEDO = gel_albedo.rgb;
		SPECULAR = 0.5;
		EMISSION = core_color * rim_energy * fres * 0.25;
		ALPHA = 1.0;
	} else {
		// --- 1. refraction ------------------------------------------------
		float dist_fade = 1.0 / (1.0 + length(VERTEX) * 0.35);
		vec2 off = n.xy * refraction * dist_fade * (0.4 + fres * 1.4);
		float lod = clamp(path * 0.9, 0.0, 4.0);
		vec3 behind = textureLod(screen_tex, clamp(SCREEN_UV + off, vec2(0.001),
				vec2(0.999)), lod).rgb;

		// --- 4. absorption (Beer-Lambert) ---------------------------------
		vec3 transmitted = behind * exp(-absorption * path);

		// --- 2. internal glow at depth ------------------------------------
		vec3 view_obj = normalize((inverse(MODEL_MATRIX) * vec4(normalize(VIEW), 0.0)).xyz);
		vec3 deep = v_obj - view_obj * core_depth * (0.5 + path * 0.4);
		float a = texture(core_noise, deep.xy * core_scale + vec2(TIME * core_speed, 0.0)).r;
		float b = texture(core_noise, deep.zy * core_scale * 0.71
				- vec2(0.0, TIME * core_speed * 0.63)).r;
		float veins = pow(clamp(a * b * 2.2, 0.0, 1.0), core_contrast);
		veins *= smoothstep(0.0, 0.6, path * 0.5);
		float beat = 1.0 + pulse_amount * sin(TIME * pulse_hz * 6.2831853);

		vec3 glow = core_color * core_energy * veins * beat;
		glow *= exp(-absorption * path * 0.45);

		SPECULAR = 0.85;
		// --- 3. rim -------------------------------------------------------
		EMISSION = glow + core_color * rim_energy * fres * 0.35;
		ALPHA = clamp(base_alpha + fres * (1.0 - base_alpha), 0.0, 1.0);
		ALBEDO = mix(transmitted, gel_albedo.rgb, clamp(0.25 + fres * 0.75, 0.0, 1.0));
	}
}
