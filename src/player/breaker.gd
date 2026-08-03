class_name Breaker
extends Node3D
## The crew's cutter: a hitscan tool with no ammunition and no patience.
##
## M12 SENSATION CHANGED WHAT THIS IS. It used to reach eight metres, which the
## first live playtest correctly called clunky: the player's own beam reaches
## thirty, so the thing ending an engagement was never the dark — it was the
## tool, and DESIGN.md pillar 2 says it should always be the dark. The base
## cutter now reaches exactly as far as the base beam does (30 m; see the M12
## section of `Balance`), so what limits a shot is whether you can SEE the thing,
## and firing at a half-lit shape at the edge of your light is a real decision
## instead of an impossibility.
##
## It is still a tool rather than a gun in every way that made that phrase mean
## something: no ammunition, heat instead of a magazine so you cannot hold it
## down, three hits to cut a Scrubber, and a beam you have to aim in the dark. It
## kills everything MOTHER has, but not equally: a Sentinel is eighteen Scrubbers
## of armour with one exposed core, so what it costs is a question of where you
## are standing.
##
## Split of responsibility, the same one M1 established for interaction: the
## trigger, the heat and the lash are local feel, and the *kill* is a host
## decision (Run._breaker_request re-casts the ray). Every peer owns a Breaker
## for the avatar it is watching, so a crewmate's shot draws on your screen too.

## Long enough to register at 60 fps without smearing into a beam. The cutter is
## a snap, not a laser.
const LASH_TIME: float = 0.1
## Widened in M4.95 to 0.075, because at 0.05 the streak was a hairline that
## vanished on a nose-to-wall shot (M3's point-blank complaint), where the streak
## is only a sliver long to begin with.
##
## PT1 walks that back. A friend playtest returned "the laser beam is wayyyy too
## thick", and they are right: 7.5 cm of additive white across the middle of the
## frame is a laser, and DESIGN.md's whole argument for this weapon is that it is
## "a short-range hitscan cutter — a tool, not a gun". The point-blank read was a
## real problem and this is not a straight revert to 0.05; 0.045 keeps a visible
## streak on a nose-to-wall shot (the glow at the impact end and the muzzle flash
## at the origin do most of that work anyway — see GLOW_ENERGY) while cutting the
## on-screen mass of a fifteen-metre shot by 40%. Same number on every peer: the
## width is a constant, not replicated state, so a crewmate's lash is exactly as
## thin as your own.
##
## M12: SUPERSEDED AS A RENDERING NUMBER, kept as the reference it was tuned to.
## A constant world thickness cannot be right at both eight metres and thirty —
## it is either a hairline at range or a slab at point-blank — so the streak now
## holds a constant APPARENT width in `nv_lash.gdshader`, calibrated to reproduce
## exactly this value at the old eight-metre range. Nothing about a close shot
## changed; the far half of a long one is now visible. The mesh cross-section is
## authored at 1x1 and the shader owns the scale, so this no longer sizes it.
const LASH_WIDTH: float = 0.045
const COLOUR: Color = Color(0.72, 0.96, 1.0)
## Energy of the impact-end glow, lighting whatever the cut lands on. Fires on
## every shot, point-blank ones included — where, with the muzzle flash at the
## other end, it does most of the reading.
const GLOW_ENERGY: float = 4.0

## M12: the constant-apparent-width beam. See the shader's own header for why a
## constant world width could not survive the range change.
const LASH_SHADER: String = "res://src/shaders/nv_lash.gdshader"

## 0..1. At 1.0 the cutter locks out until it falls back below the reset point.
var heat: float = 0.0
var locked: bool = false

## Last heat graduation a warning tick fired on, so the thermal relay clicks as
## the heat climbs past each step and never twice on the same one. Only ever
## moves on the local shooter's own breaker (a remote copy never pulls a trigger,
## so its heat stays zero — the audio follows for free).
const HEAT_GRAD: float = 0.2
var _heat_grad: int = 0

var _cooldown: float = 0.0
var _lash: MeshInstance3D = null
var _lash_mesh: BoxMesh = null
var _lash_material: ShaderMaterial = null
var _lash_time: float = 0.0
var _sparks: CPUParticles3D = null
var _glow: OmniLight3D = null


static func create() -> Breaker:
	var breaker: Breaker = Breaker.new()
	breaker.name = "Breaker"
	breaker._assemble()
	return breaker


func _assemble() -> void:
	_lash_material = ShaderMaterial.new()
	_lash_material.shader = load(LASH_SHADER) as Shader
	_lash_material.set_shader_parameter("beam_colour", COLOUR)
	_lash_material.set_shader_parameter("fade", 1.0)

	# 1 x 1 cross-section: the shader multiplies it by the per-vertex width, so
	# authoring any other number here would be scaling the beam twice.
	_lash_mesh = BoxMesh.new()
	_lash_mesh.size = Vector3(1.0, 1.0, 1.0)
	_lash = MeshInstance3D.new()
	_lash.name = "Lash"
	_lash.mesh = _lash_mesh
	_lash.material_override = _lash_material
	_lash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_lash.visible = false
	# Top-level: the lash is a world-space streak between two points, and must
	# not inherit the avatar's rotation while it is on screen.
	_lash.top_level = true
	add_child(_lash)

	_sparks = CPUParticles3D.new()
	_sparks.name = "Sparks"
	_sparks.emitting = false
	_sparks.one_shot = true
	_sparks.amount = 18
	_sparks.lifetime = 0.35
	_sparks.explosiveness = 1.0
	_sparks.spread = 90.0
	_sparks.initial_velocity_min = 1.2
	_sparks.initial_velocity_max = 4.5
	_sparks.gravity = Vector3(0.0, -5.0, 0.0)
	_sparks.scale_amount_min = 0.02
	_sparks.scale_amount_max = 0.07
	var fragment: BoxMesh = BoxMesh.new()
	fragment.size = Vector3.ONE
	_sparks.mesh = fragment
	var spark_material: StandardMaterial3D = StandardMaterial3D.new()
	spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_material.albedo_color = COLOUR
	_sparks.material_override = spark_material
	_sparks.top_level = true
	add_child(_sparks)

	_glow = OmniLight3D.new()
	_glow.name = "MuzzleGlow"
	_glow.light_color = COLOUR
	_glow.light_energy = 0.0
	_glow.omni_range = 6.0
	_glow.omni_attenuation = 1.2
	_glow.light_volumetric_fog_energy = 1.6
	_glow.shadow_enabled = false
	_glow.top_level = true
	add_child(_glow)


# ------------------------------------------------------------------ trigger --

## Local only. Whether the trigger would do anything this frame.
func ready_to_fire() -> bool:
	return _cooldown <= 0.0 and not locked


## Local only. Books the shot against the heat budget; the caller does the rest.
func pull_trigger() -> void:
	_cooldown = Balance.BREAKER_COOLDOWN
	# M9 INSTRUCTION FUSION books less heat per shot. Local, like the rest of the
	# heat budget — it is feel, not authority (the host decides what a shot is
	# WORTH, never how warm your tool got) — and floored in `Balance` so the
	# cutter always heats and the lockout is always reachable by a held trigger.
	heat = minf(heat + Balance.BREAKER_HEAT_PER_SHOT * Patches.heat_scale(), 1.0)
	# The thermal relay warns as the heat climbs past each graduation — quiet, a
	# warning not an event (AUDIO_GUIDE), and denser the hotter it gets because the
	# graduations are fixed-width and the shots come at a fixed cadence.
	var grad: int = int(heat / HEAT_GRAD)
	if grad > _heat_grad:
		_heat_grad = grad
		Audio.play_2d(&"breaker_heat")
	if heat >= 1.0 and not locked:
		locked = true
		Audio.play_2d(&"breaker_lockout")


## The visible shot, on every peer that can see this avatar.
##
## M7 adds the two arguments that turn "a line and a spray" into an impact.
## `normal` is the surface the cut landed on, so the sparks come OFF the wall
## rather than out of it and the scorch lies flat on it; `on_world` says whether
## there is a surface at all, because a burn mark projected onto a creature that
## is about to be deleted is a burn mark hanging in mid-air a second later.
##
## M12 adds `surface`, which is what the ray landed ON — plating, gel, a glyph
## panel, a cable run, grating, or a body. It is the single biggest perceived
## -quality win in the milestone and it costs nothing at runtime: the caller
## already had the collider in its hand when it cast the ray, and passing what it
## found is cheaper than every alternative for finding out later.
##
## All three default to the safe approximation (spray back along the shot,
## unclassified surface, no decal), which is what the host's echo path uses — it
## re-broadcasts an endpoint, not a collider, and putting a surface tag on that
## packet would be paying wire for a garnish that only the shooter can see
## precisely anyway.
func show_lash(from: Vector3, to: Vector3, on_world: bool = false,
		normal: Vector3 = Vector3.ZERO,
		surface: StringName = Fx.SURF_METAL) -> void:
	var delta: Vector3 = to - from
	var length: float = delta.length()

	# The impact end reads even when the streak does not. At point-blank the
	# muzzle is almost on the wall, so the streak is a sliver — but the spray and
	# the glow at `to`, together with the muzzle flash back at `from`, bracket the
	# cut so a nose-to-wall shot still snaps. These fire first and unconditionally
	# for exactly that case: the old early-return skipped them too, which is a
	# large part of why the point-blank shot read as nothing at all.
	_sparks.global_position = to
	_sparks.restart()
	_glow.global_position = to
	_glow.light_energy = GLOW_ENERGY

	# M7: the pooled impact on top of the breaker's own spray — a wider, hotter
	# spark burst, a drifting ember, and a scorch that fades. The two are not
	# redundant: this one is directional (it knows the wall) and pooled (it is the
	# same eight emitters however many people are shooting), and it is what turns
	# a hit from an event into a mark the room remembers for seven seconds.
	var away: Vector3 = normal
	if away.length_squared() < 0.0001:
		away = (from - to).normalized() if length > 0.001 else Vector3.UP
	# M12: the same cut, told apart by what it landed on. A body goes through
	# `creature_hit`, which reads the bestiary entry standing there and picks the
	# spray for it — a Sentinel's gel torso and a Scrubber's dry shell should not
	# come apart the same way.
	if surface == Fx.SURF_CREATURE:
		Fx.creature_hit(to, away, COLOUR)
	else:
		Fx.impact_on(to, away, surface, COLOUR, on_world)

	# The shot itself, spatialised at the muzzle. `show_lash` runs exactly once per
	# peer per shot (locally as prediction for the shooter, via the host echo for a
	# crewmate's), so every peer hears the cut come from where it happened. The
	# shooter's dry 2D copy that puts the tool in their own hands is added in
	# Player._update_breaker — this is the world's copy of it.
	Audio.play_3d(&"breaker_shot", from)

	# Below a couple of centimetres there is no streak worth orienting, and
	# `look_at` on a near-zero vector errors — but the impact above has already
	# carried the read.
	if length < 0.02:
		return

	_lash_mesh.size = Vector3(1.0, 1.0, length)
	_lash.global_position = (from + to) * 0.5
	_lash.look_at(to, Vector3.UP)
	# look_at points -Z at the target and the box is built along +Z; the mesh
	# would otherwise be inside-out about its own axis, which shows as a gap at
	# the muzzle rather than a streak.
	_lash.rotate_object_local(Vector3.UP, PI)
	_lash.visible = true
	_lash_time = LASH_TIME


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)

	heat = maxf(heat - Balance.BREAKER_HEAT_COOL * delta, 0.0)
	var grad: int = int(heat / HEAT_GRAD)
	if grad < _heat_grad:
		_heat_grad = grad  # let the warning ticks re-arm as it cools back down.
	if locked and heat <= Balance.BREAKER_HEAT_RESET:
		locked = false
		Audio.play_2d(&"breaker_ready")  # 'you may continue'.

	if _lash_time > 0.0:
		_lash_time -= delta
		# Fade the streak out over its life instead of blinking it off.
		_lash_material.set_shader_parameter("fade",
				clampf(_lash_time / LASH_TIME, 0.0, 1.0))
		if _lash_time <= 0.0:
			_lash.visible = false
	_glow.light_energy = maxf(_glow.light_energy - delta * 26.0, 0.0)
