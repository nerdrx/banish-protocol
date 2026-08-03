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
##    ├── UI         -2   ui/*, chips, key clicks, ticks
##    └── Voice      -3   MOTHER (murmur beds, directed address, subzero)
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
## MOTHER. Her own bus, not a corner of Player or Creatures, because she is the
## only source in the game that has to be duckable AGAINST everything else at
## once — see the VOICE section at the bottom of this file.
const BUS_VOICE: StringName = &"Voice"

## Base trim per bus (AUDIO_GUIDE layout). The user volume sliders are an offset
## ON TOP of these; a bus's live volume is base + slider trim.
const BUS_BASE: Dictionary = {
	BUS_MASTER: 0.0, BUS_MUSIC: -4.0, BUS_MUS_FLOOR: -3.0, BUS_MUS_STRESS: 0.0,
	BUS_MUS_STINGER: -1.0, BUS_WORLD: -1.0, BUS_BEDS: -3.0, BUS_CREATURES: 0.0,
	BUS_PLAYER: 0.0, BUS_UI: -2.0, BUS_VOICE: -3.0,
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
	## Derived once at registration: does this event carry a THREAT caption? If it
	## does, playing it ducks MOTHER — the one rule the voice tier must never break
	## is masking the audio a player survives by. Precomputed rather than looked up,
	## because this is read on the one-shot hot path.
	var threat: bool = false


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
	# MOTHER's voice layer. Deferred, and this is not a style choice: `Haunt`
	# autoloads AFTER us (see project.godot — it depends on Music, which depends on
	# this), so the singleton does not exist yet during our own `_ready`. Deferring
	# to idle puts the connect after every autoload is standing.
	_wire_voice.call_deferred()
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
		[BUS_UI, BUS_MASTER], [BUS_VOICE, BUS_MASTER],
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
	if ev.threat:
		_arm_voice_duck()
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
	if ev.threat:
		_arm_voice_duck()
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
	return _stream_path(ev.files[_bag_pick(ev)], ev.loop)


## Load-and-cache one path. Split out of `_stream` so the voice layer can resolve
## a SPECIFIC cue (an audition pin, or a Dampened-Protocol substitution) through
## exactly the same cache instead of a second loading path with its own bugs.
func _stream_path(path: String, loop: bool) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var stream: AudioStream = load(path) as AudioStream
	if stream == null:
		push_warning("[Audio] missing stream: %s" % path)
		return null
	# The loop points are the file boundaries (AUDIO_GUIDE), so no loop_offset is
	# needed. Setting it on the shared resource is exactly right: every user of
	# this loop wants it looping. One-shots keep loop off so they end.
	if loop and stream is AudioStreamOggVorbis:
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
	_drive_voice(delta)
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
	for bus: StringName in [BUS_MUSIC, BUS_WORLD, BUS_CREATURES, BUS_PLAYER, BUS_VOICE]:
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
		BUS_PLAYER, BUS_VOICE:
			# One slider for both, which is the honest grouping: the breath is your
			# own process making a mouth noise and MOTHER is hers. A player who turns
			# VOICE down is asking for less of the game talking, and gets it.
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
	_apply_voice_bus()


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
	# MOTHER takes her own Dampened trim (and her cue pool loses its harshest
	# member) — see VOICE_DAMPENED_TRIM.
	_apply_voice_bus()


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


# ----------------------------------------------------------------- VOICE --
#
# MOTHER'S VOICE. She has had words since M6 — 183 authored barks rendered to a
# caption line — and no MOUTH. This is the mouth: 15 synthesized cues in
# `assets/audio/mother/`, built by `tools/audio/build_mother_voice.py` from the
# real bark prosody, in three intensity tiers named by filename prefix.
#
# ## Zero new plumbing, on purpose
#
# The hook is the Director's existing `mother_spoke(text, category, tier,
# callsign)` signal. That signal already fires on every peer (it is emitted
# inside a `call_local` RPC), already respects the whole bark budget, and already
# feeds the HUD subtitle and the hub's lens. So the voice is a SUBSCRIBER: no new
# RPC, nothing new on the wire, nothing new the Director has to know about, and
# no second place where the caption rules could be got wrong.
#
# ## The three tiers, and why they are spatialised differently
#
#   MURMUR (mv_amb_*)      3D, on the architecture, DREAD attenuation. She is in
#                          the walls, two rooms over, and you could walk toward
#                          her. Longest cues (10-27 s) and quietest masters
#                          (-34 LUFS): a bed, not an event.
#   DIRECTED (mv_addr_*)   2D, non-positional. SHE IS NOT IN THE ROOM, SHE IS IN
#                          THE CHANNEL. Giving this a position would be the
#                          single worst thing that could be done to it — a player
#                          who can turn toward her is a player who has located
#                          her, and the whole premise is that you are inside her.
#   SUBZERO (mv_sub_*)     2D as well, but the intimate masters (-27 LUFS, no
#                          reverb, proximity EQ). The Below-the-Kernel register.
#
# ## Category -> tier
#
# The mapping is by REGISTER, not by event importance. `hunt` and `exfil` are
# directed because she is talking AT the crew about what is happening to them;
# `kill_ack`, `noise` and `descent` are murmurs because she is only NOTICING.
# Anything unmapped falls to the murmur, which is the quietest tier — an
# unrecognised category must never be able to make her louder.
#
# ## What it will not do
#
#   * It will not mask threat audio. Every one-shot carrying a THREAT caption
#     sidechains this bus (`_arm_voice_duck`); sustained threat loops deliberately
#     do NOT, because a Sentinel drone is a background presence and ducking her
#     for its whole life would silence her exactly where she is most worth
#     hearing. The transients are what carry information; those are what duck.
#   * It will not flash, pulse or drive any visual. Nothing in this path touches
#     a light, a shader or the HUD (the lens's own optic envelope is 0.2 Hz and
#     predates this). DESIGN.md pillar 7 is untouched by construction.
#   * It will not talk over itself. One murmur player, one directed player.
#   * It will not deliver one sentence in two different voices to two different
#     crewmates. The cue is picked from the bark TEXT, which every peer already
#     holds byte-identical — see `_voice_stream` for why that beats a shuffle bag
#     here and nowhere else in this file.
#   * It will not perturb a run. Same rule as the rest of this file: the single
#     random draw in the whole tier (the density roll) uses the PRIVATE `_rng`,
#     never `Rng`, so the determinism dump is byte-identical with her voice on or
#     off — measured, not asserted.

## Tier names.
const VOICE_MURMUR: StringName = &"murmur"
const VOICE_DIRECTED: StringName = &"directed"
const VOICE_SUBZERO: StringName = &"subzero"

## ============================ THE SWAP POINTS ============================
##
## Each tier's cue list, ORDERED BEST-FIRST by the R&D bench's ANALYTIC ranking —
## which is a measurement, not a judgement. NOBODY HAS AUDITIONED THESE YET. The
## numbers below are the bench's overall rank across all 15 candidates.
##
## To change how she sounds, edit these three lists and nothing else:
##   * DELETE a line to retire a cue;
##   * cut a list to ONE line to pin that cue as her only voice in that tier;
##   * reorder freely — which cue a given bark gets is a hash of the bark's own
##     text modulo the list length, so order is documentation of the ranking and
##     nothing depends on it.
## Adding a file to `assets/audio/mother/` and naming it here is the whole
## integration. Nothing else in the game refers to these filenames.
##
## To audition ONE cue in the running game without editing anything, set
## `BP_VOICE_CUE` in the environment to a bare cue name, e.g.
##   BP_VOICE_CUE=mv_sub_tape_eaten <the usual gamescope-wrapped launch>
## and every tier plays that cue instead. Unset it to go back to the tables.
const VOICE_MURMUR_CUES: Array[String] = [
	"mother/mv_amb_whisper_walls.ogg",      # rank 3 overall — the bench's pick
	"mother/mv_amb_manifest_walls.ogg",
	"mother/mv_amb_vocoder_conduit.ogg",
	"mother/mv_amb_choir_processes.ogg",
	"mother/mv_amb_backmask.ogg",
]
const VOICE_DIRECTED_CUES: Array[String] = [
	"mother/mv_addr_breathe.ogg",           # rank 1 overall
	"mother/mv_addr_stop_touching.ogg",     # rank 5
	"mother/mv_addr_hunt_told.ogg",
	"mother/mv_addr_doubled_mercy.ogg",
	"mother/mv_addr_epitaph_record.ogg",
]
const VOICE_SUBZERO_CUES: Array[String] = [
	"mother/mv_sub_intimate_notfromme.ogg", # rank 2 overall
	"mother/mv_sub_swarm_adjacent.ogg",     # rank 4
	"mother/mv_sub_counting_below.ogg",
	"mother/mv_sub_subharmonic_ballast.ogg",
	"mother/mv_sub_tape_eaten.ogg",         # dropped under Dampened Protocol
]
## ========================= END OF THE SWAP POINTS =========================

## Bark category -> tier, for the two tiers that are NOT the default. Everything
## absent from this table murmurs.
const VOICE_TIERS: Dictionary = {
	"address": &"directed", "hunt": &"directed",
	"epitaph": &"directed", "exfil": &"directed",
	"kernel_leak": &"subzero",
}

## The Below-the-Kernel lock. The subzero cues do not play above this depth NO
## MATTER WHAT — not on a stress spike, not on a forced bark, not on a dev flag.
## The corpus lets a `kernel_leak` LINE appear from layer 16, and that is right:
## the words leak up before the voice does. But the intimate register is the
## deepest thing she has, it is the one that reads as "she is not where you
## thought she was", and spending it in the LEGACY band would spend it for good.
## 20 is where the KERNEL band starts (corpus `bands`), which is the same place
## DESIGN.md's architecture stops being hers.
const VOICE_SUBZERO_LAYER: int = 20

## The murmur's own attenuation: the DREAD curve the Sentinel drone and the
## bulkheads use, because those are the other things in the game that are meant
## to be audible from three rooms away and to mean "not here yet".
const VOICE_MURMUR_UNIT: float = 20.0
const VOICE_MURMUR_MAX: float = 90.0
## A murmur emitter closer than this to the ear is skipped: at arm's length the
## DREAD curve is deafening and, worse, it stops being architecture.
const VOICE_MURMUR_MIN_DIST: float = 4.0
## Fallback emitter placement when the layer has no vent in earshot: behind and
## slightly above. Behind, because the one thing a murmur must not do is come
## from the direction you are already looking.
const VOICE_FALLBACK_DIST: float = 7.0
const VOICE_FALLBACK_UP: float = 2.2

## The threat sidechain. Deep enough to be under a shriek, not so deep she
## vanishes; a fast attack (a lunge cue must win the moment it fires) and a slow
## release (a mix that pumps back up is more distracting than one that ducked).
const VOICE_DUCK_DB: float = -7.0
const VOICE_DUCK_HOLD: float = 1.4
const VOICE_DUCK_ATTACK: float = 40.0   ## dB per second, downward.
const VOICE_DUCK_RELEASE: float = 6.0   ## dB per second, upward.

## The score steps back while she speaks, and only for the directed tiers — a
## murmur is part of the room tone and does not get to move the music.
const VOICE_MUSIC_DUCK_DB: float = -4.0
const VOICE_MUSIC_DUCK_TAIL: float = 0.8

## Dampened Protocol, audio half, applied to her: −6 dB on top of everything.
const VOICE_DAMPENED_TRIM: float = -6.0
## …and the one cue Dampened Protocol also has to take OUT of the pool. The
## master trim cannot help with `mv_sub_tape_eaten`, because what makes it sharp
## is not its level: it is a cassette head lifting off, which is a hard-edged
## AMPLITUDE gap, and turning the whole cue down leaves the edges exactly as
## abrupt. The comfort tier's promise is "no spikes", so under Dampened Protocol
## she simply does not reach for that one. Honest limitation: the dropouts are
## baked into the file, so this is a substitution, not a softening.
const VOICE_HARSH_CUE: String = "mv_sub_tape_eaten.ogg"
## Where the audition pin looks for a bare cue name.
const VOICE_SUBDIR: String = "mother/"

# --- voice state -------------------------------------------------------------
## Her two mouths: one on the architecture, one in the channel. Exactly one of
## each, so she can never overlap herself.
var _voice_murmur: AudioStreamPlayer3D = null
var _voice_direct: AudioStreamPlayer = null
var _voice_ready: bool = false
## Live sidechain depth in dB (<= 0) and the hold timer that drives it.
var _voice_duck_db: float = 0.0
var _voice_duck_t: float = 0.0
## Seconds left of the music duck she opened for herself.
var _voice_music_duck_t: float = 0.0
## `BP_VOICE_CUE` — a bare cue name that overrides every tier, for auditioning.
var _voice_pin: String = ""
## Cached hub aperture (MotherLens), the Partition's one physical emitter.
var _voice_lens: Node3D = null


## Deferred from `_ready` — see the call site for why it cannot be immediate.
func _wire_voice() -> void:
	var haunt: Node = get_node_or_null(^"/root/Haunt")
	if haunt == null:
		push_warning("[Audio] no HauntDirector — MOTHER has no mouth")
		return
	_voice_pin = OS.get_environment("BP_VOICE_CUE").strip_edges()
	if not _voice_pin.is_empty():
		print("[Audio] MOTHER voice pinned to '%s' (BP_VOICE_CUE)" % _voice_pin)

	_voice_murmur = AudioStreamPlayer3D.new()
	_voice_murmur.name = "MotherMurmur"
	_voice_murmur.bus = BUS_VOICE
	_voice_murmur.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_voice_murmur.unit_size = VOICE_MURMUR_UNIT
	_voice_murmur.max_distance = VOICE_MURMUR_MAX
	add_child(_voice_murmur)

	_voice_direct = AudioStreamPlayer.new()
	_voice_direct.name = "MotherDirect"
	_voice_direct.bus = BUS_VOICE
	add_child(_voice_direct)

	_voice_ready = true
	haunt.mother_spoke.connect(_on_mother_spoke)


## Which tier a bark lands in, given the category and the depth. Pure, so
## `--selftest` can assert the subzero lock without standing up a layer.
func voice_tier_for(category: String, layer: int) -> StringName:
	var tier: StringName = StringName(VOICE_TIERS.get(category, VOICE_MURMUR))
	if tier == VOICE_SUBZERO and layer < VOICE_SUBZERO_LAYER:
		# She still speaks — the WORDS are gated by the corpus, not by us — but in
		# the ordinary directed register. The whisper stays down there.
		return VOICE_DIRECTED
	return tier


## The Director spoke, on this peer. Give it a mouth, or do not.
func _on_mother_spoke(text: String, category: String, _tier: int, _callsign: bool) -> void:
	if not _voice_ready:
		return
	match voice_tier_for(category, Run.layer_number):
		VOICE_SUBZERO:
			_speak_directed(&"mother_close", text)
		VOICE_DIRECTED:
			_speak_directed(&"mother_address", text)
		_:
			_speak_murmur(text)


## The murmur bed. Density-gated, positional, and skipped outright if she is
## already murmuring — a 27 s bed does not get interrupted by the next notice.
##
## The DENSITY GATE IS ONLY HERE, and that is deliberate twice over. First,
## perceived stress is a LOCAL reading (it is computed from this peer's own
## player's distance to hunters), so a roll against it necessarily differs
## between peers — which is right for a murmur in the walls near YOU and wrong
## for a line she aimed at the crew. Second, the directed registers are already
## the most brutally budgeted thing in the game (one address per layer, three per
## run, a 45 s floor); rolling dice on top of the Director's own budget would be
## gating the money moment twice.
func _speak_murmur(text: String) -> void:
	if _voice_murmur.playing:
		return
	if _rng.randf() > Haunt.voice_density():
		return
	var ev: AudioEvent = _events.get(&"mother_murmur")
	if ev == null:
		return
	var stream: AudioStream = _voice_stream(ev, text)
	if stream == null:
		return
	var where: Vector3 = _murmur_anchor()
	_voice_murmur.stream = stream
	_voice_murmur.global_position = where
	_voice_murmur.play()
	_log(&"mother_murmur", where)
	_log_voice(&"mother_murmur", stream)
	# Same line, same event: the caption cannot drift from the sound because there
	# is only one place either of them happens.
	Captions.emit(ev.caption, where, ev.max_dist)


## The directed and Below-the-Kernel registers. Non-positional, and a new line
## takes the mouth from an older one — the current sentence is the true one.
func _speak_directed(key: StringName, text: String) -> void:
	var ev: AudioEvent = _events.get(key)
	if ev == null:
		return
	var stream: AudioStream = _voice_stream(ev, text)
	if stream == null:
		return
	_voice_direct.stream = stream
	_voice_direct.play()
	_log(key, Vector3.ZERO)
	_log_voice(key, stream)
	Captions.emit(ev.caption, _listener_pos(), ev.max_dist)
	# A hole in the score to speak into. Released by `_drive_voice` on the cue's
	# own length, so a longer line holds the duck longer without anyone counting.
	_voice_music_duck_t = stream.get_length() + VOICE_MUSIC_DUCK_TAIL
	set_music_duck(&"mother_voice", VOICE_MUSIC_DUCK_DB)


## Resolve a cue: the audition pin wins, then the line's own cue, then Dampened
## Protocol's substitution.
##
## THE CUE IS CHOSEN FROM THE BARK TEXT, not from the shuffle bag every other
## family in this file uses. That is a deliberate exception to rule #1 at the top,
## and the reason is that MOTHER is not a footstep. Two crewmates hearing
## different grate samples under their own boots is invisible; two crewmates
## hearing the same sentence delivered in two different voices is a crew that
## cannot talk to each other about what she just did. The bark text is already
## byte-identical on every peer (the Director renders it once and RPCs it), so
## hashing it gives a peer-consistent pick with nothing new on the wire, no
## seeding, and no coordination — and it has the pleasant side effect that a given
## line of hers always sounds the same, which is what a voice IS.
##
## `String.hash()` is the engine's own stable string hash, not a per-process
## randomised one, so this holds across peers, platforms and sessions.
func _voice_stream(ev: AudioEvent, text: String) -> AudioStream:
	if not _voice_pin.is_empty():
		var pinned: String = AUDIO_DIR + VOICE_SUBDIR + _voice_pin + ".ogg"
		if ResourceLoader.exists(pinned):
			return _stream_path(pinned, false)
		push_warning("[Audio] BP_VOICE_CUE '%s' is not a cue" % _voice_pin)
	if ev.files.is_empty():
		return null
	var index: int = absi(text.hash()) % ev.files.size()
	# Dampened Protocol takes the tape-eaten cue out of the pool by stepping one
	# along, which keeps this a pure function of the text (so it stays consistent
	# between two peers who have made the same comfort choice) instead of a draw.
	if dampened and ev.files.size() > 1 and ev.files[index].ends_with(VOICE_HARSH_CUE):
		index = (index + 1) % ev.files.size()
	return _stream_path(ev.files[index], false)


## Where a murmur comes out of. The architecture, if the architecture has a hole
## in it near you; her aperture, if you are home; behind your head otherwise.
func _murmur_anchor() -> Vector3:
	var ear: Vector3 = _listener_pos()
	if Run.in_hub:
		var lens: Node3D = _mother_aperture()
		if lens != null:
			return lens.global_position
	var best: Vector3 = Vector3.ZERO
	var best_d: float = 1e9
	for node: Node in get_tree().get_nodes_in_group(Props.GROUP_VENT):
		var vent: Node3D = node as Node3D
		if vent == null or not is_instance_valid(vent):
			continue
		var d: float = vent.global_position.distance_to(ear)
		if d < VOICE_MURMUR_MIN_DIST or d > VOICE_MURMUR_MAX:
			continue
		if d < best_d:
			best_d = d
			best = vent.global_position
	if best_d < 1e9:
		return best
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return ear
	# +basis.z is BEHIND a Godot camera (it looks down −z).
	return cam.global_position + cam.global_transform.basis.z * VOICE_FALLBACK_DIST \
			+ Vector3.UP * VOICE_FALLBACK_UP


## THE PARTITION's one emitter: the sealed optic on the north wall. Cached, and
## re-found whenever the scene has changed under us.
func _mother_aperture() -> Node3D:
	if _voice_lens != null and is_instance_valid(_voice_lens):
		return _voice_lens
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	var found: Array[Node] = scene.find_children("*", "MotherLens", true, false)
	_voice_lens = found[0] as Node3D if not found.is_empty() else null
	return _voice_lens


## Which FILE she actually spoke with, under `--log-audio`. `_log` prints the
## event key, which is the tier — but the tier is three keys and fifteen files,
## and both things anyone needs to check about this layer are about the file: that
## two peers picked the SAME one for one bark, and which one the ear is listening
## to during an audition.
func _log_voice(key: StringName, stream: AudioStream) -> void:
	if not Debug.log_audio or stream == null:
		return
	print("[Audio] MOTHER %s -> %s" % [key, stream.resource_path.get_file()])


## A one-shot with a THREAT caption just played: get her out of its way.
func _arm_voice_duck() -> void:
	_voice_duck_t = VOICE_DUCK_HOLD


## The sidechain envelope and the music-duck release, per frame. Arithmetic only,
## and it touches the mixer solely on the frames the level actually moved.
func _drive_voice(delta: float) -> void:
	if _voice_music_duck_t > 0.0:
		_voice_music_duck_t -= delta
		if _voice_music_duck_t <= 0.0:
			set_music_duck(&"mother_voice", 0.0)

	var want: float = 0.0
	if _voice_duck_t > 0.0:
		_voice_duck_t -= delta
		want = VOICE_DUCK_DB
	if is_equal_approx(_voice_duck_db, want):
		return
	var rate: float = VOICE_DUCK_ATTACK if want < _voice_duck_db else VOICE_DUCK_RELEASE
	_voice_duck_db = move_toward(_voice_duck_db, want, rate * delta)
	_apply_voice_bus()


## Her bus level: slider trim + the live sidechain + the Dampened trim.
func _apply_voice_bus() -> void:
	var idx: int = _idx(BUS_VOICE)
	if idx < 0:
		return
	var damp: float = VOICE_DAMPENED_TRIM if dampened else 0.0
	AudioServer.set_bus_volume_db(idx, _bus_trim(BUS_VOICE) + _voice_duck_db + damp)


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
	# One table, two owners: the label half is CaptionBus's, and its CATEGORY is
	# also the mix's own definition of "audio the player survives by". Read once,
	# here, so the hot path never touches the caption table.
	# `ev.bus != BUS_VOICE` is not defensive noise: MOTHER's Below-the-Kernel cue
	# carries a THREAT caption (it should — see CaptionBus), and without this she
	# would sidechain herself into her own duck the moment she whispered.
	ev.threat = ev.bus != BUS_VOICE and ev.caption != &"" \
			and Captions.TABLE.has(ev.caption) \
			and int((Captions.TABLE[ev.caption] as Dictionary)["cat"]) == Captions.Cat.THREAT
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

	# --- M7 subroutines (World; the cast sounds are things happening in the room) ---
	#
	# On the World bus rather than Player, and 3D rather than 2D, on purpose: a
	# crewmate's STACK PULSE has to arrive from where they are standing, because
	# the whole co-op read of the ability is "somebody over THERE just saved me".
	# The two 2D exceptions below are the ones that are genuinely inside your own
	# process — the ready tick and the refusal — and they go on UI with the rest of
	# the instrument.
	#
	# The pulse gets the LOUD attenuation curve, the same one debris and siphons
	# use, because its audible radius should match the two-room NoiseBus ping it
	# actually makes. A sound the crew can hear further than the Hound can would be
	# lying to them about the cost.
	_def(&"sub_step", ["player/sub_step_whump.ogg"], W,
			{"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"sub_step"})
	_def(&"sub_pulse", ["player/sub_stack_pulse.ogg"], W,
			{"unit": LOUD.unit, "max": LOUD.max, "caption": &"sub_pulse"})
	_def(&"sub_fork", ["player/sub_fork_cast.ogg"], W,
			{"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"sub_fork"})
	_def(&"sub_fork_hit", ["player/sub_fork_hit.ogg"], W,
			{"unit": SCRUB.unit, "max": SCRUB.max})
	_def(&"sub_fork_end", ["player/sub_fork_end.ogg"], W,
			{"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"sub_fork_end"})
	_def(&"sub_barrier", ["player/sub_barrier_cast.ogg"], W,
			{"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"sub_barrier"})
	_def(&"sub_barrier_hit", ["player/sub_barrier_hit.ogg"], W,
			{"unit": SCRUB.unit, "max": SCRUB.max})
	_def(&"sub_barrier_end", ["player/sub_barrier_end.ogg"], W,
			{"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"sub_barrier_end"})
	# Your own process, not the room: 2D, on the instrument bus, and quiet. The
	# ready tick fires every few seconds in a fight and must never become the
	# fight (the quiet-instrument rule has an audio half).
	_def(&"sub_ready", ["ui/ui_sub_ready.ogg"], U, {"twod": true, "vol": -4.0})
	_def(&"sub_refused", ["ui/ui_sub_refused.ogg"], U, {"twod": true, "vol": -3.0})
	# M7 juice: the drop-shaft ride. 2D on the PLAYER bus — this is the trunk going
	# past your own shell, not an event somewhere in the room, and it is the same
	# argument the breath loops are on that bus for.
	_def(&"descent_rush", ["world/dropshaft_rush.ogg"], P, {"twod": true, "vol": -4.0})

	# --- M9 patches (World; every one of these is a thing happening in the room) ---
	#
	# 3D and on the World bus without exception, including the two "pickup" chimes,
	# and that is the design rather than an oversight: a patch grant is PER-PLAYER,
	# so a crewmate absorbing one across a dark hall has to be audible AS being
	# over there. The crew negotiate over voice — "I've got this one, take the
	# next" — and they cannot do that if the only person who hears a pickup is the
	# person who made it.
	#
	# The two loud ones get the LOUD attenuation curve, the same one the siphon and
	# the debris use, because their audible radius should match the NoiseBus ping
	# they actually make. A sound the crew can hear further than the Hound can
	# would be lying to them about the price of their own greed.
	_def(&"patch_pickup", ["world/patch_pickup.ogg"], W,
			{"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"patch_pickup"})
	_def(&"patch_pickup_kernel", ["world/patch_pickup_kernel.ogg"], W,
			{"unit": LOUD.unit, "max": LOUD.max, "caption": &"patch_kernel"})
	_def(&"patch_cache_open", ["world/patch_cache_open.ogg"], W,
			{"unit": LOUD.unit, "max": LOUD.max, "caption": &"patch_cache"})
	_def(&"patch_watchdog", ["world/patch_watchdog.ogg"], W,
			{"unit": COMBAT.unit, "max": COMBAT.max, "caption": &"patch_watchdog"})

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

	# --- MOTHER (Voice) ---
	#
	# Three events, fifteen files, one bus. These are the only entries in this
	# table nothing ever calls `play_3d`/`play_2d` with: the VOICE section owns two
	# dedicated players so she can never talk over herself, and emits their
	# captions on the same line it starts the stream — the shared-event rule, kept
	# by hand in one place rather than by the pooled helpers.
	#
	# No `vol` exceptions anywhere: `build_mother_voice.py` normalises each tier to
	# its own BS.1770 target (−34 / −23 / −27 LUFS), so the murmur already sits
	# 11 dB under the address IN THE FILES. Adding trim here would be making the
	# same decision twice, in the place least likely to be found later.
	_def(&"mother_murmur", VOICE_MURMUR_CUES, BUS_VOICE,
			{"unit": VOICE_MURMUR_UNIT, "max": VOICE_MURMUR_MAX, "caption": &"mother_murmur"})
	_def(&"mother_address", VOICE_DIRECTED_CUES, BUS_VOICE,
			{"twod": true, "caption": &"mother_address"})
	_def(&"mother_close", VOICE_SUBZERO_CUES, BUS_VOICE,
			{"twod": true, "caption": &"mother_close"})
