@tool
class_name FidelitySlatPanel
extends Node3D
## BACKLIT SLAT-DIFFUSER WALL PANEL — an AreaLight3D behind real louvres.
##
## WHY AN AREALIGHT AND NOT A SPOT
## Every soft light in this game today is a lie told by a wide, dim, unshadowed
## SpotLight3D. That lie has one specific failure: a point source, however wide
## its cone, produces a hard shadow terminator and a small round specular
## highlight. The reference frames are full of the opposite — big flat sources
## behind diffusers whose light wraps around edges and whose reflection in a
## metal surface is a RECTANGLE, because the source is a rectangle. Godot 4.7's
## AreaLight3D is the first time we can just... have the rectangle. `area_size`
## is the emitter, the penumbra falls out of it for free, and the specular
## highlight it leaves on the brushed steel next to it is the shape of the panel.
##
## WHY THERE IS A FALLBACK, AND WHY IT IS A BOOL AND NOT A COMMENT
## Area lights are the most expensive fixture in the kit and the only one whose
## cost scales with soft-shadow quality. A layer that wants twelve wall panels
## cannot have twelve area lights. So the panel degrades in one step: turn
## `use_area_light` off and the same object becomes an emissive diffuser plus an
## optional unshadowed OmniLight fill, which costs what a decorative light costs
## and still puts a visible source on the wall. The generator (or, later, the
## PHOTONICS settings page) picks how many panels in a room get to be real —
## hero panels in the room the player is meant to look at, emissive-only for the
## rest. Because it is one export the choice can be made per-instance at build
## time rather than being a global quality setting nobody can art-direct.
##
## THE SLATS ARE THE INTRICACY LAW
## Their pitch is jittered from a seed and two of them are damaged: one bowed,
## one missing. A louvre stack with even spacing is a comb, and a comb in front
## of a light source produces exactly the metronome shadow that the fidelity
## gobo library exists to avoid. The same rule, at a different scale.
##
## SELF-CONTAINED: the scene carries the housing, frame, diffuser and both
## lights. This script generates the slats (because they are repeated and
## jittered) and applies the export toggles. Nothing here needs an autoload,
## a parent, or the rest of the game.

@export_group("Emission")
## THE toggle. True = a real AreaLight3D with soft shadows. False = emissive
## diffuser only (plus the optional fill), which is what most instances in a
## real layer should be.
@export var use_area_light: bool = true:
	set(v):
		use_area_light = v
		_apply()
## When the area light is off, add a cheap unshadowed OmniLight so the panel
## still spills onto the wall it is mounted on. Without it an emissive-only
## panel is a bright rectangle floating in black — the exact "painted neon line"
## failure the layer environment's SSIL was added to fix, and SSIL only helps
## for surfaces that are on screen.
@export var fallback_fill: bool = true:
	set(v):
		fallback_fill = v
		_apply()
## Cool-white fluorescent. Chosen to sit ~1500 K above the work light's halogen
## so the two read as different eras of hardware in one frame.
@export_range(1800.0, 8000.0, 10.0) var colour_temperature_k: float = 4500.0:
	set(v):
		colour_temperature_k = v
		_apply()
@export_range(0.0, 20.0, 0.05) var energy: float = 2.6:
	set(v):
		energy = v
		_apply()
## Soft shadows are the entire reason to pay for an area light. Turning this off
## keeps the rectangular specular and the wrap, and loses the penumbra — a
## reasonable middle tier for the settings page.
@export var area_shadows: bool = true:
	set(v):
		area_shadows = v
		_apply()
@export_range(0.5, 30.0, 0.1) var area_range_m: float = 7.5:
	set(v):
		area_range_m = v
		_apply()
@export_range(0.0, 3.0, 0.05) var volumetric_boost: float = 0.85:
	set(v):
		volumetric_boost = v
		_apply()

@export_group("Louvres")
@export_range(3, 40, 1) var slat_count: int = 13:
	set(v):
		slat_count = v
		_rebuild_slats()
## How far each slat's pitch is allowed to wander, as a fraction. 0.0 gives a
## comb. Do not ship a comb.
@export_range(0.0, 0.6, 0.01) var slat_jitter: float = 0.28:
	set(v):
		slat_jitter = v
		_rebuild_slats()
@export_range(0.004, 0.06, 0.001) var slat_thickness: float = 0.019:
	set(v):
		slat_thickness = v
		_rebuild_slats()
## Louvre tilt. Non-zero so the slats throw a directional bar rather than a flat
## stripe, and so the panel reads differently from above and below.
@export_range(-45.0, 45.0, 0.5) var slat_tilt_deg: float = 22.0:
	set(v):
		slat_tilt_deg = v
		_rebuild_slats()
@export var slat_damage: bool = true:
	set(v):
		slat_damage = v
		_rebuild_slats()
@export var seed: int = 771302:
	set(v):
		seed = v
		_rebuild_slats()

## The lit aperture, in metres. Must match the geometry in the scene — it drives
## the AreaLight3D's `area_size`, and an area light bigger than its own diffuser
## spills light out of the sides of a solid housing.
@export var aperture: Vector2 = Vector2(1.36, 0.50):
	set(v):
		aperture = v
		_apply()
		_rebuild_slats()

var _slats: Node3D = null


func _ready() -> void:
	_apply()
	_rebuild_slats()


func _area() -> AreaLight3D:
	return get_node_or_null("Area") as AreaLight3D


func _fill() -> OmniLight3D:
	return get_node_or_null("Fill") as OmniLight3D


func _apply() -> void:
	if not is_inside_tree():
		return
	var col: Color = FidelityLib.kelvin_to_color(colour_temperature_k)

	var a: AreaLight3D = _area()
	if a != null:
		a.visible = use_area_light
		a.light_color = col
		a.light_energy = energy
		a.area_size = aperture
		a.area_range = area_range_m
		a.shadow_enabled = use_area_light and area_shadows
		a.light_volumetric_fog_energy = volumetric_boost
		# Energy normalisation ON: with it, changing `area_size` changes the SHAPE
		# of the light and not its brightness, so a panel can be resized during
		# layout without every energy value in the room needing to be re-found.
		a.area_normalize_energy = true

	var f: OmniLight3D = _fill()
	if f != null:
		f.visible = (not use_area_light) and fallback_fill
		f.light_color = col
		# The fill is deliberately weaker than the area light it replaces. It is
		# not trying to match it — it is trying to stop the panel reading as a
		# sticker. A fill that matches the real thing in brightness will not
		# match it in shape, and the mismatch is more obvious the brighter it is.
		f.light_energy = energy * 0.55
		f.omni_range = area_range_m * 0.9
		f.shadow_enabled = false
		f.light_volumetric_fog_energy = volumetric_boost * 0.7

	var diffuser: MeshInstance3D = get_node_or_null("Diffuser") as MeshInstance3D
	if diffuser != null:
		var m: StandardMaterial3D = diffuser.get_surface_override_material(0) as StandardMaterial3D
		if m != null:
			m.emission = col
			# The diffuser stays emissive in BOTH modes. In area-light mode it is
			# the visible source the real light is pretending to come from; in
			# fallback mode it is the only thing left. Its brightness is nudged up
			# in fallback so the panel does not visibly dim when the toggle flips
			# — the point of a graceful degrade is that the player never sees the
			# step.
			var boost: float = 1.0 if use_area_light else 1.45
			m.emission_energy_multiplier = 0.95 * boost * clampf(energy / 2.6, 0.3, 2.5)


# -------------------------------------------------------------------- slats --

func _rebuild_slats() -> void:
	if not is_inside_tree():
		return
	if _slats != null and is_instance_valid(_slats):
		_slats.queue_free()
	_slats = Node3D.new()
	_slats.name = "Slats"
	add_child(_slats)

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed

	var mat: Material = load(FidelityLib.MAT_BRUSHED_STEEL) as Material
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = Vector3(aperture.x, slat_thickness, 0.055)

	# Cumulative jittered pitch — the same construction as the gobo library's
	# slat bands, for the same reason.
	var steps: PackedFloat32Array = PackedFloat32Array()
	var total: float = 0.0
	for i in slat_count:
		var s: float = 1.0 + rng.randf_range(-slat_jitter, slat_jitter)
		steps.append(s)
		total += s
	var unit: float = aperture.y / total

	# One bowed slat and one missing, chosen from the middle of the stack so the
	# damage is not on an edge where the frame would hide it.
	var bowed: int = -1
	var missing: int = -1
	if slat_damage and slat_count >= 6:
		bowed = 1 + (rng.randi() % (slat_count - 3))
		missing = 1 + (rng.randi() % (slat_count - 3))
		if missing == bowed:
			missing = (missing + 2) % (slat_count - 1) + 1

	var y: float = -aperture.y * 0.5
	for i in slat_count:
		var h: float = steps[i] * unit
		y += h
		if i == missing:
			continue
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "Slat%02d" % i
		mi.mesh = mesh
		mi.position = Vector3(0.0, y - h * 0.5, 0.036)
		var tilt: float = slat_tilt_deg
		var roll: float = 0.0
		if i == bowed:
			# Bent out of the stack, and pushed proud of the plane it should sit
			# in. Somebody hit this panel with something.
			tilt = slat_tilt_deg - 26.0
			roll = 1.9
			mi.position += Vector3(0.0, 0.0, 0.014)
		mi.rotation_degrees = Vector3(tilt, 0.0, roll)
		mi.set_surface_override_material(0, mat)
		# Slats are thin and sit inside their own housing; a shadow map slot each
		# would be spent shadowing the light they are already occluding
		# geometrically. Off — the AreaLight's shadow of the ROOM is the one that
		# matters, and the louvre pattern comes from the geometry itself.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_slats.add_child(mi)
