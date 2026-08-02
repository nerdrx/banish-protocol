class_name Hunter
extends Antivirus
## Base for M6's hunter processes — the Hound, the Moth and the Auditor.
##
## A hunter is an Antivirus like any other and rides the exact same rails: the
## host simulates its state machine, every peer smooths a streamed pose, death
## travels as `sync_dead`, and the breaker kills it through `take_damage` /
## `breaker_damage` with no special casing. That is the killability law made
## structural — a hunter is not a boss with rules of its own, it is a creature
## that hunts by a different sense, and the sense is the whole character.
##
## What the base adds over Antivirus is three things all three hunters share:
##
##   * **Existence is directed, not seeded.** A Scrubber's existence is a pure
##     function of the seed; a hunter's is a runtime decision the Director makes
##     off stress and noise, replicated exactly like the M4.8 reinforcement
##     trickle (one reliable packet, host to crew). So hunters are built by
##     `AntivirusDirector.spawn_hunter` and their *placement* — the seeded nests
##     they enter from and the Auditor's route — lives in the LayerGraph dump,
##     but *when* one appears does not.
##
##   * **The "hunter" group**, which the glitch-proximity HUD sense and the
##     Director both sweep. Antivirus already puts everything in `antivirus`;
##     this narrows it so the Scrubbers and the Sentinel do not drive the radar.
##
##   * **Death is an event the Director cares about.** Killing a hunter drops a
##     reward and starts a recompile timer (DESIGN.md: "killing buys time, never
##     peace"). The base routes both through `HauntDirector` so a subclass only
##     has to say what it drops and how long it stays dead.
##
## Subclasses still implement `_think`/`_act`/`_assemble` like any Antivirus, plus
## `hunter_kind` for the Director's bookkeeping and the music/bark stingers.

const HUNTER_GROUP: String = "hunter"

## Whether this hunter has already reported its own removal to the Director, so a
## kill that also despawns (or a despawn during teardown) reports exactly once.
var _reported: bool = false


func _ready() -> void:
	super()
	add_to_group(HUNTER_GROUP)


## The Director's key for this class — drives the recompile schedule, the music
## stinger (`Music.play_hunter`) and the hunt barks. Subclasses override.
func hunter_kind() -> StringName:
	return &"hunter"


## Reward dropped when this hunter is finished, and how the layer stays quiet
## afterwards. Subclasses set them; the base spills the salvage host-side.
func _drop_shards() -> int:
	return 0


func _drop_pieces() -> int:
	return 0


## Seconds before the Director recompiles the process after a KILL. Negative
## means "do not auto-recompile" (the Auditor: a deleted audit stays ended).
func _recompile_after_kill() -> float:
	return -1.0


## Host-side death. Everything hostile is killable; a finished hunter spills its
## reward and hands the Director the recompile timer, then dies down the ordinary
## Antivirus path so the shatter and the streamed `sync_dead` are unchanged.
func kill() -> void:
	if _dying:
		return
	if _is_host:
		var shards: int = _drop_shards()
		var pieces: int = _drop_pieces()
		if shards > 0 or pieces > 0:
			Run.drop_salvage(global_position, shards, pieces)
		_report_removed(true)
	super()


## Silent removal on descent. Reports the removal so the Director does not keep a
## dangling reference into a layer that no longer exists — but as a teardown, not
## a kill, so it schedules nothing.
func despawn() -> void:
	_report_removed(false)
	super()


## A hunter that took itself off the board without being killed — the Hound
## slinking away to recompile once it has escaped into the dark. No reward, a
## shorter and quieter recompile than a kill buys.
func slink_away() -> void:
	if _dying:
		return
	if _is_host:
		# `false`: this is NOT a kill. It only trips the report guard so a later
		# `despawn()` cannot double-report — the kill path (reward, kill_ack bark,
		# silence) must not run for a hunter that got away. The recompile the slink
		# earns is the Director's job, through `on_hunter_slunk`.
		_report_removed(false)
		Haunt.on_hunter_slunk(hunter_kind())
	# Fade out down the same path as a death, so a client sees it leave rather than
	# vanish; the difference from a kill is only what the Director schedules.
	sync_dead = true
	_begin_death()


## Tell the Director this hunter is gone. `killed` distinguishes a finish (start
## the recompile the kill bought) from a teardown (the layer is being rewritten).
func _report_removed(killed: bool) -> void:
	if _reported or not _is_host:
		return
	_reported = true
	if killed:
		Haunt.on_hunter_killed(hunter_kind(), _recompile_after_kill())
