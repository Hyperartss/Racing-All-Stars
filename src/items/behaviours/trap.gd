extends ItemBehaviour
## Banana / Fake Item Box: something to leave on the road. Tap to drop it behind
## you, hold the button to drag it behind you (it blocks shells from behind), hold
## brake while letting go to throw it forward.

const BEHAVIOUR := "trap"
const LABEL := "Trap (banana, fake item box)"
const PARAMS := {
	"spin": {"type": "float", "default": 0.9, "min": 0.1, "max": 4.0, "step": 0.05, "hint": "Hit-stun seconds"},
	"hit": {"type": "enum", "default": "spin", "options": ["spin", "tumble", "shock"]},
	"throw_distance": {"type": "float", "default": 14.0, "min": 2.0, "max": 60.0, "step": 0.5},
	"life": {"type": "float", "default": 0.0, "min": 0.0, "max": 300.0, "step": 1.0, "hint": "Seconds before it disappears (0 = stays)"},
	"radius": {"type": "float", "default": 0.6, "min": 0.1, "max": 4.0, "step": 0.05},
}


func holdable(_def: Dictionary, _p: Dictionary) -> bool:
	return true


func _make(items: RacerItems, def: Dictionary, p: Dictionary) -> TrapEntity:
	var e := TrapEntity.new()
	e.owner_racer = items.racer
	e.track = items.racer.track
	e.spin = float(p.spin)
	e.kind = String(p.hit)
	e.life = float(p.life)
	e.radius = float(p.radius)
	e.model = model_of(def)
	e.spin_speed = 1.5 if String(def.get("shape", "")) in ["fake_box", "box"] else 0.0
	ItemEntity.world(e.track).add_child(e)
	return e


func make_held(items: RacerItems, def: Dictionary, p: Dictionary) -> ItemEntity:
	var e := _make(items, def, p)
	e.held = true
	e._follow_owner()
	return e


func use(items: RacerItems, def: Dictionary, p: Dictionary, back: bool) -> bool:
	var e := _make(items, def, p)
	_place(items, e, p, back)
	return true


func release(items: RacerItems, def: Dictionary, p: Dictionary, back: bool) -> bool:
	var e := items.held_entity as TrapEntity
	items.held_entity = null
	if e == null or not is_instance_valid(e):
		return use(items, def, p, back)
	e.held = false
	e.age = 0.0
	_place(items, e, p, back)
	return true


func _place(items: RacerItems, e: TrapEntity, p: Dictionary, forward: bool) -> void:
	var r := items.racer as Node3D
	var fwd: Vector3 = items.racer.movement.forward()
	if forward:
		e.global_position = r.global_position + fwd * 1.2 + Vector3.UP * 0.6
		e.throw(fwd, float(p.throw_distance) + maxf(items.racer.movement.speed, 0.0) * 0.4)
	else:
		e.global_position = r.global_position - fwd * 1.6 + Vector3.UP * 0.3


func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, ctx: Dictionary) -> bool:
	return float(ctx.behind_gap) < 14.0 or float(ctx.held) > 9.0
