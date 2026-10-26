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
	if body.is_on_floor():
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
	var impact := 0.0
	for i in body.get_slide_collision_count():
		var c := body.get_slide_collision(i)
		var nrm := c.get_normal()
		if absf(nrm.y) < 0.5:   # a wall, not a floor
			impact = maxf(impact, -before.normalized().dot(nrm))
	return impact


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
