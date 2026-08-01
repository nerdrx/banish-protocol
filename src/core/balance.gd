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

# --- damage -----------------------------------------------------------------

## DESIGN.md pillar 1: "damage ... add drain spikes". Every landed antivirus hit
## burns this much of the shared pool on top of the integrity it costs, so a crew
## that fights everything runs out of clock even if nobody goes down.
const DAMAGE_CYCLE_SPIKE: float = 3.0

## How long the HUD's directional damage wedge stays up after a hit.
const DAMAGE_FLASH_TIME: float = 0.9

# --- corrupted / restore -----------------------------------------------------

## A corrupted crewmate's personal decay timer. Long enough that a crewmate two
## rooms away can plausibly reach them, short enough to be a real emergency.
const CORRUPT_DECAY: float = 60.0
const RESTORE_CHANNEL_TIME: float = 3.0
## How close the rescuer has to actually be when the host checks. Generous
## against the channel's own reach so a restore is never refused for a step the
## client took mid-channel.
const RESTORE_REACH: float = 4.0
## You come back hurt. Restoring is a reprieve, not a heal.
const RESTORE_INTEGRITY: float = 40.0

# --- breaker ----------------------------------------------------------------

## Three hits kills a Scrubber (SCRUBBER_HEALTH / BREAKER_DAMAGE). A tool, not a
## gun: short reach, no ammo, and heat instead of a magazine.
const BREAKER_DAMAGE: float = 42.0
const BREAKER_RANGE: float = 8.0
const BREAKER_COOLDOWN: float = 0.26
## The cutter is forgiving about exactly where it lands. A Scrubber is a
## knee-high shape moving at 5 m/s in the dark, and a pixel-accurate hitscan
## against a 0.36 m capsule would turn the crew's only weapon into a
## marksmanship test. Anything inside this half-angle of the aim with clear line
## of sight is cut — about a metre of slack at full range.
const BREAKER_AIM_DEG: float = 7.5
## Heat added per shot, and shed per second. 0.17/0.42 gives ~6 shots from cold
## before the cutter locks out, and ~2.4 s to cool from full.
const BREAKER_HEAT_PER_SHOT: float = 0.17
const BREAKER_HEAT_COOL: float = 0.42
## Once heat reaches 1.0 the cutter is dead until it has cooled back below this.
const BREAKER_HEAT_RESET: float = 0.45

# --- flares -----------------------------------------------------------------

const FLARE_STOCK: int = 3
## Igniting one costs the crew pool (DESIGN.md: "flares burn Cycles+Cache stock").
const FLARE_CYCLE_COST: float = 8.0
const FLARE_LIFETIME: float = 20.0
const FLARE_THROW_SPEED: float = 11.5
const FLARE_LIGHT_RANGE: float = 13.0
## Scrubbers treat this radius around a burning flare exactly like a beam cone.
const FLARE_REPEL_RADIUS: float = 9.0

# --- antivirus --------------------------------------------------------------

const SCRUBBER_HEALTH: float = 100.0
## Base metres/second, multiplied by LayerParams.scrubber_speed (1.0 -> 1.55).
## At the surface a Scrubber is faster than a walk and slower than a sprint; by
## the depth floor you cannot outrun one.
const SCRUBBER_LURK_SPEED: float = 1.5
const SCRUBBER_STALK_SPEED: float = 4.6
const SCRUBBER_LUNGE_SPEED: float = 9.5
const SCRUBBER_FLEE_SPEED: float = 6.2

## How far a Scrubber notices a running player in the dark, and how far it will
## follow one before giving up.
const SCRUBBER_HEAR_RANGE: float = 26.0
const SCRUBBER_LOSE_RANGE: float = 38.0
## Reach of the lunge, and the damage it lands.
const SCRUBBER_LUNGE_RANGE: float = 3.0
const SCRUBBER_LUNGE_DAMAGE: float = 9.0
const SCRUBBER_LUNGE_TIME: float = 0.45
const SCRUBBER_RECOVER_TIME: float = 1.1

## Beam-avoidance, THE mechanic: this long inside a beam cone (or near a flare)
## and the Scrubber breaks for the dark.
const SCRUBBER_EXPOSURE_LIMIT: float = 0.4
const SCRUBBER_FLEE_TIME: float = 4.5
## Half-angle of a player's beam cone for exposure purposes, and how far down it
## an exposed Scrubber can be. Slightly wider than the SpotLight so the mechanic
## triggers where the light visibly lands.
const BEAM_HALF_ANGLE_DEG: float = 30.0
const BEAM_EXPOSURE_RANGE: float = 24.0

## A drained siphon tap converges every Scrubber within this many rooms, and
## they keep converging on the junction for this long before losing interest.
const TAP_ALERT_ROOMS: int = 2
const TAP_ALERT_TIME: float = 12.0

## Sweep rate in radians/second — slow enough to read as surveillance, fast
## enough that crossing the room is a timing problem.
const SENTINEL_SCAN_SPEED: float = 0.55
const SENTINEL_WALK_SPEED: float = 1.6
const SENTINEL_SCAN_RANGE: float = 19.0
const SENTINEL_SCAN_HALF_ANGLE_DEG: float = 14.0
const SENTINEL_WAKE_RANGE: float = 22.0
const SENTINEL_PURGE_SPEED: float = 2.6
const SENTINEL_PURGE_RANGE: float = 4.0
const SENTINEL_PURGE_ARC_DEG: float = 55.0
const SENTINEL_PURGE_DAMAGE: float = 26.0
const SENTINEL_PURGE_COOLDOWN: float = 2.4

## Armour, not immunity. Eighteen Scrubbers' worth of hit points: forty-three
## body shots, or fifteen through the core — a fight you commit to, and one a
## crew finishes in a third of the time a lone agent does.
const SENTINEL_HEALTH: float = 1800.0
## The exposed core takes triple. A quarantine process drops its shielding to
## scan and to purge, so the window is the same window in which it is dangerous.
const SENTINEL_CORE_MULTIPLIER: float = 3.0
## How far around the front the core is reachable from. It faces the room it is
## clearing, so hitting the core means standing where the purge arc lands.
const SENTINEL_CORE_ARC_DEG: float = 75.0
## What a dead Sentinel spills, and how many piles it scatters into. This is what
## the vault was actually guarding.
const SENTINEL_DROP_SHARDS: int = 9
const SENTINEL_DROP_PIECES: int = 3
## How far outside its vault a Sentinel will chase. Beyond this it walks home.
const SENTINEL_LEASH: float = 16.0
const SENTINEL_CALM_TIME: float = 8.0

## Host AI tick. The state machines do not need a physics-rate update, and 15 Hz
## keeps a dozen creatures off the frame budget.
const AI_TICK: float = 1.0 / 15.0
## Pose broadcast rate for antivirus. Faster than the pool, slower than players:
## they are chased, not aimed at.
const ANTIVIRUS_SYNC_INTERVAL: float = 0.08

# --- data shards ------------------------------------------------------------

## Value of one shard on layer 1, scaled by LayerParams.data_multiplier.
const SHARD_BASE_VALUE: int = 10
## Shards drift to you inside this, and are absorbed at the inner radius.
const SHARD_MAGNET_RADIUS: float = 2.0
const SHARD_ABSORB_RADIUS: float = 0.75

## Carrying is free up to this many shards; past it you slow down, to a floor of
## (1 - CARRY_MAX_PENALTY). DESIGN.md: "who carries the haul?".
const CARRY_FREE_SHARDS: int = 10
const CARRY_PENALTY_SPAN: float = 30.0
const CARRY_MAX_PENALTY: float = 0.18

## A corrupted crewmate spills their buffer as one bundle anyone can pick up.
const BUNDLE_PICKUP_RADIUS: float = 1.6

# --- backdoor / exfiltration ------------------------------------------------

const BACKDOOR_CHANNEL_TIME: float = 4.0
const EXFIL_CHANNEL_TIME: float = 5.0
## Broadcast countdown once exfiltration is called. Long enough to sprint back
## from the far side of the room, short enough to be terrifying.
const EXFIL_COUNTDOWN: float = 20.0
## Stand inside this of the uplink when it fires or you are left behind.
const EXFIL_PAD_RADIUS: float = 4.5

# --- replication ------------------------------------------------------------

## Pool broadcast rate. The value is a smooth ramp, so clients interpolate
## between packets and 5 Hz is invisible.
const POOL_SYNC_INTERVAL: float = 0.2
## Integrity is pushed on change, throttled to this.
const INTEGRITY_SYNC_INTERVAL: float = 0.25


## Pool ceiling for a crew of `crew_size`.
static func pool_max(crew_size: int) -> float:
	return CYCLES_PER_CREW * float(maxi(crew_size, 1))


## Movement multiplier for a buffer holding `shards` shards.
static func carry_multiplier(shards: int) -> float:
	var over: float = float(maxi(shards - CARRY_FREE_SHARDS, 0))
	return 1.0 - CARRY_MAX_PENALTY * clampf(over / CARRY_PENALTY_SPAN, 0.0, 1.0)


## What one shard is worth on `layer_number`.
static func shard_value(layer_number: int) -> int:
	var params: Dictionary = LayerParams.of(layer_number)
	return maxi(int(round(float(SHARD_BASE_VALUE) * float(params["data_multiplier"]))), 1)
