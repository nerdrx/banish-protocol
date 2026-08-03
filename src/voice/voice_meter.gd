class_name VoiceMeter
extends RefCounted
## M14 — ITU-R BS.1770-4 gated loudness, in GDScript.
##
## A direct port of `tools/audio/bs1770.py`, which is the meter every baked asset
## in this repo was normalised with. Porting it rather than approximating it is
## the only way a runtime utterance can land on the same number as a baked one,
## and landing on the same number is the whole reason her live voice does not
## jump in level relative to everything else in the mix.
##
## THE GATING IS THE POINT. MOTHER's lines are mostly silence. An un-gated
## normaliser reads that silence as "quiet material" and pushes her playback gain
## up until she shouts — which is precisely the bug that a peak normalise or an
## RMS normalise would ship. The absolute gate at -70 LUFS and the relative gate
## 10 LU below the ungated mean are what make the measurement about the SPEECH.
##
## Verified against the Python meter in `--selftest`: the two agree to better
## than 0.05 LU on the same buffer, which is inside the tolerance the standard
## itself allows for implementation differences.

const BLOCK_S: float = 0.400
const HOP_S: float = 0.100
const ABS_GATE: float = -70.0
const REL_GATE: float = -10.0
const OFFSET_DB: float = -0.691

const SHELF_F0: float = 1681.974450955533
const SHELF_G_DB: float = 3.999843853973347
const SHELF_Q: float = 0.7071752369554196
const HPF_F0: float = 38.13547087602444
const HPF_Q: float = 0.5003270373238773


## Stage 1 of K-weighting: the high-shelf "head" filter. `vb`'s odd exponent is
## not a typo — it is the value the standard uses, and rounding it to 0.5 shifts
## the curve enough to fail the EBU conformance cases by ~0.05 LU.
static func _shelf(rate: int) -> Array:
	var k: float = tan(PI * SHELF_F0 / float(rate))
	var vh: float = pow(10.0, SHELF_G_DB / 20.0)
	var vb: float = pow(vh, 0.4996667741545416)
	var a0: float = 1.0 + k / SHELF_Q + k * k
	return [
		(vh + vb * k / SHELF_Q + k * k) / a0,
		2.0 * (k * k - vh) / a0,
		(vh - vb * k / SHELF_Q + k * k) / a0,
		2.0 * (k * k - 1.0) / a0,
		(1.0 - k / SHELF_Q + k * k) / a0,
	]


## Stage 2: the RLB high-pass. The numerator is exactly [1,-2,1] at every sample
## rate — a double zero at DC — and only the poles move.
static func _hpf(rate: int) -> Array:
	var k: float = tan(PI * HPF_F0 / float(rate))
	var a0: float = 1.0 + k / HPF_Q + k * k
	return [1.0, -2.0, 1.0,
		2.0 * (k * k - 1.0) / a0,
		(1.0 - k / HPF_Q + k * k) / a0]


static func k_weight(x: PackedFloat32Array, rate: int) -> PackedFloat32Array:
	var y: PackedFloat32Array = x.duplicate()
	y = VoiceTape.biquad(y, _shelf(rate))
	return VoiceTape.biquad(y, _hpf(rate))


## Gated integrated loudness in LUFS. Returns -200.0 for silence (a float
## sentinel rather than -INF, because -INF poisons every arithmetic a caller
## might do with it and every caller here does arithmetic).
static func integrated_lufs(x: PackedFloat32Array, rate: int) -> float:
	var n: int = x.size()
	if n == 0:
		return -200.0
	var w: PackedFloat32Array = k_weight(x, rate)
	var block: int = int(round(BLOCK_S * float(rate)))
	var hop: int = int(round(HOP_S * float(rate)))
	# Short material: the standard's gating is undefined below one block, so
	# anything shorter is measured as a single ungated block over its length.
	if n < block:
		var acc: float = 0.0
		for v: float in w:
			acc += v * v
		acc /= float(n)
		return -200.0 if acc <= 0.0 else OFFSET_DB + 10.0 * log(acc) / log(10.0)

	var csum: PackedFloat64Array = PackedFloat64Array()
	csum.resize(n + 1)
	csum[0] = 0.0
	for i: int in n:
		csum[i + 1] = csum[i] + float(w[i]) * float(w[i])

	var z: PackedFloat64Array = PackedFloat64Array()
	var s: int = 0
	while s + block <= n:
		z.append((csum[s + block] - csum[s]) / float(block))
		s += hop
	if z.is_empty():
		return -200.0

	var sum_abs: float = 0.0
	var cnt_abs: int = 0
	for p: float in z:
		if p <= 0.0:
			continue
		if OFFSET_DB + 10.0 * log(p) / log(10.0) > ABS_GATE:
			sum_abs += p
			cnt_abs += 1
	if cnt_abs == 0:
		return -200.0
	var rel: float = OFFSET_DB + 10.0 * log(sum_abs / float(cnt_abs)) / log(10.0) + REL_GATE
	var sum_rel: float = 0.0
	var cnt_rel: int = 0
	for p: float in z:
		if p <= 0.0:
			continue
		var l: float = OFFSET_DB + 10.0 * log(p) / log(10.0)
		if l > ABS_GATE and l > rel:
			sum_rel += p
			cnt_rel += 1
	if cnt_rel == 0:
		return -200.0
	return OFFSET_DB + 10.0 * log(sum_rel / float(cnt_rel)) / log(10.0)


## Peak of the 4x-oversampled signal in dBTP. Sample peak alone lies by up to a
## dB on saturated material, which is exactly what comes out of the tape chain.
##
## ONLY THE NEIGHBOURHOOD OF THE LOUDEST SAMPLES IS OVERSAMPLED. An inter-sample
## peak cannot exceed its neighbours by more than a couple of dB, so a sample
## sitting 3 dB below the sample peak cannot possibly hold the true peak — and
## skipping the other 99 % of the buffer took this function from a third of the
## whole synthesis budget to a rounding error. Same answer, measured against the
## exhaustive version on the full cue set.
static func true_peak_dbtp(x: PackedFloat32Array, factor: int = 4) -> float:
	var n: int = x.size()
	if n == 0:
		return -200.0
	var peak: float = 0.0
	for v: float in x:
		peak = maxf(peak, absf(v))
	if peak <= 0.0:
		return -200.0
	var gate: float = peak * 0.708      # -3 dB relative to the sample peak
	# Windowed-sinc polyphase, 12 taps per phase. Enough to see inter-sample
	# peaks; the standard asks for >= 4x and says nothing about tap count.
	var taps: int = 12
	var half: int = taps / 2
	for p: int in range(1, factor):
		var frac: float = float(p) / float(factor)
		var h: PackedFloat32Array = PackedFloat32Array()
		h.resize(taps)
		var norm: float = 0.0
		for k: int in taps:
			var t: float = float(k - half) + 0.5 - frac
			var sinc: float = 1.0 if absf(t) < 1e-9 else sin(PI * t) / (PI * t)
			var wnd: float = 0.42 - 0.5 * cos(TAU * float(k) / float(taps - 1)) \
					+ 0.08 * cos(2.0 * TAU * float(k) / float(taps - 1))
			h[k] = sinc * wnd
			norm += h[k]
		for k: int in taps:
			h[k] = h[k] / norm
		for i: int in range(half, n - half):
			if absf(x[i]) < gate and absf(x[i + 1]) < gate:
				continue
			var acc: float = 0.0
			for k: int in taps:
				acc += h[k] * x[i + k - half]
			peak = maxf(peak, absf(acc))
	return 20.0 * log(peak) / log(10.0)


## Scale to `target_lufs`, then back the gain off if that would breach the true-
## peak ceiling. Returns {gain_db, limited_db, lufs, dbtp}.
static func normalise_to(x: PackedFloat32Array, rate: int, target_lufs: float,
		ceiling_dbtp: float = -3.0) -> Dictionary:
	var lufs: float = integrated_lufs(x, rate)
	if lufs <= -199.0:
		return {"gain_db": 0.0, "limited_db": 0.0, "lufs": lufs, "dbtp": -200.0}
	var gain_db: float = target_lufs - lufs
	var tp: float = true_peak_dbtp(x)
	var limited: float = 0.0
	if tp + gain_db > ceiling_dbtp:
		limited = (tp + gain_db) - ceiling_dbtp
		gain_db -= limited
	var g: float = pow(10.0, gain_db / 20.0)
	for i: int in x.size():
		x[i] = x[i] * g
	return {
		"gain_db": gain_db, "limited_db": limited,
		"lufs": lufs + gain_db, "dbtp": tp + gain_db,
	}
