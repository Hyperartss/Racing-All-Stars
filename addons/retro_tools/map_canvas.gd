@tool
extends Control
## Top-down view for the Map Combiner dock.

var dock: Node
var zoom := 1.5            ## pixels per metre
var pan := Vector2.ZERO    ## world point at the centre of the view
var _drag := ""
var _last := Vector2.ZERO

const SEG_COLOURS := [Color(1, 0.82, 0.25), Color(0.4, 0.8, 1), Color(1, 0.5, 0.8), Color(0.6, 1, 0.5), Color(1, 0.6, 0.3)]


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(300, 300)


func w2s(w: Vector2) -> Vector2:
	return (w - pan) * zoom + size * 0.5


func s2w(s: Vector2) -> Vector2:
	return (s - size * 0.5) / zoom + pan


func fit() -> void:
	var pts := PackedVector2Array()
	for i in dock.layout.segments.size():
		pts.append_array(dock.source_points(i))
	if pts.is_empty():
		return
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	pan = r.get_center()
	var s := size if size.x > 10 else Vector2(600, 340)
	zoom = clampf(minf(s.x / (r.size.x + 60.0), s.y / (r.size.y + 60.0)), 0.2, 10.0)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.09, 0.2))
	# grid every 50 m
	var tl := s2w(Vector2.ZERO)
	var br := s2w(size)
	var step := 50.0
	var x := floorf(tl.x / step) * step
	while x < br.x:
		draw_line(w2s(Vector2(x, tl.y)), w2s(Vector2(x, br.y)), Color(1, 1, 1, 0.05))
		x += step
	var z := floorf(tl.y / step) * step
	while z < br.y:
		draw_line(w2s(Vector2(tl.x, z)), w2s(Vector2(br.x, z)), Color(1, 1, 1, 0.05))
		z += step
	if dock == null or dock.layout.is_empty():
		return
	var segs: Array = dock.layout.segments
	var ends := []
	for i in segs.size():
		var col: Color = SEG_COLOURS[i % SEG_COLOURS.size()]
		var whole: PackedVector2Array = dock.source_points(i)
		_poly(whole, Color(col, 0.18), 2.0, dock.seg(i).get("full", false) or analysis_closed(i))
		for b in dock.branch_points(i):
			_poly(b, Color(col, 0.18), 2.0, false)
		var pts: PackedVector2Array = dock.segment_points(i)
		var w := 10.0 * zoom if i == dock.sel else 6.0 * zoom
		_poly(pts, Color(col, 0.95 if i == dock.sel else 0.7), maxf(w, 2.0), dock.seg(i).get("full", false))
		if pts.size() >= 2:
			draw_circle(w2s(pts[0]), 5, Color(0.3, 1, 0.3))
			draw_circle(w2s(pts[pts.size() - 1]), 5, Color(1, 0.3, 0.3))
			draw_string(get_theme_default_font(), w2s(pts[pts.size() / 2]) + Vector2(8, -8), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
			ends.append([pts[pts.size() - 2], pts[pts.size() - 1], pts[0], pts[1]])
	# connectors: Hermite from the end of i to the start of i+1 (as the bake does)
	if segs.size() > 1:
		for i in ends.size():
			var a: Array = ends[i]
			var b: Array = ends[(i + 1) % ends.size()]
			var p0: Vector2 = a[1]
			var t0: Vector2 = (a[1] - a[0]).normalized()
			var p1: Vector2 = b[2]
			var t1: Vector2 = (b[3] - b[2]).normalized()
			var chord := p0.distance_to(p1)
			var curve := PackedVector2Array()
			for k in 33:
				var s := k / 32.0
				var h00 := 2 * s * s * s - 3 * s * s + 1
				var h10 := s * s * s - 2 * s * s + s
				var h01 := -2 * s * s * s + 3 * s * s
				var h11 := s * s * s - s * s
				curve.append(p0 * h00 + t0 * chord * 1.1 * h10 + p1 * h01 + t1 * chord * 1.1 * h11)
			var loop: bool = i < dock.layout.connectors.size() and bool(dock.layout.connectors[i].get("loop", false))
			_poly(curve, Color(0.45, 0.7, 1.0, 0.9), maxf(11.0 * zoom, 2.0), false)
			if loop:
				var m := w2s(p0 + t0 * maxf(30.0, chord * 0.3))
				draw_arc(m, 11.0 * zoom, 0, TAU, 24, Color(1, 1, 1), 2.0)
	# start line
	var st: Dictionary = dock.layout.get("start", {})
	var si := int(st.get("segment", 0))
	if si < segs.size():
		var sp: Vector2
		if st.has("at"):
			sp = dock.to_world(dock.seg(si), Vector2(st.at[0], st.at[1]))
		else:
			var pts2: PackedVector2Array = dock.segment_points(si)
			sp = pts2[0] if pts2.size() > 0 else Vector2.ZERO
		draw_string(get_theme_default_font(), w2s(sp) + Vector2(-6, 6), "★", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.WHITE)
	var hint := "wheel zoom · right-drag pan · drag segment to move · shift-drag rotate"
	if dock.pick != "":
		hint = "click to set: " + dock.pick
	draw_string(get_theme_default_font(), Vector2(8, size.y - 8), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.7))


func analysis_closed(i: int) -> bool:
	return bool(dock.analysis.get(dock.seg(i).get("source", ""), {}).get("closed", false))


func _poly(pts: PackedVector2Array, col: Color, width: float, closed: bool) -> void:
	if pts.size() < 2:
		return
	var s := PackedVector2Array()
	for p in pts:
		s.append(w2s(p))
	if closed:
		s.append(s[0])
	draw_polyline(s, col, width, true)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(mb.position, 1.15)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, 1.0 / 1.15)
		elif mb.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_drag = "pan" if mb.pressed else ""
			_last = mb.position
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if dock.pick != "":
					dock.picked(s2w(mb.position))
					queue_redraw()
					return
				_drag = "rotate" if mb.shift_pressed else "move"
				_last = mb.position
			else:
				_drag = ""
				dock._build_segment_box()
	elif e is InputEventMouseMotion and _drag != "":
		var mm := e as InputEventMouseMotion
		var s: Dictionary = dock.seg()
		if _drag == "pan":
			pan -= (mm.position - _last) / zoom
		elif _drag == "move" and not s.is_empty() and not s.get("full", false):
			var d := (mm.position - _last) / zoom
			var off: Array = s.get("offset", [0.0, "auto", 0.0])
			off[0] = snappedf(float(off[0]) + d.x, 0.5)
			off[2] = snappedf(float(off[2]) + d.y, 0.5)
			s["offset"] = off
		elif _drag == "rotate" and not s.is_empty() and not s.get("full", false):
			# rotate about the segment's centre, keeping it in place
			var pts: PackedVector2Array = dock.segment_points(dock.sel)
			var c := Vector2.ZERO
			for p in pts:
				c += p
			c /= maxf(pts.size(), 1)
			var src_c: Vector2 = dock.to_source(s, c)
			s["yaw"] = snappedf(float(s.get("yaw", 0.0)) + (mm.position.x - _last.x) * 0.5, 1.0)
			var off2: Array = s.get("offset", [0.0, "auto", 0.0])
			var placed: Vector2 = dock.rot(src_c, float(s.yaw))
			off2[0] = c.x - placed.x
			off2[2] = c.y - placed.y
			s["offset"] = off2
		_last = mm.position
		queue_redraw()


func _zoom_at(p: Vector2, f: float) -> void:
	var before := s2w(p)
	zoom = clampf(zoom * f, 0.05, 20.0)
	pan += before - s2w(p)
	queue_redraw()
