class_name MotherLens
extends Node3D
## MOTHER's aperture over the Partition. She lost this sector. She still watches it.
##
## DESIGN.md M6: *"MOTHER addresses players by callsign through glyph panels.
## Rarely. She has always known."* The hub is the one room where that is not a
## threat — she cannot reach the crew in here — which is exactly what makes it the
## right room for it. A voice with no consequences behind it is worse than one
## with consequences, and this is the only place in the game she gets to be that.
##
## ## What it does
##
## Structurally: a sealed housing high on the hall's north wall with a dead
## optic in it that is not quite dead. It is the composition's north anchor —
## the rig sits under it, so looking at the way down means looking at her.
##
## Behaviourally: it hosts the Haunt ambient tier for the hub. She murmurs, very
## occasionally, and only when the crew is calm — the HauntDirector's own withhold
## logic read the other way round. A crew that just got wiped and limped home does
## NOT get talked at. That is the mercy layer, applied to the one room the mercy
## layer is about.
##
## ## What it is careful about
##
## - **Host-authoritative.** Only the host picks a line and only the host decides
##   when; it goes out on the Director's existing `_speak` path, so nothing new is
##   on the wire and every peer sees the same words at the same time.
## - **Captions.** The line rides `Haunt.mother_spoke` exactly as her layer barks
##   do, so the subtitle track picks it up through the channel that already
##   respects "captions ship OFF by default" (DESIGN.md pillar 7).
## - **No flashing.** The optic breathes on a ~0.2 Hz envelope. That is two orders
##   of magnitude under the 3 Hz cap and is not a flash effect at all; it is
##   included in the hub selftest anyway, because a rate that is obviously safe
##   today is a rate somebody tunes tomorrow.

const HOUSING_COLOUR: Color = Color(0.34, 0.86, 1.0)
## Her resting glow: barely there. She is not lit up in here, she is *on*.
const IDLE_ENERGY: float = 0.22
## What it climbs to while she is speaking. Still low — this is an eye opening
## slightly, not a spotlight.
const SPEAK_ENERGY: float = 0.9
## The breath, in Hz. Sub-threshold by two orders of magnitude; see the header.
const BREATH_HZ: float = 0.2

## Seconds between the host's chances to murmur. Long: DESIGN.md says *rarely*,
## and the Partition is meant to be the quiet room.
const MURMUR_INTERVAL_MIN: float = 95.0
const MURMUR_INTERVAL_MAX: float = 180.0
## She holds off for this long after the crew arrives. Coming home should be
## silent — the debrief is talking, the pad is cooling, and she does not get the
## first word.
const MURMUR_GRACE: float = 40.0

var _optic_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _speak: float = 0.0
var _clock: float = 0.0
## Host-side pick sequence, on a literal seed under automation so a capture of the
## hub is the same capture twice.
var _rng: RandomNumberGenerator = null


static func create(where: Vector3) -> MotherLens:
	var lens: MotherLens = MotherLens.new()
	lens.name = "MotherLens"
	lens.position = where
	lens._assemble()
	return lens


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# Housing: hers, so it is flush, symmetrical and a little too large. The crew
	# have bolted nothing to it and put nothing near it.
	_add_mesh(Vector3(0.0, 0.0, 0.0), Vector3(3.4, 1.6, 0.35), casing)
	_add_mesh(Vector3(0.0, 0.86, 0.06), Vector3(3.8, 0.14, 0.28), casing)
	_add_mesh(Vector3(0.0, -0.86, 0.06), Vector3(3.8, 0.14, 0.28), casing)

	_optic_material = StandardMaterial3D.new()
	_optic_material.albedo_color = HOUSING_COLOUR.darkened(0.9)
	_optic_material.emission_enabled = true
	_optic_material.emission = HOUSING_COLOUR
	_optic_material.emission_energy_multiplier = IDLE_ENERGY
	_optic_material.roughness = 0.15
	_optic_material.disable_receive_shadows = true
	# A slot, not a circle. Every readable thing MOTHER owns in this game is a
	# rectangle of light; a round eye would be a different character.
	_add_mesh(Vector3(0.0, 0.0, 0.2), Vector3(2.6, 0.16, 0.05), _optic_material)
	for i: int in 5:
		_add_mesh(Vector3(-1.1 + float(i) * 0.55, 0.42, 0.2),
				Vector3(0.1, 0.04, 0.04), _optic_material)

	_light = OmniLight3D.new()
	_light.name = "LensGlow"
	_light.position = Vector3(0.0, 0.0, 1.0)
	_light.light_color = HOUSING_COLOUR
	_light.light_energy = IDLE_ENERGY
	_light.omni_range = 9.0
	_light.omni_attenuation = 0.9
	_light.light_volumetric_fog_energy = 2.0
	_light.shadow_enabled = false
	add_child(_light)


func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	# Same convention the HauntDirector uses for its own bark picker: fixed under
	# automation so a capture reproduces, rolled otherwise.
	if Debug.automated:
		_rng.seed = 20260803
	else:
		_rng.randomize()
	_clock = MURMUR_GRACE
	Haunt.mother_spoke.connect(_on_mother_spoke)


func _add_mesh(at: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	add_child(mesh)
	return mesh


## Every peer: the optic opens when she speaks, wherever the line came from.
func _on_mother_spoke(_text: String, _category: String, _tier: int,
		_callsign: bool) -> void:
	_speak = 1.0


func _process(delta: float) -> void:
	_speak = maxf(_speak - delta * 0.28, 0.0)
	# One slow breath, plus the speaking envelope on top. No flash term anywhere:
	# both of these are ramps, and the faster of the two is 0.2 Hz.
	var breath: float = 0.5 + 0.5 * sin(
			float(Time.get_ticks_msec()) / 1000.0 * TAU * BREATH_HZ)
	var energy: float = lerpf(IDLE_ENERGY * (0.75 + 0.25 * breath),
			SPEAK_ENERGY, _speak)
	_optic_material.emission_energy_multiplier = energy
	_light.light_energy = energy

	if not Run.in_hub:
		return
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return
	_clock -= delta
	if _clock > 0.0:
		return
	_clock = _rng.randf_range(MURMUR_INTERVAL_MIN, MURMUR_INTERVAL_MAX)
	_murmur()


## The host's chance to let her say something. Goes through the Director so the
## line, the caption and the once-ever bookkeeping (`mother_said_go_up`) are all
## the same machinery her layer barks use — a second bark path would be a second
## place to get the caption rules wrong.
func _murmur() -> void:
	if Run.injecting or Run.descending:
		return  # she does not talk over the crew committing.
	Haunt.speak_ambient()
