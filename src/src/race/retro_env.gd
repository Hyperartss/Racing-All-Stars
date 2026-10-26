class_name RetroEnv
extends Node3D
## Sky colour, fog, ambient and a sun for the N64/PS1 look. No shadows, no glow.

func _ready() -> void:
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.46, 0.68, 0.95)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.64, 0.7)
	e.ambient_light_energy = 1.0
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_light_color = Color(0.62, 0.78, 0.97)
	e.fog_depth_begin = 160.0
	e.fog_depth_end = 420.0
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	we.environment = e
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 0.75
	sun.shadow_enabled = false
	add_child(sun)
