class_name ScanSweep
extends Node3D
## Rotating red alarm beacon for the docking bay. Sweeps a volumetric shaft
## across the whole room, which is what makes the bay read as *big*.
##
## Cosmetic, so it runs locally on every peer. It is driven from the wall clock
## rather than accumulated delta so peers stay roughly in phase for free.

@export var rotation_speed: float = 1.15
@export var pulse_depth: float = 0.22

@onready var _light: SpotLight3D = get_node_or_null("Spot") as SpotLight3D

var _base_energy: float = 0.0


func _ready() -> void:
	if _light != null:
		_base_energy = _light.light_energy


func _process(_delta: float) -> void:
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	rotation.y = t * rotation_speed
	if _light != null:
		_light.light_energy = _base_energy * (1.0 - pulse_depth + sin(t * 2.4) * pulse_depth)
