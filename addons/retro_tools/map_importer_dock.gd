@tool
extends ScrollContainer
## Map Importer dock: a whole outside track model -> a playable map.
##
## Pick an imported model (inside the project), set its scale (model units per
## metre), check the guessed surface classes, then Analyse to trace the centreline
## and Export. The map lands in assets/maps/<id>/ and content/maps/<id>.json, so it
## shows up in the game's menu and can be opened in the Map Editor afterwards.

var imp := MapImporter.new()
var path_edit: LineEdit
var id_edit: LineEdit
var name_edit: LineEdit
var sub_edit: LineEdit
var scale_spin: SpinBox
var cp_spin: SpinBox
var laps_spin: SpinBox
var auto_start: CheckBox
var start_x: SpinBox
var start_z: SpinBox
var start_yaw: SpinBox
var surf_grid: GridContainer
var surf_scroll: ScrollContainer
var road_pick: OptionButton
var report_label: Label
var log_box: TextEdit
var canvas: Control
var _mode_group: ButtonGroup
var _areas := PackedFloat32Array()


func _ready() -> void:
	custom_minimum_size = Vector2(0, 340)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(v)
	var g := GridContainer.new()
	g.columns = 2
	v.add_child(g)
	path_edit = _row(g, "Model (res://...)", LineEdit.new())
	path_edit.placeholder_text = "res://import/my_course/course.obj"
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.tooltip_text = "A track model imported by Godot. Surfaces are sorted into road,\n" + \
		"off-road, wall and decoration; the road is traced into a centreline."
	id_edit = _row(g, "Id", LineEdit.new())
	name_edit = _row(g, "Name", LineEdit.new())
	sub_edit = _row(g, "Subtitle", LineEdit.new())
	sub_edit.placeholder_text = "shown in the menu"
	scale_spin = _row(g, "Scale (m per unit)", SpinBox.new())
	scale_spin.min_value = 0.0001
	scale_spin.max_value = 1000.0
	scale_spin.step = 0.001
	scale_spin.value = 1.0
	scale_spin.tooltip_text = "Model units to metres. A course built in centimetres needs 0.01,\n" + \
		"one built in 100-unit blocks needs 100."
	cp_spin = _row(g, "Checkpoints", SpinBox.new())
	cp_spin.min_value = 3
	cp_spin.max_value = 40
	cp_spin.value = 8
	laps_spin = _row(g, "Laps", SpinBox.new())
	laps_spin.min_value = 1
	laps_spin.max_value = 9
	laps_spin.value = 3
	var row := HBoxContainer.new()
	v.add_child(row)
	_btn(row, "Load", load_model)
	_btn(row, "Analyse", analyse)
	_btn(row, "Detect road", detect_road)
	_btn(row, "Export", export)

	# --- 2D check view ----------------------------------------------------------
	canvas = load("res://addons/retro_tools/map_import_canvas.gd").new()
	canvas.dock = self
	v.add_child(canvas)
	var view_row := HBoxContainer.new()
	v.add_child(view_row)
	_mode_group = ButtonGroup.new()
	for m in [["", "Check"], ["road", "Set road"], ["alt", "Alt road"],
			["wall", "Wall"], ["start", "Start"]]:
		var b := Button.new()
		b.text = String(m[1])
		b.toggle_mode = true
		b.button_group = _mode_group
		b.button_pressed = String(m[0]) == ""
		b.tooltip_text = _mode_tip(String(m[0]))
		var key := String(m[0])
		b.pressed.connect(func() -> void: _set_mode(key))
		view_row.add_child(b)
	_btn(view_row, "Fit", func() -> void: canvas.fit())

	# --- start -----------------------------------------------------------------
	_lbl(v, "Start line")
	auto_start = CheckBox.new()
	auto_start.text = "Auto (widest part of the road)"
	auto_start.button_pressed = true
	auto_start.toggled.connect(_on_auto_start)
	v.add_child(auto_start)
	var sg := GridContainer.new()
	sg.columns = 6
	v.add_child(sg)
	_lbl(sg, "X")
	start_x = SpinBox.new()
	start_x.min_value = -10000
	start_x.max_value = 10000
	start_x.step = 0.5
	start_x.editable = false
	sg.add_child(start_x)
	_lbl(sg, "Z")
	start_z = SpinBox.new()
	start_z.min_value = -10000
	start_z.max_value = 10000
	start_z.step = 0.5
	start_z.editable = false
	sg.add_child(start_z)
	_lbl(sg, "Yaw")
	start_yaw = SpinBox.new()
	start_yaw.min_value = -360
	start_yaw.max_value = 360
	start_yaw.step = 5
	start_yaw.editable = false
	start_yaw.tooltip_text = "Degrees in the map's own space: 0 = +X, 90 = +Z."
	sg.add_child(start_yaw)

	# --- surfaces ---------------------------------------------------------------
	var road_row := HBoxContainer.new()
	v.add_child(road_row)
	_lbl(road_row, "Road surface")
	road_pick = OptionButton.new()
	road_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	road_pick.tooltip_text = "The surface the centreline is traced along. Hashed texture names\n" + \
		"say nothing, so pick the asphalt here; the rows below can mark more\n" + \
		"surfaces as road (a road split over two materials), or set walls."
	road_pick.item_selected.connect(_on_road_picked)
	road_row.add_child(road_pick)
	_lbl(v, "Surfaces (what each one is)")
	surf_scroll = ScrollContainer.new()
	surf_scroll.custom_minimum_size = Vector2(0, 150)
	surf_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	v.add_child(surf_scroll)
	surf_grid = GridContainer.new()
	surf_grid.columns = 3
	surf_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	surf_scroll.add_child(surf_grid)
	var hint := _note("name, what it is, cut-out alpha. Hover a name for its texture.")
	hint.add_theme_font_size_override("font_size", 12)
	v.add_child(hint)
	report_label = _note("Load a model to see its surfaces.")
	report_label.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	v.add_child(report_label)
	log_box = TextEdit.new()
	log_box.editable = false
	log_box.custom_minimum_size = Vector2(0, 120)
	v.add_child(log_box)


func _row(g: Control, t: String, c: Control) -> Variant:
	g.add_child(_label(t))
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(c)
	return c


## Short field label. No autowrap: inside a 2-column grid a wrapping label shrinks
## to 1px wide and wraps to many lines, which makes its whole row (and the field
## next to it) enormously tall.
func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


## Full-width status line under the fields, where wrapping is wanted.
func _note(t: String) -> Label:
	var l := _label(t)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _lbl(p: Control, t: String) -> void:
	p.add_child(_label(t))


func _btn(p: Control, t: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	p.add_child(b)


func out(t: String) -> void:
	log_box.text += t + "\n"
	log_box.scroll_vertical = log_box.get_line_count()


static func _mode_tip(m: String) -> String:
	match m:
		"road":
			return "Click a surface in the view: it becomes the road the centreline is traced along."
		"alt":
			return "Click a surface to add it as road too (a road split over two materials), or remove it again."
		"wall":
			return "Click a surface to make it a wall: solid, and it collides in the game."
		"start":
			return "Click the road to put the start / finish line there, facing along the road."
		_:
			return "Click a surface in the view to see what it is."


func _set_mode(m: String) -> void:
	if canvas:
		canvas.mode = m
		canvas.queue_redraw()


# --- what the 2D view asks for -------------------------------------------------

## Check mode: a surface was clicked.
func canvas_picked(si: int) -> void:
	if si < 0:
		out("Nothing there.")
		report_label.text = "Nothing there - click on one of the drawn surfaces."
		return
	var s: Dictionary = imp.surfaces[si]
	out("Surface \"%s\": %s, %d triangles." % [String(s["name"]), String(s["class"]), int(s["tris"])])
	report_label.text = "%s · %s · %d tris" % [String(s["name"]), String(s["class"]), int(s["tris"])]


## Set road mode: trace along the clicked surface.
func canvas_set_road(si: int) -> void:
	_sync()
	imp.set_road(si)
	out("Road surface: \"%s\"." % String(imp.surfaces[si]["name"]))
	_show_road_picker()
	_show_surfaces()
	_retrace()


## Alt road mode: another surface is road as well, or no longer.
func canvas_toggle_alt(si: int) -> void:
	_sync()
	var was := String(imp.surfaces[si]["class"])
	out(imp.toggle_alt_road(si))
	_show_road_picker()
	_show_surfaces()
	if String(imp.surfaces[si]["class"]) != was:
		_retrace()
	else:
		canvas.queue_redraw()


## Wall mode (and anything else the view wants to set).
func canvas_set_class(si: int, cls: String) -> void:
	_sync()
	var s: Dictionary = imp.surfaces[si]
	out("\"%s\": %s -> %s" % [String(s["name"]), String(s["class"]), cls])
	s["class"] = cls
	_show_road_picker()
	_show_surfaces()
	canvas.queue_redraw()


## Start mode: the start / finish line goes where the view was clicked.
func canvas_set_start(at: Vector2) -> void:
	_sync()
	var err := imp.set_start(at)
	if err != "":
		out(err)
		report_label.text = err
		return
	auto_start.button_pressed = false
	_on_auto_start(false)
	start_x.value = snappedf(imp.start.x, 0.5)
	start_z.value = snappedf(imp.start.y, 0.5)
	start_yaw.value = imp.start_yaw
	out("Start at (%.1f, %.1f), facing %.0f degrees." % [imp.start.x, imp.start.y, imp.start_yaw])
	_retrace()


## A message from the view for the log.
func canvas_note(t: String) -> void:
	out(t)


## Builds again from what the view just set, and redraws it.
func _retrace() -> void:
	var t0 := Time.get_ticks_msec()
	var err := imp.build()
	var ms := Time.get_ticks_msec() - t0
	if err != "":
		out("Error: " + err)
		report_label.text = err
		for n in imp.notes:
			out("Note: " + n)
		canvas.queue_redraw()
		return
	_show_report(ms)


func _on_auto_start(on: bool) -> void:
	start_x.editable = not on
	start_z.editable = not on
	start_yaw.editable = not on


func _sync() -> void:
	imp.id = id_edit.text.strip_edges().to_snake_case()
	imp.display_name = name_edit.text.strip_edges()
	imp.subtitle = sub_edit.text.strip_edges()
	imp.scale = scale_spin.value
	imp.checkpoints = int(cp_spin.value)
	imp.laps = int(laps_spin.value)
	imp.start_auto = auto_start.button_pressed
	imp.start = Vector2(start_x.value, start_z.value)
	imp.start_yaw = start_yaw.value


func load_model() -> void:
	imp = MapImporter.new()
	_sync()
	var err := imp.load_source(path_edit.text.strip_edges())
	if err != "":
		out("Error: " + err)
		return
	id_edit.text = imp.id
	name_edit.text = imp.display_name
	out("Loaded %d mesh pieces in %d surfaces." % [imp.chunks.size(), imp.surfaces.size()])
	canvas.invalidate()
	canvas.fit()
	_show_road_picker()
	_show_surfaces()
	report_label.text = "Press Analyse to trace the road."


## The road picker: every surface with flat area, biggest first.
func _show_road_picker() -> void:
	_areas = imp.surface_areas()
	var order: Array = []
	for si in imp.surfaces.size():
		if _areas[si] > 0.5:
			order.append(si)
	order.sort_custom(func(a: int, b: int) -> bool: return _areas[a] > _areas[b])
	road_pick.clear()
	var current := -1
	for si in order:
		var s: Dictionary = imp.surfaces[si]
		road_pick.add_item("%s  (%.0f m2)" % [String(s["name"]), _areas[si]])
		road_pick.set_item_metadata(road_pick.item_count - 1, si)
		if String(s["class"]) == "road":
			current = road_pick.item_count - 1
	if current < 0 and road_pick.item_count > 0:
		current = 0
	if current >= 0:
		road_pick.select(current)


func _on_road_picked(i: int) -> void:
	var si := int(road_pick.get_item_metadata(i))
	_sync()
	imp.set_road(si)
	out("Road surface: \"%s\"." % String(imp.surfaces[si]["name"]))
	_show_surfaces()
	_retrace()


## One row per surface: name, what it is, and whether it uses cut-out alpha.
func _show_surfaces() -> void:
	for c in surf_grid.get_children():
		c.queue_free()
	for si in imp.surfaces.size():
		var s: Dictionary = imp.surfaces[si]
		var l := _label("%s  (%d tris)" % [String(s["name"]), int(s["tris"])])
		l.tooltip_text = "%s\n%s" % [String(s["key"]), _tex_note(s)]
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.custom_minimum_size = Vector2(120, 0)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		surf_grid.add_child(l)
		var pick := OptionButton.new()
		for c in MapImporter.CLASSES:
			pick.add_item(String(c))
		pick.select(maxi(0, MapImporter.CLASSES.find(String(s["class"]))))
		pick.tooltip_text = "road: drivable and the centreline is traced along it\n" + \
			"off: drivable, slower (grass, dirt)\n" + \
			"wall: solid, collides\n" + \
			"deco: drawn only, no collision\n" + \
			"skip: left out of the map"
		var row: Dictionary = imp.surfaces[si]
		pick.item_selected.connect(func(i: int) -> void:
			row["class"] = MapImporter.CLASSES[i]
			if canvas:
				canvas.queue_redraw())
		surf_grid.add_child(pick)
		var alpha := CheckBox.new()
		alpha.text = "cut-out"
		alpha.tooltip_text = "Draw with alpha scissor (fences, leaves, signs)."
		alpha.button_pressed = bool(s["alpha"])
		var row2: Dictionary = imp.surfaces[si]
		alpha.toggled.connect(func(on: bool) -> void: row2["alpha"] = on)
		surf_grid.add_child(alpha)


static func _tex_note(s: Dictionary) -> String:
	var tex := String(s["tex"])
	if tex == "":
		return "flat colour"
	return tex


## Finds the road surface by trying the flat surfaces until one laps cleanly.
func detect_road() -> void:
	if imp.chunks.is_empty():
		load_model()
		if imp.chunks.is_empty():
			return
	_sync()
	var t0 := Time.get_ticks_msec()
	var err := imp.detect_road()
	var ms := Time.get_ticks_msec() - t0
	out("Detect road (%.1f s): %s" % [ms / 1000.0, "ok" if err == "" else err])
	for n in imp.notes:
		out("Note: " + n)
	_show_road_picker()
	_show_surfaces()
	if err == "":
		_show_report(ms)


func analyse() -> void:
	if imp.chunks.is_empty():
		load_model()
		if imp.chunks.is_empty():
			return
	_sync()
	var t0 := Time.get_ticks_msec()
	var err := imp.build()
	var ms := Time.get_ticks_msec() - t0
	if err != "":
		out("Error: " + err)
		out("If that is the wrong road surface, pick one above or press \"Detect road\".")
		report_label.text = err
		for n in imp.notes:
			out("Note: " + n)
		return
	_show_report(ms)


## Logs the traced lap and fills the start fields with where it starts.
func _show_report(ms: int) -> void:
	var r := imp.report
	out("Traced %.0f m in %d samples (%.1f s)." % [float(r.get("length", 0.0)), int(r.get("samples", 0)), ms / 1000.0])
	out("Width %.1f - %.1f m, closed: %s" % [float(r.get("width_min", 0.0)), float(r.get("width_max", 0.0)), r.get("closed", false)])
	report_label.text = "Lap %.0f m, %d samples, width %.1f - %.1f m" % [
		float(r.get("length", 0.0)), int(r.get("samples", 0)),
		float(r.get("width_min", 0.0)), float(r.get("width_max", 0.0))]
	for n in imp.notes:
		out("Note: " + n)
	canvas.on_trace()
	# Show where the auto start landed so it can be adjusted.
	if imp.start_auto:
		var p := imp.start_point()
		start_x.value = snappedf(p.x, 0.5)
		start_z.value = snappedf(p.z, 0.5)


func export() -> void:
	analyse()
	if imp.chunks.is_empty() or imp.id == "":
		out("Nothing to export (load a model and give it an id).")
		return
	if not imp.report.has("length"):
		out("Nothing to export - the road could not be traced.")
		return
	var p := imp.export_map()
	out("Wrote %s and res://assets/maps/%s/ (track.json, track.bin, preview.png)." % [p, imp.id])
	out("It is in the menu now; open it in the Map Editor to clean it up or decorate it.")
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
