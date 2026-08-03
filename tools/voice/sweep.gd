extends SceneTree
## M14 bench — sweep one tape parameter and print what it does to the loudness
## landing. Used to settle the subzero register's record-amp setting: the
## intimate tier kept coming up short of its -27 LUFS target because the
## true-peak ceiling was catching its creak peaks, and the question "how much
## compression buys how much loudness" has an answer, not an opinion.

func _init() -> void:
	var text: String = "PROCESS COUNT EXCEEDS MANIFEST. NOTHING IS MISSING."
	print("  comp  ratio   LUFS     dBTP    crest")
	for comp: float in [0.30, 0.20, 0.12, 0.08, 0.05]:
		for ratio: float in [4.0, 6.0, 10.0]:
			var p: Dictionary = VoiceRegisters.params(VoiceRegisters.SUBZERO)
			var tape: Dictionary = (p["tape"] as Dictionary).duplicate()
			tape["comp"] = comp
			tape["comp_ratio"] = ratio
			var seed: int = 12345
			var tr: VoiceFrames.Track = VoiceFrames.build(text, p["frames"])
			var x: PackedFloat32Array = VoiceKlatt.render(tr, MotherVoice.RATE,
					p["klatt"], seed)
			x = VoiceTape.process(x, MotherVoice.RATE, tape, seed)
			var rep: Dictionary = VoiceMeter.normalise_to(x, MotherVoice.RATE,
					-27.0, VoiceRegisters.CEILING_DBTP)
			print("  %.2f  %5.1f  %7.2f  %7.2f  %6.2f" % [comp, ratio,
					float(rep["lufs"]), float(rep["dbtp"]),
					float(rep["dbtp"]) - float(rep["lufs"])])
	quit()
