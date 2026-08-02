extends Node
## Cartography — what the crew has SEEN of this layer. Host-authoritative,
## per-layer, shared by the whole crew.
##
## ## The design law this file exists to enforce
##
## DESIGN.md pillar 2 is "the dark is the enemy". A minimap is the single easiest
## way to delete a horror game's central pillar, and the way it happens is never a
## decision anybody makes — it is a map that draws the layout from the seed,
## because the seed is right there and every peer already has it.
##
## So the rule is stated once, here, and everything below is its consequence:
##
##   **THE MAP IS MEMORY, NOT A WALLHACK.** It may draw only what the crew has
##   already walked into or already looked at. A room that has never been entered
##   does not exist on it. An item nobody has laid eyes on does not exist on it.
##   The topology of the unexplored layer is not dimmed, not outlined, not hinted
##   at — it is absent, and that is what keeps the dark worth being afraid of.
##
## The generator hands every peer the whole layout for free, which makes this an
## unusually easy law to break by accident and an unusually cheap one to keep: the
## minimap simply never reads `LayerGraph` for anything it has not been told is
## discovered.
##
## ## Authority
##
## Same shape as Props, for the same reason (see prop_state.gd's header): the
## layout is SEEDED CONTENT, so a discovery report only ever has to carry an
## INDEX. The host checks that the reporting player is genuinely where they say
## they are, applies it to its own copy, and broadcasts.
##
##   client                     host
##   ------                     ----
##   report_room(index)         validate: run live? sender running? sender
##                              actually inside that room's rect?
##                              -> _apply_room.rpc(index) to everybody
##   report_item(kind, index)   ... and within DISCOVER_RANGE of the fixture.
##
## Line of sight is tested on the CLIENT, because the client is the only machine
## that knows what its own camera can see, and it is not security-critical: the
## worst a modified client can do is reveal a marker it was standing next to
## anyway. The host's range check is what stops a peer revealing the layer from
## across it.
##
## ## Join-race safety
##
## A crewmate who joins on layer 7 must arrive holding everything the crew has
## already explored, or their map is blank and they are the only one who cannot
## read it. `peer_connected` fires on the host with the peer id; the whole set
## goes out `rpc_id` to that peer alone. Discovery is small (two integer sets per
## layer), so the snapshot is a packet, not a stream.
##
## Nothing here is simulation. It never feeds AI, never feeds the seed stream,
## never affects generation — so determinism is untouched by construction.

signal discovered

## How close a player must be to a fixture before the host will accept a
## line-of-sight discovery of it. Generous — the client already decided it could
## see the thing; this is only an anti-nonsense bound.
const DISCOVER_RANGE: float = 26.0
## And the slack on the room test, in metres, so a player standing in a doorway
## is not refused for being 20 cm outside the rect they are visibly in.
const ROOM_SLACK: float = 2.5

## Fixture kinds a marker can be discovered for. Strings rather than an enum
## because they cross the wire and go into a Dictionary key, and a renamed enum
## constant that silently changes an int is a bug nobody finds.
const KIND_SHAFT: String = "shaft"
const KIND_SIPHON: String = "siphon"
const KIND_COMPILER: String = "compiler"
const KIND_SHARD: String = "shard"
const KIND_UPLINK: String = "uplink"
const KIND_NODE: String = "node"

## room index -> true. The crew's shared memory of where it has been.
var discovered_rooms: Dictionary = {}
## "kind:index" -> true.
var discovered_items: Dictionary = {}


func _ready() -> void:
	Run.layer_changed.connect(_on_layer_changed)
	Run.descent_started.connect(_on_descent_started)
	multiplayer.peer_connected.connect(_on_peer_connected)


func _on_layer_changed(_number: int) -> void:
	reset()


func _on_descent_started(_next: int) -> void:
	reset()


## A new layer is a new dark. Explicitly NOT carried across a descent: the crew's
## memory of ring 6 tells them nothing about ring 7, and a map that persisted
## would be claiming otherwise.
func reset() -> void:
	discovered_rooms.clear()
	discovered_items.clear()
	discovered.emit()


# ------------------------------------------------------------------ queries --

func knows_room(index: int) -> bool:
	return discovered_rooms.has(index)


func knows_item(kind: String, index: int) -> bool:
	return discovered_items.has(_key(kind, index))


func room_count() -> int:
	return discovered_rooms.size()


static func _key(kind: String, index: int) -> String:
	return "%s:%d" % [kind, index]


# ------------------------------------------------------------------ reports --

## The local player walked into a room. Called every time the room under them
## changes; the has-check keeps it to one packet per genuinely new room.
func report_room(index: int) -> void:
	if index < 0 or discovered_rooms.has(index):
		return
	if not multiplayer.has_multiplayer_peer():
		# Solo, no peer: apply directly. The solo invariant (DESIGN.md) means the
		# offline path is a first-class path, not a degraded one.
		_apply_room(index)
		return
	_room_request.rpc_id(1, index)


## The local player has a fixture in view and unobstructed. See the header for
## why the LOS test is the client's job and the range test is the host's.
func report_item(kind: String, index: int) -> void:
	if index < 0 or discovered_items.has(_key(kind, index)):
		return
	if not multiplayer.has_multiplayer_peer():
		_apply_item(kind, index)
		return
	_item_request.rpc_id(1, kind, index)


# ------------------------------------------------------- host-side validation --

func _graph() -> LayerGraph:
	var layers: Array = get_tree().get_nodes_in_group("layer")
	if layers.is_empty():
		return null
	var layer: Node = layers[0]
	return layer.get("graph") as LayerGraph


func _sender_position(peer: int) -> Vector3:
	var player: Node = Net.get_player(peer)
	if player == null or not is_instance_valid(player):
		return Vector3.INF
	return (player as Node3D).global_position


@rpc("any_peer", "call_local", "reliable")
func _room_request(index: int) -> void:
	if not multiplayer.is_server():
		return
	var peer: int = multiplayer.get_remote_sender_id()
	if peer == 0:
		peer = Net.local_id()
	if not Run.is_running(peer):
		return
	var graph: LayerGraph = _graph()
	if graph == null or index < 0 or index >= graph.rooms.size():
		return
	var at: Vector3 = _sender_position(peer)
	if at == Vector3.INF:
		return
	# The claim is checkable, so it is checked.
	if not room_contains(graph, index, at):
		return
	if discovered_rooms.has(index):
		return
	_apply_room.rpc(index)


## Is `at` inside room `index`? A room is a rectangle and a player is a point;
## `ROOM_SLACK` is doorway tolerance and nothing else.
##
## Lifted out of `_room_request` so there is ONE definition of "in that room" and
## `--selftest` can hold it to the invariant that matters: the discovery set never
## contains a room nobody has stood in. That is a claim about this predicate — if
## the slack were ever wide enough for two rooms to share a point, standing in one
## would authorise the other, and the map would quietly start drawing rooms the
## crew has never been in. `Debug._cartography_selftest` asserts exactly that,
## against real generated graphs, and it needs a function to assert it about.
static func room_contains(graph: LayerGraph, index: int, at: Vector3) -> bool:
	if graph == null or index < 0 or index >= graph.rooms.size():
		return false
	var room: Dictionary = graph.rooms[index]
	var low: Vector2 = Vector2(room["min"]) - Vector2.ONE * ROOM_SLACK
	var high: Vector2 = Vector2(room["max"]) + Vector2.ONE * ROOM_SLACK
	return at.x >= low.x and at.x <= high.x and at.z >= low.y and at.z <= high.y


@rpc("any_peer", "call_local", "reliable")
func _item_request(kind: String, index: int) -> void:
	if not multiplayer.is_server():
		return
	var peer: int = multiplayer.get_remote_sender_id()
	if peer == 0:
		peer = Net.local_id()
	if not Run.is_running(peer):
		return
	var where: Vector3 = item_position(kind, index)
	if where == Vector3.INF:
		return
	var at: Vector3 = _sender_position(peer)
	if at == Vector3.INF or at.distance_to(where) > DISCOVER_RANGE:
		return
	if discovered_items.has(_key(kind, index)):
		return
	_apply_item.rpc(kind, index)


## World position of a discoverable fixture, or `Vector3.INF` if the kind/index
## does not name one. The host validates against this and the minimap draws at
## it, so there is exactly one answer to "where is that marker".
func item_position(kind: String, index: int) -> Vector3:
	var graph: LayerGraph = _graph()
	if graph == null:
		return Vector3.INF
	match kind:
		KIND_SHAFT:
			return graph.shaft_point
		KIND_NODE:
			return graph.backdoor_point if graph.is_backdoor else Vector3.INF
		KIND_UPLINK:
			return graph.uplink_point if graph.is_backdoor else Vector3.INF
		KIND_SIPHON:
			if index >= 0 and index < graph.siphon_points.size():
				return graph.siphon_points[index]
		KIND_COMPILER:
			if index >= 0 and index < graph.compiler_points.size():
				return graph.compiler_points[index]
		KIND_SHARD:
			if index >= 0 and index < graph.shard_points.size():
				return graph.shard_points[index]
	return Vector3.INF


# --------------------------------------------------------------- join catch-up --

## Host: hand a joining peer the crew's whole memory of this layer.
##
## Sent `rpc_id` to the joiner alone — everybody else already has it — and sent
## as two flat arrays rather than as N packets, because a crew that has explored
## eight rooms and forty shards would otherwise put forty-eight reliable messages
## on the wire during the exact frame a client is building its geometry.
func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if discovered_rooms.is_empty() and discovered_items.is_empty():
		return
	_adopt.rpc_id(id, discovered_rooms.keys(), discovered_items.keys())


@rpc("authority", "reliable")
func _adopt(rooms: Array, items: Array) -> void:
	for index: int in rooms:
		discovered_rooms[int(index)] = true
	for key: String in items:
		discovered_items[String(key)] = true
	discovered.emit()


# --------------------------------------------------------------------- rpcs --

@rpc("authority", "call_local", "reliable")
func _apply_room(index: int) -> void:
	if discovered_rooms.has(index):
		return
	discovered_rooms[index] = true
	discovered.emit()


@rpc("authority", "call_local", "reliable")
func _apply_item(kind: String, index: int) -> void:
	var key: String = _key(kind, index)
	if discovered_items.has(key):
		return
	discovered_items[key] = true
	discovered.emit()
