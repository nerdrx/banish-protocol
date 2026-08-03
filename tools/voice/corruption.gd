extends SceneTree
## M14 bench — WHAT DOES CORRUPTION COST HER, IN SECONDS?
##
##   godot --headless --path . --script res://tools/voice/corruption.gd
##
## MOTHER's text decays with depth: `corruption_renderings` is [clean, tier1,
## tier2] and the deep tiers replace roughly a fifth and a half of the characters
## with the glyph set. The question this answers is whether a decayed line takes
## LONGER TO SAY than its clean original — because if it does, the pacing budget
## the writing agent bills against `duration_for` is wrong at exactly the depths
## where a warning matters most.
##
## It did. The first measurement, with glyphs treated as pronounceable content,
## read 1.15x at tier 1 and 1.19x at tier 2, with one line reaching 1.36x. That
## is a machine carefully reciting punctuation marks aloud: comically wrong for
## the fiction, and actively harmful to the timing.
##
## The ruling was that a glyph is ARTIFACT, not content — a corrupted readout
## should sound corrupted, with words going MISSING rather than extra ones
## appearing. This bench is how that was verified, and it is kept so the ratio
## can be re-checked whenever the corpus, the glyph set or the frame builder
## moves. Slot-free lines only, so the comparison is of the same words.

const CORPUS: String = "res://assets/lore/corpus.json"


func _init() -> void:
	var f: FileAccess = FileAccess.open(CORPUS, FileAccess.READ)
	if f == null:
		printerr("no corpus")
		quit(1)
		return
	var doc: Dictionary = JSON.parse_string(f.get_as_text()) as Dictionary

	var lines: int = 0
	var sums: Array[float] = [0.0, 0.0, 0.0]
	var worst: Array[float] = [1.0, 1.0, 1.0]
	var worst_line: Array[String] = ["", "", ""]
	var empties: int = 0
	# The mean is the headline, but the mean is not the risk. What a line budget
	# actually cares about is how many lines GREW and by how much in the tail, so
	# the whole distribution is kept.
	var ratios: Array[PackedFloat32Array] = [PackedFloat32Array(),
		PackedFloat32Array(), PackedFloat32Array()]

	for raw: Variant in doc.get("entries", []) as Array:
		var e: Dictionary = raw as Dictionary
		if String(e.get("kind", "")) != "bark":
			continue
		var renderings: Array = e.get("corruption_renderings", []) as Array
		if renderings.size() < 3:
			continue
		var clean: String = String(renderings[0])
		# Slot-free only: a filled slot is a different number of characters at
		# every tier and would measure the slot, not the corruption.
		if clean.contains("{"):
			continue
		var base: float = MotherVoice.duration_for(clean, VoiceRegisters.DIRECTED)
		if base <= 0.05:
			continue
		lines += 1
		for tier: int in 3:
			var d: float = MotherVoice.duration_for(String(renderings[tier]),
					VoiceRegisters.DIRECTED)
			if d <= 0.05:
				empties += 1
			var ratio: float = d / base
			sums[tier] += ratio
			ratios[tier].append(ratio)
			if ratio > worst[tier]:
				worst[tier] = ratio
				worst_line[tier] = clean

	print("[corruption] %d slot-free lines measured, directed register" % lines)
	for tier: int in 3:
		var sorted: PackedFloat32Array = ratios[tier].duplicate()
		sorted.sort()
		var n: int = sorted.size()
		var p95: float = sorted[mini(int(float(n) * 0.95), maxi(n - 1, 0))] if n > 0 else 1.0
		var grew: int = 0
		for r: float in sorted:
			if r > 1.0001:
				grew += 1
		print("  tier %d   mean %.3fx   p95 %.3fx   worst %.3fx   %d of %d lines grew (%.0f%%)" % [
			tier, sums[tier] / float(maxi(lines, 1)), p95, worst[tier],
			grew, n, 100.0 * float(grew) / float(maxi(n, 1))])
		if tier > 0 and not worst_line[tier].is_empty():
			print("            worst was: %s" % worst_line[tier].substr(0, 66))
	if empties > 0:
		print("  %d renderings collapsed to nothing at all" % empties)
	quit()
