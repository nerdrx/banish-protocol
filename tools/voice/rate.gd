extends SceneTree
## M14 bench — HOW LONG DOES SHE TAKE TO SAY THINGS?
##
##   godot --headless --path . --script res://tools/voice/rate.gd
##
## Her lines are now HEARD, not read, so a bark's length is a duration in the
## mix rather than a number of characters on a caption. This measures the actual
## speaking rate of the shipping engine over the whole corpus, per register, and
## prints a length budget in characters and syllables — which is the interface
## between whoever authors her lines and whoever has to fit them between two
## other sounds.

const CORPUS: String = "res://assets/lore/corpus.json"
## Barks sampled per register. Enough for a stable mean without spending a
## minute of synthesis on a statistic.
const SAMPLE: int = 40


func _init() -> void:
	var f: FileAccess = FileAccess.open(CORPUS, FileAccess.READ)
	if f == null:
		printerr("no corpus")
		quit(1)
		return
	var doc: Dictionary = JSON.parse_string(f.get_as_text()) as Dictionary
	var texts: PackedStringArray = PackedStringArray()
	for raw: Variant in doc["entries"]:
		var e: Dictionary = raw as Dictionary
		if String(e.get("kind", "")) != "bark":
			continue
		var t: String = String(e.get("text", ""))
		# Slots become a plausible filled value so the measurement is of the
		# sentence she actually speaks, not of the template.
		t = t.replace("{CALLSIGN}", "NERDRX").replace("{CREWMATE}", "BREAKER")
		t = t.replace("{LAYER}", "21").replace("{N}", "7").replace("{DATA}", "340")
		t = t.replace("{ROOM}", "THE VAULT").replace("{CREW_COUNT}", "3")
		t = t.replace("{RUNS}", "14").replace("{DEEPEST}", "26").replace("{CYCLES}", "90")
		t = t.replace("{DEAD}", "VANE").replace("{PATCH}", "BIT ROT")
		t = t.replace("{CREATURE}", "THE HOUND").replace("{CMD}", "PURGE")
		if t.contains("{"):
			continue
		texts.append(t)
	print("[rate] %d speakable barks in the corpus" % texts.size())

	for register: String in ["directed", "murmur", "subzero"]:
		var total_s: float = 0.0
		var total_ch: int = 0
		var total_syl: int = 0
		var total_words: int = 0
		var n: int = 0
		var longest: float = 0.0
		var longest_text: String = ""
		var step: int = maxi(texts.size() / SAMPLE, 1)
		var i: int = 0
		while i < texts.size() and n < SAMPLE:
			var t: String = texts[i]
			i += step
			var params: Dictionary = VoiceRegisters.params(register)
			var track: VoiceFrames.Track = VoiceFrames.build(t, params["frames"])
			if track.n <= 0:
				continue
			total_s += track.seconds
			total_ch += t.length()
			total_syl += track.syllables
			total_words += t.split(" ", false).size()
			if track.seconds > longest:
				longest = track.seconds
				longest_text = t
			n += 1
		if n == 0:
			continue
		print("")
		print("  %-9s  %d lines   mean %.2f s   %.1f chars/s   %.2f syllables/s   %.2f words/s" % [
			register, n, total_s / float(n), float(total_ch) / total_s,
			float(total_syl) / total_s, float(total_words) / total_s])
		print("             longest sampled: %.2f s  '%s'" % [longest, longest_text.substr(0, 70)])
		# A budget: what fits in three seconds, which is about the longest a
		# single bark can hold the channel before it starts colliding with the
		# next thing that wants to make a sound.
		print("             3 s budget ~= %d characters / %d syllables" % [
			int(3.0 * float(total_ch) / total_s), int(3.0 * float(total_syl) / total_s)])
	quit()
