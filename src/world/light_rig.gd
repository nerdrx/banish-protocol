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

const TEAL: Color = Color(0.30, 0.82, 1.00)
const KEY_COLD: Color = Color(0.62, 0.75, 1.00)
const AMBER: Color = Color(1.00, 0.62, 0.26)
const HOSTILE: Color = Color(1.00, 0.13, 0.15)

const GOBO_GRATE: String = "res://assets/textures/gobo_grate.png"
const GOBO_SLATS: String = "res://assets/textures/gobo_slats.png"
const GOBO_DUST: String = "res://assets/textures/gobo_dust.png"
const GOBO_APERTURE: String = "res://assets/textures/gobo_aperture.png"
const GOBO_CIRCUIT: String = "res://assets/textures/gobo_circuit.png"

## Godot's positional lights fall off as pow(distance, -attenuation). The game
## already uses this gentle decay so a fixture still delivers usable light
## several metres out; keeping the same number means energies transfer directly.
const DECAY: float = 0.85


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
	var l: SpotLight3D = SpotLight3D.new()
	l.name = "Key"
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	# The showcase rooms were 12 m across; generated ones reach 25 m, and a key
	# whose range dies two metres short of the wall it is aimed at is a key that
	# does nothing at all. Callers size this to the room.
	l.spot_range = range_m
	l.spot_angle = angle
	# A soft attenuation on the cone edge, but not so soft the gobo smears.
	l.spot_angle_attenuation = 0.9
	l.spot_attenuation = DECAY
	l.light_specular = 1.0
	l.shadow_enabled = shadows
	l.shadow_bias = 0.035
	l.shadow_normal_bias = 1.4
	l.shadow_blur = 1.2
	# The fog is what turns a gobo into god-rays; without this the structure
	# only exists where the beam lands.
	l.light_volumetric_fog_energy = 1.35
	if gobo != "":
		l.light_projector = load(gobo) as Texture2D
	parent.add_child(l)
	_aim(l, target)
	return _remember(l) as SpotLight3D


## Layer 3. Wide, teal, unshadowed, raking. Cheap — spend these freely.
static func accent(parent: Node3D, pos: Vector3, target: Vector3,
		energy: float = 1.6, color: Color = TEAL, angle: float = 62.0,
		gobo: String = GOBO_DUST, range_m: float = 18.0) -> SpotLight3D:
	var l: SpotLight3D = SpotLight3D.new()
	l.name = "Accent"
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.spot_range = range_m
	l.spot_angle = angle
	l.spot_angle_attenuation = 1.6
	l.spot_attenuation = DECAY
	l.light_specular = 0.55
	l.shadow_enabled = false
	l.light_volumetric_fog_energy = 0.75
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
	l.light_energy = energy
	l.omni_range = range_m
	l.omni_attenuation = DECAY
	l.light_specular = 0.65
	l.shadow_enabled = false
	l.light_volumetric_fog_energy = 1.0
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
