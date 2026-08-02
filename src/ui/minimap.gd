class_name Minimap
extends Control
## The crew's shared memory of the layer, drawn as a phosphor wireframe.
##
## ## What it is allowed to know
##
## `Cartography` owns that question and its header states the law: the map is
## memory, not a wallhack. This file is the consumer, and it keeps the law by
## never looking anything up in `LayerGraph` that `Cartography` has not already
## said is discovered. There is no dimmed "unexplored" tier, no fog-of-war
## silhouette, no outline of the rooms you have not been in. **Undiscovered
## topology is not drawn at all**, because a dimmed shape still tells you there
## is a room there and how big it is, and that is the whole thing the dark was
## for.
##
## ## The quiet-instrument rule
##
## DESIGN.md M4.9: "the resting HUD is nearly empty ... every element must justify
## every frame it is visible". A minimap is a standing rectangle of information,
## which is exactly what that rule is against — so it has two states:
##
##   CORNER   a small wireframe in the instrument cluster. Rooms as hairlines,
##            crew as shape tags, nothing else. Surfaces when the crew discovers
##            something and fades back to a low resting alpha, like every other
##            surfacing element.
##   EXPANDED held open on TAB, centred, four times the area, with fixture
##            markers and room names. Let go and it is gone.
##
## The expanded read is a DELIBERATE COST: you are holding a key, standing still,
## looking at an instrument instead of at the dark. That is the same trade the
## command terminals make (DESIGN.md M4.8: "one player heads-down typing while the
## others hold the dark"), and it is why the map is allowed to exist at all.
##
## ## Colour is never the only channel (pillar 7)
##
## Crew are drawn as SHAPES — triangle, circle, square, diamond by crew slot —
## and tinted with the player's own phosphor second. A player with any colour
## vision deficiency reads the roster off the geometry. Fixtures are shapes too,
## and each one is a different shape rather than a different colour.

# --- geometry ---------------------------------------------------------------

## Corner size, and the expanded size, both in canvas pixels.
const CORNER_SIZE: Vector2 = Vector2(190.0, 190.0)
const EXPANDED_SIZE: Vector2 = Vector2(420.0, 420.0)
## Metres of world per pixel at each size, before the auto-fit below clamps it.
const CORNER_METRES: float = 150.0
const EXPANDED_METRES: float = 165.0
## Padding inside the frame so a room on the edge of the explored set still has
## a hairline of air around it.
const INSET: float = 10.0
## How fast the box grows and shrinks between the two states. Fast enough not to
## feel like a menu, slow enough not to read as a pop.
const MORPH_RATE: float = 16.0

# --- marks ------------------------------------------------------------------

## Crew shape tags, by crew slot. MANDATORY colourblind channel (DESIGN.md pillar
## 7): the same four glyphs the roster and the world-space crew tags use.
const CREW_SHAPES: Array[int] = [3, 0, 4, 5]  # triangle, circle, square, diamond
const CREW_MARK: float = 5.0
const LOCAL_MARK: float = 6.5
## Fixture marks. Each fixture kind is a different SHAPE, so the legend survives
## a monochrome phosphor and a colour deficiency both.
const FIXTURE_MARK: float = 5.0
## Shards draw smaller than the architecture they sit in. See `_draw_fixtures`.
const SHARD_MARK: float = 2.6


## The layer we are drawing, and the graph we are allowed to ask about
## discovered things. Re-resolved when a layer enters the tree.
var _graph: LayerGraph = null
## True while TAB is held.
var expanded: bool = false
## 0 = corner, 1 = expanded. Chased, so the box morphs rather than cuts.
var _morph: float = 0.0
## Resting visibility, poked by discovery like every other surfacing element.
var _surface: UiFx.Surface = null
## Where the local player is and which way they are facing, in world XZ.
var _at: Vector2 = Vector2.ZERO
var _yaw: float = 0.0
## Crew marks, rebuilt each frame from Net: [{at:Vector2, colour:Color, slot:int,
## local:bool, down:bool}].
var _crew: Array[Dictionary] = []
## The world-space rect the explored set occupies, so the view auto-fits what the
## crew actually knows rather than always drawing the whole 136 m lattice.
var _explored: Rect2 = Rect2()
var _has_explored: bool = false
## Inset from the corner of the tube-safe box. Set by the HUD, which owns where
## the instrument cluster sits.
var margin: float = 22.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_surface = UiFx.Surface.new(UiFx.ROSTER_HOLD)
	# The map is never fully hidden the way a transient readout is: a resting
	# alpha of zero would mean a player who has not discovered anything for three
	# seconds cannot find their own map. It rests LOW and surfaces on change.
	Cartography.discovered.connect(_on_discovered)
	set_process(true)


func _on_discovered() -> void:
	_surface.surface()
	_refit()


## Resolve the layer graph lazily. The HUD outlives any single layer, and a
## descent replaces the whole world under it.
func _resolve_graph() -> void:
	var layers: Array = get_tree().get_nodes_in_group("layer")
	if layers.is_empty():
		_graph = null
		return
	var found: LayerGraph = layers[0].get("graph") as LayerGraph
	if found != _graph:
		_graph = found
		_refit()


## The bounding box of the DISCOVERED rooms only. Recomputed on discovery rather
## than per frame, and it is also the second place the law is kept: a fit
## computed over every room would silently tell the player how big the layer is.
func _refit() -> void:
	_has_explored = false
	if _graph == null:
		return
	for index: int in Cartography.discovered_rooms.keys():
		if index < 0 or index >= _graph.rooms.size():
			continue
		var room: Dictionary = _graph.rooms[index]
		var box: Rect2 = Rect2(Vector2(room["min"]),
				Vector2(room["max"]) - Vector2(room["min"]))
		_explored = box if not _has_explored else _explored.merge(box)
		_has_explored = true


# ------------------------------------------------------------ the surveyor --
#
# What actually turns walking around into a map. It lives here, on the widget,
# rather than on the player, for two reasons: `src/player` belongs to another
# workstream this milestone, and — the real one — discovery is a PRESENTATION
# concern. Nothing in the simulation cares which rooms you remember.

## Seconds between discovery sweeps. Discovery is not frame-critical and a raycast
## per fixture per frame would be a real cost for a readout nobody is looking at.
const SURVEY_INTERVAL: float = 0.25
## A fixture is discovered when it is within this far AND unobstructed AND inside
## the lens's own cone. Comfortably under Cartography.DISCOVER_RANGE, which is the
## host's outer sanity bound rather than the gameplay range.
const SIGHT_RANGE: float = 22.0
## Half-angle of the "I am looking at it" cone, in degrees. Generous — you notice
## a lit siphon tap in your peripheral vision; you do not have to aim at it.
const SIGHT_CONE_DEG: float = 62.0
## How much of the ray's length near the target belongs to the fixture rather
## than to an occluder. A drop shaft is a three-metre piece of architecture and
## it is ON the world collision layer, so a sight test that fails on any hit
## fails on the fixture itself.
const FIXTURE_RADIUS: float = 3.0
## Shards get a tighter leash than the architecture. See `_survey`.
const SHARD_SIGHT_RANGE: float = 11.0

var _survey_clock: float = 0.0
var _last_room: int = -1


## One pass: which room am I standing in, and what can I see from here.
##
## The room test is a rect containment on the graph, not a trigger volume, so it
## costs nothing and cannot be desynced by a missing Area3D. The fixture test is a
## real raycast against the world collision layer, because "line of sight" has to
## mean line of sight — a shaft two rooms away through three walls is exactly the
## thing the map must never reveal.
func _survey(delta: float) -> void:
	_survey_clock -= delta
	if _survey_clock > 0.0 or _graph == null:
		return
	_survey_clock = SURVEY_INTERVAL

	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		return
	var body: Node3D = player as Node3D
	var eye: Vector3 = body.global_position + Vector3.UP * 1.5

	var room: int = _graph.room_at(body.global_position)
	if room >= 0 and room != _last_room:
		_last_room = room
		Cartography.report_room(room)

	# The TREE ROOT's viewport, not `get_viewport()`. This widget lives inside the
	# HUD's CRT SubViewport, which is a 2D render target with no camera in it, so
	# `get_viewport().get_camera_3d()` is null here and every sight test silently
	# returned before doing anything. Rooms still appeared (containment needs no
	# camera) and fixtures never did — which is exactly the shape of bug that looks
	# like a design decision until you go looking.
	var camera: Camera3D = get_tree().root.get_camera_3d()
	if camera == null:
		return
	var forward: Vector3 = -camera.global_transform.basis.z
	var space: PhysicsDirectSpaceState3D = body.get_world_3d().direct_space_state
	var cone: float = cos(deg_to_rad(SIGHT_CONE_DEG))

	_look_for(Cartography.KIND_SHAFT, 0, eye, forward, cone, space, body)
	if _graph.is_backdoor:
		_look_for(Cartography.KIND_NODE, 0, eye, forward, cone, space, body)
		_look_for(Cartography.KIND_UPLINK, 0, eye, forward, cone, space, body)
	for i: int in _graph.siphon_points.size():
		_look_for(Cartography.KIND_SIPHON, i, eye, forward, cone, space, body)
	for i: int in _graph.compiler_points.size():
		_look_for(Cartography.KIND_COMPILER, i, eye, forward, cone, space, body)
	# Data shards, at a SHORTER range than the architecture. A shaft is a piece of
	# building you can pick out across a room; a shard is a chip on the floor, and a
	# map that inventories every one of them the moment you glance down a corridor
	# turns looting from searching into collecting. The same line-of-sight rule
	# applies, so a shard behind a crate stays unknown until you walk around it.
	for i: int in _graph.shard_points.size():
		_look_for(Cartography.KIND_SHARD, i, eye, forward, cone, space, body,
				SHARD_SIGHT_RANGE)


func _look_for(kind: String, index: int, eye: Vector3, forward: Vector3,
		cone: float, space: PhysicsDirectSpaceState3D, body: Node3D,
		range_limit: float = SIGHT_RANGE) -> void:
	if Cartography.knows_item(kind, index):
		return
	var where: Vector3 = Cartography.item_position(kind, index)
	if where == Vector3.INF:
		return
	var target: Vector3 = where + Vector3.UP * 1.0
	var offset: Vector3 = target - eye
	var distance: float = offset.length()
	if distance > range_limit or distance < 0.01:
		return
	if forward.dot(offset / distance) < cone:
		return
	# Layer 1 is "world" (see project.godot [layer_names]). A wall between the eye
	# and the fixture means the crew has not seen it, which is the whole rule.
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			eye, target, 1)
	query.exclude = [body.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if not hit.is_empty():
		# ...but the FIXTURE ITSELF is on the world layer, and a drop shaft is a
		# large piece of collidable architecture. The first build treated "the ray
		# hit something" as "the view is blocked", so standing five metres from the
		# shaft and staring straight at it never discovered it: the thing occluding
		# the ray was the thing being looked at. Only a hit meaningfully SHORT of
		# the target is an occluder.
		var blocked: float = eye.distance_to(Vector3(hit["position"]))
		if blocked < distance - FIXTURE_RADIUS:
			return
	Cartography.report_item(kind, index)


func _process(delta: float) -> void:
	_resolve_graph()
	_survey(delta)
	expanded = Input.is_action_pressed("map") and not Debug.lock_input
	if Debug.hud_state == "map":
		expanded = true
	_morph = UiFx.chase(_morph, 1.0 if expanded else 0.0, MORPH_RATE, delta)
	if Debug.hud_state == "map":
		# A capture must photograph the FINISHED state, never a frame of the morph.
		_morph = 1.0
	_surface.tick(delta)
	_gather_crew()
	_resize()
	if Debug.hud_debug:
		print("[Minimap] size=%s morph=%.2f rooms=%d explored=%s" % [str(size), _morph, Cartography.room_count(), str(_explored)])
	queue_redraw()


## The widget owns its own anchoring.
##
## Writing `size` would not have worked and it is worth saying why: this Control
## is anchored to a corner with explicit offsets, so `size` is DERIVED from those
## offsets — assigning it just gets solved away on the next layout pass, which is
## how the first build came out drawing a 46 px frame with its contents outside
## it. A widget that changes size has to change the thing size is computed from.
##
## Pinned by the BOTTOM-RIGHT corner, so expanding grows it inward across the
## screen instead of pushing it off the edge it lives on.
func _resize() -> void:
	var box: Vector2 = CORNER_SIZE.lerp(EXPANDED_SIZE, _morph)
	custom_minimum_size = box
	offset_left = -box.x - margin
	offset_top = -box.y - margin
	offset_right = -margin
	offset_bottom = -margin


func _gather_crew() -> void:
	_crew.clear()
	var local: int = Net.local_id()
	var slot: int = 0
	var ids: Array = Net.crew.keys()
	ids.sort()
	for id: int in ids:
		var player: Node = Net.get_player(id)
		if player == null or not is_instance_valid(player):
			slot += 1
			continue
		var body: Node3D = player as Node3D
		var mark: Dictionary = {
			"at": Vector2(body.global_position.x, body.global_position.z),
			"slot": slot % CREW_SHAPES.size(),
			"local": id == local,
			"colour": Net.crew_color(id),
		}
		if id == local:
			_at = mark["at"]
			_yaw = body.rotation.y
		_crew.append(mark)
		slot += 1


# ------------------------------------------------------------------ drawing --

## World XZ -> local pixels. One transform, used by everything drawn here, so a
## marker can never drift from the room it is in.
func _to_map(world: Vector2, box: Rect2, scale_factor: float) -> Vector2:
	return (world - box.get_center()) * scale_factor + size * 0.5


func _draw() -> void:
	var alpha: float = maxf(_surface.alpha, 0.68) * (0.82 + 0.18 * _morph)
	if Debug.hud_state == "map":
		alpha = 1.0

	var plate: Color = Color(0.012, 0.016, 0.024, 0.94 * alpha)
	draw_rect(Rect2(Vector2.ZERO, size), plate, true)
	# The instrument's own frame. It has to be locatable against a near-black
	# corridor at a glance — the first build drew it at 22% effective alpha and it
	# was, measurably, not there.
	var edge: Color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.55 * alpha)
	draw_rect(Rect2(Vector2.ZERO, size), edge, false, 1.0)
	# Corner brackets, brighter than the frame: the cassette-futurism tell, and the
	# thing the eye actually finds when the frame itself is a hairline.
	var tick: float = 14.0
	var hot: Color = Color(UiFx.SYSTEM_HOT.r, UiFx.SYSTEM_HOT.g, UiFx.SYSTEM_HOT.b,
			0.85 * alpha)
	for corner: Vector2 in [Vector2.ZERO, Vector2(size.x, 0.0), size,
			Vector2(0.0, size.y)]:
		var inward: Vector2 = (size * 0.5 - corner).sign()
		draw_line(corner, corner + Vector2(inward.x * tick, 0.0), hot, 2.0)
		draw_line(corner, corner + Vector2(0.0, inward.y * tick), hot, 2.0)

	if _graph == null or not _has_explored:
		# Nothing discovered: say so in one word rather than drawing an empty
		# frame the player has to guess the meaning of.
		_draw_label(Vector2(size.x * 0.5, size.y * 0.5), "NO SURVEY", alpha * 0.75,
				HORIZONTAL_ALIGNMENT_CENTER)
		return

	# Auto-fit the explored set into the frame, with a floor on the zoom so the
	# first discovered room does not fill the whole instrument.
	var span: float = maxf(maxf(_explored.size.x, _explored.size.y),
			lerpf(CORNER_METRES, EXPANDED_METRES, _morph) * 0.30)
	var usable: float = minf(size.x, size.y) - INSET * 2.0
	var scale_factor: float = usable / maxf(span, 1.0)

	_draw_rooms(alpha, scale_factor)
	if _morph > 0.05:
		_draw_fixtures(alpha * _morph, scale_factor)
	_draw_crew(alpha, scale_factor)
	_draw_legend(alpha)


## Discovered rooms as hairline rectangles and discovered corridors as the lines
## between them — the same drawing language as the menu's schematic backdrop,
## which is deliberate: both are Northcairn plotter output.
##
## A corridor is drawn only when BOTH its rooms are known. Drawing it off one end
## would be drawing a line pointing at a room the crew has never seen, which is a
## map telling you where to go — i.e. the wallhack, with extra steps.
func _draw_rooms(alpha: float, scale_factor: float) -> void:
	var wall: Color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.62 * alpha)
	var link: Color = Color(UiFx.DIM.r, UiFx.DIM.g, UiFx.DIM.b, 0.55 * alpha)

	for corridor: Dictionary in _graph.corridors:
		if not Cartography.knows_room(int(corridor["a"])) \
				or not Cartography.knows_room(int(corridor["b"])):
			continue
		var low: Vector2 = _to_map(Vector2(corridor["min"]), _explored, scale_factor)
		var high: Vector2 = _to_map(Vector2(corridor["max"]), _explored, scale_factor)
		draw_rect(Rect2(low, high - low), link, false, 1.0)

	for index: int in Cartography.discovered_rooms.keys():
		if index < 0 or index >= _graph.rooms.size():
			continue
		var room: Dictionary = _graph.rooms[index]
		var low: Vector2 = _to_map(Vector2(room["min"]), _explored, scale_factor)
		var high: Vector2 = _to_map(Vector2(room["max"]), _explored, scale_factor)
		draw_rect(Rect2(low, high - low), wall, false, 1.0)
		# VERTICAL AWARENESS. `LayerGraph.elevation_bands()` returns one record per
		# walkable region with a `band` storey index — 0 grade, 1 mezzanine, -1 a
		# sunken pit. A room that has more than its ground floor gets its decks
		# drawn as an inner hairline, so the map says "there is another level in
		# here" without pretending to be a section drawing. The band number is the
		# only thing a 2D map can honestly carry, and it is the thing that matters:
		# whether the crewmate you are looking for is above or below you.
		for band: Dictionary in _bands_of(index):
			if int(band["band"]) == 0:
				continue
			var deck_low: Vector2 = _to_map(Vector2(band["min"]), _explored, scale_factor)
			var deck_high: Vector2 = _to_map(Vector2(band["max"]), _explored, scale_factor)
			var above: bool = int(band["band"]) > 0
			draw_rect(Rect2(deck_low, deck_high - deck_low),
					Color(UiFx.SYSTEM_HOT.r, UiFx.SYSTEM_HOT.g, UiFx.SYSTEM_HOT.b,
							(0.40 if above else 0.24) * alpha), false, 1.0)

		# The room's NAME, in the expanded read only.
		#
		# `LayerGraph.room_name` is what the command terminal answers with and what
		# its wayfinding prints, so the map saying `VAULT-7C` means a crewmate can
		# read a name off the map and type it into a terminal, or say it out loud and
		# have it match what the other three are looking at. A map with no names on
		# it makes people say "the big room with the thing", which is how a crew of
		# four ends up in two different rooms.
		#
		# Expanded only, because the corner state is 190 px across and eight names in
		# it is a grey smear — the corner is a compass, the expanded read is a map.
		if _morph > 0.5 and _graph.has_method("room_name"):
			var tint: float = alpha * smoothstep(0.5, 0.95, _morph)
			_draw_label(low + (high - low) * 0.5 + Vector2(0.0, 3.0),
					_graph.room_name(index), tint * 0.9,
					HORIZONTAL_ALIGNMENT_CENTER)


## The seam with the verticality workstream, isolated to one function.
##
## `LayerGraph.elevation_bands()` landed while this was being written and is used
## directly. If a build ever ships without it — an older graph, the hand-authored
## test layer — this returns empty and the map is simply flat, which is the
## correct degradation: a flat drawing of a layer with decks is incomplete, a
## crash is not.
func _bands_of(room_index: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _graph == null or not _graph.has_method("elevation_bands"):
		return out
	for band: Dictionary in _graph.elevation_bands():
		if int(band["room"]) == room_index:
			out.append(band)
	return out


## Fixture markers, EXPANDED ONLY and DISCOVERED ONLY.
##
## Two gates, and both are load-bearing. Discovered-only is the law. Expanded-only
## is the quiet-instrument rule: a corner map with eight markers on it is a corner
## map you read instead of the room, and the marker you actually need is worth
## holding a key for.
func _draw_fixtures(alpha: float, scale_factor: float) -> void:
	# The drop shaft: the way down, and the only marker that is ever urgent.
	if Cartography.knows_item(Cartography.KIND_SHAFT, 0):
		_draw_fixture(_graph.shaft_point, scale_factor, alpha, 6, "SHAFT",
				UiFx.SYSTEM_HOT)
	if _graph.is_backdoor:
		if Cartography.knows_item(Cartography.KIND_NODE, 0):
			_draw_fixture(_graph.backdoor_point, scale_factor, alpha, 4, "NODE",
					UiFx.SYSTEM_HOT)
		if Cartography.knows_item(Cartography.KIND_UPLINK, 0):
			_draw_fixture(_graph.uplink_point, scale_factor, alpha, 5, "UPLINK",
					UiFx.SYSTEM_HOT)
	for i: int in _graph.siphon_points.size():
		if Cartography.knows_item(Cartography.KIND_SIPHON, i):
			_draw_fixture(_graph.siphon_points[i], scale_factor, alpha, 3, "TAP",
					UiFx.SYSTEM)
	for i: int in _graph.compiler_points.size():
		if Cartography.knows_item(Cartography.KIND_COMPILER, i):
			_draw_fixture(_graph.compiler_points[i], scale_factor, alpha, 0, "CMP",
					UiFx.SYSTEM)
	# Shards last, so a marker for a chip on the floor never draws over the way out.
	# Unlabelled and small: eleven of them with "DATA" beside each would bury the
	# four markers that matter under the loot. The diamond is the shape the HUD's
	# buffer readout and the world pickup already use.
	for i: int in _graph.shard_points.size():
		if Cartography.knows_item(Cartography.KIND_SHARD, i):
			_draw_fixture(_graph.shard_points[i], scale_factor, alpha, 5, "",
					UiFx.CAPTION, SHARD_MARK)


func _draw_fixture(world: Vector3, scale_factor: float, alpha: float, sides: int,
		label: String, colour: Color, mark: float = FIXTURE_MARK) -> void:
	var at: Vector2 = _to_map(Vector2(world.x, world.z), _explored, scale_factor)
	_draw_shape(at, mark, sides, Color(colour.r, colour.g, colour.b, 0.9 * alpha))
	if not label.is_empty():
		_draw_label(at + Vector2(mark + 3.0, 4.0), label, alpha * 0.8)


## Crew marks. SHAPE first, colour second — see the header.
func _draw_crew(alpha: float, scale_factor: float) -> void:
	for mark: Dictionary in _crew:
		var at: Vector2 = _to_map(mark["at"] as Vector2, _explored, scale_factor)
		var colour: Color = mark["colour"] as Color
		var local: bool = bool(mark["local"])
		var radius: float = LOCAL_MARK if local else CREW_MARK
		_draw_shape(at, radius, CREW_SHAPES[int(mark["slot"])],
				Color(colour.r, colour.g, colour.b, (1.0 if local else 0.82) * alpha))
		if local:
			# The heading spike. A map with no facing on it is a map you have to
			# turn your whole body to read.
			var nose: Vector2 = Vector2(sin(-_yaw), -cos(-_yaw)) * (radius + 5.0)
			draw_line(at, at + nose,
					Color(colour.r, colour.g, colour.b, 0.95 * alpha), 1.5, true)


## `sides` 0 draws a circle; 3+ draws a regular polygon, point up. One helper so
## a crew tag and a fixture tag can never drift into different shape vocabularies.
func _draw_shape(at: Vector2, radius: float, sides: int, colour: Color) -> void:
	if sides <= 0:
		draw_circle(at, radius, colour)
		return
	var points: PackedVector2Array = PackedVector2Array()
	for i: int in sides:
		var angle: float = -PI * 0.5 + TAU * float(i) / float(sides)
		points.append(at + Vector2(cos(angle), sin(angle)) * radius)
	draw_colored_polygon(points, colour)


## `align` needs a WIDTH to align inside, and `draw_string`'s -1 means "no box", in
## which case Godot ignores the alignment entirely. So a centred label measures its
## own string and shifts by half of it — which is also the only way to centre on a
## POINT rather than inside a rect, and a room's centre is a point.
func _draw_label(at: Vector2, text: String, alpha: float,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var font: Font = ThemeDB.fallback_font
	var theme_font: Font = get_theme_font("font", "Label")
	if theme_font != null:
		font = theme_font
	var where: Vector2 = at
	if align == HORIZONTAL_ALIGNMENT_CENTER:
		where.x -= font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				UiFx.FONT_SMALL).x * 0.5
	draw_string(font, where, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, UiFx.FONT_SMALL,
			Color(UiFx.CAPTION.r, UiFx.CAPTION.g, UiFx.CAPTION.b, alpha))


## The corner state says what it is and how to open it, once, quietly. The
## expanded state says how much of the layer the crew has actually walked, which
## is the number a crew argues over on voice chat.
func _draw_legend(alpha: float) -> void:
	if _morph > 0.5:
		_draw_label(Vector2(INSET, size.y - INSET * 0.5),
				"SURVEY  %d ROOMS" % Cartography.room_count(), alpha * 0.85)
	else:
		_draw_label(Vector2(INSET, size.y - INSET * 0.5), "TAB", alpha * 0.55)
