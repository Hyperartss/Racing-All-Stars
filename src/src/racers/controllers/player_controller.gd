class_name PlayerController
extends RacerController
## Keyboard / pad. W/Up = go, S = brake/reverse, A/D = steer, Space = jump (runner)
## or hop (kart), Shift = dash (runner) / drift (kart).

var _jump_was := false
var _act_was := false


func get_input(_racer: Node, _delta: float) -> RacerInput:
	input.clear()
	input.throttle = Input.get_action_strength("move_forward")
	input.brake = Input.get_action_strength("move_back")
	input.steer = Input.get_action_strength("move_left") - Input.get_action_strength("move_right")
	var j := Input.is_action_pressed("jump")
	input.jump = j and not _jump_was
	input.jump_held = j
	_jump_was = j
	var a := Input.is_action_pressed("dash") or Input.is_action_pressed("drift")
	input.action = a
	input.action_pressed = a and not _act_was
	_act_was = a
	return input
