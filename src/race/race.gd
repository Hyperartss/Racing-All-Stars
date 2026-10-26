class_name Race
extends Node3D
## Race scene root: builds the course, puts the roster on the grid, runs the
## countdown and laps, follows one racer with the camera.
##
## Command-line overrides (after `--`):
##   --roster=sonic,mario   --player=0 (-1 = all AI)   --laps=3

@export var roster: PackedStringArray = ["sonic", "mario"]
@export var player_index := 0
@export var laps := 3
@export var countdown := true

var track: Track
var racers: Array[Racer] = []
var camera: ChaseCamera
var hud: RaceHUD
var _cam_i := 0
var _count := 0.0
var results: Array = []


func _ready() -> void:
	_read_args()
	GameState.reset()
	GameState.total_laps = laps
	add_child(RetroEnv.new())
	track = Track.new()
	track.name = "Track"
	add_child(track)
	track.load_track()
	for k in roster.size():
		var ctrl: RacerController = PlayerController.new() if k == player_index else AIController.new(k + 1)
		var r := Racer.create(roster[k], track, ctrl)
		r.total_laps = laps
		add_child(r)
		r.place(track.grid_transform(k))
		r.finished.connect(_on_finished)
		r.lap_completed.connect(_on_lap)
		racers.append(r)
	camera = ChaseCamera.new()
	camera.target = racers[maxi(player_index, 0)] if racers.size() > 0 else null
	_cam_i = maxi(player_index, 0)
	add_child(camera)
	camera.current = true
	hud = RaceHUD.new()
	hud.race = self
	add_child(hud)
	_count = 3.0 if countdown else 0.0
	GameState.set_state(GameState.RaceState.COUNTDOWN if countdown else GameState.RaceState.RACING)
	if not countdown:
		_go()


func _read_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--roster="):
			roster = PackedStringArray(a.trim_prefix("--roster=").split(","))
		elif a.begins_with("--player="):
			player_index = int(a.trim_prefix("--player="))
		elif a.begins_with("--laps="):
			laps = int(a.trim_prefix("--laps="))
		elif a == "--no-countdown":
			countdown = false


func _go() -> void:
	for r in racers:
		r.race_active = true
	GameState.set_state(GameState.RaceState.RACING)
	EventBus.hud_message.emit("GO!", 1.0)


func _process(delta: float) -> void:
	if GameState.race_state == GameState.RaceState.COUNTDOWN:
		var before := ceili(_count)
		_count -= delta
		if ceili(_count) != before and _count > 0.0:
			EventBus.hud_message.emit(str(ceili(_count)), 0.9)
		if _count <= 0.0:
			_go()


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_TAB and racers.size() > 0:
		_cam_i = (_cam_i + 1) % racers.size()
		camera.target = racers[_cam_i]
	if e is InputEventKey and e.pressed and e.keycode == KEY_R and player_index >= 0:
		racers[player_index].respawn()


func _on_lap(r: Racer, lap: int, t: float) -> void:
	if r == camera.target and lap < laps:
		EventBus.hud_message.emit("LAP %d  %s" % [lap + 1, RaceHUD._fmt(t)], 1.5)


func _on_finished(r: Racer, t: float) -> void:
	results.append({"name": r.display_name, "time": t})
	if r == camera.target:
		EventBus.hud_message.emit("FINISH!  %s" % RaceHUD._fmt(t), 4.0)
	if results.size() == racers.size():
		GameState.set_state(GameState.RaceState.FINISHED)
