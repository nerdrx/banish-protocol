class_name BulkheadDoor
extends Interactable
## A door you can shut behind you, for a minute.
##
## DESIGN.md's M4.8 line, and the sentence in it that decides the whole design:
## *"a pursuit-breaker, not a fortress"*. Hold E and two heavy leaves drive out
## of the corridor walls and slam; the antivirus cannot path through it; MOTHER
## forces it back open after sixty seconds with a warning hiss first. It buys you
## a minute of a Scrubber pack somewhere else. It does not buy you a room.
##
## ## Why this cannot trap you
##
## Three guarantees, and the milestone would not ship without all three:
##
##   1. **It only ever stands on a loop corridor.** `LayerGraph._place_props`
##      picks from `loop_edges` — the adjacencies the spanning tree did not use —
##      so every room on both sides of this door has another way to the drop
##      shaft by construction. Sealing it is never the thing that cuts a crew off.
##   2. **It re-opens on its own**, whether or not anybody is left to open it.
##   3. **You can open it by hand**, from either side, at any time. It is your
##      door while it is shut.
##
## ## Pathing
##
## Sealing calls `LayerGraph.set_edge_blocked`, which re-solves the layer's
## all-pairs first-hop table around the closed corridor. Every peer does it off
## the same replicated packet, so all four routing tables stay identical — and a
## Scrubber does not grind against the door and dodge, it takes the long way
## round like something that knows the building.

const FRAME_COLOUR: Color = Color(1.0, 0.62, 0.26)
## Shut, and holding. Amber rather than red on purpose: DESIGN.md reserves red
## for hostile processes and for the alert state, and a sealed door washing a
## whole corridor red reads as "a Sentinel is purging" rather than as "you closed
## something". A door you shut is *your* hardware state, so it wears the hazard
## amber the frame is already striped in.
const SEALED_COLOUR: Color = Color(1.0, 0.58, 0.18)
## And the one moment it IS hostile: MOTHER overriding the lock. Red is hers.
const WARN_COLOUR: Color = Color(1.0, 0.30, 0.22)
const OPEN_COLOUR: Color = Color(0.32, 0.86, 1.0)

## Corridor cross-section this has to close. GeometryKit builds corridors one
## 4 m cell wide and one storey tall.
const SPAN: float = 4.0
const CLEAR_HEIGHT: float = GeometryKit.STOREY

## How long the door refuses a second channel after it has moved.
##
## This is the one interactable in the game that TOGGLES, and a toggle plus the
## interaction model (holding E re-arms the moment a channel completes) means a
## player who keeps the key down seals the door and immediately unseals it. Two
## and a half seconds is longer than a human holds E past a completed channel and
## far shorter than the sixty MOTHER gives you, so a deliberate re-open still
## works on the second press.
const TOGGLE_LOCK: float = 2.5

var prop_index: int = 0
## The corridor this door closes, as a graph edge. Handed to `set_edge_blocked`.
var edge: Vector2i = Vector2i(-1, -1)
var graph: LayerGraph = null

var _leaves: Array[Node3D] = []
var _blocker: StaticBody3D = null
var _shape: CollisionShape3D = null
var _strip_material: StandardMaterial3D = null
var _lamp_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _channel: float = 0.0
## 0..1 how far the leaves have driven. Eased, and the collider follows it.
var _closed: float = 0.0
var _applied_block: bool = false
## True once the door is standing, so a seal/reopen sounds only real state
## changes, not the state a joiner adopts on arrival (M5).
var _audio_ready: bool = false
## Seconds until this will accept another channel. See TOGGLE_LOCK.
var _lock: float = 0.0


## `axis` is the corridor's own ("x" or "z"); the door stands across it.
static func create(index: int, where: Vector3, axis: String, on_edge: Vector2i,
		layout: LayerGraph) -> BulkheadDoor:
	var door: BulkheadDoor = BulkheadDoor.new()
	door.name = "BulkheadDoor%d" % index
	door.prop_index = index
	door.edge = on_edge
	door.graph = layout
	door.position = where
	# The leaves travel along the corridor's cross axis, so the node is turned to
	# face down the corridor: local +X is "sideways across the passage".
	door.rotation.y = 0.0 if axis == "z" else PI * 0.5
	door.channel_time = Balance.BULKHEAD_SEAL_TIME
	door._assemble()
	return door


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# The frame. Heavy jambs and a header, standing proud of the corridor walls —
	# this reads as a pressure door somebody installed, not as a hole with a lid.
	for side: float in [-1.0, 1.0]:
		_add_mesh(Vector3(side * (SPAN * 0.5 - 0.16), CLEAR_HEIGHT * 0.5, 0.0),
				Vector3(0.32, CLEAR_HEIGHT, 0.62), casing)
	_add_mesh(Vector3(0.0, CLEAR_HEIGHT - 0.22, 0.0), Vector3(SPAN, 0.44, 0.62), casing)
	_add_mesh(Vector3(0.0, 0.05, 0.0), Vector3(SPAN, 0.1, 0.62), casing)

	# Two leaves that meet in the middle. Ribbed, because a flat slab that big
	# reads as a missing texture under the kit's grazing light.
	_strip_material = _emissive(FRAME_COLOUR, 0.5)
	for side: int in 2:
		var leaf: Node3D = Node3D.new()
		leaf.name = "Leaf%d" % side
		add_child(leaf)
		_leaves.append(leaf)
		var sign_x: float = -1.0 if side == 0 else 1.0
		_group_box(leaf, Vector3(sign_x * SPAN * 0.25, CLEAR_HEIGHT * 0.5, 0.0),
				Vector3(SPAN * 0.5, CLEAR_HEIGHT - 0.32, 0.34), casing)
		for i: int in 3:
			_group_box(leaf, Vector3(sign_x * SPAN * 0.25,
					CLEAR_HEIGHT * (0.25 + float(i) * 0.25), 0.19),
					Vector3(SPAN * 0.46, 0.13, 0.05), casing)
		# Hazard stripe down the CLOSING edge — the edge that meets the other
		# leaf, not the one that parks in the jamb. Getting that backwards puts
		# both stripes inside the walls when the door shuts, which is precisely
		# when they are the only thing telling you it did.
		_group_box(leaf, Vector3(sign_x * 0.06, CLEAR_HEIGHT * 0.5, 0.2),
				Vector3(0.08, CLEAR_HEIGHT - 0.6, 0.03), _strip_material)

	# Status lamp on the header, on the side you are standing.
	_lamp_material = _emissive(OPEN_COLOUR, 1.2)
	_add_mesh(Vector3(0.0, CLEAR_HEIGHT - 0.22, 0.33), Vector3(0.5, 0.09, 0.03),
			_lamp_material)

	# The blocker. Off until the leaves have actually met, so a player standing in
	# the doorway when it closes is pushed out rather than sealed inside the slab.
	_blocker = StaticBody3D.new()
	_blocker.name = "Blocker"
	_blocker.collision_layer = 0
	_blocker.collision_mask = 0
	_shape = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(SPAN, CLEAR_HEIGHT, 0.4)
	_shape.shape = box
	_shape.position = Vector3(0.0, CLEAR_HEIGHT * 0.5, 0.0)
	_shape.disabled = true
	_blocker.add_child(_shape)
	add_child(_blocker)

	_light = OmniLight3D.new()
	_light.name = "BulkheadGlow"
	_light.position = Vector3(0.0, CLEAR_HEIGHT * 0.62, 0.5)
	_light.light_color = OPEN_COLOUR
	_light.light_energy = 0.45
	_light.omni_range = 5.0
	_light.omni_attenuation = 1.1
	_light.light_volumetric_fog_energy = 1.6
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(3.0, 2.6, 1.6), Vector3(0.0, 1.35, 0.0))


func _ready() -> void:
	add_to_group(Props.GROUP_BULKHEAD)
	Props.bulkheads_changed.connect(_on_state_changed)
	if Props.is_sealed(prop_index):
		_closed = 1.0
	_on_state_changed()
	# Everything after the initial adopt is a real seal/reopen worth a sound.
	_audio_ready = true


func _on_state_changed() -> void:
	# The routing table follows the door, on every peer, off the same packet.
	var sealed: bool = Props.is_sealed(prop_index)
	if graph == null or edge.x < 0 or sealed == _applied_block:
		return
	_applied_block = sealed
	_lock = TOGGLE_LOCK
	graph.set_edge_blocked(edge.x, edge.y, sealed)
	# On every peer, off the one packet: the seal slam when the crew shuts it, or
	# MOTHER's warning-then-hydraulics when it comes back open. Two different
	# authors, so two different sounds — and the reopen's caption is a THREAT (she
	# is coming through your barricade). Guarded against the adopted initial state.
	if _audio_ready:
		Audio.play_3d(&"bulkhead_seal" if sealed else &"bulkhead_reopen", global_position)
	# The routing consequence, in the log, on the same line as the cause. "The
	# antivirus cannot path through a sealed door" is a claim, and the honest form
	# of it is the first hop the graph now hands a creature that wants to cross:
	# the neighbour itself while the door is open, something else (or nothing)
	# once it is shut.
	var hop: int = graph.next_room(edge.x, edge.y)
	print("[Props] bulkhead %d %s corridor %d-%d  ·  route %d->%d now via %s" % [
		prop_index, "sealed" if sealed else "opened", edge.x, edge.y,
		edge.x, edge.y, "no route" if hop < 0 else "room %d" % hop])


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	if _lock > 0.0:
		return "BULKHEAD CYCLING"
	if Props.is_sealed(prop_index):
		return "HOLD E  ·  RELEASE BULKHEAD  ·  %ds" % int(
				ceil(Props.seal_remaining(prop_index)))
	return "HOLD E  ·  SEAL BULKHEAD"


func prompt_title() -> String:
	if Props.is_sealed(prop_index):
		return "SEALED  ·  %ds" % int(ceil(Props.seal_remaining(prop_index)))
	return "SEAL BULKHEAD"


func prompt_glyph() -> String:
	return "▮"


func prompt_height() -> float:
	return CLEAR_HEIGHT - 0.9


func available() -> bool:
	return Run.local_running() and _lock <= 0.0


func complete() -> void:
	Props.request_seal(prop_index, not Props.is_sealed(prop_index))


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


# ------------------------------------------------------------------ visuals --

func _process(delta: float) -> void:
	_lock = maxf(_lock - delta, 0.0)
	var sealed: bool = Props.is_sealed(prop_index)
	var left: float = Props.seal_remaining(prop_index)
	# Closing is fast and opening is slower: MOTHER forcing a door is a machine
	# being overridden, and it should look like it is being made to give way.
	_closed = move_toward(_closed, 1.0 if sealed else 0.0,
			delta * (2.4 if sealed else 1.3))

	var eased: float = 1.0 - pow(1.0 - _closed, 2.4)
	for i: int in _leaves.size():
		# Leaf 0 owns the -X half and retracts to -X; leaf 1 mirrors it. The signs
		# have to match `_assemble`'s, or an "open" door slides both halves across
		# each other into the middle of the corridor and stands there looking
		# permanently shut — which is exactly what the first capture of this showed.
		var sign_x: float = -1.0 if i == 0 else 1.0
		_leaves[i].position.x = sign_x * SPAN * 0.5 * (1.0 - eased)

	# The collider only exists once the leaves have genuinely met. Enabling it
	# early is how a door traps somebody standing under it.
	var solid: bool = eased > 0.93
	if _shape.disabled == solid:
		_shape.disabled = not solid
		_blocker.collision_layer = 1 if solid else 0

	var t: float = UiFx.clock()
	var warning: bool = sealed and left <= Balance.BULKHEAD_WARN_SECONDS
	var colour: Color = OPEN_COLOUR
	var energy: float = 0.45 + _channel * 1.6
	if warning:
		# MOTHER's hiss made visible: a hard two-beat on the header lamp for the
		# last few seconds, so a player with their back to the door still knows.
		var beat: float = UiFx.heartbeat(t, 0.5)
		colour = WARN_COLOUR
		energy = 0.6 + beat * 3.4
	elif sealed:
		colour = SEALED_COLOUR
		energy = 0.5 + (0.5 + 0.5 * sin(t * 1.3)) * 0.5

	_lamp_material.emission = colour
	_lamp_material.emission_energy_multiplier = 0.6 + energy * 1.4
	_strip_material.emission = FRAME_COLOUR.lerp(colour, eased)
	_strip_material.emission_energy_multiplier = 0.5 + eased * 0.9 + _channel
	_light.light_color = colour
	_light.light_energy = energy


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


func _group_box(group: Node3D, at: Vector3, size: Vector3,
		material: StandardMaterial3D) -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	group.add_child(mesh)


func _emissive(colour: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(0.66)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.45
	material.disable_receive_shadows = true
	return material
