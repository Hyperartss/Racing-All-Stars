extends ItemBehaviour
## Blooper: squirts ink over the screens of the racers ahead (AI drivers wobble).

const BEHAVIOUR := "ink"
const LABEL := "Ink (blinds racers ahead)"
const PARAMS := {
	"seconds": {"type": "float", "default": 4.5, "min": 0.5, "max": 20.0, "step": 0.5},
	"targets": {"type": "enum", "default": "ahead", "options": ["ahead", "all"]},
}


func use(items: RacerItems, _def: Dictionary, p: Dictionary, _back: bool) -> bool:
	var st := GameState.standings()
	var me := st.find(items.racer)
	for k in st.size():
		var r: Node = st[k]
		if r == items.racer or not is_instance_valid(r):
			continue
		if String(p.targets) == "ahead" and k > me:
			continue
		var it: RacerItems = r.items
		if not it.invincible():
			it.ink_timer = maxf(it.ink_timer, float(p.seconds))
	return true


func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, ctx: Dictionary) -> bool:
	return int(ctx.rank) > 0
