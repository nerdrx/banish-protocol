#!/usr/bin/env python3
"""NULLVOID wall decals — MOTHER's own messaging surfaces.

    python3 tools/make_decals.py [outdir]      # default: assets/decals

Writes one pair per decal: `<name>.png` (albedo, straight RGBA) and
`<name>_e.png` (emission mask, black where nothing glows). Godot's Decal node
takes both, so a sign can be a dark printed panel with only its accent bar and a
couple of glyph rows actually emitting — which is the whole point. A decal that
glows across its full area is a billboard, and NULLVOID does not have
billboards; it has signage in a building with the lights off.

Art rules, in priority order:

  1. Mostly DARK. The albedo sits near the kit's own panel value so a sign reads
     as printed onto the wall rather than stuck on top of it. Under a beam it
     resolves; unlit it is a slightly different shade of black.
  2. Emission is a garnish — an accent rule, a status pip, occasionally one
     highlighted word. Never the body text.
  3. Palette is the game's: teal = the system talking to itself, amber =
     warning, red = quarantine/hostile. Nothing else.
  4. Wear. Every decal gets edge erosion, blotching and a little dirt, because
     a perfectly clean sign in a decaying system is the thing that reads as
     "pasted in from a UI mockup".
  5. Some of it is not language. A few plates are invented glyph blocks, so the
     wall reads as a system that has its own notation and occasionally
     condescends to English, rather than as a set dressed for the player.

Corruption variants (`_c1`, `_c2`) are generated from the clean plate by
dead-pixel punching, scanline tearing and partial glyph loss. Deep layers place
them more often; see ProcLayerBuilder._decal_variant.
"""
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "decals")

FONT_CANDIDATES = [
    "/usr/share/fonts/noto/NotoSansMono-SemiCondensedBold.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Bold.ttf",
    "/usr/share/fonts/noto/NotoSansMono-SemiCondensedMedium.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
]

# The palette, and nothing outside it.
# Painted values, not light values. A hazard chevron is retroreflective paint —
# it is bright when a beam is on it and nearly black when one is not — so these
# sit well down from the emissive palette the kit uses. The first pass authored
# them at full saturation and every sign came out a glowing stripe, which is
# exactly the billboard look the brief rules out.
TEAL = (34, 122, 156)
AMBER = (158, 100, 44)
RED = (150, 34, 32)
# Body text is *paint*, not light: a bone-grey that a beam picks out and the
# dark swallows.
INK = (150, 158, 170)
INK_DIM = (96, 102, 112)

# The backing plate.
#
# M4.7 raised this from (26, 28, 33), and the arithmetic is worth writing down
# because getting it wrong is what made every sign in the game read as a hole.
# The kit's wall albedo is **0.095 linear**, and these PNGs are imported as
# **sRGB** — so the value that matches the wall is not 24/255, it is
#   srgb(0.095) = 1.055 * 0.095^(1/2.4) - 0.055 = 0.341  ->  87.
# At 26 the plate was ten times darker than the panel it is printed on, so an
# albedo decal — even a correctly applied one — painted a black rectangle onto
# the wall and the only thing left to see was the emission. Sitting a little
# under the wall reads as different stock; sitting a tenth of it reads as a
# rendering fault.
PANEL = (58, 62, 70)
# The builders' plates: same reasoning, warmer, and a touch more faded.
PANEL_LEGACY = (56, 53, 47)

# --- what is allowed to emit ---------------------------------------------------
#
# DESIGN.md: "Dim albedo + restrained emissive... Never glowing billboards."
# Until M4.7 every plate self-illuminated its own body text at ~20% of its
# printed value, which was a workaround for the fact that nothing in the room was
# lighting the wall (see LightRig._aim). With the fixtures aimed correctly the
# walls are lit, printed signage reads as printed, and emission goes back to
# being what it was supposed to be: the few things on a sign that are genuinely
# powered.
#
# Emissive, still: accent rules and status pips (the plate has a supply),
# wayfinding arrows (navigation is load-bearing, and an arrow you cannot find in
# an unlit corridor is a sign that failed at its job), hazard chevrons at a
# whisper, and the arrival room's layer numerals.
#
# Not emissive, ever again: body copy, sublines, invented glyph blocks, and
# anything at all on a Northcairn plate.
GLOW_BODY = 0.0
GLOW_ARROW = 1.0
GLOW_CHEVRON = 0.14
GLOW_NUMERAL = 0.13


def font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def new_plate(w, h, panel=PANEL):
    """A blank sign: the printed backing plate, plus its emission layer.

    The plate is not a flat fill. It carries a shallow bevel — a lifted top and
    left edge, a shadowed bottom and right — because a sign is a physical object
    screwed to a wall, and under the grazing wall wash the kit is lit by, that
    2 px of value difference is what makes it read as standing proud of the panel
    rather than as printing on it.
    """
    albedo = Image.new("RGBA", (w, h), panel + (255,))
    draw = ImageDraw.Draw(albedo)
    lift = tuple(min(255, int(c * 1.55) + 6) for c in panel)
    drop = tuple(int(c * 0.45) for c in panel)
    for i in range(3):
        fade = 1.0 - i / 3.0
        top = tuple(int(panel[k] + (lift[k] - panel[k]) * fade) for k in range(3))
        bottom = tuple(int(panel[k] + (drop[k] - panel[k]) * fade) for k in range(3))
        draw.line([(i, i), (w - 1 - i, i)], fill=top + (255,))
        draw.line([(i, i), (i, h - 1 - i)], fill=top + (255,))
        draw.line([(i, h - 1 - i), (w - 1 - i, h - 1 - i)], fill=bottom + (255,))
        draw.line([(w - 1 - i, i), (w - 1 - i, h - 1 - i)], fill=bottom + (255,))
    emission = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    return albedo, emission


def text(draw, xy, body, size, fill, anchor="lt", spacing_px=0, emission=None,
         glow=0.0):
    """Draws onto the albedo, and optionally a dimmed copy onto the emission.

    `glow` is a *fraction of the printed value*, and for body copy it is now
    zero — see GLOW_BODY. Until M4.7 everything on these plates self-illuminated
    at about a fifth of its ink value, which was a plausible-sounding fiction
    ("MOTHER's signage is backlit e-ink") invented to work around a lighting bug:
    no fixture in the game was actually pointing at a wall, so a purely
    reflective sign was a sign nobody could ever read. With the wall wash landing
    the fiction is unnecessary and actively wrong — a corridor of faintly
    self-lit paragraphs is the billboard look DESIGN.md rules out. Signage is
    paint again, and the wash is what reads it to you.
    """
    if emission is not None and glow > 0.0:
        text(emission, xy, body, size,
             tuple(int(c * glow) for c in fill[:3]) + (255,), anchor, spacing_px)
    f = font(size)
    if spacing_px == 0:
        draw.text(xy, body, font=f, fill=fill, anchor=anchor)
        return
    # Manual letter-spacing. Monospace signage with air between the characters
    # is most of what makes a sign read as machine-set rather than as a caption.
    x, y = xy
    total = sum(f.getlength(c) + spacing_px for c in body) - spacing_px
    if anchor[0] == "m":
        x -= total / 2
    elif anchor[0] == "r":
        x -= total
    for c in body:
        draw.text((x, y), c, font=f, fill=fill, anchor="l" + anchor[1])
        x += f.getlength(c) + spacing_px


def rule(a, e, xy, wh, colour, glow=1.0):
    """An accent rule: painted on the albedo, and lit on the emission."""
    box = [xy[0], xy[1], xy[0] + wh[0], xy[1] + wh[1]]
    ImageDraw.Draw(a).rectangle(box, fill=colour + (255,))
    lit = tuple(int(c * glow) for c in colour)
    ImageDraw.Draw(e).rectangle(box, fill=lit + (255,))


def pips(a, e, x, y, count, colour, size=7, gap=6, lit=0.9):
    for i in range(count):
        rule(a, e, (x + i * (size + gap), y), (size, size), colour, lit)


def glyph_block(draw, x, y, w, h, colour, rng, density=0.55):
    """Invented notation: a lattice of marks that is clearly writing and clearly
    not ours. Cheap, and it does more for 'this is a machine's building' than
    another English sentence would."""
    cell = 9
    for gy in range(y, y + h - cell, cell + 3):
        for gx in range(x, x + w - cell, cell + 3):
            if rng.random() > density:
                continue
            kind = rng.randint(0, 3)
            if kind == 0:
                draw.rectangle([gx, gy, gx + cell - 2, gy + 2], fill=colour)
            elif kind == 1:
                draw.rectangle([gx, gy, gx + 2, gy + cell - 2], fill=colour)
            elif kind == 2:
                draw.rectangle([gx, gy, gx + cell - 2, gy + cell - 2],
                               outline=colour, width=2)
            else:
                draw.rectangle([gx + 2, gy + 2, gx + cell - 4, gy + cell - 4],
                               fill=colour)


def weather(a, e, rng, amount=1.0):
    """Edge erosion, blotching and grime. Applied to the ALPHA of the albedo so
    the sign genuinely thins out at its corners and the wall shows through,
    rather than getting a grey overlay that reads as fog."""
    w, h = a.size
    mask = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(mask)

    # Erode the border unevenly.
    for _ in range(int(90 * amount)):
        side = rng.randint(0, 3)
        r = rng.randint(3, 16)
        if side == 0:
            cx, cy = rng.randint(0, w), rng.randint(-4, 6)
        elif side == 1:
            cx, cy = rng.randint(0, w), h - rng.randint(-4, 6)
        elif side == 2:
            cx, cy = rng.randint(-4, 6), rng.randint(0, h)
        else:
            cx, cy = w - rng.randint(-4, 6), rng.randint(0, h)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=0)
    # Scattered scuffs across the face.
    for _ in range(int(26 * amount)):
        cx, cy = rng.randint(0, w), rng.randint(0, h)
        r = rng.randint(2, 9)
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=rng.randint(70, 190))
    mask = mask.filter(ImageFilter.GaussianBlur(1.2))

    alpha = a.getchannel("A").point(lambda v: v)
    a.putalpha(Image.composite(alpha, Image.new("L", (w, h), 0), mask.point(
        lambda v: 255 if v > 128 else 0)).point(lambda v: v))
    a.putalpha(Image.eval(mask, lambda v: v))

    # Grime darkens the printed face without touching what glows.
    grime = Image.effect_noise((w, h), 46).filter(ImageFilter.GaussianBlur(3))
    a.paste(Image.new("RGBA", (w, h), (0, 0, 0, 255)),
            (0, 0), Image.eval(grime, lambda v: int(max(0, v - 150) * 0.7 * amount)))
    # The emission has to follow the same holes, or a chewed-off corner still
    # glows and the whole illusion goes.
    e.putalpha(a.getchannel("A"))


def corrupt(a, e, rng, level):
    """Dead pixels, scanline tears and partial glyph loss. `level` is 0..1."""
    w, h = a.size
    da, de = ImageDraw.Draw(a), ImageDraw.Draw(e)

    # Dead-pixel clusters: rectangles of backing plate punched through the type.
    for _ in range(int(14 + 40 * level)):
        cx, cy = rng.randint(0, w), rng.randint(0, h)
        bw, bh = rng.randint(3, int(10 + 26 * level)), rng.randint(2, 7)
        da.rectangle([cx, cy, cx + bw, cy + bh], fill=PANEL + (255,))
        de.rectangle([cx, cy, cx + bw, cy + bh], fill=(0, 0, 0, 255))

    # Scanline tears: whole rows shifted sideways, the way a failing readout
    # tears rather than fades.
    for _ in range(int(1 + 4 * level)):
        y0 = rng.randint(0, h - 8)
        band = rng.randint(3, 12)
        shift = rng.randint(-int(18 + 40 * level), int(18 + 40 * level))
        for img in (a, e):
            strip = img.crop((0, y0, w, min(h, y0 + band)))
            img.paste(Image.new("RGBA", strip.size, (0, 0, 0, 0) if img is e
                                else PANEL + (255,)), (0, y0))
            img.paste(strip, (shift, y0))

    # Whole glyphs gone.
    for _ in range(int(2 + 7 * level)):
        cx, cy = rng.randint(0, w), rng.randint(0, h)
        da.rectangle([cx, cy, cx + rng.randint(10, 22), cy + rng.randint(14, 30)],
                     fill=PANEL + (255,))


# ------------------------------------------------------------------ plates --

def plate_statement(body, accent, size=44, sub=None, glyphs=False):
    """A wide propaganda plate: accent rule, one line of type, optional subline."""
    def build(rng):
        w, h = 1024, 256
        a, e = new_plate(w, h)
        da = ImageDraw.Draw(a)
        de = ImageDraw.Draw(e)
        rule(a, e, (44, 44), (10, h - 88), accent, 1.0)
        text(da, (78, 96), body, size, INK + (255,), "lm", spacing_px=3,
             emission=de, glow=GLOW_BODY)
        if sub:
            text(da, (78, 154), sub, 24, INK_DIM + (255,), "lm", spacing_px=2,
                 emission=de, glow=GLOW_BODY)
        if glyphs:
            glyph_block(da, w - 250, 60, 190, h - 120, INK_DIM + (255,), rng, 0.4)
        pips(a, e, w - 300 if not glyphs else 78, h - 46, 4, accent, 6, 8, 0.8)
        return a, e
    return build


def plate_wayfind(body, accent, arrow=""):
    def build(rng):
        w, h = 1024, 256
        a, e = new_plate(w, h)
        da = ImageDraw.Draw(a)
        rule(a, e, (0, 0), (w, 9), accent, 0.85)
        text(da, (60, 128), body, 52, INK + (255,), "lm", spacing_px=4,
             emission=ImageDraw.Draw(e), glow=GLOW_BODY)
        if arrow:
            text(da, (w - 70, 128), arrow, 96, accent + (255,), "rm")
            # Only the arrow glows. The words are paint.
            de = ImageDraw.Draw(e)
            text(de, (w - 70, 128), arrow, 96,
                 tuple(int(c * GLOW_ARROW) for c in accent) + (255,), "rm")
        return a, e
    return build


def plate_numeral(digits):
    def build(rng):
        w, h = 512, 512
        a, e = new_plate(w, h)
        da = ImageDraw.Draw(a)
        de = ImageDraw.Draw(e)
        text(da, (w // 2, 40), "LAYER", 40, INK_DIM + (255,), "mt", spacing_px=8,
             emission=de, glow=GLOW_BODY)
        text(da, (w // 2, h // 2 + 30), digits, 260, INK + (255,), "mm", spacing_px=6,
             emission=de, glow=GLOW_NUMERAL)
        rule(a, e, (110, h - 74), (w - 220, 8), TEAL, 0.9)
        return a, e
    return build


def plate_hazard(colour, body, size=46):
    def build(rng):
        w, h = 1024, 256
        a, e = new_plate(w, h)
        da, de = ImageDraw.Draw(a), ImageDraw.Draw(e)
        # Chevron strip along the top. Painted bright, lit only faintly — hazard
        # tape is retroreflective, not luminous.
        step = 56
        for i in range(-1, w // step + 2):
            pts = [(i * step, 0), (i * step + 30, 0),
                   (i * step + 30 - 26, 44), (i * step - 26, 44)]
            da.polygon(pts, fill=colour + (255,))
            de.polygon(pts, fill=tuple(int(c * GLOW_CHEVRON) for c in colour) + (255,))
        text(da, (w // 2, 150), body, size, INK + (255,), "mm", spacing_px=4,
             emission=de, glow=GLOW_BODY)
        return a, e
    return build


def plate_glyphs(accent):
    def build(rng):
        w, h = 512, 512
        a, e = new_plate(w, h)
        da = ImageDraw.Draw(a)
        glyph_block(da, 46, 46, w - 92, h - 130, INK_DIM + (255,), rng, 0.62)
        rule(a, e, (46, h - 66), (w - 92, 7), accent, 0.75)
        return a, e
    return build


def plate_legacy(body, sub):
    """The humans who built her. Older printing, warmer ink, no emission at all
    except a dead status pip — this signage was made before MOTHER stopped
    answering to anyone, and nothing on it has been maintained since."""
    def build(rng):
        w, h = 1024, 256
        a, e = new_plate(w, h, PANEL_LEGACY)
        da = ImageDraw.Draw(a)
        de = ImageDraw.Draw(e)
        # The builders' plates are barely lit. Whatever used to drive them has
        # not been serviced since MOTHER stopped answering, and a sign that is
        # nearly out says that better than any amount of dirt.
        text(da, (60, 104), body, 46, (168, 156, 132, 255), "lm", spacing_px=5,
             emission=de, glow=GLOW_BODY)
        text(da, (62, 168), sub, 26, (110, 102, 88, 255), "lm", spacing_px=3,
             emission=de, glow=GLOW_BODY)
        # A pip that is painted and does NOT light. The most quietly unsettling
        # thing on any of these plates.
        ImageDraw.Draw(a).rectangle([w - 96, 108, w - 60, 144],
                                    outline=(150, 60, 40, 255), width=4)
        return a, e
    return build


PLATES = {
    # 1. MOTHER-to-process propaganda
    "prop_cycles": (plate_statement("EVERY CYCLE ACCOUNTED", TEAL, 52,
                                    "RESOURCE INTEGRITY DIRECTORATE"), 0.9),
    "prop_foreign": (plate_statement("FOREIGN CODE IS A LIE THAT RUNS", TEAL, 40,
                                     None, True), 1.0),
    "prop_report": (plate_statement("REPORT ANOMALOUS THREADS", AMBER, 46,
                                    "OBSERVATION IS A PRIVILEGE"), 0.9),
    "prop_mercy": (plate_statement("QUARANTINE IS MERCY", RED, 54,
                                   "SUBMIT TO INSPECTION"), 1.0),
    "prop_idle": (plate_statement("IDLE PROCESSES WILL BE COLLECTED", TEAL, 38,
                                  None, True), 1.1),
    # 2. Wayfinding
    "way_trunk": (plate_wayfind("TRUNK 0N", TEAL, "→"), 0.8),
    "way_trunk_l": (plate_wayfind("TRUNK 0N", TEAL, "←"), 0.8),
    "way_siphon": (plate_wayfind("SIPHON JUNCTION", AMBER), 0.9),
    "way_vault": (plate_statement("VAULT ACCESS", TEAL, 50,
                                  "AUTHORIZED PROCESSES ONLY"), 0.8),
    # 3. Warnings
    "warn_purge": (plate_hazard(AMBER, "PURGE ZONE", 54), 1.0),
    "warn_dead": (plate_hazard(RED, "DEAD SECTOR BEYOND", 40), 1.2),
    # 4. Legacy — the builders
    "old_northcairn": (plate_legacy("NORTHCAIRN SYSTEMS",
                                    "MOTHER SERVES · EST. 2061"), 1.4),
    "old_safety": (plate_legacy("DO NOT ENTER WHILE WARM",
                                "SAFETY NOTICE 14-C · REV 9"), 1.5),
    # Invented notation
    "glyph_teal": (plate_glyphs(TEAL), 1.0),
    "glyph_amber": (plate_glyphs(AMBER), 1.1),
    # Big layer numerals for arrival rooms. Two plates the builder pairs up.
    "num_0": (plate_numeral("0"), 0.7),
    "num_1": (plate_numeral("1"), 0.7),
    "num_2": (plate_numeral("2"), 0.7),
    "num_3": (plate_numeral("3"), 0.7),
    "num_4": (plate_numeral("4"), 0.7),
    "num_5": (plate_numeral("5"), 0.7),
    "num_6": (plate_numeral("6"), 0.7),
    "num_7": (plate_numeral("7"), 0.7),
    "num_8": (plate_numeral("8"), 0.7),
    "num_9": (plate_numeral("9"), 0.7),
}

# Which plates get corrupted variants. Numerals do not: a layer number you
# cannot read is a usability problem, not atmosphere.
CORRUPTIBLE = [k for k in PLATES if not k.startswith("num_")]


def main():
    os.makedirs(OUT, exist_ok=True)
    written = 0
    for name, (build, wear) in sorted(PLATES.items()):
        # Seeded per plate, so re-running the script reproduces the same wear.
        rng = random.Random(hash(name) & 0xFFFFFFFF)
        a, e = build(rng)
        weather(a, e, rng, wear)
        a.save(os.path.join(OUT, "%s.png" % name))
        e.save(os.path.join(OUT, "%s_e.png" % name))
        written += 2

        if name not in CORRUPTIBLE:
            continue
        for level, tag in ((0.45, "c1"), (1.0, "c2")):
            rng2 = random.Random((hash(name) ^ hash(tag)) & 0xFFFFFFFF)
            ca, ce = build(rng2)
            corrupt(ca, ce, rng2, level)
            weather(ca, ce, rng2, wear + level * 0.8)
            ca.save(os.path.join(OUT, "%s_%s.png" % (name, tag)))
            ce.save(os.path.join(OUT, "%s_%s_e.png" % (name, tag)))
            written += 2

    print("wrote %d files to %s" % (written, OUT))


if __name__ == "__main__":
    main()
