class_name RoomAcoustics
extends RefCounted
## M12 SENSATION — the acoustic model. Pure, static, and deliberately not an
## autoload: everything here is arithmetic on a rectangle and a height, so the
## selftest can assert the whole model without standing up a mixer, a layer or a
## listener.
##
## ## Why this file exists
##
## A playtest returned "the sound needs some more reverb, it doesn't feel like
## there's any room". It was right, and it was right about something bigger than
## reverb: the game was mixing every space identically, so a 16-metre machinery
## hall and a 3-metre alcove sounded the same, and the player's ears were being
## told the architecture does not exist. Half of Alien: Isolation's dread is
## acoustic. This is the half NULLVOID was missing.
##
## ## The model is MEASURED FROM THE GENERATOR, never guessed
##
## `LayerGraph` already knows exactly how big every space is — `min`/`max` are
## the room's floor rectangle in metres and `h` is the height the builder really
## built, which M6.6's verticality pass raised to `storeys * KIT_STOREY` for the
## rooms that earned a second or third course of wall. Corridors carry the same
## three fields. So the acoustics do not need a table of per-archetype reverb
## presets that somebody has to keep in sync with the generator: they need the
## room's VOLUME and SURFACE AREA, which are two lines of arithmetic on numbers
## the graph already publishes, and one absorption coefficient per archetype for
## what the space is made of.
##
## That is Sabine's equation, 1900, and it is the correct amount of physics for
## this job:
##
##     RT60 = 0.161 * V / (alpha * S)
##
## V is the volume in m³, S the total interior surface in m², and `alpha` the
## mean absorption of that surface (0 = a mirror, 1 = an anechoic wedge). It is
## an approximation that assumes a diffuse field and stops being true for very
## absorbent or very long rooms — both of which we clamp for — and it buys the
## one thing a preset table cannot: when M10 makes the machinery halls bigger,
## the machinery halls get more cavernous by themselves.
##
## ## What the archetype actually decides
##
## Only what the space is MADE OF, never how big it is:
##
##   * a bus/machinery hall is bare structural slab and glass conduit — hard,
##     `alpha` 0.09, so its size turns straight into tail;
##   * the drop-shaft trunk is the hardest surface in the game and a chimney
##     besides, `alpha` 0.07;
##   * corridors are lined with cable trays, grating and duct — `alpha` 0.26,
##     which is why a corridor rings tight and fast rather than long;
##   * the backdoor sanctuary is dressed and the one room that is meant to feel
##     safe, `alpha` 0.24;
##   * an alcove is small, and its deadness falls out of the volume rather than
##     out of a special case.
##
## ## THE PLACE THE PHYSICS DOES NOT REACH, STATED HONESTLY
##
## This is the most important paragraph in the file and it is a limitation, not
## a feature.
##
## Godot's `AudioEffectReverb` is a Freeverb derivative, and under the settings
## the game actually runs it at, its usable decay range is **0.48 s to 1.56 s** —
## measured, not assumed, by `tools/sensation_bench/calibrate_reverb.gd`, which
## sweeps `room_size` and reads the decay back off an `AudioEffectCapture`. The
## table in `RT60_BY_SIZE` below IS that measurement.
##
## The physics above happily asks for 3.1 s in a machinery hall and 0.36 s in an
## alcove. The engine will deliver neither. So:
##
##   * a genuinely dead alcove cannot be sold by shortening the tail — the engine
##     will not go below ~0.48 s;
##   * a genuinely cavernous hall cannot be sold by lengthening it — everything
##     the model asks for above 1.56 s saturates at `room_size` 0.9, which means
##     the hall and the drop-shaft trunk get the SAME tail length.
##
## What carries the size difference instead is the other three parameters, and
## they have plenty of range: `wet` spans 16:1 across the archetypes (a hall at
## 0.44 against an alcove at 0.028), `predelay` spans 26 ms against 8 ms, and
## `spread` puts a hall around you while a corridor's slap-back stays in front.
## Level, first-reflection gap and width are in fact the stronger size cues in a
## real room; the tail is the one everybody names. So the model is honest about
## asking for physics and the mix is honest about what it can deliver, and the
## selftest asserts the ORDERING those three produce rather than a tail length
## the engine cannot give.
##
## The fix, if this ever stops being good enough, is a convolution reverb with
## real impulse responses per archetype. That is a bigger change than one
## milestone and it needs authored IRs; noted, deferred, not pretended away.

# ------------------------------------------------------------------- kinds --
#
# Named by what the space DOES to sound, not by what the generator calls it, so
# a new archetype only has to answer "which of these is it like".

const KIND_HALL: StringName = &"hall"           ## machinery / bus, and the vault.
const KIND_TRUNK: StringName = &"trunk"         ## the drop shaft: tall, vertical.
const KIND_ROOM: StringName = &"room"           ## arrival, siphon junction.
const KIND_SANCTUARY: StringName = &"sanctuary" ## backdoor node. Dressed, warm.
const KIND_CORRIDOR: StringName = &"corridor"   ## tight, fast slap-back.
const KIND_ALCOVE: StringName = &"alcove"       ## anything genuinely small.
const KIND_NONE: StringName = &"none"           ## menu, hub fallback: dry.

## Mean absorption coefficient per kind — the ONLY thing the archetype decides.
## Everything else in this file is measured off the rectangle.
const ALPHA: Dictionary = {
	KIND_HALL: 0.09,
	KIND_TRUNK: 0.07,
	KIND_ROOM: 0.14,
	KIND_SANCTUARY: 0.24,
	KIND_CORRIDOR: 0.26,
	KIND_ALCOVE: 0.30,
	KIND_NONE: 1.0,
}

## Below this volume a space is an alcove whatever the generator called it. A
## 3x3x3 cupboard off a machinery hall is not a machinery hall.
const ALCOVE_VOLUME: float = 90.0

## Sabine's constant in metric (0.161 s·m⁻¹). Named rather than inlined because
## it is the one number in this file that is physics and not taste.
const SABINE: float = 0.161

## Clamps on the RT60 the model is allowed to ask for. The low end is the
## engine's own floor (see the class doc); the high end is where a tail stops
## reading as a big room and starts reading as a broken effect — and it is also
## where Sabine's diffuse-field assumption has long since stopped being true for
## a 40 m corridor.
const RT60_MIN: float = 0.35
const RT60_MAX: float = 3.10
## What the ENGINE can actually deliver, as opposed to what the model asks for.
## Read only by the selftest and the bench, so a check can assert against the
## truth rather than against the aspiration. See the class doc.
const RT60_ENGINE_FLOOR: float = 0.48
const RT60_ENGINE_CEILING: float = 1.56

# ---------------------------------------------------- the engine calibration --
#
# MEASURED, on this engine build, by `tools/sensation_bench/calibrate_reverb.gd`:
# a one-sample impulse through an `AudioEffectReverb` with dry=0 wet=1, read back
# off an `AudioEffectCapture`, RT60 extrapolated from T20 per ISO 3382.
#
# MEASURED UNDER THE SHIPPING MIX'S OWN SETTINGS, which matters more than it
# sounds. A first pass of this calibration ran at damping 0 and hipass 0 and
# produced a curve topping out at 3.25 s — and the shipped mixer then delivered
# 1.2 s for the same room, because the real World bus runs the effect at the
# damping a hard space asks for. A calibration measured under conditions the game
# does not use is not a calibration, it is a coincidence. This table is taken at
# `HIPASS_WORLD` and the hall's own damping, so it describes the mix that ships.
#
# Godot 4.7.1, hipass 0.000, damping 0.347:
#   0.10 -> 0.48 s   0.40 -> 0.66   0.70 -> 0.93
#   0.20 -> 0.48     0.50 -> 0.72   0.80 -> 1.14
#   0.30 -> 0.66     0.60 -> 0.75   0.90 -> 1.56
#
# The first two entries measure identically: the effect has a floor and 0.1 and
# 0.2 are both under it. `size_for_rt60` handles the flat step rather than
# dividing by zero across it. (`room_size` 1.00 measured NON-MONOTONIC in the
# first sweep and is never used — `SIZE_MAX` stops at 0.90.)
#
# Kept as a literal array because a `const` may only hold constant expressions
# (CLAUDE.md) and because the inverse lookup below wants it indexed, not hashed.
const RT60_BY_SIZE: Array[float] = [
	0.48, 0.48, 0.66, 0.66, 0.72, 0.75, 0.93, 1.14, 1.56,
]
const SIZE_MIN: float = 0.10
const SIZE_MAX: float = 0.90
const SIZE_STEP: float = 0.10

# ------------------------------------------------------------- wet / character --
#
# How much reflected energy reaches the ear. This is the parameter that actually
# carries "big" versus "dead" — see the class doc for why it cannot be the tail.
const WET_MIN: float = 0.05
const WET_MAX: float = 0.44
## RT60 range the wet level is mapped across.
const WET_RT_LOW: float = 0.45
const WET_RT_HIGH: float = 2.60

## Per-kind multiplier on the mapped wet level. A corridor is small but LIVE —
## a slap-back is loud, it is just short — so it gets more wet than its volume
## alone would earn; a sanctuary is deliberately damped below its own size,
## because the one room in the game with no antivirus in it should sound like
## somewhere you can hear yourself think.
const WET_CHARACTER: Dictionary = {
	KIND_HALL: 1.0,
	KIND_TRUNK: 1.08,
	KIND_ROOM: 0.94,
	KIND_SANCTUARY: 0.62,
	KIND_CORRIDOR: 1.20,
	KIND_ALCOVE: 0.55,
	KIND_NONE: 0.0,
}

## Damping is a HIGH-FREQUENCY control: how fast the top of the tail dies. It
## tracks absorption directly, which is what makes a cable-lined corridor sound
## duller than a bare slab hall without either of them needing a preset.
const DAMP_BASE: float = 0.14
const DAMP_PER_ALPHA: float = 2.30
const DAMP_MAX: float = 0.88

## Predelay is the gap before the first reflection, and it is the single
## strongest cue for SIZE — bigger room, longer gap. Derived from the mean free
## path (4V/S, the standard estimate of how far sound travels between bounces)
## over the speed of sound.
const SPEED_OF_SOUND: float = 343.0
const PREDELAY_MIN: float = 6.0
const PREDELAY_MAX: float = 92.0

## Stereo width of the tail. A trunk and a hall wrap around you; a corridor's
## slap-back comes back down the corridor, which is much closer to mono.
const SPREAD_BY_KIND: Dictionary = {
	KIND_HALL: 1.0,
	KIND_TRUNK: 1.0,
	KIND_ROOM: 0.85,
	KIND_SANCTUARY: 0.80,
	KIND_CORRIDOR: 0.45,
	KIND_ALCOVE: 0.40,
	KIND_NONE: 0.0,
}

## The reverb's own high-pass, and it is DIFFERENT PER BUS for a measured reason.
##
## `hipass` removes the low band from the tail — and the low band is the part
## that decays slowest, so it is by a wide margin the most expensive parameter in
## this file. Measured on the shipping mixer: at `room_size` 0.9 a hall delivered
## 1.56 s at `hipass` 0.0 and only 1.08 s at 0.12. That is a third of the
## cavernousness the model asked for, spent on a filter.
##
## World does not need it. The World bus is ALREADY high-passed at 35 Hz ahead of
## the reverb (see `_build_buses`), so the reverb is never handed sub energy to
## put back in the first place — a second high-pass there costs tail and protects
## nothing.
##
## Creatures does need it, and this is the low-end headroom point the hunter pass
## depends on. That bus deliberately has NO high-pass, because 20–60 Hz is
## reserved for the Sentinel's and the Hound's presence weight. A reverb tail
## with full low content on that bus would smear exactly the band the player is
## supposed to feel their warning in, so the tail there is high-passed even
## though the direct sound is not.
const HIPASS_WORLD: float = 0.0
const HIPASS_CREATURES: float = 0.10

## LOW-END HEADROOM FOR THE HUNTERS.
##
## The Creatures bus is the one bus in the game with no high-pass on it, because
## the 20–60 Hz band is deliberately reserved for the Sentinel's and the Hound's
## presence weight — that sub energy IS the player's warning, and M11's hunter
## pass leans on it harder. Reverb is the classic way to lose that: a wet tail
## fills the gaps between transients, and the first thing it buries is the thing
## you were supposed to feel rather than hear.
##
## So the Creatures bus takes the same room, slightly drier than the world does.
## The tail length, the predelay and the damping are identical — the space is the
## same space, and a creature that sounded like it was in a different room from
## the gunfire would be worse than no reverb at all — but the reflected LEVEL is
## scaled here so the direct sound, and the sub under it, keeps its headroom.
##
## Stated as a limitation rather than a feature: the honest fix is a separate
## send with its own high-pass, and Godot's single-parent bus routing does not
## give us one without splitting Creatures in two.
const CREATURE_WET_SCALE: float = 0.82


# ------------------------------------------------------------------ geometry --

## Measure the space that contains `point`, from the graph the layer was really
## built from. Returns a plain Dictionary (never null) so every caller has the
## same shape to read:
##
##   {kind, w, d, h, volume, surface, rt60, room_index}
##
## `room_index` is -1 for a corridor or for "off the map", which the caller uses
## only for the CHANGE detection that decides when to re-measure.
static func measure(graph: LayerGraph, point: Vector3) -> Dictionary:
	if graph == null:
		return _space(KIND_NONE, 0.0, 0.0, 0.0, -1)

	# A room, if the point is inside four walls. `room_at` is the graph's own
	# lookup and it is exact — the same rectangle the builder built.
	var index: int = graph.room_at(point)
	if index >= 0 and index < graph.rooms.size():
		var room: Dictionary = graph.rooms[index]
		var lo: Vector2 = room["min"]
		var hi: Vector2 = room["max"]
		return _space(_kind_of(String(room["archetype"])),
				absf(hi.x - lo.x), absf(hi.y - lo.y), float(room["h"]), index)

	# Otherwise a corridor, which has exactly the same three fields. Corridors
	# are the tight spaces and they are most of the walking, so getting them
	# wrong would be getting most of the game wrong.
	for corridor: Dictionary in graph.corridors:
		var lo: Vector2 = corridor["min"]
		var hi: Vector2 = corridor["max"]
		if point.x < lo.x - 0.5 or point.x > hi.x + 0.5:
			continue
		if point.z < lo.y - 0.5 or point.z > hi.y + 0.5:
			continue
		return _space(KIND_CORRIDOR, absf(hi.x - lo.x), absf(hi.y - lo.y),
				float(corridor["h"]), -1)

	# Off the map entirely — mid-fall down a shaft, a teleport gone wrong. Fall
	# back to the nearest room rather than to silence: an acoustic that snaps to
	# dry the moment you leave the floor is worse than one that is slightly wrong.
	if graph.rooms.is_empty():
		return _space(KIND_NONE, 0.0, 0.0, 0.0, -1)
	var best: int = graph.region_of(point)
	best = clampi(best, 0, graph.rooms.size() - 1)
	var near: Dictionary = graph.rooms[best]
	var nlo: Vector2 = near["min"]
	var nhi: Vector2 = near["max"]
	return _space(_kind_of(String(near["archetype"])),
			absf(nhi.x - nlo.x), absf(nhi.y - nlo.y), float(near["h"]), best)


## Build the measured record for a box of `w` x `d` x `h`, promoting anything
## genuinely small to ALCOVE whatever the generator called it.
static func _space(kind: StringName, w: float, d: float, h: float,
		index: int) -> Dictionary:
	var volume: float = maxf(w * d * h, 0.0)
	var surface: float = maxf(2.0 * w * d + 2.0 * h * (w + d), 0.0)
	if kind != KIND_NONE and volume > 0.0 and volume < ALCOVE_VOLUME:
		kind = KIND_ALCOVE
	return {
		"kind": kind, "w": w, "d": d, "h": h,
		"volume": volume, "surface": surface,
		"rt60": rt60(volume, surface, float(ALPHA.get(kind, 0.2))),
		"room_index": index,
	}


## LayerGraph archetype -> acoustic kind. The vault joins the halls: it is a
## hard, tall, mostly empty box, and it is where the crew's greediest fights
## happen, so it wants the same size in the ear.
static func _kind_of(archetype: String) -> StringName:
	match archetype:
		LayerGraph.BUS: return KIND_HALL
		LayerGraph.VAULT: return KIND_HALL
		LayerGraph.SHAFT: return KIND_TRUNK
		LayerGraph.BACKDOOR: return KIND_SANCTUARY
		LayerGraph.ARRIVAL: return KIND_ROOM
		LayerGraph.SIPHON: return KIND_ROOM
		_: return KIND_ROOM


## Sabine. Clamped at both ends — see RT60_MIN / RT60_MAX for why each.
static func rt60(volume: float, surface: float, alpha: float) -> float:
	if volume <= 0.0 or surface <= 0.0 or alpha <= 0.0:
		return 0.0
	return clampf(SABINE * volume / (alpha * surface), RT60_MIN, RT60_MAX)


## Mean free path, 4V/S: how far sound gets between bounces. The predelay cue.
static func mean_free_path(volume: float, surface: float) -> float:
	if surface <= 0.0:
		return 0.0
	return 4.0 * volume / surface


# ------------------------------------------------------------------ the mix --

## The measured space -> the six numbers `AudioEffectReverb` actually takes.
## Pure, so the selftest asserts the ordering of the archetypes directly on this
## rather than on a running mixer.
##
##   {room_size, damping, wet, predelay, spread, hipass, rt60}
static func reverb_params(space: Dictionary) -> Dictionary:
	var kind: StringName = StringName(space.get("kind", KIND_NONE))
	if kind == KIND_NONE:
		return {
			"room_size": SIZE_MIN, "damping": DAMP_MAX, "wet": 0.0,
			"predelay": PREDELAY_MIN, "spread": 0.0, "rt60": 0.0,
		}
	var decay: float = float(space.get("rt60", RT60_MIN))
	var alpha: float = float(ALPHA.get(kind, 0.2))
	var volume: float = float(space.get("volume", 0.0))
	var surface: float = float(space.get("surface", 0.0))

	var wet: float = lerpf(WET_MIN, WET_MAX,
			clampf(inverse_lerp(WET_RT_LOW, WET_RT_HIGH, decay), 0.0, 1.0))
	wet = clampf(wet * float(WET_CHARACTER.get(kind, 1.0)), 0.0, WET_MAX)

	var predelay: float = clampf(
			mean_free_path(volume, surface) / SPEED_OF_SOUND * 1000.0,
			PREDELAY_MIN, PREDELAY_MAX)

	var delivered: float = deliverable_rt60(decay)
	return {
		"room_size": size_for_rt60(delivered),
		"rt60_delivered": delivered,
		"damping": clampf(DAMP_BASE + alpha * DAMP_PER_ALPHA, DAMP_BASE, DAMP_MAX),
		"wet": wet,
		"predelay": predelay,
		"spread": float(SPREAD_BY_KIND.get(kind, 0.8)),
		"rt60": decay,
	}


## Compress a PHYSICAL decay time onto the range the engine can actually deliver.
##
## The model asks for 0.35 s to 3.10 s; the effect delivers 0.48 s to 1.56 s (see
## the class doc). Clamping was the first thing tried and it is wrong: everything
## the physics puts above 1.56 s saturates at the same dial position, so the
## machinery hall, the drop-shaft trunk and an ordinary siphon room — 3.10, 3.10
## and 2.44 seconds of real decay — all came out at exactly the same tail. Three
## quite different spaces, one sound.
##
## Compressing instead preserves the ORDERING across the whole range, which is
## the property that actually matters: a player never hears an absolute decay
## time, they hear that this room rings longer than the last one. The compression
## is done in the LOG domain because decay time is perceived logarithmically —
## the step from 0.5 s to 1.0 s is about as big an event as 1.0 s to 2.0 s, and a
## linear squeeze would spend almost all of the engine's range on the top half of
## the model's.
static func deliverable_rt60(physical: float) -> float:
	if physical <= 0.0:
		return 0.0
	var lo: float = log(RT60_MIN)
	var hi: float = log(RT60_MAX)
	var t: float = clampf((log(clampf(physical, RT60_MIN, RT60_MAX)) - lo) / (hi - lo),
			0.0, 1.0)
	return RT60_ENGINE_FLOOR * pow(RT60_ENGINE_CEILING / RT60_ENGINE_FLOOR, t)


## Invert the measured calibration: what `room_size` produces this RT60 on this
## engine. Piecewise-linear over `RT60_BY_SIZE`, which is monotone across the
## range we use — so the inverse is well defined and needs no solver.
static func size_for_rt60(target: float) -> float:
	if RT60_BY_SIZE.is_empty():
		return SIZE_MIN
	if target <= RT60_BY_SIZE[0]:
		return SIZE_MIN
	for i: int in range(1, RT60_BY_SIZE.size()):
		var lo: float = RT60_BY_SIZE[i - 1]
		var hi: float = RT60_BY_SIZE[i]
		if target <= hi:
			var t: float = 0.0 if is_equal_approx(hi, lo) \
					else clampf((target - lo) / (hi - lo), 0.0, 1.0)
			return SIZE_MIN + (float(i - 1) + t) * SIZE_STEP
	return SIZE_MAX


## Forward direction of the same calibration, for the selftest and the bench:
## what RT60 this engine gives for a `room_size`.
static func rt60_for_size(size: float) -> float:
	if RT60_BY_SIZE.is_empty():
		return 0.0
	var pos: float = clampf((size - SIZE_MIN) / SIZE_STEP, 0.0,
			float(RT60_BY_SIZE.size() - 1))
	var i: int = int(floorf(pos))
	if i >= RT60_BY_SIZE.size() - 1:
		return RT60_BY_SIZE[RT60_BY_SIZE.size() - 1]
	return lerpf(RT60_BY_SIZE[i], RT60_BY_SIZE[i + 1], pos - float(i))


# ------------------------------------------------------------------ occlusion --
#
# The other half of "sounds placed in a world": a Scrubber screeching through a
# wall must sound muffled, not merely quieter, because a low-passed sound is how
# an ear knows there is something SOLID between it and the thing. The raycast
# lives in AudioService (it needs a live space state); the numbers live here with
# the rest of the acoustic model.

## How much an occluded source loses, in dB, at full occlusion. Deep enough to
## matter, shallow enough that a threat behind a wall is still a threat you can
## hear — the safety half of this is that the caption fires regardless.
const OCCLUSION_DB: float = -8.5

## Corner frequency of the occluded path.
##
## THIS NUMBER IS A GAMEPLAY NUMBER, not a taste one, and it was raised from an
## earlier 780 Hz for a stated reason. M11's hunters are getting distinct audio
## signatures, and the design intent is that a player can tell WHICH of them is
## behind a bulkhead from the muffled sound alone. A low-pass steep and low
## enough to be maximally convincing as a wall is also a low-pass that throws
## away the formant band every one of those signatures lives in — at 780 Hz a
## Hound and a Sentinel converge on the same distant thud, and the player loses
## the single most valuable piece of information the occlusion system could have
## given them.
##
## 1400 Hz keeps the first two or three harmonics of every creature bed intact
## (their identity lives at 200 Hz – 1.2 kHz), while still removing all the
## sibilance, click and air that make a sound read as being IN THE ROOM WITH
## YOU. The one-pole slope Godot's low-pass gives is deliberately gentle for the
## same reason. `--sensation-occlusion` measures the resulting per-creature
## spectral separation rather than asserting it.
const OCCLUSION_HZ: float = 1400.0
## Resonance of that low-pass. Flat: a resonant occlusion filter whistles, and a
## whistle is a spectral feature that would be the SAME for every creature —
## exactly the identity collapse the corner frequency above is chosen to avoid.
const OCCLUSION_RESONANCE: float = 0.5
## Hysteresis band on the bus switch for tracked loops, so a creature pacing an
## open doorway does not chatter between the two paths.
const OCCLUSION_ON: float = 0.62
const OCCLUSION_OFF: float = 0.38
## How fast a tracked loop's occlusion reading is allowed to move, per second.
## ~0.25 s to cross, which is fast enough to follow a creature through a doorway
## and slow enough that a passing crewmate does not flutter it.
const OCCLUSION_SLEW: float = 4.0

# --------------------------------------------------------- distance absorption --
#
# Air absorbs high frequencies over distance — a real, measurable thing (roughly
# 1 dB per 100 m at 2 kHz, far more at 8 kHz) and one of the strongest cues for
# FAR. Godot implements exactly this shape per-source:
# `attenuation_filter_cutoff_hz` is a low-pass whose depth scales with the
# distance attenuation already applied, up to `attenuation_filter_db`. The engine
# defaults (5000 Hz / -24 dB) are on for every AudioStreamPlayer3D in the game
# already; what M12 does is stop leaving them at the default and set them per
# family, because a 90 m Sentinel drone and a 14 m switch clunk want very
# different amounts of "far".

## Default corner for a world/prop sound: close things stay bright, far things
## lose their top.
const AIR_HZ_NEAR: float = 4200.0
## The corner used by the long-attenuation families (DREAD/LOUD curves) — the
## sounds that are MEANT to be heard from three rooms away, and which sell that
## distance by being dull rather than merely quiet.
const AIR_HZ_FAR: float = 2600.0
## How deep the distance filter is allowed to go. Godot's own default is -24 dB,
## which is close to right; -30 buys a little more "across the hall" without
## making a far sound unintelligible (and captions never depend on it).
const AIR_DB: float = -30.0
