class_name DataShard
extends Node3D
## A fragment of MOTHER's data, lying where the generator dropped it.
##
## DESIGN.md "Data (salvage)": glowing shard pickups, auto-magnet on proximity,
## buffered weight slows you slightly. Placement is seeded (LayerGraph), so every
## peer builds the same shards in the same places and only the *taking* crosses
## the wire — an index and a peer id.
##
## The magnet is cosmetic and runs everywhere; the absorb is a host decision, so
## two players reaching for the same shard can never both bank it.

const SPIN_RATE: float = 1.9
const BOB_RATE: float = 1.6
const BOB_HEIGHT: float = 0.14
const REST_HEIGHT: float = 0.75

const COLOUR: Color = Color(0.42, 0.95, 1.0)

var shard_index: int = 0
var value: int = 10

var _home: Vector3 = Vector3.ZERO
var _material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _core: MeshInstance3D = null
var _taken: bool = false
var _absorb: float = 0.0


static func create(index: int, where: Vector3, worth: int) -> DataShard:
	var shard: DataShard = DataShard.new()
	shard.name = "DataShard%d" % index
	shard.shard_index = index
	shard.value = worth
	shard.position = where + Vector3.UP * REST_HEIGHT
	shard._home = shard.position
	shard._assemble()
	return shard


func _assemble() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = COLOUR.darkened(0.5)
	_material.emission_enabled = true
	_material.emission = COLOUR
	# Bright enough to spot across a dark room, dim enough that a vault full of
	# them does not read as a wall of white once the glow pass is applied.
	_material.emission_energy_multiplier = 1.5
	_material.roughness = 0.25
	_material.disable_receive_shadows = true

	# A prism, not a cube: shards must read as *fragments* at a glance, and an
	# octahedron on its point is the cheapest silhouette that does it.
	_core = MeshInstance3D.new()
	var prism: PrismMesh = PrismMesh.new()
	prism.size = Vector3(0.34, 0.5, 0.34)
	_core.mesh = prism
	_core.material_override = _material
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_core)

	var under: MeshInstance3D = MeshInstance3D.new()
	var lower: PrismMesh = PrismMesh.new()
	lower.size = Vector3(0.34, 0.5, 0.34)
	under.mesh = lower
	under.rotation = Vector3(PI, 0.0, 0.0)
	under.material_override = _material
	under.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_core.add_child(under)

	_light = OmniLight3D.new()
	_light.name = "ShardGlow"
	_light.light_color = COLOUR
	_light.light_energy = 0.7
	_light.omni_range = 3.4
	_light.omni_attenuation = 1.4
	_light.light_volumetric_fog_energy = 1.4
	_light.shadow_enabled = false
	add_child(_light)


func _ready() -> void:
	add_to_group("data_shards")
	# Rebuilt geometry (a mid-layer rejoin) must not resurrect a taken shard.
	if Run.is_shard_taken(shard_index):
		_vanish()
	Run.shard_taken.connect(_on_shard_taken)


func _process(delta: float) -> void:
	if _taken:
		# Collapse into the buffer: shrink and brighten over a few frames.
		_absorb = maxf(_absorb - delta * 3.5, 0.0)
		scale = Vector3.ONE * _absorb
		_light.light_energy = 0.7 * _absorb * 3.0
		if _absorb <= 0.001:
			visible = false
			set_process(false)
		return

	var t: float = float(Time.get_ticks_msec()) / 1000.0
	_core.rotation.y = t * SPIN_RATE
	var target: Vector3 = _home + Vector3.UP * sin(t * BOB_RATE) * BOB_HEIGHT

	# Magnet. Cosmetic on every peer — the host's copy is the one that decides
	# the shard has actually been absorbed.
	var claimant: Node3D = _nearest_carrier()
	if claimant != null:
		var pull: Vector3 = claimant.global_position + Vector3.UP * 1.0
		target = target.lerp(pull, 0.55)
		_material.emission_energy_multiplier = 2.6
	else:
		_material.emission_energy_multiplier = 1.5

	global_position = global_position.lerp(target, 1.0 - exp(-7.0 * delta))

	if claimant == null or not multiplayer.is_server():
		return
	if global_position.distance_to(claimant.global_position + Vector3.UP * 1.0) \
			<= Balance.SHARD_ABSORB_RADIUS:
		Run.take_shard(shard_index, int(String(claimant.name)), value)


## Closest player whose buffer this shard would fall into. Corrupted and
## decompiled crew do not attract salvage.
func _nearest_carrier() -> Node3D:
	var best: Node3D = null
	var best_distance: float = Balance.SHARD_MAGNET_RADIUS
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not Run.is_running(peer):
			continue
		var node: Node = Net.get_player(peer)
		if node == null or not is_instance_valid(node):
			continue
		var body: Node3D = node as Node3D
		var distance: float = body.global_position.distance_to(global_position)
		if distance < best_distance:
			best_distance = distance
			best = body
	return best


func _on_shard_taken(index: int, _peer_id: int, _worth: int) -> void:
	if index != shard_index or _taken:
		return
	_taken = true
	_absorb = 1.0


func _vanish() -> void:
	_taken = true
	_absorb = 0.0
	visible = false
	set_process(false)
