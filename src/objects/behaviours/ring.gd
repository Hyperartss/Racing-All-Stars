@tool
extends TrackObject
## Rings (Sonic R) / coins (Mario Kart): one, a line along the object's facing, a
## circle or an arc. Each ring sits on the ground under it when the race starts.
## Rings pay for doors and (per the rules) add a little top speed.

const BEHAVIOUR := "ring"
const LABEL := "Rings / coins"
const PARAMS := {
	"layout": {"type": "enum", "default": "single", "options": ["single", "line", "circle", "arc"]},
	"count": {"type": "int", "default": 1, "min": 1, "max": 64},
	"spacing": {"type": "float", "default": 2.5, "min": 0.5, "max": 20.0, "step": 0.1, "hint": "Line: metres between rings"},
	"radius": {"type": "float", "default": 3.0, "min": 0.5, "max": 40.0, "step": 0.1, "hint": "Circle / arc radius"},
	"arc_degrees": {"type": "float", "default": 120.0, "min": 10.0, "max": 360.0, "step": 5.0},
	"height": {"type": "float", "default": 0.0, "min": -5.0, "max": 30.0, "step": 0.1, "hint": "Lift above the ground (m)"},
	"value": {"type": "int", "default": 1, "min": 1, "max": 100, "hint": "Rings per pick-up"},
	"respawn": {"type": "float", "default": -1.0, "min": -1.0, "max": 600.0, "step": 0.5, "hint": "-1 = rules default, 0 = never"},
	"snap": {"type": "bool", "default": true, "hint": "Each ring drops onto the ground under it"},
}

var _rings: Array = []       ## [{node, local, timer}]
var _t := 0.0


static func layout_points(pp: Dictionary) -> Array:
	var pts: Array = []
	var n := maxi(int(pp.get("count", 1)), 1)
	match String(pp.get("layout", "single")):
		"line":
			var sp := float(pp.get("spacing", 2.5))
			for k in n:
				pts.append(Vector3(0, 0, -(k - (n - 1) * 0.5) * sp))
		"circle":
			var r := float(pp.get("radius", 3.0))
			for k in n:
				var a := TAU * k / n
				pts.append(Vector3(sin(a) * r, 0, -cos(a) * r))
		"arc":
			var r2 := float(pp.get("radius", 3.0))
			var span := deg_to_rad(float(pp.get("arc_degrees", 120.0)))
			for k in n:
				var t := 0.5 if n == 1 else float(k) / float(n - 1)
				var a2 := -span * 0.5 + span * t
				pts.append(Vector3(sin(a2) * r2, 0, -cos(a2) * r2 + r2))
		_:
			pts.append(Vector3.ZERO)
	return pts


func build() -> void:
	for lp in layout_points(p):
		var m := model("ring")
		m.position = lp + Vector3.UP * float(p.height)
		add_child(m)
		_rings.append({"node": m, "local": lp, "timer": 0.0})


func game_ready() -> void:
	if bool(p.snap):
		for r in _rings:
			var g := ground_at(to_global(r.local))
			var l := to_local(g)
			(r.node as Node3D).position = Vector3(r.local.x, l.y + float(p.height), r.local.z)


func tick(delta: float) -> void:
	_t += delta
	var respawn := float(p.respawn)
	if respawn < 0.0:
		respawn = GameRules.f("ring_respawn")
	var rs := racers()
	for ring in _rings:
		var n: Node3D = ring.node
		if not n.visible:
			if respawn > 0.0:
				ring.timer -= delta
				if ring.timer <= 0.0:
					n.visible = true
			continue
		n.rotation.y = _t * 4.0
		var at := n.global_position + Vector3.UP * 0.7
		for r in rs:
			var it = r.items
			var reach: float = it.magnet_radius if it.magnet_timer > 0.0 else 1.25
			if (r as Node3D).global_position.distance_to(at) < reach + 0.4:
				it.add_rings(int(p.value))
				n.visible = false
				ring.timer = respawn
				Bus.action(r, &"ring", {"amount": int(p.value)})
				break
