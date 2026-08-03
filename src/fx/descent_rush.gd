class_name DescentRush
extends Node3D
## The drop-shaft ride: the descent should feel like COMMITTING.
##
## Riding a shaft used to be a channel, a fade, and a new layer. Mechanically
## that is exactly right — Balance's DESCENT_FADE_OUT/HOLD/FADE_IN exist to cover
## a full geometry rebuild — but it meant the single most consequential decision
## in the game (DESIGN.md pillar 3: *one more ring?*) was presented as a loading
## screen. This is the half-second on either side of that black frame, spent.
##
## A cylinder of vertical light streaks around the lens, rushing UP past the
## player because the player is going DOWN, plus a low whoosh that arrives with
## them. It is deliberately not a screen-space overlay: the streaks are in the
## world, they take the fog, and they take the player's own beam.
##
## ## Where it lives, and why it is not in the shaft
##
## Attached to the local avatar, driven off `Run.descent_started` /
## `descent_finished` — signals every peer already receives. Nothing about it
## touches `src/world`, the shaft prop or the layer rebuild: the descent is an
## event the run announces, and the presentation of an announced event belongs
## with the presentation layer. That also means it works identically for a
## crewmate riding down with you, for a solo drop, and for the debug descent.
##
## Local and cosmetic. No RNG (particle scatter is the emitter's own, which is
## per-peer and consumes nothing seeded), no replication, no simulation.

## Radius of the streak column around the lens, and how tall a slab of it emits.
## Wide enough that the streaks pass beside the player rather than through their
## face, tall enough that the column has no visible top or bottom.
const COLUMN_RADIUS: float = 2.6
const COLUMN_HEIGHT: float = 7.0
## How fast the streaks travel upward. Fast: this is the read.
const RUSH_SPEED_MIN: float = 14.0
const RUSH_SPEED_MAX: float = 26.0
const STREAKS: int = 90

## How long the effect ramps in and out. The ride is bracketed by a fade, so the
## rush has to be at full strength BEFORE the screen goes black and still running
## when it comes back, or the player only ever sees it start.
const RAMP_IN: float = 0.18
const RAMP_OUT: float = 0.55

var _streaks: CPUParticles3D = null
var _material: StandardMaterial3D = null
var _weight: float = 0.0
var _falling: bool = true


static func create(tint: Color) -> DescentRush:
	var rush: DescentRush = DescentRush.new()
	rush.name = "DescentRush"
	rush._assemble(tint)
	return rush


func _assemble(tint: Color) -> void:
	_streaks = CPUParticles3D.new()
	_streaks.name = "Streaks"
	_streaks.amount = STREAKS
	_streaks.lifetime = 0.65
	_streaks.preprocess = 0.5
	# World-space, so a streak keeps travelling where it was born instead of
	# being dragged along by the head it is parented to — which would make the
	# whole column look painted onto the camera.
	_streaks.local_coords = false
	_streaks.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_streaks.emission_box_extents = Vector3(COLUMN_RADIUS, COLUMN_HEIGHT * 0.5,
			COLUMN_RADIUS)
	_streaks.direction = Vector3.UP
	_streaks.spread = 4.0
	_streaks.initial_velocity_min = RUSH_SPEED_MIN
	_streaks.initial_velocity_max = RUSH_SPEED_MAX
	_streaks.gravity = Vector3.ZERO
	_streaks.scale_amount_min = 0.012
	_streaks.scale_amount_max = 0.045

	var streak: BoxMesh = BoxMesh.new()
	# Very long on the travel axis. A streak IS the motion blur; drawing a dot and
	# hoping the eye smears it does not work at 60 fps.
	streak.size = Vector3(0.6, 26.0, 0.6)
	_streaks.mesh = streak

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.albedo_color = Color(tint.r, tint.g, tint.b, 0.0)
	_material.disable_receive_shadows = true
	_material.vertex_color_use_as_albedo = true
	_streaks.material_override = _material

	var ramp: Gradient = Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, 0.9),
		Color(1.0, 1.0, 1.0, 0.7), Color(1.0, 1.0, 1.0, 0.0)])
	_streaks.color_ramp = ramp
	add_child(_streaks)


## The descent finished rebuilding; ease out and free. Called rather than
## queue_free'd directly so the streaks fade rather than vanishing on the frame
## the new layer appears — which would read as a rendering glitch.
func release() -> void:
	_falling = false


func _process(delta: float) -> void:
	var rate: float = 1.0 / RAMP_IN if _falling else -1.0 / RAMP_OUT
	_weight = clampf(_weight + rate * delta, 0.0, 1.0)
	if not _falling and _weight <= 0.001:
		queue_free()
		return
	# Scaled by the flash caps: it is additive light across most of the frame, so
	# it is exactly the kind of effect Reduced Flashing exists to remove. It is
	# not a flash — a monotone ramp cannot strobe — but the comfort tier should
	# still take it away.
	if _material != null:
		_material.albedo_color.a = _weight * 0.55 * A11y.flash_scale
