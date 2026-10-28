class_name TrackProps
extends RefCounted
## Low-poly decoration props for the merged maps, shared by the Map Editor dock and
## the game (Track spawns whatever assets/maps/<id>/decor.json lists), so what you
## place in the editor is exactly what you drive past.
##
## One prop entry is {"type", "pos": [x, y, z], "yaw": degrees, "scale": n,
## "tint": "#rrggbb"}. A prop stands on its pos (y = base of the prop, so it sits on
## the road/scenery it was dropped on) and has no collision - it is decoration.

const TYPES := ["tree", "pine", "palm", "bush", "rock", "cone", "lamp", "sign"]
const LABEL := {
	"tree": "Tree",
	"pine": "Pine",
	"palm": "Palm",
	"bush": "Bush",
	"rock": "Rock",
	"cone": "Traffic cone",
	"lamp": "Lamp post",
	"sign": "Sign",
}
## Main tint per type (the colour the editor's colour picker starts from).
const TINT := {
	"tree": "#2f7a3a",
	"pine": "#275c33",
	"palm": "#4f9b45",
	"bush": "#3c7a3f",
	"rock": "#8c8b86",
	"cone": "#e2622a",
	"lamp": "#ffe9a0",
	"sign": "#d8d3c4",
}
## Bounding size (x = radius, y = height) used for picking, framing and the
## selection box in the editor.
const SIZE := {
	"tree": Vector2(1.5, 5.0),
	"pine": Vector2(1.3, 5.1),
	"palm": Vector2(2.1, 4.9),
	"bush": Vector2(1.0, 1.2),
	"rock": Vector2(1.0, 1.0),
	"cone": Vector2(0.4, 0.9),
	"lamp": Vector2(0.5, 3.8),
	"sign": Vector2(0.9, 2.4),
}

const BARK := Color("6b4a2b")
const DARK := Color("3f4550")

static var _mats := {}


## Flat, unfiltered, unlit-ish material - the same look as the baked course.
static func material(c: Color) -> StandardMaterial3D:
	var key := c.to_html(true)
	var m: StandardMaterial3D = _mats.get(key)
	if m == null:
		m = StandardMaterial3D.new()
		m.albedo_color = c
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.roughness = 1.0
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mats[key] = m
	return m


static func default_tint(type: String) -> Color:
	return Color(String(TINT.get(type, "#ffffff")))


## A fresh Node3D for `type`, built from flat-coloured primitives.
static func build(type: String, tint: Color) -> Node3D:
	var root := Node3D.new()
	root.name = type if type != "" else "prop"
	match type:
		"tree":
			_tree(root, tint)
		"pine":
			_pine(root, tint)
		"palm":
			_palm(root, tint)
		"bush":
			_bush(root, tint)
		"rock":
			_rock(root, tint)
		"cone":
			_cone(root, tint)
		"lamp":
			_lamp(root, tint)
		"sign":
			_sign(root, tint)
		_:
			_tree(root, tint)
	return root


## The node for one decor.json entry.
static func make(e: Dictionary) -> Node3D:
	var type := String(e.get("type", "tree"))
	var n := build(type, Color(String(e.get("tint", TINT.get(type, "#ffffff")))))
	n.name = "Prop_" + type
	n.position = vec(e.get("pos", [0.0, 0.0, 0.0]))
	n.rotation.y = deg_to_rad(float(e.get("yaw", 0.0)))
	n.scale = Vector3.ONE * maxf(float(e.get("scale", 1.0)), 0.02)
	return n


## Spawns every entry of a decor "props" list under `parent`.
static func spawn(parent: Node3D, props: Array) -> void:
	for e in props:
		if e is Dictionary:
			parent.add_child(make(e))


static func vec(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO


# --- parts ------------------------------------------------------------------------

static func _part(parent: Node3D, mesh: Mesh, col: Color, pos := Vector3.ZERO,
		rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material(col)
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _cyl(top: float, bottom: float, h: float, seg := 6) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = h
	m.radial_segments = maxi(seg, 3)
	m.rings = 1
	return m


static func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


static func _ball(r: float, seg := 6, rings := 4) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = maxi(seg, 4)
	m.rings = maxi(rings, 2)
	return m


# --- the props --------------------------------------------------------------------

static func _tree(root: Node3D, tint: Color) -> void:
	_part(root, _cyl(0.19, 0.30, 2.0), BARK, Vector3(0, 1.0, 0))
	_part(root, _cyl(0.0, 1.50, 1.9, 7), tint, Vector3(0, 2.55, 0))
	_part(root, _cyl(0.0, 1.15, 1.7, 7), tint.darkened(0.08), Vector3(0, 3.45, 0))
	_part(root, _cyl(0.0, 0.80, 1.4, 7), tint.lightened(0.06), Vector3(0, 4.3, 0))


static func _pine(root: Node3D, tint: Color) -> void:
	_part(root, _cyl(0.14, 0.22, 1.2), BARK, Vector3(0, 0.6, 0))
	var ys := [1.7, 2.7, 3.6, 4.4]
	var rs := [1.30, 1.05, 0.80, 0.50]
	for i in 4:
		_part(root, _cyl(0.0, rs[i], 1.4, 7), tint.darkened(0.05 * i), Vector3(0, ys[i], 0))


static func _palm(root: Node3D, tint: Color) -> void:
	_part(root, _cyl(0.16, 0.26, 4.4), Color("a88a5c"), Vector3(0.18, 2.15, 0), Vector3(0, 0, -4))
	for k in 7:
		var arm := Node3D.new()
		arm.name = "Frond"
		arm.position = Vector3(0.3, 4.35, 0)
		arm.rotation_degrees = Vector3(0, 360.0 * k / 7.0, -16)
		root.add_child(arm)
		_part(arm, _box(Vector3(2.1, 0.05, 0.55)), tint, Vector3(1.05, 0, 0), Vector3(0, 0, -8))
	_part(root, _ball(0.22, 5, 3), BARK, Vector3(0.2, 4.2, 0.3))
	_part(root, _ball(0.20, 5, 3), BARK, Vector3(-0.1, 4.15, -0.25))


static func _bush(root: Node3D, tint: Color) -> void:
	var a := _part(root, _ball(0.78, 6, 4), tint, Vector3(0, 0.55, 0))
	a.scale = Vector3(1.0, 0.72, 1.0)
	var b := _part(root, _ball(0.52, 6, 4), tint.lightened(0.05), Vector3(0.55, 0.4, 0.2))
	b.scale = Vector3(1.0, 0.75, 1.0)
	var c := _part(root, _ball(0.45, 6, 4), tint.darkened(0.06), Vector3(-0.45, 0.35, -0.25))
	c.scale = Vector3(1.0, 0.8, 1.0)


static func _rock(root: Node3D, tint: Color) -> void:
	var a := _part(root, _ball(0.72, 5, 3), tint, Vector3(0, 0.42, 0), Vector3(0, 18, 0))
	a.scale = Vector3(1.15, 0.62, 1.0)
	var b := _part(root, _ball(0.46, 5, 3), tint.darkened(0.12), Vector3(0.55, 0.26, 0.22), Vector3(0, -35, 0))
	b.scale = Vector3(1.0, 0.6, 0.9)


static func _cone(root: Node3D, tint: Color) -> void:
	_part(root, _box(Vector3(0.52, 0.06, 0.52)), Color("3a3a3a"), Vector3(0, 0.03, 0))
	_part(root, _cyl(0.0, 0.30, 0.80, 7), tint, Vector3(0, 0.44, 0))
	_part(root, _cyl(0.12, 0.165, 0.14, 7), Color("f2f0e6"), Vector3(0, 0.47, 0))


static func _lamp(root: Node3D, tint: Color) -> void:
	_part(root, _cyl(0.09, 0.13, 3.6), DARK, Vector3(0, 1.8, 0))
	_part(root, _box(Vector3(0.5, 0.10, 0.5)), DARK, Vector3(0, 3.55, 0))
	# Own material (not the shared cache) so only the lamp glows.
	var m := material(tint).duplicate() as StandardMaterial3D
	m.emission_enabled = true
	m.emission = tint
	m.emission_energy_multiplier = 0.6
	var head := MeshInstance3D.new()
	head.mesh = _box(Vector3(0.42, 0.34, 0.42))
	head.material_override = m
	head.position = Vector3(0, 3.36, 0)
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)


static func _sign(root: Node3D, tint: Color) -> void:
	_part(root, _cyl(0.07, 0.07, 1.9, 5), BARK, Vector3(0, 0.95, 0))
	_part(root, _box(Vector3(1.3, 0.75, 0.08)), tint, Vector3(0, 1.95, 0))
	_part(root, _box(Vector3(0.95, 0.12, 0.10)), Color("c23b2e"), Vector3(0, 1.95, 0.02))
