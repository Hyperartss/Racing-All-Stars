extends SceneTree
## Dump imported character/kart meshes to OBJ for visual part identification.

func _save(mesh: Mesh, path: String, xform: Transform3D) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	var base := 0
	for s in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		f.store_line("g surf%d" % s)
		for p in v:
			var w: Vector3 = xform * p
			f.store_line("v %.5f %.5f %.5f" % [w.x, w.y, w.z])
		var idxa: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		if idxa.is_empty():
			for t in v.size() / 3:
				f.store_line("f %d %d %d" % [base + t*3 + 1, base + t*3 + 2, base + t*3 + 3])
		else:
			var k := 0
			while k + 2 < idxa.size():
				f.store_line("f %d %d %d" % [base + idxa[k] + 1, base + idxa[k+1] + 1, base + idxa[k+2] + 1])
				k += 3
		base += v.size()
	f.close()
	print("wrote ", path, " verts=", base)

func _init() -> void:
	DirAccess.make_dir_recursive_absolute("res://dumps")

	var ps: PackedScene = load("res://assets/characters/sonic/Sonic.dae")
	var root: Node = ps.instantiate()
	_walk(root)
	root.free()

func _walk(n: Node) -> void:
	if n is MeshInstance3D:
		_save(n.mesh, "res://dumps/sonic_%s.obj" % n.name, n.global_transform)
	for c in n.get_children():
		_walk(c)

	_save(load("res://assets/characters/mario/MarioPS1.obj"), "res://dumps/mario.obj", Transform3D.IDENTITY)
	_save(load("res://assets/karts/kart.obj"), "res://dumps/kart.obj", Transform3D.IDENTITY)
	print("done")
