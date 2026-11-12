extends Node
## Renders a few frames of an all-AI race with gameplay objects placed, in a console
## look: godot --path . res://scenes/capture_gameplay.tscn -- --look=saturn --out=/tmp/shots
var race: Race
var frame := 0
var look := "saturn_dreamcast"
var out := "res://out"
var shots := [200, 420, 700, 1000]

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--look="):
			look = a.trim_prefix("--look=")
		elif a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out if out.begins_with("/") else ProjectSettings.globalize_path(out))
	GameState.race_config = {}
	RetroLook.set_look(look)
	race = Race.new()
	race.player_index = -1
	race.countdown = false
	race.laps = 1
	race.roster = PackedStringArray(["sonic", "eggman", "tails", "shadow"])
	add_child(race)

func _place(type: String, dist: float, params := {}) -> void:
	var path := race.track.path
	var i := path.index_at_distance(dist)
	var t := path.tangent[i]
	var e := {"type": type, "pos": [path.pos[i].x, path.pos[i].y, path.pos[i].z], "yaw": rad_to_deg(atan2(-t.x, -t.z)), "params": params}
	race.track.props_root.add_child(TrackProps.make(e, false))

func _physics_process(_d: float) -> void:
	frame += 1
	if frame == 2:
		for k in 8:
			_place("item_box_row", 40.0 + k * 110.0, {"count": 4})
			_place("ring_line", 75.0 + k * 110.0, {"count": 6})
		_place("ring_door", 160.0, {"cost": 0, "width": 14.0})
		_place("dash_pad", 120.0)
		_place("gold_token", 100.0)
		race.racers[0].items.slot = "red_shell"
		race.racers[0].items.uses = 1
		race.racers[0].items.add_rings(7)
	if frame in shots:
		get_viewport().get_texture().get_image().save_png(out.path_join("%s_%d.png" % [look, frame]))
	if frame > shots[-1] + 2:
		get_tree().quit()
