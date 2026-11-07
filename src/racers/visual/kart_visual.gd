@tool
class_name KartVisual
extends RacerVisual
## Kart + driver, both vertex-animated:
##   kart  - wheel spin tied to speed (each wheel's own radius), front-wheel steering,
##           body lean in turns, drift slide and hop
##   driver - seated pose built from the standing model (or the character's own clips),
##            head turns toward the steer direction, arms work the wheel, leans with
##            the body
##
## The driver rig is parented to the kart body's current transform, so whatever the
## body polygons do (lean, hop) the driver follows.

@export var kart_rig_path := "res://assets/rigs/kart_standard.json"
@export var driver_rig_path := "res://assets/rigs/mario.json"
## Where the driver's hips sit, in kart space (rest pose).
@export var seat := Vector3(0.0, 0.05, 0.16)
@export var driver_scale := 0.0  ## 0 = automatic (1.1 m tall, like a runner)

var kart: VertexRig
var driver: VertexRig
var spin := 0.0
var steer_vis := 0.0
var lean := 0.0
var drift_yaw := 0.0
var head_yaw := 0.0
var hop := 0.0
var _was_drift := 0
var wheels := {}  ## name -> radius
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
	# Any driver is scaled to the same standing height as a runner, so a kart driver
	# no longer looks small beside one on the track.
	var h := (
		float(driver.meta.get("aabb_max", [0, 0.85, 0])[1])
		- float(driver.meta.get("aabb_min", [0, 0, 0])[1])
	)
	if driver_scale <= 0.0:
		driver_scale = 1.1 / maxf(h, 0.05)
	init_anim()


func update_visual(s: AnimState, delta: float) -> void:
	super(s, delta)
	var k := clampf(absf(s.speed) / maxf(s.max_speed, 0.01), 0.0, 1.5)
	# Custom clips (Animation Editor): the seated driver can breathe and lean with speed.
	advance_clip(&"drive", delta, 0.5 + clampf(k, 0.0, 1.0))
	advance_clip(&"idle", delta, 1.0)
	advance_clip(&"hit", delta, 1.0)

	# --- kart ----------------------------------------------------------------
	spin -= s.speed * delta  # angle * radius = distance; divided per wheel below
	steer_vis = approach(steer_vis, s.steer * 0.45, 12.0, delta)
	var lean_tgt := -s.steer * 0.10 * clampf(k, 0.0, 1.0) - float(s.drift_dir) * 0.08
	lean = approach(lean, lean_tgt, 8.0, delta)
	drift_yaw = approach(drift_yaw, float(s.drift_dir) * 0.38, 6.0, delta)
	if s.drift_dir != 0 and _was_drift == 0:
		hop = 1.0  # little hop on drift start
	_was_drift = s.drift_dir
	hop = maxf(0.0, hop - delta * 6.0)
	var hop_y := sin(hop * PI) * 0.12
	var shake := sin(time * 60.0) * 0.006 * k  # engine buzz

	kart.reset_pose()
	for w in wheels:
		var r: float = wheels[w]
		var roll := Basis(Vector3.RIGHT, spin / r)
		if w.begins_with("wheel_f"):
			kart.set_part_basis(w, Basis(Vector3.UP, steer_vis) * roll)
		else:
			kart.set_part_basis(w, roll)
	var body_b := (
		Basis(Vector3.UP, drift_yaw)
		* Basis(Vector3.BACK, lean)
		* Basis(
			Vector3.RIGHT,
			-0.04 * float(s.boosting) + (0.15 if s.hit > 0.0 else 0.0) * sin(time * 25.0)
		)
	)
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


## Hit-stun flinch of a seated driver: torso recoiling, head thrown back, arms flung
## out to the sides. `t` drives the wobble. The game blends it in by the hit timer and
## the Character Importer bakes it as the "hit" clip of an imported kart driver.
static func default_hit_pose(arm_rest: float = 0.0, t: float = 0.0) -> Dictionary:
	var wob := sin(t * 26.0)
	var p := default_drive_pose(arm_rest)
	p["torso"] = {"rot": Vector3(-0.12 - 0.22 - 0.06 * wob, 0.12 * wob, 0.10 * wob)}
	p["head"] = {"rot": Vector3(0.05 - 0.45, 0.22 * wob, 0)}
	p["arm_upper_l"] = {"rot": Vector3(0, -1.05, 0.95 + arm_rest - 1.35 + 0.12 * wob)}
	p["arm_upper_r"] = {"rot": Vector3(0, 1.05, -0.95 - arm_rest + 1.35 - 0.12 * wob)}
	p["arm_lower_l"] = {"rot": Vector3(0.55, -0.7, 0)}
	p["arm_lower_r"] = {"rot": Vector3(0.55, 0.7, 0)}
	p["leg_upper_l"] = {"rot": Vector3(1.35, 0.05, -0.18)}
	p["leg_upper_r"] = {"rot": Vector3(1.35, -0.05, 0.18)}
	return p


## The seated pose the driver starts from (without steering / speed changes).
## The Animation Editor seeds new kart clips with it, and the Character Importer bakes
## it as the "drive" clip of a new kart driver, so a custom clip starts from the same
## seated pose the game uses instead of a standing rest pose.
static func default_drive_pose(arm_rest: float = 0.0) -> Dictionary:
	return {
		"hips": {"rot": Vector3(0, 0, 0)},
		"torso": {"rot": Vector3(-0.12, 0, 0)},
		"head": {"rot": Vector3(0.05, 0, 0)},
		"leg_upper_l": {"rot": Vector3(1.45, 0.05, 0)},
		"leg_upper_r": {"rot": Vector3(1.45, -0.05, 0)},
		"leg_lower_l": {"rot": Vector3(-1.0, 0, 0)},
		"leg_lower_r": {"rot": Vector3(-1.0, 0, 0)},
		"arm_upper_l": {"rot": Vector3(0, -1.05, 0.95 + arm_rest)},
		"arm_upper_r": {"rot": Vector3(0, 1.05, -0.95 - arm_rest)},
		"arm_lower_l": {"rot": Vector3(0, -0.7, 0)},
		"arm_lower_r": {"rot": Vector3(0, 0.7, 0)},
	}


## Seats the driver and animates it. The base pose comes from the character's own
## clips ("drive"/"idle", with "hit" blended in) or, without clips, from the built-in
## seated pose - so every driver sits, imported or hand-made. Steering, cornering and
## the hit shake are then layered on top of whichever base pose was used, which keeps
## an authored clip reacting to the wheel like the built-in one.
func _pose_driver(s: AnimState, k: float) -> void:
	driver.reset_pose()
	var st := steer_vis / 0.45  # -1..1
	var hit := 1.0 if s.hit > 0.0 else 0.0
	var base := clip_pose(&"drive")
	if base.is_empty():
		base = clip_pose(&"idle")
	if base.is_empty():
		base = default_drive_pose(_arm_rest)
	if hit > 0.0:
		var flinch := clip_pose(&"hit")
		if flinch.is_empty():
			flinch = default_hit_pose(_arm_rest, time)
		blend_pose(driver, [base, flinch], [1.0 - hit, hit])
	else:
		blend_pose(driver, [base], [1.0])
	# Hips/torso: lean into the corner, slight forward hunch at speed.
	driver.add_rot(&"hips", Vector3(0, 0, -lean * 1.2))
	driver.add_rot(&"torso", Vector3(-0.08 * k, st * 0.12, st * 0.10))
	# Head turns toward where we are steering (and shakes when hit).
	driver.add_rot(&"head", Vector3(0.3 * hit * sin(time * 20.0), head_yaw, -st * 0.08))
	# Arms work the wheel: turning it raises one hand and lowers the other.
	driver.add_rot(&"arm_upper_l", Vector3(0, 0, -st * 0.30))
	driver.add_rot(&"arm_upper_r", Vector3(0, 0, -st * 0.30))
