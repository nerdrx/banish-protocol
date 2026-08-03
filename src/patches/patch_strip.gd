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

# --- the expanded list's geometry (CODEX) ------------------------------------
#
# The list stopped being a column of names and became a column of NAMES AND WHAT
# THEY ARE DOING, which is several times as wide and, in its roomy form, twice as
# tall. None of that can be a constant, because the canvas it has to fit inside is
# not one: `Screen.ui_scale` SHRINKS the 2D coordinate space (1280/scale wide), so
# at UI SCALE 1.6 on a 3440x1440 panel the whole instrument box is 955x382 canvas
# pixels and the band above the Cycles gauge is 164 of them. A fixed 620x450 list
# would hang off the top of the tube at exactly the setting a player turns up
# BECAUSE they were struggling to read it.
#
# So `_solve_list` measures the room it actually has every frame and degrades in
# three named steps rather than clipping:
#
#   ROOMY    two lines a patch — name and stack count over the live effect clause.
#   TIGHT    one line a patch, the clause trimmed into what is left of the row.
#   CAPPED   as many rows as fit, and a tail line naming how many are not shown.
#
# `--ui-audit` at 3440x1440 x1.0 and x1.6 is what says this works; see the M9.5
# section of debug.gd.

## What the list would like to be, and the narrowest it is still worth drawing.
const LIST_WIDTH: float = 700.0
const LIST_WIDTH_MIN: float = 300.0
## Kept clear on the right for the minimap, which expands on the same key.
const LIST_MAP_RESERVE: float = 448.0
## Breathing room above the list, inside the instrument box.
const LIST_TOP_MARGIN: float = 8.0
## The header line's own share of the height.
const LIST_HEADER: float = 22.0
## Row heights for the two layouts.
const ROW_ROOMY: float = 30.0
const ROW_TIGHT: float = 20.0
## Column geometry. The name column holds "INSTRUCTION FUSION  x6" at 13 px.
const LIST_GLYPH_X: float = 4.0
const LIST_NAME_X: float = 28.0
const LIST_NAME_WIDTH: float = 190.0
## THE CAP ANNOTATION IS NOT A COLUMN. It used to be one, right-aligned at the
## far edge, and the gate report on the first capture is the whole argument
## against it: "the right-hand cap annotations render as a loose second column
## floating over the corridor at low contrast, colliding with world geometry and
## each other. It reads as debug spill, not as an instrument."
##
## Every word of that is a property of RIGHT-ALIGNING SHORT TEXT ACROSS A GAP. The
## eye cannot associate `ceiling +90%` with a clause 300 px to its left, so it
## reads as loose text; the gap is where the corridor shows through, so it reads as
## floating; and a lane only contains what is narrower than it.
##
## So the annotation is now drawn IMMEDIATELY AFTER the clause it qualifies, as
## part of the same run of text, with the clause yielding the space rather than the
## annotation being clipped. There is no second column to collide with anything,
## the association is adjacency, and the cap can never be the thing that gets
## truncated — which matters most for `CAPPED`, the one annotation that changes a
## decision.
const CAP_SEPARATOR: String = "   ·   "

## And a GROUND. The expanded list is the one HUD surface that puts a paragraph of
## body copy over a lit corridor, and the quiet-instrument rule's "no plate" is
## about the RESTING instrument — the menu, the Compiler and the terminal all have
## plates because they are things you stop and read. So does this, while it is
## held open; it fades out with the expansion and the resting row of glyphs keeps
## the bare-instrument treatment it always had.
const PLATE_COLOUR: Color = Color(0.022, 0.015, 0.006, 1.0)
const PLATE_EDGE_ALPHA: float = 0.40
## The accent bar down the left edge, which is what makes a rectangle read as a
## panel rather than as a box drawn behind some words.
const PLATE_BAR: float = 3.0
const PLATE_PAD: float = 8.0

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
## The solved expanded-list geometry for this frame. See `_solve_list`.
var _list: Dictionary = {}


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
	_list = _solve_list(ids.size())
	var height: float = lerpf(STRIP_HEIGHT,
			maxf(float(_list["height"]), STRIP_HEIGHT), _expand)
	var width: float = lerpf(STRIP_WIDTH, float(_list["width"]), _expand)
	offset_top = STRIP_TOP + STRIP_HEIGHT - height
	offset_bottom = STRIP_TOP + STRIP_HEIGHT
	offset_right = STRIP_LEFT + width
	pivot_offset = Vector2(width * 0.5, height * 0.5)

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


## How much list there is room for, this frame, in this canvas.
##
## Measured off the strip's PARENT rather than off the viewport: the parent is the
## HUD's instrument root, which is already the tube-safe / instrument box at
## whatever aspect and UI SCALE the player is running. Asking it how big it is is
## the same question `--ui-audit` asks, so the two can never disagree.
##
## Returns {width, height, rows, row_height, roomy}. `rows` may be fewer than
## `count`, in which case the tail line says so.
func _solve_list(count: int) -> Dictionary:
	var room: Vector2 = get_parent_area_size()
	# The band between the top of the instrument box and the strip's own bottom
	# edge, which is pinned above the Cycles gauge and does not move.
	var tall: float = maxf(room.y + STRIP_TOP + STRIP_HEIGHT - LIST_TOP_MARGIN,
			STRIP_HEIGHT)
	var wide: float = clampf(room.x - STRIP_LEFT - LIST_MAP_RESERVE,
			LIST_WIDTH_MIN, LIST_WIDTH)
	# A canvas too narrow to reserve the minimap's corner at all still gets a list;
	# it gets the widest one that fits inside the box, and the trimmer does the rest.
	wide = minf(wide, maxf(room.x - STRIP_LEFT * 2.0, LIST_WIDTH_MIN))

	# Everything that is not a row: the header above the list and the resting
	# glyph band the control keeps at its own foot. Counted rather than assumed —
	# leaving `CELL_HEIGHT` out of this sum is what put the first build's header 24
	# rows ABOVE the control's own rect, ink outside the box that claimed it.
	var chrome: float = LIST_HEADER + CELL_HEIGHT
	var rows: int = maxi(count, 1)
	var roomy: bool = float(rows) * ROW_ROOMY + chrome <= tall
	var row_height: float = ROW_ROOMY if roomy else ROW_TIGHT
	var shown: int = rows
	if not roomy and float(rows) * ROW_TIGHT + chrome > tall:
		# CAPPED. One row is surrendered to the tail line that admits it.
		shown = maxi(int((tall - chrome) / ROW_TIGHT) - 1, 1)
	var lines: float = float(shown + (0 if shown == rows else 1))
	return {
		"width": wide,
		"height": minf(lines * row_height + chrome, tall),
		"rows": shown,
		"row_height": row_height,
		"roomy": roomy,
	}


## The expanded read, held on the map key: every carried patch by name, with its
## stack count and — the part that makes it worth holding a key for — WHAT IT IS
## DOING AT THAT STACK COUNT, computed from the constants the simulation runs on.
##
## "HOT LOOP x3 · consecutive cuts on one process ramp to +63% within 1.6 s" is a
## decision. "HOT LOOP x3 · STABLE" was a label.
##
## Rarity keeps its non-colour channel (pillar 7): the bracket SHAPE that the
## resting row draws is drawn here too, around the glyph, so a KERNEL patch is
## bracketed in both reads and the tier is never carried by hue alone.
func _draw_list(ids: Array[String]) -> void:
	var alpha: float = _alpha * _expand
	if alpha <= 0.01 or _list.is_empty():
		return
	var width: float = size.x
	var row_height: float = float(_list["row_height"])
	var roomy: bool = bool(_list["roomy"])
	var shown: int = mini(int(_list["rows"]), ids.size())
	var hidden: int = ids.size() - shown
	var lines: float = float(shown + (1 if hidden > 0 else 0))
	var top: float = size.y - CELL_HEIGHT - lines * row_height

	_draw_plate(Rect2(Vector2(0.0, top - LIST_HEADER + 2.0),
			Vector2(width, lines * row_height + LIST_HEADER + 2.0)), alpha)

	var header: Color = UiFx.DIM
	header.a = alpha
	draw_string(_font, Vector2(PLATE_PAD, top - 7.0), "HOT-PATCHES  ·  RUN-SCOPED",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_TEXT_SIZE, header)

	for i: int in shown:
		var id: String = ids[i]
		var count: int = Patches.local_stacks(id)
		var y: float = top + float(i) * row_height
		var tier: int = Patches.rarity(id)
		var hue: Color = PatchFx.rarity_colour(tier)
		var measured: Dictionary = UpgradeText.patch_measure(id, count)
		var capped: bool = bool(measured["capped"])

		# The glyph, wearing the same rarity bracket the resting cell wears.
		var glyph_cell: Rect2 = Rect2(Vector2(LIST_GLYPH_X + PLATE_PAD - 3.0, y + 1.0),
				Vector2(24.0, row_height - 4.0))
		_draw_bracket(glyph_cell, tier, hue, alpha)
		var lit: Color = hue
		lit.a = alpha
		draw_string(_font,
				Vector2(LIST_GLYPH_X + PLATE_PAD, y + row_height * 0.5 + 4.0),
				Patches.glyph(id), HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_GLYPH_SIZE, lit)

		var body: Color = UiFx.TEXT
		body.a = alpha
		var title: String = "%s  x%d" % [Patches.display_name(id), count]
		var name_x: float = LIST_NAME_X + PLATE_PAD
		var clause_x: float = name_x
		var right: float = width - PLATE_PAD
		if roomy:
			# Two lines: the identity, then the mechanism under it and indented, so
			# the eye can run down the names without reading every clause.
			draw_string(_font, Vector2(name_x, y + 13.0),
					UpgradeText.fit(_font, title, ROW_TEXT_SIZE, right - name_x),
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_TEXT_SIZE, body)
		else:
			draw_string(_font, Vector2(name_x, y + row_height - 5.0),
					UpgradeText.fit(_font, title, ROW_TEXT_SIZE, LIST_NAME_WIDTH - 6.0),
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_TEXT_SIZE, body)
			clause_x = name_x + LIST_NAME_WIDTH

		_draw_clause(measured, capped, clause_x, y + row_height - 5.0,
				right - clause_x, alpha)

	if hidden <= 0:
		return
	# The admission. A list that silently stopped at row six would be worse than
	# the label-only list it replaced, because a player would not know to look.
	var tail_colour: Color = UiFx.DIM
	tail_colour.a = alpha
	draw_string(_font,
			Vector2(LIST_NAME_X + PLATE_PAD, top + lines * row_height - 5.0),
			"+%d MORE  ·  FULL CATALOGUE IN THE CODEX" % hidden,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_TEXT_SIZE, tail_colour)


## The ground. A dark plate with a hairline edge and an accent bar down its left,
## so a paragraph of body copy is read off a surface rather than off a corridor.
##
## Drawn rather than themed, and drawn HERE rather than as a child ColorRect, for
## the reason this whole widget is one Control: a node added and removed with the
## expansion is a node the layout has to re-solve, and this is two `draw_rect`
## calls that already know the box.
func _draw_plate(box: Rect2, alpha: float) -> void:
	if box.size.x <= 0.0 or box.size.y <= 0.0:
		return
	var plate: Color = PLATE_COLOUR
	plate.a = PLATE_COLOUR.a * alpha
	draw_rect(box, plate, true)
	var edge: Color = UiFx.SYSTEM
	edge.a = PLATE_EDGE_ALPHA * alpha
	draw_rect(box, edge, false, 1.0)
	# The accent bar. Full-height on the left edge — the same "this is a panel,
	# and it is yours" mark the Compiler's rows wear.
	draw_rect(Rect2(box.position, Vector2(PLATE_BAR, box.size.y)), edge, true)


## The mechanism clause and, immediately after it, the bound in force.
##
## ONE RUN OF TEXT, not two columns. The cap is measured first and the CLAUSE is
## what yields — so `CAPPED` and `ceiling +90%` are never the thing that gets
## ellipsised, and never end up anywhere but touching the sentence they qualify.
## `CAPPED` also keeps its word (pillar 7: colour is never the only channel); the
## WARNING tint is the second channel, not the first.
func _draw_clause(measured: Dictionary, capped: bool, at_x: float, at_y: float,
		room: float, alpha: float) -> void:
	if room <= 0.0:
		return
	var clause: String = String(measured["effect"])
	var cap: String = "CAPPED" if capped else String(measured["ceiling"])
	var cap_text: String = "" if cap.is_empty() else CAP_SEPARATOR + cap
	var cap_width: float = 0.0
	if not cap_text.is_empty():
		cap_width = _font.get_string_size(cap_text, HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, ROW_TEXT_SIZE).x

	var gloss: Color = UiFx.CAPTION
	gloss.a = alpha
	var drawn: String = UpgradeText.fit(_font, clause, ROW_TEXT_SIZE,
			maxf(room - cap_width, 0.0))
	draw_string(_font, Vector2(at_x, at_y), drawn,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_TEXT_SIZE, gloss)
	if cap_text.is_empty():
		return
	var used: float = _font.get_string_size(drawn, HORIZONTAL_ALIGNMENT_LEFT,
			-1.0, ROW_TEXT_SIZE).x
	var mark: Color = UiFx.WARNING if capped else UiFx.DIM
	mark.a = alpha
	draw_string(_font, Vector2(at_x + used, at_y), cap_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, ROW_TEXT_SIZE, mark)
