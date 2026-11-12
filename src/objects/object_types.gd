@tool
class_name ObjectTypes
extends RefCounted
## Registry of placeable gameplay object types (data in res://content/objects/*.json)
## and their behaviours (scripts in BEHAVIOUR_DIRS declaring `const BEHAVIOUR`).
##
## A type file:
##   {"id": "ring_door", "name": "Ring door", "behaviour": "door",
##    "category": "Gameplay", "shape": "", "colour": "#3060d0",
##    "model": "res://..." (optional, your own model), "model_scale": 1.0,
##    "size": [radius, height] (editor picking box), "params": {"cost": 20}}

const DIR := "res://content/objects/"
const BEHAVIOUR_DIRS := ["res://src/objects/behaviours/", "res://content/object_behaviours/"]

static var _defs := {}
static var _behaviours := {}
static var _meta := {}
static var _loaded := false


static func reload() -> void:
	_defs = {}
	_behaviours = {}
	_meta = {}
	for dir in BEHAVIOUR_DIRS:
		for path in ItemTypes._scripts_in(dir):
			var m := ItemTypes.script_meta(path)
			if m.is_empty():
				continue
			_meta[m.id] = m
			_behaviours[m.id] = m.script
	var d := DirAccess.open(DIR)
	if d != null:
		var files := Array(d.get_files())
		files.sort()
		for fn in files:
			if not String(fn).ends_with(".json"):
				continue
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIR + String(fn)))
			if parsed is Dictionary:
				var id := String(parsed.get("id", String(fn).get_basename()))
				parsed["id"] = id
				_defs[id] = parsed
	_loaded = true


static func defs() -> Dictionary:
	if not _loaded:
		reload()
	return _defs


static func has(type: String) -> bool:
	return defs().has(type)


static func def(type: String) -> Dictionary:
	return defs().get(type, {})


static func behaviours() -> Dictionary:
	if not _loaded:
		reload()
	return _behaviours


static func behaviour_params(bid: String) -> Dictionary:
	behaviours()
	return _meta.get(bid, {}).get("params", {})


static func behaviour_label(bid: String) -> String:
	behaviours()
	return String(_meta.get(bid, {}).get("label", bid))


## Parameter schema for a type (its behaviour's PARAMS).
static func schema(type: String) -> Dictionary:
	return behaviour_params(String(def(type).get("behaviour", "")))


## Behaviour defaults < the type's params < the placed entry's params.
static func params_for(e: Dictionary) -> Dictionary:
	var type := String(e.get("type", ""))
	var d := def(type)
	var out := {}
	var sc := schema(type)
	for k in sc:
		out[k] = sc[k].get("default")
	var tp: Variant = d.get("params", {})
	if tp is Dictionary:
		out.merge(tp, true)
	var ep: Variant = e.get("params", {})
	if ep is Dictionary:
		out.merge(ep, true)
	return out


## Initial params stored when an object is placed (the type's values, plus a fresh
## uid for anything that has one, e.g. collectables).
static func initial_params(type: String) -> Dictionary:
	var out := {}
	var tp: Variant = def(type).get("params", {})
	if tp is Dictionary:
		out = (tp as Dictionary).duplicate(true)
	if schema(type).has("uid"):
		out["uid"] = new_uid()
	return out


static func new_uid() -> String:
	return "%08x" % (randi() & 0x7fffffff)


static func label(type: String) -> String:
	return String(def(type).get("name", type))


static func category(type: String) -> String:
	return String(def(type).get("category", "Gameplay"))


static func size(type: String) -> Vector2:
	var s: Variant = def(type).get("size", [1.0, 1.5])
	if s is Array and (s as Array).size() >= 2:
		return Vector2(float(s[0]), float(s[1]))
	return Vector2(1.0, 1.5)


static func make(e: Dictionary, editor_mode: bool) -> Node3D:
	var type := String(e.get("type", ""))
	var d := def(type)
	var s: Script = behaviours().get(String(d.get("behaviour", "")))
	var n: TrackObject
	if s == null:
		push_warning("ObjectTypes: '%s' has no behaviour '%s'" % [type, d.get("behaviour", "")])
		n = TrackObject.new()
	else:
		n = s.new()
	n.setup(e, d, params_for(e), editor_mode)
	n.build()
	n.name = "Obj_" + type
	n.position = TrackProps.vec(e.get("pos", [0.0, 0.0, 0.0]))
	n.rotation.y = deg_to_rad(float(e.get("yaw", 0.0)))
	n.scale = Vector3.ONE * maxf(float(e.get("scale", 1.0)), 0.02)
	return n
