@tool
extends ScrollContainer
## Character Importer dock: model -> vertex rig + character definition.
## Pick an imported model (inside the project), choose type/facing/split, set roles
## per group if needed, Analyse, then Export. The character appears in the menu.

var imp := CharacterImporter.new()
var path_edit: LineEdit
var id_edit: LineEdit
var name_edit: LineEdit
var type_pick: OptionButton
var facing_pick: OptionButton
var split_pick: OptionButton
var pose_pick: OptionButton
var height_spin: SpinBox
var groups_box: GridContainer
var log_box: TextEdit


func _ready() -> void:
	custom_minimum_size = Vector2(0, 300)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(v)
	var g := GridContainer.new()
	g.columns = 2
	v.add_child(g)
	path_edit = _row(g, "Model (res://...)", LineEdit.new())
	path_edit.placeholder_text = "res://import/my_model/model.glb"
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_edit = _row(g, "Id", LineEdit.new())
	name_edit = _row(g, "Name", LineEdit.new())
	type_pick = _row(g, "Type", _opts(["runner", "kart"]))
	facing_pick = _row(g, "Model faces", _opts(CharacterImporter.FACINGS.keys()))
	facing_pick.select(1)
	split_pick = _row(g, "Split", _opts(CharacterImporter.SPLITS))
	pose_pick = _row(g, "Arms", _opts(["auto", "t_pose", "arms_down"]))
	height_spin = _row(g, "Height (m)", SpinBox.new())
	height_spin.min_value = 0.2; height_spin.max_value = 5; height_spin.step = 0.05; height_spin.value = 1.1
	type_pick.item_selected.connect(func(i: int) -> void: height_spin.value = 1.1 if i == 0 else 0.85)
	split_pick.item_selected.connect(func(_i: int) -> void: _sync(); imp.make_groups(); _show_groups())
	var row := HBoxContainer.new()
	v.add_child(row)
	_btn(row, "Load", load_model)
	_btn(row, "Analyse", analyse)
	_btn(row, "Export", export)
	v.add_child(_label("Groups and roles (\"auto\" = split by position):"))
	groups_box = GridContainer.new()
	groups_box.columns = 2
	v.add_child(groups_box)
	log_box = TextEdit.new()
	log_box.editable = false
	log_box.custom_minimum_size = Vector2(0, 120)
	v.add_child(log_box)


func _row(g: Control, t: String, c: Control) -> Variant:
	g.add_child(_label(t))
	g.add_child(c)
	return c


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _opts(items: Array) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(String(it))
	return o


func _btn(p: Control, t: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	p.add_child(b)


func out(t: String) -> void:
	log_box.text += t + "\n"
	log_box.scroll_vertical = log_box.get_line_count()


func _sync() -> void:
	imp.id = id_edit.text.strip_edges().to_snake_case()
	imp.display_name = name_edit.text.strip_edges()
	imp.type = type_pick.get_item_text(type_pick.selected)
	imp.facing = facing_pick.get_item_text(facing_pick.selected)
	imp.split = split_pick.get_item_text(split_pick.selected)
	imp.pose = pose_pick.get_item_text(pose_pick.selected)
	imp.height = height_spin.value


func load_model() -> void:
	imp = CharacterImporter.new()
	_sync()
	var err := imp.load_source(path_edit.text.strip_edges())
	if err != "":
		out("Error: " + err)
		return
	id_edit.text = imp.id
	name_edit.text = imp.display_name
	out("Loaded %d mesh pieces." % imp.chunks.size())
	_show_groups()


func _show_groups() -> void:
	for c in groups_box.get_children():
		c.queue_free()
	var roles := ["auto", "ignore"] + CharacterImporter.ROLES
	for gr in imp.groups:
		groups_box.add_child(_label(gr.name))
		var o := _opts(roles)
		o.select(maxi(0, roles.find(gr.role)))
		var gref: Dictionary = gr
		o.item_selected.connect(func(i: int) -> void: gref.role = roles[i])
		groups_box.add_child(o)


func analyse() -> void:
	if imp.chunks.is_empty():
		load_model()
		if imp.chunks.is_empty():
			return
	var keep := {}
	for gr in imp.groups:
		keep[gr.name] = gr.role
	_sync()
	for gr in imp.groups:
		gr.role = keep.get(gr.name, gr.role)
	imp.analyse()
	out("Pose: %s  crotch %.2f  neck %.2f (fractions of height)" % [imp.measure.pose, imp.measure.crotch, imp.measure.neck])
	out("Parts (vertices): %s" % imp.role_counts())
	for n in imp.notes:
		out("Note: " + n)


func export() -> void:
	analyse()
	if imp.chunks.is_empty() or imp.id == "":
		out("Nothing to export (load a model and give it an id).")
		return
	var paint := imp.detect_paint()
	var p := imp.export(paint)
	out("Wrote %s and res://assets/rigs/%s.json (paint zones: %s)" % [p, imp.id, ", ".join(paint.keys())])
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
