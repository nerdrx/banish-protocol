class_name ScanSweep
extends Node3D
## Slow red scan sweep — MOTHER looking around a room she still bothers to watch.
##
## Deliberately slow. A fast rotating beacon reads as an alarm ("something has
## gone wrong"); a slow one reads as surveillance ("this is routine, and you are
## the thing that isn't"). DESIGN.md reserves red for hostile processes, so this
## is the only red light on an otherwise teal layer.
##
## Cosmetic, so it runs locally on every peer with no replication.
##
## The clock is `Time.get_ticks_msec()` — milliseconds since **that peer's**
## engine started — so two peers are NOT in phase with each other, and a player
## who joined three minutes later sees the beam somewhere else entirely. That is
## survivable only because it is decoration: the one sweep whose aim is a
## question players ask out loud is the Sentinel's, and that one sets
## `driven = true` and takes its angle off replicated `sync_sweep` state.

@export var sweep_speed: float = 0.42
@export var pulse_depth: float = 0.14
## When set, something else owns `rotation.y` — M3's Sentinel aims its own sweep
## from a replicated angle, because a sweep that misses on your screen and hits
## on the host's would be unplayable. The breathing pulse still runs.
@export var driven: bool = false

@onready var _light: SpotLight3D = get_node_or_null("Spot") as SpotLight3D

var _base_energy: float = 0.0


func _ready() -> void:
	if _light != null:
		_base_energy = _light.light_energy


## Brightness scale applied on top of the breath, so a driver can dim the sweep
## while its owner is dormant and blow it out on an alarm.
func set_intensity(scale: float) -> void:
	if _light != null:
		_light.light_energy = maxf(_base_energy * scale, 0.0)


func _process(_delta: float) -> void:
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	if not driven:
		rotation.y = t * sweep_speed
	if _light != null and not driven:
		# A slow breath on top of the rotation, so the sweep never sits at one
		# steady brightness long enough to become wallpaper.
		_light.light_energy = _base_energy * (1.0 - pulse_depth + sin(t * 1.3) * pulse_depth)
