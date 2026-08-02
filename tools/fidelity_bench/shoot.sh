#!/usr/bin/env bash
# Capture a fidelity scene WITHOUT ever touching the user's desktop.
#
#   tools/fidelity_bench/shoot.sh <res://scene.tscn> <out.png> [WxH] [frames] [CameraName]
#
# THE HARD RULE THIS SCRIPT EXISTS TO ENFORCE
# Every rendering (non-`--headless`) Godot invocation in this repo must run
# inside a gamescope headless backend with DISPLAY and WAYLAND_DISPLAY unset.
# Not "should" — must. The machine this project is developed on runs a live
# Wayland session with the game itself usually fullscreen on it, and a capture
# process that inherits that session opens a real window on the user's screen,
# steals focus, and can grab the pointer. That ruins the user's session and it
# ruins the shot. src/core/debug.gd enforces the same rule from inside the game
# (`_stay_out_of_the_way`); this enforces it from outside, for tools that never
# boot the game at all.
#
# `--backend headless` gives gamescope a virtual output with no compositor
# connection whatsoever, so there is no display to leak into. `env -u DISPLAY
# -u WAYLAND_DISPLAY` is belt and braces: without it, a Godot fallback path can
# still find the user's session even when the wrapper meant to hide it.
#
# An earlier revision of this file used a private Xvfb instead. Do not go back
# to that: an X server the tool starts itself is still an X server that a
# fallback can escape from, and it did.
#
# Vulkan still renders on the real GPU — gamescope only owns presentation, and
# the framebuffer is read back through Godot rather than off the display, so
# the wrapper never touches image quality.

set -euo pipefail

SCENE="${1:?usage: shoot.sh <res://scene.tscn> <out.png> [WxH] [frames] [Camera] [-- extra args]}"
OUT="${2:?missing output path}"
SIZE="${3:-1920x1080}"
FRAMES="${4:-240}"
CAM="${5:-}"
# Anything after the 5th positional is forwarded verbatim into the scene's own
# user args, so a probe scene can take its own flags (gi_probe.tscn reads --gi).
shift $(( $# < 5 ? $# : 5 ))

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="${SIZE%x*}"
H="${SIZE#*x}"

mkdir -p "$(dirname "$OUT")"

ARGS=(--scene "$SCENE" --out "$OUT" --size "$SIZE" --frames "$FRAMES" --fps)
if [ -n "$CAM" ]; then ARGS+=(--cam "$CAM"); fi
if [ "$#" -gt 0 ]; then ARGS+=("$@"); fi

env -u DISPLAY -u WAYLAND_DISPLAY \
	gamescope -W "$W" -H "$H" -w "$W" -h "$H" --backend headless -- \
	godot --path "$PROJECT" --resolution "$SIZE" \
		--script tools/fidelity_bench/capture.gd -- "${ARGS[@]}"
