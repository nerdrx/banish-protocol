class_name Directive
extends Control
## THE DIRECTIVE — one line that always answers "what am I supposed to be doing".
##
## Playtest, verbatim: "the player is wayyyyy to unguided about what to do". That
## is not a missing tutorial, it is a missing READOUT. The intrusion always knows
## what its own next step is — the state is all sitting in `Run` and `Cartography`
## already — and nothing in the interface was saying it out loud.
##
## ## Why this is not a quest log
##
## DESIGN.md's quiet-instrument rule (M4.9) is the constraint, not an obstacle:
## "every element must justify every frame it is visible", and a to-do list pinned
## to a horror HUD is exactly the MMO furniture the cassette instrument is defined
## against. So:
##
##   * ONE LINE. Never a stack, never a panel, never a checklist. The next step,
##     and nothing about the six steps after it.
##   * It rests DIM — structure colour, below the notice band, easy to not read.
##     It brightens for a beat when it CHANGES, which is the only moment it is
##     actually new information, and then it goes back to being furniture you can
##     ignore. Same surfacing grammar as every other cluster on this instrument.
##   * It reads as the program's own directive, not as a helper. "LOCATE THE DROP
##     SHAFT" is what your process is trying to do; "Find the exit!" is a game
##     talking to a person. This game does not do that.
##   * It says nothing the player has not discovered. The ladder below is keyed on
##     `Cartography` — the crew's own memory of the layer — so it can never point
##     at a shaft nobody has seen. It is a statement of your situation, never a
##     waypoint into unexplored geometry.
##
## ## And the hints, which are the other half of "unguided"
##
## Three or four verbs cannot be discovered by pressing things: TAB, Q, "hold E
## and then TYPE at a command terminal". Those get a SECOND line, shown ONCE EVER
## per program (`GameState.hints`) on the first relevant encounter, and then never
## again. A hint that repeats is a tutorial; a hint that fires once at the moment
## it is useful is a manual page delivered at the only time anybody would read it.
##
## ## Read-only, by contract
##
## This widget consults `Run` and `Cartography` and writes to neither — the
## netcode agent owns `run_state.gd` for this pass. Everything below is a pure
## function of state those two already publish, which is also why it needs no
## signals: there is no event to miss, because there is no state of its own to get
## out of step.

## Geometry. Bottom-centre, in the band above the notice line (-96) and below the
## reticle. Anchored 0..1 with margins rather than a hard width, so it gets
## whatever room the instrument box has at any aspect and any UI SCALE and can
## never be the element that pokes out of the tube.
const BAND_TOP: float = -150.0
const BAND_BOTTOM: float = -100.0
const SIDE_MARGIN: float = 40.0

## How long a changed directive stays lit before falling back to furniture.
const SURFACE_TIME: float = 2.6
## Resting alpha. Legible if you look for it, silent if you do not.
const REST_ALPHA: float = 0.60

## How long a one-shot hint holds, and how long its fade takes.
const HINT_HOLD: float = 7.0
const HINT_FADE: float = 1.4
## A hint never interrupts another hint; the queue drains one at a time.
const HINT_GAP: float = 1.2

## How often the world is asked questions that need a node lookup (the command
## terminal proximity test). Four times a second is far more often than a player
## can walk into a room and far cheaper than doing it per frame.
const PROBE_INTERVAL: float = 0.25
## How close a command terminal has to be before it is worth explaining.
const TERMINAL_HINT_RANGE: float = 7.0

## The one-shot hints, in the order they are allowed to fire if two ever come up
## in the same frame. Keys are stable strings — they are written into the program
## file, so renaming one re-shows it to every existing player.
const HINT_HUB: String = "hub_rig"
const HINT_MAP: String = "map_key"
const HINT_SHAFT: String = "drop_shaft"
const HINT_COMPILER: String = "compiler"
const HINT_TERMINAL: String = "command_terminal"
const HINT_SUBROUTINE: String = "subroutine_key"

## Every key, for the self-test to walk. A hint added to `hint_text` and not to
## this list is a hint nothing asserts; a key here with no text is caught by the
## same check. The pair is what makes "no hint ships blank" provable rather than
## reviewed.
const HINT_KEYS: Array[String] = [
	"hub_rig", "map_key", "drop_shaft", "compiler", "command_terminal",
	"subroutine_key",
]

## The band is one line of 13 px type across the instrument box. Anything longer
## than this ellipsises, which on a once-ever hint means a verb a player never got.
const HINT_MAX: int = 84

var _line: Label = null
var _hint: Label = null
var _last: String = ""
var _surface: float = 0.0
var _hint_clock: float = 0.0
var _hint_gap: float = 0.0
var _probe: float = 0.0
## Hint keys waiting to be said, in the order they came up.
var _queue: PackedStringArray = PackedStringArray()
## Seconds this run has been live, so the map hint waits until the player has
## something to look at a map of.
var _live: float = 0.0


static func create() -> Directive:
	var node: Directive = Directive.new()
	node.name = "Directive"
	return node


func _ready() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	anchor_top = 1.0
	anchor_bottom = 1.0
	anchor_left = 0.0
	anchor_right = 1.0
	offset_left = SIDE_MARGIN
	offset_right = -SIDE_MARGIN
	offset_top = BAND_TOP
	offset_bottom = BAND_BOTTOM
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# The hint sits ABOVE the directive, so the directive never moves. A readout
	# that jumps when something else appears is a readout you have to re-find.
	_hint = _label(UiFx.SYSTEM_HOT, 0.0, 22.0)
	_line = _label(UiFx.CAPTION, 26.0, 48.0)
	set_process(true)


## One of the two rows, stretched across this widget's whole width.
##
## Every offset is written EXPLICITLY, and that is not belt-and-braces. This
## widget shipped invisible for one round of captures because it used
## `set_anchors_preset(PRESET_TOP_WIDE)` and then set only the vertical offsets:
## with `keep_offsets` false the call rewrites the HORIZONTAL offsets to preserve
## the control's CURRENT width, and a fresh `Label` with `clip_text` on has a
## minimum width of 1 px. Anchors said full width, offsets said one pixel, and the
## text was clipped to a column you cannot see. Anchors and offsets are one
## statement; writing half of it is writing none of it.
func _label(colour: Color, top: float, bottom: float) -> Label:
	var label: Label = Label.new()
	label.anchor_left = 0.0
	label.anchor_right = 1.0
	label.anchor_top = 0.0
	label.anchor_bottom = 0.0
	label.offset_left = 0.0
	label.offset_right = 0.0
	label.offset_top = top
	label.offset_bottom = bottom
	label.add_theme_font_size_override("font_size", UiFx.FONT_SMALL)
	label.add_theme_color_override("font_color", colour)
	# PT2 legibility: a tight dark outline and no chromatic fringe, which is what
	# lets 13 px body copy survive a lit wall behind it.
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.01, 0.02, 0.9))
	label.add_theme_constant_override("outline_size", 4)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = ""
	label.modulate.a = 0.0
	add_child(label)
	return label


func _process(delta: float) -> void:
	_live += delta
	var wanted: String = _directive()
	if wanted.is_empty():
		_line.modulate.a = 0.0
		_hint.modulate.a = 0.0
		_last = ""
		return

	if wanted != _last:
		# The only moment this line is news. One rise and fall, no repeat, so there
		# is nothing here for a rate governor to bound — and it is comfort-scaled
		# anyway, which under Reduced Flashing simply means the line arrives at its
		# resting brightness instead of arriving lit.
		_last = wanted
		_surface = SURFACE_TIME
		_line.text = wanted
	_surface = maxf(_surface - delta, 0.0)
	var lit: float = clampf(_surface / SURFACE_TIME, 0.0, 1.0) * A11y.effect_scale("notice")
	_line.modulate.a = REST_ALPHA + (1.0 - REST_ALPHA) * lit
	_line.add_theme_color_override("font_color",
			UiFx.CAPTION.lerp(UiFx.SYSTEM_HOT, lit))

	_probe = maxf(_probe - delta, 0.0)
	if _probe <= 0.0:
		_probe = PROBE_INTERVAL
		_collect_hints()
	_tick_hint(delta)


# ---------------------------------------------------------------- directive --

## The ladder. Ordered by URGENCY, not by narrative: the first line that applies
## is the one shown, so "a crewmate is face down" always outranks "there is a
## shaft over there", because it does.
##
## Every branch names a VERB the player can act on this second, with the key that
## does it where the key is not obvious. Nothing here reads as a hint — a hint is
## about the controller, a directive is about the situation.
func _directive() -> String:
	if not Run.configured or Run.run_over or Run.descending:
		return ""
	if not Run.local_alive():
		if Run.local_corrupted():
			return "▸  CORRUPTED  ·  A CREWMATE MUST REACH YOU AND HOLD E"
		return "▸  PROCESS DELETED"

	if Run.in_hub:
		if Run.injecting:
			return "▸  INJECTION IN %02d  ·  HOLD E AT THE RIG TO ABORT" % int(
					ceilf(Run.inject_remaining))
		if not Run.crew_mustered():
			return "▸  THE PARTITION  ·  CREW ON THE PAD  %d/%d" % [
				Run.muster_inside, Run.muster_total]
		return "▸  THE PARTITION  ·  HOLD E AT THE INJECTION RIG  ·  LAYER %02d" % \
				Run.injection_layer

	if Run.exfil_calling:
		return "▸  UPLINK CALLED  ·  STAND ON THE PAD  ·  %02d" % int(
				ceilf(Run.exfil_remaining))

	# A downed crewmate outranks everything the layer has to offer, including the
	# shaft — which will not take the crew down until they are back up anyway.
	if not Run.crew_intact():
		return "▸  CREWMATE CORRUPTED  ·  REACH THEM AND HOLD E"

	if Run.starved():
		return "▸  POOL EMPTY  ·  TAP A SIPHON OR GET OUT"
	if Run.fraction() <= 0.25:
		return "▸  POOL LOW  ·  TAP A SIPHON"

	# The backdoor rings. `item_position` answers INF for a layer that has no node,
	# so "is this a backdoor layer" needs no access to the graph.
	var has_node: bool = Cartography.item_position(Cartography.KIND_NODE, 0).is_finite()
	if Run.backdoor_rooted:
		return "▸  BACKDOOR INSTALLED  ·  CALL THE UPLINK, OR TAKE THE SHAFT DEEPER"
	if has_node and Cartography.knows_item(Cartography.KIND_NODE, 0):
		return "▸  MAINTENANCE NODE LOCATED  ·  HOLD E TO ROOT IT"
	if has_node:
		return "▸  BACKDOOR NODE ON THIS RING  ·  SWEEP FOR IT"

	# Ordinary layers. The haul comes before the exit, because a shaft taken with
	# an empty buffer is a layer spent for nothing.
	var carried: int = Run.local_buffered()
	if Cartography.knows_item(Cartography.KIND_SHAFT, 0):
		if carried <= 0:
			return "▸  DROP SHAFT LOCATED  ·  SECURE DATA FIRST"
		return "▸  DROP SHAFT LOCATED  ·  HOLD E TO DESCEND  ·  %d CHIPS CARRIED" % carried
	if carried <= 0:
		return "▸  SWEEP THE LAYER  ·  COLLECT DATA, LOCATE THE DROP SHAFT"
	return "▸  %d CHIPS CARRIED  ·  LOCATE THE DROP SHAFT" % carried


# -------------------------------------------------------------------- hints --

## What each key says, once, ever. Deliberately shaped like a manual page and not
## like encouragement: the key, then the verb, then what it is for.
static func hint_text(key: String) -> String:
	match key:
		HINT_HUB:
			return "THE PARTITION  ·  THE CREW'S OWN ROOM BEHIND HER FIREWALL. THE RIG DIVES."
		HINT_MAP:
			return "TAB  ·  HOLD FOR THE LAYER MAP AND YOUR CARRIED PATCHES"
		HINT_SHAFT:
			return "DROP SHAFT  ·  HOLD E TO TAKE THE WHOLE CREW ONE RING DEEPER"
		HINT_COMPILER:
			return "COMPILER  ·  HOLD E TO COMPILE DATA INTO YOUR SOURCE. IT IS PERMANENT."
		HINT_TERMINAL:
			return "COMMAND TERMINAL  ·  HOLD E, THEN TYPE. START WITH: LIST DATA"
		HINT_SUBROUTINE:
			return "Q  ·  RUN THE SUBROUTINE IN YOUR SLOT. IT BILLS THE SHARED POOL."
	return ""


## Which hints have become true since the last probe. Queued rather than shown, so
## two arriving together are read one after the other instead of overwriting each
## other — which is what happens when a player walks into the room with the shaft
## AND the compiler in it.
func _collect_hints() -> void:
	if Run.in_hub:
		_want(HINT_HUB)
		return
	if not Run.configured or Run.run_over or not Run.local_alive():
		return
	# The map is worth explaining once there is a layer worth looking at, not on
	# the frame the player spawns holding nothing and standing in one room.
	if _live > 18.0:
		_want(HINT_MAP)
	if Cartography.knows_item(Cartography.KIND_SHAFT, 0):
		_want(HINT_SHAFT)
	if Cartography.knows_item(Cartography.KIND_COMPILER, 0) \
			or Cartography.knows_item(Cartography.KIND_COMPILER, 1):
		_want(HINT_COMPILER)
	# A subroutine is a key nobody presses by accident. Only once one is actually
	# in the slot — telling a player about a verb they do not own is an advert.
	if not Subs.local_equipped().is_empty():
		_want(HINT_SUBROUTINE)
	_probe_terminal()


## The command terminal is the one verb with a second half — you hold E and then
## you TYPE — and no prompt in the world can say the second half. So it is a
## proximity hint: near enough to walk up to, said once, gone forever.
func _probe_terminal() -> void:
	if GameState.hint_seen(HINT_TERMINAL):
		return
	var body: Node = Net.get_player(Net.local_id())
	if body == null or not is_instance_valid(body):
		return
	var here: Vector3 = (body as Node3D).global_position
	if not here.is_finite():
		return
	for node: Node in get_tree().get_nodes_in_group("command_terminals"):
		var prop: Node3D = node as Node3D
		if prop == null or not is_instance_valid(prop):
			continue
		if prop.global_position.distance_to(here) <= TERMINAL_HINT_RANGE:
			_want(HINT_TERMINAL)
			return


## Queue `key` if this program has never been shown it. The SPEND happens here
## rather than when the line is drawn, deliberately: a player who walks past the
## shaft and dies before the queue drains has still been told, and re-telling them
## on the next run is the exact behaviour a once-ever hint exists to prevent.
func _want(key: String) -> void:
	if GameState.hint_seen(key) or _queue.has(key):
		return
	if not GameState.spend_hint(key):
		return
	_queue.append(key)


func _tick_hint(delta: float) -> void:
	if _hint_clock > 0.0:
		_hint_clock -= delta
		_hint.modulate.a = clampf(_hint_clock / HINT_FADE, 0.0, 1.0)
		if _hint_clock <= 0.0:
			_hint.text = ""
			_hint_gap = HINT_GAP
		return
	_hint_gap = maxf(_hint_gap - delta, 0.0)
	if _hint_gap > 0.0 or _queue.is_empty():
		return
	var key: String = _queue[0]
	_queue.remove_at(0)
	var text: String = hint_text(key)
	if text.is_empty():
		return
	_hint.text = text
	_hint.modulate.a = 1.0
	_hint_clock = HINT_HOLD
