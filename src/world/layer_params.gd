class_name LayerParams
extends RefCounted
## The threat curve, as data: layer number -> generation and scaling knobs.
##
## DESIGN.md "Layer N scaling": antivirus count up, speed/HP up, ambient light
## down, data value up. M2 only consumes the size and lighting fields; the
## creature and economy fields are defined now so M3 has a single place to read
## them from and the curve can be tuned as one shape rather than six.
##
## Everything is a pure function of `layer_number` — no RNG. Two peers on the
## same layer always agree on the parameters before they even touch the seed.

## Layer at which the light/size curves bottom out. Past this the system is as
## dark and as dense as it gets, and the difficulty comes from what lives in it.
const DEPTH_FLOOR: int = 14


## All scaling knobs for a layer, as a plain dictionary so it survives being
## printed in a determinism dump.
static func of(layer_number: int) -> Dictionary:
	var n: int = maxi(layer_number, 1)
	# 0 at layer 1, 1.0 at DEPTH_FLOOR and beyond.
	var depth: float = clampf(float(n - 1) / float(DEPTH_FLOOR - 1), 0.0, 1.0)

	# M4.9 (balance lab): shard value grows linearly to the depth floor, then
	# LOGARITHMICALLY past it. The old `1 + (n-1)*0.35` was linear and unbounded,
	# so deep hauls ran away (a layer-40 chip was worth 14x a surface one and still
	# climbing), which made "one more ring" strictly dominant past ~20 rather than
	# a gamble. The two branches are equal at n=DEPTH_FLOOR (both 1 + 13*0.35 =
	# 5.55), so the curve is continuous and IDENTICAL at and below layer 14; only
	# the deep-layer tail is tamed. Still a pure function of n, no clamp on depth —
	# this is the one economy knob that must keep rising, just slower.
	var data_mult: float
	if n <= DEPTH_FLOOR:
		data_mult = 1.0 + float(n - 1) * 0.35
	else:
		data_mult = 1.0 + 13.0 * 0.35 * (1.0 + log(1.0 + float(maxi(n - DEPTH_FLOOR, 0)) / 8.0))

	return {
		"layer": n,
		"depth": depth,

		# --- generation ---------------------------------------------------
		# 6 rooms on the surface, 10 by the depth floor (DESIGN.md: 6-10).
		"room_count": 6 + int(round(depth * 4.0)),
		# The surface still has some working infrastructure; deeper rings do not.
		"siphon_count": 2 if n <= 6 else 1,
		# Fraction of corridors that get any light fixture at all. Most of a
		# layer must be genuinely dark, so this starts low and goes lower.
		"corridor_light_chance": lerpf(0.42, 0.14, depth),
		# Fixtures per room, before the chance roll.
		"room_light_count": maxi(int(round(lerpf(3.0, 1.0, depth))), 1),
		# Multiplies every fixture's energy.
		"light_scale": lerpf(1.0, 0.42, depth),
		# Scales the WorldEnvironment ambient — the floor below which nothing is
		# visible without a beam.
		"ambient_scale": lerpf(1.0, 0.35, depth),
		# Circuit traces are navigation as much as decoration; deeper rings have
		# decayed and run fewer of them.
		"trace_density": lerpf(1.0, 0.55, depth),
		# Ceiling heights compress as the architecture gets older and heavier.
		"height_range": Vector2(lerpf(4.2, 3.4, depth), lerpf(7.0, 5.0, depth)),

		# --- M3 hooks (defined, not yet consumed) -------------------------
		# M4.9 (balance lab): base 2 -> 4. The director reserves a Scrubber floor
		# out of this now (see AntivirusDirector._purchase), so the surface layers
		# need a couple more points of budget to still field the Sentinel they used
		# to plus the reserved pack; +2 base keeps layers 1-6 feeling identical.
		"antivirus_budget": 4 + int(round(depth * 10.0)),
		"scrubber_speed": lerpf(1.0, 1.55, depth),
		"sentinel_count": 0 if n < 3 else 1 + int(depth * 2.0),
		"data_multiplier": data_mult,
		# What the Compiler on this layer will sell you (M4). Four layers per
		# tier, so tier 5 is stocked from layer 17 down — or from the layer-15
		# sanctuary, which stocks one above its layer. Deliberately NOT tied to
		# `depth`, which bottoms out at DEPTH_FLOOR: the light and the room count
		# stop getting worse at 14, and the top module tier has to stay somewhere
		# past the point where everything else has already flattened.
		"compiler_tier": clampi(1 + (n - 1) / 4, 1, Balance.MODULE_MAX_TIER),
		# Every 5th layer ends in a hand-authored backdoor node room (M3).
		"has_backdoor": n % 5 == 0,
	}


## One-line summary for determinism dumps and the boot log.
static func describe(layer_number: int) -> String:
	var p: Dictionary = of(layer_number)
	return "layer %d: rooms=%d siphons=%d light=%.2f ambient=%.2f traces=%.2f" % [
		int(p["layer"]), int(p["room_count"]), int(p["siphon_count"]),
		float(p["light_scale"]), float(p["ambient_scale"]), float(p["trace_density"])]
