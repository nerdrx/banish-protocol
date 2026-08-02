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
## M4.95: ceiling cells to OMIT from the ceiling field, so a god-ray aperture has
## a real hole to shine through — "a shaft is a hole with a light behind it", and
## the generator must know about the shaft before it stamps the ceiling
## (INTEGRATION2 §4). Keyed by room index -> aperture cell centre (Vector2 in XZ).
## ProcLayerBuilder fills this in `_plan_shafts` before the shells are built.
var ceiling_apertures: Dictionary = {}
## M6.6: floor cells to EXCAVATE, keyed by room index -> Array[Rect2] in world XZ.
## A sunken deck is a hole, and a hole has to be missing from the floor field and
## from the slab collider both — same contract as the ceiling apertures above, and
## filled from the same place (ProcLayerBuilder, before the shells go up).
var floor_cuts: Dictionary = {}
var _gate_material: StandardMaterial3D
var _trace_material: StandardMaterial3D
var _grid_material: StandardMaterial3D

## Scales every fixture energy this builder emits. The procedural builder drives
## it from LayerParams so deeper layers are darker without every call site
## needing to know about the threat curve.
var light_scale: float = 1.0

# --- architecture decay (M4.7) ----------------------------------------------
#
# DESIGN.md's aesthetic gradient, applied to the building itself rather than only
# to its signage: "Deeper = older = corrupted: z-fighting shimmer zones,
# dead-pixel clusters, geometry that repeats wrong."
#
# M3.7 deferred this because the 110 generated decals were already carrying the
# whole depth gradient on their own, and adding a second decay axis on top of an
# untested one would have made both impossible to judge. With the decals now
# reading as printed signage under a working wall wash (see LightRig._aim), the
# signage says *what the layer is* and the architecture has to say *how old it
# is* — those are different jobs and the kit was always meant to do the second.
#
# **Determinism.** Every decision below is a pure hash of (world position, layer
# seed), exactly like DecalLib's — never `_rng`. That is a hard requirement, not
# a preference: the dressing RNG is a shared stream, and a corruption pass that
# consumed it would shift every crate, tap and Sentinel post on the layer the
# moment somebody retuned the decay curve. It also means four clients agree on
# which panel is broken without a byte on the wire, and the `--dumplayer` graph
# is untouched.
#
## Layer the architecture starts coming apart at. Everything above this is
## public-facing infrastructure and is maintained; the rot is a deep-ring fact.
const DECAY_START_LAYER: int = 8
## Layer the decay curve tops out at, and the fraction of wall slots corrupted
## there. A third is a lot — but it is a third split four ways across four very
## different faults, so no single one of them ever becomes the layer's texture.
const DECAY_FULL_LAYER: int = 18
const DECAY_MAX: float = 0.34

## Which layer this builder is standing up, and its seed. Set by the procedural
## builder; the hand-authored test layer leaves them at the surface values and
## therefore never decays, which is correct — it is a greybox, not a ring.
var layer_number: int = 1
var layer_seed: int = 0
## Faults actually placed, by kind. Printed in the layer census — "the deep
## layers decay" is a claim, and a claim about generation should be a number in a
## log rather than an impression from a screenshot.
var decay_census: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0])


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

# --------------------------------------------------------- wall relief (M4.8) --
#
# How far each wall module stands PROUD of the boundary it is placed on, in
# metres, measured off the kit .glb (scratchpad m48/probe_kit.py reports each
# module's bounds; the module's detailed face is its local +Z in Godot).
#
# M3.7's walls stopped being flat planes and became modules with real depth —
# raised armour plates, cable trays, recessed panels. Anything mounted at the
# old boundary plane therefore buries itself in whatever relief the slot behind
# it happens to have drawn, which is exactly what M4.8's first vents did.
#
# Two things use this: `wall_relief_at` tells a caller how far out the surface
# actually is at a given point, and `flattest_wall_slot` finds the nearest slot
# whose module is shallow enough to hang something on in the first place.
const WALL_RELIEF: Dictionary = {
	"WALL_4x4_PANEL": 0.355,
	"WALL_4x4_ARMOR": 0.465,
	"WALL_4x4_TRACE": 0.200,
	"WALL_2x4_CABLE": 0.200,
	"WALL_2x4_VENT": 0.220,
	"DOORFRAME_HERO": 0.370,
}
## Relief a wall prop is happy to be mounted on. Above this the module's own
## geometry is deep enough that a flush prop would stand visibly off the wall,
## so `flattest_wall_slot` goes looking for a neighbour instead.
const WALL_RELIEF_OK: float = 0.24
## Clearance left between a prop's back and the module face it hangs on.
const WALL_PROP_CLEAR: float = 0.015


## Which module the variant table puts at a given slot centre. Exactly the choice
## `_wall_slot` makes, factored out so a prop can ask the same question.
static func wall_variant_at(centre: Vector3, dark: bool) -> String:
	var options: Array = ["WALL_4x4_PANEL", "WALL_4x4_ARMOR", "WALL_2x4_CABLE"] if dark \
			else WALL_VARIANTS
	var variant: String = _pick(centre.x, centre.z, 11, options)
	if variant == "SPLIT_2M":
		# Two 2 m service modules; take the deeper of the pair.
		return "WALL_2x4_VENT"
	return variant


## How far the wall stands proud of its boundary at this slot centre.
static func wall_relief_at(centre: Vector3, dark: bool) -> float:
	return float(WALL_RELIEF.get(wall_variant_at(centre, dark), 0.36))


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
	# One roll per slot, taken before anything is placed so the fault a slot draws
	# never depends on which module the variant table happened to hand it.
	var fault: int = _decay_fault(center)
	if variant == "SPLIT_2M":
		# Two 2 m service modules filling one 4 m slot.
		var right: Vector3 = Vector3(cos(deg_to_rad(yaw)), 0.0, -sin(deg_to_rad(yaw)))
		var first: bool = absi(hash(center)) % 2 == 0
		_corrupt_module(_put("WALL_2x4_VENT" if first else "WALL_2x4_CABLE",
				center - right * 1.0, yaw), center, yaw, fault)
		_put("WALL_2x4_CABLE" if first else "WALL_2x4_VENT", center + right * 1.0, yaw)
	elif variant == "WALL_2x4_CABLE" and dark:
		var side: Vector3 = Vector3(cos(deg_to_rad(yaw)), 0.0, -sin(deg_to_rad(yaw)))
		_corrupt_module(_put("WALL_2x4_CABLE", center - side * 1.0, yaw),
				center, yaw, fault)
		_put("WALL_2x4_CABLE", center + side * 1.0, yaw)
	else:
		_corrupt_module(_put(variant, center, yaw), center, yaw, fault)
		# A dead segment does not get a practical. That is the point of it: the
		# channel is out, so the wash it used to throw onto the panel is out too,
		# and the module goes properly dark rather than dark-but-lit.
		if variant == "WALL_4x4_TRACE" and not dark and fault != FAULT_DEAD_TRACE:
			_trace_glow(center, yaw, fault == FAULT_FLICKER_TRACE)


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
func _trace_glow(center: Vector3, yaw: float, failing: bool = false) -> void:
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
	if failing:
		# ARC rather than DYING: a trace channel is a data path, and what a failing
		# one should look like is a bad connection sparking, not a fluorescent tube
		# giving up. Phase-offset from the slot's own position so no two failing
		# segments on a wall ever stutter together.
		LightRig.flicker(light, FlickerLight.Mode.ARC,
				fposmod(center.x * 0.37 + center.z * 0.71, 6.0))


# ------------------------------------------------------------ decay (M4.7) --

## Which fault, if any, this wall slot draws. See the DECAY_* constants.
##
## Two hashes: one decides *whether* the slot is corrupted at all, the second
## decides which of the four faults it gets. Separate on purpose — sharing one
## hash between the two questions makes the fault correlate with the roll, so
## every barely-corrupted slot would draw the same fault and the rarest one would
## never appear at all.
const FAULT_NONE: int = 0
const FAULT_DISPLACED: int = 1
const FAULT_SHIMMER: int = 2
const FAULT_DEAD_TRACE: int = 3
const FAULT_FLICKER_TRACE: int = 4


## 0 above DECAY_START_LAYER, ramping to DECAY_MAX at DECAY_FULL_LAYER.
static func decay_chance(layer: int) -> float:
	if layer < DECAY_START_LAYER:
		return 0.0
	var t: float = clampf(float(layer - DECAY_START_LAYER)
			/ float(maxi(DECAY_FULL_LAYER - DECAY_START_LAYER, 1)), 0.0, 1.0)
	# Starts at a fraction rather than at zero. A curve that begins at exactly
	# nothing means layer 8 — the layer the rot is supposed to *start* on — is
	# byte-for-byte as clean as layer 1, and the gradient only becomes visible
	# three rings later. One bad panel per room is the right way to open.
	return DECAY_MAX * lerpf(0.18, 1.0, t)


func _decay_fault(center: Vector3) -> int:
	var chance: float = decay_chance(layer_number)
	if chance <= 0.0:
		return FAULT_NONE
	if DecalLib.roll(center.x, center.z, 6101, layer_seed) > chance:
		return FAULT_NONE
	return FAULT_DISPLACED + int(
			DecalLib.roll(center.x, center.z, 6217, layer_seed) * 4.0) % 4


## Applies one fault to one placed module.
##
## Every branch is deliberately *small*. The failure mode this pass has to avoid
## is a deep layer that reads as broken rather than as old — a wall with a
## visibly wrong panel in it is unsettling, a wall made of visibly wrong panels
## is a bug report. Nothing here moves geometry far enough to open a hole, and
## the colliders are untouched in every case, so a decayed wall is still a wall.
func _corrupt_module(module: MeshInstance3D, center: Vector3, yaw: float,
		fault: int) -> void:
	if module == null or fault == FAULT_NONE:
		return
	decay_census[fault] += 1
	var normal: Vector3 = Vector3(sin(deg_to_rad(yaw)), 0.0, cos(deg_to_rad(yaw)))
	var jitter: float = DecalLib.roll(center.x, center.z, 6329, layer_seed)

	match fault:
		FAULT_DISPLACED:
			# The panel has come off its mounts. Pushed a few centimetres out of
			# true and rolled a degree or two, which the grazing wall wash catches
			# as a hard shadow line the neighbouring panels do not have. Well
			# inside the 0.4 m wall thickness, so nothing pokes into the corridor
			# behind it.
			module.position += normal * lerpf(-0.055, 0.045, jitter)
			module.rotation.z += lerpf(-0.035, 0.035, jitter)
			module.rotation.y += lerpf(-0.018, 0.018,
					DecalLib.roll(center.x, center.z, 6421, layer_seed))
		FAULT_SHIMMER:
			_shimmer_patch(center, yaw, jitter)
		FAULT_DEAD_TRACE, FAULT_FLICKER_TRACE:
			# The channel itself. `decay` is an instance uniform on nv_dataflow, so
			# this costs bytes in the instance record rather than a material
			# override — a corrupted module still batches with every clean one.
			module.set_instance_shader_parameter("decay",
					1.0 if fault == FAULT_DEAD_TRACE else 0.72)
			module.set_instance_shader_parameter("decay_phase", jitter * 17.0)


## DESIGN.md's "z-fighting shimmer zones", built on purpose for once.
##
## A thin plate laid exactly coplanar with the module's detailed face, in the same
## material. The depth buffer cannot separate them, so the patch flickers between
## the two surfaces as the camera moves — the precise artefact that says "this
## geometry was written by something that has been running too long without a
## defragment". It is decoration with no collider and no light, and it is the
## cheapest thing in this whole milestone: one shared BoxMesh per patch.
func _shimmer_patch(center: Vector3, yaw: float, jitter: float) -> void:
	var patch: MeshInstance3D = MeshInstance3D.new()
	patch.name = "DecayShimmer"
	var plate: BoxMesh = BoxMesh.new()
	plate.size = Vector3(lerpf(1.1, 2.6, jitter), lerpf(0.9, 2.2, jitter), 0.004)
	patch.mesh = plate
	patch.material_override = MAT_MONOLITH
	# Exactly on the face. Not 1 mm proud — the fight IS the effect, and offsetting
	# it to "fix" the artefact removes the entire point of the patch.
	patch.position = center + Vector3(sin(deg_to_rad(yaw)), 0.0, cos(deg_to_rad(yaw))) \
			* (WALL_THICKNESS * 0.5) + Vector3(0.0, lerpf(1.0, 2.9, jitter), 0.0)
	patch.rotation.y = deg_to_rad(yaw)
	patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	patch.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_geometry.add_child(patch)


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
func _kit_floor_field(rect: Rect2, trace_axis: String = "", cuts: Array = []) -> void:
	var mid: Vector2 = rect.position + rect.size * 0.5
	var x: float = rect.position.x + CELL * 0.5
	while x < rect.end.x - 0.01:
		var z: float = rect.position.y + CELL * 0.5
		while z < rect.end.y - 0.01:
			# M6.6: an excavated cell gets no plate — the sunken deck below is the
			# floor there, and a plate over it would be a lid on the pit.
			if _cell_cut(x, z, cuts):
				z += CELL
				continue
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


func _kit_ceiling_field(rect: Rect2, y: float, skip: Vector2 = Vector2(INF, INF)) -> void:
	var has_skip: bool = is_finite(skip.x)
	var x: float = rect.position.x + CELL * 0.5
	while x < rect.end.x - 0.01:
		var z: float = rect.position.y + CELL * 0.5
		while z < rect.end.y - 0.01:
			# M4.95: the god-ray aperture cell gets no module — the hole IS the
			# shaft. GodRays.hero_shaft fills it with a slotted aperture plate.
			if has_skip and absf(x - skip.x) < CELL * 0.5 and absf(z - skip.y) < CELL * 0.5:
				z += CELL
				continue
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

	var cuts: Array = floor_cuts.get(int(room["index"]), []) as Array
	_kit_floor_field(rect, "z", cuts)
	_kit_ceiling_field(rect, height,
			ceiling_apertures.get(int(room["index"]), Vector2(INF, INF)))

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
	_kit_shell_colliders(rect, height, cuts)

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
##
## M6.6: a room with a sunken deck in it has a genuine hole in its floor, so the
## slab is emitted as up to four spans around the excavation instead of one box.
## Four boxes for a room with a pit, one for every other room on the layer.
func _kit_shell_colliders(rect: Rect2, height: float, cuts: Array = []) -> void:
	var mid: Vector2 = rect.position + rect.size * 0.5
	var grown: Rect2 = Rect2(rect.position - Vector2.ONE * WALL_THICKNESS * 0.5,
			rect.size + Vector2.ONE * WALL_THICKNESS)
	for span: Rect2 in _floor_spans(grown, cuts):
		var centre: Vector2 = span.position + span.size * 0.5
		_collider_box(Vector3(centre.x, -SLAB_THICKNESS * 0.5, centre.y),
				Vector3(span.size.x, SLAB_THICKNESS, span.size.y))
	_collider_box(Vector3(mid.x, height + SLAB_THICKNESS * 0.5, mid.y),
			Vector3(rect.size.x + WALL_THICKNESS, SLAB_THICKNESS,
					rect.size.y + WALL_THICKNESS))


## `outer` minus the cut rectangles, as axis-aligned spans. The cuts are always
## wall bands (see LayerGraph's verticality section), so a guillotine split on
## one axis then the other is exact rather than approximate.
static func _floor_spans(outer: Rect2, cuts: Array) -> Array[Rect2]:
	var spans: Array[Rect2] = [outer]
	for cut_any: Variant in cuts:
		var cut: Rect2 = cut_any
		var next: Array[Rect2] = []
		for span: Rect2 in spans:
			if not span.intersects(cut):
				next.append(span)
				continue
			var hit: Rect2 = span.intersection(cut)
			if hit.position.y - span.position.y > 0.01:
				next.append(Rect2(span.position,
						Vector2(span.size.x, hit.position.y - span.position.y)))
			if span.end.y - hit.end.y > 0.01:
				next.append(Rect2(Vector2(span.position.x, hit.end.y),
						Vector2(span.size.x, span.end.y - hit.end.y)))
			if hit.position.x - span.position.x > 0.01:
				next.append(Rect2(Vector2(span.position.x, hit.position.y),
						Vector2(hit.position.x - span.position.x, hit.size.y)))
			if span.end.x - hit.end.x > 0.01:
				next.append(Rect2(Vector2(hit.end.x, hit.position.y),
						Vector2(span.end.x - hit.end.x, hit.size.y)))
		spans = next
	return spans


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


# -------------------------------------------------- M6.6 vertical primitives --
#
# Decks, the routes between them and the structure that holds them up. Everything
# in here is driven by LayerGraph's `decks` / `deck_links` / `deck_drops`, which
# means the shapes are already in the determinism dump before a single node is
# built — this file only turns a rectangle and a height into standing metal.
#
# Two rules govern the collision, and both of them are about the AI as much as
# the player:
#
#   **Slopes are single boxes.** A stair is a smooth inclined box collider with
#   decorative treads on top, never a staircase of steps. Godot's CharacterBody3D
#   walks a 27 degree slope without a thought; a flight of 0.33 m steps makes the
#   antivirus's `move_and_slide` snag on every nosing and turns a route into a
#   wedge trap. The treads are what you see; the ramp is what you walk.
#
#   **Elevated decks are grating.** Catwalks, galleries and gantries are laid with
#   the kit's FLOOR_2x2_GRATE — the one module with real holes in it. That is the
#   structural half of the upcoming lighting pass: a gobo light above a grated
#   mezzanine stripes the floor below it for free, and a beam swept up from
#   underneath breaks into slats.

## Deck slab thickness, and how far a railing stands from the open edge.
const DECK_THICKNESS: float = 0.36
const RAIL_INSET: float = 0.16
const RAIL_HEIGHT: float = 1.06
## Target riser. 4 m over twelve treads is 0.333 — steep enough to be compact,
## shallow enough to read as a stair rather than as a ladder.
const TREAD_RISE: float = 0.34
## Height at which a deck earns a railing at all. A 0.8 m dais does not get one,
## and should not: you step up onto it.
const RAIL_MIN_HEIGHT: float = 2.0
## How wide a gap a drop-down ledge opens in a railing.
const DROP_GAP: float = 3.0


static func _cell_cut(x: float, z: float, cuts: Array) -> bool:
	for cut_any: Variant in cuts:
		var cut: Rect2 = cut_any
		if cut.grow(-0.05).has_point(Vector2(x, z)):
			return true
	return false


## A decorative box that does NOT cast shadows or contribute to GI.
##
## M6.6 measurement: the verticality pass adds ~100 small boxes per layer
## (railings, joists, stringers, treads, fascias) and a matched before/after
## capture on the densest layer showed 277 -> 203 fps average, most of it spent
## re-rasterising thin metal into nineteen shadow maps. A railing post's shadow is
## worth almost nothing at the distances these are seen from, and the DECK SLAB —
## the thing that actually casts a readable shadow, and the surface the coming
## gobo pass will stripe light across — keeps its shadow. Same call the clutter
## and trim passes already make, for the same reason.
func _detail_box(center: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
	var mesh: MeshInstance3D = _mesh_box(center, size, material)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mesh


## A box collider with an arbitrary orientation — the one shape `_collider_box`
## cannot express, and the whole reason a ramp is walkable.
func _collider_oriented(centre: Vector3, size: Vector3, basis: Basis) -> void:
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.transform = Transform3D(basis, centre)
	_colliders.add_child(shape)


## Orthonormal basis whose local +X runs along `forward` and whose local +Y is the
## surface normal. Used for every sloped plate on the layer.
static func _slope_basis(forward: Vector3) -> Basis:
	var along: Vector3 = forward.normalized()
	var side: Vector3 = along.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	side = side.normalized()
	return Basis(along, side.cross(along).normalized(), side)


## One walkable deck: grating or plate on top, a slab under it, an edge fascia,
## columns where it is standing in mid-air, and a railing anywhere you could walk
## off it that is not a marked ledge.
##
## `open` is the set of edges (0=north/-Z, 1=east/+X, 2=south/+Z, 3=west/-X) that
## face the room rather than a wall; `gaps` are world-XZ points where a drop-down
## ledge opens the railing.
func deck_platform(rect: Rect2, y: float, grated: bool, open: Array,
		gaps: Array = [], columns: bool = true) -> void:
	var mid: Vector2 = rect.position + rect.size * 0.5

	# Walking surface. Kit modules on the lattice, so a deck is made of the same
	# floor the room is and reads as part of the building.
	var x: float = rect.position.x + CELL * 0.5
	while x < rect.end.x - 0.01:
		var z: float = rect.position.y + CELL * 0.5
		while z < rect.end.y - 0.01:
			if grated:
				for corner: Vector2 in [Vector2(-1.0, -1.0), Vector2(1.0, -1.0),
						Vector2(-1.0, 1.0), Vector2(1.0, 1.0)]:
					_put("FLOOR_2x2_GRATE", Vector3(x + corner.x, y, z + corner.y))
			else:
				_put("FLOOR_4x4_PLATE", Vector3(x, y, z))
			z += CELL
		x += CELL

	# The slab it is laid on, and its collider. One box for the whole deck.
	_mesh_box(Vector3(mid.x, y - DECK_THICKNESS * 0.5, mid.y),
			Vector3(rect.size.x, DECK_THICKNESS, rect.size.y), MAT_MONOLITH)
	_collider_box(Vector3(mid.x, y - DECK_THICKNESS * 0.5, mid.y),
			Vector3(rect.size.x, DECK_THICKNESS, rect.size.y))

	# Joists across the underside of anything you can stand beneath.
	#
	# Found by photographing the thing rather than by reasoning about it: a player
	# on the machine floor looking up at a gallery had their beam land on a bare
	# four-by-twelve-metre plate. That is exactly the surface the intricacy law
	# says has to hold up at thirty centimetres, and it did not. It is also the
	# surface the gobo pass will be striping light across, so it wants relief in it
	# rather than a flat plane. Cheap, too: a joist every two metres on the short
	# axis, which is a handful of boxes per deck.
	if y >= RAIL_MIN_HEIGHT:
		var short_x: bool = rect.size.x <= rect.size.y
		var span: float = rect.size.x if short_x else rect.size.y
		var march: float = rect.size.y if short_x else rect.size.x
		var joist_y: float = y - DECK_THICKNESS - 0.16
		var t: float = 1.0
		while t < march - 0.01:
			var at: Vector3 = Vector3(mid.x, joist_y, rect.position.y + t) if short_x \
					else Vector3(rect.position.x + t, joist_y, mid.y)
			_detail_box(at, Vector3(span, 0.3, 0.18) if short_x
					else Vector3(0.18, 0.3, span), MAT_CONDUIT)
			t += 2.0
		# And a beam round the rim tying them together.
		for edge_side: int in 4:
			var rim: Dictionary = _edge_of(rect, edge_side)
			var a: Vector2 = rim["from"]
			var b: Vector2 = rim["to"]
			var length: float = a.distance_to(b)
			if length < 0.1:
				continue
			var rim_mid: Vector2 = (a + b) * 0.5
			_detail_box(Vector3(rim_mid.x, joist_y, rim_mid.y),
					Vector3(length, 0.34, 0.24) if edge_side % 2 == 0
					else Vector3(0.24, 0.34, length), MAT_TRIM)

	for side: int in open:
		var edge: Dictionary = _edge_of(rect, int(side))
		var from: Vector3 = Vector3(edge["from"].x, y - DECK_THICKNESS * 0.5, edge["from"].y)
		var to: Vector3 = Vector3(edge["to"].x, y - DECK_THICKNESS * 0.5, edge["to"].y)
		# Fascia: a deeper lip along the open edge, so the deck has a shadow line
		# under it instead of a paper thickness.
		var along: Vector3 = to - from
		var length: float = along.length()
		if length < 0.1:
			continue
		var centre: Vector3 = (from + to) * 0.5
		var thick: Vector3 = Vector3(0.22, 0.44, length) if int(side) % 2 == 1 \
				else Vector3(length, 0.44, 0.22)
		_detail_box(centre + Vector3(0.0, -0.08, 0.0), thick, MAT_CONDUIT)
		if columns and y >= RAIL_MIN_HEIGHT:
			_deck_columns(from, to, y)
		if y >= RAIL_MIN_HEIGHT:
			_railing(from + Vector3(0.0, DECK_THICKNESS * 0.5, 0.0),
					to + Vector3(0.0, DECK_THICKNESS * 0.5, 0.0), gaps)


## The two ends of one edge of a rect, inset so a railing does not overhang the
## corner it meets.
static func _edge_of(rect: Rect2, side: int) -> Dictionary:
	match side:
		0:
			return {"from": Vector2(rect.position.x, rect.position.y),
					"to": Vector2(rect.end.x, rect.position.y)}
		1:
			return {"from": Vector2(rect.end.x, rect.position.y),
					"to": Vector2(rect.end.x, rect.end.y)}
		2:
			return {"from": Vector2(rect.position.x, rect.end.y),
					"to": Vector2(rect.end.x, rect.end.y)}
		_:
			return {"from": Vector2(rect.position.x, rect.position.y),
					"to": Vector2(rect.position.x, rect.end.y)}


## Support columns down to the floor, every two cells. The motivation law applied
## to structure: a walkway eight metres in the air is held up by something, and
## the something is what a beam breaks on when you sweep the room.
func _deck_columns(from: Vector3, to: Vector3, y: float) -> void:
	var along: Vector3 = to - from
	var length: float = along.length()
	if length < 0.1 or y < 1.0:
		return
	var step: Vector3 = along / length
	var t: float = CELL * 0.5
	while t < length - 0.01:
		var at: Vector3 = from + step * t
		_put("RIB_COLUMN", Vector3(at.x, 0.0, at.z), 0.0)
		# The kit's rib column is one storey; anything taller gets a plain post
		# under the rest of the drop rather than a stack of stubs.
		if y > STOREY + 0.1:
			_detail_box(Vector3(at.x, (STOREY + y) * 0.5, at.z),
					Vector3(0.3, y - STOREY, 0.3), MAT_CONDUIT)
		t += CELL * 2.0


## Posts and two rails along an edge, with the railing left OPEN wherever a
## drop-down ledge was authored. The gap is the tell: a readable break in a rail
## is how a player learns there is a way down before they take it.
func _railing(from: Vector3, to: Vector3, gaps: Array) -> void:
	var along: Vector3 = to - from
	var length: float = along.length()
	if length < 0.6:
		return
	var step: Vector3 = along / length
	var normal: Vector3 = Vector3(step.z, 0.0, -step.x)
	var base: Vector3 = -normal * RAIL_INSET

	# Rails, split around every gap. A run is emitted for each clear interval, so
	# an eight-metre edge with one ledge in it becomes two rails, not one rail with
	# a hole drawn on it.
	var breaks: Array[Vector2] = []
	for gap_any: Variant in gaps:
		var gap: Vector3 = gap_any
		var t: float = (gap - from).dot(step)
		if t < -DROP_GAP or t > length + DROP_GAP:
			continue
		# Only a gap that is actually ON this edge, not one on the far side of the
		# deck that happens to project onto it.
		if absf((gap - from - step * t).dot(normal)) > 1.2:
			continue
		breaks.append(Vector2(maxf(t - DROP_GAP * 0.5, 0.0),
				minf(t + DROP_GAP * 0.5, length)))

	var cursor: float = 0.0
	var runs: Array[Vector2] = []
	breaks.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	for gap: Vector2 in breaks:
		if gap.x - cursor > 0.4:
			runs.append(Vector2(cursor, gap.x))
		cursor = maxf(cursor, gap.y)
	if length - cursor > 0.4:
		runs.append(Vector2(cursor, length))

	for run: Vector2 in runs:
		var run_length: float = run.y - run.x
		var centre: Vector3 = from + step * ((run.x + run.y) * 0.5) + base
		var size: Vector3 = Vector3(absf(step.x) * run_length + 0.08, 0.07,
				absf(step.z) * run_length + 0.08)
		for height: float in [RAIL_HEIGHT, RAIL_HEIGHT * 0.5]:
			_detail_box(centre + Vector3(0.0, height, 0.0), size, MAT_CONDUIT)
		var posts: int = maxi(int(run_length / 2.0), 1)
		for i: int in posts + 1:
			var at: Vector3 = from + step * lerpf(run.x, run.y, float(i) / float(posts)) + base
			_detail_box(at + Vector3(0.0, RAIL_HEIGHT * 0.5, 0.0),
					Vector3(0.09, RAIL_HEIGHT, 0.09), MAT_CONDUIT)
	# Toe plate along the whole edge, gaps included: it is what stops the deck
	# reading as a floating rectangle when the rail is broken for a ledge.
	var kick_centre: Vector3 = (from + to) * 0.5 + base
	_detail_box(kick_centre + Vector3(0.0, 0.09, 0.0),
			Vector3(absf(step.x) * length + 0.06, 0.18, absf(step.z) * length + 0.06),
			MAT_TRIM)


## A walkable slope from `y0` to `y1` across `rect`, climbing along `axis` in the
## direction `dir`. `treads` dresses it as a stair; otherwise it is a plain ramp
## plate. Either way the collision is ONE inclined box — see the section header.
func deck_ramp(rect: Rect2, axis: String, dir: int, y0: float, y1: float,
		treads: bool) -> void:
	var horizontal: bool = axis == "x"
	var run: float = rect.size.x if horizontal else rect.size.y
	var width: float = rect.size.y if horizontal else rect.size.x
	if run < 0.5:
		return
	var mid: Vector2 = rect.position + rect.size * 0.5
	var step: Vector3 = Vector3(float(dir), 0.0, 0.0) if horizontal \
			else Vector3(0.0, 0.0, float(dir))
	var low: Vector3 = Vector3(mid.x, y0, mid.y) - step * (run * 0.5)
	var high: Vector3 = Vector3(mid.x, y1, mid.y) + step * (run * 0.5)
	var forward: Vector3 = high - low
	var basis: Basis = _slope_basis(forward)
	var length: float = forward.length()
	var centre: Vector3 = (low + high) * 0.5

	# The collider, sunk half its thickness so its TOP face is the walking plane.
	_collider_oriented(centre - basis.y * (DECK_THICKNESS * 0.5),
			Vector3(length, DECK_THICKNESS, width), basis)

	if not treads:
		var plate: MeshInstance3D = _detail_box(
				centre - basis.y * (DECK_THICKNESS * 0.5),
				Vector3(length, DECK_THICKNESS, width), MAT_FLOOR)
		plate.basis = basis
		# Grip strips across the ramp, so a slope reads as a slope from above
		# rather than as a wedge of the same plate the floor is made of.
		var strips: int = maxi(int(length / 1.2), 1)
		for i: int in strips:
			var t: float = (float(i) + 0.5) / float(strips)
			var at: Vector3 = low.lerp(high, t)
			var strip: MeshInstance3D = _detail_box(at + basis.y * 0.03,
					Vector3(0.16, 0.05, width - 0.3), MAT_CONDUIT)
			strip.basis = basis
	else:
		var count: int = maxi(int(absf(y1 - y0) / TREAD_RISE), 1)
		for i: int in count:
			var t0: float = float(i) / float(count)
			var t1: float = float(i + 1) / float(count)
			var tread_mid: Vector3 = low.lerp(high, (t0 + t1) * 0.5)
			var depth: float = run / float(count)
			_detail_box(Vector3(tread_mid.x, tread_mid.y + 0.02, tread_mid.z),
					Vector3(depth if horizontal else width, 0.09,
							width if horizontal else depth), MAT_FLOOR)
			# The riser, so the flight has a face and throws a shadow ladder when
			# a beam rakes across it.
			var riser_at: Vector3 = low.lerp(high, t1)
			_detail_box(Vector3(riser_at.x, riser_at.y - TREAD_RISE * 0.5, riser_at.z)
					- step * (depth * 0.5),
					Vector3(0.07 if horizontal else width, absf(y1 - y0) / float(count),
							width if horizontal else 0.07), MAT_TRIM)

	# Stringers down both flanks: a ramp bolted to something, not a floating wedge.
	var side: Vector3 = basis.z * (width * 0.5)
	for sign_side: float in [1.0, -1.0]:
		var stringer: MeshInstance3D = _detail_box(
				centre + side * sign_side - basis.y * (DECK_THICKNESS * 0.5 + 0.12),
				Vector3(length, 0.34, 0.16), MAT_CONDUIT)
		stringer.basis = basis
	# No skirt under the flight, deliberately. A box under a slope either pokes
	# through the low end of it or leaves a gap at the high end, and closed risers
	# plus stringers already stop you seeing through a stair — the space beneath is
	# a real place a Scrubber can be, which is worth more than a solid wedge.


## The pit shell: four retaining walls down to the sunken floor, plus the floor
## itself. Called with the EXCAVATION rect (the sunken deck and its ramp merged),
## so the ramp is inside the hole rather than a slope down to a wall.
func deck_excavation(cut: Rect2, y: float) -> void:
	var depth: float = -y
	if depth <= 0.05:
		return
	var mid: Vector2 = cut.position + cut.size * 0.5
	_slab(cut.position, cut.end, y - SLAB_THICKNESS * 0.5, MAT_FLOOR)
	_collider_box(Vector3(mid.x, y - SLAB_THICKNESS * 0.5, mid.y),
			Vector3(cut.size.x, SLAB_THICKNESS, cut.size.y))
	for side: int in 4:
		var edge: Dictionary = _edge_of(cut, side)
		var from: Vector2 = edge["from"]
		var to: Vector2 = edge["to"]
		var centre: Vector2 = (from + to) * 0.5
		var length: float = from.distance_to(to)
		var horizontal: bool = side % 2 == 0
		_box(Vector3(centre.x, y * 0.5, centre.y),
				Vector3(length if horizontal else 0.3, depth,
						0.3 if horizontal else length), MAT_MONOLITH)


## Overhead structure for a tall room: a girder lattice, pipe racks and the cable
## trays that run between them.
##
## The motivation law, at ceiling height. Nothing here is scattered: the girders
## are the frame that carries the roof, the pipe runs sit ON the girders, and every
## tray leaves a wall riser and arrives somewhere that needs it. It is also
## deliberate preparation for the lighting pass — a gobo dropped through a girder
## lattice onto a grated mezzanine is three layers of shadow for one light.
func technical_ceiling(rect: Rect2, height: float, loads: Array) -> void:
	if height < STOREY * 1.5:
		return
	var mid: Vector2 = rect.position + rect.size * 0.5
	var girder_y: float = height - 0.55

	# Primary girders on the long axis, every two cells; secondaries across them.
	var long_x: bool = rect.size.x >= rect.size.y
	var pitch: float = CELL * 2.0
	var t: float = (rect.position.y if long_x else rect.position.x) + CELL
	var limit: float = (rect.end.y if long_x else rect.end.x) - CELL * 0.5
	while t < limit:
		if long_x:
			_mesh_box(Vector3(mid.x, girder_y, t), Vector3(rect.size.x, 0.42, 0.3),
					MAT_CONDUIT)
			_mesh_box(Vector3(mid.x, girder_y - 0.3, t), Vector3(rect.size.x, 0.1, 0.16),
					MAT_TRIM)
		else:
			_mesh_box(Vector3(t, girder_y, mid.y), Vector3(0.3, 0.42, rect.size.y),
					MAT_CONDUIT)
			_mesh_box(Vector3(t, girder_y - 0.3, mid.y), Vector3(0.16, 0.1, rect.size.y),
					MAT_TRIM)
		t += pitch
	# One cross-tie the other way, so the lattice reads as a frame rather than as
	# a set of parallel beams.
	if long_x:
		_mesh_box(Vector3(mid.x, girder_y + 0.34, mid.y),
				Vector3(rect.size.x, 0.24, 0.24), MAT_CONDUIT)
	else:
		_mesh_box(Vector3(mid.x, girder_y + 0.34, mid.y),
				Vector3(0.24, 0.24, rect.size.y), MAT_CONDUIT)

	# Pipe racks hung under the girders, on the kit's own pipe module.
	var rack_y: float = girder_y - 1.05
	var p: float = (rect.position.x if long_x else rect.position.y) + CELL * 0.5
	var p_end: float = (rect.end.x if long_x else rect.end.y) - 0.01
	var lane: float = (mid.y if long_x else mid.x) - CELL
	while p < p_end:
		if long_x:
			_put("PIPE_RUN_4M", Vector3(p - CELL * 0.5, rack_y, lane), 0.0)
		else:
			_put("PIPE_RUN_4M", Vector3(lane, rack_y, p - CELL * 0.5), 90.0)
		p += CELL

	# Cable trays: FROM a wall riser TO each load. A tray that arrives nowhere is
	# the failure mode this whole grammar exists to prevent.
	# The trim kit's own cable tray, laid along the rack lane. Cheaper and better
	# than boxes where it exists; the `_conduit_run` branches below still do the
	# actual FROM-here-TO-there routing, because a tray is a channel and a channel
	# with nothing running in it is scenery.
	if KitLib.has("CEIL_CABLE_TRAY_4M"):
		var q: float = (rect.position.x if long_x else rect.position.y) + CELL * 0.5
		var lane_b: float = (mid.y if long_x else mid.x) + CELL
		while q < p_end:
			if long_x:
				_put("CEIL_CABLE_TRAY_4M", Vector3(q - CELL * 0.5, rack_y + 0.25, lane_b), 0.0)
			else:
				_put("CEIL_CABLE_TRAY_4M", Vector3(lane_b, rack_y + 0.25, q - CELL * 0.5), 90.0)
			q += CELL

	var riser: Vector3 = Vector3(rect.position.x + 0.9, 0.0, mid.y)
	for load_any: Variant in loads:
		var load: Vector3 = load_any
		_conduit_run(Vector3(riser.x, 1.4, riser.z), Vector3(riser.x, rack_y - 0.3, riser.z), 0.16)
		_conduit_run(Vector3(riser.x, rack_y - 0.3, riser.z),
				Vector3(load.x, rack_y - 0.3, riser.z), 0.13)
		_conduit_run(Vector3(load.x, rack_y - 0.3, riser.z),
				Vector3(load.x, rack_y - 0.3, load.z), 0.13)
		_conduit_run(Vector3(load.x, rack_y - 0.3, load.z),
				Vector3(load.x, maxf(load.y, 1.6), load.z), 0.13)


# ------------------------------------------------------------------- spawns --

## Subclasses override. Identity keeps a builder usable before it has a layout.
func get_spawn_point(_index: int) -> Transform3D:
	return Transform3D.IDENTITY
