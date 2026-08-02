extends Node
## SteamHub — the Steam API lifecycle, lobbies, invites and rich presence.
##
## NULLVOID treats Steam as a *transport and a shop window*, never a dependency
## (DESIGN.md "Steam Integration"). Everything in here is optional: if the client
## is not running, the user is not logged in, the process is headless, or init
## simply fails, `live` stays false, every call below turns into a no-op, and the
## game plays exactly as it did in M1–M3 over ENet.
##
## Init policy — Steam is attempted only when all of these hold:
##   * the GodotSteam GDExtension loaded (addons/godotsteam, committed)
##   * we have a display (never in `--headless`; the dedicated server is ENet-only)
##   * `--no-steam` was not passed
## Failure is reported once, at boot, and then forgotten.
##
## App ID 480 is Valve's public test app (Spacewar). It is what NULLVOID develops
## against until it has its own Steam Direct page: lobbies, P2P sockets, invites,
## overlay and rich presence all work on it. Its *achievement* IDs are Valve's,
## not ours, so `Achievements` keeps the local file as the source of truth and
## only mirrors — see src/core/achievements.gd.

## Emitted once the answer to "do we have Steam?" is known.
signal ready_changed
## Host path: our lobby exists and can be hosted on.
signal lobby_created(lobby_id: int)
## Client path: we are inside `lobby_id` and may connect to its owner.
signal lobby_entered(lobby_id: int)
## Any lobby operation that did not work out, with a menu-ready reason.
signal lobby_failed(reason: String)
## Result of `refresh_friend_lobbies()`: an array of
## {"lobby": int, "steam_id": int, "name": String}.
signal friend_lobbies_updated(lobbies: Array)
## Somebody entered or left the lobby (not the game session — that is Net).
signal lobby_members_changed
## The overlay/friends list asked us to join a lobby, or Steam launched us with
## `+connect_lobby`. The menu turns this into an actual join.
signal join_requested(lobby_id: int)

## Valve's Spacewar. Replaced by NULLVOID's own ID at Steam Direct time.
const DEV_APP_ID: int = 480
const MAX_CREW: int = 4

## Lobby metadata keys. Prefixed so they never collide with another Spacewar
## project's lobbies during development on 480.
const KEY_GAME: String = "nv_game"
const KEY_HOST: String = "nv_host"
const KEY_CREW: String = "nv_crew"
const KEY_LAYER: String = "nv_layer"
const KEY_VERSION: String = "nv_version"
const GAME_TAG: String = "BANISH PROTOCOL"

## True when the GDExtension is present *and* the API initialised.
var live: bool = false
## Why we are not live, for the menu's DIRECT-only fallback line.
var status: String = "STEAM NOT STARTED"
var steam_id: int = 0
var persona: String = ""
var app_id: int = DEV_APP_ID

## The lobby we own (host) or belong to (client). 0 when we are in none.
var lobby: int = 0
var is_lobby_owner: bool = false

var _presence_state: String = ""
var _pending_join: int = 0


func _ready() -> void:
	# Autoload order puts Debug before us, so its flags are already parsed.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_init_steam()


func _process(_delta: float) -> void:
	# Steam's callbacks are pumped by hand rather than embedded, so everything
	# below arrives on Godot's frame and never re-enters the engine off-thread.
	Steam.run_callbacks()


# ------------------------------------------------------------------ lifecycle --

func _init_steam() -> void:
	set_process(false)

	if not ClassDB.class_exists("Steam"):
		status = "GODOTSTEAM ADDON MISSING"
		push_warning("[Steam] %s — running ENet-only" % status)
		ready_changed.emit()
		return
	if Debug.no_steam:
		status = "STEAM DISABLED (--no-steam)"
		print("[Steam] %s" % status)
		ready_changed.emit()
		return
	if DisplayServer.get_name() == "headless":
		# The dedicated server is ENet-only by design, and headless test runs must
		# behave identically on a machine with no Steam client at all.
		status = "HEADLESS: STEAM SKIPPED"
		print("[Steam] %s" % status)
		ready_changed.emit()
		return

	app_id = Debug.steam_app_id if Debug.steam_app_id > 0 else DEV_APP_ID
	var result: Dictionary = Steam.steamInitEx(app_id, false)
	var code: int = int(result.get("status", -1))
	if code != 0:
		status = "STEAM INIT FAILED (%d %s)" % [code, String(result.get("verbal", ""))]
		push_warning("[Steam] %s — running ENet-only" % status)
		ready_changed.emit()
		return

	live = true
	set_process(true)
	steam_id = Steam.getSteamID()
	persona = Steam.getPersonaName()
	status = "STEAM READY"
	print("[Steam] initialised on app %d as %s (%d), overlay=%s" % [
		Steam.getAppID(), persona, steam_id, str(Steam.isOverlayEnabled())])

	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_chat_update.connect(_on_lobby_chat_update)
	Steam.lobby_match_list.connect(_on_lobby_match_list)
	Steam.join_requested.connect(_on_join_requested)
	Steam.lobby_invite.connect(_on_lobby_invite)

	set_presence_menu()
	_read_launch_lobby()
	ready_changed.emit()


func _exit_tree() -> void:
	if not live:
		return
	# Order matters on the way out: SteamMultiplayerPeer talks to
	# SteamNetworkingSockets in its destructor, and doing that after
	# SteamAPI_Shutdown aborts the process. Drop the peer first — it is
	# RefCounted, so clearing the reference frees it here and now.
	if Net.transport == Net.Transport.STEAM and Net.multiplayer.multiplayer_peer != null:
		Net.multiplayer.multiplayer_peer.close()
		Net.multiplayer.multiplayer_peer = null
	leave_lobby()
	Steam.steamShutdown()


## The Steam name, when we have one — the menu offers it as your callsign.
func suggested_name() -> String:
	return persona


# --------------------------------------------------------------------- lobby --

## Host path. Friends-only by default (DESIGN.md); the lobby exists before the
## peer does, because SteamMultiplayerPeer hosts *into* a lobby it owns.
func create_lobby(lobby_type: int = -1) -> bool:
	if not live:
		lobby_failed.emit("STEAM NOT AVAILABLE")
		return false
	if lobby != 0:
		leave_lobby()
	var kind: int = lobby_type if lobby_type >= 0 else Steam.LOBBY_TYPE_FRIENDS_ONLY
	print("[Steam] creating lobby (type %d, max %d)" % [kind, MAX_CREW])
	Steam.createLobby(kind, MAX_CREW)
	return true


func join_lobby(lobby_id: int) -> bool:
	if not live:
		lobby_failed.emit("STEAM NOT AVAILABLE")
		return false
	if lobby_id <= 0:
		lobby_failed.emit("INVALID LOBBY")
		return false
	if lobby == lobby_id:
		lobby_entered.emit(lobby_id)
		return true
	if lobby != 0:
		leave_lobby()
	print("[Steam] joining lobby %d" % lobby_id)
	Steam.joinLobby(lobby_id)
	return true


func leave_lobby() -> void:
	if not live or lobby == 0:
		return
	print("[Steam] leaving lobby %d" % lobby)
	Steam.leaveLobby(lobby)
	lobby = 0
	is_lobby_owner = false
	lobby_members_changed.emit()


## Host-side lobby metadata. Also what a friend's client reads before joining,
## and what the verification pass reads back to prove the lobby is real.
func publish_lobby_state(crew_size: int, layer: int) -> void:
	if not live or lobby == 0 or not is_lobby_owner:
		return
	Steam.setLobbyData(lobby, KEY_GAME, GAME_TAG)
	Steam.setLobbyData(lobby, KEY_HOST, persona)
	Steam.setLobbyData(lobby, KEY_CREW, "%d/%d" % [crew_size, MAX_CREW])
	Steam.setLobbyData(lobby, KEY_LAYER, str(layer))
	Steam.setLobbyData(lobby, KEY_VERSION, GAME_TAG + " M3.5")


func lobby_data() -> Dictionary:
	if not live or lobby == 0:
		return {}
	return Steam.getAllLobbyData(lobby)


func lobby_member_count() -> int:
	if not live or lobby == 0:
		return 0
	return Steam.getNumLobbyMembers(lobby)


## The overlay's invite dialog. No IPs, no lobby ids typed by hand — this and the
## friends list are the only two ways into a Steam session.
func open_invite_overlay() -> bool:
	if not live or lobby == 0:
		return false
	Steam.activateGameOverlayInviteDialog(lobby)
	return true


## Friends' joinable NULLVOID lobbies. Friends-only lobbies are invisible to
## `requestLobbyList` by design, so the friends list is the real source: Steam
## reports the lobby each friend is sitting in for this app.
func refresh_friend_lobbies() -> Array:
	var found: Array = []
	if not live:
		friend_lobbies_updated.emit(found)
		return found
	var count: int = Steam.getFriendCount(Steam.FRIEND_FLAG_IMMEDIATE)
	for i: int in count:
		var friend_id: int = Steam.getFriendByIndex(i, Steam.FRIEND_FLAG_IMMEDIATE)
		var played: Dictionary = Steam.getFriendGamePlayed(friend_id)
		if played.is_empty():
			continue
		if int(played.get("id", 0)) != app_id:
			continue
		var friend_lobby: int = int(played.get("lobby", 0))
		if friend_lobby == 0:
			continue
		found.append({
			"lobby": friend_lobby,
			"steam_id": friend_id,
			"name": Steam.getFriendPersonaName(friend_id),
		})
	print("[Steam] friend lobby scan: %d friend(s) in this app" % found.size())
	friend_lobbies_updated.emit(found)
	return found


# ------------------------------------------------------------- rich presence --

## DESIGN.md: "Descending · LAYER 07 · 3/4 crew" — spelled with the menu's ASCII
## `//` separator rather than a middot, because Steam hands rich presence to
## friends' clients as raw bytes and a non-ASCII separator comes back mangled.
##
## `steam_display` is the key a real app ID resolves against its localisation
## tokens; `status` is the legacy plain string, and it is what we read back to
## prove the call landed while we develop on 480 (which has no tokens of ours).
func set_presence(state: String, extra: Dictionary = {}) -> void:
	if not live:
		return
	_presence_state = state
	Steam.setRichPresence("status", state)
	Steam.setRichPresence("steam_display", "#Status")
	for key: String in extra.keys():
		Steam.setRichPresence(key, String(extra[key]))


func set_presence_menu() -> void:
	set_presence("IDLE // NO INTRUSION", {"nv_state": "menu"})


func set_presence_lobby(crew_size: int) -> void:
	set_presence("ASSEMBLING CREW // %d/%d" % [crew_size, MAX_CREW], {
		"nv_state": "lobby",
		"nv_crew": str(crew_size),
	})


func set_presence_run(layer: int, crew_size: int) -> void:
	set_presence("DESCENDING // LAYER %02d // %d/%d CREW" % [
		layer, crew_size, MAX_CREW], {
		"nv_state": "run",
		"nv_layer": str(layer),
		"nv_crew": str(crew_size),
	})


## Reads our own rich presence back out of Steam. Verification uses it; so does
## `--steam-selftest`.
func presence_readback() -> String:
	if not live:
		return ""
	return Steam.getFriendRichPresence(steam_id, "status")


# -------------------------------------------------------------- invite entry --

## `+connect_lobby <id>` — how Steam launches the game when a friend accepts an
## invite while we are not running.
func _read_launch_lobby() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(Steam.getLaunchCommandLine().split(" ", false))
	for i: int in args.size():
		if args[i] == "+connect_lobby" and i + 1 < args.size():
			var id: int = args[i + 1].to_int()
			if id > 0:
				print("[Steam] launched with +connect_lobby %d" % id)
				_pending_join = id
				# The menu is not up yet; hand it over on the next frame.
				_emit_pending_join.call_deferred()
			return


func _emit_pending_join() -> void:
	if _pending_join <= 0:
		return
	var id: int = _pending_join
	_pending_join = 0
	join_requested.emit(id)


# --------------------------------------------------------------- signal glue --

func _on_lobby_created(connect_result: int, lobby_id: int) -> void:
	if connect_result != 1:
		var reason: String = "STEAM REFUSED THE LOBBY (%d)" % connect_result
		push_warning("[Steam] " + reason)
		lobby_failed.emit(reason)
		return
	lobby = lobby_id
	is_lobby_owner = true
	Steam.setLobbyJoinable(lobby, true)
	publish_lobby_state(1, 1)
	print("[Steam] lobby %d created, owner %d" % [lobby, Steam.getLobbyOwner(lobby)])
	lobby_created.emit(lobby)
	lobby_members_changed.emit()


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:
		var reason: String = "COULD NOT ENTER LOBBY (%d)" % response
		push_warning("[Steam] " + reason)
		lobby = 0
		lobby_failed.emit(reason)
		return
	lobby = lobby_id
	is_lobby_owner = Steam.getLobbyOwner(lobby_id) == steam_id
	print("[Steam] entered lobby %d (%d member(s), owner=%s)" % [
		lobby_id, Steam.getNumLobbyMembers(lobby_id), str(is_lobby_owner)])
	lobby_entered.emit(lobby_id)
	lobby_members_changed.emit()


## Membership churn. The game session's own join/leave flow is Net's — this only
## keeps the lobby metadata and presence honest, and tells the host when the
## lobby has emptied out.
func _on_lobby_chat_update(lobby_id: int, changed_id: int, _making_change: int,
		chat_state: int) -> void:
	if lobby_id != lobby:
		return
	var who: String = Steam.getFriendPersonaName(changed_id)
	match chat_state:
		Steam.CHAT_MEMBER_STATE_CHANGE_ENTERED:
			print("[Steam] %s entered the lobby" % who)
		Steam.CHAT_MEMBER_STATE_CHANGE_LEFT, Steam.CHAT_MEMBER_STATE_CHANGE_DISCONNECTED:
			print("[Steam] %s left the lobby" % who)
		_:
			pass
	# The owner can change under us when the host quits: Steam hands the lobby to
	# whoever is left, and the leftovers should not think they are still hosting.
	is_lobby_owner = Steam.getLobbyOwner(lobby_id) == steam_id
	lobby_members_changed.emit()


func _on_lobby_match_list(lobbies: Array) -> void:
	# Only used if we ever open public lobbies; friends-only lobbies never appear
	# here. Kept so the signal is not left dangling.
	friend_lobbies_updated.emit(lobbies)


func _on_join_requested(lobby_id: int, friend_id: int) -> void:
	print("[Steam] join requested by %s -> lobby %d" % [
		Steam.getFriendPersonaName(friend_id), lobby_id])
	join_requested.emit(lobby_id)


func _on_lobby_invite(inviter: int, lobby_id: int, _game: int) -> void:
	print("[Steam] invited to lobby %d by %s" % [
		lobby_id, Steam.getFriendPersonaName(inviter)])
