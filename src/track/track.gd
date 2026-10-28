class_name Track
extends Node3D
## A race course baked by the Map Combiner (assets/maps/<id>/track.json + .bin):
## render meshes, collision split by surface class, centreline, alternate routes,
## checkpoints and starting grid. Also answers "where am I on the course".
##
## A bake can be cleaned up and decorated with the Map Editor dock, which writes
## decor.json next to track.json: erased triangles ("hidden"), hidden surfaces and
## decoration props. Re-baking the map leaves decor.json in place.

const DEFAULT_DATA := "res://assets/maps/retro_circuit/track.json"
const DECOR_NAME := "decor.json"
## Baked map to load (track.json; track.bin and tex/ sit next to it).
var data_path := DEFAULT_DATA
var TEX_DIR := ""
const CONNECTOR_SHADER := preload("res://src/track/connector.gdshader")

## Physics layer for the course.
const LAYER_TRACK := 1

var data: Dictionary
var decor: Dictionary = {}         ## decor.json: {"props": [...], "hidden": {...}}
## surface index -> {face index: true}: triangles erased in the Map Editor.
var hidden_faces := {}
var hidden_surfaces := {}          ## surface index -> true
## Per-surface source arrays, only filled when `keep_geometry` is on (the Map Editor
## needs them to pick and erase triangles): index -> {"pos", "idx", "class"}.
var surface_geo := {}
var keep_geometry := false
var _floats := PackedFloat32Array()
var _ints := PackedInt32Array()
var props_root: Node3D             ## decoration props from decor.json
var path := TrackPath.new()        ## main route
## Alternate routes: [{"path": TrackPath, "from": int, "to": int, "ai": bool, "name": String}]
var forks: Array[Dictionary] = []
var fork := TrackPath.new()        ## first alternate route (kept for older code)
var fork_from := -1000
var fork_to := -1000
var checkpoints: PackedInt32Array = []
var grid: Array = []
var kill_y := -25.0
var surface_bodies := {}           ## class -> StaticBody3D


## Call once after creating the node (any map: pass its track.json path).
func load_track(map_path: String = "") -> void:
	if not data.is_empty():
		push_warning("Track.load_track called twice; ignoring")
		return
	if map_path != "":
		data_path = map_path
	TEX_DIR = data_path.get_base_dir() + "/tex/"
	var f := FileAccess.open(data_path, FileAccess.READ)
	data = JSON.parse_string(f.get_as_text())
	_read_decor()
	path.build(data.centreline, true)
	forks.clear()
	var fl: Array = data.get("forks", [data.fork] if data.has("fork") else [])
	for fk in fl:
		var fpts: Array = []
		for p in fk.points:
			fpts.append({"p": p})
		var tp := TrackPath.new()
		tp.build(fpts, false)
		forks.append({"path": tp, "from": int(fk.join_from), "to": int(fk.join_to),
			"ai": bool(fk.get("ai", true)), "karts": bool(fk.get("karts", false)),
			"name": String(fk.get("name", "alternate route"))})
	if not forks.is_empty():
		fork = forks[0].path
		fork_from = forks[0].from
		fork_to = forks[0].to
	checkpoints = PackedInt32Array(data.checkpoints)
	grid = data.grid
	kill_y = float(data.get("kill_y", -25.0))
	_build_geometry()


func _build_geometry() -> void:
	var fl := _floats
	var ints := _ints
	if fl.is_empty():
		var bin := FileAccess.open(data_path.get_basename() + ".bin", FileAccess.READ)
		if bin == null:
			push_error("Track: missing " + data_path.get_basename() + ".bin")
			return
		fl = bin.get_buffer(int(data.float_count) * 4).to_float32_array()
		ints = bin.get_buffer(int(data.int_count) * 4).to_int32_array()
		if keep_geometry:
			_floats = fl
			_ints = ints
	var mesh := ArrayMesh.new()
	var col_faces := {"road": PackedVector3Array(), "off": PackedVector3Array(), "wall": PackedVector3Array()}
	var surfaces: Array = data.surfaces
	for si in surfaces.size():
		var s: Dictionary = surfaces[si]
		if hidden_surfaces.has(si):
			continue
		var nv := int(s.vertices)
		var pos := _vec3(fl, int(s.pos), nv)
		var nrm := _vec3(fl, int(s.nrm), nv)
		var uv := PackedVector2Array()
		uv.resize(nv)
		var uo := int(s.uv)
		for i in nv:
			uv[i] = Vector2(fl[uo + i * 2], fl[uo + i * 2 + 1])
		var idx := ints.slice(int(s.idx), int(s.idx) + int(s.indices))
		if keep_geometry:
			surface_geo[si] = {"pos": pos, "idx": idx, "class": String(s["class"]),
				"texture": String(s.texture)}
		idx = _without_hidden(si, idx)
		if idx.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_INDEX] = idx
		if String(s.texture).begins_with("conn"):
			var colr := PackedColorArray()
			colr.resize(nv)
			var co := int(s.col)
			for i in nv:
				colr[i] = Color(fl[co + i], 0, 0)
			arrays[Mesh.ARRAY_COLOR] = colr
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(s))
		var cls: String = s["class"]
		if col_faces.has(cls):
			var faces: PackedVector3Array = col_faces[cls]
			for k in idx.size():
				faces.append(pos[idx[k]])
			col_faces[cls] = faces
	var mi := MeshInstance3D.new()
	mi.name = "CourseMesh"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	for cls in col_faces:
		var body := StaticBody3D.new()
		body.name = "Collision_" + cls
		body.collision_layer = LAYER_TRACK
		body.collision_mask = 0
		body.set_meta("surface", cls)
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(col_faces[cls])
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		add_child(body)
		surface_bodies[cls] = body
	props_root = Node3D.new()
	props_root.name = "Props"
	add_child(props_root)
	var props: Array = decor.get("props", [])
	TrackProps.spawn(props_root, props)


## The index buffer of surface `si` minus the triangles erased in the Map Editor.
func _without_hidden(si: int, idx: PackedInt32Array) -> PackedInt32Array:
	var hid: Dictionary = hidden_faces.get(si, {})
	if hid.is_empty():
		return idx
	var kept := PackedInt32Array()
	var faces := idx.size() / 3
	for f in faces:
		if not hid.has(f):
			kept.append(idx[f * 3])
			kept.append(idx[f * 3 + 1])
			kept.append(idx[f * 3 + 2])
	return kept


# --- decor.json (Map Editor edits) --------------------------------------------------

func _read_decor() -> void:
	# The Map Editor fills `decor` itself before load_track, so it is not read twice.
	if decor.is_empty():
		var dp := data_path.get_base_dir() + "/" + DECOR_NAME
		if FileAccess.file_exists(dp):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(dp))
			if parsed is Dictionary:
				decor = parsed
			else:
				push_warning("Track: could not parse " + dp)
	_apply_decor_sets()


func _apply_decor_sets() -> void:
	hidden_faces.clear()
	hidden_surfaces.clear()
	var hid: Variant = decor.get("hidden", {})
	if hid is Dictionary:
		for k in hid:
			var faces := {}
			var list: Variant = hid[k]
			if list is Array:
				for f in list:
					faces[int(f)] = true
			if not faces.is_empty():
				hidden_faces[int(k)] = faces
	var hs: Variant = decor.get("hidden_surfaces", [])
	if hs is Array:
		for s in hs:
			hidden_surfaces[int(s)] = true


## Editor hook: replace the decoration and rebuild. The game loads decor.json itself.
func apply_decor(d: Dictionary) -> void:
	decor = d
	_apply_decor_sets()
	rebuild()


func rebuild() -> void:
	_clear_geometry()
	_build_geometry()


func _clear_geometry() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	surface_bodies.clear()
	surface_geo.clear()
	props_root = null


static func _vec3(fl: PackedFloat32Array, off: int, n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(n)
	for i in n:
		out[i] = Vector3(fl[off + i * 3], fl[off + i * 3 + 1], fl[off + i * 3 + 2])
	return out


func _material(s: Dictionary) -> Material:
	if String(s.texture).begins_with("conn"):
		var sm := ShaderMaterial.new()
		sm.shader = CONNECTOR_SHADER
		var c: Dictionary
		if data.has("connectors"):
			c = data.connectors.get(s.texture, {})
		else:   # older bakes
			c = {"a": data.textures.conn_a, "b": data.textures.conn_b, "rect_b": data.textures.conn_b_rect}
		sm.set_shader_parameter("tex_a", load(TEX_DIR + String(c.get("a", ""))))
		sm.set_shader_parameter("tex_b", load(TEX_DIR + String(c.get("b", ""))))
		for k in ["rect_a", "rect_b"]:
			var r: Variant = c.get(k)
			if r is Array:
				# bake rect is OBJ space (v up); convert to Godot UV space (v down)
				sm.set_shader_parameter(k, Vector4(r[0], 1.0 - r[1] - r[3], r[2], r[3]))
		return sm
	var m := StandardMaterial3D.new()
	var tp := TEX_DIR + String(s.texture).to_lower()
	if ResourceLoader.exists(tp):
		m.albedo_texture = load(tp)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if s.alpha:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.5
	return m


# --- Queries -------------------------------------------------------------------

## Where is `p` on the course? `hint` is the caller's last main index (keeps the
## search local). Positions on the alternate route are mapped onto the main route's
## distance so progress and AI keep working there.
func locate(p: Vector3, hint: int = -1) -> Dictionary:
	var i := path.nearest(p, hint)
	var d_main := path.pos[i].distance_to(p)
	var dist := path.dist[i]
	var lat := path.lateral(i, p)
	var half := path.width[i] * 0.5
	var on_fork := false
	var fi := -1
	var fk_i := -1
	# Near an alternate route? Use it if it is clearly closer than the main route.
	for k in forks.size():
		var f: Dictionary = forks[k]
		if i < int(f.from) - 10 or i > int(f.to) + 10:
			continue
		var fp: TrackPath = f.path
		var j := fp.nearest(p)
		if fp.pos[j].distance_to(p) + 1.0 < d_main:
			on_fork = true
			fi = j
			fk_i = k
			var t := float(j) / float(maxi(fp.size() - 1, 1))
			dist = lerpf(path.dist[int(f.from)], path.dist[int(f.to)], t)
			lat = fp.lateral(j, p)
			half = 6.0
			i = path.index_ahead(int(f.from), dist - path.dist[int(f.from)])
			break
	return {"index": i, "on_fork": on_fork, "fork_index": fi, "fork": fk_i, "distance": dist, "lateral": lat,
		"half_width": half, "loop": (path.flags[i] & TrackPath.FLAG_LOOP) != 0}


func fork_path(k: int) -> TrackPath:
	return forks[k].path if k >= 0 and k < forks.size() else null


func checkpoint_distance(k: int) -> float:
	return path.dist[checkpoints[k]]


func grid_transform(slot: int) -> Transform3D:
	var g: Dictionary = grid[slot % grid.size()]
	var p := Vector3(g.pos[0], g.pos[1], g.pos[2])
	var fwd := Vector3(g.fwd[0], g.fwd[1], g.fwd[2])
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), p)


## Respawn point on the main route at sample i, facing along the course.
func respawn_transform(i: int) -> Transform3D:
	var p := path.pos[i] + path.up[i] * 1.0
	return Transform3D(Basis.looking_at(path.tangent[i], Vector3.UP), p)
