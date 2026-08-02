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
## Host-side, every breaker shot (hit or miss). The muzzle flash is a light, which
## is why M6's Moth is drawn to it — the HauntDirector tracks these so a fighting
## crew feeds the one hunter that comes to light.
signal breaker_fired(by_peer: int, origin: Vector3)
## The local avatar's own shot resolved, for crosshair feedback ONLY.
##
## Emitted locally by Player and never replicated — no RPC signature changes, no
## extra bytes. `hit` is the shooter's own prediction (the same one that decides
## where its lash stops, a round trip before the host agrees); `killed` is the
## authoritative flag coming back off `_breaker_shot`. Presentation may be
## predicted; a kill confirmation may not.
signal local_shot(hit: bool, killed: bool)
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

## peer id -> shards held. This is a **count of chips**, and it is what the
## carry-weight rule reads: what slows you down is how much you are holding, not
## what it happens to be worth.
var buffered: Dictionary = {}
## peer id -> data units held. This is the **value** of that buffer — the number
## DESIGN.md's "every layer deeper multiplies the haul" is about, the number a
## Compiler spends, and the number that banks to the archive on exfiltration.
##
## M3 conflated the two (it banked the chip count and used the per-layer worth
## for nothing but the pickup readout), which meant a layer-15 haul was worth
## exactly as much as a layer-1 haul. M4 needs a real price curve, so the two are
## separate: `buffered` is weight, `buffered_value` is money.
var buffered_value: Dictionary = {}
## peer id -> flares in stock. Ceiling is the carrier's Cache tier.
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
## And the one it started at — 1 for a surface run, 6/11/16 for a backdoor
## injection. Both halves of "descended N -> M" have to be real numbers.
var start_layer: int = 1
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
	start_layer = layer_number
	use_test_layer = test_layer
	spent_siphons.clear()
	taken_shards.clear()
	integrity.clear()
	corrupted.clear()
	deleted.clear()
	buffered.clear()
	buffered_value.clear()
	flares.clear()
	descending = false
	run_over = false
	backdoor_rooted = false
	exfil_calling = false
	exfil_remaining = 0.0
	siphons_drained = 0
	_run_started_msec = Time.get_ticks_msec()
	cycles_max = Modules.crew_pool_max()
	cycles = cycles_max
	if Debug.start_cycles >= 0.0:
		cycles = minf(Debug.start_cycles, cycles_max)
	_display_cycles = cycles
	configured = true
	print("[Run] intrusion begins on layer %d, pool %.0f (%s)" % [
		layer_number, cycles, "test layer" if test_layer else "procedural"])
	config_changed.emit()
	cycles_changed.emit(cycles)


## Everything the crew has already done to the layer a joiner is about to walk
## into. Seeded content (taps, shards, the node, the uplink) exists identically
## on every peer, so what has to travel is not the objects — it is which of them
## are already spent.
##
## Sent once, inside the join handshake. It is deliberately a dictionary rather
## than more positional arguments: this list has grown twice already, and the
## audit's "the handshake should be one state packet" is the shape that stops it
## growing into a fifteen-argument RPC.
func layer_state() -> Dictionary:
	return {
		"siphons": spent_siphons.keys(),
		"shards": taken_shards.keys(),
		"rooted": backdoor_rooted,
		"exfil": exfil_calling,
		"exfil_left": exfil_remaining,
	}


## Client: adopt the host's world configuration. Arrives before the spawn packet
## (both reliable on the same channel), so geometry exists before the player does.
##
## `state` is applied BEFORE `config_changed` fires, because that signal is what
## makes the Layer build its geometry — and a fresh siphon tap asks Run whether
## it is already spent as it enters the tree, exactly the way it does on a
## descent (see `finish_descent`).
func adopt(layer: int, test_layer: bool, pool: float, maximum: float,
		state: Dictionary = {}) -> void:
	layer_number = maxi(layer, 1)
	deepest_layer = maxi(deepest_layer, layer_number)
	# A joiner's own run starts wherever they walked in, which is what their
	# debrief is about — the host's summary is the one that speaks for the crew.
	start_layer = layer_number
	use_test_layer = test_layer
	cycles = pool
	cycles_max = maximum
	_display_cycles = pool
	descending = false
	run_over = false
	_adopt_layer_state(state)
	configured = true
	config_changed.emit()
	cycles_changed.emit(cycles)
	backdoor_rooted_changed.emit()
	exfil_changed.emit()


func _adopt_layer_state(state: Dictionary) -> void:
	spent_siphons.clear()
	taken_shards.clear()
	for index: Variant in state.get("siphons", []):
		spent_siphons[int(index)] = true
	for index: Variant in state.get("shards", []):
		taken_shards[int(index)] = true
	backdoor_rooted = bool(state.get("rooted", false))
	exfil_calling = bool(state.get("exfil", false))
	exfil_remaining = maxf(float(state.get("exfil_left", 0.0)), 0.0)


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
		var loadout: Dictionary = Modules.loadout(peer)
		if not integrity.has(peer):
			integrity[peer] = float(loadout["integrity"])
		if not buffered.has(peer):
			buffered[peer] = 0
		if not buffered_value.has(peer):
			buffered_value[peer] = 0
		if not flares.has(peer):
			flares[peer] = int(loadout["flares"])

	var updated: float = Modules.crew_pool_max()
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
	buffered_value.erase(peer_id)
	flares.erase(peer_id)
	if not configured:
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	cycles_max = Modules.crew_pool_max()
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
	buffered_value.clear()
	flares.clear()
	spent_siphons.clear()
	taken_shards.clear()
	muster_inside = 0
	muster_total = 0
	deepest_layer = 1
	start_layer = 1
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


## What that buffer is worth. The number a Compiler spends and the archive banks.
func buffered_value_of(peer_id: int) -> int:
	return int(buffered_value.get(peer_id, 0))


## `peer_id`'s integrity ceiling, which their Checksum tier raises. Everything
## that used to read Balance.INTEGRITY_MAX for a specific player goes through
## here instead — the regen clamp, the HUD's percentage, and the restore.
func integrity_max_of(peer_id: int) -> float:
	return float(Modules.loadout(peer_id)["integrity"])


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


func local_buffered_value() -> int:
	return buffered_value_of(Net.local_id())


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
	# Buffer tiers raise what you carry free and soften what the rest costs;
	# Servos raise the top speed the whole thing is multiplying. Both are read
	# off the local program because movement is client-authoritative — the host
	# is not simulating this player's velocity, it is only billing for it.
	var loadout: Dictionary = Modules.local_loadout()
	return multiplier * float(loadout["move"]) * Balance.carry_multiplier(
			local_buffered(), int(loadout["carry_free"]), float(loadout["carry_penalty"]))


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
	var hurt: float = 1.0 - clampf(
			local_integrity() / maxf(integrity_max_of(Net.local_id()), 1.0), 0.0, 1.0)
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
		_push_buffers.rpc(buffered, buffered_value, flares)


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
		# Runtime lowers what existing costs you; Threading lowers what sprinting
		# adds on top. Both are resolved from the tiers this peer announced, on
		# the host, which is the only copy of them the billing is allowed to
		# believe.
		var loadout: Dictionary = Modules.loadout(int(id))
		var rate: float = float(loadout["drain"])
		var player: Node = Net.get_player(int(id))
		if player != null and is_instance_valid(player):
			var speed: float = float(player.get("sync_speed"))
			if speed >= Balance.SPRINT_BILLING_SPEED:
				rate *= float(loadout["sprint"])
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
	if descending:
		return  # the layer is being rewritten; nobody is running.
	var empty: bool = starved()

	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not is_running(peer):
			continue
		var value: float = integrity_of(peer)
		var ceiling: float = integrity_max_of(peer)

		if empty:
			value = maxf(value - Balance.STARVED_INTEGRITY_DRAIN * delta, 0.0)
		elif value < ceiling:
			value = minf(value + Balance.INTEGRITY_REGEN * delta, ceiling)
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
	if descending:
		return  # the layer is being rewritten; nobody is running.
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
		str(corrupted.keys()), str(buffered_value)])


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
	buffered_value[peer_id] = 0
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
	var value: int = buffered_value_of(peer_id)
	buffered[peer_id] = 0
	buffered_value[peer_id] = 0
	_dirty_buffers = true
	var id: int = _next_bundle_id
	_next_bundle_id += 1
	print("[Run] %s spilled %d chips worth %d data" % [
		Net.crew_name(peer_id), amount, value])
	_spawn_bundle.rpc(id, (player as Node3D).global_position, amount, value)


# -------------------------------------------------------------------- salvage --

## Host-side, called by a shard that has reached a player.
func take_shard(index: int, peer_id: int, worth: int) -> void:
	if not multiplayer.is_server() or taken_shards.has(index):
		return
	if not is_running(peer_id):
		return
	taken_shards[index] = true
	buffered[peer_id] = buffered_of(peer_id) + 1
	buffered_value[peer_id] = buffered_value_of(peer_id) + maxi(worth, 1)
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
	# What a Sentinel was standing on is worth what this layer's chips are worth.
	var worth: int = Balance.shard_value(layer_number)
	for i: int in count:
		# Integer split, remainder onto the first piles, so nothing is lost to
		# rounding and no pile is empty.
		var amount: int = shards / count + (1 if i < shards % count else 0)
		if amount <= 0:
			continue
		var angle: float = TAU * float(i) / float(count)
		var id: int = _next_bundle_id
		_next_bundle_id += 1
		_spawn_bundle.rpc(id, where + Vector3(cos(angle), 0.0, sin(angle)) * 1.4,
				amount, amount * worth)
	print("[Run] dropped %d chips worth %d data across %d bundles at %s" % [
		shards, shards * worth, count, str(where.snapped(Vector3.ONE * 0.1))])


## A Compiler took `amount` data out of `peer_id`'s buffer (Modules validated the
## purchase; this is the debit). The chip count comes down with it, in
## proportion: what you handed the Compiler was chips, and chips are the heavy
## half of a haul — a purchase should visibly lighten you.
##
## Runs on every peer. The host's copy is authoritative and will be pushed out
## with the next buffer packet; a client applies the same arithmetic immediately
## so the panel it is looking at does not sit on a stale number for 250 ms.
func spend_buffer(peer_id: int, amount: int) -> void:
	if amount <= 0:
		return
	var value: int = buffered_value_of(peer_id)
	var chips: int = buffered_of(peer_id)
	var spent: int = mini(amount, value)
	if value > 0 and chips > 0:
		# Ceil, so spending everything always empties the buffer rather than
		# leaving one weightless chip behind.
		buffered[peer_id] = maxi(chips - int(ceil(float(chips) * float(spent)
				/ float(value))), 0)
	buffered_value[peer_id] = maxi(value - spent, 0)
	_dirty_buffers = true
	buffers_changed.emit()


## Host-side. Hands `peer_id` flares out of something they found — M4.8's
## lootable cabinets, and whatever restocks after them. Clamped to the carrier's
## own Cache tier: a cabinet cannot put a fourth flare in a program that only
## compiled three, or the track stops being a purchase.
func grant_flares(peer_id: int, count: int) -> void:
	if not multiplayer.is_server() or count <= 0 or not is_running(peer_id):
		return
	var ceiling: int = int(Modules.loadout(peer_id)["flares"])
	var before: int = flares_of(peer_id)
	var after: int = mini(before + count, ceiling)
	if after == before:
		return
	flares[peer_id] = after
	_dirty_buffers = true
	_flare_granted.rpc_id(peer_id, after - before)
	if peer_id == 1:
		notice.emit("FLARE RECOVERED  ·  %d IN CACHE" % after)


@rpc("authority", "call_remote", "reliable")
func _flare_granted(count: int) -> void:
	notice.emit("FLARE RECOVERED  ·  +%d" % count)


## Host-side, called by a bundle a player has walked over.
##
## The amount and the worth are read off the host's own node here and put IN the
## packet. They used to be re-derived on each peer by searching the
## `data_bundles` group — which a peer that joined after `_spawn_bundle` was
## broadcast has no member of, so it silently added zero while the host added the
## real value, and nothing corrected it.
func take_bundle(bundle_id: int, peer_id: int) -> void:
	if not multiplayer.is_server() or not is_running(peer_id):
		return
	var bundle: DataBundle = _find_bundle(bundle_id)
	if bundle == null:
		return
	_apply_bundle.rpc(bundle_id, peer_id, bundle.amount, bundle.worth)


## Host: re-send the layer's live, un-seeded objects to one joining peer.
##
## Bundles and flares are broadcast at spawn time and never again, so a peer that
## joined afterwards has none of them: already-banked haul lay on the floor and
## could be walked over with no effect, because the node it would have collided
## with does not exist on that machine. Sent `rpc_id`, so the peers that already
## have them are not asked to build a second copy.
##
## Flares resume from where they are rather than from where they were thrown, and
## their 20 s burn restarts — a joiner sees a flare that will outlast everyone
## else's by a few seconds. That is the cheap answer and the right one: the
## alternative is putting a lifetime on the wire for a cosmetic light.
func replay_dynamics(peer_id: int) -> void:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	for node: Node in get_tree().get_nodes_in_group("data_bundles"):
		var bundle: DataBundle = node as DataBundle
		if bundle == null or not is_instance_valid(bundle):
			continue
		_spawn_bundle.rpc_id(peer_id, bundle.bundle_id, bundle.global_position,
				bundle.amount, bundle.worth)
	for node: Node in get_tree().get_nodes_in_group("flares"):
		var flare: Flare = node as Flare
		if flare == null or not is_instance_valid(flare):
			continue
		_spawn_flare.rpc_id(peer_id, flare.flare_id, flare.thrower,
				flare.global_position, Vector3.ZERO)


func _find_bundle(bundle_id: int) -> DataBundle:
	for node: Node in get_tree().get_nodes_in_group("data_bundles"):
		var bundle: DataBundle = node as DataBundle
		if bundle != null and is_instance_valid(bundle) and bundle.bundle_id == bundle_id:
			return bundle
	return null


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
	var player: Node3D = _requesting_body()
	if tap == null or player == null:
		return
	if not ((tap as Node3D).global_position.distance_to(player.global_position) <= USE_REACH):
		push_warning("[Run] siphon %d refused: peer %d is too far away" % [index, sender])
		return

	spent_siphons[index] = true
	siphons_drained += 1
	# M4.9 (balance lab): crew-scaled yield. A flat 70 refilled the same absolute
	# amount into a 100-Cycle solo pool and a 400-Cycle four-crew pool, so a tap
	# was worth 4x as much of the clock to a solo agent and left big crews
	# perpetually starved. Scaling by crew keeps a tap worth roughly the same
	# FRACTION of the pool at any size. Solo (0.55 + 0.45*1 = 1.0) is unchanged;
	# four crew return 2.35x. Host-only path, so Net.crew is authoritative here.
	var crew: int = maxi(Net.crew.size(), 1)
	cycles = minf(cycles + Balance.SIPHON_YIELD * (0.55 + 0.45 * float(crew)), cycles_max)
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

	var rescuer: Node3D = _requesting_body()
	var casualty: Node = Net.get_player(peer_id)
	if rescuer == null or casualty == null or not is_instance_valid(casualty):
		return
	if not (rescuer.global_position.distance_to(
			(casualty as Node3D).global_position) <= Balance.RESTORE_REACH):
		push_warning("[Run] restore refused: peer %d is not stood over %d" % [sender, peer_id])
		return

	corrupted.erase(peer_id)
	# You come back on the same fraction of your own ceiling, so a Checksum build
	# is restored to more absolute integrity and not to a flat 40 that shrinks
	# into irrelevance as the track goes up.
	integrity[peer_id] = integrity_max_of(peer_id) \
			* (Balance.RESTORE_INTEGRITY / Balance.INTEGRITY_MAX)
	_dirty_health = true
	print("[Run] %s restored %s at %d%% integrity" % [
		Net.crew_name(sender), Net.crew_name(peer_id),
		int(round(100.0 * Balance.RESTORE_INTEGRITY / Balance.INTEGRITY_MAX))])
	_restored.rpc(peer_id, sender, integrity_of(peer_id))


@rpc("any_peer", "call_local", "reliable")
func _breaker_request(origin: Vector3, direction: Vector3) -> void:
	if not multiplayer.is_server() or run_over:
		return
	var sender: int = _sender()
	if not is_running(sender):
		return
	# Before anything else, because everything below uses these two: a NaN origin
	# used to pass the proximity guard below (it was spelled `> 3.0`, and every
	# comparison against NaN is false), `direction.normalized()` then returned
	# zero with an engine error, and the resulting NaN endpoint was broadcast into
	# every peer's `Breaker.show_lash`.
	if not origin.is_finite() or not direction.is_finite():
		push_warning("[Run] breaker shot refused: peer %d sent a non-finite shot" % sender)
		return
	if direction.length_squared() <= 0.000001:
		return

	# Rate limit and a sanity check on where the shot came from. Neither is a
	# full anti-cheat pass (M4 tightens movement authority); both stop a broken
	# or spamming client from emptying a layer.
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - float(_last_shot.get(sender, -99.0)) < Balance.BREAKER_COOLDOWN * 0.8:
		return
	_last_shot[sender] = now

	var player: Node3D = _requesting_body()
	if player == null:
		return
	if not (player.global_position.distance_to(origin) <= ORIGIN_REACH):
		push_warning("[Run] breaker shot refused: peer %d fired from %s" % [sender, str(origin)])
		return

	# Breaker tiers are resolved here and nowhere else: the shooter drew a lash
	# on its own screen a round trip ago, but what the shot is *worth* and how far
	# it reaches are decided against the tiers the host has for that peer.
	var loadout: Dictionary = Modules.loadout(sender)
	var reach: float = float(loadout["range"])
	var endpoint: Vector3 = origin + direction.normalized() * reach
	var killed: bool = false
	## Which kind of process died, for the kill feed and the achievement hooks.
	## Empty on a miss or a survivor.
	var kind: String = ""
	var creature: Antivirus = Antivirus.pick_target(
			get_tree(), _layer_space(), origin, direction, reach)
	if creature != null:
		var damage: float = creature.breaker_damage(origin, float(loadout["damage"]))
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
	# The muzzle flash: a light the Moth reads (M6). Host-side and local — the
	# Director tracks it per shooter; nothing extra crosses the wire for it.
	breaker_fired.emit(sender, origin)
	_breaker_shot.rpc(sender, origin, endpoint, killed, kind)


func _layer_space() -> PhysicsDirectSpaceState3D:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null:
		return null
	return (layer as Node3D).get_world_3d().direct_space_state


## Both vectors here are client-authored and both are consumed by **every peer**
## for the flare's whole 20 s life: it integrates its velocity through a raycast
## each physics frame and carries a shadow-casting light. So both are checked.
## An unvalidated origin was free room lighting — and free Scrubber repulsion,
## since `Antivirus._in_player_light` treats any burning flare as exposure —
## dropped anywhere on the layer; a non-finite one poisoned every peer's physics
## query and renderer for 20 s on a node nothing could clear.
@rpc("any_peer", "call_local", "reliable")
func _flare_request(origin: Vector3, velocity: Vector3) -> void:
	if not multiplayer.is_server() or run_over:
		return
	var sender: int = _sender()
	if not is_running(sender) or flares_of(sender) <= 0:
		return
	if not origin.is_finite() or not velocity.is_finite():
		push_warning("[Run] flare refused: peer %d sent a non-finite throw" % sender)
		return
	var body: Node3D = _requesting_body()
	if body == null:
		return
	if not (body.global_position.distance_to(origin) <= ORIGIN_REACH):
		push_warning("[Run] flare refused: peer %d threw from %s" % [sender, str(origin)])
		return
	var throw: Vector3 = velocity.limit_length(
			Balance.FLARE_THROW_SPEED * THROW_SPEED_LIMIT)

	flares[sender] = flares_of(sender) - 1
	_dirty_buffers = true
	# Igniting one costs the crew, not the thrower: the pool is shared, and so is
	# the argument about who keeps burning them.
	cycles = maxf(cycles - Balance.FLARE_CYCLE_COST, 0.0)
	cycles_changed.emit(cycles)

	var id: int = _next_flare_id
	_next_flare_id += 1
	_spawn_flare.rpc(id, sender, origin, throw)


## The most heavily validated request in the game, because it is the only one
## whose effect is written to **every peer's save file**: a rooted backdoor is
## permanent progression for everybody present. Until M4.8.1 it validated nothing
## at all — not position, not layer, not liveness — so a modified client could
## sit on layer 1 and permanently rewrite four other people's programs, or fire
## it at layer 24 and hand the whole crew injection at 25. The documented threat
## model accepts a player editing *their own* save; this was a different thing.
@rpc("any_peer", "call_local", "reliable")
func _root_request() -> void:
	if not multiplayer.is_server() or run_over or descending or backdoor_rooted:
		return
	# Question 0, which only this request has: does the layer even have a node?
	if not bool(LayerParams.of(layer_number).get("has_backdoor", false)):
		push_warning("[Run] root refused: layer %d has no maintenance node" % layer_number)
		return
	var body: Node3D = _requesting_body()
	if body == null:
		return
	var node: Node3D = _find_backdoor_node()
	if node == null:
		push_warning("[Run] root refused: no maintenance node is standing")
		return
	if not (node.global_position.distance_to(body.global_position) <= USE_REACH):
		push_warning("[Run] root refused: peer %d is not at the node" % _sender())
		return
	_apply_root.rpc(layer_number)


## Ends the run for the whole crew on a 20 s fuse, so it gets the same preamble.
## A spectating or modified client used to be able to start it from anywhere on
## the layer, and everyone not on the pad when it fired lost their entire buffer.
@rpc("any_peer", "call_local", "reliable")
func _exfil_request() -> void:
	if not multiplayer.is_server() or run_over or exfil_calling or not backdoor_rooted:
		return
	var body: Node3D = _requesting_body()
	if body == null:
		return
	# The host already resolves the uplink out of its own seeded layer 25 lines
	# below, for `_fire_exfil`. Same lookup, same node, one frame earlier.
	var pad: Vector3 = _uplink_position()
	if not (pad.distance_to(body.global_position)
			<= Balance.EXFIL_PAD_RADIUS + UPLINK_CALL_SLACK):
		push_warning("[Run] exfil refused: peer %d is not at the uplink" % _sender())
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
			banked[peer] = buffered_value_of(peer)
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
	# The only build guard on the wire protocol. It harms nobody but the sender,
	# but a live dev entry point in a shipped build is still a live dev entry
	# point. Automated runs are exempt so `--decompile-at` keeps working in an
	# exported capture, which is the one release-build caller there is.
	if not OS.is_debug_build() and not Debug.automated:
		push_warning("[Run] debug decompile refused: release build")
		return
	var sender: int = _sender()
	var player: Node = Net.get_player(sender)
	var from: Vector3 = Vector3.ZERO
	if player != null and is_instance_valid(player):
		from = (player as Node3D).global_position + Vector3.FORWARD * 2.0
	damage_player(sender, Balance.INTEGRITY_MAX * 2.0, from)


# ------------------------------------------------ validating client requests --
#
# One preamble, applied to every `any_peer` handler in this file. The M4.8 audit
# found the validation was per-author rather than per-project — `_siphon_request`
# asked all three questions, `_breaker_request` asked two, `_root_request` and
# `_exfil_request` asked none — and every handler that skipped a question turned
# out to be a cheat. The three questions are:
#
#   1. who sent this?                      `_sender()`
#   2. are they actually running?          `is_running(sender)`
#   3. are they standing at the thing?     a distance check against the HOST's
#                                          own copy of the seeded node
#
# Two writing conventions go with it, both learned from the same audit:
#
#   * Every vector that arrives off the wire is `is_finite()`-tested before it
#     is used for anything. A NaN is not a large number; it is a value that
#     compares false against everything, which is how it walks through guards.
#   * Every distance guard is spelled `if not (dist <= limit): return`, never
#     `if dist > limit: return`. **[verified 4.7.1]**
#     `Vector3(NAN,NAN,NAN).distance_to(p) > 3.0` evaluates to **false**, so the
#     second spelling fails *open* on exactly the input an attacker controls.
#     The first fails closed on it.

## Host-side proximity limit for the two channels that shipped without one.
## Deliberately generous — the job is to tell "stood at the machine" from "sent
## a packet from across the layer", not to punish standing at the edge of the
## probe. The node's own interact probe is 2.6 m across and the player's reach is
## 3.4 m, so this is the geometry plus room to breathe.
const USE_REACH: float = 6.0
## The uplink's console sits on the *edge* of the pad, so the call has to be
## allowed from a pad radius further out than the node's.
const UPLINK_CALL_SLACK: float = 4.0
## How far from a player's own avatar a thrown flare or a fired shot may claim to
## have originated. Same number the breaker has used since M3.
const ORIGIN_REACH: float = 3.0
## Ceiling on a thrown flare's speed, as a multiple of the authored throw. Some
## slack for a client whose own sprint speed is added on top, none for a client
## that would like to put a flare through the far wall of the layer.
const THROW_SPEED_LIMIT: float = 1.6


func _sender() -> int:
	var sender: int = multiplayer.get_remote_sender_id()
	return 1 if sender == 0 else sender


## True when the packet we are handling came from the host — either over the
## wire from peer 1, or from a `call_local` on the host itself (sender 0).
func _from_host() -> bool:
	var sender: int = multiplayer.get_remote_sender_id()
	return sender == 0 or sender == 1


## The avatar of the peer whose request we are handling, or null if there is no
## reason to honour it at all: not the host, run finished, sender not running,
## no spawned avatar, or an avatar whose replicated position is not a number.
## Callers still do their own proximity check — this is questions 1 and 2.
func _requesting_body() -> Node3D:
	if not multiplayer.is_server() or run_over:
		return null
	if not is_running(_sender()):
		return null
	var player: Node = Net.get_player(_sender())
	if player == null or not is_instance_valid(player):
		return null
	var body: Node3D = player as Node3D
	# `sync_position` is client-authoritative by design (DESIGN.md), so this is
	# the boundary where a client-owned number becomes a host-side decision.
	if body == null or not body.global_position.is_finite():
		return null
	return body


## The host's own copy of the layer's maintenance node. The `backdoor_nodes`
## group has existed since M3 with no consumers at all; this is the lookup the
## root validation always needed.
func _find_backdoor_node() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group("backdoor_nodes"):
		var target: Node3D = node as Node3D
		if target != null and is_instance_valid(target):
			return target
	return null


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
func _push_buffers(values: Dictionary, worth: Dictionary, stock: Dictionary) -> void:
	buffered = values
	buffered_value = worth
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
		buffered_value[peer_id] = buffered_value_of(peer_id) + maxi(worth, 1)
	shard_taken.emit(index, peer_id, worth)
	buffers_changed.emit()


@rpc("authority", "call_local", "reliable")
func _apply_bundle(bundle_id: int, peer_id: int, amount: int, worth: int) -> void:
	buffered[peer_id] = buffered_of(peer_id) + amount
	buffered_value[peer_id] = buffered_value_of(peer_id) + worth
	# Every other buffer mutation in this file marks the replication flag —
	# `take_shard`, `spend_buffer`, `_delete`. This one did not, so any divergence
	# it caused persisted until an unrelated event happened to dirty the buffers.
	_dirty_buffers = true
	bundle_taken.emit(bundle_id, peer_id)
	buffers_changed.emit()
	if peer_id == Net.local_id():
		notice.emit("BUNDLE RECOVERED  ·  +%d DATA" % worth)


@rpc("authority", "call_local", "reliable")
func _spawn_bundle(bundle_id: int, where: Vector3, amount: int, value: int) -> void:
	var root: Node = _dynamic_root()
	if root == null:
		return
	root.add_child(DataBundle.create(bundle_id, where, amount, value))


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
func _restored(peer_id: int, by_peer: int, value: float) -> void:
	corrupted.erase(peer_id)
	integrity[peer_id] = value
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
	# `authority` already means the engine drops this packet from anybody but the
	# host. The explicit test is here anyway because this is the ONE rpc in the
	# game that writes a file on the machine receiving it, and a receiving peer
	# should be able to say why it trusts the packet without reading annotations.
	if not _from_host():
		return
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
		# The layer the intrusion was injected at, which is 1 only for a surface
		# run: a backdoor start opens at 6, 11 or 16. Nothing reads this yet, so
		# the hardcoded 1 was dead *and* wrong — and the first thing to read it
		# would be a debrief line saying "descended 6 -> 10", which is exactly the
		# claim the wrong value would have quietly falsified.
		"start_layer": start_layer,
		"siphons": siphons_drained,
		"seconds": float(Time.get_ticks_msec() - _run_started_msec) / 1000.0,
	}
