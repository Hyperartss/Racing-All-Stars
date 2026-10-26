extends SceneTree
## Character Importer checks (headless):
##   godot --headless -s tools/test_importer.gd [-- --export]
## 1. Mario OBJ, auto split -> compared vertex-by-vertex with the hand-made rig
## 2. Sonic DAE, node split  -> compared with the hand-made rig
## With --export also writes mario_runner (runner) and sonic_kart (kart driver).

func _init() -> void:
	var do_export := OS.get_cmdline_user_args().has("--export")
	var ok := true
	# --- Mario, auto split
	var mi := CharacterImporter.new()
	mi.id = "mario_runner"
	mi.display_name = "Mario (Runner)"
	mi.type = "runner"
	mi.facing = "+Z"
	mi.height = 0.85
	var err := mi.load_source("res://import/mario_ps1/MarioPS1.obj")
	if err != "":
		print("FAIL ", err); quit(1); return
	mi.split = "auto"
	mi.make_groups()
	mi.analyse()
	print("Mario measure: ", _fmt(mi.measure))
	print("Mario notes: ", mi.notes)
	print("Mario parts: ", mi.role_counts())
	var agree := _compare(mi, "res://assets/rigs/mario.json")
	print("Mario agreement with hand-made rig: %.1f%%" % (agree * 100.0))
	ok = ok and agree > 0.85
	# --- Sonic, nodes
	var si := CharacterImporter.new()
	si.id = "sonic_kart"
	si.display_name = "Sonic (Kart)"
	si.type = "kart"
	si.facing = "-X"
	si.height = 1.1
	err = si.load_source("res://import/sonic_r/Sonic.dae")
	if err != "":
		print("FAIL ", err); quit(1); return
	si.split = "nodes"
	si.make_groups()
	var mapping := {"Grp00": "torso", "Grp01": "head", "Grp04": "arm_upper_l", "Grp02": "arm_lower_l",
		"Grp08": "arm_upper_r", "Grp06": "arm_lower_r", "Grp05": "leg_upper_l", "Grp03": "leg_lower_l",
		"Grp09": "leg_upper_r", "Grp07": "leg_lower_r", "Grp10": "tail"}
	for g in si.groups:
		g.role = mapping.get(g.name, "auto")
	si.analyse()
	print("Sonic groups: ", si.groups.map(func(g): return "%s=%s" % [g.name, g.role]))
	print("Sonic joints: ", _fmt(si.joints))
	var agree2 := _compare(si, "res://assets/rigs/sonic.json", {"torso": "body", "leg_lower_l": "foot_l", "leg_lower_r": "foot_r"})
	print("Sonic agreement with hand-made rig: %.1f%%" % (agree2 * 100.0))
	ok = ok and agree2 > 0.95
	# Sonic, fully automatic too (how well does auto do on a model in pieces?)
	var sa := CharacterImporter.new()
	sa.facing = "-X"
	sa.height = 1.1
	sa.load_source("res://import/sonic_r/Sonic.dae")
	sa.analyse()
	print("Sonic auto measure: ", _fmt(sa.measure))
	print("Sonic auto agreement: %.1f%%" % (_compare(sa, "res://assets/rigs/sonic.json", {"torso": "body", "hips": "body", "leg_lower_l": "foot_l", "leg_lower_r": "foot_r"}) * 100.0))
	print("Mario paint: ", JSON.stringify(mi.detect_paint()))
	print("Sonic paint: ", JSON.stringify(si.detect_paint()))
	if do_export:
		print("wrote ", mi.export(mi.detect_paint()))
		print("wrote ", si.export(si.detect_paint()))
	print("IMPORTER ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _fmt(d: Dictionary) -> String:
	var s := []
	for k in d:
		var v = d[k]
		if v is float:
			s.append("%s=%.3f" % [k, v])
		elif v is Vector3:
			s.append("%s=(%.2f,%.2f,%.2f)" % [k, v.x, v.y, v.z])
		else:
			s.append("%s=%s" % [k, v])
	return ", ".join(s)


## Fraction of importer vertices whose part matches the nearest vertex of a
## hand-made rig (same model, same normalisation).
func _compare(imp: CharacterImporter, rig_path: String, rename := {}) -> float:
	var data: Dictionary = JSON.parse_string(FileAccess.open(rig_path, FileAccess.READ).get_as_text())
	var names: Array = data.parts.map(func(p): return p.name)
	var ref_p: Array[Vector3] = []
	var ref_n: Array[String] = []
	for s in data.surfaces:
		for k in s.pa.size():
			ref_p.append(Vector3(s.pos[k * 3], s.pos[k * 3 + 1], s.pos[k * 3 + 2]))
			ref_n.append(names[s.pa[k]])
	var rig := imp.build_rig()
	var inames: Array = rig.parts.map(func(p): return p.name)
	var good := 0
	var total := 0
	var confusion := {}
	for s in rig.surfaces:
		for k in s.pa.size():
			var p := Vector3(s.pos[k * 3], s.pos[k * 3 + 1], s.pos[k * 3 + 2])
			var best := 0
			var bd := INF
			for i in ref_p.size():
				var d := p.distance_squared_to(ref_p[i])
				if d < bd:
					bd = d
					best = i
			var mine: String = inames[s.pa[k]]
			mine = rename.get(mine, mine)
			total += 1
			if mine == ref_n[best]:
				good += 1
			else:
				var key: String = ref_n[best] + "->" + mine
				confusion[key] = confusion.get(key, 0) + 1
	print("  mismatches (reference->imported): ", confusion)
	return good / float(maxi(total, 1))
