class_name RestorePoint
extends Interactable
## The channel target a corrupted crewmate becomes.
##
## DESIGN.md: "Corrupted (downed) state: crewmates restore you (channel)." Rather
## than a separate world prop that would have to be spawned, tracked and freed,
## every avatar carries one and it is simply not *there* — its probe is off —
## until that avatar goes down. Crosshairs pass straight through a crewmate who
## is on their feet.
##
## The channel is local (M1's pattern); the restore itself is host-validated in
## Run._restore_request, which checks the rescuer is genuinely stood over them.

var peer_id: int = 1

var _enabled: bool = false


static func create(owner_peer: int) -> RestorePoint:
	var point: RestorePoint = RestorePoint.new()
	point.name = "RestorePoint"
	point.peer_id = owner_peer
	point.channel_time = Balance.RESTORE_CHANNEL_TIME
	# A generous box around the kneeling shell: you are aiming at something on
	# the floor, in the dark, while something else is lunging at you.
	point._add_probe(Vector3(1.8, 2.0, 1.8), Vector3(0.0, 0.8, 0.0))
	point.set_probe_enabled(false)
	return point


func prompt() -> String:
	return "HOLD E  ·  RESTORE %s  (%ds)" % [
		Net.crew_name(peer_id), int(ceilf(Run.corruption_left(peer_id)))]


func prompt_title() -> String:
	return "RESTORE %s  ·  %ds" % [
		Net.crew_name(peer_id), int(ceilf(Run.corruption_left(peer_id)))]


func prompt_glyph() -> String:
	return "◇"


## Just above a kneeling shell, not above a standing one: this only ever exists
## while its owner is on the floor.
func prompt_height() -> float:
	return 1.5


## A crewmate on their feet is not a prompt. Unlike a drained siphon tap, there
## is nothing here to label until they go down.
func prompt_visible() -> bool:
	return Run.is_corrupted(peer_id) and peer_id != Net.local_id()


func available() -> bool:
	return Run.is_corrupted(peer_id) and peer_id != Net.local_id() and Run.local_running()


func complete() -> void:
	Run.request_restore(peer_id)


func _process(_delta: float) -> void:
	# Only crewmates who are down can be aimed at, and only by someone who could
	# actually help them.
	var wanted: bool = Run.is_corrupted(peer_id) and peer_id != Net.local_id()
	if wanted == _enabled:
		return
	_enabled = wanted
	set_probe_enabled(wanted)
