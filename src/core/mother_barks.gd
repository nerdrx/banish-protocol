class_name MotherBarks
extends RefCounted
## Loads and renders MOTHER's voice from the authored corpus
## (limbo-lore/corpus.json, copied to res://assets/lore/corpus.json).
##
## 183 barks, categorised (ambient / descent / noise / hunt / kill_ack / mercy /
## sanctuary / address / exfil / epitaph / kernel_leak), each depth-gated
## (`depth_min`/`depth_max`) and pre-rendered at three corruption tiers. The
## corruption is baked into the file — `corruption_renderings` is `[clean, tier1,
## tier2]`, tier 0 always the canonical text — so this class never runs the glyph
## algorithm itself; it only PICKS the tier that matches the depth and substitutes
## the `{CALLSIGN}` token. That keeps the corruption vocabulary authored in one
## place (STYLE_BIBLE) and identical to the terminal and signage decay.
##
## Selection is a plain seeded draw and touches no run state, no wire, no
## determinism dump — the Director owns the *budget* (how rarely she speaks) and
## the *replication* (a rendered line RPC'd to the crew). This is only the library.

const CORPUS_PATH: String = "res://assets/lore/corpus.json"

## category -> Array[Dictionary] of bark entries.
var _by_category: Dictionary = {}
var _loaded: bool = false
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


## `seed_value` >= 0 pins the draw for a reproducible automated run; otherwise the
## library babbles off wall time, which is correct — she should not say the same
## thing every intrusion.
func _init(seed_value: int = -1) -> void:
	if seed_value >= 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	_load()


func _load() -> void:
	if not FileAccess.file_exists(CORPUS_PATH):
		push_warning("[MotherBarks] corpus not found at %s — MOTHER stays silent" % CORPUS_PATH)
		return
	var file: FileAccess = FileAccess.open(CORPUS_PATH, FileAccess.READ)
	if file == null:
		push_warning("[MotherBarks] cannot open %s" % CORPUS_PATH)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("entries"):
		push_warning("[MotherBarks] corpus malformed")
		return
	for entry: Variant in (parsed as Dictionary)["entries"]:
		var e: Dictionary = entry as Dictionary
		if e == null or String(e.get("kind", "")) != "bark":
			continue
		var category: String = String(e.get("category", ""))
		if not _by_category.has(category):
			_by_category[category] = [] as Array
		(_by_category[category] as Array).append(e)
	_loaded = true
	var total: int = 0
	for cat: String in _by_category:
		total += (_by_category[cat] as Array).size()
	print("[MotherBarks] loaded %d barks in %d categories" % [total, _by_category.size()])


func is_loaded() -> bool:
	return _loaded


## Pick and render one bark for `category` at `layer`. Returns
## {text, id, tier, trigger, callsign} or an empty dict if the category has no
## eligible line. `{CALLSIGN}` is replaced with `callsign`; the corruption tier is
## chosen from the depth (BARK_CORRUPT_* thresholds). `exclude` is a set of bark
## ids to keep out of the draw — the Director uses it for the once-per-player-ever
## `addr.go_up` line, which must never be offered again once it has been said.
func pick(category: String, layer: int, callsign: String = "",
		exclude: Array = []) -> Dictionary:
	if not _loaded:
		return {}
	var pool: Array = []
	var weights: Array[float] = []
	var total: float = 0.0
	for e: Dictionary in _by_category.get(category, []) as Array:
		if layer < int(e.get("depth_min", 1)) or layer > int(e.get("depth_max", 99)):
			continue
		if exclude.has(String(e.get("id", ""))):
			continue
		pool.append(e)
		var w: float = maxf(float(e.get("weight", 1)), 0.01)
		weights.append(w)
		total += w
	if pool.is_empty():
		return {}

	var roll: float = _rng.randf() * total
	var chosen: Dictionary = pool[pool.size() - 1]
	for i: int in pool.size():
		roll -= weights[i]
		if roll <= 0.0:
			chosen = pool[i]
			break

	var tier: int = tier_for(layer)
	var renderings: Array = chosen.get("corruption_renderings", [])
	var text: String = String(chosen.get("text", ""))
	if not renderings.is_empty():
		text = String(renderings[clampi(tier, 0, renderings.size() - 1)])
	text = text.replace("{CALLSIGN}", callsign)
	return {
		"text": text,
		"id": String(chosen.get("id", "")),
		"tier": tier,
		"trigger": String(chosen.get("trigger", "")),
		"callsign": bool(chosen.get("callsign_param", false)),
	}


## Corruption tier from depth: clean on the surface, tier 1 through the working
## rings, tier 2 in the legacy deep. Matches the depth bands the world decay and
## the music floors already use, because it is the same fact about the same
## building coming apart.
static func tier_for(layer: int) -> int:
	if layer >= Balance.BARK_CORRUPT_TIER2_LAYER:
		return 2
	if layer >= Balance.BARK_CORRUPT_TIER1_LAYER:
		return 1
	return 0
