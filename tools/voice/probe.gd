extends SceneTree
## M14 bench — stage-by-stage probe. Prints between every stage of the pipeline
## so a hang or a NaN can be localised without a debugger attached to a headless
## process. Throwaway in spirit, kept because "which stage" is the first question
## every time.

func _init() -> void:
	var text: String = "MOTHER SEES YOU."
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() > 0:
		text = args[0]
	printerr("[probe] text: ", text)

	var words: Array[Dictionary] = VoiceG2P.split_words(text)
	printerr("[probe] words: ", words.size())
	for w in words:
		printerr("   ", w)

	var toks: PackedStringArray = VoiceG2P.tokenise(text)
	printerr("[probe] phones: ", " ".join(toks))

	var p: Dictionary = VoiceRegisters.params("clean")
	var tr: VoiceFrames.Track = VoiceFrames.build(text, p["frames"])
	printerr("[probe] frames: n=", tr.n, " seconds=", tr.seconds, " syll=", tr.syllables)

	var t0: int = Time.get_ticks_usec()
	var s: PackedFloat32Array = VoiceKlatt.render(tr, 48000, p["klatt"], 12345)
	printerr("[probe] klatt: ", s.size(), " samples in ", (Time.get_ticks_usec() - t0) / 1000, " ms")

	t0 = Time.get_ticks_usec()
	var lu: float = VoiceMeter.integrated_lufs(s, 48000)
	printerr("[probe] lufs: ", lu, " in ", (Time.get_ticks_usec() - t0) / 1000, " ms")

	t0 = Time.get_ticks_usec()
	var tp: float = VoiceMeter.true_peak_dbtp(s)
	printerr("[probe] dbtp: ", tp, " in ", (Time.get_ticks_usec() - t0) / 1000, " ms")

	t0 = Time.get_ticks_usec()
	var post: PackedFloat32Array = VoiceTape.process(s.duplicate(), 48000,
			VoiceRegisters.params("directed")["tape"], 12345)
	printerr("[probe] tape: ", post.size(), " in ", (Time.get_ticks_usec() - t0) / 1000, " ms")

	VoiceWav.write_file("/tmp/claude-1000/probe.wav", VoiceWav.peak_normalise(s, 0.9), 48000)
	printerr("[probe] done")
	quit()
