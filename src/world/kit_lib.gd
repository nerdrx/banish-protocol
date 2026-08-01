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
## noise in nv_surface.gdshader is sampled in WORLD space precisely so that
## sharing the mesh does not mean sharing the look.

const KIT_PATH: String = "res://assets/kit/nullvoid_kit.glb"

## Blender material slot -> engine material. This table IS the art direction
## contract between the mesh author and the look-dev pass; adding a slot in
## build_kit.py means adding a line here.
const MATERIAL_MAP: Dictionary = {
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

	var packed: PackedScene = load(KIT_PATH) as PackedScene
	if packed == null:
		push_error("KitLib: cannot load %s" % KIT_PATH)
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

	var names: Array = _meshes.keys()
	names.sort()
	print("[KitLib] %d modules: %s" % [names.size(), ", ".join(names)])


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
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(mi)
	return mi


static func material(slot: String) -> Material:
	load_kit()
	return _materials.get(slot, null) as Material


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
