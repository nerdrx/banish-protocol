extends Node
## Debug — permanent developer entry points driven by command-line user args.
##
## Everything after a bare `--` reaches us via OS.get_cmdline_user_args():
##
##   godot --headless --path . -- --server [--port 27015]
##       Dedicated host: no local player, no window.
##   godot --path . -- --autohost [--port N] [--name X]
##       Host and drop straight into the layer.
##   godot --path . -- --autojoin 127.0.0.1 [--port N] [--name X]
##       Join and drop straight into the layer.
##   ... -- --screenshot /tmp/shot.png 120
##       Wait 120 rendered frames after the local player spawns, save the
##       viewport to a PNG, then quit. Combines with the flags above. Framerate
##       is pinned to 60 while armed, so 120 frames is reliably 2 seconds.
##   ... -- --quit-in 12
##       Live for 12 seconds regardless. When paired with --screenshot it takes
##       over the process lifetime, which is how one instance stays up long
##       enough for a second instance to photograph it.
##
## M2 world selection (host-side; the host replicates the choice to clients):
##   --seed N        force the run seed instead of rolling one
##   --layer N       start the intrusion on layer N rather than 1
##   --testlayer     play M1's hand-authored greybox instead of procgen
##   --cycles N      start the shared pool at N instead of full (test siphons
##                   filling it, or set it near zero to test degradation)
##   --log-cycles    print the pool once a second, to measure drain rates
##
## M2 headless determinism check (no window, no networking):
##   godot --headless --path . -- --dumplayer SEED LAYER
##       Print the generated room graph as diffable text and exit.
##
## M2 automation. Real systems are exercised end to end — these drive the same
## input paths a player would, they do not shortcut the host validation:
##   --goto TARGET [delay]         teleport the local avatar there after `delay`
##                                 seconds, and again on every new layer.
##                                 TARGET: shaft | siphon | vault | nest | node |
##                                 uplink | corridor (looking down the longest
##                                 one — the shot that judges the architecture) |
##                                 decal (stand 3 m off a wall sign and read it) |
##                                 crew (the nearest corrupted crewmate)
##   --pitch RADIANS               override the lens pitch every `--goto` sets.
##                                 Negative looks down; -1.2 is "at your own
##                                 boots", which is the shot that proves the
##                                 first-person body is really there.
##   --hold-interact [delay]       hold E from `delay` seconds onward
##   --sprint                      hold forward + sprint (Cycles drain test)
##   --autodescend                 goto shaft + hold E on every layer, forever:
##                                 the soak that rides 1 -> 2 -> 3 -> 4
##   --decompile-at N              take lethal damage at N seconds. M3 routes
##                                 this through the real damage path, so it
##                                 corrupts in a crew and deletes solo.
##
## M3 flags:
##   --fire [delay]      hold the breaker's trigger from `delay` seconds onward
##   --flare [delay]     throw one flare at `delay` seconds
##   --aim               the local avatar tracks the nearest process with its
##                       lens. There is no mouse in an automated run, and a
##                       Scrubber circling you at knee height cannot be hit
##                       without one — this is how a capture frames a kill.
##   --grab [count]      hop the local avatar onto data shards until `count` are
##                       in its buffer. The pickup itself is the real one: the
##                       host still decides that a shard was absorbed
##   --exfil [delay]     the whole endgame, driven through the real channels:
##                       walk to the node, root it, walk to the uplink, call
##                       exfiltration, then stand on the pad until it fires
##   --no-antivirus      generate the layer but buy nothing hostile
##   --log-ai            per-second census of every process and its state, plus
##                       a line on every state transition and every tap ping
##
## M3.7 flags:
##   --log-fps [window]  per-`window`-second frame-rate census: average, 1% low
##                       and the worst frame in the window, plus draw calls and
##                       primitives. The look-dev merge quadrupled the fixture
##                       count per layer, so "does a two-client layer with
##                       creatures in it still hold 60" is now a number this
##                       build has to be able to print about itself. Uncaps the
##                       frame rate for the duration: under a compositor the
##                       renderer vsyncs to 60 and every census comes back
##                       "avg=60 1%low=60", which measures the display and not
##                       the game.
##
## M3.5 (Steam) flags:
##   --no-steam          never touch the Steam API, even with the client running.
##                       The ENet-only regression path on a Steam machine.
##   --app-id N          initialise against N instead of 480 (Spacewar).
##   --steamhost         host over the Steam transport (lobby + SteamMultiplayer-
##                       Peer) instead of ENet, and drop into the layer.
##   --steamjoin ID      join Steam lobby ID directly, the way an overlay invite
##                       would.
##   --steam-selftest    print SteamID, persona, lobby id, lobby metadata and the
##                       rich-presence readback a few seconds in. Pairs with
##                       --steamhost to prove a lobby is real without a second
##                       account.
##   --reset-achievements  wipe user://achievements.json (and clear our ids at
##                       Steam) before anything else runs.
##   --grant ID          unlock achievement ID at boot; repeatable. `--grant ALL`
##                       unlocks the lot. Toasts exactly like the real thing.

const BOOT_DELAY_FRAMES: int = 2

## True whenever this process was launched to drive itself rather than to be
## played. Automated runs share a live desktop with a human who is doing
## something else, so they never take keyboard focus and never capture the
## mouse — see `_stay_out_of_the_way`, Player._capture_mouse and Hud._set_paused.
var automated: bool = false

var screenshot_path: String = ""
var screenshot_frames: int = 120
var auto_quit_after: float = 0.0

## Set while a screenshot run is armed. Player honours it and ignores ALL local
## input. A windowed capture on a live desktop still receives the real user's
## cursor and keystrokes — without this the avatar wanders off mid-run and no two
## captures ever frame the same shot.
var lock_input: bool = false

# --- world selection (read by Net.host) -------------------------------------
var forced_seed: int = 0
var start_layer: int = 1
var use_test_layer: bool = false
## Negative means "start full".
var start_cycles: float = -1.0
var log_cycles: bool = false

# --- M3 world/AI selection ---------------------------------------------------
## Generate the layer with no antivirus in it, for isolating everything else.
var no_antivirus: bool = false
## Read by the director and both state machines.
var log_ai: bool = false

# --- M3.5 Steam / achievements (read by SteamHub and Achievements) ----------
## Hard off switch for the Steam API: the game runs its ENet paths untouched.
var no_steam: bool = false
## 0 means "use SteamHub.DEV_APP_ID" (480, Spacewar).
var steam_app_id: int = 0
## Print the Steam session back out of the API once it is up.
var steam_selftest: bool = false
var reset_achievements: bool = false
var granted_achievements: PackedStringArray = PackedStringArray()

# --- synthetic input (read by Player) ---------------------------------------
var hold_interact: bool = false
var hold_sprint: bool = false
var hold_forward: bool = false
var hold_fire: bool = false
## Track the nearest antivirus with the lens (read by Player).
var aim_antivirus: bool = false

var _mode: String = ""
var _address: String = "127.0.0.1"
var _port: int = Net.DEFAULT_PORT
var _name_override: String = ""
var _color_index: int = 0

var _dump_seed: int = 0
var _dump_layer: int = 1
## `--steamjoin` target.
var _lobby_id: int = 0

## `--pitch`. Applied on top of whatever a `--goto` target chose.
var pitch_override: float = 0.0
var _has_pitch: bool = false

var _goto: String = ""
var _goto_delay: float = 1.6
var _hold_delay: float = -1.0
var _auto_descend: bool = false
var _decompile_at: float = -1.0
var _fire_delay: float = -1.0
var _flare_delay: float = -1.0
var _exfil_delay: float = -1.0
var _grab_count: int = 0

## Seconds of shader-compilation and layer-build time excluded from the census.
const FPS_WARMUP: float = 4.0

## `--log-fps`. Zero disables.
var _fps_window: float = 0.0
var _fps_warmup: float = 0.0
var _fps_clock: float = 0.0
var _fps_samples: PackedFloat32Array = PackedFloat32Array()

var _shot_armed: bool = false
var _frames_left: int = 0
var _shot_taken: bool = false


func _ready() -> void:
	_parse_args(OS.get_cmdline_user_args())
	automated = not _mode.is_empty() or not screenshot_path.is_empty() \
			or auto_quit_after > 0.0 or steam_selftest
	if automated:
		_stay_out_of_the_way()
	if _mode == "dump":
		_dump_layer_graph.call_deferred()
		return
	if _mode.is_empty() and screenshot_path.is_empty() and auto_quit_after <= 0.0 \
			and not steam_selftest:
		set_process(false)
		return
	# Stays processing for the whole run, not just while a screenshot is armed:
	# `_enforce_mouse` has to be live from boot to quit, including across the
	# menu -> layer scene change and every descent after it.
	set_process(true)
	_boot.call_deferred()


## Automated runs are launched *next to* whatever the developer is actually
## doing — often a full-screen game on the other monitor. A capture that steals
## keyboard focus or grabs the cursor ruins both the desktop and the capture, so
## an automated window is opened as a bystander: never focused, never focusable,
## and never in possession of the pointer.
##
## This is a **hard rule, not a nicety**. An automated run that captures the
## mouse yanks the cursor out of whatever the developer was doing on the other
## monitor, and because it happens on a spawn — several seconds into a run that
## was supposed to be invisible — it is very hard to attribute. It has bitten
## this project once already.
##
## Three layers, deliberately redundant:
##   1. every `MOUSE_MODE_CAPTURED` call site asks `may_capture_mouse()` first
##      (Player._capture_mouse, Hud._set_paused)
##   2. the window is opened un-focusable
##   3. `_enforce_mouse()` below re-asserts VISIBLE every frame regardless, so a
##      capture from a path nobody thought of survives for at most one frame
##
## Belt, braces, and a second pair of braces. The correct runtime cost of this is
## "one enum comparison per frame during automated runs only", which is nothing.
func _stay_out_of_the_way() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## The single question every `MOUSE_MODE_CAPTURED` call site in the codebase has
## to ask. Kept here rather than duplicated as `if Debug.automated` at each site
## so that "what counts as automated" can never drift between them.
func may_capture_mouse() -> bool:
	return not automated and DisplayServer.get_name() != "headless"


## Layer 3 of the guard above: whatever anybody does, an automated run holds the
## pointer for at most one frame. Runs unconditionally while `automated`.
func _enforce_mouse() -> void:
	if not automated or DisplayServer.get_name() == "headless":
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE:
		push_warning("[Debug] something captured the mouse during an automated "
				+ "run; releasing it")
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _parse_args(args: PackedStringArray) -> void:
	var i: int = 0
	while i < args.size():
		var arg: String = args[i]
		match arg:
			"--server":
				_mode = "server"
			"--autohost":
				_mode = "host"
			"--autojoin":
				_mode = "join"
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_address = args[i]
			"--steamhost":
				_mode = "steamhost"
			"--steamjoin":
				_mode = "steamjoin"
				if i + 1 < args.size():
					i += 1
					_lobby_id = args[i].to_int()
			"--no-steam":
				no_steam = true
			"--app-id":
				if i + 1 < args.size():
					i += 1
					steam_app_id = args[i].to_int()
			"--steam-selftest":
				steam_selftest = true
			"--reset-achievements":
				reset_achievements = true
			"--grant":
				if i + 1 < args.size():
					i += 1
					granted_achievements.append(args[i])
			"--port":
				if i + 1 < args.size():
					i += 1
					_port = args[i].to_int()
			"--name":
				if i + 1 < args.size():
					i += 1
					_name_override = args[i]
			"--color":
				if i + 1 < args.size():
					i += 1
					_color_index = args[i].to_int()
			"--seed":
				if i + 1 < args.size():
					i += 1
					forced_seed = args[i].to_int()
			"--layer":
				if i + 1 < args.size():
					i += 1
					start_layer = maxi(args[i].to_int(), 1)
			"--testlayer":
				use_test_layer = true
			"--cycles":
				if i + 1 < args.size():
					i += 1
					start_cycles = args[i].to_float()
			"--log-cycles":
				log_cycles = true
			"--log-ai":
				log_ai = true
			"--log-fps":
				_fps_window = 5.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_fps_window = maxf(args[i].to_float(), 1.0)
			"--no-antivirus":
				no_antivirus = true
			"--aim":
				aim_antivirus = true
			"--grab":
				_grab_count = 6
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_grab_count = maxi(args[i].to_int(), 1)
			"--exfil":
				_exfil_delay = 3.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_exfil_delay = args[i].to_float()
			"--fire":
				_fire_delay = 3.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_fire_delay = args[i].to_float()
			"--flare":
				_flare_delay = 3.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_flare_delay = args[i].to_float()
			"--dumplayer":
				_mode = "dump"
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_dump_seed = args[i].to_int()
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_dump_layer = maxi(args[i].to_int(), 1)
			"--goto":
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_goto = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_goto_delay = args[i].to_float()
			"--hold-interact":
				_hold_delay = 3.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_hold_delay = args[i].to_float()
			"--decompile-at":
				if i + 1 < args.size():
					i += 1
					_decompile_at = args[i].to_float()
			"--pitch":
				if i + 1 < args.size():
					i += 1
					pitch_override = args[i].to_float()
					_has_pitch = true
			"--sprint":
				hold_sprint = true
				hold_forward = true
			"--autodescend":
				_auto_descend = true
				if _goto.is_empty():
					_goto = "shaft"
				if _hold_delay < 0.0:
					_hold_delay = _goto_delay + 1.2
			"--screenshot":
				if i + 1 < args.size():
					i += 1
					screenshot_path = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					screenshot_frames = maxi(args[i].to_int(), 1)
			"--quit-in":
				if i + 1 < args.size():
					i += 1
					auto_quit_after = args[i].to_float()
			_:
				pass
		i += 1


func _boot() -> void:
	# Autoloads are ready before the main scene is swapped in; give the tree a
	# couple of frames so our change_scene_to_file() is not overwritten.
	for _i in BOOT_DELAY_FRAMES:
		await get_tree().process_frame

	if _fps_window > 0.0:
		_uncap_frame_rate()
	if not screenshot_path.is_empty():
		_arm_screenshot()
	if auto_quit_after > 0.0:
		_quit_after(auto_quit_after)
	if not _goto.is_empty() or _hold_delay >= 0.0 or _decompile_at >= 0.0 \
			or _fire_delay >= 0.0 or _flare_delay >= 0.0 or _exfil_delay >= 0.0 \
			or _grab_count > 0:
		_arm_automation()

	match _mode:
		"server":
			print("[Debug] dedicated server on port %d" % _port)
			Net.host(_port, true)
		"host":
			GameState.local_name = GameState.sanitize_name(
					_name_override if not _name_override.is_empty() else "HOST-A")
			GameState.local_color = _pick_color(0)
			print("[Debug] autohost as %s" % GameState.local_name)
			Net.host(_port, false)
		"join":
			GameState.local_name = GameState.sanitize_name(
					_name_override if not _name_override.is_empty() else "CREW-B")
			GameState.local_color = _pick_color(1)
			print("[Debug] autojoin %s:%d as %s" % [_address, _port, GameState.local_name])
			Net.join(_address, _port)
		"steamhost":
			GameState.local_name = GameState.sanitize_name(
					_name_override if not _name_override.is_empty()
					else SteamHub.suggested_name())
			GameState.local_color = _pick_color(0)
			print("[Debug] steam host as %s" % GameState.local_name)
			Net.host_steam()
		"steamjoin":
			GameState.local_name = GameState.sanitize_name(
					_name_override if not _name_override.is_empty()
					else SteamHub.suggested_name())
			GameState.local_color = _pick_color(1)
			print("[Debug] steam join lobby %d as %s" % [_lobby_id, GameState.local_name])
			Net.join_steam(_lobby_id)
		_:
			pass

	if steam_selftest:
		_steam_selftest()


## `--steam-selftest`. Reads the session back *out of the Steam API* rather than
## trusting what we asked it to do: the ID and persona, the lobby we own, its
## metadata as Steam stores it, and the rich presence string a friend would see.
## This is how a Steam lobby is verified without a second Steam account.
func _steam_selftest() -> void:
	await get_tree().create_timer(4.0).timeout
	print("[SelfTest] ---- steam ----")
	print("[SelfTest] live=%s status=%s" % [str(SteamHub.live), SteamHub.status])
	if not SteamHub.live:
		return
	print("[SelfTest] app=%d id=%d persona=%s overlay=%s" % [
		Steam.getAppID(), SteamHub.steam_id, SteamHub.persona,
		str(Steam.isOverlayEnabled())])
	print("[SelfTest] transport=%s online=%s crew=%d" % [
		"STEAM" if Net.transport == Net.Transport.STEAM else "DIRECT",
		str(Net.is_online), Net.crew.size()])
	print("[SelfTest] lobby=%d owner=%s members=%d" % [
		SteamHub.lobby, str(SteamHub.is_lobby_owner), SteamHub.lobby_member_count()])
	print("[SelfTest] lobby data=%s" % str(SteamHub.lobby_data()))
	print("[SelfTest] rich presence readback='%s'" % SteamHub.presence_readback())
	print("[SelfTest] peer=%s" % (
		"none" if Net.multiplayer.multiplayer_peer == null
		else Net.multiplayer.multiplayer_peer.get_class()))
	print("[SelfTest] achievements=%d/%d counters=%s" % [
		Achievements.earned.size(), Achievements.DEFINITIONS.size(),
		str(Achievements.counters)])
	print("[SelfTest] ---------------")


func _pick_color(fallback_index: int) -> Color:
	var index: int = _color_index if _color_index > 0 else fallback_index
	return GameState.DEFAULT_COLORS[index % GameState.DEFAULT_COLORS.size()]


# ----------------------------------------------------------------- dumplayer --

## Headless determinism probe. Generates the graph for (seed, layer) and prints
## it; run it twice and diff, or run it with two seeds and confirm they differ.
func _dump_layer_graph() -> void:
	var graph: LayerGraph = LayerGraph.generate(_dump_seed, _dump_layer)
	print("run_seed=%d" % _dump_seed)
	print(graph.to_text())
	get_tree().quit(0)


# ---------------------------------------------------------------- automation --

func _arm_automation() -> void:
	Net.local_player_spawned.connect(_on_automation_player_ready, CONNECT_ONE_SHOT)
	# Every new layer re-arms, which is what makes --autodescend a soak rather
	# than a single descent.
	Run.layer_changed.connect(_on_automation_layer)


func _on_automation_player_ready(_player: Node) -> void:
	_run_automation()
	if _decompile_at >= 0.0:
		_decompile_later(_decompile_at)
	if _fire_delay >= 0.0:
		_fire_later(_fire_delay)
	if _flare_delay >= 0.0:
		_flare_later(_flare_delay)
	if _grab_count > 0:
		_grab_shards(_grab_count)
	# With `--autodescend` the exfil is deferred until a backdoor layer is
	# reached; see `_on_automation_layer`.
	if _exfil_delay >= 0.0 and not _auto_descend:
		_run_exfil(_exfil_delay)


func _decompile_later(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	print("[Debug] applying lethal damage to the local avatar")
	Run.request_debug_decompile()


func _fire_later(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	print("[Debug] holding the breaker trigger")
	hold_fire = true


## Drives the same path the input does, so the host's stock and Cycles checks are
## exercised rather than bypassed.
func _flare_later(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	var player: Node = Net.get_player(Net.local_id())
	var avatar: Player = player as Player
	if avatar == null or not is_instance_valid(avatar):
		push_warning("[Debug] --flare skipped: no local player")
		return
	print("[Debug] throwing a flare")
	avatar.throw_flare()


func _on_automation_layer(number: int) -> void:
	if not _auto_descend:
		return
	# The full loop, in one run: ride the shaft down to the first backdoor layer
	# and then play the endgame out through the real channels. Without this,
	# `--autodescend --exfil` would fire the exfil script on layer 1, where there
	# is no node to root, and the soak would never reach the thing it exists to
	# prove.
	if _exfil_delay >= 0.0 and bool(LayerParams.of(number)["has_backdoor"]):
		print("[Debug] autodescend: layer %d has a backdoor, running the exfil" % number)
		_auto_descend = false
		hold_interact = false
		_run_exfil(1.2)
		return
	print("[Debug] autodescend: now on layer %d, re-arming" % number)
	hold_interact = false
	_run_automation()


func _run_automation() -> void:
	if not _goto.is_empty():
		await get_tree().create_timer(_goto_delay).timeout
		_teleport_local(_goto)
	if _hold_delay >= 0.0:
		var wait: float = maxf(_hold_delay - _goto_delay, 0.1) if not _goto.is_empty() \
				else _hold_delay
		await get_tree().create_timer(wait).timeout
		print("[Debug] holding interact")
		hold_interact = true


## Host-side-equivalent dev teleport: moves the *local* avatar only, which is
## exactly what a client is allowed to do to itself under M1's client-authority
## movement. Each peer offsets sideways by its roster index so a mustered crew
## does not stack inside one capsule.
## Applies `--pitch` if it was given, otherwise the target's own choice.
func _pitch_for(default_pitch: float) -> float:
	return pitch_override if _has_pitch else default_pitch


func _teleport_local(where: String) -> void:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	var player: Node = Net.get_player(Net.local_id())
	if layer == null or player == null or not is_instance_valid(player):
		push_warning("[Debug] teleport '%s' skipped: no layer or no local player" % where)
		return

	var index: int = maxi(Net.crew.keys().find(Net.local_id()), 0)
	var avatar: Player = player as Player
	if avatar == null:
		return

	if where == "shaft":
		var shaft: Vector3 = Vector3(layer.get("shaft_position"))
		# Stood off the console, facing it (-Z). Only index 0 lines up with the
		# console probe; the rest just need to be inside the muster radius.
		var side: float = 0.0 if index == 0 else (1.9 if index % 2 == 1 else -1.9)
		avatar.teleport_to(shaft + Vector3(side, 0.35, 5.4), 0.0, _pitch_for(0.0))
		print("[Debug] teleported to drop shaft %s" % str(shaft))
	elif where == "node" or where == "uplink" or where == "vault" or where == "nest":
		var target: Vector3 = Vector3(layer.get(
				"backdoor_position" if where == "node" else
				("uplink_position" if where == "uplink" else
				("vault_position" if where == "vault" else "nest_position"))))
		if target.is_equal_approx(Vector3.ZERO):
			push_warning("[Debug] no '%s' on this layer" % where)
			return
		var lateral: float = 0.0 if index == 0 else (1.6 if index % 2 == 1 else -1.6)
		if where == "nest":
			# Stand in the middle of it, looking down: that is where the pack is,
			# and a Scrubber is well below the horizon.
			avatar.teleport_to(target + Vector3(lateral, 0.35, 0.0), 0.0, _pitch_for(-0.42))
			print("[Debug] teleported to nest %s" % str(target))
			return
		if where == "uplink":
			# Inside the pad looking outward at the console on its rim: standing
			# behind the console would be standing off the pad when it fires.
			avatar.teleport_to(target + Vector3(lateral, 0.35, 0.9), PI, _pitch_for(0.0))
			print("[Debug] teleported to uplink %s" % str(target))
			return
		# The node is channelled from its +Z face, same convention as the shaft.
		avatar.teleport_to(target + Vector3(lateral, 0.35, 3.4), 0.0, _pitch_for(0.0))
		print("[Debug] teleported to %s %s" % [where, str(target)])
	elif where == "decal":
		# Art-direction probe: stand off a wall sign and look at it. Signage that
		# cannot be read at three metres is not signage, and there is no other way
		# to check that from a level-wide screenshot.
		var sign: Decal = _pick_decal(layer)
		if sign == null:
			push_warning("[Debug] no decals on this layer")
			return
		# A decal projects along its own -Y; the wall it is printed on is that
		# way, so the reader stands the other way.
		var out: Vector3 = sign.global_transform.basis.y.normalized()
		var stand: Vector3 = sign.global_position + out * 4.2
		avatar.teleport_to(Vector3(stand.x, 0.35, stand.z),
				atan2(-(-out).x, -(-out).z),
				atan2(sign.global_position.y - 1.62, 4.2))
		print("[Debug] reading decal '%s' at %s out=%s stand=%s yaw=%.2f" % [
			String(sign.name), str(sign.global_position.snapped(Vector3.ONE * 0.1)),
			str(out.snapped(Vector3.ONE * 0.01)), str(stand.snapped(Vector3.ONE * 0.1)),
			atan2(-(-out).x, -(-out).z)])
	elif where == "corridor":
		var run: Vector3 = Vector3(layer.get("corridor_position"))
		if run.is_equal_approx(Vector3.ZERO):
			push_warning("[Debug] no corridor on this layer")
			return
		avatar.teleport_to(run + Vector3(0.0, 0.35, 0.0), float(layer.get("corridor_yaw")),
				_pitch_for(0.0))
		print("[Debug] teleported to corridor %s" % str(run))
	elif where == "crew":
		var casualty: Node3D = _nearest_corrupted(avatar)
		if casualty == null:
			push_warning("[Debug] no corrupted crewmate to walk to")
			return
		# Stood just off them on whichever side is actually open, looking at them.
		# A corrupted crewmate is on the floor and often went down against a wall,
		# so the approach is probed rather than assumed; a standing one wants a
		# level look instead of a downward one.
		var approach: Vector3 = _clear_side(casualty)
		var down: bool = Run.is_corrupted(int(String(casualty.name)))
		avatar.teleport_to(casualty.global_position + approach + Vector3.UP * 0.35,
				atan2(approach.x, approach.z), _pitch_for(-0.4 if down else -0.06))
		print("[Debug] teleported to crewmate %s at %s (approach %s)" % [
			String(casualty.name), str(casualty.global_position.snapped(Vector3.ONE * 0.1)),
			str(approach.snapped(Vector3.ONE * 0.1))])
	elif where == "siphon":
		var taps: Array = layer.get("siphon_positions")
		var approaches: Array = layer.get("siphon_approaches")
		if taps.is_empty():
			push_warning("[Debug] no siphon taps on this layer")
			return
		var pick: int = index % taps.size()
		var tap: Vector3 = taps[pick]
		var stand: Vector3 = approaches[pick] if pick < approaches.size() \
				else tap + Vector3(0.0, 0.0, 2.6)
		var look: Vector3 = tap - stand
		avatar.teleport_to(stand + Vector3.UP * 0.35, atan2(-look.x, -look.z),
				_pitch_for(0.0))
		print("[Debug] teleported to siphon tap %d %s" % [pick, str(tap)])
	else:
		push_warning("[Debug] unknown --goto target '%s'" % where)


## A decal to photograph: the one nearest the crew's spawn, so the probe lands
## somewhere the layer actually lit rather than in a nest.
func _pick_decal(layer: Node) -> Decal:
	var best: Decal = null
	var best_distance: float = INF
	var origin: Vector3 = Vector3(layer.get_spawn_point(0).origin)
	for node: Node in layer.find_children("*", "Decal", true, false):
		var sign: Decal = node as Decal
		if sign == null:
			continue
		var distance: float = sign.global_position.distance_to(origin)
		if distance < best_distance:
			best_distance = distance
			best = sign
	return best


## Walks the avatar onto shard after shard until its buffer holds `count`. The
## absorb is the real one — the host still has to agree the shard was reached —
## so this exercises the salvage path rather than writing a number into it.
func _grab_shards(count: int) -> void:
	await get_tree().create_timer(1.2).timeout
	for i: int in count:
		var player: Node = Net.get_player(Net.local_id())
		var avatar: Player = player as Player
		if avatar == null or not is_instance_valid(avatar) or Run.run_over:
			return
		var shard: DataShard = _nearest_shard(avatar)
		if shard == null:
			push_warning("[Debug] --grab: no shards left on this layer")
			return
		avatar.teleport_to(shard.global_position - Vector3(0.0, DataShard.REST_HEIGHT, 0.0),
				avatar.rotation.y)
		await get_tree().create_timer(0.45).timeout
	print("[Debug] grabbed shards: buffer holds %d" % Run.local_buffered())


func _nearest_shard(from: Node3D) -> DataShard:
	var best: DataShard = null
	var best_distance: float = INF
	for node: Node in get_tree().get_nodes_in_group("data_shards"):
		var shard: DataShard = node as DataShard
		if shard == null or not is_instance_valid(shard):
			continue
		if Run.is_shard_taken(shard.shard_index):
			continue
		var distance: float = shard.global_position.distance_to(from.global_position)
		if distance < best_distance:
			best_distance = distance
			best = shard
	return best


## The endgame, end to end, through the same channels a player would hold: root
## the node, call the uplink, then stand on the pad. Every step waits on real
## replicated state rather than on a timer, so a slow host cannot make it lie.
func _run_exfil(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	_teleport_local("node")
	await get_tree().create_timer(0.4).timeout
	hold_interact = true
	if not await _wait_until(func() -> bool: return Run.backdoor_rooted, 20.0):
		push_warning("[Debug] --exfil gave up waiting for the node to root")
		return

	hold_interact = false
	await get_tree().create_timer(0.4).timeout
	_teleport_local("uplink")
	await get_tree().create_timer(0.4).timeout
	hold_interact = true
	if not await _wait_until(func() -> bool: return Run.exfil_calling, 20.0):
		push_warning("[Debug] --exfil gave up waiting for the uplink")
		return

	hold_interact = false
	print("[Debug] exfiltration called; standing on the pad")


## Polls `test` until it passes or `limit` seconds go by. Returns whether it
## passed; a run that has already ended stops waiting immediately.
func _wait_until(test: Callable, limit: float) -> bool:
	var waited: float = 0.0
	while waited < limit:
		if bool(test.call()):
			return true
		if Run.run_over:
			return false
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	return false


## An offset from `body` with nothing solid in it. A shard-grabbing avatar tends
## to go down two metres from a wall, and dropping the rescuer inside that wall
## points its crosshair at masonry.
func _clear_side(body: Node3D) -> Vector3:
	var space: PhysicsDirectSpaceState3D = body.get_world_3d().direct_space_state
	var from: Vector3 = body.global_position + Vector3.UP * 1.0
	var best: Vector3 = Vector3(0.0, 0.0, 1.9)
	if space == null:
		return best

	var best_clearance: float = -1.0
	for i: int in 8:
		var angle: float = TAU * float(i) / 8.0
		var direction: Vector3 = Vector3(sin(angle), 0.0, cos(angle))
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				from, from + direction * 3.0)
		query.collision_mask = 1
		var hit: Dictionary = space.intersect_ray(query)
		var clearance: float = 3.0 if hit.is_empty() \
				else from.distance_to(Vector3(hit["position"]))
		if clearance > best_clearance:
			best_clearance = clearance
			best = direction * minf(1.9, maxf(clearance - 0.6, 0.8))
	return best


## Nearest crewmate for `--goto crew`.
##
## Prefers a corrupted one — that is the automated half of a restore, with the
## channel itself left to `--hold-interact`. Falls back to any living crewmate,
## which is how a two-instance capture gets a crewmate in frame at all: without
## the fallback the only way to photograph another player was to hurt them
## first.
func _nearest_corrupted(from: Node3D) -> Node3D:
	var downed: Node3D = _nearest_of(from, Run.corrupted_crew())
	if downed != null:
		return downed
	var living: Array[int] = []
	for id: int in Net.crew.keys():
		if int(id) != Net.local_id() and Run.is_running(int(id)):
			living.append(int(id))
	return _nearest_of(from, living)


func _nearest_of(from: Node3D, peers: Array) -> Node3D:
	var best: Node3D = null
	var best_distance: float = INF
	for peer: int in peers:
		if peer == Net.local_id():
			continue
		var node: Node = Net.get_player(peer)
		if node == null or not is_instance_valid(node):
			continue
		var body: Node3D = node as Node3D
		var distance: float = body.global_position.distance_to(from.global_position)
		if distance < best_distance:
			best_distance = distance
			best = body
	return best


# ------------------------------------------------------------------ fps log --

## Takes the brakes off so the census measures the renderer rather than the
## monitor. Only ever called by `--log-fps`, so a played session keeps its vsync.
func _uncap_frame_rate() -> void:
	Engine.max_fps = 0
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	print("[FPS] vsync disabled for the census")



## Per-window frame-rate census.
##
## The average alone is nearly useless for judging a game like this: a layer can
## sit at 300 fps and still be unplayable if it drops a frame every time a
## Sentinel's shadow atlas re-renders. The 1% low is the number that decides
## whether the merge shipped, and the worst frame is what to go and look at.
func _sample_fps(delta: float) -> void:
	if _fps_window <= 0.0:
		return
	# The first seconds of a run are shader compilation and the layer build. They
	# are real costs and they are worth knowing about, but they are not what
	# "does a two-client layer hold 60" is asking, and leaving them in drags every
	# 1% low to 1 fps and makes the number useless.
	_fps_warmup += delta
	if _fps_warmup < FPS_WARMUP:
		return
	_fps_samples.append(float(Engine.get_frames_per_second()))
	_fps_clock += delta
	if _fps_clock < _fps_window:
		return
	_fps_clock = 0.0

	var sorted: Array[float] = []
	for value: float in _fps_samples:
		if value > 0.0:
			sorted.append(value)
	_fps_samples.clear()
	if sorted.is_empty():
		return
	sorted.sort()

	var total: float = 0.0
	for value: float in sorted:
		total += value
	var low_index: int = maxi(int(float(sorted.size()) * 0.01), 0)
	print("[FPS] avg=%.0f  1%%low=%.0f  min=%.0f  frames=%d  draws=%d  prims=%dk" % [
		total / float(sorted.size()), sorted[low_index], sorted[0], sorted.size(),
		RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000])


# ---------------------------------------------------------------- screenshot --

func _arm_screenshot() -> void:
	if DisplayServer.get_name() == "headless":
		push_warning("[Debug] --screenshot ignored: headless has no framebuffer")
		screenshot_path = ""
		return
	# Pin the framerate so a frame budget is also a wall-clock budget. Uncapped,
	# this machine renders 600 frames in ~2 s, which silently made the host quit
	# before a second instance could finish connecting.
	Engine.max_fps = 60
	lock_input = true

	_frames_left = screenshot_frames
	if _mode == "host" or _mode == "join":
		Net.local_player_spawned.connect(_on_local_player_spawned, CONNECT_ONE_SHOT)
		# A refused/timed-out connection is a state worth photographing too.
		Net.connect_failed.connect(_on_connect_failed, CONNECT_ONE_SHOT)
		# Backstop: if we never spawn (connection refused), still shoot + quit so
		# an automated run can never hang.
		_fail_safe(float(screenshot_frames) / 60.0 + 20.0)
	else:
		_shot_armed = true
	set_process(true)


func _on_local_player_spawned(_player: Node) -> void:
	print("[Debug] local player spawned, screenshot in %d frames" % _frames_left)
	_shot_armed = true


func _on_connect_failed(reason: String) -> void:
	print("[Debug] connect failed (%s), screenshot in %d frames" % [reason, _frames_left])
	_shot_armed = true


func _process(delta: float) -> void:
	_enforce_mouse()
	_sample_fps(delta)
	if not _shot_armed or _shot_taken:
		return
	_frames_left -= 1
	if _frames_left <= 0:
		_shot_taken = true
		_capture.call_deferred()


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var err: Error = image.save_png(screenshot_path)
	if err == OK:
		print("[Debug] screenshot saved: %s (%dx%d)" % [
			screenshot_path, image.get_width(), image.get_height()])
	else:
		push_error("[Debug] screenshot failed: %s" % error_string(err))
	await get_tree().process_frame
	# `--quit-in` owns the process lifetime when both are given, so a host can
	# stay up past its own screenshot while a second instance takes theirs.
	if auto_quit_after <= 0.0:
		get_tree().quit(0 if err == OK else 1)


func _fail_safe(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	if not _shot_taken:
		push_warning("[Debug] fail-safe fired: capturing without a spawned player")
		_shot_taken = true
		_capture()


func _quit_after(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	print("[Debug] --quit-in elapsed")
	get_tree().quit()
