@tool
extends Control
## Keyframe strip for the Animation Editor.
## Click or drag to scrub, right-click near a key to delete it. Frame ticks, key
## diamonds and the playhead are drawn directly, so it works in the editor.

signal seek(t: float)
signal key_delete(t: float)

var length := 1.0
var time := 0.0
var fps := 24.0
var keys := []


func _init() -> void:
	custom_minimum_size = Vector2(0, 36)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if not e.pressed:
			return
		if e.button_index == MOUSE_BUTTON_LEFT:
			seek.emit(_time_at(e.position.x))
			accept_event()
		elif e.button_index == MOUSE_BUTTON_RIGHT:
			key_delete.emit(_time_at(e.position.x))
			accept_event()
	elif e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		seek.emit(_time_at(e.position.x))
		accept_event()


func _time_at(x: float) -> float:
	return clampf((x - 4.0) / maxf(size.x - 8.0, 1.0), 0.0, 1.0) * length


func _draw() -> void:
	var w := maxf(size.x - 8.0, 1.0)
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.10, 0.11, 0.14))
	draw_rect(Rect2(Vector2.ZERO, size - Vector2.ONE), Color(0.32, 0.34, 0.42), false, 1.0)
	# Frame ticks; every 6th is a longer tick.
	var steps := clampi(int(ceil(length * fps)), 1, 240)
	for i in steps + 1:
		var x := 4.0 + w * float(i) / float(steps)
		var major := i % 6 == 0
		draw_line(Vector2(x, h - (9.0 if major else 5.0)), Vector2(x, h - 1.0),
			Color(0.42, 0.45, 0.55, 0.9))
	for k in keys:
		var kx := 4.0 + w * clampf(float(k) / maxf(length, 0.01), 0.0, 1.0)
		var c := Vector2(kx, h * 0.30)
		draw_colored_polygon(PackedVector2Array([
			c + Vector2(0, -5), c + Vector2(5, 0), c + Vector2(0, 5), c + Vector2(-5, 0)]),
			Color(1.0, 0.72, 0.18))
	var px := 4.0 + w * clampf(time / maxf(length, 0.01), 0.0, 1.0)
	draw_line(Vector2(px, 0), Vector2(px, h), Color(1.0, 0.34, 0.30), 2.0)
