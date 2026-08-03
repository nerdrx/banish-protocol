extends Node
## Debug — permanent developer entry points driven by command-line user args.
##
## Everything after a bare `--` reaches us via OS.get_cmdline_user_args():
##
##   godot --headless --path . -- --server [--port 27015]
##       Dedicated host: no local player, no window.
##   godot --path . -- --autohost [--port N] [--name X]
##       Host and drop straight into the layer.
##   godot --path . -- --autojoin 127.0.0.1 [--port N] [--name X]
##       Join and drop straight into the layer.
##   ... -- --screenshot /tmp/shot.png 120
##       Wait 120 rendered frames after the local player spawns, save the
##       viewport to a PNG, then quit. Combines with the flags above. Framerate
##       is pinned to 60 while armed, so 120 frames is reliably 2 seconds.
##   ... -- --quit-in 12
##       Live for 12 seconds regardless. When paired with --screenshot it takes
##       over the process lifetime, which is how one instance stays up long
##       enough for a second instance to photograph it.
##   ... -- --window-size 3440x1440
##       Resize the OS window to exactly WxH before capturing, borderless and
##       at the screen origin so the compositor cannot shave decoration height
##       off the request.
##
##       PT2 EXISTS BECAUSE THIS DID NOT. Every ultrawide claim made before this
##       flag was unverifiable: `--screenshot` photographs the root viewport,
##       which under `canvas_items` stretch is exactly the WINDOW's pixel size —
##       so a capture taken from the default 1280x720 window comes back 1280x720
##       no matter what resolution the *desktop* is, and no matter what the game
##       looks like when a human runs it fullscreen on a 32:9 panel. The engine's
##       own `--resolution` gets closer but is clamped by window decorations
##       (a 3440x1440 request landed a 3440x1412 window here), which silently
##       changes the aspect ratio — the one number an aspect bug is measured in.
##       `_capture` now prints the window size, the viewport size and the saved
##       image size on every shot and shouts when they disagree, so a capture can
##       no longer quietly lie about which aspect it is evidence for.
##
## M2 world selection (host-side; the host replicates the choice to clients):
##   --seed N        force the run seed instead of rolling one
##   --layer N       start the intrusion on layer N rather than 1
##   --testlayer     play M1's hand-authored greybox instead of procgen
##   --cycles N      start the shared pool at N instead of full (test siphons
##                   filling it, or set it near zero to test degradation)
##   --log-cycles    print the pool once a second, to measure drain rates
##
## M2 headless determinism check (no window, no networking):
##   godot --headless --path . -- --dumplayer SEED LAYER
##       Print the generated room graph as diffable text and exit.
##
## M2 automation. Real systems are exercised end to end — these drive the same
## input paths a player would, they do not shortcut the host validation:
##   --goto TARGET [delay]         teleport the local avatar there after `delay`
##                                 seconds, and again on every new layer.
##                                 TARGET: shaft | siphon | vault | nest | node |
##                                 uplink | corridor (looking down the longest
##                                 one — the shot that judges the architecture) |
##                                 decal (stand 3 m off a wall sign and read it) |
##                                 wallhug (nose against that wall instead — the
##                                 shot that proves the breaker does not clip
##                                 through it) |
##                                 crew (the nearest corrupted crewmate)
##   --pitch RADIANS               override the lens pitch every `--goto` sets.
##                                 Negative looks down; -1.2 is "at your own
##                                 boots", which is the shot that proves the
##                                 first-person body is really there.
##   --hold-interact [delay]       hold E from `delay` seconds onward
##   --sprint                      hold forward + sprint (Cycles drain test)
##   --autodescend                 goto shaft + hold E on every layer, forever:
##                                 the soak that rides 1 -> 2 -> 3 -> 4
##   --decompile-at N              take lethal damage at N seconds. M3 routes
##                                 this through the real damage path, so it
##                                 corrupts in a crew and deletes solo.
##
## M3 flags:
##   --fire [delay]      hold the breaker's trigger from `delay` seconds onward
##   --flare [delay]     throw one flare at `delay` seconds
##   --aim               the local avatar tracks the nearest process with its
##                       lens. There is no mouse in an automated run, and a
##                       Scrubber circling you at knee height cannot be hit
##                       without one — this is how a capture frames a kill.
##   --grab [count]      hop the local avatar onto data shards until `count` are
##                       in its buffer. The pickup itself is the real one: the
##                       host still decides that a shard was absorbed
##   --exfil [delay]     the whole endgame, driven through the real channels:
##                       walk to the node, root it, walk to the uplink, call
##                       exfiltration, then stand on the pad until it fires
##   --no-antivirus      generate the layer but buy nothing hostile
##   --log-ai            per-second census of every process and its state, plus
##                       a line on every state transition and every tap ping
##
## M3.7 flags:
##   --log-fps [window]  per-`window`-second frame-rate census: average, 1% low
##                       and the worst frame in the window, plus draw calls and
##                       primitives. The look-dev merge quadrupled the fixture
##                       count per layer, so "does a two-client layer with
##                       creatures in it still hold 60" is now a number this
##                       build has to be able to print about itself. Uncaps the
##                       frame rate for the duration: under a compositor the
##                       renderer vsyncs to 60 and every census comes back
##                       "avg=60 1%low=60", which measures the display and not
##                       the game.
##
## M3.8 flags:
##   --hud-state NAME [PHASE]
##       Force the HUD into a state a capture could not otherwise reach, and
##       *freeze* it there. Every animation in the interface runs off
##       `UiFx.clock()`, which counts frames rather than wall time during an
##       automated run — so with one of these the same shutter frame produces
##       the same picture on any machine, which is what makes the M3.8 states
##       diffable across iterations.
##
##         boot      play the shell's compile-in sequence (automation normally
##                   skips it) and hold it at PHASE, 0..1 of the way through.
##                   Defaults to 0.35 — the frame where half the readouts are
##                   up, the ring is visibly still spinning, and the self-test
##                   line is still typing.
##         full      inject with a full pool. The settled, healthy HUD.
##         warn      inject at 45% — the amber band.
##         low       inject at 10% — red, beating, and visibly decaying.
##         damage    pin the damage flinch and its edge arc on, permanently.
##         debrief   let the debrief type itself in rather than snapping to the
##                   finished panel, and pop a synthetic one a few seconds in so
##                   the screen can be photographed without playing a whole run.
##                   The payload is flagged `synthetic`, so Achievements ignores
##                   it and no save file is touched — the screen is real, the run
##                   behind it is not.
##         decompile hold the menu's dive transition open at its midpoint — the
##                   0.8 s glitch dissolve that takes the screen apart on the way
##                   into a layer.
##         readout   (PT1) hold every enemy integrity readout open at a fixed
##                   fraction. The bars surface on damage or on the crosshair
##                   resolving a target, neither of which a shutter can be aimed
##                   at, so this is the only way to photograph one. Pair it with
##                   `--goto nest`.
##         refused   (M4) pin the Compiler panel's refusal glitch on. Half a
##                   second of corrupted price and a shaking row is not a state a
##                   shutter lands in by luck, and it is the frame that proves the
##                   panel speaks the same glitch vocabulary as everything else.
##                   Pair it with `--compiler`.
##         compiling (M4.7) pin the Compiler panel's COMPILING beat at its
##                   midpoint — the row locked, the progress band mid-sweep, the
##                   tier pip not yet filled. The beat is 0.62 s long and
##                   automation deliberately skips it, so this is the only way to
##                   photograph it. Pair it with `--compiler --buy TRACK`.
##
##       `full`/`warn`/`low` are shorthand for `--cycles N`: they set the real
##       pool the host starts with, so the colour, the heartbeat, the shader
##       degradation and the interface decay are all the genuine article rather
##       than a HUD-local lie.
##
## M4 flags. The module economy has two curves in it (threat and power) and the
## only honest way to tune them is to be able to put an arbitrary build into an
## arbitrary layer and measure what happens. These are permanent dev tools, not
## scaffolding:
##   --modules "runtime:3,optics:2"
##       Force the local program's module tiers for this session. Never written
##       to the save file: it is a measuring instrument, not a cheat that sticks.
##       Track ids are Balance.MODULE_TRACKS; an unknown one warns and is
##       ignored. Applies on the host and on a client independently, which is how
##       "each peer's modules apply to the right player" gets tested.
##   --archive N
##       Start the session with N data in the wallet, so a Compiler capture does
##       not need sixty runs behind it.
##
##   --backdoor N
##       Announce N as this program's deepest rooted backdoor. `--backdoor 0` is
##       a program that has never rooted anything, which is the second instance
##       the injection gate has to turn away — the only way to test DESIGN.md's
##       "all present crew must have installed it" rule without two save files.
##
##       Any of the three above puts the program file in SANDBOX mode for the
##       whole session: `GameState.save_progress` becomes a no-op, so a capture
##       that buys four modules to photograph them cannot spend the developer's
##       real archive or leave tiers behind in their save.
##   --log-modules
##       Print every peer's resolved loadout on boot and after every purchase.
##       This is the flag that turns "the effect measurably applied" into a
##       number in a log rather than a claim about a screenshot.
##   --compiler [delay]
##       Walk to the layer's Compiler and open its panel at `delay` seconds.
##   --buy TRACK [delay]
##       Purchase one tier of TRACK through the real request path (the host
##       validates funds, stock and proximity) once the panel is up. Repeatable.
##
## M4.8 flags. The functional clutter is five props with host-validated state
## between them, and none of it can be photographed or asserted on without being
## able to walk up to a specific one and use it:
##   --goto junction|vent|cabinet|terminal|bulkhead|debris
##       Stand in front of that prop, facing it, at a distance chosen per prop
##       (see M48_TARGETS). Combines with `--fire` to weld a vent or cut a
##       cabinet lock, and with `--hold-interact` to seal a bulkhead.
##   --rewire LOAD [delay]
##       Walk to the junction, open its panel, and route the bus.
##       LOAD: lights | doors | fans | none. Drives the panel's own request path,
##       so the host's proximity check and the noise ping are both real.
##   --terminal [delay]
##       Open a command-terminal session.
##   --query "LIST DATA" [--query "QUERY VAULT-7C" ...]
##       Type commands into it, in order, waiting out each answer. Repeatable.
##   --pad [row]
##       Park the terminal's gamepad command list on a row, so the pad path can
##       be photographed. Parity is a design law (DESIGN.md's solo invariant has
##       an accessibility half), and an unphotographable feature is one nobody
##       checks.
##   --seal [delay]
##       Hold the bulkhead's channel until the door is genuinely shut, then let
##       go. `--hold-interact` cannot do this: the bulkhead is the only
##       interactable that toggles, so a key held down cycles it forever.
##   --no-descend
##       The tour stops when it has used everything instead of riding the shaft
##       down. What a staged capture wants, and what the reinforcement-trickle
##       check needs — a layer that has been fully worked over and is still there.
##   --tour
##       Use EVERY M4.8 prop on every layer, in the order they are meant to be
##       used in, then ride the shaft down and do it again. A solo `--tour` from
##       layer 1 is the milestone's end-to-end proof: it drives real inputs and
##       waits on replicated state, so a step that stopped working hangs the run
##       instead of scrolling past. Pair with `--exfil` for the full loop.
##
## M3.5 (Steam) flags:
##   --no-steam          never touch the Steam API, even with the client running.
##                       The ENet-only regression path on a Steam machine.
##   --app-id N          initialise against N instead of 480 (Spacewar).
##   --steamhost         host over the Steam transport (lobby + SteamMultiplayer-
##                       Peer) instead of ENet, and drop into the layer.
##   --steamjoin ID      join Steam lobby ID directly, the way an overlay invite
##                       would.
##   --steam-selftest    print SteamID, persona, lobby id, lobby metadata and the
##                       rich-presence readback a few seconds in. Pairs with
##                       --steamhost to prove a lobby is real without a second
##                       account.
##   --reset-achievements  wipe user://achievements.json (and clear our ids at
##                       Steam) before anything else runs.
##   --grant ID          unlock achievement ID at boot; repeatable. `--grant ALL`
##                       unlocks the lot. Toasts exactly like the real thing.
##
## PT1 (Playtest I) flags. The first friend playtest returned six complaints that
## every scripted capture in the repo had said were fine, because a scripted
## capture never moves a mouse. These three exist so a *live* session is
## reproducible and measurable rather than merely watched:
##   --playtest [seconds]
##       Host and drop into the layer like `--autohost`, but do NOT mark the run
##       automated: the mouse is captured, every local input is live, and the
##       session behaves exactly as it does for a player. `seconds` (default 300)
##       caps the process lifetime so a driven session can never wedge a machine.
##       This is the ONLY flag that opens a real interactive instance; everything
##       else in this file deliberately refuses the pointer.
##   --gunlog PATH
##       Per RENDERED frame, append `frame,dt_ms,yaw,pitch,gx,gy,gz,mx,my,mz`:
##       the breaker's GRIP and its EMITTER, in the lens's own frame, in metres.
##       A hold bolted to the lens keeps those six numbers constant however hard
##       the mouse is thrown; every centimetre they move is a centimetre the
##       weapon slid away from the eye. That difference is the whole of the "the
##       gun doesn't move with the camera" complaint, and this turns it into a
##       column of numbers instead of an argument. (Camera space, not screen
##       pixels, on purpose — see `_sample_gun`.)
##   --burst DIR [N]
##       Press F9 to dump the next N (default 24) CONSECUTIVE rendered frames as
##       `DIR/burst_XXX.png`. Frames are read back into RAM during the burst and
##       written to disk afterwards, so the capture itself does not stall the
##       frames it is measuring. The filmstrip a human looks at, next to the
##       numbers `--gunlog` prints.

const BOOT_DELAY_FRAMES: int = 2

## True whenever this process was launched to drive itself rather than to be
## played. Automated runs share a live desktop with a human who is doing
## something else, so they never take keyboard focus and never capture the
## mouse — see `_stay_out_of_the_way`, Player._capture_mouse and Hud._set_paused.
var automated: bool = false

var screenshot_path: String = ""
var screenshot_frames: int = 120
var auto_quit_after: float = 0.0

## `--window-size WxH`. Zero means "leave the window alone". See the header: this
## is the flag that makes an aspect-ratio claim checkable.
var forced_window_size: Vector2i = Vector2i.ZERO

## `--ui-scale F` / `--vignette F`: the two PT2 display settings, forced for this
## SESSION ONLY.
##
## Same doctrine as `--captions` and `--modules` (see `_ready`): a dev flag is a
## measuring instrument, never a setting that sticks. These write `Screen`'s
## fields directly and deliberately do NOT go through `Screen.set_ui_scale` /
## `set_vignette`, because those persist — and a capture run that photographed the
## slider at 1.6 would leave the developer's real interface at 1.6 forever.
## Negative means "leave the player's own value alone".
var forced_ui_scale: float = -1.0
var forced_vignette: float = -1.0

## `--no-safe-area`: put the menu and the HUD back on the pre-PT2 geometry, where
## every anchored element was pinned to the CANVAS edge instead of to the tube-safe
## box (see `UiFx.tube_safe_rect`).
##
## This is a MEASURING INSTRUMENT, not a compatibility switch. The whole PT2 layout
## claim is "these elements were in the wrong place at wide aspects", and a claim
## like that is only checkable if the wrong place can still be photographed from
## the same build — otherwise the before-picture and the after-picture differ by a
## thousand other things too. Run the same command twice, once with this flag, and
## the diff is the anchoring and nothing else.
var no_safe_area: bool = false

## `--tour [seconds]`: walk the local avatar through the layer's rooms, one every
## `seconds`, forever.
##
## The PT2 minimap's whole claim is "rooms appear as you enter them", and there
## was no way to photograph that: every existing probe teleports to ONE fixture
## and stands there, so a capture could only ever show a map with one room on it
## — which is indistinguishable from a map that is broken. This drives the same
## `teleport_to` the `--goto` targets use, room by room along the graph, so the
## discovery it produces goes through the real path (room containment, the host's
## validation, the line-of-sight raycasts) rather than through a back door that
## marks things discovered. It is a camera dolly, not a cheat.
var tour_interval: float = 0.0
var _tour_index: int = 0
var _tour_clock: float = 0.0

## `--playtest`. Overrides `automated` back to false: this is the one mode that
## wants the pointer, because the six PT1 complaints are all things a human
## noticed with a mouse in their hand and no scripted probe ever will.
var live_input: bool = false
## `--gunlog PATH` / `--burst DIR [N]`. See the header.
var gun_log_path: String = ""
var burst_dir: String = ""
var burst_frames: int = 24

## Set while a screenshot run is armed. Player honours it and ignores ALL local
## input. A windowed capture on a live desktop still receives the real user's
## cursor and keystrokes — without this the avatar wanders off mid-run and no two
## captures ever frame the same shot.
var lock_input: bool = false

# --- world selection (read by Net.host) -------------------------------------
var forced_seed: int = 0
var start_layer: int = 1
var use_test_layer: bool = false
## Negative means "start full".
var start_cycles: float = -1.0
var log_cycles: bool = false

# --- THE PARTITION (read by Net.host via `hub_start`) ------------------------
#
# `--hub` starts the session in the crew's staging sector; `--no-hub` forces the
# old behaviour of injecting straight into a layer. The DEFAULT is the interesting
# part and it is asymmetric on purpose:
#
#   a human       gets the hub, always. It is the front door now.
#   an automated  gets the layer, unless it asks. Every scripted capture in this
#   run           repo was written against "boot lands you in a layer" — `--goto
#                 shaft`, `--autodescend`, `--exfil`, every screenshot script —
#                 and none of them can walk themselves through a commit ritual
#                 that did not exist when they were written. Changing the default
#                 under them would have broken the whole verification surface of
#                 the project to add one feature.
#
# `--hub` is therefore how the hub itself gets photographed and soak-tested, and
# `--goto shaft` (or its `rig` alias) resolves to the injection rig inside it, so
# `--hub --goto rig --hold-interact 3` is a full boot-to-dive on the real input
# path with no shortcuts through the host validation.
var want_hub: bool = false
var no_hub: bool = false


## Whether this process's session should open in THE PARTITION. See the block
## above for why an automated run has to answer differently from a human one.
func hub_start() -> bool:
	if no_hub:
		return false
	if want_hub:
		return true
	return not automated

# --- M3.8 HUD capture states (read by Hud, DamageArc and MainMenu) -----------
## `--hud-state`. Empty means "behave normally". See the header for the values.
var hud_state: String = ""
## Where in the boot sequence `--hud-state boot` freezes, 0..1. A third of the
## way through is the frame worth photographing: the ring is visibly still
## spinning up, half the readouts have not resolved, and the self-test line is
## mid-type. Later than this and it just looks like the finished HUD.
var hud_boot_phase: float = 0.35
## `--hud-debug`. Restores the diagnostics line the quiet-instrument HUD (M4.9)
## demotes out of gameplay ("LISTEN HOST · N CREW", link latency, OFFLINE) as a
## standing debug overlay. Read by Hud._refresh_link. Off means the line stays
## dark and only surfaces on its own merit (a link actually going bad).
var hud_debug: bool = false

# --- M4 modules / economy ----------------------------------------------------
## `--modules`, applied to Modules once the autoloads are standing.
var module_spec: String = ""
## `--archive`. Negative means "use whatever the program file holds".
var start_archive: int = -1
## `--log-modules`.
var log_modules: bool = false
## `--backdoor`. Negative means "use the program file's own". Zero is a program
## that has never rooted anything — the crewmate the injection gate turns away.
var forced_backdoor: int = -1

# --- M3 world/AI selection ---------------------------------------------------
## Generate the layer with no antivirus in it, for isolating everything else.
var no_antivirus: bool = false

## `--haunt <hound|moth|auditor|all>`: force the named hunter(s) standing on the
## first layer, past the depth and pacing gates, for a capture or a behaviour
## test. Read by the HauntDirector on `begin`.
var haunt_force: String = ""
## `--stress N` (0..1): pin the Director's stress value, so a capture can drive the
## music and the glitch-proximity to a known intensity. Negative = off.
var stress_force: float = -1.0
## Read by the director and both state machines.
var log_ai: bool = false
## `--log-audio`. Read by AudioService and CaptionBus: print one line per sound
## trigger and per caption, so a scripted solo run can prove every source fires
## with no missing streams — the M5 audio soak's verification, without ears.
var log_audio: bool = false
## `--captions` / `--subtitles`. Turn the two text tracks on FOR THIS SESSION
## ONLY (both default OFF). Never written to user://a11y.cfg — see `_ready`.
var force_captions: bool = false
var force_subtitles: bool = false

# --- M3.5 Steam / achievements (read by SteamHub and Achievements) ----------
## Hard off switch for the Steam API: the game runs its ENet paths untouched.
var no_steam: bool = false
## 0 means "use SteamHub.DEV_APP_ID" (480, Spacewar).
var steam_app_id: int = 0
## Print the Steam session back out of the API once it is up.
var steam_selftest: bool = false
var reset_achievements: bool = false
var granted_achievements: PackedStringArray = PackedStringArray()

# --- synthetic input (read by Player) ---------------------------------------
var hold_interact: bool = false
var hold_sprint: bool = false
var hold_forward: bool = false
var hold_fire: bool = false
## Track the nearest antivirus with the lens (read by Player).
var aim_antivirus: bool = false

var _mode: String = ""
var _address: String = "127.0.0.1"
var _port: int = Net.DEFAULT_PORT
var _name_override: String = ""
var _color_index: int = 0
## `--color RRGGBB`. Overrides the program file's phosphor for this session only.
var _forced_color: Color = Color.WHITE
var _has_forced_color: bool = false

var _dump_seed: int = 0
var _dump_layer: int = 1
## M6.6 `--dumplive PATH`: write the graph this peer ACTUALLY built to PATH the
## moment the layer stands. `--dumplayer` proves the generator is a pure function
## of (seed, layer) in a fresh process; this proves a HOST and a CLIENT in a live
## ENet session ended up with the same layer, which is the cross-peer half of the
## determinism contract and the half a standalone dump cannot speak to.
var dump_live_path: String = ""
## M6.6 `--pathwalk`: after the layer stands, sweep a player-sized capsule from
## every injection point to the drop shaft and quit non-zero if any leg is
## blocked. The solo invariant, checked against real colliders.
var _pathwalk: bool = false
## M6.6 `--auditvert`: placement-quality sweep over every vertical element.
var _auditvert: bool = false
## `--tailprobe WHICH`. Which creature the spring-tail inspection stages.
var _tail_which: String = "sentinel"
var _last_probe_t: float = 0.0
## `--hunterprobe <hound|moth|auditor>`: stage one hunter on a lit turntable
## facing the camera for a clean bestiary portrait. AI frozen so it holds its idle.
var _hunter_which: String = "hound"
## `--walkprobe <sentinel|crew|crew_run|scrubber|hound|auditor|moth> [speed]`: the
## foot-skate acceptance test made into a permanent instrument. See `_run_walk_probe`.
var _walk_which: String = "sentinel"
var _walk_speed: float = -1.0
## `--tailmotion <crew|sentinel>`: drive a scripted turn/run/jump/land and capture
## the tail's live swing. Set true so TailDriver does NOT freeze under automation.
var _tail_motion_which: String = "crew"
var tail_live: bool = false
## `--steamjoin` target.
var _lobby_id: int = 0

## `--pitch`. Applied on top of whatever a `--goto` target chose.
var pitch_override: float = 0.0
var _has_pitch: bool = false

var _goto: String = ""
var _goto_delay: float = 1.6
var _hold_delay: float = -1.0
var _auto_descend: bool = false
var _decompile_at: float = -1.0
var _fire_delay: float = -1.0
var _flare_delay: float = -1.0
var _exfil_delay: float = -1.0
var _grab_count: int = 0
var _compiler_delay: float = -1.0
## `--buy` targets, in the order they were given.
var _buy_tracks: PackedStringArray = PackedStringArray()
var _buy_delay: float = 1.2

# --- M4.8 functional clutter -------------------------------------------------
## `--rewire MODE`. -1 means "open the panel and change nothing".
var _rewire_mode: int = -1
var _rewire_delay: float = -1.0
## `--seal`. Holds the bulkhead channel until the door is genuinely shut and then
## lets go — a plain `--hold-interact` would keep toggling it.
var _seal_delay: float = -1.0
## `--tour`. Use every M4.8 prop on every layer, then ride the shaft down.
var _tour: bool = false
## `--no-descend`. The tour stays where it is once it has used everything, which
## is what a staged capture (and the reinforcement-trickle check) needs: both
## want a layer that has been fully worked over and is still standing.
var _no_descend: bool = false
## `--terminal` / `--query CMD` (repeatable) / `--pad ROW`.
var _terminal_delay: float = -1.0
var _queries: PackedStringArray = PackedStringArray()
var _query_delay: float = 1.0
var _pad_row: int = -1

## How far back `--goto compiler` stands. Far enough that the lectern and its
## cowl both fit in frame, close enough that the readout rows still resolve.
const COMPILER_STANDOFF: float = 2.9

## How close `--goto wallhug` parks the avatar to a wall. Inside the capsule's
## own radius plus a hair, so the depenetration step leaves the lens roughly
## half a metre off the panel — comfortably inside Player.WEAPON_CLEAR, which is
## the whole point of the probe.
const WALLHUG_STANDOFF: float = 0.72

## Seconds of shader-compilation and layer-build time excluded from the census.
const FPS_WARMUP: float = 4.0

## `--log-fps`. Zero disables.
var _fps_window: float = 0.0
var _fps_warmup: float = 0.0
var _fps_clock: float = 0.0
var _fps_samples: PackedFloat32Array = PackedFloat32Array()

var _shot_armed: bool = false
var _frames_left: int = 0
var _shot_taken: bool = false

# --- PT1 instruments ---------------------------------------------------------
## `--gunlog`. Open for the whole session, flushed on quit.
var _gun_log: FileAccess = null
var _gun_frame: int = 0
var _gun_last: Vector2 = Vector2.ZERO
var _gun_has_last: bool = false
## `--burst`. Frames are held as Images until the burst ends: writing a 1280x720
## PNG takes longer than the frame it is a picture of, so writing during the
## burst would measure the encoder rather than the game.
var _burst_left: int = 0
var _burst_taken: Array[Image] = []
var _burst_index: int = 0


func _ready() -> void:
	_parse_args(OS.get_cmdline_user_args())
	# Before ANY Control is built: the menu and the HUD size themselves off the
	# window, and a resize that lands after they have laid out is a resize half
	# the tree only hears about via `size_changed`. Doing it first means an
	# ultrawide capture exercises the same first-layout path a fullscreen player
	# on a 32:9 panel does.
	_apply_forced_window_size()
	_apply_forced_display()
	if physics_hz > 0:
		Engine.physics_ticks_per_second = physics_hz
		print("[Debug] --physics-hz: simulation at %d, rendering uncapped" % physics_hz)
	# Before anything reads a tier or a wallet: Net announces the program the
	# instant it hosts or joins, and a forced build that arrives after that
	# announcement is a build the host never hears about.
	_apply_program_overrides()
	# `--captions` / `--subtitles`: SESSION ONLY.
	#
	# These used to go through `A11y.set_sound_captions`, which persists — so any
	# capture run that staged the caption system left it switched on in the
	# developer's real profile, permanently, and the next person to launch the
	# game got captions nobody asked for. Same doctrine as `--modules` and
	# `--archive` (see `_apply_program_overrides`): a dev flag is a measuring
	# instrument, never a setting that sticks. The fields are written directly and
	# `changed` is emitted so live views update; nothing reaches user://a11y.cfg.
	if force_captions or force_subtitles:
		if force_captions:
			A11y.sound_captions = true
		if force_subtitles:
			A11y.subtitles = true
		A11y.changed.emit()
	# Before any interface exists: the phosphor is a palette-wide token and
	# something built earlier than this would bake the default into itself.
	if _has_forced_color:
		GameState.local_color = _forced_color
		UiFx.set_phosphor(_forced_color)
	# `--playtest` is the one exception, and it is deliberately the last word: it
	# hosts through the same path `--autohost` does and then hands the session
	# back to a human (or to xdotool pretending to be one). Everything the
	# automation guard exists to prevent — stolen focus, a captured pointer — is
	# exactly what a live playtest needs.
	automated = (not _mode.is_empty() or not screenshot_path.is_empty() \
			or auto_quit_after > 0.0 or steam_selftest \
			or not aim_trace_dir.is_empty() or aim_drive \
			or not bore_trace_dir.is_empty() or reticle_probe \
			or refresh_probe > 0.0 \
			or not reel_dir.is_empty()) and not live_input
	# Round five: the viewmodel lens, for this session only. Written before the
	# first avatar is built, which is what makes `--gunlens 0` a real A/B arm
	# rather than a value that lands one frame after the hold has been placed.
	if gun_lens_deg >= 0.0:
		CrewAvatar.gun_lens_override = gun_lens_deg
		print("[Debug] --gunlens: viewmodel lens forced to %.1f deg" % gun_lens_deg)
	if chord_aim:
		CrewAvatar.aim_chord_override = true
		print("[Debug] --chordaim: aiming the grip-to-muzzle chord (the old way)")
	if std_materials:
		CrewAvatar.fp_lens_disabled = true
		print("[Debug] --stdmaterials: FP body left on StandardMaterial3D")
	if not is_nan(hold_offset.x):
		CrewAvatar.hold_offset_override = hold_offset
		print("[Debug] --hold: grip parked at %s in the lens's frame" % hold_offset)
	if automated:
		_stay_out_of_the_way()
	if _mode == "dump":
		_dump_layer_graph.call_deferred()
		return
	if _mode == "selftest":
		_balance_selftest.call_deferred()
		return
	if _mode == "tailprobe":
		_run_tail_probe.call_deferred()
		return
	if _mode == "hunterprobe":
		_run_hunter_probe.call_deferred()
		return
	if _mode == "walkprobe":
		_run_walk_probe.call_deferred()
		return
	if _mode == "tailmotion":
		_run_tail_motion.call_deferred()
		return
	if _mode.is_empty() and screenshot_path.is_empty() and auto_quit_after <= 0.0 \
			and not steam_selftest and gun_log_path.is_empty() and burst_dir.is_empty() \
			and aim_trace_dir.is_empty() and not aim_drive and not aim_overlay_only \
			and bore_trace_dir.is_empty() and not reticle_probe \
			and refresh_probe <= 0.0 \
			and reel_dir.is_empty():
		set_process(false)
		return
	if not gun_log_path.is_empty():
		_open_gun_log()
		add_child(LateSampler.new())
	if not aim_trace_dir.is_empty() or aim_overlay_only or not aim_strip_dir.is_empty():
		_start_aim_trace.call_deferred()
	if not bore_trace_dir.is_empty():
		_start_bore_trace.call_deferred()
	if reticle_probe:
		_run_reticle_probe.call_deferred()
	if refresh_probe > 0.0:
		_run_refresh_probe.call_deferred()
	# Stays processing for the whole run, not just while a screenshot is armed:
	# `_enforce_mouse` has to be live from boot to quit, including across the
	# menu -> layer scene change and every descent after it.
	set_process(true)
	_boot.call_deferred()


## `--modules` and `--archive`. Both are session-only by construction: the tier
## override lives in Modules and is never written back, and the archive is
## poked into GameState in memory without a save. A dev tool that edits the
## player's program file would be a dev tool nobody could safely run twice.
func _apply_program_overrides() -> void:
	if module_spec.is_empty() and start_archive < 0 and forced_backdoor < 0 \
			and subroutine_spec.is_empty():
		return
	# Either override makes this session's program a fabrication, and a
	# fabrication must never be written back over the real one — including by the
	# purchases a capture makes while photographing the Compiler.
	GameState.sandboxed = true
	print("[Debug] program file is SANDBOXED for this session: nothing will be saved")
	if not module_spec.is_empty():
		Modules.force_tiers(module_spec)
	if not subroutine_spec.is_empty():
		Subs.force(subroutine_spec)
	if start_archive >= 0:
		print("[Debug] --archive: wallet forced to %d" % start_archive)
		GameState.archive = start_archive
	if forced_backdoor >= 0:
		print("[Debug] --backdoor: deepest backdoor forced to %d" % forced_backdoor)
		GameState.deepest_backdoor = forced_backdoor
	if log_modules:
		Modules.purchased.connect(_log_purchase)


func _log_purchase(peer_id: int, track: String, tier: int,
		from_buffer: int, from_archive: int) -> void:
	print("[Modules] %s -> %s tier %d (paid %d buffered + %d archive)" % [
		Net.crew_name(peer_id), track.to_upper(), tier, from_buffer, from_archive])
	print("[Modules]   %s" % Modules.describe_loadout(peer_id))


## Every peer's resolved build, once the crew is standing. `--log-modules` prints
## this at the top of a run so a before/after pair around a purchase is two lines
## in the same log rather than two screenshots.
func _log_loadouts() -> void:
	if not log_modules:
		return
	print("[Modules] --- loadouts ---")
	for id: int in Net.crew.keys():
		print("[Modules] %-14s [%s]" % [
			Net.crew_name(int(id)), Modules.describe(Modules.tiers_of(int(id)))])
		print("[Modules]   %s" % Modules.describe_loadout(int(id)))
	print("[Modules] pool ceiling %.0f for %d crew" % [
		Modules.crew_pool_max(), Net.crew.size()])
	print("[Modules] ----------------")


## Automated runs are launched *next to* whatever the developer is actually
## doing — often a full-screen game on the other monitor. A capture that steals
## keyboard focus or grabs the cursor ruins both the desktop and the capture, so
## an automated window is opened as a bystander: never focused, never focusable,
## and never in possession of the pointer.
##
## This is a **hard rule, not a nicety**. An automated run that captures the
## mouse yanks the cursor out of whatever the developer was doing on the other
## monitor, and because it happens on a spawn — several seconds into a run that
## was supposed to be invisible — it is very hard to attribute. It has bitten
## this project once already.
##
## Three layers, deliberately redundant:
##   1. every `MOUSE_MODE_CAPTURED` call site asks `may_capture_mouse()` first
##      (Player._capture_mouse, Hud._set_paused)
##   2. the window is opened un-focusable
##   3. `_enforce_mouse()` below re-asserts VISIBLE every frame regardless, so a
##      capture from a path nobody thought of survives for at most one frame
##
## Belt, braces, and a second pair of braces. The correct runtime cost of this is
## "one enum comparison per frame during automated runs only", which is nothing.
## `--window-size WxH`. Borderless and parked at the screen origin on purpose:
## a decorated window subtracts its title bar from the height the compositor
## grants, so `--resolution 3440x1440` produced a 3440x1412 window — a different
## aspect ratio than the one the capture was taken to prove. Borderless removes
## the subtraction; the origin removes the "window is partly off-screen so the
## WM shrank it" failure. The granted size is read back and printed, so a request
## the compositor refused is visible in the log rather than in a wrong picture.
func _apply_forced_window_size() -> void:
	if forced_window_size == Vector2i.ZERO:
		return
	if DisplayServer.get_name() == "headless":
		push_warning("[Debug] --window-size ignored: headless has no window")
		forced_window_size = Vector2i.ZERO
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_size(forced_window_size)
	DisplayServer.window_set_position(Vector2i.ZERO)
	var granted: Vector2i = DisplayServer.window_get_size()
	print("[Debug] --window-size %dx%d -> window %dx%d%s" % [
		forced_window_size.x, forced_window_size.y, granted.x, granted.y,
		"" if granted == forced_window_size else "  (COMPOSITOR REFUSED)"])


## `--ui-scale` / `--vignette`. SESSION ONLY — see the fields for why nothing here
## goes through the persisting setters.
func _apply_forced_display() -> void:
	if forced_ui_scale < 0.0 and forced_vignette < 0.0:
		return
	if forced_ui_scale >= 0.0:
		Screen.ui_scale = clampf(forced_ui_scale, Screen.UI_SCALE_MIN, Screen.UI_SCALE_MAX)
	if forced_vignette >= 0.0:
		Screen.vignette = clampf(forced_vignette, Screen.VIGNETTE_MIN, Screen.VIGNETTE_MAX)
	Screen.call("_apply")
	print("[Debug] display forced: ui_scale=%.2f vignette=%.2f" % [
		Screen.ui_scale, Screen.vignette])


func _stay_out_of_the_way() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## The single question every `MOUSE_MODE_CAPTURED` call site in the codebase has
## to ask. Kept here rather than duplicated as `if Debug.automated` at each site
## so that "what counts as automated" can never drift between them.
func may_capture_mouse() -> bool:
	return not automated and DisplayServer.get_name() != "headless"


## Layer 3 of the guard above: whatever anybody does, an automated run holds the
## pointer for at most one frame. Runs unconditionally while `automated`.
func _enforce_mouse() -> void:
	if not automated or DisplayServer.get_name() == "headless":
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE:
		push_warning("[Debug] something captured the mouse during an automated "
				+ "run; releasing it")
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _parse_args(args: PackedStringArray) -> void:
	var i: int = 0
	while i < args.size():
		var arg: String = args[i]
		match arg:
			"--server":
				_mode = "server"
			"--autohost":
				_mode = "host"
			"--playtest":
				# Same host path as --autohost; the difference is `live_input`,
				# which vetoes `automated` and therefore the whole mouse guard.
				_mode = "host"
				live_input = true
				auto_quit_after = 300.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					auto_quit_after = maxf(args[i].to_float(), 1.0)
			"--autojoin":
				_mode = "join"
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_address = args[i]
			"--steamhost":
				_mode = "steamhost"
			"--steamjoin":
				_mode = "steamjoin"
				if i + 1 < args.size():
					i += 1
					_lobby_id = args[i].to_int()
			"--no-steam":
				no_steam = true
			"--app-id":
				if i + 1 < args.size():
					i += 1
					steam_app_id = args[i].to_int()
			"--steam-selftest":
				steam_selftest = true
			"--reset-achievements":
				reset_achievements = true
			"--grant":
				if i + 1 < args.size():
					i += 1
					granted_achievements.append(args[i])
			"--port":
				if i + 1 < args.size():
					i += 1
					_port = args[i].to_int()
			"--name":
				if i + 1 < args.size():
					i += 1
					_name_override = args[i]
			"--color":
				if i + 1 < args.size():
					i += 1
					# A swatch index OR a hex colour. Since M4.7 the shell marker is
					# also the phosphor the whole interface is coated with, so
					# "photograph the HUD in green" is something a capture has to be
					# able to ask for.
					if Color.html_is_valid(args[i]):
						_forced_color = UiFx.clamp_phosphor(Color.html(args[i]))
						_has_forced_color = true
					else:
						_color_index = args[i].to_int()
			"--seed":
				if i + 1 < args.size():
					i += 1
					forced_seed = args[i].to_int()
			"--layer":
				if i + 1 < args.size():
					i += 1
					start_layer = maxi(args[i].to_int(), 1)
			"--testlayer":
				use_test_layer = true
			"--hub":
				want_hub = true
			"--no-hub":
				no_hub = true
			"--cycles":
				if i + 1 < args.size():
					i += 1
					start_cycles = args[i].to_float()
			"--log-cycles":
				log_cycles = true
			"--hud-state":
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					hud_state = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					hud_boot_phase = clampf(args[i].to_float(), 0.0, 1.0)
				_apply_hud_state()
			"--hud-debug":
				hud_debug = true
			"--log-ai":
				log_ai = true
			"--log-audio":
				log_audio = true
			"--captions":
				force_captions = true
			"--subtitles":
				force_subtitles = true
			"--log-fps":
				_fps_window = 5.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_fps_window = maxf(args[i].to_float(), 1.0)
			"--modules":
				if i + 1 < args.size():
					i += 1
					module_spec = args[i]
			"--archive":
				if i + 1 < args.size():
					i += 1
					start_archive = maxi(args[i].to_int(), 0)
			"--log-modules":
				log_modules = true
			"--backdoor":
				if i + 1 < args.size():
					i += 1
					forced_backdoor = maxi(args[i].to_int(), 0)
			"--compiler":
				_compiler_delay = 2.4
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_compiler_delay = args[i].to_float()
				if _goto.is_empty():
					_goto = "compiler"
			"--buy":
				if i + 1 < args.size():
					i += 1
					_buy_tracks.append(args[i].strip_edges().to_lower())
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_buy_delay = args[i].to_float()
			"--rewire":
				_rewire_delay = 2.6
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_rewire_mode = _power_mode(args[i])
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_rewire_delay = args[i].to_float()
				if _goto.is_empty():
					_goto = "junction"
			"--tour":
				_tour = true
			"--no-descend":
				_no_descend = true
			"--seal":
				_seal_delay = 2.6
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_seal_delay = args[i].to_float()
				if _goto.is_empty():
					_goto = "bulkhead"
			"--terminal":
				_terminal_delay = 2.6
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_terminal_delay = args[i].to_float()
				if _goto.is_empty():
					_goto = "terminal"
			"--query":
				if i + 1 < args.size():
					i += 1
					_queries.append(args[i])
				if _terminal_delay < 0.0:
					_terminal_delay = 2.6
				if _goto.is_empty():
					_goto = "terminal"
			"--pad":
				_pad_row = 6
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_pad_row = maxi(args[i].to_int(), 0)
			"--no-antivirus":
				no_antivirus = true
			"--haunt":
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					haunt_force = args[i].strip_edges().to_lower()
				else:
					haunt_force = "all"
			"--stress":
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					stress_force = clampf(args[i].to_float(), 0.0, 1.0)
			"--aim":
				aim_antivirus = true
			"--grab":
				_grab_count = 6
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_grab_count = maxi(args[i].to_int(), 1)
			"--exfil":
				_exfil_delay = 3.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_exfil_delay = args[i].to_float()
			"--fire":
				_fire_delay = 3.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_fire_delay = args[i].to_float()
			"--flare":
				_flare_delay = 3.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_flare_delay = args[i].to_float()
			"--pathwalk":
				_pathwalk = true
			"--auditvert":
				_auditvert = true
			"--dumplive":
				if i + 1 < args.size():
					i += 1
					dump_live_path = args[i]
			"--selftest":
				_mode = "selftest"
			"--tailprobe":
				# Dev inspection for the M4.9 spring tails: stage one creature on a
				# lit turntable-less side view so the resting sag can be judged and
				# tuned. Pair with `--screenshot PATH`.
				_mode = "tailprobe"
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_tail_which = args[i]
			"--hunterprobe":
				# M6 bestiary portraits: stage one hunter on a lit floor facing the
				# camera, AI frozen on its idle. Pair with `--screenshot PATH`.
				_mode = "hunterprobe"
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_hunter_which = args[i].strip_edges().to_lower()
			"--walkprobe":
				# M6.5 no-skate acceptance test: stage one ground creature side-on,
				# drive its speed-matched gait, measure foot-skate in mm/frame and save
				# a stacked side-on filmstrip. Pair with `--screenshot PATH`.
				_mode = "walkprobe"
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_walk_which = args[i].strip_edges().to_lower()
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_walk_speed = args[i].to_float()
			"--tailmotion":
				# M6.5 tail liveliness: drive a scripted turn/run/jump/land and stack a
				# filmstrip of the tail swinging. Pair with `--screenshot PATH`.
				_mode = "tailmotion"
				tail_live = true
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_tail_motion_which = args[i].strip_edges().to_lower()
			"--dumplayer":
				_mode = "dump"
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_dump_seed = args[i].to_int()
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_dump_layer = maxi(args[i].to_int(), 1)
			"--goto":
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_goto = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_goto_delay = args[i].to_float()
			"--hold-interact":
				_hold_delay = 3.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_hold_delay = args[i].to_float()
			"--decompile-at":
				if i + 1 < args.size():
					i += 1
					_decompile_at = args[i].to_float()
			"--pitch":
				if i + 1 < args.size():
					i += 1
					pitch_override = args[i].to_float()
					_has_pitch = true
			"--sprint":
				hold_sprint = true
				hold_forward = true
			"--autodescend":
				_auto_descend = true
				if _goto.is_empty():
					_goto = "shaft"
				if _hold_delay < 0.0:
					_hold_delay = _goto_delay + 1.2
			"--screenshot":
				if i + 1 < args.size():
					i += 1
					screenshot_path = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					screenshot_frames = maxi(args[i].to_int(), 1)
			"--quit-in":
				if i + 1 < args.size():
					i += 1
					auto_quit_after = args[i].to_float()
			"--window-size":
				if i + 1 < args.size():
					i += 1
					var parts: PackedStringArray = args[i].to_lower().split("x")
					if parts.size() == 2:
						forced_window_size = Vector2i(
								maxi(parts[0].to_int(), 1), maxi(parts[1].to_int(), 1))
					else:
						push_error("[Debug] --window-size wants WxH, got '%s'" % args[i])
			"--no-safe-area":
				no_safe_area = true
			# Renamed from "--tour" at merge: that name already has an arm at the
			# M4.8 prop tour above, and GDScript match takes the first — this one
			# was unreachable dead code from the day it was written.
			"--roomtour":
				tour_interval = 2.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					tour_interval = maxf(args[i].to_float(), 0.25)
			"--ui-scale":
				if i + 1 < args.size():
					i += 1
					forced_ui_scale = args[i].to_float()
			"--vignette":
				if i + 1 < args.size():
					i += 1
					forced_vignette = args[i].to_float()
			"--gunlog":
				if i + 1 < args.size():
					i += 1
					gun_log_path = args[i]
			"--burst":
				if i + 1 < args.size():
					i += 1
					burst_dir = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					burst_frames = maxi(args[i].to_int(), 1)
			# --- PT4 aim trace. See the section at the foot of this file. -------
			"--aimtrace":
				if i + 1 < args.size():
					i += 1
					aim_trace_dir = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					var stops: Array[float] = []
					for piece: String in args[i].split(",", false):
						stops.append(piece.to_float())
					if not stops.is_empty():
						aim_trace_pitches = stops
			# --- M7 subroutines & juice ----------------------------------------
			"--subroutine":
				if i + 1 < args.size():
					i += 1
					subroutine_spec = args[i]
			"--cast":
				_cast_delay = 3.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					_cast_delay = args[i].to_float()
			"--cast-every":
				if i + 1 < args.size():
					i += 1
					_cast_every = maxf(args[i].to_float(), 0.5)
			"--reel":
				if i + 1 < args.size():
					i += 1
					reel_dir = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					reel_every = maxi(args[i].to_int(), 1)
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					reel_frames = maxi(args[i].to_int(), 1)
			"--reel-from":
				if i + 1 < args.size():
					i += 1
					reel_from = maxi(args[i].to_int(), 0)
			"--aimdrive":
				aim_drive = true
			"--physics-hz":
				# Forces a render frame rate that is NOT the physics rate, which
				# is the only way to reproduce a whole class of pose bug on a
				# machine whose display happens to run at 60. This file already
				# carries one of those (`CrewAvatar._aim_bone`: an override that
				# compounded `fps/60` times and "only appeared on hardware other
				# than the developer's"), and PT4 found a second. Half the physics
				# rate means two rendered frames per tick, which is what a 120 Hz
				# panel does to a 60 Hz simulation.
				if i + 1 < args.size():
					i += 1
					physics_hz = maxi(args[i].to_int(), 1)
			"--aimstrip":
				aim_drive = true
				if i + 1 < args.size():
					i += 1
					aim_strip_dir = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					aim_strip_every = maxi(args[i].to_int(), 1)
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					aim_strip_frames = maxi(args[i].to_int(), 1)
			"--aimoverlay":
				# The overlay without the sweep: for a live-motion strip, and for
				# eyeballing a build interactively next to `--playtest`.
				if aim_trace_dir.is_empty():
					aim_overlay_only = true
			# --- round five: the bore trace. See the section at the foot. -------
			"--boretrace":
				if i + 1 < args.size():
					i += 1
					bore_trace_dir = args[i]
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					var stops: Array[float] = []
					for piece: String in args[i].split(",", false):
						stops.append(piece.to_float())
					if not stops.is_empty():
						bore_pitches = stops
			"--gunlens":
				if i + 1 < args.size():
					i += 1
					gun_lens_deg = args[i].to_float()
			"--reticleprobe":
				reticle_probe = true
			"--refreshprobe":
				refresh_probe = 6.0
				if i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					refresh_probe = maxf(args[i].to_float(), 1.0)
			"--hold":
				# `--hold x,y,z` in the lens's own frame, metres. The composition
				# A/B arm; see CrewAvatar.hold_offset_override.
				if i + 1 < args.size():
					i += 1
					var parts: PackedStringArray = args[i].split(",", false)
					if parts.size() == 3:
						hold_offset = Vector3(parts[0].to_float(),
								parts[1].to_float(), parts[2].to_float())
			"--stdmaterials":
				# The A/B arm for the FP material conversion. See
				# CrewAvatar.fp_lens_disabled.
				std_materials = true
			"--chordaim":
				# The old (round-four) aim, for the A/B arm. See
				# CrewAvatar.aim_chord_override.
				chord_aim = true
			_:
				pass
		i += 1


## `--rewire`'s argument. Named for the loads on the box rather than for the
## enum, because that is what the panel prints and what a capture command line
## should read like.
static func _power_mode(name: String) -> int:
	match name.strip_edges().to_lower():
		"lights", "lighting":
			return Props.Power.LIGHTS
		"doors", "locks":
			return Props.Power.DOORS
		"fans", "vents":
			return Props.Power.FANS
		"none", "off", "cut":
			return Props.Power.NONE
		_:
			push_warning("[Debug] --rewire: unknown load '%s'" % name)
			return -1


## `--hud-state`. The pool presets deliberately drive `--cycles` rather than
## poking the HUD: a capture of "the interface at 10%" has to be a capture of the
## game genuinely at 10%, or it is documenting something that cannot happen.
func _apply_hud_state() -> void:
	match hud_state:
		"full":
			start_cycles = -1.0
		"warn":
			start_cycles = 45.0
		"low":
			start_cycles = 10.0
		"boot", "damage", "debrief", "decompile", "refused", "compiling", \
				"resting", "descent", "combat", "damaged", "a11ywarn", \
				"settings", "map":
			# M4.9 quiet-instrument capture states. The pool stays full — these are
			# portraits of the resting HUD, the descent card and a hot breaker, not
			# of a drained pool — and the surfacing pins in Hud._apply_surface_capture
			# fake whatever the run itself is not doing (a wound, breaker heat).
			pass
		_:
			push_warning("[Debug] unknown --hud-state '%s'" % hud_state)
			hud_state = ""


## Pops the debrief without playing a run, so the summary screen can be
## photographed on its own. Emits `Run.run_ended` locally with a plausible
## payload — the HUD is a pure observer, so this exercises the real screen; it
## touches no authoritative state and never goes near the wire.
func _fake_debrief() -> void:
	await get_tree().create_timer(2.5).timeout
	print("[Debug] --hud-state debrief: emitting a synthetic run summary")
	var banked: Dictionary = {}
	var escaped: Array = []
	for id: int in Net.crew.keys():
		banked[int(id)] = 148 if int(id) == Net.local_id() else 96
		escaped.append(int(id))
	Run.run_ended.emit({
		# Marks the payload as fabricated. Achievements refuses to score it; the
		# HUD does not care, because the HUD's job is to display what it is given.
		"synthetic": true,
		"reason": "EXFILTRATED",
		"success": true,
		"banked": banked,
		"escaped": escaped,
		"crew": Net.crew.size(),
		"deleted": 0,
		"layers": 7,
		"start_layer": 1,
		"siphons": 11,
		"seconds": 512.0,
	})


func _boot() -> void:
	# Autoloads are ready before the main scene is swapped in; give the tree a
	# couple of frames so our change_scene_to_file() is not overwritten.
	for _i in BOOT_DELAY_FRAMES:
		await get_tree().process_frame

	if _fps_window > 0.0:
		_uncap_frame_rate()
	if not screenshot_path.is_empty():
		_arm_screenshot()
	if auto_quit_after > 0.0:
		_quit_after(auto_quit_after)
	if not _goto.is_empty() or _hold_delay >= 0.0 or _decompile_at >= 0.0 \
			or _fire_delay >= 0.0 or _flare_delay >= 0.0 or _exfil_delay >= 0.0 \
			or _grab_count > 0 or _compiler_delay >= 0.0 or _rewire_delay >= 0.0 \
			or _terminal_delay >= 0.0 or _tour or _cast_delay >= 0.0:
		_arm_automation()
	if log_modules:
		# On the roster rather than on the spawn: a client spawns before the crew
		# packet lands, so a census taken at spawn reports "0 crew" and none of the
		# builds it exists to print.
		Net.crew_changed.connect(_log_loadouts)
	if hud_state == "debrief":
		Net.local_player_spawned.connect(
				func(_p: Node) -> void: _fake_debrief(), CONNECT_ONE_SHOT)

	match _mode:
		"server":
			print("[Debug] dedicated server on port %d" % _port)
			Net.host(_port, true)
		"host":
			GameState.local_name = GameState.sanitize_name(
					_name_override if not _name_override.is_empty() else "HOST-A")
			GameState.local_color = _pick_color(0)
			print("[Debug] autohost as %s" % GameState.local_name)
			Net.host(_port, false)
		"join":
			GameState.local_name = GameState.sanitize_name(
					_name_override if not _name_override.is_empty() else "CREW-B")
			GameState.local_color = _pick_color(1)
			print("[Debug] autojoin %s:%d as %s" % [_address, _port, GameState.local_name])
			Net.join(_address, _port)
		"steamhost":
			GameState.local_name = GameState.sanitize_name(
					_name_override if not _name_override.is_empty()
					else SteamHub.suggested_name())
			GameState.local_color = _pick_color(0)
			print("[Debug] steam host as %s" % GameState.local_name)
			Net.host_steam()
		"steamjoin":
			GameState.local_name = GameState.sanitize_name(
					_name_override if not _name_override.is_empty()
					else SteamHub.suggested_name())
			GameState.local_color = _pick_color(1)
			print("[Debug] steam join lobby %d as %s" % [_lobby_id, GameState.local_name])
			Net.join_steam(_lobby_id)
		_:
			pass

	if steam_selftest:
		_steam_selftest()


## `--steam-selftest`. Reads the session back *out of the Steam API* rather than
## trusting what we asked it to do: the ID and persona, the lobby we own, its
## metadata as Steam stores it, and the rich presence string a friend would see.
## This is how a Steam lobby is verified without a second Steam account.
func _steam_selftest() -> void:
	await get_tree().create_timer(4.0).timeout
	print("[SelfTest] ---- steam ----")
	print("[SelfTest] live=%s status=%s" % [str(SteamHub.live), SteamHub.status])
	if not SteamHub.live:
		return
	print("[SelfTest] app=%d id=%d persona=%s overlay=%s" % [
		Steam.getAppID(), SteamHub.steam_id, SteamHub.persona,
		str(Steam.isOverlayEnabled())])
	print("[SelfTest] transport=%s online=%s crew=%d" % [
		"STEAM" if Net.transport == Net.Transport.STEAM else "DIRECT",
		str(Net.is_online), Net.crew.size()])
	print("[SelfTest] lobby=%d owner=%s members=%d" % [
		SteamHub.lobby, str(SteamHub.is_lobby_owner), SteamHub.lobby_member_count()])
	print("[SelfTest] lobby data=%s" % str(SteamHub.lobby_data()))
	print("[SelfTest] rich presence readback='%s'" % SteamHub.presence_readback())
	print("[SelfTest] peer=%s" % (
		"none" if Net.multiplayer.multiplayer_peer == null
		else Net.multiplayer.multiplayer_peer.get_class()))
	print("[SelfTest] achievements=%d/%d counters=%s" % [
		Achievements.earned.size(), Achievements.DEFINITIONS.size(),
		str(Achievements.counters)])
	print("[SelfTest] ---------------")


func _pick_color(fallback_index: int) -> Color:
	if _has_forced_color:
		return _forced_color
	if _color_index > 0:
		return GameState.DEFAULT_COLORS[
				_color_index % GameState.DEFAULT_COLORS.size()]
	# No override at all: the program file's own phosphor, so an automated run
	# photographs the interface the player would actually be looking at rather
	# than a swatch nobody picked.
	return GameState.local_color if fallback_index == 0 \
			else GameState.DEFAULT_COLORS[
					fallback_index % GameState.DEFAULT_COLORS.size()]


# ------------------------------------------------------------------ selftest --

## `--selftest`: headless invariant checks for the balance numbers that a
## determinism dump cannot see (they are pure sim-time scalars). Prints one line
## per check and quits non-zero if any fail, so a reviewer — or CI — can gate on
## `godot --headless --path . -- --selftest`. Added in M4.9 for the sprint-billing
## invariant the SPRINT_BILLING_SPEED bump depends on.
func _balance_selftest() -> void:
	var failures: int = 0

	# The sprint-billing invariant: a player walking flat-out with a maxed Servos
	# track must stay UNDER SPRINT_BILLING_SPEED, or merely walking would bill the
	# pool at the sprint rate. WALK_SPEED and the Servos ceiling are the two numbers
	# that fight; this asserts the margin the M4.9 retune (5.4 -> 6.0) restored.
	var servo_moves: Array = Balance.MODULES["servos"]["move"]
	var max_move: float = float(servo_moves[servo_moves.size() - 1])
	var max_walk: float = Player.WALK_SPEED * max_move
	if max_walk < Balance.SPRINT_BILLING_SPEED:
		print("[SelfTest] PASS  sprint-billing: max walk %.3f (WALK %.1f x Servos %.2f) < billing %.2f (margin %.3f)" % [
			max_walk, Player.WALK_SPEED, max_move, Balance.SPRINT_BILLING_SPEED,
			Balance.SPRINT_BILLING_SPEED - max_walk])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  sprint-billing: max walk %.3f >= billing %.2f" % [
			max_walk, Balance.SPRINT_BILLING_SPEED])

	# And the converse: a real sprint must always bill. The slowest a sprint moves
	# (no Servos, unstarved) has to clear the threshold, or sprinting could be free.
	if Player.SPRINT_SPEED > Balance.SPRINT_BILLING_SPEED:
		print("[SelfTest] PASS  sprint-bills: sprint %.2f > billing %.2f" % [
			Player.SPRINT_SPEED, Balance.SPRINT_BILLING_SPEED])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  sprint-bills: sprint %.2f <= billing %.2f" % [
			Player.SPRINT_SPEED, Balance.SPRINT_BILLING_SPEED])

	# SAFETY-CRITICAL (limbo-a11y 01-photosensitivity): flash-rate caps. Measures
	# the flicker curves that drive WORLD LIGHTS at their loudest (Reduced Flashing
	# OFF — A11y.flash_scale is 1.0 here, the ship-gate worst case) and asserts the
	# fastest pair of consecutive flashes stays at or under 3 Hz (WCAG 2.3.1). This
	# is the "frame-rate-of-flash" measurement; the old DYING (20 Hz) and ARC
	# (~6.7 Hz) curves would fail it, which is the point.
	for probe: Dictionary in [
			{"m": FlickerLight.Mode.DYING, "n": "DYING"},
			{"m": FlickerLight.Mode.ARC, "n": "ARC"}]:
		var meas: Dictionary = _measure_flash_hz(int(probe["m"]))
		var hz: float = float(meas["peak_hz"])
		var amp: float = float(meas["max_amp"])
		if hz <= 3.0:
			print("[SelfTest] PASS  flash-rate %-5s: peak %.2f Hz <= 3.0 Hz (max flash amp %.2f)" % [
				String(probe["n"]), hz, amp])
		else:
			failures += 1
			printerr("[SelfTest] FAIL  flash-rate %-5s: peak %.2f Hz > 3.0 Hz (WCAG 2.3.1)" % [
				String(probe["n"]), hz])

	# --- M6 the haunting -----------------------------------------------------

	# The killability law, as a number: every hunter must die to the breaker in a
	# finite, solo-payable number of shots. Checked at the DEEPEST scaling (a
	# layer-25 hunter) against a bare tier-0 cutter — the worst case a lone agent
	# with no modules faces. Anything that comes out "never dies" is a law break.
	var tier0: float = float(Balance.MODULES["breaker"]["damage"][0])
	for probe: Dictionary in [
			{"n": "HOUND", "hp": Balance.HOUND_HEALTH},
			{"n": "MOTH", "hp": Balance.MOTH_HEALTH},
			{"n": "AUDITOR", "hp": Balance.AUDITOR_HEALTH}]:
		var deep_hp: float = Balance.hunter_health(float(probe["hp"]), 25)
		var shots: int = int(ceil(deep_hp / tier0))
		# 40 tier-0 shots is the Sentinel's own body-shot budget (~43); a hunter must
		# come in under that, or it is a wall wearing a hunter's name.
		if deep_hp > 0.0 and shots <= 40:
			print("[SelfTest] PASS  killable %-7s: layer-25 hp %.0f = %d tier-0 shots (<= 40)" % [
				String(probe["n"]), deep_hp, shots])
		else:
			failures += 1
			printerr("[SelfTest] FAIL  killable %s: %d tier-0 shots (> 40) — killability law" % [
				String(probe["n"]), shots])

	# The escalation gates must be ordered (start < auditor < double) or the depth
	# curve is incoherent — a layer could offer two hunters before it offers one.
	if Balance.HUNT_START_LAYER < Balance.HUNT_AUDITOR_LAYER \
			and Balance.HUNT_AUDITOR_LAYER <= Balance.HUNT_DOUBLE_LAYER:
		print("[SelfTest] PASS  hunt escalation: none<6=%d, auditor=%d, double=%d ordered" % [
			Balance.HUNT_START_LAYER, Balance.HUNT_AUDITOR_LAYER, Balance.HUNT_DOUBLE_LAYER])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  hunt escalation gates out of order")

	# Bark corruption must scale with depth: clean surface, corrupt deep.
	if MotherBarks.tier_for(3) == 0 and MotherBarks.tier_for(9) == 1 \
			and MotherBarks.tier_for(18) == 2:
		print("[SelfTest] PASS  bark corruption: tier 0 @L3, 1 @L9, 2 @L18 (scales with depth)")
	else:
		failures += 1
		printerr("[SelfTest] FAIL  bark corruption tiers do not scale with depth")

	# SAFETY (a11y): the glitch-proximity sense is a NEW flash source, so it must be
	# bounded by the caps like every other. Assert its ceiling stays well under the
	# unconditional shader caps at full intensity, and that Reduced Flashing zeroes
	# it. It is an amplitude (not a FlickerLight curve), so this bounds the ceiling
	# rather than measuring Hz — the sustained ramp cannot itself strobe.
	var lit: float = A11y.flash_scale
	A11y.flash_scale = 1.0
	var ceil_on: float = A11y.glitch_proximity_ceiling()
	A11y.flash_scale = 0.0
	var ceil_reduced: float = A11y.glitch_proximity_ceiling()
	A11y.flash_scale = lit
	if ceil_on <= 0.75 and ceil_reduced <= 0.001:
		print("[SelfTest] PASS  glitch-proximity cap: %.2f at full, %.2f under Reduced Flashing" % [
			ceil_on, ceil_reduced])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  glitch-proximity cap: %.2f full / %.2f reduced (safety law)" % [
			ceil_on, ceil_reduced])

	# Dampened Protocol (M6 mercy): the single comfort switch must soften the
	# PRESENTATION on both axes without touching difficulty. Assert the visual
	# scales drop when it is on and restore when off; the audio half is
	# Audio.reduced_spikes, wired to the same toggle in the settings panel.
	var was_damp: bool = A11y.dampened_protocol
	A11y.dampened_protocol = false
	var reveal_off: float = A11y.hunter_reveal_scale()
	var glitch_off: float = A11y.glitch_proximity_ceiling()
	A11y.dampened_protocol = true
	var reveal_on: float = A11y.hunter_reveal_scale()
	var glitch_on: float = A11y.glitch_proximity_ceiling()
	A11y.dampened_protocol = was_damp
	if reveal_on < reveal_off and glitch_on < glitch_off and reveal_off == 1.0:
		print("[SelfTest] PASS  dampened protocol: reveal %.2f->%.2f, glitch ceil %.2f->%.2f (softer, not easier)" % [
			reveal_off, reveal_on, glitch_off, glitch_on])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  dampened protocol did not soften the presentation")

	# PT1 SAFETY LAW: the enemy hit flash cannot exceed 3 Hz.
	#
	# The impact feedback the playtest asked for brightens a creature that fills
	# the frame, and the breaker fires faster than the WCAG 2.3.1 ceiling allows a
	# thing to flash. The governor in `Antivirus.trigger_hurt_flash` is what makes
	# that safe, and this is the number that proves it — checked against the
	# WEAPON's own maximum rate, so a future cooldown change that outruns the cap
	# fails here rather than in a player's living room.
	var shots_hz: float = 1.0 / maxf(Balance.BREAKER_COOLDOWN, 0.0001)
	var flash_hz: float = minf(shots_hz, 1.0 / Antivirus.HURT_FLASH_MIN_INTERVAL)
	if flash_hz <= 3.0:
		print("[SelfTest] PASS  flash-rate HIT   : peak %.2f Hz <= 3.0 Hz (trigger %.2f Hz, capped)" % [
			flash_hz, shots_hz])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  flash-rate HIT: %.2f Hz exceeds the WCAG ceiling" % flash_hz)

	# PT1: a FRESH profile boots silent on both text tracks.
	#
	# The playtest complaint ("the hearing aid text should be off by default")
	# turned out to be true of a track nobody had a switch for, and a default that
	# is only written down in a comment is a default that drifts. This reads the
	# real load path with an empty config — i.e. exactly what a machine that has
	# never run the game gets — so the answer cannot be a claim about a screenshot.
	var fresh: Dictionary = A11y.fresh_defaults()
	if not bool(fresh["sound_captions"]) and not bool(fresh["subtitles"]):
		print("[SelfTest] PASS  fresh profile silent: captions=off subtitles=off")
	else:
		failures += 1
		printerr("[SelfTest] FAIL  fresh profile shows text: captions=%s subtitles=%s" % [
			str(fresh["sound_captions"]), str(fresh["subtitles"])])

	# PT1: the drop-shaft refill is a real refill and it cannot overfill the pool.
	# The arithmetic `RunState._siphon_shaft` does, checked at both ends: a pool at
	# a tenth gains the full half-pool, and a pool at nine tenths gains only the
	# tenth that fits. A refill that could exceed the maximum would silently break
	# every readout that divides by it.
	var pool_max: float = Balance.pool_max(4)
	var want: float = pool_max * Balance.DESCENT_REFILL_FRACTION
	var low_gain: float = minf(want, pool_max - pool_max * 0.1)
	var high_gain: float = minf(want, pool_max - pool_max * 0.9)
	if Balance.DESCENT_REFILL_FRACTION > 0.0 and Balance.DESCENT_REFILL_FRACTION < 1.0 \
			and is_equal_approx(low_gain, want) \
			and is_equal_approx(high_gain, pool_max * 0.1) \
			and pool_max * 0.1 + high_gain <= pool_max + 0.001:
		print("[SelfTest] PASS  descent refill: +%.0f from a tenth, +%.0f from nine tenths (clamped)" % [
			low_gain, high_gain])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  descent refill: low=%.2f high=%.2f max=%.2f" % [
			low_gain, high_gain, pool_max])

	failures += _vertical_selftest()
	failures += _cartography_selftest()
	failures += _hub_selftest()
	failures += _fidelity_selftest()
	failures += _subroutine_selftest()

	print("[SelfTest] %d check(s) failed" % failures)
	get_tree().quit(1 if failures > 0 else 0)


## Called by `Layer._rebuild` with the graph that peer just built. Writes it to
## `--dumplive`'s path when the instrument is armed, and does nothing at all when
## it is not — this is on the descent path, so it must cost a string compare.
##
## The file is written per layer with the layer number appended, so a soak that
## rides 1 -> 2 -> 3 leaves one dump per ring on each peer and the whole descent
## can be diffed rather than just its first room.
## `--pathwalk`: sweep a player-sized capsule along the ground route from every
## injection point to the drop shaft and report whether it gets there.
##
## The solo invariant says spawn -> drop shaft is walkable, alone, with no jump
## and no climb, on every seed. `LayerGraph.vertical_violations` asserts that as a
## property of the GRAPH; this asserts it against the COLLIDERS that were actually
## built, which is a different and stronger claim — a graph can be right about
## where a plinth is and the builder can still have put a stair collider across
## the aisle.
##
## Uses `cast_motion` rather than moving a body: it is exact (it returns the
## fraction of the sweep that was clear), it needs no physics ticks, and it cannot
## be fooled by a capsule tunnelling. Run one process per (seed, layer) and loop
## in a shell — the layer only builds once per process, by design.
const PATHWALK_RADIUS: float = 0.34
const PATHWALK_HEIGHT: float = 1.8
## Grid pitch for the walkability fill. One metre resolves a 3.2 m doorway into
## three clear cells and a 4 m corridor into four, which is plenty, and keeps a
## whole layer at roughly twenty thousand cells — a couple of seconds headless.
const PATHWALK_STEP: float = 1.0

func _run_path_walk() -> void:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null:
		printerr("[PathWalk] FAIL no layer")
		get_tree().quit(1)
		return
	var graph: LayerGraph = layer.get("graph") as LayerGraph
	if graph == null:
		printerr("[PathWalk] FAIL no graph")
		get_tree().quit(1)
		return

	var space: PhysicsDirectSpaceState3D = (layer as Node3D).get_world_3d().direct_space_state

	# --- the grid ------------------------------------------------------------
	var lo: Vector2 = Vector2(INF, INF)
	var hi: Vector2 = Vector2(-INF, -INF)
	for room: Dictionary in graph.rooms:
		var shell: Rect2 = LayerGraph._kit_rect(room["min"], room["max"])
		lo.x = minf(lo.x, shell.position.x)
		lo.y = minf(lo.y, shell.position.y)
		hi.x = maxf(hi.x, shell.end.x)
		hi.y = maxf(hi.y, shell.end.y)
	lo -= Vector2.ONE * PATHWALK_STEP * 2.0
	hi += Vector2.ONE * PATHWALK_STEP * 2.0
	var cols: int = int(ceil((hi.x - lo.x) / PATHWALK_STEP)) + 1
	var rows: int = int(ceil((hi.y - lo.y) / PATHWALK_STEP)) + 1

	var probe: CapsuleShape3D = CapsuleShape3D.new()
	# A hair under the avatar: this is a clearance test, and a probe fatter than
	# the body it stands for reports failures nobody can feel.
	probe.radius = PATHWALK_RADIUS - 0.04
	probe.height = PATHWALK_HEIGHT - 0.10
	var centre_y: float = PATHWALK_HEIGHT * 0.5 + 0.04

	var walkable: PackedByteArray = PackedByteArray()
	walkable.resize(cols * rows)
	var open_cells: int = 0
	for cz: int in rows:
		for cx: int in cols:
			var at: Vector3 = Vector3(lo.x + float(cx) * PATHWALK_STEP, centre_y,
					lo.y + float(cz) * PATHWALK_STEP)
			# 1. Is there room for a body here?
			var shape_query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
			shape_query.shape = probe
			shape_query.transform = Transform3D(Basis.IDENTITY, at)
			shape_query.collision_mask = 1
			if not space.intersect_shape(shape_query, 1).is_empty():
				continue
			# 2. Is there FLOOR under it, at grade? A ray that finds nothing is over
			#    a sunken pit or off the map; a ramp's slab is already caught by the
			#    capsule test above. So the fill is grade-only by construction, which
			#    is exactly the claim: spawn to shaft with no climb and no descent.
			var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
					at + Vector3(0.0, 0.2, 0.0), at - Vector3(0.0, centre_y + 0.35, 0.0))
			ray.collision_mask = 1
			if space.intersect_ray(ray).is_empty():
				continue
			walkable[cz * cols + cx] = 1
			open_cells += 1

	# --- flood fill from the shaft ------------------------------------------
	#
	# Filled from the DESTINATION once, rather than searched from each of the four
	# injection points in turn: one BFS answers all of them, and the distance field
	# it leaves behind is the walk length for free.
	var distance: PackedInt32Array = PackedInt32Array()
	distance.resize(cols * rows)
	distance.fill(-1)
	var goal: int = _nearest_open(walkable, cols, rows, lo, graph.shaft_point)
	if goal < 0:
		printerr("[PathWalk] FAIL seed=%d layer=%d: the drop shaft pad itself is not walkable" % [
			Rng.run_seed, graph.layer_number])
		get_tree().quit(1)
		return
	distance[goal] = 0
	var queue: PackedInt32Array = PackedInt32Array([goal])
	var head: int = 0
	while head < queue.size():
		var cell: int = queue[head]
		head += 1
		var cx: int = cell % cols
		var cz: int = cell / cols
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = cx + step.x
			var nz: int = cz + step.y
			if nx < 0 or nz < 0 or nx >= cols or nz >= rows:
				continue
			var next: int = nz * cols + nx
			if walkable[next] == 0 or distance[next] >= 0:
				continue
			distance[next] = distance[cell] + 1
			queue.append(next)

	# --- every injection point has to reach it -------------------------------
	var failures: int = 0
	var longest: float = 0.0
	for s: int in graph.spawns.size():
		var start: int = _nearest_open(walkable, cols, rows, lo, graph.spawns[s])
		if start < 0 or distance[start] < 0:
			failures += 1
			printerr("[PathWalk] FAIL seed=%d layer=%d spawn=%d at %s cannot reach the drop shaft at grade" % [
				Rng.run_seed, graph.layer_number, s,
				str(graph.spawns[s].snapped(Vector3.ONE * 0.1))])
			continue
		longest = maxf(longest, float(distance[start]) * PATHWALK_STEP)

	if failures == 0:
		print("[PathWalk] PASS seed=%d layer=%d: %d/%d injection points reach the shaft at grade, worst walk %.0f m (%.0f s), %d walkable cells, %d decks on the layer" % [
			Rng.run_seed, graph.layer_number, graph.spawns.size(), graph.spawns.size(),
			longest, longest / Player.WALK_SPEED, open_cells, graph.decks.size()])
	get_tree().quit(1 if failures > 0 else 0)


## Index of the nearest walkable cell to a world point, or -1 if nothing within a
## few metres is open. Spawn pads and the shaft pad are clear ground by
## construction, so the search radius only has to absorb grid phase.
func _nearest_open(walkable: PackedByteArray, cols: int, rows: int, lo: Vector2,
		point: Vector3) -> int:
	var best: int = -1
	var best_distance: float = INF
	var cx: int = int(round((point.x - lo.x) / PATHWALK_STEP))
	var cz: int = int(round((point.z - lo.y) / PATHWALK_STEP))
	var reach: int = int(ceil(4.0 / PATHWALK_STEP))
	for dz: int in range(-reach, reach + 1):
		for dx: int in range(-reach, reach + 1):
			var nx: int = cx + dx
			var nz: int = cz + dz
			if nx < 0 or nz < 0 or nx >= cols or nz >= rows:
				continue
			if walkable[nz * cols + nx] == 0:
				continue
			var to_cell: float = Vector2(float(dx), float(dz)).length()
			if to_cell < best_distance:
				best_distance = to_cell
				best = nz * cols + nx
	return best


## Stands the local avatar on the layer's vertical geometry. Returns false when
## this layer has nothing of the kind asked for, which is a legitimate roll rather
## than an error — a layer of small rooms genuinely has no mezzanine.
##
##   deck     the highest LOOT deck, looking out over the room it overhangs
##   perch    a perched data cache, looking down at it
##   catwalk  the middle of a span, looking along it
##   ledge    a drop-down lip, looking over the edge at what you would land on
##   below    the floor UNDER the highest deck, looking up through the grating
##   tall     the middle of the tallest room, looking up the hero shaft
func _vertical_goto(avatar: Player, where: String, index: int) -> bool:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	var graph: LayerGraph = layer.get("graph") as LayerGraph
	if graph == null:
		return false
	var lateral: float = 0.0 if index == 0 else (1.4 if index % 2 == 1 else -1.4)

	if where == "tall":
		var best_room: int = -1
		var best_height: float = 0.0
		for room: Dictionary in graph.rooms:
			if float(room["h"]) > best_height:
				best_height = float(room["h"])
				best_room = int(room["index"])
		if best_room < 0:
			return false
		var mid: Vector3 = graph.centre_of(best_room)
		# Backed off the middle rather than stood in it: the hero shaft drops on the
		# room's centre cell, and you cannot photograph a light shaft from inside it.
		avatar.teleport_to(mid + Vector3(lateral, 0.35, 7.0), 0.0, _pitch_for(0.62))
		print("[Debug] teleported to tallest room %d (h=%.1f) %s" % [
			best_room, best_height, str(mid)])
		return true

	if where == "pit":
		# At the LIP of a sunken nest, looking down into it. The one deck kind that
		# goes below grade, and the one whose whole point is what you cannot see
		# until you commit: standing here your sightline stops at the near edge, and
		# whatever lives in the sump is under it.
		var sump: int = -1
		for deck_any: Dictionary in graph.decks:
			if String(deck_any["kind"]) == LayerGraph.DECK_PIT:
				sump = int(deck_any["id"])
				break
		if sump < 0:
			return false
		var hole: Dictionary = graph.decks[sump]
		var pit_lo: Vector2 = hole["min"]
		var pit_hi: Vector2 = hole["max"]
		var pit_mid: Vector2 = (pit_lo + pit_hi) * 0.5
		var room_mid: Vector3 = graph.centre_of(int(hole["room"]))
		var outward: Vector2 = Vector2(room_mid.x, room_mid.z) - pit_mid
		if outward.length() < 0.5:
			outward = Vector2(0.0, 1.0)
		outward = outward.normalized()
		# Just outside the near edge, on grade, facing back across the hole.
		var half_span: float = maxf(absf(outward.x) * (pit_hi.x - pit_lo.x),
				absf(outward.y) * (pit_hi.y - pit_lo.y)) * 0.5
		var lip: Vector2 = pit_mid + outward * (half_span + 1.7)
		avatar.teleport_to(Vector3(lip.x, 0.35, lip.y),
				atan2(outward.x, outward.y), _pitch_for(-0.44))
		print("[Debug] teleported to the lip of a %.1f m pit in room %d" % [
			-float(hole["y"]), int(hole["room"])])
		return true

	if where == "stair":
		# At the FOOT of the longest flight on the layer, looking up it.
		#
		# This is the framing the other probes could not get. NULLVOID is a
		# near-black game: a wide shot of a gallery from across a machine hall is a
		# shot of nothing, because the only light is the beam and the beam is a cone
		# pointed where you look. Stood at the bottom of a stair, everything the
		# milestone is about — the flight, its railing, the deck it lands on and the
		# volume above — is inside that cone at once.
		var best: int = -1
		var best_rise: float = 0.0
		for i: int in graph.deck_links.size():
			var link: Dictionary = graph.deck_links[i]
			var rise: float = absf(float(link["y1"]) - float(link["y0"]))
			if rise > best_rise:
				best_rise = rise
				best = i
		if best < 0:
			return false
		var flight: Dictionary = graph.deck_links[best]
		var toe: Vector3 = flight["foot"]
		var crown: Vector3 = flight["head"]
		var up: Vector3 = crown - toe
		up.y = 0.0
		if up.length() < 0.5:
			return false
		up = up.normalized()
		# Stood BESIDE the bottom of the flight, not below it, looking diagonally up
		# the run.
		#
		# Two failed attempts got here. Backing straight off the foot walks through
		# the wall, because a stair is built inside a wall band and starts flush
		# against it. Clamping that back into the room is worse: it lands the camera
		# ON the flight — at 4.5 m up an 8 m run the treads are already 0.8 m high,
		# so the lens ends up inside the slab and photographs solid black. There is
		# no room below a stair that begins at a wall, so the shot has to come from
		# the side, which is the better three-quarter view anyway.
		var room_mid: Vector3 = graph.centre_of(int(flight["room"]))
		var flank: Vector3 = up.cross(Vector3.UP).normalized()
		if flank.dot(room_mid - toe) < 0.0:
			flank = -flank
		# Purely perpendicular, and level with the foot: any component back along the
		# run walks into the wall the flight starts at. Then clamped inside the
		# room, because the offset itself can overshoot a shallow room.
		var stand_at: Vector3 = toe + flank * 4.6
		var shell: Rect2 = LayerGraph._kit_rect(
				graph.rooms[int(flight["room"])]["min"],
				graph.rooms[int(flight["room"])]["max"])
		var inner: Rect2 = shell.grow(-2.0)
		stand_at.x = clampf(stand_at.x, inner.position.x, inner.end.x)
		stand_at.z = clampf(stand_at.z, inner.position.y, inner.end.y)
		var aim: Vector3 = (toe + crown) * 0.5 - stand_at
		avatar.teleport_to(Vector3(stand_at.x, 0.35, stand_at.z),
				atan2(-aim.x, -aim.z), _pitch_for(0.10))
		print("[Debug] teleported to the foot of a %.1f m %s in room %d" % [
			best_rise, String(flight["kind"]), int(flight["room"])])
		return true

	if where == "perch":
		if graph.perch_points.is_empty():
			return false
		var perch: Vector3 = graph.perch_points[index % graph.perch_points.size()]
		var deck: Dictionary = graph.decks[graph.perch_decks[index % graph.perch_decks.size()]]
		var toward: Vector2 = (Vector2(deck["min"]) + Vector2(deck["max"])) * 0.5 \
				- Vector2(perch.x, perch.z)
		var back: Vector2 = -toward.normalized() * 2.6 if toward.length() > 0.01 \
				else Vector2(0.0, 2.6)
		avatar.teleport_to(perch + Vector3(back.x, 0.35, back.y),
				atan2(-(-back.x), -(-back.y)), _pitch_for(-0.34))
		print("[Debug] teleported to perch %s on a %s deck" % [
			str(perch), String(deck["kind"])])
		return true

	# The remaining three all want a particular deck, so pick one once.
	var wanted: int = -1
	var best_score: float = -1.0
	for deck: Dictionary in graph.decks:
		var kind: String = String(deck["kind"])
		if where == "catwalk" and kind != LayerGraph.DECK_CATWALK:
			continue
		if where != "catwalk" and bool(deck["solid"]):
			continue
		var score: float = float(deck["y"])
		if where == "deck" and bool(deck["loot"]):
			score += 10.0
		if score > best_score:
			best_score = score
			wanted = int(deck["id"])
	if wanted < 0 and where != "ledge":
		return false

	if where == "ledge":
		if graph.deck_drops.is_empty():
			return false
		var drop: Dictionary = graph.deck_drops[index % graph.deck_drops.size()]
		var at: Vector3 = drop["at"]
		var dir: Vector3 = drop["dir"]
		# Stood one step back from the lip, facing out over it and looking down —
		# the exact frame the player gets when they decide whether to take it.
		avatar.teleport_to(at - dir * 1.5 + Vector3(0.0, 0.35, 0.0),
				atan2(-dir.x, -dir.z), _pitch_for(-0.58))
		print("[Debug] teleported to a %.1f m ledge %s" % [float(drop["height"]), str(at)])
		return true

	var deck: Dictionary = graph.decks[wanted]
	var lo: Vector2 = deck["min"]
	var hi: Vector2 = deck["max"]
	var centre: Vector2 = (lo + hi) * 0.5
	var y: float = float(deck["y"])
	var long_x: bool = (hi.x - lo.x) >= (hi.y - lo.y)

	if where == "below":
		# On the GROUND FLOOR, backed off into the room and looking up at the deck.
		#
		# Not directly underneath it: standing under a gallery frames the underside
		# of one slab, which is a dark rectangle and proves nothing. Stood back
		# across the floor you get the shot that actually matters — the machine floor
		# still running clear beneath a walkway at head height, which is the whole
		# reason an elevated deck is allowed to ignore the doorway aisles.
		var room_mid: Vector3 = graph.centre_of(int(deck["room"]))
		var toward: Vector2 = Vector2(room_mid.x, room_mid.z) - centre
		if toward.length() < 0.5:
			toward = Vector2(0.0, 1.0)
		var stand: Vector2 = centre + toward.normalized() * 7.0
		avatar.teleport_to(Vector3(stand.x + lateral, 0.35, stand.y),
				atan2(toward.normalized().x, toward.normalized().y), _pitch_for(0.30))
		print("[Debug] teleported to the floor under the %s deck, looking back at it %s" % [
			String(deck["kind"]), str(centre)])
		return true

	# `deck` and `catwalk`: stand on it, at one end, looking along its length.
	var along: Vector2 = Vector2(1.0, 0.0) if long_x else Vector2(0.0, 1.0)
	var start: Vector2 = centre - along * (((hi.x - lo.x) if long_x else (hi.y - lo.y)) * 0.5 - 1.6)
	avatar.teleport_to(Vector3(start.x, y + 0.35, start.y),
			atan2(-along.x, -along.y), _pitch_for(-0.08))
	print("[Debug] teleported onto a %s deck at y=%.1f %s" % [
		String(deck["kind"]), y, str(start)])
	return true


func note_built_layer(graph: LayerGraph) -> void:
	if dump_live_path.is_empty() or graph == null:
		return
	var path: String = "%s.%d.txt" % [dump_live_path, graph.layer_number]
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[Debug] --dumplive could not write %s" % path)
		return
	file.store_string(graph.to_text())
	file.close()
	print("[Debug] --dumplive wrote %s" % path)


## Arms the `--pathwalk` sweep. Deliberately on a timer rather than deferred: this
## is called from inside `Layer._rebuild`, and the colliders it is about to test
## do not exist until `add_child(_builder)` a few lines further down.
func arm_path_walk() -> void:
	if not _pathwalk and not _auditvert:
		return
	await get_tree().create_timer(1.5).timeout
	if _auditvert:
		_run_vertical_audit()
		return
	_run_path_walk()


## `--auditvert`: placement quality for every vertical element on the layer.
##
## The flood fill proved the crew can WALK the layer. This asks a different and
## much pickier question: does the vertical vocabulary sit correctly in the world
## it was dropped into? A stair whose first tread is jammed against a facing wall,
## a railing running through a server rack, a plinth with a crate half inside it —
## none of those stop anyone reaching the drop shaft, and all of them look broken.
##
## Works off the SCENE, not off the graph. Every vertical mesh is tagged `Vert_*`
## at build time and the dressing already groups itself under `DataBlock`,
## `DataRack` and `Crates`; the audit takes world-space AABBs off the real nodes,
## so it sees where geometry actually ENDED UP rather than where the generator
## meant to put it. Overlaps are tested with a tolerance, because a deck flush
## against the wall it hangs off is correct and only a real interpenetration is a
## finding.
##
## Findings are grouped into classes so the fix is a placement RULE and not a
## per-seed patch — a class with one instance is usually bad luck, a class with
## forty is a rule that was never written.
const AUDIT_TOLERANCE: float = 0.06
## Clear grade a flight's foot needs in front of its first tread. A stair flush
## ALONG a wall is correct architecture; a stair flush INTO one is the bug the
## live playtest reported.
const AUDIT_APPROACH: float = 1.5
## What counts as a solid the vertical vocabulary must not interpenetrate. Node
## name stems, matched after the `@Name@2` sigil Godot gives duplicate siblings.
const AUDIT_SOLID_NAMES: Array[String] = [
	"DataBlock", "DataRack", "Crates", "DataShard", "DebrisBody",
	"RewireJunction", "WeldVent", "LootCabinet", "CommandTerminal",
	"SiphonTap", "CompilerTerminal", "BackdoorNode", "ExfilUplink",
	"PILLAR_CONDUIT_HERO", "RIB_COLUMN",
]

func _run_vertical_audit() -> void:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	if layer == null:
		printerr("[VertAudit] FAIL no layer")
		get_tree().quit(1)
		return
	var graph: LayerGraph = layer.get("graph") as LayerGraph
	var builder: Node = layer.get_node_or_null("ProcLayerBuilder")
	if graph == null or builder == null:
		printerr("[VertAudit] FAIL no graph or builder")
		get_tree().quit(1)
		return

	var vertical: Array[Dictionary] = []
	var solids: Array[Dictionary] = []
	var census: Dictionary = {}
	_collect_audit_nodes(builder, vertical, solids, census)
	if log_ai:
		var seen: Array = census.keys()
		seen.sort()
		for n: String in seen:
			print("[VertAudit]   node %-24s %4d" % [n, int(census[n])])

	var findings: Dictionary = {}
	var worst: Array[Dictionary] = []

	# --- 1. vertical element vs solid dressing -------------------------------
	for v: Dictionary in vertical:
		var va: AABB = v["aabb"]
		for o: Dictionary in solids:
			var oa: AABB = o["aabb"]
			var hit: AABB = va.intersection(oa)
			if not va.intersects(oa):
				continue
			# Shrink both by the tolerance before believing it: touching is not
			# clipping, and a deck laid against a wall touches by design.
			var depth: float = minf(minf(hit.size.x, hit.size.y), hit.size.z)
			if depth <= AUDIT_TOLERANCE:
				continue
			var label: String = "%s x %s" % [String(v["kind"]), String(o["kind"])]
			findings[label] = int(findings.get(label, 0)) + 1
			worst.append({"label": label, "depth": depth,
					"at": hit.position + hit.size * 0.5})

	# --- 2. stair-foot approach ----------------------------------------------
	for link: Dictionary in graph.deck_links:
		if String(link["kind"]) == LayerGraph.LINK_CATWALK:
			continue
		var problem: String = _foot_approach_problem(graph, link)
		if problem.is_empty():
			continue
		findings[problem] = int(findings.get(problem, 0)) + 1
		worst.append({"label": problem, "depth": 0.0, "at": Vector3(link["foot"])})

	# --- report ---------------------------------------------------------------
	var total: int = 0
	for label: String in findings:
		total += int(findings[label])
	var classes: Array = findings.keys()
	classes.sort()
	print("[VertAudit] seed=%d layer=%d elements=%d solids=%d decks=%d routes=%d findings=%d" % [
		Rng.run_seed, graph.layer_number, vertical.size(), solids.size(),
		graph.decks.size(), graph.deck_links.size(), total])
	for label: String in classes:
		print("[VertAudit]   %-34s %4d" % [label, int(findings[label])])
	worst.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["depth"]) > float(b["depth"]))
	for i: int in mini(worst.size(), 3):
		print("[VertAudit]   worst%d %s depth=%.2fm at %s" % [
			i, String(worst[i]["label"]), float(worst[i]["depth"]),
			str((worst[i]["at"] as Vector3).snapped(Vector3.ONE * 0.1))])
	get_tree().quit(0)


## Walks the built layer collecting world-space AABBs for both sides of the test.
func _collect_audit_nodes(node: Node, vertical: Array[Dictionary],
		solids: Array[Dictionary], census: Dictionary) -> void:
	# Godot names the SECOND and later siblings that share a name `@DataBlock@2`,
	# not `DataBlock2` — a leading sigil, not a trailing digit. Matching on
	# `begins_with("DataBlock")` therefore found exactly one of every group on the
	# layer and silently under-reported the audit by two orders of magnitude. Strip
	# the sigil first, then take the stem.
	var name: String = String(node.name).trim_prefix("@").split("@")[0]
	var stem: String = name.rstrip("0123456789")
	census[stem] = int(census.get(stem, 0)) + 1
	if name.begins_with("Vert_"):
		var mesh: MeshInstance3D = node as MeshInstance3D
		if mesh != null:
			vertical.append({"kind": stem,
					"aabb": mesh.global_transform * mesh.get_aabb()})
		return
	# Everything a deck, ramp or railing could bury, clip or make unusable.
	#
	# Not just the big dressing: a chip inside a plinth is loot nobody can pick up,
	# and a vent behind a stair is a mechanic the breaker cannot reach. The kit's
	# own standing furniture (hero pillars, rib columns) is in here too, because a
	# catwalk through a column reads worse than a catwalk through a crate.
	if stem in AUDIT_SOLID_NAMES:
		var box: AABB = AABB()
		var leaf: MeshInstance3D = node as MeshInstance3D
		if leaf != null:
			box = leaf.global_transform * leaf.get_aabb()
		else:
			box = _merged_aabb(node as Node3D)
		if box.size.length() > 0.01:
			solids.append({"kind": stem, "aabb": box})
		return
	for child: Node in node.get_children():
		_collect_audit_nodes(child, vertical, solids, census)


func _merged_aabb(root: Node3D) -> AABB:
	var out: AABB = AABB()
	var first: bool = true
	for child: Node in root.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh == null:
			continue
		var box: AABB = mesh.global_transform * mesh.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out


## Does this flight's foot have somewhere to stand? Returns "" when it is fine.
##
## Pure graph maths rather than a physics probe, so the same rule can be enforced
## at generation time (`LayerGraph._split_band`) and asserted in the selftest. The
## approach box sits in front of the first tread, in the direction a body walks
## in from; if it leaves the room's snapped shell, the flight is footed into a
## wall.
func _foot_approach_problem(graph: LayerGraph, link: Dictionary) -> String:
	var foot: Vector3 = link["foot"]
	var head: Vector3 = link["head"]
	var up: Vector3 = Vector3(head.x - foot.x, 0.0, head.z - foot.z)
	if up.length() < 0.01:
		return ""
	up = up.normalized()
	var shell: Rect2 = LayerGraph._kit_rect(
			graph.rooms[int(link["room"])]["min"],
			graph.rooms[int(link["room"])]["max"])
	# One body-width in front of the first tread, plus the clearance.
	var probe: Vector2 = Vector2(foot.x, foot.z) - Vector2(up.x, up.z) * AUDIT_APPROACH
	if shell.has_point(probe):
		return ""
	return "stair foot into wall (no %.1fm approach)" % AUDIT_APPROACH


# --------------------------------------------------------- M6.6 verticality --

## Seeds and depths the verticality checks are run over. Wide enough to hit
## shallow, mid, deep and backdoor layers with several room-count and room-shape
## draws each; small enough that `--selftest` still finishes in a couple of
## seconds, because a gate nobody runs is not a gate.
## Plain typed arrays, not Packed*Array: `PackedInt64Array(...)` is a constructor
## CALL, and GDScript only accepts constant expressions in a `const` — declaring
## them that way fails to parse the whole script, which takes the autoloads with
## it and every other tool in the repo with them.
const _VERT_SEEDS: Array[int] = [12345, 777, 4242, 99, 31337, 8675309]
const _VERT_LAYERS: Array[int] = [1, 3, 5, 7, 10, 12, 15, 21]

## The three verticality laws, asserted over that matrix. Returns the failure
## count.
##
## This is the check the M6.6 pass exists to be gated on. It is a pure-data test —
## no scene, no physics, no rendering — because every one of the laws is a
## statement about the GRAPH, and a statement about the graph is exactly the thing
## a headless CI job can hold on to.
func _vertical_selftest() -> int:
	var failures: int = 0
	var layers: int = 0
	var decks: int = 0
	var perches: int = 0
	var drops: int = 0
	var flat_layers: int = 0
	var worst: PackedStringArray = PackedStringArray()

	for seed_value: int in _VERT_SEEDS:
		for layer: int in _VERT_LAYERS:
			var graph: LayerGraph = LayerGraph.generate(seed_value, layer)
			layers += 1
			decks += graph.decks.size()
			perches += graph.perch_points.size()
			drops += graph.deck_drops.size()
			if graph.decks.is_empty():
				flat_layers += 1
			for problem: String in graph.vertical_violations():
				if worst.size() < 6:
					worst.append("seed %d layer %d: %s" % [seed_value, layer, problem])
				failures += 1

	if failures == 0:
		print("[SelfTest] PASS  verticality: %d layers, %d decks, %d routes-to-grade all reachable, %d perches, %d ledges" % [
			layers, decks, decks, perches, drops])
	else:
		for line: String in worst:
			printerr("[SelfTest] FAIL  verticality %s" % line)

	# Coverage, as a number rather than as an impression. "The layers read flat"
	# was the complaint this pass answers, so "how many layers still read flat"
	# has to be something the build can print about itself. A layer with no deck
	# at all is allowed (a run of small rooms is a legitimate roll) but it must be
	# the exception, not the shape of the game.
	var flat_fraction: float = float(flat_layers) / float(maxi(layers, 1))
	if flat_fraction <= 0.15:
		print("[SelfTest] PASS  vertical coverage: %.1f%% of layers wholly flat (<= 15%%), %.1f decks/layer" % [
			flat_fraction * 100.0, float(decks) / float(maxi(layers, 1))])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  vertical coverage: %.1f%% of layers have no elevation at all" % [
			flat_fraction * 100.0])

	# The landing ladder. These are movement-feel constants rather than balance
	# ones, and the property that has to hold is that they stay ORDERED against
	# the deck heights the generator actually authors: a one-storey drop must be
	# loud and free, a two-storey drop must be loud and expensive, and neither may
	# corrupt a healthy agent outright.
	var gravity: float = 9.8
	var one_storey: float = sqrt(2.0 * gravity * LayerGraph.Y_MEZZANINE)
	var two_storey: float = sqrt(2.0 * gravity * LayerGraph.Y_MEZZANINE * 2.0)
	var terrace: float = sqrt(2.0 * gravity * LayerGraph.Y_TERRACE)
	var two_cost: float = Player.LAND_HURT_MIN \
			+ (two_storey - Player.LAND_HURT_SPEED) * Player.LAND_HURT_PER_SPEED
	if terrace < Player.LAND_NOISE_SPEED \
			and one_storey >= Player.LAND_LOUD_SPEED \
			and one_storey < Player.LAND_HURT_SPEED \
			and two_storey >= Player.LAND_HURT_SPEED \
			and two_cost < Balance.INTEGRITY_MAX * 0.5:
		print("[SelfTest] PASS  drop ladder: %.1f m silent, %.1f m loud+free, %.1f m loud+%.0f integrity (< half a bar)" % [
			LayerGraph.Y_TERRACE, LayerGraph.Y_MEZZANINE, LayerGraph.Y_MEZZANINE * 2.0,
			two_cost])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  drop ladder out of order: terrace %.2f, storey %.2f, two %.2f m/s vs noise %.2f loud %.2f hurt %.2f" % [
			terrace, one_storey, two_storey, Player.LAND_NOISE_SPEED,
			Player.LAND_LOUD_SPEED, Player.LAND_HURT_SPEED])

	# The Moth has to actually USE a tall room. It is the one process that can, and
	# before M6.6 it hovered at a fixed 1.7 m — so a twelve-metre trunk room was a
	# twelve-metre trunk room with a creature bumbling around its ankles. The patrol
	# curve is a pure function precisely so this can be asserted rather than
	# photographed: sample it densely in a deep room and a shallow one and check it
	# fills the volume it is given, leans upward, and never exceeds its headroom.
	var tall_room: float = LayerGraph.KIT_STOREY * 3.0 - 1.2   # the trunk room
	var flat_room: float = LayerGraph.KIT_STOREY - 1.2         # an ordinary hall
	var samples: int = 400
	var tall_hi: float = 0.0
	var tall_sum: float = 0.0
	var flat_hi: float = 0.0
	for i: int in samples:
		var t: float = float(i) / float(samples - 1)
		var tall_y: float = Moth.patrol_altitude(t, tall_room)
		tall_hi = maxf(tall_hi, tall_y)
		tall_sum += tall_y
		flat_hi = maxf(flat_hi, Moth.patrol_altitude(t, flat_room))
	var tall_mean: float = tall_sum / float(samples)
	if tall_hi >= tall_room - 0.01 and tall_hi <= tall_room + 0.01 \
			and flat_hi <= flat_room + 0.01 \
			and tall_mean > tall_room * 0.5 \
			and tall_mean > Moth.HOVER_HEIGHT * 2.0:
		print("[SelfTest] PASS  moth altitude: %.1f m room -> patrols %.1f-%.1f m (mean %.1f, upper half); %.1f m room capped at %.1f" % [
			tall_room, Moth.HOVER_HEIGHT, tall_hi, tall_mean, flat_room, flat_hi])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  moth altitude: tall max %.2f (want %.2f), mean %.2f, flat max %.2f (want <= %.2f)" % [
			tall_hi, tall_room, tall_mean, flat_hi, flat_room])

	# Every authored slope has to be walkable by the widest, heaviest thing in the
	# game as well as by the player — the killability law says a perch a player can
	# reach is a perch a Sentinel can reach, and a 27 degree ramp it cannot climb
	# would break that quietly.
	var steepest: float = rad_to_deg(atan2(LayerGraph.Y_MEZZANINE, LayerGraph.STAIR_RUN))
	if steepest < 40.0 and LayerGraph.DECK_WIDTH >= 3.0:
		print("[SelfTest] PASS  slope walkable: steepest authored run %.1f deg (< 40), %.1f m wide" % [
			steepest, LayerGraph.DECK_WIDTH])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  slope %.1f deg / %.1f m wide is not walkable by every body" % [
			steepest, LayerGraph.DECK_WIDTH])

	return failures


## Densely samples a `FlickerLight` curve and reports the fastest flash rate in it
## and the largest flash amplitude. A "flash" is a rise of at least the WCAG
## general-flash floor (0.10 relative luminance) followed by a fall; the peak Hz is
## the reciprocal of the smallest gap between two such peaks. Pure maths, no
## rendering — reproducible and CI-able. A11y.flash_scale is at its default 1.0 in
## a selftest run, so this is the unconditional (Reduced-Flashing-OFF) worst case.
const _FLASH_SAMPLE_HZ: float = 600.0
const _FLASH_WINDOW_S: float = 20.0
const _FLASH_AMP: float = 0.10

func _measure_flash_hz(mode: int) -> Dictionary:
	var n: int = int(_FLASH_SAMPLE_HZ * _FLASH_WINDOW_S)
	var dt: float = 1.0 / _FLASH_SAMPLE_HZ
	var prev: float = FlickerLight.level(mode, 0.0, 0.0)
	var rising: bool = false
	var last_trough: float = prev
	var last_peak_t: float = -1.0
	var min_gap: float = INF
	var max_amp: float = 0.0
	for i: int in range(1, n):
		var t: float = float(i) * dt
		var v: float = FlickerLight.level(mode, t, 0.0)
		if v > prev + 0.00001:
			if not rising:
				last_trough = prev  # direction turned up: prev was a trough
			rising = true
		elif v < prev - 0.00001:
			if rising:
				# direction turned down: prev was a peak. Count it if the climb from
				# the last trough cleared the flash floor.
				var amp: float = prev - last_trough
				if amp >= _FLASH_AMP:
					max_amp = maxf(max_amp, amp)
					if last_peak_t >= 0.0:
						min_gap = minf(min_gap, t - last_peak_t)
					last_peak_t = t
			rising = false
		prev = v
	return {"peak_hz": 0.0 if is_inf(min_gap) else 1.0 / min_gap, "max_amp": max_amp}


# ----------------------------------------------------------------- tailprobe --

## `--tailprobe WHICH` (sentinel|crew). Stages ONE creature on a bare lit floor,
## side-on, and lets its M4.9 spring tail settle before saving `--screenshot PATH`.
## The one shot that proves the resting SAG — a heavy downward curve, tip below the
## root — rather than the rig's horizontal bind pose. A permanent dev tool for
## tuning the tail; it boots through the normal path, so autoloads are live.
func _run_tail_probe() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	# Replace the menu that auto-loaded with a bare stage.
	var current: Node = get_tree().current_scene
	if current != null:
		current.queue_free()
	await get_tree().process_frame

	var root: Window = get_tree().root
	root.size = Vector2i(1280, 720)

	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.015, 0.02, 0.03)
	e.ambient_light_color = Color(0.35, 0.4, 0.5)
	e.ambient_light_energy = 0.5
	env.environment = e
	root.add_child(env)
	var key: DirectionalLight3D = DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38.0, 52.0, 0.0)
	key.light_energy = 1.6
	root.add_child(key)
	var rim: OmniLight3D = OmniLight3D.new()
	rim.position = Vector3(-2.6, 2.2, -2.2)
	rim.light_energy = 7.0
	rim.omni_range = 15.0
	rim.light_color = Color(0.55, 0.72, 1.0)
	root.add_child(rim)
	# A collision floor on the world layer so a physics-driven creature stands on it
	# instead of free-falling through a purely visual plane.
	var floor_body: StaticBody3D = StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	root.add_child(floor_body)
	var floor_col: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(16.0, 0.4, 16.0)
	floor_col.shape = box
	floor_col.position = Vector3(0.0, -0.2, 0.0)
	floor_body.add_child(floor_col)
	var floor_mesh: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(16.0, 16.0)
	floor_mesh.mesh = plane
	var fm: StandardMaterial3D = StandardMaterial3D.new()
	fm.albedo_color = Color(0.05, 0.06, 0.08)
	floor_mesh.material_override = fm
	floor_body.add_child(floor_mesh)

	var creature: Node3D = null
	if _tail_which == "crew":
		var crew: CrewAvatar = CrewAvatar.create(GameState.local_color)
		root.add_child(crew)
		creature = crew
	else:
		var graph: LayerGraph = LayerGraph.generate(12345, 8)
		var sent: Sentinel = Sentinel.new()
		root.add_child(sent)
		sent.setup(0, Vector3.ZERO, 0, 20, graph)
		# Leave _process ON: the head-track dirties the skeleton each frame, which is
		# what makes the SkeletonModifier (the tail spring) re-run. In-game the AI and
		# the crew's AnimationTree do this every frame; a frozen skeleton does not.
		creature = sent
	creature.position = Vector3.ZERO

	var cam: Camera3D = Camera3D.new()
	root.add_child(cam)
	# Side-on and a touch behind, aimed at the hips where the tail roots — the one
	# framing that can actually judge a sag.
	cam.position = Vector3(2.7, 1.35, -1.9)
	cam.look_at(Vector3(0.0, 1.0, -0.25))
	cam.current = true
	print("[Debug] tailprobe staged '%s'" % _tail_which)

	# Let the spring settle to its resting droop, sampling the tip as it goes so an
	# over-damped slow settle can be told from a structurally-stuck bind pose.
	var skel: Skeleton3D = CreatureKit.find_skeleton(creature)
	var tip: int = -1 if skel == null else skel.find_bone("Tail5")
	var root_b: int = -1 if skel == null else skel.find_bone("Tail_Rt")
	if skel != null:
		print("[Debug] tail driver=%s" % (skel.get_node_or_null("TailDriver") != null))
	for t: float in [0.5, 2.0, 4.0, 6.0]:
		await get_tree().create_timer(t if t == 0.5 else t - _last_probe_t).timeout
		_last_probe_t = t
		if skel != null and tip >= 0 and root_b >= 0:
			var ty: float = (skel.global_transform * skel.get_bone_global_pose(tip)).origin.y
			var ry: float = (skel.global_transform * skel.get_bone_global_pose(root_b)).origin.y
			print("[Debug] tailprobe t=%.1fs  Tail5.y=%.3f  drop_below_root=%.3f" % [
				t, ty, ry - ty])
	if skel != null:
		var sim: Node = skel.get_node_or_null("TailSpring")
		print("[Debug] tailprobe sim=%s active=%s" % [
			sim != null, "n/a" if sim == null else str(sim.get("active"))])
		for bn: String in ["Tail_Rt", "Tail1", "Tail3", "Tail5"]:
			var bi: int = skel.find_bone(bn)
			if bi >= 0:
				var gp: Vector3 = (skel.global_transform * skel.get_bone_global_pose(bi)).origin
				print("[Debug]   %-8s worldY=%.3f  pos=%s" % [
					bn, gp.y, str(gp.snapped(Vector3.ONE * 0.01))])
	RenderingServer.force_draw()
	var img: Image = root.get_texture().get_image()
	var path: String = screenshot_path if not screenshot_path.is_empty() \
			else "user://tailprobe.png"
	img.save_png(path)
	print("[Debug] tailprobe saved %s" % path)
	get_tree().quit(0)


# --------------------------------------------------------------- hunterprobe --

## `--hunterprobe <hound|moth|auditor>`: one hunter on a lit floor, facing the
## camera, its AI frozen on its idle so it holds a clean portrait pose. The near-
## black + red-emissive enemy palette reads against a dark backdrop. Boots through
## the normal path so autoloads are live; pair with `--screenshot PATH`.
func _run_hunter_probe() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var current: Node = get_tree().current_scene
	if current != null:
		current.queue_free()
	await get_tree().process_frame

	var root: Window = get_tree().root
	root.size = Vector2i(1280, 720)

	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_COLOR
	# Near-black, like a real layer — the enemy palette is meant to be a hole in the
	# room that the red emissive burns out of, so the backdrop must be dark.
	e.background_color = Color(0.006, 0.008, 0.012)
	e.ambient_light_color = Color(0.10, 0.13, 0.20)
	# Kept low so the void stays a void (the darkness law) and the red emissive is
	# what carries the read, exactly as in a real layer.
	e.ambient_light_energy = 0.12
	env.environment = e
	root.add_child(env)
	# A cool key from the side (a crewmate's beam would be), so the shell is lit but
	# the red emissive still leads — never a flat studio wash.
	var key: SpotLight3D = SpotLight3D.new()
	key.position = Vector3(2.4, 2.6, 3.2)
	key.look_at_from_position(key.position, Vector3(0.0, 1.0, 0.0), Vector3.UP)
	key.light_energy = 6.0
	key.light_color = Color(0.7, 0.82, 1.0)
	key.spot_range = 16.0
	key.spot_angle = 40.0
	root.add_child(key)

	var floor_body: StaticBody3D = StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	root.add_child(floor_body)
	var floor_col: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(16.0, 0.4, 16.0)
	floor_col.shape = box
	floor_col.position = Vector3(0.0, -0.2, 0.0)
	floor_body.add_child(floor_col)
	var floor_mesh: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(16.0, 16.0)
	floor_mesh.mesh = plane
	var fm: StandardMaterial3D = StandardMaterial3D.new()
	fm.albedo_color = Color(0.03, 0.035, 0.05)
	fm.metallic = 0.2
	fm.roughness = 0.4
	floor_mesh.material_override = fm
	floor_body.add_child(floor_mesh)

	var graph: LayerGraph = LayerGraph.generate(12345, 16)
	var hunter: Hunter = null
	var idle: String = "idle"
	var look_y: float = 1.0
	var cam_pos: Vector3 = Vector3(0.0, 1.5, 4.2)
	match _hunter_which:
		"moth":
			hunter = Moth.new()
			idle = "drift"
			look_y = 1.7
			cam_pos = Vector3(0.0, 1.7, 3.4)
		"auditor":
			hunter = Auditor.new()
			idle = "inspect"
			look_y = 1.2
			cam_pos = Vector3(0.0, 1.4, 4.8)
		_:
			hunter = Hound.new()
			idle = "prowl"
			look_y = 0.7
			cam_pos = Vector3(0.0, 1.1, 3.8)
	root.add_child(hunter)
	hunter.setup(0, Vector3.ZERO, 0, 16, graph)
	# Freeze the sim so it holds still for the portrait; keep _process (animation +
	# emissive breathing) running so it is not a dead mannequin.
	hunter.set_physics_process(false)
	# Point it a touch off-camera so the silhouette reads as three-quarter, not a
	# mugshot, then settle its AnimationTree onto the idle clip.
	hunter.rotation.y = deg_to_rad(28.0)
	await get_tree().process_frame
	var tree: AnimationTree = hunter.find_child("AnimTree", true, false) as AnimationTree
	if tree != null:
		CreatureKit.travel(tree, idle)
		CreatureKit.set_speed(tree, 1.0)

	var cam: Camera3D = Camera3D.new()
	root.add_child(cam)
	cam.position = cam_pos
	cam.look_at(Vector3(0.0, look_y, 0.0))
	cam.current = true
	print("[Debug] hunterprobe staged '%s'" % _hunter_which)

	# Let the emissive breathe settle and the animation reach its idle.
	await get_tree().create_timer(1.6).timeout
	RenderingServer.force_draw()
	var img: Image = root.get_texture().get_image()
	var path: String = screenshot_path if not screenshot_path.is_empty() \
			else "user://hunterprobe.png"
	img.save_png(path)
	print("[Debug] hunterprobe saved %s" % path)
	get_tree().quit(0)


# ----------------------------------------------------------------- walkprobe --

## The contact (foot) bones whose stance the skate measure watches, per creature,
## and the gait state each is driven in. This is the ground truth the mission "No
## More Sliding" is checked against: a planted foot has zero world velocity while
## the body passes over it.
const _WALK_RIGS: Dictionary = {
	"crew":      {"state": "walk", "contacts": ["Left toe", "Right toe"]},
	"crew_run":  {"state": "run",  "contacts": ["Left toe", "Right toe"]},
	"sentinel":  {"state": "walk", "contacts": ["Left toe", "Right toe"]},
	"scrubber":  {"state": "skitter", "contacts":
			["leg_fL_lo", "leg_fR_lo", "leg_mL_lo", "leg_mR_lo", "leg_rL_lo", "leg_rR_lo"]},
	"hound":     {"state": "chase", "contacts":
			["leg_rL_ft", "leg_rR_ft", "leg_fL_ft", "leg_fR_ft"]},
	"auditor":   {"state": "walk", "contacts": ["legL_ft", "legR_ft"]},
	"moth":      {"state": "drift", "contacts": []},
}


## `--walkprobe WHICH [speed]`. Stages ONE ground creature side-on and answers the
## only question the no-skate mission cares about: do its feet stay planted on the
## world while it moves at its real speed?
##
## Two instruments, both from the SAME manual `AnimationTree.advance()` the game's
## speed-match drives, so what this measures is what ships:
##
##   * NUMERIC. With the body held still and the clip played at scale 1, a planted
##     foot slides backward through the world at exactly the clip's authored stance
##     speed — that speed IS the no-skate stride constant, measured off the clip
##     rather than guessed. From it and the coded stride this prints the residual
##     skate in mm/frame at the creature's real move speed (mean + worst), and the
##     stride that would zero the net drift. v-independent by construction.
##
##   * VISUAL. The body then translates forward at its real speed under a FIXED
##     side camera with world-fixed floor reference stripes, and six frames across
##     one step are stacked into a filmstrip: a planted foot sits glued to one
##     stripe row after row while the body slides over it; a skating foot walks
##     along the stripes. Saved to `--screenshot PATH`.
##
## Permanent instrument; boots through the normal path so autoloads are live.
func _run_walk_probe() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var current: Node = get_tree().current_scene
	if current != null:
		current.queue_free()
	# Hush any persistent HUD/caption layers (autoloads, nested) so the diagnostic
	# frame is just the creature, the floor and the reference stripes.
	_hush_overlays(get_tree().root)
	await get_tree().process_frame

	if not _WALK_RIGS.has(_walk_which):
		printerr("[walkprobe] unknown creature '%s'; try %s" % [
			_walk_which, str(_WALK_RIGS.keys())])
		get_tree().quit(1)
		return
	var rig: Dictionary = _WALK_RIGS[_walk_which]

	var root: Window = get_tree().root
	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.025, 0.035)
	# Brighter than a real layer on purpose: the near-black enemy palette has to be
	# legible in a diagnostic, and this stage is not the darkness law's jurisdiction.
	e.ambient_light_color = Color(0.34, 0.40, 0.50)
	e.ambient_light_energy = 0.85
	env.environment = e
	root.add_child(env)
	var key: DirectionalLight3D = DirectionalLight3D.new()
	# From behind-and-above the camera so the near leg is lit and the feet cast a
	# short contact shadow — the shadow is half the read on a plant.
	key.rotation_degrees = Vector3(-42.0, 24.0, 0.0)
	key.light_energy = 2.6
	key.shadow_enabled = true
	root.add_child(key)
	# A cool fill from the camera's +X side so a dark shell is not a silhouette.
	var fill: OmniLight3D = OmniLight3D.new()
	fill.position = Vector3(4.0, 2.0, 1.5)
	fill.light_energy = 4.0
	fill.omni_range = 14.0
	fill.light_color = Color(0.7, 0.82, 1.0)
	root.add_child(fill)

	# Floor + world-fixed reference stripes every 0.5 m along the walk axis (-Z).
	var floor_body: StaticBody3D = StaticBody3D.new()
	root.add_child(floor_body)
	var floor_mesh: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(6.0, 20.0)
	floor_mesh.mesh = plane
	var fm: StandardMaterial3D = StandardMaterial3D.new()
	fm.albedo_color = Color(0.06, 0.07, 0.09)
	floor_mesh.material_override = fm
	floor_body.add_child(floor_mesh)
	for z: int in range(-8, 9):
		var stripe: MeshInstance3D = MeshInstance3D.new()
		var sp: PlaneMesh = PlaneMesh.new()
		sp.size = Vector2(6.0, 0.02)
		stripe.mesh = sp
		stripe.position = Vector3(0.0, 0.002, float(z) * 0.5)
		var accent: bool = z % 2 == 0
		var sm: StandardMaterial3D = StandardMaterial3D.new()
		sm.albedo_color = Color(0.5, 0.62, 0.8) if accent else Color(0.2, 0.26, 0.36)
		sm.emission_enabled = true
		sm.emission = sm.albedo_color
		sm.emission_energy_multiplier = 0.6
		stripe.material_override = sm
		floor_body.add_child(stripe)

	# Build the creature and reach into its own AnimationTree — the very node the
	# game speed-matches — so nothing here is a stand-in for the shipping path.
	var creature: Node3D = null
	if _walk_which == "crew" or _walk_which == "crew_run":
		creature = CrewAvatar.create(GameState.local_color)
		root.add_child(creature)
	else:
		var graph: LayerGraph = LayerGraph.generate(12345, 12)
		var av: Antivirus = _make_probe_creature(_walk_which)
		if av == null:
			printerr("[walkprobe] no creature for '%s'" % _walk_which)
			get_tree().quit(1)
			return
		root.add_child(av)
		av.setup(0, Vector3.ZERO, 0, 12, graph)
		av.set_physics_process(false)
		av.set_process(false)  # stop its own _drive_animation fighting our scale
		creature = av
	creature.position = Vector3.ZERO
	creature.rotation = Vector3.ZERO  # faces -Z; forward travel is -Z

	await get_tree().process_frame
	var tree: AnimationTree = creature.find_child("AnimTree", true, false) as AnimationTree
	var skel: Skeleton3D = CreatureKit.find_skeleton(creature)
	if tree == null or skel == null:
		printerr("[walkprobe] '%s' has no AnimationTree/Skeleton (no clips yet?)" % _walk_which)
		get_tree().quit(1)
		return

	var contacts: Array = rig["contacts"]
	var v_real: float = _walk_speed if _walk_speed > 0.0 else _walk_real_speed(_walk_which)
	var coded: float = _walk_coded_stride(_walk_which)
	print("[walkprobe] '%s' state=%s v=%.2f m/s coded_stride=%.3f contacts=%s" % [
		_walk_which, String(rig["state"]), v_real, coded, str(contacts)])
	if contacts.is_empty():
		print("[walkprobe] %s does not walk (flight-only) — EXEMPT from foot-skate."
				% _walk_which)

	# Hand the tree to us: manual advance, our scale, its own state machine.
	tree.active = false
	CreatureKit.travel(tree, String(rig["state"]))
	CreatureKit.set_speed(tree, 1.0)
	tree.advance(0.0)
	for _s in 4:
		tree.advance(1.0 / 60.0)

	# The tracked contact point per foot: a point pinned to the foot bone at the
	# floor directly under the bone's rest head. These foot bones are LEAVES whose
	# head is the ankle/knee well above the ground, so their head arcs through the
	# leg cycle and is useless; a point rigidly carried by the bone at ground level
	# shares the foot's velocity and dips to a clean minimum in stance.
	var offsets: Dictionary = {}  # bone -> Vector3 in bone-local space
	for cb: String in contacts:
		var bi0: int = skel.find_bone(cb)
		if bi0 < 0:
			push_warning("[walkprobe] no bone '%s'" % cb)
			continue
		var grest: Transform3D = skel.get_bone_global_rest(bi0)
		var floor_pt: Vector3 = Vector3(grest.origin.x, 0.0, grest.origin.z)
		offsets[cb] = grest.affine_inverse() * floor_pt

	# --- NUMERIC: stance-foot backward speed at scale 1 = the ideal stride -------
	var dt: float = 1.0 / 60.0
	var n: int = 400  # enough for the slow auditor clip (2.4 s) to give a stable median
	var samples: Dictionary = {}  # bone -> Array[[z, y]]
	for cb: String in contacts:
		samples[cb] = []
	for _i in n:
		tree.advance(dt)
		for cb: String in contacts:
			if not offsets.has(cb):
				continue
			var bi: int = skel.find_bone(cb)
			var w: Vector3 = skel.global_transform \
					* (skel.get_bone_global_pose(bi) * (offsets[cb] as Vector3))
			(samples[cb] as Array).append([w.z, w.y])

	if not contacts.is_empty():
		_report_walk_skate(samples, contacts, v_real, coded)

	# --- VISUAL: treadmill filmstrip (world slides, creature centred) ------------
	if not screenshot_path.is_empty():
		await _walk_filmstrip(root, creature, tree, floor_body,
				v_real, coded, _walk_probe_height(_walk_which))
	get_tree().quit(0)


## Recursively hides CanvasLayers and top-level Controls, and stops their process
## so an autoload HUD/caption cannot re-show itself the next frame — leaving the
## walkprobe stage clean.
func _hush_overlays(node: Node) -> void:
	# The Captions autoload re-emits every frame (a spawned creature's presence
	# drone reads as "<name> nearby"), so hiding its layer once is not enough —
	# stop it processing outright.
	if node == get_tree().root:
		var caps: Node = get_node_or_null("/root/Captions")
		if caps != null:
			caps.process_mode = Node.PROCESS_MODE_DISABLED
	for child: Node in node.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false
			child.process_mode = Node.PROCESS_MODE_DISABLED
			continue
		if child is Control:
			(child as Control).visible = false
			child.process_mode = Node.PROCESS_MODE_DISABLED
			continue
		_hush_overlays(child)


func _make_probe_creature(which: String) -> Antivirus:
	match which:
		"sentinel":
			return Sentinel.new()
		"scrubber":
			return Scrubber.new()
		"hound":
			return Hound.new()
		"auditor":
			return Auditor.new()
		"moth":
			return Moth.new()
		_:
			return null


## The real move speed each gait is judged at (the state the probe drives).
func _walk_real_speed(which: String) -> float:
	match which:
		"crew":      return 3.0   # the walk clip's own band (starved / partial move)
		"crew_run":  return Player.SPRINT_SPEED
		"sentinel":  return Balance.SENTINEL_PURGE_SPEED
		"scrubber":  return Balance.SCRUBBER_STALK_SPEED
		"hound":     return Balance.HOUND_CHASE_SPEED
		"auditor":   return Balance.AUDITOR_WALK_SPEED
		_:           return 2.0


## Rough standing height per creature, for framing the treadmill camera.
func _walk_probe_height(which: String) -> float:
	match which:
		"crew", "crew_run": return 1.86
		"sentinel":         return Sentinel.BODY_HEIGHT
		"scrubber":         return 0.55
		"hound":            return Hound.BODY_HEIGHT
		"auditor":          return Auditor.BODY_HEIGHT
		_:                  return 1.5


## The stride constant the shipping code divides ground speed by, per gait.
func _walk_coded_stride(which: String) -> float:
	match which:
		"crew":      return CrewAvatar.WALK_SPEED_AUTHORED
		"crew_run":  return CrewAvatar.RUN_SPEED_AUTHORED
		"sentinel":  return Sentinel.WALK_STRIDE
		"scrubber":  return Scrubber.SKITTER_STRIDE
		"hound":     return Hound.CHASE_STRIDE
		"auditor":   return Auditor.PATROL_STRIDE
		_:           return 1.5


## Turns the per-bone stance samples into the numbers the mission is graded on.
##
## A rolling foot (heel-strike -> flat -> toe-off) means the tracked toe bone is
## only the true ground contact during the flat/toe-pivot part of stance; the
## heel-strike arc briefly whips it about the planted tip. So the honest read of
## the VISIBLE plant speed is the MEDIAN of the settled low-phase (feet lowest,
## episode ends trimmed), not the mean, which the arc frames skew — and the median
## of a clean plant lands on the constant the foot is truly pinned at.
func _report_walk_skate(samples: Dictionary, contacts: Array,
		v_real: float, coded: float) -> void:
	var dt: float = 1.0 / 60.0
	var settled: PackedFloat32Array = PackedFloat32Array()  # backward m/s @ scale 1
	var lows: int = 0
	for cb: String in contacts:
		var arr: Array = samples[cb]
		if arr.size() < 12:
			continue
		var ymin: float = INF
		var ymax: float = -INF
		for row: Array in arr:
			ymin = minf(ymin, row[1])
			ymax = maxf(ymax, row[1])
		var thresh: float = ymin + 0.20 * maxf(ymax - ymin, 0.0001)
		# Split the low frames into contiguous episodes; trim each episode's ends
		# (the heel-strike-in and toe-off-out arcs) and keep the settled middle.
		var ep: Array = []
		var j: int = 0
		while j < arr.size():
			if arr[j][1] <= thresh:
				var k: int = j
				while k < arr.size() and arr[k][1] <= thresh:
					k += 1
				ep.append([j, k])  # [start, end)
				j = k
			else:
				j += 1
		for span: Array in ep:
			var a: int = span[0]
			var b: int = span[1]
			lows += b - a
			var trim: int = int(floor((b - a) * 0.22))
			for m: int in range(a + maxi(trim, 1), b - maxi(trim, 0)):
				settled.append((arr[m][0] - arr[m - 1][0]) / dt)  # +Z = backward
	if settled.is_empty():
		print("[walkprobe]   no stance frames detected")
		return
	settled.sort()
	var med: float = settled[settled.size() / 2]
	var p25: float = settled[settled.size() / 4]
	var p75: float = settled[(settled.size() * 3) / 4]

	# Residual skate the SHIPPING mapping produces at v_real, judged against the
	# median plant speed: rate = v/coded, foot real backward speed = med*rate, body
	# forward = v, so net skate = v - med*rate = v*(1 - med/coded). The p25..p75
	# spread is the irreducible intra-stance wobble a scalar stride cannot remove.
	var mm: float = 1000.0 / 60.0  # m/s -> mm/frame at 60 fps
	var net_skate: float = absf(v_real * (1.0 - med / maxf(coded, 0.001)))
	var wobble: float = (p75 - p25) * (v_real / maxf(coded, 0.001))
	print("[walkprobe]   plant speed (settled median) = %.3f m/s  [p25 %.3f p75 %.3f, %d low frames]" % [
		med, p25, p75, lows])
	print("[walkprobe]   ideal stride = %.3f  [coded %.3f]" % [med, coded])
	print("[walkprobe]   @%.2f m/s : NET skate %.2f mm/frame  +/- wobble %.2f mm/frame" % [
		v_real, net_skate * mm, wobble * mm])


## A TREADMILL filmstrip: the creature is held centred and large under a fixed,
## close side camera while the WORLD (floor + reference stripes) slides backward at
## the real ground speed, exactly as the ground would flow past a creature walking
## over it. The speed-matched clip runs on top. A planted foot then rides ONE
## stripe backward for the whole of its stance (foot and stripe locked together
## panel to panel); a skating foot drifts across the stripes. Five frames across
## one step are stacked top-to-bottom into a single PNG.
func _walk_filmstrip(root: Window, creature: Node3D, tree: AnimationTree,
		floor_ref: Node3D, v_real: float, coded: float, height: float) -> void:
	var panel: Vector2i = Vector2i(960, 440)
	root.size = panel
	var cam: Camera3D = Camera3D.new()
	root.add_child(cam)
	cam.fov = 40.0
	# Close and side-on, aimed at the lower body so the feet and the stripes under
	# them fill the frame. Distance and aim scale with the creature's height.
	var dist: float = maxf(2.6 * height, 1.3)
	cam.position = Vector3(dist, height * 0.55, 0.0)
	cam.look_at(Vector3(0.0, height * 0.34, 0.0))
	cam.current = true
	creature.position = Vector3.ZERO  # fixed: the world moves, not the creature

	var frames: int = 5
	var rate: float = clampf(v_real / maxf(coded, 0.001), 0.25, 3.0)
	var step_time: float = maxf(coded, 0.6) / maxf(v_real, 0.1)
	var frame_dt: float = step_time / float(frames)
	var strip: Image = null
	for fidx: int in frames:
		var sub: int = 6
		for _k in sub:
			tree.advance(frame_dt / float(sub) * rate)
			# World slides +Z (backward, since the creature faces -Z) at v.
			floor_ref.position.z += v_real * (frame_dt / float(sub))
		await get_tree().process_frame
		RenderingServer.force_draw()
		var img: Image = root.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		if strip == null:
			strip = Image.create(panel.x, panel.y * frames, false, Image.FORMAT_RGB8)
		strip.blit_rect(img, Rect2i(0, 0, panel.x, panel.y), Vector2i(0, panel.y * fidx))
	if strip != null:
		strip.save_png(screenshot_path)
		print("[walkprobe] treadmill filmstrip (%d frames, top=first) saved %s" % [
			frames, screenshot_path])


# ---------------------------------------------------------------- tailmotion --

## `--tailmotion <crew|sentinel>`. The tail-liveliness acceptance test: a scripted
## STAND -> sharp TURN -> RUN -> JUMP -> LAND+STOP, driven in real time with the
## TailDriver's dynamics LIVE (Debug.tail_live bypasses the capture freeze), under
## a chase camera. Six frames at the moments the tail should be doing something —
## lagging the turn out wide, streaming back in the run, whipping down on the
## landing and swinging through on the stop — stacked into one PNG. Pair with
## `--screenshot PATH`. The point players raised: the tail must READ in motion.
func _run_tail_motion() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var current: Node = get_tree().current_scene
	if current != null:
		current.queue_free()
	_hush_overlays(get_tree().root)
	await get_tree().process_frame

	var root: Window = get_tree().root
	var panel: Vector2i = Vector2i(1100, 420)
	root.size = panel
	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.025, 0.035)
	e.ambient_light_color = Color(0.34, 0.40, 0.50)
	e.ambient_light_energy = 0.85
	env.environment = e
	root.add_child(env)
	var key: DirectionalLight3D = DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-46.0, 32.0, 0.0)
	key.light_energy = 2.6
	key.shadow_enabled = true
	root.add_child(key)
	var fill: OmniLight3D = OmniLight3D.new()
	fill.position = Vector3(3.0, 2.4, 3.0)
	fill.light_energy = 4.0
	fill.omni_range = 16.0
	fill.light_color = Color(0.7, 0.82, 1.0)
	root.add_child(fill)
	var floor_mesh: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	floor_mesh.mesh = plane
	var fm: StandardMaterial3D = StandardMaterial3D.new()
	fm.albedo_color = Color(0.07, 0.08, 0.10)
	floor_mesh.material_override = fm
	root.add_child(floor_mesh)

	var height: float = _walk_probe_height(_tail_motion_which)
	var creature: Node3D = null
	if _tail_motion_which == "crew":
		creature = CrewAvatar.create(GameState.local_color)
		root.add_child(creature)
	else:
		var av: Antivirus = _make_probe_creature(_tail_motion_which)
		if av == null:
			printerr("[tailmotion] no creature for '%s'" % _tail_motion_which)
			get_tree().quit(1)
			return
		var graph: LayerGraph = LayerGraph.generate(12345, 12)
		root.add_child(av)
		av.setup(0, Vector3.ZERO, 0, 12, graph)
		av.set_physics_process(false)   # we drive the transform; its own _process stays
		creature = av
	creature.position = Vector3.ZERO

	var cam: Camera3D = Camera3D.new()
	cam.fov = 44.0
	root.add_child(cam)
	print("[tailmotion] staged '%s' (tail_live=%s)" % [_tail_motion_which, tail_live])

	# Scripted motion, integrated in real time. The body faces the run direction
	# throughout (so the side camera stays consistent); the "turn" is a sharp yaw
	# WIGGLE that swings the heavy kit and tail out and lets them lag back.
	var caps: Array = [0.35, 0.66, 1.12, 1.4, 1.84, 2.08]  # rest,wiggle,run,run,jump,land
	var cap_i: int = 0
	var elapsed: float = 0.0
	var pos: Vector3 = Vector3.ZERO
	var run_yaw: float = deg_to_rad(115.0)
	var yaw: float = run_yaw
	var strip: Image = null
	var guard: int = 0
	while cap_i < caps.size() and guard < 6000:
		guard += 1
		await get_tree().process_frame
		var dt: float = minf(get_process_delta_time(), 1.0 / 30.0)
		elapsed += dt
		var vel: Vector3 = Vector3.ZERO
		var y: float = 0.0
		var face0: Vector3 = Vector3(-sin(run_yaw), 0.0, -cos(run_yaw))
		if elapsed < 0.4:
			yaw = run_yaw                                        # STAND — resting sag
		elif elapsed < 0.9:
			yaw = run_yaw + sin(smoothstep(0.4, 0.9, elapsed) * TAU) * deg_to_rad(48.0)
		elif elapsed < 1.7:
			yaw = run_yaw
			vel = face0 * 6.4                                    # RUN (walk plays)
		elif elapsed < 1.95:
			yaw = run_yaw
			vel = face0 * 3.0                                    # JUMP (still moving)
			y = sin(smoothstep(1.7, 1.95, elapsed) * PI) * 0.85
		else:
			yaw = run_yaw                                        # LAND + hard STOP
		pos += vel * dt
		creature.position = Vector3(pos.x, y, pos.z)
		creature.rotation.y = yaw
		# Side-follow cam: perpendicular to the run direction and a touch behind, so
		# the profile secondaries — arm follow-through, torso react, kit sway, the
		# weight bob — read clearly while it stays framed and large.
		var face: Vector3 = Vector3(-sin(run_yaw), 0.0, -cos(run_yaw))
		var right: Vector3 = Vector3(-face.z, 0.0, face.x)
		var dist: float = maxf(2.2 * height, 2.6)
		cam.global_position = creature.global_position + right * dist \
				- face * 0.5 + Vector3(0.0, height * 0.6, 0.0)
		cam.look_at(creature.global_position + Vector3(0.0, height * 0.42, 0.0))
		if cap_i < caps.size() and elapsed >= caps[cap_i]:
			RenderingServer.force_draw()
			var img: Image = root.get_texture().get_image()
			img.convert(Image.FORMAT_RGB8)
			if strip == null:
				strip = Image.create(panel.x, panel.y * caps.size(), false, Image.FORMAT_RGB8)
			strip.blit_rect(img, Rect2i(0, 0, panel.x, panel.y), Vector2i(0, panel.y * cap_i))
			print("[tailmotion] frame %d @ t=%.2fs" % [cap_i, elapsed])
			cap_i += 1
	if strip != null and not screenshot_path.is_empty():
		strip.save_png(screenshot_path)
		print("[tailmotion] filmstrip (rest/turn/run/jump/land/settle) saved %s"
				% screenshot_path)
	get_tree().quit(0)


# ----------------------------------------------------------------- dumplayer --

## Headless determinism probe. Generates the graph for (seed, layer) and prints
## it; run it twice and diff, or run it with two seeds and confirm they differ.
func _dump_layer_graph() -> void:
	var graph: LayerGraph = LayerGraph.generate(_dump_seed, _dump_layer)
	print("run_seed=%d" % _dump_seed)
	print(graph.to_text())
	get_tree().quit(0)


# ---------------------------------------------------------------- automation --

func _arm_automation() -> void:
	Net.local_player_spawned.connect(_on_automation_player_ready, CONNECT_ONE_SHOT)
	# Every new layer re-arms, which is what makes --autodescend a soak rather
	# than a single descent.
	Run.layer_changed.connect(_on_automation_layer)


func _on_automation_player_ready(_player: Node) -> void:
	_run_automation()
	if _decompile_at >= 0.0:
		_decompile_later(_decompile_at)
	if _fire_delay >= 0.0:
		_fire_later(_fire_delay)
	if _flare_delay >= 0.0:
		_flare_later(_flare_delay)
	if _cast_delay >= 0.0:
		_cast_later(_cast_delay)
	if _grab_count > 0:
		_grab_shards(_grab_count)
	# With `--autodescend` the exfil is deferred until a backdoor layer is
	# reached; see `_on_automation_layer`.
	if _exfil_delay >= 0.0 and not _auto_descend:
		_run_exfil(_exfil_delay)
	if _compiler_delay >= 0.0:
		_run_compiler(_compiler_delay)
	if _rewire_delay >= 0.0:
		_run_rewire(_rewire_delay)
	if _seal_delay >= 0.0:
		_run_seal(_seal_delay)
	if _terminal_delay >= 0.0:
		_run_terminal(_terminal_delay)
	if _tour:
		_run_tour()


func _decompile_later(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	print("[Debug] applying lethal damage to the local avatar")
	Run.request_debug_decompile()


func _fire_later(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	print("[Debug] holding the breaker trigger")
	hold_fire = true


## Drives the same path the input does, so the host's stock and Cycles checks are
## exercised rather than bypassed.
func _flare_later(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	var player: Node = Net.get_player(Net.local_id())
	var avatar: Player = player as Player
	if avatar == null or not is_instance_valid(avatar):
		push_warning("[Debug] --flare skipped: no local player")
		return
	print("[Debug] throwing a flare")
	avatar.throw_flare()


func _on_automation_layer(number: int) -> void:
	if _tour:
		# Same handover `--autodescend` makes: once the tour reaches a backdoor
		# layer, stop touring and play the endgame out through the real channels.
		if _exfil_delay >= 0.0 and bool(LayerParams.of(number)["has_backdoor"]):
			print("[Debug] tour: layer %d has a backdoor, running the exfil" % number)
			_tour = false
			hold_interact = false
			hold_fire = false
			_run_exfil(1.2)
			return
		print("[Debug] tour: now on layer %d" % number)
		_run_tour()
		return
	if not _auto_descend:
		return
	# The full loop, in one run: ride the shaft down to the first backdoor layer
	# and then play the endgame out through the real channels. Without this,
	# `--autodescend --exfil` would fire the exfil script on layer 1, where there
	# is no node to root, and the soak would never reach the thing it exists to
	# prove.
	if _exfil_delay >= 0.0 and bool(LayerParams.of(number)["has_backdoor"]):
		print("[Debug] autodescend: layer %d has a backdoor, running the exfil" % number)
		_auto_descend = false
		hold_interact = false
		_run_exfil(1.2)
		return
	print("[Debug] autodescend: now on layer %d, re-arming" % number)
	hold_interact = false
	_run_automation()


func _run_automation() -> void:
	if not _goto.is_empty():
		await get_tree().create_timer(_goto_delay).timeout
		_teleport_local(_goto)
	if _hold_delay >= 0.0:
		var wait: float = maxf(_hold_delay - _goto_delay, 0.1) if not _goto.is_empty() \
				else _hold_delay
		await get_tree().create_timer(wait).timeout
		print("[Debug] holding interact")
		hold_interact = true


## Host-side-equivalent dev teleport: moves the *local* avatar only, which is
## exactly what a client is allowed to do to itself under M1's client-authority
## movement. Each peer offsets sideways by its roster index so a mustered crew
## does not stack inside one capsule.
## Applies `--pitch` if it was given, otherwise the target's own choice.
func _pitch_for(default_pitch: float) -> float:
	return pitch_override if _has_pitch else default_pitch


## `--tour`. One room every `tour_interval` seconds, wrapping. See the field.
func _advance_tour(delta: float) -> void:
	if tour_interval <= 0.0:
		return
	_tour_clock -= delta
	if _tour_clock > 0.0:
		return
	_tour_clock = tour_interval
	var layer: Node = get_tree().get_first_node_in_group("layer")
	var player: Node = Net.get_player(Net.local_id())
	if layer == null or player == null or not is_instance_valid(player):
		return
	var graph: LayerGraph = layer.get("graph") as LayerGraph
	if graph == null or graph.rooms.is_empty():
		return
	var avatar: Player = player as Player
	if avatar == null:
		return
	var room: Dictionary = graph.rooms[_tour_index % graph.rooms.size()]
	_tour_index += 1
	var centre: Vector2 = (Vector2(room["min"]) + Vector2(room["max"])) * 0.5
	# Facing the middle of the room from a step off-centre, so the sight cone has
	# something in it — a tour that always looked at a wall would discover rooms
	# and never a single fixture.
	avatar.teleport_to(Vector3(centre.x, 0.35, centre.y + 3.0), 0.0, _pitch_for(0.0))


func _teleport_local(where: String) -> void:
	var layer: Node = get_tree().get_first_node_in_group("layer")
	var player: Node = Net.get_player(Net.local_id())
	if layer == null or player == null or not is_instance_valid(player):
		push_warning("[Debug] teleport '%s' skipped: no layer or no local player" % where)
		return

	var index: int = maxi(Net.crew.keys().find(Net.local_id()), 0)
	var avatar: Player = player as Player
	if avatar == null:
		return

	# --- M6.6 vertical probes ------------------------------------------------
	#
	# The layer has decks in it now, and none of the M2-M4 targets can frame one:
	# they all put the lens at grade. These stand the avatar ON the geometry the
	# verticality pass authored, which is both how the milestone gets photographed
	# and how anybody tuning a ramp angle looks at one without playing to it.
	if where == "deck" or where == "perch" or where == "catwalk" \
			or where == "ledge" or where == "below" or where == "tall" \
			or where == "stair" or where == "pit":
		if not _vertical_goto(avatar, where, index):
			push_warning("[Debug] no '%s' on this layer" % where)
		return

	# `rig` is `shaft` under another name. In THE PARTITION the Layer publishes the
	# injection rig as `shaft_position` (see `Layer._adopt_hub_furniture`), so the
	# same walk-up geometry — stood off the console, inside the muster radius,
	# facing it — is correct in both places. The alias exists so a hub script reads
	# like what it is doing rather than like a leftover.
	if where == "rig":
		where = "shaft"
	if where == "shaft":
		var shaft: Vector3 = Vector3(layer.get("shaft_position"))
		# Stood off the console, facing it (-Z). Only index 0 lines up with the
		# console probe; the rest just need to be inside the muster radius.
		var side: float = 0.0 if index == 0 else (1.9 if index % 2 == 1 else -1.9)
		avatar.teleport_to(shaft + Vector3(side, 0.35, 5.4), 0.0, _pitch_for(0.0))
		print("[Debug] teleported to drop shaft %s" % str(shaft))
	elif where == "node" or where == "uplink" or where == "vault" or where == "nest":
		var target: Vector3 = Vector3(layer.get(
				"backdoor_position" if where == "node" else
				("uplink_position" if where == "uplink" else
				("vault_position" if where == "vault" else "nest_position"))))
		if target.is_equal_approx(Vector3.ZERO):
			push_warning("[Debug] no '%s' on this layer" % where)
			return
		var lateral: float = 0.0 if index == 0 else (1.6 if index % 2 == 1 else -1.6)
		if where == "nest":
			# Stand in the middle of it, looking down: that is where the pack is,
			# and a Scrubber is well below the horizon.
			avatar.teleport_to(target + Vector3(lateral, 0.35, 0.0), 0.0, _pitch_for(-0.42))
			print("[Debug] teleported to nest %s" % str(target))
			return
		if where == "uplink":
			# Inside the pad looking outward at the console on its rim: standing
			# behind the console would be standing off the pad when it fires.
			avatar.teleport_to(target + Vector3(lateral, 0.35, 0.9), PI, _pitch_for(0.0))
			print("[Debug] teleported to uplink %s" % str(target))
			return
		# The node is channelled from its +Z face, same convention as the shaft.
		avatar.teleport_to(target + Vector3(lateral, 0.35, 3.4), 0.0, _pitch_for(0.0))
		print("[Debug] teleported to %s %s" % [where, str(target)])
	elif where == "compiler" or where == "sanctuary":
		# Stood off the plate at reading distance, facing it. The terminal's own
		# yaw points its screen into the room, so the reader stands on that side
		# and looks back — the same reasoning as `--goto decal`. `sanctuary` picks
		# the backdoor room's guaranteed terminal instead of the hidden one.
		var terminals: Array = layer.get("compiler_positions")
		if terminals.is_empty():
			push_warning("[Debug] no compiler on this layer")
			return
		var pick: int = (terminals.size() - 1) if where == "sanctuary" \
				else (index % terminals.size())
		var machine: CompilerTerminal = CompilerTerminal.find(get_tree(), pick)
		var spot: Vector3 = terminals[pick]
		var facing: Vector3 = Vector3(0.0, 0.0, 1.0) if machine == null \
				else -machine.global_transform.basis.z
		# Straight out from the plate is usually right and occasionally puts a rib
		# column between the lens and the machine. Fan a few angles and take the
		# first with a genuine sightline, the same way `--goto crew` probes for a
		# clear side to stand on.
		var view: Dictionary = _clear_view(spot, facing, COMPILER_STANDOFF)
		var out: Vector3 = view["direction"]
		var stand: Vector3 = spot + out * float(view["distance"])
		avatar.teleport_to(Vector3(stand.x, 0.35, stand.z),
				atan2(out.x, out.z), _pitch_for(-0.14))
		# Re-aim from where the body actually ended up. A teleport into a tight
		# spot is depenetrated by the next `move_and_slide`, and a yaw computed
		# from the position we *asked* for then points a metre past the machine —
		# which is a whole afternoon of "why is the prop off the edge of frame".
		_look_at_after_settling(avatar, spot + Vector3.UP * 1.3)
		print("[Debug] teleported to compiler %d at %s (stand %s, %s)" % [
			pick, str(spot.snapped(Vector3.ONE * 0.1)),
			str(stand.snapped(Vector3.ONE * 0.1)),
			"sanctuary" if machine != null and machine.sanctuary else "hidden"])
	elif M48_TARGETS.has(where):
		_goto_prop(where, index)
	elif where == "wallhug":
		# Nose against a wall, looking straight at it. The only way to photograph
		# the weapon-collision tuck (Player._update_weapon_tuck): standing back at
		# reading distance the hold is clear and there is nothing to see, and no
		# automated run is ever going to walk itself into a panel by accident.
		var sign: Decal = _pick_decal(layer)
		if sign == null:
			push_warning("[Debug] no decals on this layer to stand against")
			return
		var out: Vector3 = sign.global_transform.basis.y.normalized()
		var stand: Vector3 = sign.global_position + out * WALLHUG_STANDOFF
		avatar.teleport_to(Vector3(stand.x, 0.35, stand.z),
				atan2(out.x, out.z), _pitch_for(0.0))
		print("[Debug] wall-hugging %.2f m off '%s' at %s" % [
			WALLHUG_STANDOFF, String(sign.name),
			str(sign.global_position.snapped(Vector3.ONE * 0.1))])
	elif where == "decal":
		# Art-direction probe: stand off a wall sign and look at it. Signage that
		# cannot be read at three metres is not signage, and there is no other way
		# to check that from a level-wide screenshot.
		var sign: Decal = _pick_decal(layer)
		if sign == null:
			push_warning("[Debug] no decals on this layer")
			return
		# A decal projects along its own -Y; the wall it is printed on is that
		# way, so the reader stands the other way.
		var out: Vector3 = sign.global_transform.basis.y.normalized()
		var stand: Vector3 = sign.global_position + out * 4.2
		avatar.teleport_to(Vector3(stand.x, 0.35, stand.z),
				atan2(-(-out).x, -(-out).z),
				atan2(sign.global_position.y - 1.62, 4.2))
		print("[Debug] reading decal '%s' at %s out=%s stand=%s yaw=%.2f" % [
			String(sign.name), str(sign.global_position.snapped(Vector3.ONE * 0.1)),
			str(out.snapped(Vector3.ONE * 0.01)), str(stand.snapped(Vector3.ONE * 0.1)),
			atan2(-(-out).x, -(-out).z)])
	elif where == "corridor":
		var run: Vector3 = Vector3(layer.get("corridor_position"))
		if run.is_equal_approx(Vector3.ZERO):
			push_warning("[Debug] no corridor on this layer")
			return
		avatar.teleport_to(run + Vector3(0.0, 0.35, 0.0), float(layer.get("corridor_yaw")),
				_pitch_for(0.0))
		print("[Debug] teleported to corridor %s" % str(run))
	elif where == "crew":
		var casualty: Node3D = _nearest_corrupted(avatar)
		if casualty == null:
			push_warning("[Debug] no corrupted crewmate to walk to")
			return
		# Stood just off them on whichever side is actually open, looking at them.
		# A corrupted crewmate is on the floor and often went down against a wall,
		# so the approach is probed rather than assumed; a standing one wants a
		# level look instead of a downward one.
		var approach: Vector3 = _clear_side(casualty)
		var down: bool = Run.is_corrupted(int(String(casualty.name)))
		avatar.teleport_to(casualty.global_position + approach + Vector3.UP * 0.35,
				atan2(approach.x, approach.z), _pitch_for(-0.4 if down else -0.06))
		print("[Debug] teleported to crewmate %s at %s (approach %s)" % [
			String(casualty.name), str(casualty.global_position.snapped(Vector3.ONE * 0.1)),
			str(approach.snapped(Vector3.ONE * 0.1))])
	elif where == "siphon":
		var taps: Array = layer.get("siphon_positions")
		var approaches: Array = layer.get("siphon_approaches")
		if taps.is_empty():
			push_warning("[Debug] no siphon taps on this layer")
			return
		var pick: int = index % taps.size()
		var tap: Vector3 = taps[pick]
		var stand: Vector3 = approaches[pick] if pick < approaches.size() \
				else tap + Vector3(0.0, 0.0, 2.6)
		var look: Vector3 = tap - stand
		avatar.teleport_to(stand + Vector3.UP * 0.35, atan2(-look.x, -look.z),
				_pitch_for(0.0))
		print("[Debug] teleported to siphon tap %d %s" % [pick, str(tap)])
	else:
		push_warning("[Debug] unknown --goto target '%s'" % where)


# --------------------------------------------------------- M4.8 prop probes --

## `--goto` targets that resolve to one of the milestone's functional props.
## Each maps to the group the prop registers itself in, plus how far back to
## stand and what height to look at — a vent is a hole at knee-to-chest height
## and a bulkhead is four metres of door, and photographing either from the
## Compiler's standoff would frame the wrong thing.
const M48_TARGETS: Dictionary = {
	"junction": {"group": "rewire_junctions", "standoff": 2.4, "aim": 1.5},
	"vent": {"group": "weld_vents", "standoff": 2.8, "aim": 1.4},
	"cabinet": {"group": "loot_cabinets", "standoff": 2.6, "aim": 1.3},
	"terminal": {"group": "command_terminals", "standoff": 2.2, "aim": 1.5},
	"bulkhead": {"group": "bulkhead_doors", "standoff": 4.2, "aim": 1.8},
	"debris": {"group": "debris", "standoff": 2.0, "aim": 0.2},
	# M4.95: a density-pass machinery island, so the routed catenary feed cable and
	# its fixings can be photographed. Stands back far enough to see the machine and
	# the cable arcing up to its wall source, aimed high to catch the sag.
	"machine": {"group": "machines", "standoff": 3.8, "aim": 1.5},
	# FIDELITY PASS. The two hero practicals, so the Isolation-benchmark
	# compositions can be shot from a REAL GENERATED LAYER rather than from the
	# showcase. The work light stands well back — the shot is the lamp AND the
	# slatted pool it throws, and a 2.4 m standoff frames the lamp alone, which
	# is a product photo rather than a room.
	"worklight": {"group": "work_lights", "standoff": 3.2, "aim": 1.35},
	"panel": {"group": "diffuser_panels", "standoff": 3.2, "aim": 2.2},
}


## Stands the local avatar in front of one of M4.8's props, facing it.
##
## The approach direction is the prop's own facing where it has one (every wall
## prop's local -Z points into the room, the same convention the Compiler uses),
## fanned through `_clear_view` so a rib column between the lens and the machine
## moves the camera rather than ruining the shot. The re-aim after settling is the
## same fix the Compiler needed: a teleport into a tight spot is depenetrated on
## the next physics step, and a yaw computed before that points a metre wide.
func _goto_prop(where: String, index: int) -> void:
	var spec: Dictionary = M48_TARGETS[where]
	var nodes: Array[Node] = get_tree().get_nodes_in_group(String(spec["group"]))
	if nodes.is_empty():
		push_warning("[Debug] no '%s' on this layer" % where)
		return
	var prop: Node3D = nodes[index % nodes.size()] as Node3D
	if prop == null:
		return
	var player: Node = Net.get_player(Net.local_id())
	var avatar: Player = player as Player
	if avatar == null or not is_instance_valid(avatar):
		return

	var spot: Vector3 = prop.global_position
	# +Z, not -Z. Every M4.8 wall prop is built with its detailed face on local +Z
	# — the same convention `GeometryKit._wall_slot` uses for the module behind it,
	# so `LayerGraph.wall_normal` points both of them into the room. The Compiler
	# is the odd one out (its lectern faces -Z), which is exactly why this is a
	# separate probe rather than a shared one, and why the first version of it
	# photographed the wall beside every vent on the layer.
	var facing: Vector3 = prop.global_transform.basis.z
	var view: Dictionary = _clear_view(spot, facing, float(spec["standoff"]))
	var out: Vector3 = view["direction"]
	var stand: Vector3 = spot + out * float(view["distance"])
	avatar.teleport_to(Vector3(stand.x, 0.35, stand.z), atan2(out.x, out.z),
			_pitch_for(-0.12))
	_look_at_after_settling(avatar, spot + Vector3.UP * float(spec["aim"]))
	print("[Debug] teleported to %s %d at %s (stand %s)" % [
		where, index % nodes.size(), str(spot.snapped(Vector3.ONE * 0.1)),
		str(stand.snapped(Vector3.ONE * 0.1))])


## `--rewire`. Opens the junction panel the way holding E does and drives its own
## selection, so the host's proximity check and the panel's own request path are
## both exercised rather than bypassed.
func _run_rewire(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		push_warning("[Debug] --rewire: no local player")
		return
	var here: Vector3 = (player as Node3D).global_position
	var nearest: RewireJunction = null
	var best: float = Balance.JUNCTION_USE_RANGE
	for node: Node in get_tree().get_nodes_in_group(Props.GROUP_JUNCTION):
		var junction: RewireJunction = node as RewireJunction
		if junction == null or not is_instance_valid(junction):
			continue
		var distance: float = junction.global_position.distance_to(here)
		if distance < best:
			best = distance
			nearest = junction
	if nearest == null:
		push_warning("[Debug] --rewire: nothing in reach; is --goto junction set?")
		return
	var panel: JunctionPanel = JunctionPanel.open_for(nearest)
	if panel == null or _rewire_mode < 0:
		return
	await get_tree().create_timer(0.5).timeout
	if not is_instance_valid(panel):
		return
	print("[Debug] --rewire: routing to %s" % Props.power_name(_rewire_mode))
	panel.select(_rewire_mode)
	panel.route_selected()


## `--tour`. Use every M4.8 prop on this layer, in order, then ride the shaft
## down and do it again on the next one.
##
## This is the milestone's end-to-end proof and it is deliberately built out of
## the same pieces a player uses: it teleports to a prop (which is the only thing
## a `--goto` has ever done), holds the real trigger or the real interact key, and
## waits on **replicated state** rather than on a timer — so a step that silently
## stopped working hangs the tour instead of scrolling past in a log.
##
## The order is the order the props are meant to be used in. Route the power
## first, because DOOR LOCKS is what makes the cabinet silent; weld every vent,
## because a partly-welded nest still trickles; then the cabinet, the terminal,
## the bulkhead, and finally a kicked can on the way to the shaft.
func _run_tour() -> void:
	await get_tree().create_timer(1.4).timeout
	var layer: int = Run.layer_number

	# --- the junction, routed to DOOR LOCKS ---------------------------------
	if await _tour_visit("junction", 0):
		var junction: RewireJunction = _tour_nearest_junction()
		if junction != null:
			var panel: JunctionPanel = JunctionPanel.open_for(junction)
			if panel != null:
				await get_tree().create_timer(0.5).timeout
				panel.select(Props.Power.DOORS)
				panel.route_selected()
				await _wait_until(func() -> bool:
					return Props.power == Props.Power.DOORS, 5.0)
				panel.close()
				print("[Tour] L%d junction: power routed to %s" % [
					layer, Props.power_name(Props.power)])

	# --- every vent on the layer, welded ------------------------------------
	var vents: int = get_tree().get_nodes_in_group(Props.GROUP_VENT).size()
	for i: int in vents:
		if not await _tour_visit("vent", i):
			break
		hold_fire = true
		var welded: bool = await _tour_hold("vent", i, func() -> bool:
			return Props.is_welded(i))
		hold_fire = false
		if not welded:
			_diagnose("vent", i)
		print("[Tour] L%d vent %d: %s" % [layer, i, "welded" if welded else "FAILED"])

	# --- a cabinet, which the junction has just unlocked --------------------
	if await _tour_visit("cabinet", 0):
		hold_interact = true
		var opened: bool = await _tour_hold("cabinet", 0, func() -> bool:
			return Props.is_cabinet_open(0))
		hold_interact = false
		if not opened:
			_diagnose("cabinet", 0)
		print("[Tour] L%d cabinet 0: %s (silent path)" % [
			layer, "opened" if opened else "FAILED"])

	# --- the terminal -------------------------------------------------------
	if await _tour_visit("terminal", 0):
		var console: CommandTerminal = _tour_nearest_terminal()
		if console != null:
			var session: TerminalPanel = TerminalPanel.open_for(console)
			if session != null:
				await get_tree().create_timer(0.4).timeout
				session.submit("LIST DATA")
				await get_tree().create_timer(
						Balance.TERMINAL_QUERY_SECONDS + 1.4).timeout
				if is_instance_valid(session):
					session.close()
				print("[Tour] L%d terminal: query answered" % layer)

	# --- the bulkhead -------------------------------------------------------
	if await _tour_visit("bulkhead", 0):
		hold_interact = true
		var sealed: bool = await _wait_until(func() -> bool:
			return Props.is_sealed(0), 8.0)
		hold_interact = false
		print("[Tour] L%d bulkhead: %s" % [layer, "sealed" if sealed else "FAILED"])

	# --- kick something -----------------------------------------------------
	if await _tour_visit("debris", 0):
		hold_forward = true
		await get_tree().create_timer(1.2).timeout
		hold_forward = false
		print("[Tour] L%d debris: kicked" % layer)

	# --- and down ------------------------------------------------------------
	if _no_descend:
		print("[Tour] L%d complete; holding position (--no-descend)" % layer)
		return
	_teleport_local("shaft")
	await get_tree().create_timer(0.6).timeout
	hold_interact = true
	await _wait_until(func() -> bool: return Run.layer_number != layer, 20.0)
	hold_interact = false


## One stop on the tour: stand at the prop and give the physics a moment to
## settle. False when the layer has none of that prop, which is legitimate — not
## every ring rolls a bulkhead.
func _tour_visit(target: String, index: int) -> bool:
	if Run.run_over:
		return false
	var spec: Dictionary = M48_TARGETS.get(target, {}) as Dictionary
	if spec.is_empty():
		return false
	if get_tree().get_nodes_in_group(String(spec["group"])).is_empty():
		print("[Tour] L%d %s: none on this layer" % [Run.layer_number, target])
		return false
	_goto_prop(target, index)
	await get_tree().create_timer(0.9).timeout
	# And aim once more from wherever the body actually settled. `_goto_prop` has
	# already done this, but a second pass after a full second of physics costs
	# nothing and is the difference between a tour that reliably uses a prop and
	# one that reliably reports it broken.
	var player: Node = Net.get_player(Net.local_id())
	var avatar: Player = player as Player
	var nodes: Array[Node] = get_tree().get_nodes_in_group(String(spec["group"]))
	if avatar != null and is_instance_valid(avatar) and index < nodes.size():
		var prop: Node3D = nodes[index] as Node3D
		if prop != null:
			_look_at_after_settling(avatar,
					prop.global_position + Vector3.UP * float(spec["aim"]))
			await get_tree().create_timer(0.35).timeout
	return true


## Holds whatever is already being held until `test` passes, re-aiming at the
## prop between attempts.
##
## A single aim is not enough and the reason is the physics: a teleport that
## lands a capsule near a wall depenetrates over a second or so, and by the time
## it has stopped the yaw written on arrival is pointing at where the prop *was*
## relative to the body. Re-aiming from wherever it actually ended up converges
## in one or two passes and costs a few tenths of a second.
func _tour_hold(target: String, index: int, test: Callable) -> bool:
	for _attempt: int in 3:
		_face_prop(target, index)
		if await _wait_until(test, 3.0):
			return true
	return false


## Points the lens at a prop from wherever the avatar currently is. Immediate —
## no awaits, so it can be called inside a polling loop.
func _face_prop(target: String, index: int) -> void:
	var spec: Dictionary = M48_TARGETS.get(target, {}) as Dictionary
	if spec.is_empty():
		return
	var nodes: Array[Node] = get_tree().get_nodes_in_group(String(spec["group"]))
	if index >= nodes.size():
		return
	var prop: Node3D = nodes[index] as Node3D
	var player: Node = Net.get_player(Net.local_id())
	var avatar: Player = player as Player
	if prop == null or avatar == null or not is_instance_valid(avatar):
		return
	var eye: Vector3 = avatar.global_position + Vector3.UP * 1.62
	var to_prop: Vector3 = prop.global_position + Vector3.UP * float(spec["aim"]) - eye
	if to_prop.length_squared() < 0.04:
		return
	avatar.teleport_to(avatar.global_position, atan2(-to_prop.x, -to_prop.z),
			_pitch_for(atan2(to_prop.y, Vector2(to_prop.x, to_prop.z).length())))


## Why a tour step could not reach its prop. Temporary-feeling but permanent:
## every failure this milestone had was a line-of-sight problem, and a log line
## that says which ray missed is worth an afternoon of guessing.
func _diagnose(target: String, index: int) -> void:
	var spec: Dictionary = M48_TARGETS.get(target, {}) as Dictionary
	var nodes: Array[Node] = get_tree().get_nodes_in_group(String(spec["group"]))
	if nodes.is_empty() or index >= nodes.size():
		return
	var prop: Node3D = nodes[index] as Node3D
	var player: Node = Net.get_player(Net.local_id())
	if prop == null or player == null:
		return
	var avatar: Node3D = player as Node3D
	var eye: Vector3 = avatar.global_position + Vector3.UP * 1.62
	var space: PhysicsDirectSpaceState3D = avatar.get_world_3d().direct_space_state
	var forward: Vector3 = Vector3(-sin(avatar.rotation.y), 0.0, -cos(avatar.rotation.y))
	var to_prop: Vector3 = (prop.global_position + Vector3.UP * 1.0) - eye
	var probe: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			eye, eye + to_prop.normalized() * 7.0)
	probe.collision_mask = 4
	probe.collide_with_areas = true
	probe.collide_with_bodies = false
	var area: Dictionary = space.intersect_ray(probe)
	var wall: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			eye, eye + to_prop * 0.96)
	wall.collision_mask = 1
	var solid: Dictionary = space.intersect_ray(wall)
	print("[Tour] diagnose %s %d: dist=%.2f facing=%.2f area=%s wall=%s" % [
		target, index, to_prop.length(), forward.dot(to_prop.normalized()),
		"none" if area.is_empty() else String((area["collider"] as Node).get_parent().name),
		"clear" if solid.is_empty() else String((solid["collider"] as Node).name)])


func _tour_nearest_junction() -> RewireJunction:
	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		return null
	var here: Vector3 = (player as Node3D).global_position
	for node: Node in get_tree().get_nodes_in_group(Props.GROUP_JUNCTION):
		var junction: RewireJunction = node as RewireJunction
		if junction != null and is_instance_valid(junction) \
				and junction.global_position.distance_to(here) <= Balance.JUNCTION_USE_RANGE:
			return junction
	return null


func _tour_nearest_terminal() -> CommandTerminal:
	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		return null
	var here: Vector3 = (player as Node3D).global_position
	for node: Node in get_tree().get_nodes_in_group(Props.GROUP_TERMINAL):
		var console: CommandTerminal = node as CommandTerminal
		if console != null and is_instance_valid(console) \
				and console.global_position.distance_to(here) <= Balance.TERMINAL_USE_RANGE:
			return console
	return null


## `--seal`. Holds the bulkhead's channel through the real input path and lets go
## the moment the door is actually shut.
##
## `--hold-interact` cannot do this job: the bulkhead is the only interactable in
## the game that toggles, so a key held down past the completed channel seals it,
## re-arms and unseals it, forever. That is correct behaviour for the prop and
## useless behaviour for a capture.
func _run_seal(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	print("[Debug] --seal: holding the bulkhead channel")
	hold_interact = true
	if not await _wait_until(func() -> bool: return Props.is_sealed(0), 20.0):
		push_warning("[Debug] --seal gave up waiting for the door")
	hold_interact = false


## `--terminal` / `--query`. Opens a session and types commands into it through
## the panel's own submit path — the same one a keypress takes, so the noise ping
## and the host's proximity check are both real.
func _run_terminal(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		push_warning("[Debug] --terminal: no local player")
		return
	var here: Vector3 = (player as Node3D).global_position
	var nearest: CommandTerminal = null
	var best: float = Balance.TERMINAL_USE_RANGE
	for node: Node in get_tree().get_nodes_in_group(Props.GROUP_TERMINAL):
		var console: CommandTerminal = node as CommandTerminal
		if console == null or not is_instance_valid(console):
			continue
		var distance: float = console.global_position.distance_to(here)
		if distance < best:
			best = distance
			nearest = console
	if nearest == null:
		push_warning("[Debug] --terminal: nothing in reach; is --goto terminal set?")
		return
	var panel: TerminalPanel = TerminalPanel.open_for(nearest)
	if panel == null:
		return
	if _pad_row >= 0:
		# Parks the gamepad command list on a specific row, which is the only way
		# to photograph the pad path — a shutter will not land on a selection
		# somebody happened to scroll to.
		panel._selected = _pad_row % maxi(panel._commands.size(), 1)
	for command: String in _queries:
		await get_tree().create_timer(_query_delay).timeout
		if not is_instance_valid(panel):
			return
		print("[Debug] --query: %s" % command)
		panel.submit(command)
		# Wait out the processing beat plus the type-out, or the next query lands
		# on a busy machine and the capture photographs "BUSY."
		await get_tree().create_timer(
				Balance.TERMINAL_QUERY_SECONDS + 1.6).timeout


## A decal to photograph: the one nearest the crew's spawn, so the probe lands
## somewhere the layer actually lit rather than in a nest.
func _pick_decal(layer: Node) -> Decal:
	var best: Decal = null
	var best_distance: float = INF
	var origin: Vector3 = Vector3(layer.get_spawn_point(0).origin)
	for node: Node in layer.find_children("*", "Decal", true, false):
		var sign: Decal = node as Decal
		if sign == null:
			continue
		var distance: float = sign.global_position.distance_to(origin)
		if distance < best_distance:
			best_distance = distance
			best = sign
	return best


## Walks the avatar onto shard after shard until its buffer holds `count`. The
## absorb is the real one — the host still has to agree the shard was reached —
## so this exercises the salvage path rather than writing a number into it.
func _grab_shards(count: int) -> void:
	await get_tree().create_timer(1.2).timeout
	for i: int in count:
		var player: Node = Net.get_player(Net.local_id())
		var avatar: Player = player as Player
		if avatar == null or not is_instance_valid(avatar) or Run.run_over:
			return
		var shard: DataShard = _nearest_shard(avatar)
		if shard == null:
			push_warning("[Debug] --grab: no shards left on this layer")
			return
		avatar.teleport_to(shard.global_position - Vector3(0.0, DataShard.REST_HEIGHT, 0.0),
				avatar.rotation.y)
		await get_tree().create_timer(0.45).timeout
	print("[Debug] grabbed shards: buffer holds %d" % Run.local_buffered())


func _nearest_shard(from: Node3D) -> DataShard:
	var best: DataShard = null
	var best_distance: float = INF
	for node: Node in get_tree().get_nodes_in_group("data_shards"):
		var shard: DataShard = node as DataShard
		if shard == null or not is_instance_valid(shard):
			continue
		if Run.is_shard_taken(shard.shard_index):
			continue
		var distance: float = shard.global_position.distance_to(from.global_position)
		if distance < best_distance:
			best_distance = distance
			best = shard
	return best


## The endgame, end to end, through the same channels a player would hold: root
## the node, call the uplink, then stand on the pad. Every step waits on real
## replicated state rather than on a timer, so a slow host cannot make it lie.
func _run_exfil(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	_teleport_local("node")
	await get_tree().create_timer(0.4).timeout
	hold_interact = true
	if not await _wait_until(func() -> bool: return Run.backdoor_rooted, 20.0):
		push_warning("[Debug] --exfil gave up waiting for the node to root")
		return

	hold_interact = false
	await get_tree().create_timer(0.4).timeout
	_teleport_local("uplink")
	await get_tree().create_timer(0.4).timeout
	hold_interact = true
	if not await _wait_until(func() -> bool: return Run.exfil_calling, 20.0):
		push_warning("[Debug] --exfil gave up waiting for the uplink")
		return

	hold_interact = false
	print("[Debug] exfiltration called; standing on the pad")


## `--compiler` and `--buy`, end to end through the real paths: walk to the
## terminal, open its panel the way holding E does, then drive the panel's own
## purchase button. Nothing here reaches past the panel into Modules — a dev flag
## that skipped the panel would be proving the wrong thing.
func _run_compiler(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		push_warning("[Debug] --compiler: no local player")
		return
	var terminal: CompilerTerminal = CompilerTerminal.nearest(
			get_tree(), (player as Node3D).global_position)
	if terminal == null:
		push_warning("[Debug] --compiler: nothing in reach; is --goto compiler set?")
		return
	print("[Debug] opening compiler %d (stock tier %d)" % [
		terminal.compiler_index, terminal.stock_tier])
	var panel: CompilerPanel = CompilerPanel.open_for(terminal)
	if panel == null or _buy_tracks.is_empty():
		return

	for track: String in _buy_tracks:
		await get_tree().create_timer(_buy_delay).timeout
		if not is_instance_valid(panel):
			return
		if not Modules.is_track(track):
			push_warning("[Debug] --buy: no module track '%s'" % track)
			continue
		print("[Debug] --buy %s: before  %s" % [
			track.to_upper(), Modules.describe_loadout(Net.local_id())])
		panel.select(track)
		panel.buy_selected()
		# The purchase is a round trip even on a listen host (the request is
		# `call_local`), so the "after" line waits for the tier to actually move
		# rather than for a timer.
		var was: int = Modules.tier_of(Net.local_id(), track)
		await _wait_until(func() -> bool:
			return Modules.tier_of(Net.local_id(), track) > was, 4.0)
		print("[Debug] --buy %s: after   %s" % [
			track.to_upper(), Modules.describe_loadout(Net.local_id())])


## Polls `test` until it passes or `limit` seconds go by. Returns whether it
## passed; a run that has already ended stops waiting immediately.
func _wait_until(test: Callable, limit: float) -> bool:
	var waited: float = 0.0
	while waited < limit:
		if bool(test.call()):
			return true
		if Run.run_over:
			return false
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	return false


## Points the lens at `target` once the physics step has had a chance to shove
## the avatar out of anything it was teleported into. Two frames, because the
## depenetration happens on the physics callback and the yaw has to be written
## after it.
func _look_at_after_settling(avatar: Player, target: Vector3) -> void:
	# Six frames, not two.
	#
	# Two was enough for the Compiler, which stands in open floor. M4.8's props are
	# on walls, and a teleport that lands a capsule partly inside a wall, a crate
	# or a rib column depenetrates over *several* physics steps — so a yaw written
	# after two of them is a yaw computed from a body that is still moving. The
	# symptom was a tour standing 49 degrees off a vent it could see perfectly
	# well, which reads as a broken weld rather than as a broken camera.
	for _i: int in 6:
		await get_tree().physics_frame
	if not is_instance_valid(avatar):
		return
	var eye: Vector3 = avatar.global_position + Vector3.UP * 1.62
	var to_target: Vector3 = target - eye
	if to_target.length_squared() < 0.04:
		return
	avatar.teleport_to(avatar.global_position, atan2(-to_target.x, -to_target.z),
			_pitch_for(atan2(to_target.y, Vector2(to_target.x, to_target.z).length())))


## Where to stand to photograph `prop`: {direction, distance}.
##
## Fans candidate angles around `preferred` and measures how much open space each
## one has, casting **from the prop outward** rather than from the camera in.
## `intersect_ray` does not report a shape it starts inside, so a ray fired from a
## stand point buried in a siphon hall's hero pillar exits cleanly and calls the
## angle fine — which is how the first version of this kept photographing the
## inside of a column. The prop is known to be in open space (the generator insets
## it), so that way round is the test that cannot lie about its own origin.
##
## The measurement is along the **sightline a lens would use** — eye height at
## the stand point, down to the prop's reading height — not along the floor: a
## rib column a knee-high ray slides past still fills the middle of the picture.
## An angle with room for the full standoff wins immediately; otherwise the
## roomiest one is taken and the camera stands as far back as it fits, which is
## the difference between a cramped photograph and one of the inside of a wall.
func _clear_view(prop: Vector3, preferred: Vector3, wanted: float) -> Dictionary:
	var fallback: Dictionary = {"direction": preferred, "distance": wanted}
	var tree_layer: Node = get_tree().get_first_node_in_group("layer")
	if tree_layer == null:
		return fallback
	var space: PhysicsDirectSpaceState3D = \
			(tree_layer as Node3D).get_world_3d().direct_space_state
	if space == null:
		return fallback

	var target: Vector3 = prop + Vector3.UP * 1.35
	var best: Dictionary = {"direction": preferred, "distance": 0.0}
	for degrees: float in [0.0, 20.0, -20.0, 40.0, -40.0, 65.0, -65.0,
			95.0, -95.0, 135.0, -135.0, 180.0]:
		var direction: Vector3 = preferred.rotated(Vector3.UP, deg_to_rad(degrees))
		var eye: Vector3 = prop + direction * wanted + Vector3.UP * 1.97
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				target, eye)
		query.collision_mask = 1
		query.hit_from_inside = true
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			return {"direction": direction, "distance": wanted}
		var clearance: float = target.distance_to(Vector3(hit["position"]))
		if clearance > float(best["distance"]):
			best = {"direction": direction, "distance": clearance}
	# Nothing had the full standoff. Stand just short of whatever was roomiest,
	# and never so close that the prop is a wall of its own casing.
	best["distance"] = clampf(float(best["distance"]) - 0.7, 1.6, wanted)
	return best


## An offset from `body` with nothing solid in it. A shard-grabbing avatar tends
## to go down two metres from a wall, and dropping the rescuer inside that wall
## points its crosshair at masonry.
func _clear_side(body: Node3D) -> Vector3:
	var space: PhysicsDirectSpaceState3D = body.get_world_3d().direct_space_state
	var from: Vector3 = body.global_position + Vector3.UP * 1.0
	var best: Vector3 = Vector3(0.0, 0.0, 1.9)
	if space == null:
		return best

	var best_clearance: float = -1.0
	for i: int in 8:
		var angle: float = TAU * float(i) / 8.0
		var direction: Vector3 = Vector3(sin(angle), 0.0, cos(angle))
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				from, from + direction * 3.0)
		query.collision_mask = 1
		var hit: Dictionary = space.intersect_ray(query)
		var clearance: float = 3.0 if hit.is_empty() \
				else from.distance_to(Vector3(hit["position"]))
		if clearance > best_clearance:
			best_clearance = clearance
			best = direction * minf(1.9, maxf(clearance - 0.6, 0.8))
	return best


## Nearest crewmate for `--goto crew`.
##
## Prefers a corrupted one — that is the automated half of a restore, with the
## channel itself left to `--hold-interact`. Falls back to any living crewmate,
## which is how a two-instance capture gets a crewmate in frame at all: without
## the fallback the only way to photograph another player was to hurt them
## first.
func _nearest_corrupted(from: Node3D) -> Node3D:
	var downed: Node3D = _nearest_of(from, Run.corrupted_crew())
	if downed != null:
		return downed
	var living: Array[int] = []
	for id: int in Net.crew.keys():
		if int(id) != Net.local_id() and Run.is_running(int(id)):
			living.append(int(id))
	return _nearest_of(from, living)


func _nearest_of(from: Node3D, peers: Array) -> Node3D:
	var best: Node3D = null
	var best_distance: float = INF
	for peer: int in peers:
		if peer == Net.local_id():
			continue
		var node: Node = Net.get_player(peer)
		if node == null or not is_instance_valid(node):
			continue
		var body: Node3D = node as Node3D
		var distance: float = body.global_position.distance_to(from.global_position)
		if distance < best_distance:
			best_distance = distance
			best = body
	return best


# ------------------------------------------------------------------ fps log --

## Takes the brakes off so the census measures the renderer rather than the
## monitor. Only ever called by `--log-fps`, so a played session keeps its vsync.
func _uncap_frame_rate() -> void:
	Engine.max_fps = 0
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	print("[FPS] vsync disabled for the census")



## Per-window frame-rate census.
##
## The average alone is nearly useless for judging a game like this: a layer can
## sit at 300 fps and still be unplayable if it drops a frame every time a
## Sentinel's shadow atlas re-renders. The 1% low is the number that decides
## whether the merge shipped, and the worst frame is what to go and look at.
func _sample_fps(delta: float) -> void:
	if _fps_window <= 0.0:
		return
	# The first seconds of a run are shader compilation and the layer build. They
	# are real costs and they are worth knowing about, but they are not what
	# "does a two-client layer hold 60" is asking, and leaving them in drags every
	# 1% low to 1 fps and makes the number useless.
	_fps_warmup += delta
	if _fps_warmup < FPS_WARMUP:
		return
	_fps_samples.append(float(Engine.get_frames_per_second()))
	_fps_clock += delta
	if _fps_clock < _fps_window:
		return
	_fps_clock = 0.0

	var sorted: Array[float] = []
	for value: float in _fps_samples:
		if value > 0.0:
			sorted.append(value)
	_fps_samples.clear()
	if sorted.is_empty():
		return
	sorted.sort()

	var total: float = 0.0
	for value: float in sorted:
		total += value
	var low_index: int = maxi(int(float(sorted.size()) * 0.01), 0)
	# VRAM added M4.95: the filmic pass (PBR texture sets + the reflection atlas) is
	# the milestone with the real VRAM budget, so the soak has to be able to print
	# what it costs (INTEGRATION2 caps it at ~700 MB with the atlas at 12).
	# M7: what was actually on screen while that was measured. A 1% low is a claim
	# about a workload, and a perf line that does not say how many shatters,
	# impacts and cast blooms it was carrying is a number nobody can reproduce or
	# argue with. `Fx.counts` is a plain tally, incremented per spawn.
	var census: PackedStringArray = PackedStringArray()
	for family: String in Fx.counts.keys():
		census.append("%s %d" % [family, int(Fx.counts[family])])
	if not census.is_empty():
		print("[FPS] fx since boot: %s" % ", ".join(census))
	print("[FPS] avg=%.0f  1%%low=%.0f  min=%.0f  frames=%d  draws=%d  prims=%dk  vram=%dMB" % [
		total / float(sorted.size()), sorted[low_index], sorted[0], sorted.size(),
		RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
		RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576])


# ---------------------------------------------------------------- screenshot --

func _arm_screenshot() -> void:
	if DisplayServer.get_name() == "headless":
		push_warning("[Debug] --screenshot ignored: headless has no framebuffer")
		screenshot_path = ""
		return
	# Pin the framerate so a frame budget is also a wall-clock budget. Uncapped,
	# this machine renders 600 frames in ~2 s, which silently made the host quit
	# before a second instance could finish connecting.
	Engine.max_fps = 60
	lock_input = true

	_frames_left = screenshot_frames
	if _mode == "host" or _mode == "join":
		Net.local_player_spawned.connect(_on_local_player_spawned, CONNECT_ONE_SHOT)
		# A refused/timed-out connection is a state worth photographing too.
		Net.connect_failed.connect(_on_connect_failed, CONNECT_ONE_SHOT)
		# Backstop: if we never spawn (connection refused), still shoot + quit so
		# an automated run can never hang.
		_fail_safe(float(screenshot_frames) / 60.0 + 20.0)
	else:
		_shot_armed = true
	set_process(true)


func _on_local_player_spawned(_player: Node) -> void:
	print("[Debug] local player spawned, screenshot in %d frames" % _frames_left)
	_shot_armed = true


func _on_connect_failed(reason: String) -> void:
	print("[Debug] connect failed (%s), screenshot in %d frames" % [reason, _frames_left])
	_shot_armed = true


func _process(delta: float) -> void:
	_enforce_mouse()
	_advance_tour(delta)
	_sample_fps(delta)
	_advance_aim_drive(delta)
	_advance_burst()
	_advance_reel()
	if not _shot_armed or _shot_taken:
		return
	_frames_left -= 1
	if _frames_left <= 0:
		_shot_taken = true
		_capture.call_deferred()


# ----------------------------------------------------------- PT1 instruments --

## `--burst`: F9 arms the next `burst_frames` rendered frames.
func _unhandled_input(event: InputEvent) -> void:
	if burst_dir.is_empty():
		return
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_F9:
		return
	if _burst_left > 0:
		return
	_burst_left = burst_frames
	_burst_taken.clear()
	print("[Debug] --burst: capturing %d frames" % burst_frames)


func _advance_burst() -> void:
	if _burst_left <= 0:
		return
	_burst_left -= 1
	# Read back now, encode later. `get_image()` costs a GPU sync; `save_png()`
	# costs several milliseconds of CPU, which at 60 Hz would drop every other
	# frame of the very thing the burst is meant to photograph.
	var image: Image = get_viewport().get_texture().get_image()
	if image != null:
		_burst_taken.append(image)
	if _burst_left <= 0:
		_write_burst.call_deferred()


func _write_burst() -> void:
	DirAccess.make_dir_recursive_absolute(burst_dir)
	for image: Image in _burst_taken:
		var path: String = "%s/burst_%03d.png" % [burst_dir, _burst_index]
		_burst_index += 1
		image.save_png(path)
	print("[Debug] --burst: wrote %d frames to %s" % [_burst_taken.size(), burst_dir])
	_burst_taken.clear()


func _exit_tree() -> void:
	if _gun_log != null:
		_gun_log.flush()
		_gun_log.close()
		_gun_log = null


func _open_gun_log() -> void:
	_gun_log = FileAccess.open(gun_log_path, FileAccess.WRITE)
	if _gun_log == null:
		push_error("[Debug] --gunlog: cannot write %s" % gun_log_path)
		gun_log_path = ""
		return
	# PT4 added `tuck` and `miss_cm`. The two columns turn the log from "where is
	# the weapon" into "is it aimed, and if not, is that on purpose" — see
	# `Player.weapon_tuck` and `Debug.bore_offset`.
	_gun_log.store_line("frame,dt_ms,yaw,pitch,gx,gy,gz,mx,my,mz,roll_deg,bore_deg,"
			+ "tuck,miss_cm")


## One row per rendered frame: where the grip and the emitter are IN THE LENS'S
## OWN FRAME, in metres.
##
## This is the whole instrument for the PT1 gun-tracking complaint, and the
## coordinate system is the point. Screen pixels were the obvious choice and the
## wrong one: at a steep look-down the emitter passes within a few centimetres of
## the near plane, where `unproject_position` amplifies a 2 cm error into four
## digits and reports a hold that is tracking perfectly as one that has left the
## solar system. Camera-space metres cannot lie that way.
##
## The reading is trivial to interpret: **a hold bolted to the lens has constant
## (gx,gy,gz)**, whatever the player does with the mouse. Every centimetre of
## variation is a centimetre the weapon moved relative to the eye, and the
## complaint is exactly that number being large.
func _sample_gun(delta: float) -> void:
	if _gun_log == null:
		return
	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	var lens: Transform3D = camera.global_transform.affine_inverse()
	var grip: Vector3 = lens * player.call("hold_world_point")
	var muzzle: Vector3 = lens * player.call("muzzle_world_point")
	_gun_frame += 1
	# Angles are read off the LIVE camera basis rather than off the replicated
	# pose: `sync_yaw`/`sync_pitch` are written once per physics tick, and a
	# probe for a one-tick lag must not itself be sampled a tick late.
	var forward: Vector3 = -camera.global_transform.basis.z
	# The ROLL audit. The weapon's own basis, pulled into the lens's frame: a hold
	# with no cant has its up vector in the lens's own vertical plane, so the
	# lateral component of that vector IS the roll and it should be zero. Measured
	# rather than eyeballed, because a wide-FOV lens shears an object at the frame
	# edge and a sheared render of a level weapon looks exactly like a rolled one.
	var weapon: Basis = lens.basis * player.call("hold_world_basis")
	var roll: float = rad_to_deg(atan2(weapon.y.x, weapon.y.y))
	# And the BORE, not the silhouette: the angle between the grip->emitter line
	# and the sight line. The Surge's top edge is raked by design, so the only
	# honest measure of "is it pointing where I am looking" is the bore.
	var bore: Vector3 = (muzzle - grip).normalized()
	var offset: Vector2 = bore_offset(grip, muzzle, AIM_RANGE)
	_gun_log.store_line(
		"%d,%.3f,%.5f,%.5f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.2f" % [
			_gun_frame, delta * 1000.0,
			atan2(-forward.x, -forward.z),
			asin(clampf(forward.y, -1.0, 1.0)),
			grip.x, grip.y, grip.z, muzzle.x, muzzle.y, muzzle.z,
			roll, rad_to_deg(acos(clampf(bore.dot(Vector3.FORWARD), -1.0, 1.0))),
			float(player.call("weapon_tuck")),
			(offset.length() * 100.0) if not is_nan(offset.x) else -1.0])


## The saved PNG is the root viewport's own texture, which under `canvas_items`
## stretch is the post-stretch window output at full window resolution — so the
## file IS what the player sees, glow blur and all, not the 1280x720 design-space
## the UI was authored in. That was never obvious from the old one-line log, so
## all three sizes are printed together and compared: window, viewport, image.
## They agree on a healthy capture; when they do not, the capture is evidence
## about a resolution nobody asked for and the log says so out loud.
func _capture() -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var err: Error = image.save_png(screenshot_path)
	if err == OK:
		var window: Vector2i = DisplayServer.window_get_size()
		var shot: Vector2i = Vector2i(image.get_width(), image.get_height())
		var view: Vector2i = get_viewport().get_visible_rect().size
		print("[Debug] screenshot saved: %s  image=%dx%d (%.3f:1)  window=%dx%d  viewport=%dx%d" % [
			screenshot_path, shot.x, shot.y, float(shot.x) / maxf(float(shot.y), 1.0),
			window.x, window.y, view.x, view.y])
		if shot != window:
			push_warning(("[Debug] capture is %dx%d but the window is %dx%d — this shot is " +
					"NOT evidence about the window's aspect ratio") % [
					shot.x, shot.y, window.x, window.y])
		if forced_window_size != Vector2i.ZERO and shot != forced_window_size:
			push_warning("[Debug] --window-size asked for %dx%d, captured %dx%d" % [
					forced_window_size.x, forced_window_size.y, shot.x, shot.y])
	else:
		push_error("[Debug] screenshot failed: %s" % error_string(err))
	await get_tree().process_frame
	# `--quit-in` owns the process lifetime when both are given, so a host can
	# stay up past its own screenshot while a second instance takes theirs.
	if auto_quit_after <= 0.0:
		get_tree().quit(0 if err == OK else 1)


func _fail_safe(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	if not _shot_taken:
		push_warning("[Debug] fail-safe fired: capturing without a spawned player")
		_shot_taken = true
		_capture()


func _quit_after(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	print("[Debug] --quit-in elapsed")
	get_tree().quit()


# ------------------------------------------------------------- PT2 cartography --

## `--selftest`: the minimap can never draw a room nobody has been in.
##
## The PT2 minimap is a SHARED, HOST-VALIDATED memory of the layer — one crewmate
## walking into a room reveals it for all four. That makes it a small authority
## problem rather than a drawing problem, and the invariant underneath every claim
## the feature makes is one sentence:
##
##     a room enters the discovery set only if somebody was standing in it.
##
## The host enforces that with `Cartography.room_contains`, and the whole enforcement
## rests on those rectangles being DISJOINT once `ROOM_SLACK` is added. If two
## rooms ever shared a point, a player standing in the overlap could authorise a
## room they have never entered — and the failure would not look like a bug, it
## would look like the map being generous, which is exactly the kind of thing that
## ships. So the property is asserted over real generated graphs rather than
## trusted: every room's centre must resolve to that room and to NO other, and no
## two slack-expanded room boxes may intersect.
##
## Pure data — no scene, no physics, no networking — for the same reason
## `_vertical_selftest` is: the claim is a statement about the graph.
func _cartography_selftest() -> int:
	var failures: int = 0
	var rooms_checked: int = 0
	var worst_gap: float = INF
	var worst_where: String = ""

	for seed_value: int in _VERT_SEEDS:
		for layer: int in _VERT_LAYERS:
			var graph: LayerGraph = LayerGraph.generate(seed_value, layer)
			if graph == null:
				continue
			for i: int in graph.rooms.size():
				var room: Dictionary = graph.rooms[i]
				var low: Vector2 = Vector2(room["min"])
				var high: Vector2 = Vector2(room["max"])
				var centre: Vector3 = Vector3(
						(low.x + high.x) * 0.5, 0.0, (low.y + high.y) * 0.5)
				rooms_checked += 1

				# 1. A player at the centre of a room is in THAT room...
				if not Cartography.room_contains(graph, i, centre):
					failures += 1
					printerr("[SelfTest] FAIL  cartography: seed %d layer %d room %d "
							% [seed_value, layer, i]
							+ "does not contain its own centre")

				# 2. ...and in no other. This is the claim that keeps an unvisited
				#    room out of the set.
				for j: int in graph.rooms.size():
					if j == i:
						continue
					if Cartography.room_contains(graph, j, centre):
						failures += 1
						printerr("[SelfTest] FAIL  cartography: seed %d layer %d — "
								% [seed_value, layer]
								+ "standing in room %d authorises room %d" % [i, j])

				# 3. And the margin by which that holds, so a future room-spacing
				#    change that eats the slack shows up as a number before it shows
				#    up as a bug.
				for j: int in range(i + 1, graph.rooms.size()):
					var other: Dictionary = graph.rooms[j]
					var gap: float = _rect_gap(
							low, high, Vector2(other["min"]), Vector2(other["max"]))
					if gap < worst_gap:
						worst_gap = gap
						worst_where = "seed %d layer %d rooms %d/%d" % [
								seed_value, layer, i, j]

	var margin: float = worst_gap - Cartography.ROOM_SLACK * 2.0
	if margin <= 0.0:
		failures += 1
		printerr("[SelfTest] FAIL  cartography: closest rooms are %.2f m apart and "
				% worst_gap
				+ "ROOM_SLACK %.2f m expands both — they overlap (%s)" % [
					Cartography.ROOM_SLACK, worst_where])
	else:
		print("[SelfTest] PASS  cartography: %d rooms, none reachable from another; "
				% rooms_checked
				+ "tightest pair %.2f m apart, %.2f m clear of the slack (%s)" % [
					worst_gap, margin, worst_where])
	return failures


## Axis-aligned gap between two rectangles, in metres. Zero when they touch or
## overlap. Chebyshev-style on purpose: the containment test is per-axis, so the
## axis with the most separation is the one keeping them apart.
func _rect_gap(a_low: Vector2, a_high: Vector2, b_low: Vector2, b_high: Vector2) -> float:
	var x_gap: float = maxf(b_low.x - a_high.x, a_low.x - b_high.x)
	var y_gap: float = maxf(b_low.y - a_high.y, a_low.y - b_high.y)
	return maxf(maxf(x_gap, y_gap), 0.0)


# ------------------------------------------------------------- PT4 aim trace --
#
# The fourth round of one complaint: "THE GUN STILL DOESNT POINT TOWARDS THE
# RETICLE", reported live, at 3440x1440, after three fixes that each measured
# clean. `--gunlog` proved the hold is ATTACHED (constant grip in the lens's
# frame); it never proved the hold is AIMED, because a column of camera-space
# metres is not a picture and nobody had ever looked at the two together.
#
# The working hypothesis when this was written was ultrawide: every convergence
# constant had been solved against the 16:9 design camera, the game is hor+, so
# a baked convergence should point somewhere else at 21:9. **That hypothesis is
# wrong, and this instrument is how it was killed.** Three runs, identical
# scene, identical frame count:
#
#     1280x720    miss at 12 m  46.5 cm
#     3440x1440   miss at 12 m  45.1 cm
#     5120x1440   miss at 12 m  46.6 cm
#
# Aspect changes nothing, and it cannot: the reticle is the lens's own forward
# ray, the convergence puts the barrel line through a point ON that ray, and a
# 3D line through a point projects to a 2D line through that point's projection
# at ANY field of view or aspect. Field of view does not enter either. Anything
# that claims to solve convergence "for the aspect" is solving a problem that
# does not exist.
#
# What the same runs did show is that the miss MOVES — 10 cm to 122 cm and back,
# on a loop, with the player standing perfectly still. That is the bug, it is
# temporal rather than spatial, and it is invisible to every capture this repo
# has ever taken because a still frame samples one phase of it. Hence: an
# instrument that reports a DISTRIBUTION over a settled window rather than a
# reading, and that draws the barrel line into the frame so the number and the
# picture are the same evidence.

## `--aimtrace DIR`. Empty means off. Sweeps the lens through `aim_trace_pitches`,
## samples the bore over a settled window at each stop, writes an annotated PNG
## per stop and prints the table.
var aim_trace_dir: String = ""
## The stops, in radians. `Player.PITCH_LIMIT` is 1.45, so the last pair is the
## hard extreme of the lens's travel — which M6.6 made ordinary, because a game
## with decks in it has players looking straight up and straight down all day.
var aim_trace_pitches: Array[float] = [0.0, -0.5, 0.5, -1.0, 1.0, -1.45, 1.45]
## `--aimdrive`: scripted live-style motion. The mouse never stops moving and the
## avatar never stops walking, because that is the state the complaint was
## reported from and the state no scripted capture in this repo had ever been in.
var aim_drive: bool = false
## `--aimstrip DIR`: save every `AIM_STRIP_EVERY`th frame during the drive, up to
## `AIM_STRIP_FRAMES`. The filmstrip a human judges, next to the numbers.
var aim_strip_dir: String = ""
## `--aimoverlay`: draw the trace, run no sweep, quit on nobody's schedule.
var aim_overlay_only: bool = false
## `--physics-hz N`. Zero leaves the project setting alone. See the parser.
var physics_hz: int = 0

## Where the barrel is asked to meet the sight line, in metres. Matches
## `CrewAvatar.CONVERGE_DISTANCE`; the trace is meaningless measured anywhere
## else, so if that constant moves this one moves with it.
const AIM_RANGE: float = 12.0
## Rendered frames of settle before the first stop is sampled. The rule in
## CLAUDE.md for temporally-accumulated effects.
const AIM_SETTLE_FRAMES: int = 240
## And between stops: enough for the pitch to land and the pose to follow.
const AIM_STOP_SETTLE: int = 30
## Sampled per stop. At 60 fps that is two seconds — longer than the idle clip's
## loop, so the window sees every phase of whatever is moving.
const AIM_STOP_SAMPLES: int = 120
## `--aimstrip DIR [every] [count]` defaults. Spacing matters more than it looks:
## the first strip this instrument ever took sampled every 7th frame, which is
## 1.6 seconds of a 26-second run — the avatar had walked into one wall and the
## whole filmstrip was fourteen pictures of a tucked weapon. Wide enough to cover
## the run, or it is not a strip of the run.
var aim_strip_every: int = 45
var aim_strip_frames: int = 14

var _aim_overlay: AimOverlay = null
var _aim_clock: float = 0.0
var _aim_strip_taken: int = 0
var _aim_strip_frame: int = 0


## Where the barrel line crosses the plane `range_m` ahead of the lens, in the
## lens's own frame, in metres. `(0, 0)` IS the reticle, at every aspect and
## every field of view — see the section header.
##
## Returns a NaN vector when the barrel does not point forward at all, which is
## a real state at the pitch extremes and must not be quietly reported as a
## small miss.
static func bore_offset(grip: Vector3, muzzle: Vector3, range_m: float) -> Vector2:
	var span: Vector3 = muzzle - grip
	if span.length_squared() < 1.0e-12:
		return Vector2(NAN, NAN)
	var dir: Vector3 = span.normalized()
	if dir.z > -0.05:
		return Vector2(NAN, NAN)
	var t: float = (-range_m - grip.z) / dir.z
	if t <= 0.0:
		return Vector2(NAN, NAN)
	return Vector2(grip.x + t * dir.x, grip.y + t * dir.y)


## The lens-space grip and emitter, this frame. The same two points `--gunlog`
## logs, factored out so the trace and the log can never drift apart.
func _aim_sample() -> Dictionary:
	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		return {}
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return {}
	var lens: Transform3D = camera.global_transform.affine_inverse()
	var grip: Vector3 = lens * player.call("hold_world_point")
	var muzzle: Vector3 = lens * player.call("muzzle_world_point")
	var weapon: Basis = lens.basis * player.call("hold_world_basis")
	return {
		"grip": grip,
		"muzzle": muzzle,
		"offset": bore_offset(grip, muzzle, AIM_RANGE),
		"roll": rad_to_deg(atan2(weapon.y.x, weapon.y.y)),
		"camera": camera,
		"player": player,
	}


## `--gunlog` samples LAST, after every other node has had its say.
##
## This is a correctness fix with a measurable size, and it is worth the extra
## node. `Debug` is an autoload, so its `_process` runs BEFORE the scene's — which
## means sampling the hold from there compared THIS frame's camera against LAST
## frame's weapon pose (`CrewAvatar.drive` runs from `Player._process`). Standing
## still the two are identical and nobody ever noticed. Swinging a mouse at 1.8
## rad/s, one frame is 1.8 degrees, which the log reported as **31 cm of miss at
## 12 m that the renderer never drew**. An instrument that only lies while the
## player is moving is the worst kind, because moving is when the complaints come
## from.
##
## A child with a large `process_priority` sorts after the scene, so the sample is
## taken from the state that is about to be rendered.
class LateSampler extends Node:
	func _ready() -> void:
		name = "GunSampler"
		process_priority = 500

	func _process(delta: float) -> void:
		Debug._sample_gun(delta)


func _start_aim_trace() -> void:
	_aim_overlay = AimOverlay.new()
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "AimTrace"
	# Above the HUD's own tube so the trace is never drawn under a scanline.
	layer.layer = 128
	layer.add_child(_aim_overlay)
	add_child(layer)
	if not aim_trace_dir.is_empty():
		_run_aim_trace()


## The sweep. One stop per pitch, each sampled over a window rather than read off
## a frame — see the section header for why a reading is not evidence here.
func _run_aim_trace() -> void:
	DirAccess.make_dir_recursive_absolute(aim_trace_dir)
	var player: Node = null
	for _wait: int in 900:
		await get_tree().process_frame
		player = Net.get_player(Net.local_id())
		if player != null and is_instance_valid(player):
			break
	if player == null or not is_instance_valid(player):
		printerr("[AimTrace] no local player; nothing to trace")
		get_tree().quit()
		return
	for _settle: int in AIM_SETTLE_FRAMES:
		await get_tree().process_frame

	var view: Vector2i = get_window().size
	var camera: Camera3D = get_viewport().get_camera_3d()
	print("[AimTrace] %dx%d  aspect %.3f  fov %.1f  keep %s  range %.1f m" % [
		view.x, view.y, float(view.x) / maxf(float(view.y), 1.0),
		camera.fov if camera != null else 0.0,
		"HEIGHT" if camera != null and camera.keep_aspect == Camera3D.KEEP_HEIGHT \
				else "WIDTH", AIM_RANGE])
	print("[AimTrace] %8s %8s %8s %8s %8s %8s %8s %8s" % [
		"pitch", "mean_cm", "max_cm", "min_cm", "dx_cm", "dy_cm", "roll_deg", "px"])

	var yaw: float = float(player.get("rotation").y)
	for pitch: float in aim_trace_pitches:
		player.call("debug_look", yaw, pitch)
		for _settle: int in AIM_STOP_SETTLE:
			await get_tree().process_frame
		var total: float = 0.0
		var worst: float = -1.0
		var best: float = 1.0e9
		var last: Vector2 = Vector2.ZERO
		var roll: float = 0.0
		var counted: int = 0
		for _sample: int in AIM_STOP_SAMPLES:
			await get_tree().process_frame
			# The pitch is re-asserted every frame: the lens is a spring on a
			# remote copy and a probe that set it once would be measuring the
			# decay, not the hold.
			player.call("debug_look", yaw, pitch)
			var probe: Dictionary = _aim_sample()
			if probe.is_empty():
				continue
			var offset: Vector2 = probe["offset"]
			if is_nan(offset.x):
				continue
			var miss: float = offset.length()
			total += miss
			worst = maxf(worst, miss)
			best = minf(best, miss)
			last = offset
			roll = float(probe["roll"])
			counted += 1
		if counted == 0:
			print("[AimTrace] %8.2f   the barrel does not point forward at all" % pitch)
			continue
		if _aim_overlay != null:
			_aim_overlay.caption = "pitch %+.2f rad   %dx%d" % [pitch, view.x, view.y]
		await RenderingServer.frame_post_draw
		var shot: String = "%s/aim_%dx%d_p%s.png" % [aim_trace_dir, view.x, view.y,
			String("%+.2f" % pitch).replace(".", "").replace("+", "p").replace("-", "m")]
		get_viewport().get_texture().get_image().save_png(shot)
		print("[AimTrace] %8.2f %8.1f %8.1f %8.1f %8.1f %8.1f %8.2f  %s" % [
			pitch, total / float(counted) * 100.0, worst * 100.0, best * 100.0,
			last.x * 100.0, last.y * 100.0, roll, shot.get_file()])
	print("[AimTrace] done")
	get_tree().quit()


## `--aimdrive`. A mouse that never stops and a body that never stops, driven
## through `Player.debug_look` and `hold_forward` — the same two paths a human
## uses. Two incommensurable frequencies per axis so the motion never repeats
## inside a capture and never settles into a pose the hold could be lucky at.
func _advance_aim_drive(delta: float) -> void:
	if not aim_drive:
		return
	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		return
	_aim_clock += delta
	if _aim_clock < 2.0:
		# Let the layer build and the pose settle before the mouse starts.
		hold_forward = true
		return
	var t: float = _aim_clock - 2.0
	player.call("debug_look",
			1.10 * sin(t * 0.83) + 0.30 * sin(t * 3.10),
			1.35 * sin(t * 0.57) + 0.10 * sin(t * 2.70))
	# Walk in bursts rather than continuously. Held down, the avatar simply pins
	# itself against the first wall it finds and stays there — so the whole
	# capture is of a TUCKED weapon, which is deliberately not aimed, and the
	# trace measures the wall-probe instead of the hold. Six seconds on, three
	# off: enough walking for the bob to matter, enough pacing to get off the wall.
	hold_forward = fmod(t, 9.0) < 6.0
	if aim_strip_dir.is_empty() or _aim_strip_taken >= aim_strip_frames:
		return
	_aim_strip_frame += 1
	if _aim_strip_frame % aim_strip_every != 0:
		return
	_save_aim_strip_frame()


func _save_aim_strip_frame() -> void:
	_aim_strip_taken += 1
	var index: int = _aim_strip_taken
	if index == 1:
		DirAccess.make_dir_recursive_absolute(aim_strip_dir)
	if _aim_overlay != null:
		_aim_overlay.caption = "motion %02d" % index
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"%s/strip_%02d.png" % [aim_strip_dir, index])
	if index >= aim_strip_frames:
		print("[AimTrace] strip: wrote %d frames to %s" % [index, aim_strip_dir])


## The annotated trace itself: the barrel line, drawn into the frame it is wrong
## in, next to the reticle it is supposed to be on.
##
## Everything is drawn from the LIVE camera each frame — the projection, the
## reticle, and the aim point twelve metres down the sight line — so the picture
## cannot disagree with the numbers and neither can be stale.
##
## The reticle is drawn TWICE on purpose: once at the unprojected aim point
## (where the 3D camera says the centre of the sight line lands) and once at the
## geometric centre of the canvas (where the HUD's own dot is). They coincide on
## a healthy build at every aspect, and the day they do not, the picture says so
## instead of an aspect bug hiding inside an aim bug.
class AimOverlay extends Control:
	## Stamped into the corner of the shot, so a directory of PNGs is
	## self-describing.
	var caption: String = ""

	const BORE_COLOR: Color = Color(1.0, 0.35, 0.2, 0.95)
	const RETICLE_COLOR: Color = Color(0.3, 1.0, 0.5, 0.95)
	const MISS_COLOR: Color = Color(1.0, 0.85, 0.2, 0.95)
	const CANVAS_COLOR: Color = Color(0.35, 0.75, 1.0, 0.7)

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(true)

	func _process(_delta: float) -> void:
		queue_redraw()

	## Viewport pixels -> this Control's own drawing units.
	##
	## `unproject_position` answers in the 3D viewport's pixels; a Control under
	## `canvas_items` stretch draws in whatever units its canvas transform says,
	## and its `size` is reported in a THIRD space (the design canvas). Guessing
	## the ratio from `size / window` is the obvious conversion and it is wrong —
	## it put the reticle marker at a quarter scale in the top-left corner of the
	## first trace this instrument ever took. `get_global_transform_with_canvas`
	## is the engine's own answer to the same question and cannot disagree with
	## the renderer. The instrument for an aspect complaint does not get to have
	## an aspect bug.
	func _to_canvas(point: Vector2) -> Vector2:
		return get_global_transform_with_canvas().affine_inverse() * point

	## The true centre of the frame, in those same units. Where the HUD's own
	## reticle dot is drawn, and where the sight line must land.
	func _screen_centre() -> Vector2:
		return _to_canvas(Vector2(get_window().size) * 0.5)

	func _draw() -> void:
		var camera: Camera3D = get_viewport().get_camera_3d()
		var player: Node = Net.get_player(Net.local_id())
		if camera == null or player == null or not is_instance_valid(player):
			return
		var font: Font = ThemeDB.fallback_font
		var window: Vector2i = get_window().size
		# Sized off the frame, not off a constant: a 15 px stamp is a caption at
		# 720 and a rumour at 1440, and these traces exist to be read.
		var pt: int = maxi(15, int(float(window.y) / 52.0))
		var lens: Transform3D = camera.global_transform
		var grip_world: Vector3 = player.call("hold_world_point")
		var muzzle_world: Vector3 = player.call("muzzle_world_point")
		var to_lens: Transform3D = lens.affine_inverse()
		var grip: Vector3 = to_lens * grip_world
		var muzzle: Vector3 = to_lens * muzzle_world
		var offset: Vector2 = Debug.bore_offset(grip, muzzle, Debug.AIM_RANGE)
		var tuck: float = float(player.call("weapon_tuck"))

		# The sight line's own point at the trace range, and the barrel line's.
		# Both are taken back out to WORLD space and unprojected, rather than
		# drawn from canvas arithmetic, so the picture is the camera's own answer.
		var aim_world: Vector3 = lens * Vector3(0.0, 0.0, -Debug.AIM_RANGE)
		var centre: Vector2 = _screen_centre()
		if not camera.is_position_behind(aim_world):
			centre = _to_canvas(camera.unproject_position(aim_world))

		# The barrel line, extended well past the trace range so its direction is
		# legible even when the miss is small.
		var span: Vector3 = muzzle_world - grip_world
		if span.length_squared() > 1.0e-10:
			var far: Vector3 = grip_world + span.normalized() * 40.0
			if not camera.is_position_behind(grip_world) \
					and not camera.is_position_behind(far):
				var a: Vector2 = _to_canvas(camera.unproject_position(grip_world))
				var b: Vector2 = _to_canvas(camera.unproject_position(far))
				draw_line(a, b, BORE_COLOR, 2.0, true)
				draw_circle(a, 4.0, BORE_COLOR)

		# Where the barrel actually arrives at the trace range, and how far that
		# is from where the player is looking.
		if not is_nan(offset.x):
			var hit_world: Vector3 = lens * Vector3(offset.x, offset.y, -Debug.AIM_RANGE)
			if not camera.is_position_behind(hit_world):
				var hit: Vector2 = _to_canvas(camera.unproject_position(hit_world))
				draw_line(centre, hit, MISS_COLOR, 2.0, true)
				draw_arc(hit, 9.0, 0.0, TAU, 24, MISS_COLOR, 2.0, true)
				draw_string(font, hit + Vector2(float(pt), -float(pt) * 0.5),
						"%.1f cm @ %.0f m" % [offset.length() * 100.0, Debug.AIM_RANGE],
						HORIZONTAL_ALIGNMENT_LEFT, -1.0, pt, MISS_COLOR)

		# The reticle: the camera's own centre, then the canvas's. See the class
		# comment for why both are on the page.
		for arm: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			draw_line(centre + arm * 9.0, centre + arm * 30.0, RETICLE_COLOR, 2.0, true)
		draw_arc(_screen_centre(), 36.0, 0.0, TAU, 40, CANVAS_COLOR, 1.5, true)

		var lines: PackedStringArray = PackedStringArray([
			caption,
			"%dx%d  aspect %.3f  fov %.1f" % [window.x, window.y,
				float(window.x) / maxf(float(window.y), 1.0), camera.fov],
			"grip  %6.3f %6.3f %6.3f" % [grip.x, grip.y, grip.z],
			"bore  %.2f deg   miss %.1f cm%s" % [
				rad_to_deg(acos(clampf((muzzle - grip).normalized().dot(Vector3.FORWARD),
						-1.0, 1.0))),
				(offset.length() * 100.0) if not is_nan(offset.x) else -1.0,
				# A tucked weapon is aimed at the floor ON PURPOSE. Said on the
				# picture, or the next person reads a working wall-probe as a
				# broken convergence — which is what happened here once already.
				("   TUCK %.2f (aimed low on purpose)" % tuck) if tuck > 0.01 else ""],
		])
		var y: float = float(pt) * 1.6
		for line: String in lines:
			draw_string(font, _to_canvas(Vector2(float(pt) * 1.4, y)), line,
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, pt, RETICLE_COLOR)
			y += float(pt) * 1.3


# ------------------------------------------------------- THE PARTITION selftest --
#
# Appended section (this file is append-only during parallel work). Everything
# below is about the hub: what its flow guarantees, and what its safety law
# obligations are.
#
# The claims here are deliberately the ones a screenshot CANNOT make. Whether the
# room looks right is a capture's job; whether a crew can be stranded in it, and
# whether the machinery in it can strobe, are properties of numbers, and numbers
# are what a selftest is for.

## `--selftest`, THE PARTITION section. Returns the failure count, the same
## contract `_vertical_selftest` and `_cartography_selftest` follow.
func _hub_selftest() -> int:
	var failures: int = 0

	# SAFETY LAW (DESIGN.md pillar 7, WCAG 2.3.1). The hub added three new
	# temporally-varying emitters — the rig's armed beat, the arrival pad's settle
	# pulse and MOTHER's lens breath — and every one of them is a NEW flash source
	# that the caps have to bound. Measured at their loudest: Reduced Flashing OFF,
	# countdown at its most urgent. Anything at or under 3 Hz passes.
	for probe: Dictionary in [
			{"n": "RIG-ARM", "hz": DropInterface.ARM_PULSE_HZ_MAX},
			{"n": "RIG-IDLE", "hz": DropInterface.ARM_PULSE_HZ_MIN},
			{"n": "ARRIVAL", "hz": ArrivalPad.SETTLE_PULSE_HZ},
			{"n": "LENS", "hz": MotherLens.BREATH_HZ}]:
		var hz: float = float(probe["hz"])
		if hz <= 3.0:
			print("[SelfTest] PASS  flash-rate %-8s: %.2f Hz <= 3.0 Hz (hub)" % [
				String(probe["n"]), hz])
		else:
			failures += 1
			printerr("[SelfTest] FAIL  flash-rate %s: %.2f Hz > 3.0 Hz (WCAG 2.3.1)" % [
				String(probe["n"]), hz])

	# And the ramp has to ramp the right way. A rig whose beat SLOWED as the
	# countdown closed would be reading backwards, and the cap check above would
	# still have passed it.
	if DropInterface.ARM_PULSE_HZ_MIN < DropInterface.ARM_PULSE_HZ_MAX:
		print("[SelfTest] PASS  rig urgency: beat ramps %.2f -> %.2f Hz as it closes" % [
			DropInterface.ARM_PULSE_HZ_MIN, DropInterface.ARM_PULSE_HZ_MAX])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  rig urgency: beat does not tighten toward the commit")

	# THE 20-SECOND RULE — the hub's version of the solo invariant.
	#
	# DESIGN.md's solo invariant says everything must be fully doable alone; a
	# staging area's version of that is that it must never become a lobby tax. The
	# budget the feature was specified against is BOOT TO DIVE IN 20 SECONDS if a
	# solo player hustles, and the part of that this build owns is everything after
	# the hub is standing: walk from the spawn to the rig, hold the lever, ride the
	# solo countdown. Measured against the real numbers rather than against a
	# stopwatch on one machine.
	var walk: float = PartitionBuilder.SPAWNS[0].distance_to(PartitionBuilder.RIG) \
			/ Player.SPRINT_SPEED
	var ritual: float = walk + Balance.SHAFT_CHANNEL_TIME + Run.INJECT_COUNTDOWN_SOLO
	# 12 s leaves eight for the engine to boot, the menu to come up and a human to
	# click HOST — which is the half of the budget this file cannot measure.
	if ritual <= 12.0:
		print("[SelfTest] PASS  hub 20s rule: spawn->dive %.2fs (sprint %.2f + channel %.2f + commit %.2f)" % [
			ritual, walk, Balance.SHAFT_CHANNEL_TIME, Run.INJECT_COUNTDOWN_SOLO])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  hub 20s rule: spawn->dive %.2fs > 12.0s — the hub is a lobby tax" % ritual)

	# The solo countdown must be SHORTER than the crew one. Both exist so a commit
	# can be stopped; a solo agent has nobody to stop it for, so making them wait
	# the crew's window is pure friction.
	if Run.INJECT_COUNTDOWN_SOLO < Run.INJECT_COUNTDOWN and Run.INJECT_COUNTDOWN_SOLO > 0.0:
		print("[SelfTest] PASS  commit windows: solo %.1fs < crew %.1fs, both abortable" % [
			Run.INJECT_COUNTDOWN_SOLO, Run.INJECT_COUNTDOWN])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  commit windows: solo %.1f / crew %.1f" % [
			Run.INJECT_COUNTDOWN_SOLO, Run.INJECT_COUNTDOWN])

	# NOBODY IS EVER STRANDED. A run that ends has to bring the crew home on its
	# own, whether or not anybody presses the button — the debrief is a screen with
	# a live socket behind it, and the version of this that shipped before the hub
	# ended the session outright rather than leaving anyone there.
	if Run.HUB_RETURN_DELAY > Balance.EXFIL_COUNTDOWN * 0.0 and Run.HUB_RETURN_DELAY <= 60.0:
		print("[SelfTest] PASS  hub homecoming: unattended debrief returns after %.0fs" % [
			Run.HUB_RETURN_DELAY])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  hub homecoming: %.1fs is not a return anybody waits for" % [
			Run.HUB_RETURN_DELAY])

	# THE MUSTER PAD HAS TO CONTAIN THE CREW. Every spawn point must be far enough
	# from the rig that the crew does not start already mustered (the ritual would
	# be armable before anyone had walked anywhere), and near enough that reaching
	# it is a walk and not an expedition. The pad's own radius is the yardstick.
	var radius: float = Balance.SHAFT_MUSTER_RADIUS
	var worst_near: float = 999.0
	var worst_far: float = 0.0
	for spawn: Vector3 in PartitionBuilder.SPAWNS:
		var d: float = Vector2(spawn.x - PartitionBuilder.RIG.x,
				spawn.z - PartitionBuilder.RIG.z).length()
		worst_near = minf(worst_near, d)
		worst_far = maxf(worst_far, d)
	if worst_near > radius and worst_far < radius * 4.0:
		print("[SelfTest] PASS  hub muster: spawns %.1f-%.1f m from the rig (pad %.1f m)" % [
			worst_near, worst_far, radius])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  hub muster: spawns %.1f-%.1f m against a %.1f m pad" % [
			worst_near, worst_far, radius])

	# DETERMINISM. The Partition must not be able to move the generator. It is
	# authored, so the claim is simply that building it consumes nothing from the
	# shared streams — checked by taking the next number out of the generator's own
	# stream before and after, which is the only thing "the RNG did not advance"
	# can mean. A hub that quietly rolled one die here would shift every layer the
	# crew injected into afterwards, and `--dumplayer` (a fresh process) would
	# never catch it.
	Rng.set_run_seed(4242)
	var before: int = Rng.stream("layer").randi()
	var probe_hub: PartitionBuilder = PartitionBuilder.new()
	# Added to the tree rather than `build()`-ed in the air: `GeometryKit._ready`
	# builds, and the light rig aims its fixtures with `look_at`, which needs a
	# global transform. Built detached it still produces the right answer to the
	# question being asked here, but it produces it underneath forty engine errors,
	# and a selftest that shouts while it passes is one nobody reads.
	get_tree().root.add_child(probe_hub)
	var after: int = Rng.stream("layer").randi()
	var replay: RandomNumberGenerator = Rng.fresh("layer")
	replay.randi()
	var expected: int = replay.randi()
	probe_hub.queue_free()
	if after == expected:
		print("[SelfTest] PASS  hub determinism: building the Partition consumed 0 draws (%d -> %d)" % [
			before, after])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  hub determinism: the Partition advanced the shared RNG stream")

	return failures


# ===================== FIDELITY PASS — the Isolation benchmark ================
#
# Appended, never interleaved (CLAUDE.md: this file is append-only during
# parallel work). Two claims are asserted here and both of them are claims a
# capture cannot settle:
#
#   1. THE NEW FLASH SOURCE IS CAPPED. The fidelity pass adds a failing tripod
#      work light — a temporal-flash effect on a WORLD LIGHT, which is exactly
#      the class of thing DESIGN.md pillar 7 was written about. The existing
#      flash-rate block already measures the DYING and ARC curves; this asserts
#      that the work light actually USES one of them rather than having grown a
#      curve of its own, that the curve it uses never blacks the fixture out,
#      and that Reduced Flashing removes the swing entirely. A cap that is only
#      true because somebody remembered to reuse the right enum is a cap that
#      breaks the first time somebody does not.
#
#   2. THE INSTRUMENT ZONE IS CENTRED. The PT3 report was "the ui still looked
#      anchored to the left... the minimap was on the left instead of on the
#      very right", on a 3440x1440 panel. It was investigated with `--ui-audit`
#      and there was no arithmetic bug — the box was centred to the pixel and
#      the complaint was about the WIDTH of the composed zone, which is now a
#      setting. This locks the half that was never broken, at the two aspects
#      the user actually owns, so a future widening cannot quietly reintroduce
#      the bug the report was mistaken for.

## The work light's fault curve, and the zone geometry. Returns the failure count.
func _fidelity_selftest() -> int:
	var failures: int = 0

	# --- 1a. the work light reuses a curve the flash-rate block already proves --
	var lamp_mode: int = int(FlickerLight.Mode.ARC)
	var meas: Dictionary = _measure_flash_hz(lamp_mode)
	var hz: float = float(meas["peak_hz"])
	if hz <= 3.0:
		print("[SelfTest] PASS  work-light flicker: ARC curve peaks at %.2f Hz <= 3.0 Hz" % hz)
	else:
		failures += 1
		printerr("[SelfTest] FAIL  work-light flicker: %.2f Hz > 3.0 Hz (WCAG 2.3.1)" % hz)

	# --- 1b. and it browns out rather than blacking out ----------------------
	# A practical is often the ONLY light in the room it stands in. A fault that
	# takes it to zero takes the room to zero, twice a second, which is a worse
	# experience than the fault is worth even when it is inside the rate cap.
	var floor_level: float = 1.0
	var ceiling_level: float = 0.0
	for i: int in 4000:
		var v: float = FlickerLight.level(lamp_mode, float(i) * 0.005, 0.0)
		floor_level = minf(floor_level, v)
		ceiling_level = maxf(ceiling_level, v)
	if floor_level >= 0.5 and ceiling_level <= 1.0:
		print("[SelfTest] PASS  work-light floor: fault dips to %.2f of base, never dark" % floor_level)
	else:
		failures += 1
		printerr("[SelfTest] FAIL  work-light floor: range %.2f..%.2f (want >= 0.50, <= 1.00)" % [
			floor_level, ceiling_level])

	# --- 1c. Reduced Flashing removes the swing ------------------------------
	# Restored in a `for` with no early exit so a failure cannot leave the whole
	# process running with the accessibility switch flipped.
	var before_scale: float = A11y.flash_scale
	A11y.flash_scale = 0.0
	var calm_lo: float = 1.0
	var calm_hi: float = 0.0
	for i: int in 4000:
		var v: float = FlickerLight.level(lamp_mode, float(i) * 0.005, 0.0)
		calm_lo = minf(calm_lo, v)
		calm_hi = maxf(calm_hi, v)
	A11y.flash_scale = before_scale
	if calm_hi - calm_lo <= 0.001:
		print("[SelfTest] PASS  work-light calmed: Reduced Flashing swing %.4f (flat)" % [
			calm_hi - calm_lo])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  work-light calmed: swing %.4f under Reduced Flashing" % [
			calm_hi - calm_lo])

	# --- 2. the instrument zone, at the user's two aspects -------------------
	for view: Vector2 in [Vector2(1280.0, 720.0), Vector2(1720.0, 720.0),
			Vector2(2560.0, 720.0)]:
		for width: float in [0.0, 0.5, 1.0]:
			var rect: Rect2 = UiFx.instrument_rect(view, width)
			var left: float = rect.position.x
			var right: float = view.x - rect.end.x
			if absf(left - right) > 1.0:
				failures += 1
				printerr("[SelfTest] FAIL  hud zone %dx%d @ %d%%: left %.1f != right %.1f" % [
					int(view.x), int(view.y), int(width * 100.0), left, right])
				continue
			# And it must never reach past the glass. TUBE_EDGE is what the barrel
			# warp and the bezel falloff actually eat; a zone wider than that is a
			# zone with readouts in the part of the tube that has no picture.
			var margin: float = UiFx.glass_margin_x(view)
			if left < margin - 1.0:
				failures += 1
				printerr("[SelfTest] FAIL  hud zone %dx%d @ %d%%: inset %.1f < glass %.1f" % [
					int(view.x), int(view.y), int(width * 100.0), left, margin])
	print("[SelfTest] PASS  hud zone: centred at 16:9 / 21:9 / 32:9, at 0 / 50 / 100%")

	# The ultrawide default. The user owns a 21:9 and a 32:9 and asked for the
	# map in the true corner; a fresh profile has to give them that without
	# opening a menu, and a 16:9 profile has to be left alone.
	var auto_169: float = Screen.auto_hud_width(16.0 / 9.0)
	var auto_219: float = Screen.auto_hud_width(3440.0 / 1440.0)
	var auto_329: float = Screen.auto_hud_width(5120.0 / 1440.0)
	if auto_169 <= 0.001 and auto_219 >= 0.55 and auto_329 >= 0.85:
		print("[SelfTest] PASS  hud auto-width: 16:9 %.2f, 21:9 %.2f, 32:9 %.2f" % [
			auto_169, auto_219, auto_329])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  hud auto-width: 16:9 %.2f, 21:9 %.2f, 32:9 %.2f" % [
			auto_169, auto_219, auto_329])

	# --- 3. the darkness guard -----------------------------------------------
	# The one number the whole dusty-air feature is allowed to move, and the
	# bound it is allowed to move it by. If a future tuning pass pushes the fog
	# density past a quarter above baseline, the blacks start lifting and the
	# ambush-readability A/B stops being a formality.
	var thin: float = DustAir.layer_fog_density(0.030, 1)
	var thick: float = DustAir.layer_fog_density(0.030, 25)
	if thin >= 0.030 * 0.85 and thick <= 0.030 * 1.30 and thick > thin:
		print("[SelfTest] PASS  fog ramp: %.4f at layer 1 -> %.4f at layer 25 (base 0.0300)" % [
			thin, thick])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  fog ramp: %.4f .. %.4f outside the darkness guard" % [
			thin, thick])

	# And that BASELINE is still literally the shipped renderer. The tier is a
	# promise about the 60 fps target, and a preset that quietly acquires an
	# expensive row is a promise nobody notices being broken.
	var base: Dictionary = Photonics.preset(Photonics.Tier.BASELINE)
	if not bool(base["sdfgi"]) and int(base["area_light_budget"]) == 0 \
			and bool(base["ssil"]) and bool(base["ssao"]) \
			and int(base["volumetrics"]) == int(Photonics.Volumetrics.STANDARD):
		print("[SelfTest] PASS  photonics BASELINE: no GI, no area lights, shipped air")
	else:
		failures += 1
		printerr("[SelfTest] FAIL  photonics BASELINE has drifted from the shipped renderer")

	return failures


# ------------------------------------------------------- M7 subroutines & juice --
#
# APPENDED, per CLAUDE.md's shared-instrument rule: this section adds, and does
# not reorder or reformat anything above it. Three in-place edits were
# unavoidable and are marked at their sites — a `match` arm block in
# `_parse_args`, one line in `_apply_program_overrides`, one in
# `_on_automation_player_ready`, and the aggregation line in `_balance_selftest`.
#
# The flags:
#
#   --subroutine ID[:TIER]   compile a subroutine and slot it, for this session
#                            only. Sandboxes the program file, exactly like
#                            `--modules`: measuring a kit is not owning one.
#                            e.g. `--subroutine stack_pulse:1`
#   --cast [delay]           run the slotted subroutine `delay` seconds after
#                            the local avatar spawns. Drives the same path the
#                            Q key does, so the host's ownership, cooldown,
#                            Cycles and proximity checks are all exercised
#                            rather than bypassed.
#   --cast-every SECONDS     keep casting on that interval. What a JUICE REEL
#                            burst is armed against: the cooldowns are 4-30 s,
#                            and a shutter cannot be aimed at a single 0.4 s
#                            effect by hand.

## `--subroutine`. Applied through `Subs.force`, never written to the file.
var subroutine_spec: String = ""
## `--cast [delay]` — seconds after spawn, or -1 for off.
var _cast_delay: float = -1.0
## `--cast-every SECONDS` — 0 for a single cast.
var _cast_every: float = 0.0


## Drives the same path the Q key does. Deliberately goes through
## `Player.run_subroutine` rather than calling `Subs.request_cast` directly: the
## point of an automated cast is to exercise the real chain (input -> local
## pre-check -> host validation -> echo -> fx), and a probe that skipped to the
## middle of it would photograph an effect nobody could reach in a game.
func _cast_later(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	while true:
		var player: Node = Net.get_player(Net.local_id())
		var avatar: Player = player as Player
		if avatar == null or not is_instance_valid(avatar):
			push_warning("[Debug] --cast skipped: no local player")
			return
		print("[Debug] running subroutine '%s' (tier %d, %.0f cycles, pool %.0f)" % [
			Subs.local_equipped(), Subs.local_tier(),
			Subs.cost_of(Net.local_id(), Subs.local_equipped()), Run.cycles])
		avatar.run_subroutine()
		if _cast_every <= 0.0:
			return
		await get_tree().create_timer(_cast_every).timeout


## M7 safety + economy checks.
##
## The safety half is the milestone's non-negotiable: M7 adds five new light
## sources a player can fire at will (four cast blooms and a barrier ripple) plus
## a shatter coal, and DESIGN.md pillar 7 does not have an exception for pretty
## things. Each is asserted against the WCAG 2.3.1 three-flashes-a-second ceiling
## the same way the PT1 hit flash is: analytically, against the FASTEST RATE THE
## GAME CAN PRODUCE, so a future cooldown cut fails here rather than in a living
## room.
##
## The economy half asserts the things a balance pass could silently break: that
## a cast is meaningfully expensive against the retuned drain, that no subroutine
## is free, and that the cheapest tier-1 price is reachable inside an early run.
func _subroutine_selftest() -> int:
	var failures: int = 0

	# --- SAFETY: the cast-bloom governor ------------------------------------
	#
	# The blooms are rate-limited by `Fx.flash_gate()`, whose interval is
	# `Balance.SUB_FLASH_MIN_INTERVAL`. The trigger rate a player can actually
	# achieve is 1 / (shortest cooldown in the kit), which is far slower — but the
	# governor is what makes the CEILING true regardless, so both are checked and
	# the binding one is reported.
	var fastest_cd: float = 1e9
	for id: String in Balance.SUBROUTINE_TRACKS:
		for tier: int in range(1, Subs.tier_count(id) + 1):
			fastest_cd = minf(fastest_cd, float(Subs.value_at(id, "cooldown", tier)))
	var cast_hz: float = 1.0 / maxf(fastest_cd, 0.0001)
	var bloom_hz: float = minf(cast_hz, 1.0 / Balance.SUB_FLASH_MIN_INTERVAL)
	if bloom_hz <= 3.0:
		print("[SelfTest] PASS  flash-rate CAST  : peak %.2f Hz <= 3.0 Hz (trigger %.2f Hz, governor %.2f Hz)" % [
			bloom_hz, cast_hz, 1.0 / Balance.SUB_FLASH_MIN_INTERVAL])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  flash-rate CAST: %.2f Hz exceeds the WCAG ceiling" % bloom_hz)

	# --- SAFETY: the barrier ripple governor --------------------------------
	#
	# A shell inside a Scrubber pack is struck as fast as the pack can lunge, and
	# every strike ripples it. The pack's own floor is SCRUBBER_LUNGE_TIME +
	# SCRUBBER_RECOVER_TIME per creature, but several creatures interleave — so
	# the honest worst case is "as fast as hits arrive", and only the governor
	# bounds it. Checked against the governor alone, which is the conservative
	# reading.
	var ripple_hz: float = 1.0 / maxf(ChecksumBarrier.HIT_FLASH_MIN_INTERVAL, 0.0001)
	if ripple_hz <= 3.0:
		print("[SelfTest] PASS  flash-rate SHELL : peak %.2f Hz <= 3.0 Hz (governed, unbounded trigger)" % ripple_hz)
	else:
		failures += 1
		printerr("[SelfTest] FAIL  flash-rate SHELL: %.2f Hz exceeds the WCAG ceiling" % ripple_hz)

	# --- SAFETY: Reduced Flashing zeroes every new light --------------------
	#
	# The governor bounds the RATE; `A11y.flash_scale` bounds the AMPLITUDE, and
	# the comfort tier has to take all of it to nothing. Every M7 bloom is spelled
	# `energy * Fx.flash_gate() * A11y.flash_scale`, so this asserts the product
	# rather than trusting six call sites to have remembered.
	var lit: float = A11y.flash_scale
	A11y.flash_scale = 1.0
	var bloom_on: float = Balance.SUB_FLASH_ENERGY * A11y.flash_scale
	A11y.flash_scale = 0.0
	var bloom_off: float = Balance.SUB_FLASH_ENERGY * A11y.flash_scale
	var shatter_off: float = Balance.SHATTER_GLOW_ENERGY * A11y.flash_scale
	A11y.flash_scale = lit
	if bloom_on > 0.0 and bloom_off <= 0.0001 and shatter_off <= 0.0001:
		print("[SelfTest] PASS  cast blooms calmed: %.2f at full, %.4f under Reduced Flashing" % [
			bloom_on, bloom_off])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  cast blooms survive Reduced Flashing (%.4f / %.4f)" % [
			bloom_off, shatter_off])

	# --- SAFETY: the shake budget -------------------------------------------
	#
	# "never >2 shakes/s". The governor is `Balance.SHAKE_MIN_INTERVAL`, and the
	# ceiling is the same clamp `Player.add_shake` already applied.
	var shake_hz: float = 1.0 / maxf(Balance.SHAKE_MIN_INTERVAL, 0.0001)
	if shake_hz <= 2.0 and Balance.SHAKE_CEILING <= 1.2:
		print("[SelfTest] PASS  shake budget: %.2f impulses/s <= 2.0, ceiling %.2f" % [
			shake_hz, Balance.SHAKE_CEILING])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  shake budget: %.2f/s (ceiling %.2f)" % [
			shake_hz, Balance.SHAKE_CEILING])

	# --- ECONOMY: power costs breath ----------------------------------------
	#
	# Every subroutine at every tier must cost a MEANINGFUL number of Cycles,
	# expressed in the unit that makes it legible: seconds of solo runtime at the
	# retuned passive drain. The floor is the flare's own cost expressed the same
	# way, halved — anything cheaper than half a flare is not a decision.
	var seconds_per_cycle: float = 1.0 / maxf(Balance.PASSIVE_DRAIN, 0.0001)
	var floor_seconds: float = Balance.FLARE_CYCLE_COST * seconds_per_cycle * 0.5
	var cheapest: float = 1e9
	var cheapest_name: String = ""
	var free_casts: int = 0
	for id: String in Balance.SUBROUTINE_TRACKS:
		for tier: int in range(1, Subs.tier_count(id) + 1):
			var cost: float = float(Subs.value_at(id, "cost", tier))
			if cost <= 0.0:
				free_casts += 1
			var life: float = cost * seconds_per_cycle
			if life < cheapest:
				cheapest = life
				cheapest_name = "%s t%d" % [id, tier]
	if free_casts == 0 and cheapest >= floor_seconds:
		print("[SelfTest] PASS  subroutine cost: cheapest is %s at %.0f s of runtime (floor %.0f s)" % [
			cheapest_name, cheapest, floor_seconds])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  subroutine cost: %d free cast(s), cheapest %.0f s < floor %.0f s" % [
			free_casts, cheapest, floor_seconds])

	# --- ECONOMY: tier 1 is reachable early ---------------------------------
	#
	# DESIGN.md's acquisition rule for the kit is "cheap tier-1 versions early".
	# The cheapest module tier in the game is the reference: at least one
	# subroutine has to be buyable before the cheapest module upgrade, or the kit
	# arrives after the player has stopped needing to learn it.
	var cheapest_module: int = 1 << 30
	for track: String in Balance.MODULE_TRACKS:
		cheapest_module = mini(cheapest_module, Modules.price(track, 0))
	var cheapest_sub: int = 1 << 30
	for id: String in Balance.SUBROUTINE_TRACKS:
		cheapest_sub = mini(cheapest_sub, Subs.price(id, 0))
	if cheapest_sub <= cheapest_module:
		print("[SelfTest] PASS  subroutine entry: cheapest sub %d data <= cheapest module %d" % [
			cheapest_sub, cheapest_module])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  subroutine entry: cheapest sub %d data > cheapest module %d" % [
			cheapest_sub, cheapest_module])

	# --- THE SOLO INVARIANT + the killability law ---------------------------
	#
	# Two design laws, asserted as data rather than as prose. A subroutine may
	# never deal damage (STACK PULSE is control, and a `damage` key appearing in
	# the catalogue would be the first sign somebody had changed their mind), and
	# the slot must default to EMPTY on a fresh profile — a kit that a new program
	# starts with would make it equipment rather than a purchase, and would make
	# "abilities are power, not keys" impossible to check.
	var damage_keys: int = 0
	for id: String in Balance.SUBROUTINE_TRACKS:
		if (Subs.definition(id) as Dictionary).has("damage"):
			damage_keys += 1
	if damage_keys == 0:
		print("[SelfTest] PASS  killability law: no subroutine deals damage (%d in catalogue)" % [
			Balance.SUBROUTINE_TRACKS.size()])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  killability law: %d subroutine(s) declare damage" % damage_keys)

	# --- CATALOGUE SHAPE -----------------------------------------------------
	#
	# Every effect array must have TIERS+1 entries with index 0 = "not compiled",
	# because `value_at` clamps rather than erroring and a short array would
	# silently hand tier 3 the tier-2 number. Cheap to check, impossible to
	# notice by playing.
	var shape_bad: PackedStringArray = PackedStringArray()
	for id: String in Balance.SUBROUTINE_TRACKS:
		var entry: Dictionary = Subs.definition(id)
		var tiers: int = Subs.tier_count(id)
		if tiers != Balance.SUBROUTINE_MAX_TIER:
			shape_bad.append("%s prices=%d" % [id, tiers])
		for key: String in entry.keys():
			if key in ["name", "glyph", "note", "prices"]:
				continue
			var values: Array = entry[key]
			if values.size() != tiers + 1:
				shape_bad.append("%s.%s=%d" % [id, key, values.size()])
	if shape_bad.is_empty():
		print("[SelfTest] PASS  subroutine catalogue: %d subroutines, all arrays %d long" % [
			Balance.SUBROUTINE_TRACKS.size(), Balance.SUBROUTINE_MAX_TIER + 1])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  subroutine catalogue shape: %s" % ", ".join(shape_bad))

	# --- STACK PULSE is control, and the stagger actually stops the machine --
	#
	# A live check rather than a reading of the catalogue, because the property
	# that matters is behavioural: a staggered process is out of `_think`/`_act`
	# for the duration, is shoved if it is light and is NOT shoved if it is heavy,
	# and — the load-bearing half of the killability law — has exactly the same
	# health afterwards as before.
	#
	# Two bare `Antivirus` bodies in the tree, no graph and no world: `stagger()`
	# and its bookkeeping do not touch either, and building a layer to test three
	# assignments would make this a test nobody runs.
	var light: Antivirus = Antivirus.new()
	var heavy: Sentinel = Sentinel.new()
	add_child(light)
	add_child(heavy)
	light.set_health(100.0)
	heavy.set_health(1800.0)
	var hp_before: float = light.health
	light.stagger(1.2, light.global_position + Vector3(0.0, 0.0, -1.0), 3.2)
	heavy.stagger(1.2, heavy.global_position + Vector3(0.0, 0.0, -1.0), 3.2)
	var light_ok: bool = light.staggered() and light.health == hp_before \
			and not light.stagger_mass()
	var heavy_ok: bool = heavy.staggered() and heavy.health == 1800.0 \
			and heavy.stagger_mass()
	light.queue_free()
	heavy.queue_free()
	if light_ok and heavy_ok:
		print("[SelfTest] PASS  stack pulse: light staggered+shoveable, heavy staggered+immovable, 0 damage dealt")
	else:
		failures += 1
		printerr("[SelfTest] FAIL  stack pulse: light=%s heavy=%s (control, not damage)" % [
			str(light_ok), str(heavy_ok)])

	# --- CHECKSUM BARRIER absorbs, and stops absorbing when it is spent -----
	#
	# `take()` is the whole of the shell's contract with the damage path: it eats
	# what it can and returns what got through, and once spent it returns the
	# input untouched so a caller never has to ask whether a barrier exists. Three
	# blows against a tier-1 shell: a Sentinel purge, another purge, and a lunge
	# that must land in full because the shell is gone.
	var shell: ChecksumBarrier = ChecksumBarrier.create(1, 1, Vector3.ZERO,
			Color.WHITE, 3.4, 3.0, float(Subs.value_at("checksum_barrier", "absorb", 1)))
	var first: float = shell.take(Balance.SENTINEL_PURGE_DAMAGE)
	var second: float = shell.take(Balance.SENTINEL_PURGE_DAMAGE)
	var third: float = shell.take(Balance.SCRUBBER_LUNGE_DAMAGE)
	var eaten: float = shell.absorbed
	shell.queue_free()
	if first <= 0.0 and second > 0.0 and is_equal_approx(third, Balance.SCRUBBER_LUNGE_DAMAGE) \
			and is_equal_approx(eaten, 45.0):
		print("[SelfTest] PASS  checksum barrier: ate a full purge, %.0f of a second, then nothing (cap %.0f)" % [
			Balance.SENTINEL_PURGE_DAMAGE - second, eaten])
	else:
		failures += 1
		printerr("[SelfTest] FAIL  checksum barrier: through=%.1f/%.1f/%.1f absorbed=%.1f" % [
			first, second, third, eaten])

	# --- SURGE STEP i-frames are a window, not a flag -----------------------
	#
	# `Antivirus._land_hit` reads `Subs.invulnerable(peer)`, and the one way that
	# could go wrong is a window that never closes. Asserted against the clock the
	# host actually uses.
	var was: Dictionary = Subs._iframes_until.duplicate()
	Subs._iframes_until[9001] = Subs._now() + 0.2
	var immune_now: bool = Subs.invulnerable(9001)
	Subs._iframes_until[9001] = Subs._now() - 0.01
	var immune_after: bool = Subs.invulnerable(9001)
	Subs._iframes_until = was
	if immune_now and not immune_after:
		print("[SelfTest] PASS  surge step i-frames: open inside the window, closed outside it")
	else:
		failures += 1
		printerr("[SelfTest] FAIL  surge step i-frames: now=%s after=%s" % [
			str(immune_now), str(immune_after)])

	return failures


# ----------------------------------------------------------------- M7 reel --
#
#   --reel DIR [every] [count]   save a numbered PNG every `every` rendered
#                                frames, `count` times, and quit.
#   --reel-from N                do not start until frame N.
#
# Why this exists rather than more `--screenshot` runs: every effect in M7 is
# between 0.16 s and 1.35 s long, which at 60 fps is 10 to 81 frames, and a
# shutter aimed at one of them by hand catches the middle of a particle burst
# roughly never. `--screenshot PATH N` can be pointed at frame N exactly — but
# proving that a dash LEAVES A TRAIL, or that a shatter SCATTERS AND FADES, needs
# consecutive frames from ONE run, because the point being made is about time.
#
# The same discipline as `--burst`: read the framebuffer back during the run and
# encode afterwards. Encoding a 3440x1440 PNG inline costs more than a frame, so
# a reel that encoded as it went would be measuring the PNG encoder.
#
# `automated` is true whenever this is set (see `_ready`), so `UiFx.clock()`
# counts FRAMES — which is what makes a reel reproducible: frame 300 of two runs
# of the same command is the same picture, on any machine.

var reel_dir: String = ""
## Rendered frames between saves, how many to save, and when to start.
var reel_every: int = 6
var reel_frames: int = 8
var reel_from: int = 0

var _reel_taken: Array[Image] = []
var _reel_clock: int = 0
var _reel_done: bool = false


func _advance_reel() -> void:
	if reel_dir.is_empty() or _reel_done:
		return
	_reel_clock += 1
	if _reel_clock < reel_from:
		return
	if (_reel_clock - reel_from) % reel_every != 0:
		return
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	_reel_taken.append(viewport.get_texture().get_image())
	if _reel_taken.size() >= reel_frames:
		_reel_done = true
		_write_reel.call_deferred()


func _write_reel() -> void:
	DirAccess.make_dir_recursive_absolute(reel_dir)
	for i: int in _reel_taken.size():
		var path: String = "%s/reel_%02d.png" % [reel_dir, i]
		_reel_taken[i].save_png(path)
		print("[Debug] reel frame %d -> %s" % [i, path])
	print("[Debug] reel complete: %d frames every %d, from frame %d" % [
		_reel_taken.size(), reel_every, reel_from])
	_reel_taken.clear()
	# The reel owns the process lifetime unless `--quit-in` was also given, the
	# same hand-off `_capture` makes with `--screenshot`.
	if auto_quit_after <= 0.0:
		await get_tree().process_frame
		get_tree().quit(0)


# =============================================================================
# ROUND FIVE — THE BORE TRACE. An APPENDED section; nothing above it moved.
# =============================================================================
#
# `--aimtrace` (PT4, above) measures the chord from the grip to the muzzle, and
# `CrewAvatar` used to AIM that same chord — so the two agreed with each other
# perfectly, reported 0.0 cm at seven pitches and two ultrawide aspects, and
# neither of them ever looked at the weapon. On the Surge the grip hangs 12.6 cm
# below the barrel, so that chord rises 13.35 degrees off the thing the player's
# eye is actually reading (the barrel, the receiver, the flat top edge, the sight
# rail — all parallel to `CrewAvatar.BORE_AXIS`, all within 6.4 cm of it).
#
# This section measures the OTHER line: through the muzzle, along the barrel.
# That is the one a silhouette is made of, and it is the one round five aims.
#
# The instrument also drops three targets ON the sight line at 6, 12 and 24 m, so
# the acceptance question ("does the gun BODY read as pointing at the reticle")
# has something in the frame to be right or wrong about, instead of being an
# argument about an empty corridor.

## `--boretrace DIR`. Empty means off.
var bore_trace_dir: String = ""
## The stops, in radians. Fewer than `--aimtrace`'s seven by default: this is a
## sheet a human looks at, and seven ultrawide frames per build per lens value is
## more pictures than anybody compares honestly.
var bore_pitches: Array[float] = [0.0, -0.35, 0.35]
## Where the targets go, in metres down the sight line.
var bore_marks: Array[float] = [6.0, 12.0, 24.0]
## `--gunlens D`: the viewmodel lens for this SESSION only.
##
## Same doctrine as `--ui-scale` and `--captions`: a dev flag is a measuring
## instrument, never a setting that sticks. It writes the static override on
## CrewAvatar and never touches a saved value, so a capture run at 45 degrees
## cannot leave the developer's own game there.
var gun_lens_deg: float = -1.0

## Settle before the first stop, and between stops. Same rule as the aim trace.
const BORE_SETTLE_FRAMES: int = 240
const BORE_STOP_SETTLE: int = 30
## Longer than one loop of `aim_idle`, so the window sees every phase of it.
const BORE_STOP_SAMPLES: int = 120

var _bore_marks: Array[MeshInstance3D] = []


## Where a LINE through `muzzle` along `forward` crosses the plane `range_m`
## ahead of the lens, in the lens's own frame, in metres. `(0, 0)` is the
## reticle. Everything is already in lens space; the caller does that.
##
## The difference from `bore_offset` above is the whole of round five: that one
## takes a direction from two points that are not both on the barrel, this one
## takes the barrel's own axis and asks where the line it defines goes.
static func bore_axis_offset(muzzle: Vector3, forward: Vector3,
		range_m: float) -> Vector2:
	if forward.length_squared() < 1.0e-12:
		return Vector2(NAN, NAN)
	var dir: Vector3 = forward.normalized()
	if dir.z > -0.05:
		return Vector2(NAN, NAN)
	var t: float = (-range_m - muzzle.z) / dir.z
	if t <= 0.0:
		return Vector2(NAN, NAN)
	return Vector2(muzzle.x + t * dir.x, muzzle.y + t * dir.y)


## Both lines, at every range, in one sample. `roll` comes along because a
## silhouette read is roll AND aim, and separating them across two instruments is
## how PT2 spent a round on a cant that was really a convergence.
func _bore_sample() -> Dictionary:
	var player: Node = Net.get_player(Net.local_id())
	if player == null or not is_instance_valid(player):
		return {}
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return {}
	var lens: Transform3D = camera.global_transform.affine_inverse()
	var grip: Vector3 = lens * player.call("hold_world_point")
	var muzzle: Vector3 = lens * player.call("muzzle_world_point")
	var weapon: Basis = lens.basis * player.call("hold_world_basis")
	var axis: Array[Vector2] = []
	var chord: Array[Vector2] = []
	for range_m: float in bore_marks:
		axis.append(bore_axis_offset(muzzle, -weapon.z, range_m))
		chord.append(bore_offset(grip, muzzle, range_m))
	return {
		"axis": axis,
		"chord": chord,
		"roll": rad_to_deg(atan2(weapon.y.x, weapon.y.y)),
		"camera": camera,
	}


## The ANGULAR radius each target ring is drawn at, in degrees, nearest first.
##
## RINGS, and rings of INCREASING angular size with distance, and both choices
## are the difference between a usable sheet and three pictures of one dot.
## Three targets on the same ray are three targets at the same screen point: as
## discs they occlude each other and as same-angle rings they superimpose. Drawn
## like this they nest — a tight ring at 6 m inside a wider one at 12 inside a
## wider one at 24 — so the frame shows the sight line at three depths at once,
## and a ring you can see through never hides the weapon being judged.
const BORE_MARK_DEGREES: Array[float] = [0.9, 1.8, 2.7]

## The targets, re-seated every stop.
##
## Unshaded so they read in a room this dark without lighting it, and `top_level`
## so nothing about the player's frame can drag them off the ray they mark.
## Local, cosmetic, and created only under this flag: they never touch seeded or
## replicated state, so a determinism dump cannot see them.
func _seat_bore_marks(camera: Camera3D) -> void:
	var colours: Array[Color] = [Color(0.35, 1.0, 0.5), Color(1.0, 0.78, 0.25),
			Color(1.0, 0.4, 0.85)]
	for i: int in bore_marks.size():
		var angle: float = BORE_MARK_DEGREES[mini(i, BORE_MARK_DEGREES.size() - 1)]
		var radius: float = bore_marks[i] * tan(deg_to_rad(angle))
		if i >= _bore_marks.size():
			var mesh: TorusMesh = TorusMesh.new()
			mesh.inner_radius = radius * 0.90
			mesh.outer_radius = radius
			var mat: StandardMaterial3D = StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = colours[i % colours.size()]
			mat.disable_receive_shadows = true
			var node: MeshInstance3D = MeshInstance3D.new()
			node.name = "BoreMark%d" % i
			node.mesh = mesh
			node.material_override = mat
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			node.top_level = true
			get_tree().current_scene.add_child(node)
			_bore_marks.append(node)
		# Square to the lens: a torus is built in its own XZ plane, so its axis
		# has to be turned onto the view direction or the ring reads as an ellipse
		# and the sheet is arguing about perspective instead of about the gun.
		_bore_marks[i].global_transform = Transform3D(
				camera.global_transform.basis * Basis(Vector3.RIGHT, PI * 0.5),
				camera.global_position
					- camera.global_transform.basis.z * bore_marks[i])


func _start_bore_trace() -> void:
	DirAccess.make_dir_recursive_absolute(bore_trace_dir)
	var player: Node = null
	for _wait: int in 900:
		await get_tree().process_frame
		player = Net.get_player(Net.local_id())
		if player != null and is_instance_valid(player):
			break
	if player == null or not is_instance_valid(player):
		printerr("[BoreTrace] no local player; nothing to trace")
		get_tree().quit()
		return
	for _settle: int in BORE_SETTLE_FRAMES:
		await get_tree().process_frame

	var view: Vector2i = get_window().size
	var camera: Camera3D = get_viewport().get_camera_3d()
	var lens: float = CrewAvatar.gun_lens_deg()
	print("[BoreTrace] %dx%d  aspect %.3f  world fov %.1f  gun lens %.1f  ranges %s" % [
		view.x, view.y, float(view.x) / maxf(float(view.y), 1.0),
		camera.fov if camera != null else 0.0, lens, str(bore_marks)])
	print("[BoreTrace] %7s %6s %10s %10s %10s %10s %8s" % [
		"pitch", "range", "axis_cm", "axis_max", "chord_cm", "chord_max", "roll"])

	var yaw: float = float(player.get("rotation").y)
	for pitch: float in bore_pitches:
		player.call("debug_look", yaw, pitch)
		for _settle: int in BORE_STOP_SETTLE:
			await get_tree().process_frame
		_seat_bore_marks(get_viewport().get_camera_3d())
		var axis_sum: Array[float] = []
		var axis_max: Array[float] = []
		var chord_sum: Array[float] = []
		var chord_max: Array[float] = []
		for _slot: int in bore_marks.size():
			axis_sum.append(0.0)
			axis_max.append(0.0)
			chord_sum.append(0.0)
			chord_max.append(0.0)
		var roll: float = 0.0
		var counted: int = 0
		for _sample: int in BORE_STOP_SAMPLES:
			await get_tree().process_frame
			player.call("debug_look", yaw, pitch)
			var probe: Dictionary = _bore_sample()
			if probe.is_empty():
				continue
			var axis: Array[Vector2] = probe["axis"]
			var chord: Array[Vector2] = probe["chord"]
			for i: int in bore_marks.size():
				if not is_nan(axis[i].x):
					axis_sum[i] += axis[i].length()
					axis_max[i] = maxf(axis_max[i], axis[i].length())
				if not is_nan(chord[i].x):
					chord_sum[i] += chord[i].length()
					chord_max[i] = maxf(chord_max[i], chord[i].length())
			roll = float(probe["roll"])
			counted += 1
		if counted == 0:
			print("[BoreTrace] %7.2f   no sample" % pitch)
			continue
		for i: int in bore_marks.size():
			print("[BoreTrace] %7.2f %6.1f %10.1f %10.1f %10.1f %10.1f %8.2f" % [
				pitch, bore_marks[i], axis_sum[i] / float(counted) * 100.0,
				axis_max[i] * 100.0, chord_sum[i] / float(counted) * 100.0,
				chord_max[i] * 100.0, roll])
		# The marks are re-seated one last time against the frame that is about
		# to be photographed: the lens breathes, and a target seated 120 frames
		# ago is a target a couple of centimetres off the ray it marks.
		_seat_bore_marks(get_viewport().get_camera_3d())
		await RenderingServer.frame_post_draw
		var shot: String = "%s/bore_%dx%d_lens%02d_p%s.png" % [bore_trace_dir,
			view.x, view.y, int(roundf(maxf(lens, 0.0))),
			String("%+.2f" % pitch).replace(".", "").replace("+", "p").replace("-", "m")]
		get_viewport().get_texture().get_image().save_png(shot)
		print("[BoreTrace] %7.2f  -> %s" % [pitch, shot.get_file()])
	print("[BoreTrace] done")
	get_tree().quit()


# =============================================================================
# ROUND SIX — THE RETICLE PROBE. Appended; nothing above it moved.
# =============================================================================
#
# `--reticleprobe`, and the hypothesis it exists to kill or confirm.
#
# Every aim instrument in this file annotates the frame with ITS OWN projection
# of the camera's forward ray and calls that "the reticle". The player does not
# aim at that. The player aims at the DOT THE HUD DRAWS. If those two pixels are
# not the same pixel, then a weapon that is provably on the camera ray is a
# weapon that is visibly off the crosshair, forever, and no bore measurement ever
# taken in this repo could see it — because every one of them was measured
# against the camera ray it was already on.
#
# Three suspects were named, and all three are structural rather than numeric:
#
#   1. the RETICLE'S CONTAINER. `UiFx.tube_safe_rect` carries a deliberate
#      UPWARD BIAS (`- view.y * 0.012`), and PT2 reparented the HUD's clusters
#      into it. If the reticle rides that box, it is 1.2% of the frame height
#      above the truth — 17 px at 1440, which is 0.89 degrees, which is 19 cm at
#      the convergence distance.
#   2. the CRT TUBE's barrel warp. The HUD renders into a SubViewport and is
#      resampled through `crt.gdshader`. A warp whose fixed point is not the
#      exact centre of the glass moves the dot and nothing else.
#   3. anything applying bob, boot or glitch transforms to the layer the reticle
#      is on.
#
# This measures the answer instead of reading the code, at the aspects the
# complaint came from. Everything is reported in CANVAS units (the space the
# renderer composites in, `stretch/mode=canvas_items`) and again in WINDOW
# pixels, because "17 px" means nothing without saying 17 px of what.

## `--reticleprobe`. Prints the delta and quits.
var reticle_probe: bool = false
## `--chordaim`. Session-only, like every other flag in this file.
var chord_aim: bool = false
## `--stdmaterials`. Session-only.
var std_materials: bool = false
## `--hold x,y,z`. NaN means "leave the constant alone".
var hold_offset: Vector3 = Vector3(NAN, NAN, NAN)

## How far down the sight line the probe's aim point sits. Any distance gives the
## same pixel — that is the point of a ray — so this is only here to be a
## legitimate 3D point rather than a magic centre.
const RETICLE_PROBE_RANGE: float = 12.0
const RETICLE_PROBE_SETTLE: int = 240


## Depth-first search for the drawn reticle, wherever the HUD has put it. Walks
## through SubViewports too, which is not optional: `Hud._build_tube` reparents
## the whole interface INTO one, and a search that stopped at the window would
## report "no reticle" on a perfectly healthy build.
func _find_reticle(node: Node) -> Crosshair:
	var found: Crosshair = node as Crosshair
	if found != null:
		return found
	for child: Node in node.get_children():
		var deep: Crosshair = _find_reticle(child)
		if deep != null:
			return deep
	return null


## The tube's barrel warp, forward: fragment UV -> the source UV it samples.
## Straight out of crt.gdshader, and it has to STAY straight out of it.
static func _tube_warp(uv: Vector2, curvature: float, amount: float) -> Vector2:
	var centred: Vector2 = uv * 2.0 - Vector2.ONE
	var r2: float = centred.dot(centred)
	centred *= 1.0 + curvature * r2 * amount
	return centred * 0.5 + Vector2(0.5, 0.5)


## And backwards, by bisection on the radius: given a point drawn INTO the tube,
## where on the glass does the player see it? This is the direction that matters
## — the reticle is drawn at a source pixel and read at a fragment pixel — and it
## is solved rather than assumed because "the warp obviously fixes the centre" is
## exactly the kind of obvious this round is here to stop trusting.
static func _tube_unwarp(uv: Vector2, curvature: float, amount: float) -> Vector2:
	var target: Vector2 = uv * 2.0 - Vector2.ONE
	var want: float = target.length()
	if want < 1.0e-9:
		return uv
	var dir: Vector2 = target / want
	var lo: float = 0.0
	var hi: float = want + 1.0
	for _step: int in 60:
		var mid: float = (lo + hi) * 0.5
		var mapped: float = mid * (1.0 + curvature * mid * mid * amount)
		if mapped < want:
			lo = mid
		else:
			hi = mid
	return dir * ((lo + hi) * 0.5) * 0.5 + Vector2(0.5, 0.5)


func _run_reticle_probe() -> void:
	var player: Node = null
	for _wait: int in 900:
		await get_tree().process_frame
		player = Net.get_player(Net.local_id())
		if player != null and is_instance_valid(player):
			break
	if player == null or not is_instance_valid(player):
		printerr("[Reticle] no local player")
		get_tree().quit()
		return
	player.call("debug_look", float(player.get("rotation").y), 0.0)
	for _settle: int in RETICLE_PROBE_SETTLE:
		await get_tree().process_frame

	var window: Vector2 = Vector2(get_window().size)
	var canvas: Vector2 = get_viewport().get_visible_rect().size
	var to_window: Vector2 = Vector2(window.x / maxf(canvas.x, 1.0),
			window.y / maxf(canvas.y, 1.0))
	var camera: Camera3D = get_viewport().get_camera_3d()
	print("[Reticle] window %.0fx%.0f  canvas %.1fx%.1f  scale %.4f,%.4f  fov %.1f" % [
		window.x, window.y, canvas.x, canvas.y, to_window.x, to_window.y,
		camera.fov if camera != null else 0.0])
	if camera == null:
		printerr("[Reticle] no camera")
		get_tree().quit()
		return

	# 1. THE TRUTH: where the camera's own forward ray lands, by the camera's own
	#    arithmetic. This is what every aim instrument in this file calls centre.
	var aim_world: Vector3 = camera.global_transform \
			* Vector3(0.0, 0.0, -RETICLE_PROBE_RANGE)
	var ray_px: Vector2 = camera.unproject_position(aim_world)
	var geometric: Vector2 = canvas * 0.5

	# 2. THE DRAWN DOT: the reticle's own centre, put through the engine's own
	#    canvas transform rather than through arithmetic of ours — the same
	#    reasoning AimOverlay._to_canvas records. Inside the tube's SubViewport,
	#    so these are TUBE pixels; the container is PRESET_FULL_RECT with
	#    `stretch`, so tube pixels and canvas pixels are the same size.
	var reticle: Crosshair = _find_reticle(get_tree().root)
	if reticle == null:
		printerr("[Reticle] no Crosshair in the tree")
		get_tree().quit()
		return
	var tube: Vector2 = reticle.get_viewport().get_visible_rect().size
	var dot_px: Vector2 = reticle.get_global_transform_with_canvas() \
			* (reticle.size * 0.5)

	# 3. AND WHAT THE GLASS DOES TO IT. The dot is drawn at a SOURCE pixel of the
	#    tube texture and the player reads it at the FRAGMENT that samples there.
	var curvature: float = 0.055
	var amount: float = UiFx.TUBE_AMOUNT
	var seen_uv: Vector2 = _tube_unwarp(Vector2(dot_px.x / maxf(tube.x, 1.0),
			dot_px.y / maxf(tube.y, 1.0)), curvature, amount)
	var seen_px: Vector2 = Vector2(seen_uv.x * tube.x, seen_uv.y * tube.y)

	var safe: Rect2 = UiFx.tube_safe_rect(canvas)
	print("[Reticle] tube viewport      %.1f x %.1f" % [tube.x, tube.y])
	print("[Reticle] canvas centre      %8.2f %8.2f" % [geometric.x, geometric.y])
	print("[Reticle] camera ray pixel   %8.2f %8.2f" % [ray_px.x, ray_px.y])
	print("[Reticle] drawn dot (source) %8.2f %8.2f" % [dot_px.x, dot_px.y])
	print("[Reticle] drawn dot (seen)   %8.2f %8.2f" % [seen_px.x, seen_px.y])
	print("[Reticle] safe box centre    %8.2f %8.2f   (the upward-biased one)" % [
		safe.position.x + safe.size.x * 0.5, safe.position.y + safe.size.y * 0.5])
	var delta: Vector2 = seen_px - ray_px
	print("[Reticle] DELTA canvas px    %8.2f %8.2f   (len %.3f)" % [
		delta.x, delta.y, delta.length()])
	var win_delta: Vector2 = delta * to_window
	print("[Reticle] DELTA window px    %8.2f %8.2f   (len %.3f)" % [
		win_delta.x, win_delta.y, win_delta.length()])
	# And in the units the complaint is actually about.
	var per_degree: float = canvas.y / maxf(camera.fov, 1.0)
	print("[Reticle] DELTA degrees      %8.4f   -> %.2f cm at %.0f m" % [
		delta.length() / maxf(per_degree, 0.0001),
		tan(deg_to_rad(delta.length() / maxf(per_degree, 0.0001)))
			* RETICLE_PROBE_RANGE * 100.0, RETICLE_PROBE_RANGE])
	print("[Reticle] done")
	get_tree().quit()


# =============================================================================
# ROUND FIVE — THE REFRESH PROBE. Appended; nothing above it moved.
# =============================================================================
#
# `--refreshprobe [seconds]`.
#
# PT4 fixed a flicker that only exists when MORE THAN ONE RENDERED FRAME falls
# inside one physics tick — the hold measured an already-corrected arm and solved
# a second correction onto it, 281 mm of grip travel per frame, alternating. It
# verified the fix SYNTHETICALLY, with `--physics-hz 30`, because nothing in this
# repo could produce a genuinely fast swapchain. The player's panel is a Samsung
# Odyssey G9 and runs to 240.
#
# So this measures the real thing: the rate frames are ACTUALLY delivered at,
# with the vsync left exactly as the session found it (which is why this is not
# `--log-fps` — that one disables vsync on purpose, and a census of an uncapped
# renderer cannot tell you what the compositor is presenting). Alongside it, the
# two numbers that decide whether the hold survives that rate:
#
#   * RENDERS PER PHYSICS TICK, as a histogram. This is the actual hazard. One
#     is the developer's 60/60 machine and is the case that always worked.
#   * GRIP TRAVEL PER RENDERED FRAME, in the lens's own frame, in millimetres.
#     A hold bolted to the lens standing still moves zero. The PT4 bug put 132 mm
#     of median travel here at 30 Hz physics; anything above about 2 mm on a
#     stationary avatar is the pose being solved twice.

## `--refreshprobe [seconds]`. Zero means off.
var refresh_probe: float = 0.0

const REFRESH_SETTLE_FRAMES: int = 180

var _refresh_frames: PackedFloat64Array = PackedFloat64Array()
var _refresh_ticks: PackedInt32Array = PackedInt32Array()
var _refresh_travel: PackedFloat32Array = PackedFloat32Array()


func _run_refresh_probe() -> void:
	var player: Node = null
	for _wait: int in 900:
		await get_tree().process_frame
		player = Net.get_player(Net.local_id())
		if player != null and is_instance_valid(player):
			break
	if player == null or not is_instance_valid(player):
		printerr("[Refresh] no local player")
		get_tree().quit()
		return
	# Standing still and looking level, deliberately: the metric is "does a hold
	# that should not move, move", and a moving avatar has legitimate reasons to.
	player.call("debug_look", float(player.get("rotation").y), 0.0)
	for _settle: int in REFRESH_SETTLE_FRAMES:
		await get_tree().process_frame

	print("[Refresh] display %s   vsync %d   max_fps %d   physics %d Hz" % [
		DisplayServer.get_name(),
		DisplayServer.window_get_vsync_mode() if DisplayServer.get_name() != "headless" else -1,
		Engine.max_fps, Engine.physics_ticks_per_second])

	var camera: Camera3D = get_viewport().get_camera_3d()
	var last_grip: Vector3 = Vector3.ZERO
	var have_last: bool = false
	var started: float = Time.get_ticks_usec() / 1000000.0
	while (Time.get_ticks_usec() / 1000000.0) - started < refresh_probe:
		await get_tree().process_frame
		_refresh_frames.append(Time.get_ticks_usec() / 1000000.0)
		_refresh_ticks.append(Engine.get_physics_frames())
		camera = get_viewport().get_camera_3d()
		if camera != null:
			var grip: Vector3 = camera.global_transform.affine_inverse() \
					* player.call("hold_world_point")
			if have_last:
				_refresh_travel.append((grip - last_grip).length() * 1000.0)
			last_grip = grip
			have_last = true

	var count: int = _refresh_frames.size()
	if count < 8:
		printerr("[Refresh] only %d frames; nothing to report" % count)
		get_tree().quit()
		return
	var span: float = _refresh_frames[count - 1] - _refresh_frames[0]
	var gaps: PackedFloat32Array = PackedFloat32Array()
	for i: int in range(1, count):
		gaps.append(float(_refresh_frames[i] - _refresh_frames[i - 1]))
	var sorted_gaps: Array[float] = []
	for g: float in gaps:
		sorted_gaps.append(g)
	sorted_gaps.sort()
	print("[Refresh] %d frames in %.3f s  ->  %.1f fps mean" % [
		count, span, float(count - 1) / maxf(span, 0.0001)])
	print("[Refresh] frame gap ms: min %.3f  median %.3f  p99 %.3f  max %.3f" % [
		sorted_gaps[0] * 1000.0, sorted_gaps[sorted_gaps.size() / 2] * 1000.0,
		sorted_gaps[mini(int(sorted_gaps.size() * 0.99), sorted_gaps.size() - 1)] * 1000.0,
		sorted_gaps[sorted_gaps.size() - 1] * 1000.0])

	# Renders per physics tick: the number the flicker actually depends on.
	var per_tick: Dictionary = {}
	var seen: Dictionary = {}
	for tick: int in _refresh_ticks:
		seen[tick] = int(seen.get(tick, 0)) + 1
	for tick: int in seen:
		var n: int = int(seen[tick])
		per_tick[n] = int(per_tick.get(n, 0)) + 1
	var keys: Array = per_tick.keys()
	keys.sort()
	var histogram: PackedStringArray = PackedStringArray()
	for n: int in keys:
		histogram.append("%dx:%d" % [n, int(per_tick[n])])
	print("[Refresh] renders per physics tick  %s   (ticks seen %d)" % [
		" ".join(histogram), seen.size()])

	var travel: Array[float] = []
	for t: float in _refresh_travel:
		travel.append(t)
	travel.sort()
	if travel.is_empty():
		print("[Refresh] no grip samples")
	else:
		print("[Refresh] grip travel mm/frame: median %.3f  p95 %.3f  max %.3f" % [
			travel[travel.size() / 2],
			travel[mini(int(travel.size() * 0.95), travel.size() - 1)],
			travel[travel.size() - 1]])
	print("[Refresh] done")
	get_tree().quit()
