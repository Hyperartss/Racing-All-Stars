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
@export var map_id := "retro_circuit"
## Per-roster-slot customisation (same order as roster).
var customs: Array = []
var return_to_menu := false

var track: Track
var racers: Array[Racer] = []
var camera: ChaseCamera
var hud: RaceHUD
var _cam_i := 0
var _count := 0.0
var results: Array = []


func _ready() -> void:
	_read_args()
	_apply_config(GameState.race_config)
	GameState.reset()
	GameState.total_laps = laps
	add_child(RetroEnv.new())
	track = Track.new()
	track.name = "Track"
	add_child(track)
	var map_def: Dictionary = RacerTypes.maps().get(map_id, {})
	track.load_track(String(map_def.get("data", Track.DEFAULT_DATA)))
	for k in roster.size():
		var ctrl: RacerController = PlayerController.new() if k == player_index else AIController.new(k + 1)
		var custom: Dictionary = customs[k] if k < customs.size() else {}
		var r := Racer.create(roster[k], track, ctrl, custom)
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


## Race set up by the main menu (player first, then opponents).
func _apply_config(cfg: Dictionary) -> void:
	if cfg.is_empty():
		return
	map_id = String(cfg.get("map", map_id))
	laps = int(cfg.get("laps", laps))
	var p: Dictionary = cfg.get("player", {})
	roster = PackedStringArray([String(p.get("character", "sonic"))])
	customs = [p.get("custom", {})]
	for o in cfg.get("opponents", []):
		if o is Dictionary:
			roster.append(String(o.get("character", "sonic")))
			customs.append(o.get("custom", {}))
		else:
			roster.append(String(o))
			customs.append({})
	player_index = 0
	return_to_menu = bool(cfg.get("return_to_menu", false))


func _read_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--roster="):
			roster = PackedStringArray(a.trim_prefix("--roster=").split(","))
		elif a.begins_with("--player="):
			player_index = int(a.trim_prefix("--player="))
		elif a.begins_with("--laps="):
			laps = int(a.trim_prefix("--laps="))
		elif a.begins_with("--map="):
			map_id = a.trim_prefix("--map=")
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
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_lap(r: Racer, lap: int, t: float) -> void:
	if r == camera.target and lap < laps:
		EventBus.hud_message.emit("LAP %d  %s" % [lap + 1, RaceHUD._fmt(t)], 1.5)


func _on_finished(r: Racer, t: float) -> void:
	results.append({"name": r.display_name, "time": t})
	if r == camera.target:
		EventBus.hud_message.emit("FINISH!  %s" % RaceHUD._fmt(t), 4.0)
	if results.size() == racers.size() or (player_index >= 0 and r == racers[player_index]):
		GameState.set_state(GameState.RaceState.FINISHED)
		if return_to_menu:
			EventBus.hud_message.emit("FINISH!  %s   [Esc] menu" % RaceHUD._fmt(t), 30.0)
