class_name DropInterface
extends Interactable
## The injection rig — where the crew commits to a dive, together.
##
## This is the thing the playtest complaint is really about. "Why didn't we start
## in the hub but directly in a level?" is a complaint about a game that begins
## with a button in a menu; the answer is not a different button, it is a place
## with a machine in it that the crew has to physically agree at. So: walk onto
## the pad, hold the lever, a countdown runs where everyone can see it, and
## anybody — including whoever is sprinting back across the hall shouting — can
## put their hand on it and stop it.
##
## Deliberately the DropShaft's sibling in shape, and it shares its state machine
## with it on purpose:
##
##   the muster       `Run.crew_mustered()`, counted off `Layer.shaft_position`,
##                    which in the hub is this rig. Nothing had to learn about a
##                    second kind of muster.
##   the channel      local, instant, no round trip to fill a ring.
##   the effect       host-validated. `Run._inject_request` re-asks proximity, the
##                    muster and every crew program's backdoor, and `_fire_inject`
##                    asks the last two AGAIN when the countdown lands — six
##                    seconds is plenty of time for somebody to walk off the pad.
##
## What it does NOT share is the descent's silence. A drop shaft is a hole you
## ride down; this is a decision four people make, so it has a clock on it.

const READY_COLOUR: Color = Color(0.36, 0.9, 1.0)
const WAIT_COLOUR: Color = Color(1.0, 0.6, 0.24)
## Committed. Amber-hot rather than red — red is reserved for hostile processes
## (DESIGN.md pillar 7) and a crew committing to their own dive is not one.
const ARMED_COLOUR: Color = Color(1.0, 0.78, 0.3)

const RING_COUNT: int = 4
## The pulse the armed rig beats at, in Hz. SAFETY LAW (DESIGN.md pillar 7, WCAG
## 2.3.1): nothing in this game flashes above 3 Hz. This is the ceiling the ring
## brightness can reach at the very end of the countdown, and it is asserted by
## the hub selftest rather than trusted to this comment.
const ARM_PULSE_HZ_MAX: float = 2.0
## And the floor it starts at, so the beat visibly tightens as the clock runs
## down. Between the two, the rig never crosses the cap in either direction.
const ARM_PULSE_HZ_MIN: float = 0.8

var _ring_material: StandardMaterial3D = null
var _column_material: StandardMaterial3D = null
var _lever_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _rings: Array[MeshInstance3D] = []
var _channel: float = 0.0


static func create(where: Vector3) -> DropInterface:
	var rig: DropInterface = DropInterface.new()
	rig.name = "DropInterface"
	rig.position = where
	rig.channel_time = Balance.SHAFT_CHANNEL_TIME
	rig._assemble()
	return rig


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# The mast: the crew's own frame, standing in her aperture. Four legs and a
	# collar rather than a solid column, so the shaft of light from the ceiling
	# comes down THROUGH it and the rig is a silhouette inside the beam.
	for corner: Vector3 in [Vector3(-2.2, 0.0, -2.2), Vector3(2.2, 0.0, -2.2),
			Vector3(-2.2, 0.0, 2.2), Vector3(2.2, 0.0, 2.2)]:
		_add_mesh(corner + Vector3(0.0, 2.1, 0.0), Vector3(0.28, 4.2, 0.28), casing)
		_add_mesh(corner + Vector3(0.0, 4.24, 0.0), Vector3(0.44, 0.16, 0.44), casing)
	_add_mesh(Vector3(0.0, 4.3, -2.2), Vector3(4.7, 0.14, 0.14), casing)
	_add_mesh(Vector3(0.0, 4.3, 2.2), Vector3(4.7, 0.14, 0.14), casing)
	_add_mesh(Vector3(-2.2, 4.3, 0.0), Vector3(0.14, 0.14, 4.7), casing)
	_add_mesh(Vector3(2.2, 4.3, 0.0), Vector3(0.14, 0.14, 4.7), casing)

	# The injection column: the write-head that puts the crew into the layer
	# below. Additive, back-face culled — an open tube rendered double-sided
	# reads as a white slab (the same lesson the drop shaft's column carries).
	_column_material = _hologram(READY_COLOUR, 0.08)
	_column_material.cull_mode = BaseMaterial3D.CULL_BACK
	var column: MeshInstance3D = MeshInstance3D.new()
	var cylinder: CylinderMesh = CylinderMesh.new()
	cylinder.top_radius = 1.15
	cylinder.bottom_radius = 1.15
	cylinder.height = 8.0
	cylinder.radial_segments = 18
	cylinder.rings = 0
	cylinder.cap_top = false
	cylinder.cap_bottom = false
	column.mesh = cylinder
	column.position = Vector3(0.0, 4.0, 0.0)
	column.material_override = _column_material
	add_child(column)

	# Rings, annuli not plates — the room has to show through the middle or the
	# column stops being a shaft of light and becomes a lit cylinder.
	_ring_material = _emissive(READY_COLOUR, 0.75)
	for i: int in RING_COUNT:
		var ring: MeshInstance3D = MeshInstance3D.new()
		var torus: TorusMesh = TorusMesh.new()
		torus.inner_radius = 1.08
		torus.outer_radius = 1.22
		torus.rings = 24
		torus.ring_segments = 6
		ring.mesh = torus
		ring.position = Vector3(0.0, 0.4 + float(i) * 0.9, 0.0)
		ring.material_override = _ring_material
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(ring)
		_rings.append(ring)

	_light = OmniLight3D.new()
	_light.name = "RigGlow"
	_light.position = Vector3(0.0, 2.2, 0.0)
	_light.light_color = READY_COLOUR
	_light.light_energy = 1.7
	_light.omni_range = 14.0
	_light.omni_attenuation = 0.8
	_light.light_volumetric_fog_energy = 3.0
	_light.shadow_enabled = false
	add_child(_light)

	# The lever, on the pad's south edge — the side the crew walks in from. A
	# pedestal with a physical throw handle on it, because the whole feature is
	# that committing is an ACT and not a menu item.
	_add_mesh(Vector3(0.0, 0.5, 2.9), Vector3(1.3, 1.0, 0.6), casing)
	_lever_material = _emissive(READY_COLOUR, 0.9)
	_add_mesh(Vector3(0.0, 0.98, 2.72), Vector3(1.0, 0.05, 0.22), _lever_material)
	_add_mesh(Vector3(0.0, 1.22, 2.62), Vector3(0.09, 0.5, 0.09), casing)
	_add_mesh(Vector3(0.0, 1.5, 2.62), Vector3(0.22, 0.14, 0.22), _lever_material)

	# The probe is the LEVER, not the pad. A probe covering the pad would be a
	# volume the crew stands inside, and a ray cast from inside a shape never
	# reports it — you would be unable to interact with the thing you are standing
	# on. (The drop shaft learned this the same way.)
	# Wider than the drop shaft's (2.0 m), because this one is used differently:
	# four people crowd a pad they are all about to leave on, and the crewmate who
	# reaches the lever is whoever is nearest it, not whoever lined themselves up
	# with the middle. Found by standing a joiner 1.9 m off centre and watching the
	# prompt refuse to appear. Still the LEVER and not the pad — a probe covering
	# the pad would be a volume the crew stands inside, and a ray cast from inside
	# a shape never reports it.
	_add_probe(Vector3(3.4, 2.0, 1.2), Vector3(0.0, 0.95, 2.9))


func _add_mesh(at: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	add_child(mesh)
	return mesh


func _emissive(colour: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(0.6)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.5
	material.disable_receive_shadows = true
	return material


func _hologram(colour: Color, alpha: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(colour.r, colour.g, colour.b, alpha)
	material.disable_receive_shadows = true
	return material


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	if Run.injecting:
		return "HOLD E  ·  ABORT INJECTION  ·  %02d" % int(ceilf(Run.inject_remaining))
	if Run.descending:
		return "INJECTING"
	var missing: PackedStringArray = Run.injection_blocked_by()
	if not missing.is_empty():
		return "BACKDOOR %02d NOT INSTALLED  ·  %s" % [
			GameState.backdoor_for(Run.injection_layer), ", ".join(missing)]
	if not Run.crew_mustered():
		return "CREW ON THE PAD  %d/%d" % [Run.muster_inside, Run.muster_total]
	return "HOLD E  ·  INJECT AT LAYER %02d" % Run.injection_layer


func prompt_title() -> String:
	if Run.injecting:
		return "ABORT  ·  %02d" % int(ceilf(Run.inject_remaining))
	if Run.descending:
		return "INJECTING"
	if not Run.injection_blocked_by().is_empty():
		return "BACKDOOR %02d REQUIRED" % GameState.backdoor_for(Run.injection_layer)
	if not Run.crew_mustered():
		return "CREW ON THE PAD  %d/%d" % [Run.muster_inside, Run.muster_total]
	return "INJECTION RIG  ·  LAYER %02d" % Run.injection_layer


func prompt_glyph() -> String:
	return "▼"


## Over the lever, where the probe is and where the crew stands to throw it — not
## over the middle of the pad, which they stand on.
func prompt_anchor() -> Vector3:
	return Vector3(0.0, 2.3, 2.9)


func available() -> bool:
	if Run.descending:
		return false
	# An armed rig is ALWAYS operable, whatever the muster says. The abort is the
	# safety, and a safety you can be locked out of by stepping off the pad is not
	# one — the person most likely to want it is the one who is not on the pad.
	if Run.injecting:
		return true
	return Run.crew_mustered() and Run.injection_blocked_by().is_empty()


## Aborting is a slap, not a ceremony. Committing takes the full channel because
## it is a commitment; stopping it must not.
func channel_seconds() -> float:
	return 0.35 if Run.injecting else channel_time


## Commit and abort are the same lever, so a held key would throw it twice — arm
## the rig and then, 0.35 s later, disarm it, forever. Let go and press again.
func holds_once() -> bool:
	return true


func complete() -> void:
	if Run.injecting:
		Run.request_abort_inject()
		return
	Run.request_inject()


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


func _process(_delta: float) -> void:
	var armed: bool = Run.injecting
	var ready: bool = Run.crew_mustered() and Run.injection_blocked_by().is_empty()
	var colour: Color = WAIT_COLOUR
	if armed:
		colour = ARMED_COLOUR
	elif ready:
		colour = READY_COLOUR

	# SAFETY LAW. The armed beat is a sine at a rate that RAMPS between
	# ARM_PULSE_HZ_MIN and ARM_PULSE_HZ_MAX as the countdown closes — so the rig
	# visibly gets more urgent — and the top of that ramp is under the 3 Hz WCAG
	# 2.3.1 ceiling by construction. It is also scaled by `A11y.flash_scale`, so
	# Reduced Flashing flattens it to a steady glow rather than removing the
	# feedback: colour is never the only channel and neither is motion.
	var beat: float = 1.0
	if armed:
		var closing: float = 1.0 - clampf(
				Run.inject_remaining / maxf(Run.INJECT_COUNTDOWN, 0.01), 0.0, 1.0)
		var hz: float = lerpf(ARM_PULSE_HZ_MIN, ARM_PULSE_HZ_MAX, closing)
		var swing: float = 0.35 * A11y.flash_scale
		beat = 1.0 + swing * (0.5 + 0.5 * sin(
				float(Time.get_ticks_msec()) / 1000.0 * TAU * hz))

	_ring_material.emission = colour
	_lever_material.emission = colour
	_light.light_color = colour
	_column_material.albedo_color = Color(colour.r, colour.g, colour.b,
			(0.14 if armed else 0.05) + _channel * 0.16)

	var t: float = float(Time.get_ticks_msec()) / 1000.0
	# The rings climb the column: idle they drift, channelling they race, and an
	# armed rig runs them at a steady fast rate that reads as "this is happening".
	var speed: float = 0.5 + _channel * 5.0 + (2.6 if armed else 0.0)
	for i: int in _rings.size():
		var phase: float = fposmod(t * speed + float(i) / float(RING_COUNT), 1.0)
		_rings[i].position.y = 0.4 + phase * 4.0
		var shrink: float = 1.0 - phase * 0.35
		_rings[i].scale = Vector3(shrink, 1.0, shrink)
		_rings[i].visible = sin(phase * PI) > 0.12

	var base: float = 0.75 if ready or armed else 0.5
	_ring_material.emission_energy_multiplier = base * beat * (1.0 + _channel * 1.4)
	_lever_material.emission_energy_multiplier = base * beat
	_light.light_energy = (1.7 if ready or armed else 1.1) * beat * (1.0 + _channel)
