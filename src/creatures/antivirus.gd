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

# --- host sim ---------------------------------------------------------------

var health: float = 100.0
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
	config.add_property(NodePath(".:sync_state"))
	config.property_set_spawn(NodePath(".:sync_state"), true)
	config.property_set_replication_mode(NodePath(".:sync_state"),
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
	if not _is_host:
		_smooth_remote(delta)
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


## Waypoint on the way to `target`: straight at it while sharing a room, and at
## the connecting corridor's centre otherwise. Recomputed as rooms change, so a
## chase around a loop re-routes without any path bookkeeping.
func _route_to(target: Vector3) -> Vector3:
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
	# Once through the corridor mouth, aim at the room beyond it rather than
	# standing in the doorway re-deciding.
	if Vector2(door.x - global_position.x, door.z - global_position.z).length() \
			< WAYPOINT_RADIUS:
		return graph.centre_of(hop)
	return door


# -------------------------------------------------------------------- senses --

## Living, running crew, as bodies. Corrupted crewmates are on the floor and
## corpses do not get hunted — DESIGN.md's restore window would be worthless if a
## pack camped the body — and anyone stood in a backdoor sanctuary is off the
## board entirely: antivirus does not go in there.
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


## Host-side. Everything hostile is killable; what varies is how much a given
## shot is worth against it (see `breaker_damage`).
func take_damage(amount: float, _from: Vector3) -> void:
	if not _is_host or _dying or amount <= 0.0:
		return
	health -= amount
	_on_hurt()
	if health <= 0.0:
		kill()


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


## Subclass hook: something loud happened at `where` — a drained siphon tap, by
## default. Host only.
func alert(_where: Vector3) -> void:
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
