extends Node
## Autoload: global signal hub so gameplay systems stay decoupled.
## Extend this with new signals rather than wiring cross-references.

## A racer passed a checkpoint in order.
signal checkpoint_passed(racer: Node, index: int)
## A racer crossed the start/finish line (always one full lap after CP 0).
signal lap_crossed(racer: Node, lap: int)
## Generic per-racer state change: "dash", "drift", "boost", "jump", "hit".
signal racer_action(racer: Node, action: StringName, data: Dictionary)
## Vehicle model changed (runner <-> kart, or a new racer type joins).
signal racer_type_changed(racer: Node, type_name: StringName)
## HUD hint line, e.g. "MINI-TURBO!".
signal hud_message(text: String, seconds: float)
