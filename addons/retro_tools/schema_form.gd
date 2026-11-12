@tool
extends RefCounted
## Builds an editor form from a parameter schema, the same schemas the game reads:
## item behaviours' PARAMS, track objects' PARAMS, GameRules.SCHEMA.
##
##   key -> {"type": "float"|"int"|"bool"|"enum"|"string"|"color"|"path",
##           "default": v, "min", "max", "step", "options": [...], "hint": "..."}
##
## build() adds one row per key to a 2-column grid and calls on_change(key, value)
## whenever a field is edited. Unknown keys in `values` (added by hand to a JSON
## file) get a plain text field so nothing is hidden or lost.


static func build(parent: Control, schema: Dictionary, values: Dictionary, on_change: Callable,
		extra_keys := true) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(g)
	for key in schema:
		_row(g, String(key), schema[key], values.get(key, schema[key].get("default")), on_change)
	if extra_keys:
		for key in values:
			if not schema.has(key):
				_row(g, String(key), {"type": _guess(values[key])}, values[key], on_change)
	return g


static func _guess(v: Variant) -> String:
	if v is bool:
		return "bool"
	if v is int:
		return "int"
	if v is float:
		return "float"
	return "string"


static func _row(g: GridContainer, key: String, sc: Dictionary, value: Variant, on_change: Callable) -> void:
	var l := Label.new()
	l.text = key.capitalize()
	l.tooltip_text = String(sc.get("hint", ""))
	l.add_theme_color_override("font_color", Color(0.78, 0.81, 0.86))
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	g.add_child(l)
	var hint := String(sc.get("hint", ""))
	match String(sc.get("type", "string")):
		"float", "int":
			var s := SpinBox.new()
			var is_int := String(sc.type) == "int"
			s.min_value = float(sc.get("min", -100000.0))
			s.max_value = float(sc.get("max", 100000.0))
			s.step = 1.0 if is_int else float(sc.get("step", 0.01))
			s.allow_greater = true
			s.allow_lesser = true
			s.value = float(value) if value != null else 0.0
			s.tooltip_text = hint
			s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			s.value_changed.connect(func(x: float) -> void: on_change.call(key, int(x) if is_int else x))
			g.add_child(s)
		"bool":
			var c := CheckBox.new()
			c.button_pressed = bool(value)
			c.tooltip_text = hint
			c.toggled.connect(func(on: bool) -> void: on_change.call(key, on))
			g.add_child(c)
		"enum":
			var o := OptionButton.new()
			var opts: Array = sc.get("options", [])
			for k in opts.size():
				o.add_item(String(opts[k]))
				if String(opts[k]) == String(value):
					o.select(k)
			o.tooltip_text = hint
			o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			o.item_selected.connect(func(i: int) -> void: on_change.call(key, String(opts[i])))
			g.add_child(o)
		"color":
			var cp := ColorPickerButton.new()
			cp.color = Color.html(String(value)) if value != null and Color.html_is_valid(String(value)) else Color.WHITE
			cp.custom_minimum_size = Vector2(60, 0)
			cp.tooltip_text = hint
			cp.color_changed.connect(func(c2: Color) -> void: on_change.call(key, "#" + c2.to_html(false)))
			g.add_child(cp)
		"path":
			g.add_child(path_field(String(value) if value != null else "", String(sc.get("filter", "*")),
				func(t: String) -> void: on_change.call(key, t), hint))
		_:
			var le := LineEdit.new()
			le.text = String(value) if value != null else ""
			le.tooltip_text = hint
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_submitted.connect(func(t: String) -> void: on_change.call(key, t))
			le.focus_exited.connect(func() -> void: on_change.call(key, le.text))
			g.add_child(le)


## A text field for a res:// path with a "..." button that opens a file dialog.
static func path_field(value: String, filters: String, on_set: Callable, hint := "") -> HBoxContainer:
	var h := HBoxContainer.new()
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var le := LineEdit.new()
	le.text = value
	le.placeholder_text = "res://..."
	le.tooltip_text = hint
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text_submitted.connect(func(t: String) -> void: on_set.call(t))
	le.focus_exited.connect(func() -> void: on_set.call(le.text))
	h.add_child(le)
	var b := Button.new()
	b.text = "..."
	b.tooltip_text = "Pick a file in the project"
	b.pressed.connect(func() -> void:
		var dlg: Window
		if Engine.is_editor_hint() and ClassDB.class_exists("EditorFileDialog"):
			var ed: EditorFileDialog = ClassDB.instantiate("EditorFileDialog")
			ed.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
			ed.access = EditorFileDialog.ACCESS_RESOURCES
			for f in filters.split(";", false):
				ed.add_filter(f)
			ed.file_selected.connect(func(p: String) -> void:
				le.text = p
				on_set.call(p))
			dlg = ed
		else:
			var fd := FileDialog.new()
			fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			fd.access = FileDialog.ACCESS_RESOURCES
			for f in filters.split(";", false):
				fd.add_filter(f)
			fd.file_selected.connect(func(p: String) -> void:
				le.text = p
				on_set.call(p))
			dlg = fd
		h.add_child(dlg)
		dlg.close_requested.connect(dlg.queue_free)
		dlg.popup_centered_ratio(0.6))
	h.add_child(b)
	return h
