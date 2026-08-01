class_name ExfilUplink
extends Interactable
## The way out. Channel it once the backdoor is rooted and the crew has twenty
## seconds to be standing on the pad.
##
## DESIGN.md loop step 4: "upload out (bank all buffered data) or descend toward
## the next node". Everyone on the pad when it fires banks their buffer and the
## run ends successfully; everyone else is left inside MOTHER with the uplink
## closed behind them, which is exactly as harsh as the pillar wants.
##
## The countdown itself is Run's (host-authoritative, replicated). This node is
## the pad, the light and the klaxon.

const IDLE_COLOUR: Color = Color(0.36, 0.9, 1.0)
const LOCKED_COLOUR: Color = Color(0.34, 0.4, 0.48)
const ALARM_COLOUR: Color = Color(1.0, 0.5, 0.22)
const RING_SEGMENTS: int = 12

var _pad_material: StandardMaterial3D = null
var _ring_material: StandardMaterial3D = null
var _column_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _channel: float = 0.0


static func create(where: Vector3) -> ExfilUplink:
	var uplink: ExfilUplink = ExfilUplink.new()
	uplink.name = "ExfilUplink"
	uplink.position = where
	uplink.channel_time = Balance.EXFIL_CHANNEL_TIME
	uplink._assemble()
	return uplink


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")
	var radius: float = Balance.EXFIL_PAD_RADIUS

	# A recessed pad the crew stands *in*, sized to the rule the host enforces —
	# "on the pad" has to be something you can see, not a number.
	_pad_material = _emissive(IDLE_COLOUR, 0.25)
	_add_mesh(Vector3(0.0, 0.05, 0.0), Vector3(radius * 2.0, 0.1, radius * 2.0), casing)
	_add_mesh(Vector3(0.0, 0.11, 0.0), Vector3(radius * 1.82, 0.02, radius * 1.82),
			_pad_material)

	# Perimeter markers rather than a solid rim: the pad edge stays legible from
	# inside it, where a player standing on the pad is actually looking.
	_ring_material = _emissive(IDLE_COLOUR, 0.9)
	for i: int in RING_SEGMENTS:
		var angle: float = TAU * float(i) / float(RING_SEGMENTS)
		var at: Vector3 = Vector3(cos(angle), 0.0, sin(angle)) * radius
		var post: MeshInstance3D = _add_mesh(at + Vector3(0.0, 0.3, 0.0),
				Vector3(0.16, 0.6, 0.16), _ring_material)
		post.rotation.y = -angle

	# The uplink beam: a column of light going *up*, the only thing on a layer
	# that points out of the system rather than deeper into it.
	_column_material = _hologram(IDLE_COLOUR, 0.07)
	_column_material.cull_mode = BaseMaterial3D.CULL_BACK
	var column: MeshInstance3D = MeshInstance3D.new()
	var cylinder: CylinderMesh = CylinderMesh.new()
	cylinder.top_radius = radius * 0.62
	cylinder.bottom_radius = radius * 0.34
	cylinder.height = 9.0
	cylinder.radial_segments = 20
	cylinder.rings = 0
	cylinder.cap_top = false
	cylinder.cap_bottom = false
	column.mesh = cylinder
	column.position = Vector3(0.0, 4.5, 0.0)
	column.material_override = _column_material
	column.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(column)

	_light = OmniLight3D.new()
	_light.name = "UplinkGlow"
	_light.position = Vector3(0.0, 2.6, 0.0)
	_light.light_color = IDLE_COLOUR
	_light.light_energy = 1.6
	_light.omni_range = 18.0
	_light.omni_attenuation = 0.8
	_light.light_volumetric_fog_energy = 3.0
	_light.shadow_enabled = false
	add_child(_light)

	# Console on the pad edge, for the same reason the drop shaft has one: a probe
	# covering the pad would be a volume you stand inside and could never ray-hit.
	_add_mesh(Vector3(0.0, 0.5, radius - 0.4), Vector3(1.2, 1.0, 0.5), casing)
	_add_mesh(Vector3(0.0, 0.96, radius - 0.62), Vector3(0.9, 0.05, 0.2), _ring_material)
	_add_probe(Vector3(2.2, 2.0, 1.2), Vector3(0.0, 1.0, radius - 0.4))


func _ready() -> void:
	add_to_group("exfil_uplinks")


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
	if Run.exfil_calling:
		return "EXFILTRATION IN %d  ·  STAND ON THE PAD" % int(ceilf(Run.exfil_remaining))
	if not Run.backdoor_rooted:
		return "UPLINK LOCKED  ·  ROOT THE NODE"
	return "HOLD E  ·  CALL EXFILTRATION"


func available() -> bool:
	return Run.backdoor_rooted and not Run.exfil_calling


func complete() -> void:
	Run.request_exfil()


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)


func _process(_delta: float) -> void:
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var colour: Color = IDLE_COLOUR if Run.backdoor_rooted else LOCKED_COLOUR
	var energy: float = (1.6 if Run.backdoor_rooted else 0.6) * (1.0 + _channel * 1.4)
	var alpha: float = 0.07 + _channel * 0.14

	if Run.exfil_calling:
		# Klaxon: a hard two-beat pulse that tightens as the window closes, so the
		# room itself is the countdown even if you are not looking at the HUD.
		var urgency: float = 1.0 - clampf(Run.exfil_remaining / Balance.EXFIL_COUNTDOWN, 0.0, 1.0)
		var beat: float = absf(sin(t * (3.0 + urgency * 6.0)))
		colour = ALARM_COLOUR
		energy = 1.2 + beat * (4.0 + urgency * 6.0)
		alpha = 0.1 + beat * 0.22

	_pad_material.emission = colour
	_pad_material.emission_energy_multiplier = 0.25 + (energy * 0.14)
	_ring_material.emission = colour
	_ring_material.emission_energy_multiplier = 0.9 + (energy * 0.3)
	_column_material.albedo_color = Color(colour.r, colour.g, colour.b, alpha)
	_light.light_color = colour
	_light.light_energy = energy
