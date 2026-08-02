class_name SafeArea
extends Control
## A Control that IS the tube-safe box, and keeps being it.
##
## `UiFx.tube_safe_rect` states the rule and does the arithmetic; this is the one
## line of plumbing that makes a surface obey it. Parent anything that has to be
## read or clicked to one of these and it inherits the box for free, at every
## aspect, at every UI scale, forever — because everything inside is anchored in
## RATIOS to a node whose own rect is re-solved on `size_changed`.
##
## ## Why it exists as a class rather than as four copies of two lines
##
## PT2's first pass fixed the menu and the HUD's instrument root and stopped
## there, and the live playtest immediately found the hole: "the anchor only
## seems to apply to the left of the screen instead of respecting everything".
## That was exactly right. The HUD's clusters moved because they live under
## `Root`; the ACHIEVEMENT TOAST (its own CanvasLayer, anchored 28 px from the
## canvas's right edge) and the CAPTION STACK (its own CanvasLayer, spanning the
## canvas's full width) did not, because they are not under `Root` and never
## were. On a 32:9 panel the toast was 2532 px from the left — a metre away from
## where the player is looking, in the part of the frame the tube has no picture
## for.
##
## Every full-screen UI surface in the game is a separate CanvasLayer by design
## (the HUD, captions, toasts, the Compiler, the terminal, the junction panel,
## settings). A rule that has to be re-implemented per surface is a rule that is
## already broken on the surface somebody adds next month. So it is a node type,
## and adding a surface means parenting it to one.
##
## Ambient dressing does NOT go inside one. See MainMenu._build_terminal: the
## backdrop and the drifting schematic are full-bleed on purpose, because they
## are texture and they are what makes an ultrawide's wings read as a dark room.


## Build one filling `host`, and return it. `host` is usually a CanvasLayer.
static func wrap(host: Node) -> SafeArea:
	var area: SafeArea = SafeArea.new()
	area.name = "SafeArea"
	host.add_child(area)
	return area


## A centred modal panel that is never bigger than the tube-safe box. Returns the
## holder to build the panel's contents into.
##
## ## Why this is a helper and not three copies of fifteen lines
##
## The Compiler, the command terminal and the junction panel were written the same
## way, one after another: a `CenterContainer` on the full canvas holding a
## `Control` with a hard `custom_minimum_size`. At the design resolution that is
## indistinguishable from correct. `--ui-audit` at the sizes players actually use:
##
##     CompilerPanel  Shaker/Plate  OUTSIDE-SAFE  y=47..673   (box 45..657)
##     TerminalPanel  Panel/Plate   OUTSIDE-SAFE  x=87..987   (box 197..877)
##     JunctionPanel  Panel/Plate   OUTSIDE-SAFE  x=147..927  (box 197..877)
##
## Two failures, one shape. A CenterContainer on the canvas centres on the CANVAS,
## which is not where the safe box is (it carries an upward bias); and a hard pixel
## size in a canvas that SHRINKS as UI SCALE rises outgrows any box eventually —
## the Compiler's 880x626 is already taller than the whole 612-row box at scale
## 1.0, and wider than the 680-column box from about 1.24 up.
##
## Both are properties of the PATTERN, so the pattern is what gets fixed. `wanted`
## is the size the panel was authored at and is treated as a MAXIMUM: it gets that
## much when the box has it, the box's own size when it does not, and the overflow
## scrolls rather than hanging off the glass.
static func modal(host: Node, wanted: Vector2) -> Control:
	var area: SafeArea = SafeArea.wrap(host)

	var centre: CenterContainer = CenterContainer.new()
	centre.name = "Centre"
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(centre)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.name = "ModalScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	centre.add_child(scroll)

	var holder: Control = Control.new()
	holder.name = "Panel"
	holder.custom_minimum_size = wanted
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(holder)

	# Driven off the SafeArea's OWN size rather than off `tube_safe_rect` again.
	# This node is already the box — including under `--no-safe-area`, where it is
	# the full canvas — so there is one place that decides what the box is and no
	# second copy of the rule to fall out of step with it.
	var refit: Callable = func() -> void:
		if not is_instance_valid(scroll) or not is_instance_valid(holder):
			return
		var box: Vector2 = area.size
		if box.x <= 0.0 or box.y <= 0.0:
			return
		var width: float = minf(wanted.x, box.x)
		# The holder keeps the authored HEIGHT so there is something to scroll; the
		# scroll is what gets capped.
		holder.custom_minimum_size = Vector2(width, wanted.y)
		scroll.custom_minimum_size = Vector2(width, minf(wanted.y, box.y))
	area.resized.connect(refit)
	refit.call_deferred()
	return holder


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_viewport().size_changed.connect(refit)
	refit()


## Re-solve the box. Fires on window resize, on a monitor change, and on the UI
## SCALE slider moving — a content-scale change resizes the 2D canvas, so it
## arrives here as an ordinary resize.
func refit() -> void:
	if not is_inside_tree():
		return
	UiFx.fit_to_safe_area(self, get_viewport().get_visible_rect().size)
