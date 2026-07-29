extends Node
## Launch two copies with `-- --role=server` and `-- --role=client`.

var failures: Array[String] = []


func _ready() -> void:
	var role := _read_role()
	if role == "server":
		await _run_server()
	elif role == "client":
		await _run_client()
	else:
		push_error("Missing --role argument")
		get_tree().quit(2)


func _run_server() -> void:
	NetworkManager.host_game("Server")
	var joined := await _wait_until(
		func() -> bool:
			return NetworkManager.players.size() == NetworkManager.MAX_PLAYERS and _real_player_count() == 2,
		8.0
	)
	_check(joined, "Server did not receive the client registration")
	if joined:
		GameManager.start_game()
		GameManager.countdown_timer = 0.05
		_check(await _wait_until(func() -> bool: return GameManager.state == GameManager.GameState.PLAYING, 2.0), "Server did not enter PLAYING")
		await _instantiate_world_and_validate("SERVER")
	await get_tree().create_timer(0.5).timeout
	_finish("SERVER")


func _run_client() -> void:
	NetworkManager.join_game("127.0.0.1", "Client")
	var ready := await _wait_until(
		func() -> bool:
			return NetworkManager.players.size() == NetworkManager.MAX_PLAYERS \
				and _real_player_count() == 2 \
				and GameManager.state == GameManager.GameState.PLAYING,
		8.0
	)
	_check(ready, "Client did not receive players and PLAYING state")
	if ready:
		await _instantiate_world_and_validate("CLIENT")
	_finish("CLIENT")


func _instantiate_world_and_validate(label: String) -> void:
	var world: Node = load("res://scenes/game.tscn").instantiate()
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	var my_id := multiplayer.get_unique_id()
	_check(int(world.get("current_map_seed")) == GameManager.map_seed, "%s map seed is not synchronized" % label)
	_check(not str(world.call("get_layout_signature")).is_empty(), "%s procedural layout is missing" % label)
	_check(world.get_node_or_null("1") != null, "%s is missing host node" % label)
	_check(world.get_node_or_null(str(my_id)) != null, "%s is missing local node" % label)
	var local: Node = world.get_node_or_null(str(my_id))
	if local != null:
		_check(local.get_multiplayer_authority() == my_id, "%s local authority is incorrect" % label)


func _wait_until(predicate: Callable, timeout: float) -> bool:
	var elapsed := 0.0
	while elapsed < timeout:
		if predicate.call():
			return true
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05
	return false


func _read_role() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			return argument.trim_prefix("--role=")
	return ""


func _real_player_count() -> int:
	var count := 0
	for info: Dictionary in NetworkManager.players.values():
		if not bool(info.get("is_bot", false)):
			count += 1
	return count


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish(label: String) -> void:
	NetworkManager.leave_game()
	if failures.is_empty():
		print("%s_MULTIPLAYER_OK" % label)
		get_tree().quit(0)
	else:
		for message in failures:
			push_error(message)
		get_tree().quit(1)
