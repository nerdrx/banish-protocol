extends Node
## M12 SENSATION — the acoustic instrument.
##
##   godot --headless --path . res://tools/sensation_bench/acoustics_probe.tscn \
##       -- --out /path/to/dir [--seed N] [--layer N]
##
## VERIFY WITH MEASUREMENTS, NOT VIBES. Reverb is the easiest thing in games to
## claim and one of the harder ones to prove, so this runs the real mixer — the
## real `AudioService` buses, the real `AudioEffectReverb` instances, the real
## `RoomAcoustics` model — puts an impulse through it, and reads the decay back
## off an `AudioEffectCapture` on Master. Nothing here simulates the audio path;
## it measures it.
##
## It produces three things, all into `--out`:
##
##   1. `rt60.csv`      — one row per archetype: the room's REAL dimensions from
##                        a REAL generated LayerGraph, the modelled RT60, and the
##                        RT60 actually measured coming out of the mixer.
##   2. `decay_*.f32`   — the raw envelope of each archetype's impulse response,
##                        for the plot.
##   3. `occlusion.csv` — the A/B: each creature cue played clear and occluded,
##                        with per-band energies, so "muffled but still tellable
##                        apart" is a number instead of an opinion.
##
## `tools/sensation_bench/plot_acoustics.py` turns them into the figures.
##
## WHY THE ANALYSIS IS NOT IN HERE: an FFT in GDScript would be slow, hard to
## check, and a second implementation of something numpy already does correctly.
## The engine's job is to produce samples that really came out of the game's
## mixer; the maths belongs in a file a human can read next to a plot.

## Envelope block size, in samples at 44.1 kHz. 10 ms is fine enough to resolve a
## 0.35 s tail into 35 points and coarse enough to be a smooth curve.
const BLOCK: int = 441
## How long to record after each impulse.
const TAIL_SECONDS: float = 4.5
## How long to let the mixer settle between measurements, so one tail cannot
## contaminate the next.
const GAP_MSEC: int = 400

var _out: String = ""
var _seed: int = 424242
var _layer: int = 7
var _capture: AudioEffectCapture = null
var _player: AudioStreamPlayer = null
var _rows: PackedStringArray = PackedStringArray()
var _occ_rows: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_parse_args()
	if _out.is_empty():
		printerr("[Acoustics] --out is required")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_install_capture()
	_player = AudioStreamPlayer.new()
	add_child(_player)
	# Deferred so the autoloads have finished standing up their buses.
	_run.call_deferred()


func _parse_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i: int in args.size():
		match args[i]:
			"--out":
				if i + 1 < args.size():
					_out = args[i + 1]
			"--seed":
				if i + 1 < args.size():
					_seed = int(args[i + 1])
			"--layer":
				if i + 1 < args.size():
					_layer = int(args[i + 1])


## The capture goes LAST on Master, so what it records is exactly what a player's
## output device would have been handed — every bus, every effect, the reverb and
## the comfort tier included.
func _install_capture() -> void:
	var master: int = AudioServer.get_bus_index("Master")
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = TAIL_SECONDS + 2.0
	AudioServer.add_bus_effect(master, _capture)
	# The automation mute would make every measurement a row of zeroes.
	AudioServer.set_bus_mute(master, false)


func _run() -> void:
	var graph: LayerGraph = LayerGraph.generate(_seed, _layer)
	print("[Acoustics] layer %d seed %d: %d rooms, %d corridors" % [
		_layer, _seed, graph.rooms.size(), graph.corridors.size()])

	_rows.append("space,archetype,w_m,d_m,h_m,volume_m3,surface_m2,alpha," \
			+ "rt60_model_s,rt60_target_s,room_size,wet,damping,predelay_ms,rt60_measured_s,t20_s")

	# One representative of every acoustic kind, taken from the REAL graph so the
	# numbers are about rooms the game actually builds. The alcove is the one
	# space the generator has no archetype for — it is any small volume — so it is
	# measured at the size the vocabulary's smallest side room really is.
	for kind: StringName in [RoomAcoustics.KIND_HALL, RoomAcoustics.KIND_TRUNK,
			RoomAcoustics.KIND_ROOM, RoomAcoustics.KIND_SANCTUARY,
			RoomAcoustics.KIND_CORRIDOR, RoomAcoustics.KIND_ALCOVE]:
		var dims: Vector3 = _dimensions_for(graph, kind)
		_measure_space(kind, dims)

	_measure_occlusion()

	_write(_out.path_join("rt60.csv"), _rows)
	_write(_out.path_join("occlusion.csv"), _occ_rows)
	print("[Acoustics] wrote %s" % _out)
	get_tree().quit(0)


## Find a real example of this acoustic kind in the generated graph, and return
## its width, depth and built height. Falls back to the vocabulary's own typical
## numbers when a seed happens not to contain one (a non-backdoor layer has no
## sanctuary), and says so in the log rather than silently inventing a room.
func _dimensions_for(graph: LayerGraph, kind: StringName) -> Vector3:
	if kind == RoomAcoustics.KIND_ALCOVE:
		# Not an archetype: any volume under ALCOVE_VOLUME. A 4 x 4 x 4 side
		# space is 64 m3, comfortably inside it, and is about the size of the
		# Compiler recesses.
		return Vector3(4.0, 4.0, 4.0)
	if kind == RoomAcoustics.KIND_CORRIDOR:
		var widest: Vector3 = Vector3.ZERO
		var longest: float = 0.0
		for corridor: Dictionary in graph.corridors:
			var lo: Vector2 = corridor["min"]
			var hi: Vector2 = corridor["max"]
			var w: float = absf(hi.x - lo.x)
			var d: float = absf(hi.y - lo.y)
			if maxf(w, d) > longest:
				longest = maxf(w, d)
				widest = Vector3(w, d, float(corridor["h"]))
		if longest > 0.0:
			return widest
		return Vector3(4.0, 18.0, 4.0)

	for room: Dictionary in graph.rooms:
		if RoomAcoustics._kind_of(String(room["archetype"])) != kind:
			continue
		var lo: Vector2 = room["min"]
		var hi: Vector2 = room["max"]
		var dims: Vector3 = Vector3(absf(hi.x - lo.x), absf(hi.y - lo.y),
				float(room["h"]))
		# Skip a room the size promoter would call an alcove: it would measure
		# the alcove twice and never measure the kind we asked for.
		if dims.x * dims.y * dims.z >= RoomAcoustics.ALCOVE_VOLUME:
			return dims
	print("[Acoustics] seed has no %s; using the vocabulary's typical box" % kind)
	match kind:
		RoomAcoustics.KIND_TRUNK: return Vector3(12.0, 12.0, 12.0)
		RoomAcoustics.KIND_SANCTUARY: return Vector3(16.0, 14.0, 8.5)
		_: return Vector3(14.0, 12.0, 5.5)


func _measure_space(kind: StringName, dims: Vector3) -> void:
	Audio.force_space(kind, dims.x, dims.y, dims.z)
	Audio.settle_acoustics()
	var space: Dictionary = Audio.current_space()
	var params: Dictionary = RoomAcoustics.reverb_params(space)

	var response: PackedFloat32Array = _impulse_response(Audio.BUS_WORLD)
	var decay: Vector2 = _decay_times(_envelope(response), float(params["predelay"]))
	_write_floats(_out.path_join("decay_%s.f32" % kind), response)

	_rows.append("%s,%s,%.2f,%.2f,%.2f,%.1f,%.1f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.1f,%.3f,%.3f" % [
		kind, kind, dims.x, dims.y, dims.z,
		float(space["volume"]), float(space["surface"]),
		float(RoomAcoustics.ALPHA[kind]),
		float(space["rt60"]), float(params["rt60_delivered"]),
		float(params["room_size"]), float(params["wet"]),
		float(params["damping"]), float(params["predelay"]),
		decay.x, decay.y])
	print("[Acoustics] %-9s %5.1f x %5.1f x %4.1f m  V=%7.0f  physics %.2f s -> target %.2f s -> measured %.2f s  wet %.3f  predelay %4.1f ms" % [
		kind, dims.x, dims.y, dims.z, float(space["volume"]),
		float(space["rt60"]), float(params["rt60_delivered"]), decay.x,
		float(params["wet"]), float(params["predelay"])])


## THE OCCLUSION A/B, and the reason it is a spectral measurement rather than a
## level one.
##
## M11's hunters are getting distinct audio signatures, and the intent is that a
## player can tell WHICH one is behind a bulkhead from the muffled sound alone.
## That makes "does the low-pass preserve identity" a real, checkable question:
## if occlusion collapses every creature onto the same distant thud, the feature
## has taken information away from the player rather than added it. So each cue
## is played clear and occluded, and the band energies of both are written out —
## `plot_acoustics.py` reports how far apart the creatures still are after the
## filter compared with before it.
func _measure_occlusion() -> void:
	_occ_rows.append("cue,path,block,rms")
	# A fixed, ordinary room for both halves, so the A/B is about the occlusion
	# and not about which space each was measured in.
	Audio.force_space(RoomAcoustics.KIND_ROOM, 14.0, 12.0, 5.5)
	Audio.settle_acoustics()

	var cues: Array[String] = [
		"creatures/scrubber_lunge_shriek_01.ogg",
		"creatures/sentinel_presence_drone_loop.ogg",
		"creatures/hound_howl.ogg",
		"creatures/scrubber_skitter_loop_01.ogg",
	]
	for cue: String in cues:
		var path: String = "res://assets/audio/" + cue
		if not ResourceLoader.exists(path):
			print("[Acoustics] missing cue %s" % path)
			continue
		var name: String = cue.get_file().get_basename()
		for pair: Array in [["clear", Audio.BUS_CREATURES],
				["occluded", Audio.BUS_CREAT_OCC]]:
			var samples: PackedVector2Array = _record(path, StringName(pair[1]), 1.6)
			_write_floats(_out.path_join("occ_%s_%s.f32" % [name, pair[0]]),
					_mono(samples))
			print("[Acoustics] occlusion %s / %s: %d samples" % [
				name, pair[0], samples.size()])


# ------------------------------------------------------------------ capture --

## Fire a one-sample impulse into `bus` and return the RAW mono response.
##
## THE REVERB IS SWITCHED TO `dry = 0` FOR THE DURATION, and that is the whole
## reason this measurement works. In the game the reverb runs as an insert with
## `dry = 1`, because the direct sound must always pass through untouched — but
## that means a one-sample impulse arrives at the capture at full scale with the
## reverberant field forty decibels underneath it, and a T20 measured from that
## peak measures the click, not the room. Every archetype came back at 0.03 s.
##
## What a decay time is ABOUT is the reverberant field, so the instrument
## isolates it: dry down for the measurement, restored immediately after. This is
## the textbook impulse response of the room the mixer is currently modelling,
## and the game's own signal path is not modified — only observed differently.
func _impulse_response(bus: StringName) -> PackedFloat32Array:
	var verb: AudioEffectReverb = _reverb_on(bus)
	var kept_dry: float = 1.0
	var kept_wet: float = 0.0
	if verb != null:
		kept_dry = verb.dry
		kept_wet = verb.wet
		verb.dry = 0.0
		# Unity wet so the recorded level is the room's response and not the
		# room's response times the send level — the send level is reported
		# separately in the CSV, and multiplying the two here would hide it.
		verb.wet = 1.0
	var samples: PackedVector2Array = _record_stream(_impulse(), bus, TAIL_SECONDS)
	if verb != null:
		verb.dry = kept_dry
		verb.wet = kept_wet
	return _mono(samples)


## The live reverb instance on a bus, found by type rather than by index so it
## survives anyone adding another effect to the chain.
func _reverb_on(bus: StringName) -> AudioEffectReverb:
	var idx: int = AudioServer.get_bus_index(bus)
	if idx < 0:
		return null
	for i: int in AudioServer.get_bus_effect_count(idx):
		var verb: AudioEffectReverb = AudioServer.get_bus_effect(idx, i) as AudioEffectReverb
		if verb != null:
			return verb
	return null


## 10 ms-block peak envelope of a raw response.
func _envelope(samples: PackedFloat32Array) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	var acc: float = 0.0
	var n: int = 0
	for v: float in samples:
		acc = maxf(acc, absf(v))
		n += 1
		if n >= BLOCK:
			out.append(acc)
			acc = 0.0
			n = 0
	return out


func _record(path: String, bus: StringName, seconds: float) -> PackedVector2Array:
	return _record_stream(load(path) as AudioStream, bus, seconds)


func _record_stream(stream: AudioStream, bus: StringName,
		seconds: float) -> PackedVector2Array:
	if stream == null:
		return PackedVector2Array()
	_player.stream = stream
	_player.bus = bus
	_player.volume_db = 0.0
	OS.delay_msec(GAP_MSEC)
	_capture.clear_buffer()
	_player.play()
	var out: PackedVector2Array = PackedVector2Array()
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(seconds * 1000.0):
		OS.delay_msec(5)
		var available: int = _capture.get_frames_available()
		if available > 0:
			out.append_array(_capture.get_buffer(available))
	_player.stop()
	return out


## A single full-scale sample. The only source whose own envelope cannot
## contaminate the decay being measured — a real game sound has a tail of its
## own and would be measuring itself as much as the room.
func _impulse() -> AudioStreamWAV:
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 44100
	wav.stereo = false
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(2 * 64)
	bytes.fill(0)
	bytes.encode_s16(0, 32000)
	wav.data = bytes
	return wav


## T20 and the RT60 extrapolated from it, per ISO 3382: measure the time to fall
## 20 dB from the peak and multiply by three. Extrapolating from T20 rather than
## reading a literal 60 dB fall is standard practice and it is what makes the
## measurement robust against the noise floor.
## `predelay_ms` is skipped before the peak is looked for: the reverberant field
## does not start until the first reflection arrives, and a peak found inside the
## predelay gap would be noise.
func _decay_times(envelope: PackedFloat32Array, predelay_ms: float) -> Vector2:
	var block_ms: float = float(BLOCK) / 44.1
	var from: int = int(ceil(predelay_ms / block_ms))
	var peak: float = 0.0
	var peak_at: int = from
	for i: int in range(mini(from, envelope.size()), envelope.size()):
		if envelope[i] > peak:
			peak = envelope[i]
			peak_at = i
	if peak <= 0.0:
		return Vector2.ZERO
	for i: int in range(peak_at, envelope.size()):
		var db: float = 20.0 * log(maxf(envelope[i], 1e-7) / peak) / log(10.0)
		if db <= -20.0:
			var t20: float = float(i - peak_at) * float(BLOCK) / 44100.0
			return Vector2(t20 * 3.0, t20)
	return Vector2(0.0, 0.0)


# -------------------------------------------------------------------- output --

func _mono(samples: PackedVector2Array) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(samples.size())
	for i: int in samples.size():
		out[i] = (samples[i].x + samples[i].y) * 0.5
	return out


func _write(path: String, lines: PackedStringArray) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("[Acoustics] cannot write %s" % path)
		return
	file.store_string("\n".join(lines) + "\n")
	file.close()


func _write_floats(path: String, values: PackedFloat32Array) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("[Acoustics] cannot write %s" % path)
		return
	file.store_buffer(values.to_byte_array())
	file.close()
