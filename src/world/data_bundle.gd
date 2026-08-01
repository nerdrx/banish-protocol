class_name DataBundle
extends Node3D
## A pile of data on the floor that somebody has to walk over to claim. Two
## things make one: a corrupted crewmate spilling their whole buffer, and a dead
## Sentinel spilling what it was guarding.
##
## DESIGN.md: buffered data is lost on *deletion*, not on going down — so a
## bundle is the crew's second chance at the haul, and the reason walking back
## into the room that just corrupted someone is a real decision.
##
## Unlike shards this is not seeded content: it appears where a run went wrong,
## or where a fight was won, so it is created by an RPC from Run on every peer
## and collected host-side.

const COLOUR: Color = Color(1.0, 0.72, 0.3)
const REST_HEIGHT: float = 0.55

var bundle_id: int = 0
var amount: int = 0

var _material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _shell: Node3D = null
var _taken: bool = false
var _fade: float = 1.0


static func create(id: int, where: Vector3, shards: int) -> DataBundle:
	var bundle: DataBundle = DataBundle.new()
	bundle.name = "DataBundle%d" % id
	bundle.bundle_id = id
	bundle.amount = shards
	bundle.position = Vector3(where.x, REST_HEIGHT, where.z)
	bundle._assemble()
	return bundle


func _assemble() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = COLOUR.darkened(0.55)
	_material.emission_enabled = true
	_material.emission = COLOUR
	_material.emission_energy_multiplier = 2.2
	_material.roughness = 0.4
	_material.disable_receive_shadows = true

	# A loose cluster rather than one prism: a bundle should read as *someone's
	# whole buffer* spilled out, not as a bigger shard.
	_shell = Node3D.new()
	add_child(_shell)
	for i: int in 5:
		var angle: float = TAU * float(i) / 5.0
		var mesh: MeshInstance3D = MeshInstance3D.new()
		var prism: PrismMesh = PrismMesh.new()
		prism.size = Vector3(0.26, 0.4, 0.26)
		mesh.mesh = prism
		mesh.position = Vector3(cos(angle) * 0.32, sin(float(i) * 1.7) * 0.12, sin(angle) * 0.32)
		mesh.rotation = Vector3(0.0, angle, 0.35)
		mesh.material_override = _material
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_shell.add_child(mesh)

	_light = OmniLight3D.new()
	_light.name = "BundleGlow"
	_light.light_color = COLOUR
	_light.light_energy = 2.0
	_light.omni_range = 8.0
	_light.omni_attenuation = 0.95
	_light.light_volumetric_fog_energy = 2.0
	_light.shadow_enabled = false
	add_child(_light)


func _ready() -> void:
	add_to_group("data_bundles")
	Run.bundle_taken.connect(_on_bundle_taken)


func _process(delta: float) -> void:
	if _taken:
		_fade = maxf(_fade - delta * 3.0, 0.0)
		scale = Vector3.ONE * _fade
		_light.light_energy = 2.0 * _fade * 2.5
		if _fade <= 0.001:
			queue_free()
		return

	var t: float = float(Time.get_ticks_msec()) / 1000.0
	_shell.rotation.y = t * 0.8
	position.y = REST_HEIGHT + sin(t * 1.3) * 0.09
	_material.emission_energy_multiplier = 2.0 + sin(t * 2.6) * 0.5

	if not multiplayer.is_server():
		return
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not Run.is_running(peer):
			continue
		var node: Node = Net.get_player(peer)
		if node == null or not is_instance_valid(node):
			continue
		if (node as Node3D).global_position.distance_to(global_position) \
				<= Balance.BUNDLE_PICKUP_RADIUS:
			Run.take_bundle(bundle_id, peer)
			return


func _on_bundle_taken(id: int, _peer_id: int) -> void:
	if id != bundle_id:
		return
	_taken = true
