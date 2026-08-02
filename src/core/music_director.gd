extends Node
## MusicDirector (autoload `Music`) — the adaptive score.
##
## See limbo-music/MUSIC_GUIDE.md. Two independent axes drive the dive music,
## sharing D as a tonal centre so any combination sums without a key clash:
##
##   DEPTH   — where you are. ONE floor bed at a time (surface / mid / deep),
##             crossfaded at a band boundary, exactly like the shipped room tones.
##   STRESS  — the hunt. The Director's stress value in [0,1] gates how many
##             stress stems stack OVER the floor: +tension (0.25) → +threat
##             (0.55) → +terror (0.80). Additive — intensity accumulates.
##
## M6's real Director does not exist yet, so stress is derived here from a proxy
## (nearest antivirus, count in the room, combat recency, low Cycles) and exposed
## as `set_stress(0..1)` so M6 can seize the wheel later by calling one method.
##
## ## Phase-lock without beat-matching code
##
## Every dive stem is exactly 48.000 s = 16 bars @ 80 BPM. Started on the same
## frame (even at −80 dB) and never stopped, they stay locked forever — this
## director only ever animates `volume_db`. No clock, no re-sync, no drift. The
## register-split anti-mud discipline is the stems' own (each owns a cleared
## band); all this has to do is not fight it, which "animate only volume" does.
##
## ## The moments
##
##   * **Depth change** — crossfade the outgoing floor to the incoming over ~2 s.
##   * **Sanctuary** (a rooted backdoor room) — the whole stack ducks and
##     `mus_sanctuary_theme` rises: the score going consonant IS the reward.
##   * **Exfil** — the window opening crossfades the dive stack into
##     `mus_exfil_build`; success chains `exfil_escape → debrief`, failure
##     `exfil_fail → wipe`, handing off to the shipped stings.
##   * **Hunters** (M6) — `play_hunter()` is wired and dormant.
##
## Local and cosmetic: touches no run state, no RNG, no wire. Muted with the rest
## under `Debug.automated` via the Master bus (AudioService owns that).

const DIR: String = "res://assets/audio/music/"

# --- tuning -----------------------------------------------------------------
const FULL_DB: float = 0.0
const OFF_DB: float = -80.0
## Stress tier thresholds and their fade rates (MUSIC_GUIDE's Director sketch).
## `off` uses hysteresis (on − 0.05) so a stat hovering on a boundary does not
## flutter a layer in and out.
const TIERS: Array = [
	{"stem": &"tension", "on": 0.25, "in": 3.0, "out": 4.0},
	{"stem": &"threat", "on": 0.55, "in": 3.0, "out": 4.0},
	{"stem": &"terror", "on": 0.80, "in": 2.0, "out": 5.0},
]
const HYSTERESIS: float = 0.05
## Crossfade time for the depth floor and the sanctuary swap.
const FLOOR_FADE: float = 2.0
const SANCTUARY_FADE: float = 2.0
## Depth bands (DESIGN.md / LayerParams): 1–5 surface, 6–14 mid, 15+ deep.
const BAND_MID: int = 6
const BAND_DEEP: int = 15

# --- players (all 2D, non-positional; on the Mus* sub-buses) -----------------
## Floor beds, one live at a time. Key -> player.
var _floors: Dictionary = {}
## Stress stems, all started together and left running.
var _stems: Dictionary = {}
var _menu: AudioStreamPlayer = null
var _sanctuary: AudioStreamPlayer = null
var _exfil_build: AudioStreamPlayer = null

# --- state ------------------------------------------------------------------
enum Mode { SILENT, MENU, DIVE, SANCTUARY, EXFIL, ENDED }
var _mode: int = Mode.SILENT
## Which depth floor should currently be up.
var _floor_key: StringName = &""
## Live stress in [0,1]. `_stress_override` >= 0 means M6 (or a test) has taken
## the wheel and the proxy is ignored.
var _stress: float = 0.0
var _stress_override: float = -1.0
## Whether each tier is currently latched on, for the hysteresis.
var _tier_on: Array[bool] = [false, false, false]
## Combat recency: seconds since the last damage or kill, for the proxy.
var _combat_recency: float = 99.0


func _ready() -> void:
	_build_players()
	Run.config_changed.connect(_on_config_changed)
	Run.layer_changed.connect(_on_layer_changed)
	Run.backdoor_rooted_changed.connect(_on_backdoor_changed)
	Run.exfil_changed.connect(_on_exfil_changed)
	Run.run_ended.connect(_on_run_ended)
	Run.damaged.connect(func(_from: Vector3) -> void: _combat_recency = 0.0)
	Run.process_deleted.connect(func(_by: int, _kind: String) -> void: _combat_recency = 0.0)
	set_process(true)


func _build_players() -> void:
	# Depth floors + neutral base, on MusFloor.
	for pair: Array in [[&"surface", "mus_amb_surface.ogg"], [&"mid", "mus_amb_mid.ogg"],
			[&"deep", "mus_amb_deep.ogg"], [&"base", "mus_dive_base.ogg"]]:
		_floors[pair[0]] = _make(pair[1], Audio.BUS_MUS_FLOOR, true)
	# Stress stems, on MusStress.
	for pair: Array in [[&"tension", "mus_dive_tension.ogg"], [&"threat", "mus_dive_threat.ogg"],
			[&"terror", "mus_dive_terror.ogg"]]:
		_stems[pair[0]] = _make(pair[1], Audio.BUS_MUS_STRESS, true)
	_sanctuary = _make("mus_sanctuary_theme.ogg", Audio.BUS_MUS_FLOOR, true)
	_exfil_build = _make("mus_exfil_build.ogg", Audio.BUS_MUS_STRESS, true)
	_menu = _make("mus_main_menu_theme.ogg", Audio.BUS_MUS_FLOOR, true)


func _make(file: String, bus: StringName, loop: bool) -> AudioStreamPlayer:
	var p: AudioStreamPlayer = AudioStreamPlayer.new()
	p.name = file.get_basename()
	var stream: AudioStream = load(DIR + file) as AudioStream
	if stream != null and loop and stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	p.stream = stream
	p.bus = bus
	p.volume_db = OFF_DB
	add_child(p)
	return p


# ------------------------------------------------------------- public API --

## The main menu calls this on entry. Plays the 144 s menu theme and stops any
## dive stack left over from a finished run.
func enter_menu() -> void:
	_mode = Mode.MENU
	_stop_all(true)
	_play(_menu)


## M6 hook: drive stress directly. Passing < 0 hands the wheel back to the proxy.
func set_stress(value: float) -> void:
	_stress_override = -1.0 if value < 0.0 else clampf(value, 0.0, 1.0)


## Looping hunter stingers, kept so they can be stopped when the hunter leaves or
## the crew descends. The one-shots (Hound howl, Moth) free themselves.
var _hunter_stingers: Dictionary = {}


## M6 hook: a hunter appeared. Fires its leitmotif on MusStinger. The Auditor
## loops under the stack (its audit is a sustained presence); the others are
## one-shots. Activated by the HauntDirector (M5 wired these dormant).
func play_hunter(kind: StringName) -> void:
	var file: String = ""
	match kind:
		&"hound": file = "mus_hunter_hound.ogg"
		&"moth": file = "mus_hunter_moth.ogg"
		&"auditor": file = "mus_hunter_auditor.ogg"
		_: return
	# A looping stinger already up (a second Auditor, or a re-announce) must not
	# stack a second forever-loop over the first.
	if kind == &"auditor" and _hunter_stingers.has(kind) \
			and is_instance_valid(_hunter_stingers[kind]):
		return
	var sting: AudioStreamPlayer = _make(file, Audio.BUS_MUS_STINGER, kind == &"auditor")
	sting.volume_db = FULL_DB
	sting.play()
	if kind == &"hound":
		# The howl is a spotlight: duck the beds under it (MUSIC_GUIDE).
		Audio.set_music_duck(&"hound", -6.0)
	if kind == &"auditor" and sting.stream is AudioStreamOggVorbis:
		_hunter_stingers[kind] = sting
	else:
		sting.finished.connect(func() -> void:
			Audio.set_music_duck(&"hound", 0.0)
			sting.queue_free())


## M6 hook: a hunter left (killed, slunk, or the crew descended). Stops its
## looping stinger; one-shots are already gone. Idempotent.
func stop_hunter(kind: StringName) -> void:
	if not _hunter_stingers.has(kind):
		return
	var sting: AudioStreamPlayer = _hunter_stingers[kind]
	_hunter_stingers.erase(kind)
	if sting != null and is_instance_valid(sting):
		sting.stop()
		sting.queue_free()


## Every looping hunter stinger, silenced. Called on descent — the stingers belong
## to the layer being left.
func _stop_all_hunters() -> void:
	for kind: StringName in _hunter_stingers.keys():
		stop_hunter(kind)


# --------------------------------------------------------------- run glue --

func _on_config_changed() -> void:
	if not Run.configured:
		return
	_enter_dive()


func _enter_dive() -> void:
	_mode = Mode.DIVE
	_play(null)  # ensure processing
	_menu.volume_db = OFF_DB
	_sanctuary.volume_db = OFF_DB
	_exfil_build.volume_db = OFF_DB
	# Start every stress stem NOW, at silence, so they phase-lock for the whole
	# descent; the proxy raises them. The floor for the current band comes up.
	for stem: StringName in _stems:
		_start_silent(_stems[stem])
	_floor_key = _band_floor(Run.layer_number)
	for key: StringName in _floors:
		var p: AudioStreamPlayer = _floors[key]
		_start_silent(p)
		p.volume_db = OFF_DB
	# Snap the chosen floor up immediately on a fresh injection (no crossfade from
	# nothing); depth changes mid-run crossfade in `_on_layer_changed`.
	_floors[_floor_key].volume_db = FULL_DB


func _on_layer_changed(next_layer: int) -> void:
	if _mode == Mode.ENDED:
		return
	if _mode != Mode.DIVE and _mode != Mode.SANCTUARY and _mode != Mode.EXFIL:
		return
	# A descent leaves sanctuary/exfil and returns to the dive floor for the band.
	# Any looping hunter stinger belonged to the layer we just left.
	_stop_all_hunters()
	_mode = Mode.DIVE
	var want: StringName = _band_floor(next_layer)
	if want != _floor_key:
		_floor_key = want
	# The exfil/sanctuary overlays fade back down; the target floor fades up. All
	# handled by `_process` chasing targets.


func _on_backdoor_changed() -> void:
	# Rooting the node makes the room the campfire (DESIGN.md: sanctuary is
	# sacred). The score going consonant is the reward.
	if Run.backdoor_rooted and _mode == Mode.DIVE:
		_mode = Mode.SANCTUARY
	elif not Run.backdoor_rooted and _mode == Mode.SANCTUARY:
		_mode = Mode.DIVE


func _on_exfil_changed() -> void:
	if Run.exfil_calling and _mode != Mode.EXFIL:
		_mode = Mode.EXFIL
		_start_silent(_exfil_build)
	elif not Run.exfil_calling and _mode == Mode.EXFIL and not Run.run_over:
		_mode = Mode.DIVE


func _on_run_ended(summary: Dictionary) -> void:
	_mode = Mode.ENDED
	_stop_all_hunters()
	_stop_all(false)  # fade the dive stack out under the sting.
	var ok: bool = bool(summary.get("success", false))
	# Exfil release → debrief, or the caught-at-the-threshold collapse → wipe.
	# One-shots on MusStinger; the shipped stings live in the audio library, so
	# they play through AudioService's 2D path onto the same bus.
	if ok:
		_sting("mus_exfil_escape.ogg")
		_chain_after("mus_exfil_escape.ogg", "mus_debrief_sting.ogg")
	else:
		_sting("mus_exfil_fail.ogg")
		_chain_after("mus_exfil_fail.ogg", "mus_wipe_sting.ogg")


func _sting(file: String) -> AudioStreamPlayer:
	var p: AudioStreamPlayer = _make(file, Audio.BUS_MUS_STINGER, false)
	p.volume_db = FULL_DB
	p.play()
	p.finished.connect(p.queue_free)
	return p


## Play `second` when `first` finishes — the escape→debrief / fail→wipe handoff.
func _chain_after(first: String, second: String) -> void:
	var lead: AudioStreamPlayer = _make(first, Audio.BUS_MUS_STINGER, false)
	lead.volume_db = FULL_DB
	lead.play()
	lead.finished.connect(func() -> void:
		_sting(second)
		lead.queue_free())


# --------------------------------------------------------------- process --

func _process(delta: float) -> void:
	if _mode == Mode.SILENT:
		return
	_combat_recency = minf(_combat_recency + delta, 99.0)

	# Resolve stress: M6's override, or our proxy.
	if _mode == Mode.DIVE or _mode == Mode.EXFIL:
		var target: float = _stress_override if _stress_override >= 0.0 else _proxy_stress()
		_stress = lerpf(_stress, target, 1.0 - exp(-3.0 * delta))
	elif _mode == Mode.SANCTUARY:
		_stress = lerpf(_stress, 0.0, 1.0 - exp(-2.0 * delta))

	_drive_stems(delta)
	_drive_floors(delta)
	_drive_overlays(delta)


## The stress stack, with hysteresis on each tier so a boundary hover does not
## strobe a layer. Only `volume_db` moves; the stems stay phase-locked.
func _drive_stems(delta: float) -> void:
	# In the menu / ended, everything stress is silent.
	var active: bool = _mode == Mode.DIVE or _mode == Mode.EXFIL
	for i: int in TIERS.size():
		var tier: Dictionary = TIERS[i]
		var on_threshold: float = float(tier["on"])
		var off_threshold: float = on_threshold - HYSTERESIS
		if active:
			if _tier_on[i] and _stress < off_threshold:
				_tier_on[i] = false
			elif not _tier_on[i] and _stress >= on_threshold:
				_tier_on[i] = true
		else:
			_tier_on[i] = false
		var want: bool = _tier_on[i]
		var rate_s: float = float(tier["in"]) if want else float(tier["out"])
		_chase_db(_stems[tier["stem"]], FULL_DB if want else OFF_DB, rate_s, delta)


func _drive_floors(delta: float) -> void:
	# In a dive the band floor is up unless sanctuary has taken over; elsewhere all
	# floors fade out.
	var live: StringName = _floor_key if (_mode == Mode.DIVE or _mode == Mode.EXFIL) else &""
	# In sanctuary the depth floor stays quietly under the sanctuary theme.
	if _mode == Mode.SANCTUARY:
		live = _floor_key
	for key: StringName in _floors:
		var target: float = FULL_DB if key == live and _mode != Mode.SANCTUARY else OFF_DB
		if _mode == Mode.SANCTUARY and key == _floor_key:
			target = -14.0  # sits under the sanctuary theme rather than vanishing.
		_chase_db(_floors[key], target, 1.0 / FLOOR_FADE, delta)


func _drive_overlays(delta: float) -> void:
	# Menu theme.
	_chase_db(_menu, FULL_DB if _mode == Mode.MENU else OFF_DB, 1.5, delta)
	# Sanctuary theme.
	_chase_db(_sanctuary, FULL_DB if _mode == Mode.SANCTUARY else OFF_DB, 1.0 / SANCTUARY_FADE, delta)
	# Exfil build: up during the countdown; terror layers over it as the clock
	# runs down (handled by the stress proxy climbing). Down otherwise.
	_chase_db(_exfil_build, FULL_DB if _mode == Mode.EXFIL else OFF_DB, 0.8, delta)


## The stress proxy (this milestone's stand-in for M6's Director). Four inputs,
## each a fear the real Director will also weigh: how close the nearest hunter
## is, how many share your room, how recently you fought, and how low the clock
## is. Combined and clamped to [0,1]; M6 replaces this with `set_stress`.
func _proxy_stress() -> float:
	var player: Node3D = _local_body()
	if player == null:
		return 0.0

	var nearest: float = 1e9
	var in_room: int = 0
	var here_room: int = _room_of(player)
	for node: Node in get_tree().get_nodes_in_group(Antivirus.GROUP):
		var creature: Antivirus = node as Antivirus
		if creature == null or not is_instance_valid(creature):
			continue
		var d: float = creature.global_position.distance_to(player.global_position)
		nearest = minf(nearest, d)
		if here_room >= 0 and creature.current_room() == here_room:
			in_room += 1

	# Proximity: 0 at the hearing range, 1 on top of you.
	var prox: float = 0.0
	if nearest < 1e9:
		prox = clampf(inverse_lerp(Balance.SCRUBBER_HEAR_RANGE, 4.0, nearest), 0.0, 1.0)
	# Company in the room: each one adds, saturating at ~three.
	var crowd: float = clampf(float(in_room) / 3.0, 0.0, 1.0)
	# Combat recency: full for the first ~4 s after a hit or a kill, decaying.
	var combat: float = clampf(1.0 - _combat_recency / 8.0, 0.0, 1.0)
	# Low Cycles: the clock itself is dread once it dips under a quarter.
	var starving: float = 0.0
	if Run.configured and Run.fraction() < Balance.CYCLES_WARNING_FRACTION:
		starving = inverse_lerp(Balance.CYCLES_WARNING_FRACTION, 0.0, Run.fraction())

	# Weighted blend. Proximity and combat lead; crowd and starvation push it over
	# the top into terror. Capped at 1.
	return clampf(0.55 * prox + 0.30 * combat + 0.28 * crowd + 0.25 * starving, 0.0, 1.0)


# --------------------------------------------------------------- helpers --

func _band_floor(layer: int) -> StringName:
	if layer >= BAND_DEEP:
		return &"deep"
	if layer >= BAND_MID:
		return &"mid"
	return &"surface"


func _local_body() -> Node3D:
	var node: Node = Net.get_player(Net.local_id())
	return node as Node3D if node is Node3D and is_instance_valid(node) else null


func _room_of(body: Node3D) -> int:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null:
		return -1
	var graph: Variant = layer.get("graph") if layer.has_method("get") else null
	if graph == null or not (graph as Object).has_method("region_of"):
		return -1
	return int(graph.region_of(body.global_position))


func _chase_db(player: AudioStreamPlayer, target_db: float, rate: float, delta: float) -> void:
	if player == null:
		return
	if target_db > OFF_DB + 1.0 and not player.playing:
		_start_silent(player)
	# Rate is in dB-fraction per second; move_toward gives a linear dB ramp, which
	# is the equal-power-ish curve the guide's sketch uses.
	var step: float = absf(FULL_DB - OFF_DB) * rate * delta
	player.volume_db = move_toward(player.volume_db, target_db, step)
	if player.volume_db <= OFF_DB + 0.5 and player.playing and target_db <= OFF_DB:
		player.stop()


func _start_silent(player: AudioStreamPlayer) -> void:
	if player != null and not player.playing:
		player.volume_db = OFF_DB
		player.play()


func _play(player: AudioStreamPlayer) -> void:
	if player != null and not player.playing:
		player.volume_db = FULL_DB
		player.play()


func _stop_all(hard: bool) -> void:
	for key: StringName in _stems:
		if hard:
			(_stems[key] as AudioStreamPlayer).stop()
	for key: StringName in _floors:
		if hard:
			(_floors[key] as AudioStreamPlayer).stop()
	if hard:
		_sanctuary.stop()
		_exfil_build.stop()
	# On a soft stop the `_process` chase pulls everything to silence; on ENDED we
	# stop feeding targets so the stings own the field.
