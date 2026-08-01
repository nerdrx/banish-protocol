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

enum State { DORMANT, SCAN, PURGE }

const SHELL_COLOUR: Color = Color(0.06, 0.06, 0.07)
const ALARM_COLOUR: Color = Color(1.0, 0.18, 0.15)
const BODY_HEIGHT: float = 3.4

## Continuously streamed: the scan sweep's world yaw.
var sync_sweep: float = 0.0

var state: State = State.DORMANT

var _sweep: ScanSweep = null
var _trim_material: StandardMaterial3D = null
var _core_material: StandardMaterial3D = null
var _core_light: OmniLight3D = null
var _shell: Node3D = null

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


## It looks down from the top of a three-metre monolith, so a rack of data blocks
## is not cover from a Sentinel the way it is from a Scrubber.
func _eye_height() -> float:
	return BODY_HEIGHT - 0.4


## The core, so the cutter's aim assist pulls onto the weak point rather than
## onto the middle of three metres of plating.
func aim_point() -> Vector3:
	return global_position + Vector3.UP * 2.5


func _assemble() -> void:
	health = Balance.SENTINEL_HEALTH

	var shape: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.68
	capsule.height = BODY_HEIGHT
	shape.shape = capsule
	shape.position = Vector3(0.0, BODY_HEIGHT * 0.5, 0.0)
	add_child(shape)

	_shell = Node3D.new()
	_shell.name = "Shell"
	add_child(_shell)

	var plate: StandardMaterial3D = StandardMaterial3D.new()
	plate.albedo_color = SHELL_COLOUR
	plate.metallic = 0.5
	plate.roughness = 0.55
	_trim_material = _emissive(ALARM_COLOUR, 0.4)

	# A monolith with a head, not a creature: it is a piece of the architecture
	# that decided to walk.
	_mesh(Vector3(0.0, 1.55, 0.0), Vector3(1.25, 3.1, 1.05), plate)
	_mesh(Vector3(0.0, 3.35, 0.0), Vector3(1.05, 0.6, 0.9), plate)
	_mesh(Vector3(0.0, 0.16, 0.0), Vector3(1.5, 0.32, 1.3), plate)
	for side: float in [-1.0, 1.0]:
		_mesh(Vector3(side * 0.78, 2.1, 0.0), Vector3(0.3, 2.0, 0.6), plate)

	# Quarantine banding: the same red the layer uses for scan sweeps, so the
	# thing and its beam read as one system.
	for i: int in 4:
		_mesh(Vector3(0.0, 0.7 + float(i) * 0.75, -0.53), Vector3(0.95, 0.05, 0.02),
				_trim_material)
	_mesh(Vector3(0.0, 3.35, -0.46), Vector3(0.7, 0.09, 0.03), _trim_material)

	_core_material = _emissive(ALARM_COLOUR, 1.4)
	_mesh(Vector3(0.0, 2.5, -0.5), Vector3(0.34, 0.34, 0.06), _core_material)

	_core_light = OmniLight3D.new()
	_core_light.name = "Core"
	_core_light.position = Vector3(0.0, 2.5, -0.7)
	_core_light.light_color = ALARM_COLOUR
	_core_light.light_energy = 1.0
	_core_light.omni_range = 7.0
	_core_light.omni_attenuation = 1.1
	_core_light.light_volumetric_fog_energy = 1.8
	_core_light.shadow_enabled = false
	_shell.add_child(_core_light)

	_build_sweep()
	_last_seen = home


## The sweep rig, same vocabulary as the layer's wall-mounted scan sweeps
## (GeometryKit._build_scan_sweep) but aimed by this creature rather than by the
## wall clock.
func _build_sweep() -> void:
	_sweep = ScanSweep.new()
	_sweep.name = "Sweep"
	_sweep.driven = true
	_sweep.position = Vector3(0.0, 3.5, 0.0)

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
	spot.light_energy = 14.0
	spot.light_specular = 0.2
	# Heavy fog contribution: the sweep has to read as a visible blade crossing
	# the vault, because dodging it is the fight.
	spot.light_volumetric_fog_energy = 5.0
	spot.spot_range = Balance.SENTINEL_SCAN_RANGE + 4.0
	spot.spot_angle = Balance.SENTINEL_SCAN_HALF_ANGLE_DEG
	spot.spot_angle_attenuation = 1.3
	spot.spot_attenuation = 0.6
	spot.shadow_enabled = true
	spot.shadow_bias = 0.05
	_sweep.add_child(spot)

	_shell.add_child(_sweep)


func _mesh(at: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	_shell.add_child(mesh)
	return mesh


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
func breaker_damage(from: Vector3) -> float:
	if not core_exposed():
		return Balance.BREAKER_DAMAGE
	var to_shooter: Vector3 = from - global_position
	to_shooter.y = 0.0
	if to_shooter.length_squared() < 0.01:
		return Balance.BREAKER_DAMAGE
	var facing: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	if to_shooter.normalized().dot(facing) < cos(deg_to_rad(Balance.SENTINEL_CORE_ARC_DEG)):
		return Balance.BREAKER_DAMAGE
	return Balance.BREAKER_DAMAGE * Balance.SENTINEL_CORE_MULTIPLIER


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
	burst.position = Vector3(0.0, 2.2, 0.0)
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

	# Clients drive the sweep transform from the streamed angle; the host from
	# the one it just wrote. Same line either way.
	if _sweep != null and is_instance_valid(_sweep):
		_sweep.rotation.y = sync_sweep - rotation.y

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
