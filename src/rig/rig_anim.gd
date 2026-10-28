class_name RigAnim
extends RefCounted
## Animation clips authored in the Animation Editor (bottom panel, "Animation Editor").
##
## A character definition can carry:
##   "animations": {
##       "run": {
##           "length": 0.8, "loop": true, "fps": 24,
##           "keys": [{"t": 0.0, "pose": {"leg_upper_l": {"rot": [0, 0, 0]}}}, ...]
##       }
##   }
## Each key stores a whole pose: part name -> {"rot": [x, y, z] radians,
## "off": [x, y, z] metres}. Missing parts/fields mean "rest".
##
## The visuals blend clips over their code poses: a clip named after a state
## (idle / run / jump / hit for runners, drive / hit for kart drivers) replaces that
## state's pose. Characters without clips simply keep the built-in animation.

## Clip name -> {length, loop, keys}. Only clips with at least one key are kept.
var clips := {}


## Reads the animations of a character definition. Returns an empty animator when the
## character has none.
static func from_def(def: Dictionary) -> RigAnim:
	var a := RigAnim.new()
	var anims: Variant = def.get("animations", {})
	if anims is Dictionary:
		for name in anims:
			var c: Variant = anims[name]
			if not (c is Dictionary):
				continue
			var keys := []
			for k in c.get("keys", []):
				if k is Dictionary and k.has("pose"):
					keys.append(k)
			if keys.is_empty():
				continue
			keys.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
				return float(x.get("t", 0.0)) < float(y.get("t", 0.0)))
			a.clips[String(name)] = {
				"length": maxf(float(c.get("length", 1.0)), 0.01),
				"loop": bool(c.get("loop", true)),
				"keys": keys,
			}
	return a


func has(name: StringName) -> bool:
	return clips.has(String(name))


func names() -> Array:
	return clips.keys()


func length(name: StringName) -> float:
	var c: Dictionary = clips.get(String(name), {})
	return float(c.get("length", 1.0))


## Pose of `name` at `t` seconds: part -> {"rot": Vector3 (radians), "off": Vector3}.
## Returns {} when the character has no such clip.
func sample(name: StringName, t: float) -> Dictionary:
	return sample_clip(clips.get(String(name), {}), t)


## Samples any clip dictionary - also used by the editor for unsaved edits.
static func sample_clip(c: Dictionary, t: float) -> Dictionary:
	var keys: Array = c.get("keys", [])
	if keys.is_empty():
		return {}
	var length := maxf(float(c.get("length", 1.0)), 0.01)
	var looping := bool(c.get("loop", true))
	var time := fposmod(t, length) if looping else clampf(t, 0.0, length)
	var i := 0
	while i + 1 < keys.size() and float(keys[i + 1].get("t", 0.0)) <= time:
		i += 1
	var k0: Dictionary = keys[i]
	var t0 := float(k0.get("t", 0.0))
	if time < t0:
		# Before the first key (loop seam): hold it, which is predictable to author.
		return _pose_at(k0)
	var k1: Dictionary = k0
	var t1 := t0
	if i + 1 < keys.size():
		k1 = keys[i + 1]
		t1 = float(k1.get("t", 0.0))
	elif looping:
		# Last key wraps to the first across the end of the clip.
		k1 = keys[0]
		t1 = float(k1.get("t", 0.0)) + length
	var f := 0.0
	if t1 > t0:
		f = clampf((time - t0) / (t1 - t0), 0.0, 1.0)
	var pose := {}
	_merge(pose, k0, 1.0 - f)
	_merge(pose, k1, f)
	return pose


static func _pose_at(key: Dictionary) -> Dictionary:
	var out := {}
	_merge(out, key, 1.0)
	return out


static func _merge(dst: Dictionary, key: Dictionary, w: float) -> void:
	if is_zero_approx(w):
		return
	var pose: Variant = key.get("pose", {})
	if not (pose is Dictionary):
		return
	for part in pose:
		var e: Variant = pose[part]
		if not (e is Dictionary):
			continue
		var rec: Dictionary = dst.get(part, {"rot": Vector3.ZERO, "off": Vector3.ZERO})
		var r: Vector3 = rec["rot"]
		var o: Vector3 = rec["off"]
		rec["rot"] = r + _vec(e.get("rot", [])) * w
		rec["off"] = o + _vec(e.get("off", [])) * w
		dst[part] = rec


static func _vec(v: Variant) -> Vector3:
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	if v is Vector3:
		return v
	return Vector3.ZERO
