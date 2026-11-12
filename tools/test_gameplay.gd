extends Node
## Gameplay test: an all-AI race with item boxes, rings, a ring door, dash panels and
## a spring placed along the course, plus direct checks of item odds, collectables /
## unlocks, skins and console looks. Exit code 0 = everything passed.
## Run: godot --headless --fixed-fps 60 --path . res://scenes/test_gameplay.tscn

var race: Race
var frames := 0
var max_frames := 60 * 320
var counts := {}
var fails := 0
var _placed := false


func _ok(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		fails += 1


func _ready() -> void:
	print("== unit checks")
	_unit_checks()
	GameState.race_config = {}
	var r := Race.new()
	r.player_index = -1
	r.laps = 2
	r.countdown = false
	r.roster = PackedStringArray(["sonic", "eggman", "tails", "amy", "shadow", "metalsonic"])
	race = r
	add_child(r)
	EventBus.racer_action.connect(func(_rc, action, _d): counts[String(action)] = int(counts.get(String(action), 0)) + 1)


func _place(type: String, dist: float, params: Dictionary = {}, lateral := 0.0) -> Node3D:
	var path := race.track.path
	var i := path.index_at_distance(fposmod(dist, path.length))
	var t := path.tangent[i]
	var pos := path.pos[i] + path.right[i] * lateral
	var e := {"type": type, "pos": [pos.x, pos.y, pos.z], "yaw": rad_to_deg(atan2(-t.x, -t.z)),
		"scale": 1.0, "params": params}
	var n := TrackProps.make(e, false)
	race.track.props_root.add_child(n)
	return n


func _place_course() -> void:
	var L := race.track.path.length
	var d := 60.0
	var k := 0
	while d < L - 40.0:
		_place("item_box_row", d, {"count": 4})
		_place("ring_line", d + 35.0, {"count": 6, "spacing": 2.5})
		if k % 3 == 1:
			_place("dash_pad", d + 55.0)
		d += 130.0
		k += 1
	_place("spring", 240.0, {"launch": 9.0})
	# A door across the main road: AI racers pay for it with the rings above.
	_place("ring_door", 520.0, {"cost": 3, "width": 14.0, "open_seconds": 3.0})
	print("placed objects: %d" % race.track.props_root.get_child_count())


func _physics_process(_d: float) -> void:
	if race == null or race.racers.is_empty():
		return
	if not _placed:
		_placed = true
		_place_course()
	frames += 1
	var all := true
	for rc in race.racers:
		all = all and rc.has_finished
	if all or frames >= max_frames:
		_report(all)
		set_physics_process(false)
		get_tree().quit(0 if fails == 0 else 1)


func _report(all: bool) -> void:
	print("\n== race (%.1fs)" % (frames / 60.0))
	for rc in race.racers:
		print("  %-22s finished=%s time=%.1f respawns=%d rings=%d slot=%s" % [rc.display_name, rc.has_finished,
			rc.race_time, rc.respawns, rc.items.rings, rc.items.slot])
	print("  actions: ", counts)
	_ok(all, "every racer finished 2 laps with items on")
	_ok(int(counts.get("item", 0)) >= 6, "AI racers used items (%d)" % int(counts.get("item", 0)))
	_ok(int(counts.get("ring", 0)) >= 10, "rings were collected (%d)" % int(counts.get("ring", 0)))
	_ok(int(counts.get("hit", 0)) >= 1, "items hit someone (%d)" % int(counts.get("hit", 0)))
	_ok(int(counts.get("door", 0)) >= 1, "the ring door was bought (%d)" % int(counts.get("door", 0)))
	_ok(int(counts.get("spring", 0)) >= 1, "the spring launched someone (%d)" % int(counts.get("spring", 0)))
	_ok(int(counts.get("boost", 0)) >= 3, "boosts happened (pads, items, turbos) (%d)" % int(counts.get("boost", 0)))
	print("GAMEPLAY TEST: " + ("PASS" if fails == 0 else "FAIL (%d)" % fails))


func _unit_checks() -> void:
	ItemTypes.reload()
	ObjectTypes.reload()
	_ok(ItemTypes.items().size() >= 18, "item definitions loaded (%d)" % ItemTypes.items().size())
	_ok(ItemTypes.behaviours().size() >= 11, "item behaviours found (%d)" % ItemTypes.behaviours().size())
	for id in ItemTypes.items():
		_ok(ItemTypes.behaviour_of(id) != null, "item '%s' has a behaviour" % id)
	_ok(ObjectTypes.defs().size() >= 10, "object types loaded (%d)" % ObjectTypes.defs().size())
	for t in ObjectTypes.defs():
		var n := ObjectTypes.make({"type": t, "pos": [0, 0, 0]}, true)
		_ok(n is TrackObject and n.get_child_count() > 0, "object '%s' builds a preview" % t)
		n.free()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var lead := {}
	var last := {}
	for k in 3000:
		var a := ItemTypes.roll(0, 12, "kart", rng)
		var b := ItemTypes.roll(11, 12, "kart", rng)
		lead[a] = int(lead.get(a, 0)) + 1
		last[b] = int(last.get(b, 0)) + 1
	_ok(not lead.has("spiny_shell") and not lead.has("bullet_bill") and not lead.has("star"), "1st place never rolls spiny / bullet / star")
	_ok(int(lead.get("banana", 0)) > 400, "1st place mostly rolls defensive items (%d bananas)" % int(lead.get("banana", 0)))
	_ok(not last.has("banana") and int(last.get("bullet_bill", 0)) > 300, "last place gets catch-up items")
	# Rules defaults + override
	GameRules.reload()
	_ok(GameRules.b("items_enabled"), "rules: items on by default")
	GameRules.set_override("items_enabled", false)
	_ok(not GameRules.b("items_enabled"), "rules: override works")
	GameRules.reload()
	# Progress / unlocks (uses a scratch copy of the progress file)
	var had := FileAccess.file_exists(PlayerProgress.PATH)
	var backup := FileAccess.get_file_as_string(PlayerProgress.PATH) if had else ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PlayerProgress.PATH))
	PlayerProgress.load_progress()
	var chars := {"a": {}, "b": {"unlock": {"token": 2}}}
	_ok(not PlayerProgress.is_unlocked(chars.b), "locked character starts locked")
	PlayerProgress.pick_up("m1", "token", "t1")
	PlayerProgress.pick_up("m1", "token", "t2")
	PlayerProgress.clear_pending()
	_ok(PlayerProgress.count("token") == 0, "pick-ups are lost when the race is not finished")
	PlayerProgress.pick_up("m1", "token", "t1")
	PlayerProgress.pick_up("m1", "token", "t1")
	PlayerProgress.pick_up("m2", "token", "t9")
	var fresh := PlayerProgress.commit("m1", 61.0, chars)
	_ok(PlayerProgress.count("token") == 2 and PlayerProgress.has("m1", "t1"), "finishing keeps them (no duplicates)")
	_ok(fresh == ["b"], "the unlock is reported once (%s)" % [fresh])
	PlayerProgress.load_progress()
	_ok(PlayerProgress.count("token") == 2, "progress survives a reload")
	if had:
		var fa := FileAccess.open(PlayerProgress.PATH, FileAccess.WRITE)
		fa.store_string(backup)
		fa.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PlayerProgress.PATH))
	PlayerProgress.load_progress()
	# Looks
	_ok(RetroLook.looks().size() >= 4, "console looks loaded (%d)" % RetroLook.looks().size())
	RetroLook.set_look("dreamcast")
	_ok(RetroLook.linear() and RetroLook.rig_shader().code.contains("filter_linear"), "Dreamcast look filters textures")
	RetroLook.set_look("saturn")
	_ok(not RetroLook.linear() and RetroLook.rig_shader() == RetroLook.RIG_SHADER, "Saturn look keeps nearest")
	RetroLook.set_look("classic")
	# Skins: Super Shadow swaps the texture only (same vertices, same faces).
	var plain := RacerTypes.make_visual("shadow", {})
	var sup := RacerTypes.make_visual("shadow", {"skin": "super"})
	add_child(plain)
	add_child(sup)
	var rp: VertexRig = plain.get("rig")
	var rs: VertexRig = sup.get("rig")
	var same := rp != null and rs != null and rp._surf.size() == rs._surf.size()
	if same:
		for si in rp._surf.size():
			same = same and (rp._surf[si].rest_pos as PackedVector3Array).size() == (rs._surf[si].rest_pos as PackedVector3Array).size()
	_ok(same, "a skin keeps the model's geometry untouched")
	var t0: Texture2D = (rs._surf[0].mat as ShaderMaterial).get_shader_parameter("tex")
	_ok(t0 != null and t0.resource_path.ends_with("SuperShadow.png"), "Super Shadow skin texture is applied")
	plain.queue_free()
	sup.queue_free()
