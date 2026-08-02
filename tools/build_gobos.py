#!/usr/bin/env python3
"""Build the FIDELITY gobo library — authored projector masks for Light3D.

    python3 tools/build_gobos.py                 # write assets/gobos/*.png
    godot --headless --path . --import           # create the .import stubs
    python3 tools/build_gobos.py --fix-imports   # force the right settings
    godot --headless --path . --import           # re-import with them

Why a SECOND gobo set (assets/textures/gobo_*.png already exists)
----------------------------------------------------------------
The look-dev-1 gobos are *pattern* gobos: a cosine, a smoothstep, some fBm on
top. They break the engine-default ellipse, which was their whole job, and at
that they still work. They do not survive the Isolation benchmark. Put one on a
tripod work light in haze and the shadow it throws is a metronome — every bar
the same width, every gap the same gap, the edges razor-perfect. The eye reads
periodicity long before it reads brightness, so a perfect repeat announces
"procedural" from across the room no matter how good the fog is.

The reference frames the user supplied (medbay, one tripod light through
slatted louvres; comms room, CRTs under a cable run) have four properties this
file is built to reproduce, in descending order of how much each one matters:

  1. IRREGULAR PITCH. Real louvre stacks are not extruded from a sine. Slat
     spacing here is a cumulative sum of a jittered pitch, so no two gaps in the
     texture are the same width, and the sequence never rhymes with itself.
  2. DAMAGE THAT IMPLIES HISTORY (the motivation law, applied to a texture).
     One slat is bowed, one is half-closed, one is missing outright. A dent is
     not decoration — it is evidence that something hit this vent, which is the
     cheapest story any surface in the game can tell.
  3. EDGE WEAR. A shadow edge that is mathematically straight reads as CAD. Each
     aperture edge is nibbled by a per-slat 1-D noise, so the bar of light has a
     slightly ragged boundary that survives being blown up across a 6 m wall.
  4. DIRT OCCLUSION. Grime does not cover a vent evenly; it accumulates at the
     bottom of each aperture and runs downward in streaks. That vertical
     gradient inside each individual bar of light is most of what separates
     "photographed" from "rendered".

Every mask is white-on-black (white = light passes), 1024 px (power of two,
mipmaps required — a projector without mips aliases into crawling moiré the
moment the light or the camera moves), single channel.

Everything is synthesised from numpy + a seeded PCG — no third-party art, per
the no-third-party-assets law. The seeds are pinned so the library is
reproducible: re-running this file byte-for-byte reproduces the same textures.

Output: assets/gobos/gobo_*.png
"""

from __future__ import annotations

import argparse
import os
import re
import sys

import numpy as np
from PIL import Image

SIZE = 1024
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(ROOT, "assets", "gobos")


# ----------------------------------------------------------------- utilities --

def smoothstep(a: float, b: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _lattice(rng: np.random.Generator, freq: int) -> np.ndarray:
    """One octave of value noise, upsampled to SIZE with smoothstep interp.

    Tileable in both axes (the lattice wraps), which costs nothing and means a
    gobo can be reused as a tiling detail map later without a visible seam.
    """
    g = rng.random((freq + 1, freq + 1), dtype=np.float64)
    g[-1, :] = g[0, :]
    g[:, -1] = g[:, 0]
    coord = np.linspace(0.0, freq, SIZE, endpoint=False)
    i0 = np.floor(coord).astype(np.int32)
    f = coord - i0
    f = f * f * (3.0 - 2.0 * f)
    i1 = i0 + 1
    # separable bilinear: rows first, then columns
    top = g[i0][:, i0] * (1 - f)[None, :] + g[i0][:, i1] * f[None, :]
    bot = g[i1][:, i0] * (1 - f)[None, :] + g[i1][:, i1] * f[None, :]
    return top * (1 - f)[:, None] + bot * f[:, None]


def fbm(rng: np.random.Generator, base: int = 4, octaves: int = 5,
        gain: float = 0.5) -> np.ndarray:
    total = np.zeros((SIZE, SIZE), dtype=np.float64)
    amp, norm, freq = 1.0, 0.0, base
    for _ in range(octaves):
        total += _lattice(rng, freq) * amp
        norm += amp
        amp *= gain
        freq *= 2
    return total / norm


def blur(a: np.ndarray, radius_px: float) -> np.ndarray:
    """Separable Gaussian. Models the penumbra of a real fixture: a lamp with a
    finite emitter never throws a perfectly hard shadow edge, and a gobo that
    forgets this reads as a stencil taped to the lens."""
    if radius_px <= 0.0:
        return a
    r = max(1, int(radius_px * 3.0))
    x = np.arange(-r, r + 1, dtype=np.float64)
    k = np.exp(-0.5 * (x / radius_px) ** 2)
    k /= k.sum()
    pad = np.pad(a, ((0, 0), (r, r)), mode="edge")
    out = np.apply_along_axis(lambda m: np.convolve(m, k, mode="valid"), 1, pad)
    pad = np.pad(out, ((r, r), (0, 0)), mode="edge")
    return np.apply_along_axis(lambda m: np.convolve(m, k, mode="valid"), 0, pad)


def vignette(power: float = 1.0, inner: float = 0.70, outer: float = 1.02) -> np.ndarray:
    """Radial soft edge so the texture's square border never shows in the cone.

    Deliberately flat across the middle — a projector that dims toward its own
    edges just re-creates the plain ellipse it was meant to break up."""
    u, v = _uv()
    d = np.hypot(u - 0.5, v - 0.5) * 2.0
    return smoothstep(outer, inner, d) ** power


def _uv() -> tuple[np.ndarray, np.ndarray]:
    t = (np.arange(SIZE) + 0.5) / SIZE
    return np.meshgrid(t, t)  # u = x across, v = y down


def _grime(rng: np.random.Generator, strength: float = 0.30,
           streaks: float = 0.22) -> np.ndarray:
    """Dirt occlusion: blotchy accumulation plus downward runs.

    The streak term is a noise stretched 20:1 in v, which is what a wash of
    condensate leaves behind on a vertical grille. It is applied multiplicatively
    so it can only ever REMOVE light — grime does not glow."""
    blotch = fbm(rng, base=5, octaves=5)
    fine = fbm(rng, base=24, octaves=3)
    run = _lattice(rng, 96)
    run = blur(run, 0.6)
    run = np.repeat(run[:2, :], SIZE // 2, axis=0)[:SIZE]  # smear vertically
    run = blur(run, 1.2)
    g = 1.0 - strength * (0.65 * blotch + 0.35 * fine)
    g *= 1.0 - streaks * smoothstep(0.55, 1.0, run)
    return np.clip(g, 0.0, 1.0)


def _edge_wear(rng: np.random.Generator, bands: int, along: np.ndarray,
               band_idx: np.ndarray, scale: float) -> np.ndarray:
    """Per-band 1-D noise that nibbles the aperture edge along the slat.

    One independent wobble per band, so adjacent slats are worn differently —
    which is the point. Shared wear across the whole texture just looks like the
    whole mask was offset."""
    n = 192
    curves = rng.random((bands, n))
    # smooth each band's curve so the wear is chewed, not dithered
    k = np.array([0.06, 0.24, 0.40, 0.24, 0.06])
    curves = np.apply_along_axis(
        lambda m: np.convolve(np.concatenate([m[-2:], m, m[:2]]), k, mode="valid"),
        1, curves)
    # Sampled with linear interpolation, not nearest. Nearest quantises the
    # aperture edge into ~5 px stair-steps which are invisible in the texture and
    # extremely visible once a projector stretches that edge across a 6 m wall.
    b = np.clip(band_idx, 0, bands - 1)
    x = np.clip(along, 0.0, 1.0) * (n - 1)
    i0 = np.floor(x).astype(np.int32)
    i1 = np.minimum(i0 + 1, n - 1)
    f = x - i0
    lo = curves[b, i0]
    hi = curves[b, i1]
    return ((lo * (1.0 - f) + hi * f) - 0.5) * scale


def _slat_bands(rng: np.random.Generator, count: int, pitch: float,
                jitter: float) -> np.ndarray:
    """Cumulative jittered pitch — the single most important line in this file.

    A cosine gives you `count` identical gaps. This gives you `count` gaps that
    are all slightly wrong, which is what a stack of stamped louvres actually
    looks like after it has been bolted to a bulkhead by hand."""
    steps = pitch * (1.0 + (rng.random(count) - 0.5) * 2.0 * jitter)
    return np.concatenate([[-pitch], np.cumsum(steps) - pitch * 0.5])


def to_png(a: np.ndarray) -> Image.Image:
    return Image.fromarray(np.clip(a * 255.0 + 0.5, 0, 255).astype(np.uint8), mode="L")


# -------------------------------------------------------------------- gobos --

def gobo_vent_slat() -> np.ndarray:
    """SLATTED VENT — the medbay reference light.

    A stack of pressed-steel louvres seen from slightly below, tilted ~7 degrees
    off horizontal so the bars it throws are never parallel to a room edge (a
    shadow bar that lines up with the skirting reads as a texture; one that
    crosses it reads as a vent). Carries all four authoring properties: jittered
    pitch, three damaged slats, nibbled edges, dirt pooling at the bottom of each
    aperture.
    """
    rng = np.random.default_rng(0x5EA7)
    u, v = _uv()
    ang = np.deg2rad(7.0)
    t = (v * np.cos(ang) + u * np.sin(ang)) * 1.30 - 0.14   # slat-normal axis
    along = np.clip(u * np.cos(ang) - v * np.sin(ang) + 0.18, 0.0, 1.0)

    count = 21
    edges = _slat_bands(rng, count, pitch=1.42 / count, jitter=0.30)
    idx = np.clip(np.searchsorted(edges, t) - 1, 0, count - 1)

    lo = edges[idx]
    hi = edges[np.clip(idx + 1, 0, count)]
    span = np.maximum(hi - lo, 1e-5)

    # Per-slat aperture: how much of each band the metal actually covers. The
    # louvre is a blade, so the OPEN part is a fraction of the pitch, jittered.
    open_frac = 0.42 + rng.random(count) * 0.20
    # Three authored failures, in the order a maintenance crew would meet them.
    open_frac[7] *= 0.28    # a slat crushed nearly shut
    open_frac[13] = 0.90    # its neighbour's blade is gone entirely
    shut = np.zeros(count)
    shut[3] = 1.0           # one blade closed by hand (someone wanted it dark)

    # A bowed slat: its lower edge sags in the middle of the run.
    bow = np.zeros(count)
    bow[10] = 0.020
    bow[16] = -0.011
    sag = bow[idx] * np.sin(np.pi * along)

    o = open_frac[idx] * (1.0 - 0.92 * shut[idx])
    a0 = lo + span * (0.5 - o * 0.5) + sag
    a1 = lo + span * (0.5 + o * 0.5) + sag

    wear = _edge_wear(rng, count, along, idx, 0.016)
    soft = 0.0055
    mask = smoothstep(a0 + wear - soft, a0 + wear + soft, t) \
        * smoothstep(a1 - wear + soft, a1 - wear - soft, t)

    # Dirt pools at the bottom lip of every aperture and runs down from it.
    depth = np.clip((t - a0) / np.maximum(a1 - a0, 1e-5), 0.0, 1.0)
    lip = 1.0 - 0.45 * smoothstep(0.55, 1.0, depth)
    mask *= lip

    # The blade backs catch a little bounce — the aperture is never pure black in
    # a real fixture, and a hard zero kills the volumetric's low end.
    mask = mask * 0.985 + 0.015 * smoothstep(0.0, 0.35, mask)

    mask *= _grime(rng, strength=0.34, streaks=0.26)
    mask = blur(mask, 1.15)
    return np.clip(mask * vignette(1.0, 0.72, 1.04), 0.0, 1.0)


def gobo_fine_grille() -> np.ndarray:
    """FINE GRILLE — perforated plate over a recessed fixture.

    High-frequency, so it is the one to use when a light must feel *near* a
    surface: a fine mask reads as a fixture 30 cm off the wall, a coarse one
    reads as a vent 4 m away. Two things stop it being wallpaper: a low-frequency
    warp that bends the whole hole field (a stamped sheet is never flat once it
    has been bolted at four corners), and clogged cells where paint or grease has
    filled a perforation.
    """
    rng = np.random.default_rng(0x6127)
    u, v = _uv()

    # Bend the sheet before punching it. 0.006 of UV is ~6 px — invisible as an
    # effect, decisive as a tell.
    warp = (fbm(rng, base=3, octaves=3) - 0.5)
    warp2 = (fbm(rng, base=3, octaves=3) - 0.5)
    uu = u + warp * 0.016
    vv = v + warp2 * 0.016

    pitch = 1.0 / 34.0
    cu = uu / pitch
    cv = vv / pitch
    # staggered rows — a punched sheet is almost never a square lattice
    cu = cu + 0.5 * (np.floor(cv).astype(np.int32) % 2)
    fu = cu - np.floor(cu) - 0.5
    fv = cv - np.floor(cv) - 0.5

    key = (np.floor(cu).astype(np.int64) * 73856093
           ^ np.floor(cv).astype(np.int64) * 19349663) & 0xFFFF
    jitter = (key / 65535.0)

    radius = 0.29 + jitter * 0.055
    d = np.hypot(fu, fv * 1.06)
    holes = smoothstep(radius + 0.045, radius - 0.045, d)

    # ~4% of cells fully or partly blocked. Clustered, not sprinkled: grease
    # arrives in patches, and a uniform 4% scatter reads as noise rather than
    # neglect.
    clog_field = fbm(rng, base=7, octaves=4)
    clog = smoothstep(0.52, 0.70, clog_field) * smoothstep(0.55, 0.90, jitter)
    holes *= 1.0 - np.clip(clog * 1.6, 0.0, 1.0)

    # Frame: the plate is screwed to a bezel, so the outer 6% carries no holes
    # but four fixing bosses do break the border.
    border = smoothstep(0.0, 0.05, u) * smoothstep(1.0, 0.95, u) \
        * smoothstep(0.0, 0.05, v) * smoothstep(1.0, 0.95, v)
    holes *= border

    holes *= _grime(rng, strength=0.28, streaks=0.30)
    holes = blur(holes, 0.85)
    # Vignette tighter than the bezel it is masking (0.92 < the 0.95 border), or
    # the straight edge of the plate shows as a flat chord across the cone.
    return np.clip(holes * vignette(1.2, 0.58, 0.92), 0.0, 1.0)


def gobo_fan_blades() -> np.ndarray:
    """FAN BLADES (static) — an extract fan seen through its guard.

    STATIC on purpose. A rotating gobo is a 30-second effect and a permanent
    performance cost; a *stopped* fan is the more interesting image anyway,
    because a fan that is not turning in a machine space is a fault, and a fault
    is a story. Seven blades (prime, so the eye cannot find the symmetry), swept
    so each blade's shadow curves, three motor struts at irregular angles, and a
    wire guard whose rings are NOT evenly spaced.
    """
    rng = np.random.default_rng(0x3F00)
    u, v = _uv()
    du, dv = (u - 0.5) * 2.0, (v - 0.5) * 2.0
    r = np.hypot(du, dv)
    th = np.arctan2(dv, du)

    blades = 7
    # sweep: blade angle advances with radius, so the shadow is a curve
    swept = th + r * 1.15
    seg = swept / (2.0 * np.pi / blades)
    fseg = seg - np.floor(seg)
    bidx = np.floor(seg).astype(np.int64) % blades

    width = 0.34 + rng.random(blades) * 0.10          # chord varies per blade
    width_at_r = width[bidx] * (0.55 + 0.75 * np.clip(r, 0.0, 1.0))
    blade = smoothstep(0.5 - width_at_r - 0.03, 0.5 - width_at_r + 0.03, fseg) \
        * smoothstep(0.5 + width_at_r + 0.03, 0.5 + width_at_r - 0.03, fseg)

    # One blade is bent — its chord is fatter and it sits off-pitch.
    bent = (bidx == 4)
    blade = np.where(bent, np.clip(blade * 1.0 + 0.22, 0.0, 1.0), blade)

    open_air = 1.0 - blade
    open_air *= smoothstep(0.20, 0.27, r)             # hub disc
    open_air *= smoothstep(0.985, 0.93, r)            # shroud

    # Motor struts at deliberately unequal angles.
    for a_deg, w in ((14.0, 0.030), (139.0, 0.024), (255.0, 0.034)):
        a = np.deg2rad(a_deg)
        dist = np.abs(du * np.sin(a) - dv * np.cos(a))
        side = (du * np.cos(a) + dv * np.sin(a)) > 0.0
        open_air *= np.where(side, smoothstep(w - 0.008, w + 0.008, dist), 1.0)

    # Wire guard: concentric rings at irregular radii, plus radial wires.
    for rr, w in ((0.335, 0.0085), (0.492, 0.0075), (0.678, 0.0090), (0.855, 0.0080)):
        open_air *= smoothstep(w * 0.6, w, np.abs(r - rr))
    for a_deg in (5.0, 74.0, 151.0, 212.0, 297.0):
        a = np.deg2rad(a_deg)
        dist = np.abs(du * np.sin(a) - dv * np.cos(a))
        open_air *= smoothstep(0.0035, 0.0075, dist)

    # Dust on the leading edges: a stopped fan collects a felt of it, and the
    # felt is thickest at the tips where the air moved fastest.
    dust = fbm(rng, base=6, octaves=4)
    open_air *= 1.0 - 0.30 * smoothstep(0.45, 0.95, dust) * smoothstep(0.35, 0.9, r)

    open_air *= _grime(rng, strength=0.22, streaks=0.10)
    open_air = blur(open_air, 1.0)
    return np.clip(open_air * vignette(1.0, 0.80, 1.0), 0.0, 1.0)


def gobo_cable_tray() -> np.ndarray:
    """CABLE-TRAY LATTICE — the overhead run, lit from above.

    This is the motivation law as a gobo. A ladder tray exists because power had
    to get from A to B; the rungs are at an installer's pitch, not a designer's;
    the bundles sag between supports because gravity is real; one cable leaves
    the run and drops out of frame toward whatever it feeds. Shone straight down
    a corridor this is the single most "someone built this" mask in the set.
    """
    rng = np.random.default_rng(0x0CAB)
    u, v = _uv()
    open_air = np.ones((SIZE, SIZE))

    # Two side rails running along u, slightly non-parallel (a real tray is
    # hung on threaded rod and nothing is ever square).
    for rail_v, tilt, w in ((0.185, 0.014, 0.030), (0.845, -0.009, 0.034)):
        centre = rail_v + tilt * (u - 0.5)
        open_air *= smoothstep(w * 0.75, w, np.abs(v - centre))

    # Rungs at jittered pitch across the tray.
    rungs = 15
    pos = _slat_bands(rng, rungs, pitch=1.12 / rungs, jitter=0.34) + 0.02
    for i in range(rungs):
        x = pos[i]
        if not (-0.05 < x < 1.05):
            continue
        w = 0.0085 + rng.random() * 0.0050
        lean = (rng.random() - 0.5) * 0.055      # rungs are not plumb
        centre = x + lean * (v - 0.5)
        inside = smoothstep(0.16, 0.20, v) * smoothstep(0.88, 0.84, v)
        bar = smoothstep(w * 0.7, w, np.abs(u - centre))
        open_air *= 1.0 - (1.0 - bar) * inside

    # Cable bundles: catenary sag between the rungs they are tied to.
    supports = np.array([0.06, 0.30, 0.55, 0.79, 1.02])
    for base_v, thick, phase in ((0.31, 0.036, 0.0), (0.40, 0.052, 0.35),
                                 (0.52, 0.028, 0.7), (0.62, 0.044, 0.15),
                                 (0.71, 0.022, 0.9)):
        seg = np.clip(np.searchsorted(supports, u) - 1, 0, len(supports) - 2)
        a = supports[seg]
        b = supports[seg + 1]
        s = np.clip((u - a) / np.maximum(b - a, 1e-5), 0.0, 1.0)
        sag = 0.030 * (1.0 + phase) * np.sin(np.pi * s)
        centre = base_v + sag + 0.010 * np.sin(u * 9.0 + phase * 6.0)
        open_air *= smoothstep(thick * 0.55, thick * 0.85, np.abs(v - centre))

    # One bundle breaks out of the tray and drops away — the cable that feeds
    # the thing this light is hanging over.
    drop_u = 0.735
    t = np.clip((u - drop_u) / 0.10, 0.0, 1.0)
    dcentre = 0.40 + t * t * 0.72
    dthick = 0.040 * (1.0 - 0.35 * t)
    branch = smoothstep(dthick * 0.55, dthick * 0.9, np.abs(v - dcentre))
    open_air *= np.where(u > drop_u - 0.02, branch, 1.0)

    # Zip ties: thin, bright-blocking, irregularly placed.
    for tu, tv, tw in ((0.145, 0.395, 0.006), (0.36, 0.515, 0.005),
                       (0.585, 0.62, 0.006), (0.83, 0.30, 0.005)):
        d = np.hypot((u - tu) / 0.020, (v - tv) / 0.055)
        open_air *= 1.0 - 0.85 * smoothstep(1.0, 0.55, d) * (1.0 - smoothstep(0.0, 0.35, d))

    open_air *= _grime(rng, strength=0.30, streaks=0.34)
    open_air = blur(open_air, 1.4)
    return np.clip(open_air * vignette(0.9, 0.74, 1.04), 0.0, 1.0)


def gobo_drip_grate() -> np.ndarray:
    """DRIP GRATE — a walkway grating with something wet running through it.

    Heavy bearing bars one way, sparse cross rods the other, at two unrelated
    irregular pitches so the cell field never resolves into a lattice. Corrosion
    eats the bar edges. Two cells are blocked by debris. And the reason for the
    name: thin runnels descend from the underside of the bars, so the light this
    throws on a floor is striped AND streaked — the mask to use when a room is
    supposed to feel like it is leaking.
    """
    rng = np.random.default_rng(0xD819)
    u, v = _uv()

    bars = 17
    be = _slat_bands(rng, bars, pitch=1.20 / bars, jitter=0.26) + 0.01
    bidx = np.clip(np.searchsorted(be, v) - 1, 0, bars - 1)
    lo, hi = be[bidx], be[np.clip(bidx + 1, 0, bars)]
    span = np.maximum(hi - lo, 1e-5)
    metal = 0.30 + rng.random(bars) * 0.14          # bar thickness varies
    metal[9] = 0.62                                  # one doubled/repaired bar
    o = 1.0 - metal[bidx]
    wear = _edge_wear(rng, bars, u, bidx, 0.020)
    a0 = lo + span * (0.5 - o * 0.5) + wear
    a1 = lo + span * (0.5 + o * 0.5) - wear
    open_air = smoothstep(a0 - 0.004, a0 + 0.004, v) * smoothstep(a1 + 0.004, a1 - 0.004, v)

    # Cross rods: sparser, unrelated pitch, and NOT perpendicular.
    rods = 6
    re_ = _slat_bands(rng, rods, pitch=1.15 / rods, jitter=0.40) + 0.03
    skew = 0.05
    for i in range(rods):
        x = re_[i]
        if not (-0.05 < x < 1.05):
            continue
        w = 0.011 + rng.random() * 0.007
        centre = x + skew * (v - 0.5)
        open_air *= smoothstep(w * 0.7, w, np.abs(u - centre))

    # Debris blocking two cells: something fell in and nobody cleared it.
    for cu, cv, rr in ((0.28, 0.42, 0.085), (0.66, 0.71, 0.062)):
        d = np.hypot(u - cu, v - cv) / rr
        lump = smoothstep(1.15, 0.55, d)
        lump *= 0.55 + 0.45 * fbm(np.random.default_rng(int(cu * 1e4)), base=12, octaves=3)
        open_air *= 1.0 - np.clip(lump, 0.0, 1.0)

    # The runnels. Thin, downward, anchored to the underside of a bar and dying
    # out over 2-3 cells — the trace of water finding its way through.
    runnel = np.zeros((SIZE, SIZE))
    for ru, start_v, length, w in ((0.121, 0.16, 0.55, 0.0055),
                                   (0.318, 0.32, 0.66, 0.0040),
                                   (0.474, 0.10, 0.88, 0.0070),
                                   (0.702, 0.44, 0.42, 0.0045),
                                   (0.881, 0.24, 0.61, 0.0060)):
        wander = 0.012 * np.sin(v * 17.0 + ru * 40.0)
        lane = smoothstep(w * 1.6, w * 0.5, np.abs(u - ru - wander))
        life = smoothstep(start_v - 0.02, start_v + 0.04, v) \
            * smoothstep(start_v + length, start_v + length - 0.18, v)
        runnel = np.maximum(runnel, lane * life)
    open_air *= 1.0 - 0.55 * runnel

    # Corrosion: pitting that eats into the bar faces, so the bars themselves are
    # not clean rectangles in silhouette.
    pit = fbm(rng, base=20, octaves=4)
    open_air = np.clip(open_air + 0.25 * smoothstep(0.72, 0.95, pit) * (1.0 - open_air), 0.0, 1.0)

    open_air *= _grime(rng, strength=0.32, streaks=0.38)
    open_air = blur(open_air, 1.1)
    return np.clip(open_air * vignette(1.0, 0.76, 1.03), 0.0, 1.0)


GOBOS = (
    ("gobo_vent_slat", gobo_vent_slat),
    ("gobo_fine_grille", gobo_fine_grille),
    ("gobo_fan_blades", gobo_fan_blades),
    ("gobo_cable_tray", gobo_cable_tray),
    ("gobo_drip_grate", gobo_drip_grate),
)


# ------------------------------------------------------------ import fixups --
#
# Projector textures have import requirements that Godot's photographic defaults
# get wrong in two specific ways, and both are visible in-game:
#
#   mipmaps      MANDATORY. A projector is minified hard at the far end of its
#                own cone; without mips the slats turn into crawling moiré that
#                TAA then spends its whole budget failing to hold still.
#   compression  BPTC (BC7). A gobo is multiplied into light energy, so
#                compression error becomes banding in a beam that is already
#                being stretched across a volumetric. BC7's 8bpp holds a smooth
#                grey ramp; S3TC's 4bpp does not. detect_3d is disabled so the
#                setting cannot be silently re-decided on first use.

IMPORT_PARAMS = {
    "compress/mode": "2",
    "compress/high_quality": "true",
    "compress/channel_pack": "0",
    "mipmaps/generate": "true",
    "detect_3d/compress_to": "0",
    "process/fix_alpha_border": "false",
}


def fix_imports() -> int:
    n = 0
    for f in sorted(os.listdir(OUT)):
        if not f.endswith(".png.import"):
            continue
        path = os.path.join(OUT, f)
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        out = text
        for k, val in IMPORT_PARAMS.items():
            pat = re.compile(r"^%s=.*$" % re.escape(k), re.M)
            if pat.search(out):
                out = pat.sub("%s=%s" % (k, val), out)
            else:
                out = out.replace("[params]", "[params]\n%s=%s" % (k, val), 1)
        if out != text:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(out)
            print("  patched", f)
            n += 1
    print("build_gobos: %d .import file(s) updated" % n)
    if n == 0:
        print("  (nothing to do — run `godot --headless --path . --import` first)")
    return n


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fix-imports", action="store_true",
                    help="patch the .import sidecars Godot generated, then exit")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    if args.fix_imports:
        sys.exit(0 if fix_imports() >= 0 else 1)

    for name, fn in GOBOS:
        img = to_png(fn())
        path = os.path.join(OUT, name + ".png")
        img.save(path, optimize=True)
        arr = np.asarray(img, dtype=np.float64) / 255.0
        print("wrote %-24s %dx%d  mean=%.3f  open>50%%=%.1f%%"
              % (name + ".png", SIZE, SIZE, arr.mean(), 100.0 * (arr > 0.5).mean()))


if __name__ == "__main__":
    main()
