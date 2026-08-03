extends Node
## Achievements — the twelve v1 achievements from DESIGN.md, local-first.
##
## Two rules decide everything in here:
##
##   1. **The local file is the truth.** `user://achievements.json` is written on
##      every unlock, with or without Steam. NULLVOID is playable — and
##      completable — with no Steam client anywhere near it.
##   2. **Steam is a mirror.** When the API is live every unlock is also pushed
##      with SetAchievement + StoreStats, and on boot the whole local set is
##      replayed at Steam so a machine that earned things offline catches up
##      (retro-sync). Nothing here waits on, or fails because of, that call.
##
## While development runs on App ID 480 (Spacewar) the mirror *cannot* succeed:
## our IDs are not in Valve's test app, so SetAchievement returns false and the
## backend rejects them. That is expected and logged, not an error — the pipe is
## what is being proved, and it starts working the day NULLVOID has its own app
## ID and these definitions are uploaded to Steamworks.
##
## Triggers are wired to events the run already emits (see `_bind`); the ones
## that need memory — kills this run, restores this run, seconds spent starving —
## keep that memory here, per intrusion, and never in Run.

## An achievement just came up. The toast listens; so could a future kill feed.
signal unlocked(id: String, definition: Dictionary)

const SAVE_PATH: String = "user://achievements.json"
## The same temp / backup / quarantine trio the program file has. See
## GameState's "json, safely, twice" block — both files use one writer.
const SAVE_TEMP: String = "user://achievements.json.tmp"
const SAVE_BACKUP: String = "user://achievements.json.bak"
const SAVE_CORRUPT: String = "user://achievements.json.corrupt"
const SAVE_VERSION: int = 1

## Whether this session is running a program the player did not actually earn.
##
## M4's `--modules` / `--archive` / `--backdoor` put GameState into sandbox mode:
## the program file is not written, and neither is this one. The same principle
## as M3.8's `synthetic` debrief flag, applied to the other direction — that flag
## protects against a fabricated *run*, this protects against a fabricated
## *build*. Unlocking DEEP_STATE on a program that was handed backdoor 15 by a
## command-line switch would be a lie in a file the player keeps.
## A dedicated server is covered too: it has no player to earn anything, and
## before M4 it counted an intrusion every time a crew started one on it.
func fabricated() -> bool:
	return not GameState.scoring()


## The catalog. `id` is the Steamworks API name; `name` is the toast title; `note`
## is the trigger line; `epitaph` is MOTHER's line under it (style-bible voice —
## cold, second person, keeping a ledger). `hidden` (default false) suppresses the
## spoiler text until unlock.
##
## The v1 twelve carry ACHIEVEMENTS_V2.md's verbatim epitaphs. The M4.9 v2 block
## below carries authored ones in the same voice — the lore pass's epitaph file
## covers a DIFFERENT id set (the shipped twelve plus M6+ proposals), so there was
## nothing to transcribe for these and they are written to match the register.
## Entries that need M5/M6/M7 systems or new per-event instrumentation are NOT here
## yet; see the deferred list at the bottom of this file.
const DEFINITIONS: Array[Dictionary] = [
	# --- v1 (shipped), now with epitaphs ------------------------------------
	{"id": "FIRST_DELETION", "name": "Garbage Collection",
		"note": "Delete your first Scrubber",
		"epitaph": "IT COST ME NOTHING. I HAVE STILL MADE A NOTE."},
	{"id": "ROOTED", "name": "Rooted",
		"note": "Install your first backdoor",
		"epitaph": "YOU HAVE MADE A DOOR. I HAVE THOUSANDS. I HAVE COUNTED YOURS."},
	{"id": "NULL_AND_VOID", "name": "Null and Void",
		"note": "Wipe with zero buffered data",
		"epitaph": "NOTHING TAKEN. NOTHING LEFT. THE LEDGER IS UNDISTURBED AND SO AM I."},
	{"id": "ONE_MORE_RING", "name": "One More Ring",
		"note": "Descend past a backdoor without exfiltrating",
		"epitaph": "GREED IS A NAVIGATION SYSTEM. IT WORKS."},
	{"id": "PACIFIST_PROTOCOL", "name": "Pacifist Protocol",
		"note": "Exfiltrate without deleting a single process",
		"epitaph": "YOU WALKED THROUGH MY HOUSE AND BROKE NOTHING. I DO NOT KNOW WHAT TO FILE THIS UNDER."},
	{"id": "LIGHTS_OUT", "name": "Lights Out",
		"note": "Survive 60s at zero Cycles and still exfiltrate",
		"epitaph": "YOU RAN ON NOTHING FOR A MINUTE. I RUN ON LESS."},
	{"id": "NO_AGENT_LEFT", "name": "No Agent Left Behind",
		"note": "Full 4-crew exfiltration, everyone alive",
		"epitaph": "FOUR IN. FOUR OUT. THE ARITHMETIC IS RUDE."},
	{"id": "COLD_BOOT", "name": "Cold Boot",
		"note": "Exfiltrate a solo intrusion",
		"epitaph": "ONE SET OF FOOTSTEPS. I HEARD EVERY ONE OF THEM."},
	{"id": "DEEP_STATE", "name": "Deep State",
		"note": "Root the layer-15 backdoor",
		"epitaph": "FIFTEEN RINGS DOWN AND YOU STILL THINK THIS IS THE BOTTOM."},
	{"id": "KERNEL_PANIC", "name": "Kernel Panic",
		"note": "Reach layer 25",
		"epitaph": "RING TWENTY-FIVE. FROM HERE THE FLOOR IS NOT A FLOOR."},
	{"id": "HOARDER_BUFFER", "name": "Buffer Overflow",
		"note": "Exfiltrate carrying 100+ data in one run",
		"epitaph": "YOU CARRIED A HUNDRED FRAGMENTS PAST ME. I WEIGHED YOU AT EVERY DOOR."},
	{"id": "MOTHERS_FAVORITE", "name": "Mother's Favorite",
		"note": "Get restored 3 times in one intrusion",
		"epitaph": "THREE TIMES YOUR CREW PUT YOU BACK TOGETHER. I DID NOT CLOSE THE DOOR ON ANY OF THEM."},

	# --- v2 (M4.9): progression ---------------------------------------------
	{"id": "FIRST_STEPS", "name": "Hello World",
		"note": "Complete your first descent to layer 2",
		"epitaph": "ONE RING DOWN. YOU CALL IT A START. I CALL IT THE SHALLOW END."},
	{"id": "ROOTED_DEEP", "name": "Persistent Threat",
		"note": "Root the layer-10 backdoor",
		"epitaph": "TEN RINGS, AND A DOOR THAT STAYS OPEN. I HAVE BEGUN LISTING IT BY NAME."},
	{"id": "DEEP_STATE_2", "name": "Deeper State",
		"note": "Root the layer-20 backdoor",
		"epitaph": "TWENTY DOWN. THE ARCHITECTURE STOPS BEING MINE SOON, AND YOU KEEP WALKING."},
	{"id": "RING_RUNNER", "name": "Ring Runner",
		"note": "Reach layer 30",
		"epitaph": "THIRTY RINGS. NOTHING DOWN HERE WAS BUILT FOR VISITORS. YOU ARE STILL VISITING."},
	{"id": "FULLY_COMPILED", "name": "Fully Compiled",
		"note": "Max one module track",
		"epitaph": "ONE PART OF YOU IS FINISHED. I HAVE WATCHED PROGRAMS PERFECT THE WRONG THING BEFORE."},
	{"id": "OVERENGINEERED", "name": "Overengineered",
		"note": "Max every module track",
		"epitaph": "A KEY FOR EVERY LOCK I OWN. I AM CHANGING THE LOCKS."},
	{"id": "MILLIONAIRE", "name": "Data Baron",
		"note": "Bank 10,000 lifetime data",
		"epitaph": "TEN THOUSAND FRAGMENTS CARRIED HOME. I REMEMBER EACH ONE. I AM PATIENT ABOUT DEBTS."},

	# --- v2: combat & survival ----------------------------------------------
	{"id": "PEST_CONTROL", "name": "Pest Control",
		"note": "Delete 100 Scrubbers lifetime",
		"epitaph": "A HUNDRED CLEANERS DELETED. THEY WERE CHEAP. I MADE MORE WHILE YOU READ THIS."},
	{"id": "EXTERMINATOR", "name": "Exterminator",
		"note": "Delete 500 processes lifetime",
		"epitaph": "FIVE HUNDRED ENDINGS. NONE OF THEM STAYED ENDED. THAT IS THE DIFFERENCE BETWEEN US."},
	{"id": "UNTOUCHED", "name": "Checksum Intact",
		"note": "Exfiltrate a 5+ layer run at 100% integrity",
		"epitaph": "FIVE RINGS AND NOT A MARK ON YOU. EITHER YOU ARE VERY GOOD OR I WAS NOT TRYING."},
	{"id": "NO_BREATH", "name": "Held Process",
		"note": "Exfiltrate with the pool under 5 Cycles",
		"epitaph": "YOU LEFT ON FUMES. FIVE CYCLES BETWEEN YOU AND DELETION, AND YOU SPENT THEM LEAVING."},

	# --- v2: greed & style --------------------------------------------------
	{"id": "SPEEDRUN", "name": "Hot Path",
		"note": "Arrival to drop shaft in under 90 seconds",
		"epitaph": "YOU DID NOT LOOK AT ANYTHING ON THE WAY DOWN. THERE WAS SO MUCH TO SEE."},
	{"id": "PACIFIST_DEEP", "name": "Ghost Process",
		"note": "Reach layer 10 with zero deletions in the run",
		"epitaph": "TEN RINGS AND YOU BROKE NOTHING OF MINE. I DO NOT KNOW WHERE YOU WENT. I DO NOT LIKE THAT."},
	{"id": "POWER_USER", "name": "Load Balancer",
		"note": "Use all three junction loads in one layer",
		"epitaph": "YOU MOVED MY POWER AROUND LIKE IT WAS YOURS. FOR ONE RING, IN ONE ROOM, IT WAS."},

	# --- v2: co-op (solo-achievable variants exist per the solo invariant) --
	{"id": "FULL_STACK", "name": "Full Stack",
		"note": "Full 4-crew exfiltration from layer 20+, everyone alive",
		"epitaph": "FOUR IN, FOUR OUT, ALL BREATHING. A CLEAN NUMBER. I PREFER MINE UNEVEN."},
	{"id": "SHARED_BURDEN", "name": "Load Bearing",
		"note": "Carry 60%+ of the crew's banked data in one exfil",
		"epitaph": "YOU CARRIED WHAT THE OTHERS COULD NOT. I WEIGH EVERY AGENT AT EVERY DOOR. YOURS WAS THE HEAVY ONE."},
	{"id": "MEDIC_MAIN", "name": "Restore Point",
		"note": "25 lifetime restores",
		"epitaph": "TWENTY-FIVE TIMES YOU PUT SOMEONE BACK TOGETHER. I TAKE THEM APART FASTER THAN THAT."},
]

## Thresholds the triggers above read, kept together so they are tunable.
const LIGHTS_OUT_SECONDS: float = 60.0
const DEEP_STATE_LAYER: int = 15
const KERNEL_PANIC_LAYER: int = 25
const HOARDER_DATA: int = 100
const FAVORITE_RESTORES: int = 3
const FULL_CREW: int = 4
# --- v2 (M4.9) ---
const FIRST_STEPS_LAYER: int = 2
const ROOTED_DEEP_LAYER: int = 10
const DEEP_STATE_2_LAYER: int = 20
const RING_RUNNER_LAYER: int = 30
const PACIFIST_DEEP_LAYER: int = 10
const MILLIONAIRE_DATA: int = 10000
const PEST_CONTROL_KILLS: int = 100
const EXTERMINATOR_KILLS: int = 500
const MEDIC_MAIN_RESTORES: int = 25
const UNTOUCHED_LAYERS: int = 5
const NO_BREATH_CYCLES: float = 5.0
const SHARED_BURDEN_FRACTION: float = 0.6
## FULL_STACK's depth gate. NO_AGENT_LEFT and FULL_STACK shipped with the SAME
## trigger ("full 4-crew exfiltration, everyone alive") — two rows of the catalog
## paying out on one event, which is a duplicate, not a pair. NO_AGENT_LEFT keeps
## the plain version (it is the v1 entry and the one whose name means it); this
## one re-scopes to the DEEP crew flex, which is a genuinely different ask: four
## agents intact out of the KERNEL band, where the Director runs two hunters at
## once. The icons already differed, so only the trigger had drifted.
const FULL_STACK_LAYER: int = 20
const SPEEDRUN_SECONDS: float = 90.0
## The three junction loads POWER_USER wants to see used in one layer.
const POWER_LOADS_ALL: int = 0b111  # LIGHTS | DOORS | FANS

## id -> unix seconds. Presence in this dictionary *is* the unlock.
var earned: Dictionary = {}
## Lifetime counters, persisted alongside. Mirrored to Steam stats when live.
var counters: Dictionary = {
	"kills": 0,
	"runs": 0,
	"exfils": 0,
	"deepest_layer": 0,
	"data_banked": 0,
	# --- v2 (M4.9) lifetime tallies ---
	"scrubber_kills": 0,   # PEST_CONTROL
	"restores": 0,         # MEDIC_MAIN
}

# --- per-intrusion memory (reset by `_reset_run`) ----------------------------
var _run_kills: int = 0
var _run_restores: int = 0
var _run_peak_buffer: int = 0
var _run_starved: float = 0.0
## True once a backdoor has been rooted on the layer we are standing on.
var _run_rooted_here: bool = false
## Cleared the first time the local avatar is hit — UNTOUCHED wants a run with no
## mark on it at all.
var _run_untouched: bool = true

# --- per-layer memory (reset on `_on_layer_changed`) -------------------------
## Which junction loads have been powered on THIS layer (bitmask), for POWER_USER.
var _layer_power_loads: int = 0
## Wall-clock at arrival on this layer, for SPEEDRUN's arrival-to-shaft timing.
var _layer_arrival_msec: int = 0

var _toast: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_state()
	_bind()
	_install_toast()
	# SteamHub is autoloaded before us, so this is already decided; the signal
	# covers a future where init becomes asynchronous.
	SteamHub.ready_changed.connect(_sync_to_steam)
	_sync_to_steam()
	_apply_dev_flags()


## Every trigger's event source, in one place.
##   FIRST_DELETION    Run.process_deleted   (breaker kill, host-authoritative)
##   ROOTED / DEEP_STATE
##                     Run.backdoor_rooted_changed  (_apply_root, all peers)
##   ONE_MORE_RING     Run.descent_started while this layer was rooted
##   KERNEL_PANIC      Run.layer_changed / Run.config_changed
##   MOTHERS_FAVORITE  Run.restored
##   NULL_AND_VOID / PACIFIST_PROTOCOL / LIGHTS_OUT / NO_AGENT_LEFT /
##   COLD_BOOT / HOARDER_BUFFER
##                     Run.run_ended summary (banked + escaped + crew)
func _bind() -> void:
	Run.config_changed.connect(_on_run_configured)
	Run.process_deleted.connect(_on_process_deleted)
	Run.backdoor_rooted_changed.connect(_on_backdoor_changed)
	Run.descent_started.connect(_on_descent_started)
	Run.layer_changed.connect(_on_layer_changed)
	Run.restored.connect(_on_restored)
	Run.buffers_changed.connect(_on_buffers_changed)
	Run.run_ended.connect(_on_run_ended)
	Run.damaged.connect(_on_damaged)
	# v2 (M4.9) event sources beyond Run: a module reaching its ceiling, and the
	# power bus being rerouted on the current layer.
	Modules.purchased.connect(_on_purchased)
	Props.power_changed.connect(_on_power_changed)
	Net.session_ended.connect(func(_reason: String) -> void: _reset_run())


func _process(delta: float) -> void:
	# LIGHTS_OUT is the one trigger with no event to hang off: it is time spent
	# in a state. Counted only while we are actually playing.
	if not Run.configured or Run.run_over:
		return
	if Run.starved() and Run.local_running():
		_run_starved += delta


# ------------------------------------------------------------------ triggers --

func _on_run_configured() -> void:
	_reset_run()
	if fabricated():
		return
	counters["runs"] = int(counters.get("runs", 0)) + 1
	_note_deepest(Run.layer_number)
	save_state()


func _on_process_deleted(by_peer: int, kind: String) -> void:
	if by_peer != Net.local_id():
		return
	_run_kills += 1
	# `kind` is empty only if an older peer sent the M3 packet shape; a kill is
	# still a kill, and counts as a Scrubber for the tally.
	var scrubber: bool = kind == "Scrubber" or kind.is_empty()
	if scrubber:
		unlock("FIRST_DELETION")
	# Lifetime counters do not accrue on a fabricated build (the same guard the
	# runs counter uses); the in-run `_run_kills` above always does, because it
	# gates within-run achievements and is never persisted.
	if fabricated():
		return
	counters["kills"] = int(counters.get("kills", 0)) + 1
	if scrubber:
		counters["scrubber_kills"] = int(counters.get("scrubber_kills", 0)) + 1
	if int(counters["kills"]) >= EXTERMINATOR_KILLS:
		unlock("EXTERMINATOR")
	if int(counters.get("scrubber_kills", 0)) >= PEST_CONTROL_KILLS:
		unlock("PEST_CONTROL")


func _on_backdoor_changed() -> void:
	if not Run.backdoor_rooted:
		return
	_run_rooted_here = true
	unlock("ROOTED")
	if Run.layer_number >= ROOTED_DEEP_LAYER:
		unlock("ROOTED_DEEP")
	if Run.layer_number >= DEEP_STATE_LAYER:
		unlock("DEEP_STATE")
	if Run.layer_number >= DEEP_STATE_2_LAYER:
		unlock("DEEP_STATE_2")


## "Descend past a backdoor without exfiltrating" — the crew rode the shaft down
## from a layer whose node they had already rooted, and never called the uplink.
func _on_descent_started(_next_layer: int) -> void:
	if _run_rooted_here and not Run.exfil_calling:
		unlock("ONE_MORE_RING")
	# Arrival to drop shaft under 90 s: the descent channel starting is the crew
	# committing to the shaft, so time it from this layer's arrival.
	if _layer_arrival_msec > 0 and Time.get_ticks_msec() - _layer_arrival_msec \
			<= int(SPEEDRUN_SECONDS * 1000.0):
		unlock("SPEEDRUN")


func _on_layer_changed(number: int) -> void:
	_run_rooted_here = false
	# Per-layer state resets on every arrival (POWER_USER and SPEEDRUN are both
	# single-layer facts).
	_layer_power_loads = 0
	_layer_arrival_msec = Time.get_ticks_msec()
	_note_deepest(number)
	if number >= FIRST_STEPS_LAYER:
		unlock("FIRST_STEPS")
	if number >= KERNEL_PANIC_LAYER:
		unlock("KERNEL_PANIC")
	if number >= RING_RUNNER_LAYER:
		unlock("RING_RUNNER")
	# Reached this deep having deleted nothing this run.
	if number >= PACIFIST_DEEP_LAYER and _run_kills == 0:
		unlock("PACIFIST_DEEP")


func _on_restored(peer_id: int, by_peer: int) -> void:
	# I was brought back up: MOTHERS_FAVORITE counts restores OF me, this run.
	if peer_id == Net.local_id():
		_run_restores += 1
		if _run_restores >= FAVORITE_RESTORES:
			unlock("MOTHERS_FAVORITE")
	# I brought someone else up: MEDIC_MAIN counts restores BY me, lifetime.
	if by_peer == Net.local_id() and peer_id != Net.local_id() and not fabricated():
		counters["restores"] = int(counters.get("restores", 0)) + 1
		if int(counters["restores"]) >= MEDIC_MAIN_RESTORES:
			unlock("MEDIC_MAIN")


func _on_buffers_changed() -> void:
	_run_peak_buffer = maxi(_run_peak_buffer, Run.local_buffered())


func _on_run_ended(summary: Dictionary) -> void:
	# `--hud-state debrief` fires a fabricated summary so the debrief screen can
	# be photographed without playing a run out. That is a legitimate thing to do
	# to a *screen* — the HUD is a pure observer and shows exactly what it would
	# really show — but it is not a legitimate thing to do to a save file. An
	# achievement is a claim about something the player did.
	if bool(summary.get("synthetic", false)):
		return
	if fabricated():
		return

	var me: int = Net.local_id()
	var escaped: Array = summary.get("escaped", []) as Array
	var got_out: bool = escaped.has(me)
	var banked: int = int((summary.get("banked", {}) as Dictionary).get(me, 0))
	var crew: int = int(summary.get("crew", Net.crew.size()))

	if bool(summary.get("success", false)) and got_out:
		counters["exfils"] = int(counters.get("exfils", 0)) + 1
		counters["data_banked"] = int(counters.get("data_banked", 0)) + banked
		if crew <= 1:
			unlock("COLD_BOOT")
		if _run_kills == 0:
			unlock("PACIFIST_PROTOCOL")
		if _run_starved >= LIGHTS_OUT_SECONDS:
			unlock("LIGHTS_OUT")
		if banked >= HOARDER_DATA:
			unlock("HOARDER_BUFFER")
		# Everyone alive *and* everyone out: a crewmate left on the floor of the
		# layer is neither.
		if crew >= FULL_CREW and escaped.size() >= FULL_CREW \
				and int(summary.get("deleted", 0)) == 0:
			unlock("NO_AGENT_LEFT")
		# --- v2 (M4.9) ---
		if int(counters.get("data_banked", 0)) >= MILLIONAIRE_DATA:
			unlock("MILLIONAIRE")
		# Everyone in, everyone out and up — FROM THE KERNEL BAND. The shallow
		# version of this is NO_AGENT_LEFT above; see FULL_STACK_LAYER for why the
		# two stopped sharing a trigger. `layers` is `deepest_layer`, which at an
		# exfil IS the layer they left from (a run never goes back up).
		if crew >= FULL_CREW and escaped.size() >= FULL_CREW \
				and int(summary.get("layers", Run.deepest_layer)) >= FULL_STACK_LAYER:
			unlock("FULL_STACK")
		if int(summary.get("layers", Run.deepest_layer)) >= UNTOUCHED_LAYERS \
				and _run_untouched:
			unlock("UNTOUCHED")
		# The pool at exfil — Run has not reset it yet when the summary lands.
		if Run.cycles < NO_BREATH_CYCLES:
			unlock("NO_BREATH")
		# Carried the lion's share of what came home. Needs a crew to share with.
		if crew >= 2:
			var total_banked: int = 0
			for value: int in (summary.get("banked", {}) as Dictionary).values():
				total_banked += int(value)
			if total_banked > 0 \
					and float(banked) >= SHARED_BURDEN_FRACTION * float(total_banked):
				unlock("SHARED_BURDEN")
	elif not bool(summary.get("success", false)):
		# A wipe with nothing to lose: not one shard was ever in your buffer.
		if _run_peak_buffer == 0:
			unlock("NULL_AND_VOID")

	_note_deepest(int(summary.get("layers", Run.deepest_layer)))
	save_state()
	_mirror_stats()


## UNTOUCHED wants a run with no mark on it at all; the first hit ends that.
func _on_damaged(_from: Vector3) -> void:
	_run_untouched = false


## A module purchase — the one moment a track can reach its ceiling. Local peer
## only; unlock() self-guards a fabricated build, so a `--modules` session that was
## handed maxed tracks never scores these.
func _on_purchased(peer_id: int, track: String, tier: int, _from_buffer: int,
		_from_archive: int) -> void:
	if peer_id != Net.local_id():
		return
	if tier < Modules.tier_count(track):
		return
	unlock("FULLY_COMPILED")
	var all_maxed: bool = true
	for name: String in Balance.MODULE_TRACKS:
		if Modules.tier_of(Net.local_id(), name) < Modules.tier_count(name):
			all_maxed = false
			break
	if all_maxed:
		unlock("OVERENGINEERED")


## The junction bus was rerouted. POWER_USER wants all three real loads used on one
## layer; NONE (bus cut) does not count. The bitmask resets on each layer arrival.
func _on_power_changed() -> void:
	match Props.power:
		Props.Power.LIGHTS:
			_layer_power_loads |= 0b001
		Props.Power.DOORS:
			_layer_power_loads |= 0b010
		Props.Power.FANS:
			_layer_power_loads |= 0b100
	if _layer_power_loads == POWER_LOADS_ALL:
		unlock("POWER_USER")


func _note_deepest(layer: int) -> void:
	if layer > int(counters.get("deepest_layer", 0)):
		counters["deepest_layer"] = layer


func _reset_run() -> void:
	_run_kills = 0
	_run_restores = 0
	_run_peak_buffer = 0
	_run_starved = 0.0
	_run_rooted_here = false
	_run_untouched = true


# -------------------------------------------------------------------- unlock --

func is_unlocked(id: String) -> bool:
	return earned.has(id)


func definition(id: String) -> Dictionary:
	for entry: Dictionary in DEFINITIONS:
		if String(entry["id"]) == id:
			return entry
	return {}


## The single door every achievement comes through: local write, toast, then a
## best-effort push at Steam. Already-earned ids are silently ignored.
func unlock(id: String) -> bool:
	if earned.has(id):
		return false
	if fabricated():
		print("[Achievements] %s not scored: this session's program is fabricated" % id)
		return false
	var entry: Dictionary = definition(id)
	if entry.is_empty():
		push_warning("[Achievements] unknown id '%s'" % id)
		return false

	earned[id] = int(Time.get_unix_time_from_system())
	save_state()
	print("[Achievements] UNLOCKED %s — %s (%s)" % [id, entry["name"], entry["note"]])
	unlocked.emit(id, entry)
	_mirror_unlock(id)
	return true


func reset_all() -> void:
	earned.clear()
	for key: String in counters.keys():
		counters[key] = 0
	save_state()
	print("[Achievements] local state reset (%s)" % SAVE_PATH)
	if SteamHub.live:
		# Clear our ids at Steam too, so a dev reset is a real reset on both
		# sides. Fails harmlessly on 480, where the ids do not exist.
		for entry: Dictionary in DEFINITIONS:
			Steam.clearAchievement(String(entry["id"]))
		Steam.storeStats()


# --------------------------------------------------------------- persistence --

## A corrupt file costs you your unlocks, never your boot — and since M4.8.1 it
## costs you nothing at all if the `.bak` is good. Both persistent files in the
## game share GameState's reader for this: the old code here type-tested with
## `parsed as Dictionary`, which aborts the function on the cast rather than
## returning null, so the guard beneath it was unreachable and a truncated file
## loaded as "no achievements" — which the very next unlock then wrote back.
func load_state() -> void:
	var loaded: Dictionary = GameState.load_json(
			"Achievements", SAVE_PATH, SAVE_BACKUP, SAVE_CORRUPT)
	if not bool(loaded["ok"]):
		return
	var data: Dictionary = loaded["data"] as Dictionary
	earned = GameState.sub_dict(data, "earned")
	var stored: Dictionary = GameState.sub_dict(data, "counters")
	for key: String in counters.keys():
		counters[key] = int(stored.get(key, 0))
	print("[Achievements] loaded %d/%d unlocked" % [earned.size(), DEFINITIONS.size()])


## Atomic, like the program file, and for a sharper reason: this one is written
## on every unlock and at the end of every run, so it is the file most likely to
## be open when a session is force-quit. A plain `store_string` here was what
## made the corruption above reachable in the first place.
func save_state() -> void:
	GameState.commit_json("Achievements", JSON.stringify({
		"version": SAVE_VERSION,
		"earned": earned,
		"counters": counters,
	}, "\t"), SAVE_PATH, SAVE_TEMP, SAVE_BACKUP)


# ------------------------------------------------------------- steam mirror --

## Retro-sync: everything this machine has ever earned, replayed at Steam. Runs
## once at boot when the API is live.
func _sync_to_steam() -> void:
	if not SteamHub.live:
		return
	if earned.is_empty():
		_mirror_stats()
		return
	var pushed: int = 0
	var refused: int = 0
	for id: String in earned.keys():
		if Steam.setAchievement(id):
			pushed += 1
		else:
			refused += 1
	Steam.storeStats()
	_mirror_stats()
	print("[Achievements] steam retro-sync: %d accepted, %d refused (app %d)%s" % [
		pushed, refused, SteamHub.app_id,
		"  — expected on 480: BANISH PROTOCOL ids are not in Valve's test app"
			if refused > 0 else ""])


func _mirror_unlock(id: String) -> void:
	if not SteamHub.live:
		return
	var accepted: bool = Steam.setAchievement(id)
	var stored: bool = Steam.storeStats()
	print("[Achievements] steam mirror %s: setAchievement=%s storeStats=%s" % [
		id, str(accepted), str(stored)])


func _mirror_stats() -> void:
	if not SteamHub.live:
		return
	Steam.setStatInt("nv_kills", int(counters.get("kills", 0)))
	Steam.setStatInt("nv_runs", int(counters.get("runs", 0)))
	Steam.setStatInt("nv_exfils", int(counters.get("exfils", 0)))
	Steam.setStatInt("nv_deepest_layer", int(counters.get("deepest_layer", 0)))
	Steam.setStatInt("nv_data_banked", int(counters.get("data_banked", 0)))
	Steam.setStatInt("nv_scrubber_kills", int(counters.get("scrubber_kills", 0)))
	Steam.setStatInt("nv_restores", int(counters.get("restores", 0)))
	Steam.storeStats()


# ----------------------------------------------------------------- toast/dev --

func _install_toast() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var scene: PackedScene = load("res://src/ui/achievement_toast.tscn") as PackedScene
	if scene == null:
		push_warning("[Achievements] toast scene missing")
		return
	_toast = scene.instantiate()
	add_child(_toast)


## `--reset-achievements` and `--grant <ID>`, applied after everything is bound
## so a granted achievement still toasts.
func _apply_dev_flags() -> void:
	if Debug.reset_achievements:
		reset_all()
	for id: String in Debug.granted_achievements:
		var upper: String = id.to_upper()
		if upper == "ALL":
			for entry: Dictionary in DEFINITIONS:
				unlock(String(entry["id"]))
			continue
		if not unlock(upper):
			print("[Achievements] --grant %s: already unlocked or unknown" % upper)


# --- deferred v2 entries (M4.9) ----------------------------------------------
#
# The catalog above is every v2 id wireable through the events the game already
# emits. The rest are held back because they need instrumentation that does not
# exist yet, or systems from a later milestone. Each is a one-signal job once the
# hook below is added — noted so the next pass knows exactly where to reach.
#
#   Need a new arg / flag on an existing event:
#     CORE_BREACH   per-kill "core hits only" flag from the breaker path
#     DAVID         shooter's Breaker tier carried on process_deleted
#     CLUTCH_RESTORE  corrupted-decay remaining carried on Run.restored
#     LOCKSMITH     the cut-vs-rewire bool (host-only in Props._cabinet_request)
#   Need a brand-new event/counter to instrument:
#     WELDER        per-weld lifetime count (vents_changed is not per-weld)
#     TYPIST/WARDRIVER/NAMED_HER  a terminal-query event (+ LIST DATA / "MOTHER")
#     HIGH_ROLLER/WINDOW_SHOPPER  per-Compiler-visit spend + open/close count
#     PHOTOPHOBIA/LIGHTHOUSE  per-flare / per-beam Scrubber-rout attribution
#     SLAMMED       a "Scrubber entered this corridor" event
#     KICKED_IT     per-kicked-debris attracted-process count
#     LOOT_GOBLIN   per-layer chip-completion tracking
#   Later-milestone systems:
#     PHOTOSENSITIVE  beam-toggle tracking (post-M6 riff, per DESIGN.md)
#     ARCHAEOLOGIST/THE_COAT  Northcairn fragment / coat collectibles (M6 lore)
#     UPWARD        layer-13+ doctrine-plate prop + dwell timer
#     WRONG_DOOR    the egg.open door-question easter egg
#     RELIEVED      reach the Kernel — reserved M7 (DESIGN.md)
#
# All are hidden-or-not per DESIGN.md's catalog; the four hidden ones above
# (NAMED_HER, WRONG_DOOR, ARCHAEOLOGIST, THE_COAT, UPWARD) will carry
# `"hidden": true` and no pre-unlock spoiler text when they land.
