class_name LayerBuilder
extends GeometryKit
## Hand-authored greybox security layer, assembled from a layout table at load time.
##
## Superseded as the played map by ProcLayerBuilder in M2, but kept alive as the
## `--testlayer` reference: a fixed, known-good layout to compare procedural
## output against and to isolate whether a bug is in the generator or in the
## geometry kit it emits through.
##
## The layout lives in data (ROOMS / CORRIDORS / CONDUIT_NODES) rather than in a
## 2000-line .tscn so it stays diffable and tweakable while we tune the feel. All
## the drawing primitives it calls live in GeometryKit, shared with the generator.

## Rooms: full box with four walls, each wall optionally pierced by doors.
## Wall keys: "n" = -Z side, "s" = +Z side, "w" = -X side, "e" = +X side.
const ROOMS: Array[Dictionary] = [
	{
		# Injection point: where the crew is written into the layer.
		"id": "injection", "min": Vector2(-9.0, -7.0), "max": Vector2(9.0, 7.0), "h": 7.0,
		"doors": [{"wall": "n", "at": 0.0}],
	},
	{
		# Bus junction: the layer's crossroads.
		"id": "junction", "min": Vector2(-6.0, -31.0), "max": Vector2(6.0, -19.0), "h": 4.6,
		"doors": [
			{"wall": "s", "at": 0.0},
			{"wall": "n", "at": 0.0},
			{"wall": "w", "at": -25.0},
			{"wall": "e", "at": -25.0},
		],
	},
	{
		# Cold storage: racked data blocks.
		"id": "vault", "min": Vector2(-32.0, -32.0), "max": Vector2(-18.0, -18.0), "h": 4.0,
		"doors": [{"wall": "e", "at": -25.0}],
	},
	{
		# Bus hall: processing stacks and trunk conduits.
		"id": "bus", "min": Vector2(18.0, -33.0), "max": Vector2(34.0, -17.0), "h": 5.5,
		"doors": [{"wall": "w", "at": -25.0}],
	},
	{
		# Glyph vault: one panel still holding a process open.
		"id": "glyph", "min": Vector2(-6.5, -51.0), "max": Vector2(6.5, -41.0), "h": 3.6,
		"doors": [{"wall": "s", "at": 0.0}],
	},
]

## Corridors: floor, ceiling and two long walls. Ends are open by construction.
const CORRIDORS: Array[Dictionary] = [
	{"id": "a", "min": Vector2(-1.8, -19.0), "max": Vector2(1.8, -7.0), "h": 3.4, "axis": "z"},
	{"id": "w", "min": Vector2(-18.0, -26.8), "max": Vector2(-6.0, -23.2), "h": 3.4, "axis": "x"},
	{"id": "e", "min": Vector2(6.0, -26.8), "max": Vector2(18.0, -23.2), "h": 3.4, "axis": "x"},
	{"id": "n", "min": Vector2(-1.8, -41.0), "max": Vector2(1.8, -31.0), "h": 3.2, "axis": "z"},
]

## Conduit nodes: junction boxes where a trace run terminates and actually throws
## light. These are the layer's only ambient illumination.
const CONDUIT_NODES: Array[Dictionary] = [
	# Injection point — the best-lit room on the layer, and still barely lit.
	{"pos": Vector3(-8.6, 4.2, -2.0), "axis": "x", "len": 4.0,
		"color": Color(0.3, 0.84, 1.0), "energy": 4.0, "range": 20.0, "flicker": false},
	{"pos": Vector3(8.6, 4.2, 2.0), "axis": "x", "len": 4.0,
		"color": Color(0.3, 0.84, 1.0), "energy": 4.0, "range": 20.0, "flicker": false},
	{"pos": Vector3(-8.6, 4.2, 5.0), "axis": "x", "len": 2.4,
		"color": Color(0.26, 0.76, 1.0), "energy": 2.2, "range": 14.0, "flicker": true},
	# Corridor A — one unstable node, then unrendered dark.
	{"pos": Vector3(-1.6, 2.9, -12.0), "axis": "x", "len": 2.6,
		"color": Color(0.34, 0.88, 1.0), "energy": 2.6, "range": 13.0, "flicker": true},
	# Bus junction.
	{"pos": Vector3(-5.6, 3.6, -22.0), "axis": "x", "len": 3.0,
		"color": Color(0.3, 0.82, 1.0), "energy": 2.8, "range": 15.0, "flicker": false},
	{"pos": Vector3(5.6, 3.6, -28.0), "axis": "x", "len": 3.0,
		"color": Color(0.3, 0.82, 1.0), "energy": 1.8, "range": 14.0, "flicker": true},
	# Cold storage — an amber node running on some older standard.
	{"pos": Vector3(-25.0, 3.2, -31.6), "axis": "z", "len": 3.4,
		"color": SYSTEM_AMBER, "energy": 2.6, "range": 15.0, "flicker": false},
	# Corridor E.
	{"pos": Vector3(12.0, 2.9, -26.6), "axis": "z", "len": 2.6,
		"color": Color(0.3, 0.84, 1.0), "energy": 2.0, "range": 12.0, "flicker": false},
	# Bus hall — heavy amber load lighting over the stacks.
	{"pos": Vector3(33.6, 4.4, -25.0), "axis": "z", "len": 4.5,
		"color": SYSTEM_AMBER, "energy": 3.4, "range": 18.0, "flicker": false},
	{"pos": Vector3(18.4, 4.4, -20.0), "axis": "z", "len": 2.5,
		"color": Color(0.34, 0.88, 1.0), "energy": 1.6, "range": 12.0, "flicker": true},
	# Glyph vault — nearly nothing. The panel is the light source.
	{"pos": Vector3(-6.1, 2.8, -47.0), "axis": "z", "len": 2.0,
		"color": Color(0.3, 0.8, 1.0), "energy": 1.1, "range": 10.0, "flicker": false},
]

## Crew injection points. All face north, into the layer.
const SPAWNS: Array[Vector3] = [
	Vector3(-1.2, 0.0, -1.0),
	Vector3(0.9, 0.0, 4.6),
	Vector3(-4.2, 0.0, 4.6),
	Vector3(4.4, 0.0, -1.0),
]

## The test layer's stand-ins for the procedural furniture, so `--testlayer` can
## still exercise the Cycles economy and the descent.
const TEST_SIPHONS: Array[Vector3] = [
	Vector3(-25.0, 0.0, -21.0),
	Vector3(28.0, 0.0, -21.0),
]
const TEST_SHAFT: Vector3 = Vector3(0.0, 0.0, -46.0)


func _build_content() -> void:
	for room: Dictionary in ROOMS:
		_build_room(room)
	for corridor: Dictionary in CORRIDORS:
		_build_corridor(corridor)

	for node: Dictionary in CONDUIT_NODES:
		_build_conduit_node(node)

	_build_injection_point_dressing()
	_build_vault_dressing()
	_build_bus_dressing()
	_build_glyph_dressing()

	for i: int in TEST_SIPHONS.size():
		var tap: SiphonTap = SiphonTap.create(i, TEST_SIPHONS[i], 0.0)
		tap.add_to_group("siphon_taps")
		_fixtures.add_child(tap)
	var shaft: DropShaft = DropShaft.create(TEST_SHAFT)
	shaft.add_to_group("drop_shafts")
	_fixtures.add_child(shaft)


# ----------------------------------------------------------------- dressing --

func _build_injection_point_dressing() -> void:
	_build_scan_sweep(Vector3(0.0, 6.2, 0.0))

	# The injection port on the south wall: the aperture the crew was written in
	# through. Recessed dark slab, bright ring — and no way back out through it.
	_mesh_box(Vector3(0.0, 3.0, 6.7), Vector3(7.0, 6.0, 0.12), MAT_CONDUIT)
	_port_ring(Vector3(0.0, 3.0, 6.62), 6.4, 5.4)
	_mesh_box(Vector3(0.0, 3.0, 6.62), Vector3(0.09, 5.0, 0.06), _gate_material)

	# Maintenance gantry along the west wall.
	_box(Vector3(-7.4, 2.6, 0.0), Vector3(2.6, 0.25, 11.0), MAT_CONDUIT)
	for i: int in 6:
		var z: float = -5.0 + float(i) * 2.0
		_mesh_box(Vector3(-6.2, 1.3, z), Vector3(0.18, 2.6, 0.18), MAT_CONDUIT)
		_mesh_box(Vector3(-6.2, 3.15, z), Vector3(0.1, 0.9, 0.1), MAT_CONDUIT)
	_mesh_box(Vector3(-6.2, 3.6, 0.0), Vector3(0.09, 0.09, 11.0), MAT_CONDUIT)
	_trace(Vector3(-7.4, 2.74, -5.4), Vector3(-7.4, 2.74, 5.4), _grid_material)

	_data_block(Vector3(6.2, 0.0, -4.4), Vector3(1.5, 1.5, 1.5), 0.18)
	_data_block(Vector3(7.0, 1.5, -4.1), Vector3(1.2, 1.2, 1.2), -0.4)
	_data_block(Vector3(5.0, 0.0, -5.6), Vector3(1.1, 0.9, 1.4), 0.9)
	_data_block(Vector3(-3.4, 0.0, 5.8), Vector3(1.6, 1.2, 1.2), -0.15)
	_data_block(Vector3(3.0, 0.0, 6.0), Vector3(1.3, 1.3, 1.3), 0.5)

	_conduit_run(Vector3(-8.6, 5.4, -6.6), Vector3(-8.6, 5.4, 6.6), 0.22)
	_conduit_run(Vector3(8.6, 5.8, -6.6), Vector3(8.6, 5.8, 6.6), 0.16)


func _build_vault_dressing() -> void:
	var origin: Vector3 = Vector3(-25.0, 0.0, -25.0)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 90210
	for i: int in 14:
		var x: float = origin.x + rng.randf_range(-5.5, 5.5)
		var z: float = origin.z + rng.randf_range(-5.5, 5.5)
		var s: float = rng.randf_range(0.9, 1.7)
		_data_block(Vector3(x, 0.0, z), Vector3(s, s * rng.randf_range(0.7, 1.1), s),
				rng.randf_range(-0.6, 0.6))
		if rng.randf() < 0.4:
			_data_block(Vector3(x + rng.randf_range(-0.2, 0.2), s * 0.8, z),
					Vector3(s * 0.8, s * 0.7, s * 0.8), rng.randf_range(-0.8, 0.8))

	_mesh_box(Vector3(-31.6, 2.0, -25.0), Vector3(0.12, 3.2, 8.0), MAT_CONDUIT)
	_conduit_run(Vector3(-31.5, 3.4, -31.5), Vector3(-31.5, 3.4, -18.5), 0.18)


func _build_bus_dressing() -> void:
	# Processing stacks: tall silhouettes that break a beam into slats.
	for i: int in 4:
		var x: float = 22.0 + float(i) * 3.2
		_box(Vector3(x, 1.6, -29.5), Vector3(1.9, 3.2, 2.4), MAT_CONDUIT)
		_mesh_box(Vector3(x, 3.28, -29.5), Vector3(1.5, 0.1, 2.0),
				_make_emissive(SYSTEM_AMBER, 0.9))
		# Load indicators climbing each stack.
		for row: int in 3:
			_trace(Vector3(x - 0.6, 0.7 + float(row) * 0.8, -28.28),
					Vector3(x + 0.6, 0.7 + float(row) * 0.8, -28.28), _trace_material)
		_conduit_run(Vector3(x, 3.4, -29.5), Vector3(x, 5.3, -29.5), 0.28)

	_box(Vector3(30.0, 1.2, -21.0), Vector3(4.5, 2.4, 3.0), MAT_CONDUIT)
	_mesh_box(Vector3(30.0, 2.45, -21.0), Vector3(3.6, 0.08, 2.2),
			_make_emissive(Color(0.3, 1.0, 0.6), 0.7))

	for i: int in 5:
		var z: float = -31.0 + float(i) * 3.5
		_conduit_run(Vector3(18.5, 4.6, z), Vector3(33.5, 4.6, z), 0.2)
	_conduit_run(Vector3(19.0, 0.9, -17.4), Vector3(19.0, 0.9, -32.6), 0.34)
	_conduit_run(Vector3(19.7, 1.5, -17.4), Vector3(19.7, 1.5, -32.6), 0.22)


func _build_glyph_dressing() -> void:
	# A holographic glyph panel still holding a process open — the only thing
	# alive this deep, and the first place a player will walk toward.
	_glyph_panel(Vector3(0.0, 0.0, -50.2), Color(0.32, 1.0, 0.62))

	_data_block(Vector3(-4.6, 0.0, -47.0), Vector3(1.3, 1.0, 1.3), 0.3)
	_data_block(Vector3(4.8, 0.0, -49.0), Vector3(1.1, 1.4, 1.1), -0.2)
	_conduit_run(Vector3(-6.2, 3.1, -50.6), Vector3(-6.2, 3.1, -41.4), 0.16)


# ------------------------------------------------------------------- spawns --

func get_spawn_point(index: int) -> Transform3D:
	var point: Vector3 = SPAWNS[index % SPAWNS.size()]
	return Transform3D(Basis.IDENTITY, point)
