class_name RunnerVisual
extends RacerVisual
## Vertex animation for any on-foot (biped) racer: idle, run cycle (swing and
## cadence scaled to speed), dash, jump (spin ball) and hit. Every pose is a set of
## per-part rotations about the rig's pivots, blended by state weights.
## Works with any rig that uses the standard part names (see VertexRig.ALIASES);
## arms modelled in a T-pose are brought down automatically.

@export var rig_path := "res://assets/rigs/sonic.json"
const PARTS := ["body", "head", "arm_upper_l", "arm_lower_l", "arm_upper_r", "arm_lower_r",
	"leg_upper_l", "leg_lower_l", "leg_upper_r", "leg_lower_r", "tail"]

var rig: VertexRig
var phase := 0.0          ## run cycle phase (radians)
var spin := 0.0           ## spin-ball angle
var w_run := 0.0
var w_jump := 0.0
var w_hit := 0.0
var current_state := &"idle"
var _arm_rest := 0.0      ## brings T-pose arms down to the sides


func _ready() -> void:
	rig = VertexRig.new()
	rig.name = "Rig"
	add_child(rig)
	rig.load_rig(rig_path)
	_arm_rest = PI * 0.47 if rig.rest_pose() == "t_pose" else 0.0


func update_visual(s: AnimState, delta: float) -> void:
	super(s, delta)
	var k := clampf(absf(s.speed) / maxf(s.max_speed, 0.01), 0.0, 1.6)

	# State weights, smoothed so transitions blend.
	var tgt_jump := 1.0 if (s.jumping or (not s.grounded and s.vertical_speed > -2.0 and s.jumping)) else 0.0
	var tgt_hit := 1.0 if s.hit > 0.0 else 0.0
	var tgt_run := clampf(k * 3.0, 0.0, 1.0) if s.grounded else 0.4
	w_jump = approach(w_jump, tgt_jump, 14.0, delta)
	w_hit = approach(w_hit, tgt_hit, 16.0, delta)
	w_run = approach(w_run, tgt_run, 8.0, delta)
	current_state = &"hit" if tgt_hit > 0.5 else (&"jump" if tgt_jump > 0.5 else (&"run" if tgt_run > 0.3 else &"idle"))

	# Cadence rises with speed (Sonic R style: legs blur near top speed).
	phase += delta * (2.0 + 15.0 * k) if s.grounded else delta * 4.0
	spin += delta * (16.0 + 10.0 * k) * w_jump

	var idle := _pose_idle()
	var run := _pose_run(k, s.dashing)
	var jump := _pose_jump()
	var hit := _pose_hit()

	rig.reset_pose()
	var w_air := w_jump
	var w_h := w_hit
	var w_r := w_run * (1.0 - w_air) * (1.0 - w_h)
	var w_i := (1.0 - w_run) * (1.0 - w_air) * (1.0 - w_h)
	for p in PARTS:
		var e: Vector3 = idle.get(p, Vector3.ZERO) * w_i + run.get(p, Vector3.ZERO) * w_r \
			+ jump.get(p, Vector3.ZERO) * w_air * (1.0 - w_h) + hit.get(p, Vector3.ZERO) * w_h
		if p == "arm_upper_l":
			e.z += _arm_rest
		elif p == "arm_upper_r":
			e.z -= _arm_rest
		rig.set_rot(p, e)
	var bob := absf(sin(phase)) * 0.035 * clampf(k, 0.0, 1.0) * w_r \
		+ sin(time * 2.2) * 0.006 * w_i + 0.12 * w_air * (1.0 - w_h)
	rig.set_offset(&"body", Vector3(0, bob, 0))
	rig.apply()


func _pose_idle() -> Dictionary:
	var t := time
	var breathe := sin(t * 2.2) * 0.03
	var tap := maxf(0.0, sin(t * 7.0)) * 0.25 * (1.0 if fmod(t, 3.0) < 1.4 else 0.0)  # impatient foot tap
	return {
		"body": Vector3(breathe * 0.5, 0, 0),
		"head": Vector3(-0.05, sin(t * 0.7) * 0.25, 0),
		"arm_upper_l": Vector3(0.05, 0, -0.12 - breathe),
		"arm_upper_r": Vector3(0.05, 0, 0.12 + breathe),
		"arm_lower_l": Vector3(0.25, 0, 0),
		"arm_lower_r": Vector3(0.25, 0, 0),
		"leg_lower_r": Vector3(-tap, 0, 0),
		"leg_upper_r": Vector3(tap * 0.4, 0, 0),
		"tail": Vector3(sin(t * 3.0) * 0.2, 0, 0),
	}


## Z rotation: negative swings a left limb outward, positive a right limb.
## Swing amplitude and cadence both scale with speed `k` (0 = still, 1 = top speed).
func _pose_run(k: float, dashing: bool) -> Dictionary:
	var a := lerpf(0.35, 1.05, clampf(k, 0.0, 1.0))      # leg swing
	var arm := lerpf(0.3, 0.95, clampf(k, 0.0, 1.0))     # arm swing
	var sp := sin(phase)
	var lean := -lerpf(0.08, 0.42, clampf(k, 0.0, 1.0))
	if dashing:
		lean -= 0.15
		arm *= 0.4  # arms swept back during a dash
	var knee_l := -a * 1.1 * (0.5 + 0.5 * sin(phase - 1.3))
	var knee_r := -a * 1.1 * (0.5 + 0.5 * sin(phase + PI - 1.3))
	var back := -0.6 if dashing else 0.0
	return {
		"body": Vector3(lean, sp * 0.08 * k, 0),
		"head": Vector3(-lean * 0.6, -sp * 0.05, 0),
		"leg_upper_l": Vector3(a * sp, 0, 0),
		"leg_upper_r": Vector3(-a * sp, 0, 0),
		"leg_lower_l": Vector3(knee_l, 0, 0),
		"leg_lower_r": Vector3(knee_r, 0, 0),
		"arm_upper_l": Vector3(-arm * sp + back, 0, -0.25),
		"arm_upper_r": Vector3(arm * sp + back, 0, 0.25),
		"arm_lower_l": Vector3(0.9 * k + 0.2, 0, 0),
		"arm_lower_r": Vector3(0.9 * k + 0.2, 0, 0),
		"tail": Vector3(0.5 * k + sin(phase * 2.0) * 0.15, 0, 0),
	}


## Curled spin ball; the whole body spins about the torso pivot.
func _pose_jump() -> Dictionary:
	return {
		"body": Vector3(-spin, 0, 0),
		"head": Vector3(0.6, 0, 0),
		"leg_upper_l": Vector3(1.4, 0, -0.1),
		"leg_upper_r": Vector3(1.4, 0, 0.1),
		"leg_lower_l": Vector3(-1.8, 0, 0),
		"leg_lower_r": Vector3(-1.8, 0, 0),
		"arm_upper_l": Vector3(1.2, 0, 0.3),
		"arm_upper_r": Vector3(1.2, 0, -0.3),
		"arm_lower_l": Vector3(1.4, 0, 0),
		"arm_lower_r": Vector3(1.4, 0, 0),
		"tail": Vector3(0.8, 0, 0),
	}


## Knocked back: arms flung up, head thrown back, body wobbling.
func _pose_hit() -> Dictionary:
	var wob := sin(time * 30.0) * 0.15
	return {
		"body": Vector3(0.45 + wob, wob, 0),
		"head": Vector3(-0.5, wob * 2.0, 0),
		"arm_upper_l": Vector3(0.3, 0, -2.3 + wob),
		"arm_upper_r": Vector3(0.3, 0, 2.3 - wob),
		"arm_lower_l": Vector3(0, 0, -0.4),
		"arm_lower_r": Vector3(0, 0, 0.4),
		"leg_upper_l": Vector3(0.5, 0, -0.35),
		"leg_upper_r": Vector3(-0.3, 0, 0.35),
		"leg_lower_l": Vector3(-0.6, 0, 0),
		"leg_lower_r": Vector3(-0.3, 0, 0),
		"tail": Vector3(wob * 3.0, 0, 0),
	}
