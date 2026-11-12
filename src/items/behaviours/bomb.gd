extends ItemBehaviour
## Bob-omb: thrown ahead (or dropped behind while holding brake), explodes after a
## short fuse and sends everyone nearby tumbling.

const BEHAVIOUR := "bomb"
const LABEL := "Bomb (thrown explosive)"
const PARAMS := {
	"fuse": {"type": "float", "default": 1.4, "min": 0.1, "max": 10.0, "step": 0.1},
	"blast": {"type": "float", "default": 5.5, "min": 1.0, "max": 30.0, "step": 0.5, "hint": "Explosion radius (m)"},
	"throw_distance": {"type": "float", "default": 18.0, "min": 0.0, "max": 60.0, "step": 0.5},
	"tumble": {"type": "float", "default": 1.6, "min": 0.1, "max": 5.0, "step": 0.05},
}


func use(items: RacerItems, def: Dictionary, p: Dictionary, back: bool) -> bool:
	var r := items.racer as Node3D
	var e := BombEntity.new()
	e.owner_racer = items.racer
	e.track = items.racer.track
	e.fuse = float(p.fuse)
	e.blast = float(p.blast)
	e.tumble = float(p.tumble)
	e.radius = 0.6
	e.owner_grace = 0.8
	e.model = model_of(def)
	ItemEntity.world(e.track).add_child(e)
	var fwd: Vector3 = items.racer.movement.forward()
	if back:
		e.global_position = r.global_position - fwd * 1.6 + Vector3.UP * 0.4
		e.throw(-fwd, 2.0)
	else:
		e.global_position = r.global_position + fwd * 1.4 + Vector3.UP * 1.0
		e.throw(fwd, float(p.throw_distance) + maxf(items.racer.movement.speed, 0.0) * 0.5)
	return true


func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, ctx: Dictionary) -> bool:
	return (float(ctx.ahead_gap) < 26.0 and float(ctx.ahead_dot) > 0.8) or float(ctx.held) > 8.0
