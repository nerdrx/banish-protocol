shader_type fog;

// LIMBO PROTOCOL — local fog density for a god-ray shaft.
//
// The problem this solves: a volumetric shaft reads as a shaft in proportion to
// how much medium the light is passing through, and the only global control is
// the environment's fog density. Turn that up until the hero shafts look right
// and the whole level is inside a fog machine — every distant wall greys out,
// the darkness law dies, and the corridor stops being a corridor.
//
// A FogVolume with this material raises the density ONLY inside its own box. So
// the shaft is dense and the room around it is not, which is exactly the noir
// reference: one shaft carrying the whole frame, everything else black.
//
// Three things happen here that a plain FogMaterial cannot do:
//
//   1. ANIMATED DRIFT. Two 3D noise fields moving at different speeds, one of
//      them rising. Real dust in a light shaft is never still, and a static
//      density pattern is the single tell that separates "volumetric lighting"
//      from "a light shaft asset".
//   2. EDGE FADE ON ALL SIX FACES. A box of extra fog with hard walls shows its
//      own silhouette the moment the camera moves past it. Fading density to
//      zero at the box boundary makes it invisible as an object.
//   3. HEIGHT FALLOFF. Dust settles. Density rises toward the floor, which also
//      means the bottom of a shaft is its brightest part — the correct read,
//      because that is where the cone is widest and the medium densest.

uniform float base_density : hint_range(0.0, 0.5) = 0.075;
// How much of the density comes from the noise vs. a flat fill. At 1.0 the
// shaft is pure structure and can look like smoke; 0.55 keeps it a shaft.
uniform float noise_amount : hint_range(0.0, 1.0) = 0.55;
uniform float noise_scale = 0.16;
uniform float drift_speed = 0.035;
// Fraction of the box's half-size over which density fades to nothing.
uniform float edge_fade : hint_range(0.01, 0.9) = 0.34;
// Extra density at the floor relative to the ceiling.
uniform float height_gain : hint_range(0.0, 3.0) = 0.9;
uniform vec4 fog_albedo : source_color = vec4(0.55, 0.66, 0.82, 1.0);
// Emission is NOT how a shaft gets bright — the light does that. This is a
// whisper of self-illumination so the volume does not go absolutely black when
// the light flickers off, which reads as the shaft popping.
uniform vec4 fog_emission : source_color = vec4(0.004, 0.006, 0.010, 1.0);

uniform sampler3D volume_noise : filter_linear_mipmap, repeat_enable;

void fog() {
	// UVW is 0..1 across the volume. Distance to the nearest face, normalised.
	vec3 d = min(UVW, vec3(1.0) - UVW) / max(edge_fade, 0.001);
	float fade = clamp(d.x, 0.0, 1.0) * clamp(d.y, 0.0, 1.0) * clamp(d.z, 0.0, 1.0);
	fade = fade * fade * (3.0 - 2.0 * fade);

	vec3 p = WORLD_POSITION * noise_scale;
	float a = texture(volume_noise, p + vec3(0.0, TIME * drift_speed, 0.0)).r;
	float b = texture(volume_noise, p * 2.3 - vec3(TIME * drift_speed * 0.4,
			TIME * drift_speed * 1.7, 0.0)).r;
	// Multiplying the two octaves rather than adding them keeps the field
	// sparse: most of the volume stays thin and a few streaks are thick, which
	// is what dust in a beam actually looks like.
	float n = mix(1.0, clamp(a * b * 3.0, 0.0, 1.6), noise_amount);

	float low = 1.0 + height_gain * (1.0 - UVW.y);

	DENSITY = base_density * n * fade * low;
	ALBEDO = fog_albedo.rgb;
	EMISSION = fog_emission.rgb;
}
