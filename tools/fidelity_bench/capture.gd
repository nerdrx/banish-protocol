extends SceneTree
## Standalone capture entrypoint for the fidelity pass. NOT part of the game.
##
##   godot --path . --script tools/fidelity_bench/capture.gd -- \
##       --scene res://tools/fidelity_bench/showcase.tscn \
##       --out /tmp/shot.png --size 1920x1080 --frames 240 [--cam CameraName]
##
## WHY THIS EXISTS RATHER THAN `--screenshot`
## `src/core/debug.gd` already owns a perfectly good capture path, and the
## fidelity milestone is explicitly forbidden from touching that file (a
## parallel workstream owns it). Debug's path is also wired to the *game*: it
## boots the main menu, waits for a player spawn, and reads a dozen automation
## flags. None of that applies to photographing a lookdev scene that has no
## player in it. So this is a second, dumber door into the same room — load one
## scene, let the temporal effects settle, grab the framebuffer, quit.
##
## THE FRAME COUNT IS NOT ARBITRARY. Every expensive buffer in this project's
## look is temporally accumulated: TAA, SSR, SSIL, and the volumetric fog's
## reprojection (0.94, i.e. a ~16-frame time constant, and in practice much
## longer for the fog's low-frequency content). A capture taken at frame 5 is a
## photograph of a renderer that has not finished thinking. 240 frames at 60 fps
## is four seconds of settling, which is past the point where successive frames
## stop differing. If a shot looks noisy, raise this before you touch anything
## else.
##
## Runs windowed, so it needs an output. NEVER run it against the user's
## session. `tools/fidelity_bench/shoot.sh` is the only supported entrypoint: it
## wraps this in `gamescope --backend headless` with DISPLAY and WAYLAND_DISPLAY
## unset, so there is no desktop for a window to land on. This machine runs a
## live Wayland session with the game usually fullscreen on it; a capture that
## inherits that session opens a real window on top of whatever the user is
## doing and may grab the pointer. Same hard rule Debug._stay_out_of_the_way
## enforces from inside the game.

var _scene_path: String = ""
var _out_path: String = ""
var _frames: int = 240
var _width: int = 1920
var _height: int = 1080
var _cam: String = ""
var _fps_probe: bool = false


func _init() -> void:
	_parse_args()
	if _scene_path.is_empty() or _out_path.is_empty():
		push_error("[Capture] --scene and --out are both required")
		quit(2)
		return
	_run.call_deferred()


func _parse_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		match args[i]:
			"--scene":
				i += 1
				if i < args.size():
					_scene_path = args[i]
			"--out":
				i += 1
				if i < args.size():
					_out_path = args[i]
			"--frames":
				i += 1
				if i < args.size():
					_frames = maxi(args[i].to_int(), 1)
			"--cam":
				i += 1
				if i < args.size():
					_cam = args[i]
			"--fps":
				_fps_probe = true
			"--size":
				i += 1
				if i < args.size():
					var wh: PackedStringArray = args[i].split("x")
					if wh.size() == 2:
						_width = maxi(wh[0].to_int(), 16)
						_height = maxi(wh[1].to_int(), 16)
		i += 1


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(_width, _height))
	root.content_scale_size = Vector2i(_width, _height)
	# The window is only ever a framebuffer here. Never let it take the pointer:
	# a capture that grabs the mouse ruins whatever the user was doing, and it
	# ruins the capture too.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	var packed: PackedScene = load(_scene_path) as PackedScene
	if packed == null:
		push_error("[Capture] cannot load %s" % _scene_path)
		quit(3)
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)

	if not _cam.is_empty():
		var cam: Camera3D = scene.find_child(_cam, true, false) as Camera3D
		if cam == null:
			push_error("[Capture] no Camera3D named '%s' in %s" % [_cam, _scene_path])
		else:
			cam.current = true

	# Warm-up pass with the frame limiter off, then the settle pass at a pinned
	# rate so "frames" and "seconds" mean the same thing.
	Engine.max_fps = 0
	for _i in 8:
		await process_frame
	Engine.max_fps = 60

	var t_start: int = Time.get_ticks_usec()
	for _i in _frames:
		await process_frame
	var elapsed_us: int = Time.get_ticks_usec() - t_start

	# One extra RenderingServer sync: get_texture() reads the LAST completed
	# frame, and without this you can photograph the frame before the one you
	# waited for — which on a scene whose lighting is still converging is
	# exactly the frame you did not want.
	await RenderingServer.frame_post_draw

	var img: Image = root.get_texture().get_image()
	var err: int = img.save_png(_out_path)
	if err != OK:
		push_error("[Capture] save failed (%d) -> %s" % [err, _out_path])
		quit(4)
		return
	print("[Capture] %s  %dx%d  %d frames" % [
		_out_path, img.get_width(), img.get_height(), _frames])
	if _fps_probe:
		# A SMOKE TEST, NOT A BENCHMARK. It is capped at 60 by the settle pass,
		# runs against whatever else is using the GPU, and includes the capture
		# window's own present. It answers "does this scene render at all" and
		# nothing more; do not put this number in a cost table.
		print("[Capture] settle pass: %.2f ms/frame avg over %d frames (CAPPED, smoke only)"
			% [elapsed_us / 1000.0 / float(_frames), _frames])
	quit(0)
