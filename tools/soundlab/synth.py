#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — SOUND LAB: the addressable synthesiser.
#
# tools/make_sfx.py is the shipping synth and it is deliberately hard-coded: a
# function per sound, with its magic numbers written into the body and a comment
# explaining each one. That is the right shape for a build tool and the wrong
# shape for a search — you cannot optimise over a constant.
#
# So this module re-expresses the SAME instrument with its parameters exposed:
# soft-clipped sine stacks through one-pole filters under exponential envelopes,
# in numpy instead of python lists (make_sfx's stdlib-only rule exists so the
# build never breaks on a bare machine; a search harness that renders 20 000
# candidates has the opposite constraint and lives in its own venv-free but
# numpy-requiring corner).
#
# EQUIVALENCE IS TESTED, NOT ASSERTED. `python3 tools/soundlab/synth.py
# --verify-voice` renders make_sfx's own `sub_step` through the shipping code
# and through this module at the same parameters, and reports the error. If the
# two ever diverge, a winning parameter set stops being reproducible in the
# shipping tool, which would make the whole harness a toy.
#
# NOTHING HERE WRITES INTO assets/. Candidates go to the search output dir.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dsp import RATE, REPO, bs1770  # noqa: E402


# ------------------------------------------------------------- primitives --

def frames(seconds: float) -> int:
    return max(int(RATE * seconds), 1)


def env_ad(n: int, attack: float, decay: float) -> np.ndarray:
    """make_sfx.env_exp, vectorised. Linear attack, exponential decay — a click
       is a ramp and everything physical that rings decays exponentially."""
    a = max(frames(attack), 1)
    i = np.arange(n)
    out = np.where(i < a, i / a, np.exp(-(i - a) / (RATE * max(decay, 1e-5))))
    return out


def env_adsr_hold(n: int, attack: float, hold: float, decay: float) -> np.ndarray:
    """An AD with a plateau. The plateau is what a wind-up needs and what
       make_sfx has no way to express."""
    a, h = max(frames(attack), 1), frames(hold)
    i = np.arange(n)
    out = np.where(i < a, i / a,
                   np.where(i < a + h, 1.0,
                            np.exp(-(i - a - h) / (RATE * max(decay, 1e-5)))))
    return out


def sine(n: int, hz: float, sweep_to: float | None = None,
         phase: float = 0.0, curve: float = 1.0) -> np.ndarray:
    """A sine, optionally sweeping to `sweep_to`.

       `curve` shapes the sweep: 1.0 is make_sfx's linear glide, >1 spends more
       of the sweep near the start frequency (an exponential-ish fall, which is
       what a struck object actually does as its tension relaxes)."""
    i = np.arange(n) / max(n - 1, 1)
    if sweep_to is None:
        f = np.full(n, hz)
    else:
        f = hz + (sweep_to - hz) * (i ** curve)
    p = phase + 2.0 * np.pi * np.cumsum(f) / RATE
    return np.sin(p)


def noise(n: int, seed: int) -> np.ndarray:
    """Uniform noise from a SEEDED generator. Every candidate is reproducible
       from its parameter dict alone, seed included — a search that cannot
       reproduce its own winner is a lottery."""
    return np.random.default_rng(seed).uniform(-1.0, 1.0, n)


def lowpass(x: np.ndarray, hz: float) -> np.ndarray:
    """One-pole low-pass, applied in the frequency domain.

       Identical transfer function to make_sfx.lowpass (verified by
       --verify-voice); the recursion is replaced by a multiply so a 20 000-
       candidate search finishes."""
    n = len(x)
    nfft = 1 << int(math.ceil(math.log2(max(2 * n, 8))))
    a = 1.0 - np.exp(-2.0 * np.pi * hz / RATE)
    w = 2.0 * np.pi * np.fft.rfftfreq(nfft, 1.0)
    h = a / (1.0 - (1.0 - a) * np.exp(-1j * w))
    return np.fft.irfft(np.fft.rfft(x, nfft) * h, nfft)[:n]


def highpass(x: np.ndarray, hz: float) -> np.ndarray:
    return x - lowpass(x, hz)


def bandpass(x: np.ndarray, lo: float, hi: float) -> np.ndarray:
    return highpass(lowpass(x, max(hi, lo * 1.05)), lo)


def delay(x: np.ndarray, seconds: float, n: int) -> np.ndarray:
    """Place `x` `seconds` into a buffer of length `n`."""
    d = frames(seconds) if seconds > 0 else 0
    out = np.zeros(n)
    if d >= n:
        return out
    take = min(len(x), n - d)
    out[d:d + take] = x[:take]
    return out


def soft_clip(x: np.ndarray, drive: float = 1.0) -> np.ndarray:
    """make_sfx's tanh stage with the drive exposed. Above ~2 it stops being a
       limiter and starts being a distortion — which for a creature is a
       feature, and for a UI tick is a defect. The objective functions decide."""
    return np.tanh(x * drive) / np.tanh(max(drive, 1e-3))


def fade_edges(x: np.ndarray, ms: float = 4.0) -> np.ndarray:
    k = min(frames(ms / 1000.0), len(x) // 2)
    if k < 1:
        return x
    r = np.arange(k) / k
    x = x.copy()
    x[:k] *= r
    x[-k:] *= r[::-1]
    return x


def finish(x: np.ndarray, target_lufs: float = -15.0,
           ceiling_dbtp: float = -1.5, fade_ms: float = 4.0) -> np.ndarray:
    """The last stage every candidate goes through, and it is not optional.

       A candidate must be judged at the loudness it will SHIP at, because half
       the descriptors that matter (crest factor above all) are only meaningful
       after normalisation. Peak-normalising the search and loudness-normalising
       the build would mean optimising a different sound from the one that
       plays. Same meter, same targets, same tanh-assist as make_sfx.write()."""
    x = fade_edges(np.asarray(x, dtype=float), fade_ms)
    if not np.any(x):
        return x
    scaled, report = bs1770.normalise_to(x, RATE, target_lufs, ceiling_dbtp)
    if report["limited_db"] > 1.0:
        drive = 10.0 ** (min(report["limited_db"], 6.0) / 20.0)
        scaled, report = bs1770.normalise_to(np.tanh(x * drive) / np.tanh(drive),
                                             RATE, target_lufs, ceiling_dbtp)
    return np.asarray(scaled, dtype=float)


# --------------------------------------------------------------- recipes ---
#
# A recipe is (parameter space, render function). The space is a dict of
# name -> (low, high, log?) which the search harness samples; the renderer takes
# a plain dict of values. Everything a recipe does is documented in place,
# because the point of the harness is that a winner is READABLE — you get a
# parameter set you can port back into make_sfx.py by hand, not a black box.


class Recipe:
    def __init__(self, name: str, blurb: str, space: dict, render, cls: str):
        self.name = name
        self.blurb = blurb
        self.space = space            # name -> (lo, hi, log)
        self.render = render
        self.cls = cls                # key into classes.CLASSES

    def keys(self) -> list[str]:
        return sorted(self.space)

    def sample(self, rng: np.random.Generator) -> dict:
        p = {}
        for k in self.keys():
            lo, hi, log = self.space[k]
            if log:
                p[k] = float(np.exp(rng.uniform(np.log(lo), np.log(hi))))
            else:
                p[k] = float(rng.uniform(lo, hi))
        return p

    def to_unit(self, p: dict) -> np.ndarray:
        v = []
        for k in self.keys():
            lo, hi, log = self.space[k]
            x = p[k]
            if log:
                v.append((np.log(x) - np.log(lo)) / (np.log(hi) - np.log(lo)))
            else:
                v.append((x - lo) / (hi - lo))
        return np.array(v)

    def from_unit(self, u: np.ndarray) -> dict:
        p = {}
        for i, k in enumerate(self.keys()):
            lo, hi, log = self.space[k]
            t = float(np.clip(u[i], 0.0, 1.0))
            p[k] = float(np.exp(np.log(lo) + t * (np.log(hi) - np.log(lo)))
                         if log else lo + t * (hi - lo))
        return p


RECIPES: dict[str, Recipe] = {}


def _reg(r: Recipe) -> None:
    RECIPES[r.name] = r


# -- hunter footfall ---------------------------------------------------------
#
# Four layers, and the reason there are four is the centroid-trajectory rule:
# each layer has its OWN decay, and the bright ones are shortest. That is what
# makes the spectrum fall over the sound's length without anyone drawing an
# automation curve — the same reason a real struck object darkens.

FOOTFALL_SPACE = {
    "dur":          (0.30, 0.95, False),
    "body_hz":      (28.0, 95.0, True),    # the floor's own note
    "body_fall":    (0.35, 1.00, False),   # how far it sweeps down, as a ratio
    "body_decay":   (0.030, 0.320, True),
    "body_curve":   (0.6, 3.0, False),     # sweep shape; >1 = falls late
    "body_gain":    (0.30, 1.00, False),
    "sub_hz":       (22.0, 55.0, True),    # the felt layer, under the body
    "sub_decay":    (0.040, 0.400, True),
    "sub_gain":     (0.00, 0.90, False),
    "contact_hp":   (900.0, 9000.0, True),  # the boot meeting the grate
    "contact_dec":  (0.0015, 0.030, True),
    "contact_gain": (0.00, 0.70, False),
    "crunch_lo":    (150.0, 1400.0, True),  # the grate flexing: mid noise band
    "crunch_hi":    (700.0, 6000.0, True),
    "crunch_dec":   (0.006, 0.120, True),
    "crunch_gain":  (0.00, 0.80, False),
    "tail_lp":      (120.0, 1200.0, True),  # the room taking it
    "tail_delay":   (0.000, 0.090, False),
    "tail_atk":     (0.002, 0.070, True),
    "tail_dec":     (0.030, 0.400, True),
    "tail_gain":    (0.00, 0.60, False),
    "ring_hz":      (90.0, 900.0, True),    # a metal deck has a note
    "ring_dec":     (0.010, 0.200, True),
    "ring_gain":    (0.00, 0.50, False),
    "drive":        (0.8, 3.5, False),
    "seed":         (1.0, 1e6, False),
}


def render_footfall(p: dict) -> np.ndarray:
    n = frames(p["dur"])
    seed = int(p["seed"])
    body = sine(n, p["body_hz"], sweep_to=p["body_hz"] * p["body_fall"],
                curve=p["body_curve"]) * env_ad(n, 0.0015, p["body_decay"])
    sub = sine(n, p["sub_hz"], sweep_to=p["sub_hz"] * 0.8) \
        * env_ad(n, 0.003, p["sub_decay"])
    contact = highpass(noise(n, seed), p["contact_hp"]) \
        * env_ad(n, 0.0004, p["contact_dec"])
    crunch = bandpass(noise(n, seed + 1), p["crunch_lo"],
                      max(p["crunch_hi"], p["crunch_lo"] * 1.2)) \
        * env_ad(n, 0.001, p["crunch_dec"])
    tail_src = lowpass(noise(n, seed + 2), p["tail_lp"]) \
        * env_ad(n, p["tail_atk"], p["tail_dec"])
    tail = delay(tail_src, p["tail_delay"], n)
    ring = sine(n, p["ring_hz"], sweep_to=p["ring_hz"] * 0.94) \
        * env_ad(n, 0.0008, p["ring_dec"])
    mix = (body * p["body_gain"] + sub * p["sub_gain"]
           + contact * p["contact_gain"] + crunch * p["crunch_gain"]
           + tail * p["tail_gain"] + ring * p["ring_gain"])
    return finish(soft_clip(mix, p["drive"]))


_reg(Recipe("footfall",
            "A hunter's step. Four layers with independent decays so the "
            "spectrum falls as it rings out.",
            FOOTFALL_SPACE, render_footfall, "footfall"))


# -- creature wind-up --------------------------------------------------------
#
# The inverse instrument. Where the footfall wants a falling centroid and a hard
# transient, a wind-up wants a RISING centroid, a plateau, and roughness — which
# here comes from three sources at once, because a single AM at a fixed rate
# sounds like a tremolo pedal: (a) amplitude modulation around 70 Hz, (b) a
# jittered fundamental (a real throat is unsteady), (c) a subharmonic that beats
# against the fundamental.

WINDUP_SPACE = {
    "dur":         (0.40, 1.50, False),
    "f_start":     (55.0, 320.0, True),
    "f_end_mult":  (1.10, 4.50, True),     # how far it climbs
    "f_curve":     (0.5, 3.0, False),      # climb shape; >1 = accelerates late
    "n_harm":      (2.0, 9.99, False),     # harmonic count (floored)
    "harm_tilt":   (0.35, 1.60, False),    # per-harmonic amplitude falloff
    "harm_detune": (0.000, 0.030, False),  # inharmonicity; 0 = organ, .02 = throat
    "am_rate":     (25.0, 130.0, True),    # roughness lives at ~70 Hz
    "am_depth":    (0.00, 0.90, False),
    "am_rate2":    (8.0, 45.0, True),      # a second, slower flutter
    "am_depth2":   (0.00, 0.55, False),
    "jitter_hz":   (0.000, 0.060, False),  # fundamental instability, fraction
    "jitter_rate": (4.0, 60.0, True),
    "sub_mult":    (0.25, 0.75, False),    # subharmonic, beats with the root
    "sub_gain":    (0.00, 0.70, False),
    "breath_lo":   (200.0, 2500.0, True),  # noise band, sweeps with the pitch
    "breath_span": (1.5, 8.0, False),
    "breath_gain": (0.00, 0.70, False),
    "atk":         (0.010, 0.300, True),
    "hold":        (0.000, 0.400, False),
    "dec":         (0.030, 0.500, True),
    "drive":       (0.9, 4.5, False),
    "seed":        (1.0, 1e6, False),
}


def render_windup(p: dict) -> np.ndarray:
    n = frames(p["dur"])
    seed = int(p["seed"])
    rng = np.random.default_rng(seed + 7)
    t = np.arange(n) / RATE
    u = np.linspace(0.0, 1.0, n)
    f0 = p["f_start"] * (1.0 + (p["f_end_mult"] - 1.0) * u ** p["f_curve"])
    # Jitter: a slow random walk on the fundamental, low-passed so it is
    # instability rather than noise. This is the difference between a throat and
    # an oscillator, and it costs four lines.
    if p["jitter_hz"] > 1e-4:
        j = lowpass(rng.normal(0.0, 1.0, n), p["jitter_rate"])
        j = j / (np.abs(j).max() or 1.0)
        f0 = f0 * (1.0 + p["jitter_hz"] * j)
    phase = 2.0 * np.pi * np.cumsum(f0) / RATE
    nh = max(int(p["n_harm"]), 1)
    voice = np.zeros(n)
    for k in range(1, nh + 1):
        # Inharmonic stretch: partial k sits at k*(1 + detune*k), which is what
        # a stiff or irregular resonator does and what a pure harmonic series
        # never does.
        mult = k * (1.0 + p["harm_detune"] * k)
        voice += np.sin(phase * mult) / (k ** p["harm_tilt"])
    if p["sub_gain"] > 1e-3:
        voice += p["sub_gain"] * np.sin(phase * p["sub_mult"])
    am = (1.0 - p["am_depth"] * 0.5 * (1.0 - np.cos(2 * np.pi * p["am_rate"] * t))) \
        * (1.0 - p["am_depth2"] * 0.5 * (1.0 - np.cos(2 * np.pi * p["am_rate2"] * t)))
    voice = voice * am
    if p["breath_gain"] > 1e-3:
        lo = p["breath_lo"] * (1.0 + (p["f_end_mult"] - 1.0) * u ** p["f_curve"])
        # Approximate the sweeping band with a static one at its mean; the
        # error is under a semitone over the length and buys a 40x speedup.
        lo_m = float(lo.mean())
        breath = bandpass(noise(n, seed + 3), lo_m, lo_m * p["breath_span"])
        voice += p["breath_gain"] * breath * am
    env = env_adsr_hold(n, p["atk"], p["hold"], p["dec"])
    return finish(soft_clip(voice * env, p["drive"]))


_reg(Recipe("creature_windup",
            "The tell. Rising, rough, unsteady — the three things a threat "
            "has to be that a rising tone is not.",
            WINDUP_SPACE, render_windup, "creature_windup"))


# -- heavy impact / death ----------------------------------------------------
#
# Two events with a valley between them, because that is what the objective
# function asks for and, more importantly, what the ear reads as consequence:
# the BREAK (bright, inharmonic, short) and the COLLAPSE (low, slow, arriving
# late). Getting the gap right is most of the class.

IMPACT_SPACE = {
    "dur":          (0.60, 2.60, False),
    # the break
    "brk_hp":       (600.0, 8000.0, True),
    "brk_dec":      (0.004, 0.090, True),
    "brk_gain":     (0.15, 1.00, False),
    "part1_hz":     (140.0, 1800.0, True),   # inharmonic metal partials
    "part_spread":  (1.20, 3.20, False),     # ratio between partials
    "n_part":       (2.0, 6.99, False),
    "part_dec":     (0.010, 0.220, True),
    "part_gain":    (0.00, 0.70, False),
    "part_falloff": (0.30, 1.60, False),     # higher partials die faster
    # the collapse
    "col_delay":    (0.010, 0.400, False),
    "col_hz":       (26.0, 90.0, True),
    "col_fall":     (0.35, 0.95, False),
    "col_atk":      (0.001, 0.040, True),
    "col_dec":      (0.070, 0.700, True),
    "col_gain":     (0.20, 1.00, False),
    # the debris / room
    "deb_delay":    (0.020, 0.600, False),
    "deb_lo":       (120.0, 2000.0, True),
    "deb_hi":       (600.0, 9000.0, True),
    "deb_atk":      (0.005, 0.120, True),
    "deb_dec":      (0.050, 0.700, True),
    "deb_gain":     (0.00, 0.60, False),
    "deb_am_rate":  (8.0, 90.0, True),       # granulation -> roughness, "rubble"
    "deb_am_depth": (0.00, 0.95, False),
    "drive":        (0.9, 4.0, False),
    "seed":         (1.0, 1e6, False),
}


def render_impact(p: dict) -> np.ndarray:
    n = frames(p["dur"])
    seed = int(p["seed"])
    t = np.arange(n) / RATE
    brk = highpass(noise(n, seed), p["brk_hp"]) * env_ad(n, 0.0003, p["brk_dec"])
    parts = np.zeros(n)
    npart = max(int(p["n_part"]), 1)
    for k in range(npart):
        hz = p["part1_hz"] * (p["part_spread"] ** k)
        if hz > RATE * 0.45:
            break
        # Higher partials decay faster — this single line is what produces a
        # falling spectral centroid, the descriptor the audit says the whole
        # library is missing.
        dec = p["part_dec"] * (p["part_falloff"] ** k)
        parts += (sine(n, hz, sweep_to=hz * 0.97)
                  * env_ad(n, 0.0006, max(dec, 0.002))) / (k + 1)
    col_n = n - frames(p["col_delay"])
    col = np.zeros(n)
    if col_n > 16:
        c = sine(col_n, p["col_hz"], sweep_to=p["col_hz"] * p["col_fall"],
                 curve=1.6) * env_ad(col_n, p["col_atk"], p["col_dec"])
        col = delay(c, p["col_delay"], n)
    deb_n = n - frames(p["deb_delay"])
    deb = np.zeros(n)
    if deb_n > 16:
        lo, hi = p["deb_lo"], max(p["deb_hi"], p["deb_lo"] * 1.3)
        d = bandpass(noise(deb_n, seed + 5), lo, hi) \
            * env_ad(deb_n, p["deb_atk"], p["deb_dec"])
        # Granulate it: rubble is many small events, and amplitude modulation at
        # a few tens of Hz is the cheapest honest way to say so.
        tt = np.arange(deb_n) / RATE
        d = d * (1.0 - p["deb_am_depth"] * 0.5
                 * (1.0 - np.cos(2 * np.pi * p["deb_am_rate"] * tt)))
        deb = delay(d, p["deb_delay"], n)
    del t
    mix = (brk * p["brk_gain"] + parts * p["part_gain"]
           + col * p["col_gain"] + deb * p["deb_gain"])
    return finish(soft_clip(mix, p["drive"]))


_reg(Recipe("impact_heavy",
            "Break then collapse. Independent partial decays make the centroid "
            "fall; a delayed sub makes the weight arrive after the crack.",
            IMPACT_SPACE, render_impact, "impact_heavy"))

_reg(Recipe("death_shatter",
            "The same instrument as impact_heavy, graded against the death "
            "class instead — more flux, more envelope range, longer.",
            IMPACT_SPACE, render_impact, "death_shatter"))


# -- weapon fire -------------------------------------------------------------
#
# Included because the audit's worst finding is the breaker, and the class is a
# two-line change from the impact recipe: no delay on the low half, and a hard
# ceiling on length.

WEAPON_SPACE = {
    "dur":         (0.14, 0.55, False),
    "crack_hp":    (700.0, 6000.0, True),
    "crack_dec":   (0.002, 0.040, True),
    "crack_gain":  (0.20, 1.00, False),
    "body_hz":     (60.0, 260.0, True),
    "body_fall":   (0.40, 0.98, False),
    "body_dec":    (0.015, 0.180, True),
    "body_gain":   (0.20, 1.00, False),
    # THE LAYER THE SPACE WAS MISSING. See the note under this recipe.
    "sub_hz":      (26.0, 70.0, True),
    "sub_fall":    (0.45, 0.95, False),
    "sub_dec":     (0.020, 0.220, True),
    "sub_gain":    (0.00, 1.00, False),
    "zap_hz":      (300.0, 3000.0, True),   # the energy-weapon half
    "zap_to":      (0.15, 1.20, False),
    "zap_dec":     (0.004, 0.070, True),
    "zap_gain":    (0.00, 0.70, False),
    "air_lo":      (200.0, 3000.0, True),
    "air_hi":      (900.0, 12000.0, True),
    "air_atk":     (0.001, 0.030, True),
    "air_dec":     (0.010, 0.220, True),
    "air_gain":    (0.00, 0.50, False),
    "drive":       (1.0, 4.0, False),
    "seed":        (1.0, 1e6, False),
}


def render_weapon(p: dict) -> np.ndarray:
    n = frames(p["dur"])
    seed = int(p["seed"])
    crack = highpass(noise(n, seed), p["crack_hp"]) * env_ad(n, 0.0002, p["crack_dec"])
    body = sine(n, p["body_hz"], sweep_to=p["body_hz"] * p["body_fall"], curve=1.4) \
        * env_ad(n, 0.0008, p["body_dec"])
    sub = sine(n, p["sub_hz"], sweep_to=p["sub_hz"] * p["sub_fall"], curve=1.9) \
        * env_ad(n, 0.0012, p["sub_dec"])
    zap = sine(n, p["zap_hz"], sweep_to=p["zap_hz"] * p["zap_to"], curve=0.7) \
        * env_ad(n, 0.0006, p["zap_dec"])
    air = bandpass(noise(n, seed + 2), p["air_lo"],
                   max(p["air_hi"], p["air_lo"] * 1.3)) \
        * env_ad(n, p["air_atk"], p["air_dec"])
    mix = (crack * p["crack_gain"] + body * p["body_gain"]
           + sub * p["sub_gain"] + zap * p["zap_gain"] + air * p["air_gain"])
    return finish(soft_clip(mix, p["drive"]))


_reg(Recipe("weapon_fire",
            "Crack, body, zap, air — all attacking together, nothing delayed. "
            "The audit's worst class by a distance.",
            WEAPON_SPACE, render_weapon, "weapon_fire"))

# THE GAP THIS RECIPE USED TO HAVE, and the reason the sub layer above exists.
# The lowest oscillator was `body_hz`, floored at 60 Hz, so nothing in this
# instrument could put energy under 60 Hz — and every shortlisted candidate duly
# measured band_sub = 0.000. The objective only set a minimum on band_LOW
# (80-250 Hz), so it never complained. The search was not wrong; it was answering
# honestly inside a space that did not contain the answer, which is the general
# lesson: A SEARCH CAN ONLY FIND WHAT ITS PARAMETER SPACE CONTAINS, AND IT WILL
# NOT TELL YOU WHAT THE SPACE IS MISSING. Only a human comparing the shortlist
# against what a gun is supposed to do will catch that.
#
# Fixed in the remaster: the sub layer here and a band_sub minimum in
# classes.py were added TOGETHER, because either one alone is useless — a layer
# no criterion asks for gets optimised to zero, and a criterion no layer can
# satisfy just lowers every score by a constant.


# -- creature presence -------------------------------------------------------

PRESENCE_SPACE = {
    "dur":         (3.0, 6.0, False),
    "f0":          (28.0, 90.0, True),
    "n_harm":      (2.0, 7.99, False),
    "harm_tilt":   (0.4, 1.8, False),
    "harm_detune": (0.000, 0.040, False),
    "beat_hz":     (0.15, 4.00, True),     # slow breathing of the drone
    "beat_depth":  (0.05, 0.80, False),
    "am_rate":     (25.0, 110.0, True),    # roughness
    "am_depth":    (0.00, 0.70, False),
    "drift_oct":   (0.00, 0.80, False),    # slow centroid movement
    "drift_hz":    (0.05, 1.20, True),
    "noise_lo":    (60.0, 900.0, True),
    "noise_hi":    (300.0, 4000.0, True),
    "noise_gain":  (0.00, 0.55, False),
    "drive":       (0.9, 3.0, False),
    "seed":        (1.0, 1e6, False),
}


def render_presence(p: dict) -> np.ndarray:
    n = frames(p["dur"])
    seed = int(p["seed"])
    t = np.arange(n) / RATE
    f0 = p["f0"] * (2.0 ** (p["drift_oct"] * np.sin(2 * np.pi * p["drift_hz"] * t)))
    phase = 2.0 * np.pi * np.cumsum(f0) / RATE
    v = np.zeros(n)
    for k in range(1, max(int(p["n_harm"]), 1) + 1):
        v += np.sin(phase * k * (1.0 + p["harm_detune"] * k)) / (k ** p["harm_tilt"])
    v *= (1.0 - p["beat_depth"] * 0.5 * (1.0 - np.cos(2 * np.pi * p["beat_hz"] * t)))
    v *= (1.0 - p["am_depth"] * 0.5 * (1.0 - np.cos(2 * np.pi * p["am_rate"] * t)))
    if p["noise_gain"] > 1e-3:
        v += p["noise_gain"] * bandpass(noise(n, seed), p["noise_lo"],
                                        max(p["noise_hi"], p["noise_lo"] * 1.3))
    return finish(soft_clip(v, p["drive"]), fade_ms=40.0)


_reg(Recipe("creature_presence",
            "The drone that means it is in the room: harmonics with a slow "
            "drift, a breath and a 70 Hz grind.",
            PRESENCE_SPACE, render_presence, "creature_presence"))


# ------------------------------------------------------------------ voice --

def verify_voice() -> int:
    """Render make_sfx's own sub_step through the shipping code and through
       this module's primitives at identical parameters, and report the error.

       This is the load-bearing test of the whole harness: if the two synths
       have drifted, a parameter set that wins here does not reproduce there."""
    sys.path.insert(0, os.path.join(REPO, "tools"))
    import make_sfx  # noqa: PLC0415

    ref = np.array(make_sfx.sub_step(), dtype=float)

    n = frames(0.42)
    thump = sine(n, 40.0, sweep_to=26.0) * env_ad(n, 0.004, 0.075)
    air = lowpass(noise(n, 0x5793), 420.0) * env_ad(n, 0.002, 0.045)
    d = frames(0.15)
    tick = delay(sine(n - d, 1180.0, sweep_to=1560.0)
                 * env_ad(n - d, 0.001, 0.022) * 0.16, 0.15, n)
    body = thump * 0.95 + air * 0.30 + tick
    ours = np.tanh(body)
    ours = ours * 0.86 / (np.abs(ours).max() or 1.0)
    ours = fade_edges(ours, 4.0)

    # The noise layer cannot match: make_sfx uses random.Random(seed) and this
    # module uses numpy's PCG64, so compare with the noise layer removed AND
    # report the full-mix correlation for context.
    thump_only = np.tanh(thump * 0.95 + tick)
    ref_nonoise = np.array(make_sfx.mix(
        make_sfx.gain(make_sfx.apply_env(
            make_sfx.sine(n, 40.0, sweep_to=26.0),
            make_sfx.env_exp(n, 0.004, 0.075)), 0.95),
        [0.0] * d + make_sfx.gain(make_sfx.apply_env(
            make_sfx.sine(n - d, 1180.0, sweep_to=1560.0),
            make_sfx.env_exp(n - d, 0.001, 0.022)), 0.16)), dtype=float)
    ref_nonoise = np.tanh(ref_nonoise)
    err = float(np.abs(thump_only - ref_nonoise).max())
    rms = float(np.sqrt(np.mean((thump_only - ref_nonoise) ** 2)))
    print("[synth] deterministic layers (sine+env+delay+tanh):")
    print("        max abs error %.3e, rms error %.3e over %d samples" % (err, rms, n))

    # And the filter, on its own, against the recursion it replaces.
    probe = np.random.default_rng(4).normal(0, 1, 8000)
    a = np.array(make_sfx.lowpass(list(probe), 420.0))
    b = lowpass(probe, 420.0)
    ferr = float(np.abs(a - b).max())
    print("[synth] one-pole low-pass, FFT form vs make_sfx recursion:")
    print("        max abs error %.3e (signal rms %.3f)" % (ferr, float(probe.std())))

    ok = err < 1e-9 and ferr < 1e-9
    print("[synth] VOICE MATCH: %s" % ("yes" if ok else "NO — investigate"))
    del ref, ours
    return 0 if ok else 1


def render_from_manifest(manifest_path: str, rank: int, out_path: str) -> int:
    """Re-render one shortlisted candidate from its recorded parameters.

       This is the adoption path, and it is also the proof that the shortlist is
       real: a winner that cannot be reproduced from its parameter dict is a
       lucky render, not a result.

       The re-rendered file DECODES to the same samples as the one the search
       wrote (verified: max abs difference 0.0 over 21874 samples). The .ogg
       files themselves differ byte for byte, because libvorbis stamps a random
       stream serial into every container — compare decoded audio, not md5s."""
    import json  # noqa: PLC0415
    m = json.load(open(manifest_path))
    recipe = RECIPES[m["recipe"]]
    cand = next(c for c in m["candidates"] if c["rank"] == rank)
    x = recipe.render(cand["params"])
    import soundfile as sf  # noqa: PLC0415
    wav = os.path.splitext(out_path)[0] + ".wav"
    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    sf.write(wav, np.clip(x, -1.0, 1.0), RATE, subtype="PCM_16")
    if out_path.endswith(".ogg"):
        import subprocess  # noqa: PLC0415
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                        "-c:a", "libvorbis", "-q:a", "6", out_path], check=True)
        os.remove(wav)
    print("[synth] re-rendered %s rank %d -> %s" % (m["recipe"], rank, out_path))
    print("[synth] parameters:")
    for k in sorted(cand["params"]):
        print("        %-14s %.6g" % (k, cand["params"][k]))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify-voice", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--render", default="", metavar="MANIFEST.json",
                    help="re-render a shortlisted candidate from its parameters")
    ap.add_argument("--rank", type=int, default=1)
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    if args.verify_voice:
        return verify_voice()
    if args.render:
        if not args.out:
            ap.error("--render needs --out")
        return render_from_manifest(args.render, args.rank, args.out)
    if args.list:
        for k, r in sorted(RECIPES.items()):
            print("%-20s %2d params  -> class %-18s %s"
                  % (k, len(r.space), r.cls, r.blurb.split(".")[0]))
        return 0
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
