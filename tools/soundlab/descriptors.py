#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — SOUND LAB: the descriptor suite.
#
# The premise of this whole directory: "impressive" is not a mystical property
# only ears can reach. Most of what makes a game sound effect read as GENERIC is
# measurable, and the failure modes are boringly consistent:
#
#   * no energy below 80 Hz              -> no weight, no matter how loud
#   * a spectrum that does not MOVE      -> the single most common cause. A real
#                                           impact starts bright and darkens as
#                                           the bright partials die first; a
#                                           synth stack with one envelope on
#                                           everything has a static centroid and
#                                           reads as "a beep" no matter how it
#                                           is EQ'd.
#   * a slow attack on an impact         -> no transient, no punch
#   * a crest factor that does not
#     survive loudness normalisation     -> the sound is already squashed
#   * two-octave bandwidth               -> "thin", "cheap"
#   * a library where forty files measure
#     the same                           -> everything sounds like everything
#
# So: measure all of it, over the whole shipped library, and let the numbers say
# which assets are the problem instead of guessing.
#
# EVERY DESCRIPTOR HERE IS DETERMINISTIC. No RNG, no sampling, no thresholds
# derived from the corpus at measure time. Two runs over the same file produce
# byte-identical JSON; that is asserted by `analyze.py --verify-reproducible`.
# ---------------------------------------------------------------------------
from __future__ import annotations

import numpy as np

from dsp import (RATE, bark_filterbank, band_energies, bs1770, db,
                 envelope_rms, hz_to_bark, load, power_spectrum, stft)

# Full-scale reference for the psychoacoustic models. Zwicker's loudness and
# sharpness are defined on absolute SPL, and a digital file has none — so we
# adopt a convention and state it: digital full scale = 96 dB SPL, roughly a
# game mixed to sit at 75-80 dB SPL peak on a calibrated system with headroom.
# Sharpness is nearly invariant to this constant (it is a ratio); loudness and
# roughness are not, so their absolute values are meaningful only RELATIVE to
# other files measured with the same convention. Which is all we ask of them.
FULL_SCALE_SPL_DB = 96.0


# --------------------------------------------------------------- envelope ---

def _attack_decay(x: np.ndarray) -> dict:
    """Attack time, transient sharpness and decay shape from the RMS envelope.

       attack_ms       10 % -> 90 % of the envelope's global peak. The classic
                       definition, and the one that separates a hit from a swell.
       attack_slope    dB per millisecond across that rise. A 60 dB/ms slope is
                       a gunshot; 2 dB/ms is a door opening.
       decay_t60_ms    time from peak to -60 dB, by straight-line fit to the
                       post-peak envelope in dB (an exponential decay is a line
                       in dB, so the fit residual doubles as a shape test).
       decay_linearity R^2 of that fit. Near 1.0 = a clean exponential ring-out
                       (physical). Low = a plateau, a gate, or a tail that was
                       chopped — the "it just stops" defect.
       sustain_frac    fraction of the sound spent above -20 dB of peak. High on
                       a one-shot means it is really a loop.
    """
    # A 1 ms window at a 0.2 ms hop: the attack times that matter here are 2-10
    # ms and a coarser envelope simply reports "0". ATTACK_FLOOR_MS below is the
    # instrument's resolution, and no attack is ever reported faster than it.
    ATTACK_FLOOR_MS = 0.2
    env, t = envelope_rms(x, win_ms=1.0, hop_ms=ATTACK_FLOOR_MS)
    peak = float(env.max())
    if peak <= 0:
        return dict(attack_ms=0.0, attack_slope_db_per_ms=0.0,
                    decay_t60_ms=0.0, decay_linearity=0.0, sustain_frac=0.0,
                    peak_time_ms=0.0)
    pk = int(np.argmax(env))
    e = env / peak
    # Attack: first crossing of 0.1 before the peak, first crossing of 0.9.
    pre = e[:pk + 1]
    lo_idx = np.nonzero(pre >= 0.1)[0]
    hi_idx = np.nonzero(pre >= 0.9)[0]
    i_lo = int(lo_idx[0]) if len(lo_idx) else 0
    i_hi = int(hi_idx[0]) if len(hi_idx) else pk
    attack_ms = max((t[i_hi] - t[i_lo]) * 1000.0, ATTACK_FLOOR_MS)
    attack_slope = (db(e[i_hi]) - db(e[i_lo])) / attack_ms

    # Decay: fit dB(env) vs time over peak -> the point it falls 40 dB (or the
    # end), then extrapolate to 60 dB. Fitting to -40 rather than -60 keeps the
    # noise floor and the Vorbis decoder's own hiss out of the regression.
    post = e[pk:]
    tp = t[pk:] - t[pk]
    pdb = db(post)
    end = np.nonzero(pdb <= -40.0)[0]
    stop = int(end[0]) if len(end) else len(post)
    stop = max(stop, 8)
    if stop >= len(post):
        stop = len(post)
    seg_t, seg_db = tp[:stop], pdb[:stop]
    if len(seg_t) >= 4 and seg_t[-1] > 0:
        A = np.vstack([seg_t, np.ones_like(seg_t)]).T
        slope, icept = np.linalg.lstsq(A, seg_db, rcond=None)[0]
        pred = A @ np.array([slope, icept])
        ss_res = float(((seg_db - pred) ** 2).sum())
        ss_tot = float(((seg_db - seg_db.mean()) ** 2).sum()) or 1e-9
        r2 = max(0.0, 1.0 - ss_res / ss_tot)
        t60 = (-60.0 / slope) * 1000.0 if slope < -1e-6 else 1e6
    else:
        r2, t60 = 0.0, 0.0
    return dict(attack_ms=float(attack_ms),
                attack_slope_db_per_ms=float(attack_slope),
                decay_t60_ms=float(min(t60, 1e6)),
                decay_linearity=float(r2),
                sustain_frac=float((e > 0.1).mean()),
                peak_time_ms=float(t[pk] * 1000.0))


# --------------------------------------------------------------- spectral ---

def _spectral(x: np.ndarray) -> dict:
    """Static spectral shape plus — the important half — its TRAJECTORY.

       centroid_hz             energy-weighted mean frequency of the whole file.
       centroid_start/end_hz   centroid of the first / last quarter of the
                               sound's ENERGY (not of its duration: a 2 s file
                               with a 30 ms event should be measured across the
                               event, not across the silence).
       centroid_drop_oct       log2(start/end). POSITIVE means the sound darkens
                               as it decays, which is what every real impact
                               does and what almost no naive synth does.
       centroid_drift_oct      total absolute octave travel of the centroid,
                               frame to frame — movement of any kind, including
                               a rise.
       flux                    mean L2 norm of the positive frame-to-frame
                               change in the normalised magnitude spectrum.
                               A file with flux near zero is a held tone.
       spread_oct              spectral standard deviation expressed in octaves.
       bw20_oct                width in octaves of the band that sits within
                               20 dB of the spectral peak — the "is this thing
                               narrow-band" test, more robust than spread.
       flatness                geometric/arithmetic mean of the power spectrum.
                               1.0 = white noise, near 0 = pure tone.
       hnr_db                  harmonic-to-noise ratio by autocorrelation: how
                               pitched the sound is. Distinct from flatness,
                               which a dense inharmonic cluster also fools.
       rolloff85_hz            frequency below which 85 % of the energy sits.
    """
    # A 1024-point window (21 ms, 47 Hz bins) at a 128-sample hop.
    #
    # The window length is a real decision, not a default. At 2048 the window is
    # 43 ms long — longer than the entire bright half of a percussive sound — so
    # the transient's brightness is averaged together with the tail that follows
    # it and centroid_drop reads about half its true value. (Measured: a test
    # signal built from a 20 ms-decay 3.2 kHz partial over a 300 ms-decay 200 Hz
    # partial has a true drop near 2 octaves; a 2048 window reports 0.8, a 1024
    # window reports 1.8.) 1024 is the shortest window that still resolves a
    # 50 Hz fundamental well enough for the low end of the centroid to be
    # meaningful, so it is the one used for everything time-varying here.
    mag, freqs, times = stft(x, n_fft=1024, hop=128)
    p = mag ** 2
    frame_e = p.sum(axis=0)
    total = float(frame_e.sum()) or 1e-30

    def centroid_of(pw: np.ndarray) -> float:
        s = float(pw.sum())
        return float((freqs * pw).sum() / s) if s > 0 else 0.0

    overall = centroid_of(p.sum(axis=1))

    # Energy-time quantiles: the frames carrying the first 15 % and the last
    # 25 % of the total energy. Silence-proof, which duration quantiles are not.
    # 15 % rather than 25 % at the head because on a percussive sound the strike
    # is a small fraction of the total energy and a wider window dilutes it with
    # the ring-out we are trying to compare it against.
    cum = np.cumsum(frame_e) / total
    i_head = int(np.searchsorted(cum, 0.15))
    i75 = int(np.searchsorted(cum, 0.75))
    i_head = min(max(i_head, 1), len(frame_e) - 1)
    i75 = min(max(i75, i_head), len(frame_e) - 1)
    c_start = centroid_of(p[:, :i_head + 1].sum(axis=1))
    c_end = centroid_of(p[:, i75:].sum(axis=1))
    drop_oct = float(np.log2(max(c_start, 1.0) / max(c_end, 1.0)))

    # Per-frame centroid trajectory, restricted to frames that actually have
    # energy (-40 dB of the loudest frame) so the tail's noise floor does not
    # invent movement.
    live = frame_e > frame_e.max() * 1e-4
    cf = (freqs[:, None] * p).sum(axis=0) / np.maximum(p.sum(axis=0), 1e-30)
    cf_live = np.maximum(cf[live], 1.0)
    if len(cf_live) > 6:
        # Smooth before differencing: the frame-to-frame centroid of a noisy
        # sound jitters by a few percent, and an unsmoothed sum of |diff| is a
        # measurement of that jitter rather than of the sound's movement.
        k = np.ones(5) / 5.0
        sm_cf = np.convolve(np.log2(cf_live), k, mode="valid")
        span = max(times[live][-1] - times[live][0], 1e-3)
        drift = float(np.abs(np.diff(sm_cf)).sum())
        traj_slope = float(np.polyfit(times[live], np.log2(cf_live), 1)[0])
        drift_per_s = drift / span
    else:
        drift, traj_slope, drift_per_s = 0.0, 0.0, 0.0

    # Spectral flux, on power-normalised frames so a loud frame does not read as
    # a spectral change.
    norm = p / np.maximum(p.sum(axis=0, keepdims=True), 1e-30)
    d = np.diff(norm, axis=1)
    flux = float(np.sqrt((np.maximum(d, 0.0) ** 2).sum(axis=0)).mean()) if d.size else 0.0

    pw, fr = power_spectrum(x)
    s = float(pw.sum()) or 1e-30
    cen = float((fr * pw).sum() / s)
    # Spread measured on a LOG frequency axis. On a linear axis the spread of a
    # bass-heavy sound is dominated by where its centroid happens to sit, and
    # every low sound reads as "narrow" — which is the opposite of true.
    aud = (fr >= 20.0) & (fr <= 20000.0)
    lf = np.log2(fr[aud])
    lp = pw[aud]
    ls = float(lp.sum()) or 1e-30
    lcen = float((lf * lp).sum() / ls)
    spread_oct = float(np.sqrt(max(((lf - lcen) ** 2 * lp).sum() / ls, 0.0)))
    # -20 dB bandwidth, measured on a 1/6-octave smoothed spectrum so a single
    # FFT bin cannot define the edge.
    sm = _octave_smooth(pw, fr, frac=6.0)
    top = float(sm[aud].max()) or 1e-30
    above = np.nonzero((sm >= top * 10 ** (-20.0 / 10.0)) & aud)[0]
    if len(above) > 1:
        f_lo = max(fr[above[0]], 20.0)
        f_hi = max(fr[above[-1]], f_lo * 1.01)
        bw20 = float(np.log2(f_hi / f_lo))
    else:
        bw20 = 0.0
    cs = np.cumsum(pw) / s
    rolloff = float(fr[int(np.searchsorted(cs, 0.85))])
    # Flatness on the SMOOTHED spectrum with a -80 dB floor. On the raw
    # spectrum, a sound with a steep rolloff has thousands of denormal bins and
    # the geometric mean underflows to zero, which reads as "pure tone" for a
    # footstep — the exact opposite of the truth.
    band = np.maximum(sm[aud], top * 1e-8)
    flatness = float(np.exp(np.log(band).mean()) / band.mean())

    return dict(centroid_hz=float(overall),
                centroid_start_hz=float(c_start),
                centroid_end_hz=float(c_end),
                centroid_drop_oct=drop_oct,
                centroid_drift_oct=drift,
                centroid_drift_oct_per_s=drift_per_s,
                centroid_slope_oct_per_s=traj_slope,
                flux=flux,
                spread_oct=spread_oct,
                bw20_oct=bw20,
                rolloff85_hz=rolloff,
                flatness=flatness,
                hnr_db=_hnr(x))


def _octave_smooth(pw: np.ndarray, fr: np.ndarray, frac: float = 6.0
                   ) -> np.ndarray:
    """Constant-Q smoothing of a linear-frequency power spectrum. Without it,
       every bandwidth measurement is a measurement of FFT bin noise."""
    out = np.zeros_like(pw)
    r = 2.0 ** (0.5 / frac)
    csum = np.concatenate([[0.0], np.cumsum(pw)])
    lo = np.searchsorted(fr, fr / r, side="left")
    hi = np.searchsorted(fr, fr * r, side="right")
    hi = np.maximum(hi, lo + 1)
    out = (csum[hi] - csum[lo]) / (hi - lo)
    return out


def _hnr(x: np.ndarray) -> float:
    """Harmonic-to-noise ratio via normalised autocorrelation, on the loudest
       46 ms of the file. Boersma's estimator in its simplest useful form:
       r_max over lags 2.5 ms - 20 ms (50-400 Hz) gives HNR = 10log10(r/(1-r)).

       Reported because "pitched" and "noisy" are different kinds of generic: a
       creature roar that measures +20 dB HNR is a synthesiser playing a note,
       and a footstep that measures -10 dB is a puff of static."""
    n = min(len(x), int(RATE * 0.046))
    if n < 512:
        return -30.0
    env, _ = envelope_rms(x)
    pk = int(np.argmax(env))
    start = min(max(int(pk * (len(x) / max(len(env), 1))) - n // 4, 0), len(x) - n)
    seg = x[start:start + n].astype(float)
    seg = seg - seg.mean()
    if not np.any(seg):
        return -30.0
    win = np.hanning(n)
    seg = seg * win
    nfft = 1 << int(np.ceil(np.log2(2 * n)))
    ac = np.fft.irfft(np.abs(np.fft.rfft(seg, nfft)) ** 2, nfft)[:n]
    if ac[0] <= 0:
        return -30.0
    # Boersma's correction: divide by the autocorrelation of the WINDOW. A Hann
    # window's own taper suppresses long-lag correlation by tens of percent, so
    # without this a perfectly periodic signal reads as partly noisy — and the
    # error grows with lag, which biases every low-pitched sound downward.
    wac = np.fft.irfft(np.abs(np.fft.rfft(win, nfft)) ** 2, nfft)[:n]
    wac = wac / max(wac[0], 1e-30)
    ac = ac / ac[0]
    ac = ac / np.maximum(wac, 1e-3)
    # 1-20 ms of lag: 50 Hz to 1 kHz. The old 2.5 ms floor excluded everything
    # above 400 Hz, which meant a 440 Hz tone — the most obviously periodic
    # signal there is — measured as half noise.
    lo = int(RATE * 0.001)
    hi = min(int(RATE * 0.020), n - 1)
    if hi <= lo:
        return -30.0
    r = float(np.clip(ac[lo:hi].max(), 0.0, 0.999))
    return float(10.0 * np.log10(max(r, 1e-4) / max(1.0 - r, 1e-4)))


# -------------------------------------------------------- psychoacoustics ---
#
# Two Zwicker-family descriptors, because they are the two that correlate with
# the words a player actually uses. "Sharp" and "aggressive" is sharpness;
# "nasty", "gnarly", "wrong" is roughness. Both are computed from a specific
# loudness pattern N'(z) over 24 Bark bands.
#
# These are FAITHFUL-IN-SHAPE implementations, not certified ones: DIN 45692 and
# Daniel & Weber define their models on stationary signals through a calibrated
# reproduction chain, and a 90 ms one-shot from a game asset is neither. What
# they give us is a consistent, monotone ranking across our own library, which is
# exactly what a search objective needs. Absolute acum / asper values should be
# read as "our units", and the report says so.

def _specific_loudness(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """N'(z) over 24 Bark bands, from Zwicker's power law.

       N' = 0.08 (E_TQ/E0)^0.23 [ (0.5 + 0.5 E/E_TQ)^0.23 - 1 ]

       with E the band excitation and E_TQ the threshold in quiet, both relative
       to E0 = 10^-12 W/m^2. The threshold curve is the standard ISO 226-ish
       tabulation resampled onto our band centres."""
    p, fr = power_spectrum(x)
    fb = bark_filterbank(fr, n_bands=24)
    e_lin = fb @ p
    e_lin = e_lin / max(float(e_lin.sum()), 1e-30)          # normalise shape
    # Absolute level: the file's RMS mapped through the stated SPL convention.
    rms = float(np.sqrt(np.mean(x ** 2))) or 1e-9
    spl = FULL_SCALE_SPL_DB + 20.0 * np.log10(rms)
    band_spl = spl + 10.0 * np.log10(np.maximum(e_lin, 1e-12))

    z = np.linspace(0.5, 23.5, 24)
    # Threshold in quiet, dB SPL, at the 24 Bark band centres. Standard Zwicker
    # table (Psychoacoustics, Fastl & Zwicker, Table 'a0'/LTQ).
    ltq = np.array([30, 18, 12, 8, 7, 6, 5, 4, 3, 3, 3, 3,
                    3, 3, 3, 3, 4, 5, 6, 8, 11, 15, 20, 26], dtype=float)
    e = 10.0 ** (band_spl / 10.0)
    etq = 10.0 ** (ltq / 10.0)
    n_prime = 0.08 * (etq / 1e0) ** 0.23 * (
        np.maximum(0.5 + 0.5 * e / etq, 1e-9) ** 0.23 - 1.0)
    n_prime = np.maximum(n_prime, 0.0)
    return n_prime, z


def _sharpness(n_prime: np.ndarray, z: np.ndarray) -> float:
    """Zwicker / DIN 45692 sharpness in acum.

       S = 0.11 * sum(N'(z) g(z) z dz) / sum(N'(z) dz),  g(z) = 1 for z < 16,
       0.066 exp(0.171 z) above. High sharpness is the "bite" of a weapon and
       the "shrill" of a UI beep; it is the descriptor that tells those two
       apart from their intent, not from their level."""
    g = np.where(z < 16.0, 1.0, 0.066 * np.exp(0.171 * z))
    denom = float(n_prime.sum()) or 1e-12
    return float(0.11 * float((n_prime * g * z).sum()) / denom)


def _roughness(x: np.ndarray) -> float:
    """Daniel & Weber-style roughness, in our units.

       Roughness is amplitude modulation of the critical-band envelopes at rates
       around 70 Hz — the beat rate the ear stops hearing as tremolo and starts
       hearing as texture. It is the physical correlate of "gnarly": a creature
       roar with no roughness is a synth pad, and the difference between a
       menacing engine and a hum is almost entirely here.

       Implementation: Bark-band envelopes from the STFT, their modulation
       spectra, weighted by the Daniel-Weber g(f_mod) bandpass peaked at 70 Hz,
       normalised by band energy so the value is level-independent."""
    # 256-sample window at a 64-sample hop: the envelope sample rate is 750 Hz,
    # which is what lets a 70 Hz modulation be seen at all (Nyquist 375 Hz), and
    # a 20 ms UI tick still yields ~14 envelope frames.
    hop = 64
    mag, freqs, _ = stft(x, n_fft=256, hop=hop)
    if mag.shape[1] < 12:
        return 0.0
    fb = bark_filterbank(freqs, n_bands=24)
    pw = fb @ (mag ** 2)                         # [band, frame], power envelope
    env = np.sqrt(np.maximum(pw, 0.0))
    fs_env = RATE / float(hop)
    band_e = np.maximum(env.mean(axis=1), 1e-12)
    env = env - env.mean(axis=1, keepdims=True)
    nfr = env.shape[1]
    w = np.hanning(nfr)
    # 2/N normalisation makes the modulation spectrum a MODULATION DEPTH rather
    # than a length-dependent sum: without it a 2 s ambience always out-roughs a
    # 90 ms tick purely by having more frames.
    spec = np.abs(np.fft.rfft(env * w[None, :], axis=1)) * (2.0 / (nfr * w.mean()))
    fmod = np.fft.rfftfreq(nfr, 1.0 / fs_env)
    # Daniel & Weber weighting: a bandpass on modulation frequency, peak 70 Hz.
    g = np.exp(-((np.log2(np.maximum(fmod, 1.0) / 70.0)) ** 2) / (2 * 0.8 ** 2))
    g[fmod < 10.0] = 0.0                         # below 10 Hz is tremolo, not roughness
    # Power integration, not amplitude summation. With the 2/N normalisation
    # above, sum(spec^2) over a noise band is independent of the file's length;
    # a plain sum of |spec| is not, and an 85 s ambience would out-rough a 90 ms
    # tick purely by being long.
    mdepth = np.sqrt((spec ** 2 * g[None, :]).sum(axis=1))
    # Weight each band by its share of the total energy: a whisper of roughness
    # in a band nobody can hear is not roughness.
    share = band_e / float(band_e.sum())
    return float((mdepth / band_e * share).sum())


# ------------------------------------------------------------------- main ---

def describe(path: str) -> dict:
    """The full descriptor vector for one file. Deterministic."""
    x, rate = load(path)
    d = describe_signal(x, rate)
    d["path"] = path
    return d


def describe_signal(x: np.ndarray, rate: int = RATE) -> dict:
    """The same suite over an in-memory signal — this is the entry point the
       search harness scores candidates with, so a candidate and a shipped
       asset are measured by exactly the same instrument."""
    n = len(x)
    d: dict = {"rate": rate, "duration_s": n / float(rate)}

    # Level and dynamics. bs1770 is the project's meter; do not grow another.
    d["lufs_i"] = float(bs1770.integrated_lufs(x, rate))
    d["true_peak_dbtp"] = float(bs1770.true_peak_dbtp(x, rate))
    d["sample_peak_dbfs"] = float(bs1770.sample_peak_dbfs(x))
    rms = float(np.sqrt(np.mean(x ** 2))) if n else 0.0
    d["rms_dbfs"] = float(db(rms))

    # Envelope dynamic range: 95th vs 20th percentile of the frame RMS, in dB.
    # A sound whose loud and quiet moments are 6 dB apart is already squashed,
    # and no amount of mix work will give it back its punch.
    env, _ = envelope_rms(x, win_ms=10.0, hop_ms=2.0)
    e_db = db(env)
    d["env_range_db"] = float(np.percentile(e_db, 95) - np.percentile(e_db, 20))

    # --- crest, measured over the ACTIVE region ---------------------------
    #
    # This used to be peak over the RMS of the WHOLE file, and the search
    # harness promptly found the hole in it: silence contributes zero to the
    # denominator, so padding a sound with a gap raises its crest for free. The
    # impact_heavy shortlist did exactly that — several winners had a ~250 ms
    # hole between the break and the debris and scored well for it. Nothing
    # about that hole is a property of a good impact; it was a property of the
    # instrument.
    #
    # So the denominator is now the RMS of the SAMPLES inside the active
    # region: every window whose RMS is within 40 dB of the envelope peak,
    # expanded back to the samples it covers. -40 dB is the conventional "the
    # tail has ended" floor and is well below anything audible under a game
    # mix. `silence_frac` reports what was excluded, so a gap becomes a number
    # a class objective can penalise instead of a free gain.
    #
    # The mask is expanded to SAMPLES rather than averaged over frames on
    # purpose. The envelope hops 2 ms with a 10 ms window, so a sample near
    # either edge of the file appears in fewer frames than one in the middle —
    # averaging frame powers therefore under-weights the first 10 ms, which on
    # an impact is precisely the transient. That bias measured +0.9 dB of free
    # crest on the footstep set, i.e. it would have replaced one measurement
    # artefact with another. Masking in the sample domain has no such weighting.
    # For a sound with no dead air the mask covers everything and the definition
    # collapses to the textbook one, which is why the sine selftest still reads
    # 3.01 dB.
    active_f = env >= (env.max() * 10.0 ** (-40.0 / 20.0))
    win = max(int(RATE * 10.0 / 1000.0), 4)
    hop = max(int(RATE * 2.0 / 1000.0), 1)
    mask = np.zeros(n, dtype=bool)
    if n and active_f.any():
        starts = np.nonzero(active_f)[0] * hop
        edges = np.zeros(n + 1, dtype=np.int32)
        np.add.at(edges, np.minimum(starts, n), 1)
        np.add.at(edges, np.minimum(starts + win, n), -1)
        mask = np.cumsum(edges)[:n] > 0
    d["silence_frac"] = float(1.0 - mask.mean()) if n else 0.0
    rms_active = float(np.sqrt(np.mean(x[mask] ** 2))) if mask.any() else rms
    d["rms_active_dbfs"] = float(db(rms_active))
    d["crest_db"] = float(d["sample_peak_dbfs"] - d["rms_active_dbfs"])

    d.update(_attack_decay(x))
    d.update(_spectral(x))

    be = band_energies(x)
    for k, v in be.items():
        d["band_" + k] = float(v)
    # The two headline balance numbers, in dB relative to total, because a
    # fraction of 0.004 does not communicate and -24 dB does.
    d["sub_db"] = float(10.0 * np.log10(max(be["sub"], 1e-9)))
    d["low_db"] = float(10.0 * np.log10(max(be["low"], 1e-9)))
    d["weight_db"] = float(10.0 * np.log10(max(be["sub"] + be["low"], 1e-9)))

    n_prime, z = _specific_loudness(x)
    d["sharpness_acum"] = _sharpness(n_prime, z)
    d["loudness_sone"] = float(n_prime.sum() * (24.0 / len(n_prime)))
    d["roughness"] = _roughness(x)

    return d


# The subset the health report, the clustering and the objective functions all
# speak in. Ordered; `analyze.py` writes CSV columns in this order.
FEATURES: list[str] = [
    "duration_s", "lufs_i", "true_peak_dbtp", "crest_db", "silence_frac",
    "env_range_db",
    "attack_ms", "attack_slope_db_per_ms", "peak_time_ms", "decay_t60_ms",
    "decay_linearity",
    "sustain_frac", "centroid_hz", "centroid_start_hz", "centroid_end_hz",
    "centroid_drop_oct", "centroid_drift_oct", "centroid_drift_oct_per_s",
    "centroid_slope_oct_per_s",
    "flux", "spread_oct", "bw20_oct", "rolloff85_hz", "flatness", "hnr_db",
    "band_sub", "band_low", "band_lowmid", "band_mid", "band_highmid",
    "band_high", "band_top", "sub_db", "low_db", "weight_db",
    "sharpness_acum", "loudness_sone", "roughness",
]

# The vector used for SIMILARITY (the clustering that finds "everything sounds
# the same"). Deliberately not the full set: level descriptors are excluded,
# because two sounds at different loudness that are otherwise identical ARE the
# same sound, and the whole library is loudness-normalised anyway.
SIMILARITY_FEATURES: list[str] = [
    "duration_s", "crest_db", "env_range_db", "attack_ms",
    "attack_slope_db_per_ms", "decay_t60_ms", "sustain_frac",
    "centroid_hz", "centroid_drop_oct", "centroid_drift_oct_per_s", "flux",
    "spread_oct", "bw20_oct", "flatness", "hnr_db",
    "band_sub", "band_low", "band_lowmid", "band_mid", "band_highmid",
    "band_high", "sharpness_acum", "roughness",
]

# Features that are more meaningful on a log axis (durations, times, ratios that
# span decades). Standardisation uses log1p on these.
LOG_FEATURES = {"duration_s", "attack_ms", "decay_t60_ms", "centroid_hz",
                "centroid_start_hz", "centroid_end_hz", "rolloff85_hz",
                "loudness_sone", "roughness"}


# ---------------------------------------------------------------- selftest --
#
# Reproducibility is not correctness. `analyze.py --verify-reproducible` proves
# the suite gives the same answer twice; this proves it gives the RIGHT answer,
# by measuring signals whose properties are known by construction. Every case
# below is a descriptor's definition restated as a signal.

def _selftest() -> int:
    fails = []

    def check(name, cond, detail):
        mark = "ok  " if cond else "FAIL"
        print("  [%s] %-34s %s" % (mark, name, detail))
        if not cond:
            fails.append(name)

    n = RATE // 2
    t = np.arange(n) / RATE

    # 1. A pure tone: maximally pitched, minimally flat, no movement.
    tone = np.sin(2 * np.pi * 440.0 * t) * 0.5
    d = describe_signal(tone)
    check("pure tone -> high HNR", d["hnr_db"] > 15, "hnr %.1f dB" % d["hnr_db"])
    check("pure tone -> low flatness", d["flatness"] < 0.05,
          "flatness %.4f" % d["flatness"])
    check("pure tone -> narrow band", d["bw20_oct"] < 1.0,
          "bw20 %.2f oct" % d["bw20_oct"])
    check("pure tone -> centroid at 440", abs(d["centroid_hz"] - 440.0) < 25.0,
          "centroid %.0f Hz" % d["centroid_hz"])
    check("pure tone -> no flux", d["flux"] < 0.01, "flux %.4f" % d["flux"])

    # 2. White noise: the opposite of all of that.
    wn = np.random.default_rng(0).normal(0, 0.2, n)
    d = describe_signal(wn)
    check("white noise -> high flatness", d["flatness"] > 0.5,
          "flatness %.3f" % d["flatness"])
    check("white noise -> low HNR", d["hnr_db"] < 5.0, "hnr %.1f dB" % d["hnr_db"])
    check("white noise -> wide band", d["bw20_oct"] > 6.0,
          "bw20 %.2f oct" % d["bw20_oct"])

    # 3. Attack time: an exact 20 ms linear ramp into a held tone.
    a = frames_ms(20.0)
    ramp = np.concatenate([np.linspace(0, 1, a), np.ones(n - a)])
    d = describe_signal(np.sin(2 * np.pi * 800 * t) * ramp)
    # 10 % -> 90 % of a linear ramp is 80 % of its length.
    check("20 ms ramp -> attack ~16 ms", 13.0 < d["attack_ms"] < 19.0,
          "attack %.2f ms (expect 16)" % d["attack_ms"])

    click = np.zeros(n)
    click[100:130] = np.random.default_rng(1).normal(0, 1, 30)
    d = describe_signal(click)
    check("30-sample click -> attack at floor", d["attack_ms"] <= 1.0,
          "attack %.2f ms" % d["attack_ms"])

    # 4. Decay: an exponential with a known time constant. A decay to 1/e in
    #    tau seconds is -60 dB in 60/8.686 * tau = 6.91 * tau.
    tau = 0.10
    d = describe_signal(np.sin(2 * np.pi * 300 * t) * np.exp(-t / tau))
    want = 6.908 * tau * 1000.0
    check("exp decay tau=100ms -> T60", abs(d["decay_t60_ms"] - want) < 0.12 * want,
          "t60 %.0f ms (expect %.0f)" % (d["decay_t60_ms"], want))
    check("exp decay -> linearity ~1", d["decay_linearity"] > 0.97,
          "R^2 %.3f" % d["decay_linearity"])

    # 5. The headline descriptor. Two partials with different decays: the high
    #    one dies first, so the centroid MUST fall. This is the exact structure
    #    the audit says the library is missing, so if this case is wrong the
    #    whole report is wrong.
    lo = np.sin(2 * np.pi * 200 * t) * np.exp(-t / 0.30)
    hi = np.sin(2 * np.pi * 3200 * t) * np.exp(-t / 0.02)
    d = describe_signal(lo + hi)
    check("bright partial dies first -> centroid falls", d["centroid_drop_oct"] > 1.5,
          "drop %.2f oct" % d["centroid_drop_oct"])
    d2 = describe_signal(np.sin(2 * np.pi * 200 * t) * np.exp(-t / 0.3)
                         + np.sin(2 * np.pi * 3200 * t) * np.exp(-t / 0.3))
    check("same decays -> centroid static", abs(d2["centroid_drop_oct"]) < 0.25,
          "drop %.2f oct" % d2["centroid_drop_oct"])

    # 6. Crest factor: a sine is 3.01 dB peak-to-RMS, by definition. A sine has
    #    no dead air, so the active-region denominator equals the whole-file one
    #    and the textbook number must survive the change.
    d = describe_signal(np.sin(2 * np.pi * 500 * t) * 0.7)
    check("sine -> crest 3.01 dB", abs(d["crest_db"] - 3.01) < 0.15,
          "crest %.2f dB" % d["crest_db"])
    check("continuous sine -> no silence", d["silence_frac"] < 0.02,
          "silence_frac %.3f" % d["silence_frac"])

    # 6b. THE FIX. The same sine with a 250 ms hole punched in the middle — the
    #     exact cheat the impact_heavy search found. Crest must not move, and
    #     the hole must be reported.
    holed = (np.sin(2 * np.pi * 500 * t) * 0.7).copy()
    h0, h1 = frames_ms(80.0), frames_ms(330.0)
    holed[h0:h1] = 0.0
    dh = describe_signal(holed)
    # Halving the sounding time doubled the old whole-file crest: +3.01 dB, free.
    # What is left is the 10 ms windows that straddle the two edges of the hole
    # and are half-empty; that residual is bounded by the window length and is
    # an order of magnitude below the cheat it replaces.
    check("silence buys no crest", abs(dh["crest_db"] - d["crest_db"]) < 0.4,
          "%.2f dB holed vs %.2f dB solid (whole-file RMS gave +3.01 free)"
          % (dh["crest_db"], d["crest_db"]))
    check("the hole is reported", 0.40 < dh["silence_frac"] < 0.60,
          "silence_frac %.3f (250 of 500 ms)" % dh["silence_frac"])

    # 7. Band split: energy placed in one band should be reported in that band.
    for band, hz in (("sub", 50.0), ("low", 150.0), ("mid", 1500.0),
                     ("high", 8000.0)):
        d = describe_signal(np.sin(2 * np.pi * hz * t))
        check("%.0f Hz tone lands in '%s'" % (hz, band), d["band_" + band] > 0.9,
              "band_%s %.3f" % (band, d["band_" + band]))

    # 8. Roughness: a 1 kHz carrier amplitude-modulated at 70 Hz is the textbook
    #    maximum-roughness stimulus; the same carrier unmodulated is the floor.
    car = np.sin(2 * np.pi * 1000 * t)
    rough = describe_signal(car * (1 + 0.9 * np.sin(2 * np.pi * 70 * t)))["roughness"]
    smooth = describe_signal(car)["roughness"]
    check("70 Hz AM is rougher than steady tone", rough > 4.0 * max(smooth, 1e-6),
          "%.3f vs %.3f" % (rough, smooth))
    slow = describe_signal(car * (1 + 0.9 * np.sin(2 * np.pi * 3 * t)))["roughness"]
    check("3 Hz AM is not roughness (it is tremolo)", slow < 0.5 * rough,
          "%.3f vs %.3f" % (slow, rough))

    # 9. Sharpness: monotone in carrier frequency, by construction of g(z).
    s_low = describe_signal(np.sin(2 * np.pi * 400 * t))["sharpness_acum"]
    s_high = describe_signal(np.sin(2 * np.pi * 6000 * t))["sharpness_acum"]
    check("sharpness rises with frequency", s_high > 2.0 * s_low,
          "%.2f acum @400 Hz vs %.2f @6 kHz" % (s_low, s_high))

    # 10. Loudness agreement with the project meter, on a known case: BS.1770
    #     of a full-scale sine is about -3.0 LUFS mono.
    d = describe_signal(np.sin(2 * np.pi * 1000 * t))
    check("1 kHz FS sine -> ~ -3 LUFS (mono)", abs(d["lufs_i"] + 3.0) < 0.7,
          "%.2f LUFS" % d["lufs_i"])

    print()
    if fails:
        print("descriptors --selftest: %d FAILURES: %s" % (len(fails), ", ".join(fails)))
        return 1
    print("descriptors --selftest: all cases pass")
    return 0


def frames_ms(ms: float) -> int:
    return int(RATE * ms / 1000.0)


def feature_matrix(rows: list[dict], features: list[str]) -> np.ndarray:
    m = np.zeros((len(rows), len(features)))
    for i, r in enumerate(rows):
        for j, f in enumerate(features):
            v = float(r.get(f, 0.0))
            if f in LOG_FEATURES:
                v = float(np.log1p(max(v, 0.0)))
            m[i, j] = v
    return m


def standardise(m: np.ndarray) -> np.ndarray:
    mu = m.mean(axis=0)
    sd = m.std(axis=0)
    sd[sd < 1e-9] = 1.0
    return (m - mu) / sd


if __name__ == "__main__":
    import sys as _sys
    if "--selftest" in _sys.argv:
        _sys.exit(_selftest())
    print(__doc__ or "run with --selftest")
