# VOIDFALL — Design Document

> 1–4 player co-op descent into a dead alien megastructure adrift in deep space.

## Core Fantasy

You are a salvage crew diving into **the Husk** — a colossal derelict structure of
unknown origin, drifting in the black. Each run, your crew drops through the breach
and descends deck by deck. Deeper decks hold richer salvage — and less light, less
oxygen, and worse things living in the walls. The run ends when you extract… or when
the oxygen does.

## Design Pillars

1. **Shared breath.** The crew shares ONE oxygen reserve, fed through deck beacons.
   Sprinting, flares, and taking hits all drain it. Oxygen is the clock, the economy,
   and the argument the crew has over voice chat.
2. **Light is life.** Darkness is the primary antagonist. Flashlight cones, thrown
   flares, flickering emergency strips. Creatures avoid light and hunt in the dark.
3. **Greed kills.** Salvage is only banked when you extract. Every deck deeper
   multiplies the haul. The game constantly asks: *one more deck?*
4. **Expensive feel.** Every interaction has weight: dynamic lights and shadows,
   volumetric fog, bloom/grain/vignette, positional audio, screen shake, smooth
   60fps interpolated multiplayer.

## Gameplay Loop — roguelite descent (one dive ≈ 15–30 min)

The Husk is a vertical stack of **floors**. Each floor is one procedurally
generated deck (rooms + corridors). **Floor number = threat level**: deeper
floors spawn more, faster, tougher creatures — and richer salvage.

1. **Lobby** — crew of 1–4 readies up. The host picks the starting floor: any
   **Waystation** the crew has previously reached (floor 1, 6, 11, 16, …).
2. **Descend** — clear a path through each floor to its **drop shaft**, then
   ride it down. Salvage, beacons, fights, darkness.
3. **Waystations every 5 floors** — floors 5, 10, 15, … end in a Waystation:
   a lit, safe bay containing the extraction elevator and a Fabricator.
   Reaching one **permanently unlocks it** as a future starting point.
4. **Extract or push** — at a Waystation the crew chooses: extract (bank all
   carried salvage) or keep descending toward the next one, 5 more floors down.
5. **Wipe** — full crew death loses all *carried* salvage. Bought upgrades and
   unlocked Waystations are never lost.

## Meta-progression (persists across runs, per player)

- **Salvage is the only currency.** Carried salvage is lost on wipe; extracting
  banks it into your personal **wallet**, which persists across runs.
- **Fabricators** — one hidden somewhere on every floor, plus one guaranteed in
  each Waystation. Spend wallet + carried salvage on upgrades. Prices scale
  with upgrade tier, and Fabricators deeper in the Husk stock higher tiers.
- **Upgrades are permanent.** Once bought, an upgrade stays on your character
  forever — through extraction, death, and future runs. Dying only costs you
  the salvage in your pockets, never your build.
- **Upgrade tracks** (each 3–5 tiers): Suit (max O₂ share / passive drain ↓),
  Lungs (sprint cost ↓), Cutter (damage / range), Optics (flashlight width +
  brightness), Servos (move + revive speed), Hold (carry capacity, weight
  penalty ↓), Pouch (flare count), Plating (max health).
- **Starting deeper is the real difficulty knob.** A fresh character starts at
  floor 1; a veteran crew drops straight to Waystation 15 where floor-scaled
  enemies demand the upgrades they've accumulated. Risk stays honest: deeper
  start = deeper enemy level immediately.
- **Persistence**: each player's character (upgrade tiers, wallet, deepest
  Waystation reached) is saved locally on their own machine and announced to
  the host on join. Waystation starts require every crew member present to have
  unlocked that Waystation.

## Systems (v1 scope)

### Oxygen
- Single shared pool (e.g. 100 units/player in crew). Passive drain per living player.
- Sprint, flare throw, and damage-taken add drain spikes.
- **Beacons**: dormant machines on each deck; activating one (short channel,
  makes noise → attracts creatures) refills a chunk of the pool.
- At 0 O₂: screen closes in, health drains, crew has ~60s to extract.

### Floors (procgen)
- Room-and-corridor graph generation, seeded by host. 6–10 rooms per floor.
- Room archetypes: salvage hold, beacon chamber, nest, machinery, Fabricator
  alcove, drop-shaft room. Every 5th floor ends in a hand-authored Waystation.
- Floor N scaling (the threat curve): creature count ↑, creature speed/HP ↑,
  light density ↓, salvage value ↑, Fabricator stock tier ↑.
- Deeper floors drift from "spaceship" toward organic/wrong in palette + props.

### Creatures (v1: two species)
- **Skitters** — fast pack hunters, weak, avoid flashlight cones, swarm in the dark.
- **Bulwark** — slow heavy, immune to light-fear, area denial, guards rich rooms.
- Server-side AI: simple state machines (lurk → stalk → lunge), navigate room graph.

### Combat & tools
- Kit v1: cutter (hitscan, short range, low dmg — a tool, not a gun), flare pouch
  (limited), flashlight (infinite but a cone — you can't see behind you).
- Downed state: crewmates revive (channel). Solo down = death spiral unless O₂ trick.

### Salvage
- Glowing pickups, auto-magnet on proximity. Carried weight slows you slightly
  (tension: who carries the haul?). Carried salvage is spendable at Fabricators
  mid-run; banked into the persistent wallet only on extraction; lost on wipe.

## Multiplayer Architecture

- **Engine**: Godot 4.7, high-level multiplayer over ENet (UDP).
- **Topology**: host-authoritative listen server — one player hosts, the crew
  joins by IP (LAN or port-forward/tailscale). The host's simulation is the
  authority: all game state (O₂, creatures, salvage, doors) lives server-side.
- **Replication**: `MultiplayerSpawner` + `MultiplayerSynchronizer` for entities;
  RPCs for events (flare thrown, beacon activated, revive). Client-side input →
  server validates and simulates. Player movement uses client authority for
  responsiveness with server sanity checks (v1 pragmatism; tighten later).
- **Dedicated server**: headless export (`godot --headless -- --server`) kept
  working from M1 so a rented box can host later.
- **Lobby**: main menu → Host (pick port) or Join (IP:port) → crew lobby →
  host starts the dive. Seeded procgen: host rolls the seed, replicates it,
  every peer generates identical decks locally.

## Presentation

- **View**: first-person. Your flashlight cone is your world; you cannot see
  behind you. Crewmates are full 3D characters with visible flashlight beams.
- **Rendering**: Forward+ renderer. Near-black ambient, volumetric fog on
  (light shafts through dust), per-player SpotLight flashlights with shadows,
  flares as flickering OmniLights, dim emergency strips on emissive materials.
- **Post** (WorldEnvironment): glow/bloom, vignette + film grain (post shader),
  subtle chromatic aberration; low-O₂ and damage states push these harder.
- **Audio**: `AudioStreamPlayer3D` positional — creature skitters in the walls,
  beacon hum, your own breathing that tightens as O₂ drops. Reverb zones per
  room size. Music: sparse dark-ambient pads, combat stingers.
- **HUD**: diegetic-leaning — O₂ as a shared ring, health as suit glow, minimal
  text. Crewmate nameplates that fade with distance/darkness.

## Tech Stack

- **Godot 4.7** (Forward+), GDScript, static typing everywhere.
- Modular deck kit: corridor/room scenes assembled by seeded procgen at runtime.
- GUT (or plain `--headless` script tests) for sim logic: procgen determinism,
  O₂ math, AI state transitions.
- Native exports: Linux + Windows from day one (export templates installed).

```
voidfall/
  project.godot
  src/
    core/       autoloads: Net, GameState, Rng
    player/     controller, flashlight, interaction
    world/      deck procgen, rooms kit, props, beacons
    creatures/  AI state machines
    ui/         menus, lobby, HUD
  assets/       materials, sfx, fonts
  tests/        headless sim tests
```

## Milestones

- **M1 — Skeleton crew**: Godot project, ENet host/join, first-person controller,
  flashlight, moody greybox test deck. *Feels smooth with 2 clients.*
- **M2 — The dark**: procgen floors + drop shafts, floor-scaled generation,
  lighting rig, oxygen system + beacons, HUD.
- **M3 — The Husk bites**: creatures + floor-scaled AI, combat, downed/revive,
  salvage, Waystations, extraction. *A full dive is playable.*
- **M4 — The long game**: Fabricators + permanent upgrade tracks, per-player save
  files, Waystation-start lobby flow, wallet economy, balancing the threat curve.
- **M5 — Expensive**: post-processing polish, audio, screen shake, kill cams,
  low-O₂ presentation, menu/lobby polish, Linux + Windows export presets.
