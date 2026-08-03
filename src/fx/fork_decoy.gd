class_name ForkDecoy
extends Node3D
## FORK DECOY — a ghost copy of your avatar that walks away and gets hunted.
##
## The solo lifesaver, and the one subroutine that is genuinely *better* alone: a
## crew has crewmates to split the antivirus's attention, and a lone agent has
## nothing but geometry. A fork gives them one more body in the room that MOTHER
## cannot tell from theirs.
##
## ## What is real and what is not
##
## The decoy is a real node with a real position that the antivirus really steers
## at (`Antivirus._running_players` returns live decoys alongside crew), and it is
## nothing else. It has no collision, does no damage, cannot be shot, and cannot
## block a corridor. Everything it does, it does by being somewhere.
##
## ## Replication: spawned, then simulated identically
##
## Same shape as a thrown flare. The host validates the cast and broadcasts one
## packet (origin, direction, tier, id); every peer builds a decoy from it and
## runs the same deterministic walk — constant speed along a straight line for a
## fixed lifetime — so nothing about its motion has to be streamed. Only the
## *early* death (it soaked its last strike) is a second packet, because that one
## is a host decision.
##
## The walk is clamped against the world at spawn time on every peer identically,
## from the same origin and direction, so a fork does not walk through a wall and
## does not need a physics body to avoid doing so.
##
## ## Why it looks the way it does
##
## It reuses the crew avatar mesh — it is a copy of YOU, and a copy that was a
## different shape would be a different lie. What marks it as a fork is the
## material: unlit, additive, transparent, scanline-banded in the caster's own
## phosphor, with a vertical glitch slip. At a distance, in the dark, it reads as
## a crewmate. Up close it reads as a process that is not quite compiled, which is
## exactly what it is.

const GROUP: String = "decoys"

## Height of the scanline banding, in metres of world space. Tuned so a 1.7 m
## avatar carries about a dozen bands — enough to read as a raster, few enough
## that it does not shimmer into grey at range.
const BAND_HEIGHT: float = 0.14
## How hard the ghost pulses, and how fast. Well under 3 Hz by construction (this
## is a 1.4 s cycle) and scaled by the flash caps like every other lit thing.
const PULSE_PERIOD: float = 1.4
const PULSE_DEPTH: float = 0.22
## Base transparency of the shell.
const GHOST_ALPHA: float = 0.42
## How long the decompile burst takes before the node frees itself.
const DECOMPILE_TIME: float = 0.7

# --- identity (set by the spawn packet, identical on every peer) --------------
var decoy_id: int = 0
## Whose fork this is. Creatures do not care; the HUD and the kill feed might.
var owner_peer: int = 0
var tier: int = 1

var lifetime: float = 6.0
var walk_distance: float = 10.0
## Radius inside which a process prefers this fork to a real crew member.
var lure_radius: float = 22.0
## Strikes it soaks before decompiling early.
var hits_left: int = 3

var _tint: Color = Color(0.4, 0.7, 1.0)
var _from: Vector3 = Vector3.ZERO
var _to: Vector3 = Vector3.ZERO
var _age: float = 0.0
var _dying: float = -1.0
var _avatar: CrewAvatar = null
var _shells: Array[MeshInstance3D] = []
var _materials: Array[ShaderMaterial] = []
var _light: OmniLight3D = null


static func create(id: int, peer: int, subroutine_tier: int, origin: Vector3,
		direction: Vector3, tint: Color, seconds: float, distance: float,
		lure: float, hits: int) -> ForkDecoy:
	var decoy: ForkDecoy = ForkDecoy.new()
	decoy.name = "ForkDecoy_%d" % id
	decoy.decoy_id = id
	decoy.owner_peer = peer
	decoy.tier = maxi(subroutine_tier, 1)
	# M9 DEAD CODE: nobody collected the fork, so it keeps running. Applied HERE
	# rather than at the cast site because a decoy is built independently on every
	# peer from one packet, and the carried table is replicated to all of them —
	# so all four machines extend the same fork by the same amount without the
	# packet having to grow a field. Identity for a caster carrying nothing.
	# Lifetime AND distance, by the same factor, so the fork keeps walking at the
	# authored pace for longer instead of dawdling the same ten metres over nine
	# seconds — a decoy that slows down is a decoy standing next to you.
	var longer: float = Patches.decoy_lifetime_scale(peer)
	decoy.lifetime = maxf(seconds, 0.5) * longer
	decoy.walk_distance = maxf(distance, 0.0) * longer
	decoy.lure_radius = maxf(lure, 1.0)
	decoy.hits_left = maxi(hits, 1) + Patches.decoy_hits_bonus(peer)
	decoy._tint = tint
	decoy._from = origin
	decoy._to = origin + direction
	return decoy


func _ready() -> void:
	add_to_group(GROUP)
	global_position = _from
	_clamp_walk()
	_build_shell()
	set_process(true)


## How far the fork can actually get, decided identically on every peer from the
## same two vectors against the same seeded geometry. Without this a fork cast
## while facing a wall walks straight through it, which would make the ability
## read as a bug rather than as a body.
func _clamp_walk() -> void:
	var direction: Vector3 = _to - _from
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		direction = Vector3.FORWARD
	direction = direction.normalized()
	var reach: float = walk_distance
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space != null:
		# Cast at chest height, not at the feet: a floor ramp under the fork is not
		# a wall in front of it.
		var eye: Vector3 = _from + Vector3.UP * 1.0
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				eye, eye + direction * reach)
		query.collision_mask = Antivirus.WORLD_MASK
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			# Stop a body's width short of the panel rather than inside it.
			reach = maxf(eye.distance_to(Vector3(hit["position"])) - 0.6, 0.0)
	_to = _from + direction * reach
	# Face the way it walks. It is a copy of somebody who chose to go this way.
	rotation.y = atan2(-direction.x, -direction.z)


## The body. A real crew avatar so the silhouette is exactly yours, with every
## surface overridden by the ghost material — the model's own paint would make it
## look like a crewmate standing very still.
func _build_shell() -> void:
	_avatar = CrewAvatar.create(_tint)
	if _avatar.is_loaded():
		add_child(_avatar)
		_ghost_materials(_avatar)
	else:
		# The same fallback the player keeps: a missing export costs you the
		# silhouette, never the ability. A capsule that draws a Hound off you is
		# worth more than a correct-looking nothing.
		_avatar.queue_free()
		_avatar = null
		var shell: MeshInstance3D = MeshInstance3D.new()
		shell.name = "GhostShell"
		var capsule: CapsuleMesh = CapsuleMesh.new()
		capsule.radius = 0.32
		capsule.height = 1.7
		shell.mesh = capsule
		shell.position = Vector3(0.0, 0.85, 0.0)
		shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(shell)
		_apply_ghost(shell)

	# A fork is a program running, and a running program in this game glows a
	# little. Deliberately faint: a decoy that lit the room would draw the Moth by
	# being bright rather than by being a body, which is a different mechanic.
	_light = OmniLight3D.new()
	_light.name = "ForkGlow"
	_light.position = Vector3(0.0, 1.0, 0.0)
	_light.light_color = _tint
	_light.light_energy = 0.9
	_light.omni_range = 4.5
	_light.omni_attenuation = 1.4
	_light.light_volumetric_fog_energy = 2.2
	_light.shadow_enabled = false
	add_child(_light)


func _ghost_materials(root: Node) -> void:
	for child: Node in root.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh != null:
			_apply_ghost(mesh)
		_ghost_materials(child)


## The glitch-transparent look, as a ShaderMaterial built in code.
##
## Written inline rather than as a `.gdshader` file on purpose: it is nine lines,
## it is used by exactly one effect, and a shader file is a resource that has to
## be found, imported and kept in step. The three terms are the whole look —
## world-space scanline banding, a slow pulse, and a fresnel rim so the silhouette
## survives against a dark wall.
func _apply_ghost(mesh: MeshInstance3D) -> void:
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = _ghost_shader()
	material.set_shader_parameter("tint", _tint)
	material.set_shader_parameter("alpha", GHOST_ALPHA)
	material.set_shader_parameter("band_height", BAND_HEIGHT)
	material.set_shader_parameter("pulse", 1.0)
	material.set_shader_parameter("slip", 0.0)
	# Take the crew palette OFF before putting the ghost on.
	#
	# `CrewAvatar.create` paints the body it just built — twelve surface override
	# materials across CrewBody and CrewHead — and a fork then hides all twelve
	# behind one `material_override`. Leaving them there is not free: a mesh
	# carrying both a full set of surface overrides AND an instance override made
	# the renderer emit `Parameter "material" is null` once per surface, twelve
	# times, on every fork cast on every peer. (M7 shipped it; M9 QA counted it.
	# 12 = 5 CrewBody surfaces + 7 CrewHead. The headless renderer's dummy storage
	# reports it three times for the same cast, which is why it read as a smaller
	# problem than it was.) Clearing them first silences it exactly, and it is the
	# honest thing to do anyway: a decoy is not wearing the crew's paint, so it
	# should not be holding twelve materials' worth of it.
	if mesh.mesh != null:
		for surface: int in mesh.mesh.get_surface_count():
			mesh.set_surface_override_material(surface, null)
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shells.append(mesh)
	_materials.append(material)


## ONE shader for every fork ever spawned, compiled once.
##
## The crew avatar is a multi-mesh model, so a fork applies this to several
## surfaces — and a `Shader.new()` per surface per fork is a fresh pipeline
## compilation each time, which in a four-crew is a visible hitch on the frame a
## decoy appears. The MATERIALS stay per-mesh (each carries its own pulse and
## slip); only the compiled program is shared, which is exactly the split Godot's
## material system is built for.
static var _shared_ghost: Shader = null

static func _ghost_shader() -> Shader:
	if _shared_ghost != null:
		return _shared_ghost
	_shared_ghost = Shader.new()
	_shared_ghost.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 tint : source_color = vec4(0.4, 0.7, 1.0, 1.0);
uniform float alpha = 0.42;
uniform float band_height = 0.14;
uniform float pulse = 1.0;
uniform float slip = 0.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// World-space raster bands: the fork is a picture of a program, drawn on
	// something. Sampled in world space so the bands do not swim with the model.
	float band = step(0.42, fract((world_pos.y + slip) / max(band_height, 0.001)));
	// Fresnel rim, so the silhouette reads against a black wall at range. This is
	// most of what makes it look like a body rather than a smudge.
	float rim = pow(1.0 - abs(dot(world_normal, normalize(-VIEW))), 2.2);
	float a = alpha * pulse * (0.35 + band * 0.45 + rim * 0.9);
	ALBEDO = tint.rgb * a;
	ALPHA = a;
}
"""
	return _shared_ghost


func _process(delta: float) -> void:
	if _dying >= 0.0:
		_dying += delta
		var out: float = clampf(1.0 - _dying / DECOMPILE_TIME, 0.0, 1.0)
		for material: ShaderMaterial in _materials:
			material.set_shader_parameter("pulse", out * out)
		if _light != null and is_instance_valid(_light):
			_light.light_energy = 0.9 * out
		if _dying >= DECOMPILE_TIME:
			queue_free()
		return

	_age += delta
	var through: float = clampf(_age / lifetime, 0.0, 1.0)
	global_position = _from.lerp(_to, through)

	# The walk cycle, driven exactly the way a real avatar's is — from a speed,
	# not from an animation flag. It walks at whatever pace its distance and its
	# lifetime imply, so a tier-3 fork that covers 12 m in 8 s strolls and a
	# tier-1 that covers 10 m in 6 s walks. Both look like walking.
	if _avatar != null and is_instance_valid(_avatar):
		var speed: float = walk_distance / maxf(lifetime, 0.01)
		var heading: Vector3 = (_to - _from)
		heading.y = 0.0
		if heading.length_squared() > 0.0001:
			heading = heading.normalized() * speed
		_avatar.drive(delta, speed, heading, 0.0)

	# The pulse: a slow breathe plus a vertical raster slip, both hash-free and
	# both well under the flash ceiling. `UiFx.clock()` rather than wall time, so
	# a capture armed for frame N photographs the same phase on every machine.
	var t: float = UiFx.clock()
	var breathe: float = 1.0 - PULSE_DEPTH * (0.5 + 0.5 * sin(t * TAU / PULSE_PERIOD))
	# It is coming apart at the end of its life. The last second visibly degrades,
	# which is the tell that lets a player know the trick is about to stop working.
	var failing: float = clampf(inverse_lerp(0.82, 1.0, through), 0.0, 1.0)
	var pulse: float = breathe * (1.0 - failing * 0.45) * A11y.flash_scale
	var slip: float = failing * sin(t * 9.0) * 0.09
	for material: ShaderMaterial in _materials:
		material.set_shader_parameter("pulse", pulse)
		material.set_shader_parameter("slip", slip)
	if _light != null and is_instance_valid(_light):
		_light.light_energy = 0.9 * pulse

	if through >= 1.0:
		decompile()


## Where a process aims when it is hunting this fork. Chest height, like a crew
## member's — a Scrubber that lunged at a decoy's ankles would visibly not be
## treating it as a person.
func aim_point() -> Vector3:
	return global_position + Vector3.UP * 1.1


func is_live() -> bool:
	return _dying < 0.0


## Host-side. A process struck the fork. Nothing takes damage — a decoy has no
## integrity — but a copy of a program only survives so many contacts with an
## antivirus, and running out is what stops a fork being a permanent decoy that
## the whole layer stands around hitting.
##
## Returns true when this strike finished it, so the caller can broadcast.
func absorb() -> bool:
	if _dying >= 0.0:
		return false
	hits_left -= 1
	Audio.play_3d(&"sub_fork_hit", global_position)
	return hits_left <= 0


## It decompiles: the fork stops being a body and becomes a burst. Runs on every
## peer — from the timer they all share, or from the host's early-pop packet.
func decompile() -> void:
	if _dying >= 0.0:
		return
	_dying = 0.0
	remove_from_group(GROUP)
	Fx.decompile(global_position, _tint, false, 0.95)
	Audio.play_3d(&"sub_fork_end", global_position)


## Every live fork on this peer, nearest first is the caller's problem. Static so
## the antivirus can ask without holding a reference to the ability system.
static func live_decoys(tree: SceneTree) -> Array[ForkDecoy]:
	var out: Array[ForkDecoy] = []
	if tree == null:
		return out
	for node: Node in tree.get_nodes_in_group(GROUP):
		var decoy: ForkDecoy = node as ForkDecoy
		if decoy != null and is_instance_valid(decoy) and decoy.is_live():
			out.append(decoy)
	return out
