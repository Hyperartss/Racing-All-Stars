class_name RacerController
extends RefCounted
## Produces a RacerInput each physics frame. Subclass for player, AI, replays...

var input := RacerInput.new()


func get_input(_racer: Node, _delta: float) -> RacerInput:
	input.clear()
	return input
