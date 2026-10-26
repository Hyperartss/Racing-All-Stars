class_name KartVisual
extends RacerVisual
## Kart + driver, both vertex-animated:
##   kart  - wheel spin tied to speed (each wheel's own radius), front-wheel steering,
##           body lean in turns, drift slide and hop
##   driver - seated pose built from the standing model, head turns toward the steer
##            direction, arms work the wheel, leans with the body
##
## The driver rig is parented to the kart body's current transform, so whatever the
## body polygons do (lean, hop) the driver follows.

@export var kart_rig_path := "res://assets/rigs/kart_standard.json"
@export var driver_rig_path := "res://assets/rigs/mario.json"
## Where the driver's hips sit, in kart space (rest pose).
@export var seat := Vector3(0.0, 0.05, 0.16)
@export var driver_scale := 0.0   ## 0 = automatic (0.85 m tall)

var kart: VertexRig
var driver: VertexRig
var spin := 0.0
var steer_vis := 0.0
var lean := 0.0
var drift_yaw := 0.0
var head_yaw := 0.0
var hop := 0.0
var _was_drift := 0
var wheels := {}   ## name -> radius
var _arm_rest := 0.0


func _ready() -> void:
	kart = VertexRig.new()
	kart.name = "KartRig"
	add_child(kart)
	kart.load_rig(kart_rig_path)
	for w in ["wheel_fl", "wheel_fr", "wheel_bl", "wheel_br"]:
		if kart.has_part(w):
			wheels[w] = float(kart.meta.get(w, {}).get("radius", 0.15))
	driver = VertexRig.new()
	driver.name = "DriverRig"
	add_child(driver)
	driver.load_rig(driver_rig_path)
	# Arms modelled hanging down: lift them to the T-pose the seated pose starts from.
	_arm_rest = -PI * 0.5 if driver.rest_pose() == "arms_down" else 0.0
	# Any driver is scaled to sit like a 0.85 m tall racer.
	var h := float(driver.meta.get("aabb_max", [0, 0.85, 0])[1]) - float(driver.meta.get("aabb_min", [0, 0, 0])[1])
	if driver_scale <= 0.0:
		driver_scale = 0.85 / maxf(h, 0.05)


func update_visual(s: AnimState, delta: float) -> void:
	super(s, delta)
	var k := clampf(absf(s.speed) / maxf(s.max_speed, 0.01), 0.0, 1.5)

	# --- kart ----------------------------------------------------------------
	spin -= s.speed * delta            # angle * radius = distance; divided per wheel below
	steer_vis = approach(steer_vis, s.steer * 0.45, 12.0, delta)
	var lean_tgt := -s.steer * 0.10 * clampf(k, 0.0, 1.0) - float(s.drift_dir) * 0.08
	lean = approach(lean, lean_tgt, 8.0, delta)
	drift_yaw = approach(drift_yaw, float(s.drift_dir) * 0.38, 6.0, delta)
	if s.drift_dir != 0 and _was_drift == 0:
		hop = 1.0                       # little hop on drift start
	_was_drift = s.drift_dir
	hop = maxf(0.0, hop - delta * 6.0)
	var hop_y := sin(hop * PI) * 0.12
	var shake := sin(time * 60.0) * 0.006 * k   # engine buzz

	kart.reset_pose()
	for w in wheels:
		var r: float = wheels[w]
		var roll := Basis(Vector3.RIGHT, spin / r)
		if w.begins_with("wheel_f"):
			kart.set_part_basis(w, Basis(Vector3.UP, steer_vis) * roll)
		else:
			kart.set_part_basis(w, roll)
	var body_b := Basis(Vector3.UP, drift_yaw) * Basis(Vector3.BACK, lean) \
		* Basis(Vector3.RIGHT, -0.04 * float(s.boosting) + (0.15 if s.hit > 0.0 else 0.0) * sin(time * 25.0))
	kart.set_part_basis(&"body", body_b)
	kart.set_offset(&"body", Vector3(0, hop_y + shake, 0))
	# wheels follow the drift yaw and hop as a set (they stay level - no lean)
	for w in wheels:
		var c := kart.pivot_of(w)
		var turned := Basis(Vector3.UP, drift_yaw) * c
		kart.set_offset(w, turned - c + Vector3(0, hop_y, 0))
		kart.set_part_basis(w, Basis(Vector3.UP, drift_yaw) * kart.part_rot[kart.part_index[w]])
	kart.apply()

	# --- driver ----------------------------------------------------------------
	# Seat follows the body polygons.
	var body_x: Transform3D = kart.part_xform[kart.part_index[&"body"]]
	driver.transform = body_x * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * driver_scale), seat)
	head_yaw = approach(head_yaw, s.steer * 0.7 + float(s.drift_dir) * 0.25, 7.0, delta)
	_pose_driver(s, k)
	driver.apply()


## Seated pose from the standing (T-pose) model, plus steering and look.
func _pose_driver(s: AnimState, k: float) -> void:
	driver.reset_pose()
	var st := steer_vis / 0.45            # -1..1
	var hit := 1.0 if s.hit > 0.0 else 0.0
	# Hips/torso: lean into the corner, slight forward hunch at speed.
	driver.set_rot(&"hips", Vector3(0, 0, -lean * 1.2))
	driver.set_rot(&"torso", Vector3(-0.12 - 0.08 * k, st * 0.12, st * 0.10))
	# Head turns toward where we are steering (and shakes when hit).
	driver.set_rot(&"head", Vector3(0.05 + 0.3 * hit * sin(time * 20.0), head_yaw, -st * 0.08))
	# Legs: thighs forward, shins down toward the pedals.
	driver.set_rot(&"leg_upper_l", Vector3(1.45, 0.05, 0))
	driver.set_rot(&"leg_upper_r", Vector3(1.45, -0.05, 0))
	driver.set_rot(&"leg_lower_l", Vector3(-1.0, 0, 0))
	driver.set_rot(&"leg_lower_r", Vector3(-1.0, 0, 0))
	# Arms: down from the T-pose and forward to the wheel; turning the wheel raises
	# one hand and lowers the other.
	driver.set_rot(&"arm_upper_l", Vector3(0, -1.05, 0.95 - st * 0.30 + hit * -1.5 + _arm_rest))
	driver.set_rot(&"arm_upper_r", Vector3(0, 1.05, -0.95 - st * 0.30 + hit * 1.5 - _arm_rest))
	driver.set_rot(&"arm_lower_l", Vector3(0, -0.7, 0))
	driver.set_rot(&"arm_lower_r", Vector3(0, 0.7, 0))
