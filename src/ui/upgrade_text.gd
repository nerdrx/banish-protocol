class_name UpgradeText
## The one place the game says what an upgrade DOES.
##
## Three progression systems shipped with names, glyphs and a rarity bracket and
## no statement of effect anywhere in the interface. A player could hold six
## stacks of HOT LOOP and read the word HOT LOOP. This file is the answer, and it
## serves every surface that asks: the TAB patch list, the pickup line, the
## Compiler's detail block and the Codex.
##
## ## The law this file is written under
##
## **No number is ever typed twice.** Every figure that reaches a player is
## computed here from the constants and the pure functions the SIMULATION runs
## on — `Patches.hot_loop_bonus_for`, `Modules.value_at`, `Balance.PATCH_*` — so
## a description cannot drift from the maths. A balance pass that retunes
## `PATCH_HOTLOOP_STEP` retunes this text in the same commit, without anybody
## remembering to. That is not a nicety: the previous generation of this text was
## a `note` field saying "CONSECUTIVE HITS ON ONE PROCESS RAMP", which is
## unfalsifiable and therefore never wrong and never useful.
##
## What IS authored by hand is the PROSE — the mechanism sentence in the codex
## bodies below. It states how a thing works, never what it is worth; the worth is
## always interpolated. `--selftest` asserts every catalogue entry has one, as
## data, so a sixteenth patch cannot ship undocumented.
##
## ## Voice
##
## MOTHER's systems documentation, not a shop. Names, units and states are
## UPPERCASE because they are identifiers on an instrument; the mechanism clause
## is sentence case, which is the same split `SettingsPanel._gloss` already uses
## and the reason its explanatory text is the most readable copy in the game.
## Every line states a MECHANISM. Where a patch bargains with a system — OVERFLOW
## buying radius and paying nothing off the noise — the clause says so, because
## that IS the design.
##
## Strip clauses are kept under `CLAUSE_MAX` characters and the self-test holds
## them there; the codex bodies may run two sentences.

## The longest an effect clause may be before the strip cannot lay it out.
## Asserted rather than trusted — a clause that overflows is a clause the player
## reads two thirds of.
const CLAUSE_MAX: int = 90
## And the ceiling clause, which lives in a fixed right-hand column on the strip.
## The first capture found this the hard way: "never past 40% of the blow" is
## wider than any lane a 620-pixel list can spare, so it was drawn over the top of
## the mechanism it was qualifying. Short by rule now, and asserted.
const CEILING_MAX: int = 24

## Float slop for "this stat has hit its ceiling". Everything compared here is a
## small multiplier or a fraction, so an absolute epsilon is the right shape.
const EPS: float = 0.0005


# ------------------------------------------------------------------- patches --
#
# The codex bodies. Mechanism only: how the thing works, never how much it is
# worth, because the worth is interpolated at the point of use and this text
# would be the copy of it that goes stale.

const PATCH_BODY: Dictionary = {
	"hot_loop": "Each cut that lands on the process you last cut raises the next one by a fixed step. Switching target, or letting the window lapse, drops the ramp to nothing.",
	"garbage_collect": "A deleted process returns part of itself to the pool, more of it from a heavy one. The refund is tallied per layer against a fraction of the crew's own ceiling, so a nest never pays like a siphon tap.",
	"parity_bit": "Error correction runs on every hostile write and takes a flat bite out of it. It never takes more than a fixed share of the blow, so it thins damage rather than nullifying it.",
	"priority_boost": "Raises the scheduler's priority for your process, which reads as move speed. Sharply diminishing, and bounded so a patched walk still bills as a walk.",
	"zero_page": "A landing writes to a page nothing else is listening on. The noise a drop makes stops carrying next door; it never stops happening, and the fall still hurts.",
	"instruction_fusion": "Fuses the cutter's instructions so one shot books less heat. Floored, so the cutter always heats and the lockout is always reachable.",
	"speculative_execution": "The cutter speculates while it is idle and commits the result into the next shot. Firing resets the idle, so the crit is bought with the shots you did not take.",
	"bit_rot": "A landed cut leaves a share of itself behind as decay, eaten out of the process over the seconds after. Refreshed by a later cut, never stacked into a second timer.",
	"overflow": "The pulse writes past the end of its own buffer: wider, and holding a staggered process longer. The noise is untouched — the panic button still rings the bell.",
	"race_condition": "The scheduler bills your sprint a moment late. Continuous sprinting spends the window, and only time spent under sprint speed re-arms it.",
	"nop_sled": "Pads the migration with instructions that do nothing, which lengthens the window in which nothing can write to you. The step itself is no longer, only safer.",
	"dead_code": "The fork is compiled out of code nothing calls, so it persists longer and takes more before it decompiles. It still walks at the speed a decoy has to walk at.",
	"tail_call": "The cut does not return. It hands what is left of itself to the nearest process it has not already visited, and again from there. Every link goes through the same door an aimed cut does, so nothing is immune and nothing dies for free.",
	"watchdog": "A watchdog timer fires when a write would leave your integrity critical, and compiles a free integrity shell around you. The blow that tripped it lands for nothing; the charges are per layer.",
	"sleep_state": "With the beam off your process parks most of its clock. The drain returns to full the instant the light comes on, and the patch gives you no light to pay for it with.",
}


## Everything one carried patch is doing right now, at `stacks`.
##
## Returns `{effect, ceiling, capped}`:
##   effect   the mechanism clause with this stack count's live numbers in it.
##   ceiling  the bound in force, or "" when the stat has none.
##   capped   this stat cannot be raised further by another stack.
##
## One function rather than three, because two of the three answers fall out of
## the same arithmetic and computing them separately is how they drift apart.
static func patch_measure(id: String, stacks: int) -> Dictionary:
	var count: int = clampi(stacks, 0, Balance.PATCH_MAX_STACKS)
	match id:
		"hot_loop":
			# The full ramp — what the patch is worth once you have stayed on one
			# target, which is the number the player is deciding with. A huge run
			# length asks the function for its own maximum rather than restating it.
			var ramp: float = Patches.hot_loop_bonus_for(count, 99999) - 1.0
			return _made(
					"consecutive cuts on one process ramp to +%d%% within %.1f s" % [
						roundi(ramp * 100.0), Balance.PATCH_HOTLOOP_WINDOW],
					"ceiling +%d%%" % roundi(Balance.PATCH_HOTLOOP_MAX * 100.0),
					ramp >= Balance.PATCH_HOTLOOP_MAX - EPS)
		"garbage_collect":
			var per: float = Balance.PATCH_GC_PER_STACK * float(count)
			return _made(
					"each deletion refunds %.1f cycles, %.1f from a heavy process" % [
						per, per * Balance.PATCH_GC_HEAVY_MULT],
					"cap %.0f a layer" % (Modules.crew_pool_max()
							* Balance.PATCH_GC_LAYER_CAP_FRACTION),
					false)
		"parity_bit":
			return _made(
					"error correction shaves %.1f integrity off every hostile write" % [
						Balance.PATCH_PARITY_PER_STACK * float(count)],
					"max %d%% of a blow" % roundi(
							Balance.PATCH_PARITY_MAX_FRACTION * 100.0),
					false)
		"priority_boost":
			var gain: float = Patches.move_multiplier_for(count) - 1.0
			return _made(
					"move speed +%.1f%%, sharply diminishing per stack" % (gain * 100.0),
					"ceiling +%d%%" % roundi(Balance.PATCH_PRIORITY_CEILING * 100.0),
					gain >= Balance.PATCH_PRIORITY_CEILING - EPS)
		"zero_page":
			# The only noise reduction in the catalogue, and it has exactly one
			# caller: a LOUD landing, which is worth one room bare.
			var rooms: int = Patches.land_rooms_for(count, 1)
			var effect: String = "a hard landing is heard in this room only, never through the wall"
			if rooms > 0:
				effect = "a hard landing carries %d rooms instead of 1" % rooms
			return _made(effect, "floor: this room only", rooms <= 0)
		"instruction_fusion":
			var heat: float = Patches.heat_scale_for(count)
			return _made(
					"the cutter books x%.2f heat a shot" % heat,
					"floor x%.2f" % Balance.PATCH_FUSION_FLOOR,
					heat <= Balance.PATCH_FUSION_FLOOR + EPS)
		"speculative_execution":
			var crit: float = Patches.spec_bonus_for(count)
			return _made(
					"the first cut after %.1f s idle lands at x%.2f" % [
						Patches.spec_idle_for(count), crit],
					"ceiling x%.2f" % (1.0 + Balance.PATCH_SPEC_MAX),
					crit >= 1.0 + Balance.PATCH_SPEC_MAX - EPS)
		"bit_rot":
			var share: float = Patches.rot_fraction_for(count)
			return _made(
					"each cut seeds decay worth %d%% of it, eaten over %.0f s" % [
						roundi(share * 100.0), Balance.PATCH_ROT_SECONDS],
					"ceiling %d%%" % roundi(Balance.PATCH_ROT_MAX_FRACTION * 100.0),
					share >= Balance.PATCH_ROT_MAX_FRACTION - EPS)
		"overflow":
			# The bargain, stated. A patch that made the panic button quieter would
			# delete the ability's whole price, so the clause says it does not.
			var radius: float = Patches.pulse_radius_for(count)
			var hold: float = Patches.pulse_stagger_for(count)
			return _made(
					"stack pulse radius x%.2f, hold +%.2f s, and the pulse stays as loud" % [
						radius, hold],
					"ceiling x%.2f / +%.2f s" % [
						1.0 + Balance.PATCH_OVERFLOW_RADIUS_MAX,
						Balance.PATCH_OVERFLOW_STAGGER_MAX],
					radius >= 1.0 + Balance.PATCH_OVERFLOW_RADIUS_MAX - EPS
							and hold >= Balance.PATCH_OVERFLOW_STAGGER_MAX - EPS)
		"race_condition":
			var window: float = minf(Balance.PATCH_RACE_SECONDS
					+ Balance.PATCH_RACE_PER_STACK * float(maxi(count, 1) - 1),
					Balance.PATCH_RACE_MAX)
			return _made(
					"the first %.1f s of a sprint bill as a walk, re-arming after %.0f s slower" % [
						window, Balance.PATCH_RACE_REARM],
					"ceiling %.1f s" % Balance.PATCH_RACE_MAX,
					window >= Balance.PATCH_RACE_MAX - EPS)
		"nop_sled":
			var extra: float = Patches.iframe_bonus_for(count)
			return _made(
					"surge step holds its immunity %.2f s longer" % extra,
					"ceiling %.2f s" % Balance.PATCH_NOPSLED_MAX,
					extra >= Balance.PATCH_NOPSLED_MAX - EPS)
		"dead_code":
			var life: float = Patches.decoy_lifetime_for(count)
			var hits: int = Patches.decoy_hits_for(count)
			return _made(
					"fork decoys last x%.2f as long and soak %d more strikes" % [life, hits],
					"ceiling x%.2f / +%d" % [
						1.0 + Balance.PATCH_DEADCODE_LIFE_MAX,
						Balance.PATCH_DEADCODE_HITS_MAX],
					life >= 1.0 + Balance.PATCH_DEADCODE_LIFE_MAX - EPS
							and hits >= Balance.PATCH_DEADCODE_HITS_MAX)
		"tail_call":
			var links: int = mini(Balance.PATCH_TAILCALL_LINKS
					+ Balance.PATCH_TAILCALL_LINKS_PER_STACK * (maxi(count, 1) - 1),
					Balance.PATCH_TAILCALL_LINKS_MAX)
			return _made(
					"the cut chains to %d more within %.1f m at %d%%, decaying per link" % [
						links, Balance.PATCH_TAILCALL_RANGE,
						roundi(Balance.PATCH_TAILCALL_FALLOFF * 100.0)],
					"ceiling %d links" % Balance.PATCH_TAILCALL_LINKS_MAX,
					links >= Balance.PATCH_TAILCALL_LINKS_MAX)
		"watchdog":
			var charges: int = mini(
					Balance.PATCH_WATCHDOG_CHARGES_PER_STACK * count,
					Balance.PATCH_WATCHDOG_CHARGES_MAX)
			return _made(
					"%d free shells a layer when a hit would drop you under %d%%" % [
						charges, roundi(Balance.PATCH_WATCHDOG_TRIGGER_FRACTION * 100.0)],
					"ceiling %d, absorbs %.0f" % [
						Balance.PATCH_WATCHDOG_CHARGES_MAX,
						Balance.PATCH_WATCHDOG_SHELL_ABSORB],
					charges >= Balance.PATCH_WATCHDOG_CHARGES_MAX)
		"sleep_state":
			var drain: float = Patches.sleep_scale_for(count)
			return _made(
					"passive drain x%.2f with the beam off, unchanged the moment it is on" % drain,
					"floor x%.2f" % Balance.PATCH_SLEEP_FLOOR,
					drain <= Balance.PATCH_SLEEP_FLOOR + EPS)
	return _made("", "", false)


static func _made(effect: String, ceiling: String, capped: bool) -> Dictionary:
	return {"effect": effect, "ceiling": ceiling, "capped": capped}


## The strip's whole right-hand read on one line, for logs, the pickup line and
## anywhere too narrow for two columns.
static func patch_line(id: String, stacks: int) -> String:
	var measured: Dictionary = patch_measure(id, stacks)
	var effect: String = String(measured["effect"])
	if bool(measured["capped"]):
		return "%s  ·  CAPPED" % effect
	var ceiling: String = String(measured["ceiling"])
	return effect if ceiling.is_empty() else "%s  ·  %s" % [effect, ceiling]


static func patch_body(id: String) -> String:
	return String(PATCH_BODY.get(id, ""))


# ------------------------------------------------------------------- modules --

const MODULE_BODY: Dictionary = {
	"runtime": "Raises your share of the crew's Cycles pool and slows the passive drain every running program pays. It is the leash the whole run is timed against.",
	"threading": "Cuts the surcharge a sprint bills against the shared pool. Sprinting never becomes free; it becomes affordable.",
	"checksum": "Raises maximum integrity. Nothing restores it mid-run but a crewmate standing over you, so the ceiling is how many mistakes a layer is worth.",
	"breaker": "Raises the cutter's damage and the distance it will reach to. Against a 100-integrity Scrubber the damage tiers read as a shot count.",
	"optics": "Widens, brightens and lengthens the decryption beam. The exposure cone Scrubbers flee from is derived from the same numbers, so seeing and being avoided are one purchase.",
	"servos": "Multiplies walk and sprint top speed and shortens the channel to restore a downed crewmate. The restore half is the one that decides fights.",
	"buffer": "Raises how many data chips you carry before weight tells, and lowers what each chip past that costs you in speed.",
	"cache": "Raises the flares you inject with. Burning one still bills the shared pool, so stock is never the answer to the dark, only the option.",
}


static func module_body(track: String) -> String:
	return String(MODULE_BODY.get(track, ""))


## What the next tier of a module actually does, in the units the player reads
## elsewhere: metres, degrees, seconds, percent. Deliberately concrete — "BEAM
## 26° → 30°" is a decision, "OPTICS II" is a shopping list.
##
## Lifted out of `CompilerPanel` unchanged so the Codex prints the same arithmetic
## the shop does rather than a second copy of it.
static func module_delta(track: String, tier: int) -> String:
	var next: int = tier + 1
	if next > Modules.tier_count(track):
		return Modules.note(track)
	match track:
		"runtime":
			return "SHARE %d → %d CYCLES   ·   DRAIN %.2f → %.2f /s" % [
				int(Balance.CYCLES_PER_CREW + float(Modules.value_at(track, "share", tier))),
				int(Balance.CYCLES_PER_CREW + float(Modules.value_at(track, "share", next))),
				Balance.PASSIVE_DRAIN * float(Modules.value_at(track, "drain", tier)),
				Balance.PASSIVE_DRAIN * float(Modules.value_at(track, "drain", next))]
		"threading":
			return "SPRINT COST ×%.2f → ×%.2f" % [
				float(Modules.value_at(track, "sprint", tier)),
				float(Modules.value_at(track, "sprint", next))]
		"checksum":
			return "MAX INTEGRITY %d → %d" % [
				int(Modules.value_at(track, "integrity", tier)),
				int(Modules.value_at(track, "integrity", next))]
		"breaker":
			return "DAMAGE %d → %d   ·   REACH %.1f → %.1f m" % [
				int(Modules.value_at(track, "damage", tier)),
				int(Modules.value_at(track, "damage", next)),
				float(Modules.value_at(track, "range", tier)),
				float(Modules.value_at(track, "range", next))]
		"optics":
			return "BEAM %.0f° → %.0f°   ·   REACH %d → %d m" % [
				float(Modules.value_at(track, "angle", tier)),
				float(Modules.value_at(track, "angle", next)),
				int(Modules.value_at(track, "reach", tier)),
				int(Modules.value_at(track, "reach", next))]
		"servos":
			return "MOVE ×%.2f → ×%.2f   ·   RESTORE %.1f → %.1f s" % [
				float(Modules.value_at(track, "move", tier)),
				float(Modules.value_at(track, "move", next)),
				Balance.RESTORE_CHANNEL_TIME * float(Modules.value_at(track, "restore", tier)),
				Balance.RESTORE_CHANNEL_TIME * float(Modules.value_at(track, "restore", next))]
		"buffer":
			return "FREE CARRY %d → %d CHIPS   ·   DRAG %d%% → %d%%" % [
				int(Modules.value_at(track, "free", tier)),
				int(Modules.value_at(track, "free", next)),
				int(round(float(Modules.value_at(track, "penalty", tier)) * 100.0)),
				int(round(float(Modules.value_at(track, "penalty", next)) * 100.0))]
		"cache":
			return "FLARES %d → %d" % [
				int(Modules.value_at(track, "stock", tier)),
				int(Modules.value_at(track, "stock", next))]
	return Modules.note(track)


# --------------------------------------------------------------- subroutines --

const SUBROUTINE_BODY: Dictionary = {
	"surge_step": "Moves your avatar along its own collision — a slide, not a teleport, so it cannot pass a wall or skip geometry. The immunity window is placed by you and covers a strike already in the air.",
	"stack_pulse": "A radial burst that cancels lunges, knocks light processes back and stuns heavy ones where they stand. It cannot kill anything, and it rings a two-room noise every single time.",
	"fork_decoy": "Forks a ghost of your avatar and walks it away from you. Every process that hunts by position goes with it until its timer runs out or it has soaked its strikes.",
	"checksum_barrier": "A spherical integrity shell that absorbs damage for anyone standing inside it, crew included. MOTHER notices every cast: it is a program asserting its own integrity inside hers.",
}


static func subroutine_body(id: String) -> String:
	return String(SUBROUTINE_BODY.get(id, ""))


## What the next tier of a subroutine costs and buys. Tier 0 has no delta to
## print — a player who does not own it needs the verb, which `note` is.
static func subroutine_delta(id: String, tier: int) -> String:
	var next: int = tier + 1
	if tier <= 0 or next > Subs.tier_count(id):
		return Subs.note(id)
	var line: String = "COST %d → %d CYC   ·   CD %.1f → %.1f s" % [
		int(Subs.value_at(id, "cost", tier)),
		int(Subs.value_at(id, "cost", next)),
		float(Subs.value_at(id, "cooldown", tier)),
		float(Subs.value_at(id, "cooldown", next))]
	# One track-specific number on top, chosen as the thing that changes the play
	# rather than the thing that changes the most.
	match id:
		"stack_pulse":
			line += "   ·   HOLD %.1f → %.1f s" % [
				float(Subs.value_at(id, "stagger", tier)),
				float(Subs.value_at(id, "stagger", next))]
		"fork_decoy":
			line += "   ·   LIFE %.0f → %.0f s" % [
				float(Subs.value_at(id, "lifetime", tier)),
				float(Subs.value_at(id, "lifetime", next))]
		"checksum_barrier":
			line += "   ·   ABSORB %d → %d" % [
				int(Subs.value_at(id, "absorb", tier)),
				int(Subs.value_at(id, "absorb", next))]
	return line


## Everything a subroutine is at the tier you own, rather than the delta to the
## next one. The Codex prints this; the shop prints the delta.
static func subroutine_state(id: String, tier: int) -> String:
	if tier <= 0:
		return "NOT COMPILED"
	var parts: PackedStringArray = PackedStringArray()
	parts.append("COST %d CYC" % int(Subs.value_at(id, "cost", tier)))
	parts.append("CD %.1f s" % float(Subs.value_at(id, "cooldown", tier)))
	match id:
		"surge_step":
			parts.append("%.1f m" % float(Subs.value_at(id, "distance", tier)))
			parts.append("IMMUNE %.2f s" % float(Subs.value_at(id, "iframes", tier)))
		"stack_pulse":
			parts.append("%.1f m" % float(Subs.value_at(id, "radius", tier)))
			parts.append("HOLD %.1f s" % float(Subs.value_at(id, "stagger", tier)))
		"fork_decoy":
			parts.append("LIFE %.0f s" % float(Subs.value_at(id, "lifetime", tier)))
			parts.append("SOAKS %d" % int(Subs.value_at(id, "hits", tier)))
		"checksum_barrier":
			parts.append("%.1f m" % float(Subs.value_at(id, "radius", tier)))
			parts.append("ABSORBS %d" % int(Subs.value_at(id, "absorb", tier)))
	return "   ·   ".join(parts)


# ------------------------------------------------------------------ shared --

## Trim `text` to fit `width` canvas pixels in `font` at `size`, with an ellipsis
## when it had to bite. Used by the hand-drawn surfaces (the patch strip), which
## have no `Label.clip_text` to do it for them.
static func fit(font: Font, text: String, size: int, width: float) -> String:
	if font == null or text.is_empty() or width <= 0.0:
		return ""
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x <= width:
		return text
	var out: String = text
	while out.length() > 1:
		out = out.substr(0, out.length() - 1)
		if font.get_string_size(out + "…", HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				size).x <= width:
			return out.strip_edges(false, true) + "…"
	return "…"
