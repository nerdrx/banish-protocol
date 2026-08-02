extends Node
## Props — host-authoritative state for M4.8's functional clutter.
##
## Run owns the intrusion (the pool, who is standing, what is in whose buffer).
## This owns the *layer's furniture*: where the power is routed, which vents have
## been welded shut, which cabinets have been opened, which bulkhead is sealed
## and for how long. It is a separate autoload for the same reason Modules is
## one — Run is already the largest file in the project and none of this belongs
## to the economy.
##
## ## Authority, and the shape every request takes
##
## Identical to the Compiler's, because it is the pattern that works: the prop is
## **seeded content** (LayerGraph resolves every junction, vent, cabinet, door and
## terminal from the run seed, so every peer has its own copy of the same object
## in the same place), which means a request only ever has to carry an *index*.
## The host then checks that the sender is genuinely stood at the thing they
## claim to be using, applies the change to its own copy, and broadcasts.
##
##   client            host
##   ------            ----
##   channel/burn      -
##   request_*(index)  validate: run live? sender running? sender in range?
##                     apply, then _apply_*.rpc(index) to everybody
##
## A client that fakes a completed weld still has to be standing at the vent.
##
## ## What is NOT here
##
## The noise. Every one of these actions is loud, and the ping goes through
## `NoiseBus` from inside the host-side validation — so a refused request is also a
## silent one, which is the correct answer to "can I ping the layer for free by
## spamming packets from across the map".
##
## ## Lifetime
##
## Everything is per-layer and cleared on descent, exactly like `Run.spent_siphons`.
## A prop entering the tree asks this autoload what it already is (a rebuilt vent
## must not come up unwelded), which is why the state lives here rather than on
## the nodes.

## Where the junction has routed the layer's power. Only one at a time, by
## design: the whole point of the prop is that it is a choice.
enum Power {
	NONE,   ## Nothing routed. Emergency strips dark, cabinets locked, fans idle.
	LIGHTS, ## Emergency strips up in the junction rooms and their corridors.
	DOORS,  ## The layer's cabinet locks are released — open them silently.
	FANS,   ## Every weldable vent slams shut for VENT_FAN_SECONDS.
}

signal power_changed
signal vents_changed
signal cabinets_changed
signal bulkheads_changed

var power: int = Power.NONE
## Seconds of VENT FANS left. Every peer runs its own copy off one packet, the
## same way the exfil countdown does: it is a clock, not a simulation.
var fans_remaining: float = 0.0

## vent index -> true. Permanent for the layer — a welded vent stays welded.
var welded_vents: Dictionary = {}
## cabinet index -> true.
var opened_cabinets: Dictionary = {}
## bulkhead index -> seconds until MOTHER forces it back open.
var sealed_doors: Dictionary = {}

## Group names, so the "find the prop with this index" helper is not four
## near-identical functions.
const GROUP_JUNCTION: String = "rewire_junctions"
const GROUP_VENT: String = "weld_vents"
const GROUP_CABINET: String = "loot_cabinets"
const GROUP_BULKHEAD: String = "bulkhead_doors"
const GROUP_TERMINAL: String = "command_terminals"


func _ready() -> void:
	Run.layer_changed.connect(_on_layer_changed)
	Run.descent_started.connect(_on_descent_started)
	set_process(true)


func _on_layer_changed(_number: int) -> void:
	reset()


func _on_descent_started(_next: int) -> void:
	reset()


func reset() -> void:
	power = Power.NONE
	fans_remaining = 0.0
	welded_vents.clear()
	opened_cabinets.clear()
	sealed_doors.clear()
	power_changed.emit()
	vents_changed.emit()
	cabinets_changed.emit()
	bulkheads_changed.emit()


# ------------------------------------------------------------------ queries --

func is_welded(index: int) -> bool:
	return welded_vents.has(index)


## Welded, or held shut by the fans. The vent's collider and its prompt both read
## this; only `is_welded` is permanent.
func is_vent_shut(index: int) -> bool:
	return welded_vents.has(index) or fans_remaining > 0.0


func is_cabinet_open(index: int) -> bool:
	return opened_cabinets.has(index)


func is_sealed(index: int) -> bool:
	return sealed_doors.has(index)


func seal_remaining(index: int) -> float:
	return float(sealed_doors.get(index, 0.0))


## Cabinets open silently while the junction is feeding the door locks.
func locks_released() -> bool:
	return power == Power.DOORS


## How many vents in `room` have been welded. The antivirus director's
## reinforcement trickle reads this, which is the entire reason welding matters
## rather than being a satisfying noise.
func welds_in_room(graph: LayerGraph, room: int) -> int:
	if graph == null:
		return 0
	var count: int = 0
	for index: int in welded_vents.keys():
		if index >= 0 and index < graph.vent_rooms.size() \
				and graph.vent_rooms[index] == room:
			count += 1
	return count


static func power_name(mode: int) -> String:
	match mode:
		Power.LIGHTS:
			return "ROOM LIGHTING"
		Power.DOORS:
			return "DOOR LOCKS"
		Power.FANS:
			return "VENT FANS"
		_:
			return "UNROUTED"


# ------------------------------------------------------------------ clocks --

## The two timed states, run locally off the packet that started them. The host's
## copies are the ones that actually expire things.
func _process(delta: float) -> void:
	if fans_remaining > 0.0:
		fans_remaining = maxf(fans_remaining - delta, 0.0)
		if fans_remaining <= 0.0:
			vents_changed.emit()

	if sealed_doors.is_empty():
		return
	var expired: Array[int] = []
	var warned: Array[int] = []
	for id: int in sealed_doors.keys():
		var index: int = int(id)
		var left: float = float(sealed_doors[index]) - delta
		# The hiss. Fired once, as the clock crosses the warning mark, on every
		# peer — it is presentation, and presentation off a shared clock needs no
		# packet of its own.
		if left <= Balance.BULKHEAD_WARN_SECONDS \
				and left + delta > Balance.BULKHEAD_WARN_SECONDS:
			warned.append(index)
		sealed_doors[index] = left
		if left <= 0.0:
			expired.append(index)

	for _index: int in warned:
		Run.notice.emit("BULKHEAD OVERRIDE  ·  %ds" % int(Balance.BULKHEAD_WARN_SECONDS))
	if expired.is_empty():
		return
	# Host decides; clients wait to be told, so a slow peer never opens a door the
	# host still has shut.
	if _is_host():
		for index: int in expired:
			_apply_unseal.rpc(index)
	else:
		for index: int in expired:
			sealed_doors[index] = 0.01


# ----------------------------------------------------------------- requests --

func request_rewire(mode: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_rewire_request.rpc_id(1, mode)


func request_weld(index: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_weld_request.rpc_id(1, index)


func request_cabinet(index: int, cut: bool) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_cabinet_request.rpc_id(1, index, cut)


func request_seal(index: int, seal: bool) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_seal_request.rpc_id(1, index, seal)


## A terminal query. Nothing about the *answer* crosses the wire — every peer can
## read its own layer graph, and the panel has already started typing locally.
## What the host owns is the consequence: the query was loud.
func request_query(index: int, command: String) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_query_request.rpc_id(1, index, command)


# ------------------------------------------------------------------- server --

func _is_host() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true  # editor / offline: there is nobody else to be authority.
	return multiplayer.is_server()


func _sender() -> int:
	var sender: int = multiplayer.get_remote_sender_id()
	return 1 if sender == 0 else sender


## Whether `peer` is standing at the prop with `index` in `group`. The one check
## that separates "held the channel at the machine" from "sent a packet".
func _at_prop(peer: int, group: String, index: int, reach: float) -> Node3D:
	var player: Node = Net.get_player(peer)
	if player == null or not is_instance_valid(player):
		return null
	for node: Node in get_tree().get_nodes_in_group(group):
		var prop: Node3D = node as Node3D
		if prop == null or not is_instance_valid(prop):
			continue
		if int(prop.get("prop_index")) != index:
			continue
		if prop.global_position.distance_to((player as Node3D).global_position) > reach:
			push_warning("[Props] %s %d refused: peer %d is %.1f m away" % [
				group, index, peer,
				prop.global_position.distance_to((player as Node3D).global_position)])
			return null
		return prop
	return null


func _live(peer: int) -> bool:
	return not Run.run_over and not Run.descending and Run.is_running(peer)


@rpc("any_peer", "call_local", "reliable")
func _rewire_request(mode: int) -> void:
	if not _is_host():
		return
	var sender: int = _sender()
	if not _live(sender):
		return
	var wanted: int = clampi(mode, int(Power.NONE), int(Power.FANS))
	if wanted == power:
		return
	var junction: Node3D = _nearest_junction(sender)
	if junction == null:
		return
	# Rerouting a live power bus is the loudest thing a lever does — a siphon's
	# worth of noise, which is what makes the choice cost something.
	NoiseBus.ping(junction.global_position, Balance.NOISE_ROOMS_JUNCTION, "rewire",
			Balance.NOISE_TIME_JUNCTION)
	_apply_power.rpc(wanted,
			Balance.VENT_FAN_SECONDS if wanted == Power.FANS else 0.0)


## Any junction within reach. The mode is layer-global, so which one you used is
## a validation detail rather than part of the state.
func _nearest_junction(peer: int) -> Node3D:
	var player: Node = Net.get_player(peer)
	if player == null or not is_instance_valid(player):
		return null
	var here: Vector3 = (player as Node3D).global_position
	for node: Node in get_tree().get_nodes_in_group(GROUP_JUNCTION):
		var prop: Node3D = node as Node3D
		if prop == null or not is_instance_valid(prop):
			continue
		if prop.global_position.distance_to(here) <= Balance.JUNCTION_USE_RANGE:
			return prop
	push_warning("[Props] rewire refused: peer %d is not at a junction" % peer)
	return null


@rpc("any_peer", "call_local", "reliable")
func _weld_request(index: int) -> void:
	if not _is_host() or welded_vents.has(index):
		return
	var sender: int = _sender()
	if not _live(sender):
		return
	var vent: Node3D = _at_prop(sender, GROUP_VENT, index, Balance.VENT_WELD_RANGE)
	if vent == null:
		return
	# Welding is a cutting torch held against a grille for two seconds. It is
	# quieter than cutting a lock open — you are closing a hole, not making one —
	# but it is not silent, and a nest is exactly the wrong place to be casual.
	NoiseBus.ping(vent.global_position, Balance.NOISE_ROOMS_DEBRIS, "weld",
			Balance.NOISE_TIME_DEBRIS)
	_apply_weld.rpc(index)


@rpc("any_peer", "call_local", "reliable")
func _cabinet_request(index: int, cut: bool) -> void:
	if not _is_host() or opened_cabinets.has(index):
		return
	var sender: int = _sender()
	if not _live(sender):
		return
	# The silent path is only silent because the junction is holding the locks
	# open. Asking for it without that is asking for something that is not there.
	if not cut and not locks_released():
		push_warning("[Props] cabinet %d refused: locks are not released" % index)
		return
	var reach: float = Balance.CABINET_CUT_RANGE if cut else Balance.CABINET_USE_RANGE
	var cabinet: Node3D = _at_prop(sender, GROUP_CABINET, index, reach)
	if cabinet == null:
		return

	if cut:
		NoiseBus.ping(cabinet.global_position, Balance.NOISE_ROOMS_CABINET, "cabinet",
				Balance.NOISE_TIME_CABINET)
	# Contents are a pure function of (seed, layer, index) so the host does not
	# have to tell anybody what was inside — but the host is still the only thing
	# that may put it in a buffer, so the spill and the flare both happen here.
	var loot: Dictionary = cabinet_loot(index)
	Run.drop_salvage(cabinet.global_position + Vector3(0.0, 0.9, 0.0),
			int(loot["shards"]), 1)
	if int(loot["flares"]) > 0:
		Run.grant_flares(sender, int(loot["flares"]))
	print("[Props] cabinet %d opened by %s (%s): %d chips%s" % [
		index, Net.crew_name(sender), "cut" if cut else "unlocked",
		int(loot["shards"]),
		", +%d flare" % int(loot["flares"]) if int(loot["flares"]) > 0 else ""])
	_apply_cabinet.rpc(index)


## What is in cabinet `index` on this layer. Seeded content, so every peer agrees
## without a byte on the wire and the determinism dump can print it.
static func cabinet_loot(index: int) -> Dictionary:
	var seed_value: int = hash(str(Rng.run_seed, ":cabinet:", Run.layer_number, ":", index))
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	return {
		"shards": rng.randi_range(Balance.CABINET_SHARDS.x, Balance.CABINET_SHARDS.y),
		"flares": Balance.CABINET_FLARES \
				if rng.randf() < Balance.CABINET_FLARE_CHANCE else 0,
	}


@rpc("any_peer", "call_local", "reliable")
func _seal_request(index: int, seal: bool) -> void:
	if not _is_host():
		return
	var sender: int = _sender()
	if not _live(sender):
		return
	if seal == sealed_doors.has(index):
		return
	var door: Node3D = _at_prop(sender, GROUP_BULKHEAD, index, Balance.BULKHEAD_USE_RANGE)
	if door == null:
		return
	if seal:
		_apply_seal.rpc(index, Balance.BULKHEAD_SEAL_SECONDS)
	else:
		_apply_unseal.rpc(index)


@rpc("any_peer", "call_local", "reliable")
func _query_request(index: int, command: String) -> void:
	if not _is_host():
		return
	var sender: int = _sender()
	if not _live(sender):
		return
	var terminal: Node3D = _at_prop(sender, GROUP_TERMINAL, index,
			Balance.TERMINAL_USE_RANGE)
	if terminal == null:
		return
	print("[Props] terminal %d query by %s: %s" % [
		index, Net.crew_name(sender), command])
	NoiseBus.ping(terminal.global_position, Balance.NOISE_ROOMS_TERMINAL, "query",
			Balance.NOISE_TIME_TERMINAL)


# --------------------------------------------------------------------- rpcs --

@rpc("authority", "call_local", "reliable")
func _apply_power(mode: int, fans: float) -> void:
	power = mode
	fans_remaining = fans
	power_changed.emit()
	vents_changed.emit()
	cabinets_changed.emit()
	Run.notice.emit("POWER ROUTED  ·  %s" % power_name(mode))


@rpc("authority", "call_local", "reliable")
func _apply_weld(index: int) -> void:
	welded_vents[index] = true
	vents_changed.emit()


@rpc("authority", "call_local", "reliable")
func _apply_cabinet(index: int) -> void:
	opened_cabinets[index] = true
	cabinets_changed.emit()


@rpc("authority", "call_local", "reliable")
func _apply_seal(index: int, seconds: float) -> void:
	sealed_doors[index] = seconds
	bulkheads_changed.emit()
	Run.notice.emit("BULKHEAD SEALED  ·  %ds" % int(seconds))


@rpc("authority", "call_local", "reliable")
func _apply_unseal(index: int) -> void:
	if not sealed_doors.has(index):
		return
	sealed_doors.erase(index)
	bulkheads_changed.emit()
