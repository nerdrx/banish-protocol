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


# ============================================== M11 doctrine: THE AMBUSHER ===
#
# The Moth was already the one creature whose sense was interesting — it hunts
# LIGHT — and M11 does not touch that sense. What it was missing was what to do
# when the light goes out, and the answer it had was "wander, then leave", which
# taught the player exactly one thing and then stopped being a creature.
#
# The doctrine: it does not chase, it INTERCEPTS. When it loses the light it goes
# to the nearest light SOURCE it knows about and waits there. The crew's own
# fixtures become the ambush points; the flare somebody threw for safety is now a
# thing with a Moth circling it; and the corridor with the working work-light in
# it is a corridor you have to think about crossing.
#
# The dilemma DESIGN.md wanted — "kill it quickly or go dark and hide" — gets its
# missing third horn: going dark works, and it costs you the lit routes, because
# that is where the Moth is waiting.

var _ambush: Vector3 = Vector3.INF
var _ambush_time: float = 0.0

# ------------------------------------------- M11b: THE CEILING DIVE ---------
#
# The one creature in the game that owns the vertical, finally using it as a
# weapon rather than as a place to patrol.
#
# It breaks off, CLIMBS out of your beam into the dark of the ceiling, hangs
# there, and comes straight down on you.
#
# THE TELL IS THE CLIMB. A Moth leaving your light is not a Moth losing interest
# — it is a Moth getting above you, and the hang at the top is three quarters of
# a second of it sitting still in the one place a beam can still find it. So the
# counter is the thing the game has been teaching since M6.6: LOOK UP. Shoot it
# out of the air and the dive never happens; step aside and it hits the deck.
#
# Committed straight down, so it is dodgeable by one player with no crewmate; it
# staggers and costs under a quarter of a bar; and it cannot chain, because the
# cooldown is twelve seconds and the climb has to happen again.
enum Dive { NONE, CLIMB, HANG, FALL }

var _dive: Dive = Dive.NONE
var _dive_clock: float = 0.0
var _dive_cooldown: float = 0.0
var _dive_at: Vector3 = Vector3.ZERO
var _dive_apex: float = 0.0
var _dive_struck: bool = false
## Streamed so the climb reads as a wind-up on every screen rather than as the
## host's Moth wandering off.
var sync_dive: int = 0


func _extra_sync_properties() -> Array[String]:
	var out: Array[String] = super()
	out.append(".:sync_dive")
	return out


func diving() -> bool:
	return _dive != Dive.NONE


## Host-side. Considered before the ordinary state machine.
func _consider_dive(tick: float) -> void:
	_dive_cooldown = maxf(_dive_cooldown - tick, 0.0)
	if _dive != Dive.NONE:
		_advance_dive(tick)
		return
	if _dive_cooldown > 0.0:
		return
	var prey: Node3D = _light_body as Node3D
	if prey == null or not is_instance_valid(prey) or prey is ForkDecoy:
		return
	var gap: float = prey.global_position.distance_to(global_position)
	if gap > Balance.AI_DIVE_RANGE:
		return
	# It needs real air above it. In a low bus hall there is no dive, which is
	# correct: the move belongs to the tall rooms, and a crew that fights a Moth
	# under a low ceiling has chosen its ground well.
	var apex: float = _ceiling_here()
	if apex - prey.global_position.y < Balance.AI_DIVE_MIN_HEIGHT:
		return
	_dive = Dive.CLIMB
	sync_dive = int(Dive.CLIMB)
	_dive_clock = Balance.AI_DIVE_CLIMB_TIME
	_dive_cooldown = Balance.AI_DIVE_COOLDOWN
	_dive_apex = apex
	_dive_struck = false
	Audio.play_3d(&"scrubber_alert", global_position)
	Captions.emit(&"hunter_dive", global_position, 30.0)
	_tell_crew(&"_dive_windup_fx")


func _advance_dive(tick: float) -> void:
	_dive_clock -= tick
	if _dive_clock > 0.0:
		return
	match _dive:
		Dive.CLIMB:
			_dive = Dive.HANG
			_dive_clock = Balance.AI_DIVE_HANG
			# It commits to the point on the deck under whoever it was lit by,
			# AT THE MOMENT IT COMMITS. Everything after is a straight fall to a
			# spot, which is the whole of why stepping aside works.
			var prey: Node3D = _light_body as Node3D
			_dive_at = prey.global_position if prey != null and is_instance_valid(prey) \
					else global_position
			_dive_at.y = maxf(_dive_at.y, 0.0)
		Dive.HANG:
			_dive = Dive.FALL
			_dive_clock = 2.0
		Dive.FALL:
			_end_dive()
	sync_dive = int(_dive)


func _act_dive(delta: float) -> void:
	match _dive:
		Dive.CLIMB, Dive.HANG:
			# Straight up, out of the beam, and then perfectly still. The stillness
			# is the tell and it is also the shot.
			var above: Vector3 = Vector3(global_position.x, _dive_apex, global_position.z)
			_hover_to(above, Balance.MOTH_SURGE_SPEED, delta)
		Dive.FALL:
			var to_floor: Vector3 = _dive_at - global_position
			velocity = to_floor.normalized() * Balance.AI_DIVE_SPEED
			move_and_slide()
			if not _dive_struck:
				for body: Node3D in _running_players():
					if body.global_position.distance_to(global_position) > Balance.MOTH_STRIKE_RANGE:
						continue
					_dive_struck = true
					_land_hit(body, Balance.AI_DIVE_DAMAGE)
					break
			if global_position.distance_to(_dive_at) < 1.2 or _dive_struck:
				_impact_dive()
				_end_dive()


func _impact_dive() -> void:
	_dive_fx()
	_tell_crew(&"_dive_fx")


func _end_dive() -> void:
	_dive = Dive.NONE
	sync_dive = 0
	_dive_clock = 0.0


@rpc("authority", "call_remote", "unreliable_ordered")
func _dive_windup_fx() -> void:
	Audio.play_3d(&"scrubber_alert", global_position)
	Captions.emit(&"hunter_dive", global_position, 30.0)


@rpc("authority", "call_remote", "unreliable_ordered")
func _dive_fx() -> void:
	Audio.play_3d(&"scrubber_lunge", global_position)
	Fx.impact(global_position, Vector3.UP, EYE_COLOUR, 1.0)
	Fx.land_dust(global_position, 1)


## A stagger cancels a dive at any point in it, including mid-fall — the crew's
## answer to the move, and it must not be special-cased away.
func _on_staggered() -> void:
	if diving():
		_end_dive()


func ai_kind() -> String:
	return "moth"


func sight_range() -> float:
	return Balance.AI_SIGHT_MOTH


func sight_cone_deg() -> float:
	return Balance.AI_CONE_MOTH


## Deaf, and that is the character. Every other process in the game can be lured
## with a kicked can; the Moth cannot be lied to by sound at all, only by light —
## so going quiet does nothing for you and going dark does everything.
func hearing_rooms() -> int:
	return Balance.AI_HEAR_ROOMS_MOTH


func _telegraph_sound(state: int) -> StringName:
	match state:
		Suspicion.State.HUNTING:
			return &"scrubber_alert"
		Suspicion.State.ALERT, Suspicion.State.LOST, Suspicion.State.CURIOUS:
			return &"scrubber_chitter"
		_:
			return &""


## The ambush points: every light source it can currently sense, at hover height.
## Deliberately REPLACES the base's geometric candidates rather than extending
## them — a Moth does not check behind crates, it goes and sits on the lamps. That
## substitution is the single clearest way the four doctrines read differently
## when the same scenario is run against each of them.
func _search_candidates(kinds: Array[String]) -> Array[Vector3]:
	var spots: Array[Vector3] = []
	for node: Node in get_tree().get_nodes_in_group("flares"):
		var flare: Flare = node as Flare
		if flare == null or not is_instance_valid(flare) or not flare.is_burning():
			continue
		spots.append(flare.global_position + Vector3.UP * HOVER_HEIGHT)
		kinds.append("light")
	for node: Node in get_tree().get_nodes_in_group("work_lights"):
		var fixture: Node3D = node as Node3D
		if fixture == null or not is_instance_valid(fixture):
			continue
		if fixture.global_position.distance_to(global_position) > Balance.MOTH_LIGHT_RANGE * 1.5:
			continue
		spots.append(Vector3(fixture.global_position.x, HOVER_HEIGHT,
				fixture.global_position.z))
		kinds.append("light")
	if spots.is_empty():
		# No lamps at all in reach: fall back to the ordinary geometry so a Moth on
		# a wholly dark ring still searches rather than freezing. It is a worse
		# searcher than the Hound, which is correct — it is not a tracker.
		return super(kinds)
	return spots


func _on_suspicion(_from: int, to: int) -> void:
	if to == Suspicion.State.LOST:
		# The light went out. Go to the nearest lamp and WAIT.
		_ambush = _nearest_light_source()
		_ambush_time = Balance.AI_MOTH_AMBUSH_TIME
	elif to == Suspicion.State.HUNTING or to == Suspicion.State.UNAWARE:
		_ambush = Vector3.INF
		_ambush_time = 0.0


## THE MOTH'S SENSE, fed into the shared mind.
##
## Its sensorium is not a cone and reaches twice as far as one — it is "the
## brightest thing within 34 metres" — so it comes in through `_sense_extra`
## rather than pretending to be sight. What matters is that it goes through
## `mind.feed` like everything else: the strength is the light weight it already
## computed, so a Moth becomes certain about a lit crewmate quickly and about a
## flare on the floor never (a flare has no body, so it produces belief about a
## PLACE and the Moth still has to find whoever is standing near it).
func _sense_extra(delta: float, fed: Dictionary) -> void:
	var light: Dictionary = _brightest_light(Balance.MOTH_LIGHT_RANGE)
	if not bool(light["valid"]):
		mind.last_sight = 0.0
		return
	var weight: float = clampf(float(light["weight"]), 0.0, 1.0)
	mind.last_sight = maxf(mind.last_sight, weight)
	var body: Node3D = light["body"]
	var key: String = String(body.name) if body != null and is_instance_valid(body) \
			else "light"
	if mind.feed(key, weight, light["pos"], "light", delta, body):
		fed[key] = true
		if graph != null:
			memory.mark_seen(light["pos"], graph.region_of(light["pos"]))


## The nearest thing in the world that emits light, at hover height, or INF.
func _nearest_light_source() -> Vector3:
	var best: Vector3 = Vector3.INF
	var best_distance: float = INF
	for group: String in ["flares", "work_lights"]:
		for node: Node in get_tree().get_nodes_in_group(group):
			var source: Node3D = node as Node3D
			if source == null or not is_instance_valid(source):
				continue
			var flare: Flare = source as Flare
			if flare != null and not flare.is_burning():
				continue
			var distance: float = source.global_position.distance_to(global_position)
			if distance < best_distance:
				best_distance = distance
				best = Vector3(source.global_position.x, maxf(source.global_position.y,
						HOVER_HEIGHT), source.global_position.z)
	return best


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

	# M11: the ambush clock. It is only ever running in LOST, and it is what turns
	# "the light went out" from an exit into a threat.
	if _ambush_time > 0.0:
		_ambush_time -= tick

	# M11b: the CEILING DIVE owns the creature for its whole arc.
	_consider_dive(tick)
	if diving():
		return

	match state:
		State.DRIFT:
			if _light_weight > 0.0:
				_enter(State.SURGE)
			elif _ambush != Vector3.INF and _ambush_time > 0.0:
				# HOLDING THE LAMP. It does not wander and it does not leave: it
				# sits on the nearest light source and waits for somebody to walk
				# into it. `_act` flies it there; there is nothing else to decide.
				pass
			elif _dark_time >= Balance.MOTH_DARK_GIVEUP_TIME and _ambush_time <= 0.0:
				# Nothing to come to for long enough, and the ambush has expired: it
				# gives up the layer. Going dark still genuinely loses a Moth —
				# M11 makes it take an ambush's worth of patience longer.
				slink_away()
			else:
				_patrol_time -= tick
				if _patrol_time <= 0.0 or global_position.distance_to(_patrol) < 2.0:
					_patrol_time = _rng.randf_range(2.0, 4.0)
					var pressed: Vector3 = drift_target()
					_patrol = pressed if pressed != Vector3.INF and _rng.randf() < 0.4 \
							else _wander_point()
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
	if diving():
		_act_dive(delta)
		return
	match state:
		State.DRIFT:
			# The ambush point wins over the patrol while the clock runs: a waiting
			# Moth is a stationary shape hanging over a lamp, which is a much worse
			# thing to walk under than one bumbling around the room.
			var goal: Vector3 = _patrol
			if _ambush != Vector3.INF and _ambush_time > 0.0:
				goal = _ambush
			_hover_to(_route_to_air(goal), Balance.MOTH_DRIFT_SPEED, delta)
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
##
## M6.6: and it is the one process that ignores the deck graph entirely, on
## purpose. Ramps and stairs are for things with feet; a Moth that had to walk
## round to a staircase to reach a crewmate stood on a gantry would be the least
## frightening thing in the game. It takes the flat room-graph route and holds
## whatever altitude the target is at, which means a player who climbs to get away
## from the pack has climbed straight into the Moth's element.
func _route_to_air(target: Vector3) -> Vector3:
	var flat: Vector3 = _route_to_flat(Vector3(target.x, 0.0, target.z))
	return Vector3(flat.x, maxf(target.y, HOVER_HEIGHT), flat.z)


## The pre-M6.6 room-graph route: corridor mouths only, no deck steps. Bypasses
## `_route_to` so a flying hunter is never sent to the foot of a stair.
func _route_to_flat(target: Vector3) -> Vector3:
	if graph == null:
		return target
	var here: int = current_room()
	var there: int = graph.region_of(target)
	if here < 0 or there < 0 or here == there:
		return target
	var hop: int = graph.next_room(here, there)
	if hop < 0:
		return target
	var door: Vector3 = graph.link_point(here, hop)
	if Vector2(door.x - global_position.x, door.z - global_position.z).length() \
			< WAYPOINT_RADIUS:
		return graph.centre_of(hop)
	return door


## How high this room lets it fly. A Moth in a 4 m bus hall has nowhere to go; a
## Moth in the 12 m trunk room should be a shape crossing the light shaft above
## you, and this is the number that lets it be one.
func _ceiling_here() -> float:
	if graph == null:
		return HOVER_HEIGHT
	var room: int = current_room()
	if room < 0 or room >= graph.rooms.size():
		return HOVER_HEIGHT
	return maxf(float(graph.rooms[room].get("h", HOVER_HEIGHT)) - 1.2, HOVER_HEIGHT)


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
	# M7: through the one door — see `Antivirus._land_hit`.
	_land_hit(_light_body, Balance.MOTH_STRIKE_DAMAGE)
	_tell_crew(&"_strike_fx")


## Where it drifts to next, and at what ALTITUDE.
##
## M6.6: the patrol used to be a flat circle at 1.7 m — a Moth in a three-storey
## trunk room hovered at knee height in the corner of a twelve-metre volume, which
## wasted the only creature in the game that can use one. Now the height is rolled
## across the room's own headroom, biased upward, so it patrols the girders and the
## light shaft as often as the floor: you hear it above you before you see it, and
## looking up is how you find it. Deliberately quantised to nothing and rolled off
## its own private generator, so a tall room reads as a volume it OWNS rather than
## as a ceiling it occasionally bumps.
func _wander_point() -> Vector3:
	var base: Vector3 = home
	if graph != null and home_room >= 0:
		base = graph.centre_of(home_room)
	var altitude: float = patrol_altitude(_rng.randf(), _ceiling_here())
	return base + Vector3(_rng.randf_range(-7.0, 7.0), altitude,
			_rng.randf_range(-7.0, 7.0))


## Patrol altitude for a 0..1 roll in a room with `headroom` metres of usable
## air. A pure function so the behaviour can be asserted headlessly — see
## `Debug._vertical_selftest`. Catching a flying creature in the act is exactly
## the kind of claim a screenshot cannot settle.
##
## Biased HIGH: squaring the roll and lerping down from the ceiling puts most
## patrol points in the upper half of the volume, so a tall room is somewhere the
## Moth lives rather than somewhere it passes through at knee height. It never
## returns the ceiling itself (t=0 gives headroom, and `_ceiling_here` has already
## taken 1.2 m off the actual roof) and never drops below the hover floor.
static func patrol_altitude(t: float, headroom: float) -> float:
	return lerpf(maxf(headroom, HOVER_HEIGHT), HOVER_HEIGHT,
			clampf(t, 0.0, 1.0) * clampf(t, 0.0, 1.0))


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
				# PT-MULTI: `player.peer_id`, not `int(String(player.name))`. The
				# node name happens to be the peer id today; deriving identity from
				# it is the fragile spelling the multiplayer audit flagged, and a
				# rename anywhere would have quietly pointed this at peer 0.
				Haunt.muzzle_light(player.peer_id))
		if lit <= 0.0:
			continue
		var w: float = lit * clampf(1.0 - d / range_limit, 0.0, 1.0)
		if w > best_weight:
			best_weight = w
			best_pos = eye
			best_body = player

	# M7: a FORK DECOY is a running program, and a running program in this game
	# glows. The Moth hunts light rather than position, so it would otherwise be
	# the one process a fork could not fool — which would make the ability quietly
	# fail against exactly the hunter it is most needed against. Weighted BELOW a
	# lit beam and above a dark player: a fork is a faint glow, not a torch.
	for decoy: ForkDecoy in ForkDecoy.live_decoys(get_tree()):
		var lure: Vector3 = decoy.aim_point()
		var dd: float = lure.distance_to(global_position)
		if dd > range_limit or dd > decoy.lure_radius:
			continue
		var dw: float = 0.75 * clampf(1.0 - dd / range_limit, 0.0, 1.0)
		if dw > best_weight:
			best_weight = dw
			best_pos = lure
			best_body = decoy

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
	# M7 THE DECOMPILE SHATTER. Spawned at the Moth's HOVER height rather than at
	# its feet: it dies in the air, and fragments that appeared on the deck under
	# it would read as a second, unrelated event.
	Fx.decompile(global_position, EYE_COLOUR, false, HOVER_HEIGHT * 0.5)
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
