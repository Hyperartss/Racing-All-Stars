class_name ScatterRing
extends ItemEntity
## A ring knocked loose by a hit: it flies out, bounces, and anyone can grab it back
## for a few seconds (it blinks before it goes).

var _vel := Vector3.ZERO
var _grounded := false


static func burst(trk: Track, at: Vector3, count: int, from: Node) -> void:
	if trk == null or count <= 0:
		return
	var w := ItemEntity.world(trk)
	for k in count:
		var sr := ScatterRing.new()
		sr.track = trk
		sr.owner_racer = from
		sr.owner_grace = 0.9
		sr.life = 6.0
		sr.radius = 0.6
		sr.blocks = false
		sr.spin_speed = 6.0
		sr.model = ItemModels.build("ring", Color("ffd23a"))
		sr.model.scale = Vector3.ONE * 0.7
		var a := TAU * k / float(count) + randf() * 0.4
		sr._vel = Vector3(cos(a), 0.0, sin(a)) * randf_range(4.0, 7.0) + Vector3.UP * randf_range(6.0, 9.0)
		w.add_child(sr)
		sr.global_position = at + Vector3.UP * 0.8


func step(delta: float) -> void:
	if model != null and life - age < 1.5:
		model.visible = int(age * 12.0) % 2 == 0
	if _grounded:
		return
	_vel.y -= 26.0 * delta
	var nxt := global_position + _vel * delta
	var hit := ray(global_position + Vector3.UP * 0.2, nxt)
	if not hit.is_empty():
		if (hit.normal as Vector3).y > 0.5:
			global_position = hit.position
			if absf(_vel.y) < 3.0:
				_grounded = true
				return
			_vel = Vector3(_vel.x * 0.6, -_vel.y * 0.45, _vel.z * 0.6)
		else:
			_vel = _vel.bounce((hit.normal as Vector3)) * 0.5
		return
	global_position = nxt
	if track != null and global_position.y < track.kill_y:
		queue_free()


func on_racer(r: Node) -> void:
	if r.get("items") == null:
		return
	(r.items as RacerItems).add_rings(1)
	queue_free()
