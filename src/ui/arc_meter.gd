class_name ArcMeter
extends Control
## A drawn arc gauge. Used twice: the big shared-Cycles ring in the corner, and
## the thin channel ring around the crosshair.
##
## Drawn rather than assembled from Controls because DESIGN.md wants the HUD to
## read as "diegetic program-shell UI" — a StyleBox ProgressBar always reads as
## an application, and nothing in this game should. Ticks, a leading cap and an
## optional bloom pass are what make it look emitted rather than laid out.

@export var radius: float = 54.0
@export var thickness: float = 9.0
## Degrees clockwise from the +X axis. The default leaves a gap at the bottom,
## so the ring reads as a gauge with a start and an end rather than a donut.
@export var start_degrees: float = 135.0
@export var sweep_degrees: float = 270.0
@export var segments: int = 96
@export var tick_count: int = 12

@export var track_color: Color = Color(0.13, 0.2, 0.27, 0.85)
@export var fill_color: Color = Color(0.36, 0.86, 1.0)
@export var tick_color: Color = Color(0.3, 0.45, 0.58, 0.7)

## 0..1 gauge reading.
var value: float = 1.0: set = _set_value
## 0..1 extra bloom, driven by events (a siphon landing, a channel completing).
var glow: float = 0.0: set = _set_glow
## Draws a second, dimmer arc behind the fill — used for "where this was a
## moment ago", so a siphon visibly *fills* rather than jumping.
var ghost: float = 0.0: set = _set_ghost


func _set_value(next: float) -> void:
	value = clampf(next, 0.0, 1.0)
	queue_redraw()


func _set_glow(next: float) -> void:
	glow = clampf(next, 0.0, 1.0)
	queue_redraw()


func _set_ghost(next: float) -> void:
	ghost = clampf(next, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	var centre: Vector2 = size * 0.5
	var start: float = deg_to_rad(start_degrees)
	var sweep: float = deg_to_rad(sweep_degrees)

	draw_arc(centre, radius, start, start + sweep, segments, track_color, thickness, true)

	for i: int in tick_count + 1:
		var angle: float = start + sweep * (float(i) / float(tick_count))
		var direction: Vector2 = Vector2(cos(angle), sin(angle))
		draw_line(centre + direction * (radius + thickness * 0.62),
				centre + direction * (radius + thickness * 0.62 + 4.0),
				tick_color, 1.5, true)

	if ghost > value:
		draw_arc(centre, radius, start + sweep * value, start + sweep * ghost,
				maxi(int(float(segments) * (ghost - value)), 3),
				Color(fill_color.r, fill_color.g, fill_color.b, 0.28), thickness, true)

	if value <= 0.0005:
		return

	var end: float = start + sweep * value
	var used: int = maxi(int(float(segments) * value), 3)

	if glow > 0.001:
		# A wide, low-alpha pass under the fill. Cheaper and steadier than a
		# shader, and it blooms through the layer's glow pass anyway.
		draw_arc(centre, radius, start, end, used,
				Color(fill_color.r, fill_color.g, fill_color.b, 0.34 * glow),
				thickness * 3.0, true)

	draw_arc(centre, radius, start, end, used, fill_color, thickness, true)

	# Leading cap: the bright head of the charge.
	var head: Vector2 = centre + Vector2(cos(end), sin(end)) * radius
	draw_circle(head, thickness * 0.62, Color(1.0, 1.0, 1.0, 0.85))
