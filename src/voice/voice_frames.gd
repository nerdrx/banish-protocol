class_name VoiceFrames
extends RefCounted
## M14 — phonemes in, a Klatt parameter track out.
##
## This is where intelligibility actually lives, and it is worth being blunt
## about why: correct phonemes played one after another are still mush. What a
## listener decodes is the MOVEMENT between them — the F2 transition out of a
## stop is the only cue there is for whether it was /b/, /d/ or /g/, and the two
## are acoustically identical apart from that sweep. So this file does not emit
## "a segment, then the next segment". It lays down TARGET ANCHORS in time and
## interpolates between them, which makes every transition a real one and makes
## coarticulation fall out for free instead of being a feature somebody has to
## remember to add.
##
## Frames are 5 ms (200 Hz). That is fast enough to resolve a 10 ms burst as its
## own event and slow enough that a 3 s utterance is 600 frames of arithmetic —
## nothing, next to the per-sample synthesis that consumes them.
##
## MOTHER DOES NOT REDUCE HER VOWELS. English speakers collapse unstressed
## nuclei toward schwa; it is most of what makes natural speech sound natural and
## it is also most of what makes synthetic speech unintelligible, because a schwa
## carries no information. She keeps every vowel's identity and only shortens it.
## That single decision buys a large amount of clarity AND is exactly in
## character: vowel reduction is an economy of effort, and she is not tired.

const P_F0: int = 0        ## Hz
const P_AV: int = 1        ## voicing amplitude, linear
const P_AH: int = 2        ## aspiration (noise through the cascade)
const P_AF: int = 3        ## frication (noise through the parallel bank)
const P_F1: int = 4
const P_B1: int = 5
const P_F2: int = 6
const P_B2: int = 7
const P_F3: int = 8
const P_B3: int = 9
const P_NZ: int = 10       ## nasal anti-formant frequency, Hz
const P_NAMT: int = 11     ## nasal coupling, 0..1
const P_FF1: int = 12      ## parallel frication resonator 1
const P_FB1: int = 13
const P_FA1: int = 14
const P_FF2: int = 15      ## parallel frication resonator 2
const P_FB2: int = 16
const P_FA2: int = 17
const P_COUNT: int = 18

const FRAME_MS: float = 5.0
const FRAME_HZ: float = 200.0

## A parameter block, ready for `VoiceKlatt`.
class Track extends RefCounted:
	var frames: PackedFloat32Array = PackedFloat32Array()
	var n: int = 0
	## Seconds. Derived, but every consumer wants it and none of them should be
	## re-deriving it from the frame count and the frame rate.
	var seconds: float = 0.0
	## Syllable count, for the selftest's "did this actually parse as speech"
	## check and for the cache's cost estimate.
	var syllables: int = 0


## Build a parameter track for one utterance.
##
## `opts` is a register block from `VoiceRegisters`; every field has a default
## here so a caller can pass `{}` and still get her ordinary directed voice.
static func build(text: String, opts: Dictionary = {}) -> Track:
	var rate: float = float(opts.get("rate", 1.0))
	var f0_base: float = float(opts.get("f0", 118.0))
	var declination: float = float(opts.get("declination", -0.16))
	var accent: float = float(opts.get("accent", 1.6))
	var terminal: float = float(opts.get("terminal", -3.0))
	var final_lengthen: float = float(opts.get("final_lengthen", 1.55))
	var word_gap: float = float(opts.get("word_gap", 0.022))
	var lead_in: float = float(opts.get("lead_in", 0.14))
	var tail: float = float(opts.get("tail", 0.34))
	var breathiness: float = float(opts.get("breathiness", 0.06))
	var whisper: float = float(opts.get("whisper", 0.0))
	var clarity: float = float(opts.get("clarity", 1.0))

	var segs: Array[Dictionary] = _segments(text, rate, final_lengthen, word_gap)
	if segs.is_empty():
		var empty: Track = Track.new()
		return empty

	# --- lay the timeline out ------------------------------------------------
	var t: float = lead_in
	for s: Dictionary in segs:
		s["t0"] = t
		t += float(s["dur"])
		s["t1"] = t
		t += float(s["gap"])
	var total: float = t + tail
	var n: int = int(ceil(total * FRAME_HZ)) + 1

	var tr: Track = Track.new()
	tr.n = n
	tr.seconds = total
	tr.frames = PackedFloat32Array()
	tr.frames.resize(n * P_COUNT)
	for s: Dictionary in segs:
		if bool(s.get("nucleus", false)):
			tr.syllables += 1

	# --- formant anchors -----------------------------------------------------
	# (time, f1, f2, f3, b1, b2, b3). Interpolating between these IS the
	# transition model; there is no separate transition code anywhere.
	var at: PackedFloat32Array = PackedFloat32Array()
	var av1: PackedFloat32Array = PackedFloat32Array()
	var av2: PackedFloat32Array = PackedFloat32Array()
	var av3: PackedFloat32Array = PackedFloat32Array()
	var ab1: PackedFloat32Array = PackedFloat32Array()
	var ab2: PackedFloat32Array = PackedFloat32Array()
	var ab3: PackedFloat32Array = PackedFloat32Array()

	var push := func(tt: float, f1: float, f2: float, f3: float,
			b1: float, b2: float, b3: float) -> void:
		at.append(tt)
		av1.append(f1)
		av2.append(f2)
		av3.append(f3)
		ab1.append(b1)
		ab2.append(b2)
		ab3.append(b3)

	# Start and end from rest, so the very first formant movement is a movement
	# and not a step.
	push.call(0.0, VoicePhonemes.NEUTRAL[0], VoicePhonemes.NEUTRAL[1],
			VoicePhonemes.NEUTRAL[2], 130.0, 160.0, 220.0)

	for i: int in segs.size():
		var s: Dictionary = segs[i]
		var r: Array = s["row"] as Array
		var ty: int = int(r[VoicePhonemes.C_TYPE])
		var t0: float = float(s["t0"])
		var t1: float = float(s["t1"])
		var d: float = t1 - t0
		var f1: float = float(r[VoicePhonemes.C_F1])
		var f2: float = float(r[VoicePhonemes.C_F2])
		var f3: float = float(r[VoicePhonemes.C_F3])
		var b1: float = float(r[VoicePhonemes.C_B1])
		var b2: float = float(r[VoicePhonemes.C_B2])
		var b3: float = float(r[VoicePhonemes.C_B3])
		# `clarity` pulls every formant AWAY from neutral. At 1.0 the table is
		# taken literally; above 1.0 the vowel space is expanded, which is
		# hyper-articulation — the thing people do when they need to be
		# understood across a room, and the cheapest intelligibility knob here.
		if ty == VoicePhonemes.T_VOWEL and not is_equal_approx(clarity, 1.0):
			f1 = VoicePhonemes.NEUTRAL[0] + (f1 - VoicePhonemes.NEUTRAL[0]) * clarity
			f2 = VoicePhonemes.NEUTRAL[1] + (f2 - VoicePhonemes.NEUTRAL[1]) * clarity
			f3 = VoicePhonemes.NEUTRAL[2] + (f3 - VoicePhonemes.NEUTRAL[2]) * clarity

		match ty:
			VoicePhonemes.T_VOWEL:
				var g1: float = float(r[VoicePhonemes.C_F1B])
				if g1 < 0.0:
					push.call(t0 + d * 0.32, f1, f2, f3, b1, b2, b3)
					push.call(t0 + d * 0.78, f1, f2, f3, b1, b2, b3)
				else:
					var g2: float = float(r[VoicePhonemes.C_F2B])
					var g3: float = float(r[VoicePhonemes.C_F3B])
					if not is_equal_approx(clarity, 1.0):
						g1 = VoicePhonemes.NEUTRAL[0] + (g1 - VoicePhonemes.NEUTRAL[0]) * clarity
						g2 = VoicePhonemes.NEUTRAL[1] + (g2 - VoicePhonemes.NEUTRAL[1]) * clarity
						g3 = VoicePhonemes.NEUTRAL[2] + (g3 - VoicePhonemes.NEUTRAL[2]) * clarity
					push.call(t0 + d * 0.22, f1, f2, f3, b1, b2, b3)
					push.call(t0 + d * 0.88, g1, g2, g3, b1, b2, b3)
			VoicePhonemes.T_STOP, VoicePhonemes.T_AFFRIC:
				# The anchor sits at the RELEASE, not the middle of the closure.
				# During the closure there is nothing to hear; the whole place cue
				# is the sweep out of the burst into whatever follows.
				push.call(t1 - 0.004, f1, f2, f3, b1, b2, b3)
			VoicePhonemes.T_ASPIRATE:
				# /h/ has no place of its own — it is the following vowel, voiceless.
				# Anchoring it to itself would put a schwa in front of every H.
				pass
			VoicePhonemes.T_GLITCH:
				push.call(t0 + d * 0.5, f1, f2, f3, b1, b2, b3)
			_:
				push.call(t0 + d * 0.30, f1, f2, f3, b1, b2, b3)
				push.call(t0 + d * 0.72, f1, f2, f3, b1, b2, b3)

	push.call(total, VoicePhonemes.NEUTRAL[0], VoicePhonemes.NEUTRAL[1],
			VoicePhonemes.NEUTRAL[2], 130.0, 160.0, 220.0)

	# --- interpolate the anchors onto the frame grid -------------------------
	var k: int = 0
	for fi: int in n:
		var tt: float = float(fi) / FRAME_HZ
		while k + 2 < at.size() and at[k + 1] < tt:
			k += 1
		var ta: float = at[k]
		var tb: float = at[k + 1] if k + 1 < at.size() else at[k] + 1.0
		var u: float = 0.0 if tb <= ta else clampf((tt - ta) / (tb - ta), 0.0, 1.0)
		# Raised cosine, not linear. The articulators have mass, and a linear
		# formant ramp has a corner at each end that the ear hears as a click in
		# the spectrum.
		u = 0.5 - 0.5 * cos(PI * u)
		var o: int = fi * P_COUNT
		tr.frames[o + P_F1] = lerpf(av1[k], av1[mini(k + 1, av1.size() - 1)], u)
		tr.frames[o + P_F2] = lerpf(av2[k], av2[mini(k + 1, av2.size() - 1)], u)
		tr.frames[o + P_F3] = lerpf(av3[k], av3[mini(k + 1, av3.size() - 1)], u)
		tr.frames[o + P_B1] = lerpf(ab1[k], ab1[mini(k + 1, ab1.size() - 1)], u)
		tr.frames[o + P_B2] = lerpf(ab2[k], ab2[mini(k + 1, ab2.size() - 1)], u)
		tr.frames[o + P_B3] = lerpf(ab3[k], ab3[mini(k + 1, ab3.size() - 1)], u)

	# --- sources, per segment ------------------------------------------------
	for i: int in segs.size():
		var s: Dictionary = segs[i]
		var r: Array = s["row"] as Array
		var ty: int = int(r[VoicePhonemes.C_TYPE])
		var f_lo: int = int(floor(float(s["t0"]) * FRAME_HZ))
		var f_hi: int = int(ceil(float(s["t1"]) * FRAME_HZ))
		var amp: float = float(r[VoicePhonemes.C_AMP]) * float(s["amp"])
		match ty:
			VoicePhonemes.T_VOWEL, VoicePhonemes.T_APPROX:
				_ramp(tr, f_lo, f_hi, P_AV, amp * (1.0 - whisper), 2, 3)
				_ramp(tr, f_lo, f_hi, P_AH, breathiness + whisper * 0.9, 1, 1)
				if float(r[VoicePhonemes.C_FRIC_A]) > 0.0:
					_fric(tr, f_lo, f_hi, r, 1.0)
			VoicePhonemes.T_NASAL:
				_ramp(tr, f_lo, f_hi, P_AV, amp * (1.0 - whisper), 2, 2)
				_ramp(tr, f_lo, f_hi, P_AH, breathiness * 0.5, 1, 1)
				# Nasalisation leaks ~30 ms into the neighbours; that leak is a
				# cue in its own right and its absence is why cheap synths make
				# every nasal sound like a hum spliced in.
				_ramp(tr, f_lo - 6, f_hi + 6, P_NAMT, 1.0, 6, 6)
				_hold(tr, f_lo - 6, f_hi + 6, P_NZ, float(r[VoicePhonemes.C_NZERO]))
			VoicePhonemes.T_FRIC:
				_ramp(tr, f_lo, f_hi, P_AF, 1.0, 2, 2)
				_fric(tr, f_lo, f_hi, r, 1.0)
				if float(r[VoicePhonemes.C_VOICED]) > 0.5:
					_ramp(tr, f_lo, f_hi, P_AV, amp, 2, 2)
			VoicePhonemes.T_ASPIRATE:
				_ramp(tr, f_lo, f_hi, P_AH, 0.85, 2, 3)
				_fric(tr, f_lo, f_hi, r, 0.5)
			VoicePhonemes.T_STOP, VoicePhonemes.T_AFFRIC:
				# Closure. A voiced stop keeps a low-frequency voice bar running
				# through it; a voiceless one is a genuine hole, and the hole is
				# the articulation.
				if float(r[VoicePhonemes.C_VOICED]) > 0.5:
					_hold(tr, f_lo, f_hi, P_AV, 0.10 * amp if amp > 0.0 else 0.10)
				# Release burst: short, loud, and the two frication resonators
				# carry the place cue that the F2 sweep then confirms.
				var burst_f: int = f_hi
				var burst_len: int = 2 if ty == VoicePhonemes.T_STOP else 14
				_ramp(tr, burst_f, burst_f + burst_len, P_AF, 1.0, 0, 1)
				_fric(tr, burst_f, burst_f + burst_len + 2, r, 1.0)
				# Voice-onset time: aspiration between the burst and the voicing.
				var vot: int = int(float(r[VoicePhonemes.C_VOT]) / FRAME_MS)
				if vot > 0:
					_ramp(tr, burst_f + burst_len, burst_f + burst_len + vot,
							P_AH, 0.55, 1, 3)
			VoicePhonemes.T_GLITCH:
				_ramp(tr, f_lo, f_hi, P_AF, 1.0, 1, 1)
				_fric(tr, f_lo, f_hi, r, 1.0)

	# --- corruption damage ---------------------------------------------------
	# LAST, and after every source has been painted, because it is a GATE: it
	# subtracts sound that is already there. Running it earlier would let the
	# `_ramp` max() blend paint straight back over the hole.
	for s: Dictionary in segs:
		var dmg: int = int(s.get("damage", 0))
		if dmg > 0:
			_damage(tr, float(s["t0"]), float(s["t1"]), dmg)

	# --- F0 ------------------------------------------------------------------
	var span: float = maxf(total - lead_in - tail, 1e-4)
	var last: Dictionary = segs[segs.size() - 1]
	for fi: int in n:
		var tt: float = float(fi) / FRAME_HZ
		var prog: float = clampf((tt - lead_in) / span, 0.0, 1.0)
		var semis: float = declination * 12.0 * prog
		tr.frames[fi * P_COUNT + P_F0] = f0_base * pow(2.0, semis / 12.0)
	for s: Dictionary in segs:
		if float(s["stress"]) <= 0.0 or not bool(s.get("nucleus", false)):
			continue
		var peak: float = accent * (1.0 if float(s["stress"]) >= 1.0 else 0.55)
		var lo: float = float(s["t0"]) - 0.05
		var hi: float = float(s["t1"]) + 0.03
		var i0: int = maxi(int(lo * FRAME_HZ), 0)
		var i1: int = mini(int(hi * FRAME_HZ), n - 1)
		for fi: int in range(i0, i1 + 1):
			var u: float = float(fi - i0) / maxf(float(i1 - i0), 1.0)
			var add: float = peak * pow(sin(PI * u), 1.4)
			var o: int = fi * P_COUNT + P_F0
			tr.frames[o] = tr.frames[o] * pow(2.0, add / 12.0)
	# Terminal fall. She states; she never asks.
	var lt: float = float(last["t0"])
	var ld: float = maxf(float(last["t1"]) - lt, 1e-4)
	var li: int = maxi(int(lt * FRAME_HZ), 0)
	for fi: int in range(li, n):
		var u: float = clampf((float(fi) / FRAME_HZ - lt) / ld, 0.0, 1.0)
		var o: int = fi * P_COUNT + P_F0
		tr.frames[o] = tr.frames[o] * pow(2.0, terminal * pow(u, 1.6) / 12.0)

	_smooth(tr, P_AV, 2)
	_smooth(tr, P_AH, 2)
	_smooth(tr, P_AF, 1)
	_smooth(tr, P_NAMT, 2)
	return tr


# ==========================================================================
# SEGMENTS
# ==========================================================================

## Text -> a flat list of segments with durations, stress and trailing gaps.
##
## Returns dictionaries: {row, name, dur, gap, stress, amp, nucleus}
static func _segments(text: String, rate: float, final_lengthen: float,
		word_gap: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var words: Array[Dictionary] = VoiceG2P.split_words(text)
	# Where the last real segment is, so the phrase-final lengthening lands on
	# the right one even when the line ends in punctuation.
	var pending_pause: float = 0.0
	for wi: int in words.size():
		var w: Dictionary = words[wi]
		if String(w["kind"]) == "pause":
			pending_pause = maxf(pending_pause, float(w["seconds"]))
			continue
		var phones: PackedStringArray = PackedStringArray(w["phones"])
		var stresses: PackedFloat32Array = _stress_pattern(phones, bool(w["func_word"]))
		var nucleus_seen: int = 0
		# A corruption glyph carries no time of its own. It attaches to the sound
		# BESIDE it as damage — the preceding one if there is one, otherwise the
		# next — so a decayed line is shorter than its clean original rather than
		# longer. See `_damage` for what that then sounds like.
		var pending_damage: int = 0
		for pi: int in phones.size():
			var name: String = phones[pi]
			if name == VoiceG2P.GLITCH:
				if out.is_empty():
					pending_damage += 1
				else:
					out[out.size() - 1]["damage"] = \
							int(out[out.size() - 1].get("damage", 0)) + 1
				continue
			var r: Array = VoicePhonemes.row(name)
			var stress: float = 0.0
			var nucleus: bool = VoicePhonemes.is_vowel(name)
			if nucleus:
				stress = stresses[mini(nucleus_seen, stresses.size() - 1)] \
						if stresses.size() > 0 else 0.0
				nucleus_seen += 1
			var dur: float = float(r[VoicePhonemes.C_DUR]) / 1000.0
			if nucleus:
				dur *= 1.24 if stress >= 1.0 else (1.06 if stress > 0.0 else 0.84)
			dur /= maxf(rate, 0.05)
			out.append({
				"row": r, "name": name, "dur": dur, "gap": 0.0,
				"stress": stress, "amp": 1.0 if stress > 0.0 or not nucleus else 0.86,
				"nucleus": nucleus, "damage": pending_damage,
			})
			pending_damage = 0
		if not out.is_empty():
			out[out.size() - 1]["gap"] = maxf(pending_pause, word_gap)
			if pending_pause > 0.0:
				# A phrase boundary lengthens the syllable in front of it. This is
				# the single strongest "that was a sentence and it just ended" cue
				# there is, and it costs one multiply.
				out[out.size() - 1]["dur"] = float(out[out.size() - 1]["dur"]) * final_lengthen
			pending_pause = 0.0
	if not out.is_empty():
		var lastd: Dictionary = out[out.size() - 1]
		lastd["gap"] = 0.0
		if float(lastd["dur"]) < 0.001:
			lastd["dur"] = 0.06
	return out


## Which syllables of a word carry an accent.
##
## Primary on the first syllable, secondary two later — crude, and right often
## enough that the line reads as English rather than as a metronome. English
## stress is genuinely unpredictable from spelling and the alternative is a
## pronunciation dictionary we would then have to maintain forever. A wrong
## accent on an unfamiliar callsign is, per the brief, a feature.
static func _stress_pattern(phones: PackedStringArray, func_word: bool) -> PackedFloat32Array:
	var n: int = 0
	for p: String in phones:
		if VoicePhonemes.is_vowel(p):
			n += 1
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(maxi(n, 1))
	for i: int in out.size():
		out[i] = 0.0
	if func_word or n == 0:
		return out
	out[0] = 1.0
	var k: int = 2
	while k < n:
		out[k] = 0.5
		k += 2
	return out


# ==========================================================================
# FRAME PAINTING
# ==========================================================================

## Write `value` into `param` across [lo, hi) with attack/release ramps measured
## in FRAMES. Uses max(), so overlapping segments never cut each other's tails.
static func _ramp(tr: Track, lo: int, hi: int, param: int, value: float,
		attack: int, release: int) -> void:
	lo = maxi(lo, 0)
	hi = mini(hi, tr.n)
	if hi <= lo or value <= 0.0:
		return
	var span: int = hi - lo
	for i: int in range(lo, hi):
		var k: int = i - lo
		var a: float = 1.0 if attack <= 0 else minf(float(k + 1) / float(attack), 1.0)
		var rl: float = 1.0 if release <= 0 else minf(float(span - k) / float(release), 1.0)
		var v: float = value * minf(a, rl)
		var o: int = i * P_COUNT + param
		if v > tr.frames[o]:
			tr.frames[o] = v


static func _hold(tr: Track, lo: int, hi: int, param: int, value: float) -> void:
	lo = maxi(lo, 0)
	hi = mini(hi, tr.n)
	for i: int in range(lo, hi):
		tr.frames[i * P_COUNT + param] = value


## Paint the two frication resonators for a segment.
static func _fric(tr: Track, lo: int, hi: int, r: Array, scale: float) -> void:
	lo = maxi(lo, 0)
	hi = mini(hi, tr.n)
	for i: int in range(lo, hi):
		var o: int = i * P_COUNT
		tr.frames[o + P_FF1] = float(r[VoicePhonemes.C_FRIC_F])
		tr.frames[o + P_FB1] = float(r[VoicePhonemes.C_FRIC_BW])
		tr.frames[o + P_FA1] = float(r[VoicePhonemes.C_FRIC_A]) * scale
		tr.frames[o + P_FF2] = float(r[VoicePhonemes.C_FRC2_F])
		tr.frames[o + P_FB2] = float(r[VoicePhonemes.C_FRC2_BW])
		tr.frames[o + P_FA2] = float(r[VoicePhonemes.C_FRC2_A]) * scale


## Punch a dropout through a sound whose letter the corruption ate.
##
## THIS IS THE TAPE CHAIN'S DROPOUT STAGE, AIMED. That stage is disabled outright
## on directed speech because an HF dropout is a hole in exactly the consonants
## that carry identity — but here a hole is the whole point, and this is the one
## place where losing the consonant is the intended effect rather than the
## failure. So the mechanism finally does what it was built for, at a position
## chosen by the corpus rather than by a random number.
##
## Costs NO TIME: the hole is punched INSIDE the neighbouring segment's existing
## span, and the click sits inside the hole. A corrupted line is therefore always
## shorter than its clean original, which is what "words go missing" means when
## you have to measure it.
static func _damage(tr: Track, t0: float, t1: float, count: int) -> void:
	var f0i: int = maxi(int(t0 * FRAME_HZ), 0)
	var f1i: int = mini(int(t1 * FRAME_HZ), tr.n)
	var span: int = maxi(f1i - f0i, 2)
	# The hole grows a little with how many letters were eaten at this spot, and
	# is capped: a run of glyphs must not be able to gate a whole word to silence,
	# because silence is not damage, it is absence.
	var hole: int = clampi(int(float(span) * 0.42) + count, 2, 11)
	var start: int = clampi(f0i + (span - hole) / 2, 0, maxi(tr.n - 1, 0))
	var stop: int = mini(start + hole, tr.n)
	for i: int in range(start, stop):
		var o: int = i * P_COUNT
		tr.frames[o + P_AV] = 0.0
		tr.frames[o + P_AH] = 0.0
		tr.frames[o + P_AF] = 0.0
	# The head of the hole gets a click — the transport stumbling where the
	# letter used to be. Without it a dropout is just a gap, and a gap reads as a
	# pause rather than as damage.
	var click: Array = VoicePhonemes.row(VoiceG2P.GLITCH)
	for i: int in range(start, mini(start + 2, tr.n)):
		var o: int = i * P_COUNT
		tr.frames[o + P_AF] = 0.55
		tr.frames[o + P_FF1] = float(click[VoicePhonemes.C_FRIC_F])
		tr.frames[o + P_FB1] = float(click[VoicePhonemes.C_FRIC_BW])
		tr.frames[o + P_FA1] = float(click[VoicePhonemes.C_FRIC_A])
		tr.frames[o + P_FF2] = float(click[VoicePhonemes.C_FRC2_F])
		tr.frames[o + P_FB2] = float(click[VoicePhonemes.C_FRC2_BW])
		tr.frames[o + P_FA2] = float(click[VoicePhonemes.C_FRC2_A])


## A tiny box blur over one parameter track. Removes the frame-grid staircase
## that a 200 Hz control rate leaves on an amplitude envelope, which is audible
## as a 200 Hz buzz riding on every consonant if you skip it.
static func _smooth(tr: Track, param: int, radius: int) -> void:
	if radius <= 0 or tr.n < 3:
		return
	var tmp: PackedFloat32Array = PackedFloat32Array()
	tmp.resize(tr.n)
	for i: int in tr.n:
		var acc: float = 0.0
		var cnt: int = 0
		for k: int in range(maxi(i - radius, 0), mini(i + radius + 1, tr.n)):
			acc += tr.frames[k * P_COUNT + param]
			cnt += 1
		tmp[i] = acc / float(maxi(cnt, 1))
	for i: int in tr.n:
		tr.frames[i * P_COUNT + param] = tmp[i]
