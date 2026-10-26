#!/usr/bin/env python3
"""Bake the merged race course from the two source tracks.

Course (one lap, travelling clockwise on the Raceway map):
    Raceway: arch straight (west part) ......... cut W
    Connector A (generated, with vertical loop)
    Resort Island Trk90 -> Trk195 (+ alternate route Trk327 -> Trk384)
    Connector B (generated)
    cut E ...... Raceway: NE corner, start/finish straight, south S-bends, infield
                 esses, SW hairpin, west side, NW esses -> back to cut W

Reads only the untouched originals in Tracks/. Writes:
    assets/tracks/merged/track.json   surfaces, centreline, checkpoints, grid
    assets/tracks/merged/track.bin    float32/int32 geometry buffers
    assets/tracks/merged/tex/*.png    textures (lower-case, alpha fixed)
    out/track_top.png                 top-down plot for checking the layout

Run from the project root:  python3 tools/bake/bake_track.py
Requires numpy, pillow, opencv-python, scikit-image, networkx, matplotlib.
"""
import json, os, shutil, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from trackgeo import (Poly, read_obj, clip_poly, resample_closed, resample_open, smooth_closed,
                      smooth_open, hermite, rot_y, zip_strip)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RW_DIR = os.path.join(ROOT, "Tracks", "Mario Raceway")
IS_DIR = os.path.join(ROOT, "Tracks", "PC _ Computer - Sonic R - Courses - Resort Island")
OUT = os.path.join(ROOT, "assets", "tracks", "merged")
TEXOUT = os.path.join(OUT, "tex")

RW_SCALE = 100.0          # Raceway units -> metres (road ~10 m wide)
IS_SCALE = 2.0            # Island units -> metres (road ~10 m wide)
IS_YAW = 90.0             # island heading east -> course heading north
IS_MAIN = (90, 195)       # Trk pieces on the main route
IS_FORK = (327, 384)      # alternate route (branches at Trk157, rejoins ~Trk191)
SPACING = 2.0

# Raceway texture classes (see the texture contact sheet in the report).
RW_ROAD = {"7EEA0D6A_c.png", "92276F6_c.png"}
RW_DECO = {"1BCE005B_c.png", "2423501B_c.png", "25AE82BA_c.png", "55C14C02_c.png", "5D98AD32_c.png",
           "60FB6A23_c.png", "762A9DF7_c.png", "7F15E57A_c.png", "62E1B663_c.png", "67511A83_ctran.png",
           "5DD58B0C_atran.png", "hat.png", "4447C93F_c.png", "19B3576F_c.png"}
RW_WALL = {"695C0BE7_c.png", "1B41E2F3_c.png", "7BB9F917_ctran.png", "172433F5_ctran.png",
           "124EC633_c.png", "191496A1_c.png", "4212FC5_c.png"}
RW_GRASS = "3ED14A28_c.png"
RW_ASPHALT = "7EEA0D6A_c.png"
RW_BARRIER = "695C0BE7_c.png"
IS_ROAD_TEX = "island00.png"
IS_ROAD_RECT = (0.0, 0.25, 0.25, 0.25)   # u, v(OBJ, up), w, h of the plank/sand road tile


# =============================================================================== load

def load_raceway():
    V, VT, polys, mtl = read_obj(os.path.join(RW_DIR, "Mario Raceway.obj"), os.path.join(RW_DIR, "Mario Raceway.mtl"))
    V = V * RW_SCALE
    out = []
    for mat, grp, vi, ti in polys:
        tex = mtl.get(mat, {}).get("tex", RW_GRASS)
        uv = np.array([VT[t] if t >= 0 else [0, 0] for t in ti])
        if tex in RW_ROAD:
            cls = "road"
        elif tex in RW_DECO:
            cls = "deco"
        elif tex in RW_WALL:
            cls = "wall"
        else:
            cls = "off"
        alpha = "tran" in tex or tex == "hat.png"
        out.append(Poly(V[vi], uv, tex, cls, "rw", alpha))
    return out


def load_island():
    V, VT, polys, mtl = read_obj(os.path.join(IS_DIR, "island.obj"), os.path.join(IS_DIR, "island.mtl"))
    V = V * IS_SCALE
    out = []
    for mat, grp, vi, ti in polys:
        if grp is None or grp == "Plane":
            continue
        info = mtl.get(mat, {})
        tex = info.get("tex", "island00.png").lower()      # files on disk are upper-case
        uv = np.array([VT[t] if t >= 0 else [0, 0] for t in ti])
        p = Poly(V[vi], uv, tex, "", grp, "alpha" in info)
        out.append(p)
    return out


# ======================================================================= centrelines

def raceway_centreline(polys):
    """Skeleton of the rasterised road -> ordered closed loop at 2 m spacing."""
    import cv2
    import networkx as nx
    from skimage.morphology import skeletonize
    S = 4.0                                    # px per metre
    ox, oz = -300.0, -200.0
    W, H = int(470 * S), int(330 * S)
    img = np.zeros((H, W), np.uint8)
    for p in polys:
        if p.cls != "road":
            continue
        pts = np.array([[(q[0] - ox) * S, (q[2] - oz) * S] for q in p.p], np.int32)
        cv2.fillPoly(img, [pts], 255)
    img = cv2.morphologyEx(img, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))
    sk = skeletonize(img > 0)
    ys, xs = np.nonzero(sk)
    G = nx.Graph()
    idx = {(y, x): i for i, (y, x) in enumerate(zip(ys, xs))}
    for (y, x), i in idx.items():
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                j = idx.get((y + dy, x + dx))
                if j is not None and j != i:
                    G.add_edge(i, j)
    cyc = max(nx.cycle_basis(G), key=len)
    pts2 = np.array([[xs[i] / S + ox, ys[i] / S + oz] for i in cyc])
    dist = cv2.distanceTransform(img, cv2.DIST_L2, 5)
    pts2 = smooth_closed(resample_closed(pts2, 1.0), 6)
    pts2 = resample_closed(pts2, SPACING)
    widths = []
    for x, z in pts2:
        px, py = int((x - ox) * S), int((z - oz) * S)
        widths.append(2.0 * dist[min(max(py, 0), H - 1), min(max(px, 0), W - 1)] / S)
    pts = np.c_[pts2[:, 0], np.zeros(len(pts2)), pts2[:, 1]]
    pts[:, 1] = heights_at(polys, pts, {"road"})
    return pts, np.clip(np.array(widths), 6, 30)


def heights_at(polys, pts, classes):
    """Highest polygon of the given classes directly above/below each XZ point."""
    cand = [p for p in polys if p.cls in classes]
    mins = np.array([p.p[:, [0, 2]].min(0) for p in cand])
    maxs = np.array([p.p[:, [0, 2]].max(0) for p in cand])
    out = np.zeros(len(pts))
    for k, q in enumerate(pts):
        best = None
        sel = np.nonzero((mins[:, 0] <= q[0]) & (maxs[:, 0] >= q[0]) & (mins[:, 1] <= q[2]) & (maxs[:, 1] >= q[2]))[0]
        for i in sel:
            P = cand[i].p
            for t in range(1, len(P) - 1):
                h = _tri_height(P[0], P[t], P[t + 1], q[0], q[2])
                if h is not None and (best is None or h > best):
                    best = h
        out[k] = best if best is not None else (out[k - 1] if k else 0.0)
    return out


def _tri_height(a, b, c, x, z):
    v0 = np.array([b[0] - a[0], b[2] - a[2]]); v1 = np.array([c[0] - a[0], c[2] - a[2]])
    v2 = np.array([x - a[0], z - a[2]])
    den = v0[0] * v1[1] - v1[0] * v0[1]
    if abs(den) < 1e-12:
        return None
    u = (v2[0] * v1[1] - v1[0] * v2[1]) / den
    v = (v0[0] * v2[1] - v2[0] * v0[1]) / den
    if u < -1e-6 or v < -1e-6 or u + v > 1 + 1e-6:
        return None
    return a[1] + u * (b[1] - a[1]) + v * (c[1] - a[1])


def piece_floor_centres(polys, lo, hi):
    """Centre of each island Trk piece's floor (faces that point up) -> ordered points."""
    acc = {}
    for p in polys:
        if not p.src.startswith("Trk"):
            continue
        k = int(p.src[3:])
        if not (lo <= k <= hi):
            continue
        if abs(p.normal()[1]) > 0.6:
            acc.setdefault(k, []).append(p.p)
    keys = sorted(acc)
    return keys, np.array([np.concatenate(acc[k]).mean(0) for k in keys])


# ======================================================================== layout

P_IN_XZ = (-20.0, -62.0)      # Raceway: end of the arch straight (travelling east)
P_OUT_XZ = (0.0, 85.0)        # Raceway: bottom of the old start straight (travelling south)
START_XZ = (-122.0, -62.0)    # new start/finish line on the arch straight
IS_OFFSET_XZ = (46.0, 18.0)   # island translation (metres, after scaling)
LOOP_R = 11.0                 # vertical loop radius
LOOP_AT = 0.30                # where along connector A the loop sits (0..1)
CONN_W = 11.0                 # connector road width
RAIL_H = 1.1


def frames_from_path(P, up_hint=None):
    """Tangent / up / right along a polyline. Up defaults to world-up projected."""
    n = len(P)
    T = np.zeros_like(P)
    T[1:-1] = P[2:] - P[:-2]
    T[0] = P[1] - P[0]
    T[-1] = P[-1] - P[-2]
    T /= np.linalg.norm(T, axis=1, keepdims=True) + 1e-12
    U = np.zeros_like(P)
    Rt = np.zeros_like(P)
    for i in range(n):
        u = up_hint[i] if up_hint is not None else np.array([0, 1.0, 0])
        r = np.cross(T[i], u)
        if np.linalg.norm(r) < 1e-6:
            r = Rt[i - 1] if i else np.array([1.0, 0, 0])
        r /= np.linalg.norm(r)
        Rt[i] = r
        U[i] = np.cross(r, T[i])
    return T, U, Rt


def smoothstep(x):
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


def build_connector_path(p0, t0, p1, t1, with_loop=False, spacing=0.5):
    """Centre path + up vectors. Flat Hermite curves; optional vertical loop in the
    middle of a straight run. Returns (P, UP, loop_mask)."""
    t0 = t0 / np.linalg.norm(t0); t1 = t1 / np.linalg.norm(t1)
    chord = np.linalg.norm(p1 - p0)
    if not with_loop:
        n = max(8, int(chord * 2.0 / spacing))
        P = hermite(p0, t0 * chord * 1.1, p1, t1 * chord * 1.1, n)
        P[:, 1] = p0[1] + (p1[1] - p0[1]) * smoothstep(np.linspace(0, 1, n))
        P = resample_open(P, spacing)
        P[:, 1] = p0[1] + (p1[1] - p0[1]) * smoothstep(np.linspace(0, 1, len(P)))
        return P, None, np.zeros(len(P), bool)
    # Straight lead-in along t0, then the loop, then a Hermite to the end frame.
    d = np.array([t0[0], 0, t0[2]]); d /= np.linalg.norm(d)
    right = np.cross(d, [0, 1.0, 0]); right /= np.linalg.norm(right)
    lead = max(30.0, chord * LOOP_AT)
    ls = p0 + d * lead
    shift = -(CONN_W + 3.0)          # exit lane offset sideways (to the left)
    th = np.linspace(0, 2 * np.pi, int(2 * np.pi * LOOP_R / spacing))
    lat = shift * (1 - np.cos(th / 2)) / 2
    loopP = ls + np.outer(np.sin(th) * LOOP_R, d) + np.outer((1 - np.cos(th)) * LOOP_R, [0, 1.0, 0]) + np.outer(lat, right)
    centre = ls + np.outer(np.full_like(th, 0.0), d) + np.array([0, LOOP_R, 0]) + np.outer(lat, right)
    centre = centre + np.outer(np.sin(th) * 0.0, d)
    loopUp = (ls[None, :] + np.array([0, LOOP_R, 0]) + np.outer(lat, right)) - loopP
    loopUp /= np.linalg.norm(loopUp, axis=1, keepdims=True)
    leadP = resample_open(np.array([p0, ls]), spacing)[:-1]
    le = loopP[-1]
    rest = np.linalg.norm(p1 - le)
    n = max(8, int(rest * 2.0 / spacing))
    tail = hermite(le, d * rest * 1.1, p1, t1 * rest * 1.1, n)
    tail[:, 1] = le[1] + (p1[1] - le[1]) * smoothstep(np.linspace(0, 1, n))
    tail = resample_open(tail, spacing)
    tail[:, 1] = le[1] + (p1[1] - le[1]) * smoothstep(np.linspace(0, 1, len(tail)))
    P = np.concatenate([leadP, loopP[:-1], tail])
    UP = np.concatenate([np.tile([0, 1.0, 0], (len(leadP), 1)), loopUp[:-1], np.tile([0, 1.0, 0], (len(tail), 1))])
    mask = np.concatenate([np.zeros(len(leadP), bool), np.ones(len(loopP) - 1, bool), np.zeros(len(tail), bool)])
    return P, UP, mask


# ======================================================================== cutting

def cut_raceway(rw, cl, i_in, i_out):
    """Remove the Raceway road between i_in and i_out (travel order). Road polygons at
    the two cut planes are clipped exactly; the removed road becomes grass so the
    ground has no hole. Returns (polys, edge_in, edge_out) where the edges are the
    exact cut vertices (left->right) the connectors must start/end on."""
    n = len(cl)
    removed = np.zeros(n, bool)
    k = i_in
    while k != i_out:
        removed[k] = True
        k = (k + 1) % n
    removed[i_in] = False
    t_in = cl[(i_in + 1) % n] - cl[i_in - 1]; t_in /= np.linalg.norm(t_in)
    t_out = cl[(i_out + 1) % n] - cl[i_out - 1]; t_out /= np.linalg.norm(t_out)
    p_in, p_out = cl[i_in], cl[i_out]
    out = []
    edge_in, edge_out = [], []
    clxz = cl[:, [0, 2]]
    for p in rw:
        if p.cls != "road":
            out.append(p)
            continue
        c = p.centroid()
        near = np.argmin(np.linalg.norm(clxz - c[[0, 2]], axis=1))
        # Polygons near a cut plane are split along it.
        for plane_p, plane_t, keep_behind, edge in ((p_in, t_in, True, edge_in), (p_out, t_out, False, edge_out)):
            if np.linalg.norm((c - plane_p)[[0, 2]]) < 25.0:
                nrm = plane_t if keep_behind else -plane_t
                d = nrm @ plane_p
                kept = clip_poly(p.p, p.uv, -nrm, -d)      # behind (keep_behind) / ahead
                gone = clip_poly(p.p, p.uv, nrm, d)
                if kept is not None:
                    q = Poly(kept[0], kept[1], p.tex, "road", "rw")
                    out.append(q)
                    for v in kept[0]:
                        if abs(v @ nrm - d) < 1e-6:
                            edge.append(v)
                if gone is not None:
                    g = Poly(gone[0], gone[1], RW_GRASS, "off", "rw_cut")
                    out.append(g)
                break
        else:
            if removed[near]:
                p.tex, p.cls, p.src = RW_GRASS, "off", "rw_cut"
            out.append(p)
    # Planar grass UVs for everything retextured.
    for p in out:
        if p.src == "rw_cut":
            p.uv = p.p[:, [0, 2]] / 8.0
    return out, _sort_edge(edge_in, p_in, t_in), _sort_edge(edge_out, p_out, t_out)


def _sort_edge(pts, p0, t):
    pts = np.unique(np.round(np.array(pts), 6), axis=0)
    right = np.cross(t, [0, 1.0, 0]); right /= np.linalg.norm(right)
    order = np.argsort((pts - p0) @ right)
    return pts[order]


def island_edge(isl_all, a, b, right_dir):
    """Vertices shared by Trk<a> and Trk<b> floors, sorted left->right."""
    def verts(k):
        s = set()
        for p in isl_all:
            if p.src == f"Trk{k}" and abs(p.normal()[1]) > 0.6:
                for v in p.p:
                    s.add(tuple(np.round(v, 4)))
        return s
    shared = np.array(sorted(verts(a) & verts(b)))
    c = shared.mean(0)
    return shared[np.argsort((shared - c) @ right_dir)]


# ======================================================================== connectors

def loft_connector(P, UP, edge_a, edge_b, blend_from, blend_to, name):
    """Road ribbon + rails + skirt along path P. edge_a / edge_b are the exact source
    cut vertices; the first/last rows are zipped to them so there is no gap."""
    T, U, R = frames_from_path(P, UP)
    n = len(P)
    LAT = 8
    dist = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
    L = dist[-1]

    def local(edge, i):
        return np.c_[(edge - P[i]) @ R[i], (edge - P[i]) @ U[i]]

    la = local(edge_a, 0)
    lb = local(edge_b, n - 1)

    def prof(lp, k):
        """Resample a (lat, h) polyline to k points by arc length."""
        d = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(lp, axis=0), axis=1))])
        s = np.linspace(0, d[-1], k)
        return np.c_[np.interp(s, d, lp[:, 0]), np.interp(s, d, lp[:, 1])]
    pa = prof(la, LAT + 1)
    pb = prof(lb, LAT + 1)
    std = np.c_[np.linspace(-CONN_W / 2, CONN_W / 2, LAT + 1), np.zeros(LAT + 1)]
    rows = []
    widths = []
    TRANS = 14.0
    for i in range(n):
        fa = smoothstep(1 - dist[i] / TRANS)            # 1 at the start
        fb = smoothstep(1 - (L - dist[i]) / TRANS)      # 1 at the end
        pr = std * (1 - fa - fb) + pa * fa + pb * fb if fa + fb <= 1 else (pa if fa > fb else pb)
        rows.append(P[i] + np.outer(pr[:, 0], R[i]) + np.outer(pr[:, 1], U[i]))
        widths.append(pr[-1, 0] - pr[0, 0])
    rows[0] = rows[0]
    polys = []
    blend = blend_from + (blend_to - blend_from) * smoothstep(dist / L)

    def road_uv(i, j):
        lat = -CONN_W / 2 + CONN_W * j / LAT
        return np.array([2.0 * j / LAT, dist[i] / 5.0])

    # zip the exact source edge to the first resampled row, and the last to edge_b
    for edge, row, i, flip in ((edge_a, rows[0], 0, False), (edge_b, rows[-1], n - 1, True)):
        A, B = (edge, row) if not flip else (row, edge)
        allp = np.concatenate([A, B])
        for (x, y, z) in zip_strip(A, B):
            tri = allp[[x, y, z]]
            uv = np.array([[2.0 * ((v - P[i]) @ R[i] + CONN_W / 2) / CONN_W, dist[i] / 5.0] for v in tri])
            q = Poly(tri, uv, "conn", "road", name, col=np.full(3, blend[i]))
            if q.normal() @ U[i] < 0:
                q.p = q.p[::-1]; q.uv = q.uv[::-1]
            polys.append(q)
    # body strips
    for i in range(n - 1):
        for j in range(LAT):
            quad = np.array([rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1]])
            uv = np.array([road_uv(i, j), road_uv(i + 1, j), road_uv(i + 1, j + 1), road_uv(i, j + 1)])
            q = Poly(quad, uv, "conn", "road", name, col=np.array([blend[i], blend[i + 1], blend[i + 1], blend[i]]))
            if q.normal() @ U[i] < 0:
                q.p = q.p[::-1]; q.uv = q.uv[::-1]; q.col = q.col[::-1]
            polys.append(q)
    # rails (inward-facing, both sides) + skirts (outward, down to the ground)
    for i in range(n - 1):
        for side, j in ((-1, 0), (1, LAT)):
            a, b = rows[i][j], rows[i + 1][j]
            ua, ub = U[i], U[i + 1]
            rail = np.array([a, b, b + ub * RAIL_H, a + ua * RAIL_H])
            uv = np.array([[dist[i] / 4, 0], [dist[i + 1] / 4, 0], [dist[i + 1] / 4, 1], [dist[i] / 4, 1]])
            q = Poly(rail, uv, RW_BARRIER, "wall", name)
            inward = -R[i] * side
            if q.normal() @ inward < 0:
                q.p = q.p[::-1]; q.uv = q.uv[::-1]
            polys.append(q)
            # back of the rail (so it is solid from outside too)
            q2 = Poly(q.p[::-1].copy(), q.uv[::-1].copy(), RW_BARRIER, "wall", name)
            polys.append(q2)
            if U[i][1] > 0.7 and U[i + 1][1] > 0.7:     # no skirt on the loop
                sk = np.array([a, a - np.array([0, 6.0, 0]), b - np.array([0, 6.0, 0]), b])
                uvs = np.array([[0, 0], [0, 1.5], [1, 1.5], [1, 0]])
                q3 = Poly(sk, uvs, RW_BARRIER, "deco", name)
                if q3.normal() @ (R[i] * side) < 0:
                    q3.p = q3.p[::-1]; q3.uv = q3.uv[::-1]
                polys.append(q3)
    return polys, np.array(widths), T, U


# ======================================================================== export

def export(polys, data):
    """Group polygons into surfaces and write track.json + track.bin in Godot
    conventions (clockwise front faces, UV v down)."""
    os.makedirs(TEXOUT, exist_ok=True)
    groups = {}
    for p in polys:
        key = (p.tex, p.cls, bool(p.alpha))
        groups.setdefault(key, []).append(p)
    floats = []
    ints = []
    surfaces = []
    foff = 0
    ioff = 0
    for (tex, cls, alpha), ps in sorted(groups.items()):
        pos, nrm, uv, col, idx = [], [], [], [], []
        base = 0
        for p in ps:
            k = len(p.p)
            nn = p.normal()
            pos.append(p.p); nrm.append(np.tile(nn, (k, 1)))
            u = p.uv.copy(); u[:, 1] = 1.0 - u[:, 1]
            uv.append(u)
            col.append(p.col if p.col is not None else np.zeros(k))
            for t in range(1, k - 1):
                idx += [base, base + t + 1, base + t]        # CCW -> CW
            base += k
        pos = np.concatenate(pos).astype(np.float32); nrm = np.concatenate(nrm).astype(np.float32)
        uv = np.concatenate(uv).astype(np.float32); col = np.concatenate(col).astype(np.float32)
        idx = np.array(idx, np.int32)
        nv = len(pos)
        surf = {"texture": tex, "class": cls, "alpha": alpha, "vertices": nv, "indices": len(idx),
                "pos": foff, "nrm": foff + nv * 3, "uv": foff + nv * 6, "col": foff + nv * 8, "idx": ioff}
        floats += [pos.reshape(-1), nrm.reshape(-1), uv.reshape(-1), col]
        foff += nv * 9
        ints.append(idx)
        ioff += len(idx)
        surfaces.append(surf)
    fbuf = np.concatenate(floats).astype("<f4").tobytes()
    ibuf = np.concatenate(ints).astype("<i4").tobytes()
    with open(os.path.join(OUT, "track.bin"), "wb") as f:
        f.write(fbuf); f.write(ibuf)
    data["surfaces"] = surfaces
    data["float_count"] = foff
    data["int_offset_bytes"] = len(fbuf)
    data["int_count"] = ioff
    with open(os.path.join(OUT, "track.json"), "w") as f:
        json.dump(data, f, separators=(",", ":"))
    # textures
    texs = {s["texture"] for s in surfaces if s["texture"] != "conn"} | {RW_ASPHALT, IS_ROAD_TEX, RW_GRASS}
    for t in texs:
        src = os.path.join(RW_DIR, t)
        if not os.path.exists(src):
            src = os.path.join(IS_DIR, t.upper().replace(".PNG", ".png"))
        if not os.path.exists(src):
            src = os.path.join(IS_DIR, t)
        shutil.copyfile(src, os.path.join(TEXOUT, t.lower()))
    print(f"exported {len(surfaces)} surfaces, {foff // 9} verts-ish, {ioff // 3} tris")


class HeightCover:
    """Raster (0.5 m) of the lowest covering surface (island + connectors), grown by a
    margin, used to carve the Raceway ground beneath the new pieces."""
    def __init__(self, polys, margin):
        import cv2
        self.S = 2.0
        self.ox, self.oz = -400.0, -400.0
        n = int(800 * self.S)
        H = np.full((n, n), np.inf, np.float32)
        for p in polys:
            pts = np.array([[(q[0] - self.ox) * self.S, (q[2] - self.oz) * self.S] for q in p.p])
            x0, y0 = np.floor(pts.min(0)).astype(int) - 1
            x1, y1 = np.ceil(pts.max(0)).astype(int) + 2
            m = np.zeros((y1 - y0, x1 - x0), np.uint8)
            cv2.fillPoly(m, [np.round(pts - [x0, y0]).astype(np.int32)], 1)
            sub = H[y0:y1, x0:x1]
            sub[m > 0] = np.minimum(sub[m > 0], p.p[:, 1].min())
        big = np.where(np.isinf(H), 1e6, H).astype(np.float32)
        # Allowed ground height: below the cover inside the margin, then rising at
        # 45 degrees away from it (an embankment), up to a 16 m reach.
        reach = 16.0
        k = int(reach * self.S) * 2 + 1
        near_h = cv2.erode(big, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
        mask = (big < 1e5).astype(np.uint8)
        outside = cv2.distanceTransform(1 - mask, cv2.DIST_L2, 5) / self.S
        allowed = near_h + np.maximum(0.0, outside - margin) * 1.0
        allowed[outside > reach] = 1e6
        allowed[near_h > 1e5] = 1e6
        self.H = allowed.astype(np.float32)
        self.n = n

    def height(self, x, z):
        i, j = int((z - self.oz) * self.S), int((x - self.ox) * self.S)
        if 0 <= i < self.n and 0 <= j < self.n and self.H[i, j] < 1e5:
            return float(self.H[i, j])
        return None

    def touches(self, p):
        lo = p.p.min(0); hi = p.p.max(0)
        i0, j0 = int((lo[2] - self.oz) * self.S), int((lo[0] - self.ox) * self.S)
        i1, j1 = int((hi[2] - self.oz) * self.S) + 1, int((hi[0] - self.ox) * self.S) + 1
        i0, j0 = max(i0, 0), max(j0, 0)
        return bool((self.H[i0:i1, j0:j1] < 1e5).any())


def subdivide(p, max_edge):
    """Split a polygon into triangles no longer than max_edge (UVs interpolated)."""
    out = []
    stack = [(p.p[[0, t, t + 1]], p.uv[[0, t, t + 1]]) for t in range(1, len(p.p) - 1)]
    while stack:
        P, UV = stack.pop()
        e = [np.linalg.norm(P[(i + 1) % 3] - P[i]) for i in range(3)]
        i = int(np.argmax(e))
        if e[i] <= max_edge:
            out.append(Poly(P.copy(), UV.copy(), p.tex, p.cls, p.src, p.alpha))
            continue
        j, k = (i + 1) % 3, (i + 2) % 3
        m = (P[i] + P[j]) / 2; mu = (UV[i] + UV[j]) / 2
        stack.append((np.array([P[i], m, P[k]]), np.array([UV[i], mu, UV[k]])))
        stack.append((np.array([m, P[j], P[k]]), np.array([mu, UV[j], UV[k]])))
    return out


# ======================================================================== main

def classify_island(p):
    up = p.normal()[1]
    if p.src.startswith("Trk"):
        return "road" if up > 0.6 else "wall"
    if up > 0.6:
        return "off"
    return "deco" if p.alpha else "wall"


def footprint_mask(polys_list, margin):
    import cv2
    S = 2.0
    ox, oz = -400.0, -400.0
    img = np.zeros((int(800 * S), int(800 * S)), np.uint8)
    for p in polys_list:
        pts = np.array([[(q[0] - ox) * S, (q[2] - oz) * S] for q in p.p], np.int32)
        cv2.fillPoly(img, [pts], 255)
    k = int(margin * S) * 2 + 1
    img = cv2.dilate(img, np.ones((k, k), np.uint8))
    def inside(x, z):
        i, j = int((z - oz) * S), int((x - ox) * S)
        return 0 <= i < img.shape[0] and 0 <= j < img.shape[1] and img[i, j] > 0
    return inside


def main():
    rw = load_raceway()
    isl_all = load_island()
    cl, cw = raceway_centreline(rw)
    n = len(cl)
    i_in = int(np.argmin(np.linalg.norm(cl[:, [0, 2]] - P_IN_XZ, axis=1)))
    i_out = int(np.argmin(np.linalg.norm(cl[:, [0, 2]] - P_OUT_XZ, axis=1)))
    i_start = int(np.argmin(np.linalg.norm(cl[:, [0, 2]] - START_XZ, axis=1)))
    rw2, edge_in, edge_out = cut_raceway(rw, cl, i_in, i_out)
    print(f"raceway: {n} samples, cut {i_in}->{i_out}, edges {len(edge_in)}/{len(edge_out)} verts")

    # --- island: place it, pick the pieces we use ------------------------------
    keys, cen = piece_floor_centres(isl_all, IS_MAIN[0], IS_MAIN[1])
    exit_y = cen[-1][1]
    oy = edge_out[:, 1].mean() - exit_y
    off = np.array([IS_OFFSET_XZ[0], oy, IS_OFFSET_XZ[1]])
    for p in isl_all:
        p.p = p.p + off
    sel_trk = [p for p in isl_all if p.src.startswith("Trk") and
               (IS_MAIN[0] <= int(p.src[3:]) <= IS_MAIN[1] or IS_FORK[0] <= int(p.src[3:]) <= IS_FORK[1])]
    other_trk = [p for p in isl_all if p.src.startswith("Trk") and p not in set(sel_trk)]
    sel_c = np.array([p.centroid() for p in sel_trk])
    oth_c = np.array([p.centroid() for p in other_trk])
    sel_dec = []
    for p in isl_all:
        if not p.src.startswith("Dec"):
            continue
        c = p.centroid()
        ds = np.min(np.linalg.norm(sel_c[:, [0, 2]] - c[[0, 2]], axis=1))
        do = np.min(np.linalg.norm(oth_c[:, [0, 2]] - c[[0, 2]], axis=1))
        if ds < 18.0 and ds < do:
            sel_dec.append(p)
    island = sel_trk + sel_dec
    for p in island:
        p.cls = classify_island(p)
    print(f"island: {len(sel_trk)} track polys, {len(sel_dec)} decoration polys, offset {off.round(2)}")

    keys, cen = piece_floor_centres(island, IS_MAIN[0], IS_MAIN[1])
    main_cl = resample_open(smooth_open(resample_open(cen, 1.0), 12), SPACING)
    fkeys, fcen = piece_floor_centres(island, IS_FORK[0], IS_FORK[1])
    fork_cl = resample_open(smooth_open(resample_open(fcen, 1.0), 12), SPACING)
    # Heights from the real road surface (piece-centre averages sag on ramps).
    isl_road = [p for p in island if p.cls == "road"]
    main_cl[:, 1] = smooth_open(heights_at(isl_road, main_cl, {"road"})[:, None], 2)[:, 0]
    fork_cl[:, 1] = smooth_open(heights_at(isl_road, fork_cl, {"road"})[:, None], 2)[:, 0]

    t_entry = main_cl[2] - main_cl[0]; t_entry[1] = 0; t_entry /= np.linalg.norm(t_entry)
    t_exit = main_cl[-1] - main_cl[-3]; t_exit[1] = 0; t_exit /= np.linalg.norm(t_exit)
    e_entry = island_edge(isl_all, IS_MAIN[0] - 1, IS_MAIN[0], np.cross(t_entry, [0, 1.0, 0]))
    e_exit = island_edge(isl_all, IS_MAIN[1], IS_MAIN[1] + 1, np.cross(t_exit, [0, 1.0, 0]))
    print(f"island edges: entry {len(e_entry)} verts, exit {len(e_exit)} verts")

    # --- connectors ------------------------------------------------------------
    t_in = cl[(i_in + 1) % n] - cl[i_in - 1]; t_in[1] = 0
    t_out = cl[(i_out + 1) % n] - cl[i_out - 1]; t_out[1] = 0
    PA, UPA, loopA = build_connector_path(edge_in.mean(0), t_in, e_entry.mean(0), t_entry, with_loop=True)
    PB, UPB, loopB = build_connector_path(e_exit.mean(0), t_exit, edge_out.mean(0), t_out, with_loop=False)
    conA, wA, TA, UA = loft_connector(PA, UPA, edge_in, e_entry, 0.0, 1.0, "connA")
    conB, wB, TB, UB = loft_connector(PB, UPB, e_exit, edge_out, 1.0, 0.0, "connB")
    print(f"connector A: {len(PA)} pts ({len(PA) * 0.5:.0f} m, loop {loopA.sum() * 0.5:.0f} m); connector B: {len(PB) * 0.5:.0f} m")

    # --- carve the Raceway ground under the new pieces ---------------------------
    # Terrain under the island / connectors is subdivided and pushed below them
    # (never deleted, so no holes); walls and props in the way are removed.
    cover = [p for p in island] + [p for p in conA + conB if p.cls != "deco"]
    H = HeightCover(cover, margin=3.0)
    kept = []
    dropped = carved = 0
    for p in rw2:
        if p.cls == "road":
            kept.append(p)
            continue
        if not H.touches(p):
            kept.append(p)
            continue
        if p.cls in ("wall", "deco"):
            if abs(p.normal()[1]) < 0.6:
                dropped += 1
                continue
            # A flat top (e.g. the brick blocks) is the only ground there - keep it
            # and carve it like terrain instead of leaving a hole.
            p.cls = "off"
        for q in subdivide(p, 3.0):
            for k in range(len(q.p)):
                h = H.height(q.p[k][0], q.p[k][2])
                if h is not None and q.p[k][1] > h - 0.5:
                    q.p[k][1] = h - 0.5
            kept.append(q)
            carved += 1
    print(f"raceway under detour: {dropped} walls/props removed, ground carved into {carved} polys")

    # start / finish stripe
    s0 = cl[i_start]
    ts = cl[(i_start + 1) % n] - cl[i_start - 1]; ts[1] = 0; ts /= np.linalg.norm(ts)
    rs = np.cross(ts, [0, 1.0, 0])
    hw = cw[i_start] * 0.5
    stripe = Poly(np.array([s0 - rs * hw - ts * 1.5, s0 + rs * hw - ts * 1.5, s0 + rs * hw + ts * 1.5, s0 - rs * hw + ts * 1.5]) + [0, 0.04, 0],
                  np.array([[0, 0.12], [1, 0.12], [1, 0.30], [0, 0.30]]), "92276F6_c.png", "deco", "start")
    if stripe.normal()[1] < 0:
        stripe.p = stripe.p[::-1]; stripe.uv = stripe.uv[::-1]

    # Ground layer under the detour area: fills the gaps where the island's low
    # beaches meet the Raceway terrain (sky used to show through).
    gy = -4.6
    gx0, gx1, gz0, gz1 = -12.0, 182.0, -150.0, 170.0
    ground = Poly(np.array([[gx0, gy, gz0], [gx0, gy, gz1], [gx1, gy, gz1], [gx1, gy, gz0]], float),
                  np.array([[gx0, gz0], [gx0, gz1], [gx1, gz1], [gx1, gz0]], float) / 8.0, RW_GRASS, "off", "ground")
    if ground.normal()[1] < 0:
        ground.p = ground.p[::-1]; ground.uv = ground.uv[::-1]
    polys = kept + island + conA + conB + [stripe, ground]

    # --- centreline (travel order, starting at the start line) ------------------
    seg_rw_a = [cl[k % n] for k in range(i_out, i_in + (n if i_in < i_out else 0) + 1)]
    seq = []           # (pos, up, width, flags)
    for k in range(i_out, i_in + (n if i_in < i_out else 0) + 1):
        seq.append((cl[k % n], np.array([0, 1.0, 0]), cw[k % n], 0))
    for i in range(0, len(PA), 4):
        seq.append((PA[i], UA[i], wA[i], 4 if loopA[i] else 0))
    main_start = len(seq)
    for q in main_cl:
        seq.append((q, np.array([0, 1.0, 0]), 10.0, 8))
    main_end = len(seq) - 1
    for i in range(0, len(PB), 4):
        seq.append((PB[i], UB[i], wB[i], 0))
    # rotate so the start line is sample 0
    pts_seq = np.array([s[0] for s in seq])
    s_idx = int(np.argmin(np.linalg.norm(pts_seq[:, [0, 2]] - START_XZ, axis=1)))
    seq = seq[s_idx:] + seq[:s_idx]
    main_start = (main_start - s_idx) % len(seq)
    main_end = (main_end - s_idx) % len(seq)
    P_all = np.array([s[0] for s in seq])
    seglen = np.linalg.norm(np.roll(P_all, -1, 0) - P_all, axis=1)
    dist = np.concatenate([[0], np.cumsum(seglen)[:-1]])
    total = float(seglen.sum())
    # fork joins
    f_from = int(np.argmin(np.linalg.norm(P_all - fork_cl[0], axis=1)))
    f_to = int(np.argmin(np.linalg.norm(P_all - fork_cl[-1], axis=1)))
    # checkpoints: evenly spaced, nudged out of the fork span and the loop
    cps = []
    for c in range(10):
        target = total * c / 10.0
        i = int(np.argmin(np.abs(dist - target)))
        while (f_from <= i <= f_to) or (seq[i][3] & 4):
            i = (i + 1) % len(seq)
        cps.append(i)
    # starting grid: 2 columns, 3 m apart, 6 m rows behind the line
    t0 = P_all[1] - P_all[0]; t0[1] = 0; t0 /= np.linalg.norm(t0)
    r0 = np.cross(t0, [0, 1.0, 0])
    grid = []
    for k in range(8):
        row, col = divmod(k, 2)
        g = P_all[0] - t0 * (6.0 + row * 6.0) + r0 * (-2.5 if col == 0 else 2.5)
        g[1] = heights_at(kept, np.array([g]), {"road"})[0] + 0.3
        grid.append({"pos": g.round(3).tolist(), "fwd": t0.round(4).tolist()})

    data = {
        "name": "Retro Circuit (Mario Raceway x Resort Island)",
        "length": round(total, 2),
        "centreline": [{"p": s[0].round(3).tolist(), "up": np.round(s[1], 4).tolist(), "w": round(float(s[2]), 2), "f": int(s[3])} for s in seq],
        "fork": {"points": [q.round(3).tolist() for q in fork_cl], "join_from": f_from, "join_to": f_to},
        "checkpoints": cps,
        "grid": grid,
        "island_span": [main_start, main_end],
        "kill_y": -25.0,
        "sections": [
            {"name": "Mario Raceway", "from": 0, "to": main_start},
            {"name": "Resort Island", "from": main_start, "to": main_end},
        ],
        "textures": {"conn_a": RW_ASPHALT.lower(), "conn_b": IS_ROAD_TEX, "conn_b_rect": list(IS_ROAD_RECT)},
    }
    export(polys, data)
    print(f"lap length {total:.0f} m, {len(seq)} centreline samples, fork {f_from}->{f_to}, checkpoints {cps}")
    plot(polys, P_all, cps, fork_cl)


def plot(polys, P_all, cps, fork_cl):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    col = {"road": "#555555", "off": "#7cba5a", "wall": "#c0392b", "deco": "#e0c070", "conn": "#555555"}
    fig, ax = plt.subplots(figsize=(16, 13))
    order = {"off": 0, "deco": 1, "wall": 2, "road": 3}
    ps = sorted(polys, key=lambda p: (order.get(p.cls, 0), p.centroid()[1]))
    ax.add_collection(PolyCollection([p.p[:, [0, 2]] for p in ps],
                                     facecolors=[("#3b6fb6" if p.src.startswith("conn") and p.cls == "road" else col.get(p.cls, "#999")) for p in ps],
                                     edgecolors="none"))
    ax.plot(P_all[:, 0], P_all[:, 2], "y-", lw=1)
    ax.plot(fork_cl[:, 0], fork_cl[:, 2], "m-", lw=1)
    for k, i in enumerate(cps):
        ax.plot(P_all[i, 0], P_all[i, 2], "ko", ms=6)
        ax.text(P_all[i, 0] + 3, P_all[i, 2] + 3, f"CP{k}", fontsize=9, weight="bold")
    ax.plot(P_all[0, 0], P_all[0, 2], "w*", ms=18, mec="k")
    ax.set_aspect("equal"); ax.autoscale(); ax.invert_yaxis()
    ax.set_title("Merged course - grey road (Raceway/Island), blue = generated connectors, red = walls, star = start")
    os.makedirs(os.path.join(ROOT, "out"), exist_ok=True)
    plt.savefig(os.path.join(ROOT, "out", "track_top.png"), dpi=70)


if __name__ == "__main__":
    main()
