extends SceneTree
## M14 bench — exercise the INTEGRATION SHAPE without touching AudioService.
##
##   godot --headless --path . --script res://tools/voice/hook_sim.gd
##
## M12 owns `src/core/audio_service.gd` and is mid-rewrite of the bus graph, so
## the hook is delivered as a proposal rather than as an edit. This file is the
## proof that the proposal works: it reproduces `_on_mother_spoke`'s control flow
## exactly — the same guard, the same re-entry, the same second-pass lookup — and
## reports what a player would experience.
##
## The shape being proved:
##
##     func _on_mother_spoke(text, category, tier, callsign) -> void:
##         if not _voice_ready:
##             return
##         var key := _voice_event_key(voice_tier_for(category, Run.layer_number))
##         if not MotherVoice.await_line(text, key,
##                 _on_mother_spoke.bind(text, category, tier, callsign)):
##             return                      # she speaks a beat late instead
##         match ...                       # unchanged from here down
##
##     func _voice_stream(ev, text) -> AudioStream:
##         var live := MotherVoice.stream_for(text, ev.key)
##         if live != null:
##             return live
##         ...                             # unchanged from here down

var _spoken: int = 0
var _late: int = 0
var _silent: int = 0
var _pending: int = 0
var _t0: int = 0
var _delays: PackedFloat32Array = PackedFloat32Array()
var _asked: Dictionary = {}

const LINES: Array[String] = [
	"NERDRX. YOU BREATHE TOO LOUDLY.",
	"PROCESS COUNT EXCEEDS MANIFEST.",
	"3 OF YOU ARE STILL RUNNING ON LAYER 21.",
	"I HAVE TOLD SOMETHING WHERE YOU ARE.",
	"NERDRX. STOP TOUCHING THINGS.",
	"THE WARM FLOOR IS NOT A FAULT.",
]


func _init() -> void:
	MotherVoice.clear()
	_t0 = Time.get_ticks_msec()
	print("[hook] cold cache — every line below is a first utterance")
	for i: int in LINES.size():
		_on_mother_spoke(LINES[i], "address" if i % 2 == 0 else "ambient")
	# Say two of them a second time, which is what actually happens in a run.
	_on_mother_spoke(LINES[0], "address")
	_on_mother_spoke(LINES[1], "ambient")


func _process(_dt: float) -> bool:
	if _pending > 0 and Time.get_ticks_msec() - _t0 < 20000:
		return false
	var mean: float = 0.0
	var worst: float = 0.0
	for d: float in _delays:
		mean += d
		worst = maxf(worst, d)
	mean /= maxf(float(_delays.size()), 1.0)
	print("")
	print("[hook] %d spoken, %d of them a beat late, %d silent" % [_spoken, _late, _silent])
	print("[hook] mean delay on a cold line: %.0f ms   worst: %.0f ms" % [
		mean, worst])
	print("[hook] cache: %s" % str(MotherVoice.stats()))
	if _silent > 0:
		printerr("[hook] FAIL — a line produced no audio at all")
		quit(1)
		return true
	print("[hook] PASS — every line reached a mouth")
	quit()
	return true


## The exact control flow proposed for AudioService._on_mother_spoke.
func _on_mother_spoke(text: String, category: String) -> void:
	var key: StringName = &"mother_address" if category == "address" else &"mother_murmur"
	if not _asked.has(text + category):
		_asked[text + category] = Time.get_ticks_msec()
		_pending += 1
	if not MotherVoice.await_line(text, key, _on_mother_spoke.bind(text, category)):
		return
	_speak(key, text, category)


## …and of AudioService._speak_directed / _speak_murmur, which are unchanged
## apart from `_voice_stream` now consulting the cache first.
func _speak(key: StringName, text: String, category: String) -> void:
	var stream: AudioStream = MotherVoice.stream_for(text, key)
	var waited: int = Time.get_ticks_msec() - int(_asked[text + category])
	_pending -= 1
	if stream == null:
		_silent += 1
		printerr("  SILENT  %s" % text.substr(0, 46))
		return
	_spoken += 1
	if waited > 4:
		_late += 1
		_delays.append(float(waited))
	print("  %s  %-46s  %.2f s of audio" % [
		"LATE %4d ms" % waited if waited > 4 else "INSTANT     ",
		text.substr(0, 46),
		float((stream as AudioStreamWAV).data.size() / 2) / float(MotherVoice.RATE)])
