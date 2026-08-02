class_name LootCabinet
extends Interactable
## A locked wall cabinet, and two ways to get into it.
##
## DESIGN.md's M4.8 line: "breaker-cut the lock (short focused burn, noisy) OR
## open silently if DOOR LOCKS is powered at the junction". That *or* is the
## whole prop — it is the first thing in the game that makes the rewire junction
## pay for itself, and it is the first loot in the game that has a stealth price
## attached to taking it.
##
##   CUT       hold the trigger on the lock plate for a second and a half. The
##             plate glows, the door swings, and the noise carries a room —
##             quieter than a siphon, louder than anything you can do by walking.
##   UNLOCK    hold E, silently, if a junction somewhere on the layer is feeding
##             the door locks. Costs nothing but the routing decision you already
##             made, which is exactly the shape a reward for planning should have.
##
## Inside: chips, spilled as a recoverable bundle (so opening one still costs you
## the walk over and a corrupted crewmate's spill and a cabinet's contents are
## the same object), and sometimes a flare. Contents are seeded content — a pure
## function of (run seed, layer, index) — so nothing about what was inside has to
## cross the wire.

const CASING_COLOUR: Color = Color(0.24, 0.78, 0.95)
const LOCK_LOCKED: Color = Color(1.0, 0.34, 0.26)
const LOCK_RELEASED: Color = Color(0.36, 1.0, 0.62)
const CUT_HOT: Color = Color(1.0, 0.92, 0.72)

const MOUNT_HEIGHT: float = 1.25
const WIDTH: float = 0.9
const HEIGHT: float = 1.5
const DEPTH: float = 0.34

var prop_index: int = 0

var _door: Node3D = null
var _lock_material: StandardMaterial3D = null
var _interior_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _channel: float = 0.0
## M5 audio: the arc loop while cutting (child, freed with the node) and a latch
## so the door creaks exactly once when it opens.
var _cut_loop: AudioStreamPlayer3D = null
var _was_open: bool = false
## 0..1 how far the door has swung.
var _swing: float = 0.0


static func create(index: int, where: Vector3, yaw: float) -> LootCabinet:
	var cabinet: LootCabinet = LootCabinet.new()
	cabinet.name = "LootCabinet%d" % index
	cabinet.prop_index = index
	cabinet.position = where
	cabinet.rotation.y = yaw
	cabinet.channel_time = Balance.CABINET_OPEN_TIME
	cabinet._assemble()
	return cabinet


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# Carcass: a shallow box let into the wall, with a lip round it.
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT, DEPTH * 0.5 - 0.02),
			Vector3(WIDTH, HEIGHT, DEPTH), casing)
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT + HEIGHT * 0.5 + 0.03, DEPTH * 0.5),
			Vector3(WIDTH + 0.1, 0.06, DEPTH + 0.04), casing)
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT - HEIGHT * 0.5 - 0.03, DEPTH * 0.5),
			Vector3(WIDTH + 0.1, 0.06, DEPTH + 0.04), casing)

	# The interior. Dark until the door is open, then a thin shelf glow — the
	# chips are in there, and the light is *coming off them*, which is why it only
	# exists once the door does.
	_interior_material = _emissive(Color(0.30, 0.95, 0.70), 0.0)
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT + 0.24, 0.08),
			Vector3(WIDTH - 0.22, 0.02, DEPTH - 0.14), _interior_material)
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT - 0.26, 0.08),
			Vector3(WIDTH - 0.22, 0.02, DEPTH - 0.14), _interior_material)

	# The door, hinged on its own pivot so it can actually swing.
	_door = Node3D.new()
	_door.name = "Door"
	_door.position = Vector3(-WIDTH * 0.5, MOUNT_HEIGHT, DEPTH - 0.02)
	add_child(_door)
	_group_box(_door, Vector3(WIDTH * 0.5, 0.0, 0.0),
			Vector3(WIDTH, HEIGHT, 0.06), casing)
	# Two ribs and a handle, so the door reads as a door edge-on.
	for y: float in [-0.4, 0.4]:
		_group_box(_door, Vector3(WIDTH * 0.5, y, 0.045),
				Vector3(WIDTH - 0.12, 0.05, 0.02), casing)
	_group_box(_door, Vector3(WIDTH - 0.14, 0.0, 0.06),
			Vector3(0.04, 0.26, 0.05), casing)

	# The lock plate. This is the thing you cut, so it is the only lit part of the
	# cabinet and it is exactly where the crosshair has to be.
	_lock_material = _emissive(LOCK_LOCKED, 0.9)
	_group_box(_door, Vector3(WIDTH - 0.2, -0.02, 0.055),
			Vector3(0.12, 0.12, 0.02), _lock_material)

	_light = OmniLight3D.new()
	_light.name = "CabinetGlow"
	_light.position = Vector3(0.0, MOUNT_HEIGHT, 0.5)
	_light.light_color = LOCK_LOCKED
	_light.light_energy = 0.28
	_light.omni_range = 4.0
	_light.omni_attenuation = 1.3
	_light.light_volumetric_fog_energy = 1.0
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(WIDTH + 0.4, HEIGHT + 0.3, 0.9), Vector3(0.0, MOUNT_HEIGHT, 0.25))


func _ready() -> void:
	add_to_group(Props.GROUP_CABINET)
	if Props.is_cabinet_open(prop_index):
		_swing = 1.0


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	if Props.is_cabinet_open(prop_index):
		return "CABINET EMPTY"
	if Props.locks_released():
		return "HOLD E  ·  OPEN CABINET"
	return "HOLD FIRE  ·  CUT LOCK  (LOUD)"


func prompt_title() -> String:
	if Props.is_cabinet_open(prop_index):
		return "CABINET EMPTY"
	if Props.locks_released():
		return "OPEN  ·  UNLOCKED"
	return "CUT LOCK"


func prompt_key() -> String:
	if Props.is_cabinet_open(prop_index):
		return ""
	return "E" if Props.locks_released() else "⌁"


func prompt_glyph() -> String:
	return "▥"


func prompt_height() -> float:
	return MOUNT_HEIGHT + HEIGHT * 0.5 + 0.5


## E only works while the junction is holding the locks open. Refusing here
## rather than in `burnable` is the right way round: the prompt still shows, and
## it still says what the alternative is.
func available() -> bool:
	return Run.local_running() and Props.locks_released() \
			and not Props.is_cabinet_open(prop_index)


## Green whichever way in you are taking. A locked cabinet is not a refusal, it
## is a cabinet you have not cut yet.
func prompt_ready() -> bool:
	return available() or burnable()


func complete() -> void:
	Props.request_cabinet(prop_index, false)


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


# --------------------------------------------------------------------- burn --

func burn_seconds() -> float:
	return Balance.CABINET_CUT_TIME


func burnable() -> bool:
	return Run.local_running() and not Props.is_cabinet_open(prop_index)


func burn_complete() -> void:
	Props.request_cabinet(prop_index, true)


func set_burn_visual(fill: float) -> void:
	if Props.is_cabinet_open(prop_index):
		return
	# The arc-and-rising-heat loop while the lock is being cut (M5). Local to the
	# cutter; the creak when the door actually swings is on every peer (below).
	if fill > 0.01 and _cut_loop == null:
		_cut_loop = Audio.attach_loop(&"cabinet_cut", self)
	elif fill <= 0.01 and _cut_loop != null:
		Audio.detach_loop(_cut_loop)
		_cut_loop = null
	_lock_material.emission = LOCK_LOCKED.lerp(CUT_HOT, fill)
	_lock_material.emission_energy_multiplier = 0.9 + fill * 5.0
	_light.light_color = LOCK_LOCKED.lerp(CUT_HOT, fill)
	_light.light_energy = 0.28 + fill * 2.4


# ------------------------------------------------------------------ visuals --

func _process(delta: float) -> void:
	var open: bool = Props.is_cabinet_open(prop_index)
	# The stick-slip creak as the door swings, once, when it first opens — on every
	# peer, off the replicated Props state. Stop any cutter's arc loop with it.
	if open and not _was_open:
		_was_open = true
		if _cut_loop != null:
			Audio.detach_loop(_cut_loop)
			_cut_loop = null
		Audio.play_3d(&"cabinet_creak", global_position)
	_swing = move_toward(_swing, 1.0 if open else 0.0, delta * 2.6)
	# Eased, and it overshoots a hair: a heavy door on a spring hinge.
	var eased: float = 1.0 - pow(1.0 - _swing, 3.0)
	_door.rotation.y = -eased * deg_to_rad(104.0)

	_interior_material.emission_energy_multiplier = eased * 0.55

	if open:
		_lock_material.emission = LOCK_RELEASED
		_lock_material.emission_energy_multiplier = 0.2
		_light.light_color = Color(0.30, 0.95, 0.70)
		_light.light_energy = eased * 0.6
		return
	if burn > 0.0:
		return  # the burn visual owns the lock while it is being cut.

	var t: float = UiFx.clock()
	var released: bool = Props.locks_released()
	var colour: Color = LOCK_RELEASED if released else LOCK_LOCKED
	# Locked: a slow red pulse. Released: steady green. One of those is an
	# invitation and the other is a dare, and the crew should be able to tell at
	# fifteen metres which one this cabinet currently is.
	var beat: float = 1.0 if released else (0.55 + 0.45 * absf(sin(t * 1.5)))
	_lock_material.emission = colour
	_lock_material.emission_energy_multiplier = (0.9 + _channel * 2.0) * beat
	_light.light_color = colour
	_light.light_energy = (0.28 + _channel * 1.2) * beat


# ------------------------------------------------------------------ helpers --

func _add_mesh(at: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	add_child(mesh)
	return mesh


func _group_box(group: Node3D, at: Vector3, size: Vector3,
		material: StandardMaterial3D) -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	group.add_child(mesh)


func _emissive(colour: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(0.66)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.42
	material.disable_receive_shadows = true
	return material
