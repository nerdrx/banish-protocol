class_name Antivirus
extends CharacterBody3D
## Base for MOTHER's hunting processes. Owns everything a state machine needs and
## nothing about any particular one.
##
## Authority (DESIGN.md "Multiplayer Architecture"): the host simulates, clients
## observe. Only the host runs the state machine and moves the body; every peer
## receives pose and state through a MultiplayerSynchronizer and smooths toward
## them. A client's copy is a puppet — it never decides anything, which is why a
## client cannot see a Scrubber's state machine to predict a lunge.
##
## Existence, though, is not replicated. Which processes a layer has is a pure
## function of (seed, layer number), exactly like the walls, so every peer
## *builds* the same creatures locally and the wire only ever carries what they
## are doing. That is M2's rule ("nothing about the layout ever goes over the
## wire") applied to the things standing in the layout, and it means a peer can
## never be told about a Scrubber before it has a floor to put it on.
##
## The one thing that needs care is that a synchronizer starts streaming the
## moment a peer connects, several frames before that peer's layer scene exists.
## Visibility is therefore gated on the crew roster, which Net only writes once
## the peer's world is up.
##
## Pathing is the room graph, not a navmesh: M2's floors are flat and its
## doorways are 3.2 m wide, so "steer at the centre of the corridor into the next
## room" is enough to cross a layer, and it costs a dictionary lookup instead of
## a bake on every descent.
##
## Subclasses implement `_think()` (one decision, AI_TICK apart) and `_act()`
## (per physics frame movement), and set `sync_state` for the visuals.

## Emitted on every peer the moment this process starts coming apart. The
## director uses it to remember what a joining peer must not rebuild.
signal died

## Everything hostile is in this group; the director sweeps it on descent, and
## the siphon tap's ping is delivered through it.
const GROUP: String = "antivirus"

## Physics layer 4 — see project.godot [layer_names]. Players collide with it,
## the breaker's hitscan tests against it, and antivirus bodies ignore each other
## (a pack that shoves itself apart cannot come through a doorway).
const ANTIVIRUS_LAYER: int = 8
const WORLD_MASK: int = 1

const GRAVITY: float = 11.0
## How close to a waypoint counts as reaching it.
const WAYPOINT_RADIUS: float = 2.2
## Eye height used for line-of-sight and beam-exposure tests against a player.
const PLAYER_EYE: float = 1.62

# --- identity (set by the director on every peer before tree entry) ----------

var slot_index: int = 0
var layer_number: int = 1
## Seeded anchor this creature was bought at, and the room it belongs to.
var home: Vector3 = Vector3.ZERO
var home_room: int = -1
## Every peer's own copy of the layer layout — pathing needs no replication.
var graph: LayerGraph = null

# --- replicated -------------------------------------------------------------

var sync_position: Vector3 = Vector3.ZERO
var sync_yaw: float = 0.0
var sync_state: int = 0
## Death travels as state rather than as an RPC: an RPC would be sent to peers
## that do not have this node yet, and a streamed flag is gated by the same
## visibility rule as everything else. The host keeps the corpse alive for the
## length of the shatter, which is far longer than the stream needs.
var sync_dead: bool = false
## PT1. 0..1 remaining integrity, host-authoritative and replicated ON CHANGE, so
## the integrity readout on a CLIENT's screen shows the right number for a
## creature damaged by anyone. Health itself stays host-only — a client has no
## business knowing absolute hit points, and a fraction is all a readout draws.
var sync_integrity: float = 1.0

# --- host sim ---------------------------------------------------------------

var health: float = 100.0
## What `health` started at, so a fraction can be reported without every subclass
## remembering to publish its own maximum. Written by `set_health`.
var health_max: float = 100.0
var speed_scale: float = 1.0

var _is_host: bool = false
var _tick_clock: float = 0.0
## Anti-wedge: creatures that stop making progress against a wall pick a
## sidestep rather than grinding a corner forever.
var _stuck_time: float = 0.0
var _dodge: Vector3 = Vector3.ZERO
var _dodge_time: float = 0.0
var _dying: bool = false

var _synchronizer: MultiplayerSynchronizer = null

# --- PT1: the hit flash, and its rate governor -------------------------------

## SAFETY-CRITICAL (limbo-a11y 01-photosensitivity, DESIGN.md pillar 7).
##
## Every process in the game brightens when it is cut — the "yes, that landed"
## half of the impact feedback the first playtest asked for. The breaker fires as
## fast as `Balance.BREAKER_COOLDOWN` allows (~3.85 Hz at 0.26 s), so a held
## trigger on a Sentinel used to drive a 9x emissive spike at 3.85 Hz: OVER the
## WCAG 2.3.1 three-general-flashes-a-second ceiling, on a creature that fills
## the frame, in the DEFAULT build. The safety law is non-negotiable and it is
## not satisfied by a setting.
##
## The governor is the same shape as the muzzle flash's (see
## `ViewModel.MUZZLE_FLASH_MIN_INTERVAL`) and for the same reason: at most one
## full-amplitude flash per interval, >1/3 s, so <=3 Hz UNCONDITIONALLY with
## Reduced Flashing OFF. A shot that lands inside the interval still registers —
## the reticle ticks, the confirm sounds, the integrity readout moves — it simply
## does not re-strike the creature's emission. Independently, `hurt_flash()`
## scales by `A11y.flash_scale`, so Reduced Flashing takes it to nothing.
const HURT_FLASH_MIN_INTERVAL: float = 0.36
## 0..1, decaying. Subclasses read it through `hurt_flash()` and NEVER directly:
## the accessor is where the cap is applied, and a direct read is a hole in it.
var _hurt_flash: float = 0.0
var _since_hurt_flash: float = 10.0

# --- M7: stagger (STACK PULSE) ------------------------------------------------
#
# CONTROL, NOT DAMAGE. The killability law says every monster dies to the
# breaker; its converse is that nothing else may quietly start killing them. A
# stagger takes a process OUT OF ITS STATE MACHINE for a beat and, if it is light
# enough to be moved, shoves it — and does nothing else. `health` is not touched
# anywhere on this path.
#
# Implemented in the BASE rather than per subclass on purpose. `_physics_process`
# simply does not call `_think()` or `_act()` while the timer runs, so a committed
# lunge stops committing, a purge stops swinging and a walk stops walking, for
# every process the game has and every process it ever gets — including ones
# written after this. A subclass that needs to *forget* what it was doing
# overrides `_on_staggered()`; one that does not, does not have to know the
# mechanic exists.

## Seconds of stagger left (host-authoritative) and the shove being ridden out.
var _stagger_time: float = 0.0
var _stagger_push: Vector3 = Vector3.ZERO
## Cosmetic, on every peer: 0..1 decaying, drives the subclass's own reaction and
## the flinch. Replicated as a streamed flag rather than an RPC, for the same
## reason death is — a packet aimed at a peer whose layer is still building is an
## engine error, not a dropped message.
var sync_staggered: bool = false
var _stagger_flash: float = 0.0


# ------------------------------------------------------------------ assembly --

## Called by the director's spawn function on every peer. Subclasses build their
## body in `_assemble()`.
func setup(index: int, where: Vector3, room: int, layer: int, layout: LayerGraph) -> void:
	slot_index = index
	layer_number = layer
	home = where
	home_room = room
	graph = layout
	position = where
	sync_position = where
	collision_layer = ANTIVIRUS_LAYER
	collision_mask = WORLD_MASK
	# M6.6: the layer has ramps and stairs in it now. Without a snap, a body
	# walking down a slope leaves the surface every frame, never reports
	# `is_on_floor`, and `_steer` puts it into a permanent fall — which reads as a
	# Scrubber bouncing down a staircase. The angle is Godot's default 45 degrees
	# and every authored slope is under 27, so nothing here can climb a wall.
	floor_snap_length = 0.55
	_assemble()
	_build_sync()


## Subclass hook: meshes, lights, collision shape.
func _assemble() -> void:
	pass


## Subclass hook: extra continuously-streamed properties, as `".:name"` paths.
## The Sentinel's scan angle goes through here — a sweep that misses on your
## screen and hits on the host's would be unplayable.
func _extra_sync_properties() -> Array[String]:
	return []


## The replication rig, built in code for the same reason the props are: a
## creature must be placeable without a scene dependency. Pose and death stream
## every packet; state only when it changes.
func _build_sync() -> void:
	var config: SceneReplicationConfig = SceneReplicationConfig.new()
	var streamed: Array[String] = [".:sync_position", ".:sync_yaw", ".:sync_dead"]
	streamed.append_array(_extra_sync_properties())
	for property: String in streamed:
		config.add_property(NodePath(property))
		config.property_set_spawn(NodePath(property), true)
		config.property_set_replication_mode(NodePath(property),
				SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	for occasional: String in [".:sync_state", ".:sync_integrity", ".:sync_staggered"]:
		config.add_property(NodePath(occasional))
		config.property_set_spawn(NodePath(occasional), true)
		config.property_set_replication_mode(NodePath(occasional),
				SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)

	_synchronizer = MultiplayerSynchronizer.new()
	_synchronizer.name = "Sync"
	_synchronizer.root_path = NodePath("..")
	_synchronizer.replication_interval = Balance.ANTIVIRUS_SYNC_INTERVAL
	_synchronizer.delta_interval = Balance.ANTIVIRUS_SYNC_INTERVAL
	_synchronizer.replication_config = config
	# Nobody is streamed to until Net has them in the crew roster, which is its
	# own signal that the peer's layer scene is standing.
	_synchronizer.public_visibility = false
	_synchronizer.add_visibility_filter(_peer_has_world)
	add_child(_synchronizer)


func _peer_has_world(peer_id: int) -> bool:
	return Net.crew.has(peer_id)


## Re-evaluates the visibility filter. Called by the director when the roster
## changes, which is the only thing the filter depends on.
func refresh_visibility() -> void:
	if _synchronizer != null and is_instance_valid(_synchronizer):
		_synchronizer.update_visibility()


func _ready() -> void:
	add_to_group(GROUP)
	_is_host = multiplayer.has_multiplayer_peer() and multiplayer.is_server()
	# Solo editor runs have no peer at all; there is nobody else to be authority.
	if not multiplayer.has_multiplayer_peer():
		_is_host = true
	sync_yaw = rotation.y


# ------------------------------------------------------------------- physics --

func _physics_process(delta: float) -> void:
	# Clients learn about a death from the stream, not from a message: see
	# `sync_dead`.
	if sync_dead and not _dying:
		_begin_death()
	if _dying:
		return
	# The flinch weight decays on EVERY peer against that peer's own clock, so a
	# client's stagger reaction is never a function of packet arrival order.
	_stagger_flash = maxf(_stagger_flash - delta * 2.2, 0.0)
	if sync_staggered and _stagger_flash <= 0.0:
		_stagger_flash = 1.0
	if not _is_host:
		_smooth_remote(delta)
		return

	# M7: staggered. Out of the state machine entirely for the duration — no
	# decision, no attack, no pathing — and riding out whatever shove came with
	# it. This is what "interrupts a lunge" means mechanically: the lunge simply
	# does not get another frame of `_act`.
	if _stagger_time > 0.0:
		_stagger_time = maxf(_stagger_time - delta, 0.0)
		_ride_stagger(delta)
		if _stagger_time <= 0.0:
			sync_staggered = false
		sync_position = global_position
		sync_yaw = rotation.y
		return

	_tick_clock -= delta
	if _tick_clock <= 0.0:
		_tick_clock = Balance.AI_TICK
		_think()

	_act(delta)

	sync_position = global_position
	sync_yaw = rotation.y


## Subclass hook: one decision. Runs at Balance.AI_TICK, host only.
func _think() -> void:
	pass


## Subclass hook: movement for this frame. Host only.
func _act(_delta: float) -> void:
	pass


# ------------------------------------------------------------------- stagger --

## Host-side. STACK PULSE landed on this process.
##
## `seconds` is how long it is out of its own state machine; `push` is metres of
## knockback for a process light enough to be moved. Heavy ones (see
## `stagger_mass`) are stunned in place instead — a 2.6 m quarantine process does
## not skid across a deck because somebody clapped, and pretending it does would
## make the ability read as a joke rather than as an interrupt.
##
## Deliberately idempotent-ish: a second pulse inside the first EXTENDS the
## stagger rather than stacking two shoves, so two crewmates pulsing together
## buy more time, not more physics.
func stagger(seconds: float, from: Vector3, push: float) -> void:
	if not _is_host or _dying or seconds <= 0.0:
		return
	_stagger_time = maxf(_stagger_time, seconds)
	sync_staggered = true
	_stagger_flash = 1.0
	var away: Vector3 = global_position - from
	away.y = 0.0
	if away.length_squared() > 0.0001 and push > 0.0 and not stagger_mass():
		# Distance over duration: the shove is spent over the whole stagger, so a
		# knocked-back Scrubber SLIDES away and settles rather than being teleported
		# and then standing still looking foolish.
		_stagger_push = away.normalized() * (push / maxf(seconds, 0.01))
	else:
		_stagger_push = Vector3.ZERO
	_on_staggered()


## Whether this process is too heavy to shove. Overridden by the Sentinel and the
## Auditor; everything else is light enough to move.
func stagger_mass() -> bool:
	return false


## Subclass hook: forget what you were doing. Called on the host at the moment a
## stagger lands, so a creature whose state machine has a committed flag (a lunge
## in flight, a purge swing armed) can drop it — the base already stops it being
## SIMULATED, and this is for the bookkeeping that would otherwise resume when the
## stagger ends.
func _on_staggered() -> void:
	pass


## Riding out the shove, host-side. Uses `move_and_slide` like everything else, so
## a knocked-back process stops at a wall instead of going through it.
func _ride_stagger(delta: float) -> void:
	velocity.x = _stagger_push.x
	velocity.z = _stagger_push.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - GRAVITY * delta
	_stagger_push = _stagger_push.lerp(Vector3.ZERO, 1.0 - exp(-6.0 * delta))
	move_and_slide()


## 0..1 flinch weight, ALREADY capped by the flash scale — the same contract
## `hurt_flash()` keeps, and the only legal way to read it. Subclasses use it to
## drive an emissive dip and a pose recoil; nothing may read `_stagger_flash`.
func stagger_flash() -> float:
	return _stagger_flash * A11y.flash_scale


func staggered() -> bool:
	return _stagger_time > 0.0 or sync_staggered


## Clients: ease onto the host's pose. No dead reckoning — a Scrubber changes
## direction constantly, and extrapolating it just makes the puppet twitch.
func _smooth_remote(delta: float) -> void:
	var blend: float = 1.0 - exp(-14.0 * delta)
	global_position = global_position.lerp(sync_position, blend)
	if global_position.distance_to(sync_position) > 8.0:
		global_position = sync_position  # respawn or teleport, not a slide.
	rotation.y = lerp_angle(rotation.y, sync_yaw, blend)


# ------------------------------------------------------------------- motion --

## Planar steering toward `target` with gravity, wall-slide and a stuck escape.
func _steer(target: Vector3, speed: float, delta: float) -> void:
	var to_target: Vector3 = target - global_position
	to_target.y = 0.0
	if _dodge_time > 0.0:
		_dodge_time -= delta
		to_target += _dodge * 6.0

	var wish: Vector3 = Vector3.ZERO
	if to_target.length_squared() > 0.04:
		wish = to_target.normalized()

	var desired: Vector3 = wish * speed
	var planar: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	planar = planar.move_toward(desired, speed * 6.0 * delta)
	velocity.x = planar.x
	velocity.z = planar.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - GRAVITY * delta

	var before: Vector3 = global_position
	move_and_slide()

	_face(wish, delta)
	_check_stuck(before, speed, wish, delta)


## Turn toward travel. Deliberately not instant: a creature that snaps to face
## you reads as a turret rather than something running at you.
func _face(wish: Vector3, delta: float) -> void:
	if wish.length_squared() < 0.01:
		return
	var want: float = atan2(-wish.x, -wish.z)
	rotation.y = lerp_angle(rotation.y, want, 1.0 - exp(-9.0 * delta))


func _check_stuck(before: Vector3, speed: float, wish: Vector3, delta: float) -> void:
	if wish.length_squared() < 0.01 or speed <= 0.01:
		_stuck_time = 0.0
		return
	var moved: float = Vector2(global_position.x - before.x,
			global_position.z - before.z).length()
	if moved > speed * delta * 0.35:
		_stuck_time = 0.0
		return

	_stuck_time += delta
	if _stuck_time < 0.5 or _dodge_time > 0.0:
		return
	# Wedged. Slide along the wall for a beat, picking the side deterministically
	# from the creature's own index so a pack does not all break the same way.
	var side: float = 1.0 if (slot_index % 2) == 0 else -1.0
	_dodge = Vector3(-wish.z, 0.0, wish.x) * side
	_dodge_time = 0.8
	_stuck_time = 0.0


# ------------------------------------------------------------------ pathing --

## Room the creature is standing in (corridors resolve to a room).
func current_room() -> int:
	if graph == null:
		return -1
	return graph.region_of(global_position)


## Waypoint on the way to `target`: straight at it while sharing a room AND a
## deck, at the connecting corridor's centre when the rooms differ, and at the
## foot of a ramp, stair or catwalk when only the elevation does. Recomputed as
## rooms and decks change, so a chase up onto a mezzanine and back down re-routes
## without any path bookkeeping.
##
## M6.6: this is the whole of the antivirus's verticality. There is still no
## navmesh — the floors are flat *within* a deck, the doorways are 3.2 m wide and
## every route between decks is a 4 m wide walkable slope, so "steer at the bottom
## of the stair, then at the top of it" gets a Sentinel onto a gallery exactly the
## way "steer at the corridor mouth" gets it into the next room. The important
## property is that the graph refuses to author a deck a route cannot reach
## (`LayerGraph.unreachable_decks`), so there is no position a player can stand in
## that this function cannot produce a path to.
func _route_to(target: Vector3) -> Vector3:
	if graph == null:
		return target
	var here: int = current_room()
	var there: int = graph.region_of(target)
	if here < 0 or there < 0:
		return target

	if here != there:
		var hop: int = graph.next_room(here, there)
		if hop < 0:
			return target
		# Leaving the room means getting back to grade first: a corridor mouth is at
		# floor level, and a creature on a gallery has to walk down before it can
		# walk out.
		var descend: Vector3 = _deck_step(here, -1)
		if descend != Vector3.INF:
			return descend
		var door: Vector3 = graph.link_point(here, hop)
		# Once through the corridor mouth, aim at the room beyond it rather than
		# standing in the doorway re-deciding.
		if Vector2(door.x - global_position.x, door.z - global_position.z).length() \
				< WAYPOINT_RADIUS:
			return graph.centre_of(hop)
		return door

	var want: int = graph.deck_at(target)
	var step: Vector3 = _deck_step(here, want)
	return step if step != Vector3.INF else target


## The next deck-graph waypoint inside `room`, or INF when this creature is
## already on the deck it wants. Once it is standing at the mouth of the route it
## aims at the far end instead, which is what makes it commit to a flight of
## stairs rather than loitering at the bottom re-deciding every tick.
func _deck_step(room: int, want: int) -> Vector3:
	var standing: int = graph.deck_at(global_position)
	if standing == want:
		return Vector3.INF
	return graph.deck_waypoint(room, standing, want, global_position)


# -------------------------------------------------------------------- senses --

## Living, running crew, as bodies. Corrupted crewmates are on the floor and
## corpses do not get hunted — DESIGN.md's restore window would be worthless if a
## pack camped the body — and anyone stood in a backdoor sanctuary is off the
## board entirely: antivirus does not go in there.
##
## **M7: a live FORK DECOY is in this list too**, and that is the whole of how the
## ability works. Everything that hunts by position — the Scrubbers, the Hound,
## the Moth, the Sentinel, the Auditor — asks this one question, so a fork becomes
## prey to all of them by being appended here rather than by five state machines
## learning about a new class. The decoy is filtered by the same sanctuary rule
## as a crew member (a fork walked into a backdoor room is off the board too), and
## by its own lure radius: past that, a process is not fooled.
##
## The damage side is safe by construction because every strike goes through
## `_land_hit`, which asks what it is aiming at before it asks anything else.
func _running_players() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not Run.is_running(peer):
			continue
		var node: Node = Net.get_player(peer)
		if node == null or not is_instance_valid(node):
			continue
		var body: Node3D = node as Node3D
		if _in_sanctuary(body.global_position):
			continue
		result.append(body)
	for decoy: ForkDecoy in ForkDecoy.live_decoys(get_tree()):
		if _in_sanctuary(decoy.global_position):
			continue
		if decoy.global_position.distance_to(global_position) > decoy.lure_radius:
			continue
		result.append(decoy)
	return result


## The backdoor node room is safe ground by design (DESIGN.md: the sanctuary is
## the reward for reaching a node). Nothing hostile targets anything inside it.
func _in_sanctuary(where: Vector3) -> bool:
	if graph == null or not graph.is_backdoor:
		return false
	return graph.region_of(where) == graph.shaft_index


## Nearest running player within `range_limit` with line of sight, or null.
func _nearest_player(range_limit: float, require_los: bool = true) -> Node3D:
	var best: Node3D = null
	var best_distance: float = range_limit
	for body: Node3D in _running_players():
		var distance: float = body.global_position.distance_to(global_position)
		if distance >= best_distance:
			continue
		if require_los and not _has_los(body):
			continue
		best_distance = distance
		best = body
	return best


## Where this creature looks from. A Scrubber's sensor is at ankle height and a
## Sentinel's head is above the racking, and they should not agree about what
## counts as cover — the difference is most of why you can crawl past one and
## not the other.
func _eye_height() -> float:
	return 0.8


func _has_los(body: Node3D) -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return true
	var from: Vector3 = global_position + Vector3.UP * _eye_height()
	var to: Vector3 = body.global_position + Vector3.UP * 1.2
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = WORLD_MASK
	return space.intersect_ray(query).is_empty()


## Is this creature standing in light a player made? A beam cone with line of
## sight, or the radius of a burning flare. THE Scrubber mechanic, and the reason
## the breaker is not the only answer to one.
func _in_player_light() -> bool:
	for node: Node in get_tree().get_nodes_in_group("flares"):
		var flare: Flare = node as Flare
		if flare == null or not is_instance_valid(flare) or not flare.is_burning():
			continue
		if flare.global_position.distance_to(global_position) <= Balance.FLARE_REPEL_RADIUS:
			return true

	# The cone is per player, because Optics buys it. A crewmate three tiers into
	# the track is holding a visibly wider, longer beam, and this is where that
	# purchase turns into "the pack will not come near them".
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not Run.is_running(peer):
			continue
		var loadout: Dictionary = Modules.loadout(peer)
		var limit: float = cos(deg_to_rad(float(loadout["beam_cone_deg"])))
		var node: Node = Net.get_player(peer)
		if node == null or not is_instance_valid(node):
			continue
		var player: Player = node as Player
		if player == null or not player.sync_beam:
			continue

		var eye: Vector3 = player.global_position + Vector3.UP * PLAYER_EYE
		var to_self: Vector3 = (global_position + Vector3.UP * 0.5) - eye
		var distance: float = to_self.length()
		if distance > float(loadout["beam_expose"]) or distance < 0.01:
			continue
		if (to_self / distance).dot(_beam_direction(player)) < limit:
			continue
		if not _has_los(player):
			continue
		return true
	return false


## Where a player's beam points, from the replicated pose rather than the node's
## smoothed transform: on the host a remote crewmate's head is still easing
## toward its last packet, and exposure should follow what they are actually
## looking at.
static func _beam_direction(player: Player) -> Vector3:
	var yaw: float = player.sync_yaw
	var pitch: float = player.sync_pitch
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


# ------------------------------------------------------------------- combat --

## What the breaker is pointing at, or null. Shared by the shooter (drawing its
## own lash the frame it fires) and the host (deciding what actually died), so
## the streak and the kill can never disagree about which creature was in the
## way. Walls win: nothing behind cover is cuttable.
## `reach` is the shooter's Breaker range (Modules), passed in rather than read
## from Balance so the shooter's predicted lash and the host's authoritative
## re-cast use the same number for the same player.
static func pick_target(tree: SceneTree, space: PhysicsDirectSpaceState3D,
		origin: Vector3, direction: Vector3,
		reach: float = Balance.BREAKER_RANGE) -> Antivirus:
	if tree == null:
		return null
	var aim: Vector3 = direction.normalized()
	var limit: float = cos(deg_to_rad(Balance.BREAKER_AIM_DEG))

	var best: Antivirus = null
	var best_dot: float = limit
	for node: Node in tree.get_nodes_in_group(GROUP):
		var creature: Antivirus = node as Antivirus
		if creature == null or not is_instance_valid(creature) or creature._dying:
			continue
		var to_creature: Vector3 = creature.aim_point() - origin
		var distance: float = to_creature.length()
		if distance > reach or distance < 0.01:
			continue
		var alignment: float = (to_creature / distance).dot(aim)
		if alignment <= best_dot:
			continue
		if space != null:
			var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
					origin, creature.aim_point())
			query.collision_mask = WORLD_MASK
			if not space.intersect_ray(query).is_empty():
				continue
		best_dot = alignment
		best = creature
	return best


## Where the cutter aims at this creature. Subclasses that are not knee-high
## override it.
func aim_point() -> Vector3:
	return global_position + Vector3.UP * 0.5


## Host-side. THE door every hostile hit in the game goes through.
##
## M7 introduces it because three things now sit between "a process swung" and
## "a crewmate lost integrity", and each of the five creatures used to open that
## door itself with a bare `Run.damage_player(int(String(body.name)), …)`. That
## spelling was fine while the only thing a creature could ever be swinging at was
## a player; it is actively dangerous the moment a FORK DECOY is a legitimate
## target, because `int("ForkDecoy_3")` is 0 and peer 0 is not a peer — it would
## have written integrity for a crew member who does not exist.
##
## So the question is asked once, here, in order:
##
##   1. **Is it a fork?** Then nothing takes damage. The decoy soaks a strike and
##      may decompile early; that is the whole of its interaction with combat.
##   2. **Is the target inside SURGE STEP's i-frames?** Then the blow misses. The
##      Hound learns nothing from a dash — it just misses.
##   3. **Is there a CHECKSUM BARRIER over them?** Then the shell takes what it
##      can and only the remainder lands. Crew inside somebody else's shell are
##      covered too; that is the co-op play.
##   4. Otherwise it is a hit, through `Run.damage_player` exactly as before —
##      still the single door integrity leaves by.
func _land_hit(body: Node3D, amount: float) -> void:
	if not _is_host or body == null or not is_instance_valid(body) or amount <= 0.0:
		return

	var decoy: ForkDecoy = body as ForkDecoy
	if decoy != null:
		Subs.report_decoy_strike(decoy)
		return

	var player: Player = body as Player
	if player == null:
		return
	if Subs.invulnerable(player.peer_id):
		if Debug.log_ai:
			print("[AI] %s struck %s during a surge step — missed" % [
				String(name), Net.crew_name(player.peer_id)])
		return

	var landed: float = amount
	var barrier: ChecksumBarrier = ChecksumBarrier.covering(get_tree(),
			player.global_position)
	if barrier != null:
		landed = barrier.take(amount)
		Subs.report_barrier_absorb(barrier)
	if landed <= 0.0:
		return
	Run.damage_player(player.peer_id, landed, global_position)


## Host-side. Everything hostile is killable; what varies is how much a given
## shot is worth against it (see `breaker_damage`).
func take_damage(amount: float, _from: Vector3) -> void:
	if not _is_host or _dying or amount <= 0.0:
		return
	health -= amount
	# PT1: publish the wound before the subclass reacts to it, so a hunter that
	# changes state on being hit cannot land its packet ahead of the number the
	# integrity readout is about to draw.
	sync_integrity = clampf(health / maxf(health_max, 0.001), 0.0, 1.0)
	_on_hurt()
	if health <= 0.0:
		kill()


## Sets the starting health and remembers it as the maximum. Every subclass rolls
## its own health off `Balance` at spawn; routing it through here is what lets the
## integrity readout report a FRACTION without each of them publishing a ceiling.
func set_health(value: float) -> void:
	health = value
	health_max = maxf(value, 0.001)
	sync_integrity = 1.0


## 0..1 hit flash, ALREADY capped. The only legal way to read it.
func hurt_flash() -> float:
	return _hurt_flash * A11y.flash_scale


## One landed cut. Runs on every peer (the host directly, clients through each
## subclass's `_hit` relay), so the rate cap is enforced on every screen against
## that screen's own clock rather than trusting a packet order.
func trigger_hurt_flash() -> void:
	if _since_hurt_flash < HURT_FLASH_MIN_INTERVAL:
		return
	_since_hurt_flash = 0.0
	_hurt_flash = 1.0


## Called from each subclass's visual tick with its own decay rate.
func decay_hurt_flash(delta: float, rate: float) -> void:
	_since_hurt_flash += delta
	_hurt_flash = maxf(_hurt_flash - delta * rate, 0.0)


## Host-side death. Flips the streamed flag and plays the shatter locally; every
## peer that can see this creature does the same a packet later, and each frees
## its own copy when its animation is done.
func kill() -> void:
	if _dying:
		return
	sync_dead = true
	_begin_death()


## What one breaker shot from `from` does to this creature. Armoured processes
## override it to make where you are standing matter — nothing in NULLVOID is
## immune to the cutter, but not everything takes the same damage from it.
func breaker_damage(_from: Vector3, base: float = Balance.BREAKER_DAMAGE) -> float:
	return base


## Subclass hook: a hit landed (host only).
func _on_hurt() -> void:
	pass


## Sends a cosmetic event to every peer whose world is already standing. A plain
## `rpc()` would also reach a peer that is still loading its layer, where the
## node this method lives on does not exist yet — and that is an engine error on
## the receiving side, not a dropped packet. The crew roster is the same gate the
## synchronizers use.
func _tell_crew(method: StringName) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if peer != 1:
			rpc_id(peer, method)


## Subclass hook: something loud happened at `where`. Host only.
##
## `rooms` is how far the sound carried, in rooms of the layer graph, and
## `seconds` is how long it should hold this creature's attention. M2's siphon
## ping was the only caller and hard-coded both; M4.8 routes five different
## noises through `Noise` (rewires, welds, cabinet cuts, terminal queries, kicked
## debris) at three different reaches, so the numbers travel with the sound.
##
## The defaults are the siphon's, which keeps every existing call site honest.
func alert(_where: Vector3, _rooms: int = Balance.TAP_ALERT_ROOMS,
		_seconds: float = Balance.TAP_ALERT_TIME) -> void:
	pass


func _begin_death() -> void:
	_dying = true
	collision_layer = 0
	collision_mask = 0
	died.emit()
	_play_death()


## Subclass hook: the shatter. Must free the node when it is done.
func _play_death() -> void:
	queue_free()


## Called by the director on descent. Silent and immediate — the layer is being
## rewritten and nobody should see a death animation for it.
func despawn() -> void:
	_dying = true
	queue_free()
