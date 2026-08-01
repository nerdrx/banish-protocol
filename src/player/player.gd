class_name Player
extends CharacterBody3D
## First-person salvager.
##
## Movement is client-authoritative (DESIGN.md: responsiveness first, server
## sanity checks later). The owning peer simulates locally and pushes pose into
## the `sync_*` properties; every other peer receives those through the
## MultiplayerSynchronizer and dead-reckons + smooths toward them, so remote
## crewmates glide instead of teleport-stuttering between packets.

# --- feel constants ---------------------------------------------------------
const WALK_SPEED: float = 4.2
const SPRINT_SPEED: float = 6.9
const GROUND_ACCEL: float = 11.0
const GROUND_DECEL: float = 15.0
const AIR_ACCEL: float = 2.6
const JUMP_VELOCITY: float = 3.9
const MOUSE_SENSITIVITY: float = 0.0022
const PITCH_LIMIT: float = 1.45

const BASE_FOV: float = 74.0
const SPRINT_FOV: float = 81.0
const FOV_LERP: float = 6.0

const BOB_RATE: float = 1.55
const BOB_VERTICAL: float = 0.055
const BOB_HORIZONTAL: float = 0.035
const BOB_ROLL: float = 0.013

const DIP_STIFFNESS: float = 120.0
const DIP_DAMPING: float = 13.0
const DIP_SCALE: float = 0.035
const DIP_MAX: float = 0.22

const BEAM_LAG: float = 11.0
const BEAM_SWAY: float = 0.045

const NAMEPLATE_FULL_DISTANCE: float = 8.0
const NAMEPLATE_FADE_DISTANCE: float = 15.0

# --- identity (set by Net._spawn_player on every peer before tree entry) -----
var player_name: String = "SALVAGER"
var player_color: Color = Color.WHITE

# --- replicated state -------------------------------------------------------
var sync_position: Vector3 = Vector3.ZERO
var sync_yaw: float = 0.0
var sync_pitch: float = 0.0
var sync_speed: float = 0.0
var sync_beam: bool = true
var sync_grounded: bool = true

# --- local sim --------------------------------------------------------------
var _pitch: float = 0.0
var _bob_time: float = 0.0
var _bob_weight: float = 0.0
var _bob_phase_sign: int = 1
var _dip_offset: float = 0.0
var _dip_velocity: float = 0.0
var _was_on_floor: bool = true
var _fall_speed: float = 0.0
var _is_local: bool = false

# --- remote smoothing -------------------------------------------------------
var _remote_velocity: Vector3 = Vector3.ZERO
var _last_sync_position: Vector3 = Vector3.ZERO
var _time_since_packet: float = 0.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera
@onready var beam_rig: Node3D = $BeamRig
@onready var beam: SpotLight3D = $BeamRig/Beam
@onready var beam_cone: MeshInstance3D = $BeamRig/BeamCone
@onready var body: Node3D = $Body
@onready var stripe: MeshInstance3D = $Body/Stripe
@onready var visor: MeshInstance3D = $Body/Visor
@onready var nameplate: Label3D = $Nameplate
@onready var synchronizer: MultiplayerSynchronizer = $Sync


func _ready() -> void:
	_is_local = is_multiplayer_authority()
	sync_position = global_position
	_last_sync_position = sync_position
	sync_yaw = rotation.y
	_apply_identity()

	if _is_local:
		camera.current = true
		camera.fov = BASE_FOV
		# Our own hull would fill the lens; keep it only as a shadow caster so
		# the beam still throws a silhouette on the floor.
		_set_shadows_only(body)
		nameplate.visible = false
		beam_cone.visible = false
		_capture_mouse()
	else:
		camera.current = false
		set_physics_process(true)

	_set_beam_state(sync_beam)
	Net.notify_player_ready(self)


func _apply_identity() -> void:
	nameplate.text = player_name
	nameplate.modulate = player_color
	var accent: StandardMaterial3D = StandardMaterial3D.new()
	accent.albedo_color = player_color.darkened(0.65)
	accent.emission_enabled = true
	accent.emission = player_color
	accent.emission_energy_multiplier = 2.6
	accent.metallic = 0.2
	accent.roughness = 0.45
	stripe.material_override = accent

	var visor_mat: StandardMaterial3D = StandardMaterial3D.new()
	visor_mat.albedo_color = Color(0.02, 0.03, 0.04)
	visor_mat.emission_enabled = true
	visor_mat.emission = player_color.lerp(Color(0.6, 0.9, 1.0), 0.35)
	visor_mat.emission_energy_multiplier = 0.9
	visor_mat.metallic = 0.9
	visor_mat.roughness = 0.1
	visor.material_override = visor_mat

	beam.light_color = Color(0.86, 0.9, 1.0).lerp(player_color, 0.18)
	var beam_mat: StandardMaterial3D = beam_cone.material_override as StandardMaterial3D
	if beam_mat != null:
		var tinted: StandardMaterial3D = beam_mat.duplicate() as StandardMaterial3D
		tinted.albedo_color = Color(0.7, 0.8, 1.0).lerp(player_color, 0.25)
		tinted.albedo_color.a = beam_mat.albedo_color.a
		beam_cone.material_override = tinted


func _set_shadows_only(root: Node) -> void:
	for child: Node in root.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh != null:
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		_set_shadows_only(child)


# ------------------------------------------------------------------- input --

func _unhandled_input(event: InputEvent) -> void:
	if not _is_local:
		return

	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-motion.relative.x * MOUSE_SENSITIVITY)
		_pitch = clampf(_pitch - motion.relative.y * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		head.rotation.x = _pitch
		return

	if event.is_action_pressed("beam"):
		_set_beam_state(not sync_beam)
	elif event.is_action_pressed("interact"):
		interact()


func _capture_mouse() -> void:
	if DisplayServer.get_name() == "headless":
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# ------------------------------------------------------------------ physics --

func _physics_process(delta: float) -> void:
	if _is_local:
		_simulate_local(delta)
	else:
		_smooth_remote(delta)
	_update_view(delta)


func _simulate_local(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= get_gravity().length() * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY

	var input_dir: Vector2 = Input.get_vector(
			"move_left", "move_right", "move_forward", "move_back")
	var wish: Vector3 = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y))
	wish.y = 0.0
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	var sprinting: bool = Input.is_action_pressed("sprint") and input_dir.y < -0.1
	var top_speed: float = SPRINT_SPEED if sprinting else WALK_SPEED
	var target: Vector3 = wish * top_speed
	var planar: Vector3 = Vector3(velocity.x, 0.0, velocity.z)

	# Acceleration, never instant — the suit has mass.
	var rate: float = AIR_ACCEL
	if is_on_floor():
		rate = GROUND_ACCEL if target.length_squared() > 0.01 else GROUND_DECEL
	planar = planar.move_toward(target, rate * top_speed * delta)
	velocity.x = planar.x
	velocity.z = planar.z

	_was_on_floor = is_on_floor()
	_fall_speed = velocity.y
	move_and_slide()

	if not _was_on_floor and is_on_floor():
		_land(_fall_speed)

	sync_position = global_position
	sync_yaw = rotation.y
	sync_pitch = _pitch
	sync_speed = Vector3(velocity.x, 0.0, velocity.z).length()
	sync_grounded = is_on_floor()

	camera.fov = lerpf(camera.fov,
			SPRINT_FOV if (sprinting and sync_speed > WALK_SPEED * 0.6) else BASE_FOV,
			1.0 - exp(-FOV_LERP * delta))


## Dead-reckon between packets, then exponentially smooth onto the result.
## Without the reckoning step a 20 Hz stream reads as a visible stutter.
func _smooth_remote(delta: float) -> void:
	_time_since_packet += delta
	if not sync_position.is_equal_approx(_last_sync_position):
		if _time_since_packet > 0.001:
			var measured: Vector3 = (sync_position - _last_sync_position) / _time_since_packet
			_remote_velocity = _remote_velocity.lerp(measured, 0.5)
		_last_sync_position = sync_position
		_time_since_packet = 0.0

	var lead: float = minf(_time_since_packet, 0.15)
	var target: Vector3 = sync_position + _remote_velocity * lead
	var blend: float = 1.0 - exp(-16.0 * delta)
	global_position = global_position.lerp(target, blend)
	if global_position.distance_to(target) > 6.0:
		global_position = target  # respawn / teleport — do not slide across the deck.

	rotation.y = lerp_angle(rotation.y, sync_yaw, blend)
	_pitch = lerp_angle(_pitch, sync_pitch, blend)
	head.rotation.x = _pitch
	velocity = _remote_velocity


# --------------------------------------------------------------------- view --

func _update_view(delta: float) -> void:
	var speed: float = sync_speed if not _is_local \
			else Vector3(velocity.x, 0.0, velocity.z).length()
	var grounded: bool = sync_grounded if not _is_local else is_on_floor()

	# Head bob: scaled by speed, silent when idle.
	if grounded and speed > 0.4:
		_bob_time += delta * speed * BOB_RATE
		_bob_weight = lerpf(_bob_weight, clampf(speed / SPRINT_SPEED, 0.0, 1.0),
				1.0 - exp(-7.0 * delta))
	else:
		_bob_weight = lerpf(_bob_weight, 0.0, 1.0 - exp(-9.0 * delta))
		if _bob_weight < 0.002:
			_bob_time = 0.0

	var vertical: float = sin(_bob_time * 2.0)
	var horizontal: float = cos(_bob_time)
	_check_footstep(vertical, speed)

	_dip_velocity += (-_dip_offset * DIP_STIFFNESS - _dip_velocity * DIP_DAMPING) * delta
	_dip_offset += _dip_velocity * delta

	camera.position = Vector3(
			horizontal * BOB_HORIZONTAL * _bob_weight,
			vertical * BOB_VERTICAL * _bob_weight + _dip_offset,
			0.0)
	camera.rotation.z = horizontal * BOB_ROLL * _bob_weight

	_update_beam(delta, speed)
	_update_nameplate()


## The beam rides a lagged rig instead of being pinned to the lens — the
## beam trailing the look direction by a few frames is most of what sells weight.
func _update_beam(delta: float, speed: float) -> void:
	var target: Transform3D = camera.global_transform
	beam_rig.global_position = target.origin
	var current_q: Quaternion = beam_rig.global_transform.basis.get_rotation_quaternion()
	var target_q: Quaternion = target.basis.get_rotation_quaternion()
	var blend: float = 1.0 - exp(-BEAM_LAG * delta)
	beam_rig.global_transform.basis = Basis(current_q.slerp(target_q, blend))

	var sway: float = sin(_bob_time * 1.3) * BEAM_SWAY * clampf(speed / SPRINT_SPEED, 0.0, 1.0)
	beam_rig.rotate_object_local(Vector3.RIGHT, sway * delta * 4.0)


func _update_nameplate() -> void:
	if _is_local or not nameplate.visible:
		return
	var viewer: Camera3D = get_viewport().get_camera_3d()
	if viewer == null:
		return
	var distance: float = viewer.global_position.distance_to(nameplate.global_position)
	var alpha: float = clampf(
			inverse_lerp(NAMEPLATE_FADE_DISTANCE, NAMEPLATE_FULL_DISTANCE, distance), 0.0, 1.0)
	nameplate.modulate.a = alpha
	nameplate.outline_modulate.a = alpha * 0.8


# ---------------------------------------------------------------- beam --

func _set_beam_state(on: bool) -> void:
	sync_beam = on
	_apply_beam_visuals()


func _apply_beam_visuals() -> void:
	beam.visible = sync_beam
	beam_cone.visible = sync_beam and not _is_local


func _process(_delta: float) -> void:
	if not _is_local and beam.visible != sync_beam:
		_apply_beam_visuals()


# ------------------------------------------------------------------- events --

func _land(impact_speed: float) -> void:
	var strength: float = clampf(absf(impact_speed) * DIP_SCALE, 0.0, DIP_MAX)
	_dip_offset -= strength
	on_landed(strength)


## Hooks for M4 audio. Deliberately empty for now.
func _check_footstep(bob_vertical: float, speed: float) -> void:
	if _bob_weight < 0.25 or speed < 0.4:
		return
	var sign_now: int = 1 if bob_vertical >= 0.0 else -1
	if sign_now != _bob_phase_sign:
		_bob_phase_sign = sign_now
		on_footstep(speed > WALK_SPEED * 1.05)


func on_footstep(_sprinting: bool) -> void:
	pass  # M4: positional footstep audio + subtle dust puff.


func on_landed(_strength: float) -> void:
	pass  # M4: landing thud + screen shake.


func interact() -> void:
	pass  # M2/M3: beacons, salvage, doors.
