#!/usr/bin/env python3
"""LIMBO PROTOCOL micro-detail dressing kit — Blender 5.2 headless mesh author.

Run:  blender --factory-startup --background --python tools/build_trim.py

A second .glb that ships *beside* nullvoid_kit.glb and never replaces it. Every
module here is dressing: the main kit already builds the walls, floors and
ceilings, and this one kills the seams where those meet. A greybox reads as a
greybox mostly because its planes collide at bare 90 degree arrises — no
skirting, no corner guard, no cable tray — and the eye reads a bare arris as
"unfinished" long before it reads a texture as "cheap". A 256 tri baseboard
bolted onto a 940 tri wall is the largest quality-per-triangle win left in the
kit, which is why BASEBOARD_4M is first in the file and first in the budget.

Conventions are not re-invented here. `build_kit` is imported and its `Part`
class, `MATERIALS` slot list, 6 mm chamfer pass and vertex-colour contract are
used verbatim:

  * authoring is in **Godot space** (Y up, -Z forward, 1 unit = 1 m) and rotated
    into Blender space as the last step, so the numbers below are the numbers
    you type into the engine;
  * the `Col` layer carries R = edge-wear mask (1 on chamfered surfaces),
    G = height gradient (0 at the floor, 1 at 4 m), B spare;
  * only the six existing material slots are used, so `KitLib.MATERIAL_MAP`
    needs no new line for this file to render correctly.

Importing rather than copying is deliberate: if the house style moves in
build_kit.py it moves here too instead of quietly drifting a release later.

Anchors (identical to the main kit, so a placer reuses its wall/ceiling
transforms unchanged):
  BASEBOARD_*        wall frame — wall plane spans z in [-0.2, +0.2], detailed
                     face looks down +Z, origin on the floor at the module's
                     horizontal centre, runs along X.
  CORNER_TRIM_V      origin on the *inside corner point* of the room, base y = 0.
  CEIL_CABLE_TRAY_4M ceiling plane at y = 0, mass hangs below, runs along X.
  TRIM_COLUMN_CAP    base at y = 0, drops onto the RIB_COLUMN footprint.
"""

import json
import math
import os
import struct
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import build_kit as kit
from build_kit import FRONT, MI, WALL_H, Part

# ---------------------------------------------------------------- constants --

# This script writes exactly one file: assets/kit/limbo_trim.glb. It never
# touches nullvoid_kit.glb, and it never removes a file or a directory — the
# output is overwritten by name. build_kit.py owns the main kit; a second author
# writing into the same .glb, or clearing the folder that holds it, would be the
# one failure in this pipeline nobody could undo from a re-run.
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "kit")
OUT = os.path.normpath(OUT)

PROUD = 0.05      # how far the dressing stands off the wall face at its boldest.
                  # Big enough that a grazing beam throws a real drop shadow,
                  # small enough that a shoulder never clips it in a 3.2 m door.
KICK_H = 0.12     # skirting height. Machine-room skirting is knee-low, not
                  # domestic; 120 mm is what a mop bucket and a boot toe reach.
GAP = 0.039       # shadow-gap reveal above the kick plate. Under ~25 mm the gap
                  # fills with SSAO mush and stops reading as a gap at all.
KICK_LEAN = -14.0 # degrees. Bottom proud, sloping back as it rises: skirting is
                  # thickest where it is kicked, and the slope is a third surface
                  # angle between wall and floor, which is the whole point.


# ------------------------------------------------------------------ helpers --

def _studs(p, positions, radius=0.024, height=0.016, tilt=0.0, wear=0.35):
    """Pan-head fasteners.

    Deliberately kept *out* of the chamfer pass. A 6 mm chamfer on a 24 mm head
    is a quarter of the head, and the bevel would cost 68 tris per bolt against
    20 for the bare prism — on a module whose whole justification is being cheap
    that is the wrong trade. They are painted with a constant edge wear instead:
    proud hardware is the first thing a shoulder or a sleeve rubs bright, which
    is exactly the signal COLOR.r feeds to the surface shader.
    """
    for c in positions:
        faces = p.cyl(c, radius, height, MI["M_PanelTrim"], segments=6,
                      axis="z", smooth=True)
        if tilt:
            verts = {v for f in faces for v in f.verts}
            m = (Matrix.Translation(Vector(c))
                 @ Matrix.Rotation(math.radians(tilt), 4, "X")
                 @ Matrix.Translation(-Vector(c)))
            bmesh.ops.transform(p.bm, matrix=m, verts=list(verts))
        p._paint(faces, wear)


def _cable(p, y, z, radius, mat, xs, sag, segments=6):
    """One slack cable lofted along X with a real sag profile.

    Built by hand rather than as a chain of `cyl` calls because a chain cannot
    bend: the sag has to live in the ring positions, and lofting N rings costs
    (N-1)*12 + 8 tris against N*20 for the chain. The rings are also kept out of
    the chamfer pass — a 6 mm bevel on a 26 mm cable would eat the cable.
    """
    bm = p.bm
    rings = []
    for x in xs:
        ring = []
        for k in range(segments):
            a = math.tau * k / segments
            ring.append(bm.verts.new((
                x,
                y + sag(x) + math.sin(a) * radius,
                z + math.cos(a) * radius,
            )))
        rings.append(ring)

    faces = []
    for r0, r1 in zip(rings, rings[1:]):
        for k in range(segments):
            k2 = (k + 1) % segments
            faces.append(bm.faces.new((r0[k], r0[k2], r1[k2], r1[k])))
    for f in faces:
        f.smooth = True
    caps = [bm.faces.new(list(reversed(rings[0]))), bm.faces.new(rings[-1])]
    for f in caps:
        f.smooth = False
    faces += caps

    for f in faces:
        f.material_index = mat
        p.smooth_faces.add(f)
    bm.normal_update()
    p._uv(faces, 0, (xs[0], y, z))
    p._paint(faces, 0.0)
    return faces


def _tray_sag(x, dip=0.045, joint=0.020, hanger=1.2, half=2.0):
    """Downward offset of a cable at station x.

    Two spans repeat along a run of these modules: the 2.4 m between this
    module's own two hangers, and the 1.6 m that straddles the joint with the
    next module. Sag goes as the square of the span, so the joint dip is
    deliberately less than half the mid-span dip — and both parabolas are flat
    at x = +-2.0 so two modules butted together make one continuous catenary
    instead of a visible kink at every 4 m.
    """
    ax = abs(x)
    if ax <= hanger:
        return -dip * (1.0 - (ax / hanger) ** 2)
    u = (half - ax) / (half - hanger)
    return -joint * (1.0 - u * u)


# ------------------------------------------------------------------ modules --

def _baseboard(length):
    """Wall/floor junction trim. See BASEBOARD_4M for the section drawing."""
    p = Part()

    # Backer. Sits 15 mm proud of the wall face on purpose: coplanar with the
    # wall's own bottom rail it would z-fight, and it has to be *behind* the
    # shadow gap or you can see daylight through the module.
    p.box((0, 0.10, FRONT - 0.015), (length, 0.20, 0.06), MI["M_PanelDark"])

    # Kick plate. 120 mm tall, bottom edge 50 mm proud, leaning back 30 mm as it
    # rises. The lean is the load-bearing detail: it gives the junction a third
    # surface normal that is neither the wall's nor the floor's, so a torch
    # sweeping the corridor lights it a beat before it lights either.
    p.rotated_box((0, 0.063, 0.216), (length, KICK_H, 0.04),
                  MI["M_PanelTrim"], KICK_LEAN, axis="x")

    # Floor shoe. The one part that touches the deck, and the only part that
    # gets replaced when someone reverses a pallet truck into it.
    p.box((0, 0.011, 0.229), (length, 0.022, 0.046), MI["M_PanelTrim"])

    # Cap rail. Overhangs the kick plate by 24 mm so the 39 mm reveal below it is
    # in its own shadow at every light angle rather than only at grazing ones.
    p.box((0, 0.185, 0.222), (length, 0.04, 0.045), MI["M_PanelTrim"])

    # Fasteners on the kick face, on a 1 m pitch measured through the module
    # joint: a 4 m module and a 2 m module butted together still read as one
    # unbroken bolt line, which is what stops the tiling from showing.
    xs = [x for x in [-1.5, -0.5, 0.5, 1.5] if abs(x) < length * 0.5]
    _studs(p, [(x, 0.0678, 0.2374) for x in xs], tilt=KICK_LEAN)
    return p


def baseboard_4m():
    """Section through the module, looking along -X (z to the right, y up):

        0.205 ┤        ####      cap rail, 24 mm overhang
        0.165 ┤        ##
              ┤       ....       shadow gap, 39 mm, 30 mm deep
        0.126 ┤      ###
              ┤     ####         kick plate, leaning back 14 deg
        0.000 ┤   #######        floor shoe, 52 mm proud

    Origin is the wall's origin, not the baseboard's: the placer feeds it the
    same transform it feeds WALL_4x4_PANEL and the trim lands on the floor line.
    """
    return _baseboard(4.0), "BASEBOARD_4M"


def baseboard_2m():
    """The SPLIT_2M variant. Identical section, two bolts instead of four, so a
    2 m wall slot next to a 4 m one keeps the 1 m bolt pitch across the joint."""
    return _baseboard(2.0), "BASEBOARD_2M"


def corner_trim_v():
    """Vertical inside-corner post, 4 m tall, L-shaped in plan.

    ORIENTATION — a placer must know this to rotate it in 90 degree steps:

        plan view, +X right, +Z up the page

            +Z
             |   .............
             |   :           :   <- room interior, the L opens this way
        0.10 +##.:...........:
             |##
             |####################
        0    o####################----- +X
             0   0.035        0.10

    The origin `o` is the **inside corner point of the room**: the intersection
    of the two wall face planes, i.e. the corner the player can see, not the
    centre of the structural corner. One leg lies on the wall face that runs
    along +X, the other on the face that runs along +Z, and both stand 35 mm
    proud of them. Yaw +90 deg about Y takes it to the next corner handedness.

    The 35 mm overlap square at the origin is the entire job: two wall modules
    meeting at 90 degrees leave a vertical hairline there that no amount of
    lighting hides, and this covers it with a real folded arris that reads as
    fabricated rather than as a seam.
    """
    p = Part()
    leg, t = 0.10, 0.035

    # The two legs overlap in the 35 mm square at the corner rather than mitring
    # into it. An overlap cannot open up at any camera angle; a mitre can.
    p.box((leg * 0.5, WALL_H * 0.5, t * 0.5), (leg, WALL_H, t), MI["M_PanelDark"])
    p.box((t * 0.5, WALL_H * 0.5, leg * 0.5), (t, WALL_H, leg), MI["M_PanelDark"])

    # Base and head collars. A 4 m extrusion that simply stops at the floor
    # reads as a clipping error; a thicker collar at each end reads as a fixing.
    for y in (0.06, WALL_H - 0.06):
        p.box((0.055, y, 0.025), (0.11, 0.12, 0.05), MI["M_PanelTrim"])
        p.box((0.025, y, 0.055), (0.05, 0.12, 0.11), MI["M_PanelTrim"])

    # Three bolt clusters, one pair per cluster so each cluster straddles the
    # corner. Off-centre heights (not 1/2/3 m) so a run of these posts down a
    # corridor does not line its hardware up with the wall modules' own bolts.
    for y in (0.55, 2.00, 3.45):
        _studs(p, [(0.062, y, t + 0.007)], radius=0.020, height=0.014)
        _studs(p, [(t + 0.007, y, 0.062)], radius=0.020, height=0.014)
    return p, "CORNER_TRIM_V"


def ceil_cable_tray_4m():
    """Ladder tray on two drop hangers, 4 m along X, ceiling plane at y = 0.

    Hangs 350 mm proud of the ceiling. That number is chosen against the kit's
    other ceiling furniture: CEIL_4x4_MODULE's duct bottoms out at -0.73 and
    PIPE_RUN_4M at -0.38, so a tray at -0.38 shares a plane with the pipe run and
    can be alternated with it along a corridor without a collision pass.

    The cables are the point. A tray full of dead-straight cylinders reads as
    modelled; the same cables sagging 45 mm between hangers and 20 mm across the
    module joint read as installed, and cost nothing extra because the sag lives
    in the loft ring positions rather than in more rings.
    """
    p = Part()
    rail_z, rail_y = 0.19, -0.335   # rail centreline
    xs = (-2.0, -1.2, -0.6, 0.0, 0.6, 1.2, 2.0)   # loft stations, ends on the
                                                  # module boundary so runs join

    # Side rails. Channel section, 90 mm deep.
    for sz in (-1, 1):
        p.box((0, rail_y, sz * rail_z), (4.0, 0.09, 0.03), MI["M_PanelTrim"])

    # Rungs on a 250 mm pitch, offset half a pitch from the module edge so a
    # 4 m run of trays keeps one unbroken ladder instead of doubling a rung.
    x = -1.875
    while x < 1.9:
        p.box((x, -0.366, 0), (0.035, 0.022, 0.38), MI["M_Grate"])
        x += 0.25

    # Two drop hangers, outboard of the -Z rail with a cradle arm reaching under
    # the tray. Hangers at +-1.2 rather than the quarter points because that is
    # what makes the mid-span and joint-span sags land at 2.4 m and 1.6 m.
    for hx in (-1.2, 1.2):
        p.box((hx, -0.203, -0.215), (0.05, 0.406, 0.028), MI["M_PanelTrim"])
        p.box((hx, -0.393, 0.0), (0.05, 0.024, 0.46), MI["M_PanelTrim"])

    # Bundle: four slack cables of graded radius plus one stiff armoured run that
    # does *not* sag. The mismatch is the tell that sells the rest — every cable
    # sagging by the same amount reads as a modifier, one that refuses reads as
    # a different spec of cable.
    for z, r in ((-0.13, 0.032), (-0.06, 0.026), (0.005, 0.026), (0.075, 0.020)):
        _cable(p, -0.29 - r - 0.005, z, r, MI["M_Conduit"], xs, _tray_sag)
    p.cyl((0, -0.325, 0.14), 0.030, 4.0, MI["M_Conduit"], segments=6, axis="x")

    # One teal line along the top of the inboard rail. At 15 m the tray is four
    # dark pixels; this is the part that still says "there is structure up there"
    # and gives the data-flow shader somewhere to push a packet.
    p.strip((0, -0.283, rail_z), (3.7, 0.014, 0.02), MI["M_EmissiveTeal"])
    return p, "CEIL_CABLE_TRAY_4M"


def trim_column_cap():
    """Collar for the RIB_COLUMN foot and head. 500 mm tall, base at y = 0.

    RIB_COLUMN's end plate is 0.66 x 0.72 and stops dead on the deck, so the
    column meets the floor at a hard 90 degree arris four times over. This is a
    flared plinth that wraps it: 0.84 x 0.96 where it touches the floor,
    narrowing to 0.62 x 0.78 at the top, so the column never actually meets the
    floor in shot — the plinth does, at an angle, with a chamfer on the contact.

    TWO PER COLUMN. The head copy is this mesh mirrored in Y and translated to
    the storey height: place at y = 4.0 with basis scaled (1, -1, 1). Authoring
    it once and mirroring is why the collar is symmetric in X and Z.
    """
    p = Part()

    # Four tapered skirt panels. Each is wider than the ring it belongs to, so
    # the panels cross at the corners and seal them — no gap to see through at a
    # grazing angle, and the crossing chamfers read as a mitre for free.
    lean = 16.0
    p.rotated_box((0, 0.175, 0.40), (0.88, 0.36, 0.06), MI["M_PanelTrim"], -lean, axis="x")
    p.rotated_box((0, 0.175, -0.40), (0.88, 0.36, 0.06), MI["M_PanelTrim"], lean, axis="x")
    p.rotated_box((0.34, 0.175, 0), (0.06, 0.36, 0.88), MI["M_PanelTrim"], lean, axis="z")
    p.rotated_box((-0.34, 0.175, 0), (0.06, 0.36, 0.88), MI["M_PanelTrim"], -lean, axis="z")

    # Cap band. Grips the I-section's flange tips (x +-0.23, z +-0.325) rather
    # than floating around them, so the collar looks clamped on, not slid on.
    p.box((0, 0.42, 0), (0.62, 0.16, 0.78), MI["M_PanelDark"])
    return p, "TRIM_COLUMN_CAP"


MODULES = [
    baseboard_4m, baseboard_2m, corner_trim_v,
    ceil_cable_tray_4m, trim_column_cap,
]

BUDGET = {
    "BASEBOARD_4M": 350, "BASEBOARD_2M": 350, "CORNER_TRIM_V": 400,
    "CEIL_CABLE_TRAY_4M": 1400, "TRIM_COLUMN_CAP": 250,
}


# ------------------------------------------------------- glTF COLOR_0 repair --
#
# Blender 5.2.0's glTF exporter writes a real COLOR_0 stream only for the FIRST
# primitive of a multi-material mesh. Every later primitive gets a placeholder
# filled with opaque white. Reproduced on a bare two-cube mesh under
# --factory-startup, and it is independent of the attribute domain (CORNER or
# POINT), its type (FLOAT_COLOR or BYTE_COLOR), export_apply, the container
# format, and whether the material actually references the attribute.
#
# White is the worst possible failure value here, because it is not a crash and
# not even obviously wrong in a viewer: it hands nv_surface.gdshader wear = 1 and
# height = 1 on every surface that is not in the first material slot, which
# switches on the full edge polish and switches off the floor grime everywhere at
# once. The kit would just look uniformly plastic and nobody would know why.
#
# The workaround: export one single-material object per slot — each of those is
# primitive 0 of its own mesh, so each gets a correct COLOR_0 — and then stitch
# the primitives back into one mesh per module in the container afterwards. Only
# the JSON is rewritten; the binary chunk the exporter produced is passed
# through untouched, so the geometry is exactly what Blender wrote.

def _split_by_material(obj):
    """One single-material mesh per slot the module actually uses."""
    me = obj.data
    out = []
    for mi in sorted({p.material_index for p in me.polygons}):
        bm = bmesh.new()
        bm.from_mesh(me)
        drop = [f for f in bm.faces if f.material_index != mi]
        if drop:
            bmesh.ops.delete(bm, geom=drop, context="FACES")
        for f in bm.faces:
            f.material_index = 0
        nm = bpy.data.meshes.new("%s_%d" % (obj.name, mi))
        bm.to_mesh(nm)
        bm.free()
        nm.materials.append(bpy.data.materials[kit.MATERIALS[mi][0]])
        # Same trap as on the whole mesh: bmesh leaves no active colour index,
        # and export_vertex_color="ACTIVE" then silently exports nothing.
        if len(nm.color_attributes):
            nm.color_attributes.active_color_index = 0
            nm.color_attributes.render_color_index = 0
        out.append((mi, nm))
    return out


def _read_glb(path):
    with open(path, "rb") as f:
        d = f.read()
    off, js, blob = 12, None, b""
    while off < len(d):
        ln, ty = struct.unpack_from("<I4s", d, off)
        chunk = d[off + 8:off + 8 + ln]
        if ty == b"JSON":
            js = json.loads(chunk)
        elif ty[:3] == b"BIN":
            blob = chunk
        off += 8 + ln + ((4 - ln % 4) % 4)
    return js, blob


def _write_glb(path, js, blob):
    j = json.dumps(js, separators=(",", ":")).encode("utf-8")
    j += b" " * ((4 - len(j) % 4) % 4)
    b = blob + b"\x00" * ((4 - len(blob) % 4) % 4)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(j) + 8 + len(b)))
        f.write(struct.pack("<I4s", len(j), b"JSON"))
        f.write(j)
        f.write(struct.pack("<I4s", len(b), b"BIN\x00"))
        f.write(b)


def _merge_slots(path, layout):
    """Fold the per-slot meshes back into one mesh + one node per module, so the
    file KitLib opens has exactly the shape it expects: top level nodes named
    after modules, each mesh carrying one surface per material slot."""
    js, blob = _read_glb(path)
    node_by_name = {n["name"]: n for n in js["nodes"] if "mesh" in n}
    meshes, nodes = [], []
    for name, slots in layout:
        prims = []
        for sn in slots:
            src = node_by_name[sn]
            prims += js["meshes"][src["mesh"]]["primitives"]
        nodes.append({"name": name, "mesh": len(meshes)})
        meshes.append({"name": name, "primitives": prims})
    js["meshes"] = meshes
    js["nodes"] = nodes
    js["scenes"] = [{"name": "Scene", "nodes": list(range(len(nodes)))}]
    js["scene"] = 0
    _write_glb(path, js, blob)


# --------------------------------------------------------------------- main --

_CT = {5120: "<i1", 5121: "<u1", 5122: "<i2", 5123: "<u2", 5125: "<u4", 5126: "<f4"}
_NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def _accessor(js, blob, i):
    a = js["accessors"][i]
    bv = js["bufferViews"][a["bufferView"]]
    if bv.get("byteStride"):
        raise RuntimeError("interleaved bufferView, reader needs updating")
    dt = np.dtype(_CT[a["componentType"]])
    n = _NC[a["type"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    arr = np.frombuffer(blob, dtype=dt, count=a["count"] * n, offset=off)
    arr = arr.reshape(a["count"], n).astype(np.float64)
    if a.get("normalized"):
        arr /= np.iinfo(dt).max
    return arr


def verify(path, expected):
    """Re-open the file and read the masks straight out of its binary chunk.

    Two passes, because they catch different failures. Blender's importer proves
    the container is well formed and that the module and slot names survived —
    but it converts COLOR_0 into a BYTE_COLOR attribute on the way in, so its
    values are not evidence of anything. The raw accessor decode is the one that
    matters: it reads the exact bytes Godot will read, and checks them against
    the contract, which is that G must equal clamp(y / 4) on every vertex of
    every primitive. A dropped or white-filled COLOR_0 fails that by ~1.0, which
    is the whole point — a broken mask does not throw, it just quietly makes the
    kit look cheap.
    """
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    loaded = {o.name: sum(len(p.vertices) - 2 for p in o.data.polygons)
              for o in bpy.context.scene.objects if o.type == "MESH"}

    js, blob = _read_glb(path)
    print("\n--- re-opened %s ---" % os.path.basename(path))
    ok = True
    for name in expected:
        if name not in loaded:
            print("  %-22s DID NOT LOAD" % name)
            ok = False
            continue
        mesh = next(m for m in js["meshes"] if m["name"] == name)
        tris, err, wear, slots = 0, 0.0, [], []
        for pr in mesh["primitives"]:
            slots.append(js["materials"][pr["material"]]["name"])
            tris += len(_accessor(js, blob, pr["indices"])) // 3
            if "COLOR_0" not in pr["attributes"]:
                err, ok = 9.99, False
                continue
            c = _accessor(js, blob, pr["attributes"]["COLOR_0"])
            p = _accessor(js, blob, pr["attributes"]["POSITION"])
            err = max(err, np.abs(c[:, 1] - np.clip(p[:, 1] / WALL_H, 0, 1)).max())
            wear.append(c[:, 0])
        wear = np.concatenate(wear) if wear else np.zeros(1)
        # 0.02 covers the chamfer and the 14 deg kick lean, both of which move a
        # vertex after _paint has already sampled its height. White fails by 1.0.
        bad = err > 0.02
        ok = ok and not bad
        print("  %-22s %5d tris  height err %.4f%s  wear %.0f%% lit  [%s]"
              % (name, tris, err, "  <-- BROKEN" if bad else "",
                 100.0 * (wear > 0.99).mean(), ", ".join(slots)))
    extra = sorted(set(loaded) - set(expected))
    if extra:
        print("  unexpected objects: %s" % ", ".join(extra))
    print("  verify: %s" % ("OK" if ok else "FAILED"))
    return ok


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    kit.make_materials()

    total = 0
    report = []
    layout = []
    for fn in MODULES:
        part, name = fn()
        obj, tris = part.to_object(name)
        obj.location = (0, 0, 0)
        total += tris
        report.append((name, tris))
        # Explode into one object per material slot for the export, then put the
        # module back together in the container. See the COLOR_0 repair block.
        slots = []
        for mi, me in _split_by_material(obj):
            sub = bpy.data.objects.new("%s@%s" % (name, kit.MATERIALS[mi][0]), me)
            bpy.context.collection.objects.link(sub)
            slots.append(sub.name)
        layout.append((name, slots))
        bpy.data.objects.remove(obj, do_unlink=True)

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "limbo_trim.glb")
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_materials="EXPORT",
        export_normals=True,
        export_texcoords=True,
        # COLOR_0 carries the edge-wear / height masks the surface shader reads.
        export_vertex_color="ACTIVE",
        export_all_vertex_colors=False,
        export_active_vertex_color_when_no_material=True,
        use_selection=False,
    )
    _merge_slots(path, layout)

    print("\n=== LIMBO PROTOCOL trim kit ===")
    for name, tris in report:
        budget = BUDGET.get(name, 0)
        flag = "  OVER (budget %d)" % budget if tris > budget else ""
        print(f"  {name:<24} {tris:>6} tris{flag}")
    print(f"  {'TOTAL':<24} {total:>6} tris")
    print(f"  -> {path}")

    verify(path, [name for name, _ in report])


if __name__ == "__main__":
    main()
