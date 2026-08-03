#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# BANISH PROTOCOL — M12 SENSATION. Figures for the acoustic measurements.
#
#   python3 tools/sensation_bench/plot_acoustics.py <dir-from-acoustics_probe>
#
# Reads what `acoustics_probe.gd` recorded coming out of the real mixer and
# produces the two figures the milestone has to be able to show:
#
#   room_acoustics.png   the impulse response of every archetype on one set of
#                        axes, in dB, with the measured T20 marked. This is the
#                        picture that answers "do the spaces actually differ".
#   occlusion_ab.png     each creature cue's spectrum clear against occluded,
#                        plus the identity separation table. This is the picture
#                        that answers "is it muffled" AND the one that answers
#                        "can you still tell which creature it is", which are
#                        two different questions and only the second one is at
#                        risk.
#
# Stdlib + numpy + matplotlib. No engine, no game state: everything here is
# arithmetic on samples that already came out of the mixer.
# ---------------------------------------------------------------------------
import csv
import os
import sys

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

RATE = 44100

# The archetypes, in the order they should read on a legend: biggest space first.
ORDER = ["hall", "trunk", "room", "sanctuary", "corridor", "alcove"]
COLOURS = {
    "hall": "#5fd3f0",
    "trunk": "#8b7bf0",
    "room": "#63e6a8",
    "sanctuary": "#f0c85f",
    "corridor": "#f08a5f",
    "alcove": "#e0607a",
}

# Octave-ish analysis bands. The creature-identity question lives in the lowest
# three: fundamentals and first formants sit between 100 Hz and 1.2 kHz, which is
# exactly the region the occlusion low-pass is tuned to preserve.
BANDS = [
    ("60-125", 60, 125),
    ("125-250", 125, 250),
    ("250-500", 250, 500),
    ("500-1k", 500, 1000),
    ("1k-2k", 1000, 2000),
    ("2k-4k", 2000, 4000),
    ("4k-8k", 4000, 8000),
    ("8k-16k", 8000, 16000),
]


def read_f32(path):
    return np.fromfile(path, dtype="<f4")


def envelope_db(signal, block=441):
    """Block-peak envelope in dB relative to the block peak."""
    usable = (len(signal) // block) * block
    if usable == 0:
        return np.zeros(1)
    blocks = np.abs(signal[:usable]).reshape(-1, block).max(axis=1)
    peak = blocks.max()
    if peak <= 0:
        return np.full(len(blocks), -120.0)
    return 20.0 * np.log10(np.maximum(blocks, 1e-7) / peak)


def band_energy(signal):
    """RMS energy per analysis band, in dB. One rfft over the whole capture —
    these are steady cues, so a single spectrum is the honest summary and a
    spectrogram would be more picture for no more information."""
    if len(signal) == 0:
        return {name: -120.0 for name, _, _ in BANDS}
    window = np.hanning(len(signal))
    spectrum = np.abs(np.fft.rfft(signal * window))
    freqs = np.fft.rfftfreq(len(signal), 1.0 / RATE)
    out = {}
    for name, lo, hi in BANDS:
        mask = (freqs >= lo) & (freqs < hi)
        power = float(np.sqrt(np.mean(spectrum[mask] ** 2))) if mask.any() else 0.0
        out[name] = 20.0 * np.log10(max(power, 1e-7))
    return out


def plot_rooms(directory, rows):
    fig, (ax, ax2) = plt.subplots(
        2, 1, figsize=(11, 9), gridspec_kw={"height_ratios": [2.1, 1]}
    )
    fig.patch.set_facecolor("#0b0d10")
    for axis in (ax, ax2):
        axis.set_facecolor("#0b0d10")
        for spine in axis.spines.values():
            spine.set_color("#39424d")
        axis.tick_params(colors="#b8c2cc")
        axis.grid(True, color="#1e242b", linewidth=0.8)

    for kind in ORDER:
        path = os.path.join(directory, "decay_%s.f32" % kind)
        if not os.path.exists(path):
            continue
        curve = envelope_db(read_f32(path))
        time = np.arange(len(curve)) * 441 / RATE
        keep = time <= 2.4
        ax.plot(
            time[keep],
            curve[keep],
            label=kind.upper(),
            color=COLOURS[kind],
            linewidth=1.9,
        )

    ax.axhline(-20.0, color="#7a8896", linestyle="--", linewidth=1.0)
    ax.text(2.28, -19.0, "T20", color="#7a8896", fontsize=9, ha="right")
    ax.set_xlim(0, 2.4)
    ax.set_ylim(-70, 2)
    ax.set_xlabel("seconds", color="#b8c2cc")
    ax.set_ylabel("dB relative to peak", color="#b8c2cc")
    ax.set_title(
        "M12 SENSATION — impulse response per room archetype\n"
        "measured off AudioEffectCapture on Master, through the real mixer",
        color="#e6edf3",
        fontsize=13,
    )
    legend = ax.legend(facecolor="#141920", edgecolor="#39424d", labelcolor="#e6edf3")
    legend.get_frame().set_alpha(0.95)

    # The bar panel: what actually carries "size" once the engine's tail ceiling
    # has flattened the top three. Normalised so all three fit one axis.
    kinds = [r["space"] for r in rows]
    x = np.arange(len(kinds))
    width = 0.27
    measured = np.array([float(r["rt60_measured_s"]) for r in rows])
    wet = np.array([float(r["wet"]) for r in rows])
    predelay = np.array([float(r["predelay_ms"]) for r in rows])
    ax2.bar(x - width, measured / measured.max(), width,
            label="RT60 (measured)", color="#5fd3f0")
    ax2.bar(x, wet / wet.max(), width, label="wet (reflected level)", color="#63e6a8")
    ax2.bar(x + width, predelay / predelay.max(), width,
            label="predelay (first reflection)", color="#f0c85f")
    ax2.set_xticks(x)
    ax2.set_xticklabels([k.upper() for k in kinds], color="#b8c2cc", fontsize=9)
    ax2.set_ylabel("normalised", color="#b8c2cc")
    ax2.set_title(
        "the three size cues, normalised — note WET spans 16:1 where the tail spans 2.9:1",
        color="#e6edf3",
        fontsize=11,
    )
    ax2.legend(facecolor="#141920", edgecolor="#39424d", labelcolor="#e6edf3", fontsize=9)

    fig.tight_layout()
    out = os.path.join(directory, "room_acoustics.png")
    fig.savefig(out, dpi=110, facecolor=fig.get_facecolor())
    print("wrote", out)


def plot_occlusion(directory):
    cues = []
    for entry in sorted(os.listdir(directory)):
        if entry.startswith("occ_") and entry.endswith("_clear.f32"):
            cues.append(entry[len("occ_"): -len("_clear.f32")])
    if not cues:
        print("no occlusion captures found")
        return

    fig, axes = plt.subplots(1, len(cues), figsize=(4.4 * len(cues), 5.2))
    if len(cues) == 1:
        axes = [axes]
    fig.patch.set_facecolor("#0b0d10")

    names = [name for name, _, _ in BANDS]
    clear_vectors = {}
    occluded_vectors = {}

    for axis, cue in zip(axes, cues):
        clear = band_energy(read_f32(os.path.join(directory, "occ_%s_clear.f32" % cue)))
        occluded = band_energy(
            read_f32(os.path.join(directory, "occ_%s_occluded.f32" % cue))
        )
        clear_vectors[cue] = np.array([clear[n] for n in names])
        occluded_vectors[cue] = np.array([occluded[n] for n in names])

        axis.set_facecolor("#0b0d10")
        for spine in axis.spines.values():
            spine.set_color("#39424d")
        axis.tick_params(colors="#b8c2cc")
        axis.grid(True, color="#1e242b", linewidth=0.8)
        x = np.arange(len(names))
        axis.plot(x, clear_vectors[cue], "-o", color="#5fd3f0", label="clear", linewidth=2)
        axis.plot(
            x, occluded_vectors[cue], "-o", color="#f08a5f", label="occluded", linewidth=2
        )
        axis.set_xticks(x)
        axis.set_xticklabels(names, rotation=45, ha="right", fontsize=8, color="#b8c2cc")
        axis.set_title(cue.replace("_", " "), color="#e6edf3", fontsize=10)
        axis.set_ylabel("dB", color="#b8c2cc")
        axis.legend(facecolor="#141920", edgecolor="#39424d", labelcolor="#e6edf3",
                    fontsize=8)

    fig.suptitle(
        "M12 SENSATION — occlusion A/B: muffled, and still tellable apart",
        color="#e6edf3",
        fontsize=13,
    )
    fig.tight_layout()
    out = os.path.join(directory, "occlusion_ab.png")
    fig.savefig(out, dpi=110, facecolor=fig.get_facecolor())
    print("wrote", out)

    # THE IDENTITY CHECK. If occlusion collapsed every creature onto the same
    # distant thud, the mean pairwise distance between their band vectors would
    # fall toward zero. Reported as a ratio, because the absolute dB distance
    # depends on how loud the cues happen to be mastered.
    def mean_pairwise(vectors):
        keys = list(vectors)
        total, count = 0.0, 0
        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                a, b = vectors[keys[i]], vectors[keys[j]]
                # Level-normalised: subtract each vector's own mean, so this
                # measures SHAPE (which is identity) rather than loudness.
                total += float(np.linalg.norm((a - a.mean()) - (b - b.mean())))
                count += 1
        return total / max(count, 1)

    before = mean_pairwise(clear_vectors)
    after = mean_pairwise(occluded_vectors)
    print("\n-- creature identity through the occlusion filter --")
    print("mean pairwise spectral-shape distance, clear:    %.2f dB" % before)
    print("mean pairwise spectral-shape distance, occluded: %.2f dB" % after)
    print("retained: %.0f%%" % (100.0 * after / before if before else 0.0))
    for cue in cues:
        delta = occluded_vectors[cue] - clear_vectors[cue]
        low = delta[:4].mean()
        high = delta[4:].mean()
        print(
            "  %-32s low bands %+6.1f dB   high bands %+6.1f dB   tilt %+.1f dB"
            % (cue, low, high, high - low)
        )


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    directory = sys.argv[1]
    with open(os.path.join(directory, "rt60.csv")) as handle:
        rows = list(csv.DictReader(handle))
    rows.sort(key=lambda r: ORDER.index(r["space"]) if r["space"] in ORDER else 99)
    plot_rooms(directory, rows)
    plot_occlusion(directory)
    return 0


if __name__ == "__main__":
    sys.exit(main())
