#!/usr/bin/env bash
# M12 SENSATION — capture the showcase bench.
#
#   tools/sensation_bench/shoot.sh <out.png> [WxH] [frames] -- <scene args...>
#
# ONE GAMESCOPE AT A TIME (CLAUDE.md). Four other agents share this machine and
# a headless gamescope binds the abstract X0 socket exclusively, so this WAITS on
# the shared lock rather than racing for it. Never pkill -f gamescope: that
# murders somebody else's capture, and it has.
#
# DISPLAY and WAYLAND_DISPLAY are unset because the user is playing on this
# machine right now and a capture that inherits their session opens a real window
# on their screen and steals their pointer.
set -euo pipefail

OUT="${1:?usage: shoot.sh <out.png> [WxH] [frames] -- <scene args>}"
SIZE="${2:-3440x1440}"
FRAMES="${3:-240}"
shift $(( $# < 3 ? $# : 3 ))
[ "${1:-}" = "--" ] && shift

W=${SIZE%x*}
H=${SIZE#*x}
SCRATCH="${BP_SCRATCH:-/tmp/claude-1000/-mnt-86e4cf4f-b8d4-4490-b068-31c74182b013-claude/20aa518f-c5fb-4e1b-902d-ef00b158a6ba/scratchpad}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

exec flock "$SCRATCH/gamescope.lock" \
	env -u DISPLAY -u WAYLAND_DISPLAY \
	gamescope -W "$W" -H "$H" -w "$W" -h "$H" --backend headless -- \
	godot --path "$REPO" res://tools/sensation_bench/showcase.tscn -- \
	--screenshot "$OUT" "$FRAMES" --window-size "$SIZE" "$@"
