class_name IntegrityReadout
extends Control
## The enemy integrity readout — "how hurt is that thing", as an instrument.
##
## The first friend playtest asked for health bars ("not good enough feedback
## when an enemy is hit maybe add health bars?"), and the honest reading of that
## is not "add health bars", it is "I cannot tell whether I am winning". A
## generic MMO bar would answer the question and lose the game's whole interface
## argument, so this answers it the way DESIGN.md's shell would: as one more
## dot-matrix readout on the same phosphor CRT the Cycles ring and the reticle
## live on — an **integrity readout on a target the crew's tooling has resolved**,
## not a floating status effect.
##
## ## What it is
##
## A short row of discrete SEGMENTS with a numeral beside it, drawn at the
## creature's screen position, inside the CRT tube like everything else — so it
## picks up the scanlines, the curvature and the phosphor ghost, which is most of
## why it reads as part of the instrument rather than as a sprite pasted on the
## world.
##
## ## The quiet-instrument rule (DESIGN.md M4.9)
##
## "Every element must justify every frame it is visible." A readout appears for
## exactly two reasons and then goes away:
##
##   * the crew DAMAGED it — anyone in the crew, which is why this reads the
##     replicated `sync_integrity` and not a local hit event;
##   * the local player is AIMING at it — the crosshair is on it and the line is
##     clear, so it is the thing they are about to shoot.
##
## Nothing else surfaces one. There is no "all enemies always" mode, no
## permanently visible bars, and at most `MAX_READOUTS` on screen at once — a
## room with nine Scrubbers in it is a room where the interface must not become
## the fight.
##
## ## Colour is never the only channel (DESIGN.md pillar 7)
##
## Three channels carry the same number: the COUNT of filled segments, the
## NUMERAL, and the colour. A player who cannot separate amber from red still
## reads eleven segments falling to two and "18". The colour shift is the
## redundant third, and it only exists so a glance across a dark room lands.
##
## ## Multiplayer
##
## Health is host-authoritative and only the FRACTION is replicated
## (`Antivirus.sync_integrity`, ON_CHANGE). Every peer draws from that same
## number, so a client watching the host shoot a Sentinel sees the same readout
## fall that the host does, and a client's own hits move it on the host's screen
## the moment the host's authoritative damage lands. Nothing here is predicted.

## Never more than this many at once. The interface is not allowed to become the
## fight; three is the most a player can read in a firefight anyway.
const MAX_READOUTS: int = 3

## Segments in the bar. Twelve divides into halves, thirds and quarters, so a
## glance resolves "about half" and "nearly dead" without counting.
const SEGMENTS: int = 12
const SEGMENT_GAP: float = 2.0

## Bar geometry at REFERENCE_DISTANCE, in pixels, and how far it scales.
##
## Distance-scaled rather than fixed: a readout that stays the same size as its
## creature shrinks becomes a label floating in the room. Clamped at both ends so
## a point-blank Sentinel does not get a bar across half the screen and a
## Scrubber at twenty metres still has something readable.
const REFERENCE_DISTANCE: float = 8.0
const BAR_WIDTH: float = 74.0
const BAR_HEIGHT: float = 5.0
const SCALE_RANGE: Vector2 = Vector2(0.76, 1.35)

## How high above the creature's own aim point the bar floats, in world metres.
const WORLD_LIFT: float = 0.55

## Relevance: how long a readout stays up after the last thing that justified it,
## and how long it takes to fade once that runs out.
const HOLD_TIME: float = 2.0
const FADE_TIME: float = 0.55


## `--hud-state readout` pins every bar here: below half, above the critical
## band, so one frame shows the lit segments, the empty remainder and the amber
## it lives in most of the time.
const STAGED_FRACTION: float = 0.58

## Below this fraction the bar also goes hostile. The colour is the THIRD channel
## (see the header) — the segment count and the numeral have already said it.
const CRITICAL_FRACTION: float = 0.34



class Entry extends RefCounted:
	var node: Node3D = null
	## Last integrity we saw, so a DROP can be detected locally on every peer
	## from the replicated value alone — no damage RPC, and a client sees a
	## crewmate's hits land because the host's number moved.
	var seen: float = 1.0
	## Seconds of relevance left before the fade starts.
	var hold: float = 0.0
	var alpha: float = 0.0
	## Screen position and scale, resolved once a frame in `_refresh`.
	var at: Vector2 = Vector2.ZERO
	var scale: float = 1.0
	var visible_now: bool = false


## instance id -> Entry.
var _entries: Dictionary = {}
var _font: Font = null
var _visible: Array[Entry] = []


func _ready() -> void:
	# Anchors AND offsets: a Control built in code starts at zero size, and
	# `set_anchors_preset` alone leaves it there — which draws nothing, silently,
	# forever.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = load("res://assets/fonts/ui_font.tres") as Font


## The 3D lens, found the way `CaptionBus` finds it: through the tree ROOT.
##
## `get_viewport()` from inside the HUD returns the interface's own viewport,
## which has no 3D camera in it at all — the world is rendered by the root
## window. Asking the wrong viewport does not error; it returns null and the
## readouts quietly never appear, which is exactly how this cost an hour.
func _camera() -> Camera3D:
	var root: Viewport = get_tree().root.get_viewport()
	return root.get_camera_3d() if root != null else null


func _process(delta: float) -> void:
	_refresh(delta)
	queue_redraw()


## One pass over every process in the layer: notice new wounds, decide who is
## relevant, resolve where they are on screen, and keep the best few.
func _refresh(delta: float) -> void:
	var camera: Camera3D = _camera()
	var live: Array[Node] = get_tree().get_nodes_in_group(Antivirus.GROUP)
	var aimed: Node3D = _aim_target(camera, live)

	var seen_ids: Dictionary = {}
	for node: Node in live:
		var creature: Node3D = node as Node3D
		if creature == null or not is_instance_valid(creature):
			continue
		var id: int = creature.get_instance_id()
		seen_ids[id] = true
		var entry: Entry = _entries.get(id) as Entry
		if entry == null:
			entry = Entry.new()
			entry.node = creature
			entry.seen = float(creature.get("sync_integrity"))
			_entries[id] = entry

		var integrity: float = float(creature.get("sync_integrity"))
		# A DROP is the damage event, on every peer, without a damage packet.
		if integrity < entry.seen - 0.0001:
			entry.hold = HOLD_TIME
		entry.seen = integrity
		if creature == aimed:
			entry.hold = HOLD_TIME
		# `--hud-state readout`: hold every readout open at a fixed fraction, so
		# the element can be photographed. A capture cannot make an AI walk into
		# breaker range on the frame the shutter opens — which is exactly the
		# "unphotographable feature is one nobody checks" trap this file's own
		# neighbours (see Debug's --hud-state) exist to avoid. Display only: the
		# creature's real integrity is untouched.
		if Debug.hud_state == "readout":
			entry.hold = HOLD_TIME
			entry.seen = STAGED_FRACTION
		# A dead process has nothing to report; its readout leaves with it rather
		# than hanging over the shatter.
		if bool(creature.get("sync_dead")):
			entry.hold = 0.0
			entry.alpha = maxf(entry.alpha - delta / FADE_TIME * 3.0, 0.0)

		entry.hold = maxf(entry.hold - delta, 0.0)
		var want: float = 1.0 if entry.hold > 0.0 else 0.0
		entry.alpha = move_toward(entry.alpha, want,
				delta / (0.12 if want > 0.0 else FADE_TIME))
		entry.visible_now = false
		if entry.alpha <= 0.002 or camera == null:
			continue
		entry.visible_now = _resolve_screen(entry, camera)

	for id: int in _entries.keys():
		if not seen_ids.has(id):
			_entries.erase(id)

	_visible.clear()
	for entry: Entry in _entries.values():
		if entry.visible_now:
			_visible.append(entry)
	# Nearest first — if the cap bites, it bites on the things furthest away and
	# least likely to be what the player is asking about.
	_visible.sort_custom(func(a: Entry, b: Entry) -> bool: return a.scale > b.scale)
	if _visible.size() > MAX_READOUTS:
		_visible.resize(MAX_READOUTS)


## Where the bar goes and how big it is, or false if it is off screen / behind
## the lens.
func _resolve_screen(entry: Entry, camera: Camera3D) -> bool:
	var anchor: Vector3 = entry.node.call("aim_point") + Vector3.UP * WORLD_LIFT
	if camera.is_position_behind(anchor):
		return false
	entry.at = camera.unproject_position(anchor)
	var view: Vector2 = size
	if entry.at.x < -60.0 or entry.at.y < -40.0 \
			or entry.at.x > view.x + 60.0 or entry.at.y > view.y + 40.0:
		return false
	var distance: float = camera.global_position.distance_to(anchor)
	entry.scale = clampf(REFERENCE_DISTANCE / maxf(distance, 0.5),
			SCALE_RANGE.x, SCALE_RANGE.y)
	return true


## The one process the local player is pointing at, or null.
##
## **The same selection the weapon makes**, not a bespoke cone: `pick_target` is
## the function `Player._update_breaker` calls to decide what a shot lands on, so
## a readout surfaces on exactly the thing the next trigger pull would hit — and
## on nothing when the answer is "you would miss". That is what makes it a
## readout rather than an enemy tracker; it is the crew's own tooling reporting
## what it has resolved, which is the whole diegetic claim.
##
## It carries the line-of-sight ray with it, so a readout can never draw through
## a wall. Reach is the local program's OWN breaker range, Optics tiers included,
## because a target you cannot reach is not a target you have resolved.
func _aim_target(camera: Camera3D, _live: Array[Node]) -> Node3D:
	if camera == null or not Run.local_running():
		return null
	return Antivirus.pick_target(get_tree(),
			camera.get_world_3d().direct_space_state,
			camera.global_position, -camera.global_transform.basis.z,
			float(Modules.loadout(Net.local_id())["range"]))


func _draw() -> void:
	for entry: Entry in _visible:
		_draw_one(entry)


## One readout: a segment bar, its empty remainder, and the numeral.
##
## Drawn rather than built out of nodes, for the same reason `Crosshair` is: this
## is up to three of these appearing and vanishing several times a second, and a
## node per segment would be 36 Controls being created and freed in a firefight.
func _draw_one(entry: Entry) -> void:
	var fraction: float = clampf(entry.seen, 0.0, 1.0)
	var width: float = BAR_WIDTH * entry.scale
	var height: float = maxf(BAR_HEIGHT * entry.scale, 2.0)
	var origin: Vector2 = entry.at - Vector2(width * 0.5, height * 0.5)

	# The instrument's own phosphor — the local player's accent, clamped into the
	# readable band by UiFx so a player who picked something lurid still gets a
	# legible instrument. Hostile only when it is nearly dead, and never as the
	# only thing saying so.
	var lit: Color = UiFx.clamp_phosphor(UiFx.SYSTEM)
	if fraction <= CRITICAL_FRACTION:
		lit = UiFx.HOSTILE
	var dark: Color = UiFx.DIM
	lit.a = entry.alpha
	dark.a = entry.alpha * 0.30

	var step: float = width / float(SEGMENTS)
	var gap: float = minf(SEGMENT_GAP * entry.scale, step * 0.4)
	# Ceil, so a creature that is alive at all keeps one lit segment: "nearly
	# dead" and "dead" must not look the same on a readout you are shooting at.
	var filled: int = ceili(fraction * float(SEGMENTS)) if fraction > 0.0 else 0
	for i: int in SEGMENTS:
		var cell: Rect2 = Rect2(
				origin + Vector2(step * float(i), 0.0),
				Vector2(maxf(step - gap, 1.0), height))
		if i < filled:
			draw_rect(cell, lit)
		else:
			# The empty remainder is drawn, not omitted: the TOTAL is half of the
			# segment-count channel, and a bar you cannot see the end of is a bar
			# with no scale on it.
			draw_rect(cell, dark)

	# The numeral. The colour-blind-safe second channel, and the one a player
	# actually calls out over voice chat.
	if _font != null:
		var text: String = "%03d" % int(round(fraction * 100.0))
		var px: int = maxi(int(11.0 * entry.scale), 8)
		var label: Color = lit
		label.a = entry.alpha * 0.9
		draw_string(_font, origin + Vector2(width + 5.0 * entry.scale, height),
				text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px, label)
