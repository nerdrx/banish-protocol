extends Node
## AudioService (autoload `Audio`) — the game's voice, in one place.
##
## M5 gives NULLVOID its sound. This service owns the mixer, the event table
## (limbo-audio/AUDIO_GUIDE.md), the pools that play it, and the small helper
## every call site uses so that playing a sound and captioning it are a single
## line. It is the "audio helper" spec 03 rides on for free — a caption is a
## column of the event table, emitted at the same call as the stream.
##
## ## Three hard rules it keeps
##
##   1. **It never touches the RNG stream or replicated state.** Sound is local
##      and cosmetic (DESIGN.md's determinism law). Shuffle-bags and pitch jitter
##      draw from a PRIVATE `RandomNumberGenerator` seeded off wall time, never
##      `Rng` — so two peers picking different footstep variants cannot desync a
##      run, and the determinism dump is byte-identical with audio on or off.
##   2. **No per-frame allocation in the hot path.** Players are pooled and
##      reused; streams are loaded once and cached; the `_process` mixer work is
##      arithmetic on a handful of bus volumes. Audio is cheap and stays cheap
##      (the 60 fps hold).
##   3. **Automation-safe.** Under `Debug.automated` the Master bus is muted, so
##      a windowed capture on a live desktop makes no noise — but the streams
##      still resolve and play (silently) and every trigger still logs under
##      `--log-audio`, which is how "sources fire, no missing streams" is
##      verified without anyone having to listen.
##
## ## The bus layout (built here, at runtime)
##
##   Master
##    ├── Music      -4   (ducked by alarms / decompile)
##    │    ├── MusFloor   -3   depth beds / dive_base / sanctuary
##    │    ├── MusStress   0   tension / threat / terror / auditor
##    │    └── MusStinger -1   hunter motifs, exfil escape/fail, stings
##    ├── World      -1   ambient, world, weapons     ← HighPass 35 Hz
##    │    └── Beds   -3   ambient beds (duck independently)
##    ├── Creatures   0
##    ├── Player      0   2D self sounds (breath, pulse, hurt)
##    └── UI         -2   ui/*, chips, key clicks, ticks
##
## Built in code rather than shipped as a `default_bus_layout.tres` for the same
## reason the props and the HUD tube are: it is legible, diffable, headless-safe,
## and lets the Dampened-Protocol effects be wired to named handles here instead
## of hidden in a binary resource.

# --- bus names (one source of truth; MusicDirector reads these too) ----------
const BUS_MASTER: StringName = &"Master"
const BUS_MUSIC: StringName = &"Music"
const BUS_MUS_FLOOR: StringName = &"MusFloor"
const BUS_MUS_STRESS: StringName = &"MusStress"
const BUS_MUS_STINGER: StringName = &"MusStinger"
const BUS_WORLD: StringName = &"World"
const BUS_BEDS: StringName = &"Beds"
const BUS_CREATURES: StringName = &"Creatures"
const BUS_PLAYER: StringName = &"Player"
const BUS_UI: StringName = &"UI"

## Base trim per bus (AUDIO_GUIDE layout). The user volume sliders are an offset
## ON TOP of these; a bus's live volume is base + slider trim.
const BUS_BASE: Dictionary = {
	BUS_MASTER: 0.0, BUS_MUSIC: -4.0, BUS_MUS_FLOOR: -3.0, BUS_MUS_STRESS: 0.0,
	BUS_MUS_STINGER: -1.0, BUS_WORLD: -1.0, BUS_BEDS: -3.0, BUS_CREATURES: 0.0,
	BUS_PLAYER: 0.0, BUS_UI: -2.0,
}

const AUDIO_DIR: String = "res://assets/audio/"
const SETTINGS_PATH: String = "user://settings.cfg"

## Pool sizes. A firefight with a Sentinel, a pack and a bed rarely needs more
## than this many simultaneous one-shots; when it does, the oldest is stolen.
const POOL_3D: int = 28
const POOL_2D: int = 16

## The CRT flyback whine lives at 15.734 kHz, baked into the menu bed. Killing it
## is a surgical notch there (AUDIO_GUIDE weakness #4 — an age lottery).
const WHINE_HZ: float = 15734.0
## Dampened Protocol / reduced-spikes low-pass corner (spec 05: 6 kHz on
## Creatures + UI).
const DAMP_LP_HZ: float = 6000.0

## One captioned, mixable sound. The table below is a set of these; a call site
## names a key and this carries everything about how it plays and how it reads.
class AudioEvent extends RefCounted:
	var key: StringName = &""
	var files: PackedStringArray = PackedStringArray()
	var bus: StringName = BUS_WORLD
	var loop: bool = false
	var twod: bool = false          ## 2D (non-positional) feedback/self sound.
	var unit: float = 6.0           ## AudioStreamPlayer3D unit_size (the dial).
	var max_dist: float = 32.0
	var vol: float = 0.0            ## volume_db exception (else 0, mix at bus).
	var jitter: float = 0.0        ## ± pitch_scale, for sets that must not tire.
	var doppler: bool = false
	var caption: StringName = &""  ## CaptionBus key, or empty for silent-to-text.


## key -> AudioEvent. Built once in `_ready`.
var _events: Dictionary = {}
## file path -> loaded AudioStream, cached. Loop flag applied on first load.
var _streams: Dictionary = {}
## key -> shuffle-bag index array + cursor, so a variant never repeats within a
## bag's length. Its own RNG, never `Rng`.
var _bags: Dictionary = {}
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# --- pools ------------------------------------------------------------------
var _pool_3d: Array[AudioStreamPlayer3D] = []
var _pool_2d: Array[AudioStreamPlayer] = []
var _pool_3d_next: int = 0
var _pool_2d_next: int = 0

# --- self-sound loops (breath tiers, low-Cycles pulse, corruption) ----------
var _breath_calm: AudioStreamPlayer = null
var _breath_strained: AudioStreamPlayer = null
var _breath_critical: AudioStreamPlayer = null
var _pulse: AudioStreamPlayer = null
var _downed: AudioStreamPlayer = null
var _self_ready: bool = false

# --- settings (user://settings.cfg) -----------------------------------------
## 0..1 sliders. SFX drives World+Creatures+UI; Voice drives the Player (self)
## bus — the breath is the closest thing the game has to a voice, and gains a
## real one when M6's MOTHER barks arrive.
var vol_master: float = 1.0
var vol_music: float = 1.0
var vol_sfx: float = 1.0
var vol_voice: float = 1.0
## The flyback whine (see WHINE_HZ). ON by default (present); the toggle lets the
## age-lottery losers kill it.
var crt_whine: bool = true
## A lighter cousin of M6's Dampened Protocol: a soft limiter + high-shelf that
## rounds off sudden loud events (a shriek, a klaxon) without touching what is
## coming for you.
var reduced_spikes: bool = false
## The full Dampened Protocol (spec 05) — reads here so M6 can flip one flag.
var dampened: bool = false

# --- effect handles (for the comfort toggles) -------------------------------
var _whine_notch_idx: int = -1
var _limiter_idx: int = -1
var _highshelf_idx: int = -1

# --- ducking ----------------------------------------------------------------
## source tag -> negative dB. The live music duck is the deepest active one.
var _music_ducks: Dictionary = {}
## The decompile hand-over: her taking authorship ducks EVERYTHING to silence.
## 0 while idle; ramps on `_decompile_at`.
var _decompile_t: float = -1.0

var _muted_for_automation: bool = false


func _ready() -> void:
	_rng.randomize()
	_build_buses()
	_build_pools()
	_register_events()
	_load_settings()
	_apply_all_settings()
	_wire_signals()
	if Debug.automated:
		# A capture makes no sound, but everything below still runs so the streams
		# resolve, the pools churn and `--log-audio` prints — the run is exercised.
		AudioServer.set_bus_mute(_idx(BUS_MASTER), true)
		_muted_for_automation = true
	set_process(true)


# ----------------------------------------------------------------- buses --

## Idempotent bus construction. Godot always ships a Master; everything else is
## added here in parent-before-child order so every send resolves. Works under
## the headless dummy driver (no device, but the mixer graph is real).
func _build_buses() -> void:
	# name -> parent to send to.
	var layout: Array = [
		[BUS_MUSIC, BUS_MASTER], [BUS_MUS_FLOOR, BUS_MUSIC],
		[BUS_MUS_STRESS, BUS_MUSIC], [BUS_MUS_STINGER, BUS_MUSIC],
		[BUS_WORLD, BUS_MASTER], [BUS_BEDS, BUS_WORLD],
		[BUS_CREATURES, BUS_MASTER], [BUS_PLAYER, BUS_MASTER],
		[BUS_UI, BUS_MASTER],
	]
	for pair: Array in layout:
		_ensure_bus(pair[0], pair[1])

	# Reserve the sub-bass 20–60 Hz band for the Sentinel and the Hound: several
	# world/weapon tails carry real sub energy and with a crew, a bed and a
	# creature all playing it accumulates into mud (AUDIO_GUIDE).
	var world: int = _idx(BUS_WORLD)
	if AudioServer.get_bus_effect_count(world) == 0:
		var hp: AudioEffectHighPassFilter = AudioEffectHighPassFilter.new()
		hp.cutoff_hz = 35.0
		AudioServer.add_bus_effect(world, hp)

	_build_comfort_effects()


func _ensure_bus(name: StringName, send_to: StringName) -> void:
	var idx: int = AudioServer.get_bus_index(name)
	if idx < 0:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, name)
	AudioServer.set_bus_send(_idx(name), send_to)
	AudioServer.set_bus_volume_db(_idx(name), float(BUS_BASE[name]))


## The comfort effects, added disabled. They cost nothing until a toggle enables
## them, and wiring them here keeps every mixer decision in one file.
func _build_comfort_effects() -> void:
	# A notch at the flyback frequency on UI (where the menu bed sings). Enabled
	# only when the player has turned the whine OFF.
	var ui: int = _idx(BUS_UI)
	var notch: AudioEffectNotchFilter = AudioEffectNotchFilter.new()
	notch.cutoff_hz = WHINE_HZ
	notch.resonance = 2.0
	_whine_notch_idx = AudioServer.get_bus_effect_count(ui)
	AudioServer.add_bus_effect(ui, notch)
	AudioServer.set_bus_effect_enabled(ui, _whine_notch_idx, false)

	# Reduced-spikes / dampened limiter on Master, plus a high-shelf that tames
	# sudden brightness. Both off by default.
	var master: int = _idx(BUS_MASTER)
	var limiter: AudioEffectLimiter = AudioEffectLimiter.new()
	limiter.ceiling_db = -1.5
	limiter.threshold_db = -8.0
	limiter.soft_clip_db = 2.0
	_limiter_idx = AudioServer.get_bus_effect_count(master)
	AudioServer.add_bus_effect(master, limiter)
	AudioServer.set_bus_effect_enabled(master, _limiter_idx, false)

	var shelf: AudioEffectHighShelfFilter = AudioEffectHighShelfFilter.new()
	shelf.cutoff_hz = 5000.0
	# AudioEffectFilter.gain is a linear multiplier; ~0.65 rolls the top off by a
	# few dB, taming sudden brightness on a spike without dulling everything.
	shelf.gain = 0.65
	_highshelf_idx = AudioServer.get_bus_effect_count(master)
	AudioServer.add_bus_effect(master, shelf)
	AudioServer.set_bus_effect_enabled(master, _highshelf_idx, false)

	# Dampened Protocol's 6 kHz low-pass on Creatures and UI (spec 05). Off until
	# the flag is set; kept as the last effect on each so the notch index above
	# stays valid.
	for bus: StringName in [BUS_CREATURES, BUS_UI]:
		var b: int = _idx(bus)
		var lp: AudioEffectLowPassFilter = AudioEffectLowPassFilter.new()
		lp.cutoff_hz = DAMP_LP_HZ
		var i: int = AudioServer.get_bus_effect_count(b)
		AudioServer.add_bus_effect(b, lp)
		AudioServer.set_bus_effect_enabled(b, i, false)
		_damp_lp[bus] = i


var _damp_lp: Dictionary = {}


func _idx(name: StringName) -> int:
	return AudioServer.get_bus_index(name)


# ----------------------------------------------------------------- pools --

func _build_pools() -> void:
	for i: int in POOL_3D:
		var p: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
		p.name = "OneShot3D_%d" % i
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_pool_3d.append(p)
	for i: int in POOL_2D:
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		p.name = "OneShot2D_%d" % i
		add_child(p)
		_pool_2d.append(p)


# ------------------------------------------------------------- public API --

## Play a one-shot at a world position (a shot, a shriek, a switch clunk). Emits
## the event's caption on the same line, so text and sound cannot drift. Silent
## no-op for an unknown key (a typo never crashes a firefight).
func play_3d(key: StringName, world_pos: Vector3) -> void:
	var ev: AudioEvent = _events.get(key)
	if ev == null:
		return
	if ev.twod:
		play_2d(key)
		return
	var player: AudioStreamPlayer3D = _grab_3d()
	player.stream = _stream(ev)
	player.bus = ev.bus
	player.unit_size = ev.unit
	player.max_distance = ev.max_dist
	player.volume_db = ev.vol
	player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP \
			if ev.doppler else AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	player.pitch_scale = _pitch(ev)
	player.global_position = world_pos
	player.play()
	_log(key, world_pos)
	if ev.caption != &"":
		Captions.emit(ev.caption, world_pos, ev.max_dist)


## Play a one-shot with no position: UI feedback, or a self sound (breath, hurt,
## decompile). Its caption carries no direction.
func play_2d(key: StringName) -> void:
	var ev: AudioEvent = _events.get(key)
	if ev == null:
		return
	var player: AudioStreamPlayer = _grab_2d()
	player.stream = _stream(ev)
	player.bus = ev.bus
	player.volume_db = ev.vol
	player.pitch_scale = _pitch(ev)
	player.play()
	_log(key, Vector3.ZERO)
	if ev.caption != &"":
		Captions.emit(ev.caption, _listener_pos(), ev.max_dist)
	# The decompile is the one sound that ducks the whole mix to silence — her
	# taking authorship, made audible. Armed here so the timeline is exact.
	if key == &"ui_decompile":
		_decompile_t = 0.0


## Attach a looping positional sound to `owner` (a skittering Scrubber, a
## Sentinel drone, a channeling siphon). Returns the player so the owner can stop
## and free it on the same event it stops the behaviour. Registers the sustained
## caption too, so the loop's threat text tracks the source until it detaches.
func attach_loop(key: StringName, owner: Node3D, fade_in: float = 0.0) -> AudioStreamPlayer3D:
	var ev: AudioEvent = _events.get(key)
	if ev == null or owner == null:
		return null
	var player: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	player.stream = _stream(ev)
	player.bus = ev.bus
	player.unit_size = ev.unit
	player.max_distance = ev.max_dist
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	player.pitch_scale = _pitch(ev)
	player.volume_db = ev.vol if fade_in <= 0.0 else -60.0
	owner.add_child(player)
	# A creature commonly attaches its drone in `_assemble`, which the director
	# runs BEFORE parenting it — so the player may not be in the tree yet, and
	# `play()` (and a tween) only work once it is. Start on tree entry if so, now
	# if already in.
	var target_db: float = ev.vol
	var start: Callable = func() -> void:
		player.play()
		if fade_in > 0.0:
			player.create_tween().tween_property(player, "volume_db", target_db, fade_in)
	if player.is_inside_tree():
		start.call()
	else:
		player.tree_entered.connect(start, CONNECT_ONE_SHOT)
	_log(key, owner.global_position if owner.is_inside_tree() else Vector3.ZERO)
	if ev.caption != &"":
		Captions.register(player, ev.caption, ev.max_dist)
	return player


## Stop and free a loop from `attach_loop`, dropping its sustained caption.
func detach_loop(player: AudioStreamPlayer3D) -> void:
	if player == null or not is_instance_valid(player):
		return
	Captions.unregister(player)
	player.stop()
	player.queue_free()


# ------------------------------------------------------------ resolution --

func _stream(ev: AudioEvent) -> AudioStream:
	var path: String = ev.files[_bag_pick(ev)]
	if _streams.has(path):
		return _streams[path]
	var stream: AudioStream = load(path) as AudioStream
	if stream == null:
		push_warning("[Audio] missing stream: %s" % path)
		return null
	# The loop points are the file boundaries (AUDIO_GUIDE), so no loop_offset is
	# needed. Setting it on the shared resource is exactly right: every user of
	# this loop wants it looping. One-shots keep loop off so they end.
	if ev.loop and stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	_streams[path] = stream
	return stream


## Shuffle-bag: a variant never repeats within the bag's own length, which is
## what a true `randi()` cannot promise and what the guide asks for. Its own RNG
## — deterministically irrelevant, so this cannot perturb a run.
func _bag_pick(ev: AudioEvent) -> int:
	var n: int = ev.files.size()
	if n <= 1:
		return 0
	# `.get` on a missing key returns null, and null cannot be assigned to a
	# typed Dictionary — so hold it as Variant and refill on absent-or-exhausted.
	var bag: Variant = _bags.get(ev.key)
	if bag == null or int((bag as Dictionary)["cursor"]) >= n:
		var order: PackedInt32Array = PackedInt32Array()
		for i: int in n:
			order.append(i)
		# Fisher–Yates with the private RNG.
		for i: int in range(n - 1, 0, -1):
			var j: int = _rng.randi_range(0, i)
			var tmp: int = order[i]
			order[i] = order[j]
			order[j] = tmp
		bag = {"order": order, "cursor": 0}
		_bags[ev.key] = bag
	var pick: int = int(bag["order"][int(bag["cursor"])])
	bag["cursor"] = int(bag["cursor"]) + 1
	return pick


func _pitch(ev: AudioEvent) -> float:
	if ev.jitter <= 0.0:
		return 1.0
	return 1.0 + _rng.randf_range(-ev.jitter, ev.jitter)


func _grab_3d() -> AudioStreamPlayer3D:
	# Prefer a free player; steal the oldest by round-robin if the pool is busy.
	for _i: int in POOL_3D:
		var p: AudioStreamPlayer3D = _pool_3d[_pool_3d_next]
		_pool_3d_next = (_pool_3d_next + 1) % POOL_3D
		if not p.playing:
			return p
	var stolen: AudioStreamPlayer3D = _pool_3d[_pool_3d_next]
	_pool_3d_next = (_pool_3d_next + 1) % POOL_3D
	return stolen


func _grab_2d() -> AudioStreamPlayer:
	for _i: int in POOL_2D:
		var p: AudioStreamPlayer = _pool_2d[_pool_2d_next]
		_pool_2d_next = (_pool_2d_next + 1) % POOL_2D
		if not p.playing:
			return p
	var stolen: AudioStreamPlayer = _pool_2d[_pool_2d_next]
	_pool_2d_next = (_pool_2d_next + 1) % POOL_2D
	return stolen


func _listener_pos() -> Vector3:
	var cam: Camera3D = get_viewport().get_camera_3d()
	return Vector3.ZERO if cam == null else cam.global_position


func _log(key: StringName, where: Vector3) -> void:
	if Debug.log_audio:
		print("[Audio] %s at %s" % [key, str(where.snapped(Vector3.ONE * 0.1))])


# ---------------------------------------------------- ducking / decompile --

## Music duck request from a source (an alarm loop, a klaxon). The deepest active
## request wins; removing a source lifts its duck. Klaxons duck −6 (AUDIO_GUIDE).
func set_music_duck(source: StringName, db: float) -> void:
	if db >= 0.0:
		_music_ducks.erase(source)
	else:
		_music_ducks[source] = db
	_apply_music_bus()


func _current_music_duck() -> float:
	var deepest: float = 0.0
	for src: Variant in _music_ducks:
		deepest = minf(deepest, float(_music_ducks[src]))
	return deepest


# --------------------------------------------------------------- process --

func _process(delta: float) -> void:
	_drive_self_sounds(delta)
	_drive_beds(delta)
	_advance_decompile(delta)
	_advance_exfil()


# --- ambient beds (room tone) -----------------------------------------------
## Two players ping-ponging so a band boundary crossfades rather than cuts. The
## world beds sit on the Beds sub-bus (which ducks independently); the menu bed
## rides UI so the flyback-whine notch can find it.
var _beds: Array[AudioStreamPlayer] = []
var _bed_cur: int = -1
var _bed_key: StringName = &""


## One room-tone bed at a time, chosen by where you are, crossfaded on change —
## the surface datacentre hum, the mid unease, the deep warm-wrong crawl, the
## sanctuary campfire, and the menu/terminal CRT bed when no run is live.
func _drive_beds(delta: float) -> void:
	if _beds.is_empty():
		for _i: int in 2:
			var p: AudioStreamPlayer = AudioStreamPlayer.new()
			p.volume_db = -60.0
			add_child(p)
			_beds.append(p)

	var want: StringName = _desired_bed()
	if want != _bed_key:
		_bed_key = want
		var ev: AudioEvent = _events.get(want)
		if ev != null:
			# Bring the idle player up on the new bed; the active one fades under.
			_bed_cur = (_bed_cur + 1) % 2 if _bed_cur >= 0 else 0
			var incoming: AudioStreamPlayer = _beds[_bed_cur]
			incoming.stream = _stream(ev)
			incoming.bus = ev.bus
			incoming.volume_db = -60.0
			incoming.play()

	# ~2 s equal-power-ish crossfade: the current player toward its bed level, the
	# other toward silence.
	var blend: float = 1.0 - exp(-2.0 * delta)
	for i: int in _beds.size():
		var p: AudioStreamPlayer = _beds[i]
		var target: float = (-3.0 if i == _bed_cur and _bed_key != &"" else -60.0)
		p.volume_db = lerpf(p.volume_db, target, blend)
		if i != _bed_cur and p.playing and p.volume_db <= -55.0:
			p.stop()


func _desired_bed() -> StringName:
	if not Run.configured or Run.run_over:
		return &"amb_menu"
	if Run.backdoor_rooted:
		return &"amb_sanctuary"
	if Run.layer_number >= 15:
		return &"amb_deep"
	if Run.layer_number >= 6:
		return &"amb_mid"
	return &"amb_surface"


## One analogue gauge tick per countdown second, doubling under 10 s (AUDIO_GUIDE).
## The clock is Run's; this only listens to it, so it fires the same on every peer.
func _advance_exfil() -> void:
	if not Run.exfil_calling:
		return
	var left: float = Run.exfil_remaining
	# Below 10 s the rate doubles: tick on each half-second boundary instead.
	var mark: int = int(ceil(left * 2.0)) if left <= 10.0 else int(ceil(left))
	if mark != _exfil_tick_at and mark >= 0:
		_exfil_tick_at = mark
		play_2d(&"exfil_countdown")


## The breath tiers, the low-Cycles pulse and the corruption drone — your own
## avatar, 2D, cross-faded by the state of the run. Never hard-switched: the
## guide wants ~0.8 s cross-fades so the process failing is a slow dread, not a
## stinger. Runs every frame but only touches volumes, no allocation.
func _drive_self_sounds(delta: float) -> void:
	if not _self_ready:
		_build_self_sounds()
	var blend: float = 1.0 - exp(-1.25 * delta)  # ~0.8 s cross-fade constant.

	# Off entirely in the menu / before a run, or once you are gone.
	var in_run: bool = Run.configured and Run.local_alive()
	var corrupted: bool = in_run and Run.local_corrupted()
	var running: bool = in_run and Run.local_running()
	var frac: float = Run.fraction() if running else 1.0

	# Breath tiers by pool fraction: calm > 60%, strained 25–60%, critical < 25%.
	var calm_t: float = 1.0 if running and frac > 0.60 else 0.0
	var strained_t: float = 1.0 if running and frac <= 0.60 and frac > 0.25 else 0.0
	var critical_t: float = 1.0 if running and frac <= 0.25 else 0.0
	_ease_loop(_breath_calm, calm_t, blend, -26.0)
	_ease_loop(_breath_strained, strained_t, blend, -26.0)
	_ease_loop(_breath_critical, critical_t, blend, -26.0)

	# The heartbeat fades in from 0 across 25% -> 0% Cycles (feel it, not hear it).
	var pulse_t: float = 0.0
	if running and frac < 0.25:
		pulse_t = clampf(inverse_lerp(0.25, 0.0, frac), 0.0, 1.0)
	_ease_loop(_pulse, pulse_t, blend, -26.0)

	# The downed drone runs for the whole corrupted state.
	_ease_loop(_downed, 1.0 if corrupted else 0.0, blend, -26.0)


## Ease one self-loop toward its target level, starting/stopping it at the edges
## so a silenced loop is not spending a voice.
func _ease_loop(player: AudioStreamPlayer, target: float, blend: float, full_db: float) -> void:
	if player == null:
		return
	var want_db: float = full_db if target > 0.5 else -60.0
	if target > 0.5 and not player.playing:
		player.volume_db = -60.0
		player.play()
	player.volume_db = lerpf(player.volume_db, want_db, blend)
	if target <= 0.5 and player.playing and player.volume_db <= -55.0:
		player.stop()


func _build_self_sounds() -> void:
	_self_ready = true
	_breath_calm = _self_loop(&"breath_calm")
	_breath_strained = _self_loop(&"breath_strained")
	_breath_critical = _self_loop(&"breath_critical")
	_pulse = _self_loop(&"pulse_low")
	_downed = _self_loop(&"corruption_downed")


func _self_loop(key: StringName) -> AudioStreamPlayer:
	var ev: AudioEvent = _events.get(key)
	var p: AudioStreamPlayer = AudioStreamPlayer.new()
	p.name = "Self_%s" % key
	if ev != null:
		p.stream = _stream(ev)
		p.bus = ev.bus
	p.volume_db = -60.0
	add_child(p)
	return p


## The decompile duck timeline (AUDIO_GUIDE): everything but the decompile itself
## ramps to silence over 0.3 s starting at t = 1.35 s, holds through the 4.05 s
## gap (which is part of the sound and must not be filled), and releases at the
## tail. Driven off `_decompile_t`, armed when `ui_decompile` plays.
func _advance_decompile(delta: float) -> void:
	if _decompile_t < 0.0:
		return
	_decompile_t += delta
	var duck: float = 0.0
	if _decompile_t >= 1.35 and _decompile_t < 6.2:
		duck = -80.0 * clampf((_decompile_t - 1.35) / 0.3, 0.0, 1.0)
	elif _decompile_t >= 6.2:
		_decompile_t = -1.0  # done; buses restored below.
	# Apply the duck to everything except UI (where the decompile itself plays).
	for bus: StringName in [BUS_MUSIC, BUS_WORLD, BUS_CREATURES, BUS_PLAYER]:
		AudioServer.set_bus_volume_db(_idx(bus), _bus_trim(bus) + duck)
	if _decompile_t < 0.0:
		_apply_bus_volumes()  # restore.


# ------------------------------------------------------------- settings --

## Slider trim for a bus: the master offset always applies, plus the family
## offset for the bus's own group. Returns dB added on top of the base layout.
func _bus_trim(bus: StringName) -> float:
	var base: float = float(BUS_BASE[bus])
	var master: float = _slider_db(vol_master)
	match bus:
		BUS_MUSIC, BUS_MUS_FLOOR, BUS_MUS_STRESS, BUS_MUS_STINGER:
			# Music slider on the Music bus; the sub-buses inherit it by routing.
			return base + master + (_slider_db(vol_music) if bus == BUS_MUSIC else 0.0)
		BUS_WORLD, BUS_CREATURES, BUS_UI:
			return base + master + _slider_db(vol_sfx)
		BUS_BEDS:
			return base + master  # inherits the SFX trim via World.
		BUS_PLAYER:
			return base + master + _slider_db(vol_voice)
		_:
			return base + master


func _slider_db(value: float) -> float:
	return -80.0 if value <= 0.001 else linear_to_db(clampf(value, 0.0, 1.0))


func _apply_all_settings() -> void:
	_apply_bus_volumes()
	_apply_comfort()


func _apply_bus_volumes() -> void:
	for bus: StringName in BUS_BASE:
		AudioServer.set_bus_volume_db(_idx(bus), _bus_trim(bus))
	_apply_music_bus()


## The Music bus specifically also carries the active duck, so it is applied on
## top of its slider trim whenever either changes.
func _apply_music_bus() -> void:
	AudioServer.set_bus_volume_db(_idx(BUS_MUSIC),
			_bus_trim(BUS_MUSIC) + _current_music_duck())


func _apply_comfort() -> void:
	# The whine notch is ON when the whine is OFF.
	if _whine_notch_idx >= 0:
		AudioServer.set_bus_effect_enabled(_idx(BUS_UI), _whine_notch_idx, not crt_whine)
	# The Master limiter + high-shelf ride reduced-spikes OR dampened.
	var soften: bool = reduced_spikes or dampened
	if _limiter_idx >= 0:
		AudioServer.set_bus_effect_enabled(_idx(BUS_MASTER), _limiter_idx, soften)
	if _highshelf_idx >= 0:
		AudioServer.set_bus_effect_enabled(_idx(BUS_MASTER), _highshelf_idx, soften)
	# Dampened Protocol proper: −6 dB Creatures + 6 kHz LP on Creatures and UI.
	for bus: StringName in [BUS_CREATURES, BUS_UI]:
		if _damp_lp.has(bus):
			AudioServer.set_bus_effect_enabled(_idx(bus), int(_damp_lp[bus]), dampened)


## Public setters for the settings panel. Each writes the store, re-applies, and
## persists — no separate "apply" step for the caller to forget.
func set_volume(which: StringName, value: float) -> void:
	value = clampf(value, 0.0, 1.0)
	match which:
		&"master": vol_master = value
		&"music": vol_music = value
		&"sfx": vol_sfx = value
		&"voice": vol_voice = value
		_: return
	_apply_bus_volumes()
	_save_settings()


func set_crt_whine(on: bool) -> void:
	crt_whine = on
	_apply_comfort()
	_save_settings()


func set_reduced_spikes(on: bool) -> void:
	reduced_spikes = on
	_apply_comfort()
	_save_settings()


## M6 hook (spec 05): the full Dampened Protocol audio half. Flag-driven so the
## Director can flip it without knowing anything about the mixer.
func set_dampened(on: bool) -> void:
	dampened = on
	_apply_comfort()
	_save_settings()


func _load_settings() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	vol_master = clampf(float(cfg.get_value("audio", "master", 1.0)), 0.0, 1.0)
	vol_music = clampf(float(cfg.get_value("audio", "music", 1.0)), 0.0, 1.0)
	vol_sfx = clampf(float(cfg.get_value("audio", "sfx", 1.0)), 0.0, 1.0)
	vol_voice = clampf(float(cfg.get_value("audio", "voice", 1.0)), 0.0, 1.0)
	crt_whine = bool(cfg.get_value("audio", "crt_whine", true))
	reduced_spikes = bool(cfg.get_value("audio", "reduced_spikes", false))
	dampened = bool(cfg.get_value("audio", "dampened", false))


## Atomic temp-then-rename, like GameState.save_progress — a settings write that
## a crash truncates should never leave the mixer in a half-state on next boot.
func _save_settings() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("audio", "master", vol_master)
	cfg.set_value("audio", "music", vol_music)
	cfg.set_value("audio", "sfx", vol_sfx)
	cfg.set_value("audio", "voice", vol_voice)
	cfg.set_value("audio", "crt_whine", crt_whine)
	cfg.set_value("audio", "reduced_spikes", reduced_spikes)
	cfg.set_value("audio", "dampened", dampened)
	var temp: String = SETTINGS_PATH + ".tmp"
	if cfg.save(temp) == OK:
		DirAccess.rename_absolute(ProjectSettings.globalize_path(temp),
				ProjectSettings.globalize_path(SETTINGS_PATH))
	else:
		cfg.save(SETTINGS_PATH)


# ------------------------------------------------------- central signals --

## Connect the events cleanly available as replicated Run signals — they fire on
## every peer (call_local RPCs), so driving audio + captions from here is correct
## for multiplayer and touches no state. Loops and local-physics events are wired
## at their own nodes instead (see the creature/prop hooks).
func _wire_signals() -> void:
	Run.damaged.connect(_on_damaged)
	Run.decompiled.connect(_on_decompiled)
	Run.restored.connect(_on_restored)
	Run.shard_taken.connect(_on_shard_taken)
	Run.descent_started.connect(_on_descent_started)
	Run.backdoor_rooted_changed.connect(_on_backdoor_changed)
	Run.exfil_changed.connect(_on_exfil_changed)
	Run.corruption_changed.connect(_on_corruption_changed)
	Run.layer_changed.connect(_on_layer_changed)
	Run.run_ended.connect(_on_run_ended)


func _on_run_ended(summary: Dictionary) -> void:
	# The upload-out is the world sound of the avatar leaving with the haul; the
	# escape/wipe MUSIC is MusicDirector's job. Only on a successful exfil.
	if bool(summary.get("success", false)):
		play_3d(&"exfil_upload", _spawn_anchor().global_position if _spawn_anchor() != null else _listener_pos())


func _on_damaged(from: Vector3) -> void:
	play_2d(&"player_hurt")
	# The HUD flinch also conveys this; the caption is INFO. Direction is where
	# the hit came from, which the self-sound cannot carry.
	if A11y.sound_captions:
		Captions.emit(&"player_hurt", from, 20.0)


func _on_decompiled(peer_id: int) -> void:
	if peer_id != Net.local_id():
		return
	# The crew's warm signal collapses and one clean digital tone is left: her
	# winning, made audible. `ui_decompile` arms the whole-mix duck.
	play_2d(&"player_death")
	play_2d(&"ui_decompile")


func _on_restored(peer_id: int, _by_peer: int) -> void:
	if peer_id == Net.local_id():
		play_2d(&"player_restore_complete")


func _on_shard_taken(_index: int, peer_id: int, _worth: int) -> void:
	# Deliberately the quietest thing in the game, pitch-varied and shuffle-bagged
	# so 100 pickups in a vault reads as a run, not a machine gun.
	if peer_id == Net.local_id():
		play_2d(&"datachip")


func _on_descent_started(_next_layer: int) -> void:
	var shaft: Node = get_tree().get_first_node_in_group("layer")
	var where: Vector3 = _listener_pos()
	if shaft != null and shaft.has_method("get"):
		var p: Variant = shaft.get("shaft_position")
		if p != null:
			where = p
	play_3d(&"dropshaft", where)


var _was_rooted: bool = false

func _on_backdoor_changed() -> void:
	# Fire only on the false -> true edge (the signal also fires on descent reset).
	if Run.backdoor_rooted and not _was_rooted:
		play_3d(&"backdoor_root_complete", _listener_pos())
	_was_rooted = Run.backdoor_rooted


var _was_exfil: bool = false
var _exfil_tick_at: int = -1

func _on_exfil_changed() -> void:
	if Run.exfil_calling and not _was_exfil:
		_exfil_klaxon = attach_loop(&"exfil_klaxon", _spawn_anchor())
		set_music_duck(&"exfil_klaxon", -6.0)
		_exfil_tick_at = int(ceil(Run.exfil_remaining))
	elif not Run.exfil_calling and _was_exfil:
		detach_loop(_exfil_klaxon)
		_exfil_klaxon = null
		set_music_duck(&"exfil_klaxon", 0.0)
	_was_exfil = Run.exfil_calling

var _exfil_klaxon: AudioStreamPlayer3D = null


func _on_corruption_changed() -> void:
	# The local avatar just went down (edge into corrupted): the analogue failure.
	var down: bool = Run.local_corrupted()
	if down and not _was_corrupt:
		play_2d(&"player_corruption_enter")
		if A11y.sound_captions:
			Captions.emit(&"you_are_down", _listener_pos(), 20.0)
	_was_corrupt = down

var _was_corrupt: bool = false


func _on_layer_changed(_n: int) -> void:
	# A fresh layer resets the exfil/backdoor edge trackers so a descent does not
	# replay a stale klaxon or root sting.
	_was_rooted = Run.backdoor_rooted
	_was_exfil = Run.exfil_calling


## An anchor node for run-wide loops (the exfil klaxon), so they follow the layer
## and are freed with it. The uplink if present, else the layer root.
func _spawn_anchor() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group("exfil_uplinks"):
		if node is Node3D and is_instance_valid(node):
			return node
	var layer: Node = get_tree().get_first_node_in_group("layer")
	return layer as Node3D if layer is Node3D else null


# --------------------------------------------- the event table (the guide) --

## Register one event with sane per-family defaults. `opts` overrides any field.
func _def(key: StringName, files: Array, bus: StringName, opts: Dictionary = {}) -> void:
	var ev: AudioEvent = AudioEvent.new()
	ev.key = key
	var paths: PackedStringArray = PackedStringArray()
	for f: String in files:
		paths.append(AUDIO_DIR + f)
	ev.files = paths
	ev.bus = bus
	ev.loop = bool(opts.get("loop", false))
	ev.twod = bool(opts.get("twod", false))
	ev.unit = float(opts.get("unit", 6.0))
	ev.max_dist = float(opts.get("max", 32.0))
	ev.vol = float(opts.get("vol", 0.0))
	ev.jitter = float(opts.get("jitter", 0.0))
	ev.doppler = bool(opts.get("doppler", false))
	ev.caption = StringName(opts.get("caption", &""))
	_events[key] = ev


## Every game asset from AUDIO_GUIDE, with the attenuation, loop, loudness-
## exception and caption columns wired. Grouped by family. `V` values are the
## documented volume_db exceptions; everything else mixes at the bus.
func _register_events() -> void:
	var C := BUS_CREATURES
	var W := BUS_WORLD
	var P := BUS_PLAYER
	var U := BUS_UI
	var B := BUS_BEDS
	# Per the guide's attenuation table:
	var STEP := {"unit": 3.0, "max": 22.0}
	var PROP := {"unit": 2.5, "max": 14.0}
	var COMBAT := {"unit": 5.0, "max": 45.0}
	var SCRUB := {"unit": 7.0, "max": 32.0}
	var ROOM := {"unit": 5.0, "max": 35.0}
	var LOUD := {"unit": 14.0, "max": 70.0}   # debris / siphon (== AI radius)
	var DREAD := {"unit": 20.0, "max": 90.0}  # sentinel / bulkhead / shaft / exfil

	# --- ambient beds (World/Beds, loop) ---
	_def(&"amb_surface", ["ambient/amb_band_surface.ogg"], B, {"loop": true, "caption": &"machinery"})
	_def(&"amb_mid", ["ambient/amb_band_mid.ogg"], B, {"loop": true, "caption": &"machinery"})
	_def(&"amb_deep", ["ambient/amb_band_deep.ogg"], B, {"loop": true, "caption": &"machinery"})
	_def(&"amb_nest", ["ambient/amb_nest_quarantine.ogg"], B, {"loop": true})
	_def(&"amb_sanctuary", ["ambient/amb_sanctuary.ogg"], B, {"loop": true})
	_def(&"amb_menu", ["ambient/amb_menu_terminal.ogg"], U, {"loop": true})

	# --- player (self sounds 2D on Player; footsteps spatialised on World) ---
	_def(&"breath_calm", ["player/player_breath_calm_loop.ogg"], P, {"loop": true})
	_def(&"breath_strained", ["player/player_breath_strained_loop.ogg"], P, {"loop": true})
	_def(&"breath_critical", ["player/player_breath_critical_loop.ogg"], P, {"loop": true})
	_def(&"pulse_low", ["player/player_pulse_low_cycles_loop.ogg"], P, {"loop": true})
	_def(&"corruption_downed", ["player/player_corruption_downed_loop.ogg"], P, {"loop": true})
	_def(&"player_corruption_enter", ["player/player_corruption_enter.ogg"], P, {"twod": true})
	_def(&"player_death", ["player/player_death_delete.ogg"], P, {"twod": true, "caption": &"decompiled"})
	_def(&"player_hurt", ["player/player_hurt_01.ogg", "player/player_hurt_02.ogg",
			"player/player_hurt_03.ogg"], P, {"twod": true})
	_def(&"player_restore_channel", ["player/player_restore_channel.ogg"], P, {"twod": true})
	_def(&"player_restore_complete", ["player/player_restore_complete.ogg"], P, {"twod": true, "caption": &"restored"})
	# Footsteps: 8-variant shuffle, ±6% pitch. Remote = spatialised; the local
	# self copy is a quiet 2D −10 (your own steps sit close, not loud).
	var steps: Array = ["player/player_footstep_grate_01.ogg", "player/player_footstep_grate_02.ogg",
		"player/player_footstep_grate_03.ogg", "player/player_footstep_grate_04.ogg",
		"player/player_footstep_grate_05.ogg", "player/player_footstep_grate_06.ogg",
		"player/player_footstep_grate_07.ogg", "player/player_footstep_grate_08.ogg"]
	_def(&"footstep", steps, W, {"unit": STEP.unit, "max": STEP.max, "jitter": 0.06, "caption": &"footstep"})
	_def(&"footstep_self", steps, W, {"twod": true, "vol": -10.0, "jitter": 0.06})
	_def(&"land", ["player/player_land_grate_01.ogg", "player/player_land_grate_02.ogg"],
			W, {"unit": STEP.unit, "max": STEP.max, "jitter": 0.05})
	_def(&"land_self", ["player/player_land_grate_01.ogg", "player/player_land_grate_02.ogg"],
			W, {"twod": true, "vol": -8.0, "jitter": 0.05})

	# --- weapons & tools (World) ---
	var shots: Array = ["weapons/breaker_shot_01.ogg", "weapons/breaker_shot_02.ogg",
		"weapons/breaker_shot_03.ogg", "weapons/breaker_shot_04.ogg"]
	_def(&"breaker_shot", shots, W, {"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"breaker_fire"})
	_def(&"breaker_shot_dry", shots, W, {"twod": true, "vol": -8.0})
	_def(&"breaker_heat", ["weapons/breaker_heat_tick.ogg"], W, {"twod": true})
	_def(&"breaker_lockout", ["weapons/breaker_lockout_sizzle.ogg"], W, {"twod": true, "caption": &"breaker_overheat"})
	_def(&"breaker_ready", ["weapons/breaker_cooldown_release.ogg"], W, {"twod": true})
	_def(&"flare_ignite", ["weapons/flare_ignite.ogg"], W, {"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"flare_lit"})
	_def(&"flare_die", ["weapons/flare_die.ogg"], W, {"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"flare_dying"})
	_def(&"flare_burn", ["weapons/flare_burn_loop.ogg"], W, {"loop": true, "unit": COMBAT.unit, "max": COMBAT.max})
	_def(&"weld_loop", ["weapons/weld_loop.ogg"], W, {"loop": true, "unit": COMBAT.unit, "max": COMBAT.max, "caption": &"weld"})
	_def(&"weld_complete", ["weapons/weld_complete.ogg"], W, {"unit": COMBAT.unit, "max": COMBAT.max})

	# --- creatures (Creatures; scrubbers near-field, sentinel is a dread telegraph) ---
	var chit: Array = ["creatures/scrubber_idle_chitter_01.ogg", "creatures/scrubber_idle_chitter_02.ogg",
		"creatures/scrubber_idle_chitter_03.ogg"]
	_def(&"scrubber_chitter", chit, C, {"unit": SCRUB.unit, "max": SCRUB.max, "caption": &"scrubber_chitter"})
	var skit: Array = ["creatures/scrubber_skitter_loop_01.ogg", "creatures/scrubber_skitter_loop_02.ogg",
		"creatures/scrubber_skitter_loop_03.ogg"]
	_def(&"scrubber_skitter", skit, C, {"loop": true, "unit": SCRUB.unit, "max": SCRUB.max, "caption": &"scrubber_skitter"})
	_def(&"scrubber_alert", ["creatures/scrubber_alert.ogg"], C, {"unit": SCRUB.unit, "max": SCRUB.max, "caption": &"scrubber_alert"})
	_def(&"scrubber_lunge", ["creatures/scrubber_lunge_shriek_01.ogg", "creatures/scrubber_lunge_shriek_02.ogg",
			"creatures/scrubber_lunge_shriek_03.ogg"], C, {"unit": SCRUB.unit, "max": SCRUB.max, "caption": &"scrubber_lunge"})
	_def(&"scrubber_hurt", ["creatures/scrubber_hurt_01.ogg", "creatures/scrubber_hurt_02.ogg"],
			C, {"unit": SCRUB.unit, "max": SCRUB.max})
	_def(&"scrubber_death", ["creatures/scrubber_death_shatter_01.ogg", "creatures/scrubber_death_shatter_02.ogg"],
			C, {"unit": SCRUB.unit, "max": SCRUB.max})
	_def(&"sentinel_drone", ["creatures/sentinel_presence_drone_loop.ogg"], C,
			{"loop": true, "unit": DREAD.unit, "max": DREAD.max, "caption": &"sentinel_drone"})
	_def(&"sentinel_scan", ["creatures/sentinel_scan_sweep.ogg"], C, {"unit": DREAD.unit, "max": DREAD.max, "caption": &"sentinel_scan"})
	_def(&"sentinel_glide", ["creatures/sentinel_glide_stutter_01.ogg", "creatures/sentinel_glide_stutter_02.ogg"],
			C, {"unit": DREAD.unit, "max": DREAD.max, "caption": &"sentinel_shift"})
	_def(&"sentinel_alarm", ["creatures/sentinel_alarm_klaxon.ogg"], C,
			{"loop": true, "unit": DREAD.unit, "max": DREAD.max, "caption": &"sentinel_alarm"})
	_def(&"sentinel_core_hit", ["creatures/sentinel_core_hit_01.ogg", "creatures/sentinel_core_hit_02.ogg",
			"creatures/sentinel_core_hit_03.ogg"], C, {"unit": DREAD.unit, "max": DREAD.max})
	_def(&"sentinel_purge", ["creatures/sentinel_purge_strike.ogg"], C, {"unit": DREAD.unit, "max": DREAD.max, "caption": &"sentinel_purge"})
	_def(&"sentinel_death", ["creatures/sentinel_death_collapse.ogg"], C, {"unit": DREAD.unit, "max": DREAD.max})
	# M6 concept assets — wired, dormant (the director fires them later).
	_def(&"hound_howl", ["creatures/hound_howl.ogg"], C, {"unit": DREAD.unit, "max": DREAD.max, "caption": &"hound_howl"})
	_def(&"hound_prowl", ["creatures/hound_prowl_loop.ogg"], C, {"loop": true, "unit": DREAD.unit, "max": DREAD.max, "caption": &"hound_prowl"})

	# --- world interactions ---
	_def(&"backdoor_root_complete", ["world/backdoor_root_complete.ogg"], W, {"unit": ROOM.unit, "max": ROOM.max, "caption": &"backdoor_installed"})
	_def(&"backdoor_rooting", ["world/backdoor_rooting_sequence.ogg"], W, {"unit": ROOM.unit, "max": ROOM.max})
	_def(&"bulkhead_seal", ["world/bulkhead_seal_slam.ogg"], W, {"unit": DREAD.unit, "max": DREAD.max, "caption": &"bulkhead_seal"})
	_def(&"bulkhead_reopen", ["world/bulkhead_mother_reopen.ogg"], W, {"unit": DREAD.unit, "max": DREAD.max, "caption": &"bulkhead_reopen"})
	_def(&"cabinet_creak", ["world/cabinet_creak_open.ogg"], W, {"unit": PROP.unit, "max": PROP.max, "caption": &"cabinet"})
	_def(&"cabinet_cut", ["world/cabinet_lock_cut_sizzle.ogg"], W, {"unit": ROOM.unit, "max": ROOM.max})
	_def(&"compiler_hum", ["world/compiler_hum_loop.ogg"], W, {"loop": true, "unit": ROOM.unit, "max": ROOM.max})
	var chips: Array = ["world/datachip_pickup_01.ogg", "world/datachip_pickup_02.ogg",
		"world/datachip_pickup_03.ogg", "world/datachip_pickup_04.ogg",
		"world/datachip_pickup_05.ogg", "world/datachip_pickup_06.ogg"]
	_def(&"datachip", chips, U, {"twod": true, "vol": -6.0, "jitter": 0.06, "caption": &"data_chip"})
	var debris: Array = ["world/debris_clatter_01.ogg", "world/debris_clatter_02.ogg",
		"world/debris_clatter_03.ogg", "world/debris_clatter_04.ogg",
		"world/debris_clatter_05.ogg", "world/debris_clatter_06.ogg"]
	_def(&"debris", debris, W, {"unit": LOUD.unit, "max": LOUD.max, "jitter": 0.06, "caption": &"debris"})
	_def(&"dropshaft", ["world/dropshaft_descent.ogg"], W, {"unit": DREAD.unit, "max": DREAD.max, "doppler": true, "caption": &"descending"})
	_def(&"exfil_countdown", ["world/exfil_countdown_tick.ogg"], U, {"twod": true, "caption": &"exfil_countdown"})
	_def(&"exfil_klaxon", ["world/exfil_klaxon_loop.ogg"], W, {"loop": true, "unit": DREAD.unit, "max": DREAD.max, "caption": &"exfil_klaxon"})
	_def(&"exfil_upload", ["world/exfil_upload_out.ogg"], W, {"unit": DREAD.unit, "max": DREAD.max})
	_def(&"rewire_clunk", ["world/rewire_switch_clunk_01.ogg", "world/rewire_switch_clunk_02.ogg",
			"world/rewire_switch_clunk_03.ogg"], W, {"unit": PROP.unit, "max": PROP.max, "caption": &"rewire"})
	_def(&"siphon_channel", ["world/siphon_tap_channel_loop.ogg"], W, {"loop": true, "unit": LOUD.unit, "max": LOUD.max, "caption": &"siphon_channel"})
	_def(&"siphon_surge", ["world/siphon_tap_complete_surge.ogg"], W, {"unit": LOUD.unit, "max": LOUD.max, "caption": &"siphon_surge"})
	var keys: Array = ["world/terminal_key_click_01.ogg", "world/terminal_key_click_02.ogg",
		"world/terminal_key_click_03.ogg", "world/terminal_key_click_04.ogg",
		"world/terminal_key_click_05.ogg", "world/terminal_key_click_06.ogg"]
	_def(&"terminal_key", keys, U, {"twod": true, "jitter": 0.05})
	_def(&"terminal_send", ["world/terminal_query_send.ogg"], U, {"twod": true})
	_def(&"terminal_processing", ["world/terminal_processing_chirp.ogg"], U, {"twod": true})
	_def(&"terminal_corrupt", ["world/terminal_output_corrupt_crackle.ogg"], U, {"twod": true})

	# --- UI (CRT family, 2D) ---
	_def(&"ui_boot", ["ui/ui_boot_compile_in.ogg"], U, {"twod": true})
	_def(&"ui_decompile", ["ui/ui_decompile_transition.ogg"], U, {"twod": true})
	_def(&"ui_gauge_tick", ["ui/ui_gauge_tick.ogg"], U, {"twod": true})
	_def(&"ui_back", ["ui/ui_menu_back.ogg"], U, {"twod": true})
	_def(&"ui_hover", ["ui/ui_menu_hover_tick.ogg"], U, {"twod": true})
	_def(&"ui_select", ["ui/ui_menu_select_clack.ogg"], U, {"twod": true})
	_def(&"ui_compiling", ["ui/ui_purchase_compiling_beat.ogg"], U, {"loop": true, "twod": true})
	_def(&"ui_purchase", ["ui/ui_purchase_success_stamp.ogg"], U, {"twod": true})
	_def(&"ui_recompile", ["ui/ui_recompile_return.ogg"], U, {"twod": true})
	_def(&"ui_refusal", ["ui/ui_refusal_glitch_buzz.ogg"], U, {"twod": true})
	_def(&"ui_selftest", ["ui/ui_selftest_beep.ogg"], U, {"twod": true})
	_def(&"ui_toast", ["ui/ui_toast_reveal.ogg"], U, {"twod": true})
	# PT1. The hit marker's audible half. 2D and quiet: it is feedback about your
	# own trigger, so it sits close and never spatialises. -7 dB because it fires
	# on every landed shot at up to ~3.85 Hz, and a confirm as loud as the weapon
	# would become the weapon.
	_def(&"hit_confirm", ["ui/ui_hit_confirm.ogg"], U, {"twod": true, "vol": -7.0})
	# PT1. The drop shaft's cut of the trunk, on every peer, once per descent.
	_def(&"shaft_siphon", ["ui/ui_shaft_siphon.ogg"], U, {"twod": true, "vol": -3.0})
