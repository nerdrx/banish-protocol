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
			or auto_quit_after > 0.0 or steam_selftest) and not live_input
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
			and not steam_selftest and gun_log_path.is_empty() and burst_dir.is_empty():
		set_process(false)
		return
	if not gun_log_path.is_empty():
		_open_gun_log()
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
	if module_spec.is_empty() and start_archive < 0 and forced_backdoor < 0:
		return
	# Either override makes this session's program a fabrication, and a
	# fabrication must never be written back over the real one — including by the
	# purchases a capture makes while photographing the Compiler.
	GameState.sandboxed = true
	print("[Debug] program file is SANDBOXED for this session: nothing will be saved")
	if not module_spec.is_empty():
		Modules.force_tiers(module_spec)
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
				"resting", "descent", "combat", "damaged", "a11ywarn":
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
			or _terminal_delay >= 0.0 or _tour:
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

	print("[SelfTest] %d check(s) failed" % failures)
	get_tree().quit(1 if failures > 0 else 0)


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
	_sample_fps(delta)
	_sample_gun(delta)
	_advance_burst()
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
	_gun_log.store_line("frame,dt_ms,yaw,pitch,gx,gy,gz,mx,my,mz,roll_deg,bore_deg")


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
	_gun_log.store_line("%d,%.3f,%.5f,%.5f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f" % [
		_gun_frame, delta * 1000.0,
		atan2(-forward.x, -forward.z),
		asin(clampf(forward.y, -1.0, 1.0)),
		grip.x, grip.y, grip.z, muzzle.x, muzzle.y, muzzle.z,
		roll, rad_to_deg(acos(clampf(bore.dot(Vector3.FORWARD), -1.0, 1.0)))])


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var err: Error = image.save_png(screenshot_path)
	if err == OK:
		print("[Debug] screenshot saved: %s (%dx%d)" % [
			screenshot_path, image.get_width(), image.get_height()])
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
