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

## M3.7: the surface set is now the look-dev kit's shader materials rather than
## flat StandardMaterial3Ds. INTEGRATION.md §3 gives the mapping — the important
## part is that the albedos did NOT go down. "Near-black" is a lighting result,
## not a black texture; the first look-dev round authored panels at 0.048, the
## walls returned nothing to the beam, and the whole layer read as neon lines
## floating in a void. 0.095 panel / 0.072 floor sits within a hair of the old
## monolith_wall and is correct.
##
## These are typed `Material` rather than `StandardMaterial3D` because they are
## ShaderMaterials now; everything downstream takes `Material` for the same
## reason. The one exception is `_make_emissive`, which still hands back a
## StandardMaterial3D — a one-off glowing box does not need the surface shader
## and FlickerLight mutates its emission_energy_multiplier directly.
const MAT_MONOLITH: Material = preload("res://assets/materials/mat_panel_dark.tres")
const MAT_FLOOR: Material = preload("res://assets/materials/mat_floor_plate.tres")
const MAT_CONDUIT: Material = preload("res://assets/materials/mat_conduit.tres")
const MAT_TRIM: Material = preload("res://assets/materials/mat_panel_trim.tres")
const MAT_GRATE: Material = preload("res://assets/materials/mat_grate.tres")
const MAT_BLOCK: Material = preload("res://assets/materials/mat_panel_dark.tres")

# --- the modular kit lattice (INTEGRATION.md §2) ---------------------------
## Kit cell pitch. Module origins sit on cell centres, i.e. on `CELL * k + 2`.
const CELL: float = 4.0
## One storey. The kit stacks, so a tall room is two courses of the same walls.
const STOREY: float = 4.0

## Wall variants, chosen per cell by hashing the world position. SPLIT_2M is a
## pseudo-variant that fills one 4 m slot with two 2 m service modules — mixing
## widths on the same lattice is what stops a corridor reading as one stamp
## repeated.
## One trace module in seven, not two in six as the showcase used. In a 12 m
## showcase corridor a third of the walls glowing reads as infrastructure; across
## a 24 m generated room it reads as a lit grid, which is the exact "neon lines
## on black" look the kit was built to kill.
const WALL_VARIANTS: Array = [
	"WALL_4x4_PANEL", "WALL_4x4_ARMOR", "WALL_4x4_PANEL",
	"WALL_4x4_TRACE", "WALL_4x4_ARMOR", "SPLIT_2M", "WALL_4x4_PANEL",
]

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


func _slab(lo: Vector2, hi: Vector2, y: float, material: Material) -> void:
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

## Hairline emissive inlay between two points.
##
## The axis-aligned case is a box sized on the one axis that varies. The DIAGONAL
## case needs a rotation, and getting that wrong is a bug this project shipped
## from M2 until M3.7: taking the per-axis maximum for a diagonal run produces a
## box spanning the segment's whole bounding rectangle, so a nest's radiating
## "growth" strands — the only diagonals in the game — were not hairlines at all
## but a floor-sized slab of dark red. Under M2's flat materials that read as a
## murky stain and nobody caught it; under the look-dev tonemap it became a
## saturated red plane covering half the room.
func _trace(from: Vector3, to: Vector3, material: Material,
		width: float = TRACE_WIDTH) -> void:
	var delta: Vector3 = to - from
	var axes: int = 0
	for component: float in [delta.x, delta.y, delta.z]:
		if absf(component) > width:
			axes += 1

	if axes <= 1:
		_mesh_box((from + to) * 0.5, Vector3(
				maxf(absf(delta.x), width),
				maxf(absf(delta.y), width),
				maxf(absf(delta.z), width)), material)
		return

	# Diagonal: a thin box the length of the run, turned to lie along it.
	var length: float = delta.length()
	var mesh: MeshInstance3D = _mesh_box((from + to) * 0.5,
			Vector3(width, width, length), material)
	mesh.look_at_from_position((from + to) * 0.5, to,
			Vector3.UP if absf(delta.normalized().dot(Vector3.UP)) < 0.99 else Vector3.RIGHT)


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
	# Was 17 with a fog contribution of 5.5 and a 26 m reach, tuned against M2's
	# flat CSG materials. Against the kit's floor plates that sweep raked through
	# a doorway and painted the whole of the NEXT room a flat saturated red — it
	# stopped reading as a beam crossing a room and became a colour filter over
	# the level. The blade is the point; it has to stay a shape.
	spot.light_energy = 7.5
	spot.light_specular = 0.2
	# Still a heavy fog contribution: the sweep should read as a visible shaft
	# crossing the room, not just a moving patch on the floor.
	spot.light_volumetric_fog_energy = 2.8
	spot.spot_range = 17.0
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


## A racked data block.
##
## M2 built this as one box with a bright emissive band round the top, which was
## fine beside CSG walls and stopped being fine the moment the walls became
## chamfered, roughness-varied kit modules — a flat cube with a glowing stripe
## next to those reads as an untextured primitive somebody forgot to finish.
##
## It is now assembled the way the kit modules are: a plinth it stands on, a
## recessed body, an inset top cap, ribs down the corners, and **one short
## emissive slot** rather than a band that wraps the whole object. The surface
## shader supplies the roughness breakup and the polished-edge response for free
## because the body is bound to the same `mat_panel_dark` the walls are; what it
## could not supply is silhouette, and silhouette is what this adds.
##
## Six meshes instead of two. A vault carries a dozen of these, so this is the
## most-instanced prop in the game and the budget was chosen with that in mind.
func _data_block(pos: Vector3, size: Vector3, yaw: float) -> void:
	var group: Node3D = Node3D.new()
	group.name = "DataBlock"
	group.position = pos
	group.rotation.y = yaw
	_geometry.add_child(group)

	var plinth: float = 0.06
	var cap: float = 0.05
	var body_height: float = maxf(size.y - plinth - cap, 0.1)

	# A plinth wider than the body. Every heavy object in the kit stands on
	# something; a box resting directly on the deck reads as dropped there.
	_group_box(group, Vector3(0.0, plinth * 0.5, 0.0),
			Vector3(size.x * 1.08, plinth, size.z * 1.08), MAT_CONDUIT)
	_group_box(group, Vector3(0.0, plinth + body_height * 0.5, 0.0),
			Vector3(size.x, body_height, size.z), MAT_MONOLITH)
	# Inset cap: the step is what catches a grazing beam.
	_group_box(group, Vector3(0.0, size.y - cap * 0.5, 0.0),
			Vector3(size.x * 0.84, cap, size.z * 0.84), MAT_CONDUIT)

	# Corner ribs on the two faces most likely to be seen, standing 15 mm proud.
	for side: float in [-1.0, 1.0]:
		_group_box(group, Vector3(side * (size.x * 0.5 + 0.008),
				plinth + body_height * 0.5, 0.0),
				Vector3(0.016, body_height * 0.92, size.z * 0.22), MAT_TRIM)

	# One short slot, low on the front. Recessed, dim, and nowhere near long
	# enough to wrap the object — a status light, not a strip light.
	_group_box(group, Vector3(0.0, plinth + body_height * 0.34,
			-(size.z * 0.5 + 0.006)),
			Vector3(size.x * 0.42, 0.018, 0.012), _trace_material)

	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = pos + Vector3(0.0, size.y * 0.5, 0.0)
	shape.rotation.y = yaw
	_colliders.add_child(shape)


## A storage rack — the vault's hero prop and the bus hall's processing stack.
##
## Taller than a data block and built to be looked at: a ribbed column of
## horizontal shelves with **restrained light bleeding out of the gaps between
## them**, rather than a coloured box. The distinction matters: a green-painted
## cube says "programmer art", a dark ribbed rack with green leaking through its
## slits says "there is something running in there".
func _data_rack(pos: Vector3, size: Vector3, yaw: float, glow: Color,
		shelves: int = 5) -> void:
	var group: Node3D = Node3D.new()
	group.name = "DataRack"
	group.position = pos
	group.rotation.y = yaw
	_geometry.add_child(group)

	var plinth: float = 0.1
	var slit: StandardMaterial3D = _make_emissive(glow, 0.55)

	_group_box(group, Vector3(0.0, plinth * 0.5, 0.0),
			Vector3(size.x * 1.1, plinth, size.z * 1.12), MAT_CONDUIT)
	_group_box(group, Vector3(0.0, plinth + (size.y - plinth) * 0.5, 0.0),
			Vector3(size.x, size.y - plinth, size.z), MAT_MONOLITH)
	# Uprights standing proud of the shelves, so the rack has a frame.
	for side: float in [-1.0, 1.0]:
		_group_box(group, Vector3(side * (size.x * 0.5 - 0.03),
				plinth + (size.y - plinth) * 0.5, -(size.z * 0.5 + 0.02)),
				Vector3(0.1, size.y - plinth - 0.08, 0.05), MAT_TRIM)

	# Shelves, and the gaps between them. The slit sits BEHIND the shelf lip and
	# is 30 mm tall: from three metres you see a line of light, from ten you see
	# a rack that is faintly awake, and neither ever lights the floor.
	for i: int in shelves:
		var y: float = plinth + (size.y - plinth) * (float(i) + 0.62) / float(shelves)
		_group_box(group, Vector3(0.0, y, -(size.z * 0.5 + 0.024)),
				Vector3(size.x * 0.78, 0.05, 0.05), MAT_CONDUIT)
		_group_box(group, Vector3(0.0, y - 0.055, -(size.z * 0.5 + 0.012)),
				Vector3(size.x * 0.62, 0.03, 0.014), slit)
	_group_box(group, Vector3(0.0, size.y - 0.03, 0.0),
			Vector3(size.x * 0.86, 0.06, size.z * 0.86), MAT_CONDUIT)

	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = pos + Vector3(0.0, size.y * 0.5, 0.0)
	shape.rotation.y = yaw
	_colliders.add_child(shape)


## Mesh box parented to a prop group rather than straight into `_geometry`, so a
## multi-part prop can be positioned and rotated once.
func _group_box(group: Node3D, at: Vector3, size: Vector3,
		material: Material) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	group.add_child(mesh)
	return mesh


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
			Vector3(2.0, 1.3, 0.03), _make_hologram(colour, 0.10))
	panel.rotation.y = yaw
	panel.name = "GlyphPanel"

	# Dropped from 0.85 in M3.7. Additive glyph rows at that alpha next to the
	# kit's restrained emissives were the brightest thing in most rooms, and the
	# panel's fill light was painting every crate near it a flat poster green.
	var glyph_material: StandardMaterial3D = _make_hologram(colour, 0.45)
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
	glow.light_energy = 0.75 * light_scale
	glow.omni_range = 4.5
	glow.omni_attenuation = 1.5
	glow.light_volumetric_fog_energy = 1.1
	glow.shadow_enabled = false
	_fixtures.add_child(glow)

	return panel


## Mesh + matching box collider.
func _box(center: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
	var mesh: MeshInstance3D = _mesh_box(center, size, material)
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = center
	_colliders.add_child(shape)
	return mesh


## Mesh only — trim, traces and decoration the player never bumps into.
func _mesh_box(center: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
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


# =========================================================== the modular kit ==
#
# M3.7. Everything above this line is the M1/M2 CSG-box vocabulary and is still
# what the hand-authored test layer is built from. Everything below stamps the
# look-dev kit's 13 modules onto a 4 m lattice instead, and is what the
# procedural generator now uses. The two coexist deliberately: `--testlayer`
# stays on the old geometry, so a regression there can never be blamed on the
# kit merge.
#
# ## The grid contract (INTEGRATION.md §2)
#
# Cell = 4 m with centres on `4k + 2`. Storey = 4 m and stacks. Wall thickness is
# 0.4 m — identical to WALL_THICKNESS — and walls still sit ON the boundary with
# their detailed face pointing inward, so "a room and its corridor share one
# wall" survives unchanged and there is still no coplanar z-fighting.
#
# ## Why the snapping happens HERE and not in LayerGraph
#
# The kit needs rectangles that are multiples of 4. LayerGraph does not emit
# those; it emits jittered rects. The obvious fix is to snap in the generator —
# and it is the wrong one, because every room rect, door position and furniture
# point is in the `--dumplayer` determinism dump, and changing them would mean
# every saved seed generates a different layer than it did before M3.7.
#
# So the snap is a *rendering* decision, applied here, and the graph is byte for
# byte what it always was. Rooms grow outward to the next cell boundary (never
# inward, so nothing that used to be inside a room ends up in a wall), doors move
# to the nearest slot centre, and the colliders follow the snapped shell rather
# than the graph rect. Gameplay positions — spawns, taps, the shaft, shards,
# nests, posts — are untouched, and the worst case is a shard sitting a metre
# further from a wall than it used to.
#
# The arithmetic that makes this safe: adjacent cells are CELL_PITCH 34 m apart
# and a room's half-extent is at most MAX_HALF + JITTER = 10.5 m, so two adjacent
# rooms' faces are at least 13 m apart before snapping. Snapping moves each face
# by less than 4 m, and the result is a multiple of 4, so the gap is always at
# least 8 m of corridor. Rooms can never be snapped into each other.

## Round a low edge down and a high edge up onto the lattice: a snapped room is
## never smaller than the room the generator asked for.
static func snap_lo(v: float) -> float:
	return floorf(v / CELL) * CELL


static func snap_hi(v: float) -> float:
	return ceilf(v / CELL) * CELL


## Nearest module slot centre (`4k + 2`). Doorways land on one of these, and
## because the function is global rather than relative to a room's own origin,
## the room side and the corridor side of a doorway always agree.
static func snap_slot(v: float) -> float:
	return roundf((v - CELL * 0.5) / CELL) * CELL + CELL * 0.5


## The snapped footprint of a graph rect.
static func kit_rect(lo: Vector2, hi: Vector2) -> Rect2:
	var slo: Vector2 = Vector2(snap_lo(lo.x), snap_lo(lo.y))
	var shi: Vector2 = Vector2(snap_hi(hi.x), snap_hi(hi.y))
	return Rect2(slo, shi - slo)


## Storeys tall enough to contain `h`, at least one. Ceiling heights in the
## generator range 3.4-7 m and the sanctuary is 8.5, so this yields one or two
## courses of the same wall modules — which is exactly what the kit is for.
static func kit_storeys(h: float) -> int:
	return maxi(int(roundf(h / STOREY)), 1)


# --------------------------------------------------------------- placement --

func _kit_xform(pos: Vector3, yaw_deg: float) -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(yaw_deg), 0.0)), pos)


func _put(module: String, pos: Vector3, yaw_deg: float = 0.0) -> MeshInstance3D:
	return KitLib.spawn(_geometry, module, _kit_xform(pos, yaw_deg))


## Deterministic variant choice, seeded off the world position.
##
## Deliberately NOT `_rng`: hashing the cell is deterministic per position
## without consuming the shared run seed, so tuning the decoration can never
## desynchronise the generator, and four clients draw the same wall without
## replicating a byte. It is also stable across a descent-and-return.
static func _pick(x: float, z: float, salt: int, options: Array) -> String:
	var h: int = hash(Vector3i(int(roundf(x)), salt, int(roundf(z))))
	return String(options[absi(h) % options.size()])


## One 4 m wall slot. `yaw` faces the detailed side into the space.
##
## `dark` rooms (the nests) are forced onto blind panel variants. A nest with lit
## channels running round it is not an unlit room, and DESIGN.md needs the nest
## to be the darkest thing on the layer — it is the only place a Scrubber is
## comfortable, and that fact and the absence of light are the same fact.
func _wall_slot(center: Vector3, yaw: float, dark: bool = false) -> void:
	var options: Array = ["WALL_4x4_PANEL", "WALL_4x4_ARMOR", "WALL_2x4_CABLE"] if dark \
			else WALL_VARIANTS
	var variant: String = _pick(center.x, center.z, 11, options)
	if variant == "SPLIT_2M":
		# Two 2 m service modules filling one 4 m slot.
		var right: Vector3 = Vector3(cos(deg_to_rad(yaw)), 0.0, -sin(deg_to_rad(yaw)))
		var first: bool = absi(hash(center)) % 2 == 0
		_put("WALL_2x4_VENT" if first else "WALL_2x4_CABLE", center - right * 1.0, yaw)
		_put("WALL_2x4_CABLE" if first else "WALL_2x4_VENT", center + right * 1.0, yaw)
	elif variant == "WALL_2x4_CABLE" and dark:
		var side: Vector3 = Vector3(cos(deg_to_rad(yaw)), 0.0, -sin(deg_to_rad(yaw)))
		_put("WALL_2x4_CABLE", center - side * 1.0, yaw)
		_put("WALL_2x4_CABLE", center + side * 1.0, yaw)
	else:
		_put(variant, center, yaw)
		if variant == "WALL_4x4_TRACE" and not dark:
			_trace_glow(center, yaw)


## Every trace module carries its own light.
##
## This is the single fix that separated the look-dev kit from the screenshots it
## replaced: an emissive channel with no lit surface around it is a glowing
## rectangle floating in black. A real lit groove spills onto the panel it is cut
## into. SSIL gets part of the way there, but it is screen-space, so an inlay at
## the edge of frame stops bouncing exactly when you need it to.
##
## Stood 0.95 m off the wall with specular almost off. Sat close in it reads as a
## bare bulb hovering inside the trace rectangle, which is a worse artefact than
## the problem it solves; out here it is a wash with no source of its own and the
## emissive geometry stays the thing you look at.
func _trace_glow(center: Vector3, yaw: float) -> void:
	var normal: Vector3 = Vector3(sin(deg_to_rad(yaw)), 0.0, cos(deg_to_rad(yaw)))
	var light: OmniLight3D = OmniLight3D.new()
	light.name = "Practical_trace"
	light.position = center + Vector3(0.0, 1.90, 0.0) + normal * 0.95
	light.light_color = LightRig.TEAL
	light.light_energy = 1.5 * light_scale
	light.omni_range = 6.4
	light.omni_attenuation = 1.1
	light.light_specular = 0.04
	light.shadow_enabled = false
	light.light_volumetric_fog_energy = 0.35
	light.set_meta("authored_energy", light.light_energy)
	light.set_meta("authored_color", light.light_color)
	light.set_meta("base_energy", light.light_energy)
	_fixtures.add_child(light)


## A run of wall slots along one edge of a space, at one storey.
##   axis "x": wall lies in the XY plane at fixed z, slots march along X
##   axis "z": wall lies in the ZY plane at fixed x, slots march along Z
## `doors` holds already-snapped slot centres.
func _kit_wall_run(axis: String, fixed: float, from: float, to: float, y: float,
		yaw: float, doors: Array = [], dark: bool = false) -> void:
	var t: float = from + CELL * 0.5
	while t < to - 0.01:
		var pos: Vector3 = Vector3(t, y, fixed) if axis == "x" else Vector3(fixed, y, t)
		var is_door: bool = false
		for d: float in doors:
			if absf(t - d) < 0.01:
				is_door = true
		if is_door:
			_put("DOORFRAME_HERO", pos, yaw)
		else:
			_wall_slot(pos, yaw, dark)
		t += CELL


## Floor cells across a rectangle. `trace_axis` marks the spine that gets the
## inlaid trace plate: "x" runs the spine along X at the rect's middle row, "z"
## along Z at its middle column.
func _kit_floor_field(rect: Rect2, trace_axis: String = "") -> void:
	var mid: Vector2 = rect.position + rect.size * 0.5
	var x: float = rect.position.x + CELL * 0.5
	while x < rect.end.x - 0.01:
		var z: float = rect.position.y + CELL * 0.5
		while z < rect.end.y - 0.01:
			var on_spine: bool = (trace_axis == "z" and absf(x - snap_slot(mid.x)) < 0.01) \
					or (trace_axis == "x" and absf(z - snap_slot(mid.y)) < 0.01)
			if on_spine:
				_put("FLOOR_4x4_TRACE", Vector3(x, 0.0, z))
			else:
				_put("FLOOR_4x4_PLATE", Vector3(x, 0.0, z))
				# One grate every few cells: real holes with real darkness under
				# them, and the only place in the kit a beam shines through.
				if absi(hash(Vector2i(int(x), int(z)))) % 5 == 0:
					_put("FLOOR_2x2_GRATE", Vector3(x + 1.0, 0.0, z - 1.0))
			z += CELL
		x += CELL


func _kit_ceiling_field(rect: Rect2, y: float) -> void:
	var x: float = rect.position.x + CELL * 0.5
	while x < rect.end.x - 0.01:
		var z: float = rect.position.y + CELL * 0.5
		while z < rect.end.y - 0.01:
			# Random quarter-turns so the hanging ducts and cable drops never line
			# up into a corridor of identical silhouettes.
			var yaw: float = float(absi(hash(Vector2i(int(x) + 7, int(z)))) % 4) * 90.0
			_put("CEIL_4x4_MODULE", Vector3(x, y, z), yaw)
			z += CELL
		x += CELL


# --------------------------------------------------------------- collision --
#
# The kit meshes carry no collision at all, by design (INTEGRATION.md §2):
# generating trimesh collision from 1000-triangle chamfered panels would be a
# large physics cost for zero gameplay difference, and a bevel you can catch a
# foot on is worse than a flat wall. The generator keeps emitting flat box
# proxies on the boundary, exactly as it always did — they just now follow the
# snapped shell instead of the graph rect.

func _collider_box(center: Vector3, size: Vector3) -> void:
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = center
	_colliders.add_child(shape)


## Box proxies for one wall, pierced by the doorways and re-closed above them.
func _kit_wall_colliders(axis: String, fixed: float, from: float, to: float,
		height: float, doors: Array) -> void:
	var openings: Array = []
	for at: float in doors:
		openings.append({"at": at, "w": DOOR_WIDTH})

	for span: Vector2 in _solid_spans(from, to, openings):
		var mid: float = (span.x + span.y) * 0.5
		var length: float = span.y - span.x
		if length < 0.02:
			continue
		if axis == "x":
			_collider_box(Vector3(mid, height * 0.5, fixed),
					Vector3(length, height, WALL_THICKNESS))
		else:
			_collider_box(Vector3(fixed, height * 0.5, mid),
					Vector3(WALL_THICKNESS, height, length))

	# The lintel. Without it a doorway is a hole all the way to the ceiling and a
	# player can rocket-jump a Scrubber over the wall.
	for at: float in doors:
		if height <= DOOR_HEIGHT + 0.02:
			continue
		var lintel: float = height - DOOR_HEIGHT
		if axis == "x":
			_collider_box(Vector3(at, DOOR_HEIGHT + lintel * 0.5, fixed),
					Vector3(DOOR_WIDTH, lintel, WALL_THICKNESS))
		else:
			_collider_box(Vector3(fixed, DOOR_HEIGHT + lintel * 0.5, at),
					Vector3(WALL_THICKNESS, lintel, DOOR_WIDTH))


# ------------------------------------------------------------------ shells --

## A room, built from kit modules. Returns the snapped footprint so the caller
## can dress inside the shell it actually got rather than the one it asked for.
func kit_room(room: Dictionary) -> Rect2:
	var rect: Rect2 = kit_rect(room["min"], room["max"])
	var storeys: int = kit_storeys(float(room["h"]))
	var height: float = float(storeys) * STOREY
	var dark: bool = bool(room.get("unlit", false))
	var doors: Array = room.get("doors", []) as Array

	var north: Array = _kit_doors(doors, "n")
	var south: Array = _kit_doors(doors, "s")
	var west: Array = _kit_doors(doors, "w")
	var east: Array = _kit_doors(doors, "e")

	_kit_floor_field(rect, "z")
	_kit_ceiling_field(rect, height)

	for level: int in storeys:
		var y: float = float(level) * STOREY
		# Doors only exist on the ground course; the upper course is plain wall.
		# Detail above 4 m never gets close enough to read, which is also why the
		# variant table up there does not matter.
		var d_n: Array = north if level == 0 else []
		var d_s: Array = south if level == 0 else []
		var d_w: Array = west if level == 0 else []
		var d_e: Array = east if level == 0 else []
		# Yaw faces the detailed side inward: the north wall (-Z boundary) has the
		# room on its +Z side, and the module's detailed face is +Z at yaw 0.
		_kit_wall_run("x", rect.position.y, rect.position.x, rect.end.x, y, 0.0, d_n, dark)
		_kit_wall_run("x", rect.end.y, rect.position.x, rect.end.x, y, 180.0, d_s, dark)
		_kit_wall_run("z", rect.position.x, rect.position.y, rect.end.y, y, 90.0, d_w, dark)
		_kit_wall_run("z", rect.end.x, rect.position.y, rect.end.y, y, -90.0, d_e, dark)

	_kit_wall_colliders("x", rect.position.y, rect.position.x, rect.end.x, height, north)
	_kit_wall_colliders("x", rect.end.y, rect.position.x, rect.end.x, height, south)
	_kit_wall_colliders("z", rect.position.x, rect.position.y, rect.end.y, height, west)
	_kit_wall_colliders("z", rect.end.x, rect.position.y, rect.end.y, height, east)
	_kit_shell_colliders(rect, height)

	# Rib columns just inside the corners, so a beam sweeping the room breaks on
	# something with depth instead of running flat along a wall.
	for corner: Vector2 in [rect.position + Vector2(2.0, 2.0),
			Vector2(rect.end.x - 2.0, rect.position.y + 2.0),
			Vector2(rect.position.x + 2.0, rect.end.y - 2.0),
			rect.end - Vector2(2.0, 2.0)]:
		_put("RIB_COLUMN", Vector3(corner.x, 0.0, corner.y), 0.0)
		if storeys > 1:
			_put("RIB_COLUMN", Vector3(corner.x, STOREY, corner.y), 0.0)
	return rect


## Floor and ceiling proxies. One box each rather than one per cell: a hundred
## coplanar box shapes is a hundred broadphase pairs for a surface the player
## walks in a straight line across.
func _kit_shell_colliders(rect: Rect2, height: float) -> void:
	var mid: Vector2 = rect.position + rect.size * 0.5
	_collider_box(Vector3(mid.x, -SLAB_THICKNESS * 0.5, mid.y),
			Vector3(rect.size.x + WALL_THICKNESS, SLAB_THICKNESS,
					rect.size.y + WALL_THICKNESS))
	_collider_box(Vector3(mid.x, height + SLAB_THICKNESS * 0.5, mid.y),
			Vector3(rect.size.x + WALL_THICKNESS, SLAB_THICKNESS,
					rect.size.y + WALL_THICKNESS))


## A corridor, built from kit modules. One cell wide and one storey tall, running
## between the two rooms' snapped faces — so it always spans a whole number of
## cells and its walls land on the same lattice the rooms do.
func kit_corridor(corridor: Dictionary) -> void:
	var rect: Rect2 = kit_corridor_rect(corridor)
	if rect.size.x < CELL - 0.01 or rect.size.y < CELL - 0.01:
		return

	_kit_floor_field(rect, "x" if String(corridor["axis"]) == "x" else "z")
	_kit_ceiling_field(rect, STOREY)

	if String(corridor["axis"]) == "z":
		_kit_wall_run("z", rect.position.x, rect.position.y, rect.end.y, 0.0, 90.0)
		_kit_wall_run("z", rect.end.x, rect.position.y, rect.end.y, 0.0, -90.0)
		_kit_wall_colliders("z", rect.position.x, rect.position.y, rect.end.y, STOREY, [])
		_kit_wall_colliders("z", rect.end.x, rect.position.y, rect.end.y, STOREY, [])
		var z: float = rect.position.y + CELL
		while z < rect.end.y - 0.01:
			# Ribs hard against alternating walls: the beam breaks on them as the
			# player walks and the corridor gets a pulse instead of a length.
			var side: float = rect.end.x - 0.38 if int(z) % 8 == 0 else rect.position.x + 0.38
			var yaw: float = -90.0 if int(z) % 8 == 0 else 90.0
			_put("RIB_COLUMN", Vector3(side, 0.0, z), yaw)
			_put("PIPE_RUN_4M", Vector3(rect.position.x + 2.0, STOREY, z - 2.0), 90.0)
			z += CELL
	else:
		_kit_wall_run("x", rect.position.y, rect.position.x, rect.end.x, 0.0, 0.0)
		_kit_wall_run("x", rect.end.y, rect.position.x, rect.end.x, 0.0, 180.0)
		_kit_wall_colliders("x", rect.position.y, rect.position.x, rect.end.x, STOREY, [])
		_kit_wall_colliders("x", rect.end.y, rect.position.x, rect.end.x, STOREY, [])
		var x: float = rect.position.x + CELL
		while x < rect.end.x - 0.01:
			var side_z: float = rect.end.y - 0.38 if int(x) % 8 == 0 else rect.position.y + 0.38
			var yaw_z: float = 180.0 if int(x) % 8 == 0 else 0.0
			_put("RIB_COLUMN", Vector3(x, 0.0, side_z), yaw_z)
			_put("PIPE_RUN_4M", Vector3(x - 2.0, STOREY, rect.position.y + 2.0), 0.0)
			x += CELL
	_kit_shell_colliders(rect, STOREY)


## The snapped corridor footprint.
##
## The short axis is the single cell containing the snapped doorway centreline —
## the same `snap_slot` the room's doorframe used, which is what makes the two
## meet. The long axis runs between the two rooms' *snapped* faces, so the ends
## are snapped the opposite way round from a room: a corridor starts where the
## room it leaves grew OUT to, and stops where the room it enters grew out to.
## Snapping the corridor's own min down would bury its first cell inside a wall.
##
## Adjacent room faces are at least 13 m apart, each moves by less than 4 m, and
## the result is a multiple of 4 — so a corridor is never shorter than two cells.
static func kit_corridor_rect(corridor: Dictionary) -> Rect2:
	var lo: Vector2 = corridor["min"]
	var hi: Vector2 = corridor["max"]
	if String(corridor["axis"]) == "z":
		var cx: float = snap_slot((lo.x + hi.x) * 0.5)
		var z0: float = snap_hi(lo.y)
		var z1: float = snap_lo(hi.y)
		return Rect2(Vector2(cx - CELL * 0.5, z0), Vector2(CELL, maxf(z1 - z0, 0.0)))
	var cz: float = snap_slot((lo.y + hi.y) * 0.5)
	var x0: float = snap_hi(lo.x)
	var x1: float = snap_lo(hi.x)
	return Rect2(Vector2(x0, cz - CELL * 0.5), Vector2(maxf(x1 - x0, 0.0), CELL))


## Snapped doorway centres on one wall of a room.
static func _kit_doors(doors: Array, wall: String) -> Array:
	var result: Array = []
	for door: Dictionary in doors:
		if String(door.get("wall", "")) == wall:
			result.append(snap_slot(float(door.get("at", 0.0))))
	return result


# ------------------------------------------------------------------- spawns --

## Subclasses override. Identity keeps a builder usable before it has a layout.
func get_spawn_point(_index: int) -> Transform3D:
	return Transform3D.IDENTITY
