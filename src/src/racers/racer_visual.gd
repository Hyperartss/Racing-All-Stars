class_name RacerVisual
extends Node3D
## Base for a racer's look. The movement model fills an `AnimState` each physics
## frame; the visual turns it into vertex poses. New racer types add a new visual
## without touching the others.

## Snapshot of what the racer is doing, written by the movement model.
class AnimState:
	var speed := 0.0            ## signed forward speed, m/s
	var max_speed := 1.0
	var grounded := true
	var steer := 0.0            ## -1 right .. +1 left (input after smoothing)
	var jumping := false
	var dashing := false
	var drift_dir := 0          ## -1 right, 0 none, +1 left
	var drift_charge := 0.0     ## 0..1
	var boosting := false
	var hit := 0.0              ## seconds of hit-stun left
	var vertical_speed := 0.0

var time := 0.0


## Called every rendered frame.
func update_visual(_s: AnimState, delta: float) -> void:
	time += delta


## Ease a value toward a target, frame-rate independent.
static func approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerpf(current, target, 1.0 - exp(-rate * delta))
