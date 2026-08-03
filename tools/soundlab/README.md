# SOUND LAB

Tooling that makes "does this sound good" a **measurable** question, so it can
be searched instead of guessed.

Nothing in here writes to `assets/`, `src/` or `project.godot`. It reads audio,
produces numbers, charts and *candidate* files in an output directory you name.
Adopting a candidate is a separate, human decision made by whoever owns the
asset.

---

## Why it exists

The library is ~167 synthesised OGGs and nobody had ever measured whether they
were any good. "Generic" turns out to be mostly diagnosable: a sound reads as
cheap when it has no energy under 80 Hz, when its spectrum does not move over
its own length, when its loudest moment arrives long after the event that
caused it, when its bandwidth is two octaves, or when six "variations" measure
identically to each other. All five of those are numbers.

So: measure everything, define per-class targets with written justifications,
then run an optimiser over an addressable synthesiser until it finds parameter
sets that hit them.

---

## The pieces

| file | what it is |
|---|---|
| `dsp.py` | loading, STFT, Bark filterbank, band splits, one-pole filters. numpy only. Imports the project's existing `tools/audio/bs1770.py` for loudness — one meter for the whole game. |
| `descriptors.py` | the descriptor suite: attack/decay shape, crest, spectral **centroid trajectory**, flux, bandwidth, flatness, HNR, band balance, and Zwicker-style **sharpness** and **roughness**. Deterministic. |
| `classes.py` | the taxonomy (footfall, weapon_fire, creature_windup, ...) and the **objective functions**: per-class targets with tolerances, weights, and a written reason for each, tagged `[PHYS]`, `[FIT]` or `[CALL]`. This is the file to argue with. |
| `analyze.py` | run the suite over a directory → JSON + CSV. |
| `audit.py` | the health report: rankings, defect census, and the clustering that finds sounds which measure the same. |
| `synth.py` | the same instrument as `tools/make_sfx.py` with its parameters exposed, vectorised. `--verify-voice` proves the two agree. |
| `search.py` | random search + CMA-ES over the parameter space, scored by `classes.py`, with a diversity constraint on the shortlist and a novelty term against the shipped library. |
| `charts.py` | spectrograms with the centroid drawn on them, band-balance bars, the library PCA map, convergence plots. |
| `clap_score.py` | optional: LAION-CLAP semantic scoring, with a validation harness that measures whether it is worth trusting. |

---

## Quick start

```bash
OUT=/tmp/soundlab            # anywhere outside the repo

# 1. measure the shipped library
python3 tools/soundlab/analyze.py --out $OUT/library.json

# 2. the health report — what is weak, and what is a duplicate of what
python3 tools/soundlab/audit.py $OUT/library.json --out $OUT/HEALTH_REPORT.md

# 3. see it
python3 tools/soundlab/charts.py --library $OUT/library.json --out $OUT/charts \
    --sheets assets/audio/weapons/breaker_shot_01.ogg

# 4. search for better parameters (random baseline + CMA-ES, both reported)
python3 tools/soundlab/search.py footfall --out $OUT/search \
    --evals 2500 --top 8 --library $OUT/library.json

# 5. roll every search into one readable page
python3 tools/soundlab/search.py --out $OUT/search --report $OUT/SEARCH_RESULTS.md

# 6. audition $OUT/search/footfall/footfall_01.ogg ... then re-render the one
#    you like straight from its recorded parameters
python3 tools/soundlab/synth.py --render $OUT/search/footfall/footfall_manifest.json \
    --rank 1 --out /tmp/winner.ogg
```

Only requirement: `numpy`, `soundfile`, `matplotlib`, `ffmpeg`. All already
present on the build machine. `analyze.py --verify-reproducible` asserts two
full passes produce byte-identical output.

---

## Pointing it at your own work

**If you are regenerating an asset** (M12, or anyone touching `make_sfx.py`):

```bash
# measure just your output directory
python3 tools/soundlab/analyze.py --root path/to/your/renders --out $OUT/mine.json
python3 tools/soundlab/audit.py $OUT/mine.json
# and put your new version next to the old one
python3 tools/soundlab/charts.py --out $OUT/charts \
    --compare assets/audio/weapons/breaker_shot_01.ogg path/to/your/new_shot.ogg
```

The `--compare` chart is the fastest way to see whether a change did what you
meant: same axes, spectrogram, centroid trajectory and band balance side by
side.

**If you disagree with a score**, the objective is 200 lines of readable
criteria in `classes.py`, each with its reasoning. Change the number, rerun,
and the whole library re-ranks. That is the intended workflow — the targets are
a starting position, not a standard.

**If you want a new class or a new recipe**, add a `SoundClass` to
`classes.py` (plus a route in `ROUTES`) and, if you want to search it, a
`Recipe` to `synth.py`. A recipe is a parameter-space dict and a render
function; `search.py --all` picks it up automatically.

---

## What the numbers mean

The three that do most of the work:

- **`centroid_drop_oct`** — how many octaves the spectral centroid falls
  between the first and last quarter of the sound's *energy*. Every struck
  physical object darkens as it rings out, because the high partials radiate
  away first. A synth stack with one envelope over everything does not, and
  that single fact is the most common reason a sound is described as
  "synthetic" or "generic". Positive is physical.
- **`crest_db`** and **`env_range_db`** — punch, and whether there is any
  dynamic left after loudness normalisation. Candidates are scored *after*
  BS.1770 normalisation for exactly this reason.
- **`roughness`** — amplitude modulation of the critical-band envelopes around
  70 Hz. It is the measurable correlate of "snarl", "gnarly", "nasty". A
  creature with no roughness is a synthesiser pad; a klaxon with none is a
  loud sine.

`sharpness_acum` (Zwicker/DIN 45692) is the fatigue axis — it is why several
classes have a *maximum* rather than a minimum.

The psychoacoustic pair are faithful-in-shape implementations, not certified
ones: the published models assume stationary signals through a calibrated
reproduction chain, and a 90 ms game one-shot is neither. They give a
consistent monotone ranking across our own material, which is what an objective
needs; treat the absolute acum/asper values as "our units".

---

## The optional CLAP leg

`clap_score.py` scores audio against text — *"massive industrial machine
footfall, deep metallic impact, cavernous"* becomes a number. Setup, and an
honest validation harness that measures whether the model is any good on our
material before you trust it, are documented in the header of that file.

It is used **only to score audio we synthesised ourselves**. No third-party
audio enters the game, no reference library is downloaded, no generative model
produces a shipping asset. Do not extend it into generation.

---

## Known weakness (found by the search, not yet fixed)

`crest_db` divides the peak by the RMS of the **whole file**, so inserting
silence in the middle of a sound raises it for free — and the optimiser found
that. Several `impact_heavy` winners have a ~250 ms hole between the break and
the debris, which is a measurement artefact and not a good impact.

The fix is written up in the header of `classes.py`: measure crest against the
active region (frames above -40 dB of peak), and add a `silence_frac`
descriptor with a per-class maximum. It is deliberately not applied yet, because
changing `crest_db` re-ranks the whole audit and the audit and the search
results should stay one consistent instrument — do it as a single change and
re-run both.

Until then: **look at the waveform of any winner before adopting it.**
`charts.py --compare` exists for exactly that, and it takes ten seconds.

## What this cannot do

It can eliminate the objectively broken, find the perceptually identical, and
rank a shortlist by qualities that genuinely correlate with weight, punch, bite
and movement. It cannot tell you whether a sound is *right* for the moment it
plays in — nothing here knows that the Sentinel is meant to feel bureaucratic
rather than feral. A high score means "no measurable defects", not "this is the
one". The last step is a human ear.
