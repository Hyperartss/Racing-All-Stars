#!/usr/bin/env python3
"""Map Combiner backend: bakes race courses from pieces of existing tracks.

    python3 tools/bake/trackbake.py bake <map_id>        # content/maps/<map_id>.json -> assets/maps/<map_id>/
    python3 tools/bake/trackbake.py analyze <source_id>  # content/track_sources/<id>.json -> <id>.analysis.json
    python3 tools/bake/trackbake.py list

A *source* (content/track_sources/<id>.json) describes one original track model:
where its OBJ is, its scale, how to find its centreline ("road_skeleton" from road
textures, or "groups" from numbered track pieces like Sonic R's TrkNNN) and how to
sort its polygons into road / off-road / wall / decoration.

A *map* (content/maps/<id>.json, "layout" block) is an ordered loop of *segments*:
    {"source": id, "from": [x, z], "to": [x, z], "via": [x, z]}      part of a skeleton track
    {"source": id, "groups": [first, last], "branches": [[a, b]]}     part of a grouped track
    {"source": id, "full": true}                                      the whole original loop
each with "offset": [x, y | "auto", z], "yaw": degrees and "scenery": "all" | "near".
Consecutive segments are joined by generated connectors ("connectors": [{"loop": true}, ...]),
whose ends are stitched to the exact cut edges, so the road stays watertight.
Coordinates in from/to/via/start are in the source's own space (after its scale).

Reads only the originals (Tracks/...). Requires numpy, pillow, opencv-python,
scikit-image, networkx, matplotlib.
"""
import json, os, shutil, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from trackgeo import (Poly, read_obj, clip_poly, resample_closed, resample_open, smooth_closed,
                      smooth_open, hermite, rot_y, zip_strip)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CONTENT = os.path.join(ROOT, "content")
SPACING = 2.0
LOOP_R = 11.0
CONN_W = 11.0
RAIL_H = 1.1


def jload(path):
    with open(path) as f:
        return json.load(f)


def res_path(rel):
    return os.path.join(ROOT, rel.replace("res://", ""))


# =========================================================================== sources

class Source:
    """One original track: polygons (classified, scaled), texture files, centreline."""
    _cache = {}

    @classmethod
    def get(cls, sid):
        if sid not in cls._cache:
            cls._cache[sid] = Source(jload(os.path.join(CONTENT, "track_sources", sid + ".json")))
        return cls._cache[sid]

    def __init__(self, cfg):
        self.cfg = cfg
        self.id = cfg["id"]
        self.tex_dir = os.path.join(ROOT, cfg["tex_dir"])
        files = os.listdir(self.tex_dir)
        self.tex_files = {f.lower(): os.path.join(self.tex_dir, f) for f in files}
        V, VT, polys, mtl = read_obj(os.path.join(ROOT, cfg["obj"]), os.path.join(ROOT, cfg["mtl"]))
        V = V * float(cfg.get("scale", 1.0))
        cl = cfg["classes"]
        self.polys = []
        self.ground_polys = []
        for mat, grp, vi, ti in polys:
            info = mtl.get(mat, {})
            tex = self.tex_key(info.get("tex", ""))
            uv = np.array([VT[t] if t >= 0 else [0, 0] for t in ti])
            alpha = "alpha" in info if cl["method"] == "groups" else any(s in info.get("tex", "") for s in cl.get("alpha_if_name_contains", []))
            p = Poly(V[vi], uv, tex, "", grp or "", alpha)
            if cl["method"] == "groups":
                if grp in cl.get("ground_groups", []):
                    p.cls = "off"
                    self.ground_polys.append(p)
                    continue
                if grp is None or grp in cl.get("skip", []):
                    continue
                # Floors are found by normal in either winding (some Sonic R faces
                # are wound upside down); cut-out floors (boardwalks) still collide.
                up = abs(p.normal()[1])
                if grp.startswith(cl["track_prefix"]):
                    p.cls = "road" if up > 0.6 else "wall"
                elif up > 0.6:
                    p.cls = "off"
                else:
                    p.cls = "deco" if alpha else "wall"
            else:
                raw = info.get("tex", "")
                p.cls = "road" if raw in cl["road"] else "wall" if raw in cl.get("wall", []) else "deco" if raw in cl.get("deco", []) else "off"
            self.polys.append(p)
        self.road_tex = self.tex_key(cfg.get("road_texture", ""))
        self.grass_tex = self.tex_key(cfg.get("grass_texture", ""))
        self.rail_tex = self.tex_key(cfg.get("rail_texture", ""))
        self.start_tex = self.tex_key(cfg.get("start_texture", cfg.get("road_texture", "")))
        self._cl = None

    def tex_key(self, name):
        """Unique, lower-case texture name used in the baked map."""
        if not name:
            return ""
        return f"{self.id}__{name.lower()}"

    def tex_file(self, key):
        return self.tex_files.get(key.split("__", 1)[1])

    # --- centrelines ---------------------------------------------------------------
    def skeleton_centreline(self):
        """Closed centreline of the rasterised road (2 m spacing) + widths."""
        if self._cl is not None:
            return self._cl
        import cv2
        import networkx as nx
        from skimage.morphology import skeletonize
        road = [p for p in self.polys if p.cls == "road"]
        allp = np.concatenate([p.p for p in road])
        lo = allp.min(0) - 20
        hi = allp.max(0) + 20
        S = 4.0
        ox, oz = lo[0], lo[2]
        W, H = int((hi[0] - lo[0]) * S), int((hi[2] - lo[2]) * S)
        img = np.zeros((H, W), np.uint8)
        for p in road:
            cv2.fillPoly(img, [np.array([[(q[0] - ox) * S, (q[2] - oz) * S] for q in p.p], np.int32)], 255)
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
        pts2 = resample_closed(smooth_closed(resample_closed(pts2, 1.0), 6), SPACING)
        widths = np.array([2.0 * dist[min(max(int((z - oz) * S), 0), H - 1), min(max(int((x - ox) * S), 0), W - 1)] / S for x, z in pts2])
        pts = np.c_[pts2[:, 0], np.zeros(len(pts2)), pts2[:, 1]]
        pts[:, 1] = heights_at(road, pts)
        self._cl = (pts, np.clip(widths, 6, 30))
        return self._cl

    def piece_centres(self, lo, hi, polys=None):
        acc = {}
        prefix = self.cfg["centreline"]["prefix"]
        for p in (polys if polys is not None else self.polys):
            if not p.src.startswith(prefix) or p.cls != "road":
                continue
            k = int(p.src[len(prefix):])
            if lo <= k <= hi:
                acc.setdefault(k, []).append(p.p)
        keys = sorted(acc)
        return keys, np.array([np.concatenate(acc[k]).mean(0) for k in keys])

    def group_id(self, p):
        prefix = self.cfg["centreline"]["prefix"]
        return int(p.src[len(prefix):]) if p.src.startswith(prefix) else None


def road_widths(polys, pts, lo=5.0, hi=30.0):
    """Road width at each centreline point, from a raster of the road surface."""
    import cv2
    allp = np.concatenate([p.p for p in polys])
    S = 4.0
    ox, oz = allp[:, 0].min() - 5, allp[:, 2].min() - 5
    W, H = int((allp[:, 0].max() - ox + 5) * S), int((allp[:, 2].max() - oz + 5) * S)
    img = np.zeros((H, W), np.uint8)
    for p in polys:
        cv2.fillPoly(img, [np.array([[(q[0] - ox) * S, (q[2] - oz) * S] for q in p.p], np.int32)], 255)
    img = cv2.morphologyEx(img, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    dist = cv2.distanceTransform(img, cv2.DIST_L2, 5)
    out = []
    for q in pts:
        i, j = int((q[2] - oz) * S), int((q[0] - ox) * S)
        out.append(2.0 * dist[min(max(i, 0), H - 1), min(max(j, 0), W - 1)] / S)
    return np.clip(np.array(out), lo, hi)


def heights_at(polys, pts, missing=None):
    """Highest polygon directly above/below each XZ point. Points with no polygon get
    `missing`, or the previous point's height when missing is None."""
    if not polys:
        return np.zeros(len(pts))
    mins = np.array([p.p[:, [0, 2]].min(0) for p in polys])
    maxs = np.array([p.p[:, [0, 2]].max(0) for p in polys])
    out = np.zeros(len(pts))
    for k, q in enumerate(pts):
        best = None
        sel = np.nonzero((mins[:, 0] <= q[0]) & (maxs[:, 0] >= q[0]) & (mins[:, 1] <= q[2]) & (maxs[:, 1] >= q[2]))[0]
        for i in sel:
            P = polys[i].p
            for t in range(1, len(P) - 1):
                h = _tri_height(P[0], P[t], P[t + 1], q[0], q[2])
                if h is not None and (best is None or h > best):
                    best = h
        if best is not None:
            out[k] = best
        else:
            out[k] = missing if missing is not None else (out[k - 1] if k else 0.0)
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


def _floor_near(floors, g, ref_y, tol=1.5):
    """Height of a floor under g within tol of the route height, else None."""
    near = [p for p in floors if np.linalg.norm(p.centroid()[[0, 2]] - g[[0, 2]]) < 15]
    best = None
    for p in near:
        P = p.p
        for t in range(1, len(P) - 1):
            h = _tri_height(P[0], P[t], P[t + 1], g[0], g[2])
            if h is not None and abs(h - ref_y) < tol and (best is None or abs(h - ref_y) < abs(best - ref_y)):
                best = h
    return best


def nearest(cl, xz):
    return int(np.argmin(np.linalg.norm(cl[:, [0, 2]] - np.asarray(xz, float), axis=1)))


def sort_edge(pts, p0, t):
    pts = np.unique(np.round(np.array(pts), 6), axis=0)
    right = np.cross(t, [0, 1.0, 0]); right /= np.linalg.norm(right)
    return pts[np.argsort((pts - p0) @ right)]


def flat(t):
    t = np.array(t, float); t[1] = 0
    return t / (np.linalg.norm(t) + 1e-12)


# ========================================================================== segments

class Segment:
    """A placed piece of a source track. After build(): polys, cl (N x 3, travel order),
    widths, closed, start/end edges + tangents (unless closed), branches."""

    def __init__(self, cfg, index):
        self.cfg = cfg
        self.index = index
        self.src = Source.get(cfg["source"])
        self.scenery = cfg.get("scenery", "all" if self.src.cfg["centreline"]["method"] == "road_skeleton" else "near")
        self.closed = bool(cfg.get("full", False))
        self.branches = []      # list of (points N x 3, ai flag, name)
        self.edge_s = self.edge_e = None

    def build(self):
        if self.src.cfg["centreline"]["method"] == "road_skeleton":
            self._build_skeleton()
        else:
            self._build_groups()
        self.polys = [p for p in self.polys]
        return self

    # --- skeleton tracks (e.g. Mario Raceway) ------------------------------------------
    def _build_skeleton(self):
        src = self.src
        cl, w = src.skeleton_centreline()
        cl = cl.copy(); w = w.copy()
        n = len(cl)
        polys = [Poly(p.p.copy(), p.uv.copy(), p.tex, p.cls, p.src, p.alpha) for p in src.polys]
        start = self.cfg.get("from", self.cfg.get("start", src.cfg.get("default_start", cl[0][[0, 2]].tolist())))
        # "via" picks the travel direction. The source's default only applies to full loops.
        via = self.cfg.get("via", src.cfg.get("default_via") if self.closed else None)
        i0 = nearest(cl, start)
        if self.closed:
            # Travel direction: towards `via`.
            if via is not None:
                iv = nearest(cl, via)
                if (iv - i0) % n > n // 2:
                    cl, w = cl[::-1].copy(), w[::-1].copy()
                    i0 = n - 1 - i0
            cl = np.roll(cl, -i0, axis=0); w = np.roll(w, -i0)
            self.polys, self.cl, self.w = polys, cl, w
            return
        if "to" not in self.cfg or "from" not in self.cfg:
            raise SystemExit(f"segment {self.index + 1} ({src.id}): no cut points - set From and To in the Map Combiner")
        i1 = nearest(cl, self.cfg["to"])
        # Direction: the arc from -> to that contains `via` (default: the longer one).
        fwd_len = (i1 - i0) % n
        use_fwd = fwd_len >= n - fwd_len
        if via is not None:
            iv = nearest(cl, via)
            use_fwd = (iv - i0) % n <= fwd_len
        if not use_fwd:
            cl, w = cl[::-1].copy(), w[::-1].copy()
            i0, i1 = n - 1 - i0, n - 1 - i1
        kept_polys, edge_end, edge_start = cut_road(polys, cl, i_in=i1, i_out=i0, grass=src.grass_tex)
        ks = [(i0 + k) % n for k in range((i1 - i0) % n + 1)]
        self.cl, self.w = cl[ks], w[ks]
        self.polys = kept_polys
        self.edge_s, self.edge_e = edge_start, edge_end
        if self.scenery == "near":
            self.polys = near_only(self.polys, self.cl, 30.0)

    # --- grouped tracks (e.g. Sonic R TrkNNN pieces) -------------------------------------
    def _build_groups(self):
        src = self.src
        main = src.cfg["centreline"]["main"]
        if not self.closed and "groups" not in self.cfg:
            raise SystemExit(f"segment {self.index + 1} ({src.id}): no piece range - set Pieces in the Map Combiner")
        g0, g1 = (main if self.closed else self.cfg["groups"])
        g0, g1 = int(g0), int(g1)
        ranges = [(g0, g1)]
        branch_cfg = []
        for b in src.cfg.get("branches", []):
            want = self.cfg.get("branches", "auto")
            lo_b, hi_b = b["groups"]
            if want == "auto":
                ok = self.closed or self._branch_inside(b, g0, g1)
            else:
                ok = [lo_b, hi_b] in [list(x) for x in want]
            if ok:
                ranges.append((lo_b, hi_b))
                branch_cfg.append(b)
        sel = [p for p in src.polys if src.group_id(p) is not None and any(a <= src.group_id(p) <= b for a, b in ranges)]
        others = [p for p in src.polys if src.group_id(p) is not None and p not in set(sel)]
        if self.closed:
            dec = [p for p in src.polys if src.group_id(p) is None]
            ground = src.ground_polys
        else:
            sel_c = np.array([p.centroid() for p in sel])
            oth_c = np.array([p.centroid() for p in others]) if others else np.zeros((1, 3)) + 1e9
            dec = []
            for p in src.polys:
                if src.group_id(p) is not None:
                    continue
                c = p.centroid()
                ds = np.min(np.linalg.norm(sel_c[:, [0, 2]] - c[[0, 2]], axis=1))
                do = np.min(np.linalg.norm(oth_c[:, [0, 2]] - c[[0, 2]], axis=1))
                if ds < 18.0 and ds < do:
                    dec.append(p)
            ground = []
        self.polys = [Poly(p.p.copy(), p.uv.copy(), p.tex, p.cls, p.src, p.alpha) for p in sel + dec + ground]
        road = [p for p in self.polys if p.cls == "road"]
        keys, cen = src.piece_centres(g0, g1, self.polys)
        if self.closed:
            cl = resample_closed(smooth_closed(resample_closed(cen, 1.0), 12), SPACING)
        else:
            cl = resample_open(smooth_open(resample_open(cen, 1.0), 12), SPACING)
        cl[:, 1] = heights_at(road, cl)
        cl[:, 1] = smooth_closed(cl[:, 1:2], 2)[:, 0] if self.closed else smooth_open(cl[:, 1:2], 2)[:, 0]
        if self.closed:
            i0 = nearest(cl, self.cfg.get("start", src.cfg.get("default_start", cl[0][[0, 2]].tolist())))
            cl = np.roll(cl, -i0, axis=0)
        main_road = [p for p in road if src.group_id(p) is not None and g0 <= src.group_id(p) <= g1]
        w = road_widths(main_road, cl, 5.0, 16.0)
        self.cl, self.w = cl, smooth_closed(w[:, None], 3)[:, 0] if self.closed else smooth_open(w[:, None], 3)[:, 0]
        for b in branch_cfg:
            bk, bc = src.piece_centres(b["groups"][0], b["groups"][1], self.polys)
            if len(bc) < 3:
                continue
            bcl = resample_open(smooth_open(resample_open(bc, 1.0), 12), SPACING)
            bcl[:, 1] = smooth_open(heights_at(road, bcl)[:, None], 2)[:, 0]
            self.branches.append((bcl, bool(b.get("ai", True)), b.get("name", "branch")))
        if not self.closed:
            t_s = flat(cl[2] - cl[0]); t_e = flat(cl[-1] - cl[-3])
            self.edge_s = group_edge(src, g0 - 1, g0, np.cross(t_s, [0, 1.0, 0]))
            self.edge_e = group_edge(src, g1, g1 + 1, np.cross(t_e, [0, 1.0, 0]))

    def _branch_inside(self, b, g0, g1):
        """A branch belongs to this segment if both its ends are near the kept route."""
        _, cen = self.src.piece_centres(g0, g1)
        _, bc = self.src.piece_centres(b["groups"][0], b["groups"][1])
        if len(bc) < 2 or len(cen) < 2:
            return False
        d0 = np.min(np.linalg.norm(cen - bc[0], axis=1))
        d1 = np.min(np.linalg.norm(cen - bc[-1], axis=1))
        return d0 < 30 and d1 < 30

    # --- placement ------------------------------------------------------------------------
    def transform(self, yaw, offset):
        def T(P):
            return rot_y(P, yaw) + offset
        for p in self.polys:
            p.p = T(p.p)
        self.cl = T(self.cl)
        if self.edge_s is not None:
            self.edge_s = T(self.edge_s)
            self.edge_e = T(self.edge_e)
        self.branches = [(T(b), ai, n) for b, ai, n in self.branches]
        self.xf = (yaw, offset)

    def to_world_xz(self, xz):
        p = rot_y(np.array([[xz[0], 0.0, xz[1]]]), self.xf[0])[0] + self.xf[1]
        return [p[0], p[2]]

    def t_start(self):
        return flat(self.cl[min(2, len(self.cl) - 1)] - self.cl[0])

    def t_end(self):
        return flat(self.cl[-1] - self.cl[-3])


def group_edge(src, a, b, right_dir):
    """Vertices shared by piece a and piece b floors (the exact seam), left->right."""
    def verts(k):
        s = set()
        for p in src.polys:
            if src.group_id(p) == k and p.cls == "road":
                for v in p.p:
                    s.add(tuple(np.round(v, 4)))
        return s
    shared = np.array(sorted(verts(a) & verts(b)))
    if len(shared) < 2:
        raise SystemExit(f"{src.id}: pieces {a} and {b} share no floor edge - choose another cut piece")
    c = shared.mean(0)
    return shared[np.argsort((shared - c) @ right_dir)]


def cut_road(polys, cl, i_in, i_out, grass):
    """Keep the road from i_out forward to i_in; road outside becomes grass. Road
    polygons at both cut planes are clipped exactly. Returns (polys, edge_in, edge_out)."""
    n = len(cl)
    removed = np.zeros(n, bool)
    k = i_in
    while k != i_out:
        removed[k] = True
        k = (k + 1) % n
    removed[i_in] = False
    t_in = flat(cl[(i_in + 1) % n] - cl[i_in - 1])
    t_out = flat(cl[(i_out + 1) % n] - cl[i_out - 1])
    p_in, p_out = cl[i_in], cl[i_out]
    out = []
    edge_in, edge_out = [], []
    clxz = cl[:, [0, 2]]
    for p in polys:
        if p.cls != "road":
            out.append(p)
            continue
        c = p.centroid()
        near = np.argmin(np.linalg.norm(clxz - c[[0, 2]], axis=1))
        for plane_p, plane_t, keep_behind, edge in ((p_in, t_in, True, edge_in), (p_out, t_out, False, edge_out)):
            if np.linalg.norm((c - plane_p)[[0, 2]]) < 25.0:
                nrm = plane_t if keep_behind else -plane_t
                d = nrm @ plane_p
                kept = clip_poly(p.p, p.uv, -nrm, -d)
                gone = clip_poly(p.p, p.uv, nrm, d)
                if kept is not None:
                    out.append(Poly(kept[0], kept[1], p.tex, "road", p.src))
                    for v in kept[0]:
                        if abs(v @ nrm - d) < 1e-6:
                            edge.append(v)
                if gone is not None:
                    out.append(Poly(gone[0], gone[1], grass, "off", "cut"))
                break
        else:
            if removed[near]:
                p.tex, p.cls, p.src = grass, "off", "cut"
            out.append(p)
    for p in out:
        if p.src == "cut":
            p.uv = p.p[:, [0, 2]] / 8.0
    if not edge_in or not edge_out:
        raise SystemExit("cut point is not on the road - move from/to onto the track")
    return out, sort_edge(edge_in, p_in, t_in), sort_edge(edge_out, p_out, t_out)


def near_only(polys, cl, radius):
    import cv2
    out = []
    clxz = cl[:, [0, 2]]
    for p in polys:
        d = np.min(np.linalg.norm(clxz - p.centroid()[[0, 2]], axis=1))
        if d < radius:
            out.append(p)
    return out


# ========================================================================== connectors

def frames_from_path(P, up_hint=None):
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


def connector_path(p0, t0, p1, t1, loop=False, loop_at=0.3, spacing=0.5):
    """Centre path + up vectors: Hermite curve, optionally with a vertical loop on a
    straight run (the exit lane shifts sideways so the road clears itself)."""
    t0 = flat(t0); t1 = flat(t1)
    chord = np.linalg.norm(p1 - p0)
    if not loop:
        n = max(8, int(chord * 2.0 / spacing))
        P = hermite(p0, t0 * chord * 1.1, p1, t1 * chord * 1.1, n)
        P = resample_open(P, spacing)
        P[:, 1] = p0[1] + (p1[1] - p0[1]) * smoothstep(np.linspace(0, 1, len(P)))
        return P, None, np.zeros(len(P), bool)
    d = t0
    right = np.cross(d, [0, 1.0, 0]); right /= np.linalg.norm(right)
    lead = max(30.0, chord * loop_at)
    ls = p0 + d * lead
    shift = -(CONN_W + 3.0)
    th = np.linspace(0, 2 * np.pi, int(2 * np.pi * LOOP_R / spacing))
    lat = shift * (1 - np.cos(th / 2)) / 2
    loopP = ls + np.outer(np.sin(th) * LOOP_R, d) + np.outer((1 - np.cos(th)) * LOOP_R, [0, 1.0, 0]) + np.outer(lat, right)
    loopUp = (ls[None, :] + np.array([0, LOOP_R, 0]) + np.outer(lat, right)) - loopP
    loopUp /= np.linalg.norm(loopUp, axis=1, keepdims=True)
    leadP = resample_open(np.array([p0, ls]), spacing)[:-1]
    le = loopP[-1]
    rest = np.linalg.norm(p1 - le)
    n = max(8, int(rest * 2.0 / spacing))
    tail = resample_open(hermite(le, d * rest * 1.1, p1, t1 * rest * 1.1, n), spacing)
    tail[:, 1] = le[1] + (p1[1] - le[1]) * smoothstep(np.linspace(0, 1, len(tail)))
    P = np.concatenate([leadP, loopP[:-1], tail])
    UP = np.concatenate([np.tile([0, 1.0, 0], (len(leadP), 1)), loopUp[:-1], np.tile([0, 1.0, 0], (len(tail), 1))])
    mask = np.concatenate([np.zeros(len(leadP), bool), np.ones(len(loopP) - 1, bool), np.zeros(len(tail), bool)])
    return P, UP, mask


def loft_connector(P, UP, edge_a, edge_b, conn_tex, rail_tex, name):
    """Road ribbon (blend 0 -> 1 along it) + rails + skirts. First/last rows are zipped
    to the exact source cut vertices, so there is no gap."""
    T, U, R = frames_from_path(P, UP)
    n = len(P)
    LAT = 8
    dist = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
    L = dist[-1]

    def prof(edge, i):
        lp = np.c_[(edge - P[i]) @ R[i], (edge - P[i]) @ U[i]]
        d = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(lp, axis=0), axis=1))])
        s = np.linspace(0, d[-1], LAT + 1)
        return np.c_[np.interp(s, d, lp[:, 0]), np.interp(s, d, lp[:, 1])]
    pa, pb = prof(edge_a, 0), prof(edge_b, n - 1)
    std = np.c_[np.linspace(-CONN_W / 2, CONN_W / 2, LAT + 1), np.zeros(LAT + 1)]
    rows, widths = [], []
    TRANS = 14.0
    for i in range(n):
        fa = smoothstep(1 - dist[i] / TRANS)
        fb = smoothstep(1 - (L - dist[i]) / TRANS)
        pr = std * (1 - fa - fb) + pa * fa + pb * fb if fa + fb <= 1 else (pa if fa > fb else pb)
        rows.append(P[i] + np.outer(pr[:, 0], R[i]) + np.outer(pr[:, 1], U[i]))
        widths.append(pr[-1, 0] - pr[0, 0])
    polys = []
    blend = smoothstep(dist / L)
    for edge, row, i, flip in ((edge_a, rows[0], 0, False), (edge_b, rows[-1], n - 1, True)):
        A, B = (edge, row) if not flip else (row, edge)
        allp = np.concatenate([A, B])
        for (x, y, z) in zip_strip(A, B):
            tri = allp[[x, y, z]]
            uv = np.array([[2.0 * ((v - P[i]) @ R[i] + CONN_W / 2) / CONN_W, dist[i] / 5.0] for v in tri])
            q = Poly(tri, uv, conn_tex, "road", name, col=np.full(3, blend[i]))
            if q.normal() @ U[i] < 0:
                q.p = q.p[::-1]; q.uv = q.uv[::-1]
            polys.append(q)
    for i in range(n - 1):
        for j in range(LAT):
            quad = np.array([rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1]])
            uv = np.array([[2.0 * j / LAT, dist[i] / 5.0], [2.0 * j / LAT, dist[i + 1] / 5.0],
                           [2.0 * (j + 1) / LAT, dist[i + 1] / 5.0], [2.0 * (j + 1) / LAT, dist[i] / 5.0]])
            q = Poly(quad, uv, conn_tex, "road", name, col=np.array([blend[i], blend[i + 1], blend[i + 1], blend[i]]))
            if q.normal() @ U[i] < 0:
                q.p = q.p[::-1]; q.uv = q.uv[::-1]; q.col = q.col[::-1]
            polys.append(q)
    for i in range(n - 1):
        for side, j in ((-1, 0), (1, LAT)):
            a, b = rows[i][j], rows[i + 1][j]
            rail = np.array([a, b, b + U[i + 1] * RAIL_H, a + U[i] * RAIL_H])
            uv = np.array([[dist[i] / 4, 0], [dist[i + 1] / 4, 0], [dist[i + 1] / 4, 1], [dist[i] / 4, 1]])
            q = Poly(rail, uv, rail_tex, "wall", name)
            if q.normal() @ (-R[i] * side) < 0:
                q.p = q.p[::-1]; q.uv = q.uv[::-1]
            polys.append(q)
            polys.append(Poly(q.p[::-1].copy(), q.uv[::-1].copy(), rail_tex, "wall", name))
            if U[i][1] > 0.7 and U[i + 1][1] > 0.7:
                sk = np.array([a, a - np.array([0, 6.0, 0]), b - np.array([0, 6.0, 0]), b])
                q3 = Poly(sk, np.array([[0, 0], [0, 1.5], [1, 1.5], [1, 0]]), rail_tex, "deco", name)
                if q3.normal() @ (R[i] * side) < 0:
                    q3.p = q3.p[::-1]; q3.uv = q3.uv[::-1]
                polys.append(q3)
    return polys, np.array(widths), U


# ========================================================================== carving

class HeightCover:
    """Raster (0.5 m) of the lowest covering surface, grown into a 45 degree
    embankment, used to push host terrain below guest pieces and connectors."""
    def __init__(self, polys, margin=3.0, reach=16.0):
        import cv2
        allp = np.concatenate([p.p for p in polys])
        self.S = 2.0
        self.ox, self.oz = allp[:, 0].min() - reach - 5, allp[:, 2].min() - reach - 5
        W = int((allp[:, 0].max() - self.ox + reach + 5) * self.S)
        Hh = int((allp[:, 2].max() - self.oz + reach + 5) * self.S)
        H = np.full((Hh, W), np.inf, np.float32)
        for p in polys:
            pts = np.array([[(q[0] - self.ox) * self.S, (q[2] - self.oz) * self.S] for q in p.p])
            x0, y0 = np.floor(pts.min(0)).astype(int) - 1
            x1, y1 = np.ceil(pts.max(0)).astype(int) + 2
            m = np.zeros((y1 - y0, x1 - x0), np.uint8)
            cv2.fillPoly(m, [np.round(pts - [x0, y0]).astype(np.int32)], 1)
            sub = H[y0:y1, x0:x1]
            sub[m > 0] = np.minimum(sub[m > 0], p.p[:, 1].min())
        big = np.where(np.isinf(H), 1e6, H).astype(np.float32)
        k = int(reach * self.S) * 2 + 1
        near_h = cv2.erode(big, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
        mask = (big < 1e5).astype(np.uint8)
        outside = cv2.distanceTransform(1 - mask, cv2.DIST_L2, 5) / self.S
        allowed = near_h + np.maximum(0.0, outside - margin)
        allowed[outside > reach] = 1e6
        allowed[near_h > 1e5] = 1e6
        self.H = allowed

    def height(self, x, z):
        i, j = int((z - self.oz) * self.S), int((x - self.ox) * self.S)
        if 0 <= i < self.H.shape[0] and 0 <= j < self.H.shape[1] and self.H[i, j] < 1e5:
            return float(self.H[i, j])
        return None

    def touches(self, p):
        lo = p.p.min(0); hi = p.p.max(0)
        i0, j0 = max(int((lo[2] - self.oz) * self.S), 0), max(int((lo[0] - self.ox) * self.S), 0)
        i1, j1 = int((hi[2] - self.oz) * self.S) + 1, int((hi[0] - self.ox) * self.S) + 1
        i1, j1 = min(i1, self.H.shape[0]), min(j1, self.H.shape[1])
        if i1 <= i0 or j1 <= j0:
            return False      # entirely outside the raster (negative slices would wrap)
        return bool((self.H[i0:i1, j0:j1] < 1e5).any())


def subdivide(p, max_edge):
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


def carve(host_polys, cover_polys):
    """Push the host's terrain below the cover (never delete ground; drop only
    walls/props standing in the way)."""
    if not cover_polys:
        return host_polys, 0, 0
    H = HeightCover(cover_polys)
    kept, dropped, carved = [], 0, 0
    for p in host_polys:
        if p.cls == "road" or not H.touches(p):
            kept.append(p)
            continue
        if p.cls in ("wall", "deco"):
            if abs(p.normal()[1]) < 0.6:
                dropped += 1
                continue
            p.cls = "off"
        for q in subdivide(p, 3.0):
            for k in range(len(q.p)):
                h = H.height(q.p[k][0], q.p[k][2])
                if h is not None and q.p[k][1] > h - 0.5:
                    q.p[k][1] = h - 0.5
            kept.append(q)
            carved += 1
    return kept, dropped, carved


# ========================================================================== bake

def quad_up(P, uv, tex, cls, src):
    q = Poly(np.array(P, float), np.array(uv, float), tex, cls, src)
    if q.normal()[1] < 0:
        q.p = q.p[::-1]; q.uv = q.uv[::-1]
    return q


def bake(map_id):
    mpath = os.path.join(CONTENT, "maps", map_id + ".json")
    mdef = jload(mpath)
    lay = mdef["layout"]
    out_dir = os.path.join(ROOT, "assets", "maps", map_id)
    os.makedirs(os.path.join(out_dir, "tex"), exist_ok=True)

    segs = [Segment(c, i).build() for i, c in enumerate(lay["segments"])]
    nseg = len(segs)
    if nseg == 1 and not segs[0].closed:
        raise SystemExit("a single segment must be the full track (\"full\": true)")
    if nseg > 1 and any(s.closed for s in segs):
        raise SystemExit("a full-loop segment can only be used on its own")

    # Placement: yaw + offset; "auto" height matches the next segment's start.
    offsets = []
    for s in segs:
        o = s.cfg.get("offset", [0, 0, 0])
        offsets.append([float(o[0]), o[1], float(o[2])])
    for i, s in enumerate(segs):
        yaw = float(s.cfg.get("yaw", 0.0))
        oy = offsets[i][1]
        s.transform(yaw, np.array([offsets[i][0], 0.0 if oy == "auto" else float(oy), offsets[i][2]]))
    for i, s in enumerate(segs):
        if offsets[i][1] == "auto" and nseg > 1:
            nxt = segs[(i + 1) % nseg]
            dy = nxt.edge_s[:, 1].mean() - s.edge_e[:, 1].mean()
            s.transform(0.0, np.array([0.0, dy, 0.0]))
            s.xf = (float(s.cfg.get("yaw", 0.0)), np.array([offsets[i][0], dy, offsets[i][2]]))

    # Connectors
    conns = []
    ccfg = lay.get("connectors", [])
    textures = {}
    if nseg > 1:
        for i, s in enumerate(segs):
            nxt = segs[(i + 1) % nseg]
            cc = ccfg[i] if i < len(ccfg) else {}
            key = f"conn{i}"
            textures[key] = {"a": s.src.road_tex, "b": nxt.src.road_tex,
                             "rect_a": s.src.cfg.get("road_rect"), "rect_b": nxt.src.cfg.get("road_rect")}
            P, UPV, mask = connector_path(s.edge_e.mean(0), s.t_end(), nxt.edge_s.mean(0), nxt.t_start(),
                                          loop=bool(cc.get("loop", False)), loop_at=float(cc.get("loop_at", 0.3)))
            polys, widths, U = loft_connector(P, UPV, s.edge_e, nxt.edge_s, key, segs[0].src.rail_tex, key)
            conns.append({"P": P, "U": U, "w": widths, "loop": mask, "polys": polys})
            print(f"connector {i}: {len(P) * 0.5:.0f} m{' with loop' if cc.get('loop') else ''}")

    # Carve hosts ("all" scenery) under everything else.
    conn_polys = [p for c in conns for p in c["polys"] if p.cls != "deco"]
    for s in segs:
        if s.scenery != "all":
            continue
        cover = [p for o in segs if o is not s for p in o.polys] + conn_polys
        s.polys, dropped, carved = carve(s.polys, cover)
        if cover:
            print(f"segment {s.index} ({s.src.id}): {dropped} walls/props removed, ground carved into {carved} polys")

    polys = [p for s in segs for p in s.polys] + [p for c in conns for p in c["polys"]]
    # Very large collision triangles cause physics precision trouble: split them.
    split = []
    for p in polys:
        if p.cls != "deco" and np.ptp(p.p, axis=0).max() > 60.0:
            split += subdivide(p, 40.0)
        else:
            split.append(p)
    polys = split

    # Ground layer under guest ("near") pieces + connectors, below their lowest point.
    hosts = [s for s in segs if s.scenery == "all"]
    guests = [s for s in segs if s.scenery != "all"]
    if lay.get("ground", True) and guests and nseg > 1:
        gp = np.concatenate([p.p for s in guests for p in s.polys])
        gy = gp[:, 1].min() - 1.0
        x0, z0 = gp[:, 0].min() - 15, gp[:, 2].min() - 15
        x1, z1 = gp[:, 0].max() + 15, gp[:, 2].max() + 15
        gtex = (hosts[0] if hosts else segs[0]).src.grass_tex
        polys += subdivide(quad_up([[x0, gy, z0], [x0, gy, z1], [x1, gy, z1], [x1, gy, z0]],
                                   [[x0 / 8, z0 / 8], [x0 / 8, z1 / 8], [x1 / 8, z1 / 8], [x1 / 8, z0 / 8]], gtex, "off", "ground"), 40.0)

    # Centreline in travel order: segment, connector, segment, connector, ...
    seq = []
    sections = []
    for i, s in enumerate(segs):
        a = len(seq)
        for k in range(len(s.cl)):
            seq.append((s.cl[k], np.array([0, 1.0, 0]), float(s.w[k]), 0))
        sections.append({"name": s.src.cfg.get("name", s.src.id), "from": a, "to": len(seq) - 1})
        if i < len(conns):
            c = conns[i]
            for k in range(2, len(c["P"]) - 2, 4):
                seq.append((c["P"][k], c["U"][k], float(c["w"][k]), 4 if c["loop"][k] else 0))
    st = lay.get("start", {})
    sseg = segs[int(st.get("segment", 0))]
    at = st.get("at")
    s_world = sseg.to_world_xz(at) if at is not None else sseg.cl[0][[0, 2]].tolist()
    pts_seq = np.array([q[0] for q in seq])
    s_idx = nearest(pts_seq, s_world)
    seq = seq[s_idx:] + seq[:s_idx]
    for sec in sections:
        sec["from"] = (sec["from"] - s_idx) % len(seq)
        sec["to"] = (sec["to"] - s_idx) % len(seq)
    P_all = np.array([q[0] for q in seq])
    seglen = np.linalg.norm(np.roll(P_all, -1, 0) - P_all, axis=1)
    dist = np.concatenate([[0], np.cumsum(seglen)[:-1]])
    total = float(seglen.sum())

    forks = []
    for s in segs:
        for bcl, ai, name in s.branches:
            forks.append({"name": name, "ai": ai, "points": [q.round(3).tolist() for q in bcl],
                          "join_from": nearest(P_all, bcl[0][[0, 2]]), "join_to": nearest(P_all, bcl[-1][[0, 2]])})

    def in_fork(i):
        return any(f["join_from"] <= i <= f["join_to"] for f in forks)
    ncp = int(lay.get("checkpoints", 10))
    cps = []
    for c in range(ncp):
        i = int(np.argmin(np.abs(dist - total * c / ncp)))
        guard = 0
        while (in_fork(i) or (seq[i][3] & 4)) and guard < len(seq):
            i = (i + 1) % len(seq)
            guard += 1
        cps.append(i)

    road_all = [p for p in polys if p.cls == "road"]
    floor_all = [p for p in polys if p.cls in ("road", "off") and abs(p.normal()[1]) > 0.6]
    t0 = flat(P_all[1] - P_all[0])
    r0 = np.cross(t0, [0, 1.0, 0])
    # Starting grid: follow the centreline backwards (it may curve behind the line),
    # two columns, 6 m between rows, on top of the real road surface.
    grid = []
    cum_back = np.concatenate([[0], np.cumsum(seglen[::-1])])     # distance behind sample 0
    for k in range(8):
        row, col = divmod(k, 2)
        back = 6.0 + row * 6.0
        j = int(np.searchsorted(cum_back, back))
        i = (len(seq) - j) % len(seq)
        ti = flat(P_all[(i + 1) % len(seq)] - P_all[i - 1])
        ri = np.cross(ti, [0, 1.0, 0])
        half = min(2.5, seq[i][2] * 0.25)
        g = P_all[i] + ri * (-half if col == 0 else half)
        h = _floor_near(floor_all, g, P_all[i][1])
        if h is None:                 # no floor there (narrow road): line up on the centre
            g = P_all[i] - ti * (3.0 if col == 1 else 0.0)
            h = _floor_near(floor_all, g, P_all[i][1])
        g[1] = (h if h is not None else P_all[i][1]) + 0.3
        grid.append({"pos": g.round(3).tolist(), "fwd": ti.round(4).tolist()})

    # start / finish stripe
    hw = seq[0][2] * 0.5
    s0 = P_all[0] + np.array([0, 0.04, 0])
    polys.append(quad_up([s0 - r0 * hw - t0 * 1.5, s0 + r0 * hw - t0 * 1.5, s0 + r0 * hw + t0 * 1.5, s0 - r0 * hw + t0 * 1.5],
                         [[0, 0.12], [1, 0.12], [1, 0.30], [0, 0.30]],
                         segs[0].src.tex_key(segs[0].src.cfg.get("start_texture", "")) or sseg.src.road_tex, "deco", "start"))

    allp = np.concatenate([p.p for p in polys])
    data = {
        "name": mdef.get("name", map_id),
        "length": round(total, 2),
        "centreline": [{"p": q[0].round(3).tolist(), "up": np.round(q[1], 4).tolist(), "w": round(q[2], 2), "f": int(q[3])} for q in seq],
        "forks": forks,
        "checkpoints": cps,
        "grid": grid,
        "kill_y": round(float(allp[:, 1].min()) - 20.0, 2),
        "sections": sections,
        "connectors": textures,
    }
    if forks:
        data["fork"] = forks[0]
    export(polys, data, out_dir, segs)
    preview(polys, P_all, os.path.join(out_dir, "preview.png"))
    debug_plot(polys, P_all, cps, forks, os.path.join(ROOT, "out", f"{map_id}_top.png"))
    mdef["length"] = round(total)
    mdef["data"] = f"res://assets/maps/{map_id}/track.json"
    mdef["preview"] = f"res://assets/maps/{map_id}/preview.png"
    with open(mpath, "w") as f:
        json.dump(mdef, f, indent="\t")
    print(f"{map_id}: lap {total:.0f} m, {len(seq)} samples, {len(forks)} alternate route(s), checkpoints {cps}")


def export(polys, data, out_dir, segs):
    groups = {}
    for p in polys:
        groups.setdefault((p.tex, p.cls, bool(p.alpha)), []).append(p)
    floats, ints, surfaces = [], [], []
    foff = ioff = 0
    for (tex, cls, alpha), ps in sorted(groups.items()):
        pos, nrm, uv, col, idx = [], [], [], [], []
        base = 0
        for p in ps:
            k = len(p.p)
            pos.append(p.p); nrm.append(np.tile(p.normal(), (k, 1)))
            u = p.uv.copy(); u[:, 1] = 1.0 - u[:, 1]
            uv.append(u)
            col.append(p.col if p.col is not None else np.zeros(k))
            for t in range(1, k - 1):
                idx += [base, base + t + 1, base + t]
            base += k
        pos = np.concatenate(pos).astype(np.float32); nrm = np.concatenate(nrm).astype(np.float32)
        uv = np.concatenate(uv).astype(np.float32); col = np.concatenate(col).astype(np.float32)
        idx = np.array(idx, np.int32)
        nv = len(pos)
        surfaces.append({"texture": tex, "class": cls, "alpha": alpha, "vertices": nv, "indices": len(idx),
                         "pos": foff, "nrm": foff + nv * 3, "uv": foff + nv * 6, "col": foff + nv * 8, "idx": ioff})
        floats += [pos.reshape(-1), nrm.reshape(-1), uv.reshape(-1), col]
        foff += nv * 9
        ints.append(idx)
        ioff += len(idx)
    fbuf = np.concatenate(floats).astype("<f4").tobytes()
    ibuf = np.concatenate(ints).astype("<i4").tobytes()
    with open(os.path.join(out_dir, "track.bin"), "wb") as f:
        f.write(fbuf); f.write(ibuf)
    data.update({"surfaces": surfaces, "float_count": foff, "int_offset_bytes": len(fbuf), "int_count": ioff})
    with open(os.path.join(out_dir, "track.json"), "w") as f:
        json.dump(data, f, separators=(",", ":"))
    # textures: every key "<source>__<file>"
    keys = {s["texture"] for s in surfaces}
    for c in data["connectors"].values():
        keys |= {c["a"], c["b"]}
    for k in keys:
        if "__" not in k:
            continue
        src = Source.get(k.split("__", 1)[0])
        f = src.tex_file(k)
        if f:
            shutil.copyfile(f, os.path.join(out_dir, "tex", k))
    print(f"exported {len(surfaces)} surfaces, {ioff // 3} triangles -> {os.path.relpath(out_dir, ROOT)}")


def preview(polys, P_all, path):
    """Menu thumbnail (448 x 232): terrain, road, start."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    fig = plt.figure(figsize=(4.48, 2.32), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_facecolor("#1d2a6b")
    order = {"off": 0, "wall": 1, "road": 2}
    ps = sorted([p for p in polys if p.cls in order], key=lambda p: (order[p.cls], p.centroid()[1]))
    colour = {"off": "#4f9a3a", "wall": "#b04030", "road": "#8a8a8a"}
    ax.add_collection(PolyCollection([p.p[:, [0, 2]] for p in ps], facecolors=[colour[p.cls] for p in ps], edgecolors="none", linewidths=0, antialiaseds=False))
    ax.plot(P_all[:, 0], P_all[:, 2], color="#ffd23f", lw=1.2)
    ax.plot(P_all[0, 0], P_all[0, 2], marker="*", color="white", ms=12, mec="black")
    lo, hi = P_all.min(0) - 25, P_all.max(0) + 25
    cx, cz = (lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2
    span = max((hi[0] - lo[0]) / 448, (hi[2] - lo[2]) / 232)
    ax.set_xlim(cx - span * 224, cx + span * 224)
    ax.set_ylim(cz + span * 116, cz - span * 116)
    ax.set_xticks([]); ax.set_yticks([])
    fig.savefig(path, facecolor="#1d2a6b")
    plt.close(fig)


def debug_plot(polys, P_all, cps, forks, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    os.makedirs(os.path.dirname(path), exist_ok=True)
    col = {"road": "#555555", "off": "#7cba5a", "wall": "#c0392b", "deco": "#e0c070"}
    fig, ax = plt.subplots(figsize=(14, 11))
    order = {"off": 0, "deco": 1, "wall": 2, "road": 3}
    ps = sorted(polys, key=lambda p: (order.get(p.cls, 0), p.centroid()[1]))
    ax.add_collection(PolyCollection([p.p[:, [0, 2]] for p in ps],
                                     facecolors=[("#3b6fb6" if p.src.startswith("conn") and p.cls == "road" else col.get(p.cls, "#999")) for p in ps],
                                     edgecolors="none"))
    ax.plot(P_all[:, 0], P_all[:, 2], "y-", lw=1)
    for f in forks:
        fp = np.array(f["points"])
        ax.plot(fp[:, 0], fp[:, 2], "m-", lw=1)
    for k, i in enumerate(cps):
        ax.plot(P_all[i, 0], P_all[i, 2], "ko", ms=5)
        ax.text(P_all[i, 0] + 3, P_all[i, 2] + 3, f"CP{k}", fontsize=8, weight="bold")
    ax.plot(P_all[0, 0], P_all[0, 2], "w*", ms=16, mec="k")
    ax.set_aspect("equal"); ax.autoscale(); ax.invert_yaxis()
    plt.savefig(path, dpi=60)
    plt.close(fig)


# ========================================================================== analyze

def analyze(sid):
    """Data the Map Combiner dock draws: centreline / pieces / branches, in the
    source's own space (metres)."""
    src = Source.get(sid)
    out = {"id": sid, "name": src.cfg.get("name", sid), "method": src.cfg["centreline"]["method"]}
    if out["method"] == "road_skeleton":
        cl, w = src.skeleton_centreline()
        out["centreline"] = cl[::2].round(2).tolist()
        out["widths"] = w[::2].round(2).tolist()
        out["closed"] = True
    else:
        lo, hi = src.cfg["centreline"]["main"]
        keys, cen = src.piece_centres(lo, hi)
        out["pieces"] = [[k] + c.round(2).tolist() for k, c in zip(keys, cen)]
        out["branches"] = []
        for b in src.cfg.get("branches", []):
            bk, bc = src.piece_centres(b["groups"][0], b["groups"][1])
            out["branches"].append({"name": b.get("name"), "groups": b["groups"],
                                    "pieces": [[k] + c.round(2).tolist() for k, c in zip(bk, bc)]})
    road = np.concatenate([p.p for p in src.polys if p.cls == "road"])
    out["bounds"] = [road.min(0).round(1).tolist(), road.max(0).round(1).tolist()]
    path = os.path.join(CONTENT, "track_sources", sid + ".analysis.json")
    with open(path, "w") as f:
        json.dump(out, f)
    print(f"wrote {os.path.relpath(path, ROOT)}")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("bake", "analyze", "list"):
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == "list":
        for d in ("track_sources", "maps"):
            print(d + ":", sorted(f[:-5] for f in os.listdir(os.path.join(CONTENT, d)) if f.endswith(".json") and "analysis" not in f))
    elif sys.argv[1] == "analyze":
        for sid in sys.argv[2:]:
            analyze(sid)
    else:
        for mid in sys.argv[2:]:
            bake(mid)
