class_name Sentinel
extends Antivirus
## The quarantine process standing in the vault. Slow, heavy, armoured, and the
## closest thing a layer has to a boss.
##
## DESIGN.md: "slow heavy quarantine process, beam-immune, area denial, guards
## data vaults. Announces itself with a red scan sweep." Beam-immune means the
## *decryption* beam: light does not push a Sentinel around the way it routs a
## Scrubber, and it will not leave its vault. It is not immune to the breaker —
## nothing is — it is simply built like the wall it used to be.
##
## The fight it offers: eighteen Scrubbers' worth of armour, and a core that is
## only exposed while it is scanning or purging. Standing in front of an active
## Sentinel is where the triple damage is and where the purge arc lands, so
## killing one is a question of who is in front of it and when. What it was
## guarding falls out of it when it dies.
##
## States (host only):
##   DORMANT sat on its post, sweep idling dim
##   SCAN    crew nearby: the sweep runs; touching a player raises the alarm
##   PURGE   advance on the last-seen position and swing, until it loses you
##
## The sweep angle is replicated (`sync_sweep`), because the sweep *is* the
## mechanic and it has to be in the same place on every screen.
##
## M3.7 replaced the procedural monolith with the authored CyberSentinel model
## (2.6 m, 94 bones, 44.9k tris) wearing the quarantine dressing kit. Three
## decisions in that swap are load-bearing:
##
##   **It does not walk.** There is no locomotion clip and there is not going to
##   be one. A quarantine process is not an animal; it *glides* — frictionless
##   drift with a glitch-stutter when it changes direction, which is what a thing
##   that is being re-rendered from one position to the next would look like.
##   Legs that stayed still while the body slid would be a bug; legs that never
##   pretend to walk are a character.
##
##   **It watches you.** The neck and head are driven procedurally toward
##   whatever it is tracking, so a Sentinel standing perfectly still still turns
##   its face to follow a crewmate crossing the vault. This costs two bone poses
##   a frame and buys most of the dread.
##
##   **The CoreHousing IS the weak point.** The kit's core prop is where
##   `aim_point()` points and where the bonus damage arc is measured from, so
##   what the player is aiming at and what the rules care about are the same
##   object rather than two numbers that happen to agree. It burns brighter the
##   moment the shielding drops for a SCAN or a PURGE — the telegraph and the
##   hitbox are one piece of art.

enum State { DORMANT, SCAN, PURGE }

const SHELL_COLOUR: Color = Color(0.06, 0.06, 0.07)
const ALARM_COLOUR: Color = Color(1.0, 0.18, 0.15)
## Standing height of the authored model. Was 3.4 for the box monolith.
const BODY_HEIGHT: float = 2.6

## The dressing kit was authored against the 1.9746 m source rig and, under the
## older art convention, facing +Z. Both are fixed by one wrapper node rather
## than by re-exporting: yaw it half a turn and scale it by the same factor the
## body was scaled by.
const KIT_SCALE: float = 1.31670669

## Where the kit props sit in the Sentinel's own space, already converted.
## CoreHousing lands 13 cm in front of the `ChestUp` bone, which is exactly where
## a chest plate belongs.
const CORE_AT: Vector3 = Vector3(0.0, 1.8935, -0.1317)
const HALO_AT: Vector3 = Vector3(0.0, 1.7092, 0.0)
const PYLON_AT: Vector3 = Vector3(0.3950, 2.0516, 0.0)

## How far the head and neck may swing off centre while tracking.
const LOOK_YAW_LIMIT: float = 1.05
const LOOK_PITCH_LIMIT: float = 0.42
## Split between the two bones. Neck leads, head finishes — all of it in the head
## reads as an owl, all of it in the neck reads as a tank turret.
const NECK_SHARE: float = 0.42

## Direction-change stutter. A Sentinel that changed heading smoothly would just
## be a slow player; the hitch is what says "this thing is being recomputed".
const STUTTER_TRIGGER: float = 0.35
const STUTTER_TIME: float = 0.22

## Continuously streamed: the scan sweep's world yaw.
var sync_sweep: float = 0.0

var state: State = State.DORMANT

var _sweep: ScanSweep = null
var _trim_material: StandardMaterial3D = null
var _core_material: StandardMaterial3D = null
var _core_light: OmniLight3D = null
var _shell: Node3D = null
var _halo: Node3D = null
var _skeleton: Skeleton3D = null
var _neck_bone: int = -1
var _head_bone: int = -1
## Smoothed look angles, so the head eases onto a target instead of snapping.
var _look: Vector2 = Vector2.ZERO
## Glitch-stutter state.
var _stutter: float = 0.0
var _last_heading: Vector3 = Vector3.FORWARD
var _remote_last: Vector3 = Vector3.ZERO

var _target: Node3D = null
var _last_seen: Vector3 = Vector3.ZERO
var _calm: float = 0.0
var _swing_cooldown: float = 0.0
var _swing: float = 0.0
## Local: eases 0 -> 1 on an alarm so the whole body flares, on every peer.
var _alarm_flash: float = 0.0
var _hurt_flash: float = 0.0
## 0 -> 1 collapse once it goes down.
var _death: float = 0.0


func _extra_sync_properties() -> Array[String]:
	return [".:sync_sweep"]


## It looks down from head height on a two-and-a-half-metre body, so a rack of
## data blocks is not cover from a Sentinel the way it is from a Scrubber.
func _eye_height() -> float:
	return BODY_HEIGHT - 0.35


## The core housing, so the cutter's aim assist pulls onto the weak point rather
## than onto the middle of two and a half metres of plating — and so the thing
## the player is aiming at is literally the prop that lights up when the
## shielding drops.
func aim_point() -> Vector3:
	return global_transform * CORE_AT


func _assemble() -> void:
	health = Balance.SENTINEL_HEALTH

	# Sized to the authored mesh (0.85 m wide, 2.6 m tall). The box monolith it
	# replaces was 3.4 m with a 0.68 m radius; leaving that in place would have
	# meant a metre of invisible Sentinel above its own head and a hitbox you
	# could clip without touching the model.
	var shape: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.52
	capsule.height = BODY_HEIGHT
	shape.shape = capsule
	shape.position = Vector3(0.0, BODY_HEIGHT * 0.5, 0.0)
	add_child(shape)

	_shell = Node3D.new()
	_shell.name = "Shell"
	add_child(_shell)

	_trim_material = _emissive(ALARM_COLOUR, 0.4)
	_core_material = _emissive(ALARM_COLOUR, 1.4)

	_build_body()
	_build_kit()

	_core_light = OmniLight3D.new()
	_core_light.name = "Core"
	_core_light.position = CORE_AT + Vector3(0.0, 0.0, -0.22)
	_core_light.light_color = ALARM_COLOUR
	_core_light.light_energy = 1.0
	_core_light.omni_range = 7.0
	_core_light.omni_attenuation = 1.1
	_core_light.light_volumetric_fog_energy = 1.8
	_core_light.shadow_enabled = false
	_shell.add_child(_core_light)

	_build_sweep()
	_last_seen = home
	_last_heading = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))


## The body, repainted to the enemy palette: everything structural swallows light
## and only the Emiss and Eyes slots burn. DESIGN.md reserves red for hostile
## processes, and the Sentinel is the loudest thing wearing it.
func _build_body() -> void:
	var model: Node3D = CreatureKit.instantiate(CreatureKit.SENTINEL)
	if model == null:
		return
	model.name = "Body"
	_shell.add_child(model)

	var dark: StandardMaterial3D = CreatureKit.matte(SHELL_COLOUR, 0.35, 0.52)
	var deep: StandardMaterial3D = CreatureKit.matte(
			CreatureKit.ENEMY_BODY, 0.2, 0.62)
	CreatureKit.paint(CreatureKit.find_mesh(model), {
		"LightMetal": dark,
		"Armour": dark,
		"Bone": dark,
		"Mask": deep,
		"Slime": deep,
		"Emiss": _trim_material,
		"Eyes": _core_material,
	})

	_skeleton = CreatureKit.find_skeleton(model)
	if _skeleton != null:
		_neck_bone = _skeleton.find_bone("Neck")
		_head_bone = _skeleton.find_bone("Head")


## The quarantine dressing, socketed at the attach points the kit was authored
## for. The wrapper carries the half-turn and the scale (see KIT_SCALE); the
## pieces then sit at plain coordinates in the Sentinel's own space, which is the
## only form anybody reading this later can check against the model.
##
## The kit's `_L`/`_R` suffixes are mirrored relative to the rig's bone naming —
## `ScanPylon_R` was authored on the rig's left. The pylons carry asymmetric
## emitter hoods, so they are placed by explicit side here rather than by their
## baked origins, and the names are swapped exactly once, here, with this comment
## next to it.
func _build_kit() -> void:
	var kit: Node3D = CreatureKit.instantiate(CreatureKit.SENTINEL_KIT)
	if kit == null:
		return

	var core_material: StandardMaterial3D = _core_material
	var palette: Dictionary = {
		"Body": CreatureKit.matte(SHELL_COLOUR, 0.4, 0.45),
		"Plate": CreatureKit.matte(CreatureKit.ENEMY_PLATE, 0.5, 0.36),
		"EmissRed": _trim_material,
		"CoreEmiss": core_material,
	}

	var mounts: Dictionary = {
		"CoreHousing": CORE_AT,
		"QuarantineHalo": HALO_AT,
		# Swapped on purpose — see the note above.
		"ScanPylon_L": Vector3(PYLON_AT.x, PYLON_AT.y, PYLON_AT.z),
		"ScanPylon_R": Vector3(-PYLON_AT.x, PYLON_AT.y, PYLON_AT.z),
	}
	for piece: String in mounts:
		var source: Node = kit.find_child(piece, true, false)
		var mesh: MeshInstance3D = source as MeshInstance3D
		if mesh == null:
			push_warning("[Sentinel] dressing kit has no %s" % piece)
			continue
		var socket: Node3D = Node3D.new()
		socket.name = piece
		socket.position = mounts[piece]
		# The kit's own space, folded into the socket: half a turn to face -Z and
		# the body's scale factor.
		socket.rotation.y = PI
		socket.scale = Vector3.ONE * KIT_SCALE
		_shell.add_child(socket)

		# Clear the owner first: the piece still belongs to the kit scene it was
		# instantiated from, and re-parenting an owned node logs a warning about
		# an inconsistent owner on every Sentinel a layer spawns.
		source.owner = null
		source.get_parent().remove_child(source)
		mesh.transform = Transform3D.IDENTITY
		socket.add_child(mesh)
		CreatureKit.paint(mesh, palette)
		if piece == "QuarantineHalo":
			_halo = socket
	kit.queue_free()


## The sweep rig, same vocabulary as the layer's wall-mounted scan sweeps
## (GeometryKit._build_scan_sweep) but aimed by this creature rather than by the
## wall clock.
func _build_sweep() -> void:
	_sweep = ScanSweep.new()
	_sweep.name = "Sweep"
	_sweep.driven = true
	# Out of the scan pylons on its shoulders, not off the top of its head: the
	# emitter the player can see and the blade crossing the room are one fixture.
	_sweep.position = Vector3(0.0, PYLON_AT.y + 0.22, 0.0)

	var emitter: MeshInstance3D = MeshInstance3D.new()
	var bar: BoxMesh = BoxMesh.new()
	bar.size = Vector3(0.7, 0.06, 0.08)
	emitter.mesh = bar
	emitter.position = Vector3(0.0, -0.1, 0.0)
	emitter.material_override = _emissive(ALARM_COLOUR, 2.0)
	emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sweep.add_child(emitter)

	var spot: SpotLight3D = SpotLight3D.new()
	spot.name = "Spot"
	spot.position = Vector3(0.0, -0.16, 0.0)
	spot.rotation = Vector3(deg_to_rad(-74.0), 0.0, 0.0)
	spot.light_color = ALARM_COLOUR
	# Was 14 with a fog contribution of 5. Against the look-dev floor materials
	# that produced a flat saturated red sheet the moment the beam raked through
	# a doorway — the sweep stopped reading as a blade and became a filter over
	# the whole frame. The blade is the mechanic; it has to be a shape.
	spot.light_energy = 7.0
	spot.light_specular = 0.2
	# Still a heavy fog contribution: the sweep has to read as a visible blade
	# crossing the vault, because dodging it is the fight.
	spot.light_volumetric_fog_energy = 2.6
	spot.spot_range = Balance.SENTINEL_SCAN_RANGE + 4.0
	spot.spot_angle = Balance.SENTINEL_SCAN_HALF_ANGLE_DEG
	spot.spot_angle_attenuation = 1.3
	spot.spot_attenuation = 0.6
	spot.shadow_enabled = true
	spot.shadow_bias = 0.05
	_sweep.add_child(spot)

	_shell.add_child(_sweep)


func _emissive(colour: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(0.8)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.45
	material.disable_receive_shadows = true
	return material


# --------------------------------------------------------------------- armour --

## Armour plating everywhere except the core, and the core is only out while it
## is working. A shot into its back or into a dormant one chips at 1800 hit
## points; a shot into the exposed core does triple and turns the fight into
## something a crew can finish.
func breaker_damage(from: Vector3, base: float = Balance.BREAKER_DAMAGE) -> float:
	if not core_exposed():
		return base
	var to_shooter: Vector3 = from - global_position
	to_shooter.y = 0.0
	if to_shooter.length_squared() < 0.01:
		return base
	var facing: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	if to_shooter.normalized().dot(facing) < cos(deg_to_rad(Balance.SENTINEL_CORE_ARC_DEG)):
		return base
	return base * Balance.SENTINEL_CORE_MULTIPLIER


## Whether the shielding is down. Fiction and mechanic are the same thing here:
## it cannot scan or purge with the core covered.
func core_exposed() -> bool:
	return int(sync_state) != int(State.DORMANT)


# ---------------------------------------------------------------- decisions --

func _think() -> void:
	var tick: float = Balance.AI_TICK
	if _swing_cooldown > 0.0:
		_swing_cooldown -= tick

	match state:
		State.DORMANT:
			if _nearest_player(Balance.SENTINEL_WAKE_RANGE, false) != null:
				_enter(State.SCAN)
		State.SCAN:
			var seen: Node3D = _swept_player()
			if seen != null:
				_target = seen
				_last_seen = seen.global_position
				_enter(State.PURGE)
			elif _nearest_player(Balance.SENTINEL_WAKE_RANGE + 6.0, false) == null:
				_enter(State.DORMANT)
		State.PURGE:
			var prey: Node3D = _nearest_player(Balance.SENTINEL_SCAN_RANGE, false)
			if prey != null and _within_leash(prey.global_position):
				_target = prey
				_last_seen = prey.global_position
				_calm = Balance.SENTINEL_CALM_TIME
			else:
				_target = null
				_calm -= tick
				if _calm <= 0.0:
					_enter(State.SCAN)


func _enter(next: State) -> void:
	if state == next:
		return
	state = next
	sync_state = int(next)
	if next == State.PURGE:
		_calm = Balance.SENTINEL_CALM_TIME
		_raise_alarm()
		_tell_crew(&"_raise_alarm")
		Run.broadcast_notice("QUARANTINE PROCESS ALERTED")
	if Debug.log_ai:
		print("[AI] sentinel %d layer %d -> %s at %s" % [
			slot_index, layer_number, State.keys()[int(next)],
			str(global_position.snapped(Vector3.ONE * 0.1))])


## A player standing in the sweep right now: inside the cone, inside the range,
## and not behind a rack. This is the only way a Sentinel acquires a target — you
## can walk past a dormant one in the dark if you time it.
func _swept_player() -> Node3D:
	var limit: float = cos(deg_to_rad(Balance.SENTINEL_SCAN_HALF_ANGLE_DEG))
	var facing: Vector3 = Vector3(-sin(sync_sweep), 0.0, -cos(sync_sweep))
	for body: Node3D in _running_players():
		var to_body: Vector3 = body.global_position - global_position
		to_body.y = 0.0
		var distance: float = to_body.length()
		if distance > Balance.SENTINEL_SCAN_RANGE or distance < 0.01:
			continue
		if (to_body / distance).dot(facing) < limit:
			continue
		if not _has_los(body):
			continue
		return body
	return null


## The Sentinel does not leave its vault. Anything further than the leash from
## its post is somebody else's problem.
func _within_leash(where: Vector3) -> bool:
	return where.distance_to(home) <= Balance.SENTINEL_LEASH


# ------------------------------------------------------------------ movement --

func _act(delta: float) -> void:
	_advance_sweep(delta)
	_watch_heading(delta)

	match state:
		State.DORMANT:
			# Walk home if something dragged it off its post, otherwise stand.
			if global_position.distance_to(home) > 1.5:
				_steer(_route_to(home), Balance.SENTINEL_WALK_SPEED, delta)
			else:
				_steer(global_position, 0.0, delta)
		State.SCAN:
			_steer(global_position, 0.0, delta)
		State.PURGE:
			_act_purge(delta)


## Direction-change detector, host side. A Sentinel has no legs to tell you it
## turned, so the turn itself has to be an event: past a threshold of heading
## change it drops a stutter flag that every peer reads off `sync_state`-adjacent
## motion, and the shell hitches for a fifth of a second.
func _watch_heading(delta: float) -> void:
	var planar: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	if planar.length_squared() < 0.04:
		return
	var heading: Vector3 = planar.normalized()
	if heading.dot(_last_heading) < 1.0 - STUTTER_TRIGGER * delta * 12.0:
		_stutter = STUTTER_TIME
	_last_heading = heading


## The sweep runs while awake and idles slowly while dormant, so a vault always
## has *some* red moving in it — the room announces itself before the process in
## it does.
func _advance_sweep(delta: float) -> void:
	var rate: float = Balance.SENTINEL_SCAN_SPEED
	match state:
		State.DORMANT:
			rate *= 0.35
		State.PURGE:
			# Locked forward: it stops looking and starts clearing.
			var want: float = rotation.y
			sync_sweep = lerp_angle(sync_sweep, want, 1.0 - exp(-6.0 * delta))
			return
	sync_sweep = wrapf(sync_sweep + rate * delta, -PI, PI)


## Advance and swing. The arc is wide and slow: standing in front of a purging
## Sentinel is a decision, and there is always a way around it.
func _act_purge(delta: float) -> void:
	var goal: Vector3 = _last_seen
	if _target != null and is_instance_valid(_target):
		goal = _target.global_position
	if not _within_leash(goal):
		goal = home

	var reach: float = goal.distance_to(global_position)
	if reach > Balance.SENTINEL_PURGE_RANGE * 0.75:
		_steer(_route_to(goal), Balance.SENTINEL_PURGE_SPEED, delta)
	else:
		_steer(global_position, 0.0, delta)
		_face((goal - global_position).normalized(), delta)

	if _swing > 0.0:
		_swing -= delta
		return
	if _swing_cooldown > 0.0 or reach > Balance.SENTINEL_PURGE_RANGE:
		return

	_swing = 0.35
	_swing_cooldown = Balance.SENTINEL_PURGE_COOLDOWN
	_strike()


## Area denial, not a single-target hit: everyone inside the arc takes it.
func _strike() -> void:
	var limit: float = cos(deg_to_rad(Balance.SENTINEL_PURGE_ARC_DEG))
	var facing: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	var landed: bool = false
	for body: Node3D in _running_players():
		var to_body: Vector3 = body.global_position - global_position
		to_body.y = 0.0
		var distance: float = to_body.length()
		if distance > Balance.SENTINEL_PURGE_RANGE or distance < 0.01:
			continue
		if (to_body / distance).dot(facing) < limit:
			continue
		Run.damage_player(int(String(body.name)), Balance.SENTINEL_PURGE_DAMAGE,
				global_position)
		landed = true
	_purge_swing(landed)
	_tell_crew(&"_purge_swing")


# -------------------------------------------------------------------- events --

func _on_hurt() -> void:
	_hit()
	_tell_crew(&"_hit")


@rpc("authority", "call_remote", "unreliable_ordered")
func _hit() -> void:
	_hurt_flash = 1.0


## Everything the vault was holding falls out of it. DESIGN.md puts the haul in
## the vault and the Sentinel in front of it; this is the other half of that
## bargain, and the reason a crew would ever choose to fight one.
func kill() -> void:
	if _dying:
		return
	if _is_host:
		Run.drop_salvage(global_position, Balance.SENTINEL_DROP_SHARDS,
				Balance.SENTINEL_DROP_PIECES)
		Run.broadcast_notice("QUARANTINE PROCESS TERMINATED")
	super()


## It topples. Slower and heavier than a Scrubber's shatter, with the core
## blowing out first — three metres of architecture coming down.
func _play_death() -> void:
	_death = 1.0
	set_physics_process(false)
	if _sweep != null and is_instance_valid(_sweep):
		_sweep.set_intensity(0.0)

	var burst: CPUParticles3D = CPUParticles3D.new()
	burst.name = "Collapse"
	burst.emitting = true
	burst.one_shot = true
	burst.amount = 70
	burst.lifetime = 1.6
	burst.explosiveness = 0.85
	burst.position = CORE_AT
	burst.direction = Vector3.UP
	burst.spread = 180.0
	burst.initial_velocity_min = 2.0
	burst.initial_velocity_max = 7.5
	burst.gravity = Vector3(0.0, -9.0, 0.0)
	burst.scale_amount_min = 0.08
	burst.scale_amount_max = 0.3
	var fragment: BoxMesh = BoxMesh.new()
	fragment.size = Vector3.ONE
	burst.mesh = fragment
	burst.material_override = _emissive(ALARM_COLOUR, 2.6)
	add_child(burst)


## Client-side heading watch, from the smoothed pose rather than from velocity.
func _watch_remote_heading(delta: float) -> void:
	var moved: Vector3 = global_position - _remote_last
	_remote_last = global_position
	moved.y = 0.0
	if moved.length_squared() < 0.0004:
		return
	var heading: Vector3 = moved.normalized()
	if heading.dot(_last_heading) < 1.0 - STUTTER_TRIGGER * delta * 12.0:
		_stutter = STUTTER_TIME
	_last_heading = heading


@rpc("authority", "call_remote", "reliable")
func _raise_alarm() -> void:
	_alarm_flash = 1.0


## Every peer sees the swing whether or not it connected — a purge you dodged has
## to look like a purge you dodged. Only the host knows whether it landed, and
## only the host's own copy bothers to weight the flash by it.
@rpc("authority", "call_remote", "unreliable_ordered")
func _purge_swing(landed: bool = false) -> void:
	_alarm_flash = maxf(_alarm_flash, 0.7 if landed else 0.45)


func _process(delta: float) -> void:
	if _death > 0.0:
		_die_visual(delta)
		return

	_alarm_flash = maxf(_alarm_flash - delta * 1.6, 0.0)
	_hurt_flash = maxf(_hurt_flash - delta * 3.0, 0.0)
	if not _is_host:
		# Clients do not run `_watch_heading` (it lives in the host's `_act`), so
		# they detect the same turn off the pose they are being streamed. Same
		# effect, no extra byte on the wire.
		_watch_remote_heading(delta)

	# Clients drive the sweep transform from the streamed angle; the host from
	# the one it just wrote. Same line either way.
	if _sweep != null and is_instance_valid(_sweep):
		_sweep.rotation.y = sync_sweep - rotation.y

	_spin_halo(delta)
	_track_head(delta)
	_apply_stutter(delta)

	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var breath: float = 0.85 + sin(t * 1.1) * 0.15
	var trim: float = 0.4
	var core: float = 1.0
	var sweep_scale: float = 0.35

	match int(sync_state):
		int(State.SCAN):
			trim = 1.0
			core = 1.6
			sweep_scale = 1.0
		int(State.PURGE):
			var pulse: float = 0.6 + 0.4 * absf(sin(t * 5.0))
			trim = 2.4 * pulse
			core = 5.0 * pulse
			sweep_scale = 1.35

	trim += _alarm_flash * 3.0
	# The core is the weak point, so it has to *look* like one the moment the
	# shielding drops: dull plate while dormant, a hot exposed lamp while awake.
	if core_exposed():
		core *= 1.8
	core += _alarm_flash * 6.0 + _hurt_flash * 9.0
	_trim_material.emission_energy_multiplier = trim * breath
	_core_material.emission_energy_multiplier = core * breath
	_core_light.light_energy = core * breath
	if _sweep != null and is_instance_valid(_sweep):
		_sweep.set_intensity((sweep_scale + _alarm_flash) * breath)


## The quarantine halo turns slowly and independently of the body, which is the
## clearest possible statement that this thing is machinery rather than an
## animal: nothing alive has a part that rotates.
func _spin_halo(delta: float) -> void:
	if _halo == null or not is_instance_valid(_halo):
		return
	var rate: float = 0.35
	match int(sync_state):
		int(State.SCAN):
			rate = 0.9
		int(State.PURGE):
			rate = 2.1
	# The halo socket carries the kit's half-turn in `rotation.y`, so spin has to
	# accumulate on top of PI rather than replace it.
	_halo.rotation.y = wrapf(_halo.rotation.y + rate * delta, -PI, PI * 3.0)


## Procedural head-look, on every peer.
##
## The Sentinel has no animation of any kind, so this is the only thing that
## makes it read as *aware* rather than as a prop. It is deliberately slow and
## deliberately limited: a head that snapped onto you would be a turret, and a
## head with no limit would spin like an owl and stop being frightening.
##
## Rotations are built about the world up and the creature's own right axis,
## pulled back into each bone's parent-pose space — bone rests in an imported rig
## point in whatever direction the artist left them, and rotating about a bone's
## own local axes gives a different (wrong) answer for every rig.
func _track_head(delta: float) -> void:
	if _skeleton == null or not is_instance_valid(_skeleton):
		return
	if _neck_bone < 0 and _head_bone < 0:
		return

	var want: Vector2 = Vector2.ZERO
	var subject: Node3D = _look_subject()
	if subject != null:
		var eye: Vector3 = global_position + Vector3.UP * _eye_height()
		var local: Vector3 = global_transform.basis.inverse() \
				* (subject.global_position + Vector3.UP * 1.2 - eye)
		if local.length_squared() > 0.01:
			want = Vector2(
					clampf(atan2(-local.x, -local.z), -LOOK_YAW_LIMIT, LOOK_YAW_LIMIT),
					clampf(atan2(local.y, Vector2(local.x, local.z).length()),
							-LOOK_PITCH_LIMIT, LOOK_PITCH_LIMIT))

	_look = _look.lerp(want, 1.0 - exp(-4.5 * delta))
	_aim_bone(_neck_bone, _look * NECK_SHARE)
	_aim_bone(_head_bone, _look * (1.0 - NECK_SHARE))


## Who it is looking at. While dormant it watches whoever is nearest — it has not
## acquired them, it is just a camera that noticed movement — and once awake it
## stares at what it is hunting.
func _look_subject() -> Node3D:
	if _target != null and is_instance_valid(_target):
		return _target
	var nearest: Node3D = null
	var best: float = Balance.SENTINEL_SCAN_RANGE
	for body: Node3D in _running_players():
		var distance: float = body.global_position.distance_to(global_position)
		if distance < best:
			best = distance
			nearest = body
	return nearest


func _aim_bone(bone: int, angles: Vector2) -> void:
	if bone < 0:
		return
	var parent: int = _skeleton.get_bone_parent(bone)
	var parent_basis: Basis = _skeleton.global_transform.basis
	if parent >= 0:
		parent_basis = parent_basis * _skeleton.get_bone_global_pose(parent).basis
	var inverse: Basis = parent_basis.inverse()
	var up: Vector3 = (inverse * Vector3.UP).normalized()
	var right: Vector3 = (inverse * global_transform.basis.x).normalized()
	var delta: Quaternion = Quaternion(up, angles.x) * Quaternion(right, -angles.y)
	_skeleton.set_bone_pose_rotation(bone,
			delta * _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion())


## The glitch-stutter. Not a wobble — a hitch: the shell jumps a few centimetres
## off its own transform and snaps back, and the trim flickers with it, so a
## Sentinel changing direction looks like a frame that failed to render rather
## than like a body turning.
func _apply_stutter(delta: float) -> void:
	if _shell == null:
		return
	if _stutter <= 0.0:
		if _shell.position != Vector3.ZERO:
			_shell.position = Vector3.ZERO
		return
	_stutter = maxf(_stutter - delta, 0.0)
	var step: int = int(_stutter * 90.0)
	var jitter: float = 0.055 * (_stutter / STUTTER_TIME)
	_shell.position = Vector3(
			float(step % 3 - 1) * jitter, 0.0, float(step % 2) * jitter * 0.6)


## Topple: the shell tips, the core goes out, and the whole thing sinks into the
## floor it used to be part of.
func _die_visual(delta: float) -> void:
	_death = maxf(_death - delta * 0.7, 0.0)
	var fall: float = 1.0 - _death
	_shell.rotation.x = fall * 1.35
	_shell.position.y = -fall * 1.2
	_core_material.emission_energy_multiplier = 14.0 * sin(clampf(fall, 0.0, 1.0) * PI)
	_trim_material.emission_energy_multiplier = 2.0 * _death
	_core_light.light_energy = 9.0 * sin(clampf(fall, 0.0, 1.0) * PI)
	if _death <= 0.001:
		queue_free()
