class_name LightRig
extends RefCounted
## The NULLVOID lighting recipe, as callable functions.
##
## The rule this whole file exists to enforce: **no light does two jobs.** The
## current game lights a room with one kind of fixture at one colour, and the
## result is a space that is either lit or not lit. An expensive room is lit by
## four layers that each do exactly one thing, and the layers disagree with each
## other in colour and direction:
##
##   1. AMBIENT FILL  (environment, not a node) — near-black, cool. Just enough
##      that a silhouette is a silhouette rather than a hole. If you can read the
##      room off the fill alone, the fill is wrong.
##   2. KEY           — cold white-blue spot, high, tight, shadow-casting, and
##      always through a PROJECTOR. Beams that cast structured shadows are the
##      single biggest "expensive" tell in the whole kit. A key light without a
##      gobo paints an ellipse, and an ellipse reads as an engine default.
##   3. ACCENT/BOUNCE — teal, wide, no shadow, low energy, placed to rake ALONG
##      a wall rather than at it. Grazing light finds every chamfer in the kit;
##      perpendicular light finds none of them. This layer is what makes the
##      geometry investment pay off.
##   4. PRACTICAL     — the fixture the player can see: the conduit inlays and
##      the ceiling slots. Small range, matched to the emissive geometry it sits
##      on, so light in the room has a visible source.
##
## Shadow budget: only the key layer casts. In a 4-player co-op each player also
## carries a shadow-casting beam, so the environment cannot afford more than a
## couple of shadowed fixtures per room.

## M8 — THE COLOUR SCRIPT.
##
## The layer used to run on two hues: MOTHER's teal for everything, and an amber
## that only the sanctuary and a scatter of practicals ever saw. Two hues over an
## hour of play is a monoculture — the eye stops reading colour as information
## about ten minutes in, and after that the whole game is one temperature.
##
## So the palette is now SEMANTIC, and the semantics are the constraint that keeps
## it from becoming a paint box:
##
##     TEAL      MOTHER'S OWN SYSTEMS. Her traces, her gates, her glyph panels,
##               her architecture. Teal is HER, and nothing that is not her is
##               allowed to be teal. That is what makes a teal glow in a dark
##               room mean something.
##     AMBER     THE CREW, and the humans who built her. The CRT instrument, the
##               sanctuary, the Northcairn remnants. Warm = someone like you was
##               here.
##     TUNGSTEN  the working practical. A filament in a fitting, not a signal —
##               this is the one that does the actual lighting, and it is the
##               warm end of "service light" rather than a colour with a meaning.
##     SERVICE   cool-white maintenance light. Specified by an engineer, not
##               chosen by anybody. The neutral the other hues are read against.
##     PHOSPHOR  green. DATA and TERMINALS: a running query, a rack with
##               something alive in it, a screen. Never architecture.
##     SODIUM    old warm. The depth drift target — deep rings are lit by
##               fittings nobody has replaced in decades, and the colour a dying
##               lamp goes is orange.
##     HOSTILE   RED, AND ONLY RED. DESIGN.md pillar 7: red = danger, never
##               diluted, never decorative, and always paired with shape and
##               motion so it is not the only channel.
##
## RESTRAINT IS THE POINT. Every hue below sits under `MAX_SATURATION` — this is a
## room you are asked to look at for an hour, and a saturated fixture is a fixture
## you are aware of for the first four minutes and fatigued by for the next fifty.
## The old AMBER at (1.00, 0.62, 0.26) is a traffic cone; the new one is a lamp.
const TEAL: Color = Color(0.36, 0.80, 0.94)
const KEY_COLD: Color = Color(0.72, 0.80, 0.94)
const SERVICE: Color = Color(0.74, 0.82, 0.95)
const AMBER: Color = Color(1.00, 0.71, 0.38)
const TUNGSTEN: Color = Color(1.00, 0.80, 0.58)
const PHOSPHOR: Color = Color(0.52, 0.92, 0.64)
const SODIUM: Color = Color(1.00, 0.66, 0.30)
const HOSTILE: Color = Color(1.00, 0.13, 0.15)

## Nothing in the architectural rig is allowed past this. Emissive geometry and
## the HOSTILE red are exempt — a warning light that obeys a comfort budget is a
## warning light nobody looks at.
const MAX_SATURATION: float = 0.66

const GOBO_GRATE: String = "res://assets/textures/gobo_grate.png"
const GOBO_SLATS: String = "res://assets/textures/gobo_slats.png"
const GOBO_DUST: String = "res://assets/textures/gobo_dust.png"
const GOBO_APERTURE: String = "res://assets/textures/gobo_aperture.png"
const GOBO_CIRCUIT: String = "res://assets/textures/gobo_circuit.png"

# --- FIDELITY PASS: the authored mask library ---------------------------------
#
# Five masks built by the R&D forge (assets/gobos/, demo at
# tools/fidelity_bench/gobo_demo.tscn) and one rule about how they are used:
#
#     A MASK IS AN OBJECT, NOT A PATTERN.
#
# The five gobos above are generic light shapes. These five are pictures of
# specific hardware — a louvre stack, a perforated plate, a stopped extract fan,
# an overhead ladder tray, a walkway grating with runnels. That difference is the
# motivation law (DESIGN.md pillar 6) aimed at lighting: if a key throws slat
# shadows, there is a louvre in the path of that light, and the player should be
# able to find it. So `ProcLayerBuilder` does NOT roll for these — it asks the
# room what is actually standing in it and picks the mask that matches (see
# `_key_gobo_for` and `_ceiling_gobo_for` there).
#
# The old pattern gobos are NOT retired. They still hold the jobs a picture of a
# fitting cannot: GOBO_DUST is atmosphere on an unshadowed wall wash and has
# nothing to be a photograph of, and GOBO_APERTURE is the cheap ceiling shaft in
# rooms that did not earn a real hole. Retiring either would be swapping a
# working effect for a more expensive one that says the same thing.
const GOBO_VENT_SLAT: String = "res://assets/gobos/gobo_vent_slat.png"
const GOBO_FINE_GRILLE: String = "res://assets/gobos/gobo_fine_grille.png"
const GOBO_FAN_BLADES: String = "res://assets/gobos/gobo_fan_blades.png"
const GOBO_CABLE_TRAY: String = "res://assets/gobos/gobo_cable_tray.png"
const GOBO_DRIP_GRATE: String = "res://assets/gobos/gobo_drip_grate.png"

## Godot's positional lights fall off as pow(distance, -attenuation). The game
## already uses this gentle decay so a fixture still delivers usable light
## several metres out; keeping the same number means energies transfer directly.
const DECAY: float = 0.85

# =========================================================== M8 SOFT LIGHT ====
#
# THE NOTE THIS WHOLE SECTION IS AN ANSWER TO, verbatim: *"its nicely dark, but
# those harsh contrasts with the light are too harsh, think back to alien,
# that's more of the feeling i want."*
#
# The diagnosis matters, because the obvious reading of that note is "turn the
# lights up" and that reading is wrong — it would cost the darkness pillar for
# nothing. ALIEN'S DARK IS NOT DIMMER THAN OURS. It is SOFTER. A Nostromo
# corridor and a NULLVOID corridor have about the same amount of black in them;
# what the Nostromo has that we did not is a readable GRADE between the lit thing
# and the black — a wall that goes from lamp to shadow through six values instead
# of two. The room's SHAPE survives into the dark, so you can read the space at a
# glance and the darkness stops being a wall and starts being depth.
#
# Four things were producing the hard edge, and all four are fixed here rather
# than by lifting the exposure:
#
#   1. EVERY SOURCE WAS A POINT. A mathematical point casts a mathematically hard
#      shadow: zero penumbra, a razor line across the floor, and no amount of
#      `shadow_blur` fixes it because blur is a constant screen-space smear and a
#      real penumbra WIDENS with distance from the occluder. Godot's `light_size`
#      gives a fixture actual angular size, so a rib column's shadow is crisp at
#      its base and diffuse three metres out — which is the single biggest thing
#      in this file and is free (the soft-shadow filter is already on at
#      BASELINE; see Photonics.soft_shadows).
#   2. THE CONE EDGES WERE CUTS. `spot_angle_attenuation` under 1.0 is very
#      nearly a hard-edged cone. A real fitting has a reflector and a lens and
#      throws a feathered pool.
#   3. THE FALLOFF WAS TOO STEEP NEAR THE SOURCE. `pow(d, -0.85)` blows up under
#      a metre, so the fixture's own hotspot clips and everything past four
#      metres is nothing. Gentler decay lowers the hotspot AND raises the far
#      field: the same fixture, a much smaller peak-to-black ratio.
#   4. THE KEYS WERE TOO TIGHT AND TOO HOT. Spreading a key and trimming its
#      energy in the same breath is the "same perceived lumens, no razor edge"
#      trade — more of the wall is lit, none of it is blown.
#
# The DARKNESS LAW IS UNTOUCHED and this section is not permitted to renegotiate
# it: not one number below raises the ambient, the fog's ambient inject, or the
# emissive floor. `Layer._apply_environment` still pins the inject to zero. A
# black pixel in a NULLVOID room is still a black pixel; what changed is how many
# values sit between it and the lamp.

## Angular size of the KEY, in metres, and the reason only the key has one.
##
## `light_size` is what gives a source real angular extent, so its shadow gains a
## penumbra that WIDENS with distance from the occluder — a rib column crisp at
## its base and diffuse three metres out. That is the single biggest thing in this
## section and it is why the whole pass exists.
##
## IT IS ALSO, IN GODOT 4.7, A BRIGHTNESS CONTROL, AND THAT COST TWO CAPTURE
## ROUNDS TO FIND. The engine documents `light_size` as making a light FAINTER
## (the energy spreads over the emitter). Measured on this build it does the
## opposite and does it hard: the first cut put a size on all three fixture
## classes — 0.32 key, 0.60 accent, 0.14 practical — and the machine hall's mean
## frame luminance went up 4.8x against pre-M8, with 90% of the frame moving from
## under 0.044 to under 0.318. Zeroing every size and changing nothing else put it
## back to 0.0248 against a pre-M8 0.0247, which is the whole of the effect in one
## number. A softness knob that is really an exposure knob will quietly eat a
## darkness law, and this one nearly did.
##
## Knowing that, the sizes below are set from two DIFFERENT arguments, and which
## argument applies depends on whether the fixture casts:
##
##   THE KEY CASTS. It is the only fixture in the rig that does — the accent and
##   the practical both run `shadow_enabled = false`, because the shadow budget is
##   one or two casters per room against four crew beams. So the key is the only
##   place a size buys a PENUMBRA, and it gets its real physical size: a louvred
##   architectural fitting, a hand's width across. `KEY_PEAK` pays for the energy
##   that comes with it.
##
##   THE FILLS DO NOT CAST, so their size buys nothing but energy — and that turns
##   out to be the honest way to buy the MID-TONE LIFT this pass needs. A wall wash
##   with real extent delivers more light to the panel it rakes, with a softer
##   gradient across it, which is exactly what a diffused tube does and exactly
##   what a mathematical point cannot. It is a lift sourced from FIXTURES rather
##   than from ambient, so it lands where fixtures are and nowhere else.
##
## The fill numbers are therefore a measurement rather than a taste, swept against
## the machine hall — the room that was most nearly a black void:
##
##     accent size   hall mean    hall p90    darkest 1%    frame under 0.004
##     pre-M8        0.0247       0.0441      0.00057       19.4%
##     0.15          0.0250       0.0438      0.00057       19.6%   (no effect)
##     0.35  SHIP    0.0544       0.1279      0.00057       14.6%
##     0.50          0.0750       0.1841      0.00057       10.7%
##     0.60          0.1180       0.3181      0.00085        4.1%   (4.8x — a lift
##                                                                   dressed as a
##                                                                   softness pass)
##
## 0.35 is the row where the room's shape reads and the darkness still owns the
## frame: mid-tones up 2.9x, a quarter of the previously featureless black now
## carrying a value, and THE DARKEST 1% OF THE FRAME BIT-IDENTICAL TO PRE-M8. That
## last column is the darkness law and it is the reason 0.60 is not shipped, even
## though 0.60 is the prettiest photograph of the five.
const SIZE_KEY: float = 0.32
const SIZE_ACCENT: float = 0.35
## The practical stays a point. It is the one fixture that sits ON a visible
## source, so it is already read as a small hot thing — giving it extent makes it
## a lamp shade, and there is no shade modelled.
const SIZE_PRACTICAL: float = 0.0

## The soft distance falloff, replacing DECAY on every fixture the rig emits.
## DECAY itself stays above because callers outside this file still quote it.
##
## Lower exponent = a smaller hotspot near the source AND a brighter far field,
## which is the peak-to-black reduction stated as one number. 0.78 rather than the
## 0.68 the first cut used, and the gap is a MULTIPLICITY finding: a layer carries
## ~190 fixtures, so an exponent is not applied once to one light but 190 times to
## a frame, and 0.68 measured as a room-wide exposure lift rather than as a grade.
## The kit's trace channels needed their own, gentler number for the same reason —
## see `GeometryKit.TRACE_SOFT_DECAY`.
const SOFT_DECAY: float = 0.78

## Cone-edge feather. Higher = the pool fades out across more of the cone. The old
## key ran 0.9, which is within a hair of a hard-edged ellipse.
const KEY_FEATHER: float = 1.45
const ACCENT_FEATHER: float = 2.10

## The key spread/trim trade. A key comes out `KEY_SPREAD` times wider and
## `KEY_PEAK` times weaker than the caller asked for, capped so a wash aimed down
## a long room cannot become a hemisphere (the reason ProcLayerBuilder narrowed
## these in the first place — see its `--- wall wash ---` note; the accents are
## deliberately NOT spread here for exactly that reason).
const KEY_SPREAD: float = 1.22
const KEY_SPREAD_CAP: float = 68.0
const KEY_PEAK: float = 0.78
const ACCENT_PEAK: float = 0.92
## Practicals get NO energy trim, up or down, and the first cut of this pass had
## it at 1.18 and was wrong.
##
## The reasoning that produced 1.18 was sound — a practical is the only fixture in
## the game that sits on a VISIBLE SOURCE, so brightening one adds light to the
## frame without adding visibility across the room, which is the same argument
## Photonics makes for PRACTICAL_GAIN_GI. What it missed is that SOFT_DECAY
## ALREADY DELIVERS THAT LIFT: `d^-0.78` against `d^-0.85` lifts the three-to-six
## metre band, and it is a BETTER lift because it arrives in the mid-field where
## the grade was missing rather than at the hotspot where it was not. Stacking a
## flat 1.18 on top of it took the corridor's floor-spine can bright enough to
## clear the glow threshold and put a blown white blob in the middle of the first
## A/B frame shot for this milestone — a harsh contrast introduced by the pass
## that exists to remove harsh contrasts.
##
## So the lift comes from the CURVE and not from the energy, and this constant
## stays at 1.0 as a place to hang that finding.
const PRACTICAL_PEAK: float = 1.0

## `-- --hardlight`: build the rig with the PRE-M8 numbers.
##
## The companion of `GeometryKit._bevel_off` and it exists for the same reason:
## the read-the-room A/B the coordinator gates this milestone on is only evidence
## if it is the SAME BUILD, the same seed and the same exposure with ONE VARIABLE
## MOVED. Two builds a commit apart is two photographs, not a comparison — and
## the numbers on the two sides of this flag are exactly the pre-M8 values, so
## "put it back" is a flag rather than a memory.
##
## Read once and cached; a fixture builder is called a couple of hundred times
## per layer. Never saved anywhere.
static var _hard: int = -1


## False when `--hardlight` is on the command line.
static func soft() -> bool:
	if _hard < 0:
		_hard = 1 if OS.get_cmdline_user_args().has("--hardlight") else 0
		if _hard == 1:
			print("[LightRig] --hardlight: pre-M8 fixture values (capture flag)")
	return _hard == 0


## look_at with a fallback up vector. Half the good angles in this rig point
## straight down at the floor, which is exactly where the default UP basis is
## degenerate; without this every ceiling light silently keeps its identity
## rotation and the whole rig aims north.
##
## `use_model_front` is FALSE, and that is the whole point of this comment.
##
## M3.7 shipped this call with the flag set to `true`, which asks Godot to point
## the node's **+Z** at the target. A Light3D emits along its **-Z**, exactly like
## a camera — so every key and every accent in the game was aimed 180 degrees away
## from the surface it was placed to light. Every wall wash raked the wrong wall,
## every gobo threw its slats into the void behind the fixture, and the hero
## aperture shaft over each room fired at the ceiling.
##
## That single flag is the root cause of the two symptoms M4.7 was opened to
## chase. Rooms read as "emissive inlays floating in black" because nothing was
## lighting the panels the inlays are cut into; and wall decals read as
## emission-only backlit e-ink because a *printed* sign has nothing to reflect
## when the only light in the room is pointing at the far side of it. The decal
## pipeline was never broken — see `src/dev/decal_probe.tscn`, which renders an
## albedo decal onto the kit's own ShaderMaterial correctly the moment a light
## actually faces it.
##
## The energies in ProcLayerBuilder were tuned against the broken aim, so they
## came down with this fix rather than after it.
static func _aim(node: Node3D, target: Vector3) -> void:
	var dir: Vector3 = (target - node.global_position).normalized()
	var up: Vector3 = Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.995 else Vector3.FORWARD
	node.look_at(target, up, false)


## Layer 2. Cold, shadowed, gobo'd, aimed down. `look_at` is a world point.
static func key(parent: Node3D, pos: Vector3, target: Vector3, energy: float = 5.0,
		gobo: String = GOBO_GRATE, angle: float = 42.0,
		color: Color = KEY_COLD, range_m: float = 26.0,
		shadows: bool = true) -> SpotLight3D:
	var on: bool = soft()
	var l: SpotLight3D = SpotLight3D.new()
	l.name = "Key"
	l.position = pos
	l.light_color = color
	l.light_energy = energy * (KEY_PEAK if on else 1.0)
	# The showcase rooms were 12 m across; generated ones reach 25 m, and a key
	# whose range dies two metres short of the wall it is aimed at is a key that
	# does nothing at all. Callers size this to the room.
	l.spot_range = range_m
	# M8: wider than asked, weaker than asked, in one trade. The gobo survives it —
	# a mask spread over a bigger cone throws BIGGER slats, not blurrier ones.
	l.spot_angle = minf(angle * KEY_SPREAD, KEY_SPREAD_CAP) if on else angle
	# M8: a feathered pool rather than a cut ellipse. The pre-M8 0.9 is within a
	# hair of a hard-edged ellipse, which is what `--hardlight` puts back.
	l.spot_angle_attenuation = KEY_FEATHER if on else 0.9
	l.spot_attenuation = SOFT_DECAY if on else DECAY
	# M8: the source has SIZE, so its shadows have a penumbra that widens with
	# distance from the occluder. `shadow_blur` drops to compensate — with a real
	# light size the blur term is a multiplier on a physically-varying penumbra
	# rather than the whole of the softness, and leaving it at 1.2 smears the near
	# contact shadow that SSAO and the bevel pass both depend on.
	l.light_size = SIZE_KEY if on else 0.0
	l.light_specular = 0.92 if on else 1.0
	l.shadow_enabled = shadows
	l.shadow_bias = 0.035
	l.shadow_normal_bias = 1.4
	l.shadow_blur = 0.85 if on else 1.2
	# The fog is what turns a gobo into god-rays; without this the structure
	# only exists where the beam lands. Trimmed with the cone spread: the same fog
	# energy over a 22% wider cone is 22% more lit air, and the note this pass is
	# answering is about hard edges — including the hard edge of a fog cone.
	l.light_volumetric_fog_energy = 1.12 if on else 1.35
	if gobo != "":
		l.light_projector = load(gobo) as Texture2D
	parent.add_child(l)
	_aim(l, target)
	return _remember(l) as SpotLight3D


## Layer 3. Wide, teal, unshadowed, raking. Cheap — spend these freely.
static func accent(parent: Node3D, pos: Vector3, target: Vector3,
		energy: float = 1.6, color: Color = TEAL, angle: float = 62.0,
		gobo: String = GOBO_DUST, range_m: float = 18.0) -> SpotLight3D:
	var on: bool = soft()
	var l: SpotLight3D = SpotLight3D.new()
	l.name = "Accent"
	l.position = pos
	l.light_color = color
	l.light_energy = energy * (ACCENT_PEAK if on else 1.0)
	l.spot_range = range_m
	# NOT spread. The wash is the one cone in the game that has to stay narrow —
	# it is thrown 24 m down a wall and widening it puts the energy in the fog and
	# leaves the wall black (ProcLayerBuilder's own note). Its softness comes from
	# the feather and the emitter size instead.
	l.spot_angle = angle
	l.spot_angle_attenuation = ACCENT_FEATHER if on else 1.6
	l.spot_attenuation = SOFT_DECAY if on else DECAY
	l.light_size = SIZE_ACCENT if on else 0.0
	# M8: up from 0.55. The accent is the GRAZING layer, and a grazing light is
	# what a chamfer returns a specular streak to — the bevel pass is only worth
	# the triangles if the light raking along it has a highlight to give.
	l.light_specular = 0.66 if on else 0.55
	l.shadow_enabled = false
	l.light_volumetric_fog_energy = 0.70 if on else 0.75
	if gobo != "":
		l.light_projector = load(gobo) as Texture2D
	parent.add_child(l)
	_aim(l, target)
	return _remember(l) as SpotLight3D


## Layer 4. The visible fixture. Range is deliberately short: a practical that
## lights the whole room stops reading as a small light and starts reading as
## the room's ambient, which kills the darkness the game is built on.
static func practical(parent: Node3D, pos: Vector3, energy: float = 1.5,
		range_m: float = 5.0, color: Color = TEAL) -> OmniLight3D:
	var l: OmniLight3D = OmniLight3D.new()
	l.name = "Practical"
	l.position = pos
	l.light_color = color
	# What the level author asked for, kept separately from what is shipped: the
	# PHOTONICS gain below multiplies this, and `set_practical_gain` has to be able
	# to re-derive from the authored figure rather than compounding on itself
	# every time the setting moves.
	var on: bool = soft()
	var peak: float = PRACTICAL_PEAK if on else 1.0
	l.set_meta("fidelity_base", energy * peak)
	l.light_energy = energy * peak * Photonics.practical_gain()
	l.omni_range = range_m
	l.omni_attenuation = SOFT_DECAY if on else DECAY
	l.light_size = SIZE_PRACTICAL if on else 0.0
	# M8: up from 0.65. Practicals sit ON the machinery, which is exactly the
	# geometry the bevel pass chamfered — this is the light that puts the glint on
	# a housing edge from two metres away.
	l.light_specular = 0.80 if on else 0.65
	l.shadow_enabled = false
	# M8: 1.0 -> 0.40, and this one was found in a capture rather than reasoned out.
	#
	# A practical is a small can and it should barely light the air at all. At 1.0
	# it lit plenty, and nobody noticed for two milestones because the old steep
	# falloff kept the contribution inside a metre. Soften the falloff — which is
	# the point of this pass — and the same number spreads that contribution across
	# a much bigger volume of froxels: the ankle-height can down the middle of a
	# corridor became a glowing BALL OF AIR bright enough to clear the glow
	# threshold, sitting in the middle of the first A/B frame shot for this
	# milestone. A harsh contrast introduced by the pass that exists to remove them.
	#
	# The lesson is worth keeping and it generalises past this fixture: a fog energy
	# is not a property of a light on its own, it is a property of a light AND how
	# far that light reaches, so ANY change to a falloff re-opens every fog energy
	# downstream of it.
	l.light_volumetric_fog_energy = 0.40 if on else 1.0
	parent.add_child(l)
	return _remember(l) as OmniLight3D


## Remembers what a fixture was authored as, so `set_alert` can ramp *back*.
##
## The look-dev version lerped from the LightRig constants, which was fine in a
## showcase where every accent really was TEAL. A generated layer is not: the
## sanctuary runs amber, and rooms roll their own teals. Lerping those from a
## constant made a room change colour the instant the alert touched it and never
## return. Stash the authored values instead.
##
## `authored_*` is what the level author asked for and is never rewritten.
## `base_energy` is the *current ceiling* — the value a flicker driver multiplies
## its curve against — so the alert state and the flicker state compose instead
## of fighting each other.
static func _remember(light: Light3D) -> Light3D:
	light.set_meta("authored_energy", light.light_energy)
	light.set_meta("authored_color", light.light_color)
	light.set_meta("base_energy", light.light_energy)
	return light


## Re-scale every practical under `root` to the current PHOTONICS gain.
##
## Called when the quality tier moves so the CINEMA practical lift lands on a
## layer that is already standing, instead of only on the next one the crew
## descends into. It rewrites the authored/base metas as well as the live energy,
## because `set_alert` lerps FROM `authored_energy` and a flicker driver reads its
## ceiling out of `base_energy` — leaving either stale would make an alerted or
## failing fixture snap back to the other tier's brightness.
##
## Practicals only. The keys and accents are the architecture's own exposure and
## the darkness law is written about them; the lift is specifically a lift on the
## SHORT-RANGE fixtures that sit on visible sources (see Photonics).
static func set_practical_gain(root: Node3D, gain: float) -> void:
	for node: Node in root.find_children("Practical*", "OmniLight3D", true, false):
		var light: OmniLight3D = node as OmniLight3D
		if light == null or not light.has_meta("fidelity_base"):
			continue
		var authored: float = float(light.get_meta("fidelity_base")) * gain
		light.set_meta("authored_energy", authored)
		light.set_meta("base_energy", authored)
		light.light_energy = authored


## Attach a flicker behaviour to any light. See flicker.gd for the modes.
static func flicker(light: Light3D, mode: FlickerLight.Mode,
		seed_offset: float = 0.0) -> void:
	_remember(light)
	var f: Node = load("res://src/world/flicker.gd").new()
	f.name = "Flicker"
	f.set("mode", mode)
	f.set("base_energy", light.light_energy)
	f.set("seed_offset", seed_offset)
	light.add_child(f)


## Turn a whole rig hostile. Recolours the key layer red, kills the teal accents,
## and hands the practicals over to the alert pulse. DESIGN.md reserves red for
## hostile, so nothing else in the game may look like this.
##
## Energy is written to the `base_energy` meta as well as to the light, because a
## flickering fixture reads its ceiling from that meta every frame — without this
## an alerted dying light would flicker back up to its peacetime brightness
## between dropouts.
static func set_alert(root: Node3D, amount: float) -> void:
	for l: Node in root.find_children("*", "Light3D", true, false):
		var light: Light3D = l as Light3D
		var authored: Color = light.get_meta("authored_color", light.light_color)
		var energy: float = light.get_meta("authored_energy", light.light_energy)
		var role: String = String(light.name)
		var flickering: bool = light.has_node("Flicker")
		if role.begins_with("Accent"):
			light.light_color = authored.lerp(HOSTILE, amount)
			# Accents are the layer's "everything is fine" layer. They go first.
			var dimmed: float = lerpf(energy, energy * 0.35, amount)
			light.set_meta("base_energy", dimmed)
			if not flickering:
				light.light_energy = dimmed
		elif role.begins_with("Key"):
			light.light_color = authored.lerp(HOSTILE, amount * 0.85)
		elif role.begins_with("Practical"):
			light.light_color = authored.lerp(HOSTILE, amount)


# ====================================================== M8 THE COLOUR SCRIPT ==
#
# WHY THIS IS A PASS OVER THE BUILT RIG RATHER THAN AN ARGUMENT AT EVERY CALL
#
# `ProcLayerBuilder` decides where every fixture goes; it should not also decide
# what colour a room is. Those are different jobs on different clocks — placement
# changes when the generator changes, and the palette changes when somebody plays
# for an hour and says the game is one temperature — and welding them together is
# what produced the monoculture in the first place: a `warm if BACKDOOR else cold`
# ternary repeated at six call sites, which is a colour script you cannot read,
# cannot table, and cannot change without editing the generator.
#
# So the builder keeps emitting fixtures with its own colours, and this runs once
# afterwards and RE-GRADES them by room. It is the same shape as
# `set_practical_gain` above and the same shape as `set_alert`: a walk over the
# standing rig that rewrites the authored metas, so the alert state, the flicker
# drivers and the quality tier all keep composing with it exactly as before.
#
# It is also, not incidentally, the only version of this that could ship this
# milestone — `proc_layer_builder.gd` is under concurrent edit by the batching
# pass and is not ours to touch.
#
# DETERMINISM. Pure function of (room rectangles, archetype, layer number,
# fixture world position). No RNG is consumed, no stream is touched, no graph
# value moves — `--dumplayer` is byte-identical and two peers re-grade the same
# fixture to the same colour without a byte on the wire.
#
# WHAT IT DELIBERATELY DOES NOT TOUCH
#   * anything that is not a generic room fixture. `Practical_trace` is MOTHER's
#     own wall channel and stays teal because teal is HER; `Practical_terminal`
#     stays amber because a command terminal is the crew's CRT and DESIGN.md
#     makes that instrument amber-dominant; the colonnade, ledge and compiler
#     practicals were each placed with a reason and a colour.
#   * anything already red. Red is the danger channel and a grading pass is not
#     allowed anywhere near it.
#   * the nests, which have no fixtures at all — an unlit room is the darkest
#     thing on the layer and that is load-bearing, so the "sickly" identity in
#     the archetype table below is carried by their dressing, not by light.

const ARCH_ARRIVAL: int = 0
const ARCH_BUS: int = 1
const ARCH_VAULT: int = 2
const ARCH_SIPHON: int = 3
const ARCH_SHAFT: int = 4
const ARCH_BACKDOOR: int = 5

## The cold end. Colder than SERVICE and used only where the room's identity IS
## cold — an archive is refrigerated and looks it.
const VAULT_COLD: Color = Color(0.62, 0.76, 0.96)

## THE COLOUR SCRIPT, as a table. One row per archetype, three columns, and the
## budget is the shape of the table itself: two hue families plus one accent, and
## no room may spend more.
##
##   ARRIVAL   cool service white, MOTHER's teal on the trim, one warm can.
##             The crew's first four seconds on a ring: legible, neutral, hers.
##   BUS       MACHINERY HALL. Warm tungsten key over cool service fill, green
##             where something is running. Plant rooms are warm because plant is
##             warm; this is the room the "more colours" note is most about.
##   VAULT     COLD. Refrigerated archive, teal rake, green data.
##   SIPHON    coolant. Teal key over old sodium — the one room where the warm is
##             the OLD warm, because a siphon junction is legacy plumbing.
##   SHAFT     the drop. Cool and unattended.
##   BACKDOOR  SANCTUARY, and the only room in the game that is warm all the way
##             through. Amber over tungsten with a green readout: the campfire.
const SCRIPT_KEY: Array[Color] = [SERVICE, TUNGSTEN, VAULT_COLD, TEAL, SERVICE, AMBER]
const SCRIPT_ACCENT: Array[Color] = [TEAL, SERVICE, TEAL, SODIUM, TEAL, TUNGSTEN]
const SCRIPT_PRACTICAL: Array[Color] = [TUNGSTEN, PHOSPHOR, PHOSPHOR, TUNGSTEN,
	TUNGSTEN, PHOSPHOR]

## How far the depth drift is allowed to travel, and where it lands.
##
## Deeper rings are lit by fittings nobody has relamped in decades. Warm fixtures
## go toward SODIUM (the colour a tired lamp actually goes); cool ones DESATURATE
## toward DRAINED rather than going bluer, which is the same story
## `Layer.GRADE_AMBIENT` tells one band up — "the colour has gone out of the
## place". Capped well short of the target: this is a drift you notice on the
## eleventh ring, not a filter.
const DRIFT_WARM: float = 0.40
const DRIFT_COOL: float = 0.28
const DRIFT_FULL_LAYER: float = 16.0
const DRAINED: Color = Color(0.80, 0.83, 0.86)

## Rooms are matched by rectangle with this much slack in metres, because a wall
## wash is mounted ON the boundary and a ceiling accent can sit a little outside
## the graph rect once the kit has snapped the shell outward.
const ROOM_SLACK: float = 3.0


## The archetype row for one of LayerGraph's archetype strings.
static func script_row(archetype: String) -> int:
	match archetype:
		"arrival": return ARCH_ARRIVAL
		"vault": return ARCH_VAULT
		"siphon": return ARCH_SIPHON
		"shaft": return ARCH_SHAFT
		"backdoor": return ARCH_BACKDOOR
		_: return ARCH_BUS


## Saturation ceiling, applied to everything the script emits.
##
## The hour-of-play test is the reason this function exists rather than a note
## asking authors to be careful. A palette policed by discipline drifts; a palette
## policed by a clamp does not.
static func restrain(c: Color) -> Color:
	if c.s <= MAX_SATURATION:
		return c
	return Color.from_hsv(c.h, MAX_SATURATION, c.v, c.a)


## The depth drift. `t` is 0 at the surface and 1 at DRIFT_FULL_LAYER.
static func drift(c: Color, t: float) -> Color:
	if t <= 0.0:
		return c
	# Warm and cool drift in opposite directions on purpose: if both went warm the
	# deep rings would be monochrome orange, which is a different monoculture and
	# not an improvement on a teal one.
	if c.r >= c.b:
		return c.lerp(SODIUM, DRIFT_WARM * t)
	return c.lerp(DRAINED, DRIFT_COOL * t)


## Which of the three script columns a fixture name asks for, or -1 for "not a
## generic room fixture, leave it exactly as the builder authored it".
static func _script_role(name: String) -> int:
	if name.begins_with("Key_r") or name.begins_with("Key_shaft_r"):
		return 0
	if name.begins_with("Accent_wash_r") or name.begins_with("Accent_up_r"):
		return 1
	if name.begins_with("Practical_r"):
		return 2
	# THE CORRIDORS, and this is the best thing the script does.
	#
	# A corridor's architectural fixtures (`Key_c*`, `Accent_c*`) fall through to
	# `_row_at`'s nearest-room fallback, which resolves PER FIXTURE — so a corridor
	# running from a warm machinery hall to a cold vault is lit warm at one end and
	# cold at the other, and walking it is a slow cross-fade between the two rooms'
	# identities. Nobody authored that gradient; it is what a nearest-neighbour
	# lookup does for free once the rooms have colours at all, and it is worth more
	# than the room palettes themselves because the corridor is where the player
	# spends the time BETWEEN rooms and where a monoculture is most obvious.
	if name.begins_with("Key_c") or name.begins_with("Accent_c"):
		return 0 if name.begins_with("Key_c") else 1
	# `Practical_c*` is deliberately NOT in here. That is the floor-spine can lighting
	# the inlaid trace running down the middle of the corridor, and that trace is
	# MOTHER's own data path — it stays teal under every archetype, because teal is
	# HER and a corridor's architecture changing colour around her inlay is exactly
	# the reading the semantic palette wants.
	return -1


## The archetype row of the room a world point is standing in.
static func _row_at(rooms: Array, at: Vector3) -> int:
	var point: Vector2 = Vector2(at.x, at.z)
	var best: int = ARCH_BUS
	var best_distance: float = INF
	for room_any: Variant in rooms:
		var room: Dictionary = room_any
		var lo: Vector2 = room["min"]
		var hi: Vector2 = room["max"]
		if point.x >= lo.x - ROOM_SLACK and point.x <= hi.x + ROOM_SLACK \
				and point.y >= lo.y - ROOM_SLACK and point.y <= hi.y + ROOM_SLACK:
			return script_row(String(room["archetype"]))
		# Nearest-centre fallback, so a corridor fixture inherits the room it is
		# closest to rather than defaulting to the machinery row.
		var distance: float = point.distance_squared_to((lo + hi) * 0.5)
		if distance < best_distance:
			best_distance = distance
			best = script_row(String(room["archetype"]))
	return best


## Re-grade every generic room fixture under `root` to its room's palette.
##
## `rooms` is `LayerGraph.rooms` — dictionaries carrying `min`, `max` and
## `archetype`. Called by `Layer` once, immediately after the builder is in the
## tree and before anything else has looked at the lighting.
static func apply_colour_script(root: Node3D, rooms: Array, layer: int) -> void:
	if root == null or rooms.is_empty():
		return
	var t: float = clampf(float(maxi(layer, 1) - 1)
			/ maxf(DRIFT_FULL_LAYER - 1.0, 1.0), 0.0, 1.0)
	for node: Node in root.find_children("*", "Light3D", true, false):
		var light: Light3D = node as Light3D
		if light == null:
			continue
		var role: int = _script_role(String(light.name))
		if role < 0:
			continue
		# Never re-grade something already hostile. Nothing in a generated layer
		# should be red at build time, so this is a guard against a future caller
		# rather than against today's — which is exactly when a guard is cheap.
		var was: Color = light.light_color
		if was.r > 0.75 and was.g < 0.35 and was.b < 0.35:
			continue
		var row: int = _row_at(rooms, light.global_position)
		var picked: Color
		if role == 0:
			picked = SCRIPT_KEY[row]
		elif role == 1:
			picked = SCRIPT_ACCENT[row]
		else:
			# Practicals carry the room's accent colour MOST of the time and its key
			# colour the rest, so a machinery hall is a field of warm cans with the
			# occasional green readout in it rather than a row of identical lamps.
			# Hashed off the fixture's own position: deterministic, no RNG consumed,
			# and stable across a descent-and-return.
			var at: Vector3 = light.global_position
			var roll: int = absi(hash(Vector3i(int(roundf(at.x * 4.0)), 977,
					int(roundf(at.z * 4.0)))))
			picked = SCRIPT_PRACTICAL[row] if roll % 5 == 0 else SCRIPT_KEY[row]
		picked = restrain(drift(picked, t))
		light.light_color = picked
		# Both metas, for the same reason `set_practical_gain` rewrites both: the
		# alert lerps FROM `authored_color`, so leaving it stale would make an
		# alerted room ramp back to the colour the builder happened to emit rather
		# than to the colour the script chose.
		light.set_meta("authored_color", picked)
