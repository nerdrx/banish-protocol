#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — SOUND LAB: the search harness.
#
#   python3 tools/soundlab/search.py footfall --out OUT/footfall --evals 4000
#   python3 tools/soundlab/search.py --all --out OUT --evals 4000
#
# This is the piece that answers the actual request — "something out there that
# would help us automatically find the right sounds". It is not magic and it is
# not a generative model: it is a synthesiser whose knobs are addressable
# (synth.py), a definition of what good means for each class (classes.py), a
# meter that can tell (descriptors.py), and an optimiser that turns the crank a
# few thousand times.
#
# TWO OPTIMISERS, ON PURPOSE
# --------------------------
#   random    the baseline. Never skip it: if the clever optimiser cannot beat
#             uniform sampling of the same space, the clever optimiser is
#             broken, and you would never know without the control.
#   cmaes     Covariance Matrix Adaptation. It maintains a Gaussian over the
#             (unit-cube) parameter space and adapts both its centre and its
#             full covariance from the ranking of each generation — so it learns
#             that, say, contact_dec and crunch_dec need to move TOGETHER, which
#             is exactly the structure a layered synth has. Derivative-free,
#             which we need: the objective runs an FFT and a loudness meter.
#
# DIVERSITY IS PART OF THE OBJECTIVE, NOT AN AFTERTHOUGHT
# -------------------------------------------------------
# A naive top-8 from an optimiser is eight copies of the same winner with the
# seed changed — which would reproduce, in a new tool, precisely the "everything
# sounds the same" defect the audit just found in the shipped library. So the
# shortlist is built greedily under a minimum descriptor distance: a candidate
# only makes the list if it is at least `--min-sigma` away from everything
# already on it, measured with the same standardised descriptor metric the audit
# uses for clustering.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import classes  # noqa: E402
import descriptors as D  # noqa: E402
import synth  # noqa: E402
from dsp import RATE  # noqa: E402


# ----------------------------------------------------------------- scaler --

class Scaler:
    """A FIXED standardisation, fitted once on the shipped library.

       Fitting the scaler on the candidate pool instead would make every
       distance depend on what the optimiser happened to sample, and two runs
       would not be comparable. Fitted on the library, "0.4 sigma apart" means
       the same thing here as it does in audit.py."""

    def __init__(self, rows: list[dict], features: list[str]):
        m = D.feature_matrix(rows, features)
        self.features = features
        self.mu = m.mean(axis=0)
        self.sd = m.std(axis=0)
        self.sd[self.sd < 1e-9] = 1.0
        self.lib = (m - self.mu) / self.sd

    def vec(self, d: dict) -> np.ndarray:
        m = D.feature_matrix([d], self.features)
        return ((m - self.mu) / self.sd)[0]

    def dist_to_library(self, d: dict, mask: np.ndarray | None = None) -> float:
        v = self.vec(d)
        lib = self.lib if mask is None else self.lib[mask]
        if len(lib) == 0:
            return 9.9
        return float(np.sqrt(((lib - v) ** 2).mean(axis=1)).min())


# --------------------------------------------------------------- objective --

class Objective:
    """Render, measure, score. Caches nothing: every evaluation is independent
       and reproducible from its parameter vector.

       The total score is

           (1 - w) * fitness  +  w * novelty

       where FITNESS is the class objective from classes.py and NOVELTY is how
       far the candidate sits, in the audit's own descriptor metric, from the
       nearest SHIPPED asset of the same class. The novelty term exists because
       the audit's headline finding is that our library clusters: an optimiser
       given fitness alone will happily rediscover the sound we already have,
       score it 0.95, and teach us nothing. `--novelty 0` turns it off and
       recovers pure fitness, which is what you want when you are trying to
       repair one specific asset rather than find a new one."""

    def __init__(self, recipe: synth.Recipe, scaler: Scaler | None = None,
                 lib_mask: np.ndarray | None = None, novelty_w: float = 0.0,
                 novelty_ref: float = 1.0):
        self.recipe = recipe
        self.cls = classes.CLASSES[recipe.cls]
        self.scaler = scaler
        self.lib_mask = lib_mask
        self.novelty_w = novelty_w
        self.novelty_ref = novelty_ref
        self.n_eval = 0

    def __call__(self, u: np.ndarray) -> tuple[float, dict, dict, np.ndarray]:
        p = self.recipe.from_unit(u)
        x = self.recipe.render(p)
        d = D.describe_signal(x, RATE)
        fit, _parts = self.cls.score(d)
        nov = 0.0
        if self.scaler is not None and self.novelty_w > 0.0:
            nov = min(self.scaler.dist_to_library(d, self.lib_mask)
                      / self.novelty_ref, 1.0)
        d["_fitness"] = float(fit)
        d["_novelty"] = float(nov)
        s = (1.0 - self.novelty_w) * fit + self.novelty_w * nov
        self.n_eval += 1
        return s, p, d, x


# ------------------------------------------------------------------ CMA-ES --

def cmaes(f, dim: int, evals: int, seed: int = 0, sigma0: float = 0.30,
          popsize: int = 0, log=print):
    """(mu/mu_w, lambda)-CMA-ES on the unit cube, Hansen's standard formulation.

       Short enough to read and to trust. Bounds are handled by clipping inside
       the objective (Recipe.from_unit clips), which is the simplest correct
       treatment for a box constraint when the optimum is rarely on the face."""
    rng = np.random.default_rng(seed)
    lam = popsize or int(4 + math.floor(3 * math.log(dim)))
    mu = lam // 2
    w = np.log(mu + 0.5) - np.log(np.arange(1, mu + 1))
    w /= w.sum()
    mueff = 1.0 / (w ** 2).sum()

    cc = (4 + mueff / dim) / (dim + 4 + 2 * mueff / dim)
    cs = (mueff + 2) / (dim + mueff + 5)
    c1 = 2 / ((dim + 1.3) ** 2 + mueff)
    cmu = min(1 - c1, 2 * (mueff - 2 + 1 / mueff) / ((dim + 2) ** 2 + mueff))
    damps = 1 + 2 * max(0.0, math.sqrt((mueff - 1) / (dim + 1)) - 1) + cs

    xmean = np.full(dim, 0.5)
    sigma = sigma0
    pc = np.zeros(dim)
    ps = np.zeros(dim)
    B = np.eye(dim)
    Dg = np.ones(dim)
    C = np.eye(dim)
    chiN = math.sqrt(dim) * (1 - 1 / (4 * dim) + 1 / (21 * dim ** 2))

    best = (-1e18, None, None, None)
    history = []
    gen = 0
    used = 0
    while used < evals:
        gen += 1
        z = rng.normal(0, 1, (lam, dim))
        y = z @ (B * Dg).T
        xs = np.clip(xmean + sigma * y, 0.0, 1.0)
        vals = []
        for i in range(lam):
            s, p, d, sig = f(xs[i])
            vals.append(s)
            if s > best[0]:
                best = (s, p, d, sig)
            used += 1
        vals = np.array(vals)
        order = np.argsort(-vals)          # maximise
        history.append((gen, float(vals.max()), float(np.median(vals)), float(best[0])))
        xold = xmean.copy()
        xmean = (xs[order[:mu]] * w[:, None]).sum(axis=0)

        invsqrtC = B @ np.diag(1.0 / Dg) @ B.T
        ps = (1 - cs) * ps + math.sqrt(cs * (2 - cs) * mueff) * invsqrtC @ (xmean - xold) / sigma
        hsig = (np.linalg.norm(ps) / math.sqrt(1 - (1 - cs) ** (2 * gen)) / chiN
                < 1.4 + 2 / (dim + 1))
        pc = (1 - cc) * pc + (hsig * math.sqrt(cc * (2 - cc) * mueff)
                              * (xmean - xold) / sigma)
        artmp = (xs[order[:mu]] - xold) / sigma
        C = ((1 - c1 - cmu) * C
             + c1 * (np.outer(pc, pc) + (not hsig) * cc * (2 - cc) * C)
             + cmu * (artmp.T @ (w[:, None] * artmp)))
        sigma *= math.exp((cs / damps) * (np.linalg.norm(ps) / chiN - 1))
        sigma = float(np.clip(sigma, 1e-4, 1.0))

        C = np.triu(C) + np.triu(C, 1).T
        try:
            Dg2, B = np.linalg.eigh(C)
        except np.linalg.LinAlgError:
            break
        Dg2 = np.maximum(Dg2, 1e-14)
        Dg = np.sqrt(Dg2)
        if gen % 10 == 0:
            log("        gen %3d  best %.4f  gen-best %.4f  sigma %.3f"
                % (gen, best[0], float(vals.max()), sigma))
    return best, history


def random_search(f, dim: int, evals: int, seed: int = 0):
    rng = np.random.default_rng(seed)
    best = (-1e18, None, None, None)
    history = []
    for i in range(evals):
        u = rng.random(dim)
        s, p, d, sig = f(u)
        if s > best[0]:
            best = (s, p, d, sig)
        if (i + 1) % max(evals // 20, 1) == 0:
            history.append((i + 1, s, s, float(best[0])))
    return best, history


# ------------------------------------------------------------- shortlists --

def diverse_top(pool: list[dict], k: int, min_sigma: float,
                scaler: Scaler | None = None) -> list[dict]:
    """Greedy: take the best, then the best candidate that is at least
       `min_sigma` from everything already taken. Distance is the same
       standardised descriptor metric audit.py clusters the shipped library
       with, so 'different' means the same thing in both tools."""
    if not pool:
        return []
    rows = [c["desc"] for c in pool]
    if scaler is not None:
        m = np.vstack([scaler.vec(r) for r in rows])
    else:
        m = D.standardise(D.feature_matrix(rows, D.SIMILARITY_FEATURES))
    order = sorted(range(len(pool)), key=lambda i: -pool[i]["score"])
    picked: list[int] = []
    for i in order:
        if len(picked) >= k:
            break
        if all(float(np.sqrt(((m[i] - m[j]) ** 2).mean())) >= min_sigma
               for j in picked):
            picked.append(i)
    # If the space is genuinely narrow we may not fill the list; say so rather
    # than silently relaxing the constraint.
    return [dict(pool[i], _rank=n + 1) for n, i in enumerate(picked)]


def write_audio(path: str, x: np.ndarray) -> None:
    import soundfile as sf
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    wav = os.path.splitext(path)[0] + ".wav"
    sf.write(wav, np.clip(x, -1.0, 1.0), RATE, subtype="PCM_16")
    if path.endswith(".ogg"):
        # Same encoder settings as tools/make_sfx.py, so an auditioned candidate
        # is bit-for-bit the thing that would ship.
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                        "-c:a", "libvorbis", "-q:a", "6", path], check=True)
        os.remove(wav)


# ------------------------------------------------------------------- main --

def run_one(name: str, out_dir: str, evals: int, top: int, min_sigma: float,
            seed: int, scaler: Scaler | None = None,
            lib_rows: list[dict] | None = None, novelty_w: float = 0.0,
            pool_keep: int = 400) -> dict:
    recipe = synth.RECIPES[name]
    cls = classes.CLASSES[recipe.cls]
    dim = len(recipe.space)
    print("[search] %s  (%d parameters, class '%s', %d evaluations per method)"
          % (name, dim, recipe.cls, evals))

    lib_mask = None
    incumbents: list[dict] = []
    if lib_rows is not None:
        lib_mask = np.array([r["cls"] == recipe.cls for r in lib_rows])
        incumbents = [r for r in lib_rows if r["cls"] == recipe.cls]
        if lib_mask.sum() == 0:
            lib_mask = None
        print("        %d shipped assets in this class to be novel against; "
              "novelty weight %.2f" % (len(incumbents), novelty_w))

    pool: list[dict] = []
    all_scores: list[float] = []

    def collect(tag):
        obj = Objective(recipe, scaler, lib_mask, novelty_w)

        def f(u):
            s, p, d, x = obj(u)
            all_scores.append(float(s))
            if s > 0.0:
                # float32 in the pool and a trim at 2x: a 2.6 s candidate is
                # 250 kB of float32, and an untrimmed pool of them is a
                # gigabyte of RAM on a machine that has seven other agents on
                # it. The stored copy is only ever re-encoded to 16-bit Vorbis,
                # so the precision is free to lose.
                pool.append({"score": float(s), "params": p, "desc": d,
                             "sig": x.astype(np.float32), "method": tag})
                if len(pool) > pool_keep * 2:
                    pool.sort(key=lambda c: -c["score"])
                    del pool[pool_keep:]
            return s, p, d, x
        return f

    t0 = time.time()
    n0 = len(all_scores)
    rbest, rhist = random_search(collect("random"), dim, evals, seed=seed)
    rand_scores = np.array(all_scores[n0:])
    t_rand = time.time() - t0
    print("        random baseline: best %.4f in %.0f s (%.0f ms/eval)"
          % (rbest[0], t_rand, 1000 * t_rand / max(evals, 1)))
    # Objective discrimination. If uniform sampling of the parameter space
    # already scores 0.9 on average, the objective is not saying much and the
    # search is decorative — worth knowing, and worth printing.
    print("        random pool: median %.3f, p90 %.3f, frac>0.90 %.2f "
          "(objective %s)"
          % (float(np.median(rand_scores)), float(np.percentile(rand_scores, 90)),
             float((rand_scores > 0.90).mean()),
             "discriminates" if float((rand_scores > 0.90).mean()) < 0.25
             else "SATURATED — tighten classes.py before trusting the ranking"))

    t0 = time.time()
    cbest, chist = cmaes(collect("cmaes"), dim, evals, seed=seed + 1,
                         log=lambda s: print(s))
    t_cma = time.time() - t0
    print("        CMA-ES:          best %.4f in %.0f s" % (cbest[0], t_cma))
    gain = cbest[0] - rbest[0]
    print("        CMA-ES beat random by %+.4f (%s)"
          % (gain, "search is working" if gain > 0.005
             else "NO ADVANTAGE — treat the result as random sampling"))

    short = diverse_top(pool, top, min_sigma, scaler)
    print("        shortlist: %d candidates at >= %.2f sigma apart"
          % (len(short), min_sigma))

    # What the shipped assets of this class score on the same objective — the
    # only comparison that means anything. A candidate at 0.95 is interesting
    # only if the incumbent is not already at 0.95.
    inc = []
    for r in incumbents:
        f_, _ = cls.score(r)
        inc.append({"rel": r["rel"], "fitness": float(f_)})
    inc.sort(key=lambda t: -t["fitness"])
    if inc:
        print("        incumbents: best %.3f (%s), median %.3f"
              % (inc[0]["fitness"], os.path.basename(inc[0]["rel"]),
                 float(np.median([i["fitness"] for i in inc]))))

    os.makedirs(out_dir, exist_ok=True)
    manifest = {
        "recipe": name, "class": recipe.cls, "dim": dim,
        "evals_per_method": evals, "seed": seed, "min_sigma": min_sigma,
        "novelty_weight": novelty_w,
        "random_best": float(rbest[0]), "cmaes_best": float(cbest[0]),
        "cmaes_advantage": float(gain),
        "random_pool_median": float(np.median(rand_scores)),
        "random_pool_frac_above_0.90": float((rand_scores > 0.90).mean()),
        "seconds": {"random": t_rand, "cmaes": t_cma},
        "incumbents": inc,
        "objective": [{"feature": c.feature, "kind": c.kind,
                       "target": c.target, "soft": c.soft, "w": c.w,
                       "why": c.why} for c in cls.crits],
        "candidates": [],
        "history_cmaes": chist,
        "history_random": rhist,
    }
    for c in short:
        base = "%s_%02d" % (name, c["_rank"])
        rel = base + ".ogg"
        write_audio(os.path.join(out_dir, rel), c["sig"])
        d = c["desc"]
        manifest["candidates"].append({
            "rank": c["_rank"], "file": rel, "score": c["score"],
            "fitness": d.get("_fitness"), "novelty": d.get("_novelty"),
            "found_by": c["method"],
            "params": c["params"],
            "misses": cls.failures(d),
            "descriptors": {k: d[k] for k in D.FEATURES if k in d},
        })
    with open(os.path.join(out_dir, "%s_manifest.json" % name), "w") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=True)
    print("        wrote %d files + %s_manifest.json to %s"
          % (len(short), name, out_dir))
    return manifest


def write_report(out_dir: str, path: str) -> int:
    """Roll every manifest under `out_dir` up into one readable page.

       Separate from the search itself so it can be re-run after the fact, and
       so a reviewer never has to open a JSON file to answer "did this help?"."""
    import glob  # noqa: PLC0415
    L: list[str] = []

    def w(s: str = "") -> None:
        L.append(s)

    mans = sorted(glob.glob(os.path.join(out_dir, "*", "*_manifest.json")))
    if not mans:
        print("[search] no manifests under %s" % out_dir, file=sys.stderr)
        return 1

    w("# SOUND LAB — search results")
    w()
    w("Each class was searched twice over the same parameter space: uniform "
      "random sampling (the control) and CMA-ES. Candidates are scored by the "
      "class objective in `tools/soundlab/classes.py` plus a novelty term "
      "against the shipped assets of that class, then a shortlist is picked "
      "greedily under a minimum descriptor distance so the eight files are "
      "eight different sounds rather than one sound eight times.")
    w()
    w("| class | dim | evals/method | random best | CMA-ES best | advantage | "
      "best shipped asset | shortlist |")
    w("|---|---|---|---|---|---|---|---|")
    for mp in mans:
        m = json.load(open(mp))
        inc = m["incumbents"][0] if m["incumbents"] else None
        w("| `%s` | %d | %d | %.3f | %.3f | %+.3f | %s | %d |" % (
            m["recipe"], m["dim"], m["evals_per_method"], m["random_best"],
            m["cmaes_best"], m["cmaes_advantage"],
            ("%.3f `%s`" % (inc["fitness"], os.path.basename(inc["rel"])))
            if inc else "—", len(m["candidates"])))
    w()

    for mp in mans:
        m = json.load(open(mp))
        w("## `%s`" % m["recipe"])
        w()
        sat = m.get("random_pool_frac_above_0.90", 0.0)
        w("%d-dimensional space, %d evaluations per method. Uniform sampling "
          "scored above 0.90 on %.0f %% of draws — %s." % (
              m["dim"], m["evals_per_method"], 100 * sat,
              "the objective discriminates within this space" if sat < 0.25 else
              "**the objective is near-saturated here**, so the ranking inside "
              "the shortlist means little and the recipe structure is doing "
              "the work rather than the search"))
        w()
        if m["incumbents"]:
            w("**What we ship today:** " + ", ".join(
                "`%s` %.3f" % (os.path.basename(i["rel"]), i["fitness"])
                for i in m["incumbents"]))
            w()
        w("| # | fitness | novelty | found by | file | misses | key descriptors |")
        w("|---|---|---|---|---|---|---|")
        for c in m["candidates"]:
            d = c["descriptors"]
            key = ("%.2f s, attack %.1f ms, crest %.1f dB, centroid %+.2f oct, "
                   "sub %.3f, rough %.2f" % (
                       d.get("duration_s", 0), d.get("attack_ms", 0),
                       d.get("crest_db", 0), d.get("centroid_drop_oct", 0),
                       d.get("band_sub", 0), d.get("roughness", 0)))
            w("| %d | %.3f | %.2f | %s | `%s` | %s | %s |" % (
                c["rank"], c.get("fitness") or c["score"], c.get("novelty") or 0.0,
                c["found_by"], c["file"], "; ".join(c["misses"]) or "—", key))
        w()
        w("Reproduce any of these exactly:")
        w()
        w("```")
        # Absolute unless the manifest genuinely lives inside the repo — a
        # relpath that starts with four ../ is not a usable instruction.
        repo = os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))))
        rel = os.path.relpath(mp, repo)
        show = mp if rel.startswith("..") else rel
        w("python3 tools/soundlab/synth.py --render %s --rank 1 --out /tmp/x.ogg"
          % show)
        w("```")
        w()

    open(path, "w").write("\n".join(L) + "\n")
    print("[search] wrote %s" % path)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("recipe", nargs="?", default="")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--out", required=True)
    ap.add_argument("--evals", type=int, default=2000,
                    help="evaluations PER METHOD (random and CMA-ES each get this many)")
    ap.add_argument("--top", type=int, default=8)
    ap.add_argument("--min-sigma", type=float, default=0.35,
                    help="minimum descriptor distance between shortlisted candidates")
    ap.add_argument("--seed", type=int, default=1770)
    ap.add_argument("--library", default="",
                    help="analyze.py JSON. Enables the novelty term and the "
                         "incumbent comparison; strongly recommended.")
    ap.add_argument("--novelty", type=float, default=0.25,
                    help="weight of the 'do not rediscover what we already "
                         "ship' term (0 = pure fitness)")
    ap.add_argument("--report", default="", metavar="OUT.md",
                    help="do not search; roll the manifests already under "
                         "--out into one markdown page and exit")
    args = ap.parse_args()

    if args.report:
        return write_report(args.out, args.report)

    names = sorted(synth.RECIPES) if args.all else [args.recipe]
    if not names or not names[0]:
        ap.error("give a recipe name or --all; see synth.py --list")

    scaler = lib_rows = None
    novelty_w = 0.0
    if args.library:
        lib_rows = json.load(open(args.library))
        scaler = Scaler(lib_rows, D.SIMILARITY_FEATURES)
        novelty_w = args.novelty
    elif args.novelty > 0:
        print("[search] --novelty given without --library; novelty disabled")

    summary = {}
    for nm in names:
        if nm not in synth.RECIPES:
            print("[search] no such recipe: %s" % nm, file=sys.stderr)
            return 2
        m = run_one(nm, os.path.join(args.out, nm), args.evals, args.top,
                    args.min_sigma, args.seed, scaler, lib_rows, novelty_w)
        summary[nm] = {"random_best": m["random_best"],
                       "cmaes_best": m["cmaes_best"],
                       "advantage": m["cmaes_advantage"],
                       "incumbent_best": (m["incumbents"][0]["fitness"]
                                          if m["incumbents"] else None),
                       "n_candidates": len(m["candidates"])}
    with open(os.path.join(args.out, "search_summary.json"), "w") as fh:
        json.dump(summary, fh, indent=1, sort_keys=True)
    print("[search] summary -> %s" % os.path.join(args.out, "search_summary.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
