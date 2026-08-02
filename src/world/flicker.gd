extends Node
## Flicker behaviour bolted onto any Light3D — the SpotLight3D keys and accents
## the LightRig places, which cannot be FlickerLight (that is an OmniLight3D).
##
## The curves live in `FlickerLight.level()` so there is exactly one definition of
## what DYING looks like in the codebase. Everything is deterministic from
## `seed_offset`; drive it from the shared run seed and four clients see the same
## fixture do the same thing with zero replication.

@export var mode: FlickerLight.Mode = FlickerLight.Mode.BREATHE
@export var base_energy: float = 1.0
@export var seed_offset: float = 0.0

var _light: Light3D = null
var _t: float = 0.0
var _emissive: GeometryInstance3D = null


func _ready() -> void:
	_light = get_parent() as Light3D
	if _light == null:
		push_error("[Flicker] must be a child of a Light3D")
		set_process(false)
		return
	if base_energy <= 0.0:
		base_energy = _light.light_energy
	_light.set_meta("base_energy", base_energy)
	_t = seed_offset


func _process(delta: float) -> void:
	_t += delta
	var k: float = FlickerLight.level(mode, _t, seed_offset)
	# Read the meta rather than the cached value: LightRig.set_alert() rewrites
	# base_energy when a layer goes hostile, and a flickering accent has to follow
	# it down instead of fighting it.
	_light.light_energy = float(_light.get_meta("base_energy", base_energy)) * k
	if _emissive != null:
		# `emissive_gain` is an `instance uniform` on nv_dataflow. It used to be
		# written as "flicker_gain", which no shader in the project has ever
		# declared — so binding a housing to its light was a silent no-op from
		# M3.7 until M4.7. The name now matches the shader.
		#
		# Whether it ever RUNS is a different question: see `bind_emissive`.
		_emissive.set_instance_shader_parameter("emissive_gain", k)


## Optional: tie a mesh's emission to the same curve.
##
## **Nothing in `src/` calls this**, so `_emissive` is always null and the branch
## above is unreachable — SpotLight keys and accents flicker without their
## housings dimming with them. Kept rather than deleted because it is the correct
## half of a two-part effect and the M4.7 uniform rename above made it work; what
## is missing is a call from `LightRig.flicker` when the fixture it is lighting
## has an emissive housing. Named here so the next reader knows it is a gap and
## not a mechanism they have failed to find.
func bind_emissive(mesh: GeometryInstance3D) -> void:
	_emissive = mesh
