#!/usr/bin/env python3
"""Score the three gi_probe renders. See tools/fidelity_bench/gi_probe.sh."""

import os
import sys

import numpy as np
from PIL import Image

# Fixed regions of the 1280x720 frame, chosen once and never moved: a floor
# patch on the red side, a floor patch on the blue side, and the shadowed face
# of the tall block. All three are surfaces the single spot cannot reach.
REGIONS = {
    "floor-left  (red side) ": (150, 520, 420, 690),
    "floor-right (blue side)": (860, 520, 1130, 690),
    "block shadowed face    ": (430, 330, 610, 520),
    "ceiling (direct, control)": (500, 30, 800, 110),
}


def stats(img: np.ndarray, box) -> tuple[float, float]:
    x0, y0, x1, y1 = box
    p = img[y0:y1, x0:x1, :3]
    lum = (0.2126 * p[..., 0] + 0.7152 * p[..., 1] + 0.0722 * p[..., 2]).mean()
    return float(lum), float(p[..., 0].mean() - p[..., 2].mean())


def main() -> None:
    out = sys.argv[1]
    modes = ["off", "sdfgi", "voxelgi"]
    data = {}
    for m in modes:
        path = os.path.join(out, "gi_%s.png" % m)
        if not os.path.exists(path):
            print("MISSING", path)
            continue
        data[m] = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0

    print()
    print("%-26s %10s %10s %10s   %10s %10s %10s" % (
        "region", "off L", "sdfgi L", "voxel L", "off R-B", "sdfgi R-B", "voxel R-B"))
    print("-" * 100)
    for name, box in REGIONS.items():
        lums, rbs = [], []
        for m in modes:
            if m in data:
                l, rb = stats(data[m], box)
            else:
                l, rb = float("nan"), float("nan")
            lums.append(l)
            rbs.append(rb)
        print("%-26s %10.4f %10.4f %10.4f   %+10.4f %+10.4f %+10.4f" % (
            name, lums[0], lums[1], lums[2], rbs[0], rbs[1], rbs[2]))

    print()
    for m in ("sdfgi", "voxelgi"):
        if m not in data or "off" not in data:
            continue
        fl_off, rb_off_l = stats(data["off"], REGIONS["floor-left  (red side) "])
        fr_off, rb_off_r = stats(data["off"], REGIONS["floor-right (blue side)"])
        fl, rb_l = stats(data[m], REGIONS["floor-left  (red side) "])
        fr, rb_r = stats(data[m], REGIONS["floor-right (blue side)"])
        # A ratio is meaningless when the control is exactly black (which is the
        # point of the control), so report the absolute lift too.
        base = (fl_off + fr_off) / 2.0
        gain = (fl + fr) / 2.0
        lift = gain / base if base > 1e-4 else float("inf")
        tint = (rb_l - rb_r) - (rb_off_l - rb_off_r)
        frame = data[m]
        bad = int(np.isnan(frame).sum() + np.isinf(frame).sum())
        print("%-8s floor luminance %0.4f vs control %0.4f (%s) | colour separation "
              "(left redder than right, delta vs no-GI): %+0.4f | non-finite pixels: %d"
              % (m.upper(), gain, base,
                 "control is black" if lift == float("inf") else "%.2fx" % lift,
                 tint, bad))
    print()
    print("PASS criteria: floor lift > ~1.3x AND colour separation > +0.005 AND "
          "0 non-finite pixels.")


if __name__ == "__main__":
    main()
