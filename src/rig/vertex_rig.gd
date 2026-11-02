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
##
## The two legs are tilted slightly outward when the feet would otherwise touch
## (imported models often have both shoes modelled as one block across the centre
## line). It is a base under every pose, so no pose - built-in, authored clip or the
## Animation Editor preview - can push the shoes through each other again.

const PAINT_SHADER := preload("res://src/rig/rig_paint.gdshader")
## Gap kept between the feet, as a fraction of the rig's height, and the most the legs
## are tilted outward to reach it (radians).
const FOOT_GAP := 0.06
const MAX_LEG_SPLAY := 0.15
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
var leg_splay := 0.0                       ## outward tilt of each leg, radians (0 = none)
var _splay_l := -1                         ## part tilted outward, left leg
var _splay_r := -1                         ## part tilted outward, right leg

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
	# Cut the welded faces first: until each foot owns only its own shoe, the gap
	# between them cannot be measured (each side still holds corners of both).
	_cut_welds()
	_measure_leg_splay()
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


## "l" / "r" / centre: which side of the body a part sits on, from its name.
static func _side(name: String) -> int:
	if name.ends_with("_l"):
		return -1
	if name.ends_with("_r"):
		return 1
	return 0


## Imported models often have the two shoes modelled as one welded mass across the
## centre line - a sole or ankle ring running from one foot to the other. Every face
## of that bridge has a corner in each foot, so whichever foot it is given, it stays
## strung between them: the shoes cannot separate, and turning one foot drags half of
## the other shoe through it.
##
## The fix is a cut, not a reassignment: a face that straddles the centre plane is
## split along that plane, and each side keeps its own piece, given the part that side
## names. The two feet then share neither a face nor a vertex. Nothing moves at rest -
## the halves still meet exactly - but the seam opens as soon as the feet move apart.
##
## It runs when a rig is exported (so the file itself is right, in the game and in the
## Animation Editor) and again when one is loaded, which catches rigs that predate it
## and costs nothing on a rig that was already cut.
static func cut_welds(surfaces: Array, names: PackedStringArray, height: float) -> void:
	var index := {}
	for i in names.size():
		index[names[i]] = i
	var eps := 0.002 * maxf(height, 0.01)
	for si in surfaces.size():
		var s: Dictionary = surfaces[si]
		var pos := (s.pos as PackedVector3Array).duplicate()
		var nrm := (s.nrm as PackedVector3Array).duplicate()
		var uv := (s.uv as PackedVector2Array).duplicate()
		var pa := (s.pa as PackedInt32Array).duplicate()
		var pb := (s.pb as PackedInt32Array).duplicate()
		var w := (s.w as PackedFloat32Array).duplicate()
		var idx := (s.idx as PackedInt32Array).duplicate()
		if pos.is_empty() or idx.is_empty():
			continue
		if pb.size() < pos.size():
			pb.resize(pos.size())
		if w.size() < pos.size():
			w.resize(pos.size())
		# 1. a seam point shared by the left and right of a limb stops following both.
		for i in pos.size():
			if w[i] > 0.0 and _side(names[pa[i]]) * _side(names[pb[i]]) < 0:
				w[i] = 0.0
		# 2. every face that straddles the centre plane is cut along it.
		var out := PackedInt32Array()
		var cut := false
		for t in range(0, idx.size() - 2, 3):
			var tri := [idx[t], idx[t + 1], idx[t + 2]]
			var lo := 0
			var hi := 0
			var moves := false
			for c in tri:
				var sd := _side(names[pa[c]])
				lo = mini(lo, sd)
				hi = maxi(hi, sd)
				if sd != 0 and pos[c].x * float(sd) < -eps:
					moves = true
			# Only a face that really spans the two sides is cut; one that sits on a
			# single side is kept whole, however far its own side's letter decides.
			if not (lo < 0 and hi > 0) and not moves:
				out.append(tri[0]); out.append(tri[1]); out.append(tri[2])
				continue
			cut = true
			for sd in [-1, 1]:
				var piece := _clip_side(pos, nrm, uv, tri, sd, eps)
				if piece.size() < 3:
					continue
				var part := _piece_part(names, index, pa, pos, tri, sd, eps)
				for k in range(1, piece.size() - 1):
					for v in [piece[0], piece[k], piece[k + 1]]:
						out.append(pos.size())
						pos.append(v.p)
						nrm.append(v.n)
						uv.append(v.t)
						pa.append(part)
						pb.append(part)
						w.append(0.0)
		if not cut:
			continue
		# 3. drop the vertices the cut left behind - a face whose corners were labelled
		#    for the other foot is replaced by its two halves, so the old corners are
		#    no longer drawn and must not keep a piece of the wrong shoe alive.
		var used := {}
		for vi in out:
			used[vi] = true
		var cpos := PackedVector3Array()
		var cnrm := PackedVector3Array()
		var cuv := PackedVector2Array()
		var cpa := PackedInt32Array()
		var cpb := PackedInt32Array()
		var cw := PackedFloat32Array()
		var remap := {}
		for i in pos.size():
			if used.has(i):
				remap[i] = cpos.size()
				cpos.append(pos[i])
				cnrm.append(nrm[i])
				cuv.append(uv[i])
				cpa.append(pa[i])
				cpb.append(pb[i])
				cw.append(w[i])
		for i in out.size():
			out[i] = remap[out[i]]
		s.pos = cpos
		s.nrm = cnrm
		s.uv = cuv
		s.pa = cpa
		s.pb = cpb
		s.w = cw
		s.idx = out


## The cut as this rig needs it: applied to the surfaces in memory once they load.
func _cut_welds() -> void:
	var views: Array = []
	for s in _surf:
		views.append({"pos": s.rest_pos, "nrm": s.rest_nrm, "uv": s.uv, "idx": s.idx,
			"pa": s.pa, "pb": s.pb, "w": s.w})
	var h := float(meta.get("aabb_max", [0.0, 1.0, 0.0])[1]) - float(meta.get("aabb_min", [0.0, 0.0, 0.0])[1])
	cut_welds(views, part_names, h)
	for i in _surf.size():
		var s: Dictionary = _surf[i]
		var v: Dictionary = views[i]
		s.rest_pos = v.pos
		s.pos = (v.pos as PackedVector3Array).duplicate()
		s.rest_nrm = v.nrm
		s.nrm = (v.nrm as PackedVector3Array).duplicate()
		s.uv = v.uv
		s.pa = v.pa
		s.pb = v.pb
		s.w = v.w
		s.idx = v.idx


## The polygon one side keeps of a triangle cut at the centre plane. Corners on the
## plane are copied into both sides, so the two halves never share a vertex.
static func _clip_side(pos: PackedVector3Array, nrm: PackedVector3Array, uv: PackedVector2Array,
		tri: Array, side: int, eps: float) -> Array:
	var out: Array = []
	var sgn := float(side)
	for k in 3:
		var ai: int = tri[k]
		var bi: int = tri[(k + 1) % 3]
		var ap := pos[ai]
		var bp := pos[bi]
		var inside_a := ap.x * sgn >= -eps
		var inside_b := bp.x * sgn >= -eps
		if inside_a:
			out.append({"p": ap, "n": nrm[ai], "t": uv[ai]})
		if inside_a != inside_b:
			var d := bp.x - ap.x
			if absf(d) > 1e-9:
				var f := clampf(-ap.x / d, 0.0, 1.0)
				var n := (nrm[ai].lerp(nrm[bi], f))
				out.append({"p": ap.lerp(bp, f), "n": n.normalized() if n.length() > 0.000001 else nrm[ai],
					"t": uv[ai].lerp(uv[bi], f)})
	return out


## The part a cut piece belongs to: the part its corners standing on that side name,
## mirrored over when a corner was labelled with the other side's part.
static func _piece_part(names: PackedStringArray, index: Dictionary, pa: PackedInt32Array,
		pos: PackedVector3Array, tri: Array, side: int, eps: float) -> int:
	var votes := {}
	for c in tri:
		if pos[c].x * float(side) > eps:
			var p := _mirror(names, index, pa[c], side)
			votes[p] = int(votes.get(p, 0)) + 1
	if votes.is_empty():
		return _mirror(names, index, pa[tri[0]], side)
	var best: int = votes.keys()[0]
	for p in votes:
		if int(votes[p]) > int(votes[best]):
			best = int(p)
	return best


## The same part on the other side of the body (`foot_l` -> `foot_r`), or the part
## itself when it has no mirror.
static func _mirror(names: PackedStringArray, index: Dictionary, part: int, side: int) -> int:
	var n := String(names[part])
	var want := "_l" if side < 0 else "_r"
	if n.ends_with(want) or _side(n) == 0:
		return part
	var i: int = index.get(n.substr(0, n.length() - 2) + want, -1)
	return i if i >= 0 else part


## How far each leg has to tilt outward so the two feet stop touching, measured on the
## rest geometry: the narrowest gap between the left and right lower leg decides. Rig
## space is metres, so the extra half-gap each foot needs divided by the lever - from
## the leg's top pivot down to that closest point - is the sine of the tilt. Rigs whose
## feet already stand far enough apart keep `leg_splay` at 0 and look as authored.
func _measure_leg_splay() -> void:
	leg_splay = 0.0
	_splay_l = -1
	_splay_r = -1
	var l := _find(&"foot_l")
	if l < 0:
		l = _find(&"leg_lower_l")
	var r := _find(&"foot_r")
	if r < 0:
		r = _find(&"leg_lower_r")
	if l < 0 or r < 0 or l == r:
		return
	var lift_l := _find(&"leg_upper_l")
	var lift_r := _find(&"leg_upper_r")
	if lift_l < 0:
		lift_l = l
	if lift_r < 0:
		lift_r = r
	# Narrowest gap between the two lower legs, band by band from the sole to the knee.
	var bands := 12
	var lo := INF
	var hi := -INF
	for s in _surf:
		for i in s.pa.size():
			if s.pa[i] == l or s.pa[i] == r:
				var y: float = (s.rest_pos[i] as Vector3).y
				lo = minf(lo, y)
				hi = maxf(hi, y)
	if not (lo < hi):
		return
	var lmax := PackedFloat32Array(); lmax.resize(bands)
	var rmin := PackedFloat32Array(); rmin.resize(bands)
	lmax.fill(-INF)
	rmin.fill(INF)
	for s in _surf:
		for i in s.pa.size():
			var p: Vector3 = s.rest_pos[i]
			var b := clampi(int((p.y - lo) / (hi - lo) * bands), 0, bands - 1)
			if s.pa[i] == l:
				lmax[b] = maxf(lmax[b], p.x)
			elif s.pa[i] == r:
				rmin[b] = minf(rmin[b], p.x)
	var gap := INF
	var at := lo
	for b in bands:
		if lmax[b] == -INF or rmin[b] == INF:
			continue
		var g := rmin[b] - lmax[b]
		if g < gap:
			gap = g
			at = lo + (hi - lo) * (b + 0.5) / float(bands)
	if gap == INF:
		return
	var h := hi - lo
	if meta.has("aabb_min") and meta.has("aabb_max"):
		h = float(meta.aabb_max[1]) - float(meta.aabb_min[1])
	var want := FOOT_GAP * maxf(h, hi - lo)
	var lever := part_pivot[lift_l].y - at
	if gap >= want or lever <= 0.0001:
		return
	leg_splay = minf(MAX_LEG_SPLAY, asin(clampf((want - gap) * 0.5 / lever, 0.0, 1.0)))
	_splay_l = lift_l
	_splay_r = lift_r


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
		var rot := part_rot[i]
		if i == _splay_l:
			rot = rot * Basis(Vector3.BACK, -leg_splay)
		elif i == _splay_r:
			rot = rot * Basis(Vector3.BACK, leg_splay)
		var local := Transform3D(Basis.IDENTITY, part_offset[i] + p) \
			* Transform3D(rot, Vector3.ZERO) \
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
