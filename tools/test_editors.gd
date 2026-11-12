extends SceneTree
## Editor-tool checks for the gameplay content: the Game Editor dock (items, objects,
## looks, skins) and the Map Editor's gameplay objects (place, edit params, auto
## place, undo, save, load in a plain Track). Restores every file it touches.
## Run: godot --headless --path . -s tools/test_editors.gd

var fails := 0
var _backups := {}


func _ok(c: bool, what: String) -> void:
	print(("  ok   " if c else "  FAIL ") + what)
	if not c:
		fails += 1


func _backup(path: String) -> void:
	_backups[path] = FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else null


func _restore_all() -> void:
	for path in _backups:
		if _backups[path] == null:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		else:
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_string(_backups[path])
			f.close()


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := _find_button(c, text)
		if b:
			return b
	return null


func _labels3d(n: Node, out: Array) -> void:
	if n is Label3D:
		out.append((n as Label3D).text)
	for c in n.get_children():
		_labels3d(c, out)


func _init() -> void:
	await process_frame
	_game_editor()
	await process_frame
	_map_editor()
	_restore_all()
	print("EDITORS TEST: " + ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)


func _game_editor() -> void:
	print("== Game Editor")
	var dock: TabContainer = load("res://addons/retro_tools/game_editor_dock.gd").new()
	root.add_child(dock)
	_ok(dock.items_list.item_count >= 20, "items listed (%d)" % dock.items_list.item_count)
	_ok(dock.objects_list.item_count >= 11, "object types listed (%d)" % dock.objects_list.item_count)
	_ok(dock.looks_list.item_count >= 3, "looks listed (%d)" % dock.looks_list.item_count)
	_ok(ItemTypes.behaviour_params("shell").has("mode"), "behaviour fields are read even where the script cannot run")
	dock.load_item("res://content/items/red_shell.json")
	_ok(dock.items_form.get_child_count() > 4, "red shell form built")
	# New item through the button, edit it, save it.
	dock.current_tab = 0
	var items_page := dock.get_child(0)
	var new_btn := _find_button(items_page, "New")
	_ok(new_btn != null, "Items has a New button")
	new_btn.pressed.emit()
	var path: String = dock.item_path
	_backups[path] = null
	_ok(path.begins_with("res://content/items/new_item") and FileAccess.file_exists(path), "New wrote %s" % path)
	dock._set_item("name", "Test Rocket")
	dock._set_item("behaviour", "shell")
	dock._set_item_param("mode", "leader")
	dock._set_item_param("speed", 77.0)
	dock.item_cur.odds[0] = 0
	dock.save_item()
	var saved := FileAccess.get_file_as_string(path)
	var j: Dictionary = JSON.parse_string(saved)
	_ok(j.name == "Test Rocket" and j.behaviour == "shell" and j.params.mode == "leader" and int(j.odds[0]) == 0, "item saved with behaviour, params and odds")
	ItemTypes.reload()
	_ok(ItemTypes.params_of(String(j.id)).speed == 77.0 and ItemTypes.params_of(String(j.id)).bounces == 5, "saved params merge with the behaviour defaults")
	_find_button(items_page, "Delete").pressed.emit()
	_ok(not FileAccess.file_exists(path), "Delete removed it")
	# Objects page
	dock.load_object("res://content/objects/ring_door.json")
	_ok(dock.objects_form.get_child_count() > 2, "object type form built")
	# Skins
	var cpath := "res://content/characters/shadow.json"
	_backup(cpath)
	dock.load_character(cpath)
	_ok(dock.rig_textures(String(dock.char_cur.rig)).size() >= 1, "skin editor lists the rig's textures")
	var sid: String = dock.add_skin("Dark Test")
	dock.char_cur.skins[sid].textures["shadow_0_shadow"] = "res://content/characters/Shadow/SuperShadow.png"
	dock.char_cur["unlock"] = {"emerald": 3}
	dock.save_character()
	var cj: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(cpath))
	_ok(cj.skins.has("dark_test") and cj.skins.has("super") and cj.unlock.emerald == 3.0, "skin and unlock saved next to the existing ones")
	_ok(cj.has("paint") and cj.has("rig"), "the rest of the character definition is kept")
	_ok(dock.parse_unlock("token:5, emerald : 2").size() == 2, "unlock text parses")
	dock.queue_free()


func _map_editor() -> void:
	print("== Map Editor gameplay objects")
	var decor_path := "res://assets/maps/retro_circuit/decor.json"
	_backup(decor_path)
	var dock: Control = load("res://addons/retro_tools/map_editor_dock.gd").new()
	root.add_child(dock)
	dock.load_map("retro_circuit")
	_ok(dock.track != null and dock.track.path.size() > 0, "map loaded")
	var have_obj := false
	for i in dock.palette_pick.item_count:
		if str(dock.palette_pick.get_item_metadata(i)) == "ring_door":
			have_obj = true
	_ok(have_obj, "palette lists gameplay objects")
	var before: int = dock._props().size()
	dock.palette = "ring_door"
	var at: Vector3 = dock.track.path.pos[120]
	dock.add_prop_at(at)
	var e: Dictionary = dock._props()[-1]
	_ok(e.type == "ring_door" and e.params.get("cost") == 20, "door placed with its type's params")
	var t: Vector3 = dock.track.path.tangent[dock.track.path.nearest(at)]
	_ok(absf(angle_difference(deg_to_rad(float(e.yaw)), atan2(-t.x, -t.z))) < 0.05, "it faces along the road")
	dock.set_object_param("cost", 42)
	var labels: Array = []
	_labels3d(dock._prop_nodes()[dock.sel], labels)
	_ok(labels.has("42"), "changing cost rebuilt the door (shows 42)")
	_ok(dock._prop_nodes().size() == dock._props().size(), "nodes still match the props list")
	_ok(dock.obj_box.get_child_count() > 1, "object settings panel shows the door's fields")
	dock.palette = "gold_token"
	dock.add_prop_at(dock.track.path.pos[200])
	var uid1 := String(dock._props()[-1].params.get("uid", ""))
	dock.duplicate_selected()
	var uid2 := String(dock._props()[-1].params.get("uid", ""))
	_ok(uid1 != "" and uid2 != "" and uid1 != uid2, "collectables get their own uid (also when duplicated)")
	var n_before: int = dock._props().size()
	dock.auto_spacing.value = 200.0
	dock.auto_place("item_box_row", 0.0)
	var added: int = dock._props().size() - n_before
	_ok(added >= 5, "auto item boxes placed %d rows" % added)
	dock._undo()
	_ok(dock._props().size() == n_before, "undo takes the auto rows back")
	dock.save()
	var trk := Track.new()
	root.add_child(trk)
	trk.load_track("res://assets/maps/retro_circuit/track.json")
	var doors := 0
	var cost := 0
	for c in trk.props_root.get_children():
		if c is TrackObject and String((c as TrackObject).entry.get("type", "")) == "ring_door":
			doors += 1
			cost = int((c as TrackObject).p.cost)
	_ok(doors == 1 and cost == 42, "a plain Track spawns the saved door with cost 42")
	_ok(trk.props_root.get_child_count() == before + 3, "every saved prop / object spawns")
	dock.remove_gameplay()
	var objs := 0
	for p in dock._props():
		if TrackProps.is_object(String(p.get("type", ""))):
			objs += 1
	_ok(objs == 0 and dock._props().size() == before, "Remove gameplay keeps the decoration")
	trk.queue_free()
	dock.queue_free()
