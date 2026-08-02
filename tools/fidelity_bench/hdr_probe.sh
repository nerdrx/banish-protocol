#!/usr/bin/env bash
# Run the HDR capability probe. Same hard rule as shoot.sh: NEVER against the
# user's session — always inside gamescope's headless backend with DISPLAY and
# WAYLAND_DISPLAY unset.
#
#   tools/fidelity_bench/hdr_probe.sh          # SDR baseline
#   tools/fidelity_bench/hdr_probe.sh --hdr    # gamescope --hdr-enabled
#
# Note what this can and cannot tell you. Inside a headless gamescope there is
# no physical output, so a "supported/enabled" here is a statement about the
# nested compositor's swapchain, NOT about the user's monitor. That is still the
# useful measurement — it is exactly the path a shipped build takes when a
# player launches through gamescope — but the monitor-side half has to be
# established separately (see the report's HDR section).

set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GS_EXTRA=()
if [ "${1:-}" = "--hdr" ]; then
	GS_EXTRA+=(--hdr-enabled)
	shift
fi

env -u DISPLAY -u WAYLAND_DISPLAY \
	gamescope -W 1920 -H 1080 -w 1920 -h 1080 --backend headless "${GS_EXTRA[@]}" -- \
	godot --path "$PROJECT" --resolution 1920x1080 \
		--script tools/fidelity_bench/hdr_probe.gd -- "$@"
