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

	# 5. Fill only paints empty space: a stroke over intact road paints nothing at all.
	dock._fill_set_level({"surface": si, "face": 0, "pos": centre})
	dock._fill_stamp_world(centre)
	ok = ok and _check(dock._fill_cells.is_empty(), "a stroke over intact ground paints no cells")
	dock._fill_commit()
	ok = ok and _check(dock._patch_count() == 0, "and makes no patch")
	ok = ok and _check(dock.status_label.text.contains("nothing empty"), "and says why")

	# 5a. Cover existing: the same stroke does paint over the road when asked.
	dock._fill_cover = true
	dock._fill_seen.clear()
	dock._fill_cells.clear()
	dock._fill_keys.clear()
	dock._fill_last = Vector2.INF
	dock._fill_stamp_world(centre)
	ok = ok and _check(dock._fill_cells.size() > 1,
		"Cover existing paints over the road (%d cells)" % dock._fill_cells.size())
	dock._fill_cover = false
	dock._fill_cells.clear()
	dock._fill_seen.clear()
	dock._fill_keys.clear()

	# 5b. Erase a hole in the road, then paint over it: only the hole is filled, as one
	#     sheet whose cells share corners.
	dock._brush_hide(centre, 2.5)
	dock._drag = 4
	dock._stroke_dirty = true
	dock._end_drag()
	dock._fill_seen.clear()
	dock._fill_cells.clear()
	dock._fill_keys.clear()
	dock._fill_last = Vector2.INF
	dock._fill_stamp_world(centre)
	var stroke_cells: int = dock._fill_cells.size()
	ok = ok and _check(stroke_cells > 1, "fill paints the hole only (%d cells)" % stroke_cells)
	dock._fill_commit()
	ok = ok and _check(dock._patch_count() == 1, "one stroke made one patch")
	var first: Dictionary = dock.decor["patches"][0]
	ok = ok and _check((first["idx"] as Array).size() == stroke_cells * 6,
		"the patch is one sheet (%d tris for %d cells)" % [(first["idx"] as Array).size() / 3, stroke_cells])
	ok = ok and _check((first["verts"] as Array).size() < stroke_cells * 4,
		"cells share corners instead of stacking quads (%d verts)" % (first["verts"] as Array).size())

	# 5c. It stays on its level: no vertex is dragged metres off the plane.
	var flat_ok := true
	var plane_point: Vector3 = dock._fill_origin
	for v in (first["verts"] as Array):
		var q: Vector3 = dock._vec_of(v)
		if absf((q - plane_point).dot(dock._fill_normal)) > dock.FILL_CONFORM + dock.FILL_LIFT:
			flat_ok = false
	ok = ok and _check(flat_ok, "the sheet stays on its level")

	# 5d. Another stroke in the same hole must extend that patch, not lay a second
	#     coplanar one over it (which is what z-fights).
	dock._fill_seen.clear()
	dock._fill_cells.clear()
	dock._fill_keys.clear()
	dock._fill_last = Vector2.INF
	dock._fill_stamp_world(centre + dock.track.path.right[0] * 0.8)
	dock._fill_commit()
	ok = ok and _check(dock._patch_count() == 1, "a second stroke extends the same patch")
	var merged_cells: int = (dock.decor["patches"][0]["cells"] as Array).size()
	var merged_idx: Array = dock.decor["patches"][0]["idx"]
	ok = ok and _check(merged_cells >= stroke_cells, "the patch holds %d cells" % merged_cells)
	ok = ok and _check(merged_idx.size() == merged_cells * 6, "no overlapping quads in the sheet")

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
	ok = ok and _check(dock._fill_plane_at(view_centre), "fill takes a level from the viewport")
	ok = ok and _check(dock._fill_plane_at(Vector2(-4000, -4000)),
		"fill keeps the last level when the cursor is over nothing")
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
	var patch_cells: int = (patches[0]["cells"] as Array).size()
	var patch_node := t.get_node_or_null("Patches") as MeshInstance3D
	ok = ok and _check(patch_node != null and patch_node.mesh.get_surface_count() == 1,
		"game Track builds the patch mesh")
	if patch_node != null:
		ok = ok and _check(patch_node.mesh.surface_get_array_index_len(0) == patch_cells * 6,
			"game Track built all %d cells of the filled sheet" % patch_cells)
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
		var hidden_before: int = dock._hidden_face_count()
		dock._delete_part({"surface": big, "face": 0})
		ok = ok and _check(dock._hidden_face_count() == hidden_before,
			"Delete part refuses the oversized piece")
		ok = ok and _check(dock.status_label.text.contains("too big"), "and says why")

	# 11. The point of the rework: erase a hole in the course, then paint over it. The
	#     cursor is over nothing at all, so the level has to come from the ground beside
	#     the hole, and the stroke must fill it.
	var hole_at: Vector3 = dock.track.path.pos[40]
	dock.focus = hole_at
	dock.cam_dist = 30.0
	dock.cam_pitch = 1.2
	dock._update_camera()
	var hole_vp := Vector2(dock.viewport.size) * 0.5
	var hole_hit: Dictionary = dock._pick_triangle(hole_vp)
	var hole_tri: Array = dock._face(int(hole_hit.get("surface", -1)), int(hole_hit.get("face", -1)))
	var hole_n: Vector3 = (hole_tri[1] - hole_tri[0]).cross(hole_tri[2] - hole_tri[0]).normalized()
	var hole_c: Vector3 = hole_tri[0]
	dock._brush_hide(hole_at, 6.0)
	dock._drag = 4
	dock._stroke_dirty = true
	dock._end_drag()
	ok = ok and _check(dock._pick_triangle(hole_vp).is_empty(), "the erased hole reads as empty space")
	ok = ok and _check(not dock._fill_nearby_hit(hole_vp).is_empty(),
		"fill takes its level from the ground beside the hole")
	var patches_before: int = dock._patch_count()
	dock._begin_fill(hole_vp)
	ok = ok and _check(not dock._fill_cells.is_empty(),
		"the brush paints on empty space (%d cells)" % dock._fill_cells.size())
	dock._drag = 5
	dock._end_drag()
	ok = ok and _check(dock._patch_count() == patches_before + 1, "a stroke over the hole made a patch")
	var hp: Dictionary = dock.decor["patches"][dock._patch_count() - 1]
	# The level comes from the ground around the hole, which may be another road tile,
	# so check that the sheet is flat on its own level and that the level is the road's.
	var hole_flat := true
	var hole_gap := 0.0
	for v in (hp["verts"] as Array):
		var q: Vector3 = dock._vec_of(v)
		var d: float = absf((q - dock._fill_origin).dot(dock._fill_normal))
		hole_gap = maxf(hole_gap, d)
		if d > dock.FILL_CONFORM + dock.FILL_LIFT:
			hole_flat = false
	ok = ok and _check(hole_flat, "the patch stays flat on its level (max %.2f m off)" % hole_gap)
	ok = ok and _check(absf(dock._fill_normal.dot(hole_n)) > 0.9,
		"and that level is the road's (normal dot %.2f)" % dock._fill_normal.dot(hole_n))

	# 12. A wall: two vertical pieces with a 2 m gap, put 500 m above the map so nothing
	#     else can supply the level. Hovering the gap must take the wall's own plane (not
	#     the ground far below) and the stroke must bridge the two pieces.
	var wall_si := 999
	# Two 6 x 16 m walls with a 2 m gap, solid enough that the whole brush footprint is
	# either on a wall or in the gap (so anything else painted would be over the wall).
	var quad := [Vector3(-7, -4, 0), Vector3(-1, -4, 0), Vector3(-1, 12, 0), Vector3(-7, 12, 0),
		Vector3(1, -4, 0), Vector3(7, -4, 0), Vector3(7, 12, 0), Vector3(1, 12, 0)]
	var wpos := PackedVector3Array()
	for v in quad:
		wpos.append(v + Vector3(0, 500, 0))
	var wuv := PackedVector2Array()
	wuv.resize(wpos.size())
	dock.track.surface_geo[wall_si] = {"pos": wpos,
		"idx": PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]),
		"uv": wuv, "class": "wall", "texture": "wall_test.png", "alpha": false}
	dock._build_pick_grid()
	dock.focus = Vector3(0, 504, 0)
	dock.cam_dist = 22.0
	dock.cam_yaw = 0.0
	dock.cam_pitch = 0.02
	dock._update_camera()
	var wall_vp := Vector2(dock.viewport.size) * 0.5
	ok = ok and _check(dock._pick_triangle(wall_vp).is_empty(), "the gap between the wall pieces is empty")
	var near_hit: Dictionary = dock._fill_nearby_hit(wall_vp)
	ok = ok and _check(not near_hit.is_empty()
			and Vector3(near_hit.normal).dot(Vector3.BACK) > 0.9,
		"fill takes the wall's level, not the ground below it")

	# 12b. Pointing at the solid wall and painting does nothing: Fill only fills holes.
	var on_wall_vp: Vector2 = dock._project(Vector3(3.0, 504.0, 0.0))
	ok = ok and _check(on_wall_vp.is_finite() and not dock._pick_triangle(on_wall_vp).is_empty(),
		"the solid wall is under the cursor there")
	var patches_now: int = dock._patch_count()
	var saved_radius: float = dock.brush_radius.value
	dock.brush_radius.value = 1.0      # small brush: its whole footprint is solid wall
	dock._fill_ok = false
	dock._begin_fill(on_wall_vp)
	ok = ok and _check(dock._fill_cells.is_empty(), "painting on the solid wall paints nothing")
	dock._drag = 5
	dock._end_drag()
	ok = ok and _check(dock._patch_count() == patches_now, "and adds no patch")

	# 12c. Now the gap itself: the level is the wall's, only the gap is painted.
	dock.brush_radius.value = saved_radius
	dock._fill_ok = false
	dock._begin_fill(wall_vp)
	ok = ok and _check(dock._fill_normal.dot(Vector3.BACK) > 0.9,
		"the wall fill sits on the camera side (normal dot %.2f)" % dock._fill_normal.dot(Vector3.BACK))
	ok = ok and _check(not dock._fill_cells.is_empty(),
		"painted %d cells on the wall" % dock._fill_cells.size())
	dock._drag = 5
	dock._end_drag()
	var wp: Dictionary = dock.decor["patches"][dock._patch_count() - 1]
	var flat := true
	var xmin := INF
	var xmax := -INF
	for v in (wp["verts"] as Array):
		var q: Vector3 = dock._vec_of(v)
		if absf(q.z - dock.FILL_LIFT) > 0.05:
			flat = false
		xmin = minf(xmin, q.x)
		xmax = maxf(xmax, q.x)
	ok = ok and _check(flat, "the wall sheet lies on the wall, %.3f m in front of it" % dock.FILL_LIFT)
	ok = ok and _check(xmin < -0.4 and xmax > 0.4,
		"the sheet reaches both wall pieces (x %.1f .. %.1f)" % [xmin, xmax])
	ok = ok and _check(xmin > -1.8 and xmax < 1.8,
		"and it fills only the gap, not over the wall itself")

	# 13. Hole (7): one click closes a whole enclosed gap. A 4 x 4 m hole in a 20 x 20 m
	#     ground quad, 700 m up so nothing else can interfere.
	var gverts: Array = []
	var gidx: Array = []
	for q in [[Vector2(-10, -10), Vector2(10, -10), Vector2(10, -2), Vector2(-10, -2)],
			[Vector2(-10, 2), Vector2(10, 2), Vector2(10, 10), Vector2(-10, 10)],
			[Vector2(-10, -2), Vector2(-2, -2), Vector2(-2, 2), Vector2(-10, 2)],
			[Vector2(2, -2), Vector2(10, -2), Vector2(10, 2), Vector2(2, 2)]]:
		var base: int = gverts.size()
		for c in q:
			# 5 km away from the course, so nothing of the map is under the hole.
			gverts.append(Vector3(c.x + 5000.0, 700.0, c.y + 5000.0))
		gidx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var gpos := PackedVector3Array(gverts)
	var guv := PackedVector2Array()
	guv.resize(gpos.size())
	dock.track.surface_geo[998] = {"pos": gpos, "idx": PackedInt32Array(gidx), "uv": guv,
		"class": "off", "texture": "hole_test.png", "alpha": false}
	dock._build_pick_grid()
	dock.focus = Vector3(5000, 700, 5000)
	dock.cam_dist = 26.0
	dock.cam_yaw = 0.0
	dock.cam_pitch = 1.45
	dock._update_camera()
	var hole2_vp: Vector2 = dock._project(Vector3(5000.0, 700.0, 5000.0))
	ok = ok and _check(hole2_vp.is_finite() and dock._pick_triangle(hole2_vp).is_empty(),
		"the 4 x 4 m hole is empty space")
	var before_hole: int = dock._patch_count()
	var solid_vp: Vector2 = dock._project(Vector3(5006.0, 700.0, 5006.0))
	dock._fill_hole_at(solid_vp)
	ok = ok and _check(dock._patch_count() == before_hole, "Hole on solid ground makes no patch")
	ok = ok and _check(dock.status_label.text.contains("solid"), "and says the spot is solid")
	dock._fill_hole_at(hole2_vp)
	ok = ok and _check(dock._patch_count() == before_hole + 1, "Hole closed the gap in one click")
	var hp2: Dictionary = dock.decor["patches"][dock._patch_count() - 1]
	var hcells: int = (hp2["cells"] as Array).size()
	ok = ok and _check(hcells >= 9, "it filled the whole %d-cell outline" % hcells)
	var in_hole := true
	var hlevel := 0.0
	for v in (hp2["verts"] as Array):
		var q: Vector3 = dock._vec_of(v)
		if absf(q.x - 5000.0) > 2.3 or absf(q.z - 5000.0) > 2.3:
			in_hole = false
		hlevel = maxf(hlevel, absf(q.y - 700.0))
	ok = ok and _check(in_hole, "the sheet stays inside the hole outline")
	ok = ok and _check(hlevel < 0.2, "and on the ground level (max %.2f m off)" % hlevel)

	# 13b. A break in a narrow path is open along its sides. Hole must still close it,
	#      clipped to the strip between the two ends of the path.
	var pverts := PackedVector3Array([
		Vector3(4999, 800, 5490), Vector3(5001, 800, 5490), Vector3(5001, 800, 5498),
		Vector3(4999, 800, 5498), Vector3(4999, 800, 5502), Vector3(5001, 800, 5502),
		Vector3(5001, 800, 5510), Vector3(4999, 800, 5510)])
	var pidx := PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
	var puv := PackedVector2Array()
	puv.resize(pverts.size())
	dock.track.surface_geo[997] = {"pos": pverts, "idx": pidx, "uv": puv,
		"class": "road", "texture": "brick_test.png", "alpha": false}
	dock._build_pick_grid()
	dock.focus = Vector3(5000, 800, 5500)
	dock.cam_dist = 26.0
	dock.cam_yaw = 0.0
	dock.cam_pitch = 1.45
	dock._update_camera()
	var path_vp: Vector2 = dock._project(Vector3(5000.0, 800.0, 5500.0))
	var before_path: int = dock._patch_count()
	dock._fill_hole_at(path_vp)
	ok = ok and _check(dock._patch_count() == before_path + 1, "Hole closes a break in a narrow path")
	var pp: Dictionary = dock.decor["patches"][dock._patch_count() - 1]
	var pcs: int = (pp["cells"] as Array).size()
	var inside_path := true
	var dx_max := 0.0
	var dz_max := 0.0
	for v in (pp["verts"] as Array):
		var q: Vector3 = dock._vec_of(v)
		dx_max = maxf(dx_max, absf(q.x - 5000.0))
		dz_max = maxf(dz_max, absf(q.z - 5500.0))
		# An open gap may reach one cell past the edge of the surface it bridges.
		if absf(q.x - 5000.0) > 1.8 or absf(q.z - 5500.0) > 2.8:
			inside_path = false
	ok = ok and _check(pcs >= 4 and inside_path,
		"and keeps it between the path ends (%d cells, x %.1f z %.1f)" % [pcs, dx_max, dz_max])
	ok = ok and _check(dock.status_label.text.contains("open"), "and says the gap is open")

	# 14. Edge fill (8): pick the rim edges around a hole and close it with real triangles.
	#     A 20 x 20 m ground plane with a 4 x 4 m hole, metrically mapped UVs.
	var ev: Array = []
	var euv: Array = []
	var ei: Array = []
	var estride := 6
	var ecoords := [-10.0, -6.0, -2.0, 2.0, 6.0, 10.0]
	for z in estride:
		for x in estride:
			ev.append(Vector3(9000.0 + ecoords[x], 700.0, 9000.0 + ecoords[z]))
			euv.append(Vector2(ecoords[x] * 0.25, ecoords[z] * 0.25))
	# Upward winding, with the hole's four corners as real vertices so its rim chains.
	for z in estride - 1:
		for x in estride - 1:
			if x == 2 and z == 2:
				continue
			var a := z * estride + x
			var d := a + estride
			var c := d + 1
			var b := a + 1
			ei.append_array([a, d, c, a, c, b])
	dock.track.surface_geo[996] = {"pos": PackedVector3Array(ev), "idx": PackedInt32Array(ei),
		"uv": PackedVector2Array(euv), "class": "road", "texture": "rim_test.png", "alpha": false}
	dock._build_pick_grid()
	dock.focus = Vector3(9000, 700, 9000)
	dock.cam_dist = 30.0
	dock.cam_yaw = 0.0
	dock.cam_pitch = 1.45
	dock._update_camera()
	dock.clear_edges()
	var hole_centre := Vector3(9000, 700, 9000)
	var rim_outside := [Vector3(9002.6, 700, 9000), Vector3(8997.4, 700, 9000),
		Vector3(9000, 700, 9002.6), Vector3(9000, 700, 8997.4)]
	var picked := 0
	for p in rim_outside:
		var e: Dictionary = dock._edge_pick(dock._project(p))
		if not e.is_empty():
			dock._edge_toggle(e)
			picked += 1
	ok = ok and _check(picked == 4, "picked the four rim edges of the 4 x 4 m hole (%d)" % picked)
	ok = ok and _check(dock.edge_sel.size() == 4, "four rim edges selected")
	ok = ok and _check(dock.edge_label.text.contains("tri"),
		"the panel shows the live triangle count: \"%s\"" % dock.edge_label.text)
	var sol: Dictionary = dock.edge_solve()
	ok = ok and _check(bool(sol.get("ok", false)), "the rim solves into a fill plan")
	ok = ok and _check(String(sol.get("mode", "")) == "loop", "one closed rim -> polygon fill")
	ok = ok and _check(absf(float(sol.get("area", 0.0)) - 16.0) < 0.6,
		"the planned area is the hole's (%.2f m2)" % float(sol.get("area", 0.0)))
	ok = ok and _check((sol.get("tris", []) as Array).size() >= 2, "and it is triangulated")
	ok = ok and _check(String(sol.get("tex", "")) == "rim_test.png",
		"the texture comes from the rim's own surface")
	var pl: Dictionary = sol.get("plane", {})
	ok = ok and _check(Vector3(pl.get("n", Vector3.ZERO)).dot(Vector3.UP) > 0.9,
		"the fill faces the camera (dot %.2f)" % Vector3(pl.get("n", Vector3.ZERO)).dot(Vector3.UP))
	var planned_tris: int = (sol.get("tris", []) as Array).size()
	# Clicking a selected edge again takes it back out.
	var again: Dictionary = dock._edge_pick(dock._project(Vector3(9002.6, 700, 9000)))
	ok = ok and _check(not again.is_empty(), "the picked edge is still under the cursor")
	dock._edge_toggle(again)
	ok = ok and _check(dock.edge_sel.size() == 3, "clicking a selected edge removes it")
	dock._edge_toggle(again)
	ok = ok and _check(dock.edge_sel.size() == 4, "clicking it again adds it back")
	var patches_before_edge: int = dock._patch_count()
	dock.fill_edges()
	ok = ok and _check(dock._patch_count() == patches_before_edge + 1, "Fill edges added one patch")
	ok = ok and _check(dock.edge_sel.is_empty(), "the fill consumed the rim")
	ok = ok and _check(dock.status_label.text.contains("triangles"),
		"and reports its triangle count: \"%s\"" % dock.status_label.text)
	var ep: Dictionary = {}
	if dock._patch_count() > patches_before_edge:
		ep = dock.decor["patches"][dock._patch_count() - 1]
	ok = ok and _check(String(ep.get("texture", "")) == "rim_test.png"
		and String(ep.get("class", "")) == "road",
		"the patch keeps the surface's texture and class")
	ok = ok and _check((ep.get("idx", []) as Array).size() == planned_tris * 3,
		"it holds the planned %d triangles" % planned_tris)
	var pnode := dock.track.get_node_or_null("Patches") as MeshInstance3D
	ok = ok and _check(pnode != null and pnode.mesh.get_surface_count() == dock._patch_count(),
		"the course builds the edge patch into its own mesh (%d patches)" % dock._patch_count())
	var ep_inside := true
	var ep_flat := 0.0
	var ep_uv := true
	for i in (ep["verts"] as Array).size():
		var q: Vector3 = dock._vec_of((ep["verts"] as Array)[i])
		if absf(q.x - hole_centre.x) > 2.05 or absf(q.z - hole_centre.z) > 2.05:
			ep_inside = false
		ep_flat = maxf(ep_flat, absf(q.y - 700.0))
		var uv: Array = (ep["uv"] as Array)[i]
		if absf(float(uv[0]) - (q.x - 9000.0) * 0.25) > 0.001 \
				or absf(float(uv[1]) - (q.z - 9000.0) * 0.25) > 0.001:
			ep_uv = false
	ok = ok and _check(ep_inside, "the sheet stays inside the hole outline")
	ok = ok and _check(ep_flat < 0.01, "exactly on the hole's plane (%.3f m off)" % ep_flat)
	ok = ok and _check(ep_uv, "UVs continue the neighbouring surface's mapping")
	var seam := true
	for c in [Vector2(-2, -2), Vector2(2, -2), Vector2(2, 2), Vector2(-2, 2)]:
		var want := Vector3(9000.0 + c.x, 700.0, 9000.0 + c.y)
		var found := false
		for v in (ep["verts"] as Array):
			if dock._vec_of(v).distance_to(want) < 0.02:
				found = true
				break
		if not found:
			seam = false
	ok = ok and _check(seam, "the patch reuses the rim vertices, so its seam is watertight")

	# 15. Density: a 4 x 4 m hole in a 1 m grid asks for ~1 m triangles. The plan reports
	#     the count before anything is written; without matching it stays the raw 2.
	var fv: Array = []
	var fuv: Array = []
	var fi: Array = []
	var stride := 21
	for z in stride:
		for x in stride:
			fv.append(Vector3(12000.0 + float(x) - 10.0, 700.0, 12000.0 + float(z) - 10.0))
			fuv.append(Vector2(float(x) * 0.25, float(z) * 0.25))
	for z in 20:
		for x in 20:
			if x >= 8 and x < 12 and z >= 8 and z < 12:
				continue
			var a := z * stride + x
			var d := a + stride
			var c := d + 1
			var b := a + 1
			fi.append_array([a, d, c, a, c, b])
	dock.track.surface_geo[995] = {"pos": PackedVector3Array(fv), "idx": PackedInt32Array(fi),
		"uv": PackedVector2Array(fuv), "class": "road", "texture": "rim_test.png", "alpha": false}
	dock._build_pick_grid()
	dock.focus = Vector3(12000, 700, 12000)
	dock.cam_dist = 30.0
	dock.cam_yaw = 0.0
	dock.cam_pitch = 1.45
	dock._update_camera()
	dock.clear_edges()
	# Shift+click follows the surface's rim, so one click takes the whole 16-edge outline.
	var seed_pick: Dictionary = dock._edge_pick(dock._project(Vector3(12002.35, 700.0, 11999.5)))
	ok = ok and _check(not seed_pick.is_empty(), "a fine-grid rim edge is under the cursor")
	dock.clear_edges()
	var grown: int = dock.edge_grow(seed_pick)
	ok = ok and _check(grown == 16 and dock.edge_sel.size() == 16,
		"Shift+click took the whole 16-edge rim loop (%d)" % grown)
	dock.edge_density.button_pressed = false
	var raw: Dictionary = dock.edge_solve()
	var raw_tris: int = (raw.get("tris", []) as Array).size()
	ok = ok and _check(bool(raw.get("ok", false)) and raw_tris >= 2,
		"without density matching the rim is its raw %d triangles" % raw_tris)
	dock.edge_density.button_pressed = true
	var fine: Dictionary = dock.edge_solve()
	var fine_tris: int = (fine.get("tris", []) as Array).size()
	var fine_target := float(fine.get("target", 0.0))
	ok = ok and _check(fine_tris > raw_tris,
		"matching the 1 m neighbour grid plans %d triangles" % fine_tris)
	ok = ok and _check(fine_target > 0.5 and fine_target < 2.0,
		"the target edge length follows the neighbour (%.2f m)" % fine_target)
	dock.fill_edges()
	var fp: Dictionary = dock.decor["patches"][dock._patch_count() - 1]
	var fp_max := 0.0
	for ti in (fp["idx"] as Array).size() / 3:
		for k in 3:
			var p0: Vector3 = dock._vec_of((fp["verts"] as Array)[int(fp["idx"][ti * 3 + k])])
			var p1: Vector3 = dock._vec_of((fp["verts"] as Array)[int(fp["idx"][ti * 3 + (k + 1) % 3])])
			fp_max = maxf(fp_max, p0.distance_to(p1))
	ok = ok and _check(fp_max < 2.0,
		"the built triangles are about the neighbour's size (max %.2f m)" % fp_max)

	# 16. Two separate rims: a gap between two wall pieces. Selecting the inner edge of
	#     each gives a bridge instead of a polygon, textured by the wall's own surface.
	var wv2: Array = []
	var widx2: Array = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
	for v in [Vector3(-7, -4, 0), Vector3(-1, -4, 0), Vector3(-1, 12, 0), Vector3(-7, 12, 0),
			Vector3(1, -4, 0), Vector3(7, -4, 0), Vector3(7, 12, 0), Vector3(1, 12, 0)]:
		wv2.append(v + Vector3(0, 1500, 0))
	var wuv2 := PackedVector2Array()
	wuv2.resize(wv2.size())
	dock.track.surface_geo[994] = {"pos": PackedVector3Array(wv2), "idx": PackedInt32Array(widx2),
		"uv": wuv2, "class": "wall", "texture": "wall_test.png", "alpha": false}
	dock._build_pick_grid()
	dock.focus = Vector3(0, 1504, 0)
	dock.cam_dist = 22.0
	dock.cam_yaw = 0.0
	dock.cam_pitch = 0.02
	dock._update_camera()
	dock.clear_edges()
	var left: Dictionary = dock._edge_pick(dock._project(Vector3(-1.5, 1504.0, 0.0)))
	var right: Dictionary = dock._edge_pick(dock._project(Vector3(1.5, 1504.0, 0.0)))
	ok = ok and _check(not left.is_empty() and not right.is_empty(),
		"picked the inner edge of each wall piece")
	if not left.is_empty() and not right.is_empty():
		dock._edge_toggle(left)
		dock._edge_toggle(right)
	var wsol: Dictionary = dock.edge_solve()
	ok = ok and _check(String(wsol.get("mode", "")) == "bridge",
		"two rims become a bridge, not a polygon")
	dock.fill_edges()
	var wpat: Dictionary = dock.decor["patches"][dock._patch_count() - 1]
	var wx0 := INF
	var wx1 := -INF
	var wz := 0.0
	var wy0 := INF
	var wy1 := -INF
	for v in (wpat["verts"] as Array):
		var q: Vector3 = dock._vec_of(v)
		wx0 = minf(wx0, q.x)
		wx1 = maxf(wx1, q.x)
		wz = maxf(wz, absf(q.z))
		wy0 = minf(wy0, q.y)
		wy1 = maxf(wy1, q.y)
	ok = ok and _check(wx0 > -1.05 and wx1 < 1.05,
		"the bridge fills only the gap (x %.2f .. %.2f)" % [wx0, wx1])
	ok = ok and _check(wz < 0.02, "and sits on the wall's own plane (z %.3f)" % wz)
	ok = ok and _check(wy1 - wy0 > 10.0, "across the wall's height (%.1f m)" % (wy1 - wy0))
	ok = ok and _check(String(wpat["class"]) == "wall", "the bridge keeps the wall class")

	# 17. Pointing into the gap itself: a hole in a ground plane with the terrain below it
	#     visible through the hole, and no erased faces to remember the level. The ray goes
	#     straight through the hole and lands on the terrain, so gathering around what the
	#     cursor hit finds nothing - clicking the empty middle must still take the rim.
	var hole_verts: Array = []
	var hole_uvs: Array = []
	var hole_idx: Array = []
	var hole_stride := 11
	for z in hole_stride:
		for x in hole_stride:
			hole_verts.append(Vector3(15000.0 + float(x) * 2.0 - 10.0, 700.0, 15000.0 + float(z) * 2.0 - 10.0))
			hole_uvs.append(Vector2(float(x) * 0.25, float(z) * 0.25))
	for z in hole_stride - 1:
		for x in hole_stride - 1:
			# An 8 x 8 m hole at the centre, its corners at real vertices.
			if x >= 3 and x <= 6 and z >= 3 and z <= 6:
				continue
			var ga := z * hole_stride + x
			var gd := ga + hole_stride
			var gc := gd + 1
			var gb := ga + 1
			hole_idx.append_array([ga, gd, gc, ga, gc, gb])
	dock.track.surface_geo[992] = {"pos": PackedVector3Array(hole_verts),
		"idx": PackedInt32Array(hole_idx), "uv": PackedVector2Array(hole_uvs),
		"class": "road", "texture": "gap_test.png", "alpha": false}
	# The terrain below, big enough that its own rim is out of reach of the click.
	var tv := PackedVector3Array([Vector3(14960, 690, 14960), Vector3(15040, 690, 14960),
		Vector3(15040, 690, 15040), Vector3(14960, 690, 15040)])
	var tuv2 := PackedVector2Array()
	tuv2.resize(4)
	dock.track.surface_geo[991] = {"pos": tv, "idx": PackedInt32Array([0, 2, 1, 0, 3, 2]),
		"uv": tuv2, "class": "off", "texture": "terrain_test.png", "alpha": false}
	dock._build_pick_grid()
	dock.focus = Vector3(15000, 700, 15000)
	dock.cam_dist = 30.0
	dock.cam_yaw = 0.0
	dock.cam_pitch = 1.45
	dock._update_camera()
	dock.clear_edges()
	var gap_vp: Vector2 = dock._project(Vector3(15000.0, 700.0, 15000.0))
	var through: Dictionary = dock._pick_triangle(gap_vp)
	ok = ok and _check(not through.is_empty() and int(through.get("surface", -1)) == 991,
		"the ray goes through the hole and lands on the terrain below")
	if not through.is_empty():
		ok = ok and _check(dock._rims_around(Vector3(through["pos"]), dock._edge_reach()).is_empty(),
			"gathering around what the cursor hit finds no rim there")
	var gap_pick: Dictionary = dock._edge_pick(gap_vp)
	ok = ok and _check(not gap_pick.is_empty(), "clicking the empty middle of the gap picks a rim edge")
	ok = ok and _check(bool(gap_pick.get("gap", false)), "and marks it as a gap click, not an edge click")
	ok = ok and _check(int(gap_pick.get("si", -1)) == 992,
		"from the surface the gap is cut into, not the one behind it")
	dock._set_tool("edge")
	dock._edge_hover_at(gap_vp)
	ok = ok and _check(not dock.edge_hover.is_empty() and bool(dock.edge_hover.get("gap", false)),
		"hovering the gap lights up the edge a click would take")
	ok = ok and _check(dock.edge_rim_mesh != null
		and dock.edge_rim_mesh.mesh.get_surface_count() == 1,
		"and draws the gap's rim around the cursor")
	var gap_grown: int = dock.edge_grow(gap_pick)
	ok = ok and _check(gap_grown == 16 and dock.edge_sel.size() == 16,
		"clicking the gap took the whole 16-edge rim (%d)" % gap_grown)
	var gsol: Dictionary = dock.edge_solve()
	ok = ok and _check(bool(gsol.get("ok", false)) and String(gsol.get("mode", "")) == "loop",
		"the rim from an empty-space click solves")
	ok = ok and _check(absf(float(gsol.get("area", 0.0)) - 64.0) < 0.6,
		"as the 8 x 8 m hole's area (%.2f m2)" % float(gsol.get("area", 0.0)))
	ok = ok and _check(String(gsol.get("tex", "")) == "gap_test.png",
		"textured by the gap's own surface (not the terrain below)")
	var gbefore: int = dock._patch_count()
	dock.fill_edges()
	ok = ok and _check(dock._patch_count() == gbefore + 1, "Fill edges closes the hole")
	var gpat: Dictionary = dock.decor["patches"][dock._patch_count() - 1]
	var ginside := true
	for v in (gpat["verts"] as Array):
		var q: Vector3 = dock._vec_of(v)
		if absf(q.x - 15000.0) > 4.05 or absf(q.z - 15000.0) > 4.05 or absf(q.y - 700.0) > 0.01:
			ginside = false
	ok = ok and _check(ginside, "and the sheet is the hole, on the hole's own plane")

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
