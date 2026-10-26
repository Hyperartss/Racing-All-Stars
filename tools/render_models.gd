extends SceneTree
## Renders Sonic, Mario and the kart side by side (front + side views) and prints Sonic's part tree.

func _init() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var env := WorldEnvironment.new(); env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.25, 0.3, 0.4)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 1.0
	root.add_child(env)
	var sonic: Node3D = (load("res://assets/characters/sonic/Sonic.dae") as PackedScene).instantiate()
	root.add_child(sonic); sonic.scale = Vector3.ONE * 0.1; sonic.position = Vector3(-1.5, 0.55, 0)
	var mario := MeshInstance3D.new(); mario.mesh = load("res://assets/characters/mario/MarioPS1.obj")
	mario.scale = Vector3.ONE * 0.012; mario.position = Vector3(0, 0, 0); root.add_child(mario)
	var kart := MeshInstance3D.new(); kart.mesh = load("res://assets/karts/kart_MR_a.obj")
	kart.position = Vector3(1.5, 0, 0); root.add_child(kart)
	var cam := Camera3D.new(); root.add_child(cam)
	await process_frame
	_tree(sonic, 0)
	var vp := get_root()
	vp.size = Vector2i(1200, 600)
	for view in [["front", Vector3(0, 0.6, 6), Vector3(0, 0.6, 0)], ["side", Vector3(6, 0.6, 0.01), Vector3(0, 0.6, 0)], ["top", Vector3(0, 8, 0.01), Vector3(0, 0, 0)]]:
		cam.position = view[1]; cam.look_at(view[2])
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL; cam.size = 1.9
		for i in 4: await process_frame
		vp.get_texture().get_image().save_png("res://out/models_%s.png" % view[0])
	quit()

func _tree(n: Node, d: int) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var w: AABB = mi.global_transform * mi.mesh.get_aabb()
		print("  ".repeat(d), n.name, " origin=", mi.global_position.snapped(Vector3.ONE*0.01), " world_aabb pos=", w.position.snapped(Vector3.ONE*0.01), " size=", w.size.snapped(Vector3.ONE*0.01), " verts=", mi.mesh.surface_get_array_len(0))
	elif n is Node3D:
		print("  ".repeat(d), n.name, " [", n.get_class(), "] origin=", (n as Node3D).global_position.snapped(Vector3.ONE*0.01))
	for c in n.get_children(): _tree(c, d + 1)
