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


def write(path, sig):
    os.makedirs(os.path.dirname(path), exist_ok=True)
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


SOUNDS = {
    "ui/ui_hit_confirm.ogg": hit_confirm,
    "ui/ui_shaft_siphon.ogg": shaft_siphon,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "assets", "audio"))
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    for rel, fn in SOUNDS.items():
        if args.only and args.only not in rel:
            continue
        write(os.path.join(args.out, rel), fn())
    return 0


if __name__ == "__main__":
    sys.exit(main())
