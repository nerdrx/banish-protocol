class_name MenuBackdrop
extends Control
## The injection console's background: a slow-scrolling line-art schematic of the
## layer stack you are about to descend into.
##
## It is **not** a map. It is deliberately generated from its own fixed seed
## (`UiFx.MENU_SCHEMATIC_SEED`) and has nothing to do with the run seed, because
## a menu that quietly showed you the real layout of layer 1 would be a spoiler
## and a menu that redrew itself every launch would not be art direction. It is a
## piece of MOTHER's own documentation, drifting past.
##
## Reading downward: nine bands, each a ring of the stack; rooms as hairline
## rectangles, corridors as the lines between them, and one trunk running through
## every band — the drop shaft, the only thing in the drawing that goes deeper.
##
## Cost and allocation: all the geometry is built once into packed line arrays
## and drawn with three `draw_multiline` calls. Scrolling is a transform, not a
## rebuild, so a frame costs three draw calls and no allocations at all.

## Height of one layer band, in pixels.
const BAND: float = 128.0
## Room rectangle bounds within a band.
const ROOM_MIN: Vector2 = Vector2(34.0, 22.0)
const ROOM_MAX: Vector2 = Vector2(96.0, 54.0)

const ROOM_COLOUR: Color = Color(0.36, 0.78, 1.0, 0.13)
const LINK_COLOUR: Color = Color(0.36, 0.78, 1.0, 0.07)
const TRUNK_COLOUR: Color = Color(0.36, 0.86, 1.0, 0.2)
const LABEL_COLOUR: Color = Color(0.36, 0.78, 1.0, 0.16)

static var _font: Font = preload("res://assets/fonts/ui_font_wide.tres")

var _rooms: PackedVector2Array = PackedVector2Array()
var _links: PackedVector2Array = PackedVector2Array()
var _trunk: PackedVector2Array = PackedVector2Array()
## Where each band's label goes, and what it says. Built once alongside the rest.
var _label_points: PackedVector2Array = PackedVector2Array()
var _labels: PackedStringArray = PackedStringArray()

## Total height of one repeat of the drawing.
var _period: float = 0.0
var _built_width: float = -1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_rebuild)
	_rebuild()


func _process(_delta: float) -> void:
	queue_redraw()


## Deterministic layout. A local RandomNumberGenerator rather than the global Rng
## autoload: the menu must never touch the run's seed stream, or the first layer
## a player generates would depend on how the menu was drawn.
func _rebuild() -> void:
	if is_equal_approx(size.x, _built_width):
		return
	_built_width = size.x

	_rooms.clear()
	_links.clear()
	_trunk.clear()
	_label_points.clear()
	_labels.clear()

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = UiFx.MENU_SCHEMATIC_SEED
	_period = BAND * float(UiFx.MENU_SCHEMATIC_LAYERS)

	# The trunk wanders a little from band to band but always comes back: it is
	# one shaft through the whole stack, not nine unrelated holes.
	var trunk_x: float = size.x * 0.5

	for layer: int in UiFx.MENU_SCHEMATIC_LAYERS:
		var top: float = float(layer) * BAND
		var previous: Vector2 = Vector2(-1.0, -1.0)

		for room: int in UiFx.MENU_SCHEMATIC_ROOMS:
			var span: float = size.x / float(UiFx.MENU_SCHEMATIC_ROOMS)
			var box: Vector2 = Vector2(
					rng.randf_range(ROOM_MIN.x, ROOM_MAX.x),
					rng.randf_range(ROOM_MIN.y, ROOM_MAX.y))
			var at: Vector2 = Vector2(
					span * float(room) + rng.randf_range(6.0, maxf(span - box.x - 6.0, 8.0)),
					top + rng.randf_range(14.0, BAND - box.y - 14.0))
			_add_box(_rooms, Rect2(at, box))

			var centre: Vector2 = at + box * 0.5
			if previous.x >= 0.0:
				# Corridors are drawn as two axis-aligned runs, never a diagonal.
				# Everything in this game's architecture meets at right angles and
				# the schematic has to agree with it.
				var elbow: Vector2 = Vector2(centre.x, previous.y)
				_add_line(_links, previous, elbow)
				_add_line(_links, elbow, centre)
			previous = centre

		# The trunk: a vertical run through the band with a marker at the shaft.
		var next_x: float = clampf(trunk_x + rng.randf_range(-70.0, 70.0),
				size.x * 0.2, size.x * 0.8)
		_add_line(_trunk, Vector2(trunk_x, top), Vector2(trunk_x, top + BAND * 0.5))
		_add_line(_trunk, Vector2(trunk_x, top + BAND * 0.5),
				Vector2(next_x, top + BAND * 0.5))
		_add_line(_trunk, Vector2(next_x, top + BAND * 0.5), Vector2(next_x, top + BAND))
		_add_box(_trunk, Rect2(next_x - 5.0, top + BAND * 0.5 - 5.0, 10.0, 10.0))
		trunk_x = next_x

		_label_points.append(Vector2(18.0, top + 20.0))
		_labels.append("LAYER %02d" % (layer + 1))


func _add_line(into: PackedVector2Array, from: Vector2, to: Vector2) -> void:
	into.append(from)
	into.append(to)


func _add_box(into: PackedVector2Array, rect: Rect2) -> void:
	var a: Vector2 = rect.position
	var b: Vector2 = rect.position + Vector2(rect.size.x, 0.0)
	var c: Vector2 = rect.position + rect.size
	var d: Vector2 = rect.position + Vector2(0.0, rect.size.y)
	_add_line(into, a, b)
	_add_line(into, b, c)
	_add_line(into, c, d)
	_add_line(into, d, a)


func _draw() -> void:
	if _period <= 0.0:
		return
	# Downward, slowly. The stack goes down and so does the drawing; scrolling it
	# up would fight the one spatial idea the whole game is built on.
	var offset: float = fposmod(UiFx.clock() * UiFx.MENU_SCROLL_SPEED, _period)

	# Two passes, one period apart, so the seam is always off-screen.
	for pass_index: int in 2:
		var y: float = offset - _period * float(pass_index)
		draw_set_transform(Vector2(0.0, y))
		draw_multiline(_links, LINK_COLOUR, 1.0)
		draw_multiline(_rooms, ROOM_COLOUR, 1.0)
		draw_multiline(_trunk, TRUNK_COLOUR, 1.0)
		for i: int in _labels.size():
			draw_string(_font, _label_points[i], _labels[i],
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, LABEL_COLOUR)
	draw_set_transform(Vector2.ZERO)
