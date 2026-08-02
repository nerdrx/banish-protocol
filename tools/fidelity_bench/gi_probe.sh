#!/usr/bin/env bash
# Render the Cornell box three times (no GI / SDFGI / VoxelGI) and print the
# numbers that decide whether godotengine/godot#115599 is present on 4.7.1.
#
#   tools/fidelity_bench/gi_probe.sh <output-dir>
#
# The verdict is arithmetic, not taste. For each render we measure, in three
# fixed regions of the frame:
#   * mean luminance     — did indirect light arrive at all?
#   * red-minus-blue     — did it arrive COLOURED, i.e. is it really bounce off
#                          the red and blue walls rather than a grey ambient
#                          term wearing a GI hat?
# A working GI solution lifts the floor and the shadowed block well above the
# no-GI control AND makes the left of the room measurably redder than the right.
# A broken one fails at least one of those, and a #115599-style failure (black
# or blown out) fails the first spectacularly.

set -euo pipefail
OUT="${1:?usage: gi_probe.sh <output-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT"

for MODE in off sdfgi voxelgi; do
	echo "--- rendering $MODE ---"
	"$HERE/shoot.sh" res://tools/fidelity_bench/gi_probe.tscn \
		"$OUT/gi_$MODE.png" 1280x720 220 Cam --gi "$MODE" 2>&1 \
		| grep -E "^\[Capture\]|^\[GIProbe\]" || true
done

python3 "$HERE/gi_analyse.py" "$OUT"
