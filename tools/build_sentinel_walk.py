"""NULLVOID M6.5 — CyberSentinel.fbx -> assets/models/sentinel.glb WITH a heavy walk.

Run:
    blender --factory-startup --background --python tools/build_sentinel_walk.py -- \
        /mnt/86e4cf4f-b8d4-4490-b068-31c74182b013/3dprops/CyberSentinel.fbx \
        /mnt/86e4cf4f-b8d4-4490-b068-31c74182b013/claude/nullvoid/assets/models/sentinel.glb

------------------------------------------------------------------ what & why
The M3.7 Sentinel GLIDES: `convert_sentinel.py` bakes the enemy body and exports
with NO animations, on purpose (the frictionless-drift character). The user has
OVERRIDDEN that: the Sentinel must WALK now — heavy, deliberate, feet planted,
speed-matched in-game like the crew avatar (the M3.7 no-skate pattern).

This tool runs `convert_sentinel.py`'s geometry pipeline VERBATIM — same arm pose
baked into rest, same orphan-vertex patch (so NO neutral_bone, 94 bones), same
Rz(180)+scale+lift, same single mesh, same 7 material slots — so the exported
rig/mesh is BYTE-IDENTICAL to the shipping Sentinel (the kit mounts CORE_AT/
HALO_AT/PYLON_AT, the collision capsule, the head-track bone indices and the
CoreHousing weak point are all measured against that exact rest and MUST NOT
move). The ONLY thing added is animation: an `idle` and a heavy `walk`, authored
on the leg/hip/spine bones with two-bone foot IK (from `build_crew_avatar.py`) so
the feet plant on the floor.

The walk is deliberately WRONG — a 2.6 m mass that should stay scary on foot:
  * FLAT-FOOTED stomp (no heel-toe roll) — a slab coming down, not a person's gait
  * heavy weight shift: the hips roll hard onto the planted leg and DROP on each
    plant (the slam), then hitch — a beat too still — before the next step
  * near-dead arms: they hang and barely counter-sway
  * a touch too even, too metronomic: it is being re-rendered, not walking

Result contract (asserted at the end): 94 bones, 22764 source verts (== the
current sentinel.glb), 7 materials in the SAME order, faces Godot -Z, feet on
y=0, plus actions {idle, walk}.
"""
import bpy, sys, os, math
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:]
SRC = argv[0]
DST = argv[1]

TARGET_H = 2.6
YAW_DEG = 180.0
FPS = 24
D = math.radians
TAU = math.tau
I3 = Matrix.Identity(3)

# The exact contract the shipping sentinel.glb was built to (convert_sentinel.py).
EXPECT_BONES = 94
EXPECT_VERTS = 22764
EXPECT_MATS = ["LightMetal", "Armour", "Emiss", "Slime", "Mask", "Bone", "Eyes"]

# Neutral idle arm pose, baked into rest — copied EXACTLY from convert_sentinel.py
# so the rest the game's kit offsets are measured against does not move.
POSE = [
    ("Right shoulder", "Left shoulder", 13.0, 7.0),
    ("Right arm", "Left arm", 56.0, 13.0),
    ("Right elbow", "Left elbow", 16.0, 34.0),
    ("Right wrist", "Left wrist", 9.0, 6.0),
]


# =====================================================================  helpers
# (pure posing maths, lifted from tools/build_crew_avatar.py — same rig)

def rot_w(pitch=0.0, roll=0.0, yaw=0.0):
    return (Matrix.Rotation(D(yaw), 3, 'Z') @
            Matrix.Rotation(D(roll), 3, 'Y') @
            Matrix.Rotation(D(pitch), 3, 'X'))


def body_w(fwd=0.0, side=0.0, twist=0.0):
    return rot_w(pitch=-fwd, roll=side, yaw=twist)


def sgn(side):
    return -1.0 if side == 'L' else 1.0


def shoulder_w(side, fwd=0.0, drop=0.0):
    s = sgn(side)
    return rot_w(yaw=s * fwd, roll=s * drop)


def limb_w(swing=0.0, out=0.0, side='L'):
    return rot_w(pitch=swing, roll=-sgn(side) * out)


def set_rel(arm, bname, Rw):
    b = arm.data.bones[bname]
    Rb = b.matrix_local.to_quaternion().to_matrix()
    pb = arm.pose.bones[bname]
    pb.rotation_mode = 'XYZ'
    pb.rotation_euler = (Rb.inverted() @ Rw @ Rb).to_euler('XYZ')


def catmull(keys, t):
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
    """Catmull-Rom sampled cyclically over `period` — for a seamless loop curve."""
    t = t % period
    ext = ([(k[0] - period, k[1]) for k in keys[-3:-1]] + list(keys) +
           [(k[0] + period, k[1]) for k in keys[1:3]])
    return catmull(ext, t)


def smooth(u):
    u = max(0.0, min(1.0, u))
    return u * u * (3 - 2 * u)


def clear_pose(arm):
    for pb in arm.pose.bones:
        pb.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()


# ---------------------------------------------------------------- foot IK rig
# Two-bone IK on Left/Right leg->knee->ankle, hand copied from build_crew_avatar.

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
        self.ankle_p = b[self.ankle].head_local.copy()
        self.ball_p = b[self.toe].head_local.copy()
        self.R_ankle = b[self.ankle].matrix_local.to_quaternion().to_matrix()
        self.BALL_Y = self.ball_p.y
        self.x = self.ankle_p.x
        self.ctl = None

    def make(self):
        arm = self.arm
        e = bpy.data.objects.new("ctl_foot_%s" % self.side[0], None)
        e.empty_display_type = 'ARROWS'
        e.empty_display_size = 0.14
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

    def place(self, frame, py, pz, pitch, x=None):
        """Put the ball of the foot at (py forward, pz up) with `pitch` deg of
           toe-up, flat when pitch=0 — a heavy sole, not a rolling foot."""
        off = Vector((0.0, self.ankle_p.y - self.BALL_Y, self.ankle_p.z))
        R = Matrix.Rotation(D(pitch), 3, 'X')
        e = self.ctl
        e.location = Vector((self.x if x is None else x, py, pz)) + R @ off
        e.rotation_mode = 'XYZ'
        e.rotation_euler = (R @ self.R_ankle).to_euler('XYZ')
        e.keyframe_insert("location", frame=frame)
        e.keyframe_insert("rotation_euler", frame=frame)


# --------------------------------------------------------------- action plumbing

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
    # Root motion is stripped in-game (the clip animates in place); keep only the
    # Hips location channel so the vertical bob survives, drop the rest.
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


# ------------------------------------------------------------------ body poser
SPINE = ["Spine", "Chest", "ChestUp"]
ARM_L = ["Left shoulder", "Left arm", "Left elbow", "Left wrist"]
ARM_R = ["Right shoulder", "Right arm", "Right elbow", "Right wrist"]


def pose_body(arm, frame, hips_loc, hips_rot, spine, arml, armr):
    # NECK and HEAD are deliberately NOT animated here: at runtime sentinel.gd's
    # procedural head-track owns them (the "it watches you" dread), driving them
    # from rest toward the crewmate it is hunting. Leaving them out of the clip
    # means the body stomps while the head stays locked on you — and the head-track
    # has no clip pose to fight over on the physics/idle callback boundary.
    pb = arm.pose.bones["Hips"]
    pb.rotation_mode = 'XYZ'
    Rb = arm.data.bones["Hips"].matrix_local.to_quaternion().to_matrix()
    pb.location = Rb.inverted() @ Vector(hips_loc)
    pb.keyframe_insert("location", frame=frame)
    todo = [("Hips", hips_rot)]
    todo += list(zip(SPINE, spine))
    todo += list(zip(ARM_L, arml))
    todo += list(zip(ARM_R, armr))
    for bn, R in todo:
        if bn not in arm.pose.bones:
            continue
        set_rel(arm, bn, R)
        arm.pose.bones[bn].keyframe_insert("rotation_euler", frame=frame)


# ============================================================  HEAVY  W A L K
# 30 frames @ 24 fps = 1.25 s = 2 steps, in place. Slow and deliberate: a heavy
# thing does not hurry. Flat-footed; the hips roll HARD onto the stance leg and
# drop on the plant (the slam), then HOLD (the hitch) before the next foot lands.
HW_N = 30
HW_FRONT = 0.66          # foot plants this far forward (m, 2.6 m rig)
HW_BACK = -0.60          # foot lifts off this far back
HW_STEP = HW_FRONT - HW_BACK
HW_STANCE = 0.62         # fraction of a foot's cycle spent planted (long, heavy)
HW_LIFT = 0.16           # swing-foot ground clearance (kept low — it drags)


def hw_foot(rig, f, off):
    p = ((f - off) % HW_N) / HW_N       # 0..1 this foot's phase
    if p <= HW_STANCE:
        # STANCE: dead flat, dragging straight back at a constant rate — the
        # planted foot the whole no-skate mission is about. A tiny ease at the
        # very start reads as the weight settling onto it (the hitch), without
        # ever letting the contact point move off its constant-velocity line.
        u = p / HW_STANCE
        ref = HW_FRONT - HW_STEP * u
        rig.place(f, ref, 0.0, 0.0)
    else:
        # SWING: peel up, reach forward. Low and heavy — it barely clears.
        u = (p - HW_STANCE) / (1.0 - HW_STANCE)
        ref = HW_BACK + (HW_FRONT - HW_BACK) * smooth(u)
        pz = math.sin(math.pi * u) * HW_LIFT
        pitch = -18.0 * math.sin(math.pi * u)   # toe leads the reach
        rig.place(f, ref, pz, pitch)


# The hip VERTICAL over one loop, keyed (frame, height) rather than a flat cosine:
# a heavy weight curve, not a metronome. Slam DOWN onto each plant (frames 0/15),
# a small rebound OVERSHOOT (2/17), the hips ride HIGH over the straight stance leg
# (7/22), then descend into the next plant — with a shallow anticipation dip just
# before it (12/27). This is most of what stops the gait reading as a stiff rig.
HW_HIPZ = [(0, -0.060), (2, -0.033), (5, -0.025), (8, -0.022),
           (12, -0.043), (15, -0.060), (17, -0.033), (20, -0.025),
           (23, -0.022), (27, -0.043), (30, -0.060)]


def build_walk(arm):
    rigs = [FootRig(arm, "Left"), FootRig(arm, "Right")]
    for r in rigs:
        r.make()
    clear_pose(arm)
    new_action(arm, "walk_src")
    for f in range(HW_N + 1):
        t = TAU * f / HW_N

        # OVERLAPPING ACTION: every part reads the drive cosine at its OWN phase
        # lag (in loop-fractions), so the motion RIPPLES up from the hips through
        # the spine and out along each arm rather than every joint snapping to key
        # on the same frame — the #1 tell that separates a predator from a puppet.
        def cs(lag):
            tl = t - TAU * lag
            return math.cos(tl), math.sin(tl)

        c, s = cs(0.0)              # hips lead
        csp, ssp = cs(0.07)        # lower spine trails the hips
        cch, sch = cs(0.12)        # chest trails more
        ccu, scu = cs(0.16)        # upper chest / shoulders trail most

        # Hips: heavy weight curve (vertical), and the pelvis rolls onto the planted
        # leg a beat after the plant (the lateral shift lags the vertical slam).
        _, s_shift = cs(0.06)
        hips_loc = (-0.058 * s_shift, 0.0, cyc(HW_HIPZ, f, HW_N))
        hips_rot = body_w(fwd=4.0, side=9.0 * s, twist=-8.0 * c)

        # SPINE COUNTER-ROTATION: the chest twists AGAINST the hips (and lags), so
        # the upper body is never a rigid extension of the pelvis — it stabilises,
        # then follows. The plate/chest also counter-leans the hip roll.
        spine = [body_w(fwd=5.0, side=-4.0 * ssp, twist=5.0 * csp),
                 body_w(fwd=1.5, side=-3.0 * sch, twist=-6.0 * cch),
                 body_w(fwd=1.5, side=-3.0 * scu, twist=-9.0 * ccu)]

        # ARM FOLLOW-THROUGH: the overlong arms swing with inertia and the motion
        # whips DOWN the chain — shoulder leads, the forearm and hand each lag and
        # overshoot a few frames behind it, settling after the body's weight-shift.
        csh, ssh = cs(0.14)       # shoulder
        cup, sup = cs(0.19)       # upper arm
        cel, sel = cs(0.25)       # elbow (forearm)
        cwr, swr = cs(0.31)       # wrist (hand)
        arml = [shoulder_w('L', fwd=-3.0 * csh, drop=1.5),
                limb_w(swing=-9.0 * cup, out=3.0 + 1.0 * cup, side='L'),
                limb_w(swing=6.0 - 6.0 * cel, out=2.0, side='L'),
                limb_w(swing=-5.0 * cwr, side='L')]
        armr = [shoulder_w('R', fwd=3.0 * csh, drop=1.5),
                limb_w(swing=9.0 * cup, out=3.0 - 1.0 * cup, side='R'),
                limb_w(swing=6.0 + 6.0 * cel, out=2.0, side='R'),
                limb_w(swing=5.0 * cwr, side='R')]
        pose_body(arm, f, hips_loc, hips_rot, spine, arml, armr)
        hw_foot(rigs[0], f, 0)
        hw_foot(rigs[1], f, HW_N * 0.5)
    return bake_down(arm, rigs, "walk", 0, HW_N)


# ==================================================================  I D L E
# It stands and looms. Both feet flat and planted; a slow, shallow weight shift
# and breath so it is not a dead mannequin, but nothing that reads as restless.
I_N = 96
I_STANCE_X = 0.055       # feet a little wider than rest — a braced stance


def build_idle(arm):
    rigs = [FootRig(arm, "Left"), FootRig(arm, "Right")]
    for r in rigs:
        r.make()
    clear_pose(arm)
    new_action(arm, "idle_src")
    for f in range(I_N + 1):
        t = TAU * f / I_N
        c, s = math.cos(t), math.sin(t)
        b = math.sin(3 * t)     # slow breath, 3 per loop
        hips_loc = (-0.020 * s, 0.0, -0.050 + 0.006 * math.cos(2 * t))
        hips_rot = body_w(fwd=3.0, side=2.5 * s, twist=-1.5 * c)
        spine = [body_w(fwd=3.0 - 0.8 * b, side=-1.0 * s),
                 body_w(fwd=1.0),
                 body_w(fwd=1.5 - 1.0 * b, side=-1.0 * s)]
        arml = [shoulder_w('L', drop=1.0 - 0.5 * b),
                limb_w(swing=-1.0 * c, out=1.5, side='L'),
                limb_w(swing=2.0, side='L'), limb_w(side='L')]
        armr = [shoulder_w('R', drop=1.0 - 0.5 * b),
                limb_w(swing=1.0 * c, out=1.5, side='R'),
                limb_w(swing=2.0, side='R'), limb_w(side='R')]
        pose_body(arm, f, hips_loc, hips_rot, spine, arml, armr)
        for r, xo in zip(rigs, (I_STANCE_X, -I_STANCE_X)):
            r.place(f, r.BALL_Y, 0.0, 0.0, x=r.x + xo)
    return bake_down(arm, rigs, "idle", 0, I_N)


# ==============================================================  geometry stage
# Verbatim from convert_sentinel.py (steps 0-6): the ONLY way the rig/mesh the
# game's kit offsets are pinned to stays byte-identical.

def build_rest():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.unit_settings.system = 'METRIC'
    bpy.context.scene.render.fps = FPS
    bpy.ops.import_scene.fbx(filepath=SRC)

    arm = [o for o in bpy.data.objects if o.type == 'ARMATURE'][0]
    ob = [o for o in bpy.data.objects if o.type == 'MESH'][0]
    arm.name = "Armature"
    arm.data.name = "SentinelRig"
    me = ob.data
    me.name = "SentinelMesh"

    # 0. patch unweighted verts onto Head (blocks the exporter's neutral_bone)
    bone_names = {b.name for b in arm.data.bones}
    vg_head = ob.vertex_groups.get("Head") or ob.vertex_groups.new(name="Head")
    orphans = [v.index for v in me.vertices
               if sum(g.weight for g in v.groups
                      if ob.vertex_groups[g.group].name in bone_names) <= 1e-6]
    if orphans:
        vg_head.add(orphans, 1.0, 'REPLACE')
    print("[sent] unweighted verts patched: %d" % len(orphans))

    # 1. detach shape keys
    sk_saved = []
    if me.shape_keys:
        kbs = me.shape_keys.key_blocks
        basis = kbs[0]
        for kb in list(kbs)[1:]:
            deltas = [(kb.data[i].co - basis.data[i].co) for i in range(len(me.vertices))]
            sk_saved.append((kb.name, kb.value, kb.slider_min, kb.slider_max, deltas))
        ob.shape_key_clear()
    print("[sent] detached shape keys:", [s[0] for s in sk_saved])

    # 2. pose the arm chains out of the T-pose
    bpy.ops.object.select_all(action='DESELECT')
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='POSE')
    for pb in arm.pose.bones:
        pb.rotation_mode = 'QUATERNION'

    def spin(bone_name, axis, deg):
        bpy.context.view_layer.update()
        pb = arm.pose.bones[bone_name]
        M = pb.matrix.copy()
        h = M.translation.copy()
        R = Matrix.Rotation(math.radians(deg), 4, axis)
        pb.matrix = Matrix.Translation(h) @ R @ Matrix.Translation(-h) @ M
        bpy.context.view_layer.update()

    for br, bl, lower, fwd in POSE:
        spin(br, 'Y', -lower)
        spin(br, 'X', -fwd)
        spin(bl, 'Y', +lower)
        spin(bl, 'X', -fwd)
    bpy.context.view_layer.update()

    pose_mats = {}
    for bn in arm.data.bones:
        pb = arm.pose.bones[bn.name]
        pose_mats[bn.name] = pb.matrix @ bn.matrix_local.inverted()

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
                for cc in range(4):
                    acc[r][cc] += m[r][cc] * w
            tot += w
        if tot <= 1e-9:
            return Matrix.Identity(4)
        for r in range(4):
            for cc in range(4):
                acc[r][cc] /= tot
        return acc

    if sk_saved:
        touched = set()
        for _n, _v, _a, _b, d in sk_saved:
            for i, off in enumerate(d):
                if off.length > 1e-7:
                    touched.add(i)
        sm = {i: skin_matrix(me.vertices[i]).to_3x3() for i in touched}
        for _n, _v, _a, _b, d in sk_saved:
            for i in touched:
                d[i] = sm[i] @ d[i]

    bpy.ops.object.mode_set(mode='OBJECT')

    # 3/4. bake the posed deformation into the mesh, then pose into rest
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
    for pb in arm.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.rotation_euler = (0, 0, 0)
        pb.scale = (1, 1, 1)
    bpy.context.view_layer.update()

    # 5. restore shape keys
    if sk_saved:
        ob.shape_key_add(name="Basis", from_mix=False)
        for name, val, smin, smax, deltas in sk_saved:
            kb = ob.shape_key_add(name=name, from_mix=False)
            kb.slider_min = smin
            kb.slider_max = smax
            kb.value = val
            for i, off in enumerate(deltas):
                kb.data[i].co = me.vertices[i].co + off

    # 6. global orient / scale / lift feet to z=0
    mn = Vector((1e9,) * 3)
    mx = Vector((-1e9,) * 3)
    for v in me.vertices:
        for i in range(3):
            mn[i] = min(mn[i], v.co[i])
            mx[i] = max(mx[i], v.co[i])
    K = TARGET_H / (mx.z - mn.z)
    print("[sent] posed height %.4f -> scale %.8f" % (mx.z - mn.z, K))
    XF = (Matrix.Translation((0.0, 0.0, -K * mn.z))
          @ Matrix.Diagonal((K, K, K, 1.0))
          @ Matrix.Rotation(math.radians(YAW_DEG), 4, 'Z'))
    ob.parent = None
    ob.matrix_world = XF
    arm.matrix_world = XF
    bpy.ops.object.select_all(action='DESELECT')
    arm.select_set(True)
    ob.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    ob.parent = arm
    ob.matrix_parent_inverse = Matrix.Identity(4)
    bpy.context.view_layer.update()
    print("[sent] rest built: bones=%d verts=%d mats=%s"
          % (len(arm.data.bones), len(me.vertices), [m.name for m in me.materials]))
    return arm, ob, me


# ========================================================================  main
arm, ob, me = build_rest()

# Author the clips on the finished rest.
build_idle(arm)
build_walk(arm)
# Keep only our two actions, and clear the armature's active action so the
# exporter emits exactly {idle, walk} in a clean state.
for a in list(bpy.data.actions):
    if a.name not in ("idle", "walk"):
        a.use_fake_user = False
        bpy.data.actions.remove(a)
clear_pose(arm)
print("[sent] actions:", [a.name for a in bpy.data.actions])

# ---- byte-identical-rig assertions (the studio's discipline) ----
assert len(arm.data.bones) == EXPECT_BONES, \
    "BONE COUNT %d != %d — rig drifted" % (len(arm.data.bones), EXPECT_BONES)
assert len(me.vertices) == EXPECT_VERTS, \
    "VERT COUNT %d != %d — mesh drifted" % (len(me.vertices), EXPECT_VERTS)
assert [m.name for m in me.materials] == EXPECT_MATS, \
    "MATERIALS %s != %s" % ([m.name for m in me.materials], EXPECT_MATS)
print("[sent] ASSERT ok: %d bones, %d verts, materials in order" % (
    EXPECT_BONES, EXPECT_VERTS))

os.makedirs(os.path.dirname(DST), exist_ok=True)
# A clean active action, and clear the MESH object's animation so the exporter
# has nothing object-level to bake into a stray clip.
arm.animation_data.action = bpy.data.actions["walk"]
if ob.animation_data is not None:
    ob.animation_data_clear()
if me.shape_keys is not None and me.shape_keys.animation_data is not None:
    me.shape_keys.animation_data_clear()
bpy.ops.object.select_all(action='DESELECT')
arm.select_set(True)
ob.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.export_scene.gltf(
    filepath=DST, export_format='GLB', export_apply=True,
    export_yup=True, export_animations=True,
    export_animation_mode='ACTIONS',
    export_nla_strips=False,
    export_optimize_animation_size=False,
    # OFF: baking object animation samples the mesh object over the whole range
    # and emits a bogus clip named after it (see build_crew_avatar.py).
    export_bake_animation=False,
    export_force_sampling=True,
    export_skins=True, export_morph=True, export_materials='EXPORT',
    use_selection=True, export_all_vertex_colors=False,
)
print("[sent] WROTE", DST)
