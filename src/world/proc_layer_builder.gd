class_name ProcLayerBuilder
extends GeometryKit
## Turns a LayerGraph into standing architecture.
##
## M2 built this from CSG boxes and hairline emissive strips. M3.7 rebuilt the
## shell from the look-dev kit — 13 beveled modules stamped onto a 4 m lattice —
## and replaced the single-fixture lighting with the four-layer LightRig recipe.
## The dressing (data blocks, glyph panels, conduits, the sanctuary colonnade) is
## still built from boxes, because that is furniture and the kit is architecture.
##
## Everything here is deterministic: the only randomness comes from a generator
## seeded off `graph.layer_seed`, so two peers on the same layer place the same
## crate in the same corner. Nothing about the build is replicated. The kit's own
## variant choice does not even use that generator — it hashes the world position
## (GeometryKit._pick), so retuning the decoration can never shift the layout.
##
## Lighting is the load-bearing art decision. DESIGN.md pillar 2 — "unrendered
## space is near-black" — means a layer must be *mostly dark*. The kit makes that
## harder to hold, because a four-layer rig wants to look like a film set; the
## discipline that keeps it dark is that keys are tight cones through gobos aimed
## at the FLOOR, accents rake along a wall face rather than fill a room, and most
## corridors get nothing at all. If you can cross a room without your beam on,
## the layer is wrong.

var graph: LayerGraph = null

var _rng: RandomNumberGenerator = null
var _taps: Array[SiphonTap] = []
var _shaft: DropShaft = null
## Snapped footprint per room index. The graph rect is what the generator agreed
## on and what the determinism dump prints; this is the shell that actually got
## built, and it is what the dressing has to fit inside.
var _rects: Array[Rect2] = []
## The layer's longest corridor, which is always lit. Most corridors are dark on
## purpose, but a layer needs one legible artery — DESIGN.md's own navigation
## rule is "follow the light to find the gate", and a layer where every route is
## black is a maze rather than a building.
var _trunk_corridor: String = ""

## Reading height for wall signage. Above the kit's trace channel at 0.95 and
## below the pipe runs, which is also roughly where a person hangs a sign.
const DECAL_HEIGHT: float = 2.05

# --- M4.8 functional clutter -------------------------------------------------
#
# Two passes, and they are deliberately different in kind.
#
#   **Density** (`_clutter_room` / `_clutter_corridor`) is decoration: cable
#   looms, pipe runs, rubble, stains, crates, the occasional dead drone. All of
#   it is hashed off world position and the layer seed like the signage is, none
#   of it touches `_rng`, and almost none of it collides. Its budget is draw
#   calls, and ClutterLib spends that budget by putting everything that repeats
#   into two MultiMeshes for the whole layer.
#
#   **Function** (`_place_props`) is the levers: the rewire junction, the
#   weldable vents, the cabinets, the bulkhead and the command terminal. Those
#   ARE in the determinism dump, resolved by LayerGraph from the run seed, and
#   this file only turns each anchor into a standing object.
#
## Where a wall prop's origin sits, for the runs that do not consult the kit's
## own relief (the cable looms and pipe clusters, which lie along a wall rather
## than hang off one). Functional props go through `_wall_prop`, which reads the
## actual module depth — see GeometryKit.WALL_RELIEF.
const WALL_PROP_INSET: float = WALL_THICKNESS * 0.5 + 0.02
## How far a wall prop keeps from a snapped doorway centre. The graph already
## cleared the *unsnapped* door by 3.4 m; snapping can move a doorway by up to
## two metres, so the projection re-checks against where the doorframe actually
## went and shuffles the prop along the wall if it has to.
const WALL_PROP_DOOR_CLEAR: float = 3.0

## How much room a crate stack leaves around a functional prop. Wide enough that
## the breaker's line to a vent and the interact ray to a junction are both clear
## from anywhere a player would reasonably stand.
const CRATE_PROP_CLEAR: float = 3.6
## And how far apart two FUNCTIONAL props have to be. A tour found the case:
## layer 8 put a rewire junction on the slot in front of a vent, and the
## breaker's line of sight — correctly — hit the junction instead of the grille,
## so the vent could not be welded. Props are allowed to share a wall; they are
## not allowed to stand in front of each other.
const PROP_SEPARATION: float = 2.6

## M4.95: at most this many god-ray hero shafts per layer. Scarcity is what makes
## a motif a motif — "a room with three shafts has weather, a room with one has a
## hole in it" (HUB_NOTES §10; INTEGRATION2 §4).
const MAX_SHAFTS: int = 2

var _clutter: ClutterLib = null
## M4.95: god-ray hero-shaft specs, keyed by room index -> {pos, ceiling}. Planned
## in `_plan_shafts` BEFORE the shells are built (so the ceiling field can omit the
## aperture cell), and consumed in `_light_room` to spawn the full GodRays unit.
var _shaft_specs: Dictionary = {}
## M4.95: batched trim transforms, per trim module, flushed into MultiMeshes once.
## Baseboards and corner posts run the whole perimeter of every room — hundreds of
## instances — so they go through a MultiMesh (a few draw calls) exactly like the
## clutter, or the wall/floor seam pass would cost the soak its 60 fps on its own.
var _trim_batches: Dictionary = {}
## Resolved transforms for the functional props, filled before the density pass.
## `{kind, index, room, pos, yaw}`.
var _prop_spots: Array[Dictionary] = []
## Circles nothing solid may be dressed inside. See `_blocks_a_prop`.
var _keep_out: Array[Dictionary] = []
## One line for the layer census. "The world got denser" is a claim about
## generation, and a claim about generation belongs in a log.
var clutter_note: String = ""
var _prop_note: String = ""
## M6.6 census line: what vertical vocabulary this layer actually got.
var _vertical_note: String = ""


static func create(from_graph: LayerGraph) -> ProcLayerBuilder:
	var builder: ProcLayerBuilder = ProcLayerBuilder.new()
	builder.name = "ProcLayerBuilder"
	builder.graph = from_graph
	builder.light_scale = float(from_graph.params["light_scale"])
	# The architecture-decay pass hashes off these two and nothing else — see
	# GeometryKit's DECAY_* block for why it must never touch `_rng`.
	builder.layer_number = from_graph.layer_number
	builder.layer_seed = from_graph.layer_seed
	return builder


func _build_content() -> void:
	if graph == null:
		push_error("[ProcLayerBuilder] no graph")
		return

	# A stream of its own, so tuning the dressing never shifts the layout.
	_rng = RandomNumberGenerator.new()
	_rng.seed = hash(str(graph.layer_seed, ":dressing"))
	# Position-hashed, never `_rng` — see the class docstring and ClutterLib's.
	_clutter = ClutterLib.new(_geometry, graph.layer_seed)

	KitLib.load_kit()
	# The kit's alert uniform is on shared material resources, so it survives a
	# descent. Clear it or a layer entered while the last one was screaming comes
	# up already red.
	KitLib.set_alert(0.0)

	var longest: float = -1.0
	for corridor: Dictionary in graph.corridors:
		var span: float = maxf(kit_corridor_rect(corridor).size.x,
				kit_corridor_rect(corridor).size.y)
		if span > longest:
			longest = span
			_trunk_corridor = String(corridor["id"])

	# M4.95: decide the god-ray hero shafts BEFORE the shells go up, so the ceiling
	# field can leave the aperture cell open — a shaft is a hole with a light behind
	# it, and the hole is not optional (INTEGRATION2 §4).
	_plan_shafts()
	# M6.6: and the excavations, for the same reason and one step earlier — a
	# sunken nest is a hole in the floor field and in the slab collider, and the
	# generator has to know about it before it stamps either.
	_plan_excavations()

	_rects.resize(graph.rooms.size())
	for room: Dictionary in graph.rooms:
		_rects[int(room["index"])] = kit_room(room)
	for corridor: Dictionary in graph.corridors:
		kit_corridor(corridor)

	# Where every functional prop is going to stand, resolved as soon as the
	# shells exist and long before anything is dressed. Everything that puts a
	# solid object on a floor — the archetype dressing's loose blocks and racks,
	# and the density pass's crate stacks — consults this list and keeps out of
	# the way. A tour caught why it has to: two of layer 7's three vents could not
	# be welded, because something the dressing had stood in front of them was
	# breaking the breaker's line of sight to the grille, and decoration is not
	# allowed to disable a mechanic.
	# M6.6: the decks, their routes and the structure holding them up. Built
	# straight after the shells and before anything is dressed, so the keep-out
	# pass below can treat a plinth as a solid object and the archetype dressing
	# never stands a rack inside one.
	_build_verticality()

	_resolve_prop_spots()
	_build_keep_out()

	for room: Dictionary in graph.rooms:
		_dress_room_decals(room)
	for corridor: Dictionary in graph.corridors:
		_dress_corridor_decals(corridor)

	for room: Dictionary in graph.rooms:
		# M6.6: a tall room gets its overhead structure before its lights, so a key
		# aimed at the floor has girders and pipe racks to break on.
		_technical_ceiling_for(room)
		_light_room(room)
		# M4.95: one box-projected interior ReflectionProbe per room — free light in
		# a darkness-law game (a reflection adds apparent brightness without a lumen),
		# and the trim/corner modules that kill the wall/floor greybox seam.
		_add_probe(room)
		_trim_room(room)
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

	for room: Dictionary in graph.rooms:
		_clutter_room(room)
	for corridor: Dictionary in graph.corridors:
		_clutter_corridor(corridor)

	_place_furniture()
	_place_props()

	var draws: int = _clutter.flush()
	draws += _flush_trim()
	clutter_note = " clutter=[%s] batched=%d shafts=%d%s%s" % [
		_clutter.describe(), draws, _shaft_specs.size(), _prop_note, _vertical_note]


## The shell a room actually got, rather than the rect the generator asked for.
func _rect_of(room: Dictionary) -> Rect2:
	var index: int = int(room["index"])
	if index >= 0 and index < _rects.size() and _rects[index].size.x > 0.0:
		return _rects[index]
	return kit_rect(room["min"], room["max"])


## Built height, which is the storey-quantised one, not the graph's float.
static func _height_of(room: Dictionary) -> float:
	return float(kit_storeys(float(room["h"]))) * STOREY


# ------------------------------------------------------------------- signage --
#
# Everything below is placed from a hash of world position and the layer seed
# rather than from `_rng` — see DecalLib's class docstring. That keeps the
# `--dumplayer` determinism dump byte-identical to what it was before M3.7 while
# still giving every peer the same signs in the same places.

## The message set a room's archetype earns. A vault warns you what it is; a
## nest warns you what is past the bulkhead; the sanctuary says nothing at all,
## because MOTHER does not know it is still there.
func _decal_menu(room: Dictionary) -> Array:
	var deep: bool = graph.layer_number >= 6
	var base: Array = DecalLib.PROPAGANDA.duplicate()
	base.append_array(DecalLib.GLYPHS)
	if deep:
		# The builders' signage only survives down where the architecture is old
		# enough to predate MOTHER going quiet.
		base.append_array(DecalLib.LEGACY)

	match String(room["archetype"]):
		LayerGraph.VAULT:
			return ["way_vault", "warn_purge", "prop_mercy", "glyph_teal",
					"prop_report"]
		LayerGraph.SIPHON:
			return ["way_siphon", "prop_cycles", "glyph_amber", "prop_idle"]
		LayerGraph.SHAFT:
			return ["way_trunk", "prop_cycles", "glyph_teal"]
		LayerGraph.BACKDOOR:
			# A sanctuary is a maintenance node MOTHER has forgotten. The only
			# writing in it is older than she is.
			return DecalLib.LEGACY + ["glyph_amber"]
		_:
			if bool(room.get("unlit", false)):
				return ["warn_dead", "prop_mercy"] + DecalLib.GLYPHS
			return base


## Two to five plates per room, hung on the wall slots at reading height and
## never on a doorway. Kept off the trace channels and away from the corners,
## where a sign would be edge-on to everything.
func _dress_room_decals(room: Dictionary) -> void:
	var rect: Rect2 = _rect_of(room)
	var menu: Array = _decal_menu(room)
	if menu.is_empty():
		return
	var depth: float = float(graph.params["depth"])
	var seed_value: int = graph.layer_seed
	var doors: Array = room.get("doors", []) as Array
	var placed: int = 0
	var wanted: int = 3 if String(room["archetype"]) == LayerGraph.ARRIVAL else 4

	for side: int in 4:
		var horizontal: bool = side % 2 == 0
		var fixed: float = rect.position.y if side == 0 else (
				rect.end.x if side == 1 else (
				rect.end.y if side == 2 else rect.position.x))
		var from: float = rect.position.x if horizontal else rect.position.y
		var to: float = rect.end.x if horizontal else rect.end.y
		# Wall slot centres, same lattice the modules sit on — but never the first
		# or last slot on a wall. Those are the corners, `kit_room` stands a rib
		# column in each of them, and a sign half-eaten by a column reads as a
		# bug rather than as wear.
		var t: float = from + CELL * 1.5
		while t < to - CELL - 0.01 and placed < wanted:
			var at: Vector3 = Vector3(t, DECAL_HEIGHT, fixed) if horizontal \
					else Vector3(fixed, DECAL_HEIGHT, t)
			t += CELL
			if _slot_has_door(doors, side, at):
				continue
			if DecalLib.roll(at.x, at.z, side, seed_value) > 0.34:
				continue
			var name: String = DecalLib.pick(menu, at.x, at.z, side, seed_value)
			var yaw: float = _decal_yaw(side)
			# Pushed a few centimetres off the boundary so the projector box
			# straddles the wall face rather than starting inside it.
			var normal: Vector3 = Vector3(sin(deg_to_rad(yaw)), 0.0, cos(deg_to_rad(yaw)))
			DecalLib.place(_geometry,
					DecalLib.variant(name, depth, at.x, at.z, seed_value),
					at + normal * 0.1, yaw, DecalLib.WIDE)
			placed += 1

	_dress_room_numeral(room, rect)


## The layer number, big, on the arrival room's wall. The crew's one moment of
## orientation is also the one moment they are told how deep they are.
func _dress_room_numeral(room: Dictionary, rect: Rect2) -> void:
	if String(room["archetype"]) != LayerGraph.ARRIVAL:
		return
	var digits: String = "%02d" % mini(graph.layer_number, 99)
	var centre: Vector2 = rect.position + rect.size * 0.5
	for i: int in 2:
		DecalLib.place(_geometry, "num_" + digits[i],
				Vector3(centre.x + (-0.95 if i == 0 else 0.95), 2.6,
						rect.position.y + 0.1),
				0.0, DecalLib.SQUARE, 0.85)


## Corridors get the wayfinding, because a corridor is where you are deciding
## which way to go. The trunk arrow points at the real drop shaft — it is a
## navigation aid that happens to also be set dressing, which is the only kind
## worth authoring.
func _dress_corridor_decals(corridor: Dictionary) -> void:
	var rect: Rect2 = kit_corridor_rect(corridor)
	if rect.size.x < CELL or rect.size.y < CELL:
		return
	var seed_value: int = graph.layer_seed
	var depth: float = float(graph.params["depth"])
	var along: bool = String(corridor["axis"]) == "z"
	var length: float = rect.size.y if along else rect.size.x
	var lo: float = rect.position.y if along else rect.position.x
	var mid: Vector2 = rect.position + rect.size * 0.5

	# Which end of this corridor is closer to the way down. If a sign is going to
	# point somewhere it should point somewhere true.
	var shaft: Vector3 = graph.shaft_point
	var t: float = lo + CELL * 0.5
	while t < lo + length - 0.01:
		for wall: int in 2:
			var fixed: float = (rect.position.x if wall == 0 else rect.end.x) if along \
					else (rect.position.y if wall == 0 else rect.end.y)
			var at: Vector3 = Vector3(fixed, DECAL_HEIGHT, t) if along \
					else Vector3(t, DECAL_HEIGHT, fixed)
			if DecalLib.roll(at.x, at.z, 31 + wall, seed_value) > 0.3:
				continue
			var toward: float = (shaft.z - t) if along else (shaft.x - t)
			var menu: Array = ["way_trunk" if toward > 0.0 else "way_trunk_l",
					"prop_idle", "prop_foreign", "glyph_teal", "prop_report"]
			if graph.layer_number >= 6:
				menu.append_array(DecalLib.LEGACY)
			var name: String = DecalLib.pick(menu, at.x, at.z, 31 + wall, seed_value)
			var yaw: float = 0.0
			if along:
				yaw = 90.0 if wall == 0 else -90.0
			else:
				yaw = 0.0 if wall == 0 else 180.0
			var normal: Vector3 = Vector3(sin(deg_to_rad(yaw)), 0.0, cos(deg_to_rad(yaw)))
			DecalLib.place(_geometry,
					DecalLib.variant(name, depth, at.x, at.z, seed_value),
					at + normal * 0.1, yaw, DecalLib.WIDE)
		t += CELL


## Whether a wall slot is a doorway. Signage across an opening reads as a bug.
func _slot_has_door(doors: Array, side: int, at: Vector3) -> bool:
	var wall: String = "n" if side == 0 else ("e" if side == 1 else
			("s" if side == 2 else "w"))
	var horizontal: bool = side % 2 == 0
	for door: Dictionary in doors:
		if String(door.get("wall", "")) != wall:
			continue
		var centre: float = snap_slot(float(door.get("at", 0.0)))
		if absf(centre - (at.x if horizontal else at.z)) < CELL * 0.75:
			return true
	return false


## Wall-facing yaw, matching GeometryKit's slot convention.
static func _decal_yaw(side: int) -> float:
	match side:
		0:
			return 0.0
		1:
			return -90.0
		2:
			return 180.0
		_:
			return 90.0


# ------------------------------------------------------------------- lights --

## The four-layer recipe, per room. LightRig's one rule is *no light does two
## jobs*, and the reason the old single-fixture lighting looked cheap is that
## every conduit node was doing all four at once.
##
## Shadow budget: only the key layer casts, and never more than two per room.
## Every player in a four-crew also carries a shadow-casting beam, so the
## environment simply cannot afford more.
func _light_room(room: Dictionary) -> void:
	# Nests get nothing at all. An unlit room is the darkest thing on a layer and
	# the only place a Scrubber is comfortable — the two facts are the same fact.
	if bool(room["unlit"]):
		return

	var rect: Rect2 = _rect_of(room)
	var height: float = _height_of(room)
	var mid: Vector2 = rect.position + rect.size * 0.5
	var archetype: String = String(room["archetype"])
	var count: int = int(graph.params["room_light_count"])

	# The arrival room is the crew's one moment of orientation, so it always gets
	# the full complement plus a little more energy. The sanctuary is the other
	# exception: it is meant to feel safe, and dark is not safe.
	var warm: bool = archetype == LayerGraph.BACKDOOR
	var boost: float = 0.0
	if archetype == LayerGraph.ARRIVAL:
		count += 1
		boost = 1.2
	elif archetype == LayerGraph.BACKDOOR:
		count += 2
		boost = 2.0

	var span: float = maxf(rect.size.x, rect.size.y)
	var reach: float = span + 8.0
	var index: int = int(room["index"])

	# M4.95: when a hero shaft is the room's key light, its other fixtures must not
	# front-light the figure standing in the shaft (§4 rule 3: "a figure standing in
	# front of a light rather than in front of a window"). So the washes drop to 55%
	# and the keys to 40% — the shaft becomes the room's key and everything else
	# recedes, which is what silhouettes the crew and creatures against it.
	var has_shaft: bool = _shaft_specs.has(index)
	var shaft_accent: float = 0.55 if has_shaft else 1.0
	var shaft_key: float = 0.40 if has_shaft else 1.0

	# --- wall wash ---------------------------------------------------------
	#
	# One grazing light per wall, mounted low and close to that wall and aimed
	# ALONG it rather than at it. This is the single most important pass in the
	# room and the first version of this merge got it wrong: keys mounted at the
	# ceiling and thrown across a 24 m room delivered nothing to either wall, and
	# the result was exactly the failure the kit exists to fix — glowing inlays
	# floating on unlit black panels.
	#
	# Grazing light is the only thing that reveals a 6 mm chamfer or a 60 mm
	# panel recess. Perpendicular light reveals neither.
	for side: int in 4:
		var start: float = 0.06 if side % 2 == 0 else 0.94
		var finish: float = 0.94 if side % 2 == 0 else 0.06
		var wash: SpotLight3D = LightRig.accent(_fixtures,
				_wall_point(rect, side, 0.85, _rng.randf_range(2.4, 3.2), start),
				_wall_point(rect, side, 0.35, _rng.randf_range(1.0, 1.8), finish),
				(_rng.randf_range(2.1, 3.0) + boost * 0.5) * light_scale * shaft_accent,
				LightRig.AMBER if warm else LightRig.KEY_COLD,
				# NARROW, not wide. A 70-degree cone is the showcase's number, and
				# it is right for a 10 m wall; pointed 24 m down a generated room's
				# wall the same cone is nearly a hemisphere, the energy goes into
				# the fog and the wall it was supposed to graze stays black.
				_rng.randf_range(26.0, 36.0), LightRig.GOBO_DUST, reach)
		wash.name = "Accent_wash_r%d_%d" % [index, side]

	# --- keys --------------------------------------------------------------
	#
	# One or two shadow casters, no more: every player in a four-crew also
	# carries a shadow-casting beam, so the environment's budget is tiny. These
	# rake along a wall from a low mount — the same angle as the wash, but tight,
	# bright, gobo'd and casting, so the rib columns throw structure across the
	# floor.
	var keys: int = clampi(count - 1, 1, 2)
	var gobos: Array[String] = [LightRig.GOBO_SLATS, LightRig.GOBO_GRATE]
	# Exactly one dying fixture per room, and never in the room that is not lying
	# to you. Two is a gimmick — the eye adapts in about four seconds.
	var dying: int = -1
	if archetype != LayerGraph.BACKDOOR \
			and _rng.randf() < lerpf(0.28, 0.6, float(graph.params["depth"])):
		dying = _rng.randi_range(0, keys - 1)

	for i: int in keys:
		var side: int = _rng.randi_range(0, 3)
		var along: float = _rng.randf_range(0.08, 0.3)
		var mount: Vector3 = _wall_point(rect, side, 1.6, _rng.randf_range(2.7, 3.4), along)
		var target: Vector3 = _wall_point(rect, side, 0.3, _rng.randf_range(0.9, 1.6),
				along + 0.6)
		var key: SpotLight3D = LightRig.key(_fixtures, mount, target,
				(_rng.randf_range(3.6, 5.0) + boost * 0.8) * light_scale * shaft_key,
				gobos[i % gobos.size()], _rng.randf_range(42.0, 52.0),
				LightRig.AMBER if warm else LightRig.KEY_COLD, reach)
		key.name = "Key_r%d_%d" % [index, i]
		if i == dying:
			LightRig.flicker(key, FlickerLight.Mode.DYING, float(index) * 1.7)

	# --- hero shaft --------------------------------------------------------
	#
	# M4.95: the two-storey special rooms planned in `_plan_shafts` get the FULL
	# god-ray unit — a real hole in the ceiling, a slotted aperture plate whose
	# slats CAST into the beam, the raked cold light, a LOCAL fog volume and dust
	# motes for scale (GodRays.hero_shaft). The two numbers that hold the darkness
	# law: LOW light_energy (it lights the floor pool, not the walls) and HIGH fog
	# energy (the shaft is bright because the AIR is, not the room). Depth dims
	# both, but never below readable. Every other room keeps the cheap aperture
	# cone below — a gobo'd shaft through the haze with no physical opening.
	if has_shaft:
		var spec: Dictionary = _shaft_specs[index]
		GodRays.hero_shaft(_geometry, _fixtures, _fixtures,
				spec["pos"] as Vector3, float(spec["ceiling"]),
				Vector2(1.5, 3.2), Vector3(1.4, 0.0, 0.6),
				(2.2 + boost * 0.4) * clampf(light_scale, 0.62, 1.0),
				3, 9.0 * clampf(light_scale, 0.7, 1.0))
	else:
		# One aperture cone straight down at the middle of the room. Unshadowed on
		# purpose: its job is the volumetric shaft through the haze, and a shadow
		# map for a light pointing at an empty floor is the most expensive way in
		# the engine to buy nothing.
		LightRig.key(_fixtures, Vector3(mid.x, height - 0.4, mid.y),
				Vector3(mid.x, 0.0, mid.y),
				(_rng.randf_range(2.2, 3.4) + boost * 0.7) * light_scale,
				LightRig.GOBO_APERTURE, _rng.randf_range(46.0, 58.0),
				LightRig.AMBER if warm else LightRig.KEY_COLD,
				height + 6.0, false).name = "Key_shaft_r%d" % index

	# --- ceiling wash ------------------------------------------------------
	#
	# Two-storey rooms only. The kit's ceiling modules carry emissive slots, and
	# eight metres up with nothing lighting them those slots are bright dashes
	# floating in a black void — the same failure as an unlit trace channel, just
	# above your head. One dim wide cone aimed up fixes it for one light.
	if height > STOREY + 0.1:
		LightRig.accent(_fixtures, Vector3(mid.x, height * 0.42, mid.y),
				Vector3(mid.x + rect.size.x * 0.2, height, mid.y - rect.size.y * 0.2),
				0.60 * light_scale, LightRig.AMBER if warm else LightRig.KEY_COLD,
				64.0, LightRig.GOBO_DUST, height * 1.6).name = "Accent_up_r%d" % index

	# --- practicals --------------------------------------------------------
	#
	# Short range, low energy, sat where the emissive geometry is, so light in
	# the room always has a visible source. Deliberately feeble: a practical that
	# lights the room stops being a fixture and becomes the room's ambient, and
	# then the darkness the whole game rests on is gone.
	for i: int in count:
		var at: Vector2 = mid + Vector2(_rng.randf_range(-1.0, 1.0),
				_rng.randf_range(-1.0, 1.0)) * (rect.size * 0.32)
		var colour: Color = LightRig.AMBER if (warm or _rng.randf() < 0.18) else Color(
				_rng.randf_range(0.26, 0.34), _rng.randf_range(0.78, 0.88), 1.0)
		LightRig.practical(_fixtures, Vector3(at.x, _rng.randf_range(2.0, 3.0), at.y),
				_rng.randf_range(0.35, 0.7) * light_scale,
				_rng.randf_range(4.0, 6.0), colour).name = "Practical_r%d_%d" % [index, i]


# ------------------------------------------------------------- M4.95 filmic --
#
# God-ray hero shafts, per-room reflection probes, and the trim/corner modules
# that kill the wall/floor greybox seam. All three are deterministic — driven by
# archetype, room geometry and position, never `_rng` — so the layer a peer sees
# matches every other peer's exactly.

## Choose up to MAX_SHAFTS two-storey special rooms for a god-ray and mark each
## one's aperture cell, so the ceiling field (built next) leaves it open. Runs
## before the shells; consumed later by `_light_room`.
func _plan_shafts() -> void:
	ceiling_apertures.clear()
	_shaft_specs.clear()
	for room: Dictionary in graph.rooms:
		if _shaft_specs.size() >= MAX_SHAFTS:
			break
		if bool(room.get("unlit", false)):
			continue
		var arch: String = String(room["archetype"])
		if arch != LayerGraph.VAULT and arch != LayerGraph.SHAFT \
				and arch != LayerGraph.BACKDOOR:
			continue
		# Two-storey volume only: an 8 m shaft cannot be composed at the player's FOV
		# from inside a 4 m room without aiming the camera up (§4 rule 2).
		if _height_of(room) < STOREY * 2.0 - 0.1:
			continue
		var rect: Rect2 = kit_rect(room["min"], room["max"])
		# Enough room around the aperture to frame the shaft and keep its fog box off
		# the walls.
		if rect.size.x < CELL * 2.5 or rect.size.y < CELL * 2.5:
			continue
		var mid: Vector2 = rect.position + rect.size * 0.5
		# snap_slot lands on the same {CELL/2 + n*CELL} lattice the ceiling field
		# uses, so the omitted cell and the aperture plate line up exactly.
		var cell: Vector2 = Vector2(snap_slot(mid.x), snap_slot(mid.y))
		var index: int = int(room["index"])
		ceiling_apertures[index] = cell
		_shaft_specs[index] = {
			"pos": Vector3(cell.x, 0.0, cell.y),
			"ceiling": _height_of(room),
		}


# ------------------------------------------------------- M6.6 verticality --

## Excavations, from the graph's sunken decks. Runs before the shells so
## `kit_room` can leave the hole out of the floor field and out of the slab.
func _plan_excavations() -> void:
	floor_cuts.clear()
	for deck: Dictionary in graph.decks:
		if not deck.has("cut"):
			continue
		var room: int = int(deck["room"])
		if not floor_cuts.has(room):
			floor_cuts[room] = [] as Array[Rect2]
		(floor_cuts[room] as Array[Rect2]).append(deck["cut"] as Rect2)


## Stands every deck, route and ledge the graph authored.
##
## Nothing here decides anything. Which rooms are tall, where a gallery hangs,
## which wall a stair climbs and where a ledge opens are all resolved in
## `LayerGraph._plan_decks` and printed by `--dumplayer`; this turns each
## rectangle into metal, and records the solid ones in the keep-out list so no
## later pass drops a crate inside a plinth.
func _build_verticality() -> void:
	var counts: Dictionary = {}
	for deck: Dictionary in graph.decks:
		var kind: String = String(deck["kind"])
		counts[kind] = int(counts.get(kind, 0)) + 1
		var rect: Rect2 = Rect2(Vector2(deck["min"]), Vector2(deck["max"]) - Vector2(deck["min"]))
		var y: float = float(deck["y"])
		var room: Dictionary = graph.rooms[int(deck["room"])]
		var shell: Rect2 = _rect_of(room)

		if deck.has("cut"):
			deck_excavation(deck["cut"] as Rect2, y)
			# A sunken deck needs no platform of its own — the excavation floor IS
			# the deck — and no railing, because you are already at the bottom.
			continue

		# Which edges face the room rather than a wall. A gallery bolted to the west
		# wall gets rails on the other three; a catwalk in mid-air gets all four.
		var open: Array = []
		for side: int in 4:
			var edge: Dictionary = _edge_of(rect, side)
			var from: Vector2 = edge["from"]
			var to: Vector2 = edge["to"]
			var at: Vector2 = (from + to) * 0.5
			var against_wall: bool = absf(at.x - shell.position.x) < 0.3 \
					or absf(at.x - shell.end.x) < 0.3 \
					or absf(at.y - shell.position.y) < 0.3 \
					or absf(at.y - shell.end.y) < 0.3
			if not against_wall:
				open.append(side)

		var gaps: Array = []
		for drop: Dictionary in graph.deck_drops:
			if int(drop["deck"]) == int(deck["id"]):
				gaps.append(drop["at"])

		var grated: bool = kind == LayerGraph.DECK_MEZZANINE \
				or kind == LayerGraph.DECK_CATWALK \
				or kind == LayerGraph.DECK_CONTROL \
				or kind == LayerGraph.DECK_GANTRY
		deck_platform(rect, y, grated, open, gaps)


	for link: Dictionary in graph.deck_links:
		# A catwalk link is a pure routing edge: the span itself is a DECK and was
		# built above. Building it again here would double every catwalk on the
		# layer and put two colliders in the same place.
		if String(link["kind"]) == LayerGraph.LINK_CATWALK:
			continue
		var foot: Rect2 = Rect2(Vector2(link["min"]), Vector2(link["max"]) - Vector2(link["min"]))
		deck_ramp(foot, String(link["axis"]), int(link["dir"]),
				float(link["y0"]), float(link["y1"]),
				String(link["kind"]) == LayerGraph.LINK_STAIR)

	for drop: Dictionary in graph.deck_drops:
		_drop_marker(drop)

	if not counts.is_empty():
		var parts: PackedStringArray = PackedStringArray()
		for kind: String in counts:
			parts.append("%s %d" % [kind, int(counts[kind])])
		parts.sort()
		_vertical_note = " decks=[%s] routes=%d ledges=%d" % [
			", ".join(parts), graph.deck_links.size(), graph.deck_drops.size()]


## The hazard plate that says "you can step off here".
##
## Readability is the whole feature. A drop-down is a risk/reward decision and a
## player cannot decide anything about a ledge they did not see: the railing is
## already broken at this point (GeometryKit._railing leaves the gap), and this
## adds the striped nosing and a downward-throwing practical so the break reads
## as an opening rather than as a missing rail.
func _drop_marker(drop: Dictionary) -> void:
	var at: Vector3 = drop["at"]
	var dir: Vector3 = drop["dir"]
	var across: Vector3 = Vector3(dir.z, 0.0, -dir.x)
	var stripe: StandardMaterial3D = _make_emissive(SYSTEM_AMBER, 0.55)
	# Stripes ACROSS the lip, not tiles on it: long on the edge axis, thin on the
	# axis you walk off. The first version was 0.4 m square and, seen from where a
	# player actually stands (a metre back, looking down), read as three amber
	# slabs lying on the deck rather than as a painted nosing.
	# Length must stay well under the pitch below or the stripes merge into one
	# continuous amber bar — which is what the first pass did, and a solid bar reads
	# as a painted kerb rather than as hazard marking.
	var long: float = 0.52
	var thin: float = 0.16
	var size: Vector3 = Vector3(
			lerpf(thin, long, absf(across.x)), 0.045,
			lerpf(thin, long, absf(across.z)))
	for i: int in 5:
		var offset: float = (float(i) - 2.0) * 0.78
		_mesh_box(at + across * offset - dir * 0.30 + Vector3(0.0, 0.025, 0.0),
				size, stripe)
	# Aimed DOWN off the lip, so the thing the ledge is above is the thing that
	# lights up — you should be able to see what you are about to land on.
	LightRig.practical(_fixtures, at + dir * 0.5 + Vector3(0.0, -0.35, 0.0),
			0.5 * light_scale, 6.0, LightRig.AMBER).name = "Practical_ledge_%d_%d" % [
					int(at.x), int(at.z)]


## Overhead structure for every room the generator built tall.
##
## The cable trays leave a wall riser and arrive at something that USES power —
## the room's own conduit trunk, its drop shaft, its Compiler — which is the same
## FROM-a-source-TO-a-load grammar the wall cables have followed since M4.8, moved
## up to the girders. A tall room with nothing between the racks and the ceiling
## is exactly the empty volume the intricacy law forbids.
func _technical_ceiling_for(room: Dictionary) -> void:
	var height: float = _height_of(room)
	if height < STOREY * 1.5:
		return
	var rect: Rect2 = _rect_of(room)
	var mid: Vector2 = rect.position + rect.size * 0.5
	var index: int = int(room["index"])

	var loads: Array = []
	if index == graph.shaft_index:
		loads.append(graph.shaft_point)
	for i: int in graph.compiler_rooms.size():
		if graph.compiler_rooms[i] == index:
			loads.append(graph.compiler_points[i])
	for i: int in graph.siphon_rooms.size():
		if graph.siphon_rooms[i] == index:
			loads.append(graph.siphon_points[i])
	for i: int in graph.junction_rooms.size():
		if graph.junction_rooms[i] == index:
			loads.append(graph.junction_points[i])
	if loads.is_empty():
		# Every tall room has SOMETHING in the middle of it that the racks and the
		# lighting hang off; if the generator gave this one no named load, the room's
		# own centre column is the load.
		loads.append(Vector3(mid.x, 2.4, mid.y))
	technical_ceiling(rect, height, loads)


## One box-projected, interior ReflectionProbe per lit room (INTEGRATION2 §5). SSR
## only reflects what is on screen; the probe fills the hole — the bright emissive
## strip behind the camera that SSR cannot see. UPDATE_ONCE because the geometry
## never moves; the atlas count is capped in project.godot, and THAT is the VRAM
## cost, not the probes.
func _add_probe(room: Dictionary) -> void:
	if bool(room.get("unlit", false)):
		return
	var rect: Rect2 = _rect_of(room)
	var height: float = _height_of(room)
	var mid: Vector2 = rect.position + rect.size * 0.5
	var probe: ReflectionProbe = ReflectionProbe.new()
	probe.name = "Probe_r%d" % int(room["index"])
	probe.position = Vector3(mid.x, height * 0.98, mid.y)
	probe.size = Vector3(rect.size.x, height, rect.size.y)
	# Capture from eye height, not the ceiling: a cubemap shot from 8 m up reflects
	# the tops of everything and a room the player never stands in.
	probe.origin_offset = Vector3(0.0, -height * 0.98 + 1.7, 0.0)
	probe.box_projection = true
	probe.interior = true
	probe.enable_shadows = false
	probe.max_distance = 48.0
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	_fixtures.add_child(probe)


## Baseboards along every wall at the floor line, plus a vertical post at every
## corner — the kit trim that kills the wall/floor and wall/wall greybox seams.
## Collected into per-module batches and flushed into MultiMeshes by `_flush_trim`.
func _trim_room(room: Dictionary) -> void:
	if not KitLib.has("BASEBOARD_4M"):
		return
	var rect: Rect2 = _rect_of(room)
	var doors: Array = room.get("doors", []) as Array
	# Yaws match the wall runs in kit_room, so a baseboard's detailed +Z face lands
	# against the same wall face the modules above it show.
	_baseboard_run("x", rect.position.y, rect.position.x, rect.end.x, 0.0,
			_door_centres(doors, "n"))
	_baseboard_run("x", rect.end.y, rect.position.x, rect.end.x, 180.0,
			_door_centres(doors, "s"))
	_baseboard_run("z", rect.position.x, rect.position.y, rect.end.y, 90.0,
			_door_centres(doors, "w"))
	_baseboard_run("z", rect.end.x, rect.position.y, rect.end.y, -90.0,
			_door_centres(doors, "e"))
	if KitLib.has("CORNER_TRIM_V"):
		# Yaw orients the post's two 35 mm faces onto the two walls meeting at the
		# corner: NW faces +X/+Z (yaw 0), and round from there.
		_trim_at("CORNER_TRIM_V", Vector3(rect.position.x, 0.0, rect.position.y), 0.0)
		_trim_at("CORNER_TRIM_V", Vector3(rect.position.x, 0.0, rect.end.y), 90.0)
		_trim_at("CORNER_TRIM_V", Vector3(rect.end.x, 0.0, rect.position.y), -90.0)
		_trim_at("CORNER_TRIM_V", Vector3(rect.end.x, 0.0, rect.end.y), 180.0)


## Snapped doorway centres on one wall, so a 4 m baseboard is not laid across a
## doorway.
func _door_centres(doors: Array, wall: String) -> Array:
	var out: Array = []
	for door: Dictionary in doors:
		if String(door.get("wall", "")) == wall:
			out.append(GeometryKit.snap_slot(float(door.get("at", 0.0))))
	return out


func _baseboard_run(axis: String, fixed: float, from: float, to: float,
		yaw: float, doors: Array) -> void:
	var t: float = from + CELL * 0.5
	while t < to - 0.01:
		var is_door: bool = false
		for d: float in doors:
			if absf(t - d) < CELL * 0.5:
				is_door = true
		if not is_door:
			var pos: Vector3 = Vector3(t, 0.0, fixed) if axis == "x" \
					else Vector3(fixed, 0.0, t)
			_trim_at("BASEBOARD_4M", pos, yaw)
		t += CELL


func _trim_at(module: String, pos: Vector3, yaw_deg: float) -> void:
	if not _trim_batches.has(module):
		_trim_batches[module] = [] as Array[Transform3D]
	(_trim_batches[module] as Array[Transform3D]).append(
			Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(yaw_deg), 0.0)), pos))


## Flush the collected trim into one MultiMeshInstance3D per module. The trim mesh
## carries its own per-surface materials (M_PanelDark / M_PanelTrim), so there is
## no material_override and the whole layer's baseboards cost one draw call per
## surface instead of one per baseboard. Returns the draw calls added.
func _flush_trim() -> int:
	var draws: int = 0
	for module: String in _trim_batches:
		var xforms: Array = _trim_batches[module] as Array
		var mesh: Mesh = KitLib.mesh(module)
		if xforms.is_empty() or mesh == null:
			continue
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = xforms.size()
		for i: int in xforms.size():
			mm.set_instance_transform(i, xforms[i] as Transform3D)
		var inst: MultiMeshInstance3D = MultiMeshInstance3D.new()
		inst.name = "Trim_%s" % module
		inst.multimesh = mm
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_geometry.add_child(inst)
		draws += mesh.get_surface_count()
	_trim_batches.clear()
	return draws


## A point on one of a rect's four walls. `side` is 0=north(-Z) 1=east(+X)
## 2=south(+Z) 3=west(-X); `inset` pushes it into the room, `along` is 0..1 down
## the wall's length. Keeps the light-placement maths in one place instead of
## four nearly-identical match arms.
static func _wall_point(rect: Rect2, side: int, inset: float, y: float,
		along: float) -> Vector3:
	var t: float = clampf(along, 0.0, 1.0)
	match side:
		0:
			return Vector3(lerpf(rect.position.x, rect.end.x, t), y, rect.position.y + inset)
		1:
			return Vector3(rect.end.x - inset, y, lerpf(rect.position.y, rect.end.y, t))
		2:
			return Vector3(lerpf(rect.position.x, rect.end.x, t), y, rect.end.y - inset)
		_:
			return Vector3(rect.position.x + inset, y, lerpf(rect.position.y, rect.end.y, t))


## Most corridors are unlit on purpose: a lit corridor is a corridor you can
## cross without committing your beam, and that is the whole tension. The ones
## that do get something get a single key raking across the width, which throws
## the rib columns' shadows down the length as you walk.
func _light_corridor(corridor: Dictionary) -> void:
	var trunk: bool = String(corridor["id"]) == _trunk_corridor
	# Roll regardless, then override: the RNG stream must not depend on which
	# corridor happens to be longest, or two peers with different float rounding
	# in that comparison would dress the whole layer differently.
	var roll: float = _rng.randf()
	if not trunk and roll > float(graph.params["corridor_light_chance"]):
		return
	var rect: Rect2 = kit_corridor_rect(corridor)
	if rect.size.x < CELL or rect.size.y < CELL:
		return
	var mid: Vector2 = rect.position + rect.size * 0.5

	var id: String = String(corridor["id"])
	var along: String = "z" if String(corridor["axis"]) == "z" else "x"
	var length: float = rect.size.y if along == "z" else rect.size.x
	var lo: float = rect.position.y if along == "z" else rect.position.x
	var cross: float = mid.x if along == "z" else mid.y

	# Fixtures every 8 m down the length, alternating sides, rather than one in
	# the middle. A single mid-corridor key leaves both ends black, and the ends
	# are where the player actually stands — the first version of this merge shot
	# a corridor from its mouth and photographed four metres of nothing.
	#
	# Exactly one of them casts. The rest are accents: same grazing angle across
	# the width, same gobo, no shadow map. In a four-crew the players' own beams
	# have already eaten the shadow budget.
	var slots: int = maxi(int(length / 6.0), 2)
	var caster: int = _rng.randi_range(0, slots - 1)
	for i: int in slots:
		var t: float = lo + (float(i) + 0.5) * (length / float(slots))
		var side: float = 1.45 if i % 2 == 0 else -1.45
		var mount: Vector3 = Vector3(cross + side, STOREY - 0.45, t) if along == "z" \
				else Vector3(t, STOREY - 0.45, cross + side)
		# Aimed hard ACROSS the corridor and slightly down its length: the beam
		# lands on the opposite wall at a grazing angle, which is the only way the
		# chamfers and panel recesses in the kit ever show up.
		var target: Vector3 = Vector3(cross - side * 1.2, 0.55, t - 1.6) if along == "z" \
				else Vector3(t - 1.6, 0.55, cross - side * 1.2)
		var energy: float = _rng.randf_range(2.4, 3.6) * light_scale
		if i == caster:
			var key: SpotLight3D = LightRig.key(_fixtures, mount, target, energy,
					LightRig.GOBO_SLATS if i % 2 == 0 else LightRig.GOBO_GRATE, 54.0)
			key.name = "Key_c%s_%d" % [id, i]
			# One dying fixture in a corridor is a corridor you do not want to be
			# standing in. Two would be a strobe.
			if _rng.randf() < 0.3:
				LightRig.flicker(key, FlickerLight.Mode.DYING, float(i) * 2.3)
		else:
			LightRig.accent(_fixtures, mount, target, energy * 0.55,
					LightRig.KEY_COLD, 58.0, LightRig.GOBO_DUST,
					16.0).name = "Accent_c%s_%d" % [id, i]
		# The floor spine, so the inlay running down the middle of the corridor
		# actually casts instead of just glowing.
		LightRig.practical(_fixtures,
				Vector3(cross, 0.32, t) if along == "z" else Vector3(t, 0.32, cross),
				0.42 * light_scale, 3.8).name = "Practical_c%s_%d" % [id, i]


# ----------------------------------------------------------------- archetypes --

## Injection point: the aperture the crew was written in through, a red scan
## sweep watching the room, and enough light to get your bearings once.
func _dress_arrival(room: Dictionary) -> void:
	var rect: Rect2 = _rect_of(room)
	var centre: Vector2 = rect.position + rect.size * 0.5
	var h: float = _height_of(room)

	_build_scan_sweep(Vector3(centre.x, h - 0.6, centre.y))

	# Port on the south wall, facing back into the room.
	var port_z: float = rect.end.y - 0.22
	_mesh_box(Vector3(centre.x, 3.0, port_z), Vector3(7.0, 6.0, 0.12), MAT_CONDUIT)
	_port_ring(Vector3(centre.x, 3.0, port_z - 0.08), 6.4, 5.4)
	_mesh_box(Vector3(centre.x, 3.0, port_z - 0.08), Vector3(0.09, 5.0, 0.06), _gate_material)

	_conduit_run(Vector3(rect.position.x + 0.9, h - 1.2, rect.position.y + 1.4),
			Vector3(rect.position.x + 0.9, h - 1.2, rect.end.y - 1.4), 0.22)
	_conduit_run(Vector3(rect.end.x - 0.9, h - 1.4, rect.position.y + 1.4),
			Vector3(rect.end.x - 0.9, h - 1.4, rect.end.y - 1.4), 0.16)
	_scatter_blocks(room, 4, 0.9, 1.6)


## Siphon junction: the tap plus the machinery feeding it, so the tap reads as
## plumbed into the layer rather than dropped on the floor.
func _dress_siphon(room: Dictionary) -> void:
	var rect: Rect2 = _rect_of(room)
	var h: float = _height_of(room)
	var centre: Vector2 = rect.position + rect.size * 0.5

	for i: int in 3:
		var z: float = lerpf(rect.position.y + 2.4, rect.end.y - 2.4, (float(i) + 0.5) / 3.0)
		_conduit_run(Vector3(rect.position.x + 0.8, h - 1.0, z),
				Vector3(rect.end.x - 0.8, h - 1.0, z), 0.24)
	_conduit_run(Vector3(centre.x, h - 1.0, centre.y), Vector3(centre.x, 2.6, centre.y), 0.3)
	# The hero conduit trunk from the kit, standing where the machinery converges.
	_put("PILLAR_CONDUIT_HERO", Vector3(centre.x, 0.0, centre.y), 0.0)
	LightRig.practical(_fixtures, Vector3(centre.x, 1.9, centre.y),
			0.8 * light_scale, 4.6).name = "Practical_siphon_pillar"
	_scatter_blocks(room, 3, 0.8, 1.3)


## Data vault: racked storage and a glyph panel still holding a process open.
## This is the room the Sentinel stands in and where the haul is.
func _dress_vault(room: Dictionary) -> void:
	var rect: Rect2 = _rect_of(room)
	var centre: Vector2 = rect.position + rect.size * 0.5

	# Two ranks of storage racks running the length of the vault, with loose
	# blocks filling in around them. The racks are the reason the room reads as a
	# vault rather than as a room with crates in it — and the green is now light
	# leaking out of their shelf gaps rather than paint on a box.
	var vault_glow: Color = Color(0.26, 0.92, 0.55)
	var ranks: int = maxi(int(rect.size.x / 6.0) - 1, 2)
	for i: int in ranks:
		var x: float = lerpf(rect.position.x + 4.5, rect.end.x - 4.5,
				(float(i) + 0.5) / float(ranks))
		# Ranks are pushed out toward the side walls rather than sat either side of
		# the middle. The vault's central band is the crew's approach — and it is
		# also where `--goto vault` puts an automated run, which is how this got
		# caught: the first version put a rack exactly where the camera stands and
		# photographed the inside of a crate.
		var offset: float = maxf(rect.size.y * 0.28, 5.5)
		for j: int in 2:
			var z: float = centre.y + (offset if j == 0 else -offset)
			# Drawn first, skipped second: see `_scatter_blocks` for why the stream
			# must not shorten when a rack is dropped for standing on a prop.
			var shelves: int = _rng.randi_range(4, 6)
			if _blocks_a_prop(Vector3(x, 0.0, z)):
				continue
			_data_rack(Vector3(x, 0.0, z), Vector3(2.2, 2.6, 1.0),
					0.0 if j == 0 else PI, vault_glow, shelves)
	_scatter_blocks(room, 7, 0.9, 1.8)
	_glyph_panel(Vector3(centre.x, 0.0, rect.position.y + 1.4), vault_glow)

	# A quarantine bar across the vault: this is what "locked" looks like before
	# there is anything to unlock it with.
	# Quarantine marking, on the FLOOR. It used to be three hairlines strung
	# across the room at head height, which in a snapped vault turned into three
	# red girders crossing the entire frame from any angle a player stands at —
	# it read as a rendering fault, not as "do not cross". On the deck it reads
	# as exactly what it is, and it stays out of the way of the fight.
	var bar: StandardMaterial3D = _make_emissive(Color(1.0, 0.36, 0.26), 0.5)
	var inset: float = 3.2
	for i: int in 2:
		var z: float = rect.position.y + inset if i == 0 else rect.end.y - inset
		_mesh_box(Vector3(centre.x, 0.018, z),
				Vector3(rect.size.x - inset * 2.0, 0.035, 0.11), bar)
	for i: int in 2:
		var x: float = rect.position.x + inset if i == 0 else rect.end.x - inset
		_mesh_box(Vector3(x, 0.018, centre.y),
				Vector3(0.11, 0.035, rect.size.y - inset * 2.0), bar)


## Backdoor node sanctuary. Deliberately unlike every other room on the layer:
## bigger, taller, warm, symmetrical, colonnaded. DESIGN.md makes this the crew's
## one safe place — antivirus never comes in here — and it has to *look* like
## somewhere you can stop running.
func _dress_backdoor(room: Dictionary) -> void:
	var rect: Rect2 = _rect_of(room)
	var h: float = _height_of(room)
	var centre: Vector2 = rect.position + rect.size * 0.5
	var amber: StandardMaterial3D = _make_emissive(SYSTEM_AMBER, 0.8)
	# Derived from the shell that was actually built rather than from
	# BACKDOOR_HALF: the snapped sanctuary is a metre or two larger than the
	# graph's rect, and a colonnade that ignores that ends up inside the wall.
	var radius: float = minf(rect.size.x, rect.size.y) * 0.5 - 3.4

	# A colonnade rather than scattered clutter: the room is architecture, and
	# somebody built it on purpose.
	var columns: int = 6
	for i: int in columns:
		var angle: float = TAU * float(i) / float(columns)
		var at: Vector2 = centre + Vector2(cos(angle), sin(angle)) * radius
		_put("PILLAR_CONDUIT_HERO", Vector3(at.x, 0.0, at.y), rad_to_deg(angle))
		_mesh_box(Vector3(at.x, 1.2, at.y), Vector3(1.2, 0.05, 1.2), amber)
		# Ribs running from every column to the middle: a vault, not a lid.
		_conduit_run(Vector3(at.x, h - 0.55, at.y), Vector3(centre.x, h - 1.6, centre.y), 0.22)
		LightRig.practical(_fixtures, Vector3(at.x, 2.1, at.y),
				0.9 * light_scale, 5.0, LightRig.AMBER).name = "Practical_colonnade_%d" % i

	# Warm floor ring around the middle of the room, wide enough to walk inside.
	var ring: int = 28
	for i: int in ring:
		var angle_r: float = TAU * float(i) / float(ring)
		var at_r: Vector2 = centre + Vector2(cos(angle_r), sin(angle_r)) * (radius - 2.6)
		_mesh_box(Vector3(at_r.x, 0.016, at_r.y), Vector3(0.9, 0.03, 0.12), amber)

	# The one glyph panel on the layer that is telling you something good.
	_glyph_panel(Vector3(centre.x, 0.0, rect.position.y + 1.6), SYSTEM_AMBER)

	# The hearth. Not a LightRig fixture on purpose: this is the one light in the
	# game whose job IS to fill a room, because "safe" is a lighting state and a
	# sanctuary lit like a corridor is not one.
	var hearth: OmniLight3D = OmniLight3D.new()
	hearth.name = "SanctuaryGlow"
	hearth.position = Vector3(centre.x, h - 1.8, centre.y)
	hearth.light_color = SYSTEM_AMBER
	hearth.light_energy = 3.6 * light_scale
	hearth.omni_range = 34.0
	hearth.omni_attenuation = 0.75
	hearth.light_volumetric_fog_energy = 1.6
	hearth.shadow_enabled = false
	hearth.set_meta("authored_energy", hearth.light_energy)
	hearth.set_meta("authored_color", hearth.light_color)
	hearth.set_meta("base_energy", hearth.light_energy)
	_fixtures.add_child(hearth)

	_scatter_blocks(room, 5, 1.0, 1.7)


## A nest. No fixtures at all (see _light_room) and blind wall modules (see
## GeometryKit._wall_slot) — just dark red inlay on the floor, so a beam sweeping
## the room tells you what you have walked into a moment before the sensors light
## up.
func _dress_nest(room: Dictionary) -> void:
	var rect: Rect2 = _rect_of(room)
	var centre: Vector2 = rect.position + rect.size * 0.5
	var rot: StandardMaterial3D = _make_emissive(Color(0.6, 0.08, 0.1), 0.42)

	# Growth radiating from the middle of the room: MOTHER's cleaners have been
	# living here and the architecture has gone over to them.
	var strands: int = _rng.randi_range(5, 8)
	for i: int in strands:
		var angle: float = _rng.randf_range(0.0, TAU)
		var reach: float = _rng.randf_range(3.0, 7.0)
		var to: Vector2 = centre + Vector2(cos(angle), sin(angle)) * reach
		to.x = clampf(to.x, rect.position.x + 1.4, rect.end.x - 1.4)
		to.y = clampf(to.y, rect.position.y + 1.4, rect.end.y - 1.4)
		_trace(Vector3(centre.x, 0.016, centre.y), Vector3(to.x, 0.016, to.y), rot, 0.07)
		_data_block(Vector3(to.x, 0.0, to.y), Vector3.ONE * _rng.randf_range(0.5, 0.9),
				_rng.randf_range(-0.8, 0.8))


## Bus hall: processing stacks that break a beam into slats, and trunk conduits.
func _dress_bus(room: Dictionary) -> void:
	if bool(room["unlit"]):
		_dress_nest(room)
		return

	var rect: Rect2 = _rect_of(room)
	var h: float = _height_of(room)
	var centre: Vector2 = rect.position + rect.size * 0.5

	var stacks: int = _rng.randi_range(2, 4)
	for i: int in stacks:
		var x: float = lerpf(rect.position.x + 3.0, rect.end.x - 3.0,
				(float(i) + 0.5) / float(stacks))
		var z: float = centre.y + _rng.randf_range(-1.5, 1.5)
		# The processing stack is the same rack prop as the vault's, taller and
		# running the system's own teal — one piece of furniture doing two jobs
		# is one silhouette the player learns instead of two.
		var yaw: float = _rng.randf_range(-0.25, 0.25)
		var shelves: int = _rng.randi_range(5, 7)
		if _blocks_a_prop(Vector3(x, 0.0, z)):
			continue
		_data_rack(Vector3(x, 0.0, z), Vector3(1.9, 3.2, 2.4), yaw, SYSTEM_TEAL,
				shelves)
		_conduit_run(Vector3(x, 3.4, z), Vector3(x, h - 0.8, z), 0.28)

	for i: int in 3:
		var cz: float = lerpf(rect.position.y + 2.0, rect.end.y - 2.0, (float(i) + 0.5) / 3.0)
		_conduit_run(Vector3(rect.position.x + 0.9, h - 0.9, cz),
				Vector3(rect.end.x - 0.9, h - 0.9, cz), 0.2)
	_scatter_blocks(room, 3, 0.9, 1.5)


## Drop-shaft trunk: the room is the shaft. Heavy conduits converge on the pad
## and the ceiling opens over it, so the way down is legible from the doorway.
func _dress_shaft(room: Dictionary) -> void:
	var rect: Rect2 = _rect_of(room)
	var h: float = _height_of(room)
	var centre: Vector2 = rect.position + rect.size * 0.5

	for corner: Vector2 in [rect.position + Vector2(1.4, 1.4),
			Vector2(rect.end.x - 1.4, rect.position.y + 1.4),
			Vector2(rect.position.x + 1.4, rect.end.y - 1.4),
			rect.end - Vector2(1.4, 1.4)]:
		_conduit_run(Vector3(corner.x, h - 0.7, corner.y),
				Vector3(centre.x, h - 0.7, centre.y), 0.22)
		_conduit_run(Vector3(corner.x, 0.6, corner.y), Vector3(corner.x, h - 0.7, corner.y), 0.3)

	# Aperture ring in the ceiling, so the trunk visibly leaves the room, lit from
	# above through the aperture gobo: the way down should read as the brightest
	# thing in the room from the doorway.
	var ring: StandardMaterial3D = _make_emissive(Color(0.36, 0.9, 1.0), 0.9)
	for i: int in 4:
		var angle: float = float(i) * PI * 0.5
		var offset: Vector3 = Vector3(cos(angle), 0.0, sin(angle)) * 2.0
		_mesh_box(Vector3(centre.x, h - 0.12, centre.y) + offset,
				Vector3(4.0 if int(i) % 2 == 1 else 0.1, 0.08, 0.1 if int(i) % 2 == 1 else 4.0),
				ring)
	LightRig.key(_fixtures, Vector3(centre.x, h - 0.35, centre.y),
			Vector3(centre.x, 0.0, centre.y), 4.4 * light_scale,
			LightRig.GOBO_APERTURE, 46.0).name = "Key_shaft_aperture"


# ---------------------------------------------------------------- furniture --

## Loose data blocks. Kept clear of the room's middle band so a doorway-to-
## doorway path is never blocked and future navmesh baking stays trivial.
func _scatter_blocks(room: Dictionary, count: int, min_size: float, max_size: float) -> void:
	var rect: Rect2 = _rect_of(room)
	var centre: Vector2 = rect.position + rect.size * 0.5

	for i: int in count:
		var s: float = _rng.randf_range(min_size, max_size)
		var x: float = _rng.randf_range(rect.position.x + 2.4, rect.end.x - 2.4)
		var z: float = _rng.randf_range(rect.position.y + 2.4, rect.end.y - 2.4)
		# Push anything that landed in the central crossing out to the edges.
		if absf(x - centre.x) < 3.0 and absf(z - centre.y) < 3.0:
			x = centre.x + signf(x - centre.x + 0.001) * _rng.randf_range(3.2, 5.0)
			x = clampf(x, rect.position.x + 2.2, rect.end.x - 2.2)
		# Both remaining draws are taken BEFORE the skip below, in the order the
		# argument list used to evaluate them. Dropping a block that would stand in
		# front of a functional prop must not shorten the RNG stream, or every
		# crate, tap and Sentinel post further down the layer moves.
		var height: float = _rng.randf_range(0.7, 1.2)
		var yaw: float = _rng.randf_range(-0.7, 0.7)
		if _blocks_a_prop(Vector3(x, 0.0, z)):
			continue
		_data_block(Vector3(x, 0.0, z), Vector3(s, s * height, s), yaw)


# ------------------------------------------------------- clutter (density) --
#
# How messy a room is, is a property of what the room is FOR. That is the whole
# rule, and it is the difference between "the artist scattered props" and "people
# worked here".
#
#   BUS HALL     the messiest room on the layer. Machinery gets serviced in here
#                and nobody tidies up after themselves: cable looms down two
#                walls, pipes overhead, crates that were stacked "temporarily",
#                spills, and the layer's dead drone if it has one.
#   NEST         a bus hall that has been let go. Everything above, more rubble,
#                scorch instead of seep, and the drone that stopped running in
#                here is still here.
#   SIPHON       industrial rather than messy — this is a plant room, so it is
#                mostly pipework, and what is on the floor is coolant.
#   VAULT        formal. Somebody signs for what happens in a vault. Cable
#                management along the wall base, no crates, one old stain.
#   ARRIVAL      light. It is the crew's one moment of orientation and it should
#                not be a scrapyard.
#   SANCTUARY    tidy. DESIGN.md makes this the one place you can stop running,
#                and a room you can breathe in is a room somebody swept.
const DENSITY: Dictionary = {
	"bus": {"cables": 3, "pipes": 2, "rubble": 3, "crates": 2, "grime": 3, "husk": 0.34,
			"islands": 1, "ducts": 2},
	"nest": {"cables": 3, "pipes": 1, "rubble": 5, "crates": 1, "grime": 4, "husk": 0.5,
			"islands": 1, "ducts": 1},
	"siphon": {"cables": 2, "pipes": 3, "rubble": 2, "crates": 1, "grime": 3, "husk": 0.12,
			"islands": 1, "ducts": 2},
	"vault": {"cables": 2, "pipes": 1, "rubble": 0, "crates": 0, "grime": 1, "husk": 0.0,
			"islands": 0, "ducts": 1},
	"arrival": {"cables": 2, "pipes": 1, "rubble": 1, "crates": 1, "grime": 1, "husk": 0.0,
			"islands": 0, "ducts": 1},
	"shaft": {"cables": 2, "pipes": 2, "rubble": 2, "crates": 1, "grime": 2, "husk": 0.2,
			"islands": 1, "ducts": 2},
	# The sanctuary stays tidy — DESIGN.md's one place you can breathe is a place
	# somebody swept — so no machinery islands and no slung ducts.
	"backdoor": {"cables": 1, "pipes": 0, "rubble": 0, "crates": 0, "grime": 1, "husk": 0.0,
			"islands": 0, "ducts": 0},
}


func _density_for(room: Dictionary) -> Dictionary:
	var archetype: String = String(room["archetype"])
	if archetype == LayerGraph.BUS and bool(room["unlit"]):
		return DENSITY["nest"]
	return DENSITY.get(archetype, DENSITY["bus"]) as Dictionary


## Dresses one room. Everything placed here is decoration: the only thing with a
## collider is a crate stack, and those go against the walls, well outside the
## doorway-to-doorway crossing every creature and every player uses.
func _clutter_room(room: Dictionary) -> void:
	var rect: Rect2 = _rect_of(room)
	var centre: Vector2 = rect.position + rect.size * 0.5
	var height: float = _height_of(room)
	var density: Dictionary = _density_for(room)
	var index: int = int(room["index"])
	var doors: Array = room.get("doors", []) as Array

	# --- cable looms along the wall bases -----------------------------------
	for i: int in int(density["cables"]):
		var side: int = (index * 2 + i) % 4
		var run: Dictionary = _wall_run(rect, side, 2.4)
		if run.is_empty():
			continue
		_clutter.cable_run(run["from"], run["to"], run["normal"])

	# --- pipe clusters overhead ---------------------------------------------
	for i: int in int(density["pipes"]):
		var side: int = (index * 3 + i + 1) % 4
		var run: Dictionary = _wall_run(rect, side, 1.8)
		if run.is_empty():
			continue
		_clutter.pipe_cluster(run["from"], run["to"], run["normal"],
				minf(height - 0.9, 3.15))

	# --- rubble, stains, crates ----------------------------------------------
	#
	# All of it in the band between the walls and the central crossing, which is
	# the same rule `_scatter_blocks` follows and the reason navigation is
	# untouched by this milestone.
	for i: int in int(density["rubble"]):
		var at: Vector3 = _clutter_spot(rect, centre, index * 7 + i, 4001)
		_clutter.rubble_pile(at, 0.85, 7 + int(_clutter.roll(at, 4051) * 6.0))
	for i: int in int(density["grime"]):
		var at: Vector3 = _clutter_spot(rect, centre, index * 11 + i, 4111)
		# Scorch belongs where something burned out; seep belongs where machinery
		# is. A nest gets more of the first, a plant room more of the second.
		var scorch: bool = _clutter.roll(at, 4177) < (
				0.62 if bool(room["unlit"]) else 0.28)
		_clutter.grime(at, scorch, lerpf(2.2, 4.4, _clutter.roll(at, 4231)))
	for i: int in int(density["crates"]):
		var at: Vector3 = _clutter_spot(rect, centre, index * 13 + i, 4297)
		if _blocks_a_door(at, doors, rect) or _blocks_a_prop(at):
			continue
		var yaw: float = _clutter.roll(at, 4337) * TAU
		var tall: bool = _clutter.roll(at, 4391) < 0.4
		var footprint: Vector3 = _clutter.crate_stack(at, yaw, tall)
		# One box proxy per stack. Crates are the only clutter you can walk into,
		# and a proxy per crate would be four times the broadphase for a silhouette
		# the player treats as one object anyway.
		var shape: CollisionShape3D = CollisionShape3D.new()
		var box: BoxShape3D = BoxShape3D.new()
		box.size = Vector3(footprint.x * 1.15, footprint.y, footprint.z * 1.15)
		shape.shape = box
		shape.position = at + Vector3(0.0, footprint.y * 0.5, 0.0)
		shape.rotation.y = yaw
		_colliders.add_child(shape)

	# --- the dead drone -------------------------------------------------------
	var husk_at: Vector3 = _clutter_spot(rect, centre, index * 17, 4441)
	if _clutter.roll(husk_at, 4483) < float(density["husk"]):
		_clutter.drone_husk(husk_at, _clutter.roll(husk_at, 4519) * TAU)

	# --- machinery island, cable-fed from a wall junction (MOTIVATION LAW) -----
	# A routed source->load: a junction box on a wall feeds a machine standing in
	# the room's midground, the cable arcing between them on a true catenary and
	# VIBRATING because the machine runs. In the same band as the crates, kept off
	# doors and the crew's props, so the reading lanes and navigation are untouched.
	if int(density.get("islands", 0)) > 0:
		var m_at: Vector3 = _clutter_spot(rect, centre, index * 19 + 5, 4601)
		if not _blocks_a_door(m_at, doors, rect) and not _blocks_a_prop(m_at):
			var m_side: int = _nearest_wall(rect, m_at)
			var src: Vector3 = _wall_point(rect, m_side, WALL_PROP_INSET, 1.9,
					_wall_along(rect, m_side, m_at))
			var m_yaw: float = atan2(src.x - m_at.x, src.z - m_at.z)
			var fp: Vector3 = _clutter.machinery_island(m_at, m_yaw, src)
			var shape: CollisionShape3D = CollisionShape3D.new()
			var box: BoxShape3D = BoxShape3D.new()
			box.size = Vector3(fp.x * 1.1, fp.y, fp.z * 1.1)
			shape.shape = box
			shape.position = m_at + Vector3(0.0, fp.y * 0.5, 0.0)
			shape.rotation.y = m_yaw
			_colliders.add_child(shape)

	# --- overhead ceiling runs ------------------------------------------------
	# Cable bundles slung across the ceiling, so it reads as worked-on and a beam
	# sweeping up finds something. They SWAY only where this room has a god-ray
	# aperture — a real draught down an open shaft; everywhere else they hang dead
	# still, because a sealed bay has no wind (MOTION FOLLOWS CAUSE).
	var duct_motion: int = ClutterLib.Motion.SWAY if _shaft_specs.has(index) \
			else ClutterLib.Motion.DEAD
	for i: int in int(density.get("ducts", 0)):
		var a: Vector3 = _wall_point(rect, (index + i) % 4, 0.5, height - 0.45,
				0.28 + 0.14 * float(i))
		var b: Vector3 = _wall_point(rect, (index + i + 2) % 4, 0.5, height - 0.45,
				0.72 - 0.14 * float(i))
		_clutter.ceiling_run(a, b, duct_motion)


## Which of a rect's four walls is nearest a point (0=N 1=E 2=S 3=W).
func _nearest_wall(rect: Rect2, at: Vector3) -> int:
	var dn: float = at.z - rect.position.y
	var ds: float = rect.end.y - at.z
	var dw: float = at.x - rect.position.x
	var de: float = rect.end.x - at.x
	var m: float = minf(minf(dn, ds), minf(dw, de))
	if m == dn:
		return 0
	if m == de:
		return 1
	if m == ds:
		return 2
	return 3


## The 0..1 position along a wall nearest a point's projection, kept off the very
## corners.
func _wall_along(rect: Rect2, side: int, at: Vector3) -> float:
	if side % 2 == 0:
		return clampf(inverse_lerp(rect.position.x, rect.end.x, at.x), 0.12, 0.88)
	return clampf(inverse_lerp(rect.position.y, rect.end.y, at.z), 0.12, 0.88)


## A run along one wall of a rect, inset from both corners, plus that wall's
## inward normal. Empty when the wall is too short to be worth dressing.
func _wall_run(rect: Rect2, side: int, inset: float) -> Dictionary:
	var horizontal: bool = side % 2 == 0
	var lo: float = (rect.position.x if horizontal else rect.position.y) + inset
	var hi: float = (rect.end.x if horizontal else rect.end.y) - inset
	if hi - lo < 3.0:
		return {}
	var fixed: float = rect.position.y if side == 0 else (
			rect.end.x if side == 1 else (
			rect.end.y if side == 2 else rect.position.x))
	var normal: Vector3 = LayerGraph.wall_normal(side)
	var from: Vector3 = (Vector3(lo, 0.0, fixed) if horizontal
			else Vector3(fixed, 0.0, lo)) + normal * WALL_PROP_INSET
	var to: Vector3 = (Vector3(hi, 0.0, fixed) if horizontal
			else Vector3(fixed, 0.0, hi)) + normal * WALL_PROP_INSET
	return {"from": from, "to": to, "normal": normal}


## A spot for a loose piece of clutter: in the band between the walls and the
## room's central crossing, hashed rather than rolled.
func _clutter_spot(rect: Rect2, centre: Vector2, index: int, salt: int) -> Vector3:
	var probe: Vector3 = Vector3(rect.position.x + float(index) * 1.7, 0.0,
			rect.position.y + float(index) * 2.3)
	var angle: float = DecalLib.roll(probe.x, probe.z, salt, graph.layer_seed) * TAU
	var reach: float = lerpf(0.55, 0.95,
			DecalLib.roll(probe.x, probe.z, salt + 7, graph.layer_seed))
	var half: Vector2 = rect.size * 0.5 - Vector2(2.4, 2.4)
	var at: Vector2 = centre + Vector2(cos(angle), sin(angle)) * half * reach
	return Vector3(
			clampf(at.x, rect.position.x + 1.6, rect.end.x - 1.6), 0.0,
			clampf(at.y, rect.position.y + 1.6, rect.end.y - 1.6))


## Whether a solid prop at `at` would stand in a doorway's approach. Crates are
## the only thing in the clutter pass that collides, so this is the only place
## navigation can be broken and it is checked once, here.
func _blocks_a_door(at: Vector3, doors: Array, rect: Rect2) -> bool:
	for door: Dictionary in doors:
		var wall: String = String(door.get("wall", ""))
		var centre: float = snap_slot(float(door.get("at", 0.0)))
		var gate: Vector3 = Vector3.ZERO
		match wall:
			"n":
				gate = Vector3(centre, 0.0, rect.position.y)
			"s":
				gate = Vector3(centre, 0.0, rect.end.y)
			"w":
				gate = Vector3(rect.position.x, 0.0, centre)
			_:
				gate = Vector3(rect.end.x, 0.0, centre)
		if Vector2(at.x - gate.x, at.z - gate.z).length() < 5.5:
			return true
	return false


## Whether a solid piece of decoration here would obstruct something the crew
## has to use.
##
## Found by a tour rather than by reasoning, twice over. First: two of layer 7's
## three vents refused to weld, because the dressing had stood a crate between
## the player and the grille and `Player._probe_burnable` was correctly refusing
## to cut through it. Then: an 18-layer soak descended measurably slower than the
## M4.7 build, because the shaft pad had picked up furniture and the descent
## channel — which breaks if you move — kept restarting as the avatar
## depenetrated off it.
##
## So this is not "keep crates off vents", it is **the keep-out list for
## everything the crew stands at**: the drop shaft's whole muster radius, every
## tap, Compiler, node, uplink and injection point, and every M4.8 prop.
## Decoration is not allowed to disable a mechanic and it is not allowed to make
## one feel broken either.
func _blocks_a_prop(at: Vector3, _room_index: int = -1) -> bool:
	for zone: Dictionary in _keep_out:
		var pos: Vector3 = zone["pos"]
		if Vector2(at.x - pos.x, at.z - pos.z).length() < float(zone["radius"]):
			return true
	return false


## Builds that keep-out list. Cheap (a couple of dozen circles, tested against a
## few dozen candidate placements) and worth every comparison.
func _build_keep_out() -> void:
	_keep_out.clear()
	# M6.6 verticality, FIRST — and registered here rather than in
	# `_build_verticality` where it belongs conceptually. It used to live there,
	# and this function's `clear()` above silently wiped every deck and route
	# circle before the dressing ever consulted the list, so racks, loose blocks
	# and crate stacks were free to spawn inside plinths, terraces and pits and on
	# stair footprints. That was the clipping the playtest reported. A keep-out has
	# to be added where the list is assembled, not before it.
	for deck: Dictionary in graph.decks:
		if not bool(deck["solid"]):
			continue
		var lo: Vector2 = deck["min"]
		var hi: Vector2 = deck["max"]
		var mid: Vector2 = (lo + hi) * 0.5
		_keep_out.append({"pos": Vector3(mid.x, 0.0, mid.y),
				"radius": maxf(hi.x - lo.x, hi.y - lo.y) * 0.5 + 1.6})
	for link: Dictionary in graph.deck_links:
		if String(link["kind"]) == LayerGraph.LINK_CATWALK:
			continue
		var rlo: Vector2 = link["min"]
		var rhi: Vector2 = link["max"]
		var rmid: Vector2 = (rlo + rhi) * 0.5
		_keep_out.append({"pos": Vector3(rmid.x, 0.0, rmid.y),
				"radius": maxf(rhi.x - rlo.x, rhi.y - rlo.y) * 0.5 + 1.2})
	for spot: Dictionary in _prop_spots:
		_keep_out.append({"pos": spot["pos"], "radius": CRATE_PROP_CLEAR})
	# The muster radius, plus a body's width. This is the one that matters most:
	# the crew stands in it, motionless, for the length of the descent channel.
	_keep_out.append({"pos": graph.shaft_point,
			"radius": Balance.SHAFT_MUSTER_RADIUS + 1.5})
	for point: Vector3 in graph.siphon_points:
		_keep_out.append({"pos": point, "radius": 4.0})
	for point: Vector3 in graph.compiler_points:
		_keep_out.append({"pos": point, "radius": 4.0})
	for point: Vector3 in graph.spawns:
		_keep_out.append({"pos": point, "radius": 3.0})
	if graph.is_backdoor:
		_keep_out.append({"pos": graph.backdoor_point, "radius": 5.0})
		_keep_out.append({"pos": graph.uplink_point, "radius": 5.5})


## Corridors get cables down both bases, a pipe run overhead and the occasional
## spill. Never a crate: a corridor is one cell wide, it is the only route between
## two rooms, and a solid object in one is a navigation decision rather than a
## piece of decoration.
func _clutter_corridor(corridor: Dictionary) -> void:
	var rect: Rect2 = kit_corridor_rect(corridor)
	if rect.size.x < CELL or rect.size.y < CELL:
		return
	var along: bool = String(corridor["axis"]) == "z"
	var sides: Array[int] = ([3, 1] as Array[int]) if along else ([0, 2] as Array[int])
	for side: int in sides:
		var run: Dictionary = _wall_run(rect, side, 1.2)
		if run.is_empty():
			continue
		_clutter.cable_run(run["from"], run["to"], run["normal"])
	var pipe: Dictionary = _wall_run(rect, sides[0], 1.2)
	if not pipe.is_empty():
		_clutter.pipe_cluster(pipe["from"], pipe["to"], pipe["normal"], 3.05)

	# Two or three loose piles down the length, hard against the wall so the
	# middle of the corridor — which is the line every creature steers along — is
	# never even visually obstructed.
	var mid: Vector2 = rect.position + rect.size * 0.5
	var length: float = rect.size.y if along else rect.size.x
	var lo: float = rect.position.y if along else rect.position.x
	var stops: int = maxi(int(length / 7.0), 1)
	for i: int in stops:
		var t: float = lo + (float(i) + 0.5) * (length / float(stops))
		var offset: float = 1.35 if i % 2 == 0 else -1.35
		var at: Vector3 = Vector3(mid.x + offset, 0.0, t) if along \
				else Vector3(t, 0.0, mid.y + offset)
		if DecalLib.roll(at.x, at.z, 4603, graph.layer_seed) < 0.45:
			_clutter.rubble_pile(at, 0.55, 5)
		if DecalLib.roll(at.x, at.z, 4657, graph.layer_seed) < 0.3:
			_clutter.grime(Vector3(mid.x, 0.0, t) if along else Vector3(t, 0.0, mid.y),
					false, 2.6)


# ------------------------------------------------------ clutter (functional) --

## Turns a graph wall anchor into a standing object's transform.
##
## The graph chose a point on the wall of the room it *asked* for; the kit built
## a shell snapped outward onto the 4 m lattice, and the doorframes moved with
## it. So the point is projected onto the wall that actually exists, clamped
## inside it, and shuffled along if snapping put a doorframe where the prop was
## going to go. Returns {ok, pos, yaw}.
func _wall_prop(room: Dictionary, side: int, anchor: Vector3) -> Dictionary:
	var rect: Rect2 = _rect_of(room)
	var horizontal: bool = side % 2 == 0
	# 3.4 rather than a token margin: `kit_room` stands a RIB_COLUMN two metres in
	# from each corner, and a vent tucked in beside one is a vent whose grille the
	# breaker cannot see past.
	var along: float = anchor.x if horizontal else anchor.z
	var lo: float = (rect.position.x if horizontal else rect.position.y) + 3.4
	var hi: float = (rect.end.x if horizontal else rect.end.y) - 3.4
	if hi <= lo:
		return {"ok": false}
	along = clampf(along, lo, hi)

	var wall: String = "n" if side == 0 else ("e" if side == 1 else
			("s" if side == 2 else "w"))
	for gate: float in _kit_doors(room.get("doors", []) as Array, wall):
		if absf(along - float(gate)) >= WALL_PROP_DOOR_CLEAR:
			continue
		# Shuffle to whichever side of the doorframe still fits on this wall.
		var up: float = float(gate) + WALL_PROP_DOOR_CLEAR
		var down: float = float(gate) - WALL_PROP_DOOR_CLEAR
		if up <= hi:
			along = up
		elif down >= lo:
			along = down
		else:
			return {"ok": false}

	var fixed: float = rect.position.y if side == 0 else (
			rect.end.x if side == 1 else (
			rect.end.y if side == 2 else rect.position.x))
	var normal: Vector3 = LayerGraph.wall_normal(side)
	var dark: bool = bool(room.get("unlit", false))

	# Onto a slot centre, and preferably onto a SHALLOW module.
	#
	# The kit's walls have real depth since M3.7 — raised armour plates stand
	# 0.465 m proud of the boundary, cable trays 0.20 — so "mount it on the wall
	# plane" buries the prop in whatever the slot behind it drew. Two rules fix
	# it: sit on a slot centre (which also lines the prop up with the panel grid
	# instead of straddling two of them), and walk outward along the wall for a
	# slot flat enough to hang something on.
	var wanted: float = snap_slot(along)
	var chosen: float = wanted
	var relief: float = 1e9
	for step: int in 5:
		for direction: float in ([0.0] if step == 0 else [-1.0, 1.0]):
			var t: float = wanted + direction * float(step) * CELL
			if t < lo or t > hi:
				continue
			var probe: Vector3 = Vector3(t, 0.0, fixed) if horizontal \
					else Vector3(fixed, 0.0, t)
			var blocked: bool = false
			for gate: float in _kit_doors(room.get("doors", []) as Array, wall):
				if absf(t - float(gate)) < WALL_PROP_DOOR_CLEAR:
					blocked = true
			if blocked:
				continue
			var crowded: bool = false
			for spot: Dictionary in _prop_spots:
				var other: Vector3 = spot["pos"]
				if Vector2(probe.x - other.x, probe.z - other.z).length() < PROP_SEPARATION:
					crowded = true
					break
			if crowded:
				continue
			var depth: float = wall_relief_at(probe, dark)
			if depth < relief:
				relief = depth
				chosen = t
			if relief <= WALL_RELIEF_OK:
				break
		if relief <= WALL_RELIEF_OK:
			break
	if relief > 1e8:
		return {"ok": false}

	var base: Vector3 = Vector3(chosen, 0.0, fixed) if horizontal \
			else Vector3(fixed, 0.0, chosen)
	return {
		"ok": true,
		# Flush on the module's own face, plus a millimetre or two. NOT on the
		# boundary: the boundary is inside the wall now.
		"pos": base + normal * (relief + WALL_PROP_CLEAR),
		"yaw": LayerGraph.wall_yaw(side),
	}


## Every functional prop's final transform, resolved before anything is built.
##
## Split out from `_place_props` so the density pass can see the answers: a crate
## stack is the one piece of decoration in this milestone that collides, and a
## crate in front of a vent is a vent the breaker cannot reach. Pure — it reads
## the graph and the snapped shells and writes nothing but this list.
func _resolve_prop_spots() -> void:
	_prop_spots.clear()
	for i: int in graph.junction_points.size():
		_add_prop_spot("junction", i, graph.junction_rooms[i],
				graph.junction_sides[i], graph.junction_points[i])
	for i: int in graph.vent_points.size():
		_add_prop_spot("vent", i, graph.vent_rooms[i],
				graph.vent_sides[i], graph.vent_points[i])
	for i: int in graph.cabinet_points.size():
		_add_prop_spot("cabinet", i, graph.cabinet_rooms[i],
				graph.cabinet_sides[i], graph.cabinet_points[i])
	if graph.terminal_room >= 0:
		_add_prop_spot("terminal", 0, graph.terminal_room,
				graph.terminal_side, graph.terminal_point)


func _add_prop_spot(kind: String, index: int, room_index: int, side: int,
		anchor: Vector3) -> void:
	var mount: Dictionary = _wall_prop(graph.rooms[room_index], side, anchor)
	if not bool(mount.get("ok", false)):
		return
	_prop_spots.append({
		"kind": kind, "index": index, "room": room_index,
		"pos": mount["pos"], "yaw": mount["yaw"],
	})


## Stands every functional prop from the resolved spots. Nothing here decides
## anything — the positions, the counts and which nest a vent belongs to are all
## in the determinism dump; this turns them into objects.
func _place_props() -> void:
	var built: Dictionary = {"junction": 0, "vent": 0, "cabinet": 0, "terminal": 0}
	for spot: Dictionary in _prop_spots:
		var kind: String = String(spot["kind"])
		var index: int = int(spot["index"])
		var room_index: int = int(spot["room"])
		var at: Vector3 = spot["pos"]
		var yaw: float = float(spot["yaw"])
		built[kind] = int(built[kind]) + 1
		match kind:
			"junction":
				var junction: RewireJunction = RewireJunction.create(index, at, yaw)
				junction.set_meta("room_name", graph.room_name(room_index))
				_fixtures.add_child(junction)
				junction.adopt_strips(_emergency_strips(room_index, index),
						_strip_material(index))
			"vent":
				_fixtures.add_child(WeldVent.create(index, at, yaw, room_index))
			"cabinet":
				_fixtures.add_child(LootCabinet.create(index, at, yaw))
			"terminal":
				_fixtures.add_child(CommandTerminal.create(index, at, yaw, graph))
				# A console is player-tech and it is the one machine in the layer
				# that is on your side, so it gets a light of its own — feeble,
				# warm, and pointed at itself, the same rule the hidden Compiler
				# follows.
				LightRig.practical(_fixtures, Vector3(at.x, 2.4, at.z),
						0.55 * light_scale, 5.0,
						LightRig.AMBER).name = "Practical_terminal"

	var doors: int = 0
	if graph.bulkhead_edge.x >= 0:
		_fixtures.add_child(BulkheadDoor.create(0, graph.bulkhead_point,
				graph.bulkhead_axis, graph.bulkhead_edge, graph))
		doors += 1

	for i: int in graph.debris_points.size():
		_fixtures.add_child(DebrisBody.create(i, graph.debris_points[i],
				graph.debris_kinds[i]))

	_prop_note = " props=[junction %d, vent %d, cabinet %d, terminal %d, bulkhead %d, debris %d]" % [
		int(built["junction"]), int(built["vent"]), int(built["cabinet"]),
		int(built["terminal"]), doors, graph.debris_points.size()]


## The shared emissive material for one junction's emergency strips. One per
## junction rather than one global, so the strips are per-instance and a future
## per-room routing model does not need a material pass.
func _strip_material(index: int) -> StandardMaterial3D:
	if not has_meta("strip_material_%d" % index):
		var material: StandardMaterial3D = _make_emissive(Color(1.0, 0.86, 0.52), 0.06)
		# An UNPOWERED strip has to be a dark fixture on a dark wall. `_make_emissive`
		# derives its albedo from the emission colour, which for a warm white is a
		# pale grey — and a twenty-metre pale grey bar catching a player's beam
		# reads as a lit strip somebody forgot to switch off, which is the one thing
		# this fixture must never look like until the bus is routed to it.
		material.albedo_color = Color(0.035, 0.032, 0.028)
		material.roughness = 0.85
		set_meta("strip_material_%d" % index, material)
	return get_meta("strip_material_%d" % index) as StandardMaterial3D


## Emergency lighting for one junction: a strip run round the room it stands in
## and one over each corridor mouth leading off that room.
##
## Deliberately feeble (Balance.JUNCTION_LIGHT_ENERGY). DESIGN.md pillar 2 says
## unrendered space is near-black, and a lever that turns the lights ON would
## renegotiate the darkness the entire game rests on. What ROOM LIGHTING buys you
## is *a room you can cross without committing your beam* — enough to see the
## shape of the floor and not enough to see what is stood at the far end of it.
func _emergency_strips(room_index: int, junction_index: int) -> Array[OmniLight3D]:
	var lights: Array[OmniLight3D] = []
	var room: Dictionary = graph.rooms[room_index]
	var rect: Rect2 = _rect_of(room)
	var material: StandardMaterial3D = _strip_material(junction_index)

	# A strip along each wall, high, with a lamp at its middle. The bar is the
	# fixture you can see; the lamp is what it does.
	for side: int in 4:
		var run: Dictionary = _wall_run(rect, side, 3.0)
		if run.is_empty():
			continue
		var from: Vector3 = run["from"] + Vector3(0.0, 2.85, 0.0)
		var to: Vector3 = run["to"] + Vector3(0.0, 2.85, 0.0)
		var normal: Vector3 = run["normal"]
		_trace(from, to, material, 0.075)
		var mid: Vector3 = (from + to) * 0.5 + normal * 0.35
		lights.append(_strip_lamp(mid, "Strip_r%d_%d" % [room_index, side]))

	# And one over each doorway out of the room, so the approach lights with it —
	# DESIGN.md's "this room + adjacent corridor".
	for door: Dictionary in (room.get("doors", []) as Array):
		var wall: String = String(door.get("wall", ""))
		var centre: float = snap_slot(float(door.get("at", 0.0)))
		var at: Vector3 = Vector3.ZERO
		match wall:
			"n":
				at = Vector3(centre, 2.6, rect.position.y - 2.2)
			"s":
				at = Vector3(centre, 2.6, rect.end.y + 2.2)
			"w":
				at = Vector3(rect.position.x - 2.2, 2.6, centre)
			_:
				at = Vector3(rect.end.x + 2.2, 2.6, centre)
		_trace(at + Vector3(0.0, 0.55, 0.0),
				at + Vector3(0.0, 0.55, 0.0) + Vector3(0.9, 0.0, 0.0), material, 0.07)
		lights.append(_strip_lamp(at, "Strip_gate_r%d_%s" % [room_index, wall]))
	return lights


func _strip_lamp(at: Vector3, node_name: String) -> OmniLight3D:
	var light: OmniLight3D = OmniLight3D.new()
	light.name = node_name
	light.position = at
	light.light_color = Color(1.0, 0.84, 0.5)
	light.light_energy = 0.0  # dark until the bus is routed to it.
	light.omni_range = Balance.JUNCTION_LIGHT_RANGE
	light.omni_attenuation = 1.15
	light.light_specular = 0.1
	light.light_volumetric_fog_energy = 0.8
	light.shadow_enabled = false
	# Deliberately NOT named Accent/Key/Practical: LightRig.set_alert dispatches
	# on the name prefix, and an emergency strip is the one fixture on the layer
	# that must not be recoloured by the alert state. It is not MOTHER's lighting
	# — it is the lighting she keeps switched off, and the crew turned on.
	_fixtures.add_child(light)
	return light


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

	# Compilers. Faced toward the middle of the room they stand in, so a terminal
	# tucked against a wall presents its plate to the space the crew walks
	# through rather than to the masonry behind it.
	for i: int in graph.compiler_points.size():
		var at: Vector3 = graph.compiler_points[i]
		var toward: Vector3 = graph.centre_of(graph.compiler_rooms[i]) - at
		var yaw: float = 0.0 if toward.length_squared() < 0.01 \
				else atan2(-toward.x, -toward.z)
		var terminal: CompilerTerminal = CompilerTerminal.create(i, at, yaw,
				graph.compiler_tiers[i], graph.compiler_sanctuary[i])
		_fixtures.add_child(terminal)
		# A hidden Compiler is hidden, not invisible: one feeble practical under
		# the cowl, so a beam sweeping the room finds a shape rather than nothing.
		LightRig.practical(_fixtures, at + Vector3(0.0, 2.3, -0.3),
				0.5 * light_scale, 5.0,
				LightRig.AMBER if graph.compiler_sanctuary[i]
				else Color(0.3, 0.85, 1.0)).name = "Practical_compiler_%d" % i

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


func compiler_positions() -> Array[Vector3]:
	return graph.compiler_points
