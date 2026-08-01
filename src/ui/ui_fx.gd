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
# One system colour, one warning, one hostile, and a dim structural grey. The
# theme's ice-blue accent is the family these come from; the system colour is
# pulled a little toward teal so an emissive readout reads as *emitted* rather
# than as blue text.

## The colour of a program that is working.
const SYSTEM: Color = Color(0.36, 0.86, 1.0)
## Emissive head of the system colour, for leading caps and charge peaks.
const SYSTEM_HOT: Color = Color(0.62, 0.97, 1.0)
## Under half a pool. Not an emergency, but stop wandering.
const WARNING: Color = Color(1.0, 0.62, 0.26)
## Hostile, and everything below a quarter pool.
const HOSTILE: Color = Color(1.0, 0.42, 0.36)
## Structure: rules, tick marks, captions that are not saying anything yet.
const DIM: Color = Color(0.34, 0.42, 0.5)
## Body text.
const TEXT: Color = Color(0.82, 0.92, 1.0)

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

# --- glitch -----------------------------------------------------------------

## A damage flinch is short. Longer than this and it reads as a broken frame
## rather than as the interface being hit.
const GLITCH_TIME: float = 0.2
## Peak element displacement, in pixels. Two is the whole budget: the HUD has to
## still be readable in the frame it is glitching.
const GLITCH_SHIFT: float = 2.0
## Chromatic split of the big readouts during a flinch, in pixels.
const GLITCH_SPLIT: float = 2.4
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
## Corner clusters are rotated a hair so they read as projected onto the lens
## rather than composited onto it. Control has no skew (Node2D does), and a
## degree of rotation is the cheap, layout-safe stand-in.
const CLUSTER_TILT_DEG: float = 0.9

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
