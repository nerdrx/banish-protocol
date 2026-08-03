class_name InjectionDial
extends Interactable
## The injection selector — how deep the crew is going, as a machine.
##
## DESIGN.md's hub backlog retires the menu dropdown: *"walk to the injection rig
## to pick a backdoor and launch"*. This is the picking half, standing at the
## rig's shoulder so that choosing the depth and committing to it happen in the
## same two paces.
##
## It is a **dial with stops**, not a list. Layer 1 is always a stop; the ring
## below the crew's shallowest installed backdoor is the other. `Run.dial` is
## host-validated against exactly that set (`Run.injection_choices`), so what the
## dial can be turned to and what the rig will accept are the same question asked
## once — which is how "the crew has a backdoor that one of us hasn't installed"
## stops being a disconnect and becomes a stop that is simply not on the dial.
##
## The menu's dropdown survives as DESIGN.md's *thin fallback*: it is the value
## the host walks in holding. Everything after boot happens here.

const FACE_COLOUR: Color = Color(1.0, 0.66, 0.28)
const LOCKED_COLOUR: Color = Color(0.44, 0.5, 0.58)

## Quick. This is a switch, not a commitment — the commitment is eight metres away
## with a countdown on it.
const TURN_TIME: float = 0.3

## How many depth pips the face carries. Sized to the deepest injection the
## backdoor rule can produce in a session anybody has played to; past this the
## numeral carries it, which it does anyway (colour is never the only channel).
const PIP_COUNT: int = 8

var _face_material: StandardMaterial3D = null
var _pip_materials: Array[StandardMaterial3D] = []
var _light: OmniLight3D = null


static func create(where: Vector3) -> InjectionDial:
	var dial: InjectionDial = InjectionDial.new()
	dial.name = "InjectionDial"
	dial.position = where
	dial.channel_time = TURN_TIME
	dial._assemble()
	return dial


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# A waist-high pedestal with a canted face — crew hardware, so it is a bolted
	# lump with a readable panel on top rather than one of MOTHER's flush slabs.
	_add_mesh(Vector3(0.0, 0.5, 0.0), Vector3(0.9, 1.0, 0.7), casing)
	_add_mesh(Vector3(0.0, 0.06, 0.0), Vector3(1.1, 0.12, 0.9), casing)
	_face_material = _emissive(FACE_COLOUR, 0.85)
	var face: MeshInstance3D = _add_mesh(Vector3(0.0, 1.06, -0.06),
			Vector3(0.76, 0.04, 0.52), _face_material)
	face.rotation.x = -0.5

	# A row of depth pips beside the numeral. SAFETY LAW, the colour-is-never-the-
	# only-channel half: the depth is a COUNT of lit pips as well as a number, so
	# "how deep" survives both colour blindness and a screenshot at ten metres.
	for i: int in PIP_COUNT:
		var pip_material: StandardMaterial3D = _emissive(FACE_COLOUR, 0.9)
		_pip_materials.append(pip_material)
		var pip: MeshInstance3D = _add_mesh(
				Vector3(-0.3 + float(i) * 0.086, 1.14, 0.16),
				Vector3(0.05, 0.02, 0.09), pip_material)
		pip.rotation.x = -0.5

	_light = OmniLight3D.new()
	_light.name = "DialGlow"
	_light.position = Vector3(0.0, 1.35, 0.0)
	_light.light_color = FACE_COLOUR
	_light.light_energy = 0.55
	_light.omni_range = 3.2
	_light.omni_attenuation = 0.9
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(1.2, 1.5, 1.0), Vector3(0.0, 0.8, 0.0))


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
	material.albedo_color = colour.darkened(0.7)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.45
	material.disable_receive_shadows = true
	return material


# ------------------------------------------------------------- interactable --

## The stop after the current one, wrapping. One key, one machine, one direction —
## a dial with two stops on it does not need a second verb.
func _next_choice() -> int:
	var choices: Array[int] = Run.injection_choices()
	if choices.is_empty():
		return 1
	var index: int = choices.find(Run.injection_layer)
	return choices[(index + 1) % choices.size()]


func prompt() -> String:
	if Run.injecting:
		return "INJECTION COMMITTED  ·  LAYER %02d" % Run.injection_layer
	if Run.injection_choices().size() <= 1:
		return "INJECTION POINT  ·  LAYER 01  ·  NO BACKDOOR INSTALLED"
	return "HOLD E  ·  SET LAYER %02d" % _next_choice()


func prompt_title() -> String:
	if Run.injection_choices().size() <= 1:
		return "INJECTION  ·  LAYER %02d" % Run.injection_layer
	return "INJECTION  ·  LAYER %02d  →  %02d" % [Run.injection_layer, _next_choice()]


func prompt_glyph() -> String:
	return "◆"


func prompt_height() -> float:
	return 1.7


## One stop is not a choice; do not offer a dial that cannot turn. (Same rule the
## menu's dropdown follows, moved to where the dial is.)
func available() -> bool:
	return not Run.injecting and not Run.descending \
			and Run.injection_choices().size() > 1


func complete() -> void:
	Run.request_dial(_next_choice())


func _process(_delta: float) -> void:
	var live: bool = available()
	var colour: Color = FACE_COLOUR if live else LOCKED_COLOUR
	_face_material.emission = colour
	_light.light_color = colour
	_light.light_energy = 0.55 if live else 0.25
	# Pips light up to the dialled depth, capped at the face's own width. Steady —
	# there is nothing here that needs to flash, so nothing here does.
	for i: int in _pip_materials.size():
		var lit: bool = i < mini(Run.injection_layer, PIP_COUNT)
		_pip_materials[i].emission = colour
		_pip_materials[i].emission_energy_multiplier = 0.9 if lit else 0.05
