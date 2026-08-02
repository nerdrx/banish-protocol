#!/usr/bin/env python3
"""NULLVOID floor grime — the marks a layer wears on its deck.

    python3 tools/make_grime.py [outdir]      # default: assets/grime

Companion to `make_decals.py`, and deliberately a separate script: signage is
*writing* (text, plates, a message from MOTHER to her own processes) and grime
is *history* (a coolant leak nobody mopped, the scorch where something burned
out). They share nothing but the file format, and mixing them would mean a
re-run of one regenerating two hundred files of the other.

Art rules:

  1. **No emission at all.** A stain does not glow. These ship albedo only, and
     the ClutterLib placer leaves `texture_emission` unset — which is also why
     they cost nothing: a Decal with one texture is one projection.
  2. **Dark, and mostly alpha.** The deck plating underneath has to keep showing
     through; a stain is a *tint* on the floor, not a sticker of a floor. Peak
     alpha stays well under 1 so the kit's roughness variation survives.
  3. **Irregular, seeded, and never circular.** A perfect ellipse reads as a
     decal; a blotch with erosion round its edge reads as a spill.
  4. Two families — organic (coolant/residue seep, cool grey-teal, soft edges)
     and thermal (scorch, warm near-black with a hard sooty core and a lighter
     halo). Deep layers use more of the second, which is the same depth
     gradient the signage runs.

Output is square 512x512 RGBA. Six plates: three stains, three scorches.
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "grime")

SIZE = 512

# Painted values, not light values — the same discipline make_decals.py uses.
# A stain is slightly cooler and slightly darker than the floor plate; a scorch
# is much darker with a warm rim where the plating cooked rather than burned.
SEEP = (26, 34, 38)
SEEP_EDGE = (40, 52, 56)
SOOT = (14, 12, 12)
SCORCH_RIM = (58, 40, 28)


def blob(draw, cx, cy, radius, rng, colour, alpha, lobes=9, wobble=0.42):
    """One irregular closed blob, drawn as a polygon of jittered radii."""
    points = []
    phase = rng.uniform(0.0, math.tau)
    # Per-lobe radius, smoothed by averaging with its neighbour so the outline
    # undulates instead of spiking — spikes read as a star, not a spill.
    radii = [radius * (1.0 - wobble * rng.random()) for _ in range(lobes)]
    for i in range(lobes):
        r = (radii[i] * 2.0 + radii[(i + 1) % lobes]) / 3.0
        for sub in range(4):
            t = phase + math.tau * (i + sub / 4.0) / lobes
            rr = r * (1.0 + 0.05 * math.sin(t * 5.0 + phase))
            points.append((cx + math.cos(t) * rr, cy + math.sin(t) * rr))
    draw.polygon(points, fill=colour + (alpha,))


def erode(image, rng, amount=1.0):
    """Punch holes and speckle into the alpha so the edge is not a clean curve."""
    px = image.load()
    for _ in range(int(1400 * amount)):
        x = rng.randrange(SIZE)
        y = rng.randrange(SIZE)
        r, g, b, a = px[x, y]
        if a == 0:
            continue
        px[x, y] = (r, g, b, int(a * rng.uniform(0.15, 0.85)))
    return image.filter(ImageFilter.GaussianBlur(1.6))


def plate_stain(rng):
    """A seep: soft, cool, wide, with a darker pooled centre."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cx = SIZE * 0.5 + rng.uniform(-30, 30)
    cy = SIZE * 0.5 + rng.uniform(-30, 30)
    blob(draw, cx, cy, SIZE * 0.40, rng, SEEP_EDGE, 74, 11, 0.5)
    blob(draw, cx + rng.uniform(-18, 18), cy + rng.uniform(-18, 18),
         SIZE * 0.27, rng, SEEP, 122, 9, 0.42)
    blob(draw, cx + rng.uniform(-24, 24), cy + rng.uniform(-24, 24),
         SIZE * 0.13, rng, SEEP, 156, 8, 0.35)
    # A couple of runs trailing off the main pool — liquid has a direction.
    for _ in range(rng.randint(2, 4)):
        angle = rng.uniform(0.0, math.tau)
        reach = rng.uniform(0.3, 0.48) * SIZE
        blob(draw, cx + math.cos(angle) * reach, cy + math.sin(angle) * reach,
             SIZE * rng.uniform(0.04, 0.09), rng, SEEP, 92, 7, 0.5)
    img = img.filter(ImageFilter.GaussianBlur(7.0))
    return erode(img, rng, 0.7)


def plate_scorch(rng):
    """A burn: hard sooty core, warm rim, spatter round the outside."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cx = SIZE * 0.5 + rng.uniform(-24, 24)
    cy = SIZE * 0.5 + rng.uniform(-24, 24)
    blob(draw, cx, cy, SIZE * 0.38, rng, SCORCH_RIM, 66, 10, 0.5)
    blob(draw, cx, cy, SIZE * 0.24, rng, SOOT, 168, 9, 0.4)
    blob(draw, cx + rng.uniform(-12, 12), cy + rng.uniform(-12, 12),
         SIZE * 0.12, rng, SOOT, 205, 8, 0.3)
    img = img.filter(ImageFilter.GaussianBlur(4.5))
    # Spatter goes on AFTER the blur: it has to stay crisp, or the whole plate
    # is one soft smudge and the burn stops reading as an event.
    spatter = ImageDraw.Draw(img)
    for _ in range(rng.randint(26, 44)):
        angle = rng.uniform(0.0, math.tau)
        reach = rng.uniform(0.22, 0.47) * SIZE
        r = rng.uniform(2.0, 9.0)
        x = cx + math.cos(angle) * reach
        y = cy + math.sin(angle) * reach
        spatter.ellipse([x - r, y - r, x + r, y + r],
                        fill=SOOT + (rng.randint(70, 150),))
    return erode(img, rng, 1.0)


PLATES = {
    "stain_a": plate_stain,
    "stain_b": plate_stain,
    "stain_c": plate_stain,
    "scorch_a": plate_scorch,
    "scorch_b": plate_scorch,
    "scorch_c": plate_scorch,
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, build in sorted(PLATES.items()):
        rng = random.Random(hash(name) & 0xFFFFFFFF)
        build(rng).save(os.path.join(OUT, "%s.png" % name))
    print("wrote %d files to %s" % (len(PLATES), OUT))


if __name__ == "__main__":
    main()
