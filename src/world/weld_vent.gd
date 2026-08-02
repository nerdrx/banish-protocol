class_name WeldVent
extends Interactable
## A grille the cleaners come through, and the two seconds of breaker that stop
## them.
##
## DESIGN.md's M4.8 line calls these "Scrubber ingress flavour points, sealable
## with the breaker", and the word doing the work is *ingress*. Before this
## milestone a nest was a room with creatures in it and no explanation of where
## they came from or why killing them all left it empty forever. Now a nest has
## holes in its walls, MOTHER trickles reinforcements through them
## (AntivirusDirector's trickle), and the crew can go and close them — which is
## the first time in the project that clearing a room is something you can make
## *stick*.
##
## Held with the trigger, not with E. That is a deliberate piece of language:
## the breaker is a cutting tool and this is the game's first use of it on the
## building rather than on the things in it. Two seconds is long enough that
## doing it inside an active nest is a real decision.
##
## Three states, all of them legible from across the room:
##   OPEN    slats dark, a hole behind them, cold air.
##   SHUT    driven closed by the junction's VENT FANS. Temporary — the slats
##           are down but there is no seam, and the readout counts.
##   WELDED  permanent. A glowing weld seam across the frame, cooling from white
##           through orange to a dull scar it keeps for the rest of the layer.

## The weld seam's colour as it cools. Cutting-torch white, then the orange of
## metal that is still too hot to touch, then the scar.
const WELD_HOT: Color = Color(1.0, 0.94, 0.78)
const WELD_WARM: Color = Color(1.0, 0.44, 0.12)
const WELD_COLD: Color = Color(0.42, 0.17, 0.08)
## How long the seam takes to cool once the weld lands.
const COOL_TIME: float = 6.0

const MOUNT_HEIGHT: float = 1.05
const WIDTH: float = 1.1
const HEIGHT: float = 0.86

var prop_index: int = 0
## The nest this vent feeds. Purely informational on the prop — the director
## reads the same number off the graph — but it is what the prompt says.
var nest_room: int = -1

var _slats: Array[MeshInstance3D] = []
var _slat_material: StandardMaterial3D = null
var _dark_material: StandardMaterial3D = null
var _seam: MeshInstance3D = null
var _seam_material: StandardMaterial3D = null
var _light: OmniLight3D = null
## 0..1 how far the cover has been driven shut by the fans.
var _shut: float = 0.0
## Seconds since the weld landed, for the cool-down.
var _cooled: float = 99.0
var _was_welded: bool = false
## The looping arc sound while the cutter is on it (M5), a child freed with the node.
var _weld_loop: AudioStreamPlayer3D = null


static func create(index: int, where: Vector3, yaw: float, room: int) -> WeldVent:
	var vent: WeldVent = WeldVent.new()
	vent.name = "WeldVent%d" % index
	vent.prop_index = index
	vent.nest_room = room
	vent.position = where
	vent.rotation.y = yaw
	vent.channel_time = 0.0
	vent._assemble()
	return vent


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# The hole first: a black recess behind the slats, so a beam that catches the
	# vent at an angle finds depth rather than a painted rectangle.
	_dark_material = StandardMaterial3D.new()
	_dark_material.albedo_color = Color(0.01, 0.012, 0.014)
	_dark_material.roughness = 1.0
	_dark_material.metallic = 0.0
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT, -0.06), Vector3(WIDTH - 0.16, HEIGHT - 0.14, 0.06),
			_dark_material)

	# Frame.
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT + HEIGHT * 0.5, 0.04),
			Vector3(WIDTH, 0.09, 0.14), casing)
	_add_mesh(Vector3(0.0, MOUNT_HEIGHT - HEIGHT * 0.5, 0.04),
			Vector3(WIDTH, 0.09, 0.14), casing)
	for side: float in [-1.0, 1.0]:
		_add_mesh(Vector3(side * (WIDTH * 0.5 - 0.045), MOUNT_HEIGHT, 0.04),
				Vector3(0.09, HEIGHT, 0.14), casing)
	# Four bolt heads. They are what make the frame read as *fixed to* the wall.
	for x: float in [-1.0, 1.0]:
		for y: float in [-1.0, 1.0]:
			_add_mesh(Vector3(x * (WIDTH * 0.5 - 0.045),
					MOUNT_HEIGHT + y * (HEIGHT * 0.5 - 0.02), 0.11),
					Vector3(0.05, 0.05, 0.03), casing)

	# Slats. Angled, so the light that gets past them is broken into bands, and
	# individually placed so the fan can drive them closed.
	_slat_material = StandardMaterial3D.new()
	_slat_material.albedo_color = Color(0.10, 0.11, 0.125)
	_slat_material.roughness = 0.55
	_slat_material.metallic = 0.55
	var count: int = 6
	for i: int in count:
		var t: float = (float(i) + 0.5) / float(count)
		var slat: MeshInstance3D = _add_mesh(
				Vector3(0.0, MOUNT_HEIGHT + lerpf(HEIGHT * 0.42, -HEIGHT * 0.42, t), 0.015),
				Vector3(WIDTH - 0.2, 0.085, 0.03), _slat_material)
		slat.rotation.x = deg_to_rad(-34.0)
		_slats.append(slat)

	# The weld seam, hidden until it exists. A single bar across the frame rather
	# than a bead round the whole rim: you welded it shut, you did not restore it.
	_seam_material = _emissive(WELD_COLD, 0.0)
	_seam = _add_mesh(Vector3(0.0, MOUNT_HEIGHT, 0.09),
			Vector3(WIDTH - 0.08, 0.055, 0.035), _seam_material)
	_seam.visible = false

	_light = OmniLight3D.new()
	_light.name = "WeldGlow"
	_light.position = Vector3(0.0, MOUNT_HEIGHT, 0.4)
	_light.light_color = WELD_WARM
	_light.light_energy = 0.0
	_light.omni_range = 4.5
	_light.omni_attenuation = 1.1
	_light.light_volumetric_fog_energy = 1.8
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(WIDTH + 0.3, HEIGHT + 0.4, 0.7), Vector3(0.0, MOUNT_HEIGHT, 0.15))


func _ready() -> void:
	add_to_group(Props.GROUP_VENT)
	if Props.is_welded(prop_index):
		_was_welded = true
		_cooled = COOL_TIME
	_shut = 1.0 if Props.is_vent_shut(prop_index) else 0.0


# ------------------------------------------------------------- interactable --

## Nothing to hold E on. The prompt still exists — it is the thing that teaches
## the player the vent can be dealt with at all — it just names the trigger.
func prompt() -> String:
	if Props.is_welded(prop_index):
		return "VENT WELDED"
	if Props.fans_remaining > 0.0:
		return "VENT DRIVEN SHUT  ·  %ds" % int(ceil(Props.fans_remaining))
	return "HOLD FIRE  ·  WELD VENT SHUT"


func prompt_title() -> String:
	if Props.is_welded(prop_index):
		return "VENT WELDED"
	if Props.fans_remaining > 0.0:
		return "FANS  ·  %ds" % int(ceil(Props.fans_remaining))
	return "WELD SHUT"


## The breaker glyph in the keycap ring, because the breaker is the key.
func prompt_key() -> String:
	return "" if Props.is_welded(prop_index) else "⌁"


func prompt_glyph() -> String:
	return "▤"


func prompt_height() -> float:
	return MOUNT_HEIGHT + HEIGHT * 0.5 + 0.55


func available() -> bool:
	return false  # E does nothing here; the trigger does.


## ...but the prompt is still a green light. See Interactable.prompt_ready.
func prompt_ready() -> bool:
	return burnable()


# --------------------------------------------------------------------- burn --

func burn_seconds() -> float:
	return Balance.VENT_WELD_TIME


func burnable() -> bool:
	return Run.local_running() and not Props.is_welded(prop_index)


func burn_complete() -> void:
	Props.request_weld(prop_index)


func set_burn_visual(fill: float) -> void:
	# The seam appears as you cut it, growing out from the middle. Before the weld
	# lands it is torch-white and it is the only thing lighting the vent.
	if Props.is_welded(prop_index):
		return
	_seam.visible = fill > 0.01
	_seam.scale.x = clampf(fill, 0.05, 1.0)
	_seam_material.emission = WELD_HOT
	_seam_material.emission_energy_multiplier = fill * 4.0
	_light.light_color = WELD_HOT
	_light.light_energy = fill * 2.6
	# The saturated arc while the cutter holds on it (M5). Local to the welder —
	# the burn only runs where the trigger is held; the completed seal below is
	# heard by everyone off the replicated state.
	if fill > 0.01 and _weld_loop == null:
		_weld_loop = Audio.attach_loop(&"weld_loop", self)
	elif fill <= 0.01 and _weld_loop != null:
		Audio.detach_loop(_weld_loop)
		_weld_loop = null


# ------------------------------------------------------------------ visuals --

func _process(delta: float) -> void:
	var welded: bool = Props.is_welded(prop_index)
	if welded and not _was_welded:
		_was_welded = true
		_cooled = 0.0
		# Sealed, on every peer (this edge reads the replicated Props state): arc
		# cut-out, cooling ticks, the confirm pips. Stop the welder's arc loop too.
		if _weld_loop != null:
			Audio.detach_loop(_weld_loop)
			_weld_loop = null
		Audio.play_3d(&"weld_complete", global_position)
	if welded:
		_cooled += delta

	# Slats drive closed for the fans and stay closed for a weld.
	var want: float = 1.0 if (welded or Props.fans_remaining > 0.0) else 0.0
	_shut = move_toward(_shut, want, delta * 3.0)
	for slat: MeshInstance3D in _slats:
		slat.rotation.x = deg_to_rad(lerpf(-34.0, -2.0, _shut))
		slat.scale.y = lerpf(1.0, 1.42, _shut)

	if not welded:
		if burn <= 0.0:
			_seam.visible = false
			_light.light_energy = move_toward(_light.light_energy, 0.0, delta * 4.0)
		return

	# Cooling. White for a moment, then orange, then a scar — and the light goes
	# out with it, so a welded vent is not a lamp you left on in a nest.
	_seam.visible = true
	_seam.scale.x = 1.0
	var t: float = clampf(_cooled / COOL_TIME, 0.0, 1.0)
	var colour: Color = WELD_HOT.lerp(WELD_WARM, minf(t * 2.4, 1.0)).lerp(
			WELD_COLD, clampf((t - 0.35) / 0.65, 0.0, 1.0))
	_seam_material.emission = colour
	_seam_material.emission_energy_multiplier = lerpf(3.6, 0.22, t)
	_light.light_color = colour
	_light.light_energy = lerpf(2.2, 0.0, minf(t * 1.3, 1.0))


func _add_mesh(at: Vector3, size: Vector3, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	add_child(mesh)
	return mesh


func _emissive(colour: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(0.7)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.4
	material.disable_receive_shadows = true
	return material
