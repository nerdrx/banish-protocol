class_name PatchStrip
extends Control
## The patch strip: a compact row of phosphor glyphs above the Cycles gauge
## saying what this instance of your program has had injected into it, and how
## many of each.
##
## ## Why it is a whole self-contained Control rather than nine edits to the HUD
##
## Exactly the argument `SubroutineSlot` made one milestone ago, and it has only
## got stronger: `hud.gd` is 2100 lines with eight surfaces, a cluster list, a
## boot sequence, a depth pass, a glitch rig and a speck field, M9 lands beside
## two other agents in the same working copy, and a widget that can be added with
## ONE line and removed with one line is a widget that cannot take somebody else's
## milestone down with it. It is also genuinely one thing: a row of cells, each a
## glyph, a numeral and a rarity bracket.
##
## What it gives up by not being in `Hud._clusters` is the shared parallax lag and
## the damage-flinch jitter. It takes the cluster TILT itself, which is the part
## that reads at a glance.
##
## ## The quiet-instrument rule (DESIGN.md M4.9)
##
## "Every element must justify every frame it is visible." A carried-item list is
## the classic way to lose that argument — a permanent inventory bar is exactly
## the sort of MMO furniture the cassette instrument is defined against. So:
##
##   * carrying nothing, it draws NOTHING AT ALL. A player who has not found a
##     patch has no strip, no empty sockets and no question on their screen.
##   * carrying something, it rests as a dim row of glyphs — shape and position
##     language, no words, no plate.
##   * it SURFACES on a real change: a patch landing, a stack ticking up.
##   * it EXPANDS to the full named list only while the map is held (TAB), which
##     is the same "you are holding a key and standing still" cost the Minimap
##     charges for its own expanded read. Nothing is hidden; the detail simply has
##     a price, and the price is the same one the map already established.
##
## ## Safety (DESIGN.md pillar 7)
##
## Nothing here flashes. The arrival mark on a fresh stack is a single decaying
## bracket — one monotone rise-and-fall, so there is no second peak for a rate
## governor to govern, which is why it has none rather than by omission — and it
## is scaled by `A11y.flash_scale` anyway, so Reduced Flashing removes it.
##
## Colour is never the only channel. Rarity is carried by a BRACKET SHAPE (none /
## underline / full brackets) and by the tier word in the expanded list, before
## it is carried by a hue; the stack count is a numeral, not a bar length.

## Geometry. Bottom-left anchored, sitting in the band above the Cycles gauge
## (which tops out at y = -212) and left of the minimap, which lives on the other
## side of the screen entirely. 24..444 x -266..-218 is free at every aspect the
## instrument box supports.
const STRIP_LEFT: float = 24.0
const STRIP_TOP: float = -266.0
const STRIP_WIDTH: float = 420.0
const STRIP_HEIGHT: float = 48.0

## One cell of the resting row.
const CELL_WIDTH: float = 34.0
const CELL_HEIGHT: float = 40.0
const GLYPH_SIZE: int = 19
const COUNT_SIZE: int = 12

## The expanded list, held open on the map key.
const ROW_HEIGHT: float = 20.0
const ROW_GLYPH_SIZE: int = 15
const ROW_TEXT_SIZE: int = 13
const EXPAND_RATE: float = 9.0

## How long the strip stays up after a patch lands.
const HOLD_GAINED: float = 2.6
## The arrival mark: a bracket that expands and fades, once, on the cell that
## just changed.
const MARK_TIME: float = 0.7
const MARK_TRAVEL: float = 5.0
## Resting alpha. Low enough to be furniture, high enough to be countable.
const REST_ALPHA: float = 0.20

var _surface: UiFx.Surface = null
var _font: Font = null
## 0 = row of glyphs, 1 = named list. Chased so it morphs rather than cuts.
var _expand: float = 0.0
## Patch id -> seconds left on its arrival mark.
var _marks: Dictionary = {}
## Last seen stack counts, so a change can be detected without a signal per cell.
var _seen: Dictionary = {}
var _alpha: float = REST_ALPHA


static func create() -> PatchStrip:
	var strip: PatchStrip = PatchStrip.new()
	strip.name = "PatchStrip"
	return strip


func _ready() -> void:
	# Bottom-left anchored with negative offsets and `grow_vertical = 0` — the same
	# idiom every instrument cluster in `hud.tscn` uses, so it moves with the safe
	# area rather than against it. Never write `position` on this: the instrument
	# box is re-solved on every viewport change and an absolute position would be
	# silently wrong at 32:9.
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = STRIP_LEFT
	offset_top = STRIP_TOP
	offset_right = STRIP_LEFT + STRIP_WIDTH
	offset_bottom = STRIP_TOP + STRIP_HEIGHT
	grow_vertical = 0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The same half-degree cant every other cluster wears, so the instrument reads
	# as a physical panel rather than as a flat overlay.
	pivot_offset = Vector2(STRIP_WIDTH * 0.5, STRIP_HEIGHT * 0.5)
	rotation = deg_to_rad(-UiFx.CLUSTER_TILT_DEG)

	_font = load("res://assets/fonts/ui_font.tres") as Font
	_surface = UiFx.Surface.new(HOLD_GAINED)
	Patches.patch_gained.connect(_on_gained)
	Patches.carried_changed.connect(func() -> void: _surface.surface(HOLD_GAINED))
	set_process(true)


func _on_gained(peer_id: int, patch_id: String, _stacks: int) -> void:
	# A crewmate's pickup is THEIR business — patches are per-player and the crew
	# negotiates over voice, so somebody else finding one does not open your
	# instrument. The kill feed and the world burst already told you it happened.
	if peer_id != Net.local_id():
		return
	_marks[patch_id] = MARK_TIME
	_surface.surface(HOLD_GAINED)


func _process(delta: float) -> void:
	var ids: Array[String] = Patches.ordered_ids(Net.local_id())
	if ids.is_empty():
		# Nothing carried: the strip is not merely dark, it is absent.
		if modulate.a != 0.0:
			modulate.a = 0.0
		_seen.clear()
		return

	# Surface on any real change in the carried table, including one that arrived
	# from the host's snapshot rather than through the gained signal (a join, a
	# late packet). Cheap: one integer compare per carried patch.
	for id: String in ids:
		var count: int = Patches.local_stacks(id)
		if int(_seen.get(id, -1)) != count:
			_seen[id] = count
			_surface.surface(HOLD_GAINED)

	# Held on the map key, exactly like `Minimap.expanded` and read from the same
	# action rather than from the map itself — the widget stays self-contained and
	# the two agree because they are asking the same question.
	var open: bool = Input.is_action_pressed("map") and not Debug.lock_input
	if Debug.automated and (Debug.hud_state == "map" or Debug.hud_state == "patches"):
		open = true
		_surface.pin()
	_expand = UiFx.chase(_expand, 1.0 if open else 0.0, EXPAND_RATE, delta)

	for id: Variant in _marks.keys():
		_marks[id] = maxf(float(_marks[id]) - delta, 0.0)

	# Grow UPWARD when expanded: the strip is bottom-anchored and the row above it
	# is empty screen, while the row below it is the Cycles gauge.
	var rows: float = float(ids.size()) * ROW_HEIGHT + 22.0
	var height: float = lerpf(STRIP_HEIGHT, maxf(rows, STRIP_HEIGHT), _expand)
	offset_top = STRIP_TOP + STRIP_HEIGHT - height
	offset_bottom = STRIP_TOP + STRIP_HEIGHT
	pivot_offset = Vector2(STRIP_WIDTH * 0.5, height * 0.5)

	var lit: float = _surface.tick(delta)
	modulate.a = 1.0
	# The strip never disappears entirely while something is carried — it decays to
	# a dim row, which is the shape-and-position language the quiet instrument rule
	# asks elements to yield to.
	_alpha = REST_ALPHA + (1.0 - REST_ALPHA) * maxf(lit, _expand)
	queue_redraw()


func _draw() -> void:
	if _font == null:
		return
	var ids: Array[String] = Patches.ordered_ids(Net.local_id())
	if ids.is_empty():
		return
	_draw_row(ids)
	if _expand > 0.01:
		_draw_list(ids)


## The resting read: one cell per carried patch, glyph over numeral, in catalogue
## order so a glyph never moves once it is on the strip.
func _draw_row(ids: Array[String]) -> void:
	# Fades out as the list takes over, so the two are never both fully drawn.
	var row_alpha: float = _alpha * (1.0 - _expand)
	if row_alpha <= 0.01:
		return
	var base: float = size.y - CELL_HEIGHT
	for i: int in ids.size():
		var id: String = ids[i]
		var left: float = float(i) * CELL_WIDTH
		var cell: Rect2 = Rect2(Vector2(left, base), Vector2(CELL_WIDTH, CELL_HEIGHT))
		var tier: int = Patches.rarity(id)
		var hue: Color = PatchFx.rarity_colour(tier)

		_draw_bracket(cell, tier, hue, row_alpha)

		var mark: String = Patches.glyph(id)
		var extent: Vector2 = _font.get_string_size(mark, HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, GLYPH_SIZE)
		var glyph_colour: Color = hue
		glyph_colour.a = row_alpha
		draw_string(_font, Vector2(cell.position.x + (CELL_WIDTH - extent.x) * 0.5,
				cell.position.y + 21.0), mark, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				GLYPH_SIZE, glyph_colour)

		# The stack count as a NUMERAL. Never a pip row and never a bar: the whole
		# mechanic is "how many of these do I have", and a number is the only
		# rendering of six that reads as six at a glance.
		var count: String = "%d" % Patches.local_stacks(id)
		var count_extent: Vector2 = _font.get_string_size(count,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, COUNT_SIZE)
		var count_colour: Color = UiFx.TEXT
		count_colour.a = row_alpha
		draw_string(_font, Vector2(cell.position.x + (CELL_WIDTH - count_extent.x) * 0.5,
				cell.position.y + CELL_HEIGHT - 3.0), count,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, COUNT_SIZE, count_colour)

		_draw_mark(id, cell, hue, row_alpha)


## RARITY AS A SHAPE (pillar 7: colour is never the only channel).
##   STABLE    nothing — the common case is the quiet case.
##   UNSTABLE  a rule under the cell.
##   KERNEL    full brackets either side. A build-defining patch is bracketed on
##             the instrument the way a warning is, because it is one.
func _draw_bracket(cell: Rect2, tier: int, hue: Color, alpha: float) -> void:
	var ink: Color = hue
	ink.a = alpha * 0.8
	if tier == Balance.PATCH_TIER_UNSTABLE:
		draw_line(Vector2(cell.position.x + 5.0, cell.end.y - 1.0),
				Vector2(cell.end.x - 5.0, cell.end.y - 1.0), ink, 1.4)
		return
	if tier != Balance.PATCH_TIER_KERNEL:
		return
	var inset: float = 3.0
	var tick: float = 5.0
	for side: int in 2:
		var x: float = cell.position.x + inset if side == 0 else cell.end.x - inset
		draw_line(Vector2(x, cell.position.y + 3.0), Vector2(x, cell.end.y - 3.0),
				ink, 1.4)
		var toward: float = tick if side == 0 else -tick
		draw_line(Vector2(x, cell.position.y + 3.0),
				Vector2(x + toward, cell.position.y + 3.0), ink, 1.4)
		draw_line(Vector2(x, cell.end.y - 3.0),
				Vector2(x + toward, cell.end.y - 3.0), ink, 1.4)


## The arrival mark: one expanding, fading rectangle on the cell that changed.
## A monotone expand-and-fade has no second peak, so there is nothing here for
## the flash caps to bound — and it is scaled by them anyway, so Reduced Flashing
## removes it.
func _draw_mark(id: String, cell: Rect2, hue: Color, alpha: float) -> void:
	var left: float = float(_marks.get(id, 0.0))
	if left <= 0.0:
		return
	var through: float = 1.0 - left / MARK_TIME
	var grow: float = through * MARK_TRAVEL
	var halo: Color = hue
	halo.a = alpha * (1.0 - through) * 0.85 * A11y.flash_scale
	draw_rect(Rect2(cell.position - Vector2(grow, grow),
			cell.size + Vector2(grow, grow) * 2.0), halo, false, 1.4)


## The expanded read, held on the map key: every carried patch by name, with its
## stack count and its rarity word. This is where the fiction is legible — a
## player who wants to know what HOT LOOP does holds the same key they hold to
## read the map.
func _draw_list(ids: Array[String]) -> void:
	var alpha: float = _alpha * _expand
	if alpha <= 0.01:
		return
	var top: float = size.y - CELL_HEIGHT - float(ids.size()) * ROW_HEIGHT
	var header: Color = UiFx.DIM
	header.a = alpha
	draw_string(_font, Vector2(2.0, top - 6.0), "HOT-PATCHES  ·  RUN-SCOPED",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_TEXT_SIZE, header)

	for i: int in ids.size():
		var id: String = ids[i]
		var y: float = top + float(i) * ROW_HEIGHT + ROW_HEIGHT - 5.0
		var tier: int = Patches.rarity(id)
		var hue: Color = PatchFx.rarity_colour(tier)
		hue.a = alpha
		draw_string(_font, Vector2(4.0, y), Patches.glyph(id),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_GLYPH_SIZE, hue)
		var body: Color = UiFx.TEXT
		body.a = alpha
		draw_string(_font, Vector2(26.0, y),
				"%s  x%d" % [Patches.display_name(id), Patches.local_stacks(id)],
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_TEXT_SIZE, body)
		var word: Color = UiFx.DIM
		word.a = alpha
		draw_string(_font, Vector2(STRIP_WIDTH - 92.0, y),
				Balance.patch_tier_name(tier), HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				ROW_TEXT_SIZE, word)
