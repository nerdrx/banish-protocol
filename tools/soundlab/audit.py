#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — SOUND LAB: the library health report.
#
#   python3 tools/soundlab/analyze.py --out OUT/library.json
#   python3 tools/soundlab/audit.py OUT/library.json --out OUT/HEALTH_REPORT.md
#
# Turns 167 descriptor rows into an argument: which assets are weak, WHY they
# are weak in words a sound designer can act on, and — the part nothing else in
# the pipeline can see — which assets are duplicates of each other in every way
# that matters perceptually.
#
# THE CLUSTERING IS THE POINT
# ---------------------------
# "Generic" is very often not a property of any single sound. It is a property
# of a SET: six pickup variations that measure within a tenth of a sigma of each
# other are, to the ear, one sound played six times, and the player learns that
# in about four minutes. The audit therefore reports two different things:
#
#   VARIANT COLLAPSE   files in the same numbered family (foo_01..foo_06) whose
#                      descriptor spread is near zero. These are supposed to be
#                      different and are not.
#   CROSS-FAMILY CLONE two unrelated sounds that measure the same. These are
#                      supposed to be different KINDS of thing and are not.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import json
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import classes  # noqa: E402
import descriptors as D  # noqa: E402

VARIANT_RE = re.compile(r"^(.*?)_(\d{2,3})$")

# Universal defect flags. Deliberately class-agnostic: these are the things that
# are wrong about a sound no matter what it is meant to be. Each is (name,
# predicate, human sentence).
LOOPISH = ("ambience_bed", "creature_presence", "creature_locomotion",
           "player_body_loop", "music", "voice_mother")


def flags(r: dict) -> list[str]:
    out = []
    cls = r["cls"]
    loopy = cls in LOOPISH or r["rel"].endswith("_loop.ogg")
    if r["weight_db"] < -17.0:
        out.append("NO-LOW-END (sub+low = %.0f dB of total; nothing under "
                   "250 Hz to give it body)" % r["weight_db"])
    if r["flux"] < 0.02 and r["centroid_drift_oct_per_s"] < 0.5:
        out.append("STATIC-SPECTRUM (flux %.3f, centroid drift %.2f oct/s; the "
                   "spectrum does not move, which is the commonest cause of "
                   "'generic')" % (r["flux"], r["centroid_drift_oct_per_s"]))
    if not loopy and r["attack_ms"] > 20.0 and r["peak_time_ms"] > 30.0:
        out.append("NO-TRANSIENT (10-90%% rise %.0f ms, peak at %.0f ms; the "
                   "loudest moment arrives long after the event)"
                   % (r["attack_ms"], r["peak_time_ms"]))
    if r["crest_db"] < 10.0:
        out.append("SQUASHED (crest %.1f dB; no peak-to-average left to hit "
                   "with)" % r["crest_db"])
    if r["bw20_oct"] < 2.5:
        out.append("NARROW-BAND (%.1f octaves within 20 dB of peak; reads as a "
                   "filtered tone)" % r["bw20_oct"])
    if not loopy and r["duration_s"] < 0.06:
        out.append("TOO-SHORT (%.0f ms; no tail, so no implied space)"
                   % (r["duration_s"] * 1000.0))
    if r["true_peak_dbtp"] > -1.0:
        out.append("TRUE-PEAK %.2f dBTP (over the -1.5 ceiling make_sfx.py "
                   "sets; risks clipping on Vorbis decode)" % r["true_peak_dbtp"])
    if r["sharpness_acum"] > 3.4:
        out.append("SHRILL (%.2f acum, above the listener-fatigue ceiling)"
                   % r["sharpness_acum"])
    if not loopy and r["env_range_db"] < 8.0:
        out.append("FLAT-ENVELOPE (%.1f dB between its loud and quiet moments)"
                   % r["env_range_db"])
    return out


def variant_family(rel: str) -> str | None:
    base = os.path.splitext(os.path.basename(rel))[0]
    m = VARIANT_RE.match(base)
    if not m:
        return None
    return os.path.dirname(rel) + "/" + m.group(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("json", help="output of analyze.py")
    ap.add_argument("--out", default="")
    ap.add_argument("--clone-sigma", type=float, default=0.45,
                    help="descriptor distance (in sigma per feature) below which "
                         "two unrelated sounds are called clones")
    ap.add_argument("--variant-sigma", type=float, default=0.30,
                    help="mean intra-family distance below which a numbered "
                         "variant set is called collapsed")
    args = ap.parse_args()

    rows = json.load(open(args.json))
    rows.sort(key=lambda r: r["rel"])
    L: list[str] = []

    def w(s: str = "") -> None:
        L.append(s)

    scored = [r for r in rows if r["score"] == r["score"]]
    unscored = [r for r in rows if r["score"] != r["score"]]

    w("# BANISH PROTOCOL — sound library health report")
    w()
    w("Generated by `tools/soundlab/audit.py`. %d files measured, %d graded "
      "against a class objective, %d measured but deliberately not graded "
      "(music and MOTHER's voice belong to other milestones and other "
      "aesthetics)." % (len(rows), len(scored), len(unscored)))
    w()
    w("Scores are 0..1 against the objective function for the file's class in "
      "`tools/soundlab/classes.py`, where every criterion carries a written "
      "justification tagged [PHYS] (physics/psychoacoustics), [FIT] (read off "
      "our own best assets) or [CALL] (a BANISH PROTOCOL judgement). A score is "
      "a PRIORITY ORDER, not a verdict — see the closing section.")
    w()

    # ------------------------------------------------------------- headline --
    w("## 0. The headline")
    w()
    static = [r for r in rows if r["centroid_drop_oct"] < 0.2]
    thin = [r for r in rows if r["weight_db"] < -17.0]
    narrow = [r for r in rows if r["bw20_oct"] < 2.5]
    w("Three numbers, and between them they are most of why the set feels "
      "generic:")
    w()
    w("1. **%d of %d files (%.0f %%) have a spectral centroid that does not "
      "fall over their own decay.** Every struck object in the physical world "
      "darkens as it rings out — the bright partials radiate away first. A "
      "layer stack with one envelope over everything does not, and the ear "
      "reads that as synthetic no matter how the sound is EQ'd or how loud it "
      "is. This is the single most fixable thing in the library, and the fix "
      "is structural rather than cosmetic: give each layer its own decay, "
      "shortest on the brightest."
      % (len(static), len(rows), 100.0 * len(static) / len(rows)))
    w("2. **%d files have essentially nothing below 250 Hz** (sub+low under "
      "-17 dB of total power). Weight is not a loudness property; it is a "
      "band property, and a sound without that band cannot be made heavy "
      "downstream." % len(thin))
    w("3. **%d files sit inside 2.5 octaves at -20 dB.** Real contact events "
      "are broadband. A narrow-band one-shot is a filtered tone with a name."
      % len(narrow))
    w()
    med_rough = float(np.median([r["roughness"] for r in rows]))
    w("A fourth, softer observation: the library's median roughness is %.2f. "
      "Roughness — amplitude modulation of the critical bands around 70 Hz — "
      "is the measurable correlate of 'snarl' and 'grind'. The creature set in "
      "particular is smoother than its own design intent, which is why several "
      "of them measure closer to a synthesiser pad than to an animal." % med_rough)
    w()

    # -------------------------------------------------------------- overview --
    w("## 1. Where the library stands")
    w()
    sc = np.array([r["score"] for r in scored])
    w("| | |")
    w("|---|---|")
    w("| graded files | %d |" % len(scored))
    w("| median score | %.3f |" % float(np.median(sc)))
    w("| below 0.70 | %d |" % int((sc < 0.70).sum()))
    w("| below 0.50 | %d |" % int((sc < 0.50).sum()))
    w("| total runtime | %.0f s |" % sum(r["duration_s"] for r in rows))
    w()

    by_cls: dict[str, list[dict]] = {}
    for r in rows:
        by_cls.setdefault(r["cls"], []).append(r)
    w("### By class")
    w()
    w("| class | n | median | worst | what the class is graded on |")
    w("|---|---|---|---|---|")
    for cname in sorted(by_cls, key=lambda c: (
            np.median([r["score"] for r in by_cls[c]])
            if by_cls[c][0]["score"] == by_cls[c][0]["score"] else 9)):
        rs = by_cls[cname]
        cls = classes.CLASSES.get(cname)
        if rs[0]["score"] != rs[0]["score"]:
            w("| `%s` | %d | not graded | — | %s |" % (cname, len(rs), cls.blurb if cls else ""))
            continue
        s = [r["score"] for r in rs]
        worst = min(rs, key=lambda r: r["score"])
        w("| `%s` | %d | %.3f | %.3f `%s` | %s |" % (
            cname, len(rs), float(np.median(s)), worst["score"],
            os.path.basename(worst["rel"]), (cls.blurb if cls else "").split(".")[0] + "."))
    w()

    # ------------------------------------------------------- top offenders --
    w("## 2. The top offenders — redo these first")
    w()
    w("Ranked by class score, worst first. The bullets under each are the "
      "criteria it failed and the universal defect flags it tripped.")
    w()
    worst = sorted(scored, key=lambda r: r["score"])[:20]
    for i, r in enumerate(worst, 1):
        w("**%d. `%s`** — %s, score **%.3f**  " % (i, r["rel"], r["cls"], r["score"]))
        w("`%.2f s, %.1f LUFS, attack %.1f ms, peak at %.0f ms, crest %.1f dB, "
          "centroid %.0f Hz (%+.2f oct over decay), sub %.1f dB, %.1f acum`  "
          % (r["duration_s"], r["lufs_i"], r["attack_ms"], r["peak_time_ms"],
             r["crest_db"], r["centroid_hz"], r["centroid_drop_oct"],
             r["sub_db"], r["sharpness_acum"]))
        for f in r["fails"]:
            w("  - misses: %s" % f)
        for f in flags(r):
            w("  - **%s**" % f)
        w()

    # ------------------------------------------------------------- defects --
    w("## 3. Defect census")
    w()
    w("Every flag is class-agnostic: these are things that are wrong about a "
      "sound whatever it is meant to be.")
    w()
    census: dict[str, list[str]] = {}
    for r in rows:
        for f in flags(r):
            key = f.split(" (")[0]
            census.setdefault(key, []).append(r["rel"])
    w("| defect | files | examples |")
    w("|---|---|---|")
    for k in sorted(census, key=lambda k: -len(census[k])):
        ex = ", ".join("`%s`" % os.path.basename(p) for p in census[k][:4])
        w("| **%s** | %d | %s%s |" % (k, len(census[k]), ex,
                                      ", ..." if len(census[k]) > 4 else ""))
    w()
    for k in sorted(census, key=lambda k: -len(census[k])):
        w("<details><summary><b>%s</b> — %d files</summary>" % (k, len(census[k])))
        w()
        for p in census[k]:
            w("- `%s`" % p)
        w()
        w("</details>")
        w()

    # ------------------------------------------------------------ loudness --
    w("### Loudness consistency")
    w()
    w("Sounds that mean the same thing should arrive at the same level. A class "
      "spanning more than ~6 LU is a mix problem the player experiences as "
      "'some of these are startling and some I cannot hear', and it is "
      "independent of whether any individual file is good. Measured with the "
      "project's own BS.1770 meter (`tools/audio/bs1770.py`), mono, as the "
      "engine plays them.")
    w()
    w("| class | n | LUFS range | spread | |")
    w("|---|---|---|---|---|")
    for cname in sorted(by_cls, key=lambda c: -(max(r["lufs_i"] for r in by_cls[c])
                                                - min(r["lufs_i"] for r in by_cls[c]))):
        rs = by_cls[cname]
        if len(rs) < 2:
            continue
        lo = min(r["lufs_i"] for r in rs)
        hi = max(r["lufs_i"] for r in rs)
        spread = hi - lo
        mark = "**wide**" if spread > 6.0 else "ok"
        quiet = min(rs, key=lambda r: r["lufs_i"])
        loud = max(rs, key=lambda r: r["lufs_i"])
        w("| `%s` | %d | %.1f .. %.1f | %.1f LU | %s (`%s` vs `%s`) |"
          % (cname, len(rs), lo, hi, spread, mark,
             os.path.basename(quiet["rel"]), os.path.basename(loud["rel"])))
    w()

    # ------------------------------------------------------------ sameness --
    w("## 4. Sameness — the clustering")
    w()
    m = D.feature_matrix(rows, D.SIMILARITY_FEATURES)
    m = D.standardise(m)
    # Distance normalised by feature count, so the number reads as "average
    # standard deviations apart per descriptor" and is comparable across runs.
    dif = m[:, None, :] - m[None, :, :]
    dist = np.sqrt((dif ** 2).mean(axis=2))
    np.fill_diagonal(dist, np.inf)

    fam = [variant_family(r["rel"]) for r in rows]
    w("### 4a. Variant collapse")
    w()
    w("Numbered families (`foo_01`..`foo_06`) exist so repetition does not "
      "register. A family whose members sit within %.2f sigma of each other on "
      "the perceptual descriptors is one sound wearing six filenames."
      % args.variant_sigma)
    w()
    w("| family | n | mean intra-family distance (sigma) | verdict |")
    w("|---|---|---|---|")
    fams: dict[str, list[int]] = {}
    for i, f in enumerate(fam):
        if f:
            fams.setdefault(f, []).append(i)
    collapsed = []
    for f in sorted(fams):
        idx = fams[f]
        if len(idx) < 2:
            continue
        sub = dist[np.ix_(idx, idx)]
        vals = sub[np.isfinite(sub)]
        mu = float(vals.mean())
        verdict = ("**COLLAPSED** — regenerate with real variation"
                   if mu < args.variant_sigma else
                   "thin" if mu < args.variant_sigma * 2 else "ok")
        if mu < args.variant_sigma:
            collapsed.append((f, mu, len(idx)))
        w("| `%s_*` | %d | %.3f | %s |" % (f, len(idx), mu, verdict))
    w()

    w("### 4b. Cross-family clones")
    w()
    w("Pairs of sounds from DIFFERENT families that measure within %.2f sigma. "
      "These are the pairs a player will not be able to tell apart, which "
      "matters most when they mean different things."
      % args.clone_sigma)
    w()
    pairs = []
    n = len(rows)
    for i in range(n):
        for j in range(i + 1, n):
            if fam[i] and fam[i] == fam[j]:
                continue
            if dist[i, j] < args.clone_sigma:
                pairs.append((dist[i, j], i, j))
    pairs.sort()
    if not pairs:
        w("_None under the threshold._")
    else:
        w("| distance | a | b | same meaning? |")
        w("|---|---|---|---|")
        for dv, i, j in pairs[:40]:
            same = "same class (`%s`)" % rows[i]["cls"] if rows[i]["cls"] == rows[j]["cls"] \
                else "**different classes** (`%s` vs `%s`)" % (rows[i]["cls"], rows[j]["cls"])
            w("| %.3f | `%s` | `%s` | %s |" % (dv, rows[i]["rel"], rows[j]["rel"], same))
        if len(pairs) > 40:
            w()
            w("_...and %d more pairs under the threshold._" % (len(pairs) - 40))
    w()

    # Library-wide diversity: mean distance to nearest neighbour, per class.
    w("### 4c. Diversity per class")
    w()
    w("Mean distance from each file to its nearest neighbour ANYWHERE in the "
      "library. A low number means the class has nothing to itself.")
    w()
    nn = dist.min(axis=1)
    w("| class | n | mean nearest-neighbour distance |")
    w("|---|---|---|")
    for cname in sorted(by_cls, key=lambda c: float(np.mean(
            [nn[i] for i, r in enumerate(rows) if r["cls"] == c]))):
        vals = [nn[i] for i, r in enumerate(rows) if r["cls"] == cname]
        w("| `%s` | %d | %.3f |" % (cname, len(vals), float(np.mean(vals))))
    w()

    # ------------------------------------------------------- what to redo --
    w("## 5. The redo list")
    w()
    w("Ordered by how much the game gets back per hour spent. A sound scores "
      "high here if it is weak AND it is heard often AND its class is one the "
      "player uses to make decisions.")
    w()
    w("| priority | asset(s) | why |")
    w("|---|---|---|")
    prio = []
    for r in scored:
        if r["score"] > 0.75:
            continue
        heard = {"weapon_fire": 3.0, "footfall": 3.0, "ui_tick": 2.0,
                 "creature_windup": 2.5, "impact_heavy": 2.0,
                 "creature_locomotion": 2.0, "ui_confirm": 1.5,
                 "creature_hurt": 1.5, "death_shatter": 1.5}.get(r["cls"], 1.0)
        prio.append(((1.0 - r["score"]) * heard, r))
    prio.sort(key=lambda t: -t[0])
    for k, (_p, r) in enumerate(prio[:15], 1):
        why = r["fails"][0] if r["fails"] else (flags(r)[0] if flags(r) else "low score")
        w("| %d | `%s` | %s (score %.2f) |" % (k, r["rel"], why, r["score"]))
    for f, mu, cnt in collapsed:
        w("| — | `%s_*` (%d files) | variant collapse, %.2f sigma apart |" % (f, cnt, mu))
    w()

    # ---------------------------------------------------- the objectives --
    w("## 6. The objective functions, and why")
    w()
    w("Everything above is scored against these. They live in "
      "`tools/soundlab/classes.py` and they are meant to be argued with — "
      "change a number, rerun `audit.py`, and the whole library re-ranks. Each "
      "criterion is tagged:")
    w()
    w("- **[PHYS]** grounded in physics or psychoacoustics — these are the ones "
      "to change only with a reason.")
    w("- **[FIT]** read off our own best-sounding assets. A house style, not a "
      "law.")
    w("- **[CALL]** a BANISH PROTOCOL judgement from DESIGN.md. Another game "
      "could reasonably invert them.")
    w()
    w("A criterion scores 1.0 inside its target and decays exponentially "
      "outside it with the stated tolerance, so the objective is smooth and an "
      "optimiser can climb it — hard cliffs stall a search.")
    w()
    for cname in sorted(by_cls):
        cls = classes.CLASSES.get(cname)
        if not cls or not cls.scored or not cls.crits:
            continue
        w("### `%s` — %s" % (cname, cls.blurb))
        w()
        w("| criterion | want | tolerance | weight | why |")
        w("|---|---|---|---|---|")
        for c in cls.crits:
            tgt = (("%.3g .. %.3g" % c.target) if c.kind == "band"
                   else "%s %.3g" % (c.kind, c.target))
            w("| `%s` | %s | %.3g | %.1f | %s |"
              % (c.feature, tgt, c.soft, c.w, c.why))
        w()

    w("## 7. What this instrument can and cannot judge")
    w()
    w("**Can:** eliminate the objectively broken (no low end, no transient, "
      "narrow-band, clipped, squashed); find the sounds that are perceptually "
      "identical to each other; rank a shortlist by measurable qualities that "
      "genuinely correlate with 'weight', 'punch', 'bite' and 'movement'; and "
      "do all of it over 167 files in about a minute, reproducibly.")
    w()
    w("**Cannot:** tell you whether a sound is RIGHT for the moment it plays "
      "in. Nothing here knows that the Sentinel is supposed to feel "
      "bureaucratic rather than feral, or that the pickup chime has to sit "
      "under a caption that lands on the same beat. A high score means a sound "
      "has no measurable defects; it does not mean it is the one. The last "
      "step is always a human ear, and it is the user's.")
    w()

    text = "\n".join(L) + "\n"
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        open(args.out, "w").write(text)
        print("[soundlab] wrote %s (%d lines)" % (args.out, len(L)))
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
