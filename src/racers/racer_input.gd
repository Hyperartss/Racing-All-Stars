class_name RacerInput
extends RefCounted
## One frame of intent from a controller (player or AI). Movement models read it;
## what `action` means is up to the model (runner: dash, kart: drift).

var throttle := 0.0        ## 0..1
var brake := 0.0           ## 0..1 (also reverse for karts)
var steer := 0.0           ## -1 right .. +1 left
var jump := false          ## pressed this frame
var jump_held := false
var action := false        ## held
var action_pressed := false


func clear() -> void:
	throttle = 0.0
	brake = 0.0
	steer = 0.0
	jump = false
	jump_held = false
	action = false
	action_pressed = false
