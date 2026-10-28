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
##   Erase (3)   drag a brush over baked geometry to erase triangles (floating scenery,
##               z-fighting pieces, a stray wall). The brush radius is in the panel.
##   Part (4)    click one triangle: the whole connected piece around it goes (a tree,
##               a sign, a floating chunk). Huge pieces are refused - use the brush.
##   Fill (5)    drag a brush to close a gap, a hole or a seam - on the ground or on a
##               wall. Only empty cells are painted: geometry already on the level is
##               left alone, so the sheet fills the hole and stops at its rim. The level
##               is the surface under the cursor, else the face this editor erased there,
##               else the surface around the cursor, else the last level used. One stroke
##               is one patch, it sits on the side being looked at, and painting over an
##               earlier fill extends that patch instead of stacking coplanar quads.
##   Restore (6) paint erased triangles back in (the inverse of Erase).
##   Hole (7)    click inside a gap: the whole enclosed empty outline is filled in one go
##               (a long tear along the road, a chunk out of a wall). A break that is open
##               along a side - a broken narrow path - is filled only with the strip
##               between its two ends. A gap too wide for that is refused; use Fill (5).
##   Edges (8)   click rim edges around a gap, then Fill edges (Enter): the picked edges
##               are chained, the outline is triangulated (or two rims are bridged) using
##               their own vertices, with the texture/UVs of the surface the rim belongs to
##               and triangles split to that surface's density. Click an edge again to
##               remove it; the panel shows the live tri count, area and texture.
##
## Everything is written to assets/maps/<id>/decor.json, which Track reads when the
## map loads (props spawn, patches are built, erased triangles are skipped). Re-baking
## the map leaves decor.json alone, but surface indices change, so check the map after
## a re-bake.
## Undo: Ctrl+Z / Ctrl+Shift+Z. Save: Ctrl+S.

const MAPS := "res://content/maps/"
const DECOR := "decor.json"
const UNDO_LIMIT := 60
const CELL := 16.0                 ## pick grid cell size in metres
const MAX_PART := 4000            ## Delete part refuses pieces bigger than this
const MAX_PART_SURFACE := 60000   ## ... and surfacing bigger than this is too slow to weld
const MAX_FILL_CELLS := 3500      ## cells one fill stroke may paint
const MAX_PATCH_CELLS := 16000    ## a fill patch stops growing past this many cells
const FILL_LIFT := 0.035          ## metres the filled sheet floats above what it covers
const FILL_CONFORM := 0.5         ## how far a sheet corner may drape onto real geometry
const FILL_BAND := 0.25           ## geometry this close to the level already fills that cell
const FILL_HOLE_BAND := 1.0       ## Hole treats geometry this close as its rim, so it does
                                  ## not run off the edge of the surface it is closing
const FILL_CORNERS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]
const FILL_NEIGHBOURS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const MAX_HOLE_CELLS := 2000       ## a hole bigger than this is not a hole, it is the void
const MAX_HOLE_SPAN := 250         ## cells from the click, so a runaway fill is caught
const FILL_HOLE_REACH := 8         ## cells of surface that must be on both sides of an
                                  ## open gap for Hole to close it
const MAX_EDGE_EDGES := 128       ## rim edges one edge fill may join
const EDGE_PICK_PX := 16.0        ## how near the cursor an edge must be to be picked
const EDGE_PROBE_RINGS := 3       ## probe rings around the cursor tried (x1, x3, x9) for
                                  ## the surface a gap is cut into, before giving up
const EDGE_REACH_MIN := 2.5       ## metres around the click searched for rim edges
const EDGE_REACH_MAX := 14.0
const MAX_EDGE_TRIS := 12000      ## an edge fill stops subdividing past this
const MAX_EDGE_SUBDIV := 3        ## midpoint subdivision rounds when matching density

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
var _drag := 0                     ## 0 none, 1 orbit, 2 pan, 3 gizmo, 4 brush, 5 fill
var _stroke_dirty := false

# Fill stroke: a level (plane + UV seed) and the cells painted so far.
var _fill_ok := false
var _fill_plane := Plane()
var _fill_origin := Vector3.ZERO
var _fill_normal := Vector3.UP
var _fill_u := Vector3.RIGHT
var _fill_v := Vector3.BACK
var _fill_cell := 1.0
var _fill_seed := {}
var _fill_texture := ""
var _fill_class := "off"
var _fill_alpha := false
var _fill_cells := {}              ## Vector2i cell -> true (only empty ones are painted)
var _fill_seen := {}               ## Vector2i cell -> true (already tested this stroke)
var _fill_keys: Array[Vector2i] = []
var _fill_last := Vector2.INF      ## last stamped point, in cells
var _fill_full := false
var _fill_note := ""                ## extra text for the next commit message
var _fill_cover := false            ## Fill (brush) may paint over geometry when asked
var fill_preview: MultiMeshInstance3D

# Edge fill: boundary (rim) edges picked by hand, then closed with real triangles.
var edge_sel: Array = []           ## [{a, b, ka, kb, si, f, n, tex, cls, alpha}]
var edge_hover: Dictionary = {}
var edge_sel_mesh: MeshInstance3D
var edge_hover_mesh: MeshInstance3D
var edge_rim_mesh: MeshInstance3D
var _edge_hover_cache: Array = []   ## rim edges from the last hover gather
var _edge_hover_vp := Vector2.INF
var _edge_hover_xf := Transform3D()
var _edge_hover_dirty := true
var edge_label: Label
var edge_density: CheckBox
var edge_fill_btn: Button

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
var brush_marker: MeshInstance3D

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
var brush_radius: SpinBox
var patch_pick: OptionButton
var cover_solid: CheckBox
var pos_spins: Array[SpinBox] = []
var yaw_spin: SpinBox
var scale_spin: SpinBox
var sel_label: Label
var surf_list: ItemList
var surf_label: Label
var status_label: Label
var view_status: Label
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
	var grid := GridContainer.new()
	grid.columns = 3
	v.add_child(grid)
	var group := ButtonGroup.new()
	for t in [["select", "Select (1)"], ["place", "Place (2)"], ["erase", "Erase (3)"],
			["part", "Part (4)"], ["fill", "Fill (5)"], ["restore", "Restore (6)"],
			["hole", "Hole (7)"], ["edge", "Edges (8)"]]:
		var b := Button.new()
		b.text = String(t[1])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = String(t[0]) == tool
		b.tooltip_text = {
			"select": "Pick a prop and edit it with the gizmo",
			"place": "Click the course to add the palette prop",
			"erase": "Drag a brush over baked geometry to erase triangles",
			"part": "Click a triangle: delete its whole connected piece",
			"fill": "Drag to paint ground over a gap or hole (works over empty space too)",
			"restore": "Paint erased triangles back in",
			"hole": "Click inside a gap to fill its whole enclosed outline in one go",
			"edge": "Click the empty middle of a gap to take its whole rim, or a single rim edge to add just that one. Fill edges closes it with real triangles",
		}.get(String(t[0]), "")
		b.toggled.connect(_on_tool_toggled.bind(String(t[0])))
		grid.add_child(b)
		tool_btns.append(b)

	var g2 := GridContainer.new()
	g2.columns = 2
	v.add_child(g2)
	_lbl(g2, "Brush / fill size")
	brush_radius = SpinBox.new()
	brush_radius.min_value = 0.25
	brush_radius.max_value = 40.0
	brush_radius.step = 0.25
	brush_radius.value = 4.0
	brush_radius.tooltip_text = "Erase, Restore and Fill brush radius, in metres"
	brush_radius.value_changed.connect(_on_brush_radius_changed)
	g2.add_child(brush_radius)
	_lbl(g2, "Fill texture")
	patch_pick = OptionButton.new()
	patch_pick.tooltip_text = "Texture for Fill patches - \"Same as surface\" copies the one under the cursor"
	g2.add_child(patch_pick)
	_lbl(g2, "Fill over ground")
	cover_solid = CheckBox.new()
	cover_solid.text = "Cover existing"
	cover_solid.tooltip_text = "Off: Fill only closes empty space. On: it also paints over\n" + \
		"geometry that is already there (3.5 cm above it, so it cannot z-fight) - use it for\n" + \
		"an ugly strip that is a surface rather than a hole."
	g2.add_child(cover_solid)

	# --- edge fill -----------------------------------------------------------------
	_lbl(v, "Edge fill")
	row = HBoxContainer.new()
	v.add_child(row)
	edge_fill_btn = _btn(row, "Fill edges", fill_edges)
	edge_fill_btn.disabled = true
	edge_fill_btn.tooltip_text = "Close the selected rim with real triangles (Enter): the rim's own\n" + \
		"vertices are used, so the sheet meets the course exactly, textured like the\n" + \
		"surface it belongs to."
	_btn(row, "Clear edges", clear_edges).tooltip_text = "Forget the selected rim edges"
	edge_density = CheckBox.new()
	edge_density.text = "Match tri density"
	edge_density.button_pressed = true
	edge_density.tooltip_text = "Split the fill until its triangles are about the size of the\n" + \
		"surface next to the rim, instead of one big slab."
	edge_density.toggled.connect(func(_on: bool) -> void: _edge_refresh())
	v.add_child(edge_density)
	edge_label = _muted(v, "Edges: click the rim edge of a gap, Shift+click for the whole rim, then Fill edges (Enter).")

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
	_btn(row, "Remove patches", remove_patches).tooltip_text = "Delete every fill patch"

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

	view_status = Label.new()
	view_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	view_status.add_theme_color_override("font_color", Color(0.78, 0.81, 0.86))
	view_status.text = "Pick a map and a tool."
	right.add_child(view_status)

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

	# Brush cursor: a flat ring in the surface, so the erase radius is visible.
	brush_marker = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.94
	ring.outer_radius = 1.0
	ring.rings = 32
	ring.ring_segments = 4
	brush_marker.mesh = ring
	var brm := StandardMaterial3D.new()
	brm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	brm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	brm.albedo_color = Color(1.0, 0.92, 0.35, 0.85)
	brm.cull_mode = BaseMaterial3D.CULL_DISABLED
	brm.no_depth_test = true
	brush_marker.material_override = brm
	brush_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	brush_marker.visible = false
	preview_root.add_child(brush_marker)
	preview_holder.mouse_exited.connect(func() -> void:
		_hide_brush()
		_edge_rim_redraw([]))

	# Rim edges picked for the edge fill (drawn over the course, like the gizmo).
	edge_sel_mesh = _line_mesh()
	edge_hover_mesh = _line_mesh()
	edge_rim_mesh = _line_mesh()

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
	# Also right above the 3D view: the panel status can be scrolled out of sight, and a
	# tool that quietly does nothing is the worst kind.
	if view_status != null:
		view_status.text = text


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
	if not (decor.get("patches") is Array):
		decor["patches"] = []

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
	_fill_ok = false
	_fill_cells.clear()
	_fill_seen.clear()
	_fill_keys.clear()
	_fill_clear_preview()
	edge_sel.clear()
	edge_hover = {}
	_edge_hover_dirty = true
	_edge_redraw()
	_edge_refresh()
	_build_pick_grid()
	_refresh_patch_textures()
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
	var patches: Variant = decor.get("patches", [])
	if patches is Array and not (patches as Array).is_empty():
		out["patches"] = patches
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
	var ids := ["select", "place", "erase", "part", "fill", "restore", "hole", "edge"]
	for i in mini(tool_btns.size(), ids.size()):
		tool_btns[i].set_pressed_no_signal(ids[i] == t)
	_hide_brush()
	_fill_clear_preview()
	if t != "edge":
		edge_hover = {}
		_edge_hover_redraw()
		_edge_rim_redraw([])
	match t:
		"select":
			status("Select: click a prop, then drag the gizmo. Delete removes it.")
		"place":
			status("Place: click the course to stamp %s." % TrackProps.LABEL.get(palette, palette))
		"erase":
			status("Erase: drag the brush over geometry to hide triangles. Release to apply.")
		"part":
			status("Part: click a triangle to delete its whole connected piece (max %d triangles)." % MAX_PART)
		"fill":
			status("Fill: drag over a gap or hole to paint %.1f m of ground there." % brush_radius.value)
		"restore":
			status("Restore: drag the brush over erased spots to bring them back.")
		"hole":
			status("Hole: click inside a gap to fill its whole enclosed outline.")
		"edge":
			status("Edges: click rim edges around a gap (Shift+click takes the whole rim), then Fill edges (Enter).")


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
		props_label.text = "%d props  -  %d erased tris  -  %d patches" % [_props().size(),
			_hidden_face_count(), _patch_count()]


func _patch_count() -> int:
	var p: Variant = decor.get("patches", [])
	return (p as Array).size() if p is Array else 0


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
	_edge_hover_dirty = true
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
	if not (decor.get("patches") is Array):
		decor["patches"] = []
	_committed = JSON.stringify(decor)
	_last_tag = ""
	_edge_hover_dirty = true
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
	if track == null or cam == null or not vp.is_finite():
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


## Nearest triangle that has been erased, along the ray from a viewport position. A gap
## cut in this editor knows which surface used to fill it, which is a much better level
## than anything that can be guessed from the surroundings.
func _pick_hidden(vp: Vector2) -> Dictionary:
	if track == null or cam == null or not vp.is_finite():
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
				if not _is_hidden_face(si, f):
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
		if not _is_hidden_face(si2, f2):
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
	var nrm := Vector3.UP
	if tri3.size() >= 3:
		nrm = (tri3[1] - tri3[0]).cross(tri3[2] - tri3[0]).normalized()
	return {"surface": best_s, "face": best_f, "pos": o + d * best, "normal": nrm}


## First visible triangle along an arbitrary ray (Snap to ground, fill draping).
func _raycast(from: Vector3, dir: Vector3, max_t: float) -> Dictionary:
	if track == null or not _grid_built:
		return {}
	var best := INF
	var best_s := -1
	var best_f := -1
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
		var th2 := _ray_tri(from, dir, tri2[0], tri2[1], tri2[2])
		if th2 > 0.0 and th2 < best:
			best = th2
			best_s = si2
			best_f = f2
	if best_s < 0:
		return {}
	var hit_tri := _face(best_s, best_f)
	var hit_n := Vector3.UP
	if hit_tri.size() >= 3:
		hit_n = (hit_tri[1] - hit_tri[0]).cross(hit_tri[2] - hit_tri[0]).normalized()
	return {"surface": best_s, "face": best_f, "pos": from + dir * best, "normal": hit_n}


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
				_start_drag(e.position, e.shift_pressed)
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
				var vp := _view_pos(e.position)
				var hit := _pick_triangle(vp)
				if not hit.is_empty():
					_show_brush(hit.pos, hit.normal)
					if tool == "restore":
						_brush_show(hit.pos, brush_radius.value)
					else:
						_brush_hide(hit.pos, brush_radius.value)
				preview_holder.accept_event()
			5:
				_fill_paint(_view_pos(e.position))
				preview_holder.accept_event()
			_:
				if tool == "edge":
					_edge_hover_at(_view_pos(e.position))
				else:
					_hover_gizmo(_view_pos(e.position))
				_update_brush_hover(_view_pos(e.position))


func _start_drag(p: Vector2, shift := false) -> void:
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
		"part":
			_drag = 0
			var hp := _pick_triangle(vp)
			if hp.is_empty():
				status("Click a triangle to delete the piece it belongs to.")
			else:
				_delete_part(hp)
		"fill":
			_begin_fill(vp)
		"hole":
			_drag = 0
			_fill_hole_at(vp)
		"edge":
			_drag = 0
			var he := _edge_pick(vp)
			if he.is_empty():
				status("Edge fill: point at a gap - click its rim edge, or its empty middle, to take the outline.")
			elif shift or bool(he.get("gap", false)):
				var added := edge_grow(he)
				_edge_redraw()
				_edge_rim_redraw(_edge_hover_cache)
				_edge_refresh()
				if added == 0:
					status("That rim is already selected - press Fill edges (Enter) to close it.")
				elif shift:
					status("Shift+click took %d rim edges around the gap - %d selected." % [added, edge_sel.size()])
				else:
					status("Clicked into the gap: took its whole %d-edge rim - press Fill edges (Enter)." % added)
			else:
				_edge_toggle(he)
				edge_hover = {}
				_edge_hover_redraw()
		"erase", "restore":
			_drag = 4
			_stroke_dirty = false
			var hb := _pick_triangle(vp)
			if not hb.is_empty():
				_show_brush(hb.pos, hb.normal)
				if tool == "restore":
					_brush_show(hb.pos, brush_radius.value)
				else:
					_brush_hide(hb.pos, brush_radius.value)
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
		if _stroke_dirty and track != null:
			_edge_hover_dirty = true
			track.apply_decor(decor)
			_refresh_surface_list()
			_refresh_selection_ui()
			_update_gizmo()
			_commit()
			status("%d erased triangles, %d patches." % [_hidden_face_count(), _patch_count()])
	elif _drag == 5:
		_fill_commit()
	_drag = 0
	gizmo_drag = -1
	_update_gizmo_colors()
	var last := _last_view_pos()
	_hover_gizmo(last)
	_update_brush_hover(last)


# --- brush / part / patch -------------------------------------------------------------

## Erases every triangle whose closest point is inside the brush.
func _brush_hide(centre: Vector3, radius: float) -> int:
	var hid: Dictionary = decor.get("hidden", {})
	var n := 0
	for pair in _brush_faces(centre, radius):
		var si := int(pair[0])
		var f := int(pair[1])
		var key := str(si)
		if not hid.has(key):
			hid[key] = []
		var list: Array = hid[key]
		if list.has(f):
			continue
		list.append(f)
		n += 1
	if n > 0:
		decor["hidden"] = hid
		_stroke_dirty = true
		_update_prop_label()
	return n


## Paints erased triangles inside the brush back in.
func _brush_show(centre: Vector3, radius: float) -> int:
	var hid: Dictionary = decor.get("hidden", {})
	if hid.is_empty():
		return 0
	var r2 := radius * radius
	var removed := 0
	for k in hid.keys():
		var si := int(k)
		var keep: Array = []
		for fv in (hid[k] as Array):
			var f := int(fv)
			var tri := _face(si, f)
			if tri.size() >= 3 and _closest_on_tri(tri[0], tri[1], tri[2], centre).distance_squared_to(centre) <= r2:
				removed += 1
			else:
				keep.append(fv)
		if keep.is_empty():
			hid.erase(k)
		else:
			hid[k] = keep
	if removed > 0:
		decor["hidden"] = hid
		_stroke_dirty = true
		_update_prop_label()
	return removed


## (surface, face) pairs inside the brush, from the pick grid.
func _brush_faces(centre: Vector3, radius: float) -> Array:
	var out: Array = []
	if not _grid_built:
		return out
	var r2 := radius * radius
	var c0 := Vector2i(floori((centre.x - radius) / CELL), floori((centre.z - radius) / CELL))
	var c1 := Vector2i(floori((centre.x + radius) / CELL), floori((centre.z + radius) / CELL))
	var seen := {}
	for cx in range(c0.x, c1.x + 1):
		for cz in range(c0.y, c1.y + 1):
			var arr: PackedInt32Array = _cells.get(Vector2i(cx, cz), PackedInt32Array())
			for i in range(0, arr.size(), 2):
				_brush_face(int(arr[i]), int(arr[i + 1]), centre, r2, seen, out)
	for i in range(0, _big.size(), 2):
		_brush_face(int(_big[i]), int(_big[i + 1]), centre, r2, seen, out)
	return out


func _brush_face(si: int, f: int, centre: Vector3, r2: float, seen: Dictionary, out: Array) -> void:
	var key := Vector2i(si, f)
	if seen.has(key):
		return
	seen[key] = true
	if _is_hidden_face(si, f):
		return
	var tri := _face(si, f)
	if tri.size() < 3:
		return
	if _closest_on_tri(tri[0], tri[1], tri[2], centre).distance_squared_to(centre) <= r2:
		out.append([si, f])


## Closest point on a triangle to `p` (Ericson, Real-Time Collision Detection).
static func _closest_on_tri(a: Vector3, b: Vector3, c: Vector3, p: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var den := 1.0 / (va + vb + vc)
	return a + ab * (vb * den) + ac * (vc * den)


## Deletes the whole connected piece around the clicked triangle (a tree, a sign, a
## floating chunk). The bake is triangle soup with unshared vertices, so corners are
## welded by position (1 cm) to find what actually touches. Pieces bigger than
## MAX_PART are refused so a stray click on the route cannot wipe it.
func _delete_part(hit: Dictionary) -> void:
	var si := int(hit.surface)
	var f := int(hit.face)
	var g: Dictionary = track.surface_geo.get(si, {})
	if g.is_empty():
		return
	var idx: PackedInt32Array = g.idx
	var pos: PackedVector3Array = g.pos
	var faces := idx.size() / 3
	if f < 0 or f >= faces:
		return
	if faces > MAX_PART_SURFACE:
		status("This surface has %d triangles - the Part tool is too slow on it; use the erase brush or hide the surface." % faces)
		return
	var welded := {}
	for ff in faces:
		for k in 3:
			var p := pos[idx[ff * 3 + k]]
			var key := Vector3i(roundi(p.x * 100.0), roundi(p.y * 100.0), roundi(p.z * 100.0))
			var arr: PackedInt32Array = welded.get(key, PackedInt32Array())
			arr.append(ff)
			welded[key] = arr
	var seen := {f: true}
	var stack: Array[int] = [f]
	var part := PackedInt32Array()
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		part.append(cur)
		if part.size() > MAX_PART:
			status("That piece is over %d triangles - too big for Part; use the erase brush or hide the whole surface." % MAX_PART)
			return
		for k in 3:
			var p2 := pos[idx[cur * 3 + k]]
			var key2 := Vector3i(roundi(p2.x * 100.0), roundi(p2.y * 100.0), roundi(p2.z * 100.0))
			for nf in (welded[key2] as PackedInt32Array):
				if not seen.has(nf):
					seen[nf] = true
					stack.append(nf)
	var hid: Dictionary = decor.get("hidden", {})
	var key := str(si)
	if not hid.has(key):
		hid[key] = []
	var list: Array = hid[key]
	for ff in part:
		if not list.has(ff):
			list.append(ff)
	decor["hidden"] = hid
	_edge_hover_dirty = true
	track.apply_decor(decor)
	_refresh_surface_list()
	_refresh_selection_ui()
	_update_gizmo()
	_commit()
	status("Deleted a connected piece of %d triangles (%d erased in total)." % [part.size(), _hidden_face_count()])


## Fill: paint a sheet of ground over a gap, a hole or a seam. The level comes from the
## triangle under the cursor; over a hole from the terrain nearest the cursor on screen;
## and with nothing nearby the last fill's level is reused, so an edge can be painted
## with no geometry under it. One stroke is one patch, and painting over an earlier fill
## extends that patch, so two coplanar sheets never fight for the same pixels.
func _begin_fill(vp: Vector2) -> void:
	if track == null or cam == null:
		return
	if not _fill_plane_at(vp):
		status("Fill: no surface in view to take a level from - orbit until the area around the gap is on screen.")
		return
	_drag = 5
	_fill_cover = cover_solid != null and cover_solid.button_pressed
	_fill_cells.clear()
	_fill_seen.clear()
	_fill_keys.clear()
	_fill_last = Vector2.INF
	_fill_full = false
	_fill_note = ""
	_ensure_fill_preview()
	_fill_paint(vp)


## Takes the fill level for this stamp. False means there is no surface to take it from.
## Order: the surface under the cursor, then what this editor erased there (a gap it cut
## itself knows exactly which surface used to be in it), then the surface around the
## cursor, then the last level used.
func _fill_plane_at(vp: Vector2) -> bool:
	var hit := _pick_triangle(vp)
	if hit.is_empty():
		hit = _pick_hidden(vp)
	if hit.is_empty():
		hit = _fill_nearby_hit(vp)
	if not hit.is_empty():
		return _fill_set_level(hit)
	return _fill_ok and not _fill_seed.is_empty()


## Surface to continue when the cursor is over empty space. Rays are marched outward
## from the cursor in 12 directions until they leave the view, and the hits are grouped
## by plane: the plane that surrounds the cursor on the most sides wins (ties go to the
## nearest). A gap in a wall therefore takes the wall's plane - not the ground far below,
## not whatever is visible through the gap - and the march reaches the rim of a big hole
## instead of giving up next to the cursor. The nearest hit of that plane is the seed.
func _fill_nearby_hit(vp: Vector2) -> Dictionary:
	if cam == null:
		return {}
	var eye := cam.global_position
	var limit := maxf(viewport.size.x, viewport.size.y) * 0.6
	var dirs := 12
	var clusters: Array = []
	for i in dirs:
		var ang := TAU * float(i) / float(dirs)
		var dir := Vector2(cos(ang), sin(ang))
		var r := 8.0
		while r <= limit:
			var at: Vector2 = vp + dir * r
			var hit := _pick_triangle(at)
			if not hit.is_empty():
				var pos := Vector3(hit.pos)
				var n := Vector3(hit.normal)
				if (eye - pos).dot(n) < 0.0:
					n = -n
				var d := n.dot(pos)
				var depth := eye.distance_to(pos)
				var joined := false
				for cl in clusters:
					if Vector3(cl.n).dot(n) > 0.995 and absf(float(cl.d) - d) < 0.15:
						cl.count = int(cl.count) + 1
						if depth < float(cl.depth):
							cl.depth = depth
							cl.hit = hit
						joined = true
						break
				if not joined:
					clusters.append({"n": n, "d": d, "count": 1, "depth": depth, "hit": hit})
				break       # this direction found its surface; next direction
			r += 12.0
	var best: Dictionary = {}
	for cl in clusters:
		if best.is_empty() or int(cl.count) > int(best.count) \
				or (int(cl.count) == int(best.count) and float(cl.depth) < float(best.depth)):
			best = cl
	return best.get("hit", {})


## Level for the stroke: a plane through the picked triangle, plus its UV mapping, so a
## fill keeps the same texel density and blends into the course.
func _fill_set_level(hit: Dictionary) -> bool:
	if track == null:
		return false
	var si := int(hit.get("surface", -1))
	var f := int(hit.get("face", -1))
	var g: Dictionary = track.surface_geo.get(si, {})
	var tri := _face(si, f)
	if g.is_empty() or tri.size() < 3:
		return false
	var a: Vector3 = tri[0]
	var b: Vector3 = tri[1]
	var c: Vector3 = tri[2]
	var n := (b - a).cross(c - a).normalized()
	if n.length_squared() < 0.5:
		return false
	# The sheet has to sit on the side being looked at: on a wall or a ceiling the
	# triangle's own winding may face into the solid, which would bury the fill.
	if cam != null and (cam.global_position - a).dot(n) < 0.0:
		n = -n
	var u := b - a
	u = u - n * u.dot(n)
	if u.length_squared() < 1e-6:
		u = Vector3.RIGHT - n * n.x
	u = u.normalized()
	var uvs := _tri_uv(si, f)
	_fill_seed = {"a": a, "b": b, "c": c, "ua": uvs[0], "ub": uvs[1], "uc": uvs[2]}
	_fill_origin = a
	_fill_normal = n
	_fill_u = u
	_fill_v = n.cross(u)
	_fill_plane = Plane(n, n.dot(a))
	_fill_ok = true
	_fill_texture = String(g.get("texture", ""))
	if patch_pick != null and patch_pick.selected >= 0:
		var chosen := String(patch_pick.get_item_metadata(patch_pick.selected))
		if chosen != "":
			_fill_texture = chosen
	if _fill_texture.begins_with("conn"):
		# Connector surfaces use a blend shader; a patch takes the connector's far texture.
		var conns: Dictionary = track.data.get("connectors", {})
		_fill_texture = String((conns.get(_fill_texture, {}) as Dictionary).get("b", ""))
	_fill_alpha = bool(g.get("alpha", false))
	# A fill over the road keeps road grip; everything else is drivable off-road.
	_fill_class = "road" if String(g.get("class", "off")) == "road" else "off"
	_fill_cell = clampf(brush_radius.value / 5.0, 0.35, 2.0)
	return true


func _tri_uv(si: int, f: int) -> Array:
	var g: Dictionary = track.surface_geo.get(si, {})
	if g.is_empty() or f < 0:
		return [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	var idx: PackedInt32Array = g.idx
	var uvs: PackedVector2Array = g.get("uv", PackedVector2Array())
	var out: Array = []
	for k in 3:
		if f * 3 + k >= idx.size():
			out.append(Vector2.ZERO)
			continue
		var vi := idx[f * 3 + k]
		out.append(uvs[vi] if vi < uvs.size() else Vector2.ZERO)
	return out


## Paints the brush at a viewport position. It stamps cells, not triangles: empty space
## has no triangle and must fill just as well.
func _fill_paint(vp: Vector2) -> void:
	if not _fill_ok or cam == null:
		return
	var d := cam.project_ray_normal(vp).normalized()
	# Looking almost along the plane would throw the stamp kilometres away.
	if absf(d.dot(_fill_normal)) < 0.05:
		return
	var p: Variant = _fill_plane.intersects_ray(cam.project_ray_origin(vp), d)
	if p == null:
		return
	_show_brush(Vector3(p), _fill_normal)
	_fill_stamp_world(Vector3(p))


## Hole: closes the whole empty region under the cursor, bounded by the surface around it
## - the outline of the gap rather than a brush stroke. Fill (5) still paints freely, so
## long tears can be closed in one click and odd shapes can be brushed by hand.
func _fill_hole_at(vp: Vector2) -> void:
	if track == null or cam == null:
		return
	_fill_cover = false          # a hole is only ever closed over empty space
	if not _fill_plane_at(vp):
		status("Hole: no surface in view to take a level from - orbit so the area around the gap is on screen.")
		return
	# A hole is filled as a whole, so keep the cells coarse enough that a long tear does
	# not become tens of thousands of quads.
	_fill_cell = maxf(_fill_cell, 0.5)
	var d := cam.project_ray_normal(vp).normalized()
	if absf(d.dot(_fill_normal)) < 0.05:
		status("Hole: you are looking almost straight along that level - orbit a little and click again.")
		return
	var p: Variant = _fill_plane.intersects_ray(cam.project_ray_origin(vp), d)
	if p == null:
		status("Hole: the cursor does not land on that level - click the gap again.")
		return
	var start := _fill_cell_of(Vector3(p))
	if _fill_covered(_fill_cell_point(start)):
		status("Hole: that spot is solid - click inside the gap.")
		return
	var first := _fill_flood(start, MAX_HOLE_CELLS, MAX_HOLE_SPAN)
	var region: Dictionary = first.cells
	_fill_note = ""
	if bool(first.escaped):
		# Open gap (a break in a narrow path is open along its sides): keep what lies
		# between the ends of the surface instead of flooding the void beside it.
		# The cap covers the whole 25 x 25 cell box, so the walk sees every rim in it.
		var tight := _fill_flood(start, 700, 12)
		region = _fill_connected(_fill_corridor(tight.cells, tight.rim, FILL_HOLE_REACH), start)
		if not region.is_empty():
			_fill_note = "It is open on a side, so only the strip between its edges was filled."
	if region.is_empty():
		# No closed outline to follow: fill one brush stamp under the cursor, so a click
		# always does something visible instead of failing without a trace.
		_fill_cells.clear()
		_fill_seen.clear()
		_fill_keys.clear()
		_fill_last = Vector2.INF
		_fill_stamp_world(Vector3(p))
		_fill_note = "No closed outline here, so one brush stamp was filled instead."
		_fill_commit()
		return
	_fill_cells = region
	_fill_keys.clear()
	_fill_commit()


## Walks the empty cells out from `start`, stopping at the surface around it. `rim` is the
## covered cells that bounded the walk; `escaped` means it ran into a cap or its span,
## i.e. the gap is not closed.
func _fill_flood(start: Vector2i, cap: int, span: int) -> Dictionary:
	var cells := {}
	var rim := {}
	var seen := {start: true}
	var queue: Array[Vector2i] = [start]
	var escaped := false
	while not queue.is_empty():
		var key: Vector2i = queue.pop_back()
		if _fill_near(_fill_cell_point(key), FILL_HOLE_BAND):
			rim[key] = true
			continue
		cells[key] = true
		if cells.size() > cap:
			escaped = true
			break
		for dv in FILL_NEIGHBOURS:
			var step: Vector2i = dv
			var nk := key + step
			if seen.has(nk):
				continue
			if absi(nk.x - start.x) > span or absi(nk.y - start.y) > span:
				escaped = true
				continue
			seen[nk] = true
			queue.append(nk)
	return {"cells": cells, "rim": rim, "escaped": escaped}


## Keeps only cells that sit between two sides of the surface: a break in a narrow path
## has geometry within a few cells on both sides of one axis, the void beside the path
## does not. This is what turns an open gap into the strip across it.
func _fill_corridor(cells: Dictionary, rim: Dictionary, reach: int) -> Dictionary:
	if cells.is_empty() or rim.is_empty():
		return {}
	var out := {}
	for kv in cells:
		var k: Vector2i = kv
		var across := _rim_within(rim, k, Vector2i(1, 0), reach) \
			and _rim_within(rim, k, Vector2i(-1, 0), reach)
		var along := _rim_within(rim, k, Vector2i(0, 1), reach) \
			and _rim_within(rim, k, Vector2i(0, -1), reach)
		if across or along:
			out[k] = true
	return out


func _rim_within(rim: Dictionary, from: Vector2i, dir: Vector2i, reach: int) -> bool:
	for i in range(1, reach + 1):
		if rim.has(from + dir * i):
			return true
	return false


## Keeps the part of `cells` reachable from `start`, so a clipped gap cannot leave
## detached islands floating around.
func _fill_connected(cells: Dictionary, start: Vector2i) -> Dictionary:
	if not cells.has(start):
		return {}
	var out := {start: true}
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty():
		var key: Vector2i = queue.pop_back()
		for dv in FILL_NEIGHBOURS:
			var step: Vector2i = dv
			var nk := key + step
			if cells.has(nk) and not out.has(nk):
				out[nk] = true
				queue.append(nk)
	return out


## Cell of a point on the fill plane.
func _fill_cell_of(p: Vector3) -> Vector2i:
	var local := p - _fill_origin
	return Vector2i(floori(local.dot(_fill_u) / _fill_cell), floori(local.dot(_fill_v) / _fill_cell))


## Stamps at a world point on the fill plane, painting a band between samples so a fast
## drag leaves no gaps.
func _fill_stamp_world(p: Vector3) -> void:
	var local := p - _fill_origin
	var c := Vector2(local.dot(_fill_u), local.dot(_fill_v)) / _fill_cell
	if _fill_last.is_finite():
		# Capped so a grazing drag across a wall cannot turn into thousands of stamps.
		var steps := clampi(ceili(c.distance_to(_fill_last) / 0.45), 1, 512)
		for i in range(1, steps + 1):
			_fill_stamp(_fill_last.lerp(c, float(i) / float(steps)))
	else:
		_fill_stamp(c)
	_fill_last = c


func _fill_stamp(c: Vector2) -> void:
	var r := maxf(brush_radius.value, 0.25) / _fill_cell
	var x0 := floori(c.x - r)
	var x1 := floori(c.x + r)
	var y0 := floori(c.y - r)
	var y1 := floori(c.y + r)
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			if Vector2(cx + 0.5, cy + 0.5).distance_to(c) > r:
				continue
			var key := Vector2i(cx, cy)
			if _fill_cells.has(key) or _fill_seen.has(key):
				continue
			_fill_seen[key] = true
			# Fill only empty space: a cell that already has geometry on the level is
			# left alone, so the sheet closes gaps instead of lying over the surface.
			if _fill_covered(_fill_cell_point(key)):
				continue
			if _fill_keys.size() >= MAX_FILL_CELLS:
				if not _fill_full:
					_fill_full = true
					status("Fill stroke is full (%d cells) - release, then paint the rest." % MAX_FILL_CELLS)
				return
			_fill_cells[key] = true
			_fill_keys.append(key)
			_fill_preview_cell(key, _fill_keys.size() - 1)
	if fill_preview != null and fill_preview.multimesh != null:
		fill_preview.multimesh.visible_instance_count = _fill_keys.size()


## Centre of a painted cell, on the fill plane.
func _fill_cell_point(key: Vector2i) -> Vector3:
	return _fill_origin + _fill_u * (float(key.x) + 0.5) * _fill_cell \
		+ _fill_v * (float(key.y) + 0.5) * _fill_cell


## Is there a surface within `band` metres of this point on the level? Only surfaces
## roughly parallel to the level count, so a skirt or a wall inside a gap does not.
func _fill_near(wp: Vector3, band: float) -> bool:
	var hit := _raycast(wp + _fill_normal * band, -_fill_normal, band * 2.0)
	if hit.is_empty():
		return false
	if absf(_vec_of(hit.get("normal", Vector3.ZERO)).dot(_fill_normal)) < 0.45:
		return false
	return absf((Vector3(hit.pos) - wp).dot(_fill_normal)) <= band


## Does this point on the level already have a surface on it? Then the brush leaves the
## cell alone: Fill only paints empty space, never over geometry that is already there -
## unless Cover existing is ticked, for a strip that is a surface rather than a hole.
func _fill_covered(wp: Vector3) -> bool:
	if _fill_cover:
		return false
	return _fill_near(wp, FILL_BAND)


func _ensure_fill_preview() -> void:
	if fill_preview != null and is_instance_valid(fill_preview):
		return
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = MAX_FILL_CELLS
	mm.visible_instance_count = 0
	fill_preview = MultiMeshInstance3D.new()
	fill_preview.multimesh = mm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.35, 0.95, 0.7, 0.4)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	fill_preview.material_override = m
	fill_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	preview_root.add_child(fill_preview)


## Shows a painted cell while the stroke is still going, so coverage is visible live.
func _fill_preview_cell(key: Vector2i, i: int) -> void:
	if fill_preview == null or fill_preview.multimesh == null:
		return
	var basis := Basis(_fill_u * _fill_cell, _fill_v * _fill_cell, _fill_normal * _fill_cell)
	fill_preview.multimesh.set_instance_transform(i,
		Transform3D(basis, _fill_cell_point(key) + _fill_normal * (FILL_LIFT + 0.02)))


func _fill_clear_preview() -> void:
	if fill_preview != null and fill_preview.multimesh != null:
		fill_preview.multimesh.visible_instance_count = 0


func _fill_commit() -> void:
	_fill_clear_preview()
	if track == null:
		return
	if _fill_cells.is_empty():
		status("Fill: nothing empty under the brush - it only closes gaps and holes.")
		_fill_note = ""
		return
	var patches: Variant = decor.get("patches", [])
	if not (patches is Array):
		patches = []
	var cells := _fill_cells
	var index := _fill_merge_index(patches)
	if index >= 0:
		# Painting over an earlier fill on the same plane extends that patch: one sheet,
		# never two coplanar quads fighting for the same pixels.
		var old: Dictionary = patches[index]
		var merged := {}
		for cell in (old.get("cells", []) as Array):
			var key: Variant = _fill_remap_cell(old.get("grid", {}), cell)
			if key != null:
				merged[key] = true
		for k in cells:
			merged[k] = true
		if merged.size() <= MAX_PATCH_CELLS:
			patches[index] = _fill_patch(merged)
			cells = merged
		else:
			status("That fill patch is already full - starting a new one.")
			index = -1
	if index < 0:
		patches.append(_fill_patch(cells))
	decor["patches"] = patches
	_edge_hover_dirty = true
	track.apply_decor(decor)
	_refresh_surface_list()
	_refresh_selection_ui()
	_update_gizmo()
	_commit()
	var msg := "Filled %d cell(s) (%.1f m2) with %s." % [cells.size(),
		float(cells.size()) * _fill_cell * _fill_cell,
		_fill_texture if _fill_texture != "" else "a flat colour"]
	if _fill_note != "":
		msg += " " + _fill_note
		_fill_note = ""
	status(msg)


## Index of an existing patch on this stroke's plane and texture, or -1. Only patches
## written by this brush carry a grid, so older ones are left alone.
func _fill_merge_index(patches: Array) -> int:
	for i in patches.size():
		var p: Variant = patches[i]
		if not (p is Dictionary):
			continue
		var d: Dictionary = p
		if String(d.get("texture", "")) != _fill_texture:
			continue
		if String(d.get("class", "off")) != _fill_class or bool(d.get("alpha", false)) != _fill_alpha:
			continue
		var g: Variant = d.get("grid")
		if not (g is Dictionary) or not (d.get("cells") is Array):
			continue
		var n := _vec_of((g as Dictionary).get("n", [])).normalized()
		var org := _vec_of((g as Dictionary).get("org", []))
		if n.dot(_fill_normal) < 0.999:
			continue
		if absf((org - _fill_origin).dot(_fill_normal)) > 0.05:
			continue
		return i
	return -1


## Re-maps a cell of an existing patch into this stroke's grid: they share the plane but
## not necessarily the origin, so the cell is moved by world position.
func _fill_remap_cell(grid: Variant, cell: Variant) -> Variant:
	if not (grid is Dictionary) or not (cell is Array) or (cell as Array).size() < 2:
		return null
	var g: Dictionary = grid
	var org := _vec_of(g.get("org", []))
	var u := _vec_of(g.get("u", [])).normalized()
	var v := _vec_of(g.get("v", [])).normalized()
	var sz := float(g.get("cell", _fill_cell))
	if sz <= 0.001 or u.length_squared() < 0.5 or v.length_squared() < 0.5:
		return null
	var c: Array = cell
	var wp := org + u * (float(c[0]) * sz) + v * (float(c[1]) * sz)
	var local := wp - _fill_origin
	return Vector2i(roundi(local.dot(_fill_u) / _fill_cell), roundi(local.dot(_fill_v) / _fill_cell))


## A patch dict out of painted cells: shared corners (no overlapping quads), draped on
## the geometry under it, lifted a few centimetres so nothing z-fights, and with the
## grid kept so a later stroke can extend it.
func _fill_patch(cells: Dictionary) -> Dictionary:
	var a: Vector3 = _fill_seed.get("a", _fill_origin)
	var b: Vector3 = _fill_seed.get("b", _fill_origin)
	var c: Vector3 = _fill_seed.get("c", _fill_origin)
	var ua: Vector2 = _fill_seed.get("ua", Vector2.ZERO)
	var ub: Vector2 = _fill_seed.get("ub", Vector2.ZERO)
	var uc: Vector2 = _fill_seed.get("uc", Vector2.ZERO)
	var corner := {}
	var verts: Array = []
	var uvs: Array = []
	var idx: Array = []
	for kv in cells:
		var k: Vector2i = kv
		var ids := []
		for cv in FILL_CORNERS:
			var o: Vector2i = cv
			var key := Vector2i(k.x + o.x, k.y + o.y)
			var vid := int(corner.get(key, -1))
			if vid < 0:
				vid = verts.size()
				corner[key] = vid
				var wp := _fill_origin + _fill_u * (float(key.x) * _fill_cell) \
					+ _fill_v * (float(key.y) * _fill_cell)
				var q := _fill_drape(wp)
				verts.append([_r(q.x), _r(q.y), _r(q.z)])
				var t := _bary_uv(wp, a, b, c, ua, ub, uc)
				uvs.append([_r(t.x, 0.0001), _r(t.y, 0.0001)])
			ids.append(vid)
		idx.append_array([ids[0], ids[1], ids[2], ids[0], ids[2], ids[3]])
	var out_cells: Array = []
	for kv in cells:
		var k: Vector2i = kv
		out_cells.append([k.x, k.y])
	return {
		"texture": _fill_texture, "alpha": _fill_alpha, "class": _fill_class,
		"nrm": [_r(_fill_normal.x, 0.0001), _r(_fill_normal.y, 0.0001), _r(_fill_normal.z, 0.0001)],
		"verts": verts, "uv": uvs, "idx": idx,
		"grid": {
			"org": [_r(_fill_origin.x), _r(_fill_origin.y), _r(_fill_origin.z)],
			"u": [_r(_fill_u.x, 0.0001), _r(_fill_u.y, 0.0001), _r(_fill_u.z, 0.0001)],
			"v": [_r(_fill_v.x, 0.0001), _r(_fill_v.y, 0.0001), _r(_fill_v.z, 0.0001)],
			"n": [_r(_fill_normal.x, 0.0001), _r(_fill_normal.y, 0.0001), _r(_fill_normal.z, 0.0001)],
			"cell": _r(_fill_cell, 0.0001),
		},
		"cells": out_cells,
	}


## Follows the geometry under a sheet corner (a sloped verge, a step) instead of poking
## through it; with nothing underneath the corner stays on the plane, closing the hole.
## Only geometry close to the plane counts: on a wall a long probe would reach whatever
## is behind the gap and drag the sheet off the wall.
func _fill_drape(wp: Vector3) -> Vector3:
	var hit := _raycast(wp + _fill_normal * FILL_CONFORM, -_fill_normal, FILL_CONFORM * 2.0)
	if not hit.is_empty():
		var hn := _vec_of(hit.get("normal", _fill_normal))
		if absf(hn.dot(_fill_normal)) > 0.45:
			var off: float = (Vector3(hit.pos) - wp).dot(_fill_normal)
			if absf(off) <= FILL_CONFORM:
				return Vector3(hit.pos) + _fill_normal * FILL_LIFT
	return wp + _fill_normal * FILL_LIFT


static func _vec_of(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		var arr: Array = v
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return Vector3.ZERO


## Affine UV at `p` for the plane of triangle (a, b, c) - extends outside the triangle.
static func _bary_uv(p: Vector3, a: Vector3, b: Vector3, c: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2) -> Vector2:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var den := d00 * d11 - d01 * d01
	if absf(den) < 1e-10:
		return ua
	var vv := (d11 * d20 - d01 * d21) / den
	var ww := (d00 * d21 - d01 * d20) / den
	return ua * (1.0 - vv - ww) + ub * vv + uc * ww


# --- edge fill -------------------------------------------------------------------------
## Edge fill does not guess the hole from a brush or a flood fill: the rim is picked edge
## by edge, and those very vertices become the outline of the new surface. So the patch
## is watertight with the course, its texture and UV mapping are taken from the face the
## rim belongs to, and the triangle count comes from the neighbour's own edge length.

func _line_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = ImmediateMesh.new()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	preview_root.add_child(mi)
	return mi


static func _cross2(a: Vector2, b: Vector2) -> float:
	return a.x * b.y - a.y * b.x


static func _seg2_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _edge_key(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x * 100.0), roundi(p.y * 100.0), roundi(p.z * 100.0))


static func _edge_pair_key(a: Vector3i, b: Vector3i) -> String:
	var sa := "%d,%d,%d" % [a.x, a.y, a.z]
	var sb := "%d,%d,%d" % [b.x, b.y, b.z]
	return sa + "|" + sb if sa < sb else sb + "|" + sa


static func _newell_normal(pts: Array) -> Vector3:
	var n := Vector3.ZERO
	for i in pts.size():
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % pts.size()]
		n += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x),
			(a.x - b.x) * (a.y + b.y))
	return n


static func _to_2d(p: Vector3, plane: Dictionary) -> Vector2:
	var d := p - Vector3(plane["c"])
	return Vector2(d.dot(Vector3(plane["u"])), d.dot(Vector3(plane["v"])))


static func _poly_area(poly: PackedVector2Array) -> float:
	var s := 0.0
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		s += a.x * b.y - b.x * a.y
	return s * 0.5


static func _point_in_tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := _cross2(b - a, p - a)
	var d2 := _cross2(c - b, p - b)
	var d3 := _cross2(a - c, p - c)
	return d1 >= -1e-9 and d2 >= -1e-9 and d3 >= -1e-9


## Ear clipping for a simple polygon in the fill plane. Returns index triples (CCW), or []
## for a self-intersecting or degenerate outline - better to say so than to build a mess.
static func _triangulate(poly: PackedVector2Array) -> Array:
	var n := poly.size()
	if n < 3:
		return []
	var idx: Array = []
	for i in n:
		idx.append(i)
	if _poly_area(poly) < 0.0:
		idx.reverse()
	var out: Array = []
	var guard := 0
	while idx.size() > 3 and guard < 10000:
		guard += 1
		var clipped := false
		for i in idx.size():
			var i0: int = idx[(i + idx.size() - 1) % idx.size()]
			var i1: int = idx[i]
			var i2: int = idx[(i + 1) % idx.size()]
			var a := poly[i0]
			var b := poly[i1]
			var c := poly[i2]
			if _cross2(b - a, c - a) <= 1e-9:
				continue
			var blocked := false
			for j in idx.size():
				var p: int = idx[j]
				if p == i0 or p == i1 or p == i2:
					continue
				if _point_in_tri(poly[p], a, b, c):
					blocked = true
					break
			if blocked:
				continue
			out.append(Vector3i(i0, i1, i2))
			idx.remove_at(i)
			clipped = true
			break
		if not clipped:
			return []
	if idx.size() == 3:
		out.append(Vector3i(idx[0], idx[1], idx[2]))
	return out


## Row samples along a rim, by arc length, so two rims of different length can be lofted.
static func _edge_samples(pts: Array, steps: int) -> Array:
	var out: Array = []
	var n := pts.size()
	if n == 0:
		return out
	if n == 1:
		for i in steps + 1:
			out.append(Vector3(pts[0]))
		return out
	var lens: Array = [0.0]
	var total := 0.0
	for i in range(1, n):
		total += Vector3(pts[i - 1]).distance_to(Vector3(pts[i]))
		lens.append(total)
	if total < 1e-6:
		for i in steps + 1:
			out.append(Vector3(pts[0]))
		return out
	var seg := 0
	for i in steps + 1:
		var want := total * float(i) / float(steps)
		while seg < n - 2 and float(lens[seg + 1]) < want:
			seg += 1
		var l0 := float(lens[seg])
		var l1 := float(lens[seg + 1])
		var t := clampf((want - l0) / maxf(l1 - l0, 1e-6), 0.0, 1.0)
		out.append(Vector3(pts[seg]).lerp(Vector3(pts[seg + 1]), t))
	return out


## Lofts one rim to the other (a gap between two wall pieces, a tear with both sides
## selected). The rows are sampled to the same step count and paired end to end, so the
## strip cannot twist.
static func _edge_bridge_rows(pa: Array, pb: Array, steps: int) -> Dictionary:
	var a0: Vector3 = pa[0]
	var a1: Vector3 = pa[pa.size() - 1]
	var b0: Vector3 = pb[0]
	var b1: Vector3 = pb[pb.size() - 1]
	var straight := a0.distance_to(b0) + a1.distance_to(b1)
	var crossed := a0.distance_to(b1) + a1.distance_to(b0)
	var bs: Array = pb.duplicate()
	if crossed < straight:
		bs.reverse()
	var va := _edge_samples(pa, steps)
	var vb := _edge_samples(bs, steps)
	var verts: Array = []
	verts.append_array(va)
	verts.append_array(vb)
	var row := steps + 1
	var tris: Array = []
	for i in steps:
		var a := i
		var b := i + 1
		var c := row + i + 1
		var d := row + i
		tris.append(Vector3i(a, b, c))
		tris.append(Vector3i(a, c, d))
	return {"verts": verts, "tris": tris}


## Makes every triangle face the plane's normal (the side being looked at), and drops the
## degenerate ones the outline may produce.
static func _edge_orient(verts: Array, tris: Array, plane: Dictionary) -> Array:
	var out: Array = []
	for t in tris:
		var a := _to_2d(Vector3(verts[t.x]), plane)
		var b := _to_2d(Vector3(verts[t.y]), plane)
		var c := _to_2d(Vector3(verts[t.z]), plane)
		var area := _cross2(b - a, c - a)
		if absf(area) < 1e-10:
			continue
		out.append(t if area > 0.0 else Vector3i(t.x, t.z, t.y))
	return out


static func _edge_unique(pts: Array) -> Array:
	var out: Array = []
	var seen := {}
	for p in pts:
		var key := _edge_key(Vector3(p))
		if seen.has(key):
			continue
		seen[key] = true
		out.append(Vector3(p))
	return out


func _edge_mid(verts: Array, mids: Dictionary, i: int, j: int, a: Vector3, b: Vector3) -> int:
	var key := Vector2i(mini(i, j), maxi(i, j))
	if mids.has(key):
		return int(mids[key])
	var id := verts.size()
	verts.append((a + b) * 0.5)
	mids[key] = id
	return id


## Splits triangles until their longest edge is about the size of the triangles beside the
## rim - the point of "matching the tris": the fill has the course's own density instead
## of one huge slab. Capped so a coarse neighbour cannot explode the patch.
func _edge_subdivide(verts: Array, tris: Array, target: float) -> Array:
	if target <= 0.001:
		return tris
	var out := tris
	var depth := 0
	while depth < MAX_EDGE_SUBDIV and out.size() < MAX_EDGE_TRIS:
		var next: Array = []
		var mids := {}
		var changed := false
		for t in out:
			var a: Vector3 = verts[t.x]
			var b: Vector3 = verts[t.y]
			var c: Vector3 = verts[t.z]
			var longest := maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a)))
			if longest <= target * 1.35 or next.size() + 4 > MAX_EDGE_TRIS:
				next.append(t)
				continue
			changed = true
			var m0 := _edge_mid(verts, mids, t.x, t.y, a, b)
			var m1 := _edge_mid(verts, mids, t.y, t.z, b, c)
			var m2 := _edge_mid(verts, mids, t.z, t.x, c, a)
			next.append_array([Vector3i(t.x, m0, m2), Vector3i(m0, t.y, m1),
				Vector3i(m2, m1, t.z), Vector3i(m0, m1, m2)])
		out = next
		depth += 1
		if not changed:
			break
	return out


## Boundary edges of a set of (surface, face) pairs. The bake is triangle soup with
## unshared vertices, so corners are welded by position (1 cm): an edge used by exactly
## one triangle is a rim - the outline of a hole, a tear, or the open side of a wall.
## Erased triangles make their neighbours rim edges by their absence, so a gap cut in
## this editor is selectable edge by edge.
func _rim_edges(faces: Array) -> Array:
	var edges := {}
	var order: Array = []
	for pair in faces:
		var si := int(pair[0])
		var f := int(pair[1])
		var g: Dictionary = track.surface_geo.get(si, {})
		if g.is_empty():
			continue
		var tri := _face(si, f)
		if tri.size() < 3:
			continue
		var pa: Vector3 = tri[0]
		var pb: Vector3 = tri[1]
		var pc: Vector3 = tri[2]
		var nrm := (pb - pa).cross(pc - pa).normalized()
		if nrm.length_squared() < 0.5:
			continue
		var keys: Array = [_edge_key(pa), _edge_key(pb), _edge_key(pc)]
		var pts: Array = [pa, pb, pc]
		for k in 3:
			var ka: Vector3i = keys[k]
			var kb: Vector3i = keys[(k + 1) % 3]
			var ck := _edge_pair_key(ka, kb)
			if edges.has(ck):
				edges[ck]["count"] = int(edges[ck]["count"]) + 1
				continue
			var ea: Vector3 = pts[k]
			var eb: Vector3 = pts[(k + 1) % 3]
			if ea.distance_squared_to(eb) < 0.0004:
				continue
			var e := {"a": ea, "b": eb, "ka": ka, "kb": kb, "si": si, "f": f,
				"n": nrm, "count": 1, "tex": String(g.get("texture", "")),
				"cls": String(g.get("class", "off")), "alpha": bool(g.get("alpha", false))}
			edges[ck] = e
			order.append(e)
	var rim: Array = []
	for e in order:
		if int(e["count"]) == 1:
			rim.append(e)
	return rim


func _edge_reach() -> float:
	var reach := clampf(cam_dist * 0.12, EDGE_REACH_MIN, EDGE_REACH_MAX)
	if brush_radius != null:
		reach = maxf(reach, brush_radius.value * 2.0)
	return reach


## Rim edges around one point in the world, within reach of it.
func _rims_around(centre: Vector3, reach: float) -> Array:
	var out: Array = []
	for e in _rim_edges(_brush_faces(centre, reach)):
		# Skip the false rims at the edge of the gather radius, and rims seen from behind
		# (the far side of a wall would otherwise be drawn and picked through it).
		var mid := (Vector3(e["a"]) + Vector3(e["b"])) * 0.5
		if mid.distance_to(centre) > reach:
			continue
		if (cam.global_position - mid).dot(Vector3(e["n"])) < 0.0:
			continue
		out.append(e)
	return out


## Rim edges around the cursor: around the surface the cursor is on, or around the surface
## the gap the cursor points into is cut from.
func _edge_candidates(vp: Vector2) -> Array:
	if track == null or cam == null or not vp.is_finite():
		return []
	if not _grid_built:
		_build_pick_grid()
	var reach := _edge_reach()
	var own := _pick_triangle(vp)
	var centre := Vector3.ZERO
	var have := false
	var hit := own
	if hit.is_empty():
		# Pointing into the gap itself: an erased face knows where the level used to be.
		hit = _pick_hidden(vp)
	if not hit.is_empty():
		centre = Vector3(hit.pos)
		have = true
	elif _fill_ok:
		# A gap that was never cut by this editor: fall back to the last fill level.
		var p: Variant = _fill_plane.intersects_ray(cam.project_ray_origin(vp),
			cam.project_ray_normal(vp).normalized())
		if p != null:
			centre = Vector3(p)
			have = true
	var out: Array = _rims_around(centre, reach) if have else []
	if _edge_pick_from(out, vp).is_empty():
		# The cursor is not on a rim: it is pointing into the empty middle of a gap, which
		# has no surface of its own to gather around. Take the rim of what surrounds it.
		var skip := int(own["surface"]) if not own.is_empty() else -1
		var depth := cam_dist
		if not own.is_empty():
			depth = cam.global_position.distance_to(Vector3(own["pos"]))
		out.append_array(_edge_gap_candidates(vp, skip, depth))
	return out


## Rim edges of the gap the cursor points into. A gap is empty, so there is nothing there to
## click: aiming at a hole in a bridge hits the ground below it, and aiming at a hole in a
## wall hits whatever is behind. The surface the gap is cut into is found by probing a ring
## around the cursor, and its rim near that probe is gathered like any other.
func _edge_gap_candidates(vp: Vector2, skip: int, depth: float) -> Array:
	if track == null or cam == null or not vp.is_finite():
		return []
	var probe := _edge_surrounding(vp, skip, depth)
	if probe.is_empty() and skip >= 0:
		# A gap can open onto the same surface it is cut into (a road that continues past a
		# torn-out piece), so fall back to the surface under the cursor instead of nothing.
		probe = _edge_surrounding(vp, -1, depth)
	if probe.is_empty():
		return []
	var pos := Vector3(probe["pos"])
	var o := cam.project_ray_origin(vp)
	var d := cam.project_ray_normal(vp).normalized()
	# How far the surrounding surface sits from the aim, so the gather still reaches back
	# across a gap wider than one reach.
	var off := (o + d * maxf((pos - o).dot(d), 0.0)).distance_to(pos)
	var reach := clampf(_edge_reach() + off, EDGE_REACH_MIN, EDGE_REACH_MAX * 2.0)
	return _rims_around(pos, reach)


## Nearest geometry on a ring around the cursor: the surface a gap is cut into. Whatever
## the cursor ray itself hits is skipped, because that is what lies behind the gap. The ring
## is a distance in metres (converted with the camera's own projection), not in pixels, so
## it lands just outside a gap whatever the panel size, fov or zoom.
func _edge_surrounding(vp: Vector2, skip: int, depth: float) -> Dictionary:
	var r := _edge_reach() * 0.6 * _px_per_metre(vp, depth)
	for ring in EDGE_PROBE_RINGS:
		var best: Dictionary = {}
		var best_t := INF
		for k in 8:
			var a := TAU * float(k) / 8.0
			var hit := _pick_triangle(vp + Vector2(cos(a), sin(a)) * r)
			if hit.is_empty() or int(hit["surface"]) == skip:
				continue
			var t := cam.global_position.distance_to(Vector3(hit["pos"]))
			if t < best_t:
				best_t = t
				best = hit
		if not best.is_empty():
			return best
		r *= 3.0
	return {}


## Pixels per metre at `depth` along the cursor's ray, taken from the camera itself.
func _px_per_metre(vp: Vector2, depth: float) -> float:
	var d := cam.project_ray_normal(vp).normalized()
	var p := cam.project_ray_origin(vp) + d * maxf(depth, 0.5)
	var right := d.cross(Vector3.UP)
	if right.length_squared() < 1e-8:
		right = d.cross(Vector3.RIGHT)
	right = right.normalized()
	var px := cam.unproject_position(p).distance_to(cam.unproject_position(p + right))
	return maxf(px, 0.25)


## Hover variant: re-gathering the rim costs a few milliseconds, so the last answer is
## reused while the cursor barely moves and the camera is still. Clicks always gather
## fresh; any geometry edit marks this stale.
func _edge_candidates_cached(vp: Vector2) -> Array:
	var xf := cam.global_transform if cam != null else Transform3D()
	if not _edge_hover_dirty and _edge_hover_xf.is_equal_approx(xf) \
			and vp.distance_to(_edge_hover_vp) < 3.0:
		return _edge_hover_cache
	var cands := _edge_candidates(vp)
	_edge_hover_cache = cands
	_edge_hover_vp = vp
	_edge_hover_xf = xf
	_edge_hover_dirty = false
	return cands


## The whole rim of one surface, for Shift+click (grab a hole's outline at once). Skipped
## on surfaces so big that welding every face would stall the editor.
func _surface_rim_edges(si: int) -> Array:
	var g: Dictionary = track.surface_geo.get(si, {})
	if g.is_empty():
		return []
	var idx: PackedInt32Array = g.idx
	var faces := idx.size() / 3
	if faces > MAX_PART_SURFACE:
		return []
	var pairs: Array = []
	for f in faces:
		if not _is_hidden_face(si, f):
			pairs.append([si, f])
	return _rim_edges(pairs)


## The rim edge a click at `vp` would take: the closest one on screen, or - when the cursor
## points into the gap rather than near a rim - the one its ray aims at.
func _edge_pick(vp: Vector2) -> Dictionary:
	var cands := _edge_candidates(vp)
	var best := _edge_pick_from(cands, vp)
	if not best.is_empty():
		return best
	best = _edge_pick_gaze(cands, vp)
	if not best.is_empty():
		best = best.duplicate()
		best["gap"] = true          # aimed into the gap, not at an edge: take its whole rim
	return best


## Rim edge nearest the cursor's line of sight. Pointing into a gap puts no edge close to
## the cursor on screen, so the one already closest to the ray is what is being aimed at.
func _edge_pick_gaze(cands: Array, vp: Vector2) -> Dictionary:
	if track == null or cam == null or not vp.is_finite():
		return {}
	var o := cam.project_ray_origin(vp)
	var d := cam.project_ray_normal(vp).normalized()
	var best: Dictionary = {}
	var best_d := INF          # the candidates are already gathered around the aim
	for e in cands:
		var mid := (Vector3(e["a"]) + Vector3(e["b"])) * 0.5
		if cam.is_position_behind(mid):
			continue
		if (cam.global_position - mid).dot(Vector3(e["n"])) < 0.0:
			continue
		var t := maxf((mid - o).dot(d), 0.0)
		var dd := (o + d * t).distance_to(mid)
		if dd < best_d:
			best_d = dd
			best = e
	return best


func _edge_pick_from(cands: Array, vp: Vector2) -> Dictionary:
	if track == null or cam == null or not vp.is_finite():
		return {}
	var best: Dictionary = {}
	var best_d := EDGE_PICK_PX
	for e in cands:
		var pa := _project(Vector3(e["a"]))
		var pb := _project(Vector3(e["b"]))
		if not pa.is_finite() or not pb.is_finite():
			continue
		var mid := (Vector3(e["a"]) + Vector3(e["b"])) * 0.5
		if (cam.global_position - mid).dot(Vector3(e["n"])) < 0.0:
			continue
		var d := _seg2_dist(vp, pa, pb)
		if d < best_d:
			best_d = d
			best = e
	return best


## Shift+click: follow the surface's rim from the clicked edge round the gap and select
## the whole outline, past the hover gather radius. A corner where three rims meet stops
## the walk, so a hole joined to the open edge of the piece does not run away.
func edge_grow(seed: Dictionary) -> int:
	if track == null:
		return 0
	var rim := _surface_rim_edges(int(seed.get("si", -1)))
	if rim.is_empty():
		return 0
	var start_key := _edge_pair_key(Vector3i(seed["ka"]), Vector3i(seed["kb"]))
	var adj := {}
	for i in rim.size():
		var e: Dictionary = rim[i]
		for key in [Vector3i(e["ka"]), Vector3i(e["kb"])]:
			var arr: Array = adj.get(key, [])
			arr.append(i)
			adj[key] = arr
	var start := -1
	for i in rim.size():
		var e2: Dictionary = rim[i]
		if _edge_pair_key(Vector3i(e2["ka"]), Vector3i(e2["kb"])) == start_key:
			start = i
			break
	if start < 0:
		return 0
	var used := {start: true}
	var fwd: Array = []
	_edge_walk_rim(rim, adj, Vector3i(rim[start]["kb"]), start, fwd, used)
	var back: Array = []
	_edge_walk_rim(rim, adj, Vector3i(rim[start]["ka"]), start, back, used)
	back.reverse()
	var added := 0
	for e3 in back + [rim[start]] + fwd:
		if _edge_sel_index(e3) >= 0:
			continue
		if edge_sel.size() >= MAX_EDGE_EDGES:
			break
		edge_sel.append(_edge_entry(e3))
		added += 1
	return added


func _edge_walk_rim(rim: Array, adj: Dictionary, start_key: Vector3i, first: int,
		out: Array, used: Dictionary) -> void:
	var key := start_key
	var cur := first
	while out.size() < MAX_EDGE_EDGES:
		var corners: Array = adj.get(key, [])
		if corners.size() != 2:
			return
		var next := -1
		for j in corners:
			if int(j) != cur and not used.has(int(j)):
				next = int(j)
		if next < 0:
			return
		used[next] = true
		var e: Dictionary = rim[next]
		var ka: Vector3i = e["ka"]
		var kb: Vector3i = e["kb"]
		out.append(e)
		key = kb if ka == key else ka
		cur = next


func _edge_entry(e: Dictionary) -> Dictionary:
	return {"a": e["a"], "b": e["b"], "ka": e["ka"], "kb": e["kb"],
		"si": e["si"], "f": e["f"], "n": e["n"], "tex": e["tex"],
		"cls": e["cls"], "alpha": e["alpha"]}


func _edge_sel_index(e: Dictionary) -> int:
	var ka: Vector3i = e["ka"]
	var kb: Vector3i = e["kb"]
	for i in edge_sel.size():
		var s: Dictionary = edge_sel[i]
		var sa: Vector3i = s["ka"]
		var sb: Vector3i = s["kb"]
		if (sa == ka and sb == kb) or (sa == kb and sb == ka):
			return i
	return -1


func _edge_toggle(e: Dictionary) -> void:
	var i := _edge_sel_index(e)
	if i >= 0:
		edge_sel.remove_at(i)
		status("Edge removed - %d selected." % edge_sel.size())
	else:
		if edge_sel.size() >= MAX_EDGE_EDGES:
			status("Edge fill: %d edges is the limit - fill this part, then select the rest." % MAX_EDGE_EDGES)
			return
		edge_sel.append(_edge_entry(e))
		status("Edge selected - %d so far. Fill edges (Enter) closes the rim." % edge_sel.size())
	_edge_redraw()
	_edge_rim_redraw(_edge_hover_cache)
	_edge_refresh()


func clear_edges() -> void:
	if edge_sel.is_empty():
		status("No rim edges selected.")
		return
	edge_sel.clear()
	edge_hover = {}
	_edge_redraw()
	_edge_hover_redraw()
	_edge_rim_redraw(_edge_hover_cache)
	_edge_refresh()
	status("Cleared the rim edges.")


func _edge_redraw() -> void:
	if edge_sel_mesh == null:
		return
	var im := edge_sel_mesh.mesh as ImmediateMesh
	im.clear_surfaces()
	if edge_sel.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in edge_sel:
		im.surface_set_color(Color(1.0, 0.82, 0.2, 1.0))
		im.surface_add_vertex(Vector3(e["a"]))
		im.surface_add_vertex(Vector3(e["b"]))
	im.surface_end()


func _edge_hover_redraw() -> void:
	if edge_hover_mesh == null:
		return
	var im := edge_hover_mesh.mesh as ImmediateMesh
	im.clear_surfaces()
	if edge_hover.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(Color(0.45, 1.0, 0.95, 1.0))
	im.surface_add_vertex(Vector3(edge_hover["a"]))
	im.surface_add_vertex(Vector3(edge_hover["b"]))
	im.surface_end()


## Every rim edge near the cursor, dimmed: the hole's outline is visible before anything
## is picked, and unselected edges stand out against the yellow ones.
func _edge_rim_redraw(cands: Array) -> void:
	if edge_rim_mesh == null:
		return
	var im := edge_rim_mesh.mesh as ImmediateMesh
	im.clear_surfaces()
	if cands.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in cands:
		if _edge_sel_index(e) >= 0:
			continue
		im.surface_set_color(Color(0.55, 0.95, 0.75, 0.55))
		im.surface_add_vertex(Vector3(e["a"]))
		im.surface_add_vertex(Vector3(e["b"]))
	im.surface_end()


## Shows the rim around the cursor (thin lines) and lights up the edge a click would take,
## so it is clear where the gap's outline runs and what is still unselected.
func _edge_hover_at(vp: Vector2) -> void:
	if tool != "edge":
		return
	var cands := _edge_candidates_cached(vp)
	_edge_rim_redraw(cands)
	var e := _edge_pick_from(cands, vp)
	if e.is_empty():
		e = _edge_pick_gaze(cands, vp)
		if not e.is_empty():
			e = e.duplicate()
			e["gap"] = true
	if not e.is_empty() and _edge_sel_index(e) >= 0:
		e = {}
	var changed := e.is_empty() != edge_hover.is_empty()
	if not e.is_empty() and not changed:
		changed = edge_hover.get("ka") != e.get("ka") or edge_hover.get("kb") != e.get("kb")
	if changed:
		edge_hover = e
		_edge_hover_redraw()
	preview_holder.mouse_default_cursor_shape = \
		Control.CURSOR_POINTING_HAND if not e.is_empty() else Control.CURSOR_ARROW


## Selected rim edges grouped into chains by welded corner: a closed chain is one outline,
## two open chains are the two sides of a gap.
func _edge_chains() -> Array:
	var adj := {}
	for i in edge_sel.size():
		var e: Dictionary = edge_sel[i]
		for key in [Vector3i(e["ka"]), Vector3i(e["kb"])]:
			var arr: Array = adj.get(key, [])
			arr.append(i)
			adj[key] = arr
	for key in adj:
		if (adj[key] as Array).size() > 2:
			return []      # three selected edges at one corner: ambiguous
	var used := {}
	var chains: Array = []
	for key in adj:
		if (adj[key] as Array).size() != 1:
			continue
		var i := int((adj[key] as Array)[0])
		if not used.has(i):
			chains.append(_edge_walk(i, key, adj, used))
	for i in edge_sel.size():
		if not used.has(i):
			chains.append(_edge_walk(i, null, adj, used))
	return chains


func _edge_walk(start: int, from_key: Variant, adj: Dictionary, used: Dictionary) -> Dictionary:
	var e: Dictionary = edge_sel[start]
	var ka: Vector3i = e["ka"]
	var kb: Vector3i = e["kb"]
	var a: Vector3 = e["a"]
	var b: Vector3 = e["b"]
	if from_key != null and from_key == kb:
		var tp := a
		a = b
		b = tp
		var tk := ka
		ka = kb
		kb = tk
	var pts: Array = [a, b]
	var keys: Array = [ka, kb]
	used[start] = true
	var end_key := kb
	while true:
		var next := -1
		for j in (adj.get(end_key, []) as Array):
			if not used.has(j):
				next = int(j)
				break
		if next < 0:
			break
		var ne: Dictionary = edge_sel[next]
		var na: Vector3i = ne["ka"]
		var nb: Vector3i = ne["kb"]
		if na == end_key:
			pts.append(Vector3(ne["b"]))
			end_key = nb
		else:
			pts.append(Vector3(ne["a"]))
			end_key = na
		keys.append(end_key)
		used[next] = true
	var closed: bool = pts.size() > 2 and keys[0] == keys[keys.size() - 1]
	if closed:
		pts.remove_at(pts.size() - 1)
		keys.remove_at(keys.size() - 1)
	return {"pts": pts, "keys": keys, "closed": closed}


## Texture, class and the face the UVs come from: the majority among the selected rim
## edges, so mixing two surfaces still picks the one most of the rim belongs to.
func _edge_reference() -> Dictionary:
	if track == null or track.data.is_empty():
		return {}
	var counts := {}
	var best := ""
	for e in edge_sel:
		var k := String(e["tex"]) + "\n" + String(e["cls"])
		counts[k] = int(counts.get(k, 0)) + 1
		if best == "" or int(counts[k]) > int(counts[best]):
			best = k
	var ref: Dictionary = {}
	for e in edge_sel:
		if String(e["tex"]) + "\n" + String(e["cls"]) == best:
			ref = e
			break
	if ref.is_empty():
		return {}
	var tex := String(ref["tex"])
	if tex.begins_with("conn"):
		# Connector surfaces use a blend shader; a patch takes the far texture.
		var conns: Dictionary = track.data.get("connectors", {})
		tex = String((conns.get(tex, {}) as Dictionary).get("b", ""))
	if patch_pick != null and patch_pick.selected >= 0:
		var chosen := String(patch_pick.get_item_metadata(patch_pick.selected))
		if chosen != "":
			tex = chosen
	var cls := String(ref["cls"])
	if cls != "road" and cls != "wall":
		cls = "off"
	return {"si": int(ref["si"]), "f": int(ref["f"]), "tex": tex,
		"cls": cls, "alpha": bool(ref["alpha"])}


## Average edge length of the triangles the rim belongs to - the density to match.
func _edge_mesh_scale() -> float:
	var seen := {}
	var total := 0.0
	var n := 0
	for e in edge_sel:
		var key := Vector2i(int(e["si"]), int(e["f"]))
		if seen.has(key):
			continue
		seen[key] = true
		var tri := _face(int(e["si"]), int(e["f"]))
		if tri.size() < 3:
			continue
		for k in 3:
			total += Vector3(tri[k]).distance_to(Vector3(tri[(k + 1) % 3]))
			n += 1
	return total / float(n) if n > 0 else 0.0


## Plane of the selected rim. Newell's normal follows the outline, so a hole on a slope
## gets the rim's plane rather than the one triangle the cursor happened to be over. A
## bridge between two rims has no outline: its plane is the one through both of them
## (which also works when the rims face each other across a slot and their normals
## cancel), falling back to the faces' own normals.
func _edge_plane(rim: Array, mode: String, chains: Array = []) -> Dictionary:
	if rim.is_empty():
		return {}
	var c := Vector3.ZERO
	for p in rim:
		c += Vector3(p)
	c /= float(rim.size())
	var n := Vector3.ZERO
	if mode == "loop" or chains.size() < 2:
		n = _newell_normal(rim)
	else:
		var pa: Array = chains[0]["pts"]
		var pb: Array = chains[1]["pts"]
		n = (Vector3(pa[pa.size() - 1]) - Vector3(pa[0])).cross(Vector3(pb[0]) - Vector3(pa[0]))
		if n.length_squared() < 1e-6:
			for e in edge_sel:
				n += Vector3(e["n"])
	if n.length_squared() < 1e-8:
		return {}
	n = n.normalized()
	if cam != null and (cam.global_position - c).dot(n) < 0.0:
		n = -n
	var u := Vector3(rim[0]) - c
	u = u - n * u.dot(n)
	if u.length_squared() < 1e-6:
		u = Vector3.RIGHT - n * n.x
	if u.length_squared() < 1e-6:
		u = Vector3.BACK - n * n.z
	u = u.normalized()
	return {"c": c, "n": n, "u": u, "v": n.cross(u)}


func _edge_uv_ref(ref: Dictionary) -> Dictionary:
	var si := int(ref.get("si", -1))
	var f := int(ref.get("f", -1))
	var tri := _face(si, f)
	var uvs := _tri_uv(si, f)
	if tri.size() < 3 or uvs.size() < 3:
		return {}
	var valid := Vector2(uvs[0]).distance_squared_to(Vector2(uvs[1])) > 1e-8 \
		or Vector2(uvs[0]).distance_squared_to(Vector2(uvs[2])) > 1e-8
	return {"a": tri[0], "b": tri[1], "c": tri[2], "uv": uvs, "valid": valid}


## UV for a fill vertex, continued from the rim's own triangle, so texels line up with the
## course instead of restarting at the fill.
func _edge_uv(p: Vector3, ref: Dictionary, plane: Dictionary) -> Array:
	if not ref.is_empty() and bool(ref.get("valid", false)):
		var uvs: Array = ref["uv"]
		var t := _bary_uv(p, Vector3(ref["a"]), Vector3(ref["b"]), Vector3(ref["c"]),
			Vector2(uvs[0]), Vector2(uvs[1]), Vector2(uvs[2]))
		return [_r(t.x, 0.0001), _r(t.y, 0.0001)]
	# A surface with no real UV (flat colour): a half-metre grid keeps it sane.
	return [_r(p.dot(Vector3(plane["u"])) * 2.0, 0.0001),
		_r(p.dot(Vector3(plane["v"])) * 2.0, 0.0001)]


func _edge_patch(sol: Dictionary) -> Dictionary:
	var plane: Dictionary = sol["plane"]
	var ref: Dictionary = sol["ref"]
	var verts: Array = sol["verts"]
	var out_verts: Array = []
	var uvs: Array = []
	for p in verts:
		var q: Vector3 = p
		out_verts.append([_r(q.x), _r(q.y), _r(q.z)])
		uvs.append(_edge_uv(q, ref, plane))
	var idx: Array = []
	for t in (sol["tris"] as Array):
		idx.append_array([t.x, t.y, t.z])
	var n: Vector3 = plane["n"]
	return {
		"texture": String(sol["tex"]), "alpha": bool(sol["alpha"]), "class": String(sol["cls"]),
		"nrm": [_r(n.x, 0.0001), _r(n.y, 0.0001), _r(n.z, 0.0001)],
		"verts": out_verts, "uv": uvs, "idx": idx,
	}


## What Fill edges would build, without changing anything: chains, plane, texture from the
## rim's surface, the triangles after density matching, and the area. Drives the live
## label, and the fill itself uses the same answer so both always agree.
func edge_solve() -> Dictionary:
	if track == null:
		return {"ok": false, "msg": "no map loaded"}
	if edge_sel.size() < 2:
		return {"ok": false, "msg": "click at least two rim edges"}
	var chains := _edge_chains()
	if chains.is_empty():
		return {"ok": false, "msg": "these edges meet three at a corner - pick a clean rim"}
	var open := 0
	for c in chains:
		if not bool(c["closed"]):
			open += 1
	var mode := "loop"
	var note := ""
	if chains.size() == 1 and bool(chains[0]["closed"]):
		mode = "loop"
	elif chains.size() == 1:
		mode = "loop"
		note = "an open rim, closed with a straight edge"
	elif chains.size() == 2 and open == 2:
		mode = "bridge"
		note = "two rims bridged"
	else:
		return {"ok": false, "msg": "%d separate rims - fill one gap at a time" % chains.size()}
	var rim: Array = []
	for c in chains:
		rim.append_array(c["pts"])
	var ref := _edge_reference()
	if ref.is_empty():
		return {"ok": false, "msg": "could not read the surface under these edges"}
	var plane := _edge_plane(rim, mode, chains)
	if plane.is_empty():
		return {"ok": false, "msg": "these edges do not lie on one plane"}
	var verts: Array = []
	var tris: Array = []
	if mode == "loop":
		var outline := _edge_unique(rim)
		if outline.size() < 3:
			return {"ok": false, "msg": "two edges cannot enclose an area - select the whole rim"}
		var poly := PackedVector2Array()
		for p in outline:
			poly.append(_to_2d(Vector3(p), plane))
		if absf(_poly_area(poly)) < 1e-4:
			return {"ok": false, "msg": "that rim encloses no area"}
		tris = _triangulate(poly)
		if tris.is_empty():
			return {"ok": false, "msg": "that rim crosses itself - select one clean loop"}
		verts = outline.duplicate()
	else:
		var steps := mini(64, maxi(maxi((chains[0]["pts"] as Array).size(),
			(chains[1]["pts"] as Array).size()) - 1, 1))
		var rows := _edge_bridge_rows(chains[0]["pts"], chains[1]["pts"], steps)
		verts = rows["verts"]
		tris = rows["tris"]
	tris = _edge_orient(verts, tris, plane)
	if tris.is_empty():
		return {"ok": false, "msg": "the fill came out degenerate - select the rim again"}
	var target := 0.0
	if edge_density != null and edge_density.button_pressed:
		target = clampf(_edge_mesh_scale(), 0.05, 20.0)
		tris = _edge_subdivide(verts, tris, target)
	var area := 0.0
	for t in tris:
		var a: Vector3 = verts[t.x]
		var b: Vector3 = verts[t.y]
		var c: Vector3 = verts[t.z]
		area += (b - a).cross(c - a).length() * 0.5
	return {"ok": true, "msg": "", "mode": mode, "note": note, "chains": chains,
		"edges": edge_sel.size(), "verts": verts, "tris": tris, "area": area,
		"tex": String(ref["tex"]), "cls": String(ref["cls"]), "alpha": bool(ref["alpha"]),
		"ref": _edge_uv_ref(ref), "plane": plane, "target": target}


## Fill edges: closes the selected rim with real triangles. Unlike the brush this does not
## sample a grid - the rim's own vertices become the patch outline, so the sheet meets the
## course exactly. Texture, class and UVs continue the surface the rim belongs to, and the
## triangles are split to that surface's density.
func fill_edges() -> void:
	if track == null:
		return
	var sol := edge_solve()
	if not bool(sol.get("ok", false)):
		status("Edge fill: %s." % String(sol.get("msg", "nothing to fill")))
		_edge_refresh()
		return
	var patch := _edge_patch(sol)
	var patches: Array = []
	var existing: Variant = decor.get("patches", [])
	if existing is Array:
		patches = existing
	patches.append(patch)
	decor["patches"] = patches
	var edge_count := edge_sel.size()
	var rim_count := (sol["chains"] as Array).size()
	var tris: Array = sol["tris"]
	var area := float(sol["area"])
	edge_sel.clear()
	edge_hover = {}
	_edge_hover_dirty = true
	_edge_redraw()
	_edge_rim_redraw([])
	track.apply_decor(decor)
	_refresh_surface_list()
	_refresh_selection_ui()
	_update_gizmo()
	_commit()
	_edge_refresh()
	var tex := String(sol["tex"])
	var msg := "Edge fill: %d edge(s) in %d rim(s) -> %d triangles over %.1f m2 of %s" % [
		edge_count, rim_count, tris.size(), area,
		tex.get_basename().replace(".png", "") if tex != "" else "a flat colour"]
	if float(sol["target"]) > 0.0:
		msg += " (tri size matched to %.2f m)" % float(sol["target"])
	if String(sol["note"]) != "":
		msg += "; " + String(sol["note"])
	status(msg + ".")


## Live plan under the panel controls, so the texture and triangle count are known before
## anything is committed.
func _edge_refresh() -> void:
	if edge_fill_btn != null:
		edge_fill_btn.disabled = edge_sel.size() < 2
	if edge_label == null:
		return
	if edge_sel.is_empty():
		edge_label.text = "Edges: click the rim edge of a gap, Shift+click for the whole rim, then Fill edges (Enter)."
		return
	var sol := edge_solve()
	if not bool(sol.get("ok", false)):
		edge_label.text = "%d edge(s): %s." % [edge_sel.size(), String(sol.get("msg", ""))]
		return
	var tex := String(sol["tex"])
	edge_label.text = "%d edge(s) -> %d rim(s), %d tri(s), %.1f m2, %s%s" % [edge_sel.size(),
		(sol["chains"] as Array).size(), (sol["tris"] as Array).size(), float(sol["area"]),
		tex.get_basename().replace(".png", "") if tex != "" else "flat colour",
		("; " + String(sol["note"])) if String(sol["note"]) != "" else ""]


func _refresh_patch_textures() -> void:
	if patch_pick == null:
		return
	var keep := ""
	if patch_pick.selected >= 0:
		keep = String(patch_pick.get_item_metadata(patch_pick.selected))
	patch_pick.clear()
	patch_pick.add_item("Same as surface")
	patch_pick.set_item_metadata(0, "")
	if track != null and not track.data.is_empty():
		var seen := {}
		for s in track.data.surfaces:
			var t := String(s.get("texture", ""))
			if t == "" or t.begins_with("conn") or seen.has(t):
				continue
			seen[t] = true
			patch_pick.add_item(t.get_basename().replace(".png", ""))
			patch_pick.set_item_metadata(patch_pick.item_count - 1, t)
	for i in patch_pick.item_count:
		if String(patch_pick.get_item_metadata(i)) == keep:
			patch_pick.select(i)
			break


func remove_patches() -> void:
	if _patch_count() == 0:
		status("No fill patches to remove.")
		return
	decor["patches"] = []
	_apply_decor()
	_commit()
	status("Removed every fill patch.")


func _show_brush(centre: Vector3, normal: Vector3) -> void:
	if brush_marker == null:
		return
	var r := maxf(brush_radius.value, 0.2)
	var up := normal.normalized()
	if up.length_squared() < 0.5:
		up = Vector3.UP
	var ref := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.BACK
	var x := ref.cross(up).normalized()
	var z := x.cross(up).normalized()
	brush_marker.global_transform = Transform3D(Basis(x, up, z).scaled(Vector3.ONE * r), centre + up * 0.06)
	brush_marker.visible = true


func _hide_brush() -> void:
	if brush_marker != null:
		brush_marker.visible = false


func _on_brush_radius_changed(_v: float) -> void:
	if preview_holder != null and preview_holder.get_global_rect().has_point(get_global_mouse_position()):
		_update_brush_hover(_last_view_pos())


func _last_view_pos() -> Vector2:
	if preview_holder == null:
		return Vector2.ZERO
	return _view_pos(preview_holder.get_local_mouse_position())


## Brush cursor while hovering with Erase / Restore / Fill.
func _update_brush_hover(vp: Vector2) -> void:
	if tool != "erase" and tool != "restore" and tool != "fill":
		_hide_brush()
		return
	if track == null or cam == null:
		_hide_brush()
		return
	var hit := _pick_triangle(vp)
	if not hit.is_empty():
		_show_brush(hit.pos, hit.normal)
		return
	# Over empty space a fill still has a level to paint on, so keep the ring there.
	if tool == "fill" and _fill_ok:
		var p: Variant = _fill_plane.intersects_ray(cam.project_ray_origin(vp),
			cam.project_ray_normal(vp).normalized())
		if p != null:
			_show_brush(Vector3(p), _fill_normal)
			return
	_hide_brush()


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
		KEY_4:
			_set_tool("part")
			accept_event()
		KEY_5:
			_set_tool("fill")
			accept_event()
		KEY_6:
			_set_tool("restore")
			accept_event()
		KEY_7:
			_set_tool("hole")
			accept_event()
		KEY_8:
			_set_tool("edge")
			accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			if tool == "edge":
				fill_edges()
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
