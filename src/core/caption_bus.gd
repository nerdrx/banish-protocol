extends Node
## CaptionBus — closed captions for the soundscape, and the deaf/HoH player's
## copy of the game's primary threat telegraph.
##
## See limbo-a11y/specs/03-captions.md. NULLVOID tells you "something is coming,
## from *there*" almost entirely through positional audio — a Scrubber
## chittering in the walls, the Sentinel's drone three rooms away, the lunge
## shriek 180 ms before the claws land. A player who cannot hear that is playing
## a different, unfair game. Captions give it back, as WHAT + WHERE + HOW CLOSE.
##
## ## One event, two outputs
##
## The safety rule the spec is built on: a caption and the sound it captions are
## the SAME event. They are emitted from the same call site — the AudioService
## helper — so they can never drift apart. AudioService plays the stream and, if
## the event carries a caption key, calls into here on the same line. This bus
## owns nothing about audio; it owns the label text, the bearing/distance maths
## against the local camera, and the on-screen stack.
##
## ## Two shapes of caption
##
##   * **Transient** (`emit`) — a discrete moment: a lunge shriek, an alert, a
##     kicked can. Pushed onto the stack with a lifetime; its bearing is frozen
##     at push time, which is correct for a thing that happened once.
##   * **Sustained** (`register`/`unregister`) — a loop that stays true while its
##     emitter exists: a skittering Scrubber, a Sentinel's presence drone. Its
##     bearing is recomputed every caption tick so the arrow tracks the source as
##     the player turns. The emitter (the creature) owns the registration for the
##     same lifetime it owns the looping AudioStreamPlayer3D.
##
## ## Category and colour-independence
##
## `THREAT` telegraphs danger and is always captioned when captions are on.
## `INFO` is a useful world event; `AMBIENT` is flavour, shown only under the
## "all sounds" scope. Per spec 02 the threat style must not rely on colour — a
## protanope has to be able to tell a threat from flavour — so threats are
## bracketed, bold, and carry a category glyph and a direction arrow. Colour is a
## fourth, redundant channel, never the only one.
##
## Rendering is a private CanvasLayer this autoload owns, styled to match the
## HUD's phosphor instrument (mono face, phosphor palette, a semi-opaque plate
## behind the text — a readability requirement, not decoration). It is
## deliberately independent of the per-layer Hud scene so a caption is never lost
## to a scene swap and the system is trivially testable headless.
##
## Telemetry-free and local: nothing here is networked. A player's use of
## captions is nobody else's business (spec 06).

## Threat telegraphs danger — always captioned when captions are on. Info is a
## useful world event; Ambient is flavour, shown only under the "all sounds"
## scope. The audio event table carries one of these per captioned event.
enum Cat { THREAT, INFO, AMBIENT }

## The caption string + category per event key. This is the label half of the
## shared event table (the audio half — streams, buses, attenuation — lives in
## AudioService). Direction and distance are appended at runtime. Kept here so
## the wording a HoH player reads is authored in one legible place, next to the
## category that decides whether it shows at all.
##
## The two-klaxon rule (spec 03) is a caption requirement, not just a mix one:
## the crew's own uplink klaxon and MOTHER's quarantine klaxon MUST read
## differently in text, or a deaf player loses a distinction the audio spends
## real effort drawing. Hence "Exfil klaxon — crew uplink" vs "Quarantine alarm
## — MOTHER", never two lines that both say "Alarm".
const TABLE: Dictionary = {
	# --- creatures (the threat language) ---
	&"scrubber_chitter": {"line": "Scrubber chittering", "cat": Cat.THREAT},
	&"scrubber_skitter": {"line": "Scrubber skittering", "cat": Cat.THREAT},
	&"scrubber_alert": {"line": "Scrubber alerted!", "cat": Cat.THREAT},
	# The single most important caption in the game: it fires with the shriek,
	# ~180 ms before the damage tick, so a deaf player gets the same "dodge NOW"
	# window a hearing one does.
	&"scrubber_lunge": {"line": "Scrubber lunging!", "cat": Cat.THREAT},
	&"sentinel_drone": {"line": "Sentinel nearby", "cat": Cat.THREAT},
	&"sentinel_scan": {"line": "Sentinel scanning — core exposed", "cat": Cat.THREAT},
	&"sentinel_shift": {"line": "Sentinel shifting", "cat": Cat.THREAT},
	&"sentinel_purge": {"line": "Sentinel PURGE!", "cat": Cat.THREAT},
	&"sentinel_alarm": {"line": "Quarantine alarm — MOTHER", "cat": Cat.THREAT},
	&"hound_howl": {"line": "The Hound howls", "cat": Cat.THREAT},
	&"hound_prowl": {"line": "Hound prowling", "cat": Cat.THREAT},
	# --- world threats (MOTHER hears these, or does these) ---
	&"siphon_channel": {"line": "Siphon channeling — pinging hunters", "cat": Cat.THREAT},
	&"debris": {"line": "Debris clatter", "cat": Cat.THREAT},
	&"bulkhead_reopen": {"line": "Bulkhead forcing open", "cat": Cat.THREAT},
	# --- info (useful, not dangerous) ---
	&"exfil_klaxon": {"line": "Exfil klaxon — crew uplink", "cat": Cat.INFO},
	&"exfil_countdown": {"line": "Exfil countdown", "cat": Cat.INFO},
	&"siphon_surge": {"line": "Siphon surge — Cycles refilled", "cat": Cat.INFO},
	&"descending": {"line": "Descending", "cat": Cat.INFO},
	&"backdoor_installed": {"line": "Backdoor installed — safe", "cat": Cat.INFO},
	&"breaker_fire": {"line": "Breaker firing", "cat": Cat.INFO},
	&"breaker_overheat": {"line": "Breaker overheated", "cat": Cat.INFO},
	&"flare_lit": {"line": "Flare lit", "cat": Cat.INFO},
	&"flare_dying": {"line": "Flare dying", "cat": Cat.INFO},
	&"weld": {"line": "Welding…", "cat": Cat.INFO},
	&"rewire": {"line": "Power rerouted", "cat": Cat.INFO},
	&"cabinet": {"line": "Cabinet opened", "cat": Cat.INFO},
	&"bulkhead_seal": {"line": "Bulkhead sealed", "cat": Cat.INFO},
	&"player_hurt": {"line": "You are hit", "cat": Cat.INFO},
	&"process_failing": {"line": "Your process is failing", "cat": Cat.INFO},
	&"you_are_down": {"line": "You are down", "cat": Cat.THREAT},
	&"restored": {"line": "Restored", "cat": Cat.INFO},
	&"decompiled": {"line": "Decompiled", "cat": Cat.INFO},
	# --- ambient (flavour; only under the "all sounds" scope) ---
	&"machinery": {"line": "Machinery hum", "cat": Cat.AMBIENT},
	&"data_chip": {"line": "Data chip", "cat": Cat.AMBIENT},
	&"footstep": {"line": "Footsteps", "cat": Cat.AMBIENT},
}

## Most lines get direction; a few never do, because they have no place in the
## world — they are the player's own body or the whole screen. A 2D emitter
## (breath, decompile) also suppresses direction by passing the camera position.
const NO_DIRECTION: Dictionary = {
	&"player_hurt": true, &"process_failing": true, &"you_are_down": true,
	&"restored": true, &"decompiled": true,
}

## Eight-way bearing glyphs, colour-free by construction (spec 02): a shape, not
## a hue. Index 0 is dead ahead, running clockwise.
const BEARINGS: Array[String] = [
	"▲", "◥", "►", "◢", "▼", "◣", "◄", "◤"]

## Category glyph — the second colour-independent channel. A threat reads as a
## threat from its bracket and this mark even in greyscale.
const CAT_GLYPH: Dictionary = {
	Cat.THREAT: "!", Cat.INFO: "·", Cat.AMBIENT: "∘",
}

## How long a transient caption holds before it fades, and the fade length. Long
## enough to read a threat under pressure; the lunge caption outlives its own
## 180 ms telegraph comfortably.
const HOLD_TIME: float = 2.4
const FADE_TIME: float = 0.6
## Sustained captions are recomputed at this rate rather than every frame — the
## bearing does not need 60 Hz, and this keeps the hot path free of per-frame
## string work (the 60 fps hold the milestone asks for).
const TICK: float = 0.15
## Distance buckets, as a fraction of the source's own max audible distance.
const CLOSE_FRAC: float = 0.30
const NEAR_FRAC: float = 0.66

## A live caption line on the stack. Transient ones count down `life`; sustained
## ones are pinned by a live registration and refreshed in place.
class Line extends RefCounted:
	var key: StringName = &""
	var cat: int = Cat.INFO
	var text: String = ""       ## Fully composed, incl. bearing + distance.
	var life: float = 0.0       ## Seconds left before fade-out (transient only).
	var sustained: bool = false ## True while a registration keeps it alive.
	var label: Label = null


## Registered sustained emitters: node -> {key, cat, ref}. Recomputed each tick.
var _registered: Dictionary = {}
## The visible stack, newest last. Bounded to `max_lines`.
var _lines: Array[Line] = []

# --- rendering surface (built lazily, once) ---------------------------------
var _layer: CanvasLayer = null
var _stack: VBoxContainer = null
var _font: Font = null
var _tick_clock: float = 0.0
var _built: bool = false


func _ready() -> void:
	# Cheap every frame; only does real work when there are lines up or captions
	# are enabled. Left on always so a caption can appear the instant one is
	# emitted, in the menu or in a layer.
	set_process(true)


## Transient caption for a discrete sound. Called by AudioService on the same
## line it plays the stream, so the two are one event. `ref_dist` is the source's
## own max audible distance (from the audio event), used to bucket close/near/far
## — "far" is a real signal here: a Sentinel drone *far* means "don't go that
## way", *close* means "leave now".
func emit(key: StringName, world_pos: Vector3, ref_dist: float = 25.0) -> void:
	if not _should_show(key):
		return
	var entry: Dictionary = TABLE[key]
	var line: Line = Line.new()
	line.key = key
	line.cat = int(entry["cat"])
	line.text = _compose(key, int(entry["cat"]), world_pos, ref_dist)
	line.life = HOLD_TIME + FADE_TIME
	_ensure_built()
	_push(line)
	if Debug.log_ai:
		print("[Caption] %s" % line.text)


## Register a sustained emitter (a looping threat). The caption stays up, its
## bearing tracking `node`, until `unregister`. The emitter owns this for exactly
## as long as it owns its looping sound — see AudioService.attach_loop.
func register(node: Node3D, key: StringName, ref_dist: float = 25.0) -> void:
	if node == null or not TABLE.has(key):
		return
	_registered[node] = {"key": key, "ref": ref_dist}


## Drop an emitter. The line itself is reaped in `_refresh_sustained` once no
## registered emitter still carries its key — two skittering Scrubbers share one
## "Scrubber skittering" line, and it must survive the first one leaving.
func unregister(node: Node) -> void:
	_registered.erase(node)


## Whether this key should show at all, given the player's caption settings. A11y
## owns the toggles (spec 06 — one store); this is a pure read.
func _should_show(key: StringName) -> bool:
	if not A11y.sound_captions or not TABLE.has(key):
		return false
	var cat: int = int(TABLE[key]["cat"])
	if cat == Cat.THREAT:
		return true                       # threats always, the whole point.
	if cat == Cat.AMBIENT:
		return A11y.caption_all_sounds    # flavour only under "all sounds".
	return true                           # info always when captions on.


## Compose the full line: "[◄ Scrubber lunging! · near]" for a threat, or a
## plainer "Descending →" for info. Bracket + glyph for threats so the category
## survives greyscale.
func _compose(key: StringName, cat: int, world_pos: Vector3, ref_dist: float) -> String:
	var body: String = String(TABLE[key]["line"])
	var bearing: String = ""
	var distance: String = ""
	if A11y.caption_directional and not NO_DIRECTION.has(key):
		bearing = _bearing_to(world_pos)
	if A11y.caption_distance and not NO_DIRECTION.has(key):
		distance = _distance_bucket(world_pos, ref_dist)

	var parts: PackedStringArray = PackedStringArray()
	if not bearing.is_empty():
		parts.append(bearing)
	parts.append(body)
	if not distance.is_empty():
		parts.append("· " + distance)

	var text: String = " ".join(parts)
	if cat == Cat.THREAT:
		return "[ %s ]" % text
	return text


## Bearing glyph from the source to the listener's camera. Projects the
## source→camera vector onto the camera's own right/forward and thresholds into
## one of eight sectors. No camera (a menu, a headless run) -> no bearing.
func _bearing_to(world_pos: Vector3) -> String:
	var cam: Camera3D = _camera()
	if cam == null:
		return ""
	var to_source: Vector3 = world_pos - cam.global_position
	to_source.y = 0.0
	if to_source.length_squared() < 0.01:
		return ""
	var basis: Basis = cam.global_transform.basis
	var right: float = to_source.dot(basis.x)
	var forward: float = to_source.dot(-basis.z)
	# 0 = ahead, clockwise. +right is clockwise, so atan2(right, forward).
	var angle: float = atan2(right, forward)
	var sector: int = int(round(angle / (TAU / 8.0)))
	return BEARINGS[posmod(sector, 8)]


## close / near / far, bucketed against the source's own max audible distance so
## the word means the same thing for a near-field cabinet and a room-away drone.
func _distance_bucket(world_pos: Vector3, ref_dist: float) -> String:
	var cam: Camera3D = _camera()
	if cam == null:
		return ""
	var d: float = cam.global_position.distance_to(world_pos)
	var span: float = maxf(ref_dist, 1.0)
	if d <= span * CLOSE_FRAC:
		return "close"
	if d <= span * NEAR_FRAC:
		return "near"
	return "far"


func _camera() -> Camera3D:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var vp: Viewport = tree.root.get_viewport()
	return vp.get_camera_3d() if vp != null else null


func _process(delta: float) -> void:
	# Sustained emitters: recompute bearings a few times a second, and reap any
	# whose node has gone.
	_tick_clock -= delta
	if _tick_clock <= 0.0:
		_tick_clock = TICK
		_refresh_sustained()

	if _lines.is_empty():
		return
	var dead: Array[Line] = []
	for line: Line in _lines:
		if line.sustained:
			continue  # pinned; refreshed by _refresh_sustained.
		line.life -= delta
		if line.life <= 0.0:
			dead.append(line)
		elif line.label != null:
			line.label.modulate.a = clampf(line.life / FADE_TIME, 0.0, 1.0)
	for line: Line in dead:
		_remove(line)


## Keep one live line per active caption KEY (not per emitter), bearing refreshed
## from the nearest registered emitter carrying it. Emitters whose node died are
## dropped, and any sustained line whose key is no longer represented starts
## fading. Bounded and string-light: it only composes when captions are on.
func _refresh_sustained() -> void:
	var gone: Array = []
	var active_keys: Dictionary = {}
	for node: Variant in _registered:
		var n: Node3D = node as Node3D
		if n == null or not is_instance_valid(n):
			gone.append(node)
			continue
		var info: Dictionary = _registered[node]
		var key: StringName = info["key"]
		if not _should_show(key):
			continue
		active_keys[key] = true
		var text: String = _compose(key, int(TABLE[key]["cat"]),
				n.global_position, float(info["ref"]))
		_upsert_sustained(key, int(TABLE[key]["cat"]), text)
	for node: Variant in gone:
		_registered.erase(node)
	# Any sustained line whose key no longer has a live, shown emitter fades out.
	for line: Line in _lines:
		if line.sustained and not active_keys.has(line.key):
			line.sustained = false
			line.life = FADE_TIME


func _upsert_sustained(key: StringName, cat: int, text: String) -> void:
	for line: Line in _lines:
		if line.sustained and line.key == key:
			if line.text != text:
				line.text = text
				if line.label != null:
					line.label.text = text
			return
	var line: Line = Line.new()
	line.key = key
	line.cat = cat
	line.text = text
	line.sustained = true
	_ensure_built()
	_push(line)


# --------------------------------------------------------------- rendering --

## Build the overlay the first time a caption actually needs to show. Nothing is
## created for a player who never turns captions on.
func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_font = load("res://assets/fonts/ui_font.tres") as Font

	_layer = CanvasLayer.new()
	_layer.name = "CaptionLayer"
	# Above the HUD's own composite but below nothing that matters; captions are
	# a safety readout and should not be occluded.
	_layer.layer = 64
	add_child(_layer)

	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	margin.anchor_top = 1.0
	margin.offset_top = -220.0
	margin.offset_bottom = -28.0
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(margin)

	_stack = VBoxContainer.new()
	_stack.alignment = BoxContainer.ALIGNMENT_END
	_stack.add_theme_constant_override("separation", 4)
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_stack)


func _push(line: Line) -> void:
	line.label = _make_label(line)
	_stack.add_child(line.label)
	_lines.append(line)
	# Newest at the bottom; oldest transient falls off the top past max_lines.
	while _lines.size() > A11y.caption_max_lines:
		var oldest: Line = _lines[0]
		if oldest.sustained and _lines.size() <= _registered.size():
			break  # do not evict a live threat for another live threat.
		_remove(oldest)


func _make_label(line: Line) -> Label:
	var label: Label = Label.new()
	label.text = line.text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size",
			_size_px(A11y.caption_size))
	# A threat is bracketed, brighter and carries a warm alarm tint; info/ambient
	# sit back in the phosphor DIM. Colour is redundant to the bracket + glyph, so
	# a player who cannot see the tint still reads the category.
	var colour: Color = UiFx.TEXT if line.cat == Cat.THREAT else UiFx.DIM
	label.add_theme_color_override("font_color", colour)
	# The readability plate the spec requires: a semi-opaque backing so a caption
	# stays legible over a bright muzzle flash or a lit vault.
	var plate: StyleBoxFlat = StyleBoxFlat.new()
	plate.bg_color = Color(0.02, 0.02, 0.03, 0.62 * A11y.caption_bg_opacity)
	plate.content_margin_left = 10.0
	plate.content_margin_right = 10.0
	plate.content_margin_top = 3.0
	plate.content_margin_bottom = 3.0
	if line.cat == Cat.THREAT:
		# A left edge in the alarm hue — one more redundant channel, and it reads
		# as "urgent" without being the only thing that does.
		plate.border_width_left = 3
		plate.border_color = UiFx.HOSTILE
	label.add_theme_stylebox_override("normal", plate)
	return label


func _size_px(size: int) -> int:
	match size:
		0: return 15   # S
		2: return 25   # L
		_: return 19   # M (default)


func _remove(line: Line) -> void:
	_lines.erase(line)
	if line.label != null and is_instance_valid(line.label):
		line.label.queue_free()


## Test/instrumentation: how many caption lines are currently up. Read by the
## staged-Scrubber capture check so "captions appeared" is a number, not a claim
## about a screenshot.
func active_count() -> int:
	return _lines.size()
