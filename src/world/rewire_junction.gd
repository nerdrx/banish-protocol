class_name RewireJunction
extends Interactable
## A power bus with three loads and enough current for one of them.
##
## DESIGN.md's M4.8 line, and the Alien: Isolation rewire box it is named after:
## a wall panel that lets you take the power away from one system and give it to
## another. Three loads, and the whole prop is the fact that you cannot have two:
##
##   ROOM LIGHTING   emergency strips come up in the junction rooms and the
##                   corridors off them. You can cross those without your beam,
##                   which is the only light in the game you did not have to
##                   carry — and DESIGN.md pillar 2 means it is deliberately
##                   feeble.
##   DOOR LOCKS      the layer's cabinet locks release. Open them silently
##                   instead of cutting them, which is the difference between
##                   looting a nest and waking one.
##   VENT FANS       every weldable vent on the layer slams shut for 90 s. A
##                   temporary version of a permanent job, and the answer when a
##                   nest is already emptying into the room you are standing in.
##
## Rerouting a live bus is **loud** — a siphon's worth of noise (Balance's
## NOISE_ROOMS_JUNCTION), which is what stops the answer being "flip it back and
## forth as needed". Every choice here is one the whole layer hears you make.
##
## Solo-friendly by construction: one agent, one panel, one keypress. Co-op only
## changes who is watching the corridor while you read it.
##
## The prop is the face; `Props` owns the state and the host owns `Props`.

## Physical box colours. Teal, because this is MOTHER's machinery — the amber CRT
## is *your* readout of it and lives in the panel, not on the wall.
const CASING_COLOUR: Color = Color(0.24, 0.78, 0.95)
const LAMP_DEAD: Color = Color(0.16, 0.19, 0.22)

## Height of the box's centre. Chest height on a wall: you open it standing.
const MOUNT_HEIGHT: float = 1.45

var prop_index: int = 0

## Emergency strips this junction feeds, handed over by the builder. Lights and
## emissive bars in the junction's own room and the corridors leading off it.
var strips: Array[Node3D] = []
var _strip_lights: Array[OmniLight3D] = []
var _strip_material: StandardMaterial3D = null
## True once the junction is standing, so the switch clunk sounds only real
## throws, not the routing a joiner adopts on arrival (M5).
var _audio_ready: bool = false

var _lamps: Array[MeshInstance3D] = []
var _lamp_materials: Array[StandardMaterial3D] = []
var _screen_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _channel: float = 0.0
var _engaged: float = 0.0
## Eased 0..1 brightness of the emergency strips, so power arriving reads as
## fluorescent tubes striking rather than as a switch.
var _lit: float = 0.0


static func create(index: int, where: Vector3, yaw: float) -> RewireJunction:
	var junction: RewireJunction = RewireJunction.new()
	junction.name = "RewireJunction%d" % index
	junction.prop_index = index
	junction.position = where
	junction.rotation.y = yaw
	junction.channel_time = Balance.JUNCTION_OPEN_TIME
	junction._assemble()
	return junction


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# The box. Deliberately a *box on a wall* rather than a recessed panel: it has
	# to be findable by a beam sweeping past at an angle, and a flush panel is
	# invisible from anywhere but straight on.
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT, 0.11), Vector3(0.92, 1.12, 0.22), casing)
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT + 0.60, 0.14), Vector3(1.02, 0.07, 0.28), casing)
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT - 0.60, 0.14), Vector3(1.02, 0.07, 0.28), casing)
	# Hinge stack down one side and the handle down the other, so the silhouette
	# says "this opens" before any of the emissive is close enough to read.
	for y: float in [-0.34, 0.0, 0.34]:
		_add_mesh(Vector3(-0.44, MOUNT_HEIGHT + y, 0.2), Vector3(0.08, 0.14, 0.1), casing)
	_add_mesh(Vector3(0.40, MOUNT_HEIGHT, 0.24), Vector3(0.05, 0.34, 0.05), casing)

	# Conduit leaving the box: one down into the deck, one up into the ceiling
	# run. Without them the panel is a briefcase somebody hung on a wall.
	_add_mesh(Vector3(-0.16, MOUNT_HEIGHT - 1.35, 0.1), Vector3(0.12, 1.4, 0.12), casing)
	_add_mesh(Vector3(0.18, MOUNT_HEIGHT + 1.1, 0.1), Vector3(0.12, 1.0, 0.12), casing)

	# The readout: a dark plate with three load lamps on it. One lamp lit at a
	# time, ever — the prop's whole argument, legible from across the room.
	# Near-black albedo on the plate, for the reason the Compiler's screen and the
	# command terminal's tube both give: a lit face is a lamp, and a lamp with
	# three status lamps on it has no status to read.
	var backing: StandardMaterial3D = _emissive(CASING_COLOUR, 0.10)
	backing.albedo_color = Color(0.018, 0.021, 0.024)
	backing.roughness = 0.9
	backing.metallic = 0.0
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT + 0.24, 0.23), Vector3(0.66, 0.34, 0.03), backing)
	for i: int in 3:
		var material: StandardMaterial3D = _emissive(LAMP_DEAD, 0.2)
		_lamp_materials.append(material)
		_lamps.append(_add_mesh(
				Vector3(-0.21 + float(i) * 0.21, MOUNT_HEIGHT + 0.24, 0.25),
				Vector3(0.115, 0.115, 0.02), material))

	_screen_material = _emissive(CASING_COLOUR, 1.1)
	# Four short readout bars under the lamps, the same trick the Compiler's plate
	# uses: a screen is a dark surface with bright lines on it, never a lit face.
	for i: int in 4:
		var width: float = 0.2 + UiFx.hash01(float(i) * 4.1 + float(prop_index)) * 0.34
		_add_mesh(Vector3(-0.27 + width * 0.5, MOUNT_HEIGHT - 0.12 - float(i) * 0.075, 0.248),
				Vector3(width, 0.018, 0.012), _screen_material)

	_light = OmniLight3D.new()
	_light.name = "JunctionGlow"
	_light.position = Vector3(0.0, MOUNT_HEIGHT, 0.6)
	_light.light_color = CASING_COLOUR
	_light.light_energy = 0.55
	_light.omni_range = 4.2
	_light.omni_attenuation = 1.3
	_light.light_volumetric_fog_energy = 1.0
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(1.3, 1.6, 0.9), Vector3(0.0, MOUNT_HEIGHT, 0.25))


func _ready() -> void:
	add_to_group(Props.GROUP_JUNCTION)
	Props.power_changed.connect(_on_power_changed)
	_lit = 1.0 if Props.power == Props.Power.LIGHTS else 0.0
	_apply_strips(_lit)
	# Only sound power changes that happen after we are standing, not the adopted
	# initial state.
	_audio_ready = true


func _on_power_changed() -> void:
	# The knife-switch clunk, on every peer (Props.power_changed fires on all of
	# them off the one validated request), positioned at the junction. Guarded so
	# a joiner adopting the layer's current routing does not hear a phantom throw.
	if _audio_ready:
		Audio.play_3d(&"rewire_clunk", global_position)
	# The eased visuals in _process read Props directly.


## Adopts the emergency strips the builder made for this junction: their lights
## go dark until the bus is routed to them.
func adopt_strips(lights: Array[OmniLight3D], material: StandardMaterial3D) -> void:
	_strip_lights = lights
	_strip_material = material
	_apply_strips(0.0)


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
	material.albedo_color = colour.darkened(0.62)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.45
	material.disable_receive_shadows = true
	return material


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	return "HOLD E  ·  REWIRE JUNCTION  ·  %s" % Props.power_name(Props.power)


func prompt_title() -> String:
	return "REWIRE  ·  %s" % Props.power_name(Props.power)


func prompt_glyph() -> String:
	return "≡"


func prompt_height() -> float:
	return MOUNT_HEIGHT + 0.95


func prompt_visible() -> bool:
	return not JunctionPanel.is_open()


func available() -> bool:
	return Run.local_running() and not JunctionPanel.is_open()


func complete() -> void:
	JunctionPanel.open_for(self)


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


# ------------------------------------------------------------------ visuals --

func _process(delta: float) -> void:
	var open: bool = JunctionPanel.is_open_for(self)
	_engaged = move_toward(_engaged, 1.0 if open else 0.0, delta * 3.0)

	var t: float = UiFx.clock()
	var idle: float = 0.84 + sin(t * 2.1) * 0.16
	var charge: float = 1.0 + _channel * 1.4 + _engaged * 2.0
	_screen_material.emission_energy_multiplier = 1.1 * idle * charge
	_light.light_energy = 0.55 * idle * (1.0 + _channel * 0.9 + _engaged * 1.6)

	# One lamp lit. The others are not dimmed, they are *dead* — this is a bus
	# with one load on it, not a menu with a highlighted row.
	for i: int in _lamps.size():
		var powered: bool = Props.power == i + 1
		var lamp: StandardMaterial3D = _lamp_materials[i]
		lamp.emission = _lamp_colour(i + 1) if powered else LAMP_DEAD
		lamp.emission_energy_multiplier = (2.4 * idle) if powered else 0.16

	# Emergency strips strike rather than switch: a fluorescent tube takes a
	# moment to decide, and half a second of hesitation is the difference between
	# a lighting change and a lighting *event*.
	var want: float = 1.0 if Props.power == Props.Power.LIGHTS else 0.0
	_lit = move_toward(_lit, want, delta * (2.2 if want > 0.0 else 3.4))
	if _lit > 0.0 and want > 0.0 and _lit < 1.0:
		# The strike flicker. Only on the way up, and only while it is happening.
		_apply_strips(_lit * (0.35 + 0.65 * absf(sin(t * 27.0))))
	else:
		_apply_strips(_lit)


static func _lamp_colour(mode: int) -> Color:
	match mode:
		Props.Power.LIGHTS:
			return Color(1.0, 0.82, 0.42)
		Props.Power.DOORS:
			return Color(0.36, 1.0, 0.62)
		Props.Power.FANS:
			return Color(0.42, 0.78, 1.0)
		_:
			return LAMP_DEAD


func _apply_strips(amount: float) -> void:
	if _strip_material != null:
		_strip_material.emission_energy_multiplier = 0.06 + amount * 1.5
	for light: OmniLight3D in _strip_lights:
		if light != null and is_instance_valid(light):
			light.light_energy = amount * Balance.JUNCTION_LIGHT_ENERGY
