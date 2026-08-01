class_name ScanSweep
extends Node3D
## Slow red scan sweep — MOTHER looking around a room she still bothers to watch.
##
## Deliberately slow. A fast rotating beacon reads as an alarm ("something has
## gone wrong"); a slow one reads as surveillance ("this is routine, and you are
## the thing that isn't"). DESIGN.md reserves red for hostile processes, so this
## is the only red light on an otherwise teal layer.
##
## Cosmetic, so it runs locally on every peer with no replication. It is driven
## from the wall clock rather than accumulated delta, so peers stay roughly in
## phase for free.

@export var sweep_speed: float = 0.42
@export var pulse_depth: float = 0.14

@onready var _light: SpotLight3D = get_node_or_null("Spot") as SpotLight3D

var _base_energy: float = 0.0


func _ready() -> void:
	if _light != null:
		_base_energy = _light.light_energy


func _process(_delta: float) -> void:
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	rotation.y = t * sweep_speed
	if _light != null:
		# A slow breath on top of the rotation, so the sweep never sits at one
		# steady brightness long enough to become wallpaper.
		_light.light_energy = _base_energy * (1.0 - pulse_depth + sin(t * 1.3) * pulse_depth)
