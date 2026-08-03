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
}


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
    # A sub-bass whump has an enormous crest factor: a single 40 Hz cycle owns the
    # true peak while contributing almost nothing to integrated loudness, so the
    # ceiling eats the entire gain and the sound lands 5 dB under the library. One
    # tanh stage buys most of that back — it is a soft limiter, not a distortion
    # effect, and at these drives it is inaudible on the fundamental. Applied only
    # when the ceiling actually bound by more than a dB, so nothing that did not
    # need it is touched.
    if report["limited_db"] > 1.0:
        drive = 10.0 ** (min(report["limited_db"], 6.0) / 20.0)
        scaled, report = bs1770.normalise_to(np.tanh(x * drive) / np.tanh(drive),
                                             RATE, target, CEILING_DBTP)
    if verbose:
        print("[sfx]   loudness %.1f -> %.1f LUFS (%+.1f dB, %.1f dBTP%s)" % (
            report["before"]["lufs"], report["after"]["lufs"],
            report["gain_db"], report["after"]["true_peak_dbtp"],
            ", ceiling took %.1f dB" % report["limited_db"]
            if report["limited_db"] > 0.05 else ""))
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

       A 40 Hz thump that sweeps DOWN to 26 in 120 ms (a body leaving), plus a
       short filtered-noise displacement and a single high tick at the far end
       that reads as the process re-materialising. Total 0.42 s, almost all of it
       tail: the event is the first 30 ms and the rest is the room."""
    n = frames(0.42)
    thump = apply_env(sine(n, 40.0, sweep_to=26.0), env_exp(n, 0.004, 0.075))
    air = apply_env(lowpass(noise(n, 0x5793), 420.0), env_exp(n, 0.002, 0.045))
    # The arrival. 150 ms in — the length of the dash — and very quiet: it is a
    # confirmation, not a second event.
    d = frames(0.15)
    tick = [0.0] * d + gain(apply_env(sine(n - d, 1180.0, sweep_to=1560.0),
                                      env_exp(n - d, 0.001, 0.022)), 0.16)
    body = mix(gain(thump, 0.95), gain(air, 0.30), tick)
    return fade_edges(normalise(soft_clip(body), 0.86))


def sub_pulse():
    """STACK PULSE — the loudest thing in the kit, and it should be.

       DESIGN.md makes this the crew's panic button AND a two-room NoiseBus ping,
       so it has to sound like something the layer heard. A hard 62 Hz core under
       a fast upward sweep and a broadband crack, then a 0.8 s tail that opens out
       rather than closing — the shape of a room being told."""
    n = frames(0.95)
    core = apply_env(sine(n, 62.0, sweep_to=44.0), env_exp(n, 0.003, 0.16))
    sweep = apply_env(sine(n, 220.0, sweep_to=880.0), env_exp(n, 0.002, 0.045))
    crack = apply_env(highpass(noise(n, 0x2C4B), 900.0), env_exp(n, 0.001, 0.030))
    # The ring-out: a slow band of low-passed noise that arrives AFTER the crack,
    # which is what makes it read as a space responding rather than as a hit.
    d = frames(0.06)
    tail = [0.0] * d + gain(apply_env(lowpass(noise(n - d, 0x77A1), 260.0),
                                      env_exp(n - d, 0.09, 0.26)), 0.34)
    body = mix(gain(core, 1.0), gain(sweep, 0.34), gain(crack, 0.40), tail)
    return fade_edges(normalise(soft_clip(body), 0.90))


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
    body = mix(gain(a, 0.42), gain(b, 0.42), gain(wash, 0.22),
               gain(apply_env(sine(n, 82.0), swell), 0.30))
    return fade_edges(normalise(soft_clip(body), 0.78))


def sub_fork_hit():
    """Something struck the fork. A dry, hollow knock with no body behind it —
       the point is that it sounds WRONG, like hitting a shell. 70 ms."""
    n = frames(0.07)
    body = mix(
        gain(apply_env(sine(n, 520.0, sweep_to=380.0), env_exp(n, 0.001, 0.012)), 0.6),
        gain(apply_env(highpass(noise(n, 0x9E31), 1800.0),
                       env_exp(n, 0.0005, 0.008)), 0.30))
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
       it reads over a lunge shriek."""
    n = frames(0.16)
    body = mix(
        gain(apply_env(sine(n, 1760.0), env_exp(n, 0.0008, 0.028)), 0.55),
        gain(apply_env(sine(n, 2640.0), env_exp(n, 0.0008, 0.018)), 0.28),
        gain(apply_env(lowpass(noise(n, 0x6D02), 3000.0),
                       env_exp(n, 0.0006, 0.010)), 0.22))
    return fade_edges(normalise(soft_clip(body), 0.72))


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
        gain(apply_env(sine(n, 1320.0), env_exp(n, 0.0006, 0.014)), 0.5),
        gain(apply_env(sine(n, 1980.0), env_exp(n, 0.0006, 0.009)), 0.22))
    return fade_edges(normalise(soft_clip(body), 0.55))


def sub_refused():
    """The kit saying no — not enough Cycles, or still recompiling. Deliberately
       the SAME grammar as ui_refusal_glitch_buzz (a short, sour, detuned pair)
       but two octaves lower, because this refusal comes from inside your own
       process rather than from a panel."""
    n = frames(0.14)
    body = mix(
        gain(apply_env(sine(n, 98.0), env_exp(n, 0.002, 0.030)), 0.5),
        gain(apply_env(sine(n, 104.0), env_exp(n, 0.002, 0.030)), 0.45),
        gain(apply_env(lowpass(noise(n, 0xA13F), 600.0),
                       env_exp(n, 0.001, 0.018)), 0.20))
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
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "assets", "audio"))
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    for rel, fn in SOUNDS.items():
        if args.only and args.only not in rel:
            continue
        write(os.path.join(args.out, rel), fn(), rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
