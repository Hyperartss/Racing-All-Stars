@tool
extends EditorPlugin
## Adds two bottom-panel docks: Map Combiner and Character Importer.

var map_dock: Control
var char_dock: Control


func _enter_tree() -> void:
	map_dock = preload("res://addons/retro_tools/map_combiner_dock.gd").new()
	map_dock.name = "Map Combiner"
	add_control_to_bottom_panel(map_dock, "Map Combiner")
	char_dock = preload("res://addons/retro_tools/character_importer_dock.gd").new()
	char_dock.name = "Character Importer"
	add_control_to_bottom_panel(char_dock, "Character Importer")


func _exit_tree() -> void:
	for d in [map_dock, char_dock]:
		if d:
			remove_control_from_bottom_panel(d)
			d.queue_free()
