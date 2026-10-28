extends SceneTree
## Map Editor smoke test: loads a baked map in the dock, stamps a prop, erases a
## triangle, saves decor.json and then loads a plain Track (the game path) to check
## that the decoration arrived: the prop is spawned and the erased triangle is gone.
## Run: godot --headless --path . -s tools/test_map_editor.gd

const MAP_JSON := "res://other/does-not-exist.json"   # replaced from the dock below
const DOCK := "res://addons/retro_tools/map_editor_dock.gd"


func _init() -> void:
	var dock: Control = load(DOCK).new()
	get_root().add_child(dock)
	await process_frame
	await process_frame
	if dock.track == null:
		_fail("the dock did not load a map")
		return
	var data_path: String = dock.data_path
	var decor_path := data_path.get_base_dir() + "/decor.json"
	var had_decor := FileAccess.file_exists(decor_path)
	var ok := true

	print("map %s: %d surfaces, %d props, %d samples" % [dock.map_id,
		dock.track.data.surfaces.size(), dock._props().size(), dock.track.path.size()])

	# 1. Stamp a prop on the start straight.
	dock.palette = "tree"
	dock.tint_pick.color = TrackProps.default_tint("tree")
	dock.add_prop_at(dock.track.path.pos[6])
	ok = ok and _check(dock._props().size() == 1, "one prop in the data")
	ok = ok and _check(dock._prop_nodes().size() == 1, "one prop node in the preview")

	# 2. Erase one triangle from the first road surface.
	var si := -1
	for k in dock.track.surface_geo:
		if String(dock.track.surface_geo[k]["class"]) == "road":
			si = k
			break
	ok = ok and _check(si >= 0, "found a road surface")
	if si < 0:
		_cleanup(decor_path, had_decor)
		_fail("no road surface")
		return
	var tris_before: int = dock.track.surface_geo[si]["idx"].size() / 3
	dock._erase({"surface": si, "face": 0})
	dock._drag = 4
	dock._erased = true
	dock._end_drag()
	ok = ok and _check(dock._hidden_face_count() == 1, "one erased triangle")

	# 3. Camera picking + a gizmo move, as the mouse would do it.
	dock._select(0)
	dock._frame()
	var centre := Vector2(dock.viewport.size) * 0.5
	ok = ok and _check(dock._pick_prop(centre) == 0, "camera picks the prop at the view centre")
	ok = ok and _check(not dock._pick_triangle(centre).is_empty(), "camera ray hits the course")
	var before_move: Vector3 = dock._selected_node().global_position
	dock._begin_gizmo_drag(0, centre)
	dock._drag_gizmo(Vector2(40, 0), centre)
	dock._drag = 3
	dock._end_drag()
	var after_move: Vector3 = dock._selected_node().global_position
	ok = ok and _check(not before_move.is_equal_approx(after_move), "gizmo move changes the prop")
	var snap_hit: Dictionary = dock._raycast(after_move + Vector3.UP * 60.0, Vector3.DOWN, 400.0)
	ok = ok and _check(not snap_hit.is_empty(), "snap-to-ground ray finds the course")
	var stored: Vector3 = TrackProps.vec(dock._props()[0].pos)
	ok = ok and _check(stored.distance_to(after_move) < 0.02,
		"gizmo move is written to the data (%s vs %s)" % [stored, after_move])

	# 4. Save and reload through the dock (decor.json is read back).
	dock.save()
	ok = ok and _check(FileAccess.file_exists(decor_path), "decor.json written")
	dock.load_map(dock.map_id)
	ok = ok and _check(dock._props().size() == 1, "prop survived the reload")
	ok = ok and _check(dock._hidden_face_count() == 1, "erased triangle survived the reload")

	# 5. Hiding a whole surface drops it from the mesh.
	var mesh_before: ArrayMesh = (dock.track.get_node("CourseMesh") as MeshInstance3D).mesh
	var surfs_before := mesh_before.get_surface_count()
	dock.decor["hidden_surfaces"] = [0]
	dock._apply_decor()
	var mesh_after: ArrayMesh = (dock.track.get_node("CourseMesh") as MeshInstance3D).mesh
	ok = ok and _check(mesh_after.get_surface_count() == surfs_before - 1, "hidden surface is skipped")
	ok = ok and _check(not dock.track.surface_geo.has(0), "hidden surface is not pickable")
	dock.decor["hidden_surfaces"] = []
	dock._apply_decor()

	# 6. A plain Track is what the game loads.
	var t := Track.new()
	get_root().add_child(t)
	t.load_track(data_path)
	var props: Array = t.decor.get("props", [])
	ok = ok and _check(props.size() == 1, "game Track reads the prop")
	ok = ok and _check(t.props_root != null and t.props_root.get_child_count() == 1,
		"game Track spawns the prop")
	var mesh: ArrayMesh = (t.get_node("CourseMesh") as MeshInstance3D).mesh
	var tris_after: int = mesh.surface_get_array_index_len(si) / 3
	ok = ok and _check(tris_after == tris_before - 1,
		"erased triangle is missing from the course mesh (%d -> %d)" % [tris_before, tris_after])
	ok = ok and _check(t.hidden_faces.has(si), "game Track knows the erased face")

	_cleanup(decor_path, had_decor)
	print("MAP EDITOR TEST: " + ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _check(cond: bool, what: String) -> bool:
	print(("  ok   " if cond else "  FAIL ") + what)
	return cond


## The test writes a real decor.json; remove it again unless the project had one.
func _cleanup(path: String, had: bool) -> void:
	if not had and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _fail(msg: String) -> void:
	print("MAP EDITOR TEST: FAIL - " + msg)
	quit(1)
