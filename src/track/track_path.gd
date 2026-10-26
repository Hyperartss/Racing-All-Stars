class_name TrackPath
extends RefCounted
## A track centreline as baked samples (2 m apart): position, up, right, tangent,
## width, flags and distance. Used for progress, checkpoints, AI and respawns.
## Physics never uses it - racers drive on the real collision geometry - except in
## the vertical loop, where racers ride the centreline frames (see Racer).

const FLAG_LOOP := 4
const FLAG_ISLAND := 8

var pos := PackedVector3Array()
var up := PackedVector3Array()
var tangent := PackedVector3Array()
var right := PackedVector3Array()
var width := PackedFloat32Array()
var flags := PackedInt32Array()
var dist := PackedFloat32Array()
var length := 0.0
var closed := true


func build(points: Array, is_closed: bool) -> void:
	closed = is_closed
	var n := points.size()
	pos.resize(n); up.resize(n); tangent.resize(n); right.resize(n)
	width.resize(n); flags.resize(n); dist.resize(n)
	for i in n:
		var s: Dictionary = points[i]
		pos[i] = Vector3(s.p[0], s.p[1], s.p[2])
		var u: Array = s.get("up", [0, 1, 0])
		up[i] = Vector3(u[0], u[1], u[2]).normalized()
		width[i] = float(s.get("w", 10.0))
		flags[i] = int(s.get("f", 0))
	var acc := 0.0
	for i in n:
		dist[i] = acc
		var j := (i + 1) % n if closed else mini(i + 1, n - 1)
		acc += pos[i].distance_to(pos[j])
	length = acc
	for i in n:
		var a := (i - 1 + n) % n if closed else maxi(i - 1, 0)
		var b := (i + 1) % n if closed else mini(i + 1, n - 1)
		var t := (pos[b] - pos[a]).normalized()
		tangent[i] = t
		var r := t.cross(up[i])
		if r.length_squared() < 1e-6:
			r = right[a] if i > 0 else Vector3.RIGHT
		right[i] = r.normalized()
		up[i] = right[i].cross(t).normalized()


func size() -> int:
	return pos.size()


func wi(i: int) -> int:
	return posmod(i, pos.size()) if closed else clampi(i, 0, pos.size() - 1)


## Closest sample to `p`. Searches a window around `hint` first (cheap, and keeps a
## racer on the right part of the course where the track passes over itself), and
## only falls back to a full scan when that clearly misses.
func nearest(p: Vector3, hint: int = -1, window: int = 40) -> int:
	var n := pos.size()
	var best := 0
	var best_d := INF
	if hint >= 0:
		for k in range(-window, window + 1):
			var i := wi(hint + k)
			var d := pos[i].distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = i
		if best_d < 30.0 * 30.0:
			return best
	for i in n:
		var d := pos[i].distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = i
	return best


func lateral(i: int, p: Vector3) -> float:
	return (p - pos[i]).dot(right[i])


## Interpolated point `ahead` metres along the path from sample i.
func point_ahead(i: int, ahead: float) -> Vector3:
	var steps := ahead / 2.0
	var k := int(floor(steps))
	var f := steps - k
	return pos[wi(i + k)].lerp(pos[wi(i + k + 1)], f)


## Sample index at (or just before) distance `d` along the path.
func index_at_distance(d: float) -> int:
	d = fposmod(d, length) if closed else clampf(d, 0.0, length)
	return clampi(dist.bsearch(d, true) - 1, 0, pos.size() - 1) if d > 0.0 else 0


func index_ahead(i: int, ahead: float) -> int:
	return wi(i + int(round(ahead / 2.0)))
