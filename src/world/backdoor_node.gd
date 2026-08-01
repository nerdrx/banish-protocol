class_name BackdoorNode
extends Interactable
## The dormant maintenance node at the bottom of every 5th layer.
##
## DESIGN.md, "Why you can go deeper": rooting one installs a permanent backdoor,
## so future intrusions can inject straight to this depth. It is the single most
## consequential four seconds in a run, and it is built to look like it — dead
## grey metal that comes up gold and floods the sanctuary when it takes.
##
## State lives in Run (host-authoritative, replicated); this node is the face of
## it and reads that state on every peer.

const DORMANT_COLOUR: Color = Color(0.3, 0.34, 0.4)
const ROOTED_COLOUR: Color = Color(1.0, 0.76, 0.32)
const RING_COUNT: int = 3

var _core_material: StandardMaterial3D = null
var _ring_material: StandardMaterial3D = null
var _rings: Array[MeshInstance3D] = []
var _light: OmniLight3D = null
var _channel: float = 0.0
## Eases 0 -> 1 the moment the node roots, driving the flare-up.
var _install: float = 0.0


static func create(where: Vector3) -> BackdoorNode:
	var node: BackdoorNode = BackdoorNode.new()
	node.name = "BackdoorNode"
	node.position = where
	node.channel_time = Balance.BACKDOOR_CHANNEL_TIME
	node._assemble()
	return node


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	_add_mesh(Vector3(0.0, 0.14, 0.0), Vector3(3.2, 0.28, 3.2), casing)
	_add_mesh(Vector3(0.0, 1.5, 0.0), Vector3(1.5, 2.6, 1.5), casing)
	for corner: Vector3 in [Vector3(-1.25, 0.0, -1.25), Vector3(1.25, 0.0, -1.25),
			Vector3(-1.25, 0.0, 1.25), Vector3(1.25, 0.0, 1.25)]:
		_add_mesh(corner + Vector3(0.0, 0.9, 0.0), Vector3(0.22, 1.8, 0.22), casing)

	# The core is the readout: dead metal dormant, molten once rooted.
	_core_material = _emissive(DORMANT_COLOUR, 0.35)
	_add_mesh(Vector3(0.0, 1.6, 0.0), Vector3(0.9, 1.6, 0.9), _core_material)

	_ring_material = _emissive(DORMANT_COLOUR, 0.3)
	for i: int in RING_COUNT:
		_rings.append(_add_mesh(Vector3(0.0, 0.9 + float(i) * 0.7, 0.0),
				Vector3(1.9, 0.06, 1.9), _ring_material))

	_light = OmniLight3D.new()
	_light.name = "NodeGlow"
	_light.position = Vector3(0.0, 2.0, 0.0)
	_light.light_color = DORMANT_COLOUR
	_light.light_energy = 0.5
	_light.omni_range = 16.0
	_light.omni_attenuation = 0.8
	_light.light_volumetric_fog_energy = 2.4
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(2.6, 3.0, 2.6), Vector3(0.0, 1.5, 0.0))


func _ready() -> void:
	add_to_group("backdoor_nodes")
	if Run.backdoor_rooted:
		_install = 1.0


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


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	if Run.backdoor_rooted:
		return "BACKDOOR INSTALLED"
	return "HOLD E  ·  ROOT MAINTENANCE NODE"


func prompt_title() -> String:
	return "BACKDOOR INSTALLED" if Run.backdoor_rooted else "MAINTENANCE NODE"


func prompt_glyph() -> String:
	return "●"


func prompt_height() -> float:
	return 3.4


func available() -> bool:
	return not Run.backdoor_rooted


func complete() -> void:
	Run.request_root_backdoor()


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


func _process(delta: float) -> void:
	var rooted: bool = Run.backdoor_rooted
	if rooted:
		_install = minf(_install + delta * 0.8, 1.0)
		_channel = 0.0

	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var colour: Color = DORMANT_COLOUR.lerp(ROOTED_COLOUR, _install)
	# The overshoot is the moment: the node blows past its settled brightness as
	# it takes, then falls back to a steady burn.
	var flare: float = sin(clampf(_install, 0.0, 1.0) * PI) * 2.5
	var breath: float = 0.85 + sin(t * (1.4 + _install * 1.6)) * 0.15

	_core_material.emission = colour
	_core_material.emission_energy_multiplier = \
			(0.35 + _channel * 2.2 + _install * 2.4 + flare) * breath
	_ring_material.emission = colour
	_ring_material.emission_energy_multiplier = 0.3 + _channel * 1.4 + _install * 1.6
	_light.light_color = colour
	_light.light_energy = (0.5 + _channel * 3.0 + _install * 5.0 + flare * 3.0) * breath

	# Bands light bottom-up as the channel fills, then all hold once rooted.
	for i: int in _rings.size():
		var threshold: float = (float(i) + 0.5) / float(_rings.size())
		_rings[i].visible = rooted or _channel <= 0.001 or _channel >= threshold
