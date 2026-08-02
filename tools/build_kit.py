#!/usr/bin/env python3
"""NULLVOID look-dev architecture kit — Blender 5.2 headless mesh author.

Run:  blender --factory-startup --background --python tools/build_kit.py

Authoring conventions
---------------------
Everything below is written in **Godot space** (Y up, -Z forward, 1 unit = 1 m)
and rotated into Blender space (+90 deg about X) as the very last step before
the mesh is written.  So when you read `box((0, 2, 0), (4, 4, 0.4))` you are
reading the numbers you will type into Godot, not a transposed version of them.

Module anchors:
  walls      wall plane spans z in [-0.2, +0.2]; the detailed face looks down +Z;
             origin sits on the floor at the module's horizontal centre.
  floors     top surface at y = 0, mass hangs below.
  ceilings   visible underside at y = 0..0.1, mass and hanging kit around it.
  columns    base at y = 0.

Modular grid: 4 m and 2 m footprints, 4 m storey height, 0.4 m wall thickness —
the same numbers `GeometryKit` already uses, so the kit drops onto the existing
procgen lattice without a re-grid.

Why so many small boxes: every module is built additively out of a back plate, a
proud border frame and recessed inner plates.  No booleans, no n-gon cleanup —
and the 6 mm chamfer applied to every hard edge at the end is what makes the
whole thing read as expensive.  A chamfer is a 6 mm wide surface that faces a
different direction than its neighbours, so it catches a specular highlight the
flat face cannot.  That single line of bevel does more for perceived cost than
any texture in the kit.
"""

import json
import math
import os
import struct
import sys

import bpy
import bmesh
from mathutils import Matrix, Vector

# ---------------------------------------------------------------- constants --

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "kit")
OUT = os.path.normpath(OUT)

WALL_T = 0.4           # wall thickness, matches GeometryKit.WALL_THICKNESS
WALL_H = 4.0           # storey height
FRONT = WALL_T * 0.5   # +0.2 : the plane the detailed face lives on
BORDER = 0.14          # proud frame width around a wall module
RECESS = 0.06          # how far an inner plate sits behind the frame face
CHAMFER = 0.006        # 6 mm — reads at 1-3 m, invisible in silhouette

DOOR_W = 3.2           # matches GeometryKit.DOOR_WIDTH
DOOR_H = 3.4           # matches GeometryKit.DOOR_HEIGHT

# Material slots.  Godot re-binds these by name; the colours here only matter as
# a fallback if someone opens the .glb in a viewer that has no NULLVOID shaders.
MATERIALS = [
    ("M_PanelDark",    (0.048, 0.051, 0.058, 1.0), 0.0,  0.85, None),
    ("M_PanelTrim",    (0.086, 0.090, 0.100, 1.0), 0.65, 0.42, None),
    ("M_FloorPlate",   (0.038, 0.041, 0.048, 1.0), 0.25, 0.45, None),
    ("M_Grate",        (0.055, 0.058, 0.066, 1.0), 0.70, 0.55, None),
    ("M_Conduit",      (0.070, 0.074, 0.084, 1.0), 0.55, 0.50, None),
    ("M_EmissiveTeal", (0.100, 0.520, 0.680, 1.0), 0.0,  0.60, (0.16, 0.78, 1.0)),
]
MI = {name: i for i, (name, _, _, _, _) in enumerate(MATERIALS)}


# ------------------------------------------------------------------ bmesh io --

class Part:
    """A bmesh under construction plus the bookkeeping the chamfer pass needs."""

    def __init__(self):
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap")
        self.col = self.bm.loops.layers.float_color.new("Col")
        # Faces flagged here keep their edges out of the chamfer pass (curved
        # surfaces already have a highlight; chamfering an 8-gon just wastes
        # triangles) and get smooth shading instead.
        self.smooth_faces = set()

    # -- primitives ----------------------------------------------------------

    def box(self, center, size, mat, uv_axis=None, uv_origin=None):
        ret = bmesh.ops.create_cube(self.bm, size=1.0)
        verts = ret["verts"]
        bmesh.ops.scale(self.bm, vec=Vector(size), verts=verts)
        bmesh.ops.translate(self.bm, vec=Vector(center), verts=verts)
        faces = {f for v in verts for f in v.link_faces}
        for f in faces:
            f.material_index = mat
            f.smooth = False
        self._uv(faces, uv_axis, uv_origin or center)
        self._paint(faces, 0.0)
        return list(faces)

    def strip(self, center, size, mat):
        """An emissive inlay.  UVs run in metres along the strip's long axis so
        the data-flow shader can scroll a pulse down it at a real-world speed
        regardless of which way the strip is turned."""
        axis = max(range(3), key=lambda i: size[i])
        origin = Vector(center) - Vector(size) * 0.5
        return self.box(center, size, mat, uv_axis=axis, uv_origin=origin)

    def cyl(self, center, radius, length, mat, segments=8, axis="y", smooth=True):
        ret = bmesh.ops.create_cone(
            self.bm, cap_ends=True, cap_tris=False, segments=segments,
            radius1=radius, radius2=radius, depth=length,
        )
        verts = ret["verts"]
        rot = {"x": Matrix.Rotation(math.radians(90), 4, "Y"),
               "y": Matrix.Rotation(math.radians(90), 4, "X"),
               "z": Matrix.Identity(4)}[axis]
        bmesh.ops.transform(self.bm, matrix=rot, verts=verts)
        bmesh.ops.translate(self.bm, vec=Vector(center), verts=verts)
        faces = {f for v in verts for f in v.link_faces}
        for f in faces:
            f.material_index = mat
            f.smooth = smooth
            if smooth:
                self.smooth_faces.add(f)
        self._uv(faces, None, center)
        self._paint(faces, 0.0)
        return list(faces)

    def rotated_box(self, center, size, mat, angle_deg, axis="x"):
        faces = self.box(center, size, mat)
        verts = {v for f in faces for v in f.verts}
        idx = {"x": "X", "y": "Y", "z": "Z"}[axis]
        m = (Matrix.Translation(Vector(center))
             @ Matrix.Rotation(math.radians(angle_deg), 4, idx)
             @ Matrix.Translation(-Vector(center)))
        bmesh.ops.transform(self.bm, matrix=m, verts=list(verts))
        return faces

    # -- helpers -------------------------------------------------------------

    def _uv(self, faces, uv_axis, origin):
        for f in faces:
            n = f.normal
            dom = max(range(3), key=lambda i: abs(n[i]))
            if uv_axis is not None and uv_axis != dom:
                ua = uv_axis
                va = next(i for i in range(3) if i != ua and i != dom)
            else:
                ua, va = [(2, 1), (0, 2), (0, 1)][dom]
            for loop in f.loops:
                co = loop.vert.co
                loop[self.uv].uv = (co[ua] - origin[ua], co[va] - origin[va])

    def _paint(self, faces, edge_wear):
        for f in faces:
            for loop in f.loops:
                co = loop.vert.co
                # R = edge wear (filled in by the chamfer pass)
                # G = height gradient, 0 at the floor -> shaders pool grime low
                # B = spare
                loop[self.col] = (edge_wear, min(max(co[1] / WALL_H, 0.0), 1.0), 0.0, 1.0)

    # -- finish --------------------------------------------------------------

    def chamfer(self, offset=CHAMFER, min_angle=0.30):
        bm = self.bm
        edges = []
        for e in bm.edges:
            if len(e.link_faces) != 2:
                continue
            if e.link_faces[0] in self.smooth_faces or e.link_faces[1] in self.smooth_faces:
                continue
            if e.calc_face_angle(0.0) > min_angle:
                edges.append(e)
        if not edges:
            return
        res = bmesh.ops.bevel(
            bm, geom=edges, offset=offset, offset_type="OFFSET", segments=1,
            profile=0.5, affect="EDGES", clamp_overlap=True, loop_slide=True,
        )
        # Mark the new chamfer faces so the surface shader can brighten and
        # polish them: worn metal edges are the first thing to lose its coating.
        for f in res["faces"]:
            f.smooth = False
            for loop in f.loops:
                c = loop[self.col]
                loop[self.col] = (1.0, c[1], c[2], 1.0)

    def to_object(self, name):
        self.chamfer()
        bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces)
        # Godot space -> Blender space.  glTF then flips it back on export, so
        # the numbers written above land unchanged in the engine.
        bmesh.ops.transform(
            self.bm, matrix=Matrix.Rotation(math.radians(90), 4, "X"),
            verts=self.bm.verts,
        )
        mesh = bpy.data.meshes.new(name)
        self.bm.to_mesh(mesh)
        self.bm.free()
        # `bmesh.to_mesh` leaves `active_color_index = -1`, and the glTF
        # exporter's `export_vertex_color="ACTIVE"` then exports NOTHING. The
        # engine gets the default white for COLOR, which means wear = 1 and
        # height = 1 on every vertex in the kit: full edge polish everywhere,
        # grime nowhere. Both surface shaders read those two channels, so the
        # entire wear/grime system has been silently inert since the kit was
        # first built. One line.
        if len(mesh.color_attributes):
            mesh.color_attributes.active_color_index = 0
            mesh.color_attributes.render_color_index = 0
        obj = bpy.data.objects.new(name, mesh)
        for _, mat in sorted(_mats.items()):
            mesh.materials.append(mat)
        bpy.context.collection.objects.link(obj)
        tris = sum(len(p.vertices) - 2 for p in mesh.polygons)
        return obj, tris


_mats = {}


def make_materials():
    for i, (name, base, metallic, rough, emit) in enumerate(MATERIALS):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        bsdf = m.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = base
        bsdf.inputs["Metallic"].default_value = metallic
        bsdf.inputs["Roughness"].default_value = rough
        if emit:
            bsdf.inputs["Emission Color"].default_value = (*emit, 1.0)
            bsdf.inputs["Emission Strength"].default_value = 2.0
        _mats[i] = m


# ------------------------------------------------------------------ modules --

def _wall_shell(p, width, mat=MI["M_PanelDark"]):
    """Back plate + proud border frame shared by every wall module.

    The frame is the load-bearing trick: it sits at the full wall face while the
    inner plates sit 60 mm behind it, so every module edge is a real shadow gap
    that SSAO darkens and a grazing beam rakes across."""
    hw = width * 0.5
    p.box((0, WALL_H * 0.5, -0.1), (width, WALL_H, 0.2), mat)          # back plate
    z = FRONT - 0.1
    p.box((0, BORDER * 0.5, z), (width, BORDER, 0.2), mat)             # bottom rail
    p.box((0, WALL_H - BORDER * 0.5, z), (width, BORDER, 0.2), mat)    # top rail
    p.box((-hw + BORDER * 0.5, WALL_H * 0.5, z), (BORDER, WALL_H, 0.2), mat)
    p.box((hw - BORDER * 0.5, WALL_H * 0.5, z), (BORDER, WALL_H, 0.2), mat)


def _bay(width):
    """Inner clear area of a wall module: (x0, x1, y0, y1)."""
    hw = width * 0.5
    return (-hw + BORDER, hw - BORDER, BORDER, WALL_H - BORDER)


def _plate(p, x0, x1, y0, y1, depth=RECESS, mat=MI["M_PanelDark"]):
    if x1 - x0 <= 0.001 or y1 - y0 <= 0.001:
        return
    front = FRONT - depth
    p.box(((x0 + x1) * 0.5, (y0 + y1) * 0.5, front - 0.06),
          (x1 - x0, y1 - y0, 0.12), mat)


def _bolts(p, xs, ys, z=FRONT - RECESS, r=0.035):
    for x in xs:
        for y in ys:
            p.cyl((x, y, z + 0.012), r, 0.024, MI["M_PanelTrim"], segments=6,
                  axis="z", smooth=False)


def wall_panel_4m():
    """The workhorse: two big recessed bays split by a proud service band."""
    p = Part()
    w = 4.0
    _wall_shell(p, w)
    x0, x1, y0, y1 = _bay(w)
    band_y, band_h = 1.9, 0.22
    _plate(p, x0, x1, y0, band_y - band_h * 0.5)
    _plate(p, x0, x1, band_y + band_h * 0.5, y1)
    # Service band, proud of the frame so it throws a hard drop shadow.
    p.box((0, band_y, FRONT + 0.02), (w, band_h, 0.24), MI["M_PanelDark"])
    p.box((0, band_y, FRONT + 0.14), (w - 0.5, 0.05, 0.03), MI["M_PanelTrim"])
    _bolts(p, (x0 + 0.22, x1 - 0.22), (y0 + 0.22, band_y - 0.42, band_y + 0.42, y1 - 0.22))
    return p, "WALL_4x4_PANEL"


def wall_trace_4m():
    """Circuit-inlay wall.  The teal does not sit *on* the surface — the inner
    plates are broken around 100 mm channels and the emissive strips sit at the
    bottom of those channels, 40 mm down.  Light from an inlay bounces off two
    channel walls before it reaches you; that is what separates a lit groove
    from a painted line."""
    p = Part()
    w = 4.0
    _wall_shell(p, w)
    x0, x1, y0, y1 = _bay(w)
    h1, h2 = 0.95, 3.10        # horizontal channel centres
    ch = 0.11                  # channel width
    vx = (-1.10, 1.10)         # vertical channel centres
    floor_z = FRONT - RECESS - 0.05   # bottom of the channel

    _plate(p, x0, x1, y0, h1 - ch * 0.5)
    _plate(p, x0, x1, h2 + ch * 0.5, y1)
    segs = [(x0, vx[0] - ch * 0.5), (vx[0] + ch * 0.5, vx[1] - ch * 0.5), (vx[1] + ch * 0.5, x1)]
    for a, b in segs:
        _plate(p, a, b, h1 + ch * 0.5, h2 - ch * 0.5)

    # Verticals first, horizontals a hair proud, so crossings never co-plane.
    for x in vx:
        p.strip((x, (h1 + h2) * 0.5, floor_z + 0.017), (0.05, h2 - h1, 0.034),
                MI["M_EmissiveTeal"])
    for y in (h1, h2):
        p.strip((0, y, floor_z + 0.019), (w - BORDER * 2.4, 0.055, 0.038),
                MI["M_EmissiveTeal"])
    # Junction pips where the runs meet — data has to go somewhere.
    for x in vx:
        for y in (h1, h2):
            p.box((x, y, floor_z + 0.025), (0.16, 0.16, 0.05), MI["M_EmissiveTeal"])
    _bolts(p, (x0 + 0.2, x1 - 0.2), (y0 + 0.2, y1 - 0.2))
    return p, "WALL_4x4_TRACE"


def wall_armor_4m():
    """Heavy maintenance plate: a slab that stands *proud* of the frame instead
    of sinking into it, so the module silhouettes differently in a beam sweep."""
    p = Part()
    w = 4.0
    _wall_shell(p, w)
    x0, x1, y0, y1 = _bay(w)
    _plate(p, x0, x1, y0, y1, depth=RECESS + 0.03)
    # Armour slab with cut corners, faked as a big box plus two chamfer wedges.
    p.box((0, 2.05, FRONT + 0.06), (3.0, 2.6, 0.32), MI["M_PanelDark"])
    p.box((0, 2.05, FRONT + 0.20), (2.6, 2.2, 0.06), MI["M_PanelDark"])
    # Recessed hatch and its hardware.
    p.box((0, 2.05, FRONT + 0.14), (1.5, 1.2, 0.06), MI["M_PanelTrim"])
    for x in (-0.62, 0.62):
        for y in (1.58, 2.52):
            p.cyl((x, y, FRONT + 0.19), 0.055, 0.05, MI["M_PanelTrim"],
                  segments=6, axis="z", smooth=False)
    p.box((-1.24, 2.05, FRONT + 0.24), (0.10, 0.9, 0.05), MI["M_PanelTrim"])
    p.box((1.24, 2.05, FRONT + 0.24), (0.10, 0.9, 0.05), MI["M_PanelTrim"])
    # One status pip: a single point of teal on an otherwise dead wall.
    p.strip((1.24, 3.15, FRONT + 0.24), (0.07, 0.30, 0.05), MI["M_EmissiveTeal"])
    _bolts(p, (x0 + 0.2, x1 - 0.2), (y0 + 0.2, y1 - 0.2))
    return p, "WALL_4x4_ARMOR"


def wall_vent_2m():
    p = Part()
    w = 2.0
    _wall_shell(p, w)
    x0, x1, y0, y1 = _bay(w)
    # Deep black plenum behind the slats — the vent has to read as a hole.
    p.box((0, 2.0, FRONT - 0.30), (x1 - x0, 2.6, 0.10), MI["M_PanelDark"])
    _plate(p, x0, x1, y0, 0.66)
    _plate(p, x0, x1, 3.34, y1)
    # Louvre frame.
    p.box((0, 0.70, FRONT - 0.05), (x1 - x0, 0.10, 0.14), MI["M_PanelTrim"])
    p.box((0, 3.30, FRONT - 0.05), (x1 - x0, 0.10, 0.14), MI["M_PanelTrim"])
    p.box((0, 2.0, FRONT - 0.10), (0.09, 2.6, 0.16), MI["M_PanelTrim"])
    y = 0.85
    while y < 3.22:
        p.rotated_box((0, y, FRONT - 0.14), (x1 - x0 - 0.06, 0.055, 0.14),
                      MI["M_Grate"], -28.0, axis="x")
        y += 0.235
    _bolts(p, (x0 + 0.16, x1 - 0.16), (0.70, 3.30))
    return p, "WALL_2x4_VENT"


def wall_cable_2m():
    p = Part()
    w = 2.0
    _wall_shell(p, w)
    x0, x1, y0, y1 = _bay(w)
    _plate(p, x0, -0.34, y0, y1)
    _plate(p, 0.42, x1, y0, y1)
    # Open cable trough between the plates.
    p.box((0.04, 2.0, FRONT - 0.22), (0.80, WALL_H - BORDER * 2, 0.08), MI["M_PanelDark"])
    for x, r in ((-0.22, 0.052), (-0.09, 0.052), (0.05, 0.040), (0.16, 0.040)):
        p.cyl((x, 2.0, FRONT - 0.14), r, WALL_H - 0.3, MI["M_Conduit"], segments=8)
    p.cyl((0.30, 2.0, FRONT - 0.12), 0.085, WALL_H - 0.3, MI["M_Conduit"], segments=10)
    for y in (0.55, 1.55, 2.55, 3.55):
        p.box((0.04, y, FRONT - 0.19), (0.86, 0.10, 0.20), MI["M_PanelTrim"])
    # A single live core in the bundle.
    p.strip((-0.155, 2.0, FRONT - 0.075), (0.028, WALL_H - 0.6, 0.028), MI["M_EmissiveTeal"])
    return p, "WALL_2x4_CABLE"


def rib_column():
    """Structural I-rib.  Placed on the 2 m sub-grid at corridor joints it gives
    a beam something to break against — moving shadows as the player walks."""
    p = Part()
    p.box((0, WALL_H * 0.5, 0), (0.13, WALL_H, 0.46), MI["M_PanelDark"])
    p.box((0, WALL_H * 0.5, 0.27), (0.46, WALL_H, 0.11), MI["M_PanelDark"])
    p.box((0, WALL_H * 0.5, -0.27), (0.46, WALL_H, 0.11), MI["M_PanelDark"])
    for y in (0.09, WALL_H - 0.09):
        p.box((0, y, 0), (0.66, 0.18, 0.72), MI["M_PanelTrim"])
    for y in (1.0, 2.0, 3.0):
        p.box((0, y, 0), (0.34, 0.12, 0.52), MI["M_PanelTrim"])
    _bolts(p, (-0.24, 0.24), (0.09, WALL_H - 0.09), z=0.36, r=0.04)
    p.strip((0, WALL_H * 0.5, 0.33), (0.035, WALL_H - 0.8, 0.02), MI["M_EmissiveTeal"])
    return p, "RIB_COLUMN"


def floor_plate_4m():
    p = Part()
    # Sub-slab, top at -0.02: the 20 mm step is the seam every plate sits in.
    p.box((0, -0.16, 0), (4.0, 0.28, 4.0), MI["M_FloorPlate"])
    p.box((0, -0.01, 0), (3.86, 0.02, 3.86), MI["M_FloorPlate"])
    # Slight height variation: one quadrant is a hair proud, one is sunk. Under
    # a raking beam this is the difference between a floor and a plane.
    p.box((-0.97, -0.003, -0.97), (1.78, 0.006, 1.78), MI["M_FloorPlate"])
    p.box((0.97, -0.022, 0.97), (1.72, 0.02, 1.72), MI["M_FloorPlate"])
    for x in (-1.72, 1.72):
        for z in (-1.72, 1.72):
            p.cyl((x, -0.004, z), 0.055, 0.02, MI["M_PanelTrim"], segments=6, smooth=False)
    return p, "FLOOR_4x4_PLATE"


def floor_trace_4m():
    p = Part()
    p.box((0, -0.16, 0), (4.0, 0.28, 4.0), MI["M_FloorPlate"])
    ch = 0.09
    for sx in (-1, 1):
        for sz in (-1, 1):
            cx = sx * (1.0 + ch * 0.25)
            cz = sz * (1.0 + ch * 0.25)
            p.box((cx, -0.01, cz), (1.86 - ch * 0.5, 0.02, 1.86 - ch * 0.5),
                  MI["M_FloorPlate"])
    # Inlay sits 30 mm below the walking surface — you see the glow, never the
    # source, and it survives being stood on.
    p.strip((0, -0.043, 0), (3.7, 0.018, ch * 0.62), MI["M_EmissiveTeal"])
    p.strip((0, -0.045, 0), (ch * 0.62, 0.018, 3.7), MI["M_EmissiveTeal"])
    p.box((0, -0.038, 0), (0.20, 0.02, 0.20), MI["M_EmissiveTeal"])
    return p, "FLOOR_4x4_TRACE"


def floor_grate_2m():
    p = Part()
    # Sunken pan so the grate has real darkness under it.
    p.box((0, -0.45, 0), (2.0, 0.10, 2.0), MI["M_PanelDark"])
    for sx in (-1, 1):
        p.box((sx * 0.95, -0.15, 0), (0.10, 0.26, 2.0), MI["M_PanelTrim"])
        p.box((0, -0.15, sx * 0.95), (1.80, 0.26, 0.10), MI["M_PanelTrim"])
    z = -0.82
    while z <= 0.83:
        p.box((0, -0.06, z), (1.80, 0.08, 0.035), MI["M_Grate"])
        z += 0.113
    for x in (-0.6, 0.0, 0.6):
        p.box((x, -0.085, 0), (0.035, 0.05, 1.80), MI["M_Grate"])
    return p, "FLOOR_2x2_GRATE"


def ceiling_module_4m():
    """Ceiling with a coffer and things that hang out of it.  Hanging kit is
    what stops a corridor reading as a tube: it breaks the top of frame and gives
    the fog beams something to cut around."""
    p = Part()
    p.box((0, 0.26, 0), (4.0, 0.30, 4.0), MI["M_PanelDark"])          # deck
    for sx in (-1, 1):
        p.box((sx * 1.93, 0.055, 0), (0.14, 0.11, 4.0), MI["M_PanelDark"])
        p.box((0, 0.055, sx * 1.93), (3.72, 0.11, 0.14), MI["M_PanelDark"])
    p.box((0, 0.05, 0), (4.0, 0.10, 0.20), MI["M_PanelTrim"])         # cross ribs
    p.box((0, 0.05, 0), (0.20, 0.10, 4.0), MI["M_PanelTrim"])
    # Recessed light slot: housing sunk into the coffer, emitter face flush.
    p.box((-1.0, 0.06, 1.0), (1.30, 0.14, 0.30), MI["M_PanelTrim"])
    p.strip((-1.0, -0.012, 1.0), (1.10, 0.02, 0.16), MI["M_EmissiveTeal"])
    # Hanging duct.
    p.box((1.05, -0.42, -0.75), (0.72, 0.62, 3.0), MI["M_Conduit"])
    for z in (-1.6, -0.2, 1.2):
        p.box((1.05, -0.42, z), (0.80, 0.70, 0.08), MI["M_PanelTrim"])
    for x in (0.78, 1.32):
        p.box((x, -0.06, -0.75), (0.06, 0.24, 2.9), MI["M_PanelTrim"])
    # Cable drop with a junction can on the end.
    for x, z in ((-1.55, -1.2), (-1.42, -1.2)):
        p.cyl((x, -0.35, z), 0.025, 0.72, MI["M_Conduit"], segments=6)
    p.box((-1.48, -0.78, -1.2), (0.34, 0.20, 0.26), MI["M_Conduit"])
    p.strip((-1.48, -0.885, -1.2), (0.16, 0.02, 0.10), MI["M_EmissiveTeal"])
    return p, "CEIL_4x4_MODULE"


def pipe_run_4m():
    """Ceiling-hung service run, 4 m along X.  Anchor at the ceiling plane."""
    p = Part()
    for z, r in ((-0.18, 0.075), (0.0, 0.075), (0.20, 0.055)):
        p.cyl((0, -0.30, z), r, 4.0, MI["M_Conduit"], segments=10, axis="x")
    for z in (0.34, 0.40, 0.46):
        p.cyl((0, -0.24, z), 0.018, 4.0, MI["M_Conduit"], segments=6, axis="x")
    for x in (-1.4, 0.0, 1.4):
        p.box((x, -0.16, 0.12), (0.09, 0.32, 0.86), MI["M_PanelTrim"])
        p.box((x, -0.40, 0.12), (0.09, 0.10, 0.86), MI["M_PanelTrim"])
    p.strip((0, -0.222, 0.20), (3.4, 0.016, 0.03), MI["M_EmissiveTeal"])
    return p, "PIPE_RUN_4M"


def doorframe_hero():
    """Hero piece #1.  A 3.2 x 3.4 m opening in a 4 m module, with a three-step
    reveal driving into the wall.  Each step is a fresh chamfer ring, so the
    frame draws four bright contour lines around the exit even in near-darkness
    — the navigation beacon the layer needs, made of geometry instead of a
    glowing rectangle."""
    p = Part()
    w, hw = 4.0, 2.0
    ohw, oh = DOOR_W * 0.5, DOOR_H
    # Structural surround.
    p.box((0, (oh + WALL_H) * 0.5, 0), (w, WALL_H - oh, WALL_T), MI["M_PanelDark"])
    for sx in (-1, 1):
        cx = sx * (ohw + (hw - ohw) * 0.5)
        p.box((cx, oh * 0.5, 0), (hw - ohw, oh, WALL_T), MI["M_PanelDark"])

    # Three-step reveal: each ring steps 90 mm further into the opening and
    # 130 mm deeper into the wall.
    steps = ((0.00, 0.13, MI["M_PanelDark"]),
             (0.09, 0.00, MI["M_PanelTrim"]),
             (0.17, -0.13, MI["M_PanelDark"]))
    for inset, zc, mat in steps:
        d = 0.13
        for sx in (-1, 1):
            p.box((sx * (ohw - inset * 0.5), oh * 0.5, zc), (inset + 0.10, oh, d), mat) \
                if inset > 0 else None
        if inset > 0:
            p.box((0, oh - inset * 0.5, zc), (DOOR_W, inset + 0.10, d), mat)
    # Chamfered lip at the room-side mouth: the brightest contour.
    for sx in (-1, 1):
        p.box((sx * (ohw + 0.05), oh * 0.5 + 0.05, FRONT + 0.05),
              (0.20, oh + 0.20, 0.14), MI["M_PanelTrim"])
    p.box((0, oh + 0.10, FRONT + 0.05), (DOOR_W + 0.40, 0.20, 0.14), MI["M_PanelTrim"])

    # Recessed emissive reveal between step 1 and step 2.
    for sx in (-1, 1):
        p.strip((sx * (ohw - 0.055), oh * 0.5 - 0.10, 0.055), (0.05, oh - 0.30, 0.05),
                MI["M_EmissiveTeal"])
    p.strip((0, oh - 0.055, 0.055), (DOOR_W - 0.24, 0.05, 0.05), MI["M_EmissiveTeal"])

    # Header: vent slots, hazard rib, and a wide status bar.
    for x in (-1.35, -0.9, 0.9, 1.35):
        p.box((x, WALL_H - 0.36, FRONT - 0.02), (0.26, 0.34, 0.10), MI["M_Grate"])
    p.box((0, WALL_H - 0.62, FRONT + 0.04), (w, 0.16, 0.20), MI["M_PanelTrim"])
    p.strip((0, WALL_H - 0.62, FRONT + 0.15), (2.4, 0.06, 0.04), MI["M_EmissiveTeal"])
    # Floor kick plates, sunk so the frame meets the floor with a shadow line.
    for sx in (-1, 1):
        p.box((sx * (ohw + 0.12), 0.09, FRONT + 0.02), (0.44, 0.18, 0.20), MI["M_PanelTrim"])
    return p, "DOORFRAME_HERO"


def pillar_conduit_hero():
    """Hero piece #2.  An octagonal data trunk: four of its eight facets carry a
    recessed light channel with a segment ladder, so the flow shader can push
    packets up it.  This is the piece a room gets built around."""
    p = Part()
    r = 0.44
    facet = r * math.cos(math.radians(22.5))   # distance to a facet plane
    core = p.cyl((0, 2.0, 0), r, 4.0, MI["M_PanelDark"], segments=8, smooth=False)
    verts = {v for f in core for v in f.verts}
    bmesh.ops.transform(
        p.bm,
        matrix=(Matrix.Translation(Vector((0, 2.0, 0)))
                @ Matrix.Rotation(math.radians(22.5), 4, "Y")
                @ Matrix.Translation(-Vector((0, 2.0, 0)))),
        verts=list(verts),
    )
    for i in range(4):
        a = math.radians(90 * i)
        nx, nz = math.sin(a), math.cos(a)
        def at(depth, ox=0.0, oy=0.0):
            return (nx * (facet - depth) + (-nz) * ox, 2.0 + oy, nz * (facet - depth) + nx * ox)
        sx, sz = (0.26, 0.10) if i % 2 == 0 else (0.10, 0.26)
        # Channel floor, sunk 70 mm into the facet.
        p.box(at(0.07), (sx if i % 2 == 0 else 0.10,
                         3.4, 0.10 if i % 2 == 0 else 0.26), MI["M_PanelDark"])
        # Continuous core line.
        p.strip(at(0.035), (0.06 if i % 2 == 0 else 0.03, 3.3,
                            0.03 if i % 2 == 0 else 0.06), MI["M_EmissiveTeal"])
        # Segment ladder.
        for k in range(6):
            y = -1.35 + k * 0.55
            p.box(at(0.045, 0.0, y), (0.17 if i % 2 == 0 else 0.03, 0.075,
                                      0.03 if i % 2 == 0 else 0.17), MI["M_EmissiveTeal"])
    for y, rr, hh in ((0.30, 0.56, 0.20), (3.68, 0.56, 0.20)):
        band = p.cyl((0, y, 0), rr, hh, MI["M_PanelTrim"], segments=8, smooth=False)
        bv = {v for f in band for v in f.verts}
        bmesh.ops.transform(
            p.bm,
            matrix=(Matrix.Translation(Vector((0, y, 0)))
                    @ Matrix.Rotation(math.radians(22.5), 4, "Y")
                    @ Matrix.Translation(-Vector((0, y, 0)))),
            verts=list(bv),
        )
    p.box((0, 0.08, 0), (1.10, 0.16, 1.10), MI["M_PanelTrim"])
    p.box((0, 3.94, 0), (0.96, 0.20, 0.96), MI["M_PanelTrim"])
    # Cable bundle hugging one flank.
    for ox, rr in ((-0.10, 0.045), (0.0, 0.045), (0.10, 0.035)):
        p.cyl((0.52, 2.0, ox), rr, 3.2, MI["M_Conduit"], segments=6)
    for y in (0.75, 2.05, 3.35):
        p.box((0.53, y, 0.0), (0.20, 0.09, 0.34), MI["M_PanelTrim"])
    return p, "PILLAR_CONDUIT_HERO"


MODULES = [
    wall_panel_4m, wall_trace_4m, wall_armor_4m, wall_vent_2m, wall_cable_2m,
    rib_column, floor_plate_4m, floor_trace_4m, floor_grate_2m,
    ceiling_module_4m, pipe_run_4m, doorframe_hero, pillar_conduit_hero,
]


# --------------------------------------------------------------------- main --

def _split_by_material(obj):
    """One single-material mesh per slot the module actually uses.

    See the COLOR_0 note on `_merge_slots` for why this exists.
    """
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
        nm = bpy.data.meshes.new("%s__%d" % (obj.name, mi))
        bm.to_mesh(nm)
        bm.free()
        nm.materials.append(bpy.data.materials[MATERIALS[mi][0]])
        if len(nm.color_attributes):
            nm.color_attributes.active_color_index = 0
            nm.color_attributes.render_color_index = 0
        o = bpy.data.objects.new(nm.name, nm)
        bpy.context.collection.objects.link(o)
        out.append(nm.name)
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
    """Fold the per-slot meshes back into one mesh + one node per module.

    WHY THIS WHOLE DETOUR EXISTS
    ----------------------------
    Blender 5.2.0's glTF exporter writes a real COLOR_0 stream only for the
    FIRST primitive of a multi-material mesh. Every later primitive gets a
    placeholder filled with opaque white.

    White is the worst possible failure value here, because it is not a crash
    and not even obviously wrong in a viewer. It hands the surface shaders
    wear = 1 and height = 1 on every surface that is not in the first material
    slot, which switches ON the full edge polish and switches OFF the floor
    grime, everywhere, at once. The kit just looks uniformly plastic and nobody
    can say why. This shipped in look-dev 1 and was never noticed.

    The workaround: export one single-material object per slot — each of those
    is primitive 0 of its own mesh, so each gets a correct COLOR_0 — then stitch
    the primitives back into one mesh per module in the container afterwards.
    Only the JSON is rewritten; the binary chunk Blender produced is passed
    through untouched, so the geometry is exactly what the exporter wrote.
    """
    js, blob = _read_glb(path)
    node_by_name = {n["name"]: n for n in js["nodes"] if "mesh" in n}
    meshes, nodes = [], []
    for name, slots in layout:
        prims = []
        for sn in slots:
            src = node_by_name.get(sn)
            if src is None:
                continue
            prims += js["meshes"][src["mesh"]]["primitives"]
        nodes.append({"name": name, "mesh": len(meshes)})
        meshes.append({"name": name, "primitives": prims})
    js["meshes"] = meshes
    js["nodes"] = nodes
    js["scenes"] = [{"name": "Scene", "nodes": list(range(len(nodes)))}]
    js["scene"] = 0
    _write_glb(path, js, blob)


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    make_materials()

    total = 0
    report = []
    layout = []
    for fn in MODULES:
        part, name = fn()
        obj, tris = part.to_object(name)
        obj.location = (0, 0, 0)
        total += tris
        report.append((name, tris))
        layout.append((name, _split_by_material(obj)))
        # The combined object was only ever a staging step; exporting it too
        # would put the broken multi-primitive mesh back in the file.
        bpy.data.objects.remove(obj, do_unlink=True)

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "nullvoid_kit.glb")
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

    print("\n=== NULLVOID look-dev kit ===")
    for name, tris in report:
        flag = "  OVER" if tris > 2000 else ("  thin" if tris < 250 else "")
        print(f"  {name:<24} {tris:>6} tris{flag}")
    print(f"  {'TOTAL':<24} {total:>6} tris")
    print(f"  -> {path}")


if __name__ == "__main__":
    main()
