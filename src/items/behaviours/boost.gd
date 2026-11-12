extends ItemBehaviour
## Mushroom / Speed Shoes: a burst of speed that ignores off-road. With "golden" it
## turns into a Golden Mushroom: boost as often as you like for "duration" seconds.

const BEHAVIOUR := "boost"
const LABEL := "Boost (mushroom, speed shoes)"
const PARAMS := {
	"seconds": {"type": "float", "default": 1.1, "min": 0.1, "max": 10.0, "step": 0.05, "hint": "Length of one boost"},
	"speed": {"type": "float", "default": 9.0, "min": 0.0, "max": 40.0, "step": 0.5, "hint": "m/s added to top speed"},
	"golden": {"type": "bool", "default": false, "hint": "Unlimited boosts for 'duration' seconds"},
	"duration": {"type": "float", "default": 7.5, "min": 0.5, "max": 30.0, "step": 0.5},
}


func use(items: RacerItems, _def: Dictionary, p: Dictionary, _back: bool) -> bool:
	items.racer.movement.item_boost(float(p.seconds), float(p.speed))
	EventBus.racer_action.emit(items.racer, &"boost", {"level": 1, "item": true})
	if bool(p.golden):
		if items.golden_timer <= 0.0:
			items.golden_timer = float(p.duration)
		return false
	return true


func ai_should_use(items: RacerItems, _def: Dictionary, p: Dictionary, ctx: Dictionary) -> bool:
	if bool(p.golden) and items.golden_timer > 0.0:
		return items.racer.movement.boost_left() <= 0.05
	return bool(ctx.straight) or float(ctx.held) > 6.0
