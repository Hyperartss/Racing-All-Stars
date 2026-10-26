extends SceneTree
## Renders views of the merged course to out/track_*.png (visual check of seams,
## connectors, loop and island section). Run with --rendering-driver opengl3.

func _init() -> void:
	get_root().size = Vector2i(960, 540)
	var env := RetroEnv.new()
	get_root().add_child(env)
	var t := Track.new()
	get_root().add_child(t)
	t.load_track()
	var cam := Camera3D.new()
	cam.far = 900.0
	cam.fov = 70.0
	get_root().add_child(cam)
	await process_frame
	print(t.path.size(), " samples, length ", t.path.length, " checkpoints ", t.checkpoints)
	var views := {
		"start": [0, -8.0, 3.0],
		"conn_a": [t.checkpoints[0] + 40, -10.0, 4.0],
		"loop": [-1, 0, 0],
		"island_entry": [t.data.island_span[0] - 4, -8.0, 3.5],
		"plateau": [t.data.island_span[0] + 75, -10.0, 4.0],
		"island_exit": [t.data.island_span[1] - 6, -8.0, 3.5],
		"conn_b": [t.data.island_span[1] + 6, -8.0, 3.5],
	}
	for name in views:
		var v: Array = views[name]
		var i: int = v[0]
		if name == "loop":
			for k in t.path.size():
				if t.path.flags[k] & TrackPath.FLAG_LOOP:
					i = k
					break
			var p := t.path.pos[i]
			cam.position = p + t.path.right[i] * 40.0 + Vector3(0, 12, 0) - t.path.tangent[i] * 10.0
			cam.look_at(p + Vector3(0, 10, 0) + t.path.tangent[i] * 8.0)
		else:
			i = t.path.wi(i)
			var p := t.path.pos[i]
			cam.position = p + t.path.tangent[i] * v[1] + Vector3(0, v[2], 0)
			cam.look_at(t.path.point_ahead(i, 25.0) + Vector3(0, 1.0, 0))
		for k in 3:
			await process_frame
		get_root().get_texture().get_image().save_png("res://out/track_%s.png" % name)
	# overview
	for c in env.get_children():
		if c is WorldEnvironment:
			c.environment.fog_enabled = false
	cam.far = 2000.0
	cam.position = Vector3(-40, 330, 260)
	cam.look_at(Vector3(-40, 0, 10))
	for k in 3:
		await process_frame
	get_root().get_texture().get_image().save_png("res://out/track_overview.png")
	quit()
