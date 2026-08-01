#!/usr/bin/env python3
"""Generate the light-projector (gobo) textures the lighting rig shoots through.

Pure stdlib PNG writer — no Pillow, no numpy, nothing to install.

A projector texture is the single cheapest way to make a light look expensive.
An unmodified spotlight paints a perfect ellipse, which the eye reads instantly
as "engine default". The same light shot through a grate throws structured bars
that bend over every piece of geometry they cross, and in volumetric fog the
beam itself becomes striped. It costs one texture fetch per light.

Output: assets/textures/gobo_*.png (greyscale, 512 px)
"""

import math
import os
import struct
import zlib

SIZE = 512
OUT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "textures")
)


def write_png(path, rows, rgb=False):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2 if rgb else 0, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


# ------------------------------------------------------------------ helpers --

def _hash(x, y, s):
    n = (x * 374761393 + y * 668265263 + s * 1442695040888963407) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0


def _smooth_noise(u, v, freq, seed):
    """Cheap value noise with cosine interpolation."""
    x, y = u * freq, v * freq
    x0, y0 = int(math.floor(x)), int(math.floor(y))
    fx, fy = x - x0, y - y0
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)
    m = int(freq)
    a = _hash(x0 % m, y0 % m, seed)
    b = _hash((x0 + 1) % m, y0 % m, seed)
    c = _hash(x0 % m, (y0 + 1) % m, seed)
    d = _hash((x0 + 1) % m, (y0 + 1) % m, seed)
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(u, v, seed, octaves=4, base=4):
    total, amp, norm, freq = 0.0, 1.0, 0.0, base
    for _ in range(octaves):
        total += _smooth_noise(u, v, freq, seed) * amp
        norm += amp
        amp *= 0.5
        freq *= 2
    return total / norm


def clamp8(v):
    return max(0, min(255, int(v * 255.0 + 0.5)))


def smoothstep(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def falloff(u, v, power=1.6):
    """Radial soft edge so the gobo never shows the texture's square border.

    Deliberately flat across the middle: a projector that dims toward its own
    edges just re-creates the plain ellipse it was meant to break up."""
    d = math.hypot(u - 0.5, v - 0.5) * 2.0
    return smoothstep(1.0, 0.72, d) ** (1.0 / power)


# -------------------------------------------------------------------- gobos --

def gobo_grate():
    """Industrial floor grate seen from below: hard bars, soft dust between."""
    rows = []
    for j in range(SIZE):
        v = j / (SIZE - 1.0)
        row = bytearray()
        for i in range(SIZE):
            u = i / (SIZE - 1.0)
            bars = 0.5 + 0.5 * math.cos(v * math.pi * 2.0 * 9.0)
            bars = smoothstep(0.24, 0.52, bars)
            cross = 0.5 + 0.5 * math.cos(u * math.pi * 2.0 * 3.0)
            cross = 0.45 + 0.55 * smoothstep(0.05, 0.35, cross)
            dust = 0.78 + 0.34 * fbm(u, v, 3, octaves=4, base=8)
            row.append(clamp8(bars * cross * dust * falloff(u, v)))
        rows.append(row)
    return rows


def gobo_slats():
    """Angled louvre slats — for lights mounted behind vent modules."""
    rows = []
    for j in range(SIZE):
        v = j / (SIZE - 1.0)
        row = bytearray()
        for i in range(SIZE):
            u = i / (SIZE - 1.0)
            t = v * 0.94 + u * 0.34
            s = 0.5 + 0.5 * math.cos(t * math.pi * 2.0 * 14.0)
            s = smoothstep(0.18, 0.46, s)
            # A couple of slats are bent/missing; perfect repetition is the tell.
            band = int(t * 14.0) % 7
            if band == 3:
                s *= 0.35
            grime = 0.8 + 0.2 * fbm(u, v, 11, octaves=3, base=6)
            row.append(clamp8(s * grime * falloff(u, v, 1.3)))
        rows.append(row)
    return rows


def gobo_dust():
    """No hard pattern — just cloudy density so a 'clean' light still breathes.
    Never leave a key light with a flat projector; the eye finds the ellipse."""
    rows = []
    for j in range(SIZE):
        v = j / (SIZE - 1.0)
        row = bytearray()
        for i in range(SIZE):
            u = i / (SIZE - 1.0)
            n = fbm(u, v, 23, octaves=5, base=3)
            n = 0.62 + 0.78 * n
            row.append(clamp8(min(1.0, n) * falloff(u, v, 1.2)))
        rows.append(row)
    return rows


def gobo_aperture():
    """Hard-edged rectangular aperture with mullions — reads as light spilling
    through a service hatch or a data-vault window."""
    rows = []
    for j in range(SIZE):
        v = j / (SIZE - 1.0)
        row = bytearray()
        for i in range(SIZE):
            u = i / (SIZE - 1.0)
            inside = 1.0
            if not (0.16 < u < 0.84 and 0.10 < v < 0.90):
                inside = 0.0
            edge = min(abs(u - 0.16), abs(u - 0.84), abs(v - 0.10), abs(v - 0.90))
            inside *= min(1.0, edge / 0.03)
            mull = 1.0
            for m in (0.38, 0.62):
                mull *= min(1.0, abs(u - m) / 0.022)
            for m in (0.42,):
                mull *= min(1.0, abs(v - m) / 0.018)
            n = 0.82 + 0.18 * fbm(u, v, 7, octaves=4, base=6)
            row.append(clamp8(inside * mull * n))
        rows.append(row)
    return rows


def gobo_circuit():
    """Trace-network gobo. Shone down a wall it throws the circuit motif across
    geometry the modules do not cover, which keeps the language consistent in
    rooms that are mostly plain panel."""
    rows = []
    lines_h = [0.18, 0.37, 0.55, 0.79]
    lines_v = [0.22, 0.44, 0.68, 0.88]
    for j in range(SIZE):
        v = j / (SIZE - 1.0)
        row = bytearray()
        for i in range(SIZE):
            u = i / (SIZE - 1.0)
            acc = 0.06
            for y in lines_h:
                acc = max(acc, 1.0 - min(1.0, abs(v - y) / 0.012))
            for x in lines_v:
                acc = max(acc, 1.0 - min(1.0, abs(u - x) / 0.010))
            acc *= 0.35 + 0.65 * fbm(u, v, 31, octaves=3, base=5)
            row.append(clamp8(min(1.0, acc) * falloff(u, v, 1.5)))
        rows.append(row)
    return rows


def surface_normal():
    """Detail normal map for every hard surface in the kit.

    Two things live in here. A brushed direction (long thin streaks along U) —
    which is what makes a specular highlight stretch along a panel instead of
    sitting on it as a round blob, and is most of why machined metal looks
    machined. And a fine isotropic grain for cast/blasted areas. Neither is
    strong; at NORMAL_MAP_DEPTH ~0.55 you never see the texture, you only see
    that the highlight is no longer perfect."""
    heights = []
    for j in range(SIZE):
        v = j / (SIZE - 1.0)
        row = []
        for i in range(SIZE):
            u = i / (SIZE - 1.0)
            # Anisotropic streaks: cheap frequency ratio does the stretching.
            brushed = fbm(u * 1.0, v * 26.0, 5, octaves=3, base=8)
            grain = fbm(u, v, 17, octaves=4, base=32)
            row.append(0.62 * brushed + 0.38 * grain)
        heights.append(row)

    rows = []
    strength = 3.2
    for j in range(SIZE):
        row = bytearray()
        for i in range(SIZE):
            hl = heights[j][(i - 1) % SIZE]
            hr = heights[j][(i + 1) % SIZE]
            hd = heights[(j - 1) % SIZE][i]
            hu = heights[(j + 1) % SIZE][i]
            nx = (hl - hr) * strength
            ny = (hd - hu) * strength
            nz = 1.0
            inv = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz)
            row += bytes((clamp8(nx * inv * 0.5 + 0.5),
                          clamp8(ny * inv * 0.5 + 0.5),
                          clamp8(nz * inv * 0.5 + 0.5)))
        rows.append(row)
    return rows


def main():
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "surface_normal.png")
    write_png(path, surface_normal(), rgb=True)
    print("wrote", path)
    for name, fn in (("gobo_grate", gobo_grate), ("gobo_slats", gobo_slats),
                     ("gobo_dust", gobo_dust), ("gobo_aperture", gobo_aperture),
                     ("gobo_circuit", gobo_circuit)):
        path = os.path.join(OUT, name + ".png")
        write_png(path, fn())
        print("wrote", path)


if __name__ == "__main__":
    main()
