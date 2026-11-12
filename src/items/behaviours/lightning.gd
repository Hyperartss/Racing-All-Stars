extends ItemBehaviour
## Lightning: zaps every rival ("all") or only those ahead ("ahead"): they spin,
## shrink and slow down; the leaders stay small the longest.

const BEHAVIOUR := "lightning"
const LABEL := "Lightning (hits rivals)"
const PARAMS := {
	"targets": {"type": "enum", "default": "all", "options": ["all", "ahead"]},
	"shrink": {"type": "float", "default": 5.0, "min": 0.0, "max": 20.0, "step": 0.5, "hint": "Shrink seconds for the leader (less further back)"},
	"spin": {"type": "float", "default": 0.8, "min": 0.0, "max": 4.0, "step": 0.05},
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
		if it.invincible():
			continue
		var share := 1.0 - float(k) / float(maxi(st.size(), 1)) * 0.6
		if it.hit("shock", float(p.spin), items.racer):
			it.shrink_timer = maxf(it.shrink_timer, float(p.shrink) * share)
	EventBus.hud_message.emit("ZAP!", 0.8)
	return true


func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, ctx: Dictionary) -> bool:
	return int(ctx.rank) > 0 and float(ctx.held) > 1.5
