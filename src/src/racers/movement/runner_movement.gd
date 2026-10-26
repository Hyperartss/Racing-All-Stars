class_name RunnerMovement
extends MovementModel
## On-foot racer (Sonic R style): quick acceleration, sharp turning at low speed,
## a jump, and a dash burst on a cooldown. Off-road hurts runners far less than
## karts, so cutting across grass is a real option for them.

var params := {
	"max_speed": 27.0,
	"accel": 16.0,
	"coast_decel": 9.0,
	"brake": 34.0,
	"turn_slow": 4.2,       ## rad/s at walking pace
	"turn_fast": 2.0,       ## rad/s at top speed
	"jump_speed": 11.5,
	"air_control": 0.5,
	"dash_boost": 1.4,      ## top-speed multiplier while dashing
	"dash_time": 1.1,
	"dash_cooldown": 2.6,
}

var vy := 0.0
var jumping := false
var dash_timer := 0.0
var dash_cool := 0.0
var steer_smooth := 0.0


func setup(r: CharacterBody3D) -> void:
	super(r)
	max_speed = params.max_speed


func make_shape() -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var c := CapsuleShape3D.new()
	c.radius = 0.3
	c.height = 1.05
	cs.shape = c
	cs.position.y = 0.53
	return cs


func surface_multiplier(surface: String) -> float:
	return 0.85 if surface == "off" else 1.0


func physics_step(input: RacerInput, delta: float) -> void:
	var grounded := racer.is_on_floor()
	hit_timer = maxf(0.0, hit_timer - delta)
	dash_cool = maxf(0.0, dash_cool - delta)
	dash_timer = maxf(0.0, dash_timer - delta)
	if hit_timer > 0.0:
		input = RacerInput.new()

	# Dash: a burst of extra top speed, then a cooldown.
	if input.action_pressed and dash_cool <= 0.0 and grounded:
		dash_timer = params.dash_time
		dash_cool = params.dash_cooldown
		speed = maxf(speed, max_speed * 0.9)
		EventBus.racer_action.emit(racer, &"dash", {})

	surface_factor = surface_multiplier(floor_surface()) if grounded else surface_factor
	var top: float = max_speed * surface_factor * (params.dash_boost if dash_timer > 0.0 else 1.0)

	# Speed
	var control := 1.0 if grounded else float(params.air_control)
	if input.throttle > 0.0:
		var a: float = params.accel * (1.0 - clampf(speed / top, 0.0, 1.0) * 0.6)
		speed += a * input.throttle * control * delta
	elif grounded:
		speed = move_toward(speed, 0.0, params.coast_decel * delta)
	if input.brake > 0.0 and grounded:
		speed = move_toward(speed, -6.0, params.brake * input.brake * delta)
	if dash_timer > 0.0:
		speed = move_toward(speed, top, 40.0 * delta)
	if speed > top:
		speed = move_toward(speed, top, (20.0 if grounded else 4.0) * delta)

	# Turning: nimble when slow, wider when fast.
	steer_smooth = move_toward(steer_smooth, input.steer, 8.0 * delta)
	var k := clampf(absf(speed) / max_speed, 0.0, 1.0)
	var turn: float = lerpf(params.turn_slow, params.turn_fast, k) * control
	heading += steer_smooth * turn * delta

	# Jump
	if grounded:
		jumping = false
		vy = -2.0
		if input.jump:
			vy = params.jump_speed
			jumping = true
			grounded = false
			racer.position += Vector3.UP * 0.05
			EventBus.racer_action.emit(racer, &"jump", {})
	else:
		vy -= GRAVITY * delta
		if not input.jump_held and vy > 3.0 and jumping:
			vy -= GRAVITY * delta     # short hop when the button is let go

	var impact := move_body(forward() * speed, vy, delta)
	if racer.is_on_ceiling() and vy > 0.0:
		vy = 0.0
	if impact > 0.6 and absf(speed) > 14.0:
		take_hit(0.5)
	elif impact > 0.2:
		speed *= 1.0 - impact * 0.5 * delta * 10.0

	anim.speed = speed
	anim.max_speed = max_speed
	anim.grounded = racer.is_on_floor()
	anim.steer = steer_smooth
	anim.jumping = jumping and not racer.is_on_floor()
	anim.dashing = dash_timer > 0.0
	anim.hit = hit_timer
	anim.vertical_speed = vy


func reset_motion(new_heading: float) -> void:
	super(new_heading)
	vy = 0.0
	jumping = false
	dash_timer = 0.0
