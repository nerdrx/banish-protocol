class_name DebrisBody
extends RigidBody3D
## The clutter that betrays you.
##
## DESIGN.md's M4.8 line: "a subset of clutter is RigidBody — kick it and it
## clatters; the clatter emits a noise ping the antivirus hears (small radius)".
## Six to ten pieces on a whole layer, and they are the only objects in NULLVOID
## that punish you for *moving carelessly* rather than for making a decision.
##
## The design is almost entirely about restraint:
##
##   **Few.** Ten live rigid bodies is the budget, set in `LayerGraph.DEBRIS`.
##   Fifty would be a physics toy; ten is a hazard you learn to look at the floor
##   for.
##   **Quiet reach.** A clatter carries `NOISE_ROOMS_DEBRIS` — zero rooms, so
##   whatever is in here with you hears it and nothing else does. It is the
##   softest thing on the noise ladder by design: it should cost you the room,
##   never the layer.
##   **Asleep.** Every piece starts sleeping and is put back to sleep by hand
##   once it has settled (RigidBody3D's own threshold is generous, and a layer of
##   pieces jittering in the broadphase forever is frame budget nobody asked for).
##   **Impossible to lose.** Continuous collision detection is on and the pieces
##   are small but not tiny — the failure mode for a project like this is one can
##   falling through the deck on layer 12 and nobody ever finding out why.
##
## The kick itself comes from `Player._push_debris`: a CharacterBody3D does not
## push rigid bodies on its own in Godot 4, so the avatar applies an impulse to
## anything it slides against. The breaker can shove one too — it is a hitscan,
## so it does not, but the clatter from a piece knocked off a crate by something
## else is exactly as loud.
##
## ## Authority
##
## Each peer simulates its own pieces and they will drift apart by centimetres;
## that is fine, they are set dressing. Only the **host's** clatter pings, because
## only the host has anything listening — `Noise.ping` emits locally and the
## director's handler is host-gated, so a client's physics costs nothing but its
## own frame.

enum Kind { CAN, ROD, PLATE }

## What a kicked piece sounds like, per kind, for the log line and for M5's audio
## hookup. Nothing plays yet.
const KIND_NAMES: Array[String] = ["can", "rod", "plate"]

var kind: int = Kind.CAN

var _mesh: MeshInstance3D = null
var _noise_cooldown: float = 0.0
var _settled: float = 0.0
var _seed: int = 0


static func create(index: int, where: Vector3, of_kind: int) -> DebrisBody:
	var debris: DebrisBody = DebrisBody.new()
	debris.name = "Debris%d" % index
	debris.kind = clampi(of_kind, 0, 2)
	debris._seed = hash(str(index, ":debris:", of_kind))
	debris.position = where + Vector3(0.0, 0.08, 0.0)
	debris._assemble()
	return debris


func _assemble() -> void:
	# World layer, so the player's capsule and the breaker's hitscan both find it,
	# and it collides with the world and with players (mask 3) but never with the
	# antivirus — a Scrubber that shoves a can across a room would be pinging
	# itself, which is the funniest possible bug and not one worth shipping.
	collision_layer = 1
	collision_mask = 3
	continuous_cd = true
	can_sleep = true
	contact_monitor = true
	max_contacts_reported = 4
	# Generous margins. A 12 cm object at 6 m/s through a 40 cm slab is exactly
	# the case CCD exists for, and the margin is the belt to its braces.
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.friction = 0.85
	physics_material_override.bounce = 0.12

	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color(0.13, 0.135, 0.15)
	material.metallic = 0.65
	material.roughness = 0.52

	var shape: CollisionShape3D = CollisionShape3D.new()
	_mesh = MeshInstance3D.new()
	_mesh.material_override = material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED

	match kind:
		Kind.ROD:
			# A dropped conduit offcut. Long, thin, rolls beautifully, and is by
			# far the loudest thing to kick in a dark corridor.
			var rod: CylinderMesh = CylinderMesh.new()
			rod.top_radius = 0.045
			rod.bottom_radius = 0.045
			rod.height = 0.62
			rod.radial_segments = 8
			rod.rings = 0
			_mesh.mesh = rod
			var rod_shape: CylinderShape3D = CylinderShape3D.new()
			rod_shape.radius = 0.05
			rod_shape.height = 0.62
			shape.shape = rod_shape
			mass = 1.4
			rotation = Vector3(PI * 0.5, float(_seed % 360) * 0.0174, 0.0)
		Kind.PLATE:
			# A panel fragment. Heavy, does not travel far, lands with a slap.
			var plate: BoxMesh = BoxMesh.new()
			plate.size = Vector3(0.34, 0.035, 0.26)
			_mesh.mesh = plate
			var plate_shape: BoxShape3D = BoxShape3D.new()
			plate_shape.size = Vector3(0.34, 0.045, 0.26)
			shape.shape = plate_shape
			mass = 2.6
			rotation.y = float(_seed % 360) * 0.0174
		_:
			var can: CylinderMesh = CylinderMesh.new()
			can.top_radius = 0.055
			can.bottom_radius = 0.055
			can.height = 0.16
			can.radial_segments = 10
			can.rings = 0
			_mesh.mesh = can
			var can_shape: CylinderShape3D = CylinderShape3D.new()
			can_shape.radius = 0.058
			can_shape.height = 0.16
			shape.shape = can_shape
			mass = 0.55
			rotation.y = float(_seed % 360) * 0.0174

	add_child(_mesh)
	add_child(shape)


func _ready() -> void:
	add_to_group("debris")
	# Asleep on arrival. A layer builds ten of these in one frame and none of them
	# has any business being simulated until somebody walks into it.
	sleeping = true
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	_noise_cooldown = maxf(_noise_cooldown - delta, 0.0)
	if sleeping:
		_settled = 0.0
		return

	var speed: float = linear_velocity.length()
	if speed >= Balance.DEBRIS_NOISE_SPEED and _noise_cooldown <= 0.0:
		_noise_cooldown = Balance.DEBRIS_NOISE_COOLDOWN
		# One line per clatter under `--log-ai`, because "the antivirus hears
		# debris" is a claim that should be a log entry rather than a vibe.
		NoiseBus.ping(global_position, Balance.NOISE_ROOMS_DEBRIS,
				"debris:" + KIND_NAMES[kind], Balance.NOISE_TIME_DEBRIS)

	# Hand-parked. Godot's own sleep threshold lets a settled piece tremble for a
	# long time, and eight trembling pieces is eight broadphase pairs a layer does
	# not need to be paying for while the crew is two rooms away.
	if speed < Balance.DEBRIS_SLEEP_SPEED \
			and angular_velocity.length() < Balance.DEBRIS_SLEEP_SPEED:
		_settled += delta
		if _settled >= Balance.DEBRIS_SLEEP_DELAY:
			sleeping = true
	else:
		_settled = 0.0
