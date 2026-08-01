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
## Every Compiler on the layer (M4). Empty on the hand-authored test layer.
## `--goto compiler` walks to the first one, which on a backdoor layer is the
## hidden one rather than the sanctuary's.
var compiler_positions: Array[Vector3] = []
## Where the layer's data vault is, for `--goto vault`, and its first Scrubber
## nest, for `--goto nest` — the two rooms M3's verification runs care about.
var vault_position: Vector3 = Vector3.ZERO
var nest_position: Vector3 = Vector3.ZERO
## One end of the layer's longest corridor, and the yaw that looks down it.
## M3.7 added this because a corridor is the shot that judges the architecture
## kit — it is the only place the player sees a wall from three metres, and it is
## what the README screenshot has to be.
var corridor_position: Vector3 = Vector3.ZERO
var corridor_yaw: float = 0.0

var _builder: GeometryKit = null
var _authored: bool = false
var _fade: float = 0.0
var _fade_target: float = 0.0
var _fade_rate: float = 1.0

## Red-alert, 0..1. One number turns the whole layer hostile: the kit's surface
## materials tint and their emissive flow reverses, the LightRig recolours, and
## the post grade pushes red. DESIGN.md reserves red for hostile processes, so
## this is the only thing in the game allowed to look like this.
var _alert: float = 0.0
## Damage kick for the post shader's `stress` uniform. M2 shipped the uniform and
## never drove it; M3.7 hooks it to the same signal the screen shake uses.
var _stress: float = 0.0
## M3.8's short, hard flinch on the same signal — the frame's half of what the
## HUD does to itself. Decays over `UiFx.GLITCH_TIME` rather than over a second,
## so the two land together and let go together.
var _glitch: float = 0.0


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
	Run.damaged.connect(_on_damaged)

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
		compiler_positions = graph.compiler_points
		vault_position = graph.centre_of(graph.vault_index)
		nest_position = graph.centre_of(
				graph.nest_rooms[0] if not graph.nest_rooms.is_empty() else -1)
		_find_hero_corridor(graph)

	add_child(_builder)  # GeometryKit._ready() runs build() synchronously.
	_apply_environment()

	# Antivirus last: the taps it listens to and the rooms it paths through both
	# have to exist first. The host buys the layer's processes here; a client
	# only records the layout its spawn packets will be interpreted against.
	var built: ProcLayerBuilder = _builder as ProcLayerBuilder
	_director.begin(null if built == null else built.graph, Run.layer_number)

	# Node count is the cheap canary for the descent leaking geometry: it must
	# come back to roughly the same number on every layer, not climb. Since M3.7
	# the light census sits beside it: the look-dev rig spends four fixtures where
	# M2 spent one, and "how many of those cast shadows" is the number that
	# decides whether a four-player layer holds 60 fps.
	var lights: int = 0
	var shadowed: int = 0
	if _builder != null and is_instance_valid(_builder):
		for node: Node in _builder.find_children("*", "Light3D", true, false):
			lights += 1
			if (node as Light3D).shadow_enabled:
				shadowed += 1
	var decals: int = 0
	if _builder != null and is_instance_valid(_builder):
		decals = _builder.find_children("*", "Decal", true, false).size()
	print("[Layer] built %s  nodes=%d lights=%d shadowed=%d decals=%d" % [
		"layer %d: hand-authored test layer" % Run.layer_number if Run.use_test_layer
				else LayerParams.describe(Run.layer_number),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), lights, shadowed,
		decals])


## The longest corridor on the layer, entered from one end looking down it.
func _find_hero_corridor(graph: LayerGraph) -> void:
	corridor_position = Vector3.ZERO
	corridor_yaw = 0.0
	var best: float = -1.0
	for corridor: Dictionary in graph.corridors:
		var rect: Rect2 = GeometryKit.kit_corridor_rect(corridor)
		var length: float = maxf(rect.size.x, rect.size.y)
		if length <= best:
			continue
		best = length
		var mid: Vector2 = rect.position + rect.size * 0.5
		if String(corridor["axis"]) == "z":
			# Stood just inside the north end, facing south (+Z).
			corridor_position = Vector3(mid.x, 0.0, rect.position.y + 1.6)
			corridor_yaw = PI
		else:
			corridor_position = Vector3(rect.position.x + 1.6, 0.0, mid.y)
			corridor_yaw = -PI * 0.5


## Frees flares and dropped bundles. Immediate rather than deferred, for the
## same reason the geometry is detached before it is freed: nothing from the
## layer above may still be standing in the layer below.
func _clear_dynamic() -> void:
	for child: Node in _dynamic.get_children():
		_dynamic.remove_child(child)
		child.queue_free()


func _adopt_test_layer_furniture() -> void:
	shaft_position = LayerBuilder.TEST_SHAFT
	# The hand-authored greybox predates every M3/M4 fixture and has none of them.
	compiler_positions = []
	backdoor_position = Vector3.ZERO
	uplink_position = Vector3.ZERO
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

func _on_damaged(_from: Vector3) -> void:
	_stress = minf(_stress + 0.55, 1.0)
	_glitch = 1.0


## How hostile the layer currently is. Read off replicated Sentinel state rather
## than pushed by an RPC: `sync_state` is already on the wire because the sweep
## has to be in the same place on every screen, so a purging Sentinel turns the
## architecture red on all four clients for free.
##
## Scoped to the Sentinels that can actually see you — a purge two rooms away is
## the layer's problem, not yours — so the alert reads as *this room is hunting*
## rather than as a global difficulty light.
func _alert_amount() -> float:
	var viewer: Node = Net.get_player(Net.local_id())
	var here: Node3D = viewer as Node3D
	var worst: float = 0.0
	for node: Node in get_tree().get_nodes_in_group(Antivirus.GROUP):
		var boss: Sentinel = node as Sentinel
		if boss == null or not is_instance_valid(boss):
			continue
		var level: float = 0.0
		match int(boss.sync_state):
			int(Sentinel.State.SCAN):
				level = 0.35
			int(Sentinel.State.PURGE):
				level = 1.0
		if level <= 0.0:
			continue
		if here != null and is_instance_valid(here):
			# Falls off over the Sentinel's own leash: inside its vault the room
			# is red, a corridor away it is a rumour.
			var reach: float = Balance.SENTINEL_LEASH + 12.0
			level *= clampf(1.0 - here.global_position.distance_to(
					boss.global_position) / reach, 0.0, 1.0)
		worst = maxf(worst, level)
	return worst


func _process(delta: float) -> void:
	# The alert ramps rather than snapping. A hard cut to red reads as a bug; a
	# 0.6 s ramp reads as the room deciding something about you.
	_alert = move_toward(_alert, _alert_amount(), delta * 1.6)
	_stress = maxf(_stress - delta * 1.1, 0.0)
	# `--hud-state damage` pins the flinch so the shutter cannot miss a state
	# that is, by design, a fifth of a second long.
	_glitch = 0.8 if Debug.hud_state == "damage" \
			else maxf(_glitch - delta / UiFx.GLITCH_TIME, 0.0)
	KitLib.set_alert(_alert)
	if _builder != null and is_instance_valid(_builder):
		LightRig.set_alert(_builder, _alert)

	var material: ShaderMaterial = _grade.material as ShaderMaterial
	if material == null:
		return
	_fade = move_toward(_fade, _fade_target, _fade_rate * delta)
	var degradation: float = Run.degradation()
	material.set_shader_parameter("fade", _fade)
	material.set_shader_parameter("degradation", degradation)
	material.set_shader_parameter("stress", _stress)
	material.set_shader_parameter("glitch", _glitch)
	material.set_shader_parameter("alert", _alert)
	# The v2 master. Grain, aberration, vignette and corner desaturation all ride
	# it, so a starving or bleeding process does not just get a glitch overlay —
	# the whole grade leans on it. Capped well under the shader's 2.0 ceiling:
	# past ~1.6 the image stops being a game and starts being an effect.
	material.set_shader_parameter("intensity", 1.0 + degradation * 0.5 + _stress * 0.15)


# ------------------------------------------------------------------- lookup --

func get_spawn_point(index: int) -> Transform3D:
	if _builder != null and is_instance_valid(_builder):
		return _builder.get_spawn_point(index)
	return Transform3D.IDENTITY
