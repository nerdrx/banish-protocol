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

var _probe: Area3D = null


## Prompt shown while the player is looking at this. Uppercase: the HUD is
## stencilled equipment, not prose.
func prompt() -> String:
	return "HOLD E"


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
