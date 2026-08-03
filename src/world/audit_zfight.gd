class_name AuditZFight
extends RefCounted
## `--auditz` — the coplanar-surface sweep. The instrument behind the live
## playtest report "we also got some visible z fighting issues in parts of the
## maps".
##
## ## Why a geometric audit and not a screenshot hunt
##
## Z-fighting is the one rendering bug that a capture is nearly useless against.
## It is view-dependent, distance-dependent and frame-dependent: the pair of
## surfaces that shimmers when you stand at one end of a bus hall is rock steady
## from the other end, and a 240-frame settle picks whichever of the two happened
## to win the depth test on that frame. Hunting it by eye finds the instance you
## were standing in front of and never the RULE that produced it — and the rule
## is what matters, because a generator that puts one plate flush on one wall
## puts a thousand plates flush on a thousand walls.
##
## So this asks the question in the domain where it has a crisp answer:
##
##     WHERE DO TWO OPAQUE, SAME-FACING, NEARLY-COPLANAR FACES OVERLAP?
##
## That is a purely geometric property of the built scene, it is deterministic,
## and it is decidable before anything is ever rendered — which also means the
## audit runs headless in a couple of seconds over a whole seed/layer matrix and
## can gate a merge the way `--auditvert` and `--deckwalk` already do.
##
## ## The three conditions, and why each one is needed
##
##   SAME FACING. Two coplanar faces pointing OPPOSITE ways are the normal case
##   in any solid-modelled kit: a floor slab's top meets a plinth's bottom at
##   exactly one plane, and backface culling means only ever one of them is
##   drawn. Testing coplanarity alone reports every abutment in the building —
##   thousands of findings, none of them bugs. Facing is the filter that turns
##   this from noise into a bug list.
##
##   NEARLY COPLANAR, not exactly. Exact coincidence is the worst case but it is
##   not the only one: the depth buffer's resolution at 40 m with a 0.05 m near
##   plane is coarse enough that a 2 mm standoff still flickers. `EPS` is set
##   from that, not from taste — see the constant.
##
##   OVERLAPPING IN PLANE. Two wall modules side by side share a plane and touch
##   at an edge; that is the kit working. Only real overlapping AREA can shimmer,
##   and `MIN_AREA` drops the slivers so the table lists things a player can see.
##
## ## What it does not claim
##
## Coplanar patches are merged into their bounding rect per (node, plane), so an
## L-shaped face is over-reported as its box. In this kit that is rare and it
## errs toward listing something rather than hiding it, which is the right way
## for an audit to be wrong.
##
##     -- --auditz            the standing seed/layer matrix, plus the hub
##     -- --auditz SEED LAYER one layer, verbose: every finding, not the top 12
##
## Exits non-zero on any finding, so CI and `--selftest` can hold the line.

# --- thresholds --------------------------------------------------------------

## How close two same-facing planes have to be before the depth buffer stops
## being able to keep them apart.
##
## NOT a taste number. The project runs a 0.05 m near plane and a 220 m far
## plane (FreecamProbe, and Player's own lens matches), on a 24-bit reversed-Z
## buffer. Depth precision at distance d is roughly `d^2 * (1/near - 1/far) /
## 2^24` for a standard buffer; at the 40 m across a bus hall that is under a
## tenth of a millimetre, but the value that actually governs is INTERPOLATION
## error across a large triangle plus the 16-bit precision the shadow atlas and
## the SSAO/SSIL depth prepass work at. Measured empirically instead: 1 mm
## standoffs still shimmered on the far wall of the machine hall at 3440x1440,
## 4 mm did not. So 4 mm is the reporting threshold and `STANDOFF` below is what
## the fixes use.
const EPS: float = 0.004

## The separation a fix applies. One millimetre more than `EPS` would be cutting
## it fine; 6 mm is invisible at 30 cm (it is a third of the kit's smallest
## chamfer) and unambiguous to the depth buffer at 40 m.
const STANDOFF: float = 0.006

## Overlapping area below this is a sliver at a shared edge, not a surface a
## player can watch flicker.
const MIN_AREA: float = 0.02

## A face counts as axis-aligned when its normal is this close to an axis.
## Everything the kit builds is boxes and chamfers; the chamfer facets are
## deliberately NOT axis-aligned and drop out here, which is correct — a 45
## degree bevel facet cannot be coplanar with the wall it is easing.
const AXIS_DOT: float = 0.999

## Instances scanned per MultiMesh. A greeble batch can hold thousands and the
## sweep is O(bucket^2); the batches are built from one authored vocabulary, so
## the first few hundred contain every distinct relationship the rest repeat.
const MULTIMESH_CAP: int = 400

## The standing matrix. Same shape as the verticality audit's, and deliberately
## the same seeds, so a finding here can be looked at with `--auditvert` and
## `--deckwalk` on the identical layer.
const SEEDS: Array[int] = [4242, 90210, 1337, 7, 55555]
const LAYERS: Array[int] = [1, 3, 7, 12, 18]


# --- collection --------------------------------------------------------------

## Triangles allowed in one plane bucket before the exact polygon merge gives up
## and the patch falls back to its bounding rect. Box faces are two triangles; a
## kit module's coplanar face is a handful. Only a pathological mesh reaches this,
## and for those an over-reported bbox is the right way to be wrong.
const MERGE_TRI_CAP: int = 48


## One merged planar patch: `axis` 0/1/2, `sign` +1/-1, `d` the plane coordinate,
## `rect` its bounding extent in the other two axes (broad phase only), `poly`
## its true outline, `area` its true area, `owner` a unique instance id and
## `label` the descriptive class.
##
## THE POLYGON IS NOT OPTIONAL AND THE SECOND RUN OF THIS AUDIT IS WHY. A bounding
## rect is exact for an axis-aligned box face and a lie for anything rotated: the
## nest's diagonal "growth" strands are 7 cm boxes turned 45 degrees about Y, and
## the bounding rect of such a strand's top face is 4.4 m square. Two of them
## crossing were reported as a 15.77 m2 coplanar overlap when the surfaces
## actually share about fifty square centimetres. An audit whose worst finding is
## an artefact of its own broad phase cannot be used to drive fixes.
##
## THE TWO NAMES ARE NOT REDUNDANT AND THE FIRST RUN OF THIS AUDIT IS WHY. Almost
## every box the kit builds goes through `GeometryKit._mesh_box`, which does not
## name its node — so Godot hands out `@MeshInstance3D@1334` and the class census
## came back as 1416 findings between anonymous integers, which is a bug count
## with no bug in it. What actually identifies a surface here is WHAT IT IS MADE
## OF and HOW BIG IT IS: `mat_panel_trim[4.00x0.12x0.06]` is a baseboard run and
## `mat_floor_plate[40.40x0.40x40.40]` is a room slab, and a class naming those
## two points straight at the line of code that made them. `owner` stays unique
## so a patch is never compared against itself.
static func _patch(axis: int, sign_v: int, d: float, rect: Rect2,
		poly: Array[PackedVector2Array], area: float,
		owner: String, label: String) -> Dictionary:
	return {"axis": axis, "sign": sign_v, "d": d, "rect": rect, "poly": poly,
			"area": area, "owner": owner, "label": label}


## Shoelace. Negative for a clockwise ring, which is how `Geometry2D` marks a
## hole — so summing signed areas over a merge result gives the filled area for
## free instead of counting holes twice.
static func poly_area(poly: PackedVector2Array) -> float:
	var sum: float = 0.0
	var n: int = poly.size()
	for i: int in n:
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % n]
		sum += a.x * b.y - b.x * a.y
	return sum * 0.5


static func total_area(polys: Array[PackedVector2Array]) -> float:
	var sum: float = 0.0
	for p: PackedVector2Array in polys:
		sum += poly_area(p)
	return absf(sum)


## What a renderable is made of and how big it is — the descriptive half of a
## finding. Material stem plus the mesh's own local size, so two instances of the
## same authored element share a label wherever they stand.
static func label_for(gi: GeometryInstance3D, mesh: Mesh,
		xform: Transform3D) -> String:
	var mat: Material = gi.material_override
	if mat == null and mesh != null and mesh.get_surface_count() > 0:
		mat = mesh.surface_get_material(0)
	var stem: String = "?"
	if mat != null and not mat.resource_path.is_empty():
		stem = mat.resource_path.get_file().get_basename()
	elif mat != null:
		stem = mat.get_class()
	# A named node beats a material every time — the vertical vocabulary and the
	# kit modules both name themselves, and `Vert_deck` is more use than
	# `mat_panel_dark`.
	var node_name: String = String(gi.name)
	if not node_name.begins_with("@"):
		stem = node_name
	var size: Vector3 = Vector3.ZERO
	if mesh != null:
		var aabb: AABB = mesh.get_aabb()
		size = aabb.size * xform.basis.get_scale()
	return "%s[%.2fx%.2fx%.2f]" % [stem, size.x, size.y, size.z]


## The two axes that span the plane perpendicular to `axis`.
static func _plane_axes(axis: int) -> Vector2i:
	match axis:
		0:
			return Vector2i(1, 2)
		1:
			return Vector2i(0, 2)
		_:
			return Vector2i(0, 1)


## Pull every axis-aligned triangle out of one mesh under one transform and fold
## it into the per-plane table. Keyed by (axis, sign, millimetre) so the two
## triangles of a box face land in the same bucket and merge.
static func _harvest(mesh: Mesh, xform: Transform3D, owner: String,
		label: String, into: Dictionary) -> void:
	if mesh == null:
		return
	var tris: PackedVector3Array = mesh.get_faces()
	var count: int = tris.size() / 3
	for t: int in count:
		var a: Vector3 = xform * tris[t * 3]
		var b: Vector3 = xform * tris[t * 3 + 1]
		var c: Vector3 = xform * tris[t * 3 + 2]
		var n: Vector3 = (b - a).cross(c - a)
		if n.length_squared() < 1e-12:
			continue
		n = n.normalized()
		var axis: int = -1
		var sign_v: int = 0
		for k: int in 3:
			if absf(n[k]) >= AXIS_DOT:
				axis = k
				sign_v = 1 if n[k] > 0.0 else -1
				break
		if axis < 0:
			continue
		var d: float = a[axis]
		var span: Vector2i = _plane_axes(axis)
		# Wound consistently in plane space. `Geometry2D`'s boolean ops treat
		# winding as meaning (counter-clockwise is filled, clockwise is a hole), so
		# a triangle set that arrives with mixed winding merges into holes and the
		# patch loses most of its area. Flipping to positive shoelace here is
		# cheaper and less error-prone than reasoning about which of the six box
		# faces the plane projection mirrors.
		var tri: PackedVector2Array = PackedVector2Array([
			Vector2(a[span.x], a[span.y]),
			Vector2(b[span.x], b[span.y]),
			Vector2(c[span.x], c[span.y])])
		if poly_area(tri) < 0.0:
			tri.reverse()
		var key: String = "%d|%d|%d" % [axis, sign_v, int(roundf(d * 1000.0))]
		if not into.has(key):
			into[key] = {"axis": axis, "sign": sign_v, "d": d,
					"tris": [] as Array[PackedVector2Array],
					"owner": owner, "label": label}
		var bucket: Dictionary = into[key]
		(bucket["tris"] as Array[PackedVector2Array]).append(tri)


## Union the triangles in one plane bucket into real outlines. A box face's two
## triangles become one quad; two separate plates on the same plane stay two
## polygons, which is what keeps them from being reported as one big overlap.
static func _merge(tris: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	if tris.size() > MERGE_TRI_CAP:
		# Fall back to the bounding box of the lot. Over-reports; see MERGE_TRI_CAP.
		var box: Rect2 = Rect2(tris[0][0], Vector2.ZERO)
		for t: PackedVector2Array in tris:
			for v: Vector2 in t:
				box = box.expand(v)
		out.append(PackedVector2Array([box.position,
				Vector2(box.end.x, box.position.y), box.end,
				Vector2(box.position.x, box.end.y)]))
		return out
	for t: PackedVector2Array in tris:
		var merged: bool = false
		for i: int in out.size():
			var union: Array[PackedVector2Array] = Geometry2D.merge_polygons(out[i], t)
			# A disjoint pair comes back as the two inputs unchanged; only a genuine
			# union collapses to one ring. Anything else (a hole, a self-touching
			# result) is left alone rather than guessed at.
			if union.size() == 1:
				out[i] = union[0]
				merged = true
				break
		if not merged:
			out.append(t)
	return out


## Whether a surface participates in the depth fight at all. Transparent and
## additive materials are drawn after the depth prepass without writing depth, so
## they cannot z-fight — and the beam, the haze cards and the hologram panels are
## all in that set. Reporting them is how an audit gets a reputation for crying
## wolf.
static func _opaque(node: GeometryInstance3D) -> bool:
	if node.material_override != null:
		return _material_opaque(node.material_override)
	var mesh: Mesh = null
	if node is MeshInstance3D:
		mesh = (node as MeshInstance3D).mesh
	elif node is MultiMeshInstance3D:
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		mesh = mm.mesh if mm != null else null
	if mesh == null:
		return false
	for s: int in mesh.get_surface_count():
		if _material_opaque(mesh.surface_get_material(s)):
			return true
	return false


static func _material_opaque(mat: Material) -> bool:
	if mat == null:
		return true
	if mat is StandardMaterial3D:
		var std: StandardMaterial3D = mat as StandardMaterial3D
		return std.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED
	if mat is ShaderMaterial:
		# The kit's surface shaders are all opaque; the transparent ones in this
		# project are StandardMaterial3D (`_make_hologram`) or their own shader
		# with `render_mode blend_add`, which never reaches this path because the
		# nodes carrying it are not in the geometry tree.
		return true
	return true


# --- burial -------------------------------------------------------------------
#
# THE FILTER THAT TURNS THIS AUDIT FROM A CURIOSITY INTO A BUG LIST.
#
# The first honest run reported 931,751 findings on one layer. They were real
# coplanar same-facing overlaps and almost none of them were bugs, because the
# overwhelming majority were DOWNWARD-FACING faces buried inside the floor: a
# 10 cm conduit plate bedded into a 31 cm floor tile shares its underside plane
# with the tile's underside, both facing -Y, both entirely enclosed in solid
# material. Nothing renders there and nothing can flicker there.
#
# A surface can only z-fight if it can be SEEN, so a patch whose front side is
# inside another solid is dropped before it is ever paired. The test is a point
# sample a few centimetres off the face against a spatial hash of every opaque
# renderable's world AABB — cheap, because it runs per patch (tens of thousands)
# rather than per pair (hundreds of thousands).
#
# It is deliberately CONSERVATIVE: a patch is only dropped when EVERY sample is
# buried. A half-buried plate stays in the report, because half of it is visible
# and half of it is what the player is watching shimmer.

## How far off the face the burial samples sit. Larger than any coplanarity we
## care about, smaller than the thinnest plate in the kit.
const BURIAL_PROBE: float = 0.03

## Spatial hash cell for the AABB index. Two metres is half the kit's cell, so a
## query touches a handful of boxes.
const HASH_CELL: float = 2.0

## Samples taken across a patch before it is called buried.
const BURIAL_SAMPLES: int = 5


static func _hash_key(at: Vector3) -> Vector3i:
	return Vector3i(int(floorf(at.x / HASH_CELL)), int(floorf(at.y / HASH_CELL)),
			int(floorf(at.z / HASH_CELL)))


## Index every opaque renderable's world AABB by hash cell.
static func _solid_index(root: Node) -> Dictionary:
	var index: Dictionary = {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children():
			stack.append(child)
		var gi: GeometryInstance3D = node as GeometryInstance3D
		if gi == null or not gi.visible or not _opaque(gi):
			continue
		var owner: String = str(gi.get_instance_id())
		var boxes: Array[Dictionary] = []
		if gi is MeshInstance3D:
			var mesh: Mesh = (gi as MeshInstance3D).mesh
			if mesh != null:
				boxes.append({"aabb": gi.global_transform * mesh.get_aabb(),
						"owner": owner})
		elif gi is MultiMeshInstance3D:
			var mm: MultiMesh = (gi as MultiMeshInstance3D).multimesh
			if mm != null and mm.mesh != null:
				var base: AABB = mm.mesh.get_aabb()
				for i: int in mini(mm.instance_count, MULTIMESH_CAP):
					var xf: Transform3D = gi.global_transform * mm.get_instance_transform(i)
					boxes.append({"aabb": xf * base, "owner": "%s#%d" % [owner, i]})
		for box: Dictionary in boxes:
			var aabb: AABB = box["aabb"]
			var lo: Vector3i = _hash_key(aabb.position)
			var hi: Vector3i = _hash_key(aabb.end)
			# A very large solid (a room's floor slab) spans a lot of cells; that is
			# the price of a uniform grid and it is paid once at build time.
			for x: int in range(lo.x, hi.x + 1):
				for y: int in range(lo.y, hi.y + 1):
					for z: int in range(lo.z, hi.z + 1):
						var key: Vector3i = Vector3i(x, y, z)
						if not index.has(key):
							index[key] = [] as Array[Dictionary]
						(index[key] as Array[Dictionary]).append(box)
	return index


## Whether `at` sits inside some opaque solid other than `exclude`.
static func _inside_solid(index: Dictionary, at: Vector3, exclude: String) -> bool:
	var here: Array[Dictionary] = index.get(_hash_key(at), [] as Array[Dictionary])
	for box: Dictionary in here:
		if String(box["owner"]) == exclude:
			continue
		# Shrunk by a hair so a face merely COPLANAR with this box's surface is not
		# counted as inside it — that case is the fight, not an occlusion.
		if (box["aabb"] as AABB).grow(-0.002).has_point(at):
			return true
	return false


## Whether every sample across this patch's front side is inside solid material.
static func buried(index: Dictionary, patch: Dictionary) -> bool:
	var axis: int = int(patch["axis"])
	var span: Vector2i = _plane_axes(axis)
	var d: float = float(patch["d"]) + float(patch["sign"]) * BURIAL_PROBE
	var rect: Rect2 = patch["rect"]
	var owner: String = String(patch["owner"])
	var ring: PackedVector2Array = (patch["poly"] as Array[PackedVector2Array])[0]
	var spots: Array[Vector2] = [rect.position + rect.size * 0.5]
	# Corners pulled well inside, plus real vertices pulled toward the centroid —
	# a bounding-box corner of a non-convex outline can sit outside the surface.
	for k: int in mini(ring.size(), BURIAL_SAMPLES - 1):
		spots.append(ring[k].lerp(spots[0], 0.25))
	for spot: Vector2 in spots:
		var at: Vector3 = Vector3.ZERO
		at[axis] = d
		at[span.x] = spot.x
		at[span.y] = spot.y
		if not _inside_solid(index, at, owner):
			return false
	return true


## Whether the shared region between two patches is inside solid material — and
## therefore cannot be seen fighting no matter how coplanar it is.
##
## NO OWNER IS EXCLUDED HERE, unlike the patch-level test, and the room corner is
## the reason. Two perpendicular wall modules 0.56 m deep must overlap in a
## 0.28 m square where their runs meet, and each module's recessed-panel faces
## are coplanar with the other's inside that square. Both patches are mostly out
## in the room, so neither is buried as a whole; the SLIVER they share is inside
## the neighbouring module's body, and the neighbour is one of the two being
## judged. Excluding it hid the only solid that was doing the occluding.
##
## Not excluding anyone is safe for a genuine fight: when two surfaces really do
## share a visible plane, that plane is at or outside both bodies' own boundary,
## so a sample 3 cm further out is outside both AABBs and the finding stands.
static func _overlap_buried(clipped: Array[PackedVector2Array], axis: int,
		sign_v: int, d: float, owner_a: String, owner_b: String) -> bool:
	if last_index.is_empty():
		return false
	var span: Vector2i = _plane_axes(axis)
	var front: float = d + float(sign_v) * BURIAL_PROBE
	for ring: PackedVector2Array in clipped:
		var box: Rect2 = Rect2(ring[0], Vector2.ZERO)
		for v: Vector2 in ring:
			box = box.expand(v)
		var spots: Array[Vector2] = [box.position + box.size * 0.5]
		for k: int in mini(ring.size(), BURIAL_SAMPLES - 1):
			spots.append(ring[k].lerp(spots[0], 0.25))
		for spot: Vector2 in spots:
			var at: Vector3 = Vector3.ZERO
			at[axis] = front
			at[span.x] = spot.x
			at[span.y] = spot.y
			var here: Array[Dictionary] = last_index.get(_hash_key(at),
					[] as Array[Dictionary])
			var covered: bool = false
			for solid: Dictionary in here:
				if (solid["aabb"] as AABB).grow(-0.002).has_point(at):
					covered = true
					break
			if not covered:
				return false
	return true


## Walk a subtree and return every merged planar patch in it.
static func collect(root: Node) -> Array[Dictionary]:
	var patches: Array[Dictionary] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children():
			stack.append(child)
		var gi: GeometryInstance3D = node as GeometryInstance3D
		if gi == null or not gi.visible or not _opaque(gi):
			continue
		# `get_instance_id` rather than the node name: `_mesh_box` leaves its nodes
		# unnamed, so thousands of them answer to `@MeshInstance3D@N` — unique in
		# practice, but only by accident of Godot's counter. The object id is unique
		# by contract, which is what the self-comparison guard needs.
		var owner: String = str(gi.get_instance_id())
		if gi is MeshInstance3D:
			var mesh: Mesh = (gi as MeshInstance3D).mesh
			var table: Dictionary = {}
			_harvest(mesh, gi.global_transform, owner,
					label_for(gi, mesh, gi.global_transform), table)
			_drain(table, patches)
		elif gi is MultiMeshInstance3D:
			var mm: MultiMesh = (gi as MultiMeshInstance3D).multimesh
			if mm != null and mm.mesh != null:
				var n: int = mini(mm.instance_count, MULTIMESH_CAP)
				for i: int in n:
					# A TABLE PER INSTANCE, and the first run of this audit is why.
					# Sharing one table across a batch merged coplanar rects from
					# DIFFERENT instances into one patch — a 0.07 m trace inlay came
					# back as a 15.77 m2 face — and stamped it with whichever
					# instance happened to open the bucket, so the self-comparison
					# guard was comparing the wrong things. Two boxes inside one
					# batch can genuinely fight each other; they have to stay
					# separate patches to be seen doing it.
					var xf: Transform3D = gi.global_transform * mm.get_instance_transform(i)
					var per: Dictionary = {}
					_harvest(mm.mesh, xf, "%s#%d" % [owner, i],
							label_for(gi, mm.mesh, xf), per)
					_drain(per, patches)

	# Drop everything that cannot be seen. See the burial section above: this is
	# the difference between 931,751 findings and a bug list.
	var index: Dictionary = _solid_index(root)
	var visible: Array[Dictionary] = []
	for p: Dictionary in patches:
		if not buried(index, p):
			visible.append(p)
	# The index rides along so `findings` can run the same test on the OVERLAP
	# region — see the note there.
	last_index = index
	return visible


## The solid index built by the most recent `collect`. A return value in spirit;
## a static because threading it through the probe's call chain would put an
## implementation detail of the burial test into the harness's signature.
static var last_index: Dictionary = {}


## Merge one node's (or one instance's) plane table and append the survivors.
static func _drain(table: Dictionary, patches: Array[Dictionary]) -> void:
	for key: String in table:
		var bucket: Dictionary = table[key]
		for ring: PackedVector2Array in _merge(bucket["tris"] as Array[PackedVector2Array]):
			var area: float = absf(poly_area(ring))
			if area < MIN_AREA:
				continue
			var box: Rect2 = Rect2(ring[0], Vector2.ZERO)
			for v: Vector2 in ring:
				box = box.expand(v)
			var poly: Array[PackedVector2Array] = [ring]
			patches.append(_patch(int(bucket["axis"]), int(bucket["sign"]),
					float(bucket["d"]), box, poly, area,
					String(bucket["owner"]), String(bucket["label"])))


# --- the sweep ---------------------------------------------------------------

## Every same-facing near-coplanar overlapping pair among `patches`.
##
## Bucketed by plane coordinate at `EPS` granularity and compared against the
## neighbouring bucket too, so the sweep is near-linear instead of the 10^10 pair
## tests a layer's worth of patches would otherwise be.
static func findings(patches: Array[Dictionary]) -> Array[Dictionary]:
	var buckets: Dictionary = {}
	for i: int in patches.size():
		var p: Dictionary = patches[i]
		var slot: int = int(floorf(float(p["d"]) / EPS))
		var key: String = "%d|%d|%d" % [int(p["axis"]), int(p["sign"]), slot]
		if not buckets.has(key):
			buckets[key] = [] as Array[int]
		(buckets[key] as Array[int]).append(i)

	var found: Array[Dictionary] = []
	var seen: Dictionary = {}
	for key: String in buckets:
		var parts: PackedStringArray = key.split("|")
		var axis: int = parts[0].to_int()
		var sign_v: int = parts[1].to_int()
		var slot: int = parts[2].to_int()
		var here: Array[int] = buckets[key]
		var neighbour: Array[int] = buckets.get(
				"%d|%d|%d" % [axis, sign_v, slot + 1], [] as Array[int])
		var pool: Array[int] = []
		pool.append_array(here)
		pool.append_array(neighbour)
		for ai: int in here.size():
			for bi: int in range(ai + 1, pool.size()):
				var a: Dictionary = patches[here[ai]]
				var b: Dictionary = patches[pool[bi]]
				if String(a["owner"]) == String(b["owner"]):
					continue
				var gap: float = absf(float(a["d"]) - float(b["d"]))
				if gap > EPS:
					continue
				var ra: Rect2 = a["rect"]
				var rb: Rect2 = b["rect"]
				# Broad phase. A bbox miss is a definite miss; a bbox hit still has
				# to survive the exact test below.
				if not ra.intersects(rb):
					continue
				var overlap: Rect2 = ra.intersection(rb)
				if overlap.size.x * overlap.size.y < MIN_AREA:
					continue
				# Narrow phase: the real shared surface.
				var clipped: Array[PackedVector2Array] = Geometry2D.intersect_polygons(
						(a["poly"] as Array[PackedVector2Array])[0],
						(b["poly"] as Array[PackedVector2Array])[0])
				var area: float = total_area(clipped)
				if area < MIN_AREA:
					continue
				# IS THE SHARED PART VISIBLE? Patch-level burial is not enough, and
				# the corner of every room is why. Two perpendicular wall modules
				# each 0.56 m deep must overlap in a 0.28 m square where their runs
				# meet; each module's internal horizontal detail faces are mostly
				# out in the open (so neither patch is buried) while the SLIVER they
				# share is entirely inside the other module's solid. That produced
				# ~5,000 findings of 0.05 m2 apiece across the matrix, all of them
				# in geometry no light ever reaches. The question a z-fight audit is
				# actually asking is whether the SHARED SURFACE renders, so the test
				# belongs on the overlap.
				if _overlap_buried(clipped, axis, sign_v, float(a["d"]),
						String(a["owner"]), String(b["owner"])):
					continue
				var pair: String = "%s~%s~%d~%d" % [
					mini_name(String(a["owner"]), String(b["owner"])),
					maxi_name(String(a["owner"]), String(b["owner"])),
					axis, int(roundf(float(a["d"]) * 100.0))]
				if seen.has(pair):
					continue
				seen[pair] = true
				found.append({
					"axis": axis, "sign": sign_v, "gap": gap, "area": area,
					"a": String(a["label"]), "b": String(b["label"]),
					# The two instance ids and their in-plane extents. Only printed
					# in single-layer verbose mode, and there because the first
					# baseboard class came back with 4187 findings at one identical
					# coordinate and the table could not say whether that was one
					# bug reported 4187 times or a broken instrument.
					"ids": "%s/%s" % [String(a["owner"]), String(b["owner"])],
					"ra": a["rect"], "rb": b["rect"],
					"at": _centre(axis, float(a["d"]), overlap),
				})
	return found


static func mini_name(a: String, b: String) -> String:
	return a if a < b else b


static func maxi_name(a: String, b: String) -> String:
	return b if a < b else a


static func _centre(axis: int, d: float, overlap: Rect2) -> Vector3:
	var span: Vector2i = _plane_axes(axis)
	var mid: Vector2 = overlap.position + overlap.size * 0.5
	var out: Vector3 = Vector3.ZERO
	out[axis] = d
	out[span.x] = mid.x
	out[span.y] = mid.y
	return out


## The class a finding belongs to — the stem of both node names, digits and
## Godot's `@Name@2` duplicate sigil stripped. Fixes are made per CLASS; a class
## with one member is bad luck, a class with forty is a rule nobody wrote.
static func class_of(finding: Dictionary) -> String:
	var a: String = _stem(String(finding["a"]))
	var b: String = _stem(String(finding["b"]))
	return "%s vs %s" % [mini_name(a, b), maxi_name(a, b)]


## The class name of one side. Godot's `@Name@2` duplicate sigil and the trailing
## digits `_flush_detail` adds to disambiguate batches both get stripped, so
## `Vert_rail7[...]` and `Vert_rail[...]` are one class — the same stem rule
## `--auditvert` uses.
static func _stem(label: String) -> String:
	var bracket: int = label.find("[")
	var name: String = label.substr(0, bracket) if bracket >= 0 else label
	var dims: String = label.substr(bracket) if bracket >= 0 else ""
	var sigil: int = name.find("@")
	if sigil >= 0:
		name = name.substr(0, sigil)
	return name.rstrip("0123456789") + dims
