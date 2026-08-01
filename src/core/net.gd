extends Node
## Net — host/join lifecycle and crew roster for NULLVOID.
##
## Topology (DESIGN.md): host-authoritative listen server over ENet. The host
## owns world state; players own their own movement (client authority) so input
## feels instant, with a MultiplayerSynchronizer streaming pose to everyone else.
##
## Connect handshake:
##   1. client connects  -> `connected_to_server`
##   2. client loads the layer scene; the layer calls `world_ready()`
##   3. client sends `_register_crew(name, color)` to the host
##   4. host stores the roster entry, replies with the world config (seed, layer,
##      pool), spawns the player via MultiplayerSpawner, and broadcasts the roster
##
## Spawning only happens after step 2 so the client's MultiplayerSpawner always
## exists before any spawn packet arrives.
##
## Step 4's ordering is load-bearing for M2: the config carries the run seed the
## client generates its layer geometry from, and it is sent *before* the spawn
## packet on the same reliable channel, so the floor exists before the avatar.
##
## ## Transports (M3.5)
##
## Everything above is transport-agnostic. Godot's high-level multiplayer sits on
## whatever MultiplayerPeer we hand it, so the handshake, the spawner, the
## synchronizers and every RPC in the game run unchanged over either of:
##
##   DIRECT — `ENetMultiplayerPeer`, host by IP:port. LAN, the dedicated headless
##            server, and anyone who would rather not involve Steam. Unchanged
##            from M1.
##   STEAM  — `SteamMultiplayerPeer` over a Steam lobby the host owns. No IP is
##            ever typed or shown; friends arrive by overlay invite or the
##            friends list. Requires SteamHub.live.
##
## `transport` says which one this session is using; it is the only thing in Net
## that has to know the difference, plus `ping_ms` (ENet-only statistic) and
## `leave` (which also drops the lobby).

signal crew_changed
signal connect_failed(reason: String)
signal session_ended(reason: String)
signal local_player_spawned(player: Node)
## Transient crew events ("X JOINED THE CREW"), surfaced by the HUD.
signal notice(message: String)

enum Transport {
	DIRECT,  ## ENetMultiplayerPeer, host by address:port.
	STEAM,   ## SteamMultiplayerPeer, host by lobby.
}

const DEFAULT_PORT: int = 27015
const MAX_CLIENTS: int = 4
const CONNECT_TIMEOUT: float = 10.0
## A Steam session has a lobby handshake in front of the ENet-equivalent one, so
## it gets a little longer before we call it dead.
const STEAM_CONNECT_TIMEOUT: float = 20.0
## Virtual port on the Steam networking socket. One session per process, so the
## number never has to vary.
const STEAM_VIRTUAL_PORT: int = 0

const LAYER_SCENE: String = "res://src/world/layer.tscn"
const MENU_SCENE: String = "res://src/ui/main_menu.tscn"
const PLAYER_SCENE: String = "res://src/player/player.tscn"

## peer id -> {"name": String, "color": Color}. Untyped on purpose: this
## dictionary goes over the wire and typed containers add needless friction.
var crew: Dictionary = {}

var is_online: bool = false
var is_dedicated: bool = false
var transport: Transport = Transport.DIRECT

var _player_scene: PackedScene = null
var _spawner: MultiplayerSpawner = null
var _layer: Node = null
var _connect_timer: SceneTreeTimer = null
## Set while a Steam join is waiting on the lobby before it can touch the peer.
var _steam_joining: bool = false
## Set from the moment a client asks to connect until the server answers. A peer
## can report CONNECTED without the session ever handshaking (a Steam socket that
## reached the wrong end, for one), and that must time out like any other failure
## rather than leaving the menu saying HAILING for ever.
var _awaiting_server: bool = false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	# Run and SteamHub are autoloaded after us, so their signals cannot be
	# connected until the whole autoload list is standing.
	_bind_presence.call_deferred()


## Keeps Steam rich presence describing what this process is actually doing.
## Purely cosmetic: nothing in the session depends on it, and it is a no-op
## whenever Steam is not live.
func _bind_presence() -> void:
	Run.layer_changed.connect(_on_presence_layer_changed)
	crew_changed.connect(_publish_presence)


func _on_presence_layer_changed(_number: int) -> void:
	_publish_presence()


## "DESCENDING · LAYER 07 · 3/4 CREW", and the same numbers as lobby metadata so
## a friend reading the lobby before joining sees what they are walking into.
func _publish_presence() -> void:
	if not SteamHub.live:
		return
	if not is_online:
		SteamHub.set_presence_menu()
		return
	var size: int = maxi(crew.size(), 1)
	if Run.configured:
		SteamHub.set_presence_run(Run.layer_number, size)
	else:
		SteamHub.set_presence_lobby(size)
	if transport == Transport.STEAM and SteamHub.is_lobby_owner:
		SteamHub.publish_lobby_state(size, Run.layer_number)


# ---------------------------------------------------------------- lifecycle --

## Starts a listen server (or a dedicated one, which spawns no local player).
## DIRECT transport: ENet on `port`.
func host(port: int = DEFAULT_PORT, dedicated: bool = false) -> Error:
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		var reason: String = "COULD NOT BIND PORT %d (%s)" % [port, error_string(err)]
		push_warning("[Net] host failed: " + reason)
		connect_failed.emit(reason)
		return err

	transport = Transport.DIRECT
	print("[Net] hosting on port %d (%s)" % [port, "dedicated" if dedicated else "listen"])
	_become_host(peer, dedicated)
	return OK


## STEAM transport. The lobby has to exist before the peer can host into it, so
## this returns as soon as the lobby is *requested*; the session actually starts
## in `_on_steam_lobby_created`. Failure still funnels through `connect_failed`.
func host_steam() -> Error:
	if not SteamHub.live:
		var reason: String = "STEAM UNAVAILABLE: %s" % SteamHub.status
		push_warning("[Net] steam host refused: " + reason)
		connect_failed.emit(reason)
		return ERR_UNAVAILABLE
	transport = Transport.STEAM
	_connect_steam_once(SteamHub.lobby_created, _on_steam_lobby_created)
	_connect_steam_once(SteamHub.lobby_failed, _on_steam_lobby_failed)
	if not SteamHub.create_lobby():
		return ERR_UNAVAILABLE
	_start_connect_timeout("STEAM LOBBY", 0, STEAM_CONNECT_TIMEOUT)
	return OK


## STEAM transport, client side: enter the lobby, then connect to its owner.
## `lobby_id` comes from an overlay invite, a friends-list join or the menu's
## friend-lobby scan — never typed by a human.
func join_steam(lobby_id: int) -> Error:
	if not SteamHub.live:
		var reason: String = "STEAM UNAVAILABLE: %s" % SteamHub.status
		push_warning("[Net] steam join refused: " + reason)
		connect_failed.emit(reason)
		return ERR_UNAVAILABLE
	transport = Transport.STEAM
	_steam_joining = true
	_connect_steam_once(SteamHub.lobby_entered, _on_steam_lobby_entered)
	_connect_steam_once(SteamHub.lobby_failed, _on_steam_lobby_failed)
	if not SteamHub.join_lobby(lobby_id):
		_steam_joining = false
		return ERR_UNAVAILABLE
	print("[Net] steam join: waiting on lobby %d" % lobby_id)
	_start_connect_timeout("LOBBY %d" % lobby_id, 0, STEAM_CONNECT_TIMEOUT)
	return OK


func _on_steam_lobby_created(lobby_id: int) -> void:
	var peer: SteamMultiplayerPeer = SteamMultiplayerPeer.new()
	var err: int = peer.host_with_lobby(lobby_id)
	if err != OK:
		var reason: String = "STEAM PEER REFUSED TO HOST (%s)" % error_string(err as Error)
		push_warning("[Net] " + reason)
		SteamHub.leave_lobby()
		connect_failed.emit(reason)
		return
	_cancel_connect_timeout()
	print("[Net] listen host via Steam peer on lobby %d" % lobby_id)
	_become_host(peer, false)


func _on_steam_lobby_entered(lobby_id: int) -> void:
	if not _steam_joining:
		return  # our own lobby coming back at us as the owner.
	_steam_joining = false
	var peer: SteamMultiplayerPeer = SteamMultiplayerPeer.new()
	var err: int = peer.connect_to_lobby(lobby_id)
	if err != OK:
		var reason: String = "COULD NOT REACH THE HOST (%s)" % error_string(err as Error)
		push_warning("[Net] " + reason)
		SteamHub.leave_lobby()
		connect_failed.emit(reason)
		return
	multiplayer.multiplayer_peer = peer
	is_online = true
	is_dedicated = false
	_awaiting_server = true
	crew.clear()
	print("[Net] connecting to lobby %d owner over Steam" % lobby_id)


func _on_steam_lobby_failed(reason: String) -> void:
	_steam_joining = false
	_cancel_connect_timeout()
	connect_failed.emit(reason)


## Signals from SteamHub outlive any one session, so every connection is made
## one-shot and re-made per attempt rather than stacking up.
func _connect_steam_once(sig: Signal, target: Callable) -> void:
	if not sig.is_connected(target):
		sig.connect(target, CONNECT_ONE_SHOT)


## Everything a host does once it has a working peer, whichever transport made it.
func _become_host(peer: MultiplayerPeer, dedicated: bool) -> void:
	multiplayer.multiplayer_peer = peer
	is_online = true
	_awaiting_server = false
	is_dedicated = dedicated
	crew.clear()
	if Debug.forced_seed != 0:
		Rng.set_run_seed(Debug.forced_seed)
	else:
		Rng.roll_new_seed()
	if not dedicated:
		crew[1] = {"name": GameState.local_name, "color": GameState.local_color}
	print("[Net] session seed %d" % Rng.run_seed)
	# The host is the only peer that decides what world this is. Everything the
	# clients need to reproduce it locally goes out in _register_crew's reply.
	# The injection point is whichever is deeper: the menu's choice (a backdoor
	# this machine has installed) or an explicit `--layer`.
	Run.begin(maxi(Debug.start_layer, GameState.injection_layer), Debug.use_test_layer)
	Run.on_crew_changed()
	crew_changed.emit()
	get_tree().change_scene_to_file(LAYER_SCENE)


## Connects to a host. Failure surfaces through `connect_failed`, never a hang.
func join(address: String, port: int = DEFAULT_PORT) -> Error:
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port)
	if err != OK:
		var reason: String = "INVALID ADDRESS %s:%d (%s)" % [address, port, error_string(err)]
		push_warning("[Net] join failed: " + reason)
		connect_failed.emit(reason)
		return err

	transport = Transport.DIRECT
	multiplayer.multiplayer_peer = peer
	is_online = true
	is_dedicated = false
	_awaiting_server = true
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
	_steam_joining = false
	_awaiting_server = false
	crew.clear()
	_spawner = null
	_layer = null
	# A Steam session's lobby dies with the session. Leaving as the owner hands
	# the lobby to whoever is left, so the host also has to stop advertising it.
	if transport == Transport.STEAM:
		SteamHub.leave_lobby()
	transport = Transport.DIRECT
	SteamHub.set_presence_menu()
	Run.reset()
	crew_changed.emit()
	if not reason.is_empty():
		GameState.report(reason)
	session_ended.emit(reason)
	if is_inside_tree():
		get_tree().change_scene_to_file(MENU_SCENE)


## Called by the layer scene on every peer once the world exists.
func world_ready(layer: Node, spawner: MultiplayerSpawner) -> void:
	_layer = layer
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
		"name": String(entry.get("name", "AGENT")),
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
	player.set("player_name", String(info.get("name", "AGENT")))
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
	if _layer != null and is_instance_valid(_layer) and _layer.has_method("get_spawn_point"):
		return _layer.call("get_spawn_point", index) as Transform3D
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
		Run.on_crew_left(id)
		_receive_crew.rpc(crew)
		_crew_notice.rpc("%s LOST CONNECTION" % who)
	crew_changed.emit()


func _on_connected_to_server() -> void:
	print("[Net] connected, loading layer")
	_awaiting_server = false
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


## `port` of 0 means the label is already the whole story (the Steam paths, where
## there is no address to print).
func _start_connect_timeout(address: String, port: int,
		seconds: float = CONNECT_TIMEOUT) -> void:
	_cancel_connect_timeout()
	var label: String = address if port <= 0 else "%s:%d" % [address, port]
	var timer: SceneTreeTimer = get_tree().create_timer(seconds)
	_connect_timer = timer
	timer.timeout.connect(func() -> void:
		# A cancelled attempt leaves its timer running; only the attempt that is
		# still current may declare a timeout.
		if _connect_timer != timer:
			return
		_connect_timer = null
		_on_connect_timeout(label, seconds)
	)


func _on_connect_timeout(label: String, seconds: float) -> void:
	if not is_online:
		# STEAM: the lobby never came back, so no peer was ever built. DIRECT
		# cannot reach here — it is online the moment it has a peer.
		if transport != Transport.STEAM:
			return
		_steam_joining = false
		SteamHub.leave_lobby()
		push_warning("[Net] steam connect timed out after %.0fs" % seconds)
		connect_failed.emit("TIMED OUT ON %s" % label)
		return
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
			and not _awaiting_server:
		return
	multiplayer.multiplayer_peer = null
	is_online = false
	_steam_joining = false
	var handshake: bool = _awaiting_server
	_awaiting_server = false
	if transport == Transport.STEAM:
		SteamHub.leave_lobby()
	push_warning("[Net] connect timed out after %.0fs%s" % [
		seconds, " (socket up, no handshake)" if handshake else ""])
	connect_failed.emit("TIMED OUT REACHING %s" % label)


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
	Run.on_crew_changed()
	# Config first, spawn second, both reliable on the same channel: the client
	# builds its geometry from the seed before its avatar arrives to stand on it.
	_receive_config.rpc_id(id, Rng.run_seed, Run.layer_number, Run.use_test_layer,
			Run.cycles, Run.cycles_max)
	_spawn_for_peer(id)
	_receive_crew.rpc(crew)
	_crew_notice.rpc("%s JOINED THE CREW" % clean)
	crew_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_crew(roster: Dictionary) -> void:
	crew = roster
	crew_changed.emit()


## The whole world in one packet: the seed every peer generates geometry from,
## which layer we are on, whether the host is running the hand-authored test
## layer, and the current pool so a joiner's HUD is right on its first frame.
@rpc("authority", "call_remote", "reliable")
func _receive_config(value: int, layer: int, test_layer: bool,
		pool: float, pool_max: float) -> void:
	Rng.set_run_seed(value)
	Run.adopt(layer, test_layer, pool, pool_max)


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
## RTT of the given client. ENet-only: the Steam peer keeps its round-trip inside
## the relay and does not expose one per peer, so a Steam session reports 0 and
## the HUD simply shows no latency tag.
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
