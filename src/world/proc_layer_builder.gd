class_name ProcLayerBuilder
extends GeometryKit
## Turns a LayerGraph into standing architecture, using the same slab/trace/gate
## vocabulary the hand-authored test layer is built from.
##
## Everything here is deterministic: the only randomness comes from a generator
## seeded off `graph.layer_seed`, so two peers on the same layer place the same
## crate in the same corner. Nothing about the build is replicated.
##
## Lighting is the load-bearing art decision. DESIGN.md pillar 2 — "Unrendered
## space is near-black" — means a layer must be *mostly dark*: rooms get a
## handful of weak wall nodes, most corridors get none at all, and LayerParams
## drags both down as you descend. If you can cross a room without your beam on,
## the layer is wrong.

var graph: LayerGraph = null

var _rng: RandomNumberGenerator = null
var _taps: Array[SiphonTap] = []
var _shaft: DropShaft = null


static func create(from_graph: LayerGraph) -> ProcLayerBuilder:
	var builder: ProcLayerBuilder = ProcLayerBuilder.new()
	builder.name = "ProcLayerBuilder"
	builder.graph = from_graph
	builder.light_scale = float(from_graph.params["light_scale"])
	return builder


func _build_content() -> void:
	if graph == null:
		push_error("[ProcLayerBuilder] no graph")
		return

	# A stream of its own, so tuning the dressing never shifts the layout.
	_rng = RandomNumberGenerator.new()
	_rng.seed = hash(str(graph.layer_seed, ":dressing"))

	for room: Dictionary in graph.rooms:
		_build_room(room)
	for corridor: Dictionary in graph.corridors:
		_build_corridor(corridor)

	for room: Dictionary in graph.rooms:
		_light_room(room)
	for corridor: Dictionary in graph.corridors:
		_light_corridor(corridor)

	for room: Dictionary in graph.rooms:
		match String(room["archetype"]):
			LayerGraph.ARRIVAL:
				_dress_arrival(room)
			LayerGraph.SIPHON:
				_dress_siphon(room)
			LayerGraph.VAULT:
				_dress_vault(room)
			LayerGraph.SHAFT:
				_dress_shaft(room)
			LayerGraph.BACKDOOR:
				_dress_backdoor(room)
			_:
				_dress_bus(room)

	_place_furniture()


# ------------------------------------------------------------------- lights --

## Wall-mounted conduit nodes. Mounting position and the inward normal are
## computed per wall so the housing never shadows its own light — the origin-
## relative heuristic the hand-authored layer uses does not survive a room 50 m
## off-centre.
func _light_room(room: Dictionary) -> void:
	# Nests get nothing at all. An unlit room is the darkest thing on a layer and
	# the only place a Scrubber is comfortable — the two facts are the same fact.
	if bool(room["unlit"]):
		return

	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var h: float = room["h"]
	var count: int = int(graph.params["room_light_count"])

	# The arrival room is the crew's one moment of orientation, so it always gets
	# the full complement plus a little more energy. The sanctuary is the other
	# exception: it is meant to feel safe, and dark is not safe.
	var archetype: String = String(room["archetype"])
	if archetype == LayerGraph.ARRIVAL:
		count += 1
	elif archetype == LayerGraph.BACKDOOR:
		count += 3

	for i: int in count:
		var wall: int = _rng.randi_range(0, 3)
		var height: float = minf(h - 1.0, _rng.randf_range(2.6, 4.2))
		# The sanctuary runs warm and steady; everywhere else the system's own
		# cold teal, with the occasional amber accent.
		var warm: bool = _rng.randf() < 0.22 or archetype == LayerGraph.BACKDOOR
		var colour: Color = SYSTEM_AMBER if warm else Color(
				_rng.randf_range(0.26, 0.34), _rng.randf_range(0.78, 0.88), 1.0)
		# Flicker is the layer telling you not to trust it. More of it deeper —
		# and none of it in the one room that is not lying to you.
		var flicker: bool = _rng.randf() < lerpf(0.28, 0.55, float(graph.params["depth"])) \
				and archetype != LayerGraph.BACKDOOR
		var energy: float = _rng.randf_range(1.6, 3.2)
		if archetype == LayerGraph.ARRIVAL:
			energy += 1.0
		elif archetype == LayerGraph.BACKDOOR:
			energy += 1.6

		var spec: Dictionary = {
			"len": _rng.randf_range(2.0, 4.0),
			"color": colour, "energy": energy,
			"range": _rng.randf_range(11.0, 17.0), "flicker": flicker,
		}
		match wall:
			0:  # north (-Z)
				spec["pos"] = Vector3(_rng.randf_range(lo.x + 2.0, hi.x - 2.0), height, lo.y + 0.25)
				spec["axis"] = "x"
				spec["normal"] = Vector3(0.0, -0.1, 0.4)
			1:  # south (+Z)
				spec["pos"] = Vector3(_rng.randf_range(lo.x + 2.0, hi.x - 2.0), height, hi.y - 0.25)
				spec["axis"] = "x"
				spec["normal"] = Vector3(0.0, -0.1, -0.4)
			2:  # west (-X)
				spec["pos"] = Vector3(lo.x + 0.25, height, _rng.randf_range(lo.y + 2.0, hi.y - 2.0))
				spec["axis"] = "z"
				spec["normal"] = Vector3(0.4, -0.1, 0.0)
			_:  # east (+X)
				spec["pos"] = Vector3(hi.x - 0.25, height, _rng.randf_range(lo.y + 2.0, hi.y - 2.0))
				spec["axis"] = "z"
				spec["normal"] = Vector3(-0.4, -0.1, 0.0)
		_build_conduit_node(spec)


## Most corridors are unlit on purpose: a lit corridor is a corridor you can
## cross without committing your beam, and that is the whole tension.
func _light_corridor(corridor: Dictionary) -> void:
	if _rng.randf() > float(graph.params["corridor_light_chance"]):
		return
	var lo: Vector2 = corridor["min"]
	var hi: Vector2 = corridor["max"]
	var h: float = corridor["h"]
	var mid: Vector2 = (lo + hi) * 0.5

	var spec: Dictionary = {
		"len": 2.4, "color": Color(0.32, 0.85, 1.0),
		"energy": _rng.randf_range(1.4, 2.4), "range": 12.0,
		"flicker": _rng.randf() < 0.5,
	}
	if String(corridor["axis"]) == "z":
		spec["pos"] = Vector3(lo.x + 0.22, h - 0.7, _rng.randf_range(lo.y + 2.0, hi.y - 2.0))
		spec["axis"] = "z"
		spec["normal"] = Vector3(0.35, -0.1, 0.0)
	else:
		spec["pos"] = Vector3(_rng.randf_range(lo.x + 2.0, hi.x - 2.0), h - 0.7, lo.y + 0.22)
		spec["axis"] = "x"
		spec["normal"] = Vector3(0.0, -0.1, 0.35)
	_build_conduit_node(spec)


# ----------------------------------------------------------------- archetypes --

## Injection point: the aperture the crew was written in through, a red scan
## sweep watching the room, and enough light to get your bearings once.
func _dress_arrival(room: Dictionary) -> void:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var centre: Vector2 = (lo + hi) * 0.5
	var h: float = room["h"]

	_build_scan_sweep(Vector3(centre.x, h - 0.6, centre.y))

	# Port on the south wall, facing back into the room.
	var port_z: float = hi.y - 0.22
	_mesh_box(Vector3(centre.x, 3.0, port_z), Vector3(7.0, 6.0, 0.12), MAT_CONDUIT)
	_port_ring(Vector3(centre.x, 3.0, port_z - 0.08), 6.4, 5.4)
	_mesh_box(Vector3(centre.x, 3.0, port_z - 0.08), Vector3(0.09, 5.0, 0.06), _gate_material)

	_conduit_run(Vector3(lo.x + 0.6, h - 1.2, lo.y + 1.0),
			Vector3(lo.x + 0.6, h - 1.2, hi.y - 1.0), 0.22)
	_conduit_run(Vector3(hi.x - 0.6, h - 1.4, lo.y + 1.0),
			Vector3(hi.x - 0.6, h - 1.4, hi.y - 1.0), 0.16)
	_scatter_blocks(room, 4, 0.9, 1.6)


## Siphon junction: the tap plus the machinery feeding it, so the tap reads as
## plumbed into the layer rather than dropped on the floor.
func _dress_siphon(room: Dictionary) -> void:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var h: float = room["h"]
	var centre: Vector2 = (lo + hi) * 0.5

	for i: int in 3:
		var z: float = lerpf(lo.y + 2.0, hi.y - 2.0, (float(i) + 0.5) / 3.0)
		_conduit_run(Vector3(lo.x + 0.5, h - 1.0, z), Vector3(hi.x - 0.5, h - 1.0, z), 0.24)
	_conduit_run(Vector3(centre.x, h - 1.0, centre.y), Vector3(centre.x, 2.6, centre.y), 0.3)
	_scatter_blocks(room, 3, 0.8, 1.3)


## Data vault: racked storage and a glyph panel still holding a process open.
## Locked flavour only in M2 — DESIGN.md puts the Sentinel guarding it in M3.
func _dress_vault(room: Dictionary) -> void:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var centre: Vector2 = (lo + hi) * 0.5

	_scatter_blocks(room, 14, 0.9, 1.8)

	# The panel faces the room's interior from the north wall.
	_glyph_panel(Vector3(centre.x, 0.0, lo.y + 1.1), Color(0.32, 1.0, 0.62))

	# A quarantine bar across the vault: this is what "locked" looks like before
	# there is anything to unlock it with.
	var bar: StandardMaterial3D = _make_emissive(Color(1.0, 0.42, 0.3), 0.7)
	for i: int in 3:
		var x: float = lerpf(lo.x + 2.0, hi.x - 2.0, (float(i) + 0.5) / 3.0)
		_mesh_box(Vector3(x, 2.4, centre.y), Vector3(0.06, 0.06, hi.y - lo.y - 3.0), bar)


## Backdoor node sanctuary. Deliberately unlike every other room on the layer:
## bigger, taller, warm, symmetrical, and with a vaulted ceiling instead of a
## slab. DESIGN.md makes this the crew's one safe place — antivirus never comes
## in here — and it has to *look* like somewhere you can stop running.
func _dress_backdoor(room: Dictionary) -> void:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var h: float = room["h"]
	var centre: Vector2 = (lo + hi) * 0.5
	var amber: StandardMaterial3D = _make_emissive(SYSTEM_AMBER, 0.8)

	# A colonnade rather than scattered clutter: the room is architecture, and
	# somebody built it on purpose.
	var columns: int = 6
	for i: int in columns:
		var angle: float = TAU * float(i) / float(columns)
		var at: Vector2 = centre + Vector2(cos(angle), sin(angle)) * (LayerGraph.BACKDOOR_HALF - 2.6)
		_box(Vector3(at.x, h * 0.5, at.y), Vector3(1.1, h, 1.1), MAT_CONDUIT)
		_mesh_box(Vector3(at.x, h - 0.5, at.y), Vector3(1.35, 0.12, 1.35), amber)
		_mesh_box(Vector3(at.x, 1.2, at.y), Vector3(1.2, 0.05, 1.2), amber)
		# Ribs running from every column to the middle: a vault, not a lid.
		_conduit_run(Vector3(at.x, h - 0.55, at.y), Vector3(centre.x, h - 1.6, centre.y), 0.22)

	# Warm floor ring around the middle of the room, wide enough to walk inside.
	var ring: int = 28
	for i: int in ring:
		var angle: float = TAU * float(i) / float(ring)
		var at: Vector2 = centre + Vector2(cos(angle), sin(angle)) * (LayerGraph.BACKDOOR_HALF - 5.5)
		_mesh_box(Vector3(at.x, 0.016, at.y), Vector3(0.9, 0.03, 0.12), amber)

	# The one glyph panel on the layer that is telling you something good.
	_glyph_panel(Vector3(centre.x, 0.0, lo.y + 1.4), SYSTEM_AMBER)

	var hearth: OmniLight3D = OmniLight3D.new()
	hearth.name = "SanctuaryGlow"
	hearth.position = Vector3(centre.x, h - 1.8, centre.y)
	hearth.light_color = SYSTEM_AMBER
	hearth.light_energy = 3.6 * light_scale
	hearth.omni_range = 30.0
	hearth.omni_attenuation = 0.75
	hearth.light_volumetric_fog_energy = 1.6
	hearth.shadow_enabled = false
	_fixtures.add_child(hearth)

	_scatter_blocks(room, 5, 1.0, 1.7)


## A nest. No fixtures at all (see _light_room) — just dark red inlay on the
## floor, so a beam sweeping the room tells you what you have walked into a
## moment before the sensors light up.
func _dress_nest(room: Dictionary) -> void:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var centre: Vector2 = (lo + hi) * 0.5
	var rot: StandardMaterial3D = _make_emissive(Color(0.6, 0.08, 0.1), 0.42)

	# Growth radiating from the middle of the room: MOTHER's cleaners have been
	# living here and the architecture has gone over to them.
	var strands: int = _rng.randi_range(5, 8)
	for i: int in strands:
		var angle: float = _rng.randf_range(0.0, TAU)
		var reach: float = _rng.randf_range(3.0, 7.0)
		var to: Vector2 = centre + Vector2(cos(angle), sin(angle)) * reach
		to.x = clampf(to.x, lo.x + 1.0, hi.x - 1.0)
		to.y = clampf(to.y, lo.y + 1.0, hi.y - 1.0)
		_trace(Vector3(centre.x, 0.016, centre.y), Vector3(to.x, 0.016, to.y), rot, 0.07)
		_data_block(Vector3(to.x, 0.0, to.y), Vector3.ONE * _rng.randf_range(0.5, 0.9),
				_rng.randf_range(-0.8, 0.8))


## Bus hall: processing stacks that break a beam into slats, and trunk conduits.
func _dress_bus(room: Dictionary) -> void:
	if bool(room["unlit"]):
		_dress_nest(room)
		return

	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var h: float = room["h"]
	var centre: Vector2 = (lo + hi) * 0.5

	var stacks: int = _rng.randi_range(2, 4)
	var glow: StandardMaterial3D = _make_emissive(SYSTEM_AMBER, 0.9)
	for i: int in stacks:
		var x: float = lerpf(lo.x + 2.5, hi.x - 2.5, (float(i) + 0.5) / float(stacks))
		var z: float = centre.y + _rng.randf_range(-1.5, 1.5)
		_box(Vector3(x, 1.6, z), Vector3(1.9, 3.2, 2.4), MAT_CONDUIT)
		_mesh_box(Vector3(x, 3.28, z), Vector3(1.5, 0.1, 2.0), glow)
		for row: int in 3:
			_trace(Vector3(x - 0.6, 0.7 + float(row) * 0.8, z - 1.22),
					Vector3(x + 0.6, 0.7 + float(row) * 0.8, z - 1.22), _trace_material)
		_conduit_run(Vector3(x, 3.4, z), Vector3(x, h - 0.8, z), 0.28)

	for i: int in 3:
		var cz: float = lerpf(lo.y + 1.5, hi.y - 1.5, (float(i) + 0.5) / 3.0)
		_conduit_run(Vector3(lo.x + 0.6, h - 0.9, cz), Vector3(hi.x - 0.6, h - 0.9, cz), 0.2)
	_scatter_blocks(room, 3, 0.9, 1.5)


## Drop-shaft trunk: the room is the shaft. Heavy conduits converge on the pad
## and the ceiling opens over it, so the way down is legible from the doorway.
func _dress_shaft(room: Dictionary) -> void:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var h: float = room["h"]
	var centre: Vector2 = (lo + hi) * 0.5

	for corner: Vector2 in [Vector2(lo.x + 1.0, lo.y + 1.0), Vector2(hi.x - 1.0, lo.y + 1.0),
			Vector2(lo.x + 1.0, hi.y - 1.0), Vector2(hi.x - 1.0, hi.y - 1.0)]:
		_conduit_run(Vector3(corner.x, h - 0.7, corner.y),
				Vector3(centre.x, h - 0.7, centre.y), 0.22)
		_conduit_run(Vector3(corner.x, 0.6, corner.y), Vector3(corner.x, h - 0.7, corner.y), 0.3)

	# Aperture ring in the ceiling, so the trunk visibly leaves the room.
	var ring: StandardMaterial3D = _make_emissive(Color(0.36, 0.9, 1.0), 0.9)
	for i: int in 4:
		var angle: float = float(i) * PI * 0.5
		var offset: Vector3 = Vector3(cos(angle), 0.0, sin(angle)) * 2.0
		_mesh_box(Vector3(centre.x, h - 0.12, centre.y) + offset,
				Vector3(4.0 if int(i) % 2 == 1 else 0.1, 0.08, 0.1 if int(i) % 2 == 1 else 4.0),
				ring)


# ---------------------------------------------------------------- furniture --

## Loose data blocks. Kept clear of the room's middle band so a doorway-to-
## doorway path is never blocked and future navmesh baking stays trivial.
func _scatter_blocks(room: Dictionary, count: int, min_size: float, max_size: float) -> void:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var centre: Vector2 = (lo + hi) * 0.5

	for i: int in count:
		var s: float = _rng.randf_range(min_size, max_size)
		var x: float = _rng.randf_range(lo.x + 2.0, hi.x - 2.0)
		var z: float = _rng.randf_range(lo.y + 2.0, hi.y - 2.0)
		# Push anything that landed in the central crossing out to the edges.
		if absf(x - centre.x) < 3.0 and absf(z - centre.y) < 3.0:
			x = centre.x + signf(x - centre.x + 0.001) * _rng.randf_range(3.2, 5.0)
			x = clampf(x, lo.x + 1.8, hi.x - 1.8)
		_data_block(Vector3(x, 0.0, z), Vector3(s, s * _rng.randf_range(0.7, 1.2), s),
				_rng.randf_range(-0.7, 0.7))


func _place_furniture() -> void:
	for i: int in graph.siphon_points.size():
		var tap: SiphonTap = SiphonTap.create(i, graph.siphon_points[i],
				_rng.randf_range(-PI, PI))
		tap.add_to_group("siphon_taps")
		_fixtures.add_child(tap)
		_taps.append(tap)

	_shaft = DropShaft.create(graph.shaft_point)
	_shaft.add_to_group("drop_shafts")
	_fixtures.add_child(_shaft)

	# Salvage. Worth is a pure function of the layer, so every peer agrees on
	# what a shard is worth without being told.
	var worth: int = Balance.shard_value(graph.layer_number)
	for i: int in graph.shard_points.size():
		_fixtures.add_child(DataShard.create(i, graph.shard_points[i], worth))

	if not graph.is_backdoor:
		return
	_fixtures.add_child(BackdoorNode.create(graph.backdoor_point))
	_fixtures.add_child(ExfilUplink.create(graph.uplink_point))


# ------------------------------------------------------------------- spawns --

func get_spawn_point(index: int) -> Transform3D:
	return graph.spawn_point(index)


func siphon_positions() -> Array[Vector3]:
	return graph.siphon_points


func shaft_position() -> Vector3:
	return graph.shaft_point
