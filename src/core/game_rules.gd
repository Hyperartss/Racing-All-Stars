@tool
class_name GameRules
extends RefCounted
## Race rules shared by every system: rings, items, hits, rocket starts.
## Stored in res://content/rules.json (edited from the Game Editor dock -> Rules).
## Any key missing from the file uses the default below, so new rules can be added
## here without breaking older rules files.

const PATH := "res://content/rules.json"

## key -> schema. The Game Editor builds its Rules form from this.
const SCHEMA := {
	"items_enabled": {"type": "bool", "default": true, "hint": "Item boxes give items"},
	"item_roulette_time": {"type": "float", "default": 2.2, "min": 0.2, "max": 6.0, "step": 0.1,
		"hint": "Seconds the item roulette spins before the item is ready"},
	"item_box_respawn": {"type": "float", "default": 2.5, "min": 0.2, "max": 30.0, "step": 0.1,
		"hint": "Default seconds before a broken item box comes back"},
	"start_rings": {"type": "int", "default": 0, "min": 0, "max": 999},
	"max_rings": {"type": "int", "default": 999, "min": 1, "max": 9999},
	"ring_speed_per_ring": {"type": "float", "default": 0.004, "min": 0.0, "max": 0.05, "step": 0.001,
		"hint": "Top speed bonus per ring held (Mario Kart coins). 0 = rings only buy doors (Sonic R)"},
	"ring_speed_max_rings": {"type": "int", "default": 10, "min": 0, "max": 999,
		"hint": "Rings above this give no extra speed"},
	"rings_lost_on_hit": {"type": "int", "default": 5, "min": 0, "max": 999,
		"hint": "Rings dropped when hit (they scatter and can be picked up again)"},
	"ring_respawn": {"type": "float", "default": 12.0, "min": 0.0, "max": 300.0, "step": 0.5,
		"hint": "Default seconds before a collected ring comes back (0 = never)"},
	"rocket_start": {"type": "bool", "default": true,
		"hint": "Press accelerate just as '1' shows for a boost; too early burns out"},
	"rocket_window": {"type": "float", "default": 0.45, "min": 0.05, "max": 1.5, "step": 0.05,
		"hint": "Seconds before GO in which pressing accelerate gives the rocket start"},
	"rocket_boost": {"type": "float", "default": 1.1, "min": 0.0, "max": 4.0, "step": 0.1},
	"spin_time": {"type": "float", "default": 1.0, "min": 0.1, "max": 4.0, "step": 0.05,
		"hint": "Default hit-stun for a spin-out (bananas, shells)"},
	"tumble_time": {"type": "float", "default": 1.6, "min": 0.1, "max": 5.0, "step": 0.05,
		"hint": "Default hit-stun for explosions"},
	"trick_boost": {"type": "float", "default": 0.6, "min": 0.0, "max": 3.0, "step": 0.05,
		"hint": "Boost seconds after landing a trick (Space in the air off a ramp)"},
	"ai_items": {"type": "bool", "default": true, "hint": "AI racers use items"},
}

static var _data := {}
static var _loaded := false


static func reload() -> void:
	_data = {}
	if FileAccess.file_exists(PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary:
			_data = parsed
	_loaded = true


static func get_value(key: String) -> Variant:
	if not _loaded:
		reload()
	if _data.has(key):
		return _data[key]
	return SCHEMA.get(key, {}).get("default")


static func f(key: String) -> float:
	return float(get_value(key))


static func i(key: String) -> int:
	return int(get_value(key))


static func b(key: String) -> bool:
	return bool(get_value(key))


## Race-time override (e.g. the menu's Items On/Off) without touching the file.
static func set_override(key: String, value: Variant) -> void:
	if not _loaded:
		reload()
	_data[key] = value


static func all() -> Dictionary:
	if not _loaded:
		reload()
	var out := {}
	for k in SCHEMA:
		out[k] = get_value(k)
	for k in _data:
		if not out.has(k):
			out[k] = _data[k]
	return out


static func save_all(d: Dictionary) -> Error:
	var fa := FileAccess.open(PATH, FileAccess.WRITE)
	if fa == null:
		return FileAccess.get_open_error()
	fa.store_string(JSON.stringify(d, "\t") + "\n")
	fa.close()
	reload()
	return OK
