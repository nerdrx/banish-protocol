class_name CompilerTerminal
extends Interactable
## Where you spend what you stole.
##
## DESIGN.md, "Meta-progression": one Compiler hidden on every layer, one
## guaranteed in every backdoor sanctuary, deeper ones stocking higher tiers.
## Buffered data and archive are both spendable here, and what you buy is
## compiled into your source forever.
##
## The terminal itself is a face on host-authoritative state, the same way the
## backdoor node is: nothing about a purchase is decided here. Holding E opens
## the panel (locally, on the peer that did it — a Compiler is a *per-player*
## screen, and two crewmates can be browsing the same machine at once); the panel
## sends a request; the host validates funds, proximity and stock and answers.
##
## Built entirely from code so the generator can stand one anywhere without a
## scene dependency, and so its emissive materials are per-instance: a terminal
## that is being used lights up, and the one two rooms away does not.

## Physical stations are teal because they are working machinery MOTHER still
## runs; the interface plate runs the system colour hot, because it is the one
## surface in the layer that is talking to *you*.
const CASING_COLOUR: Color = Color(0.24, 0.78, 0.95)
const SCREEN_COLOUR: Color = Color(0.42, 0.95, 1.0)
## Sanctuary terminals wear the backdoor room's amber instead, so "this one is
## safe and stocks deeper" is legible from the doorway without a word of text.
const SANCTUARY_COLOUR: Color = Color(1.0, 0.76, 0.36)

## How close the host requires a buyer to be. Generous against the interact
## reach (3.4) so a purchase is never refused for a step taken while the panel
## was open — the panel does not close when you shuffle.
const USE_RANGE: float = 6.5

## Quick, not a channel. A Compiler is a menu, and the four seconds a backdoor
## node takes are four seconds of *commitment*; opening a shop is not that. Long
## enough that you cannot open it by brushing past.
const OPEN_TIME: float = 0.35

## Index within the layer's compiler list. Seeded content, so this is all a
## purchase packet ever has to carry.
var compiler_index: int = 0
## Highest module tier this terminal will sell (LayerParams.compiler_tier, plus
## one in a sanctuary).
var stock_tier: int = 1
var sanctuary: bool = false

var _screen_material: StandardMaterial3D = null
var _trim_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _channel: float = 0.0
## Rises while the local player has this terminal's panel open, so the machine
## is visibly the one being used.
var _engaged: float = 0.0


static func create(index: int, where: Vector3, yaw: float, tier: int,
		is_sanctuary: bool) -> CompilerTerminal:
	var terminal: CompilerTerminal = CompilerTerminal.new()
	terminal.name = "Compiler%d" % index
	terminal.compiler_index = index
	terminal.stock_tier = maxi(tier, 1)
	terminal.sanctuary = is_sanctuary
	terminal.position = where
	terminal.rotation.y = yaw
	terminal.channel_time = OPEN_TIME
	terminal._assemble()
	return terminal


## The terminal with this index on the layer that is currently standing. Used by
## the host to check a buyer is where they say they are, and by the dev flags.
static func find(tree: SceneTree, index: int) -> CompilerTerminal:
	for node: Node in tree.get_nodes_in_group("compilers"):
		var terminal: CompilerTerminal = node as CompilerTerminal
		if terminal != null and is_instance_valid(terminal) \
				and terminal.compiler_index == index:
			return terminal
	return null


## Whichever Compiler `from` is closest to and within reach of, or null. What the
## `--compiler` capture flag and the panel's own "am I still at the machine"
## check both ask.
static func nearest(tree: SceneTree, from: Vector3) -> CompilerTerminal:
	var best: CompilerTerminal = null
	var best_distance: float = USE_RANGE
	for node: Node in tree.get_nodes_in_group("compilers"):
		var terminal: CompilerTerminal = node as CompilerTerminal
		if terminal == null or not is_instance_valid(terminal):
			continue
		var distance: float = terminal.global_position.distance_to(from)
		if distance < best_distance:
			best_distance = distance
			best = terminal
	return best


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")
	var accent: Color = SANCTUARY_COLOUR if sanctuary else CASING_COLOUR

	# A lectern, not a kiosk. Heavy plinth, two ribs, and a plate raked back at
	# reading angle — the silhouette has to say "stand here and use me" from
	# across a dark room, before any of the emissive is close enough to read.
	_add_mesh(Vector3(0.0, 0.16, 0.0), Vector3(1.9, 0.32, 1.35), casing)
	_add_mesh(Vector3(0.0, 0.62, 0.16), Vector3(1.5, 0.72, 0.85), casing)
	for side: float in [-0.82, 0.82]:
		_add_mesh(Vector3(side, 0.95, 0.1), Vector3(0.16, 1.9, 0.22), casing)
		_add_mesh(Vector3(side, 1.92, 0.1), Vector3(0.26, 0.12, 0.34), casing)
	# Cowl over the plate, so the screen glow pools under it instead of washing
	# the whole room. The layer stays dark; the terminal does not.
	_add_mesh(Vector3(0.0, 1.86, -0.22), Vector3(1.75, 0.14, 0.72), casing)

	# The plate is a **screen**, not a lamp.
	#
	# The first version of this made the whole 1.4 x 1.0 face emissive at 2.4,
	# which with the game's bloom turned a terminal into a white trapezoid that
	# ate the room from four metres away — the exact failure DESIGN.md warns
	# about for the data chips ("never a glowing volume"). A screen is a dark
	# surface with bright *lines* on it, so the face runs barely above black and
	# the light comes off a rank of thin readout bars sitting a few millimetres
	# proud of it.
	var backing: StandardMaterial3D = _emissive(SCREEN_COLOUR.darkened(0.55), 0.22)
	var plate: MeshInstance3D = _add_mesh(Vector3(0.0, 1.3, -0.14),
			Vector3(1.38, 0.96, 0.07), backing)
	plate.rotation.x = deg_to_rad(-16.0)

	# Eight rows on the face, one per module track — the machine is displaying
	# the list before you ever open the panel, so what it sells is legible from
	# across the room without a word of UI.
	_screen_material = _emissive(SCREEN_COLOUR if not sanctuary
			else SANCTUARY_COLOUR, 2.0)
	for i: int in Balance.MODULE_TRACKS.size():
		var t: float = (float(i) + 0.5) / float(Balance.MODULE_TRACKS.size())
		# Ragged line lengths, hashed off the row rather than random: a readout
		# of eight identical bars reads as a test card.
		var width: float = 0.46 + UiFx.hash01(float(i) * 3.7) * 0.62
		var row: MeshInstance3D = MeshInstance3D.new()
		var bar_mesh: BoxMesh = BoxMesh.new()
		bar_mesh.size = Vector3(width, 0.035, 0.012)
		row.mesh = bar_mesh
		# NEGATIVE z. The terminal's -Z faces the room (see the builder's yaw), so
		# the plate's readable face is its -Z one; rows on +Z would be a screen
		# displaying into the back of its own casing, which is exactly what the
		# first version of this did and it took a capture to notice.
		row.position = Vector3(-0.52 + width * 0.5, lerpf(0.36, -0.36, t), -0.045)
		row.material_override = _screen_material
		row.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		plate.add_child(row)

	# Stock readout on the plinth: one bar per tier this terminal sells. A player
	# learns to read the depth of a Compiler off the machine, not off the panel.
	_trim_material = _emissive(accent, 0.9)
	for i: int in Balance.MODULE_MAX_TIER:
		var bar: MeshInstance3D = _add_mesh(
				Vector3(-0.6 + float(i) * 0.3, 0.42, -0.5),
				Vector3(0.2, 0.05, 0.05), _trim_material)
		bar.visible = i < stock_tier

	# The cable that says the thing is plumbed into the layer.
	_add_mesh(Vector3(0.0, 0.03, 0.62), Vector3(1.6, 0.06, 0.12), _trim_material)

	# Feeble on purpose, and pointed at its own cowl rather than at the room. Its
	# job is to put a pool of light on the machine so a beam sweeping past finds
	# a silhouette — not to light the room, which would undo the darkness the
	# whole game rests on.
	_light = OmniLight3D.new()
	_light.name = "CompilerGlow"
	_light.position = Vector3(0.0, 1.5, -0.45)
	_light.light_color = SCREEN_COLOUR if not sanctuary else SANCTUARY_COLOUR
	_light.light_energy = 1.1
	_light.omni_range = 6.4
	_light.omni_attenuation = 1.15
	_light.light_volumetric_fog_energy = 1.3
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(2.2, 2.6, 2.0), Vector3(0.0, 1.2, 0.0))


func _ready() -> void:
	add_to_group("compilers")


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
	material.roughness = 0.4
	material.disable_receive_shadows = true
	return material


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	return "HOLD E  ·  ACCESS COMPILER"


func prompt_title() -> String:
	return "ACCESS  ·  COMPILER"


func prompt_glyph() -> String:
	return "▩"


func prompt_height() -> float:
	return 2.35


## The panel is modal on the peer that opened it, so the prompt goes away while
## it is up rather than hanging behind the interface.
func prompt_visible() -> bool:
	return not CompilerPanel.is_open()


func available() -> bool:
	return Run.local_running() and not CompilerPanel.is_open()


func complete() -> void:
	CompilerPanel.open_for(self)


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


func _process(delta: float) -> void:
	var open: bool = CompilerPanel.is_open_for(self)
	_engaged = move_toward(_engaged, 1.0 if open else 0.0, delta * 3.0)

	var t: float = UiFx.clock()
	# Idle: a slow readout cycling something you are not party to. Engaged: the
	# machine is compiling for you, and it says so by running hot.
	var idle: float = 0.82 + sin(t * 1.9) * 0.18
	var charge: float = 1.0 + _channel * 1.6 + _engaged * 2.2
	_screen_material.emission_energy_multiplier = 2.0 * idle * charge
	_trim_material.emission_energy_multiplier = (0.9 + _engaged * 0.8) * idle
	_light.light_energy = 1.1 * idle * (1.0 + _channel * 0.8 + _engaged * 1.4)
