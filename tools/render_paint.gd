extends Node
## Renders characters with different paint jobs -> out/paint.png
func _ready() -> void:
	get_viewport().size = Vector2i(1200, 500)
	add_child(RetroEnv.new())
	var cam := Camera3D.new(); add_child(cam); cam.current = true
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL; cam.size = 3.7
	cam.position = Vector3(0, 1.2, 5); cam.look_at(Vector3(0, 0.55, 0))
	var setups := [
		["sonic", {}], ["sonic", {"paint": {"fur": "#f0d020", "shoes": "#2050ff"}}],
		["mario", {}], ["mario", {"paint": {"outfit": "#20a040"}, "kart_paint": {"body": "#2050e0", "wheels": "#ffe080", "emblem": false}}],
	]
	var vis: Array = []
	for i in setups.size():
		var v := RacerTypes.make_visual(setups[i][0], setups[i][1])
		add_child(v)
		v.position = Vector3(-2.4 + i * 1.6, 0, 0)
		v.rotation.y = PI * 0.8
		vis.append(v)
	for f in 20:
		for v in vis:
			var st := RacerVisual.AnimState.new()
			v.update_visual(st, 1.0 / 60.0)
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://out/paint.png")
	get_tree().quit()
