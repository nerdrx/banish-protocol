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

// SAFETY-CRITICAL (limbo-a11y 01-photosensitivity). Project-wide flash switch,
// declared in project.godot [shader_globals] and driven by the A11y autoload.
// 1.0 = normal (already inside the unconditional caps below), 0.0 = Reduced
// Flashing. It only ever scales an ALREADY-capped temporal term further down —
// the ship-gate ceilings here (rates, the removed full-frame invert) do NOT
// depend on it.
global uniform float a11y_flash;

// Master. Gameplay can pull the whole grade down for cutscenes/menus.
uniform float intensity : hint_range(0.0, 2.0) = 1.0;

uniform float vignette_intensity : hint_range(0.0, 2.0) = 0.78;
uniform float vignette_inner : hint_range(0.0, 1.0) = 0.30;
uniform float vignette_outer : hint_range(0.0, 1.5) = 0.92;
uniform float corner_desaturate : hint_range(0.0, 1.0) = 0.24;
// M4.95 (filmic pass) vignette refinement (INTEGRATION2 §7).
//   aspect   1.0 = circular in SCREEN space (a lens); 0.0 = the old uv-space
//            ellipse that pretended to be one on a 16:9 frame.
//   falloff  exponent on the darkening ramp. A smoothstep has a knee that shows
//            as a faint ring on a flat dark wall — the single most common "why
//            does the frame look cheap" artefact in a near-black game. A power
//            curve has no knee.
//   shift    nudges the centre down a hair, where an operator frames a subject.
uniform float vignette_aspect : hint_range(0.0, 1.0) = 1.0;
uniform float vignette_falloff : hint_range(0.6, 4.0) = 1.85;
uniform float vignette_shift : hint_range(-0.2, 0.2) = 0.03;

// --- M4.95: depth-band colour-grading LUTs -----------------------------------
// The FILMIC pass's grade. Two 32^3 strip LUTs (tools/make_luts.py) and a blend,
// so a descent CROSS-FADES its grade from one depth band to the next over
// seconds instead of cutting. Layer._apply_environment picks the two bands
// (surface / mid / deep) and drives lut_mix from the layer number. This REPLACES
// the Environment's adjustment grade (which is now disabled) — grading twice is
// how an image is crushed with nobody able to say which stage did it.
uniform sampler2D lut_a : hint_default_black, repeat_disable, filter_linear;
uniform sampler2D lut_b : hint_default_black, repeat_disable, filter_linear;
uniform float lut_mix : hint_range(0.0, 1.0) = 0.0;
uniform float lut_amount : hint_range(0.0, 1.0) = 0.0;
uniform float lut_size = 32.0;

// --- M4.95: cinematic exposure -----------------------------------------------
// A per-depth-band offset in stops (0 = unchanged) and an optional very slow
// breath on top — an iris hunting in near-darkness, not a pulse. Measured ALONE
// this pass makes the game DARKER (INTEGRATION2 §7): surface +0.10 EV drifting to
// deep -0.22 EV. Deliberately near the threshold of perception.
uniform float exposure : hint_range(-2.0, 2.0) = 0.0;
uniform float exposure_breathe : hint_range(0.0, 0.3) = 0.0;
uniform float exposure_breathe_hz = 0.055;

uniform float grain_amount : hint_range(0.0, 0.2) = 0.040;
uniform float grain_chroma : hint_range(0.0, 1.0) = 0.35;
uniform float grain_peak : hint_range(0.0, 1.0) = 0.22;   // luma the grain peaks at
uniform float grain_spread : hint_range(0.02, 1.0) = 0.30;

uniform float aberration : hint_range(0.0, 0.02) = 0.0011;
// M4.95: down from 1.6. An edge-weighted CA fires on local contrast, and a 20 mm
// emissive inlay seen edge-on is nothing BUT local contrast, so at 1.6 (tuned
// against a doorframe) it rainbow-fringed the kit's thin traces. The baked kit is
// full of them; 1.0 keeps the doorframe fringe and drops the trace fringe
// (INTEGRATION2 §12).
uniform float aberration_edge : hint_range(0.0, 8.0) = 1.0;

uniform float sharpen : hint_range(0.0, 1.5) = 0.42;

uniform float shadow_lift : hint_range(0.0, 0.1) = 0.010;
uniform vec3 shadow_tint : source_color = vec3(0.36, 0.52, 0.78);

// Gameplay drivers, unchanged in meaning from v1.
uniform float stress : hint_range(0.0, 1.0) = 0.0;
uniform float degradation : hint_range(0.0, 1.0) = 0.0;
uniform float fade : hint_range(0.0, 1.0) = 0.0;
// Red-alert / purge: pushes the grade hot without touching any material.
uniform float alert : hint_range(0.0, 1.0) = 0.0;
// M3.8 damage flinch. Distinct from `stress`, which is a ~1 s settle: this is a
// hard 0.2 s hit — a few chunky block slips and a real RGB split, the frame
// equivalent of the HUD's own flinch. Kept separate so the two can be tuned
// independently, and so a long stressful stretch never accumulates into
// something that looks like a broken renderer.
uniform float glitch : hint_range(0.0, 1.0) = 0.0;

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

// Sample a 3D LUT stored as a horizontal strip of `size` slices.
//
// The blue axis selects the slice and is interpolated MANUALLY, because hardware
// filtering across a strip would bleed the last column of one slice into the
// first column of the next — a wrong colour on the diagonal of the cube, which
// shows as a magenta tint on exactly the mid-greys that make up most of this
// game's frame. The +0.5/(size*size) half-texel inset is not optional either:
// without it the R axis samples off the ends of each slice and the LUT clips its
// own black and white points.
vec3 lut_sample(sampler2D tex, vec3 c, float size) {
	c = clamp(c, vec3(0.0), vec3(1.0));
	float slice = 1.0 / size;
	float u = (c.r * (size - 1.0) + 0.5) / (size * size);
	float v = (c.g * (size - 1.0) + 0.5) / size;
	float zf = c.b * (size - 1.0);
	float z0 = floor(zf);
	float z1 = min(z0 + 1.0, size - 1.0);
	vec3 s0 = texture(tex, vec2(u + z0 * slice, v)).rgb;
	vec3 s1 = texture(tex, vec2(u + z1 * slice, v)).rgb;
	return mix(s0, s1, zf - z0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 texel = SCREEN_PIXEL_SIZE;
	float fail = clamp(degradation + fade * 0.75, 0.0, 1.0);

	// --- datamosh: horizontal bands slip sideways (v1 behaviour) -----------
	// SAFETY (a11y #2/#3): band reroll capped 14 Hz -> 6 Hz and the tear pick 6 Hz
	// -> 3 Hz so neither reads as strobing motion; the sideways SHIFT (positional,
	// not luminance) is scaled down further by a11y_flash for Reduced Flashing.
	if (fail > 0.001) {
		float band = floor(uv.y * mix(18.0, 46.0, fail));
		float jitter = hash11(band + floor(TIME * mix(3.0, 6.0, fail)) * 37.0);
		float active = step(1.0 - fail * 0.45, jitter);
		uv.x += (jitter - 0.5) * 0.09 * fail * active * mix(0.25, 1.0, a11y_flash);
		float tear = hash11(floor(TIME * 3.0));
		if (tear > 1.0 - fail * 0.25 && abs(uv.y - fract(tear * 7.3)) < 0.02) {
			uv.x += (tear - 0.5) * 0.25 * mix(0.25, 1.0, a11y_flash);
		}
		uv.x = clamp(uv.x, 0.0, 1.0);
	}

	// --- damage flinch: a few chunky blocks slip sideways -------------------
	// Deliberately coarse (8 bands, not 40) and deliberately brief. Damage
	// should read as the frame being *struck*, which is a different gesture
	// from the fine-grained rot of a starving process above.
	if (glitch > 0.001) {
		float slab = floor(uv.y * 8.0);
		float roll = hash11(slab * 12.9 + floor(TIME * 30.0));
		if (roll > 1.0 - glitch * 0.7) {
			uv.x = clamp(uv.x + (roll - 0.5) * 0.06 * glitch, 0.0, 1.0);
		}
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
	// The flinch's split is not edge-weighted: a hit fringes the whole frame,
	// which is exactly what makes it read as an impact rather than as a lens.
	// SAFETY (a11y #10): brief and event-driven, a colour fringe not a luminance
	// flash, so kept — but scaled to 0.4 under Reduced Flashing.
	ab += aberration * glitch * 22.0 * mix(0.4, 1.0, a11y_flash);
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

	// --- M4.95: cinematic exposure -----------------------------------------
	// Before the LUT, because a LUT is a print curve and expects the exposure it
	// was graded for; doing it after would move the image across a transform
	// authored for a different black point.
	float ev = exposure;
	if (exposure_breathe > 0.0001) {
		// SAFETY (a11y): a 0.055 Hz drift of a fraction of a stop is far below any
		// flash threshold and is an amplitude change, not a flash — left unscaled.
		ev += sin(TIME * exposure_breathe_hz * 6.2831853) * exposure_breathe;
	}
	color *= exp2(ev);

	// --- M4.95: depth-band colour-grading LUT ------------------------------
	if (lut_amount > 0.001) {
		vec3 graded = mix(lut_sample(lut_a, color, lut_size),
						  lut_sample(lut_b, color, lut_size), lut_mix);
		color = mix(color, graded, lut_amount * intensity);
	}

	// --- vignette + corner desaturation ------------------------------------
	// M4.95: aspect-corrected radius and a POWER falloff instead of a smoothstep.
	// `dist` above stays uv-space for the CA offset (the fringe follows the
	// sensor, not the lens barrel); the vignette gets its own screen-space radius.
	vec2 vc = centered;
	vc.x *= mix(1.0, SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x, vignette_aspect);
	vc.y += vignette_shift;
	float vdist = length(vc) * 1.414;
	float inner = mix(vignette_inner, 0.02, fail);
	float outer = mix(vignette_outer, 0.30, fail);
	float vt = clamp((vdist - inner) / max(outer - inner, 0.001), 0.0, 1.0);
	float vig = 1.0 - pow(vt, vignette_falloff);
	float amount = vignette_intensity * intensity * (1.0 + stress * 0.8 + fail * 0.6);
	color *= mix(clamp(1.0 - amount, 0.0, 1.0), 1.0, vig);

	float l = luma(color);
	color = mix(color, vec3(l), (1.0 - vig) * corner_desaturate * intensity);

	// --- alert grade -------------------------------------------------------
	if (alert > 0.001) {
		vec3 hot = vec3(l) * vec3(1.35, 0.62, 0.60) + color * vec3(0.55, 0.25, 0.25);
		// SAFETY (a11y #5): 0.668 Hz is already sub-threshold, but it is a large RED
		// field, so under Reduced Flashing the pulse holds steady (a11y_flash -> 0
		// removes the throb) and the mix cap stays at 0.55.
		float pulse = 0.72 + 0.28 * sin(TIME * 4.2) * a11y_flash;
		color = mix(color, hot, alert * 0.55 * pulse);
	}

	// --- scanline tearing (v1 behaviour) -----------------------------------
	// SAFETY-CRITICAL (a11y #1/#4). The v1 FULL-FRAME PALETTE INVERSION
	// (`color = vec3(1.0) - color` picked at up to 9 Hz) is REMOVED: a whole-screen
	// invert is a maximal general flash and, on any red frame, a red flash — it
	// would fail PEAT on its own and gates ship. The datamosh above already reads
	// as signal failure without it. The scrolling scanline stays, but its
	// modulation is capped 0.22 -> 0.15 and scaled by a11y_flash (to 0.05 under
	// Reduced Flashing).
	if (fail > 0.001) {
		float scan = sin(uv.y * 780.0 + TIME * 40.0) * 0.5 + 0.5;
		color *= 1.0 - scan * (0.05 + 0.10 * a11y_flash) * fail;
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
