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
FOREGRIP_TOP = Vector((0.0, 0.108, -0.062))   # where it meets the rail
FOREGRIP_LEN = 0.135                          # column length
FOREGRIP_RAKE = math.radians(17.0)            # tilted forward, thumb-forward hold
FOREGRIP_HALF = Vector((0.026, 0.022))        # half-width (x), half-depth (y)
FOREGRIP_TAPER = 0.82                         # narrower at the bottom


def add_foregrip(mesh_ob):
    """Builds the foregrip directly into the Surge mesh, in the final frame."""
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(mesh_ob.data)

    axis = Vector((0.0, math.sin(FOREGRIP_RAKE), -math.cos(FOREGRIP_RAKE)))
    side = Vector((1.0, 0.0, 0.0))
    fwd = axis.cross(side).normalized() * -1.0

    def ring(t, scale):
        """Four corners of the column's cross-section at parameter t (0 top)."""
        c = FOREGRIP_TOP + axis * (FOREGRIP_LEN * t)
        hx = FOREGRIP_HALF.x * scale
        hy = FOREGRIP_HALF.y * scale
        return [c + side * sx * hx + fwd * sy * hy
                for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]

    # Three rings: a flare where it meets the rail, the shaft, and a flared
    # heel so the hand has something to pull against. Twelve faces total.
    rings = [ring(0.0, 1.04), ring(0.18, 1.0), ring(0.86, FOREGRIP_TAPER),
             ring(1.0, FOREGRIP_TAPER * 0.86)]
    verts = [[bm.verts.new(p) for p in r] for r in rings]
    base_slot = 0
    emiss_slot = 1
    faces = []
    for i in range(len(rings) - 1):
        a, b = verts[i], verts[i + 1]
        for k in range(4):
            n = (k + 1) % 4
            faces.append((bm.faces.new((a[k], a[n], b[n], b[k])), base_slot))
    # Cap the heel.
    faces.append((bm.faces.new(tuple(reversed(verts[-1]))), base_slot))

    # The seam: a shallow inset strip on the FORWARD face of the shaft, in the
    # emissive slot. One strip, not a wrap — the same restraint the kit's trace
    # channels use.
    seam = []
    for t, scale in ((0.24, 1.0), (0.80, FOREGRIP_TAPER)):
        c = FOREGRIP_TOP + axis * (FOREGRIP_LEN * t)
        hx = FOREGRIP_HALF.x * scale * 0.42
        hy = FOREGRIP_HALF.y * scale
        seam.append([c + side * sx * hx + fwd * (hy + 0.0015)
                     for sx in (-1, 1)])
    sv = [[bm.verts.new(p) for p in row] for row in seam]
    faces.append((bm.faces.new((sv[0][0], sv[0][1], sv[1][1], sv[1][0])), emiss_slot))

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
    palm = FOREGRIP_TOP + axis * (FOREGRIP_LEN * 0.45)
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
