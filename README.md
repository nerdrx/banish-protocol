# VOIDFALL

**1–4 player co-op roguelite: invade a rogue AI, descend its security layers,
steal its data — while its antivirus hunts you in the dark.**

Your crew of intrusion programs shares one pool of stolen compute Cycles. The
deeper the ring, the richer the data — and the older and angrier the antivirus.
Light is decryption. Greed kills. Exfiltrate or be deleted.

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
