@tool
class_name ItemModels
extends RefCounted
## Low-poly models for items and track objects, built from flat-coloured primitives
## (the same look as TrackProps), plus loading of your own models.
##
## Every item / object definition may name `"model": "res://..."` (a .glb/.gltf/.tscn
## scene, an imported .obj mesh, or any Mesh/PackedScene resource) and `"model_scale"`.
## Without one, `"shape"` picks a built-in model below and `"colour"` tints it.

const SHAPES := ["mushroom", "banana", "shell", "spiny", "bomb", "star", "bullet", "bolt",
	"fake_box", "ink", "shield", "ring", "magnet", "box", "token", "emerald", "spring",
	"dash", "chevron", "orb"]


static func build(shape: String, colour: Color, model_path: String = "", model_scale: float = 1.0) -> Node3D:
	if model_path != "":
		var custom := load_model(model_path)
		if custom != null:
			custom.scale *= maxf(model_scale, 0.001)
			return custom
		push_warning("ItemModels: could not load model %s - using the built-in '%s'" % [model_path, shape])
	var root := Node3D.new()
	root.name = shape if shape != "" else "model"
	match shape:
		"mushroom":
			_part(root, _cyl(0.16, 0.2, 0.3), Color("f2ead0"), Vector3(0, 0.15, 0))
			_part(root, _ball(0.32, 8, 4), colour, Vector3(0, 0.36, 0)).scale = Vector3(1, 0.7, 1)
			for k in 3:
				var a := TAU * k / 3.0
				_part(root, _ball(0.08, 5, 3), Color.WHITE, Vector3(cos(a) * 0.2, 0.5, sin(a) * 0.2))
		"banana":
			for k in 4:
				var t := float(k) / 3.0
				var p := _part(root, _cyl(0.07, 0.09, 0.22, 6), colour, Vector3(sin(t * 2.2 - 1.1) * 0.22, 0.12 + t * 0.12, 0),
					Vector3(0, 0, -60.0 + t * 120.0))
				p.scale = Vector3(1, 1, 1)
			_part(root, _box(Vector3(0.06, 0.08, 0.06)), Color("5a3a1a"), Vector3(0.26, 0.28, 0))
		"shell", "spiny":
			var dome := _part(root, _ball(0.32, 8, 4), colour, Vector3(0, 0.22, 0))
			dome.scale = Vector3(1, 0.75, 1)
			_part(root, _cyl(0.33, 0.33, 0.08, 8), Color("f4f0e0"), Vector3(0, 0.12, 0))
			if shape == "spiny":
				for k in 6:
					var a := TAU * k / 6.0
					_part(root, _cyl(0.0, 0.07, 0.22, 4), Color.WHITE, Vector3(cos(a) * 0.2, 0.42, sin(a) * 0.2),
						Vector3(sin(a) * 30.0, 0, -cos(a) * 30.0))
				_part(root, _box(Vector3(0.3, 0.06, 0.3)), Color("70d8ff"), Vector3(0, 0.5, 0), Vector3(0, 45, 0))
		"bomb":
			_part(root, _ball(0.34, 8, 5), colour, Vector3(0, 0.34, 0))
			_part(root, _cyl(0.06, 0.06, 0.14, 5), Color("c0c0c0"), Vector3(0, 0.72, 0))
			_part(root, _box(Vector3(0.05, 0.12, 0.05)), Color("ff9020"), Vector3(0, 0.84, 0))
			for k in 2:
				_part(root, _box(Vector3(0.12, 0.1, 0.06)), Color("f0d030"), Vector3(-0.1 + 0.2 * k, 0.04, 0))
		"star":
			var s := _part(root, _star_mesh(0.42, 0.18, 0.14), colour, Vector3(0, 0.45, 0))
			s.rotation_degrees.x = 90.0
		"bullet":
			_part(root, _cyl(0.32, 0.32, 0.8, 8), colour, Vector3(0, 0.4, 0), Vector3(90, 0, 0))
			_part(root, _ball(0.32, 8, 4), colour, Vector3(0, 0.4, -0.4))
			_part(root, _cyl(0.36, 0.36, 0.08, 8), Color("d0d0d0"), Vector3(0, 0.4, 0.38), Vector3(90, 0, 0))
			for side in [-1, 1]:
				_part(root, _box(Vector3(0.08, 0.1, 0.06)), Color.WHITE, Vector3(0.15 * side, 0.55, -0.55))
		"bolt":
			_part(root, _box(Vector3(0.12, 0.42, 0.08)), colour, Vector3(0.06, 0.62, 0), Vector3(0, 0, -20))
			_part(root, _box(Vector3(0.3, 0.08, 0.08)), colour, Vector3(0, 0.42, 0))
			_part(root, _box(Vector3(0.12, 0.42, 0.08)), colour, Vector3(-0.06, 0.22, 0), Vector3(0, 0, -20))
		"fake_box", "box":
			var bx := _part(root, _box(Vector3(0.9, 0.9, 0.9)), colour, Vector3(0, 0.75, 0), Vector3(25, 45, 0))
			bx.material_override = _clear_mat(colour, 0.55)
			var q := Label3D.new()
			q.text = "?"
			q.font_size = 96
			q.pixel_size = 0.008
			q.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			q.modulate = Color(1, 1, 1) if shape == "box" else Color(1, 0.6, 0.6)
			q.outline_size = 12
			q.position = Vector3(0, 0.75, 0)
			q.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			root.add_child(q)
		"ink":
			_part(root, _ball(0.3, 6, 4), colour, Vector3(0, 0.55, 0)).scale = Vector3(0.8, 1.2, 0.8)
			for k in 4:
				var a := TAU * k / 4.0
				_part(root, _cyl(0.05, 0.08, 0.4, 4), colour, Vector3(cos(a) * 0.15, 0.2, sin(a) * 0.15))
		"shield":
			var sh := _part(root, _ball(0.6, 10, 6), colour, Vector3(0, 0.6, 0))
			sh.material_override = _clear_mat(colour, 0.35)
		"ring":
			var ring := TorusMesh.new()
			ring.inner_radius = 0.28
			ring.outer_radius = 0.4
			ring.rings = 10
			ring.ring_segments = 4
			_part(root, ring, colour, Vector3(0, 0.7, 0), Vector3(90, 0, 0))
		"magnet":
			_part(root, _box(Vector3(0.14, 0.4, 0.14)), colour, Vector3(-0.18, 0.45, 0))
			_part(root, _box(Vector3(0.14, 0.4, 0.14)), colour, Vector3(0.18, 0.45, 0))
			_part(root, _box(Vector3(0.5, 0.14, 0.14)), colour, Vector3(0, 0.7, 0))
			_part(root, _box(Vector3(0.15, 0.1, 0.15)), Color("e0e0e0"), Vector3(-0.18, 0.22, 0))
			_part(root, _box(Vector3(0.15, 0.1, 0.15)), Color("e0e0e0"), Vector3(0.18, 0.22, 0))
		"token":
			_part(root, _cyl(0.45, 0.45, 0.08, 12), colour, Vector3(0, 0.9, 0), Vector3(90, 0, 0))
			var st := _part(root, _star_mesh(0.3, 0.13, 0.1), colour.lightened(0.35), Vector3(0, 0.9, 0.05))
			st.rotation_degrees.x = 0.0
		"emerald":
			var gem := MeshInstance3D.new()
			gem.mesh = _gem_mesh(0.42, 0.55)
			var gm := _clear_mat(colour, 0.82)
			gm.emission_enabled = true
			gm.emission = colour
			gm.emission_energy_multiplier = 0.35
			gem.material_override = gm
			gem.position = Vector3(0, 0.9, 0)
			gem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(gem)
		"spring":
			_part(root, _cyl(0.7, 0.75, 0.12, 8), Color("404040"), Vector3(0, 0.06, 0))
			for k in 3:
				_part(root, _cyl(0.45, 0.45, 0.08, 8), Color("d0d0d0"), Vector3(0, 0.18 + k * 0.12, 0))
			_part(root, _cyl(0.7, 0.7, 0.14, 8), colour, Vector3(0, 0.55, 0))
		"dash":
			_part(root, _box(Vector3(2.4, 0.05, 3.0)), Color("303040"), Vector3(0, 0.025, 0))
			for k in 3:
				var arm_l := _part(root, _box(Vector3(1.0, 0.06, 0.28)), colour, Vector3(-0.42, 0.05, -0.8 + k * 0.8), Vector3(0, -40, 0))
				arm_l.scale = Vector3.ONE
				_part(root, _box(Vector3(1.0, 0.06, 0.28)), colour, Vector3(0.42, 0.05, -0.8 + k * 0.8), Vector3(0, 40, 0))
		"chevron":
			for k in 2:
				_part(root, _box(Vector3(1.2, 0.05, 0.3)), colour, Vector3(-0.5, 0.04, -0.4 + k * 0.8), Vector3(0, -35, 0))
				_part(root, _box(Vector3(1.2, 0.05, 0.3)), colour, Vector3(0.5, 0.04, -0.4 + k * 0.8), Vector3(0, 35, 0))
		_:
			_part(root, _ball(0.35, 8, 5), colour, Vector3(0, 0.5, 0))
	return root


## Loads a user model: PackedScene (.glb/.gltf/.tscn/.dae/.fbx) or Mesh (.obj/.mesh/.res).
static func load_model(path: String) -> Node3D:
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	if res is PackedScene:
		var inst: Node = (res as PackedScene).instantiate()
		if inst is Node3D:
			_retro_filter(inst)
			return inst
		var holder := Node3D.new()
		holder.add_child(inst)
		return holder
	if res is Mesh:
		var root := Node3D.new()
		var mi := MeshInstance3D.new()
		mi.mesh = res
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
		_retro_filter(root)
		return root
	return null


## Nearest (or the current look's) texture filter on every material in an imported model.
static func _retro_filter(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if mi.mesh != null:
			for si in mi.mesh.get_surface_count():
				var m := mi.get_active_material(si)
				if m is BaseMaterial3D:
					var mm := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
					mm.texture_filter = RetroLook.base_filter()
					mm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
					mi.set_surface_override_material(si, mm)
	for c in n.get_children():
		_retro_filter(c)


# --- helpers ------------------------------------------------------------------------

static func _part(parent: Node3D, mesh: Mesh, col: Color, pos := Vector3.ZERO, rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = TrackProps.material(col)
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _clear_mat(c: Color, a: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c.r, c.g, c.b, a)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if RetroLook.current.get("mesh_transparency", false):
		# Saturn-style "mesh" transparency: a checkerboard of opaque pixels.
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	else:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


static func _cyl(top: float, bottom: float, h: float, seg := 6) -> CylinderMesh:
	return TrackProps._cyl(top, bottom, h, seg)


static func _box(size: Vector3) -> BoxMesh:
	return TrackProps._box(size)


static func _ball(r: float, seg := 6, rings := 4) -> SphereMesh:
	return TrackProps._ball(r, seg, rings)


## Flat 5-point star extruded by `depth`, in the XY plane.
static func _star_mesh(outer: float, inner: float, depth: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts: Array[Vector2] = []
	for k in 10:
		var a := PI * 0.5 + TAU * k / 10.0
		var r := outer if k % 2 == 0 else inner
		pts.append(Vector2(cos(a), sin(a)) * r)
	for side in [-1.0, 1.0]:
		var z: float = depth * 0.5 * side
		for k in 10:
			var a2: Vector2 = pts[k]
			var b2: Vector2 = pts[(k + 1) % 10]
			st.set_normal(Vector3(0, 0, side))
			st.add_vertex(Vector3(0, 0, z))
			st.add_vertex(Vector3(a2.x, a2.y, z))
			st.add_vertex(Vector3(b2.x, b2.y, z))
	for k in 10:
		var a3: Vector2 = pts[k]
		var b3: Vector2 = pts[(k + 1) % 10]
		var h := depth * 0.5
		var n := Vector3(b3.y - a3.y, a3.x - b3.x, 0).normalized()
		st.set_normal(n)
		st.add_vertex(Vector3(a3.x, a3.y, -h))
		st.add_vertex(Vector3(b3.x, b3.y, -h))
		st.add_vertex(Vector3(b3.x, b3.y, h))
		st.add_vertex(Vector3(a3.x, a3.y, -h))
		st.add_vertex(Vector3(b3.x, b3.y, h))
		st.add_vertex(Vector3(a3.x, a3.y, h))
	return st.commit()


## Chaos Emerald-ish gem: a cut top and a pointed base.
static func _gem_mesh(r: float, h: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 6
	var top := h * 0.22
	var mid := 0.0
	var bottom := -h * 0.55
	for k in n:
		var a0 := TAU * k / n
		var a1 := TAU * (k + 1) / n
		var p0 := Vector3(cos(a0) * r, mid, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, mid, sin(a1) * r)
		var t0 := Vector3(cos(a0) * r * 0.55, top, sin(a0) * r * 0.55)
		var t1 := Vector3(cos(a1) * r * 0.55, top, sin(a1) * r * 0.55)
		var tri := func(a: Vector3, b: Vector3, c: Vector3) -> void:
			st.set_normal((b - a).cross(c - a).normalized())
			st.add_vertex(a)
			st.add_vertex(b)
			st.add_vertex(c)
		tri.call(p0, t0, t1)
		tri.call(p0, t1, p1)
		tri.call(Vector3(0, top, 0), t1, t0)
		tri.call(p0, p1, Vector3(0, bottom, 0))
	return st.commit()
