@tool
extends TrackObject
## Collectables saved between races: Sonic R gold tokens, Chaos Emeralds, or any
## kind you name. Only the player collects them, and they are only kept when the
## player finishes the race. One already collected shows as a see-through ghost.
## Characters can be locked behind totals: "unlock": {"token": 5} in their JSON.

const BEHAVIOUR := "collectable"
const LABEL := "Collectable (token, emerald ...)"
const PARAMS := {
	"kind": {"type": "string", "default": "token", "hint": "Counted per kind: token, emerald, or your own"},
	"uid": {"type": "string", "default": "", "hint": "Unique id - set automatically when placed"},
	"height": {"type": "float", "default": 0.4, "min": -5.0, "max": 30.0, "step": 0.1},
}

var _node: Node3D
var _t := 0.0
var _taken := false
var _ghost := false


func build() -> void:
	_node = model()
	_node.position.y = float(p.height)
	add_child(_node)


func game_ready() -> void:
	var uid := _uid()
	if PlayerProgress.has(map_id, uid):
		_ghost = true
		_make_ghost(_node)


func _uid() -> String:
	var u := String(p.get("uid", ""))
	if u == "":
		u = "%s@%d,%d,%d" % [String(entry.get("type", "")), int(position.x), int(position.y), int(position.z)]
	return u


func _make_ghost(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.6, 0.75, 1.0, 0.3)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = m
	for c in n.get_children():
		_make_ghost(c)


func tick(delta: float) -> void:
	if _taken:
		return
	_t += delta
	_node.rotation.y = _t * 2.2
	_node.position.y = float(p.height) + sin(_t * 2.5) * 0.12
	for r in racers():
		if not player_racer(r):
			continue
		if (r as Node3D).global_position.distance_to(_node.global_position + Vector3.UP * 0.9) < 1.7:
			_taken = true
			_node.visible = false
			BurstFx.spawn(self, _node.global_position + Vector3.UP, colour(), 10, 5.0)
			if _ghost:
				return
			var kind := String(p.kind)
			PlayerProgress.pick_up(map_id, kind, _uid())
			var total := 0
			var got := PlayerProgress.count(kind, map_id)
			for pend in PlayerProgress.pending:
				if String(pend.kind) == kind and String(pend.map) == map_id:
					got += 1
			for sib in get_parent().get_children():
				if sib is TrackObject and String((sib as TrackObject).p.get("kind", "")) == kind:
					total += 1
			Bus.action(r, &"collect", {"kind": kind})
			Bus.hud("%s  %d/%d" % [kind.to_upper(), got, total], 1.6)
			return
