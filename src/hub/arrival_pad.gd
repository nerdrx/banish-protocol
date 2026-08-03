class_name ArrivalPad
extends Node3D
## Where a crew comes home, and where the haul is visibly put down.
##
## The exfil uplink out in the layers is the *departure*; this is the other end of
## the same cable. A crew that banked something arrives on a pad that is still
## warm from the transfer, and a crew that got wiped arrives on a dead one — which
## is the whole bank ritual, done as a place rather than as a toast.
##
## It is presentation only. Nothing here decides anything: the banking happened in
## `Run._fire_exfil` and `GameState.bank` before the crew started walking home, and
## every peer reads the same replicated summary to know which of the two states to
## show. That split matters — an arrival pad that owned the bank would be a second
## place money could be created, on the client.
##
## Not an Interactable. There is nothing to hold here; it is a floor that tells you
## how the run went while you walk off it.

## Seconds the pad stays hot after the crew lands. The debrief is up for most of
## it, so the first thing you see when you dismiss the summary is the pad still
## cooling — the transfer finishing behind you rather than having been a screen.
const SETTLE_TIME: float = 12.0

const BANKED_COLOUR: Color = Color(0.42, 0.98, 0.72)
const EMPTY_COLOUR: Color = Color(0.5, 0.56, 0.62)
const IDLE_COLOUR: Color = Color(1.0, 0.66, 0.28)

## SAFETY LAW (DESIGN.md pillar 7). The arrival shimmer is a single decaying
## envelope with ONE slow sine on it, well under the 3 Hz WCAG ceiling, and the
## amplitude rides `A11y.flash_scale` so Reduced Flashing turns it into a steady
## fade. Asserted by the hub selftest, not promised here.
const SETTLE_PULSE_HZ: float = 1.2

var _ring_material: StandardMaterial3D = null
var _light: OmniLight3D = null
## Counts down from SETTLE_TIME after an arrival; <= 0 is the resting pad.
var _settle: float = 0.0
## What the last run did, for the colour of the settle. Read off the replicated
## summary on every peer, so four screens agree.
var _banked: bool = false


static func create(where: Vector3) -> ArrivalPad:
	var pad: ArrivalPad = ArrivalPad.new()
	pad.name = "ArrivalPad"
	pad.position = where
	pad._assemble()
	return pad


func _assemble() -> void:
	# The transfer ring, inset into the plinth the builder laid: a flat annulus,
	# not a disc. A filled quad at this size blows out through the glow pass and
	# turns the floor into a light source, which is the exact thing DESIGN.md's
	# data-chip note calls out as the failure mode ("never a glowing volume").
	_ring_material = StandardMaterial3D.new()
	_ring_material.albedo_color = IDLE_COLOUR.darkened(0.7)
	_ring_material.emission_enabled = true
	_ring_material.emission = IDLE_COLOUR
	_ring_material.emission_energy_multiplier = 0.35
	_ring_material.roughness = 0.4
	_ring_material.disable_receive_shadows = true

	var ring: MeshInstance3D = MeshInstance3D.new()
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 3.3
	torus.outer_radius = 3.55
	torus.rings = 40
	torus.ring_segments = 6
	ring.mesh = torus
	ring.position = Vector3(0.0, 0.2, 0.0)
	ring.material_override = _ring_material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)

	_light = OmniLight3D.new()
	_light.name = "ArrivalGlow"
	_light.position = Vector3(0.0, 0.55, 0.0)
	_light.light_color = IDLE_COLOUR
	_light.light_energy = 0.5
	_light.omni_range = 8.0
	_light.omni_attenuation = 0.85
	_light.light_volumetric_fog_energy = 1.4
	_light.shadow_enabled = false
	add_child(_light)


func _ready() -> void:
	add_to_group("arrival_pads")
	# The pad is rebuilt with the hub, so it is standing at the moment the crew
	# lands rather than subscribing before them: read the summary the run that just
	# ended left behind, and light accordingly. `Run.run_ended` has already fired
	# by the time this node exists — it fired in the LAYER, one fade ago — which is
	# why this is a poll of settled state and not a signal connection.
	_adopt_last_run()


func _adopt_last_run() -> void:
	if not Run.in_hub:
		return
	var mine: int = Run.last_banked
	if Run.last_run_success:
		_settle = SETTLE_TIME
		_banked = mine > 0
	elif Run.last_run_reason != "":
		# A wipe still lands somebody here. The pad runs its dead colour, briefly.
		_settle = SETTLE_TIME * 0.5
		_banked = false


func _process(delta: float) -> void:
	if _settle <= 0.0:
		_ring_material.emission = IDLE_COLOUR
		_ring_material.emission_energy_multiplier = 0.35
		_light.light_color = IDLE_COLOUR
		_light.light_energy = 0.5
		return

	_settle = maxf(_settle - delta, 0.0)
	var fade: float = clampf(_settle / SETTLE_TIME, 0.0, 1.0)
	var colour: Color = BANKED_COLOUR if _banked else EMPTY_COLOUR
	# One slow sine under a decaying envelope, amplitude gated by the A11y cap.
	var swing: float = 0.3 * A11y.flash_scale
	var beat: float = 1.0 + swing * sin(
			float(Time.get_ticks_msec()) / 1000.0 * TAU * SETTLE_PULSE_HZ)
	_ring_material.emission = colour
	_ring_material.emission_energy_multiplier = (0.35 + fade * 1.1) * beat
	_light.light_color = colour
	_light.light_energy = (0.5 + fade * 1.6) * beat
