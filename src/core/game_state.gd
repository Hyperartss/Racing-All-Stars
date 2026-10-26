extends Node
## Autoload: race/session state shared between racers, track and UI.

signal racer_registered(racer: Node)
signal race_state_changed(state: int)
signal countdown_tick(value: int)

enum RaceState { IDLE, COUNTDOWN, RACING, FINISHED }

var race_state: int = RaceState.IDLE
var total_laps := 3
var racers: Array[Node] = []
## Set by the main menu before loading the race scene:
## {"map": id, "laps": int, "player": {"character": id, "custom": {...}},
##  "opponents": [char ids], "return_to_menu": bool}
var race_config := {}


func register_racer(r: Node) -> void:
	if r in racers:
		return
	racers.append(r)
	racer_registered.emit(r)


func set_state(s: int) -> void:
	if race_state == s:
		return
	race_state = s
	race_state_changed.emit(s)


## Racers sorted by race position (leader first).
func standings() -> Array:
	var rs := racers.filter(func(r): return is_instance_valid(r))
	rs.sort_custom(func(a, b):
		if a.has_finished and b.has_finished:
			return a.race_time < b.race_time
		if a.has_finished != b.has_finished:
			return a.has_finished
		return a.progress_key() > b.progress_key())
	return rs


func reset() -> void:
	racers.clear()
	set_state(RaceState.IDLE)
