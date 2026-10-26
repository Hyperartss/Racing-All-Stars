extends SceneTree
## Per-part: raw mesh AABB (untransformed) + global transform, for diagnosing rest pose.

func _init() -> void:
	var ps: PackedScene = load("res://assets/characters/sonic/Sonic.dae")
	var root: Node = ps.instantiate()
	print("--- SONIC parts ---")
	_walk(root)
	root.free()
	var mar: Mesh = load("res://assets/characters/mario/MarioPS1.obj")
	var ab: AABB = mar.get_aabb()
	print("\nMARIO mesh aabb pos=", ab.position, " size=", ab.size)
	var kart: Mesh = load("res://assets/karts/kart.obj")
	var ab2: AABB = kart.get_aabb()
	print("KART  mesh aabb pos=", ab2.position, " size=", ab2.size)

func _walk(n: Node, d: int = 0) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var raw: AABB = mi.mesh.get_aabb()
		var gx: Basis = mi.global_transform.basis
		var gt: Vector3 = mi.global_transform.origin
		var gscale := Vector3(gx.get_scale())
		# world-space aabb from global transform
		var world := raw * mi.global_transform
		print("%s%-8s rawpos=(%.2f,%.2f,%.2f) rawsize=(%.2f,%.2f,%.2f)" % ["  ".repeat(d), n.name,
			raw.position.x, raw.position.y, raw.position.z, raw.size.x, raw.size.y, raw.size.z])
		print("%s         g_origin=(%.2f,%.2f,%.2f) g_scale=(%.2f,%.2f,%.2f)  worldpos=(%.2f,%.2f,%.2f) worldsize=(%.2f,%.2f,%.2f)" % ["  ".repeat(d),
			gt.x, gt.y, gt.z, gscale.x, gscale.y, gscale.z,
			world.position.x, world.position.y, world.position.z, world.size.x, world.size.y, world.size.z])
	for c in n.get_children():
		_walk(c, d + 1)
