class_name PlayerProgress
extends RefCounted
## What the player has collected across races (user://progress.json):
## per map, the uids of every collectable picked up (tokens, Chaos Emeralds, any
## custom kind), plus best times. Pick-ups made during a race are only kept when
## the player finishes it (Sonic R rule), so quitting mid-race loses them.
##
## Characters (and skins) can be locked behind collectables with an "unlock" block
## in their definition, e.g. {"unlock": {"token": 5}} or {"unlock": {"emerald": 7}}:
## the totals over all maps must reach every count listed.

const PATH := "user://progress.json"

static var data := {}
static var _loaded := false
static var pending: Array = []        ## [{map, kind, uid}] picked up this race


static func load_progress() -> Dictionary:
	data = {}
	if FileAccess.file_exists(PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary:
			data = parsed
	if not (data.get("maps") is Dictionary):
		data["maps"] = {}
	_loaded = true
	return data


static func save() -> void:
	var fa := FileAccess.open(PATH, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(data, "\t"))


static func _map(map_id: String) -> Dictionary:
	if not _loaded:
		load_progress()
	var maps: Dictionary = data["maps"]
	if not maps.has(map_id):
		maps[map_id] = {"collected": {}, "best_time": 0.0}
	var m: Dictionary = maps[map_id]
	if not (m.get("collected") is Dictionary):
		m["collected"] = {}
	return m


## Already kept from an earlier race?
static func has(map_id: String, uid: String) -> bool:
	return _map(map_id).collected.has(uid)


static func is_pending(uid: String) -> bool:
	for p in pending:
		if String(p.uid) == uid:
			return true
	return false


static func pick_up(map_id: String, kind: String, uid: String) -> void:
	if has(map_id, uid) or is_pending(uid):
		return
	pending.append({"map": map_id, "kind": kind, "uid": uid})


static func clear_pending() -> void:
	pending.clear()


## The player finished: keep this race's pick-ups. Returns the character ids that
## this unlocked.
static func commit(map_id: String, race_time: float, chars: Dictionary = {}) -> Array:
	var before := unlocked_set(chars)
	for p in pending:
		var m := _map(String(p.map))
		m.collected[String(p.uid)] = String(p.kind)
	pending.clear()
	var mm := _map(map_id)
	if race_time > 0.0 and (float(mm.get("best_time", 0.0)) <= 0.0 or race_time < float(mm.best_time)):
		mm["best_time"] = race_time
	save()
	var after := unlocked_set(chars)
	var fresh: Array = []
	for k in after:
		if not before.has(k):
			fresh.append(k)
	return fresh


## Collected count of `kind` over all maps (or one map).
static func count(kind: String, map_id: String = "") -> int:
	if not _loaded:
		load_progress()
	var n := 0
	for mid in data.maps:
		if map_id != "" and mid != map_id:
			continue
		var col: Dictionary = data.maps[mid].get("collected", {})
		for uid in col:
			if String(col[uid]) == kind:
				n += 1
	return n


static func meets(unlock: Variant) -> bool:
	if not (unlock is Dictionary):
		return true
	for kind in unlock:
		if count(String(kind)) < int(unlock[kind]):
			return false
	return true


static func describe(unlock: Variant) -> String:
	if not (unlock is Dictionary):
		return ""
	var parts: Array = []
	for kind in unlock:
		parts.append("%d/%d %s" % [count(String(kind)), int(unlock[kind]), String(kind)])
	return ", ".join(parts)


## ids in `chars` (id -> character definition) whose "unlock" is met.
## (No game classes are named in this file: track objects use it from the editor.)
static func unlocked_set(chars: Dictionary) -> Dictionary:
	var out := {}
	for cid in chars:
		if meets(chars[cid].get("unlock")):
			out[cid] = true
	return out


static func is_unlocked(char_def: Dictionary) -> bool:
	return meets(char_def.get("unlock"))
