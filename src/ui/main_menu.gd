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
## Parallax layers, back to front, and where each currently sits.
var _parallax_layers: Array[Control] = []
var _parallax: Vector2 = Vector2.ZERO
## Cursor blink on the console's type-in.
var _cursor_clock: float = 0.0
## The tube the whole console is rendered through.
var _crt: ShaderMaterial = null
var _warmup: float = 0.0
## Set while the screen is coming apart on the way into a dive. Blocks a second
## press from starting the transition twice.
var _diving: bool = false


func _ready() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	_build_phosphor_picker()
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
	_build_terminal()
	_wire_focus()

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
	_update_parallax(delta)
	_update_terminal(delta)
	if _hex_refuse > 0.0:
		_hex_refuse = maxf(_hex_refuse - delta, 0.0)
		_hue_bar.queue_redraw()


# ------------------------------------------------------------------ terminal --
#
# The injection console as a piece of Northcairn hardware rather than as a menu.
#
# It is the same argument the HUD makes (see `crt.gdshader`): the interface you
# use is human-built, decades old and phosphor, and MOTHER's world is not. The
# menu is the first thing a player ever sees, so it is where that contract gets
# established — a save-station terminal in a corridor, not a title screen.

## Barrel curvature is stronger here than on the HUD. A console you lean over is
## a smaller, deeper tube than a readout projected in front of your eye, and the
## menu has no gameplay to stay legible during.
const MENU_CURVATURE: float = 0.075


func _build_terminal() -> void:
	# Same rig as the HUD's (see `Hud._build_tube`): the console renders into its
	# own SubViewport and comes back through the tube shader, which is the only
	# way to get a real geometric curve on it rather than a vignette pretending
	# to be one.
	#
	# The post-process ColorRect that drives the decompile dissolve deliberately
	# stays OUTSIDE the tube. That transition is MOTHER taking the screen apart,
	# and it must not look like an artefact of your own monitor — the datamosh
	# happens *to* the glass, not on it.
	# Resolved BEFORE the reparent: `$Margin` and `$Frame` are paths relative to
	# this node, and the whole point of the next twenty lines is that they stop
	# being children of it.
	_parallax_layers = [%Schematic, $Margin, $Frame]

	var screen: SubViewportContainer = SubViewportContainer.new()
	screen.name = "Tube"
	screen.stretch = true
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_PASS
	_crt = ShaderMaterial.new()
	_crt.shader = Hud.CRT_SHADER
	_crt.set_shader_parameter("amount", UiFx.TUBE_AMOUNT)
	_crt.set_shader_parameter("curvature", MENU_CURVATURE)
	_crt.set_shader_parameter("gain", 1.2)
	_crt.set_shader_parameter("scanline_strength", 0.17)
	_crt.set_shader_parameter("vignette", 0.34)
	screen.material = _crt
	add_child(screen)
	move_child(screen, _post.get_index())

	var tube: SubViewport = SubViewport.new()
	tube.name = "Glass"
	tube.transparent_bg = true
	tube.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tube.own_world_3d = false
	screen.add_child(tube)

	# Everything the console is made of moves inside. `reparent` rather than
	# remove/add, because it keeps `owner` and therefore keeps every `%UniqueName`
	# in this file resolving — the same trap the HUD hit.
	for child: Node in get_children():
		if child == screen or child == _post:
			continue
		var visual: Control = child as Control
		if visual != null:
			visual.reparent(tube, false)

	_warmup = 1.0 if Debug.automated else 0.0
	# The picker is built before the tube exists, so its first `_retint` had no
	# glass to coat. Coat it now that there is some.
	_retint()


func _update_terminal(delta: float) -> void:
	if _crt == null:
		return
	if _warmup < 1.0:
		_warmup = minf(_warmup + delta / maxf(UiFx.TUBE_WARMUP, 0.01), 1.0)
	_crt.set_shader_parameter("warmup", _warmup)
	# The console is a healthy machine, so its only artefact is the roll bar. The
	# dissolve is the exception, and it drives `degrade` up as the screen goes —
	# your tube losing sync as MOTHER pulls the picture out from under it.
	_crt.set_shader_parameter("degrade", _dissolve * 0.5)

	# Cursor. One blinking block after the callsign field, which is the single
	# cheapest thing that makes a text field read as a terminal prompt.
	_cursor_clock += delta
	var lit: bool = fposmod(_cursor_clock, UiFx.MENU_CURSOR_BLINK) \
			< UiFx.MENU_CURSOR_BLINK * 0.55
	if _name_edit != null and is_instance_valid(_name_edit):
		_name_edit.add_theme_color_override("caret_color",
				UiFx.SYSTEM_HOT if lit else Color(0.0, 0.0, 0.0, 0.0))


## Slow parallax against the pointer. Never against anything else — a console
## that drifts on its own is a screensaver.
func _update_parallax(delta: float) -> void:
	if _parallax_layers.is_empty() or Debug.automated:
		return
	var view: Vector2 = get_viewport_rect().size
	if view.x <= 0.0 or view.y <= 0.0:
		return
	# -1..1 from the centre of the screen, clamped: a pointer parked in a corner
	# should not shear the console off its mounts.
	var want: Vector2 = ((get_global_mouse_position() / view) - Vector2(0.5, 0.5)) * 2.0
	_parallax = _parallax.lerp(want.clampf(-1.0, 1.0),
			1.0 - exp(-UiFx.MENU_PARALLAX_RATE * delta))
	for i: int in mini(_parallax_layers.size(), UiFx.MENU_PARALLAX.size()):
		var layer: Control = _parallax_layers[i]
		if layer == null or not is_instance_valid(layer):
			continue
		layer.position = -_parallax * UiFx.MENU_PARALLAX[i]


# --------------------------------------------------------------- navigation --
#
# DESIGN.md has nothing to say about controllers and it does not need to: a co-op
# horror game gets played on a sofa, and a menu that can only be driven with a
# mouse is a menu half the crew cannot reach. This is the accessibility item
# deferred out of M3.8.
#
# Godot's own focus system does all the work — the only reasons it did not
# already function are that every control in this scene was authored FOCUS_NONE
# (so the swatches would not draw a focus ring the theme had no style for) and
# that nothing ever claimed initial focus. Both are fixed here rather than in the
# .tscn so the list stays next to the neighbour wiring it describes.
#
# Keyboard and mouse are untouched: focus navigation is additive, and `ui_accept`
# was already bound.
func _wire_focus() -> void:
	var order: Array[Control] = []
	for control: Control in [_name_edit, _hue_bar, _hex_edit, _injection_select, _steam_mode, _direct_mode,
			_steam_host_button, _lobby_select, _scan_button, _steam_join_button,
			_ip_edit, _port_edit, _host_button, _join_button, _quit_button]:
		if control != null and is_instance_valid(control):
			control.focus_mode = Control.FOCUS_ALL
			order.append(control)
	if _hue_bar != null:
		_hue_bar.focus_mode = Control.FOCUS_ALL

	# An explicit chain rather than Godot's geometric guess. The console has two
	# mutually exclusive halves (STEAM and DIRECT) and the automatic neighbour
	# search happily walks a stick press into whichever one is hidden.
	for i: int in order.size():
		var previous: Control = order[(i + order.size() - 1) % order.size()]
		var following: Control = order[(i + 1) % order.size()]
		order[i].focus_neighbor_top = order[i].get_path_to(previous)
		order[i].focus_neighbor_bottom = order[i].get_path_to(following)
		order[i].focus_previous = order[i].get_path_to(previous)
		order[i].focus_next = order[i].get_path_to(following)

	# Something has to be focused, or the first stick press goes nowhere and the
	# player concludes the controller is not supported.
	if not order.is_empty() and not Debug.automated:
		order[0].grab_focus()


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


# -------------------------------------------------------------------- phosphor --
#
# The shell marker used to be six preset swatches. Since M4.7 it is also the
# **phosphor the player's own interface is coated with** (see UiFx's palette
# block), which changes what the control has to be: a colour that re-tints the
# entire game deserves a real picker, and its preview is not a square — it is the
# menu itself, re-tinting live as you drag.
#
# Two ways in, because they answer different questions. The hue bar is for
# "something greener"; the hex field is for "this exact colour, the one my
# crewmate is not using". Both funnel through `_set_phosphor`, both clamp, and
# neither can put the interface into the reserved quarantine band.

## Geometry of the hue bar.
const HUE_BAR_SIZE: Vector2 = Vector2(268.0, 22.0)
## The cursor is drawn as dot-matrix blocks rather than as a triangle or a
## rounded handle, because everything else on this console is drawn out of the
## same character cells and a smooth handle would be the one object on screen
## that came from a different decade.
const HUE_CURSOR_CELL: float = 3.0
## How long the analog refusal tick lasts when a hex entry cannot be parsed.
const HEX_REFUSE_TIME: float = 0.35

var _hue_bar: ColorRect = null
var _hex_edit: LineEdit = null
var _band_note: Label = null
## Seconds left on the refusal tick. Negative when nothing is being refused.
var _hex_refuse: float = -1.0
## True between mouse-down and mouse-up on the hue bar. The colour is live the
## whole time; the program file is only written when the button comes up.
var _hue_dragging: bool = false


func _build_phosphor_picker() -> void:
	# `%ColorRow` is authored as an HBoxContainer of swatches; M4.7 empties it and
	# builds the picker in its place rather than editing the .tscn, for the same
	# reason the program panel is built in code: the row's contents are a function
	# of what the picker needs, and a scene that hard-codes them is a scene that
	# silently lies the next time it changes.
	for child: Node in _color_row.get_children():
		child.queue_free()
	_color_row.add_theme_constant_override("separation", 10)

	_hue_bar = ColorRect.new()
	_hue_bar.name = "HueBar"
	_hue_bar.custom_minimum_size = HUE_BAR_SIZE
	_hue_bar.color = Color.WHITE
	_hue_bar.focus_mode = Control.FOCUS_ALL
	_hue_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_hue_bar.gui_input.connect(_on_hue_input)
	_hue_bar.draw.connect(_draw_hue_bar)
	_color_row.add_child(_hue_bar)

	_hex_edit = LineEdit.new()
	_hex_edit.name = "HexEdit"
	_hex_edit.custom_minimum_size = Vector2(108.0, 0.0)
	_hex_edit.max_length = 7
	_hex_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hex_edit.tooltip_text = "PHOSPHOR  ·  #RRGGBB"
	_hex_edit.text_submitted.connect(_on_hex_submitted)
	_hex_edit.focus_exited.connect(func() -> void: _on_hex_submitted(_hex_edit.text))
	_color_row.add_child(_hex_edit)

	_band_note = Label.new()
	_band_note.name = "BandNote"
	_band_note.add_theme_font_size_override("font_size", 10)
	_band_note.text = ""
	_color_row.add_child(_band_note)

	_set_phosphor(GameState.local_color, true)


## The gradient, drawn rather than textured: one `draw_rect` per column, in the
## legal saturation and value the picker actually offers, so the bar is a preview
## of what you can have rather than of the whole colour wheel. The reserved
## quarantine wedge is drawn dark and struck through — it is visibly not for sale.
func _draw_hue_bar() -> void:
	var width: float = _hue_bar.size.x
	var height: float = _hue_bar.size.y
	var columns: int = maxi(int(width), 1)
	for x: int in columns:
		var hue: float = float(x) / float(columns)
		var swatch: Color = Color.from_hsv(hue, 0.85, 0.95)
		if UiFx.in_danger_band(swatch):
			swatch = Color(0.10, 0.05, 0.04)
		_hue_bar.draw_rect(Rect2(float(x), 0.0, 1.0, height), swatch)

	# The cursor: three stacked cells above and below the bar, in the phosphor
	# the player currently has, so the handle is itself a live preview.
	var at: float = GameState.local_color.h * width
	for i: int in 3:
		var offset: float = float(i) * HUE_CURSOR_CELL
		for edge: float in [-HUE_CURSOR_CELL - offset, height + offset]:
			_hue_bar.draw_rect(Rect2(at - HUE_CURSOR_CELL * 0.5 - float(i),
					edge, HUE_CURSOR_CELL + float(i) * 2.0, HUE_CURSOR_CELL),
					UiFx.SYSTEM_HOT)

	# The refusal tick: one band of hold loss across the bar, gone in a third of a
	# second. Analog, because it is this console misreading an entry — the same
	# vocabulary the HUD uses when it is knocked, and not the digital corruption
	# MOTHER uses when she is doing something to you.
	if _hex_refuse > 0.0:
		var weight: float = _hex_refuse / HEX_REFUSE_TIME
		var band: float = fposmod(UiFx.clock() * 9.0, 1.0) * height
		_hue_bar.draw_rect(Rect2(
				(UiFx.hash01(floor(UiFx.clock() * 40.0)) - 0.5) * 12.0 * weight,
				band, width, 3.0),
				Color(UiFx.HOSTILE.r, UiFx.HOSTILE.g, UiFx.HOSTILE.b, weight))


## Drag applies the colour live; the program file is written once, on release.
##
## `_set_phosphor` ends in `GameState.choose_phosphor` -> `save_progress()`, i.e.
## a full JSON.stringify, a temp-file write and an atomic rename. A drag emits one
## InputEventMouseMotion per motion sample — 60+/s, far more on a high-polling
## mouse — so a two-second drag across the bar used to commit the player's
## program a hundred and twenty times, each rename a window in which a crash
## leaves the save mid-commit. Applying and committing are separate things.
func _on_hue_input(event: InputEvent) -> void:
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click != null and click.button_index == MOUSE_BUTTON_LEFT and not click.pressed:
		# Released. Whatever the drag ended on is the choice worth keeping.
		if _hue_dragging:
			_hue_dragging = false
			GameState.choose_phosphor(GameState.local_color)
		return
	var dragging: bool = motion != null and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
	if not dragging and (click == null or not click.pressed
			or click.button_index != MOUSE_BUTTON_LEFT):
		return
	_hue_dragging = true
	var at: Vector2 = motion.position if motion != null else click.position
	var hue: float = clampf(at.x / maxf(_hue_bar.size.x, 1.0), 0.0, 1.0)
	# Saturation and value are kept from the current colour rather than reset, so
	# a player who typed an exact pale green and then nudged the hue still has a
	# pale colour afterwards.
	_set_phosphor(Color.from_hsv(hue, GameState.local_color.s, GameState.local_color.v),
			false, true)


func _on_hex_submitted(text: String) -> void:
	var entry: String = text.strip_edges()
	if not entry.begins_with("#"):
		entry = "#" + entry
	if not Color.html_is_valid(entry):
		# Keep the last valid colour and say so with a tick rather than a dialog.
		# A menu that pops a modal because somebody mistyped a hex code is a menu
		# that has forgotten what it is for.
		_hex_refuse = HEX_REFUSE_TIME
		_hex_edit.text = "#" + GameState.local_color.to_html(false).to_upper()
		return
	_set_phosphor(Color.html(entry))


## The one door every colour change goes through.
##
## `initial` suppresses the save on the first call, which happens while the menu
## is still building itself — writing the program file during construction would
## mean a launch that crashed at the wrong moment could leave a half-written one.
## `live` suppresses it for the same reason, mid-drag: the colour is applied
## immediately, and the commit waits for the mouse button to come up.
func _set_phosphor(colour: Color, initial: bool = false, live: bool = false) -> void:
	var clamped: Color = UiFx.clamp_phosphor(colour)
	# The note is shown when the pick was actually MOVED, not merely when it is
	# near the band — telling a player their orange was legal is noise.
	var nudged: bool = UiFx.in_danger_band(colour)
	if initial or live:
		# Building or dragging, not choosing.
		GameState.local_color = clamped
		UiFx.set_phosphor(clamped)
	else:
		GameState.choose_phosphor(clamped)
	_retint()
	if _hex_edit != null and not _hex_edit.has_focus():
		_hex_edit.text = "#" + clamped.to_html(false).to_upper()
	if _band_note != null:
		_band_note.text = "RESERVED · QUARANTINE BAND" if nudged else ""
		_band_note.add_theme_color_override("font_color",
				UiFx.HOSTILE if nudged else UiFx.DIM)
	if _hue_bar != null:
		_hue_bar.queue_redraw()


## Re-coats everything the console draws itself. The theme's own styleboxes are
## resources shared with the in-run interface, so they are re-tinted in place
## rather than duplicated per screen — one player, one phosphor, everywhere.
func _retint() -> void:
	if _crt != null:
		_crt.set_shader_parameter("phosphor", Vector3(
				UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b))
	var theme_resource: Theme = theme if theme != null else ThemeDB.get_project_theme()
	if theme_resource == null:
		return
	for entry: Array in [["Button", "font_color", UiFx.DIM.lightened(0.35)],
			["Button", "font_focus_color", UiFx.SYSTEM_HOT],
			["Button", "font_hover_color", UiFx.TEXT],
			["Label", "font_color", UiFx.DIM.lightened(0.2)],
			["LineEdit", "font_color", UiFx.TEXT]]:
		theme_resource.set_color(String(entry[1]), String(entry[0]), entry[2] as Color)
	for style_name: String in ["focus", "hover", "pressed"]:
		var box: StyleBoxFlat = theme_resource.get_stylebox(
				style_name, "Button") as StyleBoxFlat
		if box != null:
			box.border_color = Color(UiFx.SYSTEM_HOT.r, UiFx.SYSTEM_HOT.g,
					UiFx.SYSTEM_HOT.b, 0.9 if style_name == "focus" else 1.0)


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
		_lobby_select.add_item("NO FRIENDS RUNNING LIMBO PROTOCOL")
	_lobby_select.disabled = empty
	_steam_join_button.disabled = empty


# ------------------------------------------------------------ direct actions --

func _apply_identity() -> void:
	GameState.local_name = GameState.sanitize_name(_name_edit.text)
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
