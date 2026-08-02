class_name Breaker
extends Node3D
## The crew's cutter: a short-range hitscan tool with no ammunition and no
## patience.
##
## DESIGN.md kit v1 calls it "a tool, not a gun", and the numbers say so —
## eight metres of reach, three hits to cut a Scrubber, and heat instead of a
## magazine so you cannot simply hold it down. It kills everything MOTHER has,
## but not equally: a Sentinel is eighteen Scrubbers of armour with one exposed
## core, so what it costs is a question of where you are standing.
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
const LASH_WIDTH: float = 0.045
const COLOUR: Color = Color(0.72, 0.96, 1.0)
## Energy of the impact-end glow, lighting whatever the cut lands on. Fires on
## every shot, point-blank ones included — where, with the muzzle flash at the
## other end, it does most of the reading.
const GLOW_ENERGY: float = 4.0

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
var _lash_material: StandardMaterial3D = null
var _lash_time: float = 0.0
var _sparks: CPUParticles3D = null
var _glow: OmniLight3D = null


static func create() -> Breaker:
	var breaker: Breaker = Breaker.new()
	breaker.name = "Breaker"
	breaker._assemble()
	return breaker


func _assemble() -> void:
	_lash_material = StandardMaterial3D.new()
	_lash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_lash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_lash_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_lash_material.albedo_color = COLOUR
	_lash_material.disable_receive_shadows = true

	_lash_mesh = BoxMesh.new()
	_lash_mesh.size = Vector3(LASH_WIDTH, LASH_WIDTH, 1.0)
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
	heat = minf(heat + Balance.BREAKER_HEAT_PER_SHOT, 1.0)
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
func show_lash(from: Vector3, to: Vector3) -> void:
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

	_lash_mesh.size = Vector3(LASH_WIDTH, LASH_WIDTH, length)
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
		_lash_material.albedo_color.a = clampf(_lash_time / LASH_TIME, 0.0, 1.0)
		if _lash_time <= 0.0:
			_lash.visible = false
	_glow.light_energy = maxf(_glow.light_energy - delta * 26.0, 0.0)
