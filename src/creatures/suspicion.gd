class_name Suspicion
extends RefCounted
## M11 — the suspicion ladder every hunting process climbs, as a PURE function.
##
## The M10 verdict was "the enemy ai feels waayyyyyyy tooo simple", and the
## diagnosis was right: every creature in the game was a single-stimulus reflex
## with binary states. A Scrubber fled light. A Hound came to noise. A Moth went
## to light. Learn the one rule and the creature is solved forever.
##
## ALIEN: ISOLATION's alien is frightening for one structural reason, and it is
## not its senses — it is that it SEARCHES. It half-heard something, it comes to
## look, it checks the places you could be, it lingers, it appears to leave, it
## comes back. The gap between "reacts" and "investigates" is this ladder:
##
##   UNAWARE   nothing registered. Patrol, drift, do your job.
##   CURIOUS   something registered, weakly. Drift toward it and LOOK.
##   ALERT     something is definitely here. Actively search this area.
##   HUNTING   live evidence of a target right now. Close.
##   LOST      it had a target and the evidence stopped. Go to the last-known
##             position, then search OUTWARD through plausible places.
##
## LOST is where the fear lives. A creature that gives up instantly is a puzzle;
## one that keeps checking is a predator. So the descent back down the ladder is
## deliberately RELUCTANT — minimum dwell times, exit thresholds well below entry
## thresholds, and a decay rate that is slowest immediately after losing contact.
##
## ## Why this is a RefCounted of statics rather than code inside the creature
##
## Because AI is famously hard to test, and the only way to make it testable is
## to make the decisions pure. Everything below is a function of numbers in and
## numbers out: no tree, no physics, no rendering, no host. `--selftest` drives
## the whole ladder headlessly with synthetic evidence and asserts that awareness
## decays to UNAWARE when evidence stops, that the thresholds are ordered, that
## hysteresis is real, and that no state can flicker. The creature is a thin shell
## over this; the shell is what the captures show, and this is what the gate runs.

enum State { UNAWARE, CURIOUS, ALERT, HUNTING, LOST }

## Awareness needed to CLIMB into each state. Strictly increasing — asserted.
const CURIOUS_ENTER: float = 0.16
const ALERT_ENTER: float = 0.42
const HUNT_ENTER: float = 0.78

## Awareness at which each state gives up and falls back. Strictly BELOW its
## matching entry threshold: that gap is the hysteresis, and it is the difference
## between a creature that investigates and a creature that vibrates on a
## threshold. Also asserted.
const CURIOUS_EXIT: float = 0.06
const ALERT_EXIT: float = 0.26
const HUNT_EXIT: float = 0.55

## Minimum seconds a state must be held before it may fall BACK down the ladder.
## Climbing is instant (evidence is evidence); giving up is not. This is the
## mechanical spelling of "reluctant".
const DWELL_CURIOUS: float = 2.5
const DWELL_ALERT: float = 5.0
const DWELL_LOST: float = 8.0

## Seconds a LOST creature will keep searching after its search list is exhausted
## before it accepts it has been beaten. Being out of places to look is not the
## same as being satisfied.
const LOST_GRACE: float = 4.0


## One step of the ladder.
##
## `awareness` is the perception model's 0..1 accumulator for the best target.
## `live` says whether evidence arrived THIS tick (the difference between "I can
## see you" and "I remember seeing you"). `dwell` is seconds spent in `state`.
## `search_done` says the creature has run out of plausible places to check.
##
## Returns {state, dwell, reason} — `reason` is a short machine-readable tag that
## goes straight into the AI trace, because "why did it change its mind" is the
## single question the instrument exists to answer.
static func step(state: int, awareness: float, live: bool, dwell: float,
		delta: float, search_done: bool) -> Dictionary:
	var next: int = state
	var reason: String = "hold"
	var held: float = dwell + delta

	# --- climbing. Always available, never gated on dwell: evidence wins. ------
	if live and awareness >= HUNT_ENTER:
		next = State.HUNTING
		reason = "evidence>=hunt"
	elif state == State.HUNTING and not live:
		# The moment that makes the creature: contact broken. It does NOT drop to
		# ALERT and wander — it goes LOST, which means it still believes in you and
		# is about to come looking where you were.
		next = State.LOST
		reason = "contact-lost"
	elif state != State.HUNTING and state != State.LOST and awareness >= ALERT_ENTER:
		next = State.ALERT
		reason = "evidence>=alert"
	elif state == State.UNAWARE and awareness >= CURIOUS_ENTER:
		next = State.CURIOUS
		reason = "evidence>=curious"
	else:
		# --- falling. Gated on dwell AND on the exit threshold. ----------------
		match state:
			State.LOST:
				if awareness >= HUNT_ENTER and live:
					next = State.HUNTING
					reason = "reacquired"
				elif held >= DWELL_LOST and (search_done or awareness < ALERT_EXIT):
					next = State.ALERT
					reason = "search-exhausted" if search_done else "faded"
			State.ALERT:
				if held >= DWELL_ALERT and awareness < ALERT_EXIT:
					next = State.CURIOUS
					reason = "faded<alert"
			State.CURIOUS:
				if held >= DWELL_CURIOUS and awareness < CURIOUS_EXIT:
					next = State.UNAWARE
					reason = "faded<curious"
			State.HUNTING:
				if awareness < HUNT_EXIT:
					next = State.LOST
					reason = "faded<hunt"
			_:
				pass

	if next != state:
		held = 0.0
	return {"state": next, "dwell": held, "reason": reason}


## How fast awareness bleeds away in a given state, as a multiplier on the base
## decay. A LOST creature forgets you SLOWEST — that is what keeps it looking —
## and an UNAWARE one forgets fastest, so a creature that was mildly curious about
## a dropped can does not carry it around for a minute.
static func decay_scale(state: int) -> float:
	match state:
		State.LOST:
			return 0.35
		State.HUNTING:
			return 0.55
		State.ALERT:
			return 0.7
		State.CURIOUS:
			return 1.0
		_:
			return 1.6


## Short label for logs, traces and the debug overlay.
static func label(state: int) -> String:
	match state:
		State.CURIOUS:
			return "CURIOUS"
		State.ALERT:
			return "ALERT"
		State.HUNTING:
			return "HUNTING"
		State.LOST:
			return "LOST"
		_:
			return "UNAWARE"


## TELEGRAPHS ARE A SHIP GATE (M11 acceptance). A deep AI the player cannot read
## is not scary, it is unfair — so every state a creature can be in has a caption
## key, and the caption is the deaf player's copy of the audio tell. The keys
## resolve in `CaptionBus.TABLE`; `--selftest` asserts every entry here exists
## there, so a state added later without a tell fails the gate rather than
## shipping silently.
##
## UNAWARE deliberately has no caption: "the creature is doing nothing" is not an
## event, and captioning it would bury the three that matter.
static func caption_key(state: int) -> StringName:
	match state:
		State.CURIOUS:
			return &"ai_curious"
		State.ALERT:
			return &"ai_alert"
		State.HUNTING:
			return &"ai_hunting"
		State.LOST:
			return &"ai_searching"
		_:
			return &""


## Whether entering `state` is worth telling the player about at all. Climbing is
## always announced (it is threat information); falling is announced only into
## LOST, because "it lost you and is now searching" is the most useful thing a
## player can know and the whole reason the state exists.
static func announces(from_state: int, to_state: int) -> bool:
	if to_state == State.UNAWARE:
		return false
	if to_state == State.LOST:
		return true
	return to_state > from_state
