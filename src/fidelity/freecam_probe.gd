class_name FreecamProbe
extends Node3D
## `--freecam` — a camera that is not attached to a player.
##
## WHY THIS HAD TO EXIST, STATED AS THE BUG IT FIXES
## Every capture probe in `Debug` (`--goto vault`, `--goto worklight`, …) works
## the same way: it teleports the LOCAL AVATAR in front of a thing and points its
## lens at it. That is the right tool for almost every shot in this project and
## it is structurally incapable of taking one shot in particular — the one this
## whole milestone is about.
##
## A volumetric shaft only reads as a shaft when you see it side-on. Light
## scattering in air is something you look ACROSS, not along: stood on the axis
## of a beam you are inside a bright disc, and the six metres of lit air that
## make the picture are all behind you or all in front of you. `--goto` always
## stands the camera on that axis, because "go and look at this thing" means
## "put the lens where the thing is in the middle of frame". So every attempt at
## the money shot came back as a lit wall with no beam in it, and no amount of
## `--pitch` could fix it, because the problem was the camera's POSITION and the
## avatar was never allowed to stand anywhere except in front.
##
## This detaches the lens. It anchors to a thing by GROUP, steps sideways off
## that thing's own facing axis, and looks back across it — so the beam crosses
## the frame instead of pointing at it.
##
##     -- --freecam <group> [side] [height] [ahead] [rise]
##
##       group   the node group to anchor to: `work_lights`, `god_shafts`,
##               `machines`, `diffuser_panels`, `drop_shafts` …
##       side    metres perpendicular to the anchor's facing. THE ONE THAT
##               MATTERS — this is what turns "along the beam" into "across it".
##       height  camera height above the anchor's floor.
##       ahead   how far down the anchor's beam to aim, i.e. where in the shaft
##               the frame is centred.
##       rise    height of the aim point, for a shaft that runs vertically.
##
## It is a CAPTURE tool and it says so: it takes over the viewport camera, never
## touches simulation, is never constructed without the flag, and it prints where
## it put itself so a frame can be reproduced from a log line.

const POLL_INTERVAL: float = 0.25

var group: StringName = &"work_lights"
var side: float = 6.0
var height: float = 1.7
var ahead: float = 3.0
var rise: float = 1.4
var index: int = 0

var _camera: Camera3D = null
var _clock: float = 0.0
var _placed: bool = false


## Stand one up if `--freecam` was passed. Called by Photonics (which is already
## the autoload that owns capture-only flags) so no shared file grows a branch.
static func arm(host: Node) -> FreecamProbe:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var at: int = args.find("--freecam")
	if at < 0:
		return null
	var probe: FreecamProbe = FreecamProbe.new()
	probe.name = "FreecamProbe"
	var values: Array[String] = []
	for i: int in range(at + 1, args.size()):
		if args[i].begins_with("--"):
			break
		values.append(args[i])
	if values.size() > 0:
		probe.group = StringName(values[0])
	if values.size() > 1:
		probe.side = values[1].to_float()
	if values.size() > 2:
		probe.height = values[2].to_float()
	if values.size() > 3:
		probe.ahead = values[3].to_float()
	if values.size() > 4:
		probe.rise = values[4].to_float()
	if values.size() > 5:
		probe.index = values[5].to_int()
	host.add_child(probe)
	return probe


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_camera = Camera3D.new()
	_camera.name = "Freecam"
	# The player's own camera is 75; matching it means the composition this probe
	# produces is a composition the player could actually stand in.
	_camera.fov = 75.0
	_camera.near = 0.05
	_camera.far = 220.0
	add_child(_camera)


## Polls rather than waiting on a signal, because the thing being waited for is
## "the layer has finished building AND the props have been placed AND their
## global transforms have been solved", and there is no one signal for that. A
## quarter-second poll on a capture-only node is free.
func _process(delta: float) -> void:
	if _placed:
		return
	_clock -= delta
	if _clock > 0.0:
		return
	_clock = POLL_INTERVAL
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var anchor: Node3D = null
	if group == &"player":
		# THE CREW-BEAM SHOT. `player` is not a group, it is the local avatar, and
		# it is here because the headlamp is the one light in the game a probe can
		# never anchor to any other way: it has no scene node of its own worth
		# finding, it moves, and it is the light the whole darkness pillar is
		# about. Stepping sideways off the avatar and looking across its beam is
		# the only way to photograph a crew beam as a SHAFT rather than as a lit
		# patch of wall at the end of it.
		anchor = Net.get_player(Net.local_id()) as Node3D
	else:
		var anchors: Array[Node] = tree.get_nodes_in_group(String(group))
		if anchors.is_empty():
			return
		anchor = anchors[index % anchors.size()] as Node3D
	if anchor == null or not is_instance_valid(anchor) or not anchor.is_inside_tree():
		return
	_place(anchor)


## How far the camera may travel from `from` along `dir` before it is inside
## something, capped at `want`. Layer 1 is the world collider layer.
func _clear_run(from: Vector3, dir: Vector3, want: float) -> float:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return want
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			from, from + dir * (want + 0.6))
	query.collision_mask = 1
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return want
	# 0.45 m off whatever was hit: the camera's near plane is 5 cm, but a lens
	# parked flush against a wall still fills a third of the frame with it.
	return maxf(from.distance_to(hit["position"]) - 0.45, 0.6)


func _place(anchor: Node3D) -> void:
	# `anchor` metadata wins over the node transform where a node has one. A
	# god-ray unit is a bag of meshes positioned in the builder's space with the
	# root left at the origin, so its `global_position` is the middle of the
	# layer and its own floor point is the only thing worth aiming at.
	var origin: Vector3 = anchor.get_meta("anchor", anchor.global_position)
	# The anchor's own aim. A Node3D's forward is -Z, which is the convention the
	# work lights are built to (ProcLayerBuilder yaws them so -Z points at the
	# work) and the one every Light3D emits along. A god-ray root has no
	# meaningful yaw, and it does not need one: its beam runs straight down, so
	# ANY horizontal step is a step across it.
	var forward: Vector3 = -anchor.global_transform.basis.z
	if group == &"player":
		# An avatar's -Z is where it is FACING, which is where the headlamp
		# points; the lens sits at eye height rather than at the feet, so the
		# beam's origin has to come up with it or the frame is aimed at a floor.
		origin += Vector3(0.0, 1.5, 0.0)
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var across: Vector3 = forward.cross(Vector3.UP).normalized()

	# PERPENDICULAR TO THE MIDDLE OF THE BEAM, and that is the whole geometry.
	#
	# The first version stood beside the SOURCE and aimed at the far end of the
	# beam, which sounds equivalent and is not: it puts the source off the edge of
	# the frame and photographs the last two metres of a six-metre shaft. Framing
	# a segment means standing off its MIDPOINT and looking at the midpoint — then
	# the source is at one edge, whatever the light lands on is at the other, and
	# the lit air runs across the middle. `ahead` is therefore the beam's LENGTH,
	# not an aim distance.
	#
	# For a vertical shaft `ahead` is 0 and this degenerates correctly: the
	# midpoint is the floor point, any horizontal step is a step across the shaft,
	# and `rise` alone decides how much of its height is in frame.
	var mid: Vector3 = origin + forward * (ahead * 0.5)
	var eye: Vector3 = mid + Vector3(0.0, height, 0.0)
	# CLEARANCE, because a room is not an infinite plane.
	#
	# The first build had none and it cost two frames of pure black: layer 7's
	# work light stands close to a wall, "step 4.6 m sideways" stepped straight
	# through it, and the capture came back as a photograph of the inside of the
	# masonry with a world-space prompt bleeding through. So both sides are cast
	# against the world collision layer and the better one wins; whichever is
	# chosen is then pulled back to just short of whatever it hit. A probe that
	# silently produces a black frame is worse than one that produces a tight one.
	var best: Vector3 = eye + across * side
	var best_room: float = -1.0
	for direction: Vector3 in [across, -across]:
		var reach: float = _clear_run(eye, direction, side)
		if reach > best_room:
			best_room = reach
			best = eye + direction * reach
	var at: Vector3 = best
	var target: Vector3 = mid + Vector3(0.0, rise, 0.0)

	global_position = at
	_camera.global_position = at
	_camera.look_at(target, Vector3.UP)
	# Last, and after `look_at`: making it current before it is aimed shows one
	# frame of the camera pointing north, which a 240-frame settle hides and a
	# short one does not.
	_camera.current = true
	_placed = true
	print("[Freecam] anchored to '%s'[%d] at %s looking at %s (side=%.1f height=%.1f ahead=%.1f rise=%.1f)" % [
		String(group), index, str(at.snapped(Vector3.ONE * 0.1)),
		str(target.snapped(Vector3.ONE * 0.1)), side, height, ahead, rise])
