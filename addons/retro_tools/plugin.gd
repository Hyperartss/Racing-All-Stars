@tool
extends EditorPlugin
## Adds six bottom-panel docks: Map Combiner, Map Editor (3D clean-up and
## decoration of a baked map), Map Importer (an outside track model -> a playable
## map), Character Importer, Kart Importer and Animation Editor.

var map_dock: Control
var editor_dock: Control
var map_import_dock: Control
var char_dock: Control
var kart_dock: Control
var anim_dock: Control


func _enter_tree() -> void:
	map_dock = preload("res://addons/retro_tools/map_combiner_dock.gd").new()
	map_dock.name = "Map Combiner"
	add_control_to_bottom_panel(map_dock, "Map Combiner")
	editor_dock = preload("res://addons/retro_tools/map_editor_dock.gd").new()
	editor_dock.name = "Map Editor"
	add_control_to_bottom_panel(editor_dock, "Map Editor")
	map_import_dock = preload("res://addons/retro_tools/map_importer_dock.gd").new()
	map_import_dock.name = "Map Importer"
	add_control_to_bottom_panel(map_import_dock, "Map Importer")
	char_dock = preload("res://addons/retro_tools/character_importer_dock.gd").new()
	char_dock.name = "Character Importer"
	add_control_to_bottom_panel(char_dock, "Character Importer")
	kart_dock = preload("res://addons/retro_tools/kart_importer_dock.gd").new()
	kart_dock.name = "Kart Importer"
	add_control_to_bottom_panel(kart_dock, "Kart Importer")
	anim_dock = preload("res://addons/retro_tools/animation_editor_dock.gd").new()
	anim_dock.name = "Animation Editor"
	add_control_to_bottom_panel(anim_dock, "Animation Editor")


func _exit_tree() -> void:
	for d in [map_dock, editor_dock, map_import_dock, char_dock, kart_dock, anim_dock]:
		if d:
			remove_control_from_bottom_panel(d)
			d.queue_free()
