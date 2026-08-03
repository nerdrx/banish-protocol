extends Node3D
## M12 SENSATION — the visual bench: the breaker's reach, and the particle set.
##
##   tools/sensation_bench/shoot.sh <out.png> <WxH> -- --mode reach --reach 30 --gun 30
##   tools/sensation_bench/shoot.sh <out.png> <WxH> -- --mode particles --surface gel
##
## WHY A BENCH RATHER THAN THE GAME.
##
## The two things this milestone has to show are a WEAPON at three specific
## distances and a PARTICLE at a specific surface. Neither is something a shutter
## lands on by luck in a live layer: a procedurally generated room does not
## contain a target at exactly 30 m, and no scripted run can promise a Scrubber
## is standing on gel when the frame is taken. So the bench builds a controlled
## corridor with targets at known distances, lit exactly the way the game lights
## a layer, and fires the REAL `Breaker` through the REAL `Fx` autoload.
##
## What is real here, and it is nearly everything: the Breaker class, its lash
## mesh and `nv_lash` shader, the pooled Fx effects, the surface dispatch, the
## `A11y` caps, the player's own beam cone at Optics tier 0, and a
## `WorldEnvironment` copied from the layer's own resource. What is staged is the
## geometry and the trigger timing.
##
## THE BEFORE/AFTER. `--gun` is the reach the lash is drawn to. It is not a
## simulation of the old build: it is the same code path given the old number
## (8 m) and the new one (30 m), which is precisely what changed. A shot at a
## 30 m target with `--gun 8` ends in mid-air a third of the way there, which is
## what the complaint felt like.

## Optics tier 0, from Balance.MODULES — the beam this bench lights with is the
## beam a bare program carries, because the whole argument of the range change is
## about the relationship between the weapon and THAT.
const BEAM_ANGLE_DEG: float = 26.0
const BEAM_ENERGY: float = 6.6
const BEAM_REACH: float = 30.0

const EYE_HEIGHT: float = 1.62
## Where the targets stand. The three distances the report has to show.
const TARGET_DISTANCES: Array[float] = [6.0, 15.0, 30.0]
const CORRIDOR_WIDTH: float = 7.0
const CORRIDOR_HEIGHT: float = 4.6
const CORRIDOR_LENGTH: float = 42.0

## Targets stand this many degrees off the corridor axis, alternating sides.
##
## THE FIRST FRAMING OF THIS CAPTURE WAS UNUSABLE and the reason is worth
## keeping. With every target dead ahead and the lens aimed at it, the lash runs
## almost exactly along the view axis — so it is seen END-ON, and a 30 m beam
## renders as a bright dot in the middle of the screen. The shot was firing
## correctly and photographing nothing.
##
## 6.5 degrees is inside `BREAKER_AIM_DEG` (7.5), so every target here is one the
## cutter genuinely acquires — the capture is not cheating to get a diagonal. It
## also stops the three targets occluding each other, which the first version did
## as well: one capsule at 6 m hid both of the others.
const TARGET_OFF_AXIS_DEG: float = 6.5

var _mode: String = "reach"
var _reach: float = 30.0     ## which target to fire at
var _gun: float = 30.0       ## the reach the lash is drawn to (before/after)
var _surface: String = "metal"
var _camera: Camera3D = null
var _breaker: Breaker = null
var _fired: bool = false
var _tick: int = 0

## How many frames before the shutter the effect is triggered.
##
## THE LASH LIVES 0.1 SECONDS. At 60 fps that is six frames, so a shot fired at a
## fixed frame number and photographed at another fixed frame number is a coin
## toss — the first attempt at this capture fired at frame 200, photographed at
## 300, and produced a beautifully lit corridor with no beam in it. Rather than
## guess, the bench reads the shutter's OWN countdown (`Debug._frames_left`) and
## fires a set number of frames before it. The lash is therefore always alive and
## always at the same point in its fade, which also makes two captures
## comparable.
## How often the bench re-fires, in frames at the capture's pinned 60 fps.
##
## Particles get the weapon's REAL cadence (BREAKER_COOLDOWN 0.26 s ~= 16
## frames), because a particle burst lives 0.4-1.8 s and one is always in flight.
##
## The reach capture gets a faster one, and this is a SHUTTER-TIMING DEVICE
## rather than a claim about rate of fire: the lash lives 0.1 s — six frames —
## so at the real cadence it is on screen 38% of the time and a capture is a coin
## toss. Firing every four frames guarantees a live streak in the photograph. The
## streak drawn is exactly the streak one trigger pull draws; only how often it is
## redrawn differs, and no measurement in the report depends on the rate.
const REFIRE_FRAMES_PARTICLES: int = 16
const REFIRE_FRAMES_REACH: int = 6


func _ready() -> void:
	_parse_args()
	_build_room()
	_build_camera()
	# Fx parents its pools under the node in the "layer" group and frees them with
	# it. Giving the bench one means the real pooled path runs unchanged.
	add_to_group("layer")
	_breaker = Breaker.create()
	add_child(_breaker)
	set_process(true)


func _parse_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i: int in args.size():
		if i + 1 >= args.size():
			continue
		match args[i]:
			"--mode": _mode = args[i + 1]
			"--reach": _reach = float(args[i + 1])
			"--gun": _gun = float(args[i + 1])
			"--surface": _surface = args[i + 1]


# ------------------------------------------------------------------- the set --

func _build_room() -> void:
	var env: WorldEnvironment = WorldEnvironment.new()
	env.environment = load("res://src/world/layer_environment.tres") as Environment
	if env.environment == null:
		env.environment = Environment.new()
	add_child(env)

	var shell: Node3D = Node3D.new()
	shell.name = "Corridor"
	add_child(shell)
	var wall: StandardMaterial3D = StandardMaterial3D.new()
	wall.albedo_color = Color(0.155, 0.16, 0.175)
	wall.roughness = 0.62
	wall.metallic = 0.25
	# Floor, ceiling and two walls. A box room rather than a kit assembly: the
	# bench is about the weapon and the particles, and borrowing the real kit
	# would make every capture a hostage to M10's in-flight edits.
	_slab(shell, Vector3(CORRIDOR_WIDTH, 0.4, CORRIDOR_LENGTH),
			Vector3(0.0, -0.2, -CORRIDOR_LENGTH * 0.5 + 4.0), wall)
	_slab(shell, Vector3(CORRIDOR_WIDTH, 0.4, CORRIDOR_LENGTH),
			Vector3(0.0, CORRIDOR_HEIGHT, -CORRIDOR_LENGTH * 0.5 + 4.0), wall)
	_slab(shell, Vector3(0.4, CORRIDOR_HEIGHT, CORRIDOR_LENGTH),
			Vector3(-CORRIDOR_WIDTH * 0.5, CORRIDOR_HEIGHT * 0.5,
					-CORRIDOR_LENGTH * 0.5 + 4.0), wall)
	_slab(shell, Vector3(0.4, CORRIDOR_HEIGHT, CORRIDOR_LENGTH),
			Vector3(CORRIDOR_WIDTH * 0.5, CORRIDOR_HEIGHT * 0.5,
					-CORRIDOR_LENGTH * 0.5 + 4.0), wall)
	# The far end, so a 30 m shot that misses still lands on something.
	_slab(shell, Vector3(CORRIDOR_WIDTH, CORRIDOR_HEIGHT, 0.4),
			Vector3(0.0, CORRIDOR_HEIGHT * 0.5, -CORRIDOR_LENGTH + 4.0), wall)

	# Emissive trim down both walls. Not decoration: the environment resource
	# leans on SSIL and SSR for most of its readability, and a box with no
	# emissive surface anywhere in it gives both of them nothing to work with —
	# the room comes out blacker than the game ever is. Two dim inlays are the
	# minimum that makes the bench light like a layer.
	var inlay: StandardMaterial3D = StandardMaterial3D.new()
	inlay.albedo_color = Color(0.02, 0.03, 0.035)
	inlay.emission_enabled = true
	inlay.emission = Color(0.30, 0.72, 0.86)
	inlay.emission_energy_multiplier = 1.5
	for side: float in [-1.0, 1.0]:
		_trim(Vector3(0.06, 0.07, CORRIDOR_LENGTH),
				Vector3(side * (CORRIDOR_WIDTH * 0.5 - 0.22), 2.35,
						-CORRIDOR_LENGTH * 0.5 + 4.0), inlay)

	for distance: float in TARGET_DISTANCES:
		_target(distance)


## Emissive trim: a mesh with no collider, so it can never stop a shot.
func _trim(size: Vector3, at: Vector3, material: StandardMaterial3D) -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = material
	mesh.position = at
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)


func _slab(parent: Node3D, size: Vector3, at: Vector3,
		material: StandardMaterial3D) -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = material
	mesh.position = at
	parent.add_child(mesh)
	var body: StaticBody3D = StaticBody3D.new()
	body.collision_layer = 1
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box_shape: BoxShape3D = BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	body.position = at
	parent.add_child(body)


## A target silhouette at `distance`, with a distance label beside it so a
## capture cannot be wrong about which one it is showing.
## Where a target has to STAND for its centre to be exactly `distance` from the
## eye. The label on a reach capture is a claim about a number, so the number has
## to be the real one: a capsule dropped at z = -30 with its centre at 0.95 m and
## the eye at 1.62 m is 30.007 m away, and the first run of this bench duly
## reported "gun reaches 30 m -> falls short by 0 m".
func _target_z(distance: float) -> float:
	var rise: float = EYE_HEIGHT - 0.95
	var lateral: float = _target_x(distance)
	return -sqrt(maxf(distance * distance - rise * rise - lateral * lateral, 0.01))


## Alternating sides, so the three never overlap. See TARGET_OFF_AXIS_DEG.
func _target_x(distance: float) -> float:
	var side: float = -1.0 if int(distance) % 2 == 0 else 1.0
	if is_equal_approx(distance, 15.0):
		side = 1.0
	return side * distance * sin(deg_to_rad(TARGET_OFF_AXIS_DEG))


func _target(distance: float) -> void:
	var post: MeshInstance3D = MeshInstance3D.new()
	var capsule: CapsuleMesh = CapsuleMesh.new()
	capsule.radius = 0.34
	capsule.height = 1.7
	post.mesh = capsule
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	# The bestiary's own read: near-black shell, a seam of emissive in it. A
	# target that were bright would make the whole "can you see it at 30 m"
	# question meaningless.
	mat.albedo_color = Color(0.045, 0.05, 0.06)
	mat.roughness = 0.45
	mat.metallic = 0.4
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.2, 0.18)
	# Low. A target that lit itself would answer the very question this bench is
	# asked to photograph — whether you can SEE a thing at the edge of your beam.
	mat.emission_energy_multiplier = 0.22
	post.material_override = mat
	post.position = Vector3(_target_x(distance), 0.95, _target_z(distance))
	add_child(post)

	var label: Label3D = Label3D.new()
	label.text = "%d m" % int(distance)
	label.font_size = 64
	# Constant on-screen size regardless of range, so the three captures can be
	# put beside each other and the labels are all legible.
	label.pixel_size = 0.0016 * (distance / 6.0)
	label.modulate = Color(0.62, 0.9, 1.0, 0.85)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.position = Vector3(_target_x(distance) + 0.62, 1.72, _target_z(distance))
	add_child(label)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, EYE_HEIGHT, 0.0)
	_camera.fov = 74.0
	_camera.current = true
	add_child(_camera)
	# The lens looks DOWN THE CORRIDOR rather than at the target, which is both
	# what a player walking a corridor is doing and what makes the shot legible:
	# a lash fired at a target 6.5 degrees off the axis crosses the frame
	# diagonally instead of pointing at the viewer. It also keeps the three
	# captures framed identically, so they can be compared.
	# The player's own beam, at the bare-program Optics tier. This is the light
	# the whole range argument is about: the weapon now reaches exactly as far as
	# this does, so what the capture has to show is a target at the EDGE of it.
	# EVERY NUMBER HERE IS COPIED FROM `player.tscn`'s own Beam node. The first
	# version of this bench invented plausible-looking values (attenuation 1.1
	# against the real 0.55) and produced a corridor that was black three metres
	# out — which would have made the range capture a photograph of the bench's
	# lighting mistake rather than of the weapon. If the real beam changes, this
	# has to change with it; there is no way to share the node without dragging
	# the whole player scene into a bench.
	var beam: SpotLight3D = SpotLight3D.new()
	beam.light_color = Color(0.87, 0.91, 1.0)
	beam.light_energy = BEAM_ENERGY
	beam.light_indirect_energy = 0.35
	beam.light_volumetric_fog_energy = 2.1
	beam.light_specular = 0.5
	beam.shadow_enabled = true
	beam.shadow_bias = 0.035
	beam.shadow_normal_bias = 1.4
	beam.spot_range = BEAM_REACH
	beam.spot_attenuation = 0.55
	beam.spot_angle = BEAM_ANGLE_DEG
	beam.spot_angle_attenuation = 1.35
	beam.position = Vector3(0.0, -0.02, -0.45)
	_camera.add_child(beam)


# ------------------------------------------------------------------- the shot --

func _process(_delta: float) -> void:
	_tick += 1
	# Warm the Fx pools early. Building 95 emitters on the same frame one of them
	# is asked to fire is the sort of thing that works everywhere except in the
	# one measurement you need it in.
	if _tick == 30:
		Fx.bloom(Vector3(0.0, 1.0, -8.0), Color.WHITE, 0.0, 1.0)
	if _tick < 90:
		return
	# FIRE ON A CADENCE rather than once. The single-shot version was a bet that
	# the shutter's own frame countdown and the effect's lifetime would line up,
	# and it is a bet there is no reason to take: re-firing at the weapon's real
	# cadence means every frame from here on has a live effect in it, so the
	# capture cannot miss and two captures are directly comparable.
	var cadence: int = REFIRE_FRAMES_PARTICLES if _mode == "particles" \
			else REFIRE_FRAMES_REACH
	if _tick % cadence != 0:
		return
	if _mode == "particles":
		_show_particles()
	else:
		_show_reach()


## The reach capture. Draws the real lash from the muzzle to wherever the given
## gun reach stops it — at the target if it gets there, in mid-air if it does not.
func _show_reach() -> void:
	var from: Vector3 = _camera.global_position
	var direction: Vector3 = -_camera.global_transform.basis.z
	# Further from the lens than the avatar's real socket, because the bench
	# re-fires every six frames and a pooled bloom 0.55 m from the near plane
	# stacks into a white hole that eats the very beam the capture is of. The
	# LASH's own geometry and the impact end are untouched; only where the muzzle
	# glow sits has moved, and only in the bench.
	var muzzle: Vector3 = from + _camera.global_transform.basis * Vector3(0.34, -0.30, -1.15)
	var target: Vector3 = Vector3(_target_x(_reach), 0.95, _target_z(_reach))
	var to_target: float = from.distance_to(target)

	Fx.muzzle(muzzle, direction, Breaker.COLOUR)
	# The epsilon is float slop, not a fudge: the target is PLACED at exactly
	# `_reach` metres by `_target_z`, so a 30 m gun against a 30 m target is a
	# comparison of two numbers that should be equal and differ in the seventh
	# decimal. Without it the bench reported "falls short by 0 m".
	var reaches: bool = _gun + 0.01 >= to_target
	if reaches:
		# It reaches. The lash ends on the body and throws a creature spray.
		_breaker.show_lash(muzzle, target, false, (from - target).normalized(),
				Fx.SURF_CREATURE)
	else:
		# It does not. The streak stops at the weapon's reach, in mid-air, with
		# nothing to hit — which is exactly what eight metres felt like against
		# anything further away than eight metres.
		_breaker.show_lash(muzzle, from + direction * _gun, false,
				-direction, Fx.SURF_METAL)
	print("[Showcase] reach: target at %.0f m, gun reaches %.0f m -> %s" % [
		_reach, _gun,
		"HIT" if reaches else "falls short by %.1f m" % (to_target - _gun)])


## The particle capture. One surface at a time, plus the effect families that do
## not belong to a surface, so a showcase frame is legible instead of a soup.
func _show_particles() -> void:
	var at: Vector3 = Vector3(0.0, 1.2, -5.0)
	var normal: Vector3 = Vector3(0.0, 0.0, 1.0)
	match _surface:
		"metal": Fx.impact_on(at, normal, Fx.SURF_METAL, Breaker.COLOUR, true)
		"gel": Fx.impact_on(at, normal, Fx.SURF_GEL, Breaker.COLOUR, false)
		"screen": Fx.impact_on(at, normal, Fx.SURF_SCREEN, Breaker.COLOUR, true)
		"cable": Fx.impact_on(at, normal, Fx.SURF_CABLE, Breaker.COLOUR, true)
		"grate": Fx.impact_on(Vector3(0.0, 0.05, -5.0), Vector3.UP, Fx.SURF_GRATE,
				Breaker.COLOUR, true)
		"motes": Fx.motes(at, Color(0.62, 0.95, 1.0), 22)
		"steam": Fx.jet(Vector3(0.0, 0.3, -5.0), Vector3.UP, true)
		"coolant": Fx.jet(Vector3(-1.4, 2.4, -5.0), Vector3(0.6, -1.0, 0.0), false)
		"arc": Fx.arc(at, normal, Fx.TINT_CABLE)
		"footfall": Fx.footfall(Vector3(0.0, 0.0, -5.0), 1.0)
		"embers": Fx.impact_on(at, normal, Fx.SURF_METAL, Breaker.COLOUR, true)
		"telegraph": Fx.telegraph(Vector3(0.0, 0.05, -6.0), 6.0, Color(1.0, 0.25, 0.2))
		"glitch": Fx.mother_glitch(at, 20)
		_: Fx.impact_on(at, normal, Fx.SURF_METAL, Breaker.COLOUR, true)
	print("[Showcase] particles: %s  (counts %s)" % [_surface, str(Fx.counts)])
	var pool: Node = get_node_or_null(^"FxPool")
	print("[Showcase] pool=%s children=%d sparks=%d mist=%d" % [
		str(pool != null), 0 if pool == null else pool.get_child_count(),
		Fx._sparks.size(), Fx._mist.size()])
	if pool != null:
		for child: Node in pool.get_children():
			var em: CPUParticles3D = child as CPUParticles3D
			if em != null and em.emitting:
				print("   EMITTING %s at %s amount=%d visible=%s scale=%.3f" % [
					em.name, str(em.global_position), em.amount, str(em.is_visible_in_tree()),
					em.scale_amount_max])
