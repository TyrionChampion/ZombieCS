@tool
extends EditorDebuggerPlugin

const PREFIX := "mcp_runtime"
const PREFIX_COLON := "mcp_runtime:"

var _pending: Dictionary = {}
var _session_id: int = -1

func _has_capture(prefix: String) -> bool:
	return prefix == PREFIX

func _capture(message: String, data: Array, _session_id_from_capture: int) -> bool:
	if not message.begins_with(PREFIX_COLON):
		return false
	var suffix := message.substr(PREFIX_COLON.length())
	if suffix == "result" and data.size() >= 3:
		_pending[str(data[0])] = {
			"ok": bool(data[1]),
			"value": data[2],
		}
	return true

func _setup_session(session_id: int) -> void:
	_session_id = session_id

func send_command(command: String, request_id: String, args: Array) -> bool:
	if _session_id < 0:
		return false
	var session := get_session(_session_id)
	if session == null:
		return false
	session.send_message(PREFIX_COLON + command, [request_id] + args)
	return true

func poll_result(request_id: String) -> Variant:
	if not _pending.has(request_id):
		return null
	var result: Variant = _pending[request_id]
	_pending.erase(request_id)
	return result

func is_game_connected() -> bool:
	return _session_id >= 0 and get_session(_session_id) != null
