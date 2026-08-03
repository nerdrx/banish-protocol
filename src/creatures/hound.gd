class_name Hound
extends Hunter
## The Hound — it hears, and only hears (HUNTER_DOSSIERS: "HEARING. EXCELLENT.
## THE ONLY ONE IT HAS."). Spawned by noise debt, it runs the crew down through
## the room graph and does not tire. DESIGN.md: "Relentless pursuit; at low HP it
## flees to darkness to recompile."
##
## The whole creature is one argument with the noise floor. Every siphon, every
## burst of breaker fire, every sprinted corridor feeds NoiseBus.debt, and when
## the debt is high enough the Director vectors a Hound at the loudest thing on
## the layer. Once it is on you, going quiet is the only thing that shakes it —
## you cannot out-loud a Hound, you can only stop being the loudest room.
##
## States (host only):
##   PROWL  no scent: drift toward the last noise, or patrol the dark
##   CHASE  a running player is within hearing: close through the room graph
##   LUNGE  inside reach: commit a dash and strike, then recover
##   FLEE   below FLEE_FRACTION health: break for the dark to recompile
##
## The FLEE state is the wounded-animal window the design turns into a choice.
## A hurt Hound runs for an unlit room; reach one and survive a few seconds
## unexposed and it "recompiles" — slinks off with no reward (`slink_away`). Chase
## it down inside the window and it dies like anything else, spilling a large data
## burst and buying the layer real silence. Either way the process comes back —
## the Director recompiles it minutes later and its HOWL announces the restart.

enum State { PROWL, CHASE, LUNGE, FLEE }

const BODY_HEIGHT: float = 0.95
const SENSOR_COLOUR: Color = Color(1.0, 0.13, 0.11)
const SHELL_COLOUR: Color = Color(0.045, 0.045, 0.055)

## Metres the chase clip carries the body per loop, for foot-planting (as Scrubber).
const CHASE_STRIDE: float = 2.4
const CHASE_RATE_RANGE: Vector2 = Vector2(0.6, 2.2)

var state: State = State.PROWL

var _sensor_material: StandardMaterial3D = null
var _trim_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _shell: Node3D = null
var _anim: AnimationPlayer = null
var _tree: AnimationTree = null

var _target: Node3D = null
var _last_seen: Vector3 = Vector3.ZERO
var _alert_point: Vector3 = Vector3.ZERO
var _alert_time: float = 0.0
var _lunge_time: float = 0.0
var _recover_time: float = 0.0
var _struck: bool = false
## FLEE bookkeeping: seconds spent unexposed in the dark toward the escape.
var _escape: float = 0.0
var _patrol: Vector3 = Vector3.ZERO
var _patrol_time: float = 0.0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

## Local animation, driven per-peer off the pose it can see.
var _last_position: Vector3 = Vector3.ZERO
var _measured_speed: float = 0.0
var _death: float = 0.0
var _ember: OmniLight3D = null

## M5 audio, per-peer off the replicated `sync_state`.
var _run_loop: AudioStreamPlayer3D = null
var _audio_state: int = -1
var _howled: bool = false


func hunter_kind() -> StringName:
	return &"hound"


func _drop_shards() -> int:
	return Balance.HOUND_DROP_SHARDS


func _drop_pieces() -> int:
	return Balance.HOUND_DROP_PIECES


func _recompile_after_kill() -> float:
	return Balance.HOUND_RECOMPILE_TIME


func _eye_height() -> float:
	return BODY_HEIGHT * 0.6


# =============================================== M11 doctrine: THE TRACKER ===
#
# The Hound's identity is that it follows a TRAIL. Before M11 "it hears" meant
# `_nearest_player(30 m, require_los=false)` — an omniscient radius that made the
# creature simultaneously unfair (it knew where you were through a slab) and
# stupid (it walked straight at you, so once you learned that, it was solved).
#
# Now: nearly blind, excellent ears, and — the doctrine proper — when it loses
# you it does not go to the last-known position and give up. It walks the crew's
# NOISE HISTORY, newest first, through `NoiseBus.recent`. Every siphon you tapped,
# every burst of breaker fire, every hard landing is a place it will go and check,
# in order. That is what "relentless, will not be shaken by distance alone" is
# supposed to feel like, and it is why going quiet — not going far — is the
# counter. You cannot out-run a Hound. You can stop being the loudest room.

func ai_kind() -> String:
	return "hound"


## Poor eyes. THE dossier fact ("HEARING. EXCELLENT. THE ONLY ONE IT HAS.") given
## teeth: at nine metres and forty-five degrees it will walk past an unlit
## crewmate standing still, and still arrive at the noise they made a minute ago.
func sight_range() -> float:
	return Balance.AI_SIGHT_HOUND


func sight_cone_deg() -> float:
	return Balance.AI_CONE_HOUND


func hearing_rooms() -> int:
	return Balance.AI_HEAR_ROOMS_HOUND


# ------------------------------- M11b: THE CHARGE and THE SUMMONING HOWL ----
#
# Two moves, and they are the same doctrine at two ranges.
#
# THE CHARGE closes distance. A corridor stops being an escape route: from up to
# seventeen metres it plants, growls, and runs you down in a straight committed
# line at more than twice a sprint. Counter: it runs at where you WERE when it
# launched, so it is side-steppable — the exact skill a Scrubber lunge already
# taught, at a longer range and a higher price for missing it. Miss and it
# overshoots into a real recovery window, which is the crew's opening and the
# solo player's second chance.
#
# THE HOWL is the diegetic half. It was already the Hound's spawn announce; M11b
# makes it a genuine SUMMONING ACT by putting it on the NoiseBus at four rooms of
# reach — further than anything else in the game. So a Hound that finds you calls
# the ring down on you, and every process that arrives arrived because it HEARD
# something, exactly like the Scrubber screech. The player hears it too, and a
# player who has learned what it means knows to move before the rest get there.

var _charge_windup: float = 0.0
var _charge_time: float = 0.0
var _charge_cooldown: float = 0.0
var _charge_at: Vector3 = Vector3.ZERO
var _charge_struck: bool = false
var _howl_cooldown: float = 0.0
## Streamed: 0..1 through the wind-up, so the tell lands on every screen at once.
var sync_charge: float = 0.0


func _extra_sync_properties() -> Array[String]:
	var out: Array[String] = super()
	out.append(".:sync_charge")
	return out


func charging() -> bool:
	return _charge_windup > 0.0 or _charge_time > 0.0


## Host-side, considered before the ordinary state machine.
func _consider_charge(tick: float) -> void:
	_charge_cooldown = maxf(_charge_cooldown - tick, 0.0)
	_howl_cooldown = maxf(_howl_cooldown - tick, 0.0)

	if _charge_windup > 0.0:
		_charge_windup -= tick
		sync_charge = clampf(1.0 - _charge_windup / Balance.AI_CHARGE_WINDUP, 0.0, 1.0)
		if _charge_windup <= 0.0:
			_charge_time = Balance.AI_CHARGE_TIME
			_charge_struck = false
			sync_charge = 1.0
		return
	if _charge_time > 0.0:
		return
	if _charge_cooldown > 0.0 or state != State.CHASE:
		return
	var prey: Node3D = hunted_body()
	if prey == null or not _has_los(prey):
		return
	var gap: float = prey.global_position.distance_to(global_position)
	if gap < Balance.AI_CHARGE_MIN_RANGE or gap > Balance.AI_CHARGE_MAX_RANGE:
		return
	_charge_windup = Balance.AI_CHARGE_WINDUP
	_charge_cooldown = Balance.AI_CHARGE_COOLDOWN
	sync_charge = 0.0
	# It commits to WHERE YOU ARE NOW. Everything after this is a straight line to
	# a point on the floor, which is the whole of why side-stepping works.
	_charge_at = prey.global_position
	Audio.play_3d(&"hound_howl", global_position)
	Captions.emit(&"hunter_charge", global_position, 32.0)
	_tell_crew(&"_charge_windup_fx")


## The run itself. Host-side, per physics frame, from `_act`.
func _act_charge(delta: float) -> void:
	if _charge_windup > 0.0:
		# Planted and growling: the telegraph is that it STOPPED.
		_steer(global_position, 0.0, delta)
		_face((_charge_at - global_position).normalized(), delta)
		return
	_charge_time -= delta
	_steer(_charge_at, Balance.AI_CHARGE_SPEED * speed_scale, delta)
	if not _charge_struck:
		for body: Node3D in _running_players():
			if body.global_position.distance_to(global_position) > Balance.HOUND_LUNGE_RANGE:
				continue
			_charge_struck = true
			# Through the one door, so forks, surge-step i-frames, barriers and hot
			# patches all answer this exactly as they answer a lunge.
			_land_hit(body, Balance.AI_CHARGE_DAMAGE)
			break
	if _charge_time <= 0.0:
		sync_charge = 0.0
		# The overshoot. Missing costs it a second and a half of standing still,
		# which is the opening the move is priced against.
		_recover_time = Balance.AI_CHARGE_RECOVER
		_enter(State.CHASE)


@rpc("authority", "call_remote", "unreliable_ordered")
func _charge_windup_fx() -> void:
	Audio.play_3d(&"hound_howl", global_position)
	Captions.emit(&"hunter_charge", global_position, 32.0)


## THE SUMMONING. A real NoiseBus event at a real position — the same bus a
## kicked can rides — so anything that converges did so because it heard this.
## Rate-limited hard: a permanent siren would make the pack's arrival meaningless
## and would take the tactic of killing the caller away from the crew.
func _summon() -> void:
	if not _is_host or _howl_cooldown > 0.0:
		return
	_howl_cooldown = Balance.AI_HOWL_COOLDOWN
	Audio.play_3d(&"hound_howl", global_position)
	Captions.emit(&"hound_summon", global_position, 44.0)
	NoiseBus.ping(global_position, Balance.AI_HOWL_ROOMS, "hound_howl",
			Balance.AI_HOWL_HOLD, 1.0, self)


func _on_suspicion(_from: int, to: int) -> void:
	if to == Suspicion.State.HUNTING:
		_summon()


func _telegraph_sound(state: int) -> StringName:
	match state:
		Suspicion.State.HUNTING:
			# `_summon` carries this one, and carries it further.
			return &""
		Suspicion.State.ALERT, Suspicion.State.LOST:
			return &"scrubber_skitter"
		Suspicion.State.CURIOUS:
			return &"scrubber_chitter"
		_:
			return &""


## THE TRAIL. The base's candidates (the last-known position, the decks, the
## ledges, the ways out) with the crew's own recent noise prepended, so a Hound
## that lost you re-walks where you have been loud rather than orbiting one spot.
##
## Bounded to `AI_HOUND_TRAIL` events, and every event is still filtered by
## `HuntMemory.next_search_spot`'s radius test against the last-known position —
## so it is a trail it can plausibly believe in, not a list of every noise on the
## layer. Noise this creature never heard is not in `NoiseBus.recent`'s reach test
## either; a trail is made of things it actually perceived.
func _search_candidates(kinds: Array[String]) -> Array[Vector3]:
	var spots: Array[Vector3] = []
	for event: Dictionary in NoiseBus.recent(Balance.AI_HOUND_TRAIL):
		if event.get("emitter", null) == self:
			continue
		spots.append(event["where"])
		kinds.append("trail")
	spots.append_array(super(kinds))
	return spots


func aim_point() -> Vector3:
	return global_position + Vector3.UP * (BODY_HEIGHT * 0.55)


func _assemble() -> void:
	set_health(Balance.hunter_health(Balance.HOUND_HEALTH, layer_number))

	var shape: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.44
	capsule.height = 1.3
	shape.shape = capsule
	shape.position = Vector3(0.0, 0.65, 0.0)
	add_child(shape)

	_shell = Node3D.new()
	_shell.name = "Shell"
	add_child(_shell)
	_build_model()

	# A feeble red sensor at the head, findable in the dark but never a lamp —
	# pillar 2 holds for a hunter as hard as for a Scrubber.
	_light = OmniLight3D.new()
	_light.name = "Sensor"
	_light.position = Vector3(0.0, BODY_HEIGHT, -0.5)
	_light.light_color = SENSOR_COLOUR
	_light.light_energy = 0.9
	_light.omni_range = 3.0
	_light.omni_attenuation = 1.5
	_light.light_volumetric_fog_energy = 1.7
	_light.shadow_enabled = false
	_shell.add_child(_light)

	_rng.seed = hash(str(slot_index, ":hound:", layer_number))
	_patrol = home
	_last_position = position


func _build_model() -> void:
	var model: Node3D = CreatureKit.instantiate(CreatureKit.HOUND)
	if model == null:
		return
	model.name = "Model"
	_shell.add_child(model)

	_trim_material = CreatureKit.emissive(SENSOR_COLOUR, 0.55)
	_sensor_material = CreatureKit.emissive(SENSOR_COLOUR, 3.2)
	CreatureKit.paint(CreatureKit.find_mesh(model), {
		"Body": CreatureKit.matte(SHELL_COLOUR, 0.6, 0.44),
		"Plate": CreatureKit.matte(CreatureKit.ENEMY_PLATE, 0.5, 0.34),
		"EmissRed": _trim_material,
		"CoreEmiss": _sensor_material,
	})

	_anim = CreatureKit.find_player(model)
	CreatureKit.set_looping(_anim, PackedStringArray(
			["idle", "prowl", "chase_run", "flee_wounded"]))
	_tree = CreatureKit.build_tree(model, _anim, {
		"idle": "idle",
		"prowl": "prowl",
		"chase": "chase_run",
		"lunge": "lunge_strike",
		"flee": "flee_wounded",
		"howl": "howl",
		"death": "death_collapse",
	}, "prowl", 0.16)

	var skeleton: Skeleton3D = CreatureKit.find_skeleton(model)
	if skeleton != null:
		CreatureKit.build_spring_tail(skeleton, 22.0, 0.8)


# ---------------------------------------------------------------- decisions --

func _think() -> void:
	var tick: float = Balance.AI_TICK
	if _alert_time > 0.0:
		_alert_time -= tick

	# The wound check runs in every state: a Hound cut below the line breaks off
	# whatever it was doing and runs, which is what opens the window.
	if state != State.FLEE and health <= _flee_line():
		_charge_windup = 0.0
		_charge_time = 0.0
		sync_charge = 0.0
		_enter(State.FLEE)
		return

	# M11b: the CHARGE owns the creature while it runs. Considered before the
	# ordinary machine so a committed run is never re-decided mid-flight — that
	# commitment is what makes side-stepping it work.
	_consider_charge(tick)
	if charging():
		return

	match state:
		State.PROWL:
			_think_prowl()
		State.CHASE:
			_think_chase()
		State.LUNGE:
			_think_lunge()
		State.FLEE:
			_think_flee(tick)


func _flee_line() -> float:
	return Balance.hunter_health(Balance.HOUND_HEALTH, layer_number) \
			* Balance.HOUND_FLEE_FRACTION


func _think_prowl() -> void:
	# CHASE is now a claim about belief rather than about distance: it goes when
	# the ladder says ALERT or better, which it can only reach through evidence
	# it actually sensed.
	if suspicion >= Suspicion.State.ALERT:
		_enter(State.CHASE)
		return
	if _alert_time > 0.0:
		if global_position.distance_to(_alert_point) < 3.0:
			_alert_time = 0.0
		return
	if suspicion == Suspicion.State.CURIOUS:
		var look: Vector3 = hunt_goal()
		if look != Vector3.INF:
			_patrol = look
			return
	_patrol_time -= Balance.AI_TICK
	if _patrol_time <= 0.0 or global_position.distance_to(_patrol) < 2.0:
		_patrol_time = _rng.randf_range(2.5, 5.0)
		# With nothing to go on it drifts toward the region the Director is
		# pressing on, or the warmest room it remembers. A ZONE — never a player.
		var pressed: Vector3 = drift_target()
		_patrol = pressed if pressed != Vector3.INF else _wander_point()


func _think_chase() -> void:
	var prey: Node3D = hunted_body()
	if prey != null:
		_target = prey
		_last_seen = prey.global_position
		if prey.global_position.distance_to(global_position) <= Balance.HOUND_LUNGE_RANGE \
				and _has_los(prey):
			_enter(State.LUNGE)
		return
	_target = null
	# THE TRACKER, in one branch: it does NOT go back to prowling because it can
	# no longer sense you. It stays in CHASE for as long as the ladder holds it in
	# LOST, working down the noise trail and the plausible places, and only drops
	# out when the belief itself has decayed.
	if suspicion == Suspicion.State.UNAWARE and _alert_time <= 0.0:
		_enter(State.PROWL)


func _think_lunge() -> void:
	if _recover_time > 0.0 or _lunge_time > 0.0:
		return
	var prey: Node3D = hunted_body()
	if prey == null:
		_enter(State.CHASE if suspicion != Suspicion.State.UNAWARE else State.PROWL)
		return
	_target = prey
	_last_seen = prey.global_position
	_enter(State.CHASE)


func _think_flee(tick: float) -> void:
	# Exposed to a beam or a flare, or with a player right on top of it, resets the
	# escape: the crew is still finishing the job, so it has not got away yet.
	var hunter_here: Node3D = _nearest_player(Balance.HOUND_LUNGE_RANGE + 2.0, false)
	if _in_player_light() or hunter_here != null:
		_escape = 0.0
	elif current_room() in _dark_rooms():
		_escape += tick
	else:
		_escape = maxf(_escape - tick, 0.0)

	if _escape >= Balance.HOUND_FLEE_ESCAPE_TIME:
		# It got away. Slink off to recompile — no reward, a shorter timer.
		slink_away()


func _enter(next: State) -> void:
	if state == next:
		return
	state = next
	sync_state = int(next)
	match next:
		State.LUNGE:
			_lunge_time = Balance.HOUND_LUNGE_TIME
			_recover_time = 0.0
			_struck = false
		State.FLEE:
			_escape = 0.0
			_target = null
			_patrol = _dark_retreat()
		State.PROWL:
			_patrol_time = 0.0
			_target = null
	if Debug.log_ai:
		print("[AI] hound %d layer %d -> %s hp=%.0f at %s" % [
			slot_index, layer_number, State.keys()[int(next)], health,
			str(global_position.snapped(Vector3.ONE * 0.1))])


# ------------------------------------------------------------------ movement --

func _act(delta: float) -> void:
	if charging():
		_act_charge(delta)
		return
	match state:
		State.PROWL:
			var goal: Vector3 = _alert_point if _alert_time > 0.0 else _patrol
			_steer(_route_to(goal), Balance.HOUND_PROWL_SPEED * speed_scale, delta)
		State.CHASE:
			# M11: the goal is the mind's — the body while contact holds, the trail
			# and the search when it does not. The speed rides the rung, so a Hound
			# that has lost you visibly slows to a searching pace: the player can
			# see, from across a room, that it does not know where they are.
			var chase_goal: Vector3 = hunt_goal()
			if chase_goal == Vector3.INF:
				chase_goal = _alert_point if _alert_time > 0.0 else _last_seen
			_steer(_route_to(chase_goal),
					Balance.HOUND_CHASE_SPEED * speed_scale * suspicion_speed(), delta)
		State.LUNGE:
			_act_lunge(delta)
		State.FLEE:
			_steer(_route_to(_patrol), Balance.HOUND_FLEE_SPEED * speed_scale, delta)


func _act_lunge(delta: float) -> void:
	if _recover_time > 0.0:
		_recover_time -= delta
		_steer(global_position, 0.0, delta)
		return
	_lunge_time -= delta
	_steer(_last_seen, Balance.HOUND_LUNGE_SPEED * speed_scale, delta)
	if not _struck and _target != null and is_instance_valid(_target):
		if _target.global_position.distance_to(global_position) <= Balance.HOUND_LUNGE_RANGE * 0.7:
			_struck = true
			# M7: through the one door — see `Antivirus._land_hit`. A Hound that
			# lunges at a fork bites a fork, and one that lunges at a dashing agent
			# misses. It learns nothing either way.
			_land_hit(_target, Balance.HOUND_LUNGE_DAMAGE)
	if _lunge_time <= 0.0:
		_recover_time = Balance.HOUND_RECOVER_TIME


func _wander_point() -> Vector3:
	if graph != null and home_room >= 0:
		var centre: Vector3 = graph.centre_of(home_room)
		return centre + Vector3(_rng.randf_range(-5.0, 5.0), 0.0, _rng.randf_range(-5.0, 5.0))
	return home + Vector3(_rng.randf_range(-3.0, 3.0), 0.0, _rng.randf_range(-3.0, 3.0))


## The dark rooms (unlit nests) a wounded Hound runs for. Never the sanctuary.
func _dark_rooms() -> Array[int]:
	if graph == null:
		return [] as Array[int]
	return graph.nest_rooms


func _dark_retreat() -> Vector3:
	if graph == null:
		return home
	var here: int = current_room()
	var best: Vector3 = home
	var best_distance: float = -1.0
	for index: int in graph.nest_rooms:
		if index == here:
			continue
		if graph.is_backdoor and index == graph.shaft_index:
			continue
		var centre: Vector3 = graph.centre_of(index)
		var distance: float = centre.distance_to(global_position)
		if distance > best_distance:
			best_distance = distance
			best = centre
	if best_distance < 0.0:
		best = _wander_point()
	return best


# -------------------------------------------------------------------- events --

## Something loud. This is the Hound's ONE sense: a noise within reach pulls it.
## The Director routes noise debt here through the same NoiseBus fan-out the
## Scrubbers ride, so the crew's own siphons and breaker fire are what feed it.
func alert(where: Vector3, rooms: int = Balance.TAP_ALERT_ROOMS,
		seconds: float = Balance.HOUND_NOISE_HOLD) -> void:
	if graph == null:
		return
	if graph.room_distance(current_room(), graph.region_of(where)) > rooms + 1:
		return
	_alert_point = where
	if seconds < _alert_time:
		return
	_alert_time = seconds
	# M11 removed the omniscient half of this. It used to answer a noise by asking
	# `_nearest_player(44 m, require_los=false)` and CHASING whoever that returned
	# — which is how a creature that "only hears" ended up knowing your exact
	# position through two slabs. The hearing itself is now graded and lives in
	# `Antivirus.hear`, which fed the awareness track and the last-known position
	# before this ever ran; all that is left here is the M6 attention hold, which
	# is what keeps the Hound pointed at the noise while it closes.
	#
	# The behavioural difference is the whole milestone: it comes to the SOUND, and
	# then it has to find you.
	if state == State.PROWL and suspicion >= Suspicion.State.ALERT:
		_enter(State.CHASE)


## M7 STACK PULSE. The lunge is cancelled the same way a Scrubber's is. Note what
## is NOT here: the Hound does not learn, does not remember the pulse and does not
## adapt to it. It is a hunter that hears; being shoved teaches it nothing.
func _on_staggered() -> void:
	# M11b: a STACK PULSE cancels a charge exactly as it cancels a lunge, wind-up
	# or run. That is the crew's answer to the move and it must not be special-
	# cased away — a committed heavy attack that a stagger could not interrupt
	# would make the subroutine a lie.
	if charging():
		_charge_windup = 0.0
		_charge_time = 0.0
		sync_charge = 0.0
		_recover_time = Balance.AI_CHARGE_RECOVER
		_enter(State.CHASE)
		return
	if state == State.LUNGE:
		_struck = true
		_lunge_time = 0.0
		_recover_time = Balance.HOUND_RECOVER_TIME
		_enter(State.CHASE)


func _on_hurt() -> void:
	_hit()
	_tell_crew(&"_hit")


@rpc("authority", "call_remote", "unreliable_ordered")
func _hit() -> void:
	trigger_hurt_flash()
	Audio.play_3d(&"scrubber_hurt", global_position)


# --------------------------------------------------------------------- death --

func _play_death() -> void:
	_death = 1.0
	set_physics_process(false)
	if _run_loop != null:
		Audio.detach_loop(_run_loop)
		_run_loop = null
	Audio.play_3d(&"scrubber_death", global_position)
	# M7 THE DECOMPILE SHATTER — see Scrubber._play_death for the argument.
	Fx.decompile(global_position, SENSOR_COLOUR, false, BODY_HEIGHT * 0.8)
	CreatureKit.travel(_tree, "death")
	CreatureKit.set_speed(_tree, 1.0)

	var burst: CPUParticles3D = CPUParticles3D.new()
	burst.name = "Collapse"
	burst.emitting = true
	burst.one_shot = true
	burst.amount = 46
	burst.lifetime = 1.0
	burst.explosiveness = 1.0
	burst.position = Vector3(0.0, BODY_HEIGHT * 0.6, 0.0)
	burst.direction = Vector3.UP
	burst.spread = 180.0
	burst.initial_velocity_min = 1.8
	burst.initial_velocity_max = 5.8
	burst.gravity = Vector3(0.0, -7.5, 0.0)
	burst.scale_amount_min = 0.06
	burst.scale_amount_max = 0.2
	burst.angular_velocity_min = -520.0
	burst.angular_velocity_max = 520.0
	burst.damping_min = 0.4
	burst.damping_max = 1.6
	var fragment: BoxMesh = BoxMesh.new()
	fragment.size = Vector3.ONE
	var shard: StandardMaterial3D = CreatureKit.matte(SHELL_COLOUR.lightened(0.06), 0.45, 0.55)
	shard.emission_enabled = true
	shard.emission = SENSOR_COLOUR
	shard.emission_energy_multiplier = 0.55
	fragment.material = shard
	burst.mesh = fragment
	add_child(burst)

	var ember: OmniLight3D = OmniLight3D.new()
	ember.name = "DeathEmber"
	ember.position = Vector3(0.0, BODY_HEIGHT * 0.6, 0.0)
	ember.light_color = SENSOR_COLOUR
	ember.light_energy = 0.0
	ember.omni_range = 5.0
	ember.omni_attenuation = 0.8
	ember.light_volumetric_fog_energy = 2.2
	ember.shadow_enabled = false
	add_child(ember)
	_ember = ember


func _process(delta: float) -> void:
	if _death > 0.0:
		_die_visual(delta)
		return

	var moved: float = Vector2(global_position.x - _last_position.x,
			global_position.z - _last_position.z).length() / maxf(delta, 0.0001)
	_last_position = global_position
	_measured_speed = lerpf(_measured_speed, clampf(moved, 0.0, 12.0),
			1.0 - exp(-8.0 * delta))
	_drive_animation()

	decay_hurt_flash(delta, 4.0)
	_apply_state_visual()
	_update_audio(delta)


func _drive_animation() -> void:
	match int(sync_state):
		int(State.LUNGE):
			CreatureKit.travel(_tree, "lunge")
			CreatureKit.set_speed(_tree, 1.0)
		int(State.CHASE):
			CreatureKit.travel(_tree, "chase")
			CreatureKit.set_speed(_tree, clampf(_measured_speed / CHASE_STRIDE,
					CHASE_RATE_RANGE.x, CHASE_RATE_RANGE.y))
		int(State.FLEE):
			CreatureKit.travel(_tree, "flee")
			CreatureKit.set_speed(_tree, clampf(_measured_speed / CHASE_STRIDE,
					CHASE_RATE_RANGE.x, CHASE_RATE_RANGE.y))
		_:
			if _measured_speed > 0.7:
				CreatureKit.travel(_tree, "chase")
				CreatureKit.set_speed(_tree, clampf(_measured_speed / CHASE_STRIDE,
						CHASE_RATE_RANGE.x, CHASE_RATE_RANGE.y))
			else:
				CreatureKit.travel(_tree, "prowl")
				CreatureKit.set_speed(_tree, 1.0)


func _apply_state_visual() -> void:
	if _sensor_material == null or _trim_material == null:
		return
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var colour: Color = SENSOR_COLOUR
	var energy: float = 2.0
	var light: float = 0.7

	match int(sync_state):
		int(State.PROWL):
			energy = 1.8 + sin(t * 1.8) * 0.5
			light = 0.55
		int(State.CHASE):
			energy = 4.6 + sin(t * 7.0) * 0.9
			light = 1.0
		int(State.LUNGE):
			colour = Color(1.0, 0.6, 0.5)
			energy = 8.5
			light = 1.6
		int(State.FLEE):
			# The wounded stutter: the sensor gutters like a failing process.
			var stutter: float = 0.3 + 0.7 * absf(sin(t * 13.0))
			energy = 2.2 * stutter
			light = 0.5 * stutter

	var flash: float = hurt_flash()
	if flash > 0.0:
		colour = colour.lerp(Color(1.0, 0.95, 0.9), flash)
		energy += flash * 7.0
		light += flash * 2.5

	_sensor_material.emission = colour
	_sensor_material.emission_energy_multiplier = energy
	_trim_material.emission_energy_multiplier = 0.35 + energy * 0.09
	_light.light_color = colour
	_light.light_energy = light


## Per-peer audio off the replicated state. The howl is the spawn/return announce
## (DESIGN.md: "its howl announces the timer restarting"); the run loop is the
## thing you hear coming down the corridor.
func _update_audio(delta: float) -> void:
	if not _howled:
		_howled = true
		Audio.play_3d(&"hound_howl", global_position)
		Captions.emit(&"hound_howl", global_position, 40.0)

	var s: int = int(sync_state)
	if s != _audio_state:
		var want_run: bool = s == int(State.CHASE) or s == int(State.FLEE)
		if want_run and _run_loop == null:
			_run_loop = Audio.attach_loop(&"hound_prowl", self)
		elif not want_run and _run_loop != null:
			Audio.detach_loop(_run_loop)
			_run_loop = null
		_audio_state = s


func _die_visual(delta: float) -> void:
	_death = maxf(_death - delta * 0.8, 0.0)
	var fade: float = _death * _death
	_light.light_energy = 6.0 * sin(clampf(1.0 - _death, 0.0, 1.0) * PI) + fade
	if _sensor_material != null and _trim_material != null:
		_sensor_material.emission_energy_multiplier = 9.0 * fade
		_trim_material.emission_energy_multiplier = 1.4 * fade
	if _ember != null and is_instance_valid(_ember):
		var through: float = clampf(1.0 - _death, 0.0, 1.0)
		_ember.light_energy = 5.0 * sin(minf(through * 3.4, 1.0) * PI * 0.5) * pow(_death, 3.0)
	if _death <= 0.001:
		queue_free()
