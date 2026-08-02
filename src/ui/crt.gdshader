shader_type canvas_item;
render_mode unshaded;

// NULLVOID CRT tube — the interface, rendered as Northcairn-era human hardware.
//
// ## The fiction this implements
//
// You are a human-built intrusion program running inside a machine god. MOTHER's
// architecture is sleek, neon and modern — flat emissive inlays, chamfered
// panels, colour she chose. Your *instrument* is not hers. It is the readout the
// people who built her shipped with, decades old, and it is a phosphor tube:
// amber, scanlined, curved, and slightly out of sync. The contrast between the
// two is the point, and it is the same contrast the corrupted Northcairn decals
// in the deep layers are making.
//
// So this shader runs on the HUD **and nothing else**. The world keeps its own
// look; putting scanlines over the architecture would collapse the one
// distinction the whole art direction rests on. That is why the interface is
// rendered into its own SubViewport and this is the container's material —
// see `Hud._build_tube`.
//
// ## What is in here
//
//   * barrel curvature, sampled — a real geometric warp, not a vignette that
//     implies one. This is also where M3.8's deferred "corner clusters get
//     genuine perspective" lands: the clusters ARE in the corners, and the
//     corners of a tube are where the glass bends.
//   * an aperture-grille scanline pair (fine horizontal interlace + a much
//     softer vertical triad), drawn in SCREEN pixels so it does not stretch.
//   * a slow roll bar — the one artefact that says "this is a live signal"
//     rather than "this is a texture of a screen".
//   * horizontal-hold slip and a tracking tear, driven by `damage`. This is the
//     ANALOG half of the glitch vocabulary: an old tube being knocked does not
//     produce RGB-split datamosh blocks, it loses hold and the picture shears.
//   * signal degradation on `degrade`: snow, sync loss, and the phosphor giving
//     up its colour.
//
// Everything has a LOW default amplitude. The readouts have to stay legible in a
// firefight; the reference is Alien: Isolation's motion tracker, not a broken
// television.
//
// Cost: 1 texture fetch in the common case, 3 while the phosphor smear is on.

uniform float amount : hint_range(0.0, 1.0) = 1.0;

// --- glass ---------------------------------------------------------------
uniform float curvature : hint_range(0.0, 0.35) = 0.055;
// How hard the tube's own mask bites at the very edge of the glass.
uniform float bezel_falloff : hint_range(0.0, 0.3) = 0.045;
uniform float vignette : hint_range(0.0, 1.0) = 0.34;

// --- grille --------------------------------------------------------------
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.20;
uniform float scanline_pitch : hint_range(1.0, 8.0) = 2.0;
uniform float grille_strength : hint_range(0.0, 1.0) = 0.06;
// Seconds per pass of the roll bar. Long: it is a tell, not an animation.
uniform float roll_period : hint_range(1.0, 60.0) = 13.0;
uniform float roll_strength : hint_range(0.0, 0.4) = 0.045;

// --- phosphor ------------------------------------------------------------
// Horizontal smear: a phosphor dot does not stop when the beam moves on.
//
// PT2 — THIS WAS THE DOUBLE-STRIKE. The offset used to be a UV fraction, which
// is a fraction of the SCREEN WIDTH, so the same 0.0016 was 2.0 px on the 1280
// display it was tuned on and 5.5 px on a 3440 one. Five pixels is not a
// phosphor bleed, it is a second copy of the glyph — which is exactly what the
// playtest reported ("every character reads as stamped twice"). A phosphor dot
// has a physical size; it does not get wider because you bought a bigger monitor.
// So the smear is now specified in SCREEN PIXELS and converted through
// TEXTURE_PIXEL_SIZE, and the default is ~1 px: present at a 30 cm reading
// distance, invisible as a duplicate.
uniform float smear_pixels : hint_range(0.0, 6.0) = 1.0;
uniform vec3 phosphor : source_color = vec3(1.0, 0.72, 0.30);
// How far the tube pulls everything toward its own phosphor. 1 = a genuinely
// monochrome amber screen; below that, saturated state colours (the red danger
// band) survive, which is what keeps them meaning something.
uniform float phosphor_bias : hint_range(0.0, 1.0) = 0.42;
uniform float gain : hint_range(0.0, 3.0) = 1.06;

// --- gameplay drivers ----------------------------------------------------
// A hit. Horizontal hold goes, one band tears, the phosphor smears sideways.
uniform float damage : hint_range(0.0, 1.0) = 0.0;

// SAFETY (limbo-a11y #9). The damage/tear here is positional shear on the HUD's
// own tube (small area, ~0.2 s), so it is kept — but its amplitude is scaled by
// the project-wide flash switch for comfort (to 0.4 under Reduced Flashing).
global uniform float a11y_flash;
// The shared pool draining. The signal itself starts failing.
uniform float degrade : hint_range(0.0, 1.0) = 0.0;
// Interface boot: the degauss wobble and the brightness coming up.
uniform float warmup : hint_range(0.0, 1.0) = 1.0;

float hash11(float p) {
	return fract(sin(p * 78.233) * 43758.5453);
}

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(41.13, 289.7))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;

	// --- barrel ------------------------------------------------------------
	// Standard radial warp about the centre. Applied before anything else so
	// every artefact below rides the curve rather than sitting flat on top of it.
	vec2 centred = uv * 2.0 - 1.0;
	float r2 = dot(centred, centred);
	centred *= 1.0 + curvature * r2 * amount;
	// Degauss: the coil settling as the tube warms up, felt as a brief extra
	// bulge. Zero once `warmup` reaches 1, so a settled screen is a still screen.
	float settle = (1.0 - warmup) * sin(TIME * 26.0) * 0.02;
	centred *= 1.0 + settle;
	uv = centred * 0.5 + 0.5;

	// --- horizontal hold ---------------------------------------------------
	// The analog damage language. A tube that takes a knock loses hold: the whole
	// picture slips sideways for a few frames and one band shears further than
	// the rest. No RGB split, no block displacement — those are digital faults
	// and they belong to MOTHER, not to your hardware.
	if (damage > 0.001) {
		float damp = mix(0.4, 1.0, a11y_flash);
		float slip = (hash11(floor(TIME * 34.0)) - 0.5) * 0.035 * damage * damp;
		uv.x += slip;
		float band = step(0.5, hash11(floor(TIME * 21.0) + 3.0));
		float tear_y = fract(hash11(floor(TIME * 21.0)) * 3.7);
		if (abs(uv.y - tear_y) < 0.035 * damage) {
			uv.x += band * (hash11(floor(TIME * 61.0)) - 0.5) * 0.14 * damage * damp;
		}
	}

	// --- sync loss ---------------------------------------------------------
	// Degradation is a *signal* problem, not a rendering one: the line the beam
	// is drawing wanders before the picture does.
	if (degrade > 0.001) {
		float line = floor(uv.y * 240.0);
		uv.x += (hash11(line + floor(TIME * 9.0)) - 0.5) * 0.02 * degrade;
		uv.y += sin(TIME * 1.7) * 0.004 * degrade;
	}

	// Off the glass entirely: the tube has no picture there. Expressed as a mask
	// rather than an early return — Godot's shader compiler does not allow
	// `return` inside a processor function.
	float on_glass = step(-0.002, uv.x) * step(uv.x, 1.002)
			* step(-0.002, uv.y) * step(uv.y, 1.002);
	vec2 clamped = clamp(uv, vec2(0.0), vec2(1.0));
	vec4 src = texture(TEXTURE, clamped);

	// --- phosphor persistence, spatial half --------------------------------
	// The temporal half is done properly, by holding the tube's own framebuffer
	// between frames and fading it (see Hud._build_tube). This is only the
	// sideways bleed of a dot that is still lit when the beam has moved on, and
	// it widens under damage because that is when the beam is moving fastest.
	// In screen pixels (see `smear_pixels`), so a 4K tube bleeds as far as a 720p
	// one does — one dot — instead of five times as far.
	float bleed = smear_pixels * TEXTURE_PIXEL_SIZE.x * (1.0 + damage * 7.0);
	if (bleed > 0.00005) {
		vec4 a = texture(TEXTURE, clamp(clamped - vec2(bleed, 0.0), vec2(0.0), vec2(1.0)));
		vec4 b = texture(TEXTURE, clamp(clamped + vec2(bleed * 0.45, 0.0), vec2(0.0), vec2(1.0)));
		// 0.45, down from 0.72. The trailing copy is a decaying dot, not a second
		// impression of the same glyph — at 0.72 the ghost was within a stop of
		// the letter itself, which is what made the edge read as doubled rather
		// than as soft.
		src = max(src, max(a, b) * vec4(0.45, 0.45, 0.45, 0.45));
	}

	vec3 col = src.rgb;
	float alpha = src.a;

	// --- phosphor tint -----------------------------------------------------
	// Pull toward the tube's own colour, but only partway. A fully monochrome
	// screen cannot say "danger" in red, and the whole discipline of this
	// palette is that saturated colour means state.
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(col, phosphor * luma, phosphor_bias * amount);
	col *= gain;

	// --- grille ------------------------------------------------------------
	// PT2: the grille is a CONTENT-SCALE artefact, not a device-pixel one.
	//
	// It used to run at a fixed 2.0 device pixels. On a 720p screen that is one
	// dark line per 9 px cap height and reads as an aperture grille; at 1440p it
	// is one per 19 px of the SAME glyph, i.e. twice as many lines across the same
	// letterform, and a 2 px sine on a 1 px stem is a moiré fight rather than a
	// scanline. `scale` is how many device pixels one design-space pixel occupies
	// (the interface is authored 720 tall), so the tube now wears the same
	// stripe-per-letter at every resolution — which is what "the same tube" was
	// always supposed to mean.
	float scale = max(1.0 / (TEXTURE_PIXEL_SIZE.y * 720.0), 1.0);
	float scan = 0.5 + 0.5 * sin(FRAGCOORD.y * (6.2831853 / (scanline_pitch * scale)));
	col *= 1.0 - scan * scanline_strength * amount;
	float triad = 0.5 + 0.5 * sin(FRAGCOORD.x * (2.0943951 / scale));
	col *= 1.0 - triad * grille_strength * amount;

	// --- roll bar ----------------------------------------------------------
	float roll = fract(uv.y + TIME / roll_period);
	float bar = smoothstep(0.0, 0.12, roll) * smoothstep(0.20, 0.08, roll);
	col *= 1.0 + bar * roll_strength * amount;

	// --- signal degradation ------------------------------------------------
	if (degrade > 0.001) {
		float snow = hash21(FRAGCOORD.xy + vec2(TIME * 61.0, TIME * 37.0));
		col += phosphor * (snow - 0.5) * 0.20 * degrade;
		// The phosphor gives up its colour before it gives up its light.
		col = mix(col, vec3(dot(col, vec3(0.33))), degrade * 0.45);
		alpha *= 1.0 - step(0.986, hash11(floor(uv.y * 180.0) + floor(TIME * 12.0)))
				* degrade * 0.8;
	}

	// --- glass edge --------------------------------------------------------
	vec2 edge = abs(uv * 2.0 - 1.0);
	float inside = (1.0 - smoothstep(1.0 - bezel_falloff, 1.0, edge.x))
			* (1.0 - smoothstep(1.0 - bezel_falloff, 1.0, edge.y));
	float r = length(uv - vec2(0.5)) * 1.42;
	col *= mix(1.0, 1.0 - vignette, smoothstep(0.45, 1.0, r) * amount);

	// Warm-up: the tube comes up in brightness and settles.
	col *= mix(0.0, 1.0, clamp(warmup * 1.15, 0.0, 1.0));

	COLOR = vec4(col, alpha * inside * on_glass);
}
