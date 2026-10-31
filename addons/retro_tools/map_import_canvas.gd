@tool
extends Control
## Top-down 2D check view for the Map Importer dock.
##
## Draws every surface of the model flat, coloured by what it is, so the road can be
## checked and picked by eye before and after tracing. The traced centreline goes on
## top with the width the game will actually use, plus checkpoints, the grid slots and
## the start line.
##
## wheel zooms, right/middle drag pans. A left click does whatever the dock's mode
## says: check a surface, make it the road, add it as another road surface, make it a
## wall, or put the start line where you clicked.

const CLASS_ORDER := ["off", "deco", "road", "wall"]
## Topmost first: the reverse of CLASS_ORDER, so a click picks what is drawn on top.
const PICK_ORDER := ["wall", "road", "deco", "off"]
const CLASS_COLOURS := {
	"road": Color(0.68, 0.69, 0.74),
	"off": Color(0.23, 0.35, 0.21),
	"wall": Color(0.76, 0.37, 0.24),
	"deco": Color(0.31, 0.39, 0.52),
}
const GRID := 25.0

var dock: Node = null
var zoom := 0.6               ## pixels per metre
var pan := Vector2.ZERO       ## world (x, z) at the centre of the view
var mode := ""                ## "" check, road, alt, wall, start
var picked := -1              ## surface chosen with a left click in check mode

var _tris: Array = []         ## per surface: Array of PackedVector2Array (x, z)
var _rects: Array = []        ## per surface: Array of Rect2 (world bounds per triangle)
var _bounds := Rect2()
var _cache_scale := -1.0
var _cache_tris := -1
var _hover := -1
var _drag := ""
var _last := Vector2.ZERO

## Snapshot of the last trace, so drawing does not re-measure the path every frame.
var _path := PackedVector2Array()
var _widths := PackedFloat32Array()
var _cps: Array = []
var _slots: Array = []
var _start := Vector2.ZERO
var _start_fwd := Vector2.RIGHT
var _lap := 0.0
var _closed := false


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, 300)
	size_flags_vertical = Control.SIZE_EXPAND_FILL


# ------------------------------------------------------------------ view

func w2s(w: Vector2) -> Vector2:
	return (w - pan) * zoom + size * 0.5


func s2w(s: Vector2) -> Vector2:
	return (s - size * 0.5) / zoom + pan


func _view_rect() -> Rect2:
	var tl := s2w(Vector2.ZERO)
	var br := s2w(size)
	return Rect2(tl, br - tl)


## Frames the whole model.
func fit() -> void:
	_ensure_cache()
	if _bounds.size == Vector2.ZERO:
		return
	pan = _bounds.get_center()
	var s := size if size.x > 10.0 else Vector2(600, 300)
	zoom = clampf(minf(s.x / (_bounds.size.x + 40.0), s.y / (_bounds.size.y + 40.0)), 0.02, 20.0)
	queue_redraw()


## Forgets the geometry and the trace: call after loading a model or changing its
## scale, so a previous course's racing line is not left on the screen.
func invalidate() -> void:
	_tris.clear()
	_rects.clear()
	_bounds = Rect2()
	_cache_scale = -1.0
	_cache_tris = -1
	_hover = -1
	picked = -1
	_path = PackedVector2Array()
	_widths = PackedFloat32Array()
	_cps = []
	_slots = []
	_lap = 0.0
	_closed = false
	queue_redraw()


## Takes a snapshot of the centreline the dock just traced.
func on_trace() -> void:
	_path = PackedVector2Array()
	_widths = PackedFloat32Array()
	_cps = []
	_slots = []
	_lap = 0.0
	_closed = false
	if dock == null or dock.imp == null:
		queue_redraw()
		return
	var imp = dock.imp
	var pts: Array[Vector3] = imp.path()
	for p in pts:
		_path.append(Vector2(p.x, p.z))
	_widths = imp.path_widths()
	if _path.size() >= 2:
		_start = _path[0]
		_start_fwd = (_path[1] - _path[0]).normalized()
	_lap = imp.path_length()
	_closed = bool(imp.report.get("closed", false))
	_cps = imp.checkpoint_indices()
	_slots = imp.grid_slots()
	if not pts.is_empty():
		_start = Vector2(pts[0].x, pts[0].z)
	queue_redraw()


# ------------------------------------------------------------------ geometry cache

func _ensure_cache() -> void:
	if dock == null or dock.imp == null:
		return
	var imp = dock.imp
	if _tris.size() == imp.surfaces.size() and is_equal_approx(_cache_scale, float(imp.scale)) \
			and _cache_tris == imp.chunks.size():
		return
	# Display geometry needs the scaled, centred positions build() prepares.
	imp.prepare()
	_cache_scale = float(imp.scale)
	_cache_tris = imp.chunks.size()
	_tris.clear()
	_rects.clear()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for si in imp.surfaces.size():
		var tris: Array = []
		var rects: Array = []
		for ci in imp.surfaces[si]["chunks"]:
			var np: PackedVector3Array = imp._npos[int(ci)]
			var idx: PackedInt32Array = imp.chunks[int(ci)].idx
			for t in range(0, idx.size() - 2, 3):
				var a := Vector2(np[idx[t]].x, np[idx[t]].z)
				var b := Vector2(np[idx[t + 1]].x, np[idx[t + 1]].z)
				var c := Vector2(np[idx[t + 2]].x, np[idx[t + 2]].z)
				var tri := PackedVector2Array([a, b, c])
				tris.append(tri)
				var r := Rect2(a, Vector2.ZERO).expand(b).expand(c)
				rects.append(r)
				if String(imp.surfaces[si]["class"]) != "skip":
					lo = lo.min(r.position)
					hi = hi.max(r.end)
		_tris.append(tris)
		_rects.append(rects)
	_bounds = Rect2(lo, hi - lo) if lo.x <= hi.x else Rect2()
	if pan == Vector2.ZERO:
		fit()


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.10, 0.12, 0.16))
	_draw_grid()
	if dock == null or dock.imp == null or dock.imp.surfaces.is_empty():
		_hint("Load a track model to check its road here.")
		return
	_ensure_cache()
	var imp = dock.imp
	for cls in CLASS_ORDER:
		for si in imp.surfaces.size():
			if String(imp.surfaces[si]["class"]) == cls:
				_draw_surface(si, imp)
	# Surfacing what the mouse is over / what was picked, on top of the rest.
	for si in [_hover, picked]:
		if int(si) >= 0 and int(si) < _tris.size() and String(imp.surfaces[int(si)]["class"]) != "skip":
			_draw_surface(int(si), imp, Color(1, 1, 1, 0.22 if int(si) == _hover else 0.34))
	_draw_trace()
	_draw_hud()


func _draw_grid() -> void:
	var view := _view_rect()
	var step := GRID
	while (view.size.x / step) > 80.0:
		step *= 4.0
	var x := floorf(view.position.x / step) * step
	while x < view.end.x:
		var col := Color(1, 1, 1, 0.10 if is_zero_approx(fmod(x, step * 4.0)) else 0.05)
		draw_line(w2s(Vector2(x, view.position.y)), w2s(Vector2(x, view.end.y)), col, 1.0)
		x += step
	var z := floorf(view.position.y / step) * step
	while z < view.end.y:
		var col := Color(1, 1, 1, 0.10 if is_zero_approx(fmod(z, step * 4.0)) else 0.05)
		draw_line(w2s(Vector2(view.position.x, z)), w2s(Vector2(view.end.x, z)), col, 1.0)
		z += step


func _draw_surface(si: int, imp, tint := Color(0, 0, 0, 0)) -> void:
	var cls := String(imp.surfaces[si]["class"])
	var col: Color = CLASS_COLOURS.get(cls, Color(0.4, 0.4, 0.4))
	if tint.a > 0.0:
		col = tint
	else:
		var shade := 1.0 - 0.07 * float(si % 4)
		col = Color(col.r * shade, col.g * shade, col.b * shade,
			0.6 if bool(imp.surfaces[si]["alpha"]) else 1.0)
	var view := _view_rect()
	var tris: Array = _tris[si]
	var rects: Array = _rects[si]
	for i in tris.size():
		if not view.intersects(rects[i]):
			continue
		var t: PackedVector2Array = tris[i]
		var a := w2s(t[0])
		var b := w2s(t[1])
		var c := w2s(t[2])
		# Walls are vertical, so seen from above they are slivers: skip anything with
		# no area on screen (the triangulator rejects those).
		if absf((b - a).cross(c - a)) < 0.4:
			continue
		draw_colored_polygon(PackedVector2Array([a, b, c]), col)


func _draw_trace() -> void:
	if _path.size() < 2:
		return
	var n := _path.size()
	# The width the game will give every sample, so a too-wide or too-narrow trace shows.
	for i in n:
		var j := (i + 1) % n
		if not _closed and j == 0:
			break
		var w := ((_widths[i] if i < _widths.size() else 10.0) + (_widths[j] if j < _widths.size() else 10.0)) * 0.5
		draw_line(w2s(_path[i]), w2s(_path[j]), Color(0.45, 0.75, 1.0, 0.20), maxf(w * zoom, 2.0))
	var pts := PackedVector2Array()
	for p in _path:
		pts.append(w2s(p))
	if _closed:
		pts.append(pts[0])
	draw_polyline(pts, Color(1.0, 0.86, 0.25), 2.0, true)
	# Direction of travel.
	var every := maxi(1, n / 24)
	for i in range(0, n, every):
		var j := (i + every) % n
		var d := (_path[j] - _path[i]).normalized()
		if d == Vector2.ZERO:
			continue
		var p := w2s(_path[i])
		var side := Vector2(-d.y, d.x)
		draw_colored_polygon(PackedVector2Array([p + d * 5.0, p - d * 3.0 + side * 3.5,
			p - d * 3.0 - side * 3.5]), Color(1.0, 0.86, 0.25, 0.9))
	# Checkpoints.
	for c in _cps:
		var i := int(c)
		if i >= n:
			continue
		var j := (i + 1) % n
		var d := (_path[j] - _path[i]).normalized()
		var side := Vector2(-d.y, d.x)
		var half: float = (_widths[i] if i < _widths.size() else 10.0) * 0.5
		draw_line(w2s(_path[i] - side * half), w2s(_path[i] + side * half), Color(0.85, 0.35, 0.95), 2.0)
	# Starting grid.
	for slot in _slots:
		var pos: Array = slot["pos"]
		var p := w2s(Vector2(float(pos[0]), float(pos[2])))
		draw_rect(Rect2(p - Vector2(2, 2), Vector2(4, 4)), Color(1, 1, 1, 0.85))
	# Start / finish line, straight across the road where the lap begins.
	var side2 := Vector2(-_start_fwd.y, _start_fwd.x)
	var half2: float = (_widths[0] if _widths.size() > 0 else 10.0) * 0.5
	var a := w2s(_start - side2 * half2)
	var b := w2s(_start + side2 * half2)
	draw_line(a, b, Color(0.05, 0.05, 0.05), 6.0)
	draw_line(a, b, Color(1, 1, 1), 3.0)
	draw_circle(w2s(_start), 3.5, Color(1.0, 0.3, 0.3))


func _draw_hud() -> void:
	var font := get_theme_default_font()
	var lines: Array = []
	if dock != null and dock.imp != null and not dock.imp.surfaces.is_empty():
		var name := String(dock.imp.display_name)
		if dock.imp.id == "":
			name = String(dock.imp.source_path).get_file()
		lines.append(name)
		if _path.size() > 1:
			lines.append("lap %.0f m · %d samples · width %.1f - %.1f m" % [_lap, _path.size(),
				float(dock.imp.report.get("width_min", 0.0)), float(dock.imp.report.get("width_max", 0.0))])
		else:
			lines.append("not traced yet - press Analyse")
		lines.append("wheel zoom · right-drag pan · %.1f px/m" % zoom)
		var hi := _hover if _hover >= 0 else picked
		if hi >= 0 and hi < dock.imp.surfaces.size():
			var s: Dictionary = dock.imp.surfaces[hi]
			lines.append("%s · %s · %d tris" % [String(s["name"]), String(s["class"]), int(s["tris"])])
	var w := 0.0
	for l in lines:
		w = maxf(w, font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x)
	if not lines.is_empty():
		draw_rect(Rect2(6, 6, w + 12, 4 + lines.size() * 16), Color(0, 0, 0, 0.45))
		for i in lines.size():
			draw_string(font, Vector2(12, 21 + i * 16), String(lines[i]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.92, 0.95, 1.0))
	draw_string(font, Vector2(10, size.y - 10), _mode_hint(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		Color(1, 1, 1, 0.75))
	# Legend.
	var legend := [["road", "road"], ["off", "off-road"], ["wall", "wall"], ["deco", "decoration"]]
	var lx := size.x - 96.0
	for i in legend.size():
		var ly := 16.0 + i * 14.0
		draw_rect(Rect2(lx, ly - 8, 9, 9), CLASS_COLOURS[legend[i][0]])
		draw_string(font, Vector2(lx + 14, ly), String(legend[i][1]), HORIZONTAL_ALIGNMENT_LEFT,
			-1, 11, Color(1, 1, 1, 0.75))


func _hint(text: String) -> void:
	var font := get_theme_default_font()
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(font, Vector2((size.x - w) * 0.5, size.y * 0.5), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.5))


func _mode_hint() -> String:
	match mode:
		"road":
			return "click a surface to trace it as the road"
		"alt":
			return "click a surface to add or remove it as road"
		"wall":
			return "click a surface to make it a wall"
		"start":
			return "click the road to put the start line there"
		_:
			return "click a surface to inspect it"


# ------------------------------------------------------------------ input

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(mb.position, 1.2)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, 1.0 / 1.2)
		elif mb.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_drag = "pan" if mb.pressed else ""
			_last = mb.position
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			click_at(mb.position)
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _drag == "pan":
			pan -= (mm.position - _last) / zoom
			_last = mm.position
			queue_redraw()
		else:
			var h := surface_at(s2w(mm.position))
			if h != _hover:
				_hover = h
				queue_redraw()
	elif e is InputEventPanGesture:
		pan += (e as InputEventPanGesture).delta * 8.0 / zoom
		queue_redraw()


func _zoom_at(p: Vector2, f: float) -> void:
	var before := s2w(p)
	zoom = clampf(zoom * f, 0.02, 40.0)
	pan += before - s2w(p)
	queue_redraw()


## Left click at a view position: what it does depends on the dock's mode.
func click_at(p: Vector2) -> void:
	if dock == null or dock.imp == null or dock.imp.surfaces.is_empty():
		return
	var at := s2w(p)
	match mode:
		"start":
			dock.canvas_set_start(at)
		"road", "alt", "wall":
			var si := surface_at(at)
			if si < 0:
				dock.canvas_note("Nothing there - click on a surface.")
			elif mode == "road":
				dock.canvas_set_road(si)
			elif mode == "alt":
				dock.canvas_toggle_alt(si)
			else:
				dock.canvas_set_class(si, "wall")
		_:
			picked = surface_at(at)
			dock.canvas_picked(picked)
	queue_redraw()


## Topmost surface under a map-space point: road wins over wall, then off, then deco.
func surface_at(w: Vector2) -> int:
	if dock == null or dock.imp == null:
		return -1
	_ensure_cache()
	for cls in PICK_ORDER:
		for si in _tris.size():
			if String(dock.imp.surfaces[si]["class"]) != cls:
				continue
			var tris: Array = _tris[si]
			var rects: Array = _rects[si]
			for i in tris.size():
				if not rects[i].has_point(w):
					continue
				if _in_tri(w, tris[i]):
					return si
	return -1


static func _in_tri(p: Vector2, t: PackedVector2Array) -> bool:
	# Degenerate triangles (walls seen from above are lines) have no inside: without
	# this every point would test positive on them.
	var area := (t[1] - t[0]).cross(t[2] - t[0])
	if absf(area) < 1e-4:
		return false
	var d1 := (p - t[1]).cross(t[0] - t[1])
	var d2 := (p - t[2]).cross(t[1] - t[2])
	var d3 := (p - t[0]).cross(t[2] - t[0])
	var neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (neg and pos)
