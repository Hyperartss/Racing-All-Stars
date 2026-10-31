extends SceneTree
## Kart + Map Importer checks (headless):
##   godot --headless -s tools/test_importers.gd
## 1. Kart Importer on the shipped kart OBJ: four wheels, each with its own radius,
##    a rig the game's VertexRig loads and a kart definition that names its textures.
## 2. Map Importer on a generated oval course: road/wall classes, a centreline that
##    closes, checkpoints, the starting grid, and the result loaded by the game's
##    Track (road + wall collision).
## 3. The importer's 2D view: clicking finds the surface drawn there, a clicked
##    start moves the lap, Alt road adds and removes a road surface.
## Everything it writes is removed again afterwards.

const TMP := "res://_tmp_import/"
const MAP_ID := "_importer_test"

var ok := true


func _init() -> void:
	# Deferred so the tree is running: the 2D view test adds a dock, whose _ready()
	# builds its controls, and that needs a started scene tree.
	_start.call_deferred()


func _start() -> void:
	_test_kart()
	_test_map()
	_test_canvas()
	_test_icons()
	print("IMPORTERS ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	ok = ok and cond


# ---------------------------------------------------------------- kart

func _test_kart() -> void:
	print("Kart Importer")
	var ki := KartImporter.new()
	ki.id = "_kart_test"
	ki.display_name = "Test Kart"
	ki.facing = "+Z"
	var err := ki.load_source("res://assets/karts/kart_MR_a.obj")
	check(err == "", "loads the shipped kart: %s" % err)
	if err != "":
		return
	ki.analyse()
	check(ki.wheels.size() == 4, "found 4 wheels (%s)" % ", ".join(ki.wheels.keys()))
	for w in ["wheel_fl", "wheel_fr", "wheel_bl", "wheel_br"]:
		check(ki.wheels.has(w), "has %s" % w)
	# The hand-made standard kart has front radii 0.0986 and back radii 0.174.
	if ki.wheels.has("wheel_fl") and ki.wheels.has("wheel_bl"):
		var rf := float(ki.wheels["wheel_fl"]["radius"])
		var rb := float(ki.wheels["wheel_bl"]["radius"])
		check(absf(rf - 0.0986) < 0.02, "front wheel radius %.4f ~ 0.0986" % rf)
		check(absf(rb - 0.174) < 0.02, "back wheel radius %.4f ~ 0.174" % rb)
		check(float(ki.wheels["wheel_fl"]["centre"].z) < 0.0, "front wheels are at -Z")
	check(absf(ki.size.z - ki.length) < 0.01, "length %.2f m" % ki.size.z)
	var rig := ki.build_rig()
	var names: Array = rig.parts.map(func(p): return p.name)
	check(names.has("body") and names.has("wheel_fr"), "rig parts: " + str(names))
	check(rig.surfaces.size() > 0, "%d rig surfaces" % rig.surfaces.size())
	var zones := ki.detect_paint()
	check(zones.has("body"), "body paint zone (src %s)" % zones.get("body", {}).get("src", "?"))
	var rig_path := "res://assets/rigs/kart__kart_test.json"
	var def_path := ki.export(zones)
	check(FileAccess.file_exists(def_path), "wrote %s" % def_path)
	var def: Variant = JSON.parse_string(FileAccess.get_file_as_string(def_path))
	check(def is Dictionary, "definition parses")
	if def is Dictionary:
		check(String(def.get("rig", "")) == rig_path, "definition points at its rig")
		var zone: Dictionary = def.get("paint", {}).get("body", {})
		check(String(zone.get("surface", "")) != "", "paint zone names the saved texture: %s" % zone.get("surface", ""))
		check(def.has("seat"), "has a driver seat")
	var vr := VertexRig.new()
	vr.load_rig(rig_path)
	check(vr.part_names.size() == names.size(), "VertexRig loads the kart: " + str(vr.part_names))
	check(vr.has_part(&"wheel_bl"), "VertexRig resolves wheel_bl")
	# clean up (the real standard kart is untouched)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rig_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(def_path))
	var tex := DirAccess.open("res://assets/rigs/tex/")
	if tex:
		for f in tex.get_files():
			if String(f).begins_with("kart__kart_test"):
				DirAccess.remove_absolute(ProjectSettings.globalize_path("res://assets/rigs/tex/" + String(f)))


# ---------------------------------------------------------------- map

func _test_map() -> void:
	print("Map Importer")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	var course := TMP + "loop.res"
	var built := _write_course(course)
	check(built, "built the test course")
	if not built:
		return
	var mi := MapImporter.new()
	mi.id = MAP_ID
	mi.display_name = "Importer Test"
	var err := mi.load_source(course)
	check(err == "", "loads the test course: %s" % err)
	if err != "":
		return
	check(mi.surfaces.size() >= 2, "%d surfaces" % mi.surfaces.size())
	var classes := {}
	for s in mi.surfaces:
		classes[String(s["class"])] = int(classes.get(String(s["class"]), 0)) + 1
	check(int(classes.get("road", 0)) == 1, "one road surface guessed: %s" % classes)
	check(int(classes.get("wall", 0)) >= 1, "walls guessed: %s" % classes)
	mi.checkpoints = 4
	var build_err := mi.build()
	check(build_err == "", "traces a centreline: %s" % build_err)
	if build_err != "":
		return
	var info := mi.report
	check(float(info.get("length", 0.0)) > 150.0, "lap length %.1f m" % float(info.get("length", 0.0)))
	check(int(info.get("samples", 0)) > 40, "%d centreline samples" % int(info.get("samples", 0)))
	check(bool(info.get("closed", false)), "the loop closes")
	# The traced line must stay on the road: check its width and that it is centred.
	check(float(info.get("width_min", 0.0)) >= 6.0, "width %.1f - %.1f m" % [float(info.get("width_min", 0.0)), float(info.get("width_max", 0.0))])
	var out := mi.export_map()
	check(FileAccess.file_exists(out), "wrote %s" % out)
	var def: Variant = JSON.parse_string(FileAccess.get_file_as_string(out))
	check(def is Dictionary, "map definition parses")
	if not (def is Dictionary):
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(String(def["data"])))
	check(int(data.get("checkpoints", []).size()) == 4, "4 checkpoints")
	check(data.get("grid", []).size() == 8, "8 starting grid slots")
	check(data.get("surfaces", []).size() >= 2, "%d baked surfaces" % data.get("surfaces", []).size())
	check(FileAccess.file_exists(String(def["preview"])), "preview image written")
	var track := Track.new()
	root.add_child(track)
	track.load_track(String(def["data"]))
	check(track.path.size() > 40, "Track path %d samples" % track.path.size())
	check(track.surface_bodies.has("road"), "road collision built")
	check(track.surface_bodies.has("wall"), "wall collision built")
	var g: Transform3D = track.grid_transform(0)
	check(g.origin != Vector3.ZERO, "start grid at %s" % g.origin)
	check(track.checkpoint_distance(0) == 0.0, "checkpoint 0 at the start line")
	var where := track.locate(g.origin)
	check(absf(float(where.get("lateral", 9.0))) < 4.0, "grid slot 0 is on the racing line (%.2f m off centre)" % float(where.get("lateral", 9.0)))
	track.free()
	_cleanup_map()


# ---------------------------------------------------------------- 2D view

func _test_canvas() -> void:
	print("Map Importer 2D view")
	var Canvas = load("res://addons/retro_tools/map_import_canvas.gd")
	var tri := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)])
	check(Canvas._in_tri(Vector2(1, 1), tri), "a point inside a triangle is inside")
	check(not Canvas._in_tri(Vector2(9, 9), tri), "a point outside is outside")
	check(not Canvas._in_tri(Vector2(-2, 5), tri), "a point past an edge is outside")
	# Walls seen from above are lines: they must not swallow every click.
	check(not Canvas._in_tri(Vector2(5, 0), PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(5, 0)])),
		"a flat (edge-on) triangle has no inside")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	var course := TMP + "view.res"
	if not _write_course(course):
		check(false, "built the view test course")
		return
	var dock: Node = load("res://addons/retro_tools/map_importer_dock.gd").new()
	root.add_child(dock)
	dock.path_edit.text = course
	dock.id_edit.text = "_canvas_test"
	dock.load_model()
	check(dock.imp.surfaces.size() >= 2, "the dock loaded %d surfaces" % dock.imp.surfaces.size())
	var canvas: Control = dock.canvas
	check(canvas != null, "the dock has a 2D view")
	if canvas == null:
		dock.free()
		return
	dock.analyse()
	check(bool(dock.imp.report.get("closed", false)), "the dock traced the course")
	canvas.fit()
	check(canvas.zoom > 0.0, "the view fits the course (%.2f px/m)" % canvas.zoom)
	var road_si := -1
	for i in dock.imp.surfaces.size():
		if String(dock.imp.surfaces[i]["class"]) == "road":
			road_si = i
	var p: Vector3 = dock.imp.start_point()
	check(canvas.surface_at(Vector2(p.x, p.z)) == road_si, "clicking the road finds the road surface")
	check(canvas.surface_at(Vector2(5000, 5000)) == -1, "clicking empty space finds nothing")
	# Zoom keeps the point under the cursor where it is.
	var under: Vector2 = canvas.s2w(Vector2(40, 50))
	canvas._zoom_at(Vector2(40, 50), 1.5)
	check(canvas.s2w(Vector2(40, 50)).distance_to(under) < 0.01, "zooming keeps the cursor over the same spot")
	# Start mode: clicking a quarter of the way round restarts the lap there.
	canvas.mode = "start"
	var pts: Array[Vector3] = dock.imp.path()
	var target: Vector3 = pts[pts.size() / 4]
	canvas.click_at(canvas.w2s(Vector2(target.x, target.z)))
	check(not dock.imp.start_auto, "a clicked start is not automatic")
	check(Vector2(dock.imp.start_point().x, dock.imp.start_point().z).distance_to(
		Vector2(target.x, target.z)) < 1.0, "the lap now begins where it was clicked")
	check(bool(dock.imp.report.get("closed", false)), "the lap still closes from the new start")
	check(not dock.auto_start.button_pressed, "the start fields switch to manual")
	# Alt road: another surface can be road too, and be taken back out.
	var other := -1
	for i in dock.imp.surfaces.size():
		if i != road_si:
			other = i
			break
	if other >= 0:
		dock.canvas_toggle_alt(other)
		check(String(dock.imp.surfaces[other]["class"]) == "road", "Alt road adds a surface to the road")
		dock.canvas_toggle_alt(other)
		check(String(dock.imp.surfaces[other]["class"]) != "road", "Alt road removes it again")
		dock.canvas_set_class(other, "deco")
		check(String(dock.imp.surfaces[other]["class"]) == "deco", "a surface's class can be set from the view")
	dock.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(course))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


## A stadium-shaped road (two straights, two bends) with a wall around the outside,
## as an ArrayMesh: "Road" and "Wall" surface names drive the class guessing.
func _write_course(path: String) -> bool:
	var rings := 96
	var half_l := 45.0
	var half_r := 30.0
	var half_w := 9.0
	var inner := [[], [], []]
	var outer := [[], [], []]
	var road_pos := PackedVector3Array()
	var road_uv := PackedVector2Array()
	var road_idx := PackedInt32Array()
	var wall_pos := PackedVector3Array()
	var wall_nrm := PackedVector3Array()
	var wall_uv := PackedVector2Array()
	var wall_idx := PackedInt32Array()
	for i in rings:
		var a := TAU * float(i) / float(rings)
		var centre := Vector2(cos(a) * half_l, sin(a) * half_r)
		var n := centre.normalized()          # outwards
		var offset := centre + n * half_w
		inner[0].append(centre)
		inner[1].append(offset)
		outer[0].append(offset)
		outer[1].append(n)
	var p_index := 0
	for i in rings:
		var a: Vector2 = inner[0][i]
		var b: Vector2 = inner[0][(i + 1) % rings]
		var c2: Vector2 = inner[1][i]
		var d: Vector2 = inner[1][(i + 1) % rings]
		road_pos.append_array(PackedVector3Array([Vector3(a.x, 0, a.y), Vector3(b.x, 0, b.y),
			Vector3(d.x, 0, d.y), Vector3(c2.x, 0, c2.y)]))
		road_uv.append_array(PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]))
		road_idx.append_array(PackedInt32Array([p_index, p_index + 1, p_index + 2, p_index, p_index + 2, p_index + 3]))
		p_index += 4
	# wall: outside the road, 1.2 m high
	var w_index := 0
	for i in rings:
		var a: Vector2 = outer[0][i]
		var b: Vector2 = outer[0][(i + 1) % rings]
		wall_pos.append_array(PackedVector3Array([Vector3(a.x, 0, a.y), Vector3(b.x, 0, b.y),
			Vector3(b.x, 1.2, b.y), Vector3(a.x, 1.2, a.y)]))
		var nrm: Vector2 = outer[1][i]
		wall_nrm.append_array(PackedVector3Array([Vector3(-nrm.x, 0, -nrm.y), Vector3(-nrm.x, 0, -nrm.y),
			Vector3(-nrm.x, 0, -nrm.y), Vector3(-nrm.x, 0, -nrm.y)]))
		wall_uv.append_array(PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]))
		wall_idx.append_array(PackedInt32Array([w_index, w_index + 1, w_index + 2, w_index, w_index + 2, w_index + 3]))
		w_index += 4
	var mesh := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = road_pos
	arr[Mesh.ARRAY_TEX_UV] = road_uv
	arr[Mesh.ARRAY_INDEX] = road_idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_name(0, "Road")
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://assets/karts/kart_body.png")
	mesh.surface_set_material(0, mat)
	arr = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = wall_pos
	arr[Mesh.ARRAY_NORMAL] = wall_nrm
	arr[Mesh.ARRAY_TEX_UV] = wall_uv
	arr[Mesh.ARRAY_INDEX] = wall_idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_name(1, "Wall")
	var wmat := StandardMaterial3D.new()
	wmat.albedo_texture = load("res://assets/karts/kart_tire.png")
	mesh.surface_set_material(1, wmat)
	return ResourceSaver.save(mesh, path) == OK


## Face icons: a rig without a head part (the kart) still gets a thumbnail from the
## top of the model, and the character definition records where it is.
func _test_icons() -> void:
	print("Character icons")
	var dir := TMP + "chars/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var rig_text := FileAccess.get_file_as_string("res://assets/rigs/kart_standard.json")
	var f := FileAccess.open(dir + "icon_rig.json", FileAccess.WRITE)
	f.store_string(rig_text)
	f.close()
	f = FileAccess.open(dir + "icon_test.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"id": "icon_test", "name": "Icon Test", "type": "kart",
		"rig": dir + "icon_rig.json"}))
	f.close()
	var n := CharacterImporter.make_icons(dir)
	check(n == 1, "rendered %d icon(s)" % n)
	check(FileAccess.file_exists(dir + "icon_test.png"), "wrote the icon png")
	var img := Image.load_from_file(ProjectSettings.globalize_path(dir + "icon_test.png"))
	check(img != null and img.get_width() == 32 and img.get_height() == 32, "icon is 32x32")
	var drawn := 0
	if img:
		for y in img.get_height():
			for x in img.get_width():
				if img.get_pixel(x, y).a > 0.5:
					drawn += 1
	check(drawn > 40, "icon has %d drawn pixels" % drawn)
	var patched: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir + "icon_test.json"))
	check(patched is Dictionary and String(patched.get("icon", "")) == dir + "icon_test.png",
		"definition points at its icon")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "icon_test.png"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "icon_test.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "icon_rig.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


func _cleanup_map() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://content/maps/%s.json" % MAP_ID))
	var dir := "res://assets/maps/%s" % MAP_ID
	for f in ["track.json", "track.bin", "preview.png", "decor.json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/" + f))
	var tex := DirAccess.open(dir + "/tex")
	if tex:
		for f in tex.get_files():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/tex/" + String(f)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/tex"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP + "loop.res"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
