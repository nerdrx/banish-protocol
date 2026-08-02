#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — MOTHER'S VOICE (R&D candidate generator)
#
#   python3 tools/audio/build_mother_voice.py
#   python3 tools/audio/build_mother_voice.py --only mv_addr_breathe --wav-only
#   python3 tools/audio/build_mother_voice.py --sheets  (writes analysis PNGs)
#
# WHAT THIS IS
# ------------
# MOTHER currently exists as 183 text barks (assets/lore/corpus.json) rendered
# to a caption line. This tool is the R&D bench for giving her an AUDIBLE
# voice-presence without a text-to-speech engine and without a single byte of
# third-party audio, per the no-third-party law. Nothing here is wired into the
# game; these are candidates for review. See the report / integration notes.
#
# THE DESIGN PROBLEM
# ------------------
# Real TTS is off the table and, honestly, would be wrong anyway: a clean
# synthetic reading of "YOU BREATHE TOO LOUDLY" is a podcast, not a haunting.
# What we actually need is the *impression* of speech — the thing that makes a
# player's language centre snap to attention — with the words withheld. The
# caption already carries the words (and MUST, for deaf players); the audio
# carries the fact that something with a mouth-shaped resonator is forming
# sentences about you.
#
# So: NO PHONEMES ARE SYNTHESISED AS WORDS. What is synthesised is everything
# ELSE a sentence has —
#
#   * syllable count and rhythm, derived from the real bark text;
#   * lexical stress, and the ~1.9x final-syllable lengthening that is the
#     single strongest "this was a sentence, and it has just ended" cue;
#   * an F0 contour with declination, pitch accents on stressed syllables, and
#     a terminal fall (MOTHER states; she never asks);
#   * vowel colour that MOVES, taken from the orthographic vowel groups of the
#     actual words, with unstressed syllables reduced toward schwa;
#   * consonant EVENTS — stop closures and bursts, fricative hiss, nasal
#     murmurs — classed from the real onset/coda letters. This is the part
#     people skip, and it is why most "alien voice" synthesis sounds like a
#     theremin: without closures and bursts there is no articulation, and
#     without articulation the brain files it as music.
#
# Result: a listener hears a specific sentence being spoken, and cannot repeat
# a word of it. Which is the point — she is not addressing your ears.
#
# FOUR TECHNIQUES, ONE ENGINE
# ---------------------------
# All four techniques the brief asked for are the same signal chain with
# different excitation and different spectral-gain quantisation:
#
#   1. FORMANT SYNTHESIS   glottal-pulse excitation -> Klatt-style parallel
#                          resonator bank, time-varying, applied as a per-frame
#                          spectral gain in an STFT (the only tractable way to
#                          sweep four resonators per sample in numpy).
#   2. VOCODER TEXTURES    the identical spectral-gain surface, QUANTISED into
#                          N log-spaced bands (the staircase IS what makes a
#                          vocoder sound like a vocoder), driving a noise or
#                          conduit-hum carrier instead of a glottis.
#   3. WHISPER BANDS       voicing forced to zero, aspiration to one, formant
#                          bandwidths widened and F1 lifted — which is what a
#                          whisper physically is. Fricatives dominate.
#   4. CASSETTE CHAIN      wow / flutter / scrape, partial and total dropouts
#                          (HF-first, because that is how a tape lifting off a
#                          head actually fails), pre-emphasised tape saturation,
#                          head bump, azimuth loss, speed-modulated hiss, and
#                          print-through PRE-echo. Cassette futurism is the
#                          house style; this is the part that makes her sound
#                          like something recorded decades ago on human gear
#                          and played back by a machine that outlived them.
#
# LOUDNESS
# --------
# Every candidate is normalised with `tools/audio/bs1770.py` (a spec-faithful
# ITU-R BS.1770-4 gated meter, self-tested against EBU Tech 3341). The gating
# matters enormously here: MOTHER's phrases are mostly silence, and an
# un-gated normaliser would read that silence as "quiet material" and shove her
# playback gain up until she shouts. Targets are per-intensity, not global.
#
# All output is MONO — every asset in this repo is spatialised at runtime by
# AudioStreamPlayer3D, so baking a stereo image in would fight the engine.
# Intimacy is bought with proximity EQ and reverb absence, never with width.
#
# CPU only. numpy + PIL + ffmpeg (for the Vorbis encode). No scipy, no Godot.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bs1770  # noqa: E402  (sibling module, same directory)

RATE = 48000
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OUT_DIR = os.path.join(REPO, "assets", "audio", "mother_voice_rnd")
CORPUS = os.path.join(REPO, "assets", "lore", "corpus.json")

N_FFT = 1024
HOP = 256


# ===========================================================================
# 1. PROSODY — real bark text in, a speech timeline out
# ===========================================================================

#: Formant targets F1..F4 (Hz) and relative amplitudes. Values are a low
#: contralto — deliberately at the bottom of the female range, where a voice
#: stops reading as "assistant" and starts reading as "authority". MOTHER is a
#: planet-scale machine that has not needed to sound friendly in decades.
VOWELS = {
    "i":  (300, 2500, 3100, 4000),
    "ih": (430, 2300, 2950, 3900),
    "ey": (480, 2200, 2800, 3800),
    "eh": (600, 2050, 2800, 3800),
    "ae": (830, 1950, 2750, 3800),
    "aa": (830, 1250, 2700, 3700),
    "ao": (620, 1000, 2650, 3650),
    "ow": (520,  900, 2550, 3550),
    "uh": (470, 1150, 2450, 3450),
    "uw": (340,  950, 2350, 3350),
    "ah": (700, 1300, 2550, 3550),
    "ax": (550, 1500, 2550, 3550),   # schwa — the reduction target
    "er": (500, 1400, 1700, 3300),
}

#: Orthographic vowel group -> (nucleus, optional glide target). Diphthongs get
#: a second target so the formants MOVE inside the syllable, which is most of
#: what separates speech from a held drone. Longest match wins.
VOWEL_SPELLINGS = [
    ("eau", ("ow", None)), ("eigh", ("ey", None)),
    ("ough", ("ao", None)), ("augh", ("ao", None)),
    # -TION / -SION / -IOUS: the i+o is one reduced beat, not two. Without
    # these, VERSION and QUARANTINE each gain a phantom syllable and the whole
    # line's rhythm drifts off the stress pattern.
    ("iou", ("ax", None)), ("eou", ("ax", None)),
    ("io", ("ax", None)),  ("ia", ("ax", None)),  ("eo", ("i", "ax")),
    ("ee", ("i", None)),   ("ea", ("i", None)),   ("ei", ("ey", None)),
    ("ie", ("i", None)),   ("oo", ("uw", None)),  ("oa", ("ow", None)),
    ("ou", ("aa", "uh")),  ("ow", ("aa", "uh")),  ("oi", ("ao", "i")),
    ("oy", ("ao", "i")),   ("au", ("ao", None)),  ("aw", ("ao", None)),
    ("ai", ("ey", None)),  ("ay", ("ey", None)),  ("ue", ("uw", None)),
    ("ui", ("uw", None)),  ("eu", ("uw", None)),  ("ew", ("uw", None)),
    ("a",  ("ae", None)),  ("e",  ("eh", None)),  ("i",  ("ih", None)),
    ("o",  ("aa", None)),  ("u",  ("ah", None)),  ("y",  ("ih", None)),
]

#: Consonant classes. The synthesiser only needs the CLASS — a stop is a
#: silence followed by a click, a fricative is shaped noise, a nasal is a
#: damped low resonance with an anti-formant. Getting the class right from the
#: real spelling is enough to make articulation land in the right places.
STOPS = set("ptkbdg")
FRICATIVES = set("sfvzh")          # plus the digraphs handled below
NASALS = set("mn")
LIQUIDS = set("lrwy")

#: Function words reduce. Unstressing "THE / IS / OF" and stressing the content
#: words is what gives an utterance its gait; flat stress reads as a chant.
FUNCTION_WORDS = {
    "the", "a", "an", "is", "are", "was", "were", "to", "of", "in", "on", "at",
    "it", "its", "that", "this", "and", "or", "do", "does", "did", "have",
    "has", "had", "be", "been", "am", "i", "you", "your", "my", "me", "we",
    "they", "them", "he", "she", "with", "from", "for", "as", "by", "there",
    "here", "will", "would", "can", "could", "shall", "should", "than", "then",
}

#: Voiceless fricatives that carry real high-frequency energy. Used to pick the
#: hiss band per fricative event, so a /s/ and an /f/ do not sound identical.
FRIC_BANDS = {
    "s": (4200, 9500, 1.00), "z": (4000, 8500, 0.55),
    "sh": (2200, 6000, 0.95), "ch": (2200, 6500, 0.95),
    "f": (1400, 8000, 0.45), "v": (1200, 6500, 0.30),
    "th": (1600, 8000, 0.42), "h": (700, 4200, 0.35),
    "x": (3000, 8500, 0.80),
}


class Syllable:
    """One beat of the utterance."""

    def __init__(self) -> None:
        self.onset: list[str] = []      # consonant tokens before the nucleus
        self.coda: list[str] = []       # consonant tokens after it
        self.nucleus: str = "ax"
        self.glide: str | None = None
        self.stress: float = 0.0        # 0 reduced, 0.5 secondary, 1.0 primary
        self.final: bool = False        # last syllable before a pause
        self.phrase_end: bool = False   # last syllable of the whole utterance
        self.pause_after: float = 0.0   # seconds of silence following


def split_syllables(word: str) -> list[Syllable]:
    """Split an orthographic word into syllables around its vowel groups.

    A spelling-driven syllabifier, not a pronunciation dictionary — which is
    exactly right here, because we are not trying to be intelligible. It has to
    get the COUNT and the rough vowel colour right, and it does: PROCESS -> 2,
    MANIFEST -> 3, QUARANTINE -> 3, EXCEEDS -> 2, BREATHE -> 1, VERSION -> 2,
    DIFFERENTLY -> 4.

    Known and accepted miss: a silent 'e' INSIDE a compound (SOMETHING, and
    little else in this corpus) still counts as a beat. Every rule that fixes
    it also breaks EXPECT/SECTOR, and a one-beat rhythm error inside a
    deliberately unintelligible utterance is not worth a pronunciation
    dictionary we would then have to maintain.
    """
    w = re.sub(r"[^a-z]", "", word.lower())
    if not w:
        return []

    # Find vowel groups with their spans, longest spelling first.
    groups: list[tuple[int, int, str, str | None]] = []
    i = 0
    while i < len(w):
        # 'y' is a consonant word-initially (YOU, YOUR, YIELD) and a vowel
        # everywhere else; and the 'u' of QU is part of the consonant, not a
        # nucleus. Both cost a phantom syllable if you let the scanner have
        # them.
        if (w[i] == "y" and i == 0) or (w[i] == "u" and i > 0 and w[i - 1] == "q"):
            i += 1
            continue
        for spelling, (nuc, glide) in VOWEL_SPELLINGS:
            if w.startswith(spelling, i):
                groups.append((i, i + len(spelling), nuc, glide))
                i += len(spelling)
                break
        else:
            i += 1
    if not groups:
        # An all-consonant token (an acronym, a glyph run). Give it one beat.
        s = Syllable()
        s.onset = tokenise_consonants(w)
        s.nucleus = "ax"
        return [s]

    # Silent terminal 'e': BREATHE is one beat, not two. Keep it if the word
    # ends -Ce where C is l or r (SUBTLE, ACRE), which really is a beat.
    if len(groups) > 1 and groups[-1][1] == len(w) and w.endswith("e"):
        if not (len(w) >= 3 and w[-2] in "lr"):
            groups.pop()
    # The "-ed" rule: the past-tense suffix is only its own syllable after a
    # /t/ or /d/ (ESCALATED, NOTED, LOGGED-no). Everywhere else it is silent —
    # REMOVED is two beats, not three. This one rule is worth more than the
    # rest of the exception list put together, because MOTHER's corpus is
    # written almost entirely in the passive past.
    elif len(groups) > 1 and w.endswith("ed") and groups[-1][1] == len(w) - 1 \
            and len(w) >= 4 and w[-3] not in "td":
        groups.pop()

    syls: list[Syllable] = []
    for n, (start, end, nuc, glide) in enumerate(groups):
        s = Syllable()
        s.nucleus = nuc
        s.glide = glide
        prev_end = 0 if n == 0 else groups[n - 1][1]
        between = w[prev_end:start]
        if n == 0:
            s.onset = tokenise_consonants(between)
        else:
            # Split the intervocalic cluster: last consonant onsets the new
            # syllable, the rest closes the previous one (maximal-onset, near
            # enough for a rhythm generator).
            cons = tokenise_consonants(between)
            if len(cons) <= 1:
                s.onset = cons
            else:
                syls[-1].coda += cons[:-1]
                s.onset = cons[-1:]
        syls.append(s)
    syls[-1].coda += tokenise_consonants(w[groups[-1][1]:])
    return syls


def tokenise_consonants(chunk: str) -> list[str]:
    """Consonant letters -> tokens, keeping the digraphs that have their own
       sound (TH, SH, CH, PH, NG, CK, QU, WH)."""
    out: list[str] = []
    i = 0
    digraphs = ("th", "sh", "ch", "ph", "ng", "ck", "qu", "wh", "gh")
    while i < len(chunk):
        two = chunk[i:i + 2]
        if two in digraphs:
            out.append({"ph": "f", "ck": "k", "qu": "k", "wh": "w",
                        "gh": "h", "ng": "n"}.get(two, two))
            i += 2
        else:
            out.append(chunk[i])
            i += 1
    return out


def parse_utterance(text: str) -> list[Syllable]:
    """Bark text -> a flat syllable list with stress, finality and pauses.

    `{CALLSIGN}` is expanded to a two-syllable stand-in — the real one is
    replaced per player at runtime, and its LENGTH is what the rhythm needs.
    """
    text = text.replace("{CALLSIGN}", "BREAKER")
    syls: list[Syllable] = []
    for raw in re.findall(r"[A-Za-z'{}]+|[.,:;!?—-]", text):
        if raw in ".,:;!?—-":
            if syls:
                syls[-1].final = True
                syls[-1].pause_after = {
                    ".": 0.46, "!": 0.44, "?": 0.46, ":": 0.32, ";": 0.32,
                    ",": 0.20, "—": 0.26, "-": 0.10,
                }.get(raw, 0.20)
            continue
        word_syls = split_syllables(raw)
        if not word_syls:
            continue
        lower = re.sub(r"[^a-z]", "", raw.lower())
        if lower in FUNCTION_WORDS and len(word_syls) == 1:
            word_syls[0].stress = 0.0
        else:
            # Primary stress on the first syllable of a content word, secondary
            # two syllables later. Crude, and correct often enough that the
            # rhythm reads as English rather than as a metronome.
            word_syls[0].stress = 1.0
            for k in range(2, len(word_syls), 2):
                word_syls[k].stress = 0.5
        # Vowel reduction: an unstressed nucleus collapses toward schwa. This
        # one line is worth more realism than any amount of formant tuning.
        for s in word_syls:
            if s.stress == 0.0:
                s.nucleus = "ax" if s.nucleus not in ("i", "uw") else s.nucleus
                s.glide = None
        syls += word_syls
    if syls:
        syls[-1].final = True
        syls[-1].phrase_end = True
        syls[-1].pause_after = max(syls[-1].pause_after, 0.30)
    return syls


class Timeline:
    """Sample-rate control signals for one utterance."""

    def __init__(self, n: int) -> None:
        self.n = n
        self.f0 = np.zeros(n)
        self.voicing = np.zeros(n)
        self.aspiration = np.zeros(n)
        self.amp = np.zeros(n)
        self.formants = np.zeros((4, n))
        self.bandwidths = np.zeros((4, n))
        self.famp = np.zeros((4, n))
        self.fric = np.zeros((3, n))   # centre lo, hi, level for hiss events
        self.nasal = np.zeros(n)


def build_timeline(syls: list[Syllable], *,
                   syl_dur: float = 0.155,
                   f0_base: float = 132.0,
                   declination: float = -0.22,
                   accent_semitones: float = 2.6,
                   terminal_fall: float = -4.0,
                   final_lengthen: float = 1.9,
                   quantise: float = 0.0,
                   breathiness: float = 0.10,
                   whisper: float = 0.0,
                   lead_in: float = 0.25,
                   tail: float = 0.45,
                   rng: np.random.Generator | None = None) -> Timeline:
    """Turn the syllable list into sample-rate control signals.

    `quantise` (0..1) snaps every syllable to a fixed grid, killing the natural
    long/short alternation. At 1.0 the result is metronomic — used for the
    Below-the-Kernel "counting" candidate, because a voice with perfectly even
    syllables is one of the cheapest and most reliable ways to sound like it is
    not a person.
    """
    rng = rng or np.random.default_rng(0)
    if not syls:
        syls = [Syllable()]

    # --- durations --------------------------------------------------------
    durs: list[float] = []
    for s in syls:
        d = syl_dur * (1.35 if s.stress >= 1.0 else 0.88 if s.stress == 0.0 else 1.10)
        if s.final:
            d *= final_lengthen
        d *= 1.0 + 0.05 * (rng.random() - 0.5)     # human timing noise
        d = d * (1.0 - quantise) + syl_dur * 1.15 * quantise
        durs.append(d)
    starts: list[float] = []
    t = lead_in
    for s, d in zip(syls, durs):
        starts.append(t)
        t += d + s.pause_after * (1.0 - 0.7 * quantise)
    total = t + tail
    n = int(total * RATE)
    tl = Timeline(n)
    time = np.arange(n) / RATE

    # --- F0 contour -------------------------------------------------------
    # Declination across the utterance (universal, and the reason a monotone
    # line sounds like a robot in a 1980s film rather than like a mind).
    span = max(total - lead_in - tail, 1e-6)
    prog = np.clip((time - lead_in) / span, 0.0, 1.0)
    semis = declination * 12.0 * prog

    # Pitch accents: a rise-fall centred on each stressed syllable.
    for s, st, d in zip(syls, starts, durs):
        if s.stress <= 0.0:
            continue
        peak = accent_semitones * (1.0 if s.stress >= 1.0 else 0.55)
        lo, hi = st - 0.06, st + d + 0.04
        m = (time >= lo) & (time <= hi)
        if not np.any(m):
            continue
        u = (time[m] - lo) / max(hi - lo, 1e-6)
        semis[m] += peak * np.sin(np.pi * u) ** 1.4

    # Terminal contour on the last syllable. A fall states; a flat terminal is
    # the uncanny one (no human ends a declarative flat), which is why
    # `terminal_fall = 0` is exposed as a candidate parameter and not a bug.
    last, ld = starts[-1], durs[-1]
    m = time >= last
    if np.any(m):
        u = np.clip((time[m] - last) / max(ld, 1e-6), 0.0, 1.0)
        semis[m] += terminal_fall * u ** 1.6

    # Vibrato-free by design: MOTHER's pitch does not wander, because a machine
    # holding a note dead-steady is more unsettling than one that wobbles. A
    # sub-cent random walk keeps it from sounding like an oscillator.
    walk = np.cumsum(rng.normal(0.0, 1.0, n))
    walk = walk / (np.max(np.abs(walk)) + 1e-9) * 0.05
    tl.f0 = f0_base * 2.0 ** ((semis + walk) / 12.0)

    # --- per-segment articulation ----------------------------------------
    def ramp(a: float, b: float) -> np.ndarray:
        i0, i1 = int(max(a, 0) * RATE), int(min(b, total) * RATE)
        return np.arange(i0, max(i1, i0 + 1))

    f_targets = np.zeros((4, n))
    b_targets = np.zeros((4, n))
    a_targets = np.zeros((4, n))
    for k in range(4):
        f_targets[k, :] = VOWELS["ax"][k]
        b_targets[k, :] = (90, 120, 170, 260)[k]
        a_targets[k, :] = (1.0, 0.6, 0.35, 0.18)[k]

    for s, st, d in zip(syls, starts, durs):
        # --- onset consonants, packed into the run-up to the nucleus ------
        cons_time = st
        for c in s.onset:
            cons_time = _place_consonant(tl, c, cons_time, voiced_after=True)
        nuc_start = max(cons_time, st)
        idx = ramp(nuc_start, st + d)
        if idx.size == 0:
            continue

        # Nucleus formant glide. A monophthong still moves — it is dragged from
        # and toward its neighbours by coarticulation, which is modelled here
        # as a raised-cosine settle rather than a step.
        v0 = VOWELS[s.nucleus]
        v1 = VOWELS[s.glide] if s.glide else v0
        u = np.linspace(0.0, 1.0, idx.size)
        blend = 0.5 - 0.5 * np.cos(np.pi * np.clip(u * 1.35, 0.0, 1.0))
        openness = 0.55 + 0.45 * s.stress     # unstressed = less articulated
        for k in range(4):
            tgt = v0[k] + (v1[k] - v0[k]) * blend
            neutral = VOWELS["ax"][k]
            f_targets[k, idx] = neutral + (tgt - neutral) * openness
            # Whisper widens every bandwidth and lifts F1 — that is physically
            # what a whisper IS (turbulent glottal source, slack folds), not a
            # low-pass filter over a normal voice.
            b_targets[k, idx] = (90, 120, 170, 260)[k] * (1.0 + 2.2 * whisper)
            a_targets[k, idx] = (1.0, 0.6, 0.35, 0.18)[k]
        if whisper > 0.0:
            f_targets[0, idx] *= 1.0 + 0.18 * whisper

        tl.voicing[idx] = (1.0 - whisper) * (0.75 + 0.25 * s.stress)
        tl.aspiration[idx] = breathiness + whisper * 0.95
        # Syllable amplitude: fast attack, plateau, softer release.
        env = np.minimum(u / 0.16, 1.0) * np.minimum((1.0 - u) / 0.30 + 0.25, 1.0)
        tl.amp[idx] = np.maximum(tl.amp[idx],
                                 env * (0.55 + 0.45 * s.stress))

        # --- coda consonants ----------------------------------------------
        cons_time = st + d
        for c in s.coda:
            cons_time = _place_consonant(tl, c, cons_time, voiced_after=False)

    # Smooth the formant tracks — the articulators have mass. 25 ms of
    # smoothing is roughly a real tongue, and skipping it is what makes cheap
    # formant synths sound like a stepped filter sweep.
    win = int(0.025 * RATE)
    kern = np.hanning(win) / np.sum(np.hanning(win))
    for k in range(4):
        tl.formants[k] = np.convolve(f_targets[k], kern, mode="same")
        tl.bandwidths[k] = np.convolve(b_targets[k], kern, mode="same")
        tl.famp[k] = np.convolve(a_targets[k], kern, mode="same")
    smooth = np.hanning(int(0.012 * RATE))
    smooth /= np.sum(smooth)
    tl.amp = np.convolve(tl.amp, smooth, mode="same")
    tl.voicing = np.convolve(tl.voicing, smooth, mode="same")
    tl.aspiration = np.convolve(tl.aspiration, smooth, mode="same")
    return tl


def _place_consonant(tl: Timeline, c: str, t: float, voiced_after: bool) -> float:
    """Write one consonant event into the timeline; return the time after it.

    Stops get a real CLOSURE (a hole in the signal) before their burst. The
    hole is the articulation — a burst with no silence in front of it reads as
    a tick, and a voice made of ticks is a Geiger counter."""
    n = tl.n

    def span(a: float, b: float) -> np.ndarray:
        i0, i1 = int(a * RATE), int(b * RATE)
        return np.arange(max(i0, 0), min(max(i1, i0 + 1), n))

    if c in STOPS:
        closure = 0.042 if c in "ptk" else 0.030
        idx = span(t, t + closure)
        tl.amp[idx] = 0.0
        tl.voicing[idx] = 0.0
        tl.aspiration[idx] = 0.0
        burst = span(t + closure, t + closure + 0.014)
        tl.amp[burst] = np.maximum(tl.amp[burst], 0.55 if c in "ptk" else 0.32)
        tl.aspiration[burst] = 1.0
        lo, hi = {"p": (700, 3000), "b": (600, 2400), "t": (3000, 8000),
                  "d": (2400, 6500), "k": (1400, 4200), "g": (1200, 3600)}[c]
        tl.fric[0, burst] = lo
        tl.fric[1, burst] = hi
        tl.fric[2, burst] = 0.9 if c in "ptk" else 0.5
        return t + closure + 0.014

    if c in FRIC_BANDS:
        lo, hi, lvl = FRIC_BANDS[c]
        dur = 0.085 if c in ("s", "sh", "ch", "z") else 0.062
        idx = span(t, t + dur)
        u = np.linspace(0.0, 1.0, max(idx.size, 1))
        shape = np.sin(np.pi * u) ** 0.5
        tl.amp[idx] = np.maximum(tl.amp[idx], lvl * 0.85 * shape)
        tl.aspiration[idx] = 1.0
        tl.voicing[idx] = 0.35 if c in "zv" else 0.0
        tl.fric[0, idx] = lo
        tl.fric[1, idx] = hi
        tl.fric[2, idx] = lvl
        return t + dur

    if c in NASALS:
        dur = 0.058
        idx = span(t, t + dur)
        tl.amp[idx] = np.maximum(tl.amp[idx], 0.42)
        tl.voicing[idx] = 0.9
        tl.aspiration[idx] = 0.04
        tl.nasal[idx] = 1.0
        return t + dur

    if c in LIQUIDS:
        dur = 0.048
        idx = span(t, t + dur)
        tl.amp[idx] = np.maximum(tl.amp[idx], 0.5)
        tl.voicing[idx] = 0.85
        return t + dur

    return t + 0.020


# ===========================================================================
# 2. EXCITATION SOURCES
# ===========================================================================

def glottal_source(tl: Timeline, *, creak: float = 0.0, jitter: float = 0.004,
                   shimmer: float = 0.03, tilt_hz: float = 2600.0,
                   rng: np.random.Generator | None = None) -> np.ndarray:
    """Rosenberg glottal-flow pulse train, differentiated at the lips.

    `creak` (0..1) halves the amplitude of alternate periods, producing a
    subharmonic at F0/2 — vocal fry. It is the single most effective knob in
    this whole file for making a calm sentence sound like a threat, and it is
    free: it costs one modulo.

    `jitter` is period-to-period pitch noise. MOTHER runs LOW jitter on
    purpose. A voice with zero jitter reads as synthetic; a voice with normal
    human jitter reads as a person; a voice with slow PERIODIC wobble reads as
    a person who is wrong, and that last one is the Below-the-Kernel setting.
    """
    rng = rng or np.random.default_rng(1)
    n = tl.n
    f0 = np.maximum(tl.f0, 20.0)
    f0 = f0 * (1.0 + jitter * rng.normal(0.0, 1.0, n))
    phase = np.cumsum(f0) / RATE
    p = np.mod(phase, 1.0)
    period_index = np.floor(phase).astype(np.int64)

    # Rosenberg: raised-cosine open phase, cosine-quarter return phase.
    t1, t2 = 0.42, 0.16
    flow = np.zeros(n)
    m1 = p < t1
    flow[m1] = 0.5 * (1.0 - np.cos(np.pi * p[m1] / t1))
    m2 = (p >= t1) & (p < t1 + t2)
    flow[m2] = np.cos(np.pi * (p[m2] - t1) / (2.0 * t2))

    if creak > 0.0:
        alt = np.where(period_index % 2 == 1, 1.0 - 0.85 * creak, 1.0)
        flow *= alt
    if shimmer > 0.0:
        per_period = 1.0 + shimmer * rng.normal(0.0, 1.0, period_index.max() + 2)
        flow *= per_period[period_index]

    # Radiation at the lips is a differentiator (+6 dB/oct); the glottal flow
    # is -12, so the source lands at the -6 dB/oct real speech has.
    src = np.diff(flow, prepend=flow[0])
    return one_pole_lp(src, tilt_hz)


def aspiration_source(tl: Timeline, rng: np.random.Generator) -> np.ndarray:
    """Turbulent noise, pre-shaped by whichever fricative/burst band is active.

    Shaping the noise here rather than only in the formant bank is what makes
    /s/ a sibilant instead of a generic shhh: the fricative band is a property
    of the constriction, not of the vocal tract behind it."""
    n = tl.n
    noise = rng.normal(0.0, 1.0, n)
    spec = np.fft.rfft(noise)
    freqs = np.fft.rfftfreq(n, 1.0 / RATE)

    # Baseline aspiration: gently tilted, a breath rather than white noise.
    base = np.fft.irfft(spec * (1.0 / (1.0 + (freqs / 3200.0) ** 1.4)), n=n)

    # Fricative/burst events get their own band-passed copy, crossfaded in
    # where `tl.fric` is active. Three fixed bands are enough resolution for
    # the classes we generate, and cost three FFTs instead of one per event.
    out = base * 0.55
    bands = [(600, 2600), (2000, 6000), (3800, 11000)]
    copies = []
    for lo, hi in bands:
        mask = np.exp(-0.5 * ((np.log(np.maximum(freqs, 1.0)) -
                               np.log(math.sqrt(lo * hi))) /
                              (0.5 * math.log(hi / lo))) ** 2)
        copies.append(np.fft.irfft(spec * mask, n=n))
    centres = np.array([math.sqrt(lo * hi) for lo, hi in bands])
    fc = np.sqrt(np.maximum(tl.fric[0], 1.0) * np.maximum(tl.fric[1], 1.0))
    active = tl.fric[2] > 0.0
    if np.any(active):
        # Nearest-band selection, smoothed so the band does not switch audibly.
        w = np.zeros((len(bands), n))
        for k, c in enumerate(centres):
            w[k] = np.exp(-0.5 * ((np.log(np.maximum(fc, 1.0)) - math.log(c)) / 0.42) ** 2)
        w *= active
        w /= np.maximum(np.sum(w, axis=0, keepdims=True), 1e-9)
        shaped = sum(w[k] * copies[k] for k in range(len(bands)))
        out = out * (1.0 - active * 0.8) + shaped * tl.fric[2] * 1.5
    return out


def conduit_hum(n: int, root: float = 46.0, partials: int = 11,
                rng: np.random.Generator | None = None) -> np.ndarray:
    """A carrier made of MOTHER's own architecture: a mains-ish harmonic stack
       with slowly beating partials, of the family the ambient beds already
       use. Vocoding THIS instead of noise is the difference between 'a robot
       voice' and 'the building is forming words'."""
    rng = rng or np.random.default_rng(2)
    t = np.arange(n) / RATE
    out = np.zeros(n)
    for k in range(1, partials + 1):
        detune = 1.0 + rng.normal(0.0, 0.0015)
        beat = 1.0 + 0.16 * np.sin(2.0 * np.pi * rng.uniform(0.05, 0.31) * t
                                   + rng.uniform(0, 6.28))
        out += (beat / k ** 1.15) * np.sin(2.0 * np.pi * root * k * detune * t
                                           + rng.uniform(0, 6.28))
    return out / (np.max(np.abs(out)) + 1e-9)


# ===========================================================================
# 3. THE SPECTRAL ENGINE — formant bank / vocoder / whisper, one surface
# ===========================================================================

def stft(x: np.ndarray) -> np.ndarray:
    win = np.hanning(N_FFT + 1)[:-1]
    pad = N_FFT
    xp = np.concatenate([np.zeros(pad), x, np.zeros(pad + N_FFT)])
    n_frames = 1 + (xp.size - N_FFT) // HOP
    idx = np.arange(N_FFT)[None, :] + HOP * np.arange(n_frames)[:, None]
    return np.fft.rfft(xp[idx] * win, axis=1)


def istft(spec: np.ndarray, n: int) -> np.ndarray:
    win = np.hanning(N_FFT + 1)[:-1]
    frames = np.fft.irfft(spec, n=N_FFT, axis=1) * win
    n_frames = frames.shape[0]
    total = HOP * (n_frames - 1) + N_FFT
    out = np.zeros(total)
    norm = np.zeros(total)
    w2 = win ** 2
    for i in range(n_frames):
        out[i * HOP:i * HOP + N_FFT] += frames[i]
        norm[i * HOP:i * HOP + N_FFT] += w2
    out /= np.maximum(norm, 1e-8)
    return out[N_FFT:N_FFT + n]


def resonator_gain(freqs: np.ndarray, f: np.ndarray, bw: np.ndarray) -> np.ndarray:
    """|H| of a 2-pole resonator on a bin grid, peak-normalised.

    `freqs` is (n_bins,), `f`/`bw` are (n_frames,). Returns (n_frames, n_bins).
    Evaluating the actual digital resonator response — rather than dropping a
    Gaussian bump on a log axis, which is what most 'formant' code does — is
    what keeps the skirts and the inter-formant valleys correct, and the
    valleys are where vowel identity actually lives."""
    w = 2.0 * np.pi * freqs[None, :] / RATE
    r = np.exp(-np.pi * bw[:, None] / RATE)
    th = 2.0 * np.pi * f[:, None] / RATE
    z1 = np.exp(-1j * w)
    denom = 1.0 - 2.0 * r * np.cos(th) * z1 + (r ** 2) * z1 ** 2
    h = 1.0 / np.abs(denom)
    peak = 1.0 / ((1.0 - r) * np.sqrt(1.0 + r ** 2 - 2.0 * r * np.cos(2.0 * th)) + 1e-9)
    return h / np.maximum(peak, 1e-9)


def spectral_surface(tl: Timeline, n_frames: int, *, vocoder_bands: int = 0,
                     nasal_zero: bool = True) -> np.ndarray:
    """The time-varying spectral gain every technique shares. (n_frames, n_bins)

    `vocoder_bands > 0` bins the surface into that many log-spaced bands and
    holds each flat. The staircase is not a simplification — it is the sound of
    a vocoder, and blurring it back out would just give us the formant synth
    again with extra steps."""
    freqs = np.fft.rfftfreq(N_FFT, 1.0 / RATE)
    centre = np.clip((np.arange(n_frames) * HOP - N_FFT + N_FFT // 2), 0, tl.n - 1)

    surf = np.zeros((n_frames, freqs.size))
    for k in range(4):
        f = tl.formants[k][centre]
        bw = tl.bandwidths[k][centre]
        amp = tl.famp[k][centre]
        surf += amp[:, None] * resonator_gain(freqs, f, bw)

    # A fifth fixed high resonance keeps sibilance and burst energy alive;
    # without it every fricative gets swallowed by the F4 rolloff.
    surf += 0.10 * resonator_gain(freqs, np.full(n_frames, 4600.0),
                                  np.full(n_frames, 900.0))

    if nasal_zero:
        # Nasal murmur: add a low pole at ~270 Hz and cut an anti-formant near
        # 1 kHz. The ZERO is what makes /m/ and /n/ sound stopped-up rather
        # than merely quiet.
        nz = tl.nasal[centre]
        if np.any(nz > 0.0):
            pole = resonator_gain(freqs, np.full(n_frames, 270.0),
                                  np.full(n_frames, 110.0))
            zero = 1.0 - 0.88 * np.exp(-0.5 * ((freqs - 1000.0) / 420.0) ** 2)
            surf = surf * (1.0 - nz[:, None] * 0.75) \
                + nz[:, None] * (pole * 1.4 * zero[None, :])

    if vocoder_bands > 0:
        edges = np.geomspace(80.0, 11000.0, vocoder_bands + 1)
        binned = np.zeros_like(surf)
        for i in range(vocoder_bands):
            m = (freqs >= edges[i]) & (freqs < edges[i + 1])
            if not np.any(m):
                continue
            # Energy-preserving band level, held flat across the band.
            lvl = np.sqrt(np.mean(surf[:, m] ** 2, axis=1))
            binned[:, m] = lvl[:, None]
        binned[:, freqs < 80.0] = 0.0
        surf = binned

    return surf


def voice(tl: Timeline, *, excitation: str = "glottal", vocoder_bands: int = 0,
          creak: float = 0.0, jitter: float = 0.004, tilt_hz: float = 2600.0,
          carrier: np.ndarray | None = None,
          rng: np.random.Generator | None = None) -> np.ndarray:
    """Run one utterance through the engine. `excitation` is
       glottal | noise | carrier."""
    rng = rng or np.random.default_rng(3)
    n = tl.n
    if excitation == "glottal":
        src = (tl.voicing * glottal_source(tl, creak=creak, jitter=jitter,
                                           tilt_hz=tilt_hz, rng=rng)
               + tl.aspiration * 0.30 * aspiration_source(tl, rng))
    elif excitation == "noise":
        src = aspiration_source(tl, rng) * (0.35 + 0.65 * tl.aspiration)
    else:
        base = carrier if carrier is not None else conduit_hum(n, rng=rng)
        src = base[:n] * 0.85 + 0.15 * aspiration_source(tl, rng)
    src = src * tl.amp

    spec = stft(src)
    surf = spectral_surface(tl, spec.shape[0], vocoder_bands=vocoder_bands)
    return istft(spec * surf, n)


# ===========================================================================
# 4. FILTERS, SPACE, AND THE CASSETTE CHAIN
# ===========================================================================

def one_pole_lp(x: np.ndarray, hz: float) -> np.ndarray:
    """Zero-phase one-pole, done in the frequency domain — this is texture, not
       measurement (the measurement path in bs1770.py uses an exact
       recursion)."""
    if hz >= RATE / 2:
        return x
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(x.size, 1.0 / RATE)
    return np.fft.irfft(spec / np.sqrt(1.0 + (f / hz) ** 2), n=x.size)


def spectral_eq(x: np.ndarray, curve) -> np.ndarray:
    """Apply an arbitrary magnitude curve `curve(freqs_hz) -> linear gain`."""
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(x.size, 1.0 / RATE)
    return np.fft.irfft(spec * curve(f), n=x.size)


def low_shelf(x: np.ndarray, hz: float, db: float) -> np.ndarray:
    g = 10.0 ** (db / 20.0)
    return spectral_eq(x, lambda f: 1.0 + (g - 1.0) / (1.0 + (f / hz) ** 2))


def high_shelf(x: np.ndarray, hz: float, db: float) -> np.ndarray:
    g = 10.0 ** (db / 20.0)
    return spectral_eq(x, lambda f: 1.0 + (g - 1.0) * (f / hz) ** 2 / (1.0 + (f / hz) ** 2))


def band_reject(x: np.ndarray, hz: float, q: float, db: float) -> np.ndarray:
    g = 10.0 ** (db / 20.0)
    return spectral_eq(
        x, lambda f: 1.0 + (g - 1.0) * np.exp(-0.5 * ((np.log(np.maximum(f, 1.0))
                                                       - math.log(hz)) * q) ** 2))


def proximity(x: np.ndarray, amount: float = 1.0) -> np.ndarray:
    """The close-mic low-shelf. A directional capsule 3 cm from a mouth gains
       6-10 dB below 200 Hz; our ears read that as INTIMATE long before they
       read it as bassy. It is the whole trick of the Below-the-Kernel tier —
       she is not louder, she is nearer."""
    return low_shelf(x, 210.0, 7.5 * amount)


def make_ir(*, seconds: float, rt60_low: float, rt60_high: float,
            predelay: float, taps: int, damp_hz: float,
            resonances: list[tuple[float, float]] | None = None,
            seed: int = 0) -> np.ndarray:
    """Procedural impulse response: octave-banded exponentially decaying noise
       plus early reflections.

       Frequency-dependent decay (long lows, short highs) is the entire
       difference between 'reverb' and 'a plausible concrete room'. The
       optional `resonances` list adds narrow peaks — used to give the
       in-the-walls beds their pipe/duct formants, so she is not just distant,
       she is behind a specific piece of architecture."""
    rng = np.random.default_rng(seed)
    n = int(seconds * RATE)
    noise = rng.normal(0.0, 1.0, n)
    spec = np.fft.rfft(noise)
    freqs = np.fft.rfftfreq(n, 1.0 / RATE)
    t = np.arange(n) / RATE
    ir = np.zeros(n)
    centres = [63, 125, 250, 500, 1000, 2000, 4000, 8000]
    for fc in centres:
        u = math.log(fc / 63.0) / math.log(8000.0 / 63.0)
        rt60 = rt60_low + (rt60_high - rt60_low) * u
        mask = np.exp(-0.5 * ((np.log(np.maximum(freqs, 1.0)) - math.log(fc)) / 0.42) ** 2)
        band = np.fft.irfft(spec * mask, n=n)
        ir += band * np.exp(-6.907755 * t / max(rt60, 0.02))
    # Early reflections: a handful of discrete, decaying taps. Without these a
    # convolution reverb reads as a wash with no room shape.
    for k in range(taps):
        d = int((predelay + rng.uniform(0.004, 0.11)) * RATE)
        if d < n:
            ir[d] += rng.choice([-1.0, 1.0]) * 0.7 * math.exp(-3.0 * k / taps)
    ir[:int(predelay * RATE)] = 0.0
    ir = one_pole_lp(ir, damp_hz)
    for hz, q in (resonances or []):
        ir = band_reject(ir, hz, q, +7.0)
    return ir / (np.sqrt(np.sum(ir ** 2)) + 1e-9)


def convolve(x: np.ndarray, ir: np.ndarray) -> np.ndarray:
    n = 1
    while n < x.size + ir.size:
        n *= 2
    y = np.fft.irfft(np.fft.rfft(x, n) * np.fft.rfft(ir, n), n=n)
    return y[:x.size]


def _cubic_resample(x: np.ndarray, pos: np.ndarray) -> np.ndarray:
    """Catmull-Rom resampling at fractional sample positions. Linear
       interpolation here would low-pass the wow modulation into a dull hiss —
       audible, and exactly the artefact that makes cheap tape emulation sound
       like a cheap tape emulation."""
    i = np.floor(pos).astype(np.int64)
    f = pos - i
    n = x.size
    p0 = x[np.clip(i - 1, 0, n - 1)]
    p1 = x[np.clip(i, 0, n - 1)]
    p2 = x[np.clip(i + 1, 0, n - 1)]
    p3 = x[np.clip(i + 2, 0, n - 1)]
    return (p1 + 0.5 * f * (p2 - p0 + f * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3
                                           + f * (3.0 * (p1 - p2) + p3 - p0))))


def tape_compress(x: np.ndarray, threshold: float = 0.30,
                  ratio: float = 4.0) -> np.ndarray:
    """The record amplifier plus the tape's own headroom curve.

    Not a mastering limiter — a cassette physically cannot pass the 22 dB
    crest factor that raw synthesised stop-bursts have, and pretending it can
    is what leaves a candidate 2 dB short of its loudness target because one
    /t/ burst ate all the headroom. The detector is fast (3 ms) so it catches
    bursts, and the gain curve is smoothed zero-phase over 9 ms, which behaves
    like the look-ahead a real record amp gets for free by being slow.
    """
    det = one_pole_lp(np.abs(x), 1.0 / 0.003)
    over = np.maximum(det / threshold, 1.0)
    gain = over ** (1.0 / ratio - 1.0)
    w = max(int(0.009 * RATE), 3)
    kern = np.hanning(w) / np.sum(np.hanning(w))
    return x * np.convolve(gain, kern, mode="same")


def cassette(x: np.ndarray, *, wow: float = 0.0022, wow_hz: float = 0.52,
             flutter: float = 0.0011, flutter_hz: float = 7.4,
             scrape: float = 0.00035, dropouts: float = 0.35,
             dropout_depth: float = 0.75, hiss_db: float = -58.0,
             sat: float = 1.4, head_bump_db: float = 3.0,
             azimuth_hz: float = 8200.0, print_through_db: float = -46.0,
             spin_up: float = 0.0, comp: float = 0.30, comp_ratio: float = 4.0,
             seed: int = 0) -> np.ndarray:
    """The cassette-futurism post chain, in the order a real deck applies it.

    Order matters and is not arbitrary: speed error and saturation happen at
    RECORD time (so they must precede the playback EQ and the head noise),
    print-through is a PRE-echo because tape layers bleed onto the layer that
    passes under them on the reel, and hiss is added at the head, after
    everything the tape did to the signal. Getting the order wrong gives you a
    'lo-fi filter', which anyone can hear is a plug-in.
    """
    rng = np.random.default_rng(seed)
    n = x.size
    t = np.arange(n) / RATE
    # Work at unity peak so the compressor threshold means the same thing for
    # every candidate; the driver loudness-normalises afterwards anyway.
    x = x / (float(np.max(np.abs(x))) + 1e-12)

    # --- 0. record amplifier / tape headroom ------------------------------
    if comp > 0.0:
        x = tape_compress(x, threshold=comp, ratio=comp_ratio)

    # --- 1. transport speed error (record side) --------------------------
    # Wow is the reel; flutter is the capstan; scrape is the tape rubbing the
    # heads. Three separate frequencies because a single LFO reads as a chorus
    # pedal.
    warp = np.zeros(n)
    for depth, hz, phase in ((wow, wow_hz, rng.uniform(0, 6.28)),
                             (wow * 0.55, wow_hz * 2.7, rng.uniform(0, 6.28)),
                             (flutter, flutter_hz, rng.uniform(0, 6.28)),
                             (scrape, 41.0, rng.uniform(0, 6.28))):
        if depth > 0.0:
            warp += depth / (2.0 * math.pi * hz) * np.sin(2.0 * math.pi * hz * t + phase)
    if spin_up > 0.0:
        # The capstan getting up to speed: the first moment of playback runs
        # slow and settles. Used sparingly — it is a strong "someone just
        # pressed PLAY" signal, and MOTHER pressing play on herself is a
        # specific idea, not a default.
        warp += spin_up * np.maximum(0.0, 1.0 - t / 0.9) ** 2
    speed_curve = warp
    y = _cubic_resample(x, np.clip(np.arange(n) + speed_curve * RATE, 0, n - 1))

    # --- 2. tape saturation, pre/de-emphasised ---------------------------
    # Real tape compresses highs harder than lows. Boost highs, saturate, cut
    # them back: the HF is what gets squashed, and that self-limiting sizzle is
    # the sound. A bare tanh over the full band just sounds like distortion.
    if sat > 0.0:
        pre = high_shelf(y, 2500.0, 8.0)
        pre = np.tanh(pre * sat) / math.tanh(sat)
        y = high_shelf(pre, 2500.0, -8.0)

    # --- 3. print-through (PRE-echo) -------------------------------------
    if print_through_db > -90.0:
        lag = int(0.62 * RATE)          # roughly one wrap of the reel
        pre_echo = np.zeros(n)
        pre_echo[:n - lag] = y[lag:]
        y = y + one_pole_lp(pre_echo, 2600.0) * 10.0 ** (print_through_db / 20.0)

    # --- 4. dropouts ------------------------------------------------------
    # Oxide shedding / tape lifting off the head. HF goes FIRST and the level
    # follows, so a partial dropout is a dull patch, not a gap. Total dropouts
    # are rarer and are the only ones that read as a hole.
    if dropouts > 0.0:
        env = np.ones(n)
        hf = np.ones(n)
        count = int(dropouts * (n / RATE) * 1.6)
        for _ in range(count):
            c = rng.integers(0, n)
            width = int(rng.uniform(0.012, 0.16) * RATE)
            lo, hi = max(0, c - width // 2), min(n, c + width // 2)
            if hi <= lo:
                continue
            u = np.linspace(-1.0, 1.0, hi - lo)
            bell = np.exp(-3.0 * u ** 2)
            severity = rng.random() ** 1.8
            hf[lo:hi] = np.minimum(hf[lo:hi], 1.0 - bell * (0.55 + 0.45 * severity))
            env[lo:hi] = np.minimum(env[lo:hi],
                                    1.0 - bell * dropout_depth * severity)
        dull = one_pole_lp(y, 1500.0)
        y = (y * hf + dull * (1.0 - hf)) * env

    # --- 5. playback head EQ ---------------------------------------------
    y = low_shelf(y, 78.0, head_bump_db)              # head bump
    y = one_pole_lp(y, azimuth_hz)                    # azimuth misalignment
    y = spectral_eq(y, lambda f: 1.0 / (1.0 + (60.0 / np.maximum(f, 1.0)) ** 3))

    # --- 6. hiss, modulated by transport speed ---------------------------
    if hiss_db > -90.0:
        hiss = rng.normal(0.0, 1.0, n)
        hiss = spectral_eq(hiss, lambda f: np.clip((f / 300.0) ** 0.5, 0.0, 1.0)
                           / np.sqrt(1.0 + (f / 11000.0) ** 4))
        hiss /= (np.sqrt(np.mean(hiss ** 2)) + 1e-9)
        # Hiss level tracks speed on a real deck — a detail nobody names but
        # everybody hears as "this is a physical machine".
        hiss *= 1.0 + 6.0 * (speed_curve - float(np.mean(speed_curve)))
        y = y + hiss * 10.0 ** (hiss_db / 20.0)
    return y


def fade_edges(x: np.ndarray, ms: float = 18.0) -> np.ndarray:
    k = max(int(RATE * ms / 1000.0), 1)
    k = min(k, x.size // 2)
    w = np.linspace(0.0, 1.0, k)
    x = x.copy()
    x[:k] *= w
    x[-k:] *= w[::-1]
    return x


def loop_seam(x: np.ndarray, ms: float = 900.0) -> np.ndarray:
    """Crossfade the tail over the head so an ambient bed loops without a seam.
       Costs `ms` of length; worth it — a bed with an audible loop point stops
       being ambience and becomes a cue the moment a player notices it."""
    k = int(RATE * ms / 1000.0)
    if k * 2 >= x.size:
        return fade_edges(x)
    head, tail, body = x[:k], x[-k:], x[k:-k]
    w = np.linspace(0.0, 1.0, k)
    return np.concatenate([tail * (1.0 - w) + head * w, body])


# ===========================================================================
# 5. THE CANDIDATES
# ===========================================================================

#: Loudness targets per intensity tier. Deliberately far apart: the tiers must
#: be distinguishable with the player's hand nowhere near a volume control.
#: Ceiling is -3.0 dBTP, not the broadcast -1.0, because these still have to
#: survive a Vorbis encode, a bus, and a 3D attenuation curve on top.
TARGETS = {"ambient": -34.0, "address": -23.0, "subzero": -27.0}
CEILING_DBTP = -3.0


def bark(entry_id: str) -> str:
    """Fetch a bark's canonical text from the corpus. Fails loudly — a silent
       fallback would let a renamed entry quietly change what she says."""
    with open(CORPUS, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    for e in data["entries"]:
        if e.get("id") == entry_id:
            return str(e["text"])
    raise KeyError("no corpus entry %r" % entry_id)


def _walls_ir(seed: int) -> np.ndarray:
    """Behind-the-panel space: long, dark, with duct resonances."""
    return make_ir(seconds=2.6, rt60_low=2.3, rt60_high=0.42, predelay=0.018,
                   taps=14, damp_hz=2400.0,
                   resonances=[(190.0, 3.2), (430.0, 3.6), (880.0, 4.0)],
                   seed=seed)


def _room_ir(seed: int) -> np.ndarray:
    """A normal hard room — the address tier lives here."""
    return make_ir(seconds=1.4, rt60_low=1.1, rt60_high=0.30, predelay=0.010,
                   taps=10, damp_hz=6200.0, seed=seed)


def _tight_ir(seed: int) -> np.ndarray:
    """Almost nothing: a hair of early energy so it is not anechoic-dead, and
       no tail at all. Intimacy is the ABSENCE of a room."""
    return make_ir(seconds=0.32, rt60_low=0.18, rt60_high=0.07, predelay=0.003,
                   taps=6, damp_hz=7000.0, seed=seed)


def c_amb_manifest_walls() -> np.ndarray:
    """A1 — the baseline murmur. She is talking to herself, somewhere else."""
    rng = np.random.default_rng(1001)
    out = []
    for i, bid in enumerate(["ambient.manifest", "ambient.floorplan",
                             "ambient.warmfloor", "ambient.variance"]):
        tl = build_timeline(parse_utterance(bark(bid)), syl_dur=0.175,
                            f0_base=104.0, declination=-0.18,
                            accent_semitones=1.6, terminal_fall=-3.0,
                            breathiness=0.22, lead_in=0.6, tail=1.8,
                            rng=np.random.default_rng(2000 + i))
        out.append(voice(tl, creak=0.12, jitter=0.003, tilt_hz=1900.0,
                         rng=np.random.default_rng(3000 + i)))
        out.append(np.zeros(int(RATE * 1.6)))
    y = np.concatenate(out)
    y = convolve(y, _walls_ir(11)) * 1.2 + y * 0.18
    y = one_pole_lp(y, 3400.0)
    y = band_reject(y, 340.0, 2.6, -7.0)       # the panel between you and her
    y = cassette(y, wow=0.0026, dropouts=0.30, hiss_db=-56.0, sat=1.2, seed=11)
    return loop_seam(y)


def c_amb_vocoder_conduit() -> np.ndarray:
    """A2 — the architecture forms the words. Vocoded conduit hum."""
    rng = np.random.default_rng(1002)
    out = []
    for i, bid in enumerate(["ambient.draw", "ambient.key", "ambient.lighting"]):
        tl = build_timeline(parse_utterance(bark(bid)), syl_dur=0.195,
                            f0_base=98.0, declination=-0.12,
                            accent_semitones=1.2, terminal_fall=-2.0,
                            breathiness=0.16, lead_in=0.5, tail=1.4,
                            rng=np.random.default_rng(2100 + i))
        car = conduit_hum(tl.n, root=46.0, partials=13,
                          rng=np.random.default_rng(2200 + i))
        out.append(voice(tl, excitation="carrier", carrier=car,
                         vocoder_bands=22, rng=np.random.default_rng(3100 + i)))
        out.append(np.zeros(int(RATE * 2.1)))
    y = np.concatenate(out)
    y = convolve(y, _walls_ir(12)) * 0.9 + y * 0.35
    y = low_shelf(y, 120.0, 4.0)
    y = cassette(y, wow=0.0018, flutter=0.0008, dropouts=0.22,
                 hiss_db=-60.0, sat=1.1, azimuth_hz=9000.0, seed=12)
    return loop_seam(y)


def c_amb_whisper_walls() -> np.ndarray:
    """A3 — 'she's whispering in the walls'. No pitch at all, ever."""
    out = []
    for i, bid in enumerate(["ambient.manifest", "ambient.key",
                             "mercy.otherfloors", "ambient.workorder",
                             "ambient.floorplan"]):
        tl = build_timeline(parse_utterance(bark(bid)), syl_dur=0.150,
                            f0_base=100.0, whisper=1.0, breathiness=0.9,
                            accent_semitones=0.0, terminal_fall=0.0,
                            declination=0.0, lead_in=0.4, tail=1.1,
                            rng=np.random.default_rng(2300 + i))
        out.append(voice(tl, excitation="noise",
                         rng=np.random.default_rng(3300 + i)))
        out.append(np.zeros(int(RATE * 1.9)))
    y = np.concatenate(out)
    y = convolve(y, _walls_ir(13)) * 1.5 + y * 0.10
    y = band_reject(y, 2200.0, 2.0, -5.0)
    y = one_pole_lp(y, 6800.0)
    y = cassette(y, wow=0.0030, dropouts=0.42, hiss_db=-52.0, sat=0.9,
                 print_through_db=-52.0, seed=13)
    return loop_seam(y)


def c_amb_choir_processes() -> np.ndarray:
    """A4 — she is not one voice. Three instances, slightly out of step.

    The offsets are 40-90 ms: far enough that the ear separates them into
    distinct mouths, close enough that they are obviously saying the same
    sentence. Under 20 ms it would just be a chorus effect."""
    text = bark("ambient.draw")
    layers = []
    for i, (off, cents, rate_scale) in enumerate(
            [(0.0, 0.0, 1.0), (0.052, -14.0, 1.035), (0.089, +11.0, 0.968)]):
        tl = build_timeline(parse_utterance(text), syl_dur=0.170 * rate_scale,
                            f0_base=102.0 * 2.0 ** (cents / 1200.0),
                            declination=-0.16, accent_semitones=1.5,
                            terminal_fall=-2.5, breathiness=0.25,
                            lead_in=0.5 + off, tail=1.6,
                            rng=np.random.default_rng(2400 + i))
        layers.append(voice(tl, creak=0.08 + 0.06 * i, jitter=0.0035,
                            tilt_hz=1700.0, rng=np.random.default_rng(3400 + i)))
    n = max(len(l) for l in layers)
    y = np.zeros(n)
    for l in layers:
        y[:l.size] += l * 0.62
    y = np.concatenate([y, np.zeros(int(RATE * 2.4)), y[:int(RATE * 3.0)] * 0.7])
    y = convolve(y, _walls_ir(14)) * 1.25 + y * 0.2
    y = one_pole_lp(y, 3800.0)
    y = cassette(y, wow=0.0024, dropouts=0.28, hiss_db=-56.0, sat=1.2, seed=14)
    return loop_seam(y)


def c_amb_backmask() -> np.ndarray:
    """A5 — per-syllable time reversal.

    Each syllable is reversed in place; the syllables stay in order. The
    rhythm, pitch contour and vowel sequence all survive, but every attack
    becomes a swell. The brain still parses it as a sentence and cannot say
    why it is wrong — which is the entire brief for a quiet stretch."""
    text = bark("ambient.warmfloor")
    tl = build_timeline(parse_utterance(text), syl_dur=0.185, f0_base=100.0,
                        declination=-0.14, accent_semitones=1.8,
                        terminal_fall=-2.0, breathiness=0.28,
                        lead_in=0.5, tail=1.6, rng=np.random.default_rng(2500))
    y = voice(tl, creak=0.1, jitter=0.003, tilt_hz=1800.0,
              rng=np.random.default_rng(3500))
    # Reverse in ~one-syllable slices, crossfading the seams.
    seg = int(0.19 * RATE)
    xf = int(0.012 * RATE)
    chunks = []
    for i in range(0, y.size - seg, seg):
        chunks.append(y[i:i + seg][::-1])
    z = np.zeros(len(chunks) * seg)
    w = np.linspace(0.0, 1.0, xf)
    for i, c in enumerate(chunks):
        c = c.copy()
        c[:xf] *= w
        c[-xf:] *= w[::-1]
        z[i * seg:i * seg + seg] += c
    z = np.concatenate([z, np.zeros(int(RATE * 2.6))])
    z = np.tile(z, 2)
    z = convolve(z, _walls_ir(15)) * 1.3 + z * 0.15
    z = one_pole_lp(z, 3200.0)
    z = cassette(z, wow=0.0032, dropouts=0.36, hiss_db=-55.0, sat=1.1, seed=15)
    return loop_seam(z)


def c_addr_breathe() -> np.ndarray:
    """D1 — the reference voice. '{CALLSIGN}. YOU BREATHE TOO LOUDLY.'

    If exactly one of these fifteen becomes 'MOTHER's voice', it should be this
    one: full glottal source, correct declination, a real terminal fall, light
    creak, and just enough cassette to place it in the fiction. Everything else
    in the set is a deviation FROM this."""
    tl = build_timeline(parse_utterance(bark("addr.breathe")), syl_dur=0.162,
                        f0_base=128.0, declination=-0.22,
                        accent_semitones=2.8, terminal_fall=-4.5,
                        breathiness=0.13, lead_in=0.30, tail=0.75,
                        rng=np.random.default_rng(2600))
    y = voice(tl, creak=0.22, jitter=0.0028, tilt_hz=2800.0,
              rng=np.random.default_rng(3600))
    y = convolve(y, _room_ir(21)) * 0.42 + y * 1.0
    y = proximity(y, 0.55)
    y = cassette(y, wow=0.0016, flutter=0.0009, dropouts=0.14,
                 hiss_db=-62.0, sat=1.5, azimuth_hz=8800.0, seed=21)
    return fade_edges(y)


def c_addr_stop_touching() -> np.ndarray:
    """D2 — flat terminal. '{CALLSIGN}. STOP TOUCHING THINGS.'

    `terminal_fall = 0`. Every human declarative falls at the end; this one
    just stops, at pitch, as if the sentence were an entry in a list that
    continues somewhere you cannot hear. Short, clipped, hard bursts."""
    tl = build_timeline(parse_utterance(bark("addr.stop_touching")),
                        syl_dur=0.132, f0_base=134.0, declination=-0.06,
                        accent_semitones=2.0, terminal_fall=0.0,
                        final_lengthen=1.05, breathiness=0.08,
                        lead_in=0.22, tail=0.55,
                        rng=np.random.default_rng(2700))
    y = voice(tl, creak=0.18, jitter=0.0016, tilt_hz=3400.0,
              rng=np.random.default_rng(3700))
    y = convolve(y, _room_ir(22)) * 0.30 + y * 1.0
    y = high_shelf(y, 3000.0, 2.5)
    y = cassette(y, wow=0.0011, dropouts=0.10, hiss_db=-64.0, sat=1.7,
                 print_through_db=-90.0, seed=22)
    return fade_edges(y)


def c_addr_hunt_told() -> np.ndarray:
    """D3 — INVERTED declination. 'I HAVE TOLD SOMETHING WHERE YOU ARE...'

    Pitch RISES across the whole utterance instead of falling. Humans do this
    for questions and for lists-that-continue, never for a calm statement of
    fact, so a rising statement reads as pressure without a single decibel of
    extra level. This is the hunt-escalation candidate."""
    tl = build_timeline(parse_utterance(bark("hunt.told")), syl_dur=0.145,
                        f0_base=120.0, declination=+0.20,
                        accent_semitones=2.2, terminal_fall=+1.5,
                        final_lengthen=1.35, breathiness=0.10,
                        lead_in=0.25, tail=0.8,
                        rng=np.random.default_rng(2800))
    y = voice(tl, creak=0.14, jitter=0.0022, tilt_hz=3100.0,
              rng=np.random.default_rng(3800))
    y = convolve(y, _room_ir(23)) * 0.34 + y * 1.0
    y = proximity(y, 0.35)
    y = cassette(y, wow=0.0014, flutter=0.0013, dropouts=0.18,
                 hiss_db=-61.0, sat=1.6, seed=23)
    return fade_edges(y)


def c_addr_epitaph_record() -> np.ndarray:
    """D4 — the filing voice. 'REMOVED FROM THE FLOOR. NOT FROM THE RECORD.'

    Slow, low, heavy final lengthening, and the tape running very slightly
    slow. She is not gloating; she is updating a manifest. Plays over a
    crewmate's decompile."""
    tl = build_timeline(parse_utterance(bark("epi.record")), syl_dur=0.205,
                        f0_base=108.0, declination=-0.28,
                        accent_semitones=1.9, terminal_fall=-6.0,
                        final_lengthen=2.4, breathiness=0.20,
                        lead_in=0.4, tail=1.3,
                        rng=np.random.default_rng(2900))
    y = voice(tl, creak=0.34, jitter=0.0030, tilt_hz=2100.0,
              rng=np.random.default_rng(3900))
    y = convolve(y, _room_ir(24)) * 0.55 + y * 0.95
    y = low_shelf(y, 260.0, 3.5)
    y = one_pole_lp(y, 6000.0)
    y = cassette(y, wow=0.0038, wow_hz=0.31, flutter=0.0012, dropouts=0.20,
                 hiss_db=-58.0, sat=1.3, spin_up=0.0009, seed=24)
    return fade_edges(y)


def c_addr_doubled_mercy() -> np.ndarray:
    """D5 — two mouths, one sentence. 'I HAVE CALLED THEM OFF...'

    A voiced take and a whispered take of the identical timeline, sample-
    aligned. The whisper carries no reverb, so it sits INSIDE the listener's
    head while the voiced layer sits in the room. Two distances at once is a
    thing no single speaker can be, and it is deeply unpleasant in the good
    way."""
    text = bark("mercy.notgrateful")
    seed_rng = np.random.default_rng(3000)
    syls = parse_utterance(text)
    voiced_tl = build_timeline(syls, syl_dur=0.168, f0_base=118.0,
                               declination=-0.20, accent_semitones=2.4,
                               terminal_fall=-4.0, breathiness=0.15,
                               lead_in=0.3, tail=0.9, rng=seed_rng)
    whisper_tl = build_timeline(parse_utterance(text), syl_dur=0.168,
                                f0_base=118.0, declination=-0.20,
                                accent_semitones=2.4, terminal_fall=-4.0,
                                breathiness=0.9, whisper=1.0,
                                lead_in=0.3, tail=0.9,
                                rng=np.random.default_rng(3000))
    a = voice(voiced_tl, creak=0.20, jitter=0.0026, tilt_hz=2500.0,
              rng=np.random.default_rng(4000))
    b = voice(whisper_tl, excitation="noise", rng=np.random.default_rng(4001))
    n = max(a.size, b.size)
    a = np.pad(a, (0, n - a.size))
    b = np.pad(b, (0, n - b.size))
    wet = convolve(a, _room_ir(25)) * 0.48 + a
    dry = proximity(high_shelf(b, 4000.0, 3.0), 1.0) * 0.85
    y = wet + dry
    y = cassette(y, wow=0.0018, dropouts=0.16, hiss_db=-60.0, sat=1.4, seed=25)
    return fade_edges(y)


def c_sub_intimate_notfromme() -> np.ndarray:
    """K1 — the intimacy reference. 'I DO NOT GUARD YOU FROM ME.'

    An audible breath INTAKE before the phrase (a mouth needs air; a machine
    does not, and a machine that takes a breath anyway is the whole Below-the-
    Kernel thesis), then a near-whisper with a thread of voicing, full
    proximity shelf, and no room at all."""
    tl = build_timeline(parse_utterance(bark("leak.not_from_me")),
                        syl_dur=0.190, f0_base=88.0, declination=-0.16,
                        accent_semitones=1.4, terminal_fall=-3.0,
                        breathiness=0.75, whisper=0.55,
                        lead_in=0.95, tail=1.0,
                        rng=np.random.default_rng(3100))
    y = voice(tl, creak=0.45, jitter=0.0060, tilt_hz=1500.0,
              rng=np.random.default_rng(4100))

    # The intake. Rising noise through a slowly opening low band — an inhale is
    # a filter sweep, not a fade.
    n_in = int(0.62 * RATE)
    rng = np.random.default_rng(4102)
    breath = rng.normal(0.0, 1.0, n_in)
    u = np.linspace(0.0, 1.0, n_in)
    breath = one_pole_lp(breath, 900.0) * (np.sin(np.pi * u) ** 1.6)
    breath += one_pole_lp(rng.normal(0.0, 1.0, n_in), 2600.0) * 0.35 * u ** 2
    start = int(0.14 * RATE)
    y[start:start + n_in] += breath * 0.42

    y = convolve(y, _tight_ir(31)) * 0.22 + y * 1.0
    y = proximity(y, 1.25)
    y = high_shelf(y, 5200.0, 2.0)      # lip and tongue detail, very close
    y = cassette(y, wow=0.0012, dropouts=0.10, hiss_db=-63.0, sat=1.2,
                 azimuth_hz=11000.0, print_through_db=-50.0, seed=31)
    return fade_edges(y)


def c_sub_subharmonic_ballast() -> np.ndarray:
    """K2 — a body far too large. 'YOU THINK THE VAULTS ARE THE POINT...'

    F0 at 41 Hz — below any human larynx — with the FORMANTS left where a
    normal-sized head puts them. The mismatch is the horror: the resonator says
    'person', the source says 'something the size of a room'. Heavy creak makes
    the individual glottal pulses audible as separate events, which at this
    pitch they are."""
    tl = build_timeline(parse_utterance(bark("leak.ballast")), syl_dur=0.215,
                        f0_base=41.0, declination=-0.14,
                        accent_semitones=1.5, terminal_fall=-3.5,
                        final_lengthen=2.1, breathiness=0.30,
                        lead_in=0.5, tail=1.4,
                        rng=np.random.default_rng(3200))
    y = voice(tl, creak=0.55, jitter=0.0035, tilt_hz=1600.0,
              rng=np.random.default_rng(4200))
    y = convolve(y, _tight_ir(32)) * 0.28 + y * 1.0
    y = low_shelf(y, 150.0, 6.0)
    y = cassette(y, wow=0.0020, dropouts=0.14, hiss_db=-60.0, sat=1.6,
                 head_bump_db=5.0, seed=32)
    return fade_edges(y)


def c_sub_counting_below() -> np.ndarray:
    """K3 — the counting thing. 'SOMETHING BELOW IS ALSO COUNTING...'

    `quantise = 1.0`: every syllable is the same length, on a grid, with the
    pauses squeezed. No stress-timing, no final lengthening to speak of. It is
    the rhythm of something reading a list, and it is not MOTHER — she has
    rhythm. Whatever this is does not, and the corpus line says so out loud."""
    tl = build_timeline(parse_utterance(bark("leak.also_counting")),
                        syl_dur=0.165, f0_base=72.0, declination=-0.02,
                        accent_semitones=0.5, terminal_fall=-0.5,
                        final_lengthen=1.05, quantise=1.0,
                        breathiness=0.35, whisper=0.25,
                        lead_in=0.5, tail=1.1,
                        rng=np.random.default_rng(3300))
    y = voice(tl, creak=0.30, jitter=0.0008, tilt_hz=1800.0,
              rng=np.random.default_rng(4300))
    y = convolve(y, _tight_ir(33)) * 0.30 + y * 1.0
    y = proximity(y, 0.9)
    y = band_reject(y, 1400.0, 2.4, -4.0)
    y = cassette(y, wow=0.0009, flutter=0.0006, dropouts=0.12,
                 hiss_db=-62.0, sat=1.3, seed=33)
    return fade_edges(y)


def c_sub_swarm_adjacent() -> np.ndarray:
    """K4 — seven whisperers converging. 'I WAS NOT BUILT PARANOID...'

    Seven whispered takes, scattered across ~180 ms of onset offset, whose
    offsets are RAMPED TO ZERO across the utterance so they arrive at the final
    two syllables in perfect unison. The scare is not the swarm; it is the
    swarm agreeing."""
    text = bark("leak.adjacent")
    n_voices = 7
    takes = []
    for i in range(n_voices):
        rng = np.random.default_rng(3400 + i)
        tl = build_timeline(parse_utterance(text),
                            syl_dur=0.180 * (1.0 + 0.05 * (i / n_voices - 0.5)),
                            f0_base=90.0, whisper=1.0, breathiness=0.95,
                            accent_semitones=0.8, terminal_fall=-1.0,
                            declination=-0.08, lead_in=0.5, tail=1.2, rng=rng)
        takes.append(voice(tl, excitation="noise",
                           rng=np.random.default_rng(4400 + i)))
    n = max(t.size for t in takes) + int(0.30 * RATE)
    y = np.zeros(n)
    for i, tk in enumerate(takes):
        # Offset shrinks to zero over the take: the ramp IS the convergence.
        off0 = (i - n_voices // 2) * 0.028
        pos = np.arange(tk.size) + off0 * RATE * np.linspace(1.0, 0.0, tk.size) ** 0.7
        warped = _cubic_resample(tk, np.clip(pos, 0, tk.size - 1))
        y[:warped.size] += warped * (0.85 if i == n_voices // 2 else 0.42)
    y = convolve(y, _tight_ir(34)) * 0.26 + y * 1.0
    y = proximity(y, 1.1)
    y = one_pole_lp(y, 9000.0)
    y = cassette(y, wow=0.0016, dropouts=0.18, hiss_db=-59.0, sat=1.1, seed=34)
    return fade_edges(y)


def c_sub_tape_eaten() -> np.ndarray:
    """K5 — the recording fails. 'THE RINGS DO NOT STOP AT ZERO.'

    Catastrophic transport: deep wow, dense HF-first dropouts, a spin-up
    wobble, and print-through loud enough to hear the sentence arrive BEFORE
    it arrives. Diegetically the medium itself is being eaten while she says
    the one thing she is not supposed to say."""
    tl = build_timeline(parse_utterance(bark("leak.not_zero")), syl_dur=0.200,
                        f0_base=84.0, declination=-0.18,
                        accent_semitones=1.8, terminal_fall=-4.0,
                        final_lengthen=2.2, breathiness=0.35,
                        lead_in=0.7, tail=1.6,
                        rng=np.random.default_rng(3500))
    y = voice(tl, creak=0.40, jitter=0.0080, tilt_hz=1700.0,
              rng=np.random.default_rng(4500))
    y = convolve(y, _tight_ir(35)) * 0.25 + y * 1.0
    y = proximity(y, 0.8)
    y = cassette(y, wow=0.0115, wow_hz=0.37, flutter=0.0042, flutter_hz=6.1,
                 scrape=0.0011, dropouts=1.6, dropout_depth=0.95,
                 hiss_db=-49.0, sat=2.2, head_bump_db=5.0,
                 azimuth_hz=5200.0, print_through_db=-34.0,
                 spin_up=0.0026, seed=35)
    return fade_edges(y)


#: id -> (tier, builder, one-line listening note)
CANDIDATES: dict[str, tuple[str, object, str]] = {
    "mv_amb_manifest_walls":    ("ambient", c_amb_manifest_walls,
                                 "baseline murmur behind a panel; duct resonances"),
    "mv_amb_vocoder_conduit":   ("ambient", c_amb_vocoder_conduit,
                                 "22-band vocoder on the conduit hum; the building speaks"),
    "mv_amb_whisper_walls":     ("ambient", c_amb_whisper_walls,
                                 "unvoiced only; 'she's whispering in the walls'"),
    "mv_amb_choir_processes":   ("ambient", c_amb_choir_processes,
                                 "three instances 40-90 ms apart; she is not one voice"),
    "mv_amb_backmask":          ("ambient", c_amb_backmask,
                                 "per-syllable reversal; rhythm survives, attacks do not"),
    "mv_addr_breathe":          ("address", c_addr_breathe,
                                 "the reference voice; full contour, light creak"),
    "mv_addr_stop_touching":    ("address", c_addr_stop_touching,
                                 "flat terminal — the sentence does not end, it stops"),
    "mv_addr_hunt_told":        ("address", c_addr_hunt_told,
                                 "inverted declination; rising statement = pressure"),
    "mv_addr_epitaph_record":   ("address", c_addr_epitaph_record,
                                 "slow, low, filing you away; tape runs slightly slow"),
    "mv_addr_doubled_mercy":    ("address", c_addr_doubled_mercy,
                                 "voiced in the room + whisper inside your head"),
    "mv_sub_intimate_notfromme": ("subzero", c_sub_intimate_notfromme,
                                  "breath intake, then a near-whisper with no room"),
    "mv_sub_subharmonic_ballast": ("subzero", c_sub_subharmonic_ballast,
                                   "41 Hz source, human-sized formants; wrong body"),
    "mv_sub_counting_below":    ("subzero", c_sub_counting_below,
                                 "metronomic syllables; it counts, it does not speak"),
    "mv_sub_swarm_adjacent":    ("subzero", c_sub_swarm_adjacent,
                                 "seven whisperers converging into unison"),
    "mv_sub_tape_eaten":        ("subzero", c_sub_tape_eaten,
                                 "the medium fails mid-sentence; print-through pre-echo"),
}


# ===========================================================================
# 6. ANALYSIS THUMBNAILS (waveform + spectrogram contact sheet)
# ===========================================================================

def _phosphor(v: np.ndarray) -> np.ndarray:
    """Amber CRT ramp — the HUD's own palette, so the analysis sheet looks like
       it came out of the same machine as the game."""
    v = np.clip(v, 0.0, 1.0)
    r = np.clip(v * 2.4, 0, 1) ** 0.85
    g = np.clip((v - 0.26) * 1.55, 0, 1) ** 1.15
    b = np.clip((v - 0.74) * 2.6, 0, 1) ** 1.5
    return np.stack([r, g, b], axis=-1)


def analysis_tiles(x: np.ndarray, width: int, wave_h: int, spec_h: int):
    from PIL import Image

    # --- waveform (min/max envelope, not decimation — decimation lies) ----
    cols = np.array_split(x, width) if x.size >= width else [x]
    lo = np.array([c.min() if c.size else 0.0 for c in cols])
    hi = np.array([c.max() if c.size else 0.0 for c in cols])
    if len(lo) < width:
        lo = np.pad(lo, (0, width - len(lo)))
        hi = np.pad(hi, (0, width - len(hi)))
    peak = max(float(np.max(np.abs(x))), 1e-6)
    img = np.zeros((wave_h, width, 3))
    mid = wave_h // 2
    for i in range(width):
        a = int(mid - hi[i] / peak * (wave_h // 2 - 1))
        b = int(mid - lo[i] / peak * (wave_h // 2 - 1))
        img[min(a, b):max(a, b) + 1, i] = (1.0, 0.72, 0.24)
    img[mid, :, :] = np.maximum(img[mid, :, :], (0.32, 0.20, 0.06))
    wave = Image.fromarray((img * 255).astype(np.uint8))

    # --- spectrogram -------------------------------------------------------
    spec = np.abs(stft(x))
    mag = 20.0 * np.log10(spec.T + 1e-7)
    # Reference to the 99.7th percentile, not the absolute max: one stop burst
    # is 20 dB above everything else and referencing it pushes the whole voice
    # into the bottom of the ramp. A 58 dB window keeps formant bands and the
    # inter-formant valleys both visible, which is the point of the picture.
    ref = float(np.percentile(mag, 99.7))
    mag = np.clip((mag - ref + 58.0) / 58.0, 0.0, 1.0) ** 1.35
    # Log frequency axis — a linear one wastes 80 % of the picture on the top
    # two octaves, where none of this material lives.
    freqs = np.fft.rfftfreq(N_FFT, 1.0 / RATE)
    want = np.geomspace(60.0, 14000.0, spec_h)
    rows = np.interp(want, freqs, np.arange(freqs.size))
    idx = np.clip(rows.astype(int), 0, mag.shape[0] - 1)
    mag = mag[idx][::-1]
    if mag.shape[1] != width:
        xi = np.linspace(0, mag.shape[1] - 1, width)
        mag = np.stack([np.interp(xi, np.arange(mag.shape[1]), r) for r in mag])
    rgb = _phosphor(mag)
    # Faint gridlines at the frequencies that matter for reading a voice:
    # F1 territory, F2 territory, and the sibilance band.
    for hz in (250.0, 1000.0, 4000.0):
        row = spec_h - 1 - int(np.argmin(np.abs(want - hz)))
        if 0 <= row < spec_h:
            rgb[row] = np.clip(rgb[row] + 0.14, 0.0, 1.0)
    sp = Image.fromarray((rgb * 255).astype(np.uint8))
    return wave, sp


def write_contact_sheet(rendered: dict, path: str, reports: dict) -> None:
    from PIL import Image, ImageDraw

    W, WAVE_H, SPEC_H, PAD, LABEL_H, GUT = 700, 46, 118, 10, 26, 330
    row_h = LABEL_H + WAVE_H + SPEC_H + PAD * 2
    order = [k for k in CANDIDATES if k in rendered]
    H = row_h * len(order) + 54
    sheet = Image.new("RGB", (W + GUT + 16, H), (8, 7, 6))
    d = ImageDraw.Draw(sheet)
    d.text((14, 12), "BANISH PROTOCOL — MOTHER voice R&D  ·  waveform + log spectrogram, 60 Hz – 14 kHz",
           fill=(255, 184, 70))
    d.text((14, 26), "gridlines at 250 Hz / 1 kHz / 4 kHz  ·  'mod' = envelope modulation peak and "
                     "fraction of that energy in the 2-8 Hz syllable band",
           fill=(150, 112, 52))
    y = 48
    for key in order:
        tier, _, note = CANDIDATES[key]
        x = rendered[key]
        rep = reports[key]
        wave, sp = analysis_tiles(x, W, WAVE_H, SPEC_H)
        d.text((14, y + 4), "%s   [%s]" % (key, tier), fill=(255, 196, 96))
        d.text((14, y + 15), note, fill=(150, 112, 52))
        sheet.paste(wave, (GUT, y))
        sheet.paste(sp, (GUT, y + WAVE_H + 4))
        mod = modulation_report(x)
        d.text((14, y + 40),
               "%.1f s  %.1f LUFS  %.1f dBTP\nLRA %.1f  mod %.1f Hz / %.2f"
               % (rep["after"]["seconds"], rep["after"]["lufs"],
                  rep["after"]["true_peak_dbtp"], rep["after"]["lra"],
                  mod["peak_hz"], mod["speech_frac"]),
               fill=(120, 92, 44))
        y += row_h
    sheet.save(path)
    print("[sheet] %s" % path)


# ===========================================================================
# 7. OBJECTIVE CHECK — does it actually read as speech?
# ===========================================================================

def modulation_report(x: np.ndarray) -> dict:
    """Measure the amplitude-envelope modulation spectrum.

    Natural speech has a famously stable signature: the energy envelope
    modulates most strongly at the SYLLABLE RATE, a broad peak around 3-6 Hz,
    and that peak is a large fraction of the total envelope energy. Music
    peaks lower and narrower; noise beds have no peak at all. So this is a
    cheap, honest, listener-free test of the one thing these cues have to do —
    trip a listener's speech detector.

    Reported as (peak modulation frequency, fraction of envelope energy in the
    2-8 Hz speech band). Anything with a peak in-band and >0.25 of its
    envelope energy there is doing the job.

    Two corrections matter, and getting them wrong makes the metric useless:

      * SILENCE IS GATED OUT. These cues are mostly pauses by design; leaving
        the pauses in makes every file report its phrase rate (~0.5 Hz)
        instead of its syllable rate.
      * The envelope is divided by its own half-second moving average before
        analysis. Otherwise the slow phrase-level swell — which is real, and
        is also present in genuine speech — dominates the spectrum and buries
        the syllabic modulation we are actually testing for.
    """
    env = one_pole_lp(np.abs(x), 40.0)
    dec = max(int(RATE / 400), 1)
    env = np.maximum(env[::dec], 0.0)
    fs_env = RATE / dec
    if env.size < 128:
        return {"peak_hz": 0.0, "speech_frac": 0.0}

    # Gate: keep the active stretches only (30 dB below the envelope peak).
    thresh = float(np.max(env)) * 10.0 ** (-30.0 / 20.0)
    active = env > thresh
    if np.count_nonzero(active) < 128:
        return {"peak_hz": 0.0, "speech_frac": 0.0}
    env = env[active]

    # Flatten the phrase-level swell: divide by a 0.5 s moving average.
    w = max(int(0.5 * fs_env), 3)
    kern = np.hanning(w) / np.sum(np.hanning(w))
    slow = np.convolve(env, kern, mode="same")
    env = env / np.maximum(slow, np.max(slow) * 1e-3)
    env = env - np.mean(env)
    if env.size < 128 or np.allclose(env, 0.0):
        return {"peak_hz": 0.0, "speech_frac": 0.0}

    spec = np.abs(np.fft.rfft(env * np.hanning(env.size))) ** 2
    freqs = np.fft.rfftfreq(env.size, 1.0 / fs_env)
    usable = (freqs >= 1.0) & (freqs <= 16.0)
    band = (freqs >= 2.0) & (freqs <= 8.0)
    if not np.any(usable):
        return {"peak_hz": 0.0, "speech_frac": 0.0}
    peak_hz = float(freqs[usable][np.argmax(spec[usable])])
    frac = float(np.sum(spec[band]) / max(np.sum(spec[usable]), 1e-12))
    return {"peak_hz": peak_hz, "speech_frac": frac}


def formant_report(x: np.ndarray) -> list[float]:
    """The three strongest spectral peaks below 3.5 kHz in the long-term
       average spectrum — a rough read on where the formants ended up. Sanity
       only: if this comes back as a single peak at 50 Hz, the resonator bank
       is not running."""
    mag = np.mean(np.abs(stft(x)), axis=0)
    freqs = np.fft.rfftfreq(N_FFT, 1.0 / RATE)
    sel = (freqs > 150.0) & (freqs < 3500.0)
    f, m = freqs[sel], mag[sel]
    # Smooth, then take local maxima.
    k = np.hanning(9) / np.sum(np.hanning(9))
    ms = np.convolve(m, k, mode="same")
    peaks = [(ms[i], f[i]) for i in range(1, ms.size - 1)
             if ms[i] > ms[i - 1] and ms[i] > ms[i + 1]]
    peaks.sort(reverse=True)
    return sorted(round(p[1]) for p in peaks[:3])


# ===========================================================================
# 8. DRIVER
# ===========================================================================

def encode_ogg(wav_path: str, ogg_path: str) -> None:
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path,
                    "-c:a", "libvorbis", "-q:a", "6", ogg_path], check=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="MOTHER voice R&D candidates")
    ap.add_argument("--out", default=OUT_DIR)
    ap.add_argument("--only", default="", help="substring filter on candidate id")
    ap.add_argument("--wav-only", action="store_true", help="skip the Vorbis encode")
    ap.add_argument("--sheets", default="", help="directory for analysis PNGs")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    # Godot must not import an R&D folder — 30 stray .import files and a pile
    # of UIDs for assets nobody has approved yet. Removing this file is step
    # one of integration, not something to forget to add later.
    gdignore = os.path.join(args.out, ".gdignore")
    if not os.path.exists(gdignore):
        with open(gdignore, "w", encoding="utf-8") as fh:
            fh.write("")

    rendered: dict[str, np.ndarray] = {}
    reports: dict[str, dict] = {}
    rows = []
    for key, (tier, fn, note) in CANDIDATES.items():
        if args.only and args.only not in key:
            continue
        raw = fn()
        raw = np.nan_to_num(raw, nan=0.0, posinf=0.0, neginf=0.0)
        y, rep = bs1770.normalise_to(raw, RATE, TARGETS[tier],
                                     ceiling_dbtp=CEILING_DBTP)
        rendered[key] = y
        reports[key] = rep

        wav = os.path.join(args.out, key + ".wav")
        bs1770.write_wav(wav, y, RATE, width=3)
        if not args.wav_only:
            encode_ogg(wav, os.path.join(args.out, key + ".ogg"))
        a = rep["after"]
        mod = modulation_report(y)
        rows.append((key, tier, a["seconds"], a["lufs"], a["true_peak_dbtp"],
                     a["lra"], rep["gain_db"], rep["limited_db"],
                     mod["peak_hz"], mod["speech_frac"]))
        print("[voice] %-30s %-8s %5.1fs  %7.2f LUFS  %6.2f dBTP  LRA %4.1f  "
              "mod %4.1f Hz / %.2f  %s"
              % (key, tier, a["seconds"], a["lufs"], a["true_peak_dbtp"],
                 a["lra"], mod["peak_hz"], mod["speech_frac"],
                 "F %s" % formant_report(y)))
        if rep["limited_db"] > 0.01:
            print("        ceiling-limited by %.2f dB" % rep["limited_db"])
        # The in-band FRACTION is the meaningful figure, not the argmax: a
        # deliberately slow candidate (the epitaph) legitimately peaks near
        # 1.5 Hz because its syllables really are that long, and warning on
        # that would be warning that the design worked.
        if mod["speech_frac"] < 0.35:
            print("        WARN only %.0f%% of envelope modulation lies in the "
                  "2-8 Hz syllable band — this may not read as speech"
                  % (100.0 * mod["speech_frac"]))

    if args.sheets and rendered:
        os.makedirs(args.sheets, exist_ok=True)
        write_contact_sheet(rendered, os.path.join(args.sheets,
                                                   "mother_voice_contact_sheet.png"),
                            reports)

    print("\n%d candidates -> %s" % (len(rendered), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
