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
## The small dip between clips on a wall loom. A clipped cable barely sags — the
## deep true-catenary curve is reserved for the runs that actually HANG (see below).
const CABLE_SAG: float = 0.045

## M4.95 catenary rewrite (HUB_NOTES §9). Cables hang on a TRUE catenary now
## (y = a·cosh), not a parabola with a hand-authored sag, so the sag scales with
## span for free and two runs in one frame no longer read as decoration. The only
## handle is `slack` — the fraction by which the cable is longer than the straight
## line between its ends, i.e. how much cable somebody paid out. Tension tells the
## story: a taut feed is slack ~0.006, a dead-weight bundle sags at ~0.06.
const SLACK_WALL_LOOM: float = 0.028
const SLACK_FEED: float = 0.006
const SLACK_BUNDLE: float = 0.060

## Motivated motion (DESIGN.md pillar 6; HUB_NOTES §9). MOTION FOLLOWS CAUSE: there
## is no wind in a sealed machine-space, so nothing sways for free. A cable's motion
## is chosen by what is at its end, not by taste.
##   DEAD     a run bolted to nothing that moves — hangs dead still.
##   VIBRATE  bolted to RUNNING machinery — a fine, fast, low-amplitude tremor.
##   SWAY     in a real draught (a god-ray aperture's open shaft) — a slow, true
##            pendulum sway. Amplitude stays 1-3 cm; at 5 cm it becomes a flag and
##            the sealed bay starts feeling outdoors.
enum Motion { DEAD, VIBRATE, SWAY }
const CABLE_SHADER: String = "res://src/shaders/nv_cable.gdshader"

const PIPE_RADIUS: float = 0.085

static var _grime_cache: Dictionary = {}


## Shared unit meshes. One cylinder and one box for the whole game: every piece
## of clutter is one of those two, scaled. That is what makes the MultiMesh
## batching possible in the first place.
static var _tube_mesh: CylinderMesh = null
static var _chunk_mesh: BoxMesh = null
## The catenary sway shader, loaded once. A moving cable is one generated tube
## mesh with this material; the sway is a single sin() in its vertex stage, so a
## swaying run costs exactly what a static one costs (HUB_NOTES §9).
static var _cable_shader: Shader = null

var _parent: Node3D = null
var _seed: int = 0
## Accumulated instance transforms, per family. Flushed into MultiMeshes once.
var _tubes: Array[Transform3D] = []
var _chunks: Array[Transform3D] = []
## Census, printed with the layer build line: "the world got denser" is a claim,
## and a claim about generation belongs in a log rather than in a screenshot.
var census: Dictionary = {
	"cable": 0, "pipe": 0, "rubble": 0, "crate": 0, "husk": 0, "grime": 0,
	"island": 0, "sway": 0, "duct": 0,
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

	# M4.95: real fixings at both ends, so a loom no longer emerges from bare wall
	# (HUB_NOTES §9). Into the shared MultiMesh, so the hardware is near-free.
	var end_lift: Vector3 = inward * 0.10 + Vector3.UP * CABLE_HEIGHT
	_anchor_hw(from + end_lift, to)
	_anchor_hw(to + end_lift, from)


# ---------------------------------------------------------------- catenary --
#
# HUB_NOTES §9's hanging-matter rewrite, ported. Everything that hangs between two
# anchors — a machinery feed, a cable bundle, a coil dropping to the floor — is a
# TRUE catenary solved from an arc length, not a parabola with a guessed sag: the
# sag then scales with span for free, and two runs in one frame stop reading as
# decoration. The clipped wall looms above stay nearly straight, because a clipped
# cable is; the deep curve is for the runs that actually hang.

## Pins TIME at 0 during automated captures (the game's `Debug.automated`) so a
## round-to-round comparison is not confounded by where the cables were swinging.
## The frozen pose is NOT the rest pose — each run keeps its own phase — which is
## what a still photograph of a room full of hanging cable actually looks like.
static func _frozen() -> float:
	return 1.0 if Debug.automated else 0.0


## Solve sinh(u)/u = k by bracket + bisect (there is no closed form). Monotone for
## k > 1, so a bracket always exists and bisection cannot fail. ~70 sinh calls,
## once, at build time — never a per-frame path.
static func _cat_u(k: float) -> float:
	if k <= 1.000001:
		return 0.0001
	var lo: float = 0.00001
	var hi: float = 1.0
	while sinh(hi) / hi < k and hi < 80.0:
		hi *= 2.0
	for _i: int in 64:
		var mid: float = (lo + hi) * 0.5
		if sinh(mid) / mid < k:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## A true catenary between two anchors, sampled as a polyline. `slack` is the only
## handle — the fraction the cable is longer than the straight chord — so the sag
## comes out proportional to span for free. The s0 term makes an asymmetric run
## (unequal anchor heights) put its low point toward the low end, which the eye is
## extremely good at even when it cannot say why.
static func _catenary(a: Vector3, b: Vector3, slack: float, samples: int = 0) -> Array:
	var ax: Vector2 = Vector2(a.x, a.z)
	var bx: Vector2 = Vector2(b.x, b.z)
	var d: float = ax.distance_to(bx)
	var h: float = b.y - a.y
	var chord: float = a.distance_to(b)
	var n: int = samples if samples > 0 else clampi(int(chord * 1.4) + 4, 6, 22)
	var pts: Array = []
	# A near-vertical drop degenerates — the answer is a straight line, and its
	# character comes from the coil at the bottom, not from the curve.
	if d < 0.10 or chord < 0.02:
		for i: int in n + 1:
			pts.append(a.lerp(b, float(i) / float(n)))
		return pts
	var arc: float = chord * (1.0 + maxf(slack, 0.00005))
	var root: float = sqrt(maxf(arc * arc - h * h, 1e-9))
	var u: float = _cat_u(root / d)
	var aa: float = d / (2.0 * u)
	var q: float = h / root
	# asinh, written out: Godot's is recent enough to be a portability risk.
	var s0: float = d * 0.5 - aa * log(q + sqrt(q * q + 1.0))
	var c: float = a.y - aa * cosh(-s0 / aa)
	for i: int in n + 1:
		var t: float = float(i) / float(n)
		var flat: Vector2 = ax.lerp(bx, t)
		pts.append(Vector3(flat.x, aa * cosh((t * d - s0) / aa) + c, flat.y))
	return pts


## Motion amplitude + period for a cause, position-hashed so it is deterministic
## and so no two runs beat in lockstep. Amplitude stays inside the 1-3 cm band —
## this is air movement in a sealed bay, not wind.
func _motion_params(motion: int, at: Vector3) -> Dictionary:
	match motion:
		Motion.VIBRATE:
			# Running machinery: fast and tiny — a tremor, not a sway.
			return {"amp": lerpf(0.004, 0.010, roll(at, 5501)),
					"period": lerpf(0.35, 0.85, roll(at, 5507))}
		Motion.SWAY:
			# A real draught off an open shaft: slow, 1-3 cm, first pendulum mode.
			return {"amp": lerpf(0.012, 0.028, roll(at, 5513)),
					"period": lerpf(4.0, 9.0, roll(at, 5521))}
		_:
			return {"amp": 0.0, "period": 6.0}


## One ShaderMaterial per hanging run (nv_cable.gdshader). The sway is lateral to
## the run — a cable swings ACROSS its span, never along it — and pinned for
## captures. Zero amplitude collapses to a static-cost material.
func _cable_material(a: Vector3, b: Vector3, amp: float, period: float,
		phase: float) -> ShaderMaterial:
	if _cable_shader == null:
		_cable_shader = load(CABLE_SHADER) as Shader
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = _cable_shader
	m.set_shader_parameter("albedo", Color(0.118, 0.124, 0.138))
	m.set_shader_parameter("anchor_a", a)
	m.set_shader_parameter("anchor_b", b)
	var lat: Vector3 = Vector3(b.z - a.z, 0.0, a.x - b.x)
	m.set_shader_parameter("sway_axis",
			Vector3.RIGHT if lat.length() < 0.05 else lat.normalized())
	m.set_shader_parameter("sway_amp", amp)
	m.set_shader_parameter("sway_period", period)
	m.set_shader_parameter("sway_phase", phase)
	m.set_shader_parameter("frozen", _frozen())
	return m


## A swept tube along a polyline, as ONE mesh and ONE draw call — the only way a
## room can afford a dozen hanging runs. Six radial sides: these are 20-40 mm
## objects and their silhouette is a line. Only runs that actually MOVE go through
## here; dead runs are cheaper still as MultiMesh segments.
func _swept_tube(pts: Array, radius: float, mat: Material, name_hint: String) -> void:
	if pts.size() < 2:
		return
	var n: int = pts.size()
	var rings: Array = []
	for i: int in n:
		var tan: Vector3
		if i == 0:
			tan = pts[1] - pts[0]
		elif i == n - 1:
			tan = pts[i] - pts[i - 1]
		else:
			tan = pts[i + 1] - pts[i - 1]
		tan = tan.normalized()
		var up: Vector3 = Vector3.UP if absf(tan.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
		var rt: Vector3 = tan.cross(up).normalized()
		var vu: Vector3 = rt.cross(tan).normalized()
		var ring: Array = []
		for k: int in 6:
			var ang: float = TAU * float(k) / 6.0
			ring.append(rt * cos(ang) + vu * sin(ang))
		rings.append(ring)
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in n - 1:
		for k: int in 6:
			var k2: int = (k + 1) % 6
			var quad: Array = [
				[pts[i] + rings[i][k] * radius, rings[i][k]],
				[pts[i] + rings[i][k2] * radius, rings[i][k2]],
				[pts[i + 1] + rings[i + 1][k2] * radius, rings[i + 1][k2]],
				[pts[i + 1] + rings[i + 1][k] * radius, rings[i + 1][k]]]
			for idx: int in [0, 1, 2, 0, 2, 3]:
				st.set_normal(quad[idx][1])
				st.add_vertex(quad[idx][0])
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = name_hint
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# The sway shader moves vertices the CPU-side AABB does not know about.
	mi.extra_cull_margin = 0.3
	_parent.add_child(mi)


## FIXINGS. Nothing terminates into bare wall: a hanging cable is only believable
## if the eye can find the thing holding it up. Bolt plate + eyebolt ring + shank,
## into the shared MultiMesh so the hardware is near-free.
func _anchor_hw(at: Vector3, toward: Vector3) -> void:
	var dir: Vector3 = toward - at
	dir.y = 0.0
	dir = Vector3.FORWARD if dir.length() < 0.05 else dir.normalized()
	var yaw: float = atan2(dir.x, dir.z)
	_chunk(at + dir * 0.05, Vector3(0.13, 0.16, 0.03), yaw)
	_chunk(at - dir * 0.055, Vector3(0.05, 0.085, 0.05), yaw)
	_tube(at + dir * 0.05, at - dir * 0.05, 0.014)


## Where a cable reaches the floor it does not stop — it is left in a lazy coil,
## slightly elliptical with a decaying radius, so the spiral is something dropped
## rather than something wound. Dead, so it goes into the batched MultiMesh.
func _coil(centre: Vector3, r0: float, r1: float, turns: float) -> void:
	var n: int = int(turns * 12.0)
	var prev: Vector3 = Vector3.ZERO
	for i: int in n + 1:
		var t: float = float(i) / float(n)
		var ang: float = t * turns * TAU
		var r: float = lerpf(r0, r1, t)
		var p: Vector3 = centre + Vector3(cos(ang) * r,
				CABLE_RADIUS + sin(ang * 1.7) * 0.012, sin(ang) * r * 0.86)
		if i > 0:
			_tube(prev, p, CABLE_RADIUS)
		prev = p


# ---------------------------------------------------------- routed cabling --
#
# The MOTIVATION LAW made geometry. A routed cable runs FROM a named source (a
# tap, a junction box) TO a named load (a machine, a fixture) on a true catenary,
# with real fixings at both ends — never sprinkled along a wall for texture. Its
# MOTION is chosen by the load: bolted to a running machine it vibrates, hanging in
# a shaft's draught it sways, otherwise it hangs dead still. If you cannot name the
# cause, the run is DEAD.

## One hanging run, source -> load. `strands` > 1 fans it into a bundle, each
## strand on its own slack so the strands separate through the sag and re-converge
## at the fixings — the single most recognisable thing about a real cable bundle.
func routed_cable(source: Vector3, load: Vector3, motion: int,
		radius: float = CABLE_RADIUS, strands: int = 1,
		slack: float = SLACK_FEED) -> void:
	var mp: Dictionary = _motion_params(motion, source)
	var amp: float = float(mp["amp"])
	var period: float = float(mp["period"])
	var lat: Vector3 = Vector3(load.z - source.z, 0.0, source.x - load.x)
	lat = Vector3.RIGHT if lat.length() < 0.05 else lat.normalized()
	for s: int in strands:
		var f: float = (float(s) / maxf(float(strands - 1), 1.0) - 0.5) \
				if strands > 1 else 0.0
		var off: Vector3 = lat * (f * 0.05) + Vector3(0.0, -absf(f) * 0.018, 0.0)
		var sl: float = slack * (1.0 + f * 0.34 + float(s) * 0.03)
		var pts: Array = _catenary(source + off, load + off, sl)
		if motion == Motion.DEAD:
			# Dead runs cost nothing beyond geometry: straight into the batched
			# MultiMesh, no shader, no per-frame anything.
			for i: int in pts.size() - 1:
				_tube(pts[i], pts[i + 1], radius)
		else:
			var phase: float = roll(source + Vector3(float(s), 0.0, 0.0), 5601) * TAU
			var mat: ShaderMaterial = _cable_material(source + off, load + off,
					amp * (1.0 + f * 0.1), period * (1.0 + f * 0.2), phase)
			_swept_tube(pts, radius, mat, "RoutedCable")
			census["sway"] = int(census["sway"]) + 1
		census["cable"] = int(census["cable"]) + 1
	_anchor_hw(source, load)
	_anchor_hw(load, source)


## A machinery island: a cabinet-sized machine standing in the room's midground,
## FED by a routed cable from a source. The density pass's core motivated element —
## a load that explains the cable and a cable that explains the load. The feed
## VIBRATES because the machine is running. Returns the footprint so the caller can
## place a box proxy and keep it out of the reading lanes, exactly like a crate.
func machinery_island(at: Vector3, yaw: float, source: Vector3) -> Vector3:
	var group: Node3D = Node3D.new()
	group.name = "Machine"
	group.position = at
	group.rotation.y = yaw
	# So `--goto machine` can frame one for a capture (see Debug.M48_TARGETS). The
	# +Z the goto probe stands off is the machine's front, which faces the source.
	group.add_to_group("machines")
	_parent.add_child(group)
	var w: float = lerpf(0.9, 1.3, roll(at, 5701))
	var tall: float = lerpf(1.4, 2.0, roll(at, 5707))
	# A stack of dark cabinet boxes with a conduit cap and one dim slot, so it
	# reads as powered equipment rather than as a crate.
	_group_box(group, Vector3(0.0, tall * 0.5, 0.0), Vector3(w, tall, w * 0.8), MAT_PANEL)
	_group_box(group, Vector3(0.0, tall + 0.05, 0.0),
			Vector3(w * 0.9, 0.1, w * 0.72), MAT_CONDUIT)
	_group_box(group, Vector3(0.0, tall * 0.62, -(w * 0.41)),
			Vector3(w * 0.5, 0.02, 0.014), _slot_material())
	# The feed lands on a junction port at the top of the machine — an overhead
	# feed, which needs no facing and reads clearly as the cable's destination.
	var port: Vector3 = at + Vector3.UP * (tall + 0.06)
	_chunk(port, Vector3(0.2, 0.14, 0.14), yaw)
	# The SOURCE, made visible: a junction box on the wall where the feed begins,
	# so the cable is a connection between two things rather than a loose end.
	_chunk(source, Vector3(0.24, 0.32, 0.14),
			atan2(port.x - source.x, port.z - source.z))
	routed_cable(source, port, Motion.VIBRATE, 0.024, 2 + int(roll(at, 5713) * 2.0))
	census["island"] = int(census["island"]) + 1
	return Vector3(w, tall, w)


## An overhead cable bundle strung across the ceiling between two drop anchors —
## the "ceiling runs" of the density brief. Dead weight sags deep (nobody tensions
## it); it only moves if a draught is named for it.
func ceiling_run(a: Vector3, b: Vector3, motion: int = Motion.DEAD) -> void:
	routed_cable(a, b, motion, 0.02, 3 + int(roll(a, 5801) * 2.0), SLACK_BUNDLE)
	census["duct"] = int(census["duct"]) + 1


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
	return ("cable %d, pipe %d, rubble %d, crate %d, husk %d, grime %d, "
			+ "island %d, sway %d, duct %d") % [
		int(census["cable"]), int(census["pipe"]), int(census["rubble"]),
		int(census["crate"]), int(census["husk"]), int(census["grime"]),
		int(census["island"]), int(census["sway"]), int(census["duct"])]
