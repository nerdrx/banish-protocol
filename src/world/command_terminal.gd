class_name CommandTerminal
extends Interactable
## A console you TYPE at.
##
## DESIGN.md's M4.8 line, and the one piece of GTFO in the whole project: a CRT
## terminal wired into MOTHER's own indices, where the crew's navigator stands
## with their head down composing a query while everybody else holds the dark.
## `LIST DATA`, `LOCATE COMPILER`, `QUERY VAULT-7C`. Real commands, typed on a
## real keyboard, answered by a machine that takes a couple of seconds to think
## and gets less honest the deeper you are.
##
## Three rules make it a NULLVOID prop rather than a GTFO import:
##
##   **Every query is loud.** `NOISE_ROOMS_TERMINAL` — one room, louder than a
##   footstep and quieter than a siphon. Intel is not free; it is the second
##   cheapest thing in the game and it still costs you your position.
##
##   **Depth corrupts the answer, not the machine.** Deep layers come back with
##   glyphs missing, in exactly the vocabulary the wall signage decays in
##   (`UiFx.CORRUPT_GLYPHS`, the same alphabet the HUD falls back to). The
##   terminal is fine. Her records are not, and by layer 18 a room name is
##   something you are half guessing.
##
##   **It is solo-friendly by construction.** One agent, one keyboard, one
##   answer. Co-op means somebody else is watching the door while you read; it
##   never means somebody else has to press anything. DESIGN.md's solo invariant
##   is a design law and this is the prop most likely to break it — so it does
##   not, and the gamepad gets a command list rather than an on-screen keyboard,
##   because parity is part of the same law.
##
## The prop is player-tech: a Northcairn console in amber phosphor, standing out
## against MOTHER's teal architecture exactly the way the HUD does. It is the one
## machine in the layer that is on your side, and it looks like it.

## Amber phosphor, the interface's own. Deliberately NOT the teal every other
## machine in the layer wears.
const SCREEN_COLOUR: Color = Color(1.0, 0.66, 0.24)
const CASING_COLOUR: Color = Color(0.55, 0.56, 0.58)

const MOUNT_HEIGHT: float = 1.02

var prop_index: int = 0
var graph: LayerGraph = null

var _screen_material: StandardMaterial3D = null
var _rows: Array[MeshInstance3D] = []
var _light: OmniLight3D = null
var _channel: float = 0.0
var _engaged: float = 0.0
## Rises while a query is processing, so the machine visibly works.
var _busy: float = 0.0


static func create(index: int, where: Vector3, yaw: float,
		layout: LayerGraph) -> CommandTerminal:
	var terminal: CommandTerminal = CommandTerminal.new()
	terminal.name = "CommandTerminal%d" % index
	terminal.prop_index = index
	terminal.graph = layout
	terminal.position = where
	terminal.rotation.y = yaw
	terminal.channel_time = Balance.TERMINAL_OPEN_TIME
	terminal._assemble()
	return terminal


func _assemble() -> void:
	var casing: StandardMaterial3D = StandardMaterial3D.new()
	casing.albedo_color = Color(0.14, 0.135, 0.128)
	casing.roughness = 0.72
	casing.metallic = 0.25
	var trim: StandardMaterial3D = StandardMaterial3D.new()
	trim.albedo_color = Color(0.22, 0.215, 0.2)
	trim.roughness = 0.6
	trim.metallic = 0.4

	# A desk bolted to the wall, with the tube sat on it under a hood. The
	# silhouette is 1980s workstation on purpose: it is the one object in a layer
	# of chamfered black monoliths that has a *keyboard*.
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT - 0.06, 0.30), Vector3(1.5, 0.09, 0.62), trim)
	for side: float in [-0.66, 0.66]:
		_add_mesh(Vector3(side, MOUNT_HEIGHT * 0.5, 0.16),
				Vector3(0.09, MOUNT_HEIGHT, 0.14), casing)
	_add_mesh(Vector3(0.0, 0.06, 0.22), Vector3(1.4, 0.12, 0.44), casing)

	# The tube. A deep box with a recessed face, because a CRT is mostly depth —
	# a flat rectangle on a stalk reads as a flatscreen, which is the one thing
	# this cannot look like.
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT + 0.42, 0.06), Vector3(0.98, 0.78, 0.52), casing)
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT + 0.82, 0.12), Vector3(1.06, 0.06, 0.6), trim)
	# Hood over the face, so the phosphor pools under it instead of washing the
	# corridor. Same reasoning as the Compiler's cowl.
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT + 0.79, 0.36), Vector3(1.02, 0.05, 0.22), trim)

	# The face is a DARK surface with bright lines on it, and the albedo is the
	# half that matters. The Compiler's plate learned this the hard way in M4 and
	# the terminal re-learned it in its first capture: an emissive backing whose
	# albedo is a *darkened tint of the phosphor* is still a pale grey panel, and
	# a player's own beam pointed at it from two metres turns the whole tube into
	# a white trapezoid. Near-black albedo, matte, and the emission stays a
	# suggestion; the rows do all the talking.
	var backing: StandardMaterial3D = StandardMaterial3D.new()
	backing.albedo_color = Color(0.016, 0.014, 0.011)
	backing.roughness = 0.94
	backing.metallic = 0.0
	# No emission at all on the glass. The tube's light comes off the *rows*; a
	# face that emits is a face with no contrast left for anything drawn on it.
	var plate: MeshInstance3D = _add_mesh(Vector3(0.0, MOUNT_HEIGHT + 0.42, 0.33),
			Vector3(0.82, 0.62, 0.04), backing)
	plate.rotation.x = deg_to_rad(6.0)

	# Text rows on the face. Ragged lengths hashed off the row index — a readout
	# of identical bars is a test card, and this machine is supposed to look like
	# it has a directory open on it.
	_screen_material = _emissive(SCREEN_COLOUR, 1.7)
	for i: int in 9:
		var width: float = 0.16 + UiFx.hash01(float(i) * 5.3 + float(prop_index) * 2.1) * 0.5
		var row: MeshInstance3D = MeshInstance3D.new()
		var bar: BoxMesh = BoxMesh.new()
		bar.size = Vector3(width, 0.019, 0.01)
		row.mesh = bar
		# POSITIVE z. The console's detailed face is its local +Z (every M4.8 wall
		# prop's is — see LayerGraph.wall_normal), which is the opposite of the
		# Compiler's lectern. Rows on -Z are a directory being displayed into the
		# inside of the tube, and the first capture of this photographed exactly
		# that: a blank pale screen with nothing on it.
		row.position = Vector3(-0.33 + width * 0.5, 0.25 - float(i) * 0.058, 0.035)
		row.material_override = _screen_material
		row.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		plate.add_child(row)
		_rows.append(row)

	# The keyboard. Two rows of key blocks on the desk — this is the tell that
	# tells a player they are going to be typing before they ever hold E.
	var keys: StandardMaterial3D = StandardMaterial3D.new()
	keys.albedo_color = Color(0.09, 0.088, 0.085)
	keys.roughness = 0.85
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT + 0.02, 0.44), Vector3(0.86, 0.05, 0.3), keys)
	for i: int in 3:
		_add_mesh(Vector3(0.0, MOUNT_HEIGHT + 0.05, 0.36 + float(i) * 0.07),
				Vector3(0.78, 0.012, 0.045), trim)

	_light = OmniLight3D.new()
	_light.name = "TerminalGlow"
	_light.position = Vector3(0.0, MOUNT_HEIGHT + 0.5, 0.75)
	_light.light_color = SCREEN_COLOUR
	# Feeble, and the same reasoning as the Compiler's: its job is to put a pool
	# on the machine so a beam sweeping the room finds a silhouette, not to light
	# the room. A console you can read the wall by has undone pillar 2.
	_light.light_energy = 0.5
	_light.omni_range = 5.4
	_light.omni_attenuation = 1.2
	_light.light_volumetric_fog_energy = 1.2
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(1.6, 2.0, 1.4), Vector3(0.0, MOUNT_HEIGHT + 0.3, 0.35))


func _ready() -> void:
	add_to_group(Props.GROUP_TERMINAL)


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	return "HOLD E  ·  COMMAND TERMINAL"


func prompt_title() -> String:
	return "COMMAND TERMINAL"


func prompt_glyph() -> String:
	return "▤"


func prompt_height() -> float:
	return MOUNT_HEIGHT + 1.35


func prompt_visible() -> bool:
	return not TerminalPanel.is_open()


func available() -> bool:
	return Run.local_running() and not TerminalPanel.is_open()


func complete() -> void:
	TerminalPanel.open_for(self)


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


## Driven by the panel while a query processes, so the machine in the world is
## visibly the one doing the work — not just the screen you are reading.
func set_busy(amount: float) -> void:
	_busy = clampf(amount, 0.0, 1.0)


func _process(delta: float) -> void:
	var open: bool = TerminalPanel.is_open_for(self)
	_engaged = move_toward(_engaged, 1.0 if open else 0.0, delta * 3.0)

	var t: float = UiFx.clock()
	var idle: float = 0.84 + sin(t * 1.7) * 0.16
	var charge: float = 1.0 + _channel * 1.5 + _engaged * 1.8 + _busy * 2.4
	_screen_material.emission_energy_multiplier = 1.7 * idle * charge
	_light.light_energy = 0.5 * idle * (1.0 + _channel * 0.7 + _engaged * 1.1
			+ _busy * 1.6)

	# While a query is processing the rows scroll: one row at a time goes dark and
	# comes back, top to bottom, which is a machine reading an index.
	if _busy > 0.01:
		var head: int = int(t * 11.0) % _rows.size()
		for i: int in _rows.size():
			_rows[i].visible = i != head


# ================================================================== the intel ==
#
# Everything below is a pure function of the layer graph and replicated run
# state, which is why none of it needs the host: every peer can answer its own
# query. What the host owns is the *consequence* — the noise — and that goes
# through `Props.request_query`.

const COMMANDS: Array[String] = [
	"LIST DATA", "LOCATE COMPILER", "LOCATE SHAFT", "LOCATE VENT",
	"QUERY <ROOM>", "HELP",
]

## Compass points, -Z is north (GeometryKit's convention, and the same one the
## wayfinding decals point along).
const BEARINGS: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]


## Bearing and range from `from` to `to`, e.g. "NE 41 m".
static func heading(from: Vector3, to: Vector3) -> String:
	var delta: Vector3 = to - from
	var flat: Vector2 = Vector2(delta.x, delta.z)
	if flat.length() < 0.5:
		return "HERE"
	# atan2(x, -z) puts 0 at north and turns clockwise through east.
	var angle: float = fposmod(rad_to_deg(atan2(flat.x, -flat.y)), 360.0)
	var index: int = int(round(angle / 45.0)) % 8
	return "%s %d m" % [BEARINGS[index], int(round(flat.length()))]


## The answer to one command, as lines. Uncorrupted — the panel applies the
## depth corruption on the way out, so the same function is testable.
static func answer(graph: LayerGraph, command: String, from: Vector3) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if graph == null:
		out.append("NO INDEX AVAILABLE")
		return out
	var line: String = command.strip_edges().to_upper()
	while line.contains("  "):
		line = line.replace("  ", " ")

	if line == "HELP" or line.is_empty():
		out.append("MAINTENANCE INDEX  ·  ACCEPTED COMMANDS")
		for entry: String in COMMANDS:
			out.append("  " + entry)
		out.append("")
		out.append("EVERY QUERY IS ANSWERED ALOUD.")
		return out

	if line == "LIST DATA":
		return _list_data(graph)
	if line.begins_with("LOCATE"):
		return _locate(graph, line.substr(6).strip_edges(), from)
	if line.begins_with("QUERY"):
		return _query(graph, line.substr(5).strip_edges(), from)

	out.append("UNRECOGNISED: %s" % line)
	out.append("TRY: HELP")
	return out


## Chips still on the floor, by room. The single most useful thing the terminal
## does and the reason the crew's navigator exists: a vault with eleven
## fragments left in it is worth the walk and a bus hall with one is not.
static func _list_data(graph: LayerGraph) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var per_room: Dictionary = {}
	var total: int = 0
	for i: int in graph.shard_points.size():
		if Run.is_shard_taken(i):
			continue
		var room: int = graph.shard_rooms[i]
		per_room[room] = int(per_room.get(room, 0)) + 1
		total += 1

	out.append("DATA INDEX  ·  LAYER %02d" % graph.layer_number)
	if total == 0:
		out.append("NO UNCOLLECTED FRAGMENTS.")
		return out
	out.append("%d FRAGMENTS UNCOLLECTED" % total)
	out.append("")
	var order: Array = per_room.keys()
	order.sort_custom(func(a: int, b: int) -> bool:
		var ca: int = int(per_room[a])
		var cb: int = int(per_room[b])
		if ca != cb:
			return ca > cb
		return a < b)
	for room: int in order:
		out.append("  %-10s %3d" % [graph.room_name(int(room)), int(per_room[room])])
	return out


static func _locate(graph: LayerGraph, what: String, from: Vector3) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	match what:
		"COMPILER":
			if graph.compiler_points.is_empty():
				out.append("NO COMPILER ON THIS RING.")
				return out
			var best: int = _nearest(graph.compiler_points, from)
			out.append("COMPILER  ·  %s" % graph.room_name(graph.compiler_rooms[best]))
			out.append("  BEARING %s" % heading(from, graph.compiler_points[best]))
			out.append("  STOCK TIER %d" % graph.compiler_tiers[best])
		"SHAFT", "TRUNK":
			out.append("DATA TRUNK  ·  %s" % graph.room_name(graph.shaft_index))
			out.append("  BEARING %s" % heading(from, graph.shaft_point))
			if graph.is_backdoor:
				out.append("  MAINTENANCE NODE PRESENT")
		"VENT":
			var open_points: Array[Vector3] = []
			var open_rooms: Array[int] = []
			for i: int in graph.vent_points.size():
				if Props.is_welded(i):
					continue
				open_points.append(graph.vent_points[i])
				open_rooms.append(graph.vent_rooms[i])
			if open_points.is_empty():
				out.append("ALL INGRESS COVERS SEALED.")
				return out
			var pick: int = _nearest(open_points, from)
			out.append("INGRESS COVER  ·  %s" % graph.room_name(open_rooms[pick]))
			out.append("  BEARING %s" % heading(from, open_points[pick]))
			out.append("  %d OF %d STILL OPEN" % [
				open_points.size(), graph.vent_points.size()])
		"SIPHON":
			if graph.siphon_points.is_empty():
				out.append("NO JUNCTION ON THIS RING.")
				return out
			var tap: int = _nearest(graph.siphon_points, from)
			out.append("SIPHON JUNCTION  ·  %s" % graph.room_name(
					graph.siphon_rooms[tap]))
			out.append("  BEARING %s" % heading(from, graph.siphon_points[tap]))
			out.append("  STATE %s" % ("DRAINED" if Run.is_siphon_spent(tap) else "CHARGED"))
		_:
			out.append("CANNOT LOCATE '%s'." % what)
			out.append("TRY: COMPILER · SHAFT · VENT · SIPHON")
	return out


static func _nearest(points: Array[Vector3], from: Vector3) -> int:
	var best: int = 0
	var best_distance: float = INF
	for i: int in points.size():
		var distance: float = points[i].distance_to(from)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


## What is in a room. The command that turns the terminal from a compass into a
## reason to stand still for four seconds in a dark building.
static func _query(graph: LayerGraph, wanted: String, from: Vector3) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if wanted.is_empty():
		out.append("QUERY REQUIRES A SECTOR.")
		out.append("SECTORS ON THIS RING:")
		var names: PackedStringArray = PackedStringArray()
		for i: int in graph.rooms.size():
			names.append(graph.room_name(i))
		out.append("  " + " ".join(names))
		return out

	var index: int = graph.room_by_name(wanted)
	if index < 0:
		out.append("NO SUCH SECTOR: %s" % wanted)
		return out

	var room: Dictionary = graph.rooms[index]
	out.append("SECTOR %s" % graph.room_name(index))
	out.append("  BEARING %s" % heading(from, graph.centre_of(index)))
	out.append("  CLASS   %s%s" % [String(room["archetype"]).to_upper(),
			"  ·  UNLIT" if bool(room["unlit"]) else ""])

	var chips: int = 0
	for i: int in graph.shard_points.size():
		if graph.shard_rooms[i] == index and not Run.is_shard_taken(i):
			chips += 1
	out.append("  DATA    %d FRAGMENT%s" % [chips, "" if chips == 1 else "S"])

	var contents: PackedStringArray = PackedStringArray()
	for i: int in graph.siphon_rooms.size():
		if graph.siphon_rooms[i] == index:
			contents.append("SIPHON TAP%s" % (
					" (DRAINED)" if Run.is_siphon_spent(i) else ""))
	for i: int in graph.compiler_rooms.size():
		if graph.compiler_rooms[i] == index:
			contents.append("COMPILER T%d" % graph.compiler_tiers[i])
	for i: int in graph.junction_rooms.size():
		if graph.junction_rooms[i] == index:
			contents.append("REWIRE JUNCTION")
	for i: int in graph.cabinet_rooms.size():
		if graph.cabinet_rooms[i] == index:
			contents.append("CABINET%s" % (
					" (OPEN)" if Props.is_cabinet_open(i) else " (LOCKED)"))
	for i: int in graph.vent_rooms.size():
		if graph.vent_rooms[i] == index:
			contents.append("INGRESS COVER%s" % (
					" (WELDED)" if Props.is_welded(i) else ""))
	if index == graph.terminal_room:
		contents.append("THIS TERMINAL")
	if graph.is_backdoor and index == graph.shaft_index:
		contents.append("MAINTENANCE NODE")
	if contents.is_empty():
		contents.append("NOTHING INDEXED")
	out.append("  FIXTURES")
	for entry: String in contents:
		out.append("    " + entry)

	# What she will not tell you. A vault always says this; a nest says it if the
	# player has already been told the room is unlit. MOTHER does not report her
	# own processes to an unauthorised query — she reports that she is redacting
	# them, which is worse.
	if bool(room["unlit"]) or String(room["archetype"]) == LayerGraph.VAULT:
		out.append("  SECURITY  [REDACTED]")

	var exits: PackedStringArray = PackedStringArray()
	for corridor: Dictionary in graph.corridors:
		var a: int = int(corridor["a"])
		var b: int = int(corridor["b"])
		if a == index:
			exits.append(graph.room_name(b))
		elif b == index:
			exits.append(graph.room_name(a))
	out.append("  EXITS   %s" % (" ".join(exits) if not exits.is_empty() else "NONE"))
	return out


# ------------------------------------------------------------------ helpers --

func _add_mesh(at: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	add_child(mesh)
	return mesh


func _emissive(colour: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(0.62)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.38
	material.disable_receive_shadows = true
	return material
