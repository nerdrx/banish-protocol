extends Node
## Run — the intrusion itself: which layer, how many Cycles are left, who is
## still running, and when the crew rides the shaft down.
##
## Authority (DESIGN.md "Multiplayer Architecture"): the host simulates, clients
## observe. Every number here is written on the host and pushed out; a client's
## copy is display state. Clients only ever *request* (siphon, descend) and the
## host decides.
##
## Traffic budget: the pool is a smooth ramp, so it goes out unreliably at 5 Hz
## and clients interpolate between packets. Integrity and layer changes are rare
## and consequential, so they go reliably on change.
##
## GameState holds who you are across scenes; Run holds what is happening to you
## inside one intrusion. Leaving a session resets Run and leaves GameState alone.

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
## alive so a joining crewmate is never billed as a casualty.
var integrity: Dictionary = {}

## Tap indices already drained on the current layer. Cleared on descent.
var spent_siphons: Dictionary = {}

var muster_inside: int = 0
var muster_total: int = 0
var descending: bool = false
var run_over: bool = false

## Deepest layer the crew stood in this run, for the summary overlay.
var deepest_layer: int = 1
var siphons_drained: int = 0
var _run_started_msec: int = 0

var _pool_clock: float = 0.0
var _integrity_clock: float = 0.0
var _muster_clock: float = 0.0
var _dirty_integrity: bool = false
var _log_clock: float = 0.0
## Client-side smoothing target, so a 5 Hz pool stream reads as a continuous ramp.
var _display_cycles: float = 0.0


func _ready() -> void:
	set_process(true)


# ----------------------------------------------------------------- lifecycle --

## Host: start a fresh intrusion. Called from Net.host() once the seed is rolled.
func begin(layer: int, test_layer: bool) -> void:
	layer_number = maxi(layer, 1)
	deepest_layer = layer_number
	use_test_layer = test_layer
	spent_siphons.clear()
	integrity.clear()
	descending = false
	run_over = false
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
		if not integrity.has(int(id)):
			integrity[int(id)] = Balance.INTEGRITY_MAX

	var updated: float = Balance.pool_max(maxi(Net.crew.size(), 1))
	if updated > cycles_max:
		cycles += updated - cycles_max
	cycles_max = updated
	cycles = clampf(cycles, 0.0, cycles_max)
	_dirty_integrity = true
	cycles_changed.emit(cycles)
	integrity_changed.emit()


## Host: a crew member dropped. Their share leaves with them, but never below
## what the remaining crew is currently holding — a disconnect must not be a
## punishment for the people still running.
func on_crew_left(peer_id: int) -> void:
	integrity.erase(peer_id)
	if not configured:
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	cycles_max = Balance.pool_max(maxi(Net.crew.size(), 1))
	cycles = clampf(cycles, 0.0, cycles_max)
	_dirty_integrity = true
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
	spent_siphons.clear()
	muster_inside = 0
	muster_total = 0
	deepest_layer = 1
	siphons_drained = 0


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


func is_alive(peer_id: int) -> bool:
	return integrity_of(peer_id) > 0.0


func local_integrity() -> float:
	return integrity_of(Net.local_id())


func local_alive() -> bool:
	return is_alive(Net.local_id())


func crew_mustered() -> bool:
	return muster_total > 0 and muster_inside >= muster_total


func is_siphon_spent(index: int) -> bool:
	return spent_siphons.has(index)


## Movement penalty for the local avatar. Player multiplies its top speed by this.
func speed_multiplier() -> float:
	return Balance.STARVED_SPEED_MULT if starved() else 1.0


## 0..1 "how badly is this process failing", driving the post-process glitch and
## the vignette closing in. Starvation opens it; losing integrity deepens it.
func degradation() -> float:
	if not configured:
		return 0.0
	if not local_alive():
		# Decompiled: a steady ghost-signal wash. Full glitch here would be
		# thematically right and unwatchable — spectating is minutes long.
		return 0.25
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

	if not configured or run_over:
		return
	if not multiplayer.has_multiplayer_peer():
		return
	if not multiplayer.is_server():
		return

	_drain(delta)
	_degrade(delta)

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

	_integrity_clock -= delta
	if _dirty_integrity and _integrity_clock <= 0.0:
		_integrity_clock = Balance.INTEGRITY_SYNC_INTERVAL
		_dirty_integrity = false
		_push_integrity.rpc(integrity)


## Passive drain per living player, plus a sprint surcharge. Sprint is inferred
## from the pose stream the players already replicate — billing does not need its
## own input bit, and a client cannot under-report by withholding one.
func _drain(delta: float) -> void:
	if descending:
		return  # the layer is being rewritten; nobody is running.

	var drain: float = 0.0
	for id: int in Net.crew.keys():
		if not is_alive(int(id)):
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
## Hitting zero is decompilation — a one-way door until M3's restore channel.
func _degrade(delta: float) -> void:
	var empty: bool = starved()

	for id: int in Net.crew.keys():
		var peer: int = int(id)
		var value: float = integrity_of(peer)
		if value <= 0.0:
			continue  # already decompiled.

		if empty:
			value = maxf(value - Balance.STARVED_INTEGRITY_DRAIN * delta, 0.0)
		elif value < Balance.INTEGRITY_MAX:
			value = minf(value + Balance.INTEGRITY_REGEN * delta, Balance.INTEGRITY_MAX)
		else:
			continue  # untouched and full: nothing to write or replicate.

		integrity[peer] = value
		_dirty_integrity = true
		if value <= 0.0:
			_decompile.rpc(peer)

	if not Net.crew.is_empty():
		_check_wipe()


## `--log-cycles`. One line per second with everything needed to verify a drain
## rate against Balance by hand.
func _log_telemetry() -> void:
	var speeds: PackedStringArray = PackedStringArray()
	for id: int in Net.crew.keys():
		var player: Node = Net.get_player(int(id))
		var speed: float = 0.0 if player == null else float(player.get("sync_speed"))
		speeds.append("%d:%.1fm/s%s" % [int(id), speed,
			"*" if speed >= Balance.SPRINT_BILLING_SPEED else ""])
	print("[Run] layer=%d pool=%.1f/%.0f crew=[%s] integrity=%s" % [
		layer_number, cycles, cycles_max, ", ".join(speeds), str(integrity)])


func _check_wipe() -> void:
	for id: int in Net.crew.keys():
		if is_alive(int(id)):
			return
	if run_over:
		return
	run_over = true
	_end_run.rpc({
		"layers": deepest_layer,
		"start_layer": 1,
		"siphons": siphons_drained,
		"seconds": float(Time.get_ticks_msec() - _run_started_msec) / 1000.0,
		"reason": "CREW DECOMPILED",
	})


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
		if not is_alive(int(id)):
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


@rpc("any_peer", "call_local", "reliable")
func _siphon_request(index: int) -> void:
	if not multiplayer.is_server() or run_over or descending:
		return
	if spent_siphons.has(index):
		return

	# Proximity check: the channel ran on the requesting client, so this is the
	# one place that can tell "stood at the tap for 2.5 s" from "sent a packet".
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
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
	_update_muster()
	if not crew_mustered():
		push_warning("[Run] descent refused: crew not mustered (%d/%d)" % [
			muster_inside, muster_total])
		return
	_begin_descent.rpc(layer_number + 1)


## Dev only (`--decompile-at`). M2 has no damage sources — integrity only falls
## to starvation, which kills the whole crew at once — so without this there is
## no way to reach the one-player-down state the spectator cam exists for.
## M3 replaces the caller with antivirus damage, not this path.
func request_debug_decompile() -> void:
	if multiplayer.has_multiplayer_peer():
		_debug_decompile.rpc_id(1)


@rpc("any_peer", "call_local", "reliable")
func _debug_decompile() -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	integrity[sender] = 0.0
	_dirty_integrity = true
	_decompile.rpc(sender)
	_check_wipe()


func _find_tap(index: int) -> Node:
	for node: Node in get_tree().get_nodes_in_group("siphon_taps"):
		var tap: SiphonTap = node as SiphonTap
		if tap != null and tap.tap_index == index:
			return tap
	return null


# ---------------------------------------------------------------------- rpcs --

@rpc("authority", "call_remote", "unreliable_ordered")
func _push_pool(value: float, maximum: float) -> void:
	cycles = value
	cycles_max = maximum
	cycles_changed.emit(cycles)


@rpc("authority", "call_remote", "reliable")
func _push_integrity(values: Dictionary) -> void:
	integrity = values
	integrity_changed.emit()


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
func _starvation_notice(message: String) -> void:
	notice.emit(message)


@rpc("authority", "call_local", "reliable")
func _decompile(peer_id: int) -> void:
	integrity[peer_id] = 0.0
	integrity_changed.emit()
	decompiled.emit(peer_id)
	notice.emit("%s DECOMPILED" % Net.crew_name(peer_id))


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
	muster_inside = 0
	muster_total = 0
	layer_changed.emit(next_layer)
	descent_finished.emit()
	notice.emit("LAYER %02d" % next_layer)


@rpc("authority", "call_local", "reliable")
func _end_run(summary: Dictionary) -> void:
	run_over = true
	run_ended.emit(summary)
