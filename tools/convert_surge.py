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
