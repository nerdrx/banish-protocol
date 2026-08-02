class_name Flare
extends Node3D
## A thrown decryption charge. Arcs, sticks where it lands, and burns a wide
## teal-white light for twenty seconds.
##
## DESIGN.md kit v1: "flares (burn Cycles+Cache stock, cast wide light, repel
## Scrubbers)". The repel is not a special case — a burning flare is registered
## light, and the Scrubber's exposure check treats it exactly like a beam cone.
##
## Replication: the host validates the throw (stock, Cycles) and broadcasts the
## initial conditions once. Every peer integrates the same ballistic arc from the
## same origin and velocity, so the flight needs no streaming and the flare lands
## in the same place on every screen.

const GRAVITY: float = 11.0
const DRAG: float = 0.12
const COLOUR: Color = Color(0.62, 0.95, 1.0)
## Flicker curve.
##
## M3 drove this with two sines summed, which produces a smooth wobble — the
## wrong shape entirely. A burning flare does not wobble: it sits, gutters, and
## catches again. The curve below is a fast four-octave value noise with a floor
## under it, so most of the time the light is steady and every second or so it
## drops hard for a few frames and recovers. That asymmetry is the whole read.
const FLICKER_RATE: float = 9.0
const FLICKER_DEPTH: float = 0.28
## Smoke. A burning charge on a floor throws a thin column that the flare's own
## light catches from underneath — which is what makes the flare read as sitting
## in a room rather than as a light source parked in one.
const SMOKE_COUNT: int = 18
## The last stretch of the burn dims and stutters — a flare running out is a
## warning, not a surprise.
const DYING_FRACTION: float = 0.22

var flare_id: int = 0
var thrower: int = 1

var _velocity: Vector3 = Vector3.ZERO
var _landed: bool = false
var _life: float = Balance.FLARE_LIFETIME
var _light: OmniLight3D = null
var _material: StandardMaterial3D = null
var _shell: Node3D = null
var _smoke: CPUParticles3D = null
var _noise: FastNoiseLite = null
## The looping burn sound, a child so it follows the flare and frees with it (M5).
var _burn_loop: AudioStreamPlayer3D = null


static func create(id: int, peer_id: int, origin: Vector3, velocity: Vector3) -> Flare:
	var flare: Flare = Flare.new()
	flare.name = "Flare%d" % id
	flare.flare_id = id
	flare.thrower = peer_id
	flare.position = origin
	flare._velocity = velocity
	flare._assemble()
	return flare


func _assemble() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = COLOUR.darkened(0.35)
	_material.emission_enabled = true
	_material.emission = COLOUR
	_material.emission_energy_multiplier = 5.0
	_material.roughness = 0.3
	_material.disable_receive_shadows = true

	_shell = Node3D.new()
	add_child(_shell)
	var body: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(0.16, 0.16, 0.34)
	body.mesh = box
	body.material_override = _material
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shell.add_child(body)
	for i: int in 3:
		var fin: MeshInstance3D = MeshInstance3D.new()
		var plate: BoxMesh = BoxMesh.new()
		plate.size = Vector3(0.3, 0.02, 0.1)
		fin.mesh = plate
		fin.rotation.z = TAU * float(i) / 3.0
		fin.material_override = _material
		fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_shell.add_child(fin)

	# Shadowed on purpose: a flare on the floor throwing hard shadows up the walls
	# is what makes a room read as *lit by something you threw* rather than
	# ambiently brighter.
	_light = OmniLight3D.new()
	_light.name = "FlareGlow"
	_light.position = Vector3(0.0, 0.25, 0.0)
	_light.light_color = COLOUR
	_light.light_energy = 6.5
	_light.omni_range = Balance.FLARE_LIGHT_RANGE
	_light.omni_attenuation = 0.9
	_light.light_specular = 0.4
	_light.light_volumetric_fog_energy = 2.6
	_light.shadow_enabled = true
	_light.shadow_bias = 0.06
	add_child(_light)

	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_VALUE
	_noise.frequency = 1.0
	_noise.fractal_octaves = 4
	# Per-flare, so two flares burning in the same room never gutter together —
	# which would read as the room flickering rather than as two separate fires.
	_noise.seed = flare_id * 7919

	# The wisp. Off until it lands: a flare still in the air is not on fire yet
	# as far as the room is concerned, and a smoke trail following a thrown object
	# reads as a rocket.
	_smoke = CPUParticles3D.new()
	_smoke.name = "Smoke"
	_smoke.emitting = false
	_smoke.amount = SMOKE_COUNT
	_smoke.lifetime = 2.6
	_smoke.local_coords = false
	_smoke.position = Vector3(0.0, 0.14, 0.0)
	_smoke.direction = Vector3.UP
	_smoke.spread = 14.0
	_smoke.initial_velocity_min = 0.30
	_smoke.initial_velocity_max = 0.62
	_smoke.gravity = Vector3(0.0, 0.16, 0.0)
	_smoke.damping_min = 0.25
	_smoke.damping_max = 0.55
	_smoke.scale_amount_min = 0.16
	_smoke.scale_amount_max = 0.44
	var puff: QuadMesh = QuadMesh.new()
	puff.size = Vector2.ONE
	_smoke.mesh = puff
	var smoke_material: StandardMaterial3D = StandardMaterial3D.new()
	smoke_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	smoke_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	smoke_material.billboard_keep_scale = true
	smoke_material.vertex_color_use_as_albedo = true
	# Additive and very dim: this is smoke lit from below by the flare, not smoke
	# with a colour of its own. Anything opaque here would read as a fog machine.
	smoke_material.albedo_color = Color(COLOUR.r, COLOUR.g, COLOUR.b, 0.055)
	smoke_material.disable_receive_shadows = true
	_smoke.material_override = smoke_material
	var ramp: Gradient = Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.18, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, 0.85),
		Color(1.0, 1.0, 1.0, 0.0)])
	_smoke.color_ramp = ramp
	add_child(_smoke)


func _ready() -> void:
	add_to_group("flares")
	# Struck and caught. The ignite is a one-shot; the burn loop rides the whole
	# life and is a child, so it is freed with the flare — its position IS the
	# flare's. Both spatial, so the crew hears a flare thrown across the room.
	Audio.play_3d(&"flare_ignite", global_position)
	_burn_loop = Audio.attach_loop(&"flare_burn", self)


## Whether this flare is still throwing enough light to scare a Scrubber.
func is_burning() -> bool:
	return _life > 0.0


func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		# The burn loop dies with the node; the die one-shot comes off the pool so
		# it outlives the flare and plays the downward filter collapse.
		if _burn_loop != null:
			Audio.detach_loop(_burn_loop)
			_burn_loop = null
		Audio.play_3d(&"flare_die", global_position)
		queue_free()
		return

	if not _landed:
		_fly(delta)
	else:
		_shell.rotation.y += delta * 0.4

	var fraction: float = _life / Balance.FLARE_LIFETIME
	var t: float = UiFx.clock()
	# Value noise biased upward: `max` against a floor means the curve spends most
	# of its time near the top and only occasionally dips, which is guttering.
	var raw: float = _noise.get_noise_1d(t * FLICKER_RATE) * 0.5 + 0.5
	var flutter: float = 1.0 - FLICKER_DEPTH * (1.0 - maxf(raw, 0.35)) / 0.65
	var dying: float = 1.0
	if fraction < DYING_FRACTION:
		# Guttering wins as it burns out: the dips get deeper and more frequent
		# until the light is off more than it is on.
		dying = clampf(fraction / DYING_FRACTION, 0.0, 1.0)
		var death_roll: float = _noise.get_noise_1d(t * FLICKER_RATE * 2.6) * 0.5 + 0.5
		flutter *= lerpf(0.25 + 0.75 * death_roll, 1.0, dying)
	_light.light_energy = 6.5 * flutter * dying
	_material.emission_energy_multiplier = 5.0 * flutter * dying
	# The smoke thins as the charge burns down; a dead flare stops smoking a beat
	# after it stops burning rather than at the same instant.
	if _smoke != null and _smoke.emitting and fraction < 0.06:
		_smoke.emitting = false


## Ballistic flight with a raycast for the step, so a fast flare cannot tunnel
## through a floor between frames.
func _fly(delta: float) -> void:
	_velocity.y -= GRAVITY * delta
	_velocity *= 1.0 - DRAG * delta
	var step: Vector3 = _velocity * delta
	_shell.rotation += Vector3(9.0, 4.0, 2.0) * delta

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		position += step
		return

	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			global_position, global_position + step)
	query.collision_mask = 1  # world geometry only
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		position += step
		return

	# Stuck. Sit just proud of whatever it hit and stop simulating.
	global_position = Vector3(hit["position"]) + Vector3(hit["normal"]) * 0.12
	_landed = true
	_velocity = Vector3.ZERO
	_shell.rotation = Vector3(0.0, _shell.rotation.y, 0.0)
	if _smoke != null:
		_smoke.emitting = true
