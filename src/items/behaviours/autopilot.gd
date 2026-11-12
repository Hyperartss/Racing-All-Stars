extends ItemBehaviour
## Bullet Bill: the course drives you at high speed for a few seconds, flattening
## anyone in the way.

const BEHAVIOUR := "autopilot"
const LABEL := "Autopilot (bullet)"
const PARAMS := {
	"seconds": {"type": "float", "default": 6.0, "min": 0.5, "max": 30.0, "step": 0.5},
	"speed_mult": {"type": "float", "default": 1.55, "min": 1.0, "max": 4.0, "step": 0.05, "hint": "x top speed"},
}


func use(items: RacerItems, _def: Dictionary, p: Dictionary, _back: bool) -> bool:
	items.bullet_timer = float(p.seconds)
	items.bullet_speed = float(p.speed_mult)
	EventBus.racer_action.emit(items.racer, &"bullet", {})
	return true


func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, ctx: Dictionary) -> bool:
	return float(ctx.held) > 0.8
