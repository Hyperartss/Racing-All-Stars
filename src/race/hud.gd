class_name RaceHUD
extends CanvasLayer
## Retro race HUD (drawn shapes, no art files needed): item slot with roulette,
## rings, lap / time, big race position, speed and the racer's special-move meter,
## centre messages, and the ink overlay. Item icons use the item's "icon" PNG if it
## has one, otherwise a coloured badge with its initials.

const YELLOW := Color(1, 0.95, 0.4)
const OUTLINE := Color(0.1, 0.05, 0.2)

var race: Node
var _top: Label
var _centre: Label
var _info: Label
var _rings: Label
var _place: Label
var _gauge: HudGauge
var _msg_time := 0.0


var k := 1.0                     ## UI scale: 1 at 360 lines, smaller on Saturn res


func _ready() -> void:
	var res: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	k = clampf(res.y / 360.0, 0.55, 2.0)
	_gauge = HudGauge.new()
	_gauge.hud = self
	_gauge.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_gauge)
	_top = _label(Vector2(0, 6 * k), 15, HORIZONTAL_ALIGNMENT_RIGHT)
	_top.size = Vector2(res.x - 10 * k, 40 * k)
	_rings = _label(Vector2(10 * k + 16 * k, 70 * k), 18, HORIZONTAL_ALIGNMENT_LEFT)
	_info = _label(Vector2(10 * k, res.y - 26 * k), 12, HORIZONTAL_ALIGNMENT_LEFT)
	_place = _label(Vector2(0, res.y - 70 * k), 44, HORIZONTAL_ALIGNMENT_RIGHT)
	_place.size = Vector2(res.x - 14 * k, 60 * k)
	_centre = _label(Vector2(0, res.y * 0.33), 30, HORIZONTAL_ALIGNMENT_CENTER)
	_centre.size = Vector2(res.x, 60 * k)
	EventBus.hud_message.connect(show_message)
	EventBus.racer_action.connect(_on_action)


func _label(at: Vector2, sz: int, align: int) -> Label:
	var l := Label.new()
	l.position = at
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", maxi(int(sz * k), 7))
	l.add_theme_color_override("font_color", YELLOW)
	l.add_theme_color_override("font_outline_color", OUTLINE)
	l.add_theme_constant_override("outline_size", maxi(int(5 * k), 2))
	add_child(l)
	return l


func show_message(text: String, seconds: float) -> void:
	_centre.text = text
	_msg_time = seconds


func target() -> Racer:
	if race == null or race.camera == null:
		return null
	return race.camera.target


func _on_action(r: Node, action: StringName, data: Dictionary) -> void:
	if race == null or r != target():
		return
	match action:
		&"boost":
			if data.get("rocket", false):
				show_message("ROCKET START!", 1.0)
			elif data.get("trick", false):
				show_message("TRICK!", 0.6)
			elif not data.get("item", false) and not data.get("pad", false):
				show_message("SUPER MINI-TURBO!" if int(data.get("level", 1)) == 2 else "MINI-TURBO!", 0.8)
		&"dash":
			show_message("DASH!", 0.5)
		&"burnout":
			show_message("BURNOUT!", 0.8)
		&"blocked":
			show_message("BLOCKED!", 0.6)


func _process(delta: float) -> void:
	var r := target()
	if r == null:
		return
	var st: Array = GameState.standings()
	var place := st.find(r) + 1
	var lap := clampi(r.laps_done + 1, 1, r.total_laps)
	_top.text = "LAP %d/%d\nTIME %s" % [lap, r.total_laps, _fmt(r.race_time)]
	_place.text = _ordinal(place)
	_place.add_theme_color_override("font_color", [YELLOW, Color(0.85, 0.9, 1.0), Color(1.0, 0.65, 0.35)][place - 1] if place >= 1 and place <= 3 else Color(0.7, 0.8, 1.0))
	_rings.text = "RINGS %03d" % (r.items.rings if r.items != null else 0)
	var extra := ""
	if r.movement is KartMovement:
		var km := r.movement as KartMovement
		extra = ["", "  DRIFT: BLUE", "  DRIFT: ORANGE"][km.drift_level()] if km.drift_dir != 0 else ""
	elif r.movement is RunnerMovement:
		var rm := r.movement as RunnerMovement
		extra = "  DASH READY" if rm.dash_cool <= 0.0 else "  dash %.1fs" % rm.dash_cool
	var it: RacerItems = r.items
	if it != null:
		if it.star_timer > 0.0:
			extra += "  STAR %.0f" % it.star_timer
		if it.shield_hits > 0:
			extra += "  SHIELD"
		if it.golden_timer > 0.0:
			extra += "  GOLDEN %.1f" % it.golden_timer
	_info.text = "%3d km/h%s   [E] item  [Q] back" % [int(absf(r.movement.speed) * 3.6), extra]
	if _msg_time > 0.0:
		_msg_time -= delta
		if _msg_time <= 0.0:
			_centre.text = ""
	_gauge.queue_redraw()


static func _ordinal(n: int) -> String:
	if n <= 0:
		return ""
	var suf := "th"
	if n % 100 < 11 or n % 100 > 13:
		suf = ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]
	return "%d%s" % [n, suf]


static func _fmt(t: float) -> String:
	return "%d:%05.2f" % [int(t) / 60, fmod(t, 60.0)]
