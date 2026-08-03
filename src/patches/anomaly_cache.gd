class_name AnomalyCache
extends Interactable
## An ANOMALY CACHE — MOTHER's quarantine pod for code she could not classify,
## and the only reliable source of a KERNEL patch in the game.
##
## ## The fiction
##
## "QUARANTINE IS MERCY" is one of her own propaganda decals, and this is what
## she does with something she cannot delete and will not run: she seals it, logs
## it, and leaves it. The pod is HER architecture, not the crew's — matte black
## slab, hairline seam, containment ribs, a caged interior glow — which is the
## deliberate opposite of the pocket secretary standing three rooms away. One is a
## tool a person dropped; this is a box a machine welded shut.
##
## ## Why it is rare, guaranteed, and loud
##
## `Balance.PATCH_WEIGHTS_ANOMALY` is 70% KERNEL, and a KERNEL patch is
## build-defining. That is only healthy if it is *scheduled* rather than lucky:
## one cache every two or three layers (period and phase derived from the run
## seed, so it is the run's timetable rather than the game's), always somewhere
## the crew has to walk to, and cracking it rings a two-room bell — the same rung
## on the noise ladder a draining siphon sits on. You can always see the trade.
##
## ## The one thing it is allowed to do that nothing else is
##
## It GLOWS ACROSS A DARK ROOM. Pillar 2 says the dark is the enemy and the beam
## is the only thing that reveals a space, and every other lit prop in the game is
## disciplined to a pool at its own feet. This one is a beacon at
## `Balance.PATCH_CACHE_GLOW_ENERGY` over 7.5 m — because the whole point of a
## rare guaranteed prize is that the room tells you it is there, and because a
## thing that draws the crew's eye also draws them into a room they have not
## cleared. It lights itself and about two metres of deck. It does not light the
## room, and it never casts a shadow.

const SHELL: Color = Color(0.055, 0.058, 0.065)
const SEAM_LIVE: Color = Color(1.00, 0.86, 0.42)
const SEAM_SPENT: Color = Color(0.16, 0.20, 0.18)
const CORE_LIVE: Color = Color(1.00, 0.74, 0.30)

## The pod, in metres. Chest-high on purpose: tall enough to read as a container
## across a room, short enough that the crosshair finds it while you run.
const POD: Vector3 = Vector3(0.86, 1.12, 0.86)
const PLINTH: Vector3 = Vector3(1.06, 0.16, 1.06)
const RIBS: int = 3

var prop_index: int = 0

var _seam_material: StandardMaterial3D = null
var _core_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _lid: Node3D = null
var _channel: float = 0.0
var _open: float = 0.0
var _was_taken: bool = false


static func create(index: int, where: Vector3, yaw: float) -> AnomalyCache:
	var cache: AnomalyCache = AnomalyCache.new()
	cache.name = "AnomalyCache%d" % index
	cache.prop_index = index
	cache.position = where
	cache.rotation.y = yaw
	cache.channel_time = Balance.PATCH_CACHE_CHANNEL
	cache._assemble()
	return cache


func _assemble() -> void:
	var shell: StandardMaterial3D = StandardMaterial3D.new()
	shell.albedo_color = SHELL
	shell.roughness = 0.44
	shell.metallic = 0.55

	_box(Vector3(0.0, PLINTH.y * 0.5, 0.0), PLINTH, shell)
	_box(Vector3(0.0, PLINTH.y + POD.y * 0.5, 0.0), POD, shell)

	# Containment ribs: horizontal bands round the pod. They are what makes the
	# silhouette read as SEALED rather than as a crate, at the distance the glow
	# is visible from.
	for i: int in RIBS:
		var height: float = PLINTH.y + POD.y * (0.24 + 0.26 * float(i))
		_box(Vector3(0.0, height, 0.0),
				Vector3(POD.x + 0.05, 0.045, POD.z + 0.05), shell)

	# The seam: a hairline of light round the lid line, and a caged core behind a
	# slot on the front face. Two separate emissives so the lid can go dark while
	# the interior stays visible through the slot after it opens.
	_seam_material = _emissive(SEAM_LIVE, 2.6)
	_box(Vector3(0.0, PLINTH.y + POD.y - 0.14, 0.0),
			Vector3(POD.x + 0.012, 0.012, POD.z + 0.012), _seam_material)
	for side: int in 2:
		var x: float = (POD.x * 0.5 + 0.007) * (1.0 if side == 0 else -1.0)
		_box(Vector3(x, PLINTH.y + POD.y * 0.5, 0.0),
				Vector3(0.012, POD.y * 0.62, 0.012), _seam_material)

	_core_material = _emissive(CORE_LIVE, 3.4)
	_box(Vector3(0.0, PLINTH.y + POD.y * 0.52, POD.z * 0.5 + 0.004),
			Vector3(0.30, 0.11, 0.012), _core_material)

	# The lid, on its own pivot so cracking the pod actually opens it.
	_lid = Node3D.new()
	_lid.name = "Lid"
	_lid.position = Vector3(0.0, PLINTH.y + POD.y - 0.14, -POD.z * 0.5)
	add_child(_lid)
	var cap: MeshInstance3D = MeshInstance3D.new()
	var cap_box: BoxMesh = BoxMesh.new()
	cap_box.size = Vector3(POD.x, 0.14, POD.z)
	cap.mesh = cap_box
	cap.position = Vector3(0.0, 0.07, POD.z * 0.5)
	cap.material_override = shell
	_lid.add_child(cap)

	_light = OmniLight3D.new()
	_light.name = "CacheGlow"
	_light.position = Vector3(0.0, PLINTH.y + POD.y * 0.55, 0.0)
	_light.light_color = SEAM_LIVE
	_light.light_energy = Balance.PATCH_CACHE_GLOW_ENERGY
	_light.omni_range = Balance.PATCH_CACHE_GLOW_RANGE
	_light.omni_attenuation = 1.7
	# It writes into the fog, because a beacon in a hazy room should have a halo
	# — that is most of how it reads from the far side of a dark hall.
	_light.light_volumetric_fog_energy = 1.6
	# Never a shadow caster. See the class docstring: it lights itself, not a room.
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(POD.x + 0.5, POD.y + 0.5, POD.z + 0.5),
			Vector3(0.0, PLINTH.y + POD.y * 0.5, 0.0))


func _ready() -> void:
	add_to_group(Patches.GROUP_CACHE)
	if Patches.is_taken(Patches.KIND_CACHE, prop_index):
		_open = 1.0
		_go_spent()


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	if Patches.is_taken(Patches.KIND_CACHE, prop_index):
		return "CACHE BREACHED"
	return "HOLD E  ·  BREACH QUARANTINE  (LOUD)"


func prompt_title() -> String:
	if Patches.is_taken(Patches.KIND_CACHE, prop_index):
		return "CACHE BREACHED"
	return "ANOMALY CACHE"


func prompt_key() -> String:
	return "" if Patches.is_taken(Patches.KIND_CACHE, prop_index) else "E"


func prompt_glyph() -> String:
	return "◒"


func prompt_height() -> float:
	return PLINTH.y + POD.y + 0.55


func available() -> bool:
	return Run.local_running() and not Patches.is_taken(Patches.KIND_CACHE, prop_index)


func complete() -> void:
	Patches.request_pickup(Patches.KIND_CACHE, prop_index)


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


# ------------------------------------------------------------------ visuals --

func _process(delta: float) -> void:
	var spent: bool = Patches.is_taken(Patches.KIND_CACHE, prop_index)
	_open = move_toward(_open, 1.0 if spent else 0.0, delta * 1.4)
	# Eased: a heavy lid on a hydraulic hinge, and it hangs.
	var eased: float = 1.0 - pow(1.0 - _open, 3.0)
	_lid.rotation.x = -eased * deg_to_rad(58.0)

	if spent:
		if not _was_taken:
			Audio.play_3d(&"patch_cache_open", global_position)
			_go_spent()
		return

	# Sealed: a slow containment pulse. A 3.1 s cycle — well under 3 Hz by
	# construction — and scaled by the flash caps like every lit thing in the
	# game, so Reduced Flashing takes the breathing out and leaves the beacon.
	var beat: float = 0.78 + 0.22 * absf(sin(UiFx.clock() * 2.0)) * A11y.flash_scale
	var lit: float = beat + _channel * 1.8
	_seam_material.emission_energy_multiplier = 2.6 * lit
	_core_material.emission_energy_multiplier = 3.4 * lit
	_light.light_energy = Balance.PATCH_CACHE_GLOW_ENERGY * lit


## Breached. The pod stays standing with its lid hanging open and its seam dead —
## a room you have looted should look looted, and an empty cache is also a piece
## of information for a crewmate arriving late.
func _go_spent() -> void:
	_was_taken = true
	_seam_material.emission = SEAM_SPENT
	_seam_material.emission_energy_multiplier = 0.35
	_core_material.emission = SEAM_SPENT
	_core_material.emission_energy_multiplier = 0.2
	_light.light_color = SEAM_SPENT
	_light.light_energy = 0.18


# ------------------------------------------------------------------ helpers --

func _box(at: Vector3, size: Vector3, material: StandardMaterial3D) -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	add_child(mesh)


func _emissive(colour: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(0.72)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.38
	material.disable_receive_shadows = true
	return material
