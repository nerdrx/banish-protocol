class_name Auditor
extends Hunter
## The Auditor — it has the schedule (HUNTER_DOSSIERS: "NONE REQUIRED. IT HAS THE
## SCHEDULE."). The only hunter that does not sense you at all. It walks the layer
## checking rooms in a fixed order at a fixed rate, and if you are in one when it
## arrives, that is a scheduling matter rather than an encounter.
##
## DESIGN.md: "methodical, not reactive ... audible rooms away ... a deleted
## Auditor ends audits for that layer — the most earnable safety of the three."
## So it is the opposite design to the Hound and the Moth: it cannot be lured,
## distracted, out-run or out-quieted, because it is not reacting to anything —
## the only inputs it takes are its route and its clock. What you CAN do is delete
## it, and unlike the others that does not buy time, it buys the ring: the audit
## ends and the rooms go unchecked (the Director does not recompile it).
##
## The route is seeded content — `LayerGraph.auditor_route`, rooms ordered by
## depth and terminating at the lowest accessible point on the ring (the dossier's
## one leaked fact) — so it is in the determinism dump and identical on every
## peer. Only where the Auditor has GOT to on that route is streamed.
##
## States (host only):
##   WALK     travelling to the next room on the route
##   INSPECT  standing in a room, sweeping it; strikes anyone caught beside it
##   STRIKE   the swing (a brief sub-state of an inspection)

enum State { WALK, INSPECT, STRIKE }

const BODY_HEIGHT: float = 2.1
const AUDIT_COLOUR: Color = Color(1.0, 0.15, 0.13)
const SHELL_COLOUR: Color = Color(0.05, 0.05, 0.06)

## Metres the patrol_walk clip carries the body per second at scale 1 — i.e. the
## backward speed of the planted foot during its stance, which is the ground speed
## that keeps it planted (measured off the clip by `--walkprobe auditor`, not the
## loop-average, which understates it whenever a gait has any float phase). Divide
## real ground speed by this for the no-skate playback rate.
const PATROL_STRIDE: float = 1.6
const PATROL_RATE_RANGE: Vector2 = Vector2(0.6, 1.6)

var state: State = State.WALK

var _trim_material: StandardMaterial3D = null
var _core_material: StandardMaterial3D = null
var _core_light: OmniLight3D = null
var _shell: Node3D = null
var _anim: AnimationPlayer = null
var _tree: AnimationTree = null

## The seeded route (room indices) and where on it the Auditor is.
var _route: Array[int] = []
var _route_index: int = 0
var _inspect_time: float = 0.0
var _strike_cooldown: float = 0.0
var _struck_this_inspect: bool = false
var _strike_time: float = 0.0
## Who to turn toward while inspecting, cached at the AI tick so `_act` does not
## re-scan the crew every physics frame.
var _face_target: Node3D = null

## Local.
var _death: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _measured_speed: float = 0.0
var _drone: AudioStreamPlayer3D = null
var _audio_state: int = -1
var _last_route_room: int = -1


func hunter_kind() -> StringName:
	return &"auditor"


func _drop_shards() -> int:
	return Balance.AUDITOR_DROP_SHARDS


func _drop_pieces() -> int:
	return Balance.AUDITOR_DROP_PIECES


## A deleted Auditor ENDS the audit for the ring — it does not recompile.
func _recompile_after_kill() -> float:
	return -1.0


func _eye_height() -> float:
	return BODY_HEIGHT - 0.4


# ====================================== M11 doctrine: THE METHODICAL SWEEPER ==
#
# The Auditor's identity is that it CANNOT BE SURPRISED, and the M6 way of saying
# so was to give it no senses at all: `alert()` was a no-op and it never looked at
# anybody. That reads as scheduled rather than methodical — a thing on rails, not
# a thing doing a job — and the tell was that a crew could stand in the room it
# was walking into, in the light, and it would arrive, inspect and leave without
# ever appearing to have noticed them.
#
# M11 gives it senses and denies it REACTIONS, which is a different and much
# better creature. It perceives; it just never chases, never hurries and never
# leaves its route. What evidence buys is one thing only: the room the evidence
# came from is moved to the FRONT of the route, so an audit that hears you re-
# orders itself toward you and then proceeds at exactly the same pace.
#
# So it is still the hunter you can route around — you always know where it will
# be next, because it tells you by walking there — and it is no longer a thing
# that ignores you to your face. `reacts_to_suspicion` is false, which is what
# keeps the ladder from ever making it run.

func ai_kind() -> String:
	return "auditor"


func sight_range() -> float:
	return Balance.AI_SIGHT_AUDITOR


func sight_cone_deg() -> float:
	return Balance.AI_CONE_AUDITOR


func hearing_rooms() -> int:
	return Balance.AI_HEAR_ROOMS_AUDITOR


## It has the schedule. Nothing on the ladder makes it deviate from the route —
## the only thing evidence changes is the ORDER of the route, in `_on_suspicion`.
func reacts_to_suspicion() -> bool:
	return false


## Its tells are deliberately the quietest in the game and never urgent: an audit
## that got excited would be a different creature. The scan tone when it decides
## something is worth a look, and nothing at all for the rest of the ladder.
func _telegraph_sound(state: int) -> StringName:
	if state == Suspicion.State.ALERT or state == Suspicion.State.HUNTING:
		return &"sentinel_scan"
	return &""


## THE RE-ORDER. Evidence promotes its room to the next stop on the route and
## does nothing else — no speed change, no pursuit, no state outside WALK and
## INSPECT. The audit is coming to you now instead of in four rooms' time, which
## is dread you can watch approaching rather than a creature that lunged.
func _on_suspicion(_from: int, to: int) -> void:
	if to != Suspicion.State.ALERT and to != Suspicion.State.HUNTING:
		return
	if _route.is_empty() or memory.lkp_room < 0:
		return
	var wanted: int = memory.lkp_room
	# Never the sanctuary: a backdoor room is sacred and an audit does not enter
	# one, whatever it thinks it heard in there (DESIGN.md mercy layer).
	if graph != null and graph.is_backdoor and wanted == graph.shaft_index:
		return
	var at: int = _route.find(wanted)
	if at < 0 or at == _route_index % _route.size():
		return
	_route.remove_at(at)
	_route.insert(_route_index % maxi(_route.size() + 1, 1), wanted)
	_struck_this_inspect = false
	_enter(State.WALK)
	if Debug.log_ai:
		print("[AI] auditor %d re-ordered its route toward %s" % [
			slot_index, graph.room_name(wanted) if graph != null else str(wanted)])


func aim_point() -> Vector3:
	return global_position + Vector3.UP * (BODY_HEIGHT * 0.55)


func _assemble() -> void:
	set_health(Balance.hunter_health(Balance.AUDITOR_HEALTH, layer_number))

	var shape: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.5
	capsule.height = BODY_HEIGHT
	shape.shape = capsule
	shape.position = Vector3(0.0, BODY_HEIGHT * 0.5, 0.0)
	add_child(shape)

	_shell = Node3D.new()
	_shell.name = "Shell"
	add_child(_shell)
	_build_model()

	_core_light = OmniLight3D.new()
	_core_light.name = "Core"
	_core_light.position = Vector3(0.0, BODY_HEIGHT * 0.62, -0.2)
	_core_light.light_color = AUDIT_COLOUR
	_core_light.light_energy = 0.9
	_core_light.omni_range = 5.0
	_core_light.omni_attenuation = 1.3
	_core_light.light_volumetric_fog_energy = 1.6
	_core_light.shadow_enabled = false
	_shell.add_child(_core_light)

	# The route: seeded, so identical on every peer, and starting from wherever on
	# it the Auditor was placed nearest.
	if graph != null:
		_route = graph.auditor_route()
	_route_index = _nearest_route_index()
	_inspect_time = Balance.AUDITOR_INSPECT_TIME
	_last_position = position

	# The presence drone — the "distant door-by-door" cue that says an audit is
	# underway rooms away, with a generous max distance.
	_drone = Audio.attach_loop(&"sentinel_drone", self, 1.5)


func _build_model() -> void:
	var model: Node3D = CreatureKit.instantiate(CreatureKit.AUDITOR)
	if model == null:
		return
	model.name = "Model"
	_shell.add_child(model)

	_trim_material = CreatureKit.emissive(AUDIT_COLOUR, 0.45)
	_core_material = CreatureKit.emissive(AUDIT_COLOUR, 1.3)
	CreatureKit.paint(CreatureKit.find_mesh(model), {
		"Body": CreatureKit.matte(SHELL_COLOUR, 0.5, 0.5),
		"Plate": CreatureKit.matte(CreatureKit.ENEMY_PLATE, 0.5, 0.36),
		"EmissRed": _trim_material,
		"CoreEmiss": _core_material,
	})

	_anim = CreatureKit.find_player(model)
	CreatureKit.set_looping(_anim, PackedStringArray(["patrol_walk", "inspect"]))
	_tree = CreatureKit.build_tree(model, _anim, {
		"walk": "patrol_walk",
		"inspect": "inspect",
		"turn": "alert_turn",
		"strike": "strike",
		"death": "death",
	}, "walk", 0.2)

	var skeleton: Skeleton3D = CreatureKit.find_skeleton(model)
	if skeleton != null:
		CreatureKit.build_spring_tail(skeleton, 30.0, 0.4)


## Where on the route the Auditor starts: the index of its spawn room. Uses
## `home_room` (set by setup) rather than `current_room()`, because `_assemble`
## runs before the node is in the tree, where `global_position` — and so
## `region_of` — is not yet meaningful.
func _nearest_route_index() -> int:
	if _route.is_empty():
		return 0
	for i: int in _route.size():
		if _route[i] == home_room:
			return i
	return 0


# ---------------------------------------------------------------- decisions --

func _think() -> void:
	var tick: float = Balance.AI_TICK
	if _strike_cooldown > 0.0:
		_strike_cooldown -= tick

	match state:
		State.WALK:
			if _route.is_empty():
				return
			var target_room: int = _route[_route_index % _route.size()]
			if current_room() == target_room \
					and global_position.distance_to(graph.centre_of(target_room)) < 4.0:
				_enter(State.INSPECT)
		State.INSPECT:
			_inspect_time -= tick
			# M11b: THE INDEX. The scan runs while it inspects — being in the room
			# when the audit arrives is the danger, and now being in the CONE when
			# it arrives is a different and worse one.
			_tick_index(tick)
			# Cache who to turn toward at the AI tick, so `_act` never re-scans the
			# crew every physics frame just to face them.
			_face_target = _nearest_player(Balance.AUDITOR_STRIKE_RANGE + 3.0, false)
			# Strike whoever is caught beside it during the sweep — being on the
			# route when it arrives is the danger, not being chased.
			if not _struck_this_inspect and _strike_cooldown <= 0.0:
				var beside: Node3D = _nearest_player(Balance.AUDITOR_STRIKE_RANGE, true)
				if beside != null:
					_enter(State.STRIKE)
					return
			if _inspect_time <= 0.0:
				_advance_route()
		State.STRIKE:
			_strike_time -= tick
			if _strike_time <= 0.0:
				_enter(State.INSPECT)


# ------------------------------------------------ M11b: THE INDEX ----------
#
# The Auditor's signature move is not an attack. It FILES you.
#
# Stand in its inspection cone — narrow, forward, twelve metres — for the whole
# of `AI_MARK_SCAN_TIME` and the scan completes and marks your process. It does no
# damage. It cannot kill you. What it does is make you READABLE: a marked agent
# is perceived as brightly lit by every process on the ring for forty-five
# seconds, whether or not their beam is on.
#
# That is the most frightening thing this creature could possibly do, because it
# is the exact inverse of the game's one reliable defence. Going dark stops
# working. You have been indexed, and the layer can see you until it wears off.
# It also does what the brief asked for and what an attack cannot: it CHANGES THE
# LAYER, and it feels like being processed rather than hit.
#
# Counter, and it is completely fair: walk out of the cone. The cone is narrow,
# it does not track you, the Auditor never chases, the scan is announced when it
# starts and progress is on the creature's own core, and the mark expires on its
# own and on descent.

var _scan_hold: float = 0.0
var _scan_peer: int = -1
## Streamed 0..1 so the crew can watch the bar fill on any screen.
var sync_scan: float = 0.0


func _extra_sync_properties() -> Array[String]:
	var out: Array[String] = super()
	out.append(".:sync_scan")
	return out


## Host-side, from `_think` while inspecting. Whoever is standing in the cone.
func _tick_index(tick: float) -> void:
	var limit: float = cos(deg_to_rad(Balance.AI_MARK_CONE_DEG))
	var facing: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	var caught: Player = null
	for body: Node3D in _running_players():
		var player: Player = body as Player
		if player == null:
			continue
		var to_body: Vector3 = player.global_position - global_position
		to_body.y = 0.0
		var distance: float = to_body.length()
		if distance > Balance.AI_MARK_RANGE or distance < 0.01:
			continue
		if (to_body / distance).dot(facing) < limit:
			continue
		if not _has_los(player):
			continue
		caught = player
		break

	if caught == null:
		# Stepped out. The scan does not resume where it left off — leaving the
		# cone genuinely beats it, rather than merely pausing it.
		_scan_hold = 0.0
		_scan_peer = -1
		sync_scan = 0.0
		return

	if caught.peer_id != _scan_peer:
		_scan_peer = caught.peer_id
		_scan_hold = 0.0
		Audio.play_3d(&"sentinel_scan", global_position)
		Captions.emit(&"hunter_audit", global_position, 26.0)
		_tell_crew(&"_audit_windup_fx")
	if Haunt.is_marked(caught.peer_id):
		return
	_scan_hold += tick
	sync_scan = clampf(_scan_hold / Balance.AI_MARK_SCAN_TIME, 0.0, 1.0)
	if _scan_hold < Balance.AI_MARK_SCAN_TIME:
		return
	_scan_hold = 0.0
	sync_scan = 0.0
	Haunt.mark_agent(caught.peer_id)
	_index_fx()
	_tell_crew(&"_index_fx")


@rpc("authority", "call_remote", "unreliable_ordered")
func _audit_windup_fx() -> void:
	Audio.play_3d(&"sentinel_scan", global_position)
	Captions.emit(&"hunter_audit", global_position, 26.0)


@rpc("authority", "call_remote", "unreliable_ordered")
func _index_fx() -> void:
	Audio.play_3d(&"sentinel_alarm", global_position)
	Captions.emit(&"hunter_marked", global_position, 40.0)
	Fx.pulse_ring(global_position, Balance.AI_MARK_RANGE * 0.5, AUDIT_COLOUR, 0.6)


func _advance_route() -> void:
	_route_index = (_route_index + 1) % maxi(_route.size(), 1)
	_inspect_time = Balance.AUDITOR_INSPECT_TIME
	_struck_this_inspect = false
	_enter(State.WALK)


func _enter(next: State) -> void:
	if state == next:
		return
	state = next
	sync_state = int(next)
	if next == State.STRIKE:
		_strike_time = 0.45
		_do_strike()
	if Debug.log_ai:
		print("[AI] auditor %d layer %d -> %s route=%d/%d at %s" % [
			slot_index, layer_number, State.keys()[int(next)],
			_route_index, _route.size(),
			str(global_position.snapped(Vector3.ONE * 0.1))])


# ------------------------------------------------------------------ movement --

func _act(delta: float) -> void:
	match state:
		State.WALK:
			if _route.is_empty():
				_steer(global_position, 0.0, delta)
				return
			var target_room: int = _route[_route_index % _route.size()]
			_steer(_route_to(graph.centre_of(target_room)),
					Balance.AUDITOR_WALK_SPEED * speed_scale, delta)
		State.INSPECT, State.STRIKE:
			# It stands and sweeps; it never chases. Face the crewmate cached at the
			# last AI tick (`_think`), else hold heading.
			if _face_target != null and is_instance_valid(_face_target):
				_face((_face_target.global_position - global_position).normalized(), delta)
			_steer(global_position, 0.0, delta)


func _do_strike() -> void:
	_struck_this_inspect = true
	_strike_cooldown = Balance.AUDITOR_STRIKE_COOLDOWN
	var limit: float = cos(deg_to_rad(70.0))
	var facing: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	for body: Node3D in _running_players():
		var to_body: Vector3 = body.global_position - global_position
		to_body.y = 0.0
		var distance: float = to_body.length()
		if distance > Balance.AUDITOR_STRIKE_RANGE or distance < 0.01:
			continue
		if (to_body / distance).dot(facing) < limit:
			continue
		# M7: through the one door — see `Antivirus._land_hit`.
		_land_hit(body, Balance.AUDITOR_STRIKE_DAMAGE)
	_tell_crew(&"_strike_fx")


# -------------------------------------------------------------------- events --

## M7. Two metres of methodical process; it is stunned in place, not shoved.
## Being able to knock the audit off its route would turn "dread on a schedule"
## into "dread you can push around", which is a different creature.
func stagger_mass() -> bool:
	return true


## The Auditor does not react — noise, light, damage and absence are all nothing
## to it. `alert` is deliberately a no-op, which is most of the character.
func alert(_where: Vector3, _rooms: int = Balance.TAP_ALERT_ROOMS,
		_seconds: float = Balance.TAP_ALERT_TIME) -> void:
	pass


func _on_hurt() -> void:
	_hit()
	_tell_crew(&"_hit")


@rpc("authority", "call_remote", "unreliable_ordered")
func _hit() -> void:
	trigger_hurt_flash()
	Audio.play_3d(&"sentinel_core_hit", global_position)


@rpc("authority", "call_remote", "unreliable_ordered")
func _strike_fx() -> void:
	Audio.play_3d(&"sentinel_purge", global_position)
	Captions.emit(&"auditor_strike", global_position, 24.0)


func despawn() -> void:
	if _drone != null:
		Audio.detach_loop(_drone)
		_drone = null
	super()


# --------------------------------------------------------------------- death --

func _play_death() -> void:
	_death = 1.0
	set_physics_process(false)
	if _drone != null:
		Audio.detach_loop(_drone)
		_drone = null
	Audio.play_3d(&"sentinel_death", global_position)
	# M7 THE DECOMPILE SHATTER, at the heavy budget: two metres of methodical
	# process throws twice what a cleaner does.
	Fx.decompile(global_position, AUDIT_COLOUR, true, BODY_HEIGHT * 0.55)
	CreatureKit.travel(_tree, "death")
	CreatureKit.set_speed(_tree, 1.0)
	Captions.emit(&"auditor_ended", global_position, 24.0)

	var burst: CPUParticles3D = CPUParticles3D.new()
	burst.name = "Collapse"
	burst.emitting = true
	burst.one_shot = true
	burst.amount = 56
	burst.lifetime = 1.4
	burst.explosiveness = 0.9
	burst.position = Vector3(0.0, BODY_HEIGHT * 0.5, 0.0)
	burst.direction = Vector3.UP
	burst.spread = 180.0
	burst.initial_velocity_min = 1.6
	burst.initial_velocity_max = 6.0
	burst.gravity = Vector3(0.0, -8.5, 0.0)
	burst.scale_amount_min = 0.07
	burst.scale_amount_max = 0.26
	var fragment: BoxMesh = BoxMesh.new()
	fragment.size = Vector3.ONE
	burst.mesh = fragment
	burst.material_override = CreatureKit.emissive(AUDIT_COLOUR, 2.4)
	add_child(burst)


func _process(delta: float) -> void:
	if _death > 0.0:
		_die_visual(delta)
		return

	var moved: float = Vector2(global_position.x - _last_position.x,
			global_position.z - _last_position.z).length() / maxf(delta, 0.0001)
	_last_position = global_position
	_measured_speed = lerpf(_measured_speed, clampf(moved, 0.0, 6.0), 1.0 - exp(-8.0 * delta))
	_drive_animation()

	decay_hurt_flash(delta, 3.0)
	_apply_state_visual()
	_update_audio()


func _drive_animation() -> void:
	match int(sync_state):
		int(State.STRIKE):
			CreatureKit.travel(_tree, "strike")
			CreatureKit.set_speed(_tree, 1.0)
		int(State.INSPECT):
			CreatureKit.travel(_tree, "inspect")
			CreatureKit.set_speed(_tree, 1.0)
		_:
			if _measured_speed > 0.3:
				CreatureKit.travel(_tree, "walk")
				CreatureKit.set_speed(_tree, clampf(_measured_speed / PATROL_STRIDE,
						PATROL_RATE_RANGE.x, PATROL_RATE_RANGE.y))
			else:
				CreatureKit.travel(_tree, "inspect")
				CreatureKit.set_speed(_tree, 1.0)


func _apply_state_visual() -> void:
	if _core_material == null or _trim_material == null:
		return
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var core: float = 1.2
	var trim: float = 0.45
	match int(sync_state):
		int(State.INSPECT):
			# Brightens while it sweeps a room — the "inspection" reads across rooms.
			core = 2.6 + sin(t * 3.0) * 0.6
			trim = 1.0
		int(State.STRIKE):
			core = 6.0
			trim = 2.2
	var flash: float = hurt_flash()
	if flash > 0.0:
		core += flash * 8.0
		trim += flash * 2.0
	_core_material.emission_energy_multiplier = core
	_trim_material.emission_energy_multiplier = trim
	_core_light.light_energy = 0.7 + core * 0.4


## The "distant door-by-door" cue: a soft inspect tick each time the Auditor
## enters a new room on its route, so a crew hears the audit advancing toward them
## one room at a time.
func _update_audio() -> void:
	var s: int = int(sync_state)
	if s != _audio_state:
		if s == int(State.INSPECT):
			Audio.play_3d(&"sentinel_scan", global_position)
		_audio_state = s
	var room: int = current_room()
	if room != _last_route_room and s == int(State.WALK):
		_last_route_room = room
		Captions.emit(&"auditor_step", global_position, 26.0)


func _die_visual(delta: float) -> void:
	_death = maxf(_death - delta * 0.7, 0.0)
	var fall: float = 1.0 - _death
	if _shell != null:
		_shell.rotation.x = fall * 1.3
		_shell.position.y = -fall * 1.0
	if _core_material != null:
		_core_material.emission_energy_multiplier = 12.0 * sin(clampf(fall, 0.0, 1.0) * PI)
	if _trim_material != null:
		_trim_material.emission_energy_multiplier = 2.0 * _death
	_core_light.light_energy = 8.0 * sin(clampf(fall, 0.0, 1.0) * PI)
	if _death <= 0.001:
		queue_free()
