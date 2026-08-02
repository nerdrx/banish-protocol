shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// LIMBO PROTOCOL — parallax occlusion mapping, for the grate floors only.
//
// POM is priced per HERO SURFACE, never per kit. It is a ray march in the
// fragment shader — 16 to 48 steps of texture fetching per pixel — and putting
// it on every wall would buy a barely-perceptible improvement at a cost that
// scales with how much of the screen the material covers, which in a corridor
// game is all of it.
//
// The grates earn it, for one specific reason: they are the only surface in the
// kit with real VOID behind them. A normal map on a grate is a lie the player
// catches instantly, because they walk over it and the holes do not move
// relative to the bars. POM makes them move. It is the difference between a
// pattern and a hole, and holes are where the beam shines THROUGH the floor —
// which is one of the few genuinely memorable lighting moments the kit has.
//
// Horizontal projection only. Grates are floors. A version that handled walls
// would need a tangent frame per projection plane and three times the code for
// a case the kit does not contain.

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
uniform sampler2D tex_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_height : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_noise : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform float tile_metres = 2.0;
// Real depth of the void behind the bars, in metres. The grate modules in the
// kit are 40 mm deep, so this is not an arbitrary art number — matching it
// means the parallax agrees with the silhouette at the module's edge, which is
// where a wrong value is caught.
uniform float pom_depth : hint_range(0.0, 0.2) = 0.040;
uniform int pom_min_steps : hint_range(4, 32) = 10;
uniform int pom_max_steps : hint_range(8, 64) = 32;
// Distance in metres past which POM degrades to a plain normal-mapped sample.
// Beyond a few metres the parallax is sub-pixel and the march is pure waste.
uniform float pom_fade = 5.0;

uniform float normal_depth : hint_range(0.0, 3.0) = 1.3;
uniform float macro_scale = 0.09;
uniform float roughness_offset : hint_range(-0.5, 0.5) = 0.0;
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
	float inv_tile = 1.0 / tile_metres;
	vec2 uv = vec2(v_world.x, -v_world.z) * inv_tile;

	// View direction, world space, pointing from the surface to the eye.
	vec3 vw = (INV_VIEW_MATRIX * vec4(normalize(-VERTEX), 0.0)).xyz;
	// Tangent frame for this projection: T = +X, B = -Z (matching v = -world.z),
	// N = +Y. So the tangent-space view is a plain axis relabel.
	vec3 vt = normalize(vec3(vw.x, -vw.z, max(vw.y * sign(gn.y), 0.02)));

	float dist = length(VERTEX);
	float fade = 1.0 - smoothstep(pom_fade * 0.6, pom_fade, dist);

	if (fade > 0.01) {
		// Step count by incidence: at grazing angles the ray crosses far more
		// texels per unit of depth and a fixed count produces visible stepping
		// exactly where the effect is strongest.
		float steps = mix(float(pom_max_steps), float(pom_min_steps),
				clamp(vt.z, 0.0, 1.0));
		float layer = 1.0 / steps;
		// Total UV travel for a full traversal of the depth.
		vec2 delta = (vt.xy / vt.z) * pom_depth * inv_tile * fade;
		vec2 step_uv = delta * layer;

		float h = 1.0;
		float sampled = texture(tex_height, uv).r;
		// March until the ray drops below the height field.
		for (int i = 0; i < 64; i++) {
			if (float(i) >= steps || sampled >= h) {
				break;
			}
			uv -= step_uv;
			h -= layer;
			sampled = texture(tex_height, uv).r;
		}
		// One linear refinement between the last two steps. A binary search
		// would be more exact and it is not worth the extra fetches: the error
		// after this is well under a texel.
		vec2 prev = uv + step_uv;
		float after = sampled - h;
		float before = texture(tex_height, prev).r - h - layer;
		uv = mix(uv, prev, after / max(after - before, 0.0001));
	}

	vec3 alb = srgb_to_linear(texture(tex_albedo, uv).rgb);
	vec3 orm = texture(tex_orm, uv).rgb;
	vec3 t = texture(tex_normal, uv).xyz * 2.0 - 1.0;
	t.xy *= normal_depth;
	vec3 wn = normalize(vec3(t.x, t.z * sign(gn.y), t.y));

	float macro = texture(macro_noise, v_world.xz * macro_scale).r;
	float wear = v_color.r;

	alb = mix(alb, alb * alert_tint, alert);

	ALBEDO = alb * (1.0 + (macro - 0.5) * 0.14) + vec3(0.02) * wear;
	ROUGHNESS = clamp(orm.g + roughness_offset + (macro - 0.5) * 0.14 - wear * 0.2,
			0.025, 1.0);
	METALLIC = clamp(orm.b + wear * 0.25, 0.0, 1.0);
	SPECULAR = 0.5;
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	AO = orm.r;
	AO_LIGHT_AFFECT = 0.35;
}
