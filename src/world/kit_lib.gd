class_name KitLib
extends RefCounted
## Loader + material binder for the NULLVOID architecture kit.
##
## The .glb ships with placeholder Principled materials named `M_PanelDark`,
## `M_EmissiveTeal` and so on. Nothing in the engine ever renders those: on first
## load every surface is re-bound, ON THE MESH RESOURCE, to the corresponding
## ShaderMaterial in assets/materials. Binding on the mesh rather than per
## instance means a thousand placed modules share six material instances and six
## shader compilations — which is the difference between this kit being usable in
## a procgen layer and it being a demo.
##
## Meshes are shared between instances too, so identical modules batch. The macro
## noise in the surface shader is sampled in WORLD space precisely so that
## sharing the mesh does not mean sharing the look.
##
## M4.95 (the filmic pass): the kit is now bound to the baked-PBR materials
## (mat_pbr_*), which carry real tiling texture data and survive being looked at
## from 30 cm. The procedural look-dev-1 materials (mat_panel_dark et al.) are
## kept on disk as the fallback documented in INTEGRATION2 §13, but nothing binds
## them any more. A second optional .glb (`limbo_trim.glb`) adds the dressing
## modules — baseboards, corner posts, cable trays — that kill the wall/floor
## greybox seam.

const KIT_PATH: String = "res://assets/kit/nullvoid_kit.glb"
## The FILMIC-PASS dressing modules — baseboards, corner posts, cable trays. A
## second .glb rather than a re-export of the first so that a broken trim build
## can never take the architecture down with it: if it fails to load the layer
## degrades to "no baseboards", not to a wall of push_error.
const TRIM_PATH: String = "res://assets/kit/limbo_trim.glb"

## Blender material slot -> engine material. This table IS the art-direction
## contract between the mesh author (build_kit.py) and the look-dev pass; adding a
## slot in build_kit.py means adding a line here.
##
## M4.95 ships the baked-PBR set unconditionally (INTEGRATION2's RECOMMENDED
## column). The emissive slot is the ONE material shared with the procedural
## era — the inlays never needed a texture, they are pure light-line-work — which
## is also why `set_alert` special-cases it below.
const MATERIAL_MAP: Dictionary = {
	"M_PanelDark": "res://assets/materials/mat_pbr_panel_dark.tres",
	"M_PanelTrim": "res://assets/materials/mat_pbr_panel_trim.tres",
	"M_FloorPlate": "res://assets/materials/mat_pbr_floor_plate.tres",
	"M_Grate": "res://assets/materials/mat_pbr_grate.tres",
	"M_Conduit": "res://assets/materials/mat_pbr_conduit.tres",
	"M_EmissiveTeal": "res://assets/materials/mat_emissive_teal.tres",
}

## The procedural look-dev-1 materials, kept as the documented fallback
## (INTEGRATION2 §13 "last resort: PBR off entirely — nv_surface.gdshader is
## still present and still works"). Not bound by default; swap MATERIAL_MAP to
## this if the baked textures ever have to come out.
const PROCEDURAL_MATERIAL_MAP: Dictionary = {
	"M_PanelDark": "res://assets/materials/mat_panel_dark.tres",
	"M_PanelTrim": "res://assets/materials/mat_panel_trim.tres",
	"M_FloorPlate": "res://assets/materials/mat_floor_plate.tres",
	"M_Grate": "res://assets/materials/mat_grate.tres",
	"M_Conduit": "res://assets/materials/mat_conduit.tres",
	"M_EmissiveTeal": "res://assets/materials/mat_emissive_teal.tres",
}

static var _meshes: Dictionary = {}
static var _materials: Dictionary = {}
static var _loaded: bool = false


static func load_kit() -> void:
	if _loaded:
		return
	_loaded = true

	for slot: String in MATERIAL_MAP:
		var mat: Material = load(MATERIAL_MAP[slot]) as Material
		if mat == null:
			push_error("KitLib: missing material for slot %s" % slot)
			continue
		_materials[slot] = mat

	_load_glb(KIT_PATH, true)
	_load_glb(TRIM_PATH, false)

	var names: Array = _meshes.keys()
	names.sort()
	print("[KitLib] %d modules: %s" % [names.size(), ", ".join(names)])


## Load one .glb, bind every surface to its look-dev material, and remember the
## meshes by node name. `required` distinguishes the architecture kit (a missing
## one is fatal) from the optional trim kit (a missing one is a warning).
static func _load_glb(path: String, required: bool) -> void:
	if not ResourceLoader.exists(path):
		if required:
			push_error("KitLib: cannot find %s" % path)
		else:
			push_warning("KitLib: optional kit %s not present, skipping" % path)
		return
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_error("KitLib: cannot load %s" % path)
		return
	var root: Node = packed.instantiate()
	for child: Node in root.get_children():
		var mi: MeshInstance3D = child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var mesh: Mesh = mi.mesh
		_bind(mesh)
		_meshes[child.name] = mesh
	root.queue_free()


static func _bind(mesh: Mesh) -> void:
	var array_mesh: ArrayMesh = mesh as ArrayMesh
	for i: int in mesh.get_surface_count():
		var src: Material = mesh.surface_get_material(i)
		var slot: String = src.resource_name if src != null else ""
		# glTF import sometimes suffixes duplicated names ("M_PanelDark_001");
		# match on the prefix so a re-export never silently unbinds a surface.
		for key: String in _materials:
			if slot.begins_with(key):
				if array_mesh != null:
					array_mesh.surface_set_material(i, _materials[key])
				break


## One placed module. `mesh_name` is a key from build_kit.py.
static func spawn(parent: Node3D, mesh_name: String, xform: Transform3D,
		name_hint: String = "") -> MeshInstance3D:
	load_kit()
	if not _meshes.has(mesh_name):
		push_error("KitLib: no module named %s" % mesh_name)
		return null
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = _meshes[mesh_name]
	mi.transform = xform
	mi.name = name_hint if name_hint != "" else mesh_name
	# Kit modules are small and dense; shadow casting from every bolt head is
	# waste. Off for detail-only pieces is handled by the caller.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# SDFGI is REJECTED (INTEGRATION2 §8: indistinguishable in near-black for 20x
	# the cost), so nothing here has to opt into GI voxelisation.
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(mi)
	return mi


## True if a module was found in one of the loaded .glb files. Callers use this
## rather than trusting a flag, because the trim kit is an optional second .glb
## and a half-built one should degrade to "no baseboards", not to push_error spam
## that buries a real problem.
static func has(mesh_name: String) -> bool:
	load_kit()
	return _meshes.has(mesh_name)


static func material(slot: String) -> Material:
	load_kit()
	return _materials.get(slot, null) as Material


## The shared Mesh for a module, for callers that batch it into a MultiMesh
## themselves (the M4.95 trim pass runs the whole perimeter of every room, which
## is hundreds of instances a layer — a MultiMesh keeps that to a couple of draw
## calls) rather than spawning one node per instance via `spawn`.
static func mesh(mesh_name: String) -> Mesh:
	load_kit()
	return _meshes.get(mesh_name, null) as Mesh


## Red-alert state. Every surface material carries the same `alert` uniform, so
## the whole layer turns hostile from one call instead of a material swap pass.
static func set_alert(amount: float) -> void:
	load_kit()
	for slot: String in _materials:
		var mat: ShaderMaterial = _materials[slot] as ShaderMaterial
		if mat == null:
			continue
		if slot == "M_EmissiveTeal":
			mat.set_shader_parameter("hostile", amount)
		else:
			mat.set_shader_parameter("alert", amount)


static func module_names() -> Array:
	load_kit()
	return _meshes.keys()
