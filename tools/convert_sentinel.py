"""NULLVOID M3.7 — CyberSentinel.fbx  ->  assets/models/sentinel.glb  (enemy Sentinel).

Run:
    blender --factory-startup --background --python tools/convert_sentinel.py -- \
        /mnt/86e4cf4f-b8d4-4490-b068-31c74182b013/3dprops/CyberSentinel.fbx \
        /mnt/86e4cf4f-b8d4-4490-b068-31c74182b013/claude/nullvoid/assets/models/sentinel.glb

Optional 3rd arg: a directory to also drop a debug .blend into.

------------------------------------------------------------------ what & why
Raw FBX (Blender units, +Z up, already ~metric):
    ARMATURE "Armature.001", 94 bones, no actions
    MESH "CyberSentinel", 22872 polys / 44922 tris / 22764 verts, 92 vgroups
    materials: LightMetal, Armour, Emiss, Slime, Mask, Bone, Eyes
    shape keys: Basis + EyeL/EyeR/EyeU/EyeD (all value 0, eye-dart morphs)
    custom split normals: YES  -> the pose bake goes through modifier_apply so
    Blender transforms the corner normals for us.
    bbox min (-1.0153, -0.1728, 0.0019) max (1.0153, 1.1876, 1.9765) => 1.9746 m tall

Orientation: bone "Nose" head y = -0.1336, "Tail5" tail y = +1.1612 -> the
creature FACES BLENDER -Y.  glTF export_yup maps Blender (x,y,z) -> (x, z, -y),
so Blender -Y would land on Godot +Z (backwards).  Rotate 180 deg about Z so the
face points Blender +Y, which exports to Godot -Z.  (Verified with renders.)

Pipeline:
    1. pull the eye shape keys off (modifier_apply refuses meshes with keys)
    2. pose the shoulder/arm/elbow/wrist chains out of the T-pose
    3. apply the Armature modifier   -> mesh geometry + custom normals baked
    4. re-add the modifier, then pose.armature_apply()  -> pose becomes REST
    5. put the eye shape keys back (their verts are head-weighted and the head
       is NOT posed, so their deltas are unchanged; we transform by the vertex
       skinning matrix anyway, for correctness)
    6. bake global transform: Rz(180) * uniform scale * lift feet to z = 0
    7. export, no animations

Result contract: 2.6 m tall, feet on y=0, faces Godot -Z, root transform identity.
"""
import bpy, sys, os, math
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:]
SRC = argv[0]
DST = argv[1]
DBG = argv[2] if len(argv) > 2 else None

TARGET_H = 2.6          # metres, feet to top of head
YAW_DEG  = 180.0        # face Blender -Y -> +Y  => Godot -Z

# Neutral idle: world-space delta rotations applied about each bone's head,
# parent first.  "lower" = rotate about world Y (sign mirrored per side),
# "fwd" = rotate about world X by a negative angle (swings toward -Y = front).
#   (bone_R, bone_L, lower_deg, fwd_deg)
POSE = [
    ("Right shoulder", "Left shoulder", 13.0,  7.0),
    ("Right arm",      "Left arm",      56.0, 13.0),
    ("Right elbow",    "Left elbow",    16.0, 34.0),
    ("Right wrist",    "Left wrist",     9.0,  6.0),
]

# ------------------------------------------------------------------- import
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.unit_settings.system = 'METRIC'
bpy.ops.import_scene.fbx(filepath=SRC)

arm = [o for o in bpy.data.objects if o.type == 'ARMATURE'][0]
ob  = [o for o in bpy.data.objects if o.type == 'MESH'][0]
arm.name = "Armature"
arm.data.name = "SentinelRig"
me = ob.data
me.name = "SentinelMesh"        # glTF names the mesh after the *data* block
print(f"[sent] armature {arm.name!r} bones={len(arm.data.bones)}  mesh {ob.name!r} "
      f"polys={len(me.polygons)} tris={sum(len(p.vertices)-2 for p in me.polygons)}")

# ------------------------------------------- 0. patch the unweighted verts
# The FBX leaves 3 verts on the nose bridge with no weights at all.  Blender's
# glTF exporter would otherwise invent a 95th joint called `neutral_bone` and
# pin them to it, which tears when the game rotates Head procedurally.
bone_names = {b.name for b in arm.data.bones}
vg_head = ob.vertex_groups.get("Head") or ob.vertex_groups.new(name="Head")
orphans = [v.index for v in me.vertices
           if sum(g.weight for g in v.groups
                  if ob.vertex_groups[g.group].name in bone_names) <= 1e-6]
if orphans:
    vg_head.add(orphans, 1.0, 'REPLACE')
print(f"[sent] unweighted verts patched onto 'Head': {len(orphans)} {orphans}")

# ---------------------------------------------------- 1. detach shape keys
sk_saved = []
if me.shape_keys:
    kbs = me.shape_keys.key_blocks
    basis = kbs[0]
    for kb in list(kbs)[1:]:
        deltas = [(kb.data[i].co - basis.data[i].co) for i in range(len(me.vertices))]
        sk_saved.append((kb.name, kb.value, kb.slider_min, kb.slider_max, deltas))
    print("[sent] detached shape keys:", [s[0] for s in sk_saved])
    ob.shape_key_clear()

# ------------------------------------------------------------- 2. the pose
bpy.ops.object.select_all(action='DESELECT')
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode='POSE')
for pb in arm.pose.bones:
    pb.rotation_mode = 'QUATERNION'

def spin(bone_name, axis, deg):
    """Rotate a pose bone by `deg` about a world axis through its own head."""
    bpy.context.view_layer.update()
    pb = arm.pose.bones[bone_name]
    M = pb.matrix.copy()
    h = M.translation.copy()
    R = Matrix.Rotation(math.radians(deg), 4, axis)
    pb.matrix = Matrix.Translation(h) @ R @ Matrix.Translation(-h) @ M
    bpy.context.view_layer.update()

for br, bl, lower, fwd in POSE:
    spin(br, 'Y', -lower)     # right arm lives at -X: negative Y-rot drops it
    spin(br, 'X', -fwd)
    spin(bl, 'Y', +lower)     # left arm at +X: mirrored
    spin(bl, 'X', -fwd)
bpy.context.view_layer.update()

# skinning matrix per vertex, needed to carry the shape key deltas across
pose_mats = {}
for b in arm.data.bones:
    pb = arm.pose.bones[b.name]
    pose_mats[b.name] = pb.matrix @ b.matrix_local.inverted()

def skin_matrix(v):
    tot = 0.0
    acc = Matrix(((0.0,) * 4,) * 4)
    for g in v.groups:
        gn = ob.vertex_groups[g.group].name
        m = pose_mats.get(gn)
        if m is None or g.weight == 0.0:
            continue
        w = g.weight
        for r in range(4):
            for c in range(4):
                acc[r][c] += m[r][c] * w
        tot += w
    if tot <= 1e-9:
        return Matrix.Identity(4)
    for r in range(4):
        for c in range(4):
            acc[r][c] /= tot
    return acc

if sk_saved:
    touched = set()
    for _n, _v, _a, _b, d in sk_saved:
        for i, off in enumerate(d):
            if off.length > 1e-7:
                touched.add(i)
    print(f"[sent] shape-key affected verts: {len(touched)}")
    sm = {i: skin_matrix(me.vertices[i]).to_3x3() for i in touched}
    for _n, _v, _a, _b, d in sk_saved:
        for i in touched:
            d[i] = sm[i] @ d[i]

bpy.ops.object.mode_set(mode='OBJECT')

# ------------------------------------------------- 3/4. bake pose into rest
bpy.ops.object.select_all(action='DESELECT')
ob.select_set(True)
bpy.context.view_layer.objects.active = ob
amod = [m for m in ob.modifiers if m.type == 'ARMATURE'][0]
bpy.ops.object.modifier_apply(modifier=amod.name)
nm = ob.modifiers.new("Armature", 'ARMATURE')
nm.object = arm
nm.use_vertex_groups = True

bpy.ops.object.select_all(action='DESELECT')
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode='POSE')
bpy.ops.pose.select_all(action='SELECT')
bpy.ops.pose.armature_apply()
bpy.ops.pose.select_all(action='DESELECT')
bpy.ops.object.mode_set(mode='OBJECT')
for pb in arm.pose.bones:                       # guarantee a clean identity pose
    pb.location = (0, 0, 0)
    pb.rotation_quaternion = (1, 0, 0, 0)
    pb.rotation_euler = (0, 0, 0)
    pb.scale = (1, 1, 1)
bpy.context.view_layer.update()
print("[sent] pose baked into rest")

# ------------------------------------------------- 5. restore shape keys
if sk_saved:
    ob.shape_key_add(name="Basis", from_mix=False)
    for name, val, smin, smax, deltas in sk_saved:
        kb = ob.shape_key_add(name=name, from_mix=False)
        kb.slider_min = smin; kb.slider_max = smax; kb.value = val
        for i, off in enumerate(deltas):
            kb.data[i].co = me.vertices[i].co + off
    print("[sent] restored shape keys:", [k.name for k in me.shape_keys.key_blocks])

# ------------------------------------------- 6. global orient / scale / lift
mn = Vector((1e9,) * 3); mx = Vector((-1e9,) * 3)
for v in me.vertices:
    for i in range(3):
        mn[i] = min(mn[i], v.co[i]); mx[i] = max(mx[i], v.co[i])
print(f"[sent] posed bbox min {[round(v,4) for v in mn]} max {[round(v,4) for v in mx]}")
raw_h = mx.z - mn.z
K = TARGET_H / raw_h
print(f"[sent] posed height {raw_h:.4f} m -> uniform SCALE = {K:.8f}")

XF = (Matrix.Translation((0.0, 0.0, -K * mn.z))
      @ Matrix.Diagonal((K, K, K, 1.0))
      @ Matrix.Rotation(math.radians(YAW_DEG), 4, 'Z'))

ob.parent = None                       # both matrices are identity, nothing moves
ob.matrix_world = XF
arm.matrix_world = XF
bpy.ops.object.select_all(action='DESELECT')
arm.select_set(True); ob.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
ob.parent = arm
ob.matrix_parent_inverse = Matrix.Identity(4)
bpy.context.view_layer.update()

mn = Vector((1e9,) * 3); mx = Vector((-1e9,) * 3)
for v in me.vertices:
    for i in range(3):
        mn[i] = min(mn[i], v.co[i]); mx[i] = max(mx[i], v.co[i])
print(f"[sent] final blender bbox min {[round(v,4) for v in mn]} max {[round(v,4) for v in mx]}")
print(f"[sent] final godot   bbox min {[round(mn.x,4), round(mn.z,4), round(-mx.y,4)]}"
      f" max {[round(mx.x,4), round(mx.z,4), round(-mn.y,4)]}")
for bn in ("Head", "Neck", "HeadGRP", "Nose", "Tail5", "Right wrist", "Left wrist"):
    if bn in arm.data.bones:
        h = arm.data.bones[bn].head_local
        print(f"[sent]   bone {bn:14s} rest head blender=({h.x:.3f},{h.y:.3f},{h.z:.3f})"
              f"  godot=({h.x:.3f},{h.z:.3f},{-h.y:.3f})")

print("[sent] material slots (== glTF primitive order):", [m.name for m in me.materials])
per = {}
for p in me.polygons:
    d = per.setdefault(p.material_index, [0, 0]); d[0] += 1; d[1] += len(p.vertices) - 2
for i, m in enumerate(me.materials):
    c = per.get(i, [0, 0])
    print(f"[sent]   slot {i} {m.name!r}: polys={c[0]} tris={c[1]}")
print(f"[sent] TOTAL polys={len(me.polygons)} "
      f"tris={sum(len(p.vertices)-2 for p in me.polygons)} verts={len(me.vertices)}")
print(f"[sent] bones={len(arm.data.bones)}  actions={[a.name for a in bpy.data.actions]}")

# ------------------------------------------------------------------ export
for a in list(bpy.data.actions):
    bpy.data.actions.remove(a)
for o in (arm, ob):
    o.animation_data_clear()

os.makedirs(os.path.dirname(DST), exist_ok=True)
bpy.ops.object.select_all(action='DESELECT')
arm.select_set(True); ob.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.export_scene.gltf(
    filepath=DST, export_format='GLB', export_apply=True,
    export_yup=True, export_animations=False, export_skins=True,
    export_morph=True, export_materials='EXPORT', use_selection=True,
    export_all_vertex_colors=False,   # one COLOR_0, not COLOR_0 + COLOR_1
)
print("[sent] WROTE", DST)

if DBG:
    os.makedirs(DBG, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(DBG, "sentinel.blend"))
    print("[sent] WROTE", os.path.join(DBG, "sentinel.blend"))
