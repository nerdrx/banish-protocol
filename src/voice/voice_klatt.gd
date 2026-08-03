class_name VoiceKlatt
extends RefCounted
## M14 — the synthesiser. Klatt parameter frames in, samples out.
##
## CASCADE for voiced sound, PARALLEL for frication. That split is not a style
## choice and it is the reason this rewrite is intelligible where the baked
## engine was not: a cascade of resonators reproduces the relative amplitudes of
## the formants automatically, because a real vocal tract IS a cascade, whereas a
## parallel bank needs a correct amplitude per formant per frame and gets vowel
## identity wrong the moment one of them is off. Frication is genuinely parallel
## — the noise is generated at a constriction with only the cavity in FRONT of it
## resonating — so it gets its own bank, and that is why /s/ can be louder than
## the vowel beside it without the vowel's formants coming along.
##
## Everything is per-sample and time-domain. The Python bench did all of this as
## an STFT spectral gain because sweeping four resonators per sample is
## intractable in numpy; in GDScript a per-sample loop is the natural shape, and
## it is fast — measured 12 ms for four resonators over two seconds of 48 kHz
## audio, so the whole chain lands around 250 ms for a three-second line. On a
## worker thread that is free.
##
## The synthesis is DETERMINISTIC given (frames, seed). The noise generator is a
## seeded xorshift, not the engine RNG — partly so the cache can promise
## byte-identical audio for identical input, and partly because MOTHER's voice
## must never be able to consume from `Rng` and move a run.

const N_PARAM: int = VoiceFrames.P_COUNT

## Radiation at the lips is a differentiator. Applied to the SOURCE rather than
## the output, so the frication — which radiates from a constriction much closer
## to the lips — does not get a tilt it has not earned.
const SOURCE_TILT_HZ: float = 3000.0

## How often the resonator coefficients are recomputed, in samples. 64 at 48 kHz
## is 750 Hz, far above any rate a formant actually moves at and far below the
## cost of doing the trig every sample.
const COEF_EVERY: int = 64


## Render one track. `opts` is the register block; `seed` makes the noise
## reproducible so the same utterance is the same bytes every time.
static func render(tr: VoiceFrames.Track, rate: int, opts: Dictionary,
		seed: int) -> PackedFloat32Array:
	var n: int = int(tr.seconds * float(rate))
	var out: PackedFloat32Array = PackedFloat32Array()
	if n <= 0 or tr.n <= 0:
		return out
	out.resize(n)

	var creak: float = float(opts.get("creak", 0.14))
	var jitter: float = float(opts.get("jitter", 0.0018))
	var open_q: float = float(opts.get("open_quotient", 0.42))
	var fric_gain: float = float(opts.get("fric_gain", 1.0))
	var asp_gain: float = float(opts.get("asp_gain", 1.0))

	# --- noise ---------------------------------------------------------------
	var rs: int = seed if seed != 0 else 0x2545F491
	# Two independent streams: aspiration is a property of the glottis and
	# frication of a constriction 15 cm away, and correlating them makes every
	# /s/ sound like it is coming out of the same hole as the vowel.
	var rs2: int = rs ^ 0x9E3779B9

	# --- cascade state -------------------------------------------------------
	# Nasal zero (two zeros), nasal pole, then R1..R5.
	var zx1: float = 0.0
	var zx2: float = 0.0
	var np1: float = 0.0
	var np2: float = 0.0
	var y11: float = 0.0
	var y12: float = 0.0
	var y21: float = 0.0
	var y22: float = 0.0
	var y31: float = 0.0
	var y32: float = 0.0
	var y41: float = 0.0
	var y42: float = 0.0
	var y51: float = 0.0
	var y52: float = 0.0
	# Parallel frication.
	var g11: float = 0.0
	var g12: float = 0.0
	var g21: float = 0.0
	var g22: float = 0.0

	# --- coefficients, refreshed every COEF_EVERY samples --------------------
	var za: float = 1.0
	var zb: float = 0.0
	var zc: float = 0.0
	var pa: float = 1.0
	var pb: float = 0.0
	var pc: float = 0.0
	var a1: float = 1.0
	var b1c: float = 0.0
	var c1: float = 0.0
	var a2: float = 1.0
	var b2c: float = 0.0
	var c2: float = 0.0
	var a3: float = 1.0
	var b3c: float = 0.0
	var c3: float = 0.0
	var a4: float = 1.0
	var b4c: float = 0.0
	var c4: float = 0.0
	var a5: float = 1.0
	var b5c: float = 0.0
	var c5: float = 0.0
	var fa1: float = 0.0
	var fb1: float = 0.0
	var fc1: float = 0.0
	var fa2: float = 0.0
	var fb2: float = 0.0
	var fc2: float = 0.0

	var sr: float = float(rate)
	var frames: PackedFloat32Array = tr.frames
	var nf: int = tr.n
	var frame_step: float = VoiceFrames.FRAME_HZ / sr

	var phase: float = 0.0
	var period_i: int = 0
	var src_lp: float = 0.0
	var src_prev: float = 0.0
	var tilt_k: float = 1.0 - exp(-TAU * SOURCE_TILT_HZ / sr)

	for i: int in n:
		# --- frame interpolation --------------------------------------------
		var fpos: float = float(i) * frame_step
		var fi: int = int(fpos)
		if fi >= nf - 1:
			fi = nf - 2
		if fi < 0:
			fi = 0
		var fu: float = clampf(fpos - float(fi), 0.0, 1.0)
		var o0: int = fi * N_PARAM
		var o1: int = o0 + N_PARAM

		if i % COEF_EVERY == 0:
			var f1: float = lerpf(frames[o0 + VoiceFrames.P_F1], frames[o1 + VoiceFrames.P_F1], fu)
			var bw1: float = lerpf(frames[o0 + VoiceFrames.P_B1], frames[o1 + VoiceFrames.P_B1], fu)
			var f2: float = lerpf(frames[o0 + VoiceFrames.P_F2], frames[o1 + VoiceFrames.P_F2], fu)
			var bw2: float = lerpf(frames[o0 + VoiceFrames.P_B2], frames[o1 + VoiceFrames.P_B2], fu)
			var f3: float = lerpf(frames[o0 + VoiceFrames.P_F3], frames[o1 + VoiceFrames.P_F3], fu)
			var bw3: float = lerpf(frames[o0 + VoiceFrames.P_B3], frames[o1 + VoiceFrames.P_B3], fu)
			var namt: float = lerpf(frames[o0 + VoiceFrames.P_NAMT], frames[o1 + VoiceFrames.P_NAMT], fu)
			var nz: float = frames[o0 + VoiceFrames.P_NZ]
			if nz <= 0.0:
				nz = VoicePhonemes.FNP
			# The pole/zero cancellation trick: with the zero sitting exactly on
			# the pole the nasal branch is mathematically absent, so ONE cascade
			# covers both nasal and oral sounds and there is no crossfade to
			# click. Sliding the zero away from the pole opens the nose.
			var fz: float = lerpf(VoicePhonemes.FNP, nz, clampf(namt, 0.0, 1.0))

			var co: Array = _reson(fz, VoicePhonemes.BNP, sr)
			# Antiresonator: the reciprocal of the resonator, applied to the input
			# history rather than the output history.
			za = 1.0 / maxf(float(co[0]), 1e-9)
			zb = -float(co[1]) * za
			zc = -float(co[2]) * za
			co = _reson(VoicePhonemes.FNP, VoicePhonemes.BNP, sr)
			pa = float(co[0]); pb = float(co[1]); pc = float(co[2])
			co = _reson(f1, bw1, sr)
			a1 = float(co[0]); b1c = float(co[1]); c1 = float(co[2])
			co = _reson(f2, bw2, sr)
			a2 = float(co[0]); b2c = float(co[1]); c2 = float(co[2])
			co = _reson(f3, bw3, sr)
			a3 = float(co[0]); b3c = float(co[1]); c3 = float(co[2])
			co = _reson(VoicePhonemes.F4, VoicePhonemes.B4, sr)
			a4 = float(co[0]); b4c = float(co[1]); c4 = float(co[2])
			co = _reson(VoicePhonemes.F5, VoicePhonemes.B5, sr)
			a5 = float(co[0]); b5c = float(co[1]); c5 = float(co[2])

			var ff1: float = lerpf(frames[o0 + VoiceFrames.P_FF1], frames[o1 + VoiceFrames.P_FF1], fu)
			var fbw1: float = lerpf(frames[o0 + VoiceFrames.P_FB1], frames[o1 + VoiceFrames.P_FB1], fu)
			if ff1 > 20.0:
				co = _bandpass(ff1, fbw1, sr)
				fa1 = float(co[0]); fb1 = float(co[1]); fc1 = float(co[2])
			var ff2: float = lerpf(frames[o0 + VoiceFrames.P_FF2], frames[o1 + VoiceFrames.P_FF2], fu)
			var fbw2: float = lerpf(frames[o0 + VoiceFrames.P_FB2], frames[o1 + VoiceFrames.P_FB2], fu)
			if ff2 > 20.0:
				co = _bandpass(ff2, fbw2, sr)
				fa2 = float(co[0]); fb2 = float(co[1]); fc2 = float(co[2])

		var av: float = lerpf(frames[o0 + VoiceFrames.P_AV], frames[o1 + VoiceFrames.P_AV], fu)
		var ah: float = lerpf(frames[o0 + VoiceFrames.P_AH], frames[o1 + VoiceFrames.P_AH], fu)
		var af: float = lerpf(frames[o0 + VoiceFrames.P_AF], frames[o1 + VoiceFrames.P_AF], fu)
		var f0: float = lerpf(frames[o0 + VoiceFrames.P_F0], frames[o1 + VoiceFrames.P_F0], fu)
		var amp1: float = lerpf(frames[o0 + VoiceFrames.P_FA1], frames[o1 + VoiceFrames.P_FA1], fu)
		var amp2: float = lerpf(frames[o0 + VoiceFrames.P_FA2], frames[o1 + VoiceFrames.P_FA2], fu)

		# --- noise ----------------------------------------------------------
		rs ^= rs << 13
		rs ^= rs >> 7
		rs ^= rs << 17
		var asp: float = float(rs % 65536) * 3.0517578125e-05 - 1.0
		rs2 ^= rs2 << 13
		rs2 ^= rs2 >> 7
		rs2 ^= rs2 << 17
		var frn: float = float(rs2 % 65536) * 3.0517578125e-05 - 1.0

		# --- glottis ---------------------------------------------------------
		var src: float = 0.0
		if av > 0.0001:
			var step: float = f0 * (1.0 + jitter * asp) / sr
			phase += step
			if phase >= 1.0:
				phase -= floor(phase)
				period_i += 1
			var flow: float = 0.0
			var rq: float = open_q * 0.38
			if phase < open_q:
				flow = 0.5 * (1.0 - cos(PI * phase / open_q))
			elif phase < open_q + rq:
				flow = cos(PI * (phase - open_q) / (2.0 * rq))
			# Creak halves alternate periods. One modulo, and it is the single
			# most effective knob in the file for making a calm sentence read as
			# a threat.
			if creak > 0.0 and (period_i & 1) == 1:
				flow *= 1.0 - 0.85 * creak
			# Differentiate (radiation), then tilt: a real glottal spectrum rolls
			# off, and a source with no tilt sounds like a buzzer.
			var d: float = flow - src_prev
			src_prev = flow
			src_lp += tilt_k * (d - src_lp)
			src = src_lp * 26.0 * av
		else:
			src_prev *= 0.98

		src += asp * ah * 0.34 * asp_gain

		# --- cascade ---------------------------------------------------------
		var v: float = za * src + zb * zx1 + zc * zx2
		zx2 = zx1
		zx1 = src
		v = pa * v + pb * np1 + pc * np2
		np2 = np1
		np1 = v
		v = a1 * v + b1c * y11 + c1 * y12
		y12 = y11
		y11 = v
		v = a2 * v + b2c * y21 + c2 * y22
		y22 = y21
		y21 = v
		v = a3 * v + b3c * y31 + c3 * y32
		y32 = y31
		y31 = v
		v = a4 * v + b4c * y41 + c4 * y42
		y42 = y41
		y41 = v
		v = a5 * v + b5c * y51 + c5 * y52
		y52 = y51
		y51 = v

		# --- parallel frication ---------------------------------------------
		if af > 0.0001:
			var fs: float = frn * af * fric_gain
			var w: float = fa1 * fs - fb1 * g11 - fc1 * g12
			var o1v: float = w - g12
			g12 = g11
			g11 = w
			var w2: float = fa2 * fs - fb2 * g21 - fc2 * g22
			var o2v: float = w2 - g22
			g22 = g21
			g21 = w2
			v += (o1v * amp1 + o2v * amp2) * 0.85

		out[i] = v

	return out


## Klatt's two-pole resonator, normalised to unity gain at DC.
## y[n] = a*x[n] + b*y[n-1] + c*y[n-2]
static func _reson(f: float, bw: float, sr: float) -> Array:
	var ff: float = clampf(f, 40.0, sr * 0.48)
	var bb: float = clampf(bw, 20.0, sr * 0.45)
	var r: float = exp(-PI * bb / sr)
	var b: float = 2.0 * r * cos(TAU * ff / sr)
	var c: float = -r * r
	return [1.0 - b - c, b, c]


## Transposed direct-form-II bandpass, unity gain at the peak. Used for the
## frication bank, where a DC-normalised resonator would leak the whole low end
## of the noise into every /s/ and turn sibilance into rumble.
## Returns [a0, a1, a2] for  w = a0*x - a1*w1 - a2*w2 ;  y = w - w2
static func _bandpass(f: float, bw: float, sr: float) -> Array:
	var ff: float = clampf(f, 60.0, sr * 0.47)
	var bb: float = clampf(bw, 40.0, sr * 0.9)
	var q: float = maxf(ff / bb, 0.30)
	var w0: float = TAU * ff / sr
	var alpha: float = sin(w0) / (2.0 * q)
	var a0: float = 1.0 + alpha
	return [alpha / a0, (-2.0 * cos(w0)) / a0, (1.0 - alpha) / a0]
