@tool
extends ScrollContainer
## Kart Importer dock: vehicle model -> vertex rig + kart definition.
## Pick an imported model (inside the project), set its length / facing / split,
## Load, Analyse (finds the four wheels) and Export. The kart then shows up in the
## character menu's kart picker.

var imp := KartImporter.new()
var path_edit: LineEdit
var id_edit: LineEdit
var name_edit: LineEdit
var facing_pick: OptionButton
var split_pick: OptionButton
var length_spin: SpinBox
var wheels_label: Label
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
	path_edit.placeholder_text = "res://import/my_kart/kart.glb"
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_edit = _row(g, "Id", LineEdit.new())
	name_edit = _row(g, "Name", LineEdit.new())
	facing_pick = _row(g, "Model faces", _opts(CharacterImporter.FACINGS.keys()))
	facing_pick.select(1)
	split_pick = _row(g, "Wheels", _opts(KartImporter.SPLITS))
	split_pick.tooltip_text = "auto: find the four wheels in the shape\\n" + \
		"nodes: one mesh node per wheel (uses their origins)\\n" + \
		"surfaces: one material surface per wheel"
	length_spin = _row(g, "Length (m)", SpinBox.new())
	length_spin.min_value = 0.3
	length_spin.max_value = 6.0
	length_spin.step = 0.05
	length_spin.value = 1.4
	length_spin.tooltip_text = "Front to back. The model is scaled to this, so the kart is\\n" + \
		"the same size as the track and the standard kart."
	var row := HBoxContainer.new()
	v.add_child(row)
	_btn(row, "Load", load_model)
	_btn(row, "Analyse", analyse)
	_btn(row, "Export", export)
	wheels_label = _label("Wheels: -")
	wheels_label.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	v.add_child(wheels_label)
	v.add_child(_note("Load, Analyse, then Export. Wheels are measured in the log."))
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


## Full-width note under the fields, where wrapping is wanted.
func _note(t: String) -> Label:
	var l := _label(t)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	imp.facing = facing_pick.get_item_text(facing_pick.selected)
	imp.split = split_pick.get_item_text(split_pick.selected)
	imp.length = length_spin.value


func load_model() -> void:
	imp = KartImporter.new()
	_sync()
	var err := imp.load_source(path_edit.text.strip_edges())
	if err != "":
		out("Error: " + err)
		return
	id_edit.text = imp.id
	name_edit.text = imp.display_name
	out("Loaded %d mesh pieces from %s." % [imp.chunks.size(), imp.source_path])


func analyse() -> void:
	if imp.chunks.is_empty():
		load_model()
		if imp.chunks.is_empty():
			return
	_sync()
	imp.analyse()
	out("Length %.2f m, width %.2f m, height %.2f m" % [imp.size.z, imp.size.x, imp.size.y])
	out("Wheels: %s" % ", ".join(imp.wheels.keys()))
	for w in imp.wheels:
		var c: Vector3 = imp.wheels[w]["centre"]
		out("  %s at (%.2f, %.2f, %.2f), radius %.3f m" % [w, c.x, c.y, c.z, float(imp.wheels[w]["radius"])])
	wheels_label.text = "Wheels: %s" % ("none" if imp.wheels.is_empty() else ", ".join(imp.wheels.keys()))
	for n in imp.notes:
		out("Note: " + n)


func export() -> void:
	analyse()
	if imp.chunks.is_empty() or imp.id == "":
		out("Nothing to export (load a model and give it an id).")
		return
	# Keep hand-tuned paint settings of a previous import of the same kart.
	var zones := imp.detect_paint()
	var old = _read_json("res://content/karts/%s.json" % imp.id)
	if old is Dictionary:
		var prev_zones: Variant = old.get("paint", {})
		if prev_zones is Dictionary:
			for z in prev_zones:
				if zones.has(z):
					var merged: Dictionary = zones[z]
					var prev: Dictionary = prev_zones[z]
					for k in ["tol", "presets", "default", "src"]:
						if prev.has(k):
							merged[k] = prev[k]
					zones[z] = merged
	var p := imp.export(zones)
	out("Wrote %s and a rig for it (paint zones: %s)" % [p, ", ".join(zones.keys())])
	if not imp.wheels.is_empty():
		out("Pick it in the menu under Customise once your racer is a kart.")
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))
