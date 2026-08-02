extends Node
## GameState — who you are, and the program file that survives everything.
##
## M1 kept this to identity plus the reason we bounced back to the menu. M3 added
## two persistence hooks — the archive you had banked and the deepest backdoor
## you had installed. M4 turns those two fields into the real thing DESIGN.md's
## meta-progression section asks for: **a per-player program file**.
##
##   modules           the eight tracks and what tier each is compiled to
##   archive           your wallet, in data units
##   deepest_backdoor  the deepest maintenance node this machine has rooted
##   stats             lifetime runs / exfiltrations / deletions / data banked
##
## Achievements keep their own file (`user://achievements.json`) and always did.
## They are a claim about something you *did*; this is a description of what you
## *are*, and mixing the two would mean an achievement reset costing you a build.
##
## ## Two rules the writer follows
##
##   1. **A crash mid-write must never cost you your program.** Every save goes
##      to a temp file and is then renamed over the real one, which is atomic on
##      every filesystem this ships on. A half-written program file is not a
##      state this game can be in. `commit_json` is the only writer, here and in
##      Achievements, so there is one implementation of that rule rather than
##      one per file.
##   2. **A file we cannot read is never a file we overwrite blind.** A missing
##      or corrupt save loads as a fresh program (the game boots, always) — but
##      before it does, the reader tries the `.bak` the writer takes ahead of
##      every commit, and if that fails too the damaged bytes are moved aside to
##      `.corrupt` rather than being overwritten by the next save. Losing a
##      program to a bad shutdown is the one cost in this game a player cannot
##      earn back.

const SAVE_PATH: String = "user://save.json"
const SAVE_TEMP: String = "user://save.json.tmp"
const SAVE_BACKUP: String = "user://save.json.bak"
## Where a file that neither parsed nor had a usable `.bak` is put out of harm's
## way. Nothing reads it; it exists so "we started you fresh" is recoverable by
## hand instead of being a deletion.
const SAVE_CORRUPT: String = "user://save.json.corrupt"

## 1 — M3: {version, archive, deepest_backdoor}. `archive` counted *shards*.
## 2 — M4: the full program file. `archive` counts *data units*.
const SAVE_VERSION: int = 2

## Achievements owns this file; the v1 migration only ever *reads* it, and it is
## named here rather than reached through the autoload because that autoload is
## created after this one (see `_seed_stats_from_achievements`).
const ACHIEVEMENTS_PATH: String = "user://achievements.json"

const DEFAULT_COLORS: Array[Color] = [
	Color(0.36, 0.78, 1.0),   # ice
	Color(1.0, 0.55, 0.18),   # ember
	Color(0.45, 1.0, 0.58),   # bio
	Color(0.95, 0.35, 0.45),  # signal
	Color(0.78, 0.55, 1.0),   # void
	Color(1.0, 0.88, 0.35),   # sodium
]

## Lifetime counters, and their zero. Kept as one dictionary so adding a stat
## later is one line here and a migration nobody has to write.
const STAT_KEYS: Array[String] = ["runs", "exfils", "deletions", "data_banked"]

## Set before host()/join(); sent to the host on connect.
var local_name: String = "AGENT"
var local_color: Color = UiFx.PHOSPHOR_DEFAULT
## What the program file on disk says the phosphor is, as distinct from what this
## session is rendering in.
##
## They differ in exactly one case and it matters: `--color` is a capture flag —
## "photograph the HUD in green" — and a dev tool that quietly rewrote the
## developer's own saved colour every time they took a screenshot would be a dev
## tool nobody could safely run twice. `save_progress` writes THIS one; the menu's
## picker is the only thing that ever moves it.
var _file_color: Color = UiFx.PHOSPHOR_DEFAULT

## Populated when we leave a session, consumed and cleared by the main menu.
var last_status_message: String = ""

# --- the program file --------------------------------------------------------

## Deepest layer whose maintenance node this machine has rooted. 0 = none, so
## the only injection point on offer is layer 1.
var deepest_backdoor: int = 0
## Data banked by exfiltrating, across every run on this machine, minus
## everything spent at Compilers. DESIGN.md's "archive".
var archive: int = 0
## track id -> tier. Absent means tier 0. Never contains a zero entry, so an
## empty dictionary is exactly "a fresh program".
var modules: Dictionary = {}
## Lifetime totals. Presentation only — nothing in the simulation reads these.
var stats: Dictionary = {}

## Which layer the host injects the crew at. Chosen in the menu, applied by Net.
var injection_layer: int = 1

## Set by `--modules` / `--archive`: this session is running a **fabricated**
## program, so nothing may be written back to the file. A measuring instrument
## that edits the thing it is measuring is not a measuring instrument, and a
## capture run that quietly spends the developer's real archive on a tier it was
## only meant to photograph is a bug you find days later, in the wrong file.
var sandboxed: bool = false

## True for the session in which the file was migrated up a version. The menu
## says so once, because silently rewriting somebody's save is rude even when it
## is correct.
var migrated_from: int = 0


func _ready() -> void:
	for key: String in STAT_KEYS:
		stats[key] = 0
	load_progress()
	_bind_stats()


func sanitize_name(raw: String) -> String:
	var trimmed: String = raw.strip_edges()
	if trimmed.is_empty():
		trimmed = "AGENT"
	return trimmed.substr(0, 14).to_upper()


func report(message: String) -> void:
	last_status_message = message


func consume_status() -> String:
	var message: String = last_status_message
	last_status_message = ""
	return message


# -------------------------------------------------------------- lifetime stats --

## Lifetime counters hang off the events the run already emits, exactly the way
## Achievements does — and with the same guard. `--hud-state debrief` fabricates
## a summary so the screen can be photographed; that is a legitimate thing to do
## to a *screen* and not to a save file, so a payload flagged `synthetic` is
## counted by nothing.
func _bind_stats() -> void:
	Run.config_changed.connect(func() -> void:
		if not scoring():
			return
		bump_stat("runs", 1))
	Run.process_deleted.connect(func(by_peer: int, _kind: String) -> void:
		if scoring() and by_peer == Net.local_id():
			bump_stat("deletions", 1))
	Run.run_ended.connect(_on_run_ended)


func _on_run_ended(summary: Dictionary) -> void:
	if bool(summary.get("synthetic", false)) or not scoring():
		return
	if not bool(summary.get("success", false)):
		return
	var escaped: Array = summary.get("escaped", []) as Array
	if not escaped.has(Net.local_id()):
		return
	# `bank()` already counted the data and saved; this is the exfiltration count
	# on its own, so a successful run with an empty buffer still scores as one.
	bump_stat("exfils", 1)


## Whether this process's program file should be counting anything at all.
##
## Two ways it should not. A **sandboxed** session is running a build the player
## did not earn (`--modules` and friends), and a **dedicated server** is not a
## player at all — it has a program file only because every process does, and
## before M4 it was quietly logging an intrusion every time somebody started one
## on it.
func scoring() -> bool:
	return not sandboxed and not Net.is_dedicated


func stat(key: String) -> int:
	return int(stats.get(key, 0))


func bump_stat(key: String, amount: int) -> void:
	if amount == 0:
		return
	stats[key] = stat(key) + amount
	save_progress()


# -------------------------------------------------------------- persistence --

## Layers the crew may inject at: always 1, plus the ring below the deepest
## backdoor this machine has installed (DESIGN.md: "layer 1, or any backdoor").
func injection_choices() -> Array[int]:
	var choices: Array[int] = [1]
	if deepest_backdoor > 0:
		choices.append(deepest_backdoor + 1)
	return choices


## The deepest backdoor a program needs to have installed to inject at `layer`.
## Zero for the surface, which every program qualifies for.
static func backdoor_for(layer: int) -> int:
	return 0 if layer <= 1 else layer - 1


## Called when this machine roots a node. Only ever deepens.
func record_backdoor(layer_number: int) -> void:
	if layer_number <= deepest_backdoor:
		return
	deepest_backdoor = layer_number
	save_progress()
	print("[GameState] backdoor installed at layer %d" % layer_number)


## Called on a successful exfiltration. Buffered data becomes archive data —
## the only moment in the game where that happens.
func bank(amount: int) -> void:
	if amount <= 0:
		return
	archive += amount
	stats["data_banked"] = stat("data_banked") + amount
	save_progress()
	print("[GameState] banked %d data (archive %d)" % [amount, archive])


## A Compiler purchase the host has already accepted. The archive half of the
## price is debited here; the buffered half was never in this file to begin with.
func compile_module(track: String, tier: int, archive_spent: int) -> void:
	if tier <= 0:
		modules.erase(track)
	else:
		modules[track] = tier
	archive = maxi(archive - maxi(archive_spent, 0), 0)
	save_progress()
	print("[GameState] compiled %s tier %d (-%d archive, %d left)%s" % [
		track.to_upper(), tier, archive_spent, archive,
		"  [sandboxed: not written]" if sandboxed else ""])


func module_tier(track: String) -> int:
	return int(modules.get(track, 0))


func load_progress() -> void:
	# A corrupt or hand-edited save must never stop the game booting, and must
	# never be silently replaced either: `load_json` walks file -> .bak ->
	# quarantine, and only then gives up and starts fresh.
	var loaded: Dictionary = load_json("GameState", SAVE_PATH, SAVE_BACKUP, SAVE_CORRUPT)
	var text: String = String(loaded["text"])
	if not bool(loaded["ok"]):
		return
	var data: Dictionary = loaded["data"] as Dictionary

	var version: int = int(data.get("version", 1))
	deepest_backdoor = maxi(int(data.get("deepest_backdoor", 0)), 0)
	archive = maxi(int(data.get("archive", 0)), 0)
	# Absent in a v1/v2 file written before M4.7, which is exactly the case the
	# default covers — an untouched program ships Northcairn amber.
	var saved_colour: String = String(data.get("color", ""))
	if not saved_colour.is_empty() and Color.html_is_valid(saved_colour):
		local_color = UiFx.clamp_phosphor(Color.html(saved_colour))
	_file_color = local_color
	# One call coats every gauge, label and panel in the game — see UiFx's
	# palette block. Done here rather than in the menu so a session that skips
	# the menu entirely (every automated run, the dedicated server, a
	# `--autohost` capture) still renders in the player's own phosphor.
	UiFx.set_phosphor(local_color)
	# `sub_dict`, not `as Dictionary`: a file whose "modules" is a number or a
	# list would abort this function on the cast and leave the program half
	# loaded — the same trap the file-level read had.
	modules = _clean_modules(sub_dict(data, "modules"))
	var stored: Dictionary = sub_dict(data, "stats")
	for key: String in STAT_KEYS:
		stats[key] = maxi(int(stored.get(key, 0)), 0)

	if version < SAVE_VERSION:
		_migrate(version, text)
		return
	print("[GameState] program loaded: archive=%d backdoor=%d modules=[%s] %s" % [
		archive, deepest_backdoor, Modules.describe(modules), _stats_text()])


## Drops unknown tracks and out-of-range tiers, and never stores a zero. A save
## written by a build with a track this one does not have must not be able to
## put a key into the roster that `Modules.resolve` will then index an array
## with.
func _clean_modules(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in raw.keys():
		var track: String = String(key)
		if not Balance.MODULES.has(track):
			push_warning("[GameState] save names an unknown module '%s'; dropped" % track)
			continue
		var tiers: Array = (Balance.MODULES[track] as Dictionary)["prices"]
		var tier: int = clampi(int(raw[key]), 0, tiers.size())
		if tier > 0:
			out[track] = tier
	return out


## Brings an older program file forward. Takes a `.bak` of the original bytes
## first — always, before anything is written — so a migration that gets
## something wrong is recoverable by hand rather than by apology.
func _migrate(from_version: int, original: String) -> void:
	migrated_from = from_version
	write_text_file("GameState", SAVE_BACKUP, original)
	print("[GameState] migrating program file v%d -> v%d (backup: %s)" % [
		from_version, SAVE_VERSION, SAVE_BACKUP])

	if from_version <= 1:
		# v1 counted the archive in *shards*, because M3 banked
		# `Run.buffered_of()` — a chip count — and the per-layer worth was only
		# ever flavour on the pickup. M4 makes data a value, so a v1 archive is
		# converted at the layer-1 rate rather than being silently redefined to a
		# tenth of what it was. The runs that earned it were shallow ones; this
		# is the conservative reading of the same number, not a windfall.
		archive *= Balance.SHARD_BASE_VALUE
		# Lifetime stats did not exist. Achievements has been counting three of
		# the four all along and its file is right there, so a migrated program
		# arrives with the history the player actually has instead of zeroes.
		_seed_stats_from_achievements()

	save_progress()
	print("[GameState] migrated: archive=%d backdoor=%d modules=[%s] %s" % [
		archive, deepest_backdoor, Modules.describe(modules), _stats_text()])


## Reads `user://achievements.json` directly rather than going through the
## Achievements autoload: that autoload is created after this one, and a
## migration that has to wait for the rest of the boot is a migration that can
## be interrupted halfway.
func _seed_stats_from_achievements() -> void:
	# Same type test as everywhere else, and for the same reason: `as Dictionary`
	# on a damaged file aborts this function on the cast, which used to leave the
	# migration running on with zeroed lifetime stats.
	var parsed: Variant = as_json_object(read_text_file("GameState", ACHIEVEMENTS_PATH))
	if parsed == null:
		return
	var counters: Dictionary = sub_dict(parsed as Dictionary, "counters")
	stats["runs"] = maxi(int(counters.get("runs", 0)), 0)
	stats["exfils"] = maxi(int(counters.get("exfils", 0)), 0)
	stats["deletions"] = maxi(int(counters.get("kills", 0)), 0)
	# Banked data was a shard count there too, and converts the same way.
	stats["data_banked"] = maxi(int(counters.get("data_banked", 0)), 0) \
			* Balance.SHARD_BASE_VALUE
	print("[GameState] seeded lifetime stats from achievements: %s" % _stats_text())


func _stats_text() -> String:
	return "runs=%d exfils=%d deletions=%d banked=%d" % [
		stat("runs"), stat("exfils"), stat("deletions"), stat("data_banked")]


# ------------------------------------------------------- json, safely, twice --
#
# Both persistent files in the game go through the three helpers below.
# Achievements calls them too rather than keeping its own copy: it had a
# hand-rolled non-atomic writer and the same unreachable corruption guard, and
# two implementations of "do not lose the player's file" is one too many.


## A file's whole contents, or "" if it is missing or unreadable.
static func read_text_file(tag: String, path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("[%s] unreadable (%s): %s" % [
			tag, path, error_string(FileAccess.get_open_error())])
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


## The JSON **object** in `text`, or `null` for anything that is not one.
##
## This exists because `parsed as Dictionary` is not a type test. **[verified
## 4.7.1]** casting a non-Dictionary with `as` raises `Invalid cast: could not
## convert value to 'Dictionary'` and terminates the enclosing function on the
## spot — so a `if data == null` guard written underneath one can never run (and
## a typed `Dictionary` local is never null anyway). Every read of untrusted
## bytes in this project type-tests first and casts second.
static func as_json_object(text: String) -> Variant:
	if text.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	return parsed


## A nested object off an untrusted dictionary, or `{}` if that key holds
## anything else. The same rule as `as_json_object`, one level down: JSON and
## the wire both hand us dictionaries whose *values* are equally unchecked.
static func sub_dict(data: Dictionary, key: String) -> Dictionary:
	var value: Variant = data.get(key, {})
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	return value as Dictionary


## Reads a JSON object, recovering from `backup` if the real file is damaged and
## quarantining the damage at `corrupt` if it is not recoverable.
##
## Returns `{"ok": bool, "data": Dictionary, "text": String}` — `text` is the
## bytes the object was actually parsed from, which a migration needs so its own
## `.bak` is the file it migrated and not the one it wrote.
static func load_json(tag: String, path: String, backup: String,
		corrupt: String) -> Dictionary:
	var text: String = read_text_file(tag, path)
	var parsed: Variant = as_json_object(text)
	if parsed != null:
		return {"ok": true, "data": parsed as Dictionary, "text": text}

	if text.is_empty() and not FileAccess.file_exists(path):
		print("[%s] no file at %s; starting fresh" % [tag, path])
		return {"ok": false, "data": {}, "text": ""}

	# There were bytes and they were not a JSON object: truncated by a crash mid
	# write, hand-edited into invalidity, or half-synced from a cloud save. One
	# generation back is the `.bak` the writer takes before every commit.
	push_warning("[%s] %s is not readable JSON; trying %s" % [tag, path, backup])
	var recovered: String = read_text_file(tag, backup)
	var from_backup: Variant = as_json_object(recovered)
	if from_backup != null:
		# The damaged bytes are kept as well: the .bak is one save behind, and
		# whatever was in the newer file may still be worth reading by hand.
		_quarantine(tag, path, corrupt)
		print("[%s] recovered from %s" % [tag, backup])
		return {"ok": true, "data": from_backup as Dictionary, "text": recovered}

	# Nothing readable anywhere. Boot fresh — the game always boots — but move
	# the damage aside first, because the alternative is that the next write
	# overwrites it and the player's history is genuinely gone.
	_quarantine(tag, path, corrupt)
	push_warning("[%s] no readable file and no usable backup; starting fresh" % tag)
	return {"ok": false, "data": {}, "text": ""}


static func _quarantine(tag: String, path: String, corrupt: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var err: Error = DirAccess.copy_absolute(path, corrupt)
	if err != OK:
		push_warning("[%s] could not quarantine %s: %s" % [tag, path, error_string(err)])
		return
	print("[%s] damaged file kept at %s" % [tag, corrupt])


## Temp-then-rename, with a `.bak` of the last known good bytes taken first.
##
## `store_string` can return short on a full disk and the process can die
## between the open and the close; neither is allowed to leave the real file
## truncated, so the real file is only ever replaced by a rename of something
## already flushed and closed. The backup copy is what makes `load_json`'s
## recovery path have something to recover from — it is taken from the file on
## disk, so it is always a file that parsed at least once.
static func commit_json(tag: String, payload: String, path: String, temp: String,
		backup: String) -> bool:
	if not write_text_file(tag, temp, payload):
		return false
	# Only ever promote a file that PARSES to the backup slot. The moment this
	# matters is the first save after a recovery: the primary on disk is still the
	# damaged copy the boot refused, and copying it over `.bak` would destroy the
	# only good generation there is — turning a recoverable file into two bad ones
	# on the next crash. Re-reading a 300-byte file per save is nothing next to
	# that; this is not a per-frame path.
	if FileAccess.file_exists(path) \
			and as_json_object(read_text_file(tag, path)) != null:
		var copied: Error = DirAccess.copy_absolute(path, backup)
		if copied != OK:
			push_warning("[%s] could not refresh %s: %s" % [tag, backup, error_string(copied)])
	var err: Error = DirAccess.rename_absolute(temp, path)
	if err != OK:
		push_warning("[%s] could not commit %s: %s" % [tag, path, error_string(err)])
		return false
	return true


static func write_text_file(tag: String, path: String, text: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[%s] write failed (%s): %s" % [
			tag, path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(text)
	file.close()
	return true


func save_progress() -> void:
	if sandboxed:
		return
	var payload: String = JSON.stringify({
		"version": SAVE_VERSION,
		"deepest_backdoor": deepest_backdoor,
		"archive": archive,
		"modules": modules,
		"stats": stats,
		# The shell marker, which since M4.7 is also the phosphor the player's own
		# interface is coated with — so it is a setting worth surviving a restart
		# rather than something re-picked every launch. Stored as a hex string
		# because a Color round-trips through JSON as four floats and reads as
		# noise in a file a player might open.
		"color": _file_color.to_html(false),
	}, "\t")
	commit_json("GameState", payload, SAVE_PATH, SAVE_TEMP, SAVE_BACKUP)


## The player choosing their phosphor, from the injection console's picker. The
## one path that is allowed to change what the program file says — see
## `_file_color`.
func choose_phosphor(colour: Color) -> void:
	local_color = UiFx.clamp_phosphor(colour)
	UiFx.set_phosphor(local_color)
	# A commit that changes nothing is still a full serialise, temp write and
	# atomic rename — and every rename is a window in which a crash leaves the
	# save mid-flight. The picker calls this on release and on every tab-away out
	# of the hex field, so "nothing moved" is the common case, not the rare one.
	if _file_color.is_equal_approx(local_color):
		return
	_file_color = local_color
	save_progress()
