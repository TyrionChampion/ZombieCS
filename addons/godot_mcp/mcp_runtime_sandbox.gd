extends Node

func eval_expr(expr: String, scene_root: Node, timeout_ms: int = 2000) -> Dictionary:
	var source := """extends Node

var root: Node

func _mcp_run() -> Variant:
	return %s
""" % expr

	var script := GDScript.new()
	script.source_code = source
	var compile_err := script.reload()
	if compile_err != OK:
		return {"error": "GDScript parse error (code %d)" % compile_err}

	var instance = script.new()
	if instance == null:
		return {"error": "Failed to instantiate eval script"}

	instance.set("root", scene_root)
	add_child(instance)

	var started_ms := Time.get_ticks_msec()
	var result: Variant = instance._mcp_run()
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	instance.queue_free()

	if timeout_ms > 0 and elapsed_ms > timeout_ms:
		return {"error": "Expression timed out (%d ms)" % timeout_ms}
	return {"value": _to_json_safe(result)}

func _to_json_safe(v: Variant) -> Variant:
	match typeof(v):
		TYPE_VECTOR2:
			return [v.x, v.y]
		TYPE_VECTOR3:
			return [v.x, v.y, v.z]
		TYPE_COLOR:
			return [v.r, v.g, v.b, v.a]
		TYPE_RECT2:
			return {
				"position": [v.position.x, v.position.y],
				"size": [v.size.x, v.size.y],
			}
		TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_QUATERNION:
			return str(v)
		TYPE_OBJECT:
			if v == null:
				return null
			if v is Node:
				return str(v.get_path())
			return str(v)
		TYPE_ARRAY:
			var out: Array = []
			for item in v:
				out.append(_to_json_safe(item))
			return out
		TYPE_DICTIONARY:
			var out: Dictionary = {}
			for key in v:
				out[str(key)] = _to_json_safe(v[key])
			return out
		_:
			return v
