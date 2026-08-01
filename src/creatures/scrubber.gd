class_name Scrubber
extends Antivirus
## MOTHER's cheap disposable cleaner: fast, fragile, and terrified of light.
##
## DESIGN.md: "fast pack hunters, weak, avoid decryption beams, swarm from the
## dark". The whole creature is built around one rule — put your beam on it and
## it breaks. That makes your light a weapon and a liability at once, because it
## is also the only reason you can see the room it is running around.
##
## States (host only):
##   LURK  drifting patrol inside an unlit nest room
##   STALK a player is within hearing: close the distance through the room graph
##   LUNGE inside reach: dash, strike, recover
##   FLEE  exposed to a beam or a flare for EXPOSURE_LIMIT: scatter to the dark
##
## Everything a client sees is `sync_state` plus a streamed pose: the skitter,
## the sensor colour and the death shatter are all local reactions to those.

enum State { LURK, STALK, LUNGE, FLEE }

const BODY_HEIGHT: float = 0.42
const SENSOR_COLOUR: Color = Color(1.0, 0.16, 0.14)
const SHELL_COLOUR: Color = Color(0.05, 0.05, 0.06)

var state: State = State.LURK

var _sensor: MeshInstance3D = null
var _sensor_material: StandardMaterial3D = null
var _trim_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _shell: Node3D = null
var _legs: Array[MeshInstance3D] = []

## Host sim.
var _target: Node3D = null
var _last_seen: Vector3 = Vector3.ZERO
var _exposure: float = 0.0
var _flee_time: float = 0.0
var _lunge_time: float = 0.0
var _recover_time: float = 0.0
var _struck: bool = false
var _patrol: Vector3 = Vector3.ZERO
var _patrol_time: float = 0.0
var _alert_point: Vector3 = Vector3.ZERO
var _alert_time: float = 0.0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

## Local animation, driven on every peer from the pose it can see.
var _skitter: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _hurt_flash: float = 0.0
var _death: float = 0.0


func _assemble() -> void:
	health = Balance.SCRUBBER_HEALTH
	speed_scale = float(LayerParams.of(layer_number)["scrubber_speed"])

	var shape: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.36
	capsule.height = 0.9
	shape.shape = capsule
	shape.position = Vector3(0.0, 0.45, 0.0)
	add_child(shape)

	_shell = Node3D.new()
	_shell.name = "Shell"
	add_child(_shell)

	var plate: StandardMaterial3D = StandardMaterial3D.new()
	plate.albedo_color = SHELL_COLOUR
	plate.metallic = 0.65
	plate.roughness = 0.42
	_trim_material = _emissive(SENSOR_COLOUR, 0.55)

	# A low wedge, wider than it is tall. Read half-seen in a beam's spill it is
	# barely a shape at all, which is the point.
	_mesh(_shell, Vector3(0.0, BODY_HEIGHT, 0.0), Vector3(0.68, 0.3, 1.0), plate)
	_mesh(_shell, Vector3(0.0, BODY_HEIGHT + 0.2, -0.16), Vector3(0.44, 0.22, 0.5), plate)
	# Hairline red trim: enough emissive to be findable in the dark without ever
	# lighting the floor it is crossing.
	_mesh(_shell, Vector3(0.0, BODY_HEIGHT + 0.15, 0.0), Vector3(0.7, 0.02, 0.62),
			_trim_material)
	_mesh(_shell, Vector3(0.0, BODY_HEIGHT - 0.13, 0.0), Vector3(0.56, 0.02, 0.9),
			_trim_material)

	# Four skittering legs. Cheap, but a thing that moves on legs is a different
	# animal from a thing that slides.
	for i: int in 4:
		var side: float = -1.0 if i % 2 == 0 else 1.0
		var fore: float = -1.0 if i < 2 else 1.0
		var leg: MeshInstance3D = _mesh(_shell,
				Vector3(side * 0.34, BODY_HEIGHT * 0.55, fore * 0.3),
				Vector3(0.06, 0.62, 0.06), plate)
		leg.rotation = Vector3(0.0, 0.0, side * 0.42)
		_legs.append(leg)

	# The single sensor eye. It is the only part of a Scrubber you ever really
	# see, so it carries the whole state read.
	_sensor_material = _emissive(SENSOR_COLOUR, 3.4)
	_sensor = MeshInstance3D.new()
	var eye: SphereMesh = SphereMesh.new()
	eye.radius = 0.09
	eye.height = 0.18
	eye.radial_segments = 10
	eye.rings = 5
	_sensor.mesh = eye
	_sensor.position = Vector3(0.0, BODY_HEIGHT + 0.24, -0.4)
	_sensor.material_override = _sensor_material
	_sensor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shell.add_child(_sensor)

	_light = OmniLight3D.new()
	_light.name = "Sensor"
	_light.position = Vector3(0.0, BODY_HEIGHT + 0.24, -0.5)
	_light.light_color = SENSOR_COLOUR
	# Deliberately feeble and short. The sensor has to be *findable* in the dark,
	# not a lamp — a Scrubber that lights the room it is hunting in has undone
	# DESIGN.md pillar 2 on its own.
	_light.light_energy = 0.8
	_light.omni_range = 2.6
	_light.omni_attenuation = 1.6
	_light.light_volumetric_fog_energy = 1.6
	_light.shadow_enabled = false
	_shell.add_child(_light)

	_rng.seed = hash(str(slot_index, ":scrubber:", layer_number))
	_patrol = home
	_last_position = position


## Its sensor is at ankle height, which is why a rack of data blocks is real
## cover from a Scrubber.
func _eye_height() -> float:
	return BODY_HEIGHT + 0.2


func _mesh(parent: Node3D, at: Vector3, size: Vector3,
		material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	parent.add_child(mesh)
	return mesh


func _emissive(colour: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(0.75)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.4
	material.disable_receive_shadows = true
	return material


# ---------------------------------------------------------------- decisions --

func _think() -> void:
	var tick: float = Balance.AI_TICK

	# Exposure is measured in every state: a Scrubber mid-lunge that runs into a
	# beam still breaks off, which is what makes turning to face one work.
	if _in_player_light():
		_exposure += tick
	else:
		_exposure = maxf(_exposure - tick * 1.5, 0.0)
	if state != State.FLEE and _exposure >= Balance.SCRUBBER_EXPOSURE_LIMIT:
		_enter(State.FLEE)
		return

	if _alert_time > 0.0:
		_alert_time -= tick

	match state:
		State.LURK:
			_think_lurk(tick)
		State.STALK:
			_think_stalk()
		State.LUNGE:
			_think_lunge()
		State.FLEE:
			_think_flee(tick)


func _think_lurk(tick: float) -> void:
	var prey: Node3D = _nearest_player(Balance.SCRUBBER_HEAR_RANGE, false)
	if prey != null:
		_target = prey
		_last_seen = prey.global_position
		_enter(State.STALK)
		return
	if _alert_time > 0.0:
		_enter(State.STALK)
		return

	# Drift: a new loitering point every few seconds, inside the nest.
	_patrol_time -= tick
	if _patrol_time <= 0.0 or global_position.distance_to(_patrol) < 1.5:
		_patrol_time = _rng.randf_range(2.5, 5.0)
		_patrol = _wander_point()


func _think_stalk() -> void:
	var prey: Node3D = _nearest_player(Balance.SCRUBBER_LOSE_RANGE, false)
	if prey != null:
		_target = prey
		_last_seen = prey.global_position
		var distance: float = prey.global_position.distance_to(global_position)
		if distance <= Balance.SCRUBBER_LUNGE_RANGE and _has_los(prey):
			_enter(State.LUNGE)
		return

	_target = null
	# Nothing to chase: finish the trip to the last known position (or to the
	# junction that pinged), then go back to lurking.
	var goal: Vector3 = _alert_point if _alert_time > 0.0 else _last_seen
	if global_position.distance_to(goal) < 3.0:
		_enter(State.LURK)


func _think_lunge() -> void:
	if _recover_time > 0.0 or _lunge_time > 0.0:
		return
	var prey: Node3D = _nearest_player(Balance.SCRUBBER_LOSE_RANGE, false)
	if prey == null:
		_enter(State.LURK)
		return
	_target = prey
	_last_seen = prey.global_position
	_enter(State.STALK)


func _think_flee(tick: float) -> void:
	_flee_time -= tick
	if _flee_time > 0.0:
		return
	if _in_player_light():
		_flee_time = Balance.SCRUBBER_FLEE_TIME * 0.5
		return
	_exposure = 0.0
	_enter(State.LURK)


func _enter(next: State) -> void:
	if state == next:
		return
	state = next
	sync_state = int(next)

	match next:
		State.LUNGE:
			_lunge_time = Balance.SCRUBBER_LUNGE_TIME
			_recover_time = 0.0
			_struck = false
		State.FLEE:
			_flee_time = Balance.SCRUBBER_FLEE_TIME
			_target = null
			_patrol = _dark_retreat()
		State.LURK:
			_patrol_time = 0.0
			_target = null

	if Debug.log_ai:
		print("[AI] scrubber %d layer %d -> %s at %s" % [
			slot_index, layer_number, State.keys()[int(next)],
			str(global_position.snapped(Vector3.ONE * 0.1))])


# ------------------------------------------------------------------ movement --

func _act(delta: float) -> void:
	match state:
		State.LURK:
			_steer(_route_to(_patrol), Balance.SCRUBBER_LURK_SPEED * speed_scale, delta)
		State.STALK:
			var goal: Vector3 = _last_seen
			if _target != null and is_instance_valid(_target):
				goal = _target.global_position
			elif _alert_time > 0.0:
				goal = _alert_point
			_steer(_route_to(goal), Balance.SCRUBBER_STALK_SPEED * speed_scale, delta)
		State.LUNGE:
			_act_lunge(delta)
		State.FLEE:
			_steer(_route_to(_patrol), Balance.SCRUBBER_FLEE_SPEED * speed_scale, delta)


## The strike. A committed dash at where the player was when it launched — you
## can side-step a lunge, which is the only way an unarmed player survives a pack.
func _act_lunge(delta: float) -> void:
	if _recover_time > 0.0:
		_recover_time -= delta
		_steer(global_position, 0.0, delta)
		return

	_lunge_time -= delta
	_steer(_last_seen, Balance.SCRUBBER_LUNGE_SPEED * speed_scale, delta)

	if not _struck and _target != null and is_instance_valid(_target):
		var reach: float = _target.global_position.distance_to(global_position)
		if reach <= Balance.SCRUBBER_LUNGE_RANGE * 0.62:
			_struck = true
			Run.damage_player(int(String(_target.name)), Balance.SCRUBBER_LUNGE_DAMAGE,
					global_position)
	if _lunge_time <= 0.0:
		_recover_time = Balance.SCRUBBER_RECOVER_TIME


## A loitering point inside the nest room, or around the anchor if the room is
## unknown (a creature that fell out of the graph still has somewhere to be).
func _wander_point() -> Vector3:
	if graph != null and home_room >= 0:
		var centre: Vector3 = graph.centre_of(home_room)
		return centre + Vector3(_rng.randf_range(-5.0, 5.0), 0.0, _rng.randf_range(-5.0, 5.0))
	return home + Vector3(_rng.randf_range(-3.0, 3.0), 0.0, _rng.randf_range(-3.0, 3.0))


## Where to run when exposed: the nest, unless the nest is where the light is —
## then any other unlit room, furthest first.
func _dark_retreat() -> Vector3:
	if graph == null:
		return home
	var here: int = current_room()
	var best: Vector3 = home
	var best_distance: float = -1.0
	for index: int in graph.nest_rooms:
		if index == here:
			continue
		var centre: Vector3 = graph.centre_of(index)
		var distance: float = centre.distance_to(global_position)
		if distance > best_distance:
			best_distance = distance
			best = centre
	if best_distance < 0.0:
		# Only one nest and we are in it: cross to the far side of it.
		best = _wander_point()
	return best


# -------------------------------------------------------------------- events --

## A siphon tap went off nearby. DESIGN.md: tapping is loud, and this is what
## "loud" costs you.
func alert(where: Vector3) -> void:
	if graph == null:
		return
	if graph.room_distance(current_room(), graph.region_of(where)) > Balance.TAP_ALERT_ROOMS:
		return
	_alert_point = where
	_alert_time = Balance.TAP_ALERT_TIME
	if state == State.LURK:
		_enter(State.STALK)
	if Debug.log_ai:
		print("[AI] scrubber %d converging on tap at %s" % [
			slot_index, str(where.snapped(Vector3.ONE * 0.1))])


func _on_hurt() -> void:
	_hit()
	_tell_crew(&"_hit")
	# Being cut does not scare it off — only light does. It does make it commit:
	# a hurt Scrubber that was lurking now knows exactly where you are.
	if state == State.LURK:
		var prey: Node3D = _nearest_player(Balance.SCRUBBER_LOSE_RANGE, false)
		if prey != null:
			_target = prey
			_last_seen = prey.global_position
			_enter(State.STALK)


## Sent by `_tell_crew`, so the host runs its own copy directly rather than
## through the call.
@rpc("authority", "call_remote", "unreliable_ordered")
func _hit() -> void:
	_hurt_flash = 1.0


# --------------------------------------------------------------------- death --

## Slow shatter: the shell blows apart into red fragments, the sensor goes white
## and the light pulses once as the process is deallocated.
func _play_death() -> void:
	_death = 1.0
	set_physics_process(false)

	var burst: CPUParticles3D = CPUParticles3D.new()
	burst.name = "Shatter"
	burst.emitting = true
	burst.one_shot = true
	burst.amount = 34
	burst.lifetime = 0.85
	burst.explosiveness = 1.0
	burst.position = Vector3(0.0, BODY_HEIGHT, 0.0)
	burst.direction = Vector3.UP
	burst.spread = 180.0
	burst.initial_velocity_min = 1.6
	burst.initial_velocity_max = 5.2
	burst.gravity = Vector3(0.0, -7.0, 0.0)
	burst.scale_amount_min = 0.05
	burst.scale_amount_max = 0.16
	var fragment: BoxMesh = BoxMesh.new()
	fragment.size = Vector3.ONE
	burst.mesh = fragment
	burst.material_override = _emissive(SENSOR_COLOUR, 3.0)
	add_child(burst)


func _process(delta: float) -> void:
	if _death > 0.0:
		_die_visual(delta)
		return

	# Skitter, driven by however fast this copy is actually moving — so a client's
	# puppet legs move with the pose it receives, with no extra replication.
	var moved: float = Vector2(global_position.x - _last_position.x,
			global_position.z - _last_position.z).length() / maxf(delta, 0.0001)
	_last_position = global_position
	_skitter += delta * clampf(moved, 0.0, 10.0) * 2.4

	var bounce: float = absf(sin(_skitter)) * 0.06
	_shell.position.y = bounce
	_shell.rotation.z = sin(_skitter * 0.5) * 0.09
	for i: int in _legs.size():
		var phase: float = _skitter + float(i) * PI * 0.5
		_legs[i].rotation.x = sin(phase) * 0.55

	_hurt_flash = maxf(_hurt_flash - delta * 4.0, 0.0)
	_apply_state_visual()


## The sensor is the tell. Dim and slow while lurking, hot and steady while
## stalking, white on the lunge, stuttering while it runs.
func _apply_state_visual() -> void:
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var colour: Color = SENSOR_COLOUR
	var energy: float = 2.0
	var light: float = 1.0

	match int(sync_state):
		int(State.LURK):
			energy = 1.6 + sin(t * 1.6) * 0.5
			light = 0.45
		int(State.STALK):
			energy = 4.2 + sin(t * 6.0) * 0.8
			light = 0.9
		int(State.LUNGE):
			colour = Color(1.0, 0.62, 0.5)
			energy = 8.0
			light = 1.5
		int(State.FLEE):
			var stutter: float = 0.35 + 0.65 * absf(sin(t * 17.0))
			energy = 2.2 * stutter
			light = 0.5 * stutter

	if _hurt_flash > 0.0:
		colour = colour.lerp(Color(1.0, 0.95, 0.9), _hurt_flash)
		energy += _hurt_flash * 7.0
		light += _hurt_flash * 2.5

	_sensor_material.emission = colour
	_sensor_material.emission_energy_multiplier = energy
	_trim_material.emission_energy_multiplier = 0.35 + energy * 0.09
	_light.light_color = colour
	_light.light_energy = light


func _die_visual(delta: float) -> void:
	_death = maxf(_death - delta * 1.4, 0.0)
	var collapse: float = _death * _death
	_shell.scale = Vector3(collapse, collapse * 0.4, collapse)
	# One hard pulse of light as it goes, then nothing.
	_light.light_energy = 6.0 * sin(clampf(1.0 - _death, 0.0, 1.0) * PI) + collapse
	_sensor_material.emission_energy_multiplier = 9.0 * collapse
	if _death <= 0.001:
		queue_free()
