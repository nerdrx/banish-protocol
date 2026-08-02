class_name SiphonTap
extends Interactable
## A dormant junction the crew can bleed compute out of.
##
## DESIGN.md: "tapping one (short channel, loud — pings the antivirus) refills a
## chunk of the pool". M2 ships the channel, the refill and the pulse; the ping
## is left as `antivirus_ping` for M3 to connect to the AI's trace state.
##
## Built entirely from code so the procedural generator can place one anywhere
## without a scene dependency, and so the emissive materials are per-instance
## (a spent tap must go dark without dimming every other tap on the layer).

## Emitted on every peer when this tap is drained.
##
## M3 wired this straight to the antivirus director. M4.8 moved the fan-out into
## the `Noise` autoload — five things in the layer are loud now, and M6's Hound is
## specified as spawned by noise debt — so the director listens to `NoiseBus.heard`
## instead and this signal is kept for anything that wants to know specifically
## that *a siphon* went off. Not a rename, not a removal: a stable API with one
## fewer listener.
signal antivirus_ping(where: Vector3)

const LIVE_COLOUR: Color = Color(0.34, 1.0, 0.78)
const SPENT_COLOUR: Color = Color(0.22, 0.26, 0.3)
const PULSE_TIME: float = 1.4

var tap_index: int = 0
var spent: bool = false

var _core: MeshInstance3D = null
var _core_material: StandardMaterial3D = null
var _rings: Array[MeshInstance3D] = []
var _ring_material: StandardMaterial3D = null
var _light: OmniLight3D = null
var _pulse: float = 0.0
## A draining tap is meant to be loud — DESIGN.md has it pinging the antivirus —
## but not loud enough to light the whole room and undo the layer's darkness.
var _base_energy: float = 2.4
var _channel: float = 0.0
## The looping channel sound while a draw is in progress on this peer (M5).
var _channel_loop: AudioStreamPlayer3D = null


## Assembles a tap at `where`, facing `yaw`. The node is returned unparented so
## the builder controls when it enters the tree.
static func create(index: int, where: Vector3, yaw: float) -> SiphonTap:
	var tap: SiphonTap = SiphonTap.new()
	tap.name = "SiphonTap%d" % index
	tap.tap_index = index
	tap.position = where
	tap.rotation.y = yaw
	tap.channel_time = Balance.SIPHON_CHANNEL_TIME
	tap._assemble()
	return tap


func _assemble() -> void:
	var casing: StandardMaterial3D = preload("res://assets/materials/conduit.tres")

	# Plinth and cowl: heavy machinery, so the glowing core reads as contained
	# rather than floating.
	_add_mesh(Vector3(0.0, 0.18, 0.0), Vector3(2.0, 0.36, 2.0), casing)
	_add_mesh(Vector3(0.0, 1.05, 0.0), Vector3(1.15, 1.4, 1.15), casing)
	_add_mesh(Vector3(0.0, 2.32, 0.0), Vector3(1.6, 0.22, 1.6), casing)
	for corner: Vector3 in [Vector3(-0.72, 0.0, -0.72), Vector3(0.72, 0.0, -0.72),
			Vector3(-0.72, 0.0, 0.72), Vector3(0.72, 0.0, 0.72)]:
		_add_mesh(corner + Vector3(0.0, 1.2, 0.0), Vector3(0.16, 2.1, 0.16), casing)

	_core_material = _emissive(LIVE_COLOUR, 1.9)
	_core = _add_mesh(Vector3(0.0, 1.15, 0.0), Vector3(0.72, 1.0, 0.72), _core_material)

	# Three stacked bands. They are the charge readout during a channel: the
	# player watches the machine, not just the HUD ring.
	_ring_material = _emissive(LIVE_COLOUR, 1.3)
	for i: int in 3:
		_rings.append(_add_mesh(Vector3(0.0, 0.72 + float(i) * 0.42, 0.0),
				Vector3(1.28, 0.05, 1.28), _ring_material))

	_light = OmniLight3D.new()
	_light.name = "TapGlow"
	_light.position = Vector3(0.0, 1.5, 0.0)
	_light.light_color = LIVE_COLOUR
	_light.light_energy = _base_energy
	_light.omni_range = 13.0
	_light.omni_attenuation = 0.85
	_light.light_volumetric_fog_energy = 2.2
	_light.shadow_enabled = false
	add_child(_light)

	_add_probe(Vector3(2.2, 2.6, 2.2), Vector3(0.0, 1.3, 0.0))


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


func _ready() -> void:
	Run.siphon_taken.connect(_on_siphon_taken)
	# Rejoining or rebuilding mid-layer must not resurrect a drained tap.
	if Run.is_siphon_spent(tap_index):
		_apply_spent()


# ------------------------------------------------------------- interactable --

func prompt() -> String:
	if spent:
		return "TAP DRAINED"
	return "HOLD E  ·  SIPHON TAP"


func prompt_title() -> String:
	return "TAP DRAINED" if spent else "SIPHON TAP"


func prompt_glyph() -> String:
	return "◆"


## Clear of the cowl, which tops out at 2.43.
func prompt_height() -> float:
	return 3.0


func available() -> bool:
	return not spent


func complete() -> void:
	Run.request_siphon(tap_index)


func set_channel_visual(progress: float) -> void:
	_channel = clampf(progress, 0.0, 1.0)
	# The channel loop — valve breathing, and the noise that pings the antivirus.
	# Its caption is THREAT ("pinging hunters"), the crew's own risk made legible.
	# Started when a draw begins on this peer and stopped when it releases; the
	# host validating the tap is a separate, replicated event (the surge below).
	if _channel > 0.001 and _channel_loop == null and not spent:
		_channel_loop = Audio.attach_loop(&"siphon_channel", self)
	elif _channel <= 0.001 and _channel_loop != null:
		Audio.detach_loop(_channel_loop)
		_channel_loop = null


func _process(delta: float) -> void:
	if _pulse > 0.0:
		_pulse = maxf(_pulse - delta / PULSE_TIME, 0.0)

	if spent:
		# One long decay after the pulse, then dead metal.
		var fade: float = _pulse * _pulse
		_light.light_energy = _base_energy * 2.2 * fade
		_core_material.emission_energy_multiplier = 0.06 + fade * 3.0
		_ring_material.emission_energy_multiplier = 0.04 + fade * 2.0
		return

	# Idle breathing, plus a hard ramp while someone is drawing on it.
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	var idle: float = 0.86 + sin(t * 1.7) * 0.14
	# The emissive core ramps harder than the light: the machine visibly strains
	# without the room's exposure lifting with it.
	var charge: float = 1.0 + _channel * 1.3
	_light.light_energy = _base_energy * idle * charge
	_core_material.emission_energy_multiplier = 1.9 * idle * (1.0 + _channel * 2.6)
	_ring_material.emission_energy_multiplier = 1.3 * idle

	# Bands light bottom-up as the channel fills.
	for i: int in _rings.size():
		var threshold: float = (float(i) + 0.5) / float(_rings.size())
		_rings[i].visible = _channel <= 0.001 or _channel >= threshold


func _on_siphon_taken(index: int, _pool: float) -> void:
	if index != tap_index or spent:
		return
	_pulse = 1.0
	_apply_spent()
	antivirus_ping.emit(global_position)
	# The loudest thing in the game, and the reference every other noise in
	# Balance's ladder is set against.
	NoiseBus.ping(global_position, Balance.TAP_ALERT_ROOMS, "siphon",
			Balance.TAP_ALERT_TIME)
	# The channel is done; stop its loop and fire the surge — the loudest good
	# news in the game. Runs on every peer (`_on_siphon_taken` off the replicated
	# `_apply_siphon`), so the whole crew hears the pool refill.
	if _channel_loop != null:
		Audio.detach_loop(_channel_loop)
		_channel_loop = null
	Audio.play_3d(&"siphon_surge", global_position)


func _apply_spent() -> void:
	spent = true
	_channel = 0.0
	_core_material.emission = SPENT_COLOUR
	_ring_material.emission = SPENT_COLOUR
	# SPENT, not LIVE. A drained tap kept the live hue in its light while its own
	# materials went dark, so the one fixture a player looks at to answer "has
	# this been worked?" disagreed with the rest of the prop as it faded out.
	_light.light_color = SPENT_COLOUR
	for ring: MeshInstance3D in _rings:
		ring.visible = true
