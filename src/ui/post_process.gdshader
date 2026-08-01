shader_type canvas_item;
render_mode unshaded;

// NULLVOID post-process v2 — evolution of src/ui/post_process.gdshader.
//
// Kept from v1: the degradation/datamosh path, the fade wipe, the general
// restraint. The grade exists to make the darkness feel photographed, not to be
// noticed.
//
// New in v2:
//   * grain is luma-WEIGHTED with a bell curve, not a shadow ramp. v1 pushed the
//     most grain into the blackest pixels, which reads as dead sensor pixels.
//     Real film grain peaks in the low-mids — the region a near-black game
//     spends all its time in — and vanishes in true black and in highlights.
//   * grain is also chroma-split and anisotropic (slightly wider than tall), so
//     it reads as emulsion rather than as a dither pattern.
//   * chromatic aberration is EDGE-weighted off the local luma gradient as well
//     as the radius, so it fires on the silhouette of a lit doorframe and stays
//     invisible across a flat wall. That is where a real lens shows it.
//   * a 4-tap unsharp pass. Volumetric fog + TAA both soften the image; a touch
//     of sharpen puts the chamfer highlights back without ringing.
//   * corner desaturation + a cool shadow lift, which is what stops near-black
//     from turning into muddy grey-brown once glow is added.
//   * one `intensity` master so a gameplay state can dial the entire grade.
//
// Cost: 3 CA taps + 4 sharpen taps + 1 centre = 8 fetches at native res.

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;

// Master. Gameplay can pull the whole grade down for cutscenes/menus.
uniform float intensity : hint_range(0.0, 2.0) = 1.0;

uniform float vignette_intensity : hint_range(0.0, 2.0) = 0.78;
uniform float vignette_inner : hint_range(0.0, 1.0) = 0.30;
uniform float vignette_outer : hint_range(0.0, 1.5) = 0.92;
uniform float corner_desaturate : hint_range(0.0, 1.0) = 0.24;

uniform float grain_amount : hint_range(0.0, 0.2) = 0.040;
uniform float grain_chroma : hint_range(0.0, 1.0) = 0.35;
uniform float grain_peak : hint_range(0.0, 1.0) = 0.22;   // luma the grain peaks at
uniform float grain_spread : hint_range(0.02, 1.0) = 0.30;

uniform float aberration : hint_range(0.0, 0.02) = 0.0011;
uniform float aberration_edge : hint_range(0.0, 8.0) = 1.6;

uniform float sharpen : hint_range(0.0, 1.5) = 0.42;

uniform float shadow_lift : hint_range(0.0, 0.1) = 0.010;
uniform vec3 shadow_tint : source_color = vec3(0.36, 0.52, 0.78);

// Gameplay drivers, unchanged in meaning from v1.
uniform float stress : hint_range(0.0, 1.0) = 0.0;
uniform float degradation : hint_range(0.0, 1.0) = 0.0;
uniform float fade : hint_range(0.0, 1.0) = 0.0;
// Red-alert / purge: pushes the grade hot without touching any material.
uniform float alert : hint_range(0.0, 1.0) = 0.0;

float hash13(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

float hash11(float p) {
	return fract(sin(p * 78.233) * 43758.5453);
}

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 texel = SCREEN_PIXEL_SIZE;
	float fail = clamp(degradation + fade * 0.75, 0.0, 1.0);

	// --- datamosh: horizontal bands slip sideways (v1 behaviour) -----------
	if (fail > 0.001) {
		float band = floor(uv.y * mix(18.0, 46.0, fail));
		float jitter = hash11(band + floor(TIME * mix(3.0, 14.0, fail)) * 37.0);
		float active = step(1.0 - fail * 0.45, jitter);
		uv.x += (jitter - 0.5) * 0.09 * fail * active;
		float tear = hash11(floor(TIME * 6.0));
		if (tear > 1.0 - fail * 0.25 && abs(uv.y - fract(tear * 7.3)) < 0.02) {
			uv.x += (tear - 0.5) * 0.25;
		}
		uv.x = clamp(uv.x, 0.0, 1.0);
	}

	vec2 centered = uv - vec2(0.5);
	float dist = length(centered);

	vec3 centre = texture(screen_texture, uv).rgb;

	// --- unsharp mask ------------------------------------------------------
	// Four axis taps, not eight. The extra diagonals are unnoticeable at this
	// strength and cost 50% more bandwidth on the fullscreen pass.
	vec3 blur = texture(screen_texture, uv + vec2(texel.x, 0.0)).rgb
			+ texture(screen_texture, uv - vec2(texel.x, 0.0)).rgb
			+ texture(screen_texture, uv + vec2(0.0, texel.y)).rgb
			+ texture(screen_texture, uv - vec2(0.0, texel.y)).rgb;
	blur *= 0.25;
	float local_edge = clamp(abs(luma(centre) - luma(blur)) * 12.0, 0.0, 1.0);

	// --- chromatic aberration, radius * local contrast ----------------------
	// A real lens only shows fringing where there is an edge to fringe. Driving
	// it off local contrast means it lands on the doorframe and the pillar
	// inlays and nowhere else, so the frame stays clean.
	float ab = aberration * intensity * (1.0 + stress * 3.0 + fail * 14.0 + alert * 1.5);
	ab *= (0.35 + local_edge * aberration_edge);
	vec2 offset = centered * ab * (0.25 + dist * dist * 2.4);

	vec3 color;
	color.r = texture(screen_texture, clamp(uv + offset, vec2(0.0), vec2(1.0))).r;
	color.g = centre.g;
	color.b = texture(screen_texture, clamp(uv - offset, vec2(0.0), vec2(1.0))).b;

	color += (color - blur) * sharpen * intensity;
	color = max(color, vec3(0.0));

	// --- shadow lift -------------------------------------------------------
	// Just enough to keep a silhouette readable against the void, and cool so
	// the blacks stay blue-black instead of going muddy under glow.
	float dark = 1.0 - smoothstep(0.0, 0.08, luma(color));
	color += shadow_tint * shadow_lift * dark * intensity;

	// --- vignette + corner desaturation ------------------------------------
	float inner = mix(vignette_inner, 0.02, fail);
	float outer = mix(vignette_outer, 0.30, fail);
	float vig = 1.0 - smoothstep(inner, outer, dist);
	float amount = vignette_intensity * intensity * (1.0 + stress * 0.8 + fail * 0.6);
	color *= mix(clamp(1.0 - amount, 0.0, 1.0), 1.0, vig);

	float l = luma(color);
	color = mix(color, vec3(l), (1.0 - vig) * corner_desaturate * intensity);

	// --- alert grade -------------------------------------------------------
	if (alert > 0.001) {
		vec3 hot = vec3(l) * vec3(1.35, 0.62, 0.60) + color * vec3(0.55, 0.25, 0.25);
		float pulse = 0.72 + 0.28 * sin(TIME * 4.2);
		color = mix(color, hot, alert * 0.55 * pulse);
	}

	// --- scanline tearing / palette flips (v1 behaviour) --------------------
	if (fail > 0.001) {
		float scan = sin(uv.y * 780.0 + TIME * 40.0) * 0.5 + 0.5;
		color *= 1.0 - scan * 0.22 * fail;
		float flip = hash11(floor(TIME * 9.0) + 11.0);
		if (flip > 1.0 - fail * 0.06) {
			color = vec3(1.0) - color;
		}
	}

	// --- grain -------------------------------------------------------------
	// Bell curve on luma: none in true black (that is where dead-pixel noise
	// lives), peak through the low-mids where a real sensor is straining, gone
	// again by the highlights.
	float lg = luma(color);
	float weight = exp(-pow((lg - grain_peak) / grain_spread, 2.0));
	// Anisotropic sample coordinate: grain wider than tall reads as emulsion.
	vec2 gc = FRAGCOORD.xy * vec2(0.72, 1.0);
	float mono = hash13(vec3(gc, TIME * 60.0)) - 0.5;
	vec3 chroma = vec3(
			hash13(vec3(gc + 17.0, TIME * 60.0)) - 0.5,
			hash13(vec3(gc + 41.0, TIME * 60.0)) - 0.5,
			hash13(vec3(gc + 73.0, TIME * 60.0)) - 0.5);
	vec3 noise = mix(vec3(mono), chroma, grain_chroma);
	color += noise * grain_amount * intensity
			* (1.0 + stress * 2.0 + fail * 5.0) * weight;

	color *= 1.0 - fade;
	COLOR = vec4(color, 1.0);
}
