#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — Steam achievement icon set (procedural)
#
#   python3 tools/build_achievement_icons.py
#   python3 tools/build_achievement_icons.py --sheets /tmp/.../bells
#   python3 tools/build_achievement_icons.py --only ROOTED
#
# Generates a 256x256 PNG pair (unlocked + locked) for every achievement in
# DESIGN.md — the v1 wired list AND the v2 catalog, 50 in total.
#
# THE CATALOG IS PARSED FROM DESIGN.md, NOT COPIED
# ------------------------------------------------
# The ID list is read out of the two achievement tables in DESIGN.md at build
# time and cross-checked against the glyph registry below. Add an achievement
# to the design doc without drawing it and this tool fails loudly; draw one
# that no longer exists and it says so. An icon set that has silently drifted
# from the catalog is worse than no icon set, because you find out on the
# Steamworks upload page.
#
# DESIGN LANGUAGE
# ---------------
# DESIGN.md puts the player's whole interface on cassette-futurism CRT: the
# crew are human-built programs, so their instruments are old HUMAN tech —
# amber phosphor, scanlines, ghost persistence. The achievement set is part of
# that instrument, so every icon is a phosphor readout: near-black ground, a
# faint plate grid, one glyph excited in phosphor with real bloom, scanlines
# over the top, and a hair of chromatic fringe from a misconverged tube.
#
# SHAPE FIRST (the a11y rule, enforced not asserted)
# --------------------------------------------------
# DESIGN.md pillar 7: colour is never the only channel. So every glyph is
# built to carry its whole meaning as a SILHOUETTE. Category hue is garnish —
# six restrained phosphor tints that help a player group the set at a glance
# and carry exactly zero information that the shape does not already carry.
# `--sheets` writes a 64 px sheet and a GREYSCALE 64 px sheet so this claim is
# checkable rather than merely claimed.
#
# THE VOCABULARY (the intricacy law)
# ----------------------------------
# Glyphs are assembled from an authored vocabulary of NULLVOID motifs — the
# rooted node, the data chip hexagon, the Cycles gauge arc, the drop-shaft
# chevron, the a11y player shape-tags, the Scrubber wedge, the Sentinel with
# its exposed core, the beam cone, the depth ladder. Related achievements
# deliberately share a motif and differ by a COUNTABLE property (the backdoor
# family is the same node over 1/2/3/4 ladder rungs), so the set reads as one
# instrument rather than fifty unrelated doodles. Nothing here is a rotated
# copy of anything else.
#
# Rendering is 4x supersampled and downsampled with Lanczos; the glow is a
# three-radius blur stack, which is what makes phosphor look like phosphor
# instead of like a drop shadow.
#
# PIL + numpy. CPU only. No fonts are used anywhere — every mark is geometry,
# so the set is reproducible on any machine and carries no licence baggage.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import math
import os
import re
import sys
import zlib

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 256
SS = 4                      # supersampling factor
CANVAS = SIZE * SS

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DESIGN = os.path.join(REPO, "DESIGN.md")
OUT_DIR = os.path.join(REPO, "assets", "steam", "achievements")

#: Category tints. Amber is the house phosphor (the HUD's own); the others are
#: small deviations from it, never saturated jumps — a set where every sixth
#: icon is a different colour looks like six sets. Hidden/lore gets the one
#: real departure (cold blue-white) because those icons ARE meant to feel like
#: they came from somewhere else.
TINTS = {
    "progression": (255, 176,  72),
    "combat":      (255, 132,  70),
    "world":       (196, 214,  96),
    "greed":       (255, 206,  92),
    "hidden":      (168, 206, 255),
    "coop":        (124, 220, 210),
}


# ===========================================================================
# 1. THE PEN — normalised drawing on the supersampled mask
# ===========================================================================

class Pen:
    """Draws into a single-channel mask in normalised [0,1] coordinates.

    Everything is expressed as a fraction of the icon, so a glyph function
    reads as a description of a shape rather than as a pile of pixel
    arithmetic, and the whole set can be re-rendered at another size by
    changing one constant."""

    def __init__(self) -> None:
        self.img = Image.new("L", (CANVAS, CANVAS), 0)
        self.d = ImageDraw.Draw(self.img)

    # -- coordinate helpers ------------------------------------------------
    def px(self, v: float) -> float:
        return v * CANVAS

    def pt(self, p) -> tuple[float, float]:
        return (p[0] * CANVAS, p[1] * CANVAS)

    def w(self, v: float) -> int:
        return max(int(round(v * CANVAS)), 1)

    # -- primitives --------------------------------------------------------
    def line(self, a, b, w=0.016, fill=255):
        self.d.line([self.pt(a), self.pt(b)], fill=fill, width=self.w(w))
        # Round the caps by hand — PIL's line has no cap style, and butt caps
        # on a 50-icon set full of polylines look like broken glass.
        for p in (a, b):
            self.dot(p, w / 2.0, fill)

    def polyline(self, pts, w=0.016, closed=False, fill=255):
        seq = list(pts) + ([pts[0]] if closed else [])
        for a, b in zip(seq, seq[1:]):
            self.line(a, b, w, fill)

    def dot(self, c, r, fill=255):
        x, y = self.pt(c)
        rr = self.px(r)
        self.d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=fill)

    def circle(self, c, r, w=0.016, fill=255):
        x, y = self.pt(c)
        rr, ww = self.px(r), self.w(w)
        self.d.ellipse([x - rr, y - rr, x + rr, y + rr], outline=fill, width=ww)

    def arc(self, c, r, a0, a1, w=0.016, fill=255):
        x, y = self.pt(c)
        rr, ww = self.px(r), self.w(w)
        self.d.arc([x - rr, y - rr, x + rr, y + rr], a0, a1, fill=fill, width=ww)

    def poly(self, pts, fill=255):
        self.d.polygon([self.pt(p) for p in pts], fill=fill)

    def rect(self, x0, y0, x1, y1, w=0.016, fill=255):
        self.polyline([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], w, True, fill)

    def box(self, x0, y0, x1, y1, fill=255):
        self.d.rectangle([self.px(x0), self.px(y0), self.px(x1), self.px(y1)], fill=fill)

    def ngon(self, c, r, n, rot=0.0, w=0.016, fill=255, filled=False):
        pts = [(c[0] + r * math.cos(rot + 2 * math.pi * k / n),
                c[1] + r * math.sin(rot + 2 * math.pi * k / n)) for k in range(n)]
        if filled:
            self.poly(pts, fill)
        else:
            self.polyline(pts, w, True, fill)

    def dashes(self, a, b, n=6, w=0.014, duty=0.55, fill=255):
        for k in range(n):
            t0 = k / n
            t1 = t0 + duty / n
            p0 = (a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0)
            p1 = (a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1)
            self.line(p0, p1, w, fill)

    def ticks(self, c, r0, r1, n, a0=0.0, a1=2 * math.pi, w=0.012, fill=255):
        for k in range(n):
            a = a0 + (a1 - a0) * (k / max(n - 1, 1))
            self.line((c[0] + r0 * math.cos(a), c[1] + r0 * math.sin(a)),
                      (c[0] + r1 * math.cos(a), c[1] + r1 * math.sin(a)), w, fill)

    def erase(self, fn):
        """Run a drawing call in 'cut' mode — used to punch a gap so two
           overlapping motifs read as separate objects instead of a blob."""
        fn(0)


# ===========================================================================
# 2. THE VOCABULARY — NULLVOID motifs, shared across glyphs
# ===========================================================================

def m_chip(p: Pen, c, r, filled=False, w=0.014):
    """The data chip: a flat hexagon with an emissive circuit inlay. This is
       the actual in-world salvage token (DESIGN.md, Data)."""
    p.ngon(c, r, 6, rot=math.pi / 6, w=w, filled=filled)
    if not filled:
        p.line((c[0] - r * 0.42, c[1]), (c[0] + r * 0.42, c[1]), w * 0.75)
        p.line((c[0], c[1] - r * 0.30), (c[0], c[1] + r * 0.30), w * 0.75)


def m_node(p: Pen, c, r, w=0.016):
    """The dormant maintenance node, drawn as a PORT: a ring with four
       radial spokes into a live core.

       It started life as a ring with roots fanning downward, which was the
       literal reading of 'rooted' and completely wrong at icon scale — a
       circle on a stalk with three legs is a stick figure, and four
       backdoor icons all read as a man on a ladder. The spokes make it
       unambiguously hardware; the anchoring is done by `m_anchor` below."""
    p.circle(c, r, w)
    p.circle(c, r * 1.34, w * 0.55)
    p.dot(c, r * 0.30)
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        p.line((c[0] + r * 0.34 * math.cos(a), c[1] + r * 0.34 * math.sin(a)),
               (c[0] + r * math.cos(a), c[1] + r * math.sin(a)), w * 0.7)


def m_anchor(p: Pen, cx, y0, y1, strata_ys, w=0.014):
    """The shaft driven down from a node, with a pair of barbs biting at every
       stratum it passes. The barbs are what make it 'rooted' rather than
       merely 'deep' — and they are countable, which is the whole scheme."""
    p.line((cx, y0), (cx, y1), w)
    for k, y in enumerate(strata_ys):
        half = 0.055 + k * 0.012
        p.line((cx, y - half * 0.55), (cx - half, y + half * 0.62), w * 0.8)
        p.line((cx, y - half * 0.55), (cx + half, y + half * 0.62), w * 0.8)


def m_strata(p: Pen, x, y0, n, dy=0.125, w=0.015):
    """`n` layer strata, widening with depth — the rings you have driven
       through. Stratum COUNT is the information, and a count is countable at
       64 px and in greyscale, which a numeral is not.

       This replaced an earlier two-rail ladder: at icon scale a ladder under
       a round node reads as a stick figure on a ladder, which is a very
       different picture from 'a node rooted four rings deep'. Broken, widening
       horizontals read as strata and nothing else."""
    for k in range(n):
        y = y0 + k * dy
        half = 0.17 + k * 0.052
        p.dashes((x - half, y), (x + half, y), 3 + k, w, duty=0.72)


def m_gauge(p: Pen, c, r, frac, w=0.020, span=280.0):
    """The shared-Cycles ring, the HUD's anchor element. `frac` fills it from
       the bottom-left, clockwise, exactly as the instrument does."""
    start = 130.0
    p.arc(c, r, start, start + span, w * 0.55)
    if frac > 0.0:
        p.arc(c, r, start, start + span * frac, w)
    p.ticks(c, r * 1.16, r * 1.30, 5,
            math.radians(start), math.radians(start + span), w * 0.5)


def m_shaft(p: Pen, c, s, chevrons=3, w=0.018):
    """The drop-shaft descent chevron stack."""
    for k in range(chevrons):
        y = c[1] - s * 0.55 + k * s * 0.52
        p.polyline([(c[0] - s * 0.62, y), (c[0], y + s * 0.40),
                    (c[0] + s * 0.62, y)], w * (1.0 - 0.14 * k))


def m_tag(p: Pen, c, s, kind, w=0.016, filled=False):
    """The per-player a11y shape tags — triangle / circle / square / diamond,
       the exact set DESIGN.md pillar 7 mandates. Reusing the game's own
       colour-independent player language here is free consistency."""
    if kind == 0:
        pts = [(c[0], c[1] - s), (c[0] + s * 0.92, c[1] + s * 0.72),
               (c[0] - s * 0.92, c[1] + s * 0.72)]
        p.poly(pts) if filled else p.polyline(pts, w, True)
    elif kind == 1:
        p.dot(c, s) if filled else p.circle(c, s * 0.9, w)
    elif kind == 2:
        if filled:
            p.box(c[0] - s * 0.82, c[1] - s * 0.82, c[0] + s * 0.82, c[1] + s * 0.82)
        else:
            p.rect(c[0] - s * 0.82, c[1] - s * 0.82, c[0] + s * 0.82, c[1] + s * 0.82, w)
    else:
        pts = [(c[0], c[1] - s), (c[0] + s, c[1]), (c[0], c[1] + s), (c[0] - s, c[1])]
        p.poly(pts) if filled else p.polyline(pts, w, True)


def m_scrubber(p: Pen, c, s, w=0.014, cut=False):
    """The Scrubber: a low, fast, many-legged wedge. Pack hunter, cheap and
       disposable — so the silhouette is small, angular and leggy."""
    body = [(c[0] - s * 0.86, c[1] + s * 0.16), (c[0] - s * 0.22, c[1] - s * 0.42),
            (c[0] + s * 0.52, c[1] - s * 0.30), (c[0] + s * 0.88, c[1] + s * 0.18),
            (c[0] + s * 0.30, c[1] + s * 0.40), (c[0] - s * 0.38, c[1] + s * 0.42)]
    p.poly(body)
    for k, (dx, dy) in enumerate([(-0.80, 0.30), (-0.34, 0.42), (0.30, 0.42), (0.80, 0.28)]):
        knee = (c[0] + s * dx * 1.30, c[1] + s * (dy + 0.34))
        p.line((c[0] + s * dx, c[1] + s * dy), knee, w * 0.9)
        p.line(knee, (c[0] + s * dx * 1.52, c[1] + s * (dy + 0.86)), w * 0.75)
    if cut:
        p.line((c[0] - s * 1.25, c[1] + s * 0.95), (c[0] + s * 1.25, c[1] - s * 0.95), 0.022)


def m_sentinel(p: Pen, c, s, w=0.016, core=True):
    """The Sentinel: tall, armoured, slab-shouldered, with the exposed
       emissive core that takes bonus damage during SCAN and PURGE."""
    # Narrow and TALL — a 2.6 m quarantine process. The earlier proportions
    # were as wide as they were high and read as a tent.
    p.polyline([(c[0] - s * 0.34, c[1] + s * 1.05), (c[0] - s * 0.40, c[1] - s * 0.38),
                (c[0] - s * 0.22, c[1] - s * 0.72), (c[0] - s * 0.20, c[1] - s * 1.05),
                (c[0] + s * 0.20, c[1] - s * 1.05), (c[0] + s * 0.22, c[1] - s * 0.72),
                (c[0] + s * 0.40, c[1] - s * 0.38), (c[0] + s * 0.34, c[1] + s * 1.05)],
               w, True)
    # Shoulder slabs — the armour that a solo kill has to get through.
    p.line((c[0] - s * 0.62, c[1] - s * 0.52), (c[0] - s * 0.24, c[1] - s * 0.66), w)
    p.line((c[0] + s * 0.62, c[1] - s * 0.52), (c[0] + s * 0.24, c[1] - s * 0.66), w)
    p.line((c[0] - s * 0.62, c[1] - s * 0.52), (c[0] - s * 0.56, c[1] - s * 0.24), w * 0.8)
    p.line((c[0] + s * 0.62, c[1] - s * 0.52), (c[0] + s * 0.56, c[1] - s * 0.24), w * 0.8)
    p.line((c[0] - s * 0.37, c[1] + s * 0.52), (c[0] + s * 0.37, c[1] + s * 0.52), w * 0.7)
    if core:
        p.dot((c[0], c[1] + s * 0.02), s * 0.17)
        p.circle((c[0], c[1] + s * 0.02), s * 0.29, w * 0.7)


def m_figure(p: Pen, c, s, pose="stand", w=0.018):
    """A crew avatar silhouette. Three poses cover every glyph that needs a
       person: standing, corrupted (kneeling), and rising from a restore."""
    if pose == "down":
        # Collapsed, seen from the side: head low and forward, spine curved,
        # one arm braced, legs folded under. The first version was a dot and
        # two strokes and vanished under anything drawn over it.
        p.dot((c[0] - s * 0.62, c[1] + s * 0.02), s * 0.27)
        p.polyline([(c[0] - s * 0.38, c[1] + s * 0.14),
                    (c[0] - s * 0.02, c[1] + s * 0.02),
                    (c[0] + s * 0.40, c[1] + s * 0.24)], w * 1.15)
        # braced arm
        p.polyline([(c[0] - s * 0.24, c[1] + s * 0.12),
                    (c[0] - s * 0.30, c[1] + s * 0.58),
                    (c[0] - s * 0.62, c[1] + s * 0.70)], w * 0.85)
        # folded legs
        p.polyline([(c[0] + s * 0.40, c[1] + s * 0.24),
                    (c[0] + s * 0.72, c[1] + s * 0.58),
                    (c[0] + s * 0.28, c[1] + s * 0.72)], w * 0.85)
        p.line((c[0] + s * 0.28, c[1] + s * 0.72), (c[0] - s * 0.10, c[1] + s * 0.70), w * 0.8)
        return
    head_y = c[1] - s * (0.66 if pose == "stand" else 0.44)
    p.dot((c[0], head_y), s * 0.25)
    p.line((c[0], head_y + s * 0.26), (c[0], c[1] + s * 0.34), w)
    if pose == "rise":
        p.line((c[0], c[1] - s * 0.02), (c[0] + s * 0.56, c[1] - s * 0.52), w * 0.85)
        p.line((c[0], c[1] - s * 0.02), (c[0] - s * 0.40, c[1] + s * 0.18), w * 0.85)
        p.line((c[0], c[1] + s * 0.34), (c[0] - s * 0.36, c[1] + s * 0.92), w * 0.85)
        p.line((c[0], c[1] + s * 0.34), (c[0] + s * 0.44, c[1] + s * 0.84), w * 0.85)
    else:
        p.line((c[0], c[1] - s * 0.10), (c[0] - s * 0.44, c[1] + s * 0.16), w * 0.85)
        p.line((c[0], c[1] - s * 0.10), (c[0] + s * 0.44, c[1] + s * 0.16), w * 0.85)
        p.line((c[0], c[1] + s * 0.34), (c[0] - s * 0.32, c[1] + s * 0.94), w * 0.85)
        p.line((c[0], c[1] + s * 0.34), (c[0] + s * 0.32, c[1] + s * 0.94), w * 0.85)


def m_beam(p: Pen, apex, ang, spread, length, w=0.014, rays=3):
    """The headlamp / decryption beam cone — pillar 2's whole thesis."""
    a0, a1 = ang - spread, ang + spread
    p.line(apex, (apex[0] + length * math.cos(a0), apex[1] + length * math.sin(a0)), w)
    p.line(apex, (apex[0] + length * math.cos(a1), apex[1] + length * math.sin(a1)), w)
    for k in range(rays):
        t = (k + 1) / (rays + 1)
        r = length * (0.45 + 0.55 * t)
        p.arc(apex, r, math.degrees(a0), math.degrees(a1), w * 0.5)


def m_bracket(p: Pen, x0, y0, x1, y1, w=0.016, tab=0.055):
    """The instrument bracket — corner ticks rather than a closed box. Used to
       say 'this is a reading', which is the tone the whole HUD is written in."""
    for (cx, sx) in ((x0, 1), (x1, -1)):
        for (cy, sy) in ((y0, 1), (y1, -1)):
            p.line((cx, cy), (cx + sx * tab, cy), w)
            p.line((cx, cy), (cx, cy + sy * tab), w)


def m_uplink(p: Pen, cx, top, bot, half, w=0.017):
    """The exfil uplink drawn as a SHAFT — two rails off a floor plate, with
       stacked chevrons climbing out of the top — leaving the middle empty for
       whatever is being lifted out.

       The first version of this was a single big arrow with the payload drawn
       on top of it. Every payload collided with the arrowhead and the icons
       turned to mush at 64 px. A frame with a deliberate void is the fix: the
       motif is now a container, and containers compose."""
    # Rails are DASHED and stop well short of the chevrons. Solid rails that
    # met a chevron drew a roofline, and three icons in a row read as barns.
    p.dashes((cx - half, bot - 0.03), (cx - half, top + 0.20), 5, w)
    p.dashes((cx + half, bot - 0.03), (cx + half, top + 0.20), 5, w)
    p.line((cx - half - 0.05, bot), (cx + half + 0.05, bot), w * 1.15)
    p.line((cx - half - 0.05, bot), (cx - half - 0.05, bot - 0.045), w)
    p.line((cx + half + 0.05, bot), (cx + half + 0.05, bot - 0.045), w)
    for k in range(2):
        y = top + 0.13 - k * 0.075
        sc = 1.0 - 0.28 * k
        p.polyline([(cx - half * 0.70 * sc, y), (cx, y - 0.075 * sc),
                    (cx + half * 0.70 * sc, y)], w * (1.0 - 0.18 * k))


def m_terminal(p: Pen, c, s, w=0.016, caret=True):
    """A crew CRT console — the GTFO-cousin command terminal."""
    p.rect(c[0] - s, c[1] - s * 0.76, c[0] + s, c[1] + s * 0.62, w)
    p.line((c[0] - s * 0.34, c[1] + s * 0.62), (c[0] - s * 0.34, c[1] + s * 0.86), w * 0.7)
    p.line((c[0] + s * 0.34, c[1] + s * 0.62), (c[0] + s * 0.34, c[1] + s * 0.86), w * 0.7)
    p.line((c[0] - s * 0.62, c[1] + s * 0.86), (c[0] + s * 0.62, c[1] + s * 0.86), w)
    if caret:
        p.line((c[0] - s * 0.66, c[1] - s * 0.18), (c[0] - s * 0.40, c[1] - s * 0.18), w)
        p.box(c[0] - s * 0.30, c[1] - s * 0.34, c[0] - s * 0.10, c[1] - s * 0.02)


def m_dotrow(p: Pen, x0, x1, y, n, r=0.010):
    """Dot-matrix readout text, without a font — the HUD's own numeral style."""
    for k in range(n):
        p.dot((x0 + (x1 - x0) * (k / max(n - 1, 1)), y), r)


def m_breaker(p: Pen, c, s, w=0.016):
    """The breaker: a short-range cutter. A tool, not a gun — so the profile
       is a boxy emitter with a stubby grip, deliberately unheroic."""
    p.rect(c[0] - s * 0.86, c[1] - s * 0.34, c[0] + s * 0.42, c[1] + s * 0.22, w)
    p.polyline([(c[0] + s * 0.42, c[1] - s * 0.20), (c[0] + s * 0.92, c[1] - s * 0.10),
                (c[0] + s * 0.92, c[1] + s * 0.08), (c[0] + s * 0.42, c[1] + s * 0.16)],
               w * 0.85, True)
    p.polyline([(c[0] - s * 0.44, c[1] + s * 0.22), (c[0] - s * 0.54, c[1] + s * 0.84),
                (c[0] - s * 0.12, c[1] + s * 0.84), (c[0] - s * 0.06, c[1] + s * 0.22)],
               w * 0.85)


def m_vent(p: Pen, c, s, w=0.014, louvers=4):
    """A vent cover — the Scrubber ingress point you can weld shut."""
    p.rect(c[0] - s, c[1] - s * 0.78, c[0] + s, c[1] + s * 0.78, w)
    for k in range(louvers):
        y = c[1] - s * 0.50 + k * s * 1.00 / max(louvers - 1, 1)
        p.line((c[0] - s * 0.74, y), (c[0] + s * 0.74, y), w * 0.9)
    for dx in (-1, 1):
        for dy in (-1, 1):
            p.dot((c[0] + dx * s * 0.86, c[1] + dy * s * 0.62), 0.008)


# ===========================================================================
# 3. THE GLYPHS — one deliberate design per achievement
# ===========================================================================
# Each function draws ONE glyph. The docstring is the rationale, and it is the
# same text the build prints with --rationale.

def g_FIRST_DELETION(p):
    """One Scrubber, one cut. The whole achievement is 'you killed the first
       thing', so: a single pack-hunter wedge with a single clean diagonal
       through it, and no counter — counting starts at PEST_CONTROL."""
    # Draw the creature once, split it along a diagonal, and slide the two
    # halves apart. A line drawn OVER a body reads as a spear; a body in two
    # pieces with daylight between them reads as deleted.
    src = Pen()
    m_scrubber(src, (0.50, 0.50), 0.30)
    above, below = Pen(), Pen()
    above.poly([(-0.2, 0.86), (1.2, 0.16), (1.2, -0.2), (-0.2, -0.2)])
    below.poly([(-0.2, 0.86), (1.2, 0.16), (1.2, 1.2), (-0.2, 1.2)])
    top = Image.new("L", (CANVAS, CANVAS), 0)
    top.paste(src.img, (0, 0), above.img)
    bot = Image.new("L", (CANVAS, CANVAS), 0)
    bot.paste(src.img, (0, 0), below.img)
    d = int(0.026 * CANVAS)
    p.img = ImageChops.lighter(
        p.img, ImageChops.lighter(ImageChops.offset(top, d, -d),
                                  ImageChops.offset(bot, -d, d)))
    p.d = ImageDraw.Draw(p.img)
    # The cut itself, as a hairline in the gap.
    p.line((0.05, 0.87), (0.95, 0.42), 0.010)


def g_ROOTED(p):
    """The rooted maintenance node itself, roots driven into one ladder rung.
       This is rung 1 of the backdoor family (ROOTED / ROOTED_DEEP /
       DEEP_STATE / DEEP_STATE_2 = 1/2/3/4 rungs); depth is countable, not
       written."""
    m_node(p, (0.50, 0.340), 0.155)
    m_anchor(p, 0.50, 0.548, 0.735, [0.68])
    m_strata(p, 0.50, 0.680, 1, dy=0.125)


def g_NULL_AND_VOID(p):
    """An empty data chip with a slashed zero inside it, inside the buffer
       bracket. You wiped, and the chip you were carrying has nothing on it."""
    m_chip(p, (0.50, 0.50), 0.26)
    p.circle((0.50, 0.50), 0.115, 0.016)
    p.line((0.42, 0.585), (0.58, 0.415), 0.016)
    m_bracket(p, 0.20, 0.20, 0.80, 0.80, 0.014)


def g_ONE_MORE_RING(p):
    """Concentric privilege rings with a descent arrow driving straight
       through, past a side branch (the exfil you did not take) that ends in a
       stub. The refused option is drawn, because refusing it IS the
       achievement."""
    for r in (0.34, 0.25, 0.16):
        p.circle((0.50, 0.50), r, 0.013)
    p.line((0.50, 0.13), (0.50, 0.80), 0.020)
    p.polyline([(0.41, 0.70), (0.50, 0.84), (0.59, 0.70)], 0.020)
    p.line((0.50, 0.34), (0.74, 0.34), 0.014)
    p.line((0.74, 0.34), (0.74, 0.24), 0.014)
    p.dot((0.74, 0.22), 0.020)


def g_PACIFIST_PROTOCOL(p):
    """The breaker with a dead-flat emission line running out of its muzzle —
       a waveform that never spiked, because it never fired. Flatline is the
       mute/never-used motif and it recurs (deliberately) in PACIFIST_DEEP."""
    m_breaker(p, (0.36, 0.50), 0.24)
    p.line((0.60, 0.49), (0.88, 0.49), 0.016)
    m_bracket(p, 0.14, 0.24, 0.90, 0.78, 0.013)


def g_LIGHTS_OUT(p):
    """The Cycles gauge at dead empty, wrapped in a closing vision iris — the
       zero-Cycles presentation is literally the world shrinking around you.
       The iris is drawn as three arcs closing inward, not as a filled hole,
       so it survives at 64 px."""
    # Empty gauge track with its zero marker, inside a closing vision iris.
    p.arc((0.50, 0.52), 0.185, 130, 410, 0.013)
    p.ticks((0.50, 0.52), 0.145, 0.185, 5,
            math.radians(130), math.radians(410), 0.010)
    p.line((0.50, 0.52), (0.50 + 0.175 * math.cos(math.radians(130)),
                          0.52 + 0.175 * math.sin(math.radians(130))), 0.017)
    p.dot((0.50, 0.52), 0.022)
    for k, r in enumerate((0.41, 0.345, 0.285)):
        for a in (0, 120, 240):
            p.arc((0.50, 0.52), r, a + k * 16, a + 76 + k * 16, 0.015)


def g_NO_AGENT_LEFT(p):
    """All four a11y player tags in a ring formation — a crew holding a
       perimeter — rising through the exfil arrow. Four DISTINCT shapes, so a
       colourblind player counts four crew, not four dots."""
    m_uplink(p, 0.50, 0.16, 0.90, 0.33)
    for k, (dx, dy) in enumerate([(-0.135, -0.08), (0.135, -0.08),
                                  (-0.135, 0.165), (0.135, 0.165)]):
        m_tag(p, (0.50 + dx, 0.52 + dy), 0.080, k, 0.014, filled=True)


def g_COLD_BOOT(p):
    """Deliberately the same exfil arrow as NO_AGENT_LEFT with exactly ONE
       tag in it. The pair is meant to be read side by side: crew of four,
       crew of one. Solo is not a lesser icon — it is the same frame, emptier."""
    m_uplink(p, 0.50, 0.16, 0.90, 0.33)
    # One crew present, three berths drawn as empty OUTLINES of the other
    # three tags. Solo is the same frame with three holes in it, which is
    # exactly how solo NULLVOID is supposed to feel.
    m_tag(p, (0.365, 0.44), 0.080, 0, 0.014, filled=True)
    for k, (dx, dy) in enumerate([(0.135, -0.08), (-0.135, 0.165), (0.135, 0.165)], start=1):
        m_tag(p, (0.50 + dx, 0.52 + dy), 0.072, k, 0.009)


def g_DEEP_STATE(p):
    """Backdoor family, rung 3 — the layer-15 node."""
    m_node(p, (0.50, 0.240), 0.125)
    m_anchor(p, 0.50, 0.407, 0.845, [0.5, 0.645, 0.79])
    m_strata(p, 0.50, 0.500, 3, dy=0.145)


def g_KERNEL_PANIC(p):
    """The Kernel as a solid core disc, fractured. Radial cracks that do not
       meet the rim, so the disc still reads as a disc at 64 px — a fully
       shattered ring turns to mush at small sizes."""
    p.circle((0.50, 0.50), 0.30, 0.018)
    p.dot((0.50, 0.50), 0.115)
    rng = np.random.default_rng(7)
    for k in range(7):
        a = 2 * math.pi * k / 7 + 0.22
        r0, r1 = 0.135, 0.265 + 0.02 * rng.random()
        mid = (0.50 + r0 * 1.5 * math.cos(a + 0.10), 0.50 + r0 * 1.5 * math.sin(a + 0.10))
        p.line((0.50 + r0 * math.cos(a), 0.50 + r0 * math.sin(a)), mid, 0.014)
        p.line(mid, (0.50 + r1 * math.cos(a - 0.09), 0.50 + r1 * math.sin(a - 0.09)), 0.012)


def g_HOARDER_BUFFER(p):
    """Buffer Overflow: a container bracket packed with chips and two more
       spilling over the lip. The overflow is the two chips OUTSIDE the
       bracket — the shape says 'more than fits'."""
    m_bracket(p, 0.20, 0.36, 0.80, 0.86, 0.016, tab=0.075)
    for (x, y) in [(0.36, 0.74), (0.50, 0.74), (0.64, 0.74), (0.43, 0.58), (0.57, 0.58)]:
        m_chip(p, (x, y), 0.072, filled=True)
    m_chip(p, (0.72, 0.30), 0.070)
    m_chip(p, (0.30, 0.24), 0.062)


def g_MOTHERS_FAVORITE(p):
    """A downed figure and a restoring hand reaching in, with three tally
       ticks. The ticks are the whole joke — being restored three times is not
       a triumph, it is a record MOTHER is keeping."""
    # The body has to be the biggest thing here, or the arcs read as a
    # rainbow with a crumb under it.
    m_figure(p, (0.50, 0.74), 0.30, "down", 0.024)
    # Three completed restore arcs, nested and tight over the body. The
    # repetition IS the picture — MOTHER is keeping count, and the joke is
    # that being her favourite means being the one who keeps needing help.
    for k, r in enumerate((0.20, 0.28, 0.36)):
        p.arc((0.50, 0.74), r, 186, 354, 0.022 - k * 0.003)
        for a in (math.radians(186), math.radians(354)):
            p.dot((0.50 + r * math.cos(a), 0.74 + r * math.sin(a)), 0.019 - k * 0.003)


def g_FIRST_STEPS(p):
    """Hello World: the smallest possible descent — one shaft chevron and a
       two-rung ladder. The entry point of the whole ladder family."""
    m_shaft(p, (0.50, 0.30), 0.30, 2, 0.022)
    m_strata(p, 0.50, 0.66, 2, dy=0.17)


def g_ROOTED_DEEP(p):
    """Backdoor family, rung 2 — the layer-10 node."""
    m_node(p, (0.50, 0.280), 0.140)
    m_anchor(p, 0.50, 0.468, 0.790, [0.58, 0.735])
    m_strata(p, 0.50, 0.580, 2, dy=0.155)


def g_DEEP_STATE_2(p):
    """Backdoor family, rung 4 — the layer-20 node. Densest ladder in the
       set; the rungs crowd, which is the point."""
    m_node(p, (0.50, 0.200), 0.110)
    m_anchor(p, 0.50, 0.347, 0.880, [0.42, 0.5549999999999999, 0.69, 0.825])
    m_strata(p, 0.50, 0.420, 4, dy=0.135)


def g_RING_RUNNER(p):
    """A spiral cutting through five privilege rings in one continuous run.
       Not a ladder — RING_RUNNER is about distance travelled, not a node
       installed, so it gets motion where the backdoor family gets structure."""
    for r in (0.36, 0.29, 0.22, 0.15, 0.08):
        p.circle((0.50, 0.50), r, 0.011)
    pts = []
    for k in range(90):
        t = k / 89.0
        a = -math.pi / 2 + t * 3.4 * math.pi
        r = 0.40 - t * 0.335
        pts.append((0.50 + r * math.cos(a), 0.50 + r * math.sin(a)))
    p.polyline(pts, 0.017)
    p.dot(pts[-1], 0.024)


def g_FULLY_COMPILED(p):
    """ONE module track at max: a five-segment tier column, every segment
       filled, in a compile bracket. Reads against OVERENGINEERED, which is
       the same column eight times."""
    for k in range(5):
        y = 0.78 - k * 0.115
        p.box(0.42, y - 0.045, 0.58, y + 0.045)
    m_bracket(p, 0.32, 0.18, 0.68, 0.88, 0.016)


def g_OVERENGINEERED(p):
    """Every module track maxed — eight full columns. FULLY_COMPILED's single
       column repeated across the whole bracket: the difference between the
       two icons is a countable quantity, not a decoration."""
    for c in range(8):
        x = 0.185 + c * 0.090
        for k in range(4):
            y = 0.76 - k * 0.135
            p.box(x - 0.030, y - 0.052, x + 0.030, y + 0.052)
    m_bracket(p, 0.12, 0.14, 0.88, 0.86, 0.015)


def g_MILLIONAIRE(p):
    """Data Baron: banked chips stacked into a ziggurat inside the archive
       bracket. A vault, not a wallet — the archive is a place in this
       fiction."""
    rows = [4, 3, 2, 1]
    for r, n in enumerate(rows):
        y = 0.80 - r * 0.135
        for k in range(n):
            x = 0.50 + (k - (n - 1) / 2.0) * 0.135
            m_chip(p, (x, y), 0.062, filled=True)
    m_bracket(p, 0.14, 0.20, 0.86, 0.90, 0.016)


def g_PEST_CONTROL(p):
    """Three Scrubbers cut by one sweep, over a dot-matrix count row. Shares
       FIRST_DELETION's wedge and cut so the pair reads as 'the same job, at
       scale'."""
    for (x, y, s) in [(0.30, 0.44, 0.17), (0.54, 0.36, 0.15), (0.66, 0.56, 0.18)]:
        m_scrubber(p, (x, y), s)
    p.line((0.14, 0.68), (0.86, 0.24), 0.022)
    m_dotrow(p, 0.28, 0.72, 0.82, 7)


def g_EXTERMINATOR(p):
    """A lattice of process cells with a purge sweep erasing a whole diagonal
       band of them — the cells inside the band are drawn as empty outlines
       against filled neighbours. Mass deletion as a change of STATE across a
       grid, which is what 500 kills actually looks like from her side."""
    for r in range(5):
        for c in range(5):
            x, y = 0.24 + c * 0.13, 0.24 + r * 0.13
            gone = abs((c - r)) <= 1
            if gone:
                p.rect(x - 0.042, y - 0.042, x + 0.042, y + 0.042, 0.010)
            else:
                p.box(x - 0.042, y - 0.042, x + 0.042, y + 0.042)
    p.line((0.12, 0.24), (0.76, 0.88), 0.020)


def g_CORE_BREACH(p):
    """The Sentinel with its armour plates intact and a converging crosshair
       landing precisely on the exposed core. Nothing is broken except the
       core — 'core hits ONLY' is a statement about restraint."""
    m_sentinel(p, (0.50, 0.52), 0.28)
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        p.line((0.50 + dx * 0.20, 0.51 + dy * 0.20),
               (0.50 + dx * 0.36, 0.51 + dy * 0.36), 0.014)
    p.circle((0.50, 0.51), 0.155, 0.011)


def g_DAVID(p):
    """Pure scale contrast: a tier-0 breaker, tiny, against a Sentinel that
       fills the frame — and one thin line connecting them. The meaning is
       carried entirely by relative SIZE, which is the most colourblind-safe
       channel there is."""
    m_sentinel(p, (0.64, 0.48), 0.32)
    m_breaker(p, (0.24, 0.76), 0.115)
    p.dashes((0.32, 0.70), (0.54, 0.54), 4, 0.011)
    for k in range(3):
        p.line((0.13, 0.24 + k * 0.05), (0.19, 0.24 + k * 0.05), 0.011)


def g_UNTOUCHED(p):
    """Checksum Intact: one unbroken integrity ring — no gaps anywhere — with
       a checksum hash block inside it. Every other integrity glyph in the set
       has a gap; this one's completeness IS the achievement."""
    p.circle((0.50, 0.50), 0.32, 0.022)
    p.circle((0.50, 0.50), 0.255, 0.010)
    for k in range(2):
        p.line((0.40 + k * 0.075, 0.40), (0.36 + k * 0.075, 0.60), 0.014)
        p.line((0.38, 0.44 + k * 0.075), (0.62, 0.44 + k * 0.075), 0.014)


def g_PHOTOPHOBIA(p):
    """A flare burst with Scrubbers fleeing outward along its spokes. The
       creatures are drawn OUTSIDE the light, mid-retreat — the whole flare
       mechanic in one silhouette."""
    p.dot((0.50, 0.50), 0.055)
    p.circle((0.50, 0.50), 0.115, 0.014)
    for k in range(10):
        a = 2 * math.pi * k / 10
        p.line((0.50 + 0.145 * math.cos(a), 0.50 + 0.145 * math.sin(a)),
               (0.50 + 0.255 * math.cos(a), 0.50 + 0.255 * math.sin(a)), 0.013)
    for a in (0.5, 2.6, 4.2):
        m_scrubber(p, (0.50 + 0.355 * math.cos(a), 0.50 + 0.355 * math.sin(a)), 0.105)


def g_CLUTCH_RESTORE(p):
    """A downed crewmate under a decay arc with ONE segment left, and the
       restore channel closing on it. The nearly-empty arc is the entire
       drama; a full arc would be a different achievement."""
    m_figure(p, (0.46, 0.70), 0.31, "down", 0.024)
    # The decay ring: one heavy segment left, the rest spent (hairline).
    p.arc((0.50, 0.52), 0.37, 186, 232, 0.030)
    p.arc((0.50, 0.52), 0.37, 236, 540, 0.009)
    # The restore diving in against the clock.
    p.line((0.86, 0.16), (0.66, 0.38), 0.017)
    p.polyline([(0.62, 0.26), (0.63, 0.42), (0.79, 0.40)], 0.017)


def g_NO_BREATH(p):
    """Held Process: the Cycles gauge with a single sliver of charge, inside
       the exfil arrow. Shares the gauge with LIGHTS_OUT (which is at zero) —
       one sliver versus none is a readable difference at 64 px."""
    m_uplink(p, 0.50, 0.15, 0.91, 0.34)
    # A CLOSED gauge track with one sliver of charge left. An open 280-degree
    # arc inside the shaft rails read as an archway; a full ring cannot.
    p.circle((0.50, 0.56), 0.185, 0.012)
    p.arc((0.50, 0.56), 0.185, 130, 158, 0.028)
    p.ticks((0.50, 0.56), 0.150, 0.185, 6, 0.0, 2 * math.pi * 5 / 6, 0.009)
    p.dot((0.50, 0.56), 0.026)
    p.line((0.50, 0.56), (0.50 + 0.155 * math.cos(math.radians(158)),
                          0.56 + 0.155 * math.sin(math.radians(158))), 0.016)


def g_WELDER(p):
    """A vent cover with a weld bead run across its seam and spark ticks at
       the working end. The bead is drawn as a chain of overlapping beads,
       because a weld is a sequence of pool deposits, not a line."""
    m_vent(p, (0.50, 0.52), 0.28)
    for k in range(7):
        p.dot((0.26 + k * 0.080, 0.52 - 0.02 * math.sin(k)), 0.026)
    for a in (-0.5, -0.15, 0.25):
        p.line((0.78, 0.50), (0.78 + 0.11 * math.cos(a), 0.50 + 0.11 * math.sin(a)), 0.010)


def g_LOCKSMITH(p):
    """Quiet Entry: a cabinet whose lock is drawn INTACT (closed shackle),
       with a rewire jumper routed around it into the door edge. What matters
       is what was NOT cut, so the uncut lock is the hero of the frame."""
    # Cabinet on the left, its door line inboard of the edge.
    p.rect(0.10, 0.30, 0.52, 0.90, 0.017)
    p.line((0.44, 0.30), (0.44, 0.90), 0.010)
    # The lock hangs CLEAR of the cabinet on its own hasp, oversized and
    # closed. The achievement is about what you did not cut, so the uncut
    # shackle has to be the biggest single object in the frame.
    p.line((0.44, 0.60), (0.60, 0.60), 0.013)
    p.arc((0.68, 0.585), 0.085, 180, 360, 0.017)
    p.rect(0.595, 0.585, 0.765, 0.755, 0.018)
    p.dot((0.68, 0.665), 0.024)
    # The rewire jumper, routed over the top and into the panel instead.
    p.polyline([(0.68, 0.50), (0.68, 0.22), (0.30, 0.22), (0.30, 0.32)], 0.013)
    p.dot((0.68, 0.50), 0.019)
    p.dot((0.30, 0.33), 0.019)


def g_SLAMMED(p):
    """Access Denied: two bulkhead halves meeting on the centreline with a
       Scrubber caught at the seam, plus motion ticks showing the doors still
       travelling. The creature is bisected by the seam — the timing window is
       the picture."""
    p.line((0.08, 0.20), (0.08, 0.88), 0.016)
    p.line((0.92, 0.20), (0.92, 0.88), 0.016)
    p.line((0.06, 0.20), (0.38, 0.20), 0.013)
    p.line((0.62, 0.20), (0.94, 0.20), 0.013)
    p.line((0.06, 0.88), (0.38, 0.88), 0.013)
    p.line((0.62, 0.88), (0.94, 0.88), 0.013)
    p.box(0.12, 0.24, 0.34, 0.84)
    p.box(0.66, 0.24, 0.88, 0.84)
    for k in range(3):
        p.line((0.14, 0.34 + k * 0.20), (0.32, 0.34 + k * 0.20), 0.009, fill=0)
        p.line((0.68, 0.34 + k * 0.20), (0.86, 0.34 + k * 0.20), 0.009, fill=0)
    m_scrubber(p, (0.50, 0.56), 0.185)
    p.line((0.50, 0.18), (0.50, 0.90), 0.011)
    for k in range(3):
        p.line((0.06 + k * 0.026, 0.42 + k * 0.06), (0.13 + k * 0.026, 0.42 + k * 0.06), 0.011)
        p.line((0.94 - k * 0.026, 0.42 + k * 0.06), (0.87 - k * 0.026, 0.42 + k * 0.06), 0.011)


def g_KICKED_IT(p):
    """Who Did That: a tumbling debris canister with three expanding noise
       rings, and three process marks arriving at the outermost ring. The
       count of listeners is the achievement, so it is drawn as three distinct
       marks, not a crowd."""
    # The canister, tumbled onto its side (rotated box + end caps).
    p.polyline([(0.28, 0.72), (0.58, 0.80), (0.55, 0.92), (0.25, 0.84)], 0.016, True)
    p.line((0.31, 0.735), (0.28, 0.855), 0.010)
    p.line((0.52, 0.795), (0.49, 0.915), 0.010)
    for r in (0.26, 0.36, 0.46):
        p.arc((0.42, 0.82), r, 188, 352, 0.013)
    for (a, sz) in [(206, 0.075), (256, 0.082), (330, 0.075)]:
        ar = math.radians(a)
        m_scrubber(p, (0.42 + 0.56 * math.cos(ar), 0.82 + 0.56 * math.sin(ar)), sz)


def g_POWER_USER(p):
    """Load Balancer: one rewire junction feeding all three loads, each drawn
       as its OWN terminal shape — lamp (circle + rays), lock (shackle), fan
       (three blades). Three different silhouettes, so 'all three' is
       countable and identifiable without colour."""
    p.circle((0.50, 0.24), 0.075, 0.016)
    p.dot((0.50, 0.24), 0.026)
    for x in (0.22, 0.50, 0.78):
        p.line((0.50, 0.315), (x, 0.46), 0.013)
        p.line((x, 0.46), (x, 0.56), 0.013)
    p.circle((0.22, 0.68), 0.075, 0.014)
    for k in range(6):
        a = 2 * math.pi * k / 6
        p.line((0.22 + 0.095 * math.cos(a), 0.68 + 0.095 * math.sin(a)),
               (0.22 + 0.135 * math.cos(a), 0.68 + 0.135 * math.sin(a)), 0.010)
    p.arc((0.50, 0.665), 0.052, 180, 360, 0.013)
    p.rect(0.452, 0.665, 0.548, 0.755, 0.013)
    p.circle((0.78, 0.68), 0.030, 0.012)
    for k in range(3):
        a = 2 * math.pi * k / 3 + 0.4
        p.polyline([(0.78 + 0.030 * math.cos(a), 0.68 + 0.030 * math.sin(a)),
                    (0.78 + 0.125 * math.cos(a + 0.42), 0.68 + 0.125 * math.sin(a + 0.42)),
                    (0.78 + 0.115 * math.cos(a - 0.30), 0.68 + 0.115 * math.sin(a - 0.30))],
                   0.011, True)


def g_TYPIST(p):
    """Terminal Velocity: the console with a command line typed out as a
       dot-matrix run and a block caret at the end. Volume of queries is shown
       as three stacked command lines of decreasing length — a session, not a
       single command."""
    m_terminal(p, (0.50, 0.46), 0.30, caret=False)
    m_dotrow(p, 0.30, 0.62, 0.36, 8)
    m_dotrow(p, 0.30, 0.54, 0.46, 6)
    m_dotrow(p, 0.30, 0.46, 0.56, 4)
    p.box(0.52, 0.525, 0.60, 0.595)


def g_WARDRIVER(p):
    """Indexed: a full-height index of layer rows, every one ticked. Ten rows
       for a ten-layer run — the completeness of the column is the whole
       claim, and it stays legible when the ticks blur together at 64 px
       because the COLUMN is solid."""
    for k in range(10):
        y = 0.16 + k * 0.075
        p.line((0.30, y), (0.72, y), 0.011)
        p.polyline([(0.76, y - 0.008), (0.80, y + 0.018), (0.87, y - 0.030)], 0.012)
    p.line((0.24, 0.13), (0.24, 0.83), 0.014)


def g_LOOT_GOBLIN(p):
    """Defragmented: a scattered row of chips on the left being pulled into a
       contiguous solid block on the right. Literal defrag imagery, and the
       one glyph in the set with a left-to-right narrative."""
    for x in (0.16, 0.25, 0.38):
        m_chip(p, (x, 0.36), 0.058)
    for x in (0.20, 0.33, 0.44):
        m_chip(p, (x, 0.64), 0.058)
    p.line((0.50, 0.50), (0.60, 0.50), 0.016)
    p.polyline([(0.55, 0.45), (0.61, 0.50), (0.55, 0.55)], 0.016)
    for r in range(2):
        for c in range(3):
            m_chip(p, (0.68 + c * 0.105, 0.36 + r * 0.28), 0.058, filled=True)


def g_SPEEDRUN(p):
    """Hot Path: a room graph where exactly one route from arrival to the drop
       shaft is drawn heavy and straight, and every branch off it is thin and
       stubbed. Optimal play as a picture of everything skipped."""
    nodes = [(0.16, 0.78), (0.34, 0.60), (0.54, 0.46), (0.74, 0.28)]
    for a, b in zip(nodes, nodes[1:]):
        p.line(a, b, 0.020)
    for n in nodes:
        p.dot(n, 0.030)
    for (nx, ny), (dx, dy) in zip(nodes[:3], [(-0.02, -0.20), (0.20, 0.06), (-0.18, 0.16)]):
        p.dashes((nx, ny), (nx + dx, ny + dy), 3, 0.010)
        p.circle((nx + dx, ny + dy), 0.026, 0.010)
    m_shaft(p, (0.80, 0.20), 0.14, 2, 0.014)


def g_PACIFIST_DEEP(p):
    """Ghost Process: a crew silhouette drawn ENTIRELY in broken stroke,
       descending past depth ticks. Nothing it passed knows it was there. The
       dashed outline is the same 'absence' language as PACIFIST_PROTOCOL's
       flatline, applied to a body instead of a weapon."""
    c, s, w = (0.46, 0.50), 0.22, 0.016
    p.dashes((0.46, 0.28), (0.46, 0.32), 2, w)
    p.circle((0.46, 0.31), 0.055, 0.012)
    p.dashes((0.46, 0.37), (0.46, 0.60), 5, w)
    p.dashes((0.46, 0.44), (0.26, 0.55), 4, w * 0.85)
    p.dashes((0.46, 0.44), (0.66, 0.55), 4, w * 0.85)
    p.dashes((0.46, 0.60), (0.32, 0.84), 4, w * 0.85)
    p.dashes((0.46, 0.60), (0.60, 0.84), 4, w * 0.85)
    for k in range(5):
        p.line((0.84, 0.24 + k * 0.13), (0.90, 0.24 + k * 0.13), 0.012)
    p.line((0.87, 0.20), (0.87, 0.86), 0.010)


def g_HIGH_ROLLER(p):
    """Leverage: a Compiler arch with a big stack of data going in one side, a
       single module chip coming out the other, and a fulcrum under the beam.
       The lever makes the trade visible — you converted volume into one
       permanent thing."""
    # A tall column of spent data on one arm, one permanent module on the
    # other, over a fulcrum. Leverage as an actual lever.
    p.line((0.12, 0.66), (0.88, 0.50), 0.017)
    p.poly([(0.50, 0.58), (0.42, 0.86), (0.58, 0.86)])
    p.line((0.36, 0.86), (0.64, 0.86), 0.016)
    for k in range(6):
        m_chip(p, (0.19, 0.60 - k * 0.075), 0.052, filled=True)
    m_chip(p, (0.81, 0.40), 0.105)
    p.circle((0.81, 0.40), 0.042, 0.014)
    p.dot((0.81, 0.40), 0.016)


def g_WINDOW_SHOPPER(p):
    """Just Browsing: the Compiler frame with an empty output slot, a cursor
       hovering over nothing, and five open/close arc ticks around the edge.
       The empty slot is the punchline."""
    p.rect(0.22, 0.26, 0.78, 0.72, 0.016)
    for k in range(3):
        p.line((0.30, 0.36 + k * 0.10), (0.56, 0.36 + k * 0.10), 0.012)
    p.rect(0.62, 0.44, 0.72, 0.56, 0.012)
    p.polyline([(0.44, 0.60), (0.44, 0.76), (0.49, 0.71), (0.54, 0.78)], 0.013, True)
    for k in range(5):
        a = 200 + k * 28
        p.arc((0.50, 0.49), 0.36, a, a + 18, 0.014)


def g_PHOTOSENSITIVE(p):
    """Moth Math: an unbroken beam cone with a Moth riding it, and a toggle
       switch latched ON in the corner. The switch is the literal trigger
       condition (you never toggled the beam off) and the moth is the price."""
    m_beam(p, (0.20, 0.30), 0.62, 0.34, 0.62, 0.015, rays=3)
    p.dot((0.20, 0.30), 0.032)
    mc = (0.62, 0.60)
    p.poly([(mc[0], mc[1]), (mc[0] - 0.15, mc[1] - 0.13), (mc[0] - 0.17, mc[1] + 0.06)])
    p.poly([(mc[0], mc[1]), (mc[0] + 0.15, mc[1] - 0.13), (mc[0] + 0.17, mc[1] + 0.06)])
    p.line((mc[0], mc[1] - 0.07), (mc[0], mc[1] + 0.11), 0.014)
    p.rect(0.72, 0.14, 0.90, 0.32, 0.013)
    p.box(0.745, 0.165, 0.875, 0.235)


def g_NAMED_HER(p):
    """She Answers: a terminal caret with an aperture opening ABOVE it,
       looking back down. Query below, answer above — the reply comes from
       somewhere the console does not have."""
    m_terminal(p, (0.50, 0.70), 0.24, caret=True)
    p.circle((0.50, 0.30), 0.165, 0.016)
    p.dot((0.50, 0.30), 0.058)
    for k in range(8):
        a = 2 * math.pi * k / 8 + 0.2
        p.line((0.50 + 0.165 * math.cos(a), 0.30 + 0.165 * math.sin(a)),
               (0.50 + 0.075 * math.cos(a + 0.55), 0.30 + 0.075 * math.sin(a + 0.55)), 0.010)


def g_WRONG_DOOR(p):
    """Think Carefully: two doors — one sealed flush, one standing ajar with
       light in the gap — and nothing indicating which is which. The icon
       withholds the answer exactly as the egg does."""
    p.rect(0.12, 0.24, 0.44, 0.84, 0.016)
    p.dot((0.385, 0.56), 0.020)
    p.polyline([(0.56, 0.24), (0.88, 0.24), (0.88, 0.84), (0.56, 0.84)], 0.016)
    p.polyline([(0.56, 0.24), (0.66, 0.32), (0.66, 0.78), (0.56, 0.84)], 0.014)
    for k in range(4):
        p.line((0.665, 0.36 + k * 0.11), (0.74, 0.36 + k * 0.11), 0.009)
    p.dot((0.50, 0.14), 0.020)


def g_ARCHAEOLOGIST(p):
    """Shift Log: three torn Northcairn fragments stacked, with dot-matrix
       text and one corner index tab. The torn edge is drawn as a real jagged
       polyline — legacy human paper in a machine that has no paper."""
    for k, (ox, oy) in enumerate([(0.06, -0.06), (0.0, 0.0), (-0.06, 0.06)]):
        x0, y0 = 0.24 + ox, 0.22 + oy
        x1, y1 = 0.76 + ox, 0.74 + oy
        tear = [(x0, y0)]
        for j in range(7):
            tear.append((x0 + (x1 - x0) * (j + 1) / 7.0,
                         y1 - (0.030 if j % 2 else 0.0)))
        p.polyline([(x0, y1)] + tear[::-1] + [(x1, y0), (x0, y0)], 0.013, True)
        if k == 1:
            for j in range(3):
                m_dotrow(p, x0 + 0.06, x1 - 0.10 - j * 0.06, y0 + 0.13 + j * 0.11, 6 - j)
    p.poly([(0.70, 0.16), (0.82, 0.16), (0.82, 0.30)])


def g_THE_COAT(p):
    """Unclaimed Item: a coat on a hook, assembled from three pieces with the
       seams left visible. Three fragments, one object — the seams are the
       collection, and they are drawn as real breaks in the silhouette."""
    # Hook.
    p.arc((0.50, 0.14), 0.052, 200, 20, 0.013)
    p.line((0.50, 0.19), (0.50, 0.27), 0.013)
    # Collar and SHOULDERS — without a shoulder line a coat is a sack.
    p.polyline([(0.42, 0.31), (0.50, 0.26), (0.58, 0.31)], 0.015)
    p.line((0.42, 0.31), (0.20, 0.40), 0.017)
    p.line((0.58, 0.31), (0.80, 0.40), 0.017)
    # Sleeves.
    p.polyline([(0.20, 0.40), (0.14, 0.66), (0.26, 0.70)], 0.016)
    p.polyline([(0.80, 0.40), (0.86, 0.66), (0.74, 0.70)], 0.016)
    # Body, hem, and the centre placket.
    p.line((0.26, 0.44), (0.28, 0.88), 0.017)
    p.line((0.74, 0.44), (0.72, 0.88), 0.017)
    p.line((0.28, 0.88), (0.72, 0.88), 0.017)
    p.line((0.50, 0.31), (0.50, 0.88), 0.011)
    # The three fragment seams, left visible.
    p.dashes((0.26, 0.52), (0.74, 0.52), 7, 0.011)
    p.dashes((0.27, 0.70), (0.73, 0.70), 7, 0.011)


def g_UPWARD(p):
    """Let Nothing Pass: a doctrine wall plate carrying an upward arrow with a
       hard bar across the downward path — 'another door that only opens
       upward', straight from her own corpus. The bar is the doctrine."""
    p.rect(0.24, 0.16, 0.76, 0.84, 0.017)
    for (x, y) in [(0.30, 0.22), (0.70, 0.22), (0.30, 0.78), (0.70, 0.78)]:
        p.dot((x, y), 0.018)
    p.line((0.50, 0.70), (0.50, 0.34), 0.020)
    p.polyline([(0.38, 0.44), (0.50, 0.28), (0.62, 0.44)], 0.020)
    p.line((0.32, 0.62), (0.68, 0.62), 0.022)


def g_RELIEVED(p):
    """Relief Shift (reserved): a duty-roster row with the shift changing —
       a clock hand exactly at the changeover and an EMPTY post bracket
       beneath it. Deliberately the most withholding glyph in the set; the
       achievement's own text is reserved, so the icon says only 'someone is
       being relieved' and refuses to say of what."""
    p.circle((0.50, 0.38), 0.20, 0.016)
    p.line((0.50, 0.38), (0.50, 0.22), 0.016)
    p.line((0.50, 0.38), (0.63, 0.44), 0.013)
    p.ticks((0.50, 0.38), 0.165, 0.195, 12, 0.0, 2 * math.pi * 11 / 12, 0.009)
    m_bracket(p, 0.30, 0.66, 0.70, 0.88, 0.016, tab=0.055)
    p.dashes((0.34, 0.77), (0.66, 0.77), 5, 0.011)


def g_FULL_STACK(p):
    """Full Stack: the four player tags as a literal call stack — four frames
       pushed on top of each other in the exfil bracket. Same four shapes as
       NO_AGENT_LEFT, arranged as a stack rather than a perimeter. The two used
       to share a trigger as well as a cast, which was the catalog bug; the
       trigger split (this one is the layer-20+ version), the picture did not
       have to, because a stack of four frames is already the deep-crew read."""
    for k in range(4):
        y = 0.76 - k * 0.145
        p.rect(0.24, y - 0.058, 0.76, y + 0.058, 0.013)
        m_tag(p, (0.34, y), 0.042, k, 0.011, filled=True)
        m_dotrow(p, 0.46, 0.68, y, 4, 0.009)
    p.line((0.50, 0.19), (0.50, 0.08), 0.016)
    p.polyline([(0.42, 0.14), (0.50, 0.06), (0.58, 0.14)], 0.016)


def g_SHARED_BURDEN(p):
    """Load Bearing: a balance beam tipped by an unequal split — a tall stack
       on the carrying crew member's side, a short one opposite. The TILT is
       the information; the exact ratio is not something an icon can say, but
       'most of it was you' is."""
    # A yoke across one crew member's shoulders, loaded hard to one side.
    # The TILT carries it; no numerals, no percentages.
    m_figure(p, (0.50, 0.66), 0.21, "stand", 0.016)
    p.line((0.14, 0.36), (0.86, 0.50), 0.018)
    p.line((0.50, 0.43), (0.50, 0.52), 0.014)
    p.line((0.20, 0.375), (0.20, 0.44), 0.012)
    p.line((0.80, 0.49), (0.80, 0.55), 0.012)
    for k in range(5):
        m_chip(p, (0.20, 0.32 - k * 0.062), 0.050, filled=True)
    for k in range(2):
        m_chip(p, (0.80, 0.61 + k * 0.062), 0.050)


def g_MEDIC_MAIN(p):
    """Restore Point: a crewmate rising with the restore channel ring closing
       around them, and a tally column. Deliberately the INVERSE of
       CLUTCH_RESTORE's near-empty arc — this ring is complete, because the
       achievement is about volume, not about the last second."""
    m_figure(p, (0.46, 0.54), 0.22, "rise")
    p.arc((0.46, 0.52), 0.35, 0, 360, 0.014)
    p.arc((0.46, 0.52), 0.35, 210, 480, 0.024)
    for k in range(5):
        p.line((0.86, 0.30 + k * 0.085), (0.92, 0.30 + k * 0.085), 0.012)


def g_LIGHTHOUSE(p):
    """Lighthouse: a standing crewmate throwing a beam that sweeps a Scrubber
       off a second crewmate at the far edge. Three objects, one action — the
       only glyph in the set that shows a player helping a player, which is
       what the achievement is for."""
    m_figure(p, (0.18, 0.62), 0.17, "stand", 0.014)
    m_beam(p, (0.26, 0.52), -0.20, 0.30, 0.52, 0.013, rays=2)
    m_figure(p, (0.80, 0.56), 0.15, "stand", 0.013)
    m_scrubber(p, (0.66, 0.30), 0.135)
    for k in range(3):
        p.line((0.60 - k * 0.030, 0.18 + k * 0.022), (0.66 - k * 0.030, 0.18 + k * 0.022), 0.010)


GLYPHS = {name[2:]: fn for name, fn in list(globals().items()) if name.startswith("g_")}


# ===========================================================================
# 4. CATALOG — parsed from DESIGN.md
# ===========================================================================

#: DESIGN.md section heading -> category key. The v2 catalog's sub-headings are
#: plain prose lines above each table, so they are matched by keyword.
SECTION_KEYS = [
    ("Progression:", "progression"),
    ("Combat & survival:", "combat"),
    ("The world fights back", "world"),
    ("Greed & style:", "greed"),
    ("Hidden / lore", "hidden"),
    ("Co-op ", "coop"),
]


def load_catalog() -> list[tuple[str, str, str, str]]:
    """Return [(id, name, trigger, category)] for every achievement in
       DESIGN.md — the v1 wired table plus the v2 catalog."""
    with open(DESIGN, "r", encoding="utf-8") as fh:
        text = fh.read()
    start = text.index("### Achievement list (v1")
    end = text.index("## Tech Stack")
    body = text[start:end]

    out: list[tuple[str, str, str, str]] = []
    seen: set[str] = set()
    # v1 has no sub-headings; everything before the v2 header is "progression"
    # for tint purposes only (its members span every theme, and the tint is
    # garnish — the shapes carry the meaning).
    current = "progression"
    for line in body.splitlines():
        for marker, key in SECTION_KEYS:
            if line.startswith(marker):
                current = key
        m = re.match(r"^\|\s*`([A-Z0-9_]+)`\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$", line)
        if not m:
            continue
        aid, name, trigger = m.group(1), m.group(2), m.group(3)
        if aid in seen:
            continue
        seen.add(aid)
        out.append((aid, name, trigger, current))
    return out


# ===========================================================================
# 5. RENDER — phosphor ground, glow, scanlines, fringe
# ===========================================================================

def _ground(tint, locked: bool) -> np.ndarray:
    """The unexcited tube: near-black, a faint plate grid, and a vignette."""
    y, x = np.mgrid[0:SIZE, 0:SIZE].astype(np.float64)
    cx = (x - SIZE / 2) / (SIZE / 2)
    cy = (y - SIZE / 2) / (SIZE / 2)
    r = np.sqrt(cx ** 2 + cy ** 2)
    base = np.clip(0.055 - 0.030 * r ** 1.6, 0.0, 1.0)
    grid = (((x.astype(int) % 32) < 1) | ((y.astype(int) % 32) < 1)).astype(np.float64)
    base = base + grid * 0.016
    col = np.array(tint, dtype=np.float64) / 255.0
    if locked:
        col = np.array([0.62, 0.66, 0.72])
        base *= 0.72
    return base[..., None] * (0.30 + 0.70 * col)[None, None, :]


def _scanlines(img: np.ndarray, locked: bool) -> np.ndarray:
    """Aperture-grille scanlines plus one slow bright band. Applied over the
       whole face — the glyph is on the tube, not floating above it."""
    y = np.arange(SIZE)[:, None, None]
    lines = 1.0 - 0.20 * (y % 3 == 0)
    band = 1.0 + 0.045 * np.sin(2.0 * math.pi * y / SIZE + 0.6)
    out = img * lines * band
    if not locked:
        # A hair of phosphor persistence: each row leaks a little into the one
        # below, which is what makes a CRT look like a CRT in a still frame.
        out[1:] = np.maximum(out[1:], out[:-1] * 0.16)
    return out


def _fringe(layer: np.ndarray, amount: float = 1.0) -> np.ndarray:
    """Chromatic fringe from a misconverged tube: R lags, B leads, by one
       pixel. Applied to the GLYPH layer only — fringing the ground too would
       just look like a broken export.

       `amount` is halved for locked icons: with no bloom to sit under, a full
       one-pixel split stops reading as tube convergence and starts reading as
       a bad export, and it is the first thing the eye lands on."""
    out = layer.copy()
    out[:, 1:, 0] = layer[:, 1:, 0] * (1.0 - amount) + layer[:, :-1, 0] * amount
    out[:, :-1, 2] = layer[:, :-1, 2] * (1.0 - amount) + layer[:, 1:, 2] * amount
    return out


def render(aid: str, tint, locked: bool) -> Image.Image:
    pen = Pen()
    GLYPHS[aid](pen)

    mask = pen.img.resize((SIZE, SIZE), Image.LANCZOS)
    m = np.asarray(mask, dtype=np.float64) / 255.0

    # Three-radius bloom. One radius gives a drop shadow; three gives the
    # tight core + soft halo + wide wash that phosphor actually has.
    glow = np.zeros_like(m)
    for radius, weight in ((1.6, 0.55), (4.5, 0.34), (12.0, 0.22)):
        blur = np.asarray(mask.filter(ImageFilter.GaussianBlur(radius)),
                          dtype=np.float64) / 255.0
        glow += blur * weight

    col = np.array(tint, dtype=np.float64) / 255.0
    if locked:
        # Locked = unexcited phosphor. Desaturated toward a cold grey, dimmed
        # hard, and NO bloom — the shape is still fully readable (a player
        # should be able to see what they are missing) but the tube is off.
        lum = float(np.dot(col, [0.299, 0.587, 0.114]))
        col = np.array([lum, lum, lum]) * 0.92 + np.array([0.05, 0.06, 0.09])
        layer = m[..., None] * col[None, None, :] * 0.42 \
            + glow[..., None] * col[None, None, :] * 0.05
        # A faint etched highlight along the top of every stroke so the glyph
        # reads as engraved rather than as a low-quality copy.
        edge = np.asarray(mask.filter(ImageFilter.FIND_EDGES), dtype=np.float64) / 255.0
        layer += edge[..., None] * np.array([0.20, 0.22, 0.26])[None, None, :]
    else:
        core = np.clip(m * 1.0, 0.0, 1.0)
        layer = core[..., None] * (col * 0.55 + 0.45)[None, None, :] \
            + glow[..., None] * col[None, None, :] * 0.85

    layer = _fringe(layer, 0.35 if locked else 1.0)
    img = _ground(tint, locked) + layer
    img = _scanlines(img, locked)

    # Tube noise. Tiny, and the locked plate gets more of it — a dead channel
    # is noisier than a live one.
    # crc32, not hash(): CPython randomises str hashing per process (PEP 456)
    # unless PYTHONHASHSEED is pinned, so `hash(aid)` re-grained all 100 icons on
    # every run. That made a 100-file binary diff the normal outcome of a rebuild,
    # which is exactly the noise a drift detector must not generate — you stop
    # reading a diff that is always red. crc32 is stable across processes and
    # machines, so a rebuild that changes nothing now writes nothing.
    rng = np.random.default_rng(zlib.crc32(aid.encode("utf-8")))
    img += rng.normal(0.0, 0.012 if locked else 0.007, img.shape)

    # Bezel: corner ticks and a hairline inner frame, matching the HUD's
    # instrument bracket language.
    frame = Image.new("L", (SIZE, SIZE), 0)
    fd = ImageDraw.Draw(frame)
    fd.rectangle([6, 6, SIZE - 7, SIZE - 7], outline=255, width=1)
    for (x0, y0, x1, y1) in [(6, 6, 26, 6), (6, 6, 6, 26),
                             (SIZE - 27, 6, SIZE - 7, 6), (SIZE - 7, 6, SIZE - 7, 26),
                             (6, SIZE - 7, 26, SIZE - 7), (6, SIZE - 27, 6, SIZE - 7),
                             (SIZE - 27, SIZE - 7, SIZE - 7, SIZE - 7),
                             (SIZE - 7, SIZE - 27, SIZE - 7, SIZE - 7)]:
        fd.line([x0, y0, x1, y1], fill=255, width=3)
    f = np.asarray(frame, dtype=np.float64) / 255.0
    fc = np.array(tint) / 255.0 * (0.16 if locked else 0.42)
    img += f[..., None] * fc[None, None, :]

    return Image.fromarray((np.clip(img, 0.0, 1.0) * 255).astype(np.uint8))


# ===========================================================================
# 6. CONTACT SHEETS
# ===========================================================================

def sheet(entries, images, path, cell, cols, label=True, grey=False, title=""):
    pad, lab = 10, (14 if label else 0)
    rows = (len(entries) + cols - 1) // cols
    W = cols * (cell + pad) + pad
    H = rows * (cell + pad + lab) + pad + 26
    out = Image.new("RGB", (W, H), (9, 8, 7))
    d = ImageDraw.Draw(out)
    d.text((pad, 8), title, fill=(255, 184, 70))
    for i, (aid, name, trig, cat) in enumerate(entries):
        r, c = divmod(i, cols)
        x = pad + c * (cell + pad)
        y = 26 + pad + r * (cell + pad + lab)
        im = images[aid].resize((cell, cell), Image.LANCZOS)
        if grey:
            im = im.convert("L").convert("RGB")
        out.paste(im, (x, y))
        if label:
            d.text((x, y + cell + 2), aid[:22], fill=(150, 118, 60))
    out.save(path)
    print("[sheet] %s" % path)


def main() -> int:
    ap = argparse.ArgumentParser(description="Steam achievement icons")
    ap.add_argument("--out", default=OUT_DIR)
    ap.add_argument("--only", default="")
    ap.add_argument("--sheets", default="")
    ap.add_argument("--rationale", action="store_true",
                    help="print the per-glyph design rationale and exit")
    args = ap.parse_args()

    catalog = load_catalog()
    ids = {a for a, _, _, _ in catalog}

    missing = sorted(ids - set(GLYPHS))
    extra = sorted(set(GLYPHS) - ids)
    if missing:
        print("ERROR: DESIGN.md lists achievements with no glyph: %s" % ", ".join(missing))
        return 1
    if extra:
        print("ERROR: glyphs exist for achievements not in DESIGN.md: %s" % ", ".join(extra))
        return 1
    print("[catalog] %d achievements, %d glyphs, fully matched" % (len(catalog), len(GLYPHS)))

    if args.rationale:
        for aid, name, trig, cat in catalog:
            doc = " ".join((GLYPHS[aid].__doc__ or "").split())
            print("\n%-20s %-24s [%s]\n    trigger:  %s\n    glyph:    %s"
                  % (aid, name, cat, trig, doc))
        return 0

    os.makedirs(args.out, exist_ok=True)
    unlocked: dict[str, Image.Image] = {}
    locked: dict[str, Image.Image] = {}
    shown = []
    for aid, name, trig, cat in catalog:
        if args.only and args.only not in aid:
            continue
        tint = TINTS[cat]
        u = render(aid, tint, False)
        l = render(aid, tint, True)
        u.save(os.path.join(args.out, "%s.png" % aid.lower()))
        l.save(os.path.join(args.out, "%s_locked.png" % aid.lower()))
        unlocked[aid], locked[aid] = u, l
        shown.append((aid, name, trig, cat))
        print("[icon] %-22s %-26s [%s]" % (aid.lower(), name, cat))

    if args.sheets and shown:
        os.makedirs(args.sheets, exist_ok=True)
        sheet(shown, unlocked, os.path.join(args.sheets, "achievements_unlocked.png"),
              128, 8, title="BANISH PROTOCOL — achievement icons, UNLOCKED (shown at 128 px)")
        sheet(shown, locked, os.path.join(args.sheets, "achievements_locked.png"),
              128, 8, title="BANISH PROTOCOL — achievement icons, LOCKED (shown at 128 px)")
        sheet(shown, unlocked, os.path.join(args.sheets, "achievements_64px.png"),
              64, 10, label=False,
              title="Legibility check — actual 64 px, no labels")
        sheet(shown, unlocked, os.path.join(args.sheets, "achievements_64px_grey.png"),
              64, 10, label=False, grey=True,
              title="Colour-independence check — 64 px, greyscale (shape must carry it all)")

    print("\n%d icons (x2 states) -> %s" % (len(shown), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
