extends Node
## GameState — who you are, and the two numbers that survive a run.
##
## M1 kept this to identity plus the reason we bounced back to the menu. M3 adds
## the *persistence hooks* DESIGN.md's meta-progression needs — the archive you
## have banked and the deepest backdoor you have installed — written to a tiny
## JSON file. Deliberately only those two: the module economy and per-player
## program files are M4, and a save format that guesses at them now would only
## have to be migrated.

const SAVE_PATH: String = "user://save.json"
const SAVE_VERSION: int = 1

const DEFAULT_COLORS: Array[Color] = [
	Color(0.36, 0.78, 1.0),   # ice
	Color(1.0, 0.55, 0.18),   # ember
	Color(0.45, 1.0, 0.58),   # bio
	Color(0.95, 0.35, 0.45),  # signal
	Color(0.78, 0.55, 1.0),   # void
	Color(1.0, 0.88, 0.35),   # sodium
]

## Set before host()/join(); sent to the host on connect.
var local_name: String = "AGENT"
var local_color: Color = DEFAULT_COLORS[0]

## Populated when we leave a session, consumed and cleared by the main menu.
var last_status_message: String = ""

# --- persistence (M3 hooks; the full economy is M4) --------------------------

## Deepest layer whose maintenance node this machine has rooted. 0 = none, so
## the only injection point on offer is layer 1.
var deepest_backdoor: int = 0
## Shards banked by exfiltrating, across every run on this machine.
var archive: int = 0
## Which layer the host injects the crew at. Chosen in the menu, applied by Net.
var injection_layer: int = 1


func _ready() -> void:
	load_progress()


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


# -------------------------------------------------------------- persistence --

## Layers the crew may inject at: always 1, plus the ring below the deepest
## backdoor this machine has installed (DESIGN.md: "layer 1, or any backdoor").
func injection_choices() -> Array[int]:
	var choices: Array[int] = [1]
	if deepest_backdoor > 0:
		choices.append(deepest_backdoor + 1)
	return choices


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
	save_progress()
	print("[GameState] banked %d data (archive %d)" % [amount, archive])


func load_progress() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_warning("[GameState] save unreadable: %s" % error_string(FileAccess.get_open_error()))
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	# A corrupt or hand-edited save must never stop the game booting: fall back
	# to a fresh program rather than refusing to start.
	var data: Dictionary = parsed as Dictionary
	if data == null:
		push_warning("[GameState] save unparseable, starting fresh")
		return
	deepest_backdoor = maxi(int(data.get("deepest_backdoor", 0)), 0)
	archive = maxi(int(data.get("archive", 0)), 0)
	print("[GameState] loaded save: archive=%d deepest_backdoor=%d" % [
		archive, deepest_backdoor])


func save_progress() -> void:
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[GameState] save failed: %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify({
		"version": SAVE_VERSION,
		"deepest_backdoor": deepest_backdoor,
		"archive": archive,
	}, "\t"))
	file.close()
