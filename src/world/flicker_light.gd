class_name FlickerLight
extends OmniLight3D
## A failing fixture. Mostly stable, with brownouts and the occasional full
## dropout — the dropout is the point, because it teaches the player not to trust
## anything on this layer except their own beam.
##
## M3.7 merged the look-dev kit's flicker vocabulary into this node: the mode
## curves below are the single source of truth (`FlickerLight.level()`), shared
## with `src/world/flicker.gd`, which drives the SpotLight3D keys and accents the
## LightRig places. This node keeps the game's own plumbing — a light that also
## dims the emissive housing it is bolted to.
##
## Everything here is **deterministic from `seed_offset`** rather than from a
## randomised phase. In a host-authoritative co-op game four clients must see the
## same fixture do the same thing without anybody replicating a float per frame;
## driving the offset from the shared run seed gets that for free. The old
## `_rng.randomize()` gave every peer a different brownout, which was invisible
## in a solo capture and wrong the moment two people looked down the same
## corridor.
##
## Artistic rule that outranks all of the above: **one dying fixture per room,
## maximum.** If everything flickers the eye adapts in about four seconds and the
## effect is gone.

enum Mode {
	STEADY,      ## no-op; here so a spec table can say STEADY explicitly
	BREATHE,     ## slow sine, healthy infrastructure idling
	DYING,       ## fluorescent on its last legs: long on, sudden dropouts
	ARC,         ## fast erratic electrical arcing, never fully off
	ALERT_PULSE, ## hard square pulse for the red-alert state
}

@export var mode: Mode = Mode.DYING
@export var base_energy: float = 1.0
@export var seed_offset: float = 0.0
@export var emissive_mesh: MeshInstance3D = null

var _t: float = 0.0
var _emissive_material: StandardMaterial3D = null


## The curves, as a pure function of (mode, time, seed). Static so the Node-based
## driver in flicker.gd runs exactly the same maths on a SpotLight3D.
static func level(which: Mode, t: float, offset: float) -> float:
	match which:
		Mode.STEADY:
			return 1.0
		Mode.BREATHE:
			return 0.86 + 0.14 * sin(t * 0.9 + offset)
		Mode.DYING:
			# Two dropout windows of different periods beating against each other:
			# the gap pattern never repeats on a rhythm the ear catches.
			var a: float = sin(t * 7.3 + offset)
			var b: float = sin(t * 2.17 + offset * 1.7)
			var alive: float = smoothstep(-0.55, -0.2, a * 0.6 + b * 0.4)
			var k: float = 0.08 + 0.92 * alive
			# One hard strobe per dropout as it re-strikes.
			if alive > 0.02 and alive < 0.25:
				k += 0.7 * float(int(t * 40.0) % 2)
			return k
		Mode.ARC:
			return 0.55 + 0.45 * absf(sin(t * 21.0 + sin(t * 6.1) * 2.0 + offset))
		Mode.ALERT_PULSE:
			var phase: float = fmod(t * 0.75 + offset, 1.0)
			return 0.15 + 0.85 * smoothstep(0.0, 0.08, phase) \
					* (1.0 - smoothstep(0.28, 0.42, phase))
	return 1.0


func _ready() -> void:
	if base_energy <= 0.0:
		base_energy = light_energy
	set_meta("base_energy", base_energy)
	_t = seed_offset
	if emissive_mesh != null:
		var source: StandardMaterial3D = emissive_mesh.material_override as StandardMaterial3D
		if source != null:
			_emissive_material = source.duplicate() as StandardMaterial3D
			emissive_mesh.material_override = _emissive_material


func _process(delta: float) -> void:
	_t += delta
	var k: float = FlickerLight.level(mode, _t, seed_offset)
	light_energy = float(get_meta("base_energy", base_energy)) * k
	# Nothing looks cheaper than a glowing housing that stays lit while the room
	# around it goes dark.
	if _emissive_material != null:
		_emissive_material.emission_energy_multiplier = maxf(k * 1.4, 0.02)
