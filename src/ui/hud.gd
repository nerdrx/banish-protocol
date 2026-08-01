class_name Hud
extends CanvasLayer
## In-intrusion HUD: crosshair, crew roster with connection quality, and the pause
## overlay that releases the mouse.
##
## Deliberately minimal for M1. DESIGN.md wants this to go diegetic (Cycles ring,
## shell glow) in M2/M4 — nothing here should grow into a stat wall.

const PING_INTERVAL: float = 0.5
const NOTICE_DURATION: float = 4.0

@onready var _crew_list: VBoxContainer = %CrewList
@onready var _link_label: Label = %LinkLabel
@onready var _notice_label: Label = %NoticeLabel
@onready var _pause: Control = %PauseOverlay
@onready var _resume_button: Button = %ResumeButton
@onready var _leave_button: Button = %LeaveButton

var _ping_clock: float = 0.0
var _notice_clock: float = 0.0


func _ready() -> void:
	Net.crew_changed.connect(_rebuild_crew)
	Net.notice.connect(_show_notice)
	_resume_button.pressed.connect(_set_paused.bind(false))
	_leave_button.pressed.connect(_on_leave_pressed)
	_pause.visible = false
	_notice_label.text = ""
	_rebuild_crew()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_set_paused(not _pause.visible)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_ping_clock -= delta
	if _ping_clock <= 0.0:
		_ping_clock = PING_INTERVAL
		_refresh_link()

	if _notice_clock > 0.0:
		_notice_clock -= delta
		var fade: float = clampf(_notice_clock / 1.2, 0.0, 1.0)
		_notice_label.modulate.a = fade
		if _notice_clock <= 0.0:
			_notice_label.text = ""


# --------------------------------------------------------------------- crew --

func _rebuild_crew() -> void:
	for child: Node in _crew_list.get_children():
		child.queue_free()

	var ids: Array = Net.crew.keys()
	ids.sort()
	for id: int in ids:
		_crew_list.add_child(_crew_row(int(id)))
	_refresh_link()


func _crew_row(id: int) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var marker: ColorRect = ColorRect.new()
	marker.custom_minimum_size = Vector2(4.0, 14.0)
	marker.color = Net.crew_color(id)
	row.add_child(marker)

	var label: Label = Label.new()
	label.text = Net.crew_name(id)
	label.add_theme_font_size_override("font_size", 13)
	var is_self: bool = id == Net.local_id()
	label.add_theme_color_override("font_color",
			Color(0.88, 0.94, 1.0) if is_self else Color(0.55, 0.62, 0.72))
	row.add_child(label)

	var tag: Label = Label.new()
	tag.name = "Latency"
	tag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tag.add_theme_font_size_override("font_size", 11)
	tag.add_theme_color_override("font_color", Color(0.34, 0.42, 0.5))
	tag.text = "HOST" if id == 1 else ""
	row.add_child(tag)
	row.set_meta("peer_id", id)
	return row


func _refresh_link() -> void:
	if not Net.is_online:
		_link_label.text = "OFFLINE"
		return

	for row: Node in _crew_list.get_children():
		if not row.has_meta("peer_id"):
			continue
		var id: int = int(row.get_meta("peer_id"))
		var tag: Label = row.get_node_or_null("Latency") as Label
		if tag == null:
			continue
		if id == 1:
			tag.text = "HOST"
		elif id == Net.local_id():
			tag.text = "YOU"
		else:
			tag.text = "%d ms" % Net.ping_ms(id)

	if multiplayer.is_server():
		_link_label.text = "LISTEN HOST  ·  %d CREW" % Net.crew.size()
	else:
		var ping: int = Net.ping_ms(1)
		_link_label.text = "LINK %d ms" % ping
		var quality: Color = Color(0.4, 0.85, 0.6)
		if ping > 120:
			quality = Color(0.95, 0.45, 0.4)
		elif ping > 60:
			quality = Color(0.95, 0.75, 0.35)
		_link_label.add_theme_color_override("font_color", quality)


func _show_notice(message: String) -> void:
	_notice_label.text = message
	_notice_label.modulate.a = 1.0
	_notice_clock = NOTICE_DURATION


# -------------------------------------------------------------------- pause --

func _set_paused(paused: bool) -> void:
	_pause.visible = paused
	if DisplayServer.get_name() == "headless":
		return
	Input.set_mouse_mode(
			Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED)


func _on_leave_pressed() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Net.leave("YOU ABORTED THE INTRUSION")
