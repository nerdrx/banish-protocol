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

# --- M4.9: the quiet-instrument HUD -----------------------------------------
## Integrity is a thin arc hugging the Cycles ring rather than a bar of its own —
## the resting cluster is one gauge, and the arc surfaces on it only when you are
## hurt. The old IntegrityPanel bar (`_integrity_fill`/`_integrity_label`) is
## retired to `visible = false` in the scene; nothing drives it any more.
@onready var _integrity_arc: ArcMeter = %IntegrityArc
## The tiny persistent layer numeral the descent title fades back to.
@onready var _layer_tag: Label = %LayerTag
## The "BUFFERED DATA" caption — a surface-managed label that yields to its numeral.
@onready var _data_caption: Label = %DataCaption

## Every element that is not the resting cluster is a `UiFx.Surface`: hidden until
## it is relevant, then faded. Constructed once, ticked every frame — see
## `_update_surfaces`. The cluster itself (the Cycles ring, its numeral, the small
## data readout, the tiny layer tag) is the only thing persistent by construction.
var _srf_integrity: UiFx.Surface = null
var _srf_kit: UiFx.Surface = null
var _srf_crew: UiFx.Surface = null
var _srf_title: UiFx.Surface = null
var _srf_link: UiFx.Surface = null
## Captions that show on first change then yield to the shape they name.
var _srf_cycles_caption: UiFx.Surface = null
var _srf_data_caption: UiFx.Surface = null
var _srf_kit_label: UiFx.Surface = null
## Which pool band the caption last poked on, so a steady drain does not keep the
## label alive — only a band CROSSING (green->amber->red) re-surfaces it.
var _cycles_band: int = -1
## Last flare stock seen, so a change (throw / restock) surfaces the kit briefly.
var _flare_seen: int = -1
## Last buffered-data value seen, so a pickup or a spend surfaces its caption.
var _carried_seen: int = -1
## The demoted diagnostics line ("LISTEN HOST · N CREW", link latency). Out of the
## gameplay HUD by default; a debug overlay, shown only under `Debug.hud_debug`
## or surfaced briefly when the link itself is the relevant thing (bad latency).
var _link_bad: bool = false

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
## frame of the boot and must not allocate. `_add_boot` is the ONLY thing allowed
## to write to either — they are indexed with one counter, so a bare append to
## one of them reads off the end of the other and aborts the sequence.
var _boot_nodes: Array[CanvasItem] = []
var _boot_starts: PackedFloat32Array = PackedFloat32Array()
## Compile-order starts that something outside the array walk also needs: the
## reticle shares the crosshair anchor's moment, and the Cycles ring spins up
## with the panel it is drawn in.
const BOOT_CROSSHAIR_START: float = 0.05
const BOOT_CYCLES_START: float = 0.22

# --- glitch / degradation ---------------------------------------------------
var _glitch: float = 0.0
var _degrade: float = -1.0
## M6 glitch-proximity sense: 0..1 static that rises as a hunter nears the local
## avatar — the screen breaking IS the radar. Ramped smoothly (never a strobe) and
## held under A11y.glitch_proximity_ceiling() (the flash cap + Dampened Protocol),
## so it is a new glitch source that stays inside the safety law by construction.
var _proximity: float = 0.0
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

# --- MOTHER's voice (M6) -----------------------------------------------------
#
# The glyph-panel MOTHER speaks through. Deliberately NOT the amber player HUD:
# this is her channel, not the crew's instrument, so it renders in her red glyph
# colour, centred, above the readouts. The corruption is baked into the corpus
# rendering the Director sends (depth-scaled, the same vocabulary the terminals
# and signage decay through), so the label only holds and fades it. An address
# line — the callsign money moment — holds longer and reads larger.
var _mother_label: Label = null
var _mother_clock: float = 0.0
var _mother_hold: float = 0.0
var _mother_is_address: bool = false
var _prox_log_clock: float = 0.0
## Cached raw (pre-ceiling) proximity 0..1, refreshed on a slow scan clock so the
## per-frame path never walks the hunter group. The ceiling is applied per frame
## so the A11y / Dampened toggles still respond instantly.
var _prox_target: float = 0.0
var _prox_scan_clock: float = 0.0
## How often the radar re-scans the hunter group. The bearing of dread does not
## need 60 Hz (same reasoning as PING_INTERVAL for the link readout).
const PROX_SCAN_INTERVAL: float = 0.2

# --- the tube ---------------------------------------------------------------
## The interface's own viewport, the container compositing it back, and the
## full-rect fader that gives the phosphor its decay. See `_build_tube`.
var _tube: SubViewport = null
var _screen: SubViewportContainer = null
var _crt: ShaderMaterial = null
var _fixed: Control = null
## PT2's minimap, and its inset from the tube-safe box's bottom-right corner.
var _minimap: Minimap = null
const MINIMAP_MARGIN: float = 22.0
## 0..1 how far the tube has warmed up. Cold on injection.
var _warmup: float = 0.0

# --- crosshair --------------------------------------------------------------
var _reticle: Crosshair = null
## PT1. Enemy integrity readouts, drawn under the reticle. See IntegrityReadout.
var _readouts: IntegrityReadout = null
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
	Run.shaft_siphoned.connect(_on_shaft_siphoned)
	Run.layer_changed.connect(_on_layer_changed)
	# A client learns which layer it is on from the config packet, which lands
	# after the HUD is built. Without this the readout is stuck on 01 for anyone
	# who joined an intrusion that did not start at the surface.
	Run.config_changed.connect(func() -> void: _on_layer_changed(Run.layer_number))
	Run.run_ended.connect(_on_run_ended)
	# THE PARTITION: arriving home takes the debrief down. The crew is standing in
	# a room again, and a summary overlay left up over it would be the old
	# menu-shaped ending wearing the new flow's clothes.
	Run.hub_changed.connect(_on_hub_changed)
	Run.damaged.connect(_on_damaged)
	_resume_button.pressed.connect(_set_paused.bind(false))
	_leave_button.pressed.connect(_on_leave_pressed)
	# A SETTINGS entry in the pause overlay, so a player mid-run can soften the
	# audio spikes or turn on captions without leaving the intrusion (spec 06:
	# accessibility must be reachable at the worst moment). Built in code beside
	# the existing pause buttons.
	var settings_button: Button = Button.new()
	settings_button.text = "SETTINGS"
	var leave_parent: Node = _leave_button.get_parent()
	if leave_parent != null:
		leave_parent.add_child(settings_button)
		leave_parent.move_child(settings_button, _leave_button.get_index())
		settings_button.pressed.connect(func() -> void: SettingsPanel.open(self))
	_invite_button.pressed.connect(func() -> void: SteamHub.open_invite_overlay())
	_summary_button.pressed.connect(_on_summary_pressed)

	# Before anything pokes one: _rebuild_crew and _on_layer_changed below both
	# surface an element, and _process ticks them every frame after that.
	_build_surfaces()

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

	# M7: the subroutine slot indicator, beside the Cycles gauge. Deliberately ONE
	# line — the widget is a self-contained Control that owns its own anchors,
	# surfacing and drawing (see SubroutineSlot), so the HUD neither grows a ninth
	# surface nor a fifth cluster for it. Added before `_build_tube` so it is
	# reparented into the phosphor tube with the rest of the instrument.
	_root.add_child(SubroutineSlot.create())
	# M9: the patch strip, above the Cycles gauge. ONE line for the same reason
	# the slot above it is one line — see PatchStrip, which owns its own anchors,
	# surfacing, expansion and drawing, and draws nothing at all until this run
	# has actually found a patch.
	_root.add_child(PatchStrip.create())

	_build_tube()
	_install_depth()
	_install_glitch_rig()
	_build_mother_surface()
	Haunt.mother_spoke.connect(_on_mother_spoke)
	_build_crosshair()
	_build_gate_panel()
	_build_minimap()
	_begin_boot()
	Run.local_shot.connect(_on_local_shot)
	# Everything above snapshots laid-out geometry — the clusters' home positions,
	# the speck regions, the rotation pivots. `CyclesPanel`, `IntegrityPanel`,
	# `KitPanel` and `DataPanel` are all authored bottom-anchored, so their
	# `position.y` is derived from the parent's height and moves on every viewport
	# change; the window is resizable and `stretch/aspect=expand` grows the
	# viewport with it. Captured once, the flinch then wrote launch-time
	# coordinates back over them — a 720p -> 1080p change snapped all four
	# clusters ~360 px and left them there.
	_root.resized.connect(_recapture_layout)
	# PT2 (Screen & Nav). `Root` carries every anchored cluster in the interface,
	# and it was PRESET_FULL_RECT — so "24 px in from the left edge" meant 24 px
	# from the edge of the CANVAS, which under `canvas_items` + `expand` is 1720 px
	# wide at 21:9 and 2560 at 32:9, not 1280. The four corner clusters obediently
	# went to the four corners of a 32:9 panel: over a metre apart, two of them
	# outside the player's field of attention entirely, and all four sitting in the
	# region the CRT tube's barrel warp has no picture for. Same class of bug as
	# the menu's ghost program panel, same fix — `Root` now IS the tube-safe box.
	#
	# `Fixed` deliberately does NOT move. The crosshair, the interact prompt, the
	# damage arc and the pause/summary plates want the TRUE centre of the screen
	# and the true full frame; a reticle inset into a 16:9 box on an ultrawide
	# would not be where the gun is pointing. Aim is full-bleed, instruments are
	# safe-area, and that split is the whole rule.
	# `-- --no-hud`: the whole instrument stack hidden, for the captures that are
	# about the WORLD. A lighting sheet with a Cycles gauge in the corner is a
	# sheet where half the argument is about the gauge.
	#
	# Read straight off the command line rather than added to `Debug.hud_state`,
	# and that is deliberate: `hud_state` is a whitelist of HUD PORTRAIT states
	# with a validator behind it, "no HUD" is the absence of one, and
	# src/core/debug.gd is a shared file under concurrent edit that a capture
	# convenience has no business widening. Costs one array scan at boot.
	if OS.get_cmdline_user_args().has("--no-hud"):
		visible = false

	get_viewport().size_changed.connect(_fit_safe_area)
	# PT3: and on the settings store, because HUD WIDTH does not resize the canvas
	# — it re-decides how much of it the instruments get. A player dragging that
	# slider with the pause menu open has to see their own minimap move under it,
	# or they are tuning a number against a memory of where things used to be.
	Screen.changed.connect(_fit_safe_area)
	_fit_safe_area()

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
	_update_surfaces(delta)
	_update_proximity(delta)
	_update_mother(delta)
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
	_crt.set_shader_parameter("gain", 1.34)
	# PT2, same argument as the menu's (see MainMenu._build_terminal): the stripe
	# runs at content scale now so it needs less amplitude to read, the smear is
	# one SCREEN PIXEL rather than 0.16% of the screen width (which was five pixels
	# of ghost on an ultrawide — the reported double-strike), and the phosphor bias
	# stops dragging readouts down to the luminance of the player's marker colour.
	_crt.set_shader_parameter("phosphor_bias", 0.24)
	_crt.set_shader_parameter("smear_pixels", 1.0)
	_crt.set_shader_parameter("scanline_strength", 0.10)
	# PT2: the tube's own edge falloff follows the player's VIGNETTE slider, like
	# the menu's. It stacks on the world post grade's vignette, and two vignettes
	# multiplying is how a readout 24 px inside the frame stopped being readable.
	_crt.set_shader_parameter("vignette", 0.26 * Screen.vignette)
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
	# are already using — one fault, told twice, in two vocabularies. M6 adds the
	# proximity static under the same term: a nearing hunter loses you the tube's
	# hold, sustained rather than flinched. The `damage` shader path is already
	# a11y-scaled (mix(0.4,1,a11y_flash)) and positional (a uv shear, not a
	# luminance flash), and `_proximity` is held under the flash-capped ceiling — so
	# the radar cannot become a strobe.
	_crt.set_shader_parameter("damage", maxf(_glitch, _proximity))
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
	# PT1: the enemy integrity readouts, on the same fixed layer as the reticle
	# and BELOW it in draw order — the reticle is the one element on the interface
	# that is never allowed to be occluded. Inside the tube, so the bars pick up
	# the scanlines and the curvature like every other readout.
	_readouts = IntegrityReadout.new()
	_readouts.name = "IntegrityReadouts"
	_fixed.add_child(_readouts)
	_fixed.move_child(_readouts, _reticle.get_index())
	# Through `_add_boot`, never a bare append: `_boot_nodes` and `_boot_starts`
	# are parallel and `_apply_boot` indexes both with the same counter, so an
	# element added to one and not the other reads past the end of the other and
	# aborts the whole sequence. The reticle compiles in with the anchor it is
	# drawn over, which is the same moment.
	_add_boot(_reticle, BOOT_CROSSHAIR_START)


## Local-only, and predicted rather than authoritative — the same standing as the
## beam-lash the shooter draws a round trip before the host agrees with it. See
## `Player._update_breaker`.
func _on_local_shot(did_hit: bool, killed: bool) -> void:
	if killed:
		_kill_burst = 1.0
	if did_hit or killed:
		_hit_tick = 1.0
		# PT1: the audible half of the hit marker. A tick you can hear is what
		# makes a hit register in a dark room where the thing you shot is a
		# silhouette — and it is 2D and dry, so it never gets confused with the
		# spatialised hurt cry the creature itself makes. A kill keeps the burst
		# and the creature's own death sound; it does not stack a second confirm.
		Audio.play_2d(&"hit_confirm")


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
	# Only the resting cluster compiles in. Everything else is a Surface now
	# (M4.9): the roster, the descent title, the kit and the integrity arc are
	# hidden until they are relevant, and their first pokes below (the crew
	# rebuild, the arrival layer-change) surface them the moment the shell is up.
	_add_boot(_crosshair, BOOT_CROSSHAIR_START)
	_add_boot(_cycles_panel, BOOT_CYCLES_START)
	_add_boot(_data_panel, 0.5)

	_boot_line.text = "INSTANCE 0x%04X  ·  RUNTIME OK" % _instance_hash()
	_boot_line.visible_ratio = 0.0

	# M5: the tube warming up — contactor, degauss whump, tube warm-up, scanline
	# sweeps, self-test pips. The instrument booting as you compile into the layer.
	Audio.play_2d(&"ui_boot")

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
	# a gauge finding its reading rather than a bar being drawn. It starts when
	# the panel it lives in does — named, not an index into `_boot_starts`, which
	# moves the moment anything is added to the compile order.
	var spin: float = clampf(
			(_boot_clock - BOOT_CYCLES_START) / UiFx.BOOT_RING_TIME, 0.0, 1.0)
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

	# The pool caption ("SHARED CYCLES", "/ 100") shows on a band CROSSING — green
	# to amber to red — then yields to the ring and the numeral. A steady drain
	# must not keep the label lit, so it pokes on the transition only, never on the
	# per-second tick of the number itself.
	var band: int = 0
	if fraction < Balance.CYCLES_WARNING_FRACTION:
		band = 2
	elif fraction < UiFx.RING_AMBER_FRACTION:
		band = 1
	if band != _cycles_band:
		_cycles_band = band
		_srf_cycles_caption.surface()

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
	# A refill is a relevant change: let the pool caption say its piece and fade.
	_srf_cycles_caption.surface()


## PT1. The drop shaft's cut, arriving on the same beat as the layer title.
##
## Deliberately the SAME gesture a siphon tap makes — one surge of the ring, the
## pool caption surfacing once and fading — because they are the same event to a
## player: something just fed the pool. A second, louder treatment for the second
## refill would be two vocabularies for one idea, which is precisely the clutter
## the quiet-instrument rule exists to refuse. No banner: `LAYER NN` is already
## coming up and this must not compete with it.
func _on_shaft_siphoned(_gained: float) -> void:
	_pulse = 1.0
	_surge_clock = 0.0
	_srf_cycles_caption.surface()
	Audio.play_2d(&"shaft_siphon")


## The descent title. It announces the layer for ~2 s on arrival and then yields
## to the tiny persistent numeral in the cluster — DESIGN.md: "layer title only on
## descent". Retinted to the phosphor so the card belongs to the same instrument
## as the rest of the shell rather than reading as leftover architecture teal.
func _on_layer_changed(number: int) -> void:
	# The Partition is not a ring, and saying LAYER 01 over it is the one place the
	# instrument could still tell the player they are inside MOTHER when they are
	# standing in the sector the crew took off her. The compact tag goes to a glyph
	# for the same reason: it is a place, not a depth.
	_layer_label.text = "THE PARTITION" if Run.in_hub else "LAYER %02d" % number
	_layer_label.add_theme_color_override("font_color", UiFx.SYSTEM)
	_layer_tag.text = "◆" if Run.in_hub else "L%02d" % number
	_layer_tag.add_theme_color_override("font_color", COLOUR_DIM)
	_srf_title.surface()


# ---------------------------------------------------------------- integrity --

## Integrity as a thin arc hugging the Cycles ring — hidden at full, surfacing on
## any wound and holding through the slow regen until it has genuinely healed.
## DESIGN.md's quiet rule: "integrity hidden at full". The old horizontal bar
## (`_integrity_fill`/`_integrity_label`, now `visible = false` in the scene) is
## retired; the arc's shape and the alert line carry what it used to spell out.
func _update_integrity() -> void:
	var value: float = Run.local_integrity()
	# Against your OWN ceiling, which Checksum raises. A tier-5 program sitting at
	# 150 integrity is at 67%, not "150%", and the arc has to say so.
	var fraction: float = clampf(
			value / maxf(Run.integrity_max_of(Net.local_id()), 1.0), 0.0, 1.0)
	_integrity_arc.value = fraction

	var colour: Color = COLOUR_OK
	if fraction <= 0.0:
		colour = COLOUR_WARNING
	elif fraction < 0.4:
		colour = COLOUR_AMBER
	_integrity_arc.fill_color = colour

	# The heart of the rule: at full integrity the arc is simply not drawn.
	# Anything less than full — or corrupted, or decompiled — surfaces it, and the
	# per-frame poke keeps it up through the slow regen back to 100%, so a scar is
	# legible right up until it has actually closed.
	if fraction < 0.999 or Run.local_corrupted():
		_srf_integrity.surface()


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
	# The data caption ("BUFFERED DATA") flashes when the number moves — a chip
	# magnetised in, a purchase spent — then yields to the numeral it labels.
	if carried != _carried_seen:
		if _carried_seen >= 0:
			_srf_data_caption.surface()
		_carried_seen = carried

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
	# DESIGN.md: "breaker heat only when hot". The whole kit — heat and flare pips
	# — is hidden at rest and surfaces on relevance: the cutter running hot or
	# locked out, or the flare stock changing (a throw, a restock at a cabinet).
	if heat > 0.04 or locked:
		_srf_kit.surface()
		_srf_kit_label.surface()

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
	if stock != _flare_seen:
		if _flare_seen >= 0:
			_srf_kit.surface()
		_flare_seen = stock


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
		# A downed crewmate is ongoing relevance: the roster is re-poked every
		# frame it lasts, so it holds until everyone is back up, then fades.
		_srf_crew.surface()
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

	# THE PARTITION's commit clock, in the same slot the exfil countdown uses.
	#
	# Quiet Instrument (DESIGN.md M4.9): it is the same KIND of thing — a committed
	# clock the whole crew has to see and can still act on — so it gets the same
	# place on the screen rather than a second one. The rest of the time it is not
	# there at all, which is the rule. The rig itself carries the state; this is
	# only the number, for the crewmate who is looking at the far wall.
	if Run.injecting:
		var closing: float = 1.0 - clampf(
				Run.inject_remaining / maxf(Run.INJECT_COUNTDOWN, 0.01), 0.0, 1.0)
		_exfil_label.text = "INJECTION  %02d  ·  LAYER %02d" % [
			int(ceilf(Run.inject_remaining)), Run.injection_layer]
		_exfil_label.modulate.a = 0.65 + 0.35 * UiFx.heartbeat(
				UiFx.clock(), 0.72 - closing * 0.42)
		return

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
	# The integrity arc comes up the instant you are hit, not a frame later when
	# the replicated value lands — a wound should register the moment it happens.
	_srf_integrity.surface()
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
	# IntegrityPanel is retired (M4.9): integrity is the arc on the ring now, and it
	# jumps with the CyclesPanel it lives inside — there is no separate cluster to
	# shake any more.
	_clusters = [_crew_cluster, _cycles_panel, _kit_panel, _data_panel]
	_capture_cluster_homes()

	_cycles_ghosts = _make_ghosts(_cycles_value)
	_data_ghosts = _make_ghosts(_data_value)

	# The captions are surface-managed now — `_update_surfaces` owns their
	# modulate.a — so the degrade flicker must not also write it or the two fight.
	# Degradation still reads loudly on the specks, the tube's tearing and the
	# ring's burnt ticks; a blinking caption was always the least of it.
	_flicker_labels = []


func _capture_cluster_homes() -> void:
	_cluster_home.resize(_clusters.size())
	for i: int in _clusters.size():
		_cluster_home[i] = _clusters[i].position


## Re-takes every one-shot layout snapshot after the viewport changes size.
## Skipped mid-flinch would be fine too, but the jump is 0.2 s and a resize is
## not something to be clever about: re-home first, and let the current flinch
## finish against the new coordinates.
## Park the instrument cluster root on the tube-safe rect. See
## `UiFx.tube_safe_rect` for the rule and the measurements behind it.
##
## The parallax rig writes `_root.position` every frame, which on a Control with
## anchors is a write to its offsets — so this deliberately re-solves the anchors
## rather than trusting them to have survived. It runs on every viewport change,
## which includes the UI-scale slider moving (a scale change resizes the 2D
## canvas) and the window being dragged to another monitor.
func _fit_safe_area() -> void:
	if _root == null or not is_instance_valid(_root):
		return
	# Off the ROOT viewport, not `_root`'s own: after `_build_tube` the cluster
	# root lives inside the tube's SubViewport, and asking that for its size would
	# be asking the thing being sized how big it is.
	#
	# PT3: the INSTRUMENT zone, not the tube-safe box. Same rect at HUD WIDTH 0,
	# widening toward the panel's own edges as the player (or the ultrawide
	# auto-ramp) opens it up. The minimap rides this for free — it is anchored to
	# `_root`'s bottom-right corner, so "put the map at the very right of my
	# monitor" is one number on one Control. See `UiFx.instrument_rect`.
	UiFx.fit_to_instrument_area(_root, get_viewport().get_visible_rect().size)
	# `_root.resized` fires from this and re-snapshots every cluster's home
	# position, which is exactly what has to happen: those homes are what the
	# flinch and the parallax spring return to.
	_fit_mother_line()


## MOTHER's line is the one readout in the HUD with a HARD WIDTH — 760 px, so her
## sentences break where they were written to break. `--ui-audit` at UI SCALE 1.6:
## `Root/MotherLine OUTSIDE-SAFE x=197..957` against a 680 px safe box, because a
## fixed pixel width in a canvas that SHRINKS with the scale factor eventually
## exceeds any box you put it in. The label already autowraps, so the answer is to
## let it: authored width where there is room for it, the safe box's own width
## where there is not, and one more line of dialogue instead of two words in the
## curve of the glass.
func _fit_mother_line() -> void:
	if _mother_label == null or not is_instance_valid(_mother_label):
		return
	var view: Vector2 = get_viewport().get_visible_rect().size
	var box: float = UiFx.instrument_rect(view, Screen.hud_width_for(view)).size.x
	if Debug.no_safe_area:
		box = view.x
	var width: float = minf(MOTHER_LINE_WIDTH, box * MOTHER_LINE_FRACTION)
	_mother_label.custom_minimum_size = Vector2(width, 0.0)
	_mother_label.pivot_offset = Vector2(width * 0.5, 20.0)


func _recapture_layout() -> void:
	if _clusters.is_empty():
		return
	_capture_cluster_homes()
	_capture_speck_regions()
	for cluster: Control in _clusters:
		cluster.pivot_offset = cluster.size * 0.5


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
			_glitch = 0.0
			# The proximity static keeps the rig alive even with no damage flinch: a
			# nearing hunter jitters the clusters on its own, which is the radar. Once
			# both are gone, settle the clusters home and stop.
			if _proximity <= 0.0:
				for i: int in _clusters.size():
					if i < _cluster_home.size():
						_clusters[i].position = _cluster_home[i]
				return
		else:
			_glitch = maxf(_glitch - delta / UiFx.GLITCH_TIME, 0.0)

	# SAFETY (a11y): the flinch's positional jump and chromatic shear are small-area
	# and brief (HUD-only, ~0.2 s), so they hold with Reduced Flashing OFF — but
	# they are a new M4.9 flash source, so they scale by the same global switch and
	# go still under Reduced Flashing. The proximity static folds in under the same
	# a11y_flash scale and is already held below the flash-capped ceiling. The
	# callsign corruption below is text, not a flash, and is left alone.
	var intensity: float = maxf(_glitch, _proximity)
	var shift: float = intensity * UiFx.GLITCH_SHIFT * A11y.flash_scale
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
	var offset: float = _glitch * UiFx.GLITCH_SLIP * direction * A11y.flash_scale
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


# --------------------------------------------------------- proximity radar --

## The glitch-proximity sense. The static rises with the nearest HUNTER to the
## local avatar (Scrubbers and the Sentinel have their own language and do not
## drive it), ramped smoothly so it breathes rather than snaps, and clamped to the
## A11y ceiling — which already folds in the flash scale and Dampened Protocol. It
## is an amplitude, not a strobe: nothing here flashes, it only leans the tube's
## loss-of-hold up as a hunter closes.
func _update_proximity(delta: float) -> void:
	# The group scan is throttled; only the smooth ramp runs every frame.
	_prox_scan_clock -= delta
	if _prox_scan_clock <= 0.0:
		_prox_scan_clock = PROX_SCAN_INTERVAL
		_prox_target = _scan_nearest_hunter()
	var target: float = _prox_target * A11y.glitch_proximity_ceiling()
	_proximity = move_toward(_proximity, target, Balance.HAUNT_GLITCH_RATE * delta)
	if _proximity < 0.001:
		_proximity = 0.0
	# --log-ai: throttled trace of the radar rising, for verifying it tracks a
	# nearing hunter AND never crosses the flash-capped ceiling.
	if Debug.log_ai and _proximity > 0.0:
		_prox_log_clock -= delta
		if _prox_log_clock <= 0.0:
			_prox_log_clock = 0.5
			print("[HUD] glitch-proximity=%.3f (ceiling %.3f)" % [
				_proximity, A11y.glitch_proximity_ceiling()])


## The raw 0..1 nearness of the closest hunter to the local avatar, before the
## flash-capped ceiling is applied. Walks the hunter group — hence throttled.
func _scan_nearest_hunter() -> float:
	var body: Node3D = _player as Node3D
	if body == null or not is_instance_valid(body):
		body = Net.get_player(Net.local_id()) as Node3D
	if body == null or not is_instance_valid(body):
		return 0.0
	var nearest: float = 1e9
	for node: Node in get_tree().get_nodes_in_group(Hunter.HUNTER_GROUP):
		var hunter: Node3D = node as Node3D
		if hunter == null or not is_instance_valid(hunter):
			continue
		nearest = minf(nearest, hunter.global_position.distance_to(body.global_position))
	if nearest >= 1e9:
		return 0.0
	return clampf(inverse_lerp(Balance.HAUNT_GLITCH_FAR, Balance.HAUNT_GLITCH_NEAR,
			nearest), 0.0, 1.0)


# ----------------------------------------------------------- MOTHER's voice --

## MOTHER's glyph panel: a centred red line above the amber readouts, distinct
## from the crew's instrument because it is HER channel. Built in code beside the
## other overlays.
## The width MOTHER's line is authored at, and the most of the tube-safe box it is
## ever allowed to take. The fraction leaves her line clear of the box's own edge
## so she never reads as part of the frame.
const MOTHER_LINE_WIDTH: float = 760.0
const MOTHER_LINE_FRACTION: float = 0.92


func _build_mother_surface() -> void:
	_mother_label = Label.new()
	_mother_label.name = "MotherLine"
	_mother_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mother_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_mother_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mother_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_mother_label.anchor_left = 0.5
	_mother_label.anchor_right = 0.5
	_mother_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_mother_label.position = Vector2(0.0, 96.0)
	# Both re-solved by `_fit_mother_line` against the live safe box; these are the
	# authored values it treats as the maximum.
	_mother_label.custom_minimum_size = Vector2(MOTHER_LINE_WIDTH, 0.0)
	_mother_label.pivot_offset = Vector2(MOTHER_LINE_WIDTH * 0.5, 20.0)
	_mother_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mother_label.add_theme_font_override("font", load("res://assets/fonts/ui_font.tres") as Font)
	_mother_label.add_theme_font_size_override("font_size", 22)
	# Her colour is the hostile red the whole game reserves for MOTHER's processes,
	# never the player's amber phosphor. Paired with position + size, not colour
	# alone, so it reads without hue (the safety law's redundancy rule).
	_mother_label.add_theme_color_override("font_color", UiFx.HOSTILE)
	_mother_label.add_theme_constant_override("outline_size", 6)
	_mother_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_mother_label.modulate.a = 0.0
	_mother_label.text = ""
	# Onto the same overlay layer the notice label lives on, above the tube.
	var parent: Node = _notice_label.get_parent() if _notice_label != null else self
	parent.add_child(_mother_label)


## The Director spoke. Render the (already depth-corrupted) line; an address line —
## the callsign money moment — holds longer, reads larger, and only ever fires
## within the corpus budget the Director enforces. Subtitles-gated: A11y.subtitles
## owns MOTHER's authored text, so a player who has turned her captions off is not
## shown them.
func _on_mother_spoke(text: String, category: String, _tier: int, is_address: bool) -> void:
	if _mother_label == null or not A11y.subtitles:
		return
	_mother_is_address = is_address
	_mother_label.text = text
	# The reveal intensity is softened by Dampened Protocol (a big red line snapping
	# in is a jumpscare of its own); the hold and size grow for the rare address.
	var reveal: float = A11y.hunter_reveal_scale()
	_mother_label.add_theme_font_size_override("font_size", 30 if is_address else 22)
	_mother_hold = (5.5 if is_address else 3.2)
	_mother_clock = _mother_hold + 0.9
	_mother_label.scale = Vector2.ONE * (1.0 + 0.12 * reveal)
	if Debug.log_ai:
		print("[HUD] MOTHER (%s): %s" % [category, text])


func _update_mother(delta: float) -> void:
	if _mother_label == null or _mother_clock <= 0.0:
		return
	_mother_clock -= delta
	# Ease the reveal scale back to rest, and fade out over the tail.
	_mother_label.scale = _mother_label.scale.move_toward(Vector2.ONE, delta * 0.6)
	var fade: float = clampf(_mother_clock / 0.9, 0.0, 1.0)
	# An address line gets a faint red shiver while it holds — she is inside the
	# glass — capped small and a11y-scaled, never a flash.
	var jitter: float = 0.0
	if _mother_is_address and _mother_clock > 0.9:
		jitter = 1.2 * A11y.flash_scale * (1.0 - A11y.hunter_reveal_scale() * 0.4)
	_mother_label.position.x = (UiFx.hash01(floor(UiFx.clock() * 18.0)) - 0.5) * 2.0 * jitter
	_mother_label.modulate.a = fade
	if _mother_clock <= 0.0:
		_mother_label.text = ""
		_mother_label.position.x = 0.0


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
	_tilt(_kit_panel, -UiFx.CLUSTER_TILT_DEG)
	_tilt(_data_panel, UiFx.CLUSTER_TILT_DEG)

	_sheen(%CrewSheen, 0.55)
	_sheen(%CyclesSheen, -0.4)
	_sheen(%KitSheen, -0.35)
	_sheen(%DataSheen, 0.4)

	_capture_speck_regions()


## The readouts worth corrupting when the pool runs dry. Re-taken on resize with
## the cluster homes — same geometry, same staleness.
func _capture_speck_regions() -> void:
	# Only the persistent readouts carry dead pixels. The kit and the integrity arc
	# are hidden most of the time, and specks drawn over an empty corner read as a
	# bug rather than as decay.
	_specks.regions = [
		Rect2(_cycles_panel.position, _cycles_panel.size),
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


# ---------------------------------------------------------------- surfacing --
#
# The quiet-instrument rule (M4.9), made to run. The resting cluster — the Cycles
# ring, its numeral, the small buffered-data readout, the tiny layer tag — is
# always up. Every other element is a `UiFx.Surface`: hidden until it earns a
# frame, then faded. The pokes live in the update functions above (integrity while
# hurt, the kit while hot, a caption on a change, the roster on a crew change, the
# title on descent); this is where the alphas are ticked and where a capture pins
# or clears them so a `--hud-state` shot lands the same picture every machine.

func _build_surfaces() -> void:
	_srf_integrity = UiFx.Surface.new()
	_srf_kit = UiFx.Surface.new()
	_srf_crew = UiFx.Surface.new(UiFx.ROSTER_HOLD)
	_srf_title = UiFx.Surface.new(UiFx.TITLE_HOLD, UiFx.TITLE_RISE, UiFx.TITLE_FALL)
	_srf_link = UiFx.Surface.new()
	_srf_cycles_caption = UiFx.Surface.new(
			UiFx.CAPTION_HOLD, UiFx.SURFACE_RISE, UiFx.CAPTION_FALL)
	_srf_data_caption = UiFx.Surface.new(
			UiFx.CAPTION_HOLD, UiFx.SURFACE_RISE, UiFx.CAPTION_FALL)
	_srf_kit_label = UiFx.Surface.new(
			UiFx.CAPTION_HOLD, UiFx.SURFACE_RISE, UiFx.CAPTION_FALL)
	# Everything surface-managed starts dark. The .tscn already zeroes the two
	# top-level panels' modulate; the arc and the labels are zeroed here so the
	# very first frame (before the first tick) does not flash them.
	_integrity_arc.modulate.a = 0.0
	_kit_panel.modulate.a = 0.0
	_crew_cluster.modulate.a = 0.0
	_layer_label.modulate.a = 0.0
	_link_label.modulate.a = 0.0
	_cycles_caption.modulate.a = 0.0
	_cycles_cap.modulate.a = 0.0
	_data_caption.modulate.a = 0.0
	_kit_label.modulate.a = 0.0


## Ticks every surface and writes its alpha. Capture pins run first, so a
## `--hud-state` shot forces exactly the elements it is about and clears the rest
## — the picture never depends on which frame the shutter caught a fade on.
func _update_surfaces(delta: float) -> void:
	_apply_surface_capture()

	_crew_cluster.modulate.a = _srf_crew.tick(delta)
	_layer_label.modulate.a = _srf_title.tick(delta)
	_kit_panel.modulate.a = _srf_kit.tick(delta)
	_integrity_arc.modulate.a = _srf_integrity.tick(delta)
	_link_label.modulate.a = _srf_link.tick(delta)

	# Captions ride inside a cluster that is at full opacity once booted, so their
	# alpha is the surface's directly. The pool caption and its "/ 100" cap move
	# together — one label, told in two Labels.
	var cap: float = _srf_cycles_caption.tick(delta)
	_cycles_caption.modulate.a = cap
	_cycles_cap.modulate.a = cap
	_data_caption.modulate.a = _srf_data_caption.tick(delta)
	_kit_label.modulate.a = _srf_kit_label.tick(delta)


## The capture path for the surfacing layer. Each `--hud-state` names the elements
## it is a portrait of and silences the rest, the same discipline the boot and
## damage flinches already use. Values faked purely for the shutter (a wound the
## run did not take, a heat the breaker is not making) are set here and re-set
## every frame, so the picture is stable and the HUD stays a pure observer of Run.
func _apply_surface_capture() -> void:
	match Debug.hud_state:
		"resting":
			# The headline shot: genuinely near-empty. Only the resting cluster
			# survives — ring, numeral, tiny layer tag.
			_srf_integrity.clear()
			_srf_kit.clear()
			_srf_crew.clear()
			_srf_title.clear()
			_srf_link.clear()
			_srf_cycles_caption.clear()
			_srf_data_caption.clear()
			_srf_kit_label.clear()
		"descent":
			# The layer announcing itself: the big title up, the pool caption with
			# it, everything else quiet.
			_srf_title.pin()
			_srf_cycles_caption.pin()
			_srf_crew.clear()
			_srf_kit.clear()
			_srf_integrity.clear()
		"combat":
			# The breaker running hot. The kit surfaces and the heat bar is faked
			# near lockout for the shot — the same standing as the damage arc's
			# faked direction.
			_srf_kit.pin()
			_srf_kit_label.pin()
			_srf_title.clear()
			_srf_crew.clear()
			var track: Control = _heat_fill.get_parent_control()
			_heat_fill.size.x = float(track.size.x) * 0.82
			_heat_fill.color = COLOUR_AMBER
			_kit_label.text = "BREAKER"
			_kit_label.add_theme_color_override("font_color", COLOUR_DIM)
		"damaged":
			# Integrity surfaced and reading a wound. The arc value is faked the
			# same way the flinch fakes its direction — no shutter lands inside a
			# real hit by luck.
			_srf_integrity.pin()
			_integrity_arc.value = 0.58
			_integrity_arc.fill_color = COLOUR_AMBER
			_srf_title.clear()
			_srf_crew.clear()
			_srf_kit.clear()
		"full", "warn", "low":
			# Pool-level portraits (the settled HUD at N% Cycles). These are resting
			# shots at a pool level, so the transient elements are silenced and the
			# integrity arc and pool caption keep their natural logic — at a healthy
			# pool the arc stays hidden, and the band crossing surfaces the caption.
			_srf_crew.clear()
			_srf_title.clear()
			_srf_kit.clear()
			_srf_link.clear()
		_:
			pass


# --------------------------------------------------------------------- crew --

func _rebuild_crew() -> void:
	for child: Node in _crew_list.get_children():
		child.queue_free()
	_self_label = null

	var ids: Array = Net.crew.keys()
	ids.sort()
	for id: int in ids:
		_crew_list.add_child(_crew_row(int(id)))
	# The roster surfaces on any change — a join, a leave, a deletion — then fades.
	# DESIGN.md: "roster only on change". Guarded because Net.crew_changed can
	# arrive before _build_surfaces on a pathological early packet.
	if _srf_crew != null:
		_srf_crew.surface()
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
	label.add_theme_font_size_override("font_size", UiFx.FONT_BODY)
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
	tag.add_theme_font_size_override("font_size", UiFx.FONT_SMALL)
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

	# The diagnostics line ("LISTEN HOST · N CREW", link latency, OFFLINE) is
	# demoted out of the gameplay HUD — DESIGN.md M4.9: "demote debug-flavored
	# lines out of the gameplay HUD (keep in a debug overlay)". It shows
	# continuously only under `Debug.hud_debug`; otherwise it stays dark and
	# surfaces on its own merit — a link going bad is worth a word, "you are the
	# host" is not. The alpha is driven by `_srf_link` in `_update_surfaces`.
	if not Net.is_online:
		if Debug.hud_debug:
			_link_label.text = "OFFLINE"
			_link_label.add_theme_color_override("font_color", COLOUR_DIM)
			_srf_link.surface()
		else:
			_link_label.text = ""
		return

	var host: bool = multiplayer.is_server()
	var ping: int = 0 if host else Net.ping_ms(1)
	var text: String = "LISTEN HOST  ·  %d CREW" % Net.crew.size() if host \
			else "LINK %d ms" % ping
	var quality: Color = UiFx.SYSTEM
	if not host and ping > 120:
		quality = COLOUR_WARNING
	elif not host and ping > 60:
		quality = COLOUR_AMBER
	_link_label.add_theme_color_override("font_color", quality)

	# Re-poked every ping tick (0.5 s, inside the surface hold) so the overlay
	# holds solid while the debug flag is on; a bad link surfaces for its own sake.
	if Debug.hud_debug or (not host and ping > 120):
		_link_label.text = text
		_srf_link.surface()
	else:
		_link_label.text = ""


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

## PT2's minimap, built in code and parented to the SAFE-AREA root rather than to
## `Fixed`, because it is an INSTRUMENT: it belongs in the cluster with the Cycles
## gauge, inside the tube, subject to the same phosphor and the same 16:9 box.
## (`Fixed` is for things that must sit at the true centre of the frame — the
## reticle, the prompt, the pause plate.)
##
## Bottom-right, which is the one corner the M4.9 quiet-instrument pass left
## empty, and anchored so it stays in the corner of the SAFE BOX at every aspect.
## The widget resizes itself as it expands (see Minimap._process), so the anchors
## are bottom-right with offsets driven off its own size.
func _build_minimap() -> void:
	_minimap = Minimap.new()
	_minimap.name = "Minimap"
	_root.add_child(_minimap)
	_minimap.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_minimap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_minimap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# The widget re-solves its own offsets every frame as it morphs between the
	# corner and the expanded read; all it needs from here is where the corner is.
	_minimap.margin = MINIMAP_MARGIN


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
	_gate_title.add_theme_font_size_override("font_size", UiFx.FONT_HEAD)
	_gate_title.add_theme_color_override("font_color", COLOUR_WARNING)
	_gate_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_gate_title)

	_gate_body = Label.new()
	_gate_body.add_theme_font_size_override("font_size", UiFx.FONT_BODY)
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

	# What the button does now (see `_on_summary_pressed`). A run that ended inside
	# a live session goes HOME; one that ended without a session to go home to
	# still leaves. The label says which, because a button that reads DISCONNECT
	# and returns you to a room is a button nobody presses.
	_summary_button.disabled = false
	_summary_button.text = "RETURN TO THE PARTITION" \
			if Net.is_online and Run.configured else "DISCONNECT"
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


## Crossed into or out of THE PARTITION. Arriving home is the one thing that can
## dismiss the debrief other than the button on it, and it must — the run that
## overlay is about is two rooms behind us now.
func _on_hub_changed() -> void:
	if not Run.in_hub:
		return
	_summary.visible = false
	_pause.visible = false
	_debrief_clock = -1.0
	_exfil_label.text = ""
	_alert_label.text = ""
	_summary_button.disabled = false
	if DisplayServer.get_name() != "headless" and Debug.may_capture_mouse():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


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


## The debrief's button. THE PARTITION changed what "done with this run" means:
## it used to be the end of the session, and now it is a walk home.
##
## Any peer may ask; the host honours the first request and pulls the whole crew
## at once (`Run._return_request`), because arriving in the hub one at a time
## would be four different rooms. Whoever presses it does not get to leave early
## and does not get to strand anybody — which is the same rule the injection
## ritual runs at the other end of the loop.
##
## It still falls back to leaving outright when there is nothing to go home to:
## an offline scene run, or a session that has already been torn down under us.
func _on_summary_pressed() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if Net.is_online and Run.configured:
		_summary_button.disabled = true
		_summary_button.text = "RETURNING TO THE PARTITION"
		Run.request_return_to_hub()
		return
	Net.leave("YOU ABORTED THE INTRUSION")
