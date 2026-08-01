class_name DropShaft
extends Interactable
## The data trunk running deeper. Channel it with the whole crew stood inside and
## the layer below is written around you.
##
## DESIGN.md loop step 2: "fight/sneak through each procedurally generated layer
## to its drop shaft (a data trunk running deeper), then ride it down."
##
## The muster rule (every living crew member inside the shaft) is enforced by the
## host in Run — this node only reflects it, so a client cannot descend the crew
## by editing its own copy.

const RING_COUNT: int = 5
const READY_COLOUR: Color = Color(0.36, 0.9, 1.0)
const WAIT_COLOUR: Color = Color(1.0, 0.6, 0.24)

var _ring_material: StandardMaterial3D = null
var _column_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _rings: Array[MeshInstance3D] = []
var _channel: float = 0.0


static func create(where: Vector3) -> DropShaft:
	var shaft: DropShaft = DropShaft.new()
	shaft.name = "DropShaft"
	shaft.position = where
	shaft.channel_time = Balance.SHAFT_CHANNEL_TIME
	shaft._assemble()
	return shaft


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# A wide recessed pad rather than a hole: the crew has to stand *in* it, and
	# a hole in the floor would need collision surgery on the room slab.
	_add_mesh(Vector3(0.0, 0.06, 0.0), Vector3(6.4, 0.12, 6.4), casing)
	for corner: Vector3 in [Vector3(-2.9, 0.0, -2.9), Vector3(2.9, 0.0, -2.9),
			Vector3(-2.9, 0.0, 2.9), Vector3(2.9, 0.0, 2.9)]:
		_add_mesh(corner + Vector3(0.0, 1.9, 0.0), Vector3(0.4, 3.8, 0.4), casing)

	# The trunk itself: a column of light disappearing into the ceiling. This is
	# the only thing on a layer that points down the stack.
	_column_material = _hologram(READY_COLOUR, 0.1)
	# Back-face culling on an open additive tube: without it you see through to
	# the far wall of the cylinder and the column renders at double brightness,
	# which is what turns it from a shaft of light into a white slab.
	_column_material.cull_mode = BaseMaterial3D.CULL_BACK
	var column: MeshInstance3D = MeshInstance3D.new()
	var cylinder: CylinderMesh = CylinderMesh.new()
	cylinder.top_radius = 1.5
	cylinder.bottom_radius = 1.5
	cylinder.height = 7.0
	cylinder.radial_segments = 18
	cylinder.rings = 0
	cylinder.cap_top = false
	cylinder.cap_bottom = false
	column.mesh = cylinder
	column.position = Vector3(0.0, 3.5, 0.0)
	column.material_override = _column_material
	add_child(column)

	# Torus, not a plate. A filled quad reads as a slab of white and blows the
	# frame out through the glow pass; an annulus lets the room show through the
	# middle and stays a *ring of light climbing a shaft*.
	_ring_material = _emissive(READY_COLOUR, 0.8)
	for i: int in RING_COUNT:
		var ring: MeshInstance3D = MeshInstance3D.new()
		var torus: TorusMesh = TorusMesh.new()
		torus.inner_radius = 1.42
		torus.outer_radius = 1.58
		torus.rings = 24
		torus.ring_segments = 6
		ring.mesh = torus
		ring.position = Vector3(0.0, 0.35 + float(i) * 0.85, 0.0)
		ring.material_override = _ring_material
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(ring)
		_rings.append(ring)

	_light = OmniLight3D.new()
	_light.name = "ShaftGlow"
	_light.position = Vector3(0.0, 2.4, 0.0)
	_light.light_color = READY_COLOUR
	_light.light_energy = 1.9
	_light.omni_range = 15.0
	_light.omni_attenuation = 0.8
	_light.light_volumetric_fog_energy = 3.0
	_light.shadow_enabled = false
	add_child(_light)

	# Console on the pad edge — the thing you actually hold E on.
	_add_mesh(Vector3(0.0, 0.48, 2.7), Vector3(1.1, 0.95, 0.45), casing)
	_add_mesh(Vector3(0.0, 0.92, 2.52), Vector3(0.85, 0.05, 0.18), _ring_material)

	# The probe is the console, not the pad. A probe covering the whole pad would
	# be a volume the crew stands *inside*, and a ray cast from inside a shape
	# never reports it — you would be unable to interact with the thing you are
	# standing on.
	_add_probe(Vector3(2.0, 1.6, 1.0), Vector3(0.0, 0.85, 2.7))


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
	material.albedo_color = colour.darkened(0.6)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.5
	material.disable_receive_shadows = true
	return material


func _hologram(colour: Color, alpha: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(colour.r, colour.g, colour.b, alpha)
	material.disable_receive_shadows = true
	return material


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	if Run.descending:
		return "DESCENDING"
	# Nobody rides the trunk down while a crewmate is face down on the floor —
	# the layer above is about to stop existing, and so is anything left in it.
	if not Run.crew_intact():
		return "CREW CORRUPTED  ·  RESTORE THEM FIRST"
	if not Run.crew_mustered():
		return "CREW IN SHAFT  %d/%d" % [Run.muster_inside, Run.muster_total]
	return "HOLD E  ·  DESCEND TO LAYER %02d" % (Run.layer_number + 1)


func prompt_title() -> String:
	if Run.descending:
		return "DESCENDING"
	if not Run.crew_intact():
		return "CREW CORRUPTED"
	if not Run.crew_mustered():
		return "CREW IN SHAFT  %d/%d" % [Run.muster_inside, Run.muster_total]
	return "DROP SHAFT  ·  LAYER %02d" % (Run.layer_number + 1)


func prompt_glyph() -> String:
	return "▼"


## Over the console on the pad's +Z edge, where the probe is and where the crew
## stands to channel — not over the middle of the trunk, which they stand inside.
func prompt_anchor() -> Vector3:
	return Vector3(0.0, 2.2, 2.7)


func available() -> bool:
	return Run.crew_mustered() and Run.crew_intact() and not Run.descending


func complete() -> void:
	Run.request_descend()


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


func _process(_delta: float) -> void:
	var ready: bool = Run.crew_mustered()
	var colour: Color = READY_COLOUR if ready else WAIT_COLOUR
	_ring_material.emission = colour
	_light.light_color = colour
	_column_material.albedo_color = Color(colour.r, colour.g, colour.b,
			0.06 + _channel * 0.18)

	var t: float = float(Time.get_ticks_msec()) / 1000.0
	# The rings climb: idle they drift slowly upward, channelling they race.
	var speed: float = 0.6 + _channel * 5.0
	for i: int in _rings.size():
		var phase: float = fposmod(t * speed + float(i) / float(RING_COUNT), 1.0)
		_rings[i].position.y = 0.35 + phase * 4.2
		# Narrowing as they rise sells the trunk as a shaft receding upward.
		var shrink: float = 1.0 - phase * 0.4
		_rings[i].scale = Vector3(shrink, 1.0, shrink)
		# Fade in at the floor and out at the ceiling so nothing pops.
		_rings[i].visible = sin(phase * PI) > 0.12

	_ring_material.emission_energy_multiplier = (0.8 if ready else 0.55) * (1.0 + _channel * 1.4)
	_light.light_energy = (1.9 if ready else 1.2) * (1.0 + _channel * 1.0)
