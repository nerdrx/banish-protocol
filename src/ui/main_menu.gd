class_name MainMenu
extends Control
## Crew assembly screen: pick a callsign and shell marker, choose a transport,
## then host or join.
##
## Every failure path ends here with a readable message rather than a hang —
## `Net.connect_failed` is the single funnel for "we could not get you in".
##
## M3.5 splits the bottom half of the console in two (DESIGN.md "Steam
## Integration"):
##
##   STEAM  — default whenever the API came up. Host opens a friends-only lobby;
##            joining is a friends-list scan, an overlay invite, or a
##            `+connect_lobby` launch. No address is ever shown or typed.
##   DIRECT — M1's ENet console, untouched: address and port, for LAN and for the
##            dedicated server.
##
## Steam being unavailable is not an error state here. The toggle locks to DIRECT
## and says why.

@onready var _name_edit: LineEdit = %NameEdit
@onready var _ip_edit: LineEdit = %IpEdit
@onready var _port_edit: LineEdit = %PortEdit
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _quit_button: Button = %QuitButton
@onready var _status_label: Label = %StatusLabel
@onready var _color_row: HBoxContainer = %ColorRow
@onready var _injection_select: OptionButton = %InjectionSelect

@onready var _steam_mode: Button = %SteamModeButton
@onready var _direct_mode: Button = %DirectModeButton
@onready var _steam_section: VBoxContainer = %SteamSection
@onready var _direct_section: VBoxContainer = %DirectSection
@onready var _steam_host_button: Button = %SteamHostButton
@onready var _steam_join_button: Button = %SteamJoinButton
@onready var _lobby_select: OptionButton = %LobbySelect
@onready var _scan_button: Button = %ScanButton
@onready var _steam_hint: Label = %SteamHint

const COLOUR_IDLE: Color = Color(0.38, 0.44, 0.52)
const COLOUR_BUSY: Color = Color(0.5, 0.8, 1.0)
const COLOUR_BAD: Color = Color(0.95, 0.45, 0.4)
const COLOUR_CARRIED: Color = Color(0.95, 0.55, 0.35)

var _swatches: Array[Button] = []
var _color_index: int = 0
## Friend lobbies from the last scan, index-aligned with `_lobby_select`.
var _lobbies: Array = []


func _ready() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	_build_swatches()
	_build_injection_points()
	_name_edit.text = _default_name()
	_port_edit.text = str(Net.DEFAULT_PORT)
	_ip_edit.text = "127.0.0.1"

	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_quit_button.pressed.connect(func() -> void: get_tree().quit())
	_ip_edit.text_submitted.connect(func(_t: String) -> void: _on_join_pressed())
	Net.connect_failed.connect(_on_connect_failed)

	_steam_mode.pressed.connect(_select_transport.bind(Net.Transport.STEAM))
	_direct_mode.pressed.connect(_select_transport.bind(Net.Transport.DIRECT))
	_steam_host_button.pressed.connect(_on_steam_host_pressed)
	_steam_join_button.pressed.connect(_on_steam_join_pressed)
	_scan_button.pressed.connect(_scan_lobbies)
	# An overlay invite, a friends-list join and a `+connect_lobby` launch all
	# land here as the same signal.
	SteamHub.join_requested.connect(_on_steam_join_requested)
	SteamHub.friend_lobbies_updated.connect(_fill_lobby_list)

	_select_transport(Net.Transport.STEAM if SteamHub.live else Net.Transport.DIRECT)
	_steam_mode.disabled = not SteamHub.live
	if SteamHub.live:
		_scan_lobbies()

	var carried: String = GameState.consume_status()
	if carried.is_empty():
		_set_status("AWAITING ORDERS", COLOUR_IDLE)
	else:
		_set_status(carried, COLOUR_CARRIED)


## Your Steam persona is a better default callsign than "AGENT" — but only until
## you have typed one of your own.
func _default_name() -> String:
	if GameState.local_name != "AGENT" or not SteamHub.live:
		return GameState.local_name
	return GameState.sanitize_name(SteamHub.suggested_name())


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


# ----------------------------------------------------------------- injection --

## DESIGN.md lobby step 1: "layer 1, or any backdoor every present crew member
## has installed". M3 ships the single-machine half of that — this menu offers
## the ring below the deepest node *this* machine has rooted. Checking it against
## the whole crew's saves is M4's lobby.
func _build_injection_points() -> void:
	_injection_select.clear()
	for layer: int in GameState.injection_choices():
		_injection_select.add_item("LAYER %02d%s" % [
			layer, "" if layer == 1 else "  ·  BACKDOOR"], layer)
	_injection_select.select(_injection_select.item_count - 1)
	# One choice is not a choice; do not offer a dropdown that cannot change.
	_injection_select.disabled = _injection_select.item_count <= 1


# ----------------------------------------------------------------- transport --

func _select_transport(mode: Net.Transport) -> void:
	var steam: bool = mode == Net.Transport.STEAM and SteamHub.live
	_steam_mode.button_pressed = steam
	_direct_mode.button_pressed = not steam
	_steam_section.visible = steam
	_direct_section.visible = not steam
	if steam:
		_steam_hint.text = "SIGNED IN AS %s  ·  INVITE VIA OVERLAY" \
				% SteamHub.persona.to_upper()
	else:
		_steam_hint.text = SteamHub.status


# ------------------------------------------------------------- steam actions --

func _on_steam_host_pressed() -> void:
	_apply_identity()
	_set_busy(true)
	_set_status("OPENING A FRIENDS-ONLY LOBBY...", COLOUR_BUSY)
	Net.host_steam()


func _on_steam_join_pressed() -> void:
	var index: int = _lobby_select.selected
	if index < 0 or index >= _lobbies.size():
		_set_status("NO CREW SELECTED — SCAN FOR FRIENDS FIRST", COLOUR_BAD)
		return
	var entry: Dictionary = _lobbies[index] as Dictionary
	_apply_identity()
	_set_busy(true)
	_set_status("HAILING %s..." % String(entry.get("name", "CREW")).to_upper(), COLOUR_BUSY)
	Net.join_steam(int(entry.get("lobby", 0)))


## Overlay invite / friends-list join / `+connect_lobby`: the player has already
## said yes somewhere else, so this goes straight in rather than asking again.
func _on_steam_join_requested(lobby_id: int) -> void:
	if not is_inside_tree() or Net.is_online:
		return
	_apply_identity()
	_set_busy(true)
	_set_status("ACCEPTING INVITE...", COLOUR_BUSY)
	Net.join_steam(lobby_id)


## Friends-only lobbies are invisible to a lobby-list query by design, so the
## friends list is the scan: whoever is sitting in a NULLVOID lobby right now.
func _scan_lobbies() -> void:
	if not SteamHub.live:
		return
	SteamHub.refresh_friend_lobbies()


func _fill_lobby_list(lobbies: Array) -> void:
	_lobbies = lobbies
	_lobby_select.clear()
	for entry: Dictionary in lobbies:
		_lobby_select.add_item(String(entry.get("name", "CREW")).to_upper())
	var empty: bool = lobbies.is_empty()
	if empty:
		_lobby_select.add_item("NO FRIENDS RUNNING NULLVOID")
	_lobby_select.disabled = empty
	_steam_join_button.disabled = empty


# ------------------------------------------------------------ direct actions --

func _apply_identity() -> void:
	GameState.local_name = GameState.sanitize_name(_name_edit.text)
	GameState.local_color = GameState.DEFAULT_COLORS[_color_index]
	GameState.injection_layer = maxi(_injection_select.get_selected_id(), 1)
	_name_edit.text = GameState.local_name


func _port() -> int:
	var value: int = _port_edit.text.strip_edges().to_int()
	return value if value > 0 and value < 65536 else Net.DEFAULT_PORT


func _on_host_pressed() -> void:
	_apply_identity()
	_set_busy(true)
	_set_status("OPENING DOCK ON PORT %d..." % _port(), COLOUR_BUSY)
	Net.host(_port(), false)


func _on_join_pressed() -> void:
	var address: String = _ip_edit.text.strip_edges()
	if address.is_empty():
		_set_status("ENTER A HOST ADDRESS", COLOUR_BAD)
		return
	_apply_identity()
	_set_busy(true)
	_set_status("HAILING %s..." % address, COLOUR_BUSY)
	Net.join(address, _port())


func _on_connect_failed(reason: String) -> void:
	_set_busy(false)
	_set_status(reason, COLOUR_BAD)


func _set_busy(busy: bool) -> void:
	_host_button.disabled = busy
	_join_button.disabled = busy
	_steam_host_button.disabled = busy
	_steam_join_button.disabled = busy or _lobbies.is_empty()
	_scan_button.disabled = busy


func _set_status(message: String, color: Color) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override("font_color", color)
