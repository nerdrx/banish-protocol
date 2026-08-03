class_name LoreDirector
extends RefCounted
## M15 — HER TONGUE. The bark director: WHICH line, and WHY THAT ONE.
##
## The corpus grew from 183 barks to 848. That is the smaller half of this
## milestone and it is worth saying why out loud, because it is the thing the
## work was organised around:
##
##   **SPECIFICITY BEATS VOLUME.** A thousand random lines still feel repetitive.
##   Two hundred that fire at exactly the right moment feel infinite, because a
##   line about what you just did never reads as filler. So the corpus is big AND
##   narrow: a hundred pools hung off narrow contextual triggers, and a director
##   whose job is to notice which one is true right now.
##
## ## What this replaces
##
## `MotherBarks.pick` draws weighted-random from a whole CATEGORY. That gives a
## repeat inside the first handful of lines about half the time, and after an
## hour a player has heard the same six ambient barks a dozen times each and has
## stopped hearing her at all. It also renders `{ROOM}`, `{N}` and every other
## slot as literal braces, because only `{CALLSIGN}` was ever substituted.
##
## This does four things instead:
##
##   1. **Trigger selection.** The category the Director asks for is the register;
##      the trigger is the moment. `ambient` at a layer you have been on for six
##      minutes, carrying more than you can run with, in a room you already
##      cleared, is three different pools and she picks the most specific one.
##   2. **Slot safety.** A line's `{SLOT}`s are read out of its own text and it is
##      refused unless every one of them can be filled with a real value from the
##      live run. She never says a line about a dead crewmate on a run where
##      nobody has died, and she never renders a brace.
##   3. **Anti-repetition** (`LoreBag`): a shuffled bag per pool, so a line cannot
##      recur until its pool is spent; a recency ring persisted ACROSS runs, so
##      she does not open your next intrusion with the line that closed this one;
##      and a per-pool cooldown so two barks never crowd each other.
##   4. **Cross-run memory** (`LoreMemory`): how many times you have come, how far
##      you got last time, how you ended, whether you always take the same route.
##
## ## The single hook
##
## One line in `HauntDirector._bark`, swapping the library call for this one:
##
##     var rendered: Dictionary = LoreDirector.get_instance().pick(
##             category, _layer, callsign, exclude, _barks)
##
## That is the whole integration. Everything else this class knows, it observes
## for itself, read-only, off `Run` / `Net` / `GameState` / the scene tree — which
## is why it works with ZERO triggers wired and gets sharper as they are. If it
## cannot load its own corpus it hands the call straight back to the `MotherBarks`
## fallback it was given, so the failure mode is "the old behaviour", never
## silence.
##
## `note()` and `urge()` are the optional half: any system that wants to tell her
## something specific — a patch was taken, a kill was a chain, a collection room
## was entered — calls `LoreDirector.get_instance().note(...)` and the next bark
## knows. Nothing is required to call them.
##
## ## What this is not
##
## Not replicated, not simulation, not seen by generation. The host decides what
## she says and RPCs the rendered string, exactly as before; this only chooses the
## string. It owns a private `RandomNumberGenerator` and never touches the shared
## seeded stream, so `--dumplayer` cannot see it and determinism is untouched.

const CORPUS_PATH: String = "res://assets/lore/corpus.json"

## Mirrors `Hunter.HUNTER_GROUP`. Deliberately a literal and not a reference to
## that constant: this file is loaded by the autoload chain, and a hard reference
## into a parallel-owned script means a rename over there fails THIS parse, which
## fails the autoloads, which takes down every run in the tree. A stale literal
## costs one silent pool; a stale reference costs the game.
const HUNTER_GROUP: String = "hunter"
const ANTIVIRUS_GROUP: String = "antivirus"

## How long a `note()` stays live enough to steer the next bark. Longer than the
## Director's own bark floor (9 s) so a noted event reliably survives to the next
## opportunity, short enough that she is never commenting on ancient history.
const NOTE_TTL: float = 22.0
## A single pool may not speak twice inside this, at all. The bag stops her
## repeating a LINE; this stops her repeating a SUBJECT.
const POOL_COOLDOWN: float = 90.0
## And the soft half of the same rule, which matters more than the hard one.
##
## THE STUCK-CONDITION PROBLEM, found by the simulation and worth naming because
## it is invisible in a code read: some conditions are true for ten minutes at a
## stretch. Low Cycles. An overloaded buffer. Lingering on a ring. With a plain
## cooldown, a condition like that wins every contest the moment its cooldown
## lapses, and the player hears one ten-line pool cycle four times while eighty
## other pools sit unused — a corpus of 848 delivering the variety of ten. The
## first measured run did exactly this: 341 lines, only 166 distinct, and the
## tightest repeat gap was three lines apart in `ambient.starving`.
##
## So a pool does not come back at full strength; it RECOVERS. Its score is scaled
## by how long it has been quiet, reaching full weight only after this long. A
## freshly noted event (score 4.0) still beats everything instantly — being told
## something is not the same as noticing it again — but two conditions that are
## both permanently true now trade places instead of one of them winning forever.
const POOL_RECOVERY: float = 420.0
## This class's own crowding floor. `Balance.BARK_MIN_GAP` (9 s) is stricter and
## is what actually binds in game; this exists so the module is still safe when
## something other than the Director calls it.
const MIN_GAP: float = 6.0

## Seconds standing within `STILL_RADIUS` before she calls you stationary.
const STILL_SECONDS: float = 34.0
const STILL_RADIUS: float = 2.0
## Seconds on one ring before `ambient.linger` becomes true.
const LINGER_SECONDS: float = 240.0
## Seconds with nothing noted before `ambient.silence` becomes true.
const SILENCE_SECONDS: float = 100.0
## A hunter inside this, un-looked-at, is `ambient.unseen`.
const UNSEEN_RANGE: float = 20.0
## And inside this at all is `ambient.proximity`.
const NEAR_RANGE: float = 32.0
## Facing tolerance for "you have not noticed it": dot product of view forward
## against the direction to the hunter.
const UNSEEN_FACING: float = 0.35
## Buffered data at or above which the carry is unwise.
const HEAVY_DATA: int = 40
const RICH_DATA: int = 90
## Cycles fraction below which she comments on the pool.
const STARVING_FRACTION: float = 0.28

# ------------------------------------------------------------ THE TIME BUDGET --
#
# Her lines are HEARD now, not read. `MotherVoice.duration_for_category` returns
# the EXACT seconds of audio that will exist — not an estimate: the synthesiser
# renders `track.seconds * RATE` samples and every stage of the post chain is
# length-preserving, and M14's selftest pins that by predicting and then
# rendering. It is memoised by (register, text) and sub-millisecond, so it is
# billed PER CANDIDATE while choosing rather than after committing.
#
# Two separate things come out of that, and only one of them is a ceiling:
#
#   1. **Collision is no longer a correctness problem.** `_speak_until` holds the
#      floor for exactly as long as the line she just issued will be speaking,
#      plus a breath. A long line pushes the next one later instead of being run
#      over by it. No safety margin is added — padding an exact number would only
#      make her quieter than she needs to be.
#   2. **What remains is whether a line OUTLIVES THE MOMENT IT IS ABOUT.** That is
#      not about collision and no cooldown fixes it: "YOU ARE LOOKING AT THE WRONG
#      WALL" is only useful while it is true. Hence a ceiling, and hence a ceiling
#      that varies by how time-critical the trigger is rather than one flat number
#      that would gut the corpus and gut the best of it first.
#
# THE REGISTER CHANGES THE ANSWER BY ~20%. The same sentence runs ~5.1 s spoken
# directly to your face and ~6.1 s murmured through a wall, because the murmur is
# slower and darker on purpose. `duration_for_category` already knows the register
# and the Below-the-Kernel depth rule, so billing the function handles this for
# free — but a line that can be drawn in more than one register must fit the
# SLOWEST one it can appear in, which is what `worst_case_seconds` evaluates and
# what the pool-starvation selftest is measured against.

## Warnings about a moment that is still happening. A late one is a lie.
const CEILING_URGENT: float = 4.0
## Consequence and atmosphere. Nothing is waiting on these.
const CEILING_STANDARD: float = 7.0
## She has the floor. Rationed by the Director's own budget, not by length.
const CEILING_SETPIECE: float = 10.0

## Triggers that are URGENT regardless of the register they sit in.
##
## `hunter.wounded` is the judgement call in here and it is deliberate: it is
## filed under `kill_ack` but it is not an acknowledgement, it is an instruction
## about a window that is closing — chase it or let it go — so it is billed as a
## warning. Every other `kill_ack` trigger is a comment on something already over
## and takes the STANDARD budget.
## FUNCTION OVER FILING. The taxonomy says where a line was filed; this says what
## it DOES, and where they disagree the ceiling follows the function.
##
##   `hunter.wounded` sits in `kill_ack` and is not an acknowledgement — it is an
##   instruction about a window that is closing ("chase it or let it go").
##   `death.downed` sits in `epitaph` and is not an epitaph — nobody has died yet;
##   it is the same shape of line about the same shape of window ("it is
##   reversible for another forty seconds"), and giving it the ten-second
##   set-piece budget would let a rescue prompt outlive the rescue.
##   `ambient.unseen` is not atmosphere. It is a warning.
const URGENT_TRIGGERS: Array[String] = [
	"ambient.unseen", "hunter.wounded", "death.downed",
]
## And the reverse correction: `exfil.progress` is filed with the set-pieces but
## it is a live readout — "UPLOAD AT 40 PERCENT" is false a moment after it is
## true — so it takes the ordinary budget rather than the floor-to-itself one.
## Not urgent (nothing is decided on it), just not a set-piece.
const STANDARD_TRIGGERS: Array[String] = ["exfil.progress"]
## Set-piece triggers that sit in an otherwise ordinary register.
const SETPIECE_TRIGGERS: Array[String] = ["ambient.gallery", "address.gallery"]
## Registers that are set-pieces wholesale.
const SETPIECE_CATEGORIES: Array[String] = ["address", "epitaph", "exfil", "kernel_leak"]

## WHICH STRING THE CEILING IS BILLED ON, and the one line to change when the
## voice pass lands its glyph fix.
##
## `true` (current): billed on the exact string that will be spoken, corruption
## included. The timing system is therefore EXACT — the number the ceiling tests
## and the number the player waits through are the same number.
##
## This was briefly `false`. The corruption renderer used to inflate spoken
## duration by ~15% (tier 1) and ~19% (tier 2) because the glyph set was voiced as
## pronounceable content, and at 1.19x the URGENT budget admits about twenty-five
## characters below layer 15 — at which point "NOT ALONE. MERELY UNINFORMED.", at
## twenty-nine characters and already as terse as that thought can be put, fails.
## Enforcing a glitch effect's cost against the prose is the wrong constraint, so
## the ceiling was billed on the authored line while the cooldown was billed on
## the spoken one, and the gap was escalated rather than absorbed.
##
## The voice pass then made the glyph set an ARTIFACT — damage, a dropout, a
## swallowed syllable, rather than a machine reciting punctuation — which is both
## right for the fiction and what closes this: measured 1.046x / 0.997x, so the
## two strings now cost the same and the split is no longer needed. `--selftest`
## still prints the factor every run; if it ever drifts back, this flips back and
## the reasoning above is why.
const CEILING_BILLS_SPOKEN: bool = true

## The gap after a line has finished speaking. A breath, not a margin.
const BARK_BREATH: float = 1.6

## How many upcoming lines to hand the synthesiser to build ahead of time.
## Deliberately small: the budget is ~440 ms of worker time per second of audio
## with the full tape chain, and this runs on a bark, not on a frame.
const PREWARM_DEPTH: int = 4


## A pool must have at least this many lines to be selectable AS A TRIGGER.
##
## Three entries in the pre-M15 corpus carry a trigger that belongs to another
## register (`noise.elegant` is category `noise` on trigger `ambient.cycles`, and
## two more like it), which makes them one-line pools. A one-line pool chosen as
## a specific trigger is the exact failure this milestone exists to remove: the
## same sentence, every time the condition is true. So a pool this small is never
## picked deliberately — it stays reachable through the category-wide fallback
## draw, exactly as it was before, and simply never gets promoted to "the most
## specific thing that is true right now".
const MIN_POOL_LINES: int = 3

## Categories `pick("ambient")` is allowed to be promoted INTO.
##
## The Director only ever asks for eight of the eleven registers — `noise`,
## `descent` and `epitaph` have no call site, which is how `kernel_leak` sat
## authored and unreachable until something went looking for it. Rather than ask
## for three more hooks, the generic "say something now" call is allowed to
## upgrade itself: if you tapped a siphon nine seconds ago, the appropriate
## ambient line IS the siphon line. `epitaph` is deliberately NOT in this list —
## a death comment arriving up to forty seconds late is worse than no comment.
const PROMOTABLE: Array[String] = ["ambient", "noise", "descent"]

## Slot tokens this build knows how to fill. A line naming anything else is
## refused by `_can_speak` and reported by the selftest — the corpus cannot
## quietly grow a slot the renderer has never heard of.
const KNOWN_SLOTS: Array[String] = [
	"CALLSIGN", "CREWMATE", "DEAD", "LAYER", "ROOM", "DATA", "CYCLES",
	"CREW_COUNT", "RUNS", "DEEPEST", "PATCH", "CREATURE", "SUBROUTINE",
	"MODULE", "N",
]

static var _instance: LoreDirector = null

# --- corpus -------------------------------------------------------------------

## "category/trigger" -> Array[Dictionary] of entries.
var _pools: Dictionary = {}
## category -> Array[String] of its trigger keys.
var _triggers_by_category: Dictionary = {}
## bag key -> LoreBag.
var _bags: Dictionary = {}
## id -> entry, for the selftest and the simulation.
var _by_id: Dictionary = {}
var _bands: Array = []
var _loaded: bool = false

var memory: LoreMemory = null
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# --- observation --------------------------------------------------------------

## trigger -> {"at": seconds, "args": Dictionary}. Written by `note()`.
var _notes: Dictionary = {}
## pool key -> seconds last spoken.
var _pool_spoken: Dictionary = {}
## Simulation only: trigger -> score, replacing the observed conditions so a
## synthetic session exercises the whole selection path instead of whatever
## happens to be true in a headless process with no crew and an empty pool.
var _sim_scores: Dictionary = {}
var _sim_mode: bool = false
var _last_spoke: float = -999.0
## Wall time at which the line she is currently speaking will have finished, plus
## a breath. The dynamic half of the cooldown — see THE TIME BUDGET above.
var _speak_until: float = -999.0
var _last_event: float = 0.0

var _layer_seen: int = -1
var _layer_entered: float = 0.0
var _still_since: float = 0.0
var _still_at: Vector3 = Vector3.INF
var _rooms_seen: Dictionary = {}
var _room_now: int = -1
var _backtracking: bool = false
var _run_open: bool = false
var _bound: Node = null
## [node, signal, handler] for the named-event listeners, so `unbind` is exact.
var _named: Array[Array] = []

## Set by the simulation so the director can be driven without a tree.
var _synthetic: Dictionary = {}
var _synthetic_now: float = -1.0


static func get_instance() -> LoreDirector:
	if _instance == null:
		_instance = LoreDirector.new()
		_instance.setup(-1)
		_instance.bind()
	return _instance


## Drops the singleton. Only the selftest and the simulation use this — the game
## keeps one director for the whole process, which is what makes the recency ring
## and the bags mean anything.
static func reset_instance() -> void:
	if _instance != null:
		_instance.unbind()
	_instance = null


func setup(seed_value: int = -1) -> void:
	if seed_value >= 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	memory = LoreMemory.new()
	memory.load_record()
	_load()


## Everything she learns without anybody wiring anything.
##
## These are read-only subscriptions to signals `RunState` already emits, and
## they are the reason the milestone lands on ONE hook instead of a dozen: the
## descent registers, the noise consequences, the death record and the whole of
## the cross-run memory come from facts the run announces to the room. Nothing
## here changes any of it — the connection is a listener, and every handler ends
## in either a `note()` or a write to this module's own file.
##
## Skipped entirely when there is no `RunState` yet (the corpus tool, a bare
## headless parse), so the class is still constructible outside a game.
func bind() -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var run: Node = tree.root.get_node_or_null(^"Run")
	if run == null:
		return
	_connect(run, &"config_changed", _on_run_configured)
	_connect(run, &"run_ended", _on_run_ended)
	_connect(run, &"decompiled", _on_decompiled)
	_connect(run, &"layer_changed", _on_layer_changed)
	_connect(run, &"siphon_taken", _on_siphon)
	_connect(run, &"breaker_fired", _on_breaker)
	_connect(run, &"shard_taken", _on_shard)
	_bound = run

	# THE NAMED EVENTS. A patch, a subroutine and a module all have a display name
	# somebody else already owns, and a line that says the name is worth five that
	# say "something". Each of these three autoloads emits the fact and exposes a
	# static accessor for the name, so she can be told without a single line
	# landing in anybody else's file — the same listener pattern as `Run` above,
	# and the reason the {PATCH} hook the coordinator authorised was not needed.
	_bind_named(tree, ^"Patches", &"patch_gained", _on_patch)
	_bind_named(tree, ^"Subs", &"cast_landed", _on_cast)
	_bind_named(tree, ^"Modules", &"purchased", _on_purchase)
	# Named so a missing listener is findable. A signal that silently failed to
	# attach costs a whole register and looks exactly like "she just never says
	# that one", which is the least debuggable failure this module has.
	if Debug.log_ai:
		var attached: PackedStringArray = PackedStringArray()
		for row: Array in _named:
			attached.append("%s.%s" % [String((row[0] as Node).name), String(row[1])])
		print("[Lore] listening to run signals + %d named events: %s" % [
			_named.size(), ", ".join(attached)])


func unbind() -> void:
	if _bound == null or not is_instance_valid(_bound):
		_bound = null
		return
	for pair: Array in [[&"config_changed", _on_run_configured],
			[&"run_ended", _on_run_ended], [&"decompiled", _on_decompiled],
			[&"layer_changed", _on_layer_changed], [&"siphon_taken", _on_siphon],
			[&"breaker_fired", _on_breaker], [&"shard_taken", _on_shard]]:
		var signal_name: StringName = pair[0]
		var handler: Callable = pair[1]
		if _bound.is_connected(signal_name, handler):
			_bound.disconnect(signal_name, handler)
	_bound = null
	for row: Array in _named:
		var node: Node = row[0] as Node
		if node != null and is_instance_valid(node) \
				and node.is_connected(row[1] as StringName, row[2] as Callable):
			node.disconnect(row[1] as StringName, row[2] as Callable)
	_named.clear()


func _bind_named(tree: SceneTree, path: NodePath, signal_name: StringName,
		handler: Callable) -> void:
	var node: Node = tree.root.get_node_or_null(path)
	if node == null:
		return
	_connect(node, signal_name, handler)
	_named.append([node, signal_name, handler])


## A patch was injected. `Patches.display_name` is the same string the HUD's own
## PATCH INJECTED notice uses, so she and the instrument never disagree about
## what the thing is called.
func _on_patch(peer_id: int, patch_id: String, _stacks: int) -> void:
	note(&"patch.taken", {"PATCH": Patches.display_name(patch_id),
		"_peer": str(peer_id)})
	note(&"address.patch", {"PATCH": Patches.display_name(patch_id),
		"_peer": str(peer_id)})


func _on_cast(peer_id: int, subroutine: String) -> void:
	var name: String = Subs.display_name(subroutine)
	note(&"subroutine.cast", {"SUBROUTINE": name, "_peer": str(peer_id)})
	note(&"address.subroutine", {"SUBROUTINE": name, "_peer": str(peer_id)})


func _on_purchase(peer_id: int, track: String, _tier: int, _from_buffer: int,
		_from_archive: int) -> void:
	var name: String = Modules.display_name(track)
	note(&"compiler.buy", {"MODULE": name, "_peer": str(peer_id)})
	note(&"address.module", {"MODULE": name, "_peer": str(peer_id)})


func _connect(node: Node, signal_name: StringName, handler: Callable) -> void:
	if node.has_signal(signal_name) and not node.is_connected(signal_name, handler):
		node.connect(signal_name, handler)


func _on_run_configured() -> void:
	begin_run()


func _on_run_ended(summary: Dictionary) -> void:
	# `--hud-state debrief` fabricates a summary so the screen can be
	# photographed. Counting it would tell her she had met the developer one more
	# time than she had, in a file she keeps forever. Same guard GameState uses.
	if bool(summary.get("synthetic", false)):
		return
	end_run(bool(summary.get("success", false)), Run.deepest_layer)


func _on_decompiled(peer_id: int) -> void:
	var who: String = Net.crew_name(peer_id)
	memory.note_death(who)
	note(&"death.crew", {"DEAD": who})


func _on_layer_changed(number: int) -> void:
	var at: float = _now()
	_notes["descent.arrive"] = {"at": at, "args": {}}
	if number > memory.deepest:
		_notes["descent.deepest"] = {"at": at, "args": {}}
	else:
		_notes["descent.return"] = {"at": at, "args": {}}
	_layer_seen = number
	_layer_entered = at
	_rooms_seen.clear()
	_room_now = -1
	_last_event = at


func _on_siphon(_index: int, _pool: float) -> void:
	note(&"siphon.tap")


func _on_breaker(_by_peer: int, _origin: Vector3) -> void:
	note(&"breaker.fire")


func _on_shard(_index: int, _peer_id: int, _worth: int) -> void:
	note(&"ambient.loot")


func is_loaded() -> bool:
	return _loaded


# ------------------------------------------------------------------- loading --

func _load() -> void:
	if not FileAccess.file_exists(CORPUS_PATH):
		push_warning("[Lore] corpus not found at %s — falling back to MotherBarks" % CORPUS_PATH)
		return
	var file: FileAccess = FileAccess.open(CORPUS_PATH, FileAccess.READ)
	if file == null:
		push_warning("[Lore] cannot open %s" % CORPUS_PATH)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		push_warning("[Lore] corpus malformed")
		return
	var doc: Dictionary = parsed as Dictionary
	_bands = doc.get("bands", []) as Array
	for raw: Variant in doc.get("entries", []) as Array:
		var e: Dictionary = raw as Dictionary
		if e == null or String(e.get("kind", "")) != "bark":
			continue
		var category: String = String(e.get("category", ""))
		var trigger: String = String(e.get("trigger", ""))
		if category.is_empty():
			continue
		if trigger.is_empty():
			trigger = category + ".any"
		var key: String = category + "/" + trigger
		if not _pools.has(key):
			_pools[key] = [] as Array
			if not _triggers_by_category.has(category):
				_triggers_by_category[category] = [] as Array
			(_triggers_by_category[category] as Array).append(key)
		(_pools[key] as Array).append(e)
		_by_id[String(e.get("id", ""))] = e
	_loaded = not _pools.is_empty()
	if _loaded:
		print("[Lore] %d barks in %d pools across %d registers" % [
			_by_id.size(), _pools.size(), _triggers_by_category.size()])


# --------------------------------------------------------------- the one hook --

## Pick and render one bark. Drop-in replacement for `MotherBarks.pick` — same
## arguments, same return shape (`{text, id, tier, trigger, callsign}` or `{}`),
## plus `slots` for anyone who wants the values she used.
##
## `fallback` is the `MotherBarks` the caller already owns. It is used, and only
## used, when this director could not load its own corpus. There is no state in
## which both are silent that the old code would have spoken in.
func pick(category: String, layer: int, callsign: String = "",
		exclude: Array = [], fallback: MotherBarks = null) -> Dictionary:
	if not _loaded:
		if fallback != null and fallback.is_loaded():
			return fallback.pick(category, layer, callsign, exclude)
		return {}

	var now: float = _now()
	if now - _last_spoke < MIN_GAP or now < _speak_until:
		return {}

	_observe(layer, now)
	var ctx: Dictionary = _context(layer, callsign)
	var key: String = _choose_pool(category, layer, ctx, now, exclude)
	if key.is_empty():
		return {}

	var bag: LoreBag = _bag_for(key, layer)
	if bag == null or bag.is_empty():
		return {}
	var chosen: String = bag.draw(_rng,
			func(id: String) -> bool: return _can_speak(id, layer, ctx, exclude),
			memory.recent)
	if chosen.is_empty():
		return {}
	memory.store_bag(_bag_key(key, layer), bag.to_state())  # keyed by pool AND band

	var bag_cycle: int = bag.last_cycle
	var bag_key: String = _bag_key(key, layer)
	var entry: Dictionary = _by_id[chosen] as Dictionary
	var category_of: String = String(entry.get("category", ""))
	var tier: int = MotherBarks.tier_for(layer)
	var renderings: Array = entry.get("corruption_renderings", []) as Array
	var text: String = String(entry.get("text", ""))
	if not renderings.is_empty():
		text = String(renderings[clampi(tier, 0, renderings.size() - 1)])
	text = _fill(text, ctx)

	_last_spoke = now
	# The floor is held for exactly as long as she will be speaking. Exact, so
	# unpadded; a breath after, so two lines never touch.
	_speak_until = now + MotherVoice.duration_for_category(text, category_of, layer) \
			+ BARK_BREATH
	_pool_spoken[key] = now
	memory.note_spoken(chosen)
	memory.save()
	_prewarm_next(key, layer, ctx, exclude)
	return {
		"text": text,
		"id": chosen,
		"tier": tier,
		"trigger": String(entry.get("trigger", "")),
		"callsign": bool(entry.get("callsign_param", false)),
		"slots": ctx,
		"pool": key,
		# The BAG, not the pool: bags are per pool AND depth band, and the
		# no-repeat-within-a-cycle claim is a claim about one bag. The simulation
		# stamps on this — keyed on the pool alone it counts one line legitimately
		# drawn from the SURFACE bag and again from the WORKING bag as a repeat,
		# which is a measurement bug that reads exactly like a real one.
		"bag": bag_key,
		"cycle": bag_cycle,
	}


# ------------------------------------------------------------ what she notices --

## Tell her something happened. `trigger` is a corpus trigger name; `args` fills
## slots she could not observe for herself — `{"PATCH": "BIT ROT"}`,
## `{"CREATURE": "THE HOUND"}`, `{"DEAD": "VANE"}`.
##
## Entirely optional. Nothing in the game is required to call this; every pool it
## can reach either has an observed condition of its own or is simply not asked
## for. Calling it makes her sharper, never louder — the Director still owns the
## budget and refuses far more often than it speaks.
func note(trigger: StringName, args: Dictionary = {}) -> void:
	var name: String = String(trigger)
	if name.is_empty():
		return
	var at: float = _now()
	_notes[name] = {"at": at, "args": args}
	_last_event = at


## The same, but says "this is worth speaking about NOW" — it clears the pool
## cooldown so the next bark opportunity takes it. For the handful of moments
## that genuinely deserve a comment on the beat: a patch taken, a Sentinel core
## kill, a collection room entered.
func urge(trigger: StringName, args: Dictionary = {}) -> void:
	note(trigger, args)
	_pool_spoken.erase(_key_for_trigger(String(trigger)))


## One room, for the route fingerprint and the backtrack pool. Called for free by
## `_observe` when a layer graph is standing; exposed so a system that already
## knows can say so without the poll.
func note_room(index: int, archetype: String) -> void:
	if index < 0:
		return
	_backtracking = _rooms_seen.has(index) and index != _room_now
	if index != _room_now:
		_room_now = index
		_rooms_seen[index] = true
		memory.note_room(archetype)


func begin_run() -> void:
	if _run_open:
		return
	_run_open = true
	_rooms_seen.clear()
	_room_now = -1
	memory.begin_run()
	# Her first line of a session is the one that decides whether the voice is
	# believed. Build it during the loading pause rather than in front of the player.
	prewarm_opening(maxi(Run.layer_number, 1))
	MotherVoice.prewarm_crew()


func end_run(success: bool, reached: int) -> void:
	if not _run_open:
		return
	_run_open = false
	memory.end_run(success, reached)


# ---------------------------------------------------------------- observation --

## Everything she works out for herself, per bark opportunity. Read-only against
## `Run` / `Net` / the tree; nothing here writes to anybody else's state, and all
## of it is cheap because it runs once every twenty to forty seconds, not per
## frame.
func _observe(layer: int, now: float) -> void:
	if layer != _layer_seen:
		if _layer_seen >= 0:
			_notes["descent.arrive"] = {"at": now, "args": {}}
			if layer > memory.deepest:
				_notes["descent.deepest"] = {"at": now, "args": {}}
			elif layer <= memory.deepest:
				_notes["descent.return"] = {"at": now, "args": {}}
		_layer_seen = layer
		_layer_entered = now
		_rooms_seen.clear()
		_room_now = -1
		_last_event = now

	var body: Node3D = _local_body()
	if body == null:
		return
	var at: Vector3 = body.global_position
	if _still_at == Vector3.INF or at.distance_to(_still_at) > STILL_RADIUS:
		_still_at = at
		_still_since = now

	var graph: Object = _graph()
	if graph != null and graph.has_method("room_at") and graph.has_method("room_name"):
		var index: int = int(graph.call("region_of", at)) if graph.has_method("region_of") \
				else int(graph.call("room_at", at))
		if index >= 0:
			var archetype: String = ""
			var rooms: Array = graph.get("rooms") as Array
			if rooms != null and index < rooms.size():
				archetype = String((rooms[index] as Dictionary).get("archetype", ""))
			note_room(index, archetype)


## The slot table. A key is present ONLY when its value is genuinely available,
## which is the whole enforcement mechanism for "she never says a line about
## something that is not true".
func _context(layer: int, callsign: String) -> Dictionary:
	if not _synthetic.is_empty():
		var synthetic: Dictionary = _synthetic.duplicate()
		synthetic["LAYER"] = str(layer)
		if not callsign.is_empty():
			synthetic["CALLSIGN"] = callsign
		return synthetic

	var ctx: Dictionary = {"LAYER": str(layer)}
	if not callsign.is_empty():
		ctx["CALLSIGN"] = callsign
	ctx["RUNS"] = str(memory.runs())
	var deep: int = maxi(memory.deepest, GameState.deepest_backdoor)
	if deep > 0:
		ctx["DEEPEST"] = str(deep)

	var local: int = Net.local_id()
	var running: Array[int] = _running_peers()
	if not running.is_empty():
		ctx["CREW_COUNT"] = str(running.size())
	var mine: int = Run.buffered_value_of(local)
	if mine > 0:
		ctx["DATA"] = str(mine)
	if Run.cycles_max > 0.0:
		ctx["CYCLES"] = str(int(round(Run.cycles)))

	# A crewmate who is not the person being addressed. Only offered when there
	# genuinely is one, so `{CREWMATE}` lines are silent on a solo run.
	for peer: int in running:
		var other: String = Net.crew_name(peer)
		if other != callsign and not other.is_empty():
			ctx["CREWMATE"] = other
			break

	# The most recently deleted crewmate. `Run.deleted` is the host's own record
	# of who is gone, so this needs no wiring and cannot disagree with the run.
	var fallen: String = String((_note_args("death.crew") as Dictionary).get("DEAD", ""))
	if fallen.is_empty():
		for peer: Variant in Run.deleted:
			if bool(Run.deleted[peer]):
				fallen = Net.crew_name(int(peer))
	if not fallen.is_empty():
		ctx["DEAD"] = fallen

	var body: Node3D = _local_body()
	var graph: Object = _graph()
	if body != null and graph != null and graph.has_method("room_name") and _room_now >= 0:
		var room: String = String(graph.call("room_name", _room_now))
		if not room.is_empty() and room != "UNMAPPED":
			ctx["ROOM"] = room

	var hunter: String = _nearest_hunter_kind(body)
	if not hunter.is_empty():
		ctx["CREATURE"] = hunter

	# Whatever the most recent note handed us, last, so an explicit value always
	# wins over an observed one.
	for trigger: Variant in _notes:
		var row: Dictionary = _notes[trigger] as Dictionary
		if _now() - float(row.get("at", -999.0)) > NOTE_TTL:
			continue
		for slot: Variant in row.get("args", {}) as Dictionary:
			var name: String = String(slot)
			if KNOWN_SLOTS.has(name):
				ctx[name] = String((row["args"] as Dictionary)[slot])

	# `{N}` is the legacy slot the pre-M15 entries use and NOTHING ever
	# substituted — "RING {N}." shipped rendering as literal braces. It is filled
	# per register where the value is unambiguous, and left absent (so those lines
	# are simply not offered) where it is not. That un-bricks the descent and crew
	# lines without inventing a number for the ones that meant something else.
	if ctx.has("LAYER"):
		ctx["N_descent"] = ctx["LAYER"]
	if ctx.has("CREW_COUNT"):
		ctx["N_epitaph"] = ctx["CREW_COUNT"]
	return ctx


func _running_peers() -> Array[int]:
	var out: Array[int] = []
	for peer: Variant in Net.crew:
		var id: int = int(peer)
		if Run.is_running(id):
			out.append(id)
	return out


func _local_body() -> Node3D:
	if Engine.get_main_loop() == null:
		return null
	return Net.get_player(Net.local_id()) as Node3D


## A numeric slot as an int, or 0 when she does not have the value. Keeps every
## threshold test above honest about the difference between "zero data" and
## "no reading" — the second must never satisfy a "less than ten" condition it
## has no evidence for, so an absent slot answers -1.
func _slot_int(ctx: Dictionary, slot: String) -> int:
	if not ctx.has(slot):
		return -1
	return String(ctx[slot]).to_int()


func _graph() -> Object:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var layer: Node = tree.get_first_node_in_group("layer")
	if layer == null:
		return null
	return layer.get("graph")


## "THE HOUND" / "THE MOTH" / "THE AUDITOR" / "THE SENTINEL" for the nearest
## process, or "" when nothing is near. The species strings live here rather than
## on the creatures because the creatures have no display names and inventing one
## over there would be an edit to a parallel-owned file for a caption.
func _nearest_hunter_kind(body: Node3D) -> String:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or body == null:
		return ""
	var best: float = NEAR_RANGE
	var kind: String = ""
	for node: Node in tree.get_nodes_in_group(HUNTER_GROUP):
		var h: Node3D = node as Node3D
		if h == null or not is_instance_valid(h) or not h.has_method("ai_kind"):
			continue
		var d: float = h.global_position.distance_to(body.global_position)
		if d < best:
			best = d
			kind = String(h.call("ai_kind"))
	if kind.is_empty():
		return ""
	return "THE " + kind.to_upper()


func _hunter_near(body: Node3D, range_m: float) -> Node3D:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or body == null:
		return null
	for node: Node in tree.get_nodes_in_group(HUNTER_GROUP):
		var h: Node3D = node as Node3D
		if h == null or not is_instance_valid(h):
			continue
		if h.global_position.distance_to(body.global_position) < range_m:
			return h
	return null


# ----------------------------------------------------------- trigger selection --

## Which pool speaks. Scores every trigger the requested register can reach and
## takes the highest — an explicitly noted event beats an observed condition
## beats the register's baseline — with cooldowns knocking out anything she has
## covered recently.
func _choose_pool(category: String, layer: int, ctx: Dictionary, now: float,
		exclude: Array) -> String:
	var candidates: Array[String] = []
	for key: Variant in (_triggers_by_category.get(category, []) as Array):
		candidates.append(String(key))
	if PROMOTABLE.has(category):
		for other: String in PROMOTABLE:
			if other == category:
				continue
			for key: Variant in (_triggers_by_category.get(other, []) as Array):
				candidates.append(String(key))

	var best: String = ""
	var best_score: float = 0.0
	for key: String in candidates:
		if (_pools[key] as Array).size() < MIN_POOL_LINES:
			continue
		var quiet: float = now - float(_pool_spoken.get(key, -9999.0))
		if quiet < POOL_COOLDOWN:
			continue
		var score: float = _score(key, layer, ctx, now)
		if score <= 0.0:
			continue
		score *= clampf(quiet / POOL_RECOVERY, 0.0, 1.0)
		# THE DEPTH-THIN POOL. The pool may hold thirteen lines and still have only
		# two that are legal on layer 3, because most of them are authored deeper —
		# and a bag with two members repeats every other draw no matter how good the
		# shuffle is. The simulation caught exactly this: a tightest repeat gap of 1
		# in `spike.escalate` on the surface rings, with the no-repeat-in-a-cycle
		# invariant still perfectly intact, because a two-line cycle is one line long
		# either side of the boundary. So the floor is applied to what is SPEAKABLE
		# here, not to what is authored. A thin pool is not chosen deliberately; it
		# stays available to the category fallback, which is a coin toss across the
		# whole register and cannot concentrate on it.
		if _speakable_count(key, layer, ctx, exclude) < MIN_POOL_LINES:
			continue
		# A hair of jitter so two conditions that are true at once do not always
		# resolve the same way — the ordering is a fact about the corpus file and
		# should not become a fact about her personality.
		score += _rng.randf() * 0.05
		if score > best_score:
			best_score = score
			best = key
	if not best.is_empty():
		return best

	# THE FLOOR, and the reason this can never be a regression. If no trigger in
	# the requested register could prove itself — every pool cooled down, or the
	# register is one whose triggers are all note-only and nothing has been noted
	# — fall back to a draw across the whole CATEGORY, weighted by pool size.
	# That is precisely what `MotherBarks.pick` did, so the worst case here is the
	# old behaviour with the bag and the slot check still on top of it. She is
	# never silent in a moment where she used to speak.
	var pool_keys: Array[String] = []
	var thin: Array[String] = []
	var sizes: Array[int] = []
	var total: int = 0
	for raw: Variant in (_triggers_by_category.get(category, []) as Array):
		var key: String = String(raw)
		# The fallback answers the same floor as deliberate selection wherever it
		# can. It is the last hole the simulation found: a pool with ONE speakable
		# line at this depth cannot help repeating, and the fallback was reaching
		# for it because it only asked whether the pool could speak at all. It now
		# prefers pools that can hold a cycle, and drops to the thin ones only when
		# the register has nothing else — which is still better than silence.
		if _speakable_count(key, layer, ctx, exclude) < MIN_POOL_LINES:
			thin.append(key)
			continue
		pool_keys.append(key)
		var size: int = (_pools[key] as Array).size()
		sizes.append(size)
		total += size
	if pool_keys.is_empty():
		# Nothing in the register can hold a cycle here. A thin pool beats silence.
		if thin.is_empty():
			return ""
		return thin[_rng.randi_range(0, thin.size() - 1)]
	var roll: int = _rng.randi_range(0, maxi(total - 1, 0))
	for i: int in pool_keys.size():
		roll -= sizes[i]
		if roll < 0:
			return pool_keys[i]
	return pool_keys[pool_keys.size() - 1]


func _score(key: String, layer: int, ctx: Dictionary, now: float) -> float:
	var trigger: String = key.split("/")[1]

	# An explicit note is the strongest signal there is: something told her.
	var row: Dictionary = _notes.get(trigger, {}) as Dictionary
	var noted: float = float(row.get("at", -9999.0))
	if now - noted <= NOTE_TTL:
		# A note about a PERSON may only be spoken AT that person. `_address_target`
		# picks whoever is most under it, which is very often not whoever just took
		# the patch — and "{CALLSIGN}. YOU HAVE INJECTED BIT ROT" aimed at the wrong
		# crewmate is worse than saying nothing, because it is the one register
		# whose entire value is that she is not guessing.
		var about: String = String((row.get("args", {}) as Dictionary).get("_peer", ""))
		if not about.is_empty() and ctx.has("CALLSIGN"):
			if Net.crew_name(about.to_int()) != String(ctx["CALLSIGN"]):
				return 0.0
		return 4.0 - clampf((now - noted) / NOTE_TTL, 0.0, 0.9)

	if _sim_mode:
		return float(_sim_scores.get(trigger, 0.0))

	# Observed conditions. Each is a narrow claim about the live run, and returns
	# 0.0 the moment it cannot prove itself.
	var body: Node3D = _local_body()
	match trigger:
		"ambient.idle":
			return 0.4                                  # the baseline; always true
		"ambient.hub":
			return 2.4 if Run.in_hub else 0.0
		"ambient.overload":
			return 2.2 if _slot_int(ctx, "DATA") >= HEAVY_DATA else 0.0
		"ambient.starving":
			if Run.cycles_max <= 0.0 or Run.in_hub:
				return 0.0
			return 2.6 if Run.fraction() < STARVING_FRACTION else 0.0
		"ambient.stillness":
			if body == null or Run.in_hub:
				return 0.0
			return 1.9 if now - _still_since > STILL_SECONDS else 0.0
		"ambient.backtrack":
			return 2.0 if _backtracking else 0.0
		"ambient.linger":
			if Run.in_hub or _layer_entered <= 0.0:
				return 0.0
			return 1.7 if now - _layer_entered > LINGER_SECONDS else 0.0
		"ambient.silence":
			return 1.2 if now - _last_event > SILENCE_SECONDS else 0.0
		"ambient.route":
			return 1.6 if memory.route_repeats >= 1 else 0.0
		"ambient.unseen":
			return 3.0 if _unseen_hunter(body) else 0.0
		"ambient.proximity":
			return 1.8 if _hunter_near(body, NEAR_RANGE) != null else 0.0
		"ambient.dark":
			return 2.1 if _beam_off(body) else 0.0
		"address.first":
			return 3.2 if memory.runs() <= 1 else 0.0
		"address.runs":
			return 2.4 if memory.runs() >= 3 else 0.0
		"address.veteran":
			return 2.6 if memory.runs() >= 15 else 0.0
		"address.wipe_return":
			return 2.8 if memory.last_end == "wipe" and memory.runs() >= 2 else 0.0
		"address.returning":
			return 1.8 if memory.runs() >= 2 else 0.0
		"address.deepest":
			return 2.2 if memory.last_deepest > layer else 0.0
		"address.route":
			return 2.4 if memory.route_repeats >= 2 else 0.0
		"address.last_one":
			return 3.4 if _running_peers().size() == 1 and Net.crew.size() > 1 else 0.0
		"address.dark":
			return 2.0 if _beam_off(body) else 0.0
		"address.rich":
			return 2.3 if _slot_int(ctx, "DATA") >= RICH_DATA else 0.0
		"address.loaded":
			return 1.9 if _slot_int(ctx, "DATA") >= HEAVY_DATA else 0.0
		"address.isolated":
			return 2.0 if _isolated(body) else 0.0
		"address.crewmate":
			return 1.4 if ctx.has("CREWMATE") else 0.0
		"address.hub":
			return 2.2 if Run.in_hub else 0.0
		"address.wounded":
			return 2.5 if _wounded() else 0.0
		"address.callsign":
			return 0.8
		"exfil.rich":
			return 2.4 if _slot_int(ctx, "DATA") >= RICH_DATA else 0.0
		"exfil.poor":
			return 2.2 if _slot_int(ctx, "DATA") < 10 else 0.0
		"exfil.first":
			return 2.6 if memory.exfils == 0 else 0.0
		"death.last":
			return 2.8 if _running_peers().is_empty() and Net.crew.size() > 1 else 0.0
		"death.repeat":
			return 2.6 if memory.death_count(String(ctx.get("DEAD", ""))) >= 2 else 0.0
		"hunt.unnoticed":
			return 2.6 if _unseen_hunter(body) else 0.0
		"mercy.broken":
			return 1.6 if _wounded() else 0.0
		_:
			# Every remaining trigger is note-only: `ambient.gallery` (the
			# collection rooms do not exist yet), the noise consequences, the kill
			# methods, the patch names. They stay silent until something calls
			# `note()`, which is the correct behaviour for a claim we cannot check.
			return 0.0


func _unseen_hunter(body: Node3D) -> bool:
	if body == null:
		return false
	var h: Node3D = _hunter_near(body, UNSEEN_RANGE)
	if h == null:
		return false
	var to: Vector3 = (h.global_position - body.global_position).normalized()
	var forward: Vector3 = -body.global_transform.basis.z
	return forward.dot(to) < UNSEEN_FACING


func _isolated(body: Node3D) -> bool:
	if body == null:
		return false
	var others: int = 0
	for peer: int in _running_peers():
		if peer == Net.local_id():
			continue
		var node: Node3D = Net.get_player(peer) as Node3D
		if node == null or not is_instance_valid(node):
			continue
		others += 1
		if node.global_position.distance_to(body.global_position) < 16.0:
			return false
	return others > 0


func _wounded() -> bool:
	var value: Variant = Run.integrity.get(Net.local_id())
	if value == null:
		return false
	return float(value) < 55.0


## Whether the local beam is off. Probed rather than typed against `Player`,
## because that file belongs to another pass and this is a cosmetic read: an
## unknown property answers "not off", which fails safe (she says nothing).
func _beam_off(body: Node3D) -> bool:
	if body == null:
		return false
	# `sync_beam` is `Player`'s replicated beam switch (player.gd:224) and is what
	# actually answers here; the rest are kept as fallbacks so a rename over there
	# costs one silent pool rather than a crash. Probed rather than typed against
	# `Player` for the same reason the hunter group is a literal — that file
	# belongs to another pass, and this is a read for a caption.
	for property: String in ["sync_beam", "beam_on", "light_on", "lamp_on"]:
		var value: Variant = body.get(property)
		if value != null and value is bool:
			return not bool(value)
	return false


# --------------------------------------------------------------- eligibility --

## URGENT / STANDARD / SET-PIECE for a pool key ("category/trigger").
static func tier_of(category: String, trigger: String) -> String:
	if SETPIECE_TRIGGERS.has(trigger):
		return "SET-PIECE"
	if URGENT_TRIGGERS.has(trigger) or category == "hunt":
		return "URGENT"
	if STANDARD_TRIGGERS.has(trigger):
		return "STANDARD"
	if SETPIECE_CATEGORIES.has(category):
		return "SET-PIECE"
	return "STANDARD"


static func ceiling_for(category: String, trigger: String) -> float:
	match tier_of(category, trigger):
		"URGENT":
			return CEILING_URGENT
		"SET-PIECE":
			return CEILING_SETPIECE
		_:
			return CEILING_STANDARD


## The longest this line can possibly take, over every register it can be drawn
## in. Only `kernel_leak` changes register with depth (SUBZERO from 20), so this
## is one call for almost everything and two for the deep set.
static func worst_case_seconds(entry: Dictionary, text: String) -> float:
	var category: String = String(entry.get("category", ""))
	var lo: int = int(entry.get("depth_min", 1))
	var hi: int = int(entry.get("depth_max", 99))
	var worst: float = MotherVoice.duration_for_category(text, category, lo)
	if lo < 20 and hi >= 20:
		worst = maxf(worst, MotherVoice.duration_for_category(text, category, 20))
	return worst


func _can_speak(id: String, layer: int, ctx: Dictionary, exclude: Array) -> bool:
	if exclude.has(id):
		return false
	var entry: Dictionary = _by_id.get(id, {}) as Dictionary
	if entry.is_empty():
		return false
	if layer < int(entry.get("depth_min", 1)) or layer > int(entry.get("depth_max", 99)):
		return false
	for slot: String in slots_in(String(entry.get("text", ""))):
		if slot == "N":
			# `{N}` is legacy and means a different number in each register. It is
			# satisfied either by an explicit value somebody handed to `note()` or by
			# the per-register derivation in `_context`; a line whose number nobody
			# can supply is refused rather than rendered with braces in it.
			var category: String = String(entry.get("category", ""))
			if not ctx.has("N") and not ctx.has("N_" + category):
				return false
			continue
		if not KNOWN_SLOTS.has(slot):
			return false
		if not ctx.has(slot) or String(ctx[slot]).is_empty():
			return false
	# THE TIME CEILING, billed against the real synthesiser. Checked last because
	# it is the only test here that costs anything, and because it must be billed
	# on text with the SLOTS FILLED — a slot holds a callsign, not the word
	# "CALLSIGN", and the two do not take the same time to say.
	#
	# BILLED ON THE CANONICAL TEXT, NOT THE CORRUPTED RENDERING, and this is a
	# deliberate split that took a measurement to justify. The corruption tiers
	# inflate spoken duration by ~15% (tier 1) and ~19% (tier 2) on average, and up
	# to 36% on a single line — the glyph set costs real time in the synthesiser.
	# Billing the ceiling on the corrupted string makes the URGENT budget admit
	# about twenty-five characters below layer 15, at which point "NOT ALONE.
	# MERELY UNINFORMED." — twenty-nine characters, and already as terse as that
	# thought can be put — fails. That is not a writing constraint, it is an
	# impossible one, and it would be enforcing a glitch renderer's cost against
	# the prose.
	#
	# So the two halves of the time budget are billed on two different strings, on
	# purpose:
	#
	#   * the CEILING is a constraint on the AUTHORED line — what a writer controls
	#     — and is billed on tier 0;
	#   * the COOLDOWN is a scheduling fact about the AUDIO and is billed on the
	#     exact string that will be spoken, corruption included (see `pick`).
	#
	# The residual risk is that a deep line runs ~19% past its tier on a warning
	# that wanted to be prompt. It is bounded, it is measured, and the alternative
	# was a twenty-five-character corpus. Escalated to the coordinator: if M14's
	# G2P treats the glyph set as artifact rather than as pronounceable content,
	# this whole gap closes and the ceiling can move back onto the spoken string.
	if not bool(entry.get("length_exempt", false)):
		var canonical: String = _fill(String(entry.get("text", "")), ctx)
		if CEILING_BILLS_SPOKEN:
			canonical = render(entry, layer, ctx)
		if worst_case_seconds(entry, canonical) > ceiling_for(
				String(entry.get("category", "")), String(entry.get("trigger", ""))):
			return false
	return true


## How many lines in this pool she could actually say RIGHT NOW — depth-eligible,
## every slot fillable, not excluded. Counted rather than answered yes/no, because
## the count is the thing that decides whether a pool is safe to steer into.
func _speakable_count(key: String, layer: int, ctx: Dictionary, exclude: Array) -> int:
	var n: int = 0
	for entry: Dictionary in _pools.get(key, []) as Array:
		if _can_speak(String(entry.get("id", "")), layer, ctx, exclude):
			n += 1
	return n


## Every `{SLOT}` a line names, in order of appearance. The single source of
## truth for what a line needs — read off the text rather than off the `params`
## field, so a hand-edited corpus entry can never claim it needs nothing.
static func slots_in(text: String) -> Array[String]:
	var out: Array[String] = []
	var from: int = 0
	while true:
		var open: int = text.find("{", from)
		if open < 0:
			break
		var close: int = text.find("}", open)
		if close < 0:
			break
		var name: String = text.substr(open + 1, close - open - 1)
		if not name.is_empty() and not out.has(name):
			out.append(name)
		from = close + 1
	return out


func _fill(text: String, ctx: Dictionary) -> String:
	var out: String = text
	for slot: String in slots_in(text):
		if slot == "N":
			continue
		if ctx.has(slot):
			out = out.replace("{" + slot + "}", String(ctx[slot]))
	# `{N}`, per register. See `_context`.
	if out.contains("{N}"):
		if ctx.has("N"):
			out = out.replace("{N}", String(ctx["N"]))
		else:
			for suffix: String in ["N_descent", "N_epitaph"]:
				if ctx.has(suffix):
					out = out.replace("{N}", String(ctx[suffix]))
					break
	return out


# ---------------------------------------------------------------------- bags --

## Bags are keyed by pool AND depth band, so the set of ids inside one is fixed
## while it is being drawn from. A bag whose membership changed as you descended
## would make the no-repeat-until-exhausted invariant untrue in exactly the case
## it matters — a long run.
func _bag_key(key: String, layer: int) -> String:
	return key + "@" + band_of(layer)


func band_of(layer: int) -> String:
	for raw: Variant in _bands:
		var b: Dictionary = raw as Dictionary
		if layer >= int(b.get("min", 1)) and layer <= int(b.get("max", 99)):
			return String(b.get("name", "SURFACE"))
	return "SURFACE"


func _bag_for(key: String, layer: int) -> LoreBag:
	var bag_key: String = _bag_key(key, layer)
	if _bags.has(bag_key):
		return _bags[bag_key] as LoreBag
	var bag: LoreBag = LoreBag.new()
	var ids: Array[String] = []
	var weights: Dictionary = {}
	var band: String = band_of(layer)
	for entry: Dictionary in _pools.get(key, []) as Array:
		# Band membership, not exact depth: the exact `depth_min`/`depth_max` gate
		# is enforced per draw by `_can_speak`, so a line that unlocks two rings
		# down is already sitting in the bag waiting for you.
		if not _band_overlaps(int(entry.get("depth_min", 1)),
				int(entry.get("depth_max", 99)), band):
			continue
		var id: String = String(entry.get("id", ""))
		ids.append(id)
		weights[id] = int(entry.get("weight", 1))
	bag.configure(ids, weights)
	bag.from_state(memory.bag_state(bag_key))
	_bags[bag_key] = bag
	return bag


func _band_overlaps(dmin: int, dmax: int, band: String) -> bool:
	for raw: Variant in _bands:
		var b: Dictionary = raw as Dictionary
		if String(b.get("name", "")) != band:
			continue
		return dmin <= int(b.get("max", 99)) and dmax >= int(b.get("min", 1))
	return true


func _key_for_trigger(trigger: String) -> String:
	for key: Variant in _pools:
		if String(key).ends_with("/" + trigger):
			return String(key)
	return ""


func _note_args(trigger: String) -> Dictionary:
	var row: Dictionary = _notes.get(trigger, {}) as Dictionary
	if row.is_empty() or _now() - float(row.get("at", -9999.0)) > NOTE_TTL:
		return {}
	return row.get("args", {}) as Dictionary


func _now() -> float:
	if _synthetic_now >= 0.0:
		return _synthetic_now
	return float(Time.get_ticks_msec()) / 1000.0


# --------------------------------------------------------------- introspection --

## Pool key -> line count. The selftest's coverage check and the report's
## trigger catalogue both read this.
func pool_sizes() -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in _pools:
		out[String(key)] = (_pools[key] as Array).size()
	return out


## One pool's entries, for the budget selftest.
func pool_entries(key: String) -> Array:
	return _pools.get(key, []) as Array


## An entry as it will actually be spoken at `layer` with `ctx`: corruption tier
## picked, every slot filled. The one place that answer is computed, so the
## selftest bills the same string the player hears.
func render(entry: Dictionary, layer: int, ctx: Dictionary) -> String:
	var renderings: Array = entry.get("corruption_renderings", []) as Array
	var text: String = String(entry.get("text", ""))
	if not renderings.is_empty():
		text = String(renderings[clampi(MotherBarks.tier_for(layer), 0, renderings.size() - 1)])
	return _fill(text, ctx)


## The authored line with its slots filled and no corruption — the string the
## CEILING is measured against.
func render_canonical(entry: Dictionary, ctx: Dictionary) -> String:
	return _fill(String(entry.get("text", "")), ctx)


func entry(id: String) -> Dictionary:
	return _by_id.get(id, {}) as Dictionary


func all_ids() -> Array:
	return _by_id.keys()


## Drive the director from a synthetic clock and a synthetic slot table, so the
## simulation and the selftest can run a multi-hour session without a tree, a
## host, a layer or a single frame. `slots` is used verbatim as the context, so
## every slot is available and every line is eligible — which is the harshest
## case for the anti-repetition claim, not the kindest.
func set_synthetic(now: float, slots: Dictionary) -> void:
	_synthetic_now = now
	_synthetic = slots


# ----------------------------------------------------------------- simulation --
#
# The claim this milestone is really making is "you will not hear the same line
# twice in an evening", and a claim like that is worth exactly as much as the
# measurement behind it. So the anti-repetition machinery is not asserted by
# reading the code; it is asserted by running a synthetic multi-hour session
# through the real director, with the real corpus, and counting.
#
# The synthetic run is deliberately the HARSHEST case, not a friendly one:
#
#   * every slot is available, so every line in every pool is eligible and the
#     bags never get to look good by refusing lines;
#   * the register mix matches what `HauntDirector` actually asks for, weighted
#     the way its call sites are weighted, so `ambient` carries most of the load
#     exactly as it does in game;
#   * the cadence is the Director's own 22-40 s ambient tick, so an "hour" here
#     is an hour of wall clock, not an hour of bark opportunities.

## Register mix, as (category, share) — measured off the call sites in
## `HauntDirector`: the ambient cadence dominates, hunt rides the pacing spikes,
## kill_ack fires on a quarter of ordinary deletions, and address is rationed.
const SIM_MIX: Array[String] = [
	"ambient", "ambient", "ambient", "ambient", "ambient", "ambient",
	"ambient", "ambient", "ambient", "ambient", "ambient", "ambient",
	"hunt", "hunt", "hunt", "hunt",
	"kill_ack", "kill_ack",
	"mercy", "exfil", "sanctuary", "address",
]


## Run `minutes` of synthetic session and report the distribution.
##
## Returns everything the milestone promised to report:
##   spoken            lines she actually said
##   distinct          how many of them were different
##   first_repeat      the index of the first line heard twice (-1 = never)
##   worst_pool        the pool with the tightest repeat, and its gap
##   invariant_breaks  draws that repeated an id inside one bag cycle. Must be 0.
##   brace_leaks       rendered lines that still contained a `{`. Must be 0.
static func simulate(minutes: int, seed_value: int, carry: LoreMemory = null) -> Dictionary:
	var director: LoreDirector = LoreDirector.new()
	director.setup(seed_value)
	if carry != null:
		director.memory = carry
	else:
		director.memory = LoreMemory.new()
		director.memory.volatile = true
	if not director.is_loaded():
		return {"ok": false}

	# A full slot table: every line eligible, all of the time.
	director.set_synthetic(0.0, {
		"CALLSIGN": "VANE", "CREWMATE": "OKONKWO", "DEAD": "RESHET",
		"ROOM": "VAULT-07C", "DATA": "128", "CYCLES": "61", "CREW_COUNT": "3",
		"RUNS": "12", "DEEPEST": "17", "PATCH": "BIT ROT", "CREATURE": "THE HOUND",
		"N_descent": "7", "N_epitaph": "3",
	})

	# Conditions are DRIVEN, not observed. A headless process has no crew, no
	# hunter and an empty Cycles pool, so the live predicates answer with whatever
	# a dead world happens to imply — the first version of this measured a session
	# in which "you are starving" was true for three straight hours. Instead a
	# fraction of the observable triggers are made true at any moment and the set
	# turns over every couple of minutes, which is what a played session looks
	# like, and which actually exercises the selection path this milestone added.
	director._sim_mode = true
	var observable: Array[String] = []
	for key: Variant in director._pools:
		var trigger: String = String(key).split("/")[1]
		if not observable.has(trigger):
			observable.append(trigger)

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var condition_clock: float = 0.0

	var said: Array[String] = []
	var seen: Dictionary = {}
	var last_at: Dictionary = {}
	var pool_of: Dictionary = {}
	var cycle_seen: Dictionary = {}
	var invariant_breaks: int = 0
	var brace_leaks: int = 0
	var first_repeat: int = -1
	var worst_gap: int = 1 << 30
	var worst_pool: String = ""
	var refusals: int = 0

	var t: float = 0.0
	var layer: int = 1
	var horizon: float = float(minutes) * 60.0
	while t < horizon:
		t += rng.randf_range(22.0, 40.0)
		# Descend on roughly the DESIGN.md cadence: a ring every few minutes.
		if rng.randf() < 0.09:
			layer = mini(layer + 1, 30)
		director.set_synthetic(t, director._synthetic)
		# Roughly a fifth of the conditions true at any moment, resampled every two
		# minutes, at the same 1.2-3.0 strengths the real predicates return.
		if t >= condition_clock:
			condition_clock = t + 120.0
			director._sim_scores.clear()
			for trigger: String in observable:
				if rng.randf() < 0.2:
					director._sim_scores[trigger] = rng.randf_range(1.2, 3.0)
		var category: String = SIM_MIX[rng.randi_range(0, SIM_MIX.size() - 1)]
		var out: Dictionary = director.pick(category, layer,
				"VANE" if category == "address" else "")
		if out.is_empty():
			refusals += 1
			continue
		var id: String = String(out["id"])
		if String(out["text"]).contains("{"):
			brace_leaks += 1
		var stamp: String = "%s|%s|%d" % [String(out["bag"]), id, int(out["cycle"])]
		if cycle_seen.has(stamp):
			invariant_breaks += 1
		cycle_seen[stamp] = true
		if seen.has(id):
			if first_repeat < 0:
				first_repeat = said.size()
			var gap: int = said.size() - int(last_at[id])
			if gap < worst_gap:
				worst_gap = gap
				worst_pool = String(out["pool"])
		seen[id] = int(seen.get(id, 0)) + 1
		last_at[id] = said.size()
		pool_of[id] = String(out["pool"])
		said.append(id)

	var most: int = 0
	for id: Variant in seen:
		most = maxi(most, int(seen[id]))
	return {
		"ok": true,
		"minutes": minutes,
		"spoken": said.size(),
		"distinct": seen.size(),
		"first_repeat": first_repeat,
		"worst_pool": worst_pool,
		"worst_gap": -1 if worst_pool.is_empty() else worst_gap,
		"most_heard": most,
		"invariant_breaks": invariant_breaks,
		"brace_leaks": brace_leaks,
		"refusals": refusals,
		"closed_with": director.memory.closed_with,
		"opened_with": "" if said.is_empty() else said[0],
		"memory": director.memory,
	}


# ------------------------------------------------------------------ prewarm --

## Hand the synthesiser the lines she is most likely to say next.
##
## The voice cache is keyed by the WHOLE utterance, so warming a callsign on its
## own buys almost nothing — and this module is the only one in the game that
## knows which sentences are plausibly next, because it is the one holding the
## bags. The front of a bag is not a guess: those ids are the next draws unless a
## more specific trigger fires, and even then they are the next draws from that
## pool. So the front of the bag she just drew from, rendered exactly as it will
## be spoken, goes to the builder.
##
## Rendered through the same `_fill` the real bark uses, because a cache keyed on
## "{CALLSIGN}. GO UP." is a cache that never hits.
##
## Off the hot path by construction: this runs on a bark — once every twenty to
## forty seconds — never on a frame, and `prewarm_texts` hands the work to the
## synthesiser's own threads.
func _prewarm_next(key: String, layer: int, ctx: Dictionary, exclude: Array) -> void:
	var bag: LoreBag = _bags.get(_bag_key(key, layer)) as LoreBag
	if bag == null:
		return
	var category: String = key.split("/")[0]
	var texts: PackedStringArray = PackedStringArray()
	for id: String in bag.queue:
		if texts.size() >= PREWARM_DEPTH:
			break
		if not _can_speak(id, layer, ctx, exclude):
			continue
		var entry: Dictionary = _by_id.get(id, {}) as Dictionary
		var renderings: Array = entry.get("corruption_renderings", []) as Array
		var text: String = String(entry.get("text", ""))
		if not renderings.is_empty():
			var t: int = clampi(MotherBarks.tier_for(layer), 0, renderings.size() - 1)
			text = String(renderings[t])
		texts.append(_fill(text, ctx))
	if texts.is_empty():
		return
	MotherVoice.prewarm_texts(texts, MotherVoice.register_for_category(category, layer))


## The session opener. Warms the front of the pools she is most likely to reach
## for first, so her FIRST line of an intrusion is already built — which is the
## one that decides whether a player believes the voice.
##
## Called from `begin_run`, which is already hung off `Run.config_changed`, so
## this needs no wiring either. It lands on the layer seam, where there is
## already a loading pause.
func prewarm_opening(layer: int) -> void:
	if not _loaded:
		return
	var ctx: Dictionary = _context(layer, Net.crew_name(Net.local_id()))
	for trigger: String in ["ambient/ambient.idle", "descent/descent.arrive",
			"hunt/stalk.begin", "ambient/ambient.dark"]:
		if not _pools.has(trigger):
			continue
		# Builds the bag if it does not exist yet, which is what makes the front of
		# it meaningful this early.
		var bag: LoreBag = _bag_for(trigger, layer)
		if bag != null and not bag.is_empty():
			_prewarm_next(trigger, layer, ctx, [])
