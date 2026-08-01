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

- **Authoritative server**: Node.js + `ws`, fixed 30Hz simulation tick.
- **Client**: prediction for own movement, snapshot interpolation (~100ms buffer)
  for everything else. Server reconciliation with input sequence numbers.
- **Shared package**: all sim constants, types, and movement code shared between
  client and server so prediction matches authority.
- **Protocol**: binary-friendly design (typed message enums, flat arrays), JSON in
  early milestones, binary (ArrayBuffer) once stabilized.
- **Rooms**: lobby → room code (4 letters) → crew joins → server spawns a run
  instance per room.

## Presentation

- **View**: top-down-ish 3D (Three.js), camera slightly tilted, close to the crew.
  Gameplay is on a 2D plane; the third dimension is for lighting and depth.
- **Lighting**: near-black ambient. Per-player flashlight (spotlight + shadow),
  flares (point light, flicker, finite life), emergency strips (dim, flicker).
- **Post**: bloom, vignette, film grain, subtle chromatic aberration; low-O₂ and
  damage states push these harder.
- **Fog**: volumetric-feel layered fog planes / animated noise; dust motes in beams.
- **Audio**: WebAudio positional — creature skitters in the walls, beacon hum,
  your own breathing that tightens as O₂ drops. Music: sparse dark-ambient pads,
  combat stingers.
- **HUD**: diegetic-leaning — O₂ as a shared ring, health as suit glow, minimal text.

## Tech Stack

```
voidfall/
  packages/
    shared/    TS — protocol, sim constants, movement, procgen (seeded)
    server/    Node 20+, ws — authoritative sim, rooms, AI
    client/    Vite + Three.js — rendering, prediction, VFX, audio, UI
```

TypeScript everywhere. npm workspaces. Vitest for sim tests.

## Milestones

- **M1 — Skeleton crew**: monorepo, server tick + rooms, client connect, players
  move on a test deck with prediction + interpolation. *Feels smooth with 2 clients.*
- **M2 — The dark**: procgen decks, lighting rig, fog, oxygen system + beacons, HUD.
- **M3 — The Husk bites**: creatures + AI, combat, downed/revive, salvage, descent
  + extraction loop. *A full run is playable.*
- **M4 — Expensive**: post-processing polish, audio, screen shake, lobby/menu flow,
  kill cams, low-O₂ presentation, balancing pass.
