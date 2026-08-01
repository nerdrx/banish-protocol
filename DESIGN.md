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

## Gameplay Loop (one run ≈ 15–25 min)

1. **Lobby** — crew of 1–4 readies up, picks loadout kit.
2. **Drop** — dropship cutscene → Deck 1 breach point.
3. **Dive** — explore procedurally generated decks: find salvage, activate O₂
   beacons, fight/avoid creatures, find the shaft down to the next deck.
4. **Pressure** — each deck is darker, richer, more hostile. Shared O₂ ticks down.
5. **Extract** — call the dropship at any breach point. Salvage banks only on
   successful extraction. Wipe = lose everything.

## Systems (v1 scope)

### Oxygen
- Single shared pool (e.g. 100 units/player in crew). Passive drain per living player.
- Sprint, flare throw, and damage-taken add drain spikes.
- **Beacons**: dormant machines on each deck; activating one (short channel,
  makes noise → attracts creatures) refills a chunk of the pool.
- At 0 O₂: screen closes in, health drains, crew has ~60s to extract.

### Decks (procgen)
- Room-and-corridor graph generation, seeded by server. 6–10 rooms per deck.
- Room archetypes: salvage hold, beacon chamber, nest, machinery, shaft room.
- Deck N modifiers: light density ↓, salvage value ↑, creature count ↑.

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
  (tension: who carries the haul?). Banked on extraction → crew score + meta currency
  (meta progression is post-v1).

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

- **M1 — Skeleton crew**: monorepo, server tick + rooms, client connect, players
  move on a test deck with prediction + interpolation. *Feels smooth with 2 clients.*
- **M2 — The dark**: procgen decks, lighting rig, fog, oxygen system + beacons, HUD.
- **M3 — The Husk bites**: creatures + AI, combat, downed/revive, salvage, descent
  + extraction loop. *A full run is playable.*
- **M4 — Expensive**: post-processing polish, audio, screen shake, lobby/menu flow,
  kill cams, low-O₂ presentation, balancing pass.
