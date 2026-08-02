# BANISH PROTOCOL — working rules

DESIGN.md is the source of truth for what the game is. This file is the source
of truth for how we work on it. Earned the hard way; every rule below has a
commit or an incident behind it.

## GDScript

- Static typing everywhere. Match the existing style and comment voice.
- **`const` may only hold constant expressions — literals.**
  `PackedStringArray(...)`, `PackedInt64Array(...)` and friends are constructor
  CALLS and fail the parse. Use typed array literals: `const X: Array[int] = [...]`.
  A bad const in one script fails its parse → fails the autoloads → takes down
  every run in the tree with unrelated-looking errors. (Caught two separate
  authors on 2026-08-02.)
- **A typed array must not come from a ternary between array literals.**
  `var x: Array[Vector3] = [a, b, c] if cond else [a, b]` throws AT RUNTIME
  (both branches infer untyped `Array`), so the tree parses green and runs
  simply die silently. Build the array element by element. Corollary: a run
  that produces NO output is a bug signal, not a slow machine.
- Determinism law: seeded generation derives from position+seed hashing, never
  from consuming the shared RNG stream in order-dependent ways. Cross-peer
  byte-identical `--dumplayer` output is the invariant.

## Tree discipline (especially with multiple agents in one working copy)

- **The tree must compile between edit batches.** After any new/edited .gd, run
  a `godot --headless -- --quit-in 3` compile check (or `--selftest`) BEFORE
  starting captures/tests or moving on. Never leave the tree red while doing
  something else.
- An edit that spans "call site" and "definition" lands as ONE write, not two.
- Shared instrument files (src/core/debug.gd) are append-only during parallel
  work: add sections, never reorder or reformat others' code.
- Agents do not commit or stage. The coordinator merge-reviews and commits.

## Rendering / testing on this machine

- The user plays and works on this machine. **Every rendering Godot run must be
  wrapped:** `env -u DISPLAY -u WAYLAND_DISPLAY gamescope -W <w> -H <h> -w <w>
  -h <h> --backend headless -- godot ...`. Never a bare display, never
  `--display-driver x11` outside the wrapper.
- Captures of temporally-accumulated effects (TAA/SSR/SSIL/fog) need a settle
  (~240 frames) before the shot.
- UI verification happens at the user's real aspects (3440x1440, 5120x1440),
  not just the 1280x720 design resolution. `--window-size` + the tube-safe-area
  rule exist for this.

## Safety law (non-negotiable, DESIGN.md pillar 7)

- Nothing flashes above 3 Hz; every temporal-flash effect routes through the
  A11y caps (`a11y_flash` global). New feedback effects get a rate governor and
  a selftest.
- Color is never the only channel: shape tags, segment counts, numerals.
- Captions/subtitles ship OFF by default; toggles live under ACCESSIBILITY.
