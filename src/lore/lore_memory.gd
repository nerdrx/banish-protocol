class_name LoreMemory
extends RefCounted
## What MOTHER remembers about you between intrusions.
##
## The cheapest characterisation in the game and the most unpleasant: a system
## that files you. "YOU HAVE BEEN INSIDE ME 12 TIMES." costs one integer and does
## more work than any line she can say about the room she is standing in, because
## it is the only thing in the game that proves she was here when you were not.
##
## ## Why this is its own file and not a field in the program file
##
## `GameState` already persists the two facts that ARE progression — your archive
## and your deepest backdoor — and it is owned by the netcode pass. Nothing in
## here is progression. It is an OBSERVATION RECORD: how many times you have come,
## how you ended last time, which pools of her voice are part-spent, and which
## lines she has used recently so she does not open your next intrusion with the
## one that closed this one. A player who deletes this file loses nothing but her
## memory of them, which is the correct amount to lose, and is exactly the reason
## it must not sit in the same file as their build.
##
## It follows GameState's writer rules to the letter, through GameState's own
## static helpers: temp-then-rename with a `.bak` taken first, a damaged file
## quarantined rather than overwritten, and a missing file loading as a fresh
## record so the game always boots. And it honours `GameState.sandboxed`, because
## a capture run that quietly told her she had met the developer forty times is a
## bug you find in a screenshot three days later.

const PATH: String = "user://lore.json"
const TEMP: String = "user://lore.json.tmp"
const BACKUP: String = "user://lore.json.bak"
const CORRUPT: String = "user://lore.json.corrupt"
const VERSION: int = 1

## How many recently-spoken line ids to carry ACROSS runs. Sized so a whole
## intrusion's worth of barks (she speaks perhaps twenty to forty times in
## fifteen minutes) is still in the ring when the next one starts.
const RECENT_CAP: int = 64

## Seconds between writes at most. She talks often; the file is small; neither is
## a reason to hit the disk on every line.
const SAVE_INTERVAL: float = 20.0

# --- the record ---------------------------------------------------------------

## Intrusions this record has seen begin. `GameState.stat("runs")` is the
## authority when it is available — it is older than this file and survives a
## deletion of it — and this is the fallback and the cross-check.
var intrusions: int = 0
var exfils: int = 0
var wipes: int = 0
## Deepest ordinal layer ever reached, and the deepest reached on the run BEFORE
## this one. The second is the whole of "YOU WENT DEEPER LAST TIME".
var deepest: int = 0
var last_deepest: int = 0
## "exfil", "wipe", or "" for a record that has never seen a run finish.
var last_end: String = ""
## The last line id spoken in the previous session. Never the first of the next.
var closed_with: String = ""
## callsign -> how many times that callsign has been deleted, ever.
var deaths: Dictionary = {}
## The route fingerprint of the previous run (ordered room archetypes), and how
## many consecutive runs have now matched it. Two is already enough for her to
## say "YOU ALWAYS TAKE THE SAME ROUTE" and be telling the truth.
var last_route: String = ""
var route_repeats: int = 0

## bag key -> the ids still unspoken in that bag's current cycle.
var bags: Dictionary = {}
## Ring of recently spoken ids, oldest first.
var recent: Array[String] = []

# --- session-local ------------------------------------------------------------

var _dirty: bool = false
var _last_save: float = -999.0
var _loaded: bool = false
## A record the simulation drives. Never reads and never writes the real file —
## a repetition test that spent the developer's own history would be a test you
## can only run once.
var volatile: bool = false
## Route being accumulated this run, compared against `last_route` at the end.
var _route: PackedStringArray = PackedStringArray()


func load_record() -> void:
	if _loaded or volatile:
		return
	_loaded = true
	var result: Dictionary = GameState.load_json("Lore", PATH, BACKUP, CORRUPT)
	if not bool(result.get("ok", false)):
		return
	var data: Dictionary = result.get("data", {}) as Dictionary
	intrusions = maxi(int(data.get("intrusions", 0)), 0)
	exfils = maxi(int(data.get("exfils", 0)), 0)
	wipes = maxi(int(data.get("wipes", 0)), 0)
	deepest = maxi(int(data.get("deepest", 0)), 0)
	last_deepest = maxi(int(data.get("last_deepest", 0)), 0)
	last_end = String(data.get("last_end", ""))
	closed_with = String(data.get("closed_with", ""))
	last_route = String(data.get("last_route", ""))
	route_repeats = maxi(int(data.get("route_repeats", 0)), 0)
	deaths = data.get("deaths", {}) as Dictionary
	bags = data.get("bags", {}) as Dictionary
	recent.clear()
	for entry: Variant in data.get("recent", []) as Array:
		recent.append(String(entry))
	_trim_recent()


## How many times this player has intruded — the `{RUNS}` slot. Prefers the
## program file's lifetime counter, which is the older and more authoritative of
## the two, and falls back to this record for a player whose save was reset.
func runs() -> int:
	return maxi(GameState.stat("runs"), intrusions)


func note_spoken(id: String) -> void:
	if id.is_empty():
		return
	recent.append(id)
	_trim_recent()
	closed_with = id
	_dirty = true


func _trim_recent() -> void:
	while recent.size() > RECENT_CAP:
		recent.remove_at(0)


## Called once when an intrusion begins. Returns nothing; the interesting values
## (`last_end`, `last_deepest`) are read by the director for the lines that only
## make sense on a return.
func begin_run() -> void:
	intrusions += 1
	_route = PackedStringArray()
	_dirty = true
	save(true)


## One room entered, for the route fingerprint. Cheap enough to call per room and
## deliberately coarse — it records the SHAPE of the route (which archetypes, in
## which order), not the geometry, because the geometry is a different layer every
## run and would never match.
func note_room(archetype: String) -> void:
	if archetype.is_empty():
		return
	if _route.size() > 0 and _route[_route.size() - 1] == archetype:
		return
	if _route.size() < 32:
		_route.append(archetype)


func end_run(success: bool, reached: int) -> void:
	last_deepest = maxi(deepest, 0)
	deepest = maxi(deepest, reached)
	last_end = "exfil" if success else "wipe"
	if success:
		exfils += 1
	else:
		wipes += 1
	var route: String = ",".join(_route)
	if not route.is_empty() and route == last_route:
		route_repeats += 1
	elif not route.is_empty():
		route_repeats = 0
	last_route = route
	_dirty = true
	save(true)


func note_death(callsign: String) -> void:
	if callsign.is_empty():
		return
	deaths[callsign] = int(deaths.get(callsign, 0)) + 1
	_dirty = true


func death_count(callsign: String) -> int:
	return int(deaths.get(callsign, 0))


func store_bag(key: String, state: Array) -> void:
	bags[key] = state
	_dirty = true


func bag_state(key: String) -> Array:
	return bags.get(key, []) as Array


## Write, at most every `SAVE_INTERVAL` seconds unless `force`. Silently does
## nothing in a sandboxed session — see the class docstring.
func save(force: bool = false) -> void:
	if not _dirty or volatile or GameState.sandboxed:
		return
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if not force and now - _last_save < SAVE_INTERVAL:
		return
	_last_save = now
	_dirty = false
	var payload: Dictionary = {
		"version": VERSION,
		"intrusions": intrusions,
		"exfils": exfils,
		"wipes": wipes,
		"deepest": deepest,
		"last_deepest": last_deepest,
		"last_end": last_end,
		"closed_with": closed_with,
		"last_route": last_route,
		"route_repeats": route_repeats,
		"deaths": deaths,
		"bags": bags,
		"recent": recent,
	}
	GameState.commit_json("Lore", JSON.stringify(payload, "\t"), PATH, TEMP, BACKUP)
