class_name Track
extends Node3D
## A race course baked by the Map Combiner (assets/maps/<id>/track.json + .bin):
## render meshes, collision split by surface class, centreline, alternate routes,
## checkpoints and starting grid. Also answers "where am I on the course".

const DEFAULT_DATA := "res://assets/maps/retro_circuit/track.json"
## Baked map to load (track.json; track.bin and tex/ sit next to it).
var data_path := DEFAULT_DATA
var TEX_DIR := ""
const CONNECTOR_SHADER := preload("res://src/track/connector.gdshader")

## Physics layer for the course.
const LAYER_TRACK := 1

var data: Dictionary
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
	var bin := FileAccess.open(data_path.get_basename() + ".bin", FileAccess.READ)
	var fl: PackedFloat32Array = bin.get_buffer(int(data.float_count) * 4).to_float32_array()
	var ints: PackedInt32Array = bin.get_buffer(int(data.int_count) * 4).to_int32_array()
	var mesh := ArrayMesh.new()
	var col_faces := {"road": PackedVector3Array(), "off": PackedVector3Array(), "wall": PackedVector3Array()}
	for s in data.surfaces:
		var nv := int(s.vertices)
		var pos := _vec3(fl, int(s.pos), nv)
		var nrm := _vec3(fl, int(s.nrm), nv)
		var uv := PackedVector2Array()
		uv.resize(nv)
		var uo := int(s.uv)
		for i in nv:
			uv[i] = Vector2(fl[uo + i * 2], fl[uo + i * 2 + 1])
		var idx := ints.slice(int(s.idx), int(s.idx) + int(s.indices))
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
