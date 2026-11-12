@tool
extends TrackObject
## Springs (launch > 0) and trick zones (launch 0, put on the lip of a ramp): both
## open the trick window - press Space in the air for a boost on landing (Mario Kart
## Wii tricks).

const BEHAVIOUR := "launcher"
const LABEL := "Spring / trick zone"
const PARAMS := {
	"launch": {"type": "float", "default": 16.0, "min": 0.0, "max": 60.0, "step": 0.5, "hint": "Upward speed (0 = trick zone only)"},
	"forward": {"type": "float", "default": 4.0, "min": 0.0, "max": 30.0, "step": 0.5, "hint": "Boost m/s"},
	"radius": {"type": "float", "default": 1.2, "min": 0.3, "max": 20.0, "step": 0.1},
	"trick_seconds": {"type": "float", "default": 1.8, "min": 0.0, "max": 6.0, "step": 0.1},
}

var _cool := {}
var _vis: Node3D
var _bounce := 0.0


func build() -> void:
	_vis = model()
	add_child(_vis)


func tick(delta: float) -> void:
	for k in _cool.keys():
		_cool[k] = float(_cool[k]) - delta
		if _cool[k] <= 0.0:
			_cool.erase(k)
	if _bounce > 0.0:
		_bounce = maxf(0.0, _bounce - delta * 3.0)
		_vis.scale.y = 1.0 + _bounce * 0.6
	var rad := float(p.radius) * global_transform.basis.get_scale().x
	for r in racers():
		if _cool.has(r.get_instance_id()):
			continue
		var d := (r as Node3D).global_position - global_position
		if Vector2(d.x, d.z).length() > rad + 0.4 or d.y < -1.0 or d.y > 2.0:
			continue
		_cool[r.get_instance_id()] = 0.8
		var mv = r.movement
		if float(p.launch) > 0.0:
			mv.launch(float(p.launch))
			_bounce = 1.0
		if float(p.forward) > 0.0:
			mv.item_boost(0.6, float(p.forward))
		if float(p.trick_seconds) > 0.0:
			r.items.open_trick(float(p.trick_seconds))
		Bus.action(r, &"spring", {})
