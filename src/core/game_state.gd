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
##      state this game can be in.
##   2. **A file we cannot read is never a file we overwrite blind.** A missing
##      or corrupt save loads as a fresh program (the game boots, always), and
##      the first thing any migration does is take a `.bak` copy.

const SAVE_PATH: String = "user://save.json"
const SAVE_TEMP: String = "user://save.json.tmp"
const SAVE_BACKUP: String = "user://save.json.bak"

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
	if not FileAccess.file_exists(SAVE_PATH):
		print("[GameState] no program file; starting a fresh program")
		return
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_warning("[GameState] save unreadable: %s" % error_string(FileAccess.get_open_error()))
		return
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	# A corrupt or hand-edited save must never stop the game booting: fall back
	# to a fresh program rather than refusing to start.
	var data: Dictionary = parsed as Dictionary
	if data == null:
		push_warning("[GameState] save unparseable, starting fresh")
		return

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
	modules = _clean_modules(data.get("modules", {}) as Dictionary)
	var stored: Dictionary = data.get("stats", {}) as Dictionary
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
	_write_text(SAVE_BACKUP, original)
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
	if not FileAccess.file_exists(ACHIEVEMENTS_PATH):
		return
	var file: FileAccess = FileAccess.open(ACHIEVEMENTS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	var data: Dictionary = parsed as Dictionary
	if data == null:
		return
	var counters: Dictionary = data.get("counters", {}) as Dictionary
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


## Temp-then-rename. `store_string` can return short on a full disk and the
## process can die between the open and the close; neither is allowed to leave
## the real file truncated, so the real file is only ever replaced by a rename
## of something already flushed and closed.
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
	if not _write_text(SAVE_TEMP, payload):
		return
	var err: Error = DirAccess.rename_absolute(SAVE_TEMP, SAVE_PATH)
	if err != OK:
		push_warning("[GameState] could not commit save: %s" % error_string(err))


func _write_text(path: String, text: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[GameState] write failed (%s): %s" % [
			path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(text)
	file.close()
	return true


## The player choosing their phosphor, from the injection console's picker. The
## one path that is allowed to change what the program file says — see
## `_file_color`.
func choose_phosphor(colour: Color) -> void:
	local_color = UiFx.clamp_phosphor(colour)
	_file_color = local_color
	UiFx.set_phosphor(local_color)
	save_progress()
