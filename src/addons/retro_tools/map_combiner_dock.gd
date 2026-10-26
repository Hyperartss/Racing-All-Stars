@tool
extends HSplitContainer
## Map Combiner: build a race course from pieces of existing tracks.
##
## Left: the map's segments (which track, which part of it, where it goes), the
## connector after each segment (optionally with a vertical loop), start line.
## Right: top-down canvas. Wheel = zoom, right/middle drag = pan, left drag on the
## selected segment = move it, Shift + left drag = rotate it, "Pick" buttons then a
## click on the canvas = choose a cut point / piece / start.
## Bake runs tools/bake/trackbake.py (Python 3 + numpy, pillow, opencv-python,
## scikit-image, networkx, matplotlib) and the new map appears in the game's menu.

const MAPS := "res://content/maps/"
const SOURCES := "res://content/track_sources/"
const BAKER := "res://tools/bake/trackbake.py"
const CFG := "user://retro_tools.cfg"

var map_id := ""
var map_def := {}
var layout := {}
var sel := 0                    ## selected segment
var sources := {}               ## id -> source json
var analysis := {}              ## id -> analysis json
var pick := ""                  ## "", "from", "to", "via", "start", "first", "last"

# widgets
var map_pick: OptionButton
var id_edit: LineEdit
var name_edit: LineEdit
var sub_edit: LineEdit
var laps_spin: SpinBox
var seg_list: ItemList
var seg_box: VBoxContainer
var start_seg: SpinBox
var python_edit: LineEdit
var log_box: TextEdit
var canvas: Control
var _building := false


func _ready() -> void:
	custom_minimum_size = Vector2(0, 340)
	_load_sources()
	var left := ScrollContainer.new()
	left.custom_minimum_size = Vector2(330, 0)
	left.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(left)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(v)

	var row := HBoxContainer.new()
	v.add_child(row)
	map_pick = OptionButton.new()
	map_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_pick.item_selected.connect(func(i: int) -> void: load_map(map_pick.get_item_metadata(i)))
	row.add_child(map_pick)
	_btn(row, "Save", save_map)
	_btn(row, "Bake", bake)

	var row2 := HBoxContainer.new()
	v.add_child(row2)
	id_edit = LineEdit.new()
	id_edit.placeholder_text = "new_map_id"
	id_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(id_edit)
	_btn(row2, "New map", func() -> void: new_map(id_edit.text.strip_edges().to_snake_case()))

	var g := GridContainer.new()
	g.columns = 2
	v.add_child(g)
	_lbl(g, "Name")
	name_edit = LineEdit.new()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_changed.connect(func(t: String) -> void: map_def["name"] = t)
	g.add_child(name_edit)
	_lbl(g, "Subtitle")
	sub_edit = LineEdit.new()
	sub_edit.text_changed.connect(func(t: String) -> void: map_def["subtitle"] = t)
	g.add_child(sub_edit)
	_lbl(g, "Laps")
	laps_spin = SpinBox.new()
	laps_spin.min_value = 1
	laps_spin.max_value = 9
	laps_spin.value_changed.connect(func(x: float) -> void: map_def["laps"] = int(x))
	g.add_child(laps_spin)

	_lbl(v, "Segments (in driving order)")
	seg_list = ItemList.new()
	seg_list.custom_minimum_size = Vector2(0, 90)
	seg_list.item_selected.connect(func(i: int) -> void: sel = i; _build_segment_box(); canvas.queue_redraw())
	v.add_child(seg_list)
	var row3 := HBoxContainer.new()
	v.add_child(row3)
	_btn(row3, "+ Add", add_segment)
	_btn(row3, "- Remove", remove_segment)
	_btn(row3, "Up", func() -> void: _move_segment(-1))
	_btn(row3, "Down", func() -> void: _move_segment(1))
	seg_box = VBoxContainer.new()
	v.add_child(seg_box)

	var row4 := HBoxContainer.new()
	v.add_child(row4)
	_lbl(row4, "Start on segment")
	start_seg = SpinBox.new()
	start_seg.min_value = 0
	start_seg.value_changed.connect(func(x: float) -> void: _start()["segment"] = int(x); canvas.queue_redraw())
	row4.add_child(start_seg)
	_btn(row4, "Pick start", func() -> void: _set_pick("start"))

	var row5 := HBoxContainer.new()
	v.add_child(row5)
	_lbl(row5, "Python")
	python_edit = LineEdit.new()
	python_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	python_edit.text = _cfg_get("python", "python3")
	python_edit.text_changed.connect(func(t: String) -> void: _cfg_set("python", t))
	row5.add_child(python_edit)
	log_box = TextEdit.new()
	log_box.custom_minimum_size = Vector2(0, 90)
	log_box.editable = false
	v.add_child(log_box)

	canvas = preload("res://addons/retro_tools/map_canvas.gd").new()
	canvas.dock = self
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(canvas)
	_refresh_map_list()
	if map_pick.item_count > 0:
		load_map(map_pick.get_item_metadata(0))


# --- helpers ---------------------------------------------------------------------

func _btn(p: Control, t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	p.add_child(b)
	return b


func _lbl(p: Control, t: String) -> Label:
	var l := Label.new()
	l.text = t
	p.add_child(l)
	return l


func _spin(p: Control, lo: float, hi: float, step: float, val: float, cb: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	s.allow_greater = true
	s.allow_lesser = true
	s.custom_minimum_size.x = 70
	s.value_changed.connect(cb)
	p.add_child(s)
	return s


func log_line(t: String) -> void:
	log_box.text += t + "\n"
	log_box.scroll_vertical = log_box.get_line_count()


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.open(path, FileAccess.READ).get_as_text())


func _cfg_get(k: String, d: String) -> String:
	var c := ConfigFile.new()
	c.load(CFG)
	return String(c.get_value("map_combiner", k, d))


func _cfg_set(k: String, v: String) -> void:
	var c := ConfigFile.new()
	c.load(CFG)
	c.set_value("map_combiner", k, v)
	c.save(CFG)


# --- data ------------------------------------------------------------------------

func _load_sources() -> void:
	sources.clear()
	var d := DirAccess.open(SOURCES)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".json") and not f.ends_with(".analysis.json"):
			var s: Variant = _read_json(SOURCES + f)
			if s is Dictionary:
				sources[String(s.id)] = s
	for sid in sources:
		var a: Variant = _read_json(SOURCES + sid + ".analysis.json")
		if a is Dictionary:
			analysis[sid] = a


func _refresh_map_list() -> void:
	map_pick.clear()
	var d := DirAccess.open(MAPS)
	if d == null:
		return
	var i := 0
	for f in d.get_files():
		if f.ends_with(".json"):
			var m: Variant = _read_json(MAPS + f)
			if m is Dictionary and m.has("layout"):
				map_pick.add_item(String(m.get("name", f.get_basename())))
				map_pick.set_item_metadata(i, f.get_basename())
				if f.get_basename() == map_id:
					map_pick.select(i)
				i += 1


func load_map(id: String) -> void:
	var m: Variant = _read_json(MAPS + id + ".json")
	if not (m is Dictionary):
		return
	map_id = id
	map_def = m
	layout = map_def.get("layout", {})
	map_def["layout"] = layout
	if not layout.has("segments"):
		layout["segments"] = []
	if not layout.has("connectors"):
		layout["connectors"] = []
	_building = true
	name_edit.text = String(map_def.get("name", id))
	sub_edit.text = String(map_def.get("subtitle", ""))
	laps_spin.value = int(map_def.get("laps", 3))
	start_seg.value = int(_start().get("segment", 0))
	_building = false
	sel = 0
	for sid in _used_sources():
		ensure_analysis(sid)
	_refresh_segments()
	canvas.fit()


func new_map(id: String) -> void:
	if id == "":
		log_line("Type an id for the new map first.")
		return
	map_id = id
	var first: String = "mario_raceway" if sources.has("mario_raceway") else String(sources.keys()[0])
	map_def = {"id": id, "name": id.capitalize(), "subtitle": "", "laps": 3,
		"layout": {"segments": [{"source": first, "full": true}], "connectors": [], "start": {"segment": 0}, "checkpoints": 10}}
	layout = map_def.layout
	save_map()
	_refresh_map_list()
	load_map(id)


func save_map() -> void:
	if map_id == "":
		return
	map_def["id"] = map_id
	var f := FileAccess.open(MAPS + map_id + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify(map_def, "\t"))
	f.close()
	log_line("Saved %s%s.json" % [MAPS, map_id])


func _used_sources() -> Array:
	var out: Array = []
	for s in layout.segments:
		if not out.has(s.source):
			out.append(s.source)
	return out


func _start() -> Dictionary:
	if not layout.has("start"):
		layout["start"] = {"segment": 0}
	return layout.start


func seg(i: int = -1) -> Dictionary:
	var k := sel if i < 0 else i
	return layout.segments[k] if k >= 0 and k < layout.segments.size() else {}


func ensure_analysis(sid: String) -> void:
	if analysis.has(sid):
		return
	log_line("Analysing %s ..." % sid)
	var out := run_python(["analyze", sid])
	log_line(out)
	var a: Variant = _read_json(SOURCES + sid + ".analysis.json")
	if a is Dictionary:
		analysis[sid] = a


func run_python(args: Array) -> String:
	var out: Array = []
	var script := ProjectSettings.globalize_path(BAKER)
	var all: PackedStringArray = [script]
	for a in args:
		all.append(String(a))
	var code := OS.execute(python_edit.text if python_edit else "python3", all, out, true)
	var text := "\n".join(out)
	if code != 0:
		text += "\n(python exited with code %d - is Python 3 with numpy/opencv/scikit-image installed?)" % code
	return text


func bake() -> void:
	save_map()
	log_line("Baking %s (this can take a minute)..." % map_id)
	log_line(run_python(["bake", map_id]))
	var m: Variant = _read_json(MAPS + map_id + ".json")
	if m is Dictionary:
		map_def["length"] = m.get("length", 0)
		map_def["data"] = m.get("data", "")
		map_def["preview"] = m.get("preview", "")
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()


# --- segments ---------------------------------------------------------------------

func _refresh_segments() -> void:
	seg_list.clear()
	for i in layout.segments.size():
		var s: Dictionary = layout.segments[i]
		var what := "full loop" if s.get("full", false) else ("pieces %d-%d" % [s.groups[0], s.groups[1]] if s.has("groups") else "cut section")
		var src: Dictionary = sources.get(s.source, {})
		var loop := ""
		if i < layout.connectors.size() and bool(layout.connectors[i].get("loop", false)):
			loop = "  + loop"
		seg_list.add_item("%d. %s - %s%s" % [i + 1, src.get("name", s.source), what, loop])
	if sel >= 0 and sel < seg_list.item_count:
		seg_list.select(sel)
	start_seg.max_value = maxi(0, layout.segments.size() - 1)
	_build_segment_box()
	canvas.queue_redraw()


func add_segment() -> void:
	var sid: String = String(sources.keys()[0])
	var a: Dictionary = analysis.get(sid, {})
	var s := {"source": sid, "offset": [0.0, "auto", 0.0], "yaw": 0.0}
	if String(sources[sid].centreline.method) == "groups":
		s["groups"] = [0, 60]
		s["scenery"] = "near"
	else:
		var cl: Array = a.get("centreline", [[0, 0, 0], [10, 0, 0]])
		s["from"] = [cl[0][0], cl[0][2]]
		s["to"] = [cl[cl.size() / 3][0], cl[cl.size() / 3][2]]
		s["scenery"] = "all"
	for other in layout.segments:
		other.erase("full")
	layout.segments.append(s)
	while layout.connectors.size() < layout.segments.size():
		layout.connectors.append({"loop": false})
	sel = layout.segments.size() - 1
	ensure_analysis(sid)
	_refresh_segments()


func remove_segment() -> void:
	if layout.segments.size() <= 1:
		return
	layout.segments.remove_at(sel)
	if sel < layout.connectors.size():
		layout.connectors.remove_at(sel)
	sel = clampi(sel, 0, layout.segments.size() - 1)
	_refresh_segments()


func _move_segment(d: int) -> void:
	var j := sel + d
	if j < 0 or j >= layout.segments.size():
		return
	var tmp: Dictionary = layout.segments[sel]
	layout.segments[sel] = layout.segments[j]
	layout.segments[j] = tmp
	sel = j
	_refresh_segments()


func _build_segment_box() -> void:
	for c in seg_box.get_children():
		c.queue_free()
	var s := seg()
	if s.is_empty():
		return
	var g := GridContainer.new()
	g.columns = 2
	seg_box.add_child(g)
	_lbl(g, "Track")
	var src_pick := OptionButton.new()
	var i := 0
	for sid in sources:
		src_pick.add_item(String(sources[sid].get("name", sid)))
		src_pick.set_item_metadata(i, sid)
		if sid == s.source:
			src_pick.select(i)
		i += 1
	src_pick.item_selected.connect(func(ix: int) -> void:
		var sid2: String = src_pick.get_item_metadata(ix)
		s["source"] = sid2
		ensure_analysis(sid2)
		if String(sources[sid2].centreline.method) == "groups":
			s.erase("from"); s.erase("to"); s.erase("via")
			s["groups"] = [0, 60]
		else:
			s.erase("groups")
			var cl: Array = analysis.get(sid2, {}).get("centreline", [[0, 0, 0]])
			s["from"] = [cl[0][0], cl[0][2]]
			s["to"] = [cl[cl.size() / 3][0], cl[cl.size() / 3][2]]
		_refresh_segments())
	g.add_child(src_pick)
	var method := String(sources.get(s.source, {}).get("centreline", {}).get("method", "groups"))
	_lbl(g, "Use")
	var full := CheckBox.new()
	full.text = "whole loop (only segment)"
	full.button_pressed = bool(s.get("full", false))
	full.toggled.connect(func(on: bool) -> void:
		if on:
			layout.segments = [s]
			layout.connectors = []
			sel = 0
			s["full"] = true
		else:
			s.erase("full")
		_refresh_segments())
	g.add_child(full)
	if not s.get("full", false):
		if method == "groups":
			if not s.has("groups"):
				s["groups"] = [0, 60]
			_lbl(g, "Pieces")
			var h := HBoxContainer.new()
			g.add_child(h)
			_spin(h, 0, 999, 1, s.groups[0], func(x: float) -> void: s.groups[0] = int(x); canvas.queue_redraw())
			_spin(h, 0, 999, 1, s.groups[1], func(x: float) -> void: s.groups[1] = int(x); canvas.queue_redraw())
			_btn(h, "Pick", func() -> void: _set_pick("first"))
			_btn(h, "Pick", func() -> void: _set_pick("last"))
		else:
			for key in ["from", "to", "via"]:
				_lbl(g, key.capitalize())
				var h2 := HBoxContainer.new()
				g.add_child(h2)
				var val: Array = s.get(key, [0.0, 0.0])
				var k2: String = key
				var sx := _spin(h2, -9999, 9999, 0.5, val[0], func(x: float) -> void: _set_pt(s, k2, 0, x))
				var sz := _spin(h2, -9999, 9999, 0.5, val[1], func(z: float) -> void: _set_pt(s, k2, 1, z))
				if key == "via" and not s.has("via"):
					sx.editable = false
					sz.editable = false
				_btn(h2, "Pick", func() -> void: _set_pick(k2))
		_lbl(g, "Scenery")
		var sc := OptionButton.new()
		sc.add_item("all (keep whole track)")
		sc.add_item("near (only around the road)")
		sc.select(0 if String(s.get("scenery", "near")) == "all" else 1)
		sc.item_selected.connect(func(ix: int) -> void: s["scenery"] = "all" if ix == 0 else "near")
		g.add_child(sc)
		_lbl(g, "Offset x / z")
		var h3 := HBoxContainer.new()
		g.add_child(h3)
		var off: Array = s.get("offset", [0.0, "auto", 0.0])
		s["offset"] = off
		_spin(h3, -9999, 9999, 1, float(off[0]), func(x: float) -> void: off[0] = x; canvas.queue_redraw())
		_spin(h3, -9999, 9999, 1, float(off[2]), func(z: float) -> void: off[2] = z; canvas.queue_redraw())
		_lbl(g, "Height")
		var h4 := HBoxContainer.new()
		g.add_child(h4)
		var auto := CheckBox.new()
		auto.text = "auto"
		auto.button_pressed = String(off[1]) == "auto"
		h4.add_child(auto)
		var hy := _spin(h4, -999, 999, 0.5, 0.0 if String(off[1]) == "auto" else float(off[1]), func(y: float) -> void: off[1] = y)
		hy.editable = not auto.button_pressed
		auto.toggled.connect(func(on: bool) -> void:
			off[1] = "auto" if on else hy.value
			hy.editable = not on)
		_lbl(g, "Yaw (deg)")
		_spin(g, -360, 360, 1, float(s.get("yaw", 0.0)), func(y: float) -> void: s["yaw"] = y; canvas.queue_redraw())
		while layout.connectors.size() < layout.segments.size():
			layout.connectors.append({"loop": false})
		var cc: Dictionary = layout.connectors[sel]
		_lbl(g, "Connector after")
		var lp := CheckBox.new()
		lp.text = "vertical loop"
		lp.button_pressed = bool(cc.get("loop", false))
		lp.toggled.connect(func(on: bool) -> void: cc["loop"] = on; _refresh_segments())
		g.add_child(lp)


func _set_pt(s: Dictionary, key: String, axis: int, v: float) -> void:
	if _building:
		return
	var p: Array = s.get(key, [0.0, 0.0])
	p[axis] = v
	s[key] = p
	canvas.queue_redraw()


func _set_pick(what: String) -> void:
	pick = what
	log_line("Click on the map to set %s." % what)


## Called by the canvas with a world-space click.
func picked(world: Vector2) -> void:
	if pick == "":
		return
	var what := pick
	pick = ""
	if what == "start":
		var best := 0
		var best_d := INF
		for i in layout.segments.size():
			var pts := segment_points(i)
			for p in pts:
				var d := p.distance_to(world)
				if d < best_d:
					best_d = d
					best = i
		var src_xz := to_source(layout.segments[best], world)
		_start()["segment"] = best
		_start()["at"] = [snappedf(src_xz.x, 0.5), snappedf(src_xz.y, 0.5)]
		start_seg.value = best
		canvas.queue_redraw()
		return
	var s := seg()
	var local := to_source(s, world)
	if what in ["first", "last"]:
		var a: Dictionary = analysis.get(s.source, {})
		var best_id := 0
		var best_d := INF
		for pc in a.get("pieces", []):
			var d := Vector2(pc[1], pc[3]).distance_to(local)
			if d < best_d:
				best_d = d
				best_id = int(pc[0])
		s.groups[0 if what == "first" else 1] = best_id
	else:
		s[what] = [snappedf(local.x, 0.5), snappedf(local.y, 0.5)]
	_refresh_segments()


# --- geometry for drawing ----------------------------------------------------------

static func rot(p: Vector2, yaw_deg: float) -> Vector2:
	var a := deg_to_rad(yaw_deg)
	return Vector2(p.x * cos(a) + p.y * sin(a), -p.x * sin(a) + p.y * cos(a))


func to_world(s: Dictionary, p: Vector2) -> Vector2:
	var off: Array = s.get("offset", [0.0, 0.0, 0.0])
	return rot(p, float(s.get("yaw", 0.0))) + Vector2(float(off[0]), float(off[2]))


func to_source(s: Dictionary, w: Vector2) -> Vector2:
	var off: Array = s.get("offset", [0.0, 0.0, 0.0])
	return rot(w - Vector2(float(off[0]), float(off[2])), -float(s.get("yaw", 0.0)))


## Whole source centreline (world space) - drawn faint.
func source_points(i: int) -> PackedVector2Array:
	var s := seg(i)
	var a: Dictionary = analysis.get(s.get("source", ""), {})
	var out := PackedVector2Array()
	if a.has("centreline"):
		for p in a.centreline:
			out.append(to_world(s, Vector2(p[0], p[2])))
	else:
		for p in a.get("pieces", []):
			out.append(to_world(s, Vector2(p[1], p[3])))
	return out


## The part of the source this segment uses, in driving order (world space).
func segment_points(i: int) -> PackedVector2Array:
	var s := seg(i)
	var a: Dictionary = analysis.get(s.get("source", ""), {})
	var out := PackedVector2Array()
	if a.has("centreline"):
		var cl: Array = a.centreline
		var n := cl.size()
		if s.get("full", false):
			for p in cl:
				out.append(to_world(s, Vector2(p[0], p[2])))
			return out
		var i0 := _nearest(cl, s.get("from", [0, 0]))
		var i1 := _nearest(cl, s.get("to", [0, 0]))
		var fwd_len := posmod(i1 - i0, n)
		var use_fwd := fwd_len >= n - fwd_len
		if s.has("via"):
			use_fwd = posmod(_nearest(cl, s.via) - i0, n) <= fwd_len
		var steps := fwd_len if use_fwd else posmod(i0 - i1, n)
		for k in steps + 1:
			var j := posmod(i0 + k, n) if use_fwd else posmod(i0 - k, n)
			out.append(to_world(s, Vector2(cl[j][0], cl[j][2])))
	else:
		var lo := 0
		var hi := 99999
		if not s.get("full", false):
			lo = int(s.groups[0])
			hi = int(s.groups[1])
		for p in a.get("pieces", []):
			if int(p[0]) >= lo and int(p[0]) <= hi:
				out.append(to_world(s, Vector2(p[1], p[3])))
	return out


func branch_points(i: int) -> Array:
	var s := seg(i)
	var a: Dictionary = analysis.get(s.get("source", ""), {})
	var out: Array = []
	for b in a.get("branches", []):
		var pts := PackedVector2Array()
		for p in b.pieces:
			pts.append(to_world(s, Vector2(p[1], p[3])))
		out.append(pts)
	return out


static func _nearest(cl: Array, xz: Array) -> int:
	var best := 0
	var best_d := INF
	var q := Vector2(float(xz[0]), float(xz[1]))
	for k in cl.size():
		var d := Vector2(cl[k][0], cl[k][2]).distance_squared_to(q)
		if d < best_d:
			best_d = d
			best = k
	return best
