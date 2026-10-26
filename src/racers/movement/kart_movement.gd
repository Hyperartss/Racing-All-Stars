class_name KartMovement
extends MovementModel
## Kart (Mario Kart style): throttle/brake/reverse, speed-dependent steering with a
## little slip, hop-into-drift, and a mini-turbo whose strength depends on how long
## the drift was held. Grass slows karts a lot.

var params := {
	"max_speed": 24.0,
	"accel": 11.0,
	"coast_decel": 5.0,
	"brake": 22.0,
	"reverse_max": 7.0,
	"turn_rate": 2.1,          ## rad/s at the best steering speed
	"grip": 7.0,               ## how fast velocity realigns with the nose
	"drift_min_speed": 9.0,
	"drift_turn": 1.25,        ## base yaw rate while drifting
	"drift_turn_extra": 0.85,  ## +/- with steering inside/outside the drift
	"drift_grip": 1.6,
	"turbo_1": 0.75,           ## seconds of drift for a blue mini-turbo
	"turbo_2": 1.6,            ## seconds of drift for an orange super mini-turbo
	"boost_speed": 7.0,
	"hop_speed": 4.5,
}

var vy := 0.0
var vel_dir := 0.0          ## direction the kart is actually travelling (yaw)
var drift_dir := 0
var drift_time := 0.0
var boost_timer := 0.0
var steer_smooth := 0.0
var _was_action := false


func setup(r: CharacterBody3D) -> void:
	super(r)
	max_speed = params.max_speed
	vel_dir = heading


func make_shape() -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var c := CapsuleShape3D.new()
	c.radius = 0.42
	c.height = 1.35
	cs.shape = c
	cs.rotation.x = PI * 0.5       # lie along the kart
	cs.position.y = 0.42
	return cs


func surface_multiplier(surface: String) -> float:
	return 0.45 if surface == "off" else 1.0


func physics_step(input: RacerInput, delta: float) -> void:
	var grounded := racer.is_on_floor()
	hit_timer = maxf(0.0, hit_timer - delta)
	boost_timer = maxf(0.0, boost_timer - delta)
	if hit_timer > 0.0:
		input = RacerInput.new()
		drift_dir = 0
		drift_time = 0.0

	surface_factor = surface_multiplier(floor_surface()) if grounded else surface_factor
	var top: float = max_speed * surface_factor + (params.boost_speed if boost_timer > 0.0 else 0.0)

	# --- speed ---------------------------------------------------------------
	if grounded:
		if input.throttle > 0.0:
			var a: float = params.accel * (1.0 - clampf(speed / maxf(top, 0.1), 0.0, 1.0) * 0.5)
			speed += a * input.throttle * delta
		elif input.brake <= 0.0:
			speed = move_toward(speed, 0.0, params.coast_decel * delta)
		if input.brake > 0.0:
			if speed > 0.5:
				speed = move_toward(speed, 0.0, params.brake * input.brake * delta)
			else:
				speed = move_toward(speed, -params.reverse_max, params.accel * 0.6 * delta)
		if boost_timer > 0.0:
			speed = move_toward(speed, top, 30.0 * delta)
		if speed > top:
			speed = move_toward(speed, top, 14.0 * delta)

	# --- drift ---------------------------------------------------------------
	steer_smooth = move_toward(steer_smooth, input.steer, 6.0 * delta)
	var pressed := input.action and not _was_action
	_was_action = input.action
	if pressed and grounded and drift_dir == 0:
		vy = params.hop_speed           # little hop that starts a drift
	if input.action and drift_dir == 0 and absf(input.steer) > 0.3 and speed > params.drift_min_speed:
		drift_dir = 1 if input.steer > 0.0 else -1
		drift_time = 0.0
		EventBus.racer_action.emit(racer, &"drift", {"dir": drift_dir})
	if drift_dir != 0:
		if not input.action or speed < params.drift_min_speed * 0.7:
			_release_drift()
		elif grounded:
			drift_time += delta

	# --- steering ------------------------------------------------------------
	var k := clampf(absf(speed) / max_speed, 0.0, 1.0)
	var steer_k := clampf(absf(speed) / 6.0, 0.0, 1.0) * lerpf(1.0, 0.7, k)
	var grip: float = params.grip
	if drift_dir != 0:
		var inside := steer_smooth * float(drift_dir)    # -1 wide .. +1 tight
		heading += float(drift_dir) * (params.drift_turn + params.drift_turn_extra * inside) * delta
		grip = params.drift_grip
	else:
		heading += steer_smooth * params.turn_rate * steer_k * signf(speed + 0.001) * delta
	if not grounded:
		grip *= 0.15
	# The travel direction chases the nose: low grip = slide.
	vel_dir = lerp_angle(vel_dir, heading, 1.0 - exp(-grip * delta))

	# --- vertical + move -------------------------------------------------------
	if grounded and vy <= 0.0:
		vy = -2.0
	else:
		vy -= GRAVITY * delta
	var travel := Vector3(-sin(vel_dir), 0.0, -cos(vel_dir)) * speed
	var impact := move_body(travel, vy, delta)
	if impact > 0.65 and absf(speed) > 15.0:
		take_hit(0.7)
		EventBus.racer_action.emit(racer, &"hit", {})
	elif impact > 0.15:
		speed *= 1.0 - impact * 6.0 * delta
		vel_dir = lerp_angle(vel_dir, heading, 0.3)

	anim.speed = speed
	anim.max_speed = max_speed
	anim.grounded = racer.is_on_floor()
	anim.steer = steer_smooth
	anim.drift_dir = drift_dir
	anim.drift_charge = clampf(drift_time / params.turbo_2, 0.0, 1.0)
	anim.boosting = boost_timer > 0.0
	anim.hit = hit_timer
	anim.vertical_speed = vy


func _release_drift() -> void:
	if drift_time >= params.turbo_2:
		boost_timer = 1.1
		EventBus.racer_action.emit(racer, &"boost", {"level": 2})
	elif drift_time >= params.turbo_1:
		boost_timer = 0.6
		EventBus.racer_action.emit(racer, &"boost", {"level": 1})
	drift_dir = 0
	drift_time = 0.0


## Mini-turbo level the current drift would give if released now (0, 1, 2).
func drift_level() -> int:
	if drift_dir == 0:
		return 0
	if drift_time >= params.turbo_2:
		return 2
	return 1 if drift_time >= params.turbo_1 else 0


func reset_motion(new_heading: float) -> void:
	super(new_heading)
	vel_dir = new_heading
	vy = 0.0
	drift_dir = 0
	drift_time = 0.0
	boost_timer = 0.0
