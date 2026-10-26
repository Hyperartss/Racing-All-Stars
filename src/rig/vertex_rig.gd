class_name VertexRig
extends MeshInstance3D
## Vertex animation without skeletons.
##
## Loads a rig file baked by tools/bake/bake_rigs.py: rest-pose geometry where every
## vertex belongs to a named part (polygon group), each part having a pivot and a
## parent part. Each frame the owner sets a rotation (and optional offset) per part;
## `apply()` then moves the vertices themselves on the CPU and re-uploads the mesh.
##
## No Skeleton3D, no Skin, no AnimationPlayer - poses are pure code.
##
## Vertices on a seam between two parts carry a second part and a 50/50 blend so
## elbows and knees do not crack open when bent.

const SHADING := BaseMaterial3D.SHADING_MODE_PER_VERTEX

@export_file("*.json") var rig_path := ""

var part_names: PackedStringArray = []
var part_index := {}                       ## name -> int
var part_pivot: Array[Vector3] = []
var part_parent: PackedInt32Array = []
var part_rot: Array[Basis] = []            ## local rotation about the pivot
var part_offset: Array[Vector3] = []       ## local translation (parent space)
var part_xform: Array[Transform3D] = []    ## result, rig space
var meta := {}

var _surf: Array[Dictionary] = []          ## rest data + materials per surface
var _mesh := ArrayMesh.new()
var _loaded := false


func _ready() -> void:
	if rig_path != "" and not _loaded:
		load_rig(rig_path)


func load_rig(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("VertexRig: cannot open %s" % path)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	meta = data.get("meta", {})
	for p in data.parts:
		part_index[p.name] = part_names.size()
		part_names.append(p.name)
		part_pivot.append(Vector3(p.pivot[0], p.pivot[1], p.pivot[2]))
		part_parent.append(int(p.parent))
		part_rot.append(Basis.IDENTITY)
		part_offset.append(Vector3.ZERO)
		part_xform.append(Transform3D.IDENTITY)
	for s in data.surfaces:
		var n: int = s.pa.size()
		var pos := PackedVector3Array(); pos.resize(n)
		var nrm := PackedVector3Array(); nrm.resize(n)
		var uv := PackedVector2Array(); uv.resize(n)
		for i in n:
			pos[i] = Vector3(s.pos[i * 3], s.pos[i * 3 + 1], s.pos[i * 3 + 2])
			nrm[i] = Vector3(s.nrm[i * 3], s.nrm[i * 3 + 1], s.nrm[i * 3 + 2])
			uv[i] = Vector2(s.uv[i * 2], s.uv[i * 2 + 1])
		_surf.append({
			"rest_pos": pos, "rest_nrm": nrm, "uv": uv,
			"idx": PackedInt32Array(s.idx),
			"pa": PackedInt32Array(s.pa), "pb": PackedInt32Array(s.pb),
			"w": PackedFloat32Array(s.w),
			"pos": pos.duplicate(), "nrm": nrm.duplicate(),
			"mat": _make_material(s.texture, s.alpha, s.cull),
		})
	mesh = _mesh
	_loaded = true
	apply()


func _make_material(tex_path: String, alpha: String, cull: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if ResourceLoader.exists(tex_path):
		m.albedo_texture = load(tex_path)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.shading_mode = SHADING
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	if alpha == "scissor":
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.5
	if not cull:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# --- Pose API ------------------------------------------------------------------

func has_part(name: StringName) -> bool:
	return part_index.has(name)


func reset_pose() -> void:
	for i in part_rot.size():
		part_rot[i] = Basis.IDENTITY
		part_offset[i] = Vector3.ZERO


## Rotation in radians, applied about the part's pivot. Euler order YXZ.
func set_rot(name: StringName, euler: Vector3) -> void:
	var i: int = part_index.get(name, -1)
	if i >= 0:
		part_rot[i] = Basis.from_euler(euler)


func set_part_basis(name: StringName, b: Basis) -> void:
	var i: int = part_index.get(name, -1)
	if i >= 0:
		part_rot[i] = b


func set_offset(name: StringName, off: Vector3) -> void:
	var i: int = part_index.get(name, -1)
	if i >= 0:
		part_offset[i] = off


func pivot_of(name: StringName) -> Vector3:
	var i: int = part_index.get(name, -1)
	return part_pivot[i] if i >= 0 else Vector3.ZERO


## Current rig-space position of a point that is attached to a part in rest pose.
func point_on(name: StringName, rest_point: Vector3) -> Vector3:
	var i: int = part_index.get(name, -1)
	return part_xform[i] * rest_point if i >= 0 else rest_point


# --- Deform ----------------------------------------------------------------------

func _solve() -> void:
	# Parents are always listed before children in the rig file.
	for i in part_names.size():
		var p := part_pivot[i]
		var local := Transform3D(Basis.IDENTITY, part_offset[i] + p) \
			* Transform3D(part_rot[i], Vector3.ZERO) \
			* Transform3D(Basis.IDENTITY, -p)
		var par := part_parent[i]
		part_xform[i] = part_xform[par] * local if par >= 0 else local


## Move every vertex to the current pose and upload the mesh.
func apply() -> void:
	if _surf.is_empty():
		return
	_solve()
	_mesh.clear_surfaces()
	for si in _surf.size():
		var s: Dictionary = _surf[si]
		var rp: PackedVector3Array = s.rest_pos
		var rn: PackedVector3Array = s.rest_nrm
		var pa: PackedInt32Array = s.pa
		var pb: PackedInt32Array = s.pb
		var w: PackedFloat32Array = s.w
		var pos: PackedVector3Array = s.pos
		var nrm: PackedVector3Array = s.nrm
		for i in rp.size():
			var ta := part_xform[pa[i]]
			if w[i] > 0.0:
				var tb := part_xform[pb[i]]
				var wb := w[i]
				pos[i] = (ta * rp[i]).lerp(tb * rp[i], wb)
				nrm[i] = (ta.basis * rn[i]).lerp(tb.basis * rn[i], wb).normalized()
			else:
				pos[i] = ta * rp[i]
				nrm[i] = ta.basis * rn[i]
		s.pos = pos
		s.nrm = nrm
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_TEX_UV] = s.uv
		arrays[Mesh.ARRAY_INDEX] = s.idx
		_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_mesh.surface_set_material(si, s.mat)


## Debug/verification: how far vertices currently are from rest (max distance).
func max_displacement() -> float:
	var best := 0.0
	for s in _surf:
		var rp: PackedVector3Array = s.rest_pos
		var pos: PackedVector3Array = s.pos
		for i in rp.size():
			best = maxf(best, rp[i].distance_to(pos[i]))
	return best
