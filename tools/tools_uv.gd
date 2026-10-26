extends SceneTree
## Dump each Sonic part's triangles in UV space so we can see which atlas cell it uses.

func _init() -> void:
	var ps: PackedScene = load("res://assets/characters/sonic/Sonic.dae")
	var root: Node = ps.instantiate()
	var f := FileAccess.open("res://dumps/sonic_uv.txt", FileAccess.WRITE)
	_walk(root, f)
	root.free()
	f.close()
	print("done")

func _walk(n: Node, f: FileAccess) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(s)
			var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			if uv.is_empty(): continue
			if idx.is_empty():
				for t in uv.size() / 3:
					var a := uv[t*3]; var b := uv[t*3+1]; var c := uv[t*3+2]
					f.store_line("%s %.5f %.5f %.5f %.5f %.5f %.5f" % [n.name, a.x,a.y,b.x,b.y,c.x,c.y])
			else:
				var k := 0
				while k + 2 < idx.size():
					var a := uv[idx[k]]; var b := uv[idx[k+1]]; var c := uv[idx[k+2]]
					f.store_line("%s %.5f %.5f %.5f %.5f %.5f %.5f" % [n.name, a.x,a.y,b.x,b.y,c.x,c.y])
					k += 3
	for ch in n.get_children():
		_walk(ch, f)
