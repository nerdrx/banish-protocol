extends Node
## NoiseBus — the one place in the game where something says "I just made a sound".
##
## M2 shipped this as a single signal on a single prop: `SiphonTap.antivirus_ping`,
## which the antivirus director connected to by walking the `siphon_taps` group.
## That was correct for exactly one noise source. M4.8 adds four more (rewiring a
## junction, cutting a cabinet lock, a terminal query, kicked debris) and M6's
## Hound is specified as *spawned by noise debt* — so the fan-out becomes a
## service instead of a wire between two specific classes.
##
## ## The contract
##
##   NoiseBus.ping(where, rooms, source)
##
## `rooms` is reach in **rooms of the layer graph**, not metres, because that is
## the unit the antivirus has thought in since M3 (`LayerGraph.room_distance`)
## and because metres through a slab are a lie: sound in this building travels
## down corridors. 0 means "this room only". `source` is a short tag for logs and
## for anything that later wants to care *what* it heard.
##
## ## Who may call it, and where it takes effect
##
## Anyone may call it; it emits locally on the peer that did. Acting on it is a
## simulation decision, so every listener that changes the world checks
## `multiplayer.is_server()` for itself — the same shape `AntivirusDirector`
## already used for the tap ping. That means:
##
##   * host-side events (a validated rewire, a validated weld) ping on the host
##     and the pack converges;
##   * peer-local cosmetic events (a piece of debris a client's physics kicked)
##     ping on that client, where nothing hostile is listening, and cost nothing.
##
## Nothing here replicates. A noise event that mattered came from an RPC that had
## already been validated, and adding a second packet for the sound of it would
## be paying twice for the same fact.

## Something was heard at `where`, audible `rooms` rooms away. Connected by the
## antivirus director today; M6's Director and the Hound's noise-debt budget are
## the reason it is a signal on an autoload rather than a method call.
signal heard(where: Vector3, rooms: int, source: String, seconds: float)

## M11. The same event, carried as one record with everything a graded sense
## needs: intensity, the emitter (so a creature never hears itself), and the
## timestamp that makes a NOISE TRAIL possible.
##
## A second signal rather than more arguments on the first, because `heard` has
## two subscribers with settled semantics and a signal's arity is an interface.
## Anything that only wants "something was loud over there" keeps using `heard`;
## anything that wants to BELIEVE something about it uses this.
signal heard_event(event: Dictionary)

## Running tally of noise made on this layer, in room-reach units. Nothing
## consumes it yet — it is the number M6's "spawned by noise debt" will be a
## function of, and it costs one addition to keep honest from the start.
var debt: float = 0.0

## M11. The last few noise events on this layer, newest last. THE HOUND'S TRAIL:
## a tracker doctrine needs more than the loudest recent thing, it needs the
## sequence, so it can walk a crew's noise backwards when it loses them.
##
## Bounded and cleared on descent. Deliberately NOT replicated and NOT a memory —
## it is the layer's own recent history, and what any given creature actually
## KNOWS about it is filtered by that creature's own ears in `Antivirus.hear`.
const TRAIL_MAX: int = 8
var trail: Array[Dictionary] = []


func _ready() -> void:
	Run.layer_changed.connect(_on_layer_changed)


func _on_layer_changed(_number: int) -> void:
	debt = 0.0
	trail.clear()


## Make a sound. `seconds` is how long it should hold a listener's attention;
## the default is the siphon's, which is the loudest thing in the game.
##
## M11 adds two optional facts, both defaulted so no existing call site changes:
## `intensity` (0..1 — how much the sound TELLS you, as opposed to how far it
## carried, which is `rooms`) and `emitter` (so a creature that screams does not
## then investigate its own scream). An intensity of -1 looks the source up in
## `Balance.AI_NOISE_INTENSITY`, which is where the table of how loud the world's
## noises are actually lives.
func ping(where: Vector3, rooms: int, source: String,
		seconds: float = Balance.TAP_ALERT_TIME,
		intensity: float = -1.0, emitter: Node = null) -> void:
	debt += float(maxi(rooms, 0)) + 1.0
	var loudness: float = intensity
	if loudness < 0.0:
		loudness = float(Balance.AI_NOISE_INTENSITY.get(source, Balance.AI_NOISE_DEFAULT))
	if Debug.log_ai:
		print("[Noise] %s at %s reach=%d rooms hold=%.0fs int=%.2f debt=%.0f" % [
			source, str(where.snapped(Vector3.ONE * 0.1)), rooms, seconds, loudness, debt])
	var event: Dictionary = {
		"where": where,
		"rooms": rooms,
		"source": source,
		"seconds": seconds,
		"intensity": clampf(loudness, 0.0, 1.0),
		"emitter": emitter,
		"at": float(Time.get_ticks_msec()) / 1000.0,
	}
	trail.append(event)
	while trail.size() > TRAIL_MAX:
		trail.remove_at(0)
	heard.emit(where, rooms, source, seconds)
	heard_event.emit(event)


## The most recent `count` noise events, newest first. The Hound reads this when
## it has lost contact: the crew's own noise history is the trail it follows.
func recent(count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var i: int = trail.size() - 1
	while i >= 0 and out.size() < count:
		out.append(trail[i])
		i -= 1
	return out
