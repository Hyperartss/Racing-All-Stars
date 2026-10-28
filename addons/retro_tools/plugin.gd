@tool
extends EditorPlugin
## Adds three bottom-panel docks: Map Combiner, Character Importer and Animation
## Editor (per-character keyframe animation for the vertex rigs).

var map_dock: Control
var char_dock: Control
var anim_dock: Control


func _enter_tree() -> void:
	map_dock = preload("res://addons/retro_tools/map_combiner_dock.gd").new()
	map_dock.name = "Map Combiner"
	add_control_to_bottom_panel(map_dock, "Map Combiner")
	char_dock = preload("res://addons/retro_tools/character_importer_dock.gd").new()
	char_dock.name = "Character Importer"
	add_control_to_bottom_panel(char_dock, "Character Importer")
	anim_dock = preload("res://addons/retro_tools/animation_editor_dock.gd").new()
	anim_dock.name = "Animation Editor"
	add_control_to_bottom_panel(anim_dock, "Animation Editor")


func _exit_tree() -> void:
	for d in [map_dock, char_dock, anim_dock]:
		if d:
			remove_control_from_bottom_panel(d)
			d.queue_free()
