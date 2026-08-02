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

	_rects.resize(graph.rooms.size())
	for room: Dictionary in graph.rooms:
		_rects[int(room["index"])] = kit_room(room)
	for corridor: Dictionary in graph.corridors:
		kit_corridor(corridor)

	for room: Dictionary in graph.rooms:
		_dress_room_decals(room)
	for corridor: Dictionary in graph.corridors:
		_dress_corridor_decals(corridor)

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
				(_rng.randf_range(2.1, 3.0) + boost * 0.5) * light_scale,
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
				(_rng.randf_range(3.6, 5.0) + boost * 0.8) * light_scale,
				gobos[i % gobos.size()], _rng.randf_range(42.0, 52.0),
				LightRig.AMBER if warm else LightRig.KEY_COLD, reach)
		key.name = "Key_r%d_%d" % [index, i]
		if i == dying:
			LightRig.flicker(key, FlickerLight.Mode.DYING, float(index) * 1.7)

	# --- hero shaft --------------------------------------------------------
	#
	# One aperture cone straight down at the middle of the room. Unshadowed on
	# purpose: its job is the volumetric shaft through the haze, and a shadow map
	# for a light pointing at an empty floor is the most expensive way in the
	# engine to buy nothing.
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
			_data_rack(Vector3(x, 0.0, z), Vector3(2.2, 2.6, 1.0),
					0.0 if j == 0 else PI, vault_glow,
					_rng.randi_range(4, 6))
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
		_data_rack(Vector3(x, 0.0, z), Vector3(1.9, 3.2, 2.4),
				_rng.randf_range(-0.25, 0.25), SYSTEM_TEAL, _rng.randi_range(5, 7))
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
