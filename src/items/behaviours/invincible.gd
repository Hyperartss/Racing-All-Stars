extends ItemBehaviour
## Star / Invincibility: faster, immune to everything, and spins out whoever you touch.

const BEHAVIOUR := "invincible"
const LABEL := "Invincibility (star)"
const PARAMS := {
	"seconds": {"type": "float", "default": 7.0, "min": 0.5, "max": 30.0, "step": 0.5},
	"speed": {"type": "float", "default": 6.0, "min": 0.0, "max": 30.0, "step": 0.5, "hint": "m/s added to top speed"},
}


func use(items: RacerItems, _def: Dictionary, p: Dictionary, _back: bool) -> bool:
	items.star_timer = float(p.seconds)
	items.star_speed = float(p.speed)
	EventBus.racer_action.emit(items.racer, &"star", {})
	return true


func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, ctx: Dictionary) -> bool:
	return float(ctx.held) > 1.0
