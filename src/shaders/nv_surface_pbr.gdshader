shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// LIMBO PROTOCOL surface shader v3 — real baked PBR on a modular kit.
//
// v2 (nv_surface.gdshader) had no texture data at all: it derived roughness and
// albedo variation from two noise fields. That got the kit past "flat greybox",
// and it is still the right shader for anything the player never gets close to.
// It cannot do what this one does, which is survive being looked at from 30 cm.
//
// Three things make this file different from a stock PBR shader:
//
// 1. WORLD-SPACE PROJECTION, NOT UV.
//    The textures are projected from world position, so a run of five identical
//    wall modules is one continuous panel field instead of the same 4 m stamp
//    five times. That single decision does more against modular repetition than
//    any amount of variant authoring — and it means build_kit.py never has to
//    maintain a consistent UV layout across modules.
//
//    Only two planes, picked by dominant normal, with a narrow blend band. Full
//    triplanar would be a third set of fetches to serve geometry this kit does
//    not contain: there is nothing diagonal in a machine room.
//
// 2. THE PLACEMENT STORY LIVES HERE, NOT IN THE TEXTURE.
//    A tiling texture cannot know it is at hand height, or in the middle of a
//    corridor. So the maps carry material identity only, and the two pieces of
//    wear that depend on where a surface IS get applied here from world
//    position: a smudge band where hands and shoulders touch a wall, and a
//    polished traffic path where feet land on a floor. Bake either of those
//    into a tile and you get a smudge band on the ceiling.
//
// 3. THE DETAIL OCTAVE IS DISTANCE-FADED.
//    detail_normal covers 0.25 m — 8192 px/m — and is faded out past a few
//    metres. Close up it is the difference between a texture and a surface;
//    far away it is nothing but aliasing, and TAA would spend its whole budget
//    trying to hold it still.
//
// Fetch budget: 3 (dominant plane) + 2 (detail) + 1 (macro) = 6 typical, 9 on
// the blend band and on anything diagonal. The branch is coherent — walls and
// floors are large contiguous runs of pixels — so waves agree and the second
// plane genuinely is not paid for.

group_uniforms surface;
// `source_color` and NOTHING ELSE. Godot takes one type hint per uniform, so
// writing `source_color, hint_default_white` silently keeps the last one and
// drops the sRGB decode — the texture's stored 0.303 is then used as a linear
// albedo of 0.303 instead of the 0.082 it encodes, and every surface in the
// game renders about four times too bright. It cost a full A/B round: the 30 cm
// wall shot measured +66% mean luminance against the procedural baseline and
// three separate roughness retunes failed to explain it, because roughness was
// never the problem.
uniform sampler2D tex_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// R = ambient occlusion, G = roughness, B = metallic.
uniform sampler2D tex_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D macro_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

group_uniforms detail;
uniform sampler2D detail_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_tiling = 4.0;              // tiles per metre (0.25 m tile)
uniform float detail_depth : hint_range(0.0, 2.0) = 0.85;
uniform float detail_rough : hint_range(0.0, 1.0) = 0.25;
// Distance in metres over which the detail octave fades out. Past this the map
// is pure high-frequency noise under a moving camera.
uniform float detail_fade_start = 2.6;
uniform float detail_fade_end = 7.0;

group_uniforms tiling;
uniform float tile_metres = 2.0;                // must match make_pbr.TILE_METRES
uniform float normal_depth : hint_range(0.0, 3.0) = 1.0;
// Width of the band where the two projection planes cross-fade. Narrow: the
// wider it is, the more pixels pay for six fetches instead of three.
uniform float plane_blend : hint_range(0.01, 0.4) = 0.08;

group_uniforms variation;
// Large-scale modulation on top of the baked maps, in world space, so that two
// identical modules placed side by side still differ. This is the one job the
// old procedural shader did that a texture cannot do for itself.
uniform float macro_scale = 0.055;
uniform float macro_rough : hint_range(0.0, 0.6) = 0.16;
uniform float macro_albedo : hint_range(0.0, 0.6) = 0.18;
uniform vec4 albedo_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float roughness_offset : hint_range(-0.5, 0.5) = 0.0;
uniform float metallic_offset : hint_range(-1.0, 1.0) = 0.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;

group_uniforms story;
// Hand / shoulder contact band on walls. Real corridors have a polished,
// slightly darker stripe at exactly the height people brush past, and it is one
// of those details nobody consciously notices and everybody responds to.
uniform float smudge_amount : hint_range(0.0, 1.0) = 0.55;
uniform float smudge_centre = 1.25;             // metres above the floor
uniform float smudge_width = 0.45;
// Foot traffic on floors: polished where walked, matte where not. Driven by the
// macro field so it is blotchy and organic rather than a painted racing line.
uniform float traffic_amount : hint_range(0.0, 1.0) = 0.0;
uniform float grime_amount : hint_range(0.0, 1.0) = 0.35;
uniform float grime_height : hint_range(0.05, 3.0) = 0.9;

group_uniforms wet;
// Kept from v2 unchanged: paired with SSR and the reflection probes, wet patches
// are free light. A reflection doubles the apparent brightness of a room without
// adding a lumen, which is the only way to make a darkness-law game readable.
uniform float wet_amount : hint_range(0.0, 1.0) = 0.0;
uniform float wet_threshold : hint_range(0.0, 1.0) = 0.55;
uniform float wet_softness : hint_range(0.01, 0.5) = 0.14;
uniform float wet_roughness : hint_range(0.0, 0.5) = 0.045;
uniform float wet_darken : hint_range(0.0, 1.0) = 0.55;

group_uniforms alert;
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

// --- projection helpers ------------------------------------------------------
//
// V is negated in every projection on purpose. The maps are authored with the
// green channel pointing UP the image (the OpenGL convention), and image-up is
// DECREASING v. Sampling with v = -world.y makes image-up equal world-up, which
// means the tangent-to-world mapping below is a plain axis relabel with no
// sign fixes hiding in it. Getting this wrong inverts every recess into a bump
// and the tell only shows when something is lit from below.

vec3 unpack_n(vec3 t) { return t * 2.0 - 1.0; }

// --- sRGB decode, done by hand, on purpose -----------------------------------
//
// The albedo maps store sRGB-encoded values (a linear 0.094 near-black panel is
// stored as 0.340; storing 0.094 directly in 8 bits would leave 24 code values
// for the entire range this game lives in, and band visibly).
//
// `source_color` on a sampler2D uniform is SUPPOSED to apply this decode. In
// this engine build it does not, for a custom shader, under any import setting
// tried: lossless and BPTC, detect_3d on and off, with and without a second
// hint on the uniform. The frames measured 3.6x too bright in every ambient-lit
// region — the exact sRGB-to-linear ratio at our albedo — and a probe that
// multiplied albedo by 0.278 landed the whole frame back on the baseline to
// within 5%.
//
// So it is done here, explicitly. Three pow() on one fetch is nothing, and
// unlike a hint it cannot silently stop working. If a future engine version
// starts honouring source_color, this becomes a DOUBLE decode and every
// surface goes black — which is at least a failure you notice immediately.
vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)),
			step(vec3(0.04045), c));
}


void fragment() {
	vec3 gn = normalize(v_world_normal);
	vec3 an = abs(gn);
	float inv_tile = 1.0 / tile_metres;

	// Which plane dominates, and by how much.
	float up = smoothstep(0.5 - plane_blend, 0.5 + plane_blend, an.y);
	bool x_face = an.x > an.z;

	vec2 uv_h = vec2(v_world.x, -v_world.z) * inv_tile;
	vec2 uv_v = (x_face ? vec2(v_world.z, -v_world.y)
					   : vec2(v_world.x, -v_world.y)) * inv_tile;

	vec3 alb_s;
	vec3 orm_s;
	vec3 wn;      // perturbed world normal

	// --- horizontal plane sample (floors, ceilings) ------------------------
	if (up > 0.001) {
		vec3 a = srgb_to_linear(texture(tex_albedo, uv_h).rgb);
		vec3 o = texture(tex_orm, uv_h).rgb;
		vec3 t = unpack_n(texture(tex_normal, uv_h).xyz);
		t.xy *= normal_depth;
		// u -> +X, image-up -> +Z, plane normal -> sign(gn.y) * Y
		vec3 n = normalize(vec3(t.x, t.z * sign(gn.y), t.y));
		if (up > 0.999) {
			alb_s = a; orm_s = o; wn = n;
		} else {
			vec3 a2 = srgb_to_linear(texture(tex_albedo, uv_v).rgb);
			vec3 o2 = texture(tex_orm, uv_v).rgb;
			vec3 t2 = unpack_n(texture(tex_normal, uv_v).xyz);
			t2.xy *= normal_depth;
			vec3 n2 = x_face
					? normalize(vec3(t2.z * sign(gn.x), t2.y, t2.x))
					: normalize(vec3(t2.x, t2.y, t2.z * sign(gn.z)));
			alb_s = mix(a2, a, up);
			orm_s = mix(o2, o, up);
			wn = normalize(mix(n2, n, up));
		}
	} else {
		// --- vertical plane only (walls) -----------------------------------
		vec3 a2 = srgb_to_linear(texture(tex_albedo, uv_v).rgb);
		vec3 o2 = texture(tex_orm, uv_v).rgb;
		vec3 t2 = unpack_n(texture(tex_normal, uv_v).xyz);
		t2.xy *= normal_depth;
		alb_s = a2;
		orm_s = o2;
		wn = x_face ? normalize(vec3(t2.z * sign(gn.x), t2.y, t2.x))
					: normalize(vec3(t2.x, t2.y, t2.z * sign(gn.z)));
	}

	// --- detail octave ------------------------------------------------------
	float dist = length(VERTEX);   // VERTEX is view-space in fragment()
	float dfade = 1.0 - smoothstep(detail_fade_start, detail_fade_end, dist);
	if (dfade > 0.002) {
		vec2 duv = (up > 0.5 ? vec2(v_world.x, -v_world.z)
							 : (x_face ? vec2(v_world.z, -v_world.y)
									   : vec2(v_world.x, -v_world.y))) * detail_tiling;
		vec3 dt = unpack_n(texture(detail_normal_tex, duv).xyz);
		vec3 dn = (up > 0.5)
				? vec3(dt.x, dt.z * sign(gn.y), dt.y)
				: (x_face ? vec3(dt.z * sign(gn.x), dt.y, dt.x)
						  : vec3(dt.x, dt.y, dt.z * sign(gn.z)));
		// Whiteout-style blend: add the detail's tangential deviation to the
		// base normal rather than replacing it, so the base relief survives.
		wn = normalize(wn + (dn - gn * dot(dn, gn)) * detail_depth * dfade);
		float dr = texture(detail_orm, duv).g;
		orm_s.g = clamp(orm_s.g + (dr - 0.5) * detail_rough * dfade, 0.0, 1.0);
		orm_s.r *= mix(1.0, texture(detail_orm, duv).r, 0.5 * dfade);
	}

	// --- world-space variation ---------------------------------------------
	vec2 muv = (up > 0.5 ? v_world.xz : (x_face ? v_world.zy : v_world.xy)) * macro_scale;
	float macro = texture(macro_noise, muv).r;

	float wear = v_color.r;          // chamfer mask from build_kit.py
	float height01 = v_color.g;      // 0 at floor, 1 at 4 m

	float rough = orm_s.g + roughness_offset + (macro - 0.5) * macro_rough;
	vec3 alb = alb_s * albedo_tint.rgb * (1.0 + (macro - 0.5) * macro_albedo);
	float met = clamp(orm_s.b + metallic_offset, 0.0, 1.0);

	// The kit's own chamfers are geometry, so the texture cannot know about
	// them; the vertex-colour wear mask is how they get polished.
	rough -= wear * 0.14;
	alb += vec3(0.012) * wear;
	met = clamp(met + wear * 0.15, 0.0, 1.0);

	// Grime pooling low on walls.
	float grime = grime_amount * (1.0 - smoothstep(0.0, grime_height, height01))
			* (0.55 + 0.9 * macro);
	rough += grime * 0.18;
	alb *= 1.0 - grime * 0.16;

	// --- the placement story ------------------------------------------------
	// Hand-height contact band: only on near-vertical surfaces, only where the
	// macro field says people actually pass, polished and slightly darkened.
	float band = exp(-pow((v_world.y - smudge_centre) / smudge_width, 2.0));
	float smudge = band * smudge_amount * (1.0 - up) * smoothstep(0.30, 0.75, macro);
	// 0.18, not 0.30. Every one of these story terms is defensible alone and
	// they all subtract from roughness, so they stack: edge wear, the contact
	// band and the macro field together took a matte wall to satin at exactly
	// the height the player's eye sits. Anything that lowers roughness in this
	// shader has to be read as a budget shared between four systems.
	rough -= smudge * 0.18;
	alb *= 1.0 - smudge * 0.10;

	// Foot traffic: polish where feet land. Blotchy, from the macro field, so
	// it reads as wear rather than as a painted walkway.
	float traffic = traffic_amount * up * smoothstep(0.38, 0.72, macro);
	rough -= traffic * 0.26;
	met = clamp(met + traffic * 0.10, 0.0, 1.0);

	// --- wet patches --------------------------------------------------------
	float wet = smoothstep(wet_threshold, wet_threshold + wet_softness, macro) * wet_amount;
	wet *= smoothstep(0.55, 0.9, an.y);       // water sits in the low places
	rough = mix(rough, wet_roughness, wet);
	met = mix(met, 0.42, wet * 0.85);
	alb = mix(alb, alb * (1.0 - wet_darken), wet);
	// A puddle is a levelled surface: kill the relief inside it.
	wn = normalize(mix(wn, gn, wet * 0.85));

	alb = mix(alb, alb * alert_tint, alert);

	ALBEDO = alb;
	ROUGHNESS = clamp(rough, 0.025, 1.0);
	METALLIC = met;
	SPECULAR = mix(0.5, 0.62, wet);
	// World normal written straight into view space. Godot's NORMAL is view
	// space in fragment(); NORMAL_MAP is not usable here because the mesh
	// tangents have nothing to do with the world-space projection above.
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	AO = mix(1.0, orm_s.r, ao_strength);
	AO_LIGHT_AFFECT = 0.30;
}
