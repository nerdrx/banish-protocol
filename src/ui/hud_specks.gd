class_name HudSpecks
extends Control
## Dead pixels and scanline tears across the HUD's readouts.
##
## DESIGN.md: "low-Cycles and damage push these into glitch territory". The
## post-process shader does that to the *world*; this does it to the interface,
## which is the half that sells the shell as software rather than as a filter.
## Below `UiFx.DEGRADE_FRACTION` of the shared pool the readouts start losing
## pixels, and occasionally a band of one tears sideways.
##
## Everything is deterministic: speck positions and tear rows come out of
## `UiFx.hash01` seeded on a tick counter, so two peers looking at the same pool
## see the same damage, and a capture armed at frame 260 photographs the same
## specks every time.
##
## Cost: one redraw every `UiFx.DEGRADE_TICK` (about 13 Hz), never per frame, and
## a few dozen `draw_rect` calls inside it.

## 0..1. Zero means invisible and asleep.
var degrade: float = 0.0: set = _set_degrade
## The rectangles worth corrupting — the cluster panels. Set once by the HUD.
var regions: Array[Rect2] = []

var _tick: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func _set_degrade(next: float) -> void:
	var clamped: float = clampf(next, 0.0, 1.0)
	var was_off: bool = degrade <= 0.001
	degrade = clamped
	var off: bool = degrade <= 0.001
	if off != was_off:
		set_process(not off)
		queue_redraw()


func _process(_delta: float) -> void:
	var tick: int = int(UiFx.clock() / UiFx.DEGRADE_TICK)
	if tick == _tick:
		return
	_tick = tick
	queue_redraw()


func _draw() -> void:
	if degrade <= 0.001 or regions.is_empty():
		return

	var seed_base: float = float(_tick) * 13.0
	var count: int = int(float(UiFx.DEAD_PIXEL_COUNT) * degrade)

	for i: int in count:
		var s: float = seed_base + float(i) * 7.31
		var region: Rect2 = regions[int(UiFx.hash01(s) * float(regions.size())) % regions.size()]
		var at: Vector2 = region.position + Vector2(
				UiFx.hash01(s + 1.7) * region.size.x,
				UiFx.hash01(s + 3.3) * region.size.y)
		# Mostly single dead pixels, occasionally a two-pixel cluster. A field of
		# identical dots reads as a pattern; a field with a few doubles reads as
		# a failing panel.
		var wide: bool = UiFx.hash01(s + 5.1) > 0.78
		var bright: bool = UiFx.hash01(s + 8.9) > 0.62
		var colour: Color = UiFx.SYSTEM_HOT if bright else Color(0.0, 0.0, 0.0)
		colour.a = (0.55 if bright else 0.85) * degrade
		draw_rect(Rect2(at.floor(), Vector2(2.0 if wide else 1.0, 1.0)), colour, true)

	# --- horizontal tear ----------------------------------------------------
	# One band of one readout slipping sideways. Drawn rather than displaced: the
	# labels underneath are laid out by the theme and must not be moved, so the
	# tear is a dark cut plus the bright sliver that "escaped" from it.
	if UiFx.hash01(seed_base + 101.0) > 1.0 - UiFx.TEAR_CHANCE * degrade:
		var region: Rect2 = regions[
				int(UiFx.hash01(seed_base + 17.0) * float(regions.size())) % regions.size()]
		var y: float = region.position.y + UiFx.hash01(seed_base + 29.0) * region.size.y
		var height: float = 2.0 + UiFx.hash01(seed_base + 31.0) * 4.0
		var slip: float = (UiFx.hash01(seed_base + 41.0) - 0.5) * 22.0
		draw_rect(Rect2(region.position.x, y, region.size.x, height),
				Color(0.0, 0.01, 0.02, 0.9 * degrade), true)
		draw_rect(Rect2(region.position.x + slip, y, region.size.x * 0.55, 1.0),
				Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.5 * degrade), true)
