class_name Profile
extends RefCounted
## The player's saved choices (user://profile.json): character, per-character
## customisation, map, laps, number of opponents.

const PATH := "user://profile.json"

static var data := {}


static func load_profile() -> Dictionary:
	if FileAccess.file_exists(PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.open(PATH, FileAccess.READ).get_as_text())
		if parsed is Dictionary:
			data = parsed
	if not data.has("customs"):
		data["customs"] = {}
	data["character"] = data.get("character", "sonic")
	data["map"] = data.get("map", "retro_circuit")
	data["laps"] = int(data.get("laps", 3))
	data["opponents"] = int(data.get("opponents", 3))
	return data


static func save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))


static func custom_for(char_id: String) -> Dictionary:
	var all: Dictionary = data.get("customs", {})
	if not all.has(char_id):
		all[char_id] = {"paint": {}, "kart_paint": {}}
		data["customs"] = all
	return all[char_id]
