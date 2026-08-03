// BANISH PROTOCOL — the first-person VIEWMODEL LENS, and the whole of its
// material story. Included by nv_fp_lens.gdshader and nv_fp_lens_noshadow.gdshader.
//
// ## What this is for
//
// The held weapon and the hands on it are drawn at the edge of a 74-degree
// frame, which at 3440x1440 is 121 degrees of horizontal — and rectilinear
// projection stretches everything that far off-axis radially outward. The bore
// can be exactly on the reticle (round five made it so) and the SILHOUETTE can
// still read raked, because the near end of an 86 cm weapon 11 cm from the eye
// is drawn at a wildly different scale from its far end. Every shooter answers
// this with a longer lens for the held object.
//
// NULLVOID cannot use the textbook second viewport: the arms holding the weapon
// are the same skinned mesh as the chest and the legs (see the note in
// `Player`), and a second pass over this World3D re-runs volumetric fog, SSAO,
// SSIL, SSR and glow. So the lens is done where it costs nothing — in the vertex
// stage of the main pass, by rescaling the projection matrix. Same pass, same
// lights, same shadows, same tonemap; only the raster moves.
//
// ## Why these materials are hand-written rather than converted
//
// BaseMaterial3D cannot carry custom vertex code and Godot 4.7 does not expose
// `get_shader_rid()` to script, so there is no runtime path from a
// StandardMaterial3D to an editable copy of its shader. This is that copy,
// written out: every property the FP palette actually sets, and nothing else.
// The full inventory it has to cover (CrewAvatar.repaint / socket_breaker):
//
//   CrewBody LightMetal  matte(PLATE, 0.30, 0.32)
//   CrewBody Armour      matte(SHELL, 0.15, 0.46)
//   CrewBody Emiss       emissive(accent, 1.0, 0.55)   ANIMATED (corruption fade)
//   CrewBody Slime       gel_material  -> nv_slime.gdshader, lens added there
//   CrewBody Bone        bone_material (emissive, shadows off)
//   Surge    Base        matte(0.048.., 0.25, 0.44)
//   Surge    Emiss       emissive(accent, 1.1, 0.82)   ANIMATED (muzzle flash)
//   Surge    Material.001 matte(0.03.., 0.90, 0.12)
//
// Not one of them uses a texture, a rim, a clearcoat, a backlight, an AO map, a
// transparency mode or a non-default specular. What is left is exactly the four
// channels below, and a spatial shader that writes ALBEDO / METALLIC / ROUGHNESS
// / EMISSION goes through the SAME built-in lighting as the material it
// replaces — which is why `lens_scale == 1.0` renders identically to the build
// this replaced, and why that identity is the test the conversion is held to.
//
// `emission_energy` is the ANIMATED one on two of these slots. It is a plain
// float uniform for that reason: `CrewAvatar._write_accent` and
// `_write_emitter_heat` push to it every frame, exactly as they push to
// `emission_energy_multiplier` on the StandardMaterial3D copies a remote
// crewmate still wears.

uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.3;
uniform float roughness : hint_range(0.0, 1.0) = 0.52;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 0.0;

// The lens. 1.0 is "the world's own projection" and is the default on purpose:
// a material that has never been told about the lens must render exactly as it
// did before. See CrewAvatar.GUN_LENS_DEG for how the number is derived.
uniform float lens_scale = 1.0;


void vertex() {
	// Three lines, and the choice of WHICH three matters.
	//
	// Scaling [0][0] and [1][1] scales the x and y of clip space and leaves z
	// alone, so the near plane, the depth buffer, the wall-clipping tuck and the
	// aspect handling are all untouched — the aspect is already baked into the
	// ratio between these two entries, so a hor+ camera stays hor+ and an
	// ultrawide stays ultrawide without this shader ever knowing the resolution.
	//
	// SKIPPED IN THE SHADOW PASS, which is not a detail: the player's own body
	// and the weapon in front of the headlamp both cast into the world, and a
	// shadow map rendered through the viewmodel's lens would put the weapon's
	// shadow somewhere the weapon is not.
	if (!IN_SHADOW_PASS && lens_scale != 1.0) {
		PROJECTION_MATRIX[0][0] *= lens_scale;
		PROJECTION_MATRIX[1][1] *= lens_scale;
	}
}


void fragment() {
	ALBEDO = albedo.rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	// StandardMaterial3D's default emission operator is ADD, i.e. exactly this
	// product. Zero energy is an unlit slot, which is what the matte families want.
	EMISSION = emission_color.rgb * emission_energy;
}
