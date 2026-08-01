# NULLVOID — Design Document

> 1–4 player co-op first-person roguelite. You are an invading program descending
> through the security layers of a rogue AI to steal its data. Its antivirus is
> hunting you.

## Core Fantasy

**MOTHER** is a rogue AI — a planet-scale machine intelligence that went silent
decades ago and answers to no one. Its vaults hold the most valuable data in
existence. You are an **intrusion program**: a human-built agent injected into
MOTHER's system, rendered inside its architecture as a physical avatar.

The system is a vertical stack of **security layers** — privilege rings. The
surface layers are public-facing infrastructure: clean, geometric, half-lit.
The deeper you descend, the closer you get to the **Kernel** — and the older,
stranger, and more hostile the architecture becomes. MOTHER's **antivirus
processes** patrol the dark. They cannot tell the crew what they are; they only
know something foreign is running.

Steal the data. Reach a backdoor. Exfiltrate before the system decompiles you.

## Why you can go deeper (the fiction earns the roguelite)

- **Backdoors**: every 5th layer contains a dormant maintenance node. Rooting it
  installs a permanent **backdoor** — future intrusions can inject directly to
  any backdoor the crew has installed. Checkpoints aren't a game abstraction;
  they're the crew physically compromising MOTHER's infrastructure, run by run.
- **Permanent upgrades**: you are software. Modules compiled into your codebase
  stay compiled — deletion in-system only kills the running instance; your
  source is safe outside. Losing a run costs the data in your buffers, never
  your build.
- **Deeper = more dangerous, by definition**: lower rings run older, heavier,
  more paranoid security. Layer number *is* the antivirus privilege level.

## Design Pillars

1. **Shared Cycles.** The crew runs on ONE stolen pool of compute **Cycles** —
   the oxygen of cyberspace. Passive drain while you exist; sprinting, taking
   damage, and burning flares spike it. Siphon taps refill it — loudly. Cycles
   are the clock, the economy, and the argument the crew has over voice chat.
2. **Light is decryption.** Unrendered space is near-black — encrypted geometry
   your beam resolves into visibility. Antivirus processes avoid decryption
   beams (exposure) and hunt in the dark. You cannot see behind you.
3. **Greed kills.** Data banks only on exfiltration. Every layer deeper
   multiplies the haul. The game constantly asks: *one more ring?*
4. **Expensive feel.** Dynamic light and shadow, volumetric haze, bloom/grain/
   glitch, positional audio, screen shake, buttery multiplayer.

## Gameplay Loop — descent through the rings (one intrusion ≈ 15–30 min)

1. **Lobby** — crew of 1–4 readies up. Host picks the injection point: layer 1,
   or any **backdoor** every present crew member has installed (6, 11, 16, …).
2. **Descend** — fight/sneak through each procedurally generated layer to its
   **drop shaft** (a data trunk running deeper), then ride it down.
3. **Backdoor layers every 5** — layers 5, 10, 15 … end in a dormant node room:
   root it (channel, noisy, defend the crew) to install the backdoor — safe
   room, exfil uplink, and a guaranteed Compiler.
4. **Exfiltrate or push** — at a backdoor: upload out (bank all buffered data)
   or descend toward the next node, 5 rings deeper.
5. **Wipe** — full crew deletion loses all *buffered* data. Compiled modules
   and installed backdoors are never lost.

## Meta-progression (persists across runs, per player)

- **Data is the only currency.** Buffered data is lost on deletion; exfiltrating
  banks it to your persistent **archive** (wallet).
- **Compilers** — one hidden on every layer, one guaranteed per backdoor node.
  Spend archive + buffered data on modules. Deeper Compilers stock higher tiers.
- **Modules are permanent.** Compiled into your source forever — through
  exfiltration, deletion, everything.
- **Module tracks** (3–5 tiers each): Runtime (max Cycles share / passive drain ↓),
  Threading (sprint cost ↓), Breaker (cutter damage/range), Optics (beam width +
  brightness — literally buying vision), Servos (move + restore speed), Buffer
  (carry capacity, weight penalty ↓), Cache (flare count), Checksum (max
  integrity/health).
- **Injecting deeper is the real difficulty knob**: backdoor 15 drops you into
  layer-16 antivirus immediately. Unlocks and threat scale together.
- **Persistence**: each player's program (module tiers, archive, deepest
  backdoor) saves locally on their machine, announced to the host on join.
  Backdoor injection requires all present crew to have installed it.

## Systems (v1 scope)

### Cycles (shared resource)
- Single shared pool (e.g. 100 units per crew member). Passive drain per running
  player. Sprint, flare burn, and damage-taken add drain spikes.
- **Siphon taps**: dormant junctions on each layer; tapping one (short channel,
  loud — pings the antivirus) refills a chunk of the pool.
- At 0 Cycles: framerate-of-self degrades — vision closes in, glitches, integrity
  drains. ~60s to reach an uplink before the crew decompiles.

### Layers (procgen)
- Room-and-corridor graph generation, seeded by host. 6–10 rooms per layer.
- Room archetypes: data vault, siphon junction, nest (quarantine block),
  bus/machinery, Compiler alcove, drop-shaft trunk. Every 5th layer ends in a
  hand-authored backdoor node room.
- Layer N scaling (the threat curve): antivirus count ↑, speed/HP ↑, ambient
  light ↓, data value ↑, Compiler stock tier ↑.
- **Aesthetic gradient**: surface rings are clean modern datacenter-brutalism —
  monolithic slabs, glass conduits, orderly circuit traces. Deeper rings decay
  into legacy architecture: corrupted geometry, dead sectors, glitching
  surfaces, organic-looking cable growths — MOTHER's oldest code, half-mad.

### Antivirus (v1: two processes)

**The killability law (design invariant): every monster dies to the breaker.**
Nothing in MOTHER is immune — you can always delete the running instance. You
just can't delete the *process*: she recompiles it. Persistence comes from
respawn and behavior, never from immunity. Terror must never read as "your
gun is useless," only as "shooting is one of several competing options."

- **Scrubbers** — fast pack hunters, weak (2-3 breaker hits), avoid decryption
  beams, swarm from the dark. The system's cheap, disposable cleaners.
- **Sentinel** — slow heavy quarantine process, heavily armored (~20x Scrubber
  HP) with an exposed emissive core that takes bonus damage during its SCAN
  and PURGE states (shielding drops to act). A solo kill is a huge investment;
  a crew kill is a coordinated takedown. Drops a burst of data shards. Area
  denial, guards data vaults, announces itself with a red scan sweep.
- Host-side AI: state machines (idle patrol → trace → purge), navigate the
  room graph. Stats scale with layer number.

### Combat & tools
- Kit v1: **breaker** (short-range hitscan cutter — a tool, not a gun),
  **flares** (burn Cycles+Cache stock, cast wide light, repel Scrubbers),
  headlamp beam (infinite, but a cone).
- Corrupted (downed) state: crewmates restore you (channel). Solo corruption =
  countdown to deletion.

### Data (salvage)
- **Tokens on the ground**: flat hexagonal data chips (~10-15cm) lying on the
  floor — mostly dark material, thin emissive circuit inlay, soft slow pulse,
  small light pool beneath (wet-floor reflections carry visibility). Sparse
  singles in rooms, clustered spills in vaults. Never a glowing volume —
  realistic, immersive, dark. Auto-magnet on proximity. Buffered weight slows
  you slightly (who carries the haul?). Spendable at Compilers mid-run; banked
  to archive only on exfiltration; lost on deletion.

## Multiplayer Architecture

- **Engine**: Godot 4.7, high-level multiplayer over ENet (UDP).
- **Topology**: host-authoritative listen server — one player hosts, the crew
  joins by IP (LAN or port-forward/tailscale). The host's simulation is the
  authority: all game state (Cycles, antivirus, data, doors) lives host-side.
- **Replication**: `MultiplayerSpawner` + `MultiplayerSynchronizer` for
  entities; RPCs for events (flare, siphon tap, restore). Player movement is
  client-authoritative for responsiveness with host sanity checks (v1
  pragmatism; tighten later).
- **Dedicated server**: headless export (`godot --headless -- --server`) kept
  working from M1.
- **Lobby**: main menu → Host (port) or Join (IP:port) → crew lobby → host
  starts the intrusion. Host rolls the seed, replicates it; every peer
  generates identical layers locally.

## Presentation

- **View**: first-person. Your decryption beam is your world; you cannot see
  behind you. Crewmates are humanoid program avatars — sleek dark shells with
  emissive circuit seams in their player color, visible beams in the haze.
- **Rendering**: Forward+. Near-black ambient, volumetric haze (beams read as
  shafts), per-player SpotLight beams with shadows, flares as flickering
  OmniLights, emissive circuit traces on architecture (dim, pulsing — data
  flowing through conduits).
- **Environment language**: modern/futuristic digital brutalism — matte black
  monoliths, hairline neon circuit inlays, holographic glyph panels, data
  conduits with light pulses, floor grids that light briefly underfoot.
  Hostile events tint the architecture red (scan sweeps, purge alarms).
  Deeper = older = corrupted: z-fighting shimmer zones, dead-pixel clusters,
  geometry that repeats wrong.
- **Decals — MOTHER talks to her processes**: wall signage seeded by procgen
  (2-5/room, deterministic). Propaganda to her own daemons ("EVERY CYCLE
  ACCOUNTED", "QUARANTINE IS MERCY"), wayfinding ("TRUNK 04 →", "VAULT
  ACCESS"), hazard warnings, and — in deep layers — corrupted remnants of the
  humans who built her ("NORTHCAIRN SYSTEMS · MOTHER SERVES"), increasingly
  glitched with depth. Dim albedo + restrained emissive, weathered; invented
  glyph-blocks mixed among readable text. Never glowing billboards.
- **Post** (WorldEnvironment + CanvasLayer shader): glow/bloom, vignette, film
  grain, subtle chromatic aberration; low-Cycles and damage push these into
  **glitch** territory — datamosh smears, scanline tears, brief palette
  inversions.
- **Audio**: positional `AudioStreamPlayer3D` — Scrubber chittering-static in
  the walls, conduit hum, siphon taps like breathing pressure valves; your own
  process-hum that strains as Cycles drop. Music: sparse dark synth pads,
  combat = driving low-BPM electronic pulse.
- **HUD**: diegetic program-shell UI — shared Cycles ring, integrity as shell
  glow, buffered-data readout, crewmate tags that fade with distance/darkness.

## Steam Integration

- **Plugin**: GodotSteam GDExtension (4.21+, Steamworks SDK 1.65) + its
  MultiplayerPeer — drops into Godot's high-level multiplayer, so the existing
  Spawner/Synchronizer/RPC stack runs over Steam sockets unchanged.
- **Transport abstraction**: the menu offers **STEAM** (default when Steam is
  running: friend lobbies, invites, join-in-progress via overlay, no IPs ever)
  and **DIRECT** (ENet by IP — LAN parties and the dedicated headless server
  keep working forever; Steam is a transport, not a dependency).
- **Lobby flow**: Host → Steam lobby (friends-only default) → invite via
  overlay / join via friends list → SteamMultiplayerPeer handshake → existing
  Net handshake unchanged. Rich presence: "Descending · LAYER 07 · 3/4 crew".
- **Dev App ID**: 480 (Spacewar, Valve's public test app) until NULLVOID has
  its own Steam Direct app page. `steam_appid.txt` is dev-only, never shipped.
- **Achievements**: an `Achievements` autoload owns definitions + unlock state;
  persists locally (user://) always, mirrors to Steam stats/achievements when
  the API is live. On real-App-ID day the definitions upload to Steamworks and
  everything retro-syncs on first boot. Cloud saves via Steam Auto-Cloud
  (config-only) at ship time.

### Achievement list (v1)

| ID | Name | Trigger |
|---|---|---|
| `FIRST_DELETION` | Garbage Collection | Delete your first Scrubber |
| `ROOTED` | Rooted | Install your first backdoor |
| `NULL_AND_VOID` | Null and Void | Wipe with zero buffered data |
| `ONE_MORE_RING` | One More Ring | Descend past a backdoor without exfiltrating |
| `PACIFIST_PROTOCOL` | Pacifist Protocol | Exfiltrate without deleting a single process |
| `LIGHTS_OUT` | Lights Out | Survive 60s at zero Cycles and still exfiltrate |
| `NO_AGENT_LEFT` | No Agent Left Behind | Full 4-crew exfiltration, everyone alive |
| `COLD_BOOT` | Cold Boot | Exfiltrate a solo intrusion |
| `DEEP_STATE` | Deep State | Root the layer-15 backdoor |
| `KERNEL_PANIC` | Kernel Panic | Reach layer 25 |
| `HOARDER_BUFFER` | Buffer Overflow | Exfiltrate carrying 100+ data in one run |
| `MOTHERS_FAVORITE` | Mother's Favorite | Get restored 3 times in one intrusion |

## Tech Stack

- **Godot 4.7** (Forward+), GDScript, static typing everywhere.
- Modular layer kit: corridor/room scenes assembled by seeded procgen at runtime.
- Headless script tests for sim logic: procgen determinism, Cycles math, AI
  state transitions, module pricing.
- Native exports: Linux + Windows from day one (export templates installed).

```
nullvoid/
  project.godot
  src/
    core/       autoloads: Net, GameState, Rng, Debug
    player/     controller, beam, interaction
    world/      layer procgen, rooms kit, props, siphons, backdoors
    creatures/  antivirus AI state machines
    ui/         menus, lobby, HUD
  assets/       materials, sfx, fonts
  tests/        headless sim tests
```

## Milestones

- **M1 — Skeleton crew**: Godot project, ENet host/join, first-person controller,
  beam/flashlight, moody greybox test layer. *Feels smooth with 2 clients.*
- **M2 — The dark**: procgen layers + drop shafts, layer-scaled generation,
  lighting rig, Cycles system + siphon taps, HUD.
- **M3 — The system bites**: antivirus + layer-scaled AI, combat, corrupted/
  restore, data shards, backdoor nodes, exfiltration. *A full intrusion is
  playable.*
- **M3.5 — Steamworks**: GodotSteam GDExtension, Steam lobbies + invites +
  join-in-progress, SteamMultiplayerPeer transport beside ENet, rich presence,
  Achievements autoload (local-first, Steam-mirrored), dev on App ID 480.
- **M3.7 — Embodiment & Overhaul** (the Expensive pass, pulled forward from M5
  by user priority; merges two parallel out-of-tree workstreams: the creature
  models in `nullvoid-art/` — Scrubber v2, Sentinel dressing kit, Hound
  concept — and the `nullvoid-lookdev/` graphics kit: beveled modular
  architecture, roughness-varied PBR, wet-floor SSR, light projectors,
  SSAO/SSIL, animated emissive flow, post shader v2. User assets below
  integrate in the same pass.) (user-provided assets in `/mnt/.../3dprops/`):
  **Gun_Surge.fbx** → the breaker: first-person viewmodel + third-person prop
  socketed to crewmate hands, muzzle-anchored beam-lash VFX, NULLVOID material
  pass (matte black + teal emissive slots), 0.01 import scale fix.
  **CyberSentinel.fbx** → used TWICE, palette-split for instant readability:
  - **Sentinel (enemy)**: near-black matte body, RED glowing accents/emissive
    (eyes, seams, Emiss slots). No baked anims — by design it does NOT walk:
    frictionless glide with glitch-stutter on direction change, procedural
    head-track via eye/head bones so it watches players, jaw bone for the
    scream, IK claw plants on lunge.
  - **Crew avatar (interim, but long-lived)**: same model, INVERTED —
    bright/pale shell with blue glowing accents (default swatch bright blue;
    accent tint follows the lobby shell-marker color so crewmates stay
    tellable-apart). Full authored locomotion set, built as cyclic keyframe
    animations on the rig in Blender (headless-scripted, digitigrade gait):
    idle (weight shift + tail sway + ear/head micro-motion), walk, run
    (forward lean), plus corrupted-kneel and restore-rise poses for M3 states.
    Godot AnimationTree blends by replicated speed; procedural head-look and
    movement lean layered on top. Retires whenever the user ships a dedicated
    player model.
  FBX→glTF via Blender 5.2 headless (pipeline verified).
- **M4 — The long game**: Compilers + permanent module tracks, per-player save
  files, backdoor-injection lobby flow, archive economy, threat-curve balancing.
- **M5 — Expensive**: post/glitch polish, audio, screen shake, kill cams,
  low-Cycles presentation, menu/lobby polish, Linux + Windows export presets.
- **M6 — The Haunting**: MOTHER becomes the horror director + hunter processes.

## M6 — The Haunting (design arc, post-v1)

Goal: *proper scary, never hardcore.* Terror and punishment are different
axes — max the first, cap the second. The killability law applies to every
hunter below: all of them die to the breaker; persistence is respawn + memory,
never immunity.

### The Director
MOTHER always knows where the crew is (you run inside her); her processes only
know what she tells them — a canonical two-brain setup (Alien: Isolation) with
L4D-style pacing: she tracks crew stress (recent damage, Cycles, time since
last scare) and paces leaks of your position — quiet dread, spike, mercy.
When the crew is broken and limping she withholds (a predator toys with dying
prey): invisible rubber-banding that reads as lore, not difficulty settings.

### Hunter processes (each hunts by a different sense; counters conflict)
- **The Hound** — hears. Spawned by noise debt (siphons, breaker fire,
  sprinting). Relentless pursuit; at low HP it flees to darkness to recompile
  (wounded-animal window — chase it or let it go). Killable with focused fire:
  a real crew decision with a real reward (large data burst + silence). But
  the process survives: minutes later MOTHER recompiles it and its howl
  announces the timer restarting. Killing it buys time, never peace.
- **The Moth** — sees light. Drawn to beams, flares, muzzle flash — the exact
  inverse of Scrubbers, so light discipline and darkness-safety start
  contradicting each other mid-fight. Fragile-ish but fast; shooting it means
  muzzle light, which excites it — kill it quickly or go dark and hide.
- **The Auditor** (deep layers) — methodical, not reactive. Walks the layer
  checking rooms in a fixed order, audible rooms away. Killable (tanky); a
  deleted Auditor ends audits for that layer — the most "earnable safety" of
  the three. Dread on a schedule.
- Escalation by depth: layers 1-5 none, then one hunter class at a time;
  past ~15 the Director may run two simultaneously (Hound+Moth plays nothing
  like Hound+Auditor).

### Mercy layer (the not-hardcore guarantees)
- Hunters haunt, they don't erase: getting caught costs integrity + Cycles,
  not the run. Builds are never lost (roguelite invariant).
- Backdoor rooms are absolutely sacred — no antivirus, ever. Horror needs a
  campfire.
- Injection depth IS the difficulty slider; no difficulty menu.
- "Dampened protocol" toggle: softens audio spikes + jumpscare sharpness
  without touching difficulty.

### Garnish
- Glitch HUD as proximity sense: corruption static intensifies near hunters —
  your screen breaking is the radar.
- MOTHER addresses players by callsign through glyph panels. Rarely. She has
  always known.
