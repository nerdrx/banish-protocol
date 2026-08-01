extends Node
## Run — the intrusion itself: which layer, how many Cycles are left, who is
## still running, what is in everyone's buffer, and how the run ends.
##
## Authority (DESIGN.md "Multiplayer Architecture"): the host simulates, clients
## observe. Every number here is written on the host and pushed out; a client's
## copy is display state. Clients only ever *request* (siphon, descend, fire,
## restore, exfil) and the host decides.
##
## Traffic budget: the pool is a smooth ramp, so it goes out unreliably at 5 Hz
## and clients interpolate between packets. Health, buffers and layer changes are
## rare and consequential, so they go reliably on change.
##
## GameState holds who you are across scenes; Run holds what is happening to you
## inside one intrusion. Leaving a session resets Run and leaves GameState alone.
##
## ## Living, corrupted, deleted
##
## M3 splits "alive" in two. A crewmate whose integrity reaches zero **corrupts**
## — on the floor, out of the run, spilling their buffer, on a personal 60 s
## decay timer any crewmate can cancel by channelling a restore. Only when that
## timer expires (or a solo agent goes down, with nobody to restore them) are
## they **deleted**: spectating, gone for the run. `is_running` is the predicate
## almost everything wants; `is_alive` means "not deleted yet".

signal config_changed              ## Seed and/or layer number are now known.
signal layer_changed(number: int)  ## The layer below has been written.
signal cycles_changed(value: float)
signal integrity_changed
signal siphon_taken(index: int, pool: float)
signal descent_started(next_layer: int)
signal descent_finished
signal muster_changed(inside: int, total: int)
signal decompiled(peer_id: int)
signal run_ended(summary: Dictionary)
signal notice(message: String)

## M3 events.
signal damaged(from: Vector3)                                ## The local avatar was hit.
signal shard_taken(index: int, peer_id: int, worth: int)
signal bundle_taken(bundle_id: int, peer_id: int)
signal buffers_changed
signal corruption_changed
signal backdoor_rooted_changed
signal exfil_changed

## M3.5 events. These carry no new state — they name moments the run already
## replicates, so `Achievements` can listen instead of polling.
signal process_deleted(by_peer: int, kind: String)  ## A breaker shot killed something.
signal restored(peer_id: int, by_peer: int)         ## Somebody was brought back up.

# --- world config -----------------------------------------------------------

## False until the host has told us the seed and the layer. The Layer scene
## refuses to build geometry before this, which is what stops a client from
## generating a layer from a stale seed and desyncing the crew.
var configured: bool = false
var layer_number: int = 1
var use_test_layer: bool = false

# --- economy ----------------------------------------------------------------

var cycles: float = 0.0
var cycles_max: float = Balance.CYCLES_PER_CREW

## peer id -> 0..INTEGRITY_MAX. Absent means "not spawned yet", which counts as
## healthy so a joining crewmate is never billed as a casualty.
var integrity: Dictionary = {}
## peer id -> seconds of decay left. Present means corrupted.
var corrupted: Dictionary = {}
## peer id -> true. Present means deleted for the rest of the run.
var deleted: Dictionary = {}

## peer id -> shards held. Lost on deletion, banked on exfiltration.
var buffered: Dictionary = {}
## peer id -> flares in stock.
var flares: Dictionary = {}

## Tap indices already drained on the current layer. Cleared on descent.
var spent_siphons: Dictionary = {}
## Shard indices already absorbed on the current layer. Cleared on descent.
var taken_shards: Dictionary = {}

# --- layer state ------------------------------------------------------------

var muster_inside: int = 0
var muster_total: int = 0
var descending: bool = false
var run_over: bool = false

## Backdoor layers only. Both replicated; both cleared on descent.
var backdoor_rooted: bool = false
var exfil_calling: bool = false
var exfil_remaining: float = 0.0

## Deepest layer the crew stood in this run, for the summary overlay.
var deepest_layer: int = 1
var siphons_drained: int = 0
var _run_started_msec: int = 0

var _pool_clock: float = 0.0
var _health_clock: float = 0.0
var _buffer_clock: float = 0.0
var _muster_clock: float = 0.0
var _dirty_health: bool = false
var _dirty_buffers: bool = false
var _log_clock: float = 0.0
## Client-side smoothing target, so a 5 Hz pool stream reads as a continuous ramp.
var _display_cycles: float = 0.0

## Host-side id counters for the things that are not seeded content.
var _next_flare_id: int = 1
var _next_bundle_id: int = 1
## peer id -> last accepted breaker shot, so a client cannot out-fire its cutter.
var _last_shot: Dictionary = {}


func _ready() -> void:
	set_process(true)


# ----------------------------------------------------------------- lifecycle --

## Host: start a fresh intrusion. Called from Net.host() once the seed is rolled.
func begin(layer: int, test_layer: bool) -> void:
	layer_number = maxi(layer, 1)
	deepest_layer = layer_number
	use_test_layer = test_layer
	spent_siphons.clear()
	taken_shards.clear()
	integrity.clear()
	corrupted.clear()
	deleted.clear()
	buffered.clear()
	flares.clear()
	descending = false
	run_over = false
	backdoor_rooted = false
	exfil_calling = false
	exfil_remaining = 0.0
	siphons_drained = 0
	_run_started_msec = Time.get_ticks_msec()
	cycles_max = Balance.pool_max(maxi(Net.crew.size(), 1))
	cycles = cycles_max
	if Debug.start_cycles >= 0.0:
		cycles = minf(Debug.start_cycles, cycles_max)
	_display_cycles = cycles
	configured = true
	print("[Run] intrusion begins on layer %d, pool %.0f (%s)" % [
		layer_number, cycles, "test layer" if test_layer else "procedural"])
	config_changed.emit()
	cycles_changed.emit(cycles)


## Client: adopt the host's world configuration. Arrives before the spawn packet
## (both reliable on the same channel), so geometry exists before the player does.
func adopt(layer: int, test_layer: bool, pool: float, maximum: float) -> void:
	layer_number = maxi(layer, 1)
	deepest_layer = maxi(deepest_layer, layer_number)
	use_test_layer = test_layer
	cycles = pool
	cycles_max = maximum
	_display_cycles = pool
	descending = false
	run_over = false
	configured = true
	config_changed.emit()
	cycles_changed.emit(cycles)


## Solo / editor runs: no host to ask, so configure from whatever seed Rng has.
func begin_offline() -> void:
	if configured:
		return
	begin(layer_number, use_test_layer)


## Host: the roster changed. DESIGN.md scales the pool with crew size, so a
## crewmate arriving brings their own share with them rather than diluting the
## pool the crew already earned.
func on_crew_changed() -> void:
	if not configured:
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return

	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not integrity.has(peer):
			integrity[peer] = Balance.INTEGRITY_MAX
		if not buffered.has(peer):
			buffered[peer] = 0
		if not flares.has(peer):
			flares[peer] = Balance.FLARE_STOCK

	var updated: float = Balance.pool_max(maxi(Net.crew.size(), 1))
	if updated > cycles_max:
		cycles += updated - cycles_max
	cycles_max = updated
	cycles = clampf(cycles, 0.0, cycles_max)
	_dirty_health = true
	_dirty_buffers = true
	cycles_changed.emit(cycles)
	integrity_changed.emit()


## Host: a crew member dropped. Their share leaves with them, but never below
## what the remaining crew is currently holding — a disconnect must not be a
## punishment for the people still running.
func on_crew_left(peer_id: int) -> void:
	integrity.erase(peer_id)
	corrupted.erase(peer_id)
	deleted.erase(peer_id)
	buffered.erase(peer_id)
	flares.erase(peer_id)
	if not configured:
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	cycles_max = Balance.pool_max(maxi(Net.crew.size(), 1))
	cycles = clampf(cycles, 0.0, cycles_max)
	_dirty_health = true
	_dirty_buffers = true
	cycles_changed.emit(cycles)
	integrity_changed.emit()


func reset() -> void:
	configured = false
	layer_number = 1
	descending = false
	run_over = false
	cycles = 0.0
	_display_cycles = 0.0
	integrity.clear()
	corrupted.clear()
	deleted.clear()
	buffered.clear()
	flares.clear()
	spent_siphons.clear()
	taken_shards.clear()
	muster_inside = 0
	muster_total = 0
	deepest_layer = 1
	siphons_drained = 0
	backdoor_rooted = false
	exfil_calling = false
	exfil_remaining = 0.0


# ------------------------------------------------------------------- queries --

func fraction() -> float:
	if cycles_max <= 0.0:
		return 0.0
	return clampf(cycles / cycles_max, 0.0, 1.0)


## Smoothed pool for the HUD. Clients would otherwise show a value that steps
## five times a second while the host's own ring glides.
func display_fraction() -> float:
	if cycles_max <= 0.0:
		return 0.0
	return clampf(_display_cycles / cycles_max, 0.0, 1.0)


## The pool is empty and everyone is degrading.
func starved() -> bool:
	return configured and cycles <= 0.0


func integrity_of(peer_id: int) -> float:
	return float(integrity.get(peer_id, Balance.INTEGRITY_MAX))


## Down but recoverable: a crewmate can still channel them back.
func is_corrupted(peer_id: int) -> bool:
	return corrupted.has(peer_id)


## Gone for the run. Spectating.
func is_deleted(peer_id: int) -> bool:
	return deleted.has(peer_id)


## On their feet and playing: the predicate for billing, muster, salvage, and
## anything the antivirus hunts.
func is_running(peer_id: int) -> bool:
	return not deleted.has(peer_id) and not corrupted.has(peer_id)


## Still in the run at all, corrupted or not.
func is_alive(peer_id: int) -> bool:
	return not deleted.has(peer_id)


func corruption_left(peer_id: int) -> float:
	return float(corrupted.get(peer_id, 0.0))


func buffered_of(peer_id: int) -> int:
	return int(buffered.get(peer_id, 0))


func flares_of(peer_id: int) -> int:
	return int(flares.get(peer_id, 0))


func local_integrity() -> float:
	return integrity_of(Net.local_id())


func local_alive() -> bool:
	return is_alive(Net.local_id())


func local_running() -> bool:
	return is_running(Net.local_id())


func local_corrupted() -> bool:
	return is_corrupted(Net.local_id())


func local_buffered() -> int:
	return buffered_of(Net.local_id())


## Peer ids currently down, for the HUD's crewmate alert.
func corrupted_crew() -> Array[int]:
	var ids: Array[int] = []
	for id: int in corrupted.keys():
		ids.append(int(id))
	ids.sort()
	return ids


func crew_mustered() -> bool:
	return muster_total > 0 and muster_inside >= muster_total


## Nobody may ride the shaft down while a crewmate is face down on the floor.
func crew_intact() -> bool:
	return corrupted.is_empty()


func is_siphon_spent(index: int) -> bool:
	return spent_siphons.has(index)


func is_shard_taken(index: int) -> bool:
	return taken_shards.has(index)


## Movement penalty for the local avatar: starvation, plus the weight of the haul
## (DESIGN.md: "buffered weight slows you slightly — who carries the haul?").
func speed_multiplier() -> float:
	var multiplier: float = Balance.STARVED_SPEED_MULT if starved() else 1.0
	return multiplier * Balance.carry_multiplier(local_buffered())


## 0..1 "how badly is this process failing", driving the post-process glitch and
## the vignette closing in. Starvation opens it; losing integrity deepens it.
func degradation() -> float:
	if not configured:
		return 0.0
	if not local_alive():
		# Deleted: a steady ghost-signal wash. Full glitch here would be
		# thematically right and unwatchable — spectating is minutes long.
		return 0.25
	if local_corrupted():
		# Corrupted: the process is coming apart and you are watching it happen,
		# so this is the worst the screen ever gets.
		return 0.85
	var hurt: float = 1.0 - clampf(local_integrity() / Balance.INTEGRITY_MAX, 0.0, 1.0)
	var starving: float = 0.0
	if starved():
		# Ramp in over the first few seconds of an empty pool rather than
		# snapping the screen shut the instant it hits zero.
		starving = 0.35 + hurt * 0.65
	elif fraction() < Balance.CYCLES_WARNING_FRACTION:
		# A warning shimmer below 25%, well short of full glitch.
		starving = inverse_lerp(Balance.CYCLES_WARNING_FRACTION, 0.0, fraction()) * 0.22
	return clampf(maxf(starving, hurt * 0.5), 0.0, 1.0)


# --------------------------------------------------------------- host update --

func _process(delta: float) -> void:
	# Clients ease their displayed pool toward the last packet.
	_display_cycles = lerpf(_display_cycles, cycles, 1.0 - exp(-9.0 * delta))

	# The exfil countdown runs on every peer off one start packet: it is a clock,
	# not a simulation, and streaming it would spend bandwidth on a number every
	# peer can compute. The host's copy is the one that fires.
	if exfil_calling:
		exfil_remaining = maxf(exfil_remaining - delta, 0.0)

	if not configured or run_over:
		return
	if not multiplayer.has_multiplayer_peer():
		return
	if not multiplayer.is_server():
		return

	_drain(delta)
	_degrade(delta)
	_decay_corrupted(delta)

	if exfil_calling and exfil_remaining <= 0.0:
		_fire_exfil()
		return

	if Debug.log_cycles:
		_log_clock -= delta
		if _log_clock <= 0.0:
			_log_clock = 1.0
			_log_telemetry()

	_muster_clock -= delta
	if _muster_clock <= 0.0:
		_muster_clock = 0.25
		_update_muster()

	_pool_clock -= delta
	if _pool_clock <= 0.0:
		_pool_clock = Balance.POOL_SYNC_INTERVAL
		_push_pool.rpc(cycles, cycles_max)

	_health_clock -= delta
	if _dirty_health and _health_clock <= 0.0:
		_health_clock = Balance.INTEGRITY_SYNC_INTERVAL
		_dirty_health = false
		_push_health.rpc(integrity, corrupted, deleted)

	_buffer_clock -= delta
	if _dirty_buffers and _buffer_clock <= 0.0:
		_buffer_clock = Balance.INTEGRITY_SYNC_INTERVAL
		_dirty_buffers = false
		_push_buffers.rpc(buffered, flares)


## Passive drain per running player, plus a sprint surcharge. Sprint is inferred
## from the pose stream the players already replicate — billing does not need its
## own input bit, and a client cannot under-report by withholding one.
func _drain(delta: float) -> void:
	if descending:
		return  # the layer is being rewritten; nobody is running.

	var drain: float = 0.0
	for id: int in Net.crew.keys():
		if not is_running(int(id)):
			continue
		var rate: float = Balance.PASSIVE_DRAIN
		var player: Node = Net.get_player(int(id))
		if player != null and is_instance_valid(player):
			var speed: float = float(player.get("sync_speed"))
			if speed >= Balance.SPRINT_BILLING_SPEED:
				rate *= Balance.SPRINT_DRAIN_MULT
		drain += rate

	if drain <= 0.0:
		return
	var before: float = cycles
	cycles = maxf(cycles - drain * delta, 0.0)
	if before > 0.0 and cycles <= 0.0:
		_starvation_notice.rpc("CYCLES EXHAUSTED  ·  INTEGRITY FAILING")
	cycles_changed.emit(cycles)


## Integrity falls only while the pool is empty, and creeps back once it is not.
## Hitting zero corrupts the process — the same door antivirus damage opens.
func _degrade(delta: float) -> void:
	var empty: bool = starved()

	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not is_running(peer):
			continue
		var value: float = integrity_of(peer)

		if empty:
			value = maxf(value - Balance.STARVED_INTEGRITY_DRAIN * delta, 0.0)
		elif value < Balance.INTEGRITY_MAX:
			value = minf(value + Balance.INTEGRITY_REGEN * delta, Balance.INTEGRITY_MAX)
		else:
			continue  # untouched and full: nothing to write or replicate.

		integrity[peer] = value
		_dirty_health = true
		if value <= 0.0:
			_bring_down(peer)

	if not Net.crew.is_empty():
		_check_wipe()


## Personal decay timers. Running out is deletion — DESIGN.md's "solo corruption
## = countdown to deletion", generalised to anyone the crew could not reach.
func _decay_corrupted(delta: float) -> void:
	if corrupted.is_empty():
		return
	var expired: Array[int] = []
	for id: int in corrupted.keys():
		var peer: int = int(id)
		var left: float = float(corrupted[peer]) - delta
		corrupted[peer] = left
		if left <= 0.0:
			expired.append(peer)

	for peer: int in expired:
		_delete(peer, "%s DECOMPILED" % Net.crew_name(peer))
	if not expired.is_empty():
		_check_wipe()
	_dirty_health = true


## `--log-cycles`. One line per second with everything needed to verify a drain
## rate against Balance by hand.
func _log_telemetry() -> void:
	var speeds: PackedStringArray = PackedStringArray()
	for id: int in Net.crew.keys():
		var player: Node = Net.get_player(int(id))
		var speed: float = 0.0 if player == null else float(player.get("sync_speed"))
		speeds.append("%d:%.1fm/s%s" % [int(id), speed,
			"*" if speed >= Balance.SPRINT_BILLING_SPEED else ""])
	print("[Run] layer=%d pool=%.1f/%.0f crew=[%s] integrity=%s corrupted=%s buffered=%s" % [
		layer_number, cycles, cycles_max, ", ".join(speeds), str(integrity),
		str(corrupted.keys()), str(buffered)])


## A wipe is every crew member off their feet at once — deleted, corrupted, or
## any mix. A crew all face down has nobody left to restore anybody.
func _check_wipe() -> void:
	if run_over or Net.crew.is_empty():
		return
	for id: int in Net.crew.keys():
		if is_running(int(id)):
			return
	run_over = true
	_end_run.rpc(_summary("CREW DECOMPILED", false, {}))


## Count living crew standing in the drop shaft. Host-only: this is the gate on
## descending, so it is measured against the host's own copy of everyone's pose.
func _update_muster() -> void:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null:
		return
	var shaft: Vector3 = Vector3(layer.get("shaft_position"))

	var inside: int = 0
	var total: int = 0
	for id: int in Net.crew.keys():
		if not is_running(int(id)):
			continue
		total += 1
		var player: Node = Net.get_player(int(id))
		if player == null or not is_instance_valid(player):
			continue
		var pos: Vector3 = (player as Node3D).global_position
		if Vector2(pos.x - shaft.x, pos.z - shaft.z).length() <= Balance.SHAFT_MUSTER_RADIUS:
			inside += 1

	if inside != muster_inside or total != muster_total:
		_push_muster.rpc(inside, total)


# -------------------------------------------------------------------- damage --

## Host-side. The single door integrity leaves by, whether it was a Scrubber's
## lunge, a Sentinel's arc or a dev flag.
func damage_player(peer_id: int, amount: float, from: Vector3) -> void:
	if not multiplayer.is_server() or run_over or descending:
		return
	if not is_running(peer_id) or amount <= 0.0:
		return

	integrity[peer_id] = maxf(integrity_of(peer_id) - amount, 0.0)
	_dirty_health = true

	# DESIGN.md pillar 1: taking damage spikes the shared pool. Fighting costs
	# the crew clock even when nobody goes down.
	cycles = maxf(cycles - Balance.DAMAGE_CYCLE_SPIKE, 0.0)
	cycles_changed.emit(cycles)

	_damage_flash.rpc_id(peer_id, from)
	if peer_id == 1:
		damaged.emit(from)  # the host is its own client.

	if integrity_of(peer_id) <= 0.0:
		_bring_down(peer_id)
		_check_wipe()


## Integrity reached zero. Solo agents have nobody to restore them, so they are
## deleted outright; a crew member corrupts and starts their decay timer.
func _bring_down(peer_id: int) -> void:
	if not is_running(peer_id):
		return
	if Net.crew.size() <= 1:
		_delete(peer_id, "%s DECOMPILED  ·  NO CREW TO RESTORE YOU" % Net.crew_name(peer_id))
		return

	corrupted[peer_id] = Balance.CORRUPT_DECAY
	_dirty_health = true
	_spill_buffer(peer_id)
	_corrupt_notice.rpc(peer_id)
	var where: Node = Net.get_player(peer_id)
	print("[Run] %s corrupted at %s (%.0fs to decompile)" % [
		Net.crew_name(peer_id),
		"?" if where == null else str((where as Node3D).global_position.snapped(Vector3.ONE * 0.1)),
		Balance.CORRUPT_DECAY])


func _delete(peer_id: int, message: String) -> void:
	corrupted.erase(peer_id)
	deleted[peer_id] = true
	integrity[peer_id] = 0.0
	buffered[peer_id] = 0
	_dirty_health = true
	_dirty_buffers = true
	_decompile.rpc(peer_id, message)


## Everything they were carrying, on the floor where they fell. Recoverable —
## DESIGN.md only takes buffered data away on a wipe.
func _spill_buffer(peer_id: int) -> void:
	var amount: int = buffered_of(peer_id)
	if amount <= 0:
		return
	var player: Node = Net.get_player(peer_id)
	if player == null or not is_instance_valid(player):
		return
	buffered[peer_id] = 0
	_dirty_buffers = true
	var id: int = _next_bundle_id
	_next_bundle_id += 1
	print("[Run] %s spilled %d data" % [Net.crew_name(peer_id), amount])
	_spawn_bundle.rpc(id, (player as Node3D).global_position, amount)


# -------------------------------------------------------------------- salvage --

## Host-side, called by a shard that has reached a player.
func take_shard(index: int, peer_id: int, worth: int) -> void:
	if not multiplayer.is_server() or taken_shards.has(index):
		return
	if not is_running(peer_id):
		return
	taken_shards[index] = true
	buffered[peer_id] = buffered_of(peer_id) + 1
	_dirty_buffers = true
	_apply_shard.rpc(index, peer_id, worth)


## Host-side. Scatters `shards` across `pieces` recoverable piles at `where` —
## what a killed Sentinel was standing on top of. Same object and same
## replication path as a corrupted crewmate's spilled buffer, because it is the
## same thing: data on the floor that somebody has to walk over to claim.
func drop_salvage(where: Vector3, shards: int, pieces: int) -> void:
	if not multiplayer.is_server() or shards <= 0:
		return
	var count: int = maxi(pieces, 1)
	for i: int in count:
		# Integer split, remainder onto the first piles, so nothing is lost to
		# rounding and no pile is empty.
		var amount: int = shards / count + (1 if i < shards % count else 0)
		if amount <= 0:
			continue
		var angle: float = TAU * float(i) / float(count)
		var id: int = _next_bundle_id
		_next_bundle_id += 1
		_spawn_bundle.rpc(id, where + Vector3(cos(angle), 0.0, sin(angle)) * 1.4, amount)
	print("[Run] dropped %d data across %d bundles at %s" % [
		shards, count, str(where.snapped(Vector3.ONE * 0.1))])


## Host-side, called by a bundle a player has walked over.
func take_bundle(bundle_id: int, peer_id: int) -> void:
	if not multiplayer.is_server() or not is_running(peer_id):
		return
	_apply_bundle.rpc(bundle_id, peer_id)


# ------------------------------------------------------------------ requests --

## Local player finished a siphon channel. Host validates and applies.
func request_siphon(index: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_siphon_request.rpc_id(1, index)


## Local player finished the shaft channel.
func request_descend() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_descend_request.rpc_id(1)


## Local player finished a restore channel on `peer_id`.
func request_restore(peer_id: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_restore_request.rpc_id(1, peer_id)


## Local player pulled the breaker's trigger. The host re-casts the ray: the
## client draws its own lash immediately for feel, but nothing dies on a client's
## say-so.
func request_breaker(origin: Vector3, direction: Vector3) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_breaker_request.rpc_id(1, origin, direction)


## Local player threw a flare.
func request_flare(origin: Vector3, velocity: Vector3) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_flare_request.rpc_id(1, origin, velocity)


func request_root_backdoor() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_root_request.rpc_id(1)


func request_exfil() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_exfil_request.rpc_id(1)


## Host-side helper for anything that wants to say something to the whole crew.
func broadcast_notice(message: String) -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	_starvation_notice.rpc(message)


@rpc("any_peer", "call_local", "reliable")
func _siphon_request(index: int) -> void:
	if not multiplayer.is_server() or run_over or descending:
		return
	if spent_siphons.has(index):
		return

	# Proximity check: the channel ran on the requesting client, so this is the
	# one place that can tell "stood at the tap for 2.5 s" from "sent a packet".
	var sender: int = _sender()
	var tap: Node = _find_tap(index)
	var player: Node = Net.get_player(sender)
	if tap == null or player == null:
		return
	if (tap as Node3D).global_position.distance_to((player as Node3D).global_position) > 6.0:
		push_warning("[Run] siphon %d refused: peer %d is too far away" % [index, sender])
		return

	spent_siphons[index] = true
	siphons_drained += 1
	cycles = minf(cycles + Balance.SIPHON_YIELD, cycles_max)
	_apply_siphon.rpc(index, cycles)


@rpc("any_peer", "call_local", "reliable")
func _descend_request() -> void:
	if not multiplayer.is_server() or descending or run_over:
		return
	if not crew_intact():
		push_warning("[Run] descent refused: a crewmate is corrupted")
		return
	_update_muster()
	if not crew_mustered():
		push_warning("[Run] descent refused: crew not mustered (%d/%d)" % [
			muster_inside, muster_total])
		return
	_begin_descent.rpc(layer_number + 1)


## A crewmate held the restore channel on someone. The host checks they are
## actually stood over them, then brings them back hurt.
@rpc("any_peer", "call_local", "reliable")
func _restore_request(peer_id: int) -> void:
	if not multiplayer.is_server() or run_over:
		return
	if not is_corrupted(peer_id):
		return
	var sender: int = _sender()
	if sender == peer_id or not is_running(sender):
		return

	var rescuer: Node = Net.get_player(sender)
	var casualty: Node = Net.get_player(peer_id)
	if rescuer == null or casualty == null:
		return
	if (rescuer as Node3D).global_position.distance_to(
			(casualty as Node3D).global_position) > Balance.RESTORE_REACH:
		push_warning("[Run] restore refused: peer %d is not stood over %d" % [sender, peer_id])
		return

	corrupted.erase(peer_id)
	integrity[peer_id] = Balance.RESTORE_INTEGRITY
	_dirty_health = true
	print("[Run] %s restored %s at %d%% integrity" % [
		Net.crew_name(sender), Net.crew_name(peer_id), int(Balance.RESTORE_INTEGRITY)])
	_restored.rpc(peer_id, sender)


@rpc("any_peer", "call_local", "reliable")
func _breaker_request(origin: Vector3, direction: Vector3) -> void:
	if not multiplayer.is_server() or run_over:
		return
	var sender: int = _sender()
	if not is_running(sender):
		return

	# Rate limit and a sanity check on where the shot came from. Neither is a
	# full anti-cheat pass (M4 tightens movement authority); both stop a broken
	# or spamming client from emptying a layer.
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - float(_last_shot.get(sender, -99.0)) < Balance.BREAKER_COOLDOWN * 0.8:
		return
	_last_shot[sender] = now

	var player: Node = Net.get_player(sender)
	if player == null or not is_instance_valid(player):
		return
	if (player as Node3D).global_position.distance_to(origin) > 3.0:
		push_warning("[Run] breaker shot refused: peer %d fired from %s" % [sender, str(origin)])
		return

	var endpoint: Vector3 = origin + direction.normalized() * Balance.BREAKER_RANGE
	var killed: bool = false
	## Which kind of process died, for the kill feed and the achievement hooks.
	## Empty on a miss or a survivor.
	var kind: String = ""
	var creature: Antivirus = Antivirus.pick_target(get_tree(), _layer_space(), origin, direction)
	if creature != null:
		var damage: float = creature.breaker_damage(origin)
		endpoint = creature.aim_point()
		creature.take_damage(damage, origin)
		killed = damage > 0.0 and creature.health <= 0.0
		if killed:
			kind = creature.get_script().get_global_name()
	if Debug.log_ai:
		print("[AI] breaker shot by %d: %s" % [sender,
			"miss" if creature == null else "%s hp=%.0f%s" % [
				String(creature.name), maxf(creature.health, 0.0),
				"  KILL" if killed else ""]])
	_breaker_shot.rpc(sender, origin, endpoint, killed, kind)


func _layer_space() -> PhysicsDirectSpaceState3D:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null:
		return null
	return (layer as Node3D).get_world_3d().direct_space_state


@rpc("any_peer", "call_local", "reliable")
func _flare_request(origin: Vector3, velocity: Vector3) -> void:
	if not multiplayer.is_server() or run_over:
		return
	var sender: int = _sender()
	if not is_running(sender) or flares_of(sender) <= 0:
		return

	flares[sender] = flares_of(sender) - 1
	_dirty_buffers = true
	# Igniting one costs the crew, not the thrower: the pool is shared, and so is
	# the argument about who keeps burning them.
	cycles = maxf(cycles - Balance.FLARE_CYCLE_COST, 0.0)
	cycles_changed.emit(cycles)

	var id: int = _next_flare_id
	_next_flare_id += 1
	_spawn_flare.rpc(id, sender, origin, velocity)


@rpc("any_peer", "call_local", "reliable")
func _root_request() -> void:
	if not multiplayer.is_server() or run_over or backdoor_rooted:
		return
	_apply_root.rpc(layer_number)


@rpc("any_peer", "call_local", "reliable")
func _exfil_request() -> void:
	if not multiplayer.is_server() or run_over or exfil_calling or not backdoor_rooted:
		return
	_begin_exfil.rpc(Balance.EXFIL_COUNTDOWN)


## The window closed. Everyone on the pad banks their buffer and gets out;
## everyone else is left inside with the uplink shut behind them.
func _fire_exfil() -> void:
	if run_over:
		return
	run_over = true
	exfil_calling = false

	var pad: Vector3 = _uplink_position()
	var banked: Dictionary = {}
	## Who was actually stood on the pad when it fired. Distinct from `banked`,
	## which is zero for an agent who got out empty-handed.
	var escaped: Array = []
	var left_behind: PackedStringArray = PackedStringArray()

	for id: int in Net.crew.keys():
		var peer: int = int(id)
		var player: Node = Net.get_player(peer)
		var on_pad: bool = false
		if is_running(peer) and player != null and is_instance_valid(player):
			var pos: Vector3 = (player as Node3D).global_position
			on_pad = Vector2(pos.x - pad.x, pos.z - pad.z).length() <= Balance.EXFIL_PAD_RADIUS
		if on_pad:
			banked[peer] = buffered_of(peer)
			escaped.append(peer)
		else:
			banked[peer] = 0
			left_behind.append(Net.crew_name(peer))

	print("[Run] exfiltration fired: banked=%s escaped=%s left_behind=[%s]" % [
		str(banked), str(escaped), ", ".join(left_behind)])
	_end_run.rpc(_summary("EXFILTRATED", true, banked, escaped))


func _uplink_position() -> Vector3:
	for node: Node in get_tree().get_nodes_in_group("exfil_uplinks"):
		var uplink: ExfilUplink = node as ExfilUplink
		if uplink != null and is_instance_valid(uplink):
			return uplink.global_position
	return Vector3.ZERO


## Dev only (`--decompile-at`). M3 has real damage sources, so this now goes
## through the real door — lethal damage to the local avatar — rather than a
## private path that skips corruption, spilled buffers and the restore window.
func request_debug_decompile() -> void:
	if multiplayer.has_multiplayer_peer():
		_debug_decompile.rpc_id(1)


@rpc("any_peer", "call_local", "reliable")
func _debug_decompile() -> void:
	if not multiplayer.is_server():
		return
	var sender: int = _sender()
	var player: Node = Net.get_player(sender)
	var from: Vector3 = Vector3.ZERO
	if player != null and is_instance_valid(player):
		from = (player as Node3D).global_position + Vector3.FORWARD * 2.0
	damage_player(sender, Balance.INTEGRITY_MAX * 2.0, from)


func _sender() -> int:
	var sender: int = multiplayer.get_remote_sender_id()
	return 1 if sender == 0 else sender


func _find_tap(index: int) -> Node:
	for node: Node in get_tree().get_nodes_in_group("siphon_taps"):
		var tap: SiphonTap = node as SiphonTap
		if tap != null and tap.tap_index == index:
			return tap
	return null


## Where dynamic props (flares, dropped bundles) are parented. They belong to the
## layer, so a descent frees them with everything else.
func _dynamic_root() -> Node:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null:
		return null
	return layer.get_node_or_null("Dynamic")


# ---------------------------------------------------------------------- rpcs --

@rpc("authority", "call_remote", "unreliable_ordered")
func _push_pool(value: float, maximum: float) -> void:
	cycles = value
	cycles_max = maximum
	cycles_changed.emit(cycles)


@rpc("authority", "call_remote", "reliable")
func _push_health(values: Dictionary, down: Dictionary, gone: Dictionary) -> void:
	integrity = values
	corrupted = down
	deleted = gone
	integrity_changed.emit()
	corruption_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _push_buffers(values: Dictionary, stock: Dictionary) -> void:
	buffered = values
	flares = stock
	buffers_changed.emit()


@rpc("authority", "call_local", "reliable")
func _push_muster(inside: int, total: int) -> void:
	muster_inside = inside
	muster_total = total
	muster_changed.emit(inside, total)


@rpc("authority", "call_local", "reliable")
func _apply_siphon(index: int, pool: float) -> void:
	spent_siphons[index] = true
	cycles = pool
	cycles_changed.emit(cycles)
	siphon_taken.emit(index, pool)
	notice.emit("SIPHON TAP DRAINED  ·  +%d CYCLES" % int(Balance.SIPHON_YIELD))


@rpc("authority", "call_local", "reliable")
func _apply_shard(index: int, peer_id: int, worth: int) -> void:
	taken_shards[index] = true
	if not multiplayer.is_server():
		buffered[peer_id] = buffered_of(peer_id) + 1
	shard_taken.emit(index, peer_id, worth)
	buffers_changed.emit()


@rpc("authority", "call_local", "reliable")
func _apply_bundle(bundle_id: int, peer_id: int) -> void:
	# The bundle knows its own size; the host reads it back off the node so the
	# amount never has to be trusted from anywhere else.
	var amount: int = 0
	for node: Node in get_tree().get_nodes_in_group("data_bundles"):
		var bundle: DataBundle = node as DataBundle
		if bundle != null and is_instance_valid(bundle) and bundle.bundle_id == bundle_id:
			amount = bundle.amount
			break
	buffered[peer_id] = buffered_of(peer_id) + amount
	bundle_taken.emit(bundle_id, peer_id)
	buffers_changed.emit()
	if peer_id == Net.local_id():
		notice.emit("BUNDLE RECOVERED  ·  +%d DATA" % amount)


@rpc("authority", "call_local", "reliable")
func _spawn_bundle(bundle_id: int, where: Vector3, amount: int) -> void:
	var root: Node = _dynamic_root()
	if root == null:
		return
	root.add_child(DataBundle.create(bundle_id, where, amount))


@rpc("authority", "call_local", "reliable")
func _spawn_flare(flare_id: int, peer_id: int, origin: Vector3, velocity: Vector3) -> void:
	var root: Node = _dynamic_root()
	if root == null:
		return
	root.add_child(Flare.create(flare_id, peer_id, origin, velocity))


## The lash every peer sees. The shooter has already drawn its own (locally,
## the frame it pulled the trigger) and only wants the kill confirmation.
@rpc("authority", "call_local", "reliable")
func _breaker_shot(peer_id: int, origin: Vector3, endpoint: Vector3, killed: bool,
		kind: String = "") -> void:
	if killed:
		# Every peer hears about every kill; who fired is in the packet, so the
		# listener decides whether it was theirs.
		process_deleted.emit(peer_id, kind)
	var player: Node = Net.get_player(peer_id)
	if player == null or not is_instance_valid(player):
		return
	var avatar: Player = player as Player
	if avatar == null:
		return
	avatar.show_breaker_shot(origin, endpoint, killed, peer_id == Net.local_id())


@rpc("authority", "call_local", "reliable")
func _starvation_notice(message: String) -> void:
	notice.emit(message)


@rpc("authority", "call_local", "reliable")
func _corrupt_notice(peer_id: int) -> void:
	if not multiplayer.is_server():
		corrupted[peer_id] = Balance.CORRUPT_DECAY
		integrity[peer_id] = 0.0
	corruption_changed.emit()
	integrity_changed.emit()
	notice.emit("%s CORRUPTED  ·  RESTORE THEM" % Net.crew_name(peer_id))


@rpc("authority", "call_local", "reliable")
func _restored(peer_id: int, by_peer: int) -> void:
	corrupted.erase(peer_id)
	integrity[peer_id] = Balance.RESTORE_INTEGRITY
	corruption_changed.emit()
	integrity_changed.emit()
	restored.emit(peer_id, by_peer)
	notice.emit("%s RESTORED BY %s" % [Net.crew_name(peer_id), Net.crew_name(by_peer)])


@rpc("authority", "call_local", "reliable")
func _decompile(peer_id: int, message: String) -> void:
	integrity[peer_id] = 0.0
	corrupted.erase(peer_id)
	deleted[peer_id] = true
	buffered[peer_id] = 0
	integrity_changed.emit()
	corruption_changed.emit()
	buffers_changed.emit()
	decompiled.emit(peer_id)
	notice.emit(message)


@rpc("authority", "call_local", "reliable")
func _damage_flash(from: Vector3) -> void:
	damaged.emit(from)


@rpc("authority", "call_local", "reliable")
func _apply_root(rooted_layer: int) -> void:
	backdoor_rooted = true
	backdoor_rooted_changed.emit()
	notice.emit("BACKDOOR INSTALLED  ·  LAYER %02d" % rooted_layer)
	# Every peer records the node it just watched come up: DESIGN.md keeps
	# backdoors per player, and everyone present installed this one.
	GameState.record_backdoor(rooted_layer)


@rpc("authority", "call_local", "reliable")
func _begin_exfil(seconds: float) -> void:
	exfil_calling = true
	exfil_remaining = seconds
	exfil_changed.emit()
	notice.emit("EXFILTRATION CALLED  ·  %d SECONDS" % int(seconds))


## Every peer runs this. The Layer scene listens for `descent_started`, covers
## the screen, frees the old geometry and generates `next_layer` locally — no
## geometry ever crosses the wire, only this number.
@rpc("authority", "call_local", "reliable")
func _begin_descent(next_layer: int) -> void:
	if descending:
		return
	descending = true
	descent_started.emit(next_layer)


## Called by the Layer on every peer once its new geometry is standing. On the
## host this also commits the new layer number to authoritative state.
func finish_descent(next_layer: int) -> void:
	layer_number = next_layer
	deepest_layer = maxi(deepest_layer, next_layer)
	descending = false
	spent_siphons.clear()
	taken_shards.clear()
	backdoor_rooted = false
	exfil_calling = false
	exfil_remaining = 0.0
	muster_inside = 0
	muster_total = 0
	layer_changed.emit(next_layer)
	descent_finished.emit()
	backdoor_rooted_changed.emit()
	exfil_changed.emit()
	notice.emit("LAYER %02d" % next_layer)


@rpc("authority", "call_local", "reliable")
func _end_run(summary: Dictionary) -> void:
	run_over = true
	# The countdown is over however it ended. Clients run their own copy of the
	# clock, so they have to be told to stop rather than left showing 00.
	exfil_calling = false
	exfil_remaining = 0.0
	exfil_changed.emit()
	print("[Run] run over: %s (success=%s, layers=%d)" % [
		String(summary.get("reason", "?")), str(summary.get("success", false)),
		int(summary.get("layers", 1))])
	# Banking is per-player and local: the archive lives on your machine
	# (DESIGN.md "each player's program saves locally").
	var banked: Dictionary = summary.get("banked", {}) as Dictionary
	var mine: int = int(banked.get(Net.local_id(), 0))
	if bool(summary.get("success", false)) and mine > 0:
		GameState.bank(mine)
	run_ended.emit(summary)


## The debrief payload. Built host-side so every peer shows the same numbers.
func _summary(reason: String, success: bool, banked: Dictionary,
		escaped: Array = []) -> Dictionary:
	return {
		"reason": reason,
		"success": success,
		"banked": banked,
		"escaped": escaped,
		"crew": Net.crew.size(),
		"deleted": deleted.keys().size(),
		"layers": deepest_layer,
		"start_layer": 1,
		"siphons": siphons_drained,
		"seconds": float(Time.get_ticks_msec() - _run_started_msec) / 1000.0,
	}
