extends SceneTree
## M12 SENSATION — the engine calibration behind `RoomAcoustics.RT60_BY_SIZE`.
##
##   godot --headless --path . --script tools/sensation_bench/calibrate_reverb.gd
##
## `AudioEffectReverb.room_size` is a 0..1 dial with no documented relationship
## to a decay time, and the acoustic model needs the inverse of that
## relationship: given a room whose physics say 1.4 seconds, what number goes in
## the dial. Guessing it would have made every RT60 in the model a fiction.
##
## So it is measured. A one-sample impulse through the effect with `dry = 0`,
## captured off an `AudioEffectCapture`, T20 read off the block envelope and
## extrapolated to RT60 per ISO 3382.
##
## ## Measured UNDER THE GAME'S OWN SETTINGS, which is the whole point
##
## An earlier sweep of this ran at `damping = 0`, `hipass = 0` and reported up to
## 3.25 s at `room_size` 0.9 — and the shipped mixer then delivered 1.2 s for the
## same room, because the game runs the effect with damping and (on Creatures)
## a high-pass, and `hipass` in particular removes the low band that decays
## slowest. A calibration taken under conditions the game does not use is not a
## calibration. This one runs at the damping the model actually asks for in a
## hard, reflective space and at the World bus's real `hipass`, so the table it
## prints is a table about the shipping mix.
##
## Re-run it after ANY change to `HIPASS_WORLD`, `DAMP_BASE` or `DAMP_PER_ALPHA`,
## and paste the result into `RoomAcoustics.RT60_BY_SIZE`.

const SETTLE_MSEC: int = 220
const TAIL_MSEC: int = 4500
const BLOCK: int = 441

var _capture: AudioEffectCapture = null
var _player: AudioStreamPlayer = null
var _verb: AudioEffectReverb = null
var _done: bool = false


func _init() -> void:
	var idx: int = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "Calib")
	_verb = AudioEffectReverb.new()
	_verb.dry = 0.0
	_verb.wet = 1.0
	_verb.spread = 1.0
	_verb.predelay_msec = 12.0
	_verb.predelay_feedback = 0.0
	AudioServer.add_bus_effect(idx, _verb)
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = 8.0
	AudioServer.add_bus_effect(idx, _capture)
	_player = AudioStreamPlayer.new()
	_player.bus = "Calib"
	_player.stream = _impulse()
	root.add_child(_player)


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	# The conditions the shipping mix actually uses on the World bus: no reverb
	# high-pass (the bus is already high-passed at 35 Hz upstream, so a second one
	# only costs tail), and the damping a hard reflective space asks for.
	_verb.hipass = RoomAcoustics.HIPASS_WORLD
	_verb.damping = RoomAcoustics.DAMP_BASE \
			+ float(RoomAcoustics.ALPHA[RoomAcoustics.KIND_HALL]) * RoomAcoustics.DAMP_PER_ALPHA
	print("# calibrated at hipass=%.3f damping=%.3f" % [_verb.hipass, _verb.damping])
	print("room_size,rt60_s,t20_s")
	var table: PackedStringArray = PackedStringArray()
	for step: int in range(1, 10):
		var size: float = float(step) / 10.0
		_verb.room_size = size
		var decay: Vector2 = _measure()
		print("%.2f,%.3f,%.3f" % [size, decay.x, decay.y])
		table.append("%.2f" % decay.x)
	print("\nconst RT60_BY_SIZE: Array[float] = [\n\t%s,\n]" % ", ".join(table))
	quit()
	return true


func _measure() -> Vector2:
	OS.delay_msec(SETTLE_MSEC)
	_capture.clear_buffer()
	_player.play()
	var envelope: PackedFloat32Array = PackedFloat32Array()
	var acc: float = 0.0
	var n: int = 0
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < TAIL_MSEC:
		OS.delay_msec(5)
		var available: int = _capture.get_frames_available()
		if available <= 0:
			continue
		for frame: Vector2 in _capture.get_buffer(available):
			acc = maxf(acc, absf(frame.x))
			n += 1
			if n >= BLOCK:
				envelope.append(acc)
				acc = 0.0
				n = 0
	# Skip the predelay gap before looking for the peak of the reverberant field.
	var from: int = 2
	var peak: float = 0.0
	var peak_at: int = from
	for i: int in range(from, envelope.size()):
		if envelope[i] > peak:
			peak = envelope[i]
			peak_at = i
	if peak <= 0.0:
		return Vector2.ZERO
	for i: int in range(peak_at, envelope.size()):
		if 20.0 * log(maxf(envelope[i], 1e-7) / peak) / log(10.0) <= -20.0:
			var t20: float = float(i - peak_at) * float(BLOCK) / 44100.0
			return Vector2(t20 * 3.0, t20)
	return Vector2.ZERO


func _impulse() -> AudioStreamWAV:
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 44100
	wav.stereo = false
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(128)
	bytes.fill(0)
	bytes.encode_s16(0, 32000)
	wav.data = bytes
	return wav
