#!/usr/bin/env python3
"""NULLVOID room-designation stencils — M10b.

    python3 tools/build_signage.py [outdir]      # default: assets/decals

THE POINT, WHICH IS NOT DECORATION
----------------------------------
`LayerGraph.room_name` already gives every room a real name — `BUS-3C`,
`VAULT-3A`, `NEST-3D` — and the command terminal, the minimap and the wayfinding
text all speak it. The WALLS did not. A player could stand in a room, read
`QUERY` on a terminal, be told they are in VAULT-3A, and find nothing anywhere
in the room that agreed. This makes the building agree with the map: the same
name, stencilled beside the door, in the same grammar MOTHER uses when she talks
about the place.

That is worth more than a prettier wall. It is the difference between signage
that dresses a set and signage that is INFORMATION — the same argument
`DecalLib`'s header makes about the trunk arrows pointing at the real shaft.

WHY THE PLATES ARE PRE-COMPOSED AND WHY THE LAYER NUMBER IS NOT ON THEM
----------------------------------------------------------------------
A decal is a texture, so a name assembled at runtime would mean either rendering
text into an image every build (a hitch, and one per room) or one decal per
CHARACTER (six Decal nodes per room, on top of a layer that already places
sixty). Neither is worth it.

So the plate carries `PREFIX-LETTER` and not the layer digit: `BUS-C`, not
`BUS-3C`. The set is then 7 prefixes x 10 letters = 70 plates instead of 70 per
layer, and nothing is lost — the layer number is ALREADY on the wall, as the
big `num_*` numerals the arrival room places, and putting it on both would be a
building that repeats its own floor number in every room. Room letters cap at
ten because layers cap at ten rooms.

WEAR AND OFF-REGISTER
---------------------
A stencil is sprayed through a mask by somebody standing on a ladder:

  * the paint is OFF-REGISTER — the letters do not sit square in the plate's own
    frame, they are a few millimetres low and a few left, differently per plate;
  * the mask has TIES, so every glyph is broken by the bridges that held the
    stencil together. This is the single strongest "this is painted, not
    printed" cue and it costs three rectangles;
  * the spray has OVERSPRAY at the edges and the paint has worn where the wall
    gets touched.

SIZED AS A SCALE CUE
--------------------
Cap height is ~0.5 m at the shipped decal size (2.4 x 0.9 m). That is a real
industrial designation stencil, and it is deliberately big enough that the sign
itself tells you how large the room is — which matters more after M10 tripled
the rooms than it did before.

Corruption variants are NOT generated, for the reason `make_decals.py` gives
about the layer numerals: a room designation you cannot read is a usability
problem, not atmosphere. The wear above is baked into the clean plate instead.
"""
import os
import random
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_decals import (  # noqa: E402  (path shim above is deliberate)
    AMBER, INK, INK_DIM, TEAL, font, new_plate, rule, text, weather,
)

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "decals")

W, H = 1024, 384

# The prefixes are `LayerGraph.ROOM_PREFIX` plus NEST, which that function
# substitutes for BUS when a bus hall is unlit. If a prefix is ever added there
# it has to be added here or the wall stops agreeing with the map — which is the
# entire reason this file exists, so the mismatch would be silent and bad.
#
# The subtitle is what the room IS, in the builders' language rather than
# MOTHER's. It is the line that makes a designation read as a place instead of
# as a serial number.
PREFIXES = {
    "GATE": ("ARRIVAL GATE", TEAL),
    "BUS": ("PROCESSING BUS", TEAL),
    "VAULT": ("COLD ARCHIVE", TEAL),
    "SIPH": ("SIPHON JUNCTION", AMBER),
    "TRUNK": ("DROP SHAFT HEAD", TEAL),
    "NODE": ("MAINTENANCE NODE", AMBER),
    "NEST": ("SECTOR UNPOWERED", AMBER),
}

LETTERS = "ABCDEFGHIJ"


def stencil_ties(layer, box, rng, count=3):
    """Punch the bridges a real stencil mask needs to hold together.

    Horizontal bars cleared out of the paint layer across the whole word, not
    per glyph — that is how a one-piece mask actually behaves, and it is why
    stencil type has the breaks in the same places on every letter.
    """
    x0, y0, x1, y1 = box
    d = ImageDraw.Draw(layer)
    span = max(y1 - y0, 1)
    for i in range(count):
        # Spread over the cap height with a little jitter, never at the very top
        # or bottom where a bridge would just clip the serifless ends off.
        t = (i + 1) / (count + 1) + (rng.random() - 0.5) * 0.06
        y = y0 + span * t
        thick = max(3, int(span * (0.022 + rng.random() * 0.012)))
        d.rectangle([x0 - 8, y - thick / 2, x1 + 8, y + thick / 2], fill=(0, 0, 0, 0))


def overspray(a, rng, box, amount=0.5):
    """Speckle just outside the mask edge. A sprayed stencil is never clean."""
    x0, y0, x1, y1 = box
    px = a.load()
    for _ in range(int(1400 * amount)):
        x = int(rng.uniform(x0 - 22, x1 + 22))
        y = int(rng.uniform(y0 - 18, y1 + 18))
        if not (0 <= x < a.size[0] and 0 <= y < a.size[1]):
            continue
        r, g, b, al = px[x, y]
        k = rng.uniform(0.10, 0.34)
        px[x, y] = (int(r + (INK[0] - r) * k), int(g + (INK[1] - g) * k),
                    int(b + (INK[2] - b) * k), max(al, int(255 * k)))


def plate_designation(prefix, letter):
    subtitle, accent = PREFIXES[prefix]
    code = "%s-%s" % (prefix, letter)

    def build(rng):
        a, e = new_plate(W, H)
        da, de = ImageDraw.Draw(a), ImageDraw.Draw(e)

        # The plate's own frame: printed, square, and NOT what the paint lines
        # up with. Having a square element on the plate is what makes the
        # off-register paint legible AS off-register.
        rule(a, e, (46, 34), (W - 92, 6), accent, 0.75)
        rule(a, e, (46, H - 44), (W - 92, 4), accent, 0.55)

        # The paint, on its own layer so the ties can be cut out of it and the
        # whole thing shifted off-register in one move.
        paint = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        dp = ImageDraw.Draw(paint)
        size = 168
        f = font(size)
        dp.text((72, H // 2 - 18), code, font=f, fill=INK + (255,), anchor="lm")
        box = dp.textbbox((72, H // 2 - 18), code, font=f, anchor="lm")
        stencil_ties(paint, box, rng)
        # Off-register: a few millimetres, different per plate, never zero.
        dx = int(rng.uniform(-9, 9))
        dy = int(rng.uniform(-7, 7))
        a.alpha_composite(paint, (dx, dy))
        overspray(a, rng, (box[0] + dx, box[1] + dy, box[2] + dx, box[3] + dy))

        # The builders' name for the room, small, in the corner, unglamorous.
        text(da, (W - 74, H - 74), subtitle, 30, INK_DIM + (255,), "rm",
             spacing_px=5, emission=de, glow=0.22)
        return a, e
    return build


def main():
    os.makedirs(OUT, exist_ok=True)
    written = 0
    for prefix in sorted(PREFIXES):
        for letter in LETTERS:
            name = "desig_%s_%s" % (prefix.lower(), letter.lower())
            rng = random.Random(hash(name) & 0xFFFFFFFF)
            a, e = plate_designation(prefix, letter)(rng)
            # Heavier than a printed plate: paint on a wall in a service
            # corridor is the most abused surface in the building.
            weather(a, e, rng, 1.35)
            a.save(os.path.join(OUT, "%s.png" % name))
            e.save(os.path.join(OUT, "%s_e.png" % name))
            written += 2
    print("wrote %d designation plates to %s" % (written, OUT))


if __name__ == "__main__":
    main()
