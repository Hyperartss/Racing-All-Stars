@tool
extends TrackObject
## Item boxes (a single box or a row across the road). Driving through one spins the
## item roulette (if your slot is empty); the box breaks and comes back after
## `respawn` seconds.

const BEHAVIOUR := "item_box"
const LABEL := "Item boxes"
const PARAMS := {
	"count": {"type": "int", "default": 1, "min": 1, "max": 16, "hint": "Boxes in the row (across the object's X axis)"},
	"spacing": {"type": "float", "default": 2.6, "min": 0.8, "max": 12.0, "step": 0.1},
	"respawn": {"type": "float", "default": -1.0, "min": -1.0, "max": 120.0, "step": 0.1, "hint": "-1 = rules default"},
	"height": {"type": "float", "default": 0.0, "min": -2.0, "max": 20.0, "step": 0.1},
	"snap": {"type": "bool", "default": true},
}

var _boxes: Array = []
var _t := 0.0


func build() -> void:
	var n := maxi(int(p.count), 1)
	for k in n:
		var m := model("box")
		var lp := Vector3((k - (n - 1) * 0.5) * float(p.spacing), float(p.height), 0)
		m.position = lp
		add_child(m)
		_boxes.append({"node": m, "local": lp, "timer": 0.0})


func game_ready() -> void:
	if bool(p.snap):
		for b in _boxes:
			var l := to_local(ground_at(to_global(b.local)))
			(b.node as Node3D).position = Vector3(b.local.x, l.y + float(p.height), b.local.z)


func tick(delta: float) -> void:
	_t += delta
	var respawn := float(p.respawn)
	if respawn < 0.0:
		respawn = GameRules.f("item_box_respawn")
	var rs := racers()
	for b in _boxes:
		var n: Node3D = b.node
		if b.timer > 0.0:
			b.timer -= delta
			if b.timer <= 0.0:
				n.visible = true
				n.scale = Vector3.ONE * 0.1
			continue
		n.rotation.y = _t * 1.6
		n.position.y = (n.position.y) + sin(_t * 3.0 + b.local.x) * 0.004
		if n.scale.x < 1.0:
			n.scale = Vector3.ONE * minf(1.0, n.scale.x + delta * 3.0)
		var at := n.global_position + Vector3.UP * 0.75
		for r in rs:
			if (r as Node3D).global_position.distance_to(at) < 1.55:
				r.items.pickup_box()
				n.visible = false
				b.timer = respawn
				BurstFx.spawn(self, at, Color(0.6, 0.85, 1.0), 6, 4.0)
				break
