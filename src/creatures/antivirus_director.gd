class_name AntivirusDirector
extends Node
## Buys, builds and sweeps up MOTHER's antivirus for the current layer.
##
## Who decides what: *nothing about the roster of processes crosses the wire*.
## The positions are seeded content (LayerGraph resolves every nest and post, so
## a determinism dump covers them) and the purchase is a pure function of
## LayerParams.antivirus_budget, so every peer builds the same creatures in the
## same places at the same moment it builds the walls around them. Only what they
## are *doing* is replicated, through each creature's own synchronizer.
##
## That leaves exactly one thing a joining peer cannot work out for itself: which
## processes the crew has already killed. The host sends that list — a handful of
## node names — whenever the roster changes, and the joiner deletes them.
##
## Teardown is the other half of the job: a layer is rebuilt in place on every
## descent, so every creature has to be gone before the new one is written, and
## nothing may keep a reference to it afterwards. Because existence is local,
## each peer clears its own and no despawn packet can arrive late.

const SCRUBBER_COST: int = 1
const SENTINEL_COST: int = 3

## Where creatures are parented. A sibling of the geometry, so a rebuild does not
## take them with it — clearing them is explicit.
const CONTAINER: String = "../Antivirus"

var graph: LayerGraph = null

var _container: Node3D = null
var _layer_number: int = 0
var _log_clock: float = 0.0
## Host-side: names of everything killed on this layer, replayed to joiners.
var _dead: Array[String] = []


func _ready() -> void:
	add_to_group("antivirus_director")
	_container = get_node_or_null(CONTAINER) as Node3D
	Net.crew_changed.connect(_on_crew_changed)
	Run.descent_started.connect(_on_descent_started)
	set_process(Debug.log_ai)


func _on_crew_changed() -> void:
	for creature: Antivirus in _creatures():
		creature.refresh_visibility()
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server() and not _dead.is_empty():
		_reconcile.rpc(_dead)


# -------------------------------------------------------------------- layer --

## Called by the Layer on every peer once its geometry is standing. Builds the
## layer's antivirus locally from the seeded slots.
func begin(layout: LayerGraph, layer_number: int) -> void:
	graph = layout
	_layer_number = layer_number
	_dead.clear()
	_connect_taps()

	if graph == null or Debug.no_antivirus or _container == null:
		return
	_purchase()


## A drained tap is loud (DESIGN.md) — the signal M2 left dangling for exactly
## this. Connected on every peer; the handler is host-only because alerting is a
## simulation decision.
func _connect_taps() -> void:
	for node: Node in get_tree().get_nodes_in_group("siphon_taps"):
		var tap: SiphonTap = node as SiphonTap
		if tap == null or tap.antivirus_ping.is_connected(_on_tap_ping):
			continue
		tap.antivirus_ping.connect(_on_tap_ping)


func _on_tap_ping(where: Vector3) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	var reached: int = 0
	for creature: Antivirus in _creatures():
		creature.alert(where)
		reached += 1
	print("[AI] siphon ping at %s reached %d processes" % [
		str(where.snapped(Vector3.ONE * 0.1)), reached])


## Spends the layer's budget. Sentinels first — they are the expensive fixed
## defence and there are only ever one or two posts — then Scrubbers into every
## nest anchor the budget can afford. Pure: two peers running this on the same
## layer buy the same thing without talking to each other.
func _purchase() -> void:
	var params: Dictionary = LayerParams.of(_layer_number)
	var budget: int = int(params["antivirus_budget"])
	var sentinels: int = mini(int(params["sentinel_count"]), graph.sentinel_posts.size())

	var placed_sentinels: int = 0
	for i: int in sentinels:
		if budget < SENTINEL_COST:
			break
		budget -= SENTINEL_COST
		_build(true, i)
		placed_sentinels += 1

	var scrubbers: int = mini(budget, graph.scrubber_nests.size())
	for i: int in scrubbers:
		_build(false, i)

	print("[AI] layer %d antivirus: %d scrubbers, %d sentinels (budget %d)" % [
		_layer_number, scrubbers, placed_sentinels, int(params["antivirus_budget"])])


func _build(is_sentinel: bool, slot: int) -> void:
	var creature: Antivirus = Sentinel.new() if is_sentinel else Scrubber.new()
	# The layer number is in the name so a creature from the layer above can
	# never collide with one from the layer below during a rebuild, and so the
	# host's "already dead" list is meaningful on the receiving peer.
	creature.name = "%s_L%d_%d" % ["Sentinel" if is_sentinel else "Scrubber",
			_layer_number, slot]

	var points: Array[Vector3] = graph.sentinel_posts if is_sentinel else graph.scrubber_nests
	var rooms: Array[int] = graph.sentinel_post_rooms if is_sentinel \
			else graph.scrubber_nest_rooms
	creature.setup(slot, points[slot], rooms[slot], _layer_number, graph)
	creature.died.connect(_on_creature_died.bind(String(creature.name)))
	_container.add_child(creature)


func _on_creature_died(creature_name: String) -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	if not _dead.has(creature_name):
		_dead.append(creature_name)


## Host-side catch-up for a peer that built this layer after the crew had already
## cut through some of it. Idempotent, and sent to everyone rather than tracking
## who is new — it is a few strings.
@rpc("authority", "call_remote", "reliable")
func _reconcile(dead: Array) -> void:
	if _container == null:
		return
	for entry: String in dead:
		var node: Node = _container.get_node_or_null(NodePath(entry))
		if node != null and is_instance_valid(node):
			node.queue_free()


# ----------------------------------------------------------------- teardown --

## Descent starts a rebuild of the whole layer. Everything hostile has to be gone
## before the new geometry is written, or a Scrubber ends up hunting through
## walls that no longer exist. Every peer clears its own, so nothing is in flight.
func _on_descent_started(_next_layer: int) -> void:
	clear()


func clear() -> void:
	var removed: int = 0
	for creature: Antivirus in _creatures():
		creature.despawn()
		removed += 1
	_dead.clear()
	if removed > 0:
		print("[AI] despawned %d processes" % removed)


## Live creatures, already filtered for freed nodes — every sweep in this file
## runs during teardown at some point.
func _creatures() -> Array[Antivirus]:
	var result: Array[Antivirus] = []
	for node: Node in get_tree().get_nodes_in_group(Antivirus.GROUP):
		var creature: Antivirus = node as Antivirus
		if creature != null and is_instance_valid(creature):
			result.append(creature)
	return result


# ---------------------------------------------------------------- telemetry --

## `--log-ai`. One census line per second: enough to assert from a log that
## beam-avoidance actually fires and that a tap ping actually converges a pack.
func _process(delta: float) -> void:
	_log_clock -= delta
	if _log_clock > 0.0:
		return
	_log_clock = 1.0

	var census: Dictionary = {}
	var total: int = 0
	for creature: Antivirus in _creatures():
		total += 1
		var label: String = "?"
		if creature is Scrubber:
			label = "S." + String(Scrubber.State.keys()[int(creature.sync_state)])
		elif creature is Sentinel:
			label = "V." + String(Sentinel.State.keys()[int(creature.sync_state)])
		census[label] = int(census.get(label, 0)) + 1
	if total == 0:
		return

	var parts: PackedStringArray = PackedStringArray()
	var labels: Array = census.keys()
	labels.sort()
	for label: String in labels:
		parts.append("%s=%d" % [label, int(census[label])])
	print("[AI] layer %d processes=%d %s" % [_layer_number, total, " ".join(parts)])
