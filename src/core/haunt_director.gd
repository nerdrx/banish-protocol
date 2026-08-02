extends Node
## HauntDirector (autoload `Haunt`) — MOTHER as the horror director. M6's brain.
##
## The canonical two-brain setup (Alien: Isolation) with L4D pacing: MOTHER always
## knows where the crew is (they run inside her), her processes only know what she
## tells them, and she spends a pacing budget on quiet dread, spikes and mercy.
## She tracks crew STRESS and decides when a hunter leaks into the layer, presses,
## or withholds. When the crew is broken and limping she WITHHOLDS — a predator
## toying with dying prey — invisible rubber-banding that reads as lore rather than
## as a difficulty slider (DESIGN.md M6, "The Director").
##
## ## Who runs what
##
## The pacing — pressure, spawns, recompile timers, the withhold decision, the
## bark budget — is HOST-ONLY, exactly like every other simulation decision in the
## game; a client's copy of this autoload only drives the local presentation
## (music stress and the muzzle-flash light the Moth reads). Hunters themselves
## ride the ordinary antivirus replication (existence directed like the M4.8
## trickle, pose/state streamed, death as `sync_dead`), so nothing here needs a
## replication rig of its own beyond one small `_speak` RPC that carries a rendered
## bark to the crew.
##
## ## Stress and music
##
## `Music.set_stress` was wired dormant in M5 behind a local proxy. The Director
## seizes it: whenever a hunter is on the layer, every peer drives the score from
## the perceived stress here; when none is, the wheel is handed back to the proxy
## (`set_stress(-1)`), which is the correct fallback for the no-hunter case and for
## a client whose host has not (yet) told it anything. The withhold reads through
## the music too — a broken crew hears the terror ease, which is the mercy.

signal mother_spoke(text: String, category: String, tier: int, callsign: bool)

var _barks: MotherBarks = null

## Per-layer wiring, set by `begin` on every peer.
var graph: LayerGraph = null
var _director: AntivirusDirector = null
var _layer: int = 0
var _live: bool = false

## Host pacing state.
var _pressure: float = 0.0
var _first_delay: float = 0.0
var _spawn_serial: int = 0
## kind -> true while a hunter of that class is on the layer.
var _active: Dictionary = {}
## kind -> seconds until the Director recompiles the process.
var _recompile: Dictionary = {}
## Temporary silence bought by a kill: pressure does not accrue while it runs.
var _silence: float = 0.0
## A deleted Auditor ends the audit for the ring — it never comes back this layer.
var _auditor_deleted: bool = false
## Where the loudest recent noise was, for vectoring a fresh Hound.
var _last_noise: Vector3 = Vector3.ZERO
var _has_noise: bool = false

## Whether the Director is currently easing off. Read by the Hound host-side so a
## broken crew is toyed with rather than finished (`Hound._think`).
var withholding: bool = false

## Stress, combat recency (seconds since the last hit/kill), and the tick clock.
var _stress: float = 0.0
var _combat_recency: float = 99.0
var _tick: float = 0.0
## Throttled music-stress target + whether any hunter is present, both refreshed
## by one hunter-group scan on `_stress_scan_clock` (never per frame). The audio
## then ramps toward the cached target every frame.
var _stress_target: float = 0.0
var _present: bool = false
var _stress_scan_clock: float = 0.0
const STRESS_SCAN_INTERVAL: float = 0.12

## Bark budget (DESIGN.md: she addresses players "rarely").
var _last_bark: float = -99.0
var _last_address: float = -99.0
var _address_layer: int = 0
var _address_run: int = 0
var _bark_cadence: float = 0.0

## Muzzle-flash pulses (peer -> seconds remaining), tracked on every peer so a
## client's Moth sees the same light its shooter made. The value the Moth reads is
## a 0..1 fade.
var _muzzle: Dictionary = {}


func _ready() -> void:
	# Seed the library deterministically under an automated run so a capture says
	# the same thing twice; otherwise she babbles off wall time.
	_barks = MotherBarks.new(20260801 if Debug.automated else -1)
	Run.layer_changed.connect(_on_layer_changed)
	Run.run_ended.connect(_on_run_ended)
	Run.damaged.connect(_on_damaged)
	Run.process_deleted.connect(_on_process_deleted)
	Run.exfil_changed.connect(_on_exfil_changed)
	Run.backdoor_rooted_changed.connect(_on_backdoor_changed)
	Run.breaker_fired.connect(_on_breaker_fired)
	NoiseBus.heard.connect(_on_noise)
	set_process(true)


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


# ------------------------------------------------------------------- layer --

## Called by `Layer._rebuild` on every peer once the geometry and the antivirus
## director are standing. Stores the wiring and resets the per-layer state; on the
## host, arms the pacing (and honours the `--haunt` dev override).
func begin(layout: LayerGraph, layer_number: int, director: AntivirusDirector) -> void:
	graph = layout
	_director = director
	_layer = layer_number
	_live = graph != null
	_active.clear()
	_recompile.clear()
	_pressure = 0.0
	_silence = 0.0
	_auditor_deleted = false
	_has_noise = false
	withholding = false
	_first_delay = Balance.HAUNT_FIRST_DELAY
	_address_layer = 0

	if not _is_host() or not _live or Debug.no_antivirus:
		return
	# Dev override: force a hunter (or all) standing immediately, past the depth and
	# pacing gates, so a capture reliably gets one. Deferred a beat so the layer's
	# spawner and containers are fully up first.
	if not Debug.haunt_force.is_empty():
		_force_haunt.call_deferred(Debug.haunt_force)


func _on_layer_changed(number: int) -> void:
	_layer = number
	# The per-layer address budget resets on descent; the per-run one does not.
	_address_layer = 0


func _on_run_ended(_summary: Dictionary) -> void:
	_live = false
	_active.clear()
	_recompile.clear()
	withholding = false
	_address_run = 0
	Music.set_stress(-1.0)


# ------------------------------------------------------------------ process --

func _process(delta: float) -> void:
	# Muzzle pulses fade on every peer (the Moth's light input).
	if not _muzzle.is_empty():
		for peer: int in _muzzle.keys():
			_muzzle[peer] = float(_muzzle[peer]) - delta
			if float(_muzzle[peer]) <= 0.0:
				_muzzle.erase(peer)

	_combat_recency = minf(_combat_recency + delta, 99.0)

	# Music: whenever a hunter is on the layer (this peer can see them in the
	# group), drive the score from perceived stress; otherwise hand the wheel back
	# to M5's proxy. Runs on every peer — stress is a local perception. The TARGET
	# (a hunter-group scan + the pool/proximity math) is a slow mood, so it is
	# refreshed on a throttled clock and cached; only the audio ramp runs per frame.
	_stress_scan_clock -= delta
	if _stress_scan_clock <= 0.0:
		_stress_scan_clock = STRESS_SCAN_INTERVAL
		_stress_target = _perceived_stress()  # one group scan; also sets `_present`
	_stress = lerpf(_stress, _stress_target, 1.0 - exp(-3.0 * delta))
	if Debug.stress_force >= 0.0:
		_stress = Debug.stress_force
	if _present:
		Music.set_stress(_stress)
	else:
		Music.set_stress(-1.0)

	if not _is_host() or not _live or Run.run_over or Run.descending:
		return

	_first_delay = maxf(_first_delay - delta, 0.0)
	_silence = maxf(_silence - delta, 0.0)
	_tick += delta
	if _tick < Balance.HAUNT_TICK:
		return
	var step: float = _tick
	_tick = 0.0
	_host_tick(step)


## The host's pacing pass, HAUNT_TICK apart.
func _host_tick(step: float) -> void:
	withholding = _crew_broken()

	# Recompile timers run regardless of withhold — the process is coming back, the
	# only question is when the Director lets it in.
	for kind: StringName in _recompile.keys():
		_recompile[kind] = float(_recompile[kind]) - step
	_tick_recompiles()

	# Pressure accrues with time and with noise debt, unless we are withholding, in
	# silence just after a kill, or still inside the arrival grace.
	if not withholding and _silence <= 0.0 and _first_delay <= 0.0:
		_pressure += Balance.HAUNT_PRESSURE_PER_SEC * step
		_pressure += NoiseBus.debt * Balance.HAUNT_PRESSURE_PER_NOISE * step * 0.1
		if _pressure >= Balance.HAUNT_PRESSURE_THRESHOLD:
			_try_spawn()

	_tick_barks(step)


# -------------------------------------------------------------------- spawns --

## Which hunter classes the depth permits (DESIGN.md escalation).
func _allowed() -> Array:
	if _layer < Balance.HUNT_START_LAYER:
		return []
	var pool: Array = [&"hound", &"moth"]
	if _layer >= Balance.HUNT_AUDITOR_LAYER and not _auditor_deleted:
		pool.append(&"auditor")
	return pool


func _max_simultaneous() -> int:
	return 2 if _layer >= Balance.HUNT_DOUBLE_LAYER else 1


## Try to leak one hunter in. Honours the depth gate, the simultaneity cap and the
## pairing rule (a second hunter is always Hound + one other — never Moth+Auditor).
func _try_spawn() -> void:
	# Whatever the outcome, an attempt resets the pressure so the next hunter is
	# paced rather than instant (a successful `_spawn` resets it again to the same
	# value — harmless — and also covers the recompile-path caller).
	_pressure = Balance.HAUNT_PRESSURE_THRESHOLD * Balance.HAUNT_PRESSURE_AFTER_SPAWN
	if _active.size() >= _max_simultaneous():
		return
	var kind: StringName = _pick_spawn()
	if kind == &"":
		return
	_spawn(kind)


func _pick_spawn() -> StringName:
	var allowed: Array = _allowed()
	var free: Array = []
	for kind: StringName in allowed:
		if not _active.has(kind):
			free.append(kind)
	if free.is_empty():
		return &""

	# Pairing: if one is already out, the pair must include the Hound. When a Hound
	# is the one out, `free` already excludes it (it is active), so only the
	# not-a-Hound case needs forcing.
	if _active.size() == 1 and not _active.has(&"hound"):
		free = [&"hound"] if allowed.has(&"hound") else []
	if free.is_empty():
		return &""

	# Context picks the class. A loud crew draws the Hound; a deep quiet layer with
	# no audit running yet gets the Auditor; otherwise the Moth arrives.
	if free.has(&"hound") and NoiseBus.debt >= Balance.HOUND_NOISE_HOLD:
		return &"hound"
	if free.has(&"auditor") and _layer >= Balance.HUNT_AUDITOR_LAYER:
		return &"auditor"
	if free.has(&"moth"):
		return &"moth"
	return free[0]


## Build a hunter at a seeded nest and announce it. Host-side; the build itself
## replicates through the AntivirusDirector (reliable, call_local — every peer
## constructs the same creature at the same seeded anchor).
func _spawn(kind: StringName) -> void:
	if _director == null or not is_instance_valid(_director):
		return
	_spawn_serial += 1
	var nest: int = _pick_nest()
	var node: Hunter = _director.spawn_hunter(kind, nest, _spawn_serial)
	_active[kind] = true
	_recompile.erase(kind)
	_pressure = Balance.HAUNT_PRESSURE_THRESHOLD * Balance.HAUNT_PRESSURE_AFTER_SPAWN
	# The leitmotif stinger (M5 wired these dormant; the Director activates them).
	Music.play_hunter(kind)
	# A fresh Hound beelines for the loudest recent noise if there was one.
	if kind == &"hound" and node != null and is_instance_valid(node) and _has_noise:
		node.alert(_last_noise, 3, Balance.HOUND_NOISE_HOLD)
	# She narrates the escalation (hunt category); a recompiled Hound gets the
	# specific "it remembers being ended" line by trigger where the corpus has it.
	_bark("hunt")
	if Debug.log_ai:
		print("[Haunt] spawned %s (serial %d) at nest %d on layer %d" % [
			kind, _spawn_serial, nest, _layer])


## Which seeded entry anchor a hunter comes in from — the one furthest from the
## crew, so a spawn is a thing that arrives rather than a thing that appears on
## top of you.
func _pick_nest() -> int:
	if graph == null or graph.hunter_nests.is_empty():
		return 0
	var crew_centre: Vector3 = _crew_centroid()
	var best: int = 0
	var best_d: float = -1.0
	for i: int in graph.hunter_nests.size():
		var d: float = graph.hunter_nests[i].distance_to(crew_centre)
		if d > best_d:
			best_d = d
			best = i
	return best


func _tick_recompiles() -> void:
	for kind: StringName in _recompile.keys():
		if float(_recompile[kind]) > 0.0:
			continue
		_recompile.erase(kind)
		# It only comes back if the depth still allows it and there is room — a Hound
		# recompiled onto a layer that already has its pair waits its turn.
		if _allowed().has(kind) and _active.size() < _max_simultaneous() and not _active.has(kind):
			_spawn(kind)


# --- hunter lifecycle callbacks (host, from Hunter) -------------------------

## A hunter was finished. Start the recompile the kill bought (DESIGN.md: "killing
## buys time, never peace"), buy the layer a little silence, and let MOTHER file
## the deletion. A deleted Auditor is the exception: the audit ends for the ring.
func on_hunter_killed(kind: StringName, recompile_time: float) -> void:
	if not _is_host():
		return
	_active.erase(kind)
	Music.stop_hunter(kind)
	if kind == &"auditor":
		_auditor_deleted = true
		_bark("mercy")
	elif recompile_time > 0.0:
		_recompile[kind] = recompile_time
		# Killing the Hound buys the layer real silence; the others do not.
		if kind == &"hound":
			_silence = maxf(_silence, Balance.HOUND_SILENCE_TIME)
	_bark("kill_ack")
	if Debug.log_ai:
		print("[Haunt] %s finished; recompile in %.0fs" % [
			kind, float(_recompile.get(kind, 0.0))])


## A hunter took itself off the board without being killed (the Hound slinking
## away once it has escaped into the dark). No reward was earned, so a shorter and
## quieter recompile than a kill would have bought.
func on_hunter_slunk(kind: StringName) -> void:
	if not _is_host():
		return
	_active.erase(kind)
	Music.stop_hunter(kind)
	if kind == &"hound":
		_recompile[kind] = Balance.HOUND_SLINK_RECOMPILE_TIME
	if Debug.log_ai:
		print("[Haunt] %s slunk off; recompile in %.0fs" % [
			kind, float(_recompile.get(kind, 0.0))])


# -------------------------------------------------------------------- stress --

## Perceived stress in [0,1], computable on any peer from the local player and the
## replicated creatures. Proximity and combat lead; a low pool and a crowded room
## push it into terror; a hunter merely existing is a floor of dread.
## Also refreshes `_present` (a hunter exists) off the SAME group scan, so the
## throttled caller needs only this one walk of the group, not three.
func _perceived_stress() -> float:
	var group: Array = get_tree().get_nodes_in_group(Hunter.HUNTER_GROUP)
	_present = not group.is_empty()
	var body: Node3D = _local_body()
	if body == null:
		return 0.0

	var nearest: float = 1e9
	var crowd: int = 0
	for node: Node in group:
		var hunter: Hunter = node as Hunter
		if hunter == null or not is_instance_valid(hunter):
			continue
		var d: float = hunter.global_position.distance_to(body.global_position)
		nearest = minf(nearest, d)
		if d < Balance.HAUNT_PROX_FAR:
			crowd += 1

	var prox: float = 0.0
	if nearest < 1e9:
		prox = clampf(inverse_lerp(Balance.HAUNT_PROX_FAR, Balance.HAUNT_PROX_NEAR, nearest),
				0.0, 1.0)
	var crowded: float = clampf(float(crowd) / 2.0, 0.0, 1.0)
	var combat: float = clampf(1.0 - _combat_recency / Balance.HAUNT_COMBAT_DECAY, 0.0, 1.0)
	var starving: float = 0.0
	if Run.configured and Run.fraction() < Balance.CYCLES_WARNING_FRACTION:
		starving = inverse_lerp(Balance.CYCLES_WARNING_FRACTION, 0.0, Run.fraction())
	var floor_dread: float = Balance.HAUNT_STRESS_HUNT_FLOOR if _present else 0.0

	# When the Director is easing off, the terror eases with it — the mercy is
	# audible. Kept as a ceiling rather than a subtraction so dread never vanishes.
	var raw: float = Balance.HAUNT_STRESS_PROX * prox \
			+ Balance.HAUNT_STRESS_COMBAT * combat \
			+ Balance.HAUNT_STRESS_CROWD * crowded \
			+ Balance.HAUNT_STRESS_STARVING * starving \
			+ floor_dread
	if withholding:
		raw = minf(raw, 0.5)
	return clampf(raw, 0.0, 1.0)


## The crew is broken when the pool is nearly dry, average integrity is low, or
## anyone is down. While broken the Director withholds.
func _crew_broken() -> bool:
	if not Run.corrupted_crew().is_empty():
		return true
	if Run.configured and Run.fraction() < Balance.HAUNT_BROKEN_CYCLES:
		return true
	var sum: float = 0.0
	var n: int = 0
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not Run.is_running(peer):
			continue
		var cap: float = Run.integrity_max_of(peer)
		if cap > 0.0:
			sum += Run.integrity_of(peer) / cap
			n += 1
	if n > 0 and sum / float(n) < Balance.HAUNT_BROKEN_INTEGRITY:
		return true
	return false


# ---------------------------------------------------------------- muzzle/moth --

## The Moth reads this: how bright the muzzle flash of `peer`'s recent breaker
## fire still is, 0..1, fading over MOTH_MUZZLE_PULSE. A shot is a light even in
## the dark, which is what makes fighting a Moth feed it.
func muzzle_light(peer: int) -> float:
	if not _muzzle.has(peer):
		return 0.0
	return clampf(float(_muzzle[peer]) / Balance.MOTH_MUZZLE_PULSE, 0.0, 1.0)


func _on_breaker_fired(peer: int, _origin: Vector3) -> void:
	_muzzle[peer] = Balance.MOTH_MUZZLE_PULSE


func _on_noise(where: Vector3, _rooms: int, _source: String, _seconds: float) -> void:
	# Remember the loudest recent thing for vectoring a fresh Hound. The debt tally
	# itself lives on NoiseBus; this only keeps the position.
	_last_noise = where
	_has_noise = true


# -------------------------------------------------------------------- barks --

## MOTHER speaks, if the budget allows. `category` selects the register; `target`
## is the crewmate an address line names (rendered with THEIR callsign, so the
## whole crew watches her call one of them out). Host-only; the rendered line is
## RPC'd to everyone.
func _bark(category: String, target: int = -1) -> void:
	if not _is_host() or _barks == null or not _barks.is_loaded():
		return
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - _last_bark < Balance.BARK_MIN_GAP:
		return

	var is_address: bool = category == "address"
	if is_address:
		# The rarest category, hardest budget: at most one per layer, three per run,
		# and a long floor between any two.
		if _address_layer >= Balance.BARK_ADDRESS_PER_LAYER:
			return
		if _address_run >= Balance.BARK_ADDRESS_PER_RUN:
			return
		if now - _last_address < Balance.BARK_ADDRESS_MIN_GAP:
			return

	var callsign: String = ""
	# "GO UP" is once per player, EVER (DESIGN.md's rarest budget). Once she has
	# said it, keep it out of the address pool for good.
	var exclude: Array = []
	if is_address:
		if target < 0:
			target = _address_target()
		if target < 0:
			return
		callsign = Net.crew_name(target)
		if GameState.mother_said_go_up:
			exclude = ["addr.go_up"]

	var rendered: Dictionary = _barks.pick(category, _layer, callsign, exclude)
	if rendered.is_empty():
		return

	_last_bark = now
	if is_address:
		_last_address = now
		_address_layer += 1
		_address_run += 1
		# She only ever tells you to leave once. Burn the flag the moment she does.
		if String(rendered.get("id", "")) == "addr.go_up":
			GameState.mark_go_up_said()
	_speak.rpc(String(rendered["text"]), category, int(rendered["tier"]),
			bool(rendered.get("callsign", false)))
	if Debug.log_ai:
		print("[Haunt] MOTHER (%s t%d): %s" % [category, int(rendered["tier"]),
			String(rendered["text"])])


## A background cadence for the quieter registers, so she is present without
## chattering: an occasional ambient line, and — very rarely, when a crewmate is
## isolated and stressed — an address.
func _tick_barks(step: float) -> void:
	_bark_cadence -= step
	if _bark_cadence > 0.0:
		return
	_bark_cadence = randf_range(22.0, 40.0)
	# The address is the money moment: only when someone is genuinely under it.
	if _stress > 0.5 and _address_run < Balance.BARK_ADDRESS_PER_RUN:
		var mark: int = _address_target()
		if mark >= 0:
			_bark("address", mark)
			return
	if _hunters_present():
		_bark("hunt")
	else:
		_bark("ambient")


## Who MOTHER addresses: a living crewmate near a hunter, preferring one who is
## alone. Falls back to any running crewmate.
func _address_target() -> int:
	var best: int = -1
	var best_score: float = -1.0
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not Run.is_running(peer):
			continue
		var node: Node = Net.get_player(peer)
		var body: Node3D = node as Node3D
		if body == null or not is_instance_valid(body):
			continue
		var nearest_hunter: float = 1e9
		for hn: Node in get_tree().get_nodes_in_group(Hunter.HUNTER_GROUP):
			var h: Node3D = hn as Node3D
			if h == null or not is_instance_valid(h):
				continue
			nearest_hunter = minf(nearest_hunter, h.global_position.distance_to(body.global_position))
		# Closer to a hunter scores higher; a lone crewmate scores higher still.
		var score: float = 0.0
		if nearest_hunter < 1e9:
			score = clampf(1.0 - nearest_hunter / 30.0, 0.0, 1.0)
		if _is_isolated(body):
			score += 0.4
		if score > best_score:
			best_score = score
			best = peer
	return best


func _is_isolated(body: Node3D) -> bool:
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		var node: Node = Net.get_player(peer)
		var other: Node3D = node as Node3D
		if other == null or other == body or not is_instance_valid(other):
			continue
		if other.global_position.distance_to(body.global_position) < 16.0:
			return false
	return true


func _on_damaged(_from: Vector3) -> void:
	_combat_recency = 0.0


func _on_process_deleted(_by: int, kind: String) -> void:
	_combat_recency = 0.0
	# A Scrubber or Sentinel kill is acknowledged too, but the hunter kills route
	# their kill_ack through `on_hunter_killed` with the recompile timer attached,
	# so only the ordinary processes are handled here.
	if kind != "Hound" and kind != "Moth" and kind != "Auditor" and _is_host():
		if randf() < 0.25:
			_bark("kill_ack")


func _on_exfil_changed() -> void:
	if Run.exfil_calling:
		_bark("exfil")


func _on_backdoor_changed() -> void:
	if Run.backdoor_rooted:
		_bark("sanctuary")


## Replicated bark. Runs on every peer, including the host (call_local), so the
## HUD's MOTHER surface renders the same line everywhere at once.
@rpc("authority", "call_local", "reliable")
func _speak(text: String, category: String, tier: int, callsign: bool) -> void:
	mother_spoke.emit(text, category, tier, callsign)


# ------------------------------------------------------------------ helpers --

func _hunters_present() -> bool:
	return not get_tree().get_nodes_in_group(Hunter.HUNTER_GROUP).is_empty()


func _local_body() -> Node3D:
	var node: Node = Net.get_player(Net.local_id())
	return node as Node3D if node is Node3D and is_instance_valid(node) else null


func _crew_centroid() -> Vector3:
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for id: int in Net.crew.keys():
		var peer: int = int(id)
		if not Run.is_running(peer):
			continue
		var node: Node = Net.get_player(peer)
		var body: Node3D = node as Node3D
		if body != null and is_instance_valid(body):
			sum += body.global_position
			n += 1
	return sum / float(n) if n > 0 else Vector3.ZERO


# --------------------------------------------------------------- dev override --

## `--haunt <hound|moth|auditor|all>`: force the named hunter(s) standing now, past
## the depth and pacing gates, for a capture or a behaviour test. Host-only.
func _force_haunt(which: String) -> void:
	if not _is_host() or _director == null or not is_instance_valid(_director):
		return
	var kinds: Array = []
	match which.strip_edges().to_lower():
		"hound": kinds = [&"hound"]
		"moth": kinds = [&"moth"]
		"auditor": kinds = [&"auditor"]
		"all": kinds = [&"hound", &"moth", &"auditor"]
		_: return
	var nest: int = 0
	for kind: StringName in kinds:
		if _active.has(kind):
			continue
		_spawn_serial += 1
		var node: Hunter = _director.spawn_hunter(kind, nest, _spawn_serial)
		_active[kind] = true
		Music.play_hunter(kind)
		if node != null and is_instance_valid(node) and kind == &"hound" and _has_noise:
			node.alert(_last_noise, 3, Balance.HOUND_NOISE_HOLD)
		nest = (nest + 1) % maxi(graph.hunter_nests.size(), 1) if graph != null else 0
	print("[Haunt] --haunt %s: forced %s on layer %d" % [which, str(kinds), _layer])
