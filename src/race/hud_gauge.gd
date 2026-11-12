class_name HudGauge
extends Control
## The drawn parts of the race HUD: item slot (with roulette), ring icon and the ink.

var hud: RaceHUD
var _icons := {}
var _t := 0.0
var _blots: Array = []


func _process(delta: float) -> void:
	_t += delta


func _draw() -> void:
	var r := hud.target() if hud != null else null
	if r == null or r.items == null:
		return
	var it: RacerItems = r.items
	var ks := hud.k
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(ks, ks))
	# Item slot
	var box := Rect2(10, 8, 56, 56)
	draw_rect(box, Color(0.05, 0.06, 0.2, 0.8))
	draw_rect(box, Color(1, 0.86, 0.25), false, 2.0)
	var show := it.slot
	if it.rolling > 0.0:
		var ids := ItemTypes.items().keys()
		if not ids.is_empty():
			show = String(ids[int(_t * 14.0) % ids.size()])
	if show != "":
		_draw_icon(show, box.grow(-6))
		if it.uses > 1 and it.rolling <= 0.0:
			draw_string(get_theme_default_font(), Vector2(box.end.x - 20, box.end.y - 4), "x%d" % it.uses,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
	# Ring icon beside the counter
	draw_arc(Vector2(10 + 7, 81), 6.0, 0, TAU, 12, Color(1, 0.82, 0.2), 3.0)
	# Ink
	if it.ink_timer > 0.0:
		if _blots.is_empty():
			for k in 9:
				_blots.append([Vector2(randf_range(0.15, 0.85), randf_range(0.2, 0.8)), randf_range(30.0, 80.0)])
		var a := clampf(it.ink_timer / 1.2, 0.0, 1.0) * 0.92
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		var sz := size
		for b in _blots:
			draw_circle(Vector2(b[0].x * sz.x, b[0].y * sz.y), float(b[1]), Color(0.06, 0.05, 0.1, a))
	else:
		_blots.clear()


func _draw_icon(item_id: String, rect: Rect2) -> void:
	var def := ItemTypes.item(item_id)
	var icon_path := String(def.get("icon", ""))
	if icon_path != "":
		if not _icons.has(icon_path):
			_icons[icon_path] = load(icon_path) if ResourceLoader.exists(icon_path) else null
		var tex: Texture2D = _icons[icon_path]
		if tex != null:
			draw_texture_rect(tex, rect, false)
			return
	var c := ItemTypes.icon_colour(item_id)
	var centre := rect.get_center()
	var rad := rect.size.x * 0.42
	match String(def.get("shape", "orb")):
		"shell", "spiny":
			draw_circle(centre + Vector2(0, 3), rad, Color(0.95, 0.93, 0.85))
			draw_circle(centre, rad * 0.85, c)
		"banana":
			draw_arc(centre + Vector2(6, -4), rad * 0.9, 1.6, 3.6, 10, c, 8.0)
		"star":
			var pts := PackedVector2Array()
			for k in 10:
				var a := -PI * 0.5 + TAU * k / 10.0
				pts.append(centre + Vector2(cos(a), sin(a)) * (rad if k % 2 == 0 else rad * 0.45))
			draw_colored_polygon(pts, c)
		"box", "fake_box":
			draw_rect(Rect2(centre - Vector2(rad, rad), Vector2(rad, rad) * 2.0), Color(c.r, c.g, c.b, 0.7))
		"ring":
			draw_arc(centre, rad * 0.8, 0, TAU, 16, c, 6.0)
		"bolt":
			draw_colored_polygon(PackedVector2Array([centre + Vector2(4, -rad), centre + Vector2(-8, 2),
				centre + Vector2(0, 2), centre + Vector2(-4, rad), centre + Vector2(8, -2), centre + Vector2(0, -2)]), c)
		_:
			draw_circle(centre, rad, c)
