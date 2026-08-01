class_name FlickerLight
extends OmniLight3D
## A failing emergency strip. Mostly stable, with brownouts and the occasional
## full dropout — the dropout is the point, because it teaches the player not to
## trust anything on this layer except their own beam.
##
## Purely cosmetic and therefore run locally on every peer (no replication):
## crewmates seeing slightly different flicker phases costs nothing.

@export var base_energy: float = 1.0
@export var emissive_mesh: MeshInstance3D = null

const NOISE_SPEED: float = 9.0
const DROPOUT_CHANCE: float = 0.006
const DROPOUT_MIN: float = 0.05
const DROPOUT_MAX: float = 0.38

var _phase: float = 0.0
var _dropout_left: float = 0.0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _emissive_material: StandardMaterial3D = null


func _ready() -> void:
	_rng.randomize()
	_phase = _rng.randf() * 100.0
	if emissive_mesh != null:
		var source: StandardMaterial3D = emissive_mesh.material_override as StandardMaterial3D
		if source != null:
			_emissive_material = source.duplicate() as StandardMaterial3D
			emissive_mesh.material_override = _emissive_material


func _process(delta: float) -> void:
	_phase += delta * NOISE_SPEED
	var level: float = 1.0

	if _dropout_left > 0.0:
		_dropout_left -= delta
		level = _rng.randf_range(0.0, 0.09)
	else:
		if _rng.randf() < DROPOUT_CHANCE:
			_dropout_left = _rng.randf_range(DROPOUT_MIN, DROPOUT_MAX)
		# Two detuned sines read as an unstable ballast rather than a sine wave.
		level = 0.86 + sin(_phase) * 0.08 + sin(_phase * 2.37) * 0.06

	light_energy = base_energy * level
	if _emissive_material != null:
		_emissive_material.emission_energy_multiplier = maxf(level * 1.4, 0.02)
