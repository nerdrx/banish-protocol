#!/usr/bin/env python3
"""Force the right import settings on the generated texture sets.

Run AFTER `godot --headless --import` has created the .import stubs, then
import once more so the settings take:

    godot --headless --import && python3 tools/fix_imports.py && godot --headless --import

Why this exists: Godot's importer defaults are tuned for photographic content
and they are wrong for every map in assets/pbr/.

  normal maps   need `compress/normal_map=1` so they land in RGTC (two-channel,
                reconstructed Z). Left on auto they get S3TC and the green
                channel picks up blocking artefacts that read, at 30 cm, as a
                surface made of 4x4 tiles.
  ORM / height  are DATA. They must not be treated as colour, must not get the
                sRGB curve (the shader declares them without `source_color`,
                which is the actual gate), and must keep mipmaps or the
                roughness channel aliases into shimmering specular.
  everything    gets mipmaps and BPTC. The kit is looked at from 30 cm and from
                40 m in the same frame; without mipmaps the far end of a
                corridor is a sheet of noise that TAA then spends its entire
                budget failing to hold still.
"""

import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# compress/mode 2 = VRAM Compressed; high_quality picks BPTC (BC7 / BC5) over
# S3TC. On the target GPU class BC7 is free and the quality difference in a
# near-black image is the difference between a gradient and a staircase.
COMMON = {
    "compress/mode": "2",
    "compress/high_quality": "true",
    "mipmaps/generate": "true",
    "detect_3d/compress_to": "0",
}

RULES = [
    (re.compile(r"_normal\.png$"), dict(COMMON, **{"compress/normal_map": "1"})),
    (re.compile(r"_orm\.png$"), dict(COMMON, **{"compress/normal_map": "0"})),
    (re.compile(r"_height\.png$"), dict(COMMON, **{"compress/normal_map": "0"})),
    (re.compile(r"_albedo\.png$"), dict(COMMON, **{"compress/normal_map": "0"})),
    # Projector textures alias badly at distance without mipmaps — the reason
    # this rule is here is that look-dev 1 shipped with it as a manual step in
    # INTEGRATION.md, which is exactly the kind of step that gets skipped.
    (re.compile(r"gobo_.*\.png$"), {"mipmaps/generate": "true"}),
    (re.compile(r"surface_normal\.png$"),
     {"compress/normal_map": "1", "mipmaps/generate": "true"}),
    (re.compile(r"lut_.*\.png$"),
     {"compress/mode": "0", "mipmaps/generate": "false",
      "detect_3d/compress_to": "0"}),
]


def patch(path: str, params: dict) -> bool:
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    out = text
    for k, v in params.items():
        pat = re.compile(r"^%s=.*$" % re.escape(k), re.M)
        if pat.search(out):
            out = pat.sub("%s=%s" % (k, v), out)
        else:
            out = out.replace("[params]", "[params]\n%s=%s" % (k, v), 1)
    if out != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(out)
        return True
    return False


def main() -> None:
    n = 0
    for base, _dirs, files in os.walk(os.path.join(ROOT, "assets")):
        for f in files:
            if not f.endswith(".import"):
                continue
            src = f[:-len(".import")]
            for rx, params in RULES:
                if rx.search(src):
                    if patch(os.path.join(base, f), params):
                        n += 1
                        print("  patched %s" % src)
                    break
    print("fix_imports: %d file(s) updated" % n)
    if n == 0:
        print("  (nothing to do — run `godot --headless --import` first)")


if __name__ == "__main__":
    main()
