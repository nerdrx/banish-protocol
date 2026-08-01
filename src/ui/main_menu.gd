class_name MainMenu
extends Control
## Crew assembly screen: pick a callsign and shell marker, then host or join.
##
## Every failure path ends here with a readable message rather than a hang —
## `Net.connect_failed` is the single funnel for "we could not get you in".

@onready var _name_edit: LineEdit = %NameEdit
@onready var _ip_edit: LineEdit = %IpEdit
@onready var _port_edit: LineEdit = %PortEdit
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _quit_button: Button = %QuitButton
@onready var _status_label: Label = %StatusLabel
@onready var _color_row: HBoxContainer = %ColorRow

var _swatches: Array[Button] = []
var _color_index: int = 0


func _ready() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	_build_swatches()
	_name_edit.text = GameState.local_name
	_port_edit.text = str(Net.DEFAULT_PORT)
	_ip_edit.text = "127.0.0.1"

	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_quit_button.pressed.connect(func() -> void: get_tree().quit())
	_ip_edit.text_submitted.connect(func(_t: String) -> void: _on_join_pressed())
	Net.connect_failed.connect(_on_connect_failed)

	var carried: String = GameState.consume_status()
	if carried.is_empty():
		_set_status("AWAITING ORDERS", Color(0.38, 0.44, 0.52))
	else:
		_set_status(carried, Color(0.95, 0.55, 0.35))


# ------------------------------------------------------------------ swatches --

func _build_swatches() -> void:
	for index: int in GameState.DEFAULT_COLORS.size():
		var swatch: Button = Button.new()
		swatch.custom_minimum_size = Vector2(40.0, 34.0)
		swatch.focus_mode = Control.FOCUS_NONE
		swatch.pressed.connect(_select_color.bind(index))
		_color_row.add_child(swatch)
		_swatches.append(swatch)
	_select_color(0)


func _select_color(index: int) -> void:
	_color_index = index
	for i: int in _swatches.size():
		_paint_swatch(_swatches[i], GameState.DEFAULT_COLORS[i], i == index)


func _paint_swatch(swatch: Button, color: Color, selected: bool) -> void:
	for state: String in ["normal", "hover", "pressed", "focus"]:
		var style: StyleBoxFlat = StyleBoxFlat.new()
		style.bg_color = color.darkened(0.2 if selected else 0.5)
		style.bg_color.a = 1.0 if selected else 0.75
		style.border_color = Color(0.85, 0.94, 1.0) if selected else color.darkened(0.2)
		var width: int = 2 if selected else 1
		style.border_width_left = width
		style.border_width_top = width
		style.border_width_right = width
		style.border_width_bottom = width
		if state == "hover":
			style.bg_color = color.darkened(0.25)
		swatch.add_theme_stylebox_override(state, style)


# ------------------------------------------------------------------- actions --

func _apply_identity() -> void:
	GameState.local_name = GameState.sanitize_name(_name_edit.text)
	GameState.local_color = GameState.DEFAULT_COLORS[_color_index]
	_name_edit.text = GameState.local_name


func _port() -> int:
	var value: int = _port_edit.text.strip_edges().to_int()
	return value if value > 0 and value < 65536 else Net.DEFAULT_PORT


func _on_host_pressed() -> void:
	_apply_identity()
	_set_busy(true)
	_set_status("OPENING DOCK ON PORT %d..." % _port(), Color(0.5, 0.8, 1.0))
	Net.host(_port(), false)


func _on_join_pressed() -> void:
	var address: String = _ip_edit.text.strip_edges()
	if address.is_empty():
		_set_status("ENTER A HOST ADDRESS", Color(0.95, 0.45, 0.4))
		return
	_apply_identity()
	_set_busy(true)
	_set_status("HAILING %s..." % address, Color(0.5, 0.8, 1.0))
	Net.join(address, _port())


func _on_connect_failed(reason: String) -> void:
	_set_busy(false)
	_set_status(reason, Color(0.95, 0.45, 0.4))


func _set_busy(busy: bool) -> void:
	_host_button.disabled = busy
	_join_button.disabled = busy


func _set_status(message: String, color: Color) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", color)
