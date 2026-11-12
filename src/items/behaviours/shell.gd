extends ItemBehaviour
## Shells: "straight" bounces off walls (green), "homing" chases the racer ahead
## (red), "leader" flies to whoever is in first and explodes (spiny).
## Hold brake while firing to send straight / homing shells backwards.

const BEHAVIOUR := "shell"
const LABEL := "Shell (projectile)"
const PARAMS := {
	"mode": {"type": "enum", "default": "straight", "options": ["straight", "homing", "leader"]},
	"speed": {"type": "float", "default": 40.0, "min": 5.0, "max": 120.0, "step": 1.0},
	"life": {"type": "float", "default": 8.0, "min": 0.5, "max": 60.0, "step": 0.5},
	"bounces": {"type": "int", "default": 5, "min": 0, "max": 50},
	"spin": {"type": "float", "default": 1.0, "min": 0.1, "max": 4.0, "step": 0.05, "hint": "Hit-stun seconds"},
	"turn_rate": {"type": "float", "default": 3.5, "min": 0.0, "max": 20.0, "step": 0.1, "hint": "Homing turn speed (rad/s)"},
	"explode_radius": {"type": "float", "default": 5.0, "min": 0.0, "max": 30.0, "step": 0.5, "hint": "Leader mode blast"},
	"radius": {"type": "float", "default": 0.6, "min": 0.1, "max": 4.0, "step": 0.05},
}


func use(items: RacerItems, def: Dictionary, p: Dictionary, back: bool) -> bool:
	var r := items.racer as Node3D
	var e := ShellEntity.new()
	e.owner_racer = items.racer
	e.track = items.racer.track
	e.mode = String(p.mode)
	e.speed = float(p.speed)
	e.life = float(p.life) if e.mode != "leader" else maxf(float(p.life), 40.0)
	e.bounces = int(p.bounces)
	e.spin = float(p.spin)
	e.turn_rate = float(p.turn_rate)
	e.explode_radius = float(p.explode_radius)
	e.radius = float(p.radius)
	e.blocks = e.mode != "leader"
	e.model = model_of(def)
	e.spin_speed = 9.0
	var fwd: Vector3 = items.racer.movement.forward()
	var dir := -fwd if back and e.mode != "leader" else fwd
	e.dir = dir
	if e.mode == "homing" and not back:
		var st := GameState.standings()
		var k := st.find(items.racer)
		e.target = st[k - 1] if k > 0 else null
	elif e.mode == "leader":
		var st2 := GameState.standings()
		e.target = st2[0] if st2.size() > 0 else null
	ItemEntity.world(e.track).add_child(e)
	e.global_position = r.global_position + dir * 1.8 + Vector3.UP * (2.0 if e.mode == "leader" else 0.1)
	return true


func ai_should_use(_items: RacerItems, _def: Dictionary, p: Dictionary, ctx: Dictionary) -> bool:
	match String(p.mode):
		"leader":
			return int(ctx.rank) > 1 or float(ctx.held) > 4.0
		"homing":
			return int(ctx.rank) > 0 and float(ctx.ahead_gap) < 60.0
		_:
			if float(ctx.behind_gap) < 8.0 and float(ctx.ahead_gap) > 40.0:
				ctx["fire_back"] = true
				return true
			return float(ctx.ahead_gap) < 30.0 and float(ctx.ahead_dot) > 0.94
