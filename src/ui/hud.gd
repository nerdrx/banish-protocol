class_name Hud
extends CanvasLayer
## In-intrusion HUD: the shared Cycles ring, your integrity, the layer you are
## on, channel feedback, the crew roster, and the overlays (pause, run summary).
##
## DESIGN.md: "diegetic program-shell UI". M3.8 takes that literally — **the
## interface is software running on a hostile machine**, and it behaves like it:
##
##   * it **compiles in** when your process is injected (`_update_boot`), element
##     by element, with a one-line self-test that fades;
##   * it hangs a few pixels behind the lens on a spring (`_update_parallax`) and
##     wears a faint scanline sheen, so it reads as projected in front of you
##     rather than painted on the glass;
##   * it **flinches** when you are hit (`_update_glitch`) — clusters jump a
##     pixel or two, the big readouts split chromatically, and your own callsign
##     corrupts for a fifth of a second;
##   * it **decays** as the shared pool empties (`_update_degradation`) — dead
##     pixels in the readouts, labels that flicker, the occasional scanline tear.
##
## None of that is gameplay. The HUD is still a pure observer: it reads Run
## (replicated state) and the local Player (feel state) and never writes to
## either. Every animation runs off `UiFx.clock()`, which is wall time for a
## player and frame count for a capture, so screenshots are reproducible.
##
## Two Control layers, and the split matters. `Root` holds the readouts and takes
## the parallax lag. `Fixed` holds the crosshair, the channel ring, the damage
## arc and the overlays — everything that is either an aiming reference or
## pinned to the frame edge, and must therefore never move.

const PING_INTERVAL: float = 0.5
const NOTICE_DURATION: float = 4.0

## Local aliases for the palette. Members rather than constants since M4.7: the
## nominal phosphor is the player's own colour and is not known until the program
## file has loaded, so it cannot be baked into a `const` at parse time. The three
## that CAN still be constant are left as reads of the constants they alias, so
## nothing here can accidentally become re-tintable later.
@onready var COLOUR_OK: Color = UiFx.SYSTEM
@onready var COLOUR_WARNING: Color = UiFx.HOSTILE
@onready var COLOUR_AMBER: Color = UiFx.WARNING
@onready var COLOUR_DIM: Color = UiFx.DIM
@onready var COLOUR_TEXT: Color = UiFx.TEXT

## Width the flare-pip row has to live inside, and the gap between pips. A maxed
## Cache carries eight flares; at the M3 pip width that row would have run out of
## the kit cluster and across the buffered-data readout, so the pips are sized to
## the capacity rather than the capacity being sized to the pips.
const PIP_TRACK: float = 92.0
const PIP_GAP: float = 3.0

## How long the ring keeps blooming after a siphon lands.
const PULSE_DECAY: float = 1.6
## How fast the "where it was" ghost arc collapses onto the real value.
const GHOST_DECAY: float = 0.55
## Pixels of HUD lag per radian/second of head turn, before clamping.
const PARALLAX_GAIN: float = 1.8

const SHEEN_SHADER: Shader = preload("res://src/ui/hud_sheen.gdshader")
const CRT_SHADER: Shader = preload("res://src/ui/crt.gdshader")

@onready var _root: Control = $Root

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
@onready var _crosshair: ColorRect = %Crosshair
@onready var _boot_line: Label = %BootLine

@onready var _summary: Control = %SummaryOverlay
@onready var _summary_title: Label = %SummaryTitle
@onready var _summary_body: Label = %SummaryBody
@onready var _summary_button: Button = %SummaryButton
@onready var _banked_caption: Label = %BankedCaption
@onready var _banked_value: Label = %BankedValue

# --- M3 ---------------------------------------------------------------------
@onready var _data_value: Label = %DataValue
@onready var _kit_label: Label = %KitLabel
@onready var _heat_fill: ColorRect = %HeatFill
@onready var _flare_pips: HBoxContainer = %FlarePips
@onready var _alert_label: Label = %AlertLabel
@onready var _exfil_label: Label = %ExfilLabel
@onready var _damage_arc: DamageArc = %DamageArc

# --- M3.8 -------------------------------------------------------------------
@onready var _specks: HudSpecks = %Specks
@onready var _crew_cluster: Control = %CrewCluster
@onready var _cycles_panel: Control = %CyclesPanel
@onready var _kit_panel: Control = %KitPanel
@onready var _integrity_panel: Control = %IntegrityPanel
@onready var _data_panel: Control = %DataPanel

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
## Capacity the current pip widths were computed for.
var _pip_capacity: int = -1

# --- boot -------------------------------------------------------------------
## Seconds since the shell started compiling. A frozen value is how
## `--hud-state boot` photographs the sequence mid-compile.
var _boot_clock: float = 0.0
var _booting: bool = true
## Parallel arrays rather than an array of dictionaries: this is walked every
## frame of the boot and must not allocate.
var _boot_nodes: Array[CanvasItem] = []
var _boot_starts: PackedFloat32Array = PackedFloat32Array()

# --- glitch / degradation ---------------------------------------------------
var _glitch: float = 0.0
var _degrade: float = -1.0
## Clusters that jump when the shell is hit, and their laid-out home positions.
var _clusters: Array[Control] = []
var _cluster_home: PackedVector2Array = PackedVector2Array()
## Chromatic split ghosts for the two big readouts.
var _cycles_ghosts: Array[Label] = []
var _data_ghosts: Array[Label] = []
## The local crewmate's roster label, and the name it is supposed to read.
var _self_label: Label = null
var _self_name: String = ""
var _glyph_tick: int = -1
## Labels that flicker as the interface degrades.
var _flicker_labels: Array[Label] = []

# --- the tube ---------------------------------------------------------------
## The interface's own viewport, the container compositing it back, and the
## full-rect fader that gives the phosphor its decay. See `_build_tube`.
var _tube: SubViewport = null
var _screen: SubViewportContainer = null
var _crt: ShaderMaterial = null
var _fixed: Control = null
## 0..1 how far the tube has warmed up. Cold on injection.
var _warmup: float = 0.0

# --- crosshair --------------------------------------------------------------
var _reticle: Crosshair = null
## Phosphor decay weights for the two big readouts, and the values they were
## last showing.
var _ghost_cycles: float = 0.0
var _ghost_data: float = 0.0
var _last_cycles_text: String = ""
var _last_data_text: String = ""
var _focus_open: float = 0.0
var _hit_tick: float = 0.0
var _kill_burst: float = 0.0

# --- holographic depth ------------------------------------------------------
var _parallax: Vector2 = Vector2.ZERO
var _parallax_velocity: Vector2 = Vector2.ZERO
var _last_yaw: float = 0.0
var _last_pitch: float = 0.0
var _sheens: Array[ShaderMaterial] = []

# --- living ring ------------------------------------------------------------
## Sprint bleed weight, and the damped overshoot after a siphon lands.
var _ember: float = 0.0
var _surge_clock: float = -1.0

# --- injection gate (M4) ----------------------------------------------------
## Seconds the gate panel stays up after the last refusal. Negative = hidden.
var _gate_clock: float = -1.0
var _gate_panel: Control = null
var _gate_body: Label = null
var _gate_title: Label = null

# --- debrief ----------------------------------------------------------------
var _debrief_clock: float = -1.0
var _debrief_lines: int = 0
var _banked_from: int = 0
var _banked_to: int = 0


func _ready() -> void:
	Net.crew_changed.connect(_rebuild_crew)
	Net.injection_gate.connect(_show_gate)
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
	_boot_line.text = ""
	_build_pips()
	_ghost = Run.display_fraction()
	_on_layer_changed(Run.layer_number)
	_rebuild_crew()

	_build_tube()
	_install_depth()
	_install_glitch_rig()
	_build_crosshair()
	_build_gate_panel()
	_begin_boot()
	Run.local_shot.connect(_on_local_shot)

	# The host already has a player when the HUD loads; clients get the signal.
	var existing: Node = Net.get_player(Net.local_id())
	if existing != null:
		_player = existing as Player


func _on_local_player(player: Node) -> void:
	_player = player as Player
	if _player != null:
		_last_yaw = _player.rotation.y
		_last_pitch = float(_player.sync_pitch)


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

	_update_gate(delta)
	_update_boot(delta)
	_update_degradation()
	_update_glitch(delta)
	_update_crosshair(delta)
	_update_parallax(delta)
	_update_debrief(delta)
	_update_tube(delta)


# ---------------------------------------------------------------------- tube --

## Puts the whole interface inside a CRT.
##
## The rig is three nodes and it is worth understanding why each one is there,
## because the obvious alternative — a full-screen shader laid over everything —
## is wrong for a reason that is art direction rather than engineering: it would
## put scanlines on MOTHER's architecture. The entire premise (see
## `crt.gdshader`) is that your instrument is old human hardware and her world is
## not. The two cannot share a tube.
##
##   `_screen`   a SubViewportContainer wearing crt.gdshader. This is the glass:
##               it samples the interface and applies curvature, grille, roll and
##               the analog faults. Input passes straight through it into the
##               viewport, so the pause console's buttons still work.
##   `_tube`     the SubViewport the interface actually renders into.
##
## ## Phosphor persistence, and the version of it that did not ship
##
## The elegant implementation is a framebuffer that is never cleared, with a
## full-rect multiply drawn first to decay it — one rect, no fetches, and *every*
## element on the interface gets correct temporal decay for free, including ones
## nobody has written yet. It is implemented (crt_persist.gdshader) and it is not
## switched on, because in a real interface it is a trap.
##
## Feedback of that kind is only stable for elements that are opaque or absent.
## Anything drawn at partial alpha every frame **accumulates**: a cluster plate at
## 0.35 alpha with 0.81-per-frame survival settles at 0.74 and reads as a solid
## black box; every additive sheen saturates to white over about a second. The
## first capture of this rig had four black slabs where the readouts should have
## been. Fixing that means stripping the translucency out of the entire HUD to
## suit an effect, which is the tail wagging the dog.
##
## So the decay is bounded instead, and applied where it actually reads: the
## shader smears each lit dot sideways (spatial persistence, always on), and a
## readout that CHANGES leaves a ghost of its previous value for a few frames
## (`_update_phosphor`). Those are the two cases a player can see. A gauge head
## trailing by two pixels is not one of them, and it is not worth the interface
## it would cost.
##
## `Root` and `Fixed` are reparented in rather than being moved in the scene
## file. Every `@onready` and every `%UniqueName` in this class has already
## resolved by the time this runs, and unique names are registered against the
## scene's owner rather than against a parent, so both keep working afterwards.
## Doing it here also means the .tscn stays a plain description of the layout and
## the CRT stays one idea in one place.
func _build_tube() -> void:
	_fixed = $Fixed

	_screen = SubViewportContainer.new()
	_screen.name = "Screen"
	_screen.stretch = true
	_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	# PASS, not IGNORE: the container has to be hit-testable for input to reach
	# the viewport behind it, but must not swallow anything itself.
	_screen.mouse_filter = Control.MOUSE_FILTER_PASS
	_crt = ShaderMaterial.new()
	_crt.shader = CRT_SHADER
	_crt.set_shader_parameter("amount", UiFx.TUBE_AMOUNT)
	# The grille costs real contrast — it is a multiply, and it is multiplying
	# text that was already authored dim. The gain buys that back so the tube is
	# a texture over the readouts rather than a filter dimming them.
	_crt.set_shader_parameter("gain", 1.28)
	_crt.set_shader_parameter("scanline_strength", 0.16)
	_crt.set_shader_parameter("vignette", 0.26)
	_crt.set_shader_parameter("phosphor", Vector3(
			UiFx.SYSTEM.r, UiFx.SYSTEM.g * 1.05, UiFx.SYSTEM.b * 1.3))
	_screen.material = _crt
	add_child(_screen)

	_tube = SubViewport.new()
	_tube.name = "Tube"
	_tube.transparent_bg = true
	_tube.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_tube.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# The interface is 2D. Handing it its own 3D world would make it allocate one.
	_tube.own_world_3d = false
	_tube.gui_disable_input = false
	_screen.add_child(_tube)

	# `reparent`, not remove_child + add_child. The latter clears `owner`, and the
	# scene's `%UniqueName` registry is keyed on owner — so every `%CyclesRing` in
	# this file would resolve to null the moment the interface moved into the
	# tube. That failure is silent until the first frame that touches one.
	for panel: Control in [$Root, _fixed]:
		panel.reparent(_tube, false)

	# Automation photographs a warm tube. The degauss wobble is a boot animation
	# like any other, and a capture armed for frame N must not depend on whether
	# the coil had settled — `--hud-state boot` is the deliberate exception.
	_warmup = 0.0 if Debug.hud_state == "boot" else 1.0


## Drives the glass. Everything here is a state the rest of the HUD has already
## computed; the tube is a pure consumer, exactly like the HUD is of Run.
func _update_tube(delta: float) -> void:
	if _crt == null:
		return
	if _warmup < 1.0:
		_warmup = minf(_warmup + delta / maxf(UiFx.TUBE_WARMUP, 0.01), 1.0)
	_crt.set_shader_parameter("warmup", _warmup)
	# The damage flinch reaches the glass as a loss of horizontal hold, and the
	# draining pool reaches it as signal failure. Same two numbers the readouts
	# are already using — one fault, told twice, in two vocabularies.
	_crt.set_shader_parameter("damage", _glitch)
	_crt.set_shader_parameter("degrade", _degrade * 0.85)
	_update_phosphor(delta)


## Phosphor persistence, the half of it that reads.
##
## A CRT dot that has been struck keeps glowing after the beam moves on, so a
## readout that changes value shows the OLD value fading underneath the new one
## for a few frames. That is the artefact a player actually notices on a period
## instrument — the Cycles count dropping leaves a smear of the number it used to
## be — and it is the one worth spending anything on.
##
## Implemented on the ghost labels the flinch already owns, because they are
## already there, already positioned and already free when nothing is happening.
## A readout that has not changed costs one string comparison.
func _update_phosphor(delta: float) -> void:
	_ghost_cycles = maxf(_ghost_cycles - delta / UiFx.PHOSPHOR_HALFLIFE * 0.5, 0.0)
	_ghost_data = maxf(_ghost_data - delta / UiFx.PHOSPHOR_HALFLIFE * 0.5, 0.0)
	# The ghost has to hold the value the readout USED to show, so it is written
	# from the cached string a frame before that cache is updated. A ghost showing
	# the new number is just a blurry copy of the new number.
	if _cycles_value.text != _last_cycles_text:
		_arm_ghost(_cycles_ghosts, _cycles_value, _last_cycles_text)
		_last_cycles_text = _cycles_value.text
		_ghost_cycles = 1.0
	if _data_value.text != _last_data_text:
		_arm_ghost(_data_ghosts, _data_value, _last_data_text)
		_last_data_text = _data_value.text
		_ghost_data = 1.0
	# Nothing to do while a flinch owns the ghosts: a hold slip and a value change
	# landing on the same frame would fight over the same two labels, and the
	# flinch is the louder event.
	if _glitch > 0.001:
		return
	_phosphor_ghost(_cycles_ghosts, _ghost_cycles)
	_phosphor_ghost(_data_ghosts, _ghost_data)


func _arm_ghost(ghosts: Array[Label], source: Label, previous: String) -> void:
	for ghost: Label in ghosts:
		ghost.text = previous
		ghost.position = source.position


func _phosphor_ghost(ghosts: Array[Label], weight: float) -> void:
	for i: int in ghosts.size():
		# Left where they were, at the value they were showing — the ghost is the
		# OLD reading, so it must not be re-texted while it is decaying.
		ghosts[i].modulate.a = weight * (0.5 if i == 0 else 0.22)


# --------------------------------------------------------------- crosshair --

func _build_crosshair() -> void:
	# The M2 ColorRect stays in the scene as the layout anchor and stops being
	# drawn: everything the reticle does now is drawn by Crosshair, and a stray
	# 2x2 white square underneath it would be the one element on the interface
	# that never picked up a state.
	_crosshair.color = Color(0.0, 0.0, 0.0, 0.0)
	_reticle = Crosshair.new()
	_reticle.name = "Reticle"
	_reticle.set_anchors_preset(Control.PRESET_FULL_RECT)
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fixed.add_child(_reticle)
	_boot_nodes.append(_reticle)


## Local-only, and predicted rather than authoritative — the same standing as the
## beam-lash the shooter draws a round trip before the host agrees with it. See
## `Player._update_breaker`.
func _on_local_shot(did_hit: bool, killed: bool) -> void:
	if killed:
		_kill_burst = 1.0
	if did_hit or killed:
		_hit_tick = 1.0


func _update_crosshair(delta: float) -> void:
	if _reticle == null:
		return
	var want: float = 0.0
	var heat: float = 0.0
	var locked: bool = false
	if _player != null and is_instance_valid(_player):
		want = 1.0 if _player.focus_available and not _player.focus_prompt.is_empty() \
				else 0.0
		locked = _player.breaker_locked()
		# Only the top of the heat band reaches the reticle. Warning a player at
		# 30% heat is warning them constantly, and a warning that is always on is
		# not a warning.
		heat = clampf(inverse_lerp(UiFx.CROSS_HEAT_FRACTION, 1.0,
				_player.breaker_heat()), 0.0, 1.0)
	_focus_open = UiFx.chase(_focus_open, want, UiFx.CROSS_OPEN_RATE, delta)

	_reticle.focus = _focus_open
	_reticle.heat = 1.0 if locked else heat
	_reticle.locked = locked
	_hit_tick = maxf(_hit_tick - delta / UiFx.HIT_TICK_TIME, 0.0)
	_kill_burst = maxf(_kill_burst - delta / UiFx.KILL_BURST_TIME, 0.0)
	_reticle.hit = _hit_tick
	_reticle.kill = _kill_burst


# --------------------------------------------------------------------- boot --

## Assembles the compile order. Elements resolve from the structural to the
## specific — the crew first, then the pool that crew is spending, then what it
## is carrying — because that is the order a program shell would bring its own
## readouts up in, and it happens to scan left-to-right as well.
func _begin_boot() -> void:
	_add_boot(_crosshair, 0.05)
	_add_boot(_crew_cluster, 0.10)
	_add_boot(_cycles_panel, 0.22)
	_add_boot(_integrity_panel, 0.36)
	_add_boot(_kit_panel, 0.46)
	_add_boot(_data_panel, 0.56)
	_add_boot(_layer_label, 0.66)
	_add_boot(_link_label, 0.74)

	_boot_line.text = "INSTANCE 0x%04X  ·  RUNTIME OK" % _instance_hash()
	_boot_line.visible_ratio = 0.0

	# Automation never waits on the shell compiling: a capture armed for frame N
	# must photograph the HUD settled, and a soak must not spend a second of
	# every layer looking at a boot animation. `--hud-state boot` is the
	# deliberate exception — and it *freezes* the sequence rather than playing
	# it, so the mid-compile frame is the same frame every time.
	if Debug.hud_state == "boot":
		_boot_clock = UiFx.BOOT_DURATION * Debug.hud_boot_phase
		_apply_boot()
		return
	if Debug.automated:
		_finish_boot()


func _add_boot(node: CanvasItem, start: float) -> void:
	_boot_nodes.append(node)
	_boot_starts.append(start)
	node.modulate.a = 0.0


func _update_boot(delta: float) -> void:
	if not _booting:
		return
	if Debug.hud_state == "boot":
		return  # frozen mid-compile for the capture.

	_boot_clock += delta
	_apply_boot()
	if _boot_clock > UiFx.BOOT_DURATION + UiFx.BOOT_SELFTEST_HOLD + UiFx.BOOT_SELFTEST_FADE:
		_finish_boot()


func _apply_boot() -> void:
	for i: int in _boot_nodes.size():
		_boot_nodes[i].modulate.a = _boot_alpha(_boot_starts[i], i)

	# The ring spins up from zero and overshoots a hair before settling, which is
	# a gauge finding its reading rather than a bar being drawn.
	var spin: float = clampf(
			(_boot_clock - _boot_starts[2]) / UiFx.BOOT_RING_TIME, 0.0, 1.0)
	var eased: float = 1.0 - pow(1.0 - spin, 3.0)
	if spin < 1.0:
		eased += sin(spin * PI) * UiFx.BOOT_RING_OVERSHOOT
	_cycles_ring.value = Run.display_fraction() * clampf(eased, 0.0, 1.0)

	_update_boot_line()


## One element resolving: a hard flicker for the first fraction of a second, then
## a clean ramp. The flicker is hashed on the element index so no two come up in
## the same rhythm.
func _boot_alpha(start: float, index: int) -> float:
	var local: float = _boot_clock - start
	if local <= 0.0:
		return 0.0
	if local >= UiFx.BOOT_ELEMENT_FADE:
		return 1.0
	var ramp: float = local / UiFx.BOOT_ELEMENT_FADE
	var strobe: float = UiFx.hash01(floor(_boot_clock * 42.0) + float(index) * 5.0)
	return ramp * (0.18 if strobe < 0.4 else 1.0)


func _update_boot_line() -> void:
	var typed: float = clampf(
			(_boot_clock - 0.18) * UiFx.BOOT_TYPE_SPEED / float(maxi(
					_boot_line.text.length(), 1)), 0.0, 1.0)
	_boot_line.visible_ratio = typed
	var held: float = _boot_clock - UiFx.BOOT_DURATION - UiFx.BOOT_SELFTEST_HOLD
	_boot_line.modulate.a = 1.0 if held <= 0.0 \
			else clampf(1.0 - held / UiFx.BOOT_SELFTEST_FADE, 0.0, 1.0)


func _finish_boot() -> void:
	_booting = false
	for node: CanvasItem in _boot_nodes:
		node.modulate.a = 1.0
	_boot_line.text = ""
	_boot_line.modulate.a = 0.0


## Short identity for the self-test line. Deterministic from the peer id and the
## callsign, so an automated run prints the same instance every time and the two
## peers in a two-client capture print different ones.
func _instance_hash() -> int:
	return hash("%s#%d" % [GameState.local_name, Net.local_id()]) & 0xFFFF


# ------------------------------------------------------------------- cycles --

func _update_cycles(delta: float) -> void:
	var fraction: float = Run.display_fraction()

	# Sprinting bills the pool at 2.5x (Balance.SPRINT_DRAIN_MULT). The ember is
	# that surcharge made visible — read off the same speed the host bills from,
	# not off a separate input bit, so what you see is what you are paying.
	var sprinting: bool = _player != null and is_instance_valid(_player) \
			and float(_player.sync_speed) >= Balance.SPRINT_BILLING_SPEED
	_ember = 1.0 if sprinting else maxf(_ember - delta / UiFx.RING_EMBER_DECAY, 0.0)
	_cycles_ring.ember = _ember

	# A siphon landing overshoots and settles rather than stepping up: seventy
	# Cycles arriving at once should feel like a surge through the gauge.
	var surge: float = 0.0
	if _surge_clock >= 0.0:
		_surge_clock += delta
		if _surge_clock > UiFx.RING_SURGE_TIME:
			_surge_clock = -1.0
		else:
			var u: float = _surge_clock / UiFx.RING_SURGE_TIME
			surge = UiFx.RING_SURGE_OVERSHOOT * exp(-u * 5.0) * cos(u * 9.0)

	if not _booting:
		_cycles_ring.value = fraction + surge

	# The ghost arc trails the real value downward, so the drain reads as
	# something being consumed rather than a number quietly shrinking.
	_ghost = maxf(fraction, _ghost - GHOST_DECAY * delta)
	_cycles_ring.ghost = _ghost

	if _pulse > 0.0:
		_pulse = maxf(_pulse - delta / PULSE_DECAY, 0.0)
	_cycles_ring.glow = _pulse

	# Three bands, not two. Amber at half a pool is the "stop wandering" signal
	# the crew argues over; red below a quarter is the emergency, and only the
	# emergency gets a heartbeat.
	var alarm: bool = fraction < Balance.CYCLES_WARNING_FRACTION
	var colour: Color = COLOUR_OK
	if alarm:
		colour = COLOUR_WARNING
	elif fraction < UiFx.RING_AMBER_FRACTION:
		# Gamma'd rather than linear. A straight lerp from ice-blue to amber runs
		# through a pale desaturated grey at the halfway point, and a gauge that
		# goes *washed out* on its way to a warning reads as broken rather than
		# as concerned. Curving it keeps the ring on-palette until the tint has
		# something to say, then commits.
		var tint: float = clampf(inverse_lerp(
				UiFx.RING_AMBER_FRACTION, Balance.CYCLES_WARNING_FRACTION,
				fraction), 0.0, 1.0)
		colour = COLOUR_OK.lerp(COLOUR_AMBER, pow(tint, UiFx.RING_AMBER_GAMMA))

	var beat: float = 0.0
	if alarm and not Run.starved():
		beat = UiFx.heartbeat(UiFx.clock(), UiFx.RING_BEAT_PERIOD)
		colour = COLOUR_WARNING * (0.74 + 0.26 * beat)
		colour.a = 1.0
	_cycles_ring.beat = beat

	_cycles_ring.fill_color = colour
	_cycles_value.add_theme_color_override("font_color", colour)
	_cycles_caption.add_theme_color_override("font_color",
			COLOUR_WARNING if alarm else Color(UiFx.SYSTEM.r, UiFx.SYSTEM.g, UiFx.SYSTEM.b, 0.72))

	_cycles_value.text = "%03d" % int(ceilf(Run.cycles))
	_cycles_cap.text = "/ %d" % int(Run.cycles_max)
	_cycles_caption.text = "CYCLES DEPLETED" if Run.starved() else "SHARED CYCLES"


func _on_siphon_taken(_index: int, _pool: float) -> void:
	_pulse = 1.0
	_surge_clock = 0.0


func _on_layer_changed(number: int) -> void:
	_layer_label.text = "LAYER %02d" % number


# ---------------------------------------------------------------- integrity --

func _update_integrity() -> void:
	var value: float = Run.local_integrity()
	# Against your OWN ceiling, which Checksum raises. A tier-5 program sitting at
	# 150 integrity is at 67%, not at "150%", and the bar has to say so.
	var fraction: float = clampf(
			value / maxf(Run.integrity_max_of(Net.local_id()), 1.0), 0.0, 1.0)
	var full: float = float(_integrity_fill.get_parent_control().size.x)
	_integrity_fill.size.x = full * fraction

	var colour: Color = COLOUR_OK
	if fraction <= 0.0:
		colour = COLOUR_WARNING
	elif fraction < 0.4:
		colour = COLOUR_AMBER
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

## The channel ring stays at the crosshair — it is aiming feedback and belongs
## where you are looking. The *text* moved out to the object it describes
## (WorldPrompt); `UiFx.SCREEN_PROMPT_FALLBACK` puts it back for anyone who needs
## a fixed place on the screen to read.
func _update_channel() -> void:
	if _player == null or not is_instance_valid(_player):
		_channel_ring.visible = false
		_prompt_label.text = ""
		return

	if UiFx.SCREEN_PROMPT_FALLBACK:
		_prompt_label.text = _player.focus_prompt
		_prompt_label.add_theme_color_override("font_color",
				COLOUR_TEXT if _player.focus_available else COLOUR_AMBER)
	elif not _prompt_label.text.is_empty():
		_prompt_label.text = ""

	var progress: float = _player.channel_progress
	_channel_ring.visible = progress > 0.001
	_channel_ring.value = progress
	_channel_ring.glow = progress * 0.6


# ----------------------------------------------------------------------- kit --

## One pip per flare the local program can hold. Built to the *ceiling* of the
## Cache track rather than to the current tier, and the pips past your own
## capacity are simply hidden: buying Cache mid-run then has to light a pip, not
## rebuild the row — and a rebuilt row would flicker in the corner of the screen
## at the exact moment the player is looking at a Compiler panel instead.
func _build_pips() -> void:
	for child: Node in _flare_pips.get_children():
		child.queue_free()
	_pips.clear()
	_flare_pips.add_theme_constant_override("separation", int(PIP_GAP))
	var ceiling: int = int(Modules.value_at("cache", "stock",
			Modules.tier_count("cache")))
	for i: int in ceiling:
		var pip: ColorRect = ColorRect.new()
		pip.custom_minimum_size = Vector2(PIP_TRACK, 8.0)
		pip.color = COLOUR_OK
		_flare_pips.add_child(pip)
		_pips.append(pip)
	_size_pips(Balance.FLARE_STOCK)


## Buffered data, breaker heat and flare stock — everything the local agent is
## carrying, in one corner.
func _update_kit() -> void:
	# What the buffer is WORTH, because that is what a Compiler spends and what an
	# exfiltration banks. The chip count is the weight, and it lives behind the
	# amber rather than on the face of the readout — "how much money am I
	# carrying" is the number the greed pillar is actually about.
	var carried: int = Run.local_buffered_value()
	_data_value.text = "%03d" % carried
	# The readout turns amber once the haul is heavy enough to be slowing you
	# down: the weight rule is invisible otherwise, and Buffer tiers move the
	# threshold, so it is read off the local loadout rather than off Balance.
	var heavy: bool = Run.local_buffered() > int(Modules.local_loadout()["carry_free"])
	_data_value.add_theme_color_override("font_color",
			COLOUR_AMBER if heavy else UiFx.SYSTEM_HOT)

	var heat: float = 0.0
	var locked: bool = false
	if _player != null and is_instance_valid(_player):
		heat = _player.breaker_heat()
		locked = _player.breaker_locked()
	var track: Control = _heat_fill.get_parent_control()
	_heat_fill.size.x = float(track.size.x) * clampf(heat, 0.0, 1.0)
	_heat_fill.color = COLOUR_WARNING if locked else \
			(COLOUR_AMBER if heat > 0.6 else COLOUR_OK)
	_kit_label.text = "BREAKER  ·  OVERHEATED" if locked else "BREAKER"
	_kit_label.add_theme_color_override("font_color",
			COLOUR_WARNING if locked else COLOUR_DIM)

	var stock: int = Run.flares_of(Net.local_id())
	var capacity: int = int(Modules.local_loadout()["flares"])
	if capacity != _pip_capacity:
		_size_pips(capacity)
	for i: int in _pips.size():
		_pips[i].visible = i < capacity
		# A pip is a lit phosphor block or an unlit one. The unlit state is not a
		# darker version of the lit colour — it is the tube with nothing on it.
		_pips[i].color = UiFx.SYSTEM_HOT if i < stock \
				else Color(0.16, 0.11, 0.05, 0.85)


# -------------------------------------------------------------------- alerts --

## Corrupted crewmates and the exfil countdown. Both are the kind of thing you
## must not be able to miss while looking at something else.
## Divides the fixed track between however many flares this program can hold.
func _size_pips(capacity: int) -> void:
	_pip_capacity = capacity
	var count: int = maxi(capacity, 1)
	var width: float = clampf(
			(PIP_TRACK - PIP_GAP * float(count - 1)) / float(count), 5.0, 18.0)
	for pip: ColorRect in _pips:
		pip.custom_minimum_size.x = width
		pip.size.x = width


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
		_alert_label.modulate.a = 0.7 + 0.3 * UiFx.heartbeat(UiFx.clock(), 0.62)

	if not Run.exfil_calling:
		_exfil_label.text = ""
		return
	var left: float = Run.exfil_remaining
	_exfil_label.text = "EXFILTRATION  %02d" % int(ceilf(left))
	# The pulse tightens as the window closes.
	var urgency: float = 1.0 - clampf(left / Balance.EXFIL_COUNTDOWN, 0.0, 1.0)
	_exfil_label.modulate.a = 0.65 + 0.35 * UiFx.heartbeat(
			UiFx.clock(), 0.72 - urgency * 0.42)


# -------------------------------------------------------------------- damage --

func _on_damaged(from: Vector3) -> void:
	_damage_flash = 1.0
	_glitch = 1.0
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


## An arc of corrupted static burnt into the frame edge facing the source. M2
## used four full-edge bands; those told you *that* you were hit, and the whole
## point is telling you where from. See DamageArc.
func _update_damage(delta: float) -> void:
	if Debug.hud_state == "damage":
		# Pinned for the capture: the flinch is a fifth of a second long and no
		# shutter is going to land inside it by luck.
		_damage_arc.direction = Vector2(0.72, 0.69)
		_damage_arc.weight = 0.85
		_glitch = 0.8
		return
	if _damage_flash <= 0.0:
		return
	_damage_flash = maxf(_damage_flash - delta / Balance.DAMAGE_FLASH_TIME, 0.0)
	_damage_arc.direction = _damage_local
	_damage_arc.weight = _damage_flash


# -------------------------------------------------------------------- glitch --

## Builds the pieces the flinch needs, once: two tinted ghost copies of each big
## readout (the chromatic split — cheaper and sharper than a per-control shader
## on a Label), and the list of clusters that jump.
func _install_glitch_rig() -> void:
	_clusters = [_crew_cluster, _cycles_panel, _integrity_panel, _kit_panel, _data_panel]
	_cluster_home.resize(_clusters.size())
	for i: int in _clusters.size():
		_cluster_home[i] = _clusters[i].position

	_cycles_ghosts = _make_ghosts(_cycles_value)
	_data_ghosts = _make_ghosts(_data_value)

	_flicker_labels = [_cycles_caption, _kit_label, _integrity_label, _cycles_cap]


## Phosphor ghosts for the big readouts.
##
## M3.8 made these a chromatic split — a red copy one way, a cyan copy the other
## — which is what a digital display does when its colour channels come apart. A
## monochrome amber tube has no channels to separate. What it does instead is
## lose horizontal hold: the same picture, in the same colour, shifted sideways,
## with the older copy dimmer because its phosphor has already started to decay.
##
## So both ghosts are now the readout's own colour and both go the SAME way, at
## different distances. That is a shear, not a fringe, and it is the difference
## between "my monitor was knocked" and "my monitor is a modern one that is
## broken in an impossible way".
func _make_ghosts(source: Label) -> Array[Label]:
	var made: Array[Label] = []
	for tint: Color in [UiFx.SYSTEM_HOT, UiFx.SYSTEM]:
		var ghost: Label = Label.new()
		ghost.text = source.text
		ghost.horizontal_alignment = source.horizontal_alignment
		ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ghost.add_theme_font_size_override("font_size",
				source.get_theme_font_size("font_size"))
		ghost.add_theme_color_override("font_color", tint)
		ghost.modulate.a = 0.0
		# Behind the real readout: the split should look like fringing on the
		# glyphs, not like three labels stacked.
		source.get_parent().add_child(ghost)
		source.get_parent().move_child(ghost, source.get_index())
		ghost.position = source.position
		ghost.size = source.size
		made.append(ghost)
	return made


func _update_glitch(delta: float) -> void:
	if Debug.hud_state != "damage":
		if _glitch <= 0.0:
			return
		_glitch = maxf(_glitch - delta / UiFx.GLITCH_TIME, 0.0)

	var shift: float = _glitch * UiFx.GLITCH_SHIFT
	var tick: float = floor(UiFx.clock() * 45.0)
	for i: int in _clusters.size():
		var jump: Vector2 = Vector2(
				UiFx.hash01(tick + float(i) * 3.1) - 0.5,
				UiFx.hash01(tick + float(i) * 3.1 + 11.0) - 0.5) * 2.0 * shift
		_clusters[i].position = _cluster_home[i] + jump

	_split(_cycles_ghosts, _cycles_value)
	_split(_data_ghosts, _data_value)
	_corrupt_callsign()


func _split(ghosts: Array[Label], source: Label) -> void:
	# Both trailing the same way, the nearer one brighter. The direction is
	# hashed per flinch rather than fixed, so two hits in a row do not shear
	# identically — a repeated identical artefact reads as an animation.
	var direction: float = 1.0 if UiFx.hash01(floor(UiFx.clock() * 5.0)) < 0.5 else -1.0
	var offset: float = _glitch * UiFx.GLITCH_SLIP * direction
	for i: int in ghosts.size():
		var ghost: Label = ghosts[i]
		if ghost.text != source.text:
			ghost.text = source.text
		ghost.modulate.a = _glitch * (0.55 if i == 0 else 0.28)
		ghost.position = source.position \
				+ Vector2(offset * (0.45 if i == 0 else 1.0), 0.0)


## Your own callsign coming apart for a fifth of a second. It is the one label on
## the HUD that is *you*, which is exactly why it is the one that corrupts.
func _corrupt_callsign() -> void:
	if _self_label == null or not is_instance_valid(_self_label):
		return
	if _glitch <= 0.001:
		if _self_label.text != _self_name:
			_self_label.text = _self_name
		return
	var tick: int = int(UiFx.clock() / UiFx.GLITCH_GLYPH_INTERVAL)
	if tick == _glyph_tick:
		return
	_glyph_tick = tick

	var out: String = ""
	for i: int in _self_name.length():
		var roll: float = UiFx.hash01(float(tick) * 7.0 + float(i) * 2.3)
		if roll < _glitch * 0.45:
			var pick: int = int(UiFx.hash01(float(tick) + float(i) * 5.7)
					* float(UiFx.CORRUPT_GLYPHS.length()))
			out += UiFx.CORRUPT_GLYPHS[pick % UiFx.CORRUPT_GLYPHS.length()]
		else:
			out += _self_name[i]
	_self_label.text = out


# --------------------------------------------------------------- degradation --

## The interface fails with the pool that powers it. Deliberately later than the
## amber warning: the readouts change colour first, and only start losing pixels
## once the crew is genuinely in trouble.
func _update_degradation() -> void:
	var target: float = 0.0
	if Run.configured:
		if Run.starved():
			target = 1.0
		else:
			target = clampf(inverse_lerp(
					UiFx.DEGRADE_FRACTION, 0.0, Run.display_fraction()), 0.0, 1.0)
	if absf(target - _degrade) > 0.002:
		_degrade = target
		_specks.degrade = _degrade
		for sheen: ShaderMaterial in _sheens:
			sheen.set_shader_parameter("degrade", _degrade)

	if _degrade <= 0.001:
		return
	# Label flicker. Hashed on a slow tick and on the label's index so the row
	# does not blink in unison — a synchronised flicker reads as an animation, an
	# unsynchronised one reads as a failing panel.
	var tick: float = floor(UiFx.clock() / UiFx.DEGRADE_TICK)
	for i: int in _flicker_labels.size():
		var roll: float = UiFx.hash01(tick + float(i) * 9.4)
		_flicker_labels[i].modulate.a = \
				0.25 if roll < 0.16 * _degrade else 1.0


# ------------------------------------------------------- holographic depth --

## Installs the sheen materials and the corner tilt.
##
## The tilt is deliberately about one degree. Control has no skew (Node2D does),
## so a small rotation about each cluster's own centre is the layout-safe way to
## stop the corners reading as rectangles glued to the frame. Any more than this
## and the text starts to shimmer under TAA — a real cost for an effect that is
## supposed to be subliminal.
func _install_depth() -> void:
	_tilt(_crew_cluster, UiFx.CLUSTER_TILT_DEG)
	_tilt(_cycles_panel, -UiFx.CLUSTER_TILT_DEG)
	_tilt(_integrity_panel, -UiFx.CLUSTER_TILT_DEG)
	_tilt(_kit_panel, -UiFx.CLUSTER_TILT_DEG)
	_tilt(_data_panel, UiFx.CLUSTER_TILT_DEG)

	_sheen(%CrewSheen, 0.55)
	_sheen(%CyclesSheen, -0.4)
	_sheen(%IntegritySheen, -0.35)
	_sheen(%KitSheen, -0.35)
	_sheen(%DataSheen, 0.4)

	# The readouts worth corrupting when the pool runs dry.
	_specks.regions = [
		Rect2(_cycles_panel.position, _cycles_panel.size),
		Rect2(_kit_panel.position, _kit_panel.size),
		Rect2(_integrity_panel.position, _integrity_panel.size),
		Rect2(_data_panel.position, _data_panel.size),
	]


func _tilt(cluster: Control, degrees: float) -> void:
	cluster.pivot_offset = cluster.size * 0.5
	cluster.rotation = deg_to_rad(degrees)


func _sheen(rect: ColorRect, perspective: float) -> void:
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = SHEEN_SHADER
	material.set_shader_parameter("tint", UiFx.SYSTEM)
	material.set_shader_parameter("perspective", perspective)
	# Every cluster gets its own sweep phase. Five panels sweeping in lockstep
	# would read as one animation across the screen instead of five surfaces.
	material.set_shader_parameter("sweep_period",
			UiFx.MENU_SWEEP_INTERVAL * (0.7 + UiFx.hash01(float(_sheens.size()) * 3.7) * 0.9))
	rect.material = material
	rect.color = Color(1.0, 1.0, 1.0, 1.0)
	_sheens.append(material)


## A few pixels of spring-damped lag against the lens. The HUD is projected in
## front of the process, not welded to it, so a hard turn leaves it very slightly
## behind — and then it catches up with the faintest overshoot.
##
## Disabled during automated runs: `--goto` snaps the avatar's rotation, which
## would fire a large impulse into the spring and make every capture depend on
## exactly when the shutter landed relative to the teleport.
func _update_parallax(delta: float) -> void:
	if Debug.automated or _player == null or not is_instance_valid(_player) or delta <= 0.0:
		return

	var yaw: float = _player.rotation.y
	var pitch: float = float(_player.sync_pitch)
	var spin: Vector2 = Vector2(
			angle_difference(_last_yaw, yaw), pitch - _last_pitch) / delta
	_last_yaw = yaw
	_last_pitch = pitch

	var target: Vector2 = (spin * PARALLAX_GAIN).limit_length(UiFx.PARALLAX_PIXELS)
	var accel: Vector2 = (target - _parallax) * UiFx.PARALLAX_SPRING \
			- _parallax_velocity * UiFx.PARALLAX_DAMPING
	_parallax_velocity += accel * delta
	_parallax += _parallax_velocity * delta
	_root.position = _parallax.limit_length(UiFx.PARALLAX_PIXELS * 1.6)


# --------------------------------------------------------------------- crew --

func _rebuild_crew() -> void:
	for child: Node in _crew_list.get_children():
		child.queue_free()
	_self_label = null

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
			UiFx.TEXT if is_self else UiFx.DIM)
	row.add_child(label)
	if is_self:
		# Held so the damage flinch can corrupt it — see `_corrupt_callsign`.
		_self_label = label
		_self_name = label.text

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
					Run.integrity_of(id) / maxf(Run.integrity_max_of(id), 1.0), 0.0, 1.0)
			gauge.custom_minimum_size.x = maxf(26.0 * fraction, 1.0)
			gauge.color = COLOUR_WARNING if fraction <= 0.0 else \
					(COLOUR_AMBER if fraction < 0.4 else COLOUR_OK)

		var tag: Label = row.get_node_or_null("Latency") as Label
		if tag == null:
			continue
		if not Run.is_alive(id):
			tag.text = "GONE"
			tag.add_theme_color_override("font_color", COLOUR_WARNING)
		elif Run.is_corrupted(id):
			tag.text = "DOWN %ds" % int(ceilf(Run.corruption_left(id)))
			tag.add_theme_color_override("font_color", COLOUR_AMBER)
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
		var quality: Color = UiFx.SYSTEM
		if ping > 120:
			quality = Color(0.95, 0.45, 0.4)
		elif ping > 60:
			quality = Color(0.95, 0.75, 0.35)
		_link_label.add_theme_color_override("font_color", quality)


# ----------------------------------------------------------- injection gate --
#
# DESIGN.md's lobby rule: "Backdoor injection requires all present crew to have
# installed it." NULLVOID has no separate lobby scene — the crew assembles inside
# the layer, join-in-progress — so the rule is enforced at the door (Net's
# `_register_crew` refuses the peer and tells them why) and *shown* here.
#
# The host is the one who needs this panel. From the refused player's side the
# answer arrives as a menu status line, which is the right place for it because
# the fix is "go and root that node". From the host's side, somebody just
# bounced off their session and the only useful thing an interface can say is
# **which crew member is missing which backdoor** — otherwise a crew spends the
# evening guessing why their fourth cannot get in.

func _build_gate_panel() -> void:
	_gate_panel = Control.new()
	_gate_panel.name = "InjectionGate"
	_gate_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_gate_panel.position = Vector2(-260.0, 96.0)
	_gate_panel.custom_minimum_size = Vector2(520.0, 0.0)
	_gate_panel.size = Vector2(520.0, 150.0)
	_gate_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gate_panel.visible = false
	_fixed.add_child(_gate_panel)

	var plate: ColorRect = ColorRect.new()
	plate.color = Color(0.05, 0.015, 0.02, 0.9)
	plate.set_anchors_preset(Control.PRESET_FULL_RECT)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gate_panel.add_child(plate)

	var edge: ColorRect = ColorRect.new()
	edge.color = Color(COLOUR_WARNING.r, COLOUR_WARNING.g, COLOUR_WARNING.b, 0.7)
	edge.set_anchors_preset(Control.PRESET_TOP_WIDE)
	edge.custom_minimum_size = Vector2(0.0, 2.0)
	edge.offset_bottom = 2.0
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(edge)

	var column: VBoxContainer = VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.offset_left = 16.0
	column.offset_right = -16.0
	column.offset_top = 12.0
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(column)

	_gate_title = Label.new()
	_gate_title.add_theme_font_size_override("font_size", 15)
	_gate_title.add_theme_color_override("font_color", COLOUR_WARNING)
	_gate_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_gate_title)

	_gate_body = Label.new()
	_gate_body.add_theme_font_size_override("font_size", 13)
	_gate_body.add_theme_color_override("font_color", COLOUR_TEXT)
	_gate_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_gate_body)


## `entries` is Net.gate_roster(): every program the gate has looked at, in join
## order, with the crew that got in first and everyone it turned away after.
func _show_gate(entries: Array) -> void:
	if _gate_panel == null:
		return
	var needed: int = 0
	var lines: PackedStringArray = PackedStringArray()
	for row: Dictionary in entries:
		needed = maxi(needed, int(row.get("needed", 0)))
		var theirs: int = int(row.get("theirs", 0))
		lines.append("%-14s BACKDOOR %s   %s" % [
			String(row.get("name", "AGENT")),
			"--" if theirs <= 0 else "%02d" % theirs,
			"OK" if bool(row.get("ok", false)) else "MISSING  ·  TURNED AWAY"])
	_gate_title.text = "INJECTION GATE  ·  LAYER %02d  ·  BACKDOOR %02d REQUIRED" % [
		Run.layer_number, needed]
	_gate_body.text = "\n".join(lines)
	_gate_panel.visible = true
	_gate_clock = 12.0


func _update_gate(delta: float) -> void:
	if _gate_clock < 0.0:
		return
	_gate_clock -= delta
	# Held solid, then let go. A panel that fades the whole time is a panel you
	# read while it is disappearing.
	_gate_panel.modulate.a = clampf(_gate_clock / 1.5, 0.0, 1.0)
	if _gate_clock <= 0.0:
		_gate_clock = -1.0
		_gate_panel.visible = false


func _show_notice(message: String) -> void:
	_notice_label.text = message
	_notice_label.modulate.a = 1.0
	_notice_clock = NOTICE_DURATION


# ----------------------------------------------------------------- overlays --

func _set_paused(paused: bool) -> void:
	_pause.visible = paused
	# Controller navigation: an overlay that opens with nothing focused is an
	# overlay a pad cannot use. Mouse and keyboard are unaffected — focus is
	# additive, and clicking still works exactly as it did.
	if paused:
		_resume_button.grab_focus.call_deferred()
	# Join-in-progress is the whole point of a Steam lobby: the pause console is
	# where a host reaches the overlay's invite dialog mid-intrusion. Hidden
	# entirely on the DIRECT transport, where there is nothing to invite into.
	_invite_button.visible = paused and SteamHub.live \
			and Net.transport == Net.Transport.STEAM and SteamHub.lobby != 0
	if DisplayServer.get_name() == "headless":
		return
	if paused:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif Debug.may_capture_mouse():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


## The debrief, for both ways a run can end. DESIGN.md M5 will make this a proper
## screen; what it has to do now is say plainly whether the haul came home — and
## since M3.8, say it the way the rest of the shell speaks: the lines type
## themselves in, and the archive total rolls up to what the run just added.
func _on_run_ended(summary: Dictionary) -> void:
	_pause.visible = false
	_summary.visible = true
	_exfil_label.text = ""
	_alert_label.text = ""

	var success: bool = bool(summary.get("success", false))
	_summary_title.text = "EXFILTRATION COMPLETE" if success else "INTRUSION TERMINATED"
	_summary_title.add_theme_color_override("font_color",
			UiFx.SYSTEM_HOT if success else COLOUR_WARNING)

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
	var mine: int = int(banked.get(Net.local_id(), 0))
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
	else:
		lines.append("BUFFERED DATA LOST. COMPILED MODULES INTACT.")

	# The archive delta, spelled out. Run has already banked by the time this
	# runs, so "what it was" is the archive minus what came home — and printing
	# the sum rather than only the new total is the whole point: a debrief should
	# answer "was that run worth it" without arithmetic.
	var before: int = maxi(GameState.archive - (mine if success else 0), 0)
	lines.append("")
	if success and mine > 0:
		lines.append("ARCHIVE           %d  →  %d   (+%d)" % [
			before, GameState.archive, mine])
	else:
		lines.append("ARCHIVE           %d   (UNCHANGED)" % GameState.archive)

	_summary_button.grab_focus.call_deferred()
	_summary_body.text = "\n".join(lines)
	_summary_body.visible_ratio = 0.0
	_debrief_lines = lines.size()
	_debrief_clock = 0.0

	# The counter rolls from what the archive held before this run to what it
	# holds now. Run has already banked, so the target is simply the archive and
	# the start is the archive minus what came home.
	_banked_to = GameState.archive
	_banked_from = maxi(_banked_to - (mine if success else 0), 0)
	_banked_caption.text = "ARCHIVE  ·  +%d THIS RUN" % mine \
			if success and mine > 0 else "ARCHIVE"
	_banked_value.text = str(_banked_from)
	_banked_value.add_theme_color_override("font_color",
			UiFx.SYSTEM_HOT if success else COLOUR_DIM)

	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## Types the summary in and rolls the counter. Snapped to its finished state
## under automation, so a captured debrief is always the whole panel rather than
## whatever fraction of it had appeared when the shutter fired.
func _update_debrief(delta: float) -> void:
	if _debrief_clock < 0.0:
		return
	if Debug.automated and Debug.hud_state != "debrief":
		_debrief_clock = -1.0
		_summary_body.visible_ratio = 1.0
		_banked_value.text = str(_banked_to)
		return

	_debrief_clock += delta
	var typing: float = float(_debrief_lines) * UiFx.DEBRIEF_LINE_TIME
	_summary_body.visible_ratio = clampf(_debrief_clock / maxf(typing, 0.01), 0.0, 1.0)

	var rolling: float = clampf(
			(_debrief_clock - typing) / UiFx.DEBRIEF_COUNT_TIME, 0.0, 1.0)
	# Ease out: a counter that decelerates into its total reads as a machine
	# settling on a number rather than as a linear tween.
	var eased: float = 1.0 - pow(1.0 - rolling, 3.0)
	_banked_value.text = str(int(round(lerpf(float(_banked_from), float(_banked_to), eased))))
	if rolling >= 1.0:
		_debrief_clock = -1.0


func _on_leave_pressed() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Net.leave("YOU ABORTED THE INTRUSION")
