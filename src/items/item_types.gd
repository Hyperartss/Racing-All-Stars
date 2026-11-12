@tool
class_name ItemTypes
extends RefCounted
## Registry of items (data) and item behaviours (code).
##
## Items: res://content/items/<id>.json, e.g.
##   {"id": "red_shell", "name": "Red Shell", "behaviour": "shell", "count": 1,
##    "shape": "shell", "colour": "#e02020", "icon": "res://...png" (optional),
##    "model": "res://..." (optional), "params": {"mode": "homing"},
##    "odds": [0, 20, 20, ...12 weights, one per race position...],
##    "racer_types": ["kart", "runner"] (optional), "enabled": true}
##
## Behaviours: every script in BEHAVIOUR_DIRS that declares `const BEHAVIOUR`.

const ITEM_DIR := "res://content/items/"
const BEHAVIOUR_DIRS := ["res://src/items/behaviours/", "res://content/item_behaviours/"]
const POSITIONS := 12

static var _items := {}
static var _behaviours := {}             ## id -> Script (null if it cannot load here)
static var _meta := {}                   ## id -> {"path", "label", "params"}
static var _instances := {}
static var _loaded := false


static func reload() -> void:
	_items = {}
	_behaviours = {}
	_meta = {}
	_instances = {}
	for dir in BEHAVIOUR_DIRS:
		for path in _scripts_in(dir):
			var m := script_meta(path)
			if m.is_empty():
				continue
			_meta[m.id] = m
			_behaviours[m.id] = m.script
	var d := DirAccess.open(ITEM_DIR)
	if d != null:
		var files := Array(d.get_files())
		files.sort()
		for fn in files:
			if not String(fn).ends_with(".json"):
				continue
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ITEM_DIR + String(fn)))
			if parsed is Dictionary:
				var id := String(parsed.get("id", String(fn).get_basename()))
				parsed["id"] = id
				_items[id] = parsed
			else:
				push_warning("ItemTypes: could not parse %s%s" % [ITEM_DIR, fn])
	_loaded = true


## BEHAVIOUR / LABEL / PARAMS of a behaviour script. Read from the compiled script,
## or from its source text when it cannot compile in this context (editor tools and
## `godot -s` tests run without the game's autoloads).
static func script_meta(path: String) -> Dictionary:
	var s: Script = load(path) if ResourceLoader.exists(path) else null
	if s != null:
		var cm := s.get_script_constant_map()
		if cm.has("BEHAVIOUR"):
			return {"id": String(cm.BEHAVIOUR), "label": String(cm.get("LABEL", cm.BEHAVIOUR)),
				"params": cm.get("PARAMS", {}), "path": path, "script": s if s.can_instantiate() else null}
	if not FileAccess.file_exists(path):
		return {}
	var src := FileAccess.get_file_as_string(path)
	var re := RegEx.create_from_string("const\\s+BEHAVIOUR\\s*:?=\\s*\"([^\"]+)\"")
	var m := re.search(src)
	if m == null:
		return {}
	var out := {"id": m.get_string(1), "label": m.get_string(1), "params": {}, "path": path, "script": null}
	var rl := RegEx.create_from_string("const\\s+LABEL\\s*:?=\\s*\"([^\"]+)\"")
	var ml := rl.search(src)
	if ml != null:
		out.label = ml.get_string(1)
	var at := src.find("const PARAMS")
	if at >= 0:
		var open := src.find("{", at)
		var depth := 0
		var end := -1
		for i in range(open, src.length()):
			var ch := src[i]
			if ch == "{":
				depth += 1
			elif ch == "}":
				depth -= 1
				if depth == 0:
					end = i
					break
		if end > open:
			var body := src.substr(open, end - open + 1)
			body = RegEx.create_from_string(",(\\s*[}\\]])").sub(body, "$1", true)
			var parsed: Variant = JSON.parse_string(body)
			if parsed is Dictionary:
				out.params = parsed
	return out


## .gd files in a folder (also finds exported .gdc / .remap names).
static func _scripts_in(dir: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	var seen := {}
	for fn in d.get_files():
		var f := String(fn).trim_suffix(".remap")
		if f.ends_with(".gdc"):
			f = f.trim_suffix(".gdc") + ".gd"
		if f.ends_with(".gd") and not seen.has(f):
			seen[f] = true
			out.append(dir + f)
	out.sort()
	return out


static func items() -> Dictionary:
	if not _loaded:
		reload()
	return _items


static func item(id: String) -> Dictionary:
	return items().get(id, {})


static func behaviours() -> Dictionary:
	if not _loaded:
		reload()
	return _behaviours


static func behaviour_label(bid: String) -> String:
	behaviours()
	return String(_meta.get(bid, {}).get("label", bid))


static func behaviour_params(bid: String) -> Dictionary:
	behaviours()
	return _meta.get(bid, {}).get("params", {})


## The behaviour object of an item (an ItemBehaviour; typed loosely so the editor
## tools can use this registry without compiling the game-side item code).
static func behaviour_of(item_id: String) -> RefCounted:
	var bid := String(item(item_id).get("behaviour", ""))
	if _instances.has(bid):
		return _instances[bid]
	var s: Script = behaviours().get(bid)
	if s == null:
		return null
	var inst: RefCounted = s.new()
	_instances[bid] = inst
	return inst


## The item's parameters: the behaviour's defaults with the item's own values on top.
static func params_of(item_id: String) -> Dictionary:
	var def := item(item_id)
	var out := {}
	var schema := behaviour_params(String(def.get("behaviour", "")))
	for k in schema:
		out[k] = schema[k].get("default")
	var own: Variant = def.get("params", {})
	if own is Dictionary:
		for k in own:
			out[k] = own[k]
	return out


## Odds column for race position `rank` (0 = leader) out of `count` racers.
static func column(rank: int, count: int) -> int:
	if count <= 1:
		return 0
	return clampi(int(round(float(rank) / float(count - 1) * float(POSITIONS - 1))), 0, POSITIONS - 1)


## Pick an item for a racer at `rank` of `count`. "" when nothing is available.
static func roll(rank: int, count: int, racer_type: String, rng: RandomNumberGenerator) -> String:
	var col := column(rank, count)
	var pool: Array = []
	var total := 0.0
	for id in items():
		var def: Dictionary = items()[id]
		if not bool(def.get("enabled", true)):
			continue
		if behaviours().get(String(def.get("behaviour", ""))) == null:
			continue
		var rt: Variant = def.get("racer_types", [])
		if rt is Array and not (rt as Array).is_empty() and not (rt as Array).has(racer_type):
			continue
		var odds: Variant = def.get("odds", [])
		var w := 1.0
		if odds is Array and (odds as Array).size() > 0:
			w = float(odds[mini(col, (odds as Array).size() - 1)])
		if w <= 0.0:
			continue
		pool.append([id, w])
		total += w
	if pool.is_empty():
		return ""
	var x := rng.randf() * total
	for e in pool:
		x -= float(e[1])
		if x <= 0.0:
			return String(e[0])
	return String(pool[-1][0])


static func icon_colour(item_id: String) -> Color:
	return Color.html(String(item(item_id).get("colour", "#ffffff")))
