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

## How far out of a room's middle a Compiler is pushed. Comfortably clear of the
## siphon room's hero pillar and of the crossing every doorway path uses.
const CENTRE_CLEARANCE: float = 5.0

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

## Compiler terminals (M4). DESIGN.md: "one hidden on every layer, one
## guaranteed per backdoor node". Parallel arrays: compiler i stands at
## `compiler_points[i]` in `compiler_rooms[i]` and stocks up to
## `compiler_tiers[i]`, with `compiler_sanctuary[i]` marking the guaranteed one.
##
## These are **seeded content**, exactly like the shards and the Sentinel posts.
## Nothing about a Compiler crosses the wire — the host and every client resolve
## the same terminal in the same corner from (run_seed, layer), which is what lets
## a purchase RPC carry an index instead of a position and lets the host check
## that a buyer is genuinely stood at the machine they claim to be using.
var compiler_points: Array[Vector3] = []
var compiler_rooms: Array[int] = []
var compiler_tiers: Array[int] = []
var compiler_sanctuary: Array[bool] = []

## Antivirus slots. The host buys from these with the layer's antivirus budget;
## every peer knows them, so a spawn packet is just an index.
var scrubber_nests: Array[Vector3] = []
var scrubber_nest_rooms: Array[int] = []
var sentinel_posts: Array[Vector3] = []
var sentinel_post_rooms: Array[int] = []

## M4.8 functional clutter. Parallel arrays, same contract as the Compilers: all
## of it is **seeded content**, so a rewire packet carries a mode and a weld
## packet carries an index, and the host has its own copy of the exact prop the
## client says it is standing at.
##
## Wall-mounted props (junctions, vents, cabinets, terminals) store the point on
## the **graph** rect's wall plus which side it is. The builder projects that onto
## the snapped shell it actually built — see ProcLayerBuilder._wall_prop. Storing
## the graph-space anchor is what keeps `--dumplayer` a statement about the
## generator rather than about the kit's snapping rules.
var junction_points: Array[Vector3] = []
var junction_sides: Array[int] = []
var junction_rooms: Array[int] = []
## Weldable vent covers. `vent_rooms[i]` is the nest the vent feeds, which is the
## room whose reinforcement trickle welding it shuts down.
var vent_points: Array[Vector3] = []
var vent_sides: Array[int] = []
var vent_rooms: Array[int] = []
var cabinet_points: Array[Vector3] = []
var cabinet_sides: Array[int] = []
var cabinet_rooms: Array[int] = []
## One command terminal per layer. `terminal_room` is -1 when a layer was too
## small to find it a wall (which cannot happen at the shipped room counts, but a
## generator that can fail loudly is better than one that can fail silently).
var terminal_point: Vector3 = Vector3.ZERO
var terminal_side: int = 0
var terminal_room: int = -1
## One sealable bulkhead, always on a **loop** corridor — never on a spanning-tree
## edge, so sealing it can never be the thing that cuts a player off from the
## shaft. `bulkhead_edge` is (-1, -1) on the rare layer with no loops at all.
var bulkhead_point: Vector3 = Vector3.ZERO
var bulkhead_edge: Vector2i = Vector2i(-1, -1)
var bulkhead_axis: String = "x"
## Kickable physics debris: a point and a kind (0 can, 1 rod, 2 plate fragment).
var debris_points: Array[Vector3] = []
var debris_kinds: Array[int] = []

## The adjacencies the spanning tree did NOT use. Everything on one of these has
## an alternative route by construction, which is exactly the property a door the
## player can shut needs to have.
var loop_edges: Array[Vector2i] = []

var _rng: RandomNumberGenerator = null
var _adjacency: Dictionary = {}  # int -> Array[int]
## Corridor adjacency (loops included) and the first hop of the shortest path
## between every pair of rooms — the whole of M3's antivirus pathing.
var _links: Dictionary = {}      # int -> Array[int]
var _hops: Dictionary = {}       # int * 100 + int -> int
var _hop_counts: Dictionary = {} # int * 100 + int -> int
## Edges a sealed bulkhead is currently closing. Not part of generation — it is
## runtime state, replicated as "door N is shut" and applied identically on every
## peer, and `_rebuild_hops` re-solves the routing table around it.
var _blocked: Dictionary = {}


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
	loop_edges = _extra_loops(edges, cells.size())
	edges.append_array(loop_edges)
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
	_rebuild_hops()


## Seals or unseals the corridor between two rooms and re-solves the routing
## table around it (M4.8's bulkhead doors).
##
## Every peer calls this off the same replicated "door N is shut" packet, so all
## four routing tables stay identical — the graph is still a pure function of the
## seed *plus* a replicated set of closed doors, which is the same guarantee with
## one more input.
##
## The rebuild is a hundred BFS entries for a ten-room layer and happens once per
## seal event, so it is cheaper than the alternative (creatures re-deciding at a
## door every tick) by orders of magnitude.
func set_edge_blocked(a: int, b: int, blocked: bool) -> void:
	var key: int = _edge_key(a, b)
	if blocked == _blocked.has(key):
		return
	if blocked:
		_blocked[key] = true
	else:
		_blocked.erase(key)
	_rebuild_hops()


func is_edge_blocked(a: int, b: int) -> bool:
	return _blocked.has(_edge_key(a, b))


## All-pairs first hop over the corridor graph, minus whatever is sealed.
func _rebuild_hops() -> void:
	_hops.clear()
	_hop_counts.clear()
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
				if _blocked.has(_edge_key(current, next)):
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
	# Deliberately last in the stream. Everything above it draws from `_rng` in
	# the order M2 and M3 established, so adding Compilers in M4 appends lines to
	# the determinism dump instead of moving every shard on every layer — the
	# dump for a given (seed, layer) is unchanged above this point.
	_place_compilers()
	# And M4.8 appends after M4, for the same reason and with the same result:
	# every shard, nest, post and Compiler on every saved seed is exactly where it
	# was before the functional clutter existed.
	_place_props()


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


## Compiler terminals. One hidden somewhere on the layer that is not the vault
## (the vault already has a Sentinel and the haul; putting the shop in it would
## make one room the whole layer), plus the guaranteed sanctuary one on every
## backdoor layer.
##
## "Hidden" means it goes in a bus hall or a siphon junction, unlit ones
## included — the Compiler is worth walking into the dark for, and a nest with a
## terminal in it is a genuine argument.
func _place_compilers() -> void:
	var base_tier: int = int(params["compiler_tier"])

	var candidates: Array[int] = []
	for room: Dictionary in rooms:
		var archetype: String = String(room["archetype"])
		if archetype == BUS or archetype == SIPHON:
			candidates.append(int(room["index"]))
	# A tiny layer where every room is spoken for still gets its Compiler; the
	# arrival room is the last resort because it is the one place the crew is
	# guaranteed to stand, and a shop you cannot miss is not hidden.
	if candidates.is_empty():
		for room: Dictionary in rooms:
			if String(room["archetype"]) != VAULT:
				candidates.append(int(room["index"]))
	if not candidates.is_empty():
		var pick: int = candidates[_rng.randi_range(0, candidates.size() - 1)]
		compiler_points.append(_clear_of_centre(rooms[pick], _scatter_point(rooms[pick], 3.4)))
		compiler_rooms.append(pick)
		compiler_tiers.append(base_tier)
		compiler_sanctuary.append(false)

	if not is_backdoor:
		return
	# The fourth station in the sanctuary's triangle: shaft north, node east,
	# uplink south, Compiler west. It stocks one tier above its layer, which is
	# the reason to walk to a backdoor room even on a run you are not banking.
	var trunk: Vector2 = _centre_of(rooms[shaft_index])
	compiler_points.append(Vector3(trunk.x - BACKDOOR_HALF * 0.52, 0.0, trunk.y + 1.0))
	compiler_rooms.append(shaft_index)
	compiler_tiers.append(mini(base_tier + Balance.COMPILER_SANCTUARY_BONUS,
			Balance.MODULE_MAX_TIER))
	compiler_sanctuary.append(true)


# ----------------------------------------------------- M4.8 functional clutter --
#
# Five families of prop, all placed here rather than in the builder, all appended
# to the end of the RNG stream. Two things drive every decision below:
#
#   **Nothing may block a route.** Wall props stand on walls, clear of every
#   doorway by DOOR_CLEAR; debris is scattered like the loose data blocks are,
#   pushed out of the room's central crossing; and the one prop that genuinely
#   closes a corridor is only ever allowed on a loop edge.
#
#   **Every prop is reachable and usable alone.** There is no two-agent lever in
#   this milestone and there is not going to be one — DESIGN.md's solo invariant
#   is a design law, and the place it would be broken is exactly here, in a set
#   of props that would be *so* satisfying to make co-operative.

## How many of each. Ranges rather than fixed counts, so two layers at the same
## depth still feel hand-dressed.
const JUNCTIONS: Vector2i = Vector2i(1, 2)
const VENTS: Vector2i = Vector2i(2, 4)
const CABINETS: Vector2i = Vector2i(1, 3)
const DEBRIS: Vector2i = Vector2i(6, 10)

## Clearance a wall prop keeps from a doorway centre. Half a door (1.6) plus a
## body's width, so you can never end up welding a vent from inside a corridor.
const PROP_DOOR_CLEAR: float = 3.4
## And from a room corner, where the kit stands a rib column.
const PROP_CORNER_INSET: float = 3.0
## Tries before a wall prop gives up on a wall. Every attempt draws from `_rng`,
## so the count is deterministic even though the outcome branches.
const PROP_WALL_TRIES: int = 6


## Wall-facing yaw in radians for a side (0=north/-Z, 1=east/+X, 2=south/+Z,
## 3=west/-X). Matches GeometryKit's wall-slot convention exactly, so a prop and
## the module behind it always agree which way is into the room.
static func wall_yaw(side: int) -> float:
	match side:
		0:
			return 0.0
		1:
			return -PI * 0.5
		2:
			return PI
		_:
			return PI * 0.5


## Inward normal of a wall side.
static func wall_normal(side: int) -> Vector3:
	var yaw: float = wall_yaw(side)
	return Vector3(sin(yaw), 0.0, cos(yaw))


## A point on one of `room`'s walls with nothing in the way, or ZERO if this wall
## has no room for a prop. `side` is the caller's; the doorway and corner
## clearances are this function's.
func _wall_prop_point(room: Dictionary, side: int) -> Vector3:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	var doors: Array = room.get("doors", []) as Array
	var wall: String = "n" if side == 0 else ("e" if side == 1 else
			("s" if side == 2 else "w"))
	var horizontal: bool = side % 2 == 0
	var from: float = (lo.x if horizontal else lo.y) + PROP_CORNER_INSET
	var to: float = (hi.x if horizontal else hi.y) - PROP_CORNER_INSET
	if to <= from:
		return Vector3.ZERO
	var fixed: float = lo.y if side == 0 else (
			hi.x if side == 1 else (hi.y if side == 2 else lo.x))

	for _attempt: int in PROP_WALL_TRIES:
		var t: float = _rng.randf_range(from, to)
		var clear: bool = true
		for door: Dictionary in doors:
			if String(door.get("wall", "")) != wall:
				continue
			if absf(float(door.get("at", 0.0)) - t) < PROP_DOOR_CLEAR:
				clear = false
				break
		if not clear:
			continue
		return Vector3(t, 0.0, fixed) if horizontal else Vector3(fixed, 0.0, t)
	return Vector3.ZERO


## Mounts one wall prop somewhere on `room`, trying each wall in a rolled order.
## Returns {ok, point, side}.
func _mount_wall_prop(room: Dictionary) -> Dictionary:
	var first: int = _rng.randi_range(0, 3)
	for step: int in 4:
		var side: int = (first + step) % 4
		var point: Vector3 = _wall_prop_point(room, side)
		if not point.is_equal_approx(Vector3.ZERO):
			return {"ok": true, "point": point, "side": side}
	return {"ok": false, "point": Vector3.ZERO, "side": 0}


func _place_props() -> void:
	# --- rewire junctions --------------------------------------------------
	#
	# Anywhere but the sanctuary and the trunk. The junction is a decision you
	# make about the layer you are still in, so putting one in the room you leave
	# from would be putting it after the decision.
	var general: Array[int] = []
	for room: Dictionary in rooms:
		var archetype: String = String(room["archetype"])
		if archetype == SHAFT or archetype == BACKDOOR:
			continue
		general.append(int(room["index"]))
	if general.is_empty():
		general.append(arrival_index)

	var wanted_junctions: int = mini(
			_rng.randi_range(JUNCTIONS.x, JUNCTIONS.y), general.size())
	var junction_pool: Array[int] = general.duplicate()
	for _i: int in wanted_junctions:
		if junction_pool.is_empty():
			break
		var pick: int = _rng.randi_range(0, junction_pool.size() - 1)
		var index: int = junction_pool[pick]
		junction_pool.remove_at(pick)
		var mount: Dictionary = _mount_wall_prop(rooms[index])
		if not bool(mount["ok"]):
			continue
		junction_points.append(mount["point"])
		junction_sides.append(int(mount["side"]))
		junction_rooms.append(index)

	# --- weldable vent covers ----------------------------------------------
	#
	# On the walls of the nests, because a vent is where the cleaners come in and
	# the nest is where they live. A layer with one nest gets several vents on it;
	# a layer with four gets one each. Either way the crew can shut a nest down.
	var nests: Array[int] = nest_rooms.duplicate()
	if nests.is_empty():
		nests.append(shaft_index if vault_index < 0 else vault_index)
	var wanted_vents: int = _rng.randi_range(VENTS.x, VENTS.y)
	for i: int in wanted_vents:
		var index: int = nests[i % nests.size()]
		var mount: Dictionary = _mount_wall_prop(rooms[index])
		if not bool(mount["ok"]):
			continue
		vent_points.append(mount["point"])
		vent_sides.append(int(mount["side"]))
		vent_rooms.append(index)

	# --- lootable cabinets --------------------------------------------------
	var wanted_cabinets: int = mini(
			_rng.randi_range(CABINETS.x, CABINETS.y), general.size())
	var cabinet_pool: Array[int] = general.duplicate()
	for _i: int in wanted_cabinets:
		if cabinet_pool.is_empty():
			break
		var pick: int = _rng.randi_range(0, cabinet_pool.size() - 1)
		var index: int = cabinet_pool[pick]
		cabinet_pool.remove_at(pick)
		var mount: Dictionary = _mount_wall_prop(rooms[index])
		if not bool(mount["ok"]):
			continue
		cabinet_points.append(mount["point"])
		cabinet_sides.append(int(mount["side"]))
		cabinet_rooms.append(index)

	# --- the command terminal ----------------------------------------------
	#
	# In a LIT room, and never in the vault. This is the one prop the player
	# stands at with their back to the room for several seconds at a time, and
	# putting it in a nest would not be tense, it would be a tax.
	var console_rooms: Array[int] = []
	for room: Dictionary in rooms:
		var archetype: String = String(room["archetype"])
		if archetype == SHAFT or archetype == BACKDOOR or archetype == VAULT:
			continue
		if bool(room["unlit"]):
			continue
		console_rooms.append(int(room["index"]))
	if console_rooms.is_empty():
		console_rooms.append(arrival_index)
	var console: int = console_rooms[_rng.randi_range(0, console_rooms.size() - 1)]
	var console_mount: Dictionary = _mount_wall_prop(rooms[console])
	if bool(console_mount["ok"]):
		terminal_point = console_mount["point"]
		terminal_side = int(console_mount["side"])
		terminal_room = console

	# --- the bulkhead -------------------------------------------------------
	#
	# Loop edges only, and the reason is a design law rather than a preference:
	# a door on a spanning-tree edge is a door that can cut a player off from the
	# drop shaft, and a prop that can end a run by being used correctly is not
	# shippable. On a loop edge the worst case is a longer walk.
	if not loop_edges.is_empty():
		var edge: Vector2i = loop_edges[_rng.randi_range(0, loop_edges.size() - 1)]
		for corridor: Dictionary in corridors:
			var a: int = int(corridor["a"])
			var b: int = int(corridor["b"])
			if (a != edge.x or b != edge.y) and (a != edge.y or b != edge.x):
				continue
			var mid: Vector2 = (Vector2(corridor["min"]) + Vector2(corridor["max"])) * 0.5
			bulkhead_point = Vector3(mid.x, 0.0, mid.y)
			bulkhead_edge = Vector2i(a, b)
			bulkhead_axis = String(corridor["axis"])
			break

	# --- physics debris -----------------------------------------------------
	#
	# Six to ten pieces on the whole layer. That number is a performance budget as
	# much as an art one: every one of these is a live RigidBody3D in the
	# broadphase, and a layer with fifty of them is a layer that stutters when a
	# player walks through a doorway.
	# Never in the sanctuary and never in the trunk room. The sanctuary is the
	# crew's one safe place and a can rolling across it is a jump scare with no
	# author; the trunk room is where the whole crew stands still for three
	# seconds to muster, and a rigid body underfoot there is a descent channel
	# that keeps breaking for reasons nobody can see.
	var floor_rooms: Array[int] = []
	for room: Dictionary in rooms:
		var archetype: String = String(room["archetype"])
		if archetype != BACKDOOR and archetype != SHAFT:
			floor_rooms.append(int(room["index"]))
	if floor_rooms.is_empty():
		floor_rooms.append(arrival_index)
	var wanted_debris: int = _rng.randi_range(DEBRIS.x, DEBRIS.y)
	for _i: int in wanted_debris:
		var index: int = floor_rooms[_rng.randi_range(0, floor_rooms.size() - 1)]
		debris_points.append(_clear_of_centre(rooms[index],
				_scatter_point(rooms[index], 3.0)))
		debris_kinds.append(_rng.randi_range(0, 2))


# ---------------------------------------------------------------- room names --

## Prefix per archetype. Short, all-caps, and readable as a place rather than as
## a category — a terminal answering "VAULT-7C" is naming a room, not describing
## a data structure.
const ROOM_PREFIX: Dictionary = {
	ARRIVAL: "GATE",
	SIPHON: "SIPH",
	VAULT: "VAULT",
	BUS: "BUS",
	SHAFT: "TRUNK",
	BACKDOOR: "NODE",
}


## MOTHER's own name for a room, e.g. `BUS-7C`. Deterministic by construction —
## it is a pure function of the archetype, the layer number and the room index —
## so the command terminal, the wayfinding it prints and any future system that
## has to say where something is all use the same word for the same place.
##
## An unlit bus hall is a NEST regardless of what the archetype table says. The
## crew learns that word fast, and it is worth a terminal being willing to say it.
func room_name(index: int) -> String:
	if index < 0 or index >= rooms.size():
		return "UNMAPPED"
	var room: Dictionary = rooms[index]
	var archetype: String = String(room["archetype"])
	var prefix: String = String(ROOM_PREFIX.get(archetype, "BUS"))
	if archetype == BUS and bool(room["unlit"]):
		prefix = "NEST"
	# A..Z then wraps; layers cap at ten rooms, so it never does.
	return "%s-%d%s" % [prefix, layer_number,
			char(65 + (index % 26))]


## The room whose name is `name`, or -1. What `QUERY <ROOM>` resolves against.
func room_by_name(wanted: String) -> int:
	var needle: String = wanted.strip_edges().to_upper()
	for i: int in rooms.size():
		if room_name(i) == needle:
			return i
	return -1


## Pushes a point out of a room's central crossing, the same rule the loose
## furniture follows. A siphon junction stands its hero conduit trunk on the room
## centre and every room's doorway-to-doorway path runs through it, so a Compiler
## that rolled the middle would be standing inside the plumbing.
func _clear_of_centre(room: Dictionary, point: Vector3) -> Vector3:
	var centre: Vector2 = _centre_of(room)
	var away: Vector2 = Vector2(point.x - centre.x, point.z - centre.y)
	if away.length() >= CENTRE_CLEARANCE:
		return point
	if away.length_squared() < 0.01:
		away = Vector2(1.0, 0.0)
	var pushed: Vector2 = centre + away.normalized() * CENTRE_CLEARANCE
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	return Vector3(clampf(pushed.x, lo.x + 3.0, hi.x - 3.0), 0.0,
			clampf(pushed.y, lo.y + 3.0, hi.y - 3.0))


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
	lines.append("LIMBO PROTOCOL LAYER DUMP")
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
	for i: int in compiler_points.size():
		lines.append("  compiler %02d room=%d tier=%d sanctuary=%d (%.3f,%.3f,%.3f)" % [
			i, compiler_rooms[i], compiler_tiers[i],
			1 if compiler_sanctuary[i] else 0,
			compiler_points[i].x, compiler_points[i].y, compiler_points[i].z])

	# --- M4.8 ---------------------------------------------------------------
	#
	# Every functional prop, in the dump, for the same reason the Sentinel posts
	# are: two peers that disagree about which wall a vent is on disagree about
	# what a weld packet means. `side` is in here as well as the point because the
	# builder projects the point onto the snapped shell and the side is what tells
	# it which way to project.
	for i: int in junction_points.size():
		lines.append("  junction %02d room=%d side=%d (%.3f,%.3f,%.3f)" % [
			i, junction_rooms[i], junction_sides[i],
			junction_points[i].x, junction_points[i].y, junction_points[i].z])
	for i: int in vent_points.size():
		lines.append("  vent %02d room=%d side=%d (%.3f,%.3f,%.3f)" % [
			i, vent_rooms[i], vent_sides[i],
			vent_points[i].x, vent_points[i].y, vent_points[i].z])
	for i: int in cabinet_points.size():
		lines.append("  cabinet %02d room=%d side=%d (%.3f,%.3f,%.3f)" % [
			i, cabinet_rooms[i], cabinet_sides[i],
			cabinet_points[i].x, cabinet_points[i].y, cabinet_points[i].z])
	lines.append("  terminal room=%d side=%d (%.3f,%.3f,%.3f)" % [
		terminal_room, terminal_side,
		terminal_point.x, terminal_point.y, terminal_point.z])
	lines.append("  bulkhead edge=(%d,%d) axis=%s (%.3f,%.3f,%.3f)" % [
		bulkhead_edge.x, bulkhead_edge.y, bulkhead_axis,
		bulkhead_point.x, bulkhead_point.y, bulkhead_point.z])
	for i: int in debris_points.size():
		lines.append("  debris %02d kind=%d (%.3f,%.3f,%.3f)" % [
			i, debris_kinds[i],
			debris_points[i].x, debris_points[i].y, debris_points[i].z])
	# Room names last: they are derived rather than rolled, but a dump that prints
	# them is a dump that catches a rename breaking every terminal answer.
	var names: PackedStringArray = PackedStringArray()
	for i: int in rooms.size():
		names.append(room_name(i))
	lines.append("  names %s" % " ".join(names))

	return "\n".join(lines)
