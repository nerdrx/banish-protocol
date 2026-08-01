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


func _ready() -> void:
	add_to_group("flares")


## Whether this flare is still throwing enough light to scare a Scrubber.
func is_burning() -> bool:
	return _life > 0.0


func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return

	if not _landed:
		_fly(delta)
	else:
		_shell.rotation.y += delta * 0.4

	var fraction: float = _life / Balance.FLARE_LIFETIME
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var flutter: float = 0.9 + sin(t * 21.0) * 0.06 + sin(t * 7.3) * 0.04
	var dying: float = 1.0
	if fraction < DYING_FRACTION:
		# Stutter harder and dimmer as it burns out.
		dying = clampf(fraction / DYING_FRACTION, 0.0, 1.0)
		flutter *= 0.55 + 0.45 * absf(sin(t * 13.0))
	_light.light_energy = 6.5 * flutter * dying
	_material.emission_energy_multiplier = 5.0 * flutter * dying


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
