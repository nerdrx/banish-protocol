class_name Hud
extends CanvasLayer
## In-intrusion HUD: the shared Cycles ring, your integrity, the layer you are
## on, channel feedback, the crew roster, and the overlays (pause, run summary).
##
## DESIGN.md: "diegetic program-shell UI". Everything here is drawn dark, thin
## and emissive, and it only speaks when it has something to say — the channel
## ring and the shaft muster line are invisible until they are relevant. Nothing
## renders in default Godot grey; the theme is nullvoid_theme.tres throughout.
##
## The HUD is a pure observer. It reads Run (replicated state) and the local
## Player (feel state) and never writes to either.

const PING_INTERVAL: float = 0.5
const NOTICE_DURATION: float = 4.0

const COLOUR_OK: Color = Color(0.36, 0.86, 1.0)
const COLOUR_WARNING: Color = Color(1.0, 0.42, 0.36)
const COLOUR_DIM: Color = Color(0.34, 0.42, 0.5)
const COLOUR_TEXT: Color = Color(0.82, 0.92, 1.0)

## How long the ring keeps blooming after a siphon lands.
const PULSE_DECAY: float = 1.6
## How fast the "where it was" ghost arc collapses onto the real value.
const GHOST_DECAY: float = 0.55

@onready var _crew_list: VBoxContainer = %CrewList
@onready var _link_label: Label = %LinkLabel
@onready var _notice_label: Label = %NoticeLabel
@onready var _pause: Control = %PauseOverlay
@onready var _resume_button: Button = %ResumeButton
@onready var _leave_button: Button = %LeaveButton
@onready var _invite_button: Button = %InviteButton

@onready var _cycles_ring: ArcMeter = %CyclesRing
@onready var _cycles_value: Label = %CyclesValue
@onready var _cycles_cap: Label = %CyclesCap
@onready var _cycles_caption: Label = %CyclesCaption
@onready var _integrity_fill: ColorRect = %IntegrityFill
@onready var _integrity_label: Label = %IntegrityLabel
@onready var _layer_label: Label = %LayerLabel
@onready var _channel_ring: ArcMeter = %ChannelRing
@onready var _prompt_label: Label = %PromptLabel

@onready var _summary: Control = %SummaryOverlay
@onready var _summary_title: Label = %SummaryTitle
@onready var _summary_body: Label = %SummaryBody
@onready var _summary_button: Button = %SummaryButton

# --- M3 ---------------------------------------------------------------------
@onready var _data_value: Label = %DataValue
@onready var _kit_label: Label = %KitLabel
@onready var _heat_fill: ColorRect = %HeatFill
@onready var _flare_pips: HBoxContainer = %FlarePips
@onready var _alert_label: Label = %AlertLabel
@onready var _exfil_label: Label = %ExfilLabel
@onready var _damage_edges: Control = %DamageEdges

var _ping_clock: float = 0.0
var _notice_clock: float = 0.0
var _pulse: float = 0.0
var _ghost: float = 0.0
var _player: Player = null

## Directional damage: 0..1 flash weight, and the direction it came from in view
## space (x = right, y = forward).
var _damage_flash: float = 0.0
var _damage_local: Vector2 = Vector2.ZERO
var _pips: Array[ColorRect] = []


func _ready() -> void:
	Net.crew_changed.connect(_rebuild_crew)
	Net.notice.connect(_show_notice)
	Net.local_player_spawned.connect(_on_local_player)
	Run.notice.connect(_show_notice)
	Run.siphon_taken.connect(_on_siphon_taken)
	Run.layer_changed.connect(_on_layer_changed)
	# A client learns which layer it is on from the config packet, which lands
	# after the HUD is built. Without this the readout is stuck on 01 for anyone
	# who joined an intrusion that did not start at the surface.
	Run.config_changed.connect(func() -> void: _on_layer_changed(Run.layer_number))
	Run.run_ended.connect(_on_run_ended)
	Run.damaged.connect(_on_damaged)
	_resume_button.pressed.connect(_set_paused.bind(false))
	_leave_button.pressed.connect(_on_leave_pressed)
	_invite_button.pressed.connect(func() -> void: SteamHub.open_invite_overlay())
	_summary_button.pressed.connect(_on_leave_pressed)

	_pause.visible = false
	_summary.visible = false
	_notice_label.text = ""
	_channel_ring.visible = false
	_prompt_label.text = ""
	_alert_label.text = ""
	_exfil_label.text = ""
	_build_pips()
	_ghost = Run.display_fraction()
	_on_layer_changed(Run.layer_number)
	_rebuild_crew()

	# The host already has a player when the HUD loads; clients get the signal.
	var existing: Node = Net.get_player(Net.local_id())
	if existing != null:
		_player = existing as Player


func _on_local_player(player: Node) -> void:
	_player = player as Player


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _summary.visible:
			return
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

	_update_cycles(delta)
	_update_integrity()
	_update_channel()
	_update_kit()
	_update_alerts()
	_update_damage(delta)


# ------------------------------------------------------------------- cycles --

func _update_cycles(delta: float) -> void:
	var fraction: float = Run.display_fraction()
	_cycles_ring.value = fraction

	# The ghost arc trails the real value downward, so the drain reads as
	# something being consumed rather than a number quietly shrinking.
	_ghost = maxf(fraction, _ghost - GHOST_DECAY * delta)
	_cycles_ring.ghost = _ghost

	if _pulse > 0.0:
		_pulse = maxf(_pulse - delta / PULSE_DECAY, 0.0)
	_cycles_ring.glow = _pulse

	var warning: bool = fraction < Balance.CYCLES_WARNING_FRACTION
	var colour: Color = COLOUR_WARNING if warning else COLOUR_OK
	if warning and not Run.starved():
		# A slow throb below 25%: visible in peripheral vision, not a strobe.
		var beat: float = 0.72 + 0.28 * sin(float(Time.get_ticks_msec()) / 190.0)
		colour = COLOUR_WARNING * beat
		colour.a = 1.0
	_cycles_ring.fill_color = colour
	_cycles_value.add_theme_color_override("font_color", colour)
	_cycles_caption.add_theme_color_override("font_color",
			COLOUR_WARNING if warning else Color(0.36, 0.78, 1.0, 0.75))

	_cycles_value.text = "%03d" % int(ceilf(Run.cycles))
	_cycles_cap.text = "/ %d" % int(Run.cycles_max)
	_cycles_caption.text = "CYCLES DEPLETED" if Run.starved() else "SHARED CYCLES"


func _on_siphon_taken(_index: int, _pool: float) -> void:
	_pulse = 1.0


func _on_layer_changed(number: int) -> void:
	_layer_label.text = "LAYER %02d" % number


# ---------------------------------------------------------------- integrity --

func _update_integrity() -> void:
	var value: float = Run.local_integrity()
	var fraction: float = clampf(value / Balance.INTEGRITY_MAX, 0.0, 1.0)
	var full: float = float(_integrity_fill.get_parent_control().size.x)
	_integrity_fill.size.x = full * fraction

	var colour: Color = COLOUR_OK
	if fraction <= 0.0:
		colour = COLOUR_WARNING
	elif fraction < 0.4:
		colour = Color(1.0, 0.62, 0.26)
	_integrity_fill.color = colour

	if Run.local_corrupted():
		_integrity_label.text = "CORRUPTED"
		_integrity_label.add_theme_color_override("font_color", COLOUR_WARNING)
	elif fraction <= 0.0:
		_integrity_label.text = "DECOMPILED  ·  SPECTATING"
		_integrity_label.add_theme_color_override("font_color", COLOUR_WARNING)
	else:
		_integrity_label.text = "INTEGRITY %d%%" % int(round(fraction * 100.0))
		_integrity_label.add_theme_color_override("font_color", COLOUR_DIM)


# ------------------------------------------------------------------ channel --

## Prompt and channel ring both come off the local avatar. The muster line is the
## drop shaft's own prompt, so "CREW IN SHAFT 2/3" needs no special case here.
func _update_channel() -> void:
	if _player == null or not is_instance_valid(_player):
		_channel_ring.visible = false
		_prompt_label.text = ""
		return

	var prompt: String = _player.focus_prompt
	_prompt_label.text = prompt
	_prompt_label.add_theme_color_override("font_color",
			COLOUR_TEXT if _player.focus_available else Color(1.0, 0.62, 0.26))

	var progress: float = _player.channel_progress
	_channel_ring.visible = progress > 0.001
	_channel_ring.value = progress
	_channel_ring.glow = progress * 0.6


# ----------------------------------------------------------------------- kit --

## One pip per flare in the crew's default stock. Built once: the stock size is a
## constant until M4's Cache modules raise it, and a rebuilt row would flicker.
func _build_pips() -> void:
	for child: Node in _flare_pips.get_children():
		child.queue_free()
	_pips.clear()
	for i: int in Balance.FLARE_STOCK:
		var pip: ColorRect = ColorRect.new()
		pip.custom_minimum_size = Vector2(18.0, 8.0)
		pip.color = COLOUR_OK
		_flare_pips.add_child(pip)
		_pips.append(pip)


## Buffered data, breaker heat and flare stock — everything the local agent is
## carrying, in one corner.
func _update_kit() -> void:
	var carried: int = Run.local_buffered()
	_data_value.text = "%03d" % carried
	# The readout turns amber once the haul is heavy enough to be slowing you
	# down: the weight rule is invisible otherwise.
	var heavy: bool = carried > Balance.CARRY_FREE_SHARDS
	_data_value.add_theme_color_override("font_color",
			Color(1.0, 0.72, 0.3) if heavy else Color(0.42, 0.95, 1.0))

	var heat: float = 0.0
	var locked: bool = false
	if _player != null and is_instance_valid(_player):
		heat = _player.breaker_heat()
		locked = _player.breaker_locked()
	var track: Control = _heat_fill.get_parent_control()
	_heat_fill.size.x = float(track.size.x) * clampf(heat, 0.0, 1.0)
	_heat_fill.color = COLOUR_WARNING if locked else \
			(Color(1.0, 0.62, 0.26) if heat > 0.6 else COLOUR_OK)
	_kit_label.text = "BREAKER  ·  OVERHEATED" if locked else "BREAKER"
	_kit_label.add_theme_color_override("font_color",
			COLOUR_WARNING if locked else COLOUR_DIM)

	var stock: int = Run.flares_of(Net.local_id())
	for i: int in _pips.size():
		var lit: bool = i < stock
		_pips[i].color = Color(0.62, 0.95, 1.0) if lit else Color(0.12, 0.18, 0.24, 0.9)


# -------------------------------------------------------------------- alerts --

## Corrupted crewmates and the exfil countdown. Both are the kind of thing you
## must not be able to miss while looking at something else.
func _update_alerts() -> void:
	var down: Array[int] = Run.corrupted_crew()
	if down.is_empty():
		_alert_label.text = ""
	else:
		var lines: PackedStringArray = PackedStringArray()
		for peer: int in down:
			var seconds: int = int(ceilf(Run.corruption_left(peer)))
			if peer == Net.local_id():
				lines.append("YOU ARE CORRUPTED  ·  %ds  ·  HOLD ON" % seconds)
			else:
				lines.append("%s CORRUPTED  ·  %ds  ·  HOLD E TO RESTORE" % [
					Net.crew_name(peer), seconds])
		_alert_label.text = "\n".join(lines)
		var beat: float = 0.7 + 0.3 * sin(float(Time.get_ticks_msec()) / 140.0)
		_alert_label.modulate.a = beat

	if not Run.exfil_calling:
		_exfil_label.text = ""
		return
	var left: float = Run.exfil_remaining
	_exfil_label.text = "EXFILTRATION  %02d" % int(ceilf(left))
	# The pulse tightens as the window closes.
	var urgency: float = 1.0 - clampf(left / Balance.EXFIL_COUNTDOWN, 0.0, 1.0)
	var flash: float = 0.65 + 0.35 * absf(sin(
			float(Time.get_ticks_msec()) / (260.0 - urgency * 170.0)))
	_exfil_label.modulate.a = flash


# -------------------------------------------------------------------- damage --

func _on_damaged(from: Vector3) -> void:
	_damage_flash = 1.0
	_damage_local = Vector2.ZERO
	if _player == null or not is_instance_valid(_player):
		return
	# Project the hit into the lens's own frame, so "left" means left on screen
	# rather than left in the world.
	var to_source: Vector3 = from - _player.global_position
	to_source.y = 0.0
	if to_source.length_squared() < 0.01:
		return
	to_source = to_source.normalized()
	var yaw: float = _player.rotation.y
	var forward: Vector3 = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right: Vector3 = Vector3(cos(yaw), 0.0, -sin(yaw))
	_damage_local = Vector2(to_source.dot(right), to_source.dot(forward))


## Four edge bands rather than a full-screen wash: a wash tells you that you were
## hit, and the whole point is telling you *where from*.
func _update_damage(delta: float) -> void:
	if _damage_flash <= 0.0:
		return
	_damage_flash = maxf(_damage_flash - delta / Balance.DAMAGE_FLASH_TIME, 0.0)
	var strength: float = _damage_flash * _damage_flash * 0.55

	_set_edge("Top", maxf(_damage_local.y, 0.0) * strength)
	_set_edge("Bottom", maxf(-_damage_local.y, 0.0) * strength)
	_set_edge("Right", maxf(_damage_local.x, 0.0) * strength)
	_set_edge("Left", maxf(-_damage_local.x, 0.0) * strength)


func _set_edge(edge: String, alpha: float) -> void:
	var rect: ColorRect = _damage_edges.get_node_or_null(edge) as ColorRect
	if rect != null:
		rect.color.a = clampf(alpha, 0.0, 1.0)


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

	# Per-crewmate integrity: a short bar rather than a number, so the roster
	# stays scannable at a glance in the dark.
	var gauge: ColorRect = ColorRect.new()
	gauge.name = "Integrity"
	gauge.custom_minimum_size = Vector2(26.0, 3.0)
	gauge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gauge.color = COLOUR_OK
	row.add_child(gauge)

	var tag: Label = Label.new()
	tag.name = "Latency"
	tag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tag.add_theme_font_size_override("font_size", 11)
	tag.add_theme_color_override("font_color", COLOUR_DIM)
	tag.text = "HOST" if id == 1 else ""
	row.add_child(tag)
	row.set_meta("peer_id", id)
	return row


func _refresh_link() -> void:
	for row: Node in _crew_list.get_children():
		if not row.has_meta("peer_id"):
			continue
		var id: int = int(row.get_meta("peer_id"))

		var gauge: ColorRect = row.get_node_or_null("Integrity") as ColorRect
		if gauge != null:
			var fraction: float = clampf(
					Run.integrity_of(id) / Balance.INTEGRITY_MAX, 0.0, 1.0)
			gauge.custom_minimum_size.x = maxf(26.0 * fraction, 1.0)
			gauge.color = COLOUR_WARNING if fraction <= 0.0 else \
					(Color(1.0, 0.62, 0.26) if fraction < 0.4 else COLOUR_OK)

		var tag: Label = row.get_node_or_null("Latency") as Label
		if tag == null:
			continue
		if not Run.is_alive(id):
			tag.text = "GONE"
			tag.add_theme_color_override("font_color", COLOUR_WARNING)
		elif Run.is_corrupted(id):
			tag.text = "DOWN %ds" % int(ceilf(Run.corruption_left(id)))
			tag.add_theme_color_override("font_color", Color(1.0, 0.62, 0.26))
		elif id == 1:
			tag.text = "HOST"
		elif id == Net.local_id():
			tag.text = "YOU"
		else:
			tag.text = "%d ms" % Net.ping_ms(id)

	if not Net.is_online:
		_link_label.text = "OFFLINE"
		return

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


# ----------------------------------------------------------------- overlays --

func _set_paused(paused: bool) -> void:
	_pause.visible = paused
	# Join-in-progress is the whole point of a Steam lobby: the pause console is
	# where a host reaches the overlay's invite dialog mid-intrusion. Hidden
	# entirely on the DIRECT transport, where there is nothing to invite into.
	_invite_button.visible = paused and SteamHub.live \
			and Net.transport == Net.Transport.STEAM and SteamHub.lobby != 0
	if DisplayServer.get_name() == "headless" or Debug.automated:
		return
	Input.set_mouse_mode(
			Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED)


## The debrief, for both ways a run can end. DESIGN.md M5 will make this a proper
## screen; what it has to do now is say plainly whether the haul came home.
func _on_run_ended(summary: Dictionary) -> void:
	_pause.visible = false
	_summary.visible = true
	_exfil_label.text = ""
	_alert_label.text = ""

	var success: bool = bool(summary.get("success", false))
	_summary_title.text = "EXFILTRATION COMPLETE" if success else "INTRUSION TERMINATED"
	_summary_title.add_theme_color_override("font_color",
			Color(0.42, 0.95, 1.0) if success else COLOUR_WARNING)

	var lines: PackedStringArray = PackedStringArray([
		"REASON            %s" % String(summary.get("reason", "UNKNOWN")),
		"LAYERS REACHED    %02d" % int(summary.get("layers", 1)),
		"SIPHONS DRAINED   %d" % int(summary.get("siphons", 0)),
		"RUNTIME           %d:%02d" % [
			int(float(summary.get("seconds", 0.0))) / 60,
			int(float(summary.get("seconds", 0.0))) % 60],
		"",
	])

	# Per-player banked data: the crew reads the same table on every screen, and
	# whose buffer made it out is the whole story of the run.
	var banked: Dictionary = summary.get("banked", {}) as Dictionary
	# Who stood on the pad is a different question from who had anything to bank:
	# an agent can get out empty-handed, and that is not the same as being left
	# inside with the uplink shut behind them.
	var escaped: Array = summary.get("escaped", []) as Array
	if success:
		var ids: Array = banked.keys()
		ids.sort()
		for id: int in ids:
			var peer: int = int(id)
			var amount: int = int(banked[peer])
			var fate: String = "LEFT BEHIND"
			if escaped.has(peer):
				fate = "BANKED %d DATA" % amount if amount > 0 else "OUT, EMPTY BUFFER"
			lines.append("%-14s %s" % [Net.crew_name(peer), fate])
		lines.append("")
		lines.append("ARCHIVE  %d DATA" % GameState.archive)
	else:
		lines.append("BUFFERED DATA LOST. COMPILED MODULES INTACT.")

	_summary_body.text = "\n".join(lines)
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _on_leave_pressed() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Net.leave("YOU ABORTED THE INTRUSION")
