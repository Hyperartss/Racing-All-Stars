extends Node
## Automated lap test. AI drives every racer; prints checkpoint splits, lap times,
## respawns, which animation states were seen, and proof the meshes are being
## vertex-animated. Exit code 0 = every racer finished.
## Run: godot --headless --fixed-fps 60 --path . res://scenes/test_lap.tscn -- --roster=sonic,mario --laps=1

var race: Race
var frames := 0
var max_frames := 60 * 240
var seen := {}
var disp := {}
var splits := {}
var _trace: Array = []      ## --trace=from,to : print motion while a racer is in that index range


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--trace="):
			_trace = Array(a.trim_prefix("--trace=").split(",")).map(func(x): return int(x))
	var r := Race.new()
	r.player_index = -1
	r.laps = 1
	r.countdown = false
	r.roster = PackedStringArray(["sonic", "mario"])
	race = r
	add_child(r)


func _physics_process(_d: float) -> void:
	if race == null or race.racers.is_empty():
		return
	if frames == 0:
		for rc in race.racers:
			splits[rc.display_name] = []
			seen[rc.display_name] = {}
			disp[rc.display_name] = 0.0
		for rc in race.racers:
			rc.respawned.connect(func(r, why, at): print("  RESPAWN %s: %s at %s idx=%d" % [r.display_name, why, at.snapped(Vector3.ONE * 0.1), r.track_index]))
		EventBus.checkpoint_passed.connect(func(rc, k): splits[rc.display_name].append("CP%d@%.1fs" % [k, rc.race_time]))
	frames += 1
	if frames == 60 * 12:     # verify the hit reaction on every racer once
		for rc in race.racers:
			rc.movement.take_hit(0.6)
	for rc in race.racers:
		var v := rc.visual
		if v is RunnerVisual:
			seen[rc.display_name][(v as RunnerVisual).current_state] = true
			disp[rc.display_name] = maxf(disp[rc.display_name], (v as RunnerVisual).rig.max_displacement())
		elif v is KartVisual:
			var kv := v as KartVisual
			if absf(kv.spin) > 0.1: seen[rc.display_name]["wheel_spin"] = true
			if absf(kv.steer_vis) > 0.1: seen[rc.display_name]["front_steer"] = true
			if absf(kv.lean) > 0.02: seen[rc.display_name]["body_lean"] = true
			if absf(kv.head_yaw) > 0.1: seen[rc.display_name]["head_turn"] = true
			if rc.movement.anim.drift_dir != 0: seen[rc.display_name]["drift"] = true
			disp[rc.display_name] = maxf(disp[rc.display_name], kv.kart.max_displacement())
		if rc.on_rail: seen[rc.display_name]["loop"] = true
		if rc.movement.anim.hit > 0.0: seen[rc.display_name]["hit_state"] = true
		if rc.movement.anim.dashing: seen[rc.display_name]["dash"] = true
		if rc.movement.anim.boosting: seen[rc.display_name]["mini_turbo"] = true
		if rc.movement.anim.jumping: seen[rc.display_name]["jumping"] = true
		if rc.track.locate(rc.global_position, rc.track_index).on_fork: seen[rc.display_name]["alt_route"] = true
	for rc in race.racers:
		if _trace.size() == 2 and rc.track_index >= _trace[0] and rc.track_index <= _trace[1] and frames % 6 == 0 and frames < 60 * 40:
			print("   trace %s f=%d idx=%d pos=%s v=%s floor=%s surf=%s rail=%s" % [rc.display_name, frames, rc.track_index, rc.global_position.snapped(Vector3.ONE*0.1), rc.velocity.snapped(Vector3.ONE*0.1), rc.is_on_floor(), rc.movement.floor_surface(), rc.on_rail])
			for ci in rc.get_slide_collision_count():
				var c := rc.get_slide_collision(ci)
				print("      hit n=%s at=%s %s" % [c.get_normal().snapped(Vector3.ONE * 0.01), c.get_position().snapped(Vector3.ONE * 0.01), c.get_collider().name])
	if frames % 600 == 0:
		for rc in race.racers:
			print("t=%5.1fs %-6s cp=%d lap=%d idx=%d speed=%.1f pos=%s respawns=%d" % [rc.race_time, rc.display_name,
				rc.next_cp, rc.laps_done, rc.track_index, rc.movement.speed, rc.global_position.snapped(Vector3.ONE * 0.1), rc.respawns])
	var done := race.racers.all(func(rc): return rc.has_finished)
	if done or frames >= max_frames:
		print("\n==== RESULT after %.1fs sim ====" % (frames / 60.0))
		var ok := true
		for rc in race.racers:
			print("%s (%s): finished=%s time=%.2f laps=%s respawns=%d" % [rc.display_name, rc.character, rc.has_finished, rc.race_time, str(rc.lap_times), rc.respawns])
			print("   splits: ", " ".join(splits[rc.display_name]))
			print("   seen: ", seen[rc.display_name].keys(), "  max vertex displacement %.3f m" % disp[rc.display_name])
			ok = ok and rc.has_finished
		print("ALL FINISHED" if ok else "NOT ALL FINISHED")
		get_tree().quit(0 if ok else 1)
