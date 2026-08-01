shader_type canvas_item;
render_mode unshaded;

// Full-screen grade sitting on top of the 3D pass: vignette, film grain and a
// touch of lateral chromatic aberration. Kept deliberately restrained — these
// effects are here to make the darkness feel photographed rather than rendered,
// not to be noticed on their own.
//
// `degradation` is the exception. DESIGN.md: "At 0 Cycles: framerate-of-self
// degrades — vision closes in, glitches, integrity drains." It is driven from
// Run.degradation() and pushes the same grade into datamosh territory: the
// vignette closes to a tunnel, blocks of the frame slip sideways, scanlines tear
// and the palette briefly inverts. Everything scales from one number so the
// failure reads as one process dying rather than four unrelated effects.

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;

uniform float vignette_intensity : hint_range(0.0, 2.0) = 0.85;
uniform float vignette_inner : hint_range(0.0, 1.0) = 0.32;
uniform float vignette_outer : hint_range(0.0, 1.5) = 0.86;
uniform float grain_amount : hint_range(0.0, 0.2) = 0.028;
uniform float grain_shadow_bias : hint_range(0.0, 1.0) = 0.65;
uniform float aberration : hint_range(0.0, 0.02) = 0.0015;
uniform float stress : hint_range(0.0, 1.0) = 0.0;

// 0 = healthy, 1 = about to be deleted.
uniform float degradation : hint_range(0.0, 1.0) = 0.0;
// Cover for the drop-shaft transition: 0 = clear, 1 = black.
uniform float fade : hint_range(0.0, 1.0) = 0.0;

float hash13(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

float hash11(float p) {
	return fract(sin(p * 78.233) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	// Total failure pressure: sustained degradation plus the transition wipe,
	// which glitches on its way to black so a descent reads as the layer being
	// rewritten around you rather than a cross-fade.
	float fail = clamp(degradation + fade * 0.75, 0.0, 1.0);

	// --- datamosh: horizontal bands slip sideways -------------------------
	if (fail > 0.001) {
		float band = floor(uv.y * mix(18.0, 46.0, fail));
		float jitter = hash11(band + floor(TIME * mix(3.0, 14.0, fail)) * 37.0);
		// Only a minority of bands move at once; a frame where everything
		// shifts reads as camera shake, not corruption.
		float active = step(1.0 - fail * 0.45, jitter);
		uv.x += (jitter - 0.5) * 0.09 * fail * active;

		// Occasional full-frame tear.
		float tear = hash11(floor(TIME * 6.0));
		if (tear > 1.0 - fail * 0.25 && abs(uv.y - fract(tear * 7.3)) < 0.02) {
			uv.x += (tear - 0.5) * 0.25;
		}
		uv.x = clamp(uv.x, 0.0, 1.0);
	}

	vec2 centered = uv - vec2(0.5);
	float dist = length(centered);

	// Aberration scales with the square of the radius: clean centre, smeared
	// corners, the way a cheap wide lens behaves.
	float ab = aberration * (1.0 + stress * 3.0 + fail * 14.0);
	vec2 offset = centered * ab * (0.25 + dist * dist * 2.4);

	vec3 color;
	color.r = texture(screen_texture, clamp(uv + offset, vec2(0.0), vec2(1.0))).r;
	color.g = texture(screen_texture, uv).g;
	color.b = texture(screen_texture, clamp(uv - offset, vec2(0.0), vec2(1.0))).b;

	// --- vignette, closing to a tunnel as the process fails ----------------
	float inner = mix(vignette_inner, 0.02, fail);
	float outer = mix(vignette_outer, 0.30, fail);
	float vig = 1.0 - smoothstep(inner, outer, dist);
	float amount = vignette_intensity * (1.0 + stress * 0.8 + fail * 0.6);
	color *= mix(clamp(1.0 - amount, 0.0, 1.0), 1.0, vig);

	// --- scanline tearing --------------------------------------------------
	if (fail > 0.001) {
		float scan = sin(uv.y * 780.0 + TIME * 40.0) * 0.5 + 0.5;
		color *= 1.0 - scan * 0.22 * fail;

		// Brief palette inversions — a whole frame flipping, rarely, rather
		// than a constant strobe.
		float flip = hash11(floor(TIME * 9.0) + 11.0);
		if (flip > 1.0 - fail * 0.06) {
			color = vec3(1.0) - color;
		}
	}

	// Grain, weighted toward the shadows where a sensor actually struggles.
	float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
	float noise = hash13(vec3(FRAGCOORD.xy, TIME * 60.0)) - 0.5;
	float weight = mix(1.0, 1.0 - clamp(luma, 0.0, 1.0), grain_shadow_bias);
	color += noise * grain_amount * (1.0 + stress * 2.0 + fail * 5.0) * weight;

	// The transition wipe lands last so nothing above can lift it off black.
	color *= 1.0 - fade;

	COLOR = vec4(color, 1.0);
}
