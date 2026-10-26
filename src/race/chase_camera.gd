class_name ChaseCamera
extends Camera3D
## Classic kart-racer chase camera: behind and above the target, lags on turns,
## widens FOV with speed. Through the loop it follows the target's own up.

var target: Racer
var distance_back := 6.0
var height := 2.4
var _pos := Vector3.ZERO
var _up := Vector3.UP


func _ready() -> void:
	far = 700.0
	fov = 68.0
	if target:
		_pos = _desired()


func _desired() -> Vector3:
	var b := target.global_transform.basis
	var fwd := -b.z
	var up := Vector3.UP if not target.on_rail else b.y
	if not target.on_rail:
		fwd.y = 0.0
		fwd = fwd.normalized()
	return target.global_position - fwd * distance_back + up * height


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	if Input.is_action_pressed("look_back"):
		var b := target.global_transform.basis
		global_position = target.global_position + (-b.z) * 5.0 + Vector3.UP * 2.0
		look_at(target.global_position + Vector3.UP, Vector3.UP)
		return
	var want := _desired()
	var rate := 12.0 if target.on_rail else 7.0
	_pos = _pos.lerp(want, 1.0 - exp(-rate * delta))
	if _pos.distance_to(want) > 30.0:
		_pos = want
	var tu := target.global_transform.basis.y.normalized() if target.on_rail else Vector3.UP
	_up = _up.lerp(tu, 1.0 - exp(-6.0 * delta)).normalized()
	global_position = _pos
	var look := target.global_position + _up * 1.0 + (-target.global_transform.basis.z) * 4.0
	if global_position.distance_to(look) > 0.1:
		look_at(look, _up)
	var spd := absf(target.movement.speed)
	fov = lerpf(fov, 66.0 + clampf(spd, 0.0, 40.0) * 0.35, 1.0 - exp(-3.0 * delta))
