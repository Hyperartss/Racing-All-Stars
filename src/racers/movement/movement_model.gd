class_name MovementModel
extends RefCounted
## How a racer type moves. One subclass per racer type (runner, kart, ... flyer).
## The Racer owns the body, progress and the loop; the model only turns input into
## velocity and fills the animation state. Register new types in RacerTypes.

const GRAVITY := 30.0

var racer: CharacterBody3D
var anim := RacerVisual.AnimState.new()

## Forward speed along `heading` (m/s) and the facing direction (yaw, radians).
var speed := 0.0
var heading := 0.0
var max_speed := 20.0
## Multiplier on top speed from the surface under us (road 1.0).
var surface_factor := 1.0
var hit_timer := 0.0
## Top-speed multiplier from outside the model (rings held, shrunk by lightning ...).
## RacerItems sets it every frame.
var bonus_mult := 1.0
## Item / pad boost: extra top speed for a while (mushrooms, dash panels, stars,
## tricks, rocket starts). While it runs, off-road does not slow you down.
var ext_boost_timer := 0.0
var ext_boost_speed := 0.0
var _launch := 0.0


func setup(r: CharacterBody3D) -> void:
	racer = r
	heading = r.rotation.y


## Collision shape for this racer type (and its local offset).
func make_shape() -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var c := CapsuleShape3D.new()
	c.radius = 0.35
	c.height = 1.0
	cs.shape = c
	cs.position.y = 0.5
	return cs


## Top-speed multiplier per surface class. Override to give a type its own feel.
func surface_multiplier(surface: String) -> float:
	match surface:
		"off":
			return 0.6
		_:
			return 1.0


func physics_step(_input: RacerInput, _delta: float) -> void:
	pass


## Called when the racer is put back on the track.
func reset_motion(new_heading: float) -> void:
	speed = 0.0
	heading = new_heading
	racer.velocity = Vector3.ZERO


## Boost from an item, pad, trick or rocket start (stacks by taking the longer/stronger).
func item_boost(seconds: float, extra_speed: float) -> void:
	ext_boost_speed = maxf(ext_boost_speed if ext_boost_timer > 0.0 else 0.0, extra_speed)
	ext_boost_timer = maxf(ext_boost_timer, seconds)
	speed = maxf(speed, max_speed * 0.6)


func boost_left() -> float:
	return ext_boost_timer


## Extra top speed right now (call once per physics step: it also counts down).
func ext_boost(delta: float) -> float:
	if ext_boost_timer <= 0.0:
		ext_boost_speed = 0.0
		return 0.0
	ext_boost_timer = maxf(0.0, ext_boost_timer - delta)
	return ext_boost_speed


## Springs: leave the ground with this upward speed on the next step.
func launch(up_speed: float) -> void:
	_launch = up_speed
	if "vy" in self:
		set("vy", up_speed)
	if "jumping" in self:
		set("jumping", true)


func launching() -> bool:
	return _launch > 0.0


## Knocked by something (wall at speed, other racer, item).
func take_hit(seconds: float) -> void:
	hit_timer = maxf(hit_timer, seconds)
	speed *= 0.4


func forward() -> Vector3:
	return Vector3(-sin(heading), 0.0, -cos(heading))


## Shared ground handling: move along the floor plane, snap to it, slide on walls.
## Returns the wall impact strength (0 = none) so models can react.
func move_body(planar_velocity: Vector3, vertical: float, delta: float) -> float:
	var body := racer
	var v := planar_velocity
	var snap := body.floor_snap_length
	if _launch > 0.0:
		v.y = maxf(vertical, _launch)
		body.floor_snap_length = 0.0
		body.position += Vector3.UP * 0.08
	elif body.is_on_floor():
		var n := body.get_floor_normal()
		# Follow slopes: keep speed, tilt the motion into the floor plane.
		v = (v - n * v.dot(n))
		if v.length() > 0.01:
			v = v.normalized() * planar_velocity.length()
		v += n * minf(vertical, 0.0)
	else:
		v.y = vertical
	body.velocity = v
	var before := body.velocity
	body.move_and_slide()
	if _launch > 0.0:
		_launch = 0.0
		body.floor_snap_length = snap
	var impact := 0.0
	for i in body.get_slide_collision_count():
		var c := body.get_slide_collision(i)
		var nrm := c.get_normal()
		if absf(nrm.y) < 0.5:   # a wall, not a floor
			impact = maxf(impact, -before.normalized().dot(nrm))
	if impact > 0.3 and body.is_on_floor():
		if _try_step_up(planar_velocity, delta):
			impact = 0.0
	return impact


## Arcade step-up: climb lips and kerbs up to STEP_HEIGHT that the body walked into
## (old tracks have plenty of small ledges with no ramp).
const STEP_HEIGHT := 1.1

func _try_step_up(planar_velocity: Vector3, delta: float) -> bool:
	var body := racer
	var fwd := Vector3(planar_velocity.x, 0, planar_velocity.z)
	if fwd.length() < 1.0:
		return false
	var step := fwd.normalized() * maxf(fwd.length() * delta, 0.25)
	var up := Vector3.UP * STEP_HEIGHT
	var t := body.global_transform
	if body.test_move(t, up):
		return false                      # no headroom
	var raised := t.translated(up)
	if body.test_move(raised, step):
		return false                      # still blocked higher up: a real wall
	var over := raised.translated(step)
	var col := KinematicCollision3D.new()
	if body.test_move(over, Vector3.DOWN * (STEP_HEIGHT + 0.2), col) and col.get_normal().y > 0.6:
		body.global_position = over.origin + col.get_travel()
		return true
	return false


## Floor surface class ("road", "off", "wall") from the collider metadata.
func floor_surface() -> String:
	if not racer.is_on_floor():
		return ""
	for i in racer.get_slide_collision_count():
		var c := racer.get_slide_collision(i)
		if c.get_normal().y > 0.5:
			var col := c.get_collider()
			if col and col.has_meta("surface"):
				return String(col.get_meta("surface"))
	return "road"
