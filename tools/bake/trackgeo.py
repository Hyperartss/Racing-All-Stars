"""Geometry helpers for the track bake (polygons, clipping, centrelines, lofting)."""
import numpy as np


class Poly:
    """One polygon. Internal convention: counter-clockwise seen from its front,
    OBJ-style UVs (v up). Converted to Godot conventions only at export."""
    __slots__ = ("p", "uv", "tex", "cls", "src", "alpha", "col")

    def __init__(self, p, uv, tex, cls, src="", alpha=False, col=None):
        self.p = np.asarray(p, float)
        self.uv = np.asarray(uv, float)
        self.tex = tex
        self.cls = cls          # road | off | wall | deco | conn
        self.src = src
        self.alpha = alpha
        self.col = col          # optional per-vertex blend weight (connectors)

    def normal(self):
        n = np.zeros(3)
        P = self.p
        for i in range(len(P)):
            a, b = P[i], P[(i + 1) % len(P)]
            n += np.cross(a, b)
        l = np.linalg.norm(n)
        return n / l if l > 1e-12 else np.array([0, 1.0, 0])

    def centroid(self):
        return self.p.mean(0)


def read_obj(path, mtl_path=None):
    V, VT = [], []
    polys = []
    mat = grp = None
    for line in open(path, errors="ignore"):
        t = line.split()
        if not t:
            continue
        if t[0] == "v":
            V.append([float(x) for x in t[1:4]])
        elif t[0] == "vt":
            VT.append([float(x) for x in t[1:3]])
        elif t[0] == "usemtl":
            mat = t[1]
        elif t[0] in ("g", "o"):
            grp = " ".join(t[1:])
        elif t[0] == "f":
            vi, ti = [], []
            for c in t[1:]:
                a = c.split("/")
                vi.append(int(a[0]) - 1)
                ti.append(int(a[1]) - 1 if len(a) > 1 and a[1] else -1)
            polys.append((mat, grp, vi, ti))
    mtl = {}
    if mtl_path:
        cur = None
        for line in open(mtl_path, errors="ignore"):
            t = line.split()
            if not t:
                continue
            if t[0] == "newmtl":
                cur = t[1]
                mtl[cur] = {}
            elif t[0] == "map_Kd":
                mtl[cur]["tex"] = " ".join(t[1:])
            elif t[0] == "map_d":
                mtl[cur]["alpha"] = " ".join(t[1:])
    return np.array(V), np.array(VT) if VT else np.zeros((1, 2)), polys, mtl


def clip_poly(P, UV, n, d):
    """Keep the part of polygon where dot(n, p) >= d. Returns (P, UV) or None."""
    out_p, out_uv = [], []
    k = len(P)
    s = P @ n - d
    for i in range(k):
        j = (i + 1) % k
        a, b = s[i], s[j]
        if a >= 0:
            out_p.append(P[i]); out_uv.append(UV[i])
        if (a >= 0) != (b >= 0):
            t = a / (a - b)
            out_p.append(P[i] + (P[j] - P[i]) * t)
            out_uv.append(UV[i] + (UV[j] - UV[i]) * t)
    if len(out_p) < 3:
        return None
    return np.array(out_p), np.array(out_uv)


def resample_closed(pts, spacing):
    pts = np.asarray(pts, float)
    seg = np.linalg.norm(np.roll(pts, -1, 0) - pts, axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)])
    total = cum[-1]
    n = max(4, int(round(total / spacing)))
    out = []
    for k in range(n):
        t = k * total / n
        i = np.searchsorted(cum, t, side="right") - 1
        i = min(i, len(pts) - 1)
        f = (t - cum[i]) / max(seg[i], 1e-9)
        out.append(pts[i] + (pts[(i + 1) % len(pts)] - pts[i]) * f)
    return np.array(out)


def resample_open(pts, spacing):
    pts = np.asarray(pts, float)
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)])
    total = cum[-1]
    n = max(2, int(round(total / spacing)) + 1)
    out = []
    for k in range(n):
        t = k * total / (n - 1)
        i = min(np.searchsorted(cum, t, side="right") - 1, len(pts) - 2)
        f = (t - cum[i]) / max(seg[i], 1e-9)
        out.append(pts[i] + (pts[i + 1] - pts[i]) * f)
    return np.array(out)


def smooth_closed(pts, passes=3):
    pts = np.asarray(pts, float).copy()
    for _ in range(passes):
        pts = (np.roll(pts, 1, 0) + 2 * pts + np.roll(pts, -1, 0)) / 4
    return pts


def smooth_open(pts, passes=3):
    pts = np.asarray(pts, float).copy()
    for _ in range(passes):
        q = pts.copy()
        q[1:-1] = (pts[:-2] + 2 * pts[1:-1] + pts[2:]) / 4
        pts = q
    return pts


def hermite(p0, t0, p1, t1, n):
    s = np.linspace(0, 1, n)[:, None]
    h00 = 2 * s**3 - 3 * s**2 + 1
    h10 = s**3 - 2 * s**2 + s
    h01 = -2 * s**3 + 3 * s**2
    h11 = s**3 - s**2
    return h00 * p0 + h10 * t0 + h01 * p1 + h11 * t1


def rot_y(p, deg):
    a = np.radians(deg)
    c, s = np.cos(a), np.sin(a)
    p = np.asarray(p, float)
    return np.stack([p[..., 0] * c + p[..., 2] * s, p[..., 1], -p[..., 0] * s + p[..., 2] * c], axis=-1)


def zip_strip(A, B):
    """Triangulate between two polylines (both ordered left->right, any counts) by
    walking their normalised arc-length parameters. Every vertex of both rows is used,
    so the strip is watertight against whatever geometry owns either row.
    Returns list of index triples into concat(A, B)."""
    def params(P):
        d = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
        return d / max(d[-1], 1e-9)
    ua, ub = params(A), params(B)
    i = j = 0
    na, nb = len(A), len(B)
    tris = []
    while i < na - 1 or j < nb - 1:
        if j >= nb - 1 or (i < na - 1 and ua[i + 1] <= ub[j + 1]):
            tris.append((i, i + 1, na + j)); i += 1
        else:
            tris.append((i, na + j + 1, na + j)); j += 1
    return tris
