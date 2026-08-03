#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — SOUND LAB: semantic scoring with LAION-CLAP.
#
# CLAP embeds audio and text into one space, so "how much does this sound like
# *massive industrial machine footfall, deep metallic impact, cavernous*" stops
# being a question only ears can answer and becomes a number. That is the
# closest thing to a machine ear that exists off the shelf, and it is the tool
# the request was reaching for.
#
# THIS IS THE OPTIONAL LEG. The descriptor path (analyze/audit/search) is the
# guaranteed deliverable and has no dependency on any of this. Nothing here can
# fail the milestone; if the model is unavailable the tool says so and exits.
#
# LICENSING — READ BEFORE EXTENDING
# ---------------------------------
# CLAP is used here only to SCORE audio we synthesised ourselves. No third-party
# audio enters the game, no reference library is downloaded, and no generative
# model produces a shipping asset. That keeps the repo's no-external-assets law
# intact. Do not extend this file into generation.
#
# SETUP (nothing is installed into the system python)
# ---------------------------------------------------
#   python3 -m venv /path/on/big/disk/.soundlab-venv
#   .soundlab-venv/bin/pip install --index-url \
#       https://download.pytorch.org/whl/cpu torch
#   .soundlab-venv/bin/pip install transformers soundfile numpy
#   export HF_HOME=/path/on/big/disk/.soundlab-hf     # model cache, ~2 GB
#   .soundlab-venv/bin/python tools/soundlab/clap_score.py --validate \
#       --library OUT/library.json
#
# CPU inference. ~0.3 s per clip on this machine; do not fight ROCm for it.
#
# WHY THE SCORE IS A MARGIN AND NOT A COSINE
# ------------------------------------------
# Raw CLAP cosine similarity carries a strong per-text bias: some prompts are
# simply "closer" to all audio than others, so comparing cos(clip, promptA)
# across clips is fine but comparing it across PROMPTS is not, and a single
# absolute cosine is close to meaningless. Two standard corrections, both
# applied here:
#   1. PROMPT ENSEMBLING — several phrasings per concept, embeddings averaged.
#      Reduces the variance contributed by one unlucky wording.
#   2. A CONTRASTIVE MARGIN — score = mean cos(positives) - mean cos(negatives),
#      with the negatives chosen to be the failure the class actually risks.
#      The per-clip bias cancels in the subtraction.
# `--validate` measures whether the result is worth anything, on our own
# library, and prints the number rather than asserting the model is good.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MODEL_ID = "laion/clap-htsat-unfused"
CLAP_RATE = 48000
MAX_SECONDS = 10.0


def _load_model():
    try:
        import torch
        from transformers import ClapModel, ClapProcessor
    except Exception as exc:                              # noqa: BLE001
        print("[clap] unavailable: %s" % exc, file=sys.stderr)
        print("[clap] this leg is optional; the descriptor path does not need it.",
              file=sys.stderr)
        return None, None, None
    proc = ClapProcessor.from_pretrained(MODEL_ID)
    model = ClapModel.from_pretrained(MODEL_ID).eval()
    return torch, proc, model


def _read(path: str) -> np.ndarray:
    import soundfile as sf
    x, rate = sf.read(path, always_2d=True, dtype="float32")
    x = x.mean(axis=1)
    if rate != CLAP_RATE:
        t = np.linspace(0, len(x) - 1, int(len(x) * CLAP_RATE / rate))
        x = np.interp(t, np.arange(len(x)), x).astype(np.float32)
    # CLAP's HTSAT front end takes 10 s; longer files are truncated rather than
    # chunk-averaged, because for a game one-shot the first 10 s IS the sound
    # and for a loop any 10 s window is representative.
    return x[:int(CLAP_RATE * MAX_SECONDS)]


class Clap:
    def __init__(self):
        self.torch, self.proc, self.model = _load_model()
        self.ok = self.model is not None

    def audio_embed(self, paths: list[str], batch: int = 8) -> np.ndarray:
        out = []
        for i in range(0, len(paths), batch):
            auds = [_read(p) for p in paths[i:i + batch]]
            inp = self.proc(audio=auds, sampling_rate=CLAP_RATE,
                            return_tensors="pt", padding=True)
            with self.torch.no_grad():
                e = self.model.get_audio_features(**inp)
            e = e if hasattr(e, "shape") else e.pooler_output
            e = e / e.norm(dim=-1, keepdim=True)
            out.append(e.numpy())
            print("[clap]   %d/%d" % (min(i + batch, len(paths)), len(paths)),
                  file=sys.stderr)
        return np.vstack(out)

    def text_embed(self, texts: list[str]) -> np.ndarray:
        inp = self.proc(text=texts, return_tensors="pt", padding=True)
        with self.torch.no_grad():
            e = self.model.get_text_features(**inp)
        e = e if hasattr(e, "shape") else e.pooler_output
        e = e / e.norm(dim=-1, keepdim=True)
        return e.numpy()


def class_prompts() -> dict:
    import classes  # noqa: PLC0415
    return {n: (c.clap_positive, c.clap_negative)
            for n, c in classes.CLASSES.items() if c.clap_positive}


def margins(clap: Clap, emb: np.ndarray, cname: str, prompts: dict) -> np.ndarray:
    pos, neg = prompts[cname]
    tp = clap.text_embed(pos).mean(axis=0)
    tp /= np.linalg.norm(tp)
    if neg:
        tn = clap.text_embed(neg).mean(axis=0)
        tn /= np.linalg.norm(tn)
    else:
        tn = np.zeros_like(tp)
    return emb @ tp - emb @ tn


def cmd_validate(args) -> int:
    """Does CLAP agree with our own taxonomy?

       The test: embed every shipped asset, then for each class compute the
       contrastive margin against that class's prompts and ask what fraction of
       the top-N highest-margin files really are members of that class. Chance
       level is the class's share of the library, printed alongside. If the
       model cannot beat chance on our material it is not a usable judge of it,
       and this prints that rather than hiding it."""
    clap = Clap()
    if not clap.ok:
        return 3
    rows = json.load(open(args.library))
    root = args.root
    paths = [os.path.join(root, r["rel"]) for r in rows]
    print("[clap] embedding %d files..." % len(paths), file=sys.stderr)
    emb = clap.audio_embed(paths)
    prompts = class_prompts()

    results = {}
    print("\n%-22s %5s %8s %8s %8s" % ("class", "n", "top-n hit", "chance", "AUC"))
    print("-" * 58)
    for cname in sorted(prompts):
        members = np.array([r["cls"] == cname for r in rows])
        n = int(members.sum())
        if n == 0:
            continue
        m = margins(clap, emb, cname, prompts)
        order = np.argsort(-m)
        hit = float(members[order[:n]].mean())
        chance = n / len(rows)
        # ROC AUC of the margin as a member/non-member discriminator, by the
        # rank-sum identity (no sklearn in this venv, and it is three lines).
        ranks = np.empty(len(m))
        ranks[np.argsort(m)] = np.arange(1, len(m) + 1)
        pos_ranks = ranks[members].sum()
        neg = len(m) - n
        auc = (pos_ranks - n * (n + 1) / 2) / (n * neg) if neg else float("nan")
        results[cname] = {"n": n, "top_n_precision": hit, "chance": chance,
                          "auc": float(auc),
                          "top5": [rows[i]["rel"] for i in order[:5]]}
        print("%-22s %5d %8.2f %8.2f %8.3f" % (cname, n, hit, chance, auc))
    aucs = [v["auc"] for v in results.values() if v["auc"] == v["auc"]]
    print("-" * 58)
    print("mean AUC over %d classes: %.3f  (0.5 = useless, 1.0 = perfect)"
          % (len(aucs), float(np.mean(aucs))))

    # The mean is the least interesting number here. CLAP's usefulness is
    # STRONGLY class-dependent on our material, and a per-class verdict is the
    # only one anybody should act on — using it as a tie-breaker on a class
    # where it scores 0.5 would be worse than not using it at all.
    good = sorted(c for c, v in results.items() if v["auc"] >= 0.80)
    mid = sorted(c for c, v in results.items() if 0.65 <= v["auc"] < 0.80)
    bad = sorted(c for c, v in results.items() if v["auc"] < 0.65)
    print("\nVERDICT, per class:")
    print("  TRUST as a secondary ranking signal (AUC >= 0.80): %s"
          % (", ".join(good) or "none"))
    print("  TIE-BREAK only (0.65-0.80):                        %s"
          % (", ".join(mid) or "none"))
    print("  DO NOT USE (< 0.65):                               %s"
          % (", ".join(bad) or "none"))
    print("\nA class with one member has an AUC that means very little; read "
          "n before reading the score.")
    if args.out:
        json.dump(results, open(args.out, "w"), indent=1, sort_keys=True)
        print("[clap] wrote %s" % args.out)
    return 0


def cmd_rank(args) -> int:
    """Rank a directory of candidates by semantic margin for a given class."""
    clap = Clap()
    if not clap.ok:
        return 3
    files = sorted(f for f in os.listdir(args.dir)
                   if f.lower().endswith((".ogg", ".wav", ".flac")))
    if not files:
        print("[clap] nothing to rank in %s" % args.dir, file=sys.stderr)
        return 1
    paths = [os.path.join(args.dir, f) for f in files]
    emb = clap.audio_embed(paths)
    prompts = class_prompts()
    if args.cls not in prompts:
        print("[clap] no prompts for class %s" % args.cls, file=sys.stderr)
        return 2
    m = margins(clap, emb, args.cls, prompts)
    order = np.argsort(-m)
    print("\nsemantic ranking for class '%s'" % args.cls)
    print("  prompts +: %s" % "; ".join(prompts[args.cls][0]))
    print("  prompts -: %s" % "; ".join(prompts[args.cls][1]))
    print()
    out = []
    for rank, i in enumerate(order, 1):
        print("%2d. %+.4f  %s" % (rank, m[i], files[i]))
        out.append({"rank": rank, "margin": float(m[i]), "file": files[i]})
    if args.out:
        json.dump({"class": args.cls, "ranking": out}, open(args.out, "w"),
                  indent=1)
        print("[clap] wrote %s" % args.out)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    from dsp import REPO  # noqa: PLC0415

    v = sub.add_parser("validate", help="measure CLAP against our own taxonomy")
    v.add_argument("--library", required=True)
    v.add_argument("--root", default=os.path.join(REPO, "assets", "audio"))
    v.add_argument("--out", default="")
    v.set_defaults(func=cmd_validate)

    r = sub.add_parser("rank", help="rank a candidate directory")
    r.add_argument("dir")
    r.add_argument("--cls", required=True)
    r.add_argument("--out", default="")
    r.set_defaults(func=cmd_rank)

    args = ap.parse_args()
    if not getattr(args, "func", None):
        ap.print_help()
        return 0
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
