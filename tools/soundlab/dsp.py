#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — SOUND LAB: signal primitives.
#
# The shared floor everything else in tools/soundlab/ stands on: loading, an
# STFT, a Bark filterbank and a handful of envelope helpers. numpy only, on
# purpose — scipy is not installed on the build machine and every routine here
# is a dozen lines of FFT anyway.
#
# NOTHING IN THIS DIRECTORY WRITES TO assets/ OR src/. The Sound Lab measures,
# ranks and proposes; adopting a proposal is a separate, human decision made by
# whoever owns the asset.
# ---------------------------------------------------------------------------
from __future__ import annotations

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# The BS.1770 meter already in the tree is the loudness authority for the whole
# project (tools/make_sfx.py and the MOTHER voice pipeline both use it). Import
# it read-only rather than growing a second, disagreeing meter.
sys.path.insert(0, os.path.join(REPO, "tools", "audio"))
import bs1770  # noqa: E402

RATE = 48000


# ------------------------------------------------------------------ loading --

def load(path: str, target_rate: int = RATE) -> tuple[np.ndarray, int]:
    """Read any file soundfile can open, mono-summed, float64 in [-1, 1].

       Every shipped asset is mono at 48 kHz (see bs1770.py's channel note), so
       the downmix and the resample below are guards, not a pipeline stage: if
       either ever fires, something upstream changed and the audit says so."""
    import soundfile as sf
    x, rate = sf.read(path, always_2d=True, dtype="float64")
    x = x.mean(axis=1)
    if rate != target_rate:
        x = resample_linear(x, rate, target_rate)
        rate = target_rate
    return np.ascontiguousarray(x), rate


def resample_linear(x: np.ndarray, src: int, dst: int) -> np.ndarray:
    """Linear resample. Only ever used as a guard for an off-rate asset; the
       descriptor suite would rather report a slightly soft top octave than
       refuse to measure a file at all."""
    n = int(round(len(x) * dst / float(src)))
    t = np.linspace(0.0, len(x) - 1.0, n)
    return np.interp(t, np.arange(len(x), dtype=float), x)


# --------------------------------------------------------------------- STFT --

def stft(x: np.ndarray, n_fft: int = 2048, hop: int = 256,
         window: str = "hann") -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Magnitude STFT.

       Returns (mag[freq, frame], freqs_hz, times_s).

       The default here is 2048 (43 ms, 23 Hz bins) but the descriptor suite
       calls it with 1024/128 for everything time-varying — see the note in
       descriptors._spectral, where the window length is a measured decision
       rather than a default: at 2048 the window is longer than the bright half
       of a percussive sound, and the centroid trajectory reads about half its
       true slope."""
    if window == "hann":
        w = np.hanning(n_fft + 1)[:-1]
    else:
        w = np.ones(n_fft)
    if len(x) < n_fft:
        x = np.pad(x, (0, n_fft - len(x)))
    n_frames = 1 + (len(x) - n_fft) // hop
    idx = np.arange(n_fft)[None, :] + hop * np.arange(n_frames)[:, None]
    frames = x[idx] * w[None, :]
    spec = np.fft.rfft(frames, n=n_fft, axis=1)
    mag = np.abs(spec).T                       # [freq, frame]
    freqs = np.fft.rfftfreq(n_fft, 1.0 / RATE)
    times = (np.arange(n_frames) * hop + n_fft * 0.5) / RATE
    return mag, freqs, times


def power_spectrum(x: np.ndarray, n_fft: int | None = None
                   ) -> tuple[np.ndarray, np.ndarray]:
    """Whole-signal power spectrum (single Hann-windowed transform)."""
    if n_fft is None:
        n_fft = int(2 ** np.ceil(np.log2(max(len(x), 1024))))
    w = np.hanning(len(x) + 1)[:-1] if len(x) > 1 else np.ones(len(x))
    spec = np.fft.rfft(x * w, n=n_fft)
    freqs = np.fft.rfftfreq(n_fft, 1.0 / RATE)
    return (np.abs(spec) ** 2), freqs


# ---------------------------------------------------------------- envelopes --

def envelope_rms(x: np.ndarray, win_ms: float = 3.0,
                 hop_ms: float = 0.5) -> tuple[np.ndarray, np.ndarray]:
    """Short-window RMS envelope. 3 ms / 0.5 ms: an attack this suite calls
       "under 8 ms" has to be resolvable at 8 ms, and a 3 ms window is the
       longest that still is."""
    win = max(int(RATE * win_ms / 1000.0), 4)
    hop = max(int(RATE * hop_ms / 1000.0), 1)
    if len(x) < win:
        x = np.pad(x, (0, win - len(x)))
    n = 1 + (len(x) - win) // hop
    idx = np.arange(win)[None, :] + hop * np.arange(n)[:, None]
    env = np.sqrt(np.maximum((x[idx] ** 2).mean(axis=1), 1e-24))
    t = (np.arange(n) * hop + win * 0.5) / RATE
    return env, t


def db(x: np.ndarray | float, floor: float = 1e-12) -> np.ndarray | float:
    return 20.0 * np.log10(np.maximum(np.abs(x), floor))


# ------------------------------------------------------------ Bark / bands --
#
# Traunmuller's analytic Bark scale — the one every psychoacoustic text uses for
# a closed form, accurate to a fraction of a Bark over the audible range.

def hz_to_bark(f: np.ndarray) -> np.ndarray:
    f = np.asarray(f, dtype=float)
    return (26.81 * f / (1960.0 + f)) - 0.53


def bark_to_hz(z: np.ndarray) -> np.ndarray:
    z = np.asarray(z, dtype=float) + 0.53
    return 1960.0 * z / (26.81 - z)


def bark_filterbank(freqs: np.ndarray, n_bands: int = 24,
                    z_max: float = 24.0) -> np.ndarray:
    """Triangular filterbank on the Bark scale, [band, freq], power-summing.

       Rows are normalised to unit power sum so a band's value is the signal
       power falling in it, not an area artefact of the band's width."""
    z_edges = np.linspace(0.0, z_max, n_bands + 2)
    f_edges = bark_to_hz(z_edges)
    z = hz_to_bark(freqs)
    fb = np.zeros((n_bands, len(freqs)))
    del f_edges
    for b in range(n_bands):
        lo, mid, hi = z_edges[b], z_edges[b + 1], z_edges[b + 2]
        left = (z - lo) / max(mid - lo, 1e-9)
        right = (hi - z) / max(hi - mid, 1e-9)
        fb[b] = np.clip(np.minimum(left, right), 0.0, 1.0)
    return fb


# The band split the health report speaks in. Chosen for game audio rather than
# for music: the first two bands are the ones a laptop speaker cannot reproduce
# and a subwoofer lives or dies by, and the split at 250 Hz is where "weight"
# stops and "body" starts.
BANDS: list[tuple[str, float, float]] = [
    ("sub", 20.0, 80.0),          # felt, not heard. Weight.
    ("low", 80.0, 250.0),         # body, chest.
    ("lowmid", 250.0, 800.0),     # size and box. Where mud lives.
    ("mid", 800.0, 2500.0),       # legibility over a mix; the ear's peak.
    ("highmid", 2500.0, 6000.0),  # attack, bite, aggression.
    ("high", 6000.0, 12000.0),    # air, detail, metal.
    ("top", 12000.0, 20000.0),    # sparkle; mostly inaudible on TV speakers.
]


def band_energies(x: np.ndarray) -> dict[str, float]:
    """Fraction of total signal power in each of BANDS. Sums to <= 1."""
    p, f = power_spectrum(x)
    total = float(p.sum()) or 1.0
    out = {}
    for name, lo, hi in BANDS:
        m = (f >= lo) & (f < hi)
        out[name] = float(p[m].sum() / total)
    return out


# Filters live in synth.py rather than here: the only filters this project
# needs are the ones tools/make_sfx.py uses, and keeping them next to the
# synthesiser that must match it is how they stay matched.

__all__ = [
    "RATE", "REPO", "bs1770", "load", "stft", "power_spectrum",
    "envelope_rms", "db", "hz_to_bark", "bark_to_hz", "bark_filterbank",
    "BANDS", "band_energies", "resample_linear",
]
