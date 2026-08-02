class_name TerminalPanel
extends CanvasLayer
## The command terminal's screen: a prompt, a cursor, and a machine that takes
## its time.
##
## Same tube as the Compiler's panel and the same phosphor, because it is the
## same hardware — but where that panel is a *list you choose from*, this one is
## a **text session**. You type. The machine spends a couple of seconds
## pretending to look things up, then types back at forty-odd characters a
## second, and on a deep ring what it types back has holes in it.
##
## ## Input, and the accessibility parity that is a design law
##
## Two paths, and they do not know about each other:
##
##   **Keyboard** — raw `InputEventKey`. Printable characters append, backspace
##   deletes, enter submits, escape closes. Deliberately *not* routed through
##   `ui_*` actions: `ui_accept` is bound to space, and a terminal where the
##   space bar submits your command is not a terminal.
##
##   **Gamepad** — the command list down the right-hand side, navigated with
##   `ui_up`/`ui_down` and fired with `ui_accept`, from joypad events only. Every
##   command the keyboard can compose is in that list, `QUERY <ROOM>` expanded to
##   one row per sector, so a pad player is never told to go and find a keyboard.
##   DESIGN.md's solo invariant has an accessibility half and this is it.
##
## The list is visible to everybody, always. On a keyboard it doubles as the HELP
## card you would otherwise have to ask for.
##
## Per player, local, unreplicated. `Props.request_query` is the only thing that
## leaves, and all it does is tell the host to make a noise.

static var _open: TerminalPanel = null

## Kept inside the tube's safe area. The CRT shader's barrel curvature pushes
## content outward near the edges, so a panel sized to the viewport is a panel
## whose corners bow past the glass.
const WIDTH: float = 900.0
const HEIGHT: float = 560.0
const PAD: float = 22.0
## How many transcript lines the screen holds before it scrolls.
const SCROLL: int = 22
## Rows of the command list visible at once.
const LIST_ROWS: int = 9

static var _mono: Font = preload("res://assets/fonts/ui_font.tres")

var terminal: CommandTerminal = null

var _transcript: PackedStringArray = PackedStringArray()
var _screen: Label = null
var _input_line: Label = null
var _status: Label = null
var _list: Label = null

var _typed: String = ""
## Queued answer, revealed a character at a time once processing finishes.
var _pending: PackedStringArray = PackedStringArray()
var _process_left: float = 0.0
var _reveal_chars: float = 0.0
var _revealing: bool = false
## Gamepad list selection, and every command it can fire.
var _commands: PackedStringArray = PackedStringArray()
var _selected: int = 0


static func is_open() -> bool:
	return _open != null and is_instance_valid(_open)


static func is_open_for(which: CommandTerminal) -> bool:
	return is_open() and _open.terminal == which


static func open_for(which: CommandTerminal) -> TerminalPanel:
	if is_open():
		_open.close()
	if which == null or not is_instance_valid(which):
		return null
	var panel: TerminalPanel = TerminalPanel.new()
	panel.name = "TerminalPanel"
	panel.terminal = which
	panel.layer = 3
	which.get_tree().get_root().add_child(panel)
	_open = panel
	return panel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_build_command_list()
	Run.run_ended.connect(func(_s: Dictionary) -> void: close())
	Run.descent_started.connect(func(_n: int) -> void: close())
	if Debug.may_capture_mouse():
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	var layer: int = 1 if terminal.graph == null else terminal.graph.layer_number
	_push("NORTHCAIRN FIELD TERMINAL  ·  REV 9")
	_push("ATTACHED TO MAINTENANCE INDEX  ·  RING %02d" % layer)
	if corruption() > 0.01:
		# The machine says what is wrong with it once, plainly, and then never
		# mentions it again — every answer after this is just quietly wrong.
		_push("WARNING: INDEX INTEGRITY %d%%" % int(round((1.0 - corruption()) * 100.0)))
	_push("TYPE HELP FOR COMMANDS.")
	_push("")
	print("[Terminal] session open at terminal %d (ring %d, corruption %.2f)" % [
		terminal.prop_index, layer, corruption()])


func close() -> void:
	if _open == self:
		_open = null
	if terminal != null and is_instance_valid(terminal):
		terminal.set_busy(0.0)
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
	glass.set_shader_parameter("gain", 1.2)
	# The heaviest scanlines of any panel in the game. This is a *text terminal*:
	# the grille is what makes it read as a character generator rather than as a
	# label with a font on it.
	glass.set_shader_parameter("scanline_strength", 0.24)
	glass.set_shader_parameter("curvature", 0.045)
	glass.set_shader_parameter("vignette", 0.26)
	screen.material = glass
	add_child(screen)

	var tube: SubViewport = SubViewport.new()
	tube.name = "Tube"
	tube.transparent_bg = true
	tube.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tube.own_world_3d = false
	screen.add_child(tube)

	var shade: ColorRect = ColorRect.new()
	shade.color = Color(0.02, 0.012, 0.004, 0.72)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	tube.add_child(shade)

	var centre: CenterContainer = CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tube.add_child(centre)

	var holder: Control = Control.new()
	holder.name = "Panel"
	holder.custom_minimum_size = Vector2(WIDTH, HEIGHT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(holder)

	var back: ColorRect = ColorRect.new()
	back.name = "Plate"
	back.color = Color(0.040, 0.026, 0.010, 0.94)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(back)
	for edge: int in 4:
		var line: ColorRect = ColorRect.new()
		line.color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.5)
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
	column.add_theme_constant_override("separation", 6)
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.offset_left = PAD
	column.offset_right = -PAD
	column.offset_top = PAD * 0.7
	column.offset_bottom = -PAD * 0.7
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.add_child(column)

	var header: HBoxContainer = HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(header)
	var title: Label = _label(header, "MAINTENANCE INDEX  ·  QUERY SESSION", 20,
			UiFx.SYSTEM)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status = _label(header, "", 13, UiFx.DIM)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	column.add_child(_rule())

	# Transcript on the left, command list on the right. Two Labels rather than a
	# container per row: the transcript re-renders every frame while a line types
	# in, and rebuilding twenty Controls per frame to animate text is how a UI
	# ends up costing more than the layer behind it.
	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(body)

	_screen = _label(body, "", 15, UiFx.TEXT)
	_screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_screen.vertical_alignment = VERTICAL_ALIGNMENT_TOP

	var side: VBoxContainer = VBoxContainer.new()
	side.custom_minimum_size = Vector2(268.0, 0.0)
	side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(side)
	_label(side, "COMMAND LIST", 13, UiFx.DIM)
	_list = _label(side, "", 14, UiFx.DIM)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.vertical_alignment = VERTICAL_ALIGNMENT_TOP

	column.add_child(_rule())
	_input_line = _label(column, "> ", 17, UiFx.SYSTEM_HOT)

	var sheen: ColorRect = ColorRect.new()
	sheen.set_anchors_preset(Control.PRESET_FULL_RECT)
	sheen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheen.color = Color.WHITE
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = Hud.SHEEN_SHADER
	material.set_shader_parameter("tint", UiFx.SYSTEM)
	material.set_shader_parameter("sheen_strength", 0.04)
	material.set_shader_parameter("scanline_strength", 0.02)
	material.set_shader_parameter("sweep_period", 6.5)
	material.set_shader_parameter("sweep_width", 0.05)
	material.set_shader_parameter("perspective", 0.0)
	material.set_shader_parameter("mask_start", 0.94)
	sheen.material = material
	back.add_child(sheen)


func _label(parent: Control, text: String, size: int, colour: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_override("font", _mono)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The transcript prints whatever the intel functions hand it, and a `QUERY`
	# with no sector lists every room name on the layer. Clipped AND wrapped: a
	# line that is too long folds rather than running out through the tube's
	# curved edge, and anything still too wide loses its tail to an ellipsis.
	label.clip_text = true
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	parent.add_child(label)
	return label


func _rule() -> Control:
	var line: ColorRect = ColorRect.new()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.26)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## Every command a pad can fire, `QUERY` expanded per sector so the list is a
## complete alternative to the keyboard rather than a summary of it.
func _build_command_list() -> void:
	_commands = PackedStringArray([
		"LIST DATA", "LOCATE COMPILER", "LOCATE SHAFT", "LOCATE VENT",
		"LOCATE SIPHON", "HELP",
	])
	if terminal.graph != null:
		for i: int in terminal.graph.rooms.size():
			_commands.append("QUERY %s" % terminal.graph.room_name(i))


# -------------------------------------------------------------------- input --

func _unhandled_input(event: InputEvent) -> void:
	# --- keyboard: this is a text field, so raw keys win ---------------------
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed:
		get_viewport().set_input_as_handled()
		match key.keycode:
			KEY_ESCAPE:
				close()
			KEY_ENTER, KEY_KP_ENTER:
				submit(_typed)
			KEY_BACKSPACE:
				if not _typed.is_empty():
					_typed = _typed.substr(0, _typed.length() - 1)
			KEY_TAB:
				_complete()
			_:
				var glyph: String = char(key.unicode)
				# Printable ASCII only. A terminal that accepts a tab character or
				# a dead key into its buffer is a terminal that answers questions
				# nobody typed.
				if key.unicode >= 32 and key.unicode < 127 and _typed.length() < 40:
					_typed += glyph.to_upper()
		return

	# --- gamepad: the list ---------------------------------------------------
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		if event.is_action_pressed("ui_cancel"):
			close()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_down"):
			_selected = (_selected + 1) % _commands.size()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_up"):
			_selected = (_selected + _commands.size() - 1) % _commands.size()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_accept"):
			submit(_commands[_selected])
			get_viewport().set_input_as_handled()


## Tab-completion against the command list. Small, and it is the difference
## between typing `QUERY VAULT-7C` and typing `QUERY V` — which matters a great
## deal when a pack is coming down the corridor behind you.
func _complete() -> void:
	if _typed.is_empty():
		return
	for entry: String in _commands:
		if entry.begins_with(_typed):
			_typed = entry
			return


## Public so `--query` drives the same path a keypress does.
func submit(command: String) -> void:
	var line: String = command.strip_edges()
	_typed = ""
	if line.is_empty():
		return
	_push("> " + line)
	if _process_left > 0.0 or _revealing:
		# One query at a time. The machine is busy and says so, which is also the
		# thing that stops a player queueing six loud queries in two seconds.
		_push("  BUSY.")
		return

	# The answer is computed locally — every peer has the graph — and the *noise*
	# goes to the host. Same split as every channel in the game: local feel,
	# host-owned consequence.
	_pending = CommandTerminal.answer(terminal.graph, line,
			terminal.global_position)
	_process_left = Balance.TERMINAL_QUERY_SECONDS
	Props.request_query(terminal.prop_index, line)


func _push(line: String) -> void:
	_transcript.append(line)
	while _transcript.size() > SCROLL:
		_transcript.remove_at(0)


# ----------------------------------------------------------------- updating --

func _process(delta: float) -> void:
	if terminal == null or not is_instance_valid(terminal):
		close()
		return
	var me: Node = Net.get_player(Net.local_id())
	if me != null and is_instance_valid(me) \
			and (me as Node3D).global_position.distance_to(
					terminal.global_position) > Balance.TERMINAL_USE_RANGE:
		close()
		return

	if _process_left > 0.0:
		_process_left = maxf(_process_left - delta, 0.0)
		terminal.set_busy(1.0)
		if _process_left <= 0.0:
			_revealing = true
			_reveal_chars = 0.0
	elif _revealing:
		terminal.set_busy(0.6)
		_reveal_chars += delta * Balance.TERMINAL_TYPE_SPEED
		# Lines land whole once their characters have all been typed, which keeps
		# the transcript array simple: only the line currently typing is partial.
		while not _pending.is_empty():
			var head: String = _pending[0]
			if _reveal_chars < float(head.length()):
				break
			_reveal_chars -= float(maxi(head.length(), 1))
			_push(corrupt(head))
			_pending.remove_at(0)
		if _pending.is_empty():
			_revealing = false
			_push("")
			terminal.set_busy(0.0)
	else:
		terminal.set_busy(0.0)

	_refresh()


func _refresh() -> void:
	var lines: PackedStringArray = _transcript.duplicate()
	# The line currently being typed, shown as far as it has got.
	if _revealing and not _pending.is_empty():
		var head: String = _pending[0]
		var cut: int = clampi(int(_reveal_chars), 0, head.length())
		lines.append(corrupt(head.substr(0, cut)))
	while lines.size() > SCROLL:
		lines.remove_at(0)
	_screen.text = "\n".join(lines)

	var blink: bool = fmod(UiFx.clock(), UiFx.MENU_CURSOR_BLINK * 2.0) \
			< UiFx.MENU_CURSOR_BLINK
	if _process_left > 0.0:
		_input_line.text = "> PROCESSING%s" % ".".repeat(
				1 + int(UiFx.clock() * 3.0) % 3)
		_input_line.add_theme_color_override("font_color", UiFx.WARNING)
	else:
		_input_line.text = "> %s%s" % [_typed, "█" if blink else " "]
		_input_line.add_theme_color_override("font_color", UiFx.SYSTEM_HOT)

	_status.text = "%s  ·  QUERIES ARE HEARD" % (
			"INTEGRITY %d%%" % int(round((1.0 - corruption()) * 100.0))
			if corruption() > 0.01 else "INDEX NOMINAL")
	_status.add_theme_color_override("font_color",
			UiFx.WARNING if corruption() > 0.01 else UiFx.DIM)

	_refresh_list()


func _refresh_list() -> void:
	# A window of rows around the selection, so a nine-room layer's twenty-odd
	# commands still fit on a screen the size of a terminal.
	var start: int = clampi(_selected - LIST_ROWS / 2, 0,
			maxi(_commands.size() - LIST_ROWS, 0))
	var rows: PackedStringArray = PackedStringArray()
	for i: int in mini(LIST_ROWS, _commands.size()):
		var index: int = start + i
		if index >= _commands.size():
			break
		rows.append("%s %s" % ["▶" if index == _selected else " ", _commands[index]])
	if start + LIST_ROWS < _commands.size():
		rows.append("  …")
	_list.text = "\n".join(rows)


# --------------------------------------------------------------- corruption --

## How badly this ring's index has rotted, 0..1.
##
## Same curve shape as the architecture decay and the signage decay, and for the
## same stated reason: it is one fact about the building, said three ways. Above
## TERMINAL_CORRUPT_START her records start losing glyphs; by CORRUPT_FULL a
## room name is something you are half guessing at.
func corruption() -> float:
	var layer: int = 1 if terminal.graph == null else terminal.graph.layer_number
	if layer < Balance.TERMINAL_CORRUPT_START:
		return 0.0
	var t: float = clampf(float(layer - Balance.TERMINAL_CORRUPT_START)
			/ float(maxi(Balance.TERMINAL_CORRUPT_FULL
					- Balance.TERMINAL_CORRUPT_START, 1)), 0.0, 1.0)
	return Balance.TERMINAL_CORRUPT_MAX * lerpf(0.22, 1.0, t)


## Punches glyphs out of a line, in the same alphabet the HUD and the Compiler's
## refusal use.
##
## Deterministic per (layer, line content, column) rather than random: a query
## you run twice comes back wrong the *same way*, which reads as a damaged record
## rather than as a flickering screen — and it means the player can tell the
## difference between "the index is corrupt" and "the terminal is broken".
##
## Whitespace and the leading indent are never touched, because the columns are
## how a `LIST DATA` is read and a corruption pass that destroys the layout has
## destroyed the answer rather than degraded it.
func corrupt(line: String) -> String:
	var amount: float = corruption()
	if amount <= 0.0 or line.is_empty():
		return line
	var salt: float = float(line.length()) * 3.7 + float(line.hash() % 977)
	var out: String = ""
	for i: int in line.length():
		var glyph: String = line[i]
		if glyph == " " or glyph == "·":
			out += glyph
			continue
		if UiFx.hash01(salt + float(i) * 1.31) < amount:
			out += UiFx.CORRUPT_GLYPHS[int(UiFx.hash01(salt + float(i) * 7.7)
					* float(UiFx.CORRUPT_GLYPHS.length())) % UiFx.CORRUPT_GLYPHS.length()]
		else:
			out += glyph
	return out
