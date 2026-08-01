class_name Interactable
extends Node3D
## Base for anything the crew holds E on.
##
## Split of responsibility, following M1's client-authority-with-host-validation
## pattern: the *channel* is local (instant feedback, no round trip to fill a
## progress ring) and the *effect* is host-validated. A client that fakes a
## completed channel still has to survive Run's proximity and state checks.
##
## Detection is a physics ray from the player's camera against a probe Area3D on
## the "interact" layer, so an interactable can be any shape and never interferes
## with movement collision.

## Physics layer 3 — see project.godot [layer_names]. Bodies stay on 1/2.
const INTERACT_LAYER: int = 4

@export var channel_time: float = 2.5

## True while this is what the local crosshair is on. Set by Player; read by the
## world prompt, which never fades out something you are aiming at.
var focused: bool = false

var _probe: Area3D = null
var _prompt: WorldPrompt = null


## Prompt shown while the player is looking at this. Uppercase: the HUD is
## stencilled equipment, not prose.
##
## M3.8 moved the *presentation* of this into the world (see `prompt_title`);
## this string is still the one source of truth for what the thing has to say,
## and it is what the screen-centre accessibility fallback prints.
func prompt() -> String:
	return "HOLD E"


# ------------------------------------------------------- world-space prompt --
#
# The diegetic prompt is assembled from three pieces rather than one sentence: a
# category glyph, the key on a keycap, and a short title. "HOLD E · SIPHON TAP"
# is a HUD line; a glyph, an E and the word SIPHON TAP is a label on a machine.

## Short name of the thing, with no verb and no key in it.
func prompt_title() -> String:
	return prompt()


## The letter drawn in the keycap ring. Empty means there is nothing to hold —
## the prompt is telling you something rather than offering you something.
func prompt_key() -> String:
	return "E" if available() else ""


## One glyph, the category marker. Kept to basic geometric shapes so it resolves
## in every font on the system-font fallback chain.
func prompt_glyph() -> String:
	return "◆"


## Height above this node's origin the prompt floats at. Chosen per subclass so
## the label clears the machine instead of hanging inside it.
func prompt_height() -> float:
	return 2.4


func prompt_anchor() -> Vector3:
	return Vector3(0.0, prompt_height(), 0.0)


## Whether the prompt should exist at all right now. Distinct from `available()`:
## a drained tap still says TAP DRAINED, but a crewmate who is on their feet has
## no restore prompt to show.
func prompt_visible() -> bool:
	return true


## Called by Player when the crosshair arrives on or leaves this.
func set_focused(on: bool) -> void:
	focused = on


## Player's single entry point for channel feedback: fans the fill out to the
## world prompt's ring and then to whatever the subclass does with it.
##
## Subclasses override `set_channel_visual` and do not call super, so the prompt
## plumbing cannot live in there.
func apply_channel(progress: float) -> void:
	if _prompt != null and is_instance_valid(_prompt):
		_prompt.set_progress(progress)
	set_channel_visual(progress)


## Whether a channel may start at all. A refusal still shows `prompt()`, so the
## HUD can explain *why* it is refusing (e.g. "CREW IN SHAFT 2/3").
func available() -> bool:
	return true


## Local channel reached full. Ask the host to make it real.
func complete() -> void:
	pass


## Called every frame the local player is channelling this, 0..1. Cosmetic only.
func set_channel_visual(_progress: float) -> void:
	pass


## Builds the detection probe. Called by subclasses during construction, before
## the node enters the tree.
func _add_probe(size: Vector3, offset: Vector3 = Vector3.ZERO) -> void:
	_probe = Area3D.new()
	_probe.name = "Probe"
	_probe.collision_layer = INTERACT_LAYER
	_probe.collision_mask = 0
	# `monitoring` off: the probe never needs to know what is inside it, and the
	# overlap bookkeeping is pure cost. `monitorable` ON is not optional —
	# a non-monitorable Area3D is skipped by intersect_ray(), so the probe would
	# exist and simply never be found.
	_probe.monitoring = false
	_probe.monitorable = true
	_probe.position = offset

	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	_probe.add_child(shape)
	add_child(_probe)

	# Every interactable in the game builds its probe exactly once, during
	# assembly — which makes this the one hook the base class has that no
	# subclass overrides (`_ready` is overridden by most of them and none of them
	# call super). The world prompt is built here for that reason and no other.
	_prompt = WorldPrompt.create(self)
	add_child(_prompt)


## Interactables that are only sometimes there at all — a crewmate you can
## restore, and only while they are down — switch their probe off rather than
## refusing in `available()`, so the crosshair passes straight through them.
func set_probe_enabled(on: bool) -> void:
	if _probe == null or not is_instance_valid(_probe):
		return
	_probe.collision_layer = INTERACT_LAYER if on else 0
