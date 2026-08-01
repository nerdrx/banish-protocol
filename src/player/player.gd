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

## Above this apparent speed, a remote avatar did not move — it was moved (a
## descent, a debug jump). Comfortably above a sprint plus a fall.
const TELEPORT_SPEED: float = 24.0

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

# --- corrupted (downed) ------------------------------------------------------
## How hot the circuit seams run normally. They go out as the process corrupts.
const SEAM_ENERGY: float = 3.0

## Where the lens sits once the process is on its knees, and how far the shell
## drops with it.
const CORRUPT_EYE_HEIGHT: float = 0.72
const CORRUPT_BODY_DROP: float = 0.62
const CORRUPT_LERP: float = 4.0

## How far in front of the eye bone the first-person lens sits. See `_embody`.
const EYE_FORWARD: float = 0.16

# --- kit ---------------------------------------------------------------------
## Where the breaker's lash leaves the shell when there is no viewmodel to ask —
## low and to the side of the lens, so it reads as coming off the avatar rather
## than out of your eye. Since M3.7 the local player's lash starts at the Surge's
## actual emitter instead (see `_muzzle_point`); this is the fallback and the
## origin remote copies use.
const MUZZLE_OFFSET: Vector3 = Vector3(0.2, -0.18, -0.35)
## A flare leaves the hand with a lob on it and inherits the throw's motion.
const FLARE_LOFT: float = 2.4

# --- screen shake ------------------------------------------------------------
const SHAKE_DECAY: float = 3.4
const SHAKE_TRANSLATION: float = 0.09
const SHAKE_ROLL: float = 0.035

# --- identity (set by Net._spawn_player on every peer before tree entry) -----
var player_name: String = "AGENT"
var player_color: Color = Color.WHITE
## Node name is the peer id (Net._spawn_player), cached here for readability.
var peer_id: int = 1

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

# --- kit (present on every peer's copy; only the owner pulls the trigger) ----
var _breaker: Breaker = null
var _restore_point: RestorePoint = null
## First-person Surge. Local avatar only — a remote crewmate carries the same
## model socketed to their hand instead (see CrewAvatar).
var _view_model: ViewModel = null
## Third-person shell. Present on every peer's copy of every avatar: yours casts
## a shadow you can see, theirs is what you actually look at.
var _avatar: CrewAvatar = null

# --- decompiled / corrupted --------------------------------------------------
var _seam_material: StandardMaterial3D = null
var _spectating: bool = false
## 0..1 how far into the collapse this avatar is, eased on every peer.
var _collapse: float = 0.0
var _corrupt_light: OmniLight3D = null

# --- screen shake (local lens only) -----------------------------------------
var _shake: float = 0.0
var _shake_seed: float = 0.0

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
	peer_id = String(name).to_int()
	sync_position = global_position
	_last_sync_position = sync_position
	sync_yaw = rotation.y
	_shake_seed = float(peer_id) * 7.13
	_apply_identity()
	_build_avatar()
	_build_kit()

	if _is_local:
		camera.current = true
		camera.fov = BASE_FOV
		# The old placeholder shell would fill the lens; keep it only as a shadow
		# caster so the beam still throws a silhouette on the floor.
		_set_shadows_only(body)
		if _avatar != null and _avatar.is_loaded():
			# TRUE first-person: the lens sits in the avatar's own eye and the
			# rifle is in its posed hands. See `_embody`.
			_embody()
		else:
			# No crew model: fall back to the floating viewmodel, so a broken or
			# missing export costs you your body but never your breaker.
			_view_model = ViewModel.create(player_color)
			camera.add_child(_view_model)
		nameplate.visible = false
		beam_cone.visible = false
		_capture_mouse()
	else:
		camera.current = false
		set_physics_process(true)

	_dress_beam()
	_set_beam_state(sync_beam)
	if _is_local:
		Run.damaged.connect(_on_damaged)
	Net.notify_player_ready(self)


## The crew shell. Built on every peer's copy of every player: a remote crewmate
## is what you look at, and your own is what your beam throws a shadow of.
##
## The M1 capsule stays in the scene as the fallback. If the model is missing or
## the export is broken, `is_loaded()` comes back false and the capsule is left
## visible — in a game this dark, an invisible crewmate would be indistinguishable
## from a replication bug, and that is a debugging afternoon nobody needs.
func _build_avatar() -> void:
	_avatar = CrewAvatar.create(player_color)
	if not _avatar.is_loaded():
		_avatar.queue_free()
		_avatar = null
		return
	add_child(_avatar)
	# Remote copies get the breaker socketed here; the local copy does it in
	# `_embody`, after the head mesh has been dealt with.
	if not _is_local:
		_avatar.socket_breaker(player_color)
	# The placeholder shell and the real one must never be on screen together.
	body.visible = false


## First-person embodiment.
##
## DESIGN.md renders you "inside MOTHER's architecture, as a physical avatar",
## and until M3.7 that avatar was a capsule nobody could see and a rifle floating
## in the lower-right of the frame. Now the crew model IS the first-person body:
## look down and you see your own chest, your own hands on the Surge, and your
## own feet on the deck.
##
## Three moves make it work:
##
##   1. **The lens moves to the eye.** The head rig is re-parked at the avatar's
##      `Eye` node's world height, so the camera is where the model's eyes are
##      rather than at an arbitrary 1.62. Every existing feel system — bob, dip,
##      landing, shake, beam lag — hangs off that rig untouched, which is why
##      this is a two-line change rather than a rewrite of `_update_view`.
##   2. **The head is hidden, the body is not.** `set_first_person()` puts only
##      the skull mesh on SHADOWS_ONLY. Rendering it would fill the frame with
##      the inside of a jaw; hiding the whole model would throw away the thing
##      we came here for.
##   3. **The rifle is in the hand, not on the camera.** The muzzle origin now
##      follows the posed weapon, so the beam-lash leaves the barrel the player
##      can see rather than a point floating near their eye.
##
## Known gap, honestly: the body yaws with the look direction, because movement
## is client-authoritative off a single yaw. Turning your head turns your torso.
## Decoupling them needs an aim-offset layer and a torso-twist limit, which is a
## milestone of its own.
func _embody() -> void:
	_avatar.socket_breaker(player_color)
	_avatar.set_first_person()
	# The lens height is deliberately NOT moved to the model's eye.
	#
	# The obvious thing to do here is park the camera exactly where the avatar's
	# `Eye` node is (1.69 m on this model). Doing that quietly broke the drop
	# shaft: its console probe tops out at y = 1.65, the debug descent stands
	# 2.7 m back and looks level, and at 1.62 the crosshair ray clears the probe
	# by three centimetres while at 1.69 it misses by four. Every reach, probe
	# and eye-height constant in M1-M3 was tuned against 1.62, and an art pass is
	# not allowed to move a gameplay number by accident. The seven centimetres
	# are invisible; the regression was not.
	#
	# What DOES transfer is the forward step out of the skull.
	#
	# A camera at the literal eye position of a short-necked, heavy-chested
	# creature spends most of its time inside that creature's own chest plate:
	# you get a flat wall of backface where your torso should be, and pitching
	# down makes it worse rather than better. A 16 cm forward offset clears the
	# chest, keeps the arms and the rifle in frame, and is small enough that it
	# never reads as an out-of-body camera.
	head.position.z = -EYE_FORWARD


## The kit every copy of an avatar carries. The breaker exists on remote copies
## so a crewmate's shot draws on your screen; the restore point exists on every
## copy because any of them might be the one you have to go and pick up.
func _build_kit() -> void:
	_breaker = Breaker.create()
	add_child(_breaker)

	_restore_point = RestorePoint.create(peer_id)
	add_child(_restore_point)

	# The beacon that makes a downed crewmate findable across a dark room. Off
	# until they go down.
	_corrupt_light = OmniLight3D.new()
	_corrupt_light.name = "CorruptBeacon"
	_corrupt_light.position = Vector3(0.0, 0.6, 0.0)
	_corrupt_light.light_color = Color(1.0, 0.36, 0.28)
	_corrupt_light.light_energy = 0.0
	_corrupt_light.omni_range = 9.0
	_corrupt_light.omni_attenuation = 0.9
	_corrupt_light.light_volumetric_fog_energy = 2.4
	_corrupt_light.shadow_enabled = false
	add_child(_corrupt_light)


func _apply_identity() -> void:
	nameplate.text = player_name
	nameplate.modulate = player_color
	# Circuit seams are how you tell crewmates apart at 20 m in the dark, so they
	# run hot enough to bloom and are applied to every seam mesh at once.
	_seam_material = StandardMaterial3D.new()
	_seam_material.albedo_color = player_color.darkened(0.6)
	_seam_material.emission_enabled = true
	_seam_material.emission = player_color
	_seam_material.emission_energy_multiplier = SEAM_ENERGY
	_seam_material.metallic = 0.1
	_seam_material.roughness = 0.4
	_seam_material.disable_receive_shadows = true
	for seam: Node in seams.get_children():
		var mesh: MeshInstance3D = seam as MeshInstance3D
		if mesh != null:
			mesh.material_override = _seam_material

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


## Breaks the beam cone up with the same dust gobo the look-dev rig uses on its
## projectors.
##
## A perfectly even torch cone is the most synthetic thing in a dark game, and it
## has a second, worse symptom: because every ray in the cone carries the same
## energy, anything the player walks up to goes flat white. Before this, a data
## rack three metres away was a featureless grey slab with its detail washed off
## it. The cloud breakup restores the falloff the geometry needs to read, and the
## energy comes down a notch to go with it.
func _dress_beam() -> void:
	beam.light_projector = load(LightRig.GOBO_DUST) as Texture2D


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
	elif event.is_action_pressed("flare") and Run.local_running():
		throw_flare()


func _capture_mouse() -> void:
	# An automated run shares the desktop with a human who is doing something
	# else. Stealing their cursor is as rude as stealing their focus, and this
	# spawn-time capture is the single most likely place for it to happen.
	if not Debug.may_capture_mouse():
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
	# Deleted: the process is gone, the view stays. Nothing below this point
	# should run — no movement, no interaction, no billing weight.
	if not Run.local_alive():
		_spectate(delta)
		return

	# Corrupted: still here, still watching, and completely helpless. The camera
	# stays first-person on purpose — being down has to be *your* problem, not a
	# spectator mode with a countdown attached.
	if Run.local_corrupted():
		_kneel(delta)
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

	if Debug.aim_antivirus:
		_track_nearest_antivirus(delta)
	_update_breaker(frozen)
	_update_interaction(delta)


## `--aim`. An automated run has no mouse, and the breaker is a short-range tool
## pointed at knee-high things that circle you — without this, a capture can
## never frame a hit. Steers the same lens a player would, at a human rate.
func _track_nearest_antivirus(delta: float) -> void:
	var best: Node3D = null
	var best_distance: float = Balance.BREAKER_RANGE + 4.0
	for node: Node in get_tree().get_nodes_in_group(Antivirus.GROUP):
		var creature: Antivirus = node as Antivirus
		if creature == null or not is_instance_valid(creature):
			continue
		var distance: float = creature.global_position.distance_to(global_position)
		if distance < best_distance:
			best_distance = distance
			best = creature
	if best == null:
		return

	var eye: Vector3 = global_position + Vector3.UP * 1.62
	var to_target: Vector3 = (best as Antivirus).aim_point() - eye
	if to_target.length_squared() < 0.01:
		return
	var blend: float = 1.0 - exp(-8.0 * delta)
	rotation.y = lerp_angle(rotation.y, atan2(-to_target.x, -to_target.z), blend)
	_pitch = lerp_angle(_pitch, clampf(
			atan2(to_target.y, Vector2(to_target.x, to_target.z).length()),
			-PITCH_LIMIT, PITCH_LIMIT), blend)
	head.rotation.x = _pitch


# ----------------------------------------------------------------------- kit --

## Local only. The trigger is held, not tapped: the cutter has its own cadence
## and heat ceiling, so holding it down is a decision about the next few seconds
## rather than a stream of free damage.
func _update_breaker(frozen: bool) -> void:
	var holding: bool = Debug.hold_fire or (not frozen and Input.is_action_pressed("fire"))
	if not holding or not _breaker.ready_to_fire():
		return

	var from: Vector3 = camera.global_position
	var basis: Basis = camera.global_transform.basis
	var direction: Vector3 = -basis.z
	var muzzle: Vector3 = from + basis * MUZZLE_OFFSET

	_breaker.pull_trigger()
	# Predicted endpoint, drawn this frame. The host re-casts the same ray and
	# decides what actually died — this is only where the streak stops.
	_breaker.show_lash(muzzle, _breaker_endpoint(from, direction))
	add_shake(0.22)
	Run.request_breaker(from, direction)


## Where the lash leaves the avatar. The Surge's own emitter when we are holding
## one, so the streak and the muzzle flash come out of the same hole.
func _muzzle_point(from: Vector3, basis: Basis) -> Vector3:
	if _avatar != null and is_instance_valid(_avatar) and _avatar.is_loaded():
		return _avatar.muzzle_point()
	if _view_model != null and is_instance_valid(_view_model):
		return _view_model.muzzle_point()
	return from + basis * MUZZLE_OFFSET


## Where the streak stops: whatever the cutter is pointing at, or the wall behind
## it. Same target selection the host runs, so the prediction is not a guess.
func _breaker_endpoint(from: Vector3, direction: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var creature: Antivirus = Antivirus.pick_target(get_tree(), space, from, direction)
	if creature != null:
		return creature.aim_point()

	var reach: Vector3 = from + direction * Balance.BREAKER_RANGE
	if space == null:
		return reach
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, reach)
	query.collision_mask = Antivirus.WORLD_MASK
	query.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	return reach if hit.is_empty() else Vector3(hit["position"])


## Local only. Throws from the lens with a loft on it, inheriting the avatar's
## own motion so a flare thrown while sprinting goes where you expect. Public
## because `--flare` drives the same path an input would.
func throw_flare() -> void:
	if Run.flares_of(peer_id) <= 0:
		return
	var basis: Basis = camera.global_transform.basis
	var origin: Vector3 = camera.global_position + basis * Vector3(0.0, -0.1, -0.6)
	var velocity: Vector3 = -basis.z * Balance.FLARE_THROW_SPEED \
			+ Vector3.UP * FLARE_LOFT + Vector3(self.velocity.x, 0.0, self.velocity.z)
	Run.request_flare(origin, velocity)


## Called on every peer by Run when a shot is resolved. The shooter has already
## drawn its own lash a round trip ago and only wants the kill confirmation.
func show_breaker_shot(origin: Vector3, endpoint: Vector3, killed: bool, mine: bool) -> void:
	if not mine:
		_breaker.show_lash(origin, endpoint)
		return
	if killed:
		add_shake(0.85)


## Breaker state, read by the HUD's heat indicator.
func breaker_heat() -> float:
	return 0.0 if _breaker == null else _breaker.heat


func breaker_locked() -> bool:
	return _breaker != null and _breaker.locked


## Adds to the lens shake. Bounded rather than accumulated without limit: two
## kills in a second should read as emphatic, not as a broken camera.
func add_shake(amount: float) -> void:
	_shake = clampf(_shake + amount, 0.0, 1.2)


func _on_damaged(_from: Vector3) -> void:
	add_shake(0.6)


# ------------------------------------------------------------- interaction --

## Local-only. Finds what the crosshair is on, runs the channel, and hands the
## completed channel to the interactable — which turns it into a host-validated
## request. Nothing here is authoritative; it is the feel layer.
func _update_interaction(delta: float) -> void:
	var target: Interactable = _probe_interactable()
	if target != _focus:
		_set_focus(target)

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
	_focus.apply_channel(channel_progress)

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


## Moves the crosshair's attention. M3.8's world-space prompts need to know what
## is being aimed at — a prompt you are looking straight at never fades — so
## focus changes go through one place rather than being an assignment.
func _set_focus(target: Interactable) -> void:
	if _focus != null and is_instance_valid(_focus):
		_focus.set_focused(false)
	_focus = target
	if _focus != null and is_instance_valid(_focus):
		_focus.set_focused(true)
	_reset_channel()


func _reset_channel() -> void:
	if _focus != null and is_instance_valid(_focus):
		_focus.apply_channel(0.0)
	_channel_elapsed = 0.0
	channel_progress = 0.0


# ---------------------------------------------------------------- corrupted --

## Down. Gravity still applies (a process corrupted mid-air still falls), the
## avatar still occupies the world so crewmates can find and reach it, and
## nothing else runs: no input, no channel, no kit.
func _kneel(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	velocity.y = 0.0 if is_on_floor() else velocity.y - get_gravity().length() * delta
	move_and_slide()

	_set_focus(null)
	focus_prompt = ""
	focus_available = false

	sync_position = global_position
	sync_yaw = rotation.y
	sync_pitch = _pitch
	sync_speed = 0.0
	sync_grounded = is_on_floor()


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
		_set_focus(null)
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
		if peer == Net.local_id() or not Run.is_running(peer):
			continue
		var node: Node = Net.get_player(peer)
		if node != null and is_instance_valid(node):
			return node as Node3D
	return null


## Authority-side reposition, used by the drop-shaft rebuild. Clears the
## dead-reckoning history too, or remote peers would smoothly slide the avatar
## across the whole previous layer to its new home. `pitch` exists for the debug
## teleports: Scrubbers are knee-high, and an automated run that always looks at
## the horizon can never point at one.
func teleport_to(where: Vector3, yaw: float, pitch: float = 0.0) -> void:
	global_position = where
	rotation.y = yaw
	velocity = Vector3.ZERO
	_pitch = clampf(pitch, -PITCH_LIMIT, PITCH_LIMIT)
	head.rotation.x = _pitch
	sync_position = where
	sync_yaw = yaw
	sync_pitch = _pitch
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
			if measured.length() > TELEPORT_SPEED:
				# Not motion — a teleport (a descent, a debug jump). Reckoning
				# from it would extrapolate hundreds of metres in one frame and
				# the snap below would then commit to that garbage.
				_remote_velocity = Vector3.ZERO
				global_position = sync_position
			else:
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

	# Shake rides on top of bob rather than replacing it, so a hit while running
	# reads as a hit while running. Driven from the clock at two incommensurate
	# rates, which is cheaper than noise and does not loop audibly.
	_shake = maxf(_shake - SHAKE_DECAY * delta * _shake, 0.0)
	if _shake < 0.002:
		_shake = 0.0
	var t: float = float(Time.get_ticks_msec()) / 1000.0 + _shake_seed
	var kick: Vector3 = Vector3(
			sin(t * 47.0) * 0.6 + sin(t * 23.0) * 0.4,
			sin(t * 39.0) * 0.6 + sin(t * 17.0) * 0.4, 0.0) * _shake * SHAKE_TRANSLATION

	camera.position = Vector3(
			horizontal * BOB_HORIZONTAL * _bob_weight + kick.x,
			vertical * BOB_VERTICAL * _bob_weight + _dip_offset + kick.y,
			0.0)
	camera.rotation.z = horizontal * BOB_ROLL * _bob_weight \
			+ sin(t * 31.0) * _shake * SHAKE_ROLL

	if _view_model != null and is_instance_valid(_view_model):
		# Fed the same bob the lens got, so the weapon rides the walk cycle
		# instead of floating independently of it, plus the strafe component in
		# the avatar's own frame for the lean.
		var strafe: float = transform.basis.x.dot(
				Vector3(velocity.x, 0.0, velocity.z)) / SPRINT_SPEED
		_view_model.drive(delta, Vector2(rotation.y, _pitch), clampf(strafe, -1.0, 1.0),
				Vector3(horizontal * BOB_HORIZONTAL * _bob_weight,
						vertical * BOB_VERTICAL * _bob_weight, 0.0))

	_update_collapse(delta)
	_update_beam(delta, speed)
	_update_nameplate()


## The downed shell, on every peer. The avatar sinks, its seams go out, and a red
## beacon comes up — a corrupted crewmate has to be findable from across a dark
## room, or the restore window is theatre.
func _update_collapse(delta: float) -> void:
	var down: bool = Run.is_corrupted(peer_id)
	_collapse = move_toward(_collapse, 1.0 if down else 0.0, CORRUPT_LERP * delta)
	if _collapse <= 0.001 and not down:
		if _corrupt_light.light_energy != 0.0:
			_corrupt_light.light_energy = 0.0
			if _avatar == null:
				body.position.y = 0.0
				body.rotation.x = 0.0
			head.position.y = 1.62
			if _seam_material != null:
				_seam_material.emission = player_color
				_seam_material.emission_energy_multiplier = SEAM_ENERGY
		return

	if _avatar == null:
		body.position.y = -CORRUPT_BODY_DROP * _collapse
		body.rotation.x = _collapse * 0.42
	if _is_local:
		head.position.y = lerpf(1.62, CORRUPT_EYE_HEIGHT, _collapse)

	# The seams go out and go red as the process comes apart: a downed crewmate
	# must not still be wearing their colour, or a crew cannot read the room.
	if _seam_material != null:
		_seam_material.emission = player_color.lerp(Color(1.0, 0.3, 0.24), _collapse)
		_seam_material.emission_energy_multiplier = lerpf(SEAM_ENERGY, 0.45, _collapse)

	var t: float = float(Time.get_ticks_msec()) / 1000.0
	# A slow two-beat, like something failing rather than an alarm going off.
	var beat: float = 0.55 + 0.45 * absf(sin(t * 2.2))
	_corrupt_light.light_energy = 1.5 * _collapse * beat


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

	# A downed crewmate's tag reads at any range and never fades: it is the only
	# thing pointing at where the run went wrong.
	if Run.is_corrupted(peer_id):
		nameplate.text = "%s\nCORRUPTED" % player_name
		nameplate.modulate = Color(1.0, 0.42, 0.34)
		alpha = 1.0
	elif nameplate.text != player_name:
		nameplate.text = player_name
		nameplate.modulate = player_color

	nameplate.modulate.a = alpha
	nameplate.outline_modulate.a = alpha * 0.8


# ---------------------------------------------------------------- beam --

func _set_beam_state(on: bool) -> void:
	sync_beam = on
	_apply_beam_visuals()


## A beam is a running process's tool. Corrupted or deleted, it goes out — which
## also takes away the light that was keeping the Scrubbers off you.
func _apply_beam_visuals() -> void:
	var live: bool = sync_beam and Run.is_running(peer_id)
	beam.visible = live
	beam_cone.visible = live and not _is_local


func _process(delta: float) -> void:
	# Cheap enough to reconcile every frame, and it covers three separate inputs
	# (the toggle, corruption, deletion) without any of them having to remember
	# to call it.
	_apply_beam_visuals()

	# The avatar is driven from the IDLE callback on purpose: its AnimationTree
	# runs on the physics callback, and the procedural head-look has to be
	# written after the clip has had its say or it is overwritten every frame.
	# Speed comes from the replicated pose on a remote copy, so the walk cycle
	# runs at the right pace on every screen with no animation on the wire.
	if _avatar != null and is_instance_valid(_avatar):
		var speed: float = sync_speed if not _is_local \
				else Vector3(velocity.x, 0.0, velocity.z).length()
		_avatar.drive(delta, speed, Vector3(velocity.x, 0.0, velocity.z), _collapse)


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
