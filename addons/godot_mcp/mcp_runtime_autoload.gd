extends Node

const PREFIX := "mcp_runtime"
const PREFIX_COLON := "mcp_runtime:"
const MAX_NODE_RESULTS := 200

func _ready() -> void:
	if not EngineDebugger.is_active():
		return
	EngineDebugger.register_message_capture(PREFIX, Callable(self, "_on_message"))

func _exit_tree() -> void:
	if EngineDebugger.is_active():
		EngineDebugger.unregister_message_capture(PREFIX)

func _on_message(message: String, data: Array) -> bool:
	if not message.begins_with(PREFIX_COLON):
		return false

	var suffix := message.substr(PREFIX_COLON.length())
	var request_id := str(data[0]) if data.size() > 0 else ""

	match suffix:
		"ping":
			_reply(request_id, true, "pong")
			return true
		"eval":
			var expr := str(data[1]) if data.size() > 1 else ""
			_handle_eval(request_id, expr, 2000)
			return true
		"eval_timed":
			var expr_timed := str(data[1]) if data.size() > 1 else ""
			var timeout_ms := int(data[2]) if data.size() > 2 else 2000
			_handle_eval(request_id, expr_timed, timeout_ms)
			return true
		"inspect":
			var node_path := str(data[1]) if data.size() > 1 else ""
			var property := str(data[2]) if data.size() > 2 else ""
			_handle_inspect(request_id, node_path, property)
			return true
		"call_method":
			var call_node_path := str(data[1]) if data.size() > 1 else ""
			var method := str(data[2]) if data.size() > 2 else ""
			var args_json := str(data[3]) if data.size() > 3 else "[]"
			_handle_call_method(request_id, call_node_path, method, args_json)
			return true
		"find_nodes":
			var type_filter := str(data[1]) if data.size() > 1 else ""
			var group_filter := str(data[2]) if data.size() > 2 else ""
			var name_contains := str(data[3]) if data.size() > 3 else ""
			_handle_find_nodes(request_id, type_filter, group_filter, name_contains)
			return true
	return false

func _handle_eval(request_id: String, expr: String, timeout_ms: int) -> void:
	if expr.is_empty():
		_reply(request_id, false, "expr is empty")
		return

	var blocked := [
		"FileAccess",
		"DirAccess",
		"OS.execute",
		"OS.create_process",
		"JavaScriptBridge",
		"Thread",
	]
	for item in blocked:
		if expr.find(item) != -1:
			_reply(request_id, false, "Blocked API in expr: %s" % item)
			return

	var sandbox_script = load("res://addons/godot_mcp/mcp_runtime_sandbox.gd")
	if sandbox_script == null:
		_reply(request_id, false, "mcp_runtime_sandbox.gd not found")
		return

	var tree := get_tree()
	if tree == null or tree.root == null:
		_reply(request_id, false, "SceneTree root is not available")
		return

	var instance = sandbox_script.new()
	tree.root.add_child(instance)
	var result: Dictionary = instance.eval_expr(expr, tree.root, timeout_ms)
	instance.queue_free()

	if result.has("error"):
		_reply(request_id, false, str(result.get("error", "Unknown eval error")))
		return
	_reply(request_id, true, result.get("value", null))

func _handle_inspect(request_id: String, node_path: String, property: String) -> void:
	var tree := get_tree()
	if tree == null or tree.root == null:
		_reply(request_id, false, "SceneTree root is not available")
		return
	var node := tree.root.get_node_or_null(node_path)
	if node == null:
		_reply(request_id, false, "Node not found: %s" % node_path)
		return
	if not _node_has_property(node, property):
		_reply(request_id, false, "Property not found: %s" % property)
		return
	_reply(request_id, true, _serialize(node.get(property)))

func _handle_call_method(request_id: String, node_path: String, method: String, args_json: String) -> void:
	var tree := get_tree()
	if tree == null or tree.root == null:
		_reply(request_id, false, "SceneTree root is not available")
		return
	var node := tree.root.get_node_or_null(node_path)
	if node == null:
		_reply(request_id, false, "Node not found: %s" % node_path)
		return
	if not node.has_method(method):
		_reply(request_id, false, "Method not found: %s" % method)
		return

	var args = JSON.parse_string(args_json)
	if typeof(args) != TYPE_ARRAY:
		args = []
	var result = node.callv(method, args)
	_reply(request_id, true, _serialize(result))

func _handle_find_nodes(request_id: String, type_filter: String, group_filter: String, name_contains: String) -> void:
	var tree := get_tree()
	if tree == null or tree.root == null:
		_reply(request_id, false, "SceneTree root is not available")
		return
	var items: Array = []
	_collect_nodes(tree.root, type_filter, group_filter, name_contains.to_lower(), items)
	_reply(request_id, true, items)

func _collect_nodes(node: Node, type_filter: String, group_filter: String, name_lc: String, out: Array) -> void:
	var matches := true
	if type_filter != "" and not node.is_class(type_filter):
		matches = false
	if group_filter != "" and not node.is_in_group(group_filter):
		matches = false
	if name_lc != "" and not str(node.name).to_lower().contains(name_lc):
		matches = false

	if matches:
		out.append({
			"name": str(node.name),
			"path": str(node.get_path()),
			"class": node.get_class(),
			"groups": Array(node.get_groups()),
		})
		if out.size() >= MAX_NODE_RESULTS:
			return

	for child in node.get_children():
		if out.size() >= MAX_NODE_RESULTS:
			break
		if child is Node:
			_collect_nodes(child, type_filter, group_filter, name_lc, out)

func _node_has_property(node: Object, property_name: String) -> bool:
	if property_name == "":
		return false
	for item in node.get_property_list():
		if typeof(item) == TYPE_DICTIONARY and str(item.get("name", "")) == property_name:
			return true
	return false

func _reply(request_id: String, ok: bool, value: Variant) -> void:
	EngineDebugger.send_message(PREFIX_COLON + "result", [request_id, ok, value])

func _serialize(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2:
			return [value.x, value.y]
		TYPE_VECTOR3:
			return [value.x, value.y, value.z]
		TYPE_COLOR:
			return [value.r, value.g, value.b, value.a]
		TYPE_RECT2:
			return {
				"position": [value.position.x, value.position.y],
				"size": [value.size.x, value.size.y],
			}
		TYPE_TRANSFORM2D, TYPE_TRANSFORM3D:
			return str(value)
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Node:
				return str(value.get_path())
			return str(value)
		TYPE_ARRAY:
			var out: Array = []
			for item in value:
				out.append(_serialize(item))
			return out
		TYPE_DICTIONARY:
			var out_dict: Dictionary = {}
			for key in value:
				out_dict[str(key)] = _serialize(value[key])
			return out_dict
		_:
			return value
