extends ItemBehaviour
## Super Ring / coin bag: adds rings straight away.

const BEHAVIOUR := "rings"
const LABEL := "Rings (adds rings)"
const PARAMS := {
	"amount": {"type": "int", "default": 10, "min": 1, "max": 999},
}


func use(items: RacerItems, _def: Dictionary, p: Dictionary, _back: bool) -> bool:
	items.add_rings(int(p.amount))
	EventBus.racer_action.emit(items.racer, &"rings", {"amount": int(p.amount)})
	return true


func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, _ctx: Dictionary) -> bool:
	return true
