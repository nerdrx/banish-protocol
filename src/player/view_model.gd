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
## ## Wall clipping
##
## Not solved with a separate viewport and its own near plane — the usual answer,
## and the wrong one here, because the *primary* first-person rig in this game is
## an embodied body (Player._embody) and this floating prop is only the fallback
## for a missing crew model. Two different anti-clipping techniques for the same
## weapon would be two different feels for the same button.
##
## So this wears the same weapon-collision tuck the avatar does: the owning
## Player probes ahead of the lens and hands both rigs a 0..1 crowding weight,
## and the hold springs down and back toward the chest. See
## `Player._update_weapon_tuck` for the probe and the argument.

## Where the weapon sits relative to the lens: right, low, and pushed forward
## enough to clear the near plane.
## Pushed back rather than in: the Surge is 0.86 m long, and held at a third of
## a metre it filled a quarter of the frame and ran off the right edge. Half a
## metre out it reads as carried without ever becoming the subject.
const REST_POSITION: Vector3 = Vector3(0.30, -0.245, -0.44)
## Canted inward and nose-down a touch, so it reads as held rather than mounted.
const REST_ROTATION: Vector3 = Vector3(-0.035, 0.120, 0.05)
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
## Peak energy of the light the muzzle throws into the room.
##
## M3.7 lit the emitter and gave the flash light 3.4 energy with no shadow, which
## in a room this dark is a soft teal bubble around your own hands. A cutter
## discharging should put one frame of hard structure on the wall next to you —
## so the light casts, reaches further, and rides a squared falloff so the decay
## reads as a discharge rather than as a dimmer.
const MUZZLE_FLASH_ENERGY: float = 2.6

## SAFETY-CRITICAL (limbo-a11y 01-photosensitivity). The breaker fires as fast as
## Balance.BREAKER_COOLDOWN allows — ~3.85 Hz at 0.26 s — which is OVER the WCAG
## 2.3.1 ceiling of three general flashes a second. The muzzle flash is a real
## world-casting light (until M4.95 `fire()` was never called, so this only became
## live this milestone), and a held trigger would strobe the room above the line.
##
## The governor guarantees at most one FULL room flash per this interval: >1/3 s,
## so <=3 Hz UNCONDITIONALLY, with Reduced Flashing OFF (the ship gate). A shot
## that lands inside the interval keeps its emitter glow and its lash — the shot
## still reads — but its room-casting light is gated off. Independently, the room
## light is scaled by A11y.flash_scale, so Reduced Flashing calms it toward 0.
const MUZZLE_FLASH_MIN_INTERVAL: float = 0.34

## Weapon collision: where the hold ends up when a wall is right in front of the
## lens. Down, back, and canted over — the same gesture the avatar's chest makes.
const TUCK_POSITION: Vector3 = Vector3(0.06, -0.19, 0.30)
const TUCK_ROTATION: Vector3 = Vector3(0.85, 0.22, 0.30)

const BODY_COLOUR: Color = Color(0.048, 0.05, 0.058)
const TRIM_COLOUR: Color = Color(0.10, 0.11, 0.125)

var _model: Node3D = null
var _muzzle: Node3D = null
var _emitter_material: StandardMaterial3D = null
var _sight_material: StandardMaterial3D = null
var _flash_light: OmniLight3D = null

var _sway: Vector2 = Vector2.ZERO
## 0..1 weapon-collision tuck, written by the owning Player once a frame.
var _tuck: float = 0.0
var _recoil: float = 0.0
var _recoil_velocity: float = 0.0
var _flash: float = 0.0
## Flash-rate governor state (see MUZZLE_FLASH_MIN_INTERVAL). `_since_full_flash`
## counts up in `drive`; `_room_gate` is 1 for a shot allowed a full room flash,
## 0 for one suppressed by the rate cap. Starts large so the first shot flashes.
var _since_full_flash: float = 10.0
var _room_gate: float = 0.0
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
	# Attenuation, not energy, is what was blowing the frame out.
	#
	# Godot's omni falloff is pow(distance, -attenuation), and this light lives
	# INSIDE the hand holding it — roughly 0.1 m from the mesh it is brightest
	# against. At the M3.7 attenuation of 1.3 that is a x20 near-field multiplier,
	# so a 3-energy flash delivered ~60 to the player's own knuckles, blew them to
	# paper, and the glow pass then spread that across the whole frame: firing in
	# a dark corridor whited out the corridor. A gentle 0.6 decay costs nothing at
	# range (a longer reach buys it back) and keeps the near field survivable.
	_flash_light.omni_range = 9.0
	_flash_light.omni_attenuation = 0.6
	_flash_light.light_volumetric_fog_energy = 2.6
	# Casting. One shadow map that is only ever rendered on the frames a shot is
	# in flight — the light sits at zero energy the rest of the time, and Godot
	# skips the atlas update for a light contributing nothing.
	_flash_light.shadow_enabled = true
	_flash_light.shadow_bias = 0.06
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


## Weapon collision, 0 = clear, 1 = pressed against a wall.
func set_tuck(amount: float) -> void:
	_tuck = clampf(amount, 0.0, 1.0)


## One shot fired: kick the spring and light the emitter.
func fire() -> void:
	_recoil_velocity += RECOIL_RETURN * RECOIL_KICK
	_flash = FLASH_TIME
	# Rate governor: only a shot at least MUZZLE_FLASH_MIN_INTERVAL after the last
	# full one gets a full ROOM flash. A too-soon shot still lights the emitter and
	# draws its lash below — it just does not throw a fresh light on the walls, so
	# a held trigger stays under the WCAG flash ceiling.
	if _since_full_flash >= MUZZLE_FLASH_MIN_INTERVAL:
		_room_gate = 1.0
		_since_full_flash = 0.0
	else:
		_room_gate = 0.0


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

	position = REST_POSITION + TUCK_POSITION * _tuck + Vector3(
			-_sway.x * SWAY_YAW - lateral * LEAN + bob.x * BOB_SCALE,
			_sway.y * SWAY_PITCH + bob.y * BOB_SCALE + _recoil * RECOIL_RISE,
			_recoil * RECOIL_KICK * 2.0)
	rotation = REST_ROTATION + TUCK_ROTATION * _tuck + Vector3(
			_sway.y * 0.07 - _recoil * 0.5,
			_sway.x * 0.09,
			-_sway.x * 0.06)

	_since_full_flash += delta
	_flash = maxf(_flash - delta, 0.0)
	var heat: float = _flash / FLASH_TIME
	if _emitter_material != null:
		# Idles at a low glow — the tool is powered even when you are not cutting,
		# which is most of what stops it reading as a prop.
		_emitter_material.emission_energy_multiplier = 1.1 + heat * 2.8
	if _flash_light != null:
		# The flash is a real light on the world as well as on the weapon: energy
		# well above the emitter's own glow, a short reach, and a heavy fog
		# contribution so a shot fired into a dark corridor puts one frame of
		# structure on the walls beside you. See CrewAvatar for the socketed twin.
		# Gated by the flash-rate governor (`_room_gate`, 0 on a too-soon shot) and
		# scaled by A11y.flash_scale — SAFETY-CRITICAL, see MUZZLE_FLASH_MIN_INTERVAL.
		_flash_light.light_energy = heat * heat * MUZZLE_FLASH_ENERGY \
				* _room_gate * A11y.flash_scale
