extends Node
## Renders gameplay frames from an all-AI race to out/race_*.png.
var race: Race
var frame := 0
var shots := {120: ["grid", 0], 420: ["sonic_run", 0], 720: ["mario_drift", 1], 1020: ["sonic_island", 0], 1320: ["mario_island", 1], 1650: ["mario_later", 1], 2000: ["sonic_later", 0]}

func _ready() -> void:
	race = Race.new()
	race.player_index = -1
	race.countdown = false
	race.laps = 1
	add_child(race)

func _physics_process(_d: float) -> void:
	frame += 1
	for f in shots:
		if frame == f - 30:
			race.camera.target = race.racers[shots[f][1]]
		if frame == f:
			get_viewport().get_texture().get_image().save_png("res://out/race_%s.png" % shots[f][0])
			var r: Racer = race.racers[shots[f][1]]
			print("%s: idx %d on_rail %s state %s" % [shots[f][0], r.track_index, r.on_rail, r.movement.anim.speed])
	if frame > 2050:
		get_tree().quit()
