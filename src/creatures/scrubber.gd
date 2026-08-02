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
## Everything a client sees is `sync_state` plus a streamed pose: the gait, the
## sensor colour and the death shatter are all local reactions to those.
##
## M3.7 replaced the box-and-legs placeholder with the authored model
## (`assets/models/scrubber.glb`, 5 284 tris, 15 bones) and its four clips. The
## swap is deliberately **visual only** — health, speeds, ranges, the collision
## capsule and the whole state machine below are byte for byte what M3 shipped,
## so a regression in how a Scrubber *plays* cannot be blamed on how it looks.
##
## The one thing worth knowing about the mapping: STALK and FLEE share the
## skitter clip, time-scaled by how fast the body is actually moving. A fleeing
## Scrubber is faster than a stalking one, and playing one authored clip at one
## rate under both would have the feet sliding in exactly the state the player is
## most likely to be staring at it.

enum State { LURK, STALK, LUNGE, FLEE }

const BODY_HEIGHT: float = 0.42
const SENSOR_COLOUR: Color = Color(1.0, 0.16, 0.14)
const SHELL_COLOUR: Color = Color(0.05, 0.05, 0.06)

## Metres the skitter clip carries the body in one loop, measured off the
## authored cycle. Dividing real speed by this gives the playback rate that keeps
## the feet planted.
const SKITTER_STRIDE: float = 1.5
## Above this the clip is being pushed harder than it was authored for and starts
## to buzz; below it, a barely-moving Scrubber would freeze mid-step.
const SKITTER_RATE_RANGE: Vector2 = Vector2(0.55, 2.6)

var state: State = State.LURK

var _sensor_material: StandardMaterial3D = null
var _trim_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _shell: Node3D = null
var _anim: AnimationPlayer = null
var _tree: AnimationTree = null

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
var _last_position: Vector3 = Vector3.ZERO
var _measured_speed: float = 0.0
var _hurt_flash: float = 0.0
var _death: float = 0.0

## M5 audio, driven per-peer off the replicated `sync_state` (never the host-only
## `_enter`), so every client hears the creature it can see with no extra wire.
## The skitter loop is owned here and freed with the creature; the idle chitter
## uses its OWN rng — NOT the sim's `_rng`, which drives patrol points and whose
## sequence a sound draw would perturb (a determinism break). This one is
## cosmetic and seeded off wall time.
var _skitter: AudioStreamPlayer3D = null
var _audio_state: int = -1
var _chitter_timer: float = 0.0
var _chitter_rng: RandomNumberGenerator = RandomNumberGenerator.new()
## The dying coal left at the point of deletion. See `_play_death`.
var _ember: OmniLight3D = null


func _assemble() -> void:
	health = Balance.SCRUBBER_HEALTH
	speed_scale = float(LayerParams.of(layer_number)["scrubber_speed"])

	# Unchanged from M3. The authored mesh is 0.72 m wide and 0.49 m tall, which
	# fits inside this capsule with room to spare — deliberately: a knee-high
	# thing that circles you should be slightly *easier* to hit than its
	# silhouette suggests, or a pack becomes a coin flip.
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

	_build_model()

	_light = OmniLight3D.new()
	_light.name = "Sensor"
	_light.position = Vector3(0.0, BODY_HEIGHT + 0.1, -0.42)
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
	_chitter_rng.randomize()
	_chitter_timer = _chitter_rng.randf_range(1.0, 4.0)
	_patrol = home
	_last_position = position


## The authored model, repainted to the enemy palette and wired to an
## AnimationTree. The trim and core materials are kept as members because they
## are the creature's entire state read — see `_apply_state_visual`.
func _build_model() -> void:
	var model: Node3D = CreatureKit.instantiate(CreatureKit.SCRUBBER)
	if model == null:
		return
	model.name = "Model"
	_shell.add_child(model)

	_trim_material = CreatureKit.emissive(SENSOR_COLOUR, 0.55)
	_sensor_material = CreatureKit.emissive(SENSOR_COLOUR, 3.4)
	var mesh: MeshInstance3D = CreatureKit.find_mesh(model)
	CreatureKit.paint(mesh, {
		"Body": CreatureKit.matte(SHELL_COLOUR, 0.65, 0.42),
		"Plate": CreatureKit.matte(CreatureKit.ENEMY_PLATE, 0.5, 0.34),
		"EmissRed": _trim_material,
		"CoreEmiss": _sensor_material,
	})

	_anim = CreatureKit.find_player(model)
	CreatureKit.set_looping(_anim, PackedStringArray(["idle_lurk", "skitter"]))
	_tree = CreatureKit.build_tree(model, _anim, {
		"lurk": "idle_lurk",
		"skitter": "skitter",
		"lunge": "lunge",
		"death": "death_shatter",
	}, "lurk", 0.14)


## Its sensor is at ankle height, which is why a rack of data blocks is real
## cover from a Scrubber.
func _eye_height() -> float:
	return BODY_HEIGHT + 0.2


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

## Something was loud nearby. DESIGN.md: tapping a siphon is loud — and since
## M4.8 so is rewiring a junction, cutting a cabinet open, querying a terminal
## and kicking a can across a corridor. This is what "loud" costs you.
##
## The reach test is in rooms rather than metres on purpose: sound in this
## building goes down corridors, and a Scrubber the other side of a slab has not
## heard anything however close it is standing.
func alert(where: Vector3, rooms: int = Balance.TAP_ALERT_ROOMS,
		seconds: float = Balance.TAP_ALERT_TIME) -> void:
	if graph == null:
		return
	if graph.room_distance(current_room(), graph.region_of(where)) > rooms:
		return
	_alert_point = where
	# A quieter noise does not overwrite a louder one that is still holding: the
	# pack does not forget a siphon because somebody kicked a can afterwards.
	if seconds < _alert_time:
		return
	_alert_time = seconds
	if state == State.LURK:
		_enter(State.STALK)
	if Debug.log_ai:
		print("[AI] scrubber %d converging on noise at %s (%.0fs)" % [
			slot_index, str(where.snapped(Vector3.ONE * 0.1)), seconds])


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
	# Runs on every peer (host directly, clients via `_tell_crew`), so the cut is
	# heard wherever the creature is on each screen.
	Audio.play_3d(&"scrubber_hurt", global_position)


# --------------------------------------------------------------------- death --

## Slow shatter: the shell blows apart into red fragments, the sensor goes white
## and the light pulses once as the process is deallocated.
func _play_death() -> void:
	_death = 1.0
	set_physics_process(false)
	# Stop the skitter on the same frame the shell shatters; play the death.
	if _skitter != null:
		Audio.detach_loop(_skitter)
		_skitter = null
	Audio.play_3d(&"scrubber_death", global_position)
	# The clip does the coming-apart; the particles are the spray it throws off.
	# Playing one without the other reads either as a puff of dust with a corpse
	# still standing in it, or as a mesh quietly folding up in silence.
	CreatureKit.travel(_tree, "death")
	CreatureKit.set_speed(_tree, 1.0)

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
	# The fragments TUMBLE. A shell coming apart throws pieces that turn in the
	# air; particles that keep a fixed orientation read as sparks, and sparks are
	# what a thing made of electricity does, not what a thing made of plating does.
	burst.angular_velocity_min = -520.0
	burst.angular_velocity_max = 520.0
	burst.damping_min = 0.4
	burst.damping_max = 1.6
	var fragment: BoxMesh = BoxMesh.new()
	fragment.size = Vector3.ONE
	burst.mesh = fragment
	# Lit, not emissive.
	#
	# M3 made the fragments a flat emissive red, which meant a Scrubber deleted in
	# a pitch-black nest still threw thirty glowing chips — the one thing in the
	# room that did not need your beam to be visible, in a game whose second
	# pillar is that light is the only thing that renders anything. They are
	# plating now: dark, rough, faintly metallic, and they catch the player's beam
	# and the muzzle flash that killed them. In the dark you see almost nothing,
	# which is correct and much worse.
	var shard: StandardMaterial3D = CreatureKit.matte(SHELL_COLOUR.lightened(0.06),
			0.45, 0.55)
	shard.emission_enabled = true
	shard.emission = SENSOR_COLOUR
	# Just enough that a fragment carries a coal of the thing it came out of.
	shard.emission_energy_multiplier = 0.55
	burst.mesh.material = shard
	# The ember: a short red glow at the point of deletion, decaying over about a
	# second. This is what actually reads in a dark room — one dying coal where a
	# process used to be.
	var ember: OmniLight3D = OmniLight3D.new()
	ember.name = "DeathEmber"
	ember.position = Vector3(0.0, BODY_HEIGHT, 0.0)
	ember.light_color = SENSOR_COLOUR
	ember.light_energy = 0.0
	ember.omni_range = 4.5
	ember.omni_attenuation = 0.8
	ember.light_volumetric_fog_energy = 2.2
	ember.shadow_enabled = false
	add_child(ember)
	_ember = ember
	add_child(burst)


func _process(delta: float) -> void:
	if _death > 0.0:
		_die_visual(delta)
		return

	# Gait, driven by however fast this copy is actually moving — so a client's
	# puppet runs at the pace of the pose it receives, with no extra replication
	# and no need for the client to be able to see the state machine.
	var moved: float = Vector2(global_position.x - _last_position.x,
			global_position.z - _last_position.z).length() / maxf(delta, 0.0001)
	_last_position = global_position
	# Smoothed: a 20 Hz pose stream differentiates into a very noisy speed, and
	# feeding that straight into playback rate makes the clip stutter.
	_measured_speed = lerpf(_measured_speed, clampf(moved, 0.0, 12.0),
			1.0 - exp(-8.0 * delta))
	_drive_animation()

	_hurt_flash = maxf(_hurt_flash - delta * 4.0, 0.0)
	_apply_state_visual()
	_update_audio(delta)


## Creature audio, entirely a function of the replicated `sync_state` this copy
## can see — so a client hears exactly what it is watching. The skitter loop runs
## while it moves; the alert fires when it first has your signal; the lunge shriek
## fires with the windup, ~180 ms before the claws — and its caption is the single
## most important one in the game (spec 03), the deaf player's dodge cue.
func _update_audio(delta: float) -> void:
	var s: int = int(sync_state)
	if s != _audio_state:
		var want_skitter: bool = s == int(State.STALK) or s == int(State.FLEE)
		if want_skitter and _skitter == null:
			_skitter = Audio.attach_loop(&"scrubber_skitter", self)
		elif not want_skitter and _skitter != null:
			Audio.detach_loop(_skitter)
			_skitter = null
		# Idle -> trace: it has seen you (pack aggro tell).
		if s == int(State.STALK) and _audio_state == int(State.LURK):
			Audio.play_3d(&"scrubber_alert", global_position)
		# The windup. Fired on entering LUNGE, before the strike lands.
		if s == int(State.LUNGE):
			Audio.play_3d(&"scrubber_lunge", global_position)
		_audio_state = s

	# The 'in the walls' chitter while it drifts, every 2–6 s.
	if s == int(State.LURK):
		_chitter_timer -= delta
		if _chitter_timer <= 0.0:
			_chitter_timer = _chitter_rng.randf_range(2.0, 6.0)
			Audio.play_3d(&"scrubber_chitter", global_position)


## State -> clip, plus the time scale that keeps the feet planted.
func _drive_animation() -> void:
	match int(sync_state):
		int(State.LUNGE):
			CreatureKit.travel(_tree, "lunge")
			CreatureKit.set_speed(_tree, 1.0)
		int(State.STALK), int(State.FLEE):
			CreatureKit.travel(_tree, "skitter")
			CreatureKit.set_speed(_tree, clampf(_measured_speed / SKITTER_STRIDE,
					SKITTER_RATE_RANGE.x, SKITTER_RATE_RANGE.y))
		_:
			# Lurking, but a lurking Scrubber still drifts between loiter points.
			# Above walking pace it should be skittering, whatever the state
			# machine thinks it is doing.
			if _measured_speed > 0.9:
				CreatureKit.travel(_tree, "skitter")
				CreatureKit.set_speed(_tree, clampf(_measured_speed / SKITTER_STRIDE,
						SKITTER_RATE_RANGE.x, SKITTER_RATE_RANGE.y))
			else:
				CreatureKit.travel(_tree, "lurk")
				CreatureKit.set_speed(_tree, 1.0)


## The sensor is the tell. Dim and slow while lurking, hot and steady while
## stalking, white on the lunge, stuttering while it runs.
func _apply_state_visual() -> void:
	# `_build_model` returns early when the .glb will not instantiate, and the
	# materials below are created *after* that return — so on a failed load these
	# stay null and this function, which runs from `_process` for every Scrubber
	# on the layer, null-derefs every frame. Sentinel guards its equivalents the
	# same way (`_track_head` checks `_skeleton`, `_spin_halo` checks `_halo`).
	if _sensor_material == null or _trim_material == null:
		return
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


## The authored death_shatter clip is 1.0 s long and does the coming-apart, so
## this no longer scales the shell down — it only rides the light and the
## emissives out over the same window and frees the node at the end.
func _die_visual(delta: float) -> void:
	_death = maxf(_death - delta * 0.9, 0.0)
	var fade: float = _death * _death
	# One hard pulse of light as the process is deallocated, then nothing.
	_light.light_energy = 6.0 * sin(clampf(1.0 - _death, 0.0, 1.0) * PI) + fade
	if _sensor_material != null and _trim_material != null:
		_sensor_material.emission_energy_multiplier = 9.0 * fade
		_trim_material.emission_energy_multiplier = 1.4 * fade
	if _ember != null and is_instance_valid(_ember):
		# One hard flash as the process is deallocated, then a coal. Cubed rather
		# than squared: the tail has to be long enough to still be there when the
		# fragments have stopped moving, and dim enough not to light the room.
		var through: float = clampf(1.0 - _death, 0.0, 1.0)
		_ember.light_energy = 5.0 * sin(minf(through * 3.4, 1.0) * PI * 0.5) \
				* pow(_death, 3.0)
	if _death <= 0.001:
		queue_free()
