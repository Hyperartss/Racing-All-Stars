@tool
class_name KartImporter
extends RefCounted
## Turns an imported vehicle model (OBJ / glTF / DAE / FBX - anything Godot imports)
## into a kart rig + a kart definition.
##
## A kart only needs two kinds of part: the body, which leans and hops around the
## rig origin, and its four wheels, which KartVisual spins by their own radius and
## steers at the front. So instead of the character importer's biped split this
## finds the four wheel lumps in the model, measures each one and makes everything
## else the body.
##
## 1. load_source()  - mesh surfaces in source space (same loader as the Character Importer)
## 2. analyse()      - face -Z, scale so the kart is `length` metres long, sit it on the
##                     ground, then find and measure the wheels
## 3. build_rig()    - rig dictionary (format of assets/rigs/*.json) with parts
##                     body + wheel_fl/fr/bl/br; wheel centres and radii go in meta
## 4. detect_paint() - a "Body" colour-swap zone and a "Wheels" tint zone
## 5. export()       - assets/rigs/kart_<id>.json, its textures and content/karts/<id>.json

const WHEELS := ["wheel_fl", "wheel_fr", "wheel_bl", "wheel_br"]
const SPLITS := ["auto", "nodes", "surfaces"]
const PALETTE := ["#c00000", "#2050e0", "#20b040", "#e0c020", "#f0f0f0", "#202020", "#e060c0", "#30d0d0"]

## Raw mesh pieces in source space (CharacterImporter chunk format):
## {node, surface, origin, pos, nrm, uv, idx, tex, colour, alpha_tex}
var chunks: Array[Dictionary] = []
var source_path := ""
var id := ""
var display_name := ""
var facing := "+Z"
var length := 1.4                 ## metres front to back (scale reference)
var split := "auto"

var scale := 1.0
var norm := Transform3D.IDENTITY  ## source -> rig space
var notes := PackedStringArray()
var wheels := {}                  ## part name -> {"centre": Vector3, "radius": float}
var size := Vector3.ZERO          ## rig-space extent (width, height, length)

# per chunk after analyse(): normalised positions and the part of every vertex
var _npos: Array[PackedVector3Array] = []
var _nnrm: Array[PackedVector3Array] = []
var _vpart: Array[PackedStringArray] = []
var _alpha_cache := {}

# connected pieces of the current analyse() (vertex ids + union-find)
var _uf := {}
var _tri_ids: Array[PackedInt32Array] = []
var _vert_src: Array[Vector2i] = []          ## vertex id -> (chunk, vertex index)
var _comp_tris := {}                         ## root -> Array[int] triangle numbers


# ------------------------------------------------------------------ load

func load_source(path: String) -> String:
	source_path = path
	chunks.clear()
	wheels.clear()
	var ci := CharacterImporter.new()
	var err := ci.load_source(path)
	if err != "":
		return err
	chunks = ci.chunks
	if id == "":
		id = ci.id
	if display_name == "":
		display_name = ci.display_name
	return ""


# ------------------------------------------------------------------ analyse

func analyse() -> void:
	notes.clear()
	wheels.clear()
	# 1. turn the model to face -Z, scale it to `length` and stand it on the ground
	var rot := Basis(Vector3.UP, deg_to_rad(float(CharacterImporter.FACINGS.get(facing, 0.0))))
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for c in chunks:
		for p in c.pos:
			var q: Vector3 = rot * p
			lo = lo.min(q)
			hi = hi.max(q)
	var span := hi - lo
	scale = length / maxf(span.z, 1e-6)
	var centre := Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
	norm = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale), -centre * scale) * Transform3D(rot, Vector3.ZERO)
	_npos.clear()
	_nnrm.clear()
	for c in chunks:
		var np := PackedVector3Array()
		np.resize(c.pos.size())
		var nn := PackedVector3Array()
		nn.resize(c.pos.size())
		for i in np.size():
			np[i] = norm * c.pos[i]
			nn[i] = (rot * c.nrm[i]).normalized()
		_npos.append(np)
		_nnrm.append(nn)
	size = Vector3(span.x * scale, span.y * scale, span.z * scale)
	# 2. body + wheels
	_assign_parts()
	if wheels.is_empty():
		notes.append("No four wheels found - the whole model is one part. Split by nodes "
			+ "(one mesh node per wheel) or by surfaces if the wheels use their own material.")
	for w in WHEELS:
		if not wheels.has(w):
			notes.append("%s is missing: that corner will not turn." % w)


## Splits the model into body + four wheels: by node / surface names, or by finding
## the four compact lumps that touch the ground near the corners.
func _assign_parts() -> void:
	_vpart.clear()
	for ci in chunks.size():
		var roles := PackedStringArray()
		roles.resize(chunks[ci].pos.size())
		roles.fill("body")
		_vpart.append(roles)
	if split == "nodes" or split == "surfaces":
		# The names say which geometry is a wheel; the lumps inside it say which one.
		var named := _wheel_candidates(true, false)
		if named.size() >= 4:
			_take_quadrants(named)
			return
		_named_parts()
		if wheels.is_empty():                 # no name matched: fall back to the shape
			var shape := _wheel_candidates(false, true)
			if shape.size() >= 4:
				_take_quadrants(shape)
				notes.append("No wheel names matched - the wheels were found by shape instead.")
		return
	var cands := _wheel_candidates(false, true)
	if cands.size() >= 4:
		_take_quadrants(cands)
		return
	# A welded body hides the wheels in one piece: look inside the tire material only.
	var tyre := _wheel_candidates(true, false)
	if tyre.size() >= 4:
		_take_quadrants(tyre)
		notes.append("Wheels found by material name, not by shape - check the split.")
		return
	notes.append("Wheel lumps could not be separated (the model may be one welded piece).")


## Parts from the mesh node / surface names: anything wheel-ish becomes a wheel,
## the corner decides which one.
func _named_parts() -> void:
	for ci in chunks.size():
		var c: Dictionary = chunks[ci]
		var key := String(c.node) if split == "nodes" else String(c.surface)
		var s := (String(key) + " " + String(c.tex).get_file()).to_lower()
		if not (s.contains("wheel") or s.contains("tire") or s.contains("tyre")):
			continue
		# Centre of the piece decides the corner.
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for p in _npos[ci]:
			lo = lo.min(p)
			hi = hi.max(p)
		var cen := (lo + hi) * 0.5
		var name := "wheel_" + ("f" if cen.z < 0.0 else "b") + ("l" if cen.x < 0.0 else "r")
		_vpart[ci].fill(name)
		# Merge all pieces of the same wheel (a tire + a hub can be separate meshes).
		if not wheels.has(name):
			wheels[name] = {"centre": cen, "radius": (hi.y - lo.y) * 0.5, "min": lo, "max": hi}
		else:
			var w: Dictionary = wheels[name]
			var wlo: Vector3 = w["min"].min(lo)
			var whi: Vector3 = w["max"].max(hi)
			w["min"] = wlo
			w["max"] = whi
			w["centre"] = (wlo + whi) * 0.5
			w["radius"] = (whi.y - wlo.y) * 0.5


## Connected lumps, with their bounding boxes. `only_tyres` keeps just geometry whose
## node/surface/texture name looks like a tire or wheel; `filter_shape` drops lumps
## that cannot be a wheel (not touching the ground, or too big) - off when the names
## already told us it is a wheel.
func _wheel_candidates(only_tyres := false, filter_shape := true) -> Array:
	var comps := _components(only_tyres)
	var out := []
	var half_w := maxf(size.x * 0.5, 1e-3)
	var half_l := maxf(size.z * 0.5, 1e-3)
	for root in comps:
		var c: Dictionary = comps[root]
		var lo: Vector3 = c["min"]
		var hi: Vector3 = c["max"]
		var ext := hi - lo
		if filter_shape:
			if lo.y > size.y * 0.2:          # must reach the ground
				continue
			if ext.y > size.y * 0.8:         # a wheel is not the whole kart
				continue
			if ext.x > half_w * 1.05 or ext.z > half_l * 0.9:
				continue
		out.append({"root": root, "min": lo, "max": hi, "centre": (lo + hi) * 0.5,
			"radius": ext.y * 0.5, "tris": int(c["tris"])})
	return out


## Unions the model's triangles into connected pieces by welded vertex position.
## Fills _uf / _tri_ids / _vert_src / _comp_tris and returns root -> {"min","max","tris"}.
## When `only_tyres` is true only geometry whose node/surface/texture name looks
## like a tire takes part.
func _components(only_tyres: bool) -> Dictionary:
	_uf.clear()
	_tri_ids.clear()
	_vert_src.clear()
	_comp_tris.clear()
	var pos_of: Array[Vector3] = []
	var key_first := {}
	for ci in chunks.size():
		var c: Dictionary = chunks[ci]
		if only_tyres:
			var s := (String(c.node) + " " + String(c.surface) + " " + String(c.tex).get_file()).to_lower()
			if not (s.contains("tire") or s.contains("tyre") or s.contains("wheel")):
				continue
		var np: PackedVector3Array = _npos[ci]
		var idx: PackedInt32Array = c.idx
		for t in range(0, idx.size() - 2, 3):
			var ids := PackedInt32Array()
			ids.resize(3)
			for k in 3:
				var vi := idx[t + k]
				var p := np[vi]
				var key := Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))
				var v := int(key_first.get(key, -1))
				if v < 0:
					v = pos_of.size()
					key_first[key] = v
					pos_of.append(p)
					_vert_src.append(Vector2i(ci, vi))
				ids[k] = v
			_union(ids[0], ids[1])
			_union(ids[0], ids[2])
			_tri_ids.append(ids)
	var out := {}
	for i in _tri_ids.size():
		var root := _find_root(_tri_ids[i][0])
		if not out.has(root):
			out[root] = {"min": Vector3(INF, INF, INF), "max": -Vector3(INF, INF, INF), "tris": 0}
			_comp_tris[root] = []
		var rec: Dictionary = out[root]
		rec["tris"] = int(rec["tris"]) + 1
		var list: Array = _comp_tris[root]
		list.append(i)
		_comp_tris[root] = list
		var mn: Vector3 = rec["min"]
		var mx: Vector3 = rec["max"]
		for k in 3:
			var p := pos_of[_tri_ids[i][k]]
			mn = mn.min(p)
			mx = mx.max(p)
		rec["min"] = mn
		rec["max"] = mx
	return out


func _union(a: int, b: int) -> void:
	var ra := _find_root(a)
	var rb := _find_root(b)
	if ra != rb:
		_uf[rb] = ra


func _find_root(a: int) -> int:
	var r := a
	while int(_uf.get(r, r)) != r:
		r = int(_uf[r])
	# path compression, iterative
	var k := a
	while int(_uf.get(k, k)) != k:
		var nxt := int(_uf[k])
		_uf[k] = r
		k = nxt
	return r


## Takes the biggest candidate in each of the four corners and names it.
func _take_quadrants(cands: Array) -> void:
	var best := {}
	for c in cands:
		var cen: Vector3 = c["centre"]
		var q := Vector2i(0 if cen.x < 0.0 else 1, 0 if cen.z < 0.0 else 1)
		if not best.has(q) or int(c["tris"]) > int(best[q]["tris"]):
			best[q] = c
	if best.size() < 4:
		notes.append("Only %d of the 4 wheel corners were found." % best.size())
	for q in best:
		var c: Dictionary = best[q]
		var name := "wheel_" + ("f" if q.y == 0 else "b") + ("l" if q.x == 0 else "r")
		wheels[name] = {"centre": c["centre"], "radius": c["radius"]}
		_paint_component(int(c["root"]), name)


## Gives every vertex of a connected piece a part name.
func _paint_component(root: int, part: String) -> void:
	for i in _comp_tris.get(root, []):
		for v in _tri_ids[int(i)]:
			var src := _vert_src[v]
			if src.y < _vpart[src.x].size():
				_vpart[src.x][src.y] = part


# ------------------------------------------------------------------ build

## Rig dictionary (format of assets/rigs/*.json). `tex_map` maps a chunk texture
## key to the path written into the rig.
func build_rig(tex_map: Dictionary = {}) -> Dictionary:
	var parts: Array = [{"name": "body", "pivot": [0.0, 0.0, 0.0], "parent": -1}]
	var index := {"body": 0}
	for w in WHEELS:
		if not wheels.has(w):
			continue
		var c: Vector3 = wheels[w]["centre"]
		index[w] = parts.size()
		parts.append({"name": w, "pivot": [snappedf(c.x, 0.0001), snappedf(c.y, 0.0001), snappedf(c.z, 0.0001)],
			"parent": -1})
	# one rig surface per texture
	var by_tex := {}
	for ci in chunks.size():
		var key := tex_key(ci)
		if not by_tex.has(key):
			by_tex[key] = []
		by_tex[key].append(ci)
	var surfaces: Array = []
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for key in by_tex:
		var pos32 := PackedFloat32Array()
		var nrm32 := PackedFloat32Array()
		var uv32 := PackedFloat32Array()
		var idx := PackedInt32Array()
		var pa := PackedInt32Array()
		for ci in by_tex[key]:
			var np: PackedVector3Array = _npos[ci]
			var nn: PackedVector3Array = _nnrm[ci]
			var cu: PackedVector2Array = chunks[ci].uv
			var rr: PackedStringArray = _vpart[ci]
			var keep := PackedInt32Array()
			keep.resize(np.size())
			for i in np.size():
				keep[i] = pa.size()
				pos32.append(snappedf(np[i].x, 0.00001))
				pos32.append(snappedf(np[i].y, 0.00001))
				pos32.append(snappedf(np[i].z, 0.00001))
				nrm32.append(snappedf(nn[i].x, 0.0001))
				nrm32.append(snappedf(nn[i].y, 0.0001))
				nrm32.append(snappedf(nn[i].z, 0.0001))
				uv32.append(snappedf(cu[i].x, 0.00001))
				uv32.append(snappedf(cu[i].y, 0.00001))
				pa.append(int(index.get(rr[i], 0)))
				lo = lo.min(np[i])
				hi = hi.max(np[i])
			var ci_idx: PackedInt32Array = chunks[ci].idx
			for t in range(0, ci_idx.size() - 2, 3):
				idx.append(keep[ci_idx[t]])
				idx.append(keep[ci_idx[t + 1]])
				idx.append(keep[ci_idx[t + 2]])
		if pa.is_empty():
			continue
		var w := PackedFloat32Array()
		w.resize(pa.size())          # no shared seams: wheels are separate pieces
		surfaces.append({"texture": tex_map.get(key, key), "alpha": "scissor" if _has_alpha(key) else "",
			"cull": false, "pos": Array(pos32), "nrm": Array(nrm32), "uv": Array(uv32),
			"idx": Array(idx), "pa": Array(pa), "pb": Array(pa), "w": Array(w)})
	var meta := {"source": source_path, "imported_with": "Kart Importer", "front": "-Z",
		"scale": snappedf(scale, 0.00001), "split": split,
		"aabb_min": [snappedf(lo.x, 0.0001), snappedf(lo.y, 0.0001), snappedf(lo.z, 0.0001)],
		"aabb_max": [snappedf(hi.x, 0.0001), snappedf(hi.y, 0.0001), snappedf(hi.z, 0.0001)]}
	for w in WHEELS:
		if wheels.has(w):
			var c: Vector3 = wheels[w]["centre"]
			meta[w] = {"centre": [snappedf(c.x, 0.0001), snappedf(c.y, 0.0001), snappedf(c.z, 0.0001)],
				"radius": snappedf(float(wheels[w]["radius"]), 0.0001)}
	return {"name": "kart_" + id.trim_prefix("kart_"), "parts": parts, "surfaces": surfaces, "meta": meta}


## Texture identity of a chunk: its texture path (+ opacity map), or its flat colour.
func tex_key(ci: int) -> String:
	var c: Dictionary = chunks[ci]
	if c.tex != "":
		return c.tex + ("|" + c.alpha_tex if c.alpha_tex != "" else "")
	return "colour:" + (c.colour as Color).to_html(false)


## True when the texture image has cut-out alpha (kart tires usually do).
func _has_alpha(key: String) -> bool:
	if _alpha_cache.has(key):
		return bool(_alpha_cache[key])
	var out := false
	if not key.begins_with("colour:"):
		var img := CharacterImporter.key_image(key.split("|")[0])
		for y in range(0, img.get_height(), 2):
			for x in range(0, img.get_width(), 2):
				if img.get_pixel(x, y).a < 0.4:
					out = true
					break
			if out:
				break
	_alpha_cache[key] = out
	return out


# ------------------------------------------------------------------ paint

## Colour zones for the menu: the body's dominant hue can be swapped, the wheels
## are tinted. Each zone remembers the texture it belongs to in "tex_key"; export()
## turns that into the saved image's name.
func detect_paint() -> Dictionary:
	var zones := {}
	var body := _dominant_colour(_chunk_indices("body"))
	if not body.is_empty():
		zones["body"] = {"label": "Body", "mode": "swap", "surface": "", "tex_key": body["key"],
			"src": "#" + String(body["colour"]), "tol": 0.06, "default": "#" + String(body["colour"]),
			"presets": _presets(String(body["colour"]))}
	var wheel := _dominant_texture(_chunk_indices("wheels"))
	if wheel != "" and (not body.has("key") or wheel != String(body["key"])):
		zones["wheels"] = {"label": "Wheels", "mode": "tint", "surface": "", "tex_key": wheel,
			"default": "#ffffff",
			"presets": ["#ffffff", "#ff9090", "#90b0ff", "#a0ffa0", "#ffe080", "#606060"]}
	return zones


## Most common strongly-saturated colour of the given chunks, plus the texture it
## came from (sampled at the model's UVs, so unused texture areas do not count).
func _dominant_colour(cis: Array) -> Dictionary:
	var bins := 36
	var hist := PackedFloat32Array()
	hist.resize(bins)
	var acc: Array[Vector3] = []
	acc.resize(bins)
	acc.fill(Vector3.ZERO)
	var per_key := {}
	for ci in cis:
		var key := tex_key(ci)
		per_key[key] = int(per_key.get(key, 0)) + chunks[ci].pos.size()
	if per_key.is_empty():
		return {}
	# the texture covering most of the body wins
	var key := ""
	var best_n := -1
	for k in per_key:
		if int(per_key[k]) > best_n:
			best_n = int(per_key[k])
			key = String(k)
	var img := CharacterImporter.key_image(key.split("|")[0])
	var total := 0.0
	for ci in cis:
		if tex_key(ci) != key:
			continue
		var cu: PackedVector2Array = chunks[ci].uv
		var cidx: PackedInt32Array = chunks[ci].idx
		for t in range(0, cidx.size() - 2, 3):
			for k in 3:
				var p := cu[cidx[t + k]]
				var c := img.get_pixel(clampi(int(fposmod(p.x, 1.0) * img.get_width()), 0, img.get_width() - 1),
					clampi(int(fposmod(p.y, 1.0) * img.get_height()), 0, img.get_height() - 1))
				if c.a < 0.5 or c.s < 0.35 or c.v < 0.2:
					continue
				var b := int(c.h * bins) % bins
				hist[b] += 1.0
				acc[b] += Vector3(c.r, c.g, c.b)
				total += 1.0
	if total <= 0.0:
		return {}
	var best := 0
	for b in bins:
		if hist[b] > hist[best]:
			best = b
	var sum := Vector3.ZERO
	var cnt := 0.0
	for d in [-1, 0, 1]:
		var b := posmod(best + d, bins)
		sum += acc[b]
		cnt += hist[b]
	var col := Color(sum.x / maxf(cnt, 1.0), sum.y / maxf(cnt, 1.0), sum.z / maxf(cnt, 1.0))
	return {"key": key, "colour": col.to_html(false)}


## Texture covering most of the given chunks (used for the wheel tint).
func _dominant_texture(cis: Array) -> String:
	var per_key := {}
	for ci in cis:
		var key := tex_key(ci)
		per_key[key] = int(per_key.get(key, 0)) + chunks[ci].pos.size()
	var key := ""
	var best := -1
	for k in per_key:
		if int(per_key[k]) > best:
			best = int(per_key[k])
			key = String(k)
	return key


func _chunk_indices(part: String) -> Array:
	var out := []
	for ci in chunks.size():
		for r in _vpart[ci]:
			if r == part or (part == "wheels" and String(r).begins_with("wheel")):
				out.append(ci)
				break
	return out


static func _presets(col: String) -> Array:
	var out: Array = ["#" + col]
	var h := Color.html("#" + col).h
	for p in PALETTE:
		if absf(Color.html(p).h - h) > 0.06:
			out.append(p)
	return out.slice(0, 7)


# ------------------------------------------------------------------ export

## Writes assets/rigs/kart_<id>.json, its textures and content/karts/<id>.json.
## Returns the kart definition path.
func export(paint: Dictionary, kart_dir: String = "res://content/karts/",
		rig_dir: String = "res://assets/rigs/") -> String:
	var rig_name := "kart_" + id.trim_prefix("kart_")
	var paths := save_textures(rig_dir + "tex/", rig_name)
	var rig := build_rig(paths)
	_write_json(rig_dir + rig_name + ".json", rig, false)
	var zones := {}
	for z in paint:
		var zone: Dictionary = (paint[z] as Dictionary).duplicate(true)
		var key := String(zone.get("tex_key", ""))
		zone.erase("tex_key")
		if key != "" and paths.has(key):
			zone["surface"] = String(paths[key]).get_file().get_basename()
		zones[z] = zone
	var def := {
		"id": id, "name": display_name, "rig": rig_dir + rig_name + ".json",
		"seat": _seat(), "paint": zones,
	}
	var path := kart_dir + id + ".json"
	_write_json(path, def, true)
	return path


## Where a driver sits, in kart space: a little behind the middle, above the floor.
func _seat() -> Array:
	return [0.0, snappedf(maxf(size.y * 0.09, 0.02), 0.001), snappedf(size.z * 0.12, 0.001)]


## Copies the textures to `dir` as PNGs; returns key -> res:// path.
func save_textures(dir: String, prefix: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var out := {}
	var n := 0
	for ci in chunks.size():
		var key := tex_key(ci)
		if out.has(key):
			continue
		var img := CharacterImporter.key_image(key)
		var base := "colour" if key.begins_with("colour:") else key.split("|")[0].get_file().get_basename().to_snake_case()
		var path := "%s%s_%d_%s.png" % [dir, prefix, n, base]
		img.save_png(ProjectSettings.globalize_path(path))
		out[key] = path
		n += 1
	return out


static func _write_json(path: String, data: Dictionary, pretty: bool) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t" if pretty else ""))
	f.close()
