# BANISH PROTOCOL — Playtest Guide

Thanks for testing. This is a **pre-alpha** — the game is content-complete
(full descent loop, permanent progression, the antivirus, sound, and the
Haunting) but unbalanced-by-real-humans and rough in places. Your job is to
break it and tell us how it felt.

## What it is

1–4 player co-op first-person horror roguelite. You're an intrusion program
looting a rogue AI ("MOTHER") from the inside while her antivirus hunts you
through the dark. Your beam is the only light; your crew shares one draining
pool of compute; nothing you steal counts until you exfiltrate. **Solo is
fully supported — and the scariest way to play.**

## Install

1. Download the build for your OS from the release page and unzip it anywhere.
2. **Linux:** run `banish-protocol.x86_64` (mark executable if needed:
   `chmod +x banish-protocol.x86_64`). **Windows:** run `banish-protocol.exe`
   (SmartScreen may warn — it's an unsigned pre-alpha; "More info → Run anyway").
3. Keep the whole folder together — the `.pck` and the Steam libraries next to
   the binary are required.

## Play together

At the menu, pick **STEAM** (if you launched via Steam) or **DIRECT**:
- **DIRECT (most reliable right now):** one person clicks **HOST** (default
  port), everyone else types the host's IP and clicks **JOIN**. Same LAN works
  out of the box; over the internet use [Tailscale](https://tailscale.com) or a
  port-forward.
- **STEAM:** host a friends-only lobby, others join from the friends list /
  overlay invite. *Note: the Steam join path is wired but has only been tested
  host-side — you're the first real two-account test. If it misbehaves, fall
  back to DIRECT.*

**Solo:** just click HOST and dive alone.

## Controls

| | | | |
|---|---|---|---|
| Move | `W A S D` | Beam on/off | `F` |
| Sprint (burns Cycles) | `Shift` | Interact / root / restore | `E` |
| Look / aim | Mouse | Fire breaker | `LMB` |
| Flare | `G` / `RMB` | Pause / settings | `Esc` |

At a **terminal**, walk up, hold `E`, and *type* commands: `LIST DATA`,
`LOCATE SHAFT`, `LOCATE COMPILER`, `QUERY <ROOM>`, `HELP`. (Every query is loud.)

## The loop (≈15–30 min a run)

Descend layer by layer to each **drop shaft**. Grab data, tap siphons to refill
Cycles (loud — it draws the antivirus), fight or avoid the **Scrubbers** and the
armored **Sentinel**. Every 5th layer is a **backdoor sanctuary**: root it (safe
room, Compiler, exfil uplink), then decide — **exfiltrate** (bank everything) or
**push one more ring** for a richer haul. Data only counts if you make it out.
Wipe loses the data in your pockets — never your **permanent module upgrades**
(bought at Compilers, they survive death forever) or your **rooted backdoors**
(next run, inject straight to them).

## The Haunting (deeper in)

Past layer 6, MOTHER starts hunting. The **Hound** hears you (stay quiet), the
**Moth** is drawn to your light (go dark), the **Auditor** sweeps rooms on a
schedule (deep layers). They're all killable — but killing a process only buys
time; she recompiles it. She'll also start speaking to you.

## Accessibility

First launch offers **Reduced Flashing** (the game is seizure-safe by default,
but this softens further). In **Settings** (menu or pause): audio-comfort
sliders, **Sound Captions** (directional threat text for deaf/HoH players), a
**CRT-whine kill** toggle (the interface hum is a real high-frequency tone), and
**Dampened Protocol** (softens jumpscares/spikes without changing difficulty).

## Known pre-alpha rough edges

- **Steam join** needs a real second-account test (see above; DIRECT is solid).
- Balance is math-tuned, not human-tuned — tell us where it felt unfair or trivial.
- No packaged tutorial yet; this guide is it.
- Creature packs can bunch in doorways occasionally.
- It's *dark on purpose* — turn the lights off, use headphones, trust the beam.

## Tell us

What scared you, what confused you, where it dragged, what broke, and — most
useful — **the moment you said "one more ring?" and regretted it.**

`MOTHER is listening.`
