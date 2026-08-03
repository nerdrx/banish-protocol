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
## Built in `_ready` rather than in the scene, so it has no `%` name. Held because
## the focus chain needs it: SETTINGS is where UI SCALE and VIGNETTE live, and it
## was missing from `_wire_focus`'s explicit order — which on a pad meant the two
## settings the last two playtests asked for by name were unreachable without a
## mouse. DESIGN.md's solo invariant has an accessibility half.
var _settings_button: Button = null
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
##
## NAMES, resolved with `find_child`, not paths — and that is a bug fix, not a
## style preference. These used to be paths rooted at this node ("Margin/Column/
## Title"), and `_build_terminal` reparents every one of those controls into the
## tube's SubViewport BEFORE `_open_console` runs. So every lookup returned null,
## the reveal list was empty, and the type-in that the console's whole first
## impression is built on had silently not run since the tube landed. PT2's
## tube-safe area would have moved them a second time; names survive both.
const REVEAL_NAMES: Array[String] = [
	"Title",
	"Subtitle",
	"CallsignLabel",
	"MarkerLabel",
	"InjectionLabel",
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


## Walk the tree and give every button the console's mechanical voice: a near-
## subliminal hover tick as focus moves, a solenoid clack on press. Recursive so
## it covers the built-in-code panels (phosphor picker, program panel) too.
func _wire_menu_audio(node: Node) -> void:
	for child: Node in node.get_children():
		var button: Button = child as Button
		if button != null:
			button.mouse_entered.connect(func() -> void: Audio.play_2d(&"ui_hover"))
			button.pressed.connect(func() -> void: Audio.play_2d(&"ui_select"))
		var option: OptionButton = child as OptionButton
		if option != null:
			option.item_selected.connect(func(_i: int) -> void: Audio.play_2d(&"ui_select"))
		_wire_menu_audio(child)


func _ready() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# FIRST. Everything below either lives inside the safe area or measures it.
	_build_safe_area()
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

	# A SETTINGS entry beside QUIT, built in code so no scene surgery is needed.
	# Opens the M5 audio-comfort slice (SettingsPanel); the full IA is a later pass.
	# BEFORE `_wire_focus`, which builds an explicit focus ring out of the controls
	# that exist when it runs — this button being created after it is why SETTINGS
	# had never been on the ring at all.
	var settings_button: Button = Button.new()
	settings_button.text = "SETTINGS"
	# Matched to ABANDON. Without these it inherited a container's FILL and stretched
	# the whole width of the menu while its twin sat at 160 px — the two global
	# actions are equals and now measure the same. See `_build_menu_scroll`/STACKED.
	settings_button.custom_minimum_size = Vector2(160.0, 0.0)
	settings_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var quit_parent: Node = _quit_button.get_parent()
	if quit_parent != null:
		quit_parent.add_child(settings_button)
		quit_parent.move_child(settings_button, _quit_button.get_index())
		settings_button.pressed.connect(func() -> void: SettingsPanel.open(self))
	_settings_button = settings_button

	_wire_focus()
	# M5: the 144 s menu theme, and the CRT menu/terminal room tone (the ambient
	# bed AudioService picks when no run is live). Every button gets the analogue
	# hover tick and select clack.
	Music.enter_menu()
	_wire_menu_audio(self)

	var carried: String = GameState.consume_status()
	if carried.is_empty():
		_set_status("AWAITING ORDERS", COLOUR_IDLE)
	else:
		_set_status(carried, COLOUR_CARRIED)

	# Arriving with a status in hand means we just came out of an intrusion, so
	# the console recompiles out of black — the reverse of the dissolve that took
	# us in. A cold boot simply types itself in.
	_open_console(not carried.is_empty())


# -------------------------------------------------------------- safe area --
#
# PT2. See `UiFx.tube_safe_rect` for the rule and why the canvas is not 1280 wide.
#
# The split this makes is the whole fix, and it is a content decision rather than
# a technical one: **information goes inside the glass, dressing goes edge to
# edge.** The Backdrop gradient and the Schematic stay full-bleed children of this
# node — they are texture, they have nothing to lose to a barrel warp, and on a
# 32:9 panel they are what fills the 1280 px of canvas either side of the console
# so the extra width reads as a dark room rather than as a letterbox. Everything
# a player has to read or click moves inside `_safe`.

## The tube-safe box. Every readable control in the menu is a descendant.
var _safe: Control = null

## `Margin`'s insets once it lives inside the tube-safe box rather than on the raw
## canvas. Small on purpose: the 7.5% tube inset is already the standoff from the
## glass, and everything these have left to clear is the frame's own furniture —
## `Frame/TopRule` at +40 from the top of the box, and `Ticker`/`Version` in its
## last 28 rows. See `_build_menu_scroll`'s DOUBLE INSET note.
const SAFE_MARGIN_TOP: int = 48
const SAFE_MARGIN_BOTTOM: int = 40


func _build_safe_area() -> void:
	_safe = Control.new()
	_safe.name = "SafeArea"
	_safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_safe)
	# In front of the ambient layers, behind the post grade — the same slot the
	# console occupied before, so the dive dissolve still takes it apart.
	move_child(_safe, _post.get_index())

	# `reparent` rather than remove/add: it keeps `owner`, and therefore keeps
	# every `%UniqueName` in this file resolving. Same trap `_build_terminal`
	# documents hitting.
	#
	# `Frame` comes too. Its two hairline rules were anchored to the canvas, which
	# on an ultrawide drew a 5120 px line across the whole panel with the console
	# a small island in the middle of it — the rules are the tube's own frame, so
	# they belong on the tube's own box.
	for leaf: String in ["Frame", "Margin", "Ticker", "Version"]:
		var control: Control = get_node_or_null(leaf) as Control
		if control != null:
			control.reparent(_safe, false)

	_build_menu_scroll()
	get_viewport().size_changed.connect(_fit_safe_area)
	_fit_safe_area()


## The console SCROLLS when it does not fit, and PT2 is what made that possible
## to need.
##
## The live playtest: "the menu isn't completely visible with the wrong screen
## aspect". The column is title + subtitle + a ~470 px console + two buttons,
## about 640 px of content, and the tube-safe box is 612 px tall at 16:9 — under
## the design resolution it fitted with nothing to spare, so any of {a 16:10
## window, a UI SCALE above 1.0, a short window} pushed ABANDON off the bottom of
## a MarginContainer that has no opinion about overflow. The buttons were not
## small or dim; they were not on the screen.
##
## A ScrollContainer is the fix rather than shrinking the console, because the
## thing the player asked for by turning UI SCALE up is BIGGER TEXT, and answering
## that by making the console smaller again would be answering a different
## question. Content that fits still centres exactly as before (the column keeps
## `alignment = CENTER` and fills the viewport when it is shorter than it); content
## that does not fit gains a scrollbar and stays entirely reachable.
##
## ## What the scroll alone did NOT fix (PT2, second pass)
##
## `--ui-audit` at the player's own 3440x1440, at UI SCALE 1.0, on the DEFAULT
## build: SETTINGS and ABANDON `OUTSIDE-SAFE CLIPPED(-31px)`, the console
## `CLIPPED(-71px)`, JOIN CREW and the status line cut. The scrollbar was real and
## the content was reachable — by scrolling — but every actionable control in the
## menu was below the fold on a cold boot. "Reachable after an action the player
## has no reason to guess at" is not visible, and the live report said so.
##
## Three things were wrong, and only the third one is taste:
##
##   DOUBLE INSET   `Margin`'s 48/110 px margins were authored when it filled the
##                  1280x720 CANVAS, where 110 px at the bottom was what kept the
##                  column clear of the ticker on the canvas's last rows. PT2
##                  reparented it into the tube-safe box — which is ALREADY inset
##                  7.5% — so the two insets stacked and 158 of 612 usable rows
##                  went to nothing. Re-authored here against the box it now
##                  lives in, which is also why it is done in code: `Margin` still
##                  fills the raw canvas under `--no-safe-area`, and that path has
##                  to keep the geometry it is there to photograph.
##   SCROLLED-AWAY  the two global actions were the LAST rows of a scrolling
##                  column, so they were the first casualties of a short box. They
##                  are now a fixed action bar OUTSIDE the scroll, pinned to the
##                  bottom of the safe area: SETTINGS and ABANDON are on the
##                  screen at every aspect and every UI scale, and only the
##                  console body scrolls. This is the ordinary dialog contract —
##                  a scrolling body over a fixed action row — and it is the only
##                  arrangement in which a scroll cannot hide a verb.
##   STACKED        those two buttons were also stacked vertically, and SETTINGS
##                  had no horizontal size flag so it stretched the full width
##                  while ABANDON sat at 160 px. Side by side in one 31 px row:
##                  37 rows cheaper than the stack, and they finally look like the
##                  pair of equals they are.
func _build_menu_scroll() -> void:
	var column: Control = find_child("Column", true, false) as Control
	if column == null:
		return
	var margin: MarginContainer = column.get_parent() as MarginContainer
	if margin == null:
		return

	# Re-authored against the safe box (see DOUBLE INSET above). The top clears
	# `Frame/TopRule` at +40 and the bottom clears `Ticker`/`Version`, which sit in
	# the box's last 28 rows.
	if not Debug.no_safe_area:
		margin.add_theme_constant_override("margin_top", SAFE_MARGIN_TOP)
		margin.add_theme_constant_override("margin_bottom", SAFE_MARGIN_BOTTOM)

	# Shell: a scrolling body over a fixed action row.
	var shell: VBoxContainer = VBoxContainer.new()
	shell.name = "Shell"
	shell.add_theme_constant_override("separation", 10)
	margin.add_child(shell)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.name = "ColumnScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true  # a pad user tabbing into the console scrolls to it
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	shell.add_child(scroll)
	_style_scrollbar(scroll)
	column.reparent(scroll, false)
	# EXPAND_FILL so a column shorter than the viewport still fills it and its own
	# centre alignment keeps working — otherwise adding the scroll would silently
	# top-align the entire menu. A column TALLER than the viewport still reports its
	# own minimum height, which is what raises the scrollbar.
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# The fixed action row. `_ready` adds SETTINGS beside ABANDON by asking for
	# ABANDON's PARENT, so moving ABANDON here is all it takes to move both.
	var actions: HBoxContainer = HBoxContainer.new()
	actions.name = "ActionBar"
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 12)
	shell.add_child(actions)
	if _quit_button != null and is_instance_valid(_quit_button):
		_quit_button.reparent(actions, false)
	# `Gap2` spaced the action buttons off the console inside the old column; the
	# shell's own separation does that now, and leaving it in adds 12 dead rows to
	# the scrolling body.
	var gap2: Node = find_child("Gap2", true, false)
	if gap2 != null:
		gap2.queue_free()

	_scroll = scroll
	_column = column as VBoxContainer
	_capture_authored_density()


## Make the scrollbar look like a scrollbar.
##
## Godot's default is a grey rounded pill on no track, and on this backdrop — a
## dark room full of drifting grey schematic furniture — that is indistinguishable
## from the dressing. It was there the whole time in the PT2 captures and it read
## as part of the wallpaper, which for a player's purposes is the same as the
## menu simply ending. An affordance nobody can see is not an affordance.
##
## A recessed track plus a phosphor grabber, in the interface's own two colours.
func _style_scrollbar(scroll: ScrollContainer) -> void:
	var bar: VScrollBar = scroll.get_v_scroll_bar()
	if bar == null:
		return
	bar.custom_minimum_size = Vector2(10.0, 0.0)

	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.10)
	track.set_corner_radius_all(1)
	track.set_content_margin_all(0)
	bar.add_theme_stylebox_override(&"scroll", track)

	var grabber: StyleBoxFlat = StyleBoxFlat.new()
	grabber.bg_color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.55)
	grabber.set_corner_radius_all(1)
	bar.add_theme_stylebox_override(&"grabber", grabber)

	var hot: StyleBoxFlat = grabber.duplicate() as StyleBoxFlat
	hot.bg_color = Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.85)
	bar.add_theme_stylebox_override(&"grabber_highlight", hot)
	bar.add_theme_stylebox_override(&"grabber_pressed", hot)


# --------------------------------------------------------------- density --
#
# The last 42 px, and why they are not taken out of the type.
#
# After the action bar came out of the scroll, `--ui-audit` at 3440x1440 x1.0 read
# `CLIPPED(-42px)`: 525 rows of column into 483 rows of box. Two ways to close a
# 42 px gap, and only one of them is allowed. The fonts and the contrast are the
# ANSWER to playtest 1 ("barely legible on ANY screen") — spending them to buy
# layout would be undoing the last fix to pay for this one. Whitespace is not an
# answer to anything, and this console is spaced on a single uniform 8 px rhythm
# that was chosen at one resolution.
#
# So the density is a function of the box. Three tiers of the AUTHORED spacing —
# never absolute numbers, so re-spacing the scene in the editor still works — and
# the loosest one that fits wins. Type, colour and hit-target sizes are untouched
# at every tier; only the air between rows moves. A short box gets a tighter
# console, which is what a person laying this out by hand would do, and the
# scrollbar stays as the backstop for the genuinely extreme cases (UI SCALE 1.6 on
# a 32:9 panel is 382 usable rows and no amount of tightening fits 525 into it).

## Multipliers on the authored separations, loosest first. 0.35 is the floor
## because below about 3 px a rule and a label stop reading as separate rows.
const DENSITY_TIERS: Array[float] = [1.0, 0.6, 0.35]
## Vertical rhythm never goes below this, whatever the multiplier says.
const DENSITY_FLOOR: int = 2

var _scroll: ScrollContainer = null
var _column: VBoxContainer = null
## Node -> authored vertical separation, sampled once before anything is tightened.
## Re-deriving from the live value would compound: tier 0.6 applied twice is 0.36.
var _authored_separation: Dictionary = {}
## The `Gap` spacer's authored height, same reason.
var _authored_gap: float = 0.0
var _density_tier: int = -1


## Only the VERTICAL rhythm. `ColorRow`, `TransportRow`, `HostRow` and `JoinRow`
## are HBoxes whose separation is horizontal — tightening those would buy no rows
## and would jam the transport buttons into each other.
func _density_targets() -> Array[BoxContainer]:
	var out: Array[BoxContainer] = []
	for leaf: String in ["Column", "Fields", "SteamSection", "DirectSection",
			"ProgramFields"]:
		var box: VBoxContainer = find_child(leaf, true, false) as VBoxContainer
		if box != null:
			out.append(box)
	return out


## Idempotent per node, and called a second time once `_build_program_panel` has
## added its rows. Re-sampling a node that has already been tightened would record
## the TIGHTENED value as the authored one, and every later pass would compound
## against it — tier 0.6 applied twice is 0.36.
func _capture_authored_density() -> void:
	for box: BoxContainer in _density_targets():
		if not _authored_separation.has(box):
			_authored_separation[box] = box.get_theme_constant(&"separation")
	var gap: Control = find_child("Gap", true, false) as Control
	if gap != null and _authored_gap <= 0.0:
		_authored_gap = gap.custom_minimum_size.y
	# A node joined the set, so whatever tier is applied has not been applied to it.
	_density_tier = -1


## The panel is as tall as its rows and no taller. Re-derived after every density
## change, because the rows it is measuring have just moved.
func _fit_program_height() -> void:
	if _program_panel == null or not is_instance_valid(_program_panel):
		return
	if _program_fields == null or not is_instance_valid(_program_fields):
		return
	_program_panel.custom_minimum_size.y = \
			_program_fields.get_combined_minimum_size().y + PROGRAM_PADDING * 2.0


## Pick the loosest tier whose column fits `available` rows, and apply it.
##
## Measured rather than predicted: the console has two mutually exclusive halves
## (STEAM and DIRECT) and a status line that grows, so the number of visible gaps
## is not a constant this file can do arithmetic on. Applying a tier and asking the
## container what it now needs is both shorter and correct.
func _apply_density(available: float) -> void:
	if _column == null or not is_instance_valid(_column) or available <= 0.0:
		return
	for tier: int in DENSITY_TIERS.size():
		_set_density(tier)
		if _column.get_combined_minimum_size().y <= available:
			return
	# Nothing fits: stay at the tightest and let the scrollbar do its job.


func _set_density(tier: int) -> void:
	if tier == _density_tier:
		return
	_density_tier = tier
	var scale: float = DENSITY_TIERS[tier]
	for box: BoxContainer in _density_targets():
		var authored: Variant = _authored_separation.get(box)
		if authored == null:
			continue
		box.add_theme_constant_override(&"separation",
				maxi(DENSITY_FLOOR, int(round(float(authored) * scale))))
	var gap: Control = find_child("Gap", true, false) as Control
	if gap != null and _authored_gap > 0.0:
		gap.custom_minimum_size.y = maxf(float(DENSITY_FLOOR), _authored_gap * scale)
	_fit_program_height()


## Re-solve the box. Called on every viewport change, which covers the window
## being dragged between monitors, going fullscreen, AND the UI-scale slider
## moving (a scale change resizes the 2D canvas, so it arrives here as a resize).
func _fit_safe_area() -> void:
	if _safe == null or not is_instance_valid(_safe):
		return
	var view: Vector2 = get_viewport_rect().size
	UiFx.fit_to_safe_area(_safe, view)
	_place_program_panel()
	# Deferred: `_safe` has only just been given its new anchors, so the scroll
	# inside it still reports LAST frame's height. Measuring the box before the
	# containers have re-sorted picks the density for a screen that no longer
	# exists — and on the very first call, for a box of zero.
	_refit_density.call_deferred()


func _refit_density() -> void:
	if _scroll == null or not is_instance_valid(_scroll):
		return
	_apply_density(_scroll.size.y)


# ------------------------------------------------------------ presentation --

## Opens the injection console. `returning` is true when we have just come back
## out of a run, which is when the screen has to recompile from black.
func _open_console(returning: bool) -> void:
	_reveal_labels.clear()
	for leaf: String in REVEAL_NAMES:
		var label: Label = find_child(leaf, true, false) as Label
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

	# Capture hook: the first-launch safety warning is otherwise reachable only on a
	# real, un-automated first launch. `--hud-state a11ywarn` photographs it.
	if Debug.hud_state == "a11ywarn":
		_show_photosensitivity_warning.call_deferred()
	# PT2: and the settings panel, which is otherwise two clicks past a button no
	# scripted probe presses. Pair with `--ui-scale` / `--vignette` to photograph
	# the sliders at a known value.
	if Debug.hud_state == "settings":
		(func() -> void: SettingsPanel.open(self)).call_deferred()

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
	# SAFETY-CRITICAL (limbo-a11y): the first-launch photosensitivity caution, shown
	# once before any animated menu content is legible, offering Reduced Flashing at
	# equal prominence. Skipped under automation (returned above) so a capture is
	# never of the warning. Deferred so the menu finishes laying out first.
	if not A11y.warning_ack:
		_show_photosensitivity_warning.call_deferred()
	_reveal_clock = 0.0


## SAFETY-CRITICAL (limbo-a11y 01-photosensitivity). The first-launch caution.
##
## Built in code as a CanvasLayer above everything, deliberately WITHOUT the CRT
## tube or any glitch driver — the one screen in the game that must never flash is
## the one warning about flashing. The menu's animated backdrop is frozen while it
## is up (`set_process(false)`) and hidden under a near-opaque plate, so nothing
## strobes behind it either. Two buttons of EQUAL weight — the safe option is not a
## secondary link. Shown once (A11y.warning_ack); a fuller settings pass will make
## it reachable again and add the standing toggle.
func _show_photosensitivity_warning() -> void:
	set_process(false)  # freeze the ticker and console sweep behind the plate

	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "PhotosensitivityWarning"
	layer.layer = 200
	add_child(layer)

	var plate: ColorRect = ColorRect.new()
	plate.set_anchors_preset(Control.PRESET_FULL_RECT)
	plate.color = Color(0.015, 0.015, 0.022, 0.985)
	plate.mouse_filter = Control.MOUSE_FILTER_STOP  # swallows input to the menu behind
	layer.add_child(plate)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	plate.add_child(center)

	var column: VBoxContainer = VBoxContainer.new()
	column.custom_minimum_size = Vector2(560.0, 0.0)
	column.add_theme_constant_override("separation", 18)
	center.add_child(column)

	var title: Label = Label.new()
	title.text = "PHOTOSENSITIVITY WARNING"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", UiFx.WARNING)
	column.add_child(title)

	var body: Label = Label.new()
	body.text = "This game contains flashing lights, strobing, and rapid glitch " \
			+ "effects that may affect players with photosensitive epilepsy.\n\n" \
			+ "Reduced Flashing softens these effects well below the safety " \
			+ "threshold. You can change this at any time in settings."
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", UiFx.FONT_HEAD)
	body.add_theme_color_override("font_color", UiFx.TEXT)
	column.add_child(body)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 20)
	column.add_child(buttons)

	var reduce: Button = Button.new()
	reduce.text = "ENABLE REDUCED FLASHING"
	reduce.custom_minimum_size = Vector2(250.0, 46.0)
	buttons.add_child(reduce)

	var cont: Button = Button.new()
	cont.text = "CONTINUE"
	cont.custom_minimum_size = Vector2(250.0, 46.0)
	buttons.add_child(cont)

	# One dismissal path, both buttons acknowledge so it never re-shows; only the
	# left one also flips the switch on. Restores the menu's animation on close.
	var dismiss: Callable = func(enable: bool) -> void:
		if enable:
			A11y.set_reduced_flashing(true)
		A11y.acknowledge_warning()
		layer.queue_free()
		set_process(true)
	reduce.pressed.connect(dismiss.bind(true))
	cont.pressed.connect(dismiss.bind(false))
	reduce.grab_focus.call_deferred()


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
	# Back to front. `Margin` and `Frame` live under the safe area since PT2, so
	# they are looked up by name rather than by `$Path`.
	_parallax_layers = [%Schematic,
			find_child("Margin", true, false) as Control,
			find_child("Frame", true, false) as Control]

	var screen: SubViewportContainer = SubViewportContainer.new()
	screen.name = "Tube"
	screen.stretch = true
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_PASS
	_crt = ShaderMaterial.new()
	_crt.shader = Hud.CRT_SHADER
	_crt.set_shader_parameter("amount", UiFx.TUBE_AMOUNT)
	_crt.set_shader_parameter("curvature", MENU_CURVATURE)
	# PT2 legibility, three numbers on one line of argument: the tube is GARNISH
	# AROUND a crisp glyph, never a filter over one.
	#   gain            1.2 -> 1.34. The grille is a multiply and it is multiplying
	#                   text; the gain is what buys that contrast back.
	#   scanline        0.17 -> 0.10. The stripe now runs at content scale (see
	#                   crt.gdshader) so it lands once per letterform at every
	#                   resolution — which means it no longer needs to be strong to
	#                   be legible as a stripe, and at 0.17 it was fighting stems.
	#   phosphor_bias   0.42 -> 0.20. This pulls every pixel toward the player's
	#                   own phosphor MULTIPLIED BY ITS LUMA, so a deep-violet
	#                   marker (which is what people pick) was dragging white text
	#                   down to a fifth of its brightness. The hue still reads; the
	#                   letters keep their light.
	#   smear_pixels    one pixel, in screen pixels rather than a fraction of the
	#                   screen width. THIS was the reported double-strike.
	_crt.set_shader_parameter("gain", 1.34)
	_crt.set_shader_parameter("phosphor_bias", 0.20)
	_crt.set_shader_parameter("smear_pixels", 1.0)
	_crt.set_shader_parameter("scanline_strength", 0.10)
	# PT2: the tube's own edge falloff follows the player's VIGNETTE slider too.
	# It is a second vignette stacked on the post grade's, and the two of them
	# together are what made a panel 22 px inside the frame unreadable. 0.34 stays
	# the authored maximum; the default multiplier lands it near 0.19.
	_crt.set_shader_parameter("vignette", 0.34 * Screen.vignette)
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
	#
	# PT2 exempts the two AMBIENT layers, and the reason is the tube-safe rule's
	# other half: dressing is full-bleed.
	#
	#   Backdrop  — it is the only thing painting the region OUTSIDE the glass.
	#               Inside the tube it was masked away with everything else, and
	#               what showed through instead was the viewport's clear colour: a
	#               flat grey surround around the picture. The shipped vignette of
	#               1.05 was hiding it, which is one more thing the vignette was
	#               doing that a vignette should not be doing — turn the slider
	#               down and a grey border appears.
	#   Schematic — MOTHER's documentation drifting past. It is texture, it carries
	#               no information, and on a 32:9 panel it is what fills the 1280 px
	#               of canvas either side of the console so the extra width reads as
	#               a dark room the console is standing in rather than as padding.
	#               Reads as the wall behind the monitor, which is what it is.
	for child: Node in get_children():
		if child == screen or child == _post:
			continue
		if child.name == &"Backdrop" or child.name == &"Schematic":
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
			_ip_edit, _port_edit, _host_button, _join_button,
			_settings_button, _quit_button]:
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
	_band_note.add_theme_font_size_override("font_size", UiFx.FONT_SMALL)
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
	# PT2 — CONTRAST. This loop was the single biggest reason the menu came back
	# from the playtest as "horrible to read", and it was invisible in the scene
	# file: the .tscn's authored colours are correct, and then this ran at boot and
	# wrote DIM over the top of them. DIM is `base.v * 0.52` — a RULE colour, the
	# thing tick marks and un-said captions are drawn in — and every button label
	# and every field label in the menu was being painted with it, then multiplied
	# again by a scanline grille, a phosphor bias and two vignettes.
	#
	# The phosphor identity does not require dim letters. It comes from the tube:
	# the curvature, the grille, the roll bar, the panel dressing. Alien:
	# Isolation's terminals are aggressively readable and lose nothing by it. So
	# body text reads TEXT, secondary text reads CAPTION (the new token), and DIM
	# goes back to drawing rules.
	for entry: Array in [["Button", "font_color", UiFx.TEXT],
			["Button", "font_focus_color", UiFx.SYSTEM_HOT],
			["Button", "font_hover_color", Color(1.0, 1.0, 1.0)],
			["Label", "font_color", UiFx.TEXT],
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

## Narrow enough to sit clear of the injection console inside the tube-safe box,
## wide enough for "PROCESSES DELETED 9999" at the PT2 type sizes.
const PROGRAM_WIDTH: float = 268.0
## Air above and below the panel's rows. The panel's HEIGHT is this plus whatever
## the rows need — see `_fit_program_height`. It used to be a hard 396.
const PROGRAM_PADDING: float = 14.0
## Air between the console and the panel.
const PROGRAM_GAP: float = 22.0
## The console's own minimum width (`Console.custom_minimum_size.x` in the scene),
## plus the MarginContainer's left and right margins. The fit test below compares
## the tube-safe box against this plus the panel.
const CONSOLE_FOOTPRINT: float = 560.0
const COLUMN_MARGINS: float = 128.0

## Kept so `_place_program_panel` can re-solve it on every viewport change.
var _program_panel: Control = null
## The panel's row list. Its combined minimum height IS the panel's height.
var _program_fields: VBoxContainer = null

# ## The PT2 bug, and what replaced it
#
# This panel WAS the "ghost column at the right edge". It read:
#
#     panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
#     panel.position = Vector2(-PROGRAM_WIDTH - 22.0, -186.0)
#
# which is the anchor-then-position antipattern in its pure form. The preset puts
# all four anchors on the canvas's right edge; `position` then writes a pixel
# OFFSET from that edge. Nothing is wrong with the arithmetic — it lands 22 px
# inside the right edge of the canvas, exactly as intended. The two things wrong
# with it are everything the arithmetic does not know about:
#
#   1. **22 px inside the canvas is off the glass.** The tube's barrel warp plus
#      its bezel falloff plus two vignettes eat something like the outer 10% of
#      the frame, so the panel was rendered into a region that has no picture.
#      What survived was its left third — "YOUR PROGR", "ARCHIV", "DEEPES" — which
#      is precisely the truncated-ghost artefact the player reported.
#   2. **The canvas's right edge is not where the author thought.** At 21:9 it is
#      1720 px from the left instead of 1280, at 32:9 it is 2560. The panel dutifully
#      followed it out into the dark, 700 px away from the console it belongs beside,
#      and at those aspects it is not a ghost any more — it is simply gone.
#
# The replacement stops free-floating the panel at all. It goes into an
# HBoxContainer beside the console, inside the centred column, inside the
# tube-safe box — so a LAYOUT decides where it is, and a layout cannot put it
# 700 px away from the thing it belongs to or 22 px inside an edge that is not
# there. The composition also improves: console and program read as one instrument
# with two halves, centred together, instead of a console with something drifting
# off its starboard side.
#
# What survives from the old code is the one thing worth keeping — a fixed width —
# plus a new refusal: the panel HIDES ITSELF when the safe box cannot hold both it
# and the console. A high UI scale or a 4:3 monitor shrinks the box until they
# would collide, and the old code would have collided them, which is the other
# half of "looks layered multiple times". Hiding is honest: this readout is a
# convenience, and the same numbers are on the Compiler two minutes into any run.
func _build_program_panel() -> void:
	var console: Control = find_child("Console", true, false) as Control
	if console == null:
		return
	var console_column: Node = console.get_parent()

	var console_row: HBoxContainer = HBoxContainer.new()
	console_row.name = "ConsoleRow"
	console_row.alignment = BoxContainer.ALIGNMENT_CENTER
	console_row.add_theme_constant_override("separation", int(PROGRAM_GAP))
	console_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	console_column.add_child(console_row)
	console_column.move_child(console_row, console.get_index())
	# SHRINK_CENTER so the row is exactly as wide as its contents and stays
	# centred in the column, the way the console alone used to be.
	console_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	console.reparent(console_row, false)

	var panel: Control = Control.new()
	panel.name = "ProgramPanel"
	# Height DERIVED from the rows it holds (`_fit_program_height`), not declared.
	# A hard 396 here was the last 16 px of the PT2 menu clip and the reason
	# tightening the console bought nothing: the panel shares an HBox with it, so a
	# fixed height on the panel is a floor under the WHOLE ROW, and every row the
	# console gave back the panel took straight out again.
	panel.custom_minimum_size = Vector2(PROGRAM_WIDTH, 0.0)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_program_panel = panel
	console_row.add_child(panel)
	_place_program_panel()

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
	# Named so the density pass can find it: this list is 13 rows of readout and it
	# tightens with the rest of the menu rather than being the one block that does
	# not and therefore sets the floor for everything else.
	column.name = "ProgramFields"
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.offset_left = 18.0
	column.offset_right = -14.0
	column.offset_top = PROGRAM_PADDING
	column.add_theme_constant_override("separation", 3)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(column)
	_program_fields = column
	# The panel's rows are now in the density set; re-sample, then fit again.
	#
	# The second call is not belt-and-braces. `_fit_safe_area` drives the density,
	# and after boot it only runs on `size_changed` — so a session launched AT the
	# project's own 1280x720 never resizes its window, never re-fits, and keeps the
	# tier chosen before this panel existed. That is exactly the split the matrix
	# caught: 1280x720 and 2560x1440 both compute a 1280x720 canvas and an
	# identical 1088x612 safe box, and only the one that had to resize came back
	# clean. Queued in order — capture, then fit.
	_capture_authored_density.call_deferred()
	_refit_density.call_deferred()

	_program_line(column, "YOUR PROGRAM", UiFx.FONT_HEAD, UiFx.SYSTEM)
	_program_line(column, "COMPILED  ·  SURVIVES DELETION", UiFx.FONT_SMALL, UiFx.CAPTION)
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
		_program_cell(row, Modules.glyph(track), UiFx.FONT_BODY, lit, 22.0)
		_program_cell(row, Modules.display_name(track), UiFx.FONT_SMALL,
				UiFx.TEXT if tier > 0 else UiFx.CAPTION, 120.0)
		var pips: String = ""
		for t: int in total:
			pips += "●" if t < tier else "○"
		_program_cell(row, pips, UiFx.FONT_BODY, lit, 0.0)

	column.add_child(_program_rule())
	_program_line(column, "ARCHIVE           %d DATA" % GameState.archive, UiFx.FONT_BODY, UiFx.TEXT)
	_program_line(column, "DEEPEST BACKDOOR  %s" % (
			"NONE" if GameState.deepest_backdoor <= 0
			else "LAYER %02d" % GameState.deepest_backdoor), UiFx.FONT_BODY, UiFx.TEXT)
	column.add_child(_program_rule())
	_program_line(column, "INTRUSIONS        %d" % GameState.stat("runs"), UiFx.FONT_SMALL, UiFx.CAPTION)
	_program_line(column, "EXFILTRATIONS     %d" % GameState.stat("exfils"), UiFx.FONT_SMALL, UiFx.CAPTION)
	_program_line(column, "PROCESSES DELETED %d" % GameState.stat("deletions"), UiFx.FONT_SMALL, UiFx.CAPTION)
	_program_line(column, "DATA BANKED       %d" % GameState.stat("data_banked"), UiFx.FONT_SMALL, UiFx.CAPTION)

	# Rewriting somebody's save file is a thing to admit to, once, plainly.
	if GameState.migrated_from > 0:
		column.add_child(_program_rule())
		_program_line(column, "PROGRAM FILE MIGRATED v%d → v%d" % [
			GameState.migrated_from, GameState.SAVE_VERSION], UiFx.FONT_SMALL, UiFx.WARNING)
		_program_line(column, "BACKUP: user://save.json.bak", UiFx.FONT_SMALL, UiFx.CAPTION)


## The one thing the container cannot decide for itself: whether there is room.
##
## Re-run on every viewport change (`_fit_safe_area`), which covers window
## resizes, monitor changes and the UI-scale slider — a scale change shrinks the
## 2D canvas, so it arrives here as a resize like any other.
func _place_program_panel() -> void:
	if _program_panel == null or not is_instance_valid(_program_panel):
		return
	var box: float = get_viewport_rect().size.x if Debug.no_safe_area \
			else UiFx.tube_safe_rect(get_viewport_rect().size).size.x
	var needed: float = COLUMN_MARGINS + CONSOLE_FOOTPRINT + PROGRAM_GAP + PROGRAM_WIDTH
	_program_panel.visible = box >= needed


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
##
## M7 (THE PARTITION) demotes it to what DESIGN.md's hub backlog calls the *thin
## fallback*. It is no longer where the decision is made — the injection selector
## standing beside the rig in the hub is, with the whole crew's roster in front of
## it (`Run.injection_choices`, `InjectionDial`). What survives here is the value
## the host walks into the Partition holding, which is worth keeping: a crew that
## always dives at their deepest backdoor should not have to re-dial it every
## session. Hence the PRESET label — it is a default, and it says so.
func _build_injection_points() -> void:
	_injection_select.clear()
	for layer: int in GameState.injection_choices():
		_injection_select.add_item("PRESET  ·  LAYER %02d%s" % [
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
		_lobby_select.add_item("NO FRIENDS RUNNING BANISH PROTOCOL")
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
