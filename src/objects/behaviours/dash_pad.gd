@tool
extends TrackObject
## Dash panel / boost pad: a burst of speed for anyone who drives over it.

const BEHAVIOUR := "dash_pad"
const LABEL := "Dash panel"
const PARAMS := {
	"seconds": {"type": "float", "default": 0.9, "min": 0.1, "max": 5.0, "step": 0.05},
	"speed": {"type": "float", "default": 10.0, "min": 0.0, "max": 40.0, "step": 0.5, "hint": "m/s added to top speed"},
	"length": {"type": "float", "default": 3.0, "min": 0.5, "max": 20.0, "step": 0.1},
	"width": {"type": "float", "default": 2.4, "min": 0.5, "max": 20.0, "step": 0.1},
}

var _cool := {}
var _t := 0.0
var _vis: Node3D


func build() -> void:
	_vis = model("dash")
	_vis.scale = Vector3(float(p.width) / 2.4, 1.0, float(p.length) / 3.0)
	add_child(_vis)


func tick(delta: float) -> void:
	_t += delta
	for k in _cool.keys():
		_cool[k] = float(_cool[k]) - delta
		if _cool[k] <= 0.0:
			_cool.erase(k)
	for r in racers():
		if _cool.has(r.get_instance_id()):
			continue
		if in_box(r, float(p.width) * 0.5 + 0.3, float(p.length) * 0.5 + 0.3, 1.8):
			r.movement.item_boost(float(p.seconds), float(p.speed))
			_cool[r.get_instance_id()] = 0.4
			Bus.action(r, &"boost", {"level": 1, "pad": true})
