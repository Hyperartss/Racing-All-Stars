extends SceneTree
## Headless inspection of imported assets: node tree, mesh names, surfaces, AABB, bones, anims.

const TARGETS := [
	["SONIC", "res://assets/characters/sonic/Sonic.dae"],
	["MARIO", "res://assets/characters/mario/MarioPS1.obj"],
	["KART_PC", "res://assets/karts/kart.obj"],
	["MARIO_RACEWAY", "res://assets/tracks/mario_raceway/Mario Raceway.obj"],
	["RESORT_ISLAND", "res://assets/tracks/resort_island/island.obj"],
]

func _init() -> void:
	for t in TARGETS:
		print("\n", "=".repeat(78))
		print(t[0], "  ->  ", t[1])
		if not ResourceLoader.exists(t[1]):
			print("  !! MISSING"); continue
		var res: Resource = load(t[1])
		if res == null:
			print("  !! FAILED TO LOAD"); continue
		if res is Mesh:
			_report_mesh(res, t[0])
			continue
		var root: Node = (res as PackedScene).instantiate()
		_report(root, 1)
		root.free()

func _report_mesh(m: Mesh, label: String) -> void:
	var ab: AABB = m.get_aabb()
	print("  - loaded as ", m.get_class(), " directly")
	print("    aabb pos=", ab.position, "  size=", ab.size)
	if m is ArrayMesh:
		var am := m as ArrayMesh
		print("    surfaces=", am.get_surface_count())
		for i in am.get_surface_count():
			var arr: Array = am.surface_get_arrays(i)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var mat: Material = am.surface_get_material(i)
			print("      s%-3d verts=%-5d mat='%s'" % [i, v.size(), mat.resource_name if mat else "<none>"])

func _report(n: Node, d: int) -> void:
	var pad := "  ".repeat(d)
	var kind := n.get_class()
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var m: Mesh = mi.mesh
		var ab: AABB = m.get_aabb() if m else AABB()
		print(pad, "- MeshInstance3D '", n.name, "'")
		if m is ArrayMesh:
			var am := m as ArrayMesh
			print(pad, "    surfaces=", am.get_surface_count())
			for i in mini(am.get_surface_count(), 400):
				var arr: Array = am.surface_get_arrays(i)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var mat: Material = am.surface_get_material(i)
				var mname := mat.resource_name if mat else "<none>"
				if i < 12 or i >= am.get_surface_count() - 2:
					print(pad, "      s%-3d verts=%-5d mat='%s'" % [i, v.size(), mname])
		else:
			print(pad, "    mesh class=", m.get_class() if m else "null")
		print(pad, "    aabb pos=", ab.position, "  size=", ab.size)
		if mi.skin:
			print(pad, "    SKIN bones=", mi.skin.get_bone_count())
	elif n is AnimationPlayer:
		print(pad, "- AnimationPlayer anims=", (n as AnimationPlayer).get_animation_list())
	elif n is Skeleton3D:
		print(pad, "- Skeleton3D bones=", (n as Skeleton3D).get_bone_count())
	else:
		print(pad, "- ", kind, " '", n.name, "'")
	for c in n.get_children():
		_report(c, d + 1)
