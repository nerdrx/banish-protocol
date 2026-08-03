#!/usr/bin/env python3
"""crewsync — the FOUR-PEER multiplayer harness for BANISH PROTOCOL.

Every multiplayer test in this project's history was two instances: a host and
one client. A real playtest with four players reported crew who could see some
of their crewmates but not all, and creatures that behaved as though the three
clients were not in the building. Neither symptom is expressible in a two-peer
session -- with one client there is no "some of the others" to get wrong -- so
the verification standard itself was the root cause underneath both bugs.

This harness runs N real Godot processes (one listen host, N-1 clients) against
a real ENet socket, on a schedule you choose, and asserts on machine-readable
census files rather than on a screenshot. Nothing here eyeballs anything.

WHY IT NEEDS NO GAMESCOPE
    Every process runs `--headless`, so nothing renders and nothing touches the
    abstract X0 socket that CLAUDE.md serialises capture runs on. Four of these
    can run while another agent is mid-capture. The one thing that DOES render
    -- the money-shot capture of a creature hunting a client -- is a separate,
    single, wrapped run; this file never starts one.

WHY IT ISOLATES XDG_DATA_HOME
    `user://` is where the developer's real program file lives (archive, module
    tiers, achievements, codex). Four sessions writing it concurrently would
    both corrupt it and make the harness depend on whatever the developer last
    bought. Each peer gets its own XDG_DATA_HOME under the output directory, so
    every run starts from an identical blank program and the real save is never
    opened.

USAGE
    tools/crewsync/crewsync.py --scenario all --walk        # the full gate
    tools/crewsync/crewsync.py --scenario staggered --walk  # one join order
    tools/crewsync/crewsync.py --peers 2 --walk             # the old standard, as a control
    tools/crewsync/crewsync.py --lure client2 --walk        # park the pack on a client
    tools/crewsync/crewsync.py --keep --out DIR             # keep logs and censuses

    **Pass `--walk` for anything that asserts about motion.** Without it the crew
    stands still and the pose assertions are vacuous; with it every peer tours
    its layer for the whole run and never comes to rest. An earlier version used
    `--sprint`, which walks each avatar into a wall in about four seconds — after
    which every observer sees every crewmate frozen, in a beautifully consistent
    join-ordered pattern that is entirely an artefact of the driver. That cost
    half a day and nearly shipped a netcode "fix" for a bug that did not exist.
    CLAUDE.md's rule earned its place here: when a human report and a clean
    measurement disagree, first ask what the instrument is pointed at.

SCENARIOS
    together  burst  staggered  latecomer   join orderings
    hub                                     crew assembles in THE PARTITION
    inject                                  hub -> muster at the rig -> layer
    descend                                 the whole crew rides the shaft down
    all                                     every one of the above, in series

EXIT CODE
    0 = every assertion held. Non-zero = the count of failures, each printed as
    a line naming the peer and the missing entity.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GODOT = os.environ.get("GODOT", "godot")

# Peer colours are cosmetic, but distinct ones make a capture readable.
NAMES = ["HOST-A", "CREW-B", "CREW-C", "CREW-D", "CREW-E", "CREW-F"]


# --------------------------------------------------------------------- model --

@dataclass
class Peer:
    """One Godot process and everything we know about what it believed."""

    tag: str
    is_host: bool
    delay: float
    argv: list[str]
    census_path: Path
    log_path: Path
    proc: subprocess.Popen | None = None
    log_handle: object = None
    records: list[dict] = field(default_factory=list)

    # The census taken inside the window when every peer was still connected,
    # and the bounds of that window. Set by `align()`.
    settled: dict | None = None
    window: tuple[float, float] = (0.0, 0.0)

    @property
    def last(self) -> dict | None:
        return self.settled if self.settled is not None else (
            self.records[-1] if self.records else None)

    def load(self) -> None:
        self.records = []
        if not self.census_path.exists():
            return
        for line in self.census_path.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                self.records.append(json.loads(line))
            except json.JSONDecodeError:
                pass


@dataclass
class Scenario:
    """A join schedule. The whole point of the harness: asymmetric visibility is
    an ordering bug, so the ordering has to be a parameter and not an accident."""

    name: str
    # Seconds after the host starts that each client is launched.
    joins: list[float]
    duration: float = 26.0
    note: str = ""
    # Extra CLI args every peer in this scenario gets. This is how a scenario
    # exercises a CROSSING (a descent, an injection out of the hub) rather than
    # only a join: the crossing is the code path that rebuilds the world under a
    # live spawner, and it is the one no two-peer test ever stressed.
    extra: list[str] = field(default_factory=list)


def scenarios(peers: int, duration: float) -> dict[str, Scenario]:
    clients = peers - 1
    return {
        # Everybody piles in at once. This is what four friends clicking a Steam
        # invite at the same time actually looks like.
        "together": Scenario("together", [3.0] * clients, duration,
                             "all clients join in the same second"),
        # Comfortably separated: each join is fully settled before the next.
        "staggered": Scenario("staggered", [3.0 + 4.0 * i for i in range(clients)],
                              duration + 4.0 * clients,
                              "each join completes before the next begins"),
        # Everyone but one piles in at the start; the last arrives well after the
        # run is under way. The ordering that most resembles "my friend joined
        # late and nobody could see him".
        "latecomer": Scenario("latecomer",
                              ([3.0] * (clients - 1) + [18.0]) if clients >= 2
                              else [3.0] * clients,
                              duration + 16.0,
                              "the crew is mid-layer when the last one arrives"),
        # Tight: inside the same handful of frames, which is where a race lives.
        "burst": Scenario("burst", [4.0 + 0.15 * i for i in range(clients)], duration,
                          "joins land within a few frames of each other"),
        # The crew starts in THE PARTITION rather than dropping straight into a
        # layer, which is a different code path (Run.begin_hub) and a different
        # gate (`Run.in_hub` skips the injection check).
        "hub": Scenario("hub", [3.0 + 2.0 * i for i in range(clients)], duration,
                        "crew assembles in the hub"),
        # THE CROSSINGS. A human never starts in a layer -- `Debug.hub_start()`
        # sends every real player through THE PARTITION -- so the session the
        # playtest reported began in the hub, mustered at the rig and injected.
        # Neither crossing was in any automated multiplayer test before this one.
        "inject": Scenario("inject", [3.0 + 2.0 * i for i in range(clients)],
                           duration + 20.0,
                           "crew musters at the rig and injects out of the hub",
                           ["--goto", "shaft", "10", "--autodescend"]),
        # Ride the shaft down with the whole crew aboard, repeatedly. The layer is
        # regenerated under a spawner that is never freed; the avatars are meant to
        # survive it untouched.
        "descend": Scenario("descend", [3.0] * clients, duration + 24.0,
                            "the whole crew rides the shaft down",
                            ["--goto", "shaft", "8", "--autodescend"]),
    }


# ------------------------------------------------------------------- running --

def build_peer(index: int, out: Path, port: int, scenario: Scenario,
               args: argparse.Namespace) -> Peer:
    is_host = index == 0
    tag = "host" if is_host else "client%d" % index
    name = NAMES[index % len(NAMES)]
    census = out / ("census.%s.jsonl" % tag)
    log = out / ("log.%s.txt" % tag)
    delay = 0.0 if is_host else scenario.joins[index - 1]
    # Every peer stops at the same wall-clock moment, and the HOST stops last.
    # A client that outlives the host takes `server_disconnected` -> `leave()`,
    # which clears the roster and returns it to the menu -- so its final census
    # would report an empty crew and the harness would fail a healthy session.
    quit_in = (scenario.duration + 2.0) if is_host else max(scenario.duration - delay, 3.0)

    argv = [GODOT, "--headless", "--path", str(REPO), "--"]
    if is_host:
        argv += ["--autohost"]
    else:
        argv += ["--autojoin", "127.0.0.1"]
    argv += [
        "--port", str(port),
        "--name", name,
        "--seed", str(args.seed),
        "--layer", str(args.layer),
        # A blank program file has no backdoors, and joining a run in progress at
        # any depth is gated on one. Announce enough to be admitted so the harness
        # is testing crew sync and not the injection gate.
        "--backdoor", "40",
        "--archive", "5000",
        "--crewdump", str(census), str(args.interval),
        "--crewtag", tag,
        "--quit-in", "%.2f" % quit_in,
    ]
    if scenario.name in ("hub", "inject"):
        argv += ["--hub"]
    argv += scenario.extra
    if args.walk:
        # A driver that NEVER stops. Anything that can come to rest (sprinting
        # into a wall) turns the motion assertion into a test of the layout.
        argv += ["--roomtour", "%.2f" % args.walk_every]
    if args.no_antivirus:
        argv += ["--no-antivirus"]
    if args.haunt:
        argv += ["--haunt", args.haunt]
    if is_host and args.lure:
        argv += ["--lure", args.lure, "%.2f" % args.lure_delay]
    argv += args.extra

    return Peer(tag=tag, is_host=is_host, delay=delay, argv=argv,
                census_path=census, log_path=log)


def align(peers: list[Peer]) -> tuple[float, list[str]]:
    """Pick, for every peer, the census taken while the whole crew was still up.

    A peer that has already been told the host is gone reports an empty roster,
    truthfully -- so judging a session on its LAST census measures teardown, not
    crew sync. The all-connected window ends the moment the first process stops
    writing, which is the earliest last-record wall clock across the crew.
    """
    problems: list[str] = []
    lasts = [p.records[-1]["wall"] for p in peers if p.records]
    firsts = [p.records[0]["wall"] for p in peers if p.records]
    if len(lasts) != len(peers):
        return 0.0, problems
    window_end = min(lasts)
    window_start = max(firsts)
    if window_end - window_start < 3.0:
        problems.append("peers overlapped for only %.1fs -- too short to judge; "
                        "raise --duration" % (window_end - window_start))
    for peer in peers:
        inside = [r for r in peer.records if r["wall"] <= window_end]
        peer.window = (window_start, window_end)
        peer.settled = inside[-1] if inside else None
        if peer.settled is None:
            problems.append("%s wrote nothing inside the all-connected window"
                            % peer.tag)
    return window_end, problems


def run_scenario(scenario: Scenario, args: argparse.Namespace,
                 out_root: Path) -> tuple[list[Peer], list[str]]:
    out = out_root / scenario.name
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    port = args.port or random.randint(28100, 28900)
    peers = [build_peer(i, out, port, scenario, args) for i in range(args.peers)]

    print("\n=== scenario %-10s  %d peers  port %d  seed %d  layer %d" % (
        scenario.name, args.peers, port, args.seed, args.layer))
    if scenario.note:
        print("    %s" % scenario.note)
    print("    joins at t+%s, run for %.1fs" % (
        ", ".join("%.2f" % p.delay for p in peers[1:]) or "-", scenario.duration))

    started = time.monotonic()
    launched: list[Peer] = []
    try:
        for peer in peers:
            wait = peer.delay - (time.monotonic() - started)
            if wait > 0:
                time.sleep(wait)
            env = dict(os.environ)
            # See the module docstring: never the developer's real program file.
            home = out / ("userdata.%s" % peer.tag)
            home.mkdir(parents=True, exist_ok=True)
            env["XDG_DATA_HOME"] = str(home)
            env["XDG_CONFIG_HOME"] = str(home)
            # Belt and braces against a stray renderer: nothing here may open a
            # display, and a hard-failed display is louder than a silent one.
            env.pop("DISPLAY", None)
            env.pop("WAYLAND_DISPLAY", None)
            peer.log_handle = open(peer.log_path, "wb")
            peer.proc = subprocess.Popen(peer.argv, cwd=str(REPO), env=env,
                                         stdout=peer.log_handle,
                                         stderr=subprocess.STDOUT)
            launched.append(peer)
            print("    [t+%5.2f] %-8s pid %d" % (
                time.monotonic() - started, peer.tag, peer.proc.pid))

        deadline = started + scenario.duration + args.grace
        while time.monotonic() < deadline:
            if all(p.proc is not None and p.proc.poll() is not None for p in launched):
                break
            time.sleep(0.25)
    finally:
        for peer in launched:
            if peer.proc is not None and peer.proc.poll() is None:
                peer.proc.send_signal(signal.SIGTERM)
        time.sleep(1.0)
        for peer in launched:
            if peer.proc is not None and peer.proc.poll() is None:
                peer.proc.kill()
            if peer.log_handle is not None:
                peer.log_handle.close()

    for peer in peers:
        peer.load()
    red = red_tree(peers, scenario)
    if red:
        return peers, red
    _, problems = align(peers)
    return peers, ["[%s] %s" % (scenario.name, p) for p in problems] \
        + assert_crew(peers, scenario, args)


# ---------------------------------------------------------------- assertions --

def red_tree(peers: list[Peer], scenario: Scenario) -> list[str]:
    """Refuse to draw conclusions from a session whose scripts did not compile.

    Several agents share this working copy, and a neighbour's half-written file
    takes down an autoload for every process in the tree. When that happens the
    avatars stop moving -- which looks EXACTLY like the replication bug this
    harness hunts. A red tree is therefore reported as a red tree and nothing
    else is believed: a false root cause costs more than a re-run.
    """
    bad: list[str] = []
    for peer in peers:
        if not peer.log_path.exists():
            continue
        text = peer.log_path.read_text(errors="replace")
        hits = [line for line in text.splitlines()
                if "SCRIPT ERROR" in line or "Failed to instantiate an autoload" in line
                or "Failed to load script" in line]
        if hits:
            bad.append("[%s] %s: the tree was RED (%d script errors, first: %s) "
                       "-- fix the tree and re-run; nothing below is evidence" % (
                           scenario.name, peer.tag, len(hits), hits[0][:110]))
    return bad


def assert_crew(peers: list[Peer], scenario: Scenario,
                args: argparse.Namespace) -> list[str]:
    """Every failure names the peer and the missing entity. No verdict is a
    judgement call; every one of them is a set difference."""
    fails: list[str] = []
    prefix = "[%s]" % scenario.name

    host = peers[0]
    if host.last is None:
        return ["%s host wrote no census at all -- it never reached the layer" % prefix]

    # Ground truth for who SHOULD be here: ENet peer ids are random, so the
    # expected id set can only come from the host's own roster, and the host's
    # roster is separately checked for size.
    truth = sorted(host.last.get("roster", []))
    names = host.last.get("names", {})

    def who(pid: int) -> str:
        return "%s(%d)" % (names.get(str(pid), "?"), pid)

    # Did each peer's OWN avatar move, as measured by the peer that owns it? A
    # crewmate who stood still all run proves nothing about anybody's pose
    # stream, so the motion check below only indicts a frozen avatar whose owner
    # was demonstrably walking.
    movers: dict[int, bool] = {}
    for other in peers:
        if other.last is None:
            continue
        mine = other.last.get("self")
        movers[mine] = motion(other).get(mine, False)

    if len(truth) != args.peers:
        fails.append("%s host roster has %d of %d crew: %s" % (
            prefix, len(truth), args.peers, [who(p) for p in truth]))

    for peer in peers:
        last = peer.last
        if last is None:
            fails.append("%s %s wrote no census -- process never got a world up" % (
                prefix, peer.tag))
            continue

        # (A) VISIBILITY. What this peer was told the crew is, vs what its own
        # scene tree actually contains.
        roster = sorted(last.get("roster", []))
        spawned = sorted(last.get("spawned", []))
        for pid in truth:
            if pid not in roster:
                fails.append("%s %s roster is missing %s" % (prefix, peer.tag, who(pid)))
            if pid not in spawned:
                fails.append("%s %s CANNOT SEE %s -- rostered=%s, no avatar in tree" % (
                    prefix, peer.tag, who(pid), pid in roster))
        for pid in spawned:
            if pid not in truth:
                fails.append("%s %s has a ghost avatar %d nobody rosters" % (
                    prefix, peer.tag, pid))

        # Determinism: one world, one seed. A peer on a different seed built a
        # different building and every position in this census is meaningless.
        if last.get("seed") != host.last.get("seed"):
            fails.append("%s %s built seed %s, host built %s" % (
                prefix, peer.tag, last.get("seed"), host.last.get("seed")))
        # A crossing is sequenced independently on every peer off one number, so
        # mid-descent the layer numbers legitimately differ for a fraction of a
        # second. Only a settled disagreement is a bug.
        if last.get("layer") != host.last.get("layer") \
                and not last.get("descending") and not host.last.get("descending"):
            fails.append("%s %s is on layer %s, host is on %s" % (
                prefix, peer.tag, last.get("layer"), host.last.get("layer")))

        # THE MOTION CHECK. A node in the tree is not a crewmate you can see.
        # Every peer other than the avatar's owner must be receiving a pose
        # stream for it; an avatar that never moves while its owner is walking is
        # a replication failure, and to the player it is indistinguishable from
        # an absent crewmate. This is the check that "can you see your crewmates"
        # actually means, and no two-peer test can fail it in an interesting way.
        for pid, moved in motion(peer).items():
            if pid == last.get("self"):
                continue  # our own avatar; we are the authority for it.
            if not movers.get(pid, False):
                continue  # its owner never moved either -- nothing to replicate.
            if not moved:
                fails.append(
                    "%s %s sees %s FROZEN -- avatar present, pose stream never "
                    "arrived (this is what 'desync' looks like)" % (
                        prefix, peer.tag, who(pid)))

    # (B1) CAN EVERY PEER SEE THE MONSTERS MOVE? Judged against the host, which
    # is the authority for creature motion: any creature the host saw move must
    # have moved on every other peer too. A creature that is alive and hunting on
    # the host and frozen on one client is that client's game being broken in a
    # way nobody in the session can see.
    host_creatures = creature_motion(host)
    live = {name for name, did in host_creatures.items() if did}
    for peer in peers[1:]:
        if peer.last is None:
            continue
        seen = creature_motion(peer)
        for name in sorted(live):
            if name not in seen:
                fails.append("%s %s has NO creature %s at all" % (prefix, peer.tag, name))
            elif not seen[name]:
                fails.append(
                    "%s %s sees creature %s FROZEN while the host has it moving "
                    "-- OPEN P0: creature pose does not reach clients at all "
                    "(reproduces at 2 peers too; see the note in "
                    "src/creatures/antivirus.gd:_build_sync)" % (
                        prefix, peer.tag, name))

    # (B2) TARGETING. `_running_players()` is not a distance query -- it returns
    # every living, non-sanctuary crewmate anywhere in the layer -- so the
    # candidate set is exactly comparable to the running roster, and any peer
    # missing from it is invisible to that creature's senses by construction.
    running = {int(k) for k, v in host.last.get("running", {}).items() if v}
    creatures = host.last.get("creatures", [])
    if not creatures and not args.no_antivirus and not host.last.get("in_hub"):
        fails.append("%s host had no creatures to measure -- rerun without --no-antivirus"
                     % prefix)
    for row in creatures:
        seen = {int(c) for c in row.get("candidates", []) if str(c).lstrip("-").isdigit()}
        for pid in sorted(running):
            if pid not in seen:
                fails.append(
                    "%s creature %s (%s) DOES NOT PERCEIVE %s -- candidates=%s" % (
                        prefix, row.get("name"), row.get("kind"), who(pid),
                        sorted(seen)))

    # The hunt itself, when the run asked for one. Structural perception is
    # necessary but not sufficient: this is the assertion that a client can
    # actually be hunted, which is the symptom the player reported.
    if args.lure:
        want = lure_id(host, args.lure)
        hunted = set()
        for record in host.records:
            for row in record.get("creatures", []):
                target = row.get("target", "")
                if str(target).lstrip("-").isdigit():
                    hunted.add(int(target))
        if want and want not in hunted:
            fails.append("%s no creature ever hunted the lured peer %s -- hunted %s" % (
                prefix, who(want), sorted(hunted) or "nobody"))
        elif want:
            print("    hunt: a creature acquired %s" % who(want))

    return fails


def creature_motion(peer: Peer) -> dict[str, bool]:
    """Which creatures this peer saw MOVE, inside the all-connected window.

    Creature pose is a per-peer synchronizer stream gated by
    `Net.peer_has_world`. A peer on the wrong side of that gate is streamed no
    creature state at all and sees a building full of statues, while the host
    and the rest of the crew see a normal hunt. From that seat the game reads as
    "the enemies only respond to the host" -- and nothing is logged anywhere.
    """
    start, end = peer.window
    first: dict[str, str] = {}
    moved: dict[str, bool] = {}
    for record in peer.records:
        if end > 0.0 and not (start <= record["wall"] <= end):
            continue
        for name, pos in record.get("creature_pose", {}).items():
            if name not in first:
                first[name] = pos
                moved[name] = False
            elif pos != first[name]:
                moved[name] = True
    return moved


def motion(peer: Peer) -> dict[int, bool]:
    """Which avatars this peer saw MOVE, INSIDE the all-connected window.

    The window matters more than it looks. Peers join at different times, so a
    census taken over each peer's whole life compares different stretches of the
    run for different observers -- and any motion driver that can ever stop (a
    sprint into a wall, say) then produces a beautifully consistent triangular
    "bug" that is nothing but the last joiner watching everybody else stand
    still. That artefact cost half a day. Every observer is now judged over the
    same wall-clock interval, and the driver (`--walk`) never stops moving.

    Positions are compared as strings at centimetre precision, so a stationary
    avatar and a smoothly-interpolated one are trivially distinguishable and no
    threshold has to be argued about.
    """
    start, end = peer.window
    first: dict[int, str] = {}
    moved: dict[int, bool] = {}
    for record in peer.records:
        if end > 0.0 and not (start <= record["wall"] <= end):
            continue
        for key, pos in record.get("positions", {}).items():
            pid = int(key)
            if pid not in first:
                first[pid] = pos
                moved[pid] = False
            elif pos != first[pid]:
                moved[pid] = True
    return moved


def lure_id(host: Peer, spec: str) -> int:
    if host.last is None:
        return 0
    ids = sorted(host.last.get("roster", []))
    if not ids:
        return 0
    spec = spec.lower()
    if spec in ("host", "local"):
        return 1
    if spec.startswith("client"):
        index = int(spec[6:] or 0)
        return ids[index] if 1 <= index < len(ids) else 0
    for pid in ids:
        if host.last.get("names", {}).get(str(pid), "").lower() == spec:
            return pid
    return 0


# ---------------------------------------------------------------------- main --

def summarise(peers: list[Peer]) -> None:
    for peer in peers:
        last = peer.last
        if last is None:
            print("    %-8s  NO CENSUS" % peer.tag)
            continue
        print("    %-8s self=%-11d roster=%-2d spawned=%-2d missing=%s" % (
            peer.tag, last.get("self", 0), len(last.get("roster", [])),
            len(last.get("spawned", [])), last.get("missing") or "-"))
    host = peers[0]
    if host.last and host.last.get("creatures"):
        for row in host.last["creatures"][:6]:
            print("    creature %-6s %-9s %-8s candidates=%s target=%s" % (
                row.get("name"), row.get("kind"), row.get("state"),
                row.get("candidates"), row.get("target") or "-"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--peers", type=int, default=4,
                    help="total crew including the listen host (default 4)")
    ap.add_argument("--scenario", default="together",
                    help="together|staggered|latecomer|burst|hub|all")
    ap.add_argument("--seed", type=int, default=20260803)
    ap.add_argument("--layer", type=int, default=3)
    ap.add_argument("--duration", type=float, default=26.0)
    ap.add_argument("--interval", type=float, default=1.0,
                    help="seconds between census records")
    ap.add_argument("--grace", type=float, default=25.0,
                    help="seconds to wait past the run for processes to exit")
    ap.add_argument("--port", type=int, default=0, help="0 picks a free-ish high port")
    ap.add_argument("--lure", default="", help="host|clientN|NAME -- park the pack on them")
    ap.add_argument("--lure-delay", type=float, default=14.0)
    ap.add_argument("--haunt", default="", help="force a hunter kind (see --haunt)")
    ap.add_argument("--walk", action="store_true",
                    help="drive every peer around its layer for the whole run "
                         "(room tour). Required for the motion assertions to "
                         "mean anything -- a stationary crew proves nothing.")
    ap.add_argument("--walk-every", type=float, default=1.5)
    ap.add_argument("--no-antivirus", action="store_true")
    ap.add_argument("--out", default="", help="output directory (default: a temp dir)")
    ap.add_argument("--keep", action="store_true", help="do not delete the output dir")
    ap.add_argument("extra", nargs="*", default=[],
                    help="extra args passed to every peer")
    args = ap.parse_args()

    out_root = Path(args.out) if args.out else Path("/tmp/crewsync-%d" % os.getpid())
    out_root.mkdir(parents=True, exist_ok=True)
    print("crewsync: output -> %s" % out_root)

    catalogue = scenarios(args.peers, args.duration)
    if args.scenario == "all":
        wanted = ["together", "burst", "staggered", "latecomer", "hub",
                  "inject", "descend"]
    else:
        wanted = [s.strip() for s in args.scenario.split(",") if s.strip()]

    total: list[str] = []
    for name in wanted:
        if name not in catalogue:
            print("unknown scenario %r; have %s" % (name, ", ".join(catalogue)))
            return 2
        peers, fails = run_scenario(catalogue[name], args, out_root)
        summarise(peers)
        if fails:
            print("    --- %d FAILURE(S)" % len(fails))
            for line in fails:
                print("    " + line)
        else:
            print("    --- green")
        total += fails

    print("\n============================================================")
    if total:
        print("CREWSYNC: %d failure(s) across %d scenario(s)" % (len(total), len(wanted)))
        for line in total:
            print("  " + line)
    else:
        print("CREWSYNC: green across %d scenario(s) with %d peers" % (
            len(wanted), args.peers))
    print("logs and censuses: %s" % out_root)

    if not args.keep and not args.out and not total:
        shutil.rmtree(out_root, ignore_errors=True)
    return min(len(total), 120)


if __name__ == "__main__":
    sys.exit(main())
