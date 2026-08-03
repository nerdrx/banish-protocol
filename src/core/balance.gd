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

# --- the intended curve (M4) ------------------------------------------------
#
# Two curves run against each other and the whole game lives in the gap between
# them: the **threat curve** (LayerParams — more processes, faster, darker, per
# layer) and the **power curve** (the module tracks below, bought with data the
# threat curve is guarding). M4's job was to make the second one exist; this
# comment is the shape they are tuned to.
#
#   layers  1-5    A fresh program, no modules at all, comfortably learns the
#                  game. Two siphons a layer, Scrubbers only until 3, one
#                  Sentinel after that. A careful 1->5 run banks roughly
#                  500-800 data, which is the first two or three module tiers.
#   layers  6-10   Siphons halve (LayerParams.siphon_count drops to 1 at 7) and
#                  the antivirus budget roughly doubles. Playable bare, but the
#                  pool is now the binding constraint: this band is asking for
#                  Runtime 1-2 and whichever of Breaker/Optics your crew fights
#                  or sneaks with. Banks ~900-1400.
#   layers 11-15   The ambient light and room-light curves have bottomed out and
#                  the Sentinel count is at its ceiling. Expect most tracks
#                  touched at tier 1-3 and two of them at 3-4. Banks ~1800-2600,
#                  so this is also where the tier-4 prices start being payable.
#   layers 16+     Honest endgame. Nothing new is generated — the depth floor is
#                  layer 14 — so the difficulty is purely that the numbers keep
#                  scaling while your build is finite. Tier 5 exists for here.
#
# Prices are set so the first tier of anything lands inside one or two surface
# runs and the fifth tier of anything costs about ten deep ones. Maxing every
# track is ~133,000 data: sixty-plus runs, which is the point.
#
# Two rules keep this honest and both are load-bearing:
#   1. **Modules never touch world generation.** Every value below is applied to
#      a player, per player, at simulation time. The determinism dump cannot see
#      any of it.
#   2. **The host owns every number that matters.** A client's tiers are
#      announced (Net.crew) and the host resolves them; nothing here is applied
#      from a client's own say-so except the purely cosmetic half of Optics.

# --- the pool ---------------------------------------------------------------

## Base pool contributed by each crew member at injection. Four agents inject
## with 400 Cycles; one agent injects with 100 and is on a much shorter leash.
## M4: this is the *base* share — Runtime tiers add to it per player, so a crew
## of four with different builds no longer has a pool that is a multiple of one
## number (see `Modules.crew_pool_max`).
const CYCLES_PER_CREW: float = 100.0

## Per living player, per second, just for existing.
##
## PT1: HALVED, 0.6 -> 0.3, on the first friend playtest's "our oxygen should run
## out at least half as fast". 100 / 0.3 = ~333 s of solo runtime on a full share
## instead of ~166. The old number was tuned against a layer you could sweep in
## two minutes; six milestones of intricacy, functional clutter, terminals and
## hunters later, a *careful* sweep no longer fits inside it, and a clock that
## expires during normal play stops being the argument the crew has over voice
## chat (pillar 1) and becomes a reason to skip the content.
##
## Nothing else in the economy is scaled with it, deliberately. Sprint is a
## MULTIPLIER on this (below), so its share of the budget is unchanged and
## sprinting still costs the same fraction of your runtime it always did. The
## spikes — damage, flares — are absolute, so halving the drain makes them
## RELATIVELY twice as expensive against the clock: taking hits and burning
## flares now costs a visibly larger slice of the run than merely existing does,
## which is the direction DESIGN.md wants ("passive drain while you exist;
## sprinting, taking damage, and burning flares SPIKE it"). The siphon yield is
## likewise untouched, so a tap is now worth twice as much wall-clock time —
## correct, because a tap is loud and should buy something worth being heard for.
const PASSIVE_DRAIN: float = 0.3

## Sprinting multiplies that player's drain. Sprinting the whole layer costs you
## roughly two thirds of your runtime, which is the trade the pillar wants.
const SPRINT_DRAIN_MULT: float = 2.5

## A player only counts as sprinting for billing purposes above this speed, so
## holding shift while stood still is free (and so the host can infer sprint from
## the pose stream instead of replicating an extra input bit).
##
## M4.9 (balance lab): raised 5.4 -> 6.0. At 5.4 a maxed-Servos walk (WALK_SPEED
## 4.2 * 1.22 = 5.124) sat only 0.28 under the threshold, so a starved-but-fast
## build could brush sprint billing while merely walking. 6.0 restores a clean
## margin (5.124 < 6.0) while still landing well under SPRINT_SPEED (6.9), so an
## actual sprint always bills. The invariant WALK_SPEED * max(Servos.move) <
## SPRINT_BILLING_SPEED is checked headless by `--selftest` (see Debug).
const SPRINT_BILLING_SPEED: float = 6.0

# --- siphon taps ------------------------------------------------------------

## One tap returns most of a crew member's share. Two taps on a layer means the
## crew can break roughly even; missing both means descending on a deficit.
const SIPHON_YIELD: float = 70.0
const SIPHON_CHANNEL_TIME: float = 2.5

# --- drop shaft -------------------------------------------------------------

## PT1 — **the drop shaft IS a data trunk, and riding it down siphons it.**
##
## Completing a descent refills the shared pool by this fraction of its MAXIMUM,
## clamped to max. Fiction first: the shaft is not an elevator, it is a live
## trunk running deeper into MOTHER, and a crew of intrusion programs riding one
## down are inside a pipe carrying the thing they run on. Taking a cut of it on
## the way past is what a program would do.
##
## Mechanically it is the descent's answer to the siphon tap's refill, and it
## pulls in the same direction as the halved PASSIVE_DRAIN: greed is supposed to
## be the thing that kills you (pillar 3), not arithmetic. Before this, "one more
## ring?" was asked of a pool that only ever went down between taps, so the honest
## answer was usually no and the game's central question answered itself. Half a
## pool back at the bottom of the shaft makes the question live again — you can
## always afford ONE more ring, which is exactly how a greed trap should feel.
##
## Half rather than full on purpose: a full refill would make the clock stop
## mattering, and the pool is the clock.
##
## **Only real descents.** Not the initial injection, not a backdoor start — see
## `RunState.finish_descent`, which is called by the Layer only when a completed
## drop-shaft ride has finished rebuilding the world below.
const DESCENT_REFILL_FRACTION: float = 0.5

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
## M4.9 (balance lab): 2.6 -> 4.6. At 2.6 the purge lunge was slower than a walk
## and trivially back-pedalled, so the Sentinel's one offensive window never
## landed and the fight was pure attrition on the core. 4.6 makes closing the arc
## a real threat you have to answer, without making it a Scrubber-fast chaser
## (still under SCRUBBER_STALK_SPEED 4.6's pack pressure in feel because it only
## moves this fast during the brief purge commit).
const SENTINEL_PURGE_SPEED: float = 4.6
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
##
## M4.9 (balance lab): the kill drop drops 9 -> 5 while the vault floor it guards
## rises (SHARDS_VAULT 8-12 -> 11-16, in LayerGraph). The reward for clearing a
## vault is unchanged in total, but it moves off the kill and onto the room: a
## crew that fights the Sentinel and one that slips the vault while it scans now
## come out closer to even, which is the "shooting is one option" the killability
## law asks for rather than "the kill IS the loot".
const SENTINEL_DROP_SHARDS: int = 5
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


## Pool ceiling for a crew of `crew_size` with no modules compiled. Kept for the
## offline/editor path and for anything that wants the un-modified number;
## `Modules.crew_pool_max()` is what the host actually bills against.
static func pool_max(crew_size: int) -> float:
	return CYCLES_PER_CREW * float(maxi(crew_size, 1))


## Movement multiplier for a buffer holding `shards` shards. `free` and
## `penalty` come from the carrier's Buffer tier (Modules.loadout), so a Mule
## build genuinely carries more before it starts to drag.
static func carry_multiplier(shards: int, free: int = CARRY_FREE_SHARDS,
		penalty: float = CARRY_MAX_PENALTY) -> float:
	var over: float = float(maxi(shards - free, 0))
	return 1.0 - penalty * clampf(over / CARRY_PENALTY_SPAN, 0.0, 1.0)


## What one shard is worth on `layer_number`.
static func shard_value(layer_number: int) -> int:
	var params: Dictionary = LayerParams.of(layer_number)
	return maxi(int(round(float(SHARD_BASE_VALUE) * float(params["data_multiplier"]))), 1)


## Sentinel hit points on `layer_number`. M4.9 (balance lab): armour now scales
## past the depth floor. At and below DEPTH_FLOOR it is the flat SENTINEL_HEALTH;
## past it, +8% per layer, so a layer-20 quarantine process is ~1.48x the wall a
## layer-14 one is. Everything else on the threat curve flattens at the floor
## (LayerParams.depth clamps at 14) while the crew's Breaker keeps climbing to
## tier 5 — without this the deepest Sentinels got *easier* in real terms every
## ring. Pure sim-time: applied per-creature at assembly, never to generation.
static func sentinel_health(layer_number: int) -> float:
	var over: int = maxi(layer_number - LayerParams.DEPTH_FLOOR, 0)
	return SENTINEL_HEALTH * (1.0 + 0.08 * float(over))


## Hunter hit points on `layer_number` (M6). Same shape as the Sentinel's armour:
## flat at and below the depth floor, +6% per layer past it, so the deepest
## hunters do not get easier in real terms as the crew's Breaker climbs. `base` is
## the class's own HOUND_/MOTH_/AUDITOR_HEALTH. Pure sim-time; never touches
## generation, so a determinism dump cannot see it.
static func hunter_health(base: float, layer_number: int) -> float:
	var over: int = maxi(layer_number - LayerParams.DEPTH_FLOOR, 0)
	return base * (1.0 + 0.06 * float(over))


# --- modules (M4) -----------------------------------------------------------
#
# The eight permanent tracks from DESIGN.md's meta-progression section. Every
# number the economy and the effects run on is here; `Modules` (autoload) owns
# the *behaviour* — resolving a set of tiers into a loadout, pricing a purchase,
# and replicating who has what.
#
# Shape of a track:
#   name/glyph/note   what the Compiler panel prints
#   prices[i]         cost of buying tier i+1 (so `prices` has TIERS entries)
#   <effect>[t]       the value at tier t, with index 0 = "no module at all".
#                     Effect arrays therefore have TIERS+1 entries and index 0
#                     always repeats the bare constant above.
#
# Tier counts are deliberately uneven (DESIGN.md says 3-5). A track with three
# tiers is one you finish; a track with five is one you commit a build to.

## Order the Compiler panel and the menu's program readout list them in. Roughly
## "keeps you alive" -> "kills things" -> "carries the haul".
const MODULE_TRACKS: Array[String] = [
	"runtime", "threading", "checksum", "breaker",
	"optics", "servos", "buffer", "cache",
]

const MODULES: Dictionary = {
	# --- Runtime: the clock ------------------------------------------------
	# The default track. 100 Cycles at 0.6/s is 166 s of solo runtime; a maxed
	# Runtime is 180 at 0.42/s, which is 428 s — two and a half times the leash,
	# and the reason a layer-18 sweep is possible at all.
	"runtime": {
		"name": "RUNTIME",
		"glyph": "◉",
		"note": "CYCLES SHARE ↑  ·  PASSIVE DRAIN ↓",
		"prices": [300, 800, 2200, 5900, 16000],
		"share": [0.0, 12.0, 26.0, 42.0, 60.0, 80.0],
		"drain": [1.0, 0.94, 0.88, 0.82, 0.76, 0.70],
	},
	# --- Threading: the sprint ---------------------------------------------
	# Three tiers, because "sprinting is expensive" is a rule the game needs to
	# keep. At tier 3 a sprint bills 1.55x instead of 2.5x — cheaper, never free.
	"threading": {
		"name": "THREADING",
		"glyph": "≡",
		"note": "SPRINT COST ↓",
		"prices": [260, 780, 2300],
		"sprint": [2.5, 2.15, 1.85, 1.55],
	},
	# --- Checksum: the health ----------------------------------------------
	# A Scrubber lunge is 9 and a Sentinel arc is 26. At tier 5 (224) a purge
	# costs you 12% instead of 26%, which is the difference between "we back off"
	# and "we finish it".
	"checksum": {
		"name": "CHECKSUM",
		"glyph": "▣",
		"note": "MAX INTEGRITY ↑",
		"prices": [300, 820, 2300, 6200, 17000],
		"integrity": [100.0, 118.0, 138.0, 162.0, 190.0, 224.0],
	},
	# --- Breaker: the cutter -----------------------------------------------
	# Scrubber HP is 100, so damage tiers read as a shot count: 3 hits bare, 2 at
	# tier 2, 1 at tier 5. Range matters as much — eight metres is inside a
	# lunge, fifteen is not.
	"breaker": {
		"name": "BREAKER",
		"glyph": "⌁",
		"note": "CUTTER DAMAGE ↑  ·  REACH ↑",
		"prices": [320, 880, 2400, 6300, 17000],
		# M4.9 (balance lab): reshaped 42/50/60/72/86/104 -> 42/48/52/62/76/104.
		# Against SCRUBBER_HEALTH 100 the old curve broke to a 2-shot kill at tier 1
		# (50) already, so the first Breaker tier trivialised the whole early game.
		# The new curve keeps tier 1 a 3-shot (48) and tier 2 barely a 2-shot (52),
		# so the 2-shot breakpoint moves to tier 2 where it is paid for — the deep
		# tiers (76/104) are unchanged, so the endgame ceiling is the same.
		"damage": [42.0, 48.0, 52.0, 62.0, 76.0, 104.0],
		"range": [8.0, 9.0, 10.2, 11.6, 13.2, 15.0],
	},
	# --- Optics: buying vision ---------------------------------------------
	# The one track whose purchase you can SEE the instant it lands, which is
	# why the Compiler applies live rather than at the next injection. The
	# exposure cone the Scrubbers flee from is derived from the same numbers
	# (Modules.loadout), so a wider beam genuinely holds more of them off.
	"optics": {
		"name": "OPTICS",
		"glyph": "◇",
		"note": "BEAM WIDTH ↑  ·  BRIGHTNESS ↑  ·  REACH ↑",
		"prices": [280, 780, 2200, 6100, 17000],
		"angle": [26.0, 30.0, 34.5, 39.5, 45.0, 51.0],
		"energy": [6.6, 7.5, 8.6, 9.9, 11.4, 13.0],
		"reach": [30.0, 34.0, 38.5, 43.5, 49.0, 55.0],
	},
	# --- Servos: the legs --------------------------------------------------
	# Small movement numbers on purpose: the avatar's feel was tuned in M1 and a
	# 22% top-speed swing is the most it takes before the bob, the dip and the
	# camera lag stop matching the body. The restore half is the real reason to
	# buy it — three seconds stood still next to a downed crewmate is a long time.
	"servos": {
		"name": "SERVOS",
		"glyph": "⋔",
		"note": "MOVE SPEED ↑  ·  RESTORE SPEED ↑",
		"prices": [340, 980, 2900, 8200],
		"move": [1.0, 1.05, 1.10, 1.16, 1.22],
		"restore": [1.0, 0.88, 0.77, 0.66, 0.56],
	},
	# --- Buffer: the haul --------------------------------------------------
	# Cheapest track to start, because "who carries the haul" should be a
	# decision a new crew can act on. Tier 4 carries 46 chips free and barely
	# notices the rest.
	"buffer": {
		"name": "BUFFER",
		"glyph": "▤",
		"note": "CARRY CAPACITY ↑  ·  WEIGHT PENALTY ↓",
		"prices": [240, 680, 1900, 5200],
		"free": [10, 16, 24, 34, 46],
		"penalty": [0.18, 0.145, 0.11, 0.08, 0.05],
	},
	# --- Cache: the flares -------------------------------------------------
	# Three tiers and steep, because a flare is the answer to a Scrubber pack and
	# eight of them would make the dark negotiable. Still costs the shared pool
	# to burn one, which is what keeps the stock from being the whole answer.
	"cache": {
		"name": "CACHE",
		"glyph": "✦",
		"note": "FLARE STOCK ↑",
		"prices": [300, 960, 3000],
		"stock": [3, 4, 6, 8],
	},
}

## Highest tier any track goes to. The Compiler stock gate is clamped to it.
const MODULE_MAX_TIER: int = 5

## Sanctuary Compilers stock one tier above the layer they stand on
## (DESIGN.md: "Deeper Compilers stock higher tiers"), which is what makes a
## backdoor room worth walking to even when you are not exfiltrating.
const COMPILER_SANCTUARY_BONUS: int = 1

# --- M4.8 functional clutter -------------------------------------------------
#
# The world gets dense and it gets levers. Two rules run through every number
# below and both come straight out of DESIGN.md:
#
#   **The solo invariant.** Every prop here is usable by one agent. Nothing
#   needs a second pair of hands, nothing is held open by a crewmate, and
#   nothing costs more than one player can pay. Co-op makes them *easier to use
#   safely* (somebody else watches the dark while you type), never *possible*.
#
#   **The killability law's cousin: props never trap you.** A sealed bulkhead
#   opens again on its own, only ever stands on a corridor with an alternative
#   route, and can be re-opened by hand. A welded vent is a wall, and walls are
#   already everywhere. Nothing in this milestone can end a run by itself.

# --- noise ------------------------------------------------------------------
#
# Reach is measured in ROOMS rather than metres, because that is the unit the
# antivirus already thinks in (`LayerGraph.room_distance`, which the siphon's
# alert has used since M3) and because a metre radius through a wall is a lie —
# sound in this building travels down corridors, not through slabs.
#
# The ladder, quietest to loudest:
#   0 rooms   kicked debris. Whatever is in here with you hears it; nothing else.
#   1 room    a terminal query, a cabinet lock cut. Louder than a footstep,
#             quieter than a siphon: the neighbours look up.
#   2 rooms   rewiring a junction, draining a siphon. The layer knows.
const NOISE_ROOMS_DEBRIS: int = 0
const NOISE_ROOMS_TERMINAL: int = 1
const NOISE_ROOMS_CABINET: int = 1
const NOISE_ROOMS_JUNCTION: int = 2

## How long each kind of noise holds a process's attention. Same shape as
## TAP_ALERT_TIME, which is the loudest of them and stays the reference.
const NOISE_TIME_DEBRIS: float = 5.0
const NOISE_TIME_TERMINAL: float = 8.0
const NOISE_TIME_CABINET: float = 8.0
const NOISE_TIME_JUNCTION: float = TAP_ALERT_TIME

# --- rewire junctions -------------------------------------------------------

## Opening the panel is a beat, not a commitment — the same reasoning as the
## Compiler's OPEN_TIME. The *choice* is the expensive part.
const JUNCTION_OPEN_TIME: float = 0.4
const JUNCTION_USE_RANGE: float = 5.5
## How long VENT FANS holds every weldable vent on the layer shut.
const VENT_FAN_SECONDS: float = 90.0
## Emergency strips under ROOM LIGHTING. Deliberately feeble compared to the
## key/wash rig — this is a corridor you can cross without your beam, not a
## room with the lights on. DESIGN.md pillar 2 is not negotiable for a lever.
const JUNCTION_LIGHT_ENERGY: float = 1.35
const JUNCTION_LIGHT_RANGE: float = 9.0

# --- weldable vent covers ---------------------------------------------------

## Seconds of focused breaker to weld one shut. Two seconds is long enough to
## be a decision in a nest and short enough to be worth making.
const VENT_WELD_TIME: float = 2.0
const VENT_WELD_RANGE: float = 6.5

# --- lootable cabinets ------------------------------------------------------

## Cutting the lock is louder and slower than welding a vent: you are making a
## hole in MOTHER's property rather than closing one.
const CABINET_CUT_TIME: float = 1.6
const CABINET_CUT_RANGE: float = 6.5
## The silent path — hold E with DOOR LOCKS powered at the junction.
const CABINET_OPEN_TIME: float = 1.0
const CABINET_USE_RANGE: float = 5.5
## What is inside. Chips are spilled as a recoverable bundle (the same object a
## corrupted crewmate drops), so opening one still costs you the walk over.
const CABINET_SHARDS: Vector2i = Vector2i(2, 4)
## Roughly a third of cabinets also hold a flare. Cache tier still caps you.
const CABINET_FLARE_CHANCE: float = 0.34
const CABINET_FLARES: int = 1

# --- sealable bulkhead doors ------------------------------------------------

## Heavy. This one IS a commitment — you are standing still in a doorway with
## something coming down the corridor.
const BULKHEAD_SEAL_TIME: float = 1.6
## How long MOTHER tolerates a door of hers being shut.
const BULKHEAD_SEAL_SECONDS: float = 60.0
## Her warning before she forces it: the hiss, and then it is open.
const BULKHEAD_WARN_SECONDS: float = 6.0
const BULKHEAD_USE_RANGE: float = 6.0

# --- command terminals ------------------------------------------------------

const TERMINAL_OPEN_TIME: float = 0.45
const TERMINAL_USE_RANGE: float = 5.5
## How long a query takes to 'process' before the phosphor starts typing back.
const TERMINAL_QUERY_SECONDS: float = 2.2
## Characters per second the answer types at. Slower than the HUD's self-test:
## this is a machine thinking, not a machine reporting.
const TERMINAL_TYPE_SPEED: float = 58.0
## Output corruption ramps between these layers, to this fraction of glyphs.
## Same shape as GeometryKit's architecture decay and DecalLib's signage decay,
## because it is the same fact about the same building.
const TERMINAL_CORRUPT_START: int = 6
const TERMINAL_CORRUPT_FULL: int = 18
const TERMINAL_CORRUPT_MAX: float = 0.40

# --- physics debris ---------------------------------------------------------

## Impulse a walking player imparts. Enough to send a can skittering, nowhere
## near enough to make the deck a pinball table.
const DEBRIS_PUSH: float = 2.4
## How fast a piece has to be moving for its clatter to count as a noise event,
## and how long before it may ping again. Without the cooldown one can rolling
## down a corridor is a siren.
const DEBRIS_NOISE_SPEED: float = 1.2
const DEBRIS_NOISE_COOLDOWN: float = 1.4
## Below this speed a piece is put back to sleep by hand. RigidBody3D's own
## sleep threshold is generous, and a layer with ten pieces jittering in the
## broadphase forever is ten pieces of frame budget nobody asked for.
const DEBRIS_SLEEP_SPEED: float = 0.12
const DEBRIS_SLEEP_DELAY: float = 1.5

# --- reinforcement trickle --------------------------------------------------
#
# M4.8 adds a modest one so that welding a vent means something. Before this a
# layer's antivirus was a fixed purchase: kill it and the layer was clear, which
# made the nests scenery. The trickle is deliberately slow and hard-capped at
# the layer's own budget — it is pressure, not attrition, and it can never make
# a layer harder than the threat curve already said it was.
const TRICKLE_FIRST_DELAY: float = 60.0
const TRICKLE_INTERVAL: float = 45.0
## Only nests with an unwelded vent trickle at all, and each welded vent in the
## room multiplies that room's rate by this. Weld them all and the nest is shut.
const TRICKLE_WELD_PENALTY: float = 0.45

# --- M6 the haunting: hunters ------------------------------------------------
#
# Three hunter processes, each hunting by a different sense. Every one of them
# dies to the breaker (the killability law is not negotiable) and every one is
# solo-survivable (the solo invariant): a lone agent must be able to complete a
# haunted run, so a hunter HAUNTS — costs integrity and Cycles when it catches
# you — but never erases the run (DESIGN.md's mercy layer). Injection depth is
# the only difficulty knob; there is no difficulty menu.
#
# The health numbers sit deliberately between the Scrubber (100, disposable) and
# the Sentinel (1800, a wall): a hunter is a fight you commit to and can finish
# alone with focused fire, not a bullet-sponge and not a pushover. All three
# scale past the depth floor exactly like the Sentinel's armour (Balance.
# hunter_health), so the deepest hunters do not get *easier* in real terms as the
# crew's Breaker climbs to tier 5.

## Escalation by depth (DESIGN.md): layers 1-5 have no hunters; from 6 the
## Director may run one class; the Auditor is a deep-layer process; past the
## double threshold the Director may run TWO at once (always Hound + one other).
const HUNT_START_LAYER: int = 6
const HUNT_AUDITOR_LAYER: int = 13
const HUNT_DOUBLE_LAYER: int = 15

## --- the Hound: hears ---
## Persistent stalker spawned by NOISE DEBT (NoiseBus). Relentless pursuit
## through the room graph; at low HP it breaks for the dark to recompile.
const HOUND_HEALTH: float = 300.0
const HOUND_PROWL_SPEED: float = 2.6
const HOUND_CHASE_SPEED: float = 5.6
const HOUND_LUNGE_SPEED: float = 9.4
const HOUND_FLEE_SPEED: float = 7.2
## How far it hears a running player once it is on the layer, and how far it will
## follow a scent before giving up and prowling.
const HOUND_HEAR_RANGE: float = 30.0
const HOUND_LOSE_RANGE: float = 44.0
const HOUND_LUNGE_RANGE: float = 3.2
const HOUND_LUNGE_DAMAGE: float = 12.0
const HOUND_LUNGE_TIME: float = 0.5
const HOUND_RECOVER_TIME: float = 1.2
## Noise debt (NoiseBus.debt) needed before the Director will vector the Hound at
## a fresh noise, and how long a noise event holds it on that scent.
const HOUND_NOISE_HOLD: float = 14.0
## Below this fraction of health it flees to darkness (the wounded-animal window).
const HOUND_FLEE_FRACTION: float = 0.30
## Once fleeing, this long unexposed in a dark room and it "recompiles" — slinks
## off (despawns) with no reward. Chasing it down inside the window is the choice.
const HOUND_FLEE_ESCAPE_TIME: float = 6.0
## What a finished Hound spills (the "large data burst" reward for the kill), and
## how long the layer stays quiet before the Director recompiles the process.
const HOUND_DROP_SHARDS: int = 10
const HOUND_DROP_PIECES: int = 4
const HOUND_SILENCE_TIME: float = 14.0
## Recompile delay after a kill (DESIGN.md: "minutes later ... its howl announces
## the timer restarting"). Tuned to gameplay minutes, not the dossier's nine.
const HOUND_RECOMPILE_TIME: float = 135.0
## A Hound that slinks off (escaped, not killed) recompiles sooner and quieter —
## you did not buy the silence.
const HOUND_SLINK_RECOMPILE_TIME: float = 70.0

## --- the Moth: sees light ---
## The inverse of the Scrubber: drawn to active beams, flares and muzzle flash.
## Fast and fragile-ish; shooting it makes muzzle light that excites it.
const MOTH_HEALTH: float = 150.0
const MOTH_DRIFT_SPEED: float = 2.2
const MOTH_SURGE_SPEED: float = 7.8
## How far the Moth senses light. A beam or flare inside this pulls it in.
const MOTH_LIGHT_RANGE: float = 34.0
## Strike reach and damage when it reaches the light you are holding.
const MOTH_STRIKE_RANGE: float = 2.6
const MOTH_STRIKE_DAMAGE: float = 10.0
const MOTH_STRIKE_COOLDOWN: float = 1.4
## A breaker shot is a muzzle flash: a light pulse at the shooter this long,
## which the Moth is drawn to even if the beam then goes dark.
const MOTH_MUZZLE_PULSE: float = 0.55
## With no light anywhere it loses interest and drifts; this long dark and it
## gives up the layer (despawns) so going dark genuinely loses it.
const MOTH_DARK_GIVEUP_TIME: float = 12.0
const MOTH_DROP_SHARDS: int = 5
const MOTH_DROP_PIECES: int = 3
const MOTH_RECOMPILE_TIME: float = 80.0

## --- the Auditor: has the schedule ---
## Deep-layer only, methodical, NOT reactive: walks the layer checking rooms in a
## fixed seeded order at a fixed rate. Tanky but killable; deleting it ENDS audits
## for that layer (the most earnable safety of the three).
const AUDITOR_HEALTH: float = 620.0
const AUDITOR_WALK_SPEED: float = 2.3
## How long it inspects each room before moving to the next on its route.
const AUDITOR_INSPECT_TIME: float = 3.2
## Strike reach and damage. It does not chase — it strikes whoever is beside it
## when it inspects, then walks on. Being on its route is the danger.
const AUDITOR_STRIKE_RANGE: float = 3.6
const AUDITOR_STRIKE_DAMAGE: float = 16.0
const AUDITOR_STRIKE_COOLDOWN: float = 2.0
const AUDITOR_DROP_SHARDS: int = 8
const AUDITOR_DROP_PIECES: int = 4

# --- M6 the Director: pacing + stress ---------------------------------------
#
# Host-authoritative. Tracks crew STRESS in [0,1] and paces the hunt: quiet
# dread, spike, mercy (L4D's AI director, MOTHER's two-brain knowledge from
# Alien: Isolation). When the crew is broken it WITHHOLDS — the predator toys
# with dying prey — invisible rubber-banding that reads as lore, not difficulty.

## Director decision tick. Slow: pacing is a mood, not a physics problem.
const HAUNT_TICK: float = 0.5
## Stress inputs, blended and clamped to [0,1]. Proximity and combat lead; a low
## pool and a crowded room push it over into terror.
const HAUNT_STRESS_PROX: float = 0.55
const HAUNT_STRESS_COMBAT: float = 0.35
const HAUNT_STRESS_CROWD: float = 0.24
const HAUNT_STRESS_STARVING: float = 0.26
## A hunter merely existing is a floor of dread even across the room.
const HAUNT_STRESS_HUNT_FLOOR: float = 0.22
## Seconds a hit or a kill keeps combat stress pinned before it decays.
const HAUNT_COMBAT_DECAY: float = 8.0
## How close a hunter is "on top of you" (stress 1) and how far is "gone" (0).
const HAUNT_PROX_NEAR: float = 4.0
const HAUNT_PROX_FAR: float = 30.0

## Withhold: the crew is broken when the pool is under this fraction, or average
## integrity is under this, or anyone is corrupted. While broken the Director
## stops pressing — no new spawns, and active hunters ease off.
const HAUNT_BROKEN_CYCLES: float = 0.12
const HAUNT_BROKEN_INTEGRITY: float = 0.30

## Spawn pacing. Pressure accrues per second and per unit of noise debt; when it
## crosses the threshold (and depth allows and a slot is free) the Director
## vectors a hunter in. Withholding freezes the accrual.
const HAUNT_PRESSURE_THRESHOLD: float = 100.0
const HAUNT_PRESSURE_PER_SEC: float = 3.4
const HAUNT_PRESSURE_PER_NOISE: float = 2.2
## A grace period after arriving on a layer before the first spawn can land, so a
## descent is not immediately a jump scare.
const HAUNT_FIRST_DELAY: float = 18.0
## After a hunter leaves (killed/slunk) the pressure resets to this fraction of
## threshold, so the next one is paced, not instant.
const HAUNT_PRESSURE_AFTER_SPAWN: float = 0.15

# --- M6 MOTHER barks (the corpus budget) ------------------------------------
#
# 183 barks in limbo-lore/corpus.json, categorised, depth-gated and pre-rendered
# at three corruption tiers. The Director speaks them by context, and the budget
# is the whole discipline — MOTHER noticing is rare on purpose (DESIGN.md: "she
# addresses players by callsign. Rarely."). Over-speaking her is the one way to
# make the money moments cheap.

## Callsign address lines: at most one per layer, three per intrusion. The
## rarest, highest-impact category — the "she has always known" beat.
const BARK_ADDRESS_PER_LAYER: int = 1
const BARK_ADDRESS_PER_RUN: int = 3
## Minimum seconds between ANY two barks, so she never chatters.
const BARK_MIN_GAP: float = 9.0
## Minimum seconds between two address lines specifically — even rarer.
const BARK_ADDRESS_MIN_GAP: float = 45.0
## Corruption tier by depth (matches the depth bands): tier 0 clean on the
## surface, tier 1 through the working rings, tier 2 in the legacy deep. The
## renderings are pre-baked in the corpus; this only picks which one.
const BARK_CORRUPT_TIER1_LAYER: int = 6
const BARK_CORRUPT_TIER2_LAYER: int = 15

# --- M6 glitch-proximity sense + Dampened Protocol --------------------------
#
# The HUD's corruption static rises as a hunter nears — your screen breaking IS
# the radar. It is a NEW flash source, so it is bounded by the A11y flash caps
# (the safety law) exactly like every other glitch: the ceiling below is the
# unconditional cap, scaled further down by A11y.flash_scale and by Dampened
# Protocol. It is an amplitude ramp, never a strobe — no term added here flashes.

## Range over which a hunter drives the HUD static (1 on top of you, 0 beyond).
const HAUNT_GLITCH_NEAR: float = 3.0
const HAUNT_GLITCH_FAR: float = 26.0
## Unconditional ceiling on the proximity static, well under the shaders' own
## caps. Dampened Protocol lowers it further.
const HAUNT_GLITCH_CEILING: float = 0.62
## How fast the static ramps toward its target, so it breathes rather than snaps.
const HAUNT_GLITCH_RATE: float = 1.8

## Dampened Protocol (DESIGN.md mercy layer): softens PRESENTATION, not
## difficulty. The single settings toggle ties the audio comfort M5 shipped to
## these visual softeners — jumpscare sharpness, hunter-reveal intensity and the
## glitch-proximity ceiling all multiply by this when it is on.
const DAMPENED_REVEAL_SCALE: float = 0.55
const DAMPENED_GLITCH_SCALE: float = 0.5

# =============================================================================
# M7 — SUBROUTINES (the ability kit)
# =============================================================================
#
# NOTHING ABOVE THIS LINE WAS TOUCHED. The Cycles economy was retuned by PT1 and
# the balance lab and those constants are settled; everything below is new, and
# it is priced *against* them rather than by adjusting them.
#
# ## The fiction, and why it costs breath
#
# You are software. A subroutine is a routine compiled into your program, and
# running one costs the thing you run ON — the shared pool. DESIGN.md pillar 1
# makes Cycles "the clock, the economy, and the argument the crew has over voice
# chat", so a power that did not touch it would sit outside the only tension the
# game has. Every cast BURNS from the crew pool. Power always costs breath.
#
# ## How the costs were chosen
#
# The unit that makes a cost legible is **seconds of solo runtime**: at
# PASSIVE_DRAIN 0.3/s one Cycle is 3.33 s of existing, and a fresh solo agent
# injects with CYCLES_PER_CREW 100 — about 333 s. Against that ladder:
#
#   FLARE_CYCLE_COST      8    ~27 s     the existing reference point.
#   SURGE STEP            6    ~20 s     an escape you may take often.
#   STACK PULSE          14    ~47 s     the co-op save button. Once a fight.
#   FORK DECOY           22    ~73 s     a fifth of a solo life. A plan, not a
#                                        reflex.
#   CHECKSUM BARRIER     28    ~93 s     the most expensive thing a program can
#                                        do. You buy three seconds for it.
#
# In a four-crew the pool is ~400, so the same cast is a quarter of the fraction
# — correct, and the same shape the siphon's crew-scaled yield already has: a
# crew can afford to be powerful more often than a lone agent, and the lone agent
# is the one DESIGN.md says should be the scariest way to play.
#
# ## Two laws these numbers are written under
#
#   **The solo invariant.** Every subroutine is fully usable alone and NONE of
#   them is on a critical path. Nothing in the game is gated behind owning one:
#   they are power, never keys. A player who never buys one can complete
#   everything a player who bought all four can.
#
#   **The killability law's cousin.** STACK PULSE is CONTROL, not damage — it
#   staggers, interrupts and knocks back, and it cannot kill. Nothing here makes
#   a process immune to the breaker and nothing here deletes one for free.
#
# The catalogue mirrors `MODULES` exactly (name/glyph/note/prices + per-tier
# effect arrays where index 0 is "not compiled"), so `Modules.value_at`-shaped
# lookups work unchanged and the Compiler panel draws both from one idiom.

## Order the Compiler's SUBROUTINES section and the HUD's swap list use.
## Cheapest and most reflexive first, most expensive and most deliberate last —
## the same "keeps you alive -> changes the fight" sort MODULE_TRACKS uses.
const SUBROUTINE_TRACKS: Array[String] = [
	"surge_step", "stack_pulse", "fork_decoy", "checksum_barrier",
]

## Every subroutine goes to three tiers. Three, not five: a subroutine is a verb
## you either have or do not, and the tiers only make the verb cheaper and
## slightly wider. A five-tier ability track would turn a kit into a build.
const SUBROUTINE_MAX_TIER: int = 3

const SUBROUTINES: Dictionary = {
	# --- SURGE STEP: process migration ---------------------------------------
	# A 6 m slide, not a teleport: it MOVES the avatar through the world with its
	# own collision, so it cannot pass a wall and cannot be used to skip geometry
	# the generator meant you to walk around. The i-frames are the point — they
	# are what makes it an answer to a lunge already in the air rather than a
	# faster walk. The Hound learns nothing from it. It just misses.
	"surge_step": {
		"name": "SURGE STEP",
		"glyph": "»",
		"note": "6 m PROCESS MIGRATION  ·  BRIEF INVULNERABILITY",
		"prices": [180, 900, 3200],
		"cost": [0.0, 6.0, 5.0, 4.0],
		"cooldown": [0.0, 4.0, 3.4, 2.8],
		"distance": [0.0, 6.0, 6.0, 6.5],
		## Seconds of i-frames. A Scrubber lunge commits for 0.45 s
		## (SCRUBBER_LUNGE_TIME) and lands once; 0.20 s of immunity placed by the
		## player covers the strike, never the whole commit.
		"iframes": [0.0, 0.20, 0.22, 0.26],
	},
	# --- STACK PULSE: radial interrupt ---------------------------------------
	# Control, not damage (the killability law is not negotiable and this does not
	# bend it: a pulse has never killed anything). It cancels lunges, knocks
	# Scrubbers back and stuns a Sentinel for a beat. It is also LOUD — a full
	# two-room NoiseBus ping, so the Hound hears every single one. The crew's
	# panic button rings a bell.
	"stack_pulse": {
		"name": "STACK PULSE",
		"glyph": "◎",
		"note": "6 m INTERRUPT BURST  ·  VERY LOUD",
		"prices": [220, 1100, 3800],
		"cost": [0.0, 14.0, 12.0, 10.0],
		"cooldown": [0.0, 9.0, 8.0, 7.0],
		"radius": [0.0, 6.0, 6.5, 7.0],
		## How long a staggered process is out of the fight. Comfortably longer
		## than SCRUBBER_RECOVER_TIME so a cancelled lunge is a real reprieve.
		"stagger": [0.0, 1.2, 1.5, 1.8],
		## Metres of knockback applied to light processes. Heavy ones (Sentinel,
		## Auditor) are stunned in place instead — a 2.6 m mass does not skid.
		"knockback": [0.0, 3.2, 3.8, 4.4],
	},
	# --- FORK DECOY: a copy of you, walking away ------------------------------
	# The solo lifesaver, and the one subroutine that is *better* alone: a crew
	# has crewmates to draw aggro, and an agent on their own has nothing. It forks
	# a ghost of your avatar, walks it forward, and every process that hunts by
	# position goes with it until it decompiles.
	"fork_decoy": {
		"name": "FORK DECOY",
		"glyph": "◈",
		"note": "GHOST FORK DRAWS ANTIVIRUS  ·  DECOMPILES ON A TIMER",
		"prices": [420, 1800, 5600],
		"cost": [0.0, 22.0, 19.0, 16.0],
		"cooldown": [0.0, 26.0, 22.0, 18.0],
		"lifetime": [0.0, 6.0, 7.0, 8.0],
		## How far it walks over its life, in metres. 10 m over 6 s is a walk, not
		## a sprint: a decoy that outran the thing chasing it would be useless.
		"walk": [0.0, 10.0, 11.0, 12.0],
		## Radius inside which a process prefers the fork to a real crew member.
		"lure": [0.0, 22.0, 26.0, 30.0],
		## Strikes it soaks before it decompiles early. It is a copy of a program,
		## not a wall.
		"hits": [0, 3, 4, 5],
	},
	# --- CHECKSUM BARRIER: integrity, held ------------------------------------
	# Three seconds of a spherical integrity shell that absorbs damage for ANYONE
	# standing inside it, crew included — the one subroutine whose value goes UP
	# with the number of people around you, and therefore the co-op positioning
	# play. Expensive enough that using it is a decision the crew talks about.
	#
	# MOTHER notices. A barrier is a program asserting its own integrity inside
	# hers, and the Director's combat stress is pinned by every cast.
	"checksum_barrier": {
		"name": "CHECKSUM BARRIER",
		"glyph": "⌾",
		"note": "3 s INTEGRITY SHELL  ·  ABSORBS FOR THE CREW INSIDE",
		"prices": [520, 2200, 6800],
		"cost": [0.0, 28.0, 24.0, 20.0],
		"cooldown": [0.0, 30.0, 26.0, 22.0],
		"duration": [0.0, 3.0, 3.0, 3.5],
		"radius": [0.0, 3.4, 3.8, 4.2],
		## Total integrity absorbed before the shell fails. A Sentinel purge is 26
		## and a Scrubber lunge is 9, so tier 1 eats a purge and a bite, or five
		## bites — a fight's worth of mistakes, not a fight's worth of health.
		"absorb": [0.0, 45.0, 65.0, 90.0],
	},
}

## Compiler stock gate for subroutines. A Compiler stocks a subroutine tier when
## its own `stock_tier` reaches it, exactly like a module — so tier 1 of the two
## cheap subroutines is available at the first Compiler a fresh crew finds, which
## is the "cheap tier-1 versions early" the kit is designed around.

# --- M7 cast presentation ----------------------------------------------------
#
# SAFETY LAW (DESIGN.md pillar 7). Every effect below is a NEW light source, so
# every one of them is bounded here rather than in the effect that draws it, and
# the numbers are asserted by `--selftest`. Two rules run through all of them:
#
#   1. **No effect flashes.** Each is a single rise-and-fall envelope — one
#      bloom, decaying — never a repeating cycle. A one-shot cannot strobe.
#   2. **The rate is governed anyway**, because a player can cast repeatedly.
#      `SUB_FLASH_MIN_INTERVAL` is the same shape and the same reasoning as
#      `Antivirus.HURT_FLASH_MIN_INTERVAL`: at most one full-amplitude bloom per
#      interval, so the ceiling is under 3 Hz UNCONDITIONALLY with Reduced
#      Flashing OFF. The shortest cooldown in the kit is 2.8 s, so the governor
#      is not even reachable by legitimate play — it is there so that a future
#      cooldown cut, or a bug, fails in `--selftest` instead of in a living room.

## Minimum seconds between two full-amplitude ability blooms. 0.36 s == 2.78 Hz.
const SUB_FLASH_MIN_INTERVAL: float = 0.36
## Unconditional ceiling on a cast bloom's light energy, before A11y scaling.
## STACK PULSE is the brightest thing in the kit and it sits here.
const SUB_FLASH_ENERGY: float = 5.0
## How fast a cast bloom decays, in energy per second. ~0.35 s to black from the
## ceiling: long enough to read, far too short to be a second flash.
const SUB_FLASH_DECAY: float = 14.0

## Screen shake handed out by each cast, in `Player.add_shake` units. Tiny and
## damped — the shake discipline below caps how often any of it can land.
const SUB_SHAKE_STEP: float = 0.28
const SUB_SHAKE_PULSE: float = 0.55
const SUB_SHAKE_BARRIER: float = 0.30
const SUB_SHAKE_DECOY: float = 0.18

# --- M7 juice: shake discipline ----------------------------------------------
#
# "Punchy screen shake discipline (tiny, damped, a11y-scaled, never >2 shakes/s)".
# The shake itself is `Player._shake`, which has been a damped rotational noise
# since M4.7 and is not changed. What is new is a GOVERNOR on how often a fresh
# impulse may be added, because M7 adds several new sources (impacts, landings,
# kills, four abilities) on top of the two M3 had — and a camera that is shaken
# by everything is a camera nobody can aim.
#
# Bounded three ways: a minimum interval between impulses, a hard ceiling on the
# accumulated weight, and `A11y.effect_scale("shake")` on top of both so Reduced
# Flashing takes the whole thing to nothing.
## Minimum seconds between two accepted shake impulses. 0.5 s == 2 per second,
## the stated budget. A stronger impulse arriving inside the window is not
## dropped — it is admitted at the difference, so a kill during a firefight still
## reads while ten small hits do not stack into a tremor.
const SHAKE_MIN_INTERVAL: float = 0.5
## Ceiling on the accumulated shake weight, matching `Player.add_shake`'s clamp.
const SHAKE_CEILING: float = 1.2

# --- M7 juice: landing dust tiers --------------------------------------------
#
# The verticality noise tiers (Player.LAND_NOISE_SPEED / LAND_LOUD_SPEED /
# LAND_HURT_SPEED) already tell the player how much a drop cost them in NOISE.
# The dust puff is the same information delivered a beat earlier and in a
# different sense: you see how hard you landed before you hear who heard it.
# Particle counts per tier, so the three tiers are visibly three tiers.
const LAND_DUST_SOFT: int = 8
const LAND_DUST_LOUD: int = 18
const LAND_DUST_HURT: int = 34

# --- M7 juice: the decompile shatter -----------------------------------------
#
# THE money effect: a deleted process comes apart into glowing fragments that
# scatter, tumble and fade. It is cosmetic, local, and spawned from the death
# event every peer already receives — it consumes no RNG (variation is
# hash-derived from the creature's own slot index and position, so two peers draw
# the same shatter without a packet).
#
# Budgeted rather than generous: the perf target is 4 players + 6 processes +
# effects at 60 fps, and a shatter is the single largest particle allocation in
# the game. One pooled emitter per creature size class, capped counts.
const SHATTER_FRAGMENTS_LIGHT: int = 46
const SHATTER_FRAGMENTS_HEAVY: int = 96
const SHATTER_LIFETIME: float = 1.35
## The dying coal at the point of deletion, and how fast it goes out. A fading
## glow, never a flash — this is the safety law applied to the prettiest effect
## in the game rather than in spite of it.
const SHATTER_GLOW_ENERGY: float = 3.2
const SHATTER_GLOW_DECAY: float = 3.6

# --- M7 juice: pooled scorch decals -------------------------------------------

## How many breaker scorches may be on a layer at once before the oldest is
## recycled, and how long one takes to fade. Pooled: the nodes are created once
## and moved, never allocated per shot.
const SCORCH_POOL: int = 24
const SCORCH_LIFETIME: float = 7.0
const SCORCH_SIZE: float = 0.42

# =============================================================================
# M9 — PATCHES (run-scoped hot-patches)
# =============================================================================
#
# NOTHING ABOVE THIS LINE WAS TOUCHED. Everything below is new and is priced
# *against* the settled economy rather than by adjusting it.
#
# ## The fiction, and why it is run-scoped
#
# A module is compiled into your SOURCE and survives everything (DESIGN.md's
# meta-progression: "deletion in-system only kills the running instance; your
# source is safe outside"). A patch is the opposite of that and deliberately so:
# it is a HOT-PATCH injected into the instance that is currently executing. It
# lives in process memory, not in your source, so it dies with the instance —
# gone on a wipe, and gone on exfil too, because the process you exfiltrate is
# the process you stop running.
#
# That is what makes patches the roguelite half of a game whose meta-progression
# is permanent. Modules are the build you keep; patches are the build this run
# happened to hand you. Exfiltrating converts each carried patch into a small
# data bonus (`PATCH_EXFIL_DATA`), so a stacked run that ends well still pays —
# you sell the patch back rather than keeping it.
#
# ## The law these numbers are written under: THE ECONOMY STAYS THE BOSS
#
# DESIGN.md pillar 1 makes Cycles "the clock, the economy, and the argument the
# crew has over voice chat", pillar 2 makes the dark the enemy, and pillar 3
# makes greed the thing that kills you. A patch may bend any of those; none may
# break one. Concretely, and every one of these is asserted by `--selftest`:
#
#   * **No free light.** Nothing here widens a beam, brightens a flare or lights
#     a room. SLEEP STATE — the one patch that touches the drain hard — pays you
#     for turning your beam OFF, which pushes *into* pillar 2 rather than out of
#     it.
#   * **No silent-everything.** ZERO PAGE lowers landing noise by one room-tier
#     per stack and touches nothing else; the siphon, the breaker, the terminal,
#     the pulse and the pickups themselves stay exactly as loud as they were.
#     There is no patch anywhere in the catalogue that reduces any other noise.
#   * **The drain cannot be trivialised.** Every Cycles refund is capped per
#     layer (`PATCH_GC_LAYER_CAP_FRACTION`) and every drain reduction has a hard
#     floor (`PATCH_SLEEP_FLOOR`, `PATCH_RACE_MAX`). A maxed patch build still
#     runs out of clock.
#   * **The killability law is untouched.** Nothing here makes a process immune
#     to the breaker and nothing deletes one outside the breaker: TAIL CALL and
#     BIT ROT are both the cutter's OWN damage, chained and delayed, routed
#     through `Antivirus.take_damage` like every other cut.
#   * **The solo invariant.** No patch is required for anything, none is a key,
#     and the catalogue is never a gate. A run that finds nothing is a run.
#
# ## Stacking
#
# Risk-of-Rain shaped: finding the same patch again does not upgrade it, it
# ADDS ONE. Stack count multiplies or extends the effect, and every effect has a
# named ceiling so a lucky run is powerful rather than broken. `PATCH_MAX_STACKS`
# is 6 for the same reason the HUD strip draws a single numeral: past six the
# ceilings have all bound anyway, and a two-digit stack count is a spreadsheet.

## Rarity tiers. STABLE is the bread and butter, UNSTABLE reshapes a fight,
## KERNEL is build-defining and rare. Ints rather than an enum because they index
## the weight arrays below and are written into the wire packet.
const PATCH_TIER_STABLE: int = 0
const PATCH_TIER_UNSTABLE: int = 1
const PATCH_TIER_KERNEL: int = 2

## Ceiling on how many of one patch a program may be carrying. See above.
const PATCH_MAX_STACKS: int = 6

## Order the HUD strip and the inspect list use: tier first, then the catalogue's
## own order inside a tier, so a KERNEL patch is always at the end of the strip
## and always in the same place.
const PATCH_TRACKS: Array[String] = [
	# --- STABLE ---
	"hot_loop", "garbage_collect", "parity_bit", "priority_boost",
	"zero_page", "instruction_fusion",
	# --- UNSTABLE ---
	"speculative_execution", "bit_rot", "overflow", "race_condition",
	"nop_sled", "dead_code",
	# --- KERNEL ---
	"tail_call", "watchdog", "sleep_state",
]

## The catalogue. Shape deliberately mirrors `MODULES` / `SUBROUTINES` —
## name/glyph/note — minus the per-tier effect arrays, because a patch has no
## tiers: it has a STACK COUNT, and the numbers it multiplies are the constants
## below. `tier` here is RARITY, not power level.
##
## Glyphs are kept inside the Geometric Shapes / Block Elements ranges for the
## same reason the interact prompts are (`Interactable.prompt_glyph`): they have
## to resolve on every font in the system fallback chain, and an icon that draws
## as a box on somebody's machine is not an icon.
const PATCHES: Dictionary = {
	# --- STABLE ---------------------------------------------------------------
	"hot_loop": {
		"name": "HOT LOOP",
		"glyph": "◐",
		"tier": PATCH_TIER_STABLE,
		"note": "CONSECUTIVE HITS ON ONE PROCESS RAMP",
	},
	"garbage_collect": {
		"name": "GARBAGE COLLECT",
		"glyph": "◌",
		"tier": PATCH_TIER_STABLE,
		"note": "DELETIONS REFUND CYCLES  ·  CAPPED PER LAYER",
	},
	"parity_bit": {
		"name": "PARITY BIT",
		"glyph": "◫",
		"tier": PATCH_TIER_STABLE,
		"note": "ERROR CORRECTION SHAVES EVERY HIT",
	},
	"priority_boost": {
		"name": "PRIORITY BOOST",
		"glyph": "▶",
		"tier": PATCH_TIER_STABLE,
		"note": "MOVE SPEED ↑  ·  DIMINISHING",
	},
	"zero_page": {
		"name": "ZERO PAGE",
		"glyph": "▽",
		"tier": PATCH_TIER_STABLE,
		"note": "LANDING NOISE ↓ ONE TIER PER STACK",
	},
	"instruction_fusion": {
		"name": "INSTRUCTION FUSION",
		"glyph": "◨",
		"tier": PATCH_TIER_STABLE,
		"note": "CUTTER HEAT PER SHOT ↓",
	},
	# --- UNSTABLE -------------------------------------------------------------
	"speculative_execution": {
		"name": "SPECULATIVE EXECUTION",
		"glyph": "◗",
		"tier": PATCH_TIER_UNSTABLE,
		"note": "FIRST SHOT AFTER A PAUSE CRITS",
	},
	"bit_rot": {
		"name": "BIT ROT",
		"glyph": "▚",
		"tier": PATCH_TIER_UNSTABLE,
		"note": "CUTS LEAVE A DECAY THAT KEEPS EATING",
	},
	"overflow": {
		"name": "OVERFLOW",
		"glyph": "◍",
		"tier": PATCH_TIER_UNSTABLE,
		"note": "STACK PULSE RADIUS + HOLD ↑  ·  AS LOUD AS EVER",
	},
	"race_condition": {
		"name": "RACE CONDITION",
		"glyph": "◪",
		"tier": PATCH_TIER_UNSTABLE,
		"note": "FIRST SECONDS OF A SPRINT BILL AS A WALK",
	},
	"nop_sled": {
		"name": "NOP SLED",
		"glyph": "▱",
		"tier": PATCH_TIER_UNSTABLE,
		"note": "SURGE STEP INVULNERABILITY ↑",
	},
	"dead_code": {
		"name": "DEAD CODE",
		"glyph": "▧",
		"tier": PATCH_TIER_UNSTABLE,
		"note": "FORK DECOYS LIVE LONGER AND SOAK MORE",
	},
	# --- KERNEL ---------------------------------------------------------------
	"tail_call": {
		"name": "TAIL CALL",
		"glyph": "▷",
		"tier": PATCH_TIER_KERNEL,
		"note": "THE CUT CHAINS TO A NEARBY PROCESS",
	},
	"watchdog": {
		"name": "WATCHDOG",
		"glyph": "◒",
		"tier": PATCH_TIER_KERNEL,
		"note": "ONE FREE SHELL PER LAYER AT CRITICAL INTEGRITY",
	},
	"sleep_state": {
		"name": "SLEEP STATE",
		"glyph": "◑",
		"tier": PATCH_TIER_KERNEL,
		"note": "PASSIVE DRAIN ↓ WHILE YOUR BEAM IS OFF",
	},
}

# --- STABLE effects ----------------------------------------------------------

## HOT LOOP. Consecutive cuts on the SAME process ramp. 7% a hit, three ramp
## steps bought per stack, and a hard ceiling at +90% so a six-stack build is a
## faster kill rather than a different game. The window is generous enough to
## survive a Scrubber crossing the crosshair and short enough that the ramp is
## about staying on one target rather than about firing at all.
const PATCH_HOTLOOP_STEP: float = 0.07
const PATCH_HOTLOOP_STEPS_PER_STACK: int = 3
const PATCH_HOTLOOP_MAX: float = 0.90
const PATCH_HOTLOOP_WINDOW: float = 1.6

## GARBAGE COLLECT. A deleted process frees the memory it was holding, and you
## take it. 1.6 Cycles a stack for a light process, triple for a heavy one.
##
## THE CAP IS THE WHOLE DESIGN. Uncapped, a six-stack GARBAGE COLLECT in a nest
## turns the antivirus into a siphon tap and the pool stops being the clock. So
## refunds are tallied per LAYER against a fraction of the crew's own pool
## ceiling: at 25% a good layer is worth about half a siphon, which is a real
## reward that never replaces going and finding the tap.
const PATCH_GC_PER_STACK: float = 1.6
const PATCH_GC_HEAVY_MULT: float = 3.0
const PATCH_GC_LAYER_CAP_FRACTION: float = 0.25

## PARITY BIT. A flat shave off every incoming hit, never a fraction of it — so
## it is worth most against a Scrubber's 9 and least against a Sentinel's 26,
## which is the right way round for a common patch. Bounded twice: a stack is
## only 0.9 integrity, and no amount of stacking may eat more than 40% of a blow.
const PATCH_PARITY_PER_STACK: float = 0.9
const PATCH_PARITY_MAX_FRACTION: float = 0.40

## PRIORITY BOOST. Deliberately the most diminishing thing in the catalogue:
## `1 + CEILING * (1 - FALLOFF^stacks)`, so stack 1 is worth +5.4%, stack 6 is
## worth +11.6%, and the asymptote is +12%.
##
## The ceiling is not an aesthetic choice. `WALK_SPEED * max(Servos.move) *
## (1 + CEILING)` must stay under `SPRINT_BILLING_SPEED`, or a maxed-Servos
## patched walk starts billing the pool at the sprint rate for walking — the
## exact failure the M4.9 balance lab raised the threshold to fix. 4.2 * 1.22 *
## 1.12 = 5.74 against a 6.0 threshold. `--selftest` asserts the margin.
const PATCH_PRIORITY_CEILING: float = 0.12
const PATCH_PRIORITY_FALLOFF: float = 0.55

## ZERO PAGE. One room-tier of landing noise per stack, floored at "this room
## only" — a drop is never silent, it just stops carrying next door. The synergy
## with M6.6's verticality is the point: the shortcut down a shaft was priced in
## noise, and this is the patch that makes taking it a habit.
##
## It does NOT touch the fall's DAMAGE, and it does not touch any other noise in
## the game. There is exactly one caller.
const PATCH_ZEROPAGE_PER_STACK: int = 1

## INSTRUCTION FUSION. Macro-op fusion: two operations issued as one, so the
## cutter does the same work for less heat. 11% a stack against a floor of 0.55 —
## the tool always heats, and the lockout is always reachable by a held trigger.
const PATCH_FUSION_PER_STACK: float = 0.11
const PATCH_FUSION_FLOOR: float = 0.55

# --- UNSTABLE effects --------------------------------------------------------

## SPECULATIVE EXECUTION. The branch was predicted while you were not firing, so
## the first shot after a pause lands with the work already done. +85% a stack
## against a +200% ceiling (a 3x cut), and the idle window shortens with stacks
## to a 2.0 s floor so a stacked build rewards a rhythm rather than a stopwatch.
const PATCH_SPEC_IDLE: float = 3.0
const PATCH_SPEC_IDLE_PER_STACK: float = 0.35
const PATCH_SPEC_IDLE_FLOOR: float = 2.0
const PATCH_SPEC_BONUS_PER_STACK: float = 0.85
const PATCH_SPEC_MAX: float = 2.00

## BIT ROT. A cut leaves corruption behind that keeps eating: 7% of the landed
## hit a stack, spread over four seconds, capped at 30% of the hit.
##
## It is the BREAKER'S damage, delayed — dealt through `Antivirus.take_damage`
## from the host, credited to the shooter, and it cannot start on a process the
## breaker never touched. The killability law is a statement about what kills
## things, and rot does not add a new killer; it stretches an existing one out.
## A fresh cut REFRESHES the decay rather than adding a second one, so six
## stacks is one heavier rot and never six overlapping timers.
const PATCH_ROT_FRACTION_PER_STACK: float = 0.07
const PATCH_ROT_MAX_FRACTION: float = 0.30
const PATCH_ROT_SECONDS: float = 4.0
## How often the host applies a tick of it. Slower than the AI tick on purpose:
## rot is a slow leak, and a 15 Hz leak is a second weapon.
const PATCH_ROT_TICK: float = 0.5

## OVERFLOW. STACK PULSE reaches further and holds longer. Radius +14% a stack
## to +45%; stagger +0.12 s a stack to +0.4 s.
##
## The NOISE is untouched, and that is the balance. The pulse's defining cost is
## that it rings a two-room bell the Hound hears; a patch that made the panic
## button quieter would delete the ability's whole price. A bigger pulse is a
## bigger bell.
const PATCH_OVERFLOW_RADIUS_PER_STACK: float = 0.14
const PATCH_OVERFLOW_RADIUS_MAX: float = 0.45
const PATCH_OVERFLOW_STAGGER_PER_STACK: float = 0.12
const PATCH_OVERFLOW_STAGGER_MAX: float = 0.40

## RACE CONDITION. The scheduler has not noticed you are sprinting yet. For the
## first 1.5 s (+0.55 s a stack, ceiling 3.2 s) of a sprint the SPRINT SURCHARGE
## is suspended — the passive drain still runs, because you still exist.
##
## Re-arms only after four seconds under the billing speed, so it is a burst
## across a corridor, never a free sprint held by tapping the key.
const PATCH_RACE_SECONDS: float = 1.5
const PATCH_RACE_PER_STACK: float = 0.55
const PATCH_RACE_MAX: float = 3.2
const PATCH_RACE_REARM: float = 4.0

## NOP SLED. More instructions to slide down: +0.055 s of SURGE STEP immunity a
## stack, ceiling +0.18 s. Against `SCRUBBER_LUNGE_TIME` 0.45 even a maxed sled
## (0.26 + 0.18 = 0.44) still does not cover a whole commit — it covers the
## strike, which is what an i-frame is for.
const PATCH_NOPSLED_PER_STACK: float = 0.055
const PATCH_NOPSLED_MAX: float = 0.18

## DEAD CODE. Nobody collected it, so it keeps running. Fork lifetime +30% a
## stack to +90%, and one extra strike soaked per two stacks to a ceiling of +3.
const PATCH_DEADCODE_LIFE_PER_STACK: float = 0.30
const PATCH_DEADCODE_LIFE_MAX: float = 0.90
const PATCH_DEADCODE_HITS_PER_TWO_STACKS: int = 1
const PATCH_DEADCODE_HITS_MAX: int = 3

# --- KERNEL effects ----------------------------------------------------------

## TAIL CALL. The cut does not return — it jumps straight into the next frame.
## A landed breaker hit chains to the nearest OTHER process within 6.5 m, at 45%
## of the parent hit, decaying 0.72 per further link. One link, plus one a stack,
## to a ceiling of four.
##
## Routed through `Antivirus.take_damage` from the host, credited to the shooter,
## and a process already in the chain is never revisited. It is the breaker's own
## damage arriving somewhere else, which is why the killability law does not
## budge: the chain kills nothing the breaker could not have killed by aiming.
const PATCH_TAILCALL_RANGE: float = 6.5
const PATCH_TAILCALL_LINKS: int = 1
const PATCH_TAILCALL_LINKS_PER_STACK: int = 1
const PATCH_TAILCALL_LINKS_MAX: int = 4
const PATCH_TAILCALL_FALLOFF: float = 0.45
const PATCH_TAILCALL_DECAY: float = 0.72

## WATCHDOG. The timer nobody kicked. Once a layer, a hit that would take you to
## or under 28% integrity is absorbed WHOLE and a free CHECKSUM BARRIER goes up
## around you — the same shell the subroutine casts, reused rather than reinvented,
## so the crew standing with you are covered by it exactly as they would be.
##
## +1 charge a layer a stack to a ceiling of three, and the charges reset on
## descent rather than accumulating: this is insurance against a layer, not a
## stock of lives.
const PATCH_WATCHDOG_TRIGGER_FRACTION: float = 0.28
const PATCH_WATCHDOG_CHARGES_PER_STACK: int = 1
const PATCH_WATCHDOG_CHARGES_MAX: int = 3
const PATCH_WATCHDOG_SHELL_ABSORB: float = 45.0
const PATCH_WATCHDOG_SHELL_SECONDS: float = 3.0
const PATCH_WATCHDOG_SHELL_RADIUS: float = 3.4

## SLEEP STATE. The build-defining one, and the only patch that touches the
## passive drain — in the direction pillar 2 wants. While your beam is OFF your
## share of the drain is scaled by (1 - 0.30 a stack) against a 0.40 floor: at
## most a 60% saving, bought by playing in the dark you were already told was the
## enemy. It gives you no light, it does not touch the sprint surcharge, and the
## moment you switch your beam on you pay full rate again.
const PATCH_SLEEP_PER_STACK: float = 0.30
const PATCH_SLEEP_FLOOR: float = 0.40

# --- acquisition -------------------------------------------------------------
#
# Three sources, and their rarity mixes are the whole progression curve of a run.
# Every roll is HASH-DERIVED from (run seed, layer, source tag, index) and never
# consumes the shared RNG stream — DESIGN.md's determinism law. That means every
# peer computes the same answer for the same slate before anybody touches it, and
# the host's grant is a validation rather than a broadcast of a secret.

## Weights per rarity tier, indexed by PATCH_TIER_*.
##
## The POCKET SECRETARY is the bread and butter: a slate somebody left behind, so
## it is mostly STABLE with a real chance of something better. A deleted process
## drops even more conservatively — the reward for fighting is the data, and a
## patch on top is a bonus. The ANOMALY CACHE is the only reliable route to a
## KERNEL patch in the game, which is what makes walking to one worth the noise.
const PATCH_WEIGHTS_SLATE: Array[int] = [66, 30, 4]
const PATCH_WEIGHTS_DROP: Array[int] = [72, 26, 2]
const PATCH_WEIGHTS_ANOMALY: Array[int] = [0, 30, 70]

## How many pocket secretaries the generator leaves on a layer. Two on the
## surface, four by the depth floor: the patch economy opens up exactly as the
## threat curve stops being survivable bare.
const PATCH_SLATES_MIN: int = 2
const PATCH_SLATES_MAX: int = 4
## Layers per extra slate above the minimum.
const PATCH_SLATES_PER_LAYER: int = 6

## Chance a deleted process leaves a slate behind, by weight class. A Scrubber is
## disposable and almost never carries anything; a quarantine process and a
## hunter are the two things in the game you commit to a fight for.
const PATCH_DROP_CHANCE_LIGHT: float = 0.014
const PATCH_DROP_CHANCE_HEAVY: float = 0.22
const PATCH_DROP_CHANCE_HUNTER: float = 0.34

## The anomaly cache appears every N layers, with N and the phase both derived
## from the run seed — so "every two or three layers" is true of the run rather
## than of the game, and two crews on two seeds do not learn one timetable.
const PATCH_ANOMALY_PERIOD_MIN: int = 2
const PATCH_ANOMALY_PERIOD_MAX: int = 3

## Pickup. Walk over it, hold the channel, absorb the hot-patch; the slate then
## powers dead and stays where it is as inert dressing. The cache takes longer
## because it is a container being opened rather than a slate being read.
const PATCH_SLATE_CHANNEL: float = 0.5
const PATCH_CACHE_CHANNEL: float = 1.1
## Host-side proximity gate on a grant. Generous like every other `_at_prop`
## reach: the job is to tell "stood at it" from "sent a packet".
const PATCH_PICKUP_REACH: float = 4.0

## GREED HAS A PRICE. Reading a slate wakes it up and it announces itself; a
## cache is a sealed container being cracked. One room and two rooms — the
## terminal-query and the siphon-drain rungs of the existing noise ladder, not
## new ones.
const PATCH_SLATE_NOISE_ROOMS: int = NOISE_ROOMS_TERMINAL
const PATCH_SLATE_NOISE_TIME: float = NOISE_TIME_TERMINAL
const PATCH_CACHE_NOISE_ROOMS: int = NOISE_ROOMS_JUNCTION
const PATCH_CACHE_NOISE_TIME: float = NOISE_TIME_JUNCTION

## What one carried stack is worth on exfiltration, by rarity tier. Priced
## against the module ladder: a full six-stack KERNEL build is ~720 data, which
## is roughly one cheap module tier — a good run's patches pay for a permanent
## upgrade, and never for a build.
const PATCH_EXFIL_DATA: Array[int] = [18, 45, 120]

# --- presentation ------------------------------------------------------------
#
# SAFETY LAW (DESIGN.md pillar 7). The pickup burst is a NEW light source, so it
# is bounded here rather than in the effect that draws it and it is asserted by
# `--selftest`. It is one rise-and-fall envelope — a bloom, decaying — so it
# cannot strobe by construction, and it goes through `Fx.flash_gate()` and
# `A11y.flash_scale` on top like every other bloom in the game.

## Unconditional ceiling on a pickup bloom, before gating and A11y scaling, and
## before the rarity scale below.
##
## THE FIRST CAPTURE OF THIS EFFECT IS WHY THE NUMBER IS 1.8 AND NOT 3.4. At 3.4
## with a 6 m reach the burst is fired 1.5 m from the lens (you are stood over the
## thing you just picked up), and the pickup reel came back as two frames of white
## filling most of the screen. It was inside every safety cap — one envelope, no
## repeat, comfortably under 3 Hz — and it was still wrong, because pillar 2 says
## the dark is the enemy and a game whose whole look is one beam in a black room
## cannot afford a pickup that lights the room better than the beam does. The
## effect reads exactly as well at half the energy and a smaller radius, because
## what sells it is the RING (which says how far it reached) and the chime, not
## the luminance.
const PATCH_PICKUP_FLASH_ENERGY: float = 1.8
const PATCH_PICKUP_RING_RADIUS: float = 1.6
## A KERNEL pickup is allowed to be a bigger moment than a STABLE one — it is the
## rarest thing in the run — but only by this much, and from the lowered base.
const PATCH_PICKUP_KERNEL_SCALE: float = 1.45
const PATCH_PICKUP_SHAKE: float = 0.22
## Minimum seconds between two full-amplitude pickup blooms. Unreachable by hand
## (the channel alone is 0.5 s), and it is here so that a future channel cut
## fails in `--selftest` rather than in a living room. 0.36 s == 2.78 Hz.
const PATCH_PICKUP_FLASH_MIN_INTERVAL: float = 0.36

## The slate's own screen: a find-me beacon in a dark room that also risks
## drawing an eye. Deliberately feeble — under a data chip's pool and well under
## the cabinet's lock plate — because pillar 2 is not negotiable for a pickup.
const PATCH_SLATE_SCREEN_ENERGY: float = 0.34
const PATCH_SLATE_SCREEN_RANGE: float = 3.2
## The anomaly cache is allowed to be seen across a dark room. It is the rarest
## thing on the layer and the whole point of it is that you notice it.
const PATCH_CACHE_GLOW_ENERGY: float = 1.15
const PATCH_CACHE_GLOW_RANGE: float = 7.5


## Rarity tier of a patch id, or STABLE for anything unknown (a table read from
## an untrusted packet must never abort the read).
static func patch_tier(id: String) -> int:
	var entry: Dictionary = PATCHES.get(id, {}) as Dictionary
	return int(entry.get("tier", PATCH_TIER_STABLE))


static func patch_tier_name(tier: int) -> String:
	match tier:
		PATCH_TIER_KERNEL:
			return "KERNEL"
		PATCH_TIER_UNSTABLE:
			return "UNSTABLE"
		_:
			return "STABLE"
