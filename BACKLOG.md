# BACKLOG

Everything the M4.8 audit found that the fix pass did **not** land, grouped by
what it costs and why it was left. Audit IDs are kept so each line is traceable
back to a file:line finding and a written failure scenario.

Nothing here is a CRITICAL or a HIGH — all 18 of those are fixed. What is left is
the MEDIUM performance cluster, a set of latent traps that are unreachable today,
and the cosmetic LOWs.

The fix pass closed, inline, every finding it happened to be standing in already:
M2, M3, M4b, M8, M16, M18, M24, L2, L3, L4, L9, L13, L14, L17, L18, plus the
whole of systemic pattern #10 (stale load-bearing comments). Those are not
repeated here.

---

## Performance cluster — where to look first if deep layers drop frames

These scale with layer size, which scales with depth, so the symptom is "it gets
worse the further down we go" — which is also what the difficulty curve looks
like, and is therefore easy to attribute to the wrong thing. Measure before
optimising: `--log-fps 5` prints average, 1% low, worst frame, draw calls and
primitives per window.

**M1 — `Net.crew.keys()` allocates an Array inside per-frame loops, 22 call sites.**
`src/world/data_shard.gd`, `data_bundle.gd`, `creatures/antivirus.gd`,
`core/run_state.gd`, `player/player.gd`, plus `hud.gd`, `layer.gd`, `modules.gd`,
`debug.gd`. Worst offender is `DataShard._nearest_carrier`, called from `_process`
for every shard on the layer every frame — 30-40 shards × 4 players is ~40 Array
allocations and ~320 node lookups per frame for objects mostly nowhere near a
player. Fix: iterate the dictionary directly (`for id: int in Net.crew:` — no
allocation) everywhere, and early-out the magnet on a cheap squared distance.

**M6 — `Antivirus._running_players()` rebuilds two Arrays per call.**
`src/creatures/antivirus.gd:310-323`. Called from `_nearest_player`,
`_swept_player`, `_strike`, and — the one that matters — `Sentinel._look_subject`
(`sentinel.gd:772-782`), which runs from `_process`, i.e. every frame on every
peer rather than at `AI_TICK`. Same fix as M1.

**M7 — `Antivirus._in_player_light` sweeps the flare group per creature per tick.**
`src/creatures/antivirus.gd:372-377`. `get_nodes_in_group("flares")` allocates
per creature per `_think` (15 Hz × ~12 creatures). Cheap individually; same
convention fix as M1/M4/M6.

**M4 — `Layer._process` walks the entire built layer every frame.**
`src/world/layer.gd` `_process`/`_alert_amount`, `src/world/light_rig.gd:192-193`.
Three unconditional costs stack: a fresh `get_nodes_in_group(Antivirus.GROUP)`
Array; `LightRig.set_alert` running `root.find_children("*", "Light3D", true,
false)` — a recursive walk of every descendant of the builder, every kit module
and every Decal, with an `is_class` and a name `match` per node and a fresh
result Array, 60+ times a second; and six `set_shader_parameter` calls on the
~99% of frames where nothing moved. Fix: cache the Light3D list at build time
(`layer.gd` already walks it once for the census), cache the creature list on
`Run.layer_changed` / `Antivirus.died`, and early-out when `_alert` is unchanged.
*Note: M4b, the stale `_alert` surviving a descent, is fixed.*

**M5 — per-instance emissive materials written every frame, in ten files.**
`scrubber.gd`, `sentinel.gd`, `data_shard.gd`, `data_bundle.gd`, `siphon_tap.gd`,
`drop_shaft.gd`, `backdoor_node.gd`, `exfil_uplink.gd`, `compiler_terminal.gd`,
`flare.gd`. Each builds its own `StandardMaterial3D` (necessary — the state read
*is* per-instance) then pushes every uniform to the RenderingServer every frame
regardless of change, and no two props of the same type ever batch. On a layer
with 12 creatures, 40 shards, 2 taps, a shaft and a compiler that is several
hundred material updates per frame. Fix: one `set_if_changed` helper, plus share
one material between props whose state is genuinely shared.

**M13 — the Compiler panel is rebuilt from scratch every frame.**
`src/ui/compiler_panel.gd` `_process` -> `_refresh()`, unconditional, no dirty
check. Per frame: eight `Modules.quote()` calls each building a fresh 8-key
Dictionary; eight `PackedStringArray` pip builds + `"".join`; eight
`_effect_line` calls each a `%` format over a temporary Array; ~48
`add_theme_color_override` writes, each pushing `NOTIFICATION_THEME_CHANGED` down
the subtree and invalidating a Label text buffer; and a
`Net.get_player(Net.local_id())`. Fix: re-run `_refresh_row` only when
`_selected`, `_beat`, `_refuse`, the tier table or the wallet actually changes.

**M14 — `Run.corrupted_crew()` allocates and sorts an Array every HUD frame.**
`src/ui/hud.gd` -> `src/core/run_state.gd` `corrupted_crew`. Builds a new
`Array[int]`, appends every corrupted key and sorts it — every frame, including
the common case where nobody is down. When someone *is* down it additionally
builds a `PackedStringArray`, one `%` format per downed peer and a `"\n".join()`,
per frame. Fix: early-out on `Run.corrupted.is_empty()`, and rebuild the alert
text only when the set or the whole-second countdown changes.

**M15 — HUD theme overrides and string formatting every frame.**
`src/ui/hud.gd`, five sites. Seven `add_theme_color_override` calls and five
`%`-formatted temporaries per frame, none guarded by a change check.
`Label.set_text` early-outs on an identical string, so the text is cheap *after*
formatting — but the allocation and every theme-override write happen regardless.
The file already caches `_last_cycles_text` / `_last_data_text` for the phosphor
ghosts, so the machinery exists. Fix: compare against the cached value first.

**M23 — main-menu caret colour override written every frame.**
`src/ui/main_menu.gd` `_update_terminal`, from `_process`. Writes
`add_theme_color_override("caret_color", ...)` unconditionally, so the LineEdit
takes a theme-changed notification and a redraw every frame the menu is up, for a
~1.6 Hz blink. Fix: write only on the transition.

**M19 — `CreatureKit.matte()` allocates a unique material per creature for constant colours.**
`src/creatures/creature_kit.gd:120-126`, called from `scrubber.gd` and
`sentinel.gd`. The file header correctly justifies per-instance materials for the
*emissive* slots so two Scrubbers can flash independently; `Body` and `Plate` are
constant colours and get no such benefit. With `antivirus_budget` up to 12 that is
~24 redundant unique material states on a deep layer, and no Scrubber body batches
with any other's. Fix: hoist the constant `Body`/`Plate` materials to `static var`
singletons; keep `emissive()` per instance.

**M17 — the HUD roster rebuild operates on nodes already queued for deletion.**
`src/ui/hud.gd` `_rebuild_crew`. `queue_free()` is deferred to end of frame, so
`_crew_list` still holds the old rows *and* the new ones; `_refresh_link` then
does full work on both sets. The `VBoxContainer` lays out both, so the roster
visually doubles for one frame on every join/leave. Fix: `remove_child(child)`
before `queue_free()`.

---

## Correctness, not yet reachable

Latent traps: correct today by accident or by call-site discipline, wrong the
moment something moves.

**M11 — client-authoritative movement feeds host logic.**
`src/player/player.gd` `sync_position` + `player.tscn`'s `SceneReplicationConfig`,
consumed in `run_state.gd` (muster radius, restore reach, breaker origin, exfil
pad) and `prop_state.gd`. *Partly closed:* every host-side consumer of a
client-owned position now `is_finite()`-tests it and every distance guard is
spelled to fail closed, so NaN no longer walks through. What is still open is the
DESIGN.md "host sanity checks" that were deferred: a per-tick displacement bound,
so a client cannot teleport across the layer between two legal-looking positions.
That is a real anti-cheat feature rather than a bug fix, which is why it is here.

**M21 — `LightRig.set_alert`'s meta default lets an unregistered light ratchet to full red.**
`src/world/light_rig.gd:195`. `light.get_meta("authored_color", light.light_color)`
defaults to the light's *current* colour, so a `Key*`/`Accent*`/`Practical*`-named
light that never went through `_remember` re-lerps its own current colour toward
`HOSTILE` every frame (and per M4 `set_alert` runs every frame), converging to
full red at any constant non-zero alert. Not reachable today — every light under
the builder is registered — but `geometry_kit.gd:955-957` hand-copies the three
`set_meta` lines onto `Practical_trace`, which reads like this trap was hit once
and patched at the call site rather than at the source. Fix: skip lights lacking
`authored_color`, or make `_remember` idempotent and lazily invoked.

**M22 — `KitLib._loaded` is latched before the load is attempted.**
`src/world/kit_lib.gd:39` vs `:42-51`. If the `.glb` or a `.tres` fails to load
the flag is already set and there is no retry: `_meshes` stays empty and every
`spawn` pushes an error and returns null for the rest of the process, while a
partially-populated `_materials` leaves affected surfaces on the `.glb`'s
placeholder materials. One bad import gives a layer with full colliders and no
visible walls. Fix: set `_loaded = true` only after both loops complete — the same
change `CrewAvatar._loaded` (M18) already got.

**L16 — `CreatureKit`'s three finders null-deref if handed null.**
`src/creatures/creature_kit.gd:72`, `:83`, `:95`. `null as MeshInstance3D` yields
null, the recursion guard misses, and the next line dereferences. Every current
caller is guarded, so there is no reachable null-deref today. Fix: `if root ==
null: return null` in the three finders.

**L6 — `_hops` packs room pairs as `root * 100 + target` while `_edge_key` uses `* 1000`.**
`src/world/layer_graph.gd:597-598` vs `:359`. Both are safe at today's 10-room
maximum, but the two encodings disagree and the ×100 version silently collides
above 100 rooms.

**L21 — `Layer._descend`'s coroutine is silently abandoned if the session ends mid-descent.**
`src/world/layer.gd` `_descend`. **[verified 4.7.1]** a coroutine awaiting a
`SceneTreeTimer` whose `self` has been freed is dropped with no error and no
resumption, so `Run.finish_descent` is skipped — harmless *only* because
`Net.leave` -> `Run.reset()` clears `descending`. Worth knowing it is luck rather
than design; the same pattern elsewhere would leave half-applied state.

---

## Dead code and dead claims

**M9 — the `Rng` autoload's entire named-stream API is dead.**
`src/core/rng.gd:10`, `:35-53`. `Rng.stream()`, `Rng.fresh()` and `Rng.seed_for()`
have zero call sites in `src/`. `LayerGraph` derives its sub-seed inline with the
same `hash(str(...))` formula and a comment explaining why it bypasses the
autoload. Dead determinism infrastructure is a trap: it looks tested and is not,
and the caching in `stream()` has the opposite semantics from what procgen needs.
Fix: delete it, or wire `LayerGraph` through `Rng.fresh()` so there is one
implementation. **Touching this means re-running the determinism dump.**

**L19 — `KitLib` has two dead statics and one silent no-op.**
`src/world/kit_lib.gd:100` (`material()`) and `:119` (`module_names()`) have zero
callers. `_bind`'s `if array_mesh != null` guard means a primitive-mesh module
silently keeps its placeholder material with no warning.

**L9 (half done) — `Flicker.bind_emissive()` still has no callers.**
`src/world/flicker.gd`. The misleading comment is fixed and the gap is now named
in the docstring, but the mechanism is still not wired: SpotLight keys and accents
flicker without their emissive housings dimming with them. Fix: call it from
`LightRig.flicker` for fixtures that have one.

---

## Presentation and consistency

**M12 — two different clocks drive presentation.**
`UiFx.clock()` (frame-counting during automated runs, so captures are
reproducible) is used in `compiler_terminal.gd`, `flare.gd`, `player.gd`.
`Time.get_ticks_msec()` is used in `siphon_tap.gd`, `drop_shaft.gd`,
`backdoor_node.gd`, `exfil_uplink.gd`, `data_shard.gd`, `data_bundle.gd`,
`scrubber.gd`, `sentinel.gd`. The `--screenshot` / `--hud-state` reproducibility
guarantee therefore only holds for about a third of the animated surfaces — which
quietly halves the value of the capture tooling. Fix: one clock, and it should be
`UiFx.clock()`.

**M20 (comment fixed, mechanism not) — `ScanSweep` peers are not in phase.**
`src/world/scan_sweep.gd`. The false claim is now documented as false. Making it
true means driving `t` off a shared run clock. Cosmetic — the Sentinel's own sweep
is replicated — but "is the beam on me?" is a thing four players say out loud.

**L10 — Flicker phase is seeded but its clock is not.**
`src/world/flicker.gd:32`, `src/world/flicker_light.gd:83`, vs the header claim at
`flicker_light.gd:14-19` that "four clients must see the same fixture do the same
thing". The seed fixes the phase *offset*; `_t += delta` starts at zero on
whatever frame that peer built the layer, so a late joiner sees different
dropouts. Same family as M12 and fixed by the same shared clock.

**L11 — an evicted achievement toast's tween outlives its card. (PLAUSIBLE)**
`src/ui/achievement_toast.gd:38-41` + `:91`. The tween is created with
`self.create_tween()` so it is bound to the `CanvasLayer`, not to `slot`; freeing
`slot` does not kill it. `PropertyTweener` no-ops on a dead target, but
`tween_callback(slot.queue_free)` still fires on a freed object. Confirm with
`--grant ALL` (the exact case the `MAX_VISIBLE` comment names) or five
near-simultaneous unlocks, then check stderr for
"Error calling method from CallbackTweener". Fix: `tween.bind_node(slot)`.

**L12 — toast reveal height latches on the tween's first tick. (PLAUSIBLE)**
`src/ui/achievement_toast.gd:82-87`. `full` is lambda-captured and latched on
first invocation; if the `VBoxContainer` has not sorted `slot` yet, `slot.size.y`
is 0 and `full` latches to `1.0`, which with `clip_contents = true` leaves a
permanently 1-px strip. Certain regardless of ordering: `custom_minimum_size.y` is
never released, so the card cannot reflow if the autowrapped note re-wraps.

**L15 — `ScanSweep.set_intensity()` is clobbered on the next frame when `driven == false`.**
`src/world/scan_sweep.gd:33-35` vs `:42-45`. `_process` recomputes `light_energy`
from `_base_energy` and ignores the scale. Not reachable today (the only caller
sets `driven = true`), but the API contract is wrong.

**M10 — `_reconcile` is re-broadcast to the whole crew on every roster change.**
`src/creatures/antivirus_director.gd:45-50`. Fires on every `crew_changed`, which
includes every `_crew_notice` and every `Modules.push_crew()` after a purchase —
not just joins. Idempotent and small, but it means every Compiler purchase
broadcasts the dead-creature list to everyone.

**L5 — `Scrubber`'s per-creature RNG is not seeded from the run seed.**
`src/creatures/scrubber.gd:113` — `hash(str(slot_index, ":scrubber:",
layer_number))`. Host-local behaviour only, so no determinism consequence, but
Scrubber 0 on layer 3 wanders identically in every run of every seed.

**L7 — `Antivirus._tell_crew` hardcodes the host as peer 1.**
`src/creatures/antivirus.gd:503-509`. Correct for Godot and correct for the
dedicated-server case, but one of several places where `1` is spelled out rather
than derived.

---

## Naming and housekeeping

**L1 (mostly landed in M4.8) — leftover `NULLVOID` strings.**
Every user-visible one is gone: `SteamHub.GAME_TAG`, the menu's "NO FRIENDS
RUNNING …" line, the layer-dump header and the Achievements log all read LIMBO
PROTOCOL. Two things remain. `src/core/steam_service.gd` writes `KEY_VERSION` as
`GAME_TAG + " M3.5"` — the milestone is three releases stale and friends' clients
read it before joining. And `NULLVOID` still appears in comments and docstrings
across 16 files; cosmetic, and cheapest to do as one sweep rather than
opportunistically.

**L20 — `src/ui/nullvoid_theme.tres` is referenced from three scenes.**
`src/ui/hud.tscn:4`, `src/ui/main_menu.tscn:4`,
`src/ui/achievement_toast.tscn:4`. A rename-or-leave decision rather than a bug —
listed so it is a decision rather than an oversight.

---

## Conventions worth landing once rather than thirty times

From the audit's systemic-patterns section. Three of the twelve are now project
conventions with the code to match (`as` used as a type test; `any_peer`
validation preamble; distance guards that fail closed). These are the ones left:

- **#5 / #6** — `Dictionary.keys()` and `get_nodes_in_group()` inside `_process`
  (22 and ~8 call sites), and `Net.get_player(id)` being two `get_node_or_null`
  calls inside per-object per-frame loops. It wants to be a cached
  `Dictionary[int, Node]` maintained at spawn/despawn. This is M1/M6/M7 and most
  of the perf cluster, as one change.
- **#9** — per-frame unconditional writes to per-instance materials, theme
  overrides and panel rebuilds (M5, M13, M15, M23). One `set_if_changed` helper
  plus a dirty flag on the four `_process` hotspots covers all of them.
- **#12** — hand-maintained parallel arrays. The one that broke (C6) is fixed and
  its arrays now have a single append helper, but `LayerGraph` has six more pairs
  (`shard_points`/`shard_rooms`, the four `compiler_*`, `scrubber_nests`/
  `scrubber_nest_rooms`, `sentinel_posts`/`sentinel_post_rooms`) that are correct
  only because each pair is appended in the same loop body. One append helper per
  pair, and iterate the shorter container.
- **#8** — two presentation clocks (M12), which halves the reproducibility the
  `--screenshot` / `--hud-state` tooling exists to provide.
