@tool
class_name FidelityWorkLight
extends Node3D
## TRIPOD WORK LIGHT — a practical the player can see, and a story they can read.
##
## THE MOTIVATION LAW, APPLIED TO A LIGHT FIXTURE
## Every other light in this game is architecture: it is bolted to the building
## because the building was built with lights in it. This one is not. It is a
## portable lamp on a tripod, which means somebody CARRIED it here, set it down,
## aimed it at the thing they were working on, and ran a cable back to a battery
## block because the wall socket in this room is dead. That is the whole design.
## Everything the prop contains exists to make that sentence legible without a
## word of text:
##
##   * The cable is ROUTED, not decorative. It leaves the head at a gland, is
##     tied down the column, reaches the floor, coils into a slack loop nobody
##     bothered to dress, and ends in the block's socket. Pillar 6: "cables run
##     FROM a source TO a load as routed connections, never sprinkled."
##   * The tripod legs are at 0 / 137 / 244 degrees, not 0 / 120 / 240. A tripod
##     set down on a floor by a person is never symmetric, and the moment it is,
##     the eye files the whole object under "asset".
##   * The lamp is AIMED at something below and ahead of it — the working
##     position — rather than at the room. A work light pointed at a room is a
##     room light with extra geometry.
##   * The toolbox variant puts the rest of the job in frame. Open lid, contents
##     visible. It is the difference between "a lamp" and "a lamp somebody is
##     coming back for".
##   * The floor scuff decal is where the tripod feet have been dragged. It
##     costs one decal and it says the lamp has been moved more than once.
##
## The head runs a GOBO by default (VENT_SLAT), because a bare work light throws
## the engine-default ellipse and the entire fidelity pass exists to stop that.
## The slats are justified: this is a caged lamp, and the cage has a louvred
## shroud on it to keep the glare out of the eyes of whoever is working.
##
## WHAT THE SCENE OWNS VS WHAT THIS SCRIPT OWNS
## work_light.tscn holds the authored hardware — tripod, column, head, guard,
## lens, and the SpotLight3D with its tuned cone. Those are art decisions with
## specific numbers and they belong in a file an artist can open. This script
## owns only what is DERIVED from the exports: the cable route (which depends on
## where the power block was placed), the block and toolbox variants, and the
## export toggles themselves. Nothing here re-authors geometry the scene already
## contains.

const CABLE_RADIUS: float = 0.0125
const CABLE_SEGMENTS: int = 44


@export_group("Light")
## Which projector mask the head shoots through. NONE gives the engine-default
## ellipse and is only there so the difference can be photographed.
@export var gobo: FidelityLib.Gobo = FidelityLib.Gobo.VENT_SLAT:
	set(v):
		gobo = v
		_apply_light()
## Halogen work lamps live between 2800 and 3200 K. The point of the number is
## the CONTRAST with MOTHER's ~6500 K architecture, not the number itself.
@export_range(1800.0, 7000.0, 10.0) var colour_temperature_k: float = 3050.0:
	set(v):
		colour_temperature_k = v
		_apply_light()
@export_range(0.0, 40.0, 0.1) var energy: float = 9.0:
	set(v):
		energy = v
		_apply_light()
@export_range(5.0, 80.0, 0.5) var spot_angle_deg: float = 34.0:
	set(v):
		spot_angle_deg = v
		_apply_light()
@export_range(1.0, 40.0, 0.5) var spot_range_m: float = 16.0:
	set(v):
		spot_range_m = v
		_apply_light()
@export var cast_shadows: bool = true:
	set(v):
		cast_shadows = v
		_apply_light()
## How hard the cone writes itself into the volumetric fog. Above ~2.0 the shaft
## stops being a shaft and becomes a solid cone of milk.
@export_range(0.0, 3.0, 0.05) var volumetric_boost: float = 1.6:
	set(v):
		volumetric_boost = v
		_apply_light()

@export_group("Aim")
## Down-tilt of the head. Negative points at the floor, which is where a work
## light points.
@export_range(-85.0, 30.0, 0.5) var head_pitch_deg: float = -27.0:
	set(v):
		head_pitch_deg = v
		_apply_aim()
## A few degrees of yaw off the tripod's own axis. Deliberately not zero by
## default: nobody sets a tripod down square to the thing they are lighting.
@export_range(-90.0, 90.0, 0.5) var head_yaw_deg: float = 9.0:
	set(v):
		head_yaw_deg = v
		_apply_aim()

@export_group("Power run")
## Where the battery block sits, in the light's own space. The cable is routed
## to it — move this and the cable re-routes. If you set it to Vector3.ZERO the
## block and the cable are both omitted (for a lamp that is genuinely mains-fed
## from off-screen), which is a legitimate choice and not a bug.
@export var power_block_offset: Vector3 = Vector3(1.42, 0.0, -0.95):
	set(v):
		power_block_offset = v
		_rebuild_dressing()
@export_range(0.0, 90.0, 1.0) var power_block_yaw_deg: float = -24.0:
	set(v):
		power_block_yaw_deg = v
		_rebuild_dressing()
## Extra cable beyond the straight-line distance, as a fraction. Zero looks like
## a taut guy-wire, which is the single most common cable mistake in games —
## nobody pays out exactly the length they need.
@export_range(0.0, 1.5, 0.01) var cable_slack: float = 0.55:
	set(v):
		cable_slack = v
		_rebuild_dressing()

@export_group("Story")
## The toolbox variant. Adds an open toolbox at the base — the rest of the job.
@export var toolbox: bool = false:
	set(v):
		toolbox = v
		_rebuild_dressing()
## Drag marks under the feet. One decal; says the lamp has been moved.
@export var floor_scuff: bool = true:
	set(v):
		floor_scuff = v
		_rebuild_dressing()
## Deterministic variation seed — coil shape, scuff choice, toolbox contents.
## Same seed, same lamp, on every peer.
@export var seed: int = 20260802:
	set(v):
		seed = v
		_rebuild_dressing()

@export_group("Fault")
## A failing ballast. OFF by default — most work lights work — and attached from
## the generator rather than authored, because whether THIS lamp is the broken
## one is a fact about the layer (see ProcLayerBuilder._place_work_lights).
@export var flicker: bool = false:
	set(v):
		flicker = v
		_apply_flicker()
## Deterministic phase, so four peers watch the same lamp stutter together with
## nothing on the wire.
@export var flicker_seed: float = 0.0:
	set(v):
		flicker_seed = v
		_apply_flicker()

var _dressing: Node3D = null
var _flicker: Node = null


# ---------------------------------------------------------------- the fault --
#
# SAFETY-CRITICAL (DESIGN.md pillar 7 / WCAG 2.3.1). This is a NEW temporal-flash
# source on a WORLD LIGHT, which is the exact class of effect the safety law was
# written about, so it gets the same treatment every other one in the game got:
#
#   1. It reuses `FlickerLight.Mode.ARC`, and it reuses it ON PURPOSE rather than
#      inventing a curve. ARC's phase advances at most 8.5 rad/s BY CONSTRUCTION
#      (base 7.0 plus a 1.5 rad/s wobble), so the rectified flash rate peaks at
#      8.5/PI ~= 2.7 Hz — under the 3 Hz line, with Reduced Flashing OFF. A new
#      curve would be a new thing to prove; this one is already proven and
#      already measured by `--selftest`.
#   2. Its swing is capped to 0.2 peak-to-peak inside `FlickerLight.level`, and
#      the base stays lit, so a failing work lamp browns out and never blacks
#      out. A practical that fully drops is also a practical that takes the only
#      light in a dark room away twice a second.
#   3. It multiplies by `A11y.flash_scale`, so Reduced Flashing calms it further.
#
# ARC rather than DYING is a deliberate choice and not the obvious one. DYING is
# the fluorescent-tube curve — long on, sudden full dropouts — and it is the
# right curve for the strip lights in MOTHER's ceiling. A halogen work lamp on a
# failing battery block does not drop out; it hunts. The two faults sound
# different and they look different, and using the tube curve here would make the
# player's own lamp read as more of MOTHER's architecture.

## Attach (or remove) the fault. The generator's entry point.
func attach_flicker(phase: float) -> void:
	flicker_seed = phase
	flicker = true


func _apply_flicker() -> void:
	if not is_inside_tree():
		return
	if _flicker != null and is_instance_valid(_flicker):
		_flicker.queue_free()
		_flicker = null
	var l: SpotLight3D = _spot()
	if l == null or not flicker:
		return
	# The same driver the LightRig uses for its own keys, so there is exactly one
	# implementation of "a light that misbehaves" in the codebase and exactly one
	# place a rate cap has to hold.
	l.set_meta("base_energy", l.light_energy)
	var driver: Node = load("res://src/world/flicker.gd").new()
	driver.name = "Flicker"
	driver.set("mode", FlickerLight.Mode.ARC)
	driver.set("base_energy", l.light_energy)
	driver.set("seed_offset", flicker_seed)
	l.add_child(driver)
	_flicker = driver


func _ready() -> void:
	_apply_light()
	_apply_aim()
	_rebuild_dressing()
	_apply_flicker()


# ----------------------------------------------------------------- the light --

func _spot() -> SpotLight3D:
	return get_node_or_null("Column/Head/Spot") as SpotLight3D


func _apply_light() -> void:
	if not is_inside_tree():
		return
	var l: SpotLight3D = _spot()
	if l == null:
		return
	l.light_color = FidelityLib.kelvin_to_color(colour_temperature_k)
	l.light_energy = energy
	# The CEILING the fault driver multiplies its curve against, not just the
	# current value. Without this, retuning `energy` on a lamp that is already
	# flickering writes a number the driver overwrites on the very next frame,
	# and the export silently stops doing anything.
	l.set_meta("base_energy", energy)
	l.spot_angle = spot_angle_deg
	l.spot_range = spot_range_m
	l.shadow_enabled = cast_shadows
	l.light_volumetric_fog_energy = volumetric_boost
	l.light_projector = FidelityLib.gobo_texture(gobo)

	# The lens is the visible source, so it has to agree with the light. A
	# practical whose emissive does not match its own beam colour is the tell
	# that the "fixture" is a decal in front of a spotlight.
	var lens: MeshInstance3D = get_node_or_null("Column/Head/Lens") as MeshInstance3D
	if lens != null:
		var m: StandardMaterial3D = lens.get_surface_override_material(0) as StandardMaterial3D
		if m != null:
			m.emission = FidelityLib.kelvin_to_color(colour_temperature_k)
			# Only just over the glow threshold (1.65 in layer_environment.tres),
			# so the lens blooms and nothing else in the prop does.
			m.emission_energy_multiplier = 2.1 * clampf(energy / 9.0, 0.25, 2.2)


func _apply_aim() -> void:
	if not is_inside_tree():
		return
	var head: Node3D = get_node_or_null("Column/Head") as Node3D
	if head == null:
		return
	head.rotation_degrees = Vector3(head_pitch_deg, head_yaw_deg, 0.0)


# -------------------------------------------------------------- the dressing --

func _rebuild_dressing() -> void:
	if not is_inside_tree():
		return
	if _dressing != null and is_instance_valid(_dressing):
		_dressing.queue_free()
	_dressing = Node3D.new()
	_dressing.name = "Dressing"
	add_child(_dressing)
	if Engine.is_editor_hint():
		_dressing.owner = null

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed

	if power_block_offset.length() > 0.05:
		_build_power_block(rng)
		_build_cable(rng)
	if toolbox:
		_build_toolbox(rng)
	if floor_scuff:
		_build_scuff(rng)


func _brushed() -> Material:
	return load(FidelityLib.MAT_BRUSHED_STEEL) as Material


func _hazard() -> Material:
	return load(FidelityLib.MAT_HAZARD_BAND) as Material


func _box(parent: Node3D, nm: String, size: Vector3, pos: Vector3,
		rot: Vector3, mat: Material) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = nm
	var bm: BoxMesh = BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.rotation_degrees = rot
	mi.set_surface_override_material(0, mat)
	parent.add_child(mi)
	return mi


func _build_power_block(rng: RandomNumberGenerator) -> void:
	## A sealed battery/transformer block. Squat, heavy, with a carry handle and
	## a hazard strip on the lid — because it is the thing in this arrangement
	## that will actually hurt you.
	var root: Node3D = Node3D.new()
	root.name = "PowerBlock"
	root.position = power_block_offset
	root.rotation_degrees = Vector3(0.0, power_block_yaw_deg, 0.0)
	_dressing.add_child(root)

	_box(root, "Body", Vector3(0.38, 0.235, 0.28), Vector3(0.0, 0.1175, 0.0),
			Vector3.ZERO, _brushed())
	# The hazard strip runs along the lid edge only — the edge you grab and the
	# edge that is live. Painting the whole box would say nothing.
	var lid: MeshInstance3D = _box(root, "LidStrip", Vector3(0.39, 0.055, 0.29),
			Vector3(0.0, 0.245, 0.0), Vector3.ZERO, _hazard())
	# One tile across the long axis so the band lands once, not four times.
	lid.set_instance_shader_parameter("uv1_scale", Vector3.ONE)
	_box(root, "Handle", Vector3(0.16, 0.022, 0.030), Vector3(0.0, 0.292, 0.0),
			Vector3.ZERO, _brushed())
	_box(root, "HandleL", Vector3(0.022, 0.055, 0.030), Vector3(-0.069, 0.268, 0.0),
			Vector3.ZERO, _brushed())
	_box(root, "HandleR", Vector3(0.022, 0.055, 0.030), Vector3(0.069, 0.268, 0.0),
			Vector3.ZERO, _brushed())

	# The socket the cable actually plugs into, on the face pointing back at the
	# lamp. `_cable_end()` reads this position, so the cable can never miss it.
	var socket: MeshInstance3D = MeshInstance3D.new()
	socket.name = "Socket"
	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.top_radius = 0.030
	cyl.bottom_radius = 0.034
	cyl.height = 0.055
	cyl.radial_segments = 12
	socket.mesh = cyl
	socket.position = Vector3(0.0, 0.135, 0.163)
	socket.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	socket.set_surface_override_material(0, _brushed())
	root.add_child(socket)

	# It has been set down on a floor and slid. Slight tilt sells the weight.
	root.rotation_degrees += Vector3(0.0, 0.0, rng.randf_range(-1.4, 1.4))


func _cable_end() -> Vector3:
	var yaw: float = deg_to_rad(power_block_yaw_deg)
	var local_socket: Vector3 = Vector3(0.0, 0.135, 0.19)
	var rotated: Vector3 = Vector3(
			local_socket.x * cos(yaw) + local_socket.z * sin(yaw),
			local_socket.y,
			-local_socket.x * sin(yaw) + local_socket.z * cos(yaw))
	return power_block_offset + rotated


func _build_cable(rng: RandomNumberGenerator) -> void:
	## The route, in order, from source to load:
	##   head gland -> droop -> tie at the collar -> tie at mid column -> the
	##   foot of the column -> a slack coil dropped on the floor -> the socket.
	##
	## Drawn as ONE MultiMeshInstance3D. 44 segments as 44 MeshInstance3Ds would
	## be 44 draw calls for a piece of set dressing; as a multimesh it is one,
	## which is the difference between this prop being placeable in quantity and
	## being a screenshot piece.
	var end: Vector3 = _cable_end()
	var foot: Vector3 = Vector3(0.055, CABLE_RADIUS + 0.004, 0.06)

	var pts: PackedVector3Array = PackedVector3Array()
	pts.append(Vector3(0.055, 1.505, 0.085))                 # gland at the head
	pts.append(Vector3(0.075, 1.36, 0.12))                   # the droop
	pts.append(Vector3(0.040, 1.10, 0.045))                  # tie at the collar
	pts.append(Vector3(0.028, 0.60, 0.038))                  # tie at mid column
	pts.append(foot)

	# The slack coil. Nobody pays out exactly the length they need, so the
	# surplus ends up as a loose loop on the floor near the base. Its size is
	# driven by `cable_slack` so the export means something physical.
	var direct: float = foot.distance_to(end)
	var surplus: float = direct * cable_slack
	if surplus > 0.15:
		var loop_r: float = clampf(surplus / (2.0 * PI), 0.10, 0.42)
		var toward: Vector3 = (end - foot)
		toward.y = 0.0
		if toward.length() < 0.01:
			toward = Vector3(1.0, 0.0, 0.0)
		toward = toward.normalized()
		var side: Vector3 = Vector3(-toward.z, 0.0, toward.x)
		var centre: Vector3 = foot + toward * (loop_r * 0.9) + side * (loop_r * 0.5)
		centre.y = CABLE_RADIUS + 0.004
		var phase: float = rng.randf_range(0.0, TAU)
		var turns: int = 7
		for i in turns + 1:
			var a: float = phase + TAU * float(i) / float(turns)
			# The loop is an ellipse, not a circle, and it wanders — a perfect
			# circle of cable on a floor is a spring, not a cable.
			var wobble: float = 1.0 + 0.16 * sin(a * 3.0 + phase)
			pts.append(centre
					+ toward * (cos(a) * loop_r * 1.25 * wobble)
					+ side * (sin(a) * loop_r * 0.78 * wobble)
					+ Vector3(0.0, 0.004 * sin(a * 2.0), 0.0))

	pts.append(end + Vector3(0.0, -0.03, 0.0) + (foot - end).normalized() * 0.14)
	pts.append(end)

	var samples: PackedVector3Array = _catmull_rom(pts, CABLE_SEGMENTS)

	var mesh: CylinderMesh = CylinderMesh.new()
	mesh.top_radius = CABLE_RADIUS
	mesh.bottom_radius = CABLE_RADIUS
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.rings = 1
	mesh.material = _cable_material()

	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = samples.size() - 1
	for i in samples.size() - 1:
		mm.set_instance_transform(i, _segment_transform(samples[i], samples[i + 1]))

	var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	mmi.name = "Cable"
	mmi.multimesh = mm
	# A cable is thin and dark; it does not earn a shadow map slot, and at 44
	# segments it would cost one per light in range.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dressing.add_child(mmi)


## A unit-height +Y cylinder, stretched and rotated onto the segment a->b.
static func _segment_transform(a: Vector3, b: Vector3) -> Transform3D:
	var d: Vector3 = b - a
	var len: float = d.length()
	if len < 0.0001:
		return Transform3D(Basis().scaled(Vector3(1.0, 0.0001, 1.0)), a)
	var up: Vector3 = d / len
	var ref: Vector3 = Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var right: Vector3 = ref.cross(up).normalized()
	var fwd: Vector3 = up.cross(right).normalized()
	var basis: Basis = Basis(right, up * len, fwd)
	return Transform3D(basis, a + d * 0.5)


## Uniform Catmull-Rom through the control points, with the ends duplicated so
## the curve actually starts and finishes where it was told to.
static func _catmull_rom(pts: PackedVector3Array, samples: int) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	if pts.size() < 2:
		return pts
	var n: int = pts.size()
	for s in samples + 1:
		var t: float = float(s) / float(samples) * float(n - 1)
		var i: int = clampi(int(floor(t)), 0, n - 2)
		var f: float = t - float(i)
		var p0: Vector3 = pts[maxi(i - 1, 0)]
		var p1: Vector3 = pts[i]
		var p2: Vector3 = pts[i + 1]
		var p3: Vector3 = pts[mini(i + 2, n - 1)]
		out.append(0.5 * (
				2.0 * p1
				+ (p2 - p0) * f
				+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f * f
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f * f * f))
	return out


func _cable_material() -> StandardMaterial3D:
	var m: StandardMaterial3D = StandardMaterial3D.new()
	# Rubber flex: dark, dielectric, and NOT matte. A cable jacket has a low
	# broad sheen that catches a raking light along its whole length, which is
	# most of what makes a cable read as a cable rather than as a black tube.
	m.albedo_color = Color(0.055, 0.056, 0.060)
	m.roughness = 0.46
	m.metallic = 0.0
	return m


func _build_toolbox(rng: RandomNumberGenerator) -> void:
	## The rest of the job. Lid open, because a closed toolbox is furniture and
	## an open one is an interruption.
	var root: Node3D = Node3D.new()
	root.name = "Toolbox"
	root.position = Vector3(-0.62, 0.0, 0.46)
	root.rotation_degrees = Vector3(0.0, rng.randf_range(-40.0, -12.0), 0.0)
	_dressing.add_child(root)

	_box(root, "Body", Vector3(0.46, 0.185, 0.22), Vector3(0.0, 0.0925, 0.0),
			Vector3.ZERO, _brushed())
	_box(root, "Foot", Vector3(0.42, 0.018, 0.19), Vector3(0.0, 0.009, 0.0),
			Vector3.ZERO, _brushed())
	# Lid, hinged at the back and fallen open past vertical the way a real lid
	# does when you let go of it.
	var lid: Node3D = Node3D.new()
	lid.name = "Lid"
	lid.position = Vector3(0.0, 0.185, -0.11)
	lid.rotation_degrees = Vector3(rng.randf_range(-116.0, -96.0), 0.0, 0.0)
	root.add_child(lid)
	_box(lid, "LidPanel", Vector3(0.46, 0.015, 0.22), Vector3(0.0, 0.0075, -0.11),
			Vector3.ZERO, _brushed())
	_box(lid, "LidEdge", Vector3(0.46, 0.030, 0.020), Vector3(0.0, 0.015, -0.21),
			Vector3.ZERO, _hazard())

	# Contents: three tools of different lengths, dropped in at angles. Sized so
	# they read at 2 m as "things", never as identifiable objects — a recognisable
	# spanner would raise questions about who manufactures spanners inside a
	# rogue AI, and the answer to that is a different milestone.
	for i in 3:
		var l: float = rng.randf_range(0.13, 0.27)
		_box(root, "Tool%d" % i,
				Vector3(l, rng.randf_range(0.016, 0.030), rng.randf_range(0.020, 0.038)),
				Vector3(rng.randf_range(-0.13, 0.13), 0.185 + 0.012 * float(i),
						rng.randf_range(-0.06, 0.06)),
				Vector3(0.0, rng.randf_range(-55.0, 55.0), rng.randf_range(-4.0, 4.0)),
				_brushed())


func _build_scuff(rng: RandomNumberGenerator) -> void:
	## Drag marks under the feet. A Decal rather than geometry so it takes the
	## floor's own normal and lighting, and so it costs nothing when the room is
	## dark — which, in this game, is most of the time.
	var d: Decal = Decal.new()
	d.name = "FloorScuff"
	var tex: Texture2D = load(
			FidelityLib.SCUFF_TEXTURES[rng.randi() % FidelityLib.SCUFF_TEXTURES.size()]
			) as Texture2D
	if tex == null:
		return
	d.texture_albedo = tex
	d.size = Vector3(1.85, 0.7, 1.85)
	d.position = Vector3(rng.randf_range(-0.1, 0.1), 0.30, rng.randf_range(-0.1, 0.1))
	d.rotation_degrees = Vector3(0.0, rng.randf_range(0.0, 360.0), 0.0)
	# Subtractive, not additive: a scuff is where the floor got DARKER and
	# rougher, and a decal that brightens the floor under a lamp reads as a
	# lighting bug rather than as dirt.
	d.modulate = Color(0.30, 0.31, 0.33, 1.0)
	d.albedo_mix = 0.55
	# Fade with distance so a room full of these does not cost a decal pass at
	# 30 m for marks nobody can resolve past 8.
	d.distance_fade_enabled = true
	d.distance_fade_begin = 9.0
	d.distance_fade_length = 5.0
	# Only project onto near-horizontal surfaces. Without this the mark climbs
	# the tripod legs and the toolbox, which is exactly the failure that makes
	# decal dirt look sprayed on rather than trodden in.
	d.normal_fade = 0.55
	_dressing.add_child(d)
