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

# --- verticality (M6.6) -----------------------------------------------------
#
# Mirrors of GeometryKit's lattice constants. Deliberately duplicated rather than
# referenced: LayerGraph is pure data with no scene-tree dependency (that is what
# lets `--dumplayer` run before a single node exists), and GeometryKit is a
# Node3D that preloads six materials. A deck has to be expressible in the graph,
# so the graph owns its own copy of the two numbers the lattice is made of.
const KIT_CELL: float = 4.0
const KIT_STOREY: float = 4.0

## Deck kinds — the vertical vocabulary. Every one of them is a *motivated*
## elevation, authored into an archetype because that room has a reason for it:
##   PLINTH     the vault's prize deck. The haul is up on a slab, on purpose.
##   TERRACE    a server-stack / tap-machinery step. Plant sits above the wet
##              floor, which is the reason plant rooms have plinths in real life.
##   MEZZANINE  the machinery hall's service gallery: a walkway at head height
##              over the racks, so somebody can reach the tops of them.
##   CATWALK    maintenance access FROM the mezzanine TO the control platform.
##              It goes somewhere. The motivation law applies to routes.
##   CONTROL    the small overwatch platform the catwalk arrives at.
##   GANTRY     the trunk room's service ring around the drop shaft.
##   PIT        a nest sunk below grade. The cleaners live in the sump.
##   DAIS       the sanctuary's low node step. Ceremonial, safe, readable.
const DECK_PLINTH: String = "plinth"
const DECK_TERRACE: String = "terrace"
const DECK_MEZZANINE: String = "mezzanine"
const DECK_CATWALK: String = "catwalk"
const DECK_CONTROL: String = "control"
const DECK_GANTRY: String = "gantry"
const DECK_PIT: String = "pit"
const DECK_DAIS: String = "dais"

## Link kinds. A RAMP is a plain inclined slab, a STAIR is the same slope dressed
## with treads (one collider either way — see GeometryKit._ramp), and a CATWALK is
## a level span between two decks at the same height.
const LINK_RAMP: String = "ramp"
const LINK_STAIR: String = "stair"
const LINK_CATWALK: String = "catwalk"

## Deck heights. The elevated set sits exactly one kit storey up, so a mezzanine
## floor is the kit's own second course and the wall modules behind it line up.
const Y_MEZZANINE: float = KIT_STOREY
const Y_GANTRY: float = KIT_STOREY
const Y_PLINTH: float = 2.4
const Y_TERRACE: float = 1.6
const Y_DAIS: float = 0.8
const Y_PIT: float = -1.6

## Run lengths, chosen so every slope is walkable by a CharacterBody3D at the
## default 45 degree floor limit and reads as architecture rather than as a wedge:
## 4 m over 8 m is 26.6 degrees (a real building stair is 30-37), 2.4 m over 8 m
## is 16.7, 1.6 m over 4 m is 21.8.
const STAIR_RUN: float = 8.0
const RAMP_RUN_PLINTH: float = 8.0
const RAMP_RUN_LOW: float = 4.0
## Every ramp, stair and catwalk is one kit cell wide. Wide enough for a Sentinel
## (2.6 m) to walk up without catching a shoulder, which is the killability law
## applied to geometry: a perch a player can reach and a Sentinel cannot is a
## camping spot, and camping spots are not shippable.
const DECK_WIDTH: float = KIT_CELL

## Clear width kept for the doorway-to-doorway crossing. Nothing that occupies the
## GROUND volume (a plinth, a terrace, a dais, a sunken pit) may stand in one of
## these strips, which is what keeps the solo invariant intact: spawn -> drop
## shaft stays walkable at grade, with no jump and no climb, on every seed.
const AISLE_HALF: float = 3.6
## And the room's own central crossing, which every doorway path runs through.
##
## Every ground-standing surface in this section — every ramp, every stair, every
## solid deck — is built INSIDE the wall band it belongs to rather than reaching
## out into the room. That is not an aesthetic preference: a ramp laid
## perpendicular to a wall in a 16 m room is a ramp across the middle of the room,
## and the middle of the room is the crossing. Hugging the wall is what lets a
## generated space have real elevation and still guarantee that the floor a player
## walks from the doorway to the drop shaft is untouched.
const CROSSING_HALF: float = 3.2
## Clearance a ground-occupying deck keeps from an already-placed fixture (a
## Sentinel post, a Compiler, a tap, a functional prop). Decks are planned last
## and yield to everything that was there first.
const DECK_FIXTURE_CLEAR: float = 3.2

## A drop-down has to be worth the noise. Below this the ledge is decoration
## rather than a shortcut and no marker is emitted.
const DROP_MIN_HEIGHT: float = 2.0

## Clear grade reserved in front of the first tread of every ground route.
##
## A live playtest found flights whose bottom step was jammed into the wall that
## closes the band they sit in — you could see the stair but not walk onto it
## without sidling along the wall first. The band is cut end to end along a wall,
## so without a reserve the route can start exactly in a room corner.
##
## 2 m rather than the 1.5 m the audit demands, because `_add_link` already pushes
## the `foot` waypoint 1 m up-slope: the reserve has to cover the clearance AND
## that offset, with something left over.
const ROUTE_APPROACH: float = 2.0

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
##
## M4.9 (balance lab): the vault floor rises (8-12 -> 11-16) to absorb the reward
## the Sentinel kill-drop gave up (SENTINEL_DROP_SHARDS 9 -> 5), so clearing a
## vault is worth about what it was but the payout sits on the ROOM not the kill.
## Ordinary rooms floor at 1 (was 0) so a swept room is never a total blank — the
## intricacy law dislikes empty rooms, and a room with nothing to find reads as
## one the generator forgot.
const SHARDS_VAULT: Vector2i = Vector2i(11, 16)
const SHARDS_ROOM: Vector2i = Vector2i(1, 3)
const SHARDS_BACKDOOR: Vector2i = Vector2i(2, 3)
## The drop-shaft room's guaranteed cache. `_place_shards` still skips the SHAFT
## archetype (no farming the exit by rerolling), so this fixed handful is the only
## salvage there — see `_place_shaft_cache`.
const SHARDS_SHAFT_CACHE: int = 2

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

## M6 hunter placement. Seeded content like everything else here, so a
## determinism dump covers it and two peers agree on it before the Director makes
## a single runtime decision — but *whether and when* a hunter appears is the
## Director's host-authoritative call (replicated like the reinforcement trickle),
## not part of generation. These are only the *entry anchors* a directed spawn
## can use (dark rooms, never the sanctuary) and are derived without drawing from
## `_rng`, so adding them cannot move a single shard, nest or post on any existing
## seed — the M5 dump above the hunter lines is byte-for-byte unchanged.
var hunter_nests: Array[Vector3] = []
var hunter_nest_rooms: Array[int] = []

## M6.6 verticality. Walkable surfaces that are not the ground floor, the routes
## that connect them, and the one-way ledges you can leave them by.
##
## **Derived, never rolled.** Every decision below hashes (room centre, layer
## seed) exactly like the architecture decay and the signage do — see `_roll`.
## That is not a stylistic choice: `_rng` is a shared, order-dependent stream, and
## a verticality pass that drew from it would move every shard, nest, post,
## Compiler and prop on every existing seed the moment somebody retuned a ramp
## angle. Hashing means the whole feature is *appended* to the generator: the only
## lines of the M6 dump that move are the room heights of the rooms that earned a
## second storey and the handful of loot points lifted onto a perch.
##
## Deck records: {id, room, kind, min:Vector2, max:Vector2, y, band, solid, loot}.
## `solid` decks occupy the ground volume under them (a plinth is a block you walk
## around); elevated decks stand on columns and the floor passes underneath, which
## is why only the solid ones have to respect the doorway aisles.
var decks: Array[Dictionary] = []
## Routes between decks: {room, a, b, kind, min, max, axis, dir, y0, y1, foot, head}.
## `a` is the LOWER end (-1 means the room's ground floor), `b` the upper. Both
## directions are walkable — a link is a route, not a one-way.
var deck_links: Array[Dictionary] = []
## One-way ledges: {room, deck, at:Vector3, to:Vector3, height, dir:Vector3}. A
## player can step off; nothing hostile is routed through one (see
## `Antivirus._route_to` — a drop is not in the deck graph at all).
var deck_drops: Array[Dictionary] = []
## Loot the room asks you to climb for: {point, room, deck, kind}. `kind` is
## "shard" or "siphon". NEVER on the critical path — see `_plan_decks`.
var perch_points: Array[Vector3] = []
var perch_decks: Array[int] = []
## Per-room storey count, settled in `_build_rooms` and re-read by the builder.
## A mezzanine needs two courses of wall to hang off; the trunk room wants three,
## because the drop shaft should read as a hole going somewhere.
var room_storeys: Array[int] = []

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

		# M6.6: a room that earns vertical play is built tall enough to contain it.
		# The height roll above is still taken for every room whatever the answer,
		# so the RNG stream is exactly where it was; the override only changes the
		# NUMBER, and only for the archetypes the vocabulary reaches. Everything else
		# keeps the height it always had.
		# M6.7 (found by the deck-climb probe): the motif roll must be taken at the
		# SNAPPED rect's centre, which is where `_plan_decks` takes it. This call
		# used to pass the raw `centre`, so `_plan_motif` — a function whose own
		# docstring says it "must answer the same" both times it is asked — could
		# answer MEZZANINE here and "" over there, or the other way round. When it
		# said "flat" here and "mezzanine" there, the room kept its rolled height:
		# 5.2 m rounds to ONE kit storey, so the shell was built 4 m tall and the
		# gallery was authored at Y_MEZZANINE = 4 m. That is a walkway laid in the
		# ceiling. Nothing in the graph could see it — the deck is reachable, the
		# slope is legal, the footprint is clear — and a capsule walking up the
		# stair puts its head into the ceiling slab 2.7 m from the top.
		var kit_shell: Rect2 = _kit_rect(centre - half, centre + half)
		var storeys: int = _plan_storeys(archetype, unlit.has(i), kit_shell,
				kit_shell.position + kit_shell.size * 0.5)
		if float(storeys) * KIT_STOREY > height:
			height = float(storeys) * KIT_STOREY
		var built: int = maxi(maxi(storeys, int(roundf(height / KIT_STOREY))), 1)
		room_storeys.append(built)

		rooms.append({
			"index": i,
			"cell": cell,
			"min": centre - half,
			"max": centre + half,
			"h": height,
			"storeys": built,
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


## The two ends of the corridor joining `a` and `b`, ordered [a's end, b's end].
##
## `link_point` gives the middle, which is the right waypoint to STEER at but the
## wrong one to draw a straight line through: a line from a corridor's midpoint to
## a room's centre crosses the room's wall beside the doorway, not the doorway. A
## traversal probe has to go in one end and out the other.
func corridor_ends(a: int, b: int) -> Array[Vector3]:
	for corridor: Dictionary in corridors:
		var x: int = int(corridor["a"])
		var y: int = int(corridor["b"])
		if (x != a or y != b) and (x != b or y != a):
			continue
		var lo: Vector2 = corridor["min"]
		var hi: Vector2 = corridor["max"]
		var first: Vector3
		var second: Vector3
		# The SNAPPED footprint, because that is the corridor that was built — the
		# graph rect runs between the rooms' unsnapped faces and its ends can sit
		# outside the shell entirely. Mirrors GeometryKit.kit_corridor_rect; see
		# KIT_CELL for why the graph keeps its own copy of the lattice.
		#
		# Each end is then pushed a further REACH_THROUGH metres into the room it
		# serves, so the waypoint lands past the doorframe on the doorway's own
		# centreline. A point in the mouth is a point a straight line can leave
		# sideways through the corridor wall.
		const REACH_THROUGH: float = 3.0
		if String(corridor["axis"]) == "x":
			var cz: float = _snap_slot((lo.y + hi.y) * 0.5)
			first = Vector3(ceilf(lo.x / KIT_CELL) * KIT_CELL - REACH_THROUGH, 0.0, cz)
			second = Vector3(floorf(hi.x / KIT_CELL) * KIT_CELL + REACH_THROUGH, 0.0, cz)
		else:
			var cx: float = _snap_slot((lo.x + hi.x) * 0.5)
			first = Vector3(cx, 0.0, ceilf(lo.y / KIT_CELL) * KIT_CELL - REACH_THROUGH)
			second = Vector3(cx, 0.0, floorf(hi.y / KIT_CELL) * KIT_CELL + REACH_THROUGH)
		# `first` is the end nearer room `x`; flip when the caller asked the other
		# way round.
		# Built element by element: a ternary between two array literals yields an
		# untyped Array, which will not assign to an Array[Vector3].
		var out: Array[Vector3] = []
		if x == a:
			out.append(first)
			out.append(second)
		else:
			out.append(second)
			out.append(first)
		return out
	var fallback: Array[Vector3] = [centre_of(a), centre_of(b)]
	return fallback


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
	# M4.9 appends last of all. The shaft cache draws from `_rng` after everything
	# else, so it adds two lines to the dump without shifting a single nest, post,
	# Compiler or prop above it — the same append discipline M4 and M4.8 used.
	_place_shaft_cache()
	# M6 last, and deliberately NOT from `_rng` at all: the hunter entry anchors are
	# derived from data the generator already settled (the unlit nests, the room
	# depths), so they cannot perturb the stream even in principle — every seed's
	# shards, nests, posts, Compilers and props are exactly where M5 left them.
	_place_hunter_nests()
	# M6.6 last of all, and — like the hunter anchors — deliberately NOT from
	# `_rng`: every deck, route and ledge is hashed off (room centre, layer seed),
	# so the verticality pass cannot move a shard, nest, post, Compiler or prop on
	# any existing seed even in principle. It runs after the furniture because it
	# has to yield to it (`_floor_fixtures`), not because it needs the stream.
	_plan_decks()


## Entry anchors for M6's directed hunter spawns. Dark rooms (the unlit nests) are
## where a hunter comes in from — never a lit arrival room and never the sanctuary
## (DESIGN.md: backdoor rooms are sacred, no hunter enters, ever). Pure derivation,
## no RNG: the point is a room centre, the room set is `nest_rooms`.
func _place_hunter_nests() -> void:
	var candidates: Array[int] = nest_rooms.duplicate()
	if candidates.is_empty():
		# A layer that rolled no unlit room still gets hunter entries: the deepest
		# rooms that are not the arrival or the way down.
		for room: Dictionary in rooms:
			var index: int = int(room["index"])
			if index != arrival_index and index != shaft_index:
				candidates.append(index)
		candidates.sort()
	for index: int in candidates:
		if is_backdoor and index == shaft_index:
			continue
		hunter_nests.append(centre_of(index))
		hunter_nest_rooms.append(index)
	# Absolute fallback: the arrival room, so a directed spawn always has an anchor.
	if hunter_nests.is_empty():
		hunter_nests.append(centre_of(arrival_index))
		hunter_nest_rooms.append(arrival_index)


## The Auditor's fixed route: every room ordered shallow-to-deep, so the sweep
## works inward and TERMINATES at the lowest accessible point on the ring (the one
## fact the dossier leaks). The sanctuary is excluded on a backdoor layer — the
## Auditor audits the ring, never the campfire. Pure function of the room depths,
## so it is identical on every peer and stable in the dump.
func auditor_route() -> Array[int]:
	var order: Array[int] = []
	for room: Dictionary in rooms:
		var index: int = int(room["index"])
		if is_backdoor and index == shaft_index:
			continue
		order.append(index)
	order.sort_custom(func(a: int, b: int) -> bool:
		var da: int = int(rooms[a]["depth"])
		var db: int = int(rooms[b]["depth"])
		if da != db:
			return da < db
		return a < b)
	return order


## Salvage. Vaults are rich, everything else is loose change; the drop-shaft room
## is skipped here so nobody farms the exit by rerolling — its guaranteed cache is
## placed separately in `_place_shaft_cache`.
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


## The drop-shaft room's guaranteed cache (M4.9). `_place_shards` skips the SHAFT
## archetype so the exit cannot be farmed by rerolling the layer; this hands the
## crew a small FIXED handful there instead — enough that riding the trunk down is
## never a dead room, never enough to camp. A distinct, guaranteed spawn: fixed
## count, tighter scatter, and the only placement that draws from `_rng` after the
## props, so it perturbs nothing above it. On a backdoor layer the shaft room is a
## sanctuary that `_place_shards` already stocks (archetype BACKDOOR), so skip it.
func _place_shaft_cache() -> void:
	if is_backdoor:
		return
	if shaft_index < 0 or shaft_index >= rooms.size():
		return
	var room: Dictionary = rooms[shaft_index]
	for i: int in SHARDS_SHAFT_CACHE:
		shard_points.append(_scatter_point(room, 1.6))
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


# -------------------------------------------------------- M6.6 verticality --
#
# The layers used to read flat: one floor, one ceiling, and every decision the
# player made was a decision about the XZ plane. This section gives the descent a
# Y axis — and does it under the same two laws the rest of the generator answers
# to.
#
#   **Motivation.** Elevation is authored INTO archetypes, never sprinkled as
#   height noise. A vault puts its haul on a plinth because that is what vaults
#   do with valuables. A machinery hall gets a service gallery because somebody
#   has to reach the tops of the racks, and the catwalk off it goes FROM the
#   gallery TO the control platform — a route with two ends, exactly like a cable
#   run has a source and a load. A nest is sunk below grade because the cleaners
#   live in the sump. If a room has no reason to be tall, it stays flat.
#
#   **The solo invariant.** No elevation is ever on the critical path. Ground
#   level stays a complete, connected, jump-free walking surface from every spawn
#   to the drop shaft on every seed: elevated decks stand on columns and the floor
#   runs underneath them, and the four ground-occupying kinds (plinth, terrace,
#   dais, pit) are refused any footprint that touches a doorway aisle, the room's
#   central crossing, or a fixture that was placed before them. `_ground_clear`
#   is where that law lives and `Debug._vertical_selftest` is where it is proved.
#
#   **Killability, both ways.** Every deck is reachable by a ramp, a stair or a
#   catwalk — never only by a drop. A one-way ledge is a shortcut OUT of a perch,
#   never the way in, so there is no position a player can occupy that a Sentinel
#   cannot walk to. The reachability assertion is in the selftest.

## 0..1 from a world position and a salt, hashed against the layer seed. The same
## trick DecalLib and the decay pass use, for the same reason: it is deterministic
## per position on every peer without consuming the shared RNG stream.
func _roll(a: float, b: float, salt: int) -> float:
	var h: int = hash(Vector4i(int(roundf(a)), int(roundf(b)), salt + 977,
			layer_seed & 0x7FFFFFFF))
	return float(absi(h) % 10000) / 10000.0


## The snapped kit footprint of a rect. Mirrors GeometryKit.kit_rect — see the
## KIT_CELL comment for why the graph carries its own copy.
static func _kit_rect(lo: Vector2, hi: Vector2) -> Rect2:
	var slo: Vector2 = Vector2(floorf(lo.x / KIT_CELL) * KIT_CELL,
			floorf(lo.y / KIT_CELL) * KIT_CELL)
	var shi: Vector2 = Vector2(ceilf(hi.x / KIT_CELL) * KIT_CELL,
			ceilf(hi.y / KIT_CELL) * KIT_CELL)
	return Rect2(slo, shi - slo)


## Which vertical motif a room earns, as a pure function of what the room IS and
## how big it actually got. Returns "" for a flat room.
##
## Called twice — once from `_build_rooms` (which needs only the storey count) and
## once from `_plan_decks` (which needs the layout) — and it must answer the same
## thing both times, which is why it takes no state and draws no RNG.
func _plan_motif(archetype: String, unlit: bool, rect: Rect2, centre: Vector2) -> String:
	# Two measurements, because a wall-band deck cares about two different things:
	# `span` is how much clear floor is left once a four-metre band is taken off a
	# wall (so the crossing survives), and `wall` is whether any wall is long
	# enough to hold a route AND a deck end to end. A 12 x 24 m vault is a perfectly
	# good plinth room; a 12 x 12 m one is not.
	var span: float = minf(rect.size.x, rect.size.y)
	var wall: float = maxf(rect.size.x, rect.size.y)
	match archetype:
		ARRIVAL:
			# The one room that stays flat on purpose. It is the crew's single
			# moment of orientation and the start of the critical path; a player
			# should never arrive facing a staircase.
			return ""
		BACKDOOR:
			return DECK_DAIS if wall >= 16.0 else ""
		SHAFT:
			# The trunk room is the layer's tall room. Its gantry is the strongest
			# perch in the game and it is deliberately placed at the exit, where the
			# crew is already deciding whether to leave.
			return DECK_GANTRY if wall >= 16.0 and span >= 12.0 else ""
		VAULT:
			return DECK_PLINTH if wall >= 16.0 and span >= 12.0 else ""
		SIPHON:
			return DECK_TERRACE if wall >= 16.0 else ""
	# Bus halls. A nest sinks; a working hall gets a gallery if it is big enough
	# for one and a stack terrace if it is not. Two halls in five stay flat even
	# when they would fit a gallery — a layer where every room has a mezzanine has
	# no mezzanines, it has a texture.
	if unlit:
		return DECK_PIT if wall >= 16.0 else ""
	if wall >= 16.0 and span >= 12.0 and _roll(centre.x, centre.y, 7331) < 0.72:
		return DECK_MEZZANINE
	if wall >= 16.0 and _roll(centre.x, centre.y, 7457) < 0.5:
		return DECK_TERRACE
	return ""


## Storeys a room is built to. Anything hanging a walkway at head height needs a
## second course of wall behind it; the trunk room takes a third so the drop shaft
## reads as a hole with somewhere to go.
func _plan_storeys(archetype: String, unlit: bool, rect: Rect2, centre: Vector2) -> int:
	var motif: String = _plan_motif(archetype, unlit, rect, centre)
	match motif:
		DECK_GANTRY:
			return 3
		DECK_MEZZANINE:
			return 2
		DECK_PLINTH:
			return 2
	# A vault or a sanctuary that missed its motif is still the room the layer's
	# hero light shaft wants to be in, and a shaft cannot be composed inside a 4 m
	# box (ProcLayerBuilder._plan_shafts refuses one).
	if archetype == VAULT or archetype == BACKDOOR:
		return 2
	return 0


# --- placement helpers -------------------------------------------------------

## The strips of floor a room may not build a solid obstacle in: one aisle per
## doorway running from that wall to the far side, plus the central crossing they
## all pass through. Returned as Rect2s in world XZ.
func _aisles(room: Dictionary) -> Array[Rect2]:
	var rect: Rect2 = _kit_rect(room["min"], room["max"])
	var centre: Vector2 = rect.position + rect.size * 0.5
	var out: Array[Rect2] = [Rect2(centre - Vector2.ONE * CROSSING_HALF,
			Vector2.ONE * CROSSING_HALF * 2.0)]
	# An aisle runs from its doorway to the central crossing and stops there. It
	# does NOT run on to the far wall: every doorway path meets every other one in
	# the middle, so reaching the crossing is the whole requirement, and an aisle
	# that crossed the entire room would refuse a deck on any wall perpendicular to
	# any door — which in a single-door room is three walls out of four.
	for door: Dictionary in (room.get("doors", []) as Array):
		var wall: String = String(door.get("wall", ""))
		# SNAPPED, not the graph's raw `at`.
		#
		# Found by the `--pathwalk` capsule sweep, which is the entire reason that
		# instrument exists: the aisle was centred on the position the generator
		# chose, but the doorway is BUILT at `snap_slot(at)` — up to two metres
		# along the wall from it. So a deck could clear the aisle by the rules and
		# still stand beside the real opening, and on seed 4242 layer 3 a terrace
		# did exactly that, one and a half metres inside the door. The graph was
		# right about its own rule; the rule was about the wrong coordinate.
		var at: float = _snap_slot(float(door.get("at", 0.0)))
		match wall:
			"n":
				out.append(Rect2(Vector2(at - AISLE_HALF, rect.position.y),
						Vector2(AISLE_HALF * 2.0,
								centre.y - rect.position.y + CROSSING_HALF)))
			"s":
				out.append(Rect2(Vector2(at - AISLE_HALF, centre.y - CROSSING_HALF),
						Vector2(AISLE_HALF * 2.0,
								rect.end.y - centre.y + CROSSING_HALF)))
			"w":
				out.append(Rect2(Vector2(rect.position.x, at - AISLE_HALF),
						Vector2(centre.x - rect.position.x + CROSSING_HALF,
								AISLE_HALF * 2.0)))
			_:
				out.append(Rect2(Vector2(centre.x - CROSSING_HALF, at - AISLE_HALF),
						Vector2(rect.end.x - centre.x + CROSSING_HALF,
								AISLE_HALF * 2.0)))
	return out


## Is `inner` inside `outer`? Rect2.encloses is exact and every deck here is
## deliberately flush with a wall, so a shrunken-rect test rejects exactly the
## placements the pass is built to make. This one tolerates a centimetre.
static func _within(outer: Rect2, inner: Rect2) -> bool:
	return inner.position.x >= outer.position.x - 0.01 \
			and inner.position.y >= outer.position.y - 0.01 \
			and inner.end.x <= outer.end.x + 0.01 \
			and inner.end.y <= outer.end.y + 0.01


## Everything already standing on this room's floor. Decks are planned last and
## give way to all of it — a plinth that swallowed a Compiler would be a shop you
## cannot reach, and a plinth on a Sentinel post would be a Sentinel inside a wall.
func _floor_fixtures(index: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i: int in sentinel_post_rooms.size():
		if sentinel_post_rooms[i] == index:
			out.append(sentinel_posts[i])
	for i: int in compiler_rooms.size():
		if compiler_rooms[i] == index:
			out.append(compiler_points[i])
	for i: int in junction_rooms.size():
		if junction_rooms[i] == index:
			out.append(junction_points[i])
	for i: int in vent_rooms.size():
		if vent_rooms[i] == index:
			out.append(vent_points[i])
	for i: int in cabinet_rooms.size():
		if cabinet_rooms[i] == index:
			out.append(cabinet_points[i])
	if terminal_room == index:
		out.append(terminal_point)
	if index == arrival_index:
		out.append_array(spawns)
	if index == shaft_index:
		out.append(shaft_point)
		if is_backdoor:
			out.append(backdoor_point)
			out.append(uplink_point)
	for i: int in scrubber_nest_rooms.size():
		if scrubber_nest_rooms[i] == index:
			out.append(scrubber_nests[i])
	return out


## May a GROUND-OCCUPYING surface stand here? The solo invariant, as a predicate.
func _ground_clear(room: Dictionary, foot: Rect2) -> bool:
	for aisle: Rect2 in _aisles(room):
		if aisle.intersects(foot):
			return false
	for fixture: Vector3 in _floor_fixtures(int(room["index"])):
		if foot.grow(DECK_FIXTURE_CLEAR).has_point(Vector2(fixture.x, fixture.z)):
			return false
	return true


## Adds a deck and returns its id.
func _add_deck(room: int, kind: String, foot: Rect2, y: float, solid: bool,
		loot: bool) -> int:
	var id: int = decks.size()
	decks.append({
		"id": id, "room": room, "kind": kind,
		"min": foot.position, "max": foot.end, "y": y,
		"band": elevation_band(y), "solid": solid, "loot": loot,
	})
	return id


## Storey index for a floor height — the one number a vertical-aware minimap
## needs to slice a layer by level. -1 sunken, 0 grade, 1 mezzanine.
##
## FLOOR rather than round, and the difference is the whole point. Rounding put a
## 2.4 m vault plinth on the mezzanine slice (2.4/4 rounds to 1) while leaving a
## 1.6 m terrace on the grade slice — so two knee-high steps, which a player reads
## as the same kind of thing, landed on different levels of the map. Flooring puts
## every step, plinth, terrace and dais on grade where they belong, and reserves
## band 1 for the decks you actually have to climb to: the ones at a full storey.
static func elevation_band(y: float) -> int:
	return int(floorf(y / KIT_STOREY))


## Adds a walkable route between two decks (-1 is the ground floor). `axis` is the
## direction of travel; `dir` is +1 when the surface rises toward increasing axis.
func _add_link(room: int, lower: int, upper: int, kind: String, foot: Rect2,
		axis: String, dir: int, y0: float, y1: float) -> void:
	var mid: Vector2 = foot.position + foot.size * 0.5
	var half: float = (foot.size.x if axis == "x" else foot.size.y) * 0.5
	var step: Vector2 = Vector2(float(dir), 0.0) if axis == "x" else Vector2(0.0, float(dir))
	var foot_at: Vector2 = mid - step * half
	var head_at: Vector2 = mid + step * half
	deck_links.append({
		"room": room, "a": lower, "b": upper, "kind": kind,
		"min": foot.position, "max": foot.end, "axis": axis, "dir": dir,
		"y0": y0, "y1": y1,
		# One cell short of each end, so a creature steering at the foot of a ramp
		# is aimed at the bottom of the slope rather than at the lip of it.
		"foot": Vector3(foot_at.x, y0, foot_at.y) + Vector3(step.x, 0.0, step.y) * 1.0,
		"head": Vector3(head_at.x, y1, head_at.y) - Vector3(step.x, 0.0, step.y) * 1.0,
	})


## A readable ledge off `deck`, facing `dir`. Only emitted when the fall is worth
## making — see DROP_MIN_HEIGHT — and never used as a route INTO anything.
func _add_drop(room: int, deck: int, at: Vector3, dir: Vector2, landing_y: float) -> void:
	var height: float = at.y - landing_y
	if height < DROP_MIN_HEIGHT:
		return
	deck_drops.append({
		"room": room, "deck": deck, "at": at,
		"to": Vector3(at.x + dir.x * 2.6, landing_y, at.z + dir.y * 2.6),
		"height": height, "dir": Vector3(dir.x, 0.0, dir.y),
	})


# --- the planner -------------------------------------------------------------

## Builds every deck, route and ledge on the layer. Runs last of all, after every
## furniture point exists, so it can yield to all of them.
func _plan_decks() -> void:
	for room: Dictionary in rooms:
		var rect: Rect2 = _kit_rect(room["min"], room["max"])
		var centre: Vector2 = rect.position + rect.size * 0.5
		var motif: String = _plan_motif(String(room["archetype"]),
				bool(room["unlit"]), rect, centre)
		match motif:
			DECK_MEZZANINE:
				_plan_mezzanine(room, rect)
			DECK_GANTRY:
				_plan_gantry(room, rect)
			DECK_PLINTH:
				_plan_plinth(room, rect)
			DECK_TERRACE:
				_plan_terrace(room, rect)
			DECK_PIT:
				_plan_pit(room, rect)
			DECK_DAIS:
				_plan_dais(room, rect)
	_lift_loot()


## Wall sides in the order this room prefers to build against: door-free walls
## first (a gallery goes over the machines, not over the entrance), then the rest,
## with the tie broken by a position hash so two same-shaped rooms differ.
func _wall_order(room: Dictionary, salt: int) -> Array[int]:
	var doored: Dictionary = {}
	for door: Dictionary in (room.get("doors", []) as Array):
		match String(door.get("wall", "")):
			"n":
				doored[0] = true
			"e":
				doored[1] = true
			"s":
				doored[2] = true
			_:
				doored[3] = true
	var rect: Rect2 = _kit_rect(room["min"], room["max"])
	var mid: Vector2 = rect.position + rect.size * 0.5
	var start: int = int(_roll(mid.x, mid.y, salt) * 4.0) % 4
	var free: Array[int] = []
	var used: Array[int] = []
	for step: int in 4:
		var side: int = (start + step) % 4
		if doored.has(side):
			used.append(side)
		else:
			free.append(side)
	free.append_array(used)
	return free


## A strip of floor `depth` deep along one wall of `rect`, inset `margin` from
## both of its ends.
static func _wall_strip(rect: Rect2, side: int, depth: float, margin: float) -> Rect2:
	match side:
		0:
			return Rect2(rect.position.x + margin, rect.position.y,
					rect.size.x - margin * 2.0, depth)
		1:
			return Rect2(rect.end.x - depth, rect.position.y + margin,
					depth, rect.size.y - margin * 2.0)
		2:
			return Rect2(rect.position.x + margin, rect.end.y - depth,
					rect.size.x - margin * 2.0, depth)
		_:
			return Rect2(rect.position.x, rect.position.y + margin,
					depth, rect.size.y - margin * 2.0)


## Inward normal of a wall side, in XZ.
static func _side_normal(side: int) -> Vector2:
	match side:
		0:
			return Vector2(0.0, 1.0)
		1:
			return Vector2(-1.0, 0.0)
		2:
			return Vector2(0.0, -1.0)
		_:
			return Vector2(1.0, 0.0)


## Splits one wall band into a ROUTE slice and a DECK slice, laid end to end
## along the wall. Returns {ok, deck:Rect2, route:Rect2, axis:String, dir:int},
## where `dir` is +1 when the deck lies toward increasing `axis` from the route.
##
## Every ground-standing surface the verticality pass emits comes out of this
## function, which is how the solo invariant is held structurally rather than by
## checking for it afterwards: a route and its deck both live in the four-metre
## band against a wall, so the room's middle is never touched by either.
func _split_band(rect: Rect2, side: int, depth: float, run: float,
		deck_len: float, salt: int) -> Dictionary:
	var horizontal: bool = side % 2 == 0
	# A two-cell band is only affordable in a room deep enough to still have a
	# crossing left over once it is taken. Everywhere else the band narrows to one
	# cell rather than the whole motif being refused — a shallow gallery is still
	# a gallery, and a room with no midground is the failure mode the intricacy law
	# names by name.
	var across: float = rect.size.y if horizontal else rect.size.x
	var want: float = depth if across >= 24.0 else minf(depth, KIT_CELL)
	var band: Rect2 = _wall_strip(rect, side, want, 0.0)
	if band.size.x < KIT_CELL or band.size.y < KIT_CELL:
		return {"ok": false}
	var along: float = band.size.x if horizontal else band.size.y
	# The reserve is spent at whichever end the ROUTE lands on; the deck may still
	# run flush to the far end, because nobody has to walk onto a deck from outside
	# the room.
	if along < run + KIT_CELL + ROUTE_APPROACH:
		return {"ok": false}
	# Deck length snapped DOWN to the lattice, so its far edge lands on a cell
	# boundary and the floor modules stamped on it are whole.
	var used: float = floorf(
			minf(deck_len, along - run - ROUTE_APPROACH) / KIT_CELL) * KIT_CELL
	if used < KIT_CELL:
		return {"ok": false}

	var lo: float = band.position.x if horizontal else band.position.y
	var hi: float = lo + along
	var route_first: bool = _roll(band.position.x, band.position.y, salt) < 0.5
	var route_lo: float = lo + ROUTE_APPROACH if route_first else hi - ROUTE_APPROACH - run
	var deck_lo: float = lo + ROUTE_APPROACH + run if route_first \
			else hi - ROUTE_APPROACH - run - used
	var axis: String = "x" if horizontal else "z"

	var deck: Rect2
	var route: Rect2
	if horizontal:
		deck = Rect2(Vector2(deck_lo, band.position.y), Vector2(used, band.size.y))
		route = Rect2(Vector2(route_lo, band.position.y), Vector2(run, band.size.y))
	else:
		deck = Rect2(Vector2(band.position.x, deck_lo), Vector2(band.size.x, used))
		route = Rect2(Vector2(band.position.x, route_lo), Vector2(band.size.x, run))
	return {"ok": true, "deck": deck, "route": route, "axis": axis,
			"dir": 1 if route_first else -1}


## The machinery hall's service gallery, the catwalk that leaves it, and the
## control platform the catwalk arrives at.
##
## This is the archetype the whole feature was built for: a big volume that used
## to be a floor with racks on it becomes a floor with racks on it and a walkway
## over them, a span across the middle at head height, and a small overlook you
## have to commit to a route to reach. The gallery, the span and the platform are
## all ELEVATED and stand on columns, so the ground floor the crew crosses is
## exactly as walkable as it was before; only the stair touches the floor, and
## the stair is inside the wall band.
func _plan_mezzanine(room: Dictionary, rect: Rect2) -> void:
	var index: int = int(room["index"])
	var centre: Vector2 = rect.position + rect.size * 0.5
	var deep: bool = minf(rect.size.x, rect.size.y) >= 24.0
	var depth: float = KIT_CELL * (2.0 if deep else 1.0)

	for side: int in _wall_order(room, 7541):
		var split: Dictionary = _split_band(rect, side, depth, STAIR_RUN,
				KIT_CELL * 4.0, 7603)
		if not bool(split["ok"]):
			continue
		var stair: Rect2 = split["route"]
		# Only the stair stands on the floor, so only the stair has to clear.
		if not _ground_clear(room, stair):
			continue
		var gallery: Rect2 = split["deck"]
		var horizontal: bool = side % 2 == 0
		var normal: Vector2 = _side_normal(side)

		var gallery_id: int = _add_deck(index, DECK_MEZZANINE, gallery,
				Y_MEZZANINE, false, false)
		_add_link(index, -1, gallery_id, LINK_STAIR, stair, String(split["axis"]),
				int(split["dir"]), 0.0, Y_MEZZANINE)

		# The catwalk. It spans FROM the gallery TO a control platform on the far
		# wall, because a walkway that stops in mid-air is scenery and a walkway
		# with two ends is maintenance access. Two cells wide of platform: an
		# overlook, not a second gallery — the scarcity is what makes the climb a
		# question rather than a chore.
		var far: int = (side + 2) % 4
		var control: Rect2 = _wall_strip(rect, far, KIT_CELL, 0.0)
		var gallery_mid: Vector2 = gallery.position + gallery.size * 0.5
		var span_at: float = _snap_cell(gallery_mid.x if horizontal else gallery_mid.y)
		if horizontal:
			control = Rect2(Vector2(span_at - KIT_CELL, control.position.y),
					Vector2(KIT_CELL * 2.0, control.size.y))
		else:
			control = Rect2(Vector2(control.position.x, span_at - KIT_CELL),
					Vector2(control.size.x, KIT_CELL * 2.0))
		if _within(rect, control):
			var span: Rect2
			if horizontal:
				var z0: float = gallery.end.y if side == 0 else control.end.y
				var z1: float = control.position.y if side == 0 else gallery.position.y
				span = Rect2(Vector2(span_at - KIT_CELL * 0.5, z0),
						Vector2(DECK_WIDTH, maxf(z1 - z0, 0.0)))
			else:
				var x0: float = gallery.end.x if side == 3 else control.end.x
				var x1: float = control.position.x if side == 3 else gallery.position.x
				span = Rect2(Vector2(x0, span_at - KIT_CELL * 0.5),
						Vector2(maxf(x1 - x0, 0.0), DECK_WIDTH))
			if span.size.x >= KIT_CELL and span.size.y >= KIT_CELL:
				var control_id: int = _add_deck(index, DECK_CONTROL, control,
						Y_MEZZANINE, false, true)
				var catwalk_id: int = _add_deck(index, DECK_CATWALK, span,
						Y_MEZZANINE, false, false)
				var span_axis: String = "z" if horizontal else "x"
				_add_link(index, gallery_id, catwalk_id, LINK_CATWALK, span,
						span_axis, 1, Y_MEZZANINE, Y_MEZZANINE)
				_add_link(index, catwalk_id, control_id, LINK_CATWALK, span,
						span_axis, 1, Y_MEZZANINE, Y_MEZZANINE)
				# The way out. Stepping off the control platform is a four-metre
				# fall onto the machine floor: loud, cheap in integrity, and much
				# faster than walking back across the span with something following.
				var lip: Vector2 = control.position + control.size * 0.5 \
						+ _side_normal(far) * (KIT_CELL * 0.5)
				_add_drop(index, control_id, Vector3(lip.x, Y_MEZZANINE, lip.y),
						_side_normal(far), 0.0)

		# And one off the gallery's inner edge, so a mezzanine fight always has an
		# exit that is not the stair you came up.
		var edge: Vector2 = gallery.position + gallery.size * 0.5 \
				+ normal * ((gallery.size.y if horizontal else gallery.size.x) * 0.5)
		_add_drop(index, gallery_id, Vector3(edge.x, Y_MEZZANINE, edge.y), normal, 0.0)
		return


## The trunk room's service ring: an L of gantry along two walls at one storey, a
## stair up at one end, and a ledge back down onto the pad. The drop shaft itself
## stays in the clear middle of the room, at grade, exactly where it always was —
## riding the trunk down never asks you to climb anything.
func _plan_gantry(room: Dictionary, rect: Rect2) -> void:
	var index: int = int(room["index"])
	for side: int in _wall_order(room, 7669):
		var split: Dictionary = _split_band(rect, side, KIT_CELL, STAIR_RUN,
				KIT_CELL * 4.0, 7717)
		if not bool(split["ok"]):
			continue
		var stair: Rect2 = split["route"]
		if not _ground_clear(room, stair):
			continue
		var run_a: Rect2 = split["deck"]
		var gantry: int = _add_deck(index, DECK_GANTRY, run_a, Y_GANTRY, false, true)
		_add_link(index, -1, gantry, LINK_STAIR, stair, String(split["axis"]),
				int(split["dir"]), 0.0, Y_GANTRY)

		# The second arm, round the corner the gantry's deck end reaches. Two
		# perpendicular wall bands physically meet in that corner cell, so the arm
		# is a genuine continuation of the walkway rather than a floating slab.
		#
		# M6.7 (found by the deck-climb probe): the corner is chosen off RUN_A's own
		# extent, not off the split's `dir`. The old line rotated the side by +1 or
		# -1 depending on `dir`, and that convention only holds for two of the four
		# sides — on a west or a south band it named the corner at the STAIR's end
		# instead of the deck's. The stair band sits between the two, descending, so
		# the arm was a slab in mid-air 3 m above the flight with a LINK_CATWALK
		# claiming it was walkable. Every graph law passed: the deck was reachable
		# (there was an edge), the span was level and wide, nothing blocked the
		# ground. A capsule walked under it.
		#
		# Which end of the band `run_a` occupies is a fact about two rectangles, so
		# it is read off them rather than re-derived from the split's bookkeeping.
		var vertical_band: bool = side % 2 == 1
		var arm_side: int
		if vertical_band:
			# Band runs along Z: its low end is the north side, its high end south.
			arm_side = 0 if absf(run_a.position.y - rect.position.y) \
					<= absf(run_a.end.y - rect.end.y) else 2
		else:
			# Band runs along X: low end west, high end east.
			arm_side = 3 if absf(run_a.position.x - rect.position.x) \
					<= absf(run_a.end.x - rect.end.x) else 1
		var arm: Rect2 = _wall_strip(rect, arm_side, KIT_CELL, 0.0)
		var horizontal: bool = side % 2 == 0
		# Trim the arm back so it stops before the opposite wall — a full ring
		# would read as a mezzanine, and the trunk room wants an L that frames the
		# shaft rather than a balcony that surrounds it.
		if horizontal:
			arm = Rect2(arm.position, Vector2(arm.size.x, minf(arm.size.y, KIT_CELL * 3.0))) \
					if arm_side % 2 == 1 else arm
		if arm_side % 2 == 1:
			var near_z: bool = absf(run_a.position.y - arm.position.y) \
					< absf(run_a.end.y - arm.end.y)
			var length: float = minf(arm.size.y, KIT_CELL * 3.0)
			arm = Rect2(Vector2(arm.position.x, arm.position.y if near_z else arm.end.y - length),
					Vector2(arm.size.x, length))
		else:
			var near_x: bool = absf(run_a.position.x - arm.position.x) \
					< absf(run_a.end.x - arm.end.x)
			var length_x: float = minf(arm.size.x, KIT_CELL * 3.0)
			arm = Rect2(Vector2(arm.position.x if near_x else arm.end.x - length_x, arm.position.y),
					Vector2(length_x, arm.size.y))
		# And the arm only exists if it TOUCHES the run. The side choice above is
		# correct, and this is the law it is correct against: a walkway you get to
		# by walking is one whose two halves share an edge. `grow(0.05)` because two
		# rectangles that abut exactly do not "intersect" in float arithmetic.
		if _within(rect, arm) and arm.size.x >= KIT_CELL \
				and arm.size.y >= KIT_CELL and arm.grow(0.05).intersects(run_a):
			var arm_id: int = _add_deck(index, DECK_GANTRY, arm, Y_GANTRY, false, false)
			_add_link(index, gantry, arm_id, LINK_CATWALK, arm,
					"x" if arm_side % 2 == 0 else "z", 1, Y_GANTRY, Y_GANTRY)

		var normal: Vector2 = _side_normal(side)
		var lip: Vector2 = run_a.position + run_a.size * 0.5 + normal * (KIT_CELL * 0.5)
		_add_drop(index, gantry, Vector3(lip.x, Y_GANTRY, lip.y), normal, 0.0)
		return


## The vault's prize deck. A slab along one wall with the haul on it and steps up
## the side of it — the room's whole proposition in one shape: the thing you came
## for is visible from the doorway and standing on it puts you in the open, above
## the cover, with one way down that makes a noise.
func _plan_plinth(room: Dictionary, rect: Rect2) -> void:
	_plan_solid(room, rect, DECK_PLINTH, Y_PLINTH, RAMP_RUN_PLINTH,
			KIT_CELL, KIT_CELL * 3.0, 7793, true, LINK_STAIR)


## A stack terrace: plant standing a step above the floor, which is what plant
## rooms do with machinery that must not sit in a coolant spill. Small and cheap,
## and the reason a siphon junction stops being a flat box with a pillar in it.
func _plan_terrace(room: Dictionary, rect: Rect2) -> void:
	_plan_solid(room, rect, DECK_TERRACE, Y_TERRACE, RAMP_RUN_LOW,
			KIT_CELL, KIT_CELL * 2.0, 7867, true, LINK_RAMP)


## The sanctuary's node step. Low, and ramped from BOTH ends, because the one
## room in the game whose job is to feel safe should never make you walk around
## anything to reach the thing you came for.
func _plan_dais(room: Dictionary, rect: Rect2) -> void:
	_plan_solid(room, rect, DECK_DAIS, Y_DAIS, RAMP_RUN_LOW,
			KIT_CELL, KIT_CELL * 2.0, 7919, false, LINK_RAMP, true)


## Shared body for the ground-occupying decks. Walks the wall order looking for a
## band whose deck AND whose route both clear the aisles, the crossing and every
## fixture already standing on the floor; gives up quietly when the room has no
## room, which is the correct answer for a small hall that is already full.
func _plan_solid(room: Dictionary, rect: Rect2, kind: String, y: float,
		run: float, depth: float, deck_len: float, salt: int, loot: bool,
		link_kind: String, both_ends: bool = false) -> void:
	var index: int = int(room["index"])
	for side: int in _wall_order(room, salt):
		var split: Dictionary = _split_band(rect, side, depth, run, deck_len,
				salt + 31)
		if not bool(split["ok"]):
			continue
		var deck: Rect2 = split["deck"]
		var route: Rect2 = split["route"]
		if not _ground_clear(room, deck) or not _ground_clear(room, route):
			continue

		var horizontal: bool = side % 2 == 0
		var axis: String = String(split["axis"])
		var dir: int = int(split["dir"])
		var id: int = _add_deck(index, kind, deck, y, true, loot)
		_add_link(index, -1, id, link_kind, route, axis, dir, 0.0, y)

		if both_ends:
			# The far face gets its own ramp, if the wall is long enough to hold
			# one and the floor there is clear.
			var back: Rect2
			if horizontal:
				var x0: float = deck.end.x if dir > 0 else deck.position.x - run
				back = Rect2(Vector2(x0, deck.position.y), Vector2(run, deck.size.y))
			else:
				var z0: float = deck.end.y if dir > 0 else deck.position.y - run
				back = Rect2(Vector2(deck.position.x, z0), Vector2(deck.size.x, run))
			if _within(rect, back) and _ground_clear(room, back):
				_add_link(index, -1, id, link_kind, back, axis, -dir, 0.0, y)
		return


## Nearest kit cell boundary, so a deck's edges land on the lattice the floor
## modules are stamped on.
static func _snap_cell(v: float) -> float:
	return roundf(v / KIT_CELL) * KIT_CELL


## Nearest module SLOT centre (4k + 2) — the lattice a doorway lands on.
## Mirrors GeometryKit.snap_slot.
static func _snap_slot(v: float) -> float:
	return roundf((v - KIT_CELL * 0.5) / KIT_CELL) * KIT_CELL + KIT_CELL * 0.5


## A nest sunk below grade. The only deck kind that goes DOWN, and the only ramp
## on the layer that descends: the pack lives in the sump, and walking in means
## losing your sightline over the lip of it before you can see what is down there.
func _plan_pit(room: Dictionary, rect: Rect2) -> void:
	var index: int = int(room["index"])
	for side: int in _wall_order(room, 7993):
		var split: Dictionary = _split_band(rect, side, KIT_CELL * 2.0,
				RAMP_RUN_LOW, KIT_CELL * 3.0, 8039)
		if not bool(split["ok"]):
			continue
		var pit: Rect2 = split["deck"]
		var ramp: Rect2 = split["route"]
		if not _ground_clear(room, pit) or not _ground_clear(room, ramp):
			continue
		var id: int = _add_deck(index, DECK_PIT, pit, Y_PIT, true, true)
		# A sunken deck is a HOLE, and the hole has to include the ramp that leads
		# into it or the ramp would be a slope down to a wall. The two are collinear
		# in the wall band, so their union is a rectangle; the builder cuts it out of
		# the floor field and out of the slab collider.
		decks[id]["cut"] = pit.merge(ramp)
		# The pit is the LOW end, so the ascent runs from the pit toward the ramp's
		# outer end — the opposite sense to every raised deck.
		_add_link(index, id, -1, LINK_RAMP, ramp, String(split["axis"]),
				-int(split["dir"]), Y_PIT, 0.0)
		return


## Moves a little loot onto the decks that asked for it.
##
## Nothing is CREATED here and nothing is created for a perch anywhere: the layer
## has exactly the salvage it always had, and a few pieces of it are now somewhere
## that costs you a climb and a silhouette. That is the whole design of the
## feature — "is it worth the exposure?" is only a question if the alternative is
## walking past it.
func _lift_loot() -> void:
	for deck: Dictionary in decks:
		if not bool(deck["loot"]):
			continue
		var room: int = int(deck["room"])
		var lo: Vector2 = deck["min"]
		var hi: Vector2 = deck["max"]
		var y: float = float(deck["y"])
		var wanted: int = 3 if String(deck["kind"]) == DECK_PLINTH else 2
		var moved: int = 0
		for i: int in shard_points.size():
			if moved >= wanted or shard_rooms[i] != room:
				continue
			var at: Vector2 = Vector2(
					lerpf(lo.x + 1.2, hi.x - 1.2, _roll(float(i), y, 8009 + i)),
					lerpf(lo.y + 1.2, hi.y - 1.2, _roll(y, float(i), 8123 + i)))
			shard_points[i] = Vector3(at.x, y, at.y)
			perch_points.append(shard_points[i])
			perch_decks.append(int(deck["id"]))
			moved += 1

		# A tap that ended up inside its room's terrace goes ON it. The machinery is
		# the reason the terrace exists, so the two belong together — and it turns
		# the loudest thing on the layer into a thing you do in the open, one step
		# up, with one way down.
		if String(deck["kind"]) != DECK_TERRACE:
			continue
		var foot: Rect2 = Rect2(lo, hi - lo)
		for i: int in siphon_points.size():
			if siphon_rooms[i] != room:
				continue
			var flat: Vector2 = Vector2(siphon_points[i].x, siphon_points[i].z)
			# Adopt any tap the terrace REACHES, not just one already comfortably
			# inside it. The first version only lifted taps within the shrunk
			# footprint, which left a tap sitting at the rim standing at grade with
			# the slab built straight through it — the audit's last surviving
			# clipping class. A terrace may not be laid over a tap it declines to
			# adopt.
			# ADOPT OR KEEP CLEAR — never graze. A tap just outside the slab still
			# clipped the edge fascia, because a tap housing is over a metre wide and
			# the fascia stands 0.11 m proud of the deck. Adopting anything within a
			# full fixture clearance closes the annulus where that can happen: either
			# the plant is on the terrace, or it is far enough away to be unrelated
			# to it. Half-measures here are what the audit kept finding.
			if not foot.grow(DECK_FIXTURE_CLEAR).has_point(flat):
				continue
			# Pulled clear of the terrace edge before it is raised. The audit found
			# tap housings clipping the deck's own fascia lip: the tap only had to be
			# inside the footprint to be lifted, so one that rolled near the rim ended
			# up half inside the edge trim. Standing plant belongs in the middle of
			# its plinth anyway.
			# Adaptive: on a one-cell-deep terrace a fixed 1.6 m inset still left the
			# tap housing grazing the edge fascia. Take half the narrow axis less a
			# margin instead, so a shallow deck simply centres its plant.
			var margin: float = minf(1.9,
					minf(foot.size.x, foot.size.y) * 0.5 - 0.3)
			var inset: Rect2 = foot.grow(-maxf(margin, 0.2))
			var placed: Vector2 = Vector2(
					clampf(flat.x, inset.position.x, inset.end.x),
					clampf(flat.y, inset.position.y, inset.end.y))
			siphon_points[i] = Vector3(placed.x, y, placed.y)
			# The approach follows the tap, or an automated `--goto siphon` walks to
			# where the tap used to be.
			# Stand where the plant is reachable from: the middle of its own deck.
			var deck_mid: Vector2 = foot.position + foot.size * 0.5
			siphon_approaches[i] = Vector3(deck_mid.x, y, deck_mid.y)
			perch_points.append(siphon_points[i])
			perch_decks.append(int(deck["id"]))


# --- queries -----------------------------------------------------------------

## The deck a position is standing on, or -1 for the ground floor. Vertical
## tolerance is half a storey, so a body walking up a ramp resolves to whichever
## end it is nearer.
func deck_at(point: Vector3) -> int:
	var best: int = -1
	var best_gap: float = 2.2
	for deck: Dictionary in decks:
		var lo: Vector2 = deck["min"]
		var hi: Vector2 = deck["max"]
		if point.x < lo.x or point.x > hi.x or point.z < lo.y or point.z > hi.y:
			continue
		var gap: float = absf(point.y - float(deck["y"]))
		if gap < best_gap:
			best_gap = gap
			best = int(deck["id"])
	return best


## Floor height of a deck (0.0 for the ground).
func deck_height(id: int) -> float:
	if id < 0 or id >= decks.size():
		return 0.0
	return float(decks[id]["y"])


## Decks belonging to one room, ground excluded.
func decks_in(room: int) -> Array[int]:
	var out: Array[int] = []
	for deck: Dictionary in decks:
		if int(deck["room"]) == room:
			out.append(int(deck["id"]))
	return out


## The waypoint a body at `at`, standing on deck `from`, should steer at to reach
## deck `to` — both decks in `room`. Returns Vector3.INF when there is no route,
## which `unreachable_decks` asserts never happens for any authored deck.
##
## `at` decides which END of the first link to aim at, and that is the difference
## between a creature that climbs a stair and one that paces at the bottom of it:
## once the body is standing ON the flight, the target becomes the far end, so it
## commits instead of re-deciding every tick and turning back toward the foot it
## has just walked past.
##
## Breadth-first over a graph that never has more than five nodes, recomputed per
## AI tick. That is cheaper than caching it and it stays correct if a future pass
## ever makes a link closable, the same way `_rebuild_hops` does for corridors.
func deck_waypoint(room: int, from: int, to: int, at: Vector3 = Vector3.INF) -> Vector3:
	if from == to:
		return Vector3.INF
	var links: Dictionary = {}  # deck id -> Array[link index]
	for i: int in deck_links.size():
		if int(deck_links[i]["room"]) != room:
			continue
		for key: int in [int(deck_links[i]["a"]), int(deck_links[i]["b"])]:
			if not links.has(key):
				links[key] = [] as Array[int]
			(links[key] as Array[int]).append(i)

	var previous: Dictionary = {from: -1}
	var queue: Array[int] = [from]
	var head: int = 0
	while head < queue.size():
		var current: int = queue[head]
		head += 1
		if current == to:
			break
		for i: int in (links.get(current, [] as Array[int]) as Array[int]):
			var link: Dictionary = deck_links[i]
			var other: int = int(link["b"]) if int(link["a"]) == current else int(link["a"])
			if previous.has(other):
				continue
			previous[other] = i
			queue.append(other)

	if not previous.has(to):
		return Vector3.INF
	# Walk back to the first hop out of `from`, and aim at the end of that link
	# which is on `from`'s side.
	var step: int = to
	while int(previous[step]) >= 0:
		var link_index: int = int(previous[step])
		var link: Dictionary = deck_links[link_index]
		var lower: int = int(link["a"])
		var upper: int = int(link["b"])
		var back: int = upper if lower == step else lower
		if back == from:
			var near: Vector3 = link["foot"] if lower == from else link["head"]
			var far: Vector3 = link["head"] if lower == from else link["foot"]
			if at == Vector3.INF:
				return near
			# Already on the flight: commit to the far end.
			var foot: Rect2 = Rect2(Vector2(link["min"]),
					Vector2(link["max"]) - Vector2(link["min"]))
			return far if foot.grow(1.2).has_point(Vector2(at.x, at.z)) else near
		step = back
	return Vector3.INF


## Is every deck on the layer reachable on foot from its room's ground floor?
##
## The killability law, cutting both ways: a perch a player can stand on and a
## Sentinel cannot walk to is a camping spot. Drops are deliberately excluded from
## the deck graph, so this is a statement about ramps, stairs and catwalks only.
func unreachable_decks() -> Array[int]:
	var out: Array[int] = []
	for deck: Dictionary in decks:
		var id: int = int(deck["id"])
		if deck_waypoint(int(deck["room"]), -1, id) == Vector3.INF:
			out.append(id)
	return out


## Every way this layer's verticality could be wrong, as a list of strings. Empty
## is the only shippable answer and `Debug._vertical_selftest` asserts it across a
## matrix of seeds and depths.
##
## The three laws, in order:
##
##   1. **Killability both ways.** Every deck is reachable on foot from grade by
##      ramp/stair/catwalk. Drops are excluded from the deck graph, so a perch
##      whose only entrance was a one-way ledge fails here — as it should: it
##      would be a place a player can stand and a Sentinel cannot.
##   2. **The solo invariant.** Nothing that occupies the ground volume stands in
##      a doorway aisle, in the room's central crossing, or on a fixture. The
##      spawn-to-shaft walk stays flat, jump-free and unobstructed.
##   3. **Walkability.** Every slope is under Godot's 45 degree floor limit with
##      margin, and every route is wide enough for the widest body in the game.
func vertical_violations() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()

	for id: int in unreachable_decks():
		out.append("deck %d (%s, room %d) has no route from grade" % [
			id, String(decks[id]["kind"]), int(decks[id]["room"])])

	for deck: Dictionary in decks:
		var room: Dictionary = rooms[int(deck["room"])]
		var foot: Rect2 = Rect2(Vector2(deck["min"]),
				Vector2(deck["max"]) - Vector2(deck["min"]))
		if not _within(_kit_rect(room["min"], room["max"]), foot):
			out.append("deck %d escapes room %d" % [int(deck["id"]), int(deck["room"])])
		if not bool(deck["solid"]):
			continue
		if not _ground_clear(room, foot):
			out.append("deck %d (%s) blocks the ground route in room %d" % [
				int(deck["id"]), String(deck["kind"]), int(deck["room"])])
		if deck.has("cut") and not _ground_clear(room, deck["cut"] as Rect2):
			out.append("excavation for deck %d blocks the ground route" % int(deck["id"]))

	for link: Dictionary in deck_links:
		var foot: Rect2 = Rect2(Vector2(link["min"]),
				Vector2(link["max"]) - Vector2(link["min"]))
		var rise: float = absf(float(link["y1"]) - float(link["y0"]))
		var run: float = foot.size.x if String(link["axis"]) == "x" else foot.size.y
		var width: float = foot.size.y if String(link["axis"]) == "x" else foot.size.x
		if run > 0.01 and rad_to_deg(atan2(rise, run)) > 40.0:
			out.append("route %d->%d in room %d is %.1f degrees" % [
				int(link["a"]), int(link["b"]), int(link["room"]),
				rad_to_deg(atan2(rise, run))])
		if width < 3.0:
			out.append("route %d->%d in room %d is only %.1f m wide" % [
				int(link["a"]), int(link["b"]), int(link["room"]), width])
		if String(link["kind"]) != LINK_CATWALK and not _ground_clear(
				rooms[int(link["room"])], foot) and float(link["y0"]) <= 0.01:
			out.append("route %d->%d blocks the ground route in room %d" % [
				int(link["a"]), int(link["b"]), int(link["room"])])
		# M6.7, law 4: a LEVEL span has to physically REACH both decks it claims to
		# join. Reachability was a statement about edges in a dictionary, and a
		# gantry arm authored round the wrong corner satisfied every other line in
		# this function while standing three metres above the flight that was
		# supposed to serve it. A ramp or a stair is exempt because it MEETS its
		# decks at its ends by construction, in the third dimension; a catwalk is
		# the same height at both ends, so its footprint is the whole claim.
		if String(link["kind"]) != LINK_CATWALK:
			continue
		for end_deck: int in [int(link["a"]), int(link["b"])]:
			if end_deck < 0 or end_deck >= decks.size():
				continue
			var span: Rect2 = Rect2(Vector2(decks[end_deck]["min"]),
					Vector2(decks[end_deck]["max"]) - Vector2(decks[end_deck]["min"]))
			# Abutting rectangles do not "intersect" in float arithmetic, so the
			# tolerance is the whole reason this reads as touching rather than as
			# overlapping.
			if not foot.grow(0.05).intersects(span):
				out.append("catwalk %d->%d in room %d does not reach deck %d" % [
					int(link["a"]), int(link["b"]), int(link["room"]), end_deck])

	# Nothing on the critical path may be standing on a deck. The crew arrives at
	# grade, walks at grade and rides the trunk down from grade.
	var critical: Dictionary = {"spawn": spawns, "shaft": [shaft_point] as Array[Vector3]}
	if is_backdoor:
		critical["node"] = [backdoor_point] as Array[Vector3]
		critical["uplink"] = [uplink_point] as Array[Vector3]
	for label: String in critical:
		for point: Vector3 in (critical[label] as Array[Vector3]):
			if absf(point.y) > 0.01 or deck_at(point) >= 0:
				out.append("%s at %s is not at grade" % [label, str(point)])

	return out


## Elevation bands for the vertical-aware minimap (next milestone).
##
## One entry per walkable region on the layer, ground floors included, so a
## minimap can slice the layer by level without knowing anything about decks:
##
##   {room:int, region:int, band:int, y:float, kind:String,
##    min:Vector2, max:Vector2}
##
## `band` is the storey index — 0 is grade, 1 is a mezzanine, -1 is a sunken pit —
## and it is the only field a level slider needs. `region` is -1 for a room's
## ground floor and the deck id otherwise, which is exactly the key `deck_at`
## returns for a position, so "which slice is this player on" is one call.
func elevation_bands() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for room: Dictionary in rooms:
		var rect: Rect2 = _kit_rect(room["min"], room["max"])
		out.append({
			"room": int(room["index"]), "region": -1, "band": 0, "y": 0.0,
			"kind": "floor", "min": rect.position, "max": rect.end,
		})
	for deck: Dictionary in decks:
		out.append({
			"room": int(deck["room"]), "region": int(deck["id"]),
			"band": int(deck["band"]), "y": float(deck["y"]),
			"kind": String(deck["kind"]),
			"min": Vector2(deck["min"]), "max": Vector2(deck["max"]),
		})
	return out


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
	lines.append("BANISH PROTOCOL LAYER DUMP")
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

	# --- M6 -----------------------------------------------------------------
	#
	# The hunter entry anchors and the Auditor's route, in the dump for the same
	# reason the Sentinel posts are: two peers that disagree about where a hunter
	# comes in, or about the order the Auditor walks, disagree about a spawn packet
	# and about a streamed pose. Both are derived (no RNG), so these lines are a
	# statement that the derivation is identical on every peer — and being appended
	# last, they move nothing above them.
	for i: int in hunter_nests.size():
		lines.append("  hunter_nest %02d room=%d (%.3f,%.3f,%.3f)" % [
			i, hunter_nest_rooms[i],
			hunter_nests[i].x, hunter_nests[i].y, hunter_nests[i].z])
	lines.append("  auditor_route %s" % str(auditor_route()))

	# --- M6.6 verticality ----------------------------------------------------
	#
	# Decks, routes and ledges are geometry the crew walks on and the antivirus
	# paths over, so they belong in the dump for exactly the reason the room rects
	# do: two peers that disagree about where a catwalk is disagree about where a
	# Sentinel can stand. Derived rather than rolled, so — as with the hunter
	# anchors above — these lines are a statement that the derivation is identical
	# on every peer, and they move nothing above them.
	for deck: Dictionary in decks:
		var dlo: Vector2 = deck["min"]
		var dhi: Vector2 = deck["max"]
		lines.append("  deck %02d room=%d %-9s band=%d y=%.3f solid=%d loot=%d min=(%.3f,%.3f) max=(%.3f,%.3f)" % [
			int(deck["id"]), int(deck["room"]), String(deck["kind"]), int(deck["band"]),
			float(deck["y"]), 1 if bool(deck["solid"]) else 0,
			1 if bool(deck["loot"]) else 0, dlo.x, dlo.y, dhi.x, dhi.y])
	for link: Dictionary in deck_links:
		var llo: Vector2 = link["min"]
		var lhi: Vector2 = link["max"]
		lines.append("  route %d->%d room=%d %-7s axis=%s dir=%+d y=%.3f..%.3f min=(%.3f,%.3f) max=(%.3f,%.3f)" % [
			int(link["a"]), int(link["b"]), int(link["room"]), String(link["kind"]),
			String(link["axis"]), int(link["dir"]), float(link["y0"]), float(link["y1"]),
			llo.x, llo.y, lhi.x, lhi.y])
	for drop: Dictionary in deck_drops:
		var at: Vector3 = drop["at"]
		lines.append("  drop deck=%d room=%d h=%.3f (%.3f,%.3f,%.3f)" % [
			int(drop["deck"]), int(drop["room"]), float(drop["height"]),
			at.x, at.y, at.z])
	for i: int in perch_points.size():
		lines.append("  perch %02d deck=%d (%.3f,%.3f,%.3f)" % [
			i, perch_decks[i], perch_points[i].x, perch_points[i].y, perch_points[i].z])
	lines.append("  storeys %s" % str(room_storeys))
	# Room names last: they are derived rather than rolled, but a dump that prints
	# them is a dump that catches a rename breaking every terminal answer.
	var names: PackedStringArray = PackedStringArray()
	for i: int in rooms.size():
		names.append(room_name(i))
	lines.append("  names %s" % " ".join(names))

	return "\n".join(lines)
