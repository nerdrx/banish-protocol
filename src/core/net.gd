extends Node
## Net — host/join lifecycle and crew roster for VOIDFALL.
##
## Topology (DESIGN.md): host-authoritative listen server over ENet. The host
## owns world state; players own their own movement (client authority) so input
## feels instant, with a MultiplayerSynchronizer streaming pose to everyone else.
##
## Connect handshake:
##   1. client connects  -> `connected_to_server`
##   2. client loads the deck scene; deck calls `world_ready()`
##   3. client sends `_register_crew(name, color)` to the host
##   4. host stores the roster entry, spawns the player via MultiplayerSpawner,
##      replies with the run seed and broadcasts the new roster
##
## Spawning only happens after step 2 so the client's MultiplayerSpawner always
## exists before any spawn packet arrives.

signal crew_changed
signal connect_failed(reason: String)
signal session_ended(reason: String)
signal local_player_spawned(player: Node)
## Transient crew events ("X JOINED THE CREW"), surfaced by the HUD.
signal notice(message: String)

const DEFAULT_PORT: int = 27015
const MAX_CLIENTS: int = 4
const CONNECT_TIMEOUT: float = 10.0

const LAYER_SCENE: String = "res://src/world/test_layer.tscn"
const MENU_SCENE: String = "res://src/ui/main_menu.tscn"
const PLAYER_SCENE: String = "res://src/player/player.tscn"

## peer id -> {"name": String, "color": Color}. Untyped on purpose: this
## dictionary goes over the wire and typed containers add needless friction.
var crew: Dictionary = {}

var is_online: bool = false
var is_dedicated: bool = false

var _player_scene: PackedScene = null
var _spawner: MultiplayerSpawner = null
var _deck: Node = null
var _connect_timer: SceneTreeTimer = null


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# ---------------------------------------------------------------- lifecycle --

## Starts a listen server (or a dedicated one, which spawns no local player).
func host(port: int = DEFAULT_PORT, dedicated: bool = false) -> Error:
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		var reason: String = "COULD NOT BIND PORT %d (%s)" % [port, error_string(err)]
		push_warning("[Net] host failed: " + reason)
		connect_failed.emit(reason)
		return err

	multiplayer.multiplayer_peer = peer
	is_online = true
	is_dedicated = dedicated
	crew.clear()
	Rng.roll_new_seed()
	if not dedicated:
		crew[1] = {"name": GameState.local_name, "color": GameState.local_color}
	print("[Net] hosting on port %d (%s), seed %d" % [
		port, "dedicated" if dedicated else "listen", Rng.run_seed])
	crew_changed.emit()
	get_tree().change_scene_to_file(LAYER_SCENE)
	return OK


## Connects to a host. Failure surfaces through `connect_failed`, never a hang.
func join(address: String, port: int = DEFAULT_PORT) -> Error:
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port)
	if err != OK:
		var reason: String = "INVALID ADDRESS %s:%d (%s)" % [address, port, error_string(err)]
		push_warning("[Net] join failed: " + reason)
		connect_failed.emit(reason)
		return err

	multiplayer.multiplayer_peer = peer
	is_online = true
	is_dedicated = false
	crew.clear()
	print("[Net] connecting to %s:%d" % [address, port])
	_start_connect_timeout(address, port)
	return OK


## Tears down the session and returns to the menu with a message.
func leave(reason: String = "") -> void:
	print("[Net] leaving session: %s" % (reason if not reason.is_empty() else "no reason given"))
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_online = false
	is_dedicated = false
	crew.clear()
	_spawner = null
	_deck = null
	crew_changed.emit()
	if not reason.is_empty():
		GameState.report(reason)
	session_ended.emit(reason)
	if is_inside_tree():
		get_tree().change_scene_to_file(MENU_SCENE)


## Called by the deck scene on every peer once the world exists.
func world_ready(deck: Node, spawner: MultiplayerSpawner) -> void:
	_deck = deck
	_spawner = spawner
	_spawner.spawn_function = _spawn_player

	if not is_online:
		return  # solo scene run from the editor — nothing to replicate.

	if multiplayer.is_server():
		if not is_dedicated:
			_spawn_for_peer(1)
	else:
		_register_crew.rpc_id(1, GameState.local_name, GameState.local_color)


## Called by Player._ready() on every peer.
func notify_player_ready(player: Node) -> void:
	if player.is_multiplayer_authority():
		local_player_spawned.emit(player)


# ------------------------------------------------------------------ spawning --

func _spawn_for_peer(id: int) -> void:
	if _spawner == null or not is_instance_valid(_spawner):
		push_warning("[Net] spawn requested with no spawner")
		return
	var entry: Dictionary = crew.get(id, {}) as Dictionary
	var spawn_index: int = crew.keys().find(id)
	var point: Transform3D = _spawn_point(maxi(spawn_index, 0))
	_spawner.spawn({
		"id": id,
		"name": String(entry.get("name", "SALVAGER")),
		"color": Color(entry.get("color", Color.WHITE)),
		"position": point.origin,
		"yaw": point.basis.get_euler().y,
	})


## Runs on every peer (MultiplayerSpawner custom spawn function), so authority
## and cosmetic identity are set identically everywhere before the node enters
## the tree — no follow-up RPC needed.
func _spawn_player(data: Variant) -> Node:
	var info: Dictionary = data as Dictionary
	if _player_scene == null:
		_player_scene = load(PLAYER_SCENE) as PackedScene
	var player: Node3D = _player_scene.instantiate() as Node3D
	var id: int = int(info.get("id", 1))
	player.name = str(id)
	player.set("player_name", String(info.get("name", "SALVAGER")))
	player.set("player_color", Color(info.get("color", Color.WHITE)))
	player.position = Vector3(info.get("position", Vector3.ZERO))
	player.rotation = Vector3(0.0, float(info.get("yaw", 0.0)), 0.0)
	player.set_multiplayer_authority(id)
	return player


func _despawn_peer(id: int) -> void:
	var player: Node = get_player(id)
	if player != null:
		player.queue_free()


func get_player(id: int) -> Node:
	if _spawner == null or not is_instance_valid(_spawner):
		return null
	var root: Node = _spawner.get_node_or_null(_spawner.spawn_path)
	if root == null:
		return null
	return root.get_node_or_null(str(id))


func _spawn_point(index: int) -> Transform3D:
	if _deck != null and is_instance_valid(_deck) and _deck.has_method("get_spawn_point"):
		return _deck.call("get_spawn_point", index) as Transform3D
	return Transform3D.IDENTITY


# --------------------------------------------------------------- signal glue --

func _on_peer_connected(id: int) -> void:
	print("[Net] peer %d connected" % id)
	# The roster entry and spawn wait for the peer's own _register_crew call.


func _on_peer_disconnected(id: int) -> void:
	var who: String = _display_name(id)
	print("[Net] peer %d (%s) disconnected" % [id, who])
	if multiplayer.is_server():
		_despawn_peer(id)
		crew.erase(id)
		_receive_crew.rpc(crew)
		_crew_notice.rpc("%s LOST CONNECTION" % who)
	crew_changed.emit()


func _on_connected_to_server() -> void:
	print("[Net] connected, loading deck")
	_cancel_connect_timeout()
	get_tree().change_scene_to_file(LAYER_SCENE)


func _on_connection_failed() -> void:
	_cancel_connect_timeout()
	multiplayer.multiplayer_peer = null
	is_online = false
	push_warning("[Net] connection refused")
	connect_failed.emit("NO RESPONSE FROM HOST")


func _on_server_disconnected() -> void:
	leave("HOST ENDED THE SESSION")


func _start_connect_timeout(address: String, port: int) -> void:
	_cancel_connect_timeout()
	_connect_timer = get_tree().create_timer(CONNECT_TIMEOUT)
	_connect_timer.timeout.connect(func() -> void:
		if is_online and not multiplayer.has_multiplayer_peer():
			return
		if is_online and multiplayer.multiplayer_peer != null \
				and multiplayer.multiplayer_peer.get_connection_status() \
				!= MultiplayerPeer.CONNECTION_CONNECTED:
			multiplayer.multiplayer_peer = null
			is_online = false
			push_warning("[Net] connect timed out after %.0fs" % CONNECT_TIMEOUT)
			connect_failed.emit("TIMED OUT REACHING %s:%d" % [address, port])
	)


func _cancel_connect_timeout() -> void:
	_connect_timer = null


# ---------------------------------------------------------------------- rpcs --

@rpc("any_peer", "call_remote", "reliable")
func _register_crew(player_name: String, color: Color) -> void:
	if not multiplayer.is_server():
		return
	var id: int = multiplayer.get_remote_sender_id()
	var clean: String = GameState.sanitize_name(player_name)
	crew[id] = {"name": clean, "color": color}
	print("[Net] crew registered: %d = %s" % [id, clean])
	_receive_seed.rpc_id(id, Rng.run_seed)
	_spawn_for_peer(id)
	_receive_crew.rpc(crew)
	_crew_notice.rpc("%s JOINED THE CREW" % clean)
	crew_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_crew(roster: Dictionary) -> void:
	crew = roster
	crew_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_seed(value: int) -> void:
	Rng.set_run_seed(value)


@rpc("authority", "call_local", "reliable")
func _crew_notice(message: String) -> void:
	crew_changed.emit()
	notice.emit(message)
	print("[Net] " + message)


# -------------------------------------------------------------------- lookup --

func _display_name(id: int) -> String:
	var entry: Dictionary = crew.get(id, {}) as Dictionary
	return String(entry.get("name", "PEER %d" % id))


func crew_name(id: int) -> String:
	return _display_name(id)


func crew_color(id: int) -> Color:
	var entry: Dictionary = crew.get(id, {}) as Dictionary
	return Color(entry.get("color", Color.WHITE))


func local_id() -> int:
	if multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return 1


## Round-trip time in ms. Clients measure against the host; the host reports the
## RTT of the given client.
func ping_ms(id: int) -> int:
	var peer: ENetMultiplayerPeer = multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer == null:
		return 0
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return 0
	var target: int = id if multiplayer.is_server() else 1
	if target == multiplayer.get_unique_id():
		return 0
	# The roster is rebuilt from a disconnect notification, so it can still name a
	# peer ENet has already dropped. Asking for its stats logs an engine error.
	if not multiplayer.get_peers().has(target):
		return 0
	var packet_peer: ENetPacketPeer = peer.get_peer(target)
	if packet_peer == null:
		return 0
	return int(packet_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
