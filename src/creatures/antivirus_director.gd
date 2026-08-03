class_name AntivirusDirector
extends Node
## Buys, builds and sweeps up MOTHER's antivirus for the current layer.
##
## Who decides what: *nothing about the roster of processes crosses the wire*.
## The positions are seeded content (LayerGraph resolves every nest and post, so
## a determinism dump covers them) and the purchase is a pure function of
## LayerParams.antivirus_budget, so every peer builds the same creatures in the
## same places at the same moment it builds the walls around them. Only what they
## are *doing* is replicated, through each creature's own synchronizer.
##
## That leaves exactly one thing a joining peer cannot work out for itself: which
## processes the crew has already killed. The host sends that list — a handful of
## node names — whenever the roster changes, and the joiner deletes them.
##
## Teardown is the other half of the job: a layer is rebuilt in place on every
## descent, so every creature has to be gone before the new one is written, and
## nothing may keep a reference to it afterwards. Because existence is local,
## each peer clears its own and no despawn packet can arrive late.

const SCRUBBER_COST: int = 1
const SENTINEL_COST: int = 3

## Where creatures are parented. A sibling of the geometry, so a rebuild does not
## take them with it — clearing them is explicit.
const CONTAINER: String = "../Antivirus"

var graph: LayerGraph = null

var _container: Node3D = null
var _layer_number: int = 0
var _log_clock: float = 0.0
## Host-side: names of everything killed on this layer, replayed to joiners.
var _dead: Array[String] = []

# --- directed spawns (trickle + M6 hunters) ---------------------------------
#
# Most creatures' existence is a pure function of the seed. Two are not: the M4.8
# reinforcement trickle (a function of the clock and of what the crew has welded)
# and the M6 hunters (a function of the Director's pacing). Both are *directed* —
# the host decides they exist and tells the crew — and both must be seen by a peer
# that JOINS after they spawned (the M3 mid-run join gauntlet). So the host keeps
# one record of every LIVING directed spawn and replays the whole set on a roster
# change (which is also the moment a joining peer's world comes up): build the ones
# you are missing, delete the ones I have killed. Before M6 the trickle had no such
# replay and was silently invisible to joiners; folding it in here fixed that.
## Host-side: {name, kind: "scrubber"|"hound"|"moth"|"auditor", nest, serial}.
var _directed: Array[Dictionary] = []

# --- reinforcement trickle (M4.8) -------------------------------------------
#
# Before this milestone a layer's antivirus was a single fixed purchase: kill it
# and the layer was clear forever, which made the nests scenery and made welding
# a vent shut a nice noise with no consequence attached.
#
# So MOTHER trickles. Slowly (Balance.TRICKLE_INTERVAL), from nests that still
# have an *unwelded* vent in them, and never past the budget the threat curve
# already authorised for this layer — so the trickle is pressure, not attrition,
# and it can never make a ring harder than LayerParams said it was.
#
# The one thing it costs in architecture: a trickled Scrubber is not seeded
# content (it depends on wall-clock time and on what the crew has welded), so
# unlike every other creature in the game its existence has to be replicated.
# That is one small reliable packet per spawn, host to crew.
var _trickle_clock: float = 0.0
## How many Scrubbers the layer's budget bought. The trickle refills toward this
## and never above it.
var _scrubber_cap: int = 0
## Serial for trickled creatures, so a replacement can never collide with the
## seeded slot it is refilling.
var _trickle_serial: int = 0


func _ready() -> void:
	add_to_group("antivirus_director")
	_container = get_node_or_null(CONTAINER) as Node3D
	Net.crew_changed.connect(_on_crew_changed)
	# M11 moves the fan-out onto the richer signal: `heard_event` carries the
	# intensity and the emitter as well as the position, which is what a GRADED
	# sense needs and what `heard` deliberately does not carry (its arity is an
	# interface with two other subscribers). Nothing else about the routing
	# changes — the director still offers every noise to every creature and every
	# creature decides for itself whether it heard it.
	NoiseBus.heard_event.connect(_on_noise_event)
	set_process(true)


func _on_crew_changed() -> void:
	for creature: Antivirus in _creatures():
		creature.refresh_visibility()
	# A roster change is also a peer's world coming up: replay the directed spawns
	# (living hunters to build, dead ones to delete) so a mid-run joiner sees
	# exactly what the crew is being hunted by, and a re-hosted layer stays honest.
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server() \
			and (not _dead.is_empty() or not _directed.is_empty()):
		_reconcile.rpc(_directed, _dead)


# -------------------------------------------------------------------- layer --

## Called by the Layer on every peer once its geometry is standing. Builds the
## layer's antivirus locally from the seeded slots.
func begin(layout: LayerGraph, layer_number: int) -> void:
	graph = layout
	_layer_number = layer_number
	_dead.clear()
	_directed.clear()
	_trickle_clock = Balance.TRICKLE_FIRST_DELAY
	_trickle_serial = 0
	_scrubber_cap = 0
	_by_net_id.clear()
	_relay_clock = 0.0

	if graph == null or Debug.no_antivirus or _container == null:
		return
	_purchase()


## Something in the layer was loud.
##
## M2 wired this straight from `SiphonTap.antivirus_ping` to the pack, because
## there was exactly one noise source. M4.8 has five and M6's Hound is specified
## as spawned by noise debt, so it all comes through `Noise` now — the tap still
## emits its own signal for anything that wants to listen specifically, and this
## handler no longer knows or cares what made the sound.
##
## Connected on every peer; host-only here, because alerting is a simulation
## decision and a client's local physics kicking a can is not one.
## M11: offers the whole event. The fan-out is unchanged in shape — every noise
## is offered to every process — but the DECISION about whether it was heard has
## moved into the creature, where it belongs: `Antivirus.hear` runs the room-graph
## falloff against that creature's own ears, feeds its own awareness track, warms
## its own hot-zone memory, and only then hands down to the M6 `alert()` override
## it always did. Nothing is shared between creatures; two Scrubbers hearing the
## same can arrive at two different beliefs about it.
func _on_noise_event(event: Dictionary) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	var reached: int = 0
	for creature: Antivirus in _creatures():
		creature.hear(event)
		reached += 1
	if Debug.log_ai:
		print("[AI] noise '%s' at %s (reach %d rooms, int %.2f) offered to %d processes" % [
			String(event["source"]), str(Vector3(event["where"]).snapped(Vector3.ONE * 0.1)),
			int(event["rooms"]), float(event["intensity"]), reached])


## Spends the layer's budget. Sentinels first — they are the expensive fixed
## defence and there are only ever one or two posts — then Scrubbers into every
## nest anchor the budget can afford. Pure: two peers running this on the same
## layer buy the same thing without talking to each other.
func _purchase() -> void:
	var params: Dictionary = LayerParams.of(_layer_number)
	var budget: int = int(params["antivirus_budget"])
	# M4.9 (balance lab): reserve a Scrubber floor before the Sentinels spend, so a
	# vault layer can never come out all-Sentinel-no-pack — the "swarm from the
	# dark" is the pillar, and a lone slow Sentinel with no cleaners around it is a
	# turret, not a threat. The reserve is released back into the Scrubber buy
	# below, so it is a FLOOR on Scrubbers, not a cap on anything; paired with the
	# +2 budget base (LayerParams) it adds early pack pressure rather than trading
	# the Sentinel away for it.
	var reserved: int = mini(2, budget)
	# Clamp the layer's Sentinel count to the posts the graph actually placed.
	var sentinels: int = mini(int(params["sentinel_count"]), graph.sentinel_posts.size())

	var placed_sentinels: int = 0
	for i: int in sentinels:
		# Sentinels spend only what is left ABOVE the reserve.
		if budget - reserved < SENTINEL_COST:
			break
		budget -= SENTINEL_COST
		_build(true, i)
		placed_sentinels += 1

	# Everything left — the reserve plus whatever the Sentinels did not spend —
	# becomes Scrubbers, one per point, clamped to the nests the layer has.
	var scrubbers: int = mini(budget, graph.scrubber_nests.size())
	for i: int in scrubbers:
		_build(false, i)
	_scrubber_cap = scrubbers

	print("[AI] layer %d antivirus: %d scrubbers, %d sentinels (budget %d, floor %d)" % [
		_layer_number, scrubbers, placed_sentinels, int(params["antivirus_budget"]), reserved])


func _build(is_sentinel: bool, slot: int, suffix: String = "") -> Antivirus:
	var creature: Antivirus = Sentinel.new() if is_sentinel else Scrubber.new()
	# The layer number is in the name so a creature from the layer above can
	# never collide with one from the layer below during a rebuild, and so the
	# host's "already dead" list is meaningful on the receiving peer.
	creature.name = "%s_L%d_%d%s" % ["Sentinel" if is_sentinel else "Scrubber",
			_layer_number, slot, suffix]

	var points: Array[Vector3] = graph.sentinel_posts if is_sentinel else graph.scrubber_nests
	var rooms: Array[int] = graph.sentinel_post_rooms if is_sentinel \
			else graph.scrubber_nest_rooms
	creature.setup(slot, points[slot], rooms[slot], _layer_number, graph)
	creature.died.connect(_on_creature_died.bind(String(creature.name)))
	_container.add_child(creature)
	return creature


# ----------------------------------------------------------------- trickle --

## MOTHER pushing another cleaner through a vent, once in a while.
##
## Host-only, and it will only ever refill toward the count the layer's own
## budget bought. Rooms whose ingress covers have been welded are skipped
## entirely once every vent in them is shut, which is the whole reason the weld
## exists — and each welded vent in a room that still has an open one slows that
## room down by TRICKLE_WELD_PENALTY, so a partial job is worth doing too.
func _tick_trickle(delta: float) -> void:
	if graph == null or Debug.no_antivirus or _container == null:
		return
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	if Run.run_over or Run.descending or _scrubber_cap <= 0:
		return

	_trickle_clock -= delta
	if _trickle_clock > 0.0:
		return
	_trickle_clock = Balance.TRICKLE_INTERVAL

	var living: int = 0
	for creature: Antivirus in _creatures():
		if creature is Scrubber:
			living += 1
	if living >= _scrubber_cap:
		return

	var slot: int = _pick_trickle_slot()
	if slot < 0:
		print("[AI] trickle held: every ingress cover on layer %d is welded" % _layer_number)
		return
	_trickle_serial += 1
	_trickle.rpc(slot, _trickle_serial)


## Which nest anchor MOTHER pushes through, or -1 if the crew has closed them
## all. Weighted by how open the room still is, and resolved with the layer's own
## seed plus the serial so the choice is stable to reason about in a log.
func _pick_trickle_slot() -> int:
	var candidates: Array[int] = []
	var weights: Array[float] = []
	var total: float = 0.0
	for i: int in graph.scrubber_nests.size():
		var room: int = graph.scrubber_nest_rooms[i]
		var open: int = 0
		var welded: int = 0
		for v: int in graph.vent_rooms.size():
			if graph.vent_rooms[v] != room:
				continue
			if Props.is_welded(v):
				welded += 1
			else:
				open += 1
		# A nest with vents and none of them open is shut. A nest the generator
		# never gave a vent to trickles at the base rate — it has ingress the crew
		# cannot see, which is fair and is also what stops the mechanic from
		# accidentally being "weld four things and the layer is over".
		if open == 0 and welded > 0:
			continue
		var weight: float = pow(Balance.TRICKLE_WELD_PENALTY, float(welded))
		candidates.append(i)
		weights.append(weight)
		total += weight
	if candidates.is_empty() or total <= 0.0:
		return -1

	var roll: float = fposmod(float(hash(str(_layer_number, ":trickle:",
			_trickle_serial)) % 10000) / 10000.0, 1.0) * total
	for i: int in candidates.size():
		roll -= weights[i]
		if roll <= 0.0:
			return candidates[i]
	return candidates[candidates.size() - 1]


## A reinforcement's existence crosses the wire (M4.8) — it is a function of the
## clock and of what the crew has welded, not of the seed. Like the M6 hunters it
## is a *directed* spawn, so it is recorded in `_directed` and replayed to a
## mid-run joiner by `_reconcile` — the two used to be separate mechanisms with
## different join semantics (the trickle silently invisible to joiners); they are
## one now.
@rpc("authority", "call_local", "reliable")
func _trickle(slot: int, serial: int) -> void:
	if graph == null or _container == null:
		return
	if slot < 0 or slot >= graph.scrubber_nests.size():
		return
	var creature: Antivirus = _build(false, slot, "_t%d" % serial)
	_record_directed(String(creature.name), "scrubber", slot, serial)
	print("[AI] reinforcement %d pushed into %s" % [
		serial, graph.room_name(graph.scrubber_nest_rooms[slot])])


func _on_creature_died(creature_name: String) -> void:
	# A directed spawn that dies drops out of the living set so a joiner never
	# rebuilds a dead hunter; runs on every peer so each keeps its own set honest.
	for i: int in range(_directed.size() - 1, -1, -1):
		if String(_directed[i]["name"]) == creature_name:
			_directed.remove_at(i)
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	if not _dead.has(creature_name):
		_dead.append(creature_name)


## Host-side catch-up for a peer that built this layer after the crew had already
## cut through some of it — now carrying the living directed spawns as well as the
## dead, so a joiner both builds the hunters it is missing and deletes the ones the
## crew already deleted. Idempotent, and sent to everyone rather than tracking who
## is new — it is a handful of records.
@rpc("authority", "call_remote", "reliable")
func _reconcile(alive: Array, dead: Array) -> void:
	if _container == null or graph == null:
		return
	for record: Dictionary in alive:
		var kind: String = String(record["kind"])
		var slot: int = int(record["nest"])
		var serial: int = int(record["serial"])
		if kind == "scrubber":
			# A trickled Scrubber: rebuild it if this peer is missing it. Same
			# idempotency guard `_build_hunter` uses, since a live trickle packet and
			# a reconcile can race.
			var nm: String = "Scrubber_L%d_%d_t%d" % [_layer_number, slot, serial]
			if _container.get_node_or_null(NodePath(nm)) == null \
					and slot >= 0 and slot < graph.scrubber_nests.size():
				var built: Antivirus = _build(false, slot, "_t%d" % serial)
				_record_directed(String(built.name), "scrubber", slot, serial)
		else:
			_build_hunter(StringName(kind), slot, serial)
	for entry: String in dead:
		var node: Node = _container.get_node_or_null(NodePath(entry))
		if node != null and is_instance_valid(node):
			node.queue_free()


# ----------------------------------------------------------------- hunters --

## Build a directed hunter and replicate it. Called by the HauntDirector on the
## host; returns the host's own copy so the Director can vector a fresh Hound at
## the noise that drew it. The build itself goes out reliably to the crew, exactly
## like a trickled Scrubber's existence.
func spawn_hunter(kind: StringName, nest: int, serial: int) -> Hunter:
	var node: Hunter = _build_hunter(kind, nest, serial)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_spawn_hunter_net.rpc(String(kind), nest, serial)
	return node


## Remote half of a directed hunter spawn — build only, no reply.
@rpc("authority", "call_remote", "reliable")
func _spawn_hunter_net(kind: String, nest: int, serial: int) -> void:
	_build_hunter(StringName(kind), nest, serial)


## Builds one hunter at a seeded nest, idempotently (a reconcile and a live spawn
## packet can race). Records it in the living set so a later joiner is told about
## it. The `serial` is the creature's slot index too, so its per-instance RNG seed
## and its music-duck key are unique across a layer.
func _build_hunter(kind: StringName, nest: int, serial: int) -> Hunter:
	if graph == null or _container == null or Debug.no_antivirus:
		return null
	if graph.hunter_nests.is_empty():
		return null
	var slot: int = clampi(nest, 0, graph.hunter_nests.size() - 1)
	var label: String = ""
	var creature: Hunter = null
	match kind:
		&"hound":
			creature = Hound.new()
			label = "Hound"
		&"moth":
			creature = Moth.new()
			label = "Moth"
		&"auditor":
			creature = Auditor.new()
			label = "Auditor"
		_:
			return null
	var creature_name: String = "%s_L%d_%d_d%d" % [label, _layer_number, slot, serial]
	var existing: Node = _container.get_node_or_null(NodePath(creature_name))
	if existing != null and is_instance_valid(existing):
		return existing as Hunter
	creature.name = creature_name
	creature.setup(serial, graph.hunter_nests[slot], graph.hunter_nest_rooms[slot],
			_layer_number, graph)
	creature.died.connect(_on_creature_died.bind(creature_name))
	_container.add_child(creature)
	_record_directed(creature_name, String(kind), slot, serial)
	return creature as Hunter


## Record a directed spawn (trickle or hunter) in the living set, once. Kept on
## every peer so each has its own honest set, and the host has the authoritative
## copy to replay to a joiner in `_reconcile`.
func _record_directed(creature_name: String, kind: String, slot: int, serial: int) -> void:
	for record: Dictionary in _directed:
		if String(record["name"]) == creature_name:
			return
	_directed.append({"name": creature_name, "kind": kind, "nest": slot, "serial": serial})


# ----------------------------------------------------------------- teardown --

## Descent starts a rebuild of the whole layer. Everything hostile has to be gone
## before the new geometry is written, or a Scrubber ends up hunting through
## walls that no longer exist. Every peer clears its own, so nothing is in flight.
##
## Called by `Layer._descend` rather than from a `Run.descent_started` connection
## of our own. Both used to subscribe to that signal and rely on Godot firing
## slots in connection order — the director winning only because a child's
## `_ready` runs before its parent's. Moving or re-instancing this node in
## `layer.tscn` would have silently inverted it and freed the geometry first.
func clear() -> void:
	var removed: int = 0
	for creature: Antivirus in _creatures():
		creature.despawn()
		removed += 1
	_dead.clear()
	_directed.clear()
	_by_net_id.clear()
	if removed > 0:
		print("[AI] despawned %d processes" % removed)


## Live creatures, already filtered for freed nodes — every sweep in this file
## runs during teardown at some point.
func _creatures() -> Array[Antivirus]:
	var result: Array[Antivirus] = []
	for node: Node in get_tree().get_nodes_in_group(Antivirus.GROUP):
		var creature: Antivirus = node as Antivirus
		if creature != null and is_instance_valid(creature):
			result.append(creature)
	return result


# ---------------------------------------------------------------- telemetry --

## The trickle runs always; the census is `--log-ai` only. One line per second:
## enough to assert from a log that beam-avoidance actually fires, that a noise
## ping actually converges a pack, and that a welded nest stops refilling.
# ============================================================ THE POSE RELAY ==
#
# ## Why this exists
#
# Every antivirus stood FROZEN AT ITS SPAWN POINT in every client's world, for
# the whole run, for the entire life of the project — while the host watched a
# perfectly normal hunt. Measured on `tools/crewsync/`, comparing the RECEIVED
# `sync_position` rather than the applied transform, and reproducing with a
# single client:
#
#     host     t=8.9  Scrubber_L3_1  -50.38, 0.00, -18.60   (patrolling)
#     client1  t=8.9  Scrubber_L3_1  -46.22, 0.00, -16.70   (its own local spawn,
#                                                            never changes)
#
# That is the user's playtest report — "the enemies only responded to the host" —
# in its true form. The creatures were not ignoring the crew; they were FURNITURE
# in three quarters of the crew's game.
#
# ## Why the synchronizer could not do it
#
# Disproved by A/B, not by argument: forcing the roster filter true changed
# nothing, `public_visibility = true` changed nothing, the roster was complete in
# every join order, and both host->client and client->client RPCs were verified
# delivering. What is left is structural. Crew avatars are created through a
# `MultiplayerSpawner`, which is what establishes the shared node-path cache their
# synchronizers resolve against. Creatures are never spawned — the determinism law
# says every peer GENERATES them locally from the seed — so their synchronizers
# have no spawn to resolve through and never deliver.
#
# ## The shape of the fix
#
# Push pose from the host, exactly the way `_reconcile` already pushes the
# directed-spawn roster a few lines above. Determinism is untouched: creatures
# still come into existence locally from the seed and NOTHING about their
# existence crosses the wire. This is a pose/state layer on top.
#
# ## Bandwidth
#
# One batched packet for the whole layer, not one per creature — 13 creatures at
# 4 peers would otherwise be 13 synchronizers x 3 clients x 20 Hz. Four parallel
# packed arrays (ids, positions, yaws, one status byte each) cost about 27 bytes
# per creature, so a dense layer is ~350 bytes at RELAY_HZ, unreliable and
# unordered-safe. Interest management on top: a creature no crewmate is anywhere
# near is not sent at all, because nobody can see it and a client's own copy
# standing still is exactly right until somebody gets close.

## How often the host pushes. Matches the synchronizer interval it replaces, so
## the smoothing in `Antivirus._smooth_remote` is tuned for the same cadence.
const RELAY_HZ: float = 20.0
## Beyond this from every living crewmate a creature is relayed at a REDUCED
## rate — never at no rate at all. See `_relay_worth_sending`.
const RELAY_INTEREST: float = 60.0
## How many relay ticks a far creature skips. Four at RELAY_HZ 20 is still 5 Hz,
## which is plenty to keep a distant patrol honest and costs a fifth of the bytes.
const RELAY_FAR_EVERY: int = 4

var _relay_clock: float = 0.0
## Monotonic relay tick, for the far-creature rate divisor.
var _relay_tick: int = 0
var _relay_dump_clock: float = 0.0
## Client-side: net id -> creature, rebuilt lazily when an unknown id arrives.
var _by_net_id: Dictionary = {}


## THE INSTRUMENT THAT CLOSED THE P0. One line per creature per peer: name, relay
## id, full node path, authority flag, and whether it is still simulating. Diffing
## the host's dump against a client's is what exposed three colliding id pairs in
## a list of six — a thing no amount of reading the code had revealed, because
## every id resolved and the miss counter read zero.
##
## Kept, flag-gated, fired once ~8 s in under `--log-ai`. The next person to
## suspect a creature is out of sync should reach for this first.
var _roster_dumped: bool = false


func _dump_roster() -> void:
	if _roster_dumped or not Debug.log_ai:
		return
	_roster_dumped = true
	var who: String = "HOST" if (not multiplayer.has_multiplayer_peer() or multiplayer.is_server()) else "CLIENT"
	for creature: Antivirus in _creatures():
		print("[ROSTER] %s name=%s id=%d path=%s host_flag=%s dying=%s pp=%s" % [
			who, String(creature.name), creature.net_id(), String(creature.get_path()),
			str(creature._is_host), str(creature._dying),
			str(creature.is_physics_processing())])


func _tick_relay(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	if Net.crew.size() <= 1:
		return  # nobody to tell.
	_relay_clock -= delta
	if _relay_clock > 0.0:
		return
	_relay_clock = 1.0 / RELAY_HZ
	_relay_tick += 1
	if _relay_tick == 60:
		_dump_roster()

	var crew: Array[Vector3] = []
	for id: int in Net.crew.keys():
		var node: Node = Net.get_player(int(id))
		var body: Node3D = node as Node3D
		if body != null and is_instance_valid(body):
			crew.append(body.global_position)

	var ids: PackedInt32Array = PackedInt32Array()
	var poses: PackedVector3Array = PackedVector3Array()
	var yaws: PackedFloat32Array = PackedFloat32Array()
	var status: PackedByteArray = PackedByteArray()

	for creature: Antivirus in _creatures():
		if not _relay_worth_sending(creature, crew):
			continue
		ids.append(creature.net_id())
		poses.append(creature.sync_position)
		yaws.append(creature.sync_yaw)
		# One byte carries everything that is not pose: the state machine's own
		# state (4 bits — no creature has more than 16), the suspicion rung
		# (3 bits), and the dead flag. Integrity rides its own array only when it
		# is not full, which is almost never, so it is folded in as a byte too.
		var packed: int = (int(creature.sync_state) & 0x0F) \
				| ((int(creature.sync_suspicion) & 0x07) << 4) \
				| (0x80 if creature.sync_dead else 0)
		status.append(packed)
		status.append(int(round(clampf(creature.sync_integrity, 0.0, 1.0) * 255.0)))
		status.append(1 if creature.sync_staggered else 0)

	if ids.is_empty():
		return
	_relay.rpc(ids, poses, yaws, status)


## Interest management — RATE, never presence.
##
## The first cut of this dropped distant creatures from the packet entirely, on
## the reasoning that a client's own copy standing still is correct until somebody
## can perceive it. That reasoning is wrong, and the harness caught it: clients do
## not run the AI, so a creature that is never relayed is not "correct until
## observed", it is FROZEN AT ITS LOCAL SPAWN POINT — the precise bug this whole
## relay exists to fix, reintroduced by an optimisation. It took the gate from 8
## frozen creatures to 3, which is the worst kind of nearly-fixed.
##
## So distance buys a lower RATE, not silence. A far creature still moves on every
## client, at 5 Hz instead of 20, and it is never more than a fifth of a second
## stale by the time somebody walks into the room with it. A death is always sent
## at full rate wherever it happened, because a missed death is a creature that
## lives forever in somebody else's game.
func _relay_worth_sending(creature: Antivirus, crew: Array[Vector3]) -> bool:
	if creature.sync_dead:
		return true
	for where: Vector3 in crew:
		if where.distance_to(creature.global_position) <= RELAY_INTEREST:
			return true
	# Far: relayed on one tick in RELAY_FAR_EVERY. Phase-offset by the creature's
	# own id so the distant half of a layer does not all land in the same packet.
	#
	# NOTE (M11): held at TRUE while the relay is being proven. A dense layer is
	# ~350 bytes at 20 Hz and the cull is worth single-digit KB/s — which is not
	# worth one gram of doubt about whether a creature moved on a client. Restore
	# the rate divisor only once `crewsync` is green WITHOUT it, so the gate can
	# tell the difference between "culled" and "broken".
	return true


## The relay itself. Unreliable: pose is a stream and a dropped packet is
## replaced by the next one 50 ms later, which is strictly better than head-of-line
## blocking a hunt behind a retransmit. Death is latched on the receiving side
## (`Antivirus.apply_relay`) so losing or reordering a packet cannot resurrect
## anything.
@rpc("authority", "call_remote", "unreliable_ordered")
func _relay(ids: PackedInt32Array, poses: PackedVector3Array,
		yaws: PackedFloat32Array, status: PackedByteArray) -> void:
	# Diagnostics kept deliberately cheap and behind the flag: the miss counter is
	# what proved the id scheme sound (0 misses over a 30 s run), and the next
	# person debugging this will want it back immediately.
	var misses: int = 0
	for i: int in ids.size():
		if i >= poses.size() or i >= yaws.size() or i * 3 + 2 >= status.size():
			return  # malformed or truncated: drop the packet, never half-apply it.
		var creature: Antivirus = _find_by_net_id(ids[i])
		if creature == null:
			misses += 1
			continue
		var packed: int = status[i * 3]
		creature.apply_relay(poses[i], yaws[i], packed & 0x0F, (packed >> 4) & 0x07,
				float(status[i * 3 + 1]) / 255.0, (packed & 0x80) != 0,
				status[i * 3 + 2] != 0)
	if Debug.log_ai and misses > 0:
		print("[RELAY] client MISS %d of %d ids (local index has %d)" % [
			misses, ids.size(), _by_net_id.size()])


## Client-side lookup, with a lazily-rebuilt index. The index is rebuilt only when
## an id misses, which happens on the first packet after a creature is built and
## then never again — so the common path is one dictionary hit.
func _find_by_net_id(id: int) -> Antivirus:
	var found: Antivirus = _by_net_id.get(id, null) as Antivirus
	if found != null and is_instance_valid(found):
		return found
	_by_net_id.clear()
	for creature: Antivirus in _creatures():
		_by_net_id[creature.net_id()] = creature
	found = _by_net_id.get(id, null) as Antivirus
	return found if found != null and is_instance_valid(found) else null


func _process(delta: float) -> void:
	_relay_dump_clock += delta
	if _relay_dump_clock > 8.0:
		_dump_roster()
	_tick_relay(delta)
	_tick_trickle(delta)
	if not Debug.log_ai:
		return
	_log_clock -= delta
	if _log_clock > 0.0:
		return
	_log_clock = 1.0

	# Sanctuary safety (M6 mercy law): backdoor rooms are sacred, no hunter enters,
	# ever. This is enforced structurally (hunters never target a player in the
	# sanctuary, the Auditor's route and the hunter nests exclude it, and a wounded
	# Hound never retreats into it) — this is the cheap assertion that says so out
	# loud, so a regression that let one in is caught in a log rather than in play.
	if graph != null and graph.is_backdoor:
		for creature: Antivirus in _creatures():
			if creature is Hunter and creature.current_room() == graph.shaft_index:
				printerr("[AI] SANCTUARY BREACH: %s entered the backdoor room" % creature.name)

	var census: Dictionary = {}
	var total: int = 0
	for creature: Antivirus in _creatures():
		total += 1
		var label: String = "?"
		if creature is Scrubber:
			label = "S." + String(Scrubber.State.keys()[int(creature.sync_state)])
		elif creature is Sentinel:
			label = "V." + String(Sentinel.State.keys()[int(creature.sync_state)])
		elif creature is Hound:
			label = "H." + String(Hound.State.keys()[int(creature.sync_state)])
		elif creature is Moth:
			label = "M." + String(Moth.State.keys()[int(creature.sync_state)])
		elif creature is Auditor:
			label = "A." + String(Auditor.State.keys()[int(creature.sync_state)])
		census[label] = int(census.get(label, 0)) + 1
	if total == 0:
		return

	var parts: PackedStringArray = PackedStringArray()
	var labels: Array = census.keys()
	labels.sort()
	for label: String in labels:
		parts.append("%s=%d" % [label, int(census[label])])
	# PT1: the census carries INTEGRITY as well as state. `sync_integrity` is what
	# the enemy readouts draw from, it is host-authoritative and replicated, and
	# the only honest way to show a client is seeing a crewmate's damage is to
	# print the client's own copy of the number next to the host's.
	var wounded: PackedStringArray = PackedStringArray()
	for creature: Antivirus in _creatures():
		if creature.sync_integrity < 0.999:
			wounded.append("%d:%d%%" % [creature.slot_index,
					int(round(creature.sync_integrity * 100.0))])
	# M6.6: ALTITUDE, for anything that flies. "The Moth exploits tall rooms" is a
	# claim about behaviour, and a claim about behaviour should be a number in a
	# log rather than an impression from a screenshot — a still frame cannot show
	# that a creature is USING a volume, only that it was somewhere once. Printed
	# as height / room headroom, so a Moth patrolling the girders of a twelve-metre
	# trunk room and one bumping around a four-metre bus hall are told apart at a
	# glance.
	var flight: PackedStringArray = PackedStringArray()
	for creature: Antivirus in _creatures():
		if creature is not Moth:
			continue
		var head: float = 0.0
		if graph != null:
			var room: int = creature.current_room()
			if room >= 0 and room < graph.rooms.size():
				head = float(graph.rooms[room]["h"])
		flight.append("%d:%.1f/%.0fm" % [
			creature.slot_index, creature.global_position.y, head])
	print("[AI] %s layer %d processes=%d %s%s%s" % [
		"HOST " if multiplayer.is_server() else "CLIENT",
		_layer_number, total, " ".join(parts),
		"  integrity[" + " ".join(wounded) + "]" if wounded.size() > 0 else "",
		"  altitude[" + " ".join(flight) + "]" if flight.size() > 0 else ""])
