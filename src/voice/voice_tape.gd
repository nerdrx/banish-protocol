class_name VoiceTape
extends RefCounted
## M14 — the post chain: room, then tape.
##
## Everything that makes her sound like MOTHER rather than like a speech
## synthesiser lives here. It is a port of the cassette chain the baked cues
## used, with two deliberate substitutions:
##
##   * CONVOLUTION REVERB became a Schroeder network. A 2.6 s procedural impulse
##     response needs an FFT convolution, and a 2^18-point FFT in GDScript is
##     seconds of work per line. A four-comb / two-allpass network with
##     frequency-dependent damping gives the same two facts the ear is actually
##     using — how long the tail is and how dark it is — for about 1 % of the
##     cost. Honest delta: the early-reflection pattern is generic, so her rooms
##     have less individual character than the baked ones did. Nobody has been
##     able to name which room a line was in, so this is the right trade.
##   * ZERO-PHASE FILTERS became ordinary one-pole and biquad recursions. The
##     phase difference is inaudible on this material and the frequency-domain
##     versions each cost a full-buffer FFT.
##
## THE CLARITY RULE, and it is new: the tape must never eat the words. Every
## parameter here is scaled by the register, and the directed register — the one
## she says your callsign in — runs the chain at roughly a third of the depth the
## baked address cues used. The dropouts in particular are HF-first amplitude
## holes, and an HF hole lands exactly on the sibilance that carries consonant
## identity. She is allowed to sound like a recording. She is not allowed to
## sound like a damaged one while she is telling you something.

## Catmull-Rom, for the wow/flutter resample. Linear interpolation here
## low-passes the modulation into a dull hiss, which is audible and is exactly
## the artefact that makes cheap tape emulation sound cheap.
static func _cubic(x: PackedFloat32Array, pos: float) -> float:
	var n: int = x.size()
	var i: int = int(floor(pos))
	var f: float = pos - float(i)
	var p0: float = x[clampi(i - 1, 0, n - 1)]
	var p1: float = x[clampi(i, 0, n - 1)]
	var p2: float = x[clampi(i + 1, 0, n - 1)]
	var p3: float = x[clampi(i + 2, 0, n - 1)]
	return p1 + 0.5 * f * (p2 - p0 + f * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3
			+ f * (3.0 * (p1 - p2) + p3 - p0)))


# ------------------------------------------------------------------ filters --

static func one_pole_lp(x: PackedFloat32Array, hz: float, rate: int) -> PackedFloat32Array:
	if hz >= float(rate) * 0.49:
		return x
	var k: float = 1.0 - exp(-TAU * hz / float(rate))
	var z: float = 0.0
	for i: int in x.size():
		z += k * (x[i] - z)
		x[i] = z
	return x


static func one_pole_hp(x: PackedFloat32Array, hz: float, rate: int) -> PackedFloat32Array:
	var k: float = 1.0 - exp(-TAU * hz / float(rate))
	var z: float = 0.0
	for i: int in x.size():
		z += k * (x[i] - z)
		x[i] = x[i] - z
	return x


## RBJ biquad, direct form I, applied in place.
static func biquad(x: PackedFloat32Array, c: Array) -> PackedFloat32Array:
	var b0: float = float(c[0])
	var b1: float = float(c[1])
	var b2: float = float(c[2])
	var a1: float = float(c[3])
	var a2: float = float(c[4])
	var x1: float = 0.0
	var x2: float = 0.0
	var y1: float = 0.0
	var y2: float = 0.0
	for i: int in x.size():
		var xi: float = x[i]
		var yi: float = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1
		x1 = xi
		y2 = y1
		y1 = yi
		x[i] = yi
	return x


static func low_shelf_coeffs(hz: float, db: float, rate: int, q: float = 0.7) -> Array:
	var a: float = pow(10.0, db / 40.0)
	var w: float = TAU * hz / float(rate)
	var cw: float = cos(w)
	var alpha: float = sin(w) / (2.0 * q)
	var tsa: float = 2.0 * sqrt(a) * alpha
	var a0: float = (a + 1.0) + (a - 1.0) * cw + tsa
	return [
		a * ((a + 1.0) - (a - 1.0) * cw + tsa) / a0,
		2.0 * a * ((a - 1.0) - (a + 1.0) * cw) / a0,
		a * ((a + 1.0) - (a - 1.0) * cw - tsa) / a0,
		(-2.0 * ((a - 1.0) + (a + 1.0) * cw)) / a0,
		((a + 1.0) + (a - 1.0) * cw - tsa) / a0,
	]


static func high_shelf_coeffs(hz: float, db: float, rate: int, q: float = 0.7) -> Array:
	var a: float = pow(10.0, db / 40.0)
	var w: float = TAU * hz / float(rate)
	var cw: float = cos(w)
	var alpha: float = sin(w) / (2.0 * q)
	var tsa: float = 2.0 * sqrt(a) * alpha
	var a0: float = (a + 1.0) - (a - 1.0) * cw + tsa
	return [
		a * ((a + 1.0) + (a - 1.0) * cw + tsa) / a0,
		-2.0 * a * ((a - 1.0) + (a + 1.0) * cw) / a0,
		a * ((a + 1.0) + (a - 1.0) * cw - tsa) / a0,
		(2.0 * ((a - 1.0) - (a + 1.0) * cw)) / a0,
		((a + 1.0) - (a - 1.0) * cw - tsa) / a0,
	]


static func peak_coeffs(hz: float, db: float, q: float, rate: int) -> Array:
	var a: float = pow(10.0, db / 40.0)
	var w: float = TAU * hz / float(rate)
	var alpha: float = sin(w) / (2.0 * q)
	var a0: float = 1.0 + alpha / a
	return [
		(1.0 + alpha * a) / a0,
		(-2.0 * cos(w)) / a0,
		(1.0 - alpha * a) / a0,
		(-2.0 * cos(w)) / a0,
		(1.0 - alpha / a) / a0,
	]


# ------------------------------------------------------------------- reverb --

## Comb delays in samples at 48 kHz, scaled for other rates. Mutually prime-ish
## so the tail does not develop a pitch.
const COMBS: Array[int] = [1687, 1901, 2143, 2477]
const ALLPASS: Array[int] = [341, 113]


## Schroeder reverb with per-comb HF damping. `rt60_low` sets the feedback,
## `damp_hz` how fast the top decays — long lows and short highs is the entire
## difference between "reverb" and "a plausible concrete room".
static func reverb(x: PackedFloat32Array, rate: int, rt60: float, damp_hz: float,
		predelay: float, mix: float) -> PackedFloat32Array:
	if mix <= 0.0:
		return x
	var n: int = x.size()
	var scale: float = float(rate) / 48000.0
	var wet: PackedFloat32Array = PackedFloat32Array()
	wet.resize(n)
	var damp_k: float = 1.0 - exp(-TAU * damp_hz / float(rate))
	for ci: int in COMBS.size():
		var d: int = maxi(int(float(COMBS[ci]) * scale), 8)
		var g: float = pow(10.0, -3.0 * float(d) / (maxf(rt60, 0.05) * float(rate)))
		var buf: PackedFloat32Array = PackedFloat32Array()
		buf.resize(d)
		var lp: float = 0.0
		var p: int = 0
		for i: int in n:
			var y: float = buf[p]
			wet[i] += y
			lp += damp_k * (y - lp)
			buf[p] = x[i] + lp * g
			p += 1
			if p >= d:
				p = 0
	var inv: float = 1.0 / float(COMBS.size())
	for i: int in n:
		wet[i] *= inv
	for ai: int in ALLPASS.size():
		var d: int = maxi(int(float(ALLPASS[ai]) * scale), 4)
		var buf: PackedFloat32Array = PackedFloat32Array()
		buf.resize(d)
		var p: int = 0
		var g: float = 0.62
		for i: int in n:
			var bufout: float = buf[p]
			var inp: float = wet[i]
			buf[p] = inp + bufout * g
			wet[i] = bufout - inp * g
			p += 1
			if p >= d:
				p = 0
	var pre: int = maxi(int(predelay * float(rate)), 0)
	for i: int in n:
		var s: int = i - pre
		x[i] = x[i] + (wet[s] if s >= 0 else 0.0) * mix
	return x


# --------------------------------------------------------------- the chain --

## Run the post chain. `opts` comes from `VoiceRegisters`; `seed` keeps a given
## utterance's tape damage identical every time it is synthesised, which is what
## lets the cache promise byte-identical audio.
static func process(x: PackedFloat32Array, rate: int, opts: Dictionary,
		seed: int) -> PackedFloat32Array:
	var n: int = x.size()
	if n == 0:
		return x
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed

	# Normalise to unity peak first so every threshold below means the same thing
	# regardless of what the synthesiser handed us; the loudness pass at the end
	# sets the real level.
	var peak: float = 0.0
	for v: float in x:
		peak = maxf(peak, absf(v))
	if peak > 1e-9:
		var g: float = 1.0 / peak
		for i: int in n:
			x[i] = x[i] * g

	# --- room ---------------------------------------------------------------
	var rmix: float = float(opts.get("reverb_mix", 0.0))
	if rmix > 0.0:
		x = reverb(x, rate, float(opts.get("reverb_rt60", 0.9)),
				float(opts.get("reverb_damp", 5000.0)),
				float(opts.get("reverb_predelay", 0.010)), rmix)

	# --- proximity ----------------------------------------------------------
	# The close-mic low shelf. A capsule 3 cm from a mouth gains 6-10 dB below
	# 200 Hz, and our ears read that as INTIMATE long before they read it as
	# bassy. She is not louder in the subzero register; she is nearer.
	var prox: float = float(opts.get("proximity", 0.0))
	if prox > 0.0:
		x = biquad(x, low_shelf_coeffs(210.0, 7.5 * prox, rate))

	# --- record amplifier ---------------------------------------------------
	var comp: float = float(opts.get("comp", 0.30))
	if comp > 0.0:
		x = _compress(x, rate, comp, float(opts.get("comp_ratio", 4.0)))

	# --- transport speed error ---------------------------------------------
	var wow: float = float(opts.get("wow", 0.0016))
	var flutter: float = float(opts.get("flutter", 0.0009))
	if wow > 0.0 or flutter > 0.0:
		var wow_hz: float = float(opts.get("wow_hz", 0.52))
		var p1: float = rng.randf() * TAU
		var p2: float = rng.randf() * TAU
		var p3: float = rng.randf() * TAU
		var src: PackedFloat32Array = x.duplicate()
		for i: int in n:
			var t: float = float(i) / float(rate)
			var warp: float = wow / (TAU * wow_hz) * sin(TAU * wow_hz * t + p1)
			warp += (wow * 0.55) / (TAU * wow_hz * 2.7) * sin(TAU * wow_hz * 2.7 * t + p2)
			warp += flutter / (TAU * 7.4) * sin(TAU * 7.4 * t + p3)
			x[i] = _cubic(src, clampf(float(i) + warp * float(rate), 0.0, float(n - 1)))

	# --- tape saturation, pre/de-emphasised --------------------------------
	# Real tape compresses highs harder than lows. Boost highs, saturate, cut
	# them back; the HF is what gets squashed and that self-limiting sizzle is
	# the sound. A bare tanh over the full band is just distortion.
	var sat: float = float(opts.get("sat", 1.2))
	if sat > 0.0:
		x = biquad(x, high_shelf_coeffs(2500.0, 7.0, rate))
		var th: float = tanh(sat)
		for i: int in n:
			x[i] = tanh(x[i] * sat) / th
		x = biquad(x, high_shelf_coeffs(2500.0, -7.0, rate))

	# --- print-through (a PRE-echo: the reel bleeds onto the layer above) ---
	var pt: float = float(opts.get("print_through_db", -90.0))
	if pt > -80.0:
		var lag: int = int(0.62 * float(rate))
		var amt: float = pow(10.0, pt / 20.0)
		var echo: PackedFloat32Array = PackedFloat32Array()
		echo.resize(n)
		for i: int in range(0, n - lag):
			echo[i] = x[i + lag]
		echo = one_pole_lp(echo, 2600.0, rate)
		for i: int in n:
			x[i] += echo[i] * amt

	# --- dropouts -----------------------------------------------------------
	# Oxide shedding. HF goes FIRST and the level follows, so a partial dropout
	# is a dull patch, not a gap. Off entirely in the directed register: an HF
	# hole is a hole in the consonants.
	var drop: float = float(opts.get("dropouts", 0.0))
	if drop > 0.0:
		var depth: float = float(opts.get("dropout_depth", 0.6))
		var env: PackedFloat32Array = PackedFloat32Array()
		var hf: PackedFloat32Array = PackedFloat32Array()
		env.resize(n)
		hf.resize(n)
		for i: int in n:
			env[i] = 1.0
			hf[i] = 1.0
		var count: int = int(drop * (float(n) / float(rate)) * 1.6)
		for _k: int in count:
			var c: int = rng.randi_range(0, maxi(n - 1, 0))
			var width: int = int(rng.randf_range(0.012, 0.16) * float(rate))
			var lo: int = maxi(0, c - width / 2)
			var hi: int = mini(n, c + width / 2)
			if hi <= lo:
				continue
			var sev: float = pow(rng.randf(), 1.8)
			for i: int in range(lo, hi):
				var u: float = 2.0 * float(i - lo) / float(hi - lo) - 1.0
				var bell: float = exp(-3.0 * u * u)
				hf[i] = minf(hf[i], 1.0 - bell * (0.55 + 0.45 * sev))
				env[i] = minf(env[i], 1.0 - bell * depth * sev)
		var dull: PackedFloat32Array = one_pole_lp(x.duplicate(), 1500.0, rate)
		for i: int in n:
			x[i] = (x[i] * hf[i] + dull[i] * (1.0 - hf[i])) * env[i]

	# --- playback head EQ ---------------------------------------------------
	x = biquad(x, low_shelf_coeffs(78.0, float(opts.get("head_bump_db", 3.0)), rate))
	x = one_pole_lp(x, float(opts.get("azimuth_hz", 9000.0)), rate)
	x = one_pole_hp(x, 62.0, rate)

	# --- presence -----------------------------------------------------------
	# A consonant-band lift, and the one thing in this file that exists purely
	# for intelligibility. 2.6 kHz is where the burst/fricative cues live and
	# where a cassette's own losses bite first; putting some of it back is what
	# a broadcast chain would have done anyway.
	var pres: float = float(opts.get("presence_db", 0.0))
	if not is_zero_approx(pres):
		x = biquad(x, peak_coeffs(float(opts.get("presence_hz", 2600.0)), pres, 0.9, rate))

	# --- hiss ---------------------------------------------------------------
	var hiss_db: float = float(opts.get("hiss_db", -62.0))
	if hiss_db > -85.0:
		var amt: float = pow(10.0, hiss_db / 20.0)
		var hz: PackedFloat32Array = PackedFloat32Array()
		hz.resize(n)
		for i: int in n:
			hz[i] = rng.randf() * 2.0 - 1.0
		hz = one_pole_lp(hz, 10000.0, rate)
		hz = one_pole_hp(hz, 700.0, rate)
		for i: int in n:
			x[i] += hz[i] * amt * 1.7

	return _fade_edges(x, rate, 14.0)


## The record amplifier plus the tape's own headroom curve. Not a mastering
## limiter: a cassette physically cannot pass the 22 dB crest factor a raw
## synthesised stop burst has, and pretending it can leaves a line 2 dB short of
## its loudness target because one /t/ ate all the headroom.
static func _compress(x: PackedFloat32Array, rate: int, threshold: float,
		ratio: float) -> PackedFloat32Array:
	var n: int = x.size()
	var det: PackedFloat32Array = PackedFloat32Array()
	det.resize(n)
	for i: int in n:
		det[i] = absf(x[i])
	det = one_pole_lp(det, 1.0 / 0.003, rate)
	var gain: PackedFloat32Array = PackedFloat32Array()
	gain.resize(n)
	var e: float = 1.0 / ratio - 1.0
	for i: int in n:
		gain[i] = pow(maxf(det[i] / threshold, 1.0), e)
	# Forward-then-backward one-pole == a zero-phase smooth, which is the
	# look-ahead a real record amplifier gets for free by being slow.
	gain = one_pole_lp(gain, 110.0, rate)
	var z: float = gain[n - 1]
	var k: float = 1.0 - exp(-TAU * 110.0 / float(rate))
	for i: int in range(n - 1, -1, -1):
		z += k * (gain[i] - z)
		gain[i] = z
	for i: int in n:
		x[i] = x[i] * gain[i]
	return x


static func _fade_edges(x: PackedFloat32Array, rate: int, ms: float) -> PackedFloat32Array:
	var k: int = mini(int(float(rate) * ms / 1000.0), x.size() / 2)
	for i: int in k:
		var w: float = float(i) / float(k)
		x[i] = x[i] * w
		x[x.size() - 1 - i] = x[x.size() - 1 - i] * w
	return x
