@tool
class_name MapImporter
extends RefCounted
## Turns a whole track model (OBJ / glTF / DAE - anything Godot imports) into a
## playable map, without going through the Map Combiner's hand-made source files.
##
## The Map Combiner stitches pieces of the two shipped tracks together. This does
## the other thing: one outside model in, one finished course out.
##
## 1. load_source()  - every mesh surface, its material, texture and opacity
## 2. classes        - road / off-road / wall / decoration per surface, guessed from
##                     the node and texture names (the dock lets you change them)
## 3. build()        - scale + centre the model, rasterise the road, then *drive* a
##                     centreline along it: step forward, look ahead, move to the
##                     middle of the road between its edges, repeat until the loop
##                     closes. Width comes from the edges, height from the road
##                     triangles, so the game gets the same data a bake produces.
## 4. export_map()   - assets/maps/<id>/track.json + track.bin + tex/ + preview.png
##                     and content/maps/<id>.json, so it appears in the menu and can
##                     be cleaned up and decorated in the Map Editor.
##
## No Python and no source-track config: the centreline is found from the model.

## Node / texture name hints, checked in this order.
const DECO_HINTS := ["tree", "leaf", "leaves", "bush", "flower", "plant", "shrub", "sign",
	"banner", "flag", "lamp", "light", "crowd", "people", "cloud", "sky", "cable", "wire",
	"line", "fencepost", "arrow", "billboard", "balloon"]
const ROAD_HINTS := ["road", "track", "asphalt", "tarmac", "street", "course", "roadway",
	"highway", "pavement", "drivable"]
const WALL_HINTS := ["wall", "fence", "rail", "barrier", "guard", "pillar", "post", "kerb",
	"curb", "ledge", "block", "bridge", "tunnel"]
const OFF_HINTS := ["grass", "dirt", "sand", "ground", "terrain", "offroad", "off_road",
	"snow", "mud", "water", "sea", "rock", "stone", "cliff", "shore"]
const ALPHA_HINTS := ["tran", "alpha", "cut", "leaf", "foliage", "tree", "bush", "flag"]

const CLASSES := ["road", "off", "wall", "deco", "skip"]
const CELL := 1.0            ## road raster cell (metres)
const BUCKET := 4.0          ## height-lookup bucket (metres)
const SPACING := 2.0         ## centreline sample spacing (metres), like the bake
const MAX_WIDTH := 30.0
const MIN_WIDTH := 6.0
const MAX_LOOK := 24.0       ## how far the edge probes reach
const MASK_GAP := 5          ## cells (metres) of road hole that get bridged

var source_path := ""
var id := ""
var display_name := ""
var subtitle := ""
var scale := 1.0             ## metres per model unit
var checkpoints := 8
var laps := 3
var start_auto := true       ## false: use `start` + `start_yaw`
var start := Vector2.ZERO    ## map-space XZ (metres, after scale)
var start_yaw := 0.0         ## degrees, 0 = +X, 90 = +Z (only when start_auto is off)

## Raw mesh pieces: {node, surface, mat, tex, colour, alpha, pos, nrm, uv, idx}
var chunks: Array[Dictionary] = []
## Grouped surfaces: {name, key, tex, colour, alpha, class, tris, chunks: [int]}
var surfaces: Array[Dictionary] = []
var notes := PackedStringArray()
var report := {}             ## what build() found (shown in the dock)

var _npos: Array[PackedVector3Array] = []
var _nnrm: Array[PackedVector3Array] = []
var _origin := Vector3.ZERO
var size := Vector3.ZERO

# road raster (map space): cell (x, z) -> _ox + x * CELL, _oz + z * CELL
var _mask := PackedByteArray()
var _mw := 0
var _mh := 0
var _ox := 0.0
var _oz := 0.0

# road triangles (map space) + their bucket index, for heights
var _road_tris: Array[PackedVector3Array] = []
var _bucket := {}

var _points: Array[Vector3] = []     ## traced centreline (y = road height)
var _widths := PackedFloat32Array()
var _closed := false


# ------------------------------------------------------------------ load

func load_source(path: String) -> String:
	source_path = path
	chunks.clear()
	surfaces.clear()
	if not ResourceLoader.exists(path):
		return "Not an imported resource: %s (put the model inside the project and let Godot import it)" % path
	var r: Resource = load(path)
	if r == null:
		return "Could not load %s (is it imported? check the Import dock for errors)" % path
	if r is Mesh:
		_add_mesh(r, path.get_file().get_basename(), Transform3D.IDENTITY, null)
	elif r is PackedScene:
		var root: Node = r.instantiate()
		_walk(root, Transform3D.IDENTITY)
		root.free()
	else:
		return "Unsupported resource type: %s" % r.get_class()
	if chunks.is_empty():
		return "No meshes found in %s" % path
	if id == "":
		id = path.get_file().get_basename().to_snake_case()
	if display_name == "":
		display_name = path.get_file().get_basename().capitalize()
	group_surfaces()
	_prepare()          # geometry ready to draw, before anything is traced
	return ""


func _walk(n: Node, parent_xf: Transform3D) -> void:
	var xf := parent_xf
	if n is Node3D:
		xf = parent_xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh and (n as MeshInstance3D).visible:
		_add_mesh((n as MeshInstance3D).mesh, String(n.name), xf, n as MeshInstance3D)
	for c in n.get_children():
		_walk(c, xf)


func _add_mesh(m: Mesh, node_name: String, xf: Transform3D, mi: MeshInstance3D) -> void:
	for s in m.get_surface_count():
		if m.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var a := m.surface_get_arrays(s)
		var pos: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		if pos.is_empty():
			continue
		var nrm: PackedVector3Array = a[Mesh.ARRAY_NORMAL] if a[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV] if a[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if idx.is_empty():
			idx.resize(pos.size())
			for i in pos.size():
				idx[i] = i
		var wp := PackedVector3Array()
		wp.resize(pos.size())
		var wn := PackedVector3Array()
		wn.resize(pos.size())
		for i in pos.size():
			wp[i] = xf * pos[i]
			wn[i] = (xf.basis * (nrm[i] if i < nrm.size() else Vector3.UP)).normalized()
		if uv.size() != pos.size():
			uv.resize(pos.size())
		var mat: Material = mi.get_active_material(s) if mi else m.surface_get_material(s)
		var tex := ""
		var colour := Color.WHITE
		var alpha := false
		var mat_name := ""
		if mat is BaseMaterial3D:
			var bm := mat as BaseMaterial3D
			colour = bm.albedo_color
			if bm.albedo_texture:
				tex = bm.albedo_texture.resource_path
			alpha = bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
			mat_name = bm.resource_name
		var surf_name: String = (m as ArrayMesh).surface_get_name(s) if m is ArrayMesh else ""
		if surf_name == "" and mat:
			surf_name = mat.resource_name
		if surf_name == "":
			surf_name = "surface %d" % s
		if mat_name == "":
			mat_name = surf_name
		chunks.append({"node": node_name, "surface": surf_name, "mat": mat_name, "tex": tex,
			"colour": colour, "alpha": alpha, "pos": wp, "nrm": wn, "uv": uv, "idx": idx})


## Groups the mesh pieces into surfaces the dock can list and guesses what each one
## is for. The material counts too: an OBJ imported by Godot can keep every piece in
## one node named "Shape" and split them only by material, which is what the texture
## is here.
func group_surfaces() -> void:
	surfaces.clear()
	var index := {}
	for ci in chunks.size():
		var c: Dictionary = chunks[ci]
		var key := String(c.node) + "/" + String(c.surface) + "/" + _piece_key(c)
		if not index.has(key):
			index[key] = surfaces.size()
			var alpha := bool(c.alpha) or _name_in(String(c.surface) + " " + String(c.tex), ALPHA_HINTS)
			var sname := String(c.surface)
			var tname := String(c.tex).get_file()
			var stem := tname.get_basename()
			# "Shape" / "surface 0" say nothing: show the texture name instead.
			if stem != "" and (sname == "" or sname.to_lower().begins_with("shape")
					or sname.to_lower().begins_with("surface")):
				sname = stem
			surfaces.append({"name": sname, "key": key, "tex": String(c.tex),
				"colour": c.colour, "alpha": alpha, "tris": 0, "chunks": [],
				"class": guess_class(sname, String(c.tex), alpha)})
		var s: Dictionary = surfaces[index[key]]
		s.tris = int(s.tris) + int(c.idx.size() / 3)
		var list: Array = s["chunks"]
		list.append(ci)
		s["chunks"] = list


## Texture identity of a mesh piece: its image, or its flat colour.
static func _piece_key(c: Dictionary) -> String:
	var tex := String(c.get("tex", ""))
	if tex != "":
		return tex
	var col: Color = c.get("colour", Color.WHITE)
	return "colour:" + col.to_html(false)


## Up-facing area of every surface in square metres (scaled): the road is usually
## not the biggest thing in a course model, but a surface with no flat area at all
## cannot be one.
func surface_areas() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(surfaces.size())
	for si in surfaces.size():
		var area := 0.0
		for ci in surfaces[si]["chunks"]:
			var np: PackedVector3Array = chunks[int(ci)].pos
			var idx: PackedInt32Array = chunks[int(ci)].idx
			for t in range(0, idx.size() - 2, 3):
				var n := (np[idx[t + 1]] - np[idx[t]]).cross(np[idx[t + 2]] - np[idx[t]])
				if n.length_squared() > 1e-12 and absf(n.normalized().y) > 0.5:
					area += n.length() * 0.5 * scale * scale
		out[si] = area
	return out


static func _name_in(text: String, hints: Array) -> bool:
	var t := text.to_lower()
	for h in hints:
		if t.contains(String(h)):
			return true
	return false


## Best guess at a surface's job from its node/material/texture names.
static func guess_class(surface_name: String, tex_path: String, alpha: bool) -> String:
	var t := (surface_name + " " + tex_path.get_file()).to_lower()
	if _name_in(t, ROAD_HINTS):
		return "road"
	if _name_in(t, WALL_HINTS):
		return "wall"
	if _name_in(t, DECO_HINTS) or alpha:
		return "deco"
	if _name_in(t, OFF_HINTS):
		return "off"
	return "off"


# ------------------------------------------------------------------ build

## Scales, traces the centreline and measures it. Returns "" on success, else why.
func build() -> String:
	notes.clear()
	report = {}
	if chunks.is_empty():
		return "Load a model first."
	if id == "":
		return "Give the map an id."
	if not _ensure_road():
		return "No surface is set to road - set one in the class list."
	_prepare()
	_raster_road()
	if _road_tris.is_empty():
		return "The road surface has no triangles."
	var err := _trace()
	if err != "":
		return err
	_heights()
	report["length"] = _length()
	report["samples"] = _points.size()
	report["closed"] = _closed
	report["width_min"] = _min_width()
	report["width_max"] = _max_width()
	return ""


## Tries the surfaces with flat area, biggest first, until one of them traces a
## closed lap. Returns "" when one worked (it is then the road surface).
## Hashed texture names ("7EEA0D6A_c.png") say nothing about which is the asphalt,
## so this is usually the quickest way in.
func detect_road(max_tries: int = 8) -> String:
	var areas := surface_areas()
	var order: Array = []
	for si in surfaces.size():
		if areas[si] > 0.5:
			order.append(si)
	order.sort_custom(func(a: int, b: int) -> bool: return areas[a] > areas[b])
	if order.is_empty():
		return "No surface has any flat (up-facing) area - this does not look like a track."
	var previous := -1
	for si in surfaces.size():
		if String(surfaces[si]["class"]) == "road":
			previous = si
	var last := ""
	var tries := 0
	for si in order:
		if tries >= max_tries:
			break
		tries += 1
		_set_only_road(int(si))
		var err := build()
		if err == "":
			notes.append("Road detected: \"%s\" (try %d of %d)." % [surfaces[int(si)]["name"], tries, mini(max_tries, order.size())])
			return ""
		last = err
	for k in surfaces.size():
		if String(surfaces[k]["class"]) == "road":
			surfaces[k]["class"] = "off"
	if previous >= 0:
		surfaces[previous]["class"] = "road"
	return "No surface traced a closed lap (%d tried). Last problem: %s" % [tries, last]


## Makes `si` the road surface (the one the centreline follows).
func set_road(si: int) -> void:
	_set_only_road(si)


## Adds a surface to the road as well (a road split over two materials, or a
## separate piece of it) or takes it out again. Returns a note for the dock's log.
func toggle_alt_road(si: int) -> String:
	if si < 0 or si >= surfaces.size():
		return "No surface there."
	var sname := String(surfaces[si]["name"])
	if String(surfaces[si]["class"]) == "road":
		var roads := 0
		for s in surfaces:
			if String(s["class"]) == "road":
				roads += 1
		if roads <= 1:
			return "\"%s\" is the only road surface - pick another road first." % sname
		surfaces[si]["class"] = "off"
		return "\"%s\" is no longer road." % sname
	surfaces[si]["class"] = "road"
	var n := 0
	for s in surfaces:
		if String(s["class"]) == "road":
			n += 1
	return "\"%s\" is road too (%d road surfaces)." % [sname, n]


## Puts the start / finish line at a map-space XZ point, pointing along the road
## there. Returns "" on success, or why that point cannot be the start.
func set_start(at: Vector2) -> String:
	_prepare()
	_raster_road()
	if _road_tris.is_empty():
		return "Set a road surface first, then click on the road."
	var h := road_height(at.x, at.y)
	if h < -1e29:
		return "That point is not on the road."
	var p := Vector3(at.x, h, at.y)
	if not _on_road(p):
		return "That point is not on the road."
	start_auto = false
	start = at
	var d := _road_dir(p, Vector3.RIGHT)
	start_yaw = snappedf(rad_to_deg(atan2(d.z, d.x)), 1.0)
	return ""


## Makes `si` the only road surface.
func _set_only_road(si: int) -> void:
	for k in surfaces.size():
		if String(surfaces[k]["class"]) == "road":
			surfaces[k]["class"] = "off"
	if si >= 0 and si < surfaces.size():
		surfaces[si]["class"] = "road"


## Makes sure at least one surface is the road. If none is named like one, the
## surface with the most upward-facing area wins.
func _ensure_road() -> bool:
	for s in surfaces:
		if String(s["class"]) == "road" and int(s["tris"]) > 0:
			return true
	var areas := surface_areas()
	var best := -1
	for si in areas.size():
		if areas[si] > 0.0 and (best < 0 or areas[si] > areas[best]):
			best = si
	if best < 0:
		return false
	surfaces[best]["class"] = "road"
	notes.append("No surface looked like a road, so \"%s\" is being used as the road." % surfaces[best]["name"])
	return true


## Geometry ready to draw: scale, centre and ground the model. Safe to call again.
func prepare() -> void:
	_prepare()


## Applies scale, centres the model on X/Z and puts its lowest point on y = 0.
func _prepare() -> void:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for c in chunks:
		for p in c.pos:
			lo = lo.min(p)
			hi = hi.max(p)
	_origin = Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
	_npos.clear()
	_nnrm.clear()
	var blo := Vector3(INF, INF, INF)
	var bhi := -lo
	for ci in chunks.size():
		var np := PackedVector3Array()
		np.resize(chunks[ci].pos.size())
		var nn := PackedVector3Array()
		nn.resize(chunks[ci].nrm.size())
		for i in np.size():
			np[i] = (chunks[ci].pos[i] - _origin) * scale
			if i < nn.size():
				nn[i] = chunks[ci].nrm[i]
			blo = blo.min(np[i])
			bhi = bhi.max(np[i])
		_npos.append(np)
		_nnrm.append(nn)
	size = bhi - blo


## Rasterises the road surfaces into a 1 m grid and buckets their triangles for
## height lookups.
func _raster_road() -> void:
	_road_tris.clear()
	_bucket.clear()
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for si in surfaces.size():
		if String(surfaces[si]["class"]) != "road":
			continue
		for ci in surfaces[si]["chunks"]:
			var np: PackedVector3Array = _npos[int(ci)]
			for p in np:
				lo = lo.min(p)
				hi = hi.max(p)
	if lo.x > hi.x:
		_mw = 0
		_mh = 0
		_mask = PackedByteArray()
		return
	lo -= Vector3(MAX_LOOK, 0.0, MAX_LOOK)
	hi += Vector3(MAX_LOOK, 0.0, MAX_LOOK)
	_ox = lo.x
	_oz = lo.z
	_mw = maxi(1, int(ceil((hi.x - lo.x) / CELL)) + 1)
	_mh = maxi(1, int(ceil((hi.z - lo.z) / CELL)) + 1)
	_mask = PackedByteArray()
	_mask.resize(_mw * _mh)
	_mask.fill(0)
	for si in surfaces.size():
		if String(surfaces[si]["class"]) != "road":
			continue
		for ci in surfaces[si]["chunks"]:
			var np: PackedVector3Array = _npos[int(ci)]
			var idx: PackedInt32Array = chunks[int(ci)].idx
			for t in range(0, idx.size() - 2, 3):
				var tri := PackedVector3Array([np[idx[t]], np[idx[t + 1]], np[idx[t + 2]]])
				var ti := _road_tris.size()
				_road_tris.append(tri)
				_fill_tri(tri)
				_bucket_tri(ti, tri)
	_close_mask()


## Bridges narrow holes in the road mask: a start / finish line is often its own
## surface with no asphalt under it, and so are the seams between pieces. Only a
## run of empty cells with road on both sides is filled, so the road does not get
## wider and two separate roads are not joined by accident.
func _close_mask() -> void:
	for pass_i in 2:
		for y in _mh:
			var x := 0
			while x < _mw:
				if _mask[y * _mw + x] != 0:
					x += 1
					continue
				var start := x
				while x < _mw and _mask[y * _mw + x] == 0:
					x += 1
				if start > 0 and x < _mw and x - start <= MASK_GAP:
					for k in range(start, x):
						_mask[y * _mw + k] = 1
		for x in _mw:
			var y := 0
			while y < _mh:
				if _mask[y * _mw + x] != 0:
					y += 1
					continue
				var start := y
				while y < _mh and _mask[y * _mw + x] == 0:
					y += 1
				if start > 0 and y < _mh and y - start <= MASK_GAP:
					for k in range(start, y):
						_mask[k * _mw + x] = 1


func _fill_tri(tri: PackedVector3Array) -> void:
	var a := Vector2(tri[0].x, tri[0].z)
	var b := Vector2(tri[1].x, tri[1].z)
	var c := Vector2(tri[2].x, tri[2].z)
	var x0 := int(floor((minf(a.x, minf(b.x, c.x)) - _ox) / CELL))
	var x1 := int(ceil((maxf(a.x, maxf(b.x, c.x)) - _ox) / CELL))
	var y0 := int(floor((minf(a.y, minf(b.y, c.y)) - _oz) / CELL))
	var y1 := int(ceil((maxf(a.y, maxf(b.y, c.y)) - _oz) / CELL))
	var pts := [a, b, c]
	for gy in range(maxi(y0, 0), mini(y1, _mh - 1) + 1):
		var zc := _oz + (gy + 0.5) * CELL
		var xs := []
		for e in 3:
			var p0: Vector2 = pts[e]
			var p1: Vector2 = pts[(e + 1) % 3]
			if (p0.y <= zc and p1.y > zc) or (p1.y <= zc and p0.y > zc):
				var f := (zc - p0.y) / (p1.y - p0.y)
				xs.append(lerpf(p0.x, p1.x, f))
		if xs.size() < 2:
			continue
		var lx: float = xs.min()
		var hx: float = xs.max()
		var gx0 := maxi(x0, 0)
		var gx1 := mini(x1, _mw - 1)
		for gx in range(gx0, gx1 + 1):
			var xc := _ox + (gx + 0.5) * CELL
			if xc >= lx and xc <= hx:
				_mask[gy * _mw + gx] = 1


func _bucket_tri(ti: int, tri: PackedVector3Array) -> void:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p in tri:
		lo = lo.min(p)
		hi = hi.max(p)
	var x0 := int(floor((lo.x - _ox) / BUCKET))
	var x1 := int(floor((hi.x - _ox) / BUCKET))
	var z0 := int(floor((lo.z - _oz) / BUCKET))
	var z1 := int(floor((hi.z - _oz) / BUCKET))
	for bx in range(x0, x1 + 1):
		for bz in range(z0, z1 + 1):
			var key := Vector2i(bx, bz)
			if not _bucket.has(key):
				_bucket[key] = PackedInt32Array()
			var list: PackedInt32Array = _bucket[key]
			list.append(ti)
			_bucket[key] = list


func _road_cell(cx: int, cz: int) -> bool:
	if cx < 0 or cz < 0 or cx >= _mw or cz >= _mh:
		return false
	return _mask[cz * _mw + cx] != 0


func _on_road(v: Vector3) -> bool:
	return _road_cell(int(floor((v.x - _ox) / CELL)), int(floor((v.z - _oz) / CELL)))


## Height of the highest road triangle under (x, z), or -INF when there is none.
func road_height(x: float, z: float) -> float:
	var key := Vector2i(int(floor((x - _ox) / BUCKET)), int(floor((z - _oz) / BUCKET)))
	var best := -1e30
	var list: PackedInt32Array = _bucket.get(key, PackedInt32Array())
	for ti in list:
		var h := _tri_y(_road_tris[ti], x, z)
		if h > best:
			best = h
	if best > -1e29:
		return best
	# A big triangle can reach further than its bucket: fall back to a full scan.
	for tri in _road_tris:
		var h2 := _tri_y(tri, x, z)
		if h2 > best:
			best = h2
	return best


static func _tri_y(tri: PackedVector3Array, x: float, z: float) -> float:
	var a := tri[0]
	var b := tri[1]
	var c := tri[2]
	var den := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(den) < 1e-9:
		return -1e30
	var w0 := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / den
	var w1 := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / den
	var w2 := 1.0 - w0 - w1
	if w0 < -1e-4 or w1 < -1e-4 or w2 < -1e-4:
		return -1e30
	return w0 * a.y + w1 * b.y + w2 * c.y


# ------------------------------------------------------------------ trace

## Distance along the road from p in `dir` (never further than MAX_LOOK).
func _edge(p: Vector3, dir: Vector3) -> float:
	var d := 0.0
	while d < MAX_LOOK:
		d += 0.5
		if not _on_road(p + dir * d):
			return d - 0.5
	return MAX_LOOK


## Follows the road until the centreline comes back to where it started.
func _trace() -> String:
	var st := _start_frame()
	if st.is_empty():
		return "No start point on the road."
	var p: Vector3 = st[0]
	var t: Vector3 = st[1]
	_points.clear()
	_widths = PackedFloat32Array()
	_points.append(p)
	_widths.append(_edge(p, -_right_of(t)) + _edge(p, _right_of(t)))
	var step := SPACING
	var travelled := 0.0
	var max_steps := 4000
	_closed = false
	for i in max_steps:
		var right := _right_of(t)
		var l := _edge(p, -right)
		var r := _edge(p, right)
		if l + r < 3.0:
			return "Lost the road after %.0f m - the road surface is too narrow or broken in two." % travelled
		p += right * (r - l) * 0.5
		# Look ahead, then pull the look-ahead point into the middle of the road there.
		var look := p + t * step * 2.0
		var l2 := _edge(look, -right)
		var r2 := _edge(look, right)
		if l2 + r2 < 2.0:
			look = p + t * step
			l2 = _edge(look, -right)
			r2 = _edge(look, right)
			if l2 + r2 < 2.0:
				return "The road ends after %.0f m - is the course a closed loop?" % travelled
		look += right * (r2 - l2) * 0.5
		var d := look - p
		d.y = 0.0
		if d.length() < step * 0.25:
			return "The path stalls after %.0f m (the road may fold back on itself)." % travelled
		d = d.normalized()
		var ang := t.angle_to(d)
		if ang > 1.2:
			return "The road turns more than 70 degrees in one step after %.0f m - try another start." % travelled
		if ang > 0.5:                     # keep corners from throwing the path sideways
			d = t.slerp(d, 0.5 / ang).normalized()
		t = (t * 0.45 + d * 0.55).normalized()
		right = _right_of(t)
		l = _edge(p, -right)
		r = _edge(p, right)
		var np := p + t * step
		np.y = 0.0
		travelled += p.distance_to(np)
		p = np
		_points.append(p)
		_widths.append(l + r)
		if _points.size() > 16 and travelled > step * 12.0:
			var back := Vector2(p.x - _points[0].x, p.z - _points[0].z).length()
			if back < step * 1.2:
				_closed = true
				break
	if not _closed:
		return "The centreline did not close after %.0f m - the course may not be a loop, or the start is on a branch." % travelled
	# The last point sits on the first one: drop it so the lap does not stutter.
	_points.pop_back()
	_widths.resize(_points.size())
	for i in _widths.size():
		_widths[i] = clampf(_widths[i], MIN_WIDTH, MAX_WIDTH)
	return ""


static func _right_of(t: Vector3) -> Vector3:
	var r := t.cross(Vector3.UP)
	if r.length_squared() < 1e-8:
		return Vector3.RIGHT
	return r.normalized()


## Start position + heading. Auto: the widest part of the road, pointing along it.
func _start_frame() -> Array:
	if not start_auto:
		var h := road_height(start.x, start.y)
		if h > -1e29 and _on_road(Vector3(start.x, h, start.y)):
			var a := deg_to_rad(start_yaw)
			var t := Vector3(cos(a), 0.0, sin(a)).normalized()
			return [Vector3(start.x, h, start.y), t]
		notes.append("The start point is not on the road - using the widest part of it instead.")
	# Auto: widest cell of the road (distance to the nearest edge) ...
	var widest := _widest_point()
	if widest.is_empty():
		return []
	var p: Vector3 = widest[0]
	# ... pointing along the road.
	var best_dir := _road_dir(p, Vector3.RIGHT)
	var h := road_height(p.x, p.z)
	return [Vector3(p.x, h if h > -1e29 else 0.0, p.z), best_dir]


## Direction of travel at p: the direction whose chord stays on the road longest.
func _road_dir(p: Vector3, fallback: Vector3) -> Vector3:
	var best_len := -1.0
	var best_dir := fallback
	for k in 16:
		var a := TAU * float(k) / 16.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		var l := _edge(p, dir) + _edge(p, -dir)
		if l > best_len:
			best_len = l
			best_dir = dir
	return best_dir


## Cell centre farthest from the road's edge (a cheap distance field).
func _widest_point() -> Array:
	var n := _mw * _mh
	if n == 0:
		return []
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(-1)
	var q := PackedInt32Array()
	for i in n:
		if _mask[i] == 0:
			continue
		var x := i % _mw
		var y := i / _mw
		if not (_road_cell(x - 1, y) and _road_cell(x + 1, y) and _road_cell(x, y - 1) and _road_cell(x, y + 1)):
			dist[i] = 1
			q.append(i)
	var head := 0
	var best := 0
	var best_d := 0
	while head < q.size():
		var i := q[head]
		head += 1
		if dist[i] > best_d:
			best_d = dist[i]
			best = i
		var x: int = i % _mw
		var y: int = i / _mw
		var nd := dist[i] + 1
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				if dx == 0 and dy == 0:
					continue
				var cx: int = x + int(dx)
				var cy: int = y + int(dy)
				if not _road_cell(cx, cy):
					continue
				var j: int = cy * _mw + cx
				if dist[j] >= 0:
					continue
				dist[j] = nd
				q.append(j)
	if best_d == 0:
		return []
	var bx := best % _mw
	var by := best / _mw
	return [Vector3(_ox + (bx + 0.5) * CELL, 0.0, _oz + (by + 0.5) * CELL)]


## Real heights from the road triangles, smoothed so the course is not a staircase.
func _heights() -> void:
	var ys := PackedFloat32Array()
	ys.resize(_points.size())
	var last := 0.0
	for i in _points.size():
		var h := road_height(_points[i].x, _points[i].z)
		if h < -1e29:
			h = last
		last = h
		ys[i] = h
	for pass_i in 2:
		var out := ys.duplicate()
		for i in ys.size():
			var a := ys[posmod(i - 1, ys.size())]
			var c := ys[(i + 1) % ys.size()]
			out[i] = (a + 2.0 * ys[i] + c) * 0.25
		ys = out
	for i in _points.size():
		_points[i] = Vector3(_points[i].x, ys[i], _points[i].z)


func _length() -> float:
	var total := 0.0
	for i in _points.size():
		var j := (i + 1) % _points.size()
		var d := (_points[j] - _points[i])
		d.y = 0.0
		total += d.length()
	return total


func _min_width() -> float:
	if _widths.is_empty():
		return 0.0
	var m := INF
	for w in _widths:
		m = minf(m, w)
	return m


func _max_width() -> float:
	var m := 0.0
	for w in _widths:
		m = maxf(m, w)
	return m


## Distance travelled up to sample i.
func _distance_at(i: int) -> float:
	var total := 0.0
	for k in mini(i, _points.size()):
		var j := (k + 1) % _points.size()
		var d := (_points[j] - _points[k])
		d.y = 0.0
		total += d.length()
	return total


func _tangent_at(i: int) -> Vector3:
	var a := _points[posmod(i - 1, _points.size())]
	var b := _points[(i + 1) % _points.size()]
	var t := Vector3(b.x - a.x, 0.0, b.z - a.z)
	if t.length_squared() < 1e-8:
		return Vector3.RIGHT
	return t.normalized()


## Checkpoint sample indices and the starting grid slots.
func _checkpoints() -> Array:
	var out: Array = []
	if _points.is_empty():
		return out
	var total := _length()
	var dists := PackedFloat32Array()
	dists.resize(_points.size())
	for i in _points.size():
		dists[i] = _distance_at(i)
	for c in checkpoints:
		var target := total * float(c) / float(maxi(checkpoints, 1))
		var best := 0
		for i in dists.size():
			if absf(dists[i] - target) < absf(dists[best] - target):
				best = i
		if not out.has(best):
			out.append(best)
	out.sort()
	return out


func _grid() -> Array:
	var out: Array = []
	var n := _points.size()
	for k in 8:
		var row := k / 2
		var col := k % 2
		var back := 6.0 + float(row) * 6.0
		var i := posmod(-int(round(back / SPACING)), n)
		var right := _right_of(_tangent_at(i))
		var half := minf(2.5, _widths[i] * 0.25)
		var p := _points[i] + right * (-half if col == 0 else half)
		p.y = _points[i].y + 0.3
		var fwd := _tangent_at(i)
		out.append({"pos": [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)],
			"fwd": [snappedf(fwd.x, 0.0001), 0.0, snappedf(fwd.z, 0.0001)]})
	return out


# ------------------------------------------------------------------ export

## Writes the map: assets/maps/<id>/{track.json,track.bin,tex/,preview.png} and
## content/maps/<id>.json. Returns the map definition path.
func export_map(map_dir: String = "res://content/maps/") -> String:
	var out_dir := "res://assets/maps/" + id
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir + "/tex"))
	var tex_names := _write_textures(out_dir + "/tex/")
	var groups := {}
	for si in surfaces.size():
		var s: Dictionary = surfaces[si]
		var cls := String(s["class"])
		if cls == "skip":
			continue
		var key := String(tex_names.get(_tex_key(s), ""))
		var gkey := key + "|" + cls + "|" + str(bool(s["alpha"]))
		if not groups.has(gkey):
			groups[gkey] = {"tex": key, "class": cls, "alpha": bool(s["alpha"]), "chunks": []}
		var g: Dictionary = groups[gkey]
		var list: Array = g["chunks"]
		list.append_array(s["chunks"])
		g["chunks"] = list
	# start / finish checker
	var checker := _checker_texture(out_dir + "/tex/")
	groups["__start"] = {"tex": checker, "class": "deco", "alpha": false, "quad": true}
	var floats := PackedFloat32Array()
	var ints := PackedInt32Array()
	var surf_meta: Array = []
	for gkey in groups:
		var g: Dictionary = groups[gkey]
		var pos := PackedVector3Array()
		var nrm := PackedVector3Array()
		var uv := PackedVector2Array()
		var idx := PackedInt32Array()
		if bool(g.get("quad", false)):
			_append_start_stripe(pos, nrm, uv, idx)
		else:
			for ci in g["chunks"]:
				var np: PackedVector3Array = _npos[int(ci)]
				var nn: PackedVector3Array = _nnrm[int(ci)]
				var cu: PackedVector2Array = chunks[int(ci)].uv
				var base := pos.size()
				for i in np.size():
					pos.append(np[i])
					nrm.append(nn[i] if i < nn.size() else Vector3.UP)
					uv.append(cu[i] if i < cu.size() else Vector2.ZERO)
				var ci_idx: PackedInt32Array = chunks[int(ci)].idx
				for k in ci_idx.size():
					idx.append(base + ci_idx[k])
		if idx.is_empty():
			continue
		var nv := pos.size()
		var foff := floats.size()
		for p in pos:
			floats.append(p.x)
			floats.append(p.y)
			floats.append(p.z)
		for v in nrm:
			floats.append(v.x)
			floats.append(v.y)
			floats.append(v.z)
		for t in uv:
			floats.append(t.x)
			floats.append(t.y)
		var col_off := floats.size()
		for i in nv:
			floats.append(0.0)
		surf_meta.append({"texture": String(g["tex"]), "class": String(g["class"]),
			"alpha": bool(g["alpha"]), "vertices": nv, "indices": idx.size(),
			"pos": foff, "nrm": foff + nv * 3, "uv": foff + nv * 6, "col": col_off, "idx": ints.size()})
		ints.append_array(idx)
	var data := {
		"name": display_name,
		"length": snappedf(_length(), 0.01),
		"centreline": _centreline_json(),
		"forks": [],
		"checkpoints": _checkpoints(),
		"grid": _grid(),
		"kill_y": snappedf(_lowest_y() - 20.0, 0.01),
		"sections": [],
		"connectors": {},
		"surfaces": surf_meta,
		"float_count": floats.size(),
		"int_offset_bytes": floats.size() * 4,
		"int_count": ints.size(),
	}
	var bin := FileAccess.open(out_dir + "/track.bin", FileAccess.WRITE)
	bin.store_buffer(floats.to_byte_array())
	bin.store_buffer(ints.to_byte_array())
	bin.close()
	var f := FileAccess.open(out_dir + "/track.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	_write_preview(out_dir + "/preview.png")
	var def := {
		"id": id, "name": display_name, "subtitle": subtitle,
		"data": out_dir + "/track.json", "preview": out_dir + "/preview.png",
		"laps": laps, "length": int(snappedf(_length(), 1.0)),
		"import": {"source": source_path, "scale": scale, "checkpoints": checkpoints},
	}
	var path := map_dir + id + ".json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(map_dir))
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(def, "\t"))
	f.close()
	return path


func _centreline_json() -> Array:
	var out: Array = []
	for i in _points.size():
		var p := _points[i]
		out.append({"p": [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)],
			"up": [0.0, 1.0, 0.0], "w": snappedf(_widths[i], 0.01) if i < _widths.size() else 10.0, "f": 0})
	return out


## The start / finish stripe: a flat checker quad across the road at sample 0.
func _append_start_stripe(pos: PackedVector3Array, nrm: PackedVector3Array,
		uv: PackedVector2Array, idx: PackedInt32Array) -> void:
	if _points.is_empty():
		return
	var p := _points[0]
	var t := _tangent_at(0)
	var r := _right_of(t)
	var hw := (_widths[0] if not _widths.is_empty() else 10.0) * 0.5
	p.y += 0.04
	var corners := [p - r * hw - t * 1.5, p + r * hw - t * 1.5, p + r * hw + t * 1.5, p - r * hw + t * 1.5]
	var uvs := [Vector2(0, 0), Vector2(8, 0), Vector2(8, 3), Vector2(0, 3)]
	for i in 4:
		pos.append(corners[i])
		nrm.append(Vector3.UP)
		uv.append(uvs[i])
	idx.append_array(PackedInt32Array([0, 1, 2, 0, 2, 3]))


## First centreline sample (where the start / finish line is), for the dock.
func start_point() -> Vector3:
	return _points[0] if not _points.is_empty() else Vector3.ZERO


# ------------------------------------------------------------------ reading the trace

## Traced centreline, y = road height.
func path() -> Array[Vector3]:
	return _points


func path_widths() -> PackedFloat32Array:
	return _widths


func path_length() -> float:
	return _length()


## Indices into path() where the checkpoints sit.
func checkpoint_indices() -> Array:
	return _checkpoints()


## Starting grid slots, as they will be written to the map.
func grid_slots() -> Array:
	return _grid()


func _lowest_y() -> float:
	var m := INF
	for ci in chunks.size():
		for p in _npos[ci]:
			m = minf(m, p.y)
	return m if m < INF else 0.0


## Texture identity of a surface: its image, or a flat colour.
static func _tex_key(s: Dictionary) -> String:
	var tex := String(s.get("tex", ""))
	if tex == "":
		var col: Color = s.get("colour", Color.WHITE)
		return "colour:" + col.to_html(false)
	return tex


## Copies every texture into the map's tex folder as a lowercase PNG (Track looks
## textures up as TEX_DIR + lower-case name) and returns key -> file name.
func _write_textures(dir: String) -> Dictionary:
	var out := {}
	var used := {}
	for si in surfaces.size():
		var key := _tex_key(surfaces[si])
		if out.has(key):
			continue
		var base := "colour" if key.begins_with("colour:") else key.get_file().get_basename().to_snake_case()
		base = _safe_name(base)
		var name := base + ".png"
		var n := 2
		while used.has(name):
			name = "%s_%d.png" % [base, n]
			n += 1
		used[name] = true
		var img: Image
		if key.begins_with("colour:"):
			img = Image.create(4, 4, false, Image.FORMAT_RGBA8)
			img.fill(Color.html(key.substr(7)))
		else:
			img = _load_image(key)
			if img == null:
				img = Image.create(4, 4, false, Image.FORMAT_RGBA8)
				img.fill(Color.MAGENTA)
		img.save_png(ProjectSettings.globalize_path(dir + name))
		out[key] = name
	return out


static func _safe_name(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s[i].to_lower()
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_":
			out += c
	if out == "":
		out = "tex"
	if out.begins_with("conn"):
		out = "tex_" + out        # "conn*" is the connector shader in Track
	return out


static func _load_image(path: String) -> Image:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null and ResourceLoader.exists(path):
		var t: Texture2D = load(path)
		if t:
			img = t.get_image()
	if img and img.is_compressed():
		img.decompress()
	return img


## 16 x 16 black/white checker for the start line, saved next to the textures.
func _checker_texture(dir: String) -> String:
	var img := Image.create(16, 16, false, Image.FORMAT_RGB8)
	for y in 16:
		for x in 16:
			var on := ((x / 8) + (y / 8)) % 2 == 0
			img.set_pixel(x, y, Color(0.95, 0.95, 0.95) if on else Color(0.08, 0.08, 0.1))
	img.save_png(ProjectSettings.globalize_path(dir + "start_checker.png"))
	return "start_checker.png"


## Menu thumbnail: the road seen from above with the racing line and the start.
func _write_preview(path: String) -> void:
	var W := 448
	var H := 232
	var img := Image.create(W, H, false, Image.FORMAT_RGB8)
	img.fill(Color(0.16, 0.24, 0.13))
	if _mw > 0 and _mh > 0:
		var pad := 10
		var sx := float(W - pad * 2) / float(_mw)
		var sy := float(H - pad * 2) / float(_mh)
		var s := minf(sx, sy)
		var ox := pad + (W - pad * 2 - _mw * s) * 0.5
		var oy := pad + (H - pad * 2 - _mh * s) * 0.5
		for py in H:
			for px in W:
				var mx := int((px - ox) / s)
				var my := int((py - oy) / s)
				if mx < 0 or my < 0 or mx >= _mw or my >= _mh:
					continue
				if _mask[my * _mw + mx] != 0:
					img.set_pixel(px, py, Color(0.55, 0.55, 0.58))
		# racing line
		for i in _points.size():
			var j := (i + 1) % _points.size()
			var a := Vector2(ox + (_points[i].x - _ox) / CELL * s, oy + (_points[i].z - _oz) / CELL * s)
			var b := Vector2(ox + (_points[j].x - _ox) / CELL * s, oy + (_points[j].z - _oz) / CELL * s)
			_line(img, a, b, Color(1.0, 0.86, 0.25))
		if not _points.is_empty():
			var p0 := Vector2(ox + (_points[0].x - _ox) / CELL * s, oy + (_points[0].z - _oz) / CELL * s)
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					var q := Vector2i(int(p0.x) + dx, int(p0.y) + dy)
					if q.x >= 0 and q.y >= 0 and q.x < W and q.y < H:
						img.set_pixel(q.x, q.y, Color.WHITE)
	img.save_png(ProjectSettings.globalize_path(path))


static func _line(img: Image, a: Vector2, b: Vector2, col: Color) -> void:
	var d := b - a
	var steps := int(maxf(absf(d.x), absf(d.y))) + 1
	for k in steps + 1:
		var p := a + d * (float(k) / float(maxi(steps, 1)))
		var x := int(p.x)
		var y := int(p.y)
		if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
			img.set_pixel(x, y, col)
