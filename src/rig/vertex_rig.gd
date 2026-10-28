@tool
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

const PAINT_SHADER := preload("res://src/rig/rig_paint.gdshader")
## Alternative part names, so any rig can drive any animator (e.g. a runner rig
## with "foot_l" or a driver rig with "hips"/"torso" instead of "body").
const ALIASES := {
	"body": ["hips", "torso", "pelvis", "chest"],
	"hips": ["body", "pelvis"],
	"torso": ["chest", "spine"],
	"leg_lower_l": ["foot_l", "shin_l"],
	"leg_lower_r": ["foot_r", "shin_r"],
	"foot_l": ["leg_lower_l", "shin_l"],
	"foot_r": ["leg_lower_r", "shin_r"],
}

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
			"tex": s.texture, "hidden": false,
		})
	mesh = _mesh
	_loaded = true
	apply()


func _make_material(tex_path: String, alpha: String, _cull: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PAINT_SHADER
	if ResourceLoader.exists(tex_path):
		m.set_shader_parameter("tex", load(tex_path))
	m.set_shader_parameter("use_alpha", alpha == "scissor")
	return m


# --- Paint (colour customisation) -------------------------------------------------

## Recolour pixels near `src` to `dst` on surfaces whose texture path contains
## `surface_filter` ("" = every surface). Keeps the original shading.
func paint_swap(surface_filter: String, src: Color, dst: Color, tol: float = 0.07) -> void:
	for s in _surf:
		if surface_filter == "" or String(s.tex).contains(surface_filter):
			var swaps: Array = s.get("swaps", [])
			if swaps.size() >= 4:
				continue
			swaps.append([Vector3(src.h, src.s, src.v), Vector3(dst.h, dst.s, dst.v), tol])
			s.swaps = swaps
			var m: ShaderMaterial = s.mat
			var a := PackedVector3Array(); var b := PackedVector3Array(); var t := PackedFloat32Array()
			for w in swaps:
				a.append(w[0]); b.append(w[1]); t.append(w[2])
			for k in range(swaps.size(), 4):
				a.append(Vector3.ZERO); b.append(Vector3.ZERO); t.append(0.0)
			m.set_shader_parameter("src_hsv", a)
			m.set_shader_parameter("dst_hsv", b)
			m.set_shader_parameter("hue_tol", t)
			m.set_shader_parameter("swap_count", swaps.size())


## Remove all colour swaps (back to the original texture colours).
func paint_reset() -> void:
	for s in _surf:
		s.swaps = []
		(s.mat as ShaderMaterial).set_shader_parameter("swap_count", 0)
		(s.mat as ShaderMaterial).set_shader_parameter("tint", Color.WHITE)
		s.hidden = false


## Multiply the colour of matching surfaces.
func paint_tint(surface_filter: String, c: Color) -> void:
	for s in _surf:
		if surface_filter == "" or String(s.tex).contains(surface_filter):
			(s.mat as ShaderMaterial).set_shader_parameter("tint", c)


## Show or hide matching surfaces (e.g. the kart emblem).
func set_surface_visible(surface_filter: String, on: bool) -> void:
	for s in _surf:
		if String(s.tex).contains(surface_filter):
			s.hidden = not on
	apply()


## "t_pose" (arms out sideways) or "arms_down", from the file or measured.
func rest_pose() -> String:
	if meta.has("rest_pose"):
		return String(meta.rest_pose)
	var a := _find("arm_upper_l")
	var b := _find("arm_lower_l")
	if a < 0 or b < 0:
		return "arms_down"
	var d := part_pivot[b] - part_pivot[a]
	return "t_pose" if absf(d.x) > absf(d.y) else "arms_down"


# --- Pose API ------------------------------------------------------------------

func has_part(name: StringName) -> bool:
	return _find(name) >= 0


## The rig's own name for a pose part (alias-resolved), "" if the rig has no such part.
func resolve_name(name: StringName) -> StringName:
	var i := _find(name)
	return StringName(part_names[i]) if i >= 0 else &""


func _find(name: StringName) -> int:
	var i: int = part_index.get(name, -1)
	if i >= 0:
		return i
	for alt in ALIASES.get(String(name), []):
		i = part_index.get(alt, -1)
		if i >= 0:
			return i
	return -1


func reset_pose() -> void:
	for i in part_rot.size():
		part_rot[i] = Basis.IDENTITY
		part_offset[i] = Vector3.ZERO


## Rotation in radians, applied about the part's pivot. Euler order YXZ.
func set_rot(name: StringName, euler: Vector3) -> void:
	var i := _find(name)
	if i >= 0:
		part_rot[i] = Basis.from_euler(euler)


func set_part_basis(name: StringName, b: Basis) -> void:
	var i := _find(name)
	if i >= 0:
		part_rot[i] = b


func set_offset(name: StringName, off: Vector3) -> void:
	var i := _find(name)
	if i >= 0:
		part_offset[i] = off


## Add to the current offset (e.g. a procedural bob on top of an authored pose).
func add_offset(name: StringName, off: Vector3) -> void:
	var i := _find(name)
	if i >= 0:
		part_offset[i] = part_offset[i] + off


## Add an extra local rotation on top of the current pose (e.g. a head turn).
func add_rot(name: StringName, euler: Vector3) -> void:
	var i := _find(name)
	if i >= 0:
		part_rot[i] = part_rot[i] * Basis.from_euler(euler)


func pivot_of(name: StringName) -> Vector3:
	var i := _find(name)
	return part_pivot[i] if i >= 0 else Vector3.ZERO


## Current rig-space position of a point that is attached to a part in rest pose.
func point_on(name: StringName, rest_point: Vector3) -> Vector3:
	var i := _find(name)
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
		if s.hidden:
			continue
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
		_mesh.surface_set_material(_mesh.get_surface_count() - 1, s.mat)


## Index of the part whose triangles the ray hits first (editor viewport picking),
## or -1 when it misses. Uses the deformed positions, so it matches what is drawn.
func pick(origin: Vector3, dir: Vector3) -> int:
	var best := -1
	var best_t := INF
	for s in _surf:
		if s.hidden:
			continue
		var pos: PackedVector3Array = s.pos
		var idx: PackedInt32Array = s.idx
		var pa: PackedInt32Array = s.pa
		for i in range(0, idx.size() - 2, 3):
			var ia := idx[i]
			var t := _ray_triangle(origin, dir, pos[ia], pos[idx[i + 1]], pos[idx[i + 2]])
			if t > 0.0 and t < best_t:
				best_t = t
				best = pa[ia]
	return best


static func _ray_triangle(o: Vector3, d: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	# Moeller-Trumbore; returns the ray distance or -1.
	var e1 := b - a
	var e2 := c - a
	var p := d.cross(e2)
	var det := e1.dot(p)
	if absf(det) < 1e-7:
		return -1.0
	var inv := 1.0 / det
	var tvec := o - a
	var u := tvec.dot(p) * inv
	if u < 0.0 or u > 1.0:
		return -1.0
	var q := tvec.cross(e1)
	var v := d.dot(q) * inv
	if v < 0.0 or u + v > 1.0:
		return -1.0
	var t := e2.dot(q) * inv
	return t if t > 1e-4 else -1.0


## Debug/verification: how far vertices currently are from rest (max distance).
func max_displacement() -> float:
	var best := 0.0
	for s in _surf:
		var rp: PackedVector3Array = s.rest_pos
		var pos: PackedVector3Array = s.pos
		for i in rp.size():
			best = maxf(best, rp[i].distance_to(pos[i]))
	return best
