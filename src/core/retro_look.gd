@tool
class_name RetroLook
extends RefCounted
## Console "looks": internal resolution, texture filtering, colour depth, dither and
## fog. Presets are data in res://content/looks/*.json, so a new look is one file:
##
##   {"id": "saturn", "name": "Sega Saturn", "resolution": [400, 225],
##    "filter": "nearest", "bits": [5, 5, 5], "dither": 0.0, "scanlines": 0.0,
##    "fog_scale": 0.8, "saturation": 1.05, "mesh_transparency": true}
##
## "classic" (the original 640x360 N64/PS1 look) is built in and is what the editor
## tools use, so authoring views never change.
##
## Materials read the look when they are built (Track, TrackProps, VertexRig), so the
## race applies the preset before it loads the course and racers.

const DIR := "res://content/looks/"
const POST_SHADER := preload("res://src/core/retro_post.gdshader")
const RIG_SHADER := preload("res://src/rig/rig_paint.gdshader")

const CLASSIC := {
	"id": "classic", "name": "Classic (N64 / PS1)", "resolution": [640, 360],
	"filter": "nearest", "bits": [8, 8, 8], "dither": 0.0, "scanlines": 0.0,
	"fog_scale": 1.0, "saturation": 1.0, "mesh_transparency": false,
}

static var current: Dictionary = CLASSIC
static var _looks := {}
static var _rig_linear: Shader


static func looks() -> Dictionary:
	if _looks.is_empty():
		_looks = {"classic": CLASSIC}
		var d := DirAccess.open(DIR)
		if d != null:
			var files := Array(d.get_files())
			files.sort()
			for fn in files:
				if not String(fn).ends_with(".json"):
					continue
				var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIR + String(fn)))
				if parsed is Dictionary:
					var lk: Dictionary = CLASSIC.duplicate(true)
					lk.merge(parsed, true)
					lk["id"] = String(parsed.get("id", String(fn).get_basename()))
					_looks[lk.id] = lk
	return _looks


static func set_look(id: String) -> void:
	current = looks().get(id, CLASSIC)


static func linear() -> bool:
	return String(current.get("filter", "nearest")) == "linear"


## Texture filter for StandardMaterial3D course / prop materials.
static func base_filter() -> int:
	return BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS if linear() else BaseMaterial3D.TEXTURE_FILTER_NEAREST


## Shader for vertex-rig materials: the original (nearest) or a bilinear copy.
static func rig_shader() -> Shader:
	if not linear():
		return RIG_SHADER
	if _rig_linear == null:
		_rig_linear = Shader.new()
		_rig_linear.code = RIG_SHADER.code.replace("filter_nearest", "filter_linear_mipmap")
	return _rig_linear


static func fog_scale() -> float:
	return float(current.get("fog_scale", 1.0))


## Applies the resolution and adds the colour-depth / dither pass to `root`.
## Call once per scene (race, menu). `resolution` overrides the look's own (the menu
## keeps its 640x360 layout and only takes the colour pass).
static func apply(root: Node, resolution: Vector2i = Vector2i.ZERO) -> void:
	if root == null or not root.is_inside_tree():
		return
	var old := root.get_node_or_null("RetroPost")
	if old != null:
		root.remove_child(old)
		old.queue_free()
	var win := root.get_window()
	var res: Array = current.get("resolution", [640, 360])
	if resolution != Vector2i.ZERO:
		res = [resolution.x, resolution.y]
	if win != null and res.size() >= 2:
		win.content_scale_size = Vector2i(int(res[0]), int(res[1]))
	var bits: Array = current.get("bits", [8, 8, 8])
	var needs_post := float(current.get("dither", 0.0)) > 0.0 or float(current.get("scanlines", 0.0)) > 0.0 \
		or absf(float(current.get("saturation", 1.0)) - 1.0) > 0.001
	for bv in bits:
		if int(bv) < 8:
			needs_post = true
	if not needs_post:
		return
	var layer := CanvasLayer.new()
	layer.name = "RetroPost"
	layer.layer = 90
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = POST_SHADER
	m.set_shader_parameter("levels", Vector3(pow(2.0, float(bits[0])) - 1.0,
		pow(2.0, float(bits[1])) - 1.0, pow(2.0, float(bits[2])) - 1.0))
	m.set_shader_parameter("dither", float(current.get("dither", 0.0)))
	m.set_shader_parameter("scanlines", float(current.get("scanlines", 0.0)))
	m.set_shader_parameter("saturation", float(current.get("saturation", 1.0)))
	rect.material = m
	layer.add_child(rect)
	root.add_child(layer)
