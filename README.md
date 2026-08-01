# VOIDFALL

**1–4 player co-op descent into a dead alien megastructure adrift in deep space.**

Your crew shares one oxygen reserve. The deeper you dive, the richer the salvage —
and the darker it gets. Light is life. Greed kills. Extract or die.

First-person, full 3D. Built with **Godot 4.7** — host-authoritative multiplayer
over ENet: one player hosts, the crew joins by IP. Native builds for Linux and
Windows.

## Play

```bash
godot --path . 
```

Or open the project in the Godot 4.7 editor and hit F5. One player clicks
**Host**, everyone else **Join** with the host's IP. For testing solo, launch
two instances.

## Dedicated server

```bash
godot --headless --path . -- --server
```

See [DESIGN.md](DESIGN.md) for the full design document.
