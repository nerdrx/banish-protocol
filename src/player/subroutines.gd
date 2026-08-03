extends Node
## Subroutines (autoload `Subs`) — the M7 ability kit: what you own, what is
## compiled into your one active slot, and what happens when you run it.
##
## ## The fiction is the architecture
##
## You are software. A subroutine is a routine compiled into your program, bought
## at a Compiler like any other module and carried between runs like any other
## module. Running one costs the thing you run ON — the shared Cycles pool. That
## is not a balance decision bolted on afterwards; it is the only place a power
## fantasy can attach to this game without floating free of it. DESIGN.md pillar 1
## makes Cycles "the clock, the economy, and the argument the crew has over voice
## chat", so **power always costs breath**.
##
## ## Three laws this file is written under
##
##   **The solo invariant** (DESIGN.md, a design law). Every subroutine is fully
##   usable alone, and NONE of them is ever required. Nothing in the game is gated
##   behind owning one; they change how a fight goes, never whether it can be
##   finished. A player who never buys a subroutine can complete everything.
##
##   **The killability law's cousin.** STACK PULSE is control, not damage. It
##   cancels, staggers and shoves; it has never killed anything and cannot. No
##   subroutine makes a process immune to the breaker, and none deletes one.
##
##   **Host-authoritative, like everything with a consequence.** A client asks; the
##   host decides. It re-checks ownership, the equipped slot, the cooldown, the
##   pool and the distance, exactly the way `Run._breaker_request` does — and the
##   three questions from `Run`'s validation preamble (who sent this, are they
##   running, are they where they say) are asked here too, with the same
##   `if not (dist <= limit)` spelling that fails CLOSED on a NaN.
##
## ## Why this is its own autoload and its own save file
##
## Two reasons, one architectural and one practical. Architecturally the kit is a
## complete subsystem — a catalogue, an ownership table, a wire protocol and four
## effects — and folding it into `Modules` would put abilities into the module
## readout, the program file's module table and the Compiler's module list, none
## of which mean the same thing. Practically, `user://subroutines.cfg` follows the
## precedent `A11y` already set: state that is not the program file survives a
## corrupt program file. Your archive and your module tiers are in `save.json`;
## which subroutine you have slotted is not, and losing one should never cost you
## the other.
##
## ## What crosses the wire
##
## Two packets per cast at most, and never more:
##
##   1. the **request** (client -> host): which subroutine, from where, facing
##      where.
##   2. the **echo** (host -> everyone): it happened, by whom, at what tier, with
##      a serial. Every peer builds the same fx, the same fork and the same shell
##      from it. Nothing about the effects is streamed; they are deterministic
##      from the packet, so a fork walks the same line on four machines.
##
## Only two things add a third packet, and both are genuine host decisions a
## client cannot compute: a fork popping early because it soaked its last strike,
## and a barrier's absorbed fraction changing.

## The local player's slot changed, or their owned set did. The HUD and the
## Compiler panel both listen rather than polling.
signal equipped_changed
signal owned_changed
## A cast landed, on every peer. `peer_id` is the caster.
signal cast_landed(peer_id: int, subroutine: String)
## The host said no, or the local pre-check did. Local only; the HUD ticks.
signal cast_refused(reason: String)
## A purchase resolved / was refused, mirroring `Modules`' pair so the Compiler
## panel can treat both catalogues with one code path.
signal purchased(peer_id: int, subroutine: String, tier: int)
signal refused(subroutine: String, reason: String)

const CONFIG_PATH: String = "user://subroutines.cfg"
const SECTION: String = "kit"

## How far from their own avatar a client may claim to have cast. Same number and
## same reasoning as `Run.ORIGIN_REACH`: enough slack for a lens offset and a
## frame of movement, none for casting across the layer.
const ORIGIN_REACH: float = 3.0
## Host-side proximity gate on swapping your slot at a Compiler. Generous, like
## `Run.USE_REACH` — the job is to tell "stood at the machine" from "sent a
## packet", not to punish standing at the edge of the probe.
const SWAP_REACH: float = 6.0

## How far a SURGE STEP may be refused for, in metres of wall. Below this the
## dash is simply shortened rather than rejected: a player who dashes into a
## doorframe should slide to the frame, not lose the cast and the Cycles.
const STEP_MIN_DISTANCE: float = 0.8
## Body probe for the dash, so it stops at a wall instead of passing through one.
const STEP_PROBE_RADIUS: float = 0.34
const STEP_PROBE_HEIGHT: float = 1.5

# --- local program ------------------------------------------------------------
## subroutine id -> tier owned. Persisted.
var owned: Dictionary = {}
## The one compiled slot, or "" for an empty slot. Persisted.
var equipped: String = ""

# --- session mirror (announced, host-authoritative for decisions) -------------
## peer -> {id: tier}
var _crew_owned: Dictionary = {}
## peer -> equipped id
var _crew_equipped: Dictionary = {}

# --- cooldowns ----------------------------------------------------------------
## Host: peer -> seconds of engine time at which the next cast is allowed.
var _host_ready_at: Dictionary = {}
## Local display: seconds remaining and the full length, so the HUD can draw a
## sweep without asking anyone. Purely presentational — the host's copy decides.
var _cooldown_left: float = 0.0
var _cooldown_span: float = 0.0

# --- i-frames -----------------------------------------------------------------
## Host: peer -> engine time at which their SURGE STEP immunity ends. Read by
## `Antivirus._strike`, which is the single door every hostile hit goes through.
var _iframes_until: Dictionary = {}

# --- host-side object ids -----------------------------------------------------
var _next_decoy: int = 1
var _next_barrier: int = 1

## `--subroutine ID` forces a slot for a session without writing the file, the
## same way `--modules` forces module tiers. Instruments only.
var _forced: String = ""


func _ready() -> void:
	_load()
	# Modules is created before GameState for its migration; this one is created
	# after Net, but the roster hook still has to wait for the whole autoload list
	# to stand up before it can connect.
	_bind.call_deferred()


func _bind() -> void:
	Net.crew_changed.connect(_on_crew_changed)
	Run.run_ended.connect(func(_s: Dictionary) -> void: _reset_session())
	Run.descent_started.connect(func(_n: int) -> void: _reset_session())
	set_process(true)


func _reset_session() -> void:
	_host_ready_at.clear()
	_iframes_until.clear()
	_cooldown_left = 0.0
	_cooldown_span = 0.0


func _on_crew_changed() -> void:
	# Announce on every roster change rather than only on join: a peer that
	# arrives after us has never seen our kit, and re-announcing is one small
	# reliable packet on an event that already costs several.
	announce()


func _process(delta: float) -> void:
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(_cooldown_left - delta, 0.0)
		if _cooldown_left <= 0.0:
			# 'You may cast again' — the same grammar the breaker's cooldown
			# release uses, and just as quiet.
			Audio.play_2d(&"sub_ready")


# ------------------------------------------------------------------ catalogue --
#
# Deliberately the same shape as `Modules`' catalogue accessors, so the Compiler
# panel draws a subroutine row and a module row through one code path.

static func definition(id: String) -> Dictionary:
	return Balance.SUBROUTINES.get(id, {}) as Dictionary


static func is_subroutine(id: String) -> bool:
	return Balance.SUBROUTINES.has(id)


static func tier_count(id: String) -> int:
	var entry: Dictionary = definition(id)
	if entry.is_empty():
		return 0
	return (entry["prices"] as Array).size()


static func price(id: String, tier: int) -> int:
	var entry: Dictionary = definition(id)
	if entry.is_empty():
		return 0
	var prices: Array = entry["prices"]
	if tier < 0 or tier >= prices.size():
		return 0
	return int(prices[tier])


static func display_name(id: String) -> String:
	return String(definition(id).get("name", id.to_upper()))


static func glyph(id: String) -> String:
	return String(definition(id).get("glyph", "◆"))


static func note(id: String) -> String:
	return String(definition(id).get("note", ""))


## One effect value at one tier. Index 0 of every effect array is "not compiled",
## exactly like `Modules.value_at`.
static func value_at(id: String, key: String, tier: int) -> Variant:
	var entry: Dictionary = definition(id)
	if not entry.has(key):
		return null
	var values: Array = entry[key]
	return values[clampi(tier, 0, values.size() - 1)]


## A `{id: tier}` table from somewhere untrusted, made safe. Same discipline and
## the same hard-won reason as `Modules.sanitize_tiers`: an out-of-range integer
## was never the danger, the TYPE was — `int({})` aborts the enclosing function,
## and this table is read on the host inside a cast validation.
static func sanitize(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in raw.keys():
		if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
			continue
		var id: String = String(key)
		if not is_subroutine(id):
			continue
		var value: Variant = raw[key]
		if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
			continue
		var tier: int = clampi(int(value), 0, tier_count(id))
		if tier > 0:
			out[id] = tier
	return out


# ------------------------------------------------------------------- queries --

func tier_of(peer_id: int, id: String) -> int:
	if peer_id == Net.local_id():
		return clampi(int(owned.get(id, 0)), 0, tier_count(id))
	var table: Dictionary = _crew_owned.get(peer_id, {}) as Dictionary
	return clampi(int(table.get(id, 0)), 0, tier_count(id))


func equipped_of(peer_id: int) -> String:
	if peer_id == Net.local_id():
		return local_equipped()
	return String(_crew_equipped.get(peer_id, ""))


## What this machine has slotted. `--subroutine` wins for a session, and is never
## written back — measuring a kit is not the same as owning one.
func local_equipped() -> String:
	if not _forced.is_empty():
		return _forced
	return equipped


func local_tier() -> int:
	var id: String = local_equipped()
	return 0 if id.is_empty() else tier_of(Net.local_id(), id)


## Cycles one cast of `peer_id`'s slot costs. Zero when they have nothing slotted
## or do not own it — which is also how the HUD knows to draw an empty socket.
func cost_of(peer_id: int, id: String) -> float:
	var tier: int = tier_of(peer_id, id)
	if tier <= 0:
		return 0.0
	return float(value_at(id, "cost", tier))


func cooldown_of(peer_id: int, id: String) -> float:
	var tier: int = tier_of(peer_id, id)
	if tier <= 0:
		return 0.0
	return float(value_at(id, "cooldown", tier))


## 0..1 of the local cooldown still to run, for the HUD's sweep. 0 means ready.
func cooldown_fraction() -> float:
	if _cooldown_span <= 0.0:
		return 0.0
	return clampf(_cooldown_left / _cooldown_span, 0.0, 1.0)


func cooldown_seconds() -> float:
	return _cooldown_left


## Whether the local player could cast right now, ignoring the host's opinion.
## The HUD draws with this; nothing decides with it.
func local_ready() -> bool:
	var id: String = local_equipped()
	if id.is_empty() or tier_of(Net.local_id(), id) <= 0:
		return false
	if _cooldown_left > 0.0:
		return false
	return Run.cycles >= cost_of(Net.local_id(), id)


## Host-side. Is this peer inside a SURGE STEP's immunity window?
##
## Read by `Antivirus._strike`, which every hostile hit in the game passes
## through. Deliberately a timestamp rather than a flag: a flag has to be cleared
## by something, and the thing that would clear it is a timer that can be missed.
func invulnerable(peer_id: int) -> bool:
	var until: float = float(_iframes_until.get(peer_id, 0.0))
	return until > _now()


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# ------------------------------------------------------------------ ownership --

## Local player bought a tier / swapped a slot: tell the crew. Client -> host ->
## everyone, the same relay shape `Net.push_crew` uses, rather than a client
## broadcast: the host is the only peer allowed to publish a roster.
func announce() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_announce_request.rpc_id(1, owned, local_equipped())


@rpc("any_peer", "call_local", "reliable")
func _announce_request(raw_owned: Dictionary, raw_equipped: String) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	var clean: Dictionary = sanitize(raw_owned)
	var slot: String = raw_equipped if is_subroutine(raw_equipped) else ""
	# A slot you do not own is an empty slot. The host never has to ask this
	# question again — every later cast check reads this table.
	if not slot.is_empty() and int(clean.get(slot, 0)) <= 0:
		slot = ""
	_crew_owned[sender] = clean
	_crew_equipped[sender] = slot
	_push_kits.rpc(_crew_owned, _crew_equipped)


@rpc("authority", "call_local", "reliable")
func _push_kits(all_owned: Dictionary, all_equipped: Dictionary) -> void:
	_crew_owned = all_owned
	_crew_equipped = all_equipped
	owned_changed.emit()


## Swap the slot. Free, instant, and only meaningful at a Compiler — DESIGN.md
## makes the Compiler the place a program is rewritten, and a kit you could
## reconfigure mid-fight would make owning several subroutines strictly better
## than committing to one.
func request_equip(id: String, compiler_id: int) -> void:
	var slot: String = id if is_subroutine(id) else ""
	if not slot.is_empty() and tier_of(Net.local_id(), slot) <= 0:
		refused.emit(id, "NOT COMPILED")
		return
	if not multiplayer.has_multiplayer_peer():
		_set_equipped(slot)
		return
	_equip_request.rpc_id(1, slot, compiler_id)


@rpc("any_peer", "call_local", "reliable")
func _equip_request(id: String, compiler_id: int) -> void:
	if not multiplayer.is_server() or Run.run_over:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	if not Run.is_running(sender):
		return
	var slot: String = id if is_subroutine(id) else ""
	if not slot.is_empty():
		var table: Dictionary = _crew_owned.get(sender, {}) as Dictionary
		if int(table.get(slot, 0)) <= 0:
			_refuse(sender, id, "NOT COMPILED")
			return
	# Question 3: are they at the machine? Same shape as the purchase check.
	var terminal: CompilerTerminal = CompilerTerminal.find(get_tree(), compiler_id)
	var body: Node = Net.get_player(sender)
	if terminal == null or body == null or not is_instance_valid(body):
		_refuse(sender, id, "COMPILER OUT OF REACH")
		return
	if not (terminal.global_position.distance_to(
			(body as Node3D).global_position) <= SWAP_REACH):
		push_warning("[Subs] slot swap refused: peer %d is not at compiler %d" % [
			sender, compiler_id])
		_refuse(sender, id, "COMPILER OUT OF REACH")
		return
	_crew_equipped[sender] = slot
	_equip_applied.rpc(sender, slot)


@rpc("authority", "call_local", "reliable")
func _equip_applied(peer_id: int, id: String) -> void:
	_crew_equipped[peer_id] = id
	if peer_id == Net.local_id():
		_set_equipped(id)
	owned_changed.emit()


func _set_equipped(id: String) -> void:
	equipped = id
	_cooldown_left = 0.0
	_cooldown_span = 0.0
	_save()
	equipped_changed.emit()


# ------------------------------------------------------------------ purchasing --

## What buying the next tier of `id` would cost, and where the money comes from.
## Byte-for-byte the shape `Modules.quote` returns, so the Compiler panel can
## render either catalogue with one row builder.
func quote(peer_id: int, id: String, stock_tier: int) -> Dictionary:
	var tier: int = tier_of(peer_id, id)
	var next: int = tier + 1
	var out: Dictionary = {
		"track": id, "tier": tier, "next": next, "price": 0,
		"from_buffer": 0, "from_archive": 0, "affordable": false, "reason": "",
	}
	if not is_subroutine(id):
		out["reason"] = "NO SUCH SUBROUTINE"
		return out
	if next > tier_count(id):
		out["reason"] = "FULLY COMPILED"
		return out
	if next > stock_tier:
		out["reason"] = "TIER %d NOT STOCKED HERE" % next
		return out

	var cost: int = price(id, tier)
	out["price"] = cost
	var buffer: int = Run.buffered_value_of(peer_id)
	var archive: int = Modules.archive_of(peer_id)
	var from_buffer: int = mini(buffer, cost)
	out["from_buffer"] = from_buffer
	out["from_archive"] = cost - from_buffer
	if cost - from_buffer > archive:
		out["reason"] = "INSUFFICIENT DATA"
		return out
	out["affordable"] = true
	return out


func request_purchase(id: String, compiler_id: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		refused.emit(id, "NO SESSION")
		return
	_purchase_request.rpc_id(1, id, compiler_id)


@rpc("any_peer", "call_local", "reliable")
func _purchase_request(id: String, compiler_id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	if Run.run_over:
		_refuse(sender, id, "RUN OVER")
		return
	if not Run.is_running(sender):
		_refuse(sender, id, "PROCESS NOT RUNNING")
		return

	var terminal: CompilerTerminal = CompilerTerminal.find(get_tree(), compiler_id)
	var body: Node = Net.get_player(sender)
	if terminal == null or body == null or not is_instance_valid(body):
		_refuse(sender, id, "COMPILER OUT OF REACH")
		return
	if not (terminal.global_position.distance_to(
			(body as Node3D).global_position) <= CompilerTerminal.USE_RANGE):
		push_warning("[Subs] purchase refused: peer %d is not at compiler %d" % [
			sender, compiler_id])
		_refuse(sender, id, "COMPILER OUT OF REACH")
		return

	var deal: Dictionary = quote(sender, id, terminal.stock_tier)
	if not bool(deal["affordable"]):
		_refuse(sender, id, String(deal["reason"]))
		return

	# Host-side commit, against numbers the host owns for the session: the buffer
	# is `Run`'s and the archive is the roster mirror `Modules` spends from. Both
	# doors are the same ones a module purchase uses; nothing new is trusted.
	var from_buffer: int = int(deal["from_buffer"])
	var from_archive: int = int(deal["from_archive"])
	Run.spend_buffer(sender, from_buffer)
	var entry: Dictionary = Net.crew.get(sender, {}) as Dictionary
	entry["archive"] = maxi(int(entry.get("archive", 0)) - from_archive, 0)
	Net.crew[sender] = entry

	var table: Dictionary = (_crew_owned.get(sender, {}) as Dictionary).duplicate()
	table[id] = int(deal["next"])
	_crew_owned[sender] = table
	# First subroutine you compile goes straight into the empty slot. Making a
	# player walk back to the same terminal to equip the thing they just bought
	# from it is a step that teaches nothing.
	if String(_crew_equipped.get(sender, "")).is_empty():
		_crew_equipped[sender] = id
	print("[Subs] %s compiled %s tier %d for %d (%d buffered + %d archive)" % [
		Net.crew_name(sender), id.to_upper(), int(deal["next"]),
		int(deal["price"]), from_buffer, from_archive])

	Net.push_crew()
	_purchase_applied.rpc(sender, id, int(deal["next"]), from_archive,
			String(_crew_equipped[sender]))


@rpc("authority", "call_local", "reliable")
func _purchase_applied(peer_id: int, id: String, tier: int, from_archive: int,
		slot: String) -> void:
	var table: Dictionary = (_crew_owned.get(peer_id, {}) as Dictionary).duplicate()
	table[id] = tier
	_crew_owned[peer_id] = table
	_crew_equipped[peer_id] = slot
	if peer_id == Net.local_id():
		owned[id] = tier
		equipped = slot
		# The archive half of the price, debited against the same file the host's
		# session mirror was made from. `Modules.compile_module` does exactly this
		# for a module; a subroutine tier lives in our own file, so only the money
		# is written through GameState.
		if from_archive > 0:
			GameState.archive = maxi(GameState.archive - from_archive, 0)
			GameState.save_progress()
		_save()
		equipped_changed.emit()
	owned_changed.emit()
	purchased.emit(peer_id, id, tier)


func _refuse(peer_id: int, id: String, reason: String) -> void:
	# The host is its own client, and an `rpc_id` at yourself on a `call_remote`
	# method is an engine error rather than a delivered packet — so a listen host
	# refusing its own purchase takes the local path. Same fix, same reason, as
	# `Modules._refuse`.
	if peer_id == multiplayer.get_unique_id():
		_purchase_refused(id, reason)
		return
	_purchase_refused.rpc_id(peer_id, id, reason)


@rpc("authority", "call_remote", "reliable")
func _purchase_refused(id: String, reason: String) -> void:
	print("[Subs] refused: %s — %s" % [id.to_upper(), reason])
	refused.emit(id, reason)


# ---------------------------------------------------------------------- casting --

## Q. Called by `Player` on the local peer.
##
## The local pre-check is presentation, not authority: it decides whether the HUD
## ticks a refusal and whether we spend a packet, and the host re-checks every one
## of the same questions before anything happens. A client that skips it gains
## nothing except a refused packet.
func request_cast(origin: Vector3, direction: Vector3) -> void:
	var id: String = local_equipped()
	if id.is_empty():
		cast_refused.emit("NO SUBROUTINE COMPILED")
		return
	if tier_of(Net.local_id(), id) <= 0:
		cast_refused.emit("NOT COMPILED")
		return
	if _cooldown_left > 0.0:
		cast_refused.emit("RECOMPILING  ·  %.1fs" % _cooldown_left)
		Audio.play_2d(&"sub_refused")
		return
	if Run.cycles < cost_of(Net.local_id(), id):
		cast_refused.emit("INSUFFICIENT CYCLES")
		Audio.play_2d(&"sub_refused")
		return
	if not multiplayer.has_multiplayer_peer():
		return
	if not origin.is_finite() or not direction.is_finite():
		return
	# Start the local sweep on the frame the key went down rather than a round
	# trip later. If the host refuses, `_cast_denied` clears it — a cooldown that
	# only starts when the packet comes back reads as input lag on the one
	# interaction that is supposed to feel instant.
	_cooldown_span = cooldown_of(Net.local_id(), id)
	_cooldown_left = _cooldown_span
	_cast_request.rpc_id(1, id, origin, direction)


@rpc("any_peer", "call_local", "reliable")
func _cast_request(id: String, origin: Vector3, direction: Vector3) -> void:
	if not multiplayer.is_server() or Run.run_over or Run.descending:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	if not Run.is_running(sender):
		return
	# Every vector off the wire is finiteness-tested before it is used for
	# anything. A NaN is not a large number; it is a value that compares false
	# against everything, which is how it walks through guards.
	if not origin.is_finite() or not direction.is_finite():
		push_warning("[Subs] cast refused: peer %d sent a non-finite cast" % sender)
		return
	if direction.length_squared() <= 0.000001:
		return
	if not is_subroutine(id):
		return
	# The slot and the ownership are read from the HOST's announced table, never
	# from the packet. A client cannot cast something it did not announce.
	if String(_crew_equipped.get(sender, "")) != id:
		_deny(sender, "SUBROUTINE NOT SLOTTED")
		return
	var tier: int = clampi(int((_crew_owned.get(sender, {}) as Dictionary).get(id, 0)),
			0, tier_count(id))
	if tier <= 0:
		_deny(sender, "NOT COMPILED")
		return
	var now: float = _now()
	if now < float(_host_ready_at.get(sender, 0.0)):
		_deny(sender, "RECOMPILING")
		return

	var body: Node3D = Net.get_player(sender) as Node3D
	if body == null or not is_instance_valid(body) or not body.global_position.is_finite():
		return
	if not (body.global_position.distance_to(origin) <= ORIGIN_REACH):
		push_warning("[Subs] cast refused: peer %d cast from %s" % [sender, str(origin)])
		return

	var cost: float = float(value_at(id, "cost", tier))
	if Run.cycles < cost:
		_deny(sender, "INSUFFICIENT CYCLES")
		return

	# Power costs breath. The pool is host-owned and this is the debit; the 5 Hz
	# pool stream carries it out with everything else, and the echo below lands on
	# the same beat so the gauge and the effect agree.
	Run.cycles = maxf(Run.cycles - cost, 0.0)
	Run.cycles_changed.emit(Run.cycles)
	_host_ready_at[sender] = now + float(value_at(id, "cooldown", tier))

	var serial: int = 0
	match id:
		"surge_step":
			_host_surge_step(sender, tier, body)
		"stack_pulse":
			_host_stack_pulse(sender, tier, body)
		"fork_decoy":
			serial = _next_decoy
			_next_decoy += 1
		"checksum_barrier":
			serial = _next_barrier
			_next_barrier += 1
			_host_barrier_notice()

	if Debug.log_ai:
		print("[Subs] %s ran %s t%d for %.0f cycles (pool %.0f)" % [
			Net.crew_name(sender), id.to_upper(), tier, cost, Run.cycles])
	_cast_applied.rpc(sender, id, tier, body.global_position, direction.normalized(),
			serial)


func _deny(peer_id: int, reason: String) -> void:
	if peer_id == multiplayer.get_unique_id():
		_cast_denied(reason)
		return
	_cast_denied.rpc_id(peer_id, reason)


@rpc("authority", "call_remote", "reliable")
func _cast_denied(reason: String) -> void:
	# Give the sweep back. The client started it optimistically for feel; a
	# refusal must not leave the slot dark for a cooldown that never ran.
	_cooldown_left = 0.0
	_cooldown_span = 0.0
	cast_refused.emit(reason)
	Audio.play_2d(&"sub_refused")


# ------------------------------------------------------------ host-side effects --

## SURGE STEP is the one subroutine whose *motion* is client-authoritative, for
## the same reason all movement is (DESIGN.md, "responsiveness first"): the
## avatar slides on the caster's own machine the frame the key goes down. What the
## host owns is everything with a consequence — the Cycles, the cooldown and the
## i-frames — and it grants the immunity window here, against its own clock.
func _host_surge_step(peer_id: int, tier: int, _body: Node3D) -> void:
	_iframes_until[peer_id] = _now() + float(value_at("surge_step", "iframes", tier))


## STACK PULSE, resolved where it matters: on the host, against the host's own
## copy of every process in the room.
##
## CONTROL, NOT DAMAGE. It calls `Antivirus.stagger`, which cancels a committed
## lunge, holds the creature out of its state machine for a beat and shoves the
## light ones back. It does not call `take_damage` and it never will — the
## killability law says every monster dies to the breaker, and its converse is
## that nothing else quietly starts killing them.
##
## And it is LOUD. A full two-room `NoiseBus` ping, the same reach as a drained
## siphon, held for the same time: the crew's panic button rings a bell, and the
## Hound hears every single one.
func _host_stack_pulse(peer_id: int, tier: int, body: Node3D) -> void:
	var radius: float = float(value_at("stack_pulse", "radius", tier))
	var hold: float = float(value_at("stack_pulse", "stagger", tier))
	var shove: float = float(value_at("stack_pulse", "knockback", tier))
	var centre: Vector3 = body.global_position
	var caught: int = 0
	for node: Node in get_tree().get_nodes_in_group(Antivirus.GROUP):
		var creature: Antivirus = node as Antivirus
		if creature == null or not is_instance_valid(creature):
			continue
		if creature.global_position.distance_to(centre) > radius:
			continue
		creature.stagger(hold, centre, shove)
		caught += 1
	NoiseBus.ping(centre, Balance.NOISE_ROOMS_JUNCTION, "stack_pulse",
			Balance.NOISE_TIME_JUNCTION)
	if Debug.log_ai:
		print("[Subs] stack pulse by %d staggered %d process(es) in %.1f m" % [
			peer_id, caught, radius])


## MOTHER notices a barrier. A program asserting its own integrity inside hers is
## exactly the sort of thing the Director should look up at, so a cast pins its
## combat stress the way a landed hit does. Host-only; the Director is a host
## brain and every peer computes its own perceived stress from the same
## replicated facts.
func _host_barrier_notice() -> void:
	if Haunt != null:
		Haunt.notice_assertion()


# ----------------------------------------------------------------------- echo --

## The one packet every peer builds the whole cast from. Fx, forks and shells are
## all deterministic functions of it, so four machines draw the same thing without
## a byte more traffic.
@rpc("authority", "call_local", "reliable")
func _cast_applied(peer_id: int, id: String, tier: int, origin: Vector3,
		direction: Vector3, serial: int) -> void:
	if peer_id == Net.local_id():
		# Re-arm the local sweep off the AUTHORITATIVE cooldown. The optimistic
		# one started with the client's own tier, which is the same number — but
		# only because the host agreed, and that is the copy to trust.
		_cooldown_span = float(value_at(id, "cooldown", tier))
		_cooldown_left = _cooldown_span
	var tint: Color = Net.crew_color(peer_id)
	match id:
		"surge_step": _play_surge_step(peer_id, tier, origin, direction, tint)
		"stack_pulse": _play_stack_pulse(peer_id, tier, origin, tint)
		"fork_decoy": _play_fork_decoy(peer_id, tier, origin, direction, tint, serial)
		"checksum_barrier": _play_barrier(peer_id, tier, origin, tint, serial)
	cast_landed.emit(peer_id, id)


func _play_surge_step(peer_id: int, tier: int, origin: Vector3, direction: Vector3,
		tint: Color) -> void:
	var body: Node = Net.get_player(peer_id)
	var player: Player = body as Player
	var distance: float = float(value_at("surge_step", "distance", tier))
	var planar: Vector3 = Vector3(direction.x, 0.0, direction.z)
	if planar.length_squared() < 0.0001:
		planar = Vector3.FORWARD
	planar = planar.normalized()
	var target: Vector3 = origin + planar * distance
	if player != null and is_instance_valid(player):
		# The caster's own machine does the sliding; every other peer only draws
		# the wake and lets the pose stream carry the motion, which it already
		# does at 20 Hz and which is exactly what a dash looks like anyway.
		if peer_id == Net.local_id():
			target = player.surge_step(planar, distance,
					float(value_at("surge_step", "iframes", tier)))
		else:
			target = player.global_position + planar * distance
	var trail: SurgeTrail = SurgeTrail.create(origin, target,
			atan2(-planar.x, -planar.z), tint)
	_dynamic().add_child(trail)
	# A bass whump at the origin, not at the destination: the sound is the process
	# leaving, and a player who dashed away from something should hear the noise
	# behind them.
	Audio.play_3d(&"sub_step", origin)
	if peer_id == Net.local_id():
		Fx.shake(Balance.SUB_SHAKE_STEP)


func _play_stack_pulse(peer_id: int, tier: int, origin: Vector3, tint: Color) -> void:
	var radius: float = float(value_at("stack_pulse", "radius", tier))
	Fx.pulse_ring(origin, radius, tint, 0.42)
	# The flare, gated. This is the only wide-area luminance the kit produces, so
	# it is the one that goes through the governor: at most one full bloom per
	# `Balance.SUB_FLASH_MIN_INTERVAL`, and A11y.flash_scale on top. A gated pulse
	# still rings, still shoves and still draws its ring — only the bloom is held.
	Fx.bloom(origin + Vector3.UP * 1.0, tint,
			Balance.SUB_FLASH_ENERGY * Fx.flash_gate() * A11y.flash_scale, radius * 2.2)
	Audio.play_3d(&"sub_pulse", origin)
	if peer_id == Net.local_id():
		Fx.shake(Balance.SUB_SHAKE_PULSE)


func _play_fork_decoy(peer_id: int, tier: int, origin: Vector3, direction: Vector3,
		tint: Color, serial: int) -> void:
	var planar: Vector3 = Vector3(direction.x, 0.0, direction.z)
	if planar.length_squared() < 0.0001:
		planar = Vector3.FORWARD
	var decoy: ForkDecoy = ForkDecoy.create(serial, peer_id, tier, origin,
			planar.normalized(), tint,
			float(value_at("fork_decoy", "lifetime", tier)),
			float(value_at("fork_decoy", "walk", tier)),
			float(value_at("fork_decoy", "lure", tier)),
			int(value_at("fork_decoy", "hits", tier)))
	_dynamic().add_child(decoy)
	Audio.play_3d(&"sub_fork", origin)
	if peer_id == Net.local_id():
		Fx.shake(Balance.SUB_SHAKE_DECOY)


func _play_barrier(peer_id: int, tier: int, origin: Vector3, tint: Color,
		serial: int) -> void:
	var barrier: ChecksumBarrier = ChecksumBarrier.create(serial, peer_id, origin, tint,
			float(value_at("checksum_barrier", "radius", tier)),
			float(value_at("checksum_barrier", "duration", tier)),
			float(value_at("checksum_barrier", "absorb", tier)))
	_dynamic().add_child(barrier)
	Audio.play_3d(&"sub_barrier", origin)
	if peer_id == Net.local_id():
		Fx.shake(Balance.SUB_SHAKE_BARRIER)


## Where the kit's world objects are parented. The layer's own `Dynamic` node, so
## a descent frees a live fork and a live shell with everything else — the same
## home flares and dropped bundles use, and the same reason.
func _dynamic() -> Node:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null:
		return self
	var dynamic: Node = layer.get_node_or_null("Dynamic")
	return dynamic if dynamic != null else layer


# ------------------------------------------------------- host -> peer events --

## Host-side. A process struck `decoy`; if that finished it, tell everyone so the
## fork decompiles on the same beat on four screens instead of four timers.
func report_decoy_strike(decoy: ForkDecoy) -> void:
	if not multiplayer.is_server() or decoy == null or not is_instance_valid(decoy):
		return
	if decoy.absorb():
		_decoy_popped.rpc(decoy.decoy_id)


@rpc("authority", "call_local", "reliable")
func _decoy_popped(id: int) -> void:
	for node: Node in get_tree().get_nodes_in_group(ForkDecoy.GROUP):
		var decoy: ForkDecoy = node as ForkDecoy
		if decoy != null and is_instance_valid(decoy) and decoy.decoy_id == id:
			decoy.decompile()
			return


## Host-side. A shell ate `eaten` of a hit. Broadcast as a FRACTION rather than an
## absolute, so a client that missed a packet still draws the right integrity
## band; `broke` collapses it everywhere on the same frame.
func report_barrier_absorb(barrier: ChecksumBarrier) -> void:
	if not multiplayer.is_server() or barrier == null or not is_instance_valid(barrier):
		return
	var fraction: float = clampf(barrier.absorbed / maxf(barrier.capacity, 0.001),
			0.0, 1.0)
	_barrier_hit.rpc(barrier.barrier_id, fraction, fraction >= 1.0)


@rpc("authority", "call_local", "reliable")
func _barrier_hit(id: int, fraction: float, broke: bool) -> void:
	for node: Node in get_tree().get_nodes_in_group(ChecksumBarrier.GROUP):
		var barrier: ChecksumBarrier = node as ChecksumBarrier
		if barrier == null or not is_instance_valid(barrier) or barrier.barrier_id != id:
			continue
		barrier.ripple(fraction)
		if broke:
			barrier.collapse()
		return


# ---------------------------------------------------------------- persistence --
#
# Its own file, for the reason `A11y` keeps its own: state that is not the program
# file must survive a corrupt program file. The archive and the module tiers are
# in save.json and are `GameState`'s business; which subroutine you have slotted
# is not, and losing one must never cost you the other.

func _load() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	owned = sanitize(cfg.get_value(SECTION, "owned", {}) as Dictionary)
	var slot: String = String(cfg.get_value(SECTION, "equipped", ""))
	equipped = slot if (is_subroutine(slot) and int(owned.get(slot, 0)) > 0) else ""


## Same temp-then-rename discipline `GameState.save_progress` and `A11y._save`
## use: `ConfigFile.save` writes in one call, but a crash mid-write can still
## truncate, and the swap is atomic on every filesystem we target.
func _save() -> void:
	if GameState.sandboxed:
		return
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value(SECTION, "owned", owned)
	cfg.set_value(SECTION, "equipped", equipped)
	var temp: String = CONFIG_PATH + ".tmp"
	if cfg.save(temp) == OK:
		DirAccess.rename_absolute(ProjectSettings.globalize_path(temp),
				ProjectSettings.globalize_path(CONFIG_PATH))
	else:
		cfg.save(CONFIG_PATH)


# ------------------------------------------------------------------ dev tools --

## `--subroutine ID[:TIER]`. A slot without the run that earned it, for measuring
## and for captures. Never written to the file — the same rule `--modules` keeps.
func force(spec: String) -> void:
	var parts: PackedStringArray = spec.strip_edges().split(":")
	var id: String = parts[0].strip_edges().to_lower()
	if not is_subroutine(id):
		push_warning("[Subs] --subroutine: no subroutine '%s'" % id)
		return
	var tier: int = tier_count(id)
	if parts.size() > 1:
		tier = clampi(parts[1].to_int(), 1, tier_count(id))
	owned[id] = tier
	_forced = id
	print("[Subs] forced slot: %s tier %d" % [id.to_upper(), tier])
	equipped_changed.emit()
	owned_changed.emit()


## Compact one-line rendering of a kit, for logs and the self-test.
static func describe(table: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for id: String in Balance.SUBROUTINE_TRACKS:
		var tier: int = int(table.get(id, 0))
		if tier > 0:
			parts.append("%s:%d" % [id, tier])
	return "none" if parts.is_empty() else ",".join(parts)
