class_name PatchFx
extends Node3D
## The patch system's two bespoke effects: the pickup burst and the TAIL CALL arc.
##
## Everything else M9 needs already exists in the pooled `Fx` autoload and is
## called straight out of it — the ring, the bloom, the sparks and the shake are
## all `Fx`'s, and re-implementing any of them here would be a second budget for
## the same photons. What is left is one composite (the pickup, which is a ring
## AND a bloom AND a sound AND a caption fired as one moment) and one shape `Fx`
## has no vocabulary for (a bolt between two points).
##
## ## The four `Fx` rules still apply, because they are the project's rules
##
##   1. **Cosmetic and local.** Nothing here changes the simulation.
##   2. **It never touches the RNG stream.** Every offset and spin below is
##      `UiFx.hash01()` of something the event already carries. There is not one
##      `randf` in this file.
##   3. **Allocation-light.** The pickup allocates nothing at all — it is three
##      calls into `Fx`'s pools. The arc is one self-freeing node per link, the
##      same shape and the same budget as `SurgeTrail`, which is one node per
##      dash: a chain is capped at four links and the breaker is capped at
##      3.85 Hz, so the worst case is under sixteen one-box nodes a second and
##      each of them lives for a fifth of a second.
##   4. **The safety law binds the light.** The pickup bloom is a single
##      rise-and-fall envelope — it cannot strobe by construction — and it is
##      multiplied by `Fx.flash_gate()` and `A11y.flash_scale` at the call site
##      below, bounded by `Balance.PATCH_PICKUP_FLASH_ENERGY`, which is under the
##      ability kit's own ceiling. The arc is additive geometry with no light
##      attached to it, so there is nothing there for the caps to bound.

## Seconds one chain bolt lives, and how thick it is. Short and thin: a tail call
## is an instruction jumping, not a lightning strike.
## 0.28 s and not the 0.19 the first pass used. A tail call is the signature of
## the rarest patch in the game and it happens between two processes several
## metres apart in a dark room, often while the player is looking at neither: at
## a fifth of a second it was a thing you could only see if you already knew it
## had happened. This is still short — it is a jump, not a lightning strike — and
## it is still one monotone fade with no light attached.
const ARC_LIFE: float = 0.28
const ARC_WIDTH: float = 0.055
## How far the bolt bows away from the straight line between the two processes,
## as a fraction of its own length. A dead-straight bar reads as a girder.
const ARC_BOW: float = 0.09
## Segments per bolt. Three is enough to read as a jagged jump and cheap enough
## that four of them in one frame is four draw calls.
const ARC_SEGMENTS: int = 3

var _age: float = 0.0
var _material: StandardMaterial3D = null


# ------------------------------------------------------------------ the pickup --

## The moment a hot-patch lands: a ring on the deck, a bloom, a chime and — for
## the player who actually got it — a caption and a shake.
##
## Runs on EVERY peer, because a crewmate reading a slate across a dark room
## should light that room for a moment; that is the co-op read that makes the
## per-player grant negotiable over voice ("I've got it — leave the next one").
## What is local to the grabber is the part that is about *them*: the shake and
## the caption.
##
## `tier` tints the ring by rarity on top of the crew colour, which is garnish
## and never the only channel — the HUD strip carries the same fact as a glyph, a
## numeral and a bracket shape (pillar 7).
static func pickup(where: Vector3, tint: Color, tier: int, mine: bool) -> void:
	var hue: Color = tint.lerp(rarity_colour(tier), 0.45)
	var scale: float = 1.0
	if tier >= Balance.PATCH_TIER_KERNEL:
		scale = Balance.PATCH_PICKUP_KERNEL_SCALE
	Fx.pulse_ring(where + Vector3.UP * 0.05,
			Balance.PATCH_PICKUP_RING_RADIUS * scale, hue, 0.5)
	# The one wide-area luminance term in the effect, and therefore the one thing
	# that goes through the governor. A gated pickup still rings, still draws its
	# ring and still sounds; only the bloom is withheld.
	#
	# The reach is deliberately only a little wider than the ring. You are standing
	# ON the thing you picked up, so a 6 m falloff puts the whole burst inside the
	# lens — see `Balance.PATCH_PICKUP_FLASH_ENERGY` for the capture that taught
	# this and why "inside every safety cap" was not the same as "right".
	Fx.bloom(where + Vector3.UP * 0.8, hue,
			Balance.PATCH_PICKUP_FLASH_ENERGY * scale * Fx.flash_gate()
			* A11y.flash_scale,
			Balance.PATCH_PICKUP_RING_RADIUS * scale * 1.6)
	var chime: StringName = &"patch_pickup"
	if tier >= Balance.PATCH_TIER_KERNEL:
		chime = &"patch_pickup_kernel"
	Audio.play_3d(chime, where)
	if mine:
		Fx.shake(Balance.PATCH_PICKUP_SHAKE)


## Rarity tint. CVD-safe by construction — the three are separated in LIGHTNESS
## as well as hue (0.62 / 0.78 / 0.95 luma), so a protanope reads three
## brightnesses even before the glyph and the bracket shape carry it (pillar 7:
## colour is never the only channel).
static func rarity_colour(tier: int) -> Color:
	match tier:
		Balance.PATCH_TIER_KERNEL:
			return Color(1.00, 0.86, 0.42)   # bright amber — the rarest, the brightest.
		Balance.PATCH_TIER_UNSTABLE:
			return Color(0.62, 0.80, 1.00)   # pale blue, mid lightness.
		_:
			return Color(0.42, 0.72, 0.62)   # muted teal, darkest.


# ------------------------------------------------------------------ the arc --

## One bolt between two processes. Built in one shot along the line and freed by
## its own clock, exactly like `SurgeTrail`.
static func chain_arc(from: Vector3, to: Vector3, tint: Color) -> PatchFx:
	var arc: PatchFx = PatchFx.new()
	arc.name = "TailCallArc"
	arc._assemble(from, to, tint)
	return arc


func _assemble(from: Vector3, to: Vector3, tint: Color) -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.disable_receive_shadows = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Additive and over-driven: in a near-black room an additive bar at 1.0 is a
	# grey smear, and the bolt has to read against a creature's own emissive.
	_material.albedo_color = Color(tint.r * 2.6, tint.g * 2.6, tint.b * 2.6, 0.9)

	var span: Vector3 = to - from
	var length: float = span.length()
	if length < 0.01:
		return
	# The bow is hashed off the endpoints rather than rolled, so every peer draws
	# the same jag from the same packet — and so `--dumplayer` never sees it.
	var side: Vector3 = span.normalized().cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = Vector3.RIGHT
	side = side.normalized()
	var previous: Vector3 = from
	for i: int in ARC_SEGMENTS:
		var through: float = float(i + 1) / float(ARC_SEGMENTS)
		var point: Vector3 = from + span * through
		if i < ARC_SEGMENTS - 1:
			var jag: float = (UiFx.hash01(point.x * 12.9 + point.z * 78.2
					+ float(i) * 3.3) - 0.5) * 2.0
			point += side * jag * length * ARC_BOW
			point.y += (UiFx.hash01(point.z * 41.7 + float(i) * 7.1) - 0.5) \
					* length * ARC_BOW
		_segment(previous, point)
		previous = point


func _segment(from: Vector3, to: Vector3) -> void:
	var span: Vector3 = to - from
	var length: float = span.length()
	if length < 0.001:
		return
	var bar: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(ARC_WIDTH, ARC_WIDTH, length)
	bar.mesh = box
	bar.material_override = _material
	bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The basis is built by hand rather than with `look_at`: this node is
	# assembled BEFORE it enters the tree (the `create`-then-parent idiom every
	# fx object in the project uses), and `look_at` on a node with no world is an
	# engine error, not a rotation. The parent sits at the layer origin like
	# `SurgeTrail`'s, so these local coordinates are world coordinates.
	var direction: Vector3 = span / length
	var up: Vector3 = Vector3.UP
	if absf(direction.dot(Vector3.UP)) > 0.95:
		up = Vector3.RIGHT
	bar.transform = Transform3D(Basis.looking_at(direction, up), (from + to) * 0.5)
	add_child(bar)


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	_age += delta
	if _age >= ARC_LIFE:
		queue_free()
		return
	if _material != null:
		# Monotone fade, no second peak. There is nothing here for a rate governor
		# to govern, which is why it has none — by argument rather than omission.
		_material.albedo_color.a = (1.0 - _age / ARC_LIFE) * 0.9
