class_name ViewModel
extends Node3D
## The breaker in your hands — the Surge, held in the lower-right of the frame.
##
## DESIGN.md calls the breaker "a short-range hitscan cutter — a tool, not a
## gun", and the viewmodel has to argue that: it sits low and slightly canted so
## it never becomes the subject of the shot, it does not reload, it does not
## bristle with attachments, and the only thing that lights up on it is the
## emitter, in the system's own teal, when it fires.
##
## ## Why it hangs off a lagged rig
##
## Pinning a viewmodel rigidly to the camera makes it feel weightless: it is the
## one object on screen that never moves relative to the eye, so the brain reads
## it as painted onto the lens. Everything here exists to break that — the model
## chases the camera's rotation a few frames behind (sway), leans against lateral
## movement, drifts on the walk cycle, and kicks back on every shot.
##
## Same trick, same reason, and the same constant family as `Player._update_beam`.
##
## ## What this is NOT
##
## It is not rendered through a separate viewport with its own near plane, which
## is the usual way to stop a viewmodel poking through a wall. That costs a
## second camera and a second render pass per player. At NULLVOID's held-low,
## short-barrel framing the intersection case is rare enough to defer, and it is
## noted as a known gap rather than pretended away.

## Where the weapon sits relative to the lens: right, low, and pushed forward
## enough to clear the near plane.
## Pushed back rather than in: the Surge is 0.86 m long, and held at a third of
## a metre it filled a quarter of the frame and ran off the right edge. Half a
## metre out it reads as carried without ever becoming the subject.
const REST_POSITION: Vector3 = Vector3(0.23, -0.20, -0.46)
## Canted inward and nose-down a touch, so it reads as held rather than mounted.
const REST_ROTATION: Vector3 = Vector3(-0.035, 0.065, 0.05)
## Viewmodel scale.
##
## The usual way to stop a held rifle swallowing the frame is a second camera at
## a narrower FOV. That is a whole extra render pass per player, so NULLVOID does
## what the other half of the industry does instead and shrinks the model: at the
## player's 74-degree FOV an 0.86 m weapon half a metre from the eye is taller
## than the screen, and no amount of repositioning fixes that — only scale does.
## 0.6 puts it at the same apparent size as a viewmodel shot through a 55-degree
## lens, which is the look this is imitating.
const MODEL_SCALE: float = 0.6

## How fast the model catches up with the lens. Lower is heavier.
const SWAY_LAG: float = 9.0
const SWAY_YAW: float = 0.055
const SWAY_PITCH: float = 0.04
## Lateral lean against strafing, and the drift the walk cycle puts into it.
const LEAN: float = 0.022
const BOB_SCALE: float = 0.6

## Recoil: an impulse backward and up, on a spring.
const RECOIL_KICK: float = 0.055
const RECOIL_RISE: float = 0.035
const RECOIL_RETURN: float = 15.0
const RECOIL_DAMP: float = 9.0

## Muzzle emitter, hot for this long after a shot.
const FLASH_TIME: float = 0.09

const BODY_COLOUR: Color = Color(0.048, 0.05, 0.058)
const TRIM_COLOUR: Color = Color(0.10, 0.11, 0.125)

var _model: Node3D = null
var _muzzle: Node3D = null
var _emitter_material: StandardMaterial3D = null
var _sight_material: StandardMaterial3D = null
var _flash_light: OmniLight3D = null

var _sway: Vector2 = Vector2.ZERO
var _recoil: float = 0.0
var _recoil_velocity: float = 0.0
var _flash: float = 0.0
var _last_yaw: float = 0.0
var _last_pitch: float = 0.0


## `tint` is the owning player's shell colour. The emitter takes a fraction of it
## so a crewmate's muzzle flash is recognisably theirs across a dark room,
## without the weapon itself stopping being NULLVOID-black.
static func create(tint: Color) -> ViewModel:
	var view: ViewModel = ViewModel.new()
	view.name = "ViewModel"
	view._build(tint)
	return view


func _build(tint: Color) -> void:
	_model = CreatureKit.instantiate(CreatureKit.SURGE)
	if _model == null:
		return
	add_child(_model)

	var accent: Color = Color(0.22, 0.86, 1.0).lerp(tint, 0.35)
	_emitter_material = CreatureKit.emissive(accent, 1.1, 0.82)
	# The sight plate.
	#
	# First pass made this unshaded and additive, on the theory that a holo sight
	# is a projection. In a game this dark that was a mistake at any alpha: an
	# unshaded additive quad is the one surface in the scene that does not go
	# out when the lights do, so in an unlit room the entire weapon vanished and
	# left a glowing cyan rectangle hanging in the middle of the frame like a UI
	# element that had escaped the HUD.
	#
	# It is dark glass now, lit by the room like everything else, with a whisper
	# of emission so it catches an angle. The Emiss slot is the weapon's only
	# real light source, which is how it should have been from the start.
	_sight_material = StandardMaterial3D.new()
	_sight_material.albedo_color = Color(0.03, 0.045, 0.055)
	_sight_material.metallic = 0.9
	_sight_material.roughness = 0.12
	_sight_material.emission_enabled = true
	_sight_material.emission = accent
	_sight_material.emission_energy_multiplier = 0.10
	_sight_material.disable_receive_shadows = true

	CreatureKit.paint(CreatureKit.find_mesh(_model), {
		# Matte black with a hair of metal. A properly metallic weapon returns
		# nothing at all to a head-mounted beam, which is the only light it will
		# ever be seen under.
		"Base": CreatureKit.matte(BODY_COLOUR, 0.25, 0.44),
		"Emiss": _emitter_material,
		"Material.001": _sight_material,
	})

	_muzzle = _model.find_child("Muzzle", true, false) as Node3D

	_flash_light = OmniLight3D.new()
	_flash_light.name = "MuzzleFlash"
	_flash_light.light_color = accent
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 5.5
	_flash_light.omni_attenuation = 1.3
	_flash_light.light_volumetric_fog_energy = 2.2
	_flash_light.shadow_enabled = false
	if _muzzle != null:
		_muzzle.add_child(_flash_light)
	else:
		add_child(_flash_light)

	position = REST_POSITION
	rotation = REST_ROTATION
	scale = Vector3.ONE * MODEL_SCALE


## World position of the emitter, which is where the beam-lash streak starts.
## Falls back to the rig's own origin so a missing model can never stop the
## breaker from drawing.
func muzzle_point() -> Vector3:
	if _muzzle != null and is_instance_valid(_muzzle):
		return _muzzle.global_position
	return global_position


## One shot fired: kick the spring and light the emitter.
func fire() -> void:
	_recoil_velocity += RECOIL_RETURN * RECOIL_KICK
	_flash = FLASH_TIME


## `look` is the lens's current (yaw, pitch); `lateral` is the strafe component
## of the owner's velocity in its own frame; `bob` is the head-bob phase offset
## already computed by the player, so the weapon and the camera agree.
func drive(delta: float, look: Vector2, lateral: float, bob: Vector3) -> void:
	# Sway: the difference between where the lens is now and where it was, eased
	# out. This is the whole feel of a held object in one line.
	var dyaw: float = wrapf(look.x - _last_yaw, -PI, PI)
	var dpitch: float = look.y - _last_pitch
	_last_yaw = look.x
	_last_pitch = look.y
	var blend: float = 1.0 - exp(-SWAY_LAG * delta)
	_sway = _sway.lerp(Vector2(clampf(dyaw / maxf(delta, 0.001) * 0.02, -1.0, 1.0),
			clampf(dpitch / maxf(delta, 0.001) * 0.02, -1.0, 1.0)), blend)

	# Recoil spring: critically-ish damped, so two shots in quick succession stack
	# rather than resetting each other.
	_recoil_velocity += (-_recoil * RECOIL_RETURN - _recoil_velocity * RECOIL_DAMP) * delta
	_recoil += _recoil_velocity * delta

	position = REST_POSITION + Vector3(
			-_sway.x * SWAY_YAW - lateral * LEAN + bob.x * BOB_SCALE,
			_sway.y * SWAY_PITCH + bob.y * BOB_SCALE + _recoil * RECOIL_RISE,
			_recoil * RECOIL_KICK * 2.0)
	rotation = REST_ROTATION + Vector3(
			_sway.y * 0.07 - _recoil * 0.5,
			_sway.x * 0.09,
			-_sway.x * 0.06)

	_flash = maxf(_flash - delta, 0.0)
	var heat: float = _flash / FLASH_TIME
	if _emitter_material != null:
		# Idles at a low glow — the tool is powered even when you are not cutting,
		# which is most of what stops it reading as a prop.
		_emitter_material.emission_energy_multiplier = 1.1 + heat * 9.0
	if _flash_light != null:
		_flash_light.light_energy = heat * 3.4
