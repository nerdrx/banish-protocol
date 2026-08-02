extends Node3D
## Decal albedo probe — the isolation rig for the M4.7 root-cause.
##
##   godot --path . res://src/dev/decal_probe.tscn -- --screenshot /tmp/x.png 90
##
## Three walls side by side, all under the same light, all wearing the same
## decal:
##
##   left    `mat_panel_dark.tres` — the kit's ShaderMaterial (nv_surface)
##   middle  a StandardMaterial3D authored to the same albedo
##   right   the ShaderMaterial again, but with a bright albedo decal and NO
##           emission texture at all
##
## If the middle wall shows a printed sign and the left one does not, the fault
## is the custom shader. If neither does, the fault is the Decal setup. If both
## do, the fault was in the content all along.

const WALL: Vector3 = Vector3(5.0, 4.0, 0.4)


func _ready() -> void:
	var albedo: Texture2D = load("res://assets/decals/prop_mercy.png") as Texture2D
	var emission: Texture2D = load("res://assets/decals/prop_mercy_e.png") as Texture2D

	_wall(Vector3(-5.6, 2.0, 0.0), load("res://assets/materials/mat_panel_dark.tres") as Material)
	_wall(Vector3(0.0, 2.0, 0.0), _standard())
	_wall(Vector3(5.6, 2.0, 0.0), load("res://assets/materials/mat_panel_dark.tres") as Material)

	_decal(Vector3(-5.6, 2.0, 0.3), albedo, emission)
	_decal(Vector3(0.0, 2.0, 0.3), albedo, emission)
	_decal(Vector3(5.6, 2.0, 0.3), albedo, null)

	var floor_mesh: MeshInstance3D = MeshInstance3D.new()
	var plane: BoxMesh = BoxMesh.new()
	plane.size = Vector3(30.0, 0.4, 14.0)
	floor_mesh.mesh = plane
	floor_mesh.position = Vector3(0.0, -0.2, 5.0)
	floor_mesh.material_override = load("res://assets/materials/mat_floor_plate.tres") as Material
	add_child(floor_mesh)

	var key: SpotLight3D = SpotLight3D.new()
	key.position = Vector3(0.0, 5.0, 7.0)
	key.light_energy = 6.0
	key.spot_range = 24.0
	key.spot_angle = 70.0
	key.shadow_enabled = false
	add_child(key)
	# -Z is a light's emission axis, so `use_model_front` stays false here.
	key.look_at(Vector3(0.0, 2.0, 0.0), Vector3.UP)
	print("[Probe] key forward=%s (want roughly toward -Z/-Y)" % str(
			(-key.global_transform.basis.z).snapped(Vector3.ONE * 0.01)))

	# The same question asked of the production rig: does a LightRig fixture aimed
	# at a target actually emit toward it? A Light3D emits along its own -Z.
	var rig: SpotLight3D = LightRig.key(self, Vector3(0.0, 12.0, 0.0),
			Vector3(0.0, 0.0, -6.0), 0.0, "", 40.0, LightRig.KEY_COLD, 4.0, false)
	print("[Probe] LightRig.key at (0,12,0) -> (0,0,-6): emits %s   (want ~(0,-0.89,-0.44))" % str(
			(-rig.global_transform.basis.z).snapped(Vector3.ONE * 0.01)))

	var camera: Camera3D = Camera3D.new()
	camera.position = Vector3(0.0, 2.2, 9.0)
	camera.current = true
	add_child(camera)


func _wall(at: Vector3, material: Material) -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = WALL
	mesh.mesh = box
	mesh.position = at
	mesh.material_override = material
	add_child(mesh)


func _standard() -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color(0.095, 0.101, 0.114)
	material.roughness = 0.8
	material.metallic = 0.0
	return material


func _decal(at: Vector3, albedo: Texture2D, emission: Texture2D) -> void:
	var decal: Decal = Decal.new()
	decal.texture_albedo = albedo
	if emission != null:
		decal.texture_emission = emission
		decal.emission_energy = 0.9
	decal.size = Vector3(4.0, 0.9, 1.0)
	decal.upper_fade = 0.25
	decal.lower_fade = 0.25
	decal.normal_fade = 0.0
	decal.position = at
	decal.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	add_child(decal)
