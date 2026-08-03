#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — SOUND LAB: measure a directory of audio.
#
#   python3 tools/soundlab/analyze.py                       # whole library
#   python3 tools/soundlab/analyze.py --root some/dir --out /tmp/x.json
#   python3 tools/soundlab/analyze.py --verify-reproducible # determinism check
#
# Writes a JSON array of descriptor rows and a CSV of the same, and prints a
# one-line-per-file summary. Nothing is written inside assets/.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import classes  # noqa: E402
import descriptors as D  # noqa: E402
from dsp import REPO  # noqa: E402

AUDIO_EXT = (".ogg", ".wav", ".flac", ".mp3")


def walk(root: str) -> list[str]:
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.lower().endswith(AUDIO_EXT):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def analyse_tree(root: str, quiet: bool = False) -> list[dict]:
    rows = []
    for path in walk(root):
        rel = os.path.relpath(path, root)
        try:
            d = D.describe(path)
        except Exception as exc:                      # noqa: BLE001
            print("[soundlab] FAILED %s: %s" % (rel, exc), file=sys.stderr)
            continue
        d["rel"] = rel.replace(os.sep, "/")
        d["cls"], d["score"], fails = classes.score(d["rel"], d)
        d["fails"] = fails
        d.pop("path", None)
        rows.append(d)
        if not quiet:
            sc = "  n/a" if d["score"] != d["score"] else "%5.3f" % d["score"]
            print("[soundlab] %s %-22s %s" % (sc, d["cls"], d["rel"]))
    return rows


def write_out(rows: list[dict], out_json: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(out_json)), exist_ok=True)
    with open(out_json, "w") as fh:
        json.dump(rows, fh, indent=1, sort_keys=True)
    csv_path = os.path.splitext(out_json)[0] + ".csv"
    cols = ["rel", "cls", "score"] + D.FEATURES
    with open(csv_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for r in rows:
            w.writerow([r.get(c, "") for c in cols])
    print("[soundlab] wrote %s and %s (%d files)" % (out_json, csv_path, len(rows)))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(REPO, "assets", "audio"))
    ap.add_argument("--out", default="")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--verify-reproducible", action="store_true",
                    help="measure everything twice and assert the JSON is identical")
    args = ap.parse_args()

    t0 = time.time()
    rows = analyse_tree(args.root, quiet=args.quiet)
    print("[soundlab] %d files in %.1f s" % (len(rows), time.time() - t0))

    if args.verify_reproducible:
        again = analyse_tree(args.root, quiet=True)
        a = json.dumps(rows, sort_keys=True)
        b = json.dumps(again, sort_keys=True)
        if a != b:
            print("[soundlab] NOT REPRODUCIBLE — descriptor output differs run to run",
                  file=sys.stderr)
            return 1
        print("[soundlab] reproducible: two full passes byte-identical (%d chars)" % len(a))

    if args.out:
        write_out(rows, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
