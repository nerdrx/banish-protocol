class_name JunctionPanel
extends CanvasLayer
## Your readout of a rewire junction: three loads, one bus, pick one.
##
## Written in the M3.8/M4.7 interface language and built the same way the
## Compiler's panel is — the same tube, the same phosphor, the same clip-reveal —
## because it is the same piece of hardware. What you are looking at is not
## MOTHER's panel; it is *your* Northcairn instrument rendering her panel, which
## is why it is amber and scanlined while the box on the wall is teal.
##
## Deliberately much smaller than the Compiler's. That panel is a shop with eight
## rows and a wallet; this is a three-position switch, and it should read as one
## in the half second before you decide.
##
## Per player, local, unreplicated. The only thing that leaves is
## `Props.request_rewire`, and the host decides.

static var _open: JunctionPanel = null

## Wide enough for the LONGEST row this panel can draw — the fans' note plus the
## POWERED state column — with the CRT's barrel distortion in mind: the tube
## pushes edge content outward, so a panel that only just fits on a flat screen
## bleeds past its own border through the glass. Measured against the widest
## string rather than guessed, and every cell clips as well, so a future longer
## note degrades to an ellipsis instead of escaping the plate.
const WIDTH: float = 780.0
const ROW_HEIGHT: float = 58.0
const PAD: float = 24.0
const REVEAL_ROW: float = 0.07

## The three loads, in the order the box's lamps are in.
##
## Glyphs are drawn from the set the Compiler panel already proved renders on the
## mono fallback chain (Balance.MODULES). A panel is not the place to discover
## that a character your font does not have comes out as a hollow box — the first
## capture of this had two of the three doing exactly that.
const LOADS: Array[Dictionary] = [
	{
		"mode": Props.Power.LIGHTS, "glyph": "✦", "name": "ROOM LIGHTING",
		"note": "EMERGENCY STRIPS  ·  THIS SECTOR + APPROACH",
	},
	{
		"mode": Props.Power.DOORS, "glyph": "▣", "name": "DOOR LOCKS",
		"note": "CABINET LOCKS RELEASED  ·  SILENT ENTRY",
	},
	{
		"mode": Props.Power.FANS, "glyph": "≡", "name": "VENT FANS",
		"note": "INGRESS COVERS DRIVEN SHUT  ·  TIMED",
	},
]

var junction: RewireJunction = null

var _rows: Array[Control] = []
var _selected: int = 0
var _reveal: float = 0.0
var _subtitle: Label = null
var _footer: Label = null


static func is_open() -> bool:
	return _open != null and is_instance_valid(_open)


static func is_open_for(which: RewireJunction) -> bool:
	return is_open() and _open.junction == which


## Opens the panel for the local player. Parented to the root rather than to the
## prop, for the same reason the Compiler's is: a descent frees the layer, and a
## panel left pointing at a junction that no longer exists is a crash.
static func open_for(which: RewireJunction) -> JunctionPanel:
	if is_open():
		_open.close()
	if which == null or not is_instance_valid(which):
		return null
	var panel: JunctionPanel = JunctionPanel.new()
	panel.name = "JunctionPanel"
	panel.junction = which
	panel.layer = 3
	which.get_tree().get_root().add_child(panel)
	_open = panel
	return panel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Run.run_ended.connect(func(_s: Dictionary) -> void: close())
	Run.descent_started.connect(func(_n: int) -> void: close())
	Props.power_changed.connect(_refresh)
	if Debug.may_capture_mouse():
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_reveal = 99.0 if Debug.automated else 0.0
	# Start on whatever is currently powered, so ACCEPT on an already-routed bus
	# is a no-op rather than an accident.
	for i: int in LOADS.size():
		if int(LOADS[i]["mode"]) == Props.power:
			_selected = i
	print("[Junction] panel open at junction %d (power %s)" % [
		junction.prop_index, Props.power_name(Props.power)])


func close() -> void:
	if _open == self:
		_open = null
	if Debug.may_capture_mouse():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	queue_free()


# -------------------------------------------------------------------- build --

func _build() -> void:
	var screen: SubViewportContainer = SubViewportContainer.new()
	screen.name = "Screen"
	screen.stretch = true
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_PASS
	var glass: ShaderMaterial = ShaderMaterial.new()
	glass.shader = Hud.CRT_SHADER
	glass.set_shader_parameter("amount", UiFx.TUBE_AMOUNT)
	glass.set_shader_parameter("gain", 1.22)
	glass.set_shader_parameter("scanline_strength", 0.17)
	glass.set_shader_parameter("curvature", 0.038)
	glass.set_shader_parameter("vignette", 0.22)
	screen.material = glass
	add_child(screen)

	var tube: SubViewport = SubViewport.new()
	tube.name = "Tube"
	tube.transparent_bg = true
	tube.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tube.own_world_3d = false
	screen.add_child(tube)

	var shade: ColorRect = ColorRect.new()
	shade.name = "Shade"
	shade.color = Color(0.02, 0.012, 0.004, 0.62)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	tube.add_child(shade)

	var centre: CenterContainer = CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tube.add_child(centre)

	var holder: Control = Control.new()
	holder.name = "Panel"
	holder.custom_minimum_size = Vector2(WIDTH,
			ROW_HEIGHT * float(LOADS.size()) + 176.0)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(holder)

	var back: ColorRect = ColorRect.new()
	back.name = "Plate"
	back.color = Color(0.045, 0.030, 0.012, 0.93)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(back)
	for edge: int in 4:
		var line: ColorRect = ColorRect.new()
		line.color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.55)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		match edge:
			0:
				line.set_anchors_preset(Control.PRESET_TOP_WIDE)
				line.offset_bottom = 2.0
			1:
				line.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
				line.offset_top = -2.0
			2:
				line.set_anchors_preset(Control.PRESET_LEFT_WIDE)
				line.offset_right = 1.0
			_:
				line.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
				line.offset_left = -1.0
		back.add_child(line)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.offset_left = PAD
	column.offset_right = -PAD
	column.offset_top = PAD * 0.8
	column.offset_bottom = -PAD * 0.8
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.add_child(column)

	_text(column, "MAINTENANCE BUS  ·  LOAD SELECT", 24, UiFx.SYSTEM)
	_subtitle = _text(column, "", 13, UiFx.DIM)
	column.add_child(_rule())

	for i: int in LOADS.size():
		var row: Control = _build_row(i)
		column.add_child(row)
		_rows.append(row)

	column.add_child(_rule())
	_footer = _text(column, "", 12, UiFx.DIM)

	var sheen: ColorRect = ColorRect.new()
	sheen.set_anchors_preset(Control.PRESET_FULL_RECT)
	sheen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheen.color = Color.WHITE
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = Hud.SHEEN_SHADER
	material.set_shader_parameter("tint", UiFx.SYSTEM)
	material.set_shader_parameter("sheen_strength", 0.05)
	material.set_shader_parameter("scanline_strength", 0.02)
	material.set_shader_parameter("sweep_period", 5.5)
	material.set_shader_parameter("sweep_width", 0.05)
	material.set_shader_parameter("perspective", 0.0)
	material.set_shader_parameter("mask_start", 0.94)
	sheen.material = material
	back.add_child(sheen)


func _build_row(index: int) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "Row_%d" % index
	row.custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.set_meta("index", index)

	var marker: ColorRect = ColorRect.new()
	marker.name = "Marker"
	marker.custom_minimum_size = Vector2(3.0, 0.0)
	marker.color = UiFx.SYSTEM
	row.add_child(marker)

	var glyph: Label = _cell(row, String(LOADS[index]["glyph"]), 22, UiFx.SYSTEM, 36.0)
	glyph.name = "Glyph"
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var name_label: Label = _cell(row, String(LOADS[index]["name"]), 18, UiFx.TEXT, 168.0)
	name_label.name = "Name"

	var note_text: String = String(LOADS[index]["note"])
	if int(LOADS[index]["mode"]) == Props.Power.FANS:
		note_text = "INGRESS COVERS DRIVEN SHUT  ·  %d SECONDS" % int(
				Balance.VENT_FAN_SECONDS)
	var note: Label = _cell(row, note_text, 12, UiFx.DIM, 0.0)
	note.name = "Note"
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var state: Label = _cell(row, "", 15, UiFx.SYSTEM, 92.0)
	state.name = "State"
	state.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	row.mouse_entered.connect(func() -> void: _selected = index)
	row.gui_input.connect(func(event: InputEvent) -> void:
		var click: InputEventMouseButton = event as InputEventMouseButton
		if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			_selected = index
			_route())
	return row


func _cell(parent: Control, text: String, size: int, colour: Color,
		width: float) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.custom_minimum_size = Vector2(width, 0.0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Nothing in a fixed-width cell may push its neighbours off the plate.
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	parent.add_child(label)
	return label


func _text(parent: Control, text: String, size: int, colour: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	parent.add_child(label)
	return label


func _rule() -> Control:
	var line: ColorRect = ColorRect.new()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.28)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


# -------------------------------------------------------------------- input --

## Keyboard, mouse and pad from one path — `ui_*` actions, which Godot already
## binds to the D-pad and the face buttons. Gamepad parity here is free and it is
## not an accident: DESIGN.md's accessibility line means every panel in the game
## has to be operable without a mouse.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_down"):
		_selected = (_selected + 1) % _rows.size()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_up"):
		_selected = (_selected + _rows.size() - 1) % _rows.size()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_route()
		get_viewport().set_input_as_handled()


## Public so an automated run drives the same path a keypress does.
func select(mode: int) -> void:
	for i: int in LOADS.size():
		if int(LOADS[i]["mode"]) == mode:
			_selected = i
			return


func route_selected() -> void:
	_route()


func _route() -> void:
	var mode: int = int(LOADS[_selected]["mode"])
	# Selecting what is already powered cuts it instead — a three-way switch with
	# an off position, which is what makes "nothing is routed" a state you can
	# choose rather than only a state you start in.
	Props.request_rewire(Props.Power.NONE if Props.power == mode else mode)


# ----------------------------------------------------------------- updating --

func _process(delta: float) -> void:
	if junction == null or not is_instance_valid(junction):
		close()
		return
	var me: Node = Net.get_player(Net.local_id())
	if me != null and is_instance_valid(me) \
			and (me as Node3D).global_position.distance_to(
					junction.global_position) > Balance.JUNCTION_USE_RANGE:
		close()
		return
	_reveal += delta
	_refresh()


func _refresh() -> void:
	if _subtitle == null:
		return
	var graph_room: String = String(junction.get_meta("room_name", "SECTOR"))
	_subtitle.text = "JUNCTION %02d  ·  %s  ·  ONE LOAD AT A TIME" % [
		junction.prop_index, graph_room]

	for i: int in _rows.size():
		_refresh_row(i)

	if Props.power == Props.Power.FANS and Props.fans_remaining > 0.0:
		_footer.text = "FANS DRIVEN  ·  %02d s REMAINING" % int(
				ceil(Props.fans_remaining))
		_footer.add_theme_color_override("font_color", UiFx.WARNING)
	else:
		_footer.text = "↑↓ SELECT   ·   ACCEPT ROUTE   ·   BACK CLOSE   ·   REROUTING IS LOUD"
		_footer.add_theme_color_override("font_color", UiFx.DIM)


func _refresh_row(index: int) -> void:
	var row: Control = _rows[index]
	var mode: int = int(LOADS[index]["mode"])
	var powered: bool = Props.power == mode
	var chosen: bool = index == _selected

	var visible_now: bool = _reveal >= float(index) * REVEAL_ROW
	row.modulate.a = 1.0 if visible_now else 0.0
	if not visible_now:
		return

	var lit: Color = UiFx.SYSTEM if powered else UiFx.DIM
	var marker: ColorRect = row.get_node("Marker") as ColorRect
	marker.color = Color(lit.r, lit.g, lit.b, 1.0 if chosen else 0.22)
	marker.custom_minimum_size.x = 4.0 if chosen else 3.0

	(row.get_node("Glyph") as Label).add_theme_color_override("font_color", lit)
	(row.get_node("Name") as Label).add_theme_color_override("font_color",
			UiFx.SYSTEM_HOT if chosen else (UiFx.TEXT if powered else UiFx.DIM))
	(row.get_node("Note") as Label).add_theme_color_override("font_color",
			UiFx.TEXT if chosen else UiFx.DIM)

	var state: Label = row.get_node("State") as Label
	state.text = "● POWERED" if powered else "○ CUT"
	state.add_theme_color_override("font_color",
			UiFx.SYSTEM_HOT if powered else UiFx.DIM)
