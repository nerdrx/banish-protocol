class_name Moth
extends Hunter
## The Moth — it sees light, any light, indiscriminately (HUNTER_DOSSIERS: "It
## checked the bulbs."). It is the exact inverse of the Scrubber: where a
## Scrubber breaks for the dark the moment your beam lands on it, a Moth turns
## and comes. So the two mechanics contradict each other on purpose — the light
## discipline that holds a pack off is the dinner bell that calls a Moth in, and
## a crew fighting one makes muzzle flash, which makes more Moth.
##
## DESIGN.md: "Drawn to beams, flares, muzzle flash ... Fragile-ish but fast;
## shooting it means muzzle light, which excites it — kill it quickly or go dark
## and hide." The counter is a real dilemma rather than a rule: you can delete it
## in three or four shots and eat the muzzle light while you do, or you can go
## fully dark — beam off, no flares, hold fire — and let it lose you.
##
## It does not stalk. It ARRIVES: it flies to the brightest thing it can sense and
## strikes whoever is holding it. Reach it with your beam off and there is nothing
## for it to come to.
##
## States (host only):
##   DRIFT   no light in range: slow hover, wandering the dark
##   SURGE   a light is in range: fly to it, fast
##   STRIKE  reached the holder of a live light: strike, brief cooldown

enum State { DRIFT, SURGE, STRIKE }

const HOVER_HEIGHT: float = 1.7
const EYE_COLOUR: Color = Color(1.0, 0.16, 0.12)
const SHELL_COLOUR: Color = Color(0.05, 0.05, 0.062)

var state: State = State.DRIFT

var _eye_material: StandardMaterial3D = null
var _trim_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _shell: Node3D = null
var _anim: AnimationPlayer = null
var _tree: AnimationTree = null

## Host sim.
var _light_pos: Vector3 = Vector3.ZERO
var _light_weight: float = 0.0
var _light_body: Node3D = null
var _strike_cooldown: float = 0.0
var _dark_time: float = 0.0
var _patrol: Vector3 = Vector3.ZERO
var _patrol_time: float = 0.0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

## Local.
var _death: float = 0.0
## The dilating iris: eased 0..1 by how much light it currently has.
var _iris: float = 0.0
var _wing: AudioStreamPlayer3D = null
var _audio_state: int = -1


func hunter_kind() -> StringName:
	return &"moth"


func _drop_shards() -> int:
	return Balance.MOTH_DROP_SHARDS


func _drop_pieces() -> int:
	return Balance.MOTH_DROP_PIECES


func _recompile_after_kill() -> float:
	return Balance.MOTH_RECOMPILE_TIME


func _eye_height() -> float:
	return HOVER_HEIGHT


func aim_point() -> Vector3:
	return global_position + Vector3.UP * 0.2


func _assemble() -> void:
	set_health(Balance.hunter_health(Balance.MOTH_HEALTH, layer_number))
	# Starts at hover height rather than on the anchor's floor.
	position = home + Vector3.UP * HOVER_HEIGHT
	sync_position = position

	var shape: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 0.9
	shape.shape = capsule
	add_child(shape)

	_shell = Node3D.new()
	_shell.name = "Shell"
	add_child(_shell)
	_build_model()

	# The eye IS the light it carries: a small red omni at the head that swells
	# with the iris. Kept feeble — it must not light the room it hunts in.
	_light = OmniLight3D.new()
	_light.name = "Eye"
	_light.position = Vector3(0.0, 0.1, -0.3)
	_light.light_color = EYE_COLOUR
	_light.light_energy = 0.6
	_light.omni_range = 2.4
	_light.omni_attenuation = 1.7
	_light.light_volumetric_fog_energy = 1.5
	_light.shadow_enabled = false
	_shell.add_child(_light)

	_rng.seed = hash(str(slot_index, ":moth:", layer_number))
	_patrol = home + Vector3.UP * HOVER_HEIGHT


func _build_model() -> void:
	var model: Node3D = CreatureKit.instantiate(CreatureKit.MOTH)
	if model == null:
		return
	model.name = "Model"
	_shell.add_child(model)

	_trim_material = CreatureKit.emissive(EYE_COLOUR, 0.5)
	_eye_material = CreatureKit.emissive(EYE_COLOUR, 2.6)
	CreatureKit.paint(CreatureKit.find_mesh(model), {
		"Body": CreatureKit.matte(SHELL_COLOUR, 0.5, 0.4),
		"Plate": CreatureKit.matte(CreatureKit.ENEMY_PLATE, 0.45, 0.34),
		"EmissRed": _trim_material,
		"CoreEmiss": _eye_material,
	})

	_anim = CreatureKit.find_player(model)
	CreatureKit.set_looping(_anim, PackedStringArray(["hover_idle", "attracted_surge"]))
	_tree = CreatureKit.build_tree(model, _anim, {
		"drift": "hover_idle",
		"surge": "attracted_surge",
		"strike": "strike",
		"death": "death_collapse",
	}, "drift", 0.14)


# ---------------------------------------------------------------- decisions --

func _think() -> void:
	var tick: float = Balance.AI_TICK
	if _strike_cooldown > 0.0:
		_strike_cooldown -= tick

	# Sense the brightest thing in range, every tick. This is its only input.
	var light: Dictionary = _brightest_light(Balance.MOTH_LIGHT_RANGE)
	if bool(light["valid"]):
		_light_pos = light["pos"]
		_light_weight = float(light["weight"])
		_light_body = light["body"]
		_dark_time = 0.0
	else:
		_light_weight = 0.0
		_light_body = null
		_dark_time += tick

	match state:
		State.DRIFT:
			if _light_weight > 0.0:
				_enter(State.SURGE)
			elif _dark_time >= Balance.MOTH_DARK_GIVEUP_TIME:
				# Nothing to come to for long enough: it gives up the layer. Going
				# dark genuinely loses a Moth.
				slink_away()
			else:
				_patrol_time -= tick
				if _patrol_time <= 0.0 or global_position.distance_to(_patrol) < 2.0:
					_patrol_time = _rng.randf_range(2.0, 4.0)
					_patrol = _wander_point()
		State.SURGE:
			if _light_weight <= 0.0:
				_enter(State.DRIFT)
				return
			# Reached the holder of a live light: strike it.
			if _light_body != null and is_instance_valid(_light_body) \
					and _strike_cooldown <= 0.0 \
					and _light_body.global_position.distance_to(global_position) \
						<= Balance.MOTH_STRIKE_RANGE:
				_enter(State.STRIKE)
		State.STRIKE:
			pass  # `_act` runs the strike, then hands back to SURGE.


func _enter(next: State) -> void:
	if state == next:
		return
	state = next
	sync_state = int(next)
	if Debug.log_ai:
		print("[AI] moth %d layer %d -> %s light=%.2f at %s" % [
			slot_index, layer_number, State.keys()[int(next)], _light_weight,
			str(global_position.snapped(Vector3.ONE * 0.1))])


# ------------------------------------------------------------------ movement --

func _act(delta: float) -> void:
	match state:
		State.DRIFT:
			_hover_to(_route_to_air(_patrol), Balance.MOTH_DRIFT_SPEED, delta)
		State.SURGE:
			_hover_to(_route_to_air(_light_pos), Balance.MOTH_SURGE_SPEED, delta)
		State.STRIKE:
			_hover_to(global_position, 0.0, delta)
			_do_strike()
			_enter(State.SURGE)
	# `sync_position`/`sync_yaw` are written by Antivirus._physics_process right
	# after `_act` returns (host only), so this override does not repeat them.


## A room-graph waypoint at hover height — the Moth paths between rooms like
## anything else, it just does it in the air.
func _route_to_air(target: Vector3) -> Vector3:
	var flat: Vector3 = _route_to(Vector3(target.x, 0.0, target.z))
	return Vector3(flat.x, maxf(target.y, HOVER_HEIGHT), flat.z)


## Frictionless hover: seek the target in the plane and ease toward hover height.
## No gravity — a Moth does not fall — but it keeps its collider so the breaker's
## line of sight and hitscan treat it like anything else (killability).
func _hover_to(target: Vector3, speed: float, delta: float) -> void:
	var to_target: Vector3 = target - global_position
	var planar: Vector3 = Vector3(to_target.x, 0.0, to_target.z)
	var wish: Vector3 = Vector3.ZERO
	if planar.length_squared() > 0.04:
		wish = planar.normalized()
	var desired: Vector3 = wish * speed
	var current: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	current = current.move_toward(desired, speed * 6.0 * delta + 0.1)
	velocity.x = current.x
	velocity.z = current.z
	# Seek hover height, plus a gentle bob so it never reads as pinned to a rail.
	var want_y: float = target.y if target.y > 0.5 else HOVER_HEIGHT
	want_y += sin(float(Time.get_ticks_msec()) * 0.004 + float(slot_index)) * 0.18
	velocity.y = (want_y - global_position.y) * 3.5
	move_and_slide()
	_face(wish, delta)


func _do_strike() -> void:
	if _light_body == null or not is_instance_valid(_light_body):
		return
	if _light_body.global_position.distance_to(global_position) > Balance.MOTH_STRIKE_RANGE:
		return
	_strike_cooldown = Balance.MOTH_STRIKE_COOLDOWN
	Run.damage_player(int(String(_light_body.name)), Balance.MOTH_STRIKE_DAMAGE,
			global_position)
	_tell_crew(&"_strike_fx")


func _wander_point() -> Vector3:
	var base: Vector3 = home
	if graph != null and home_room >= 0:
		base = graph.centre_of(home_room)
	return base + Vector3(_rng.randf_range(-5.0, 5.0), HOVER_HEIGHT,
			_rng.randf_range(-5.0, 5.0))


# --- light sensing ----------------------------------------------------------

## The brightest light the Moth can sense within `range_limit`: burning flares,
## active player beams, and the muzzle flash of recent breaker fire (tracked by
## the Director). Returns {valid, pos, weight, body}; `body` is the player holding
## a beam/muzzle (so the Moth can strike them) or null for a flare.
func _brightest_light(range_limit: float) -> Dictionary:
	var best_weight: float = 0.0
	var best_pos: Vector3 = Vector3.ZERO
	var best_body: Node3D = null

	# Burning flares: a bright point in the world. No body to strike — it just
	# circles the flare, denying the crew the safety they threw it for.
	for node: Node in get_tree().get_nodes_in_group("flares"):
		var flare: Flare = node as Flare
		if flare == null or not is_instance_valid(flare) or not flare.is_burning():
			continue
		var d: float = flare.global_position.distance_to(global_position)
		if d > range_limit:
			continue
		var w: float = 1.4 * clampf(1.0 - d / range_limit, 0.0, 1.0)
		if w > best_weight:
			best_weight = w
			best_pos = flare.global_position + Vector3.UP * 0.4
			best_body = null

	# Active player beams + muzzle flash. A beam that is ON is a light the Moth
	# comes to; a recent shot is a muzzle flash it comes to even in the dark. The
	# base's `_running_players()` already yields the living, non-sanctuary crew.
	for body: Node3D in _running_players():
		var player: Player = body as Player
		if player == null:
			continue
		var eye: Vector3 = player.global_position + Vector3.UP * PLAYER_EYE
		var d: float = eye.distance_to(global_position)
		if d > range_limit:
			continue
		var lit: float = maxf(1.0 if player.sync_beam else 0.0,
				Haunt.muzzle_light(int(String(player.name))))
		if lit <= 0.0:
			continue
		var w: float = lit * clampf(1.0 - d / range_limit, 0.0, 1.0)
		if w > best_weight:
			best_weight = w
			best_pos = eye
			best_body = player

	return {"valid": best_weight > 0.0, "pos": best_pos, "weight": best_weight,
			"body": best_body}


# -------------------------------------------------------------------- events --

func _on_hurt() -> void:
	_hit()
	_tell_crew(&"_hit")


@rpc("authority", "call_remote", "unreliable_ordered")
func _hit() -> void:
	trigger_hurt_flash()
	Audio.play_3d(&"scrubber_hurt", global_position)


@rpc("authority", "call_remote", "unreliable_ordered")
func _strike_fx() -> void:
	trigger_hurt_flash()
	Audio.play_3d(&"scrubber_lunge", global_position)


# --------------------------------------------------------------------- death --

func _play_death() -> void:
	_death = 1.0
	set_physics_process(false)
	if _wing != null:
		Audio.detach_loop(_wing)
		_wing = null
	Audio.play_3d(&"scrubber_death", global_position)
	CreatureKit.travel(_tree, "death")
	CreatureKit.set_speed(_tree, 1.0)

	var burst: CPUParticles3D = CPUParticles3D.new()
	burst.name = "Ash"
	burst.emitting = true
	burst.one_shot = true
	burst.amount = 30
	burst.lifetime = 1.1
	burst.explosiveness = 1.0
	burst.direction = Vector3.DOWN
	burst.spread = 150.0
	burst.initial_velocity_min = 0.8
	burst.initial_velocity_max = 3.0
	burst.gravity = Vector3(0.0, -3.5, 0.0)
	burst.scale_amount_min = 0.03
	burst.scale_amount_max = 0.1
	var fragment: BoxMesh = BoxMesh.new()
	fragment.size = Vector3.ONE
	var shard: StandardMaterial3D = CreatureKit.matte(SHELL_COLOUR.lightened(0.05), 0.4, 0.6)
	shard.emission_enabled = true
	shard.emission = EYE_COLOUR
	shard.emission_energy_multiplier = 0.5
	fragment.material = shard
	burst.mesh = fragment
	add_child(burst)


func _process(delta: float) -> void:
	if _death > 0.0:
		_die_visual(delta)
		return
	_drive_animation()
	decay_hurt_flash(delta, 4.0)
	_apply_state_visual(delta)
	_update_audio()


func _drive_animation() -> void:
	match int(sync_state):
		int(State.SURGE):
			CreatureKit.travel(_tree, "surge")
			CreatureKit.set_speed(_tree, 1.0)
		int(State.STRIKE):
			CreatureKit.travel(_tree, "strike")
			CreatureKit.set_speed(_tree, 1.0)
		_:
			CreatureKit.travel(_tree, "drift")
			CreatureKit.set_speed(_tree, 1.0)


## The aperture-eye tell: the iris dilates (the eye swells and brightens) as it
## gains your light and closes when it loses it, so "it has your light" is
## something you can read off the creature, not just infer from its heading.
func _apply_state_visual(delta: float) -> void:
	if _eye_material == null or _trim_material == null:
		return
	var target_iris: float = 0.0
	match int(sync_state):
		int(State.SURGE), int(State.STRIKE):
			target_iris = 1.0
		_:
			# In DRIFT the iris tracks any faint light it senses, so it visibly
			# perks up the instant a beam clicks on across the room.
			target_iris = clampf(_light_weight, 0.0, 0.6)
	_iris = lerpf(_iris, target_iris, 1.0 - exp(-6.0 * delta))

	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var energy: float = 1.4 + _iris * 6.0 + sin(t * 3.0) * 0.3 * _iris
	var flash: float = hurt_flash()
	if flash > 0.0:
		energy += flash * 7.0
	_eye_material.emission_energy_multiplier = energy
	# The iris also scales the eye so it literally dilates.
	_eye_material.emission = EYE_COLOUR.lerp(Color(1.0, 0.5, 0.4), flash)
	_trim_material.emission_energy_multiplier = 0.4 + _iris * 1.2
	_light.light_energy = 0.5 + _iris * 1.6
	_light.omni_range = 2.0 + _iris * 1.6


func _update_audio() -> void:
	var s: int = int(sync_state)
	if s != _audio_state:
		var want_wing: bool = s == int(State.SURGE) or s == int(State.STRIKE)
		if want_wing and _wing == null:
			_wing = Audio.attach_loop(&"scrubber_skitter", self)
		elif not want_wing and _wing != null:
			Audio.detach_loop(_wing)
			_wing = null
		if s == int(State.SURGE) and _audio_state == int(State.DRIFT):
			Audio.play_3d(&"scrubber_alert", global_position)
			Captions.emit(&"moth_surge", global_position, 30.0)
		_audio_state = s


func _die_visual(delta: float) -> void:
	_death = maxf(_death - delta * 1.1, 0.0)
	var fade: float = _death * _death
	# It loses lift as it dies: sinks toward the floor while it comes apart.
	global_position.y = maxf(global_position.y - delta * (1.0 - _death) * 3.0, 0.2)
	if _eye_material != null:
		_eye_material.emission_energy_multiplier = 8.0 * fade
	if _trim_material != null:
		_trim_material.emission_energy_multiplier = 1.2 * fade
	_light.light_energy = 3.0 * fade
	if _death <= 0.001:
		queue_free()
