class_name Balance
extends RefCounted
## Every tunable number the intrusion economy runs on, in one file.
##
## DESIGN.md pillar 1: "Shared Cycles ... the clock, the economy, and the argument
## the crew has over voice chat." That only works if the numbers are legible, so
## they live here with the reasoning attached rather than scattered across the
## systems that consume them.
##
## Never instantiated — this is a constant namespace.

# --- the pool ---------------------------------------------------------------

## Base pool contributed by each crew member at injection. Four agents inject
## with 400 Cycles; one agent injects with 100 and is on a much shorter leash.
const CYCLES_PER_CREW: float = 100.0

## Per living player, per second, just for existing. 100 / 0.6 = ~166 s of
## solo runtime on a full share — comfortably longer than a careful sweep of a
## layer, comfortably shorter than a thorough one.
const PASSIVE_DRAIN: float = 0.6

## Sprinting multiplies that player's drain. Sprinting the whole layer costs you
## roughly two thirds of your runtime, which is the trade the pillar wants.
const SPRINT_DRAIN_MULT: float = 2.5

## A player only counts as sprinting for billing purposes above this speed, so
## holding shift while stood still is free (and so the host can infer sprint from
## the pose stream instead of replicating an extra input bit).
const SPRINT_BILLING_SPEED: float = 5.4

# --- siphon taps ------------------------------------------------------------

## One tap returns most of a crew member's share. Two taps on a layer means the
## crew can break roughly even; missing both means descending on a deficit.
const SIPHON_YIELD: float = 70.0
const SIPHON_CHANNEL_TIME: float = 2.5

# --- drop shaft -------------------------------------------------------------

const SHAFT_CHANNEL_TIME: float = 3.0
## How far from the shaft's centre a player still counts as "in the shaft".
const SHAFT_MUSTER_RADIUS: float = 7.5
## Cover for the rebuild. The screen is black well before geometry is freed.
const DESCENT_FADE_OUT: float = 0.55
const DESCENT_HOLD: float = 0.35
const DESCENT_FADE_IN: float = 0.9

# --- integrity / degradation ------------------------------------------------

const INTEGRITY_MAX: float = 100.0

## Only drains while the pool is empty. 100 / 1.7 = ~59 s from full integrity to
## decompilation — DESIGN.md's "~60s to reach an uplink before the crew
## decompiles".
const STARVED_INTEGRITY_DRAIN: float = 1.7

## Integrity recovers slowly once the pool is back, so a bad stretch is a scar
## rather than a death sentence.
const INTEGRITY_REGEN: float = 1.1

## Movement penalty while starved. Small enough to still be a run, large enough
## that you feel the process failing.
const STARVED_SPEED_MULT: float = 0.82

## Pool fraction below which the HUD goes to warning red.
const CYCLES_WARNING_FRACTION: float = 0.25

# --- replication ------------------------------------------------------------

## Pool broadcast rate. The value is a smooth ramp, so clients interpolate
## between packets and 5 Hz is invisible.
const POOL_SYNC_INTERVAL: float = 0.2
## Integrity is pushed on change, throttled to this.
const INTEGRITY_SYNC_INTERVAL: float = 0.25


## Pool ceiling for a crew of `crew_size`.
static func pool_max(crew_size: int) -> float:
	return CYCLES_PER_CREW * float(maxi(crew_size, 1))
