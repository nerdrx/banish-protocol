class_name ClutterLib
extends RefCounted
## The stuff nobody put away — M4.8's density pass.
##
## M3.7 gave the layers architecture and M4 gave them purpose, and the result was
## a building that was *clean*. Real infrastructure is not clean: it has cable
## looms zip-tied along the wall base, pipe runs bracketed overhead, spill stains
## nobody mopped, scorch where something cooked off, crates that were stacked in
## a corridor "temporarily" some years ago, and the occasional dead maintenance
## drone that nobody was ever going to come and collect.
##
## ## Two rules, and both of them are budgets
##
## **1. Draw calls.** This is the milestone most likely to cost the 18-layer soak
## its 60 fps, and the reason is arithmetic: a layer has ~9 rooms and ~10
## corridors, and putting even twenty loose meshes in each is four hundred more
## draw calls than M4.7 shipped. So everything that repeats goes into a
## **MultiMesh** — one per family for the entire layer, accumulated as the builder
## dresses each room and flushed once at the end. Cables, pipes and rubble are
## thousands of instances across three draw calls. Only the pieces that are
## genuinely one-offs (a drone husk, a crate stack with a collider on it) are
## real nodes.
##
## **2. Navigation.** None of it collides except the crate stacks, and those are
## a single box proxy placed by the caller well clear of the doorway-to-doorway
## crossing. Cables lie on the deck at 12 cm — under the step height of every
## body in the game — pipes are at head height and above, and rubble is
## decoration you walk straight through. A creature has never once had to path
## around anything in this file, which is deliberate: the milestone that fills the
## world with objects is not the milestone to also start moving the walls.
##
## ## Determinism
##
## Every decision is a hash of `(world position, layer seed)` through
## `DecalLib.roll`, exactly like the signage and the architecture decay, and for
## the same reason: the dressing RNG is a shared stream and a density pass that
## consumed it would move every shard and Sentinel post on the layer the moment
## somebody retuned how many cans are in a corridor.

# --- materials --------------------------------------------------------------
#
# The kit's own, so clutter is made of the same building the walls are. A prop
# with its own material is a prop that reads as imported.
const MAT_CONDUIT: Material = preload("res://assets/materials/mat_conduit.tres")
const MAT_PANEL: Material = preload("res://assets/materials/mat_panel_dark.tres")
const MAT_TRIM: Material = preload("res://assets/materials/mat_panel_trim.tres")

## Floor grime, from `tools/make_grime.py`. Albedo only — a stain does not glow,
## and a Decal with one texture is one projection.
const GRIME_DIR: String = "res://assets/grime/"
const STAINS: Array = ["stain_a", "stain_b", "stain_c"]
const SCORCHES: Array = ["scorch_a", "scorch_b", "scorch_c"]

## How far a floor decal projects down. Shallow: it only has to reach the deck.
const GRIME_DEPTH: float = 0.5

## Cable geometry. Deliberately under every step height in the game.
const CABLE_HEIGHT: float = 0.13
const CABLE_RADIUS: float = 0.030
const CABLE_SPAN: float = 2.4
const CABLE_SAG: float = 0.045

const PIPE_RADIUS: float = 0.085

static var _grime_cache: Dictionary = {}


## Shared unit meshes. One cylinder and one box for the whole game: every piece
## of clutter is one of those two, scaled. That is what makes the MultiMesh
## batching possible in the first place.
static var _tube_mesh: CylinderMesh = null
static var _chunk_mesh: BoxMesh = null

var _parent: Node3D = null
var _seed: int = 0
## Accumulated instance transforms, per family. Flushed into MultiMeshes once.
var _tubes: Array[Transform3D] = []
var _chunks: Array[Transform3D] = []
## Census, printed with the layer build line: "the world got denser" is a claim,
## and a claim about generation belongs in a log rather than in a screenshot.
var census: Dictionary = {
	"cable": 0, "pipe": 0, "rubble": 0, "crate": 0, "husk": 0, "grime": 0,
}


func _init(parent: Node3D, layer_seed: int) -> void:
	_parent = parent
	_seed = layer_seed
	if _tube_mesh == null:
		_tube_mesh = CylinderMesh.new()
		_tube_mesh.top_radius = 1.0
		_tube_mesh.bottom_radius = 1.0
		_tube_mesh.height = 1.0
		# Eight sides. A cable is 3 cm across and a pipe is 17 — nobody has ever
		# counted the facets on either, and this is the difference between the
		# clutter costing 40k triangles a layer and 200k.
		_tube_mesh.radial_segments = 8
		_tube_mesh.rings = 0
		_tube_mesh.cap_top = false
		_tube_mesh.cap_bottom = false
	if _chunk_mesh == null:
		_chunk_mesh = BoxMesh.new()
		_chunk_mesh.size = Vector3.ONE


# ------------------------------------------------------------------ helpers --

## 0..1 hash of a world point. Same space as the signage and the decay pass.
func roll(at: Vector3, salt: int) -> float:
	return DecalLib.roll(at.x, at.z, salt, _seed)


## A tube instance between two points. Everything cylindrical in this file goes
## through here, so the basis maths exists once.
func _tube(from: Vector3, to: Vector3, radius: float) -> void:
	var delta: Vector3 = to - from
	var length: float = delta.length()
	if length < 0.01:
		return
	var up: Vector3 = delta / length
	var reference: Vector3 = Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 \
			else Vector3.FORWARD
	var right: Vector3 = reference.cross(up).normalized()
	var forward: Vector3 = right.cross(up).normalized()
	_tubes.append(Transform3D(
			Basis(right * radius, up * length, forward * radius),
			(from + to) * 0.5))


func _chunk(at: Vector3, size: Vector3, yaw: float, pitch: float = 0.0) -> void:
	var basis: Basis = Basis.from_euler(Vector3(pitch, yaw, 0.0)).scaled(size)
	_chunks.append(Transform3D(basis, at))


# ------------------------------------------------------------------- cables --

## A cable loom along a wall base, sagging between clips.
##
## `from`/`to` are on the wall line; `inward` is the wall's normal, so the loom
## sits a few centimetres proud of the panel rather than inside it. Two or three
## strands at slightly different heights and standoffs, because one cable is a
## wire and three cables are infrastructure.
func cable_run(from: Vector3, to: Vector3, inward: Vector3) -> void:
	var length: float = from.distance_to(to)
	if length < CABLE_SPAN:
		return
	var spans: int = maxi(int(length / CABLE_SPAN), 1)
	var strands: int = 2 + int(roll(from, 8101) * 2.0)
	for strand: int in strands:
		var lift: float = CABLE_HEIGHT + float(strand) * 0.055
		var stand: float = 0.10 + float(strand) * 0.035
		var previous: Vector3 = Vector3.ZERO
		for i: int in spans + 1:
			var t: float = float(i) / float(spans)
			var point: Vector3 = from.lerp(to, t) + inward * stand \
					+ Vector3.UP * lift
			# Sag between clips: the midpoint of every span dips. Cheap, and it is
			# the entire difference between a cable and a pipe.
			if i > 0:
				var mid: Vector3 = (previous + point) * 0.5 \
						+ Vector3.DOWN * (CABLE_SAG * (1.0 + float(strand) * 0.4))
				_tube(previous, mid, CABLE_RADIUS)
				_tube(mid, point, CABLE_RADIUS)
				census["cable"] = int(census["cable"]) + 2
			# A clip every few spans, so the loom is fixed to something.
			if i % 3 == 0 and strand == 0:
				_chunk(point + inward * -0.02, Vector3(0.07, 0.16, 0.11), 0.0)
			previous = point


# -------------------------------------------------------------------- pipes --

## A bracketed pipe cluster running along a wall at head height and above. The
## one piece of clutter that is *supposed* to be in your way visually and never
## physically: it breaks a beam sweeping down a corridor into bands.
func pipe_cluster(from: Vector3, to: Vector3, inward: Vector3, height: float) -> void:
	var length: float = from.distance_to(to)
	if length < 3.0:
		return
	var count: int = 2 + int(roll(from, 8221) * 3.0)
	for i: int in count:
		var stand: float = 0.22 + float(i) * 0.19
		var lift: float = height + (roll(from + Vector3(float(i), 0.0, 0.0), 8317) - 0.5) * 0.5
		var radius: float = PIPE_RADIUS * (0.7 + roll(from, 8419 + i) * 0.8)
		_tube(from + inward * stand + Vector3.UP * lift,
				to + inward * stand + Vector3.UP * lift, radius)
		census["pipe"] = int(census["pipe"]) + 1

	# Brackets every few metres, hanging the cluster off the wall.
	var brackets: int = maxi(int(length / 4.0), 1)
	for i: int in brackets + 1:
		var t: float = float(i) / float(brackets)
		var at: Vector3 = from.lerp(to, t) + inward * 0.32 + Vector3.UP * height
		_chunk(at + inward * -0.28, Vector3(0.6, 0.09, 0.09),
				atan2(inward.x, inward.z))


# ------------------------------------------------------------------- rubble --

## A debris pile: fragments of panel, broken trim, a scatter of chips. Purely
## decorative, walked straight through, and the single densest thing on a layer
## by instance count — which is exactly why it is a MultiMesh.
func rubble_pile(at: Vector3, radius: float, amount: int) -> void:
	for i: int in amount:
		var r1: float = roll(at + Vector3(float(i) * 0.7, 0.0, 0.0), 8501)
		var r2: float = roll(at + Vector3(0.0, 0.0, float(i) * 0.7), 8563)
		var r3: float = roll(at + Vector3(float(i) * 0.3, 0.0, float(i) * 0.9), 8623)
		var angle: float = r1 * TAU
		var reach: float = sqrt(r2) * radius
		var size: float = lerpf(0.06, 0.30, r3)
		_chunk(at + Vector3(cos(angle) * reach, size * 0.35, sin(angle) * reach),
				Vector3(size, size * lerpf(0.18, 0.55, r1), size * lerpf(0.6, 1.4, r2)),
				r3 * TAU, (r1 - 0.5) * 0.5)
		census["rubble"] = int(census["rubble"]) + 1


# ------------------------------------------------------------------- crates --

## A stack of crates or a server totem. The one clutter family that collides, so
## the caller places it and owns the box proxy — see ProcLayerBuilder._clutter_room.
##
## Returns the stack's footprint so the caller can size that proxy.
func crate_stack(at: Vector3, yaw: float, tall: bool) -> Vector3:
	var group: Node3D = Node3D.new()
	group.name = "Crates"
	group.position = at
	group.rotation.y = yaw
	_parent.add_child(group)

	var levels: int = 2 + int(roll(at, 8707) * (3.0 if tall else 2.0))
	var width: float = lerpf(0.75, 1.05, roll(at, 8741))
	var y: float = 0.0
	for level: int in levels:
		var shrink: float = 1.0 - float(level) * 0.06
		var height: float = lerpf(0.42, 0.68, roll(at + Vector3(0.0, float(level), 0.0), 8803))
		var w: float = width * shrink
		# Each crate is nudged off the one below it. A perfectly aligned stack
		# reads as a placeholder; a stack that is 4 cm out reads as one somebody
		# put there in a hurry.
		var slip: Vector3 = Vector3(
				(roll(at + Vector3(float(level), 0.0, 0.0), 8861) - 0.5) * 0.12, 0.0,
				(roll(at + Vector3(0.0, 0.0, float(level)), 8923) - 0.5) * 0.12)
		var twist: float = (roll(at + Vector3(float(level), float(level), 0.0), 8971) - 0.5) * 0.3
		_group_box(group, slip + Vector3(0.0, y + height * 0.5, 0.0),
				Vector3(w, height, w * 0.92), MAT_PANEL, twist)
		_group_box(group, slip + Vector3(0.0, y + height - 0.02, 0.0),
				Vector3(w * 0.86, 0.04, w * 0.8), MAT_CONDUIT, twist)
		# One dim slot per crate at most, and only on the taller totems: a stack
		# of glowing boxes is a Christmas tree, not a server rack.
		if tall and level == levels - 1:
			_group_box(group, slip + Vector3(0.0, y + height * 0.5, -(w * 0.46)),
					Vector3(w * 0.35, 0.02, 0.012), _slot_material(), twist)
		y += height
	census["crate"] = int(census["crate"]) + levels
	return Vector3(width, y, width)


static func _slot_material() -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = GeometryKit.SYSTEM_TEAL.darkened(0.6)
	material.emission_enabled = true
	material.emission = GeometryKit.SYSTEM_TEAL
	material.emission_energy_multiplier = 0.32
	material.roughness = 0.6
	material.disable_receive_shadows = true
	return material


func _group_box(group: Node3D, at: Vector3, size: Vector3, material: Material,
		yaw: float = 0.0) -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = at
	mesh.rotation.y = yaw
	mesh.material_override = material
	mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	group.add_child(mesh)


# --------------------------------------------------------------- drone husk --

## A dead maintenance drone: a Scrubber shell that stopped running some time ago.
##
## Reuses the authored Scrubber mesh rather than modelling a new prop, which is
## both the cheap answer and the right one — the crew learns that silhouette as
## the thing that kills them, and finding one of them lying on its side with its
## sensor out is the same silhouette saying something else entirely.
##
## Stripped to a pose: the AnimationPlayer is freed, so the model is a skinned
## mesh at rest with no per-frame cost, and every emissive slot goes to dead
## metal. Deliberately rare — one or two on a layer. A corridor of corpses is a
## diorama; one corpse is a story.
func drone_husk(at: Vector3, yaw: float) -> void:
	var model: Node3D = CreatureKit.instantiate(CreatureKit.SCRUBBER)
	if model == null:
		return
	model.name = "DroneHusk"
	# Nothing about a husk animates. Freeing the player rather than pausing it
	# means the node does not exist to be ticked, which matters when the soak is
	# building eighteen of these.
	var animator: AnimationPlayer = CreatureKit.find_player(model)
	if animator != null:
		animator.queue_free()

	var dead: StandardMaterial3D = CreatureKit.matte(
			CreatureKit.ENEMY_BODY.lightened(0.04), 0.72, 0.30)
	var burnt: StandardMaterial3D = CreatureKit.matte(Color(0.09, 0.07, 0.07), 0.8, 0.2)
	CreatureKit.paint(CreatureKit.find_mesh(model), {
		"Body": dead,
		"Plate": burnt,
		"EmissRed": burnt,
		"CoreEmiss": burnt,
	})

	var holder: Node3D = Node3D.new()
	holder.name = "Husk"
	holder.position = at
	holder.rotation = Vector3(
			# Tipped onto its side or its back, and never level: a drone that
			# powered down neatly is a drone that was switched off, and nothing
			# down here is switched off on purpose.
			lerpf(-0.5, -1.5, roll(at, 9011)),
			yaw,
			lerpf(-0.9, 0.9, roll(at, 9067)))
	holder.add_child(model)
	_parent.add_child(holder)
	census["husk"] = int(census["husk"]) + 1


# -------------------------------------------------------------------- grime --

## A floor stain or scorch mark. Albedo only, no emission, no collider — the
## single cheapest piece of storytelling in the project.
func grime(at: Vector3, scorch: bool, size: float) -> void:
	var menu: Array = SCORCHES if scorch else STAINS
	var name: String = String(menu[int(roll(at, 9101) * float(menu.size()))
			% menu.size()])
	var texture: Texture2D = _grime_texture(name)
	if texture == null:
		return
	var decal: Decal = Decal.new()
	decal.name = "Grime_" + name
	decal.texture_albedo = texture
	decal.size = Vector3(size, GRIME_DEPTH, size)
	decal.upper_fade = 0.1
	decal.lower_fade = 0.4
	# Floor only. Without the normal fade a wide stain climbs the crate standing
	# in the middle of it, which reads as paint rather than as a spill.
	decal.normal_fade = 0.45
	decal.modulate = Color(1.0, 1.0, 1.0, lerpf(0.55, 0.95, roll(at, 9157)))
	decal.albedo_mix = 0.9
	decal.distance_fade_enabled = true
	decal.distance_fade_begin = 22.0
	decal.distance_fade_length = 10.0
	decal.position = at + Vector3(0.0, GRIME_DEPTH * 0.4, 0.0)
	decal.rotation.y = roll(at, 9209) * TAU
	_parent.add_child(decal)
	census["grime"] = int(census["grime"]) + 1


static func _grime_texture(name: String) -> Texture2D:
	if _grime_cache.has(name):
		return _grime_cache[name] as Texture2D
	var texture: Texture2D = load(GRIME_DIR + name + ".png") as Texture2D
	if texture == null:
		push_warning("[ClutterLib] missing grime '%s' — run tools/make_grime.py" % name)
	_grime_cache[name] = texture
	return texture


# -------------------------------------------------------------------- flush --

## Turns everything accumulated into two MultiMeshInstance3Ds and returns how
## many draw calls this whole pass cost. Called once, at the end of the build.
func flush() -> int:
	var calls: int = 0
	calls += _flush_family("ClutterTubes", _tube_mesh, _tubes, MAT_CONDUIT)
	calls += _flush_family("ClutterChunks", _chunk_mesh, _chunks, MAT_PANEL)
	return calls


func _flush_family(node_name: String, mesh: Mesh, transforms: Array[Transform3D],
		material: Material) -> int:
	if transforms.is_empty() or mesh == null:
		return 0
	var multi: MultiMesh = MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for i: int in transforms.size():
		multi.set_instance_transform(i, transforms[i])

	var instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multi
	instance.material_override = material
	# No shadows and no GI from any of it. A cable loom casting a shadow map entry
	# is the most expensive possible way to render a piece of string, and the
	# grazing wall wash the kit relies on would be broken up by hundreds of tiny
	# shadow casters into something that reads as noise.
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_parent.add_child(instance)
	return 1


## One line for the layer census.
func describe() -> String:
	return "cable %d, pipe %d, rubble %d, crate %d, husk %d, grime %d" % [
		int(census["cable"]), int(census["pipe"]), int(census["rubble"]),
		int(census["crate"]), int(census["husk"]), int(census["grime"])]
