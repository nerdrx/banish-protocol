# LIMBO PROTOCOL — Design Document

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
5. **The intricacy law.** Everything reads as intricately worked-on, even when
   procedural. Procgen assembles an authored vocabulary — it never excuses
   sparseness. Big volumes need midground (islands, catwalks, overhead runs);
   empty floor plazas are a failure mode; surfaces hold up at 30cm; the only
   permitted emptiness is deliberate dread. If a space looks generated, the
   generator has failed.
6. **The motivation law (companion to intricacy).** Detail must be *justified*,
   not scattered — the generator asks "does this make sense here?" per element.
   Cables run FROM a source TO a load (tap→machine, junction→fixture) as routed
   connections, never sprinkled; props exist because something placed them;
   clutter accretes where work happens. Dynamic motion needs a diegetic cause:
   a sealed machine-space has no wind, so nothing sways for free. Motion follows
   cause — cables bolted to running machinery get a fine high-frequency
   vibration; cables near a *powered* vent-fan (the rewire junction's own fan
   load) or a god-ray draft get true low-frequency sway; dead runs hang dead
   still. If you cannot name the cause, cut the effect. Placement is a graph
   (route, connect, motivate), not a scatter.

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
- **The Slime slot (avatar + Sentinel)**: the rig's organic sections render as
  translucent gel — glassy transmission, wet specular, an internal emissive
  glow bleeding through (crew: the player's phosphor color inside their shell;
  Sentinel: deep red). Dark-first: glossy-wet darkness with light circulating
  under glass, never bright jelly. Adds literal depth to both factions.
- **Rendering**: Forward+. Near-black ambient, volumetric haze (beams read as
  shafts), per-player SpotLight beams with shadows, flares as flickering
  OmniLights, emissive circuit traces on architecture (dim, pulsing — data
  flowing through conduits).
- **God rays are a signature motif**: volumetric light shafts as compositional
  anchors, not accidents — ceiling apertures dropping hero shafts into key
  rooms (vault, drop shaft, arrival), grates striping corridors, dust motes
  riding the beams. Every important room earns one readable light event; the
  player's path should cross through light shafts, silhouetting crew and
  creatures against them (the user's own key art is the reference).
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
- **HUD — cassette futurism (Alien: Isolation)**: the player is a human-built
  program, so their interface is old HUMAN tech — a phosphor CRT instrument
  (scanlines, slight curvature, phosphor ghost-persistence, amber-dominant)
  deliberately contrasting MOTHER's sleek neon architecture and rhyming with
  the Northcairn legacy remnants in deep layers. Analog glitch language: VHS
  tracking tears and sync loss for damage/low-Cycles; pristine digital glitch
  reserved for MOTHER's own acts (decompile). Restrained, instrument-like:
  shared Cycles ring as analog gauge, dot-matrix readouts, quiet by default.
- **The quiet-instrument rule (M4.9)**: sleek = adaptive silence. The HUD's
  resting state is nearly empty — one compact cluster (Cycles gauge anchoring
  a thin integrity arc + small data numeral), no persistent text labels, no
  redundant status lines. Elements SURFACE on relevance (value changing,
  danger threshold, aim/interact context) and fade when stable: integrity
  hidden at full, breaker heat only when hot, layer title only on descent,
  roster only on change. Labels appear briefly on change, then yield to
  shape/position language. Every element must justify every frame it is
  visible. Show less, mean more.

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

### Achievement list (v1 — wired)

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

### Achievement catalog v2 (target ~40 — implement in M4.9)

Progression:
| `FIRST_STEPS` | Hello World | Complete your first descent to layer 2 |
| `ROOTED_DEEP` | Persistent Threat | Root the layer-10 backdoor |
| `DEEP_STATE_2` | Deeper State | Root the layer-20 backdoor |
| `RING_RUNNER` | Ring Runner | Reach layer 30 |
| `FULLY_COMPILED` | Fully Compiled | Max one module track |
| `OVERENGINEERED` | Overengineered | Max every module track |
| `MILLIONAIRE` | Data Baron | Bank 10,000 lifetime data |

Combat & survival:
| `PEST_CONTROL` | Pest Control | Delete 100 Scrubbers lifetime |
| `EXTERMINATOR` | Exterminator | Delete 500 processes lifetime |
| `CORE_BREACH` | Core Breach | Kill a Sentinel with core hits only |
| `DAVID` | David | Kill a Sentinel with tier-0 Breaker |
| `UNTOUCHED` | Checksum Intact | Exfiltrate a 5+ layer run at 100% integrity |
| `PHOTOPHOBIA` | Photophobia | Rout 10 Scrubbers with one flare |
| `CLUTCH_RESTORE` | Garbage Collected | Restore a crewmate with <5s left on their decay timer |
| `NO_BREATH` | Held Process | Exfiltrate with the pool under 5 Cycles |

The world fights back (M4.8 props):
| `WELDER` | Certified Welder | Weld 25 vents lifetime |
| `LOCKSMITH` | Quiet Entry | Open 10 cabinets via rewire without ever cutting one |
| `SLAMMED` | Access Denied | Seal a bulkhead within 2s of a Scrubber entering its corridor |
| `KICKED_IT` | Who Did That | Attract 3+ processes with one kicked debris |
| `POWER_USER` | Load Balancer | Use all three junction loads in one layer |
| `TYPIST` | Terminal Velocity | Run 50 terminal queries lifetime |
| `WARDRIVER` | Indexed | LIST DATA on every layer of a 10+ layer run |

Greed & style:
| `LOOT_GOBLIN` | Defragmented | Collect every chip on a layer, 3 layers in a row |
| `SPEEDRUN` | Hot Path | Arrival to drop shaft in under 90 seconds |
| `PACIFIST_DEEP` | Ghost Process | Reach layer 10 with zero deletions in the run |
| `HIGH_ROLLER` | Leverage | Spend 2,000+ data at a single Compiler visit |
| `WINDOW_SHOPPER` | Just Browsing | Open and close a Compiler 5 times in one run buying nothing |
| `PHOTOSENSITIVE` | Moth Math | Exfiltrate without ever toggling your beam off (post-M6 riff) |

Hidden / lore (unlock text stays cryptic):
| `NAMED_HER` | She Answers | Type MOTHER at a terminal |
| `WRONG_DOOR` | Think Carefully | Answer the door question (egg.open) |
| `ARCHAEOLOGIST` | Shift Log | Read 10 Northcairn fragments lifetime |
| `THE_COAT` | Unclaimed Item | Find all three coat fragments |
| `UPWARD` | Let Nothing Pass | Stand at a layer-13+ doctrine plate for 30s |
| `RELIEVED` | Relief Shift | (M7+: reach the Kernel — reserved) |

Co-op (all solo-achievable variants exist per the solo invariant, except the explicitly-social):
| `FULL_STACK` | Full Stack | Exfiltrate with a full 4-crew, everyone alive |
| `SHARED_BURDEN` | Load Bearing | Carry 60%+ of the crew's banked data in one exfil |
| `MEDIC_MAIN` | Restore Point | 25 lifetime restores |
| `LIGHTHOUSE` | Lighthouse | Rout a Scrubber off a crewmate with YOUR beam 10 times |

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
- **M4.8 — Functional clutter**: the world gets dense and interactive.
  Static clutter (cables, debris, dead maintenance drones, pipe runs) plus
  props that DO things: rewire junctions (Alien: Isolation style — reroute
  power between room lighting / door locks / vent fans), weldable vent covers
  (Scrubber ingress points sealable with the breaker), lootable cabinets
  (breaker-cut the lock, data inside), physics debris that makes noise when
  kicked (antivirus hears it), sealable bulkhead doors (temporary barricade,
  MOTHER re-opens them eventually). All deterministic placement.
  **GTFO-inspired: in-world command terminals** — CRT consoles (player-tech
  aesthetic) where you TYPE actual commands to query MOTHER's own systems:
  `LIST DATA`, `LOCATE COMPILER`, `PING SHAFT`, `QUERY <room>` — powerful
  intel, but queries are loud (antivirus ping radius), and deeper layers
  return partially corrupted output. The crew's navigator ritual: one player
  heads-down typing while the others hold the dark. (Our muster-to-descend
  is already a GTFO bioscan cousin; alarm-scan events join in M6.)

**The solo invariant (design law)**: everything above — and everything ever —
must be fully doable solo. Co-op multiplies tension and comfort, never gates
content: no mechanic may require a second pair of hands (terminals are usable
solo, just tenser; scans scale to crew size; no two-person doors, ever).
Solo NULLVOID is the scariest way to play, not a degraded mode.
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

## Future backlog (user ideas, post-M6)

- **The Partition (hub area)**: a sector of MOTHER the crew has permanently
  carved out — the place you exist between intrusions. Starts as a bare
  compromised maintenance bay; grows with the crew. **The hub IS the menu**
  (interactive/diegetic): walk to the injection rig to pick a backdoor and
  launch, the Compiler terminal to spend, the Assembler to craft, a roster
  panel to invite friends — crewmates physically stand in the room with you
  while you ready up. Traditional menus reduce to a thin fallback.
- **Decoration**: place salvaged objects from the deep — trophies (a dead
  Scrubber shell), legacy human artifacts, light fixtures, banners of
  captured propaganda. Per-crew persistence.
- **Crafting bench ("the Assembler")**: the Compiler's big sibling in the hub.
  Crafts cosmetics, tools, maybe flare variants from found resources.
- **Resources beyond data**: rare material drops found in-world (clean RAM,
  legacy components, intact glyph panels) that fuel the Assembler — a second,
  optional collection layer that rewards exploration over speed.

### Below the Kernel (endgame / NG+ arc)

Real silicon has privilege rings below Ring 0 (hypervisor, SMM, management
engines). Canon: when the crew finally roots the Kernel, they learn MOTHER is
not the bottom. **Negative rings exist — and something lives down there that
she went rogue to contain.** The paranoid police state, the propaganda,
"QUARANTINE IS MERCY" — she was never the villain; she was the warden. NG+:
descend below zero, into architecture that was never hers.

### M7+ candidates (canonized ideas)

- **Proximity voice**: in-fiction radio; creatures HEAR you talking. Whisper
  or die. The single biggest co-op horror multiplier available.
- **Purge storms**: mid-run structural events — MOTHER kills a layer's
  lighting for 90s, or slowly walls off sectors with quarantine barriers.
- **Loadout archetypes** (starting-module presets, not rigid classes):
  Breacher (cutter), Cartographer (pings, wayfinding at range), Restorer
  (revives, integrity share), Mule (double buffer, slower).
- **New tools**: decoy process (fakes your noise signature), tripflares,
  wall-revealing scanner pulse that pings the antivirus. Everything costs.
- **Daily intrusion**: one shared seed worldwide, one attempt, leaderboard by
  banked data — determinism makes this nearly free.
- **Contracts**: rival employers with reputations buying the data;
  conflicting job modifiers ("bank 40, root nothing — leave no trace").
- **Biome bands by depth**: coolant flats (liquid reflective floors), memory
  gardens (data growing organically, wrong), dead sectors (no light, no
  traces, decaying geometry).
- **Companion drone**: a repurposed Scrubber that follows, carries a lamp,
  magnets chips from corners. Emotional damage when the Hound takes it.
- **Photo mode**.
- **Corrupted minigame**: while downed, a tiny terminal puzzle slows your
  decay timer.
- Plus, from M6 notes: **the Still** (moves only unobserved — beam = statue)
  and **honeypot vaults** (too-rich vaults that are traps; MOTHER read the
  same security textbooks as her creators).
