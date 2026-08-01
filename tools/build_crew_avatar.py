#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# NULLVOID  M3.7  --  player crew avatar locomotion set
#
#   blender --factory-startup --background --python tools/build_crew_avatar.py
#
#   optional args after "--":
#       --blend  <path>   also save the working .blend (for the render harness)
#       --out    <path>   override the .glb output path
#       --report          print the per-frame foot contact / slide analysis
#
# Source : /mnt/.../3dprops/CyberSentinel.fbx        (READ ONLY)
# Output : assets/models/crew_avatar.glb             (5 glTF animations)
#
# Pipeline
#   1. import the FBX, rotate 180 deg about Z.  The source model faces Blender
#      -Y; glTF y-up export maps blender(x,y,z) -> gltf(x, z, -y), so a -Y
#      facing model would arrive in Godot facing +Z (backwards).  After the
#      flip the nose is at Blender +Y -> Godot -Z = Godot forward.
#   2. uniform scale to 1.86 m tall, feet on z = 0, transforms applied.
#   3. relax the T-pose into an A-pose and BAKE IT INTO THE REST POSE.
#      bpy.ops.object.modifier_apply refuses meshes that carry shape keys (this
#      one has four eye-aim morphs) so the linear blend skin is run by hand over
#      the vertices AND every shape key block, then pose->rest is applied.
#   4. split the mesh into CrewHead / CrewBody by dominant vertex weight so the
#      local player can hide their own head in first person, and drop an `Eye`
#      empty on the Head bone for the first-person camera.
#   5. author idle / walk / run / kneel / rise / aim_idle.  Both legs are driven by IK onto
#      world-space foot controls, so the planted foot travels backwards at
#      exactly the cycle velocity (no skating), then everything is baked down to
#      plain FK rotations for export.
#
# Rotation convention.  After step 1/2 the character faces Blender +Y, up is
# +Z, and the character's own right hand side is +X.  Every pose below is
# written as an armature-space rotation:
#       Rx(+)  tips +Y toward +Z : leg swings FORWARD, toe tips UP,
#                                  an upright bone leans BACKWARD
#       Ry(+)  tips +Z toward +X : lean toward the character's RIGHT
#       Rz(+)  tips +Y toward -X : turn toward the character's LEFT
# set_rel() applies such a rotation on top of whatever the parent is doing
# (so chains accumulate, which is what spines/tails/limbs want); set_abs()
# pins the bone's armature-space orientation regardless of its parent and is
# only used to build the A-pose rest.
# ---------------------------------------------------------------------------
import bpy, bmesh, math, os, sys
from mathutils import Vector, Matrix, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SRC = "/mnt/86e4cf4f-b8d4-4490-b068-31c74182b013/3dprops/CyberSentinel.fbx"
OUT = os.path.join(REPO, "assets", "models", "crew_avatar.glb")

TARGET_H = 1.86
FPS = 24
D = math.radians
TAU = math.tau
I3 = Matrix.Identity(3)


# --------------------------------------------------------------- rotations --

def rot_w(pitch=0.0, roll=0.0, yaw=0.0):
    """armature-space rotation in degrees; X applied first, then Y, then Z."""
    return (Matrix.Rotation(D(yaw), 3, 'Z') @
            Matrix.Rotation(D(roll), 3, 'Y') @
            Matrix.Rotation(D(pitch), 3, 'X'))


def body_w(fwd=0.0, side=0.0, twist=0.0):
    """upright bones (hips/spine/chest/neck/head).
       fwd>0 leans forward, side>0 leans to the character's right,
       twist>0 turns toward the character's left."""
    return rot_w(pitch=-fwd, roll=side, yaw=twist)


def tail_w(lift=0.0, sway=0.0):
    """the tail points -Y.  lift>0 raises it, sway>0 swings it right."""
    return rot_w(pitch=-lift, yaw=sway)


def sgn(side):
    return -1.0 if side == 'L' else 1.0


def shoulder_w(side, fwd=0.0, drop=0.0):
    s = sgn(side)
    return rot_w(yaw=s * fwd, roll=s * drop)


def limb_w(swing=0.0, out=0.0, side='L'):
    """hanging arm bones: swing>0 = forward, out>0 = away from the body.
       Because swing is a rotation about armature X and the whole chain uses
       relative deltas, upper-arm swing + forearm bend simply accumulate."""
    return rot_w(pitch=swing, roll=-sgn(side) * out)


def set_rel(arm, bname, Rw):
    """rotate a bone by Rw (armature axes) on top of its parent's pose."""
    b = arm.data.bones[bname]
    Rb = b.matrix_local.to_quaternion().to_matrix()
    pb = arm.pose.bones[bname]
    pb.rotation_mode = 'XYZ'
    pb.rotation_euler = (Rb.inverted() @ Rw @ Rb).to_euler('XYZ')


def set_abs(arm, bname, Rw, Rw_parent=I3):
    """pin the bone's armature-space orientation to Rw @ rest, given that its
       parent has itself been pinned to Rw_parent @ rest."""
    b = arm.data.bones[bname]
    Rb = b.matrix_local.to_quaternion().to_matrix()
    pb = arm.pose.bones[bname]
    pb.rotation_mode = 'XYZ'
    pb.rotation_euler = (Rb.inverted() @ Rw_parent.inverted() @ Rw @ Rb).to_euler('XYZ')


# ---------------------------------------------------------- interpolation --

def catmull(keys, t):
    """keys = [(x, v), ...] ascending.  C1 Catmull-Rom, clamped outside."""
    n = len(keys)
    if t <= keys[0][0]:
        return keys[0][1]
    if t >= keys[-1][0]:
        return keys[-1][1]
    i = 0
    while i < n - 1 and keys[i + 1][0] < t:
        i += 1
    x0, v0 = keys[i]
    x1, v1 = keys[i + 1]
    u = (t - x0) / (x1 - x0)
    vm = keys[i - 1][1] if i > 0 else v0 - (v1 - v0)
    vp = keys[i + 2][1] if i + 2 < n else v1 + (v1 - v0)
    m0 = 0.5 * (v1 - vm)
    m1 = 0.5 * (vp - v0)
    u2, u3 = u * u, u * u * u
    return ((2 * u3 - 3 * u2 + 1) * v0 + (u3 - 2 * u2 + u) * m0 +
            (-2 * u3 + 3 * u2) * v1 + (u3 - u2) * m1)


def cyc(keys, t, period):
    t = t % period
    ext = ([(k[0] - period, k[1]) for k in keys[-3:-1]] + list(keys) +
           [(k[0] + period, k[1]) for k in keys[1:3]])
    return catmull(ext, t)


def ease(a, b, u):
    u = max(0.0, min(1.0, u))
    return a + (b - a) * (u * u * (3 - 2 * u))


# ------------------------------------------------- stage 1-3 : build rest --

ARM_DOWN = 77.0        # degrees below the T-pose horizontal
ARM_FWD = 1.0          # upper arm carried this far forward
ELBOW_FWD = 19.0       # forearm carried this far forward -> ~18 deg of bend
WRIST_FWD = 21.0

# base curvature of the tail, per segment, degrees of lift added on top of its
# parent.  The source rest tail is a dead-straight 1.1 m rod pointing -Y; this
# arcs it up out of the hips and then lets it fall away, which is what makes
# the silhouette read as a creature rather than a broom handle.
TAIL_ARC = (12.0, 10.0, -14.0, -16.0, -14.0, -10.0)

# first-person camera point: midway between the eye bones, pushed forward to
# roughly the surface of the face.
EYE_FWD = 0.042

# ---- the Surge rifle, imported read-only purely as a posing reference.
# In Godot it is 0.86 m long with the barrel down -Z, +Y up, origin at the grip.
# The glTF importer converts that to Blender Z-up as barrel +Y / up +Z, which is
# already the direction this character faces.
SURGE = os.path.join(REPO, "assets", "models", "surge.glb")
# where the grip sits in armature space, and how the weapon is angled:
# low ready, a little right of centre, muzzle forward and angled down.
# Note this is deliberately carried HIGHER and flatter than a real-world low
# ready.  With a first-person camera at the eye, a true low ready puts the
# muzzle ~55 deg below the view axis, i.e. off the bottom of the screen; this
# hold keeps the muzzle around 34 deg down so the player can actually see their
# own weapon without it being shouldered.
AIM_GRIP = Vector((0.115, 0.300, 1.185))
AIM_PITCH, AIM_YAW, AIM_ROLL = -8.0, 7.0, 12.0
# Attach points are on the SURFACE the palm touches, not on the weapon's
# centre line -- putting them on the axis buries half of each hand inside the
# receiver.  The hands sit 0.145 m apart, a compact hold that suits a cutting
# tool and, more practically, is the only spacing both of this creature's very
# long arms can reach without the left one locking straight.
# The Surge is a tall, thin, skeletonised slab (about 0.035 m wide and 0.15 m
# deep at the handguard, with a large open frame amidships).  Attach points
# therefore sit just OUTSIDE its side faces so the hands wrap the weapon rather
# than being impaled by the frame cut-out.
GRIP_ATTACH_R = Vector((0.034, -0.005, -0.015))   # right face of the pistol grip
FOREGRIP_LOCAL = Vector((-0.033, 0.150, -0.025))  # left face of the handguard
# hand attach point measured out from the wrist head, in the wrist bone's own
# basis (local Y runs wrist -> knuckles).
HAND_OFF = Vector((0.0, 0.100, -0.006))
# hand orientation, expressed in the rifle's frame as
# (wrist->knuckle direction, back-of-hand normal).
#   right: knuckles run down the pistol grip, back of the hand outboard
#   left : support hand under the handguard, palm up, knuckles across the
#          weapon so the curled fingers close over the far side
GRIP_HAND_R = (Vector((0.12, 0.26, -0.96)), Vector((0.94, -0.34, 0.03)))
GRIP_HAND_L = (Vector((0.15, 0.25, -0.96)), Vector((-0.98, 0.05, -0.19)))


def rifle_basis():
    return rot_w(pitch=AIM_PITCH, roll=AIM_ROLL, yaw=AIM_YAW)


def basis_from(y_dir, z_dir):
    """Right-handed orthonormal basis with Y along y_dir and Z as close to
       z_dir as possible.  Columns are X, Y, Z."""
    Y = Vector(y_dir).normalized()
    Z = (Vector(z_dir) - Y * Y.dot(z_dir)).normalized()
    X = Y.cross(Z)
    M = Matrix.Identity(3)
    M.col[0], M.col[1], M.col[2] = X, Y, Z
    return M
# at speed the tail is thrown out behind as a counterweight: much flatter,
# almost no droop.  cumulative comes out at roughly 10-16 deg above horizontal.
RUN_TAIL = (10.0, 6.0, -2.0, -2.0, -1.0, 0.0)
# downed: the whole chain gives up and hangs toward the floor
KNEEL_TAIL = (2.0, -4.0, -10.0, -8.0, -4.0, 2.0)


def rest_relax(arm):
    """Pose the T-pose skeleton into a relaxed A-pose ready to be baked in."""
    for pb in arm.pose.bones:
        pb.rotation_mode = 'XYZ'
        pb.rotation_euler = Euler((0, 0, 0))

    # fingers first, while the hand is still in the T-pose frame: the finger
    # points +-X with the palm facing down, so a curl is a roll about Y.
    for side in ('L', 'R'):
        s = sgn(side)
        for fname, amt in (("Index", 32), ("Middle", 35), ("Ring", 38), ("Pinky", 41)):
            for j in (1, 2, 3):
                set_rel(arm, "%sFinger%d_%s" % (fname, j, side), rot_w(roll=s * amt))
        for j in (1, 2, 3):
            set_rel(arm, "ThumbFinger%d_%s" % (j, side), rot_w(roll=s * 18, pitch=-14))

    # then the arm chain, pinned in armature space
    for side, name in (('L', "Left"), ('R', "Right")):
        s = sgn(side)
        Rsh = shoulder_w(side, fwd=5.0, drop=8.0)
        Rup = rot_w(pitch=ARM_FWD) @ rot_w(roll=s * ARM_DOWN)
        Rlo = rot_w(pitch=ELBOW_FWD) @ rot_w(roll=s * ARM_DOWN)
        Rwr = rot_w(pitch=WRIST_FWD) @ rot_w(roll=s * ARM_DOWN)
        set_abs(arm, "%s shoulder" % name, Rsh)
        set_abs(arm, "%s arm" % name, Rup, Rsh)
        set_abs(arm, "%s elbow" % name, Rlo, Rup)
        set_abs(arm, "%s wrist" % name, Rwr, Rlo)


def wbbox(ob):
    bpy.context.view_layer.update()
    co = [ob.matrix_world @ Vector(c) for c in ob.bound_box]
    return (Vector((min(c.x for c in co), min(c.y for c in co), min(c.z for c in co))),
            Vector((max(c.x for c in co), max(c.y for c in co), max(c.z for c in co))))


def skin_bake(arm, mesh):
    """Apply the current pose to the mesh vertices and to every shape key."""
    bpy.context.view_layer.update()
    bone_mat = {pb.name: pb.matrix @ pb.bone.matrix_local.inverted()
                for pb in arm.pose.bones}
    gi2mat = {vg.index: bone_mat[vg.name] for vg in mesh.vertex_groups
              if vg.name in bone_mat}
    me = mesh.data
    mats, skipped = [], 0
    for v in me.vertices:
        pairs = [(gi2mat[g.group], g.weight) for g in v.groups
                 if g.group in gi2mat and g.weight > 0.0]
        tot = sum(w for _, w in pairs)
        if tot <= 1e-8:
            mats.append(None)
            skipped += 1
            continue
        acc = Matrix(([0.0] * 4,) * 4)
        for m, w in pairs:
            f = w / tot
            for r in range(4):
                for c in range(4):
                    acc[r][c] += m[r][c] * f
        mats.append(acc)
    for i, v in enumerate(me.vertices):
        if mats[i] is not None:
            v.co = mats[i] @ v.co
    if me.shape_keys:
        for kb in me.shape_keys.key_blocks:
            for i in range(len(kb.data)):
                if mats[i] is not None:
                    kb.data[i].co = mats[i] @ kb.data[i].co
    me.update()
    return skipped


def clear_pose(arm):
    for pb in arm.pose.bones:
        pb.rotation_mode = 'XYZ'
        pb.rotation_euler = Euler((0, 0, 0))
        pb.location = Vector((0, 0, 0))
        pb.scale = Vector((1, 1, 1))


def setup():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = FPS
    bpy.ops.import_scene.fbx(filepath=SRC)
    arm = [o for o in bpy.data.objects if o.type == 'ARMATURE'][0]
    mesh = [o for o in bpy.data.objects if o.type == 'MESH'][0]
    arm.name = "Armature"
    bpy.context.view_layer.update()

    mn, mx = wbbox(mesh)
    S = TARGET_H / (mx.z - mn.z)
    X = (Matrix.Translation((0.0, 0.0, -mn.z * S)) @
         Matrix.Rotation(math.pi, 4, 'Z') @ Matrix.Diagonal((S, S, S, 1.0)))
    print("[setup] source height %.4f m -> scale %.6f, rotate 180 deg about Z"
          % (mx.z - mn.z, S))

    mw = mesh.matrix_world.copy()
    mesh.parent = None
    mesh.matrix_world = mw
    for ob in (arm, mesh):
        ob.matrix_world = X @ ob.matrix_world
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action='DESELECT')
    for ob in (arm, mesh):
        ob.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.object.select_all(action='DESELECT')
    mesh.parent = arm
    mesh.matrix_parent_inverse = arm.matrix_world.inverted()
    bpy.context.view_layer.update()

    rest_relax(arm)
    bpy.context.view_layer.update()
    print("[setup] skin bake: %d unweighted verts" % skin_bake(arm, mesh))
    bpy.context.view_layer.objects.active = arm
    arm.select_set(True)
    bpy.ops.object.mode_set(mode='POSE')
    bpy.ops.pose.select_all(action='SELECT')
    bpy.ops.pose.armature_apply()
    bpy.ops.object.mode_set(mode='OBJECT')
    arm.select_set(False)
    clear_pose(arm)

    mn, mx = wbbox(mesh)
    print("[setup] final height %.4f m, feet z %.4f, bbox %s .. %s"
          % (mx.z - mn.z, mn.z,
             tuple(round(v, 3) for v in mn), tuple(round(v, 3) for v in mx)))
    nose = max((mesh.matrix_world @ v.co for v in mesh.data.vertices
                if (mesh.matrix_world @ v.co).z > 1.5), key=lambda v: v.y)
    print("[setup] nose at %s -> faces Blender +Y = Godot -Z"
          % (tuple(round(v, 4) for v in nose),))
    for bn in ("Left wrist", "Right wrist", "Left arm", "Left elbow"):
        b = arm.data.bones[bn]
        print("[setup] rest %-14s %s -> %s" % (
            bn, tuple(round(v, 3) for v in b.head_local),
            tuple(round(v, 3) for v in b.tail_local)))
    return arm, mesh


# -------------------------------------------------- head / body mesh split --
# Everything from the neck up.  The local player hides CrewHead in first person
# and keeps CrewBody, so looking down shows their own chest, arms and feet.
HEAD_BONES = {
    "Neck", "Head", "HeadGRP", "NeckGRP", "Jaw", "Tongue1", "Tongue2", "Tongue3",
    "Nose", "NoseRT", "eye_l", "eye_r",
    "EarRT_L", "Ear1_L", "Ear1_L.001", "Ear1_L.002",
    "EarRT_R", "Ear1_R", "Ear1_R.001", "Ear1_R.002",
}


def split_head_body(arm, mesh):
    """Split `mesh` into CrewHead + CrewBody.

    A vertex belongs to the head if its summed head-bone weight beats its
    summed body-bone weight.  A FACE then goes wherever the majority of its
    corners went, and every face lands in exactly one of the two meshes, so
    there is no hole at the neck -- the boundary vertices are simply duplicated
    into both objects.  Both objects keep all seven material slots and the same
    armature binding."""
    gis = {mesh.vertex_groups[n].index for n in HEAD_BONES if n in mesh.vertex_groups}
    vhead = []
    for v in mesh.data.vertices:
        hw = sum(g.weight for g in v.groups if g.group in gis)
        bw = sum(g.weight for g in v.groups if g.group not in gis)
        vhead.append(hw > bw)
    face_head = []
    for poly in mesh.data.polygons:
        n = sum(1 for i in poly.vertices if vhead[i])
        face_head.append(n * 2 > len(poly.vertices))

    out = []
    for name, want_head in (("CrewHead", True), ("CrewBody", False)):
        ob = mesh.copy()
        ob.data = mesh.data.copy()
        ob.name = name
        ob.data.name = name
        bpy.context.collection.objects.link(ob)
        bm = bmesh.new()
        bm.from_mesh(ob.data)
        bm.faces.ensure_lookup_table()
        kill = [f for i, f in enumerate(bm.faces) if face_head[i] != want_head]
        bmesh.ops.delete(bm, geom=kill, context='FACES')
        bm.to_mesh(ob.data)
        bm.free()
        ob.data.update()
        out.append(ob)
    n_head = sum(1 for x in face_head if x)
    print("[split] CrewHead %d faces / CrewBody %d faces (of %d)"
          % (n_head, len(face_head) - n_head, len(face_head)))
    bpy.data.objects.remove(mesh, do_unlink=True)
    return out


def make_eye(arm):
    """Empty at the first-person camera point: mid way between the eye bones,
       pushed forward to the surface of the face.  Parented to the Head bone."""
    b = arm.data.bones
    mid = (b["eye_l"].head_local + b["eye_r"].head_local) * 0.5
    p = Vector((0.0, mid.y + EYE_FWD, mid.z))
    e = bpy.data.objects.new("Eye", None)
    e.empty_display_type = 'PLAIN_AXES'
    e.empty_display_size = 0.05
    bpy.context.collection.objects.link(e)
    e.parent = arm
    e.parent_type = 'BONE'
    e.parent_bone = "Head"
    bpy.context.view_layer.update()
    # face the empty the way the character faces (Blender +Y -> Godot -Z)
    e.matrix_world = Matrix.Translation(p)
    bpy.context.view_layer.update()
    local = b["Head"].matrix_local.inverted() @ Matrix.Translation(p)
    print("[eye] world rest %s" % (tuple(round(v, 5) for v in p),))
    print("[eye] local to Head bone (bone space, identical in Godot) %s"
          % (tuple(round(v, 5) for v in local.translation),))
    return e, p, local


# ------------------------------------------------------------- foot rig ----

class FootRig:
    def __init__(self, arm, side):
        self.arm = arm
        self.side = side
        self.thigh = "%s leg" % side
        self.shin = "%s knee" % side
        self.ankle = "%s ankle" % side
        self.toe = "%s toe" % side
        b = arm.data.bones
        self.hip_p = b[self.thigh].head_local.copy()
        self.knee_p = b[self.shin].head_local.copy()
        self.ankle_p = b[self.ankle].head_local.copy()
        self.ball_p = b[self.toe].head_local.copy()
        self.L1 = (self.knee_p - self.hip_p).length
        self.L2 = (self.ankle_p - self.knee_p).length
        self.R_ankle = b[self.ankle].matrix_local.to_quaternion().to_matrix()
        self.TIP_Y = 0.085           # front of the toe mesh, on the floor
        self.BALL_Y = self.ball_p.y  # metatarsal joint
        self.HEEL_Y = -0.090
        self.x = self.ankle_p.x
        self.ctl = None

    def make(self):
        arm = self.arm
        e = bpy.data.objects.new("ctl_foot_%s" % self.side[0], None)
        e.empty_display_type = 'ARROWS'
        e.empty_display_size = 0.12
        bpy.context.collection.objects.link(e)
        self.ctl = e
        pb_shin = arm.pose.bones[self.shin]
        c = pb_shin.constraints.new('IK')
        c.target = e
        c.chain_count = 2
        c.use_tail = True
        pb_shin.lock_ik_y = True
        pb_shin.lock_ik_z = True
        pb_shin.use_ik_limit_x = True
        # shin local +X == armature Rx(-x): knee flexion is +local X, so
        # clamping it above zero makes a backwards-popping knee impossible.
        pb_shin.ik_min_x = D(3.0)
        pb_shin.ik_max_x = D(145.0)
        arm.pose.bones[self.thigh].lock_ik_y = True
        cr = arm.pose.bones[self.ankle].constraints.new('COPY_ROTATION')
        cr.target = e
        cr.target_space = 'WORLD'
        cr.owner_space = 'WORLD'
        return e

    def destroy(self):
        for bn in (self.shin, self.ankle):
            for c in list(self.arm.pose.bones[bn].constraints):
                self.arm.pose.bones[bn].constraints.remove(c)
        if self.ctl:
            bpy.data.objects.remove(self.ctl, do_unlink=True)
            self.ctl = None

    def place(self, frame, pivot, py, pz, pitch, x=None):
        """pivot: the foot feature placed at (py, pz).  pitch in degrees,
           positive = toe up.
             'tip'      front of the toe mesh, on the floor
             'ball'     floor point under the metatarsal joint
             'toejoint' the metatarsal joint itself, 43 mm up.  Rolling about
                        this one and giving the toe bone the opposite rotation
                        keeps the toes exactly flat on the floor while the
                        heel peels up -- rolling about the floor point instead
                        buries the toes by ball_z*sin(pitch).
             'heel' / 'ankle' as named."""
        ref_y = {'tip': self.TIP_Y, 'ball': self.BALL_Y, 'toejoint': self.ball_p.y,
                 'heel': self.HEEL_Y, 'ankle': self.ankle_p.y}[pivot]
        ref_z = {'ankle': self.ankle_p.z, 'toejoint': self.ball_p.z}.get(pivot, 0.0)
        off = Vector((0.0, self.ankle_p.y - ref_y, self.ankle_p.z - ref_z))
        R = Matrix.Rotation(D(pitch), 3, 'X')
        e = self.ctl
        e.location = Vector((self.x if x is None else x, py, pz)) + R @ off
        e.rotation_mode = 'XYZ'
        e.rotation_euler = (R @ self.R_ankle).to_euler('XYZ')
        e.keyframe_insert("location", frame=frame)
        e.keyframe_insert("rotation_euler", frame=frame)


# -------------------------------------------------------------- arm rig ----

class ArmRig:
    """IK for one arm, so the hand can be pinned onto the rifle rather than
       dead-reckoned in FK.  Mirrors FootRig: an IK constraint on the forearm
       puts the wrist head on the control, and a world-space Copy Rotation
       gives the hand its orientation."""

    def __init__(self, arm, side):
        self.arm = arm
        self.side = side                       # "Left" / "Right"
        self.s = 'L' if side == "Left" else 'R'
        self.upper = "%s arm" % side
        self.fore = "%s elbow" % side
        self.wrist = "%s wrist" % side
        b = arm.data.bones
        self.wrist_p = b[self.wrist].head_local.copy()
        self.R_wrist = b[self.wrist].matrix_local.to_quaternion().to_matrix()
        self.ctl = None

    def make(self):
        arm = self.arm
        e = bpy.data.objects.new("ctl_hand_%s" % self.s, None)
        e.empty_display_type = 'ARROWS'
        e.empty_display_size = 0.09
        bpy.context.collection.objects.link(e)
        self.ctl = e
        pb = arm.pose.bones[self.fore]
        c = pb.constraints.new('IK')
        c.target = e
        c.chain_count = 2
        c.use_tail = True
        # the elbow is a hinge about its own local Z (in the source T-pose,
        # local +Z swung the forearm backwards); locking X and Y makes a
        # sideways-folding elbow impossible.
        pb.lock_ik_x = True
        pb.lock_ik_y = True
        pb.use_ik_limit_z = True
        if self.s == 'L':
            pb.ik_min_z, pb.ik_max_z = D(-140.0), D(4.0)
        else:
            pb.ik_min_z, pb.ik_max_z = D(-4.0), D(140.0)
        arm.pose.bones[self.upper].lock_ik_y = True
        cr = arm.pose.bones[self.wrist].constraints.new('COPY_ROTATION')
        cr.target = e
        cr.target_space = 'WORLD'
        cr.owner_space = 'WORLD'
        return e

    def destroy(self):
        for bn in (self.fore, self.wrist):
            for c in list(self.arm.pose.bones[bn].constraints):
                self.arm.pose.bones[bn].constraints.remove(c)
        if self.ctl:
            bpy.data.objects.remove(self.ctl, do_unlink=True)
            self.ctl = None

    def grip(self, frame, R_hand, attach_pt):
        """Place the hand so that HAND_OFF, measured in the hand's own basis
           from the wrist head, lands exactly on attach_pt."""
        p = Vector(attach_pt) - R_hand @ HAND_OFF
        e = self.ctl
        e.location = p
        e.rotation_mode = 'XYZ'
        e.rotation_euler = R_hand.to_euler('XYZ')
        e.keyframe_insert("location", frame=frame)
        e.keyframe_insert("rotation_euler", frame=frame)
        return p


# -------------------------------------------------------- action plumbing --

def action_fcurves(action):
    if hasattr(action, "fcurves") and len(action.fcurves):
        return list(action.fcurves)
    out = []
    for layer in getattr(action, "layers", []):
        for strip in layer.strips:
            for cb in getattr(strip, "channelbags", []):
                out.extend(cb.fcurves)
    return out


def remove_fcurve(action, fc):
    try:
        action.fcurves.remove(fc)
        return
    except Exception:
        pass
    for layer in getattr(action, "layers", []):
        for strip in layer.strips:
            for cb in getattr(strip, "channelbags", []):
                if fc in list(cb.fcurves):
                    cb.fcurves.remove(fc)
                    return


def new_action(ob, name):
    if ob.animation_data is None:
        ob.animation_data_create()
    a = bpy.data.actions.new(name)
    a.use_fake_user = True
    ob.animation_data.action = a
    return a


def bake_down(arm, rigs, name, f0, f1):
    bpy.context.view_layer.objects.active = arm
    arm.select_set(True)
    bpy.ops.object.mode_set(mode='POSE')
    bpy.ops.pose.select_all(action='SELECT')
    bpy.ops.nla.bake(frame_start=int(f0), frame_end=int(f1), step=1,
                     only_selected=False, visual_keying=True,
                     clear_constraints=True, clear_parents=False,
                     use_current_action=False, clean_curves=False,
                     bake_types={'POSE'},
                     channel_types={'LOCATION', 'ROTATION'})
    bpy.ops.object.mode_set(mode='OBJECT')
    arm.select_set(False)
    act = arm.animation_data.action
    for fc in action_fcurves(act):
        if fc.data_path.endswith(".location") and '"Hips"' not in fc.data_path:
            remove_fcurve(act, fc)
    for fc in action_fcurves(act):
        for kp in fc.keyframe_points:
            kp.interpolation = 'LINEAR'
        fc.update()
    act.name = name
    act.use_fake_user = True
    try:
        act.use_frame_range = True
        act.frame_start = f0
        act.frame_end = f1
    except Exception:
        pass
    for r in rigs:
        r.destroy()
    return act


def drop_actions(keep):
    for a in list(bpy.data.actions):
        if a.name not in keep:
            a.use_fake_user = False
            bpy.data.actions.remove(a)


# ------------------------------------------------------------ body poser --

SPINE = ["Spine", "Chest", "ChestUp"]
TAIL = ["Tail_Rt", "Tail1", "Tail2", "Tail3", "Tail4", "Tail5"]
ARM_L = ["Left shoulder", "Left arm", "Left elbow", "Left wrist"]
ARM_R = ["Right shoulder", "Right arm", "Right elbow", "Right wrist"]


def pose_body(arm, frame, hips_loc, hips_rot, spine, neck, head, ears,
              tail, arml, armr, toes):
    pb = arm.pose.bones["Hips"]
    pb.rotation_mode = 'XYZ'
    Rb = arm.data.bones["Hips"].matrix_local.to_quaternion().to_matrix()
    pb.location = Rb.inverted() @ Vector(hips_loc)
    pb.keyframe_insert("location", frame=frame)
    todo = [("Hips", hips_rot)]
    todo += list(zip(SPINE, spine))
    todo += [("Neck", neck), ("Head", head), ("EarRT_L", ears[0]), ("EarRT_R", ears[1])]
    todo += list(zip(TAIL, tail))
    todo += list(zip(ARM_L, arml))
    todo += list(zip(ARM_R, armr))
    todo += [("Left toe", toes[0]), ("Right toe", toes[1])]
    for bn, R in todo:
        set_rel(arm, bn, R)
        arm.pose.bones[bn].keyframe_insert("rotation_euler", frame=frame)


# -------------------------------------------------------------- W A L K ----
# 24 frames @ 24 fps = 1.000 s = 2 steps, in place.
#   contact  f0  / f12      down  f3  / f15
#   passing  f6  / f18      up    f9  / f21
W_N = 24
W_TIP_FRONT = 0.430      # toe-tip ground contact at the plant
W_TIP_BACK = -0.350      # toe-tip ground contact at toe-off
W_STEP = W_TIP_FRONT - W_TIP_BACK
W_V = W_STEP / (W_N * 0.5)

W_HIPZ = [(0, -0.048), (3, -0.074), (6, -0.014), (9, -0.030),
          (12, -0.048), (15, -0.074), (18, -0.014), (21, -0.030), (24, -0.048)]
W_PITCH = [(0.0, -7.0), (3.0, 0.0), (6.0, 0.0), (9.0, -24.0), (12.0, -46.0)]
W_ROLLOVER = 6.0         # frame the ground pivot moves tip -> toe joint
W_SWING = [(12, -0.424, 0.147, -46.0),
           (14, -0.360, 0.250, -20.0),
           (17, -0.120, 0.278, 8.0),
           (20, 0.150, 0.205, 12.0),
           (22, 0.262, 0.125, 4.0),
           (24, 0.280, 0.068, -7.0)]


def walk_toe(p):
    """toe-bone counter rotation: exactly cancels the foot roll after the
       rollover so the toes stay flat on the floor."""
    return 0.0 if p > 12.0 or p <= W_ROLLOVER else -catmull(W_PITCH, p)


def walk_foot(rig, f, off):
    p = (f - off) % W_N
    if p <= 12.0:
        pitch = catmull(W_PITCH, p)
        lift = 0.0 if p < 11.0 else (p - 11.0) * 0.020
        if p <= W_ROLLOVER:
            pivot, ref, pz = 'tip', W_TIP_FRONT - W_V * p, lift
        else:
            pivot = 'toejoint'
            ref = (W_TIP_FRONT - rig.TIP_Y + rig.BALL_Y) - W_V * p
            pz = rig.ball_p.z + lift
        rig.place(f, pivot, ref, pz, pitch)
    else:
        rig.place(f, 'ankle',
                  catmull([(k[0], k[1]) for k in W_SWING], p),
                  catmull([(k[0], k[2]) for k in W_SWING], p),
                  catmull([(k[0], k[3]) for k in W_SWING], p))


def build_walk(arm):
    rigs = [FootRig(arm, "Left"), FootRig(arm, "Right")]
    for r in rigs:
        r.make()
    clear_pose(arm)
    new_action(arm, "walk_src")
    for f in range(W_N + 1):
        t = TAU * f / W_N
        c, s = math.cos(t), math.sin(t)
        c2 = math.cos(2 * t)
        hips_loc = (-0.030 * s, 0.0, cyc(W_HIPZ, f, W_N))
        hips_rot = body_w(fwd=5.0, side=5.0 * s, twist=-10.0 * c)
        spine = [body_w(fwd=8.0, side=-2.0 * s, twist=9.0 * c),
                 body_w(fwd=1.5),
                 body_w(fwd=4.0, side=-3.0 * s, twist=10.0 * c)]
        neck = body_w(fwd=-8.0, twist=-4.0 * c, side=-2.0 * s)
        head = body_w(fwd=-6.0 + 2.5 * c2, twist=-5.0 * c, side=1.5 * s)
        ears = (rot_w(pitch=-6.0 + 7.0 * c2, roll=4.0 * s),
                rot_w(pitch=-6.0 + 7.0 * c2, roll=-4.0 * s))
        tail = []
        for i, amp in enumerate((4.0, 9.0, 8.0, 7.0, 6.0, 5.0)):
            dl = 0.32 * i
            tail.append(tail_w(lift=TAIL_ARC[i] + 5.0 * math.cos(2 * t - dl),
                               sway=amp * math.cos(t - dl)))
        swL, swR = -28.0 * c, 28.0 * c
        arml = [shoulder_w('L', fwd=-6.0 * c),
                limb_w(swing=swL, out=7.0 + 3.0 * c, side='L'),
                limb_w(swing=12.0 - 14.0 * c, out=4.0, side='L'),
                limb_w(swing=6.0 * c, side='L')]
        armr = [shoulder_w('R', fwd=6.0 * c),
                limb_w(swing=swR, out=7.0 - 3.0 * c, side='R'),
                limb_w(swing=12.0 + 14.0 * c, out=4.0, side='R'),
                limb_w(swing=-6.0 * c, side='R')]
        toes = (rot_w(pitch=walk_toe(f % W_N)),
                rot_w(pitch=walk_toe((f - 12) % W_N)))
        pose_body(arm, f, hips_loc, hips_rot, spine, neck, head, ears,
                  tail, arml, armr, toes)
        walk_foot(rigs[0], f, 0)
        walk_foot(rigs[1], f, 12)
    return bake_down(arm, rigs, "walk", 0, W_N)


# ---------------------------------------------------------------- R U N ----
# 16 frames @ 24 fps = 0.667 s = 2 steps, with a flight phase.
R_N = 16
R_STANCE = 6.0
R_TIP_FRONT = 0.470
R_TIP_BACK = -0.455
R_STEP = R_TIP_FRONT - R_TIP_BACK
R_V = R_STEP / R_STANCE

R_HIPZ = [(0, -0.078), (2, -0.120), (4, -0.060), (6, -0.010),
          (8, -0.078), (10, -0.120), (12, -0.060), (14, -0.010), (16, -0.078)]
R_PITCH = [(0.0, -14.0), (2.0, 0.0), (4.0, -28.0), (6.0, -52.0)]
R_ROLLOVER = 2.0
R_SWING = [(6, -0.487, 0.196, -52.0),
           (8, -0.430, 0.360, -34.0),
           (10, -0.150, 0.430, 6.0),
           (12, 0.180, 0.330, 18.0),
           (14, 0.352, 0.175, 6.0),
           (16, 0.318, 0.075, -14.0)]


def run_toe(p):
    return 0.0 if p > R_STANCE or p <= R_ROLLOVER else -catmull(R_PITCH, p)


def run_foot(rig, f, off):
    p = (f - off) % R_N
    if p <= R_STANCE:
        pitch = catmull(R_PITCH, p)
        lift = 0.0 if p < 5.2 else (p - 5.2) * 0.05
        if p <= R_ROLLOVER:
            pivot, ref, pz = 'tip', R_TIP_FRONT - R_V * p, lift
        else:
            pivot = 'toejoint'
            ref = (R_TIP_FRONT - rig.TIP_Y + rig.BALL_Y) - R_V * p
            pz = rig.ball_p.z + lift
        rig.place(f, pivot, ref, pz, pitch)
    else:
        rig.place(f, 'ankle',
                  catmull([(k[0], k[1]) for k in R_SWING], p),
                  catmull([(k[0], k[2]) for k in R_SWING], p),
                  catmull([(k[0], k[3]) for k in R_SWING], p))


def build_run(arm):
    rigs = [FootRig(arm, "Left"), FootRig(arm, "Right")]
    for r in rigs:
        r.make()
    clear_pose(arm)
    new_action(arm, "run_src")
    for f in range(R_N + 1):
        t = TAU * f / R_N
        c, s = math.cos(t), math.sin(t)
        c2 = math.cos(2 * t)
        hips_loc = (-0.026 * s, 0.0, cyc(R_HIPZ, f, R_N))
        hips_rot = body_w(fwd=8.0, side=6.0 * s, twist=-14.0 * c)
        spine = [body_w(fwd=11.0, side=-3.0 * s, twist=12.0 * c),
                 body_w(fwd=2.0),
                 body_w(fwd=4.0, side=-4.0 * s, twist=14.0 * c)]
        neck = body_w(fwd=-9.0, twist=-6.0 * c, side=-2.0 * s)
        head = body_w(fwd=-10.0 + 3.0 * c2, twist=-7.0 * c, side=2.0 * s)
        ears = (rot_w(pitch=-16.0 + 8.0 * c2, roll=5.0 * s),
                rot_w(pitch=-16.0 + 8.0 * c2, roll=-5.0 * s))
        tail = []
        for i, amp in enumerate((3.0, 7.0, 6.0, 5.0, 4.0, 3.0)):
            dl = 0.35 * i
            base = RUN_TAIL[i]
            tail.append(tail_w(lift=base + 4.0 * math.cos(2 * t - dl),
                               sway=amp * math.cos(t - dl)))
        swL, swR = -44.0 * c, 44.0 * c
        arml = [shoulder_w('L', fwd=-9.0 * c),
                limb_w(swing=swL, out=9.0, side='L'),
                limb_w(swing=40.0 - 20.0 * c, out=5.0, side='L'),
                limb_w(swing=10.0 * c, side='L')]
        armr = [shoulder_w('R', fwd=9.0 * c),
                limb_w(swing=swR, out=9.0, side='R'),
                limb_w(swing=40.0 + 20.0 * c, out=5.0, side='R'),
                limb_w(swing=-10.0 * c, side='R')]
        toes = (rot_w(pitch=run_toe(f % R_N)),
                rot_w(pitch=run_toe((f - 8) % R_N)))
        pose_body(arm, f, hips_loc, hips_rot, spine, neck, head, ears,
                  tail, arml, armr, toes)
        run_foot(rigs[0], f, 0)
        run_foot(rigs[1], f, 8)
    return bake_down(arm, rigs, "run", 0, R_N)


# -------------------------------------------------------------- I D L E ----
I_N = 96


def build_idle(arm):
    rigs = [FootRig(arm, "Left"), FootRig(arm, "Right")]
    for r in rigs:
        r.make()
    clear_pose(arm)
    new_action(arm, "idle_src")
    for f in range(I_N + 1):
        t = TAU * f / I_N
        c, s = math.cos(t), math.sin(t)
        b, b2 = math.sin(3 * t), math.cos(3 * t)     # breath, 3 per loop
        hips_loc = (-0.028 * s, 0.0, STAND_Z + 0.010 * math.cos(2 * t) - 0.007 * b)
        hips_rot = body_w(fwd=2.0, side=4.5 * s, twist=-3.0 * c)
        spine = [body_w(fwd=3.0 - 1.6 * b, side=-2.0 * s, twist=2.5 * c),
                 body_w(fwd=0.5),
                 body_w(fwd=-1.0 - 2.2 * b, side=-2.5 * s, twist=3.0 * c)]
        neck = body_w(fwd=-2.0 + 1.2 * b, twist=-2.0 * c, side=1.0 * s)
        head = body_w(fwd=-1.5 + 1.5 * math.cos(2 * t) + 1.0 * b2,
                      twist=-6.0 * c - 2.0 * math.sin(2 * t),
                      side=3.5 * math.sin(2 * t) + 1.5 * s)
        ears = (rot_w(pitch=-4.0 + 5.0 * math.sin(2 * t + 0.7), roll=3.0 * s),
                rot_w(pitch=-4.0 + 5.0 * math.sin(2 * t - 0.4), roll=-3.5 * s))
        tail = []
        for i, amp in enumerate((5.0, 11.0, 10.0, 9.0, 8.0, 7.0)):
            dl = 0.55 * i
            base = TAIL_ARC[i]
            tail.append(tail_w(lift=base + 4.0 * math.cos(2 * t - dl),
                               sway=amp * math.cos(t - dl)))
        arml = [shoulder_w('L', fwd=-1.5 * c, drop=-1.5 * b),
                limb_w(swing=-3.0 * c + 1.0 * b, out=2.0 + 1.5 * s, side='L'),
                limb_w(swing=6.0 - 5.0 * c, side='L'),
                limb_w(swing=4.0 * c, side='L')]
        armr = [shoulder_w('R', fwd=1.5 * c, drop=-1.5 * b),
                limb_w(swing=3.0 * c + 1.0 * b, out=2.0 - 1.5 * s, side='R'),
                limb_w(swing=6.0 + 5.0 * c, side='R'),
                limb_w(swing=-4.0 * c, side='R')]
        pose_body(arm, f, hips_loc, hips_rot, spine, neck, head, ears,
                  tail, arml, armr, (rot_w(), rot_w()))
        # slightly staggered, slightly narrowed stance reads as a person
        # standing rather than a mannequin on a turntable
        for r, (xo, yo) in zip(rigs, STAND_FOOT):
            r.place(f, 'ball', r.BALL_Y + yo, 0.0, 0.0, x=r.x + xo)
    return bake_down(arm, rigs, "idle", 0, I_N)


# ------------------------------------------------------ K N E E L / RISE ---
K_N = 20
# the standing end of kneel/rise is pinned to idle's neutral (hip height and
# staggered foot placement) so the game can cross-fade between them cleanly.
STAND_Z = -0.046
STAND_FOOT = (0.010, 0.055), (-0.010, -0.030)


def kneel_pose(arm, rigs, f, u, stagger=0.0):
    """u: 0 = standing, 1 = down on the left knee.  stagger adds an
       off-balance wobble, used to keep `rise` from reading as a rewind."""
    e = u * u * (3 - 2 * u)
    st = stagger
    hips_loc = (-0.030 * e + 0.014 * st, -0.055 * e, STAND_Z + (-0.500 - STAND_Z) * e)
    lean = 18.0 * e + 6.0 * math.sin(math.pi * e)
    hips_rot = body_w(fwd=lean * 0.35, side=-7.0 * e + 6.0 * st, twist=8.0 * e)
    spine = [body_w(fwd=lean * 0.35, side=3.0 * e - 4.0 * st, twist=-5.0 * e),
             body_w(fwd=3.0 * e),
             body_w(fwd=lean * 0.30, side=2.0 * e - 3.0 * st, twist=-4.0 * e)]
    neck = body_w(fwd=10.0 * e, twist=2.0 * e)
    head = body_w(fwd=17.0 * e - 6.0 * st, twist=3.0 * e, side=-3.0 * e + 4.0 * st)
    ears = (rot_w(pitch=-26.0 * e, roll=10.0 * e),
            rot_w(pitch=-26.0 * e, roll=-10.0 * e))
    tail = []
    for i in range(6):
        dl = 0.5 * i
        base = TAIL_ARC[i] + (KNEEL_TAIL[i] - TAIL_ARC[i]) * e
        tail.append(tail_w(lift=base + 3.0 * math.sin(math.pi * e - dl) - 3.0 * st,
                           sway=(-9.0 * e + 9.0 * st) * math.cos(dl * 0.4)))
    arml = [shoulder_w('L', fwd=8.0 * e, drop=-6.0 * e),
            limb_w(swing=14.0 * e + 8.0 * st, out=-4.0 * e, side='L'),
            limb_w(swing=-14.0 * e + 26.0 * abs(st), side='L'),
            limb_w(swing=-10.0 * e, side='L')]
    armr = [shoulder_w('R', fwd=8.0 * e, drop=-6.0 * e),
            limb_w(swing=10.0 * e - 8.0 * st, out=-4.0 * e, side='R'),
            limb_w(swing=-10.0 * e + 26.0 * abs(st), side='R'),
            limb_w(swing=-10.0 * e, side='R')]
    toes = (rot_w(pitch=48.0 * e), rot_w(pitch=6.0 * e))
    pose_body(arm, f, hips_loc, hips_rot, spine, neck, head, ears,
              tail, arml, armr, toes)
    L, R = rigs
    (lxo, lyo), (rxo, ryo) = STAND_FOOT
    L.place(f, 'ball', ease(L.BALL_Y + lyo, -0.415, e), ease(0.0, 0.070, e),
            ease(0.0, -56.0, e), x=L.x + lxo + 0.010 * e)
    R.place(f, 'ball', ease(R.BALL_Y + ryo, 0.135, e), 0.0, ease(0.0, 6.0, e),
            x=R.x + rxo - 0.020 * e)


def build_kneel(arm):
    rigs = [FootRig(arm, "Left"), FootRig(arm, "Right")]
    for r in rigs:
        r.make()
    clear_pose(arm)
    new_action(arm, "kneel_src")
    for f in range(K_N + 1):
        u = f / float(K_N)
        st = 0.0
        if 0.55 < u < 0.95:
            st = -0.50 * math.sin((u - 0.55) / 0.40 * math.pi)
        kneel_pose(arm, rigs, f, u, st)
    return bake_down(arm, rigs, "kneel", 0, K_N)


def build_rise(arm):
    rigs = [FootRig(arm, "Left"), FootRig(arm, "Right")]
    for r in rigs:
        r.make()
    clear_pose(arm)
    new_action(arm, "rise_src")
    for f in range(K_N + 1):
        v = f / float(K_N)
        # not a rewind: hangs low, lurches up past balance, then settles
        u = (1.0 - v) ** 1.25
        u += 0.13 * math.sin(math.pi * v) - 0.09 * math.sin(2 * math.pi * v)
        u = max(-0.05, min(1.0, u))       # slight over-straighten near the top
        st = 1.10 * math.sin(math.pi * (v ** 0.75)) * math.cos(2.2 * math.pi * v)
        kneel_pose(arm, rigs, f, u, st)
    return bake_down(arm, rigs, "rise", 0, K_N)


# ------------------------------------------------------ A I M _ I D L E ----
# Two-handed low-ready hold, 96 frames, cyclic.  The rifle is placed in
# armature space and BOTH hands are solved onto it, so the grip cannot drift.
A_N = 96


def aim_rifle(f):
    """rifle grip point + basis for frame f (a slow, shallow hold sway)."""
    t = TAU * f / A_N
    b = math.sin(2 * t)                       # breath
    P = AIM_GRIP + Vector((0.005 * math.sin(t + 0.6),
                           0.004 * math.sin(2 * t),
                           0.006 * math.cos(t) - 0.004 * b))
    R = rot_w(pitch=AIM_PITCH + 1.3 * b,
              roll=AIM_ROLL + 1.6 * math.sin(t),
              yaw=AIM_YAW + 1.1 * math.cos(t))
    return P, R


def aim_hands(P, R):
    """world hand bases + attach points for a given rifle placement."""
    RhR = R @ basis_from(*GRIP_HAND_R)
    RhL = R @ basis_from(*GRIP_HAND_L)
    return ((RhR, Vector(P) + R @ GRIP_ATTACH_R),
            (RhL, Vector(P) + R @ FOREGRIP_LOCAL))


def build_aim_idle(arm):
    feet = [FootRig(arm, "Left"), FootRig(arm, "Right")]
    hands = [ArmRig(arm, "Right"), ArmRig(arm, "Left")]
    for r in feet + hands:
        r.make()
    clear_pose(arm)
    new_action(arm, "aim_idle_src")
    for f in range(A_N + 1):
        t = TAU * f / A_N
        c, s = math.cos(t), math.sin(t)
        b = math.sin(2 * t)
        hips_loc = (-0.018 * s, 0.0, STAND_Z + 0.006 * math.cos(2 * t) - 0.005 * b)
        hips_rot = body_w(fwd=4.0, side=3.0 * s, twist=-6.0)
        # bladed stance: the torso is turned toward the character's right so the
        # left shoulder leads, then the neck/head unwind back to face forward.
        spine = [body_w(fwd=7.0 - 1.2 * b, side=-1.5 * s, twist=-6.0),
                 body_w(fwd=1.0),
                 body_w(fwd=3.0 - 1.8 * b, side=-1.5 * s, twist=-7.0)]
        neck = body_w(fwd=-6.0 + 0.8 * b, twist=9.0, side=0.8 * s)
        head = body_w(fwd=-4.0 + 0.9 * b, twist=10.0, side=1.0 * math.sin(2 * t))
        ears = (rot_w(pitch=-8.0 + 3.0 * math.sin(2 * t + 0.5), roll=3.0 * s),
                rot_w(pitch=-8.0 + 3.0 * math.sin(2 * t - 0.3), roll=-3.0 * s))
        tail = []
        for i, amp in enumerate((3.0, 6.0, 5.5, 5.0, 4.5, 4.0)):
            dl = 0.5 * i
            tail.append(tail_w(lift=TAIL_ARC[i] + 2.5 * math.cos(2 * t - dl),
                               sway=amp * math.cos(t - dl)))
        # arm/elbow/wrist are IK driven; only the shoulders stay FK
        arml = [shoulder_w('L', fwd=7.0 + 1.5 * b, drop=-3.0), I3, I3, I3]
        armr = [shoulder_w('R', fwd=-4.0 + 1.0 * b, drop=-5.0), I3, I3, I3]
        pose_body(arm, f, hips_loc, hips_rot, spine, neck, head, ears,
                  tail, arml, armr, (rot_w(), rot_w()))
        P, R = aim_rifle(f)
        (RhR, aR), (RhL, aL) = aim_hands(P, R)
        hands[0].grip(f, RhR, aR)
        hands[1].grip(f, RhL, aL)
        # bladed foot stance, left foot forward and toed slightly out
        feet[0].place(f, 'ball', feet[0].BALL_Y + 0.105, 0.0, 0.0, x=feet[0].x + 0.012)
        feet[1].place(f, 'ball', feet[1].BALL_Y - 0.070, 0.0, 0.0, x=feet[1].x - 0.014)
    return bake_down(arm, feet + hands, "aim_idle", 0, A_N)


def rifle_socket(arm):
    """Local transform for the rifle under a BoneAttachment3D on `Right wrist`.
       Read back off the *evaluated* pose rather than assumed, then reported in
       bone space -- which the glTF y-up conversion leaves untouched (a bone's
       local frame is the same in Blender and in Godot)."""
    bpy.context.scene.frame_set(0)
    bpy.context.view_layer.update()
    P, R = aim_rifle(0)
    rifle_world = Matrix.Translation(P) @ R.to_4x4()
    bone = arm.pose.bones["Right wrist"].matrix.copy()
    socket_bl = bone.inverted() @ rifle_world
    # A bone's own frame survives the y-up conversion unchanged (verified in
    # Godot), so the translation carries straight over.  The RIFLE's frame does
    # NOT: surge.glb is barrel -Z / up +Y in Godot but the glTF importer hands
    # Blender barrel +Y / up +Z.  The two differ by exactly the y-up rotation,
    # so the Godot-side socket needs it multiplied back in on the right.
    C_inv = Matrix.Rotation(math.pi / 2.0, 4, 'X')
    socket_gd = socket_bl @ C_inv
    return socket_bl, socket_gd, rifle_world


def attach_rifle_reference(arm, socket):
    """Import surge.glb read-only and hang it off the Right wrist bone so the
       render harness shows the real weapon.  NOT exported."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=SURGE)
    new = [o for o in bpy.data.objects if o not in before]
    root = [o for o in new if o.parent is None][0]
    root.name = "SurgeRef"
    c = root.constraints.new('CHILD_OF')
    c.target = arm
    c.subtarget = "Right wrist"
    c.inverse_matrix = Matrix.Identity(4)
    root.matrix_basis = socket
    bpy.context.view_layer.update()
    return root, new


def upper_body_bones(arm, split="Spine"):
    """Ordered list of every bone from `split` upward -- the AnimationTree
       filter for blending aim_idle over walk/run."""
    out = []

    def walk(b):
        out.append(b.name)
        for ch in b.children:
            walk(ch)
    walk(arm.data.bones[split])
    return out


# -------------------------------------------------------------- analysis ---

def foot_vertex_sets(mesh):
    out = {}
    for side in ("Left", "Right"):
        names = ["%s ankle" % side, "%s toe" % side] + \
                ["Toe%s%d_%s" % (n, i, side[0])
                 for n in ("Pinky", "Ring", "Mid", "Index") for i in (1, 2)]
        gis = {mesh.vertex_groups[n].index for n in names if n in mesh.vertex_groups}
        out[side] = [v.index for v in mesh.data.vertices
                     if any(g.group in gis and g.weight > 0.3 for g in v.groups)]
    return out


def analyse(arm, mesh, action, f0, f1, label, contact_z=0.015, quiet=False):
    arm.animation_data.action = action
    sets = foot_vertex_sets(mesh)
    rows = []
    for f in range(int(f0), int(f1) + 1):
        bpy.context.scene.frame_set(f)
        dg = bpy.context.evaluated_depsgraph_get()
        ev = mesh.evaluated_get(dg)
        me = ev.to_mesh()
        row = {"f": f}
        for side, idx in sets.items():
            co = [mesh.matrix_world @ me.vertices[i].co for i in idx]
            mz = min(v.z for v in co)
            touch = [v for v in co if v.z < contact_z]
            row[side] = (mz, (sum(v.y for v in touch) / len(touch)) if touch else None,
                         len(touch))
        ev.to_mesh_clear()
        rows.append(row)
    print("\n=== %s : foot contact ===" % label)
    if not quiet:
        print("  f |   L minz  L contact y    n |   R minz  R contact y    n")
        for r in rows:
            ls, rs = r["Left"], r["Right"]
            print("%3d | %8.4f %s %4d | %8.4f %s %4d" % (
                r["f"], ls[0], ("%9.4f" % ls[1]) if ls[1] is not None else "     --  ",
                ls[2], rs[0], ("%9.4f" % rs[1]) if rs[1] is not None else "     --  ", rs[2]))
    worst = min(min(r["Left"][0], r["Right"][0]) for r in rows)
    for side in ("Left", "Right"):
        d = []
        for a, b in zip(rows, rows[1:]):
            if (a[side][1] is not None and b[side][1] is not None
                    and a[side][2] > 60 and b[side][2] > 60):
                d.append(b[side][1] - a[side][1])
        if d:
            print("  %-5s contact-patch centroid travel/frame: %+.4f .. %+.4f"
                  % (side, min(d), max(d)))
        # single-vertex slide: the foremost toe vertex, tracked while it is on
        # the floor.  This is the honest skate measurement.
        tip = max(sets[side], key=lambda i: mesh.data.vertices[i].co.y)
        tr = []
        for f in range(int(f0), int(f1) + 1):
            bpy.context.scene.frame_set(f)
            dg = bpy.context.evaluated_depsgraph_get()
            ev = mesh.evaluated_get(dg)
            me = ev.to_mesh()
            tr.append(mesh.matrix_world @ me.vertices[tip].co)
            ev.to_mesh_clear()
        dd = [(b.y - a.y) for a, b in zip(tr, tr[1:])
              if a.z < 0.02 and b.z < 0.02]
        if dd:
            print("  %-5s toe-tip vertex travel/frame while grounded: "
                  "%+.5f .. %+.5f  (spread %.5f m)"
                  % (side, min(dd), max(dd), max(dd) - min(dd)))
    print("  deepest floor penetration: %.4f m" % worst)
    return rows


# ---------------------------------------------------------------- export ---

def export(path, arm, objs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.select_all(action='DESELECT')
    arm.select_set(True)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = arm
    for a in bpy.data.actions:
        a.use_fake_user = True
    bpy.ops.export_scene.gltf(
        filepath=path, export_format='GLB',
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_animations=True,
        export_animation_mode='ACTIONS',
        export_nla_strips=False,
        export_optimize_animation_size=False,
        # OFF on purpose: "bake all object animations" samples every object
        # that has no action over the whole scene frame range, which produced
        # a bogus 250-frame animation named after the mesh alongside the real
        # ones.
        export_bake_animation=False,
        export_force_sampling=True,
        export_materials='EXPORT',
        export_skins=True,
        export_morph=True,
    )
    print("[export] wrote %s (%.2f MB)" % (path, os.path.getsize(path) / 1e6))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    blend = argv[argv.index("--blend") + 1] if "--blend" in argv else None
    out = argv[argv.index("--out") + 1] if "--out" in argv else OUT
    report = "--report" in argv

    arm, mesh = setup()
    bpy.context.scene.render.fps = FPS
    eye, eye_world, eye_local = make_eye(arm)

    acts = {"idle": build_idle(arm), "walk": build_walk(arm), "run": build_run(arm),
            "kneel": build_kneel(arm), "rise": build_rise(arm),
            "aim_idle": build_aim_idle(arm)}
    drop_actions(set(acts.keys()))

    # ---- rifle socket, measured off the evaluated aim_idle pose
    arm.animation_data.action = acts["aim_idle"]
    socket, socket_gd, rifle_world = rifle_socket(arm)
    print("\n[socket] rifle local transform under BoneAttachment3D('Right wrist')")
    print("[socket]   position (x, y, z) = (%.5f, %.5f, %.5f)"
          % tuple(socket_gd.translation))
    e = socket_gd.to_euler('XYZ')
    print("[socket]   rotation deg, Godot EULER_ORDER_XYZ = (%.3f, %.3f, %.3f)"
          % tuple(math.degrees(a) for a in e))
    ey = socket_gd.to_euler('YXZ')
    print("[socket]   rotation deg, Godot default YXZ      = (%.3f, %.3f, %.3f)"
          % tuple(math.degrees(a) for a in ey))
    q = socket_gd.to_quaternion()
    print("[socket]   quaternion (x, y, z, w) = (%.6f, %.6f, %.6f, %.6f)"
          % (q.x, q.y, q.z, q.w))
    muzzle = rifle_world @ Vector((0.0, 0.5309, 0.1261))
    print("[socket]   muzzle should land at godot (%.4f, %.4f, %.4f)"
          % (muzzle.x, muzzle.z, -muzzle.y))

    # ---- split, then analyse against the body half
    head_ob, body_ob = split_head_body(arm, mesh)
    for ob, label in ((head_ob, "CrewHead"), (body_ob, "CrewBody")):
        tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
        print("[split] %-9s %6d verts %6d tris  materials %s"
              % (label, len(ob.data.vertices), tris,
                 sorted({ob.data.materials[p.material_index].name
                         for p in ob.data.polygons})))

    print("\n[stride] walk: step %.3f m  stride %.3f m/cycle  %.3f s  -> %.3f m/s"
          % (W_STEP, 2 * W_STEP, W_N / FPS, 2 * W_STEP / (W_N / FPS)))
    print("[stride] run : step %.3f m  stride %.3f m/cycle  %.3f s  -> %.3f m/s"
          % (R_STEP, R_V * R_N, R_N / FPS, R_V * R_N / (R_N / FPS)))

    ub = upper_body_bones(arm, "Spine")
    print("\n[filter] upper-body split point = 'Spine' (%d bones at and above it)"
          % len(ub))
    print("[filter] " + ",".join(ub))

    if report:
        analyse(arm, mesh=body_ob, action=acts["walk"], f0=0, f1=W_N, label="walk", quiet=True)
        analyse(arm, mesh=body_ob, action=acts["run"], f0=0, f1=R_N, label="run", quiet=True)
        analyse(arm, mesh=body_ob, action=acts["idle"], f0=0, f1=8,
                label="idle (first 8)", quiet=True)
        analyse(arm, mesh=body_ob, action=acts["aim_idle"], f0=0, f1=8,
                label="aim_idle (first 8)", quiet=True)
        analyse(arm, mesh=body_ob, action=acts["kneel"], f0=0, f1=K_N, label="kneel", quiet=True)
        analyse(arm, mesh=body_ob, action=acts["rise"], f0=0, f1=K_N, label="rise", quiet=True)

    arm.animation_data.action = acts["aim_idle"]
    bpy.context.scene.frame_set(0)
    export(out, arm, [head_ob, body_ob, eye])
    if blend:
        # the rifle reference goes in AFTER the export so it never ships
        attach_rifle_reference(arm, socket)
        os.makedirs(os.path.dirname(blend), exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=blend)
        print("[blend] %s" % blend)


main()
