extends Node
## Seam/gap check: casts rays down onto the road across its width at every
## centreline sample of the main route and every alternate route.
## Run: godot --headless --path . res://scenes/check_floor.tscn -- --map=<id>
func _ready() -> void:
	var map_id := "retro_circuit"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			map_id = a.trim_prefix("--map=")
	var t := Track.new(); add_child(t)
	t.load_track(String(RacerTypes.maps()[map_id].data))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_viewport().world_3d.direct_space_state
	var misses := 0
	var checked := 0
	var road_hits := 0
	var paths: Array = [t.path]
	for f in t.forks:
		paths.append(f.path)
	for pass_i in paths.size():
		var p: TrackPath = paths[pass_i]
		for i in p.size():
			var w := p.width[i] if pass_i == 0 else 8.0
			for k in 11:
				var lat := lerpf(-0.48, 0.48, k / 10.0) * w
				var o := p.pos[i] + p.right[i] * lat
				var up := p.up[i]
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(o + up * 2.5, o - up * 6.0, 1))
				checked += 1
				if hit.is_empty():
					misses += 1
					if misses < 15:
						print("MISS %s sample %d lat %.1f at %s" % ["main" if pass_i == 0 else "alt%d" % pass_i, i, lat, o.snapped(Vector3.ONE * 0.1)])
				elif String(hit.collider.get_meta("surface", "")) == "road":
					road_hits += 1
	print("floor check %s: %d rays, %d misses (%.2f%%), %d on road surface (%.1f%%)" % [map_id, checked, misses, 100.0 * misses / checked, road_hits, 100.0 * road_hits / checked])
	get_tree().quit(0)
