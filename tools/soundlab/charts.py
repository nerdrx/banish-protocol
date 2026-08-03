#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — SOUND LAB: pictures of the numbers.
#
#   python3 tools/soundlab/charts.py --library OUT/library.json --out OUT/charts
#   python3 tools/soundlab/charts.py --compare a.ogg b.ogg --out OUT/charts
#
# Nobody adopts a parameter set because a JSON file said 0.94. These are the
# charts that make the audit arguable:
#
#   sheet_<name>.png    per-file: waveform, spectrogram, the centroid TRAJECTORY
#                       drawn on top of the spectrogram (the descriptor the
#                       whole suite is built around), band balance, envelope.
#   map_classes.png     the whole library projected to 2D by PCA of the
#                       perceptual descriptors — the clustering, visible.
#   scores.png          class scores, worst class first.
#   defects.png         the defect census as a bar chart.
#   compare_<a>_vs_<b>.png  incumbent against candidate, same axes.
#
# matplotlib with the Agg backend: no display is opened, no GPU is touched, and
# nothing here can collide with a gamescope capture.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import classes  # noqa: E402
import descriptors as D  # noqa: E402
from dsp import BANDS, RATE, band_energies, envelope_rms, load, stft  # noqa: E402

# The interface's own palette — phosphor on black, so a chart pasted into the
# design doc looks like it came from the same game.
BG = "#0b0e0c"
FG = "#c8d6c0"
ACCENT = "#7fe08a"
WARN = "#e0a15a"
BAD = "#e05a5a"
plt.rcParams.update({
    "figure.facecolor": BG, "axes.facecolor": BG, "savefig.facecolor": BG,
    "text.color": FG, "axes.labelcolor": FG, "xtick.color": FG,
    "ytick.color": FG, "axes.edgecolor": "#3a463a", "grid.color": "#222a22",
    "font.size": 8, "axes.titlesize": 9,
})


def sheet(path: str, out_png: str, title: str = "") -> None:
    """One page per sound. The centroid trajectory is drawn ON the spectrogram
       because that juxtaposition is the entire argument: you can see whether
       the bright energy dies before the low energy does."""
    x, rate = load(path)
    d = D.describe_signal(x, rate)
    # Same 1024/128 analysis the descriptor suite uses, so the blue line on
    # this picture is literally the number in the table below it.
    mag, freqs, times = stft(x, n_fft=1024, hop=128)
    p = mag ** 2
    cf = (freqs[:, None] * p).sum(axis=0) / np.maximum(p.sum(axis=0), 1e-30)
    frame_e = p.sum(axis=0)
    live = frame_e > frame_e.max() * 1e-4

    fig = plt.figure(figsize=(11, 7.2))
    gs = fig.add_gridspec(3, 2, height_ratios=[1.0, 2.0, 1.2], hspace=0.42,
                          wspace=0.22)

    ax = fig.add_subplot(gs[0, :])
    t = np.arange(len(x)) / rate
    ax.plot(t, x, lw=0.4, color=ACCENT)
    env, te = envelope_rms(x, win_ms=3.0, hop_ms=1.0)
    ax.plot(te, env, lw=1.0, color=WARN)
    ax.plot(te, -env, lw=1.0, color=WARN)
    ax.set_xlim(0, t[-1] if len(t) else 1)
    ax.set_title("%s   —   %.2f s, %.1f LUFS, crest %.1f dB, attack %.2f ms, "
                 "peak @ %.0f ms" % (title or os.path.basename(path),
                                     d["duration_s"], d["lufs_i"],
                                     d["crest_db"], d["attack_ms"],
                                     d["peak_time_ms"]))
    ax.grid(alpha=0.3)

    ax = fig.add_subplot(gs[1, :])
    S = 20 * np.log10(np.maximum(mag, 1e-9))
    S -= S.max()
    ax.pcolormesh(times, freqs, S, vmin=-80, vmax=0, cmap="magma",
                  shading="auto", rasterized=True)
    ax.plot(times[live], cf[live], color="#00e5ff", lw=1.4,
            label="spectral centroid")
    ax.set_yscale("log")
    ax.set_ylim(20, 20000)
    ax.set_ylabel("Hz")
    ax.set_xlabel("s")
    ax.legend(loc="upper right", facecolor=BG, edgecolor="#3a463a",
              labelcolor=FG, fontsize=7)
    verdict = ("centroid FALLS %.2f oct — physical" % d["centroid_drop_oct"]
               if d["centroid_drop_oct"] > 0.3 else
               "centroid RISES %.2f oct" % (-d["centroid_drop_oct"])
               if d["centroid_drop_oct"] < -0.3 else
               "centroid STATIC (%.2f oct) — the 'generic' tell"
               % d["centroid_drop_oct"])
    ax.set_title("spectrogram + centroid trajectory   —   %s" % verdict)

    ax = fig.add_subplot(gs[2, 0])
    be = band_energies(x)
    names = [b[0] for b in BANDS]
    vals = [10 * np.log10(max(be[n], 1e-9)) for n in names]
    cols = [BAD if (n in ("sub", "low") and v < -17) else ACCENT
            for n, v in zip(names, vals)]
    ax.bar(names, vals, color=cols)
    ax.axhline(-17, color=WARN, lw=0.8, ls="--")
    ax.set_ylim(-45, 2)
    ax.set_ylabel("dB rel. total")
    ax.set_title("band balance  (sub+low = %.1f dB)" % d["weight_db"])
    ax.grid(alpha=0.3, axis="y")

    ax = fig.add_subplot(gs[2, 1])
    ax.axis("off")
    keys = ["attack_ms", "peak_time_ms", "decay_t60_ms", "decay_linearity",
            "crest_db", "env_range_db", "centroid_hz", "centroid_drop_oct",
            "centroid_drift_oct_per_s", "flux", "bw20_oct", "flatness",
            "hnr_db", "sharpness_acum", "roughness"]
    txt = "\n".join("%-26s %10.3f" % (k, d[k]) for k in keys)
    ax.text(0.0, 1.0, txt, family="monospace", fontsize=7.5, va="top",
            color=FG)
    fig.savefig(out_png, dpi=130, bbox_inches="tight")
    plt.close(fig)


def compare(paths: list[str], out_png: str, labels: list[str] | None = None) -> None:
    """Several sounds on the same axes. Spectrograms stacked, centroid overlaid,
       band balance side by side — the picture you use to decide whether a
       candidate is actually an improvement on the incumbent."""
    n = len(paths)
    labels = labels or [os.path.basename(p) for p in paths]
    fig = plt.figure(figsize=(4.4 * n, 6.4))
    gs = fig.add_gridspec(3, n, height_ratios=[0.7, 2.0, 1.0], hspace=0.45,
                          wspace=0.25)
    for i, path in enumerate(paths):
        x, rate = load(path)
        d = D.describe_signal(x, rate)
        mag, freqs, times = stft(x, n_fft=1024, hop=128)
        p = mag ** 2
        cf = (freqs[:, None] * p).sum(axis=0) / np.maximum(p.sum(axis=0), 1e-30)
        live = p.sum(axis=0) > p.sum(axis=0).max() * 1e-4

        ax = fig.add_subplot(gs[0, i])
        ax.plot(np.arange(len(x)) / rate, x, lw=0.35, color=ACCENT)
        ax.set_title("%s\n%.2f s | crest %.1f dB | atk %.1f ms"
                     % (labels[i], d["duration_s"], d["crest_db"], d["attack_ms"]),
                     fontsize=8)
        ax.grid(alpha=0.25)

        ax = fig.add_subplot(gs[1, i])
        S = 20 * np.log10(np.maximum(mag, 1e-9))
        S -= S.max()
        ax.pcolormesh(times, freqs, S, vmin=-80, vmax=0, cmap="magma",
                      shading="auto", rasterized=True)
        ax.plot(times[live], cf[live], color="#00e5ff", lw=1.3)
        ax.set_yscale("log")
        ax.set_ylim(20, 20000)
        if i == 0:
            ax.set_ylabel("Hz")
        ax.set_title("centroid %+.2f oct over decay | flux %.3f"
                     % (d["centroid_drop_oct"], d["flux"]), fontsize=8)

        ax = fig.add_subplot(gs[2, i])
        be = band_energies(x)
        names = [b[0] for b in BANDS]
        vals = [10 * np.log10(max(be[nm], 1e-9)) for nm in names]
        ax.bar(names, vals, color=[BAD if (nm in ("sub", "low") and v < -17)
                                   else ACCENT for nm, v in zip(names, vals)])
        ax.set_ylim(-45, 2)
        ax.axhline(-17, color=WARN, lw=0.8, ls="--")
        ax.tick_params(axis="x", rotation=45)
        if i == 0:
            ax.set_ylabel("dB rel. total")
    fig.savefig(out_png, dpi=130, bbox_inches="tight")
    plt.close(fig)


def library_map(rows: list[dict], out_png: str) -> None:
    """PCA of the perceptual descriptors. The audit's clustering, seen.

       PCA rather than t-SNE on purpose: the axes stay linear combinations of
       real descriptors, so the loadings printed under the plot mean something,
       and two runs give the same picture."""
    m = D.standardise(D.feature_matrix(rows, D.SIMILARITY_FEATURES))
    m = m - m.mean(axis=0)
    U, S, Vt = np.linalg.svd(m, full_matrices=False)
    xy = U[:, :2] * S[:2]
    var = (S ** 2) / (S ** 2).sum()

    cls_list = sorted({r["cls"] for r in rows})
    cmap = plt.get_cmap("turbo")
    # 26 classes is more than any colormap can separate, so shape carries half
    # the identity. Same reason DESIGN.md's safety law says colour is never the
    # only channel — it applies to our own instruments too.
    marks = ["o", "s", "^", "D", "v", "P", "X", "*"]
    fig, ax = plt.subplots(figsize=(11.5, 8))
    for i, c in enumerate(cls_list):
        idx = [k for k, r in enumerate(rows) if r["cls"] == c]
        ax.scatter(xy[idx, 0], xy[idx, 1], s=30, marker=marks[i % len(marks)],
                   color=cmap((i % 7) / 6.0 * 0.85 + 0.07 * (i // 7)), label=c,
                   edgecolors="none", alpha=0.9)
    # Label only the tightest clusters — the ones the audit complains about —
    # and only one member of each, or the labels stack into a smear.
    dist = np.sqrt(((xy[:, None, :] - xy[None, :, :]) ** 2).sum(axis=2))
    np.fill_diagonal(dist, np.inf)
    nn = dist.min(axis=1)
    labelled: list[np.ndarray] = []
    for k in np.argsort(nn):
        if len(labelled) >= 12:
            break
        if any(np.hypot(*(xy[k] - q)) < 0.6 for q in labelled):
            continue
        labelled.append(xy[k])
        ax.annotate(os.path.basename(rows[k]["rel"]).replace(".ogg", ""),
                    xy[k], fontsize=6.0, color="#ffffff", alpha=0.85,
                    xytext=(4, 4), textcoords="offset points")
    ax.set_xlabel("PC1 (%.0f %% of variance)" % (100 * var[0]))
    ax.set_ylabel("PC2 (%.0f %%)" % (100 * var[1]))
    ax.set_title("The library in perceptual-descriptor space — points that sit "
                 "on top of each other sound the same")
    ax.legend(ncol=2, fontsize=6.5, facecolor=BG, edgecolor="#3a463a",
              labelcolor=FG, loc="best")
    ax.grid(alpha=0.25)
    top = np.argsort(-np.abs(Vt[0]))[:5]
    ax.text(0.01, 0.01, "PC1 driven by: " + ", ".join(
        "%s(%+.2f)" % (D.SIMILARITY_FEATURES[i], Vt[0][i]) for i in top),
        transform=ax.transAxes, fontsize=6.5, color=FG, alpha=0.8)
    fig.savefig(out_png, dpi=130, bbox_inches="tight")
    plt.close(fig)


def score_chart(rows: list[dict], out_png: str) -> None:
    scored = [r for r in rows if r["score"] == r["score"]]
    by: dict[str, list[float]] = {}
    for r in scored:
        by.setdefault(r["cls"], []).append(r["score"])
    order = sorted(by, key=lambda c: np.median(by[c]))
    fig, ax = plt.subplots(figsize=(9, 0.34 * len(order) + 2.0))
    for i, c in enumerate(order):
        v = by[c]
        col = BAD if np.median(v) < 0.6 else WARN if np.median(v) < 0.8 else ACCENT
        ax.barh(i, np.median(v), color=col, height=0.6, alpha=0.85)
        ax.scatter(v, [i] * len(v), s=12, color=FG, zorder=3, alpha=0.8)
    ax.set_yticks(range(len(order)))
    ax.set_yticklabels(order, fontsize=7.5)
    ax.set_xlim(0, 1.02)
    ax.set_xlabel("class objective score (bar = median, dots = individual files)")
    ax.set_title("Where the shipped library stands, worst class first")
    ax.grid(alpha=0.25, axis="x")
    fig.savefig(out_png, dpi=130, bbox_inches="tight")
    plt.close(fig)


def defect_chart(rows: list[dict], out_png: str) -> None:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import audit  # noqa: PLC0415
    census: dict[str, int] = {}
    for r in rows:
        for f in audit.flags(r):
            census[f.split(" (")[0]] = census.get(f.split(" (")[0], 0) + 1
    order = sorted(census, key=lambda k: census[k])
    fig, ax = plt.subplots(figsize=(8, 0.4 * len(order) + 1.8))
    ax.barh(range(len(order)), [census[k] for k in order], color=BAD, alpha=0.85)
    for i, k in enumerate(order):
        ax.text(census[k] + 0.6, i, str(census[k]), va="center", fontsize=8,
                color=FG)
    ax.set_yticks(range(len(order)))
    ax.set_yticklabels(order, fontsize=8)
    ax.set_xlabel("files affected (of %d)" % len(rows))
    ax.set_title("Defect census across the shipped library")
    ax.grid(alpha=0.25, axis="x")
    fig.savefig(out_png, dpi=130, bbox_inches="tight")
    plt.close(fig)


def search_chart(manifest: dict, out_png: str) -> None:
    """Optimiser convergence + where the shortlist lands against the incumbents.
       The right-hand panel is the one that matters: if the candidates are not
       clearly above the shipped assets, the search bought nothing."""
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.2))
    ax = axes[0]
    ch = manifest.get("history_cmaes") or []
    if ch:
        g = [c[0] * (manifest["evals_per_method"] / max(ch[-1][0], 1)) for c in ch]
        ax.plot(g, [c[3] for c in ch], color=ACCENT, lw=1.6, label="CMA-ES best so far")
        ax.plot(g, [c[2] for c in ch], color=ACCENT, lw=0.7, alpha=0.5,
                label="CMA-ES generation median")
    rh = manifest.get("history_random") or []
    if rh:
        ax.plot([c[0] for c in rh], [c[3] for c in rh], color=WARN, lw=1.6,
                ls="--", label="random best so far")
    ax.set_xlabel("evaluations")
    ax.set_ylabel("objective")
    ax.set_title("%s — convergence" % manifest["recipe"])
    ax.legend(fontsize=7, facecolor=BG, edgecolor="#3a463a", labelcolor=FG)
    ax.grid(alpha=0.25)

    ax = axes[1]
    inc = manifest.get("incumbents") or []
    cand = manifest.get("candidates") or []
    if inc:
        ax.barh(range(len(inc)), [i["fitness"] for i in inc], color=BAD,
                alpha=0.85, height=0.6)
        ax.set_yticks(range(len(inc) + len(cand)))
        ax.set_yticklabels([os.path.basename(i["rel"]) for i in inc]
                           + ["cand %02d" % c["rank"] for c in cand], fontsize=7)
    if cand:
        ax.barh(range(len(inc), len(inc) + len(cand)),
                [c.get("fitness") or c["score"] for c in cand], color=ACCENT,
                alpha=0.85, height=0.6)
        if not inc:
            ax.set_yticks(range(len(cand)))
            ax.set_yticklabels(["cand %02d" % c["rank"] for c in cand], fontsize=7)
    ax.set_xlim(0, 1.02)
    ax.set_xlabel("class fitness (red = shipped, green = candidate)")
    ax.set_title("shortlist vs the assets we ship today")
    ax.grid(alpha=0.25, axis="x")
    fig.savefig(out_png, dpi=130, bbox_inches="tight")
    plt.close(fig)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--library", default="")
    ap.add_argument("--sheets", nargs="*", default=[],
                    help="audio files to render a per-sound sheet for")
    ap.add_argument("--compare", nargs="*", default=[])
    ap.add_argument("--search-manifest", nargs="*", default=[])
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    if args.library:
        rows = json.load(open(args.library))
        library_map(rows, os.path.join(args.out, "map_classes.png"))
        score_chart(rows, os.path.join(args.out, "scores.png"))
        defect_chart(rows, os.path.join(args.out, "defects.png"))
        print("[charts] library map, scores, defects -> %s" % args.out)

    for p in args.sheets:
        name = os.path.splitext(os.path.basename(p))[0]
        out = os.path.join(args.out, "sheet_%s.png" % name)
        sheet(p, out)
        print("[charts] %s" % out)

    if args.compare:
        name = "_vs_".join(os.path.splitext(os.path.basename(p))[0]
                           for p in args.compare)[:90]
        out = os.path.join(args.out, "compare_%s.png" % name)
        compare(args.compare, out)
        print("[charts] %s" % out)

    for mf in args.search_manifest:
        m = json.load(open(mf))
        out = os.path.join(args.out, "search_%s.png" % m["recipe"])
        search_chart(m, out)
        print("[charts] %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
