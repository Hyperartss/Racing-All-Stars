@tool
extends TrackObject
## Sonic R ring door: a solid gate across a shortcut with a price on it. Touch it
## with enough rings and it takes them and slides open; it closes again after
## `open_seconds` (0 = stays open for the rest of the race).
## The door faces along the object's -Z: drive "through" it along the facing.

const BEHAVIOUR := "door"
const LABEL := "Ring door (pay to open)"
const PARAMS := {
	"cost": {"type": "int", "default": 20, "min": 0, "max": 999, "hint": "Rings it takes to open"},
	"width": {"type": "float", "default": 6.0, "min": 1.0, "max": 40.0, "step": 0.25},
	"height": {"type": "float", "default": 4.0, "min": 1.0, "max": 20.0, "step": 0.25},
	"thickness": {"type": "float", "default": 0.4, "min": 0.1, "max": 4.0, "step": 0.05},
	"open_seconds": {"type": "float", "default": 6.0, "min": 0.0, "max": 120.0, "step": 0.5, "hint": "0 = stays open once bought"},
	"ai_buys": {"type": "bool", "default": true, "hint": "AI racers that touch it with enough rings open it too"},
	"frame_colour": {"type": "color", "default": "#d8d3c4"},
}

var _panel: Node3D
var _shape: CollisionShape3D
var _label: Label3D
var _open := 0.0              ## 0 closed .. 1 open
var _target := 0.0
var _timer := 0.0
var _msg_cool := 0.0


func build() -> void:
	var w := float(p.width)
	var h := float(p.height)
	var t := float(p.thickness)
	var frame := Color.html(String(p.frame_colour))
	for side in [-1.0, 1.0]:
		ItemModels._part(self, ItemModels._box(Vector3(0.5, h + 0.6, t + 0.3)), frame, Vector3(side * (w * 0.5 + 0.25), (h + 0.6) * 0.5, 0))
	ItemModels._part(self, ItemModels._box(Vector3(w + 1.0, 0.5, t + 0.3)), frame, Vector3(0, h + 0.55, 0))
	_panel = Node3D.new()
	add_child(_panel)
	if String(def.get("model", "")) != "":
		var m := model()
		_panel.add_child(m)
	else:
		ItemModels._part(_panel, ItemModels._box(Vector3(w, h, t)), colour(), Vector3(0, h * 0.5, 0))
		var ring := ItemModels.build("ring", Color("ffd23a"))
		ring.position = Vector3(0, h * 0.62 - 0.7, -t * 0.5 - 0.05)
		ring.rotation_degrees.y = 90.0
		_panel.add_child(ring)
	_label = Label3D.new()
	_label.text = str(int(p.cost))
	_label.font_size = 64
	_label.pixel_size = 0.012
	_label.outline_size = 10
	_label.modulate = Color(1, 0.9, 0.3)
	_label.position = Vector3(0, h * 0.3, -t * 0.5 - 0.06)
	_label.rotation_degrees.y = 180.0
	_label.double_sided = true
	_label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_panel.add_child(_label)
	var body := StaticBody3D.new()
	body.collision_layer = Track.LAYER_TRACK
	body.collision_mask = 0
	body.set_meta("surface", "wall")
	_shape = CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(w, h, t + 0.2)
	_shape.shape = bs
	_shape.position = Vector3(0, h * 0.5, 0)
	body.add_child(_shape)
	add_child(body)
	if editor:
		_shape.disabled = true


func is_open() -> bool:
	return _target > 0.5


func tick(delta: float) -> void:
	_msg_cool = maxf(0.0, _msg_cool - delta)
	if absf(_open - _target) > 0.001:
		_open = move_toward(_open, _target, delta * 2.5)
		_panel.position.y = _open * (float(p.height) - 0.3)
		_panel.scale.y = 1.0 - _open * 0.9
	if is_open():
		if float(p.open_seconds) > 0.0:
			_timer -= delta
			if _timer <= 0.0 and not _anyone_inside():
				_target = 0.0
				_shape.set_deferred("disabled", false)
		return
	for r in racers():
		if not in_box(r, float(p.width) * 0.5 + 0.6, float(p.thickness) * 0.5 + 2.2, float(p.height)):
			continue
		var player := player_racer(r)
		if not player and not bool(p.ai_buys):
			continue
		var it = r.items
		if it.spend_rings(int(p.cost)):
			_target = 1.0
			_timer = float(p.open_seconds)
			_shape.set_deferred("disabled", true)
			Bus.action(r, &"door", {"cost": int(p.cost)})
			if player:
				Bus.hud("DOOR OPEN  -%d RINGS" % int(p.cost), 1.4)
			return
		elif player and _msg_cool <= 0.0:
			_msg_cool = 2.0
			Bus.hud("NEED %d RINGS" % int(p.cost), 1.2)


func _anyone_inside() -> bool:
	for r in racers():
		if in_box(r, float(p.width) * 0.5 + 0.5, float(p.thickness) * 0.5 + 1.2, float(p.height)):
			return true
	return false
