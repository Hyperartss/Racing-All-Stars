extends Node
## Drives the main menu, screenshots each screen to out/menu_*.png, then starts a
## race from it and checks the race came up with the configured roster.
var menu: Node

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	# The menu becomes the current scene so changing scene frees it, not this script.
	var tree := get_tree()
	reparent(tree.root)
	menu = load("res://scenes/main_menu.tscn").instantiate()
	tree.root.add_child(menu)
	tree.current_scene = menu
	await _wait(30)
	await _shot("title")
	menu.show_screen("characters")
	await _wait(20)
	await _shot("characters_sonic")
	menu._pick_character("mario")
	await _wait(30)
	await _shot("characters_mario")
	menu._rebuild_customise()
	menu.show_screen("customise")
	var cm: Dictionary = Profile.custom_for("mario")
	cm["kart_paint"] = {"body": "#2050e0", "wheels": "#ffe080", "emblem": false}
	cm["paint"] = {"outfit": "#20a040"}
	menu._apply_custom()
	await _wait(30)
	await _shot("customise")
	menu.show_screen("maps")
	await _wait(20)
	await _shot("maps")
	menu.prof.opponents = 3
	menu.prof.laps = 1
	menu.start_race()
	await _wait(90)
	var race := get_tree().current_scene
	print("race scene: ", race.name, " racers: ", race.racers.map(func(r): return r.display_name), " map: ", race.map_id)
	await _shot("race_from_menu")
	get_tree().quit()

func _wait(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _shot(n: String) -> void:
	get_viewport().get_texture().get_image().save_png("res://out/menu_%s.png" % n)
