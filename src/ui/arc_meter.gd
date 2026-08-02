class_name ArcMeter
extends Control
## A drawn arc gauge. Used twice: the big shared-Cycles ring in the corner, and
## the thin channel ring around the crosshair.
##
## Drawn rather than assembled from Controls because DESIGN.md wants the HUD to
## read as "diegetic program-shell UI" — a StyleBox ProgressBar always reads as
## an application, and nothing in this game should.
##
## M4.7 restyles it as an **analog instrument on a phosphor tube** rather than a
## digital arc. Same living behaviour, different material: the fill is amber
## phosphor, the head hunts by a fraction of a pixel the way a moving-coil pointer
## does, and the ticks above the reading are not "empty" — they are **burnt in**,
## the ghost left on the glass by a gauge that has spent years sitting at full.
##
## M3.8 turns the Cycles ring into something that is visibly *alive*:
##
##   * the fill is **segmented**, notched at regular intervals, and the fine tick
##     marks outside it **burn away** as the pool drains — a spent tick is short,
##     dark and jittered off true, so the gauge looks eaten rather than emptied.
##   * an **outer hairline orbit** turns continuously with a bright dash on it.
##     Nothing reads it; it exists so the ring is never a still image.
##   * `ember` paints a drain streak trailing the head. Sprinting bleeds the pool
##     at 2.5x and this is where you see that happening.
##   * `beat` scales the whole drawing on a heartbeat, for the sub-25% alarm.
##
## Every one of those is off by default, so the channel ring around the crosshair
## keeps M2's behaviour exactly.
##
## Allocation note: the per-tick unit vectors are computed once into a packed
## array and reused, and every extra pass is `draw_line`/`draw_circle`, which
## allocate nothing. `draw_arc` builds its point list in C++, not in GDScript.

@export var radius: float = 54.0
@export var thickness: float = 9.0
## Degrees clockwise from the +X axis. The default leaves a gap at the bottom,
## so the ring reads as a gauge with a start and an end rather than a donut.
@export var start_degrees: float = 135.0
@export var sweep_degrees: float = 270.0
@export var segments: int = 96
@export var tick_count: int = 12

## Setters, like every other drawn property on this Control. Without them a call
## site that changes ONLY a colour silently does not repaint — the HUD's phosphor
## retint gets away with it today purely because it writes a sibling property on
## the same frame.
@export var track_color: Color = Color(0.20, 0.13, 0.05, 0.75): set = _set_track_color
@export var fill_color: Color = Color(0.98, 0.68, 0.22): set = _set_fill_color
@export var tick_color: Color = Color(0.62, 0.42, 0.18, 0.75): set = _set_tick_color

@export_group("Living ring")
## Notches cut into the fill. Zero draws one continuous arc (M2 behaviour).
@export var notch_count: int = 0
## Draw the outer hairline orbit and turn it.
@export var orbit: bool = false
@export var orbit_gap: float = 13.0
## Burnt ticks are drawn at this fraction of a live tick's length.
@export var burnt_tick_scale: float = 0.45
## Needle jitter, in pixels of radius. A moving-coil meter never sits perfectly
## still; the pointer hunts by a fraction of a division. Tiny — this has to be
## something you feel rather than something you can see happening.
@export var needle_jitter: float = 0.55

## 0..1 gauge reading.
var value: float = 1.0: set = _set_value
## 0..1 extra bloom, driven by events (a siphon landing, a channel completing).
var glow: float = 0.0: set = _set_glow
## Draws a second, dimmer arc behind the fill — used for "where this was a
## moment ago", so a siphon visibly *fills* rather than jumping.
var ghost: float = 0.0: set = _set_ghost
## 0..1 drain streak trailing the head. Sprint bleed.
var ember: float = 0.0: set = _set_ember
## 0..1 heartbeat weight. Scales the drawing; the alarm below 25% Cycles.
var beat: float = 0.0: set = _set_beat

## Cached unit directions, one per tick, rebuilt only when the geometry changes.
var _tick_dirs: PackedVector2Array = PackedVector2Array()
## The arc geometry `_tick_dirs` was last built for. Three plain scalars rather
## than one hashed key, so the change test itself allocates nothing.
var _tick_count_key: int = -1
var _tick_start_key: float = NAN
var _tick_sweep_key: float = NAN
## Orbit phase, advanced in `_process` only while `orbit` is on.
var _orbit_phase: float = 0.0


func _ready() -> void:
	set_process(orbit)


func _set_track_color(next: Color) -> void:
	track_color = next
	queue_redraw()


func _set_fill_color(next: Color) -> void:
	fill_color = next
	queue_redraw()


func _set_tick_color(next: Color) -> void:
	tick_color = next
	queue_redraw()


func _set_value(next: float) -> void:
	value = clampf(next, 0.0, 1.0)
	queue_redraw()


func _set_glow(next: float) -> void:
	glow = clampf(next, 0.0, 1.0)
	queue_redraw()


func _set_ghost(next: float) -> void:
	ghost = clampf(next, 0.0, 1.0)
	queue_redraw()


func _set_ember(next: float) -> void:
	ember = clampf(next, 0.0, 1.0)
	queue_redraw()


func _set_beat(next: float) -> void:
	beat = clampf(next, 0.0, 1.0)
	queue_redraw()


func _process(_delta: float) -> void:
	# Driven off the shared UI clock rather than delta, so a capture freezes the
	# orbit at a reproducible angle instead of wherever the frame landed.
	var next: float = fposmod(UiFx.clock() * UiFx.RING_ORBIT_SPEED, 1.0)
	if absf(next - _orbit_phase) < 0.0005:
		return
	_orbit_phase = next
	queue_redraw()


## Unit vector per tick. Rebuilt when the arc geometry changes and never
## otherwise — this is the only array the meter owns.
func _rebuild_ticks() -> void:
	# Three scalars compared directly, NOT `hash([a, b, c])` — that spelling
	# builds and hashes an Array literal on every `_draw`, i.e. every frame the
	# Cycles ring redraws, purely to decide not to rebuild. The allocation note in
	# the header is only true because this is spelled out.
	if _tick_count_key == tick_count and is_equal_approx(_tick_start_key, start_degrees) \
			and is_equal_approx(_tick_sweep_key, sweep_degrees) \
			and _tick_dirs.size() == tick_count + 1:
		return
	_tick_count_key = tick_count
	_tick_start_key = start_degrees
	_tick_sweep_key = sweep_degrees
	_tick_dirs.resize(tick_count + 1)
	var start: float = deg_to_rad(start_degrees)
	var sweep: float = deg_to_rad(sweep_degrees)
	for i: int in tick_count + 1:
		var angle: float = start + sweep * (float(i) / float(maxi(tick_count, 1)))
		_tick_dirs[i] = Vector2(cos(angle), sin(angle))


func _draw() -> void:
	_rebuild_ticks()

	var centre: Vector2 = size * 0.5
	# The heartbeat is a scale on the drawing, not on the Control: scaling the
	# Control would drag the value label nested beside it out of alignment.
	var scale: float = 1.0 + beat * UiFx.RING_BEAT_SCALE
	var r: float = radius * scale
	var t: float = thickness * scale
	var start: float = deg_to_rad(start_degrees)
	var sweep: float = deg_to_rad(sweep_degrees)

	if orbit:
		_draw_orbit(centre, r + orbit_gap)

	# The track is drawn in two halves: the part the reading still covers at full
	# strength, and the part it has already given up dimmer. A single even track
	# reads as an empty bar waiting to be filled; this reads as a gauge that has
	# been eaten, which is what a draining shared pool is.
	var spent_from: float = start + sweep * value
	draw_arc(centre, r, start, spent_from, maxi(int(float(segments) * value), 2),
			track_color, t, true)
	draw_arc(centre, r, spent_from, start + sweep,
			maxi(int(float(segments) * (1.0 - value)), 2),
			Color(track_color.r * 0.55, track_color.g * 0.5, track_color.b * 0.5,
					track_color.a * 0.5), t, true)
	_draw_ticks(centre, r, t)

	if ghost > value:
		draw_arc(centre, r, start + sweep * value, start + sweep * ghost,
				maxi(int(float(segments) * (ghost - value)), 3),
				Color(fill_color.r, fill_color.g, fill_color.b, 0.28), t, true)

	if value <= 0.0005:
		return

	var end: float = start + sweep * value
	var used: int = maxi(int(float(segments) * value), 3)

	if glow > 0.001:
		# A wide, low-alpha pass under the fill. Cheaper and steadier than a
		# shader, and it blooms through the layer's glow pass anyway.
		draw_arc(centre, r, start, end, used,
				Color(fill_color.r, fill_color.g, fill_color.b, 0.34 * glow), t * 3.0, true)

	draw_arc(centre, r, start, end, used, fill_color, t, true)
	_draw_notches(centre, r, t, start, sweep, end)

	if ember > 0.001:
		_draw_ember(centre, r, t, start, sweep, end)

	# Leading cap: the bright head of the charge, hunting by half a pixel the way
	# a needle does. Tinted toward the phosphor's hot value rather than to white —
	# at low readings a white dot on a short red stub is the brightest thing in
	# the corner, and the eye goes to the wrong element.
	var hunt: float = (UiFx.hash01(floor(UiFx.clock() * 11.0)) - 0.5) * 2.0
	var head: Vector2 = centre + Vector2(cos(end), sin(end)) * (r + hunt * needle_jitter)
	draw_circle(head, t * 0.52, fill_color.lerp(UiFx.SYSTEM_HOT, 0.65))


## Fine ticks outside the arc. Everything above the current reading is *burnt*:
## short, dark, and knocked a pixel off true, so a draining pool visibly eats its
## own gauge instead of just uncovering track.
func _draw_ticks(centre: Vector2, r: float, t: float) -> void:
	var inner: float = r + t * 0.62
	for i: int in _tick_dirs.size():
		var direction: Vector2 = _tick_dirs[i]
		var fraction: float = float(i) / float(maxi(tick_count, 1))
		var live: bool = fraction <= value + 0.001
		var length: float = 4.0 if live else 4.0 * burnt_tick_scale
		var colour: Color = tick_color
		if not live:
			# Burn-in, not absence: a division the gauge has sat at for decades has
			# etched itself into the phosphor and still shows faintly with nothing
			# driving it. Same hue, a fifth of the brightness.
			colour = Color(tick_color.r, tick_color.g, tick_color.b, tick_color.a * 0.30)
		# Burnt ticks sit a hair off the ring; a perfectly aligned dead tick just
		# looks like a dimmer live one.
		var skew: float = 0.0 if live else (UiFx.hash01(float(i) * 3.7) - 0.5) * 2.4
		var base: Vector2 = centre + direction * inner + direction.orthogonal() * skew
		draw_line(base, base + direction * length, colour, 1.5, true)


## Notches cut across the fill at regular intervals. Drawn in the track colour so
## they read as gaps between segments rather than as marks on top of a bar.
func _draw_notches(centre: Vector2, r: float, t: float, start: float, sweep: float,
		end: float) -> void:
	if notch_count <= 0:
		return
	for i: int in notch_count:
		var angle: float = start + sweep * (float(i) + 0.5) / float(notch_count)
		if angle > end:
			return
		var direction: Vector2 = Vector2(cos(angle), sin(angle))
		draw_line(centre + direction * (r - t * 0.55), centre + direction * (r + t * 0.55),
				Color(0.02, 0.03, 0.04, 0.85), 2.0, false)


## The drain streak: a short, hot tail behind the head, fading backwards. Reads
## as compute being burned off the end of the arc.
func _draw_ember(centre: Vector2, r: float, t: float, start: float, sweep: float,
		end: float) -> void:
	const STEPS: int = 9
	var span: float = sweep * 0.085 * ember
	for i: int in STEPS:
		var k: float = float(i) / float(STEPS - 1)
		var angle: float = end + span * k
		if angle < start:
			break
		var direction: Vector2 = Vector2(cos(angle), sin(angle))
		var fade: float = (1.0 - k) * ember
		var jitter: float = (UiFx.hash01(float(i) + floor(UiFx.clock() * 24.0)) - 0.5) * t * 0.5
		var point: Vector2 = centre + direction * (r + jitter)
		draw_circle(point, t * 0.4 * (1.0 - k * 0.6),
				Color(UiFx.SYSTEM_HOT.r, UiFx.SYSTEM_HOT.g, UiFx.SYSTEM_HOT.b, 0.85 * fade))


## A hairline circle outside the gauge with one bright dash travelling round it.
## Pure decoration, and the cheapest possible way to stop the corner of the
## screen from being a still image.
func _draw_orbit(centre: Vector2, r: float) -> void:
	var hairline: Color = Color(tick_color.r, tick_color.g, tick_color.b, tick_color.a * 0.35)
	draw_arc(centre, r, 0.0, TAU, 48, hairline, 1.0, true)
	var head: float = _orbit_phase * TAU
	draw_arc(centre, r, head, head + 0.5, 8,
			Color(fill_color.r, fill_color.g, fill_color.b, 0.55), 1.6, true)
	var mark: Vector2 = centre + Vector2(cos(head + 0.5), sin(head + 0.5)) * r
	draw_circle(mark, 1.8, Color(fill_color.r, fill_color.g, fill_color.b, 0.8))
