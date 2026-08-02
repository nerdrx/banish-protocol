@tool
class_name FidelityCrtTerminal
extends Node3D
## CRT TERMINAL — light-cast retrofit prototype.
##
## THE PROBLEM THIS IS A PROTOTYPE FOR
## The game already has CRT terminals (src/world/command_terminal.gd, M4.8) and
## they are emissive-only: the screen glows, and the room around it does not
## change. That is defensible — an emissive surface is free, a light is not —
## but it is also the single largest gap between our comms-room screenshots and
## the user's Isolation comms-room reference. In the reference the monitors are
## not bright objects, they are the LIGHT SOURCE: green falls on the desk, on
## the operator's hands, on the ceiling above, and the room's whole colour comes
## from three tubes and nothing else. An emissive quad cannot do that. Neither
## can SSIL, which only bounces what is already on screen and dies the moment
## the player looks away from the monitor at the thing the monitor was lighting.
##
## THE RETROFIT
## Put an AreaLight3D immediately in front of the screen, sized to the screen,
## and feed it the SCREEN'S OWN IMAGE as `area_texture`. That last part is the
## reason this is worth building rather than just bolting an omni behind the
## glass: a textured area light casts the brightness distribution of its own
## texture, so the bright header bar spills more than the dim body text, and if
## the screen content ever changes the cast changes with it. The light is not
## "green light near a monitor", it is that monitor lighting the room.
##
## COST, HONESTLY
## One shadowed area light per terminal is not shippable at the density the
## comms rooms want. `use_area_light` is the switch, and the intended policy is
## the same as the diffuser panel's: the ONE terminal a room is composed around
## gets a real light, its neighbours are emissive-only and borrow the hero's
## spill. Which one is the hero is a level-design decision, so it is an export,
## not a global quality tier.
##
## `assets/props/fidelity/crt_lightcast_ab.tscn` puts the two modes side by side
## in one frame so the difference can be photographed rather than argued about.

@export_group("Screen")
## Emissive-only (false) vs emissive + a real textured AreaLight3D (true).
@export var use_area_light: bool = true:
	set(v):
		use_area_light = v
		_apply()
## P1 green. Not pure green — see the note in build_fidelity_materials.py: a
## fully saturated primary has nowhere to roll off under AgX and clips flat.
@export var phosphor: Color = Color(0.34, 1.0, 0.42):
	set(v):
		phosphor = v
		_apply()
@export_range(0.0, 12.0, 0.05) var screen_emission: float = 2.4:
	set(v):
		screen_emission = v
		_apply()
@export_range(0.0, 20.0, 0.05) var cast_energy: float = 3.1:
	set(v):
		cast_energy = v
		_apply()
@export_range(0.2, 20.0, 0.1) var cast_range_m: float = 4.6:
	set(v):
		cast_range_m = v
		_apply()
## Soft shadows off by default. A terminal casting a shadow of the desk it sits
## on is correct and almost invisible; a terminal casting a shadow of the
## OPERATOR is the shot, and that only happens in the one room where somebody
## composed for it.
@export var cast_shadows: bool = false:
	set(v):
		cast_shadows = v
		_apply()
@export_range(0.0, 3.0, 0.05) var volumetric_boost: float = 0.7:
	set(v):
		volumetric_boost = v
		_apply()
## Feed the screen image to the light. Off = a flat wash of `phosphor`, which is
## what a naive retrofit gives you and is worth being able to see next to the
## textured version.
@export var textured_cast: bool = true:
	set(v):
		textured_cast = v
		_apply()


func _ready() -> void:
	_apply()


func _apply() -> void:
	if not is_inside_tree():
		return

	var screen: MeshInstance3D = get_node_or_null("Screen") as MeshInstance3D
	if screen != null:
		var m: StandardMaterial3D = screen.get_surface_override_material(0) as StandardMaterial3D
		if m != null:
			m.emission = phosphor
			m.emission_energy_multiplier = screen_emission

	var a: AreaLight3D = get_node_or_null("Cast") as AreaLight3D
	if a != null:
		a.visible = use_area_light
		a.light_color = phosphor
		a.light_energy = cast_energy
		a.area_range = cast_range_m
		a.shadow_enabled = use_area_light and cast_shadows
		a.light_volumetric_fog_energy = volumetric_boost
		a.area_normalize_energy = true
		a.area_texture = (load(FidelityLib.TEX_CRT_PHOSPHOR) as Texture2D) \
				if textured_cast else null
