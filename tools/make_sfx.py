#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — procedural sound effects (PT1)
#
#   python3 tools/make_sfx.py [--out assets/audio] [--only KEY]
#
# Every sound in this game is synthesised rather than sourced, and this is the
# tool that does it for the two the first playtest asked for:
#
#   ui/ui_hit_confirm.ogg     the hit marker's tick. Fires on every landed
#                             breaker shot, so it has to be SHORT, has to sit in
#                             a different part of the spectrum from the shot that
#                             caused it (weapons/breaker_shot_*: a broadband
#                             crack around 200-2000 Hz), and must never be
#                             mistaken for taking damage. A high, dry, two-tone
#                             tick — a relay closing behind glass.
#   ui/ui_shaft_siphon.ogg    the drop shaft's cut of the trunk. A soft upward
#                             sweep that resolves onto the interface's own note,
#                             ~0.9 s, no attack transient: a pool filling, not an
#                             event firing. Quiet-instrument rule — this plays
#                             under the LAYER card, and must not compete with it.
#
# Stdlib only, on purpose: this repo has no numpy and a build tool that needs one
# is a build tool nobody runs. Everything below is a list of floats. WAV is
# written by hand, then ffmpeg converts to the .ogg Godot imports (ffmpeg is
# already a dependency of the capture pipeline).
#
# The instrument voice is deliberately the same family as the rest of the UI set:
# soft-clipped sine stacks through a one-pole low-pass, an exponential envelope,
# and a whisper of the CRT's own 15.734 kHz flyback whine on the UI sounds so
# they belong to the same box as the interface that plays them.
# ---------------------------------------------------------------------------
import argparse, math, os, random, struct, subprocess, sys, wave

RATE = 48000
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


# ------------------------------------------------------------------ helpers --

def frames(seconds):
    return int(RATE * seconds)


def env_exp(n, attack, decay):
    """Exponential AD envelope. `attack` and `decay` are in seconds; the attack
       is linear (a click is a linear ramp) and the decay is exponential (which
       is what every physical thing that rings actually does)."""
    a = max(frames(attack), 1)
    out = []
    for i in range(n):
        if i < a:
            out.append(i / a)
        else:
            out.append(math.exp(-(i - a) / (RATE * decay)))
    return out


def sine(n, hz, phase=0.0, sweep_to=None):
    """A sine, optionally sweeping linearly to `sweep_to` across its length."""
    out = []
    p = phase
    for i in range(n):
        f = hz if sweep_to is None else hz + (sweep_to - hz) * (i / max(n - 1, 1))
        p += 2.0 * math.pi * f / RATE
        out.append(math.sin(p))
    return out


def noise(n, seed):
    rng = random.Random(seed)
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def lowpass(sig, hz):
    """One-pole. Enough: this is texture, not a filter design exercise."""
    a = 1.0 - math.exp(-2.0 * math.pi * hz / RATE)
    out, y = [], 0.0
    for x in sig:
        y += a * (x - y)
        out.append(y)
    return out


def highpass(sig, hz):
    return [x - y for x, y in zip(sig, lowpass(sig, hz))]


def bandpass(sig, lo, hi):
    return highpass(lowpass(sig, max(hi, lo * 1.05)), lo)


# --------------------------------------------------------- THE CENTROID LAW --
#
# The single most useful thing the SOUND LAB audit found: 110 of the 167 files
# in this library had a spectral centroid that does not FALL over their own
# decay. Every struck object in the physical world darkens as it rings out,
# because the high partials radiate their energy away first — a bright partial
# is a fast partial, that is what "bright" means. A layer stack with one
# envelope over everything does not do this, and the ear reads that as
# synthetic no matter how the sound is EQ'd, how loud it is, or how good the
# individual layers are. It is the mechanical definition of "generic", and it
# is the reason the whole set was described as "sorta not exactly there".
#
# The fix is structural, not cosmetic, and it is these two helpers. Nothing
# below is clever; the discipline is the point:
#
#   * every layer gets its OWN decay, never a shared envelope;
#   * the decay is SHORTER the brighter the layer;
#   * within a partial stack that relationship is a law rather than a habit —
#     `struck()` derives each partial's decay from the one below it.
#
# Applied to the recipes in this file it moves the centroid trajectory from
# roughly flat to 1-3 octaves of fall, which is the range physical impacts
# actually occupy. Measure it with:
#     python3 tools/soundlab/analyze.py --root <dir> && tools/soundlab/audit.py

def struck(n, f0, count=5, spread=1.87, decay=0.18, falloff=0.55, tilt=1.0,
           attack=0.0006, glide=0.985, detune=0.0):
    """An inharmonic partial stack in which the high partials die first.

       `spread` is the ratio between successive partials — 1.87 rather than 2.0
       because a real plate or shell is inharmonic and an exact octave stack
       sounds like an organ. `falloff` < 1 is THE CENTROID LAW: partial k decays
       in `decay * falloff**k` seconds, so the top of the stack is gone while
       the bottom is still ringing and the centroid falls without anyone drawing
       an automation curve."""
    out = [0.0] * n
    for k in range(count):
        hz = f0 * (spread ** k) * (1.0 + detune * k)
        if hz > RATE * 0.45:
            break
        dec = max(decay * (falloff ** k), 0.0015)
        amp = 1.0 / ((k + 1) ** tilt)
        env = env_exp(n, attack, dec)
        part = sine(n, hz, sweep_to=hz * glide)
        for i in range(n):
            out[i] += part[i] * env[i] * amp
    # Peak-normalised, for the same reason `air` is: without it a stack's output
    # level depends on `count` and `tilt` — seven partials at tilt 0.3 sum to a
    # peak of nearly 5 and three at tilt 1.3 to under 2 — so `gain(struck(...),
    # 0.6)` means two different things in two recipes. Every layer helper in this
    # file returns unit peak so that a mix is read off its gains.
    top = max(abs(x) for x in out) or 1.0
    return [x / top for x in out]


def air(n, seed, lo, hi, attack=0.0004, decay=0.02, delay=0.0, order=1):
    """A band of noise with its own envelope, optionally arriving late.

       The companion to `struck`: the noise half of a contact event, kept as a
       separate layer with a separate decay for the same reason.

       PEAK-NORMALISED BEFORE IT RETURNS, which matters more than it looks. The
       one-pole bandpass attenuates by an amount that depends entirely on how
       wide and how high the band is — a 1.4-15 kHz burst comes back near unity
       and a 60-340 Hz one comes back 20 dB down — so `gain(air(...), 0.6)` does
       not mean 0.6 of anything unless the layer is normalised first. Without
       this, mixing by ear-free numbers is guesswork and the loudest layer in a
       stack is whichever one happened to sit in the filter's easy region. It
       cost an hour on the Sentinel collapse, whose contact transient was mixed
       at 1.3 and arrived 20 dB under the mass it was supposed to precede.

       `order` cascades the band edges. The one-pole filters in this file roll
       off at 6 dB per octave, which is gentle enough that a band nominally at
       95-330 Hz measures a spectral centroid up around 1.5 kHz — most of its
       energy is in the skirt, not the passband. That is fine for a bright
       contact layer and actively wrong for a layer whose whole job is to be the
       DARK half of a sound: a "warm" layer that is secretly bright inverts the
       centroid trajectory of everything it is mixed into. order=2 or 3 where
       the band has to mean what it says.
    """
    d = frames(delay)
    m = max(n - d, 1)
    src = noise(m, seed)
    for _ in range(max(order, 1)):
        src = bandpass(src, lo, hi)
    body = apply_env(src, env_exp(m, attack, decay))
    top = max(abs(x) for x in body) or 1.0
    body = [x / top for x in body]
    return [0.0] * d + body if d else body


def delay_into(layer, seconds, n):
    """Place `layer` `seconds` into a buffer of length `n`."""
    d = frames(seconds)
    out = [0.0] * n
    for i in range(min(len(layer), n - d)):
        out[d + i] = layer[i]
    return out


def am(sig, rate_hz, depth, phase=0.0):
    """Amplitude modulation. At 60-100 Hz this is ROUGHNESS — the measurable
       correlate of snarl, grind and bite, and the descriptor the audit says the
       creature set is missing (library median 0.49; a creature wants 1.5). At
       3-12 Hz it is tremolo, which is a different and much cheaper effect."""
    w = 2.0 * math.pi * rate_hz / RATE
    return [x * (1.0 - depth * 0.5 * (1.0 - math.cos(w * i + phase)))
            for i, x in enumerate(sig)]


def jitter_sine(n, hz, sweep_to=None, curve=1.0, depth=0.0, rate=18.0, seed=0):
    """A sine whose frequency wanders. `curve` > 1 spends more of a sweep near
       the start frequency (what a relaxing tension actually does); `depth` is
       fractional instability, low-passed so it is a wobble rather than noise.

       A throat is unsteady and an oscillator is not, and that difference is
       most of what separates a creature from a synthesiser."""
    if depth > 1e-6:
        j = lowpass(noise(n, seed), rate)
        top = max(abs(v) for v in j) or 1.0
        j = [v / top for v in j]
    else:
        j = None
    out, p = [], 0.0
    for i in range(n):
        u = (i / max(n - 1, 1)) ** curve
        f = hz if sweep_to is None else hz + (sweep_to - hz) * u
        if j is not None:
            f *= 1.0 + depth * j[i]
        p += 2.0 * math.pi * f / RATE
        out.append(math.sin(p))
    return out


def grains(n, seed, count, lo, hi, decay, spread=0.0, pitch=0.0, jitterish=0.35,
           darken=1.0):
    """A train of short irregular bursts inside one buffer.

       This is what makes a chitter a chitter and a skitter a skitter: discrete
       events with silence between them. A continuous band of noise with a slow
       envelope over it measures 5 dB of envelope range and reads as a hiss with
       a name — which is exactly what the audit says our idle set is."""
    rng = random.Random(seed)
    out = [0.0] * n
    for g in range(count):
        # Irregular placement. Even spacing is a machine; a living thing is not
        # a metronome, and the ear notices the difference immediately.
        centre = (g + 0.5) / count
        t = centre + rng.uniform(-jitterish, jitterish) / count
        d = frames(max(t, 0.0) * n / RATE)
        m = n - d
        if m < 64:
            continue
        f = 1.0 + rng.uniform(-spread, spread)
        # `darken` < 1 walks the band down across the train, so even a texture
        # made of many separate events obeys the centroid law over its own
        # length — the creature is running out of breath, not looping a sample.
        w = darken ** (g / max(count - 1, 1))
        src = bandpass(noise(m, seed + 17 * g + 1), lo * f * w, hi * f * w)
        if pitch > 0.0:
            tone = sine(m, lo * f * 2.0, sweep_to=lo * f * 1.6)
            src = [a + pitch * b for a, b in zip(src, tone)]
        env = env_exp(m, 0.0005, decay * rng.uniform(0.6, 1.4))
        amp = rng.uniform(0.55, 1.0)
        for i in range(m):
            out[d + i] += src[i] * env[i] * amp
    return out


def mix(*layers):
    n = max(len(l) for l in layers)
    out = [0.0] * n
    for layer in layers:
        for i, v in enumerate(layer):
            out[i] += v
    return out


def gain(sig, g):
    return [x * g for x in sig]


def apply_env(sig, envelope):
    return [x * e for x, e in zip(sig, envelope)]


def soft_clip(sig):
    return [math.tanh(x) for x in sig]


def normalise(sig, peak=0.89):
    top = max(abs(x) for x in sig) or 1.0
    return [x * peak / top for x in sig]


def voice(sig, drive=1.0, peak=0.86):
    """The instrument's soft-clip stage, with its drive made EXPLICIT.

       `soft_clip` is tanh, and the recipes above hand it a raw layer sum — so
       how hard the sound is saturated depends on how many layers happen to be
       in it and what gains they happen to carry. That is an accident, and on a
       sub-heavy mix it is a destructive one: tanh's instantaneous gain collapses
       while the 44 Hz fundamental is near its excursion, so any quieter layer
       riding on top of it at that moment is gated out. Measured on the surge
       step, a plate ring mixed in at 0.34 arrived at the output 20 dB below
       where it was put in, purely because it was unlucky enough to be
       simultaneous with the bass.

       Normalising to a stated `drive` before the tanh makes the saturation a
       parameter with a value instead of an emergent property of the arrangement.
       drive 1.0 is about where the old call sites sat; below ~0.6 the stage is
       effectively linear and layers keep the balance they were mixed at."""
    top = max(abs(x) for x in sig) or 1.0
    return normalise(soft_clip([x * drive / top for x in sig]), peak)


def fade_edges(sig, ms=4.0):
    """Kill the DC step at both ends. A sample that starts or stops on a nonzero
       value clicks, and a click on a sound that fires several times a second is
       the fastest way to make a mix sound cheap."""
    k = max(frames(ms / 1000.0), 1)
    for i in range(min(k, len(sig))):
        sig[i] *= i / k
        sig[-1 - i] *= i / k
    return sig


# --- loudness --------------------------------------------------------------
#
# Peak normalisation is what every one of these synths ends on, and it is the
# wrong final answer: two sounds normalised to the same PEAK can differ by 10 dB
# in perceived loudness, which is how a library ends up with a tick that shreds
# and a whoosh nobody hears. So the last stage is BS.1770-4 integrated loudness,
# measured and corrected by tools/audio/bs1770.py — the same meter the MOTHER
# voice pipeline uses, so the whole game is measured by one instrument.
#
# The targets are read off the SHIPPED library rather than invented: the M5 asset
# set sits at about -15 LUFS for a one-shot event, so that is the default and
# anything quieter than an event is placed below it on purpose. `-1.5 dBTP` is the
# ceiling; Vorbis encoding can add a few tenths of a dB of intersample peak and a
# one-shot that clips on decode is the one defect nobody can fix downstream.
DEFAULT_LUFS = -15.0
CEILING_DBTP = -1.5

## Per-sound loudness targets, for the sounds that are deliberately not events.
## The quiet-instrument rule (DESIGN.md M4.9) has an audio half: a confirm that
## fires every few seconds in a firefight must not become the firefight.
## The two PT1 sounds predate the loudness pass and were TUNED BY EAR against
## their peak-normalised masters — `ui_hit_confirm` in particular is mixed at
## -7 dB in the event table because of how loud that file already is. Re-measuring
## them would silently undo a shipped tuning decision that a playtest signed off,
## so they are left exactly as they were. New assets are measured; old assets are
## not retro-fitted without someone listening.
UNMEASURED = ["ui/ui_hit_confirm.ogg", "ui/ui_shaft_siphon.ogg"]

TARGETS = {
    "ui/ui_sub_ready.ogg": -23.0,      # the quietest thing after the gauge tick
    "ui/ui_sub_refused.ogg": -18.0,    # a refusal is information, not an alarm
    "player/sub_fork_hit.ogg": -17.0,  # feedback under a fight, not over it
    "player/sub_barrier_hit.ogg": -16.5,

    # --- the remaster's adoptions ------------------------------------------
    #
    # Every entry below is the SHIPPED file's own measured integrated loudness,
    # to the tenth of a LU. None of it is a new mix decision and that is the
    # entire point.
    #
    # These 28 assets had no generator in the repository (see the block comment
    # further down), so they were never measured by this tool and they sit
    # wherever M5 happened to put them — which for `datachip_pickup` is -27.2
    # LUFS and for `scrubber_lunge_shriek` is -17.5. Letting them fall through
    # to DEFAULT_LUFS raised the datachips by 12 dB, the skitters by 9 and the
    # landings by 9, and a landing 9 dB over a footstep is a different game.
    # The remaster's job was the SOUND; the mix is a separate decision with its
    # own playtest behind it, and the event tables in src/core/audio_service.gd
    # carry per-event trims that were tuned against these exact levels.
    #
    # Several of them are obviously wrong as levels — a pickup 12 dB under the
    # library is not a considered choice, it is an artefact of whatever made it
    # — but re-levelling the library is a mix pass, not this pass, and doing it
    # silently inside an asset swap is how a change nobody asked for ships.
    # The numbers are here, in one table, for whoever takes that on.
    "weapons/breaker_shot_01.ogg": -18.3,
    "weapons/breaker_shot_02.ogg": -18.3,
    "weapons/breaker_shot_03.ogg": -18.5,
    "weapons/breaker_shot_04.ogg": -18.6,
    "world/datachip_pickup_01.ogg": -27.2,
    "world/datachip_pickup_02.ogg": -27.1,
    "world/datachip_pickup_03.ogg": -27.2,
    "world/datachip_pickup_04.ogg": -27.2,
    "world/datachip_pickup_05.ogg": -27.2,
    "world/datachip_pickup_06.ogg": -27.2,
    "creatures/scrubber_lunge_shriek_01.ogg": -17.5,
    "creatures/scrubber_lunge_shriek_02.ogg": -17.5,
    "creatures/scrubber_lunge_shriek_03.ogg": -17.6,
    "creatures/scrubber_idle_chitter_01.ogg": -18.5,
    "creatures/scrubber_idle_chitter_02.ogg": -18.5,
    "creatures/scrubber_idle_chitter_03.ogg": -18.5,
    "creatures/scrubber_hurt_01.ogg": -18.6,
    "creatures/scrubber_hurt_02.ogg": -18.6,
    "creatures/scrubber_skitter_loop_01.ogg": -24.5,
    "creatures/scrubber_skitter_loop_02.ogg": -24.5,
    "creatures/scrubber_skitter_loop_03.ogg": -24.5,
    "creatures/sentinel_death_collapse.ogg": -19.3,
    "creatures/hound_howl.ogg": -16.9,
    "player/player_hurt_01.ogg": -20.6,
    "player/player_hurt_02.ogg": -20.7,
    "player/player_hurt_03.ogg": -20.7,
    "player/player_land_grate_01.ogg": -26.2,
    "player/player_land_grate_02.ogg": -26.1,
}


# --- the loudness assist: LIMIT, do not SATURATE ---------------------------
#
# A sub-bass whump has an enormous crest factor: a single 40 Hz cycle owns the
# true peak while contributing almost nothing to K-weighted loudness (BS.1770
# weights 40 Hz down by about 13 dB), so the ceiling eats the entire gain and
# the sound lands several dB under the library. Something has to buy that back.
#
# This used to be one global `tanh(x * drive)` stage. It worked, and it was
# billed as "a soft limiter, not a distortion effect" — but tanh has no
# threshold. It is nonlinear at every amplitude, so it compresses the body of
# the sound and not just its peaks, and the SOUND LAB audit priced what that
# costs: `sub_step_whump` lost 2.3 dB of crest (12.0 -> 9.7) and
# `sub_stack_pulse` lost 2.9 dB (13.7 -> 10.8). It was buying level by spending
# punch, on the two sounds in the game that exist to be punch.
#
# What replaces it is an actual limiter: linear below a knee set `KNEE_DB` under
# the ceiling, and above that the excess is folded asymptotically into the
# ceiling. Everything quieter than the knee — which is the whole body of the
# sound and all of its tail — passes through with plain gain applied. Only the
# few sample excursions that would have clipped are reshaped.
#
# The other half of the fix is the ORDER. The old code drove tanh with the raw
# pre-normalisation signal, whose scale depended on whatever peak the recipe's
# `normalise()` call happened to leave it at, so the amount of distortion was a
# side effect of an unrelated constant. Here the signal is peak-normalised
# FIRST, then a single drive is bisected against the meter, so the limiter is
# always anchored to the ceiling and the drive is always the smallest one that
# reaches the target.
#
# And a policy, which is the part that actually fixes the audit finding.
# Swapping tanh for a real limiter is not by itself enough: measured on
# `sub_step_whump`, the limiter reaches the -15 LUFS target that tanh only got
# halfway to, and reaching it costs MORE crest, not less (12.0 -> 7.5 dB versus
# tanh's 12.0 -> 9.7). That is not a bug in the limiter. It is physics: when a
# sound's peak IS its body — one 40 Hz half-cycle carrying nearly all of the
# energy — there is no gain stage in existence that can raise its K-weighted
# loudness without flattening the thing that makes it hit.
#
# So the assist is given a BUDGET. It buys level while level is cheap and stops
# when the next dB would cost more than `CREST_BUDGET_DB` of peak-to-average,
# landing under target and saying so in the build log rather than quietly
# trading away the punch. The real answer for a sound that hits the budget is
# upstream, in the recipe: give it harmonics with their own faster decays, so
# the meter has something above 40 Hz to see. That buys level honestly, and
# because the harmonics die first it buys a falling spectral centroid at the
# same time. `sub_step` and `sub_pulse` below now do exactly that, and neither
# spends its budget any more.
# The budget itself has two terms, because one number was wrong in both
# directions. A flat 1.5 dB starved the loud, spiky assets: the Sentinel
# collapse arrives with 20.6 dB of crest, five dB more than any class in
# classes.py asks for, and refusing to spend any of that surplus left it at
# -23.9 LUFS against a -15 target — inaudible under a fight, which is a worse
# defect than the one the budget exists to prevent. So: always allowed 1.5 dB,
# and additionally allowed to spend anything ABOVE the floor. 14 dB is the
# floor because it is the highest crest_db minimum any objective in
# classes.py sets (weapon_fire); a sound with more than that has punch to
# spare, and a sound at or under it does not and is not asked for any.
#
# And a third constraint, which the first two turned out not to imply. Crest is
# peak over the RMS of the whole active region, so a limiter can flatten the
# first ten milliseconds of a sound and pay for it out of a long tail without
# the crest number moving much. It did exactly that to the Sentinel collapse:
# crest stayed inside its budget while the measured 10-90 % rise went from 8 ms
# to 48 ms — the audit's original complaint about that file, reintroduced by the
# stage meant to be protecting it. TRANSIENT AND CREST ARE NOT THE SAME
# PROPERTY, and the brief was "buy level without eating transients", so the
# attack is now a term of its own.
KNEE_DB = 4.0
CREST_BUDGET_DB = 1.5
CREST_FLOOR_DB = 14.0
ATTACK_STRETCH_MAX = 1.30


def _crest_db(x, np):
    return float(20.0 * math.log10(max(float(np.max(np.abs(x))), 1e-12))
                 - 20.0 * math.log10(max(float(np.sqrt(np.mean(x ** 2))), 1e-12)))


def _attack_ms(x, np):
    """10-90 % rise of the RMS envelope, to the envelope's global peak — the
       same definition tools/soundlab/descriptors.py uses, so the build tool and
       the audit are talking about the same number."""
    win, hop = 144, 24                       # 3 ms / 0.5 ms at 48 kHz
    if len(x) < win + hop:
        return 0.0
    n = 1 + (len(x) - win) // hop
    idx = np.arange(win)[None, :] + hop * np.arange(n)[:, None]
    env = np.sqrt(np.maximum((x[idx] ** 2).mean(axis=1), 1e-24))
    pk = int(np.argmax(env))
    top = env[pk]
    rise = env[:pk + 1]
    lo = np.nonzero(rise >= 0.1 * top)[0]
    hi = np.nonzero(rise >= 0.9 * top)[0]
    if not len(lo) or not len(hi):
        return 0.0
    return float((hi[0] - lo[0]) * hop / RATE * 1000.0)


def _knee_limit(x, ceiling_lin, np):
    """Soft-knee peak limiter. Linear below `ceiling_lin` * -KNEE_DB; above it,
       the overshoot is compressed asymptotically into the ceiling so the output
       cannot exceed it. Unlike tanh this has a threshold, which is the entire
       point: the body of the sound is not in the nonlinearity."""
    thresh = ceiling_lin * 10.0 ** (-KNEE_DB / 20.0)
    a = np.abs(x)
    out = a.copy()
    over = a > thresh
    k = ceiling_lin - thresh
    out[over] = thresh + k * np.tanh((a[over] - thresh) / k)
    return np.sign(x) * out


def _limit_to(x, target_lufs, ceiling_dbtp, np, bs1770):
    """Push the drive up until the target is reached or something breaks.

       A SCAN, not a bisection, and that distinction cost a bug. Loudness rises
       monotonically with drive and crest falls monotonically, so both can be
       bisected — but ATTACK TIME DOES NOT MOVE MONOTONICALLY. Measured on the
       Sentinel collapse: 6.0, 6.0, 6.0, 47.5, 47.5, 47.0, 6.5, 2.0, 1.0 ms as
       the drive goes 1x to 16x. The jump at 2x is the limiter flattening the
       contact transient until the envelope's global peak moves to the mass
       arriving 60 ms later, so the 10-90 % rise is suddenly measured to a
       different event entirely; by 6x everything is flat and the number comes
       back down. A bisection sampled the far end, found 1.0 ms, declared the
       constraint satisfied and shipped a 48 ms attack on an impact.

       So: walk up in 0.2 dB steps from unity and stop at the first step that
       breaks a rule. Non-monotone constraints need a scan, and the guard has to
       hold at every drive on the way, not just at the one it lands on."""
    ceiling = 10.0 ** (ceiling_dbtp / 20.0)
    peak = float(np.max(np.abs(x))) or 1.0
    unit = np.asarray(x, dtype=float) / peak

    def at(g):
        return _knee_limit(unit * g * ceiling, ceiling, np)

    # The budget is measured against the UNTOUCHED shape. Not against at(1.0):
    # the knee starts 4 dB below the ceiling, so even a unity drive costs a few
    # tenths, and a budget that forgives its own first bite is not a budget.
    crest0 = _crest_db(unit, np)
    budget = max(CREST_BUDGET_DB, crest0 - CREST_FLOOR_DB)
    # 0.5 ms of slack on top of the ratio because the envelope hop is 0.5 ms and
    # a one-bin move is not a defect.
    atk_max = _attack_ms(unit, np) * ATTACK_STRETCH_MAX + 0.5

    best, bound = at(1.0), False
    for step in range(1, 121):                       # 0.2 dB steps, up to 24 dB
        g = 10.0 ** (0.2 * step / 20.0)
        y = at(g)
        if _crest_db(y, np) < crest0 - budget or _attack_ms(y, np) > atk_max:
            bound = True
            break
        best = y
        if bs1770.integrated_lufs(y, RATE) >= target_lufs:
            break
    # The knee bounds the SAMPLE peak; inter-sample peaks can still overshoot,
    # and a one-shot that clips on Vorbis decode is the defect nobody can fix
    # downstream. One linear trim, which costs no shape at all.
    tp = bs1770.true_peak_dbtp(best, RATE)
    if tp > ceiling_dbtp:
        best = best * 10.0 ** ((ceiling_dbtp - tp) / 20.0)
    return best, bound


def normalise_loudness(sig, rel, verbose=True):
    """BS.1770-normalise `sig` toward its target, if numpy and the meter are
       available. Degrades to the peak-normalised signal with a warning rather
       than failing the build: a machine without numpy should still be able to
       regenerate the sound set, it just will not be measured."""
    try:
        sys.path.insert(0, os.path.join(HERE, "audio"))
        import numpy as np
        import bs1770
    except Exception as exc:
        if verbose:
            print("[sfx] loudness pass skipped (%s)" % exc)
        return sig
    if rel in UNMEASURED:
        if verbose:
            print("[sfx]   loudness pass skipped (PT1 asset, tuned by ear)")
        return sig
    target = TARGETS.get(rel, DEFAULT_LUFS)
    x = np.asarray(sig, dtype=float)
    scaled, report = bs1770.normalise_to(x, RATE, target, CEILING_DBTP)
    assist = ""
    # Only when the ceiling actually bound by more than a dB, so nothing that
    # did not need it is touched.
    if report["limited_db"] > 1.0:
        y, budget_bound = _limit_to(x, target, CEILING_DBTP, np, bs1770)
        after = bs1770.measure(y, RATE)
        # Report the crest both ways. The old assist made this number worse and
        # nobody was measuring it; now the build log says so on every asset that
        # needs the stage at all.
        assist = ("  [limiter %+.1f dB of level, crest %.1f -> %.1f dB%s]"
                  % (after["lufs"] - report["after"]["lufs"],
                     _crest_db(scaled, np), _crest_db(y, np),
                     ", STOPPED ON CREST BUDGET — fix the recipe, not the gain"
                     if budget_bound else ""))
        scaled = y
        report = {"before": report["before"], "after": after,
                  "gain_db": after["lufs"] - report["before"]["lufs"],
                  "limited_db": report["limited_db"]}
    if verbose:
        print("[sfx]   loudness %.1f -> %.1f LUFS (%+.1f dB, %.1f dBTP%s)%s" % (
            report["before"]["lufs"], report["after"]["lufs"],
            report["gain_db"], report["after"]["true_peak_dbtp"],
            ", ceiling took %.1f dB" % report["limited_db"]
            if report["limited_db"] > 0.05 else "", assist))
    return list(scaled)


def write(path, sig, rel=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sig = normalise_loudness(sig, rel)
    wav = path.replace(".ogg", ".wav")
    with wave.open(wav, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(RATE)
        fh.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, x)) * 32767)) for x in sig))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                    "-c:a", "libvorbis", "-q:a", "6", path], check=True)
    os.remove(wav)
    print("[sfx] %s  (%.2f s)" % (path, len(sig) / RATE))


# ------------------------------------------------------------------- sounds --

def hit_confirm():
    """The hit marker's tick.

       Two short sines a fifth apart (2960 / 4440 Hz) over a filtered noise chiff,
       total length 90 ms. Deliberately ABOVE the breaker shot's band: the shot is
       a broadband crack with its weight under 2 kHz, so a confirm placed up here
       reads as a separate event even when the two land on the same frame, which
       they always do. The second tone starts 12 ms late — the tiny stagger is
       what makes it a *tick* rather than a chord."""
    n = frames(0.09)
    body = mix(
        gain(apply_env(sine(n, 2960.0), env_exp(n, 0.0008, 0.020)), 0.75),
        gain([0.0] * frames(0.012)
             + apply_env(sine(n - frames(0.012), 4440.0),
                         env_exp(n - frames(0.012), 0.0006, 0.013)), 0.5),
        # The chiff. High-passed noise, very short — the mechanical half of a
        # relay closing, without which two sines sound like a phone menu.
        gain(apply_env(highpass(noise(n, 0x81DE), 3200.0),
                       env_exp(n, 0.0004, 0.006)), 0.35))
    return fade_edges(normalise(soft_clip(body), 0.80))


def shaft_siphon():
    """The drop shaft's cut of the trunk.

       An 0.9 s upward sweep from 180 Hz to the interface's own 440, plus its
       octave, under a slow swell with NO attack transient — the pool is filling,
       and a fill that starts with a click is an event. A thread of low-passed
       noise rides it as the flow, and a whisper of the CRT flyback whine at
       15.734 kHz ties it to the box it is coming out of.

       Ends on a single soft confirm partial rather than a chord: DESIGN.md's
       quiet-instrument rule wants this to be noticed and then forgotten, under
       the LAYER card that lands on the same beat."""
    n = frames(0.9)
    swell = env_exp(n, 0.34, 0.30)
    flow = lowpass(noise(n, 0x5A1F), 900.0)
    body = mix(
        gain(apply_env(sine(n, 180.0, sweep_to=440.0), swell), 0.55),
        gain(apply_env(sine(n, 360.0, sweep_to=880.0), swell), 0.22),
        gain(apply_env(flow, swell), 0.30),
        gain(apply_env(sine(n, 15734.0), env_exp(n, 0.30, 0.22)), 0.020),
        # The confirm: one clean partial arriving as the sweep resolves.
        gain([0.0] * frames(0.62)
             + apply_env(sine(n - frames(0.62), 880.0),
                         env_exp(n - frames(0.62), 0.006, 0.075)), 0.30))
    return fade_edges(normalise(soft_clip(body), 0.72), ms=8.0)


# ------------------------------------------------- M7 subroutines & juice --
#
# Eight new sounds for the ability kit and the juice pass. The voice is the same
# family as everything above — soft-clipped sine stacks through one-pole filters
# with exponential envelopes — but the SUBROUTINE set is deliberately its own
# register, because it has to be tellable from both of the two voices already in
# the mix:
#
#   MOTHER's architecture   sleek, metallic, teal. Her machines.
#   Northcairn hardware     phosphor, relay clicks, tape. Your interface.
#   SUBROUTINES (new)       neither. These are things happening INSIDE your own
#                           process, so they are sub-bass and pitched sweeps with
#                           very little midrange — felt more than heard, the way
#                           your own heartbeat is. Nothing in the set has a
#                           mechanical transient, because nothing mechanical is
#                           involved: you are recompiling yourself.
#
# Every one is BS.1770-normalised by tools/audio/bs1770.py after synthesis (see
# `--normalise`), so the set sits at a consistent loudness against the shipped
# library instead of at whatever peak-normalisation happened to give it.


def sub_step():
    """SURGE STEP — the bass whump of a process being migrated.

       A 44 Hz thump that sweeps DOWN to 27 in 120 ms (a body leaving), plus a
       short filtered-noise displacement and a single high tick at the far end
       that reads as the process re-materialising. Total 0.42 s, almost all of it
       tail: the event is the first 30 ms and the rest is the room.

       REMASTER. The old version was one 40 Hz sine and a puff of low-passed
       noise, and it measured 0.6 octaves of bandwidth, a centroid that RISES
       over its decay, and a K-weighted loudness so far below the library that
       the loudness assist had to distort the whole waveform to reach it — which
       cost 2.3 dB of the crest factor that is the entire point of a whump.

       Three problems, one fix: give the thump its own harmonics at 2x and 3x,
       each decaying faster than the one below it. The meter can see 88 and
       132 Hz where it could barely see 44, so the level is bought honestly
       instead of taken out of the transient; the harmonics die first, so the
       spectrum falls as it rings; and the stack is now broadband where it was a
       filtered tone. The contact click is split off as its own 5 ms layer for
       the same reason — mass arrives late, contact does not."""
    n = frames(0.42)
    # The fundamental, with a touch of instability: a floor plate under load is
    # not a signal generator.
    body = apply_env(jitter_sine(n, 44.0, sweep_to=27.0, curve=1.7,
                                 depth=0.010, rate=26.0, seed=0x5791),
                     env_exp(n, 0.0015, 0.085))
    # The fundamental's own overtones. They follow it DOWN, which is physical —
    # and it is also why they cannot on their own put anything in the 80-250 Hz
    # band: sweeping 88 -> 62 spends most of its life under 80 Hz and is counted
    # as more sub. So they buy the meter its level and the plate below buys the
    # body.
    h2 = apply_env(sine(n, 88.0, sweep_to=62.0), env_exp(n, 0.0010, 0.028))
    h3 = apply_env(sine(n, 132.0, sweep_to=96.0), env_exp(n, 0.0008, 0.013))
    # The deck itself. A steel floor plate has modes of its own and they do NOT
    # sweep with the thing that hit it — they ring at the plate's frequencies
    # and die fast, high ones first. This is the layer that gives the whump a
    # size instead of just a weight.
    plate = struck(n, 224.0, count=4, spread=1.81, decay=0.030, falloff=0.52,
                   tilt=1.25, attack=0.0004, glide=0.97)
    # Contact. Gone in 6 ms — this is the deck being met, not the deck ringing.
    click = air(n, 0x5793, 1400.0, 9000.0, attack=0.0002, decay=0.0055)
    disp = air(n, 0x5794, 90.0, 430.0, attack=0.0015, decay=0.042)
    # The arrival. 115 ms in — the length of the dash — and very quiet: it is a
    # confirmation, not a second event.
    #
    # It used to sit at 150 ms at 0.16, and that one layer was single-handedly
    # responsible for this sound's centroid RISING over its decay: by 150 ms the
    # 44 Hz fundamental is 15 dB down, so a 1180 Hz tick at -16 dB owns the last
    # quarter of the energy the centroid trajectory is measured over. Earlier
    # and quieter, it still reads as the process re-materialising and it no
    # longer inverts the spectral shape of the whole sound. The general lesson:
    # a late bright layer is the most common way to lose the centroid law, and
    # it is invisible until something measures the trajectory.
    d = frames(0.115)
    tick = [0.0] * d + gain(apply_env(sine(n - d, 1180.0, sweep_to=1560.0),
                                      env_exp(n - d, 0.001, 0.016)), 0.085)
    out = mix(gain(body, 0.95), gain(h2, 0.52), gain(h3, 0.30),
              gain(plate, 0.40), gain(click, 0.30), gain(disp, 0.26), tick)
    return fade_edges(voice(out, drive=0.55, peak=0.86))


def sub_pulse():
    """STACK PULSE — the loudest thing in the kit, and it should be.

       DESIGN.md makes this the crew's panic button AND a two-room NoiseBus ping,
       so it has to sound like something the layer heard. A hard 62 Hz core under
       a fast upward sweep and a broadband crack, then a 0.8 s tail that opens out
       rather than closing — the shape of a room being told.

       REMASTER: same three changes as sub_step, and for the same reasons. The
       old version spent 2.9 dB of crest — the most of anything in the library —
       on a loudness assist it only needed because a 62 Hz sine is nearly
       invisible to a K-weighted meter. The core now carries its own harmonic
       stack through `struck()`, so the level is there before the gain stage
       gets to it, and the stack's falling centroid is free."""
    # 0.80 s rather than 0.95: the last 150 ms of the old file sat below -40 dB
    # of peak, which is inaudible tail the player pays decode cost for and which
    # measures as 22 % dead air. A tail should end when it stops speaking.
    n = frames(0.80)
    core = apply_env(jitter_sine(n, 62.0, sweep_to=44.0, curve=1.5,
                                 depth=0.008, rate=22.0, seed=0x2C49),
                     env_exp(n, 0.0025, 0.16))
    # The core's own overtones. spread 2.06 rather than 2.0: a slightly stretched
    # stack beats against itself instead of fusing into one thick sine.
    over = struck(n, 124.0, count=3, spread=2.06, decay=0.045, falloff=0.48,
                  tilt=1.1, attack=0.0010, glide=0.88)
    sweep = apply_env(sine(n, 220.0, sweep_to=880.0), env_exp(n, 0.002, 0.038))
    crack = apply_env(highpass(noise(n, 0x2C4B), 900.0), env_exp(n, 0.0004, 0.022))
    # The ring-out: a slow band of low-passed noise that arrives AFTER the crack,
    # which is what makes it read as a space responding rather than as a hit.
    # The ring-out is granulated at 68 Hz. Roughness — amplitude modulation in
    # the 60-100 Hz region — is the measurable correlate of "grind", and a
    # perfectly smooth decay is a reverb tail rather than a structure
    # complaining about what just happened to it.
    d = frames(0.06)
    tail = [0.0] * d + gain(am(apply_env(lowpass(noise(n - d, 0x77A1), 260.0),
                                         env_exp(n - d, 0.09, 0.22)),
                               68.0, 0.55), 0.40)
    body = mix(gain(core, 1.0), gain(over, 0.44), gain(sweep, 0.34),
               gain(crack, 0.50), tail)
    return fade_edges(voice(body, drive=1.00, peak=0.90))


def sub_fork():
    """FORK DECOY cast — a copy being written.

       Two detuned sines a few cents apart so the pitch BEATS: the single most
       direct way to make a sound mean "there are two of these now". They separate
       over the length of the sample, from unison to a wide beat, under a soft
       noise wash."""
    n = frames(0.7)
    swell = env_exp(n, 0.05, 0.20)
    a = apply_env(sine(n, 330.0), swell)
    b = apply_env(sine(n, 330.0, sweep_to=337.0), swell)
    wash = apply_env(lowpass(noise(n, 0x1F0D), 1400.0), env_exp(n, 0.10, 0.15))
    # The instant of the copy: 4 ms, bright, and the only thing in the sound
    # with a fast decay — which is what makes the rest of it read as an
    # aftermath rather than as a pad fading in.
    strike = air(n, 0x1F0E, 1800.0, 12000.0, attack=0.0003, decay=0.0040)
    body = mix(gain(a, 0.42), gain(b, 0.42), gain(wash, 0.22),
               gain(strike, 0.26),
               gain(apply_env(sine(n, 82.0), swell), 0.30))
    return fade_edges(normalise(soft_clip(body), 0.78))


def sub_fork_hit():
    """Something struck the fork. A dry, hollow knock with no body behind it —
       the point is that it sounds WRONG, like hitting a shell. 70 ms."""
    n = frames(0.07)
    body = mix(
        gain(apply_env(sine(n, 520.0, sweep_to=380.0), env_exp(n, 0.001, 0.012)), 0.6),
        # The shell's own partials, dying top-down. Without them the knock has a
        # flat spectrum over its whole 70 ms, which is the thing that reads as
        # synthetic even on a sound this short.
        gain(struck(n, 780.0, count=4, spread=1.63, decay=0.010, falloff=0.48,
                    tilt=0.9, attack=0.0004, glide=0.97, detune=0.03), 0.34),
        gain(apply_env(highpass(noise(n, 0x9E31), 1800.0),
                       env_exp(n, 0.0005, 0.005)), 0.30))
    return fade_edges(normalise(soft_clip(body), 0.70))


def sub_fork_end():
    """The fork decompiles. A downward sweep that loses its low end first, so it
       thins to nothing rather than fading — a program being deallocated."""
    n = frames(0.5)
    fall = env_exp(n, 0.004, 0.11)
    body = mix(
        gain(apply_env(sine(n, 300.0, sweep_to=90.0), fall), 0.55),
        gain(apply_env(sine(n, 600.0, sweep_to=210.0), env_exp(n, 0.002, 0.06)), 0.24),
        gain(apply_env(highpass(noise(n, 0x4B7C), 2200.0),
                       env_exp(n, 0.002, 0.05)), 0.22))
    return fade_edges(normalise(soft_clip(body), 0.74))


def sub_barrier():
    """CHECKSUM BARRIER cast — a shell closing.

       The one sound in the kit with a HARMONIC stack rather than a sweep: a
       root, a fifth and an octave arriving 25 ms apart, which is what a lattice
       assembling sounds like. It resolves UP, unlike everything else here."""
    n = frames(0.8)
    swell = env_exp(n, 0.03, 0.22)
    parts = [gain(apply_env(sine(n, 146.8), swell), 0.40)]
    for i, hz in enumerate([220.0, 293.7]):
        d = frames(0.025 * (i + 1))
        parts.append(gain([0.0] * d + apply_env(sine(n - d, hz),
                                                env_exp(n - d, 0.03, 0.20)), 0.26))
    parts.append(gain(apply_env(lowpass(noise(n, 0x3AF9), 700.0),
                                env_exp(n, 0.06, 0.14)), 0.16))
    return fade_edges(normalise(soft_clip(mix(*parts)), 0.80))


def sub_barrier_hit():
    """A blow absorbed. A short bell-like ping with a fast decay — energy going
       into a lattice and being dissipated by it. Sits ABOVE the creature band so
       it reads over a lunge shriek.

       REMASTER: 0.76 octaves of bandwidth is a filtered tone, not a lattice
       dissipating a blow. The two sines become a struck stack with independent
       decays, and a short low knock arrives with them so the barrier has
       something to be made of."""
    n = frames(0.16)
    ping = struck(n, 880.0, count=5, spread=1.66, decay=0.030, falloff=0.56,
                  tilt=0.85, attack=0.0006, glide=0.985, detune=0.020)
    tick = air(n, 0x6D02, 2600.0, 13000.0, attack=0.0002, decay=0.0040)
    knock = apply_env(sine(n, 208.0, sweep_to=176.0), env_exp(n, 0.0008, 0.020))
    # The settle, 34 ms behind and a fifth down: the lattice redistributing what
    # it just absorbed. A second event is also the only way this class gets any
    # spectral flux — one ping, however good, measures as a single gesture.
    settle = delay_into(struck(n - frames(0.034), 587.0, count=4, spread=1.72,
                               decay=0.016, falloff=0.55, tilt=0.9,
                               attack=0.0006, glide=0.98, detune=0.024),
                        0.034, n)
    body = mix(gain(ping, 0.70), gain(tick, 0.34), gain(knock, 0.40),
               gain(settle, 0.42))
    return fade_edges(voice(body, drive=0.85, peak=0.76), ms=2.0)


def sub_barrier_end():
    """The shell fails. The barrier cast, backwards in spirit: the harmonic stack
       collapses to the root and the root falls away."""
    n = frames(0.45)
    fall = env_exp(n, 0.003, 0.10)
    body = mix(
        gain(apply_env(sine(n, 293.7, sweep_to=146.8), fall), 0.42),
        gain(apply_env(sine(n, 146.8, sweep_to=73.4), fall), 0.40),
        gain(apply_env(highpass(noise(n, 0x8C55), 1500.0),
                       env_exp(n, 0.001, 0.035)), 0.20))
    return fade_edges(normalise(soft_clip(body), 0.76))


def sub_ready():
    """A subroutine finished recompiling. The quietest sound in the game after
       the gauge tick: two soft partials, 55 ms, no noise layer at all. The
       quiet-instrument rule applies to audio too — this fires every few seconds
       in a fight and must never become the fight."""
    n = frames(0.055)
    body = mix(
        gain(apply_env(sine(n, 1320.0), env_exp(n, 0.0006, 0.018)), 0.5),
        # 0.0045 against the root's 0.018: a 4:1 decay ratio rather than 1.5:1.
        # The upper partial has to be clearly gone first or the pair reads as a
        # chord with a fade on it.
        gain(apply_env(sine(n, 1980.0), env_exp(n, 0.0006, 0.0045)), 0.22))
    return fade_edges(normalise(soft_clip(body), 0.55))


def sub_refused():
    """The kit saying no — not enough Cycles, or still recompiling. Deliberately
       the SAME grammar as ui_refusal_glitch_buzz (a short, sour, detuned pair)
       but two octaves lower, because this refusal comes from inside your own
       process rather than from a panel."""
    n = frames(0.14)
    body = mix(
        gain(apply_env(sine(n, 98.0), env_exp(n, 0.002, 0.034)), 0.5),
        gain(apply_env(sine(n, 104.0), env_exp(n, 0.002, 0.034)), 0.45),
        # The contact edge. Short and bright, so the refusal starts as an event
        # and settles into a sour hum rather than being one flat buzz.
        gain(air(n, 0xA140, 900.0, 6000.0, attack=0.0004, decay=0.0055), 0.26),
        gain(apply_env(lowpass(noise(n, 0xA13F), 600.0),
                       env_exp(n, 0.001, 0.012)), 0.20))
    return fade_edges(normalise(soft_clip(body), 0.62))


def descent_rush():
    """The drop shaft ride. 2.2 s of wind through a trunk: band-passed noise that
       opens from a whistle to a roar and closes again, with a slow downward
       pitch drift underneath so the ear reads it as DESCENDING rather than as
       generic wind. Long, because the whole point is that the descent should
       feel like committing rather than like a loading screen."""
    n = frames(2.2)
    shape = env_exp(n, 0.45, 0.75)
    # Two noise bands: a low body that carries the weight, and a high hiss that
    # gives it speed. The high one is enveloped shorter so the rush 'arrives'.
    low = apply_env(lowpass(noise(n, 0x11C7), 380.0), shape)
    high = apply_env(highpass(lowpass(noise(n, 0x22D8), 5200.0), 1600.0),
                     env_exp(n, 0.30, 0.50))
    drift = apply_env(sine(n, 120.0, sweep_to=52.0), shape)
    body = mix(gain(low, 0.62), gain(high, 0.26), gain(drift, 0.30))
    return fade_edges(normalise(soft_clip(body), 0.80), ms=25.0)


def patch_pickup():
    """A hot-patch absorbed off a pocket secretary.

       THE GRAMMAR IS THE CREW'S OWN TECH, not MOTHER's. A slate is human
       hardware — the same box the phosphor HUD came out of — so this is built
       from the interface's family (soft sine partials through a one-pole
       low-pass) rather than from her neon: one hard mechanical click (the
       slate's single button), then a two-note rise that RESOLVES, because the
       event is an acquisition and an unresolved interval would read as a
       warning. 0.34 s, mostly tail.

       Deliberately modest. It fires perhaps four times a layer, and the pickup
       already has a light burst and a caption; a fanfare here would make the
       KERNEL chime below have nowhere to go."""
    n = frames(0.34)
    click = apply_env(highpass(noise(n, 0x9C21), 2600.0), env_exp(n, 0.0008, 0.010))
    lift = env_exp(n, 0.010, 0.11)
    low = apply_env(sine(n, 392.0), lift)
    # The resolution, 70 ms behind: a perfect fifth up. The stagger is what makes
    # it a phrase rather than a chord.
    d = frames(0.07)
    # 0.055 s rather than 0.085: the resolution is the BRIGHT note, and a bright
    # note that outlives the root makes the chime get lighter as it dies. That
    # one number is why this file, and every pickup in the library, measured a
    # centroid that does not fall.
    high = [0.0] * d + gain(apply_env(sine(n - d, 587.0),
                                      env_exp(n - d, 0.008, 0.055)), 0.44)
    warm = apply_env(lowpass(noise(n, 0x3D77), 900.0), env_exp(n, 0.020, 0.110))
    body = mix(gain(click, 0.30), gain(low, 0.50), high, gain(warm, 0.22))
    return fade_edges(normalise(soft_clip(body), 0.74))


def patch_pickup_kernel():
    """A KERNEL patch coming out of an anomaly cache.

       The one moment in the patch economy that is allowed to be a MOMENT: the
       same click-and-rise as its stable sibling, extended into a three-note
       arpeggio over a low swell that arrives UNDER the notes rather than with
       them. 0.9 s. Still not a fanfare — the crew are stealing something, and a
       triumphant sting would fight the room's own dread — but it is the sound
       everyone on voice comment on, which is the point of a rare drop."""
    n = frames(0.9)
    swell = apply_env(sine(n, 98.0, sweep_to=131.0), env_exp(n, 0.12, 0.30))
    body = mix(gain(swell, 0.42))
    # 392 / 587 / 784: the stable chime's two notes plus the octave. A build-
    # defining patch says the same phrase and then keeps going.
    # Each note of the arpeggio is higher AND shorter than the one before it, so
    # the phrase darkens as it resolves instead of brightening.
    for i, hz in enumerate([392.0, 587.0, 784.0]):
        d = frames(0.05 + 0.11 * i)
        body = mix(body, [0.0] * d + gain(
            apply_env(sine(n - d, hz), env_exp(n - d, 0.008, 0.13 * 0.62 ** i)),
            0.44 - 0.06 * i))
    shimmer = apply_env(highpass(lowpass(noise(n, 0x77C3), 7200.0), 3200.0),
                        env_exp(n, 0.10, 0.11))
    return fade_edges(normalise(soft_clip(mix(body, gain(shimmer, 0.13))), 0.80))


def patch_cache_open():
    """An anomaly cache being breached — a pressurised quarantine pod cracking.

       HER hardware, so the grammar flips: no musical partials at all, only
       mechanism. A heavy bolt releasing (a low filtered thump with a metallic
       ring on top), then the seal letting go as a band of noise that opens and
       closes, then the lid taking its own weight. 1.15 s, and the last third is
       the hydraulics — the pod is slow, and it should sound slow.

       REMASTER. This measured a 562 ms attack — the loudest moment of a bolt
       releasing arrived over half a second after the bolt released — and 0.45
       octaves of bandwidth, the narrowest file in the library. Both had one
       cause: the bolt was un-normalised low-passed noise, which a one-pole
       filter returns about 20 dB down, so the LID at 480 ms was the loudest
       thing in a sound whose entire subject is a mechanical release. The
       layers are peak-normalised now (see `air`), and the bolt carries a struck
       shell stack, so the release is broadband, is the peak, and darkens after
       it the way a struck shell does."""
    n = frames(1.15)
    # The bolt. A low thump, the sharp edge of the release, and the shell it is
    # set into ringing — high partials first.
    bolt = air(n, 0x51B9, 95.0, 560.0, attack=0.0006, decay=0.075)
    strike = air(n, 0x51BA, 1100.0, 12000.0, attack=0.0002, decay=0.0110)
    shell = struck(n, 168.0, count=7, spread=1.78, decay=0.16, falloff=0.74,
                   tilt=0.35, attack=0.0005, glide=0.94, detune=0.016)
    # The seal letting go, 100 ms behind: a band of pressure that opens and
    # closes. Roughened, because gas through a gap is not a smooth hiss.
    hiss = am(air(n, 0x2A6F, 800.0, 5400.0, attack=0.090, decay=0.19,
                  delay=0.10), 58.0, 0.45)
    # The lid, arriving late and low: the hydraulic take-up rather than an impact.
    h = frames(0.48)
    # The lid used to be a bare 62 Hz sine held for two thirds of a second, and
    # it was 90 % of this file's power — which is why the whole sound measured
    # 0.45 octaves wide, the narrowest in the library, and why the release was
    # not the loudest thing in a sound about a release. It keeps its own
    # harmonics now (so it is a hydraulic ram and not a test tone) and it is
    # mixed as an aftermath rather than as the subject.
    lid = delay_into(mix(gain(apply_env(jitter_sine(n - h, 62.0, sweep_to=48.0,
                                                    depth=0.02, rate=9.0,
                                                    seed=0x2A70),
                                        env_exp(n - h, 0.09, 0.16)), 1.0),
                         gain(struck(n - h, 124.0, count=4, spread=1.83,
                                     decay=0.10, falloff=0.60, tilt=0.5,
                                     attack=0.030, glide=0.97), 0.55)),
                     0.48, n)
    body = mix(gain(bolt, 0.66), gain(strike, 0.72), gain(shell, 0.95),
               gain(hiss, 0.44), gain(lid, 0.20))
    return fade_edges(voice(body, drive=0.80, peak=0.86), ms=8.0)


def patch_watchdog():
    """WATCHDOG firing — the timer nobody kicked, kicking.

       It has to be legible at the exact instant a player is about to be knocked
       down, over a fight, so it is a MECHANICAL LATCH and not a tone: a hard
       high transient (the relay), a short square-ish 147 Hz body (the assertion),
       and the shell's own hum rising underneath for 0.35 s. Related to
       sub_barrier by that last layer on purpose — it IS a checksum barrier, and
       the ear should be told so.

       REMASTER: an alarm is graded on ROUGHNESS and on the 800-2500 Hz band,
       because that is how a real klaxon is noticed without being shrill — and
       this one had 0.09 of the first and 0.0001 of the second. Both are added
       here as structure rather than level: the assertion is modulated at 58 Hz
       (roughness, not tremolo) and its harmonics now reach into the ear's most
       sensitive band, which is the free lane in a firefight."""
    n = frames(0.62)
    latch = air(n, 0x6E11, 3200.0, 15000.0, attack=0.0004, decay=0.012)
    slam = air(n, 0x1C93, 90.0, 620.0, attack=0.0015, decay=0.038)
    # The assertion, with partials up into 800-2500 and a 58 Hz grind on it.
    assertion = am(am(struck(n, 147.0, count=7, spread=1.94, decay=0.070,
                             falloff=0.84, tilt=0.30, attack=0.0030, glide=0.99),
                      62.0, 1.00), 43.0, 0.55)
    # The 800-2500 Hz band explicitly, because that is the criterion and because
    # it is the lane a watchdog has to cut through a firefight in. Modulated at
    # the same rate as the assertion so the two read as one buzzer.
    bite = am(air(n, 0x6E13, 850.0, 2100.0, attack=0.0006, decay=0.13),
              62.0, 1.00)
    d = frames(0.04)
    hum = delay_into(am(apply_env(sine(n - d, 294.0, sweep_to=330.0),
                                  env_exp(n - d, 0.05, 0.13)), 41.0, 0.75),
                     0.04, n)
    body = mix(gain(latch, 0.70), gain(slam, 0.40), gain(assertion, 0.46),
               gain(bite, 1.15), gain(hum, 0.34))
    return fade_edges(voice(body, drive=1.05, peak=0.82))



# ===========================================================================
# THE REMASTER — classes that had no generator at all
# ===========================================================================
#
# A finding that has to be written down because it shapes everything below:
# of the 167 .ogg files in assets/audio, this tool built 17 and
# tools/audio/build_mother_voice.py built 15. THE OTHER 135 HAVE NO SOURCE IN
# THE REPOSITORY. They were rendered once, during M5, by something that was
# never committed. Every one of the audit's headline offenders — the breaker,
# the Scrubber's whole vocabulary, the collapsed variant families — is in that
# unsourced 135, so "re-render the affected classes" could not mean re-running
# anything. It meant writing the instrument for them.
#
# That is what this section is. Each family below re-creates a shipped asset
# NAME with the same role in the same event table (nothing in
# src/core/audio_service.gd changes), built to the objective in
# tools/soundlab/classes.py, and under the centroid law above. The assets are
# now reproducible, which they were not this morning.
#
# The variant families are parameter TABLES rather than loops over a seed. That
# is the fix for the audit's other finding: six `datachip_pickup` files sat
# 0.075 sigma apart in descriptor space, which is one sound wearing six
# filenames, because they differed only by an RNG seed and a seed does not move
# a perceptual descriptor. Real variation is a different note, a different
# decay, a different balance — so each row below states those explicitly and
# the spread is verified by tools/soundlab/audit.py's clustering.


# -- the breaker -------------------------------------------------------------
#
# The audit's worst class in the game, by a distance: weapon_fire scored
# 0.36-0.43 where the library median is 0.86. The measurements said the loudest
# moment of the breaker discharging arrived 57-61 ms after the trigger, with a
# static centroid and essentially nothing below 250 Hz — which is not a
# description of a gun. It is a description of a breathing loop, and indeed the
# clustering put breaker_shot_02 within 0.365 sigma of
# player_breath_critical_loop. The milestone that just extended the weapon's
# reach to 30 m makes that more exposed, not less.
#
# So this is built transient-first, in the order the physics happens:
#
#   1. CRACK      2 ms of broadband noise. This is the event. It must be the
#                 loudest sample in the file and it must be at t=0, because the
#                 player's finger moved at t=0 and everything else is a
#                 consequence.
#   2. SNAP       the mid-band body of the discharge, 15 ms.
#   3. BODY       the weapon's own note, an inharmonic stack whose partials die
#                 top-down (the centroid law).
#   4. SUB        THE LAYER THAT DID NOT EXIST. The lab's own search could not
#                 find this: its weapon recipe floored the lowest oscillator at
#                 60 Hz, so every candidate it shortlisted measured band_sub =
#                 0.000, and the objective only set a minimum on band_low, so
#                 nothing ever complained. A search can only find what its
#                 parameter space contains. Both the layer and a band_sub
#                 minimum in classes.py were added together.
#   5. TAIL       the discharge venting; low, and arriving 10 ms late so it
#                 reads as an aftermath rather than as part of the hit.
#
# TWO VOICINGS, and the choice between them is the user's, not the tool's. The
# search's shortlist offered a near-pure low thump (candidate 06) and a
# broadband crack (candidate 08); both are built here from the same structure,
# so the transient, the sub and the falling centroid are identical and only the
# balance differs. Flip BREAKER_VOICING to switch the shipping set; the audition
# pair is rendered by `--ab`.
BREAKER_VOICING = "thump"

BREAKER_MIX = {
    # crack  snap  body   sub  tail   — the two candidate voicings.
    # "thump" is the audition's candidate 06 — the near-pure ~200 Hz thump. The
    # 200 Hz is the BODY layer, not the sub: the sub is there so the shot is felt
    # as well as heard, and at 0.34 it sits under the body rather than replacing
    # it. Mixed the other way round the shot measures 90 % of its power below
    # 80 Hz, which is a kick drum, not a breaker.
    "thump": (0.46, 0.34, 1.00, 0.34, 0.30),   # cand. 06: weight forward
    "broad": (0.90, 0.72, 0.56, 0.24, 0.40),   # cand. 08: crack forward
}

# Four shots that are four shots. The old set sat 0.402 sigma apart — "thin" in
# the audit's terms, and audibly one sound at the fire rate. Body note, sub
# note, decay and length all move; a magnetic weapon that lands on exactly the
# same note four times is a sample, and the ear works that out fast.
# The last three columns tilt the voicing per shot without leaving it: a coil
# that has just fired is hotter than one that has been idle, so shot to shot the
# crack, the body and the vent are not in the same proportion. Four shots that
# differ only in pitch measure 0.10 sigma apart on the nearest pair and the ear
# hears a sample being retriggered; these numbers are what take the family off
# the audit's collapse list.
BREAKER_VARIANTS = [
    # dur    body_hz  sub_hz  body_dec  crack_dec  x_crack x_body x_tail  seed
    (0.300,  196.0,   47.0,   0.052,    0.0034,    1.00,   1.00,  1.00,   0x4B01),
    (0.185,  268.0,   62.0,   0.030,    0.0020,    1.35,   0.90,  0.40,   0x4B02),
    (0.460,  152.0,   36.0,   0.088,    0.0052,    0.70,   1.15,  1.80,   0x4B03),
    (0.345,  232.0,   44.0,   0.068,    0.0026,    1.25,   0.78,  1.60,   0x4B04),
]


def breaker_shot(i, voicing=None):
    """The breaker discharging. See the block comment above."""
    (dur, body_hz, sub_hz, body_dec, crack_dec,
     x_crack, x_body, x_tail, seed) = BREAKER_VARIANTS[i]
    g_crack, g_snap, g_body, g_sub, g_tail = BREAKER_MIX[voicing or BREAKER_VOICING]
    n = frames(dur)
    # 1. The event. 0.15 ms of attack: this has to BE the transient.
    crack = air(n, seed, 2400.0, 15000.0, attack=0.00015, decay=crack_dec)
    # 2. The discharge proper.
    snap = air(n, seed + 1, 650.0, 3600.0, attack=0.0003, decay=crack_dec * 4.2)
    # 3. The weapon's note, darkening as it goes.
    body = struck(n, body_hz, count=4, spread=1.93, decay=body_dec,
                  falloff=0.44, tilt=1.15, attack=0.0004, glide=0.82)
    # 4. The floor. Sweeping down hard — a discharge unloads.
    sub = apply_env(jitter_sine(n, sub_hz, sweep_to=sub_hz * 0.60, curve=1.9,
                                depth=0.020, rate=34.0, seed=seed + 2),
                    env_exp(n, 0.0012, body_dec * 2.10))
    # 5. Venting. 10 ms late, low, and rough: gas leaving a hot coil.
    tail = am(air(n, seed + 3, 130.0, 620.0, attack=0.004,
                  decay=body_dec * 0.95, delay=0.010), 74.0, 0.35)
    out = mix(gain(crack, g_crack * x_crack), gain(snap, g_snap * x_crack),
              gain(body, g_body * x_body), gain(sub, g_sub * x_body),
              gain(tail, g_tail * x_tail))
    return fade_edges(voice(out, drive=0.72, peak=0.90), ms=2.0)


# -- datachip pickup ---------------------------------------------------------
#
# The worst variant collapse in the library: six files 0.075 sigma apart, i.e.
# measurably ONE sound. Players have been hearing a single clip six times and
# believing it varied, which is worse than having one file, because the game
# pays six times the memory to lie about it.
#
# Six genuinely different acquisitions instead. The grammar stays — the crew's
# own hardware, a mechanical contact then a pitched resolution, per the
# `patch_pickup` note above — but each row picks a different interval, a
# different chip note, a different contact brightness and a different stagger.
# The intervals are all consonant and all RESOLVE (an acquisition that ends on
# a tritone reads as a warning), which is the constraint that makes this a set
# rather than six random chimes.
# Six rows, and the columns after `stagger` are the ones that make this a set
# rather than six transpositions. A different NOTE moves centroid_hz and nothing
# else, and centroid_hz is one axis of twenty-three in the similarity vector —
# which is why the shipped family, whose members differed by a seed, measured
# 0.075 sigma apart. Balance, partial structure and contact character move
# crest, bandwidth, flatness, HNR and band split, and those are the axes the
# clustering actually looks at.
DATACHIP_VARIANTS = [
    # root  intvl   dur   click_hp  decay  stagger  g_click g_low g_high g_warm np fall seed
    (523.3, 1.500, 0.24,  3100.0,  0.062,  0.046,   0.40,  0.62, 0.34, 0.24, 4, 0.42, 0x7A01),
    (466.2, 1.335, 0.34,  1700.0,  0.105,  0.082,   0.16,  0.70, 0.20, 0.62, 5, 0.62, 0x7A02),
    (587.3, 1.260, 0.20,  5600.0,  0.042,  0.030,   0.78,  0.44, 0.46, 0.16, 3, 0.30, 0x7A03),
    (392.0, 2.000, 0.42,  1500.0,  0.140,  0.110,   0.22,  0.80, 0.14, 0.50, 6, 0.70, 0x7A04),
    (659.3, 1.200, 0.16,  7200.0,  0.030,  0.022,   0.92,  0.66, 0.30, 0.10, 2, 0.24, 0x7A05),
    (440.0, 1.680, 0.31,  2400.0,  0.090,  0.072,   0.28,  0.50, 0.66, 0.52, 5, 0.56, 0x7A06),
]


def datachip_pickup(i):
    """A datachip read off a dead terminal. One of six, and they differ."""
    (root, interval, dur, click_hp, decay, stagger,
     g_click, g_low, g_high, g_warm, npart, fall, seed) = DATACHIP_VARIANTS[i]
    n = frames(dur)
    # The contact: the reader's own leaf spring. Brightness varies per chip
    # because the sockets in this station were not all made in the same decade.
    click = air(n, seed, click_hp, 14000.0, attack=0.0002, decay=0.0045)
    # The read. Partials with independent decays so the chime darkens as it
    # rings — a chime with one envelope is the definition of "generic chime",
    # and this family was the audit's STATIC-SPECTRUM exhibit.
    low = struck(n, root, count=int(npart), spread=2.01, decay=decay,
                 falloff=fall, tilt=0.95, attack=0.0018, glide=0.999)
    # The resolution, staggered behind. The stagger is what makes it a phrase.
    m = n - frames(stagger)
    # The resolution decays to HALF the root's length. It is the brighter of
    # the two notes, so if it outlives the root the chime gets brighter as it
    # dies — which is what the whole family did, and why all six were flagged
    # STATIC-SPECTRUM.
    high = delay_into(struck(m, root * interval, count=2, spread=2.01,
                             decay=decay * 0.30, falloff=0.42, tilt=1.4,
                             attack=0.0015, glide=0.999), stagger, n)
    # A breath of the terminal's own hum under it, so the pickup belongs to the
    # box it came out of rather than floating over it.
    # The terminal's own hum: low, and the LONGEST decay in the sound, so what
    # is left at the end is the dark half. Also the only thing in this family
    # with any energy under 250 Hz — all six shipped files were NO-LOW-END.
    warm = air(n, seed + 1, 95.0, 330.0, attack=0.006, decay=decay * 3.0,
               order=3)
    out = mix(gain(click, g_click), gain(low, g_low), gain(high, g_high),
              gain(warm, g_warm))
    return fade_edges(voice(out, drive=0.75, peak=0.80), ms=3.0)


# -- the Scrubber's voice ----------------------------------------------------
#
# Three collapsed families in one animal: lunge shrieks 0.088 sigma apart, hurt
# 0.118, idle chitters 0.129. The whole creature measured as about one and a
# half sounds, and all of it was flagged NO-LOW-END and (for the idles)
# FLAT-ENVELOPE at 5-6 dB of range.
#
# The instrument is a throat rather than an oscillator, and the difference is
# four things the old set had none of: a fundamental that WANDERS
# (`jitter_sine`), inharmonic partials, amplitude modulation at 60-100 Hz
# (`am` — this is roughness, the measurable correlate of a snarl), and a
# subharmonic that beats against the root. A rising smooth tone is a siren. A
# rising rough unsteady one is an animal.

SCRUBBER_LUNGE = [
    # dur   f0     climb  am_hz  am_d  jit    hold   seed
    (0.72,  190.0, 3.10,  72.0,  0.95, 0.045, 0.10,  0x3C01),
    (1.05,  148.0, 3.90,  64.0,  0.98, 0.058, 0.16,  0x3C02),
    (0.86,  232.0, 2.55,  81.0,  0.92, 0.038, 0.06,  0x3C03),
]


def scrubber_lunge_shriek(i):
    """The tell, 300-600 ms before it commits. It must RISE and it must snarl."""
    dur, f0, climb, am_hz, am_d, jit, hold, seed = SCRUBBER_LUNGE[i]
    n = frames(dur)
    # The throat. Climbing, unsteady, inharmonic — `detune` stretches partial k
    # to k*(1+detune*k), which is what a stiff irregular resonator does and what
    # a pure harmonic series never does.
    voice_l = [0.0] * n
    for k in range(1, 6):
        mult = k * (1.0 + 0.021 * k)
        part = jitter_sine(n, f0 * mult, sweep_to=f0 * mult * climb, curve=1.35,
                           depth=jit, rate=26.0 + 7.0 * k, seed=seed + k)
        amp = 1.0 / (k ** 0.85)
        for j in range(n):
            voice_l[j] += part[j] * amp
    # The subharmonic. It beats against the root and it is most of what makes a
    # small thing sound like it has a chest.
    subh = jitter_sine(n, f0 * 0.5, sweep_to=f0 * 0.5 * climb, curve=1.35,
                       depth=jit * 0.7, rate=19.0, seed=seed + 11)
    # Breath. Sweeps with the pitch, because a fixed noise band under a rising
    # voice reads as two unrelated sounds.
    breath = air(n, seed + 21, f0 * 1.6, f0 * 5.5, attack=0.030,
                 decay=dur * 0.55)
    body = mix(gain(voice_l, 0.62), gain(subh, 0.40), gain(breath, 0.30))
    # Two modulation rates, because a single AM is a tremolo pedal and two
    # beating against each other is a texture.
    body = am(am(am(body, am_hz, am_d), am_hz * 0.61 + 5.0, 0.55),
              am_hz * 1.43, 0.34)
    env = env_exp(n, 0.055, dur * 0.42)
    # Hold the top: a wind-up that starts decaying the instant it peaks never
    # reads as a commitment about to be made.
    h = frames(hold)
    for j in range(min(h, n)):
        idx = frames(0.055) + j
        if idx < n:
            env[idx] = 1.0
    return fade_edges(voice(apply_env(body, env), drive=1.35, peak=0.88), ms=5.0)


SCRUBBER_CHITTER = [
    # dur   grains  lo      hi      dec     am_hz  seed
    (0.46,  6,      900.0,  4200.0, 0.016,  78.0,  0x3D01),
    (0.62,  9,      620.0,  2900.0, 0.011,  64.0,  0x3D02),
    (0.38,  5,      1250.0, 5600.0, 0.022,  92.0,  0x3D03),
]


def scrubber_idle_chitter(i):
    """Mutters. Their only job is to be varied, and they were not.

       The audit measured 5.6-6.9 dB of envelope range on this family — a flat
       wash, no articulation, three files 0.13 sigma apart. A chitter is
       DISCRETE EVENTS: `grains` places an irregular train of short bursts with
       silence between them, which is where envelope range and spectral flux
       come from. It is also the difference between a creature muttering and a
       hiss with a name."""
    dur, count, lo, hi, dec, am_hz, seed = SCRUBBER_CHITTER[i]
    n = frames(dur)
    clicks = grains(n, seed, count, lo, hi, dec, spread=0.30, pitch=0.45,
                    darken=0.26)
    # A body under the clicks so it has a throat rather than only teeth, and so
    # the family stops tripping NO-LOW-END: every one of these had less than
    # -46 dB of its power under 250 Hz.
    throat = [0.0] * n
    for k in range(1, 4):
        part = jitter_sine(n, lo * 0.24 * k * (1.0 + 0.03 * k),
                           depth=0.09, rate=34.0, seed=seed + 40 + k)
        for j in range(n):
            throat[j] += part[j] / (k ** 1.1)
    throat = am(apply_env(throat, env_exp(n, 0.012, dur * 0.30)), am_hz, 0.80)
    # Gate the throat with the grain train so the body articulates WITH the
    # clicks instead of droning underneath them.
    peak = max(abs(v) for v in clicks) or 1.0
    duck = lowpass([abs(v) / peak for v in clicks], 90.0)
    dtop = max(duck) or 1.0
    throat = [v * (0.15 + 0.85 * (g / dtop)) for v, g in zip(throat, duck)]
    out = mix(gain(clicks, 0.80), gain(throat, 0.55))
    return fade_edges(voice(out, drive=1.25, peak=0.82), ms=3.0)


SCRUBBER_HURT = [
    # dur   f0     fall  am_hz  g_yelp g_hit g_chest seed
    (0.34,  296.0, 0.58,  74.0, 0.34,  1.00, 0.22,   0x3E01),
    (0.21,  438.0, 0.36,  63.0, 0.62,  1.00, 0.14,   0x3E02),
]


def scrubber_hurt(i):
    """Damage feedback. Must be legible UNDER weapon fire, which is a band
       argument rather than a level one: the breaker owns the high-mid, so this
       lives in 800-2500 Hz, the ear's most sensitive band and the free lane."""
    dur, f0, fall, am_hz, g_yelp, g_hit, g_chest, seed = SCRUBBER_HURT[i]
    n = frames(dur)
    yelp = [0.0] * n
    for k in range(1, 5):
        mult = k * (1.0 + 0.028 * k)
        part = jitter_sine(n, f0 * mult, sweep_to=f0 * mult * fall, curve=0.65,
                           depth=0.055, rate=40.0, seed=seed + k)
        for j in range(n):
            yelp[j] += part[j] / (k ** 0.75)
    yelp = am(am(yelp, am_hz, 0.98), am_hz * 0.54 + 4.0, 0.45)
    # The impact half — something struck a shell. Bright, and gone in 8 ms.
    hit = air(n, seed + 9, 1100.0, 9000.0, attack=0.0002, decay=0.010)
    chest = apply_env(jitter_sine(n, f0 * 0.33, sweep_to=f0 * 0.33 * fall,
                                  depth=0.04, rate=22.0, seed=seed + 17),
                      env_exp(n, 0.002, dur * 0.30))
    out = mix(gain(apply_env(yelp, env_exp(n, 0.0020, dur * 0.34)), g_yelp),
              gain(hit, g_hit), gain(chest, g_chest))
    return fade_edges(voice(out, drive=1.20, peak=0.84), ms=3.0)


SCRUBBER_SKITTER = [
    # dur   grains  lo      hi      dec     seed
    (1.10,  17,     700.0,  3400.0, 0.010,  0x3F01),
    (1.35,  24,     500.0,  2400.0, 0.0075, 0x3F02),
    (0.92,  13,     980.0,  4400.0, 0.014,  0x3F03),
]


def scrubber_skitter_loop(i):
    """Claws on deck plate. A LOOP, so it must not have an event at its seam.

       Flagged SHRILL in the audit (all three of them) and 0.232 sigma apart.
       The shrillness was a band problem — nothing under 250 Hz and everything
       above 3 kHz — so the claws now land on a plate that answers them, and
       the top is rolled off. The loop is built to begin and end inside a gap
       between grains, so a 2 ms edge fade is inaudible rather than a click
       once per cycle."""
    dur, count, lo, hi, dec, seed = SCRUBBER_SKITTER[i]
    n = frames(dur)
    claws = grains(n, seed, count, lo, hi, dec, spread=0.42, pitch=0.0,
                   jitterish=0.30, darken=1.0)
    # The deck answering. Each claw excites the plate under it, so the plate ring
    # is gated by the claw envelope — that is the cue that says "on metal".
    plate = struck(n, 118.0, count=4, spread=1.78, decay=0.070, falloff=0.50,
                   tilt=1.4, attack=0.0006, glide=0.99)
    peak = max(abs(v) for v in claws) or 1.0
    duck = lowpass([abs(v) / peak for v in claws], 55.0)
    dtop = max(duck) or 1.0
    plate = [v * (g / dtop) for v, g in zip(plate, duck)]
    # A little body so the thing has a mass. Under 80 Hz, which is the cue that
    # survives a bulkhead.
    mass = am(apply_env(lowpass(noise(n, seed + 5), 90.0),
                        env_exp(n, 0.02, dur)), 41.0, 0.65)
    out = mix(gain(lowpass(claws, 5200.0), 0.72), gain(plate, 0.50),
              gain(mass, 0.30))
    return fade_edges(voice(out, drive=0.95, peak=0.82), ms=2.0)


# -- the player's own body ---------------------------------------------------

# The last four columns are what stops these being one grunt pitched three ways.
# The shipped set measured 0.133 sigma apart on the perceptual descriptors, and
# a fundamental is only one of twenty-three axes: how much CATCH is in the front
# of it, how many partials the chest carries, how fast the voice falls and how
# much breath escapes afterwards move crest, bandwidth, flatness and HNR, which
# are the ones the clustering reads.
PLAYER_HURT = [
    # dur   f0     fall  am_hz  breath  g_catch nharm decay_x  seed
    (0.30,  138.0, 0.70,  58.0, 0.20,   0.62,   7,    0.24,    0x5E01),
    (0.52,  108.0, 0.86,  66.0, 0.52,   0.14,   4,    0.42,    0x5E02),
    (0.40,  162.0, 0.58,  51.0, 0.34,   0.36,   9,    0.30,    0x5E03),
]


def player_hurt(i):
    """A grunt. Intimate, close-mic, never heroic — and three of them that are
       three of them (the shipped set measured 0.131 sigma apart).

       Proximity effect is the whole class: a close voice has chest in it, and
       without the 80-250 Hz band it sounds like it is happening to somebody
       else, which in a first-person game is the entire failure."""
    dur, f0, fall, am_hz, bg, g_catch, nharm, decay_x, seed = PLAYER_HURT[i]
    n = frames(dur)
    chest = [0.0] * n
    for k in range(1, int(nharm) + 1):
        mult = k * (1.0 + 0.012 * k)
        part = jitter_sine(n, f0 * mult, sweep_to=f0 * mult * fall, curve=1.5,
                           depth=0.030, rate=17.0 + 5.0 * k, seed=seed + k)
        for j in range(n):
            chest[j] += part[j] / (k ** 1.05)
    chest = am(chest, am_hz, 0.55)
    # The glottal catch at the front — the involuntary part, 4 ms.
    catch = air(n, seed + 8, 260.0, 2400.0, attack=0.0008, decay=0.012)
    # Breath escaping after the voice stops. Its own envelope, arriving late:
    # the exhale is a consequence of the grunt, not part of it.
    # Darker than the voice, on purpose. An exhale that is BRIGHTER than the
    # grunt it follows makes the whole sound get lighter as it ends, which is
    # the inverse of what a body does; the shipped player_hurt set measured
    # -2.9 to -3.3 octaves of centroid movement for exactly this reason.
    breath = air(n, seed + 12, 210.0, 1050.0, attack=0.030,
                 decay=dur * 0.38, delay=dur * 0.22)
    out = mix(gain(apply_env(chest, env_exp(n, 0.010, dur * decay_x)), 0.78),
              gain(catch, g_catch), gain(breath, bg * 0.62))
    return fade_edges(voice(out, drive=0.90, peak=0.80), ms=4.0)


# -- named offenders ---------------------------------------------------------

def sentinel_death_collapse():
    """A Sentinel hitting the deck. Rank 5 in the audit at 0.462.

       Its defect was structural and slightly absurd for an IMPACT: a 78 ms
       attack, so the loudest moment of a two-tonne machine falling over arrived
       a twelfth of a second after it hit. Plus 16 seconds of T60 in a 5 s file
       and 2.5 octaves of bandwidth.

       Rebuilt as what it is: contact, then the frame failing, then the mass
       arriving, then debris. Four events with valleys between them, each with
       its own decay, brightest first."""
    n = frames(1.35)
    # 1. Contact. This is the event, and it is at zero.
    hit = air(n, 0x6A01, 700.0, 14000.0, attack=0.00012, decay=0.0165)
    # 2. The frame. A big inharmonic plate stack — this is the "size" of it.
    # tilt 0.55 and falloff 0.66: the partials still die top-down (the centroid
    # law holds) but they are LOUD on the way. A two-tonne machine failing is
    # mostly metal, and an impact whose spectrum is 1.3 octaves wide is a filtered
    # tone with a name — the audit's NARROW-BAND flag, which this file also had.
    frame = struck(n, 108.0, count=7, spread=1.69, decay=0.26, falloff=0.66,
                   tilt=0.55, attack=0.0004, glide=0.955, detune=0.014)
    # 3. The mass, arriving 45 ms behind the contact because a falling body
    #    lands before its weight does.
    mass_n = n - frames(0.045)
    mass = delay_into(apply_env(jitter_sine(mass_n, 52.0, sweep_to=31.0,
                                            curve=1.8, depth=0.018, rate=14.0,
                                            seed=0x6A02),
                                env_exp(mass_n, 0.0025, 0.34)), 0.045, n)
    # 4. Debris. Granulated, late, and rough — the structure complaining.
    # Debris rides at 260-2200 rather than 260-5200: it is rubble settling
    # inside a structure, and anything brighter than that late in the file
    # inverts the centroid trajectory of the whole sound.
    deb = am(air(n, 0x6A03, 240.0, 2600.0, attack=0.030, decay=0.30,
                 delay=0.11), 46.0, 0.85)
    # 5. The room taking it.
    room = air(n, 0x6A04, 60.0, 340.0, attack=0.070, decay=0.46, delay=0.09)
    # The contact is mixed to sit CLEARLY above the mass, not level with it.
    # At equal envelope height the two peaks are inside a few tenths of a dB of
    # each other, and Vorbis moves an envelope peak by about that much — so
    # which event the attack is measured to flips between the float buffer and
    # the file the game actually plays (8 ms vs 48 ms, same signal). A struck
    # thing's contact should be the loudest moment of it by a margin anyway.
    out = mix(gain(hit, 4.20), gain(frame, 1.05), gain(mass, 0.40),
              gain(deb, 0.22), gain(room, 0.16))
    return fade_edges(voice(out, drive=0.62, peak=0.92), ms=8.0)


def hound_howl():
    """The Hound calling. 4.6 s at 5.2 dB of envelope range in the shipped file:
       a flat wash, not a howl, and the audit said so.

       A howl is SHAPED — it is taken, it swells, it BREAKS, and it falls away.
       The break is the part that matters and the part the old file had no
       equivalent of: the register jump where the voice cracks into its upper
       partials. That is one line here (a second stack that arrives at the
       break) and it is most of the difference between an animal and a pad.

       Graded on carry rather than on transient: this exists to be heard through
       two bulkheads, and low frequencies are what diffract around geometry and
       survive Godot's occlusion filtering."""
    n = frames(3.40)
    # The fundamental, rising into the break then falling away after it.
    f0 = 96.0
    body = [0.0] * n
    for k in range(1, 8):
        mult = k * (1.0 + 0.009 * k)
        part = jitter_sine(n, f0 * mult, sweep_to=f0 * mult * 1.62, curve=0.55,
                           depth=0.022, rate=9.0 + 4.0 * k, seed=0x7B00 + k)
        for j in range(n):
            body[j] += part[j] / (k ** 1.15)
    # The rasp. Two beating modulations, deep — this is the animal.
    body = am(am(body, 74.0, 0.80), 27.0, 0.34)
    # THE SHAPE. Swell, break, second swell, fall. Written as an explicit
    # breakpoint envelope rather than an AD, because an AD cannot articulate and
    # the whole finding on this file was that it does not articulate.
    pts = [(0.00, 0.00), (0.16, 0.34), (0.30, 0.72), (0.38, 0.44),
           (0.46, 1.00), (0.62, 0.86), (0.74, 0.30), (0.88, 0.10),
           (1.00, 0.00)]
    shape = []
    for j in range(n):
        u = j / max(n - 1, 1)
        for a, b in zip(pts, pts[1:]):
            if a[0] <= u <= b[0]:
                t = (u - a[0]) / max(b[0] - a[0], 1e-9)
                shape.append(a[1] + (b[1] - a[1]) * (t * t * (3 - 2 * t)))
                break
        else:
            shape.append(0.0)
    # The break: the register crack at 38 % through, where the shape dips.
    brk_n = n - frames(3.40 * 0.375)
    crack = delay_into(apply_env(
        struck(brk_n, f0 * 3.1, count=4, spread=1.66, decay=0.34, falloff=0.58,
               tilt=0.95, attack=0.012, glide=1.18, detune=0.02),
        env_exp(brk_n, 0.020, 0.55)), 3.40 * 0.375, n)
    # The chest, carrying under everything so it survives a wall.
    chest = apply_env(jitter_sine(n, 58.0, sweep_to=46.0, curve=1.2,
                                  depth=0.015, rate=6.0, seed=0x7BEE),
                      env_exp(n, 0.20, 1.30))
    out = mix(gain(apply_env(body, shape), 0.80), gain(crack, 0.40),
              gain(apply_env(chest, shape), 0.46))
    return fade_edges(voice(out, drive=1.15, peak=0.86), ms=25.0)


PLAYER_LAND = [
    # dur   plate_hz  sub_hz  g_boot g_grate g_plate g_sub  seed
    (0.50,  168.0,    46.0,   0.62,  0.70,   1.00,   0.42,  0x8C01),
    (0.34,  248.0,    36.0,   1.00,  0.96,   0.62,   0.18,  0x8C02),
]


def player_land_grate(i):
    """Landing on grating. Both shipped files missed band_sub and both had a
       centroid that rises; this is the footfall recipe with the centroid law
       applied and a sub layer that was simply absent."""
    (dur, plate_hz, sub_hz, g_boot, g_grate, g_plate, g_sub,
     seed) = PLAYER_LAND[i]
    n = frames(dur)
    boot = air(n, seed, 1100.0, 11000.0, attack=0.00015, decay=0.0045)
    grate = am(air(n, seed + 1, 320.0, 2600.0, attack=0.0004, decay=0.030),
               58.0, 0.45)
    plate = struck(n, plate_hz, count=6, spread=1.76, decay=0.075, falloff=0.62,
                   tilt=0.70, attack=0.0004, glide=0.96, detune=0.011)
    sub = apply_env(jitter_sine(n, sub_hz, sweep_to=sub_hz * 0.64, curve=1.8,
                                depth=0.015, rate=24.0, seed=seed + 2),
                    env_exp(n, 0.0015, 0.095))
    room = air(n, seed + 3, 90.0, 520.0, attack=0.012, decay=dur * 0.45,
               delay=0.014)
    out = mix(gain(boot, g_boot), gain(grate, g_grate), gain(plate, g_plate),
              gain(sub, g_sub), gain(room, 0.24))
    return fade_edges(voice(out, drive=0.70, peak=0.88), ms=3.0)

SOUNDS = {
    "ui/ui_hit_confirm.ogg": hit_confirm,
    "ui/ui_shaft_siphon.ogg": shaft_siphon,
    # M7 subroutines
    "player/sub_step_whump.ogg": sub_step,
    "player/sub_stack_pulse.ogg": sub_pulse,
    "player/sub_fork_cast.ogg": sub_fork,
    "player/sub_fork_hit.ogg": sub_fork_hit,
    "player/sub_fork_end.ogg": sub_fork_end,
    "player/sub_barrier_cast.ogg": sub_barrier,
    "player/sub_barrier_hit.ogg": sub_barrier_hit,
    "player/sub_barrier_end.ogg": sub_barrier_end,
    "ui/ui_sub_ready.ogg": sub_ready,
    "ui/ui_sub_refused.ogg": sub_refused,
    # M7 juice
    "world/dropshaft_rush.ogg": descent_rush,
    # M9 patches
    "world/patch_pickup.ogg": patch_pickup,
    "world/patch_pickup_kernel.ogg": patch_pickup_kernel,
    "world/patch_cache_open.ogg": patch_cache_open,
    "world/patch_watchdog.ogg": patch_watchdog,
}

# The remaster's adoptions. Same filenames, same rows in the event tables in
# src/core/audio_service.gd — nothing is renamed and nothing is added, because a
# rename would be a wiring change and these are asset replacements. What is new
# is that they have a source.
for _i in range(4):
    SOUNDS["weapons/breaker_shot_%02d.ogg" % (_i + 1)] = \
        (lambda k: lambda: breaker_shot(k))(_i)
for _i in range(6):
    SOUNDS["world/datachip_pickup_%02d.ogg" % (_i + 1)] = \
        (lambda k: lambda: datachip_pickup(k))(_i)
for _i in range(3):
    SOUNDS["creatures/scrubber_lunge_shriek_%02d.ogg" % (_i + 1)] = \
        (lambda k: lambda: scrubber_lunge_shriek(k))(_i)
    SOUNDS["creatures/scrubber_idle_chitter_%02d.ogg" % (_i + 1)] = \
        (lambda k: lambda: scrubber_idle_chitter(k))(_i)
    SOUNDS["creatures/scrubber_skitter_loop_%02d.ogg" % (_i + 1)] = \
        (lambda k: lambda: scrubber_skitter_loop(k))(_i)
    SOUNDS["player/player_hurt_%02d.ogg" % (_i + 1)] = \
        (lambda k: lambda: player_hurt(k))(_i)
for _i in range(2):
    SOUNDS["creatures/scrubber_hurt_%02d.ogg" % (_i + 1)] = \
        (lambda k: lambda: scrubber_hurt(k))(_i)
    SOUNDS["player/player_land_grate_%02d.ogg" % (_i + 1)] = \
        (lambda k: lambda: player_land_grate(k))(_i)
SOUNDS["creatures/sentinel_death_collapse.ogg"] = sentinel_death_collapse
SOUNDS["creatures/hound_howl.ogg"] = hound_howl
del _i


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "assets", "audio"))
    ap.add_argument("--only", default="")
    ap.add_argument("--ab", default="", metavar="DIR",
                    help="render both breaker voicings side by side for an "
                         "audition. Writes DIR/thump/ and DIR/broad/ with the "
                         "same filenames, so the pair can be sent as a pair. "
                         "Nothing here decides which one ships; "
                         "BREAKER_VOICING does, and a human sets it.")
    args = ap.parse_args()
    if args.ab:
        global BREAKER_VOICING
        for v in ("thump", "broad"):
            BREAKER_VOICING = v
            for i in range(4):
                rel = "weapons/breaker_shot_%02d.ogg" % (i + 1)
                write(os.path.join(args.ab, v, rel), breaker_shot(i, v), rel)
        return 0
    for rel, fn in SOUNDS.items():
        if args.only and args.only not in rel:
            continue
        write(os.path.join(args.out, rel), fn(), rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
