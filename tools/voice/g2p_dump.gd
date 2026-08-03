extends SceneTree
## M14 bench — dump the letter-to-sound result for every word MOTHER can say.
##
##   godot --headless --path . --script res://tools/voice/g2p_dump.gd -- [--all]
##
## The corpus is the whole of her vocabulary, so this is a complete audit of the
## rules against the only text they will ever see. Sorted by frequency, because a
## wrong reading of THE is a hundred times worse than a wrong reading of BALLAST.
## `--all` prints every word; the default prints the 120 most common plus every
## word whose reading contains a phoneme the synthesiser does not have.

const CORPUS: String = "res://assets/lore/corpus.json"

func _init() -> void:
	var all: bool = OS.get_cmdline_user_args().has("--all")
	var f: FileAccess = FileAccess.open(CORPUS, FileAccess.READ)
	if f == null:
		printerr("no corpus")
		quit(1)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text()) as Dictionary
	var freq: Dictionary = {}
	var entries: int = 0
	for e_v: Variant in data["entries"]:
		var e: Dictionary = e_v as Dictionary
		if String(e.get("kind", "")) != "bark":
			continue
		entries += 1
		var text: String = String(e.get("text", "")).replace("{CALLSIGN}", "")
		var word: String = ""
		for k: int in text.length():
			var c: String = text[k].to_upper()
			if (c >= "A" and c <= "Z") or c == "'":
				word += c
			else:
				if not word.is_empty():
					freq[word] = int(freq.get(word, 0)) + 1
				word = ""
		if not word.is_empty():
			freq[word] = int(freq.get(word, 0)) + 1

	var words: Array = freq.keys()
	words.sort_custom(func(a, b): return int(freq[a]) > int(freq[b]))
	print("[g2p] %d bark entries, %d distinct words" % [entries, words.size()])

	var bad: int = 0
	var shown: int = 0
	for w_v: Variant in words:
		var w: String = String(w_v)
		var ph: PackedStringArray = VoiceG2P.word_to_phones(w)
		var unknown: bool = false
		for p: String in ph:
			if not VoicePhonemes.has(p):
				unknown = true
		if unknown:
			bad += 1
		if all or shown < 120 or unknown:
			print("  %-18s %3d  %s%s" % [w, int(freq[w]), " ".join(ph),
					"   <<< UNKNOWN PHONEME" if unknown else ""])
			shown += 1
	print("[g2p] %d words produced a phoneme the synthesiser has no row for" % bad)
	quit()
