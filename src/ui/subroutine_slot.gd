class_name SubroutineSlot
extends Control
## The compiled-slot indicator: one socket beside the Cycles gauge, saying what
## is in it, whether it is ready, and what running it will cost.
##
## ## Why it is a whole self-contained Control rather than six edits to the HUD
##
## Two reasons, and the first one is not architectural. The HUD is 2000 lines
## with eight surfaces, a cluster list, a boot sequence, a depth pass, a glitch
## rig and a speck field, and every new element in it is six edits in six places.
## M7 lands beside two other agents working in the same tree, and a widget that
## can be added with ONE line and removed with one line is a widget that cannot
## take somebody else's milestone down with it. The second reason is that it is
## genuinely one thing: a socket, a sweep, a cost. It owns its own state, reads
## its own two autoloads and draws itself.
##
## What it gives up by not being in `Hud._clusters` is the shared parallax lag and
## the damage-flinch jitter. It takes the cluster TILT itself (below), which is
## the part that reads at a glance; the jitter is a fraction of a pixel on a
## 54-pixel widget and is not worth the coupling.
##
## ## The quiet-instrument rule (DESIGN.md M4.9)
##
## "Every element must justify every frame it is visible." A slot indicator that
## sat lit permanently would be a fourth persistent readout on an instrument whose
## resting state is supposed to be one cluster. So it SURFACES:
##
##   * bright while the subroutine is recompiling (you want the sweep)
##   * bright for a beat after a cast, and after the ready tick
##   * bright while the pool is too low to afford it (a real state change)
##   * bright on hold — the cost preview
##   * otherwise it fades to a dim outline: the socket is still THERE, because
##     "you have a subroutine" is information a player needs at rest, but it
##     stops competing.
##
## An empty slot (nothing compiled) draws nothing at all. A player who has never
## bought a subroutine should not have a socket on their HUD asking about it.
##
## ## Safety
##
## Nothing here flashes. The ready pop is a single decaying ring, the sweep is a
## monotone ramp, and the low-Cycles state is a colour, not a blink. There is no
## temporal-flash term in this file, so there is nothing for a rate governor to
## govern — which is why it has none, rather than by omission.

## Geometry. Sized and placed to sit in the empty rectangle to the right of the
## Cycles cluster and above the kit panel: `CyclesPanel` ends at x=190 and
## `KitPanel` starts at y=-150, so x 196..300 / y -212..-158 is genuinely free at
## every aspect the instrument box supports.
const SLOT_LEFT: float = 196.0
const SLOT_TOP: float = -212.0
const SLOT_WIDTH: float = 108.0
const SLOT_HEIGHT: float = 54.0

## The socket ring the glyph sits in.
const RING_RADIUS: float = 19.0
const RING_WIDTH: float = 2.4
const RING_SEGMENTS: int = 48
## Where the cooldown sweep starts, and which way it runs. Top, clockwise — the
## reading a clock face already taught everybody.
const SWEEP_START_DEG: float = -90.0

## How long the widget stays up after something happens to it.
const HOLD_CAST: float = 1.6
const HOLD_READY: float = 1.1
## The ready pop: a ring that expands and fades, once, when the sweep completes.
const POP_TIME: float = 0.45
const POP_TRAVEL: float = 9.0
## Resting alpha of the socket when nothing is going on. Low enough to be
## furniture, high enough that you can see you have something slotted.
const REST_ALPHA: float = 0.22

var _surface: UiFx.Surface = null
var _pop: float = 0.0
var _last_fraction: float = 0.0
var _seen_id: String = ""
var _seen_affordable: bool = true
var _font: Font = null


static func create() -> SubroutineSlot:
	var slot: SubroutineSlot = SubroutineSlot.new()
	slot.name = "SubroutineSlot"
	return slot


func _ready() -> void:
	# Bottom-left anchored with negative offsets, `grow_vertical = 0` — the same
	# idiom every instrument cluster in `hud.tscn` uses, so it moves with the safe
	# area rather than against it. Never write `position` on this: the instrument
	# box is re-solved on every viewport change and an absolute position would be
	# silently wrong at 32:9.
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = SLOT_LEFT
	offset_top = SLOT_TOP
	offset_right = SLOT_LEFT + SLOT_WIDTH
	offset_bottom = SLOT_TOP + SLOT_HEIGHT
	grow_vertical = 0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The same half-degree cant every other cluster wears (`UiFx.CLUSTER_TILT_DEG`),
	# so the instrument reads as a physical panel rather than as a flat overlay.
	pivot_offset = Vector2(SLOT_WIDTH * 0.5, SLOT_HEIGHT * 0.5)
	rotation = deg_to_rad(-UiFx.CLUSTER_TILT_DEG)

	_font = load("res://assets/fonts/ui_font.tres") as Font
	_surface = UiFx.Surface.new(HOLD_CAST)
	Subs.cast_landed.connect(_on_cast)
	Subs.equipped_changed.connect(func() -> void: _surface.surface(HOLD_CAST))
	set_process(true)


func _on_cast(peer_id: int, _id: String) -> void:
	if peer_id == Net.local_id():
		_surface.surface(HOLD_CAST)


func _process(delta: float) -> void:
	var id: String = Subs.local_equipped()
	if id.is_empty():
		# Nothing compiled: the widget is not merely dark, it is absent. A socket
		# that asks a question the player cannot yet answer is clutter.
		if modulate.a != 0.0:
			modulate.a = 0.0
		return

	var fraction: float = Subs.cooldown_fraction()
	var affordable: bool = Run.cycles >= Subs.cost_of(Net.local_id(), id)

	# The ready pop, armed on the FALLING edge of the sweep rather than on a
	# timer: the moment the ring completes is the moment the player can act, and
	# that is the only frame worth marking.
	if _last_fraction > 0.0 and fraction <= 0.0:
		_pop = POP_TIME
		_surface.surface(HOLD_READY)
	_last_fraction = fraction
	_pop = maxf(_pop - delta, 0.0)

	# Surface while there is something to say. A cooling sweep is worth watching;
	# so is "you cannot afford this" the moment it becomes true. A slot that is
	# ready and affordable says nothing and fades to its outline.
	if fraction > 0.0:
		_surface.surface(0.15)
	if affordable != _seen_affordable or id != _seen_id:
		_seen_affordable = affordable
		_seen_id = id
		_surface.surface(HOLD_CAST)

	# Pinned open for captures, exactly like every other surfaced element: a
	# shutter cannot be aimed at a 1.6 s dwell by hand.
	if Debug.automated and Debug.hud_state != "":
		_surface.pin()

	var lit: float = _surface.tick(delta)
	modulate.a = 1.0
	# The socket never disappears entirely while something is slotted — it decays
	# to an outline, which is the "shape and position language" the quiet
	# instrument rule asks elements to yield to.
	_alpha = REST_ALPHA + (1.0 - REST_ALPHA) * lit
	queue_redraw()


## Composite alpha, held as a member because `_draw` cannot take arguments and
## `modulate` is reserved for the surfacing of the whole widget by anything above.
var _alpha: float = REST_ALPHA


func _draw() -> void:
	var id: String = Subs.local_equipped()
	if id.is_empty():
		return
	var centre: Vector2 = Vector2(RING_RADIUS + 6.0, size.y * 0.5)
	var fraction: float = Subs.cooldown_fraction()
	var cost: float = Subs.cost_of(Net.local_id(), id)
	var affordable: bool = Run.cycles >= cost
	var ready: bool = fraction <= 0.0 and affordable

	# Colour carries three states and is NEVER the only channel carrying them
	# (pillar 7): the sweep's own arc length says how long is left, the glyph is a
	# shape, and the cost numeral is a numeral. The tint is the fourth, redundant
	# read.
	var lit: Color = UiFx.SYSTEM
	if not affordable:
		lit = UiFx.HOSTILE
	elif not ready:
		lit = UiFx.DIM

	# --- the socket ----------------------------------------------------------
	var track: Color = UiFx.DIM
	track.a = _alpha * 0.55
	_arc(centre, RING_RADIUS, 0.0, TAU, track, RING_WIDTH * 0.7)

	# --- the cooldown sweep --------------------------------------------------
	#
	# Drawn as the REMAINING arc, running clockwise from the top, so a slot that
	# is nearly ready is nearly empty. The alternative (a filling arc) reads as a
	# charge meter, and this is a wait.
	if fraction > 0.0:
		var start: float = deg_to_rad(SWEEP_START_DEG)
		var span: float = TAU * fraction
		var sweep: Color = UiFx.SYSTEM_HOT
		sweep.a = _alpha
		_arc(centre, RING_RADIUS, start, span, sweep, RING_WIDTH)
	elif ready:
		var full: Color = UiFx.SYSTEM
		full.a = _alpha * 0.9
		_arc(centre, RING_RADIUS, 0.0, TAU, full, RING_WIDTH)

	# --- the ready pop -------------------------------------------------------
	#
	# One expanding ring, decaying. Not a flash: a monotone expand-and-fade has no
	# second peak, so there is nothing here for the flash caps to bound — and it
	# is scaled by them anyway, so Reduced Flashing removes it.
	if _pop > 0.0:
		var through: float = 1.0 - _pop / POP_TIME
		var halo: Color = UiFx.SYSTEM_HOT
		halo.a = _alpha * (1.0 - through) * 0.7 * A11y.flash_scale
		_arc(centre, RING_RADIUS + through * POP_TRAVEL, 0.0, TAU, halo, 1.4)

	# --- the glyph -----------------------------------------------------------
	#
	# The icon vocabulary cribs the achievement glyph language: one phosphor-
	# excited mark that carries its whole meaning as a silhouette, with the
	# category hue as garnish. » migration, ◎ radial burst, ◈ a copy inside a
	# copy, ⌾ a shell around a core.
	if _font != null:
		var mark: String = Subs.glyph(id)
		var mark_size: int = 21
		var extent: Vector2 = _font.get_string_size(mark,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, mark_size)
		var glyph_colour: Color = lit
		glyph_colour.a = _alpha
		draw_string(_font, centre + Vector2(-extent.x * 0.5, extent.y * 0.32),
				mark, HORIZONTAL_ALIGNMENT_LEFT, -1.0, mark_size, glyph_colour)

		# --- the cost preview ------------------------------------------------
		#
		# Always a numeral, never a bar: DESIGN.md's dot-matrix readout language,
		# and a number is the only rendering of "14 Cycles" that a player can
		# compare against the gauge two centimetres to its left. Drawn in the
		# hostile tint the instant the pool cannot pay it, which is the moment the
		# information becomes urgent.
		var numeral: String = "%d" % int(round(cost))
		var numeral_colour: Color = UiFx.TEXT if affordable else UiFx.HOSTILE
		numeral_colour.a = _alpha
		draw_string(_font, Vector2(RING_RADIUS * 2.0 + 16.0, size.y * 0.5 - 2.0),
				numeral, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 17, numeral_colour)
		var unit: Color = UiFx.DIM
		unit.a = _alpha * 0.85
		draw_string(_font, Vector2(RING_RADIUS * 2.0 + 16.0, size.y * 0.5 + 13.0),
				"CYC", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, unit)

		# Seconds left, under the socket, only while it means something. A sweep
		# tells you roughly; a numeral tells you whether to commit.
		if fraction > 0.0:
			var left: Color = UiFx.DIM
			left.a = _alpha
			draw_string(_font, centre + Vector2(-11.0, RING_RADIUS + 12.0),
					"%.1f" % Subs.cooldown_seconds(),
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, left)


## An arc, drawn as a polyline rather than with `draw_arc`, so the segment count
## is ours and a 19-pixel ring does not get the same tessellation as a 54-pixel
## one. Allocation-light: one PackedVector2Array per arc per redraw, and the
## widget only redraws when something about it changed.
func _arc(centre: Vector2, radius: float, start: float, span: float,
		colour: Color, width: float) -> void:
	if colour.a <= 0.003 or radius <= 0.5:
		return
	var steps: int = maxi(int(float(RING_SEGMENTS) * (absf(span) / TAU)), 3)
	var points: PackedVector2Array = PackedVector2Array()
	for i: int in steps + 1:
		var angle: float = start + span * (float(i) / float(steps))
		points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
	draw_polyline(points, colour, width, true)
