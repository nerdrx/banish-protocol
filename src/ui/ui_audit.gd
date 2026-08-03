class_name UiAudit
extends CanvasLayer
## UiAudit — the tube-safe rule, photographed and asserted, from inside the build.
##
## `--ui-audit` draws the tube-safe box over the live frame, boxes every element
## that puts ink on the screen, and prints a table of every one of them with a
## verdict. It is the instrument PT2 was missing.
##
## ## Why this exists rather than a person looking at a screenshot
##
## PT2's first pass moved the HUD's instrument clusters inside the safe box, and
## the live playtest came back with "the anchor only seems to apply to the left of
## the screen". It was right, and the reason it could be right is that the fix had
## been *checked by eye on a picture of one screen*. The ACHIEVEMENT TOAST and the
## CAPTION STACK are their own CanvasLayers — they are not under the HUD's `Root`,
## they never moved, and no capture in the repo had a toast in it, so nothing said
## so. Three more surfaces (the Compiler, the terminal, the junction panel) had
## never been looked at at all.
##
## An eye cannot audit a rule that spans five CanvasLayers and only misbehaves at
## aspects the developer's monitor cannot display. So the rule gets an instrument:
##
##   * every Control that DRAWS is enumerated from the live tree, so a surface
##     somebody adds next month is in the audit the first time it is run and
##     nobody has to remember to add it;
##   * ambient dressing is excluded BY NAME, from a list in this file, because
##     full-bleed dressing is deliberate (see `UiFx.tube_safe_rect`) and a rule
##     that flags the backdrop as a violation is a rule people learn to ignore;
##   * the verdict is arithmetic (`Rect2.encloses`), printed as numbers, not a
##     judgement about a JPEG.
##
## ## The second verdict: CLIPPED
##
## The same walk answers the other live complaint — "the menu isn't completely
## visible with the wrong screen aspect" — because the failure mode there is not
## "outside the safe box", it is "inside an ancestor that CLIPS". A ScrollContainer
## whose scrollbar never appears looks exactly like a menu with fewer buttons on
## it. So every element is also intersected with each clipping ancestor above it,
## and anything losing pixels that way is reported CLIPPED with the number of rows
## it lost. Unreachable UI is a layout bug even when it is perfectly anchored.
##
## Usage (always through headless gamescope — see Debug's header):
##
##     godot --path . -- --window-size 3440x1440 --ui-audit --screenshot out.png 120
##
## Nothing in this file runs, or is even constructed, without the flag.


## The audit draws above every surface it is auditing. Captions sit at 64 and the
## HUD's overlays below that; 512 is clear of anything the game will plausibly add
## and clear of the menu's post-process ColorRect, which is not a layer at all.
const AUDIT_LAYER: int = 512

## Frames to wait before the first report. The menu compiles itself in, the HUD
## boots, and a table printed at frame 0 describes neither.
const FIRST_REPORT_FRAME: int = 60
## And the interval between the reports after it. Three is enough to show that a
## layout has settled rather than caught mid-animation.
const REPORT_INTERVAL: int = 90
const REPORT_COUNT: int = 3

## AMBIENT DRESSING — full-bleed on purpose, excluded from the verdict.
##
## `UiFx.tube_safe_rect`'s rule has two halves and this is the second one: texture
## is allowed at the edge because it carries no information, and on an ultrawide it
## is the entire reason the wings read as a dark room instead of as a letterbox.
## Flagging it would make every run fail and the failures mean nothing.
##
## Plain typed arrays, not `PackedStringArray`: that is a constructor CALL, and
## GDScript only accepts constant expressions in a `const` — declaring it that way
## fails to parse the whole script and, from an autoload, takes the boot with it.
const DRESSING: Array[String] = [
	"Backdrop", "Schematic", "Post", "Specks", "HudSpecks", "ConsoleSweep",
	"Dim", "TopRule", "BottomRule", "Frame", "Vignette", "Tube", "Scanlines",
]
## Anything whose name ends with one of these is dressing too — the per-cluster
## glass highlights (`CrewSheen`, `KitSheen`, ...) are lighting, not readouts.
const DRESSING_SUFFIX: Array[String] = ["Sheen", "Glow", "Grain"]

## WORLD- AND CENTRE-ANCHORED OVERLAYS — measured, but not judged.
##
## These are full-screen Controls with a `_draw`, so their RECT is the whole canvas
## while their INK is a few hundred pixels somewhere inside it. The audit can see
## rects and cannot see ink, so a containment test on them answers a question
## nobody asked: `Reticle` is at the exact centre of the screen by construction,
## `IntegrityReadouts` projects a bar onto a creature standing in the world (a bar
## the safe box pulled off its creature would be a WORSE bar), and `DamageArc` is a
## flinch at the edges of the frame that is full-bleed for the same reason the
## scanlines are.
##
## Listed rather than dropped, and printed on their own line in the report. An
## exclusion nobody can see is how the toast got missed; this one is on the page.
const WORLD_ANCHORED: Array[String] = ["Reticle", "Crosshair", "IntegrityReadouts",
	"DamageArc", "ChannelRing"]

const OK_COLOR: Color = Color(0.35, 1.0, 0.45, 0.85)
const BAD_COLOR: Color = Color(1.0, 0.25, 0.25, 0.95)
const CLIP_COLOR: Color = Color(1.0, 0.68, 0.15, 0.95)
const SAFE_COLOR: Color = Color(0.25, 0.85, 1.0, 0.95)
const INSTRUMENT_COLOR: Color = Color(1.0, 0.80, 0.35, 0.85)
const SURFACE_COLOR: Color = Color(0.85, 0.55, 1.0, 0.9)
const LEAF_ALPHA: float = 0.30

## One audited element, resolved once per frame.
class Entry:
	var name: String = ""
	var surface: String = ""
	## In `WORLD_ANCHORED`: reported, never failed.
	var unjudged: bool = false
	var rect: Rect2 = Rect2()
	## `rect` after every clipping ancestor has taken its bite.
	var visible_rect: Rect2 = Rect2()
	var inside: bool = true
	var clipped: bool = false


var _frames: int = 0
var _reports: int = 0
var _entries: Array[Entry] = []
var _surfaces: Dictionary = {}
var _safe: Rect2 = Rect2()
## PT3: the HUD's instrument zone, which is the tube-safe box only at HUD WIDTH
## 0. Judged against separately, because the two boxes are two different rules —
## the menu is a composed screen and stays tube-safe; the HUD is a set of
## instruments and the player owns how far apart they sit. Auditing the second
## against the first would report a setting working as a bug.
var _instruments: Rect2 = Rect2()
var _canvas: Control = null


## Surfaces judged against the INSTRUMENT zone rather than the tube-safe box.
## By CanvasLayer name, so a surface that is not an instrument cannot silently
## opt itself into the wider rule by being added under the HUD later.
const INSTRUMENT_SURFACES: Array[String] = ["HUD"]


## True for the whole session once `--ui-audit` has been seen.
##
## Two surfaces read this and hold themselves open when it is set: the achievement
## toast (4.2 s) and the caption stack (2.4 s). Both are TRANSIENT, and a transient
## surface is one a shutter cannot be aimed at — which is the entire reason the
## toast's anchoring was wrong for a milestone without anybody noticing. Under the
## audit they stop expiring, so the frame that proves where they sit can actually
## be taken. It changes nothing in a normal run: the flag is never set.
static var armed: bool = false


## Stand one up under `host`. Returns null unless `--ui-audit` was passed, so the
## call site is a single unconditional line and this file owns the policy.
static func arm(host: Node) -> UiAudit:
	if not OS.get_cmdline_user_args().has("--ui-audit"):
		return null
	armed = true
	var audit: UiAudit = UiAudit.new()
	audit.name = "UiAudit"
	host.add_child(audit)
	return audit


func _ready() -> void:
	layer = AUDIT_LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Control.new()
	_canvas.name = "Draw"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_draw_audit)
	add_child(_canvas)


func _process(_delta: float) -> void:
	_frames += 1
	_collect()
	_canvas.queue_redraw()
	if _reports < REPORT_COUNT \
			and _frames >= FIRST_REPORT_FRAME + _reports * REPORT_INTERVAL:
		_reports += 1
		_print_report()


# ------------------------------------------------------------------ collect --

func _collect() -> void:
	_entries.clear()
	_surfaces.clear()
	var view: Vector2 = get_viewport().get_visible_rect().size
	_safe = get_viewport().get_visible_rect() if Debug.no_safe_area \
			else UiFx.tube_safe_rect(view)
	_instruments = get_viewport().get_visible_rect() if Debug.no_safe_area \
			else UiFx.instrument_rect(view, Screen.hud_width_for(view))
	_walk(get_tree().root, "root", Rect2(Vector2.ZERO, view))


## The box a surface is held to. See `INSTRUMENT_SURFACES`.
func _box_for(surface: String) -> Rect2:
	return _instruments if INSTRUMENT_SURFACES.has(surface) else _safe


## Depth-first, carrying the accumulated CLIP RECT down.
##
## The clip is the interesting parameter. Godot applies `clip_contents` at draw
## time, so a Control's `size` keeps claiming the space it wanted even when a
## ScrollContainer above it is only showing the top 400 rows of it — which is
## precisely how a menu loses its buttons while every rect in the inspector still
## looks correct.
func _walk(node: Node, surface: String, clip: Rect2) -> void:
	if node == self:
		return
	var here: String = surface
	if node is CanvasLayer and node != self:
		here = String(node.name)
	var control: Control = node as Control
	var next_clip: Rect2 = clip
	if control != null:
		if not control.is_visible_in_tree():
			return
		var rect: Rect2 = _canvas_rect(control)
		if control.clip_contents or control is ScrollContainer:
			next_clip = clip.intersection(rect)
		if _is_ink(control):
			var entry: Entry = Entry.new()
			entry.name = _path_name(control, here)
			entry.surface = here
			entry.rect = rect
			entry.visible_rect = clip.intersection(rect)
			entry.clipped = not _covers(clip, rect)
			# Judged on the VISIBLE rect, not the laid-out one. A row scrolled below
			# the fold has a rect way outside the safe box and no pixels anywhere —
			# calling that a safe-area violation would make every scrolling surface
			# in the game fail forever, which is how an instrument gets ignored. The
			# rule is about INK, so the test is about ink.
			entry.unjudged = WORLD_ANCHORED.has(String(control.name))
			entry.inside = entry.unjudged \
					or entry.visible_rect.size.x <= 0.0 \
					or entry.visible_rect.size.y <= 0.0 \
					or _covers(_box_for(here), entry.visible_rect)
			_entries.append(entry)
			if not entry.unjudged \
					and entry.visible_rect.size.x > 0.0 and entry.visible_rect.size.y > 0.0:
				var bounds: Variant = _surfaces.get(here)
				_surfaces[here] = entry.visible_rect if bounds == null \
						else (bounds as Rect2).merge(entry.visible_rect)
	for child: Node in node.get_children():
		_walk(child, here, next_clip)


## A Control that puts pixels on the screen, as opposed to one that arranges
## Controls that do. Containers, spacers and the invisible `SafeArea` plumbing all
## fall out here, which is what keeps the table readable.
func _is_ink(control: Control) -> bool:
	if control.modulate.a <= 0.02 or control.self_modulate.a <= 0.02:
		return false
	if control.size.x <= 1.0 or control.size.y <= 1.0:
		return false
	if _is_dressing(control):
		return false
	if control.has_method("_draw"):
		return true
	return control is Label or control is RichTextLabel or control is BaseButton \
			or control is LineEdit or control is TextEdit or control is Range \
			or control is Panel or control is PanelContainer or control is ColorRect \
			or control is TextureRect or control is NinePatchRect \
			or control is ItemList or control is Tree


func _is_dressing(control: Control) -> bool:
	var name_text: String = String(control.name)
	if DRESSING.has(name_text):
		return true
	for suffix: String in DRESSING_SUFFIX:
		if name_text.ends_with(suffix):
			return true
	# A ColorRect or TextureRect carrying a ShaderMaterial is an effect pass (the
	# post grade, the tube mask, the persistence buffer), never a readout.
	if (control is ColorRect or control is TextureRect) \
			and control.material is ShaderMaterial:
		return true
	# A plain ColorRect that covers the ENTIRE canvas is a scrim: the dimmer behind
	# the Compiler, the terminal and the junction panel all are one, and every one
	# of them is meant to reach the edges. Caught by shape rather than by name
	# because two of the three are unnamed `@ColorRect@1745`-style nodes, and a
	# dressing list keyed on generated names is a list that rots on the next build.
	if control is ColorRect and _fills_canvas(control):
		return true
	return false


func _fills_canvas(control: Control) -> bool:
	var view: Viewport = control.get_viewport()
	if view == null:
		return false
	var rect: Rect2 = _canvas_rect(control)
	return _covers(rect, Rect2(Vector2.ZERO, view.get_visible_rect().size))


## The control's rect in the viewport's canvas coordinates — the same space
## `UiFx.tube_safe_rect` answers in, so the containment test is a plain compare.
## All four corners are transformed rather than the origin plus the size, because
## a rotated or scaled CanvasLayer would make the latter a lie.
func _canvas_rect(control: Control) -> Rect2:
	var xf: Transform2D = control.get_global_transform_with_canvas()
	var size: Vector2 = control.size
	var a: Vector2 = xf * Vector2.ZERO
	var out: Rect2 = Rect2(a, Vector2.ZERO)
	out = out.expand(xf * Vector2(size.x, 0.0))
	out = out.expand(xf * size)
	out = out.expand(xf * Vector2(0.0, size.y))
	return out


## Containment with a one-pixel tolerance. Layout arithmetic lands on halves and a
## rule that fails on a 0.4 px overhang is a rule that cries wolf.
func _covers(outer: Rect2, inner: Rect2) -> bool:
	return inner.position.x >= outer.position.x - 1.0 \
			and inner.position.y >= outer.position.y - 1.0 \
			and inner.end.x <= outer.end.x + 1.0 \
			and inner.end.y <= outer.end.y + 1.0


func _path_name(control: Control, surface: String) -> String:
	var parent: Node = control.get_parent()
	if parent == null or String(parent.name) == surface:
		return String(control.name)
	return "%s/%s" % [String(parent.name), String(control.name)]


# --------------------------------------------------------------------- draw --

func _draw_audit() -> void:
	var font: Font = ThemeDB.fallback_font
	var view: Rect2 = get_viewport().get_visible_rect()

	# Every element, thin. The carpet of boxes is the point: it shows at a glance
	# that the audit looked at the whole frame and not at a shortlist.
	for entry: Entry in _entries:
		var tint: Color = OK_COLOR
		if not entry.inside:
			tint = BAD_COLOR
		elif entry.clipped:
			tint = CLIP_COLOR
		tint.a = LEAF_ALPHA if entry.inside and not entry.clipped else 0.9
		# The VISIBLE rect, so the drawing agrees with the verdict: a box around a
		# row that is scrolled out of sight is a box around nothing.
		if entry.visible_rect.size.x > 0.0 and entry.visible_rect.size.y > 0.0:
			_canvas.draw_rect(entry.visible_rect, tint, false, 1.0)

	# Each surface's total ink, thick and named. This is the line the toast bug
	# would have failed: one box per CanvasLayer, so a surface parked out in the
	# wing is visible without reading a single label.
	for key: Variant in _surfaces:
		var bounds: Rect2 = _surfaces[key] as Rect2
		var good: bool = _covers(_box_for(String(key)), bounds)
		_canvas.draw_rect(bounds, SURFACE_COLOR if good else BAD_COLOR, false, 2.0)
		_canvas.draw_string(font, bounds.position + Vector2(4.0, -5.0),
				String(key), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11,
				SURFACE_COLOR if good else BAD_COLOR)

	# The rules themselves, last, so they are never drawn over. The instrument
	# zone is only drawn when it differs from the tube-safe box — at HUD WIDTH 0
	# they are the same rectangle and two strokes on one edge reads as a bug.
	if not _instruments.is_equal_approx(_safe):
		_canvas.draw_rect(_instruments, INSTRUMENT_COLOR, false, 2.0)
		_canvas.draw_string(font, _instruments.position + Vector2(4.0, 28.0),
				"INSTRUMENTS %dx%d  (HUD WIDTH %d%%)" % [
					int(_instruments.size.x), int(_instruments.size.y),
					int(round(Screen.hud_width_for(view.size) * 100.0))],
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, INSTRUMENT_COLOR)
	_canvas.draw_rect(_safe, SAFE_COLOR, false, 2.0)
	_canvas.draw_string(font, _safe.position + Vector2(4.0, 14.0),
			"TUBE-SAFE %dx%d" % [int(_safe.size.x), int(_safe.size.y)],
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, SAFE_COLOR)

	_draw_legend(font, view)


func _draw_legend(font: Font, view: Rect2) -> void:
	var fails: int = 0
	var clips: int = 0
	for entry: Entry in _entries:
		if not entry.inside:
			fails += 1
		if entry.clipped:
			clips += 1
	var lines: PackedStringArray = PackedStringArray([
		"UI AUDIT  canvas %dx%d  scale x%.2f" % [
			int(view.size.x), int(view.size.y), Screen.ui_scale],
		"%d elements  %d surfaces" % [_entries.size(), _surfaces.size()],
		"%d OUTSIDE SAFE   %d CLIPPED" % [fails, clips],
	])
	var at: Vector2 = Vector2(8.0, 16.0)
	for i: int in lines.size():
		var tint: Color = SAFE_COLOR
		if i == 2:
			tint = OK_COLOR if fails == 0 and clips == 0 else BAD_COLOR
		_canvas.draw_string(font, at + Vector2(0.0, i * 14.0), lines[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, tint)


# ------------------------------------------------------------------- report --

## The table. Printed rather than drawn because the numbers are the evidence and a
## number in a PNG cannot be diffed between two runs.
func _print_report() -> void:
	var view: Vector2 = get_viewport().get_visible_rect().size
	print("[UiAudit] ---- canvas %dx%d  window %dx%d  ui_scale x%.2f  frame %d" % [
		int(view.x), int(view.y), int(get_window().size.x), int(get_window().size.y),
		Screen.ui_scale, _frames])
	print("[UiAudit] safe box  x=%d y=%d w=%d h=%d" % [
		int(_safe.position.x), int(_safe.position.y),
		int(_safe.size.x), int(_safe.size.y)])
	# PT3. Printed unconditionally, even when it equals the safe box: a reader
	# comparing two runs has to be able to see WHICH zone the HUD was held to and
	# what the slider was on, without inferring it from the numbers matching.
	print("[UiAudit] instruments x=%d y=%d w=%d h=%d  hud_width=%.2f%s" % [
		int(_instruments.position.x), int(_instruments.position.y),
		int(_instruments.size.x), int(_instruments.size.y),
		Screen.hud_width_for(view), " (auto)" if Screen.hud_width_auto else ""])
	# And the centring check the "anchored to the left" report needed: the gap
	# outboard of the instrument ink on each side. Equal gaps means centred, and
	# a claim about anchoring is settled by two integers rather than by a JPEG.
	var ink: Variant = _surfaces.get("HUD")
	if ink != null:
		var hud: Rect2 = ink as Rect2
		print("[UiAudit] hud ink   left-gap=%d right-gap=%d  (canvas %d wide)" % [
			int(hud.position.x), int(view.x - hud.end.x), int(view.x)])
	var fails: int = 0
	var clips: int = 0
	for entry: Entry in _entries:
		if entry.unjudged:
			print("[UiAudit] unjudged %-24s (world/centre-anchored overlay)" % entry.name)
	for key: Variant in _surfaces:
		var bounds: Rect2 = _surfaces[key] as Rect2
		var verdict: String = "INSIDE" if _covers(_box_for(String(key)), bounds) else "OUTSIDE"
		print("[UiAudit] surface %-18s %-7s  x=%d..%d y=%d..%d" % [
			String(key), verdict,
			int(bounds.position.x), int(bounds.end.x),
			int(bounds.position.y), int(bounds.end.y)])
	for entry: Entry in _entries:
		if entry.inside and not entry.clipped:
			continue
		var tags: PackedStringArray = PackedStringArray()
		if not entry.inside:
			tags.append("OUTSIDE-SAFE")
			fails += 1
		if entry.clipped:
			var lost: float = entry.rect.size.y - entry.visible_rect.size.y
			tags.append("CLIPPED(-%dpx)" % int(maxf(lost, 0.0)))
			clips += 1
		printerr("[UiAudit] %-10s %-34s %s  x=%d..%d y=%d..%d" % [
			entry.surface, entry.name, " ".join(tags),
			int(entry.rect.position.x), int(entry.rect.end.x),
			int(entry.rect.position.y), int(entry.rect.end.y)])
	print("[UiAudit] %d element(s) outside the safe box, %d clipped, of %d audited" % [
		fails, clips, _entries.size()])
