extends ItemBehaviour
## Magnet / Thunder Shield: rings within the radius fly to you for a while.

const BEHAVIOUR := "magnet"
const LABEL := "Ring magnet"
const PARAMS := {
	"seconds": {"type": "float", "default": 9.0, "min": 0.5, "max": 60.0, "step": 0.5},
	"radius": {"type": "float", "default": 10.0, "min": 1.0, "max": 60.0, "step": 0.5},
}


func use(items: RacerItems, _def: Dictionary, p: Dictionary, _back: bool) -> bool:
	items.magnet_timer = float(p.seconds)
	items.magnet_radius = float(p.radius)
	return true


func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, _ctx: Dictionary) -> bool:
	return true
