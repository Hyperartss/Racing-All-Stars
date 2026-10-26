extends Node3D
## Main menu: Title -> Character -> Customise -> Map -> race.
## The selected racer stands on a turntable on the right, rebuilt live as the
## player changes character or paint. Everything listed comes from res://content/,
## so imported characters and combined maps show up automatically.

const YELLOW := Color(1.0, 0.86, 0.25)
const PANEL := Color(0.08, 0.1, 0.28, 0.88)
const RACE_SCENE := "res://scenes/race.tscn"

var ui: CanvasLayer
var screens := {}
var current := ""
var prof: Dictionary
var stage: Node3D
var preview: RacerVisual
var preview_char := ""
var _anim := RacerVisual.AnimState.new()
var _t := 0.0

# widgets we update
var char_buttons := {}
var char_info: Label
var custom_box: VBoxContainer
var map_buttons := {}
var map_info: Label
var map_image: TextureRect
var laps_spin: SpinBox
var opp_spin: SpinBox


func _ready() -> void:
	prof = Profile.load_profile()
	RacerTypes.reload()
	if not RacerTypes.characters().has(prof.character):
		prof.character = RacerTypes.characters().keys()[0]
	if not RacerTypes.maps().has(prof.map):
		prof.map = RacerTypes.maps().keys()[0]
	_build_stage()
	ui = CanvasLayer.new()
	add_child(ui)
	_build_title()
	_build_characters()
	_build_customise()
	_build_maps()
	show_screen("title")
	_refresh_preview()


# --- 3D stage ----------------------------------------------------------------------

func _build_stage() -> void:
	add_child(RetroEnv.new())
	stage = Node3D.new()
	add_child(stage)
	var plat := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.25
	cyl.bottom_radius = 1.35
	cyl.height = 0.2
	cyl.radial_segments = 16
	plat.mesh = cyl
	var m := StandardMaterial3D.new()
	var tex_path := "res://assets/maps/retro_circuit/tex/92276f6_c.png"
	if ResourceLoader.exists(tex_path):
		m.albedo_texture = load(tex_path)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.uv1_scale = Vector3(4, 4, 1)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	plat.material_override = m
	plat.position.y = -0.1
	stage.add_child(plat)
	var cam := Camera3D.new()
	cam.fov = 42.0
	cam.position = Vector3(-1.25, 1.05, 3.3)
	cam.look_at(Vector3(-1.25, 0.55, 0))
	add_child(cam)
	cam.current = true


func _refresh_preview() -> void:
	var cid: String = prof.character
	if preview:
		preview.queue_free()
	preview = RacerTypes.make_visual(cid, Profile.custom_for(cid))
	preview_char = cid
	stage.add_child(preview)


func _process(delta: float) -> void:
	_t += delta
	stage.rotation.y += delta * 0.6
	if preview and is_instance_valid(preview) and preview.is_node_ready():
		_anim.speed = 0.0
		_anim.max_speed = 20.0
		_anim.grounded = true
		_anim.steer = sin(_t * 0.9) * 0.6     # karts: wheels steer, head looks around
		preview.update_visual(_anim, delta)


# --- UI helpers --------------------------------------------------------------------

func _panel(name_: String) -> VBoxContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.border_color = YELLOW
	sb.set_border_width_all(2)
	sb.set_content_margin_all(8)
	pc.add_theme_stylebox_override("panel", sb)
	pc.position = Vector2(10, 10)
	pc.custom_minimum_size = Vector2(300, 340)
	pc.size = Vector2(300, 340)
	ui.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	pc.add_child(v)
	screens[name_] = pc
	return v


func _label(parent: Control, text: String, size_px: int = 12, colour: Color = Color.WHITE, wrap: bool = true) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", Color(0.05, 0.02, 0.15))
	l.add_theme_constant_override("outline_size", 3)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 60
	parent.add_child(l)
	return l


func _button(parent: Control, text: String, cb: Callable, size_px: int = 13) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size_px)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _swatch(parent: Control, c: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(18, 18)
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_border_width_all(1)
	sb.border_color = Color(0, 0, 0)
	b.add_theme_stylebox_override("normal", sb)
	var sh := sb.duplicate()
	sh.border_color = YELLOW
	sh.set_border_width_all(2)
	b.add_theme_stylebox_override("hover", sh)
	b.add_theme_stylebox_override("focus", sh)
	b.add_theme_stylebox_override("pressed", sh)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func show_screen(n: String) -> void:
	current = n
	for k in screens:
		screens[k].visible = (k == n)
	var first := _first_button(screens[n])
	if first:
		first.grab_focus.call_deferred()


func _first_button(n: Node) -> Control:
	for c in n.get_children():
		if c is BaseButton:
			return c
		var r := _first_button(c)
		if r:
			return r
	return null


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		match current:
			"characters": show_screen("title")
			"customise": show_screen("characters")
			"maps": show_screen("customise")


# --- Screens -----------------------------------------------------------------------

func _build_title() -> void:
	var v := _panel("title")
	_label(v, "RETRO\nKARTING", 34, YELLOW)
	_label(v, "Mario Kart x Sonic R", 13)
	var gap := Control.new()
	gap.custom_minimum_size.y = 30
	v.add_child(gap)
	_button(v, "RACE", func(): show_screen("characters"), 18)
	_button(v, "QUIT", func(): get_tree().quit(), 14)
	var gap2 := Control.new()
	gap2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(gap2)
	_label(v, "New characters: Project > Tools > Character Importer\nNew maps: Map Combiner dock", 9, Color(0.75, 0.8, 1.0))


func _build_characters() -> void:
	var v := _panel("characters")
	_label(v, "CHOOSE YOUR RACER", 16, YELLOW)
	var grid := GridContainer.new()
	grid.columns = 2
	v.add_child(grid)
	for cid in RacerTypes.characters():
		var c: Dictionary = RacerTypes.characters()[cid]
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(138, 34)
		b.text = "%s\n%s" % [c.get("name", cid), String(RacerTypes.TYPES.get(c.get("type", "runner"), {}).get("label", c.get("type", ""))).to_upper()]
		b.add_theme_font_size_override("font_size", 11)
		b.pressed.connect(_pick_character.bind(cid))
		b.focus_entered.connect(_pick_character.bind(cid))
		grid.add_child(b)
		char_buttons[cid] = b
	char_info = _label(v, "", 11)
	char_info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	v.add_child(row)
	_button(row, "< BACK", func(): show_screen("title"))
	var go := _button(row, "CUSTOMISE >", func(): _rebuild_customise(); show_screen("customise"))
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick_character(prof.character)


func _pick_character(cid: String) -> void:
	prof.character = cid
	for k in char_buttons:
		char_buttons[k].button_pressed = (k == cid)
	var c: Dictionary = RacerTypes.character(cid)
	var st: Dictionary = c.get("stats", {})
	var lines := ["%s  -  %s" % [c.get("name", cid), String(c.get("type", "")).to_upper()]]
	for k in ["speed", "accel", "handling"]:
		var n := int(st.get(k, 3))
		lines.append("%-9s %s" % [k.capitalize(), "#".repeat(n) + ".".repeat(5 - n)])
	if c.get("type", "") == "runner":
		lines.append("Space jump, Shift dash. Grass barely slows you.")
	else:
		lines.append("Hold Ctrl/Shift while steering to drift; release for a mini-turbo.")
	if char_info:
		char_info.text = "\n".join(lines)
	if preview_char != cid and stage:
		_refresh_preview()


func _build_customise() -> void:
	var v := _panel("customise")
	_label(v, "CUSTOMISE", 16, YELLOW)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	custom_box = VBoxContainer.new()
	custom_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(custom_box)
	var row := HBoxContainer.new()
	v.add_child(row)
	_button(row, "< BACK", func(): show_screen("characters"))
	_button(row, "RESET", _reset_custom)
	var go := _button(row, "MAP >", func(): show_screen("maps"))
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _rebuild_customise() -> void:
	for c in custom_box.get_children():
		c.queue_free()
	var cid: String = prof.character
	var c: Dictionary = RacerTypes.character(cid)
	var custom := Profile.custom_for(cid)
	_label(custom_box, String(c.get("name", cid)).to_upper(), 12, YELLOW)
	_zone_rows(c.get("paint", {}), custom, "paint")
	if c.get("type", "") == "kart":
		var kid: String = custom.get("kart", c.get("default_kart", "standard"))
		var karts := RacerTypes.karts()
		if karts.size() > 1:
			var ob := OptionButton.new()
			var i := 0
			for k in karts:
				ob.add_item(String(karts[k].get("name", k)))
				ob.set_item_metadata(i, k)
				if k == kid:
					ob.select(i)
				i += 1
			ob.item_selected.connect(func(ix):
				custom["kart"] = ob.get_item_metadata(ix)
				_rebuild_customise()
				_refresh_preview())
			custom_box.add_child(ob)
		var kart := RacerTypes.kart_def(kid)
		_label(custom_box, String(kart.get("name", "KART")).to_upper(), 12, YELLOW)
		_zone_rows(kart.get("paint", {}), custom, "kart_paint")


func _zone_rows(zones: Dictionary, custom: Dictionary, key: String) -> void:
	if not custom.has(key):
		custom[key] = {}
	var chosen: Dictionary = custom[key]
	for z in zones:
		var zone: Dictionary = zones[z]
		var mode: String = zone.get("mode", "swap")
		if mode == "toggle":
			var cb := CheckButton.new()
			cb.text = String(zone.get("label", z))
			cb.add_theme_font_size_override("font_size", 11)
			cb.button_pressed = bool(chosen.get(z, zone.get("default", true)))
			cb.toggled.connect(func(on): chosen[z] = on; _apply_custom())
			custom_box.add_child(cb)
			continue
		_label(custom_box, String(zone.get("label", z)), 11)
		var row := HFlowContainer.new()
		custom_box.add_child(row)
		for hexc in zone.get("presets", [zone.get("default", "#ffffff")]):
			_swatch(row, Color.html(String(hexc)), func(): chosen[z] = String(hexc); _apply_custom())
		var pick := ColorPickerButton.new()
		pick.custom_minimum_size = Vector2(26, 18)
		pick.color = Color.html(String(chosen.get(z, zone.get("default", "#ffffff"))))
		pick.edit_alpha = false
		pick.color_changed.connect(func(c2): chosen[z] = "#" + c2.to_html(false); _apply_custom())
		row.add_child(pick)


func _apply_custom() -> void:
	if preview and is_instance_valid(preview):
		preview.set_meta("custom", Profile.custom_for(prof.character))
		RacerTypes.apply_paint(preview)
	Profile.save()


func _reset_custom() -> void:
	var all: Dictionary = prof.customs
	all.erase(prof.character)
	_rebuild_customise()
	_refresh_preview()
	Profile.save()


func _build_maps() -> void:
	var v := _panel("maps")
	_label(v, "CHOOSE A COURSE", 16, YELLOW)
	var list := VBoxContainer.new()
	v.add_child(list)
	for mid in RacerTypes.maps():
		var m: Dictionary = RacerTypes.maps()[mid]
		var b := Button.new()
		b.toggle_mode = true
		b.text = String(m.get("name", mid))
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_pick_map.bind(mid))
		b.focus_entered.connect(_pick_map.bind(mid))
		list.add_child(b)
		map_buttons[mid] = b
	map_image = TextureRect.new()
	map_image.custom_minimum_size = Vector2(280, 110)
	map_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	map_image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	v.add_child(map_image)
	map_info = _label(v, "", 10)
	var opts := GridContainer.new()
	opts.columns = 4
	opts.add_theme_constant_override("h_separation", 8)
	v.add_child(opts)
	_label(opts, "Laps", 11, Color.WHITE, false)
	laps_spin = SpinBox.new()
	laps_spin.min_value = 1
	laps_spin.max_value = 9
	laps_spin.value = prof.laps
	laps_spin.value_changed.connect(func(x): prof.laps = int(x))
	opts.add_child(laps_spin)
	_label(opts, "Opponents", 11, Color.WHITE, false)
	opp_spin = SpinBox.new()
	opp_spin.min_value = 0
	opp_spin.max_value = 7
	opp_spin.value = prof.opponents
	opp_spin.value_changed.connect(func(x): prof.opponents = int(x))
	opts.add_child(opp_spin)
	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(gap)
	var row := HBoxContainer.new()
	v.add_child(row)
	_button(row, "< BACK", func(): show_screen("customise"))
	var go := _button(row, "START RACE!", start_race, 14)
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick_map(prof.map)


func _pick_map(mid: String) -> void:
	prof.map = mid
	for k in map_buttons:
		map_buttons[k].button_pressed = (k == mid)
	var m: Dictionary = RacerTypes.maps().get(mid, {})
	var pv := String(m.get("preview", ""))
	map_image.texture = load(pv) if pv != "" and ResourceLoader.exists(pv) else null
	var info := String(m.get("subtitle", ""))
	if m.has("length"):
		info += "   %.2f km" % (float(m.length) / 1000.0)
	map_info.text = info


## Build the race config and load the race.
func start_race() -> void:
	var pid: String = prof.character
	var others: Array = RacerTypes.characters().keys().filter(func(k): return k != pid)
	if others.is_empty():
		others = [pid]
	var opponents := []
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in int(prof.opponents):
		var oid: String = others[i % others.size()]
		# Repeat characters get a random paint job so they can be told apart.
		var custom := {}
		if i >= others.size() or oid == pid:
			custom = _random_custom(oid, rng)
		opponents.append({"character": oid, "custom": custom})
	GameState.race_config = {
		"map": prof.map, "laps": int(prof.laps),
		"player": {"character": pid, "custom": Profile.custom_for(pid)},
		"opponents": opponents, "return_to_menu": true,
	}
	Profile.save()
	get_tree().change_scene_to_file(RACE_SCENE)


func _random_custom(cid: String, rng: RandomNumberGenerator) -> Dictionary:
	var c := RacerTypes.character(cid)
	var out := {"paint": {}, "kart_paint": {}}
	for z in c.get("paint", {}):
		var pr: Array = c.paint[z].get("presets", [])
		if pr.size() > 0:
			out.paint[z] = pr[rng.randi() % pr.size()]
	var kart := RacerTypes.kart_def(String(c.get("default_kart", "standard")))
	for z in kart.get("paint", {}):
		var pr: Array = kart.paint[z].get("presets", [])
		if pr.size() > 0:
			out.kart_paint[z] = pr[rng.randi() % pr.size()]
	return out
