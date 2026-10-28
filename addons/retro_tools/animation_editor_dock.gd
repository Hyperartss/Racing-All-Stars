@tool
extends HSplitContainer
## Animation Editor dock: simple keyframe animation for each character's vertex rig.
##
## Pick a character, pick (or create) a clip, then click on the timeline and pose a
## part - either with the number fields or directly in the 3D preview. Clicking a part
## (or a pivot dot) shows a Blender-style gizmo: drag a coloured ring to rotate about
## that axis, or an arrow to move along it. R / G switch tools, X / Y / Z lock an axis,
## middle-drag orbits, Shift+middle pans, wheel zooms. With Auto-key on (the default)
## every change is stored at the playhead, like a stop-motion editor. Every clip change
## is undoable (Ctrl+Z / Ctrl+Shift+Z).
##
## Clips are saved into content/characters/<id>.json ("animations"), which the game
## reads through RigAnim:
##   runner      idle, run, jump, hit
##   kart driver drive (or idle), hit
## A clip replaces that state's code pose; characters without clips are unchanged.

const CHARS := "res://content/characters/"
const RUNNER_CLIPS := ["idle", "run", "jump", "hit"]
const KART_CLIPS := ["drive", "idle", "hit"]
const DEFAULT_FPS := 24

# --- data -------------------------------------------------------------------------
var char_id := ""
var char_def := {}
var clips := {}
var clip_name := ""
var pose := {}
var time := 0.0
var playing := false
var selected_part := ""
var _dirty := false
var _syncing := false
var _pending_char := ""

# --- undo -------------------------------------------------------------------------
const UNDO_LIMIT := 80
var undo_stack: Array[String] = []
var redo_stack: Array[String] = []
var _committed := "{}"          ## clips as of the last committed edit
var _last_commit_tag := ""
var _last_commit_ms := 0
var undo_btn: Button
var redo_btn: Button

# --- 3D preview -------------------------------------------------------------------
var rig: VertexRig
var preview_root: Node3D
var cam: Camera3D
var cam_yaw := PI
var cam_pitch := 0.16
var cam_dist := 3.0
var focus := Vector3(0, 0.55, 0)
var _drag := 0                 ## 0 none, 1 orbit, 2 pose, 3 gizmo, 4 pan
var _drag_move := false
var _drag_travel := 0.0         ## pixels moved since the press (pose drag dead zone)
var _hover_handle := -1
var handle_root: Node3D
var handles: Array[MeshInstance3D] = []
var handle_mesh: SphereMesh
var handle_mat: StandardMaterial3D
var handle_sel_mat: StandardMaterial3D
var handle_hover_mat: StandardMaterial3D

# Gizmo: one ring (rotate) and one arrow (move) per axis.
var gizmo_root: Node3D
var gizmo_axes: Array[Node3D] = []
var gizmo_rings: Array[MeshInstance3D] = []
var gizmo_arrows: Array[Node3D] = []
var gizmo_mats: Array[StandardMaterial3D] = []
var gizmo_move := false         ## arrows instead of rings
var gizmo_hover := -1
var gizmo_drag := -1
var axis_lock := -1             ## -1 free, 0 X, 1 Y, 2 Z
var axis_btns: Array[Button] = []
var _g_dir2 := Vector2.RIGHT    ## screen direction of a positive drag
var _g_px_per_rad := 40.0
var _g_px_per_unit := 100.0
var _g_start_rot := Vector3.ZERO
var _g_start_off := Vector3.ZERO
var _g_acc := 0.0               ## pixels dragged along _g_dir2 (accumulated)

# --- widgets ----------------------------------------------------------------------
var preview_holder: SubViewportContainer
var viewport: SubViewport
var char_pick: OptionButton
var info_label: Label
var clip_pick: OptionButton
var standard_pick: OptionButton
var name_edit: LineEdit
var length_spin: SpinBox
var loop_check: CheckBox
var fps_spin: SpinBox
var part_list: ItemList
var rot_spins: Array[SpinBox] = []
var off_spins: Array[SpinBox] = []
var auto_key: CheckBox
var play_btn: Button
var rotate_btn: Button
var move_btn: Button
var time_label: Label
var timeline
var save_btn: Button
var status_label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(0, 340)

	# --- left: character, clips, parts, pose -------------------------------------
	var left_scroll := ScrollContainer.new()
	left_scroll.custom_minimum_size = Vector2(330, 0)
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(left_scroll)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(left)

	var row := HBoxContainer.new()
	left.add_child(row)
	_label(row, "Character")
	char_pick = OptionButton.new()
	char_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	char_pick.tooltip_text = "Every character in content/characters"
	char_pick.item_selected.connect(_on_char_picked)
	row.add_child(char_pick)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.tooltip_text = "Rescan content/characters (after importing a character)"
	refresh.pressed.connect(_refresh_characters)
	row.add_child(refresh)

	info_label = _muted(left, "")

	row = HBoxContainer.new()
	left.add_child(row)
	_label(row, "Clip")
	clip_pick = OptionButton.new()
	clip_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip_pick.tooltip_text = "Runner clips: idle, run, jump, hit\nKart driver clips: drive (or idle), hit"
	clip_pick.item_selected.connect(_on_clip_picked)
	row.add_child(clip_pick)
	var new_btn := Button.new()
	new_btn.text = "New"
	new_btn.tooltip_text = "Add the next free state clip (idle, run, jump, hit / drive)"
	new_btn.pressed.connect(new_clip)
	row.add_child(new_btn)

	row = HBoxContainer.new()
	left.add_child(row)
	name_edit = LineEdit.new()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.placeholder_text = "clip name"
	row.add_child(name_edit)
	var rename_btn := Button.new()
	rename_btn.text = "Rename"
	rename_btn.pressed.connect(rename_clip)
	row.add_child(rename_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.pressed.connect(delete_clip)
	row.add_child(del_btn)

	row = HBoxContainer.new()
	left.add_child(row)
	_label(row, "Standard")
	standard_pick = OptionButton.new()
	standard_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	standard_pick.tooltip_text = "Built-in animation to load into the clip with that name"
	row.add_child(standard_pick)
	var import_btn := Button.new()
	import_btn.text = "Import"
	import_btn.tooltip_text = "Bake the built-in animation into its clip, replacing that clip's keys"
	import_btn.pressed.connect(import_standard)
	row.add_child(import_btn)

	var g := GridContainer.new()
	g.columns = 2
	left.add_child(g)
	_label(g, "Length (s)")
	length_spin = SpinBox.new()
	length_spin.min_value = 0.05
	length_spin.max_value = 20.0
	length_spin.step = 0.05
	length_spin.value = 1.0
	length_spin.value_changed.connect(_on_length_changed)
	g.add_child(length_spin)
	_label(g, "Loop")
	loop_check = CheckBox.new()
	loop_check.button_pressed = true
	loop_check.toggled.connect(_on_loop_toggled)
	g.add_child(loop_check)
	_label(g, "FPS")
	fps_spin = SpinBox.new()
	fps_spin.min_value = 1
	fps_spin.max_value = 60
	fps_spin.step = 1
	fps_spin.value = DEFAULT_FPS
	fps_spin.tooltip_text = "Timeline frame snapping (playback uses real seconds)"
	fps_spin.value_changed.connect(_on_fps_changed)
	g.add_child(fps_spin)

	_label(left, "Parts - click one, then pose it")
	part_list = ItemList.new()
	part_list.custom_minimum_size = Vector2(0, 110)
	part_list.item_selected.connect(_on_part_selected)
	left.add_child(part_list)

	var pg := GridContainer.new()
	pg.columns = 3
	pg.add_theme_constant_override("h_separation", 6)
	left.add_child(pg)
	_label(pg, "Axis")
	_label(pg, "Rotate (deg)")
	_label(pg, "Move (m)")
	for axis in ["X", "Y", "Z"]:
		_label(pg, axis)
		var r := SpinBox.new()
		r.min_value = -180.0
		r.max_value = 180.0
		r.step = 1.0
		r.suffix = "\u00b0"
		r.custom_minimum_size.x = 78
		r.value_changed.connect(func(_v: float) -> void: _pose_changed())
		pg.add_child(r)
		rot_spins.append(r)
		var o := SpinBox.new()
		o.min_value = -1.0
		o.max_value = 1.0
		o.step = 0.01
		o.custom_minimum_size.x = 78
		o.value_changed.connect(func(_v: float) -> void: _pose_changed())
		pg.add_child(o)
		off_spins.append(o)

	row = HBoxContainer.new()
	left.add_child(row)
	var reset_part := Button.new()
	reset_part.text = "Reset part"
	reset_part.pressed.connect(_reset_part)
	row.add_child(reset_part)
	var reset_all := Button.new()
	reset_all.text = "Reset all"
	reset_all.pressed.connect(_reset_all)
	row.add_child(reset_all)

	row = HBoxContainer.new()
	left.add_child(row)
	save_btn = Button.new()
	save_btn.text = "Save"
	save_btn.tooltip_text = "Write the clips into content/characters/<id>.json (Ctrl+S)"
	save_btn.pressed.connect(save)
	row.add_child(save_btn)
	undo_btn = Button.new()
	undo_btn.text = "Undo"
	undo_btn.tooltip_text = "Undo the last clip change (Ctrl+Z)"
	undo_btn.pressed.connect(_undo)
	row.add_child(undo_btn)
	redo_btn = Button.new()
	redo_btn.text = "Redo"
	redo_btn.tooltip_text = "Redo (Ctrl+Shift+Z)"
	redo_btn.pressed.connect(_redo)
	row.add_child(redo_btn)
	_update_undo_buttons()

	_muted(left, "1. Pick a clip (or New).  2. Click the timeline to choose a time.  3. Select a part and pose it.  Auto-key stores every change at the playhead.")

	# --- right: preview + playback ------------------------------------------------
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(right)

	_muted(right, "Click a part or a pivot dot (hover highlights what will be picked), then drag a gizmo ring to rotate or an arrow to move. [ / ] cycle parts, Alt-click selects through the gizmo. R / G pick the tool, X / Y / Z lock an axis, Esc frees it. Middle-drag orbits, Shift+middle pans, wheel zooms, double-click or F frames. Ctrl+Z undoes.")
	var tools := HBoxContainer.new()
	right.add_child(tools)
	var group := ButtonGroup.new()
	rotate_btn = Button.new()
	rotate_btn.text = "Rotate (R)"
	rotate_btn.toggle_mode = true
	rotate_btn.button_group = group
	rotate_btn.button_pressed = true
	rotate_btn.tooltip_text = "Drag a gizmo ring to rotate about that axis; drag the part for free rotation (Shift rolls)"
	rotate_btn.toggled.connect(_on_tool_toggled.bind(false))
	tools.add_child(rotate_btn)
	move_btn = Button.new()
	move_btn.text = "Move (G)"
	move_btn.toggle_mode = true
	move_btn.button_group = group
	move_btn.tooltip_text = "Drag a gizmo arrow to slide along that axis; drag the part to slide in the view plane"
	move_btn.toggled.connect(_on_tool_toggled.bind(true))
	tools.add_child(move_btn)
	tools.add_child(VSeparator.new())
	_label(tools, "Axis")
	var axis_group := ButtonGroup.new()
	axis_group.allow_unpress = true
	for ai in 3:
		var ab := Button.new()
		ab.text = ["X", "Y", "Z"][ai]
		ab.toggle_mode = true
		ab.button_group = axis_group
		ab.custom_minimum_size.x = 30
		ab.tooltip_text = "Constrain dragging to %s (Esc clears)" % ["X", "Y", "Z"][ai]
		ab.toggled.connect(_on_axis_button.bind(ai))
		tools.add_child(ab)
		axis_btns.append(ab)
	var help_btn := Button.new()
	help_btn.text = "?"
	help_btn.tooltip_text = "Shortcuts"
	help_btn.pressed.connect(_show_help)
	tools.add_child(help_btn)

	_build_preview(right)

	var prow := HBoxContainer.new()
	right.add_child(prow)
	play_btn = Button.new()
	play_btn.text = "Play"
	play_btn.toggle_mode = true
	play_btn.toggled.connect(func(on: bool) -> void: _set_play(on))
	prow.add_child(play_btn)
	var stop_btn := Button.new()
	stop_btn.text = "Stop"
	stop_btn.pressed.connect(_stop)
	prow.add_child(stop_btn)
	time_label = Label.new()
	time_label.text = "0.00 / 1.00 s"
	time_label.custom_minimum_size = Vector2(110, 0)
	prow.add_child(time_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prow.add_child(spacer)
	auto_key = CheckBox.new()
	auto_key.text = "Auto-key"
	auto_key.button_pressed = true
	auto_key.tooltip_text = "Store every pose change at the playhead."
	prow.add_child(auto_key)
	var key_btn := Button.new()
	key_btn.text = "Key pose"
	key_btn.tooltip_text = "Store the whole current pose at the playhead"
	key_btn.pressed.connect(key_pose)
	prow.add_child(key_btn)
	var del_key_btn := Button.new()
	del_key_btn.text = "Del key"
	del_key_btn.tooltip_text = "Delete the key nearest the playhead (or right-click a key)"
	del_key_btn.pressed.connect(func() -> void: delete_key_near(time))
	prow.add_child(del_key_btn)

	timeline = preload("res://addons/retro_tools/anim_timeline.gd").new()
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.seek.connect(_on_timeline_seek)
	timeline.key_delete.connect(delete_key_near)
	right.add_child(timeline)

	status_label = _muted(right, "Pick a character to start.")

	_refresh_characters()


func _process(delta: float) -> void:
	if not playing or clip_name == "" or not is_visible_in_tree():
		return
	var c: Dictionary = clips.get(clip_name, {})
	var clip_len := maxf(float(c.get("length", 1.0)), 0.01)
	var t := time + delta
	if t >= clip_len:
		if bool(c.get("loop", true)):
			t = fposmod(t, clip_len)
		else:
			t = clip_len
			_set_play(false)
	_set_time(t)


# --- helpers ----------------------------------------------------------------------

func _label(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	parent.add_child(l)
	return l


func _muted(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", Color(0.62, 0.65, 0.72))
	parent.add_child(l)
	return l


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _vec(v: Variant) -> Vector3:
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	if v is Vector3:
		return v
	return Vector3.ZERO


func status(text: String) -> void:
	status_label.text = text


func _set_dirty(d: bool) -> void:
	_dirty = d
	save_btn.text = "Save *" if d else "Save"


# --- characters -------------------------------------------------------------------

func _refresh_characters() -> void:
	_syncing = true
	char_pick.clear()
	var d := DirAccess.open(CHARS)
	if d == null:
		_syncing = false
		status("Cannot open " + CHARS)
		return
	var files := Array(d.get_files())
	files.sort()
	for f in files:
		if not String(f).ends_with(".json"):
			continue
		var def := _read_json(CHARS + f)
		var id := String(def.get("id", String(f).get_basename()))
		char_pick.add_item("%s  (%s)" % [def.get("name", id), def.get("type", "runner")])
		char_pick.set_item_metadata(char_pick.item_count - 1, id)
	_syncing = false
	for i in char_pick.item_count:
		if String(char_pick.get_item_metadata(i)) == char_id:
			char_pick.select(i)
			return
	if char_pick.item_count > 0:
		char_pick.select(0)
		load_character(String(char_pick.get_item_metadata(0)))


func _on_char_picked(i: int) -> void:
	if _syncing:
		return
	var id := String(char_pick.get_item_metadata(i))
	if id == char_id:
		return
	if _dirty:
		_pending_char = id
		_confirm("Discard unsaved changes to %s and open %s?" % [char_id, id],
			_do_pending_char, _cancel_char_pick)
		return
	load_character(id)


func _do_pending_char() -> void:
	var next := _pending_char
	_pending_char = ""
	load_character(next)


func _cancel_char_pick() -> void:
	_pending_char = ""
	_syncing = true
	for i in char_pick.item_count:
		if String(char_pick.get_item_metadata(i)) == char_id:
			char_pick.select(i)
			break
	_syncing = false


func load_character(id: String) -> void:
	char_id = id
	char_def = _read_json(CHARS + id + ".json")
	var anims: Variant = char_def.get("animations", {})
	clips = anims.duplicate(true) if anims is Dictionary else {}
	clip_name = ""
	time = 0.0
	_set_play(false)
	if rig != null:
		rig.queue_free()
		rig = null
	_clear_gizmo()
	var rig_path := String(char_def.get("rig", ""))
	if rig_path != "" and ResourceLoader.exists(rig_path):
		rig = VertexRig.new()
		rig.name = "PreviewRig"
		preview_root.add_child(rig)
		rig.load_rig(rig_path)
		info_label.text = "%s  -  %d parts  -  %s" % [rig_path.get_file(), rig.part_names.size(),
			char_def.get("type", "runner")]
		_frame_camera()
	else:
		info_label.text = "No rig found: " + rig_path
		status("This character has no rig.")
	_refresh_parts()
	_build_gizmo()
	_refresh_standard_list()
	_refresh_clip_list()
	_set_dirty(false)
	_reset_undo()
	if clip_name == "":
		status("No clips for %s yet - press New to add one." % id)


# --- clips ------------------------------------------------------------------------

func _refresh_clip_list() -> void:
	clip_pick.clear()
	var names := clips.keys()
	names.sort()
	for n in names:
		clip_pick.add_item(String(n))
	if not clips.has(clip_name):
		clip_name = String(names[0]) if names.size() > 0 else ""
	if clip_name != "":
		clip_pick.select(names.find(clip_name))
		_load_clip()
	else:
		name_edit.text = ""
		_set_play(false)
		timeline.length = 1.0
		timeline.time = 0.0
		timeline.keys = []
		timeline.queue_redraw()
		time = 0.0
		pose = _full_pose({})
		_apply_live_pose()
		_sync_pose_controls()
		time_label.text = "0.00 / 1.00 s"


func _on_clip_picked(i: int) -> void:
	if _syncing:
		return
	var n := clip_pick.get_item_text(i)
	if n == clip_name:
		return
	clip_name = n
	_load_clip()


func _load_clip() -> void:
	var c: Dictionary = clips.get(clip_name, {})
	for i in standard_pick.item_count:
		if standard_pick.get_item_text(i) == clip_name:
			standard_pick.select(i)
			break
	_syncing = true
	length_spin.value = float(c.get("length", 1.0))
	loop_check.button_pressed = bool(c.get("loop", true))
	fps_spin.value = float(c.get("fps", DEFAULT_FPS))
	name_edit.text = clip_name
	_syncing = false
	timeline.length = maxf(float(c.get("length", 1.0)), 0.05)
	timeline.fps = maxf(float(c.get("fps", DEFAULT_FPS)), 1.0)
	_refresh_timeline_keys()
	_set_play(false)
	_set_time(0.0)


func new_clip() -> void:
	if char_def.is_empty():
		return
	var names: Array = KART_CLIPS if String(char_def.get("type", "runner")) == "kart" else RUNNER_CLIPS
	var n := ""
	for s in names:
		if not clips.has(s):
			n = s
			break
	if n == "":
		var i := 1
		while clips.has("clip_%d" % i):
			i += 1
		n = "clip_%d" % i
	# A state clip starts from the real built-in animation, so it is visible and
	# editable straight away instead of starting from a rest pose.
	if rig != null and n in _standard_states():
		_bake_standard(n)
		return
	# Custom kart clips pose a seated driver: start from the pose the game uses.
	if String(char_def.get("type", "runner")) == "kart" and rig != null:
		var arm_rest := -PI * 0.5 if rig.rest_pose() == "arms_down" else 0.0
		pose = _full_pose(KartVisual.default_drive_pose(arm_rest))
		_apply_live_pose()
	clips[n] = {
		"length": 1.0,
		"loop": n in ["idle", "run", "drive"],
		"fps": float(DEFAULT_FPS),
		"keys": [{"t": 0.0, "pose": _pose_to_json(pose)}],
	}
	clip_name = n
	_refresh_clip_list()
	_set_dirty(true)
	_commit("clip")
	status("Added clip '%s' - pose a part, scrub, pose again. Auto-key stores it." % n)


func rename_clip() -> void:
	var n := name_edit.text.strip_edges().to_snake_case()
	if clip_name == "" or n == "" or n == clip_name:
		return
	if clips.has(n):
		status("A clip called '%s' already exists." % n)
		return
	clips[n] = clips[clip_name]
	clips.erase(clip_name)
	var old := clip_name
	clip_name = n
	_refresh_clip_list()
	_set_dirty(true)
	_commit("clip")
	status("Renamed '%s' to '%s'. Use the state names to make it play (see the tooltip)." % [old, n])


func delete_clip() -> void:
	if clip_name == "":
		return
	_confirm("Delete clip '%s' from %s?" % [clip_name, char_id], _remove_clip.bind(clip_name))


func _remove_clip(n: String) -> void:
	clips.erase(n)
	clip_name = ""
	_refresh_clip_list()
	_set_dirty(true)
	_commit("clip")
	status("Deleted clip '%s'." % n)


## Built-in states this character type can import.
func _standard_states() -> Array:
	if String(char_def.get("type", "runner")) == "kart":
		return ["drive", "hit"]
	return ["idle", "run", "jump", "hit"]


func _refresh_standard_list() -> void:
	standard_pick.clear()
	if char_def.is_empty():
		return
	for s in _standard_states():
		standard_pick.add_item(String(s))
	if standard_pick.item_count > 0:
		standard_pick.select(0)


## Loads the built-in animation into its clip so it can be edited. Existing keys are
## replaced after a confirmation.
func import_standard() -> void:
	if rig == null or char_def.is_empty() or standard_pick.item_count == 0:
		return
	var state := standard_pick.get_item_text(standard_pick.selected)
	if clips.has(state) and not clips[state].get("keys", []).is_empty():
		_confirm("Replace the keys of the '%s' clip with the built-in animation?" % state,
			_bake_standard.bind(state))
	else:
		_bake_standard(state)


func _bake_standard(state: String) -> void:
	if not clips.has(state):
		clips[state] = {
			"length": 1.0,
			"loop": state in ["idle", "run", "drive"],
			"fps": float(DEFAULT_FPS),
			"keys": [],
		}
	var c: Dictionary = clips[state]
	var length := maxf(float(c.get("length", 1.0)), 0.05)
	var fps := maxf(float(c.get("fps", DEFAULT_FPS)), 1.0)
	var loop := bool(c.get("loop", true))

	# The reference state the built-in animation is sampled from.
	var st := RacerVisual.AnimState.new()
	st.max_speed = 20.0
	var rate := 1.0
	var phase_rate := 0.0
	match state:
		"idle":
			st.speed = 0.0
		"run":
			st.speed = st.max_speed
			rate = RunnerVisual.RUN_FULL_CLIP_RATE
			phase_rate = RunnerVisual.RUN_FULL_PHASE_RATE
		"jump":
			st.jumping = true
			st.grounded = false
			st.vertical_speed = 3.0
		"hit":
			st.hit = 1.0
		"drive":
			st.speed = st.max_speed * 0.5
		_:
			status("There is no built-in '%s' animation." % state)
			return
	# The clip is played at `rate`, so it must contain whole built-in cycles over its
	# in-game duration (length / rate) to loop seamlessly.
	if phase_rate > 0.0:
		var cycles := maxf(roundf(length * phase_rate / (rate * TAU)), 1.0)
		length = cycles * TAU * rate / phase_rate
		c["length"] = length

	var v := _make_capture_actor()
	if v == null:
		status("Could not load a rig for %s." % char_id)
		return
	# Let the state weights settle before the first key is captured.
	for i in 90:
		v.update_visual(st, 1.0 / 60.0)
	# Start at the beginning of the standard cycle, not after the warm-up.
	v.time = 0.0
	if v is RunnerVisual:
		var rv := v as RunnerVisual
		if state == "run":
			rv.phase = 0.0
		elif state == "jump":
			rv.spin = 0.0
	v.update_visual(st, 0.0)      # apply the reset pose before the first key

	var capture: VertexRig = null
	if v is KartVisual:
		capture = (v as KartVisual).driver
	elif v is RunnerVisual:
		capture = (v as RunnerVisual).rig
	var keys := []
	if capture != null:
		var count := clampi(int(round(length * fps)), 2, 240)
		var step := length / float(count)
		var key_count := count if loop else count + 1
		for i in key_count:
			if i > 0:
				# The clip runs `rate` times faster in game, so sample the built-in
				# animation slower to keep the original cadence.
				v.update_visual(st, step / rate)
			keys.append({"t": minf(float(i) * step, length), "pose": _capture_pose(capture)})
	preview_root.remove_child(v)
	v.queue_free()
	if keys.is_empty():
		status("Could not read the character's rig.")
		return
	c["keys"] = keys
	clips[state] = c
	clip_name = state
	_refresh_clip_list()
	_set_dirty(true)
	_commit("clip")
	status("Imported the built-in %s animation (%d keys, %.2f s). Edit it, then Save." % [state, keys.size(), length])


## A hidden visual used to sample the built-in animation (it has the same rig and
## character settings, just without the custom clips).
func _make_capture_actor() -> RacerVisual:
	if rig == null:
		return null
	var def := char_def.duplicate(true)
	def.erase("animations")
	var v: RacerVisual
	if String(char_def.get("type", "runner")) == "kart":
		var kv := KartVisual.new()
		var kid := String(char_def.get("default_kart", "standard"))
		var kdef := _read_json("res://content/karts/%s.json" % kid)
		kv.kart_rig_path = String(kdef.get("rig", "res://assets/rigs/kart_standard.json"))
		kv.driver_rig_path = String(char_def.get("rig", ""))
		var seat: Variant = char_def.get("seat", [0.0, 0.05, 0.16])
		if seat is Array and seat.size() >= 3:
			kv.seat = Vector3(float(seat[0]), float(seat[1]), float(seat[2]))
		v = kv
	else:
		var rv := RunnerVisual.new()
		rv.rig_path = String(char_def.get("rig", ""))
		v = rv
	v.set_meta("char_def", def)
	preview_root.add_child(v)
	v.visible = false
	return v


func _capture_pose(r: VertexRig) -> Dictionary:
	var p := {}
	for i in r.part_names.size():
		p[String(r.part_names[i])] = {
			"rot": r.part_rot[i].get_euler(),
			"off": r.part_offset[i],
		}
	return _pose_to_json(p)


func _on_length_changed(v: float) -> void:
	if _syncing or clip_name == "":
		return
	var c: Dictionary = clips[clip_name]
	c["length"] = maxf(v, 0.05)
	clips[clip_name] = c
	timeline.length = float(c["length"])
	_set_dirty(true)
	_set_time(minf(time, float(c["length"])))
	_commit("clip")


func _on_loop_toggled(on: bool) -> void:
	if _syncing or clip_name == "":
		return
	clips[clip_name]["loop"] = on
	_set_dirty(true)
	_commit("clip")


func _on_fps_changed(v: float) -> void:
	if _syncing or clip_name == "":
		return
	clips[clip_name]["fps"] = maxf(v, 1.0)
	timeline.fps = maxf(v, 1.0)
	timeline.queue_redraw()
	_set_dirty(true)
	_commit("clip")


# --- timeline and keys ------------------------------------------------------------

func _key_times() -> Array:
	var out := []
	var c: Dictionary = clips.get(clip_name, {})
	for k in c.get("keys", []):
		out.append(float(k.get("t", 0.0)))
	return out


func _refresh_timeline_keys() -> void:
	timeline.keys = _key_times()
	timeline.queue_redraw()


func _clip_length() -> float:
	var c: Dictionary = clips.get(clip_name, {})
	return maxf(float(c.get("length", 1.0)), 0.05)


func _snap(t: float) -> float:
	var c: Dictionary = clips.get(clip_name, {})
	var fps := maxf(float(c.get("fps", DEFAULT_FPS)), 1.0)
	return clampf(roundf(t * fps) / fps, 0.0, _clip_length())


func _set_time(t: float) -> void:
	time = clampf(t, 0.0, _clip_length())
	timeline.time = time
	timeline.queue_redraw()
	time_label.text = "%.2f / %.2f s" % [time, _clip_length()]
	if clip_name != "":
		var c: Dictionary = clips.get(clip_name, {})
		pose = _full_pose(RigAnim.sample_clip(c, time))
		_apply_live_pose()
		_sync_pose_controls()


func _on_timeline_seek(t: float) -> void:
	_set_play(false)
	_set_time(_snap(t))


func _set_play(on: bool) -> void:
	playing = on and clip_name != ""
	play_btn.set_pressed_no_signal(playing)
	play_btn.text = "Pause" if playing else "Play"


func _stop() -> void:
	_set_play(false)
	_set_time(0.0)


func key_pose() -> void:
	if clip_name == "":
		status("Pick or create a clip first.")
		return
	if _write_key(time, pose):
		status("Key at %.2f s - %d keys." % [time, _key_times().size()])
	else:
		status("Updated the key at %.2f s." % time)
	_commit("key")


## Stores `p` at `t` (replacing a key on the same frame). Returns true if a key was added.
func _write_key(t: float, p: Dictionary) -> bool:
	if clip_name == "":
		return false
	var c: Dictionary = clips.get(clip_name, {})
	var fps := maxf(float(c.get("fps", DEFAULT_FPS)), 1.0)
	var tol := 0.5 / fps
	var tt := clampf(roundf(t * fps) / fps, 0.0, maxf(_clip_length() - tol, 0.0))
	var keys: Array = c.get("keys", [])
	for k in keys:
		if absf(float(k.get("t", 0.0)) - tt) <= tol:
			k["pose"] = _pose_to_json(p)
			_refresh_timeline_keys()
			_set_dirty(true)
			return false
	keys.append({"t": tt, "pose": _pose_to_json(p)})
	keys.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return float(x.get("t", 0.0)) < float(y.get("t", 0.0)))
	c["keys"] = keys
	clips[clip_name] = c
	_refresh_timeline_keys()
	_set_dirty(true)
	return true


func delete_key_near(t: float) -> void:
	if clip_name == "":
		return
	var c: Dictionary = clips.get(clip_name, {})
	var keys: Array = c.get("keys", [])
	var best := -1
	var bd := INF
	for i in keys.size():
		var d := absf(float(keys[i].get("t", 0.0)) - t)
		if d < bd:
			bd = d
			best = i
	var tol := 1.0 / maxf(float(c.get("fps", DEFAULT_FPS)), 1.0)
	if best < 0 or bd > tol:
		status("No key at the playhead.")
		return
	var kt := float(keys[best].get("t", 0.0))
	keys.remove_at(best)
	c["keys"] = keys
	clips[clip_name] = c
	_refresh_timeline_keys()
	_set_dirty(true)
	_set_time(kt)
	_commit("key")
	status("Deleted the key at %.2f s." % kt)


# --- parts and posing -------------------------------------------------------------

func _refresh_parts() -> void:
	part_list.clear()
	selected_part = ""
	_refresh_handles()
	if rig == null:
		pose = {}
		_sync_pose_controls()
		return
	for p in rig.part_names:
		part_list.add_item(String(p))
	if rig.part_names.size() > 0:
		part_list.select(0)
		selected_part = String(rig.part_names[0])
	pose = _full_pose({})
	_sync_pose_controls()
	_update_handles()


func _full_pose(p: Dictionary) -> Dictionary:
	var out := {}
	if rig == null:
		return out
	for part in rig.part_names:
		var e: Variant = p.get(part, {})
		if not (e is Dictionary):
			continue
		out[String(part)] = {
			"rot": _vec(e.get("rot", [])),
			"off": _vec(e.get("off", [])),
		}
	return out


func _pose_to_json(p: Dictionary) -> Dictionary:
	var out := {}
	for part in p:
		var e: Dictionary = p[part]
		var rot: Vector3 = e.get("rot", Vector3.ZERO)
		var off: Vector3 = e.get("off", Vector3.ZERO)
		var rec := {"rot": [rot.x, rot.y, rot.z]}
		if not off.is_zero_approx():
			rec["off"] = [off.x, off.y, off.z]
		out[String(part)] = rec
	return out


func _apply_live_pose() -> void:
	if rig == null:
		return
	rig.reset_pose()
	for part in pose:
		var e: Dictionary = pose[part]
		rig.set_rot(part, e.get("rot", Vector3.ZERO))
		var off: Vector3 = e.get("off", Vector3.ZERO)
		if not off.is_zero_approx():
			rig.set_offset(part, off)
	rig.apply()
	_update_handles()


func _on_part_selected(i: int) -> void:
	selected_part = part_list.get_item_text(i)
	_sync_pose_controls()
	_update_handles()


func _select_part_index(i: int) -> void:
	if rig == null or i < 0 or i >= rig.part_names.size():
		return
	selected_part = String(rig.part_names[i])
	_hover_handle = -1
	part_list.select(i)
	part_list.ensure_current_is_visible()
	_sync_pose_controls()
	_update_handles()
	status("Selected '%s' - drag a ring or arrow, or use [ / ] to cycle parts."
		% selected_part)


## Step through the part list from the keyboard, so a part hidden inside the body
## never has to be grabbed with the mouse.
func _cycle_part(delta: int) -> void:
	if rig == null or rig.part_names.is_empty():
		return
	var n := rig.part_names.size()
	var i := 0
	for k in n:
		if String(rig.part_names[k]) == selected_part:
			i = k
			break
	_select_part_index((i + delta + n) % n)


func _sync_pose_controls() -> void:
	_syncing = true
	var e: Dictionary = pose.get(selected_part, {})
	var r: Vector3 = e.get("rot", Vector3.ZERO)
	var o: Vector3 = e.get("off", Vector3.ZERO)
	rot_spins[0].value = rad_to_deg(r.x)
	rot_spins[1].value = rad_to_deg(r.y)
	rot_spins[2].value = rad_to_deg(r.z)
	off_spins[0].value = o.x
	off_spins[1].value = o.y
	off_spins[2].value = o.z
	_syncing = false


func _pose_changed() -> void:
	if _syncing or selected_part == "" or rig == null:
		return
	if clip_name == "":
		status("No clip selected - press New to create one, then pose.")
	_set_play(false)
	pose[selected_part] = {
		"rot": Vector3(deg_to_rad(rot_spins[0].value), deg_to_rad(rot_spins[1].value),
			deg_to_rad(rot_spins[2].value)),
		"off": Vector3(off_spins[0].value, off_spins[1].value, off_spins[2].value),
	}
	_apply_live_pose()
	if clip_name != "" and auto_key.button_pressed:
		_write_key(time, pose)
		_commit("field")


func _reset_part() -> void:
	if selected_part == "":
		return
	_set_play(false)
	pose[selected_part] = {"rot": Vector3.ZERO, "off": Vector3.ZERO}
	_apply_live_pose()
	_sync_pose_controls()
	if auto_key.button_pressed:
		_write_key(time, pose)
	_commit("pose")


func _reset_all() -> void:
	_set_play(false)
	pose = _full_pose({})
	_apply_live_pose()
	_sync_pose_controls()
	if auto_key.button_pressed:
		_write_key(time, pose)
	_commit("pose")


# --- undo / redo ------------------------------------------------------------------

## Clips are snapshotted as JSON, so an undo restores keys, lengths and names exactly.
## Continuous edits (a gizmo drag, a spinner drag) are coalesced into one step by tag.
func _reset_undo() -> void:
	undo_stack.clear()
	redo_stack.clear()
	_committed = JSON.stringify(clips)
	_last_commit_tag = ""
	_update_undo_buttons()


func _commit(tag: String = "") -> void:
	var now := JSON.stringify(clips)
	if now == _committed:
		return
	var t := Time.get_ticks_msec()
	if tag != "" and tag == _last_commit_tag and t - _last_commit_ms < 700:
		_committed = now
		_last_commit_ms = t
		return
	undo_stack.append(_committed)
	if undo_stack.size() > UNDO_LIMIT:
		undo_stack.pop_front()
	redo_stack.clear()
	_committed = now
	_last_commit_tag = tag
	_last_commit_ms = t
	_update_undo_buttons()


func _undo() -> void:
	if undo_stack.is_empty():
		return
	_set_play(false)
	redo_stack.append(_committed)
	_restore_state(undo_stack.pop_back())
	status("Undone - %d more step(s) available." % undo_stack.size())


func _redo() -> void:
	if redo_stack.is_empty():
		return
	_set_play(false)
	undo_stack.append(_committed)
	_restore_state(redo_stack.pop_back())
	status("Redone - %d more step(s) available." % redo_stack.size())


func _restore_state(snapshot: String) -> void:
	var parsed: Variant = JSON.parse_string(snapshot)
	clips = parsed if parsed is Dictionary else {}
	_committed = JSON.stringify(clips)
	_last_commit_tag = ""
	var t := time
	_refresh_clip_list()
	_refresh_timeline_keys()
	_set_dirty(true)
	_set_time(minf(t, _clip_length()))
	_sync_pose_controls()
	_update_undo_buttons()


func _update_undo_buttons() -> void:
	if undo_btn != null:
		undo_btn.disabled = undo_stack.is_empty()
	if redo_btn != null:
		redo_btn.disabled = redo_stack.is_empty()


# --- tools and shortcuts ----------------------------------------------------------

func _on_tool_toggled(on: bool, move: bool) -> void:
	if on:
		_set_tool(move)


func _set_tool(move: bool) -> void:
	gizmo_move = move
	if rotate_btn != null:
		rotate_btn.set_pressed_no_signal(not move)
	if move_btn != null:
		move_btn.set_pressed_no_signal(move)
	gizmo_hover = -1
	_update_gizmo()
	if move:
		status("Move tool: drag an arrow (or the part). X/Y/Z locks the axis.")
	else:
		status("Rotate tool: drag a ring (or the part; Shift rolls). X/Y/Z locks the axis.")


func _on_axis_button(on: bool, axis: int) -> void:
	if on:
		_set_axis(axis)
	elif axis_lock == axis:
		_set_axis(-1)


func _set_axis(axis: int) -> void:
	axis_lock = axis
	for i in axis_btns.size():
		axis_btns[i].set_pressed_no_signal(i == axis)
	if axis < 0:
		status("Free drag - no axis lock.")
	else:
		status("Locked to %s: drag the part to %s it." % [["X", "Y", "Z"][axis],
			"move" if gizmo_move else "rotate"])


## Keyboard shortcuts, only while this dock (or its preview) is the active surface.
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
		return
	if k.alt_pressed:
		return
	match k.keycode:
		KEY_R:
			_set_tool(false)
			accept_event()
		KEY_G:
			_set_tool(true)
			accept_event()
		KEY_X:
			_set_axis(0)
			accept_event()
		KEY_Y:
			_set_axis(1)
			accept_event()
		KEY_Z:
			_set_axis(2)
			accept_event()
		KEY_F:
			_frame_camera()
			accept_event()
		KEY_BRACKETLEFT:
			_cycle_part(-1)
			accept_event()
		KEY_BRACKETRIGHT:
			_cycle_part(1)
			accept_event()
		KEY_ESCAPE:
			_set_axis(-1)
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


func _show_help() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Animation Editor - shortcuts"
	dlg.dialog_text = "PREVIEW\n" \
		+ "Click a part or a pivot dot to select it.\n" \
		+ "R / G: rotate / move tool\n" \
		+ "X / Y / Z: constrain to that axis (Esc frees it)\n" \
		+ "[ / ]: previous / next part\n" \
		+ "Alt-click: select a part through the gizmo\n" \
		+ "Drag a ring: rotate about its axis; drag an arrow: move along it\n" \
		+ "Drag the part: free rotate (Shift rolls) / view-plane move\n" \
		+ "Middle-drag or right-drag: orbit   Shift+middle: pan\n" \
		+ "Wheel: zoom   Double-click or F: frame\n\n" \
		+ "CLIPS\n" \
		+ "Ctrl+Z / Ctrl+Shift+Z (or Ctrl+Y): undo / redo\n" \
		+ "Ctrl+S: save"
	add_child(dlg)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered(Vector2i(460, 0))


# --- save -------------------------------------------------------------------------

func save() -> void:
	if char_id == "" or char_def.is_empty():
		status("Pick a character first.")
		return
	if not _write_character():
		return
	_set_dirty(false)
	status("Saved %d clip(s) to %s%s.json" % [clips.size(), CHARS, char_id])
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()


func _write_character() -> bool:
	char_def["animations"] = clips
	var path := CHARS + char_id + ".json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		status("Could not write " + path)
		return false
	f.store_string(JSON.stringify(char_def, "\t", false) + "\n")
	f.close()
	return true


# --- 3D preview -------------------------------------------------------------------

func _build_preview(parent: Control) -> void:
	preview_holder = SubViewportContainer.new()
	preview_holder.stretch = true
	preview_holder.custom_minimum_size = Vector2(320, 210)
	preview_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_holder.mouse_filter = Control.MOUSE_FILTER_STOP
	preview_holder.focus_mode = Control.FOCUS_CLICK
	preview_holder.gui_input.connect(_on_preview_input)
	parent.add_child(preview_holder)

	viewport = SubViewport.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	preview_holder.add_child(viewport)

	preview_root = Node3D.new()
	viewport.add_child(preview_root)

	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.15, 0.19)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.66, 0.74)
	env.ambient_light_energy = 0.9
	world.environment = env
	preview_root.add_child(world)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -32, 0)
	sun.light_energy = 1.1
	preview_root.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, 138, 0)
	fill.light_energy = 0.35
	preview_root.add_child(fill)

	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(8, 8)
	floor_mesh.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.26, 0.28, 0.33)
	mat.roughness = 1.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	floor_mesh.material_override = mat
	preview_root.add_child(floor_mesh)

	cam = Camera3D.new()
	cam.fov = 35.0
	cam.current = true
	preview_root.add_child(cam)

	# Part handles: small unshaded dots at every pivot, drawn over the mesh so they
	# can be clicked even when a part is hidden behind another.
	handle_mesh = SphereMesh.new()
	handle_mesh.radial_segments = 8
	handle_mesh.rings = 4
	handle_mesh.radius = 1.0
	handle_mesh.height = 2.0
	handle_mat = StandardMaterial3D.new()
	handle_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	handle_mat.albedo_color = Color(0.35, 0.70, 1.0)
	handle_mat.no_depth_test = true
	handle_sel_mat = StandardMaterial3D.new()
	handle_sel_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	handle_sel_mat.albedo_color = Color(1.0, 0.78, 0.20)
	handle_sel_mat.no_depth_test = true
	handle_hover_mat = StandardMaterial3D.new()
	handle_hover_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	handle_hover_mat.albedo_color = Color(0.80, 0.95, 1.0)
	handle_hover_mat.no_depth_test = true
	handle_root = Node3D.new()
	handle_root.name = "PoseHandles"
	preview_root.add_child(handle_root)
	_update_camera()


func _frame_camera() -> void:
	var mn := Vector3.ZERO
	var mx := Vector3(0, 1.2, 0)
	if rig != null:
		mn = _vec(rig.meta.get("aabb_min", [0, 0, 0]))
		mx = _vec(rig.meta.get("aabb_max", [0, 1.2, 0]))
	focus = Vector3(0, (mn.y + mx.y) * 0.5, 0)
	cam_dist = maxf((mx.y - mn.y) * 2.4, 0.8)
	cam_pitch = 0.16
	cam_yaw = PI
	_update_camera()


func _update_camera() -> void:
	if cam == null:
		return
	var off := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch),
		cos(cam_yaw) * cos(cam_pitch)) * cam_dist
	cam.position = focus + off
	cam.look_at(focus, Vector3.UP)
	_update_handles()


func _refresh_handles() -> void:
	for h in handles:
		h.queue_free()
	handles.clear()
	if rig == null or handle_root == null:
		return
	for i in rig.part_names.size():
		var h := MeshInstance3D.new()
		h.mesh = handle_mesh
		h.material_override = handle_mat
		h.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		handle_root.add_child(h)
		handles.append(h)
	_update_handles()


## Keep the pivot dots at the current pose and a constant on-screen size.
func _update_handles() -> void:
	_update_gizmo()
	if rig == null or handles.is_empty() or cam == null:
		return
	var s := maxf(cam_dist * 0.0125, 0.006)
	for i in handles.size():
		var sel := String(rig.part_names[i]) == selected_part
		handles[i].position = rig.part_xform[i] * rig.part_pivot[i]
		handles[i].scale = Vector3.ONE * (s * (1.35 if sel else 1.0))
		if sel:
			handles[i].material_override = handle_sel_mat
		elif i == _hover_handle:
			handles[i].material_override = handle_hover_mat
		else:
			handles[i].material_override = handle_mat


# --- gizmo ------------------------------------------------------------------------

func _axis_vector(i: int) -> Vector3:
	match i:
		0:
			return Vector3.RIGHT
		1:
			return Vector3.UP
	return Vector3.BACK


## Ring/arrow meshes are built along local +Y; rotate that onto the axis.
func _axis_node_basis(i: int) -> Basis:
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


## Radius of the gizmo in world units, so it stays the same size on screen.
func _gizmo_len() -> float:
	return maxf(cam_dist * 0.095, 0.04)


func _clear_gizmo() -> void:
	if gizmo_root != null and is_instance_valid(gizmo_root):
		gizmo_root.queue_free()
	gizmo_root = null
	gizmo_axes.clear()
	gizmo_rings.clear()
	gizmo_arrows.clear()
	gizmo_mats.clear()
	gizmo_hover = -1
	gizmo_drag = -1


func _build_gizmo() -> void:
	_clear_gizmo()
	if rig == null:
		return
	gizmo_root = Node3D.new()
	gizmo_root.name = "Gizmo"
	rig.add_child(gizmo_root)
	var torus := TorusMesh.new()
	torus.inner_radius = 0.985
	torus.outer_radius = 1.012
	torus.rings = 48
	torus.ring_segments = 8
	for a in 3:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Transparent + no depth test: drawn after the model, always visible on top.
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.no_depth_test = true
		mat.albedo_color = _axis_color(a, false)
		var axis := Node3D.new()
		axis.basis = _axis_node_basis(a)
		gizmo_root.add_child(axis)

		var ring := MeshInstance3D.new()
		ring.mesh = torus
		ring.material_override = mat
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		axis.add_child(ring)

		var arrow := Node3D.new()
		var shaft := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.014
		cyl.bottom_radius = 0.014
		cyl.height = 0.66
		cyl.radial_segments = 8
		shaft.mesh = cyl
		shaft.position = Vector3(0, 0.47, 0)
		shaft.material_override = mat
		shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arrow.add_child(shaft)
		var tip := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.05
		cone.height = 0.16
		cone.radial_segments = 12
		tip.mesh = cone
		tip.position = Vector3(0, 0.88, 0)
		tip.material_override = mat
		tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arrow.add_child(tip)
		axis.add_child(arrow)

		gizmo_axes.append(axis)
		gizmo_rings.append(ring)
		gizmo_arrows.append(arrow)
		gizmo_mats.append(mat)
	gizmo_move = move_btn.button_pressed if move_btn != null else false
	_update_gizmo()


## Keep the gizmo on the selected part's pivot, oriented like the part's parent, and
## show rings or arrows depending on the tool.
func _update_gizmo() -> void:
	if gizmo_root == null or rig == null:
		return
	var i: int = rig.part_index.get(selected_part, -1)
	var show := i >= 0 and i < rig.part_xform.size()
	gizmo_root.visible = show
	if not show:
		return
	var par: int = rig.part_parent[i]
	var gb := Basis.IDENTITY if par < 0 else rig.part_xform[par].basis
	gb = gb.orthonormalized()
	var l := _gizmo_len()
	gizmo_root.transform = Transform3D(gb * Basis.from_scale(Vector3.ONE * l),
		rig.part_xform[i] * rig.part_pivot[i])
	for a in gizmo_rings.size():
		gizmo_rings[a].visible = not gizmo_move
		gizmo_arrows[a].visible = gizmo_move
	_update_gizmo_colors()


func _update_gizmo_colors() -> void:
	for a in gizmo_mats.size():
		var c := _axis_color(a, a == gizmo_hover or a == gizmo_drag)
		if gizmo_mats[a].albedo_color != c:
			gizmo_mats[a].albedo_color = c


## Viewport position of a world point, or an infinite vector when behind the camera.
func _project(p: Vector3) -> Vector2:
	if cam == null or cam.is_position_behind(p):
		return Vector2.INF
	return cam.unproject_position(p)


## Distance from a ray (unit direction) to a point, in world units.
func _ray_point_distance(o: Vector3, d: Vector3, p: Vector3) -> float:
	return (p - o).cross(d).length()


func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Axis (0 X, 1 Y, 2 Z) of the gizmo handle under a viewport position, or -1.
## Picking is done in screen space against the drawn ring/arrow, so it stays
## clickable at any zoom and matches what is visible through the model.
func _gizmo_axis_at(p: Vector2) -> int:
	if rig == null or cam == null or selected_part == "":
		return -1
	if gizmo_root == null or not gizmo_root.visible:
		return -1
	var i: int = rig.part_index.get(selected_part, -1)
	if i < 0:
		return -1
	var l := _gizmo_len()
	var rt := rig.global_transform
	var pivot := rt * (rig.part_xform[i] * rig.part_pivot[i])
	# Keep the pivot itself free for selecting the part: seen edge-on a ring
	# collapses into a line through this point.
	var pc := _project(pivot)
	if pc.is_finite() and p.distance_to(pc) < 11.0:
		return -1
	var par: int = rig.part_parent[i]
	var gb := rt.basis if par < 0 else rt.basis * rig.part_xform[par].basis
	gb = gb.orthonormalized()
	var best := -1
	var bd := 8.0
	var ro := cam.project_ray_origin(p)
	var rd := cam.project_ray_normal(p).normalized()
	for a in 3:
		var dir := (gb * _axis_vector(a)).normalized()
		if gizmo_move:
			var s0 := _project(pivot + dir * l * 0.12)
			var s1 := _project(pivot + dir * l)
			if not s0.is_finite() or not s1.is_finite():
				continue
			var d := _segment_distance(p, s0, s1)
			if d < bd:
				bd = d
				best = a
		else:
			var rb := gb * _axis_node_basis(a)
			var last := Vector2.INF
			var axis_best := 9.0
			var axis_pt := Vector3.ZERO
			var found := false
			for k in 33:
				var ang := TAU * float(k) / 32.0
				var w := pivot + rb * Vector3(cos(ang), 0.0, sin(ang)) * l
				var s := _project(w)
				if not s.is_finite():
					last = Vector2.INF
					continue
				if last.is_finite():
					var d := _segment_distance(p, last, s)
					if d < axis_best:
						axis_best = d
						axis_pt = w
						found = true
				last = s
			# A ring seen edge-on projects onto a line through the pivot; without this
			# check a click on the part's centre would grab the ring instead.
			if found and axis_best < bd and _ray_point_distance(ro, rd, axis_pt) <= l * 0.18:
				bd = axis_best
				best = a
	return best


## Highlight the handle or pivot dot under the cursor, so it is obvious what a click
## will select before committing to it.
func _preview_hover(p: Vector2) -> void:
	var a := _gizmo_axis_at(p)
	var h := -1 if a >= 0 else _handle_at(p)
	if a == gizmo_hover and h == _hover_handle:
		return
	gizmo_hover = a
	_hover_handle = h
	_update_gizmo_colors()
	_update_handles()
	if preview_holder != null:
		preview_holder.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
			if a >= 0 or h >= 0 else Control.CURSOR_ARROW


## `at` is the click position in viewport pixels; it decides where on the ring the
## drag starts, so the part follows the cursor on either side of the pivot.
func _begin_gizmo_drag(axis: int, at: Vector2 = Vector2.INF) -> void:
	if rig == null or cam == null or selected_part == "":
		return
	if not rig.part_index.has(selected_part):
		return
	_set_play(false)
	_drag = 3
	gizmo_drag = axis
	_g_acc = 0.0
	var i: int = rig.part_index[selected_part]
	var l := _gizmo_len()
	var rt := rig.global_transform
	var pivot := rt * (rig.part_xform[i] * rig.part_pivot[i])
	var par: int = rig.part_parent[i]
	var gb := rt.basis if par < 0 else rt.basis * rig.part_xform[par].basis
	gb = gb.orthonormalized()
	var dir := (gb * _axis_vector(axis)).normalized()
	var c := _project(pivot)
	if not c.is_finite():
		c = Vector2.ZERO
	if gizmo_move:
		var d := _project(pivot + dir * l) - c
		if not d.is_finite() or d.length() < 4.0:
			d = Vector2.DOWN * 4.0
		_g_dir2 = d.normalized()
		_g_px_per_unit = maxf(d.length() / l, 0.01)
	else:
		var rb := gb * _axis_node_basis(axis)
		var ang := 0.0
		if at.is_finite():
			# The ring point nearest the cursor, in screen space: works even when the
			# ring is viewed almost edge-on (where a ray/plane test is unstable).
			var best := INF
			for k in 64:
				var a2 := TAU * float(k) / 64.0
				var s := _project(pivot + rb * Vector3(cos(a2), 0.0, sin(a2)) * l)
				if s.is_finite() and s.distance_to(at) < best:
					best = s.distance_to(at)
					ang = a2
		var r := rb * Vector3(cos(ang), 0.0, sin(ang)) * l
		var tang := dir.cross(r).normalized()
		var on := _project(pivot + r)
		var vel := _project(pivot + tang * l * 0.2)
		var d2 := vel - c
		_g_dir2 = d2.normalized() if d2.is_finite() and d2.length() > 0.001 else Vector2.RIGHT
		_g_px_per_rad = maxf(on.distance_to(c), 16.0)
	var e: Dictionary = pose.get(selected_part, {})
	_g_start_rot = e.get("rot", Vector3.ZERO)
	_g_start_off = e.get("off", Vector3.ZERO)
	_update_gizmo_colors()


func _comp(v: Vector3, i: int) -> float:
	match i:
		0:
			return v.x
		1:
			return v.y
	return v.z


func _with_comp(v: Vector3, i: int, x: float) -> Vector3:
	match i:
		0:
			return Vector3(x, v.y, v.z)
		1:
			return Vector3(v.x, x, v.z)
	return Vector3(v.x, v.y, x)


## One step of a gizmo drag. `rel` is in viewport pixels.
func _drag_gizmo(rel: Vector2) -> void:
	if gizmo_drag < 0 or selected_part == "":
		return
	var e: Dictionary = pose.get(selected_part, {})
	# Accumulate: each mouse event adds its own movement, so the part tracks the
	# cursor instead of snapping back to start + one event's delta every frame.
	_g_acc += rel.dot(_g_dir2)
	var d := _g_acc
	if gizmo_move:
		var o := _with_comp(_g_start_off, gizmo_drag,
			clampf(_comp(_g_start_off, gizmo_drag) + d / _g_px_per_unit, -1.0, 1.0))
		pose[selected_part] = {"rot": e.get("rot", Vector3.ZERO), "off": o}
	else:
		var r := _with_comp(_g_start_rot, gizmo_drag,
			_comp(_g_start_rot, gizmo_drag) + d / _g_px_per_rad)
		pose[selected_part] = {"rot": r, "off": e.get("off", Vector3.ZERO)}
	_apply_live_pose()
	_sync_pose_controls()
	if clip_name != "" and auto_key.button_pressed:
		_write_key(time, pose)


func _pan(rel: Vector2) -> void:
	if cam == null:
		return
	var per_px := 2.0 * cam_dist * tan(deg_to_rad(cam.fov) * 0.5) \
		/ maxf(preview_holder.size.y, 1.0)
	focus += (-cam.global_transform.basis.x * rel.x
		+ cam.global_transform.basis.y * rel.y) * per_px
	_update_camera()


## Mouse position in SubViewport pixels (the container stretches it to the panel).
func _view_pos(p: Vector2) -> Vector2:
	if preview_holder.size.x <= 0.0 or preview_holder.size.y <= 0.0:
		return p
	return p * Vector2(viewport.size.x, viewport.size.y) / preview_holder.size


func _handle_at(p: Vector2) -> int:
	if cam == null:
		return -1
	var best := -1
	var bd := 17.0
	for i in handles.size():
		var wp := handles[i].global_position
		if cam.is_position_behind(wp):
			continue
		var d := cam.unproject_position(wp).distance_to(p)
		if d < bd:
			bd = d
			best = i
	return best


func _pick_part(p: Vector2) -> int:
	if rig == null or cam == null:
		return -1
	var inv := rig.global_transform.affine_inverse()
	var o := inv * cam.project_ray_origin(p)
	var d := (inv.basis * cam.project_ray_normal(p)).normalized()
	return rig.pick(o, d)


func _start_drag(p: Vector2, bypass_gizmo := false) -> void:
	_drag = 1
	if rig == null or cam == null:
		return
	if preview_holder != null:
		preview_holder.grab_focus()
	var vp := _view_pos(p)
	var g := -1 if bypass_gizmo else _gizmo_axis_at(vp)
	if g >= 0:
		_begin_gizmo_drag(g, vp)
		return
	var hit := _handle_at(vp)
	if hit < 0:
		hit = _pick_part(vp)
	if hit < 0:
		return
	_set_play(false)
	_select_part_index(hit)
	_drag = 2
	_drag_travel = 0.0
	_drag_move = move_btn.button_pressed
	if axis_lock >= 0:
		_begin_gizmo_drag(axis_lock, vp)
		return
	if clip_name == "":
		status("No clip selected - press New to create one, then pose.")


## One mouse-motion step of a pose drag: rotate (or move) the selected part in 3D.
func _drag_pose(rel: Vector2, shift: bool) -> void:
	if rig == null or selected_part == "":
		return
	var e: Dictionary = pose.get(selected_part, {})
	var rot: Vector3 = e.get("rot", Vector3.ZERO)
	var off: Vector3 = e.get("off", Vector3.ZERO)
	if _drag_move:
		var right := cam.global_transform.basis.x
		var up := cam.global_transform.basis.y
		var per_px := 2.0 * cam_dist * tan(deg_to_rad(cam.fov) * 0.5) / maxf(preview_holder.size.y, 1.0)
		var delta := (right * rel.x + up * -rel.y) * per_px
		var idx: int = rig.part_index.get(selected_part, -1)
		if idx >= 0:
			var parent: int = rig.part_parent[idx]
			if parent >= 0:
				delta = rig.part_xform[parent].basis.inverse() * delta
		off = (off + delta).clamp(Vector3(-1, -1, -1), Vector3(1, 1, 1))
	else:
		var step := 0.008
		if shift:
			rot.z -= rel.x * step
		else:
			rot.x -= rel.y * step      # drag up: swing forward
			rot.y -= rel.x * step      # drag right: turn right
	pose[selected_part] = {"rot": rot, "off": off}
	_apply_live_pose()
	_sync_pose_controls()
	if clip_name != "" and auto_key.button_pressed:
		_write_key(time, pose)


## Mouse motion in SubViewport pixels (the container stretches it to the panel).
func _view_rel(v: Vector2) -> Vector2:
	if preview_holder.size.x <= 0.0 or preview_holder.size.y <= 0.0:
		return v
	return v * Vector2(viewport.size.x, viewport.size.y) / preview_holder.size


func _on_preview_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed and e.double_click:
				_drag = 0
				gizmo_drag = -1
				_frame_camera()
			elif e.pressed:
				_start_drag(e.position, e.alt_pressed)
			else:
				if _drag == 2 or _drag == 3:
					_commit("pose")
				_drag = 0
				gizmo_drag = -1
				_update_gizmo_colors()
				_preview_hover(_view_pos(e.position))
			preview_holder.accept_event()
		elif e.button_index == MOUSE_BUTTON_RIGHT or e.button_index == MOUSE_BUTTON_MIDDLE:
			if e.pressed and _drag == 0:
				_drag = 4 if (e.button_index == MOUSE_BUTTON_MIDDLE and e.shift_pressed) else 1
			elif not e.pressed and (_drag == 1 or _drag == 4):
				_drag = 0
			preview_holder.accept_event()
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist = maxf(0.25, cam_dist * 0.9)
			_update_camera()
			preview_holder.accept_event()
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = minf(30.0, cam_dist * 1.1)
			_update_camera()
			preview_holder.accept_event()
	elif e is InputEventMouseMotion:
		if _drag == 1:
			cam_yaw -= e.relative.x * 0.01
			cam_pitch = clampf(cam_pitch - e.relative.y * 0.01, -1.2, 1.2)
			_update_camera()
			preview_holder.accept_event()
		elif _drag == 2:
			# A tiny movement is a click to select, not an accidental pose change.
			_drag_travel += e.relative.length()
			if _drag_travel >= 3.0:
				_drag_pose(e.relative, e.shift_pressed)
			preview_holder.accept_event()
		elif _drag == 3:
			_drag_gizmo(_view_rel(e.relative))
			preview_holder.accept_event()
		elif _drag == 4:
			_pan(e.relative)
			preview_holder.accept_event()
		else:
			_preview_hover(_view_pos(e.position))


# --- small dialogs ----------------------------------------------------------------

func _confirm(text: String, on_yes: Callable, on_no: Callable = Callable()) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = text
	dlg.dialog_autowrap = true
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		dlg.queue_free()
		on_yes.call())
	dlg.canceled.connect(func() -> void:
		dlg.queue_free()
		if on_no.is_valid():
			on_no.call())
	dlg.popup_centered()
