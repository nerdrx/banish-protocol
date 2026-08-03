class_name LoreBag
extends RefCounted
## One pool's shuffled bag — the anti-repetition primitive.
##
## THE INVARIANT, stated once so the selftest and the simulation can both point
## at it: **a line cannot be heard twice until every other line in its pool has
## been heard.** Not "unlikely to repeat" — cannot. A weighted random draw, which
## is what the corpus shipped with, gives you a repeat inside the first handful
## of lines roughly half the time; over an hour it gives you the same six barks
## and a player who has stopped listening. A bag gives you the whole pool, in a
## different order every cycle, and the first repeat only after the pool is spent.
##
## Weights still matter, and this is the part worth reading. Weight does not mean
## "drawn more often" here (that would break the invariant); it means **drawn
## EARLIER**. The shuffle is an Efraimidis-Spirakis weighted sample without
## replacement — each id gets the key `randf() ** (1 / weight)` and the bag is
## sorted on it — so a weight-9 line reliably lands near the front of the cycle
## and a weight-2 line near the back. Over a long session every line is heard the
## same number of times; over a SHORT session (one intrusion, one bag) the player
## hears the strong ones. That is exactly the distribution the weights were
## authored for, and it is why they were not thrown away.
##
## The bag is depth-banded by its owner (see `LoreDirector._bag_key`), so the set
## of ids in it is fixed while it is being drawn from. A bag whose eligibility
## changed mid-cycle would make the invariant a lie.

## The ids still to be drawn this cycle, front first.
var queue: Array[String] = []
## Every id this bag cycles over, so it can refill itself without being told.
var ids: Array[String] = []
## id -> authored weight, for the refill sort.
var weights: Dictionary = {}
## Completed cycles. Reported by the simulation; nothing reads it in the game.
var cycles: int = 0
## The cycle the most recent successful `draw` belonged to.
##
## Not the same as `cycles`, and the difference is the whole reason this exists:
## the draw that EMPTIES the queue completes a cycle, so reading `cycles` after it
## returns the number of the cycle that is about to start, not the one the line
## came from. Stamping on that made the last line of every cycle look like a
## repeat of the first line of the next — sixteen false failures in a three-hour
## simulation, which is exactly what a real invariant break would have looked like.
var last_cycle: int = 0


func configure(pool_ids: Array[String], pool_weights: Dictionary) -> void:
	ids = pool_ids.duplicate()
	weights = pool_weights.duplicate()


func is_empty() -> bool:
	return ids.is_empty()


## Draw the first id the caller will accept. `accept` is given each candidate in
## bag order and returns whether the line can actually be spoken right now —
## the director uses it to skip lines whose {SLOT} it cannot fill.
##
## A rejected id is LEFT IN THE BAG at its position rather than discarded, which
## is the whole reason this takes a predicate instead of just popping: a line
## that needs {DEAD} must not burn its turn in the cycle on a run where nobody
## has died yet. It waits, near the front, until the fact it describes is true.
##
## Returns "" only when no id in the whole cycle is acceptable.
func draw(rng: RandomNumberGenerator, accept: Callable, avoid: Array[String]) -> String:
	if ids.is_empty():
		return ""
	if queue.is_empty():
		refill(rng, avoid)
	for pass_index: int in 2:
		for i: int in queue.size():
			var candidate: String = queue[i]
			if not bool(accept.call(candidate)):
				continue
			queue.remove_at(i)
			last_cycle = cycles
			if queue.is_empty():
				cycles += 1
			return candidate
		# Nothing in the remainder of this cycle was speakable. Start the next one
		# and try once more; the second pass sees the ids already spent this cycle.
		if pass_index == 0:
			cycles += 1
			refill(rng, avoid)
	return ""


## Reshuffle the whole pool. `avoid` — the globally most-recently-spoken ids —
## are pushed to the back of the new order rather than removed, so the line that
## closed the last intrusion cannot open the next one, and no line straddles a
## cycle boundary as an immediate repeat.
func refill(rng: RandomNumberGenerator, avoid: Array[String]) -> void:
	var keyed: Array[Dictionary] = []
	for id: String in ids:
		var w: float = maxf(float(weights.get(id, 1)), 0.01)
		# Efraimidis-Spirakis: pow(u, 1/w) sorted descending is a weighted sample
		# without replacement. High weight -> reliably early in the cycle.
		var u: float = maxf(rng.randf(), 0.000001)
		var key: float = pow(u, 1.0 / w)
		if avoid.has(id):
			# Demoted below every non-recent line, but still ordered among its peers.
			key -= 2.0
		keyed.append({"id": id, "key": key})
	keyed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["key"]) > float(b["key"]))
	queue.clear()
	for row: Dictionary in keyed:
		queue.append(String(row["id"]))


## The part worth persisting: where this bag is in its cycle. Saved and restored
## across runs so she does not restart every pool from the top each intrusion —
## the cheapest half of "she remembers".
func to_state() -> Array:
	var out: Array = []
	for id: String in queue:
		out.append(id)
	return out


func from_state(state: Array) -> void:
	queue.clear()
	for entry: Variant in state:
		var id: String = String(entry)
		# Drop ids the corpus no longer has, so an edited corpus cannot resurrect a
		# deleted line or wedge a bag on an id that will never be acceptable.
		if ids.has(id):
			queue.append(id)
