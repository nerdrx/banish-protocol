#!/usr/bin/env python3
"""LIMBO PROTOCOL — 3D colour-grading LUTs, one per depth band.

Run:  python3 tools/make_luts.py

Writes assets/luts/lut_{surface,mid,deep}.png as 32^3 strip LUTs (1024 x 32,
32 slices laid along U, blue axis stepping across slices). post_process_v3
samples them with a manual blue-axis lerp; see `lut_sample()` there.

Why a real LUT instead of more Environment adjustment sliders
------------------------------------------------------------
Look-dev 1 graded with `adjustment_contrast`, `adjustment_saturation` and a
per-channel GradientTexture1D. Those are three global knobs that apply the same
transform to every colour in the frame. A 3D LUT is a full RGB -> RGB mapping,
so it can do the thing the knobs cannot: treat the same luminance differently
depending on its HUE. That is the entire difference between "the image is
tinted teal" and "the teal emissive is clean, the grey architecture has a green
cast, and the warm accents are being pulled toward sick amber" — three
statements about three different parts of the frame, which is what grading is.

The depth bands are DESIGN.md's aesthetic gradient made literal:

  surface   layers 1-5    clean modern datacenter-brutalism. Cold, clinical,
                          slightly desaturated, blacks that stay blue-neutral.
                          The look of a system that is working.
  mid       layers 6-15   grey-teal. Chroma drains out of everything that is
                          not an emissive; shadows go green-teal. The system is
                          still working but nobody has maintained it in years.
  deep      layers 16+    warm-wrong. Shadows carry a dark amber-green cast that
                          does not belong in this palette, highlights push
                          magenta, and the mid-tones lose almost all chroma.
                          Reads as a colour pipeline that is failing, which is
                          exactly the fiction: MOTHER's oldest code, half-mad.

Every band also carries the same gentle filmic S-curve, because the one thing
all three need is for near-black to stop being a flat crush and start being a
toe.
"""

import os

import numpy as np
from PIL import Image

SIZE = 32                       # 32^3 = 32768 entries; 1024x32 px strip
OUT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "assets", "luts"))

# Rec.709 luma. Used for every saturation and split-tone weight below.
LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def identity() -> np.ndarray:
    """The neutral cube, shape (SIZE, SIZE, SIZE, 3) indexed [b, g, r]."""
    ax = np.linspace(0.0, 1.0, SIZE, dtype=np.float32)
    b, g, r = np.meshgrid(ax, ax, ax, indexing="ij")
    return np.stack([r, g, b], axis=-1)


def contrast(c: np.ndarray, amount: float, pivot: float = 0.5) -> np.ndarray:
    """Plain linear contrast about a pivot — the thing Environment's
    `adjustment_contrast` does, reproduced here because the LUT REPLACES it.

    This is the step that was missing, and its absence looked exactly like the
    LUT brightening the game. It is not: EnvBuilder switches
    `adjustment_enabled` off when a LUT is bound (grading twice is how an image
    ends up crushed with nobody able to say which stage did it), and the
    baseline was running `adjustment_contrast = 1.12`. At that setting a 0.10
    shadow maps to 0.052 — the low-mids are nearly halved — so a LUT that does
    not carry the same term measures 26% brighter than the frame it replaced
    while every value inside it is, by itself, correct.

    A LUT has to subsume the whole grade it stands in for. Anything left behind
    reappears as a regression somewhere nobody is looking.
    """
    return np.clip(pivot + (c - pivot) * amount, 0.0, 1.0)


def cdl(c: np.ndarray, slope, offset, power) -> np.ndarray:
    """ASC CDL. The colourist's primary control, and the reason it is here
    rather than a lift/gamma/gain of my own invention: slope/offset/power is
    what every grading suite on earth speaks, so these numbers transfer."""
    s = np.array(slope, dtype=np.float32)
    o = np.array(offset, dtype=np.float32)
    p = np.array(power, dtype=np.float32)
    return np.power(np.clip(c * s + o, 0.0, 1.0), p)


def saturate(c: np.ndarray, amount: float, pivot_shift: float = 0.0
             ) -> np.ndarray:
    l = np.sum(c * LUMA, axis=-1, keepdims=True)
    return np.clip(l + (c - l) * (amount + pivot_shift * l), 0.0, 1.0)


def split_tone(c: np.ndarray, shadow: tuple, highlight: tuple,
               balance: float = 0.5, strength: float = 1.0) -> np.ndarray:
    """Push shadows one way and highlights the other.

    Split-toning is what stops near-black reading as "underexposed" and starts
    it reading as "photographed at night". Look-dev 1 established this with a
    gradient curve; doing it in the LUT means it can be different per band,
    which is the whole point of having bands.
    """
    l = np.sum(c * LUMA, axis=-1, keepdims=True)
    # Weight curves that overlap in the mid-tones rather than meeting at a hard
    # edge — a split tone with a visible transition is a colour-banding bug.
    ws = np.clip(1.0 - l / max(balance, 1e-3), 0.0, 1.0) ** 1.4
    wh = np.clip((l - balance) / max(1.0 - balance, 1e-3), 0.0, 1.0) ** 1.4
    s = np.array(shadow, dtype=np.float32)
    h = np.array(highlight, dtype=np.float32)
    return np.clip(c + (s * ws + h * wh) * strength, 0.0, 1.0)


def filmic_curve(c: np.ndarray, toe: float, shoulder: float,
                 contrast: float) -> np.ndarray:
    """A gentle S. Not a tonemapper — the tonemapper already ran — just the
    print curve on top of it.

    The toe is the part that matters for this game. A hard clip at zero makes
    every unlit surface the same colour, which destroys the one thing the
    darkness law needs to work: that unlit is not uniformly black, it is a
    hundred barely-different blacks and the eye can still read shape in them.
    """
    x = np.clip(c, 0.0, 1.0)
    # Symmetric S around 0.5, strength = contrast.
    s = x + contrast * (x - 0.5) * (1.0 - np.abs(x - 0.5) * 2.0) * 0.5
    # Toe: open up the near-blacks without moving black itself. The mix with
    # x^0.75 is zero at zero by construction, which is the property that
    # matters — a curve that lifts absolute black turns this game milky and no
    # amount of lighting work recovers it.
    s = s * (1.0 - toe) + toe * np.power(x, 0.75)
    # Shoulder: a Reinhard-style roll applied ONLY above the knee.
    #
    # Two wrong versions preceded this one and both were the same mistake in
    # different clothes: a "shoulder" that touched the bottom of the range.
    # The first mapped black to +0.10 outright. The second, `s*(1+sh)/(1+sh*s)`,
    # was correct at both endpoints and therefore looked fine — but it lifts
    # every value in between, including a 0.05 shadow by 12%. Measured in
    # engine, the LUT stage alone raised corridor mean luma 31% and dropped the
    # fraction of frame below 2% luma from 75% to 55%. A grade that makes
    # previously-black geometry visible is a grade that lit the room, and the
    # darkness law does not care that it was done with a curve.
    #
    # Below the knee, nothing happens at all. That is the property that matters.
    knee = 0.62
    above = np.clip((s - knee) / (1.0 - knee), 0.0, 1.0)
    rolled = above * (1.0 + shoulder) / (1.0 + shoulder * above)
    s = np.minimum(s, knee) + rolled * (1.0 - knee)
    return np.clip(s, 0.0, 1.0)


# ------------------------------------------------------------------- bands --

def band_surface(c: np.ndarray) -> np.ndarray:
    """Layers 1-5. Clean, cold, clinical. The system is working."""
    # 1.05, not 1.12. The Environment's linear contrast was the ONLY contrast
    # in the baseline; this LUT also carries a filmic S-curve, and stacking the
    # full 1.12 on top of it crushed the room view to 97% of frame below 2%
    # luma — 48% darker than the baseline, which fails the darkness law from
    # the other direction. Measured either side and interpolated.
    c = contrast(c, 1.05)
    c = cdl(c, slope=(0.99, 1.00, 1.03), offset=(-0.004, -0.002, 0.006),
            power=(1.02, 1.00, 0.97))
    c = filmic_curve(c, toe=0.020, shoulder=0.10, contrast=0.20)
    c = saturate(c, 0.94, pivot_shift=0.10)
    c = split_tone(c, shadow=(-0.002, 0.001, 0.008),
                   highlight=(0.010, 0.008, 0.000), balance=0.42, strength=1.0)
    return c


def band_mid(c: np.ndarray) -> np.ndarray:
    """Layers 6-15. Grey-teal. Maintained by nobody for a long time."""
    # A shade more contrast than the surface band: the mid rings are further
    # from maintenance and the image should be harder, not just greener.
    c = contrast(c, 1.075)
    c = cdl(c, slope=(0.94, 1.00, 0.99), offset=(-0.006, 0.004, 0.008),
            power=(1.06, 0.99, 1.00))
    c = filmic_curve(c, toe=0.016, shoulder=0.13, contrast=0.26)
    # Chroma drains out of the architecture but the emissives are near the top
    # of the range, so a saturation that RISES with luma keeps the neon and
    # kills the rest. This is the trick the Environment sliders cannot do.
    c = saturate(c, 0.76, pivot_shift=0.52)
    c = split_tone(c, shadow=(-0.005, 0.004, 0.006),
                   highlight=(0.005, 0.010, 0.007), balance=0.40, strength=1.0)
    return c


def band_deep(c: np.ndarray) -> np.ndarray:
    """Layers 16+. Warm-wrong. The colour pipeline itself is failing."""
    c = contrast(c, 1.10)
    c = cdl(c, slope=(1.02, 0.95, 0.88), offset=(0.010, 0.006, -0.002),
            power=(0.97, 1.02, 1.10))
    c = filmic_curve(c, toe=0.012, shoulder=0.18, contrast=0.32)
    c = saturate(c, 0.62, pivot_shift=0.70)
    # Amber-green in the shadows, magenta in the highlights: two casts that do
    # not belong to the same white balance, so the eye cannot resolve the frame
    # into one light source. That unresolvable quality is the effect.
    c = split_tone(c, shadow=(0.008, 0.006, -0.003),
                   highlight=(0.016, -0.005, 0.013), balance=0.38, strength=1.0)
    return c


BANDS = {
    "surface": band_surface,
    "mid": band_mid,
    "deep": band_deep,
    "neutral": lambda c: c,     # the A/B control: proves the sampler is exact
}


def write_lut(name: str, fn) -> None:
    cube = fn(identity())
    # Strip layout: SIZE slices along U, blue index selects the slice. Row = G,
    # column-within-slice = R. This is the layout post_process_v3 expects and
    # it is also what every .cube -> .png converter emits, so a LUT authored in
    # Resolve drops straight in.
    strip = np.zeros((SIZE, SIZE * SIZE, 3), dtype=np.float32)
    for b in range(SIZE):
        strip[:, b * SIZE:(b + 1) * SIZE, :] = cube[b]
    img = (np.clip(strip, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "lut_%s.png" % name)
    Image.fromarray(img, "RGB").save(path)
    print("  %-22s %dx%d" % (os.path.basename(path), img.shape[1], img.shape[0]))


def main() -> None:
    print("LUTs -> %s" % OUT)
    for name, fn in BANDS.items():
        write_lut(name, fn)
    # A visual sanity strip: the neutral LUT must round-trip a ramp exactly, and
    # the others must not move the ramp's ends by more than a hair or the
    # darkness law is being broken by the grade rather than by the lighting.
    ramp = np.linspace(0, 1, 64, dtype=np.float32)
    grey = np.stack([ramp] * 3, axis=-1)[None, :, :]
    for name, fn in BANDS.items():
        out = fn(grey)[0]
        print("  %-9s black=%.4f  mid=%.3f  white=%.4f"
              % (name, float(out[0].mean()), float(out[32].mean()),
                 float(out[-1].mean())))


if __name__ == "__main__":
    main()
