extends Node
## Patches (autoload `Patches`) — M9's run-scoped hot-patches: what this
## *instance* of your program has had injected into it, where those injections
## came from, and what they do to everything else.
##
## ## The fiction is the architecture, again
##
## `Modules` are compiled into your SOURCE and survive everything; `Subs` are
## bought at a Compiler and carried between runs. A PATCH is neither. It is a
## hot-patch written into the process that is currently executing — it lives in
## the instance's memory, not in your codebase — so it dies with the instance.
## Wipe and it is gone. Exfiltrate and it is *also* gone, because the process you
## exfiltrate is the process you stop running; what you keep is the small data
## bonus you get for selling the patch back on the way out (`exfil_bonus`).
##
## That is deliberately the opposite shape from every other progression system in
## the game, and it is why the game needed one. DESIGN.md's meta-progression is
## permanent by design ("losing a run costs the data in your buffers, never your
## build"), which is exactly right for a horror roguelite and exactly wrong for
## the *within-a-run* escalation a Risk-of-Rain-shaped item economy provides.
## Patches are the run's own curve: they stack, they compound, they make the
## eleventh ring feel different from the first, and they are all gone tomorrow.
##
## ## Three laws this file is written under
##
##   **The economy stays the boss.** See `Balance`'s M9 header for the full
##   statement and every cap that enforces it. In this file it shows up as: every
##   Cycles refund goes through `_gc_credit`, which is tallied per layer against
##   a fraction of the crew's pool ceiling; every drain reduction has a floor;
##   nothing here produces light.
##
##   **The killability law.** TAIL CALL and BIT ROT are the BREAKER'S damage —
##   chained and delayed — routed through `Antivirus.take_damage` exactly like a
##   cut that was aimed. No patch makes anything immune, no patch deletes
##   anything the breaker could not have, and there is no `damage` key anywhere
##   in the catalogue for a future author to reach for. `--selftest` asserts it.
##
##   **Host-authoritative, like everything with a consequence.** A client asks to
##   pick something up; the host decides who gets it, re-checking the same three
##   questions `Run` and `Props` ask (who sent this, are they running, are they
##   where they say) with the same `if not (dist <= limit)` spelling that fails
##   CLOSED on a NaN.
##
## ## Determinism, and why nothing here is a secret
##
## Every roll — which patch a slate carries, whether a deleted process leaves
## one, which layers get an anomaly cache — is HASH-DERIVED from the run seed,
## the layer number and the source's own index. It never consumes `Rng.stream()`,
## because DESIGN.md's determinism law says seeded content must not depend on the
## ORDER anything happened in, and a crew that reads two slates in a different
## order must not get different patches.
##
## The consequence is pleasant: every peer can compute what a slate holds before
## anybody touches it, so the wire only ever has to carry *who got it*. There is
## no hidden roll to replicate and no join race about a roll that already
## happened. What the host owns is the grant, which is a decision, not a secret.
##
## ## What crosses the wire
##
## Two packets per pickup at most:
##
##   1. the **request** (client -> host): which kind of vessel, which index.
##   2. the **grant** (host -> everyone): that vessel is spent, this peer took
##      it, here is the whole carried table. Every peer builds the same fx, the
##      same dead slate and the same HUD strip from it.
##
## The table is broadcast WHOLE rather than as a delta, for the same reason
## `Subs._push_kits` does: a peer that joined thirty seconds ago has never seen
## any of it, and one small reliable packet on an event that already costs
## several is cheaper than a join-race protocol.

## The local player's carried patches changed, or anybody's did. The HUD strip
## listens rather than polling.
signal carried_changed
## Somebody picked one up, on every peer. `peer_id` is the grabber.
signal patch_gained(peer_id: int, patch_id: String, stacks: int)
## The host said no, or the local pre-check did. Local only.
signal pickup_refused(reason: String)

## Vessel kinds. Written into the wire packet and used as the hash tag, so they
## are strings rather than an enum — a renumbered enum would silently re-roll
## every slate in every existing seed.
const KIND_SLATE: String = "slate"
const KIND_CACHE: String = "cache"
const KIND_DROP: String = "drop"

## Groups the vessels put themselves in, so the host's proximity check and the
## `--goto` probes can both find one by index.
const GROUP_SLATE: String = "patch_slates"
const GROUP_CACHE: String = "anomaly_caches"

# --- carried state (host-authoritative, run-scoped) ---------------------------
## peer -> {patch_id: stacks}. Cleared at the end of a run and on entering the
## hub, and NEVER written to disk. That is the entire point of the system.
var carried: Dictionary = {}

## "<kind>:<index>" -> peer that took it. Per LAYER — a spent slate must not come
## back when the layer is rebuilt under a joining peer, and a fresh layer has a
## fresh set. Same lifetime and the same reasoning as `Props.opened_cabinets`.
var taken: Dictionary = {}

# --- per-layer host budgets ---------------------------------------------------
## GARBAGE COLLECT: Cycles refunded on this layer so far, against the cap.
var _gc_credit: float = 0.0
## WATCHDOG: peer -> charges spent on this layer.
var _watchdog_spent: Dictionary = {}
## Serial for watchdog-spawned shells. NEGATIVE, so it can never collide with
## `Subs`' own positive barrier ids while both live in the same group.
var _next_shell: int = -1

# --- per-peer host sim state --------------------------------------------------
## HOT LOOP: peer -> {target: int (instance id), hits: int, at: float}.
var _loop: Dictionary = {}
## SPECULATIVE EXECUTION: peer -> engine time of that peer's last breaker shot.
var _last_shot: Dictionary = {}
## RACE CONDITION: peer -> {since: float (seconds sprinting), rest: float}.
var _sprint: Dictionary = {}
## BIT ROT: creature instance id -> {left, per_second, peer, node}.
var _rot: Dictionary = {}
var _rot_clock: float = 0.0

## `--patches ID[:STACKS],…` forces a carried set for a session without any of it
## being earned. Instruments only — see `_parse_forced`.
var _forced: Dictionary = {}
## Which peer id the forced table is currently filed under. See `_on_crew_changed`.
var _forced_filed: int = 0


func _ready() -> void:
	# Same deferral `Subs` uses: this autoload is created near the end of the
	# list, but the roster hook still has to wait for the whole list to stand up.
	_bind.call_deferred()
	_parse_forced()


func _bind() -> void:
	Net.crew_changed.connect(_on_crew_changed)
	Run.run_ended.connect(func(_s: Dictionary) -> void: clear_run())
	Run.layer_changed.connect(func(_n: int) -> void: _reset_layer())
	Run.descent_started.connect(func(_n: int) -> void: _reset_layer())
	set_process(true)


## A run ended, or the crew went home. Everything a patch is dies here — that is
## the design, not a cleanup convenience.
func clear_run() -> void:
	carried.clear()
	_reset_layer()
	_loop.clear()
	_last_shot.clear()
	_sprint.clear()
	if not _forced.is_empty():
		# `--patches` is a session fixture, not a run reward: it survives the run
		# boundary so a capture can descend without re-arming.
		carried[Net.local_id()] = (_forced as Dictionary).duplicate()
	carried_changed.emit()


func _reset_layer() -> void:
	taken.clear()
	_gc_credit = 0.0
	_watchdog_spent.clear()
	_rot.clear()


func _on_crew_changed() -> void:
	# `--patches` is applied in `_ready`, before this machine has a peer id — so on
	# a CLIENT the forced table was filed under the wrong key. Re-file it whenever
	# the roster moves. Instruments only; it costs one dictionary write.
	if not _forced.is_empty() and _forced_filed != Net.local_id():
		_forced_filed = Net.local_id()
		carried[Net.local_id()] = (_forced as Dictionary).duplicate()
		carried_changed.emit()
	# A peer that arrives after a pickup has never seen the table. Re-publishing
	# on every roster change is one small reliable packet, and it is what makes
	# the join race unlosable rather than merely unlikely.
	if _is_host():
		_push_carried.rpc(carried, taken)


func _is_host() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true  # editor / offline: nobody else is authority.
	return multiplayer.is_server()


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# ------------------------------------------------------------------ catalogue --

static func definition(id: String) -> Dictionary:
	return Balance.PATCHES.get(id, {}) as Dictionary


static func is_patch(id: String) -> bool:
	return Balance.PATCHES.has(id)


static func display_name(id: String) -> String:
	return String(definition(id).get("name", id.to_upper()))


static func glyph(id: String) -> String:
	return String(definition(id).get("glyph", "◆"))


static func note(id: String) -> String:
	return String(definition(id).get("note", ""))


static func rarity(id: String) -> int:
	return Balance.patch_tier(id)


## A `{id: stacks}` table from somewhere untrusted, made safe. Same discipline
## and the same hard-won reason as `Modules.sanitize_tiers` and `Subs.sanitize`:
## an out-of-range integer was never the danger, the TYPE was — `int({})` aborts
## the enclosing function, and this table is read on the host inside a damage
## calculation that runs several times a second.
static func sanitize(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in raw.keys():
		if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
			continue
		var id: String = String(key)
		if not is_patch(id):
			continue
		var value: Variant = raw[key]
		if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
			continue
		var count: int = clampi(int(value), 0, Balance.PATCH_MAX_STACKS)
		if count > 0:
			out[id] = count
	return out


# ------------------------------------------------------------------- queries --

## How many of `id` this peer is carrying. The single accessor every effect below
## goes through, so there is exactly one place the table is read and exactly one
## place the stack ceiling is enforced.
func stacks(peer_id: int, id: String) -> int:
	var table: Dictionary = carried.get(peer_id, {}) as Dictionary
	return clampi(int(table.get(id, 0)), 0, Balance.PATCH_MAX_STACKS)


func local_stacks(id: String) -> int:
	return stacks(Net.local_id(), id)


func carried_of(peer_id: int) -> Dictionary:
	return carried.get(peer_id, {}) as Dictionary


func local_carried() -> Dictionary:
	return carried_of(Net.local_id())


## How many distinct patches, and how many stacks in total, a peer is holding.
## The debrief and the HUD both want the pair.
func total_stacks(peer_id: int) -> int:
	var sum: int = 0
	for id: String in Balance.PATCH_TRACKS:
		sum += stacks(peer_id, id)
	return sum


## Carried ids in catalogue order (tier first). The HUD strip and the inspect
## list both draw from this, so a patch never moves in the strip once it is in
## it — a glyph that shuffles as you collect is a glyph nobody learns.
func ordered_ids(peer_id: int) -> Array[String]:
	var out: Array[String] = []
	for id: String in Balance.PATCH_TRACKS:
		if stacks(peer_id, id) > 0:
			out.append(id)
	return out


## Compact one-line rendering, for logs and the self-test.
static func describe(table: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for id: String in Balance.PATCH_TRACKS:
		var count: int = int(table.get(id, 0))
		if count > 0:
			parts.append("%s x%d" % [id, count])
	return "none" if parts.is_empty() else ", ".join(parts)


# ------------------------------------------------------- deterministic rolls --
#
# DESIGN.md's determinism law. Nothing below touches `Rng.stream()`; every roll
# is a fresh generator seeded from a hash of (run seed, layer, tag, index), so it
# is a pure function of WHAT is being rolled rather than of WHEN it was rolled.
# Two peers, four peers and a headless dump all agree, in any order, forever.

## The generator for one roll. Never cached — a cached stream would make the
## second roll depend on the first, which is the exact failure this avoids.
static func _roller(tag: String, layer: int, index: int) -> RandomNumberGenerator:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(str(Rng.run_seed, ":patch:", tag, ":", layer, ":", index))
	return rng


## Which patch a vessel holds. `weights` is one of `Balance.PATCH_WEIGHTS_*`.
##
## Two-stage on purpose: roll the RARITY TIER off the weights, then pick evenly
## inside that tier. Rolling the flat catalogue with per-patch weights would make
## a tier's rarity an emergent property of how many patches happen to be in it,
## so adding a fourteenth STABLE patch would quietly make KERNEL rarer.
static func roll_patch(tag: String, layer: int, index: int, weights: Array[int]) -> String:
	var rng: RandomNumberGenerator = _roller(tag, layer, index)
	var total: int = 0
	for w: int in weights:
		total += maxi(w, 0)
	if total <= 0:
		return ""
	var pick: int = rng.randi_range(0, total - 1)
	var tier: int = Balance.PATCH_TIER_STABLE
	var running: int = 0
	for i: int in weights.size():
		running += maxi(weights[i], 0)
		if pick < running:
			tier = i
			break
	var pool: Array[String] = []
	for id: String in Balance.PATCH_TRACKS:
		if Balance.patch_tier(id) == tier:
			pool.append(id)
	if pool.is_empty():
		return ""
	return pool[rng.randi_range(0, pool.size() - 1)]


## What is on the slate/cache with this index, on this layer, without touching
## it. Every peer computes the same answer, which is why the wire carries no
## secret and a joining peer needs no catch-up packet for one.
func preview(kind: String, index: int, layer: int = -1) -> String:
	var on_layer: int = Run.layer_number if layer < 0 else layer
	if kind == KIND_CACHE:
		return roll_patch(KIND_CACHE, on_layer, index, Balance.PATCH_WEIGHTS_ANOMALY)
	if kind == KIND_DROP:
		return roll_patch(KIND_DROP, on_layer, index, Balance.PATCH_WEIGHTS_DROP)
	return roll_patch(KIND_SLATE, on_layer, index, Balance.PATCH_WEIGHTS_SLATE)


## How many pocket secretaries the generator leaves on `layer`.
static func slate_count(layer: int) -> int:
	var extra: int = maxi(layer - 1, 0) / maxi(Balance.PATCH_SLATES_PER_LAYER, 1)
	return clampi(Balance.PATCH_SLATES_MIN + extra,
			Balance.PATCH_SLATES_MIN, Balance.PATCH_SLATES_MAX)


## Layers between anomaly caches on this run, and the offset of the first one.
## Both derived from the run seed, so "every two or three layers" is a fact about
## the RUN — two crews on two seeds never learn one timetable.
static func anomaly_period() -> int:
	var rng: RandomNumberGenerator = _roller("anomaly_period", 0, 0)
	return rng.randi_range(Balance.PATCH_ANOMALY_PERIOD_MIN,
			Balance.PATCH_ANOMALY_PERIOD_MAX)


static func anomaly_phase() -> int:
	var period: int = maxi(anomaly_period(), 1)
	var rng: RandomNumberGenerator = _roller("anomaly_phase", 0, 0)
	return rng.randi_range(0, period - 1)


## Whether `layer` has the guaranteed anomaly cache on it. Pure, static, and
## callable before a single node exists — which is what lets the self-test walk
## twenty layers of a seed and assert the spacing.
static func layer_has_anomaly(layer: int) -> bool:
	var period: int = maxi(anomaly_period(), 1)
	return posmod(layer - anomaly_phase(), period) == 0


## Whether a deleted process of `kind` at `slot` leaves a slate behind. Hashed
## off the creature's own slot index, so it is decided by WHICH process died
## rather than by how many had died before it — a crew that kills the pack in a
## different order gets the same drops.
static func process_drops(kind: String, slot: int, layer: int) -> bool:
	var chance: float = Balance.PATCH_DROP_CHANCE_LIGHT
	match kind:
		"Sentinel":
			chance = Balance.PATCH_DROP_CHANCE_HEAVY
		"Hound", "Moth", "Auditor":
			chance = Balance.PATCH_DROP_CHANCE_HUNTER
	return _roller("drop_chance", layer, slot).randf() < chance


# ---------------------------------------------------------------- the pickup --

## Called by a vessel's completed channel on the local peer. The local check is
## presentation — it decides whether the HUD ticks a refusal and whether we spend
## a packet — and the host re-checks all of it.
func request_pickup(kind: String, index: int) -> void:
	if is_taken(kind, index):
		pickup_refused.emit("ALREADY READ")
		return
	if not multiplayer.has_multiplayer_peer():
		# Offline / editor: there is nobody to ask, so take the host path directly.
		_grant(Net.local_id(), kind, index)
		return
	_pickup_request.rpc_id(1, kind, index)


func is_taken(kind: String, index: int) -> bool:
	return taken.has("%s:%d" % [kind, index])


## Who took it, or 0. The dead slate draws its own inert state off this.
func taken_by(kind: String, index: int) -> int:
	return int(taken.get("%s:%d" % [kind, index], 0))


@rpc("any_peer", "call_local", "reliable")
func _pickup_request(kind: String, index: int) -> void:
	if not _is_host() or Run.run_over or Run.descending:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	if not Run.is_running(sender):
		return
	if kind != KIND_SLATE and kind != KIND_CACHE and kind != KIND_DROP:
		return
	if is_taken(kind, index):
		_deny(sender, "ALREADY READ")
		return

	# Question three, and the only one a client can lie about: are they at the
	# thing they claim to be reading? Spelled `not (d <= reach)`, never
	# `d > reach` — every distance guard in the project fails closed on a NaN.
	var vessel: Node3D = find_vessel(get_tree(), kind, index)
	var body: Node = Net.get_player(sender)
	if vessel == null or body == null or not is_instance_valid(body):
		_deny(sender, "OUT OF REACH")
		return
	var here: Vector3 = (body as Node3D).global_position
	if not here.is_finite():
		return
	if not (vessel.global_position.distance_to(here) <= Balance.PATCH_PICKUP_REACH):
		push_warning("[Patches] pickup refused: peer %d is %.1f m from %s %d" % [
			sender, vessel.global_position.distance_to(here), kind, index])
		_deny(sender, "OUT OF REACH")
		return
	_grant(sender, kind, index)


## Host-side. Roll, grant, mark spent, ring the bell, broadcast.
func _grant(peer_id: int, kind: String, index: int) -> void:
	var id: String = preview(kind, index)
	if id.is_empty():
		return
	var table: Dictionary = (carried.get(peer_id, {}) as Dictionary).duplicate()
	var count: int = clampi(int(table.get(id, 0)) + 1, 1, Balance.PATCH_MAX_STACKS)
	table[id] = count
	carried[peer_id] = table
	taken["%s:%d" % [kind, index]] = peer_id

	# GREED HAS A PRICE. The noise is rung from inside the host-side validation,
	# exactly like every `Props` action, so a refused pickup is also a silent one
	# and nobody can ping the layer by spamming packets from across the map.
	var vessel: Node3D = find_vessel(get_tree(), kind, index)
	var where: Vector3 = vessel.global_position if vessel != null else Vector3.ZERO
	if kind == KIND_CACHE:
		NoiseBus.ping(where, Balance.PATCH_CACHE_NOISE_ROOMS, "anomaly_cache",
				Balance.PATCH_CACHE_NOISE_TIME)
		# MOTHER NOTICES — through the ONE public door the Director already has,
		# and no further. `Haunt.notice_assertion` was written for a CHECKSUM
		# BARRIER ("a program asserting its own integrity inside hers"), and
		# cracking a pod she welded shut and running what was inside it is the same
		# sentence in a louder register: it pins her combat stress and MAY spend a
		# line from the existing `hunt` category, which refuses far more often than
		# it speaks. No new bark category, no corpus edit, no new budget — the
		# whole discipline of DESIGN.md's bark budget is that she is rare, and a
		# system that invented itself a voice would be the thing that breaks it.
		if Haunt != null:
			Haunt.notice_assertion()
	else:
		NoiseBus.ping(where, Balance.PATCH_SLATE_NOISE_ROOMS, "pocket_secretary",
				Balance.PATCH_SLATE_NOISE_TIME)

	print("[Patches] %s took %s x%d from a %s (%s)" % [
		Net.crew_name(peer_id), display_name(id), count, kind,
		Balance.patch_tier_name(rarity(id))])
	if not multiplayer.has_multiplayer_peer():
		_pickup_applied(peer_id, kind, index, id, count, carried, taken)
		return
	_pickup_applied.rpc(peer_id, kind, index, id, count, carried, taken)


@rpc("authority", "call_local", "reliable")
func _pickup_applied(peer_id: int, kind: String, index: int, id: String,
		count: int, all_carried: Dictionary, all_taken: Dictionary) -> void:
	carried = all_carried
	taken = all_taken
	carried_changed.emit()
	patch_gained.emit(peer_id, id, count)
	# Every peer prints what it now believes the whole crew is carrying. Verbose,
	# and worth it: "did the grant land on the other machine, and did it land on
	# the RIGHT player" is the one question a per-player pickup in a co-op game has
	# to be able to answer from a log rather than from two screenshots.
	if Debug.log_ai:
		for member: Variant in Net.crew.keys():
			print("[Patches] %s carries %s" % [Net.crew_name(int(member)),
				describe(carried_of(int(member)))])
	# The juice runs on every peer — a crewmate reading a slate across the room
	# should light the room for a moment — but the caption and the HUD surface
	# belong to the one who got it. Patches are PER-PLAYER; the crew negotiates
	# over voice, like everything here.
	var vessel: Node3D = find_vessel(get_tree(), kind, index)
	if vessel != null:
		PatchFx.pickup(vessel.global_position, Net.crew_color(peer_id), rarity(id),
				peer_id == Net.local_id())
	if peer_id == Net.local_id():
		Run.notice.emit("PATCH INJECTED  ·  %s  x%d" % [display_name(id), count])


## The host's whole table, pushed on a roster change. Idempotent by construction:
## it is a snapshot, not a delta, so a peer that received it twice is correct and
## a peer that missed one is fixed by the next.
@rpc("authority", "call_local", "reliable")
func _push_carried(all_carried: Dictionary, all_taken: Dictionary) -> void:
	carried = all_carried
	taken = all_taken
	carried_changed.emit()


func _deny(peer_id: int, reason: String) -> void:
	# The host is its own client, and an `rpc_id` at yourself on a `call_remote`
	# method is an engine error rather than a delivered packet. Same fix and same
	# reason as `Subs._deny` and `Modules._refuse`.
	if peer_id == multiplayer.get_unique_id():
		_pickup_denied(reason)
		return
	_pickup_denied.rpc_id(peer_id, reason)


@rpc("authority", "call_remote", "reliable")
func _pickup_denied(reason: String) -> void:
	pickup_refused.emit(reason)


## The vessel with this kind and index, on this peer. Every peer built its own
## copy from the same seed, so this is a local lookup rather than a node path.
static func find_vessel(tree: SceneTree, kind: String, index: int) -> Node3D:
	if tree == null:
		return null
	var group: String = GROUP_CACHE if kind == KIND_CACHE else GROUP_SLATE
	for node: Node in tree.get_nodes_in_group(group):
		var prop: Node3D = node as Node3D
		if prop == null or not is_instance_valid(prop):
			continue
		# Kind AND index. A placed slate and a dropped one share the group and can
		# share an index, and telling them apart is what stops reading one from
		# marking the other spent.
		if int(prop.get("prop_index")) != index:
			continue
		if group == GROUP_SLATE and String(prop.get("vessel_kind")) != kind:
			continue
		return prop
	return null


# --------------------------------------------------------- host: the breaker --
#
# Three patches read the cutter and two write to it. All of them go through the
# two functions below, which `Run._breaker_request` calls on either side of the
# shot it was already resolving — so there is exactly one place in the game where
# a patched cut differs from a bare one.

## SPECULATIVE EXECUTION and HOT LOOP, applied to a shot the host is about to
## resolve. Returns the damage that should actually land.
##
## Order matters and is stated rather than incidental: the speculative crit is a
## MULTIPLIER on the base, and the hot-loop ramp multiplies whatever came out of
## it — so a crit that lands mid-ramp is worth more, which is the read a player
## expects from "the ramp is on my damage".
func amplify(peer_id: int, creature: Antivirus, base: float) -> float:
	if base <= 0.0 or creature == null or not is_instance_valid(creature):
		return base
	var out: float = base
	var now: float = _now()

	var spec: int = stacks(peer_id, "speculative_execution")
	if spec > 0 and now - float(_last_shot.get(peer_id, -999.0)) >= spec_idle_for(spec):
		out *= spec_bonus_for(spec)

	var loop: int = stacks(peer_id, "hot_loop")
	if loop > 0:
		var state: Dictionary = _loop.get(peer_id, {}) as Dictionary
		var same: bool = int(state.get("target", 0)) == creature.get_instance_id() \
				and now - float(state.get("at", -999.0)) <= Balance.PATCH_HOTLOOP_WINDOW
		var run_length: int = 0
		if same:
			run_length = int(state.get("hits", 0))
		out *= hot_loop_bonus_for(loop, run_length)
	return out


## Everything that happens BECAUSE a cut landed. Called by the host from
## `Run._breaker_request` with the damage that was actually applied.
func on_breaker_hit(peer_id: int, creature: Antivirus, damage: float,
		origin: Vector3, killed: bool) -> void:
	if not _is_host():
		return
	var now: float = _now()
	_last_shot[peer_id] = now
	if creature == null or not is_instance_valid(creature):
		return

	# HOT LOOP bookkeeping: one target at a time, and switching targets costs the
	# ramp. A run of hits is the thing being rewarded.
	if stacks(peer_id, "hot_loop") > 0:
		var state: Dictionary = _loop.get(peer_id, {}) as Dictionary
		var same: bool = int(state.get("target", 0)) == creature.get_instance_id() \
				and now - float(state.get("at", -999.0)) <= Balance.PATCH_HOTLOOP_WINDOW
		var run_length: int = (int(state.get("hits", 0)) + 1) if same else 1
		_loop[peer_id] = {
			"target": creature.get_instance_id(), "hits": run_length, "at": now,
		}

	if killed:
		# `announce` false: `Run._breaker_shot` is already carrying this kill to
		# every peer along with the lash. See `_on_deleted`.
		_on_deleted(peer_id, creature, false)
		return

	# BIT ROT. Refreshed, never stacked into a second timer: six stacks is one
	# heavier decay, so the cap in `Balance` is the cap in the world.
	var rot: int = stacks(peer_id, "bit_rot")
	if rot > 0 and damage > 0.0:
		var pool: float = damage * rot_fraction_for(rot)
		var key: int = creature.get_instance_id()
		var live: Dictionary = _rot.get(key, {}) as Dictionary
		_rot[key] = {
			"left": maxf(pool, float(live.get("left", 0.0))),
			"rate": maxf(pool, float(live.get("left", 0.0))) / Balance.PATCH_ROT_SECONDS,
			"peer": peer_id,
			"node": creature,
		}

	# TAIL CALL, last: it is the loudest thing a cut can do and it must not
	# perturb the bookkeeping above.
	var chain: int = stacks(peer_id, "tail_call")
	if chain > 0 and damage > 0.0:
		_run_tail_call(peer_id, creature, damage, chain, origin)


## The chain. Breadth-nothing, depth-`links`: each link finds the nearest process
## it has not already visited, inside `PATCH_TAILCALL_RANGE` of the LAST one, and
## hands on a decaying share of the parent's damage.
##
## Every link goes through `Antivirus.take_damage`, which is the same door the
## aimed shot went through — so armour, the Sentinel's core multiplier and the
## death path all behave exactly as they always have. The chain adds a caller,
## never a new kind of damage.
func _run_tail_call(peer_id: int, from: Antivirus, damage: float, chain_stacks: int,
		origin: Vector3) -> void:
	var links: int = mini(
			Balance.PATCH_TAILCALL_LINKS
					+ Balance.PATCH_TAILCALL_LINKS_PER_STACK * (chain_stacks - 1),
			Balance.PATCH_TAILCALL_LINKS_MAX)
	var visited: Dictionary = {from.get_instance_id(): true}
	var here: Antivirus = from
	var carry: float = damage * Balance.PATCH_TAILCALL_FALLOFF
	var hops: PackedStringArray = PackedStringArray()
	# The polyline the bolts are drawn along, collected as we go and sent once.
	var path: PackedVector3Array = PackedVector3Array([from.aim_point()])
	for _link: int in links:
		if carry <= 0.5 or here == null or not is_instance_valid(here):
			break
		var next: Antivirus = _nearest_unvisited(here.global_position, visited)
		if next == null:
			break
		visited[next.get_instance_id()] = true
		var landed: float = next.breaker_damage(origin, carry)
		next.take_damage(landed, here.global_position)
		path.append(next.aim_point())
		hops.append("%s(%.0f)" % [String(next.name), landed])
		if next.health <= 0.0:
			# A chain link kill. No shot packet is carrying it, so it announces.
			_on_deleted(peer_id, next, true)
		here = next
		carry *= Balance.PATCH_TAILCALL_DECAY
	if path.size() < 2:
		return
	if Debug.log_ai:
		print("[Patches] TAIL CALL from %s -> %s" % [String(from.name), " -> ".join(hops)])
	# THE ONE PLACE M9 STREAMS AN EFFECT, and it is worth saying why rather than
	# leaving it as an inconsistency. Every other patch effect is derivable from a
	# packet every peer already has; this one is not — the chain is resolved
	# against the HOST's creature positions and health, and a client recomputing
	# it from its own smoothed puppets would draw a different chain near a tie.
	# So the geometry travels, UNRELIABLY: it is a fifth of a second of additive
	# geometry with no light on it, and a dropped bolt costs a player nothing.
	if multiplayer.has_multiplayer_peer():
		_chain_arc.rpc(peer_id, path)
	else:
		_chain_arc(peer_id, path)


@rpc("authority", "call_local", "unreliable")
func _chain_arc(peer_id: int, path: PackedVector3Array) -> void:
	if path.size() < 2:
		return
	var tint: Color = Net.crew_color(peer_id)
	var home: Node = _dynamic()
	for i: int in path.size() - 1:
		home.add_child(PatchFx.chain_arc(path[i], path[i + 1], tint))


func _nearest_unvisited(from: Vector3, visited: Dictionary) -> Antivirus:
	var best: Antivirus = null
	var best_distance: float = Balance.PATCH_TAILCALL_RANGE
	for node: Node in get_tree().get_nodes_in_group(Antivirus.GROUP):
		var creature: Antivirus = node as Antivirus
		if creature == null or not is_instance_valid(creature):
			continue
		if visited.has(creature.get_instance_id()) or creature.health <= 0.0:
			continue
		var distance: float = creature.global_position.distance_to(from)
		if distance >= best_distance:
			continue
		best_distance = distance
		best = creature
	return best


## A process this peer deleted, however it died (aimed cut, chain link or rot).
## GARBAGE COLLECT's refund and the slate drop both live here so there is one
## definition of "deleted by you".
##
## ## `announce` and why it is not defaulted
##
## `Run.process_deleted` is what the achievements, the lifetime deletion counter,
## MOTHER's kill acknowledgement and the music director's combat clock all listen
## to, and until M9 QA only ONE of this function's three callers ever reached it:
## the aimed shot, because `Run._breaker_shot` emits the signal itself on the way
## past. A chain link and a rot tick deleted a process and told nobody — the same
## kill, worth nothing, because of which line of code finished it.
##
## So the announcement belongs here, where "deleted by you" is defined... except
## for the one caller whose packet has already said it. Emitting unconditionally
## would double-fire every ordinary breaker kill: two deletions counted, two
## achievements ticked, one process.
##
## Hence a parameter, and hence no default on it. A fourth caller has to decide,
## in one word, whether it has already announced — which is exactly the question
## the three existing ones each got wrong or right silently.
func _on_deleted(peer_id: int, creature: Antivirus, announce: bool) -> void:
	_rot.erase(creature.get_instance_id())
	_maybe_drop_slate(creature)
	if announce:
		var script: Script = creature.get_script() as Script
		Run.announce_deletion(peer_id,
				"" if script == null else script.get_global_name())
	var gc: int = stacks(peer_id, "garbage_collect")
	if gc <= 0:
		return
	var heavy: bool = creature.health_max >= 300.0
	var refund: float = Balance.PATCH_GC_PER_STACK * float(gc)
	if heavy:
		refund *= Balance.PATCH_GC_HEAVY_MULT
	# THE CAP. Tallied per layer against the crew's own pool ceiling, so a nest
	# is worth about half a siphon at six stacks and never worth more than the
	# tap you did not go and find. This is the line that keeps the drain the boss.
	var ceiling: float = Modules.crew_pool_max() * Balance.PATCH_GC_LAYER_CAP_FRACTION
	refund = minf(refund, maxf(ceiling - _gc_credit, 0.0))
	if refund <= 0.0:
		return
	_gc_credit += refund
	Run.cycles = minf(Run.cycles + refund, Run.cycles_max)
	Run.cycles_changed.emit(Run.cycles)
	if Debug.log_cycles:
		print("[Patches] GARBAGE COLLECT refunded %.1f cycles (%.0f/%.0f this layer)" % [
			refund, _gc_credit, ceiling])


## ACQUISITION SOURCE (b): a deleted process leaves its slate behind.
##
## The fiction is the same one the whole system runs on — a hot-patch lives in a
## running instance's memory, so what a deleted process leaves is not a patch, it
## is a SLATE with one written on it, exactly like the ones the engineers left.
## Same prop, same channel, same noise; only the rarity mix is stingier
## (`PATCH_WEIGHTS_DROP`), because the reward for fighting is the data and a patch
## on top is a bonus.
##
## Whether it drops is hashed off the creature's own slot index, so it is decided
## by WHICH process died rather than by how many died before it: a crew that
## clears a nest in a different order gets the same drops. What is NOT derivable
## on a client is *that* it died to something the host resolved, so the spawn is
## the one host->everyone packet in this path — and it is rare by construction
## (1.4% of Scrubbers, 22% of Sentinels, 34% of hunters).
func _maybe_drop_slate(creature: Antivirus) -> void:
	if not _is_host() or creature == null or not is_instance_valid(creature):
		return
	var script: Script = creature.get_script() as Script
	var kind: String = "" if script == null else script.get_global_name()
	if not process_drops(kind, creature.slot_index, Run.layer_number):
		return
	var where: Vector3 = creature.global_position
	if not where.is_finite():
		return
	print("[Patches] %s left a pocket secretary behind" % String(creature.name))
	if multiplayer.has_multiplayer_peer():
		_drop_slate.rpc(creature.slot_index, where)
	else:
		_drop_slate(creature.slot_index, where)


@rpc("authority", "call_local", "reliable")
func _drop_slate(index: int, where: Vector3) -> void:
	# The patch on it is hash-derived from the same three numbers on every peer, so
	# the packet carries a position and an index and nothing about the contents.
	var tier: int = Balance.patch_tier(preview(KIND_DROP, index))
	var yaw: float = UiFx.hash01(where.x * 7.7 + where.z * 3.1) * TAU
	_dynamic().add_child(PocketSecretary.create(index,
			where + Vector3(0.0, 0.03, 0.0), yaw, tier, KIND_DROP))


# ------------------------------------------------------------- host: the rot --

func _process(delta: float) -> void:
	if not _is_host() or _rot.is_empty():
		return
	_rot_clock += delta
	if _rot_clock < Balance.PATCH_ROT_TICK:
		return
	var step: float = _rot_clock
	_rot_clock = 0.0
	var dead: Array[int] = []
	for key: Variant in _rot.keys():
		var entry: Dictionary = _rot[key] as Dictionary
		var creature: Antivirus = entry["node"] as Antivirus
		if creature == null or not is_instance_valid(creature) or creature.health <= 0.0:
			dead.append(int(key))
			continue
		var bite: float = minf(float(entry["rate"]) * step, float(entry["left"]))
		if bite <= 0.0:
			dead.append(int(key))
			continue
		entry["left"] = float(entry["left"]) - bite
		creature.take_damage(bite, creature.global_position)
		if creature.health <= 0.0:
			# A rot kill, seconds after the cut that seeded it. Announces, for the
			# same reason the chain does.
			_on_deleted(int(entry["peer"]), creature, true)
			dead.append(int(key))
		elif float(entry["left"]) <= 0.0:
			dead.append(int(key))
	for key: int in dead:
		_rot.erase(key)


# ------------------------------------------------------ host: incoming damage --

## PARITY BIT and WATCHDOG, applied to a hostile hit the host is about to land.
## Called from `Antivirus._land_hit` — the single door every hostile strike in
## the game already goes through — AFTER the fork and i-frame questions and
## AFTER the barrier has taken its share, so a patch never covers for a shell
## that was already covering.
##
## Deliberately NOT wired to `Run.damage_player` itself, which would also catch
## falls and starvation. A patch is error correction against MOTHER's writes; a
## drop off a gantry is your own arithmetic.
func on_incoming(peer_id: int, amount: float, from: Vector3) -> float:
	if not _is_host() or amount <= 0.0:
		return amount

	# WATCHDOG first: it is the one that can eat the whole blow, and asking the
	# cheaper question first would shave a hit the shell was going to absorb.
	var dog: int = stacks(peer_id, "watchdog")
	if dog > 0:
		var charges: int = mini(Balance.PATCH_WATCHDOG_CHARGES_PER_STACK * dog,
				Balance.PATCH_WATCHDOG_CHARGES_MAX)
		var spent: int = int(_watchdog_spent.get(peer_id, 0))
		var after: float = Run.integrity_of(peer_id) - amount
		var trigger: float = Run.integrity_max_of(peer_id) \
				* Balance.PATCH_WATCHDOG_TRIGGER_FRACTION
		if spent < charges and after <= trigger:
			_watchdog_spent[peer_id] = spent + 1
			var body: Node = Net.get_player(peer_id)
			var where: Vector3 = from
			if body != null and is_instance_valid(body):
				where = (body as Node3D).global_position
			var serial: int = _next_shell
			_next_shell -= 1
			print("[Patches] WATCHDOG fired for %s (%d/%d this layer)" % [
				Net.crew_name(peer_id), spent + 1, charges])
			if multiplayer.has_multiplayer_peer():
				_watchdog_fired.rpc(peer_id, where, serial)
			else:
				_watchdog_fired(peer_id, where, serial)
			return 0.0

	var parity: int = stacks(peer_id, "parity_bit")
	if parity > 0:
		var shave: float = minf(Balance.PATCH_PARITY_PER_STACK * float(parity),
				amount * Balance.PATCH_PARITY_MAX_FRACTION)
		return maxf(amount - shave, 0.0)
	return amount


## The free shell. Reuses `ChecksumBarrier` — the same object CHECKSUM BARRIER
## casts — rather than inventing a second shield, so a crewmate standing with the
## saved player is covered by it exactly as they would be by a cast one, and
## `Antivirus._land_hit`'s barrier branch needs no new case.
##
## The serial is NEGATIVE so it can never collide with `Subs`' own positive
## barrier ids while both live in the `ChecksumBarrier.GROUP`.
@rpc("authority", "call_local", "reliable")
func _watchdog_fired(peer_id: int, where: Vector3, serial: int) -> void:
	var shell: ChecksumBarrier = ChecksumBarrier.create(serial, peer_id, where,
			Net.crew_color(peer_id), Balance.PATCH_WATCHDOG_SHELL_RADIUS,
			Balance.PATCH_WATCHDOG_SHELL_SECONDS, Balance.PATCH_WATCHDOG_SHELL_ABSORB)
	_dynamic().add_child(shell)
	Audio.play_3d(&"patch_watchdog", where)
	if peer_id == Net.local_id():
		Run.notice.emit("WATCHDOG  ·  INTEGRITY ASSERTED")


## Where the patch system's world objects are parented: the layer's own `Dynamic`
## node, so a descent frees a live shell with everything else. Same home and same
## reason as `Subs._dynamic`.
func _dynamic() -> Node:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null:
		return self
	var dynamic: Node = layer.get_node_or_null("Dynamic")
	return dynamic if dynamic != null else layer


# ---------------------------------------------------------- passive modifiers --
#
# The read-only half: small pure functions the systems that own each number call
# at the point they compute it. Every one of them returns the identity value for
# a peer carrying nothing, so an unpatched game is bit-for-bit the game it was.
#
# Each comes in two halves, and the split is not decoration. The `*_for(stacks)`
# STATIC is the maths; the instance method is the table lookup that feeds it. The
# self-test drives the statics directly, so it is asserting the arithmetic the
# game actually runs rather than a copy of it written in the test — which is the
# only version of this check that stays true when somebody retunes a constant.

## PRIORITY BOOST. `1 + CEILING * (1 - FALLOFF^stacks)` — sharply diminishing, and
## bounded so a maxed-Servos patched WALK still stays under the sprint billing
## threshold. `--selftest` asserts that margin; see `Balance`.
static func move_multiplier_for(count: int) -> float:
	if count <= 0:
		return 1.0
	return 1.0 + Balance.PATCH_PRIORITY_CEILING \
			* (1.0 - pow(Balance.PATCH_PRIORITY_FALLOFF, float(count)))


func move_multiplier(peer_id: int = -1) -> float:
	var who: int = Net.local_id() if peer_id < 0 else peer_id
	return move_multiplier_for(stacks(who, "priority_boost"))


## ZERO PAGE. The landing's noise reach in rooms, lowered one tier a stack and
## floored at "this room only". The ONLY noise reduction in the catalogue, and it
## has exactly one caller.
static func land_rooms_for(count: int, base_rooms: int) -> int:
	return maxi(base_rooms - Balance.PATCH_ZEROPAGE_PER_STACK * maxi(count, 0), 0)


func land_noise_rooms(peer_id: int, base_rooms: int) -> int:
	return land_rooms_for(stacks(peer_id, "zero_page"), base_rooms)


## INSTRUCTION FUSION. Multiplier on the heat one breaker shot books. Floored, so
## the cutter always heats and the lockout is always reachable.
static func heat_scale_for(count: int) -> float:
	if count <= 0:
		return 1.0
	return maxf(1.0 - Balance.PATCH_FUSION_PER_STACK * float(count),
			Balance.PATCH_FUSION_FLOOR)


func heat_scale(peer_id: int = -1) -> float:
	var who: int = Net.local_id() if peer_id < 0 else peer_id
	return heat_scale_for(stacks(who, "instruction_fusion"))


## SLEEP STATE. Multiplier on a peer's PASSIVE drain while their beam is off.
static func sleep_scale_for(count: int) -> float:
	if count <= 0:
		return 1.0
	return maxf(1.0 - Balance.PATCH_SLEEP_PER_STACK * float(count),
			Balance.PATCH_SLEEP_FLOOR)


## Returns 1.0 the instant the beam comes on: the patch pays you for the dark and
## nothing else, and it gives you no light to pay for it with.
func drain_scale(peer_id: int, beam_on: bool) -> float:
	if beam_on:
		return 1.0
	return sleep_scale_for(stacks(peer_id, "sleep_state"))


## HOT LOOP's multiplier for a run of `run_length` consecutive hits on one target.
static func hot_loop_bonus_for(count: int, run_length: int) -> float:
	if count <= 0:
		return 1.0
	var ceiling: int = Balance.PATCH_HOTLOOP_STEPS_PER_STACK * count
	return 1.0 + minf(Balance.PATCH_HOTLOOP_STEP * float(mini(run_length, ceiling)),
			Balance.PATCH_HOTLOOP_MAX)


## SPECULATIVE EXECUTION's crit multiplier, and the idle it needs to arm.
static func spec_bonus_for(count: int) -> float:
	if count <= 0:
		return 1.0
	return 1.0 + minf(Balance.PATCH_SPEC_BONUS_PER_STACK * float(count),
			Balance.PATCH_SPEC_MAX)


static func spec_idle_for(count: int) -> float:
	if count <= 0:
		return Balance.PATCH_SPEC_IDLE
	return maxf(Balance.PATCH_SPEC_IDLE
			- Balance.PATCH_SPEC_IDLE_PER_STACK * float(count - 1),
			Balance.PATCH_SPEC_IDLE_FLOOR)


## BIT ROT's share of a landed hit.
static func rot_fraction_for(count: int) -> float:
	if count <= 0:
		return 0.0
	return minf(Balance.PATCH_ROT_FRACTION_PER_STACK * float(count),
			Balance.PATCH_ROT_MAX_FRACTION)


## RACE CONDITION. Host-side, called once per billing frame per running peer:
## `true` means the sprint surcharge applies, `false` means the scheduler has not
## noticed yet. The passive drain runs either way — you still exist.
##
## Stateful on purpose. The window is spent by CONTINUOUS sprinting and re-arms
## only after `PATCH_RACE_REARM` seconds under the billing speed, so it is a
## burst across a corridor and never a free sprint held by tapping the key.
func bills_sprint(peer_id: int, sprinting: bool, delta: float) -> bool:
	var count: int = stacks(peer_id, "race_condition")
	if count <= 0:
		return sprinting
	var state: Dictionary = _sprint.get(peer_id, {}) as Dictionary
	var used: float = float(state.get("used", 0.0))
	var rest: float = float(state.get("rest", 0.0))
	if not sprinting:
		rest += delta
		if rest >= Balance.PATCH_RACE_REARM:
			used = 0.0
		_sprint[peer_id] = {"used": used, "rest": rest}
		return false
	var window: float = minf(
			Balance.PATCH_RACE_SECONDS + Balance.PATCH_RACE_PER_STACK * float(count - 1),
			Balance.PATCH_RACE_MAX)
	used += delta
	_sprint[peer_id] = {"used": used, "rest": 0.0}
	return used > window


## NOP SLED. Extra seconds of SURGE STEP immunity.
static func iframe_bonus_for(count: int) -> float:
	if count <= 0:
		return 0.0
	return minf(Balance.PATCH_NOPSLED_PER_STACK * float(count), Balance.PATCH_NOPSLED_MAX)


func iframe_bonus(peer_id: int) -> float:
	return iframe_bonus_for(stacks(peer_id, "nop_sled"))


## OVERFLOW. Multiplier on STACK PULSE's radius. The NOISE is untouched — see
## `Balance`: a patch that made the panic button quieter would delete the
## ability's whole price.
static func pulse_radius_for(count: int) -> float:
	if count <= 0:
		return 1.0
	return 1.0 + minf(Balance.PATCH_OVERFLOW_RADIUS_PER_STACK * float(count),
			Balance.PATCH_OVERFLOW_RADIUS_MAX)


func pulse_radius_scale(peer_id: int) -> float:
	return pulse_radius_for(stacks(peer_id, "overflow"))


## OVERFLOW's second half: extra seconds a staggered process stays out of it.
static func pulse_stagger_for(count: int) -> float:
	if count <= 0:
		return 0.0
	return minf(Balance.PATCH_OVERFLOW_STAGGER_PER_STACK * float(count),
			Balance.PATCH_OVERFLOW_STAGGER_MAX)


func pulse_stagger_bonus(peer_id: int) -> float:
	return pulse_stagger_for(stacks(peer_id, "overflow"))


## DEAD CODE. Multiplier on a fork's lifetime, and extra strikes it soaks.
static func decoy_lifetime_for(count: int) -> float:
	if count <= 0:
		return 1.0
	return 1.0 + minf(Balance.PATCH_DEADCODE_LIFE_PER_STACK * float(count),
			Balance.PATCH_DEADCODE_LIFE_MAX)


func decoy_lifetime_scale(peer_id: int) -> float:
	return decoy_lifetime_for(stacks(peer_id, "dead_code"))


static func decoy_hits_for(count: int) -> int:
	if count <= 0:
		return 0
	return mini(count / 2 * Balance.PATCH_DEADCODE_HITS_PER_TWO_STACKS,
			Balance.PATCH_DEADCODE_HITS_MAX)


func decoy_hits_bonus(peer_id: int) -> int:
	return decoy_hits_for(stacks(peer_id, "dead_code"))


# ------------------------------------------------------------------- the exit --

## What this peer's carried patches are worth on exfiltration.
##
## Patches do not survive the run — the process you exfiltrate is the process you
## stop running — so ending a stacked run has to pay something or the whole
## system punishes success. You sell them back: each stack converts at its
## rarity's rate (`Balance.PATCH_EXFIL_DATA`), banked with the buffer.
##
## Host-side, called from `Run._fire_exfil` for each peer standing on the pad. A
## crewmate who was left behind converts nothing, which is the same rule their
## buffer already follows.
func exfil_bonus(peer_id: int) -> int:
	var total: int = 0
	for id: String in Balance.PATCH_TRACKS:
		var count: int = stacks(peer_id, id)
		if count <= 0:
			continue
		var tier: int = clampi(rarity(id), 0, Balance.PATCH_EXFIL_DATA.size() - 1)
		total += Balance.PATCH_EXFIL_DATA[tier] * count
	return total


# ------------------------------------------------------------------ dev tools --

## `--patches ID[:STACKS],…`. A carried set without the run that earned it, for
## measuring and for captures.
##
## Parsed HERE rather than in `Debug`, on purpose: `src/core/debug.gd` is the
## project's shared instrument file and is append-only while several agents work
## in one tree (CLAUDE.md), and a new flag needs a case inside its existing
## argument match. Reading our own flag off the command line costs one function
## and touches nobody else's milestone. Never written to disk — patches have no
## disk to be written to, which is the point of the system.
func _parse_forced() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var spec: String = ""
	for i: int in args.size():
		if args[i] == "--patches" and i + 1 < args.size():
			spec = args[i + 1]
			break
	if spec.is_empty():
		return
	for chunk: String in spec.split(",", false):
		var parts: PackedStringArray = chunk.strip_edges().split(":")
		var id: String = parts[0].strip_edges().to_lower()
		if not is_patch(id):
			push_warning("[Patches] --patches: no patch '%s'" % id)
			continue
		var count: int = 1
		if parts.size() > 1:
			count = clampi(parts[1].to_int(), 1, Balance.PATCH_MAX_STACKS)
		_forced[id] = count
	if _forced.is_empty():
		return
	carried[Net.local_id()] = (_forced as Dictionary).duplicate()
	print("[Patches] forced carry: %s" % describe(_forced))
	carried_changed.emit()
