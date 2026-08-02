#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — ITU-R BS.1770-4 loudness meter (K-weighted, gated).
#
#   python3 tools/audio/bs1770.py --selftest
#   python3 tools/audio/bs1770.py assets/audio/**/*.wav
#
# WHY THIS FILE EXISTS
# --------------------
# The brief for the MOTHER-voice R&D said to reuse "the existing BS.1770 meter
# in tools/audio". There isn't one — `tools/audio/` did not exist and nothing in
# the repo (Python or GDScript) implements a loudness meter; the only prior
# normalisation in the tree is `tools/make_sfx.py`'s PEAK normalise, which is a
# different and much cruder thing. Rather than invent a number and call it LUFS,
# this is a from-scratch, spec-faithful implementation with a self-test against
# the published EBU Tech 3341 conformance cases. It is written to be the shared
# meter the rest of the audio pipeline can import:
#
#     from bs1770 import integrated_lufs, normalise_to
#
# NOTHING ELSE IN THE REPO IS MODIFIED BY THIS FILE.
#
# THE ALGORITHM (BS.1770-4 §2 + Annex 1)
# --------------------------------------
#   1. K-weighting: two cascaded biquads per channel —
#      a. a "head" high-shelf (+~4 dB above ~2 kHz), modelling the acoustic
#         effect of a head in a diffuse field;
#      b. an RLB high-pass (~38 Hz), which is what stops a rumble bed from
#         reading as loudness.
#      The published coefficients are 48 kHz only. This module DERIVES them for
#      any rate by bilinear transform of the analogue prototypes (the f0/Q/gain
#      triples in Annex 1), and asserts the 48 kHz derivation reproduces the
#      published table to 1e-10 in `--selftest`.
#   2. Mean square of each weighted channel over 400 ms blocks at 75 % overlap
#      (100 ms hop). Channel weights G: 1.0 for L/R/C, 1.41 for surrounds, and
#      the LFE is never counted.
#   3. Block loudness  l_j = -0.691 + 10*log10( sum_i G_i * z_ij ).
#   4. Two gates: an ABSOLUTE gate at -70 LUFS, then a RELATIVE gate 10 LU below
#      the mean of everything that survived the absolute gate. The integrated
#      loudness is the -0.691 + 10*log10 of the mean power over the survivors.
#      The relative gate is the whole point of the standard: it stops the silence
#      between MOTHER's phrases from dragging her measured level down and making
#      the normaliser shout.
#
# CHANNEL CONVENTION FOR THIS REPO
# --------------------------------
# Every asset in `assets/audio/` is MONO, because every one of them is played
# through an AudioStreamPlayer3D and spatialised at runtime. A mono file is
# metered here as ONE channel at G = 1.0, which reads 3.01 LU quieter than the
# same material duplicated into a stereo pair. That is the correct reading for a
# spatialised point source; `--dual-mono` is provided for comparing against
# consumer meters that silently upmix.
#
# TRUE PEAK
# ---------
# `true_peak_dbtp` oversamples 4x with a windowed-sinc polyphase interpolator
# (BS.1770-4 Annex 2 asks for >= 4x at 48 kHz) so inter-sample peaks in the
# post-cassette-saturation material are actually visible. Sample peak alone lies
# by up to ~1 dB on this kind of content.
#
# Stdlib + numpy. No scipy (not installed on this machine), no soundfile
# dependency for the core maths — `read_wav`/`write_wav` are hand-rolled so the
# meter can be imported by anything.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import math
import os
import struct
import sys
import wave

import numpy as np

# --- BS.1770-4 constants ----------------------------------------------------

BLOCK_S = 0.400          # gating block length
OVERLAP = 0.75           # 75 % overlap -> 100 ms hop
ABS_GATE_LUFS = -70.0    # absolute gate
REL_GATE_LU = -10.0      # relative gate, below the ungated mean
OFFSET_DB = -0.691       # the calibration constant in the loudness equation

#: Per-channel weights G_i. Index by the channel-layout names below.
CHANNEL_GAIN = {"L": 1.0, "R": 1.0, "C": 1.0, "Ls": 1.41, "Rs": 1.41, "LFE": 0.0}

#: Analogue prototypes for the two K-weighting stages (BS.1770-4 Annex 1).
SHELF_F0 = 1681.974450955533
SHELF_G_DB = 3.999843853973347
SHELF_Q = 0.7071752369554196
HPF_F0 = 38.13547087602444
HPF_Q = 0.5003270373238773

#: The published 48 kHz table, kept only so `--selftest` can prove the
#: derivation below is right. Never used directly.
PUBLISHED_48K = (
    ([1.53512485958697, -2.69169618940638, 1.19839281085285],
     [1.0, -1.69065929318241, 0.73248077421585]),
    ([1.0, -2.0, 1.0],
     [1.0, -1.99004745483398, 0.99007225036621]),
)


# --- filter design ----------------------------------------------------------

def _shelf_coeffs(rate: float) -> tuple[list[float], list[float]]:
    """Stage 1 of K-weighting: the high-shelf 'head' filter.

    Bilinear transform of the analogue shelf, pre-warped at f0. `Vb`'s odd
    exponent (0.4996667741545416) is not a typo — it is the value the standard
    uses to land the shelf's midpoint where the reference implementation puts
    it, and rounding it to 0.5 shifts the whole curve enough to fail the EBU
    conformance cases by ~0.05 LU."""
    k = math.tan(math.pi * SHELF_F0 / rate)
    vh = 10.0 ** (SHELF_G_DB / 20.0)
    vb = vh ** 0.4996667741545416
    a0 = 1.0 + k / SHELF_Q + k * k
    b = [(vh + vb * k / SHELF_Q + k * k) / a0,
         2.0 * (k * k - vh) / a0,
         (vh - vb * k / SHELF_Q + k * k) / a0]
    a = [1.0,
         2.0 * (k * k - 1.0) / a0,
         (1.0 - k / SHELF_Q + k * k) / a0]
    return b, a


def _hpf_coeffs(rate: float) -> tuple[list[float], list[float]]:
    """Stage 2 of K-weighting: the RLB high-pass. Numerator is exactly [1,-2,1]
       — a double zero at DC — at every sample rate; only the poles move."""
    k = math.tan(math.pi * HPF_F0 / rate)
    a0 = 1.0 + k / HPF_Q + k * k
    a = [1.0,
         2.0 * (k * k - 1.0) / a0,
         (1.0 - k / HPF_Q + k * k) / a0]
    return [1.0, -2.0, 1.0], a


def biquad(x: np.ndarray, b: list[float], a: list[float]) -> np.ndarray:
    """Direct-form I biquad, exact sample-by-sample recursion.

    Deliberately NOT an FFT approximation: this is the measurement path, and a
    meter that is 'about right' is worse than no meter because you trust it.
    Measured at ~0.02 s per second of 48 kHz audio, which is free at this scale.
    """
    b0, b1, b2 = b
    _, a1, a2 = a
    y = np.empty_like(x, dtype=np.float64)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(x.shape[0]):
        xi = float(x[i])
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, xi
        y2, y1 = y1, yi
        y[i] = yi
    return y


def k_weight(x: np.ndarray, rate: int) -> np.ndarray:
    """Apply both K-weighting stages to one channel."""
    b, a = _shelf_coeffs(rate)
    y = biquad(x, b, a)
    b, a = _hpf_coeffs(rate)
    return biquad(y, b, a)


# --- the meter --------------------------------------------------------------

def _channels(samples: np.ndarray) -> np.ndarray:
    """Coerce to (n_channels, n_samples) float64."""
    a = np.asarray(samples, dtype=np.float64)
    if a.ndim == 1:
        return a[None, :]
    if a.shape[0] > a.shape[1]:      # (n, ch) -> (ch, n)
        a = a.T
    return a


def block_powers(samples: np.ndarray, rate: int,
                 gains: list[float] | None = None) -> np.ndarray:
    """Gated-block weighted power  sum_i G_i * z_ij , one value per 400 ms
       block at 100 ms hop. Returns an empty array for material shorter than
       one block (which is most one-shot SFX — see `integrated_lufs`)."""
    ch = _channels(samples)
    n_ch, n = ch.shape
    if gains is None:
        gains = [1.0] * n_ch
    block = int(round(BLOCK_S * rate))
    hop = int(round(BLOCK_S * (1.0 - OVERLAP) * rate))
    if n < block:
        return np.zeros(0)
    starts = np.arange(0, n - block + 1, hop)
    total = np.zeros(starts.shape[0])
    for c in range(n_ch):
        if gains[c] == 0.0:
            continue
        sq = k_weight(ch[c], rate) ** 2
        csum = np.concatenate(([0.0], np.cumsum(sq)))
        z = (csum[starts + block] - csum[starts]) / block
        total += gains[c] * z
    return total


def integrated_lufs(samples: np.ndarray, rate: int,
                    gains: list[float] | None = None) -> float:
    """Gated integrated loudness in LUFS. `-inf` for digital silence.

    Short-material fallback: BS.1770's gating is undefined below one 400 ms
    block, so anything shorter is measured as a single ungated block over its
    whole length. That is exactly the un-gated mean-square loudness, which is
    the right answer for a 90 ms tick and is flagged by `measure()` so a caller
    can tell the two regimes apart."""
    ch = _channels(samples)
    if gains is None:
        gains = [1.0] * ch.shape[0]
    n = ch.shape[1]
    if int(round(BLOCK_S * rate)) > n:
        total = 0.0
        for c in range(ch.shape[0]):
            if gains[c] == 0.0:
                continue
            total += gains[c] * float(np.mean(k_weight(ch[c], rate) ** 2))
        return -math.inf if total <= 0.0 else OFFSET_DB + 10.0 * math.log10(total)

    z = block_powers(ch, rate, gains)
    if z.size == 0 or not np.any(z > 0.0):
        return -math.inf

    with np.errstate(divide="ignore"):
        loud = OFFSET_DB + 10.0 * np.log10(np.where(z > 0.0, z, 1e-300))

    keep = loud > ABS_GATE_LUFS                      # absolute gate
    if not np.any(keep):
        return -math.inf
    rel = OFFSET_DB + 10.0 * math.log10(float(np.mean(z[keep]))) + REL_GATE_LU
    keep &= loud > rel                               # relative gate
    if not np.any(keep):
        return -math.inf
    return OFFSET_DB + 10.0 * math.log10(float(np.mean(z[keep])))


def loudness_range_lu(samples: np.ndarray, rate: int) -> float:
    """EBU R128 Loudness Range (LRA), abbreviated: 3 s blocks at 1 s hop, the
       absolute gate at -70, a relative gate at -20 LU, then the 10th-to-95th
       percentile spread. Reported as a texture statistic — a whisper bed with
       an LRA of 2 LU is a drone, one with 12 LU is breathing."""
    ch = _channels(samples)
    rate_i = int(rate)
    block = 3 * rate_i
    hop = rate_i
    n = ch.shape[1]
    if n < block:
        return 0.0
    weighted = [k_weight(ch[c], rate_i) ** 2 for c in range(ch.shape[0])]
    starts = np.arange(0, n - block + 1, hop)
    z = np.zeros(starts.shape[0])
    for sq in weighted:
        csum = np.concatenate(([0.0], np.cumsum(sq)))
        z += (csum[starts + block] - csum[starts]) / block
    z = z[z > 0.0]
    if z.size < 2:
        return 0.0
    loud = OFFSET_DB + 10.0 * np.log10(z)
    keep = loud > ABS_GATE_LUFS
    if not np.any(keep):
        return 0.0
    rel = OFFSET_DB + 10.0 * math.log10(float(np.mean(z[keep]))) - 20.0
    sel = loud[keep & (loud > rel)]
    if sel.size < 2:
        return 0.0
    return float(np.percentile(sel, 95.0) - np.percentile(sel, 10.0))


# --- true peak --------------------------------------------------------------

def _polyphase_taps(factor: int, taps_per_phase: int = 24) -> np.ndarray:
    """Windowed-sinc interpolator, Blackman-windowed, one row per output phase."""
    half = taps_per_phase // 2
    idx = np.arange(-half, half) + 0.5
    rows = []
    for p in range(factor):
        t = idx + p / factor
        h = np.sinc(t)
        w = np.blackman(t.shape[0])
        h = h * w
        rows.append(h / np.sum(h))
    return np.array(rows)


def true_peak_dbtp(samples: np.ndarray, rate: int, factor: int = 4) -> float:
    """Peak of the 4x-oversampled signal, in dBTP. `-inf` for silence."""
    ch = _channels(samples)
    taps = _polyphase_taps(factor)
    peak = 0.0
    for c in range(ch.shape[0]):
        x = ch[c]
        peak = max(peak, float(np.max(np.abs(x))) if x.size else 0.0)
        for row in taps:
            y = np.convolve(x, row, mode="same")
            if y.size:
                peak = max(peak, float(np.max(np.abs(y))))
    return -math.inf if peak <= 0.0 else 20.0 * math.log10(peak)


def sample_peak_dbfs(samples: np.ndarray) -> float:
    p = float(np.max(np.abs(np.asarray(samples, dtype=np.float64)))) if np.size(samples) else 0.0
    return -math.inf if p <= 0.0 else 20.0 * math.log10(p)


# --- the thing callers actually want ---------------------------------------

def measure(samples: np.ndarray, rate: int, dual_mono: bool = False) -> dict:
    """Full report for one buffer."""
    ch = _channels(samples)
    if dual_mono and ch.shape[0] == 1:
        ch = np.vstack([ch, ch])
    n = ch.shape[1]
    return {
        "lufs": integrated_lufs(ch, rate),
        "lra": loudness_range_lu(ch, rate),
        "true_peak_dbtp": true_peak_dbtp(ch, rate),
        "sample_peak_dbfs": sample_peak_dbfs(ch),
        "seconds": n / float(rate),
        "channels": int(ch.shape[0]),
        "gated": bool(n >= int(round(BLOCK_S * rate))),
    }


def normalise_to(samples: np.ndarray, rate: int, target_lufs: float,
                 ceiling_dbtp: float = -1.0) -> tuple[np.ndarray, dict]:
    """Scale `samples` to `target_lufs`, then back the gain off if that would
       push true peak above `ceiling_dbtp`.

       Returns `(scaled, report)`; `report["limited_db"]` is how much loudness
       had to be surrendered to the ceiling, which is the number you want in a
       build log — if it is ever large the source has a crest-factor problem
       that a gain stage cannot fix."""
    x = np.asarray(samples, dtype=np.float64)
    before = measure(x, rate)
    if not math.isfinite(before["lufs"]):
        return x, {"before": before, "after": before, "gain_db": 0.0, "limited_db": 0.0}

    gain_db = target_lufs - before["lufs"]
    tp_after = before["true_peak_dbtp"] + gain_db
    limited = 0.0
    if tp_after > ceiling_dbtp:
        limited = tp_after - ceiling_dbtp
        gain_db -= limited
    y = x * (10.0 ** (gain_db / 20.0))
    return y, {"before": before, "after": measure(y, rate),
               "gain_db": gain_db, "limited_db": limited}


# --- wav i/o (hand-rolled; keeps this module dependency-light) --------------

def read_wav(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path, "rb") as fh:
        n_ch, width, rate, n = fh.getnchannels(), fh.getsampwidth(), fh.getframerate(), fh.getnframes()
        raw = fh.readframes(n)
    if width == 2:
        a = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    elif width == 3:
        # 24-bit packed little-endian, sign-extended into int32. This is the
        # format `write_wav` produces by default, so the module has to be able
        # to read its own output — it could not, until the build verified it.
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        q = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        q = np.where(q >= (1 << 23), q - (1 << 24), q)
        a = q.astype(np.float64) / 8388608.0
    elif width == 4:
        a = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648.0
    elif width == 1:
        a = (np.frombuffer(raw, dtype="u1").astype(np.float64) - 128.0) / 128.0
    else:
        raise ValueError("unsupported sample width %d in %s" % (width, path))
    if n_ch > 1:
        a = a.reshape(-1, n_ch).T
    return a, rate


def write_wav(path: str, samples: np.ndarray, rate: int, width: int = 3) -> None:
    """24-bit by default — these are R&D masters that get re-encoded, and
       16-bit dither noise stacked under a whisper bed is audible."""
    a = _channels(samples)
    n_ch = a.shape[0]
    inter = a.T.reshape(-1)
    inter = np.clip(inter, -1.0, 1.0 - 1.0 / (1 << 23))
    if width == 2:
        raw = (inter * 32767.0).astype("<i2").tobytes()
    elif width == 3:
        q = np.round(inter * 8388607.0).astype(np.int32)
        raw = np.stack([(q & 0xFF), ((q >> 8) & 0xFF), ((q >> 16) & 0xFF)],
                       axis=1).astype(np.uint8).tobytes()
    else:
        raise ValueError("unsupported width %d" % width)
    with wave.open(path, "wb") as fh:
        fh.setnchannels(n_ch)
        fh.setsampwidth(width)
        fh.setframerate(rate)
        fh.writeframes(raw)


# --- conformance ------------------------------------------------------------

def _selftest() -> int:
    ok = True

    def check(label: str, got: float, want: float, tol: float) -> None:
        nonlocal ok
        good = abs(got - want) <= tol
        ok &= good
        print("  [%s] %-52s got %+9.4f  want %+9.4f  (tol %.3f)"
              % ("PASS" if good else "FAIL", label, got, want, tol))

    print("BS.1770-4 self-test")
    print("- derived 48 kHz coefficients vs published table")
    for (db, da), (pb, pa) in zip((_shelf_coeffs(48000), _hpf_coeffs(48000)), PUBLISHED_48K):
        for got, want in zip(db + da, pb + pa):
            ok &= abs(got - want) < 1e-10
    print("  [%s] derivation reproduces BS.1770-4 Table 1 to 1e-10"
          % ("PASS" if ok else "FAIL"))

    rate = 48000
    t = np.arange(rate * 20) / rate

    # EBU Tech 3341 case 1: stereo 1 kHz sine of AMPLITUDE -23 dBFS -> -23.0
    # LUFS. Note "amplitude", not RMS — that is the standard's own convention
    # for these vectors, and it is what makes the case such a tidy check: the
    # sine's -3.01 dB crest and the +3.01 dB of summing two channels cancel,
    # and the -0.691 offset is cancelled by the K-weighting's +0.69 dB of gain
    # at exactly 1 kHz. Any error anywhere in the chain shows up immediately.
    amp = 10.0 ** (-23.0 / 20.0)
    sine = amp * np.sin(2.0 * math.pi * 1000.0 * t)
    check("3341-1  stereo 1 kHz sine, amplitude -23 dBFS",
          integrated_lufs(np.vstack([sine, sine]), rate), -23.0, 0.1)

    # Case 2: the same at -33 dBFS. Proves the meter is linear across the range
    # the gates operate in.
    s2 = 10.0 ** (-33.0 / 20.0) * np.sin(2.0 * math.pi * 1000.0 * t)
    check("3341-2  stereo 1 kHz sine, amplitude -33 dBFS",
          integrated_lufs(np.vstack([s2, s2]), rate), -33.0, 0.1)

    # Mono convention: one channel at G=1.0 reads exactly 3.01 LU below the
    # dual-mono pair. This is the assumption every asset in this repo is
    # normalised under, so it is worth asserting rather than believing.
    check("mono single channel is 3.01 LU below dual-mono",
          integrated_lufs(np.vstack([sine, sine]), rate) - integrated_lufs(sine, rate),
          10.0 * math.log10(2.0), 0.01)

    # The relative gate: 20 s of tone at -23, then 20 s of near-silence at -70.
    # An UNgated meter reads about -26 (the mean power halves); the gated
    # answer must stay at -23. This is the behaviour MOTHER's speech needs —
    # long silences between phrases must not inflate her playback gain.
    quiet = 10.0 ** (-70.0 / 20.0) * np.sin(2.0 * math.pi * 1000.0 * t)
    gated = np.concatenate([sine, quiet])
    check("relative gate ignores inter-phrase silence",
          integrated_lufs(np.vstack([gated, gated]), rate), -23.0, 0.3)
    ungated = OFFSET_DB + 10.0 * math.log10(
        float(np.mean(block_powers(np.vstack([gated, gated]), rate))))
    check("  ...and an ungated mean really would have been wrong",
          ungated, -26.0, 0.5)

    # True peak: a high sine placed so its crests fall between sample instants.
    # The 4x oversampled peak must exceed the sample peak, and by a sane amount
    # (a bug that returns garbage typically overshoots by many dB).
    tt = np.arange(48000) / 48000.0
    inter_sample = 0.99 * np.sin(2.0 * math.pi * 11997.0 * tt + 0.37)
    tp = true_peak_dbtp(inter_sample, 48000)
    sp = sample_peak_dbfs(inter_sample)
    check("true peak exceeds sample peak on inter-sample content, sanely",
          tp - sp, 0.35, 0.35)

    # normalise_to round-trip.
    noisy = np.random.default_rng(7).normal(0.0, 0.05, rate * 5)
    y, rep = normalise_to(noisy, rate, -20.0, ceiling_dbtp=-1.0)
    check("normalise_to lands on target", rep["after"]["lufs"], -20.0, 0.05)

    # WAV round-trip at 24 bit. Asserted because the module writes 24-bit by
    # default, and a writer whose own reader chokes on its output is a trap
    # that only shows up the first time someone re-measures a rendered asset.
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as fh:
        tmp = fh.name
    try:
        write_wav(tmp, y, rate, width=3)
        back, br = read_wav(tmp)
        ok_rate = br == rate
        ok &= ok_rate
        print("  [%s] 24-bit wav round-trip preserves sample rate"
              % ("PASS" if ok_rate else "FAIL"))
        check("24-bit wav round-trip preserves loudness",
              integrated_lufs(back, br), rep["after"]["lufs"], 0.02)
    finally:
        os.unlink(tmp)

    print("SELFTEST %s" % ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="BS.1770-4 loudness meter")
    ap.add_argument("files", nargs="*", help="wav files to measure")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--dual-mono", action="store_true",
                    help="measure mono files as a duplicated stereo pair")
    args = ap.parse_args()
    if args.selftest or not args.files:
        return _selftest()
    print("%-46s %9s %7s %9s %8s" % ("file", "LUFS", "LRA", "dBTP", "len"))
    for path in args.files:
        x, rate = read_wav(path)
        m = measure(x, rate, dual_mono=args.dual_mono)
        print("%-46s %9.2f %7.2f %9.2f %7.2fs"
              % (path.split("/")[-1], m["lufs"], m["lra"], m["true_peak_dbtp"], m["seconds"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
