class_name PatchPlacement
extends RefCounted
## Where M9's two vessels stand. The whole of the patch system's contact with
## world generation, deliberately shaped as ONE static call so the integration
## into `ProcLayerBuilder` is a single line that can be added and removed without
## touching anything else in a 2400-line file three agents share.
##
## ## THE MOTIVATION LAW IS THE PLACEMENT RULE (DESIGN.md pillar 6)
##
## "Detail must be *justified*, not scattered — the generator asks 'does this make
## sense here?' per element." A pickup is the easiest thing in a game to scatter
## and the worst thing to scatter, because a collectible lying in an empty
## corridor is the single clearest signal that a level was generated rather than
## built. So neither vessel here has a position of its own; each one BORROWS a
## position from something the layer already justified:
##
##   POCKET SECRETARY — somebody's slate, put down while they worked. The only
##   legal anchors are the layer's own evidence of work, which the builder has
##   already resolved by the time this runs:
##     * a tripod WORK LIGHT      a lamp somebody is coming back for. The slate is
##                                beside the toolbox, in the pool of the lamp.
##     * a COMMAND TERMINAL       on the desk shelf, beside the keys. The most
##                                literal reading of "somebody was working here".
##     * a LOOT CABINET           at the foot of the locker it came out of.
##     * a REWIRE JUNCTION        on the deck under an opened bus panel.
##   No work on the layer, no slates. That is correct, not a gap.
##
##   ANOMALY CACHE — MOTHER's quarantine pod, so it stands where she would put
##   one: in the vault she guards, or failing that in an unlit quarantine block,
##   or failing that in the deepest machine space. Never in the arrival room,
##   never in the shaft room, never in a sanctuary (nothing hostile or valuable
##   goes in a backdoor room — the campfire is sacred).
##
## ## Determinism
##
## Every decision below is `DecalLib.roll` of a WORLD POSITION and the layer seed
## — the same idiom the signage, the clutter and the work lights use, and for the
## same reason (DESIGN.md's determinism law). The builder's `_rng` stream is never
## touched, so adding this pass moved nothing else on any layer, and the
## `--dumplayer` determinism dump — which renders `LayerGraph`, not the builder —
## is byte-for-byte what it was before M9 existed.

## Salts. Distinct from every other consumer of `DecalLib.roll` in the project so
## two passes never draw the same number from the same square metre.
const SALT_SLATE_PICK: int = 7301
const SALT_SLATE_SLIDE: int = 7307
const SALT_CACHE_ANGLE: int = 7321
const SALT_CACHE_RADIUS: int = 7331
const SALT_CACHE_YAW: int = 7333

## How far from the anchor a slate is set down, and how far it may slide along.
const SLATE_STANDOFF: float = 0.62
const SLATE_SLIDE: float = 0.45
## Height of a command terminal's desk shelf in the terminal's own space, and how
## far along it the slate sits. Matched to `CommandTerminal.MOUNT_HEIGHT` and the
## shelf it builds at `MOUNT_HEIGHT - 0.06` with a 0.09 m top.
const DESK_HEIGHT: float = 1.04
const DESK_FORWARD: float = 0.30
const DESK_LATERAL: float = 0.46

## How far off the room centre the anomaly pod stands, and the inset it keeps
## from the graph rect so a snapped shell can never leave it inside a wall.
const CACHE_RADIUS_MIN: float = 1.1
const CACHE_RADIUS_MAX: float = 2.8
const CACHE_WALL_INSET: float = 2.6
## Clearance the pod keeps from anything the crew stands at or shoots through.
const CACHE_CLEARANCE: float = 2.4


## Stands this layer's pocket secretaries and, on the layers that earn one, its
## anomaly cache. Returns a census fragment for the build log, the same shape
## `_prop_note` and `clutter_note` already use.
##
## `prop_spots` and `work_lights` are the builder's own resolved lists —
## `{kind, index, room, pos, yaw}` and `{pos, yaw, room, toolbox, caster, kind}`
## — passed in rather than re-derived, because the whole point is that these
## vessels stand at anchors somebody ELSE justified.
static func place(parent: Node, graph: LayerGraph, prop_spots: Array[Dictionary],
		work_lights: Array[Dictionary]) -> String:
	if parent == null or graph == null:
		return ""
	var slates: int = _place_slates(parent, graph, prop_spots, work_lights)
	var cache: int = _place_cache(parent, graph, prop_spots)
	return " patches=[slate %d, anomaly %d]" % [slates, cache]


# ----------------------------------------------------------------- the slates --

static func _place_slates(parent: Node, graph: LayerGraph,
		prop_spots: Array[Dictionary], work_lights: Array[Dictionary]) -> int:
	var wanted: int = Patches.slate_count(graph.layer_number)
	var candidates: Array[Dictionary] = _slate_candidates(graph, prop_spots, work_lights)
	if candidates.is_empty():
		return 0

	# Two passes over a FIXED candidate order. The first takes the anchors that
	# roll under the bar, which spreads the slates across kinds and rooms rather
	# than filling the first four; the second backfills if the layer was unlucky,
	# so the count is a guarantee and the *placement* is the roll. Order-stable by
	# construction, which is what makes two peers agree.
	var chosen: Array[int] = []
	var used: Dictionary = {}
	for pass_index: int in 2:
		for c: int in candidates.size():
			if chosen.size() >= wanted:
				break
			if used.has(c):
				continue
			var probe: Vector3 = candidates[c]["pos"]
			if pass_index == 0 and DecalLib.roll(probe.x, probe.z, SALT_SLATE_PICK,
					graph.layer_seed) > 0.55:
				continue
			used[c] = true
			chosen.append(c)
		if chosen.size() >= wanted:
			break

	for i: int in chosen.size():
		var spot: Dictionary = candidates[chosen[i]]
		var at: Vector3 = spot["pos"]
		# The rarity is read from the SAME roll the pickup will use, so the screen
		# a player reads across a dark room is telling them the truth — there is one
		# roll, computed identically on every peer, and the prop is a view of it.
		var tier: int = Balance.patch_tier(
				Patches.preview(Patches.KIND_SLATE, i, graph.layer_number))
		parent.add_child(PocketSecretary.create(i, at, float(spot["yaw"]), tier))
	return chosen.size()


## Every place on this layer a person could plausibly have put a slate down, in a
## fixed order. Work lights first because they are the strongest story (a lamp
## aimed at unfinished work, with a toolbox beside it), then the terminal desk,
## then the lockers and the opened panels.
static func _slate_candidates(graph: LayerGraph, prop_spots: Array[Dictionary],
		work_lights: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for lamp: Dictionary in work_lights:
		var stand: Vector3 = lamp["pos"]
		var yaw: float = float(lamp["yaw"])
		# Beside the tripod, on the side the power block is not on — where somebody
		# knelt. `FidelityWorkLight`'s block sits at local (+0.86, 0, +1.15), so the
		# slate goes to the other hand.
		var right: Vector3 = Vector3(cos(yaw), 0.0, -sin(yaw))
		var at: Vector3 = stand - right * 0.58 + Vector3(0.0, 0.02, 0.0)
		out.append({"pos": at, "yaw": yaw + PI * 0.35})

	for spot: Dictionary in prop_spots:
		var kind: String = String(spot["kind"])
		if kind != "terminal" and kind != "cabinet" and kind != "junction":
			continue
		var anchor: Vector3 = spot["pos"]
		var yaw: float = float(spot["yaw"])
		# The wall props are built with their detailed face on local +Z (the same
		# convention `GeometryKit._wall_slot` uses), so this is the direction out
		# into the room.
		var out_dir: Vector3 = Vector3(sin(yaw), 0.0, cos(yaw))
		var along: Vector3 = Vector3(out_dir.z, 0.0, -out_dir.x)
		var slide: float = (DecalLib.roll(anchor.x, anchor.z, SALT_SLATE_SLIDE,
				graph.layer_seed) - 0.5) * 2.0 * SLATE_SLIDE
		if kind == "terminal":
			# ON THE DESK. The most literal "somebody was working here" the layer
			# has, and the reading the user asked for by name.
			var side: float = DESK_LATERAL
			if DecalLib.roll(anchor.x, anchor.z, SALT_SLATE_SLIDE + 1,
					graph.layer_seed) < 0.5:
				side = -DESK_LATERAL
			out.append({
				"pos": anchor + out_dir * DESK_FORWARD + along * side
						+ Vector3(0.0, DESK_HEIGHT, 0.0),
				"yaw": yaw + PI,
			})
			continue
		out.append({
			"pos": anchor + out_dir * SLATE_STANDOFF + along * slide
					+ Vector3(0.0, 0.02, 0.0),
			"yaw": yaw + PI * (0.4 if kind == "cabinet" else 0.7),
		})
	return out


# ------------------------------------------------------------------ the cache --

static func _place_cache(parent: Node, graph: LayerGraph,
		prop_spots: Array[Dictionary]) -> int:
	if not Patches.layer_has_anomaly(graph.layer_number):
		return 0
	var room: int = _cache_room(graph)
	if room < 0:
		return 0
	var centre: Vector3 = graph.centre_of(room)
	var rect: Rect2 = _graph_rect(graph.rooms[room])
	# Off the centre by a hashed angle and radius: dead centre is where a
	# generator puts a prop and where a building never does, and the vault's own
	# dressing owns the middle of the floor.
	var angle: float = DecalLib.roll(centre.x, centre.z, SALT_CACHE_ANGLE,
			graph.layer_seed) * TAU
	var radius: float = CACHE_RADIUS_MIN + DecalLib.roll(centre.x, centre.z,
			SALT_CACHE_RADIUS, graph.layer_seed) * (CACHE_RADIUS_MAX - CACHE_RADIUS_MIN)

	var at: Vector3 = centre
	# Eight candidate bearings off the same hashed start, taking the first that is
	# clear. A pod that spawned inside a Compiler is a pod nobody can open, and
	# rotating around the room is cheaper and more legible than giving up.
	for attempt: int in 8:
		var probe: Vector3 = centre + Vector3(cos(angle + float(attempt) * TAU / 8.0),
				0.0, sin(angle + float(attempt) * TAU / 8.0)) * radius
		probe.x = clampf(probe.x, rect.position.x + CACHE_WALL_INSET,
				rect.end.x - CACHE_WALL_INSET)
		probe.z = clampf(probe.z, rect.position.y + CACHE_WALL_INSET,
				rect.end.y - CACHE_WALL_INSET)
		probe.y = centre.y
		if _cache_spot_clear(graph, prop_spots, probe):
			at = probe
			break
		at = probe

	# Faced at the middle of the room it stands in, so its lit face and its slot
	# present to the space the crew walks through rather than to the masonry — the
	# same rule the Compiler's own facing follows.
	var toward: Vector3 = centre - at
	var yaw: float = DecalLib.roll(at.x, at.z, SALT_CACHE_YAW, graph.layer_seed) * TAU
	if toward.length_squared() > 0.04:
		yaw = atan2(-toward.x, -toward.z)
	parent.add_child(AnomalyCache.create(0, at, yaw))
	return 1


## Which room MOTHER would quarantine something in. Vault first (it is the room
## she already guards), then an unlit block (a quarantine nest), then the deepest
## machine space. Never arrival, never the shaft room, and never a sanctuary.
static func _cache_room(graph: LayerGraph) -> int:
	var fallback: int = -1
	var unlit: int = -1
	for room: Dictionary in graph.rooms:
		var index: int = int(room["index"])
		var archetype: String = String(room["archetype"])
		if archetype == LayerGraph.ARRIVAL or archetype == LayerGraph.SHAFT \
				or archetype == LayerGraph.BACKDOOR:
			continue
		if index == graph.shaft_index:
			continue
		if archetype == LayerGraph.VAULT:
			return index
		if unlit < 0 and bool(room.get("unlit", false)):
			unlit = index
		fallback = index
	return unlit if unlit >= 0 else fallback


static func _cache_spot_clear(graph: LayerGraph, prop_spots: Array[Dictionary],
		probe: Vector3) -> bool:
	for spot: Dictionary in prop_spots:
		var pos: Vector3 = spot["pos"]
		if Vector2(probe.x - pos.x, probe.z - pos.z).length() < CACHE_CLEARANCE:
			return false
	# Everything the crew stops moving at keeps its distance: a chest-high pod in
	# a muster radius or on a Compiler's approach is a pod somebody walks into for
	# the length of a channel.
	var stations: Array[Vector3] = []
	stations.append_array(graph.siphon_points)
	stations.append_array(graph.compiler_points)
	stations.append_array(graph.spawns)
	stations.append(graph.shaft_point)
	for point: Vector3 in stations:
		if Vector2(probe.x - point.x, probe.z - point.z).length() < CACHE_CLEARANCE + 1.4:
			return false
	# And off the verticality, for the reason the M6.6 playtest reported: a solid
	# prop inside a plinth footprint is a prop half-buried in a plinth.
	for deck: Dictionary in graph.decks:
		if not bool(deck["solid"]):
			continue
		var lo: Vector2 = deck["min"]
		var hi: Vector2 = deck["max"]
		if probe.x > lo.x - 1.0 and probe.x < hi.x + 1.0 \
				and probe.z > lo.y - 1.0 and probe.z < hi.y + 1.0:
			return false
	return true


## The graph's own rect for a room. Deliberately the GRAPH rect rather than the
## builder's snapped shell: this class is static and self-contained by design (one
## line of integration), and the generous `CACHE_WALL_INSET` covers the couple of
## metres snapping can move a wall by.
static func _graph_rect(room: Dictionary) -> Rect2:
	var lo: Vector2 = room["min"]
	var hi: Vector2 = room["max"]
	return Rect2(lo, hi - lo)
