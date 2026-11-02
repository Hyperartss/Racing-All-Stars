@tool
class_name CharacterImporter
extends RefCounted
## Turns an imported 3D model (OBJ / glTF / DAE / FBX - anything Godot imports)
## into a vertex rig + a character definition the game can use.
##
## 1. load_source()  - collect every mesh surface (positions, normals, UVs, texture)
## 2. groups         - how the model is split into parts:
##      "auto"     : one group, split by position into a biped (head, torso, hips,
##                   upper/lower arms and legs, and a foot per side) from the front
##                   silhouette. Below the crotch the side alone decides the leg, so
##                   the left and right legs never end up in the same part, and each
##                   foot gets its own part with the ankle as its pivot
##      "nodes"    : one group per mesh node (models built from separate pieces,
##                   e.g. Sonic R); node origins become the pivots
##      "surfaces" : one group per mesh surface (OBJ groups/materials)
##    Every group gets a role (a part name, or "auto" = split that group by position,
##    or "ignore").
## 3. analyse()      - normalise (face -Z, stand on the ground, scale to height),
##                     measure the body and place the joints (editable afterwards)
## 4. build_rig()    - rig dictionary in the same format as assets/rigs/*.json
## 5. detect_paint() - colour zones the menu can recolour
## 6. export()       - assets/rigs/<id>.json (+ textures) and content/characters/<id>.json,
##                     which for a kart driver also carries its default clips (drive,
##                     hit) so it sits in the game and in the Animation Editor
##
## No skeleton, no skin, no animation clips: the game animates the parts itself.

const ROLES := ["hips", "torso", "head", "arm_upper_l", "arm_lower_l", "arm_upper_r", "arm_lower_r",
	"leg_upper_l", "leg_lower_l", "foot_l", "leg_upper_r", "leg_lower_r", "foot_r", "tail"]
const PARENT := {
	"hips": "", "torso": "hips", "head": "torso", "tail": "hips",
	"arm_upper_l": "torso", "arm_lower_l": "arm_upper_l",
	"arm_upper_r": "torso", "arm_lower_r": "arm_upper_r",
	"leg_upper_l": "hips", "leg_lower_l": "leg_upper_l", "foot_l": "leg_lower_l",
	"leg_upper_r": "hips", "leg_lower_r": "leg_upper_r", "foot_r": "leg_lower_r",
}
## Knee height as a fraction of the crotch height (see _place_joints).
const KNEE := 0.6
## Ankle height as a fraction of the knee height: where the shin ends and the foot -
## the whole shoe, up to its collar - begins. Each foot is its own part so it can be
## turned or nudged on its own instead of dragging the shin with it. On the shipped
## models the shoe's collar ring sits at 0.65-0.75 of the knee height, so 0.7 keeps
## the shoe whole; lower splits the sole off the shoe and leaves it with the shin.
const ANKLE := 0.7
const FACINGS := {"-Z": 0.0, "+Z": 180.0, "-X": -90.0, "+X": 90.0}
const SPLITS := ["auto", "nodes", "surfaces"]
const TYPE_DEFAULTS := {
	"runner": {"height": 1.1, "stats": {"speed": 4, "accel": 4, "handling": 4}},
	"kart": {"height": 0.85, "stats": {"speed": 4, "accel": 4, "handling": 4}},
}
const PALETTE := ["#e02020", "#2050ff", "#20b040", "#f0d020", "#f08020", "#c040ff", "#f0f0f0", "#202020", "#ff70b0", "#30d0d0"]
const HUE_NAMES := [[0.0, "Red"], [0.07, "Orange"], [0.14, "Yellow"], [0.25, "Lime"], [0.36, "Green"],
	[0.47, "Cyan"], [0.62, "Blue"], [0.76, "Purple"], [0.86, "Pink"], [0.96, "Red"]]

var source_path := ""
var id := ""
var display_name := ""
var type := "runner"
var facing := "+Z"
var height := 1.1
var split := "auto"
var pose := "auto"                ## "auto", "t_pose", "arms_down"

## Raw mesh pieces in source space: {node, surface, origin, pos, nrm, uv, idx, tex, alpha_tex}
var chunks: Array[Dictionary] = []
## Current grouping: {name, role, origin (Vector3, source space), has_origin, chunks: [int]}
var groups: Array[Dictionary] = []
## Joint positions in rig space (after normalising), role -> Vector3. Edit freely.
var joints := {}
var measure := {}                 ## what analyse() found (for the UI)
var norm := Transform3D.IDENTITY  ## source -> rig space
var scale := 1.0
var notes := PackedStringArray()   ## warnings for the UI

# per chunk, after analyse(): normalised positions and the part role per vertex
var _npos: Array[PackedVector3Array] = []
var _nnrm: Array[PackedVector3Array] = []
var _vrole: Array[PackedStringArray] = []


# ------------------------------------------------------------------ load

func load_source(path: String) -> String:
	source_path = path
	chunks.clear()
	if not ResourceLoader.exists(path):
		return "Not an imported resource: %s (put the model inside the project and let Godot import it)" % path
	var r: Resource = load(path)
	var mtl := _read_mtl_alpha(path)
	if r is Mesh:
		_add_mesh(r as Mesh, path.get_file().get_basename(), Transform3D.IDENTITY, Vector3.ZERO, mtl)
	elif r is PackedScene:
		var root: Node = (r as PackedScene).instantiate()
		_walk(root, Transform3D.IDENTITY, mtl)
		root.free()
	else:
		return "Unsupported resource type: %s" % r.get_class()
	if chunks.is_empty():
		return "No meshes found in %s" % path
	if id == "":
		id = path.get_file().get_basename().to_snake_case()
	if display_name == "":
		display_name = path.get_file().get_basename().capitalize()
	make_groups()
	return ""


func _walk(n: Node, parent_xf: Transform3D, mtl: Dictionary) -> void:
	var xf := parent_xf
	if n is Node3D:
		xf = parent_xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh and (n as MeshInstance3D).visible:
		_add_mesh((n as MeshInstance3D).mesh, String(n.name), xf, xf.origin, mtl, n as MeshInstance3D)
	for c in n.get_children():
		_walk(c, xf, mtl)


func _add_mesh(m: Mesh, node_name: String, xf: Transform3D, origin: Vector3, mtl: Dictionary, mi: MeshInstance3D = null) -> void:
	for s in m.get_surface_count():
		if m.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var a := m.surface_get_arrays(s)
		var pos: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = a[Mesh.ARRAY_NORMAL] if a[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV] if a[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if idx.is_empty():
			idx.resize(pos.size())
			for i in pos.size():
				idx[i] = i
		var wp := PackedVector3Array(); wp.resize(pos.size())
		var wn := PackedVector3Array(); wn.resize(pos.size())
		for i in pos.size():
			wp[i] = xf * pos[i]
			wn[i] = (xf.basis * (nrm[i] if i < nrm.size() else Vector3.UP)).normalized()
		if uv.size() != pos.size():
			uv.resize(pos.size())
		var mat: Material = mi.get_active_material(s) if mi else m.surface_get_material(s)
		var tex := ""
		var colour := Color.WHITE
		if mat is BaseMaterial3D:
			var bm := mat as BaseMaterial3D
			colour = bm.albedo_color
			if bm.albedo_texture:
				tex = bm.albedo_texture.resource_path
		var surf_name: String = (m as ArrayMesh).surface_get_name(s) if m is ArrayMesh else ""
		if surf_name == "" and mat:
			surf_name = mat.resource_name
		if surf_name == "":
			surf_name = "surface %d" % s
		var mat_name: String = mat.resource_name if mat else ""
		chunks.append({"node": node_name, "surface": surf_name, "origin": origin,
			"pos": wp, "nrm": wn, "uv": uv, "idx": idx, "tex": tex, "colour": colour,
			"alpha_tex": mtl.get(mat_name, "")})


## OBJ: the .mtl may ship opacity as a separate image (map_d) - Godot ignores it.
func _read_mtl_alpha(path: String) -> Dictionary:
	var out := {}
	if path.get_extension().to_lower() != "obj":
		return out
	var obj := FileAccess.open(path, FileAccess.READ)
	if obj == null:
		return out
	var mtl_file := ""
	while not obj.eof_reached():
		var l := obj.get_line().strip_edges()
		if l.begins_with("mtllib "):
			mtl_file = l.substr(7).strip_edges()
			break
	if mtl_file == "":
		return out
	var f := FileAccess.open(path.get_base_dir().path_join(mtl_file), FileAccess.READ)
	if f == null:
		return out
	var cur := ""
	while not f.eof_reached():
		var l := f.get_line().strip_edges()
		if l.begins_with("newmtl "):
			cur = l.substr(7).strip_edges()
		elif l.begins_with("map_d ") and cur != "":
			out[cur] = path.get_base_dir().path_join(l.substr(6).strip_edges())
	return out


# ------------------------------------------------------------------ groups

## Rebuild `groups` for the current split mode, guessing roles from names.
func make_groups() -> void:
	groups.clear()
	var by_name := {}
	for ci in chunks.size():
		var c: Dictionary = chunks[ci]
		var key := "model"
		if split == "nodes":
			key = c.node
		elif split == "surfaces":
			key = c.surface
		if not by_name.has(key):
			by_name[key] = groups.size()
			var role := "auto" if split == "auto" else guess_role(key)
			groups.append({"name": key, "role": role, "origin": c.origin, "has_origin": split == "nodes", "chunks": []})
		groups[by_name[key]].chunks.append(ci)


## Part role from a node/bone/material name ("LeftForeArm", "arm.L", "Head", ...).
static func guess_role(n: String) -> String:
	var s := n.to_lower().replace(" ", "_").replace("-", "_").replace(".", "_")
	var side := ""
	if s.begins_with("left") or s.ends_with("_l") or s.contains("_l_") or s.contains("left"):
		side = "_l"
	elif s.begins_with("right") or s.ends_with("_r") or s.contains("_r_") or s.contains("right"):
		side = "_r"
	if s.contains("head") or s.contains("hat") or s.contains("hair") or s.contains("face") or s.contains("eye") or s.contains("neck"):
		return "head"
	if s.contains("tail"):
		return "tail"
	if side != "":
		if s.contains("forearm") or s.contains("lowerarm") or s.contains("lower_arm") or s.contains("hand") or s.contains("glove") or s.contains("fist"):
			return "arm_lower" + side
		if s.contains("arm") or s.contains("shoulder"):
			return "arm_upper" + side
		if s.contains("shin") or s.contains("calf") or s.contains("lowerleg") or s.contains("lower_leg") or s.contains("foot") or s.contains("shoe") or s.contains("knee"):
			return "leg_lower" + side
		if s.contains("thigh") or s.contains("upleg") or s.contains("upperleg") or s.contains("upper_leg") or s.contains("leg"):
			return "leg_upper" + side
	if s.contains("hip") or s.contains("pelvis") or s.contains("waist"):
		return "hips"
	if s.contains("torso") or s.contains("chest") or s.contains("spine") or s.contains("body"):
		return "torso"
	return "auto"


# ------------------------------------------------------------------ analyse

func analyse() -> void:
	notes.clear()
	# 1. facing + scale + ground
	var rot := Basis(Vector3.UP, deg_to_rad(FACINGS.get(facing, 0.0)))
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for c in chunks:
		for p in c.pos:
			var q: Vector3 = rot * p
			lo = lo.min(q)
			hi = hi.max(q)
	scale = height / maxf(hi.y - lo.y, 1e-6)
	var centre := Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
	norm = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale), -centre * scale) * Transform3D(rot, Vector3.ZERO)
	_npos.clear(); _nnrm.clear()
	for c in chunks:
		var np := PackedVector3Array(); np.resize(c.pos.size())
		var nn := PackedVector3Array(); nn.resize(c.pos.size())
		for i in np.size():
			np[i] = norm * c.pos[i]
			nn[i] = rot * c.nrm[i]
		_npos.append(np)
		_nnrm.append(nn)
	# 2. measure the body from the auto-split vertices (whole model if none)
	_measure()
	# 3. joints
	_place_joints()
	classify()


## Front silhouette of the parts that are split automatically, rasterised to a grid
## (unit height), then: crotch, neck, leg spacing, torso width, arm pose and reach.
func _measure() -> void:
	var tris: Array[PackedVector2Array] = []
	var zsum := 0.0
	var zn := 0
	var any_auto := false
	for g in groups:
		if g.role == "auto":
			any_auto = true
	for g in groups:
		if any_auto and g.role != "auto":
			continue
		if g.role == "ignore":
			continue
		for ci in g.chunks:
			var np: PackedVector3Array = _npos[ci]
			var idx: PackedInt32Array = chunks[ci].idx
			for t in range(0, idx.size() - 2, 3):
				var tri := PackedVector2Array([_u(np[idx[t]]), _u(np[idx[t + 1]]), _u(np[idx[t + 2]])])
				tris.append(tri)
			for p in np:
				zsum += p.z
				zn += 1
	var R := 120
	var maxx := 0.05
	for tri in tris:
		for p in tri:
			maxx = maxf(maxx, absf(p.x))
	var C := int(ceil(maxx * R)) * 2 + 3
	var c0 := C / 2
	var grid := PackedByteArray(); grid.resize(R * C)
	for tri in tris:
		_raster(grid, R, C, c0, tri)
	var filled := func(r: int, c: int) -> bool:
		return r >= 0 and r < R and c >= 0 and c < C and grid[r * C + c] != 0
	# torso run (contiguous from the centre) and outer runs per row
	var run_l := PackedInt32Array(); run_l.resize(R)
	var run_r := PackedInt32Array(); run_r.resize(R)
	var row_max := PackedFloat32Array(); row_max.resize(R)
	for r in R:
		var k := 0
		while filled.call(r, c0 - k - 1):
			k += 1
		run_l[r] = k
		k = 0
		while filled.call(r, c0 + k + 1):
			k += 1
		run_r[r] = k
		var m := 0
		for c in C:
			if grid[r * C + c]:
				m = maxi(m, absi(c - c0))
		row_max[r] = m / float(R)
	var top := R - 1
	while top > 0 and row_max[top] == 0.0 and not filled.call(top, c0):
		top -= 1
	# crotch: walk down the centre line from mid-height
	var r0 := int(R * 0.6)
	while r0 > 0 and not filled.call(r0, c0):
		r0 -= 1
	var cr := r0
	while cr > 0 and filled.call(cr - 1, c0):
		cr -= 1
	var crotch := cr / float(R)
	if crotch < 0.12 or crotch > 0.6:
		crotch = 0.42                       # long dress / no visible gap: guess
		notes.append("No gap between the legs found - crotch guessed at 42% height.")
	var crow := int(crotch * R)
	# legs: mean |x| of filled cells just below the crotch
	var lx := 0.0
	var ln := 0
	for r in range(maxi(0, crow - int(R * 0.12)), maxi(1, crow - 1)):
		for c in C:
			if grid[r * C + c] and c != c0:
				lx += absf(c - c0) / float(R)
				ln += 1
	var leg_x := lx / ln if ln > 0 else 0.08
	# span
	var span := 0.0
	for r in range(crow, top + 1):
		span = maxf(span, row_max[r])
	var is_t := span > 0.33
	if pose == "t_pose":
		is_t = true
	elif pose == "arms_down":
		is_t = false
	var torso_w := PackedFloat32Array()
	var arm_rows: Array[int] = []
	var outer_x := 0.0
	var outer_n := 0
	for r in range(crow, top + 1):
		var half := maxf(run_l[r], run_r[r]) / float(R)
		if is_t:
			if row_max[r] > span * 0.8:
				arm_rows.append(r)
			else:
				torso_w.append(half)
		else:
			# a second run beyond a gap = an arm hanging beside the body
			var found := false
			for side in [-1, 1]:
				var start: int = (run_l[r] if side < 0 else run_r[r]) + 2
				for k in range(start, C / 2):
					if filled.call(r, c0 + side * k):
						found = true
						outer_x += k / float(R)
						outer_n += 1
						break
			if found and r < crow + int((top - crow) * 0.75):
				arm_rows.append(r)
			torso_w.append(half)
	torso_w.sort()
	var torso_half: float = torso_w[torso_w.size() * 3 / 10] if torso_w.size() > 0 else 0.1
	var neck := 0.0
	var shoulder_y := 0.0
	var shoulder_x := torso_half
	var hand_y := 0.0
	var arm_x := 0.0
	if is_t and not arm_rows.is_empty():
		var top_arm: int = arm_rows.max()
		var bot_arm: int = arm_rows.min()
		shoulder_y = (top_arm + bot_arm) * 0.5 / R
		neck = (top_arm + 2) / float(R)
		# shoulder: where the arm leaves the torso = torso width just under the arms
		shoulder_x = torso_half * 1.05
		hand_y = shoulder_y
	else:
		is_t = false
		# neck: narrowest torso row in the upper part
		var best := 1e9
		var nr := int(lerpf(crow, top, 0.45))
		for r in range(int(lerpf(crow, top, 0.3)), int(lerpf(crow, top, 0.75))):
			var w := float(run_l[r] + run_r[r])
			if w < best:
				best = w
				nr = r
		if not arm_rows.is_empty():
			var top_arm2: int = arm_rows.max()
			shoulder_y = (top_arm2 + 3) / float(R)
			hand_y = arm_rows.min() / float(R)
			arm_x = outer_x / maxf(outer_n, 1) + 0.02
			neck = minf(nr / float(R), shoulder_y + 0.03)
			shoulder_y = minf(shoulder_y, neck - 0.02)
		else:
			neck = nr / float(R)
			shoulder_y = neck - 0.05
			hand_y = crotch
			arm_x = torso_half + 0.03
			notes.append("Arms not separated from the body in the front view - arm joints are a guess, check them.")
		shoulder_x = arm_x
	measure = {
		"crotch": crotch, "neck": neck, "leg_x": leg_x, "span": span, "torso_half": torso_half,
		"pose": "t_pose" if is_t else "arms_down", "shoulder_y": shoulder_y, "shoulder_x": shoulder_x,
		"hand_y": hand_y, "arm_x": arm_x, "z": zsum / maxf(zn, 1) / height, "top": top / float(R),
	}


func _u(p: Vector3) -> Vector2:
	return Vector2(p.x / height, p.y / height)


func _raster(grid: PackedByteArray, R: int, C: int, c0: int, t: PackedVector2Array) -> void:
	var a := t[0] * R
	var b := t[1] * R
	var c := t[2] * R
	var x0 := int(floor(minf(a.x, minf(b.x, c.x)))) + c0
	var x1 := int(ceil(maxf(a.x, maxf(b.x, c.x)))) + c0
	var y0 := int(floor(minf(a.y, minf(b.y, c.y))))
	var y1 := int(ceil(maxf(a.y, maxf(b.y, c.y))))
	for p in [a, b, c]:
		var cx := int(round(p.x)) + c0
		var cy := int(p.y)
		if cy >= 0 and cy < R and cx >= 0 and cx < C:
			grid[cy * C + cx] = 1
	for y in range(maxi(y0, 0), mini(y1 + 1, R)):
		for x in range(maxi(x0, 0), mini(x1 + 1, C)):
			var q := Vector2(x - c0, y + 0.5)
			if Geometry2D.point_is_inside_triangle(q, a, b, c):
				grid[y * C + x] = 1


## Joint template from the measurements (rig space, metres).
func _place_joints() -> void:
	var m := measure
	var H := height
	var z := float(m.z) * H
	var cr := float(m.crotch) * H
	var nk := float(m.neck) * H
	var lx := float(m.leg_x) * H
	var j := {}
	j["hips"] = Vector3(0, cr + 0.02 * H, z)
	j["torso"] = Vector3(0, lerpf(cr, nk, 0.5), z)
	j["head"] = Vector3(0, nk, z)
	j["tail"] = Vector3(0, cr + 0.04 * H, z + 0.08 * H)
	for s in [["_l", -1.0], ["_r", 1.0]]:
		var sx: float = s[1]
		j["leg_upper" + s[0]] = Vector3(sx * lx, cr, z)
		j["leg_lower" + s[0]] = Vector3(sx * lx, cr * KNEE, z)
		j["foot" + s[0]] = Vector3(sx * lx, cr * KNEE * ANKLE, z)
		if m.pose == "t_pose":
			var shx := float(m.shoulder_x) * H
			var sy := float(m.shoulder_y) * H
			var reach := float(m.span) * H
			j["arm_upper" + s[0]] = Vector3(sx * shx, sy, z)
			j["arm_lower" + s[0]] = Vector3(sx * lerpf(shx, reach, 0.3), sy, z)
			j["hand" + s[0]] = Vector3(sx * reach, sy, z)
		else:
			var ax := float(m.arm_x) * H
			var sy2 := float(m.shoulder_y) * H
			var hy := float(m.hand_y) * H
			j["arm_upper" + s[0]] = Vector3(sx * ax, sy2, z)
			j["arm_lower" + s[0]] = Vector3(sx * ax, lerpf(sy2, hy, 0.45), z)
			j["hand" + s[0]] = Vector3(sx * ax, hy, z)
	# explicit groups with an origin (node mode) pin their own pivot
	for g in groups:
		if g.has_origin and g.role in ROLES:
			j[g.role] = norm * (g.origin as Vector3)
	joints = j


# ------------------------------------------------------------------ classify

## Part role for every vertex (explicit group roles, else position).
func classify() -> void:
	_vrole.clear()
	var role_of_chunk := {}
	for g in groups:
		for ci in g.chunks:
			role_of_chunk[ci] = g.role
	for ci in chunks.size():
		var np: PackedVector3Array = _npos[ci]
		var roles := PackedStringArray(); roles.resize(np.size())
		var gr: String = role_of_chunk.get(ci, "auto")
		for i in np.size():
			roles[i] = _auto_role(np[i]) if gr == "auto" else gr
		_vrole.append(roles)


func _auto_role(p: Vector3) -> String:
	var j := joints
	if p.y >= (j.head as Vector3).y:
		return "head"
	var q := Vector2(p.x, p.y)
	var limb_r := 0.02 * height
	var crotch := float(measure.get("crotch", 0.42)) * height
	# Below the crotch the body is only legs, and the side alone picks which one. A
	# nearest-pivot race ties at the centre line, so the inner surface of both legs
	# used to end up in one part (or in the hips), which fused the two legs together.
	# Below the ankle the foot is its own part (foot_l / foot_r), pivoted at the ankle.
	if p.y < crotch:
		var side := "_l" if p.x < 0.0 else "_r"
		var knee: float = (j["leg_lower" + side] as Vector3).y
		var ankle: float = (j["foot" + side] as Vector3).y
		var la: Vector3 = j["leg_upper" + side]
		var lb: Vector3 = j["leg_lower" + side]
		var lc: Vector3 = j["foot" + side]
		var d_leg := minf(_seg_dist(q, Vector2(la.x, la.y), Vector2(lb.x, lb.y)),
			_seg_dist(q, Vector2(lb.x, lb.y), Vector2(lc.x, 0.0))) - limb_r
		# A hand hanging beside the knee (arms modelled down) keeps its arm.
		var aa: Vector3 = j["arm_upper" + side]
		var ab: Vector3 = j["arm_lower" + side]
		var ac: Vector3 = j["hand" + side]
		var d_upper := _seg_dist(q, Vector2(aa.x, aa.y), Vector2(ab.x, ab.y))
		var d_lower := _seg_dist(q, Vector2(ab.x, ab.y), Vector2(ac.x, ac.y))
		if minf(d_upper, d_lower) - limb_r < d_leg:
			return ("arm_upper" if d_upper <= d_lower else "arm_lower") + side
		if p.y < ankle:
			return "foot" + side
		return ("leg_upper" if p.y >= knee else "leg_lower") + side
	# Above the crotch: torso capsule from the crotch to the neck, with the arms where
	# they leave the body.
	var th := float(measure.get("torso_half", 0.1)) * height
	var best := "torso"
	var best_d := _seg_dist(q, Vector2(0, crotch), Vector2(0, (j.head as Vector3).y)) - th
	for s in ["_l", "_r"]:
		var a: Vector3 = j["arm_upper" + s]
		var b: Vector3 = j["arm_lower" + s]
		var c: Vector3 = j["hand" + s]
		var d1 := _seg_dist(q, Vector2(a.x, a.y), Vector2(b.x, b.y)) - limb_r
		var d2 := _seg_dist(q, Vector2(b.x, b.y), Vector2(c.x, c.y)) - limb_r
		if d1 < best_d:
			best_d = d1
			best = "arm_upper" + s
		if d2 < best_d:
			best_d = d2
			best = "arm_lower" + s
	if best == "torso" and p.y < (j.torso as Vector3).y:
		best = "hips"
	return best


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Roles used by the current classification, parents first.
func used_roles() -> PackedStringArray:
	var used := {}
	for roles in _vrole:
		for r in roles:
			if r != "ignore":
				used[r] = true
	var out := PackedStringArray()
	for r in ROLES:
		if used.has(r):
			out.append(r)
	return out


func role_counts() -> Dictionary:
	var out := {}
	for roles in _vrole:
		for r in roles:
			out[r] = int(out.get(r, 0)) + 1
	return out


# ------------------------------------------------------------------ build

## Rig dictionary (format of assets/rigs/*.json). `tex_map` maps a chunk texture key
## to the path written into the rig.
func build_rig(tex_map: Dictionary = {}) -> Dictionary:
	var roles := used_roles()
	var parts: Array = []
	var index := {}
	for r in roles:
		var par := String(PARENT.get(r, ""))
		while par != "" and not index.has(par):
			par = String(PARENT.get(par, ""))
		var pv: Vector3 = joints.get(r, Vector3.ZERO)
		index[r] = parts.size()
		parts.append({"name": r, "pivot": [snappedf(pv.x, 0.0001), snappedf(pv.y, 0.0001), snappedf(pv.z, 0.0001)],
			"parent": index[par] if par != "" else -1})
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
		var pos := PackedFloat32Array(); var nrm := PackedFloat32Array(); var uv := PackedFloat32Array()
		var idx := PackedInt32Array(); var pa := PackedInt32Array()
		for ci in by_tex[key]:
			var np: PackedVector3Array = _npos[ci]
			var nn: PackedVector3Array = _nnrm[ci]
			var cu: PackedVector2Array = chunks[ci].uv
			var rr: PackedStringArray = _vrole[ci]
			var keep := PackedInt32Array(); keep.resize(np.size())
			for i in np.size():
				if rr[i] == "ignore":
					keep[i] = -1
					continue
				keep[i] = pa.size()
				for v in [np[i].x, np[i].y, np[i].z]:
					pos.append(snappedf(v, 0.00001))
				for v in [nn[i].x, nn[i].y, nn[i].z]:
					nrm.append(snappedf(v, 0.0001))
				uv.append(snappedf(cu[i].x, 0.00001))
				uv.append(snappedf(cu[i].y, 0.00001))
				pa.append(index[rr[i]])
				lo = lo.min(np[i]); hi = hi.max(np[i])
			var ci_idx: PackedInt32Array = chunks[ci].idx
			for t in range(0, ci_idx.size() - 2, 3):
				var a := keep[ci_idx[t]]; var b := keep[ci_idx[t + 1]]; var c := keep[ci_idx[t + 2]]
				if a >= 0 and b >= 0 and c >= 0:
					idx.append(a); idx.append(b); idx.append(c)
		if pa.is_empty():
			continue
		surfaces.append({"texture": tex_map.get(key, key), "alpha": "scissor", "cull": false,
			"pos": Array(pos), "nrm": Array(nrm), "uv": Array(uv), "idx": Array(idx),
			"pa": Array(pa), "pb": Array(pa), "w": []})
	_cut_centre(surfaces, roles)
	_seams(surfaces, roles)
	return {"name": id, "parts": parts, "surfaces": surfaces, "meta": {
		"source": source_path, "imported_with": "Character Importer", "scale": scale,
		"rest_pose": rest_pose_name(), "split": split,
		"aabb_min": [snappedf(lo.x, 0.0001), snappedf(lo.y, 0.0001), snappedf(lo.z, 0.0001)],
		"aabb_max": [snappedf(hi.x, 0.0001), snappedf(hi.y, 0.0001), snappedf(hi.z, 0.0001)]}}


## Cuts a model whose two shoes are welded across the centre line into two feet, in
## the exported rig itself, so the file works as it is - the game, the Animation Editor
## and any other tool - instead of being patched when it loads. The cut only splits
## faces that straddle the centre plane; no geometry is thrown away. See
## VertexRig.cut_welds, which older rigs get on load.
func _cut_centre(surfaces: Array, roles: PackedStringArray) -> void:
	var views: Array = []
	for s in surfaces:
		var n: int = s.pa.size()
		var pos := PackedVector3Array(); pos.resize(n)
		var nrm := PackedVector3Array(); nrm.resize(n)
		var uv := PackedVector2Array(); uv.resize(n)
		for i in n:
			pos[i] = Vector3(s.pos[i * 3], s.pos[i * 3 + 1], s.pos[i * 3 + 2])
			nrm[i] = Vector3(s.nrm[i * 3], s.nrm[i * 3 + 1], s.nrm[i * 3 + 2])
			uv[i] = Vector2(s.uv[i * 2], s.uv[i * 2 + 1])
		views.append({"pos": pos, "nrm": nrm, "uv": uv, "idx": PackedInt32Array(s.idx),
			"pa": PackedInt32Array(s.pa), "pb": PackedInt32Array(s.pb),
			"w": PackedFloat32Array(s.w)})
	VertexRig.cut_welds(views, roles, height)
	for i in surfaces.size():
		var s: Dictionary = surfaces[i]
		var v: Dictionary = views[i]
		s.pos = _flat3(v.pos)
		s.nrm = _flat3(v.nrm)
		s.uv = _flat2(v.uv)
		s.pa = Array(v.pa)
		s.pb = Array(v.pb)
		s.w = Array(v.w)
		s.idx = Array(v.idx)


## A packed vector array back to the flat float list the rig file stores.
static func _flat3(a: PackedVector3Array) -> Array:
	var out: Array = []
	out.resize(a.size() * 3)
	for i in a.size():
		out[i * 3] = a[i].x
		out[i * 3 + 1] = a[i].y
		out[i * 3 + 2] = a[i].z
	return out


static func _flat2(a: PackedVector2Array) -> Array:
	var out: Array = []
	out.resize(a.size() * 2)
	for i in a.size():
		out[i * 2] = a[i].x
		out[i * 2 + 1] = a[i].y
	return out


## A vertex position shared by two parts follows both 50/50 (no cracks at joints),
## except between the left and right of the same limb: those two copies keep their own
## part, so a shared inner-leg point cannot pull both legs together.
func _seams(surfaces: Array, roles: PackedStringArray) -> void:
	var parts_at := {}
	for s in surfaces:
		for k in s.pa.size():
			var key := Vector3i(roundi(s.pos[k * 3] * 200), roundi(s.pos[k * 3 + 1] * 200), roundi(s.pos[k * 3 + 2] * 200))
			if not parts_at.has(key):
				parts_at[key] = {}
			parts_at[key][s.pa[k]] = true
	for s in surfaces:
		var w: Array = []
		w.resize(s.pa.size())
		w.fill(0.0)
		for k in s.pa.size():
			var key := Vector3i(roundi(s.pos[k * 3] * 200), roundi(s.pos[k * 3 + 1] * 200), roundi(s.pos[k * 3 + 2] * 200))
			var ps: Dictionary = parts_at[key]
			if ps.size() < 2:
				continue
			var other := 1 << 30
			for q in ps:
				if q != s.pa[k] and _seam_blend(String(roles[q]), String(roles[s.pa[k]])):
					other = mini(other, int(q))
			if other < (1 << 30):
				s.pb[k] = other
				w[k] = 0.5
		s.w = w


## "l" / "r" for a left/right part, "" for a part on the centre line.
static func _side_of(role: String) -> String:
	if role.ends_with("_l"):
		return "l"
	if role.ends_with("_r"):
		return "r"
	return ""


## A seam joins two parts unless they are the two sides of the same limb (leg_upper_l
## and leg_upper_r, or a left hand sharing a point with the right leg): averaging those
## is what made the legs move as one piece.
static func _seam_blend(a: String, b: String) -> bool:
	var sa := _side_of(a)
	return not (sa != "" and sa != _side_of(b))


## "t_pose" (arms out sideways) or "arms_down", from the placed shoulder and elbow
## joints. The kart seated pose needs it to lift arms that hang down.
func rest_pose_name() -> String:
	var out := String(measure.get("pose", "arms_down"))
	if joints.has("arm_upper_l") and joints.has("arm_lower_l"):
		var d: Vector3 = joints.arm_lower_l - joints.arm_upper_l
		out = "t_pose" if absf(d.x) > absf(d.y) else "arms_down"
	return out


## Texture identity of a chunk: its texture path (+ opacity map), or its flat colour.
func tex_key(ci: int) -> String:
	var c: Dictionary = chunks[ci]
	if c.tex != "":
		return c.tex + ("|" + c.alpha_tex if c.alpha_tex != "" else "")
	return "colour:" + (c.colour as Color).to_html(false)


## The image for a texture key (opacity map merged into alpha; flat colours as 4x4).
static func key_image(key: String) -> Image:
	if key.begins_with("colour:"):
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.html(key.substr(7)))
		return img
	var parts := key.split("|")
	var img := _load_image(parts[0])
	if img == null:
		img = Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.MAGENTA)
	img.convert(Image.FORMAT_RGBA8)
	if parts.size() > 1:
		var a := _load_image(parts[1])
		if a:
			a.convert(Image.FORMAT_RGBA8)
			a.resize(img.get_width(), img.get_height(), Image.INTERPOLATE_NEAREST)
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					c.a = a.get_pixel(x, y).get_luminance()
					img.set_pixel(x, y, c)
	return img


static func _load_image(path: String) -> Image:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null and ResourceLoader.exists(path):
		var t: Texture2D = load(path)
		if t:
			img = t.get_image()
	if img and img.is_compressed():
		img.decompress()
	return img


# ------------------------------------------------------------------ paint zones

## Colour zones: the strongest saturated hues of the model's textures, weighted by
## how much of each texture the model actually uses.
func detect_paint(max_zones: int = 3) -> Dictionary:
	var bins := 36
	var hist := PackedFloat32Array(); hist.resize(bins)
	var acc: Array[Vector3] = []
	acc.resize(bins)
	acc.fill(Vector3.ZERO)
	var total := 0.0
	var seen := {}
	for ci in chunks.size():
		var key := tex_key(ci)
		if seen.has(key):
			continue
		seen[key] = true
		var img := key_image(key)
		var step := maxi(1, int(sqrt(img.get_width() * img.get_height() / 4096.0)))
		# sample at the model's UVs (covers what is visible) plus a coarse grid
		var samples: Array[Color] = []
		for cj in chunks.size():
			if tex_key(cj) != key:
				continue
			var cu: PackedVector2Array = chunks[cj].uv
			var cidx: PackedInt32Array = chunks[cj].idx
			for t in range(0, cidx.size() - 2, 3):
				var cen := (cu[cidx[t]] + cu[cidx[t + 1]] + cu[cidx[t + 2]]) / 3.0
				for p in [cen, cu[cidx[t]].lerp(cen, 0.5), cu[cidx[t + 1]].lerp(cen, 0.5), cu[cidx[t + 2]].lerp(cen, 0.5)]:
					var px := int(fposmod(p.x, 1.0) * img.get_width())
					var py := int(fposmod(p.y, 1.0) * img.get_height())
					samples.append(img.get_pixel(clampi(px, 0, img.get_width() - 1), clampi(py, 0, img.get_height() - 1)))
		if samples.is_empty():
			for y in range(0, img.get_height(), step):
				for x in range(0, img.get_width(), step):
					samples.append(img.get_pixel(x, y))
		for c in samples:
			if c.a < 0.5 or c.s < 0.45 or c.v < 0.25:
				continue
			var b := int(c.h * bins) % bins
			hist[b] += 1.0
			acc[b] += Vector3(c.r, c.g, c.b)
			total += 1.0
	var zones := {}
	if total <= 0.0:
		return zones
	var used := PackedByteArray(); used.resize(bins)
	for n in max_zones:
		var best := -1
		for b in bins:
			if not used[b] and (best < 0 or hist[b] > hist[best]):
				best = b
		if best < 0 or hist[best] < total * 0.06:
			break
		# grow the peak over neighbouring bins that still have weight
		var lo := best
		var hi := best
		while hist[posmod(lo - 1, bins)] > hist[best] * 0.15 and not used[posmod(lo - 1, bins)] and best - lo < 3:
			lo -= 1
		while hist[posmod(hi + 1, bins)] > hist[best] * 0.15 and not used[posmod(hi + 1, bins)] and hi - best < 3:
			hi += 1
		var sum := Vector3.ZERO
		var cnt := 0.0
		for b in range(lo, hi + 1):
			used[posmod(b, bins)] = 1
			sum += acc[posmod(b, bins)]
			cnt += hist[posmod(b, bins)]
		for b in [posmod(lo - 1, bins), posmod(hi + 1, bins)]:
			used[b] = 1                     # keep zones apart
		var col := Color(sum.x / cnt, sum.y / cnt, sum.z / cnt)
		var name := hue_name(col.h) if col.v > 0.5 else "Dark " + hue_name(col.h).to_lower()
		var key := name.to_lower()
		while zones.has(key):
			key += "_2"
		var presets: Array = [col.to_html(false)]
		for p in PALETTE:
			if absf(Color.html(p).h - col.h) > 0.06 or Color.html(p).s < 0.2:
				presets.append(p)
		zones[key] = {"label": name, "surface": "", "src": "#" + col.to_html(false),
			"tol": clampf((hi - lo + 1) * 0.5 / bins + 0.03, 0.06, 0.1),
			"default": "#" + col.to_html(false), "presets": presets.slice(0, 6).map(func(x): return "#" + String(x).trim_prefix("#"))}
	return zones


static func hue_name(h: float) -> String:
	var best := "Colour"
	var bd := 9.0
	for e in HUE_NAMES:
		var d := absf(h - float(e[0]))
		if d < bd:
			bd = d
			best = e[1]
	return best


# ------------------------------------------------------------------ export

## Writes assets/rigs/<id>.json, its textures and content/characters/<id>.json.
## `paint` = zones (detect_paint() or edited). Returns the character file path.
func export(paint: Dictionary, rig_dir: String = "res://assets/rigs/", char_dir: String = "res://content/characters/") -> String:
	var tex_map := save_textures(rig_dir + "tex/", id)
	var rig := build_rig(tex_map)
	_write_json(rig_dir + id + ".json", rig, false)
	# Face thumbnail for the character menu, drawn from the rig itself.
	var icon_path := char_dir + id + ".png"
	var icon := RigIcon.render(rig, 32)
	var def := {
		"id": id, "name": display_name, "type": type, "rig": rig_dir + id + ".json",
		"icon": icon_path,
		"colour": paint.values()[0].src if not paint.is_empty() else "#c0c0c0",
		"paint": paint, "stats": TYPE_DEFAULTS[type].stats.duplicate(),
	}
	if type == "kart":
		def["seat"] = [0.0, 0.05, 0.16]
		def["default_kart"] = "standard"
	var path := char_dir + id + ".json"
	var old: Variant = null
	if FileAccess.file_exists(path):
		old = JSON.parse_string(FileAccess.open(path, FileAccess.READ).get_as_text())
	if old is Dictionary:
		# keep hand-tuned fields of an existing definition (clips from the Animation Editor too)
		for k in ["stats", "params", "seat", "default_kart", "animations"]:
			if old.has(k):
				def[k] = old[k]
	# A kart driver sits: a new kart character gets its own default clips (seated
	# "drive" and "hit"), so the Animation Editor opens on the pose the game uses.
	# Clips already saved for the character are the author's work and are kept.
	if type == "kart" and not def.has("animations"):
		def["animations"] = default_animations()
	_write_json(path, def, true)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(char_dir))
	icon.save_png(ProjectSettings.globalize_path(icon_path))
	return path


## Re-renders the face icon of every character in `char_dir` and adds it to the
## definition - for characters imported before icons existed. Returns how many
## were written.
static func make_icons(char_dir: String = "res://content/characters/") -> int:
	var n := 0
	var d := DirAccess.open(char_dir)
	if d == null:
		return 0
	var files := Array(d.get_files())
	files.sort()
	for f in files:
		if not String(f).ends_with(".json"):
			continue
		var path := char_dir + String(f)
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (parsed is Dictionary):
			continue
		var def: Dictionary = parsed
		var rig_path := String(def.get("rig", ""))
		if rig_path == "" or not FileAccess.file_exists(rig_path):
			continue
		var rig: Variant = JSON.parse_string(FileAccess.get_file_as_string(rig_path))
		if not (rig is Dictionary):
			continue
		var icon_path := char_dir + String(def.get("id", String(f).get_basename())) + ".png"
		var icon := RigIcon.render(rig, 32)
		icon.save_png(ProjectSettings.globalize_path(icon_path))
		def["icon"] = icon_path
		_write_json(path, def, true)
		n += 1
	return n


## Copies/merges the textures to `dir` as PNGs; returns key -> res:// path.
func save_textures(dir: String, prefix: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var out := {}
	var n := 0
	for ci in chunks.size():
		var key := tex_key(ci)
		if out.has(key):
			continue
		var img := key_image(key)
		var base := key.split("|")[0].get_file().get_basename().to_snake_case() if not key.begins_with("colour:") else "colour"
		var path := "%s%s_%d_%s.png" % [dir, prefix, n, base]
		img.save_png(ProjectSettings.globalize_path(path))
		out[key] = path
		n += 1
	return out


## Default animation set of a kart driver - its own, not the runner's idle/run/jump/
## hit. "drive" holds the seated pose the game seats every driver in and "hit" the
## hit-stun flinch; both are static poses (steering, leaning and the hop are layered on
## top by KartVisual), so a new kart character opens in the Animation Editor already
## sitting, with every part keyable.
func default_animations() -> Dictionary:
	var arm_rest := -PI * 0.5 if rest_pose_name() == "arms_down" else 0.0
	var hit_len := 0.5
	var drive_keys := [{"t": 0.0, "pose": _pose_json(KartVisual.default_drive_pose(arm_rest))}]
	var hit_keys: Array = []
	for i in 13:
		var t := hit_len * float(i) / 12.0
		hit_keys.append({"t": snappedf(t, 0.001),
			"pose": _pose_json(KartVisual.default_hit_pose(arm_rest, t))})
	return {
		"drive": {"length": 1.0, "loop": true, "fps": 24.0, "keys": drive_keys},
		"hit": {"length": hit_len, "loop": false, "fps": 24.0, "keys": hit_keys},
	}


## A pose dictionary (part -> Vector3 or {rot, off}) as the key data RigAnim reads.
static func _pose_json(pose: Dictionary) -> Dictionary:
	var out := {}
	for part in pose:
		var v: Variant = pose[part]
		var rot := Vector3.ZERO
		var off := Vector3.ZERO
		if v is Vector3:
			rot = v
		elif v is Dictionary:
			rot = v.get("rot", Vector3.ZERO)
			off = v.get("off", Vector3.ZERO)
		var rec := {"rot": [snappedf(rot.x, 0.0001), snappedf(rot.y, 0.0001), snappedf(rot.z, 0.0001)]}
		if not off.is_zero_approx():
			rec["off"] = [snappedf(off.x, 0.0001), snappedf(off.y, 0.0001), snappedf(off.z, 0.0001)]
		out[String(part)] = rec
	return out


static func _write_json(path: String, data: Dictionary, pretty: bool) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t" if pretty else ""))
	f.close()
