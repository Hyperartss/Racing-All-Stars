class_name BombEntity
extends ItemEntity
## Thrown in an arc; lands, ticks for `fuse` seconds and explodes, sending every
## racer in `blast` metres tumbling. Driving into it sets it off at once.

var fuse := 1.4
var blast := 5.0
var tumble := 1.6
var _vel := Vector3.ZERO
var _landed := false
var _tick := 0.0


func throw(dir: Vector3, dist: float) -> void:
	var t := 0.7
	_vel = dir.normalized() * (dist / t)
	_vel.y = 10.0


func step(delta: float) -> void:
	if not _landed:
		_vel.y -= 30.0 * delta
		var nxt := global_position + _vel * delta
		if _vel.y < 0.0:
			var hit := ray(global_position + Vector3.UP * 0.3, nxt + Vector3.DOWN * 0.1)
			if not hit.is_empty():
				global_position = hit.position
				_landed = true
				return
		global_position = nxt
		if track != null and global_position.y < track.kill_y:
			queue_free()
		return
	_tick += delta
	if model != null:
		model.scale = Vector3.ONE * (1.0 + 0.15 * sin(_tick * 18.0))
	if _tick >= fuse:
		explode()


func explode() -> void:
	var at := global_position
	BurstFx.explosion(get_parent(), at + Vector3.UP * 0.5, blast)
	for r in GameState.racers:
		if is_instance_valid(r) and (r as Node3D).global_position.distance_to(at) < blast:
			hit_racer(r, "tumble", tumble, owner_racer)
	for e in get_tree().get_nodes_in_group(GROUP):
		if e != self and is_instance_valid(e) and (e as Node3D).global_position.distance_to(at) < blast * 0.7 \
				and e is TrapEntity:
			(e as ItemEntity).vanish(true)
	queue_free()


func on_racer(_r: Node) -> void:
	if _landed or age > 0.3:
		explode()
