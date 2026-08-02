extends Node
## Custom spring tail (M4.9). Loaded via preload (no class_name) by
## CreatureKit.build_spring_tail.
##
## Godot 4.7's SpringBoneSimulator3D would not deflect the tail on these rigs — the
## per-joint gravity was applied and the modifier manually advanced every frame,
## and the chain still sat dead-straight at its bind pose — so the tail is driven
## here directly instead. It layers three things onto whatever the animation wrote,
## as LOCAL bone rotations, run last in the frame:
##
##   1. a heavy resting DROOP — a downward curve, tip well below the root — which
##      is the headline acceptance test (a horizontal bind tail is the "cursed"
##      look). This is guaranteed and deterministic: it does not depend on a
##      settling integrator, so a standing-still capture always shows the sag.
##   2. inertial LAG — the tail trails a turn and streams out behind movement.
##   3. a landing BOUNCE — a downward kick when the body drops onto the floor.
##
## The droop is the equilibrium the lag/bounce spring settles back to within ~1 s
## of stopping. Cosmetic and LOCAL per peer — it reads the replicated pose and
## writes only this peer's skeleton, so it never touches networked or seeded state
## and cannot perturb the determinism dump. Frozen deterministically under
## Debug.automated: the dynamics are stilled and the tail holds the pure droop, so
## a capture is identical every run.

var skeleton: Skeleton3D = null
## Tail1..Tail5, root-to-tip.
var bones: PackedInt32Array = PackedInt32Array()
## Per-bone resting droop in radians, ramped for a hanging curve.
var droop: PackedFloat32Array = PackedFloat32Array()
## Liveliness scales the dynamic lag/bounce amplitude (crew lively, Sentinel dead).
var liveliness: float = 1.0

var _rest: Array = []
var _angle: PackedFloat32Array = PackedFloat32Array()
var _yaw: PackedFloat32Array = PackedFloat32Array()
var _vel: PackedFloat32Array = PackedFloat32Array()
var _yaw_vel: PackedFloat32Array = PackedFloat32Array()
var _last_pos: Vector3 = Vector3.ZERO
var _last_up_vel: float = 0.0
var _t: float = 0.0
var _ready_done: bool = false

## Spring toward the target droop. Stiff enough to settle in ~1 s, damped so it
## does not visibly oscillate.
const STIFFNESS: float = 55.0
const DAMPING: float = 9.5
## How hard a turn/movement pushes the tail, per (rad/s) and per (m/s).
const TURN_LAG: float = 0.9
const STREAM_LIFT: float = 0.11
## Landing bounce: extra droop kick per m/s of downward speed lost on impact.
const BOUNCE: float = 0.22


func _ready() -> void:
	process_priority = 500  # after the AnimationTree, so we drape the fresh pose
	if skeleton == null:
		return
	var n: int = bones.size()
	_rest.resize(n)
	_angle.resize(n)
	_yaw.resize(n)
	_vel.resize(n)
	_yaw_vel.resize(n)
	for i: int in n:
		_rest[i] = skeleton.get_bone_rest(bones[i]).basis.get_rotation_quaternion()
		_angle[i] = droop[i]  # start already drooped — no settle-in flicker
		_yaw[i] = 0.0
		_vel[i] = 0.0
		_yaw_vel[i] = 0.0
	_last_pos = skeleton.global_position
	_ready_done = true
	_apply()


func _process(delta: float) -> void:
	if not _ready_done or skeleton == null or not is_instance_valid(skeleton):
		return
	_t += delta

	# Frozen under automation: hold the pure droop so a capture is reproducible.
	if Debug.automated:
		for i: int in bones.size():
			_angle[i] = droop[i]
			_yaw[i] = 0.0
		_apply()
		return

	# Motion of the body this frame, in its own frame, drives lag and lift.
	var pos: Vector3 = skeleton.global_position
	var world_vel: Vector3 = (pos - _last_pos) / maxf(delta, 0.0001)
	_last_pos = pos
	var basis: Basis = skeleton.global_transform.basis
	var fwd_speed: float = basis.z.dot(world_vel)   # +Z is the tail's back
	var side_speed: float = basis.x.dot(world_vel)
	var up_vel: float = world_vel.y

	# A landing is a sudden loss of downward speed — kick the tail down.
	var landed: float = maxf(_last_up_vel - up_vel, 0.0) if up_vel > _last_up_vel - 0.5 else 0.0
	_last_up_vel = up_vel

	for i: int in bones.size():
		var falloff: float = float(i + 1) / float(bones.size())   # tip reacts most
		# The tail streams UP/back when moving forward and lags the turn sideways.
		var target: float = droop[i] - fwd_speed * STREAM_LIFT * falloff * liveliness \
				+ landed * BOUNCE * falloff * liveliness
		var yaw_target: float = -side_speed * TURN_LAG * 0.04 * falloff * liveliness \
				+ sin(_t * 1.3 + float(i) * 0.7) * 0.02 * liveliness
		# Critically-damped-ish spring toward the targets.
		_vel[i] += ((target - _angle[i]) * STIFFNESS - _vel[i] * DAMPING) * delta
		_angle[i] += _vel[i] * delta
		_yaw_vel[i] += ((yaw_target - _yaw[i]) * STIFFNESS - _yaw_vel[i] * DAMPING) * delta
		_yaw[i] += _yaw_vel[i] * delta
	_apply()


## Writes the local pose for each tail bone: its rest, then a bend about local X
## (the droop + dynamics) and a small yaw about local Y (turn lag + idle sway).
func _apply() -> void:
	for i: int in bones.size():
		# Bend about local -X: +angle droops the tail DOWN (about +X curled it up
		# over the back). A small yaw about local Y carries the turn lag and sway.
		var q: Quaternion = (_rest[i] as Quaternion) \
				* Quaternion(Vector3(-1.0, 0.0, 0.0), _angle[i]) \
				* Quaternion(Vector3(0.0, 1.0, 0.0), _yaw[i])
		skeleton.set_bone_pose_rotation(bones[i], q)
