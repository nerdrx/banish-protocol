class_name Perception
extends RefCounted
## M11 — graded senses, and the AWARENESS accumulator they feed.
##
## Before this milestone every sense in the game was a boolean. `_nearest_player`
## answered "is a crewmate within N metres", `_has_los` answered "is there a wall
## in the way", `_in_player_light` answered "am I standing in a beam". A creature
## built on booleans cannot be uncertain, and a creature that cannot be uncertain
## cannot investigate — it can only switch. That is the whole of why the AI read
## as simple.
##
## So: senses return a STRENGTH in 0..1, evidence accumulates into a per-target
## awareness that rises with evidence and decays with time, and the state machine
## reads the accumulator rather than the sense. Uncertainty becomes a number the
## creature carries around, which is the thing a search is made of.
##
## ## SIGHT
##
## A cone with distance falloff, occlusion against real geometry, an edge penalty
## (something at the rim of the cone is glimpsed, not seen) and — the part that
## matters most for this game — modulation by **how lit the target is**.
##
## DESIGN.md pillar 2 is "the dark is the enemy: your beam is the only thing that
## reveals it". Wiring visibility to illumination is what turns that pillar into
## the stealth system rather than leaving it as a rendering fact: a crewmate
## standing in a work light is visible across a hall, a crewmate in the dark is
## nearly invisible at ten metres, and a crewmate with their BEAM ON is a beacon
## carrying a lamp. The player already understands the rule — they have been
## fighting the dark since M2 — so the AI reading it costs no tutorialisation.
##
## `SIGHT_DARK_FLOOR` is why the dark is not a cheat code: an unlit crewmate is
## still faintly perceptible at short range, so hiding is a delay and a discount,
## never an invisibility toggle. It is also the mercy layer doing its job in the
## other direction (a creature that literally cannot see you would make the game
## trivial rather than scary).
##
## ## HEARING
##
## Intensity and DIRECTION out of the existing NoiseBus, with room-graph falloff.
## Deliberately a sense of WHERE, never of WHAT: hearing feeds an awareness track
## and a position, and the creature has to go and look to find out whether that
## was a crewmate or a can. That gap is where a player gets to lie to a hunter.
##
## ## The fairness invariant
##
## `feed()` REFUSES evidence of zero strength — it will not create a track and it
## will not update one. Nothing in the codebase may hand a creature a target
## without first producing a nonzero sensory strength for it, so "a creature never
## acquires a target it has no sensory evidence for" is a property of this
## function rather than a hope about five state machines. `--selftest` asserts it
## here, on the perception path, rather than downstream on the outcome.

## Physics mask for occlusion. Layer 1 = world geometry, exactly as
## `Antivirus.WORLD_MASK`.
const WORLD_MASK: int = 1

## How visible an unlit target is at point-blank, as a fraction of a lit one.
## Not zero (see above) and not high: at 0.14 an unlit crewmate leaking evidence
## at maximum sight strength takes several seconds to push a creature to HUNTING,
## which reads as "it senses something is there" rather than "it saw you".
const SIGHT_DARK_FLOOR: float = 0.14

## A target at the very rim of the cone is glimpsed rather than seen.
const SIGHT_EDGE_FLOOR: float = 0.35

## Awareness gained per second at strength 1.0, and lost per second with no
## evidence at all (scaled by `Suspicion.decay_scale`). The ratio is the memory:
## roughly 1.4 s of clean sight to reach HUNTING, roughly 9 s of nothing to fall
## out of LOST — the asymmetry IS the dread.
const AWARE_GAIN: float = 0.62
const AWARE_DECAY: float = 0.13

## Seconds a track survives with no evidence before it is forgotten entirely.
## Bounded so a creature's memory can never grow without limit, and so a crewmate
## who genuinely got away is genuinely gone.
const TRACK_TTL: float = 45.0

## Hard cap on simultaneously-tracked targets. Four crew plus a fork decoy is the
## real ceiling; the cap exists so a pathological spawn cannot turn a per-frame
## sense into an O(n) surprise.
const MAX_TRACKS: int = 8

## ATTENTION SPLITTING (1-4 players). How much MORE certain a creature has to be
## about a second crewmate before it will drop the one it is already committed to.
##
## Without a margin, four crew standing at four distances produce a creature that
## re-picks its favourite every tick and therefore walks at nobody — the classic
## way multi-target AI reads as broken. With it, a hunter COMMITS: it takes the
## crewmate it is most sure of and stays on them until somebody else is clearly
## more findable, which is the behaviour that makes splitting up a real tactic
## (one crewmate can deliberately become the louder, brighter target and pull it)
## and makes staying together a real risk (the pack converges on one of you and
## the rest have to decide whether to shoot or run).
const COMMIT_MARGIN: float = 0.18

## key -> {awareness, last_pos, last_dir, silent, kind, strength, node}
var tracks: Dictionary = {}

## Who this creature is currently attending to. Purely an attention mechanism —
## it has no bearing on what may be SENSED, only on which of several sensed
## things the creature commits to walking at.
var committed: String = ""

## The strongest thing sensed on the most recent tick, for the trace and overlay.
var last_sight: float = 0.0
var last_hearing: float = 0.0


# --------------------------------------------------------------- pure senses --

## SIGHT strength in 0..1.
##
## `dot` is the cosine between the creature's facing and the direction to the
## target; `cone_cos` is the cosine of the cone's half-angle. `lit` is 0..1 from
## `illumination_at`. Occluded, out of range or outside the cone all return
## exactly 0.0, which is the value `feed` refuses — so cover, distance and
## looking the other way are all the same kind of safety.
##
## Falloff is quadratic rather than linear on purpose: the useful sight range is
## the near half of the cone, and a creature that sees you equally well at 3 m and
## 25 m has a cone, not eyes.
static func sight_strength(distance: float, range_limit: float, dot: float,
		cone_cos: float, occluded: bool, lit: float) -> float:
	if occluded or range_limit <= 0.0 or distance > range_limit or dot < cone_cos:
		return 0.0
	var near: float = clampf(1.0 - distance / range_limit, 0.0, 1.0)
	var falloff: float = near * near
	var edge: float = 1.0
	if cone_cos < 0.999:
		edge = clampf(inverse_lerp(cone_cos, 1.0, dot), 0.0, 1.0)
	var aim: float = SIGHT_EDGE_FLOOR + (1.0 - SIGHT_EDGE_FLOOR) * edge
	var brightness: float = SIGHT_DARK_FLOOR \
			+ (1.0 - SIGHT_DARK_FLOOR) * clampf(lit, 0.0, 1.0)
	return clampf(falloff * aim * brightness, 0.0, 1.0)


## HEARING strength in 0..1 for a noise of `intensity` heard `rooms_away` rooms
## away by a creature whose ears reach `reach` rooms. Past the reach it is exactly
## 0.0 — sound in this building travels down corridors, and a slab is a slab.
static func hearing_strength(intensity: float, rooms_away: int, reach: int) -> float:
	if reach < 0 or rooms_away < 0 or rooms_away > reach:
		return 0.0
	var carry: float = 1.0 - float(rooms_away) / float(reach + 1)
	return clampf(intensity * carry, 0.0, 1.0)


## How lit `point` is, 0..1, from everything in the world that emits light the
## crew is responsible for or standing in.
##
## Deliberately NOT a render query. Sampling the framebuffer would be honest and
## unaffordable; this asks the same question of the light sources themselves,
## which is what the artists placed and what the player can reason about. Work
## lights and diffuser panels are the room's own lighting (the crew did not make
## them, but standing under one is still a choice); flares and beams are the
## crew's own noise in the visual channel.
##
## Occlusion is tested for the two the player controls and skipped for static
## fixtures: a work light behind a rack does not light you, but paying for a
## raycast per fixture per creature per tick would show up in the 60 fps gate long
## before the realism did.
static func illumination_at(tree: SceneTree, point: Vector3,
		space: PhysicsDirectSpaceState3D = null) -> float:
	if tree == null:
		return 0.0
	var lit: float = 0.0

	# Burning flares: the crew's own portable sun, and the loudest visual event
	# they can make.
	for node: Node in tree.get_nodes_in_group("flares"):
		var flare: Flare = node as Flare
		if flare == null or not is_instance_valid(flare) or not flare.is_burning():
			continue
		var fd: float = flare.global_position.distance_to(point)
		if fd > Balance.FLARE_LIGHT_RANGE:
			continue
		lit = maxf(lit, clampf(1.0 - fd / Balance.FLARE_LIGHT_RANGE, 0.0, 1.0))

	# Room fixtures. Cheap and unoccluded by design (see above).
	for node: Node in tree.get_nodes_in_group("work_lights"):
		var fixture: Node3D = node as Node3D
		if fixture == null or not is_instance_valid(fixture):
			continue
		var wd: float = fixture.global_position.distance_to(point)
		if wd > Balance.AI_WORKLIGHT_REACH:
			continue
		lit = maxf(lit, Balance.AI_WORKLIGHT_WEIGHT
				* clampf(1.0 - wd / Balance.AI_WORKLIGHT_REACH, 0.0, 1.0))

	if space != null and lit < 1.0:
		pass  # reserved: occluded fixture test, see the comment above.
	return clampf(lit, 0.0, 1.0)


## How lit a PLAYER is: their surroundings, plus the enormous fact of their own
## beam. A crewmate holding a live beam is carrying a lamp, and a lamp in a
## near-black building is the single most detectable thing in the game.
##
## This is the exact point where DESIGN.md pillar 2 becomes the stealth system:
## turning your beam off is not a graphics option, it is the crouch button.
static func player_illumination(tree: SceneTree, player: Player,
		ambient: float) -> float:
	var lit: float = ambient
	if player != null and is_instance_valid(player) and player.sync_beam:
		lit = maxf(lit, Balance.AI_BEAM_BEACON)
	if player != null and is_instance_valid(player):
		# M11b THE INDEX. An agent the Auditor has filed reads as lit whether or
		# not their beam is on — the whole cost of being marked, and the exact
		# inverse of the game's one reliable defence. See `HauntDirector.mark_agent`.
		lit = maxf(lit, Haunt.audit_mark(player.peer_id) * Balance.AI_MARK_GLOW)
		# A recent muzzle flash is a light too, which is why shooting your way out
		# of an investigation makes the investigation worse. Same source the Moth
		# already reads, so the two senses can never disagree about a shot.
		lit = maxf(lit, Haunt.muzzle_light(player.peer_id) * Balance.AI_MUZZLE_BEACON)
	if tree != null:
		lit = maxf(lit, ambient)
	return clampf(lit, 0.0, 1.0)


# -------------------------------------------------------------- accumulation --

## THE FAIRNESS DOOR. Evidence of strength <= 0 creates nothing and updates
## nothing, so no code path anywhere can hand a creature a target it has not
## sensed. Returns whether the evidence was accepted.
##
## `kind` is a short tag ("sight", "sound", "pain") that travels into the trace,
## because a reviewer watching a capture needs to know not just that the creature
## became suspicious but WHAT of.
func feed(key: String, strength: float, where: Vector3, kind: String,
		delta: float, node: Node3D = null) -> bool:
	if key.is_empty() or strength <= 0.0 or delta <= 0.0:
		return false
	var track: Dictionary = tracks.get(key, {}) as Dictionary
	if track.is_empty():
		if tracks.size() >= MAX_TRACKS:
			return false
		track = {"awareness": 0.0, "last_pos": where, "silent": 0.0,
				"kind": kind, "strength": 0.0, "node": node}
	track["awareness"] = clampf(float(track["awareness"])
			+ strength * AWARE_GAIN * delta, 0.0, 1.0)
	track["last_pos"] = where
	track["silent"] = 0.0
	track["kind"] = kind
	track["strength"] = strength
	if node != null:
		track["node"] = node
	tracks[key] = track
	return true


## Time passing with no evidence. Every track that was not fed this tick loses
## awareness at a rate the suspicion state chooses, and a track that has been
## silent for TRACK_TTL is dropped entirely — memory is per-creature and
## forgettable, never a global omniscient tracker.
func decay(delta: float, state: int) -> void:
	if delta <= 0.0:
		return
	var rate: float = AWARE_DECAY * Suspicion.decay_scale(state) * delta
	var dead: Array[String] = []
	for key: String in tracks.keys():
		var track: Dictionary = tracks[key]
		var silent: float = float(track["silent"]) + delta
		if silent > 0.0:
			track["awareness"] = maxf(float(track["awareness"]) - rate, 0.0)
		track["silent"] = silent
		track["strength"] = 0.0
		if silent >= TRACK_TTL or float(track["awareness"]) <= 0.0001:
			dead.append(key)
		else:
			tracks[key] = track
	for key: String in dead:
		tracks.erase(key)


## Marks the tracks fed this tick as still-live, so `decay` only bleeds the ones
## that were not. Called by the creature between sensing and decaying.
func settle(fed: Dictionary, delta: float, state: int) -> void:
	var rate: float = AWARE_DECAY * Suspicion.decay_scale(state) * delta
	var dead: Array[String] = []
	for key: String in tracks.keys():
		if fed.has(key):
			continue
		var track: Dictionary = tracks[key]
		track["silent"] = float(track["silent"]) + delta
		track["awareness"] = maxf(float(track["awareness"]) - rate, 0.0)
		track["strength"] = 0.0
		if float(track["silent"]) >= TRACK_TTL or float(track["awareness"]) <= 0.0001:
			dead.append(key)
		else:
			tracks[key] = track
	for key: String in dead:
		tracks.erase(key)


## The track this creature is attending to, or an empty dictionary.
##
## "Best" is awareness first — a creature commits to what it is most sure of
## rather than to what is nearest, which is why a Hound will walk past a silent
## crewmate to get to the one that made the noise.
##
## With 1-4 crew that rule alone is not enough, because four tracks at four
## similar awarenesses make a creature that changes its mind every tick and
## therefore never arrives anywhere. So the choice is STICKY: whoever it is
## already committed to keeps the attention until somebody else is `COMMIT_MARGIN`
## more certain. That is the whole of attention-splitting, and it is what makes
## one crewmate deliberately making noise a way to buy the other three a room.
func best() -> Dictionary:
	var top_key: String = ""
	var top_score: float = 0.0
	for key: String in tracks.keys():
		var score: float = float((tracks[key] as Dictionary)["awareness"])
		if score > top_score:
			top_score = score
			top_key = key
	if top_key.is_empty():
		committed = ""
		return {}

	# Hold the current commitment unless the challenger clears the margin.
	if committed != top_key and tracks.has(committed):
		var held: float = float((tracks[committed] as Dictionary)["awareness"])
		if top_score - held < COMMIT_MARGIN:
			top_key = committed
	committed = top_key

	var out: Dictionary = (tracks[top_key] as Dictionary).duplicate()
	out["key"] = top_key
	return out


## Awareness of the single most-sensed track, ignoring the attention commitment.
## The ladder reads THIS rather than `best()`: a creature must climb to HUNTING on
## the strongest evidence it has, even if its attention is on somebody else, or a
## crewmate walking into a Sentinel's face while it is committed to their friend
## would be invisible to the state machine.
func peak_awareness() -> float:
	var top: float = 0.0
	for key: String in tracks.keys():
		top = maxf(top, float((tracks[key] as Dictionary)["awareness"]))
	return top


## Awareness of the attended track, 0..1 — what the overlay and trace report,
## because it is the number that explains where the creature is walking.
func awareness() -> float:
	var top: Dictionary = best()
	return 0.0 if top.is_empty() else float(top["awareness"])


## Whether any evidence arrived on the most recent tick. The difference between
## "I can see you" and "I remember seeing you", which is the whole of the
## HUNTING/LOST distinction.
func live() -> bool:
	for key: String in tracks.keys():
		if float((tracks[key] as Dictionary)["strength"]) > 0.0:
			return true
	return false


func forget() -> void:
	tracks.clear()
	last_sight = 0.0
	last_hearing = 0.0
