class_name GeometryKit
extends Node3D
## The room-kit primitives every security layer is assembled from.
##
## M1 grew this vocabulary inside the hand-authored greybox (slabs, doored walls,
## lit gate frames, hairline circuit traces, conduit runs, data blocks). M2 lifts
## it out so the procedural generator emits exactly the same architecture as the
## hand-built test layer — one art direction, two sources of layout.
##
## Art direction (DESIGN.md "Environment language"): modern digital brutalism.
## Matte near-black monolithic slabs, hairline emissive circuit traces inlaid on
## walls and floors, data conduits, and a floor grid. The traces are the only
## thing rendering the space when your beam points elsewhere, so they double as
## navigation — follow the light to find the gate.
##
## Conventions: +X east, -Z north, y=0 is the walking surface. Walls are centred
## on the room boundary, so a room and the corridor bolted to it share one wall
## and there is no coplanar z-fighting. Corridors therefore build only their long
## sides; their ends are the doorway holes cut in the room walls.
##
## Subclasses fill `_build_content()`; `build()` owns the containers and the
## shared materials.

const WALL_THICKNESS: float = 0.4
const SLAB_THICKNESS: float = 0.4
const DOOR_WIDTH: float = 3.2
const DOOR_HEIGHT: float = 3.4

## How far proud of a wall boundary a surface trace sits.
const TRACE_FACE: float = WALL_THICKNESS * 0.5 + 0.015
const TRACE_WIDTH: float = 0.035
## Below eye level on purpose. At eye height a continuous trace reads as a laser
## line bisecting the screen; down here it reads as inlay in a wall.
const TRACE_HEIGHT: float = 0.95
## Clearance left around a gate so traces stop short of the frame instead of
## sailing across the opening.
const TRACE_GATE_MARGIN: float = 0.5

## The system's own colour. Traces, gates and most conduits run this teal;
## anything warm is a deliberate accent, anything red is hostile.
const SYSTEM_TEAL: Color = Color(0.32, 0.86, 1.0)
const SYSTEM_AMBER: Color = Color(1.0, 0.62, 0.26)

## Godot's positional lights fall off as pow(distance, -attenuation): with this
## gentle decay a conduit node still delivers ~25% of its energy 5 m away, which
## is why the energies in the tables look high.
const LIGHT_DECAY: float = 0.85

const MAT_MONOLITH: StandardMaterial3D = preload("res://assets/materials/monolith_wall.tres")
const MAT_FLOOR: StandardMaterial3D = preload("res://assets/materials/monolith_floor.tres")
const MAT_CONDUIT: StandardMaterial3D = preload("res://assets/materials/conduit.tres")
const MAT_BLOCK: StandardMaterial3D = preload("res://assets/materials/data_block.tres")

var _geometry: Node3D
var _colliders: StaticBody3D
var _fixtures: Node3D
var _gate_material: StandardMaterial3D
var _trace_material: StandardMaterial3D
var _grid_material: StandardMaterial3D

## Scales every fixture energy this builder emits. The procedural builder drives
## it from LayerParams so deeper layers are darker without every call site
## needing to know about the threat curve.
var light_scale: float = 1.0


func _ready() -> void:
	build()


func build() -> void:
	_geometry = Node3D.new()
	_geometry.name = "Geometry"
	add_child(_geometry)

	_colliders = StaticBody3D.new()
	_colliders.name = "Colliders"
	_colliders.collision_layer = 1
	_colliders.collision_mask = 0
	add_child(_colliders)

	_fixtures = Node3D.new()
	_fixtures.name = "Fixtures"
	add_child(_fixtures)

	# Emission energies stay low: anything much above ~1.0 clips through the ACES
	# curve into a featureless white blob once glow is applied. The hierarchy is
	# deliberate — gates brightest (they are the exits), then wall traces, then
	# the floor grid, which should be barely more than a suggestion.
	_gate_material = _make_emissive(SYSTEM_TEAL, 0.85)
	_trace_material = _make_emissive(SYSTEM_TEAL, 0.38)
	_grid_material = _make_emissive(Color(0.22, 0.6, 0.95), 0.22)

	_build_content()


## Subclass hook: emit the layer.
func _build_content() -> void:
	pass


# ------------------------------------------------------------------- shells --

func _build_room(room: Dictionary) -> void:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var h: float = room["h"]
	var doors: Array = room.get("doors", []) as Array

	_slab(lo, hi, -SLAB_THICKNESS * 0.5, MAT_FLOOR)
	_slab(lo, hi, h + SLAB_THICKNESS * 0.5, MAT_MONOLITH)

	_wall_at_z(lo.y, lo.x, hi.x, h, _doors_on(doors, "n"))
	_wall_at_z(hi.y, lo.x, hi.x, h, _doors_on(doors, "s"))
	_wall_at_x(lo.x, lo.y, hi.y, h, _doors_on(doors, "w"))
	_wall_at_x(hi.x, lo.y, hi.y, h, _doors_on(doors, "e"))

	_floor_grid(lo, hi, 4.0)
	_room_wall_traces(room)


func _build_corridor(corridor: Dictionary) -> void:
	var lo: Vector2 = corridor["min"]
	var hi: Vector2 = corridor["max"]
	var h: float = corridor["h"]
	var top: float = minf(TRACE_HEIGHT + 1.4, h - 0.3)

	_slab(lo, hi, -SLAB_THICKNESS * 0.5, MAT_FLOOR)
	_slab(lo, hi, h + SLAB_THICKNESS * 0.5, MAT_MONOLITH)

	if String(corridor["axis"]) == "z":
		_wall_at_x(lo.x, lo.y, hi.y, h, [])
		_wall_at_x(hi.x, lo.y, hi.y, h, [])
		# One trace down the centre of the floor: the corridor reads as a data
		# path you are walking along, and it points both ways in the dark.
		_trace(Vector3((lo.x + hi.x) * 0.5, 0.014, lo.y + 0.6),
				Vector3((lo.x + hi.x) * 0.5, 0.014, hi.y - 0.6), _grid_material)
		_wall_trace_run(Vector3(lo.x + TRACE_FACE, TRACE_HEIGHT, lo.y + 0.6),
				Vector3(lo.x + TRACE_FACE, TRACE_HEIGHT, hi.y - 0.6), top, 4.0)
		_wall_trace_run(Vector3(hi.x - TRACE_FACE, TRACE_HEIGHT, lo.y + 0.6),
				Vector3(hi.x - TRACE_FACE, TRACE_HEIGHT, hi.y - 0.6), top, 4.0)
	else:
		_wall_at_z(lo.y, lo.x, hi.x, h, [])
		_wall_at_z(hi.y, lo.x, hi.x, h, [])
		_trace(Vector3(lo.x + 0.6, 0.014, (lo.y + hi.y) * 0.5),
				Vector3(hi.x - 0.6, 0.014, (lo.y + hi.y) * 0.5), _grid_material)
		_wall_trace_run(Vector3(lo.x + 0.6, TRACE_HEIGHT, lo.y + TRACE_FACE),
				Vector3(hi.x - 0.6, TRACE_HEIGHT, lo.y + TRACE_FACE), top, 4.0)
		_wall_trace_run(Vector3(lo.x + 0.6, TRACE_HEIGHT, hi.y - TRACE_FACE),
				Vector3(hi.x - 0.6, TRACE_HEIGHT, hi.y - TRACE_FACE), top, 4.0)
	_rib_run(lo, hi, h, String(corridor["axis"]))


## Structural ribs every few metres. Cheap, but they give a corridor a rhythm
## and a reason for the beam to throw moving shadows as you walk.
func _rib_run(lo: Vector2, hi: Vector2, h: float, axis: String) -> void:
	var spacing: float = 3.0
	if axis == "z":
		var z: float = lo.y + spacing * 0.5
		while z < hi.y:
			_mesh_box(Vector3((lo.x + hi.x) * 0.5, h - 0.18, z),
					Vector3(hi.x - lo.x, 0.36, 0.28), MAT_CONDUIT)
			_mesh_box(Vector3(lo.x + 0.14, h * 0.5, z), Vector3(0.28, h, 0.28), MAT_CONDUIT)
			_mesh_box(Vector3(hi.x - 0.14, h * 0.5, z), Vector3(0.28, h, 0.28), MAT_CONDUIT)
			z += spacing
	else:
		var x: float = lo.x + spacing * 0.5
		while x < hi.x:
			_mesh_box(Vector3(x, h - 0.18, (lo.y + hi.y) * 0.5),
					Vector3(0.28, 0.36, hi.y - lo.y), MAT_CONDUIT)
			_mesh_box(Vector3(x, h * 0.5, lo.y + 0.14), Vector3(0.28, h, 0.28), MAT_CONDUIT)
			_mesh_box(Vector3(x, h * 0.5, hi.y - 0.14), Vector3(0.28, h, 0.28), MAT_CONDUIT)
			x += spacing


func _doors_on(doors: Array, wall: String) -> Array:
	var result: Array = []
	for door: Dictionary in doors:
		if String(door.get("wall", "")) == wall:
			result.append(door)
	return result


func _slab(lo: Vector2, hi: Vector2, y: float, material: StandardMaterial3D) -> void:
	_box(Vector3((lo.x + hi.x) * 0.5, y, (lo.y + hi.y) * 0.5),
			Vector3(hi.x - lo.x + WALL_THICKNESS, SLAB_THICKNESS, hi.y - lo.y + WALL_THICKNESS),
			material)


## Wall in the XY plane at a fixed Z, spanning [x0, x1], pierced by `doors`.
func _wall_at_z(z: float, x0: float, x1: float, h: float, doors: Array) -> void:
	var spans: Array[Vector2] = _solid_spans(x0, x1, doors)
	for span: Vector2 in spans:
		_box(Vector3((span.x + span.y) * 0.5, h * 0.5, z),
				Vector3(span.y - span.x, h, WALL_THICKNESS), MAT_MONOLITH)
	for door: Dictionary in doors:
		var at: float = float(door.get("at", 0.0))
		var w: float = float(door.get("w", DOOR_WIDTH))
		var dh: float = float(door.get("h", DOOR_HEIGHT))
		if h > dh:
			_box(Vector3(at, (dh + h) * 0.5, z), Vector3(w, h - dh, WALL_THICKNESS), MAT_MONOLITH)
		_gate_frame(Vector3(at, 0.0, z), w, dh, "z")


## Wall in the ZY plane at a fixed X, spanning [z0, z1], pierced by `doors`.
func _wall_at_x(x: float, z0: float, z1: float, h: float, doors: Array) -> void:
	var spans: Array[Vector2] = _solid_spans(z0, z1, doors)
	for span: Vector2 in spans:
		_box(Vector3(x, h * 0.5, (span.x + span.y) * 0.5),
				Vector3(WALL_THICKNESS, h, span.y - span.x), MAT_MONOLITH)
	for door: Dictionary in doors:
		var at: float = float(door.get("at", 0.0))
		var w: float = float(door.get("w", DOOR_WIDTH))
		var dh: float = float(door.get("h", DOOR_HEIGHT))
		if h > dh:
			_box(Vector3(x, (dh + h) * 0.5, at), Vector3(WALL_THICKNESS, h - dh, w), MAT_MONOLITH)
		_gate_frame(Vector3(x, 0.0, at), w, dh, "x")


## Splits [from, to] into the solid runs left over after the doors are removed.
func _solid_spans(from: float, to: float, doors: Array) -> Array[Vector2]:
	var openings: Array[Vector2] = []
	for door: Dictionary in doors:
		var at: float = float(door.get("at", 0.0))
		var half: float = float(door.get("w", DOOR_WIDTH)) * 0.5
		openings.append(Vector2(at - half, at + half))
	openings.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)

	var spans: Array[Vector2] = []
	var cursor: float = from
	for opening: Vector2 in openings:
		if opening.x - cursor > 0.02:
			spans.append(Vector2(cursor, opening.x))
		cursor = maxf(cursor, opening.y)
	if to - cursor > 0.02:
		spans.append(Vector2(cursor, to))
	return spans


## Lit gate frame. Gates are the brightest thing on the layer, which makes them
## read as navigation beacons from the far end of a dark corridor.
func _gate_frame(base: Vector3, width: float, height: float, normal_axis: String) -> void:
	var half: float = width * 0.5
	var bar: float = 0.075
	if normal_axis == "z":
		_mesh_box(base + Vector3(-half, height * 0.5, 0.0),
				Vector3(bar, height, WALL_THICKNESS + 0.06), _gate_material)
		_mesh_box(base + Vector3(half, height * 0.5, 0.0),
				Vector3(bar, height, WALL_THICKNESS + 0.06), _gate_material)
		_mesh_box(base + Vector3(0.0, height, 0.0),
				Vector3(width, bar, WALL_THICKNESS + 0.06), _gate_material)
	else:
		_mesh_box(base + Vector3(0.0, height * 0.5, -half),
				Vector3(WALL_THICKNESS + 0.06, height, bar), _gate_material)
		_mesh_box(base + Vector3(0.0, height * 0.5, half),
				Vector3(WALL_THICKNESS + 0.06, height, bar), _gate_material)
		_mesh_box(base + Vector3(0.0, height, 0.0),
				Vector3(WALL_THICKNESS + 0.06, bar, width), _gate_material)


# ------------------------------------------------------------------- traces --

## Hairline emissive inlay between two axis-aligned points.
func _trace(from: Vector3, to: Vector3, material: StandardMaterial3D,
		width: float = TRACE_WIDTH) -> void:
	var delta: Vector3 = to - from
	var size: Vector3 = Vector3(
			maxf(absf(delta.x), width),
			maxf(absf(delta.y), width),
			maxf(absf(delta.z), width))
	_mesh_box((from + to) * 0.5, size, material)


## A horizontal trace run with vertical branches climbing off it at intervals —
## the circuit-inlay motif. `from`/`to` must share two axes.
func _wall_trace_run(from: Vector3, to: Vector3, top: float, branch_every: float) -> void:
	_trace(from, to, _trace_material)
	var length: float = (to - from).length()
	if length < 0.5 or branch_every <= 0.0:
		return
	var direction: Vector3 = (to - from) / length
	var travelled: float = branch_every * 0.5
	while travelled < length:
		var point: Vector3 = from + direction * travelled
		_trace(point, Vector3(point.x, top, point.z), _trace_material)
		travelled += branch_every


## Faint grid inlaid in the floor slab. Gives the eye something to track when a
## beam sweeps across an otherwise featureless expanse, and sells the fiction
## that the floor is rendered rather than built.
func _floor_grid(lo: Vector2, hi: Vector2, spacing: float) -> void:
	var y: float = 0.014
	var x: float = lo.x + spacing
	while x < hi.x - 0.1:
		_trace(Vector3(x, y, lo.y + 0.5), Vector3(x, y, hi.y - 0.5), _grid_material, 0.03)
		x += spacing
	var z: float = lo.y + spacing
	while z < hi.y - 0.1:
		_trace(Vector3(lo.x + 0.5, y, z), Vector3(hi.x - 0.5, y, z), _grid_material, 0.03)
		z += spacing


## Circuit traces around a room's four walls, broken around every gate so a run
## never sails across an opening.
func _room_wall_traces(room: Dictionary) -> void:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var h: float = room["h"]
	var doors: Array = room.get("doors", []) as Array
	var top: float = minf(TRACE_HEIGHT + 1.6, h - 0.4)
	var inset: float = 0.8

	for span: Vector2 in _trace_spans(lo.x + inset, hi.x - inset, _doors_on(doors, "n")):
		_wall_trace_run(Vector3(span.x, TRACE_HEIGHT, lo.y + TRACE_FACE),
				Vector3(span.y, TRACE_HEIGHT, lo.y + TRACE_FACE), top, 5.0)
	for span: Vector2 in _trace_spans(lo.x + inset, hi.x - inset, _doors_on(doors, "s")):
		_wall_trace_run(Vector3(span.x, TRACE_HEIGHT, hi.y - TRACE_FACE),
				Vector3(span.y, TRACE_HEIGHT, hi.y - TRACE_FACE), top, 5.0)
	for span: Vector2 in _trace_spans(lo.y + inset, hi.y - inset, _doors_on(doors, "w")):
		_wall_trace_run(Vector3(lo.x + TRACE_FACE, TRACE_HEIGHT, span.x),
				Vector3(lo.x + TRACE_FACE, TRACE_HEIGHT, span.y), top, 5.0)
	for span: Vector2 in _trace_spans(lo.y + inset, hi.y - inset, _doors_on(doors, "e")):
		_wall_trace_run(Vector3(hi.x - TRACE_FACE, TRACE_HEIGHT, span.x),
				Vector3(hi.x - TRACE_FACE, TRACE_HEIGHT, span.y), top, 5.0)


## Solid runs left on a wall after each gate is removed with clearance, dropping
## stubs too short to read as anything but a speck.
func _trace_spans(from: float, to: float, doors: Array) -> Array[Vector2]:
	var widened: Array = []
	for door: Dictionary in doors:
		widened.append({
			"at": door.get("at", 0.0),
			"w": float(door.get("w", DOOR_WIDTH)) + TRACE_GATE_MARGIN * 2.0,
		})
	var spans: Array[Vector2] = []
	for span: Vector2 in _solid_spans(from, to, widened):
		if span.y - span.x > 0.8:
			spans.append(span)
	return spans


# ------------------------------------------------------------------- lights --

## Conduit node: a junction box where a trace run terminates and actually throws
## light. These are a layer's only ambient illumination.
##
## `spec` keys: pos, axis ("x"/"z"), len, color, energy, range, flicker, and an
## optional `normal` — the direction to nudge the light source away from the
## surface it is mounted on, so the housing does not shadow itself. Without an
## explicit normal we fall back to M1's "push away from the origin" heuristic,
## which is correct for the hand-authored layer built around 0,0.
func _build_conduit_node(spec: Dictionary) -> void:
	var pos: Vector3 = spec["pos"]
	var length: float = spec["len"]
	var color: Color = spec["color"]
	var energy: float = float(spec["energy"]) * light_scale
	var flicker: bool = spec["flicker"]

	var housing_size: Vector3 = Vector3(0.12, 0.14, length) if String(spec["axis"]) == "z" \
			else Vector3(length, 0.14, 0.12)
	var glow: StandardMaterial3D = _make_emissive(color, 1.4)
	var mesh: MeshInstance3D = _mesh_box(pos, housing_size, glow)
	mesh.material_override = glow

	var offset: Vector3 = spec.get("normal", Vector3.ZERO)
	if offset.length_squared() < 0.0001:
		offset = Vector3(-signf(pos.x) * 0.35, -0.1, 0.0)
		if String(spec["axis"]) == "x":
			offset = Vector3(0.0, -0.1, -signf(pos.z) * 0.35 if absf(pos.z) > 0.1 else 0.35)

	var light: OmniLight3D
	if flicker:
		light = FlickerLight.new()
		var flicker_light: FlickerLight = light as FlickerLight
		flicker_light.base_energy = energy
		flicker_light.emissive_mesh = mesh
	else:
		light = OmniLight3D.new()
		light.light_energy = energy

	light.name = "ConduitNode"
	light.position = pos + offset
	light.light_color = color
	light.omni_range = float(spec["range"])
	light.omni_attenuation = LIGHT_DECAY
	light.light_specular = 0.35
	light.light_volumetric_fog_energy = 1.0
	light.shadow_enabled = false  # nodes are fill light; the beam casts.
	_fixtures.add_child(light)


## Slow red scan sweep. DESIGN.md reserves red for hostile processes, so this is
## a room quietly telling you it is being watched.
func _build_scan_sweep(pos: Vector3) -> void:
	var sweep: Node3D = Node3D.new()
	sweep.name = "ScanSweep"
	sweep.set_script(load("res://src/world/scan_sweep.gd"))
	sweep.position = pos

	# Children first, tree last: ScanSweep resolves its SpotLight in @onready, and
	# adding the parent to the tree early would run _ready() against an empty node
	# and silently disable the pulse.
	var mount: MeshInstance3D = MeshInstance3D.new()
	var mount_mesh: BoxMesh = BoxMesh.new()
	mount_mesh.size = Vector3(0.7, 0.16, 0.7)
	mount.mesh = mount_mesh
	mount.material_override = MAT_CONDUIT
	sweep.add_child(mount)

	# A thin emitter bar rather than a beacon dome: this is an aperture, not a
	# warning light.
	var emitter: MeshInstance3D = MeshInstance3D.new()
	var emitter_mesh: BoxMesh = BoxMesh.new()
	emitter_mesh.size = Vector3(0.9, 0.05, 0.07)
	emitter.mesh = emitter_mesh
	emitter.position = Vector3(0.0, -0.12, 0.0)
	emitter.material_override = _make_emissive(Color(1.0, 0.14, 0.16), 1.6)
	sweep.add_child(emitter)

	var spot: SpotLight3D = SpotLight3D.new()
	spot.name = "Spot"
	spot.position = Vector3(0.0, -0.18, 0.0)
	spot.rotation = Vector3(deg_to_rad(-52.0), 0.0, 0.0)
	spot.light_color = Color(1.0, 0.16, 0.13)
	spot.light_energy = 17.0
	spot.light_specular = 0.2
	# Heavy fog contribution: the sweep is meant to read as a visible shaft
	# crossing the room, not just a moving patch on the floor.
	spot.light_volumetric_fog_energy = 5.5
	spot.spot_range = 26.0
	spot.spot_angle = 22.0
	spot.spot_angle_attenuation = 1.4
	spot.spot_attenuation = 0.6
	spot.shadow_enabled = true
	spot.shadow_bias = 0.05
	sweep.add_child(spot)

	_fixtures.add_child(sweep)


# ------------------------------------------------------------------ helpers --

## Emissive outline rectangle, used for injection-port apertures.
func _port_ring(center: Vector3, width: float, height: float) -> void:
	var bar: float = 0.08
	var hw: float = width * 0.5
	var hh: float = height * 0.5
	_mesh_box(center + Vector3(-hw, 0.0, 0.0), Vector3(bar, height, 0.06), _gate_material)
	_mesh_box(center + Vector3(hw, 0.0, 0.0), Vector3(bar, height, 0.06), _gate_material)
	_mesh_box(center + Vector3(0.0, hh, 0.0), Vector3(width, bar, 0.06), _gate_material)
	_mesh_box(center + Vector3(0.0, -hh, 0.0), Vector3(width, bar, 0.06), _gate_material)


func _data_block(pos: Vector3, size: Vector3, yaw: float) -> void:
	var mesh: MeshInstance3D = _mesh_box(pos + Vector3(0.0, size.y * 0.5, 0.0), size, MAT_BLOCK)
	mesh.rotation.y = yaw

	# A lit seam around each block: racked storage, not cargo.
	var seam: MeshInstance3D = _mesh_box(
			pos + Vector3(0.0, size.y * 0.78, 0.0),
			Vector3(size.x * 1.01, 0.025, size.z * 1.01), _trace_material)
	seam.rotation.y = yaw

	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = pos + Vector3(0.0, size.y * 0.5, 0.0)
	shape.rotation.y = yaw
	_colliders.add_child(shape)


## Data conduit: a dark tube with a lit seam running its length, so it reads as
## something carrying data rather than fluid.
func _conduit_run(from: Vector3, to: Vector3, radius: float) -> void:
	var delta: Vector3 = to - from
	var length: float = delta.length()
	if length < 0.01:
		return

	var mesh: MeshInstance3D = MeshInstance3D.new()
	var cylinder: CylinderMesh = CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = length
	cylinder.radial_segments = 10
	cylinder.rings = 0
	mesh.mesh = cylinder
	mesh.material_override = MAT_CONDUIT

	var up: Vector3 = delta / length
	var reference: Vector3 = Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var right: Vector3 = reference.cross(up).normalized()
	var forward: Vector3 = right.cross(up).normalized()
	mesh.transform = Transform3D(Basis(right, up, forward), (from + to) * 0.5)
	_geometry.add_child(mesh)

	var offset: Vector3 = Vector3.DOWN * (radius + 0.014)
	if absf(up.dot(Vector3.UP)) > 0.9:
		offset = Vector3.RIGHT * (radius + 0.014)
	_trace(from + offset, to + offset, _trace_material, 0.03)


## Holographic glyph panel — the "still holding a process open" motif. Returns
## the panel mesh so callers can name or animate it.
func _glyph_panel(base: Vector3, colour: Color, yaw: float = 0.0) -> MeshInstance3D:
	var plinth: MeshInstance3D = _mesh_box(base + Vector3(0.0, 0.4, 0.0),
			Vector3(2.6, 0.8, 0.9), MAT_CONDUIT)
	plinth.rotation.y = yaw
	var lip: MeshInstance3D = _mesh_box(base + Vector3(0.0, 0.82, 0.0),
			Vector3(2.2, 0.05, 0.7), _trace_material)
	lip.rotation.y = yaw

	# The panel reads as projected: an unshaded emissive plane floating clear of
	# its plinth, with glyph rows rather than a screen bezel.
	var facing: Vector3 = Vector3(sin(yaw), 0.0, cos(yaw))
	var panel: MeshInstance3D = _mesh_box(base + Vector3(0.0, 1.95, 0.0) + facing * 0.1,
			Vector3(2.0, 1.3, 0.03), _make_hologram(colour, 0.16))
	panel.rotation.y = yaw
	panel.name = "GlyphPanel"

	var glyph_material: StandardMaterial3D = _make_hologram(colour, 0.85)
	var rows: Array[float] = [0.86, 0.5, 0.74, 0.34, 0.62, 0.44]
	var side: Vector3 = Vector3(cos(yaw), 0.0, -sin(yaw))
	for row: int in rows.size():
		var width: float = rows[row]
		var along: Vector3 = side * (-0.72 + width * 0.5)
		var glyph: MeshInstance3D = _mesh_box(
				base + Vector3(0.0, 2.42 - float(row) * 0.18, 0.0) + along + facing * 0.09,
				Vector3(width, 0.05, 0.02), glyph_material)
		glyph.rotation.y = yaw

	var housing: MeshInstance3D = _mesh_box(base + Vector3(0.0, 0.92, 0.0) + facing * 0.1,
			Vector3(0.5, 0.1, 0.3), MAT_CONDUIT)
	housing.rotation.y = yaw

	var glow: OmniLight3D = OmniLight3D.new()
	glow.name = "GlyphGlow"
	glow.position = base + Vector3(0.0, 1.9, 0.0) + facing * 0.9
	glow.light_color = colour
	glow.light_energy = 2.2 * light_scale
	glow.omni_range = 9.0
	glow.omni_attenuation = 0.9
	glow.light_volumetric_fog_energy = 1.8
	glow.shadow_enabled = false
	_fixtures.add_child(glow)

	return panel


## Mesh + matching box collider.
func _box(center: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = _mesh_box(center, size, material)
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = center
	_colliders.add_child(shape)
	return mesh


## Mesh only — trim, traces and decoration the player never bumps into.
func _mesh_box(center: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = center
	mesh.material_override = material
	_geometry.add_child(mesh)
	return mesh


func _make_emissive(color: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color.darkened(0.55)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	material.metallic = 0.0
	material.roughness = 0.6
	material.disable_receive_shadows = true
	return material


## Unshaded, slightly transparent variant for holographic surfaces — a projection
## should not pick up shading from the room it floats in, and you should be able
## to see the wall faintly through it.
func _make_hologram(color: Color, alpha: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	material.disable_receive_shadows = true
	return material


# ------------------------------------------------------------------- spawns --

## Subclasses override. Identity keeps a builder usable before it has a layout.
func get_spawn_point(_index: int) -> Transform3D:
	return Transform3D.IDENTITY
