class_name UiFx
extends RefCounted
## Every tunable the M3.8 interface runs on, in one file — the UI's answer to
## Balance.gd.
##
## The premise (DESIGN.md "HUD: diegetic program-shell UI"): the interface is not
## an overlay drawn on top of the game, it is **software running on a hostile
## machine**. It boots. It lags behind your head because it is projected, not
## glued. It flinches when the process it is reporting on takes damage, and it
## starts losing pixels when the pool that powers it runs dry.
##
## Nothing in here is gameplay. Every number is presentation, and every animation
## has an automation-safe path — see `clock()` and `Debug.hud_state`.
##
## Never instantiated; this is a constant namespace.

# --- palette ----------------------------------------------------------------
#
# **Amber phosphor.** M3.8 ran the interface in the same ice-blue teal as
# MOTHER's architecture, which made the HUD read as *part of her system* — as
# though the thing reporting on the intrusion belonged to the thing being
# intruded upon. M4.7 breaks that on purpose.
#
# DESIGN.md's fiction: you are "a human-built agent injected into MOTHER's
# system". Your instrument is therefore human, and old — Northcairn shipped it,
# nobody has revised it since 2061, and it is the same generation of hardware as
# the legacy plates rotting on the walls of the deep layers. It is a monochrome
# amber CRT. Against a world made of teal neon, an amber readout can never be
# mistaken for architecture, at any brightness, at any distance, in any room.
#
# The discipline that keeps it from becoming decoration: **one phosphor, and
# saturated colour means state.** Everything nominal is amber. Warning is a
# hotter, deeper orange. Danger is red and nothing else in the interface is ever
# allowed to be. There is no fourth colour, and the tube's `phosphor_bias` pulls
# unsaturated things further toward amber while leaving the reds alone, so the
# two states that matter are the two that survive.

# ## Whose phosphor?
#
# M4.7 makes the nominal colour **the player's own**. The shell marker you pick
# in the injection console is not only how your crewmates tell you apart in the
# dark any more — it is the phosphor your instrument is coated with. It is your
# hardware; it glows the colour you chose. Amber is simply what Northcairn
# shipped, and what a program file that has never been touched still says.
#
# Everything nominal on the interface reads one of the four tokens below, and all
# four are derived from that one colour, so re-tinting the entire game is a single
# assignment. `WARNING` and `HOSTILE` are **const and stay const**: an alarm state
# that could be recoloured to look like a healthy one is not an alarm state.
# `clamp_phosphor` additionally keeps a player from picking their way into the
# danger band, so red never becomes ambiguous.
#
# These are `static var` rather than `const`. Every existing `UiFx.SYSTEM` call
# site is unchanged by that; what it costs is that a class can no longer bind one
# into a `const` of its own, which is why Hud and AchievementToast now hold theirs
# as plain members.

## What a program file with no colour in it renders as. Northcairn amber.
const PHOSPHOR_DEFAULT: Color = Color(0.98, 0.68, 0.22)

## The colour of a program that is working — the player's own phosphor at rest.
static var SYSTEM: Color = PHOSPHOR_DEFAULT
## Emissive head of the phosphor — a dot the beam has just struck, before it
## decays back. Leading caps, gauge heads, charge peaks.
static var SYSTEM_HOT: Color = Color(1.0, 0.87, 0.58)
## Structure: rules, tick marks, captions that are not saying anything yet.
## Deliberately far down — a dark tube with a few lit things on it reads as an
## instrument; an evenly lit one reads as a menu.
static var DIM: Color = Color(0.62, 0.42, 0.18)
## Body text. Warm off-white, not white: nothing on a phosphor screen is neutral.
static var TEXT: Color = Color(0.93, 0.82, 0.60)

## Under half a pool. Not an emergency, but stop wandering. NEVER re-tinted.
const WARNING: Color = Color(1.0, 0.47, 0.11)
## Hostile, and everything below a quarter pool. The only red on the interface,
## and the reason `clamp_phosphor` exists. NEVER re-tinted.
const HOSTILE: Color = Color(1.0, 0.24, 0.17)

# --- the picker's legal band --------------------------------------------------
#
# Three constraints, and each one is protecting something specific.
#
#   HUE     a wedge either side of pure red is reserved. Red on this interface
#           means quarantine, purge, lethal — and a player whose whole HUD is red
#           cannot be told any of those things. A pick inside the wedge is nudged
#           to the nearer edge rather than rejected, because silently refusing a
#           colour is worse than quietly moving it.
#   SAT     floor, because a desaturated phosphor is grey, and grey on a
#           near-black screen is unreadable. Ceiling stays 1: a fully saturated
#           phosphor is exactly what a real one is.
#   VALUE   floor only. A dark phosphor is an unlit one.
## Degrees either side of hue 0 that belong to the danger state.
const DANGER_BAND_DEG: float = 15.0
const PHOSPHOR_SAT: Vector2 = Vector2(0.45, 1.0)
const PHOSPHOR_VALUE: Vector2 = Vector2(0.70, 1.0)


## Whether `colour` sits in the reserved quarantine band.
static func in_danger_band(colour: Color) -> bool:
	var degrees: float = colour.h * 360.0
	return degrees <= DANGER_BAND_DEG or degrees >= 360.0 - DANGER_BAND_DEG


## Pulls any colour into the legal phosphor band. Idempotent, so a value that has
## already been clamped survives a round trip through the save file unchanged.
static func clamp_phosphor(colour: Color) -> Color:
	var hue: float = colour.h
	if in_danger_band(colour):
		# Out to whichever edge of the wedge is nearer. A pick just above red goes
		# orange; one just below goes magenta. Both stay recognisably close to
		# what the player was reaching for.
		var degrees: float = colour.h * 360.0
		var above: bool = degrees <= DANGER_BAND_DEG
		hue = (DANGER_BAND_DEG if above else 360.0 - DANGER_BAND_DEG) / 360.0
	return Color.from_hsv(hue,
			clampf(colour.s, PHOSPHOR_SAT.x, PHOSPHOR_SAT.y),
			clampf(colour.v, PHOSPHOR_VALUE.x, PHOSPHOR_VALUE.y))


## Re-coats the tube. One call re-tints the HUD, the menu, the Compiler, the
## world-space prompts and every gauge in the game, because all of them read the
## four tokens above and nothing holds a private copy.
##
## The three derived tokens are relatives of the chosen one rather than fixed
## colours: HOT is the same hue driven toward white (a phosphor dot that has just
## been struck is brighter AND less saturated, which is why a pure-hue highlight
## always looks like a sticker), DIM is the same hue with the light taken out of
## it, and TEXT is most of the way to white because body copy has to be read
## rather than admired.
static func set_phosphor(colour: Color) -> void:
	var base: Color = clamp_phosphor(colour)
	SYSTEM = base
	SYSTEM_HOT = Color.from_hsv(base.h, base.s * 0.42, minf(base.v * 1.05 + 0.12, 1.0))
	DIM = Color.from_hsv(base.h, minf(base.s * 1.05, 1.0), base.v * 0.52)
	TEXT = Color.from_hsv(base.h, base.s * 0.32, minf(base.v * 1.02 + 0.06, 1.0))


# --- the tube ---------------------------------------------------------------
#
# The interface renders into its own SubViewport and is composited back through
# `crt.gdshader`. See `Hud._build_tube` for the rig and the shader's own header
# for why the world is deliberately left out of it.

## Phosphor decay half-life, in seconds. The time a lit dot takes to fall to half
## brightness once the beam has left it.
##
## 0.055 is short enough that a moving gauge head trails rather than smears, and
## long enough that a readout changing value visibly ghosts for a frame or three.
## Above ~0.12 the whole screen starts to look like it is underwater.
const PHOSPHOR_HALFLIFE: float = 0.055
## Frames the tube takes to warm up from cold, on injection. A CRT does not turn
## on, it *comes up* — and this is the one place the game can say "your hardware
## is old" without a line of dialogue.
const TUBE_WARMUP: float = 0.9

## Master amplitude for every CRT artefact. Exposed as one number because the
## single most likely thing to go wrong with this look is that it wins: a tube
## you notice is a tube you are reading instead of the game.
const TUBE_AMOUNT: float = 0.85

# --- boot sequence ----------------------------------------------------------

## Total compile time for the shell. Short enough that a player who alt-tabbed
## back in does not wait on it, long enough to read as a machine starting.
const BOOT_DURATION: float = 1.2
## How long one element takes to resolve from flicker to solid.
const BOOT_ELEMENT_FADE: float = 0.26
## The self-test line holds, then fades.
const BOOT_SELFTEST_HOLD: float = 1.5
const BOOT_SELFTEST_FADE: float = 0.7
## Characters per second the self-test line types at.
const BOOT_TYPE_SPEED: float = 46.0
## The Cycles ring spins up from zero and overshoots slightly before settling.
const BOOT_RING_TIME: float = 0.62
const BOOT_RING_OVERSHOOT: float = 0.09

# --- glitch: two vocabularies, two authors -----------------------------------
#
# M4.7 splits what M3.8 treated as one effect, and the split is authorship.
#
#   **ANALOG** — things that happen to YOUR hardware. Taking a hit knocks the
#   tube: horizontal hold slips, one band tears, the phosphor smears sideways.
#   Running out of Cycles is a failing signal: sync loss, snow, the colour
#   draining out of the phosphor before the light does. None of it is digital,
#   because none of it is MOTHER doing anything to you — it is a decades-old
#   monitor being shaken and starved.
#
#   **DIGITAL** — things MOTHER does TO you. The decompile transition into a
#   layer keeps its datamosh, its block displacement and its palette inversion,
#   because that is her taking your process apart, and it should not look like
#   anything your own equipment is capable of.
#
# Keeping those apart costs nothing and buys the player a piece of information
# they will never consciously notice: whether what just went wrong is happening
# to their kit or to them.

## A damage flinch is short. Longer than this and it reads as a broken frame
## rather than as the interface being hit.
const GLITCH_TIME: float = 0.2
## Peak element displacement, in pixels. Two is the whole budget: the HUD has to
## still be readable in the frame it is glitching.
const GLITCH_SHIFT: float = 2.0
## Horizontal-hold slip of the big readouts during a flinch, in pixels.
##
## Sideways only, and in one direction at a time. M3.8 split them chromatically —
## a red ghost one way and a cyan ghost the other — which is a digital fault on a
## screen that has no colour channels to separate. A monochrome tube losing hold
## shears; it does not fringe.
const GLITCH_SLIP: float = 3.6
## How often the corrupted glyphs in the callsign re-roll while glitching.
const GLITCH_GLYPH_INTERVAL: float = 0.045
## The alphabet a corrupting label falls back to.
const CORRUPT_GLYPHS: String = "#%&@$*!?/\\|<>^~+=0X"

# --- low-Cycles degradation -------------------------------------------------

## Pool fraction the interface itself starts failing at. Deliberately below
## Balance.CYCLES_WARNING_FRACTION: the readouts turn amber first and only start
## dropping pixels once the situation is genuinely bad.
const DEGRADE_FRACTION: float = 0.22
## Dead pixels drawn across the readouts at full degradation.
const DEAD_PIXEL_COUNT: int = 34
## Specks and flicker re-roll at this rate rather than per frame — a 60 Hz
## flicker is a strobe, and re-rolling every frame is what makes one.
const DEGRADE_TICK: float = 0.075
## Chance per tick of a horizontal tear across a readout, at full degradation.
const TEAR_CHANCE: float = 0.14

# --- holographic depth ------------------------------------------------------

## Peak parallax lag of the HUD against the lens, in pixels. Above ~8 the HUD
## visibly swims and text starts to smear under TAA.
const PARALLAX_PIXELS: float = 5.0
## Spring constant and damping for that lag. Critically damped-ish: it settles
## without a visible bounce, which would read as a bug.
const PARALLAX_SPRING: float = 46.0
const PARALLAX_DAMPING: float = 11.0
## Corner clusters are rotated a hair so they read as sitting on a curved surface
## rather than composited onto a flat one.
##
## M3.8 shipped this rotation as an admitted stand-in for real perspective, and
## M4.7 finally has the real thing — but not by warping Controls. The interface
## now renders into its own SubViewport and comes back through a tube with actual
## barrel curvature (`crt.gdshader`), and the corners of a tube are exactly where
## the glass bends. The clusters live in the corners, so they get genuine
## geometric perspective for free, from a cause the fiction already had.
##
## The rotation stays, smaller, as the second cue: curvature alone bends the
## edges of a cluster but leaves its baseline level, and a hair of roll is what
## sells a panel *mounted* on the inside of a curved screen.
const CLUSTER_TILT_DEG: float = 0.6

# --- Cycles ring ------------------------------------------------------------

## Below this the ring takes on an amber tinge; below CYCLES_WARNING_FRACTION
## (Balance) it goes hostile and starts beating.
const RING_AMBER_FRACTION: float = 0.5
## How sharply that tinge arrives across the band. Above 1 it holds off and then
## commits, which keeps the ring from spending the whole upper half of the band
## sitting in the washed-out grey between ice-blue and amber.
const RING_AMBER_GAMMA: float = 1.8
## Heartbeat scale at full alarm, and its period in seconds.
const RING_BEAT_SCALE: float = 0.035
const RING_BEAT_PERIOD: float = 0.86
## Outer hairline orbit: revolutions per second. Slow enough to be subliminal.
const RING_ORBIT_SPEED: float = 0.035
## Sprint bleed: how long an ember lingers behind the ring's head.
const RING_EMBER_DECAY: float = 0.9
## Siphon refill: overshoot fraction and settle time.
const RING_SURGE_OVERSHOOT: float = 0.055
const RING_SURGE_TIME: float = 0.45

# --- world-space prompts ----------------------------------------------------

## Prompts are solid inside this and gone by FADE_FAR.
const PROMPT_FADE_NEAR: float = 6.5
const PROMPT_FADE_FAR: float = 15.0
## And solid inside this half-angle off the lens axis, gone by the outer one.
const PROMPT_ANGLE_NEAR_DEG: float = 9.0
const PROMPT_ANGLE_FAR_DEG: float = 34.0
## Vertical float, in metres, and its period.
const PROMPT_FLOAT: float = 0.05
const PROMPT_FLOAT_PERIOD: float = 3.1
## How fast a prompt's alpha chases its target. Instant fade-in reads as a popup.
const PROMPT_FADE_RATE: float = 7.0

## Accessibility fallback: keep the old screen-centre prompt line as well as the
## world-anchored label. Off by default — the whole point of M3.8 is that the
## prompt lives on the object — but the code path stays, because "read the text
## in the middle of the screen" is the only way some players will ever get it.
const SCREEN_PROMPT_FALLBACK: bool = false

# --- menu -------------------------------------------------------------------

## The schematic backdrop scrolls this many pixels a second.
const MENU_SCROLL_SPEED: float = 7.0
## Layers drawn in the generated schematic, and rooms per layer.
const MENU_SCHEMATIC_LAYERS: int = 9
const MENU_SCHEMATIC_ROOMS: int = 7
## Fixed seed: the backdrop is the same drawing every launch, because it is a
## piece of art direction and not a slot machine.
const MENU_SCHEMATIC_SEED: int = 0x4E554C4C
## Seconds between MOTHER's glyph-ticker lines.
const MENU_TICKER_INTERVAL: float = 3.4
## Seconds between scan sweeps across the console.
const MENU_SWEEP_INTERVAL: float = 7.5
## Type-in reveal of the console on first open.
const MENU_TYPE_TIME: float = 0.85

## The screen decompiles into the dive over this long.
const DECOMPILE_TIME: float = 0.8
## And recompiles back out of it slightly faster on the way home.
const RECOMPILE_TIME: float = 0.55

# --- debrief ----------------------------------------------------------------

## Seconds per typed line of the run summary.
const DEBRIEF_LINE_TIME: float = 0.075
## How long the banked-data counter takes to roll up to its total.
const DEBRIEF_COUNT_TIME: float = 1.1


# --- crosshair --------------------------------------------------------------
#
# Alien: Isolation's discipline, in one rule: **the reticle says nothing until it
# has something to say.** At rest it is a single lit dot — the beam parked at the
# centre of the tube, doing nothing. State arrives as hairline brackets that open
# around it, and they only ever open for three reasons: there is something to
# interact with, the breaker is running hot, or you just hit something.
#
# Everything below is sub-200 ms and drawn in hairlines. A reticle that animates
# is a reticle you look at instead of looking through.

## The resting dot.
const CROSS_DOT: float = 1.6
## Bracket geometry: how far the four ticks sit from centre, and their length.
const CROSS_BRACKET_GAP: float = 7.0
const CROSS_BRACKET_LEN: float = 5.0
const CROSS_BRACKET_WIDTH: float = 1.0
## How far the brackets travel as they open, and how fast they spring.
const CROSS_OPEN_TRAVEL: float = 4.0
const CROSS_OPEN_RATE: float = 22.0
## Heat warning: the brackets tick outward and go amber as the breaker approaches
## lockout. Below this fraction of the heat bar the crosshair says nothing —
## warning you at 30% would be warning you constantly.
const CROSS_HEAT_FRACTION: float = 0.62

## Hit confirmation. A tick on the reticle, gone almost before it registers —
## which is the point: you should feel it landed rather than see a notification.
## PT1: the hit tick, sharpened.
##
## The playtest read the old tick as "not good enough feedback when an enemy is
## hit", and the numbers say why: four hairlines travelling 3 px, at bracket
## weight, gone in 0.16 s. That is a reticle *acknowledging* a hit; a player
## wants a reticle that *reacts* to one. Longer travel, a heavier stroke, and a
## fifth longer on screen — still under a fifth of a second, still the same four
## marks reusing the bracket geometry (a hit must never look like a new icon
## appearing), and still nothing at all when you miss.
##
## Rate: this fires at the breaker's own cadence, up to ~3.85 Hz. It is a small
## phosphor mark on a dark reticle, not a general flash — WCAG 2.3.1 governs
## luminance changes over a large area, and this covers ~0.02% of the frame — but
## it is scaled by `A11y.flash_scale` anyway, because the cheapest way to keep the
## safety law true is to never make an exception to it.
const HIT_TICK_TIME: float = 0.19
const HIT_TICK_TRAVEL: float = 6.5
const HIT_TICK_LEN: float = 5.5
const HIT_TICK_WIDTH: float = 2.0
## A kill. Four short fragments thrown off the centre, in the hostile red, and
## still under a fifth of a second.
const KILL_BURST_TIME: float = 0.22
const KILL_BURST_TRAVEL: float = 13.0
## And a faint mark left where the shot landed, in world space, so a hit has a
## place as well as a moment. Fades over this long.
const IMPACT_MARK_TIME: float = 0.5

# --- panels -----------------------------------------------------------------
#
# One open/close language for every panel in the game — the Compiler, the
# debrief, the injection gate. A clip-reveal (the panel wipes open from its own
# centre line, the way a CRT draws a raster) plus a single frame of hold loss.
## Seconds for a panel to wipe open, and to wipe shut again.
const PANEL_OPEN: float = 0.22
const PANEL_CLOSE: float = 0.14
## The one-frame hold slip as it lands. Pixels.
const PANEL_SNAP_SLIP: float = 5.0

## Compiler purchase: the COMPILING beat. Total length of the lock-progress-stamp
## sequence, and how long the success stamp holds afterwards.
const COMPILE_BEAT: float = 0.62
const COMPILE_STAMP: float = 0.85
## Tier pips fill with an ease and a tick rather than appearing filled.
const COMPILE_PIP_FILL: float = 0.30

# --- toasts -----------------------------------------------------------------
## Achievement/system cards arrive on a spring rather than a tween, and reveal by
## scanline: the card draws itself top to bottom the way the tube draws a frame.
const TOAST_SPRING: float = 26.0
const TOAST_DAMPING: float = 8.5
const TOAST_REVEAL: float = 0.26

# --- surfacing (M4.9): the quiet-instrument rule ----------------------------
#
# DESIGN.md's quiet-instrument rule: "the resting HUD is nearly empty ... Elements
# SURFACE on relevance ... and fade when stable. Labels appear briefly on change,
# then yield to shape/position. Every element must justify every frame it is
# visible."
#
# `Surface` (bottom of this file) is the one mechanism all of that runs on: a
# poke-able alpha with a dwell and a fade. Call `surface()` once for an event
# (a chip picked up, a descent) or every frame while a condition holds (integrity
# below full, the breaker hot); it fades `SURFACE_FALL` after the last poke. A
# capture `pin()`s it fully on, the same way the boot and damage flinches are
# pinned, so a `--hud-state` screenshot lands the same picture every machine.
#
# Two asymmetries are deliberate. Rise is fast and fade is slow: an element that
# eases in reads as a popup, one that snaps out reads as a bug. And a *label*
# holds shorter than the *shape* it names — the word is read once and then gets
# out of the way of the gauge.

## Default dwell at full before an un-repoked element begins to fade, and the
## chase rates that bring it up and let it down. Frame-rate independent.
const SURFACE_HOLD: float = 2.0
const SURFACE_RISE: float = 16.0
const SURFACE_FALL: float = 3.4
## The descent title is the one element with a longer, calmer dwell — a card that
## announces the layer for ~2 s and then yields to a tiny persistent numeral.
const TITLE_HOLD: float = 2.0
const TITLE_RISE: float = 8.0
const TITLE_FALL: float = 2.4
## A caption ("SHARED CYCLES", "BREAKER") shows on first change then gets out of
## the way of the shape it labels — shorter hold than the element it belongs to.
const CAPTION_HOLD: float = 1.5
const CAPTION_FALL: float = 3.0
## The roster surfaces on a crew change and holds a beat longer than the rest, so
## a join or a downed crewmate is legible before it fades to nothing.
const ROSTER_HOLD: float = 3.0

# --- menu depth -------------------------------------------------------------
## Parallax travel of the injection console's layers against the pointer, in
## pixels, from back to front. The schematic drifts most, the bezel not at all —
## which is what tells the eye the bezel is the thing closest to it.
const MENU_PARALLAX: Array[float] = [14.0, 6.0, -3.0]
## How fast those layers chase the pointer. Slow: this is a heavy console in a
## rack, not a card hovering under a cursor.
const MENU_PARALLAX_RATE: float = 3.2
## Cursor blink period on the console's type-in.
const MENU_CURSOR_BLINK: float = 0.62

# --- audio hooks (M5) -------------------------------------------------------
#
# Named now, deliberately, so that when M5 wires audio there is already one place
# that says what the interface is supposed to sound like and every call site is
# already in the right frame of mind. Nothing plays yet.
##   CRT_HUM       continuous, under everything, pitched to the tube's roll rate
##   CRT_DEGAUSS   the thump-and-wobble on injection (see TUBE_WARMUP)
##   CRT_TRACKING  the analog tear on damage
##   KEY_CLICK     a Compiler row selection: one mechanical key, no reverb
##   KEY_COMMIT    the COMPILING beat's terminating stamp
const SOUND_CRT_HUM: StringName = &"crt_hum"
const SOUND_CRT_DEGAUSS: StringName = &"crt_degauss"
const SOUND_CRT_TRACKING: StringName = &"crt_tracking"
const SOUND_KEY_CLICK: StringName = &"key_click"
const SOUND_KEY_COMMIT: StringName = &"key_commit"


## The clock every UI animation in the game reads.
##
## Wall time while a human is playing; **frames** while a capture is running, so
## that a screenshot armed for frame 260 catches exactly the same phase of every
## sine wave on every machine. Without this, "the Cycles ring at 10%" is a
## different picture every time it is taken and the captures cannot be diffed.
static func clock() -> float:
	if Debug.automated:
		return float(Engine.get_frames_drawn()) / 60.0
	return float(Time.get_ticks_msec()) / 1000.0


## Deterministic 0..1 hash. Used for flicker, dead pixels and glyph corruption,
## none of which want a real RNG (an RNG would allocate and would drift between
## peers for no benefit).
static func hash01(value: float) -> float:
	return fposmod(sin(value * 78.233) * 43758.5453, 1.0)


## A 0..1 heartbeat: fast attack, slow release, unlike a sine. This is what makes
## the low-Cycles ring read as a pulse rather than as a throb.
static func heartbeat(seconds: float, period: float) -> float:
	var phase: float = fposmod(seconds, period) / period
	if phase < 0.14:
		return phase / 0.14
	return maxf(1.0 - (phase - 0.14) / 0.42, 0.0)


## Blend toward `target` at a frame-rate-independent rate.
static func chase(current: float, target: float, rate: float, delta: float) -> float:
	return lerpf(current, target, 1.0 - exp(-rate * delta))


## The per-frame survival fraction that gives PHOSPHOR_HALFLIFE seconds of decay.
##
## Computed from delta rather than baked as a constant, because a fixed per-frame
## fraction makes the trail length a function of frame rate: the same tube would
## smear twice as far at 30 fps as at 60, which is the kind of thing that looks
## fine on the machine it was tuned on and wrong on everybody else's.
static func phosphor_decay(delta: float) -> float:
	if delta <= 0.0:
		return 0.0
	return clampf(pow(0.5, delta / maxf(PHOSPHOR_HALFLIFE, 0.001)), 0.0, 0.98)


## One surfacing HUD element — the quiet-instrument rule made mechanical.
##
## Hidden at rest (`alpha` 0). `surface()` brings it up: call it once for a
## discrete event, or every frame while an ongoing condition holds (each call
## just re-arms the dwell). It fades once nothing has poked it for `hold_time`
## seconds. `pin()` forces it fully shown for a deterministic capture; `clear()`
## drops it with no fade when a whole subsystem goes away or a resting capture
## wants the screen genuinely empty.
##
## Constructed ONCE per element and ticked every frame, so nothing here allocates
## on the hot path — the same discipline as ArcMeter's tick cache. The alpha it
## returns is the element's `modulate.a`; a caller composes nothing else onto it.
class Surface extends RefCounted:
	var alpha: float = 0.0
	var hold_time: float = UiFx.SURFACE_HOLD
	var rise_rate: float = UiFx.SURFACE_RISE
	var fall_rate: float = UiFx.SURFACE_FALL
	## Seconds of dwell left before the fade begins. Re-armed by `surface()`.
	var _hold: float = 0.0
	## Capture override: once pinned, the element is fully shown regardless.
	var _pinned: bool = false

	func _init(hold: float = UiFx.SURFACE_HOLD, rise: float = UiFx.SURFACE_RISE,
			fall: float = UiFx.SURFACE_FALL) -> void:
		hold_time = hold
		rise_rate = rise
		fall_rate = fall

	## Bring it up and re-arm the dwell. `hold` overrides the default for this poke
	## (a longer-lived alert can ask for more time without changing the element's
	## resting behaviour).
	func surface(hold: float = -1.0) -> void:
		_hold = hold if hold >= 0.0 else hold_time

	## Force it fully shown from now on. The capture path — mirrors how the boot
	## and damage states pin their own animations so a shutter is reproducible.
	func pin() -> void:
		_pinned = true
		alpha = 1.0

	## Drop it immediately, no fade. Used by a resting capture and by a subsystem
	## that has genuinely gone (the crew emptied, the run ended).
	func clear() -> void:
		_hold = 0.0
		alpha = 0.0

	## Advance one frame and return the new alpha. Rise is fast, fade is slow.
	func tick(delta: float) -> float:
		if _pinned:
			alpha = 1.0
			return 1.0
		if _hold > 0.0:
			_hold = maxf(_hold - delta, 0.0)
			alpha = UiFx.chase(alpha, 1.0, rise_rate, delta)
		else:
			alpha = UiFx.chase(alpha, 0.0, fall_rate, delta)
		return alpha
