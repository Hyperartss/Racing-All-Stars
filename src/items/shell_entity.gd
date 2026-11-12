class_name ShellEntity
extends ItemEntity
## A projectile that skims the course.
##   straight - goes where it was fired and bounces off walls (green shell)
##   homing   - follows the road to the racer ahead, then locks on (red shell)
##   leader   - flies over the course to the leader and explodes (spiny shell)

var mode := "straight"
var speed := 40.0
var dir := Vector3.FORWARD
var bounces := 5
var spin := 1.0
var turn_rate := 3.5
var explode_radius := 0.0
var target: Node
var _vy := 0.0
var _idx := -1


func step(delta: float) -> void:
	if mode == "leader":
		_step_leader(delta)
		return
	if mode == "homing":
		_steer_homing(delta)
	var move := dir * speed * delta
	var from := global_position + Vector3.UP * 0.4
	var wall := ray(from, from + dir * (move.length() + 0.35))
	if not wall.is_empty() and absf((wall.normal as Vector3).y) < 0.5:
		if mode == "homing":
			vanish(true)
			return
		var n: Vector3 = wall.normal
		n.y = 0.0
		n = n.normalized()
		dir = dir.bounce(n).normalized()
		bounces -= 1
		if bounces < 0:
			vanish(true)
			return
		move = dir * speed * delta
	global_position += move
	var g := ray(global_position + Vector3.UP * 1.6, global_position + Vector3.DOWN * 3.0)
	if not g.is_empty() and (g.normal as Vector3).y > 0.3:
		global_position.y = (g.position as Vector3).y + 0.05
		_vy = 0.0
	else:
		_vy -= 30.0 * delta
		global_position.y += _vy * delta
		if track != null and global_position.y < track.kill_y:
			queue_free()
			return
	for b in blockers_near(radius):
		if b is ShellEntity and (b as ShellEntity).mode == "leader":
			continue
		(b as ItemEntity).vanish(true)
		vanish(true)
		return


func _steer_homing(delta: float) -> void:
	var aim := global_position + dir
	var tgt_ok := target != null and is_instance_valid(target)
	if tgt_ok and (target as Node3D).global_position.distance_to(global_position) < 28.0:
		aim = (target as Node3D).global_position
	elif track != null:
		_idx = track.path.nearest(global_position, _idx)
		aim = track.path.pos[track.path.index_ahead(_idx, 9.0)]
	var want := aim - global_position
	want.y = 0.0
	if want.length() < 0.01:
		return
	var a := dir.signed_angle_to(want.normalized(), Vector3.UP)
	dir = dir.rotated(Vector3.UP, clampf(a, -turn_rate * delta, turn_rate * delta)).normalized()


func _step_leader(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		var st := GameState.standings()
		target = st[0] if st.size() > 0 else null
		if target == null:
			vanish(true)
			return
	var tp := (target as Node3D).global_position
	var d := tp.distance_to(global_position)
	var aim := tp
	if d > 18.0 and track != null:
		_idx = track.path.nearest(global_position, _idx)
		aim = track.path.pos[track.path.index_ahead(_idx, 14.0)] + Vector3.UP * 3.0
	elif d > 4.0:
		aim = tp + Vector3.UP * 2.5
	var to := aim - global_position
	if to.length() > 0.01:
		global_position += to.normalized() * minf(speed * delta, to.length())
	if d < 2.2:
		_explode()


func _explode() -> void:
	var at := global_position
	BurstFx.explosion(get_parent(), at, maxf(explode_radius, 2.0))
	for r in GameState.racers:
		if is_instance_valid(r) and (r as Node3D).global_position.distance_to(at) < maxf(explode_radius, 2.0):
			hit_racer(r, "tumble", GameRules.f("tumble_time"), owner_racer)
	queue_free()


func on_racer(r: Node) -> void:
	if mode == "leader":
		if r == target:
			_explode()
		return
	hit_racer(r, "spin", spin, owner_racer)
	vanish(true)


func _burst_colour() -> Color:
	return Color(0.4, 1.0, 0.4) if mode == "straight" else Color(1.0, 0.4, 0.4)
