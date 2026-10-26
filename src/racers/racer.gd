class_name Racer
extends CharacterBody3D
## A racer of any type. Owns the body, progress (checkpoints/laps), respawning and
## the vertical loop; delegates motion to a MovementModel, intent to a
## RacerController and looks to a RacerVisual. All three come from RacerTypes, so a
## new racer type plugs in without changes here.

signal lap_completed(racer: Racer, lap: int, time: float)
signal finished(racer: Racer, time: float)
signal respawned(racer: Racer, reason: String, at: Vector3)

var character := "sonic"
var display_name := "Racer"
var colour := Color.WHITE
var movement: MovementModel
var controller: RacerController
var visual: RacerVisual
var track: Track

# --- progress ---
var track_index := -1
var distance := 0.0
var next_cp := 1               ## next checkpoint to reach (0 is the finish line)
var laps_done := 0
var total_laps := 3
var race_time := 0.0
var lap_start := 0.0
var lap_times: Array[float] = []
var has_finished := false
var race_active := false
var respawns := 0
var _prev_distance := 0.0
var _last_good_index := 0
var _off_timer := 0.0
var _stall_time := 0.0
var _loc := {}
var _under_time := 0.0
var _stall_dist := -1.0

# --- loop riding ---
var on_rail := false
var _rail_s := 0.0
var _rail_lat := 0.0
var _rail_cool := 0.0

## Visual tilt toward the floor normal (smoothed).
var _tilt := Basis.IDENTITY


static func create(char_id: String, trk: Track, ctrl: RacerController) -> Racer:
	var r := Racer.new()
	r.character = char_id
	var c: Dictionary = RacerTypes.CHARACTERS[char_id]
	r.display_name = c.name
	r.colour = c.colour
	r.track = trk
	r.controller = ctrl
	r.movement = RacerTypes.make_movement(char_id)
	r.visual = RacerTypes.make_visual(char_id)
	return r


func _ready() -> void:
	name = display_name
	collision_layer = 2
	collision_mask = 1 | 2
	floor_max_angle = deg_to_rad(52.0)
	floor_snap_length = 0.7
	floor_constant_speed = true
	floor_stop_on_slope = false
	safe_margin = 0.02
	add_child(movement.make_shape())
	add_child(visual)
	movement.setup(self)
	GameState.register_racer(self)


func place(t: Transform3D) -> void:
	global_transform = Transform3D(Basis.IDENTITY, t.origin)
	var f := -t.basis.z
	var h := atan2(-f.x, -f.z)
	rotation = Vector3(0, h, 0)
	movement.reset_motion(h)
	on_rail = false
	var loc := track.locate(global_position, -1)
	track_index = loc.index
	distance = loc.distance
	_prev_distance = distance


func _physics_process(delta: float) -> void:
	if track == null:
		return
	var inp: RacerInput = controller.get_input(self, delta) if race_active and not has_finished else RacerInput.new()
	if has_finished:
		inp.throttle = 0.4      # cruise after the line
		inp.steer = controller.get_input(self, delta).steer if controller is AIController else 0.0
	if on_rail:
		_rail_step(inp, delta)
	else:
		movement.physics_step(inp, delta)
		rotation.y = movement.heading
		_maybe_enter_rail()
	if race_active:
		race_time += delta
	_update_progress(delta)
	_check_respawn(delta)
	_update_visual(delta)


# --- Loop: ride the centreline frames --------------------------------------------

func _maybe_enter_rail() -> void:
	if _rail_cool > 0.0:
		_rail_cool -= get_physics_process_delta_time()
		return
	var p := track.path
	if not (p.flags[track_index] & TrackPath.FLAG_LOOP):
		return
	# Only at the loop's entry (the exit lane sits right beside it).
	var first := track_index
	while p.flags[p.wi(first - 1)] & TrackPath.FLAG_LOOP:
		first = p.wi(first - 1)
	if p.wi(track_index - first) > 3:
		return
	if movement.speed < 4.0:
		return
	var i := track_index
	var off := global_position - track.path.pos[i]
	if absf(off.dot(track.path.up[i])) > 2.0:
		return
	on_rail = true
	_rail_s = track.path.dist[i]
	_rail_lat = clampf(off.dot(track.path.right[i]), -4.0, 4.0)


func _rail_step(inp: RacerInput, delta: float) -> void:
	var p := track.path
	# Keep momentum through the loop (a minimum speed so nobody stalls upside down).
	movement.speed = maxf(movement.speed, 15.0) + inp.throttle * 4.0 * delta
	_rail_s += movement.speed * delta
	_rail_lat = clampf(_rail_lat + inp.steer * -3.0 * delta, -4.0, 4.0)
	var i := p.index_at_distance(_rail_s)
	var j := p.wi(i + 1)
	var f := clampf((_rail_s - p.dist[i]) / maxf(p.dist[j] - p.dist[i], 0.01), 0.0, 1.0)
	var pos := p.pos[i].lerp(p.pos[j], f)
	var up := p.up[i].lerp(p.up[j], f).normalized()
	var tan := p.tangent[i].lerp(p.tangent[j], f).normalized()
	var right := tan.cross(up).normalized()
	global_position = pos + right * _rail_lat + up * 0.05
	track_index = i
	# Body faces along the loop; the movement heading follows the flat direction.
	var b := Basis(right, up, -tan)
	global_transform.basis = b
	velocity = tan * movement.speed
	movement.anim.grounded = true
	movement.anim.speed = movement.speed
	movement.anim.steer = inp.steer
	movement.anim.jumping = false
	if not (p.flags[j] & TrackPath.FLAG_LOOP):
		on_rail = false
		_rail_cool = 1.0
		var h := atan2(-tan.x, -tan.z)
		movement.heading = h
		if movement is KartMovement:
			(movement as KartMovement).vel_dir = h
		rotation = Vector3(0, h, 0)
		velocity = tan * movement.speed


# --- Progress ----------------------------------------------------------------------

func _update_progress(delta: float) -> void:
	var loc := track.locate(global_position, track_index)
	_loc = loc
	track_index = loc.index
	distance = loc.distance
	var total := track.path.length
	var cps := track.checkpoints
	# Forward progress, unwrapped across the finish line.
	var d := distance - _prev_distance
	if d < -total * 0.5:
		d += total
	elif d > total * 0.5:
		d -= total
	if absf(d) < 40.0:
		# next checkpoint crossed?
		if next_cp < cps.size():
			var cd := track.checkpoint_distance(next_cp)
			if _crossed(_prev_distance, distance, cd, total):
				next_cp += 1
				EventBus.checkpoint_passed.emit(self, next_cp - 1)
		elif _crossed(_prev_distance, distance, 0.0, total):
			_complete_lap()
	_prev_distance = distance
	if absf(loc.lateral) < loc.half_width + 3.0 and not loc.on_fork:
		_last_good_index = track_index


static func _crossed(a: float, b: float, mark: float, total: float) -> bool:
	# Moving forward from a to b (with wrap) passes `mark`?
	var da := fposmod(mark - a, total)
	var db := fposmod(b - a, total)
	return db < total * 0.5 and da > 0.0 and da <= db


func _complete_lap() -> void:
	laps_done += 1
	next_cp = 1
	var lt := race_time - lap_start
	lap_start = race_time
	lap_times.append(lt)
	lap_completed.emit(self, laps_done, lt)
	EventBus.lap_crossed.emit(self, laps_done)
	if laps_done >= total_laps and not has_finished:
		has_finished = true
		finished.emit(self, race_time)


## Race position key: laps + checkpoints + distance.
func progress_key() -> float:
	var total := track.path.length
	var into_lap := fposmod(distance - 0.0, total)
	if next_cp == 1 and into_lap > total * 0.5:
		into_lap = 0.0      # still behind the line at the start
	return laps_done * 100000.0 + next_cp * 1000.0 + into_lap * 0.1


# --- Respawn -----------------------------------------------------------------------

func _check_respawn(delta: float) -> void:
	var ref := track.path.pos[track_index]
	if _loc.get("on_fork", false):
		ref = track.fork.pos[int(_loc.fork_index)]
	var loc_far := global_position.distance_to(ref) > 45.0
	if loc_far:
		_off_timer += delta
	else:
		_off_timer = 0.0
	# No forward progress for a long time (wedged somewhere): put back on the road.
	if race_active and not has_finished:
		if distance != _stall_dist:
			if absf(distance - _stall_dist) > 3.0:
				_stall_dist = distance
				_stall_time = 0.0
		_stall_time += delta
	# Dropped under the course (e.g. off an edge onto the ground layer)?
	var below := track.path.pos[track_index].y - global_position.y
	if not on_rail and not _loc.get("on_fork", false) and below > 3.5:
		_under_time += delta
	else:
		_under_time = 0.0
	var why := ""
	if _under_time > 1.0:
		why = "under course"
		_under_time = 0.0
	elif global_position.y < track.kill_y:
		why = "fell"
	elif _off_timer > 3.0:
		why = "off course"
	elif _stall_time > 7.0:
		why = "stalled"
	if why != "":
		respawned.emit(self, why, global_position)
		respawn()
		_stall_time = 0.0
		_stall_dist = distance


func respawn() -> void:
	respawns += 1
	var i := track.path.wi(_last_good_index - 3)
	place(track.respawn_transform(i))
	_off_timer = 0.0


# --- Visual ------------------------------------------------------------------------

func _update_visual(delta: float) -> void:
	if on_rail:
		visual.transform = Transform3D.IDENTITY
	else:
		# Tilt the model to the ground under it (body yaw stays in rotation.y).
		var n := get_floor_normal() if is_on_floor() else Vector3.UP
		var local_n := global_transform.basis.inverse() * n
		var target := Basis(Quaternion(Vector3.UP, local_n.normalized()))
		_tilt = _tilt.slerp(target, 1.0 - exp(-10.0 * delta))
		visual.transform = Transform3D(_tilt, Vector3.ZERO)
	visual.update_visual(movement.anim, delta)
