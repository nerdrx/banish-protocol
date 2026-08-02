class_name Crosshair
extends Control
## The reticle, as an instrument rather than as a graphic.
##
## One rule, borrowed wholesale from Alien: Isolation's discipline and from the
## fact that NULLVOID's breaker is "a tool, not a gun" (DESIGN.md): **the reticle
## says nothing until it has something to say.**
##
## At rest it is a single lit phosphor dot at the centre of the tube. Three things
## can make it speak, and nothing else ever may:
##
##   * **interaction** — the crosshair is on something you can use. Four hairline
##     brackets open around the dot. This is the same information the world-space
##     prompt is already giving you on the object itself; the reticle's job is
##     only to confirm that the *ray* is on it, which a tag floating near a
##     machine cannot.
##   * **heat** — the breaker is approaching lockout. The brackets open further
##     and go amber, and at lockout they go hostile. A heat bar in the corner is
##     a number you have to look away to read; this is the same number where you
##     are already looking.
##   * **impact** — a shot landed, or something died. A tick, or four fragments.
##     Both are gone inside a fifth of a second.
##
## Everything is drawn: hairlines, a dot, and short segments. No textures, no
## child nodes, no allocation per frame. It sits inside the CRT tube like the
## rest of the interface, so the brackets pick up the scanlines and the dot
## leaves a phosphor trail when it moves — which is most of why a drawn reticle
## on this screen reads as a beam parked at the centre rather than as a sprite.

## 0..1 how open the interaction brackets are. Driven by the Hud.
var focus: float = 0.0: set = _set_focus
## 0..1 breaker heat, already mapped through CROSS_HEAT_FRACTION by the Hud.
var heat: float = 0.0: set = _set_heat
## True once the breaker has actually locked out.
var locked: bool = false: set = _set_locked
## 0..1 hit tick, decaying.
var hit: float = 0.0: set = _set_hit
## 0..1 kill burst, decaying.
var kill: float = 0.0: set = _set_kill


func _set_focus(value: float) -> void:
	focus = clampf(value, 0.0, 1.0)
	queue_redraw()


func _set_heat(value: float) -> void:
	heat = clampf(value, 0.0, 1.0)
	queue_redraw()


func _set_locked(value: bool) -> void:
	locked = value
	queue_redraw()


func _set_hit(value: float) -> void:
	hit = clampf(value, 0.0, 1.0)
	queue_redraw()


func _set_kill(value: float) -> void:
	kill = clampf(value, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	var centre: Vector2 = size * 0.5

	# The dot. Always lit, always the same size — it is the one fixed reference
	# on the whole interface and the moment it starts animating it stops being
	# one. It goes hostile only at lockout, which is the only state where the
	# thing the reticle is pointing with does not work.
	var dot: Color = UiFx.HOSTILE if locked else UiFx.SYSTEM_HOT
	draw_circle(centre, UiFx.CROSS_DOT, dot)

	# Brackets. `open` is the larger of the two reasons to have any, so a heated
	# breaker pointed at a siphon tap does not draw two sets of ticks.
	var open: float = maxf(focus, heat)
	if open > 0.004:
		var colour: Color = UiFx.SYSTEM
		if locked:
			colour = UiFx.HOSTILE
		elif heat > focus:
			colour = UiFx.WARNING
		colour.a = clampf(open * 0.9, 0.0, 1.0)

		var gap: float = UiFx.CROSS_BRACKET_GAP + UiFx.CROSS_OPEN_TRAVEL * open
		for axis: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			draw_line(centre + axis * gap,
					centre + axis * (gap + UiFx.CROSS_BRACKET_LEN),
					colour, UiFx.CROSS_BRACKET_WIDTH, true)

	# Hit: the four ticks jump outward and brighten, then fall back. Reusing the
	# bracket geometry rather than drawing a new shape is deliberate — a hit
	# should read as the reticle *reacting*, not as a second icon appearing.
	if hit > 0.004:
		var reach: float = UiFx.CROSS_BRACKET_GAP + UiFx.HIT_TICK_TRAVEL * hit
		var tick: Color = UiFx.SYSTEM_HOT
		tick.a = hit
		for axis: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			draw_line(centre + axis * reach, centre + axis * (reach + 3.0),
					tick, 1.4, true)

	# Kill: fragments thrown off the centre on the diagonals, in the one red the
	# interface is allowed. Diagonal on purpose, so it never occupies the same
	# pixels as the hit tick and the two can overlap without becoming mush.
	if kill > 0.004:
		var travel: float = UiFx.KILL_BURST_TRAVEL * (1.0 - kill)
		var shard: Color = UiFx.HOSTILE
		shard.a = kill
		for i: int in 4:
			var angle: float = PI * 0.25 + PI * 0.5 * float(i)
			var direction: Vector2 = Vector2(cos(angle), sin(angle))
			draw_line(centre + direction * (4.0 + travel),
					centre + direction * (4.0 + travel + 4.5 * kill),
					shard, 1.4, true)
