class_name SurgeTrail
extends Node3D
## SURGE STEP's afterimage — the ghost the process leaves behind when it migrates.
##
## The obvious implementation is to snapshot the avatar's skinned mesh once per
## frame of the dash and fade the copies out. It is also the wrong one here: the
## crew avatar is a 94-bone skinned mesh, and five duplicates of it per dash per
## player is five extra skinning passes and five draw calls that exist for 0.4 s,
## in a game already carrying volumetric fog, SSIL, SSR and TAA. In a four-crew
## fight that is a measurable frame cost for a garnish.
##
## So the ghosts are SILHOUETTES: unlit, additive, player-tinted capsules the size
## of the avatar's own body, dropped along the path and faded out back-to-front.
## In a near-black game lit by one beam, that is what an afterimage actually looks
## like — the shape of the thing, in its own colour, going out. The detail nobody
## can see in a 0.4 s streak is detail nobody should pay for.
##
## Cosmetic and local. Spawned on every peer from the host's validated cast echo,
## so a crewmate's dash trails on your screen; consumes no RNG.

## How many ghosts a dash leaves. Five reads as a trail; three reads as a stutter
## and eight reads as a smear.
const GHOSTS: int = 5
## Seconds each ghost lives. Longer than the dash itself so the last one is still
## fading as the avatar arrives — the trail must outlive the motion or it reads as
## the avatar being drawn twice rather than as a wake.
const GHOST_LIFE: float = 0.42
## Body capsule, matched to the crew avatar's silhouette rather than to its
## collision (which is a wider, gameplay-shaped pill).
const GHOST_RADIUS: float = 0.30
const GHOST_HEIGHT: float = 1.55
## Peak alpha of the leading ghost. The tail fades to nothing across the set.
const GHOST_ALPHA: float = 0.30
## Where along the dash the first ghost is dropped. See `_assemble`.
const TRAIL_START: float = 0.2
## Any ghost closer than this to the viewing lens is not drawn. Belt and braces
## over the back-face cull: a dash that ends against a wall can put the LAST
## ghost on top of the camera too, and a wake is a thing you look back at.
const LENS_CLEAR: float = 1.25

var _age: float = 0.0
var _ghosts: Array[MeshInstance3D] = []
var _material: StandardMaterial3D = null


## Builds the whole trail in one shot, along the straight line the dash will take.
## `from`/`to` are the endpoints the host validated; `yaw` orients the shells so
## the ghosts face the way the avatar was facing rather than the way it moved
## (a side-step leaves ghosts looking forward, which is correct and reads better).
static func create(from: Vector3, to: Vector3, yaw: float, tint: Color) -> SurgeTrail:
	var trail: SurgeTrail = SurgeTrail.new()
	trail.name = "SurgeTrail"
	trail._assemble(from, to, yaw, tint)
	return trail


func _assemble(from: Vector3, to: Vector3, yaw: float, tint: Color) -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.albedo_color = Color(tint.r, tint.g, tint.b, GHOST_ALPHA)
	_material.disable_receive_shadows = true
	# BACK-face culling, and it is load-bearing rather than an optimisation.
	#
	# The first capture of this effect was a wall of violet: in first person the
	# lens sits INSIDE the avatar, so it also sits inside the ghost dropped at the
	# origin — and an additive shell with culling disabled renders its own interior
	# across the entire frame. With back faces culled, a shell seen from inside
	# draws nothing at all, which is exactly the correct answer: you cannot see the
	# outside of a shape you are inside.
	_material.cull_mode = BaseMaterial3D.CULL_BACK

	var shell: CapsuleMesh = CapsuleMesh.new()
	shell.radius = GHOST_RADIUS
	shell.height = GHOST_HEIGHT
	shell.radial_segments = 10
	shell.rings = 4

	for i: int in GHOSTS:
		var ghost: MeshInstance3D = MeshInstance3D.new()
		ghost.name = "Ghost_%d" % i
		ghost.mesh = shell
		# One material, duplicated per ghost so each can carry its own alpha. The
		# mesh itself is shared — five instances of one capsule is one buffer.
		ghost.material_override = _material.duplicate() as StandardMaterial3D
		ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Distributed from a fifth of the way along rather than from the origin.
		# The ghost AT the origin is the one the caster is standing in on the frame
		# it spawns, and a wake should start behind you, not on you.
		var through: float = lerpf(TRAIL_START, 1.0,
				float(i) / float(maxi(GHOSTS - 1, 1)))
		ghost.global_position = from.lerp(to, through) + Vector3.UP * (GHOST_HEIGHT * 0.5)
		ghost.rotation.y = yaw
		# The trail STRETCHES toward the destination. A dash is a smear, and a
		# column of undistorted copies reads as a strobe of the same body.
		ghost.scale = Vector3(1.0 - through * 0.35, 1.0, 1.0 + through * 0.9)
		add_child(ghost)
		_ghosts.append(ghost)


func _ready() -> void:
	# Top-level: the trail is a world-space wake and must not follow the avatar it
	# came off, or it would travel with the dash instead of being left behind.
	top_level = true


func _process(delta: float) -> void:
	_age += delta
	var through: float = _age / GHOST_LIFE
	if through >= 1.0:
		queue_free()
		return
	for i: int in _ghosts.size():
		var ghost: MeshInstance3D = _ghosts[i]
		if ghost == null or not is_instance_valid(ghost):
			continue
		# Back to front. The oldest ghost (index 0, at the origin) is already
		# faintest and goes out first, so the trail visibly retracts toward where
		# the avatar ended up rather than dissolving evenly.
		var rank: float = float(i) / float(maxi(_ghosts.size() - 1, 1))
		var life: float = clampf((1.0 - through) * (0.45 + rank * 0.55), 0.0, 1.0)
		var material: StandardMaterial3D = ghost.material_override as StandardMaterial3D
		if material != null:
			material.albedo_color.a = life * GHOST_ALPHA * A11y.flash_scale
		var lens: Camera3D = get_viewport().get_camera_3d()
		ghost.visible = lens == null \
				or ghost.global_position.distance_to(lens.global_position) > LENS_CLEAR
