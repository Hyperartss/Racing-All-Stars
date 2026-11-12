extends ItemBehaviour
## Barrier (Sonic shields): blocks the next hit(s) for a while.

const BEHAVIOUR := "shield"
const LABEL := "Shield (blocks hits)"
const PARAMS := {
	"hits": {"type": "int", "default": 1, "min": 1, "max": 10},
	"seconds": {"type": "float", "default": 15.0, "min": 0.0, "max": 120.0, "step": 1.0, "hint": "0 = until it is used up"},
}


func use(items: RacerItems, _def: Dictionary, p: Dictionary, _back: bool) -> bool:
	items.shield_hits = int(p.hits)
	items.shield_timer = float(p.seconds) if float(p.seconds) > 0.0 else 1.0e9
	return true


func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, _ctx: Dictionary) -> bool:
	return true
