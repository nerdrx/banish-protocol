class_name ProgramTerminal
extends Interactable
## Your PROGRAM, on a screen you can walk up to.
##
## Everything on this face already exists in `GameState` and the main menu already
## prints it — archive, compiled tiers, deepest backdoor, lifetime counters. The
## point of putting it here is that the hub IS the menu (DESIGN.md), and a stat
## screen that only exists behind Escape is one more reason to never be in the
## room. So the numbers get a physical location: records alcove, east side, bolted
## to MOTHER's wall with the crew's own bracket.
##
## Cassette futurism, deliberately (DESIGN.md "HUD"): this is HUMAN kit — a
## phosphor tube in an amber housing, scanlines and all — sitting in an
## architecture of flush neon inlay. It is meant to look like something that was
## carried in, because it was.
##
## The text is drawn into a Label3D rather than a shader-driven CRT: it changes
## about twice a session (a purchase, a rooted node) and every frame it is not
## changing has to cost nothing. It refreshes on the two signals that can move it
## and on nothing else.

const SCREEN_COLOUR: Color = Color(1.0, 0.72, 0.32)
const SCREEN_W: float = 1.5
const SCREEN_H: float = 1.0

var _screen_material: StandardMaterial3D = null
var _label: Label3D = null
var _light: OmniLight3D = null


static func create(where: Vector3, yaw: float) -> ProgramTerminal:
	var terminal: ProgramTerminal = ProgramTerminal.new()
	terminal.name = "ProgramTerminal"
	terminal.position = where
	terminal.rotation.y = yaw
	# There is nothing to commit to, so there is nothing to channel. A quick tap
	# refreshes the face — which is only ever a courtesy, since the signals below
	# keep it live anyway.
	terminal.channel_time = 0.25
	terminal._assemble()
	return terminal


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# Housing: a deep box on a wall bracket, tilted back the way a monitor on a
	# shelf is. The bracket is visible on purpose — nothing the crew installed in
	# the Partition is flush with her walls.
	_add_mesh(Vector3(0.0, 1.5, 0.35), Vector3(1.9, 1.4, 0.7), casing)
	_add_mesh(Vector3(0.0, 0.78, 0.5), Vector3(2.1, 0.12, 0.9), casing)
	for side: float in [-1.0, 1.0]:
		_add_mesh(Vector3(side * 0.85, 1.16, 0.62), Vector3(0.1, 0.8, 0.1), casing)

	_screen_material = StandardMaterial3D.new()
	_screen_material.albedo_color = SCREEN_COLOUR.darkened(0.86)
	_screen_material.emission_enabled = true
	_screen_material.emission = SCREEN_COLOUR
	_screen_material.emission_energy_multiplier = 0.45
	_screen_material.roughness = 0.25
	_screen_material.disable_receive_shadows = true
	_add_mesh(Vector3(0.0, 1.52, -0.02), Vector3(SCREEN_W, SCREEN_H, 0.04),
			_screen_material)

	_label = Label3D.new()
	_label.name = "Face"
	_label.position = Vector3(0.0, 1.52, -0.06)
	_label.rotation.y = PI
	_label.font_size = 26
	# Pixel size is what makes a Label3D a readable panel rather than a billboard:
	# at 0.0016 the block below is ~1.4 m wide, which fits the tube with a margin.
	_label.pixel_size = 0.0016
	_label.modulate = SCREEN_COLOUR
	_label.outline_size = 0
	_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_label.shaded = false
	_label.double_sided = false
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_label.width = SCREEN_W / 0.0016
	add_child(_label)

	_light = OmniLight3D.new()
	_light.name = "ScreenCast"
	_light.position = Vector3(0.0, 1.52, -0.6)
	_light.light_color = SCREEN_COLOUR
	_light.light_energy = 0.85
	_light.omni_range = 4.2
	_light.omni_attenuation = 0.9
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(2.0, 1.6, 0.9), Vector3(0.0, 1.5, 0.0))


func _ready() -> void:
	_refresh()
	# The two things that can move these numbers mid-session. Nothing polls.
	Net.crew_changed.connect(_refresh)
	Run.hub_changed.connect(_refresh)


func _add_mesh(at: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	add_child(mesh)
	return mesh


## The face. Fixed-width columns, uppercase, no prose — this is an instrument
## readout, and the HUD's own voice is the one it speaks in.
func _refresh() -> void:
	if _label == null or not is_instance_valid(_label):
		return
	var lines: PackedStringArray = PackedStringArray()
	lines.append("PROGRAM  %s" % GameState.sanitize_name(GameState.local_name))
	lines.append("")
	lines.append("ARCHIVE          %d" % GameState.archive)
	lines.append("DEEPEST BACKDOOR %s" % ("NONE" if GameState.deepest_backdoor <= 0
			else "%02d" % GameState.deepest_backdoor))
	lines.append("")
	lines.append("RUNS  %d   EXFILS  %d" % [
		GameState.stat("runs"), GameState.stat("exfils")])
	lines.append("DELETIONS  %d   BANKED  %d" % [
		GameState.stat("deletions"), GameState.stat("data_banked")])
	lines.append("")
	var compiled: String = Modules.describe(GameState.modules)
	lines.append("MODULES  %s" % ("NONE COMPILED" if compiled.is_empty() else compiled))
	_label.text = "\n".join(lines)


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	return "HOLD E  ·  PROGRAM"


func prompt_title() -> String:
	return "PROGRAM  ·  %s" % GameState.sanitize_name(GameState.local_name)


func prompt_glyph() -> String:
	return "■"


func prompt_height() -> float:
	return 2.6


func complete() -> void:
	_refresh()
