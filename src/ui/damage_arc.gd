class_name DamageArc
extends Control
## Directional damage: an arc of corrupted static burnt into the screen edge on
## the side the hit came from.
##
## M2 shipped four alpha-ramped ColorRects on the four edges. They told you that
## you were hit and roughly where from, but a full-height rectangle fading up and
## down is the single most generic thing a game HUD can do, and it read as a
## filter rather than as damage to the shell you are running inside.
##
## This is the same information — the direction is the same view-space vector the
## old edges used — drawn as an arc segment of static: slices radiating in from
## the border, each one a different depth, each one flickering on its own, all of
## them concentrated on the bearing the damage came from and falling away either
## side. Nothing is drawn at all on the other three quarters of the frame.
##
## Deterministic under `UiFx.clock()`, so a damage frame captures identically
## every run.

## How far in from the border the deepest slice reaches, in pixels.
const DEPTH: float = 124.0
## Slices around the full border. Only the ones inside SPREAD are ever drawn.
const SLICES: int = 72
## Half-width of the arc, in degrees.
const SPREAD_DEG: float = 62.0
## The static re-rolls at this rate. Per-frame noise is a strobe.
const NOISE_RATE: float = 22.0

const HOT: Color = Color(1.0, 0.24, 0.2)
const COLD: Color = Color(0.55, 0.06, 0.05)

## 0..1 flash weight.
var weight: float = 0.0: set = _set_weight
## Where it came from, in the lens's own frame: x = right, y = forward.
var direction: Vector2 = Vector2.ZERO: set = _set_direction

## One quad, reused for every slice. The alternative is 40 allocations a frame.
var _quad: PackedVector2Array = PackedVector2Array([Vector2.ZERO, Vector2.ZERO,
		Vector2.ZERO, Vector2.ZERO])


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func _set_weight(next: float) -> void:
	var clamped: float = clampf(next, 0.0, 1.0)
	var was_off: bool = weight <= 0.001
	weight = clamped
	var off: bool = weight <= 0.001
	if off != was_off:
		set_process(not off)
	queue_redraw()


func _set_direction(next: Vector2) -> void:
	direction = next
	queue_redraw()


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if weight <= 0.001:
		return

	var centre: Vector2 = size * 0.5
	# Screen bearing, measured clockwise from the top of the frame. Forward in
	# the lens's frame is the top of the screen, right is the right.
	var bearing: float = 0.0
	if direction.length_squared() > 0.0001:
		bearing = atan2(direction.x, direction.y)
	else:
		# A hit with no usable direction (a dev decompile, a source standing
		# exactly on you) rings the whole border instead of lying about a side.
		_draw_ring(centre)
		return

	var spread: float = deg_to_rad(SPREAD_DEG)
	var tick: float = floor(UiFx.clock() * NOISE_RATE)
	var strength: float = weight * weight

	for i: int in SLICES:
		var angle: float = TAU * float(i) / float(SLICES)
		var offset: float = angle_difference(bearing, angle)
		if absf(offset) > spread:
			continue
		# Cosine falloff across the arc, squared: the middle of the wedge is
		# solid and the ends dissolve rather than stopping.
		var falloff: float = cos(offset / spread * PI * 0.5)
		falloff *= falloff
		var noise: float = UiFx.hash01(float(i) * 2.17 + tick)
		var alpha: float = strength * falloff * (0.35 + noise * 0.65)
		if alpha <= 0.01:
			continue
		_draw_slice(centre, angle, TAU / float(SLICES),
				DEPTH * falloff * (0.45 + noise * 0.55) * (0.6 + strength * 0.4),
				COLD.lerp(HOT, noise), alpha)


## The ring form, for a hit with no direction. Same slices, no falloff.
func _draw_ring(centre: Vector2) -> void:
	var tick: float = floor(UiFx.clock() * NOISE_RATE)
	for i: int in SLICES:
		var noise: float = UiFx.hash01(float(i) * 2.17 + tick)
		_draw_slice(centre, TAU * float(i) / float(SLICES), TAU / float(SLICES),
				DEPTH * 0.45 * (0.4 + noise * 0.6),
				COLD.lerp(HOT, noise), weight * weight * (0.2 + noise * 0.4))


## One wedge from the frame's border inward. The border point is found by
## intersecting the bearing with the rect, so the wedge sits flush against the
## edge on a 16:9 frame and on a 4:3 one.
func _draw_slice(centre: Vector2, angle: float, step: float, depth: float,
		colour: Color, alpha: float) -> void:
	var a: Vector2 = _border(centre, angle - step * 0.5)
	var b: Vector2 = _border(centre, angle + step * 0.5)
	var pull_a: Vector2 = (centre - a).normalized() * depth
	var pull_b: Vector2 = (centre - b).normalized() * depth
	_quad[0] = a
	_quad[1] = b
	_quad[2] = b + pull_b
	_quad[3] = a + pull_a
	draw_colored_polygon(_quad, Color(colour.r, colour.g, colour.b, alpha))


## Where the bearing leaves the frame. Bearing 0 is the top of the screen.
func _border(centre: Vector2, angle: float) -> Vector2:
	var d: Vector2 = Vector2(sin(angle), -cos(angle))
	var scale: float = INF
	if absf(d.x) > 0.0001:
		scale = minf(scale, centre.x / absf(d.x))
	if absf(d.y) > 0.0001:
		scale = minf(scale, centre.y / absf(d.y))
	return centre + d * scale
