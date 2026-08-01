shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// NULLVOID surface shader — "near-black, but not the same near-black twice".
//
// The whole thesis of this file is that the cheap look and the expensive look
// use the SAME albedo. What separates them is roughness. A flat roughness value
// makes every square metre of a room return light identically, which is the
// single loudest "this is a game engine" tell there is. Real surfaces vary:
// panel to panel (different batches, different wear), across a panel (smudges,
// hand-oil, dust), and along every machined edge (the coating goes first).
//
// So there are three roughness layers here, at three different scales:
//
//   macro   world-space, metres wide  -> panel-to-panel variation. Sampled in
//           WORLD space, not UV, so identical kit modules placed next to each
//           other never look identical. This is what kills modular repetition.
//   detail  UV-space, centimetres     -> smudges and dust breakup.
//   wear    vertex colour R, authored -> every chamfered edge from the Blender
//           kit is polished and lifted. Bevels catch light; polished bevels
//           catch MORE light, and the eye reads that as expensive metal.
//
// Plus two masks that come free with the kit's vertex colours:
//   COLOR.g  height gradient -> grime pools at floor level and nowhere else.
//   COLOR.r  edge wear (above).
//
// And a wet mode for floors: macro noise thresholded into puddle-shaped patches
// of very low roughness. Paired with SSR those patches mirror the teal inlays
// and the fog beams. A dark room with one wet patch reads richer than a dark
// room lit twice as hard.
//
// Cost: 4 texture fetches. That is the entire budget.

uniform vec4 albedo : source_color = vec4(0.048, 0.051, 0.058, 1.0);
uniform float roughness_base : hint_range(0.0, 1.0) = 0.78;
uniform float metallic_base : hint_range(0.0, 1.0) = 0.0;
uniform float specular_base : hint_range(0.0, 1.0) = 0.5;

uniform sampler2D macro_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;

// Scales are in "tiles per metre", so 0.12 = one macro blotch every ~8 m.
uniform float macro_scale = 0.115;
uniform float detail_scale = 1.6;
uniform float normal_scale = 2.4;
uniform float normal_depth : hint_range(0.0, 2.0) = 0.55;

uniform float rough_macro : hint_range(0.0, 1.0) = 0.26;
uniform float rough_detail : hint_range(0.0, 1.0) = 0.13;
uniform float albedo_var : hint_range(0.0, 1.0) = 0.30;

// Edge treatment, driven by the chamfer mask baked into COLOR.r.
uniform float edge_polish : hint_range(0.0, 1.0) = 0.34;
uniform float edge_lift : hint_range(0.0, 0.2) = 0.030;
uniform float edge_metal : hint_range(0.0, 1.0) = 0.30;

// Grime, driven by COLOR.g (0 at the floor, 1 at 4 m).
uniform float grime_amount : hint_range(0.0, 1.0) = 0.45;
uniform float grime_height : hint_range(0.05, 2.0) = 0.55;

// Wet-look patches. Off for walls, on for floors.
uniform float wet_amount : hint_range(0.0, 1.0) = 0.0;
uniform float wet_threshold : hint_range(0.0, 1.0) = 0.55;
uniform float wet_softness : hint_range(0.01, 0.5) = 0.14;
uniform float wet_roughness : hint_range(0.0, 0.5) = 0.045;
uniform float wet_darken : hint_range(0.0, 1.0) = 0.55;

// A hint of brushed direction on trim/metal. Cheap: no extra fetch.
uniform float anisotropy_amount : hint_range(-1.0, 1.0) = 0.0;

// Global emergency tint — the red-alert state pushes this and every surface in
// the layer turns fractionally hostile without touching a single material.
uniform vec3 alert_tint : source_color = vec3(1.0, 0.28, 0.30);
uniform float alert : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_world;
varying vec3 v_world_normal;
varying vec4 v_color;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	v_color = COLOR;
}

void fragment() {
	vec3 n = normalize(v_world_normal);
	vec3 an = abs(n);

	// Two-plane world projection rather than full triplanar: one sample for the
	// horizontal case, one for whichever vertical plane the surface faces most.
	// Third plane would cost a fetch and buy nothing — no surface in this kit is
	// diagonal enough to notice.
	vec2 uv_h = v_world.xz * macro_scale;
	vec2 uv_v = (an.x > an.z ? v_world.zy : v_world.xy) * macro_scale;
	float up = smoothstep(0.35, 0.85, an.y);
	float macro = mix(texture(macro_noise, uv_v).r, texture(macro_noise, uv_h).r, up);

	float detail = texture(detail_noise, UV * detail_scale).r;

	float wear = v_color.r;
	float height = v_color.g;
	float grime = grime_amount * (1.0 - smoothstep(0.0, grime_height, height))
			* (0.55 + 0.9 * macro);

	// --- roughness stack ---------------------------------------------------
	float rough = roughness_base;
	rough += (macro - 0.5) * rough_macro;
	rough += (detail - 0.5) * rough_detail;
	rough += grime * 0.22;
	rough -= wear * edge_polish;

	// --- albedo ------------------------------------------------------------
	vec3 alb = albedo.rgb * (1.0 + (macro - 0.5) * albedo_var);
	alb += vec3(edge_lift) * wear;
	alb *= 1.0 - grime * 0.18;

	float met = clamp(metallic_base + wear * edge_metal, 0.0, 1.0);

	// --- wet patches -------------------------------------------------------
	float wet = smoothstep(wet_threshold, wet_threshold + wet_softness, macro) * wet_amount;
	// Water sits in the low spots, so kill it on anything close to vertical.
	wet *= smoothstep(0.55, 0.9, an.y);
	rough = mix(rough, wet_roughness, wet);
	met = mix(met, 0.42, wet * 0.85);
	alb = mix(alb, alb * (1.0 - wet_darken), wet);

	alb = mix(alb, alb * alert_tint, alert);

	ALBEDO = alb;
	ROUGHNESS = clamp(rough, 0.025, 1.0);
	METALLIC = met;
	SPECULAR = mix(specular_base, 0.62, wet);

	// Normal detail fades out inside a puddle: a wet surface is a levelled one.
	NORMAL_MAP = texture(detail_normal, UV * normal_scale).xyz;
	NORMAL_MAP_DEPTH = normal_depth * (1.0 - wet * 0.85);

	ANISOTROPY = anisotropy_amount;
	// Ambient occlusion from the detail layer only — SSAO owns the big shapes,
	// this just keeps the fine breakup from looking painted on.
	AO = mix(1.0, 0.72 + 0.28 * detail, 0.6);
	AO_LIGHT_AFFECT = 0.25;
}
