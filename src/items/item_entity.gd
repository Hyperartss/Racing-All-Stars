class_name ItemEntity
extends Node3D
## Something an item put on the course: a banana, a shell, a bomb, scattered rings.
## Subclasses override step() (motion) and on_racer() (what touching it does).
## Entities live under the track's "ItemWorld" node and touch racers by distance, so
## they work the same for every racer type and need no physics bodies of their own.

const GROUP := "item_entities"

var owner_racer: Node              ## Racer that made it (may be freed)
var track: Track
var life := 0.0                    ## seconds before it vanishes (0 = never)
var age := 0.0
var radius := 0.7
var owner_grace := 0.6             ## the owner cannot hit their own item this soon
var held := false                  ## dragged behind the owner
var blocks := true                 ## stops / is stopped by projectiles
var model: Node3D
var spin_speed := 0.0


static func world(trk: Track) -> Node3D:
	var w := trk.get_node_or_null("ItemWorld") as Node3D
	if w == null:
		w = Node3D.new()
		w.name = "ItemWorld"
		trk.add_child(w)
	return w


func _ready() -> void:
	add_to_group(GROUP)
	if model != null and model.get_parent() == null:
		add_child(model)


func _physics_process(delta: float) -> void:
	age += delta
	if life > 0.0 and age > life:
		vanish(false)
		return
	if model != null and spin_speed != 0.0:
		model.rotation.y += spin_speed * delta
	if held:
		_follow_owner()
	else:
		step(delta)
	if not is_inside_tree() or is_queued_for_deletion():
		return
	for r in GameState.racers:
		if not is_instance_valid(r) or r == null:
			continue
		if r == owner_racer and (held or age < owner_grace):
			continue
		if touching(r):
			on_racer(r)
			if is_queued_for_deletion():
				return


func step(_delta: float) -> void:
	pass


func on_racer(_r: Node) -> void:
	pass


func touching(r: Node) -> bool:
	var rp: Vector3 = (r as Node3D).global_position + Vector3.UP * 0.5
	return rp.distance_to(global_position + Vector3.UP * 0.3) < radius + 0.55


func vanish(burst: bool = true) -> void:
	if burst and is_inside_tree():
		BurstFx.spawn(get_parent(), global_position + Vector3.UP * 0.4, _burst_colour())
	if owner_racer != null and is_instance_valid(owner_racer) and owner_racer.get("items") != null:
		var it: RacerItems = owner_racer.items
		if it.held_entity == self:
			it.held_entity = null
	queue_free()


func _burst_colour() -> Color:
	return Color(1, 0.9, 0.5)


func _follow_owner() -> void:
	if owner_racer == null or not is_instance_valid(owner_racer):
		held = false
		return
	var o := owner_racer as Node3D
	var back := o.global_transform.basis.z
	back.y = 0.0
	back = back.normalized() if back.length() > 0.01 else Vector3.BACK
	global_position = o.global_position + back * 1.5 + Vector3.UP * 0.05
	rotation.y = o.rotation.y


## Ray against the course only (layer 1).
func ray(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	return space.intersect_ray(q)


## Put the entity on the ground under it. Returns false over a void.
func snap_to_ground(lift: float = 0.0) -> bool:
	var hit := ray(global_position + Vector3.UP * 2.5, global_position + Vector3.DOWN * 8.0)
	if hit.is_empty():
		return false
	global_position = hit.position + Vector3.UP * lift
	return true


## Other entities close by that block / get blocked by projectiles.
func blockers_near(r: float) -> Array:
	var out: Array = []
	for e in get_tree().get_nodes_in_group(GROUP):
		if e == self or not is_instance_valid(e) or e.is_queued_for_deletion():
			continue
		var ie := e as ItemEntity
		if ie == null or not ie.blocks:
			continue
		if ie.global_position.distance_to(global_position) < r + ie.radius:
			out.append(ie)
	return out


static func hit_racer(r: Node, kind: String, seconds: float, by: Node) -> bool:
	if r == null or not is_instance_valid(r) or r.get("items") == null:
		return false
	return (r.items as RacerItems).hit(kind, seconds, by)
