extends Node
## Modules — the permanent upgrade layer, and the only place that knows how a
## set of module tiers turns into numbers the simulation uses.
##
## DESIGN.md, "Meta-progression": eight tracks, 3-5 tiers each, compiled into
## your source forever. Losing a run costs the data in your buffers, never your
## build. Every tunable is in `Balance.MODULES`; everything here is behaviour.
##
## ## Where a player's tiers live, and who is allowed to believe them
##
## Three copies exist and they are not equal:
##
##   1. **The program file** (`user://save.json`, owned by GameState) is the
##      truth for *your* machine, across sessions. Nothing else survives a quit.
##   2. **The crew roster** (`Net.crew[id]["modules"]`) is the truth for *this
##      session*. It is announced on join and re-broadcast on every purchase, so
##      every peer — the host that simulates, and the clients that only need to
##      draw a wider beam on a crewmate — reads the same table.
##   3. **The loadout cache** below is a resolved, memoised view of (2). It is
##      invalidated whenever the roster changes and never written to directly.
##
## The host resolves (2) and applies it. A client applies exactly one thing from
## its own copy: the cosmetic half of Optics on its own avatar, because a beam
## that waits for a round trip to widen is a beam that reads as laggy. Everything
## with a consequence — damage, drain, integrity, stock, funds — is host-side.
##
## ## Archive, and what "host-validated" honestly means here
##
## Buffered data is host-owned (Run.buffered_value): the host knows exactly what
## every agent picked up because it is the thing that decided they picked it up.
## The archive is *not* — DESIGN.md puts the wallet on the player's own machine
## on purpose, and there is no server to ask. So a joining peer announces its
## archive and the host keeps a **session mirror** of it (`Net.crew[id]
## ["archive"]`), spends against that mirror, and refuses anything the mirror
## cannot pay for. That makes double-spending inside a session impossible, which
## is the property that actually matters for a co-op game; it does not, and
## cannot, stop somebody editing their own save file between sessions. Being
## clear about which of those two we bought is better than pretending.

## A purchase landed for `peer_id`. Every peer gets this — the buyer to write its
## program file, everyone else to re-resolve that peer's loadout.
signal purchased(peer_id: int, track: String, tier: int, from_buffer: int, from_archive: int)
## The host said no. Local to the peer that asked; the panel glitches on it.
signal refused(track: String, reason: String)
## Somebody's tiers changed (purchase, join, leave). Anything holding a resolved
## loadout should drop it.
signal loadouts_changed


## Resolved effect keys, with the bare-constant values a peer with no modules
## at all gets. Kept as one dictionary so a loadout is always the same shape and
## a consumer can never read a key that is sometimes missing.
##
## `beam_cone_deg` / `beam_expose` are the exposure geometry the Scrubbers flee
## from. They are derived from the Optics *visual* numbers rather than listed
## separately in Balance, because the whole point of the track is that what you
## can see and what the antivirus is afraid of are the same cone.
static func base_loadout() -> Dictionary:
	return {
		"share": Balance.CYCLES_PER_CREW,
		"drain": Balance.PASSIVE_DRAIN,
		"sprint": Balance.SPRINT_DRAIN_MULT,
		"integrity": Balance.INTEGRITY_MAX,
		"damage": Balance.BREAKER_DAMAGE,
		"range": Balance.BREAKER_RANGE,
		"beam_angle": 26.0,
		"beam_energy": 6.6,
		"beam_reach": 30.0,
		"beam_cone_deg": Balance.BEAM_HALF_ANGLE_DEG,
		"beam_expose": Balance.BEAM_EXPOSURE_RANGE,
		"move": 1.0,
		"restore": Balance.RESTORE_CHANNEL_TIME,
		"carry_free": Balance.CARRY_FREE_SHARDS,
		"carry_penalty": Balance.CARRY_MAX_PENALTY,
		"flares": Balance.FLARE_STOCK,
	}


## peer id -> resolved loadout. Rebuilt lazily; cleared wholesale rather than
## per-entry, because the events that change it (join, leave, purchase) all
## already re-broadcast the whole roster anyway.
var _cache: Dictionary = {}

## `--modules`. Overrides the local program's tiers for a session without ever
## being written back to the save file.
var _forced_tiers: Dictionary = {}


func _ready() -> void:
	# This autoload is deliberately created *before* GameState, so that the
	# program file's migration can name a track and describe a tier table while
	# it runs. That means Net does not exist yet, and the roster hook has to wait
	# for the whole autoload list to be standing.
	_bind.call_deferred()


func _bind() -> void:
	Net.crew_changed.connect(_invalidate)


func _invalidate() -> void:
	_cache.clear()
	loadouts_changed.emit()


# ------------------------------------------------------------- definitions --

static func definition(track: String) -> Dictionary:
	return Balance.MODULES.get(track, {}) as Dictionary


static func is_track(track: String) -> bool:
	return Balance.MODULES.has(track)


## How many tiers this track has. Read off the price list, so the two can never
## disagree about how far a track goes.
static func tier_count(track: String) -> int:
	var entry: Dictionary = definition(track)
	if entry.is_empty():
		return 0
	return (entry["prices"] as Array).size()


## Cost of moving from `tier` to `tier + 1`. Zero means there is nothing to buy.
static func price(track: String, tier: int) -> int:
	var entry: Dictionary = definition(track)
	if entry.is_empty():
		return 0
	var prices: Array = entry["prices"]
	if tier < 0 or tier >= prices.size():
		return 0
	return int(prices[tier])


static func display_name(track: String) -> String:
	return String(definition(track).get("name", track.to_upper()))


static func glyph(track: String) -> String:
	return String(definition(track).get("glyph", "◆"))


static func note(track: String) -> String:
	return String(definition(track).get("note", ""))


## One effect value at one tier. `key` is a per-track effect array in Balance.
static func value_at(track: String, key: String, tier: int) -> Variant:
	var entry: Dictionary = definition(track)
	if not entry.has(key):
		return null
	var values: Array = entry[key]
	return values[clampi(tier, 0, values.size() - 1)]


# ---------------------------------------------------------------- resolving --

## Turns a `{track: tier}` table into the flat loadout the simulation reads.
## Pure and static: the determinism dump can call it, a test can call it, and it
## has no idea whose tiers it was handed.
static func resolve(tiers: Dictionary) -> Dictionary:
	var out: Dictionary = base_loadout()

	var runtime: int = _tier_of(tiers, "runtime")
	out["share"] = Balance.CYCLES_PER_CREW + float(value_at("runtime", "share", runtime))
	out["drain"] = Balance.PASSIVE_DRAIN * float(value_at("runtime", "drain", runtime))

	out["sprint"] = float(value_at("threading", "sprint", _tier_of(tiers, "threading")))
	out["integrity"] = float(value_at("checksum", "integrity", _tier_of(tiers, "checksum")))

	var breaker: int = _tier_of(tiers, "breaker")
	out["damage"] = float(value_at("breaker", "damage", breaker))
	out["range"] = float(value_at("breaker", "range", breaker))

	# Optics drives five numbers off three. The cone the Scrubbers avoid is the
	# base exposure geometry scaled by how much wider and further the light
	# actually goes, so "I bought vision" and "they will not come near me" are
	# the same purchase rather than two that have to be kept in step by hand.
	var optics: int = _tier_of(tiers, "optics")
	var angle: float = float(value_at("optics", "angle", optics))
	var reach: float = float(value_at("optics", "reach", optics))
	out["beam_angle"] = angle
	out["beam_energy"] = float(value_at("optics", "energy", optics))
	out["beam_reach"] = reach
	out["beam_cone_deg"] = Balance.BEAM_HALF_ANGLE_DEG * (angle / 26.0)
	out["beam_expose"] = Balance.BEAM_EXPOSURE_RANGE * (reach / 30.0)

	var servos: int = _tier_of(tiers, "servos")
	out["move"] = float(value_at("servos", "move", servos))
	out["restore"] = Balance.RESTORE_CHANNEL_TIME \
			* float(value_at("servos", "restore", servos))

	var buffer: int = _tier_of(tiers, "buffer")
	out["carry_free"] = int(value_at("buffer", "free", buffer))
	out["carry_penalty"] = float(value_at("buffer", "penalty", buffer))

	out["flares"] = int(value_at("cache", "stock", _tier_of(tiers, "cache")))
	return out


static func _tier_of(tiers: Dictionary, track: String) -> int:
	return clampi(int(tiers.get(track, 0)), 0, tier_count(track))


## Everything `peer_id`'s program does to the simulation. Falls back to the bare
## loadout for a peer nobody has announced yet, which is what a dedicated
## server's own id and an editor-run solo session both look like.
func loadout(peer_id: int) -> Dictionary:
	if _cache.has(peer_id):
		return _cache[peer_id] as Dictionary
	var resolved: Dictionary = resolve(tiers_of(peer_id))
	_cache[peer_id] = resolved
	return resolved


## The announced tiers for a peer. The local peer prefers its own live table:
## its save is the truth for itself, and this is also what makes a purchase feel
## instant on the machine that made it rather than a round trip later.
func tiers_of(peer_id: int) -> Dictionary:
	if peer_id == Net.local_id():
		return local_tiers()
	var entry: Dictionary = Net.crew.get(peer_id, {}) as Dictionary
	return entry.get("modules", {}) as Dictionary


## What this machine's program has compiled. `--modules` wins for a session.
func local_tiers() -> Dictionary:
	if not _forced_tiers.is_empty():
		return _forced_tiers
	return GameState.modules


func local_loadout() -> Dictionary:
	return loadout(Net.local_id())


func tier_of(peer_id: int, track: String) -> int:
	return _tier_of(tiers_of(peer_id), track)


## Pool ceiling for the crew as it currently stands: the sum of everybody's
## Runtime-modified share rather than a multiple of one number. A crew with one
## maxed Runtime and three fresh programs has a bigger pool than four fresh
## ones, and it is the maxed player's build that paid for the difference.
func crew_pool_max() -> float:
	if Net.crew.is_empty():
		return Balance.CYCLES_PER_CREW
	var total: float = 0.0
	for id: int in Net.crew.keys():
		total += float(loadout(int(id))["share"])
	return maxf(total, Balance.CYCLES_PER_CREW)


# ------------------------------------------------------------------ pricing --

## What buying the next tier of `track` would cost `peer_id`, and where the
## money comes from. Buffered data is spent first (DESIGN.md makes both
## spendable mid-run, and spending the volatile half first is strictly better
## for the player — anything left in a buffer can still be lost).
##
## Returns {tier, price, from_buffer, from_archive, affordable, reason}.
func quote(peer_id: int, track: String, stock_tier: int) -> Dictionary:
	var tier: int = tier_of(peer_id, track)
	var next: int = tier + 1
	var out: Dictionary = {
		"track": track, "tier": tier, "next": next, "price": 0,
		"from_buffer": 0, "from_archive": 0, "affordable": false, "reason": "",
	}
	if not is_track(track):
		out["reason"] = "NO SUCH MODULE"
		return out
	if next > tier_count(track):
		out["reason"] = "FULLY COMPILED"
		return out
	if next > stock_tier:
		out["reason"] = "TIER %d NOT STOCKED HERE" % next
		return out

	var cost: int = price(track, tier)
	out["price"] = cost
	var buffer: int = Run.buffered_value_of(peer_id)
	var archive: int = archive_of(peer_id)
	var from_buffer: int = mini(buffer, cost)
	var from_archive: int = cost - from_buffer
	out["from_buffer"] = from_buffer
	out["from_archive"] = from_archive
	if from_archive > archive:
		out["reason"] = "INSUFFICIENT DATA"
		return out
	out["affordable"] = true
	return out


## The session mirror of a peer's wallet. The local peer reads its own live
## GameState so a purchase and a bank both show up immediately.
func archive_of(peer_id: int) -> int:
	if peer_id == Net.local_id():
		return GameState.archive
	var entry: Dictionary = Net.crew.get(peer_id, {}) as Dictionary
	return maxi(int(entry.get("archive", 0)), 0)


# ---------------------------------------------------------------- purchasing --

## Local player pressed BUY. Goes to the host like every other consequential
## thing in the game; the panel does not move a pip until the host says so.
func request_purchase(track: String, compiler_id: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		refused.emit(track, "NO SESSION")
		return
	_purchase_request.rpc_id(1, track, compiler_id)


@rpc("any_peer", "call_local", "reliable")
func _purchase_request(track: String, compiler_id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	if Run.run_over:
		_refuse(sender, track, "RUN OVER")
		return
	if not Run.is_running(sender):
		_refuse(sender, track, "PROCESS NOT RUNNING")
		return

	# Proximity, the same shape as the siphon's: the panel ran on the client, so
	# this is the one place that can tell "stood at the Compiler" from "sent a
	# packet". The Compiler is seeded content, so the host has its own copy of
	# the exact node the client says it is using.
	var terminal: CompilerTerminal = CompilerTerminal.find(get_tree(), compiler_id)
	var player: Node = Net.get_player(sender)
	if terminal == null or player == null or not is_instance_valid(player):
		_refuse(sender, track, "COMPILER OUT OF REACH")
		return
	if terminal.global_position.distance_to(
			(player as Node3D).global_position) > CompilerTerminal.USE_RANGE:
		push_warning("[Modules] purchase refused: peer %d is not at compiler %d" % [
			sender, compiler_id])
		_refuse(sender, track, "COMPILER OUT OF REACH")
		return

	var deal: Dictionary = quote(sender, track, terminal.stock_tier)
	if not bool(deal["affordable"]):
		_refuse(sender, track, String(deal["reason"]))
		return

	# Host-side commit. Both halves of the payment come out of numbers the host
	# owns for the duration of the session, and the roster goes back out so every
	# peer re-resolves this player before the next frame's simulation.
	var from_buffer: int = int(deal["from_buffer"])
	var from_archive: int = int(deal["from_archive"])
	Run.spend_buffer(sender, from_buffer)
	var entry: Dictionary = Net.crew.get(sender, {}) as Dictionary
	entry["archive"] = maxi(int(entry.get("archive", 0)) - from_archive, 0)
	var tiers: Dictionary = (entry.get("modules", {}) as Dictionary).duplicate()
	tiers[track] = int(deal["next"])
	entry["modules"] = tiers
	Net.crew[sender] = entry
	print("[Modules] %s compiled %s tier %d for %d (%d buffered + %d archive)" % [
		Net.crew_name(sender), track.to_upper(), int(deal["next"]),
		int(deal["price"]), from_buffer, from_archive])

	Net.push_crew()
	_purchase_applied.rpc(sender, track, int(deal["next"]), from_buffer, from_archive)


@rpc("authority", "call_local", "reliable")
func _purchase_applied(peer_id: int, track: String, tier: int,
		from_buffer: int, from_archive: int) -> void:
	_cache.erase(peer_id)
	if not multiplayer.is_server():
		# The host already debited its own copy when it validated. A client runs
		# the same arithmetic now so the panel updates on the frame the purchase
		# lands rather than when the next buffer packet happens to arrive.
		Run.spend_buffer(peer_id, from_buffer)
		var entry: Dictionary = Net.crew.get(peer_id, {}) as Dictionary
		if not entry.is_empty():
			entry["archive"] = maxi(int(entry.get("archive", 0)) - from_archive, 0)
	if peer_id == Net.local_id():
		# The buyer's own program file is the only lasting record of this. The
		# archive was already debited host-side in the session mirror; this is the
		# same debit against the file the mirror was made from.
		GameState.compile_module(track, tier, from_archive)
	loadouts_changed.emit()
	purchased.emit(peer_id, track, tier, from_buffer, from_archive)


## Tells `peer_id` no. The host is its own client, and an `rpc_id` at yourself on
## a `call_remote` method is an engine error rather than a delivered packet — so
## a listen host refusing its own purchase takes the local path.
func _refuse(peer_id: int, track: String, reason: String) -> void:
	if peer_id == multiplayer.get_unique_id():
		_purchase_refused(track, reason)
		return
	_purchase_refused.rpc_id(peer_id, track, reason)


@rpc("authority", "call_remote", "reliable")
func _purchase_refused(track: String, reason: String) -> void:
	print("[Modules] purchase refused: %s — %s" % [track.to_upper(), reason])
	refused.emit(track, reason)


# ------------------------------------------------------------------ dev tools --

## `--modules "runtime:3,optics:2"`. A whole build, without the sixty runs.
## Deliberately never written to the save file: these are for measuring the
## power curve, not for playing with.
func force_tiers(spec: String) -> void:
	_forced_tiers.clear()
	for chunk: String in spec.split(",", false):
		var pair: PackedStringArray = chunk.strip_edges().split(":")
		if pair.size() != 2:
			push_warning("[Modules] --modules: cannot read '%s'" % chunk)
			continue
		var track: String = pair[0].strip_edges().to_lower()
		if not is_track(track):
			push_warning("[Modules] --modules: no track '%s'" % track)
			continue
		_forced_tiers[track] = clampi(pair[1].to_int(), 0, tier_count(track))
	_invalidate()
	print("[Modules] forced tiers: %s" % describe(_forced_tiers))


## Compact one-line rendering of a tier table, for logs and the self-test.
static func describe(tiers: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for track: String in Balance.MODULE_TRACKS:
		var tier: int = int(tiers.get(track, 0))
		if tier > 0:
			parts.append("%s:%d" % [track, tier])
	return "none" if parts.is_empty() else ",".join(parts)


## One line per number the loadout resolves to. `--log-modules` prints this on
## every purchase, which is how "the effect measurably applied" is verified
## without reading it off a screenshot.
func describe_loadout(peer_id: int) -> String:
	var l: Dictionary = loadout(peer_id)
	return ("share=%.0f drain=%.3f sprint=%.2f integrity=%.0f damage=%.0f range=%.1f "
			+ "beam=%.1f°/%.1fe/%.0fm cone=%.1f° expose=%.0fm move=%.2f restore=%.2fs "
			+ "carry=%d/%.3f flares=%d") % [
		float(l["share"]), float(l["drain"]), float(l["sprint"]), float(l["integrity"]),
		float(l["damage"]), float(l["range"]), float(l["beam_angle"]),
		float(l["beam_energy"]), float(l["beam_reach"]), float(l["beam_cone_deg"]),
		float(l["beam_expose"]), float(l["move"]), float(l["restore"]),
		int(l["carry_free"]), float(l["carry_penalty"]), int(l["flares"])]
