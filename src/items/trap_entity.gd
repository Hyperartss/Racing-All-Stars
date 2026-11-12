class_name TrapEntity
extends ItemEntity
## A trap lying on the course (banana, fake item box, ...): spins out whoever drives
## into it. Can be dragged behind its owner, where it also stops shells from behind,
## or thrown forward in an arc.

var spin := 0.9
var kind := "spin"
var _vel := Vector3.ZERO
var _flying := false
var _settled := false


func throw(dir: Vector3, dist: float) -> void:
	_flying = true
	var t := 0.65
	_vel = dir.normalized() * (dist / t)
	_vel.y = 9.0


func step(delta: float) -> void:
	if _flying:
		_vel.y -= 30.0 * delta
		var nxt := global_position + _vel * delta
		if _vel.y < 0.0:
			var hit := ray(global_position + Vector3.UP * 0.3, nxt + Vector3.DOWN * 0.1)
			if not hit.is_empty() and (hit.normal as Vector3).y > 0.5:
				global_position = hit.position
				_flying = false
				_settled = true
				return
		global_position = nxt
		if track != null and global_position.y < track.kill_y:
			queue_free()
	elif not _settled:
		if not snap_to_ground():
			global_position += Vector3.DOWN * 9.0 * delta
			if track != null and global_position.y < track.kill_y:
				queue_free()
		else:
			_settled = true


func on_racer(r: Node) -> void:
	hit_racer(r, kind, spin, owner_racer)
	vanish(true)


func _burst_colour() -> Color:
	return Color(1.0, 0.9, 0.3)
