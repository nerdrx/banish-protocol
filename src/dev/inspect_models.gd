extends SceneTree
## Prints the engine-side contract of every model in assets/models: node tree,
## surfaces + material names in order, skeleton bones, animations, AABB.

func _dump(node: Node, depth: int) -> void:
	var pad: String = "  ".repeat(depth)
	print("%s%s [%s]" % [pad, node.name, node.get_class()])
	var mi: MeshInstance3D = node as MeshInstance3D
	if mi != null and mi.mesh != null:
		var tris: int = 0
		for i: int in mi.mesh.get_surface_count():
			var mat: Material = mi.mesh.surface_get_material(i)
			var arrays: Array = mi.mesh.surface_get_arrays(i)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			tris += idx.size() / 3
			print("%s  surface %d: '%s'" % [pad, i, "null" if mat == null else mat.resource_name])
		print("%s  aabb=%s tris=%d" % [pad, str(mi.mesh.get_aabb()), tris])
	var skel: Skeleton3D = node as Skeleton3D
	if skel != null:
		print("%s  bones=%d" % [pad, skel.get_bone_count()])
		var names: PackedStringArray = PackedStringArray()
		for i: int in skel.get_bone_count():
			names.append(skel.get_bone_name(i))
		print("%s  bone_names=%s" % [pad, ", ".join(names)])
	var ap: AnimationPlayer = node as AnimationPlayer
	if ap != null:
		for a: String in ap.get_animation_list():
			var anim: Animation = ap.get_animation(a)
			print("%s  anim '%s' len=%.3f loop=%d tracks=%d" % [
				pad, a, anim.length, int(anim.loop_mode), anim.get_track_count()])
	for child: Node in node.get_children():
		_dump(child, depth + 1)


func _init() -> void:
	for path: String in ["res://assets/models/scrubber.glb", "res://assets/models/surge.glb",
			"res://assets/models/sentinel_kit.glb", "res://assets/models/sentinel.glb",
			"res://assets/models/crew_avatar.glb", "res://assets/models/hound.glb"]:
		if not ResourceLoader.exists(path):
			print("\n===== %s : MISSING =====" % path)
			continue
		print("\n===== %s =====" % path)
		var packed: PackedScene = load(path) as PackedScene
		if packed == null:
			print("  FAILED TO LOAD")
			continue
		var root: Node = packed.instantiate()
		_dump(root, 1)
		root.free()
	quit()
