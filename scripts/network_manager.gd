extends Node
## ENet 房间和玩家名单。服务器是玩家状态的唯一写入方。

signal player_joined(peer_id: int, player_name: String)
signal player_left(peer_id: int)
signal player_updated(peer_id: int)
signal server_started()
signal connection_failed(reason: String)
signal connection_succeeded()

const PORT: int = 7777
const MAX_PLAYERS: int = 24
const BOT_ID_START: int = 10000

var players: Dictionary = {}
var is_host: bool = false
var local_player_name: String = "Player"
var _next_bot_id := BOT_ID_START


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_multiplayer_signals()


func _connect_multiplayer_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func host_game(player_name: String) -> void:
	_clear_session()
	local_player_name = _sanitize_name(player_name)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS - 1)
	if err != OK:
		connection_failed.emit("创建房间失败: %d" % err)
		return

	multiplayer.multiplayer_peer = peer
	is_host = true
	_add_player_local(1, local_player_name)
	fill_empty_slots_with_bots()
	server_started.emit()


func join_game(address: String, player_name: String) -> void:
	_clear_session()
	local_player_name = _sanitize_name(player_name)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		connection_failed.emit("连接失败: %d" % err)
		return

	multiplayer.multiplayer_peer = peer


func _sanitize_name(value: String) -> String:
	var cleaned := value.strip_edges().substr(0, 20)
	return cleaned if not cleaned.is_empty() else "玩家"


func _on_peer_connected(_peer_id: int) -> void:
	pass


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server() or not players.has(peer_id):
		return
	rpc("_sync_remove_player", peer_id)
	fill_empty_slots_with_bots()


func _on_connected_to_server() -> void:
	rpc_id(1, "_register_player", local_player_name)
	connection_succeeded.emit()


func _on_connection_failed() -> void:
	_clear_session()
	connection_failed.emit("无法连接到服务器")


func _on_server_disconnected() -> void:
	_clear_session()
	connection_failed.emit("与服务器断开连接")


@rpc("any_peer", "reliable")
func _register_player(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 1 or players.has(peer_id):
		return

	_remove_one_bot()
	_add_player_local(peer_id, _sanitize_name(player_name), false)
	for pid: int in players:
		rpc_id(peer_id, "_sync_player", pid, players[pid])
	for pid: int in players:
		if pid != peer_id and pid != 1 and not bool(players[pid].get("is_bot", false)):
			rpc_id(pid, "_sync_player", peer_id, players[peer_id])
	GameManager.sync_state_to_peer(peer_id)


func _default_player_info(player_name: String, is_bot: bool = false) -> Dictionary:
	return {
		"name": player_name,
		"is_bot": is_bot,
		"is_zombie": false,
		"alive": true,
		"health": 100.0,
		"max_health": 100.0,
	}


func _add_player_local(peer_id: int, player_name: String, is_bot: bool = false) -> void:
	var is_new := not players.has(peer_id)
	players[peer_id] = _default_player_info(player_name, is_bot)
	if is_new:
		player_joined.emit(peer_id, player_name)
	else:
		player_updated.emit(peer_id)


func fill_empty_slots_with_bots() -> void:
	if not multiplayer.is_server():
		return
	while players.size() < MAX_PLAYERS:
		var bot_id := _next_bot_id
		_next_bot_id += 1
		var bot_number := bot_id - BOT_ID_START + 1
		_add_player_local(bot_id, "AI-%02d" % bot_number, true)
		if multiplayer.get_peers().size() > 0:
			rpc("_sync_player", bot_id, players[bot_id])


func _remove_one_bot() -> void:
	var bot_ids: Array[int] = []
	for pid: int in players:
		if bool(players[pid].get("is_bot", false)):
			bot_ids.append(pid)
	if bot_ids.is_empty():
		return
	bot_ids.sort()
	rpc("_sync_remove_player", bot_ids.back())


@rpc("authority", "reliable")
func _sync_player(peer_id: int, info: Dictionary) -> void:
	var is_new := not players.has(peer_id)
	players[peer_id] = info.duplicate(true)
	if is_new:
		player_joined.emit(peer_id, str(info.get("name", "玩家")))
	else:
		player_updated.emit(peer_id)


@rpc("authority", "call_local", "reliable")
func _sync_remove_player(peer_id: int) -> void:
	if players.erase(peer_id):
		player_left.emit(peer_id)


func update_player_info(peer_id: int, info: Dictionary) -> void:
	if multiplayer.is_server() and players.has(peer_id):
		rpc("_sync_player_info", peer_id, info)


@rpc("authority", "call_local", "reliable")
func _sync_player_info(peer_id: int, info: Dictionary) -> void:
	if not players.has(peer_id):
		return
	players[peer_id] = info.duplicate(true)
	player_updated.emit(peer_id)


func get_alive_humans_count() -> int:
	var count := 0
	for info: Dictionary in players.values():
		if not info.get("is_zombie", false) and info.get("alive", true):
			count += 1
	return count


func get_zombie_count() -> int:
	var count := 0
	for info: Dictionary in players.values():
		if info.get("is_zombie", false) and info.get("alive", true):
			count += 1
	return count


func all_are_zombies() -> bool:
	return not players.is_empty() and get_alive_humans_count() == 0


func leave_game() -> void:
	_clear_session()


func _clear_session() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	players.clear()
	is_host = false
	_next_bot_id = BOT_ID_START
