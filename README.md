# VOIDFALL

**1–4 player co-op descent into a dead alien megastructure adrift in deep space.**

Your crew shares one oxygen reserve. The deeper you dive, the richer the salvage —
and the darker it gets. Light is life. Greed kills. Extract or die.

Built with TypeScript, Three.js, and an authoritative Node.js WebSocket server
(30Hz tick, client prediction + snapshot interpolation).

## Quick start

```bash
npm install
npm run dev        # starts server (:8080) + client (:5173)
```

Open http://localhost:5173 in two browser windows to test multiplayer locally.

## Structure

| Package | What |
|---|---|
| `packages/shared` | Protocol, sim constants, shared movement + procgen |
| `packages/server` | Authoritative simulation, rooms, creature AI |
| `packages/client` | Three.js rendering, prediction, VFX, audio, UI |

See [DESIGN.md](DESIGN.md) for the full design document.
