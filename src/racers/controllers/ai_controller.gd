class_name AIController
extends RacerController
## Simple racing line follower: aims at a point ahead on the centreline (further
## ahead at speed), brakes for sharp corners, and uses the type's special move
## (runner: dash on straights, kart: drift through long corners for mini-turbos).

var lane := 0.0               ## preferred lateral offset (m)
var skill := 1.0              ## 0.8 .. 1.0 scales top speed use
var _stuck := 0.0
var _reverse := 0.0
var _drift_hold := 0.0
var _rng := RandomNumberGenerator.new()
var _jump_timer := 3.0
var _fork_choice := false     ## take the alternate route this lap?
var _on_fork := false
var _fork_i := 0
var _last_lap := -1


func _init(seed_value: int = 0) -> void:
	_rng.seed = seed_value
	lane = _rng.randf_range(-2.0, 2.0)


func get_input(racer: Node, delta: float) -> RacerInput:
	input.clear()
	var track: Track = racer.track
	var mv: MovementModel = racer.movement
	var i: int = racer.track_index
	var spd := absf(mv.speed)
	var path := track.path
	var look := clampf(6.0 + spd * 0.55, 8.0, 22.0)
	var j := path.index_ahead(i, look)
	# Alternate route: decide once per lap, then follow its own line.
	if racer.laps_done != _last_lap:
		_last_lap = racer.laps_done
		_fork_choice = _rng.randf() < 0.5
	if not _on_fork and _fork_choice and i >= track.fork_from - 6 and i <= track.fork_from:
		_on_fork = true
		_fork_i = 0
	var target := path.pos[j] + path.right[j] * lane
	if _on_fork:
		var fk := track.fork
		_fork_i = fk.nearest(racer.global_position, _fork_i, 12)
		if _fork_i >= fk.size() - 3 or i > track.fork_to + 4:
			_on_fork = false
		else:
			target = fk.pos[fk.wi(_fork_i + int(look / 2.0))]
	var to: Vector3 = target - (racer as Node3D).global_position
	to.y = 0.0
	var fwd := mv.forward()
	var ang := fwd.signed_angle_to(to.normalized(), Vector3.UP)
	input.steer = clampf(ang * 2.4, -1.0, 1.0)

	# How sharp is the road ahead? Compare tangents.
	var t0 := path.tangent[i]
	var t1 := path.tangent[path.index_ahead(i, 30.0)]
	var bend := absf(t0.signed_angle_to(t1, Vector3.UP))
	input.throttle = 1.0
	if bend > 1.2 and spd > mv.max_speed * 0.62:
		input.throttle = 0.0
		input.brake = 0.4
	if absf(ang) > 0.9 and spd > 8.0:
		input.throttle = 0.3

	# Special moves
	if mv is RunnerMovement:
		_jump_timer -= delta
		if _jump_timer <= 0.0 and bend < 0.3 and racer.is_on_floor():
			input.jump = true
			input.jump_held = true
			_jump_timer = _rng.randf_range(3.0, 7.0)
		if bend < 0.25 and absf(ang) < 0.15 and spd > 12.0:
			input.action = true
			input.action_pressed = true
	elif mv is KartMovement:
		var km := mv as KartMovement
		var turn_dir := signf(t0.signed_angle_to(t1, Vector3.UP))
		if km.drift_dir == 0:
			if bend > 0.7 and spd > 14.0 and absf(ang) > 0.12:
				input.action = true
				_drift_hold = 0.0
				input.steer = turn_dir
		else:
			_drift_hold += delta
			# keep drifting while the corner lasts, release after a good turbo
			input.action = bend > 0.35 or km.drift_level() < 1
			if _drift_hold > 2.2:
				input.action = false
			# steer to hold the line inside the drift
			input.steer = clampf(ang * 2.0, -1.0, 1.0)

	# Unstick: if we are not moving while trying to, back up briefly.
	var real := (racer as CharacterBody3D).get_real_velocity().length()
	if real < 1.5 and racer.race_active and not racer.on_rail:
		_stuck += delta
	else:
		_stuck = maxf(0.0, _stuck - delta)
	if _stuck > 1.5:
		_reverse = 0.9
		_stuck = 0.0
	if _reverse > 0.0:
		_reverse -= delta
		input.throttle = 0.0
		input.brake = 1.0
		input.steer = -input.steer
	return input
