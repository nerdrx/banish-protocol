"""NULLVOID M3.7 — Gun_Surge.fbx  ->  assets/models/surge.glb  (the Breaker).

Run:
    blender --factory-startup --background --python tools/convert_surge.py -- \
        /mnt/86e4cf4f-b8d4-4490-b068-31c74182b013/3dprops/Gun_Surge.fbx \
        /mnt/86e4cf4f-b8d4-4490-b068-31c74182b013/claude/nullvoid/assets/models/surge.glb

Optional 3rd arg: a directory to also drop a debug .blend into.

------------------------------------------------------------------ what & why
Raw FBX (Blender units, +Z up):
    single MESH "Surge", 4977 polys / 9524 tris / 4792 verts
    slots: 0 Base (4790 polys), 1 Emiss (109), 2 Material.001 (78)
    bbox min (-14.019, -0.800, -4.200) max (10.200, 0.800, 4.000)
    -> long axis is X (24.2194 u), thin axis Y (1.6 u), up is Z (8.2 u)

Verified by ortho renders (see scratchpad m37/qv/gun_ruler.png):
    * MUZZLE is at -X.  The emitter ring / barrel boss protrudes to x ~ -13.82
      and the shroud blade tips reach x = -14.019.
    * The buttpad (ribbed) is at +X (x = +10.2), skeleton stock behind the grip.
    * Trigger at x ~ -0.58; pistol grip column runs (x 0.05, z -1.0) ->
      (x 1.70, z -3.7), so the palm centre is ~ (0.85, 0, -2.15).
    * Material.001 is the sight blade/holo panel: a 0.1 x 0.898 x 1.498 u plate
      standing on top of the receiver at x ~ 0, z 2.451..3.949.  ACCENT/GLASS,
      not a body slot.

Coordinate contract:
    glTF export with export_yup=True maps Blender (x, y, z) -> glTF (x, z, -y).
    Godot wants the barrel down -Z, so the muzzle must sit at Blender +Y.
    The muzzle is at Blender -X, therefore rotate -90 deg about Z:
        (x, y) -> (y, -x)     [-X -> +Y]  and Blender +Z stays up -> Godot +Y.

    Everything is baked into the mesh data; the exported object transform is
    identity, so Godot needs no scale/rotation correction.
"""
import bpy, sys, os, math
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:]
SRC = argv[0]
DST = argv[1]
DBG = argv[2] if len(argv) > 2 else None

# ------------------------------------------------------------------ tunables
TARGET_LEN = 0.86                      # metres, overall length in Godot
GRIP_RAW   = Vector((0.85, 0.0, -2.15))   # palm centre, raw FBX units
MUZZLE_RAW = Vector((-14.10, 0.0, 1.40))  # just ahead of the emitter ring
ROT_Z_DEG  = -90.0                     # maps raw -X (muzzle) -> Blender +Y

# ------------------------------------------------------------------- import
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.unit_settings.system = 'METRIC'
bpy.ops.import_scene.fbx(filepath=SRC)

meshes = [o for o in bpy.data.objects if o.type == 'MESH']
assert len(meshes) == 1, f"expected 1 mesh, got {[o.name for o in meshes]}"
ob = meshes[0]
ob.name = "Surge"
ob.data.name = "SurgeMesh"

# bake whatever the importer left on the object into the mesh data first
bpy.context.view_layer.update()
ob.data.transform(ob.matrix_world)
ob.matrix_world = Matrix.Identity(4)

mn = Vector((1e9,) * 3); mx = Vector((-1e9,) * 3)
for v in ob.data.vertices:
    for i in range(3):
        mn[i] = min(mn[i], v.co[i]); mx[i] = max(mx[i], v.co[i])
raw_len = mx.x - mn.x
SCALE = TARGET_LEN / raw_len
print(f"[surge] raw bbox min {[round(v,4) for v in mn]} max {[round(v,4) for v in mx]}")
print(f"[surge] raw length along X = {raw_len:.4f} u -> uniform SCALE = {SCALE:.8f}")

# --------------------------------------------------------------- transform
# v' = S * Rz(theta) * (v - GRIP)
R = Matrix.Rotation(math.radians(ROT_Z_DEG), 4, 'Z')
S = Matrix.Diagonal((SCALE, SCALE, SCALE, 1.0))
XF = S @ R @ Matrix.Translation(-GRIP_RAW)
ob.data.transform(XF)
ob.matrix_world = Matrix.Identity(4)

# ------------------------------------------------- M4.8: the foregrip -----
#
# A deliberate ART ADDITION, and the reason is a bug: the crew avatar's support
# hand was posed onto the handguard, and the Surge has no handguard to hold. Its
# midsection is a skeletonised open frame about 28-36 mm wide, so the left hand
# was closing on a rectangle of air beside the frame cut-out with its fingers
# passing through the lower rail. No amount of offset tuning fixes a hand
# gripping a feature the model does not have.
#
# So the model grows one, which is what every real rifle does: a short angled
# foregrip hung off the underside of the lower rail, exactly where a two-handed
# hold puts the support hand. It is authored here rather than in the source FBX
# because the FBX is READ ONLY (see the header) — this file is already the place
# where the weapon is turned into NULLVOID's weapon.
#
# Design language, matched to the rest of the Surge:
#   * hard-surface, flat-chamfered, no curves the rest of the model does not have
#   * the body goes in the `Base` slot (matte black, same as the receiver)
#   * ONE emissive seam down its forward face, in the `Emiss` slot, so it reads
#     as part of the same machine as the emitter ring and not as a bolt-on
#
# Placement is measured, not guessed (scratchpad m48/probe_surge.py): in the
# exported Blender frame the lower rail runs along z = -0.066..-0.073 for
# y = 0.05..0.29, and the frame there is +-0.014 wide. The grip therefore hangs
# from z = -0.066 down, centred on the weapon's plane.
#
# HOW BIG is set by the hand, not by real-world ergonomics: this creature's hand
# is a great deal larger than a person's, and the first pass sized the grip like
# a rifle accessory — the fingers closed past the heel and hung in the air below
# it, which is the same "holding nothing" read the bug report started with. It is
# now 135 mm long and 52 mm across, which the hand wraps rather than swallows.
#
# HOW FAR FORWARD is a reach constraint, not an aesthetic one, and the first
# attempt got it wrong: at y = 0.196 the support hand sat 25 cm from the trigger
# hand, well outside the envelope this creature's arms were rigged for (the M3.7
# hold is 14.5 cm), and the left arm's IK gave up and buried the hand in the
# receiver. Pulled back to y = 0.108 the two hands are ~17 cm apart — still a
# compact cutting-tool hold, and inside what the arms can actually do.
#
# Numbers below are in the FINAL (post-transform) Blender frame — barrel +Y, up
# +Z, origin at the pistol grip — and are converted back through XF's inverse so
# they can be authored where they are read.
#
# ---------------------------------------------------------------- T18 re-cut
#
# The task this pass was given was "the band z = -0.150 .. -0.105 contains ZERO
# vertices, so the foregrip is a hollow skeletonised frame — author a solid
# column into the void". The band really does contain zero vertices. There is
# no void. The column M4.8 built spans exactly that band; what it has no
# vertices in is its own MIDDLE, because the shaft was four rings and the two
# nearest the band sat at z = -0.085 and z = -0.173 with a single long quad
# stretched between them. A quad crosses a 45 mm band without leaving one
# vertex in it, and a histogram that counts vertices cannot see it.
#
# Confirmed by shooting rays through the weapon instead of counting points
# (scratchpad surge/probe_surface.py): at every 5 mm step from z = -0.105 to
# z = -0.150 the ray hits solid at x = +-0.023 .. 0.025, and the column's
# centreline reads INSIDE the mesh the whole way down. It is solid. It always
# was. This is CLAUDE.md's instrument rule with a new hat on: the vertex
# histogram was never measuring the surface a hand touches, and two milestones
# of grip work were argued from it (see build_crew_avatar.py's PT4 note, which
# moved the support hand OFF this column and onto the flat handguard slab on
# the strength of that reading).
#
# So nothing is authored into the void — a second column there would have
# intersected this one. What the column does get is the work it never had:
#
#   * an eight-sided cross-section (rectangle with cut corners) instead of a
#     plain box, which is the chamfer language the receiver and the shroud
#     blades already speak;
#   * a PANEL BREAK at t = 0.42..0.48 — the shaft steps in 1.3 mm and carries
#     the emissive seam across the step, so the column reads as two panels
#     bolted together rather than one extruded stick;
#   * a FLARED HEEL (1.02, was tapering away to 0.70). A support hand pulls
#     backwards into a vertical grip; the old column got narrower exactly where
#     the little finger needed something to pull against, which is half of why
#     the hold read as a drape even when the hand was on it;
#   * rings inside the band, so the next person to slice this model gets an
#     honest answer.
#
# The SECTION is re-proportioned, and that is the change that actually makes a
# hand close on this thing. M4.8 sized the column by eye against the hand's
# overall size — 52 mm across, 44 mm deep, nearly square — and with the attach
# finally on the column the finger solver showed what square costs. Posed and
# measured in the weapon's own frame (scratchpad surge/probe_hand.py), the four
# left knuckles do not stack DOWN the column, they spread fore-and-aft across
# it, and they spread further than it is deep:
#
#     IndexFinger1_L  head y = +0.1541      13 mm past the column's FRONT face
#     MiddleFinger1_L head y = +0.1377
#     RingFinger1_L   head y = +0.1156
#     PinkyFinger1_L  head y = +0.0966       7 mm past the column's REAR face
#
# 57.5 mm of knuckle line on a 44 mm grip: the two outer fingers were closing
# on air either side of it, which is a drape no matter how solid the middle is.
# The weapon already had the answer on its other grip — the pistol grip is
# 28 mm across and 58 mm deep, narrow to wrap and long to seat four fingers on,
# and the right hand has never had this problem. So the foregrip takes the same
# proportions: 34 mm across x 62 mm deep, which puts its front face at y =
# +0.1535 and its rear face at y = +0.0966, i.e. exactly under the index and
# pinky knuckles. Narrower also means the fingers stop wrapping at contact
# instead of sailing 9 mm past the far side hunting for it.
#
# LEN drops 135 -> 130 mm for one reason: the heel flare hangs lower than the
# old taper did, and 130 mm keeps the model's bounding box inside the envelope
# it shipped with (min z = -0.1956) instead of growing it.
FOREGRIP_TOP = Vector((0.0, 0.108, -0.062))   # where it meets the rail
FOREGRIP_LEN = 0.130                          # column length
FOREGRIP_RAKE = math.radians(17.0)            # tilted forward, thumb-forward hold
FOREGRIP_HALF = Vector((0.017, 0.031))        # half-width (x), half-depth (y)
FOREGRIP_CHAMFER = 0.34                       # corner cut, fraction of the half
## (t, scale) down the column: rail flare, shoulder, panel break, lower panel,
## flared heel. Six rings -> 40 quads + one cap; ~86 tris on a 9552-tri model.
FOREGRIP_RINGS = ((0.00, 1.04), (0.13, 1.00), (0.42, 0.99),
                  (0.48, 0.93), (0.86, 0.91), (1.00, 1.02))
## Where the support hand's palm goes, as a fraction of the column length.
FOREGRIP_PALM_T = 0.45


def add_foregrip(mesh_ob):
    """Builds the foregrip directly into the Surge mesh, in the final frame."""
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(mesh_ob.data)

    axis = Vector((0.0, math.sin(FOREGRIP_RAKE), -math.cos(FOREGRIP_RAKE)))
    side = Vector((1.0, 0.0, 0.0))
    fwd = axis.cross(side).normalized() * -1.0

    def scale_at(t):
        """The column's cross-section scale at t, lerped along FOREGRIP_RINGS."""
        for (t0, s0), (t1, s1) in zip(FOREGRIP_RINGS, FOREGRIP_RINGS[1:]):
            if t <= t1:
                u = (t - t0) / (t1 - t0)
                return s0 + (s1 - s0) * max(0.0, min(1.0, u))
        return FOREGRIP_RINGS[-1][1]

    def ring(t, scale):
        """The column's cross-section at parameter t (0 = top, at the rail).

           Eight points: a rectangle with its four corners cut. Flat chamfers,
           no curves — the same hard-surface language as the receiver."""
        c = FOREGRIP_TOP + axis * (FOREGRIP_LEN * t)
        hx = FOREGRIP_HALF.x * scale
        hy = FOREGRIP_HALF.y * scale
        k = 1.0 - FOREGRIP_CHAMFER
        corners = ((1, -k), (k, -1), (-k, -1), (-1, -k),
                   (-1, k), (-k, 1), (k, 1), (1, k))
        return [c + side * sx * hx + fwd * sy * hy for sx, sy in corners]

    rings = [ring(t, s) for t, s in FOREGRIP_RINGS]
    verts = [[bm.verts.new(p) for p in r] for r in rings]
    base_slot = 0
    emiss_slot = 1
    faces = []
    for i in range(len(rings) - 1):
        a, b = verts[i], verts[i + 1]
        for k in range(len(a)):
            n = (k + 1) % len(a)
            faces.append((bm.faces.new((a[k], a[n], b[n], b[k])), base_slot))
    # Cap the heel.
    faces.append((bm.faces.new(tuple(reversed(verts[-1]))), base_slot))

    # The seam: a shallow inset strip on the FORWARD face of the shaft, in the
    # emissive slot. One strip, not a wrap — the same restraint the kit's trace
    # channels use. It is built ring by ring rather than as a single quad so it
    # STEPS with the panel break instead of bridging over it in mid-air.
    seam = []
    for t in (0.17, 0.42, 0.62):
        scale = scale_at(t)
        c = FOREGRIP_TOP + axis * (FOREGRIP_LEN * t)
        hx = FOREGRIP_HALF.x * scale * 0.42
        hy = FOREGRIP_HALF.y * scale
        seam.append([c + side * sx * hx + fwd * (hy + 0.0015)
                     for sx in (-1, 1)])
    sv = [[bm.verts.new(p) for p in row] for row in seam]
    for i in range(len(sv) - 1):
        faces.append((bm.faces.new((sv[i][0], sv[i][1],
                                    sv[i + 1][1], sv[i + 1][0])), emiss_slot))

    for f, slot in faces:
        f.material_index = slot
        f.smooth = False
    # Recalculate winding on the NEW faces only. `bm.faces.new` takes the vertex
    # order it is given, and a column built ring-by-ring comes out with half its
    # sides facing inward — which renders as holes and, worse, makes an
    # inside/outside test against the mesh answer backwards for every point near
    # the grip. Restricted to the new faces so the imported body is untouched.
    bmesh.ops.recalc_face_normals(bm, faces=[f for f, _ in faces])
    bm.normal_update()
    bm.to_mesh(mesh_ob.data)
    bm.free()
    mesh_ob.data.update()
    print("[surge] foregrip: %d faces added, top %s len %.3f rake %.0f deg" % (
        len(faces), tuple(round(v, 4) for v in FOREGRIP_TOP),
        FOREGRIP_LEN, math.degrees(FOREGRIP_RAKE)))
    # The palm centre a support hand should be posed onto: half way down the
    # shaft, on the surface of its left face. build_crew_avatar.py reads this
    # number out of this log line.
    palm = FOREGRIP_TOP + axis * (FOREGRIP_LEN * FOREGRIP_PALM_T)
    print("[surge] foregrip palm centre (blender) = (%.4f, %.4f, %.4f)"
          % tuple(palm))
    print("[surge] foregrip surface half-width x = %.4f, depth y = %.4f"
          % (FOREGRIP_HALF.x, FOREGRIP_HALF.y))


add_foregrip(ob)


# ------------------------------------------------------------------ empties
def empty(name, raw_pos, size=0.03):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = 'PLAIN_AXES'
    e.empty_display_size = size
    bpy.context.collection.objects.link(e)
    e.parent = ob
    e.matrix_parent_inverse = Matrix.Identity(4)
    e.location = XF @ Vector(raw_pos)
    return e

muz = empty("Muzzle", MUZZLE_RAW)
grp = empty("Grip", GRIP_RAW)

bpy.context.view_layer.update()
print(f"[surge] Muzzle local (blender) = {tuple(round(v,5) for v in muz.location)}"
      f"  -> godot {(round(muz.location.x,5), round(muz.location.z,5), round(-muz.location.y,5))}")
print(f"[surge] Grip   local (blender) = {tuple(round(v,5) for v in grp.location)}")

nmn = Vector((1e9,) * 3); nmx = Vector((-1e9,) * 3)
for v in ob.data.vertices:
    for i in range(3):
        nmn[i] = min(nmn[i], v.co[i]); nmx[i] = max(nmx[i], v.co[i])
print(f"[surge] blender bbox min {[round(v,4) for v in nmn]} max {[round(v,4) for v in nmx]}")
print(f"[surge] godot   bbox min {[round(nmn.x,4), round(nmn.z,4), round(-nmx.y,4)]}"
      f" max {[round(nmx.x,4), round(nmx.z,4), round(-nmn.y,4)]}")

# --------------------------------------------------------------- materials
# names are contract; do NOT touch them.
print("[surge] material slots (== glTF primitive order):",
      [m.name for m in ob.data.materials])
per = {}
for p in ob.data.polygons:
    d = per.setdefault(p.material_index, [0, 0])
    d[0] += 1; d[1] += len(p.vertices) - 2
for i, m in enumerate(ob.data.materials):
    c = per.get(i, [0, 0])
    print(f"[surge]   slot {i} {m.name!r}: polys={c[0]} tris={c[1]}")
print(f"[surge] TOTAL polys={len(ob.data.polygons)} "
      f"tris={sum(len(p.vertices)-2 for p in ob.data.polygons)} "
      f"verts={len(ob.data.vertices)}")

# ------------------------------------------------------------------ export
os.makedirs(os.path.dirname(DST), exist_ok=True)
bpy.ops.object.select_all(action='DESELECT')
for o in (ob, muz, grp):
    o.select_set(True)
bpy.context.view_layer.objects.active = ob
bpy.ops.export_scene.gltf(
    filepath=DST, export_format='GLB', export_apply=True,
    export_yup=True, export_animations=False,
    export_materials='EXPORT', use_selection=True,
)
print("[surge] WROTE", DST)

if DBG:
    os.makedirs(DBG, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(DBG, "surge.blend"))
    print("[surge] WROTE", os.path.join(DBG, "surge.blend"))
