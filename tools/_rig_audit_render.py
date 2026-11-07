import bpy
import json
import os
import math
from mathutils import Vector

ROOT = "/home/hyper/Desktop/New Drive Files/WIP/retrokarting"
OUT = os.path.join(ROOT, ".tmp_rig_audit")
os.makedirs(OUT, exist_ok=True)

PALETTE = [
    (0.82, 0.18, 0.18, 1), (0.16, 0.45, 0.86, 1), (0.20, 0.72, 0.30, 1),
    (0.96, 0.78, 0.14, 1), (0.85, 0.38, 0.12, 1), (0.58, 0.24, 0.82, 1),
    (0.90, 0.90, 0.90, 1), (0.22, 0.22, 0.22, 1), (0.94, 0.38, 0.72, 1),
    (0.12, 0.76, 0.78, 1), (0.55, 0.70, 0.16, 1), (0.72, 0.45, 0.20, 1),
    (0.36, 0.52, 0.78, 1), (0.60, 0.60, 0.60, 1),
]


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.render.resolution_x = 640
    sc.render.resolution_y = 640
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = "PNG"
    sc.display.shading.light = "FLAT"
    sc.display.shading.color_type = "MATERIAL"
    sc.display.shading.show_shadows = False
    sc.display.shading.show_cavity = True
    sc.display.shading.cavity_type = "BOTH"
    sc.display.shading.curvature_ridge_factor = 1.0
    sc.display.shading.curvature_valley_factor = 1.0
    sc.display.shading.background_type = "VIEWPORT"
    sc.display.shading.background_color = (1, 1, 1)
    sc.world = bpy.data.worlds.new("World")
    sc.world.color = (1, 1, 1)
    sc.view_settings.view_transform = "Standard"


def look_at(cam, target):
    d = Vector(target) - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def load_rig(path):
    with open(path) as f:
        d = json.load(f)
    parts = d["parts"]
    verts = []
    faces = []
    face_parts = []
    for s in d["surfaces"]:
        base = len(verts)
        p = s["pos"]
        for i in range(0, len(p), 3):
            # Godot Y-up -> Blender Z-up
            verts.append((p[i], p[i + 2], p[i + 1]))
        idx = s["idx"]
        pa = s["pa"]
        for t in range(0, len(idx) - 2, 3):
            a, b, c = idx[t], idx[t + 1], idx[t + 2]
            if a == b or b == c or c == a:
                continue
            faces.append((base + a, base + b, base + c))
            face_parts.append(pa[a])
    mesh = bpy.data.meshes.new(d.get("name", "rig"))
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(d.get("name", "rig"), mesh)
    bpy.context.collection.objects.link(obj)
    for i, p in enumerate(parts):
        mat = bpy.data.materials.new("part_%02d_%s" % (i, p.get("name", "?")))
        mat.diffuse_color = PALETTE[i % len(PALETTE)]
        mat.roughness = 1.0
        obj.data.materials.append(mat)
    for poly, pi in zip(mesh.polygons, face_parts):
        poly.material_index = pi
    for poly in mesh.polygons:
        poly.use_smooth = False
    return d, obj


def bounds(obj):
    xs = [v.co.x for v in obj.data.vertices]
    ys = [v.co.y for v in obj.data.vertices]
    zs = [v.co.z for v in obj.data.vertices]
    return Vector((min(xs), min(ys), min(zs))), Vector((max(xs), max(ys), max(zs)))


def add_camera():
    data = bpy.data.cameras.new("Cam")
    data.type = "ORTHO"
    cam = bpy.data.objects.new("Cam", data)
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    return cam


def render_view(name, cam, center, radius, direction, scale=None):
    d = Vector(direction).normalized()
    cam.location = Vector(center) + d * (radius * 4.0 + 2.0)
    look_at(cam, center)
    cam.data.ortho_scale = (scale if scale is not None else radius * 2.15)
    bpy.context.scene.render.filepath = os.path.join(OUT, name + ".png")
    bpy.ops.render.render(write_still=True)


def main():
    clear()
    cam = add_camera()
    for fn in sorted(os.listdir(os.path.join(ROOT, "assets", "rigs"))):
        if not fn.endswith(".json"):
            continue
        stem = fn[:-5]
        d, obj = load_rig(os.path.join(ROOT, "assets", "rigs", fn))
        lo, hi = bounds(obj)
        center = (lo + hi) * 0.5
        radius = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) * 0.5
        # Four orthographic views around the character.
        for label, direction in [
            ("front", (0, -1, 0)),
            ("back", (0, 1, 0)),
            ("left", (-1, 0, 0)),
            ("right", (1, 0, 0)),
        ]:
            render_view("%s_%s" % (stem, label), cam, center, radius, direction)
        # Foot close-up: side and front of the low 30 cm.
        feet = []
        for s in d["surfaces"]:
            pa = s["pa"]
            for i, p in enumerate(pa):
                nm = d["parts"][p].get("name", "")
                if nm.startswith("foot"):
                    feet.append(Vector((s["pos"][i * 3], s["pos"][i * 3 + 2], s["pos"][i * 3 + 1])))
        if feet:
            flo = Vector((min(v.x for v in feet), min(v.y for v in feet), min(v.z for v in feet)))
            fhi = Vector((max(v.x for v in feet), max(v.y for v in feet), max(v.z for v in feet)))
            fc = (flo + fhi) * 0.5
            fr = max(fhi.x - flo.x, fhi.y - flo.y, fhi.z - flo.z) * 0.6
            for label, direction in [("feet_front", (0, -1, 0)), ("feet_side", (-1, 0, 0)),
                                     ("feet_top", (0, 0, 1)), ("feet_bottom", (0, 0, -1))]:
                render_view("%s_%s" % (stem, label), cam, fc, max(fr, 0.2), direction,
                            scale=max(fhi.x - flo.x, fhi.z - flo.z, fhi.y - flo.y) * 2.2)
        bpy.data.objects.remove(obj, do_unlink=True)
    print("WROTE", OUT)


main()
