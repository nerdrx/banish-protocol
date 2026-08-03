extends SceneTree
## M14 bench — render arbitrary text through the LIVE engine to WAV files.
##
##   godot --headless --path . --script res://tools/voice/render.gd -- \
##       --out /tmp/voice --register directed "TEXT ONE" "TEXT TWO"
##
## This is not a build step and it produces nothing the game loads. It is the
## audition path: the same code the game will speak with, dumped to disk so a
## human can listen and say whether she is understandable yet.

func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var out_dir: String = "/tmp/voice"
	var register: String = "directed"
	var texts: PackedStringArray = PackedStringArray()
	var prefix: String = ""
	var dry: bool = false
	var i: int = 0
	while i < args.size():
		match args[i]:
			"--out":
				i += 1
				out_dir = args[i]
			"--prefix":
				i += 1
				prefix = args[i]
			"--register":
				i += 1
				register = args[i]
			"--dry":
				dry = true
			_:
				texts.append(args[i])
		i += 1
	if texts.is_empty():
		texts.append("BREAKER. YOU BREATHE TOO LOUDLY.")

	DirAccess.make_dir_recursive_absolute(out_dir)
	var n: int = 0
	for text: String in texts:
		var t0: int = Time.get_ticks_usec()
		var res: Dictionary = MotherVoice.render_debug(text, register, dry)
		var us: int = Time.get_ticks_usec() - t0
		var samples: PackedFloat32Array = res["samples"]
		var name: String = "%s%02d_%s" % [prefix, n, _slug(text)]
		var path: String = out_dir.path_join(name + ".wav")
		VoiceWav.write_file(path, samples, MotherVoice.RATE)
		print("[render] %-52s %5.2fs  %6.1f ms  %7.2f LUFS  %6.2f dBTP  %s" % [
			name.substr(0, 52), float(samples.size()) / float(MotherVoice.RATE),
			us / 1000.0, float(res["lufs"]), float(res["dbtp"]), path])
		print("         phones: %s" % String(res["phones"]))
		n += 1
	quit()


func _slug(text: String) -> String:
	var s: String = ""
	for k: int in text.length():
		var c: String = text[k].to_lower()
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			s += c
		elif not s.ends_with("_"):
			s += "_"
	return s.substr(0, 46).strip_edges().trim_suffix("_")
