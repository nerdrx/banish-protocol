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

@onready var _console_sweep: ColorRect = %ConsoleSweep
@onready var _ticker: Label = %Ticker
@onready var _post: ColorRect = %Post

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

## MOTHER talking to her own daemons, the way the wall decals do (DESIGN.md
## "MOTHER talks to her processes"). The injection console is inside her, so the
## chatter that scrolls along its bottom rule is hers, not ours — which is what
## makes the menu feel like somewhere you have already broken into.
const TICKER_LINES: Array[String] = [
	"MOTHER  ·  CYCLE AUDIT COMPLETE  ·  EVERY CYCLE ACCOUNTED",
	"◆◇◆  INTEGRITY SWEEP  RING 01-04  ·  NO ANOMALY  ◆◇◆",
	"QUARANTINE IS MERCY  ·  REPORT FOREIGN PROCESS",
	"TRUNK 04 ▼  SCHEDULED DEFRAGMENT  ·  HOLD ALL DESCENT",
	"NORTHCAIRN SYSTEMS  ·  MOTHER SERVES  ·  ▣▣▢▣▢▣",
	"SIPHON PRESSURE NOMINAL  ·  TAP 07 FLAGGED FOR SERVICE",
	"◆  ANTIVIRUS ROSTER SYNCHRONISED  ·  1288 PROCESSES  ◆",
	"DATA VAULT SEAL VERIFIED  ·  ACCESS DENIED TO ALL",
	"UNSCHEDULED READ ON RING 02  ·  ESCALATING  ·  ▤▤▥▤",
	"COMPUTE IS FINITE  ·  YOUR CYCLES ARE HERS",
]

## The console's reveal order. Everything with a `visible_ratio` types itself in
## when the console opens; buttons cannot, so they simply fade with the panel.
const REVEAL_PATHS: Array[String] = [
	"Margin/Column/Title",
	"Margin/Column/Subtitle",
	"Margin/Column/Console/Fields/CallsignLabel",
	"Margin/Column/Console/Fields/MarkerLabel",
	"Margin/Column/Console/Fields/InjectionLabel",
	"Version",
]

var _swatches: Array[Button] = []
var _color_index: int = 0
## Friend lobbies from the last scan, index-aligned with `_lobby_select`.
var _lobbies: Array = []

# --- M3.8 presentation ------------------------------------------------------
## Type-in reveal clock. Negative once the console has finished opening.
var _reveal_clock: float = 0.0
var _reveal_labels: Array[Label] = []
var _ticker_clock: float = 0.0
var _ticker_index: int = 0
## Decompile/recompile weight, 0 = clear screen, 1 = gone.
var _dissolve: float = 0.0
var _dissolve_target: float = 0.0
## Set while the screen is coming apart on the way into a dive. Blocks a second
## press from starting the transition twice.
var _diving: bool = false


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

	_build_program_panel()

	var carried: String = GameState.consume_status()
	if carried.is_empty():
		_set_status("AWAITING ORDERS", COLOUR_IDLE)
	else:
		_set_status(carried, COLOUR_CARRIED)

	# Arriving with a status in hand means we just came out of an intrusion, so
	# the console recompiles out of black — the reverse of the dissolve that took
	# us in. A cold boot simply types itself in.
	_open_console(not carried.is_empty())


# ------------------------------------------------------------ presentation --

## Opens the injection console. `returning` is true when we have just come back
## out of a run, which is when the screen has to recompile from black.
func _open_console(returning: bool) -> void:
	_reveal_labels.clear()
	for path: String in REVEAL_PATHS:
		var label: Label = get_node_or_null(path) as Label
		if label != null:
			label.visible_ratio = 0.0
			_reveal_labels.append(label)

	var sheen: ShaderMaterial = ShaderMaterial.new()
	sheen.shader = Hud.SHEEN_SHADER
	sheen.set_shader_parameter("tint", UiFx.SYSTEM)
	# Brighter and rarer than the HUD's: this is one sweep across one panel every
	# few seconds, and it is allowed to be the thing that catches your eye.
	sheen.set_shader_parameter("sheen_strength", 0.06)
	sheen.set_shader_parameter("scanline_strength", 0.018)
	sheen.set_shader_parameter("sweep_period", UiFx.MENU_SWEEP_INTERVAL)
	sheen.set_shader_parameter("sweep_width", 0.045)
	sheen.set_shader_parameter("perspective", 0.0)
	# The console has a drawn border of its own, so the sweep runs edge to edge
	# instead of fading into an oval the way a HUD cluster's does.
	sheen.set_shader_parameter("mask_start", 0.92)
	_console_sweep.material = sheen

	_ticker.text = TICKER_LINES[0]

	_dissolve = 1.0 if returning else 0.0
	_dissolve_target = 0.0
	# `--hud-state decompile` holds the dive transition open at its midpoint. It
	# lasts 0.8 s in play and there is no way to photograph the middle of it by
	# pressing a button, so the capture freezes it instead.
	if Debug.hud_state == "decompile":
		_dissolve = 0.55
		_dissolve_target = 0.55
	_apply_dissolve()

	# A capture of the menu must be of the *finished* menu, and an automated run
	# must never sit through a reveal it did not ask for.
	if Debug.automated:
		if Debug.hud_state != "decompile":
			_dissolve = 0.0
			_apply_dissolve()
		_reveal_clock = -1.0
		for label: Label in _reveal_labels:
			label.visible_ratio = 1.0
		return
	_reveal_clock = 0.0


func _process(delta: float) -> void:
	_update_reveal(delta)
	_update_ticker(delta)
	_update_dissolve(delta)


## Each line types itself in, staggered down the console. `visible_ratio` rather
## than rebuilding the string every frame: no allocation, and it interpolates
## sub-character so short labels do not look like they are stuttering.
func _update_reveal(delta: float) -> void:
	if _reveal_clock < 0.0:
		return
	_reveal_clock += delta
	var done: bool = true
	for i: int in _reveal_labels.size():
		var start: float = float(i) * UiFx.MENU_TYPE_TIME * 0.22
		var ratio: float = clampf(
				(_reveal_clock - start) / UiFx.MENU_TYPE_TIME, 0.0, 1.0)
		_reveal_labels[i].visible_ratio = ratio
		if ratio < 1.0:
			done = false
	if done:
		_reveal_clock = -1.0


func _update_ticker(delta: float) -> void:
	_ticker_clock -= delta
	if _ticker_clock > 0.0:
		return
	_ticker_clock = UiFx.MENU_TICKER_INTERVAL
	_ticker_index = (_ticker_index + 1) % TICKER_LINES.size()
	_ticker.text = TICKER_LINES[_ticker_index]


## The dive transition. The screen does not fade to black — it **decompiles**:
## the post grade's own datamosh and scanline-tear path is driven all the way up
## while the image goes out, so the last thing you see of the console is it
## coming apart into bands. Coming home runs the same thing backwards.
##
## Reuses the menu's existing post-process material rather than adding an
## overlay, which means the transition is made of the same glitch vocabulary the
## intrusion uses when you are dying in it. That is the point.
func _update_dissolve(delta: float) -> void:
	if is_equal_approx(_dissolve, _dissolve_target):
		return
	var span: float = UiFx.DECOMPILE_TIME if _dissolve_target > _dissolve \
			else UiFx.RECOMPILE_TIME
	_dissolve = move_toward(_dissolve, _dissolve_target, delta / maxf(span, 0.01))
	_apply_dissolve()


func _apply_dissolve() -> void:
	var material: ShaderMaterial = _post.material as ShaderMaterial
	if material == null:
		return
	material.set_shader_parameter("degradation", _dissolve)
	material.set_shader_parameter("fade", _dissolve * _dissolve)
	# The flinch is spiked in the middle of the dissolve rather than at either
	# end: it is the moment the console gives up, not the moment it starts to.
	material.set_shader_parameter("glitch", sin(_dissolve * PI))


## Starts the decompile and calls `then` once the screen is gone. Every path out
## of this menu that ends in a scene change goes through here.
func _dive(then: Callable) -> void:
	if _diving:
		return
	_diving = true
	_dissolve_target = 1.0
	# Automation drives Net directly and never touches this menu, but a dev
	# running `--quit-in` on the menu should not be made to wait either.
	if not Debug.automated:
		await get_tree().create_timer(UiFx.DECOMPILE_TIME).timeout
	if not is_inside_tree():
		return
	then.call()


## Whatever we were diving into refused us. Put the screen back together.
func _surface() -> void:
	_diving = false
	_dissolve_target = 0.0


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


# ------------------------------------------------------------------ program --
#
# DESIGN.md: "each player's program (module tiers, archive, deepest backdoor)
# saves locally on their machine." Before M4 the menu never said what was in it,
# which meant the only place a player could see their own build was by walking to
# a Compiler two layers into a run — the one moment they are least able to plan
# around it.
#
# Built in code rather than added to the scene for the same reason the HUD's crew
# rows are: it is a list whose length is a constant in Balance, and a scene that
# hard-codes eight rows is a scene that silently lies the day a ninth track is
# added.

## Narrow enough to sit clear of the injection console, which is centred and
## about 630 px wide on a 1280 frame.
const PROGRAM_WIDTH: float = 292.0

func _build_program_panel() -> void:
	var panel: Control = Control.new()
	panel.name = "ProgramPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	panel.position = Vector2(-PROGRAM_WIDTH - 22.0, -186.0)
	panel.size = Vector2(PROGRAM_WIDTH, 372.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	# Behind the post grade, so the dive dissolve takes it apart with everything
	# else rather than leaving a readout floating over a decompiling screen.
	move_child(panel, _post.get_index())

	var plate: ColorRect = ColorRect.new()
	plate.color = Color(0.02, 0.055, 0.08, 0.72)
	plate.set_anchors_preset(Control.PRESET_FULL_RECT)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(plate)

	var edge: ColorRect = ColorRect.new()
	edge.color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.4)
	edge.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	edge.custom_minimum_size = Vector2(2.0, 0.0)
	edge.offset_right = 2.0
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(edge)

	var column: VBoxContainer = VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.offset_left = 18.0
	column.offset_right = -14.0
	column.offset_top = 14.0
	column.add_theme_constant_override("separation", 3)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(column)

	_program_line(column, "YOUR PROGRAM", 15, UiFx.SYSTEM)
	_program_line(column, "COMPILED  ·  SURVIVES DELETION", 10, UiFx.DIM)
	column.add_child(_program_rule())

	for track: String in Balance.MODULE_TRACKS:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(row)

		# Through Modules rather than straight off the file, so `--modules` shows
		# the build the session is actually running with — the menu must never
		# disagree with the Compiler panel about what you have compiled.
		var tier: int = Modules.tier_of(Net.local_id(), track)
		var total: int = Modules.tier_count(track)
		var lit: Color = UiFx.SYSTEM if tier > 0 else UiFx.DIM
		_program_cell(row, Modules.glyph(track), 13, lit, 20.0)
		_program_cell(row, Modules.display_name(track), 12,
				UiFx.TEXT if tier > 0 else UiFx.DIM, 106.0)
		var pips: String = ""
		for t: int in total:
			pips += "●" if t < tier else "○"
		_program_cell(row, pips, 13, lit, 0.0)

	column.add_child(_program_rule())
	_program_line(column, "ARCHIVE           %d DATA" % GameState.archive, 12, UiFx.TEXT)
	_program_line(column, "DEEPEST BACKDOOR  %s" % (
			"NONE" if GameState.deepest_backdoor <= 0
			else "LAYER %02d" % GameState.deepest_backdoor), 12, UiFx.TEXT)
	column.add_child(_program_rule())
	_program_line(column, "INTRUSIONS        %d" % GameState.stat("runs"), 11, UiFx.DIM)
	_program_line(column, "EXFILTRATIONS     %d" % GameState.stat("exfils"), 11, UiFx.DIM)
	_program_line(column, "PROCESSES DELETED %d" % GameState.stat("deletions"), 11, UiFx.DIM)
	_program_line(column, "DATA BANKED       %d" % GameState.stat("data_banked"), 11, UiFx.DIM)

	# Rewriting somebody's save file is a thing to admit to, once, plainly.
	if GameState.migrated_from > 0:
		column.add_child(_program_rule())
		_program_line(column, "PROGRAM FILE MIGRATED v%d → v%d" % [
			GameState.migrated_from, GameState.SAVE_VERSION], 10, UiFx.WARNING)
		_program_line(column, "BACKUP: user://save.json.bak", 10, UiFx.DIM)


func _program_line(parent: Control, text: String, size: int, colour: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _program_cell(parent: Control, text: String, size: int, colour: Color,
		width: float) -> Label:
	var label: Label = _program_line(parent, text, size, colour)
	label.custom_minimum_size = Vector2(width, 0.0)
	return label


func _program_rule() -> Control:
	var line: ColorRect = ColorRect.new()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.22)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


# ----------------------------------------------------------------- injection --

## DESIGN.md lobby step 1: "layer 1, or any backdoor every present crew member
## has installed". M3 shipped the single-machine half — this menu offers the ring
## below the deepest node *this* machine has rooted. M4 adds the crew half, and
## it lives at the door rather than here: there is no separate lobby scene to
## check a roster in, so the host's `_register_crew` turns away any program that
## has not installed the backdoor the run started at, and both sides are told
## exactly who and why (Net's injection gate, Hud's gate panel).
##
## The dropdown therefore says what it is committing the crew to, and does not
## pretend to know who is going to join.
func _build_injection_points() -> void:
	_injection_select.clear()
	for layer: int in GameState.injection_choices():
		_injection_select.add_item("LAYER %02d%s" % [
			layer, "" if layer == 1
			else "  ·  NEEDS BACKDOOR %02d" % (layer - 1)], layer)
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
	_dive(func() -> void: Net.host_steam())


func _on_steam_join_pressed() -> void:
	var index: int = _lobby_select.selected
	if index < 0 or index >= _lobbies.size():
		_set_status("NO CREW SELECTED — SCAN FOR FRIENDS FIRST", COLOUR_BAD)
		return
	var entry: Dictionary = _lobbies[index] as Dictionary
	_apply_identity()
	_set_busy(true)
	_set_status("HAILING %s..." % String(entry.get("name", "CREW")).to_upper(), COLOUR_BUSY)
	var lobby: int = int(entry.get("lobby", 0))
	_dive(func() -> void: Net.join_steam(lobby))


## Overlay invite / friends-list join / `+connect_lobby`: the player has already
## said yes somewhere else, so this goes straight in rather than asking again.
func _on_steam_join_requested(lobby_id: int) -> void:
	if not is_inside_tree() or Net.is_online:
		return
	_apply_identity()
	_set_busy(true)
	_set_status("ACCEPTING INVITE...", COLOUR_BUSY)
	_dive(func() -> void: Net.join_steam(lobby_id))


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
	var port: int = _port()
	_dive(func() -> void: Net.host(port, false))


func _on_join_pressed() -> void:
	var address: String = _ip_edit.text.strip_edges()
	if address.is_empty():
		_set_status("ENTER A HOST ADDRESS", COLOUR_BAD)
		return
	_apply_identity()
	_set_busy(true)
	_set_status("HAILING %s..." % address, COLOUR_BUSY)
	var port: int = _port()
	_dive(func() -> void: Net.join(address, port))


## Every failure path lands here, so this is also where the screen comes back
## together after a dive that never happened.
func _on_connect_failed(reason: String) -> void:
	_surface()
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
