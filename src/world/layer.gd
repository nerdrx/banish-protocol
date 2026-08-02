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
## Wall-clock start of the current build, for the census line's `build=` figure.
var _build_started_usec: int = 0


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

	# The alert belongs to the layer being torn down, not to the one being built.
	# `ProcLayerBuilder._build_content` already resets the kit's shared uniform on
	# every build, with a comment saying why — but `_alert` itself survived, and
	# `_process` re-applied it on the very next frame. Descending mid-PURGE
	# (alert ~1.0, i.e. the dramatic escape, i.e. the case that actually happens)
	# ramps down at 1.6/s = 0.625 s, against a 0.35 s hold, so the *new* layer
	# faded in visibly red with its accents dimmed for its first ~0.28 s.
	_alert = 0.0

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
		_build_started_usec = Time.get_ticks_usec()
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
	# M6: hand the layer to the HauntDirector too, on every peer. It only PACES the
	# hunt host-side (spawns ride the antivirus director above); a client's copy
	# drives the local presentation. Null graph (test layer) leaves it dormant.
	Haunt.begin(null if built == null else built.graph, Run.layer_number, _director)

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
	var decay: String = ""
	if _builder != null and is_instance_valid(_builder) and not Run.use_test_layer:
		var census: PackedInt32Array = _builder.decay_census
		var total: int = 0
		for kind: int in census:
			total += kind
		decay = " decay=%d(displaced %d, shimmer %d, dead %d, arcing %d)" % [
			total, census[1], census[2], census[3], census[4]]
	# M4.8's density pass is the single biggest perf risk in the project, so its
	# instance counts and the number of draw calls it was batched into go in the
	# same line the light and decal census have been in since M3.7.
	var clutter: String = ""
	if built != null and is_instance_valid(built):
		clutter = built.clutter_note
	# Build time, in the same line, since M4.8: a descent hides the build behind a
	# 1.8 s fade, and a density pass that quietly pushed generation past that
	# would turn every drop shaft in the game into a hitch. This is the number
	# that says whether it did.
	var elapsed: float = 0.0 if _build_started_usec <= 0 \
			else float(Time.get_ticks_usec() - _build_started_usec) / 1000.0
	print("[Layer] built %s  nodes=%d lights=%d shadowed=%d decals=%d build=%.0fms%s%s" % [
		"layer %d: hand-authored test layer" % Run.layer_number if Run.use_test_layer
				else LayerParams.describe(Run.layer_number),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), lights, shadowed,
		decals, elapsed, decay, clutter])


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


# ---------------------------------------------------------------- depth bands --
#
# DESIGN.md's aesthetic gradient has a colour axis as well as a brightness one:
# "surface rings are clean modern datacenter-brutalism... deeper rings decay into
# legacy architecture". M3.7 shipped the brightness half (LayerParams'
# `ambient_scale` and `light_scale`) and left every ring the same colour, so a
# layer-16 corridor was a layer-2 corridor with the dimmer down.
#
# Three anchors, lerped by layer number, and nothing else changes: no new assets,
# no per-band lighting rigs, no material swaps. It is the cheapest possible
# version of the biome-band backlog in DESIGN.md's M7 candidates, and it exists
# mostly to answer one question the player should never have to ask out loud —
# *how deep am I?* — without printing a number at them.
#
#   SURFACE   clean and cold. Public-facing infrastructure, still maintained,
#             lit blue-white because somebody specified it that way.
#   DRAINED   the teal bleeds out toward grey. Nothing is hostile yet; it is
#             simply that nobody has been down here in a long time and the
#             colour has gone out of the place.
#   HOSTILE   warm undertones creeping into the shadows. Not red — red is
#             reserved for the alert state and stays reserved — but the blacks
#             stop being blue-black and start being brown-black, which the eye
#             reads as *wrong* long before it can say why.
#
# The three ambients are within 15% of each other in luminance on purpose. This
# is a hue shift, not an exposure change: the darkness law is owned by
# `ambient_scale` and a grading pass is not allowed to quietly renegotiate it.
const GRADE_AMBIENT: Array[Color] = [
	Color(0.075, 0.115, 0.200),
	Color(0.086, 0.104, 0.122),
	Color(0.116, 0.094, 0.081),
]
const GRADE_FOG: Array[Color] = [
	Color(0.32, 0.40, 0.50),
	Color(0.36, 0.39, 0.41),
	Color(0.47, 0.39, 0.34),
]
const GRADE_BACKGROUND: Array[Color] = [
	Color(0.0030, 0.0042, 0.0068),
	Color(0.0034, 0.0038, 0.0042),
	Color(0.0050, 0.0038, 0.0031),
]
## Saturation drains through the middle band and comes fractionally back in the
## deep one — the warmth has to be visible, and a fully desaturated frame cannot
## carry a hue shift at all.
const GRADE_SATURATION: Array[float] = [1.06, 0.88, 0.97]
## Where each anchor lands. Layer 1 is pure surface; 10 is fully drained; 16 and
## below is fully hostile. Between them it is a straight lerp, so a descent is a
## slow slide rather than three steps.
const GRADE_DRAINED_LAYER: float = 10.0
const GRADE_HOSTILE_LAYER: float = 16.0

## M4.95: the depth-band 3D LUTs, one per grade anchor (surface / mid / deep),
## matching DESIGN.md's aesthetic gradient and the limbo-concepts biome study —
## surface cold-clean → mid teal-drain → deep warm-wrong. Selected and cross-faded
## exactly like the ambient/fog anchors above (same `low`/`mix`), so the grade
## slides down the descent instead of cutting. These REPLACE the Environment
## adjustment grade, which is disabled in layer_environment.tres.
const GRADE_LUTS: Array[String] = [
	"res://assets/luts/lut_surface.png",
	"res://assets/luts/lut_mid.png",
	"res://assets/luts/lut_deep.png",
]
## Per-band cinematic exposure offset in stops (INTEGRATION2 §7): a touch up at the
## clean surface, drifting down into the deep, so the world dims further as it goes
## wrong. Measured alone this pass makes the game DARKER, which is why it ships.
const GRADE_EXPOSURE: Array[float] = [0.10, -0.06, -0.22]
## The iris-hunting breath, ±this many stops at 0.055 Hz. Sub-threshold; unscaled.
const GRADE_EXPOSURE_BREATHE: float = 0.035

static var _lut_textures: Array[Texture2D] = []


## The three depth-band LUTs, loaded once and shared across every layer.
static func _lut(index: int) -> Texture2D:
	if _lut_textures.is_empty():
		for path: String in GRADE_LUTS:
			_lut_textures.append(load(path) as Texture2D)
	return _lut_textures[clampi(index, 0, _lut_textures.size() - 1)]


## 0..2 position along the three grade anchors.
static func grade_position(layer: int) -> float:
	var n: float = float(maxi(layer, 1))
	if n <= GRADE_DRAINED_LAYER:
		return clampf(inverse_lerp(1.0, GRADE_DRAINED_LAYER, n), 0.0, 1.0)
	return 1.0 + clampf(inverse_lerp(
			GRADE_DRAINED_LAYER, GRADE_HOSTILE_LAYER, n), 0.0, 1.0)


## Ambient falls with depth (LayerParams) and its *colour* shifts with it
## (GRADE_*). The environment resource is duplicated so a runtime tweak never
## writes back to the .tres shared by every layer.
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

	var band: float = grade_position(Run.layer_number)
	var low: int = 0 if band < 1.0 else 1
	var mix: float = band if band < 1.0 else band - 1.0
	scaled.ambient_light_color = GRADE_AMBIENT[low].lerp(GRADE_AMBIENT[low + 1], mix)
	scaled.volumetric_fog_albedo = GRADE_FOG[low].lerp(GRADE_FOG[low + 1], mix)
	scaled.background_color = GRADE_BACKGROUND[low].lerp(GRADE_BACKGROUND[low + 1], mix)
	# M4.95: the Environment adjustment grade is disabled (the depth-band LUTs own
	# it now), so the old per-band adjustment_saturation is gone from here — its job
	# moved into the LUTs. GRADE_SATURATION is kept above only as a record of it.
	_world_environment.environment = scaled

	# Drive the post shader's depth-band LUT + cinematic exposure off the SAME band
	# the ambient/fog anchors use. Guarded: the authored test layer and a very early
	# frame can reach here before the Post ColorRect's material is resolved.
	var grade: ShaderMaterial = _grade.material as ShaderMaterial
	if grade != null:
		grade.set_shader_parameter("lut_a", _lut(low))
		grade.set_shader_parameter("lut_b", _lut(low + 1))
		grade.set_shader_parameter("lut_mix", mix)
		grade.set_shader_parameter("lut_amount", 1.0)
		grade.set_shader_parameter("exposure",
				lerpf(GRADE_EXPOSURE[low], GRADE_EXPOSURE[low + 1], mix))
		grade.set_shader_parameter("exposure_breathe", GRADE_EXPOSURE_BREATHE)


# ------------------------------------------------------------------ descent --

func _on_descent_started(next_layer: int) -> void:
	# Explicit, and first: everything hostile has to be despawned before the
	# geometry it is pathing through is freed. This used to be a second subscriber
	# on the same signal, correct only because Godot fires slots in connection
	# order and a child's `_ready` happens to run before its parent's.
	if _director != null and is_instance_valid(_director):
		_director.clear()
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
