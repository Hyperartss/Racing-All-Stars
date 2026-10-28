@tool
extends HSplitContainer
## Map Editor: clean up and decorate a merged (baked) map in 3D.
##
## Left: pick a baked map, choose a tool and place props. Right: the course itself
## in a 3D preview - middle-drag orbits, Shift+middle pans, wheel zooms, F frames.
##
## Tools
##   Select (1)  click a prop to select it, then drag the gizmo: move (G) arrows,
##               rotate (R) ring, scale (S) handle. Delete removes, Ctrl+D duplicates.
##   Place (2)   click the course to stamp the palette prop; keeps stamping until you
##               pick another tool. Random yaw and size jitter are in the panel.
##   Erase (3)   drag over baked geometry to erase triangles (floating scenery,
##               z-fighting pieces, a stray wall). "Restore all" puts everything back.
##
## Everything is written to assets/maps/<id>/decor.json, which Track reads when the
## map loads (props spawn, erased triangles are skipped). Re-baking the map leaves
## decor.json alone, but surface indices change, so check the map after a re-bake.
## Undo: Ctrl+Z / Ctrl+Shift+Z. Save: Ctrl+S.

const MAPS := "res://content/maps/"
const DECOR := "decor.json"
const UNDO_LIMIT := 60
const CELL := 16.0                 ## pick grid cell size in metres

# --- data ---------------------------------------------------------------------------
var map_id := ""
var map_def := {}
var data_path := ""
var decor := {}
var sel := -1                      ## selected prop index in decor.props
var tool := "select"               ## select | place | erase
var palette := "tree"

# --- 3D preview ---------------------------------------------------------------------
var track: Track
var preview_root: Node3D
var cam: Camera3D
var cam_yaw := 0.9
var cam_pitch := 0.55
var cam_dist := 140.0
var focus := Vector3.ZERO
var _drag := 0                     ## 0 none, 1 orbit, 2 pan, 3 gizmo, 4 erase stroke
var _erased := false

# Gizmo: arrows for move, a Y ring for rotate, a Y handle for scale.
var gizmo_root: Node3D
var gizmo_axes: Array[Node3D] = []
var gizmo_rings: Array[MeshInstance3D] = []
var gizmo_arrows: Array[Node3D] = []
var gizmo_mats: Array[StandardMaterial3D] = []
var gizmo_mode := "move"           ## move | rotate | scale
var gizmo_hover := -1
var gizmo_drag := -1
var _g_acc := 0.0
var _g_dir2 := Vector2.UP
var _g_px_per_unit := 100.0
var _g_start := Vector3.ZERO
var _g_prev_angle := 0.0
var _g_pivot := Vector3.ZERO
var sel_box: MeshInstance3D
var erase_marker: MeshInstance3D

# --- picking ------------------------------------------------------------------------
var _cells := {}                   ## Vector2i cell -> PackedInt32Array of (surface, face)
var _big := PackedInt32Array()     ## faces too large for one cell
var _grid_built := false

# --- undo ---------------------------------------------------------------------------
var undo_stack: Array[String] = []
var redo_stack: Array[String] = []
var _committed := "{}"
var _last_tag := ""
var _last_ms := 0
var _dirty := false
var _syncing := false

# --- widgets ------------------------------------------------------------------------
var map_pick: OptionButton
var save_btn: Button
var undo_btn: Button
var redo_btn: Button
var tool_btns: Array[Button] = []
var palette_pick: OptionButton
var tint_pick: ColorPickerButton
var jitter_spin: SpinBox
var random_yaw: CheckBox
var props_label: Label
var pos_spins: Array[SpinBox] = []
var yaw_spin: SpinBox
var scale_spin: SpinBox
var sel_label: Label
var surf_list: ItemList
var surf_label: Label
var status_label: Label
var preview_holder: SubViewportContainer
var viewport: SubViewport
var _autoloaded := false


func _ready() -> void:
	custom_minimum_size = Vector2(0, 340)
	_build_left()
	_build_right()
	_refresh_maps()
	# A map is several MB; load the first one when the tab is first opened, not
	# while the editor is still starting up.
	visibility_changed.connect(_autoload_map)
	_autoload_map()


func _autoload_map() -> void:
	if _autoloaded or not is_visible_in_tree():
		return
	_autoloaded = true
	if map_pick.item_count > 0:
		load_map(String(map_pick.get_item_metadata(0)))


func _build_left() -> void:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)

	var row := HBoxContainer.new()
	v.add_child(row)
	_label(row, "Map")
	map_pick = OptionButton.new()
	map_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_pick.tooltip_text = "Every map in content/maps that has a baked track"
	map_pick.item_selected.connect(_on_map_picked)
	row.add_child(map_pick)
	_btn(row, "Reload", func() -> void: load_map(map_id)).tooltip_text = \
		"Re-read the baked track and decor.json from disk"

	row = HBoxContainer.new()
	v.add_child(row)
	save_btn = _btn(row, "Save", save)
	save_btn.tooltip_text = "Write the decoration into assets/maps/<id>/decor.json (Ctrl+S)"
	undo_btn = _btn(row, "Undo", _undo)
	undo_btn.tooltip_text = "Ctrl+Z"
	redo_btn = _btn(row, "Redo", _redo)
	redo_btn.tooltip_text = "Ctrl+Shift+Z"

	_muted(v, "Click the course to place a prop. Drag the gizmo to move (G), rotate (R) or scale (S). Middle-drag orbits, Shift+middle pans, wheel zooms, F frames, double-click a spot to fly to it.")

	# --- tools ---------------------------------------------------------------------
	row = HBoxContainer.new()
	v.add_child(row)
	var group := ButtonGroup.new()
	for t in [["select", "Select (1)"], ["place", "Place (2)"], ["erase", "Erase (3)"]]:
		var b := Button.new()
		b.text = String(t[1])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = String(t[0]) == tool
		b.tooltip_text = {
			"select": "Pick a prop and edit it with the gizmo",
			"place": "Click the course to add the palette prop",
			"erase": "Drag over baked geometry to erase triangles",
		}.get(String(t[0]), "")
		b.toggled.connect(_on_tool_toggled.bind(String(t[0])))
		row.add_child(b)
		tool_btns.append(b)

	row = HBoxContainer.new()
	v.add_child(row)
	palette_pick = OptionButton.new()
	palette_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	palette_pick.tooltip_text = "What the Place tool stamps"
	for t in TrackProps.TYPES:
		palette_pick.add_item(String(TrackProps.LABEL.get(t, t)))
		palette_pick.set_item_metadata(palette_pick.item_count - 1, t)
	palette_pick.item_selected.connect(_on_palette_picked)
	row.add_child(palette_pick)
	tint_pick = ColorPickerButton.new()
	tint_pick.custom_minimum_size = Vector2(46, 0)
	tint_pick.color = TrackProps.default_tint(palette)
	tint_pick.tooltip_text = "Main colour of the prop (leaves, rock, sign board...)"
	tint_pick.color_changed.connect(func(_c: Color) -> void: _tint_changed())
	row.add_child(tint_pick)

	row = HBoxContainer.new()
	v.add_child(row)
	_btn(row, "Add at view", add_at_view).tooltip_text = "Stamp the palette prop where the camera looks"
	random_yaw = CheckBox.new()
	random_yaw.text = "Random yaw"
	random_yaw.button_pressed = true
	row.add_child(random_yaw)
	row = HBoxContainer.new()
	v.add_child(row)
	_label(row, "Size jitter")
	jitter_spin = SpinBox.new()
	jitter_spin.min_value = 0.0
	jitter_spin.max_value = 0.9
	jitter_spin.step = 0.05
	jitter_spin.value = 0.15
	jitter_spin.tooltip_text = "Random scale variation when stamping"
	row.add_child(jitter_spin)

	# --- selection ----------------------------------------------------------------
	_lbl(v, "Selected prop")
	sel_label = _muted(v, "Nothing selected.")
	row = HBoxContainer.new()
	v.add_child(row)
	_btn(row, "Duplicate", duplicate_selected).tooltip_text = "Ctrl+D"
	_btn(row, "Delete", delete_selected).tooltip_text = "Delete key"
	_btn(row, "Snap to ground", snap_selected).tooltip_text = "Drop the prop onto the geometry below it"
	var g := GridContainer.new()
	g.columns = 2
	v.add_child(g)
	for i in 3:
		_lbl(g, ["Position X", "Position Y", "Position Z"][i])
		var s := SpinBox.new()
		s.min_value = -4000.0
		s.max_value = 4000.0
		s.step = 0.05
		s.allow_greater = true
		s.allow_lesser = true
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.value_changed.connect(_on_pos_spin.bind(i))
		g.add_child(s)
		pos_spins.append(s)
	_lbl(g, "Rotation (deg)")
	yaw_spin = SpinBox.new()
	yaw_spin.min_value = -360.0
	yaw_spin.max_value = 360.0
	yaw_spin.step = 1.0
	yaw_spin.allow_greater = true
	yaw_spin.allow_lesser = true
	yaw_spin.value_changed.connect(func(_x: float) -> void: _yaw_changed())
	g.add_child(yaw_spin)
	_lbl(g, "Scale")
	scale_spin = SpinBox.new()
	scale_spin.min_value = 0.05
	scale_spin.max_value = 20.0
	scale_spin.step = 0.05
	scale_spin.allow_greater = true
	scale_spin.value_changed.connect(func(_x: float) -> void: _scale_changed())
	g.add_child(scale_spin)

	# --- surface cleanup -----------------------------------------------------------
	_lbl(v, "Baked surfaces")
	surf_label = _muted(v, "")
	surf_list = ItemList.new()
	surf_list.custom_minimum_size = Vector2(0, 110)
	v.add_child(surf_list)
	row = HBoxContainer.new()
	v.add_child(row)
	_btn(row, "Hide / show", toggle_surface).tooltip_text = \
		"Skip the whole surface: it disappears from the course and its collision"
	_btn(row, "Restore faces", restore_faces).tooltip_text = "Undo every erased triangle"
	_btn(row, "Restore all", restore_all).tooltip_text = "Unhide everything (faces and surfaces)"

	status_label = _muted(v, "Pick a map.")


func _build_right() -> void:
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(right)

	var tools := HBoxContainer.new()
	right.add_child(tools)
	var group := ButtonGroup.new()
	for t in [["move", "Move (G)"], ["rotate", "Rotate (R)"], ["scale", "Scale (S)"]]:
		var b := Button.new()
		b.text = String(t[1])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = String(t[0]) == gizmo_mode
		b.tooltip_text = {
			"move": "Drag an arrow to slide the prop along that axis (Ctrl snaps)",
			"rotate": "Drag the ring to turn the prop (Ctrl snaps to 15 degrees)",
			"scale": "Drag the handle up/down to resize the prop (Ctrl snaps)",
		}.get(String(t[0]), "")
		b.toggled.connect(_on_mode_toggled.bind(String(t[0])))
		tools.add_child(b)
	tools.add_child(VSeparator.new())
	_btn(tools, "Frame (F)", _frame).tooltip_text = "Frame the map, or the selected prop"
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tools.add_child(spacer)
	props_label = Label.new()
	props_label.add_theme_color_override("font_color", Color(0.62, 0.65, 0.72))
	tools.add_child(props_label)

	preview_holder = SubViewportContainer.new()
	preview_holder.stretch = true
	preview_holder.custom_minimum_size = Vector2(420, 210)
	preview_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_holder.mouse_filter = Control.MOUSE_FILTER_STOP
	preview_holder.focus_mode = Control.FOCUS_CLICK
	preview_holder.gui_input.connect(_on_preview_input)
	right.add_child(preview_holder)

	viewport = SubViewport.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	preview_holder.add_child(viewport)

	preview_root = Node3D.new()
	viewport.add_child(preview_root)

	# Same look as the game (RetroEnv), so edits are judged in context.
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.46, 0.68, 0.95)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.64, 0.7)
	env.ambient_light_energy = 1.0
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.62, 0.78, 0.97)
	env.fog_depth_begin = 200.0
	env.fog_depth_end = 560.0
	we.environment = env
	preview_root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 0.85
	sun.shadow_enabled = false
	preview_root.add_child(sun)

	cam = Camera3D.new()
	cam.fov = 62.0
	cam.far = 1400.0
	cam.current = true
	preview_root.add_child(cam)

	_build_gizmo()

	sel_box = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	sel_box.mesh = box
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.albedo_color = Color(1.0, 0.85, 0.25, 0.20)
	bm.cull_mode = BaseMaterial3D.CULL_DISABLED
	bm.no_depth_test = true
	sel_box.material_override = bm
	sel_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sel_box.visible = false
	preview_root.add_child(sel_box)

	erase_marker = MeshInstance3D.new()
	var em := StandardMaterial3D.new()
	em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	em.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	em.albedo_color = Color(1.0, 0.25, 0.2, 0.7)
	em.cull_mode = BaseMaterial3D.CULL_DISABLED
	em.no_depth_test = true
	erase_marker.material_override = em
	erase_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	erase_marker.visible = false
	preview_root.add_child(erase_marker)

	_update_camera()


# --- helpers -------------------------------------------------------------------------

func _btn(p: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	p.add_child(b)
	return b


func _label(p: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	p.add_child(l)
	return l


func _lbl(p: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.78, 0.81, 0.86))
	p.add_child(l)
	return l


func _muted(p: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", Color(0.62, 0.65, 0.72))
	p.add_child(l)
	return l


func status(text: String) -> void:
	if status_label != null:
		status_label.text = text


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


static func _r(v: float, step := 0.001) -> float:
	return snappedf(v, step)


static func _with_axis(v: Vector3, i: int, x: float) -> Vector3:
	match i:
		0:
			return Vector3(x, v.y, v.z)
		1:
			return Vector3(v.x, x, v.z)
	return Vector3(v.x, v.y, x)


static func _axis_value(v: Vector3, i: int) -> float:
	match i:
		0:
			return v.x
		1:
			return v.y
	return v.z


func _empty_decor() -> Dictionary:
	return {"version": 1, "props": [], "hidden": {}, "hidden_surfaces": []}


# --- maps -----------------------------------------------------------------------------

func _on_map_picked(i: int) -> void:
	if _syncing:
		return
	load_map(String(map_pick.get_item_metadata(i)))


func _refresh_maps() -> void:
	_syncing = true
	map_pick.clear()
	var d := DirAccess.open(MAPS)
	if d == null:
		_syncing = false
		status("Cannot open " + MAPS)
		return
	var files := Array(d.get_files())
	files.sort()
	for f in files:
		if not String(f).ends_with(".json"):
			continue
		var def := _read_json(MAPS + String(f))
		var id := String(def.get("id", String(f).get_basename()))
		var data := String(def.get("data", ""))
		if data == "" or not FileAccess.file_exists(data):
			# A saved-but-unbaked map: nothing to edit yet.
			continue
		map_pick.add_item(String(def.get("name", id)))
		map_pick.set_item_metadata(map_pick.item_count - 1, id)
	_syncing = false


func load_map(id: String) -> void:
	if id == "":
		return
	map_id = id
	map_def = _read_json(MAPS + id + ".json")
	data_path = String(map_def.get("data", ""))
	if data_path == "":
		data_path = "res://assets/maps/%s/track.json" % id
	if not FileAccess.file_exists(data_path):
		status("No baked track for %s - press Bake in the Map Combiner first." % id)
		return
	_syncing = true
	for i in map_pick.item_count:
		if String(map_pick.get_item_metadata(i)) == id:
			map_pick.select(i)
			break
	_syncing = false

	decor = _read_json(data_path.get_base_dir() + "/" + DECOR)
	if decor.is_empty():
		decor = _empty_decor()
	if not (decor.get("props") is Array):
		decor["props"] = []
	if not (decor.get("hidden") is Dictionary):
		decor["hidden"] = {}
	if not (decor.get("hidden_surfaces") is Array):
		decor["hidden_surfaces"] = []

	# Fresh preview of the course.
	if track != null and is_instance_valid(track):
		preview_root.remove_child(track)
		track.queue_free()
	track = Track.new()
	track.name = "MapTrack"
	track.keep_geometry = true
	track.decor = decor          # the editor's dictionary, so edits stay in sync
	preview_root.add_child(track)
	track.load_track(data_path)
	sel = -1
	_grid_built = false
	_build_pick_grid()
	_frame()
	_refresh_surface_list()
	_refresh_selection_ui()
	_update_gizmo()
	_set_dirty(false)
	_reset_undo()
	status("Editing %s - %d surfaces, %d props, %d erased triangles." % [id,
		track.data.surfaces.size(), _props().size(), _hidden_face_count()])


func save() -> void:
	if data_path == "":
		return
	var path := data_path.get_base_dir() + "/" + DECOR
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		status("Could not write " + path)
		return
	f.store_string(JSON.stringify(_clean_decor(), "\t") + "\n")
	f.close()
	_set_dirty(false)
	status("Saved %s - it is used whenever %s loads." % [path, map_id])


## Drops empty bookkeeping so decor.json only lists real edits.
func _clean_decor() -> Dictionary:
	var out := {"version": 1}
	var props := _props()
	if not props.is_empty():
		out["props"] = props
	var hid := {}
	for k in decor.get("hidden", {}):
		var list: Array = decor.hidden[k]
		if not list.is_empty():
			hid[k] = list
	if not hid.is_empty():
		out["hidden"] = hid
	var hs: Array = decor.get("hidden_surfaces", [])
	if not hs.is_empty():
		out["hidden_surfaces"] = hs
	return out


func _props() -> Array:
	var p: Variant = decor.get("props", [])
	if p is Array:
		return p
	var a: Array = []
	decor["props"] = a
	return a


func _prop_nodes() -> Array:
	if track == null or track.props_root == null:
		return []
	return track.props_root.get_children()


func _hidden_face_count() -> int:
	var n := 0
	var hid: Dictionary = decor.get("hidden", {})
	for k in hid:
		var list: Variant = hid[k]
		if list is Array:
			n += (list as Array).size()
	return n


# --- tools ----------------------------------------------------------------------------

func _on_tool_toggled(on: bool, t: String) -> void:
	if on:
		_set_tool(t)


func _on_mode_toggled(on: bool, m: String) -> void:
	if on:
		_set_gizmo_mode(m)


func _set_tool(t: String) -> void:
	tool = t
	for i in tool_btns.size():
		tool_btns[i].set_pressed_no_signal(["select", "place", "erase"][i] == t)
	if erase_marker != null:
		erase_marker.visible = false
	match t:
		"select":
			status("Select: click a prop, then drag the gizmo. Delete removes it.")
		"place":
			status("Place: click the course to stamp %s." % TrackProps.LABEL.get(palette, palette))
		"erase":
			status("Erase: drag over geometry to hide triangles. Release to apply.")


func _set_gizmo_mode(m: String) -> void:
	gizmo_mode = m
	gizmo_hover = -1
	if m == "rotate":
		status("Rotate: drag the ring (Ctrl snaps to 15 degrees).")
	elif m == "scale":
		status("Scale: drag the handle up/down (Ctrl snaps).")
	else:
		status("Move: drag an arrow to slide the prop along that axis (Ctrl snaps).")
	_update_gizmo()


# --- props ---------------------------------------------------------------------------

func _stamp_entry(at: Vector3) -> Dictionary:
	var yaw := randf_range(-180.0, 180.0) if random_yaw.button_pressed else 0.0
	var jitter := jitter_spin.value
	var scl := 1.0
	if jitter > 0.001:
		scl = 1.0 + randf_range(-jitter, jitter)
	return {
		"type": palette,
		"pos": [_r(at.x), _r(at.y), _r(at.z)],
		"yaw": _r(yaw, 0.1),
		"scale": _r(maxf(scl, 0.1), 0.01),
		"tint": tint_pick.color.to_html(false),
	}


func add_prop_at(at: Vector3) -> void:
	var e := _stamp_entry(at)
	_props().append(e)
	if track != null and track.props_root != null:
		track.props_root.add_child(TrackProps.make(e))
	_select(_props().size() - 1)
	_commit("add")


func add_at_view() -> void:
	if track == null:
		return
	var hit := _pick_triangle(Vector2(viewport.size) * 0.5)
	add_prop_at(hit.pos if not hit.is_empty() else focus)
	status("Added a %s at the view centre." % TrackProps.LABEL.get(palette, palette))


func duplicate_selected() -> void:
	if sel < 0 or sel >= _props().size():
		return
	var e: Dictionary = (_props()[sel] as Dictionary).duplicate(true)
	var p: Array = e.get("pos", [0, 0, 0])
	e["pos"] = [_r(float(p[0]) + 2.5), float(p[1]), _r(float(p[2]) + 2.5)]
	_props().append(e)
	if track != null and track.props_root != null:
		track.props_root.add_child(TrackProps.make(e))
	_select(_props().size() - 1)
	_commit("add")
	status("Duplicated the prop.")


func delete_selected() -> void:
	if sel < 0 or sel >= _props().size():
		return
	var nodes := _prop_nodes()
	_props().remove_at(sel)
	if sel < nodes.size():
		var n: Node = nodes[sel]
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.queue_free()
	sel = mini(sel, _props().size() - 1)
	if sel < 0:
		sel = -1
	_commit("delete")
	_refresh_selection_ui()
	_update_gizmo()
	status("Deleted the prop.")


func snap_selected() -> void:
	var n := _selected_node()
	if n == null:
		return
	var hit := _raycast(n.global_position + Vector3.UP * 60.0, Vector3.DOWN, 400.0)
	if hit.is_empty():
		status("No geometry under the prop - nothing to snap to.")
		return
	n.global_position = hit.pos
	_sync_selected_to_data()
	_update_gizmo()
	_commit("snap")
	status("Snapped to the ground.")


func _select(i: int) -> void:
	sel = i if i >= 0 and i < _props().size() else -1
	_refresh_selection_ui()
	_update_gizmo()


func _selected_node() -> Node3D:
	var nodes := _prop_nodes()
	if sel < 0 or sel >= nodes.size():
		return null
	return nodes[sel] as Node3D


func _refresh_selection_ui() -> void:
	_syncing = true
	var n := _selected_node()
	if n == null:
		sel_label.text = "Nothing selected - pick a prop with the Select tool."
		for s in pos_spins:
			s.editable = false
		yaw_spin.editable = false
		scale_spin.editable = false
	else:
		var e: Dictionary = _props()[sel]
		sel_label.text = "%s  (prop %d of %d)" % [
			TrackProps.LABEL.get(String(e.get("type", "")), "Prop"), sel + 1, _props().size()]
		for s in pos_spins:
			s.editable = true
		yaw_spin.editable = true
		scale_spin.editable = true
		pos_spins[0].value = n.global_position.x
		pos_spins[1].value = n.global_position.y
		pos_spins[2].value = n.global_position.z
		yaw_spin.value = rad_to_deg(n.rotation.y)
		scale_spin.value = n.scale.x
		tint_pick.color = Color(String(e.get("tint", "#ffffff")))
	_syncing = false
	_update_prop_label()


func _update_prop_label() -> void:
	if props_label != null:
		props_label.text = "%d props  -  %d erased tris" % [_props().size(), _hidden_face_count()]


func _on_pos_spin(_v: float, axis: int) -> void:
	if _syncing or sel < 0:
		return
	var n := _selected_node()
	if n == null:
		return
	n.global_position = _with_axis(n.global_position, axis, pos_spins[axis].value)
	_sync_selected_to_data()
	_update_gizmo()
	_commit("field")


func _yaw_changed() -> void:
	if _syncing or sel < 0:
		return
	var n := _selected_node()
	if n == null:
		return
	n.rotation.y = deg_to_rad(yaw_spin.value)
	_sync_selected_to_data()
	_update_gizmo()
	_commit("field")


func _scale_changed() -> void:
	if _syncing:
		return
	var n := _selected_node()
	if n == null:
		return
	n.scale = Vector3.ONE * maxf(scale_spin.value, 0.05)
	_sync_selected_to_data()
	_update_gizmo()
	_commit("field")


func _tint_changed() -> void:
	if _syncing or sel < 0:
		return
	var e: Dictionary = _props()[sel]
	e["tint"] = tint_pick.color.to_html(false)
	var n := _selected_node()
	if n != null:
		var pos := n.global_position
		var yaw := n.rotation.y
		var scl := n.scale.x
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.queue_free()
		var fresh := TrackProps.make(e)
		fresh.position = pos
		fresh.rotation.y = yaw
		fresh.scale = Vector3.ONE * scl
		track.props_root.add_child(fresh)
	_update_gizmo()
	_commit("tint")


func _sync_selected_to_data() -> void:
	var n := _selected_node()
	if n == null or sel < 0:
		return
	var e: Dictionary = _props()[sel]
	e["pos"] = [_r(n.global_position.x), _r(n.global_position.y), _r(n.global_position.z)]
	e["yaw"] = _r(fposmod(rad_to_deg(n.rotation.y) + 180.0, 360.0) - 180.0, 0.1)
	e["scale"] = _r(n.scale.x, 0.01)
	_set_dirty(true)
	_update_prop_label()


# --- surfaces ------------------------------------------------------------------------

func _refresh_surface_list() -> void:
	surf_list.clear()
	if track == null or track.data.is_empty():
		surf_label.text = ""
		return
	var surfaces: Array = track.data.surfaces
	for si in surfaces.size():
		var s: Dictionary = surfaces[si]
		var tex := String(s.get("texture", "")).get_basename().replace(".png", "")
		if tex.length() > 26:
			tex = tex.substr(0, 26) + "..."
		var hid: Dictionary = track.hidden_faces.get(si, {})
		var state := ""
		if track.hidden_surfaces.has(si):
			state = "hidden"
		elif not hid.is_empty():
			state = "%d erased" % hid.size()
		surf_list.add_item("%d  %s  %s  %s" % [si, String(s.get("class", "")), tex, state])
		surf_list.set_item_metadata(surf_list.item_count - 1, si)
		if String(s.get("class", "")) in ["deco", "wall"]:
			surf_list.set_item_custom_fg_color(surf_list.item_count - 1, Color(0.72, 0.75, 0.80))
	surf_label.text = "%d surfaces - %d erased triangles in %d, %d hidden" % [surfaces.size(),
		_hidden_face_count(), track.hidden_faces.size(), track.hidden_surfaces.size()]


func toggle_surface() -> void:
	var rows := surf_list.get_selected_items()
	if rows.is_empty():
		status("Select a surface in the list first.")
		return
	var si := int(surf_list.get_item_metadata(rows[0]))
	var hs: Array = decor.get("hidden_surfaces", [])
	if hs.has(si):
		hs.erase(si)
	else:
		hs.append(si)
	decor["hidden_surfaces"] = hs
	_apply_decor()
	status("Surface %d is now %s." % [si, "hidden" if hs.has(si) else "shown"])


func restore_faces() -> void:
	decor["hidden"] = {}
	_apply_decor()
	status("Every erased triangle is back.")


func restore_all() -> void:
	decor["hidden"] = {}
	decor["hidden_surfaces"] = []
	_apply_decor()
	status("The whole bake is shown again.")


func _apply_decor() -> void:
	if track == null:
		return
	var keep := sel
	track.apply_decor(decor)
	sel = mini(keep, _props().size() - 1)
	_refresh_surface_list()
	_refresh_selection_ui()
	_update_gizmo()
	_set_dirty(true)


# --- undo ----------------------------------------------------------------------------

func _reset_undo() -> void:
	undo_stack.clear()
	redo_stack.clear()
	_committed = JSON.stringify(decor)
	_last_tag = ""
	_update_undo_buttons()


func _commit(tag := "") -> void:
	var now := JSON.stringify(decor)
	if now == _committed:
		return
	var t := Time.get_ticks_msec()
	if tag != "" and tag == _last_tag and t - _last_ms < 700:
		_committed = now
		_last_ms = t
		return
	undo_stack.append(_committed)
	if undo_stack.size() > UNDO_LIMIT:
		undo_stack.pop_front()
	redo_stack.clear()
	_committed = now
	_last_tag = tag
	_last_ms = t
	_update_undo_buttons()
	_set_dirty(true)


func _undo() -> void:
	if undo_stack.is_empty():
		return
	redo_stack.append(_committed)
	_restore(undo_stack.pop_back())
	status("Undone - %d more step(s)." % undo_stack.size())


func _redo() -> void:
	if redo_stack.is_empty():
		return
	undo_stack.append(_committed)
	_restore(redo_stack.pop_back())
	status("Redone - %d more step(s)." % redo_stack.size())


func _restore(snapshot: String) -> void:
	var parsed: Variant = JSON.parse_string(snapshot)
	decor = parsed if parsed is Dictionary else _empty_decor()
	if not (decor.get("props") is Array):
		decor["props"] = []
	if not (decor.get("hidden") is Dictionary):
		decor["hidden"] = {}
	if not (decor.get("hidden_surfaces") is Array):
		decor["hidden_surfaces"] = []
	_committed = JSON.stringify(decor)
	_last_tag = ""
	if track != null:
		track.apply_decor(decor)
	sel = mini(sel, _props().size() - 1)
	_refresh_surface_list()
	_refresh_selection_ui()
	_update_gizmo()
	_set_dirty(true)
	_update_undo_buttons()


func _update_undo_buttons() -> void:
	if undo_btn != null:
		undo_btn.disabled = undo_stack.is_empty()
	if redo_btn != null:
		redo_btn.disabled = redo_stack.is_empty()


func _set_dirty(d: bool) -> void:
	_dirty = d
	if save_btn != null:
		save_btn.text = "Save *" if d else "Save"


func _on_palette_picked(i: int) -> void:
	palette = String(palette_pick.get_item_metadata(i))
	# Don't recolour the prop that happens to be selected: this is the stamp colour.
	_syncing = true
	tint_pick.color = TrackProps.default_tint(palette)
	_syncing = false
	if tool == "place":
		status("Place: click the course to stamp %s." % TrackProps.LABEL.get(palette, palette))


# --- camera --------------------------------------------------------------------------

func _update_camera() -> void:
	if cam == null:
		return
	var off := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch),
		cos(cam_yaw) * cos(cam_pitch)) * cam_dist
	cam.position = focus + off
	cam.look_at(focus, Vector3.UP)
	_update_gizmo()


func _map_points() -> PackedVector3Array:
	if track == null or track.path.size() == 0:
		return PackedVector3Array()
	return track.path.pos


func _frame() -> void:
	if track == null:
		return
	var n := _selected_node()
	if n != null:
		var h := _prop_height(sel)
		focus = n.global_position + Vector3.UP * h * 0.5
		cam_dist = maxf(h * 2.4, 12.0)
		_update_camera()
		return
	var pts := _map_points()
	if pts.is_empty():
		return
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = Vector3(minf(mn.x, p.x), minf(mn.y, p.y), minf(mn.z, p.z))
		mx = Vector3(maxf(mx.x, p.x), maxf(mx.y, p.y), maxf(mx.z, p.z))
	focus = (mn + mx) * 0.5
	cam_dist = maxf(mn.distance_to(mx) * 0.75, 60.0)
	cam_pitch = 0.62
	_update_camera()


func _prop_height(i: int) -> float:
	if i < 0 or i >= _props().size():
		return 1.0
	var e: Dictionary = _props()[i]
	var s: Vector2 = TrackProps.SIZE.get(String(e.get("type", "tree")), Vector2(1, 2))
	return float(s.y) * float(e.get("scale", 1.0))


func _update_selection_box() -> void:
	var n := _selected_node()
	if n == null or sel < 0:
		sel_box.visible = false
		return
	var e: Dictionary = _props()[sel]
	var size: Vector2 = TrackProps.SIZE.get(String(e.get("type", "tree")), Vector2(1, 2))
	var s := float(e.get("scale", 1.0))
	sel_box.visible = true
	sel_box.global_position = n.global_position + Vector3.UP * float(size.y) * s * 0.5
	sel_box.scale = Vector3(float(size.x) * 2.0 * s, float(size.y) * s, float(size.x) * 2.0 * s)


func _pan(rel: Vector2) -> void:
	if cam == null:
		return
	var per_px := 2.0 * cam_dist * tan(deg_to_rad(cam.fov) * 0.5) / maxf(preview_holder.size.y, 1.0)
	focus += (-cam.global_transform.basis.x * rel.x + cam.global_transform.basis.y * rel.y) * per_px
	_update_camera()


func _view_pos(p: Vector2) -> Vector2:
	if preview_holder.size.x <= 0.0 or preview_holder.size.y <= 0.0:
		return p
	return p * Vector2(viewport.size.x, viewport.size.y) / preview_holder.size


## Pixel deltas in SubViewport pixels (the container stretches it to the panel).
func _view_rel(v: Vector2) -> Vector2:
	if preview_holder.size.x <= 0.0 or preview_holder.size.y <= 0.0:
		return v
	return v * Vector2(viewport.size.x, viewport.size.y) / preview_holder.size


# --- picking --------------------------------------------------------------------------

## Uniform grid over the baked triangles. Physics does not step in the editor, so the
## Map Editor raycasts the geometry itself. Small triangles get one cell (their XZ
## bounds), big ground triangles go to `_big` and are always tested.
func _build_pick_grid() -> void:
	_cells.clear()
	_big = PackedInt32Array()
	_grid_built = false
	if track == null:
		return
	var t0 := Time.get_ticks_msec()
	var cells := {}
	var big := PackedInt32Array()
	var tris := 0
	for si in track.surface_geo:
		var g: Dictionary = track.surface_geo[si]
		var pos: PackedVector3Array = g.pos
		var idx: PackedInt32Array = g.idx
		for f in idx.size() / 3:
			var a := pos[idx[f * 3]]
			var b := pos[idx[f * 3 + 1]]
			var c := pos[idx[f * 3 + 2]]
			var c0 := Vector2i(floori(minf(a.x, minf(b.x, c.x)) / CELL), floori(minf(a.z, minf(b.z, c.z)) / CELL))
			var c1 := Vector2i(floori(maxf(a.x, maxf(b.x, c.x)) / CELL), floori(maxf(a.z, maxf(b.z, c.z)) / CELL))
			if (c1.x - c0.x + 1) * (c1.y - c0.y + 1) > 8:
				big.append(si)
				big.append(f)
				continue
			for cx in range(c0.x, c1.x + 1):
				for cz in range(c0.y, c1.y + 1):
					var key := Vector2i(cx, cz)
					var arr: PackedInt32Array = cells.get(key, PackedInt32Array())
					arr.append(si)
					arr.append(f)
					cells[key] = arr
					tris += 1
	_cells = cells
	_big = big
	_grid_built = true
	status("Pick grid: %d triangles in %d cells (+%d large) - %d ms" % [tris, _cells.size(),
		_big.size() / 2, Time.get_ticks_msec() - t0])


static func _ray_tri(o: Vector3, d: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var e1 := b - a
	var e2 := c - a
	var p := d.cross(e2)
	var det := e1.dot(p)
	if absf(det) < 1e-9:
		return -1.0
	var inv := 1.0 / det
	var tv := o - a
	var u := tv.dot(p) * inv
	if u < 0.0 or u > 1.0:
		return -1.0
	var q := tv.cross(e1)
	var v := d.dot(q) * inv
	if v < 0.0 or u + v > 1.0:
		return -1.0
	var t := e2.dot(q) * inv
	return t if t > 0.05 else -1.0


func _face(si: int, f: int) -> Array:
	var g: Dictionary = track.surface_geo.get(si, {})
	if g.is_empty():
		return []
	var pos: PackedVector3Array = g.pos
	var idx: PackedInt32Array = g.idx
	if f * 3 + 2 >= idx.size():
		return []
	return [pos[idx[f * 3]], pos[idx[f * 3 + 1]], pos[idx[f * 3 + 2]]]


func _is_hidden_face(si: int, f: int) -> bool:
	var hid: Dictionary = track.hidden_faces.get(si, {})
	return hid.has(f)


## Closest visible baked triangle along the ray from a viewport position.
func _pick_triangle(vp: Vector2) -> Dictionary:
	if track == null or cam == null:
		return {}
	if not _grid_built:
		_build_pick_grid()
	var o := cam.project_ray_origin(vp)
	var d := cam.project_ray_normal(vp).normalized()
	var best := INF
	var best_s := -1
	var best_f := -1
	var seen := {}
	var step := CELL * 0.4
	var t := 0.0
	while t < 1400.0:
		var p := o + d * t
		var key := Vector2i(floori(p.x / CELL), floori(p.z / CELL))
		if not seen.has(key):
			seen[key] = true
			var arr: PackedInt32Array = _cells.get(key, PackedInt32Array())
			for i in range(0, arr.size(), 2):
				var si := arr[i]
				var f := arr[i + 1]
				if _is_hidden_face(si, f):
					continue
				var tri := _face(si, f)
				if tri.size() < 3:
					continue
				var th := _ray_tri(o, d, tri[0], tri[1], tri[2])
				if th > 0.0 and th < best:
					best = th
					best_s = si
					best_f = f
		t += step
	for i in range(0, _big.size(), 2):
		var si2 := _big[i]
		var f2 := _big[i + 1]
		if _is_hidden_face(si2, f2):
			continue
		var tri2 := _face(si2, f2)
		if tri2.size() < 3:
			continue
		var th2 := _ray_tri(o, d, tri2[0], tri2[1], tri2[2])
		if th2 > 0.0 and th2 < best:
			best = th2
			best_s = si2
			best_f = f2
	if best_s < 0:
		return {}
	var tri3 := _face(best_s, best_f)
	return {"surface": best_s, "face": best_f, "pos": o + d * best,
		"normal": (tri3[1] - tri3[0]).cross(tri3[2] - tri3[0]).normalized()}


## First visible triangle along an arbitrary ray (used by Snap to ground).
func _raycast(from: Vector3, dir: Vector3, max_t: float) -> Dictionary:
	if track == null or not _grid_built:
		return {}
	var best := INF
	var best_s := -1
	var seen := {}
	var step := CELL * 0.4
	var t := 0.0
	while t < max_t:
		var p := from + dir * t
		var key := Vector2i(floori(p.x / CELL), floori(p.z / CELL))
		if not seen.has(key):
			seen[key] = true
			var arr: PackedInt32Array = _cells.get(key, PackedInt32Array())
			for i in range(0, arr.size(), 2):
				var si := arr[i]
				var f := arr[i + 1]
				if _is_hidden_face(si, f):
					continue
				var tri := _face(si, f)
				if tri.size() < 3:
					continue
				var th := _ray_tri(from, dir, tri[0], tri[1], tri[2])
				if th > 0.0 and th < best:
					best = th
					best_s = si
		t += step
	for i in range(0, _big.size(), 2):
		var si2 := _big[i]
		var f2 := _big[i + 1]
		if _is_hidden_face(si2, f2):
			continue
		var tri2 := _face(si2, f2)
		if tri2.size() < 3:
			continue
		var th2 := _ray_tri(from, dir, tri2[0], tri2[1], tri2[2])
		if th2 > 0.0 and th2 < best:
			best = th2
			best_s = si2
	if best_s < 0:
		return {}
	return {"surface": best_s, "pos": from + dir * best}


## Prop under the cursor (bounding sphere per prop), or -1.
func _pick_prop(vp: Vector2) -> int:
	if cam == null:
		return -1
	var o := cam.project_ray_origin(vp)
	var d := cam.project_ray_normal(vp).normalized()
	var best := INF
	var best_i := -1
	var nodes := _prop_nodes()
	var props := _props()
	for i in mini(nodes.size(), props.size()):
		var n := nodes[i] as Node3D
		if n == null:
			continue
		var e: Dictionary = props[i]
		var size: Vector2 = TrackProps.SIZE.get(String(e.get("type", "tree")), Vector2(1, 2))
		var s := float(e.get("scale", 1.0))
		var center := n.global_position + Vector3.UP * float(size.y) * s * 0.5
		var r := maxf(float(size.x) * s, float(size.y) * s * 0.5)
		var oc := o - center
		var b := oc.dot(d)
		var c := oc.length_squared() - r * r
		var disc := b * b - c
		if disc < 0.0:
			continue
		var th := -b - sqrt(disc)
		if th <= 0.0:
			continue
		if th < best:
			best = th
			best_i = i
	return best_i


# --- gizmo -----------------------------------------------------------------------------

func _axis_vector(i: int) -> Vector3:
	match i:
		0:
			return Vector3.RIGHT
		1:
			return Vector3.UP
	return Vector3.BACK


## Arrow meshes are built along local +Y; rotate that onto the axis.
func _axis_basis(i: int) -> Basis:
	match i:
		0:
			return Basis(Vector3(0, 0, 1), -PI * 0.5)
		1:
			return Basis.IDENTITY
	return Basis(Vector3(1, 0, 0), PI * 0.5)


func _axis_color(i: int, hot: bool) -> Color:
	if hot:
		return Color(1.0, 0.86, 0.25)
	match i:
		0:
			return Color(0.95, 0.30, 0.32)
		1:
			return Color(0.42, 0.85, 0.35)
	return Color(0.32, 0.58, 0.98)


func _gizmo_len() -> float:
	return maxf(cam_dist * 0.05, 0.9)


func _build_gizmo() -> void:
	gizmo_root = Node3D.new()
	gizmo_root.name = "Gizmo"
	gizmo_root.visible = false
	preview_root.add_child(gizmo_root)
	var torus := TorusMesh.new()
	torus.inner_radius = 0.985
	torus.outer_radius = 1.012
	torus.rings = 40
	torus.ring_segments = 6
	for a in 3:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Transparent + no depth test: the gizmo is always visible over the course.
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.no_depth_test = true
		mat.albedo_color = _axis_color(a, false)
		var axis := Node3D.new()
		axis.basis = _axis_basis(a)
		gizmo_root.add_child(axis)

		var ring := MeshInstance3D.new()
		ring.mesh = torus
		ring.material_override = mat
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		axis.add_child(ring)

		var arrow := Node3D.new()
		var shaft := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.02
		cyl.bottom_radius = 0.02
		cyl.height = 0.68
		cyl.radial_segments = 6
		shaft.mesh = cyl
		shaft.position = Vector3(0, 0.46, 0)
		shaft.material_override = mat
		shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arrow.add_child(shaft)
		var tip := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.07
		cone.height = 0.22
		cone.radial_segments = 8
		tip.mesh = cone
		tip.position = Vector3(0, 0.9, 0)
		tip.material_override = mat
		tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arrow.add_child(tip)
		axis.add_child(arrow)

		gizmo_axes.append(axis)
		gizmo_rings.append(ring)
		gizmo_arrows.append(arrow)
		gizmo_mats.append(mat)


## The gizmo floats above the prop's base so it is not buried in the ground.
func _gizmo_pivot_of(n: Node3D) -> Vector3:
	return n.global_position + Vector3.UP * maxf(_prop_height(sel) * 0.4, 0.4)


func _update_gizmo() -> void:
	if gizmo_root == null or sel_box == null:
		return
	var n := _selected_node()
	if n == null:
		gizmo_root.visible = false
		sel_box.visible = false
		return
	_g_pivot = _gizmo_pivot_of(n)
	gizmo_root.visible = true
	gizmo_root.transform = Transform3D(Basis.from_scale(Vector3.ONE * _gizmo_len()), _g_pivot)
	for a in gizmo_rings.size():
		gizmo_rings[a].visible = gizmo_mode == "rotate" and a == 1
		gizmo_arrows[a].visible = gizmo_mode == "move" or (gizmo_mode == "scale" and a == 1)
	_update_gizmo_colors()
	_update_selection_box()


func _update_gizmo_colors() -> void:
	for a in gizmo_mats.size():
		var hot := a == gizmo_hover or a == gizmo_drag
		var c := _axis_color(a, hot)
		if gizmo_mode == "scale" and a == 1:
			c = Color(1.0, 0.85, 0.3) if not hot else Color(1.0, 0.95, 0.6)
		if gizmo_mats[a].albedo_color != c:
			gizmo_mats[a].albedo_color = c


## Distance from a ray to a segment, used to grab arrows in 3D.
static func _ray_segment(o: Vector3, d: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	if ab.length_squared() < 0.000001:
		return (o - a).cross(d).length()
	var t := clampf(-(o - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return (o - (a + ab * t)).cross(d).length()


## Axis (0/1/2) of the gizmo handle under the cursor, or -1.
func _gizmo_axis_at(vp: Vector2) -> int:
	var n := _selected_node()
	if n == null or cam == null or not gizmo_root.visible:
		return -1
	var o := cam.project_ray_origin(vp)
	var d := cam.project_ray_normal(vp).normalized()
	var l := _gizmo_len()
	if gizmo_mode == "rotate":
		if absf(d.dot(Vector3.UP)) < 0.05:
			return -1
		var hit: Variant = Plane(Vector3.UP, _g_pivot.y).intersects_ray(o, d)
		if hit == null:
			return -1
		return 1 if absf((Vector3(hit) - _g_pivot).length() - l) < l * 0.16 else -1
	var best := -1
	var bd := l * 0.22
	for a in 3:
		if gizmo_mode == "scale" and a != 1:
			continue
		var dir := _axis_vector(a)
		var dist := _ray_segment(o, d, _g_pivot + dir * l * 0.12, _g_pivot + dir * l)
		if dist < bd:
			bd = dist
			best = a
	return best


func _project(p: Vector3) -> Vector2:
	if cam == null or cam.is_position_behind(p):
		return Vector2.INF
	return cam.unproject_position(p)


## Angle of the cursor around the vertical gizmo axis, for the rotate ring.
func _angle_at(o: Vector3, d: Vector3) -> float:
	var hit: Variant = Plane(Vector3.UP, _g_pivot.y).intersects_ray(o, d)
	if hit == null:
		return 0.0
	var v: Vector3 = Vector3(hit) - _g_pivot
	return atan2(v.z, v.x)


func _begin_gizmo_drag(axis: int, vp: Vector2) -> void:
	var n := _selected_node()
	if n == null or cam == null:
		return
	_drag = 3
	gizmo_drag = axis
	_g_acc = 0.0
	_g_pivot = _gizmo_pivot_of(n)
	_g_start = n.global_position
	if gizmo_mode == "rotate":
		_g_prev_angle = _angle_at(cam.project_ray_origin(vp), cam.project_ray_normal(vp).normalized())
		_g_start = Vector3(0, n.rotation.y, 0)
	elif gizmo_mode == "scale":
		_g_start = Vector3.ONE * n.scale.x
	else:
		# Screen direction of a positive drag along the axis, so the prop keeps up
		# with the cursor even when the camera looks straight along that axis.
		var c := _project(_g_pivot)
		var e := _project(_g_pivot + _axis_vector(axis) * _gizmo_len())
		var d2 := e - c
		if not d2.is_finite() or d2.length() < 6.0:
			_g_dir2 = Vector2.UP
			_g_px_per_unit = -100.0 / _gizmo_len()
		else:
			_g_dir2 = d2.normalized()
			_g_px_per_unit = d2.length() / _gizmo_len()
	_update_gizmo_colors()


func _drag_gizmo(rel: Vector2, vp: Vector2) -> void:
	var n := _selected_node()
	if n == null or cam == null:
		return
	var ctrl := Input.is_key_pressed(KEY_CTRL)
	match gizmo_mode:
		"rotate":
			var a := _angle_at(cam.project_ray_origin(vp), cam.project_ray_normal(vp).normalized())
			var delta := wrapf(a - _g_prev_angle, -PI, PI)
			_g_prev_angle = a
			var yaw := n.rotation.y + delta
			if ctrl:
				yaw = deg_to_rad(snappedf(rad_to_deg(yaw), 15.0))
			n.rotation.y = yaw
		"scale":
			_g_acc += rel.y
			var s := maxf(_g_start.x * exp(_g_acc / 160.0), 0.05)
			if ctrl:
				s = snappedf(s, 0.1)
			n.scale = Vector3.ONE * clampf(s, 0.05, 20.0)
		_:
			_g_acc += rel.dot(_g_dir2)
			var target := _axis_value(_g_start, gizmo_drag) + _g_acc / _g_px_per_unit
			if ctrl:
				target = snappedf(target, 0.5)
			n.global_position = _with_axis(_g_start, gizmo_drag, target)
	_sync_selected_to_data()
	_update_gizmo()


func _hover_gizmo(vp: Vector2) -> void:
	var a := _gizmo_axis_at(vp)
	if a != gizmo_hover:
		gizmo_hover = a
		_update_gizmo_colors()
	preview_holder.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if a >= 0 else Control.CURSOR_ARROW


# --- input ------------------------------------------------------------------------------

func _on_preview_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed and e.double_click:
				_drag = 0
				gizmo_drag = -1
				var hit := _pick_triangle(_view_pos(e.position))
				if not hit.is_empty():
					focus = hit.pos
					cam_dist = clampf(cam_dist * 0.5, 4.0, 400.0)
					_update_camera()
			elif e.pressed:
				_start_drag(e.position)
			else:
				_end_drag()
			preview_holder.accept_event()
		elif e.button_index == MOUSE_BUTTON_RIGHT or e.button_index == MOUSE_BUTTON_MIDDLE:
			if e.pressed and _drag == 0:
				_drag = 2 if (e.button_index == MOUSE_BUTTON_MIDDLE and e.shift_pressed) else 1
				preview_holder.grab_focus()
			elif not e.pressed and (_drag == 1 or _drag == 2):
				_drag = 0
			preview_holder.accept_event()
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist = clampf(cam_dist * 0.88, 3.0, 900.0)
			_update_camera()
			preview_holder.accept_event()
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = clampf(cam_dist * 1.14, 3.0, 900.0)
			_update_camera()
			preview_holder.accept_event()
	elif e is InputEventMouseMotion:
		match _drag:
			1:
				cam_yaw -= e.relative.x * 0.008
				cam_pitch = clampf(cam_pitch - e.relative.y * 0.008, -0.05, 1.5)
				_update_camera()
				preview_holder.accept_event()
			2:
				_pan(e.relative)
				preview_holder.accept_event()
			3:
				_drag_gizmo(_view_rel(e.relative), _view_pos(e.position))
				preview_holder.accept_event()
			4:
				var hit := _pick_triangle(_view_pos(e.position))
				if not hit.is_empty():
					_erase(hit)
				preview_holder.accept_event()
			_:
				_hover_gizmo(_view_pos(e.position))


func _start_drag(p: Vector2) -> void:
	preview_holder.grab_focus()
	var vp := _view_pos(p)
	_drag = 1
	var axis := _gizmo_axis_at(vp)
	if axis >= 0:
		_begin_gizmo_drag(axis, vp)
		return
	match tool:
		"place":
			_drag = 0
			var hit := _pick_triangle(vp)
			if hit.is_empty():
				status("Click on the course to place a prop.")
				return
			add_prop_at(hit.pos)
			status("Placed a %s - click again for more, or pick Select to edit it." % TrackProps.LABEL.get(palette, palette))
		"erase":
			_drag = 4
			_erased = false
			var hit2 := _pick_triangle(vp)
			if not hit2.is_empty():
				_erase(hit2)
		_:
			# Select: a prop pick wins, otherwise clicking empty space deselects.
			_drag = 0
			var i := _pick_prop(vp)
			if i >= 0:
				_select(i)
				status("Selected %s (%d of %d). Drag the gizmo to edit it." % [
					TrackProps.LABEL.get(String(_props()[i].get("type", "")), "prop"), i + 1, _props().size()])
			else:
				_select(-1)


func _end_drag() -> void:
	if _drag == 3:
		_commit()
		_refresh_selection_ui()
	elif _drag == 4:
		if _erased and track != null:
			track.apply_decor(decor)
			_refresh_surface_list()
			_refresh_selection_ui()
			_update_gizmo()
			_commit("erase")
			status("Erased %d triangles so far." % _hidden_face_count())
		if erase_marker != null:
			erase_marker.visible = false
	_drag = 0
	gizmo_drag = -1
	_update_gizmo_colors()
	_hover_gizmo(_view_pos(preview_holder.get_local_mouse_position()))


func _erase(hit: Dictionary) -> void:
	var si := int(hit.surface)
	var f := int(hit.face)
	var hid: Dictionary = decor.get("hidden", {})
	var key := str(si)
	if not hid.has(key):
		hid[key] = []
	var list: Array = hid[key]
	if list.has(f):
		return
	list.append(f)
	decor["hidden"] = hid
	_erased = true
	# Red marker on the triangle being erased; the mesh itself updates on release.
	var tri := _face(si, f)
	if tri.size() == 3:
		var im := ImmediateMesh.new()
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, null)
		im.surface_add_vertex(tri[0])
		im.surface_add_vertex(tri[1])
		im.surface_add_vertex(tri[2])
		im.surface_end()
		erase_marker.mesh = im
		erase_marker.visible = true
	_update_prop_label()


func _shortcut_input(e: InputEvent) -> void:
	if not _dock_active():
		return
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.is_command_or_control_pressed():
		match k.keycode:
			KEY_Z:
				if k.shift_pressed:
					_redo()
				else:
					_undo()
				accept_event()
			KEY_Y:
				_redo()
				accept_event()
			KEY_S:
				save()
				accept_event()
			KEY_D:
				duplicate_selected()
				accept_event()
		return
	if k.alt_pressed:
		return
	match k.keycode:
		KEY_ESCAPE:
			_select(-1)
			_set_tool("select")
			accept_event()
		KEY_1:
			_set_tool("select")
			accept_event()
		KEY_2:
			_set_tool("place")
			accept_event()
		KEY_3:
			_set_tool("erase")
			accept_event()
		KEY_DELETE, KEY_BACKSPACE:
			delete_selected()
			accept_event()
		KEY_G:
			_set_gizmo_mode("move")
			accept_event()
		KEY_R:
			_set_gizmo_mode("rotate")
			accept_event()
		KEY_S:
			_set_gizmo_mode("scale")
			accept_event()
		KEY_F:
			_frame()
			accept_event()


func _dock_active() -> bool:
	if not is_inside_tree() or not is_visible_in_tree() or preview_holder == null:
		return false
	if preview_holder.has_focus():
		return true
	var f := get_viewport().gui_get_focus_owner()
	if f == null:
		return preview_holder.get_global_rect().has_point(get_global_mouse_position())
	return f == self or is_ancestor_of(f)
