@tool
class_name Bus
extends RefCounted
## Late-bound access to the GameState / EventBus autoloads for code that is also
## loaded by the editor tools (track objects, models): those scripts must compile
## where the autoloads do not exist (editor docks, `godot -s` test scripts), so they
## look the singletons up at run time instead of naming them.


static func _root() -> Node:
	var ml := Engine.get_main_loop()
	return (ml as SceneTree).root if ml is SceneTree else null


static func game_state() -> Node:
	var r := _root()
	return r.get_node_or_null("GameState") if r != null else null


static func event_bus() -> Node:
	var r := _root()
	return r.get_node_or_null("EventBus") if r != null else null


## Every live racer.
static func racers() -> Array:
	var gs := game_state()
	if gs == null:
		return []
	return (gs.get("racers") as Array).filter(func(r): return is_instance_valid(r))


static func standings() -> Array:
	var gs := game_state()
	return gs.call("standings") if gs != null else []


static func action(racer: Node, action_name: StringName, data: Dictionary = {}) -> void:
	var eb := event_bus()
	if eb != null:
		eb.emit_signal("racer_action", racer, action_name, data)


static func hud(text: String, seconds: float) -> void:
	var eb := event_bus()
	if eb != null:
		eb.emit_signal("hud_message", text, seconds)
