class_name CompilerPanel
extends CanvasLayer
## The Compiler's face: eight tracks, what the next tier of each does, what it
## costs, and what you have to pay with.
##
## Written in the M3.8 interface language rather than as a menu (DESIGN.md's
## "diegetic program-shell UI", and no default controls anywhere in this game):
## the panel **compiles in** line by line when it opens, the schematic header
## names the machine and its stock depth rather than saying "SHOP", a purchase
## resolves with the row running hot, and a refusal **glitches** — the row
## corrupts, the price goes hostile and the whole panel takes a hit, because
## being told no by MOTHER's own hardware should feel like being told no.
##
## Per player, on purpose. Two crewmates can stand at the same terminal with
## their own panels open, browsing different tracks, spending different wallets;
## nothing here is shared, replicated or synchronised, and the only thing that
## leaves the machine is a purchase request.
##
## Everything it draws is read live: it holds no copy of your tiers, your buffer
## or your archive. A crewmate's siphon landing, a shard absorbed on the way over
## and a purchase all show up on the next frame without a refresh path.

## One panel at a time, and it is always the local player's. Static because the
## Compiler in the world, the interact prompt and the dev flags all need to ask
## "is a panel up" without holding a reference to one.
static var _open: CompilerPanel = null

const WIDTH: float = 880.0
const ROW_HEIGHT: float = 52.0
const PAD: float = 26.0

## Seconds per row of the type-in reveal, and how long a purchase keeps a row lit.
const REVEAL_ROW: float = 0.055
const CONFIRM_TIME: float = 1.1
## A refusal glitch is longer than the HUD's damage flinch — the HUD's is a
## reflex, this is a machine refusing you, and it wants a beat to land.
const REFUSE_TIME: float = 0.55

## Named the actions rather than the keys, because the actions are what a pad is
## bound to as well.
const FOOTER_HINT: String = "↑↓ SELECT   ·   ACCEPT COMPILE   ·   BACK CLOSE"

var terminal: CompilerTerminal = null

var _rows: Array[Control] = []
var _selected: int = 0
var _reveal: float = 0.0
var _confirm: float = 0.0
var _confirm_row: int = -1
var _refuse: float = 0.0
var _refuse_row: int = -1
var _refuse_reason: String = ""

var _panel: Control = null
var _subtitle: Label = null
## The COMPILING beat: seconds remaining, and which row is locked while it runs.
var _beat: float = 0.0
var _beat_row: int = -1
var _beat_track: String = ""
## Tier pips animate in on open and on a purchase rather than appearing filled.
var _pip_fill: float = 0.0
var _pip_row: int = -1
var _wallet: Label = null
var _footer: Label = null
var _sheen: ColorRect = null


# ---------------------------------------------------------------- lifecycle --

static func is_open() -> bool:
	return _open != null and is_instance_valid(_open)


static func is_open_for(which: CompilerTerminal) -> bool:
	return is_open() and _open.terminal == which


## Opens the panel for the local player at `which`. Parented to the layer rather
## than to the terminal: a descent frees the layer, which is exactly when a panel
## left open would otherwise be pointing at a machine that no longer exists.
static func open_for(which: CompilerTerminal) -> CompilerPanel:
	if is_open():
		_open.close()
	if which == null or not is_instance_valid(which):
		return null
	var panel: CompilerPanel = CompilerPanel.new()
	panel.name = "CompilerPanel"
	panel.terminal = which
	panel.layer = 3  # above the HUD (1) and its overlays.
	which.get_tree().get_root().add_child(panel)
	_open = panel
	return panel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Modules.purchased.connect(_on_purchased)
	Modules.refused.connect(_on_refused)
	Run.run_ended.connect(func(_s: Dictionary) -> void: close())
	Run.descent_started.connect(func(_n: int) -> void: close())
	# The panel is parented to the root Window rather than to `current_scene`, so
	# `change_scene_to_file` does NOT free it — which is the whole reason it can
	# survive a session ending and wake up in the main menu. `Net.leave()` emits
	# neither `run_ended` nor `descent_started` (it calls `Run.reset()`, which
	# emits nothing), so this third connection is the one that covers a host
	# dropping while you are reading a Compiler.
	Net.session_ended.connect(func(_reason: String) -> void: close())
	# A panel is a thing you stand still to read. Releasing the pointer is the
	# right behaviour for a human and forbidden during a capture, so it goes
	# through the one guard every mouse-mode call site in this codebase asks.
	if Debug.may_capture_mouse():
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# Automation photographs the finished panel, never a reveal in progress.
	_reveal = 99.0 if Debug.automated else 0.0
	print("[Compiler] panel open at terminal %d (stock tier %d%s)" % [
		terminal.compiler_index, terminal.stock_tier,
		", sanctuary" if terminal.sanctuary else ""])


## Closing gives the pointer back to the game — but ONLY if there is still a game
## to give it back to. Two ways there is not, and both used to leave the player
## with no cursor and dead mouse clicks:
##
##   * the host drops while a panel is open. The scene changes to the menu, which
##     sets MOUSE_MODE_VISIBLE, and then this panel — which the scene change did
##     not free — notices its terminal is gone and re-captures on the next frame.
##   * the run ends while a panel is open. `Hud` and this panel are connected to
##     the same `Run.run_ended` and write opposite mouse modes; Godot fires slots
##     in connection order and the panel always connects later, so the debrief
##     came up with no cursor and `LEAVE` could not be clicked.
##
## Being live is the condition, not being in a particular scene: the same test
## the rest of the interface uses.
func close() -> void:
	# Three signals and `_process` can all reach here in the same frame, and
	# `queue_free()` does not stop `_process` running again before the frame ends.
	if is_queued_for_deletion():
		return
	if _open == self:
		_open = null
	if Debug.may_capture_mouse() and _run_is_live():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	queue_free()


## `Run.configured` rather than `Net.is_online`, so an editor-run solo session
## still gets its pointer back: `Net.leave()` calls `Run.reset()`, which clears
## `configured`, and `_end_run` sets `run_over` before it emits `run_ended`.
func _run_is_live() -> bool:
	return Run.configured and not Run.run_over and Run.local_alive()


# -------------------------------------------------------------------- build --

func _build() -> void:
	var accent: Color = UiFx.WARNING if terminal.sanctuary else UiFx.SYSTEM

	# The Compiler wears the same tube the HUD does.
	#
	# It is worth being explicit about the authorship here, because the fiction
	# has two machines in it. The terminal in the wall is MOTHER's — sleek, teal,
	# hers. What you are looking at is not the terminal: it is *your* readout of
	# the terminal, rendered on your own Northcairn hardware, which is why the
	# panel is amber and scanlined and the machine it is talking to is not. The
	# sanctuary terminals keep their warm accent on top of that, so "this one is
	# older than she is" still reads.
	var screen: SubViewportContainer = SubViewportContainer.new()
	screen.name = "Screen"
	screen.stretch = true
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_PASS
	var glass: ShaderMaterial = ShaderMaterial.new()
	glass.shader = Hud.CRT_SHADER
	glass.set_shader_parameter("amount", UiFx.TUBE_AMOUNT)
	glass.set_shader_parameter("gain", 1.24)
	glass.set_shader_parameter("scanline_strength", 0.15)
	# Flatter than the HUD's. A panel you are reading dense numbers off wants less
	# glass between you and the numbers than a readout you glance at.
	glass.set_shader_parameter("curvature", 0.032)
	glass.set_shader_parameter("vignette", 0.20)
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
	shade.color = Color(0.02, 0.012, 0.004, 0.74)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	tube.add_child(shade)

	# Centred by a container, not by hand.
	#
	# The first version anchored the plate to PRESET_CENTER and then wrote its
	# own offsets, which put a 780-pixel panel half off the left edge of a
	# capture — anchors resolved against a rect that did not exist yet. A
	# CenterContainer knows the panel's minimum size and does the arithmetic
	# after layout, which is the whole reason containers exist.
	var centre: CenterContainer = CenterContainer.new()
	centre.name = "Centre"
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tube.add_child(centre)

	var holder: Control = Control.new()
	holder.name = "Panel"
	holder.custom_minimum_size = Vector2(WIDTH,
			ROW_HEIGHT * float(Balance.MODULE_TRACKS.size()) + 210.0)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(holder)

	# The piece the refusal glitch shakes. Separate from `holder` because a
	# container owns its child's position and would put it back every frame.
	_panel = Control.new()
	_panel.name = "Shaker"
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(_panel)

	var frame: Control = _framed(_panel, accent)

	var column: VBoxContainer = VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 4)
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.offset_left = PAD
	column.offset_right = -PAD
	column.offset_top = PAD * 0.8
	column.offset_bottom = -PAD * 0.8
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(column)

	_text(column, "COMPILER  ·  MODULE SOURCE", 26, accent)
	_subtitle = _text(column, "", 13, UiFx.DIM)
	column.add_child(_rule(accent))
	_wallet = _text(column, "", 14, UiFx.TEXT)
	column.add_child(_rule(accent))

	for i: int in Balance.MODULE_TRACKS.size():
		var row: Control = _build_row(Balance.MODULE_TRACKS[i], i)
		column.add_child(row)
		_rows.append(row)

	column.add_child(_rule(accent))
	_footer = _text(column, FOOTER_HINT, 12, UiFx.DIM)

	# One panel-wide sheen sweep, the same shader the menu console and every HUD
	# cluster wear. It is what stops a rectangle of text reading as a rectangle
	# of text and starts it reading as a surface with light on it.
	_sheen = ColorRect.new()
	_sheen.name = "Sheen"
	_sheen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sheen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheen.color = Color.WHITE
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = Hud.SHEEN_SHADER
	material.set_shader_parameter("tint", accent)
	material.set_shader_parameter("sheen_strength", 0.05)
	material.set_shader_parameter("scanline_strength", 0.02)
	material.set_shader_parameter("sweep_period", 5.5)
	material.set_shader_parameter("sweep_width", 0.05)
	material.set_shader_parameter("perspective", 0.0)
	material.set_shader_parameter("mask_start", 0.94)
	_sheen.material = material
	frame.add_child(_sheen)


## The bordered plate everything sits on. Drawn rather than themed, so it wears
## the terminal's own accent colour without a StyleBox per Compiler.
func _framed(parent: Control, accent: Color) -> Control:
	var back: ColorRect = ColorRect.new()
	back.name = "Plate"
	back.color = Color(0.045, 0.030, 0.012, 0.93)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(back)

	for edge: int in 4:
		var line: ColorRect = ColorRect.new()
		line.color = Color(accent.r, accent.g, accent.b, 0.55)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		match edge:
			0:
				line.set_anchors_preset(Control.PRESET_TOP_WIDE)
				line.custom_minimum_size = Vector2(0.0, 2.0)
				line.offset_bottom = 2.0
			1:
				line.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
				line.custom_minimum_size = Vector2(0.0, 2.0)
				line.offset_top = -2.0
			2:
				line.set_anchors_preset(Control.PRESET_LEFT_WIDE)
				line.custom_minimum_size = Vector2(1.0, 0.0)
				line.offset_right = 1.0
			_:
				line.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
				line.custom_minimum_size = Vector2(1.0, 0.0)
				line.offset_left = -1.0
		back.add_child(line)
	return back


## One track. Five pieces laid out left to right, because that is the order the
## decision is made in: what is it, how far in am I, what does the next one do,
## what does it cost.
func _build_row(track: String, index: int) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "Row_" + track
	row.custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.set_meta("track", track)
	row.set_meta("index", index)

	var marker: ColorRect = ColorRect.new()
	marker.name = "Marker"
	marker.custom_minimum_size = Vector2(3.0, 0.0)
	marker.color = UiFx.SYSTEM
	row.add_child(marker)

	var glyph: Label = _cell(row, Modules.glyph(track), 20, UiFx.SYSTEM, 34.0)
	glyph.name = "Glyph"
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var name_label: Label = _cell(row, Modules.display_name(track), 17, UiFx.TEXT, 128.0)
	name_label.name = "Name"

	var pips: Label = _cell(row, "", 17, UiFx.SYSTEM, 96.0)
	pips.name = "Pips"

	var effect: Label = _cell(row, "", 13, UiFx.DIM, 0.0)
	effect.name = "Effect"
	effect.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var price: Label = _cell(row, "", 16, UiFx.SYSTEM, 132.0)
	price.name = "Price"
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	row.mouse_entered.connect(func() -> void: _selected = index)
	row.gui_input.connect(func(event: InputEvent) -> void:
		var click: InputEventMouseButton = event as InputEventMouseButton
		if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			_selected = index
			_buy())
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
	# M4.8 clipping sweep: the effect column carries the longest strings in the
	# game ("SHARE 100 -> 112 CYCLES  ·  DRAIN 0.60 -> 0.56 /s") and a tier-5
	# price is four digits wider than a tier-1 one. Clipped rather than allowed
	# to push the price cell out through the plate and the tube's curved edge.
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


func _rule(accent: Color) -> Control:
	var line: ColorRect = ColorRect.new()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.color = Color(accent.r, accent.g, accent.b, 0.28)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


# -------------------------------------------------------------------- input --

## Keyboard, mouse and pad, from one path.
##
## The panel navigates on `ui_up` / `ui_down` / `ui_accept` / `ui_cancel` rather
## than on raw keys, and Godot binds those to the D-pad, the left stick and the
## south/east face buttons by default — so gamepad support here is a property of
## having used the actions in the first place, and the M4.7 accessibility item
## costs this file nothing but the note saying so. Rows still take the mouse
## (hover selects, click buys); the three input methods do not know about each
## other.
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
		_buy()
		get_viewport().set_input_as_handled()


## Public so `--buy` drives exactly the path a keypress does rather than calling
## Modules behind the panel's back.
func select(track: String) -> void:
	for i: int in _rows.size():
		if String(_rows[i].get_meta("track")) == track:
			_selected = i
			return


func buy_selected() -> void:
	_buy()


func _buy() -> void:
	var track: String = _track_at(_selected)
	# The panel asks anyway even when its own quote says no: the host is the
	# authority on funds and stock, and a client that silently refuses its own
	# purchase is a client that can be wrong in a way nobody can see. The local
	# quote decides how the row is *drawn*, never whether the request is sent.
	Modules.request_purchase(track, terminal.compiler_index)


func _track_at(index: int) -> String:
	return String(_rows[clampi(index, 0, _rows.size() - 1)].get_meta("track"))


# ------------------------------------------------------------------ updating --

func _on_purchased(peer_id: int, track: String, _tier: int,
		_from_buffer: int, _from_archive: int) -> void:
	if peer_id != Net.local_id():
		return
	# The beat, then the confirmation. A purchase that resolves instantly reads as
	# a list item toggling; a purchase that visibly *takes a moment to compile*
	# reads as a machine doing work on your behalf — which, in a game whose entire
	# meta-progression is "modules compiled into your source", is the one
	# interaction that has to feel like something happened.
	_beat = UiFx.COMPILE_BEAT
	_beat_row = _row_of(track)
	_beat_track = track
	_pip_row = _beat_row
	_pip_fill = 0.0
	_confirm = CONFIRM_TIME + UiFx.COMPILE_BEAT
	_confirm_row = _row_of(track)
	# The whole refusal, not just its glitch weight. The footer reads `_refuse_row`
	# and `_refuse_reason` and checks neither against `_refuse`, so clearing only
	# the weight left `REFUSED · INSUFFICIENT DATA` printed under a row that had
	# since been bought — two cells from its own COMPILED ✓ stamp.
	_refuse = 0.0
	_refuse_row = -1
	_refuse_reason = ""


func _on_refused(track: String, reason: String) -> void:
	_refuse = REFUSE_TIME
	_refuse_row = _row_of(track)
	_refuse_reason = reason


func _row_of(track: String) -> int:
	for i: int in _rows.size():
		if String(_rows[i].get_meta("track")) == track:
			return i
	return -1


func _process(delta: float) -> void:
	if terminal == null or not is_instance_valid(terminal):
		close()
		return
	# Walking away closes it. The host would refuse the purchase anyway
	# (Modules._purchase_request checks the range), but a panel you can read from
	# the next room is a panel that stops being a machine.
	var me: Node = Net.get_player(Net.local_id())
	if me != null and is_instance_valid(me) \
			and (me as Node3D).global_position.distance_to(
					terminal.global_position) > CompilerTerminal.USE_RANGE:
		close()
		return

	_reveal += delta
	_confirm = maxf(_confirm - delta, 0.0)
	_refuse = maxf(_refuse - delta, 0.0)
	if _beat > 0.0:
		_beat = maxf(_beat - delta, 0.0)
		if _beat <= 0.0:
			# The beat has finished; the pips fill on the far side of it, with an
			# ease, so the tier arriving is the last thing that happens rather
			# than the first.
			_pip_fill = 0.0001
	elif _pip_fill > 0.0:
		_pip_fill = minf(_pip_fill + delta / UiFx.COMPILE_PIP_FILL, 1.0)
	# Automation photographs the finished panel unless it has been sent to
	# photograph a specific beat. Without this a soak would spend two thirds of a
	# second per purchase looking at a progress shimmer.
	if Debug.automated and Debug.hud_state != "compiling":
		_beat = 0.0
		_pip_fill = 1.0
	elif Debug.hud_state == "compiling":
		# Pinned mid-beat. 0.62 s is not a window a shutter lands in by luck, and
		# this is the frame that proves the panel does any of this at all.
		_beat = UiFx.COMPILE_BEAT * 0.45
		if _beat_row < 0:
			_beat_row = _selected
			_beat_track = _track_at(_selected)
	# `--hud-state refused` pins the glitch. It is 0.55 s long by design and no
	# shutter lands inside it by luck — the same reasoning, and the same escape
	# hatch, as the HUD's pinned damage flinch.
	if Debug.hud_state == "refused":
		_refuse = REFUSE_TIME * 0.72
		_refuse_row = _selected
		if _refuse_reason.is_empty():
			_refuse_reason = "INSUFFICIENT DATA"
	_refresh()


func _refresh() -> void:
	var me: int = Net.local_id()
	var buffer: int = Run.buffered_value_of(me)
	var archive: int = GameState.archive

	_subtitle.text = "%s  ·  LAYER %02d  ·  STOCK TIER %d%s" % [
		"SANCTUARY TERMINAL" if terminal.sanctuary else "UNLISTED TERMINAL",
		Run.layer_number, terminal.stock_tier,
		"  ·  ONE TIER DEEPER THAN THIS RING" if terminal.sanctuary else ""]
	_wallet.text = "BUFFERED  %d DATA          ARCHIVE  %d DATA          SPENDS BUFFER FIRST" % [
		buffer, archive]

	for i: int in _rows.size():
		_refresh_row(i)

	# The glitch is half a second; the *reason* stays until you look somewhere
	# else. Being told no should be a moment, but being told WHY should be
	# readable for as long as you are still standing there deciding.
	if _refuse_row == _selected and not _refuse_reason.is_empty():
		_footer.text = "REFUSED  ·  %s" % _refuse_reason
		_footer.add_theme_color_override("font_color", UiFx.HOSTILE)
	else:
		_footer.text = FOOTER_HINT
		_footer.add_theme_color_override("font_color", UiFx.DIM)


func _refresh_row(index: int) -> void:
	var row: Control = _rows[index]
	var track: String = String(row.get_meta("track"))
	var deal: Dictionary = Modules.quote(Net.local_id(), track, terminal.stock_tier)
	var tier: int = int(deal["tier"])
	var total: int = Modules.tier_count(track)
	var chosen: bool = index == _selected
	var affordable: bool = bool(deal["affordable"])
	var maxed: bool = tier >= total
	var stocked: bool = int(deal["next"]) <= terminal.stock_tier

	# Type-in reveal, staggered down the panel. Rows arrive as the shell finishes
	# resolving them, which is the same trick the HUD boots with.
	var visible_now: bool = _reveal >= float(index) * REVEAL_ROW
	row.modulate.a = 1.0 if visible_now else 0.0
	if not visible_now:
		return

	var lit: Color = UiFx.SYSTEM
	if maxed:
		lit = UiFx.DIM
	elif not stocked:
		lit = UiFx.WARNING.darkened(0.25)
	elif not affordable:
		lit = UiFx.DIM

	var marker: ColorRect = row.get_node("Marker") as ColorRect
	marker.color = Color(lit.r, lit.g, lit.b, 1.0 if chosen else 0.22)
	marker.custom_minimum_size.x = 4.0 if chosen else 3.0

	(row.get_node("Glyph") as Label).add_theme_color_override("font_color", lit)
	var name_label: Label = row.get_node("Name") as Label
	name_label.add_theme_color_override("font_color",
			UiFx.SYSTEM_HOT if chosen else (UiFx.TEXT if not maxed else UiFx.DIM))

	# Tier pips. Filled to what you have compiled, hollow for what the track
	# still holds, and the ones this terminal cannot sell you are drawn as bars
	# rather than circles — "not here" is a different answer from "not yet".
	var pips: PackedStringArray = PackedStringArray()
	for t: int in total:
		if t < tier:
			pips.append("●")
		elif t + 1 <= terminal.stock_tier:
			pips.append("○")
		else:
			pips.append("▪")
	# The tier that just landed fills with an ease rather than appearing filled:
	# the last pip is drawn hollow until the beat finishes and then snaps solid,
	# which is the tick at the end of the COMPILING sequence.
	if index == _pip_row and _pip_fill < 1.0 and tier > 0:
		var eased: float = 1.0 - pow(1.0 - _pip_fill, 3.0)
		if eased < 0.72:
			pips[tier - 1] = "○"
	(row.get_node("Pips") as Label).text = "".join(pips)
	(row.get_node("Pips") as Label).add_theme_color_override("font_color", lit)

	var effect: Label = row.get_node("Effect") as Label
	effect.text = _effect_line(track, tier, maxed)
	effect.add_theme_color_override("font_color",
			UiFx.TEXT if chosen and not maxed else UiFx.DIM)

	var price: Label = row.get_node("Price") as Label
	if maxed:
		price.text = "COMPILED"
		price.add_theme_color_override("font_color", UiFx.DIM)
	elif not stocked:
		price.text = "NOT STOCKED"
		price.add_theme_color_override("font_color", UiFx.WARNING.darkened(0.2))
	else:
		price.text = "%d DATA" % int(deal["price"])
		price.add_theme_color_override("font_color",
				UiFx.SYSTEM_HOT if affordable else UiFx.HOSTILE)

	# --- the COMPILING beat ---------------------------------------------------
	#
	# Three states in 0.62 s, and none of them is a spinner:
	#   LOCKED    the row stops being interactive and says what it is doing
	#   SHIMMER   a bright band travels the price cell left to right, once
	#   STAMP     "COMPILED" lands, and the tier pip fills behind it with a tick
	if _beat > 0.0 and index == _beat_row:
		var through: float = 1.0 - _beat / maxf(UiFx.COMPILE_BEAT, 0.01)
		name_label.add_theme_color_override("font_color", UiFx.SYSTEM_HOT)
		# A three-cell shimmer sliding across a fixed-width field. Mono type is
		# doing real work here: the band is the same width on every frame because
		# every glyph is.
		var cells: int = 11
		var head: int = int(through * float(cells + 3)) - 3
		var band: String = ""
		for cell: int in cells:
			band += "█" if cell >= head and cell < head + 3 else "░"
		price.text = band
		price.add_theme_color_override("font_color", UiFx.SYSTEM_HOT)
		(row.get_node("Marker") as ColorRect).color = UiFx.SYSTEM_HOT
		_apply_glitch(row, index, price)
		return

	# A purchase that landed: the row runs hot and falls back.
	if _confirm > 0.0 and index == _confirm_row:
		var heat: float = clampf(_confirm / CONFIRM_TIME, 0.0, 1.0)
		name_label.add_theme_color_override("font_color",
				UiFx.TEXT.lerp(UiFx.SYSTEM_HOT, heat))
		# The stamp. Held solid for most of its life and released at the end, so
		# it reads as something that was pressed onto the row rather than as a
		# label fading in and out.
		price.text = "COMPILED ✓"
		var stamp: Color = UiFx.SYSTEM_HOT
		stamp.a = clampf(_confirm / (CONFIRM_TIME * 0.35), 0.0, 1.0)
		price.add_theme_color_override("font_color", stamp)

	_apply_glitch(row, index, price)


## The refusal. Same vocabulary as the HUD's damage flinch and the menu's
## decompile — the row jumps a couple of pixels, its price corrupts into the
## glyph soup, and the panel behind it shivers. DESIGN.md reserves this language
## for things going wrong, and being unable to afford a module is a thing going
## wrong.
func _apply_glitch(row: Control, index: int, price: Label) -> void:
	if _refuse <= 0.0:
		row.position.x = 0.0
		if _panel != null:
			_panel.position.x = 0.0
		return

	var weight: float = _refuse / REFUSE_TIME
	var tick: float = floor(UiFx.clock() * 42.0)
	if index == _refuse_row:
		row.position.x = (UiFx.hash01(tick + float(index)) - 0.5) * 2.0 \
				* UiFx.GLITCH_SHIFT * 3.0 * weight
		var out: String = ""
		for i: int in price.text.length():
			if UiFx.hash01(tick + float(i) * 2.7) < weight * 0.5:
				out += UiFx.CORRUPT_GLYPHS[int(UiFx.hash01(tick + float(i) * 5.1)
						* float(UiFx.CORRUPT_GLYPHS.length()))
						% UiFx.CORRUPT_GLYPHS.length()]
			else:
				out += price.text[i]
		price.text = out
		price.add_theme_color_override("font_color", UiFx.HOSTILE)
	else:
		row.position.x = (UiFx.hash01(tick + float(index) * 3.3) - 0.5) \
				* UiFx.GLITCH_SHIFT * weight
	if _panel != null:
		_panel.position.x = (UiFx.hash01(tick * 1.7) - 0.5) * 3.0 * weight


## What the next tier of this track actually does, in the units the player reads
## it in elsewhere: metres, degrees, seconds, percent. Deliberately concrete —
## "BEAM 26° → 30°" is a decision, "OPTICS II" is a shopping list.
func _effect_line(track: String, tier: int, maxed: bool) -> String:
	if maxed:
		return Modules.note(track)
	var next: int = tier + 1
	match track:
		"runtime":
			return "SHARE %d → %d CYCLES   ·   DRAIN %.2f → %.2f /s" % [
				int(Balance.CYCLES_PER_CREW + float(Modules.value_at(track, "share", tier))),
				int(Balance.CYCLES_PER_CREW + float(Modules.value_at(track, "share", next))),
				Balance.PASSIVE_DRAIN * float(Modules.value_at(track, "drain", tier)),
				Balance.PASSIVE_DRAIN * float(Modules.value_at(track, "drain", next))]
		"threading":
			return "SPRINT COST ×%.2f → ×%.2f" % [
				float(Modules.value_at(track, "sprint", tier)),
				float(Modules.value_at(track, "sprint", next))]
		"checksum":
			return "MAX INTEGRITY %d → %d" % [
				int(Modules.value_at(track, "integrity", tier)),
				int(Modules.value_at(track, "integrity", next))]
		"breaker":
			return "DAMAGE %d → %d   ·   REACH %.1f → %.1f m" % [
				int(Modules.value_at(track, "damage", tier)),
				int(Modules.value_at(track, "damage", next)),
				float(Modules.value_at(track, "range", tier)),
				float(Modules.value_at(track, "range", next))]
		"optics":
			return "BEAM %.0f° → %.0f°   ·   REACH %d → %d m" % [
				float(Modules.value_at(track, "angle", tier)),
				float(Modules.value_at(track, "angle", next)),
				int(Modules.value_at(track, "reach", tier)),
				int(Modules.value_at(track, "reach", next))]
		"servos":
			return "MOVE ×%.2f → ×%.2f   ·   RESTORE %.1f → %.1f s" % [
				float(Modules.value_at(track, "move", tier)),
				float(Modules.value_at(track, "move", next)),
				Balance.RESTORE_CHANNEL_TIME * float(Modules.value_at(track, "restore", tier)),
				Balance.RESTORE_CHANNEL_TIME * float(Modules.value_at(track, "restore", next))]
		"buffer":
			return "FREE CARRY %d → %d CHIPS   ·   DRAG %d%% → %d%%" % [
				int(Modules.value_at(track, "free", tier)),
				int(Modules.value_at(track, "free", next)),
				int(round(float(Modules.value_at(track, "penalty", tier)) * 100.0)),
				int(round(float(Modules.value_at(track, "penalty", next)) * 100.0))]
		"cache":
			return "FLARES %d → %d" % [
				int(Modules.value_at(track, "stock", tier)),
				int(Modules.value_at(track, "stock", next))]
	return Modules.note(track)
