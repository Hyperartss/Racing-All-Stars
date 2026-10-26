extends Node
## Debug render: camera behind centreline sample N (arg --idx=N) -> out/view_N.png
func _ready() -> void:
	add_child(RetroEnv.new())
	var idx := 0
	var map_id := "retro_circuit"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--idx="): idx = int(a.trim_prefix("--idx="))
		if a.begins_with("--map="): map_id = a.trim_prefix("--map=")
	var t := Track.new(); add_child(t); t.load_track(String(RacerTypes.maps()[map_id].data))
	var cam := Camera3D.new(); add_child(cam); cam.current = true; cam.far = 600
	var p := t.path.pos[idx]
	cam.position = p - t.path.tangent[idx] * 10.0 + Vector3(0, 4, 0)
	cam.look_at(p + Vector3(0, 1, 0))
	for k in 4: await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://out/view_%d.png" % idx)
	get_tree().quit()
