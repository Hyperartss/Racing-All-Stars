class_name BurstFx
extends Node3D
## A short pop of flat-coloured chunks (item hits, explosions, box breaks).

var _parts: Array = []
var _t := 0.0
var duration := 0.5


static func spawn(parent: Node, at: Vector3, colour: Color, count: int = 7, power: float = 5.0) -> BurstFx:
	if parent == null or not parent.is_inside_tree():
		return null
	var fx := BurstFx.new()
	parent.add_child(fx)
	fx.global_position = at
	var mat := TrackProps.material(colour)
	for k in count:
		var mi := MeshInstance3D.new()
		mi.mesh = TrackProps._box(Vector3.ONE * 0.18)
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fx.add_child(mi)
		var dir := Vector3(randf_range(-1, 1), randf_range(0.4, 1.2), randf_range(-1, 1)).normalized()
		fx._parts.append([mi, dir * power * randf_range(0.6, 1.2)])
	return fx


static func explosion(parent: Node, at: Vector3, r: float) -> void:
	var fx := spawn(parent, at, Color(1.0, 0.55, 0.1), 14, r * 2.2)
	if fx == null:
		return
	fx.duration = 0.7
	var ball := MeshInstance3D.new()
	ball.mesh = TrackProps._ball(r * 0.5, 8, 5)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.85, 0.3, 0.6)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ball.material_override = m
	fx.add_child(ball)
	fx._parts.append([ball, Vector3.ZERO])


func _process(delta: float) -> void:
	_t += delta
	for p in _parts:
		var mi: MeshInstance3D = p[0]
		var v: Vector3 = p[1]
		if v == Vector3.ZERO:
			mi.scale = Vector3.ONE * (1.0 + _t * 3.0)
			continue
		v.y -= 18.0 * delta
		p[1] = v
		mi.position += v * delta
		mi.rotation += Vector3(4, 3, 2) * delta
	if _t > duration:
		queue_free()
