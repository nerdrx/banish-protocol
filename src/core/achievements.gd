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
const SAVE_VERSION: int = 1

## The DESIGN.md table, verbatim, plus the counter each trigger needs.
## `id` is the Steamworks API name; `name` is what the toast shows.
const DEFINITIONS: Array[Dictionary] = [
	{"id": "FIRST_DELETION", "name": "Garbage Collection",
		"note": "Delete your first Scrubber"},
	{"id": "ROOTED", "name": "Rooted",
		"note": "Install your first backdoor"},
	{"id": "NULL_AND_VOID", "name": "Null and Void",
		"note": "Wipe with zero buffered data"},
	{"id": "ONE_MORE_RING", "name": "One More Ring",
		"note": "Descend past a backdoor without exfiltrating"},
	{"id": "PACIFIST_PROTOCOL", "name": "Pacifist Protocol",
		"note": "Exfiltrate without deleting a single process"},
	{"id": "LIGHTS_OUT", "name": "Lights Out",
		"note": "Survive 60s at zero Cycles and still exfiltrate"},
	{"id": "NO_AGENT_LEFT", "name": "No Agent Left Behind",
		"note": "Full 4-crew exfiltration, everyone alive"},
	{"id": "COLD_BOOT", "name": "Cold Boot",
		"note": "Exfiltrate a solo intrusion"},
	{"id": "DEEP_STATE", "name": "Deep State",
		"note": "Root the layer-15 backdoor"},
	{"id": "KERNEL_PANIC", "name": "Kernel Panic",
		"note": "Reach layer 25"},
	{"id": "HOARDER_BUFFER", "name": "Buffer Overflow",
		"note": "Exfiltrate carrying 100+ data in one run"},
	{"id": "MOTHERS_FAVORITE", "name": "Mother's Favorite",
		"note": "Get restored 3 times in one intrusion"},
]

## Thresholds the triggers above read, kept together so they are tunable.
const LIGHTS_OUT_SECONDS: float = 60.0
const DEEP_STATE_LAYER: int = 15
const KERNEL_PANIC_LAYER: int = 25
const HOARDER_DATA: int = 100
const FAVORITE_RESTORES: int = 3
const FULL_CREW: int = 4

## id -> unix seconds. Presence in this dictionary *is* the unlock.
var earned: Dictionary = {}
## Lifetime counters, persisted alongside. Mirrored to Steam stats when live.
var counters: Dictionary = {
	"kills": 0,
	"runs": 0,
	"exfils": 0,
	"deepest_layer": 0,
	"data_banked": 0,
}

# --- per-intrusion memory (reset by `_reset_run`) ----------------------------
var _run_kills: int = 0
var _run_restores: int = 0
var _run_peak_buffer: int = 0
var _run_starved: float = 0.0
## True once a backdoor has been rooted on the layer we are standing on.
var _run_rooted_here: bool = false

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
	counters["runs"] = int(counters.get("runs", 0)) + 1
	_note_deepest(Run.layer_number)
	save_state()


func _on_process_deleted(by_peer: int, kind: String) -> void:
	if by_peer != Net.local_id():
		return
	_run_kills += 1
	counters["kills"] = int(counters.get("kills", 0)) + 1
	if kind == "Scrubber" or kind.is_empty():
		# `kind` is empty only if an older peer sent the M3 packet shape; a kill
		# is still a kill, and the first one is the achievement.
		unlock("FIRST_DELETION")


func _on_backdoor_changed() -> void:
	if not Run.backdoor_rooted:
		return
	_run_rooted_here = true
	unlock("ROOTED")
	if Run.layer_number >= DEEP_STATE_LAYER:
		unlock("DEEP_STATE")


## "Descend past a backdoor without exfiltrating" — the crew rode the shaft down
## from a layer whose node they had already rooted, and never called the uplink.
func _on_descent_started(_next_layer: int) -> void:
	if _run_rooted_here and not Run.exfil_calling:
		unlock("ONE_MORE_RING")


func _on_layer_changed(number: int) -> void:
	_run_rooted_here = false
	_note_deepest(number)
	if number >= KERNEL_PANIC_LAYER:
		unlock("KERNEL_PANIC")


func _on_restored(peer_id: int, _by_peer: int) -> void:
	if peer_id != Net.local_id():
		return
	_run_restores += 1
	if _run_restores >= FAVORITE_RESTORES:
		unlock("MOTHERS_FAVORITE")


func _on_buffers_changed() -> void:
	_run_peak_buffer = maxi(_run_peak_buffer, Run.local_buffered())


func _on_run_ended(summary: Dictionary) -> void:
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
	elif not bool(summary.get("success", false)):
		# A wipe with nothing to lose: not one shard was ever in your buffer.
		if _run_peak_buffer == 0:
			unlock("NULL_AND_VOID")

	_note_deepest(int(summary.get("layers", Run.deepest_layer)))
	save_state()
	_mirror_stats()


func _note_deepest(layer: int) -> void:
	if layer > int(counters.get("deepest_layer", 0)):
		counters["deepest_layer"] = layer


func _reset_run() -> void:
	_run_kills = 0
	_run_restores = 0
	_run_peak_buffer = 0
	_run_starved = 0.0
	_run_rooted_here = false


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

func load_state() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_warning("[Achievements] unreadable: %s" % error_string(FileAccess.get_open_error()))
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	var data: Dictionary = parsed as Dictionary
	# A corrupt file costs you your unlocks, never your boot.
	if data == null:
		push_warning("[Achievements] unparseable, starting fresh")
		return
	earned = data.get("earned", {}) as Dictionary
	var stored: Dictionary = data.get("counters", {}) as Dictionary
	for key: String in counters.keys():
		counters[key] = int(stored.get(key, 0))
	print("[Achievements] loaded %d/%d unlocked" % [earned.size(), DEFINITIONS.size()])


func save_state() -> void:
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[Achievements] save failed: %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify({
		"version": SAVE_VERSION,
		"earned": earned,
		"counters": counters,
	}, "\t"))
	file.close()


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
		"  — expected on 480: NULLVOID ids are not in Valve's test app"
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
