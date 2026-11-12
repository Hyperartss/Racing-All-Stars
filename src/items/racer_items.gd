class_name RacerItems
extends Node
## Per-racer item slot, rings and power-up state. A child of every Racer.
##
## Item boxes call pickup_box(); the roulette spins for the rules' roulette time and
## lands on an item weighted by race position (ItemTypes.roll). The use button
## (E / J) fires it: holding it drags holdable items (bananas) behind you, and holding
## brake (S) while using fires projectiles backwards / throws traps forwards.
## AI racers decide here too (via each behaviour's ai_should_use), so the AI
## controller needs no item code.

signal changed

var racer: Node                        ## the Racer (parent)
var slot := ""                         ## item id held ("" = none)
var uses := 0                          ## e.g. 3 for triple items
var rolling := 0.0                     ## roulette seconds left
var _pending := ""
var held_entity: ItemEntity
var holding := false
var rings := 0

# --- effects (seconds left) ---
var star_timer := 0.0
var star_speed := 6.0
var bullet_timer := 0.0
var bullet_speed := 1.5
var shrink_timer := 0.0
var ink_timer := 0.0
var shield_hits := 0
var shield_timer := 0.0
var magnet_timer := 0.0
var magnet_radius := 10.0
var golden_timer := 0.0
var invuln := 0.0
var trick_window := 0.0
var tricked := false
var trick_spin := 0.0
var _was_air := false
var _held_time := 0.0
var _ai_hold_until := 0.0
var _ai_think := 0.0
var _t := 0.0
var _path_i := -1
var rng := RandomNumberGenerator.new()
var _shield_fx: Node3D
var _star_fx_t := 0.0


func _ready() -> void:
	racer = get_parent()
	rings = GameRules.i("start_rings")
	rng.seed = hash(String(racer.name)) ^ int(Time.get_ticks_usec())


func is_ai() -> bool:
	return racer.controller is AIController


func item_def() -> Dictionary:
	return ItemTypes.item(slot) if slot != "" else {}


## Called by the Racer each physics frame with this frame's input, before movement.
func physics(inp: RacerInput, delta: float) -> void:
	_t += delta
	for k in ["star_timer", "bullet_timer", "shrink_timer", "ink_timer", "magnet_timer", "invuln", "trick_window"]:
		set(k, maxf(0.0, float(get(k)) - delta))
	if shield_timer > 0.0:
		shield_timer = maxf(0.0, shield_timer - delta)
		if shield_timer <= 0.0:
			shield_hits = 0
	if golden_timer > 0.0:
		golden_timer -= delta
		if golden_timer <= 0.0:
			golden_timer = 0.0
			_clear_slot()
	if rolling > 0.0:
		rolling -= delta
		if rolling <= 0.0:
			rolling = 0.0
			slot = _pending
			uses = maxi(int(ItemTypes.item(slot).get("count", 1)), 1) if slot != "" else 0
			_held_time = 0.0
			changed.emit()
	if slot != "":
		_held_time += delta

	# Bullet: the course drives you.
	if bullet_timer > 0.0:
		_autopilot(inp)
		racer.movement.item_boost(0.15, racer.movement.max_speed * (bullet_speed - 1.0))
	if star_timer > 0.0:
		racer.movement.item_boost(0.15, star_speed)
	if star_timer > 0.0 or bullet_timer > 0.0:
		_ram_others()
	if ink_timer > 0.0 and is_ai():
		inp.steer = clampf(inp.steer + sin(_t * 2.7) * 0.35, -1.0, 1.0)
	racer.movement.bonus_mult = speed_mult()

	if racer.race_active and not racer.has_finished:
		if is_ai():
			_ai_step(inp, delta)
		else:
			_player_step(inp)
	_trick_step(inp)
	_update_shield_fx()


func _player_step(inp: RacerInput) -> void:
	if slot == "" or rolling > 0.0:
		return
	var b: ItemBehaviour = ItemTypes.behaviour_of(slot)
	if b == null:
		return
	var def := item_def()
	var p := ItemTypes.params_of(slot)
	var back := inp.brake > 0.5
	if inp.item_pressed and not holding:
		if b.holdable(def, p) and held_entity == null:
			holding = true
			held_entity = b.call("make_held", self, def, p) if b.has_method("make_held") else null
			if held_entity == null:
				holding = false
				_fire(b, def, p, back)
		else:
			_fire(b, def, p, back)
	elif holding and not inp.item:
		holding = false
		if b.release(self, def, p, back):
			consume()


func _fire(b: ItemBehaviour, def: Dictionary, p: Dictionary, back: bool) -> void:
	if b.use(self, def, p, back):
		consume()
	EventBus.racer_action.emit(racer, &"item", {"item": String(def.get("id", ""))})


func consume() -> void:
	uses -= 1
	if uses <= 0:
		_clear_slot()
	else:
		changed.emit()


func _clear_slot() -> void:
	slot = ""
	uses = 0
	golden_timer = 0.0
	_held_time = 0.0
	changed.emit()


## Item box touched. Returns true if the roulette started.
func pickup_box() -> bool:
	if not GameRules.b("items_enabled") or slot != "" or rolling > 0.0:
		return false
	var st := GameState.standings()
	var rank := maxi(st.find(racer), 0)
	var type := String(RacerTypes.character(racer.character).get("type", "runner"))
	_pending = ItemTypes.roll(rank, st.size(), type, rng)
	if _pending == "":
		return false
	rolling = GameRules.f("item_roulette_time") * (rng.randf_range(0.6, 0.9) if is_ai() else 1.0)
	changed.emit()
	return true


func add_rings(n: int) -> void:
	rings = clampi(rings + n, 0, GameRules.i("max_rings"))
	changed.emit()


## Pay `n` rings (doors). False if there are not enough.
func spend_rings(n: int) -> bool:
	if rings < n:
		return false
	rings -= n
	changed.emit()
	return true


func speed_mult() -> float:
	var m := 1.0 + float(mini(rings, GameRules.i("ring_speed_max_rings"))) * GameRules.f("ring_speed_per_ring")
	if shrink_timer > 0.0:
		m *= 0.78
	return m


func visual_scale() -> float:
	return 0.6 if shrink_timer > 0.0 else 1.0


func invincible() -> bool:
	return star_timer > 0.0 or bullet_timer > 0.0


## Something hit this racer. kind: "spin" (banana, shell), "tumble" (explosion),
## "shock" (lightning), "squash" (rammed by a star / bullet). False if it was blocked.
func hit(kind: String, seconds: float, by: Node) -> bool:
	if invincible() or invuln > 0.0:
		return false
	if shield_hits > 0 and kind != "shock":
		shield_hits -= 1
		BurstFx.spawn(racer.get_parent(), racer.global_position + Vector3.UP, Color(0.5, 0.8, 1.0))
		EventBus.racer_action.emit(racer, &"blocked", {"by": by})
		return false
	racer.movement.take_hit(seconds)
	if kind == "tumble" and "vy" in racer.movement:
		racer.movement.set("vy", 8.0)
	var lost := mini(rings, GameRules.i("rings_lost_on_hit"))
	if lost > 0:
		rings -= lost
		ScatterRing.burst(racer.track, racer.global_position, lost, racer)
	if held_entity != null and is_instance_valid(held_entity):
		held_entity.held = false
		held_entity = null
		holding = false
	invuln = seconds + 0.35
	changed.emit()
	EventBus.racer_action.emit(racer, &"hit", {"kind": kind, "by": by})
	return true


## Springs / trick ramps open a window in which Space does a trick.
func open_trick(seconds: float) -> void:
	trick_window = maxf(trick_window, seconds)


func _trick_step(inp: RacerInput) -> void:
	var air: bool = not racer.is_on_floor()
	if air and trick_window > 0.0 and not tricked:
		var want := inp.jump
		if is_ai() and trick_window > 0.0 and rng.randf() < 0.03:
			want = true
		if want:
			tricked = true
			trick_spin = 1.0
			EventBus.racer_action.emit(racer, &"trick", {})
	if trick_spin > 0.0:
		trick_spin = maxf(0.0, trick_spin - get_physics_process_delta_time() * 2.2)
	if not air and _was_air and tricked:
		tricked = false
		racer.movement.item_boost(GameRules.f("trick_boost"), 6.0)
		EventBus.racer_action.emit(racer, &"boost", {"level": 1, "trick": true})
	if not air and trick_window <= 0.0:
		tricked = false
	_was_air = air


func _autopilot(inp: RacerInput) -> void:
	var path: TrackPath = racer.track.path
	var i: int = racer.track_index
	var j := path.index_ahead(i, clampf(10.0 + absf(racer.movement.speed) * 0.5, 12.0, 26.0))
	var to: Vector3 = path.pos[j] - (racer as Node3D).global_position
	to.y = 0.0
	var ang: float = racer.movement.forward().signed_angle_to(to.normalized(), Vector3.UP)
	inp.steer = clampf(ang * 2.6, -1.0, 1.0)
	inp.throttle = 1.0
	inp.brake = 0.0


func _ram_others() -> void:
	for r in GameState.racers:
		if r == racer or not is_instance_valid(r):
			continue
		if (r as Node3D).global_position.distance_to((racer as Node3D).global_position) < 1.7:
			ItemEntity.hit_racer(r, "spin", GameRules.f("spin_time"), racer)


# --- AI ------------------------------------------------------------------------------

func _ai_step(inp: RacerInput, delta: float) -> void:
	if not GameRules.b("ai_items") or slot == "" or rolling > 0.0:
		return
	var b: ItemBehaviour = ItemTypes.behaviour_of(slot)
	if b == null:
		return
	var def := item_def()
	var p := ItemTypes.params_of(slot)
	if holding:
		var ctx_h := ai_context()
		if _t > _ai_hold_until or float(ctx_h.behind_gap) < 5.0:
			holding = false
			if b.release(self, def, p, false):
				consume()
		return
	_ai_think -= delta
	if _ai_think > 0.0:
		return
	_ai_think = rng.randf_range(0.25, 0.5)
	var ctx := ai_context()
	if b.holdable(def, p) and held_entity == null and b.has_method("make_held") and rng.randf() < 0.6:
		held_entity = b.call("make_held", self, def, p)
		if held_entity != null:
			holding = true
			_ai_hold_until = _t + rng.randf_range(4.0, 12.0)
			return
	if b.ai_should_use(self, def, p, ctx):
		_fire(b, def, p, bool(ctx.get("fire_back", false)))
	inp.item_pressed = false


## What the AI looks at to decide on an item.
func ai_context() -> Dictionary:
	var st := GameState.standings()
	var rank := st.find(racer)
	var me := racer as Node3D
	var ahead: Node = st[rank - 1] if rank > 0 else null
	var behind: Node = st[rank + 1] if rank >= 0 and rank + 1 < st.size() else null
	var path: TrackPath = racer.track.path
	var i: int = racer.track_index
	var t0 := path.tangent[i]
	var t1 := path.tangent[path.index_ahead(i, 30.0)]
	var fwd: Vector3 = racer.movement.forward()
	var ahead_gap := 1.0e9
	var ahead_dot := 0.0
	if ahead != null:
		var d := (ahead as Node3D).global_position - me.global_position
		ahead_gap = d.length()
		ahead_dot = fwd.dot(d.normalized()) if d.length() > 0.01 else 0.0
	var behind_gap := 1.0e9
	if behind != null:
		behind_gap = (behind as Node3D).global_position.distance_to(me.global_position)
	return {"rank": rank, "count": st.size(), "ahead": ahead, "ahead_gap": ahead_gap,
		"ahead_dot": ahead_dot, "behind": behind, "behind_gap": behind_gap,
		"straight": absf(t0.signed_angle_to(t1, Vector3.UP)) < 0.3, "held": _held_time}


# --- shield bubble -------------------------------------------------------------------

func _update_shield_fx() -> void:
	var want := shield_hits > 0 or star_timer > 0.0
	if want and _shield_fx == null:
		_shield_fx = ItemModels.build("shield", Color(0.45, 0.75, 1.0))
		_shield_fx.position = Vector3(0, 0.05, 0)
		racer.add_child(_shield_fx)
	elif not want and _shield_fx != null:
		_shield_fx.queue_free()
		_shield_fx = null
	if _shield_fx != null:
		_star_fx_t += get_physics_process_delta_time()
		_shield_fx.rotation.y += 0.05
		if star_timer > 0.0:
			var c := Color.from_hsv(fmod(_star_fx_t * 1.5, 1.0), 0.8, 1.0)
			for ch in _shield_fx.get_children():
				if ch is MeshInstance3D:
					var m := (ch as MeshInstance3D).material_override as StandardMaterial3D
					if m:
						m.albedo_color = Color(c.r, c.g, c.b, 0.35)


## Rocket start / burnout from the countdown (Race calls this at GO).
func rocket_start(ok: bool) -> void:
	if ok:
		racer.movement.item_boost(GameRules.f("rocket_boost"), 8.0)
		EventBus.racer_action.emit(racer, &"boost", {"level": 2, "rocket": true})
	else:
		racer.movement.take_hit(0.8)
		EventBus.racer_action.emit(racer, &"burnout", {})
