#!/usr/bin/env python3
"""LIMBO PROTOCOL trim sheet — high-poly built and baked down in Blender 5.2.

Run:  blender --factory-startup --background --python tools/bake_trimsheet.py

Output: assets/trim/trimsheet_{normal,ao,height,curvature}.png at 2048 x 2048.

What this is
------------
Eight horizontal bands stacked in V, each one 2048 x 256 px, each tiling
seamlessly left to right. A wall module UVs a face into one band and gets a
real machined surface out of it for nothing — the alternative is spending
triangles on detail that is 3 px tall on screen.

    band  V range (Godot)   content
      0   0.000 - 0.125     flat panel, fine brushed grain
      1   0.125 - 0.250     recessed panel gap / shadow-line channel
      2   0.250 - 0.375     bolted seam strip, hex sockets
      3   0.375 - 0.500     louvre / vent slot run
      4   0.500 - 0.625     raised rib with chamfers
      5   0.625 - 0.750     cable-conduit half-round with clamps
      6   0.750 - 0.875     hazard chevron relief
      7   0.875 - 1.000     fine perforated hex grille

V is quoted in **Godot** convention, where v = 0 is the top row of the image.
Blender's own V runs the other way, which is exactly why the bands are laid out
top-down in the scene: band N is modelled at world Y in [7-N, 8-N] so that after
the flip it lands on image rows [256N, 256N+256). Get that backwards once and
every UV offset in the material set is wrong by 1 - v.

Why the scene is 8 x 8 world units
----------------------------------
1 unit = 256 px, so a band is exactly 8 x 1 units and the pixel budget is
readable straight off the model: a 0.02 unit chamfer is 5 px, which is the
smallest feature that survives a mip. Every band is authored as a repeating unit
whose width divides 8 exactly, so the U seam is not a special case that has to
be blended afterwards — the geometry is genuinely periodic across it.

Why bands are separate objects
------------------------------
The AO pass uses an Ambient Occlusion shader node with `only_local` set, which
restricts occlusion to the object being shaded. One object per band therefore
means band 4's rib cannot darken band 3's louvres, and the AO distance can be
generous without the bands bleeding into each other. The low-poly target is a
single continuous plane covering the whole 0..1 UV square — one island, so the
bake margin never has to dilate across a band boundary.
"""

import math
import os
import sys

import bmesh
import bpy
import numpy as np
from PIL import Image
from mathutils import Matrix, Vector

# ---------------------------------------------------------------- constants --

# assets/trim/ is this script's own output directory and holds nothing else.
# assets/pbr/ belongs to make_pbr.py and is never read, written, globbed or
# cleared from here. Nothing in this file removes a file or a directory either:
# outputs are overwritten by name, because a build script that clears its output
# directory is a build script that will one day clear the wrong one.
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "trim")
OUT = os.path.normpath(OUT)

SIZE = 2048
BANDS = 8
BAND_PX = SIZE // BANDS          # 256
SHEET_W = 8.0                    # world units across U -> 256 px per unit
BAND_H = 1.0                     # world units per band

CHAMFER = 0.020                  # ~5 px. Below this a chamfer is gone by mip 1.
BEVEL_MIN_ANGLE = 0.30           # rad, same test build_kit.py uses

# Every band's geometry runs past the edge of the sheet instead of stopping on
# it. Geometry that ends exactly at x = +-4 presents its end cap to the outermost
# column of texels, and the bake ray catches that wall instead of the top face —
# which put a 181-level discontinuity into the first and last column of five of
# the eight bands, the one place a tiling texture cannot afford one. The overhang
# is 12 grid cells / 1.5 louvre units / 0.75 bolt pitches, so every repeating
# lattice in the file stays in phase across it.
OVER = 0.375
X0, X1 = -SHEET_W * 0.5 - OVER, SHEET_W * 0.5 + OVER

# Bake ray budget. The cage is pushed 0.30 out along the flat plane's normal and
# the ray is allowed 0.62, so it starts above the tallest relief (+0.098) and
# still reaches the deepest recess (-0.25) without punching through to the far
# side of anything.
CAGE = 0.30
RAY = 0.62
MARGIN = 16

AO_DISTANCE = 0.35               # ~90 px. Long enough to shade a channel, short
                                 # enough that a band never goes globally grey.
AO_SAMPLES = 16
SAMPLES = {"NORMAL": 8, "AO": 12, "HEIGHT": 4}

Z_LO, Z_HI = -0.14, 0.10         # remapped to 0..1 in the height pass


# ------------------------------------------------------------------ 1D noise --

def _hash(i, seed):
    n = (i * 374761393 + seed * 668265263) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0 * 2.0 - 1.0


def _vnoise(t, seed):
    """Value noise on a line, smoothstep interpolated. Used only across the
    brush direction, where the sheet does not have to tile."""
    i = math.floor(t)
    f = t - i
    f = f * f * (3.0 - 2.0 * f)
    return _hash(int(i), seed) * (1.0 - f) + _hash(int(i) + 1, seed) * f


# ------------------------------------------------------------------ builder --

class Band:
    """A high-poly strip. Local `ly` is 0..1 across the band's height; because
    BAND_H is 1.0 those are also world units, which keeps the numbers below
    readable as both 'fraction of the band' and 'metres of relief'."""

    def __init__(self, index, name):
        self.index = index
        self.name = name
        self.bm = bmesh.new()
        self.y0 = (BANDS - 1 - index) * BAND_H
        self.smooth = set()

    # -- primitives ----------------------------------------------------------

    def box(self, x0, x1, ly0, ly1, z0, z1):
        ret = bmesh.ops.create_cube(self.bm, size=1.0)
        verts = ret["verts"]
        bmesh.ops.scale(self.bm, vec=Vector((x1 - x0, ly1 - ly0, z1 - z0)), verts=verts)
        bmesh.ops.translate(self.bm, vec=Vector(
            ((x0 + x1) * 0.5, self.y0 + (ly0 + ly1) * 0.5, (z0 + z1) * 0.5)), verts=verts)
        faces = {f for v in verts for f in v.link_faces}
        for f in faces:
            f.smooth = False
        return list(faces)

    def rot_box(self, x0, x1, ly0, ly1, z0, z1, angle_deg, axis):
        faces = self.box(x0, x1, ly0, ly1, z0, z1)
        c = Vector(((x0 + x1) * 0.5, self.y0 + (ly0 + ly1) * 0.5, (z0 + z1) * 0.5))
        m = (Matrix.Translation(c)
             @ Matrix.Rotation(math.radians(angle_deg), 4, axis.upper())
             @ Matrix.Translation(-c))
        bmesh.ops.transform(self.bm, matrix=m, verts=list({v for f in faces for v in f.verts}))
        return faces

    def prism(self, poly, z0, z1):
        """Closed solid from a polygon given as [(x, ly), ...] in band space."""
        bm = self.bm
        lo = [bm.verts.new((x, self.y0 + y, z0)) for x, y in poly]
        hi = [bm.verts.new((x, self.y0 + y, z1)) for x, y in poly]
        faces = [bm.faces.new(lo), bm.faces.new(list(reversed(hi)))]
        n = len(poly)
        for k in range(n):
            k2 = (k + 1) % n
            faces.append(bm.faces.new((lo[k], lo[k2], hi[k2], hi[k])))
        for f in faces:
            f.smooth = False
        return faces

    def xprism(self, poly, x0, x1, smooth_edges=()):
        """Closed solid from a polygon given as [(ly, z), ...], extruded along X.
        `smooth_edges` names the polygon edge indices that belong to a curve, so
        the round parts shade round and stay out of the bevel pass."""
        bm = self.bm
        a = [bm.verts.new((x0, self.y0 + y, z)) for y, z in poly]
        b = [bm.verts.new((x1, self.y0 + y, z)) for y, z in poly]
        caps = [bm.faces.new(a), bm.faces.new(list(reversed(b)))]
        faces = list(caps)
        n = len(poly)
        for k in range(n):
            k2 = (k + 1) % n
            f = bm.faces.new((a[k], a[k2], b[k2], b[k]))
            if k in smooth_edges:
                f.smooth = True
                self.smooth.add(f)
            else:
                f.smooth = False
            faces.append(f)
        for f in caps:
            f.smooth = False
        return faces

    def hex_cup(self, cx, cly, r_out, r_in, z_base, z_socket, z_top, phase=0.0):
        """A hex bolt head with a hex socket sunk into it, as a closed solid.

        Modelled rather than boolean'd for the same reason build_kit.py never
        booleans: the socket is a ring of quads between two hexagons, which is
        30 faces of known topology instead of an n-gon cleanup pass."""
        bm = self.bm

        def ring(r, z):
            return [bm.verts.new((cx + r * math.cos(phase + math.tau * k / 6),
                                  self.y0 + cly + r * math.sin(phase + math.tau * k / 6),
                                  z)) for k in range(6)]

        ob, ot = ring(r_out, z_base), ring(r_out, z_top)
        it, ib = ring(r_in, z_top), ring(r_in, z_socket)
        faces = [bm.faces.new(ob), bm.faces.new(ib)]
        for lo, hi in ((ob, ot), (ot, it), (it, ib)):
            for k in range(6):
                k2 = (k + 1) % 6
                faces.append(bm.faces.new((lo[k], lo[k2], hi[k2], hi[k])))
        for f in faces:
            f.smooth = False
        return faces

    def grid(self, nx, ny, fn, over=0):
        """Displaced open sheet. The only piece in the file that is not a closed
        solid, so its winding is checked and corrected explicitly rather than
        handed to recalc_face_normals, whose inside/outside heuristic has nothing
        to work with on an open surface.

        The overhang is counted in whole cells, not world units: the tessellation
        itself is a pattern, and a grid whose vertex spacing does not divide the
        sheet width an exact number of times will not tile however periodic the
        displacement function is."""
        bm = self.bm
        step = SHEET_W / nx
        rows = []
        for j in range(ny + 1):
            ly = j / ny
            row = []
            for i in range(-over, nx + over + 1):
                x = -SHEET_W * 0.5 + step * i
                row.append(bm.verts.new((x, self.y0 + ly, fn(x, ly))))
            rows.append(row)
        faces = []
        nx += 2 * over
        for j in range(ny):
            for i in range(nx):
                faces.append(bm.faces.new((rows[j][i], rows[j][i + 1],
                                           rows[j + 1][i + 1], rows[j + 1][i])))
        bm.normal_update()
        if sum(f.normal.z for f in faces) < 0:
            bmesh.ops.reverse_faces(bm, faces=faces)
        for f in faces:
            f.smooth = True
            self.smooth.add(f)
        return faces

    # -- finish --------------------------------------------------------------

    def _on_band_edge(self, e):
        """True for an edge lying exactly on the band's top or bottom boundary.

        Those must not be chamfered. A band boundary is not a physical arris —
        it is where one 256 px strip of the sheet stops and the next begins — and
        chamfering it stamps a 5 px bevel highlight along the top and bottom of
        every band, which shows up as a false seam the moment a UV shell is
        placed near a band edge or a band is tiled against itself."""
        y0, y1 = self.y0, self.y0 + BAND_H
        return (all(abs(v.co.y - y0) < 1e-4 for v in e.verts)
                or all(abs(v.co.y - y1) < 1e-4 for v in e.verts))

    def finish(self, bevel=True, recalc=True):
        bm = self.bm
        if recalc:
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        if bevel:
            edges = [e for e in bm.edges
                     if len(e.link_faces) == 2
                     and e.link_faces[0] not in self.smooth
                     and e.link_faces[1] not in self.smooth
                     and not self._on_band_edge(e)
                     and e.calc_face_angle(0.0) > BEVEL_MIN_ANGLE]
            if edges:
                bmesh.ops.bevel(bm, geom=edges, offset=CHAMFER, offset_type="OFFSET",
                                segments=1, profile=0.5, affect="EDGES",
                                clamp_overlap=True, loop_slide=True)
        mesh = bpy.data.meshes.new(self.name)
        bm.to_mesh(mesh)
        bm.free()
        obj = bpy.data.objects.new(self.name, mesh)
        bpy.context.collection.objects.link(obj)
        return obj, sum(len(p.vertices) - 2 for p in mesh.polygons)


def arc(cy, r, z0, a0, a1, steps):
    """Points on a circle in the (ly, z) plane, for xprism cross-sections."""
    return [(cy + r * math.cos(a0 + (a1 - a0) * k / steps),
             z0 + r * math.sin(a0 + (a1 - a0) * k / steps)) for k in range(steps + 1)]


# -------------------------------------------------------------------- bands --

def band0_brushed():
    """Flat panel. Everything here is under 1.5 mm of relief on purpose: this is
    the band a wall spends most of its area in, and its whole job is to not be
    perfectly flat. A dead-flat albedo panel under a moving light reads as a
    render error; the same panel with a directional grain reads as rolled steel.

    The grain runs along U so a wall UV'd with U horizontal gets horizontal
    brushing, which is how sheet stock actually comes off the mill."""
    b = Band(0, "BAND0_BRUSHED")

    def z(x, ly):
        # Macro: the panel is not flat because no 2 m panel ever is. Periodic in
        # x at whole cycles per sheet so it survives the seam.
        macro = 0.0045 * (0.6 * math.sin(math.tau * x / SHEET_W + 0.7)
                          + 0.4 * math.sin(2 * math.tau * x / SHEET_W + 2.1))
        macro *= 0.55 + 0.45 * math.sin(math.pi * ly)
        # Grain: high frequency across the brush direction, modulated along it.
        g = _vnoise(ly * 70.0, 11) * 0.62 + _vnoise(ly * 150.0, 23) * 0.38
        m = (0.5 * math.sin(3 * math.tau * x / SHEET_W + 1.7)
             + 0.3 * math.sin(7 * math.tau * x / SHEET_W + 0.4)
             + 0.2 * math.sin(13 * math.tau * x / SHEET_W + 2.9))
        return macro + 0.0011 * g * (0.75 + 0.25 * m)

    b.grid(256, 256, z, over=12)     # 12 cells = OVER, keeps the lattice in phase
    return b.finish(bevel=False, recalc=False)


def band1_channel():
    """Recessed panel gap. Two steps down rather than one: a single square groove
    bakes as two black lines and nothing in between, while a stepped reveal gives
    the normal map four separate chamfer highlights at four different depths,
    which is what makes a 24 px channel read as 40 mm of real steel."""
    b = Band(1, "BAND1_CHANNEL")
    b.box(X0, X1, 0.00, 1.00, -0.25, -0.085)     # body / channel floor
    b.box(X0, X1, 0.60, 1.00, -0.25, 0.0)        # upper land
    b.box(X0, X1, 0.00, 0.40, -0.25, 0.0)        # lower land
    b.box(X0, X1, 0.56, 0.60, -0.25, -0.035)     # upper step
    b.box(X0, X1, 0.40, 0.44, -0.25, -0.035)     # lower step
    return b.finish()


def band2_bolted():
    """Bolted seam strip. Bolt pitch is 0.5 units = 128 px = 16 across the sheet,
    so a wall can crop this band at any 1/16 and still land between fasteners."""
    b = Band(2, "BAND2_BOLTED")
    b.box(X0, X1, 0.00, 1.00, -0.25, 0.0)        # land
    b.box(X0, X1, 0.28, 0.72, -0.25, 0.022)      # strap
    for a, c in ((0.280, 0.315), (0.685, 0.720)):
        b.box(X0, X1, a, c, -0.25, 0.038)        # strap edge lips
    # Big bolts sit mid-pitch and never touch the seam. The small nuts are offset
    # half a pitch, which lands one of them exactly on x = +-4 — so the loop runs
    # to 16 inclusive and puts a matching half nut on both edges. Generating only
    # 16 leaves a nut on the right edge with nothing to meet it on the left.
    for k in range(16):
        x = -3.75 + k * 0.5
        # Socket floor sits 30 mm below the head so the hex hole self-shadows
        # instead of baking as a flat hexagon of the same grey as the head.
        b.hex_cup(x, 0.50, 0.105, 0.052, 0.022, 0.050, 0.080, phase=math.radians(30))
    for k in range(17):
        x = -4.0 + k * 0.5
        b.hex_cup(x, 0.135, 0.034, 0.020, 0.0, 0.014, 0.020)
        b.hex_cup(x, 0.865, 0.034, 0.020, 0.0, 0.014, 0.020)
    return b.finish()


def band3_louvre():
    """Louvre run: 32 vertical slots on a 0.25 unit pitch, each with a blade
    raked 35 degrees inside it. The blade is the reason to model this rather than
    paint it — without it a slot bakes as a black rectangle, and with it the slot
    has one lit face and one dark one and reads as air moving through."""
    b = Band(3, "BAND3_LOUVRE")
    b.box(X0, X1, 0.00, 1.00, -0.30, -0.10)      # plenum floor
    b.box(X0, X1, 0.82, 1.00, -0.30, 0.0)        # top rail
    b.box(X0, X1, 0.00, 0.18, -0.30, 0.0)        # bottom rail
    # Mullion on every unit boundary including both seams, and two units of
    # overhang each side so the slot lattice runs off the sheet in phase.
    for k in range(-2, 35):
        xb = -4.0 + k * 0.25
        b.box(xb - 0.0475, xb + 0.0475, 0, 1, -0.30, 0.0)
    for k in range(-2, 34):
        xc = -3.875 + k * 0.25
        b.rot_box(xc - 0.065, xc + 0.065, 0.22, 0.78, -0.064, -0.040, 35.0, "y")
    return b.finish()


def band4_rib():
    """Raised rib. Split down the middle by a shallow groove so the rib crown has
    its own pair of chamfers, and crossed every 1.0 unit by a stiffener strap —
    the strap is what stops the band from being translation-invariant, which is
    what makes a long run of it stop looking like an extrusion."""
    b = Band(4, "BAND4_RIB")
    b.box(X0, X1, 0.00, 1.00, -0.25, 0.0)
    b.box(X0, X1, 0.36, 0.47, -0.25, 0.075)
    b.box(X0, X1, 0.53, 0.64, -0.25, 0.075)
    b.box(X0, X1, 0.47, 0.53, -0.25, 0.042)      # groove floor
    b.box(X0, X1, 0.16, 0.20, -0.25, 0.022)      # micro ribs, top and bottom
    b.box(X0, X1, 0.80, 0.84, -0.25, 0.022)
    for k in range(8):
        c = -3.5 + k * 1.0
        b.box(c - 0.06, c + 0.06, 0.22, 0.78, -0.25, 0.098)
    return b.finish()


def band5_conduit():
    """Half-round conduit with clamps. The half round is 14 segments over 180
    degrees and smooth shaded, so it bakes as a genuine cylindrical gradient
    rather than 14 flat facets — a faceted pipe in a normal map is the single
    most obvious tell that a sheet was baked from a low-poly source."""
    b = Band(5, "BAND5_CONDUIT")
    b.box(X0, X1, 0.00, 1.00, -0.25, 0.0)

    big, small = 0.135, 0.062
    for cy, r in ((0.55, big), (0.20, small)):
        poly = arc(cy, r, 0.0, 0.0, math.pi, 14) + [(cy - r, -0.02), (cy + r, -0.02)]
        b.xprism(poly, X0, X1, smooth_edges=range(14))

    for k in range(8):
        c = -3.5 + k * 1.0
        strap = (arc(0.55, 0.168, 0.0, 0.0, math.pi, 14)
                 + list(reversed(arc(0.55, big, 0.0, 0.0, math.pi, 14))))
        b.xprism(strap, c - 0.038, c + 0.038,
                 smooth_edges=list(range(14)) + list(range(15, 29)))
        for s in (-1, 1):
            b.box(c - 0.055, c + 0.055, 0.55 + s * 0.19, 0.55 + s * 0.125, -0.25, 0.030)
    return b.finish()


def band6_chevron():
    """Hazard chevrons, embossed rather than painted.

    45 degrees exactly, on a 0.5 unit pitch — 16 across the sheet, so the family
    of bars x - y = c maps onto itself under a shift of 8 and the seam needs no
    special case. Bars are generated well past both edges and simply overhang;
    the low-poly plane stops at +-4, so the overhang costs nothing and guarantees
    the pattern at u = 0 is the same pattern as at u = 1."""
    b = Band(6, "BAND6_CHEVRON")
    b.box(X0, X1, 0.00, 1.00, -0.25, -0.032)     # recessed field
    b.box(X0, X1, 0.00, 0.10, -0.25, 0.0)        # frame rails
    b.box(X0, X1, 0.90, 1.00, -0.25, 0.0)
    w, rise = 0.25, 0.80
    for k in range(21):
        c = -5.5 + k * 0.5
        b.prism([(c, 0.10), (c + w, 0.10), (c + w + rise, 0.90), (c + rise, 0.90)],
                -0.25, -0.002)
    return b.finish()


def band7_grille():
    """Perforated hex grille inside a frame.

    96 cells across: the pitch divides 8 exactly and 96 is even, so the half-cell
    offset on alternate rows also maps onto itself across the seam. Get either of
    those wrong and the honeycomb tiles with a visible jog every 2048 px.

    The frame is not decoration. A honeycomb cannot end cleanly on a straight
    line — its boundary is a zigzag — so the rows are clipped to whole cells and
    the leftover is covered by rails. Without them the outermost cells would spill
    past the band into its neighbour's 256 px, which on a shared UV sheet means
    band 6 grows a row of holes it never asked for.

    Each cell is a closed hexagonal annulus: land, chamfered mouth, bore, and a
    wall back down to the plenum. Solid rather than an open shell so
    recalc_face_normals has a volume to reason about."""
    b = Band(7, "BAND7_GRILLE")
    pitch = SHEET_W / 96.0
    R = pitch / math.sqrt(3.0)                  # circumradius of a pointy-top hex
    r1, rc = 0.60 * R, 0.52 * R
    row_h = 1.5 * R
    rail, floor_z = 0.085, -0.085

    b.box(X0, X1, 0.00, 1.00, -0.25, floor_z)    # plenum behind the perforations
    b.box(X0, X1, 0.00, rail, -0.25, 0.0)        # frame rails
    b.box(X0, X1, 1.0 - rail, 1.00, -0.25, 0.0)

    # Whole rows only, centred in the open field so the two rails match.
    lo = int(math.ceil((rail + R) / row_h))
    hi = int(math.floor((1.0 - rail - R) / row_h))
    mid = (lo + hi) * 0.5
    ys = [0.5 + (j - mid) * row_h for j in range(lo, hi + 1)]
    # Close the zigzag notches at the first and last row against the rails.
    b.box(X0, X1, rail, ys[0] - 0.5 * R, -0.25, 0.0)
    b.box(X0, X1, ys[-1] + 0.5 * R, 1.0 - rail, -0.25, 0.0)

    bm = b.bm
    for j, cy in enumerate(ys):
        off = pitch * 0.5 if j % 2 else 0.0
        # 96 columns is the period; the extra one at each end is what puts a
        # matching half cell on both seams instead of only on the left one.
        for i in range(-1, 97):
            cx = -4.0 + i * pitch + off

            def ring(r, z, cx=cx, cy=cy):
                return [bm.verts.new((cx + r * math.cos(math.pi / 2 + math.tau * k / 6),
                                      b.y0 + cy + r * math.sin(math.pi / 2 + math.tau * k / 6),
                                      z)) for k in range(6)]

            o0, o1 = ring(R, 0.0), ring(R, floor_z)
            m0, m1 = ring(r1, 0.0), ring(rc, -0.012)
            m2 = ring(rc, floor_z)
            for a, c in ((o0, m0), (m0, m1), (m1, m2), (m2, o1), (o1, o0)):
                for k in range(6):
                    k2 = (k + 1) % 6
                    bm.faces.new((a[k], a[k2], c[k2], c[k])).smooth = False
    # Already chamfered by hand at the hole mouth; a bevel pass on ~1000 cells
    # would quadruple the face count to add a second chamfer nobody can resolve.
    return b.finish(bevel=False)


BAND_FNS = [band0_brushed, band1_channel, band2_bolted, band3_louvre,
            band4_rib, band5_conduit, band6_chevron, band7_grille]


# ------------------------------------------------------------------ low poly --

def make_lowpoly():
    """One quad per band, welded into a single island that fills UV 0..1.

    Single island matters: with eight separate islands the 16 px bake margin
    would dilate each band's content 16 px into its neighbours, and the top and
    bottom rows of every band would be contaminated with the wrong material."""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    cols = [bm.verts.new((-SHEET_W * 0.5, j * BAND_H, 0.0)) for j in range(BANDS + 1)]
    cols2 = [bm.verts.new((SHEET_W * 0.5, j * BAND_H, 0.0)) for j in range(BANDS + 1)]
    for j in range(BANDS):
        bm.faces.new((cols[j], cols2[j], cols2[j + 1], cols[j + 1]))
    bm.normal_update()
    for f in bm.faces:
        f.smooth = False
        for loop in f.loops:
            co = loop.vert.co
            loop[uv].uv = ((co.x + SHEET_W * 0.5) / SHEET_W, co.y / (BANDS * BAND_H))
    mesh = bpy.data.meshes.new("TRIMSHEET_LOW")
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("TRIMSHEET_LOW", mesh)
    bpy.context.collection.objects.link(obj)
    return obj


# ----------------------------------------------------------------- materials --

def make_hi_material():
    mat = bpy.data.materials.new("M_HI")
    mat.use_nodes = True
    return mat


def wire_hi(mat, mode):
    """Rewire the shared high-poly material for one pass.

    AO and height both come out of an Emission shader and an EMIT bake rather
    than Blender's own AO bake type, because that is the only way to control the
    occlusion distance and to keep the occlusion local to one band. The height
    pass is just the hit point's Z remapped to 0..1, which is exact and needs no
    samples to converge."""
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    if mode == "NORMAL":
        # Geometry only; a diffuse shader keeps Cycles from complaining.
        bsdf = nt.nodes.new("ShaderNodeBsdfDiffuse")
        nt.links.new(bsdf.outputs[0], out.inputs["Surface"])
        return
    emit = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(emit.outputs[0], out.inputs["Surface"])
    if mode == "AO":
        ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
        ao.samples = AO_SAMPLES
        ao.only_local = True
        ao.inputs["Distance"].default_value = AO_DISTANCE
        nt.links.new(ao.outputs["AO"], emit.inputs["Color"])
    else:
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        rng = nt.nodes.new("ShaderNodeMapRange")
        rng.inputs["From Min"].default_value = Z_LO
        rng.inputs["From Max"].default_value = Z_HI
        nt.links.new(geo.outputs["Position"], sep.inputs["Vector"])
        nt.links.new(sep.outputs["Z"], rng.inputs["Value"])
        nt.links.new(rng.outputs["Result"], emit.inputs["Color"])


def make_lo_material(img):
    mat = bpy.data.materials.new("M_LO")
    mat.use_nodes = True
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    nt.nodes.active = tex          # the bake target is "the active image node"
    return mat


# ---------------------------------------------------------------------- bake --

def bake(scene, low, highs, hi_mat, img, mode):
    wire_hi(hi_mat, mode)
    for m in low.data.materials:
        for n in m.node_tree.nodes:
            if n.type == "TEX_IMAGE":
                n.image = img
                m.node_tree.nodes.active = n

    scene.cycles.samples = SAMPLES[mode]
    bpy.ops.object.select_all(action="DESELECT")
    for o in highs:
        o.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low

    if mode == "NORMAL":
        scene.render.bake.normal_space = "TANGENT"
        scene.render.bake.normal_r = "POS_X"
        scene.render.bake.normal_g = "POS_Y"
        scene.render.bake.normal_b = "POS_Z"
        bpy.ops.object.bake(type="NORMAL")
    else:
        bpy.ops.object.bake(type="EMIT")


def read_image(img):
    """Pull an image out of Blender as (row 0 = top) float RGBA.

    Read through foreach_get, not img.pixels[:] — the latter builds a 16 M entry
    Python list per map and turns a two second step into a thirty second one."""
    buf = np.zeros(SIZE * SIZE * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    return buf.reshape(SIZE, SIZE, 4)[::-1]


def save(path, arr):
    """Write linear data straight to 8 bit with no transfer function.

    Every map here is data, not a picture: normals are an encoded vector, AO and
    height are masks. Saving through Blender's image writer would put a view
    transform on them, which is how a normal map ends up subtly wrong in a way
    nobody traces back to the exporter."""
    a = np.clip(arr, 0.0, 1.0)
    Image.fromarray((a * 255.0 + 0.5).astype(np.uint8)).save(path)


# ------------------------------------------------------------- derived maps --

def green_correlation(nrm, hgt):
    """Decide the normal map's handedness from the data instead of from folklore.

    Row index r runs *down* the image, so the OpenGL "up" axis V is -r. For a
    height field h(r) the surface normal's V component is therefore +dh/dr, not
    -dh/dr — the sign flip between "down the image" and "up in texture space"
    cancels the usual minus. Green encodes that component, so under the OpenGL
    convention (G - 0.5) and dh/dr must share a sign, and the correlation over
    every sloped pixel in the sheet comes out positive. Negative means Blender
    handed us a DirectX map and the channel has to be inverted.

    That sign is easy to talk yourself out of, so `rib_probe` checks the answer a
    second time against a feature whose orientation is known by construction."""
    g = nrm[:, :, 1] - 0.5
    dh = np.zeros_like(hgt)
    dh[1:-1] = (hgt[2:] - hgt[:-2]) * 0.5          # d(height)/d(row)
    mask = np.abs(dh) > 0.004
    if mask.sum() < 1000:
        raise RuntimeError("height map is too flat to establish normal handedness")
    return float(np.mean(g[mask] * dh[mask])), int(mask.sum())


def rib_probe(nrm):
    """Green either side of band 4's rib crown.

    The rib is a box: its upper chamfer faces up the image and its lower chamfer
    faces down, by construction and not by inference. Under OpenGL the first must
    read above 0.5 and the second below it. Columns are sampled between the
    stiffener straps, which sit on a 256 px pitch starting at column 128."""
    def row(ly):
        return 4 * BAND_PX + int(round((1.0 - ly) * BAND_PX))
    cols = slice(200, 300)
    upper = float(nrm[row(0.64):row(0.64) + 6, cols, 1].mean())
    lower = float(nrm[row(0.36) - 6:row(0.36), cols, 1].mean())
    return upper, lower


def curvature_from_normal(nrm):
    """Convexity from the divergence of the normal's tangential components.

    Rolled in U with np.roll so the curvature map tiles exactly as well as the
    normal map it came from, and sampled at two radii because a single 3-tap
    picks up the chamfers and misses the broad crown of a rib."""
    nx = nrm[:, :, 0] * 2.0 - 1.0
    ny = nrm[:, :, 1] * 2.0 - 1.0
    acc = np.zeros((SIZE, SIZE), dtype=np.float32)
    for step, weight in ((1, 0.65), (3, 0.35)):
        dx = (np.roll(nx, -step, axis=1) - np.roll(nx, step, axis=1)) * 0.5
        # Row index grows downward while +Y grows upward, hence the reversal.
        dy = (np.roll(ny, step, axis=0) - np.roll(ny, -step, axis=0)) * 0.5
        acc += weight * (dx + dy) / step
    return np.clip(0.5 + acc * 3.0, 0.0, 1.0)


# --------------------------------------------------------------------- main --

def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.use_denoising = False
    scene.render.bake.use_selected_to_active = True
    scene.render.bake.cage_extrusion = CAGE
    scene.render.bake.max_ray_distance = RAY
    scene.render.bake.margin = MARGIN
    scene.render.bake.margin_type = "EXTEND"
    scene.render.bake.use_clear = True

    hi_mat = make_hi_material()
    highs, tris = [], []
    for fn in BAND_FNS:
        obj, n = fn()
        obj.data.materials.append(hi_mat)
        highs.append(obj)
        tris.append((obj.name, n))

    low = make_lowpoly()
    imgs = {}
    for k in ("NORMAL", "AO", "HEIGHT"):
        img = bpy.data.images.new("bake_" + k, SIZE, SIZE, alpha=False, float_buffer=True)
        img.colorspace_settings.name = "Non-Color"
        imgs[k] = img
    low.data.materials.append(make_lo_material(imgs["NORMAL"]))

    print("\n=== LIMBO PROTOCOL trim sheet ===")
    for name, n in tris:
        print(f"  {name:<18} {n:>8} tris (high)")
    print(f"  {'TOTAL':<18} {sum(n for _, n in tris):>8} tris (high)")

    for k in ("NORMAL", "AO", "HEIGHT"):
        print("  baking %s at %d samples ..." % (k, SAMPLES[k]))
        bake(scene, low, highs, hi_mat, imgs[k], k)

    nrm = read_image(imgs["NORMAL"])[:, :, :3].astype(np.float32)
    ao = read_image(imgs["AO"])[:, :, 0].astype(np.float32)
    hgt = read_image(imgs["HEIGHT"])[:, :, 0].astype(np.float32)

    corr, n = green_correlation(nrm, hgt)
    if corr < 0:
        nrm[:, :, 1] = 1.0 - nrm[:, :, 1]
        print("  green channel: DirectX (corr %+.5f over %d px) -> FLIPPED to OpenGL"
              % (corr, n))
    else:
        print("  green channel: OpenGL   (corr %+.5f over %d px) -> kept" % (corr, n))
    upper, lower = rib_probe(nrm)
    good = upper > 0.5 > lower
    print("  green check:   band 4 rib upper %.3f / lower %.3f -> %s"
          % (upper, lower, "+Y up, correct for Godot" if good else "WRONG"))
    if not good:
        raise RuntimeError("normal map green channel is not OpenGL after correction")

    curv = curvature_from_normal(nrm)

    os.makedirs(OUT, exist_ok=True)
    written = {}
    for name, data in (("normal", nrm), ("ao", ao), ("height", hgt), ("curvature", curv)):
        p = os.path.join(OUT, "trimsheet_%s.png" % name)
        save(p, data)
        written[name] = p

    report(written, nrm, ao, hgt, curv)


def report(written, nrm, ao, hgt, curv):
    print("\n  --- written ---")
    for name, p in written.items():
        with Image.open(p) as im:
            print("  %-10s %s  %dx%d %s" % (name, p, im.size[0], im.size[1], im.mode))

    print("\n  --- per band (V ranges are Godot: v=0 is the top row) ---")
    labels = ["brushed panel", "recessed channel", "bolted seam", "louvre run",
              "raised rib", "conduit + clamps", "hazard chevron", "hex grille"]
    print("  %-3s %-13s %-16s %8s %8s %8s %8s" %
          ("b", "V range", "content", "nrm dev", "ao min", "hgt rng", "seam/adj"))
    ok = True
    for i in range(BANDS):
        s = slice(i * BAND_PX, (i + 1) * BAND_PX)
        n, a, h = nrm[s], ao[s], hgt[s]
        # How far the band's normals depart from flat. A blank bake is 0.000.
        dev = float(np.abs(n[:, :, :2] - 0.5).max())
        # Seam continuity. On a tiling band, column 0 and column 2047 are
        # neighbours, so they must differ no more than any other adjacent pair
        # does — but half the bands are constant in X, where every column is
        # identical and a purely relative test divides by zero and screams. So
        # the seam passes if it is small in absolute terms (under 2 levels of
        # 8 bit, i.e. invisible) OR small relative to the band's own texel step.
        seam = float(np.abs(n[:, 0] - n[:, -1]).mean()) * 255.0
        adj = float(np.abs(n[:, :-1] - n[:, 1:]).mean()) * 255.0
        if dev < 0.02 or (seam > 2.0 and seam > 4.0 * adj):
            ok = False
        print("  %-3d %.3f-%.3f  %-16s %8.3f %8.3f %8.3f %6.2f/%.2f"
              % (i, i / BANDS, (i + 1) / BANDS, labels[i],
                 dev, float(a.min()), float(h.max() - h.min()), seam, adj))
    print("  curvature spread %.3f-%.3f" % (float(curv.min()), float(curv.max())))
    print("  bake check: %s" % ("OK" if ok else "SUSPECT — inspect the PNGs"))


if __name__ == "__main__":
    main()
