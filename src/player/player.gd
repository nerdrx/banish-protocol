class_name Player
extends CharacterBody3D
## First-person intrusion program — the crew member's avatar inside MOTHER.
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

## How far you can reach an interactable, and the interact-layer mask the probe
## ray tests against (project.godot [layer_names] 3d_physics/layer_3).
const REACH: float = 3.4
const INTERACT_MASK: int = 4
## A channel is broken by moving, not just by releasing the key — DESIGN.md wants
## siphoning to be a commitment. Well above the residual drift after a stop.
const CHANNEL_MOVE_TOLERANCE: float = 0.35

# --- spectator (decompiled) --------------------------------------------------
const SPECTATE_DISTANCE: float = 3.4
const SPECTATE_HEIGHT: float = 2.1
const SPECTATE_LERP: float = 3.5

# --- identity (set by Net._spawn_player on every peer before tree entry) -----
var player_name: String = "AGENT"
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

# --- interaction (local only; the HUD reads these off the local avatar) ------
## 0..1 fill of the current channel, and the prompt for whatever is under the
## crosshair. Not replicated: a channel is local feedback, and its *effect* is a
## host-validated request (see Interactable).
var channel_progress: float = 0.0
var focus_prompt: String = ""
var focus_available: bool = false

var _focus: Interactable = null
var _channel_elapsed: float = 0.0

# --- decompiled -------------------------------------------------------------
var _spectating: bool = false

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
@onready var seams: Node3D = $Body/Seams
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
		# Our own shell would fill the lens; keep it only as a shadow caster so
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
	# Circuit seams are how you tell crewmates apart at 20 m in the dark, so they
	# run hot enough to bloom and are applied to every seam mesh at once.
	var accent: StandardMaterial3D = StandardMaterial3D.new()
	accent.albedo_color = player_color.darkened(0.6)
	accent.emission_enabled = true
	accent.emission = player_color
	accent.emission_energy_multiplier = 3.0
	accent.metallic = 0.1
	accent.roughness = 0.4
	accent.disable_receive_shadows = true
	for seam: Node in seams.get_children():
		var mesh: MeshInstance3D = seam as MeshInstance3D
		if mesh != null:
			mesh.material_override = accent

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
	if motion != null and Debug.lock_input:
		return
	if motion != null and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-motion.relative.x * MOUSE_SENSITIVITY)
		_pitch = clampf(_pitch - motion.relative.y * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		head.rotation.x = _pitch
		return

	if event.is_action_pressed("beam"):
		_set_beam_state(not sync_beam)


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
	# Decompiled: the process is gone, the view stays. Nothing below this point
	# should run — no movement, no interaction, no billing weight.
	if not Run.local_alive():
		_spectate(delta)
		return

	# Debug.lock_input freezes the avatar for reproducible automated captures.
	var frozen: bool = Debug.lock_input
	if not is_on_floor():
		velocity.y -= get_gravity().length() * delta
	elif not frozen and Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY

	var input_dir: Vector2 = Vector2.ZERO
	if not frozen:
		input_dir = Input.get_vector(
				"move_left", "move_right", "move_forward", "move_back")
	# Synthetic forward, used by the automated Cycles-drain runs. Applied after
	# the real input so a human at the keyboard can still steer during one.
	if Debug.hold_forward:
		input_dir.y = -1.0
	var wish: Vector3 = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y))
	wish.y = 0.0
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	var sprinting: bool = (Debug.hold_sprint or (not frozen
			and Input.is_action_pressed("sprint"))) and input_dir.y < -0.1
	# Starvation slows the avatar (DESIGN.md "framerate-of-self degrades"). It is
	# applied to the top speed rather than the acceleration so the loss of pace
	# is felt immediately rather than as sluggish handling.
	var top_speed: float = (SPRINT_SPEED if sprinting else WALK_SPEED) * Run.speed_multiplier()
	var target: Vector3 = wish * top_speed
	var planar: Vector3 = Vector3(velocity.x, 0.0, velocity.z)

	# Acceleration, never instant — the avatar has mass.
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

	_update_interaction(delta)


# ------------------------------------------------------------- interaction --

## Local-only. Finds what the crosshair is on, runs the channel, and hands the
## completed channel to the interactable — which turns it into a host-validated
## request. Nothing here is authoritative; it is the feel layer.
func _update_interaction(delta: float) -> void:
	var target: Interactable = _probe_interactable()
	if target != _focus:
		_focus = target
		_reset_channel()

	if _focus == null:
		focus_prompt = ""
		focus_available = false
		return

	focus_prompt = _focus.prompt()
	focus_available = _focus.available()

	# Debug.hold_interact deliberately ignores lock_input: an automated capture
	# needs to freeze the avatar and still be mid-channel when the shutter fires.
	var holding: bool = Debug.hold_interact \
			or (not Debug.lock_input and Input.is_action_pressed("interact"))
	if not holding or not focus_available:
		_reset_channel()
		return
	if Vector3(velocity.x, 0.0, velocity.z).length() > CHANNEL_MOVE_TOLERANCE:
		_reset_channel()
		return

	_channel_elapsed += delta
	channel_progress = clampf(_channel_elapsed / maxf(_focus.channel_time, 0.01), 0.0, 1.0)
	_focus.set_channel_visual(channel_progress)

	if channel_progress >= 1.0:
		var finished: Interactable = _focus
		_reset_channel()
		finished.complete()


## Ray from the lens against the interact layer. Areas only: an interactable's
## probe must never influence movement collision.
func _probe_interactable() -> Interactable:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return null
	var from: Vector3 = camera.global_position
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			from, from - camera.global_transform.basis.z * REACH)
	query.collision_mask = INTERACT_MASK
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider: Node = hit["collider"] as Node
	if collider == null:
		return null
	return collider.get_parent() as Interactable


func _reset_channel() -> void:
	if _focus != null and is_instance_valid(_focus):
		_focus.set_channel_visual(0.0)
	_channel_elapsed = 0.0
	channel_progress = 0.0


# -------------------------------------------------------------- decompiled --

## Third-person chase cam on a living crewmate. Cheaper and more robust than
## handing our viewport to their camera: their rig is authored for *their* head,
## and re-parenting cameras across replicated nodes invites lifetime bugs.
func _spectate(delta: float) -> void:
	if not _spectating:
		_spectating = true
		velocity = Vector3.ZERO
		collision_layer = 0
		collision_mask = 0
		beam.visible = false
		beam_cone.visible = false
		_reset_channel()
		focus_prompt = ""

	var subject: Node3D = _find_living_crewmate()
	if subject == null:
		return

	var behind: Vector3 = subject.global_transform.basis.z * SPECTATE_DISTANCE
	var target: Vector3 = subject.global_position + behind + Vector3.UP * SPECTATE_HEIGHT
	var blend: float = 1.0 - exp(-SPECTATE_LERP * delta)
	global_position = global_position.lerp(target, blend)

	var look_at: Vector3 = subject.global_position + Vector3.UP * 1.2
	var delta_v: Vector3 = look_at - global_position
	if delta_v.length_squared() > 0.01:
		rotation.y = atan2(-delta_v.x, -delta_v.z)
		_pitch = clampf(atan2(delta_v.y,
				Vector2(delta_v.x, delta_v.z).length()), -PITCH_LIMIT, PITCH_LIMIT)
		head.rotation.x = _pitch

	sync_position = global_position
	sync_yaw = rotation.y
	sync_pitch = _pitch
	sync_speed = 0.0


func _find_living_crewmate() -> Node3D:
	var ids: Array = Net.crew.keys()
	ids.sort()
	for id: int in ids:
		var peer: int = int(id)
		if peer == Net.local_id() or not Run.is_alive(peer):
			continue
		var node: Node = Net.get_player(peer)
		if node != null and is_instance_valid(node):
			return node as Node3D
	return null


## Authority-side reposition, used by the drop-shaft rebuild. Clears the
## dead-reckoning history too, or remote peers would smoothly slide the avatar
## across the whole previous layer to its new home.
func teleport_to(where: Vector3, yaw: float) -> void:
	global_position = where
	rotation.y = yaw
	velocity = Vector3.ZERO
	sync_position = where
	sync_yaw = yaw
	_last_sync_position = where
	_remote_velocity = Vector3.ZERO
	_reset_channel()


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
		global_position = target  # respawn / teleport — do not slide across the layer.

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
