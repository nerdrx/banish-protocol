class_name LayerGraph
extends RefCounted
## Seeded room-and-corridor graph for one security layer. Pure data — no nodes,
## no scene tree, no rendering — so it can be generated and diffed headlessly.
##
## Determinism contract: `generate(run_seed, layer_number)` is a pure function.
## The host rolls one run seed and replicates it (Net._receive_config); every
## peer derives the same per-layer sub-seed and builds byte-identical geometry
## locally. Nothing about the layout ever goes over the wire.
##
## ## Algorithm
##
## 1. **Cell growth.** Rooms are placed on a coarse GRID x GRID lattice of
##    CELL-metre cells. Starting from one random cell we repeatedly pop a random
##    cell off a frontier of orthogonal neighbours until we have `room_count`.
##    Growing by adjacency (rather than scattering rooms and hoping) guarantees
##    the cell-adjacency graph is connected, which guarantees the layer is.
## 2. **Room rects.** Each cell gets an axis-aligned rect centred on its cell
##    centre with a small jitter. Cell size is chosen so the widest two rooms in
##    adjacent cells still leave a corridor's worth of gap — rooms can never
##    overlap, and corridors are always a single straight segment.
## 3. **Spanning tree.** Randomised Prim over the cell adjacency graph, so every
##    room is reachable. Then 1-2 unused adjacencies are added back as loops, so
##    the layer is not a pure tree and you can be flanked.
## 4. **Corridors.** For each edge, the two rooms' facing walls are joined by a
##    corridor whose cross-axis position is chosen inside the overlap of their
##    perpendicular extents, inset far enough that a full-width doorway fits.
##    That position becomes a door in both rooms' walls.
## 5. **Archetypes.** BFS depth from the arrival room orders the layer: the
##    deepest room is the drop-shaft trunk, siphon junctions are placed in the
##    next-deepest rooms, one mid room becomes a data vault, the rest are bus
##    halls.

# --- lattice ----------------------------------------------------------------

## Cell pitch. Must exceed 2 * (MAX_HALF + JITTER) by a comfortable corridor
## length, or adjacent rooms would touch.
const CELL: float = 34.0
const GRID: int = 4

const MIN_HALF: float = 5.5
const MAX_HALF: float = 9.0
## Room centres wander this far off their cell centre. Bounded so the
## perpendicular overlap of two adjacent rooms is always wide enough for a door.
const JITTER: float = 1.5

const CORRIDOR_HALF_WIDTH: float = 1.8
const CORRIDOR_HEIGHT: float = 3.4

## Clearance a doorway needs from a room corner: half a door plus a margin so the
## opening never eats the wall's end.
const DOOR_MARGIN: float = 2.4

const EXTRA_LOOPS_MIN: int = 1
const EXTRA_LOOPS_MAX: int = 2

# --- archetypes -------------------------------------------------------------

const ARRIVAL: String = "arrival"
const SIPHON: String = "siphon"
const VAULT: String = "vault"
const BUS: String = "bus"
const SHAFT: String = "shaft"

# --- output -----------------------------------------------------------------

var layer_number: int = 1
var layer_seed: int = 0
var params: Dictionary = {}

## {index, cell:Vector2i, min:Vector2, max:Vector2, h:float, archetype:String,
##  depth:int, doors:Array[{wall,at}]}. `min`/`max`/`h`/`doors` are exactly the
## shape GeometryKit._build_room() consumes.
var rooms: Array[Dictionary] = []

## {id, a:int, b:int, axis:"x"|"z", min:Vector2, max:Vector2, h:float} —
## the shape GeometryKit._build_corridor() consumes.
var corridors: Array[Dictionary] = []

var arrival_index: int = 0
var shaft_index: int = 0
var siphon_rooms: Array[int] = []

## World-space furniture anchors, resolved once here so the builder, the host's
## muster check and the debug teleports all agree.
var spawns: Array[Vector3] = []
var siphon_points: Array[Vector3] = []
## Where a player stands to reach each tap: one step back toward the room's
## middle, so an automated `--goto siphon` never teleports into a wall.
var siphon_approaches: Array[Vector3] = []
var shaft_point: Vector3 = Vector3.ZERO

var _rng: RandomNumberGenerator = null
var _adjacency: Dictionary = {}  # int -> Array[int]


## Builds the graph for (run_seed, layer_number). Deterministic and total.
static func generate(run_seed: int, layer_number: int) -> LayerGraph:
	var graph: LayerGraph = LayerGraph.new()
	graph._generate(run_seed, layer_number)
	return graph


func _generate(run_seed: int, number: int) -> void:
	layer_number = maxi(number, 1)
	params = LayerParams.of(layer_number)

	# Derive the per-layer sub-seed from the run seed the host replicated. Rng's
	# own hashing is reused so there is exactly one seed-derivation rule in the
	# codebase, but we do not go through the autoload: a headless determinism
	# dump must be able to generate a layer for an arbitrary seed.
	layer_seed = hash(str(run_seed, ":layer:", layer_number))
	_rng = RandomNumberGenerator.new()
	_rng.seed = layer_seed

	var cells: Array[Vector2i] = _grow_cells(int(params["room_count"]))
	_build_rooms(cells)
	_build_adjacency(cells)
	var edges: Array[Vector2i] = _spanning_tree(cells.size())
	edges.append_array(_extra_loops(edges, cells.size()))
	_carve_corridors(edges)
	_assign_archetypes()
	_place_furniture()


# ------------------------------------------------------------------- lattice --

## Random walk outward from a seed cell, so the chosen set is always contiguous.
func _grow_cells(count: int) -> Array[Vector2i]:
	var start: Vector2i = Vector2i(_rng.randi_range(0, GRID - 1), _rng.randi_range(0, GRID - 1))
	var chosen: Array[Vector2i] = [start]
	var taken: Dictionary = {start: true}
	var frontier: Array[Vector2i] = _neighbours(start, taken)

	while chosen.size() < count and not frontier.is_empty():
		var pick: int = _rng.randi_range(0, frontier.size() - 1)
		var cell: Vector2i = frontier[pick]
		frontier.remove_at(pick)
		if taken.has(cell):
			continue
		taken[cell] = true
		chosen.append(cell)
		for neighbour: Vector2i in _neighbours(cell, taken):
			if not frontier.has(neighbour):
				frontier.append(neighbour)

	return chosen


## In-bounds orthogonal neighbours not already claimed. Fixed order, so the
## frontier is a deterministic function of the sequence of picks.
func _neighbours(cell: Vector2i, taken: Dictionary) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var next: Vector2i = cell + step
		if next.x < 0 or next.y < 0 or next.x >= GRID or next.y >= GRID:
			continue
		if taken.has(next):
			continue
		result.append(next)
	return result


func _build_rooms(cells: Array[Vector2i]) -> void:
	var heights: Vector2 = params["height_range"]
	# Centre the lattice on the origin so world coordinates stay small and
	# readable in logs regardless of which cells were chosen.
	var offset: float = float(GRID - 1) * CELL * 0.5

	for i: int in cells.size():
		var cell: Vector2i = cells[i]
		var centre: Vector2 = Vector2(
				float(cell.x) * CELL - offset + _rng.randf_range(-JITTER, JITTER),
				float(cell.y) * CELL - offset + _rng.randf_range(-JITTER, JITTER))
		var half: Vector2 = Vector2(
				_rng.randf_range(MIN_HALF, MAX_HALF),
				_rng.randf_range(MIN_HALF, MAX_HALF))
		rooms.append({
			"index": i,
			"cell": cell,
			"min": centre - half,
			"max": centre + half,
			"h": _rng.randf_range(heights.x, heights.y),
			"archetype": BUS,
			"depth": 0,
			"doors": [],
		})


func _build_adjacency(cells: Array[Vector2i]) -> void:
	var lookup: Dictionary = {}
	for i: int in cells.size():
		lookup[cells[i]] = i
		_adjacency[i] = [] as Array[int]

	for i: int in cells.size():
		for step: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			var other: Vector2i = cells[i] + step
			if not lookup.has(other):
				continue
			var j: int = int(lookup[other])
			(_adjacency[i] as Array[int]).append(j)
			(_adjacency[j] as Array[int]).append(i)


# ------------------------------------------------------------------ topology --

## Randomised Prim: grow a connected set one random frontier edge at a time.
## Cheaper than Kruskal here (no union-find) and the randomness is already
## bounded by the seeded RNG.
func _spanning_tree(count: int) -> Array[Vector2i]:
	var edges: Array[Vector2i] = []
	if count <= 1:
		return edges

	var inside: Dictionary = {0: true}
	while inside.size() < count:
		var candidates: Array[Vector2i] = []
		for a: int in inside.keys():
			for b: int in (_adjacency[a] as Array[int]):
				if not inside.has(b):
					candidates.append(Vector2i(a, b))
		if candidates.is_empty():
			break  # unreachable by construction; a disconnected layer is not shippable.
		candidates.sort_custom(_edge_before)
		var edge: Vector2i = candidates[_rng.randi_range(0, candidates.size() - 1)]
		inside[edge.y] = true
		edges.append(edge)
	return edges


## Total order on edges so the candidate list is stable before the RNG picks from
## it. Dictionary key order is an implementation detail; determinism cannot rest
## on it.
static func _edge_before(a: Vector2i, b: Vector2i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	return a.y < b.y


## 1-2 adjacencies the tree did not use, so the layer has loops. A pure tree
## means every retreat is back the way you came, which reads as a maze rather
## than a building.
func _extra_loops(tree: Array[Vector2i], count: int) -> Array[Vector2i]:
	var used: Dictionary = {}
	for edge: Vector2i in tree:
		used[_edge_key(edge.x, edge.y)] = true

	var spare: Array[Vector2i] = []
	for a: int in count:
		for b: int in (_adjacency[a] as Array[int]):
			if a >= b:
				continue
			if used.has(_edge_key(a, b)):
				continue
			spare.append(Vector2i(a, b))
	spare.sort_custom(_edge_before)

	var wanted: int = _rng.randi_range(EXTRA_LOOPS_MIN, EXTRA_LOOPS_MAX)
	var extra: Array[Vector2i] = []
	while extra.size() < wanted and not spare.is_empty():
		var pick: int = _rng.randi_range(0, spare.size() - 1)
		extra.append(spare[pick])
		spare.remove_at(pick)
	return extra


static func _edge_key(a: int, b: int) -> int:
	return mini(a, b) * 1000 + maxi(a, b)


# ----------------------------------------------------------------- corridors --

func _carve_corridors(edges: Array[Vector2i]) -> void:
	for edge: Vector2i in edges:
		var a: Dictionary = rooms[edge.x]
		var b: Dictionary = rooms[edge.y]
		var cell_a: Vector2i = a["cell"]
		var cell_b: Vector2i = b["cell"]
		if cell_a.y == cell_b.y:
			_corridor_x(a, b)
		else:
			_corridor_z(a, b)


## East-west corridor. `at` is the shared Z centreline, chosen inside the two
## rooms' overlapping Z extents so both doorways clear their corners.
func _corridor_x(a: Dictionary, b: Dictionary) -> void:
	var left: Dictionary = a
	var right: Dictionary = b
	if (Vector2(left["min"]).x) > (Vector2(right["min"]).x):
		left = b
		right = a

	var at: float = _overlap_point(
			maxf(Vector2(left["min"]).y, Vector2(right["min"]).y),
			minf(Vector2(left["max"]).y, Vector2(right["max"]).y))

	(left["doors"] as Array).append({"wall": "e", "at": at})
	(right["doors"] as Array).append({"wall": "w", "at": at})

	corridors.append({
		"id": "x%d_%d" % [int(left["index"]), int(right["index"])],
		"a": int(left["index"]), "b": int(right["index"]), "axis": "x",
		"min": Vector2(Vector2(left["max"]).x, at - CORRIDOR_HALF_WIDTH),
		"max": Vector2(Vector2(right["min"]).x, at + CORRIDOR_HALF_WIDTH),
		"h": CORRIDOR_HEIGHT,
	})


## North-south corridor. Walls are named for the axis they face: "n" is the -Z
## side, "s" the +Z side (GeometryKit's convention).
func _corridor_z(a: Dictionary, b: Dictionary) -> void:
	var north: Dictionary = a
	var south: Dictionary = b
	if (Vector2(north["min"]).y) > (Vector2(south["min"]).y):
		north = b
		south = a

	var at: float = _overlap_point(
			maxf(Vector2(north["min"]).x, Vector2(south["min"]).x),
			minf(Vector2(north["max"]).x, Vector2(south["max"]).x))

	(north["doors"] as Array).append({"wall": "s", "at": at})
	(south["doors"] as Array).append({"wall": "n", "at": at})

	corridors.append({
		"id": "z%d_%d" % [int(north["index"]), int(south["index"])],
		"a": int(north["index"]), "b": int(south["index"]), "axis": "z",
		"min": Vector2(at - CORRIDOR_HALF_WIDTH, Vector2(north["max"]).y),
		"max": Vector2(at + CORRIDOR_HALF_WIDTH, Vector2(south["min"]).y),
		"h": CORRIDOR_HEIGHT,
	})


## A point inside [lo, hi] with door clearance at both ends. The lattice
## guarantees the raw overlap is at least 8 m, so the inset interval is never
## empty in practice; the midpoint fallback exists so a future tuning pass that
## widens doors or narrows rooms degrades instead of producing a wall-piercing
## doorway.
func _overlap_point(lo: float, hi: float) -> float:
	var inner_lo: float = lo + DOOR_MARGIN
	var inner_hi: float = hi - DOOR_MARGIN
	if inner_hi <= inner_lo:
		return (lo + hi) * 0.5
	return _rng.randf_range(inner_lo, inner_hi)


# ---------------------------------------------------------------- archetypes --

func _assign_archetypes() -> void:
	arrival_index = 0  # cell growth started here, so it is the most central room.
	var depths: Array[int] = _bfs_depths(arrival_index)
	for i: int in rooms.size():
		rooms[i]["depth"] = depths[i]

	# Deepest room is the way down. Ties break on the higher index so the choice
	# never depends on iteration order of anything unordered.
	shaft_index = arrival_index
	for i: int in rooms.size():
		if i != arrival_index and depths[i] >= depths[shaft_index]:
			shaft_index = i
	if shaft_index == arrival_index and rooms.size() > 1:
		shaft_index = rooms.size() - 1

	rooms[arrival_index]["archetype"] = ARRIVAL
	rooms[shaft_index]["archetype"] = SHAFT

	# Siphon junctions go in the deepest remaining rooms: refuelling should be a
	# commitment, not something you pass on the way in.
	var free: Array[int] = []
	for i: int in rooms.size():
		if i != arrival_index and i != shaft_index:
			free.append(i)
	free.sort_custom(func(x: int, y: int) -> bool:
		if depths[x] != depths[y]:
			return depths[x] > depths[y]
		return x < y)

	var wanted: int = mini(int(params["siphon_count"]), free.size())
	for i: int in wanted:
		rooms[free[i]]["archetype"] = SIPHON
		siphon_rooms.append(free[i])

	# One data vault, from the shallow end of what is left. Locked flavour only
	# in M2 (DESIGN.md puts the Sentinel that guards it in M3).
	if free.size() > wanted:
		rooms[free[free.size() - 1]]["archetype"] = VAULT


## Hop count from `root` over the corridor graph.
func _bfs_depths(root: int) -> Array[int]:
	var depths: Array[int] = []
	depths.resize(rooms.size())
	depths.fill(-1)
	if rooms.is_empty():
		return depths

	# Corridor adjacency, not cell adjacency: loops added after the tree count.
	var links: Dictionary = {}
	for i: int in rooms.size():
		links[i] = [] as Array[int]
	for corridor: Dictionary in corridors:
		(links[int(corridor["a"])] as Array[int]).append(int(corridor["b"]))
		(links[int(corridor["b"])] as Array[int]).append(int(corridor["a"]))

	depths[root] = 0
	var queue: Array[int] = [root]
	var head: int = 0
	while head < queue.size():
		var current: int = queue[head]
		head += 1
		for next: int in (links[current] as Array[int]):
			if depths[next] < 0:
				depths[next] = depths[current] + 1
				queue.append(next)

	# Isolated rooms cannot happen (the tree spans every room), but a -1 leaking
	# into the archetype sort would silently pick the wrong drop shaft.
	for i: int in depths.size():
		if depths[i] < 0:
			depths[i] = 0
	return depths


# ------------------------------------------------------------------ fixtures --

func _place_furniture() -> void:
	var arrival: Dictionary = rooms[arrival_index]
	var centre: Vector2 = _centre_of(arrival)
	# Four injection points in a loose square, well inside the walls.
	for offset: Vector2 in [Vector2(-1.6, 1.2), Vector2(1.7, 1.4),
			Vector2(-1.9, -1.5), Vector2(1.5, -1.3)]:
		spawns.append(Vector3(centre.x + offset.x, 0.0, centre.y + offset.y))

	for index: int in siphon_rooms:
		var room: Dictionary = rooms[index]
		var room_centre: Vector2 = _centre_of(room)
		# Offset the tap off-centre so the room still reads as a space you walk
		# through rather than a pedestal in a box.
		var half: Vector2 = (Vector2(room["max"]) - Vector2(room["min"])) * 0.5
		var toward: Vector2 = Vector2(
				_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)).normalized()
		if toward.length_squared() < 0.01:
			toward = Vector2(1.0, 0.0)
		var tap: Vector3 = Vector3(
				room_centre.x + toward.x * (half.x - 3.0),
				0.0,
				room_centre.y + toward.y * (half.y - 3.0))
		siphon_points.append(tap)
		siphon_approaches.append(tap - Vector3(toward.x, 0.0, toward.y) * 3.0)

	shaft_point = Vector3(_centre_of(rooms[shaft_index]).x, 0.0,
			_centre_of(rooms[shaft_index]).y)


static func _centre_of(room: Dictionary) -> Vector2:
	return (Vector2(room["min"]) + Vector2(room["max"])) * 0.5


# -------------------------------------------------------------------- lookup --

func room_at(point: Vector3) -> int:
	for room: Dictionary in rooms:
		var lo: Vector2 = room["min"]
		var hi: Vector2 = room["max"]
		if point.x >= lo.x and point.x <= hi.x and point.z >= lo.y and point.z <= hi.y:
			return int(room["index"])
	return -1


func spawn_point(index: int) -> Transform3D:
	if spawns.is_empty():
		return Transform3D.IDENTITY
	var point: Vector3 = spawns[index % spawns.size()]
	# Face the room's centre, so a fresh layer opens in front of you rather than
	# behind. Godot's -Z forward means the yaw is atan2 of the delta.
	var centre: Vector2 = _centre_of(rooms[arrival_index])
	var look: Vector2 = centre - Vector2(point.x, point.z)
	var yaw: float = 0.0 if look.length_squared() < 0.01 else atan2(-look.x, -look.y)
	return Transform3D(Basis(Vector3.UP, yaw), point)


# ---------------------------------------------------------------------- dump --

## Stable text rendering of the graph, for `--dumplayer` determinism diffing.
## Deliberately includes geometry, not just topology: a generator that produced
## the same rooms in different places would still desync a crew.
func to_text() -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("NULLVOID LAYER DUMP")
	lines.append("layer=%d sub_seed=%d" % [layer_number, layer_seed])
	lines.append(LayerParams.describe(layer_number))
	lines.append("rooms=%d corridors=%d" % [rooms.size(), corridors.size()])
	lines.append("arrival=%d shaft=%d siphons=%s" % [
		arrival_index, shaft_index, str(siphon_rooms)])

	for room: Dictionary in rooms:
		var lo: Vector2 = room["min"]
		var hi: Vector2 = room["max"]
		var doors: Array = room["doors"]
		var door_text: PackedStringArray = PackedStringArray()
		# Doors are appended in corridor order, which is edge order — already
		# deterministic — but sorting makes the dump independent of that too.
		var sorted_doors: Array = doors.duplicate()
		sorted_doors.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
			if String(x["wall"]) != String(y["wall"]):
				return String(x["wall"]) < String(y["wall"])
			return float(x["at"]) < float(y["at"]))
		for door: Dictionary in sorted_doors:
			door_text.append("%s@%.3f" % [String(door["wall"]), float(door["at"])])

		lines.append("  room %02d cell=(%d,%d) %-8s depth=%d min=(%.3f,%.3f) max=(%.3f,%.3f) h=%.3f doors=[%s]" % [
			int(room["index"]), (room["cell"] as Vector2i).x, (room["cell"] as Vector2i).y,
			String(room["archetype"]), int(room["depth"]),
			lo.x, lo.y, hi.x, hi.y, float(room["h"]), ", ".join(door_text)])

	for corridor: Dictionary in corridors:
		var lo2: Vector2 = corridor["min"]
		var hi2: Vector2 = corridor["max"]
		lines.append("  link %02d-%02d axis=%s min=(%.3f,%.3f) max=(%.3f,%.3f)" % [
			int(corridor["a"]), int(corridor["b"]), String(corridor["axis"]),
			lo2.x, lo2.y, hi2.x, hi2.y])

	for i: int in spawns.size():
		lines.append("  spawn %d (%.3f,%.3f,%.3f)" % [i, spawns[i].x, spawns[i].y, spawns[i].z])
	for i: int in siphon_points.size():
		lines.append("  siphon %d room=%d (%.3f,%.3f,%.3f)" % [
			i, siphon_rooms[i], siphon_points[i].x, siphon_points[i].y, siphon_points[i].z])
	lines.append("  shaft (%.3f,%.3f,%.3f)" % [shaft_point.x, shaft_point.y, shaft_point.z])

	return "\n".join(lines)
