@tool
class_name TrackObject
extends Node3D
## Base for gameplay objects placed on a map with the Map Editor (rings, item boxes,
## doors, collectables, dash panels, springs ...). They are stored in decor.json's
## "props" list like decoration, with a "params" block:
##   {"type": "ring_door", "pos": [...], "yaw": 90, "scale": 1, "tint": "#3060d0",
##    "params": {"cost": 30}}
##
## Each behaviour is one script in res://src/objects/behaviours/ (or
## res://content/object_behaviours/) that extends TrackObject and declares
##   const BEHAVIOUR := "door"
##   const LABEL := "Ring door"
##   const PARAMS := {"cost": {"type": "int", "default": 20, ...}}
## Object TYPES are data: res://content/objects/<id>.json picks a behaviour and its
## defaults, shape/colour or your own "model". The Map Editor lists every type and
## builds the selected object's settings from PARAMS.

var entry: Dictionary = {}
var def: Dictionary = {}
var p: Dictionary = {}          ## merged parameters (behaviour defaults < type < entry)
var editor := false             ## built for the Map Editor: visual only, no gameplay
var track: Track
var map_id := ""


func setup(e: Dictionary, d: Dictionary, params: Dictionary, editor_mode: bool) -> void:
	entry = e
	def = d
	p = params
	editor = editor_mode


## Build the visual (and colliders). Called before the node enters the tree, so the
## editor can measure it straight away.
func build() -> void:
	add_child(model())


func _ready() -> void:
	if editor:
		set_physics_process(false)
		set_process(false)
		return
	track = _find_track()
	if track != null:
		map_id = track.data_path.get_base_dir().get_file()
	game_ready()


func game_ready() -> void:
	pass


func _physics_process(delta: float) -> void:
	tick(delta)


func tick(_delta: float) -> void:
	pass


func _find_track() -> Track:
	var n := get_parent()
	while n != null:
		if n is Track:
			return n
		n = n.get_parent()
	return null


func colour() -> Color:
	return Color.html(String(entry.get("tint", def.get("colour", "#ffffff"))))


func model(shape: String = "") -> Node3D:
	var s := shape if shape != "" else String(def.get("shape", "orb"))
	return ItemModels.build(s, colour(), String(def.get("model", "")), float(def.get("model_scale", 1.0)))


func racers() -> Array:
	return Bus.racers()


## Racer inside a box around this object: half sizes in the object's own (unscaled)
## axes, `up` metres above / below.
func in_box(r: Node, half_x: float, half_z: float, up: float = 2.0) -> bool:
	var lp := global_transform.affine_inverse() * ((r as Node3D).global_position)
	var s := global_transform.basis.get_scale()
	return absf(lp.x * s.x) < half_x and absf(lp.z * s.z) < half_z and lp.y * s.y > -up * 0.5 and lp.y * s.y < up


## Course height under a world point (or the point itself if nothing is below).
func ground_at(world: Vector3, reach: float = 8.0) -> Vector3:
	if not is_inside_tree():
		return world
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(world + Vector3.UP * 3.0, world + Vector3.DOWN * reach, 1)
	var hit := space.intersect_ray(q)
	return hit.position if not hit.is_empty() else world


func player_racer(r: Node) -> bool:
	var c: Variant = r.get("controller")
	return c != null and c.get_script() != null and String(c.get_script().resource_path).ends_with("player_controller.gd")
