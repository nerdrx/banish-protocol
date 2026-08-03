class_name DustAir
extends Node3D
## THE AIR — suspended dust, and the haze it is suspended in.
##
## The user's note on the Isolation references was one sentence: *"as if the air
## was dusty."* Both reference frames are carried by it. In the medbay the
## tripod light is only a tripod light because you can see the cone; in the comms
## room the monitors only bleed green across the desk because the air between
## them and the desk is doing something. Remove the air from either frame and you
## have a lit room instead of a photographed one.
##
## THIS FILE IS THREE THINGS, AND THEY ARE THE SAME IDEA AT THREE SCALES
##
##   1. THE DUST BOX (`attach`). A sparse GPUParticles3D volume that FOLLOWS THE
##      CAMERA, so a few hundred motes cover a whole layer instead of the tens of
##      thousands a static field would need. The motes are dark until light finds
##      them — see nv_dust_mote.gdshader, which is where the actual idea lives.
##   2. ROOM HAZE (`room_haze`). Per-archetype fog density, because how much is
##      in the air is a property of what happens in the room. A machine hall is
##      hazy. A nest is filthy. A sanctuary is a place somebody swept.
##   3. SOURCE PLUMES (`source_plume`). Small local FogVolumes at the things dust
##      COMES FROM: an open vent, a running machine. The motivation law applied
##      to atmosphere — haze that is thickest nowhere in particular is weather,
##      and a sealed machine-space does not have weather.
##
## THE DARKNESS GUARD
## Denser air is the single easiest way to accidentally end this game. Fog with
## emission, or fog taking an ambient inject, raises the floor of every pixel it
## covers: crank the density and the blacks turn grey, the player can navigate
## without a beam, and pillar 2 is gone. So:
##
##   * every volume this file creates has ZERO emission and ZERO ambient inject;
##   * the GLOBAL density ramp is small (`layer_fog_density` moves 0.030 by at
##     most ±25% across sixteen layers);
##   * the per-room deltas are RELATIVE and mostly SUBTRACTIVE — a sanctuary is
##     cleaner than baseline rather than a bus hall being fogged over;
##   * the motes have `ambient_light_disabled` and no emission at all.
##
## The A/B that proves it is the ambush-readability pair: same enemy, same room,
## fog on and off, at BASELINE and CINEMA. If a Scrubber standing in the dark is
## easier to see with the air on, the air is wrong.

const MOTE_SHADER: String = "res://src/shaders/nv_dust_mote.gdshader"

## The box the motes live in, centred on the camera. Wide enough that the edge is
## never in frame at a 75-degree FOV, short enough that a mote is never spawned
## above the ceiling of a single-storey room.
const BOX: Vector3 = Vector3(11.0, 4.2, 11.0)
## Motes at full density. Deliberately SPARSE: real air has almost nothing in it,
## and the tell of fake dust is that there is enough of it to see a pattern in.
## The number that matters is not the count, it is that they are invisible
## without light — so most of these are costing a vertex and nothing else.
const MOTES_FULL: int = 1400
## How quickly the density may change. 1.5 s to cross the whole range, and it is
## a LERP with no oscillating term, so nothing in this system can flash (pillar
## 7). A dust field that popped as you walked between rooms would also be the
## most distracting thing in the frame.
const RAMP_PER_SECOND: float = 0.66

## How dusty each room archetype's air is, as a multiplier on the layer's own
## density. See `_density_for` in ProcLayerBuilder for the clutter version of the
## same table and the same reasoning: this is a property of what the room is FOR.
##
##   BUS/MACHINERY  the hazy one. Machinery runs, gets serviced, sheds.
##   NEST           filthier still, and nothing has cleaned it in a long time.
##   SIPHON         a plant room: vapour rather than dust, but the same number.
##   VAULT          formal, filtered, and the one room somebody signs for.
##   ARRIVAL        the crew's moment of orientation. Not a smoke machine.
##   SHAFT          a trunk running deeper, so it has a draught and it carries.
##   BACKDOOR       the sanctuary, and near-clean by design — DESIGN.md's one
##                  place you can stop running should also be the one place you
##                  can SEE across.
const ARCHETYPE_HAZE: Dictionary = {
	"bus": 1.35,
	"nest": 1.55,
	"siphon": 1.30,
	"vault": 0.85,
	"arrival": 0.90,
	"shaft": 1.15,
	"backdoor": 0.62,
}
## And the same table for the motes, which are not the same thing: a sanctuary
## can be near-clean in the AIR and still have dust in the shafts of its own
## hearth light, and a vault's filtered air genuinely has very little in it.
const ARCHETYPE_MOTES: Dictionary = {
	"bus": 1.0,
	"nest": 1.15,
	"siphon": 0.85,
	"vault": 0.45,
	"arrival": 0.6,
	"shaft": 0.8,
	"backdoor": 0.35,
}

var _particles: GPUParticles3D = null
var _material: ShaderMaterial = null
## Where the box last teleported to. The emitter only moves in whole steps (see
## `_process`) so the motes are not dragged along with the camera like a swarm.
var _anchor: Vector3 = Vector3.ZERO
var _graph: LayerGraph = null
var _want: float = 1.0
var _have: float = 0.0


# ------------------------------------------------------------- global density --

## The layer's baseline fog density: the authored 0.030, moved by depth.
##
## Small on purpose (±25% across sixteen layers) and stated as a function rather
## than as a constant so the darkness guard has ONE number to audit. DESIGN.md's
## aesthetic gradient says the deep rings are older and less maintained; thicker
## air is the cheapest honest way to say that, and it also makes the deep layers
## read as shorter-sighted without touching a single light energy.
static func layer_fog_density(base: float, layer: int) -> float:
	var depth: float = clampf(inverse_lerp(1.0, 16.0, float(maxi(layer, 1))), 0.0, 1.0)
	return base * lerpf(0.92, 1.25, depth)


# ------------------------------------------------------------------ room haze --

## One FogVolume filling a room, at that room's own density delta.
##
## RELATIVE, not absolute: the box adds `(multiplier - 1) * base`, so a vault
## SUBTRACTS density and a bus hall adds it, and the layer's global figure stays
## the thing that decides what "normal air" is. A room-sized box that set an
## absolute density would make every doorway a visible seam.
static func room_haze(parent: Node3D, rect: Rect2, height: float,
		archetype: String, unlit: bool, base_density: float) -> FogVolume:
	var key: String = "nest" if unlit and archetype == "bus" else archetype
	var multiplier: float = float(ARCHETYPE_HAZE.get(key, 1.0))
	var delta: float = (multiplier - 1.0) * base_density
	if absf(delta) < 0.0008:
		return null
	var fv: FogVolume = FogVolume.new()
	fv.name = "Haze_%s" % key
	fv.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	# Inset from the shell so the box never straddles a wall. A fog volume that
	# pokes through into the corridor beyond puts a soft-edged rectangle of haze
	# in a place the player can see the whole of, and it reads as a bug.
	fv.size = Vector3(maxf(rect.size.x - 1.2, 1.0), maxf(height - 0.4, 1.0),
			maxf(rect.size.y - 1.2, 1.0))
	fv.position = Vector3(rect.position.x + rect.size.x * 0.5,
			(height - 0.4) * 0.5, rect.position.y + rect.size.y * 0.5)
	fv.material = _fog_material(delta, 0.55)
	parent.add_child(fv)
	return fv


## A plume at something dust actually comes OUT of.
##
## The motivation law, applied to atmosphere. Uniform haze is weather, and a
## sealed machine-space has no weather — so the haze has a SOURCE: an open vent
## grille breathing, a machine running hot. Small, local, and thick enough that a
## beam swept across it finds a body of air rather than a wall.
static func source_plume(parent: Node3D, at: Vector3, normal: Vector3,
		base_density: float, strength: float = 1.0) -> FogVolume:
	var fv: FogVolume = FogVolume.new()
	fv.name = "Plume"
	fv.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	fv.size = Vector3(2.6, 2.2, 2.6)
	# Pushed out along the normal and DOWN: what comes out of a vent is heavier
	# and colder than the room, and it falls. A plume centred on the grille reads
	# as a glow around the fitting instead of as air leaving it.
	fv.position = at + normal * 1.1 + Vector3(0.0, -0.35, 0.0)
	fv.material = _fog_material(base_density * 1.9 * strength, 0.72)
	parent.add_child(fv)
	return fv


static func _fog_material(density: float, edge_fade: float) -> ShaderMaterial:
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = load(GodRays.SHAFT_FOG_SHADER) as Shader
	m.set_shader_parameter("base_density", density)
	m.set_shader_parameter("noise_amount", 0.42)
	m.set_shader_parameter("noise_scale", 0.11)
	# Slow. The drift is the only motion in the whole atmosphere system and it is
	# two orders of magnitude under anything the safety law cares about.
	m.set_shader_parameter("drift_speed", 0.018)
	m.set_shader_parameter("edge_fade", edge_fade)
	m.set_shader_parameter("height_gain", 0.75)
	m.set_shader_parameter("fog_albedo", Color(0.52, 0.55, 0.60))
	# THE DARKNESS GUARD, in the one place a room-sized volume could break it.
	# Zero. Not "low" — a fog volume with emission is a room-sized area light.
	m.set_shader_parameter("fog_emission", Color(0.0, 0.0, 0.0))
	m.set_shader_parameter("volume_noise", load(GodRays.VOLUME_NOISE))
	return m


# ------------------------------------------------------------------ the motes --

## Stand a dust box under `parent` and return it. One per layer.
static func attach(parent: Node3D, graph: LayerGraph) -> DustAir:
	var air: DustAir = DustAir.new()
	air.name = "DustAir"
	air._graph = graph
	parent.add_child(air)
	return air


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = load(MOTE_SHADER) as Shader
	_material.set_shader_parameter("opacity", 0.0)

	_particles = GPUParticles3D.new()
	_particles.name = "Motes"
	_particles.amount = MOTES_FULL
	_particles.lifetime = 22.0
	# Preprocessed to a full lifetime so the box is already populated the frame it
	# appears. Without this, walking into a fresh layer means walking into clean
	# air that slowly gets dusty, which is the opposite of an establishing shot.
	_particles.preprocess = 22.0
	_particles.explosiveness = 0.0
	_particles.randomness = 1.0
	# 24 fps, interpolated. Dust moves at centimetres per second; simulating it at
	# 144 is spending the entire budget of the effect on nothing anybody can see.
	_particles.fixed_fps = 24
	_particles.interpolate = true
	_particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_particles.visibility_aabb = AABB(-BOX, BOX * 2.0)
	_particles.process_material = _process_material()

	var quad: QuadMesh = QuadMesh.new()
	# 1-3 cm, via the process material's scale range. Anything bigger stops being
	# dust and starts being ash, which is a different game and a different mood.
	quad.size = Vector2(0.030, 0.030)
	_particles.draw_pass_1 = quad
	_particles.material_override = _material
	# A mote must never cast. Hundreds of shadow-casting quads inside every beam
	# in the game would be the single most expensive thing in the project.
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_particles)


func _process_material() -> ParticleProcessMaterial:
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = BOX
	# Barely moving, and mostly sideways. Dust suspended in still indoor air does
	# not fall visibly — it hangs and wanders. A downward drift reads as snow.
	pm.direction = Vector3(0.3, -1.0, 0.15)
	pm.spread = 55.0
	pm.initial_velocity_min = 0.004
	pm.initial_velocity_max = 0.032
	pm.gravity = Vector3(0.0, -0.004, 0.0)
	# The brownian half. Two scales: a slow large-scale wander so a clump of
	# motes moves together like a body of air, and the noise's own fine detail on
	# top so no two grains follow the same path.
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.11
	pm.turbulence_noise_scale = 1.4
	pm.turbulence_noise_speed = Vector3(0.02, 0.014, 0.02)
	pm.turbulence_influence_min = 0.4
	pm.turbulence_influence_max = 1.0
	pm.scale_min = 0.42
	pm.scale_max = 1.55
	var curve: Curve = Curve.new()
	curve.add_point(Vector2(0.0, 0.0))
	curve.add_point(Vector2(0.16, 1.0))
	curve.add_point(Vector2(0.84, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	var ct: CurveTexture = CurveTexture.new()
	ct.curve = curve
	pm.alpha_curve = ct
	return pm


## Follow the camera, in STEPS.
##
## The emitter jumps a whole box-quarter at a time rather than tracking the
## camera continuously, and that is not an optimisation — it is the difference
## between dust and a swarm. A continuously-tracking emitter drags its particles
## with the player, so the same motes stay in the same screen positions and the
## whole field reads as a texture stuck to the lens. Teleporting the emitter
## leaves the existing motes where they were in the WORLD (the particles are
## global-space) and only decides where the next ones are born.
func _process(delta: float) -> void:
	if _particles == null or not is_instance_valid(_particles):
		return
	var view: Viewport = get_viewport()
	var cam: Camera3D = null if view == null else view.get_camera_3d()
	if cam != null:
		var eye: Vector3 = cam.global_position
		if eye.distance_to(_anchor) > BOX.x * 0.25:
			_anchor = eye
			_particles.global_position = eye
		_want = _density_at(eye)

	var target: float = _want * Photonics.dust_scale()
	_have = move_toward(_have, target, RAMP_PER_SECOND * delta)
	# Ratio AND opacity. The ratio stops simulating motes that are not wanted;
	# the opacity is what makes the change a fade rather than a pop, because
	# `amount_ratio` culls particles instantly and visibly.
	_particles.amount_ratio = clampf(_have, 0.0, 1.0)
	_particles.emitting = _have > 0.005
	_material.set_shader_parameter("opacity", clampf(_have, 0.0, 1.0))


## How dusty the air is where the camera is standing.
##
## Archetype, then depth. Deeper layers are older and dirtier — the same axis
## `layer_fog_density` rides, so the two never disagree about which way a descent
## is going.
func _density_at(eye: Vector3) -> float:
	var key: String = "bus"
	if _graph != null:
		var index: int = _graph.room_at(eye)
		if index >= 0 and index < _graph.rooms.size():
			var room: Dictionary = _graph.rooms[index]
			key = String(room["archetype"])
			if bool(room.get("unlit", false)) and key == "bus":
				key = "nest"
	var depth: float = 0.0
	if _graph != null:
		depth = clampf(inverse_lerp(1.0, 16.0,
				float(maxi(_graph.layer_number, 1))), 0.0, 1.0)
	return clampf(float(ARCHETYPE_MOTES.get(key, 1.0)) * lerpf(0.9, 1.3, depth),
			0.0, 1.0)
