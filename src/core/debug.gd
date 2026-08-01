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
##   --goto shaft|siphon [delay]   teleport the local avatar there after `delay`
##                                 seconds, and again on every new layer
##   --hold-interact [delay]       hold E from `delay` seconds onward
##   --sprint                      hold forward + sprint (Cycles drain test)
##   --autodescend                 goto shaft + hold E on every layer, forever:
##                                 the soak that rides 1 -> 2 -> 3 -> 4
##   --decompile-at N              ask the host to zero this peer's integrity at
##                                 N seconds, to exercise the spectator cam

const BOOT_DELAY_FRAMES: int = 2

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

# --- synthetic input (read by Player) ---------------------------------------
var hold_interact: bool = false
var hold_sprint: bool = false
var hold_forward: bool = false

var _mode: String = ""
var _address: String = "127.0.0.1"
var _port: int = Net.DEFAULT_PORT
var _name_override: String = ""
var _color_index: int = 0

var _dump_seed: int = 0
var _dump_layer: int = 1

var _goto: String = ""
var _goto_delay: float = 1.6
var _hold_delay: float = -1.0
var _auto_descend: bool = false
var _decompile_at: float = -1.0

var _shot_armed: bool = false
var _frames_left: int = 0
var _shot_taken: bool = false


func _ready() -> void:
	_parse_args(OS.get_cmdline_user_args())
	if _mode == "dump":
		_dump_layer_graph.call_deferred()
		return
	if _mode.is_empty() and screenshot_path.is_empty() and auto_quit_after <= 0.0:
		set_process(false)
		return
	_boot.call_deferred()


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

	if not screenshot_path.is_empty():
		_arm_screenshot()
	if auto_quit_after > 0.0:
		_quit_after(auto_quit_after)
	if not _goto.is_empty() or _hold_delay >= 0.0 or _decompile_at >= 0.0:
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
		_:
			pass


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


func _decompile_later(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	print("[Debug] requesting decompile of the local avatar")
	Run.request_debug_decompile()


func _on_automation_layer(number: int) -> void:
	if not _auto_descend:
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
		avatar.teleport_to(shaft + Vector3(side, 0.35, 5.4), 0.0)
		print("[Debug] teleported to drop shaft %s" % str(shaft))
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
		avatar.teleport_to(stand + Vector3.UP * 0.35, atan2(-look.x, -look.z))
		print("[Debug] teleported to siphon tap %d %s" % [pick, str(tap)])
	else:
		push_warning("[Debug] unknown --goto target '%s'" % where)


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


func _process(_delta: float) -> void:
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
