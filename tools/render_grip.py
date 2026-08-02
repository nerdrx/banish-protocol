#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# LIMBO PROTOCOL — grip inspection renders
#
#   blender --factory-startup --background <crew.blend> \
#           --python tools/render_grip.py -- --out <dir> [--size 900]
#
# Reads the working .blend that `build_crew_avatar.py --blend` leaves behind —
# which already has the Surge parented to the right wrist at the shipping socket
# — and renders close-ups of both hands from five directions.
#
# Why five and not one: the game camera hides sins. It looks at the hold from
# behind and slightly above, which is exactly the angle at which a finger
# passing through a receiver is invisible. Look-down, the wall-tuck and every
# third-person view of a crewmate expose it. So the check is:
#
#   game     from behind/above, roughly where the player's lens sits
#   left     square on from the character's left
#   right    square on from the character's right
#   top      straight down
#   under    three-quarters from below, the angle a crouching crewmate sees
#
# A pass means: no phalanx disappears into the weapon and no fingertip floats
# clear of it, from ALL FIVE. The numeric half of the same check is the
# per-phalanx gap table `build_crew_avatar.py` prints while it fits.
import bpy, sys, os, math
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[argv.index("--out") + 1] if "--out" in argv else "/tmp/grip"
SIZE = int(argv[argv.index("--size") + 1]) if "--size" in argv else 900
FRAME = int(argv[argv.index("--frame") + 1]) if "--frame" in argv else 0

os.makedirs(OUT, exist_ok=True)
scene = bpy.context.scene
scene.frame_set(FRAME)

# EEVEE by name, whichever generation this Blender ships.
for name in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
    try:
        scene.render.engine = name
        break
    except TypeError:
        continue
scene.render.resolution_x = SIZE
scene.render.resolution_y = SIZE
scene.render.resolution_percentage = 100
scene.render.film_transparent = False
try:
    scene.eevee.taa_render_samples = 32
except AttributeError:
    pass

arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
bpy.context.view_layer.update()

# --- lighting -------------------------------------------------------------
#
# Deliberately NOT the game's near-black. This is an inspection render: three
# hard keys from opposite sides so a gap between a finger and the receiver
# actually casts a shadow into itself and can be seen, plus enough fill that
# nothing hides in the dark.
for spec in ((3.0, -2.5, 2.4, 900.0), (-3.0, -2.0, 1.6, 700.0),
             (0.0, 3.2, 2.0, 500.0), (0.0, -0.5, -2.5, 260.0)):
    lamp = bpy.data.lights.new("insp", 'POINT')
    lamp.energy = spec[3]
    lamp.shadow_soft_size = 0.35
    ob = bpy.data.objects.new("insp", lamp)
    ob.location = Vector(spec[:3])
    bpy.context.collection.objects.link(ob)
world = bpy.data.worlds.new("insp")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.05, 0.055, 0.065, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 1.2
scene.world = world

cam_data = bpy.data.cameras.new("insp")
cam_data.lens = 52.0
cam = bpy.data.objects.new("insp_cam", cam_data)
bpy.context.collection.objects.link(cam)
scene.camera = cam


def look_at(obj, target, direction, distance):
    obj.location = Vector(target) + Vector(direction).normalized() * distance
    to = Vector(target) - obj.location
    obj.rotation_euler = to.to_track_quat('-Z', 'Y').to_euler()


# Focus points: the two wrists, read off the posed skeleton, so the renders
# follow the hold rather than a hard-coded position that goes stale the first
# time the pose changes.
def wrist(name):
    pb = arm.pose.bones[name]
    return (arm.matrix_world @ pb.matrix @ Vector((0.0, pb.bone.length * 0.9, 0.0)))


VIEWS = {
    # The player's own view: behind the character, a little above, looking down
    # the hold the way the first-person lens does.
    "game": (Vector((0.30, -0.85, 0.42)), 0.52),
    "left": (Vector((-1.0, 0.05, 0.06)), 0.46),
    "right": (Vector((1.0, 0.05, 0.06)), 0.46),
    "top": (Vector((0.05, 0.02, 1.0)), 0.48),
    "under": (Vector((0.55, -0.45, -0.72)), 0.48),
}

targets = {"right": wrist("Right wrist"), "left": wrist("Left wrist")}
# And one framing that contains both hands, for the "is this one hold" read.
targets["both"] = (targets["right"] + targets["left"]) * 0.5

written = []
for hand, focus in targets.items():
    for view, (direction, dist) in VIEWS.items():
        look_at(cam, focus, direction, dist * (1.9 if hand == "both" else 1.0))
        path = os.path.join(OUT, "grip_%s_%s.png" % (hand, view))
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        written.append(path)

print("[grip-render] wrote %d images to %s" % (len(written), OUT))
for p in written:
    print("[grip-render]   %s" % p)
