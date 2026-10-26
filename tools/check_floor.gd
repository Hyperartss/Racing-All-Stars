extends Node
## Seam/gap check: casts rays down onto the road across its width at every
## centreline sample (main route + alternate route). Any miss is a hole.
func _ready() -> void:
	var t := Track.new(); add_child(t); t.load_track()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_viewport().world_3d.direct_space_state
	var misses := 0
	var checked := 0
	var road_hits := 0
	for pass_i in 2:
		var p := t.path if pass_i == 0 else t.fork
		for i in p.size():
			var w := p.width[i] if pass_i == 0 else 8.0
			for k in 11:
				var lat := lerpf(-0.48, 0.48, k / 10.0) * w
				var o := p.pos[i] + p.right[i] * lat
				var up := p.up[i]
				var q := PhysicsRayQueryParameters3D.create(o + up * 2.5, o - up * 6.0, 1)
				var hit := space.intersect_ray(q)
				checked += 1
				if hit.is_empty():
					misses += 1
					if misses < 25:
						print("MISS %s sample %d lat %.1f at %s" % ["main" if pass_i == 0 else "fork", i, lat, o.snapped(Vector3.ONE * 0.1)])
				elif String(hit.collider.get_meta("surface", "")) == "road":
					road_hits += 1
	print("floor check: %d rays, %d misses, %d on road surface (%.1f%%)" % [checked, misses, road_hits, 100.0 * road_hits / checked])
	get_tree().quit(0 if misses == 0 else 1)
