#!/usr/bin/env python3
"""Build the FIDELITY material families — MLI foil, hazard band, brushed steel.

    python3 tools/build_fidelity_materials.py              # write the maps
    godot --headless --path . --import                     # make .import stubs
    python3 tools/build_fidelity_materials.py --fix-imports
    godot --headless --path . --import                     # re-import for real

Three families, chosen because between them they cover every material read in
the Isolation comms-room reference that our kit currently cannot do:

  MLI GOLD FOIL      the gold multi-layer insulation wrapped round machinery.
                     A pure specular event — no diffuse to speak of, all of its
                     detail lives in the normal, and it is the single loudest
                     "this is real hardware" signal in the whole reference frame.
  HAZARD / WEAR BAND painted amber-and-black diagonals on machine trim, chipped
                     back to bare steel at every edge somebody has knocked.
  BRUSHED STEEL      directional-highlight metal for kit surfaces and prop
                     bodies. Anisotropic, because a stretched highlight is what
                     tells the eye a panel was machined rather than modelled.

All three are baked to a tiling 1024 set (albedo / normal / packed ORM, plus an
anisotropy flowmap for the steel) and bound to StandardMaterial3D .tres files
that the showcase and the prop kit share. Synthesised from numpy + a pinned PCG
seed — no third-party source art, per the no-third-party-assets law, and
re-running this file reproduces the same maps byte for byte.

PBR discipline (these are the numbers that go wrong first under AgX)
--------------------------------------------------------------------
  * Metals get their real F0 in albedo and metallic = 1. Gold is (1.00, 0.766,
    0.336); steel is neutral around 0.56 linear. "Darkening the metal" by
    crushing its albedo is the classic fix that makes a metal read as painted
    plastic — the darkness in this game comes from having no light, not from
    lying about reflectance.
  * Nothing is roughness 0. A perfect mirror in a room with five practicals is
    five white dots on a black surface; every family here floors at 0.10 and
    spends most of its area between 0.2 and 0.5, which is where a specular
    highlight has a shape you can read.
  * Nothing is albedo 1.0 or 0.0 either. Painted amber tops out at 0.72 sRGB;
    the "black" of the hazard stripe is 0.045, not zero. Under AgX a value that
    clips has nowhere to roll off to and goes flat.

Output: assets/materials/fidelity/tex/*.png
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
OUT = os.path.join(ROOT, "assets", "materials", "fidelity", "tex")


# ----------------------------------------------------------------- utilities --

def smoothstep(a: float, b: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _lattice(rng: np.random.Generator, fx: int, fy: int) -> np.ndarray:
    """One octave of TILEABLE value noise at independent x/y frequencies.

    The independent axes are the whole reason this is not the gobo tool's
    helper: a brushed-metal streak is just value noise at 8 x 512, and a
    crumple is the same noise at 24 x 24. One function, two materials."""
    g = rng.random((fy + 1, fx + 1), dtype=np.float64)
    g[-1, :] = g[0, :]
    g[:, -1] = g[:, 0]

    cx = np.linspace(0.0, fx, SIZE, endpoint=False)
    ix0 = np.floor(cx).astype(np.int32)
    tx = cx - ix0
    tx = tx * tx * (3.0 - 2.0 * tx)
    cy = np.linspace(0.0, fy, SIZE, endpoint=False)
    iy0 = np.floor(cy).astype(np.int32)
    ty = cy - iy0
    ty = ty * ty * (3.0 - 2.0 * ty)

    top = g[iy0][:, ix0] * (1 - tx)[None, :] + g[iy0][:, ix0 + 1] * tx[None, :]
    bot = g[iy0 + 1][:, ix0] * (1 - tx)[None, :] + g[iy0 + 1][:, ix0 + 1] * tx[None, :]
    return top * (1 - ty)[:, None] + bot * ty[:, None]


def fbm(rng: np.random.Generator, fx: int = 4, fy: int = 4, octaves: int = 5,
        gain: float = 0.5) -> np.ndarray:
    total = np.zeros((SIZE, SIZE))
    amp, norm = 1.0, 0.0
    for _ in range(octaves):
        total += _lattice(rng, fx, fy) * amp
        norm += amp
        amp *= gain
        fx *= 2
        fy *= 2
    return total / norm


def ridged(rng: np.random.Generator, f: int = 6, octaves: int = 5,
           sharp: float = 1.7) -> np.ndarray:
    """Ridged multifractal — creases, not blobs.

    `1 - |2n-1|` folds a smooth noise about its midline, which turns every
    zero-crossing into a crease. Stacked octaves give a crease NETWORK with
    branching, which is exactly the topology of crumpled foil and is not
    something you can fake by turning up a normal map's strength."""
    total = np.zeros((SIZE, SIZE))
    amp, norm, freq = 1.0, 0.0, f
    for _ in range(octaves):
        n = _lattice(rng, freq, freq)
        r = 1.0 - np.abs(2.0 * n - 1.0)
        total += (r ** sharp) * amp
        norm += amp
        amp *= 0.55
        freq *= 2
    return total / norm


def blur(a: np.ndarray, radius_px: float) -> np.ndarray:
    if radius_px <= 0.0:
        return a
    r = max(1, int(radius_px * 3.0))
    x = np.arange(-r, r + 1, dtype=np.float64)
    k = np.exp(-0.5 * (x / radius_px) ** 2)
    k /= k.sum()
    pad = np.pad(a, ((0, 0), (r, r)), mode="wrap")
    out = np.apply_along_axis(lambda m: np.convolve(m, k, mode="valid"), 1, pad)
    pad = np.pad(out, ((r, r), (0, 0)), mode="wrap")
    return np.apply_along_axis(lambda m: np.convolve(m, k, mode="valid"), 0, pad)


def normal_from_height(h: np.ndarray, strength: float) -> np.ndarray:
    """Tangent-space normal from a height field, wrapping at the edges.

    np.roll rather than a padded gradient, because a normal map with a seam is
    worse than no normal map at all: the seam catches a specular highlight and
    draws a bright line down the middle of every surface it tiles across."""
    hl = np.roll(h, 1, axis=1)
    hr = np.roll(h, -1, axis=1)
    hu = np.roll(h, 1, axis=0)
    hd = np.roll(h, -1, axis=0)
    nx = (hl - hr) * strength
    ny = (hd - hu) * strength
    nz = np.ones_like(h)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack([nx * inv * 0.5 + 0.5,
                     ny * inv * 0.5 + 0.5,
                     nz * inv * 0.5 + 0.5], axis=-1)


def cavity(h: np.ndarray, radius: float = 5.0) -> np.ndarray:
    """Cheap AO: how far below its own neighbourhood each pixel sits."""
    lowfreq = blur(h, radius)
    return np.clip(0.5 + (h - lowfreq) * 2.2, 0.0, 1.0)


def srgb_to_lin(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def save_rgb(name: str, rgb: np.ndarray) -> None:
    img = Image.fromarray(np.clip(rgb * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGB")
    img.save(os.path.join(OUT, name), optimize=True)
    print("  wrote %-32s RGB  %dx%d" % (name, SIZE, SIZE))


def save_rgba(name: str, rgba: np.ndarray) -> None:
    img = Image.fromarray(np.clip(rgba * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGBA")
    img.save(os.path.join(OUT, name), optimize=True)
    print("  wrote %-32s RGBA %dx%d" % (name, SIZE, SIZE))


def _uv() -> tuple[np.ndarray, np.ndarray]:
    t = (np.arange(SIZE) + 0.5) / SIZE
    return np.meshgrid(t, t)


def _bands(rng: np.random.Generator, count: int, pitch: float,
           jitter: float) -> np.ndarray:
    steps = pitch * (1.0 + (rng.random(count) - 0.5) * 2.0 * jitter)
    return np.concatenate([[-pitch], np.cumsum(steps) - pitch * 0.5])


# ------------------------------------------------------------------ MLI foil --

def build_mli_gold() -> None:
    """Aluminised-Kapton multi-layer insulation: gold, crumpled, taped.

    The three things that make it read, in order:

      1. THE CREASE NETWORK. Ridged fBm at four octaves, so folds branch into
         smaller folds. A foil normal made from ordinary fBm looks like a
         bedsheet; only the ridged fold gives you the sharp-crease-with-flat-
         facet-between structure that catches a moving light as a travelling
         glint.
      2. THE QUILTING. Real MLI blankets are stitched or taped into panels on an
         irregular grid, and the tape locally FLATTENS the crinkle (the seam is
         the one part of the blanket that is under tension). Suppressing the
         crease amplitude along the seams is what turns "gold noise" into
         "gold blanket, assembled by a person".
      3. THE TEARS. Two places where the outer layer has split and the dark
         inner layers show through. Metallic drops there; that discontinuity in
         the specular is worth more than any amount of extra crinkle.
    """
    rng = np.random.default_rng(0xC01D)
    u, v = _uv()

    # --- seams: irregular quilt grid ---------------------------------------
    su = _bands(rng, 4, 0.25, 0.34) + 0.06
    sv = _bands(rng, 3, 0.333, 0.30) + 0.05
    seam = np.zeros((SIZE, SIZE))
    for x in su:
        if -0.05 < x < 1.05:
            wob = 0.006 * np.sin(v * 11.0 + x * 30.0)
            seam = np.maximum(seam, smoothstep(0.020, 0.004, np.abs(u - x - wob)))
    for y in sv:
        if -0.05 < y < 1.05:
            wob = 0.006 * np.sin(u * 9.0 + y * 25.0)
            seam = np.maximum(seam, smoothstep(0.024, 0.005, np.abs(v - y - wob)))
    tape = smoothstep(0.15, 0.75, seam)

    # --- crumple ------------------------------------------------------------
    # Fold SCALE is the parameter that decides whether this reads as foil or as
    # stucco, and it is counter-intuitive: the instinct is lots of small
    # wrinkles, which averages out to orange peel. Crumpled foil is a few LARGE
    # folds (base frequency 5 across a 1 m tile, i.e. 20 cm folds) with a second
    # much weaker generation of creases inside the facets. Three octaves, not
    # five — every extra octave here is contrast spent on detail nobody can see
    # and structure everybody can feel the loss of.
    creases = ridged(rng, f=5, octaves=3, sharp=2.6)
    creases = np.clip((creases - 0.18) * 1.9, 0.0, 1.0)   # push the folds apart
    micro = ridged(rng, f=17, octaves=2, sharp=3.0)
    buckle = fbm(rng, 2, 2, octaves=2)
    height = 1.00 * creases + 0.26 * micro + 0.42 * buckle
    # Tape pulls the blanket flat, and pulls it slightly PROUD of the field.
    height = height * (1.0 - 0.80 * tape) + tape * 0.55
    height = blur(height, 0.45)

    # --- tears --------------------------------------------------------------
    tear = np.zeros((SIZE, SIZE))
    for cu, cv, ru, rv, ang in ((0.71, 0.28, 0.085, 0.020, 0.6),
                                (0.22, 0.77, 0.055, 0.014, -1.1)):
        ca, sa = np.cos(ang), np.sin(ang)
        du = (u - cu) * ca + (v - cv) * sa
        dv = -(u - cu) * sa + (v - cv) * ca
        d = np.hypot(du / ru, dv / rv)
        wob = 0.35 * (fbm(np.random.default_rng(int(cu * 9973)), 14, 14, 3) - 0.5)
        tear = np.maximum(tear, smoothstep(1.0 + wob, 0.55 + wob, d))
    tear = np.clip(tear, 0.0, 1.0)

    # --- albedo -------------------------------------------------------------
    # Gold F0 in sRGB. Aluminised Kapton is warmer and slightly greener than
    # bullion gold, hence the small green lift over the textbook (1, .766, .336).
    gold = np.array([1.00, 0.775, 0.365])
    # Kapton amber varies across a sheet as the coating thickness varies; a
    # perfectly uniform gold is the giveaway.
    hue = fbm(rng, 5, 5, 4)
    tint = 1.0 + (hue[..., None] - 0.5) * np.array([0.04, 0.10, 0.26])
    alb = gold[None, None, :] * tint
    # Crease ridges are scuffed: the coating is abraded and goes duller/paler.
    scuff = smoothstep(0.55, 0.95, creases)
    alb = alb * (1.0 - 0.22 * scuff[..., None]) + 0.16 * scuff[..., None]
    # Tape is a dull amber polyimide, not metal.
    tape_c = np.array([0.42, 0.29, 0.12])
    alb = alb * (1.0 - tape[..., None]) + tape_c[None, None, :] * tape[..., None]
    # Torn areas: dark inner scrim.
    inner = np.array([0.055, 0.050, 0.048])
    alb = alb * (1.0 - tear[..., None]) + inner[None, None, :] * tear[..., None]
    # Dust settles in the crease valleys, never on the ridges.
    dust = fbm(rng, 7, 7, 5) * smoothstep(0.55, 0.10, creases)
    alb = alb * (1.0 - 0.14 * dust[..., None]) + 0.045 * dust[..., None]
    save_rgb("mli_gold_albedo.png", np.clip(alb, 0.0, 1.0))

    # --- normal -------------------------------------------------------------
    # 7.0 is high, deliberately. Foil has no macro geometry to hide behind; if
    # the normal is timid the whole family reads as gold paint.
    save_rgb("mli_gold_normal.png", normal_from_height(height, 7.0))

    # --- ORM ----------------------------------------------------------------
    ao = np.clip(cavity(height, 6.0) * 0.55 + 0.45, 0.0, 1.0)
    ao = np.clip(ao * (1.0 - 0.30 * tear), 0.0, 1.0)
    rough = 0.15 + 0.26 * scuff + 0.10 * dust
    rough = rough * (1.0 - tape) + 0.58 * tape
    rough = rough * (1.0 - tear) + 0.74 * tear
    rough = np.clip(rough, 0.10, 0.95)
    metal = np.ones((SIZE, SIZE))
    metal = metal * (1.0 - tape) + 0.10 * tape
    metal = metal * (1.0 - tear) + 0.08 * tear
    metal = np.clip(metal - 0.10 * dust, 0.0, 1.0)
    save_rgb("mli_gold_orm.png", np.stack([ao, rough, metal], axis=-1))


# -------------------------------------------------------------- hazard band --

def build_hazard_band() -> None:
    """Amber/black hazard diagonals on machine trim, chipped to bare steel.

    Laid out as a BAND: the hazard field occupies the middle ~64% of V with a
    ragged hand-masked boundary top and bottom, and the rest is the machine's
    own enamel. Tile it once vertically across a trim strip and you get a proper
    painted band with edges that were taped off by somebody in a hurry; tile it
    horizontally as far as you like.

    The chipping is the point. Paint fails at EDGES and at IMPACTS, never
    uniformly — so the chip mask is (stripe-edge proximity) x (a clustered
    impact field), and where it wins, the material underneath is a different
    material: darker, rougher, and metallic, because it is bare steel.
    """
    rng = np.random.default_rng(0x4A20)
    u, v = _uv()

    # --- diagonal stripes at jittered pitch --------------------------------
    ang = np.deg2rad(45.0)
    t = (u * np.cos(ang) + v * np.sin(ang)) * 1.6
    count = 14
    edges = _bands(rng, count, 1.85 / count, 0.22)
    idx = np.clip(np.searchsorted(edges, t) - 1, 0, count - 1)
    lo, hi = edges[idx], edges[np.clip(idx + 1, 0, count)]
    span = np.maximum(hi - lo, 1e-5)
    frac = (t - lo) / span
    dark_stripe = (np.arange(count) % 2 == 0)[idx]
    # A hand-painted stripe edge wanders; a printed one does not.
    wobble = 0.030 * (fbm(rng, 22, 22, 3) - 0.5)
    stripe = smoothstep(0.5 + wobble, 0.5 + wobble + 0.02, frac)
    is_dark = np.where(dark_stripe, 1.0 - stripe, stripe)

    # One stripe was repainted slightly off-register — a second amber edge
    # showing a sliver of the older coat.
    ghost = (idx == 9) & (frac > 0.30) & (frac < 0.40)

    # --- the band boundary --------------------------------------------------
    ragged_a = 0.045 * (fbm(rng, 9, 9, 4) - 0.5)
    ragged_b = 0.045 * (fbm(rng, 11, 11, 4) - 0.5)
    band = smoothstep(0.17 + ragged_a, 0.195 + ragged_a, v) \
        * smoothstep(0.83 + ragged_b, 0.805 + ragged_b, v)

    # --- surface height: paint sits ON the metal ---------------------------
    plate = fbm(rng, 6, 6, 5) * 0.35
    dent = fbm(rng, 4, 4, 3)
    plate += smoothstep(0.72, 1.0, dent) * -0.28          # a couple of knocks
    height = plate + band * 0.055 + is_dark * band * 0.010

    # --- chipping -----------------------------------------------------------
    # Edge proximity: paint lifts along the tape line and along stripe joins.
    edge_prox = np.maximum(
        smoothstep(0.06, 0.0, np.abs(frac - 0.5)),
        np.maximum(smoothstep(0.035, 0.0, np.abs(v - (0.185 + ragged_a))),
                   smoothstep(0.035, 0.0, np.abs(v - (0.818 + ragged_b)))))
    impacts = fbm(rng, 10, 10, 5)
    micro = fbm(rng, 46, 46, 3)
    chip = smoothstep(0.60, 0.78, impacts) * 0.9 + 0.55 * edge_prox
    chip *= smoothstep(0.32, 0.62, micro)                  # ragged chip outline
    # Knocks strip paint outright.
    chip = np.maximum(chip, smoothstep(0.80, 0.94, dent))
    chip = np.clip(chip, 0.0, 1.0)
    # ONE paint layer over ONE steel substrate. The band only decides what
    # COLOUR the paint is, never whether paint exists — the first version of
    # this gated coverage on the band too, which made every pixel outside the
    # hazard stripe report as bare metal and turned the machine's own enamel
    # into a mirror. Chipping is heavier inside the band because that is the
    # edge people actually hit; outside it the enamel is mostly intact.
    chip = chip * (0.35 + 0.65 * band)
    paint = 1.0 - chip

    # --- albedo -------------------------------------------------------------
    amber = np.array([0.72, 0.42, 0.075])       # painted hazard amber, not neon
    charcoal = np.array([0.045, 0.043, 0.042])  # the "black" stripe, never 0
    enamel = np.array([0.115, 0.122, 0.128])    # the machine's own grey
    steel = np.array([0.42, 0.425, 0.435])      # bare metal under the chip

    hazard_c = np.where(is_dark[..., None] > 0.5, charcoal[None, None, :],
                        amber[None, None, :])
    hazard_c = np.where(ghost[..., None], amber[None, None, :] * 0.72, hazard_c)
    enamel_c = enamel[None, None, :] * (0.85 + 0.3 * plate[..., None] / 0.35)
    paint_c = enamel_c * (1.0 - band[..., None]) + hazard_c * band[..., None]
    under = np.broadcast_to(steel, (SIZE, SIZE, 3)) * (0.80 + 0.4 * plate[..., None] / 0.35)
    alb = under * (1.0 - paint[..., None]) + paint_c * paint[..., None]

    # Scratches cut through everything, straightest lines in the material.
    scratch = np.zeros((SIZE, SIZE))
    for a_deg, off, w in ((8.0, 0.21, 0.0016), (172.0, 0.55, 0.0011),
                          (25.0, 0.72, 0.0021), (150.0, 0.36, 0.0009)):
        a = np.deg2rad(a_deg)
        d = np.abs((u - 0.5) * np.sin(a) - (v - off) * np.cos(a))
        life = smoothstep(0.05, 0.20, u) * smoothstep(0.98, 0.72, u)
        scratch = np.maximum(scratch, smoothstep(w * 2.2, w, d) * life)
    scratch *= smoothstep(0.35, 0.75, fbm(rng, 30, 6, 3))  # broken, not ruled
    alb = alb * (1.0 - 0.75 * scratch[..., None]) + steel[None, None, :] * 0.75 * scratch[..., None]

    grime = fbm(rng, 5, 5, 5)
    alb = alb * (1.0 - 0.20 * smoothstep(0.45, 0.95, grime))[..., None]
    save_rgb("hazard_band_albedo.png", np.clip(alb, 0.0, 1.0))

    # --- normal -------------------------------------------------------------
    # The paint layer has THICKNESS. A chip is a step down of one paint-film,
    # and that little lip catching a raking light is the entire reason to build
    # a wear mask instead of just painting a darker patch. The step is sharpened
    # (a narrow blur, high strength) so it survives at grazing angles.
    lip = smoothstep(0.35, 0.65, paint)
    h = plate + lip * 0.085 - smoothstep(0.72, 1.0, dent) * 0.10 + scratch * -0.05
    save_rgb("hazard_band_normal.png", normal_from_height(blur(h, 0.45), 9.0))

    # --- ORM ----------------------------------------------------------------
    ao = np.clip(cavity(h, 7.0) * 0.6 + 0.4, 0.0, 1.0)
    # Painted enamel is semi-gloss and gets polished where hands go; bare steel
    # under a chip is oxidised and rough. That contrast IS the wear read.
    rough = (0.30 + 0.16 * grime) * paint + (0.64 + 0.14 * micro) * (1.0 - paint)
    rough = np.where(scratch > 0.4, 0.24, rough)
    rough = np.clip(rough, 0.12, 0.95)
    # Paint is a dielectric; the steel it flakes off is not. Nothing in between.
    metal = np.clip((1.0 - paint) * 0.95, 0.0, 1.0)
    metal = np.where(scratch > 0.4, 0.90, metal)
    save_rgb("hazard_band_orm.png", np.stack([ao, rough, metal], axis=-1))


# ------------------------------------------------------------ brushed steel --

def build_brushed_steel() -> None:
    """Anisotropic brushed metal for kit surfaces and prop bodies.

    A brushed finish is not a texture, it is a SPECULAR SHAPE: the highlight
    smears perpendicular to the grain. Godot does that with the anisotropy
    feature, which needs two things from us — a normal/roughness set that carries
    the grain, and a flowmap whose RG says which way the grain runs and whose
    ALPHA says how strong it is at that pixel (BaseMaterial3D samples
    `texture_flowmap.rga`, uses `.rg*2-1` as the flow vector and `.b` of that
    swizzle — i.e. the alpha channel — as the ratio).

    The authored part is the flowmap. Uniform along-U grain is what every
    brushed-metal tutorial ships and it reads as a decal. Here the grain drifts
    a few degrees across the sheet, and two spun discs — where a fastener was
    run in and its washer polished a circle — carry genuinely circular flow.
    Those two discs are 3% of the area and do most of the convincing.
    """
    rng = np.random.default_rng(0x8B12)
    u, v = _uv()

    # --- grain --------------------------------------------------------------
    coarse = _lattice(rng, 6, 420)
    mid = _lattice(rng, 12, 900)
    fine = _lattice(rng, 40, 1024)
    grain = 0.5 * coarse + 0.33 * mid + 0.17 * fine
    # A few deep drag lines: the grit that was too big for the belt.
    drag = _lattice(rng, 3, 260)
    grain -= 0.45 * smoothstep(0.90, 1.0, drag)

    # Rolling mill banding across the sheet, very low frequency, very low amp.
    band = 0.5 + 0.5 * np.sin(v * np.pi * 2.0 * 3.0 + fbm(rng, 3, 3, 2) * 4.0)
    height = grain * 0.85 + band * 0.06

    # --- spun discs ---------------------------------------------------------
    discs = ((0.285, 0.640, 0.105), (0.755, 0.235, 0.078))
    disc_mask = np.zeros((SIZE, SIZE))
    spun_rings = np.zeros((SIZE, SIZE))
    bolt = np.zeros((SIZE, SIZE))
    for cu, cv, r in discs:
        d = np.hypot(u - cu, v - cv) / r
        ring = np.hypot(u - cu, v - cv)
        # Concentric turning marks. Period ~5 px: any tighter and it aliases
        # into a moiré the mip chain cannot rescue.
        spun = 0.5 + 0.5 * np.sin(ring * 1250.0 + fbm(rng, 20, 20, 2) * 6.0)
        m = smoothstep(1.0, 0.86, d)
        disc_mask = np.maximum(disc_mask, m)
        spun_rings = np.maximum(spun_rings, spun * m)
        height = height * (1.0 - m) + (spun * 0.28 + 0.42) * m
        bolt = np.maximum(bolt, smoothstep(0.26, 0.16, d))
    # The fastener hole: a real hole, dark and deep, not a shading trick.
    height -= bolt * 0.85

    # --- albedo -------------------------------------------------------------
    # Gunmetal: a treated/blued steel rather than bright stainless, because the
    # kit is "matte black monoliths" and a bright chrome family fights it. Still
    # a true metal F0, just a darker alloy — NOT a crushed-albedo fake.
    steel = np.array([0.455, 0.472, 0.495])
    alb = np.broadcast_to(steel, (SIZE, SIZE, 3)).copy()
    alb *= 0.86 + 0.28 * grain[..., None]
    patina = fbm(rng, 4, 4, 5)
    # Oxide bloom: warms and darkens where the finish has been breathed on.
    alb = alb * (1.0 - 0.30 * smoothstep(0.58, 0.95, patina)[..., None]) \
        + np.array([0.16, 0.125, 0.10])[None, None, :] \
        * (0.30 * smoothstep(0.58, 0.95, patina))[..., None]
    alb = alb * (1.0 - 0.85 * bolt[..., None]) + 0.028 * bolt[..., None]
    save_rgb("brushed_steel_albedo.png", np.clip(alb, 0.0, 1.0))

    # --- normal -------------------------------------------------------------
    # Low strength: the grain must live in the ROUGHNESS, not the normal. A
    # strong normal turns brushed metal into corrugated metal.
    save_rgb("brushed_steel_normal.png", normal_from_height(height, 1.35))

    # --- ORM ----------------------------------------------------------------
    ao = np.clip(cavity(height, 5.0) * 0.35 + 0.65, 0.0, 1.0)
    ao = np.clip(ao * (1.0 - 0.65 * bolt), 0.0, 1.0)
    rough = 0.30 + 0.20 * (grain - 0.5) * 2.0
    rough += 0.16 * smoothstep(0.58, 0.95, patina)
    # Handling polish: the finish is rubbed smoother where things touch it.
    polish = smoothstep(0.30, 0.05, fbm(rng, 3, 3, 3))
    rough -= 0.10 * polish
    # The spun disc's turning marks are a ROUGHNESS event, not a height one —
    # the washer burnished the surface, it did not emboss it. Putting the rings
    # in the height map (the first attempt) made them invisible at any sane
    # normal strength; in roughness they show the moment a light rakes across.
    disc_rough = 0.19 + 0.17 * spun_rings
    rough = rough * (1.0 - disc_mask) + disc_rough * disc_mask
    rough = np.clip(rough + 0.30 * bolt, 0.11, 0.80)
    metal = np.clip(0.98 - 0.22 * smoothstep(0.62, 0.98, patina), 0.0, 1.0)
    metal = np.clip(metal - 0.55 * bolt, 0.0, 1.0)
    save_rgb("brushed_steel_orm.png", np.stack([ao, rough, metal], axis=-1))

    # --- anisotropy flowmap -------------------------------------------------
    # RG = flow direction encoded to 0..1, A = anisotropy ratio. Default (no
    # map) behaviour is flow (1,0), i.e. R=1.0 G=0.5 — the grain runs along the
    # mesh tangent. We drift it by a few degrees and swirl it inside the discs.
    drift = (fbm(rng, 3, 3, 3) - 0.5) * np.deg2rad(24.0)
    fx = np.cos(drift)
    fy = np.sin(drift)
    for cu, cv, r in discs:
        d = np.hypot(u - cu, v - cv) / r
        m = smoothstep(1.0, 0.80, d)
        tang_x = -(v - cv)
        tang_y = (u - cu)
        n = np.maximum(np.hypot(tang_x, tang_y), 1e-6)
        fx = fx * (1.0 - m) + (tang_x / n) * m
        fy = fy * (1.0 - m) + (tang_y / n) * m
    n = np.maximum(np.hypot(fx, fy), 1e-6)
    fx, fy = fx / n, fy / n
    # Ratio: strong on the brushed field, killed where the finish is polished
    # out (a polished patch has no grain, so it must have no anisotropy either
    # or the highlight smears with nothing to smear along).
    ratio = np.clip(0.92 - 0.55 * polish - 0.25 * smoothstep(0.62, 0.98, patina), 0.0, 1.0)
    ratio = ratio * (1.0 - disc_mask) + 0.85 * disc_mask
    flow = np.stack([fx * 0.5 + 0.5, fy * 0.5 + 0.5,
                     np.full_like(fx, 0.5), ratio], axis=-1)
    save_rgba("brushed_steel_flow.png", flow)


# ------------------------------------------------------------ CRT phosphor --

def build_crt_phosphor() -> None:
    """A P1-green CRT screen image — emission map AND area-light texture.

    Two consumers, and the second one is the interesting one:

      * the terminal's screen material uses it as an emission texture, and
      * the AreaLight3D behind that screen uses it as its `area_texture`.

    Feeding the same image to both is what makes the light-cast retrofit
    honest. An untextured area light throws a flat wash of one colour; textured
    with the screen's own content, the light landing on the wall carries the
    screen's brightness distribution — a bright header bar spills more than the
    dim body text does, and the spill shifts when the content shifts. That is
    the difference between "there is a green light near the monitor" and "the
    monitor is lighting the room".

    NOT tileable (it is a screen, it has edges), 512 — it is only ever seen on a
    30 cm surface and as a light's own texture, and the alternative is spending
    4x the VRAM on pixels that a phosphor bloom is about to smear anyway.
    """
    global SIZE
    prev, SIZE = SIZE, 512
    try:
        rng = np.random.default_rng(0x9E12)
        u, v = _uv()
        lum = np.zeros((SIZE, SIZE))

        # Header rule + a title block.
        lum += smoothstep(0.062, 0.068, v) * smoothstep(0.078, 0.072, v) * 0.85
        # Body: rows of glyph blocks at a fixed leading with ragged line lengths,
        # because a terminal that fills every line to the margin is a texture and
        # a terminal with ragged right edges is a document.
        rows = 22
        lead = 0.036
        top = 0.105
        for i in range(rows):
            y = top + i * lead
            if y > 0.94:
                break
            rowh = smoothstep(y, y + 0.004, v) * smoothstep(y + 0.019, y + 0.015, v)
            width = 0.16 + rng.random() * 0.68
            indent = 0.075 + (0.055 if rng.random() < 0.22 else 0.0)
            # character cells with gaps — a word-shaped run, not a solid bar
            cell = 0.0092
            cu = (u - indent) / cell
            glyph = smoothstep(0.12, 0.30, np.abs((cu - np.floor(cu)) - 0.5) * -1.0 + 0.5)
            key = (np.floor(np.clip(cu, 0, 1e6)).astype(np.int64) * 2654435761
                   + i * 40503) & 0xFFFF
            present = ((key / 65535.0) > 0.16).astype(np.float64)
            line = smoothstep(indent - 0.002, indent + 0.002, u) \
                * smoothstep(indent + width, indent + width - 0.004, u)
            bright = 0.58 + 0.36 * ((key >> 4) / 65535.0)
            if i in (4, 11):                       # a highlighted / selected row
                bright = bright * 0.0 + 0.95
            lum += rowh * line * glyph * present * bright

        # A boxed status field bottom-right — every real terminal has one.
        box = smoothstep(0.60, 0.605, u) * smoothstep(0.93, 0.925, u) \
            * smoothstep(0.845, 0.850, v) * smoothstep(0.915, 0.910, v)
        edge = box * (1.0 - (smoothstep(0.612, 0.617, u) * smoothstep(0.918, 0.913, u)
                             * smoothstep(0.857, 0.862, v) * smoothstep(0.903, 0.898, v)))
        lum += edge * 0.9

        # Phosphor persistence: a short vertical smear downward. Cheap, and it is
        # most of why a CRT reads as a CRT rather than an LCD.
        smear = lum.copy()
        for k in range(1, 7):
            smear = np.maximum(smear, np.roll(lum, k, axis=0) * (1.0 - k / 7.0) * 0.55)
        lum = np.maximum(lum, smear)

        # Scanlines and shadow mask. Both are gentle — at 512 across a 30 cm
        # screen a hard mask aliases into a moiré that no mip chain survives.
        scan = 0.80 + 0.20 * (0.5 + 0.5 * np.cos(v * np.pi * 2.0 * 190.0))
        lum *= scan
        lum *= 0.93 + 0.07 * (0.5 + 0.5 * np.cos(u * np.pi * 2.0 * 150.0))

        # Bloom: the glass in front of the phosphor scatters. Two radii so the
        # halo has a core and a skirt.
        lum = np.clip(lum * 1.25, 0.0, 1.6)
        lum = lum + blur(lum, 1.6) * 0.60 + blur(lum, 7.0) * 0.50

        # Tube geometry: the raster does not reach the corners, and the corners
        # are darker because the beam travels further to get there.
        d = np.hypot((u - 0.5) * 1.06, (v - 0.5) * 1.10) * 2.0
        lum *= smoothstep(1.02, 0.80, d)
        lum *= 1.0 - 0.18 * smoothstep(0.55, 1.0, d)

        # Dust on the outside of the glass, lit by the phosphor behind it.
        lum *= 0.90 + 0.14 * fbm(rng, 6, 6, 4)

        # P1 green: not pure (0,1,0). Real green phosphor is yellow-shifted and
        # its highlights desaturate toward white, which is exactly what AgX
        # wants — a fully saturated primary at high energy has nowhere to roll
        # off and clips to a flat plate of colour.
        core = np.array([0.34, 1.00, 0.42])
        hot = np.array([0.86, 1.00, 0.80])
        t = np.clip(lum / 1.6, 0.0, 1.0)[..., None]
        rgb = (core[None, None, :] * (1.0 - t) + hot[None, None, :] * t) \
            * np.clip(lum, 0.0, 1.0)[..., None]
        # A dim ambient phosphor floor, so the unlit screen is never pure black:
        # a dead-black CRT face reads as a hole cut in the prop.
        rgb += np.array([0.012, 0.030, 0.016])[None, None, :]
        save_rgb("crt_phosphor_emis.png", np.clip(rgb, 0.0, 1.0))
    finally:
        SIZE = prev


FAMILIES = (
    ("MLI gold foil", build_mli_gold),
    ("hazard / wear band", build_hazard_band),
    ("brushed anisotropic steel", build_brushed_steel),
    ("CRT phosphor screen", build_crt_phosphor),
)


# ------------------------------------------------------------ import fixups --
#
# Same reasoning as tools/fix_imports.py, applied to a directory that file does
# not walk (its rules key off `_albedo`/`_normal`/`_orm` suffixes and would in
# fact catch most of these — this is here so the fidelity set is reproducible
# from ONE command and cannot be half-configured by running the wrong tool).

COMMON = {
    "compress/mode": "2",
    "compress/high_quality": "true",
    "mipmaps/generate": "true",
    "detect_3d/compress_to": "0",
}
RULES = (
    (re.compile(r"_normal\.png$"), dict(COMMON, **{"compress/normal_map": "1"})),
    # The flowmap carries a DIRECTION in RG and a ratio in A. Compressing it as
    # a normal map (RGTC, two channels, reconstructed Z) would throw the alpha
    # away and take the anisotropy ratio with it, so it is explicitly not one.
    (re.compile(r"_flow\.png$"), dict(COMMON, **{"compress/normal_map": "0",
                                                 "compress/channel_pack": "1"})),
    (re.compile(r"_orm\.png$"), dict(COMMON, **{"compress/normal_map": "0"})),
    (re.compile(r"_albedo\.png$"), dict(COMMON, **{"compress/normal_map": "0"})),
    # The CRT screen is an EMISSION map and an area-light texture. Both paths
    # want smooth gradients across a phosphor bloom, and block compression puts
    # 4x4 steps in exactly that gradient — it is 0.75 MB uncompressed, so this
    # is the one texture in the set that keeps its full precision.
    (re.compile(r"_emis\.png$"), {"compress/mode": "0", "mipmaps/generate": "true",
                                  "detect_3d/compress_to": "0"}),
)


def fix_imports() -> int:
    n = 0
    for f in sorted(os.listdir(OUT)):
        if not f.endswith(".import"):
            continue
        src = f[:-len(".import")]
        params = None
        for rx, p in RULES:
            if rx.search(src):
                params = p
                break
        if params is None:
            continue
        path = os.path.join(OUT, f)
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        out = text
        for k, val in params.items():
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
    print("build_fidelity_materials: %d .import file(s) updated" % n)
    if n == 0:
        print("  (nothing to do — run `godot --headless --path . --import` first)")
    return n


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fix-imports", action="store_true")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    if args.fix_imports:
        fix_imports()
        sys.exit(0)

    for label, fn in FAMILIES:
        print(label)
        fn()


if __name__ == "__main__":
    main()
