#!/usr/bin/env python3
"""LIMBO PROTOCOL — tiling PBR master texture author.

Run:  python3 tools/make_pbr.py            (writes assets/pbr/*.png)
      python3 tools/make_pbr.py --preview   (also writes a contact sheet)

Why this is a Python script and not a Substance graph
-----------------------------------------------------
Everything here is authored as a HEIGHT FIELD first and every other map is
derived from it — normals by differentiation, ambient occlusion by multi-scale
cavity, curvature/wear by comparing the height against its own blur. That is the
same dependency chain a Substance graph builds, and doing it in numpy means the
whole material set regenerates from nothing in about a minute, is diffable in
git, and cannot drift from what the comments claim it is.

Every single operation in this file is PERIODIC. Blurs wrap, noise lattices
wrap, scratches that run off the right edge come back on the left. A texture
that tiles in albedo but not in its ambient occlusion produces a seam that no
one can find but everyone can see.

The split between texture and shader
------------------------------------
These maps carry MATERIAL IDENTITY — what the surface is made of, how it was
machined, how it was assembled. They deliberately do NOT carry PLACEMENT STORY:
the hand-height smudge band on a wall and the worn traffic path down the middle
of a corridor are functions of world position, not of the material, so they live
in nv_surface_pbr.gdshader where world position is available. Baking a smudge
band into a tiling texture puts a smudge band on the ceiling.

Map packing
-----------
  *_albedo.png   sRGB base colour
  *_normal.png   tangent-space normal, OpenGL convention (+Y up)
  *_orm.png      R = ambient occlusion, G = roughness, B = metallic
                 One fetch for three channels. This is the packing every console
                 renderer uses and the reason is bandwidth: the surface shader
                 samples four textures per pixel and a three-way split would
                 make that six.

Resolution: 2048 px covering 2.0 m of surface = 1024 px/m. The detail set covers
0.25 m at the same resolution (8192 px/m) and is overlaid at close range; see
DETAIL_TILING in the shader.
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image

SIZE = 2048
OUT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "assets", "pbr"))

# One tile of a master set covers this much wall. Chosen so a 4 m kit module
# shows a 2x2 panel layout, which is what real machine-room panelling does, and
# so the texel density (1024 px/m) survives a player standing 30 cm from a wall
# with the detail overlay carrying the last octave.
TILE_METRES = 2.0


# ----------------------------------------------------------------- numerics --

def _wrap_blur1(a: np.ndarray, radius: int, axis: int) -> np.ndarray:
    """Box blur along one axis with wrap-around, via a summed-area trick.

    Three of these approximate a gaussian closely enough that nothing
    downstream can tell, and each one is O(n) instead of O(n*r) — which matters
    because the ambient-occlusion pass wants radii up to 160 px at 2048.
    """
    if radius < 1:
        return a
    n = a.shape[axis]
    radius = min(radius, n // 2 - 1)
    pad = [(0, 0), (0, 0)]
    pad[axis] = (radius + 1, radius)
    p = np.pad(a, pad, mode="wrap")
    c = np.cumsum(p, axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    hi = np.take(c, np.arange(2 * radius + 1, n + 2 * radius + 1), axis=axis)
    return (hi - lo) / float(2 * radius + 1)


def blur(a: np.ndarray, radius: float) -> np.ndarray:
    """Periodic, roughly-gaussian blur."""
    r = max(1, int(round(radius / 3.0)))
    out = a
    for _ in range(3):
        out = _wrap_blur1(out, r, 0)
        out = _wrap_blur1(out, r, 1)
    return out


def _lattice(freq: int, rng: np.random.Generator) -> np.ndarray:
    """A freq x freq random lattice that wraps (row/col 0 repeated at the end)."""
    g = rng.random((freq + 1, freq + 1)).astype(np.float32)
    g[-1, :] = g[0, :]
    g[:, -1] = g[:, 0]
    return g


def value_noise(size: int, freq: int, rng: np.random.Generator) -> np.ndarray:
    """Bilinear-smoothstep value noise on a wrapping lattice."""
    g = _lattice(freq, rng)
    t = (np.arange(size, dtype=np.float32) + 0.5) * freq / size
    i = np.floor(t).astype(np.int32)
    f = t - i
    f = f * f * (3.0 - 2.0 * f)
    i = np.clip(i, 0, freq - 1)
    a = g[np.ix_(i, i)]
    b = g[np.ix_(i, i + 1)]
    c = g[np.ix_(i + 1, i)]
    d = g[np.ix_(i + 1, i + 1)]
    fx = f[None, :]
    fy = f[:, None]
    return (a * (1 - fx) * (1 - fy) + b * fx * (1 - fy)
            + c * (1 - fx) * fy + d * fx * fy)


def fbm(size: int, base_freq: int, octaves: int, rng: np.random.Generator,
        gain: float = 0.5, lacunarity: int = 2) -> np.ndarray:
    """Fractal sum of value noise. Frequencies stay integer so it keeps tiling."""
    out = np.zeros((size, size), dtype=np.float32)
    amp = 1.0
    total = 0.0
    freq = base_freq
    for _ in range(octaves):
        out += value_noise(size, freq, rng) * amp
        total += amp
        amp *= gain
        freq *= lacunarity
    return out / total


def stretched_noise(size: int, fx: int, fy: int, rng: np.random.Generator,
                    octaves: int = 3) -> np.ndarray:
    """Anisotropic noise — the brushed-metal primitive.

    Real brushed steel is not "noise with an anisotropic BRDF"; it is a surface
    covered in parallel scratches, and the scratches themselves have to be in
    the normal map or the highlight has nothing to break on.
    """
    out = np.zeros((size, size), dtype=np.float32)
    amp, total = 1.0, 0.0
    for o in range(octaves):
        m = 2 ** o
        g = rng.random((fy * m + 1, fx * m + 1)).astype(np.float32)
        g[-1, :] = g[0, :]
        g[:, -1] = g[:, 0]
        ty = (np.arange(size, dtype=np.float32) + 0.5) * (fy * m) / size
        tx = (np.arange(size, dtype=np.float32) + 0.5) * (fx * m) / size
        iy, ix = np.floor(ty).astype(np.int32), np.floor(tx).astype(np.int32)
        fyy, fxx = ty - iy, tx - ix
        fyy = fyy * fyy * (3 - 2 * fyy)
        fxx = fxx * fxx * (3 - 2 * fxx)
        a = g[np.ix_(iy, ix)]
        b = g[np.ix_(iy, ix + 1)]
        c = g[np.ix_(iy + 1, ix)]
        d = g[np.ix_(iy + 1, ix + 1)]
        FX, FY = fxx[None, :], fyy[:, None]
        out += (a * (1 - FX) * (1 - FY) + b * FX * (1 - FY)
                + c * (1 - FX) * FY + d * FX * FY) * amp
        total += amp
        amp *= 0.55
    return out / total


def norm01(a: np.ndarray) -> np.ndarray:
    lo, hi = float(a.min()), float(a.max())
    if hi - lo < 1e-6:
        return np.zeros_like(a)
    return (a - lo) / (hi - lo)


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / max(e1 - e0, 1e-6), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ------------------------------------------------------------- height shapes --

def grid_distance(size: int, cells: int, offset: float = 0.0) -> np.ndarray:
    """Distance in pixels to the nearest gridline of a `cells`-way split.

    Periodic by construction, which is what lets a panel layout tile.
    """
    pitch = size / float(cells)
    t = (np.arange(size, dtype=np.float32) + 0.5 - offset) % pitch
    return np.minimum(t, pitch - t)


def recessed_grid(size: int, cols: int, rows: int, gap_px: float,
                  chamfer_px: float, depth: float) -> np.ndarray:
    """A field of raised plates separated by chamfered recessed channels.

    The chamfer is the entire point. A panel gap modelled as a straight-sided
    slot has two surfaces (the plate face and the channel floor) that face the
    same direction, so a light rakes across it and nothing happens. A chamfered
    lip adds a third surface at 45 degrees which catches a highlight the flat
    face cannot — this is the same 6 mm bevel argument build_kit.py makes in
    geometry, resolved here at texture scale for the gaps that are too small to
    model.
    """
    dx = grid_distance(size, cols)[None, :]
    dy = grid_distance(size, rows)[:, None]
    d = np.minimum(np.broadcast_to(dx, (size, size)),
                   np.broadcast_to(dy, (size, size)))
    half = gap_px * 0.5
    # 0 inside the channel, 1 out on the plate, linear ramp across the chamfer.
    lip = np.clip((d - half) / max(chamfer_px, 1e-3), 0.0, 1.0)
    return (lip - 1.0) * depth


def _stamp(out: np.ndarray, x0: float, y0: float, x1: float, y1: float,
           pad: float, fn) -> None:
    """Evaluate `fn(X, Y)` over a small wrapped window and subtract it.

    Everything drawn as an individual mark — bolts, scratches, weld beads —
    only touches a few hundred pixels, so evaluating it over the full 2048^2
    grid is thousands of times more arithmetic than the mark is worth. The
    first version of this file did exactly that and took six minutes to
    generate the set, which is long enough that you stop iterating on the art
    and start defending the numbers you already have.
    """
    size = out.shape[0]
    xlo, xhi = int(np.floor(min(x0, x1) - pad)), int(np.ceil(max(x0, x1) + pad))
    ylo, yhi = int(np.floor(min(y0, y1) - pad)), int(np.ceil(max(y0, y1) + pad))
    if xhi - xlo >= size or yhi - ylo >= size:
        xlo, xhi, ylo, yhi = 0, size, 0, size
    ix = np.arange(xlo, xhi)
    iy = np.arange(ylo, yhi)
    X, Y = np.meshgrid(ix.astype(np.float32), iy.astype(np.float32))
    v = fn(X, Y)
    if v is None:
        return
    out[np.ix_(iy % size, ix % size)] += v


def bolt_field(size: int, positions, radius_px: float, height: float,
               socket: bool = True) -> np.ndarray:
    """Hex-socket bolt heads at explicit pixel positions.

    Bolts are the cheapest legibility trick in industrial art: they give the eye
    an absolute scale reference, so a wall stops being an abstract dark plane
    and becomes a wall made of panels that someone screwed on. They also want
    to sit where a fastener would actually go — at plate corners, in line with a
    seam — which is why this takes a position list rather than a tidy grid.
    """
    out = np.zeros((size, size), dtype=np.float32)
    for (cx, cy) in positions:
        def f(X, Y, cx=cx, cy=cy):
            r = np.sqrt((X - cx) ** 2 + (Y - cy) ** 2)
            # Washer, domed cap, hex socket. Three concentric steps is what
            # makes a bolt read as hardware instead of a bump.
            v = (1.0 - smoothstep(radius_px * 1.28, radius_px * 1.42, r)) * height * 0.30
            v += (1.0 - smoothstep(radius_px * 0.80, radius_px * 0.98, r)) * height * 0.70
            if socket:
                v -= (1.0 - smoothstep(radius_px * 0.30, radius_px * 0.44, r)) \
                        * height * 1.15
            return v
        _stamp(out, cx, cy, cx, cy, radius_px * 1.8, f)
    return out


def grid_positions(size: int, cols: int, rows: int, inset: float,
                   corners: bool = True):
    """Fastener positions for a cols x rows plate layout, inset from each
    plate's corners (or its centre)."""
    px, py = size / float(cols), size / float(rows)
    out = []
    for j in range(rows):
        for i in range(cols):
            cx, cy = (i + 0.5) * px, (j + 0.5) * py
            if corners:
                for sx in (-1.0, 1.0):
                    for sy in (-1.0, 1.0):
                        out.append((cx + sx * (px * 0.5 - inset),
                                    cy + sy * (py * 0.5 - inset)))
            else:
                out.append((cx, cy))
    return out


def scratches(size: int, count: int, rng: np.random.Generator,
              length: float = 0.16, width: float = 1.6,
              angle_bias: float | None = None, spread: float = 3.14159,
              depth: float = 1.0) -> np.ndarray:
    """Random gouges, drawn with wrap-around.

    `angle_bias` aims them: floors get scratches along the direction of travel,
    walls get them wherever something was dragged past.
    """
    out = np.zeros((size, size), dtype=np.float32)
    for _ in range(count):
        ang = rng.uniform(0, 2 * np.pi) if angle_bias is None else \
                angle_bias + rng.uniform(-spread, spread)
        ln = rng.uniform(0.25, 1.0) * length * size
        x0, y0 = rng.uniform(0, size), rng.uniform(0, size)
        dx, dy = float(np.cos(ang)), float(np.sin(ang))
        w = width * rng.uniform(0.5, 1.6)
        amp = depth * rng.uniform(0.45, 1.0)

        def f(X, Y, x0=x0, y0=y0, dx=dx, dy=dy, ln=ln, w=w, amp=amp):
            px, py = X - x0, Y - y0
            t = np.clip(px * dx + py * dy, 0.0, ln)
            d = np.abs(px * dy - py * dx)
            # Taper the ends so a scratch does not stop with a chisel edge.
            taper = np.clip(np.minimum(t, ln - t) / max(ln * 0.22, 1.0), 0.0, 1.0)
            return -(1.0 - smoothstep(w * 0.3, w, d)) * taper * amp
        _stamp(out, x0, y0, x0 + dx * ln, y0 + dy * ln, w * 2.0 + 2.0, f)
    return out


# ------------------------------------------------------------ cell dispatch --

class Cells:
    """A cols x rows subdivision of the tile, with per-cell local coordinates.

    This is the machinery that makes a tile stop looking like a tile. A wall
    covered in one repeated plate is a texture; a wall covered in plates that
    are each a slightly different height, a slightly different shade, and every
    fourth one of which is a vent or an access hatch, is a WALL. Doing that
    needs per-cell random values and per-cell local UVs, and doing it without
    a python loop over cells needs them as full-resolution arrays.
    """

    def __init__(self, size: int, cols: int, rows: int,
                 rng: np.random.Generator):
        self.size, self.cols, self.rows = size, cols, rows
        px, py = size / float(cols), size / float(rows)
        self.px, self.py = px, py
        x = np.arange(size, dtype=np.float32) + 0.5
        y = np.arange(size, dtype=np.float32) + 0.5
        ix = np.minimum((x / px).astype(np.int32), cols - 1)
        iy = np.minimum((y / py).astype(np.int32), rows - 1)
        self.ix, self.iy = ix, iy
        # Local coordinate inside the cell, 0..1.
        self.u = ((x / px) - ix)[None, :]
        self.v = ((y / py) - iy)[:, None]
        # Distance to the cell edge in pixels, both axes.
        self.du = np.minimum(self.u, 1.0 - self.u) * px
        self.dv = np.minimum(self.v, 1.0 - self.v) * py
        self._rand = rng.random((rows, cols, 8)).astype(np.float32)

    def rand(self, channel: int) -> np.ndarray:
        """A full-res field, constant within each cell."""
        return self._rand[np.ix_(self.iy, self.ix)][:, :, channel]

    def is_type(self, channel: int, lo: float, hi: float) -> np.ndarray:
        r = self.rand(channel)
        return ((r >= lo) & (r < hi)).astype(np.float32)

    def centres(self):
        return [(( i + 0.5) * self.px, (j + 0.5) * self.py)
                for j in range(self.rows) for i in range(self.cols)]


# ------------------------------------------------------------ derived maps --

def normal_from_height(h: np.ndarray, strength: float) -> np.ndarray:
    """Tangent-space normal by central difference, OpenGL convention.

    Green points UP the image, which is what Godot's `hint_normal` expects. The
    +Y flip is where half of all normal maps in the wild are wrong; the tell is
    that recesses read as bumps under a light from above and nobody notices
    until they light the scene from below.
    """
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
    nx = -dx * strength
    ny = dy * strength            # +Y up: image row increases downward
    nz = np.ones_like(h)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack([nx * inv, ny * inv, nz * inv], axis=-1)


def cavity_ao(h: np.ndarray, scales=(6, 18, 48, 120), strength: float = 1.0
              ) -> np.ndarray:
    """Multi-scale cavity occlusion.

    A pixel is occluded to the extent it sits below its own neighbourhood
    average, summed over several neighbourhood sizes so both a 3 px bolt socket
    and a 100 px panel channel get darkened. Not a ray-traced bake; visually
    indistinguishable from one on a height field this shallow, and it costs
    milliseconds instead of minutes.
    """
    occ = np.zeros_like(h)
    w_total = 0.0
    for i, s in enumerate(scales):
        w = 1.0 / (1.0 + i * 0.55)
        occ += np.maximum(blur(h, s) - h, 0.0) * w
        w_total += w
    occ /= w_total
    occ = norm01(occ)
    return np.clip(1.0 - occ * strength, 0.0, 1.0)


def convexity(h: np.ndarray, radius: float = 10.0) -> np.ndarray:
    """0..1 mask that is high on ridges and edges — the edge-wear driver.

    Everything that gets touched, scraped or walked on wears at its high points
    first. Driving albedo lift and roughness drop off this is what stops "wear"
    from looking like a noise texture multiplied over a panel.
    """
    return np.clip(norm01(h - blur(h, radius)) * 2.0 - 1.0, 0.0, 1.0)


def to_srgb(lin: np.ndarray) -> np.ndarray:
    """Godot imports albedo PNGs as sRGB, so linear values must be encoded."""
    a = np.clip(lin, 0.0, 1.0)
    return np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(a, 1 / 2.4) - 0.055)


def save_rgb(path: str, rgb: np.ndarray) -> None:
    img = (np.clip(rgb, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(img, "RGB").save(path, optimize=True)
    print("  %-46s %dx%d" % (os.path.basename(path), img.shape[1], img.shape[0]))


def save_set(name: str, albedo_lin: np.ndarray, normal: np.ndarray,
             ao: np.ndarray, rough: np.ndarray, metal: np.ndarray) -> None:
    os.makedirs(OUT, exist_ok=True)
    save_rgb(os.path.join(OUT, "%s_albedo.png" % name), to_srgb(albedo_lin))
    save_rgb(os.path.join(OUT, "%s_normal.png" % name), normal * 0.5 + 0.5)
    orm = np.stack([np.clip(ao, 0, 1), np.clip(rough, 0, 1),
                    np.clip(metal, 0, 1)], axis=-1)
    save_rgb(os.path.join(OUT, "%s_orm.png" % name), orm)


def tint(base: tuple, mask: np.ndarray) -> np.ndarray:
    """Broadcast a scalar mask into an RGB image at a base colour."""
    return np.stack([mask * base[0], mask * base[1], mask * base[2]], axis=-1)


# ------------------------------------------------------------------- panels --

def build_wall_panel(rng: np.random.Generator) -> None:
    """M_PanelDark — the wall the player stands 30 cm from.

    Layout inside the 2 m tile: a 4 x 4 grid of 0.5 m plates. The kit geometry
    already owns everything above half a metre (borders, insets, recessed
    emissive channels, 6 mm chamfers), so a texture that also draws 1 m plates
    is competing with the mesh and loses. The texture's job is the octave the
    mesh cannot afford: 20-200 mm.

    The variety is the point. Every plate gets its own height offset, its own
    shade and its own roughness, and one plate in three is not a plate at all
    but a louvred vent or a bolted access hatch. A wall of identical plates is
    a texture; a wall of plates that disagree with each other is a wall.
    """
    s = SIZE
    px_per_m = s / TILE_METRES
    C = Cells(s, 4, 4, rng)

    # --- plate layout -------------------------------------------------------
    # 18 mm channels with a 10 mm chamfered lip either side. Wider and deeper
    # than the first pass: at 14 mm and a 8 mm lip the whole feature was 30 px
    # and read as a pencil line rather than as a gap you could get a fingernail
    # into.
    h = recessed_grid(s, 4, 4, gap_px=0.018 * px_per_m,
                      chamfer_px=0.010 * px_per_m, depth=1.0)
    plate = smoothstep(-0.55, -0.06, h)          # 1 on plate faces, 0 in channels

    # Per-plate height jitter. Real panels are shimmed by hand and no two sit
    # exactly flush; the 1-2 mm step between neighbours is the single most
    # convincing thing in the whole set because it puts a hard shadow edge
    # along a seam that would otherwise be symmetric.
    h = h + (C.rand(0) - 0.5) * 0.30 * plate

    # A reveal step inside each plate: the plate face is not flat, it has a
    # 25 mm border that stands proud of a shallow field.
    inner = smoothstep(0.020 * px_per_m, 0.030 * px_per_m,
                       np.minimum(C.du, C.dv))
    h = h - inner * 0.22 * plate

    # --- plate types --------------------------------------------------------
    vent = C.is_type(1, 0.00, 0.20) * plate
    hatch = C.is_type(1, 0.20, 0.36) * plate
    ribbed = C.is_type(1, 0.36, 0.50) * plate

    # Louvres: five slots, cut into the plate field, each with a lip below it.
    slot = np.sin(C.v * np.pi * 5.0) ** 2
    louvre = (smoothstep(0.55, 0.95, slot)
              * smoothstep(0.030 * px_per_m, 0.055 * px_per_m, C.du))
    h = h - louvre * 0.62 * vent

    # Access hatch: a deeper inner rectangle with a raised lip and a pull slot.
    hface = smoothstep(0.048 * px_per_m, 0.058 * px_per_m,
                       np.minimum(C.du, C.dv))
    h = h - hface * 0.30 * hatch
    pull = (smoothstep(0.30, 0.34, C.u) * smoothstep(0.70, 0.66, C.u)
            * smoothstep(0.74, 0.78, C.v) * smoothstep(0.86, 0.82, C.v))
    h = h - pull * 0.55 * hatch

    # Ribbed plate: three raised stiffeners.
    rib = smoothstep(0.62, 0.90, np.sin(C.v * np.pi * 3.0 + 0.5) ** 2)
    h = h + rib * 0.26 * ribbed * smoothstep(0.035 * px_per_m,
                                             0.055 * px_per_m, C.du)

    # --- hardware -----------------------------------------------------------
    # Bolts at plate corners, 22 mm heads, plus one row down the hatch edges.
    h = h + bolt_field(s, grid_positions(s, 4, 4, inset=0.045 * px_per_m),
                       radius_px=0.011 * px_per_m, height=0.34)

    # --- micro --------------------------------------------------------------
    # Brushed grain, long in X: the direction a linisher runs on sheet that
    # comes off a press in a 2 m width.
    grain = stretched_noise(s, fx=6, fy=560, rng=rng, octaves=3) - 0.5
    h = h + grain * 0.070
    # Press-formed sheet is never dead flat, and the tiny slope change is what
    # makes a specular sweep across a wall interesting instead of a clean ramp.
    oil = fbm(s, 3, 4, rng) - 0.5
    h = h + oil * 0.13 * plate
    h = h + scratches(s, 140, rng, length=0.05, width=2.4, depth=0.12)

    normal = normal_from_height(h, strength=3.0)
    ao = cavity_ao(h, strength=1.0)
    edge = convexity(h, radius=9.0)

    # --- roughness ----------------------------------------------------------
    # Base is matte coated steel. Four things vary it: brushed grain
    # (anisotropic micro-facets), a blotch field (batch-to-batch coating
    # variance), per-plate variance, and edge wear (polished where rubbed).
    blotch = fbm(s, 3, 5, rng)
    # 0.80, not 0.74. The first tuned build measured +76% mean luminance on the
    # 30 cm wall shot against the procedural baseline, with the fraction of the
    # frame below 2% luma falling from 48% to 20%. Almost none of that was
    # albedo: it was a plate face at roughness ~0.55 returning a broad specular
    # sheen to a spotlight half a metre away. Coated steel in a machine room is
    # matte. Only the worn edges and the contact band are allowed to be shiny.
    rough = np.full((s, s), 0.80, dtype=np.float32)
    rough += (blotch - 0.5) * 0.20
    rough += grain * 0.14
    rough += (C.rand(2) - 0.5) * 0.16 * plate
    rough -= edge * 0.20
    # Inside the channels the coating was never rubbed and dust collects.
    rough += (1.0 - plate) * 0.12
    rough = np.clip(rough, 0.16, 0.95)

    # --- albedo -------------------------------------------------------------
    # Near-black, but never ONE near-black. The whole "AAA surface" delta is
    # that no two square centimetres return light identically.
    base = np.full((s, s), 0.082, dtype=np.float32)
    base *= 1.0 + (C.rand(3) - 0.5) * 0.26 * plate    # plate-to-plate batch
    base *= 1.0 + (blotch - 0.5) * 0.30
    base *= 1.0 - (1.0 - ao) * 0.40
    base += edge * 0.036                       # bare metal showing at the edges
    grime = np.clip(fbm(s, 6, 4, rng) - 0.42, 0.0, 1.0) * 1.6
    base *= 1.0 - grime * 0.24
    alb = tint((1.0, 1.02, 1.10), base)        # a hair cool, matching the kit
    # Rust-free, but the exposed edges read very slightly warm — the eye needs
    # one non-blue thing in the frame or the whole game looks like a colour cast.
    alb[..., 0] += edge * 0.022
    alb[..., 1] += edge * 0.013

    metal = np.clip(0.05 + edge * 0.38, 0.0, 1.0)

    print("wall_panel")
    save_set("wall_panel", alb, normal, ao, rough, metal)


def build_floor_plate(rng: np.random.Generator) -> None:
    """M_FloorPlate — 1 m plates, anti-slip tread, and a wear story.

    The tread pattern is the reason this set exists. A dark floor with no relief
    returns a flashlight beam as one soft ellipse; a floor with a 2 mm raised
    tread returns it as a field of thousands of tiny highlights that MOVE as the
    player walks, and motion is what sells a surface.
    """
    s = SIZE
    px_per_m = s / TILE_METRES
    C = Cells(s, 2, 2, rng)

    # 2 x 2 plates per 2 m tile = 1 m plates, deeper and wider channels than the
    # walls because a floor joint has to shed water and take a pallet truck.
    h = recessed_grid(s, 2, 2, gap_px=0.028 * px_per_m,
                      chamfer_px=0.013 * px_per_m, depth=1.0)
    plate_mask = smoothstep(-0.55, -0.06, h)
    # Plates settle. A 2 mm step between neighbouring floor plates is something
    # every player has walked over in a real building and nobody has seen in a
    # game, and it costs one line.
    h = h + (C.rand(0) - 0.5) * 0.26 * plate_mask

    # Anti-slip: a diagonal lozenge tread, but only on two plates in three.
    # A floor where every plate is treaded is a floor with one idea on it.
    yy, xx = np.mgrid[0:s, 0:s].astype(np.float32)
    pitch = 0.055 * px_per_m
    d1 = np.abs(((xx + yy) % pitch) - pitch * 0.5)
    d2 = np.abs(((xx - yy) % pitch) - pitch * 0.5)
    bar_w = pitch * 0.19
    tread = np.maximum((1.0 - smoothstep(bar_w * 0.55, bar_w, d1)),
                       (1.0 - smoothstep(bar_w * 0.55, bar_w, d2)))
    # Break the tread into segments so it is a lozenge field, not endless lines.
    seg = ((np.floor(xx / (pitch * 3.0)) + np.floor(yy / (pitch * 3.0))) % 2)
    tread = tread * (0.55 + 0.45 * seg)
    treaded = C.is_type(1, 0.0, 0.66)
    h = h + tread * 0.34 * plate_mask * treaded

    # The untreaded plates get a shallow recessed field with a border reveal
    # instead, so they still have relief to catch a raking beam.
    smooth_plate = (1.0 - treaded) * plate_mask
    h = h - smoothstep(0.055 * px_per_m, 0.075 * px_per_m,
                       np.minimum(C.du, C.dv)) * 0.20 * smooth_plate

    h = h + bolt_field(s, grid_positions(s, 2, 2, inset=0.062 * px_per_m),
                       radius_px=0.015 * px_per_m, height=0.30)

    # Traffic scuffs. Biased along X because a corridor has a direction, and
    # the shader rotates the whole set per-surface if the corridor does not.
    h = h + scratches(s, 420, rng, length=0.30, width=1.5,
                      angle_bias=0.0, spread=0.30, depth=0.055)
    h = h + scratches(s, 120, rng, length=0.10, width=2.2, depth=0.045)

    normal = normal_from_height(h, strength=2.6)
    ao = cavity_ao(h, strength=1.05)
    edge = convexity(h, radius=7.0)

    # --- roughness: the traffic story -------------------------------------
    # A worn floor is POLISHED where feet land and rough where they do not.
    # The polish mask is a broad low-frequency field so the effect reads at
    # room scale; the shader multiplies it by a corridor-spine mask so the
    # polish lands where people actually walk.
    traffic = smoothstep(0.42, 0.78, fbm(s, 2, 4, rng))
    grit = fbm(s, 12, 4, rng)
    rough = np.full((s, s), 0.62, dtype=np.float32)
    rough -= traffic * 0.26
    rough -= edge * 0.24                 # tread tips buffed smooth
    rough += (grit - 0.5) * 0.16
    rough += smoothstep(0.30, 0.02, norm01(h)) * 0.16   # dirt in the joints
    rough = np.clip(rough, 0.10, 0.95)

    # --- albedo ------------------------------------------------------------
    base = np.full((s, s), 0.070, dtype=np.float32)
    base *= 1.0 + (C.rand(3) - 0.5) * 0.22 * plate_mask
    base *= 1.0 + (fbm(s, 3, 5, rng) - 0.5) * 0.30
    base *= 1.0 - (1.0 - ao) * 0.45
    base += edge * 0.048
    base += traffic * 0.014              # polished metal shows a touch brighter
    stain = np.clip(fbm(s, 5, 5, rng) - 0.48, 0.0, 1.0) * 2.0
    base *= 1.0 - stain * 0.30
    alb = tint((1.0, 1.01, 1.08), base)

    metal = np.clip(0.20 + edge * 0.50 + traffic * 0.12, 0.0, 1.0)

    print("floor_plate")
    save_set("floor_plate", alb, normal, ao, rough, metal)


def build_armor_panel(rng: np.random.Generator) -> None:
    """M_PanelTrim / armour — heavier, machined, more expensive-looking.

    This is the material that goes on the pieces the player is meant to read as
    structural: doorframes, armour walls, column collars. Bigger forms, welded
    seams, and a lower base roughness so it separates from the wall panels under
    the same light. Two materials that differ only in albedo read as one
    material; two that differ in ROUGHNESS read as two.
    """
    s = SIZE
    px_per_m = s / TILE_METRES

    # One big plate per tile with a heavy border reveal.
    h = recessed_grid(s, 1, 1, gap_px=0.030 * px_per_m,
                      chamfer_px=0.016 * px_per_m, depth=1.0)

    # Raised horizontal ribs across the plate — structural stiffeners, with a
    # chamfered shoulder rather than a soft hump. The chamfer is what makes an
    # extrusion read as machined; a rounded ridge reads as a fold in cloth.
    yy = np.arange(s, dtype=np.float32)[:, None]
    rib_pitch = 0.25 * px_per_m
    dy = np.abs((yy % rib_pitch) - rib_pitch * 0.5)
    rib_w = 0.028 * px_per_m
    cham = 0.006 * px_per_m
    rib = np.clip((rib_w - dy) / cham, 0.0, 1.0)
    plate_mask = smoothstep(-0.30, -0.05, h)
    h = h + np.broadcast_to(rib, (s, s)) * 0.40 * plate_mask

    # A weld seam: a beaded line with the ripple a real bead has.
    bead_y = int(s * 0.62)
    dist = np.abs(np.arange(s, dtype=np.float32)[:, None] - bead_y)
    dist = np.minimum(dist, s - dist)
    ripple = 0.5 + 0.5 * np.sin(np.arange(s, dtype=np.float32)[None, :]
                                * (2 * np.pi * 26.0 / s))
    bead_w = 0.011 * px_per_m
    bead = (1.0 - smoothstep(bead_w * 0.4, bead_w, dist)) * (0.55 + 0.45 * ripple)
    h = h + bead * 0.30 * plate_mask

    h = h + bolt_field(s, grid_positions(s, 3, 3, inset=0.030 * px_per_m),
                       radius_px=0.014 * px_per_m, height=0.44)
    h = h + (stretched_noise(s, fx=440, fy=8, rng=rng, octaves=3) - 0.5) * 0.05
    h = h + (fbm(s, 4, 4, rng) - 0.5) * 0.09
    h = h + scratches(s, 60, rng, length=0.07, width=2.8, depth=0.09)

    normal = normal_from_height(h, strength=2.9)
    ao = cavity_ao(h, strength=0.95)
    edge = convexity(h, radius=11.0)

    blotch = fbm(s, 3, 5, rng)
    rough = np.full((s, s), 0.54, dtype=np.float32)
    rough += (blotch - 0.5) * 0.24
    rough -= edge * 0.16
    rough += smoothstep(0.34, 0.04, norm01(h)) * 0.16
    rough = np.clip(rough, 0.10, 0.92)

    base = np.full((s, s), 0.098, dtype=np.float32)
    base *= 1.0 + (blotch - 0.5) * 0.28
    base *= 1.0 - (1.0 - ao) * 0.40
    base += edge * 0.040
    alb = tint((1.0, 1.01, 1.06), base)
    # Heat tint either side of the weld bead: the one place in the palette
    # allowed to be warm, and it is worth a lot in an all-teal frame.
    heat = (1.0 - smoothstep(bead_w, bead_w * 4.5, dist)) * plate_mask
    alb[..., 0] += heat * 0.030
    alb[..., 1] += heat * 0.012
    alb[..., 2] -= heat * 0.004

    metal = np.clip(0.45 + edge * 0.28, 0.0, 1.0)

    print("armor_panel")
    save_set("armor_panel", alb, normal, ao, rough, metal)


def build_grate(rng: np.random.Generator) -> None:
    """M_Grate — the parallax-occlusion hero surface.

    Authored with an unusually deep, clean height field on purpose: this set is
    the one the POM shader steps through, and POM needs real depth separation
    between the bar tops and the void below or it produces mush. The albedo is
    near-zero in the holes so that even without POM the grate reads as holes.
    """
    s = SIZE
    px_per_m = s / TILE_METRES

    # Bearing bars every 30 mm running X, cross rods every 100 mm running Y.
    yy, xx = np.mgrid[0:s, 0:s].astype(np.float32)
    bar_pitch = 0.030 * px_per_m
    bar_w = 0.006 * px_per_m
    dby = np.abs((yy % bar_pitch) - bar_pitch * 0.5)
    bars = 1.0 - smoothstep(bar_w * 0.55, bar_w * 0.95, dby)

    rod_pitch = 0.100 * px_per_m
    rod_w = 0.005 * px_per_m
    drx = np.abs((xx % rod_pitch) - rod_pitch * 0.5)
    rods = 1.0 - smoothstep(rod_w * 0.5, rod_w * 0.95, drx)

    h = np.maximum(bars, rods * 0.72)
    # Round the bar tops slightly: a grate that has been walked on is not sharp.
    h = h - (1.0 - h) * 0.0
    h = blur(h, 1.6)
    h = h + (stretched_noise(s, fx=380, fy=10, rng=rng, octaves=2) - 0.5) * 0.05 * h
    h = h + scratches(s, 200, rng, length=0.12, width=1.2, depth=0.04) * h

    normal = normal_from_height(h, strength=3.4)
    # AO here is dominated by the void between bars, so bias it hard.
    ao = np.clip(cavity_ao(h, scales=(4, 12, 34), strength=1.25), 0.0, 1.0)
    ao = np.minimum(ao, 0.10 + 0.90 * smoothstep(0.05, 0.55, h))
    edge = convexity(h, radius=5.0)

    rough = np.full((s, s), 0.55, dtype=np.float32)
    rough -= edge * 0.30                     # bar tops polished by boots
    rough += (fbm(s, 8, 4, rng) - 0.5) * 0.18
    rough += (1.0 - smoothstep(0.05, 0.5, h)) * 0.22
    rough = np.clip(rough, 0.12, 0.95)

    base = np.full((s, s), 0.085, dtype=np.float32)
    base *= 0.06 + 0.94 * smoothstep(0.02, 0.45, h)   # the holes are the void
    base *= 1.0 + (fbm(s, 4, 4, rng) - 0.5) * 0.25
    base += edge * 0.070
    alb = tint((1.0, 1.01, 1.05), base)

    metal = np.clip(0.45 + edge * 0.45, 0.0, 1.0) * smoothstep(0.02, 0.35, h)

    print("grate")
    save_set("grate", alb, normal, ao, rough, metal)
    # POM needs the height field itself, single channel, 0 = deepest.
    save_rgb(os.path.join(OUT, "grate_height.png"),
             np.stack([norm01(h)] * 3, axis=-1))


def build_detail(rng: np.random.Generator) -> None:
    """The close-up octave: 0.25 m of surface at 2048 px = 8192 px/m.

    This set is not a material. It is the last octave of EVERY material,
    overlaid at close range and faded out past ~3 m so it never contributes to
    the distant image (where it would just be shimmer). Its normal is what
    stands between "a nice texture" and "a surface" when the player's face is
    30 cm from a wall — which in a flashlight game happens constantly.

    Only two channels ship: the normal, and a roughness breakup packed into the
    ORM's G. Albedo detail at this scale is invisible under a beam.
    """
    s = SIZE

    # Machining grain: fine parallel tool marks with occasional deeper chatter.
    grain = stretched_noise(s, fx=10, fy=900, rng=rng, octaves=4) - 0.5
    chatter = stretched_noise(s, fx=4, fy=170, rng=rng, octaves=2) - 0.5
    h = grain * 0.55 + chatter * 0.25

    # Micro-scratches in every direction — handling, cloths, dust wiped off.
    h = h + scratches(s, 900, rng, length=0.22, width=1.1, depth=0.10)
    h = h + scratches(s, 260, rng, length=0.06, width=2.0, depth=0.16)

    # Dust and grit specks sitting ON the surface (positive height).
    speck = fbm(s, 220, 2, rng)
    h = h + np.clip(speck - 0.74, 0.0, 1.0) * 2.6 * 0.22

    # Tiny pitting.
    pit = fbm(s, 150, 2, rng)
    h = h - np.clip(pit - 0.78, 0.0, 1.0) * 2.4 * 0.30

    normal = normal_from_height(h, strength=1.5)
    ao = cavity_ao(h, scales=(3, 9, 24), strength=0.55)
    rough = np.clip(0.5 + (fbm(s, 60, 3, rng) - 0.5) * 0.55
                    - convexity(h, 4.0) * 0.25, 0.0, 1.0)

    os.makedirs(OUT, exist_ok=True)
    print("detail")
    save_rgb(os.path.join(OUT, "detail_normal.png"), normal * 0.5 + 0.5)
    save_rgb(os.path.join(OUT, "detail_orm.png"),
             np.stack([ao, rough, np.zeros_like(rough)], axis=-1))


# -------------------------------------------------------------------- main --

def contact_sheet() -> None:
    """One PNG with every map at 256 px, for eyeballing the whole set at once."""
    names = sorted(f for f in os.listdir(OUT) if f.endswith(".png")
                   and f != "_contact.png")
    cols = 3
    rows = (len(names) + cols - 1) // cols
    cell = 300
    sheet = Image.new("RGB", (cols * cell, rows * (cell + 18)), (18, 20, 24))
    from PIL import ImageDraw
    d = ImageDraw.Draw(sheet)
    for i, n in enumerate(names):
        im = Image.open(os.path.join(OUT, n)).resize((cell, cell), Image.LANCZOS)
        x, y = (i % cols) * cell, (i // cols) * (cell + 18)
        sheet.paste(im, (x, y + 18))
        d.text((x + 4, y + 4), n, fill=(150, 210, 255))
    sheet.save(os.path.join(OUT, "_contact.png"))
    print("contact sheet -> %s/_contact.png" % OUT)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    jobs = {
        "wall": build_wall_panel,
        "floor": build_floor_plate,
        "armor": build_armor_panel,
        "grate": build_grate,
        "detail": build_detail,
    }
    # Fixed seeds: a material set that changes when you re-run the script is not
    # a material set, it is a slot machine, and no A/B against it means anything.
    seeds = {"wall": 20260801, "floor": 20260802, "armor": 20260803,
             "grate": 20260804, "detail": 20260805}
    for k, fn in jobs.items():
        if args.only and k not in args.only.split(","):
            continue
        fn(np.random.default_rng(seeds[k]))
    if args.preview:
        contact_sheet()
    print("done -> %s" % OUT)


if __name__ == "__main__":
    main()
