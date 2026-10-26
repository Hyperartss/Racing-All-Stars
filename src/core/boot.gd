extends Node3D
## Boot: straight into a race (Sonic = player, Mario = AI).

func _ready() -> void:
	get_tree().change_scene_to_file.call_deferred("res://scenes/race.tscn")
