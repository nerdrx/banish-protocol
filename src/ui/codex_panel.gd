class_name CodexPanel
extends CanvasLayer
## THE CODEX — every upgrade in the game, what it does, and which of them this
## program has actually met.
##
## Three progression systems (patches, subroutines, modules) had names and glyphs
## and no reference anywhere. The TAB strip and the Compiler's detail block answer
## "what is this one doing right now"; this answers "what is there, and what have I
## not seen yet", which is a different question and needs somewhere to live.
##
## ## Why it is also a collection
##
## Patches are the only catalogue in the game a player cannot browse before they
## own it — modules and subroutines are on the Compiler's face from the first
## terminal, but a patch arrives out of a pocket secretary and is gone at the end
## of the run. So the patch section is REDACTED until first contact and fills in
## permanently after it (`GameState.codex`), which turns a reference into a record
## of what this program has been through. The rarity of a locked entry is still
## shown: "there are two KERNEL patches I have never held" is a thing worth
## knowing, and it is the part that makes the blanks interesting rather than
## annoying.
##
## Nothing here is a power. The Codex is documentation; every number on it is
## derived by `UpgradeText` from the constants the simulation runs on, so it cannot
## be wrong, and none of it crosses the wire.
##
## ## Interface language
##
## The Compiler's, deliberately — the same amber plate behind the same phosphor
## tube, because both are your own Northcairn hardware reading MOTHER's machine
## rather than MOTHER's machine talking to you. It navigates on `ui_*` actions, so
## a pad drives it for free.

## One at a time, and it is always the local player's.
static var _open: CodexPanel = null

const WIDTH: float = 960.0
const PAD: float = 24.0
## Index row, and the width of the index column beside the detail pane.
const ROW_HEIGHT: float = 23.0
const INDEX_WIDTH: float = 316.0
## Everything above and below the index column: title, subtitle, rules, footer.
const CHROME_HEIGHT: float = 190.0

const SECTION_PATCHES: int = 0
const SECTION_SUBROUTINES: int = 1
const SECTION_MODULES: int = 2

## A redacted entry's name and its clause. Block Elements, for the same reason the
## patch glyphs are Geometric Shapes: they resolve on every font in the system
## fallback chain, and an icon that draws as a box on somebody's machine is not an
## icon. Here the box IS the icon.
const REDACT_GLYPH: String = "▨"
const REDACT_NAME: String = "▒▒▒▒▒▒▒▒"
const REDACT_CLAUSE: String = "▒▒▒▒▒ ▒▒▒▒▒▒▒ ▒▒▒▒  ·  ▒▒▒▒ ▒▒"

const FOOTER_HINT: String = "↑↓ ENTRY   ·   ←→ SECTION   ·   BACK CLOSE"

var _section: int = SECTION_PATCHES
var _selected: int = 0
var _ids: Array[String] = []

var _title: Label = null
var _subtitle: Label = null
var _index: VBoxContainer = null
var _rows: Array[Label] = []
var _detail_glyph: Label = null
var _detail_name: Label = null
var _detail_state: Label = null
var _detail_body: Label = null
var _detail_rows: Array[Label] = []
var _footer: Label = null

## `--codex-seen ID,…`: a discovery set for a session, without the runs that earned
## it. Never written to the program file.
##
## Parsed HERE rather than in `Debug` for the reason `Patches._parse_forced` states
## at length: `src/core/debug.gd` is the project's shared instrument file and is
## append-only while several agents work in one tree, and reading our own flag off
## the command line costs one function and touches nobody else's milestone.
static var _forced_seen: Dictionary = {}
static var _forced_parsed: bool = false


# ---------------------------------------------------------------- lifecycle --

static func is_open() -> bool:
	return _open != null and is_instance_valid(_open)


## Opens for the local player, parented to the root Window rather than to the
## current scene — the same reasoning `CompilerPanel.open_for` documents: a scene
## change must not free a panel the player is reading.
static func open(host: Node) -> CodexPanel:
	if is_open():
		_open.close()
		return null
	if host == null or not host.is_inside_tree():
		return null
	var panel: CodexPanel = CodexPanel.new()
	panel.name = "CodexPanel"
	panel.layer = 4  # above the Compiler (3), which can be open behind it.
	host.get_tree().get_root().add_child(panel)
	_open = panel
	return panel


## Whether this session was launched to photograph the Codex, and which section.
## Returns -1 for "no flag".
static func flagged_section() -> int:
	_parse_flags()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] != "--codex":
			continue
		var want: String = "" if i + 1 >= args.size() else args[i + 1].strip_edges().to_lower()
		match want:
			"subroutines", "subs":
				return SECTION_SUBROUTINES
			"modules":
				return SECTION_MODULES
			_:
				return SECTION_PATCHES
	return -1


static func _parse_flags() -> void:
	if _forced_parsed:
		return
	_forced_parsed = true
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] != "--codex-seen" or i + 1 >= args.size():
			continue
		for chunk: String in args[i + 1].split(",", false):
			var id: String = chunk.strip_edges().to_lower()
			if Balance.PATCHES.has(id):
				_forced_seen[id] = true
			else:
				push_warning("[Codex] --codex-seen: no patch '%s'" % id)
		print("[Codex] forced discovery: %d entries" % _forced_seen.size())


## Has this program met `id`? The session overlay is presentation only and is never
## written back, so a capture cannot fill in a real player's record.
static func seen(id: String) -> bool:
	_parse_flags()
	return GameState.patch_seen(id) or bool(_forced_seen.get(id, false))


static func seen_count() -> int:
	var found: int = 0
	for id: String in Balance.PATCH_TRACKS:
		if seen(id):
			found += 1
	return found


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var wanted: int = flagged_section()
	if wanted >= 0:
		_section = wanted
	_build()
	_rebuild_index()
	Run.run_ended.connect(func(_s: Dictionary) -> void: close())
	Run.descent_started.connect(func(_n: int) -> void: close())
	Net.session_ended.connect(func(_reason: String) -> void: close())
	print("[Codex] open: %d/%d hot-patches catalogued" % [
		seen_count(), Balance.PATCH_TRACKS.size()])


func close() -> void:
	if is_queued_for_deletion():
		return
	if _open == self:
		_open = null
	queue_free()


# -------------------------------------------------------------------- build --

func _build() -> void:
	var accent: Color = UiFx.SYSTEM

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
	# Flatter than the HUD's, and for the same reason the Compiler's is: a panel you
	# read dense text off wants less glass between you and the text.
	glass.set_shader_parameter("curvature", 0.030)
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
	shade.color = Color(0.02, 0.012, 0.004, 0.80)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	tube.add_child(shade)

	# Capped and scrolled by the tube-safe rule (PT2). The tallest section is the
	# patch catalogue, so the panel is sized for that and the rest of the sections
	# simply leave the bottom of the index empty rather than resizing the plate
	# under the player's eyes.
	var holder: Control = SafeArea.modal(tube, Vector2(WIDTH,
			ROW_HEIGHT * float(Balance.PATCH_TRACKS.size()) + CHROME_HEIGHT))

	var frame: Control = _framed(holder, accent)

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

	_title = _text(column, "CODEX  ·  SYSTEMS REFERENCE", UiFx.FONT_HEAD + 7, accent)
	_subtitle = _text(column, "", UiFx.FONT_SMALL, UiFx.DIM)
	column.add_child(_rule(accent))

	var body: HBoxContainer = HBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 18)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(body)

	_index = VBoxContainer.new()
	_index.name = "Index"
	_index.custom_minimum_size = Vector2(INDEX_WIDTH, 0.0)
	_index.add_theme_constant_override("separation", 0)
	_index.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(_index)

	var detail: VBoxContainer = VBoxContainer.new()
	detail.name = "Detail"
	detail.add_theme_constant_override("separation", 3)
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(detail)

	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_child(head)
	_detail_glyph = _text(head, "", UiFx.FONT_HEAD + 5, accent)
	_detail_name = _text(head, "", UiFx.FONT_HEAD + 2, UiFx.TEXT)
	_detail_state = _text(detail, "", UiFx.FONT_SMALL, UiFx.DIM)

	# The mechanism sentence WRAPS. Everything else on this panel clips, because
	# everything else is a field; a mechanism a player has to guess the end of is
	# the state of affairs this whole pass exists to end.
	_detail_body = Label.new()
	_detail_body.name = "Mechanism"
	_detail_body.add_theme_font_size_override("font_size", UiFx.FONT_BODY)
	_detail_body.add_theme_color_override("font_color", UiFx.CAPTION)
	_detail_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_body.custom_minimum_size = Vector2(0.0, 96.0)
	_detail_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_detail_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_child(_detail_body)

	detail.add_child(_rule(accent))
	# The value table. Six rows is the deepest any catalogue goes (PATCH_MAX_STACKS),
	# built once and re-labelled, so changing entry costs no allocation.
	for _i: int in Balance.PATCH_MAX_STACKS:
		_detail_rows.append(_text(detail, "", UiFx.FONT_SMALL, UiFx.TEXT))

	column.add_child(_rule(accent))
	_footer = _text(column, FOOTER_HINT, 12, UiFx.DIM)


func _framed(parent: Control, accent: Color) -> Control:
	var back: ColorRect = ColorRect.new()
	back.name = "Plate"
	back.color = Color(0.045, 0.030, 0.012, 0.94)
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


func _text(parent: Control, content: String, size: int, colour: Color) -> Label:
	var label: Label = Label.new()
	label.text = content
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _rule(accent: Color) -> Control:
	var line: ColorRect = ColorRect.new()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.color = Color(accent.r, accent.g, accent.b, 0.28)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


# ----------------------------------------------------------------- sections --

func _section_ids(which: int) -> Array[String]:
	# Built element by element rather than returned from a ternary between array
	# literals: a typed array assigned from a ternary infers UNTYPED on both
	# branches and throws at RUNTIME, which parses green and dies silently.
	var out: Array[String] = []
	var source: Array[String] = Balance.PATCH_TRACKS
	if which == SECTION_SUBROUTINES:
		source = Balance.SUBROUTINE_TRACKS
	elif which == SECTION_MODULES:
		source = Balance.MODULE_TRACKS
	for id: String in source:
		out.append(id)
	return out


func _section_name(which: int) -> String:
	match which:
		SECTION_SUBROUTINES:
			return "SUBROUTINES"
		SECTION_MODULES:
			return "MODULES"
	return "HOT-PATCHES"


func _rebuild_index() -> void:
	_ids = _section_ids(_section)
	_selected = clampi(_selected, 0, maxi(_ids.size() - 1, 0))
	for row: Label in _rows:
		row.queue_free()
	_rows.clear()
	for i: int in _ids.size():
		var row: Label = Label.new()
		row.name = "Entry_" + _ids[i]
		row.custom_minimum_size = Vector2(INDEX_WIDTH, ROW_HEIGHT)
		row.add_theme_font_size_override("font_size", UiFx.FONT_SMALL)
		row.clip_text = true
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		var index: int = i
		row.mouse_entered.connect(func() -> void: _selected = index)
		_index.add_child(row)
		_rows.append(row)
	_refresh()


# -------------------------------------------------------------------- input --

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return
	if _ids.is_empty():
		return
	if event.is_action_pressed("ui_down"):
		_selected = (_selected + 1) % _ids.size()
	elif event.is_action_pressed("ui_up"):
		_selected = (_selected + _ids.size() - 1) % _ids.size()
	elif event.is_action_pressed("ui_right"):
		_section = (_section + 1) % 3
		_selected = 0
		_rebuild_index()
	elif event.is_action_pressed("ui_left"):
		_section = (_section + 2) % 3
		_selected = 0
		_rebuild_index()
	else:
		return
	Audio.play_2d(&"ui_select")
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	_refresh()


# ----------------------------------------------------------------- refresh --

func _refresh() -> void:
	if _subtitle == null or _ids.is_empty():
		return
	_subtitle.text = "%s   ·   %d ENTRIES   ·   HOT-PATCHES %d/%d CATALOGUED" % [
		_section_name(_section), _ids.size(), seen_count(),
		Balance.PATCH_TRACKS.size()]

	for i: int in _rows.size():
		_refresh_row(i)

	match _section:
		SECTION_SUBROUTINES:
			_refresh_subroutine(_ids[_selected])
		SECTION_MODULES:
			_refresh_module(_ids[_selected])
		_:
			_refresh_patch(_ids[_selected])


func _refresh_row(i: int) -> void:
	var id: String = _ids[i]
	var row: Label = _rows[i]
	var chosen: bool = i == _selected
	var mark: String = "▸ " if chosen else "  "
	match _section:
		SECTION_PATCHES:
			# A locked entry keeps its RARITY. "There are two KERNEL patches I have
			# never held" is worth knowing, and it is what makes the blanks a
			# collection rather than a defect.
			var rarity: int = Patches.rarity(id)
			if seen(id):
				row.text = "%s%s  %s" % [mark, Patches.glyph(id), Patches.display_name(id)]
				row.add_theme_color_override("font_color",
						UiFx.SYSTEM_HOT if chosen else UiFx.TEXT)
			else:
				# The RARITY stays. "Two KERNEL patches I have never held" is the
				# fact that makes a locked row worth looking at, and a column of
				# identical blanks is the version of this screen nobody scrolls.
				row.text = "%s%s  %s  ·  %s" % [mark, REDACT_GLYPH, REDACT_NAME,
						Balance.patch_tier_name(rarity)]
				row.add_theme_color_override("font_color",
						UiFx.CAPTION if chosen else UiFx.DIM)
		SECTION_SUBROUTINES:
			var owned: int = Subs.tier_of(Net.local_id(), id)
			row.text = "%s%s  %s%s" % [mark, Subs.glyph(id), Subs.display_name(id),
					"" if owned <= 0 else "  ·  %d" % owned]
			row.add_theme_color_override("font_color",
					UiFx.SYSTEM_HOT if chosen else (UiFx.TEXT if owned > 0 else UiFx.DIM))
		_:
			var compiled: int = GameState.module_tier(id)
			row.text = "%s%s  %s%s" % [mark, Modules.glyph(id), Modules.display_name(id),
					"" if compiled <= 0 else "  ·  %d" % compiled]
			row.add_theme_color_override("font_color",
					UiFx.SYSTEM_HOT if chosen else (UiFx.TEXT if compiled > 0 else UiFx.DIM))


## A hot-patch. The value table is the point: the same clause at one stack, at a
## middling stack and at the ceiling, so a player can see what a second copy of
## something is worth BEFORE they walk past the slate holding it.
func _refresh_patch(id: String) -> void:
	var tier: int = Patches.rarity(id)
	var carried: int = Patches.local_stacks(id)
	var found: bool = seen(id)

	_detail_glyph.text = Patches.glyph(id) if found else REDACT_GLYPH
	_detail_glyph.add_theme_color_override("font_color",
			PatchFx.rarity_colour(tier) if found else UiFx.DIM)
	_detail_name.text = Patches.display_name(id) if found else REDACT_NAME
	_detail_name.add_theme_color_override("font_color",
			UiFx.TEXT if found else UiFx.DIM)

	var facts: PackedStringArray = PackedStringArray()
	facts.append(Balance.patch_tier_name(tier))
	facts.append("RUN-SCOPED")
	facts.append("SELLS BACK FOR %d DATA A STACK" % Balance.PATCH_EXFIL_DATA[
			clampi(tier, 0, Balance.PATCH_EXFIL_DATA.size() - 1)])
	if carried > 0:
		facts.append("CARRIED x%d" % carried)
	if not found:
		facts.append("NO SAMPLE ON FILE")
	_detail_state.text = "   ·   ".join(facts)

	_detail_body.text = UpgradeText.patch_body(id) if found else \
			"This entry writes itself the first time a hot-patch of this class is injected into your program. They are left on pocket secretaries, sealed into anomaly caches, and occasionally dropped by something you delete."

	# One row per interesting stack count: the first, the middle of the curve, and
	# the ceiling. Rendered from `UpgradeText`, so the table is the arithmetic the
	# simulation runs rather than a description of it.
	var samples: Array[int] = [1, 3, Balance.PATCH_MAX_STACKS]
	if carried > 0 and not samples.has(carried):
		samples.append(carried)
	samples.sort()
	for i: int in _detail_rows.size():
		var row: Label = _detail_rows[i]
		if i >= samples.size():
			row.text = ""
			continue
		var count: int = samples[i]
		if not found:
			row.text = "x%d    %s" % [count, REDACT_CLAUSE]
			row.add_theme_color_override("font_color", UiFx.DIM)
			continue
		row.text = "x%d    %s" % [count, UpgradeText.patch_line(id, count)]
		# The stack you are actually holding is lit; the rest are reference.
		row.add_theme_color_override("font_color",
				UiFx.SYSTEM_HOT if count == carried else UiFx.CAPTION)


func _refresh_subroutine(id: String) -> void:
	var owned: int = Subs.tier_of(Net.local_id(), id)
	var total: int = Subs.tier_count(id)
	_detail_glyph.text = Subs.glyph(id)
	_detail_glyph.add_theme_color_override("font_color", UiFx.SYSTEM)
	_detail_name.text = Subs.display_name(id)
	_detail_name.add_theme_color_override("font_color", UiFx.TEXT)

	var facts: PackedStringArray = PackedStringArray()
	facts.append("ONE ACTIVE SLOT" if owned <= 0 else "COMPILED TIER %d/%d" % [owned, total])
	facts.append(Subs.note(id))
	if Subs.local_equipped() == id:
		facts.append("SLOTTED")
	_detail_state.text = "   ·   ".join(facts)
	_detail_body.text = UpgradeText.subroutine_body(id)

	for i: int in _detail_rows.size():
		var row: Label = _detail_rows[i]
		if i >= total:
			row.text = ""
			continue
		var tier: int = i + 1
		row.text = "TIER %d    %s    ·    %d DATA" % [
			tier, UpgradeText.subroutine_state(id, tier), Subs.price(id, tier - 1)]
		row.add_theme_color_override("font_color",
				UiFx.SYSTEM_HOT if tier == owned else
				(UiFx.CAPTION if tier < owned else UiFx.DIM))


func _refresh_module(track: String) -> void:
	var tier: int = GameState.module_tier(track)
	var total: int = Modules.tier_count(track)
	_detail_glyph.text = Modules.glyph(track)
	_detail_glyph.add_theme_color_override("font_color", UiFx.SYSTEM)
	_detail_name.text = Modules.display_name(track)
	_detail_name.add_theme_color_override("font_color", UiFx.TEXT)
	_detail_state.text = "%s   ·   %s   ·   PERMANENT" % [
		"NOT COMPILED" if tier <= 0 else "COMPILED TIER %d/%d" % [tier, total],
		Modules.note(track)]
	_detail_body.text = UpgradeText.module_body(track)

	for i: int in _detail_rows.size():
		var row: Label = _detail_rows[i]
		if i >= total:
			row.text = ""
			continue
		# The whole ladder, each rung as the transition it is. A player deciding
		# whether OPTICS is worth committing to wants to see tier 5 from tier 1.
		row.text = "%d → %d    %s    ·    %d DATA" % [
			i, i + 1, UpgradeText.module_delta(track, i), Modules.price(track, i)]
		row.add_theme_color_override("font_color",
				UiFx.SYSTEM_HOT if i + 1 == tier + 1 and tier < total else
				(UiFx.CAPTION if i < tier else UiFx.DIM))
