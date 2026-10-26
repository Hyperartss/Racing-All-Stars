#!/usr/bin/env python3
"""Bake the source character/kart models into vertex-rig files for Godot.

Reads ONLY the untouched originals in Characters/ and Karts/ and writes:
    assets/rigs/<name>.json   - rest-pose geometry split into named parts
    assets/rigs/tex/*.png     - texture copies (alpha maps merged where needed)

A rig file is plain geometry: every vertex belongs to one part (polygon group),
optionally blended 50/50 with a second part on a seam. Each part has a pivot and a
parent. Nothing here is a skeleton or an animation clip - the game moves the
vertices itself every frame (src/rig/vertex_rig.gd).

Conventions of the output: metres, +Y up, character faces -Z, origin on the ground
under the model's centre.

Requires: numpy, pillow, pycollada  (pip install numpy pillow pycollada)
Run from the project root:  python3 tools/bake/bake_rigs.py
"""
import json, os, shutil, sys
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "rigs")
TEX = os.path.join(OUT, "tex")
SONIC_DAE = os.path.join(ROOT, "Characters", "Sonic", "Sonic.dae")
MARIO_DIR = os.path.join(ROOT, "Characters", "Custom _ Edited - Mario Customs - Mario - Mario (PlayStation 1 Style)")
KART_DIR = os.path.join(ROOT, "Karts", "DS _ DSi - Mario Kart DS - Karts - Standard MR", "Standard MR")


# --------------------------------------------------------------------------- utils

def zup_to_yup(p):
    """Collada Z-up (x, y, z) -> Godot Y-up (x, z, -y)."""
    p = np.asarray(p, dtype=float)
    return np.stack([p[..., 0], p[..., 2], -p[..., 1]], axis=-1)


def rot_y(p, deg):
    a = np.radians(deg)
    c, s = np.cos(a), np.sin(a)
    p = np.asarray(p, dtype=float)
    return np.stack([p[..., 0] * c + p[..., 2] * s, p[..., 1], -p[..., 0] * s + p[..., 2] * c], axis=-1)


class RigBuilder:
    def __init__(self, name):
        self.name = name
        self.parts = []          # dicts: name, pivot, parent
        self.surfaces = []       # dicts
        self.meta = {}

    def part(self, name, pivot, parent=-1):
        self.parts.append({"name": name, "pivot": [float(x) for x in pivot], "parent": int(parent)})
        return len(self.parts) - 1

    def surface(self, texture, pos, nrm, uv, idx, pa, pb=None, w=None, alpha="none", cull=True):
        n = len(pos)
        pb = pa if pb is None else pb
        w = np.zeros(n) if w is None else w
        self.surfaces.append({
            "texture": texture, "alpha": alpha, "cull": cull,
            "pos": np.round(np.asarray(pos).reshape(-1), 5).tolist(),
            "nrm": np.round(np.asarray(nrm).reshape(-1), 4).tolist(),
            "uv": np.round(np.asarray(uv).reshape(-1), 5).tolist(),
            # OBJ/Collada are counter-clockwise; Godot's front faces are clockwise.
            "idx": [int(i) for i in np.asarray(idx).reshape(-1, 3)[:, [0, 2, 1]].reshape(-1)],
            "pa": [int(i) for i in pa], "pb": [int(i) for i in pb],
            "w": np.round(np.asarray(w), 3).tolist(),
        })

    def transform(self, fn):
        """Apply a point transform to every vertex and pivot (normals get the linear part)."""
        for p in self.parts:
            p["pivot"] = [float(x) for x in fn(np.array([p["pivot"]]))[0]]
        for s in self.surfaces:
            P = np.array(s["pos"]).reshape(-1, 3)
            N = np.array(s["nrm"]).reshape(-1, 3)
            P2 = fn(P)
            N2 = fn(N) - fn(np.zeros((1, 3)))
            N2 /= np.linalg.norm(N2, axis=1, keepdims=True) + 1e-9
            s["pos"] = np.round(P2.reshape(-1), 5).tolist()
            s["nrm"] = np.round(N2.reshape(-1), 4).tolist()

    def bounds(self):
        P = np.concatenate([np.array(s["pos"]).reshape(-1, 3) for s in self.surfaces])
        return P.min(0), P.max(0)

    def save(self):
        lo, hi = self.bounds()
        self.meta["aabb_min"] = [round(float(x), 4) for x in lo]
        self.meta["aabb_max"] = [round(float(x), 4) for x in hi]
        data = {"name": self.name, "parts": self.parts, "surfaces": self.surfaces, "meta": self.meta}
        path = os.path.join(OUT, self.name + ".json")
        with open(path, "w") as f:
            json.dump(data, f, separators=(",", ":"))
        nv = sum(len(s["pa"]) for s in self.surfaces)
        print(f"wrote {os.path.relpath(path, ROOT)}  parts={len(self.parts)} verts={nv} "
              f"size={np.round(hi - lo, 3).tolist()}")


def copy_tex(src, dst_name, alpha_src=None):
    """Copy a texture into assets/rigs/tex. If alpha_src is given, its luminance
    becomes the alpha channel (the source models ship opacity as a separate image)."""
    dst = os.path.join(TEX, dst_name)
    if alpha_src:
        rgb = Image.open(src).convert("RGB")
        a = Image.open(alpha_src).convert("L").resize(rgb.size, Image.NEAREST)
        img = rgb.copy()
        img.putalpha(a)
        img.save(dst)
    else:
        shutil.copyfile(src, dst)
    return "res://assets/rigs/tex/" + dst_name


def smooth_normals(P, idx):
    N = np.zeros_like(P)
    T = np.asarray(idx).reshape(-1, 3)
    fn = np.cross(P[T[:, 1]] - P[T[:, 0]], P[T[:, 2]] - P[T[:, 0]])
    for k in range(3):
        np.add.at(N, T[:, k], fn)
    return N / (np.linalg.norm(N, axis=1, keepdims=True) + 1e-9)


def load_obj(path):
    """Minimal OBJ reader -> list of (material, [ (pos, uv, nrm) x3 ]) triangles, plus
    group name per triangle."""
    V, VT, VN = [], [], []
    tris = []
    mat = None
    grp = None
    for line in open(path, errors="ignore"):
        t = line.split()
        if not t:
            continue
        if t[0] == "v":
            V.append([float(x) for x in t[1:4]])
        elif t[0] == "vt":
            VT.append([float(x) for x in t[1:3]])
        elif t[0] == "vn":
            VN.append([float(x) for x in t[1:4]])
        elif t[0] == "usemtl":
            mat = t[1]
        elif t[0] in ("g", "o"):
            grp = " ".join(t[1:])
        elif t[0] == "f":
            corners = []
            for c in t[1:]:
                a = c.split("/")
                vi = int(a[0]) - 1
                ti = int(a[1]) - 1 if len(a) > 1 and a[1] else -1
                ni = int(a[2]) - 1 if len(a) > 2 and a[2] else -1
                corners.append((vi, ti, ni))
            for k in range(1, len(corners) - 1):
                tris.append((mat, grp, (corners[0], corners[k], corners[k + 1])))
    return np.array(V), np.array(VT) if VT else np.zeros((0, 2)), np.array(VN) if VN else np.zeros((0, 3)), tris


def obj_surface_arrays(V, VT, VN, tris):
    """Unweld OBJ corners into flat arrays keyed by (v, vt, vn); returns pos, uv, nrm, idx, src_vertex."""
    key = {}
    pos, uv, nrm, src, idx = [], [], [], [], []
    for _, _, corners in tris:
        for c in corners:
            if c not in key:
                key[c] = len(pos)
                pos.append(V[c[0]])
                uv.append(VT[c[1]] if c[1] >= 0 else [0, 0])
                nrm.append(VN[c[2]] if c[2] >= 0 else [0, 1, 0])
                src.append(c[0])
            idx.append(key[c])
    uv = np.array(uv, dtype=float)
    uv[:, 1] = 1.0 - uv[:, 1]           # OBJ V is bottom-up, Godot is top-down
    return np.array(pos, float), uv, np.array(nrm, float), np.array(idx), np.array(src)


# --------------------------------------------------------------------------- Sonic

def bake_sonic():
    import collada
    d = collada.Collada(SONIC_DAE)
    rb = RigBuilder("sonic")
    tex = copy_tex(os.path.join(os.path.dirname(SONIC_DAE), "PLAYER00.png"), "sonic_player00.png")
    copy_tex(os.path.join(os.path.dirname(SONIC_DAE), "BLINK00.png"), "sonic_blink00.png")

    # Sonic R model: 11 rigid groups in a parent/child hierarchy. Node origins are
    # the joints, so they become the pivots directly.
    names = {"Grp00": "body", "Grp01": "head", "Grp04": "arm_upper_l", "Grp02": "arm_lower_l",
             "Grp08": "arm_upper_r", "Grp06": "arm_lower_r", "Grp05": "leg_upper_l", "Grp03": "foot_l",
             "Grp09": "leg_upper_r", "Grp07": "foot_r", "Grp10": "tail"}
    pos_all, nrm_all, uv_all, idx_all, part_all = [], [], [], [], []

    def walk(node, parent_world, parent_part):
        local = node.matrix if hasattr(node, "matrix") else np.eye(4)
        world = parent_world @ local
        part = parent_part
        if isinstance(node, collada.scene.Node) and node.id in names:
            pivot = zup_to_yup(world[:3, 3])
            part = rb.part(names[node.id], pivot, parent_part)
            for ch in node.children:
                if isinstance(ch, collada.scene.GeometryNode):
                    for prim in ch.geometry.primitives:
                        tri = prim.triangleset() if hasattr(prim, "triangleset") else prim
                        P = tri.vertex[tri.vertex_index].reshape(-1, 3)
                        P = (world @ np.c_[P, np.ones(len(P))].T).T[:, :3]
                        N = tri.normal[tri.normal_index].reshape(-1, 3) @ world[:3, :3].T
                        UV = tri.texcoordset[0][tri.texcoord_indexset[0]].reshape(-1, 2).copy()
                        UV[:, 1] = 1.0 - UV[:, 1]
                        base = sum(len(p) for p in pos_all)
                        pos_all.append(zup_to_yup(P))
                        nrm_all.append(zup_to_yup(N))
                        uv_all.append(UV)
                        idx_all.append(np.arange(len(P)) + base)
                        part_all.append(np.full(len(P), part))
        for ch in getattr(node, "children", []):
            if isinstance(ch, collada.scene.Node):
                walk(ch, world, part)

    for n in d.scene.nodes:
        walk(n, np.eye(4), -1)

    rb.surface(tex, np.concatenate(pos_all), np.concatenate(nrm_all), np.concatenate(uv_all),
               np.concatenate(idx_all), np.concatenate(part_all), alpha="scissor", cull=False)
    # Faces -X after the axis swap; turn to -Z, scale to ~1.1 m, stand on the ground.
    rb.transform(lambda p: rot_y(p, -90.0))
    lo, hi = rb.bounds()
    s = 1.1 / (hi[1] - lo[1])
    c = (lo + hi) * 0.5
    rb.transform(lambda p: (p - np.array([c[0], lo[1], c[2]])) * s)
    rb.meta.update({"source": "Characters/Sonic/Sonic.dae", "scale": s, "texture_blink": "res://assets/rigs/tex/sonic_blink00.png"})
    rb.save()


# --------------------------------------------------------------------------- Mario

MARIO_PARTS = [
    # name, joints merged into it, parent part name
    ("hips", ["Bone"], None),
    ("torso", ["Bone_001"], "hips"),
    ("head", ["Bone_002", "Bone_003"], "torso"),
    ("arm_upper_l", ["Bone_005"], "torso"),
    ("arm_lower_l", ["Bone_006", "Bone_007"], "arm_upper_l"),
    ("arm_upper_r", ["Bone_010"], "torso"),
    ("arm_lower_r", ["Bone_011", "Bone_012"], "arm_upper_r"),
    ("leg_upper_l", ["Bone_004"], "hips"),
    ("leg_lower_l", ["Bone_008", "Bone_009"], "leg_upper_l"),
    ("leg_upper_r", ["Bone_013"], "hips"),
    ("leg_lower_r", ["Bone_014", "Bone_015"], "leg_upper_r"),
]


def bake_mario():
    """Geometry, UVs and textures come from MarioPS1.obj (it matches the shipped
    Preview.png). The .dae (an older variant of the same model, same space) has a
    16-joint armature that is NOT used for animation: joint positions give the
    pivots, and each OBJ vertex takes the part of the nearest .dae vertex's strongest
    skin weight - that is just how the polygon groups get decided."""
    import collada
    d = collada.Collada(os.path.join(MARIO_DIR, "MarioPS1.dae"))
    rb = RigBuilder("mario")
    texs = {
        "Material": (copy_tex(os.path.join(MARIO_DIR, "MarioColorBake.png"), "mario_body.png"), "none"),
        "Material.001": (copy_tex(os.path.join(MARIO_DIR, "MarioHeadColorBake.png"), "mario_head.png"), "none"),
        "Material.002": (copy_tex(os.path.join(MARIO_DIR, "Mario Mustache.png"), "mario_mustache.png",
                                  os.path.join(MARIO_DIR, "Mario Mustache Opacity.png")), "scissor"),
        "Material.003": (copy_tex(os.path.join(MARIO_DIR, "Mario Brows.png"), "mario_brows.png",
                                  os.path.join(MARIO_DIR, "Mario Brows opacity.png")), "scissor"),
    }
    # Joint pivots (world space of the .dae == OBJ space after Z-up -> Y-up).
    ctrl = d.controllers[0]
    jnames = [str(n[0]) if not isinstance(n, str) else n for n in ctrl.sourcebyid[ctrl.joint_source].data]
    jpos = {n: np.linalg.inv(ctrl.joint_matrices[n])[:3, 3] for n in jnames}
    joint_part, part_idx = {}, {}
    for name, joints, parent in MARIO_PARTS:
        part_idx[name] = rb.part(name, zup_to_yup(jpos[joints[0]]), part_idx[parent] if parent else -1)
        for j in joints:
            joint_part[j] = part_idx[name]
    # Reference points: skinned .dae body vertices in world space + their part.
    arm_world = np.eye(4)
    for n in d.scene.nodes:
        if n.id == "Armature":
            arm_world = np.asarray(n.matrix)
    ref_p, ref_part = [], []
    for c in d.controllers:
        if c.geometry.name != "Plane":
            continue
        names = [str(n[0]) if not isinstance(n, str) else n for n in c.sourcebyid[c.joint_source].data]
        bsm = np.asarray(c.bind_shape_matrix)
        P = c.geometry.primitives[0].vertex
        P = zup_to_yup((arm_world @ bsm @ np.c_[P, np.ones(len(P))].T).T[:, :3])
        for vi in range(len(c.index)):
            ji, wi = c.joint_index[vi], c.weight_index[vi]
            ws = c.weights[wi].reshape(-1)
            ref_p.append(P[vi]); ref_part.append(joint_part[names[int(ji[np.argmax(ws)])]])
    ref_p = np.array(ref_p); ref_part = np.array(ref_part)

    V, VT, VN, tris = load_obj(os.path.join(MARIO_DIR, "MarioPS1.obj"))
    group_of = {}
    for _, g, cs in tris:
        for c in cs:
            group_of.setdefault(c[0], g)

    def part_for(vi):
        g = group_of.get(vi, "")
        p = V[vi]
        if g in ("Mario_Hat", "Mario_Hair"):
            return part_idx["head"]
        if g == "HFist":
            # Model still faces +Z here, so its left hand is at +X.
            return part_idx["arm_lower_l" if p[0] > 0 else "arm_lower_r"]
        dd = np.linalg.norm(ref_p - p, axis=1)
        return int(ref_part[np.argmin(dd)])

    for mat, (tex, alpha) in texs.items():
        ts = [t for t in tris if t[0] == mat]
        if not ts:
            continue
        pos, uv, nrm, idx, src = obj_surface_arrays(V, VT, VN, ts)
        pa = np.array([part_for(v) for v in src])
        rb.surface(tex, pos, nrm, uv, idx, pa, alpha=alpha, cull=(alpha == "none"))
    # Seam softening: a position shared by two parts follows both 50/50, which hides
    # cracks at the elbows/knees when they bend (no weight painting involved).
    pos_parts = {}
    for sf in rb.surfaces:
        P = np.array(sf["pos"]).reshape(-1, 3)
        for k, pa in enumerate(sf["pa"]):
            pos_parts.setdefault(tuple(np.round(P[k], 2)), set()).add(pa)
    for sf in rb.surfaces:
        P = np.array(sf["pos"]).reshape(-1, 3)
        for k, pa in enumerate(sf["pa"]):
            ps = pos_parts[tuple(np.round(P[k], 2))]
            if len(ps) > 1:
                sf["pb"][k] = int(min(q for q in ps if q != pa)); sf["w"][k] = 0.5

    # OBJ faces +Z (nose forward); turn to -Z, scale to 0.85 m, stand on the ground.
    rb.transform(lambda p: rot_y(p, 180.0))
    lo, hi = rb.bounds()
    sc = 0.85 / (hi[1] - lo[1])
    c = (lo + hi) * 0.5
    rb.transform(lambda p: (p - np.array([c[0], lo[1], c[2]])) * sc)
    rb.meta.update({"source": "MarioPS1.obj (+ .dae joint positions for pivots only)", "scale": sc})
    rb.save()


# --------------------------------------------------------------------------- Kart

def bake_kart():
    V, VT, VN, tris = load_obj(os.path.join(KART_DIR, "kart_MR_a.obj"))
    rb = RigBuilder("kart_standard")
    texs = {
        "kart_body": copy_tex(os.path.join(KART_DIR, "kart_body.png"), "kart_body.png"),
        "kart_tire": copy_tex(os.path.join(KART_DIR, "kart_tire.png"), "kart_tire.png"),
        "kart_emblem": copy_tex(os.path.join(KART_DIR, "kart_emblem.png"), "kart_emblem.png"),
    }
    # Turn the kart to face -Z first (it faces +Z in the file).
    V = rot_y(V, 180.0)
    VN = rot_y(VN, 180.0) if len(VN) else VN
    body = rb.part("body", [0, 0, 0], -1)

    # Split the tire material into 4 wheels by connectivity.
    tire_tris = [t for t in tris if t[0] == "kart_tire"]
    parent = {}

    def find(a):
        while parent.setdefault(a, a) != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    key = lambda vi: tuple(np.round(V[vi], 4))
    for _, _, cs in tire_tris:
        ks = [key(c[0]) for c in cs]
        for k in ks[1:]:
            parent[find(ks[0])] = find(k)
    groups = {}
    for t in tire_tris:
        groups.setdefault(find(key(t[2][0][0])), []).append(t)
    wheel_of = {}
    wheels = []
    for g, ts in groups.items():
        P = V[sorted({c[0] for _, _, cs in ts for c in cs})]
        lo, hi = P.min(0), P.max(0)
        centre = (lo + hi) * 0.5
        radius = (hi[1] - lo[1]) * 0.5
        side = "l" if centre[0] < 0 else "r"
        end = "f" if centre[2] < 0 else "b"
        name = f"wheel_{end}{side}"
        wheels.append((name, centre, radius, ts))
    wheels.sort(key=lambda w: w[0])
    for name, centre, radius, ts in wheels:
        pi = rb.part(name, centre, -1)   # wheels stay level while the body leans
        rb.meta[name] = {"centre": centre.round(4).tolist(), "radius": round(float(radius), 4)}
        for t in ts:
            wheel_of[id(t)] = pi

    for mat in ("kart_body", "kart_tire", "kart_emblem"):
        ts = [t for t in tris if t[0] == mat]
        if not ts:
            continue
        pos, uv, nrm, idx, src = obj_surface_arrays(V, VT, VN, ts)
        pa = np.full(len(pos), body)
        if mat == "kart_tire":
            # corner -> wheel
            k = 0
            corner_part = {}
            for t in ts:
                for c in t[2]:
                    corner_part[c] = wheel_of[id(t)]
            # obj_surface_arrays keyed by corner tuple in first-seen order
            seen = []
            for t in ts:
                for c in t[2]:
                    if c not in seen:
                        seen.append(c)
            pa = np.array([corner_part[c] for c in seen])
        if np.allclose(nrm, [0, 1, 0]):
            nrm = smooth_normals(pos, idx)
        # The shipped .mtl marks everything fully transparent (d 0); textures carry
        # cut-out alpha instead, so use alpha scissor.
        rb.surface(texs[mat], pos, nrm, uv, idx, pa, alpha="scissor", cull=False)
    lo, hi = rb.bounds()
    rb.meta.update({"source": "Karts/.../Standard MR/kart_MR_a.obj", "front": "-Z"})
    rb.save()


if __name__ == "__main__":
    os.makedirs(TEX, exist_ok=True)
    bake_sonic()
    bake_mario()
    bake_kart()
