@tool
extends RefCounted

const MAX_LOG_ITEMS := 200

var server_started_at_unix: int = Time.get_unix_time_from_system()
var last_method: String = ""
var last_error: Dictionary = {}
var last_warning: Dictionary = {}
var auto_capture_enabled := false
var auto_capture_mode := "game"
var auto_capture_format := "png"
var auto_capture_include_base64 := false
var auto_capture_max_base64_bytes := 0

var _errors: Array[Dictionary] = []
var _warnings: Array[Dictionary] = []
var _runtime_error_baselines: Dictionary = {}

func record_error(message: String, data: Dictionary = {}) -> void:
	var item := {
		"timestamp": Time.get_datetime_string_from_system(),
		"message": message,
		"data": data,
	}
	_errors.append(item)
	last_error = item
	if _errors.size() > MAX_LOG_ITEMS:
		_errors.pop_front()

func record_warning(message: String, data: Dictionary = {}) -> void:
	var item := {
		"timestamp": Time.get_datetime_string_from_system(),
		"message": message,
		"data": data,
	}
	_warnings.append(item)
	last_warning = item
	if _warnings.size() > MAX_LOG_ITEMS:
		_warnings.pop_front()

func get_errors(limit: int = 50) -> Array[Dictionary]:
	if limit <= 0:
		return []
	var start := maxi(0, _errors.size() - limit)
	return _errors.slice(start, _errors.size())

func get_warnings(limit: int = 50) -> Array[Dictionary]:
	if limit <= 0:
		return []
	var start := maxi(0, _warnings.size() - limit)
	return _warnings.slice(start, _warnings.size())

func set_last_method(method: String) -> void:
	last_method = method

func get_auto_capture_settings() -> Dictionary:
	return {
		"enabled": auto_capture_enabled,
		"mode": auto_capture_mode,
		"format": auto_capture_format,
		"include_base64": auto_capture_include_base64,
		"max_base64_bytes": auto_capture_max_base64_bytes,
	}

func update_auto_capture_settings(patch: Dictionary) -> Dictionary:
	if patch.has("enabled"):
		auto_capture_enabled = bool(patch.get("enabled", false))
	if patch.has("mode"):
		auto_capture_mode = str(patch.get("mode", "game"))
	if patch.has("format"):
		auto_capture_format = str(patch.get("format", "png"))
	if patch.has("include_base64"):
		auto_capture_include_base64 = bool(patch.get("include_base64", false))
	if patch.has("max_base64_bytes"):
		auto_capture_max_base64_bytes = maxi(0, int(patch.get("max_base64_bytes", 0)))
	return get_auto_capture_settings()

func get_runtime_error_baseline(name: String = "default") -> Dictionary:
	var key = name.strip_edges()
	if key == "":
		key = "default"
	var item = _runtime_error_baselines.get(key, {})
	if typeof(item) == TYPE_DICTIONARY:
		return item.duplicate(true)
	return {}

func set_runtime_error_baseline(name: String, summary: Dictionary) -> void:
	var key = name.strip_edges()
	if key == "":
		key = "default"
	_runtime_error_baselines[key] = summary.duplicate(true)

func snapshot() -> Dictionary:
	return {
		"server_started_at_unix": server_started_at_unix,
		"uptime_seconds": Time.get_unix_time_from_system() - server_started_at_unix,
		"last_method": last_method,
		"last_error": last_error,
		"last_warning": last_warning,
		"error_count": _errors.size(),
		"warning_count": _warnings.size(),
		"auto_capture": get_auto_capture_settings(),
		"runtime_error_baselines": _runtime_error_baselines.size(),
	}
