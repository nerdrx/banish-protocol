class_name Layer
extends Node3D
## Root of a playable security layer. Owns the replication rig (spawner + player
## container), generates the layer's geometry, and rebuilds it on descent.
##
## Every peer loads this scene locally; only spawned player nodes are replicated
## across the wire. Geometry is *never* replicated — each peer generates it from
## (run_seed, layer_number), both of which the host pushes before the first spawn
## packet. That is the whole reason `Run.configured` exists: building from a
## stale or absent seed would put the crew in different buildings.
##
## Build order on a client is load-bearing:
##   Layer._ready -> Net.world_ready -> _register_crew -> host replies with the
##   config -> Run.config_changed -> geometry -> (host's spawn packet arrives)
## Both messages are reliable on the same channel, so the floor always exists
## before the avatar standing on it does.

const DESCENT_SETTLE_HEIGHT: float = 0.35

@onready var _spawner: MultiplayerSpawner = $PlayerSpawner
@onready var _world_environment: WorldEnvironment = $WorldEnvironment
@onready var _grade: ColorRect = $Post/Grade
@onready var _director: AntivirusDirector = $AntivirusDirector
## Flares and dropped bundles. Not seeded content, so it is cleared by hand on
## every rebuild rather than dying with the geometry.
@onready var _dynamic: Node3D = $Dynamic

## Where Run measures the crew muster from. Read by name from the autoload, so
## it stays a plain property.
var shaft_position: Vector3 = Vector3.ZERO
var siphon_positions: Array[Vector3] = []
var siphon_approaches: Array[Vector3] = []
## Backdoor layers only; Vector3.ZERO elsewhere. Read by the debug teleports and
## by Run when it decides who was stood on the pad.
var backdoor_position: Vector3 = Vector3.ZERO
var uplink_position: Vector3 = Vector3.ZERO
## Where the layer's data vault is, for `--goto vault`, and its first Scrubber
## nest, for `--goto nest` — the two rooms M3's verification runs care about.
var vault_position: Vector3 = Vector3.ZERO
var nest_position: Vector3 = Vector3.ZERO

var _builder: GeometryKit = null
var _authored: bool = false
var _fade: float = 0.0
var _fade_target: float = 0.0
var _fade_rate: float = 1.0


func _ready() -> void:
	add_to_group("layer")

	# test_layer.tscn ships a LayerBuilder child; the procedural scene does not.
	var authored: Node = get_node_or_null("LayerBuilder")
	if authored != null:
		_builder = authored as GeometryKit
		_authored = true
		_adopt_test_layer_furniture()

	Run.config_changed.connect(_on_config_changed)
	Run.descent_started.connect(_on_descent_started)

	if not Net.is_online:
		# Running the scene straight from the editor: nobody is going to tell us
		# what to build, so roll our own.
		Run.begin_offline()
	if Run.configured:
		_rebuild()

	Net.world_ready(self, _spawner)


func _on_config_changed() -> void:
	_rebuild()


# -------------------------------------------------------------------- build --

func _rebuild() -> void:
	if _authored:
		_apply_environment()
		return

	# Detach before freeing: queue_free() only lands at the end of the frame, and
	# an old layer's colliders overlapping the new one for even one frame is
	# enough to launch a player through a wall.
	if _builder != null and is_instance_valid(_builder):
		remove_child(_builder)
		_builder.queue_free()
		_builder = null
	_clear_dynamic()

	if Run.use_test_layer:
		var authored: LayerBuilder = LayerBuilder.new()
		authored.name = "LayerBuilder"
		_builder = authored
		_adopt_test_layer_furniture()
	else:
		var graph: LayerGraph = LayerGraph.generate(Rng.run_seed, Run.layer_number)
		var procedural: ProcLayerBuilder = ProcLayerBuilder.create(graph)
		_builder = procedural
		shaft_position = graph.shaft_point
		siphon_positions = graph.siphon_points
		siphon_approaches = graph.siphon_approaches
		backdoor_position = graph.backdoor_point
		uplink_position = graph.uplink_point
		vault_position = graph.centre_of(graph.vault_index)
		nest_position = graph.centre_of(
				graph.nest_rooms[0] if not graph.nest_rooms.is_empty() else -1)

	add_child(_builder)  # GeometryKit._ready() runs build() synchronously.
	_apply_environment()

	# Antivirus last: the taps it listens to and the rooms it paths through both
	# have to exist first. The host buys the layer's processes here; a client
	# only records the layout its spawn packets will be interpreted against.
	var built: ProcLayerBuilder = _builder as ProcLayerBuilder
	_director.begin(null if built == null else built.graph, Run.layer_number)

	# Node count is the cheap canary for the descent leaking geometry: it must
	# come back to roughly the same number on every layer, not climb.
	print("[Layer] built %s  nodes=%d" % [
		"layer %d: hand-authored test layer" % Run.layer_number if Run.use_test_layer
				else LayerParams.describe(Run.layer_number),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])


## Frees flares and dropped bundles. Immediate rather than deferred, for the
## same reason the geometry is detached before it is freed: nothing from the
## layer above may still be standing in the layer below.
func _clear_dynamic() -> void:
	for child: Node in _dynamic.get_children():
		_dynamic.remove_child(child)
		child.queue_free()


func _adopt_test_layer_furniture() -> void:
	shaft_position = LayerBuilder.TEST_SHAFT
	siphon_positions = LayerBuilder.TEST_SIPHONS
	siphon_approaches = []
	for tap: Vector3 in LayerBuilder.TEST_SIPHONS:
		siphon_approaches.append(tap + Vector3(0.0, 0.0, 2.6))


## Ambient falls with depth (LayerParams). The environment resource is duplicated
## so a runtime tweak never writes back to the .tres shared by every layer.
func _apply_environment() -> void:
	var source: Environment = _world_environment.environment
	if source == null:
		return
	var scaled: Environment = source.duplicate() as Environment
	var params: Dictionary = LayerParams.of(Run.layer_number)
	# Cache the authored value once: duplicating a duplicate would compound the
	# scaling every time we descend.
	if not has_meta("base_ambient"):
		set_meta("base_ambient", source.ambient_light_energy)
	scaled.ambient_light_energy = float(get_meta("base_ambient")) \
			* float(params["ambient_scale"])
	_world_environment.environment = scaled


# ------------------------------------------------------------------ descent --

func _on_descent_started(next_layer: int) -> void:
	_descend(next_layer)


## Sequenced on every peer independently. No peer waits for another: the layer
## number came from the host and generation is deterministic, so a client that
## takes longer to build simply spends longer on black.
func _descend(next_layer: int) -> void:
	_fade_target = 1.0
	_fade_rate = 1.0 / maxf(Balance.DESCENT_FADE_OUT, 0.01)
	await get_tree().create_timer(Balance.DESCENT_FADE_OUT).timeout

	# Clearing the layer's per-layer state before building matters: fresh siphon
	# taps ask Run whether they are already spent as they enter the tree.
	Run.finish_descent(next_layer)
	_rebuild()
	_place_local_player()

	await get_tree().create_timer(Balance.DESCENT_HOLD).timeout
	_fade_target = 0.0
	_fade_rate = 1.0 / maxf(Balance.DESCENT_FADE_IN, 0.01)


## Each peer moves its own avatar. Movement is client-authoritative (M1), so the
## host telling a client where to stand would fight that client's own simulation;
## the spawn point is derived from replicated state instead, and every peer
## computes the same one.
func _place_local_player() -> void:
	var id: int = Net.local_id()
	var player: Node = Net.get_player(id)
	if player == null or not is_instance_valid(player):
		return
	var index: int = maxi(Net.crew.keys().find(id), 0)
	var point: Transform3D = get_spawn_point(index)
	var avatar: Player = player as Player
	if avatar == null:
		return
	avatar.teleport_to(point.origin + Vector3.UP * DESCENT_SETTLE_HEIGHT,
			point.basis.get_euler().y)


# --------------------------------------------------------------------- post --

func _process(delta: float) -> void:
	var material: ShaderMaterial = _grade.material as ShaderMaterial
	if material == null:
		return
	_fade = move_toward(_fade, _fade_target, _fade_rate * delta)
	material.set_shader_parameter("fade", _fade)
	material.set_shader_parameter("degradation", Run.degradation())


# ------------------------------------------------------------------- lookup --

func get_spawn_point(index: int) -> Transform3D:
	if _builder != null and is_instance_valid(_builder):
		return _builder.get_spawn_point(index)
	return Transform3D.IDENTITY
