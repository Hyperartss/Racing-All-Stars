extends Node3D
## Boot: opens the main menu.

func _ready() -> void:
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")
