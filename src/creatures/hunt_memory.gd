class_name HuntMemory
extends RefCounted
## M11 — what one process remembers. PER-CREATURE, BOUNDED, AND FORGETTABLE.
##
## The single most important thing about this class is what it is NOT: it is not
## a global tracker. Every hunter owns its own instance, nothing writes into
## another creature's copy, and every field in it decays. A shared memory would be
## telepathy wearing a data structure, and telepathy is the exact failure the
## diegetic-coordination rule exists to prevent — if two creatures know the same
## thing, the player must have been able to watch the second one find out.
##
## Four things live here, and each answers a specific way the M10 AI felt stupid:
##
##   * **Last-known position with confidence decay.** "It knows where you were"
##     is what makes a chase survivable and a search frightening. Confidence bleeds
##     with time, so the creature's belief about where you are gets vaguer — and
##     the search radius grows with the vagueness, which is the correct and much
##     nastier behaviour: the longer you hide, the wider it looks.
##
##   * **Recently-searched spots.** Without this a searching creature ping-pongs
##     between the same two corners forever, which is worse than not searching at
##     all because the player can watch it be stupid. Bounded ring, entries expire.
##
##   * **Hot zones.** A room where the crew keeps making noise draws more
##     attention over a run. This is the only memory that persists across a single
##     contact, and it is what makes a siphon you tapped ten minutes ago still a
##     bad place to stand.
##
##   * **Escape adaptation.** If the crew always breaks contact the same way —
##     always dropping off a ledge, always cutting the same kind of corner — a
##     hunter starts checking that option sooner. Small, hard-bounded, and always
##     announced by behaviour the player can read (it checks the ledge FIRST; it
##     does not gain a new sense).
##
## Pure data and pure arithmetic, so `--selftest` can drive a whole search to
## exhaustion headlessly and prove it TERMINATES — the one property of a search
## routine that a screenshot can never establish.

## How long a last-known position stays worth walking to, in seconds. Confidence
## falls linearly to zero across it.
const LKP_LIFETIME: float = 26.0

## Search radius around the LKP at full confidence and at none. The growth is the
## interesting half: a vague belief searches a WIDER area, so waiting a creature
## out in the next room over stops working the longer you wait.
const SEARCH_RADIUS_SURE: float = 6.0
const SEARCH_RADIUS_VAGUE: float = 18.0

## How close counts as "I have already checked there", and how long that lasts.
## The expiry matters: a creature that never re-checks anywhere would walk out of
## a room it swept twenty seconds ago and never come back, which is the same
## failure as never searching.
const SEARCHED_RADIUS: float = 4.0
const SEARCHED_TTL: float = 30.0
## Hard cap on remembered spots. Bounded memory is a correctness property, not an
## optimisation: an unbounded list is an unbounded per-tick loop.
const SEARCHED_MAX: int = 10

## Hot-zone heat added per noise event and lost per second. Tuned so a single can
## fades in under a minute and a siphon channel plus a firefight leaves a room
## warm for several.
const HOT_PER_EVENT: float = 0.35
const HOT_DECAY: float = 0.02
const HOT_MAX: float = 2.0

## Escape adaptation, hard-bounded at both ends. `ADAPT_MAX` is the ceiling on how
## much any single learned habit may bias a search, and it is deliberately small:
## the creature gets to check the ledge first, never to teleport to it.
const ADAPT_PER_EVENT: float = 0.22
const ADAPT_DECAY: float = 0.012
const ADAPT_MAX: float = 0.75

## FALSE DEPARTURES. It leaves, then comes back. The terror is in the
## POSSIBILITY, not the frequency — a creature that does this every time is a
## creature with a tell, and a tell is a solved puzzle. So: at most one per this
## many seconds, per creature, and only ever out of LOST.
const FALSE_DEPART_COOLDOWN: float = 75.0
const FALSE_DEPART_CHANCE: float = 0.35
## How long it commits to walking away before turning round.
const FALSE_DEPART_TIME: float = 5.5

var lkp: Vector3 = Vector3.INF
var lkp_age: float = 0.0
var lkp_room: int = -1

## [{pos: Vector3, age: float}], newest last, capped at SEARCHED_MAX.
var searched: Array[Dictionary] = []

## room index -> heat.
var hot: Dictionary = {}

## Learned escape habits. Keys are the two the layer geometry actually offers:
## "drop" (they went off a ledge or into a pit) and "corner" (they broke line of
## sight around architecture). Values are 0..ADAPT_MAX.
var adapt: Dictionary = {"drop": 0.0, "corner": 0.0}

var _false_depart_cooldown: float = 0.0


func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	if lkp != Vector3.INF:
		lkp_age += delta
		if lkp_age >= LKP_LIFETIME:
			lkp = Vector3.INF
			lkp_room = -1
	for i: int in range(searched.size() - 1, -1, -1):
		searched[i]["age"] = float(searched[i]["age"]) + delta
		if float(searched[i]["age"]) >= SEARCHED_TTL:
			searched.remove_at(i)
	for room: int in hot.keys():
		var heat: float = float(hot[room]) - HOT_DECAY * delta
		if heat <= 0.0:
			hot.erase(room)
		else:
			hot[room] = heat
	for habit: String in adapt.keys():
		adapt[habit] = maxf(float(adapt[habit]) - ADAPT_DECAY * delta, 0.0)
	_false_depart_cooldown = maxf(_false_depart_cooldown - delta, 0.0)


## New evidence about where a target is. Resets the search: a creature that has
## just seen you does not carry on checking the corner it was walking to.
func mark_seen(where: Vector3, room: int) -> void:
	lkp = where
	lkp_age = 0.0
	lkp_room = room
	searched.clear()


## Confidence in the last-known position, 1 at the moment of contact falling to 0
## at LKP_LIFETIME. Drives the search radius and the overlay's LKP ring.
func confidence() -> float:
	if lkp == Vector3.INF:
		return 0.0
	return clampf(1.0 - lkp_age / LKP_LIFETIME, 0.0, 1.0)


## How wide to search, given how sure it still is. Vague belief searches wider.
func search_radius() -> float:
	return lerpf(SEARCH_RADIUS_VAGUE, SEARCH_RADIUS_SURE, confidence())


func mark_searched(where: Vector3) -> void:
	for entry: Dictionary in searched:
		if Vector3(entry["pos"]).distance_to(where) <= SEARCHED_RADIUS:
			entry["age"] = 0.0
			return
	searched.append({"pos": where, "age": 0.0})
	while searched.size() > SEARCHED_MAX:
		searched.remove_at(0)


func was_searched(where: Vector3) -> bool:
	for entry: Dictionary in searched:
		if Vector3(entry["pos"]).distance_to(where) <= SEARCHED_RADIUS:
			return true
	return false


## THE SEARCH ITSELF, and the proof that it terminates.
##
## `candidates` are the plausible places a target could be — supplied by the
## creature from the LAYER, so verticality does real work here: perches, the far
## side of a gantry, the foot of a drop, a pit, the mouths of the corridors out.
## Each is scored, the best unsearched one wins, and every spot the creature
## reaches is marked. Because `searched` only forgets on a timer and candidates
## are finite, the pool strictly shrinks — so `Vector3.INF` (search exhausted) is
## reachable, and the LOST state cannot loop forever. `--selftest` drives exactly
## this to exhaustion.
##
## Scoring, in order of weight:
##   * near the last-known position, inside the confidence-scaled radius;
##   * cheap to get to from where the creature is standing;
##   * warm (this room has been noisy this run);
##   * matching whatever escape habit this creature has learned.
func next_search_spot(candidates: Array[Vector3], from: Vector3,
		kinds: Array[String] = []) -> Vector3:
	var anchor: Vector3 = lkp if lkp != Vector3.INF else from
	var radius: float = search_radius()
	var best: Vector3 = Vector3.INF
	var best_score: float = -1e9
	for i: int in candidates.size():
		var spot: Vector3 = candidates[i]
		if was_searched(spot):
			continue
		var to_anchor: float = spot.distance_to(anchor)
		if to_anchor > radius * 2.5:
			continue
		var score: float = 0.0
		score += 3.0 * clampf(1.0 - to_anchor / maxf(radius * 2.5, 0.001), 0.0, 1.0)
		score += 1.2 * clampf(1.0 - spot.distance_to(from) / 40.0, 0.0, 1.0)
		if i < kinds.size():
			score += 2.0 * float(adapt.get(kinds[i], 0.0))
		if score > best_score:
			best_score = score
			best = spot
	return best


## Something loud happened in `room`. Heat is the only memory that survives a
## whole contact, and it is what makes the crew's own noise history a place.
func warm(room: int, weight: float = 1.0) -> void:
	if room < 0:
		return
	hot[room] = minf(float(hot.get(room, 0.0)) + HOT_PER_EVENT * weight, HOT_MAX)


func heat_of(room: int) -> float:
	return float(hot.get(room, 0.0))


## The warmest room this creature knows about, or -1. Used when a hunter has
## nothing at all to go on: it drifts toward where the crew has been loud rather
## than wandering its home room, which is why a noisy crew gets haunted.
func hottest_room() -> int:
	var best: int = -1
	var best_heat: float = 0.0
	for room: int in hot.keys():
		var heat: float = float(hot[room])
		if heat > best_heat:
			best_heat = heat
			best = room
	return best


## LIGHT ADAPTATION. The crew broke contact by `habit` again. Bounded at
## ADAPT_MAX and bled off by `tick`, so a habit the crew stops using is forgotten
## — this is a lean, not a lesson.
func note_escape(habit: String) -> void:
	if not adapt.has(habit):
		return
	adapt[habit] = minf(float(adapt[habit]) + ADAPT_PER_EVENT, ADAPT_MAX)


func bias_of(habit: String) -> float:
	return float(adapt.get(habit, 0.0))


## Whether this creature may pull a FALSE DEPARTURE right now. Rate-limited hard;
## `roll` is supplied by the caller's own seeded generator so the behaviour is
## reproducible in a capture rather than a coin flip on wall time.
func may_false_depart(roll: float) -> bool:
	if _false_depart_cooldown > 0.0:
		return false
	if roll > FALSE_DEPART_CHANCE:
		return false
	_false_depart_cooldown = FALSE_DEPART_COOLDOWN
	return true


func forget() -> void:
	lkp = Vector3.INF
	lkp_age = 0.0
	lkp_room = -1
	searched.clear()
