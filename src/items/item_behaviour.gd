@tool
class_name ItemBehaviour
extends RefCounted
## What an item DOES. One script per behaviour in res://src/items/behaviours/ (or
## res://content/item_behaviours/ for add-ons); items themselves are data
## (res://content/items/<id>.json) that pick a behaviour and set its parameters, so
## "Triple Red Shell" and "Red Shell" share one script with a different "count".
##
## A behaviour script declares:
##   const BEHAVIOUR := "shell"            # id used by item definitions
##   const LABEL := "Shell (projectile)"   # shown in the Game Editor
##   const PARAMS := {"speed": {"type": "float", "default": 40.0, ...}, ...}
## and overrides use() (and optionally ai_should_use(), holdable(), release()).
## The Game Editor builds the item form from PARAMS, so a new behaviour shows up there
## with its own fields as soon as the file exists - nothing else to register.

## Fire the item. `back` is true when the player holds brake (S) while using it:
## projectiles go backwards, traps get thrown forward. Return false to keep the item.
func use(_items: RacerItems, _def: Dictionary, _p: Dictionary, _back: bool) -> bool:
	return true


## Hold the use button to drag this item behind you (bananas, shells as a shield).
func holdable(_def: Dictionary, _p: Dictionary) -> bool:
	return false


## Let go of a held item. Default: same as using it.
func release(items: RacerItems, def: Dictionary, p: Dictionary, back: bool) -> bool:
	return use(items, def, p, back)


## AI: should the holder use it now? ctx = {"rank", "count", "ahead": Racer|null,
## "ahead_gap" (m), "behind": Racer|null, "behind_gap" (m), "straight": bool, "held": s}
func ai_should_use(_items: RacerItems, _def: Dictionary, _p: Dictionary, ctx: Dictionary) -> bool:
	return float(ctx.get("held", 0.0)) > 3.0


# --- shared helpers -------------------------------------------------------------------

static func colour_of(def: Dictionary) -> Color:
	return Color.html(String(def.get("colour", "#ffffff")))


static func model_of(def: Dictionary) -> Node3D:
	return ItemModels.build(String(def.get("shape", "orb")), colour_of(def),
		String(def.get("model", "")), float(def.get("model_scale", 1.0)))


## Every racer other than `me`, ordered by race position (leader first).
static func rivals(me: Node) -> Array:
	return Bus.standings().filter(func(r): return r != me and is_instance_valid(r))
