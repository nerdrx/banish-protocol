class_name CreatureKit
extends RefCounted
## Shared loading and palette plumbing for M3.7's authored models.
##
## Three of them come out of the same source art, and one of them (CyberSentinel)
## is used TWICE with opposite palettes — near-black-and-red as the enemy, pale-
## and-blue as the crew avatar. That split is the whole readability argument in
## DESIGN.md: the silhouette is deliberately the same, because it should be
## unsettling that the thing hunting you is wearing your shape; the *colour* is
## what tells you in a tenth of a second which one you are looking at.
##
## So: the .glb files ship with their authored material names and nothing else.
## Every surface is repainted here, at load, from a name -> material table. That
## keeps one mesh serving two characters, keeps per-player tinting possible (a
## crewmate's accents follow their lobby shell colour), and means an art re-export
## never has to know anything about the game's palette.
##
## Materials are applied as **surface overrides on the instance**, not on the mesh
## resource: two Scrubbers on the same layer flash their sensors independently,
## and a mesh-level binding would make one hit light up the whole pack.

const SCRUBBER: String = "res://assets/models/scrubber.glb"
const SENTINEL: String = "res://assets/models/sentinel.glb"
const SENTINEL_KIT: String = "res://assets/models/sentinel_kit.glb"
const CREW_AVATAR: String = "res://assets/models/crew_avatar.glb"
const SURGE: String = "res://assets/models/surge.glb"

## Enemy palette. The body swallows light — a Sentinel should be a hole in the
## room until its core comes up — and every emissive slot burns red, which
## DESIGN.md reserves for hostile processes and nothing else.
const ENEMY_BODY: Color = Color(0.038, 0.038, 0.048)
const ENEMY_PLATE: Color = Color(0.055, 0.055, 0.068)
const ENEMY_RED: Color = Color(1.0, 0.14, 0.13)

## Crew palette: the inverse. A pale shell so a crewmate is a readable silhouette
## in a beam at 15 m, with the accents tinted to that player's lobby colour.
const CREW_SHELL: Color = Color(0.62, 0.66, 0.72)
const CREW_PLATE: Color = Color(0.74, 0.78, 0.84)

## Every surface name across the art set, as a reference for whoever writes the
## next palette. Two families, because two pipelines produced the models:
##
##   nullvoid-art creatures  Body, Plate, EmissRed, CoreEmiss
##   CyberSentinel.fbx       LightMetal, Armour, Emiss, Slime, Mask, Bone, Eyes
##   Gun_Surge.fbx           Base, Emiss, Material.001
const KNOWN_SLOTS: Array = [
	"Body", "Plate", "EmissRed", "CoreEmiss",
	"LightMetal", "Armour", "Emiss", "Slime", "Mask", "Bone", "Eyes",
	"Base", "Material.001",
]


## Instantiates a .glb and returns its root. Kept in one place because a failed
## load has to be loud: a creature that silently comes up invisible is a bug that
## survives every automated test in the project.
static func instantiate(path: String) -> Node3D:
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_error("[CreatureKit] cannot load %s" % path)
		return null
	var node: Node3D = packed.instantiate() as Node3D
	if node == null:
		push_error("[CreatureKit] %s is not a Node3D scene" % path)
	return node


## First MeshInstance3D under `root`, depth first.
static func find_mesh(root: Node) -> MeshInstance3D:
	var mesh: MeshInstance3D = root as MeshInstance3D
	if mesh != null:
		return mesh
	for child: Node in root.get_children():
		var found: MeshInstance3D = find_mesh(child)
		if found != null:
			return found
	return null


static func find_skeleton(root: Node) -> Skeleton3D:
	var skeleton: Skeleton3D = root as Skeleton3D
	if skeleton != null:
		return skeleton
	for child: Node in root.get_children():
		var found: Skeleton3D = find_skeleton(child)
		if found != null:
			return found
	return null


static func find_player(root: Node) -> AnimationPlayer:
	var player: AnimationPlayer = root as AnimationPlayer
	if player != null:
		return player
	for child: Node in root.get_children():
		var found: AnimationPlayer = find_player(child)
		if found != null:
			return found
	return null


## Repaints every surface of `mesh` from `palette` (slot name -> Material).
## Unlisted slots are left on whatever the .glb shipped, which is the right
## default: a new material slot appearing in a re-export should look wrong on
## screen rather than disappear.
static func paint(mesh: MeshInstance3D, palette: Dictionary) -> void:
	if mesh == null or mesh.mesh == null:
		return
	for i: int in mesh.mesh.get_surface_count():
		var source: Material = mesh.mesh.surface_get_material(i)
		var slot: String = "" if source == null else source.resource_name
		for key: String in palette:
			if slot.begins_with(key):
				mesh.set_surface_override_material(i, palette[key] as Material)
				break


## Matte shell. Metallic is kept low on purpose: a true metal returns almost
## nothing to a head-mounted beam except an off-axis lobe, and a creature lit
## only by the player's torch would render as a black hole with a highlight.
static func matte(colour: Color, metallic: float = 0.3,
		roughness: float = 0.52) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour
	material.metallic = metallic
	material.roughness = roughness
	return material


static func emissive(colour: Color, energy: float,
		darken: float = 0.75) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = colour.darkened(darken)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = energy
	material.roughness = 0.4
	material.disable_receive_shadows = true
	return material


const GEL_SHADER: Shader = preload("res://src/shaders/nv_slime.gdshader")
static var _gel_noise: NoiseTexture2D = null


## The Slime slot: dark-glass gel with an internal glow (M4.9, ported from the
## limbo-lookdev2 recipe). `core_color` is the one faction token — the crew's
## player-phosphor accent, or the Sentinel's deep red circulating between shell and
## bones. Dark-first (near-black albedo); the glow lives INSIDE the shell and the
## pale Bone geometry (see `bone_material`) reads through it up close.
static func gel_material(core_color: Color, energy: float,
		pulse: float = 0.22) -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = GEL_SHADER
	mat.set_shader_parameter("core_color",
			Vector3(core_color.r, core_color.g, core_color.b))
	mat.set_shader_parameter("core_energy", energy)
	mat.set_shader_parameter("pulse_amount", pulse)
	mat.set_shader_parameter("core_noise", _gel_noise_texture())
	return mat


## One shared animated noise field for the gel veins, built once.
static func _gel_noise_texture() -> NoiseTexture2D:
	if _gel_noise != null:
		return _gel_noise
	var n: FastNoiseLite = FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.045
	n.fractal_octaves = 3
	_gel_noise = NoiseTexture2D.new()
	_gel_noise.noise = n
	_gel_noise.seamless = true
	_gel_noise.width = 256
	_gel_noise.height = 256
	return _gel_noise


## The Bone slot: pale and emissive-lifted so the interior skeleton reads THROUGH
## the gel shell up close (PRESS.md recipe values). Countable at 1-2 m, swallowed
## toward black by the gel's absorption by ~8 m.
static func bone_material(pale: Color = Color(0.47, 0.446, 0.40)) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = pale
	mat.metallic = 0.0
	mat.roughness = 0.44
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.88, 0.72)
	mat.emission_energy_multiplier = 0.6
	mat.disable_receive_shadows = true
	return mat


## Hangs the tail. Attaches a TailDriver to the Tail1..Tail5 chain so the tail SAGS
## into a heavy downward curve at rest, lags on turns, streams with movement and
## bounces on landing (M4.9). Replaces the rig's dead-straight bind tail and the
## crew's baked tail keys — a horizontal tail is the un-simulated "cursed" default
## this exists to kill. (Godot 4.7's SpringBoneSimulator3D would not deflect these
## rigs' tails; see tail_driver.gd.)
##
## `droop_deg` is the per-segment resting bend (it accumulates down the chain into
## the curve) and `liveliness` scales the dynamic lag/bounce — crew lively, the
## Sentinel dead-weight. The driver runs LAST in the frame, so it drapes the pose
## the animation just wrote.
##
## Cosmetic and LOCAL per peer (the task's rule): it reads the replicated pose and
## writes only to this peer's own skeleton, never to networked or seeded state — so
## it cannot perturb the determinism dump, and two peers seeing slightly different
## tail motion is expected and fine. The resting droop is the gravity equilibrium,
## which a standing avatar settles to identically every run under the pinned-60fps
## capture path, so a standing-still tail capture is reproducible.
static func build_spring_tail(skeleton: Skeleton3D, droop_deg: float,
		liveliness: float) -> Node:
	if skeleton == null or skeleton.find_bone("Tail1") < 0:
		return null
	# The Tail1..Tail5 chain, root to tip. `droop_deg` is the per-segment resting
	# bend; because each bone's rotation is relative to its already-bent parent, the
	# bends ACCUMULATE down the chain into a hanging curve. A shape ramp puts the
	# most droop through the middle so the tail arcs rather than kinking at the base.
	const SHAPE: Array = [0.7, 1.0, 1.1, 1.0, 0.85]
	var bones: PackedInt32Array = PackedInt32Array()
	var droop: PackedFloat32Array = PackedFloat32Array()
	var i: int = 0
	for name: String in ["Tail1", "Tail2", "Tail3", "Tail4", "Tail5"]:
		var bi: int = skeleton.find_bone(name)
		if bi >= 0:
			bones.append(bi)
			droop.append(deg_to_rad(droop_deg) * float(SHAPE[mini(i, SHAPE.size() - 1)]))
		i += 1
	if bones.is_empty():
		return null
	# Properties set BEFORE add_child, because for an in-tree skeleton _ready fires
	# the instant it is parented and reads them.
	var driver: Node = preload("res://src/creatures/tail_driver.gd").new()
	driver.name = "TailDriver"
	driver.set("skeleton", skeleton)
	driver.set("bones", bones)
	driver.set("droop", droop)
	driver.set("liveliness", liveliness)
	skeleton.add_child(driver)
	return driver


## Builds the AnimationTree every animated character in the game uses:
##
##     BlendTree
##       "state"  AnimationNodeStateMachine   one node per clip
##       "speed"  AnimationNodeTimeScale      driven by real world speed
##       output
##
## The TimeScale is the reason this is a blend tree rather than a bare state
## machine. A skitter clip authored at one pace and played at that pace under a
## creature moving at another is the single most obvious animation fault there
## is — the feet slide, and once you have seen it you cannot unsee it. Wrapping
## the machine in a scale node lets the gameplay speed drive the clip.
##
## `clips` maps state name -> animation name. Every state is reachable from every
## other, so callers only ever have to say where they want to be.
static func build_tree(host: Node, player: AnimationPlayer, clips: Dictionary,
		start: String, xfade: float = 0.18) -> AnimationTree:
	if player == null:
		push_error("[CreatureKit] no AnimationPlayer to drive")
		return null

	var machine: AnimationNodeStateMachine = AnimationNodeStateMachine.new()
	for state: String in clips:
		var clip: AnimationNodeAnimation = AnimationNodeAnimation.new()
		clip.animation = StringName(clips[state])
		machine.add_node(state, clip)
	for from: String in clips:
		for to: String in clips:
			if from == to:
				continue
			var link: AnimationNodeStateMachineTransition = \
					AnimationNodeStateMachineTransition.new()
			link.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
			link.xfade_time = xfade
			link.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_DISABLED
			machine.add_transition(from, to, link)

	var blend: AnimationNodeBlendTree = AnimationNodeBlendTree.new()
	blend.add_node("state", machine, Vector2(0.0, 0.0))
	var scale: AnimationNodeTimeScale = AnimationNodeTimeScale.new()
	blend.add_node("speed", scale, Vector2(320.0, 0.0))
	blend.connect_node("speed", 0, "state")
	blend.connect_node("output", 0, "speed")

	var tree: AnimationTree = AnimationTree.new()
	tree.name = "AnimTree"
	tree.tree_root = blend
	# PHYSICS, not IDLE, and the reason is procedural bone work.
	#
	# The crew avatar layers a head-look on top of whatever clip is playing by
	# writing bone poses directly. Godot runs `_physics_process` before
	# `_process` within a frame, so an animation mixer on the idle callback would
	# overwrite those writes every single frame and the head would never move —
	# a bug that looks exactly like "the head-track code does not work" and is
	# actually a scheduling order. On the physics callback the tree writes first
	# and the override lands after it, every time.
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	host.add_child(tree)
	# anim_player is a NodePath relative to the tree, so it can only be resolved
	# once the tree is actually in the scene.
	tree.anim_player = tree.get_path_to(player)
	tree.active = true
	travel(tree, start)
	return tree


## Sets the loop mode on a player's clips. glTF carries no loop flag, so every
## imported animation arrives as one-shot; a walk cycle that plays once and stops
## is the classic symptom.
static func set_looping(player: AnimationPlayer, looping: PackedStringArray) -> void:
	if player == null:
		return
	for name: String in looping:
		if not player.has_animation(name):
			continue
		player.get_animation(name).loop_mode = Animation.LOOP_LINEAR


## Adds an upper-body overlay to a tree built by `build_tree`.
##
## The result is:
##
##     BlendTree
##       "state"   state machine    locomotion, the whole body
##       "speed"   time scale       gameplay speed -> clip rate
##       "overlay" AnimationNodeAnimation   one held pose
##       "split"   Blend2 + bone filter     overlay wins above the split bone
##       output
##
## This is what lets a crewmate walk with their legs and hold a rifle with their
## arms at the same time without authoring a walk-with-rifle clip, a
## run-with-rifle clip, and every other combination. The filter is computed from
## the skeleton at runtime rather than hardcoded — every bone descended from
## `split_bone` is in the upper body by definition, which survives a re-export
## adding a finger.
static func add_upper_body(tree: AnimationTree, skeleton: Skeleton3D,
		clip: String, split_bone: String, track_prefix: String) -> bool:
	if tree == null or skeleton == null:
		return false
	var root: AnimationNodeBlendTree = tree.tree_root as AnimationNodeBlendTree
	if root == null:
		return false
	var split: int = skeleton.find_bone(split_bone)
	if split < 0:
		push_warning("[CreatureKit] no '%s' bone to split the body at" % split_bone)
		return false

	var overlay: AnimationNodeAnimation = AnimationNodeAnimation.new()
	overlay.animation = StringName(clip)
	root.add_node("overlay", overlay, Vector2(320.0, 180.0))

	var blend: AnimationNodeBlend2 = AnimationNodeBlend2.new()
	blend.filter_enabled = true
	for bone: int in skeleton.get_bone_count():
		if not _descends_from(skeleton, bone, split):
			continue
		blend.set_filter_path(NodePath("%s:%s" % [track_prefix,
				skeleton.get_bone_name(bone)]), true)
	root.add_node("split", blend, Vector2(560.0, 0.0))

	# Unplug the output BEFORE rewiring. A blend tree refuses to take a node as a
	# source while that node is still feeding the output slot, so connecting
	# `speed -> split` with `speed -> output` still live fails, and it fails with
	# an error message ("output == p_output_node") that points at the wrong end
	# of the graph entirely.
	root.disconnect_node("output", 0)
	root.connect_node("split", 0, "speed")
	root.connect_node("split", 1, "overlay")
	root.connect_node("output", 0, "split")
	return true


static func _descends_from(skeleton: Skeleton3D, bone: int, ancestor: int) -> bool:
	var walk: int = bone
	while walk >= 0:
		if walk == ancestor:
			return true
		walk = skeleton.get_bone_parent(walk)
	return false


## How much of the upper-body overlay is showing, 0..1.
static func set_upper_body(tree: AnimationTree, amount: float) -> void:
	if tree == null:
		return
	tree.set("parameters/split/blend_amount", clampf(amount, 0.0, 1.0))


static func travel(tree: AnimationTree, state: String) -> void:
	if tree == null:
		return
	var playback: AnimationNodeStateMachinePlayback = \
			tree.get("parameters/state/playback") as AnimationNodeStateMachinePlayback
	if playback == null:
		return
	if playback.get_current_node() != state:
		playback.travel(state)


static func set_speed(tree: AnimationTree, scale: float) -> void:
	if tree == null:
		return
	tree.set("parameters/speed/scale", maxf(scale, 0.01))
