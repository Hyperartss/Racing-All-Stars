class_name RacerTypes
extends RefCounted
## Registry of racer types, characters, karts and maps.
##
## Racer TYPES are code (a MovementModel + a RacerVisual each). Characters, karts and
## maps are data: JSON files in res://content/{characters,karts,maps}/ - the menu
## lists whatever is there, the Character Importer and Map Combiner editor plugins
## write new ones.
##
## Adding a racer type (e.g. a flyer) = MovementModel subclass + RacerVisual
## subclass + one entry in TYPES. Existing types are untouched.

const CONTENT := "res://content/"

static var TYPES := {
	"runner": {"movement": RunnerMovement, "visual": RunnerVisual, "label": "Runner"},
	"kart": {"movement": KartMovement, "visual": KartVisual, "label": "Kart"},
}

static var _chars := {}
static var _karts := {}
static var _maps := {}
static var _loaded := false


static func reload() -> void:
	_chars = _load_dir(CONTENT + "characters")
	_karts = _load_dir(CONTENT + "karts")
	_maps = _load_dir(CONTENT + "maps")
	_loaded = true


static func _load_dir(dir: String) -> Dictionary:
	var out := {}
	var d := DirAccess.open(dir)
	if d == null:
		return out
	var files := Array(d.get_files())
	files.sort()
	for f in files:
		if not String(f).ends_with(".json"):
			continue
		var fa := FileAccess.open(dir + "/" + f, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(fa.get_as_text())
		if parsed is Dictionary:
			var def: Dictionary = parsed
			out[String(def.get("id", String(f).get_basename()))] = def
		else:
			push_warning("RacerTypes: could not parse %s/%s" % [dir, f])
	return out


static func characters() -> Dictionary:
	if not _loaded:
		reload()
	return _chars


static func karts() -> Dictionary:
	if not _loaded:
		reload()
	return _karts


static func maps() -> Dictionary:
	if not _loaded:
		reload()
	return _maps


static func character(id: String) -> Dictionary:
	return characters().get(id, {})


static func make_movement(char_id: String) -> MovementModel:
	var t: Dictionary = TYPES[character(char_id).get("type", "runner")]
	var script: GDScript = t.movement
	var mv: MovementModel = script.new()
	# Optional per-character tuning: "params": {"max_speed": 30, ...}
	var p: Dictionary = character(char_id).get("params", {})
	if not p.is_empty() and "params" in mv:
		var mp: Dictionary = mv.get("params")
		for k in p:
			mp[k] = p[k]
	return mv


## Builds the visual for a character with the player's customisation applied.
## custom = {"paint": {zone: "#hex"}, "kart": id, "kart_paint": {zone: value}}
static func make_visual(char_id: String, custom: Dictionary = {}) -> RacerVisual:
	var c := character(char_id)
	var type: String = c.get("type", "runner")
	var v: RacerVisual
	if type == "kart":
		var kv := KartVisual.new()
		var kart := kart_def(String(custom.get("kart", c.get("default_kart", "standard"))))
		kv.kart_rig_path = kart.get("rig", kv.kart_rig_path)
		kv.driver_rig_path = c.get("rig", kv.driver_rig_path)
		var seat: Array = c.get("seat", kart.get("seat", [0.0, 0.05, 0.16]))
		kv.seat = Vector3(seat[0], seat[1], seat[2])
		v = kv
	else:
		var script: GDScript = TYPES[type].visual
		v = script.new()
		v.set("rig_path", c.get("rig", ""))
	v.set_meta("char_def", c)
	v.set_meta("custom", custom)
	v.ready.connect(func(): apply_paint(v), CONNECT_ONE_SHOT)
	return v


static func kart_def(id: String) -> Dictionary:
	var k: Dictionary = karts().get(id, {})
	if k.is_empty() and not karts().is_empty():
		k = karts().values()[0]
	return k


## Applies paint zones from the character (and kart) definition to the visual's rigs.
static func apply_paint(v: RacerVisual) -> void:
	var c: Dictionary = v.get_meta("char_def", {})
	var custom: Dictionary = v.get_meta("custom", {})
	var body_rig: VertexRig = v.get("rig") if "rig" in v else v.get("driver")
	_paint_rig(body_rig, c.get("paint", {}), custom.get("paint", {}))
	if v is KartVisual:
		var kart := kart_def(String(custom.get("kart", c.get("default_kart", "standard"))))
		_paint_rig((v as KartVisual).kart, kart.get("paint", {}), custom.get("kart_paint", {}))


static func _paint_rig(rig: VertexRig, zones: Dictionary, chosen: Dictionary) -> void:
	if rig == null:
		return
	rig.paint_reset()
	for z in zones:
		var zone: Dictionary = zones[z]
		var val: Variant = chosen.get(z, zone.get("default"))
		var mode: String = zone.get("mode", "swap")
		var surf: String = zone.get("surface", "")
		match mode:
			"toggle":
				for sf in rig._surf:
					if String(sf.tex).contains(surf):
						sf.hidden = not bool(val)
			"tint":
				rig.paint_tint(surf, Color.html(String(val)))
			_:
				var src := Color.html(String(zone.get("src", "#ffffff")))
				var dst := Color.html(String(val))
				if not src.is_equal_approx(dst):
					rig.paint_swap(surf, src, dst, float(zone.get("tol", 0.07)))
	rig.apply()
