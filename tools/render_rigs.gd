extends SceneTree
## Visual check of the vertex-animated rigs: renders Sonic (idle/run/jump/hit) and the
## kart+Mario (straight, steering, drifting) to out/rigs_*.png.
## Run: godot --rendering-driver opengl3 --path . -s tools/render_rigs.gd

func _snap(cam: Camera3D, file: String) -> void:
	for i in 3:
		await process_frame
	get_root().get_texture().get_image().save_png("res://out/" + file)


func _init() -> void:
	get_root().size = Vector2i(960, 540)
	var root := Node3D.new()
	get_root().add_child(root)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.35, 0.45, 0.6)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.75)
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(sun)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(20, 20)
	floor.mesh = pm
	root.add_child(floor)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	root.add_child(cam)
	await process_frame

	# --- Sonic, four states side by side, seen from 3/4 front and from the side
	var states := [["idle", 0.0, true, false, 0.0], ["run", 28.0, true, false, 0.0],
		["jump", 20.0, false, true, 0.0], ["hit", 5.0, true, false, 0.5]]
	var sonics: Array = []
	for i in states.size():
		var v := SonicVisual.new()
		root.add_child(v)
		v.position = Vector3(-2.1 + i * 1.4, 0, 0)
		sonics.append(v)
	for frame in 20:
		for i in states.size():
			var st := RacerVisual.AnimState.new()
			st.speed = states[i][1]; st.max_speed = 28.0
			st.grounded = states[i][2]; st.jumping = states[i][3]; st.hit = states[i][4]
			sonics[i].update_visual(st, 1.0 / 60.0)
	cam.size = 2.4
	cam.position = Vector3(0, 0.6, 5); cam.look_at(Vector3(0, 0.55, 0))
	cam.rotation.y = 0.0
	await _snap(cam, "rigs_sonic_front.png")
	for v in sonics: v.rotation.y = PI * 0.5
	await _snap(cam, "rigs_sonic_side.png")
	for v in sonics: v.queue_free()

	# --- Kart: straight, steering left, drifting right (3/4 view and side)
	var karts: Array = []
	var ks := [[20.0, 0.0, 0], [20.0, 1.0, 0], [20.0, -0.6, -1]]
	for i in ks.size():
		var kv := KartVisual.new()
		root.add_child(kv)
		kv.position = Vector3(-1.8 + i * 1.8, 0, 0)
		karts.append(kv)
	for frame in 40:
		for i in ks.size():
			var st := RacerVisual.AnimState.new()
			st.speed = ks[i][0]; st.max_speed = 24.0; st.steer = ks[i][1]; st.drift_dir = ks[i][2]
			karts[i].update_visual(st, 1.0 / 60.0)
	cam.size = 2.0
	for kv in karts: kv.rotation.y = PI * 0.8
	cam.position = Vector3(0, 1.6, 5); cam.look_at(Vector3(0, 0.35, 0))
	await _snap(cam, "rigs_kart_front.png")
	for kv in karts: kv.rotation.y = PI * 0.5
	cam.position = Vector3(0, 0.5, 5); cam.look_at(Vector3(0, 0.4, 0))
	await _snap(cam, "rigs_kart_side.png")
	for kv in karts: kv.rotation.y = 0.0
	cam.position = Vector3(0, 6, 0.01); cam.look_at(Vector3(0, 0, 0))
	await _snap(cam, "rigs_kart_top.png")
	print("rig displacement check: kart=%.3f driver=%.3f" % [karts[1].kart.max_displacement(), karts[1].driver.max_displacement()])
	quit()
