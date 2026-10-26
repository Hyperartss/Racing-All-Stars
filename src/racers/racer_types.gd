class_name RacerTypes
extends RefCounted
## Registry of racer types and characters.
##
## Adding a racer type (e.g. a flyer) = write a MovementModel subclass + a
## RacerVisual subclass, then add one entry to TYPES. Existing types are untouched.
## Adding a character = one entry in CHARACTERS pointing at a type.

static var TYPES := {
	"runner": {"movement": RunnerMovement, "ai_uses_action": "dash"},
	"kart": {"movement": KartMovement, "ai_uses_action": "drift"},
}

static var CHARACTERS := {
	"sonic": {"name": "Sonic", "type": "runner", "visual": SonicVisual, "colour": Color(0.2, 0.4, 1.0)},
	"mario": {"name": "Mario", "type": "kart", "visual": KartVisual, "colour": Color(0.9, 0.15, 0.15),
		"visual_props": {"kart_rig_path": "res://assets/rigs/kart_standard.json", "driver_rig_path": "res://assets/rigs/mario.json"}},
}


static func make_movement(character: String) -> MovementModel:
	var c: Dictionary = CHARACTERS[character]
	var t: Dictionary = TYPES[c.type]
	var script: GDScript = t.movement
	return script.new()


static func make_visual(character: String) -> RacerVisual:
	var c: Dictionary = CHARACTERS[character]
	var script: GDScript = c.visual
	var v: RacerVisual = script.new()
	var props: Dictionary = c.get("visual_props", {})
	for k in props:
		v.set(k, props[k])
	return v
