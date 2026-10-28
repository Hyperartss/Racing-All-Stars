extends SceneTree
## Map Editor smoke test: loads a baked map in the dock, stamps a prop, uses the erase
## brush, refuses an oversized Delete part, restores it, fills a patch, saves
## decor.json and then loads a plain Track (the game path) to check everything arrived:
## the prop is spawned, the patch is built, the erased triangle is gone.
## Run: godot --headless --path . -s tools/test_map_editor.gd

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

	# 2. The first road surface (a connector strip) is a big connected piece.
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
	var tri: Array = dock._face(si, 0)
	var centre: Vector3 = (tri[0] + tri[1] + tri[2]) / 3.0

	# 3. Delete part: this road strip is one welded piece, so all of it goes.
	dock._delete_part({"surface": si, "face": 0})
	ok = ok and _check(dock._hidden_face_count() == tris_before,
		"Delete part removed the whole connected piece (%d of %d)" % [dock._hidden_face_count(), tris_before])
	dock.restore_faces()
	ok = ok and _check(dock._hidden_face_count() == 0, "Restore faces brings the piece back")

	# 4. Erase brush, then the restore brush paints it back.
	dock._brush_hide(centre, 0.35)
	var erased: int = dock._hidden_face_count()
	ok = ok and _check(erased >= 1, "erase brush hid triangles (%d)" % erased)
	dock._drag = 4
	dock._stroke_dirty = true
	dock._end_drag()
	ok = ok and _check(dock._hidden_face_count() == erased, "stroke applied")
	dock._brush_show(centre, 0.35)
	ok = ok and _check(dock._hidden_face_count() == 0, "restore brush brings them back")
	dock._drag = 4
	dock._stroke_dirty = true
	dock._end_drag()

	# 5. Fill a patch where the road is, then leave one triangle erased for the save.
	dock._make_patch({"surface": si, "face": 0, "pos": centre})
	ok = ok and _check(dock._patch_count() == 1, "fill made one patch")
	dock._brush_hide(centre, 0.35)
	var erased_final: int = dock._hidden_face_count()
	dock._drag = 4
	dock._stroke_dirty = true
	dock._end_drag()

	# 6. Camera picking + a gizmo move, as the mouse would do it.
	dock._select(0)
	dock._frame()
	var view_centre := Vector2(dock.viewport.size) * 0.5
	ok = ok and _check(dock._pick_prop(view_centre) == 0, "camera picks the prop at the view centre")
	ok = ok and _check(not dock._pick_triangle(view_centre).is_empty(), "camera ray hits the course")
	var before_move: Vector3 = dock._selected_node().global_position
	dock._begin_gizmo_drag(0, view_centre)
	dock._drag_gizmo(Vector2(40, 0), view_centre)
	dock._drag = 3
	dock._end_drag()
	var after_move: Vector3 = dock._selected_node().global_position
	ok = ok and _check(not before_move.is_equal_approx(after_move), "gizmo move changes the prop")
	var snap_hit: Dictionary = dock._raycast(after_move + Vector3.UP * 60.0, Vector3.DOWN, 400.0)
	ok = ok and _check(not snap_hit.is_empty(), "snap-to-ground ray finds the course")
	var stored: Vector3 = TrackProps.vec(dock._props()[0].pos)
	ok = ok and _check(stored.distance_to(after_move) < 0.02,
		"gizmo move is written to the data (%s vs %s)" % [stored, after_move])

	# 7. Save and reload through the dock (decor.json is read back).
	dock.save()
	ok = ok and _check(FileAccess.file_exists(decor_path), "decor.json written")
	dock.load_map(dock.map_id)
	ok = ok and _check(dock._props().size() == 1, "prop survived the reload")
	ok = ok and _check(dock._hidden_face_count() == erased_final, "erased triangles survived the reload")
	ok = ok and _check(dock._patch_count() == 1, "patch survived the reload")

	# 8. Hiding a whole surface drops it from the mesh.
	var mesh_before: ArrayMesh = (dock.track.get_node("CourseMesh") as MeshInstance3D).mesh
	var surfs_before := mesh_before.get_surface_count()
	dock.decor["hidden_surfaces"] = [0]
	dock._apply_decor()
	var mesh_after: ArrayMesh = (dock.track.get_node("CourseMesh") as MeshInstance3D).mesh
	ok = ok and _check(mesh_after.get_surface_count() == surfs_before - 1, "hidden surface is skipped")
	ok = ok and _check(not dock.track.surface_geo.has(0), "hidden surface is not pickable")
	dock.decor["hidden_surfaces"] = []
	dock._apply_decor()

	# 9. A plain Track is what the game loads.
	var t := Track.new()
	get_root().add_child(t)
	t.load_track(data_path)
	var props: Array = t.decor.get("props", [])
	ok = ok and _check(props.size() == 1, "game Track reads the prop")
	ok = ok and _check(t.props_root != null and t.props_root.get_child_count() == 1,
		"game Track spawns the prop")
	var patches: Array = t.decor.get("patches", [])
	ok = ok and _check(patches.size() == 1, "game Track reads the patch")
	var patch_node := t.get_node_or_null("Patches") as MeshInstance3D
	ok = ok and _check(patch_node != null and patch_node.mesh.get_surface_count() == 1,
		"game Track builds the patch mesh")
	if patch_node != null:
		ok = ok and _check(patch_node.mesh.surface_get_array_index_len(0) == 6,
			"patch is two triangles")
	var mesh: ArrayMesh = (t.get_node("CourseMesh") as MeshInstance3D).mesh
	var tris_after: int = mesh.surface_get_array_index_len(si) / 3
	ok = ok and _check(tris_after == tris_before - erased_final,
		"erased triangles are missing from the course mesh (%d -> %d)" % [tris_before, tris_after])
	ok = ok and _check(t.hidden_faces.has(si), "game Track knows the erased face")

	_cleanup(decor_path, had_decor)

	# 10. On the big merged course, Delete part refuses an oversized piece.
	dock.load_map("retro_circuit")
	var big := -1
	for k in dock.track.surface_geo:
		var gg: Dictionary = dock.track.surface_geo[k]
		if String(gg["class"]) == "road" and gg["idx"].size() / 3 > dock.MAX_PART:
			big = k
			break
	ok = ok and _check(big >= 0, "retro_circuit has a road piece over MAX_PART")
	if big >= 0:
		dock._delete_part({"surface": big, "face": 0})
		ok = ok and _check(dock._hidden_face_count() == 0, "Delete part refuses the oversized piece")
		ok = ok and _check(dock.status_label.text.contains("too big"), "and says why")

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
