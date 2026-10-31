@tool
class_name RigIcon
extends RefCounted
## Renders a character's face from its vertex rig as a small thumbnail - no viewport,
## no camera, no screenshot: the head part's own triangles are projected front-on and
## filled with their texture, so it works headless (importers, tests) and matches the
## model exactly.
##
## The rig faces -Z (the importers normalise that), so the camera sits in front at -Z
## and vertices with the smallest z are nearest.

const BG := Color(0, 0, 0, 0)


## A face thumbnail of `rig` (a rig dictionary). `images` maps a rig texture path to
## an Image; pass {} to load them from disk.
static func render(rig: Dictionary, size: int = 32, images: Dictionary = {}) -> Image:
	if images.is_empty():
		images = texture_images(rig)
	var out := Image.create(size, size, false, Image.FORMAT_RGBA8)
	out.fill(BG)
	var parts: Array = rig.get("parts", [])
	if parts.is_empty():
		return out
	var head := -1
	for i in parts.size():
		if String(parts[i].get("name", "")) == "head":
			head = i
			break
	# Gather the head's triangles (or the top of the model when it has no head part).
	var all_lo := Vector3(INF, INF, INF)
	var all_hi := -all_lo
	for s in rig.get("surfaces", []):
		var pos: Array = s.get("pos", [])
		for i in range(0, pos.size() - 2, 3):
			var p := Vector3(pos[i], pos[i + 1], pos[i + 2])
			all_lo = all_lo.min(p)
			all_hi = all_hi.max(p)
	if all_lo.x > all_hi.x:
		return out
	var top := all_hi.y - maxf((all_hi.y - all_lo.y) * 0.3, 1e-3)
	var tris: Array = []          # {p: PackedVector3Array, uv: PackedVector2Array, img: Image}
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for s in rig.get("surfaces", []):
		var pos: Array = s.get("pos", [])
		var uv: Array = s.get("uv", [])
		var idx: Array = s.get("idx", [])
		var pa: Array = s.get("pa", [])
		var img: Image = images.get(String(s.get("texture", "")), null)
		for t in range(0, idx.size() - 2, 3):
			var keep := false
			for k in 3:
				var vi: int = idx[t + k]
				if head >= 0:
					if vi < pa.size() and int(pa[vi]) == head:
						keep = true
				elif vi * 3 + 1 < pos.size() and float(pos[vi * 3 + 1]) >= top:
					keep = true
			if not keep:
				continue
			var p := PackedVector3Array()
			var u := PackedVector2Array()
			for k in 3:
				var vi2: int = idx[t + k]
				var q := Vector3(float(pos[vi2 * 3]), float(pos[vi2 * 3 + 1]), float(pos[vi2 * 3 + 2]))
				p.append(q)
				u.append(Vector2(float(uv[vi2 * 2]), float(uv[vi2 * 2 + 1])) if vi2 * 2 + 1 < uv.size() else Vector2.ZERO)
				lo = lo.min(q)
				hi = hi.max(q)
			tris.append({"p": p, "uv": u, "img": img})
	if tris.is_empty() or lo.x > hi.x:
		return out
	# Frame it: a square around the head, with a little air.
	var side := maxf(maxf(hi.x - lo.x, hi.y - lo.y) * 1.12, 0.02)
	var cx := (lo.x + hi.x) * 0.5
	var cy := (lo.y + hi.y) * 0.5
	var depth := PackedFloat32Array()
	depth.resize(size * size)
	depth.fill(INF)
	for tri in tris:
		_draw_tri(out, depth, tri, size, cx, cy, side)
	return out


static func _draw_tri(img: Image, depth: PackedFloat32Array, tri: Dictionary, size: int,
		cx: float, cy: float, side: float) -> void:
	var p: PackedVector3Array = tri["p"]
	var u: PackedVector2Array = tri["uv"]
	var tex: Image = tri["img"]
	var sx := PackedFloat32Array()
	var sy := PackedFloat32Array()
	for k in 3:
		sx.append((p[k].x - cx) / side * size + size * 0.5)
		sy.append(size * 0.5 - (p[k].y - cy) / side * size)
	var x0 := int(floor(minf(sx[0], minf(sx[1], sx[2]))))
	var x1 := int(ceil(maxf(sx[0], maxf(sx[1], sx[2]))))
	var y0 := int(floor(minf(sy[0], minf(sy[1], sy[2]))))
	var y1 := int(ceil(maxf(sy[0], maxf(sy[1], sy[2]))))
	var den := (sy[1] - sy[2]) * (sx[0] - sx[2]) + (sx[2] - sx[1]) * (sy[0] - sy[2])
	if absf(den) < 1e-9:
		return
	var tw := 4
	var th := 4
	if tex != null:
		tw = tex.get_width()
		th = tex.get_height()
	for y in range(maxi(y0, 0), mini(y1, size - 1) + 1):
		for x in range(maxi(x0, 0), mini(x1, size - 1) + 1):
			var px := x + 0.5
			var py := y + 0.5
			var w0 := ((sy[1] - sy[2]) * (px - sx[2]) + (sx[2] - sx[1]) * (py - sy[2])) / den
			var w1 := ((sy[2] - sy[0]) * (px - sx[2]) + (sx[0] - sx[2]) * (py - sy[2])) / den
			var w2 := 1.0 - w0 - w1
			if w0 < 0.0 or w1 < 0.0 or w2 < 0.0:
				continue
			var z := p[0].z * w0 + p[1].z * w1 + p[2].z * w2
			if z >= depth[y * size + x]:
				continue
			var uvx := u[0].x * w0 + u[1].x * w1 + u[2].x * w2
			var uvy := u[0].y * w0 + u[1].y * w1 + u[2].y * w2
			var col := Color.MAGENTA
			if tex != null:
				var tx := clampi(int(fposmod(uvx, 1.0) * tw), 0, tw - 1)
				var ty := clampi(int(fposmod(uvy, 1.0) * th), 0, th - 1)
				col = tex.get_pixel(tx, ty)
			if col.a < 0.5:
				continue
			depth[y * size + x] = z
			img.set_pixel(x, y, Color(col.r, col.g, col.b, 1.0))


## Every texture a rig uses, path -> Image (missing files become magenta).
static func texture_images(rig: Dictionary) -> Dictionary:
	var out := {}
	for s in rig.get("surfaces", []):
		var t := String(s.get("texture", ""))
		if t == "" or out.has(t):
			continue
		var img := load_image(t)
		if img == null:
			img = Image.create(4, 4, false, Image.FORMAT_RGBA8)
			img.fill(Color.MAGENTA)
		out[t] = img
	return out


static func load_image(path: String) -> Image:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null and ResourceLoader.exists(path):
		var t: Texture2D = load(path)
		if t:
			img = t.get_image()
	if img and img.is_compressed():
		img.decompress()
	if img:
		img.convert(Image.FORMAT_RGBA8)
	return img
