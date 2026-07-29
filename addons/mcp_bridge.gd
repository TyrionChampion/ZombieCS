@tool
extends EditorPlugin

const PORT := 49631
const HOST := "127.0.0.1"

const MCPGuardClass = preload("res://addons/godot_mcp/mcp_guard.gd")
const MCPStateClass = preload("res://addons/godot_mcp/mcp_state.gd")
const MCPRouterPath := "res://addons/godot_mcp/mcp_router.gd"
const RUNTIME_AUTOLOAD_NAME := "McpRuntimeAutoload"
const RUNTIME_AUTOLOAD_PATH := "res://addons/godot_mcp/mcp_runtime_autoload.gd"

var _tcp := TCPServer.new()
var _peers: Dictionary = {}
var _next_peer_id := 1
var _reload_scheduled := false

var _guard
var _state
var _router
var _debugger_plugin

func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		return

	_guard = MCPGuardClass.new()
	_state = MCPStateClass.new()
	var router_script = load(MCPRouterPath)
	if router_script == null:
		push_error("Godot MCP: Failed to load router script: %s" % MCPRouterPath)
		return
	_router = router_script.new(self, _guard, _state)
	var debugger_script = load("res://addons/godot_mcp/mcp_debugger_plugin.gd")
	if debugger_script != null:
		_debugger_plugin = debugger_script.new()
		add_debugger_plugin(_debugger_plugin)
		if _router != null and _router.has_method("set_debugger_plugin"):
			_router.set_debugger_plugin(_debugger_plugin)

	_register_runtime_autoload()

	var err := _tcp.listen(PORT, HOST)
	if err != OK:
		push_error("Godot MCP: Failed to listen on ws://%s:%d (error=%d)" % [HOST, PORT, err])
		return

	set_process(true)
	print("Godot MCP: Bridge listening on ws://%s:%d" % [HOST, PORT])

func _exit_tree() -> void:
	if _debugger_plugin != null:
		remove_debugger_plugin(_debugger_plugin)
		_debugger_plugin = null
	_unregister_runtime_autoload()
	for id in _peers.keys():
		var ws: WebSocketPeer = _peers[id]
		if ws != null:
			ws.close()
	_peers.clear()
	if _tcp.is_listening():
		_tcp.stop()
	print("Godot MCP: Bridge stopped")

func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return

	_accept_pending_connections()
	_poll_peers()

func request_project_reload() -> Dictionary:
	if _reload_scheduled:
		return {"scheduled": true, "already_scheduled": true}

	_reload_scheduled = true
	call_deferred("_perform_project_reload")
	return {"scheduled": true}

func _perform_project_reload() -> void:
	_reload_scheduled = false
	var iface := get_editor_interface()
	if iface != null and iface.has_method("restart_editor"):
		iface.call("restart_editor", true)
		return

	var exec_path := OS.get_executable_path()
	if exec_path != "":
		var args: PackedStringArray = ["--path", ProjectSettings.globalize_path("res://"), "--editor"]
		OS.create_process(exec_path, args, false)

	var tree := get_tree()
	if tree != null:
		tree.quit()

func _register_runtime_autoload() -> void:
	var key := "autoload/%s" % RUNTIME_AUTOLOAD_NAME
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, "*" + RUNTIME_AUTOLOAD_PATH)
		ProjectSettings.save()

func _unregister_runtime_autoload() -> void:
	var key := "autoload/%s" % RUNTIME_AUTOLOAD_NAME
	if ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, "")
		ProjectSettings.save()

func _accept_pending_connections() -> void:
	while _tcp.is_connection_available():
		var conn := _tcp.take_connection()
		var ws := WebSocketPeer.new()
		var err := ws.accept_stream(conn)
		if err != OK:
			_state.record_error("Failed to accept MCP client stream", {"error": err})
			continue
		_peers[_next_peer_id] = ws
		_next_peer_id += 1
		print("Godot MCP: MCP client connected")

func _poll_peers() -> void:
	for id in _peers.keys().duplicate():
		var ws: WebSocketPeer = _peers[id]
		if ws == null:
			_peers.erase(id)
			continue

		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_peers.erase(id)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue

		while ws.get_available_packet_count() > 0:
			var msg := ws.get_packet().get_string_from_utf8()
			var req := JSON.parse_string(msg)
			var response = _router.handle_jsonrpc(req)
			if response != null:
				ws.send_text(JSON.stringify(response))
