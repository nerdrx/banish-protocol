extends Node
## Net — host/join lifecycle and crew roster for NULLVOID.
##
## Topology (DESIGN.md): host-authoritative listen server over ENet. The host
## owns world state; players own their own movement (client authority) so input
## feels instant, with a MultiplayerSynchronizer streaming pose to everyone else.
##
## Connect handshake:
##   1. client builds a peer but does NOT hand it to the engine; it loads the
##      layer scene, which calls `world_ready()`
##   2. `world_ready` attaches the peer — so the MultiplayerSpawner is already in
##      the tree before the socket is live -> `connected_to_server`
##   3. client sends `_register_crew(name, color)` to the host
##   4. host stores the roster entry, replies with the world config (seed, layer,
##      pool), spawns the player via MultiplayerSpawner, and broadcasts the roster
##
## **Steps 1 and 2 are in that order deliberately, and it is not obvious.** The
## spawns *this file* initiates are all sent from `_register_crew`, well after
## the joiner's spawner exists — but they are not the only spawns on the wire.
## Godot's own `SceneReplicationInterface` re-sends a spawn command for every
## already-spawned node the moment the server's `peer_connected` fires, and the
## host has spawned its own avatar long before anybody connects. **[verified
## 4.7.1]** if the client's spawner does not exist within ~3 frames of
## `connected_to_server`, that catch-up packet is dropped with
## `Node not found: "Spawner"` and **the engine never retries** — leaving a
## client that is fully connected, correctly rostered, and cannot see a single
## crewmate. No crewmate avatars means no `RestorePoint`, which means that client
## cannot bring a downed teammate back up: the co-op core loop, silently gone.
##
## Loading `layer.tscn` (which also instantiates `hud.tscn`, the post shader and
## the environment) is comfortably more than three frames on a cold cache, so the
## fix is not to be quick — it is to make the race unreachable. The peer is only
## attached once the spawner is standing, and the budget stops mattering.
##
## Step 4's ordering is load-bearing for M2: the config carries the run seed the
## client generates its layer geometry from, and it is sent *before* the spawn
## packet on the same reliable channel, so the floor exists before the avatar.
##
## ## Joining mid-descent
##
## `Run.layer_number` is not advanced by `_begin_descent`; it is advanced by
## `Run.finish_descent`, ~0.55 s later. A registration answered inside that
## window hands the joiner the layer the crew is *leaving*, they generate the
## wrong building, and `_begin_descent` was broadcast before they existed so
## nothing ever corrects them. So the host does not answer inside the window at
## all: a registration that arrives while `Run.descending` (or before the host's
## own world is standing) is parked in `_pending_registrations` and replayed the
## moment both are settled. The joiner waits a fraction of a second longer and
## lands in the layer the crew is actually in.
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
## M4. Host-side: somebody was turned away at the injection point because their
## program has not installed the backdoor this intrusion started at. Carries the
## roster line the HUD's gate panel prints.
signal injection_gate(entries: Array)

enum Transport {
	DIRECT,  ## ENetMultiplayerPeer, host by address:port.
	STEAM,   ## SteamMultiplayerPeer, host by lobby.
}

const DEFAULT_PORT: int = 27015
## Crew size the whole game is built for, listen host included. DESIGN.md says
## 1–4 and `LayerGraph._place_furniture` authors exactly four spawn points, which
## `spawn_point()` then wraps with `index % spawns.size()` — so a fifth player
## does not get a bad spawn, they get the *first* player's spawn, on every layer
## and on every descent. The Steam transport already capped at four total
## (`SteamHub.MAX_CREW`); ENet passed this straight to `create_server`, whose
## argument is the number of **clients** alongside the listen host, and admitted
## five. One number, one meaning: total crew.
const MAX_CREW: int = 4
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

## peer id -> {"name": String, "color": Color, "modules": Dictionary,
##             "archive": int, "backdoor": int}. Untyped on purpose: this
## dictionary goes over the wire and typed containers add needless friction.
##
## M4 widened the entry from identity into **the announced program**. DESIGN.md
## keeps every player's build on their own machine and has them announce it to
## the host on join, so this roster is the session's copy of everybody's program:
## the host resolves module tiers off it to simulate with (Modules.loadout), the
## clients read it to draw a crewmate's beam at the right width, and the lobby
## gate reads `backdoor` to decide who is allowed at this depth.
var crew: Dictionary = {}

## Host-side. Everyone this session has turned away at the injection point, and
## why — {name, needed, theirs}. Kept rather than only emitted so the HUD panel
## can still be showing it a few seconds later, and so a second refusal adds a
## line instead of replacing the screen.
var refused_crew: Array = []

var is_online: bool = false
var is_dedicated: bool = false
var transport: Transport = Transport.DIRECT

var _player_scene: PackedScene = null
var _spawner: MultiplayerSpawner = null
var _layer: Node = null
var _connect_timer: SceneTreeTimer = null
## A client's peer between "the address is valid" and "the spawner exists". It is
## deliberately NOT handed to `multiplayer` until `world_ready` — see the
## handshake note in the header. An unattached peer is never polled, so the
## socket makes no progress and the host cannot see us yet.
var _pending_peer: MultiplayerPeer = null
## True from the moment a join has changed the scene to the layer. It decides
## where a failure is allowed to be reported: `connect_failed` while the menu is
## still up, `leave()` (which reports and returns to the menu) once it is not.
var _joined_into_world: bool = false
## Registrations the host could not honour when they arrived — its own world was
## not standing yet, or a descent was in flight and `Run.layer_number` was still
## the layer above. Entries are `{"id": int, "entry": Dictionary}`, replayed in
## arrival order by `_flush_pending_registrations`.
var _pending_registrations: Array = []
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
	_bind_descent_gate.call_deferred()


## Keeps Steam rich presence describing what this process is actually doing.
## Purely cosmetic: nothing in the session depends on it, and it is a no-op
## whenever Steam is not live.
func _bind_presence() -> void:
	Run.layer_changed.connect(_on_presence_layer_changed)
	crew_changed.connect(_publish_presence)


## Load-bearing, unlike `_bind_presence`: this is what releases a join that
## arrived mid-descent, once the layer below is standing on the host.
func _bind_descent_gate() -> void:
	Run.descent_finished.connect(_on_descent_finished)


## Deferred by one call, not run inline: `Run.finish_descent` emits this from
## inside `Layer._descend`, *before* `_rebuild()` has replaced the geometry. A
## spawn resolved here and now would use the old layer's spawn points.
func _on_descent_finished() -> void:
	_flush_pending_registrations.call_deferred()


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
	# A dedicated server has no local player, so all four slots are for clients;
	# a listen host is standing in one of them.
	var slots: int = MAX_CREW if dedicated else MAX_CREW - 1
	var err: Error = peer.create_server(port, slots)
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
	# Held, not attached — same reason as the DIRECT path. The transport does not
	# change the fact that the engine's catch-up spawns need a spawner to land in.
	_pending_peer = peer
	is_online = true
	is_dedicated = false
	_awaiting_server = true
	crew.clear()
	print("[Net] connecting to lobby %d owner over Steam" % lobby_id)
	_enter_world_to_join()


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
	refused_crew.clear()
	if Debug.forced_seed != 0:
		Rng.set_run_seed(Debug.forced_seed)
	else:
		Rng.roll_new_seed()
	if not dedicated:
		crew[1] = local_crew_entry()
	print("[Net] session seed %d" % Rng.run_seed)
	# The host is the only peer that decides what world this is. Everything the
	# clients need to reproduce it locally goes out in _register_crew's reply.
	# The injection point is whichever is deeper: the menu's choice (a backdoor
	# this machine has installed) or an explicit `--layer`.
	var target: int = maxi(Debug.start_layer, GameState.injection_layer)
	# THE PARTITION is the front door now (DESIGN.md's hub backlog: "the hub IS the
	# menu"). The crew arrives in their own sector, the rig is where they commit,
	# and `target` is only what the dial starts on.
	#
	# `Debug.hub_start()` is what keeps every scripted capture in the repo working:
	# an automated run drops straight into the layer as it always did unless it
	# explicitly asks for `--hub`, because a `--goto shaft` script has no way to
	# walk itself through a ritual that did not exist when it was written. A human
	# always gets the hub.
	if Debug.hub_start():
		Run.begin_hub(target)
	else:
		Run.begin(target, Debug.use_test_layer)
	Run.on_crew_changed()
	crew_changed.emit()
	get_tree().change_scene_to_file(LAYER_SCENE)


## Connects to a host. Failure surfaces through `connect_failed`, never a hang.
##
## The peer is built here — so a malformed address is still refused synchronously
## while the menu is up to say so — but it is not handed to `multiplayer` until
## the layer scene has stood up its spawner. See the handshake note in the header.
func join(address: String, port: int = DEFAULT_PORT) -> Error:
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port)
	if err != OK:
		var reason: String = "INVALID ADDRESS %s:%d (%s)" % [address, port, error_string(err)]
		push_warning("[Net] join failed: " + reason)
		connect_failed.emit(reason)
		return err

	transport = Transport.DIRECT
	_pending_peer = peer
	is_online = true
	is_dedicated = false
	_awaiting_server = true
	crew.clear()
	print("[Net] connecting to %s:%d (peer held until the layer is standing)" % [
		address, port])
	_start_connect_timeout(address, port)
	_enter_world_to_join()
	return OK


## Loads the layer scene ahead of the handshake. `Run.configured` is still false
## so the Layer builds nothing yet, and `is_online` is already true so it does
## not mistake this for an editor run and roll its own offline seed.
func _enter_world_to_join() -> void:
	_joined_into_world = true
	get_tree().change_scene_to_file(LAYER_SCENE)


## Hands the held peer to the engine, now that `_spawner` exists. Everything the
## server pushes at us on `peer_connected` — including the catch-up spawns for
## crewmates who were already standing — now has somewhere to land.
func _attach_pending_peer() -> void:
	var peer: MultiplayerPeer = _pending_peer
	_pending_peer = null
	if peer == null:
		return
	multiplayer.multiplayer_peer = peer
	print("[Net] spawner is up; opening the socket")


## One funnel for "the join did not happen", wherever we got to. Before the scene
## change the menu is listening on `connect_failed`; after it, the menu does not
## exist and `leave()` is the only thing that can both report and get us back.
func _fail_join(reason: String) -> void:
	# A held peer still owns a socket even though the engine never saw it.
	if _pending_peer != null:
		_pending_peer.close()
		_pending_peer = null
	_awaiting_server = false
	_steam_joining = false
	push_warning("[Net] " + reason)
	if _joined_into_world:
		# Standing in a layer with no session. `leave()` reports the reason and is
		# the only thing that gets us back to a menu that can show it.
		connect_failed.emit(reason)
		leave(reason)
		return
	# State first, then the signal: the menu's handler runs inside the emit.
	multiplayer.multiplayer_peer = null
	is_online = false
	# Debug's capture backstop listens for this too, so an automated run can never
	# hang waiting for a session that failed.
	connect_failed.emit(reason)


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
	_joined_into_world = false
	if _pending_peer != null:
		_pending_peer.close()
		_pending_peer = null
	crew.clear()
	refused_crew.clear()
	_pending_registrations.clear()
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


## Called by the layer scene on every peer once the world exists. This is the
## gate the whole handshake hangs off: no spawn packet — ours or the engine's —
## may be on the wire before it has run on the receiving side.
func world_ready(layer: Node, spawner: MultiplayerSpawner) -> void:
	_layer = layer
	_spawner = spawner
	_spawner.spawn_function = _spawn_player

	if not is_online:
		return  # solo scene run from the editor — nothing to replicate.

	if _pending_peer != null:
		# Joining client. The socket opens here, one step later than it used to.
		_attach_pending_peer()
		return

	if not multiplayer.has_multiplayer_peer():
		return

	if multiplayer.is_server():
		if not is_dedicated:
			_spawn_for_peer(1)
		# A client that got its registration in while the host was still loading
		# its own layer scene has been waiting on exactly this.
		_flush_pending_registrations()
	else:
		# Only reachable if a client somehow stands up a second layer scene with a
		# live peer; the normal path registers from `_on_connected_to_server`.
		_register_crew.rpc_id(1, local_crew_entry())


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
	_drop_pending_registration(id)
	if multiplayer.is_server():
		# A peer the injection gate turned away is disconnected on purpose and was
		# never on the roster. The crew has already been told why it happened; a
		# second notice reading "PEER 1867386995 LOST CONNECTION" is a bug report
		# from the engine, not news.
		var was_crew: bool = crew.has(id)
		_despawn_peer(id)
		crew.erase(id)
		Run.on_crew_left(id)
		_receive_crew.rpc(crew)
		if was_crew:
			_crew_notice.rpc("%s LOST CONNECTION" % who)
	crew_changed.emit()


## The layer scene is already standing by the time this fires — that is the whole
## point of holding the peer — so there is no scene to change to, only a roster
## entry to send.
func _on_connected_to_server() -> void:
	print("[Net] connected, registering with the host")
	_awaiting_server = false
	_cancel_connect_timeout()
	_register_crew.rpc_id(1, local_crew_entry())


func _on_connection_failed() -> void:
	_cancel_connect_timeout()
	multiplayer.multiplayer_peer = null
	_fail_join("NO RESPONSE FROM HOST")


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
	if _pending_peer != null:
		# The layer scene never called `world_ready`, so the peer was never
		# attached and the socket never opened. Nothing is going to happen on its
		# own from here, and a joiner sat in an unbuilt layer is the one failure
		# state that used to look like a hang.
		if transport == Transport.STEAM:
			SteamHub.leave_lobby()
		_fail_join("TIMED OUT LOADING THE LAYER FOR %s" % label)
		return
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
			and not _awaiting_server:
		return
	var handshake: bool = _awaiting_server
	multiplayer.multiplayer_peer = null
	if transport == Transport.STEAM:
		SteamHub.leave_lobby()
	push_warning("[Net] connect timed out after %.0fs%s" % [
		seconds, " (socket up, no handshake)" if handshake else ""])
	_fail_join("TIMED OUT REACHING %s" % label)


func _cancel_connect_timeout() -> void:
	_connect_timer = null


# ---------------------------------------------------------------------- rpcs --

## The program this machine announces. Identity, plus everything about the build
## that the host has to know to simulate this player and to decide whether they
## are allowed at this depth (DESIGN.md: "each player's program ... announced to
## the host on join").
func local_crew_entry() -> Dictionary:
	return {
		"name": GameState.sanitize_name(GameState.local_name),
		"color": GameState.local_color,
		"modules": Modules.local_tiers().duplicate(),
		"archive": GameState.archive,
		"backdoor": GameState.deepest_backdoor,
	}


## Re-broadcasts the roster. Called by Modules after a purchase, which is the one
## thing that changes an announced program mid-session.
func push_crew() -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	_receive_crew.rpc(crew)
	crew_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _register_crew(entry: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var id: int = multiplayer.get_remote_sender_id()
	if not _may_register_now():
		_defer_registration(id, entry)
		return
	_admit_crew(id, entry)


## Whether the host can answer a registration truthfully right now. Two reasons
## it cannot, and both used to be answered anyway with the wrong world:
##
##   * the host's own layer scene is not standing, so `_spawn_for_peer` has no
##     spawner and the joiner's avatar is never created at all;
##   * a descent is in flight, so `Run.layer_number` is still the layer the crew
##     is *leaving* and the reply would send the joiner to build it.
func _may_register_now() -> bool:
	if _spawner == null or not is_instance_valid(_spawner):
		return false
	return not Run.descending


func _defer_registration(id: int, entry: Dictionary) -> void:
	for row: Dictionary in _pending_registrations:
		if int(row["id"]) == id:
			row["entry"] = entry  # a re-send replaces, it does not queue twice.
			return
	_pending_registrations.append({"id": id, "entry": entry})
	print("[Net] registration from peer %d held (%s)" % [id,
		"descent in flight" if Run.descending else "host world not standing"])


func _drop_pending_registration(id: int) -> void:
	for index: int in range(_pending_registrations.size() - 1, -1, -1):
		if int((_pending_registrations[index] as Dictionary)["id"]) == id:
			_pending_registrations.remove_at(index)


## Replays every held registration, in arrival order. Called once the host's
## world is standing and once every descent has settled — never speculatively,
## because `_admit_crew` is what puts a spawn on the wire.
func _flush_pending_registrations() -> void:
	if _pending_registrations.is_empty():
		return
	if not _may_register_now():
		return
	var queued: Array = _pending_registrations
	_pending_registrations = []
	for row: Dictionary in queued:
		var id: int = int(row["id"])
		# A peer that gave up and dropped while it was held is not admitted to a
		# layer it is no longer connected to.
		if not multiplayer.get_peers().has(id):
			print("[Net] held registration from peer %d dropped: gone" % id)
			continue
		print("[Net] releasing held registration from peer %d on layer %d" % [
			id, Run.layer_number])
		_admit_crew(id, row["entry"] as Dictionary)


## A number that arrived over the wire, or `fallback`. **[verified 4.7.1]**
## `int({})` raises `Invalid call. Nonexistent 'int' constructor` and terminates
## the enclosing function, so a bare `int(entry.get(...))` on an announced
## program is a handler a modified client can abort halfway through.
static func _wire_int(value: Variant, fallback: int) -> int:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return int(value)
	return fallback


static func _wire_color(value: Variant) -> Color:
	if typeof(value) != TYPE_COLOR:
		return Color.WHITE
	return value as Color


func _admit_crew(id: int, entry: Dictionary) -> void:
	var clean: String = GameState.sanitize_name(String(entry.get("name", "AGENT")))
	var theirs: int = maxi(_wire_int(entry.get("backdoor", 0), 0), 0)

	# DESIGN.md's lobby rule, enforced at the only moment this architecture has
	# to enforce it. There is no separate lobby scene — the crew assembles inside
	# the layer, join-in-progress — so "a backdoor start requires every present
	# crew member to have installed it" becomes a check at the door: an agent
	# whose program never rooted this node cannot be injected here, because the
	# fiction of the backdoor is that it is *their* compromised infrastructure,
	# not the host's.
	# THE PARTITION is never gated. Nobody is turned away from the crew's own
	# staging sector — the rig inside it is what asks the backdoor question now,
	# before anyone commits and while everybody can still see who is short (see
	# `Run.injection_blocked_by`). What survives here is the case the rig cannot
	# cover: joining a run that is ALREADY under way, at a depth this program has
	# no right to be at. Spelled explicitly rather than relying on the hub
	# reporting layer 1, so that moving the hub's layer number can never quietly
	# turn the gate back on.
	var needed: int = 0 if Run.in_hub else GameState.backdoor_for(Run.layer_number)
	if theirs < needed:
		print("[Net] injection refused for %s: backdoor %02d required, program has %02d" % [
			clean, needed, theirs])
		refused_crew.append({"name": clean, "needed": needed, "theirs": theirs})
		injection_gate.emit(gate_roster())
		_crew_notice.rpc("%s TURNED AWAY  ·  BACKDOOR %02d NOT INSTALLED" % [clean, needed])
		_injection_refused.rpc_id(id, needed, theirs, Run.layer_number)
		# Give the refusal packet a moment to leave before the socket goes.
		_disconnect_later(id)
		return

	crew[id] = {
		"name": clean,
		"color": _wire_color(entry.get("color", Color.WHITE)),
		# Sanitised, not trusted. The local save path has cleaned its module table
		# since M4 with a comment explaining exactly why; the wire path had no
		# equivalent, so a modified client could announce a tier whose *type* then
		# aborted `Modules.loadout` — which the host calls once per crew member
		# per frame — and stall the whole crew's simulation.
		"modules": Modules.sanitize_tiers(GameState.sub_dict(entry, "modules")),
		"archive": maxi(_wire_int(entry.get("archive", 0), 0), 0),
		"backdoor": theirs,
	}
	print("[Net] crew registered: %d = %s (archive %d, backdoor %02d, modules [%s])" % [
		id, clean, int(crew[id]["archive"]), theirs,
		Modules.describe(crew[id]["modules"] as Dictionary)])
	Run.on_crew_changed()
	# Config first, spawn second, both reliable on the same channel: the client
	# builds its geometry from the seed before its avatar arrives to stand on it.
	#
	# The config carries the layer's *worked* state as well as its identity —
	# which taps are drained, which shards are gone, whether the node is rooted,
	# whether exfiltration is already counting down. Before M4.8.1 the whole
	# catch-up payload was five positional numbers, and the only reconcile in the
	# game was for dead creatures. A joiner therefore arrived to live-looking taps
	# whose 2.5 s channel silently did nothing, a maintenance node that read
	# `ROOT MAINTENANCE NODE` and refused, and an uplink that read
	# `UPLINK LOCKED` — i.e. they could not exfiltrate at all.
	_receive_config.rpc_id(id, Rng.run_seed, Run.layer_number, Run.use_test_layer,
			Run.cycles, Run.cycles_max, Run.layer_state())
	_spawn_for_peer(id)
	# Dynamics are not seeded content, so they cannot be derived — they have to be
	# replayed. Only to the joiner: everybody else already has them.
	Run.replay_dynamics(id)
	_receive_crew.rpc(crew)
	_crew_notice.rpc("%s JOINED THE CREW" % clean)
	crew_changed.emit()


## Every program the gate has looked at this session — the crew that got in, and
## everybody it turned away. This is what the HUD's gate panel prints, so the
## host can see *who* is missing the backdoor rather than only that somebody was.
func gate_roster() -> Array:
	var needed: int = GameState.backdoor_for(Run.layer_number)
	var rows: Array = []
	var ids: Array = crew.keys()
	ids.sort()
	for id: int in ids:
		var entry: Dictionary = crew[id] as Dictionary
		rows.append({
			"name": String(entry.get("name", "AGENT")),
			"theirs": int(entry.get("backdoor", 0)),
			"needed": needed,
			"ok": true,
		})
	for row: Dictionary in refused_crew:
		rows.append({
			"name": String(row.get("name", "AGENT")),
			"theirs": int(row.get("theirs", 0)),
			"needed": int(row.get("needed", needed)),
			"ok": false,
		})
	return rows


func _disconnect_later(id: int) -> void:
	await get_tree().create_timer(0.35).timeout
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		multiplayer.multiplayer_peer.disconnect_peer(id)


## Client side of the gate. The menu is the right place to be told this, because
## the fix is "go and root that node", which is a decision about the next run.
@rpc("authority", "call_remote", "reliable")
func _injection_refused(needed: int, theirs: int, layer: int) -> void:
	var reason: String = "INJECTION REFUSED  ·  LAYER %02d NEEDS BACKDOOR %02d  ·  YOUR PROGRAM HAS %s" % [
		layer, needed, "NONE" if theirs <= 0 else "%02d" % theirs]
	push_warning("[Net] " + reason)
	leave(reason)


@rpc("authority", "call_remote", "reliable")
func _receive_crew(roster: Dictionary) -> void:
	crew = roster
	crew_changed.emit()


## The whole world in one packet: the seed every peer generates geometry from,
## which layer we are on, whether the host is running the hand-authored test
## layer, the current pool so a joiner's HUD is right on its first frame, and
## what the crew has already done to this layer (see `Run.layer_state`).
@rpc("authority", "call_remote", "reliable")
func _receive_config(value: int, layer: int, test_layer: bool,
		pool: float, pool_max: float, state: Dictionary) -> void:
	Rng.set_run_seed(value)
	Run.adopt(layer, test_layer, pool, pool_max, state)


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


## "Is this machine allowed to decide?" — with no peer assigned the answer is
## yes, because there is nobody else to be authority (an editor run of
## `layer.tscn`, or the frame before a join attaches its peer).
##
## `core/` has always paired `is_server()` with `has_multiplayer_peer()`; `world/`
## did not, and a bare `is_server()` with no peer pushes `No multiplayer peer is
## assigned` from `get_unique_id()` and returns false. One helper, one answer.
func is_authority() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	return multiplayer.is_server()


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
