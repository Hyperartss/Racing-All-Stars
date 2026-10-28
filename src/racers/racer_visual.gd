@tool
class_name RacerVisual
extends Node3D
## Base for a racer's look. The movement model fills an `AnimState` each physics
## frame; the visual turns it into vertex poses. New racer types add a new visual
## without touching the others.

## Snapshot of what the racer is doing, written by the movement model.
class AnimState:
	var speed := 0.0            ## signed forward speed, m/s
	var max_speed := 1.0
	var grounded := true
	var steer := 0.0            ## -1 right .. +1 left (input after smoothing)
	var jumping := false
	var dashing := false
	var drift_dir := 0          ## -1 right, 0 none, +1 left
	var drift_charge := 0.0     ## 0..1
	var boosting := false
	var hit := 0.0              ## seconds of hit-stun left
	var vertical_speed := 0.0

var time := 0.0

## Custom animation clips from the character definition (Animation Editor). Null when
## the character has none; the visuals then keep their built-in code poses.
var anim: RigAnim
## Clip name -> seconds played.
var clip_time := {}


## Called every rendered frame.
func update_visual(_s: AnimState, delta: float) -> void:
	time += delta


## Reads the character's custom clips. Call from a subclass' _ready() after loading
## its rig; without clips nothing changes.
func init_anim() -> void:
	var def: Dictionary = get_meta("char_def", {})
	if not def.is_empty():
		anim = RigAnim.from_def(def)


func has_clip(name: StringName) -> bool:
	return anim != null and anim.has(name)


## Move a clip's playhead; loops are wrapped by the sampler.
func advance_clip(name: StringName, delta: float, rate: float = 1.0) -> void:
	if anim == null or not anim.has(name):
		return
	clip_time[name] = float(clip_time.get(name, 0.0)) + delta * maxf(rate, 0.0)


func clip_pose(name: StringName) -> Dictionary:
	if anim == null:
		return {}
	return anim.sample(name, float(clip_time.get(name, 0.0)))


## Pose for a state: its custom clip when the character has one, else the code pose.
func pose_or_clip(name: StringName, fallback: Dictionary) -> Dictionary:
	var p := clip_pose(name)
	return p if not p.is_empty() else fallback


## Applies a weighted blend of pose dictionaries to `rig`.
## Each pose maps rig or canonical part names to either a Vector3 (rotation, radians)
## or {"rot": Vector3, "off": Vector3}. Parts the rig does not have are skipped.
static func blend_pose(rig: VertexRig, poses: Array, weights: Array) -> void:
	var rot := {}
	var off := {}
	for pi in poses.size():
		var w: float = weights[pi]
		if is_zero_approx(w):
			continue
		var pose: Dictionary = poses[pi]
		for key in pose:
			var part: StringName = rig.resolve_name(key)
			if part == &"":
				continue
			var v: Variant = pose[key]
			var r := Vector3.ZERO
			var o := Vector3.ZERO
			if v is Vector3:
				r = v
			elif v is Dictionary:
				r = v.get("rot", Vector3.ZERO)
				o = v.get("off", Vector3.ZERO)
			rot[part] = rot.get(part, Vector3.ZERO) + r * w
			off[part] = off.get(part, Vector3.ZERO) + o * w
	for part in rot:
		rig.set_rot(part, rot[part])
	for part in off:
		if off[part] != Vector3.ZERO:
			rig.set_offset(part, off[part])


## Ease a value toward a target, frame-rate independent.
static func approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerpf(current, target, 1.0 - exp(-rate * delta))
