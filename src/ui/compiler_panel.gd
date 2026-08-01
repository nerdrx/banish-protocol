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

const WIDTH: float = 780.0
const ROW_HEIGHT: float = 52.0
const PAD: float = 26.0

## Seconds per row of the type-in reveal, and how long a purchase keeps a row lit.
const REVEAL_ROW: float = 0.055
const CONFIRM_TIME: float = 1.1
## A refusal glitch is longer than the HUD's damage flinch — the HUD's is a
## reflex, this is a machine refusing you, and it wants a beat to land.
const REFUSE_TIME: float = 0.55

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


func close() -> void:
	if _open == self:
		_open = null
	if Debug.may_capture_mouse():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	queue_free()


# -------------------------------------------------------------------- build --

func _build() -> void:
	var accent: Color = UiFx.WARNING if terminal.sanctuary else UiFx.SYSTEM

	var shade: ColorRect = ColorRect.new()
	shade.name = "Shade"
	shade.color = Color(0.0, 0.02, 0.04, 0.72)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)

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
	add_child(centre)

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
	_footer = _text(column, "↑↓ SELECT   ·   ENTER COMPILE   ·   ESC CLOSE", 12, UiFx.DIM)

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
	back.color = Color(0.015, 0.05, 0.075, 0.94)
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
	parent.add_child(label)
	return label


func _text(parent: Control, text: String, size: int, colour: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _rule(accent: Color) -> Control:
	var line: ColorRect = ColorRect.new()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.color = Color(accent.r, accent.g, accent.b, 0.28)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


# -------------------------------------------------------------------- input --

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
	_confirm = CONFIRM_TIME
	_confirm_row = _row_of(track)
	_refuse = 0.0


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
		_footer.text = "↑↓ SELECT   ·   ENTER COMPILE   ·   ESC CLOSE"
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
	var pips: String = ""
	for t: int in total:
		if t < tier:
			pips += "●"
		elif t + 1 <= terminal.stock_tier:
			pips += "○"
		else:
			pips += "▪"
	(row.get_node("Pips") as Label).text = pips
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

	# A purchase that landed: the row runs hot and falls back.
	if _confirm > 0.0 and index == _confirm_row:
		var heat: float = _confirm / CONFIRM_TIME
		name_label.add_theme_color_override("font_color",
				UiFx.TEXT.lerp(UiFx.SYSTEM_HOT, heat))
		price.text = "COMPILED  ✓"
		price.add_theme_color_override("font_color", UiFx.SYSTEM_HOT)

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
