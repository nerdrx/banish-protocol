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
var _last_yaw: float = 0.0
var _t: float = 0.0
var _ready_done: bool = false

## Spring toward the target. UNDERDAMPED on purpose (M6.5): at the old
## 55/9.5 the damping ratio was ~0.64, near-critical, so the tail SNAPPED to its
## target and never swung — players reported it "barely moved". 34/5.0 is ζ~0.43,
## which overshoots once and settles in ~1 s: it visibly swings its weight, lags a
## turn out wide and rebounds, then hangs back into the resting sag.
const STIFFNESS: float = 34.0
const DAMPING: float = 5.0
## Turn lag: a sharp yaw swings the tail out to the OUTSIDE of the turn, per rad/s
## of heading change; plus a smaller push from strafing, per m/s sideways.
const TURN_LAG: float = 0.30
const STRAFE_LAG: float = 0.075
## Streaming: running LIFTS the tail toward horizontal (it trails), per m/s
## forward; jumping/falling drapes it down / lifts it, per m/s vertical.
const STREAM_LIFT: float = 0.17
const VERT_STREAM: float = 0.13
## Landing bounce: a downward velocity kick to the tail per m/s of downward speed
## killed on impact — it whips down, then the underdamped spring rebounds it up.
const BOUNCE: float = 0.34
## A little life at rest so a standing tail breathes rather than hanging dead.
const IDLE_SWAY: float = 0.035
## Clamp on how far a dynamic push may bend a segment off its droop, so a hard
## turn or a sprint can never fold the tail through the body or over its own back.
const MAX_PUSH: float = 0.9


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
	_last_yaw = skeleton.global_transform.basis.get_euler().y
	_ready_done = true
	_apply()


func _process(delta: float) -> void:
	if not _ready_done or skeleton == null or not is_instance_valid(skeleton):
		return
	_t += delta

	# Frozen under automation so a still capture is reproducible — UNLESS a tail
	# motion probe asked for live dynamics (Debug.tail_live), which is the whole
	# point of a jump/turn/run-stop capture.
	if Debug.automated and not Debug.tail_live:
		for i: int in bones.size():
			_angle[i] = droop[i]
			_yaw[i] = 0.0
		_apply()
		return

	# Motion of the body this frame, in its own frame, drives lag, lift and bounce.
	var pos: Vector3 = skeleton.global_position
	var world_vel: Vector3 = (pos - _last_pos) / maxf(delta, 0.0001)
	_last_pos = pos
	var basis: Basis = skeleton.global_transform.basis
	# +Z is the tail's back, so a body facing -Z moving forward reads as +fwd_speed.
	var fwd_speed: float = -basis.z.dot(world_vel)
	var side_speed: float = basis.x.dot(world_vel)
	var up_vel: float = world_vel.y

	# Heading change this frame -> the turn the tail lags behind.
	var yaw: float = basis.get_euler().y
	var yaw_rate: float = wrapf(yaw - _last_yaw, -PI, PI) / maxf(delta, 0.0001)
	_last_yaw = yaw

	# A landing is a sudden loss of downward speed (up_vel jumps toward zero): the
	# per-frame upward change, delivered to the tail as a downward velocity impulse.
	var landed: float = maxf(up_vel - _last_up_vel, 0.0)
	_last_up_vel = up_vel

	var n: int = bones.size()
	for i: int in n:
		var falloff: float = float(i + 1) / float(n) * liveliness   # tip reacts most
		# Bend target: running lifts the tail toward horizontal (it trails back), a
		# rising body drapes it lower and a fall lifts it — clamped so a sprint can
		# never fold it over its own back.
		var push: float = clampf(
				-fwd_speed * STREAM_LIFT + up_vel * VERT_STREAM, -MAX_PUSH, MAX_PUSH)
		var target: float = droop[i] + push * falloff
		_vel[i] += ((target - _angle[i]) * STIFFNESS - _vel[i] * DAMPING) * delta
		# Landing impulse: a downward velocity kick the underdamped spring rebounds.
		_vel[i] += landed * BOUNCE * falloff
		_angle[i] += _vel[i] * delta
		# Sideways: a sharp turn (yaw_rate) and strafing swing the tail out wide,
		# over a shallow idle sway so a standing tail is never quite dead.
		var yaw_target: float = clampf(
				-yaw_rate * TURN_LAG - side_speed * STRAFE_LAG, -MAX_PUSH, MAX_PUSH) \
				* falloff + sin(_t * 1.1 + float(i) * 0.6) * IDLE_SWAY * liveliness
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
