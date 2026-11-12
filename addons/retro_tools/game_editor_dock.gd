@tool
extends TabContainer
## Game Editor: everything that is data, edited in the editor.
##   Items       - content/items/*.json: behaviour + its parameters, count, look/model,
##                 icon and the odds table per race position (1st .. 12th).
##   Objects     - content/objects/*.json: placeable gameplay object types (rings, item
##                 boxes, doors, collectables, pads, springs ...) and their defaults.
##                 Place them with the Map Editor.
##   Rules       - content/rules.json (rings, item roulette, hits, rocket start ...).
##   Characters  - skins (texture swaps on the same model - nothing is cut or rebuilt)
##                 and unlock conditions (tokens / emeralds / your own kinds).
##   Looks       - content/looks/*.json console presets (Saturn, Dreamcast, ...).
## New item / object BEHAVIOURS are scripts (see src/items/item_behaviour.gd and
## src/objects/track_object.gd); they appear in the Behaviour lists here with their own
## fields as soon as the file exists.

const SchemaForm := preload("res://addons/retro_tools/schema_form.gd")
const ITEM_DIR := "res://content/items/"
const OBJECT_DIR := "res://content/objects/"
const LOOK_DIR := "res://content/looks/"
const CHAR_DIR := "res://content/characters/"
const SHAPES := ["mushroom", "banana", "shell", "spiny", "bomb", "star", "bullet", "bolt",
	"fake_box", "ink", "shield", "ring", "magnet", "box", "token", "emerald", "spring",
	"dash", "chevron", "orb"]
const POS_NAMES := ["1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th", "9th", "10th", "11th", "12th"]
const LOOK_SCHEMA := {
	"name": {"type": "string", "default": "New look"},
	"filter": {"type": "enum", "default": "nearest", "options": ["nearest", "linear"], "hint": "nearest = Saturn / PS1 pixels, linear = Dreamcast bilinear"},
	"dither": {"type": "float", "default": 0.0, "min": 0.0, "max": 2.0, "step": 0.05, "hint": "Ordered dither before the colour cut"},
	"scanlines": {"type": "float", "default": 0.0, "min": 0.0, "max": 1.0, "step": 0.01},
	"fog_scale": {"type": "float", "default": 1.0, "min": 0.1, "max": 5.0, "step": 0.05, "hint": "x fog distance"},
	"saturation": {"type": "float", "default": 1.0, "min": 0.0, "max": 2.0, "step": 0.01},
	"mesh_transparency": {"type": "bool", "default": false, "hint": "Saturn checkerboard instead of real transparency"},
}

var items_list: ItemList
var items_form: VBoxContainer
var item_cur := {}
var item_path := ""
var objects_list: ItemList
var objects_form: VBoxContainer
var obj_cur := {}
var obj_path := ""
var rules_form: VBoxContainer
var rules_cur := {}
var looks_list: ItemList
var looks_form: VBoxContainer
var look_cur := {}
var look_path := ""
var char_pick: OptionButton
var char_form: VBoxContainer
var char_cur := {}
var char_path := ""
var skin_sel := ""
var status_label: Label
var _dirty := {}


func _ready() -> void:
	custom_minimum_size = Vector2(0, 340)
	_build_items()
	_build_objects()
	_build_rules()
	_build_characters()
	_build_looks()
	refresh_all()


func refresh_all() -> void:
	ItemTypes.reload()
	ObjectTypes.reload()
	GameRules.reload()
	_list_dir(items_list, ITEM_DIR)
	_list_dir(objects_list, OBJECT_DIR)
	_list_dir(looks_list, LOOK_DIR)
	_fill_chars()
	_show_rules()


func status(t: String) -> void:
	for tab in get_children():
		var l := tab.find_child("Status", true, false) as Label
		if l:
			l.text = t


# --- shared --------------------------------------------------------------------------

func _page(title: String) -> Array:
	var h := HSplitContainer.new()
	h.name = title
	add_child(h)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(220, 0)
	h.add_child(left)
	var sc := ScrollContainer.new()
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	h.add_child(sc)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(right)
	return [left, right]


func _btn(p: Control, text: String, cb: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(cb)
	p.add_child(b)
	return b


func _lbl(p: Control, text: String, muted := false) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", Color(0.62, 0.65, 0.72) if muted else Color(0.9, 0.86, 0.55))
	p.add_child(l)
	return l


func _status_label(p: Control) -> void:
	var l := _lbl(p, "", true)
	l.name = "Status"


func _list(p: Control, on_pick: Callable) -> ItemList:
	var il := ItemList.new()
	il.size_flags_vertical = Control.SIZE_EXPAND_FILL
	il.item_selected.connect(func(i: int) -> void: on_pick.call(String(il.get_item_metadata(i))))
	p.add_child(il)
	return il


func _list_dir(il: ItemList, dir: String) -> void:
	if il == null:
		return
	il.clear()
	var d := DirAccess.open(dir)
	if d == null:
		DirAccess.make_dir_recursive_absolute(dir)
		return
	var files := Array(d.get_files())
	files.sort()
	for f in files:
		if not String(f).ends_with(".json"):
			continue
		var j := read_json(dir + String(f))
		il.add_item("%s  (%s)" % [String(j.get("name", String(f).get_basename())), String(f).get_basename()])
		il.set_item_metadata(il.item_count - 1, dir + String(f))


static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func write_json(path: String, d: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d, "\t") + "\n")
	f.close()
	if Engine.is_editor_hint() and ClassDB.class_exists("EditorInterface"):
		EditorInterface.get_resource_filesystem().scan()
	return true


func _clear(c: Control) -> void:
	for ch in c.get_children():
		c.remove_child(ch)
		ch.queue_free()


static func _new_id(dir: String, base: String) -> String:
	var id := base.to_snake_case().replace(" ", "_")
	if id == "":
		id = "new"
	var k := 1
	var out := id
	while FileAccess.file_exists(dir + out + ".json"):
		k += 1
		out = "%s_%d" % [id, k]
	return out


func _crud_row(p: Control, kind: String, dir: String, cur_get: Callable, on_load: Callable, make_new: Callable) -> void:
	var row := HBoxContainer.new()
	p.add_child(row)
	_btn(row, "New", func() -> void:
		var d: Dictionary = make_new.call()
		var id := _new_id(dir, String(d.get("name", kind)))
		d["id"] = id
		write_json(dir + id + ".json", d)
		refresh_all()
		on_load.call(dir + id + ".json")
		status("Made %s%s.json" % [dir, id]), "Make a new %s file" % kind)
	_btn(row, "Duplicate", func() -> void:
		var cur: Dictionary = cur_get.call()
		if cur.is_empty():
			return
		var d := cur.duplicate(true)
		d["name"] = String(d.get("name", "")) + " copy"
		var id := _new_id(dir, String(d.get("id", kind)) + "_copy")
		d["id"] = id
		write_json(dir + id + ".json", d)
		refresh_all()
		on_load.call(dir + id + ".json")
		status("Duplicated to %s%s.json" % [dir, id]), "Copy the selected %s" % kind)
	_btn(row, "Delete", func() -> void:
		var cur: Dictionary = cur_get.call()
		if cur.is_empty():
			return
		var path := dir + String(cur.get("id", "")) + ".json"
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		refresh_all()
		status("Deleted " + path), "Delete the selected %s file" % kind)


# --- Items ---------------------------------------------------------------------------

func _build_items() -> void:
	var lr := _page("Items")
	var left: VBoxContainer = lr[0]
	items_form = lr[1]
	_lbl(left, "Items (content/items)")
	items_list = _list(left, load_item)
	_crud_row(left, "item", ITEM_DIR, func() -> Dictionary: return item_cur, load_item, func() -> Dictionary:
		return {"name": "New item", "behaviour": "boost", "count": 1, "shape": "orb", "colour": "#ffffff",
			"params": {}, "odds": [10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10], "enabled": true})
	_btn(left, "Save item  (Ctrl+S)", save_item)
	_status_label(left)


func load_item(path: String) -> void:
	item_path = path
	item_cur = read_json(path)
	_draw_item()


func _set_item(key: String, v: Variant) -> void:
	item_cur[key] = v
	_dirty["item"] = true
	if key == "behaviour":
		_draw_item()


func _set_item_param(key: String, v: Variant) -> void:
	if not (item_cur.get("params") is Dictionary):
		item_cur["params"] = {}
	item_cur.params[key] = v
	_dirty["item"] = true


func _draw_item() -> void:
	_clear(items_form)
	if item_cur.is_empty():
		return
	_lbl(items_form, "%s  -  %s" % [String(item_cur.get("name", "")), item_path])
	var bids: Array = ItemTypes.behaviours().keys()
	bids.sort()
	var base := {
		"name": {"type": "string", "default": ""},
		"behaviour": {"type": "enum", "default": "boost", "options": bids, "hint": "What the item does (scripts in src/items/behaviours)"},
		"count": {"type": "int", "default": 1, "min": 1, "max": 9, "hint": "Uses per pick-up (3 = triple item)"},
		"enabled": {"type": "bool", "default": true},
		"shape": {"type": "enum", "default": "orb", "options": SHAPES, "hint": "Built-in low-poly model when no model file is set"},
		"colour": {"type": "color", "default": "#ffffff"},
		"model": {"type": "path", "default": "", "filter": "*.glb,*.gltf,*.tscn,*.scn,*.obj,*.dae,*.fbx,*.res,*.tres", "hint": "Your own model (optional)"},
		"model_scale": {"type": "float", "default": 1.0, "min": 0.01, "max": 100.0, "step": 0.01},
		"icon": {"type": "path", "default": "", "filter": "*.png,*.svg,*.webp", "hint": "HUD icon (optional; otherwise a coloured badge)"},
	}
	var vals := {}
	for k in base:
		vals[k] = item_cur.get(k, base[k].default)
	SchemaForm.build(items_form, base, vals, _set_item, false)
	var rt := HBoxContainer.new()
	items_form.add_child(rt)
	var rl := Label.new()
	rl.text = "Racer types"
	rl.tooltip_text = "Comma list of racer types that can roll this item (empty = everyone), e.g. kart, runner"
	rt.add_child(rl)
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text = ", ".join(PackedStringArray(item_cur.get("racer_types", [])))
	le.placeholder_text = "everyone"
	var commit_rt := func(t: String) -> void:
		var arr: Array = []
		for part in t.split(",", false):
			if part.strip_edges() != "":
				arr.append(part.strip_edges())
		item_cur["racer_types"] = arr
		_dirty["item"] = true
	le.text_submitted.connect(commit_rt)
	le.focus_exited.connect(func() -> void: commit_rt.call(le.text))
	rt.add_child(le)
	var bid := String(item_cur.get("behaviour", ""))
	_lbl(items_form, "Behaviour: " + ItemTypes.behaviour_label(bid))
	var schema := ItemTypes.behaviour_params(bid)
	if schema.is_empty():
		_lbl(items_form, "This behaviour has no parameters.", true)
	else:
		var pv := {}
		for k in schema:
			pv[k] = schema[k].get("default")
		var own: Variant = item_cur.get("params", {})
		if own is Dictionary:
			pv.merge(own, true)
		SchemaForm.build(items_form, schema, pv, _set_item_param)
	_draw_odds()


func _draw_odds() -> void:
	_lbl(items_form, "Odds by race position (weight; 0 = never). Racers fewer than 12 are spread over the columns.")
	var odds: Array = item_cur.get("odds", [])
	while odds.size() < ItemTypes.POSITIONS:
		odds.append(odds[-1] if odds.size() > 0 else 10)
	item_cur["odds"] = odds
	var g := GridContainer.new()
	g.columns = 6
	items_form.add_child(g)
	var spins: Array = []
	for k in ItemTypes.POSITIONS:
		var v := VBoxContainer.new()
		var l := Label.new()
		l.text = POS_NAMES[k]
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)
		var s := SpinBox.new()
		s.min_value = 0
		s.max_value = 1000
		s.step = 1
		s.value = float(odds[k])
		s.value_changed.connect(func(x: float) -> void:
			odds[k] = int(x)
			_dirty["item"] = true
			_odds_note())
		v.add_child(s)
		spins.append(s)
		g.add_child(v)
	var row := HBoxContainer.new()
	items_form.add_child(row)
	var preset := func(arr: Array) -> void:
		for k in ItemTypes.POSITIONS:
			spins[k].value = arr[k]
	_btn(row, "Flat", func() -> void: preset.call([10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10]), "Same chance everywhere")
	_btn(row, "Front-runner", func() -> void: preset.call([30, 25, 20, 15, 10, 5, 0, 0, 0, 0, 0, 0]), "Defensive item: leaders get it")
	_btn(row, "Mid-pack", func() -> void: preset.call([0, 5, 15, 20, 25, 25, 20, 15, 5, 0, 0, 0]))
	_btn(row, "Catch-up", func() -> void: preset.call([0, 0, 0, 0, 0, 5, 10, 15, 20, 25, 30, 30]), "Powerful item: only the back of the pack")
	var note := _lbl(items_form, "", true)
	note.name = "OddsNote"
	_odds_note()


func _odds_note() -> void:
	var note := items_form.find_child("OddsNote", true, false) as Label
	if note == null:
		return
	var parts: Array = []
	for col in [0, 5, 11]:
		var total := 0.0
		var mine := 0.0
		for id in ItemTypes.items():
			var d: Dictionary = item_cur if id == String(item_cur.get("id", "")) else ItemTypes.items()[id]
			if not bool(d.get("enabled", true)):
				continue
			var o: Array = d.get("odds", [])
			var w := float(o[mini(col, o.size() - 1)]) if o.size() > 0 else 1.0
			total += w
			if id == String(item_cur.get("id", "")):
				mine = w
		parts.append("%s %.0f%%" % [POS_NAMES[col], 100.0 * mine / maxf(total, 0.001)])
	note.text = "Chance with the saved odds of the other items: " + "   ".join(parts)


func save_item() -> void:
	if item_path == "" or item_cur.is_empty():
		status("Pick an item first.")
		return
	if write_json(item_path, item_cur):
		_dirty.erase("item")
		ItemTypes.reload()
		_list_dir(items_list, ITEM_DIR)
		status("Saved " + item_path)


# --- Objects -------------------------------------------------------------------------

func _build_objects() -> void:
	var lr := _page("Objects")
	var left: VBoxContainer = lr[0]
	objects_form = lr[1]
	_lbl(left, "Object types (content/objects)")
	_lbl(left, "Place them in the Map Editor (palette: Gameplay / Collectables).", true)
	objects_list = _list(left, load_object)
	_crud_row(left, "object", OBJECT_DIR, func() -> Dictionary: return obj_cur, load_object, func() -> Dictionary:
		return {"name": "New object", "behaviour": "ring", "category": "Gameplay", "shape": "ring",
			"colour": "#ffd23a", "size": [1.0, 1.5], "params": {}})
	_btn(left, "Save object", save_object)
	_status_label(left)


func load_object(path: String) -> void:
	obj_path = path
	obj_cur = read_json(path)
	_draw_object()


func _set_obj(key: String, v: Variant) -> void:
	if key == "size_radius" or key == "size_height":
		var sz: Array = obj_cur.get("size", [1.0, 1.5])
		sz[0 if key == "size_radius" else 1] = v
		obj_cur["size"] = sz
	else:
		obj_cur[key] = v
	_dirty["object"] = true
	if key == "behaviour":
		_draw_object()


func _set_obj_param(key: String, v: Variant) -> void:
	if not (obj_cur.get("params") is Dictionary):
		obj_cur["params"] = {}
	obj_cur.params[key] = v
	_dirty["object"] = true


func _draw_object() -> void:
	_clear(objects_form)
	if obj_cur.is_empty():
		return
	_lbl(objects_form, "%s  -  %s" % [String(obj_cur.get("name", "")), obj_path])
	var bids: Array = ObjectTypes.behaviours().keys()
	bids.sort()
	var sz: Array = obj_cur.get("size", [1.0, 1.5])
	var base := {
		"name": {"type": "string", "default": ""},
		"category": {"type": "string", "default": "Gameplay", "hint": "Palette group in the Map Editor"},
		"behaviour": {"type": "enum", "default": "ring", "options": bids, "hint": "Scripts in src/objects/behaviours"},
		"shape": {"type": "enum", "default": "orb", "options": SHAPES},
		"colour": {"type": "color", "default": "#ffffff"},
		"model": {"type": "path", "default": "", "filter": "*.glb,*.gltf,*.tscn,*.scn,*.obj,*.dae,*.fbx,*.res,*.tres", "hint": "Your own model (optional)"},
		"model_scale": {"type": "float", "default": 1.0, "min": 0.01, "max": 100.0, "step": 0.01},
		"size_radius": {"type": "float", "default": 1.0, "min": 0.1, "max": 50.0, "step": 0.1, "hint": "Editor pick / selection box radius"},
		"size_height": {"type": "float", "default": 1.5, "min": 0.1, "max": 50.0, "step": 0.1},
	}
	var vals := {}
	for k in base:
		vals[k] = obj_cur.get(k, base[k].default)
	vals["size_radius"] = float(sz[0])
	vals["size_height"] = float(sz[1])
	SchemaForm.build(objects_form, base, vals, _set_obj, false)
	var bid := String(obj_cur.get("behaviour", ""))
	_lbl(objects_form, "Behaviour: %s - defaults for every placed copy (each placed one can override them in the Map Editor)" % ObjectTypes.behaviour_label(bid))
	var schema := ObjectTypes.behaviour_params(bid)
	var pv := {}
	for k in schema:
		pv[k] = schema[k].get("default")
	var own: Variant = obj_cur.get("params", {})
	if own is Dictionary:
		pv.merge(own, true)
	pv.erase("uid")
	var sc2 := schema.duplicate()
	sc2.erase("uid")
	SchemaForm.build(objects_form, sc2, pv, _set_obj_param)


func save_object() -> void:
	if obj_path == "" or obj_cur.is_empty():
		status("Pick an object type first.")
		return
	if write_json(obj_path, obj_cur):
		_dirty.erase("object")
		ObjectTypes.reload()
		_list_dir(objects_list, OBJECT_DIR)
		status("Saved %s - press R next to the Map Editor palette to see changes." % obj_path)


# --- Rules ---------------------------------------------------------------------------

func _build_rules() -> void:
	var lr := _page("Rules")
	var left: VBoxContainer = lr[0]
	rules_form = lr[1]
	_lbl(left, "Race rules (content/rules.json)")
	_lbl(left, "Rings, items, hits and starts. The menu's Items switch overrides 'items_enabled' per race.", true)
	_btn(left, "Save rules", save_rules)
	_btn(left, "Defaults", func() -> void:
		rules_cur = {}
		for k in GameRules.SCHEMA:
			rules_cur[k] = GameRules.SCHEMA[k].default
		_draw_rules())
	_status_label(left)


func _show_rules() -> void:
	rules_cur = GameRules.all()
	_draw_rules()


func _draw_rules() -> void:
	_clear(rules_form)
	SchemaForm.build(rules_form, GameRules.SCHEMA, rules_cur, func(k: String, v: Variant) -> void: rules_cur[k] = v)


func save_rules() -> void:
	if GameRules.save_all(rules_cur) == OK:
		status("Saved " + GameRules.PATH)


# --- Characters (skins, unlocks) -----------------------------------------------------

func _build_characters() -> void:
	var lr := _page("Characters")
	var left: VBoxContainer = lr[0]
	char_form = lr[1]
	_lbl(left, "Skins & unlocks")
	_lbl(left, "A skin swaps textures on the character's own model - the geometry (feet and all) is never cut or rebuilt. New characters / karts: Character Importer and Kart Importer docks.", true)
	char_pick = OptionButton.new()
	char_pick.item_selected.connect(func(i: int) -> void: load_character(String(char_pick.get_item_metadata(i))))
	left.add_child(char_pick)
	_btn(left, "Save character", save_character)
	_status_label(left)


func _fill_chars() -> void:
	if char_pick == null:
		return
	char_pick.clear()
	var d := DirAccess.open(CHAR_DIR)
	if d == null:
		return
	var files := Array(d.get_files())
	files.sort()
	for f in files:
		if String(f).ends_with(".json"):
			var j := read_json(CHAR_DIR + String(f))
			char_pick.add_item(String(j.get("name", f)))
			char_pick.set_item_metadata(char_pick.item_count - 1, CHAR_DIR + String(f))
	if char_pick.item_count > 0:
		var keep := 0
		for i in char_pick.item_count:
			if String(char_pick.get_item_metadata(i)) == char_path:
				keep = i
		char_pick.select(keep)
		load_character(String(char_pick.get_item_metadata(keep)))


func load_character(path: String) -> void:
	char_path = path
	char_cur = read_json(path)
	var skins: Variant = char_cur.get("skins", {})
	if not (skins is Dictionary) or not (skins as Dictionary).has(skin_sel):
		skin_sel = ""
	_draw_character()


static func unlock_text(u: Variant) -> String:
	if not (u is Dictionary):
		return ""
	var parts: Array = []
	for k in u:
		parts.append("%s:%d" % [k, int(u[k])])
	return ", ".join(parts)


static func parse_unlock(t: String) -> Dictionary:
	var out := {}
	for part in t.split(",", false):
		var kv := part.strip_edges().split(":")
		if kv.size() == 2 and kv[0].strip_edges() != "":
			out[kv[0].strip_edges()] = int(kv[1])
	return out


## Texture paths of the rig's surfaces (read from the rig file).
func rig_textures(rig_path: String) -> Array:
	var out: Array = []
	var j := read_json(rig_path)
	for s in j.get("surfaces", []):
		if s is Dictionary:
			var t := String(s.get("texture", ""))
			if t != "" and not out.has(t):
				out.append(t)
	return out


func _unlock_row(parent: Control, value: Variant, on_set: Callable, tip: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var l := Label.new()
	l.text = "Unlock"
	l.tooltip_text = tip
	row.add_child(l)
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.placeholder_text = "always available   (e.g. token:5, emerald:1)"
	le.text = unlock_text(value)
	le.tooltip_text = tip
	le.text_submitted.connect(func(t: String) -> void: on_set.call(parse_unlock(t)))
	le.focus_exited.connect(func() -> void: on_set.call(parse_unlock(le.text)))
	row.add_child(le)


func _draw_character() -> void:
	_clear(char_form)
	if char_cur.is_empty():
		return
	_lbl(char_form, "%s  -  %s" % [String(char_cur.get("name", "")), char_path])
	_unlock_row(char_form, char_cur.get("unlock"), func(u: Dictionary) -> void:
		if u.is_empty():
			char_cur.erase("unlock")
		else:
			char_cur["unlock"] = u
		_dirty["char"] = true,
		"Collectable totals needed before this racer can be picked, as kind:count pairs. Kinds are the 'kind' of collectables you place (token, emerald, ...).")
	var skins: Dictionary = char_cur.get("skins", {}) if char_cur.get("skins") is Dictionary else {}
	char_cur["skins"] = skins
	_lbl(char_form, "Skins")
	var row := HBoxContainer.new()
	char_form.add_child(row)
	var pick := OptionButton.new()
	pick.add_item("(pick a skin)")
	pick.set_item_metadata(0, "")
	for sk in skins:
		pick.add_item(String(skins[sk].get("name", sk)))
		pick.set_item_metadata(pick.item_count - 1, sk)
		if sk == skin_sel:
			pick.select(pick.item_count - 1)
	pick.item_selected.connect(func(i: int) -> void:
		skin_sel = String(pick.get_item_metadata(i))
		_draw_character())
	row.add_child(pick)
	var name_le := LineEdit.new()
	name_le.placeholder_text = "new skin name"
	name_le.custom_minimum_size.x = 140
	row.add_child(name_le)
	_btn(row, "Add skin", func() -> void: add_skin(name_le.text))
	_btn(row, "Remove", func() -> void:
		if skin_sel != "":
			skins.erase(skin_sel)
			skin_sel = ""
			_dirty["char"] = true
			_draw_character())
	if skin_sel == "" or not skins.has(skin_sel):
		_lbl(char_form, "Add a skin, then give any surface a different texture (same UV layout as the original). Players pick skins on the Customise screen.", true)
		return
	var skin: Dictionary = skins[skin_sel]
	SchemaForm.build(char_form, {"name": {"type": "string", "default": skin_sel}}, {"name": skin.get("name", skin_sel)},
		func(_k: String, v: Variant) -> void:
			skin["name"] = v
			_dirty["char"] = true)
	_unlock_row(char_form, skin.get("unlock"), func(u: Dictionary) -> void:
		if u.is_empty():
			skin.erase("unlock")
		else:
			skin["unlock"] = u
		_dirty["char"] = true, "Collectables needed before this skin can be picked")
	if not (skin.get("textures") is Dictionary):
		skin["textures"] = {}
	var tx: Dictionary = skin.textures
	_lbl(char_form, "Textures (empty = keep the original)")
	var g := GridContainer.new()
	g.columns = 2
	char_form.add_child(g)
	for t in rig_textures(String(char_cur.get("rig", ""))):
		var key := String(t).get_file().get_basename()
		var l := Label.new()
		l.text = key
		l.tooltip_text = String(t)
		g.add_child(l)
		g.add_child(SchemaForm.path_field(String(tx.get(key, "")), "*.png,*.jpg,*.webp,*.tga,*.bmp",
			func(p: String) -> void:
				if p.strip_edges() == "":
					tx.erase(key)
				else:
					tx[key] = p.strip_edges()
				_dirty["char"] = true, "Replacement for " + String(t)))


func add_skin(skin_name: String) -> String:
	if char_cur.is_empty():
		return ""
	var nm := skin_name.strip_edges()
	if nm == "":
		nm = "Skin"
	var skins: Dictionary = char_cur.get("skins", {}) if char_cur.get("skins") is Dictionary else {}
	var id := nm.to_snake_case().replace(" ", "_")
	var k := 1
	var base := id
	while skins.has(id):
		k += 1
		id = "%s_%d" % [base, k]
	skins[id] = {"name": nm, "textures": {}}
	char_cur["skins"] = skins
	skin_sel = id
	_dirty["char"] = true
	_draw_character()
	return id


func save_character() -> void:
	if char_path == "" or char_cur.is_empty():
		return
	var skins: Variant = char_cur.get("skins", {})
	if skins is Dictionary and (skins as Dictionary).is_empty():
		char_cur.erase("skins")
	if write_json(char_path, char_cur):
		_dirty.erase("char")
		status("Saved " + char_path)


# --- Looks ---------------------------------------------------------------------------

func _build_looks() -> void:
	var lr := _page("Looks")
	var left: VBoxContainer = lr[0]
	looks_form = lr[1]
	_lbl(left, "Console looks (content/looks)")
	_lbl(left, "Picked on the course screen of the menu. Resolution is the internal render size; bits are per colour channel (5 = Saturn RGB555, 5/6/5 = Dreamcast RGB565).", true)
	looks_list = _list(left, load_look)
	_crud_row(left, "look", LOOK_DIR, func() -> Dictionary: return look_cur, load_look, func() -> Dictionary:
		return {"name": "New look", "resolution": [640, 360], "filter": "nearest", "bits": [5, 5, 5],
			"dither": 0.0, "scanlines": 0.0, "fog_scale": 1.0, "saturation": 1.0})
	_btn(left, "Save look", save_look)
	_status_label(left)


func load_look(path: String) -> void:
	look_path = path
	look_cur = read_json(path)
	_clear(looks_form)
	_lbl(looks_form, "%s  -  %s" % [String(look_cur.get("name", "")), path])
	var vals := {}
	for k in LOOK_SCHEMA:
		vals[k] = look_cur.get(k, LOOK_SCHEMA[k].default)
	SchemaForm.build(looks_form, LOOK_SCHEMA, vals, func(k: String, v: Variant) -> void: look_cur[k] = v, false)
	var res: Array = look_cur.get("resolution", [640, 360])
	var bits: Array = look_cur.get("bits", [8, 8, 8])
	var sch := {
		"width": {"type": "int", "default": 640, "min": 160, "max": 3840},
		"height": {"type": "int", "default": 360, "min": 120, "max": 2160},
		"red_bits": {"type": "int", "default": 8, "min": 1, "max": 8},
		"green_bits": {"type": "int", "default": 8, "min": 1, "max": 8},
		"blue_bits": {"type": "int", "default": 8, "min": 1, "max": 8},
	}
	SchemaForm.build(looks_form, sch, {"width": res[0], "height": res[1], "red_bits": bits[0],
		"green_bits": bits[1], "blue_bits": bits[2]}, func(k: String, v: Variant) -> void:
			var r2: Array = look_cur.get("resolution", [640, 360])
			var b2: Array = look_cur.get("bits", [8, 8, 8])
			match k:
				"width": r2[0] = v
				"height": r2[1] = v
				"red_bits": b2[0] = v
				"green_bits": b2[1] = v
				"blue_bits": b2[2] = v
			look_cur["resolution"] = r2
			look_cur["bits"] = b2, false)


func save_look() -> void:
	if look_path == "" or look_cur.is_empty():
		return
	if write_json(look_path, look_cur):
		RetroLook._looks = {}
		_list_dir(looks_list, LOOK_DIR)
		status("Saved " + look_path)


func _unhandled_key_input(e: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if e is InputEventKey and e.pressed and e.ctrl_pressed and e.keycode == KEY_S:
		match get_current_tab_control().name:
			"Items": save_item()
			"Objects": save_object()
			"Rules": save_rules()
			"Characters": save_character()
			"Looks": save_look()
		get_viewport().set_input_as_handled()
