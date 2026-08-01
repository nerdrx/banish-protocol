class_name LayerGraph
extends RefCounted
## Seeded room-and-corridor graph for one security layer. Pure data — no nodes,
## no scene tree, no rendering — so it can be generated and diffed headlessly.
##
## Determinism contract: `generate(run_seed, layer_number)` is a pure function.
## The host rolls one run seed and replicates it (Net._receive_config); every
## peer derives the same per-layer sub-seed and builds byte-identical geometry
## locally. Nothing about the layout ever goes over the wire — and that includes
## M3's furniture: where the shards lie, which rooms the Scrubbers nest in and
## where the Sentinel stands are all resolved here, so the host's spawn packets
## only ever have to say *which* slot woke up, never where it is.
##
## ## Algorithm
##
## 1. **Cell growth.** Rooms are placed on a coarse GRID x GRID lattice of
##    CELL-metre cells. Starting from one random cell we repeatedly pop a random
##    cell off a frontier of orthogonal neighbours until we have `room_count`.
##    Growing by adjacency (rather than scattering rooms and hoping) guarantees
##    the cell-adjacency graph is connected, which guarantees the layer is.
## 2. **Spanning tree.** Randomised Prim over the cell adjacency graph, so every
##    room is reachable. Then 1-2 unused adjacencies are added back as loops, so
##    the layer is not a pure tree and you can be flanked.
## 3. **Archetypes.** BFS depth from the arrival room orders the layer: the
##    deepest room is the drop-shaft trunk, siphon junctions are placed in the
##    next-deepest rooms, one mid room becomes a data vault, the rest are bus
##    halls, and a share of those bus halls are left *unlit* — the nests M3's
##    Scrubbers lurk in. Archetypes are settled before any rect exists because a
##    backdoor layer's shaft room is built to a different size (below).
## 4. **Room rects.** Each cell gets an axis-aligned rect centred on its cell
##    centre with a small jitter. Cell size is chosen so the widest two rooms in
##    adjacent cells still leave a corridor's worth of gap — rooms can never
##    overlap, and corridors are always a single straight segment. On every 5th
##    layer the shaft room is instead built square, tall and much larger: the
##    backdoor node sanctuary.
## 5. **Corridors.** For each edge, the two rooms' facing walls are joined by a
##    corridor whose cross-axis position is chosen inside the overlap of their
##    perpendicular extents, inset far enough that a full-width doorway fits.
##    That position becomes a door in both rooms' walls.
## 6. **Furniture.** Spawns, taps, the shaft, data shards, Scrubber nests and
##    Sentinel posts, all as world-space points.

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

## Half-extent of a backdoor node room, which is built on its cell centre with no
## jitter. 13 + a neighbour's worst case 10.5 = 23.5 < CELL, so the sanctuary is
## nearly three times the floor area of a normal room and still cannot touch
## anything.
const BACKDOOR_HALF: float = 13.0
const BACKDOOR_HEIGHT: float = 8.5

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
const BACKDOOR: String = "backdoor"

# --- salvage ----------------------------------------------------------------

## Shards per room by archetype. The vault is where the haul is; everywhere else
## is loose change, and the sanctuary hands you a parting gift.
const SHARDS_VAULT: Vector2i = Vector2i(8, 12)
const SHARDS_ROOM: Vector2i = Vector2i(0, 3)
const SHARDS_BACKDOOR: Vector2i = Vector2i(2, 3)

# --- output -----------------------------------------------------------------

var layer_number: int = 1
var layer_seed: int = 0
var params: Dictionary = {}
## Every 5th layer: the shaft room is a backdoor node sanctuary.
var is_backdoor: bool = false

## {index, cell:Vector2i, min:Vector2, max:Vector2, h:float, archetype:String,
##  depth:int, unlit:bool, doors:Array[{wall,at}]}. `min`/`max`/`h`/`doors` are
## exactly the shape GeometryKit._build_room() consumes.
var rooms: Array[Dictionary] = []

## {id, a:int, b:int, axis:"x"|"z", min:Vector2, max:Vector2, h:float} —
## the shape GeometryKit._build_corridor() consumes.
var corridors: Array[Dictionary] = []

var arrival_index: int = 0
var shaft_index: int = 0
var vault_index: int = -1
var siphon_rooms: Array[int] = []
## Unlit bus halls. Scrubbers nest here and flee back here when exposed.
var nest_rooms: Array[int] = []

## World-space furniture anchors, resolved once here so the builder, the host's
## muster check and the debug teleports all agree.
var spawns: Array[Vector3] = []
var siphon_points: Array[Vector3] = []
## Where a player stands to reach each tap: one step back toward the room's
## middle, so an automated `--goto siphon` never teleports into a wall.
var siphon_approaches: Array[Vector3] = []
var shaft_point: Vector3 = Vector3.ZERO
## Only meaningful when `is_backdoor`.
var backdoor_point: Vector3 = Vector3.ZERO
var uplink_point: Vector3 = Vector3.ZERO

## Salvage, parallel arrays: shard i sits at `shard_points[i]` in `shard_rooms[i]`.
var shard_points: Array[Vector3] = []
var shard_rooms: Array[int] = []

## Antivirus slots. The host buys from these with the layer's antivirus budget;
## every peer knows them, so a spawn packet is just an index.
var scrubber_nests: Array[Vector3] = []
var scrubber_nest_rooms: Array[int] = []
var sentinel_posts: Array[Vector3] = []
var sentinel_post_rooms: Array[int] = []

var _rng: RandomNumberGenerator = null
var _adjacency: Dictionary = {}  # int -> Array[int]
## Corridor adjacency (loops included) and the first hop of the shortest path
## between every pair of rooms — the whole of M3's antivirus pathing.
var _links: Dictionary = {}      # int -> Array[int]
var _hops: Dictionary = {}       # int * 100 + int -> int
var _hop_counts: Dictionary = {} # int * 100 + int -> int


## Builds the graph for (run_seed, layer_number). Deterministic and total.
static func generate(run_seed: int, layer_number: int) -> LayerGraph:
	var graph: LayerGraph = LayerGraph.new()
	graph._generate(run_seed, layer_number)
	return graph


func _generate(run_seed: int, number: int) -> void:
	layer_number = maxi(number, 1)
	params = LayerParams.of(layer_number)
	is_backdoor = bool(params["has_backdoor"])

	# Derive the per-layer sub-seed from the run seed the host replicated. Rng's
	# own hashing is reused so there is exactly one seed-derivation rule in the
	# codebase, but we do not go through the autoload: a headless determinism
	# dump must be able to generate a layer for an arbitrary seed.
	layer_seed = hash(str(run_seed, ":layer:", layer_number))
	_rng = RandomNumberGenerator.new()
	_rng.seed = layer_seed

	var cells: Array[Vector2i] = _grow_cells(int(params["room_count"]))
	_build_adjacency(cells)
	var edges: Array[Vector2i] = _spanning_tree(cells.size())
	edges.append_array(_extra_loops(edges, cells.size()))
	# Archetypes before rects: a backdoor layer's shaft room is a different size,
	# and the corridors carved in the next step have to meet its real walls.
	var plan: Dictionary = _assign_archetypes(cells.size(), edges)
	_build_rooms(cells, plan)
	_carve_corridors(edges)
	_build_links(edges)
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


func _build_rooms(cells: Array[Vector2i], plan: Dictionary) -> void:
	var heights: Vector2 = params["height_range"]
	var archetypes: Array = plan["archetypes"]
	var unlit: Dictionary = plan["unlit"]
	var depths: Array = plan["depths"]
	# Centre the lattice on the origin so world coordinates stay small and
	# readable in logs regardless of which cells were chosen.
	var offset: float = float(GRID - 1) * CELL * 0.5

	for i: int in cells.size():
		var cell: Vector2i = cells[i]
		# Drawn for every room whatever its archetype, so the stream stays aligned
		# and a backdoor layer's other rooms are the rooms they would have been.
		var jitter: Vector2 = Vector2(
				_rng.randf_range(-JITTER, JITTER), _rng.randf_range(-JITTER, JITTER))
		var half: Vector2 = Vector2(
				_rng.randf_range(MIN_HALF, MAX_HALF),
				_rng.randf_range(MIN_HALF, MAX_HALF))
		var height: float = _rng.randf_range(heights.x, heights.y)

		var archetype: String = String(archetypes[i])
		if archetype == BACKDOOR:
			# The sanctuary is square, centred and tall: it should read as
			# deliberate architecture the moment you step through the door.
			jitter = Vector2.ZERO
			half = Vector2(BACKDOOR_HALF, BACKDOOR_HALF)
			height = BACKDOOR_HEIGHT

		var centre: Vector2 = Vector2(
				float(cell.x) * CELL - offset + jitter.x,
				float(cell.y) * CELL - offset + jitter.y)
		rooms.append({
			"index": i,
			"cell": cell,
			"min": centre - half,
			"max": centre + half,
			"h": height,
			"archetype": archetype,
			"depth": int(depths[i]),
			"unlit": unlit.has(i),
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

## Decides what every room *is* before any of them has a shape. Returns
## {archetypes: Array[String], unlit: Dictionary, depths: Array[int]}.
func _assign_archetypes(count: int, edges: Array[Vector2i]) -> Dictionary:
	var archetypes: Array[String] = []
	archetypes.resize(count)
	archetypes.fill(BUS)

	arrival_index = 0  # cell growth started here, so it is the most central room.
	var depths: Array[int] = _bfs_depths(arrival_index, count, edges)

	# Deepest room is the way down. Ties break on the higher index so the choice
	# never depends on iteration order of anything unordered.
	shaft_index = arrival_index
	for i: int in count:
		if i != arrival_index and depths[i] >= depths[shaft_index]:
			shaft_index = i
	if shaft_index == arrival_index and count > 1:
		shaft_index = count - 1

	archetypes[arrival_index] = ARRIVAL
	# On every 5th layer the trunk room is the backdoor node sanctuary: same drop
	# shaft, wholly different room.
	archetypes[shaft_index] = BACKDOOR if is_backdoor else SHAFT

	# Siphon junctions go in the deepest remaining rooms: refuelling should be a
	# commitment, not something you pass on the way in.
	var free: Array[int] = []
	for i: int in count:
		if i != arrival_index and i != shaft_index:
			free.append(i)
	free.sort_custom(func(x: int, y: int) -> bool:
		if depths[x] != depths[y]:
			return depths[x] > depths[y]
		return x < y)

	var wanted: int = mini(int(params["siphon_count"]), free.size())
	for i: int in wanted:
		archetypes[free[i]] = SIPHON
		siphon_rooms.append(free[i])

	# One data vault, from the shallow end of what is left. M3 posts a Sentinel
	# in it and fills it with shards — this is the room you have to solve.
	if free.size() > wanted:
		vault_index = free[free.size() - 1]
		archetypes[vault_index] = VAULT

	return {
		"archetypes": archetypes,
		"unlit": _choose_unlit(archetypes),
		"depths": depths,
	}


## Rooms left with no fixtures at all. DESIGN.md pillar 2 wants most of a layer
## genuinely dark, and M3 needs somewhere for the Scrubbers to *live*: an unlit
## bus hall is both. Never the arrival room (the crew's one moment of
## orientation) and never the sanctuary.
func _choose_unlit(archetypes: Array[String]) -> Dictionary:
	var candidates: Array[int] = []
	for i: int in archetypes.size():
		if archetypes[i] == BUS:
			candidates.append(i)

	var unlit: Dictionary = {}
	if candidates.is_empty():
		return unlit

	var chance: float = lerpf(0.45, 0.85, float(params["depth"]))
	for i: int in candidates:
		if _rng.randf() < chance:
			unlit[i] = true
	# Always at least one nest, or a shallow layer can roll itself an antivirus
	# with nowhere to hide.
	if unlit.is_empty():
		unlit[candidates[_rng.randi_range(0, candidates.size() - 1)]] = true

	for i: int in unlit.keys():
		nest_rooms.append(int(i))
	nest_rooms.sort()
	return unlit


## Hop count from `root` over the corridor graph (loops included).
func _bfs_depths(root: int, count: int, edges: Array[Vector2i]) -> Array[int]:
	var depths: Array[int] = []
	depths.resize(count)
	depths.fill(-1)
	if count <= 0:
		return depths

	var links: Dictionary = {}
	for i: int in count:
		links[i] = [] as Array[int]
	for edge: Vector2i in edges:
		(links[edge.x] as Array[int]).append(edge.y)
		(links[edge.y] as Array[int]).append(edge.x)

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


# -------------------------------------------------------------------- paths --

## Corridor adjacency plus an all-pairs first-hop table. With ten rooms this is
## a hundred BFS entries computed once at generation time, which is what lets a
## Scrubber re-path every AI tick for free.
func _build_links(edges: Array[Vector2i]) -> void:
	for i: int in rooms.size():
		_links[i] = [] as Array[int]
	for edge: Vector2i in edges:
		(_links[edge.x] as Array[int]).append(edge.y)
		(_links[edge.y] as Array[int]).append(edge.x)

	for root: int in rooms.size():
		var previous: Array[int] = []
		previous.resize(rooms.size())
		previous.fill(-1)
		var distance: Array[int] = []
		distance.resize(rooms.size())
		distance.fill(-1)
		distance[root] = 0
		var queue: Array[int] = [root]
		var head: int = 0
		while head < queue.size():
			var current: int = queue[head]
			head += 1
			for next: int in (_links[current] as Array[int]):
				if distance[next] >= 0:
					continue
				distance[next] = distance[current] + 1
				previous[next] = current
				queue.append(next)

		# Walk each target back to the room next to the root: that is the hop the
		# creature actually takes.
		for target: int in rooms.size():
			if target == root or distance[target] < 0:
				continue
			var step: int = target
			while previous[step] != root and previous[step] >= 0:
				step = previous[step]
			_hops[root * 100 + target] = step
			_hop_counts[root * 100 + target] = distance[target]


## The room a creature standing in `from` should walk into next on its way to
## `to`. Returns -1 when there is no route (or it is already there).
func next_room(from: int, to: int) -> int:
	if from < 0 or to < 0 or from == to:
		return -1
	return int(_hops.get(from * 100 + to, -1))


## Rooms between `from` and `to`, inclusive of neither. Used for the siphon tap's
## alert radius ("converge if you are within N rooms of the junction").
func room_distance(from: int, to: int) -> int:
	if from < 0 or to < 0:
		return 99
	if from == to:
		return 0
	return int(_hop_counts.get(from * 100 + to, 99))


## Centre of the corridor joining two adjacent rooms — the waypoint a creature
## steers at while crossing between them.
func link_point(a: int, b: int) -> Vector3:
	for corridor: Dictionary in corridors:
		var x: int = int(corridor["a"])
		var y: int = int(corridor["b"])
		if (x == a and y == b) or (x == b and y == a):
			var mid: Vector2 = (Vector2(corridor["min"]) + Vector2(corridor["max"])) * 0.5
			return Vector3(mid.x, 0.0, mid.y)
	return centre_of(b)


func centre_of(index: int) -> Vector3:
	if index < 0 or index >= rooms.size():
		return Vector3.ZERO
	var mid: Vector2 = _centre_of(rooms[index])
	return Vector3(mid.x, 0.0, mid.y)


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

	var trunk: Vector2 = _centre_of(rooms[shaft_index])
	if is_backdoor:
		# Three stations in a wide triangle so the sanctuary reads as a room with
		# purposes, not a pad with clutter: shaft north, node east, uplink south.
		shaft_point = Vector3(trunk.x, 0.0, trunk.y - BACKDOOR_HALF * 0.5)
		backdoor_point = Vector3(trunk.x + BACKDOOR_HALF * 0.52, 0.0, trunk.y + 1.0)
		uplink_point = Vector3(trunk.x - 1.0, 0.0, trunk.y + BACKDOOR_HALF * 0.5)
	else:
		shaft_point = Vector3(trunk.x, 0.0, trunk.y)

	_place_shards()
	_place_antivirus_slots()


## Salvage. Vaults are rich, everything else is loose change; the drop-shaft room
## is left empty so nobody is farming the exit.
func _place_shards() -> void:
	for room: Dictionary in rooms:
		var archetype: String = String(room["archetype"])
		var span: Vector2i = SHARDS_ROOM
		match archetype:
			VAULT:
				span = SHARDS_VAULT
			BACKDOOR:
				span = SHARDS_BACKDOOR
			ARRIVAL, SHAFT:
				continue
		var count: int = _rng.randi_range(span.x, span.y)
		for i: int in count:
			shard_points.append(_scatter_point(room, 2.2))
			shard_rooms.append(int(room["index"]))


## One nest anchor per unlit room and one post per vault, both well inside the
## walls. The host buys from these slots with the layer's antivirus budget, so
## the *positions* are seeded content and only the count crosses the wire.
func _place_antivirus_slots() -> void:
	var nests: Array[int] = nest_rooms.duplicate()
	if nests.is_empty():
		# Every room lit — rare, but a layer with no dark room still gets hunters.
		for room: Dictionary in rooms:
			if String(room["archetype"]) == BUS:
				nests.append(int(room["index"]))
	if nests.is_empty():
		nests.append(shaft_index)

	# Three anchors per nest room: a pack scatters rather than stacking in one
	# corner, and the budget can always find somewhere to put a Scrubber.
	for pass_index: int in 3:
		for index: int in nests:
			scrubber_nests.append(_scatter_point(rooms[index], 3.0))
			scrubber_nest_rooms.append(index)

	if vault_index < 0:
		return
	var vault: Dictionary = rooms[vault_index]
	var vault_centre: Vector2 = _centre_of(vault)
	for i: int in 2:
		var side: float = -1.0 if i == 0 else 1.0
		sentinel_posts.append(Vector3(
				vault_centre.x + side * (Vector2(vault["max"]).x - vault_centre.x - 3.5),
				0.0, vault_centre.y))
		sentinel_post_rooms.append(vault_index)


## A point inside a room, `inset` clear of its walls.
func _scatter_point(room: Dictionary, inset: float) -> Vector3:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	return Vector3(
			_rng.randf_range(lo.x + inset, hi.x - inset), 0.0,
			_rng.randf_range(lo.y + inset, hi.y - inset))


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


## Room index for anything standing anywhere, including mid-corridor: a corridor
## resolves to the room it is heading into. Antivirus pathing needs a room for
## every position, not just the ones inside four walls.
func region_of(point: Vector3) -> int:
	var inside: int = room_at(point)
	if inside >= 0:
		return inside

	for corridor: Dictionary in corridors:
		var lo: Vector2 = corridor["min"]
		var hi: Vector2 = corridor["max"]
		if point.x < lo.x - 0.5 or point.x > hi.x + 0.5:
			continue
		if point.z < lo.y - 0.5 or point.z > hi.y + 0.5:
			continue
		var a: int = int(corridor["a"])
		var b: int = int(corridor["b"])
		return a if centre_of(a).distance_squared_to(point) \
				<= centre_of(b).distance_squared_to(point) else b

	# Off the map entirely (a fall, a teleport gone wrong): nearest room centre.
	var best: int = 0
	var best_distance: float = INF
	for i: int in rooms.size():
		var distance: float = centre_of(i).distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


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
## Deliberately includes geometry and every furniture point, not just topology: a
## generator that produced the same rooms in different places — or the same rooms
## with the Sentinel somewhere else — would still desync a crew.
func to_text() -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("NULLVOID LAYER DUMP")
	lines.append("layer=%d sub_seed=%d backdoor=%s" % [
		layer_number, layer_seed, str(is_backdoor)])
	lines.append(LayerParams.describe(layer_number))
	lines.append("rooms=%d corridors=%d" % [rooms.size(), corridors.size()])
	lines.append("arrival=%d shaft=%d vault=%d siphons=%s nests=%s" % [
		arrival_index, shaft_index, vault_index, str(siphon_rooms), str(nest_rooms)])

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

		lines.append("  room %02d cell=(%d,%d) %-8s depth=%d unlit=%d min=(%.3f,%.3f) max=(%.3f,%.3f) h=%.3f doors=[%s]" % [
			int(room["index"]), (room["cell"] as Vector2i).x, (room["cell"] as Vector2i).y,
			String(room["archetype"]), int(room["depth"]), 1 if bool(room["unlit"]) else 0,
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
	if is_backdoor:
		lines.append("  node (%.3f,%.3f,%.3f)" % [
			backdoor_point.x, backdoor_point.y, backdoor_point.z])
		lines.append("  uplink (%.3f,%.3f,%.3f)" % [
			uplink_point.x, uplink_point.y, uplink_point.z])
	for i: int in shard_points.size():
		lines.append("  shard %02d room=%d (%.3f,%.3f,%.3f)" % [
			i, shard_rooms[i], shard_points[i].x, shard_points[i].y, shard_points[i].z])
	for i: int in scrubber_nests.size():
		lines.append("  nest %02d room=%d (%.3f,%.3f,%.3f)" % [
			i, scrubber_nest_rooms[i], scrubber_nests[i].x, scrubber_nests[i].y,
			scrubber_nests[i].z])
	for i: int in sentinel_posts.size():
		lines.append("  post %02d room=%d (%.3f,%.3f,%.3f)" % [
			i, sentinel_post_rooms[i], sentinel_posts[i].x, sentinel_posts[i].y,
			sentinel_posts[i].z])

	return "\n".join(lines)
