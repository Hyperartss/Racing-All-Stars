class_name RaceHUD
extends CanvasLayer
## Plain retro text HUD (placeholder art): lap, position, time, speed, the racer's
## special-move meter, countdown and results.

var race: Node
var _top: Label
var _centre: Label
var _info: Label
var _msg_time := 0.0


func _ready() -> void:
	_top = _label(Vector2(8, 6), 16, HORIZONTAL_ALIGNMENT_LEFT)
	_info = _label(Vector2(8, 300), 13, HORIZONTAL_ALIGNMENT_LEFT)
	_centre = _label(Vector2(0, 120), 32, HORIZONTAL_ALIGNMENT_CENTER)
	_centre.size = Vector2(640, 60)
	EventBus.hud_message.connect(show_message)
	EventBus.racer_action.connect(_on_action)


func _label(at: Vector2, sz: int, align: int) -> Label:
	var l := Label.new()
	l.position = at
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", Color(1, 0.95, 0.4))
	l.add_theme_color_override("font_outline_color", Color(0.1, 0.05, 0.2))
	l.add_theme_constant_override("outline_size", 5)
	add_child(l)
	return l


func show_message(text: String, seconds: float) -> void:
	_centre.text = text
	_msg_time = seconds


func _on_action(r: Node, action: StringName, data: Dictionary) -> void:
	if race == null or r != race.camera.target:
		return
	if action == &"boost":
		show_message("SUPER MINI-TURBO!" if int(data.get("level", 1)) == 2 else "MINI-TURBO!", 0.8)
	elif action == &"dash":
		show_message("DASH!", 0.5)


func _process(delta: float) -> void:
	if race == null:
		return
	var r: Racer = race.camera.target
	if r == null:
		return
	var st: Array = GameState.standings()
	var place := st.find(r) + 1
	var lap := clampi(r.laps_done + 1, 1, r.total_laps)
	_top.text = "%s   LAP %d/%d   POS %d/%d   TIME %s" % [r.display_name.to_upper(), lap, r.total_laps,
		place, st.size(), _fmt(r.race_time)]
	var extra := ""
	if r.movement is KartMovement:
		var km := r.movement as KartMovement
		extra = ["", "  DRIFT: BLUE", "  DRIFT: ORANGE"][km.drift_level()] if km.drift_dir != 0 else ""
	elif r.movement is RunnerMovement:
		var rm := r.movement as RunnerMovement
		extra = "  DASH READY" if rm.dash_cool <= 0.0 else "  dash %.1fs" % rm.dash_cool
	_info.text = "%3d km/h%s   [Tab] switch camera  [Q] look back" % [int(absf(r.movement.speed) * 3.6), extra]
	if _msg_time > 0.0:
		_msg_time -= delta
		if _msg_time <= 0.0:
			_centre.text = ""


static func _fmt(t: float) -> String:
	return "%d:%05.2f" % [int(t) / 60, fmod(t, 60.0)]
