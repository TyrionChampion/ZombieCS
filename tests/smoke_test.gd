extends Node
## Headless regression smoke test: host -> countdown -> game -> player/HUD/weapon state.

var failures: Array[String] = []


func _ready() -> void:
	NetworkManager.host_game("SmokeTest")
	_check(multiplayer.multiplayer_peer != null, "ENet server was not created")
	_check(NetworkManager.players.has(1), "Host player was not registered")
	_check(NetworkManager.players.size() == NetworkManager.MAX_PLAYERS, "Bots did not fill the room")

	GameManager.start_game()
	_check(GameManager.state == GameManager.GameState.COUNTDOWN, "Round did not enter countdown")
	GameManager.countdown_timer = 0.01
	await get_tree().create_timer(0.1).timeout
	_check(GameManager.state == GameManager.GameState.PLAYING, "Round did not enter playing")

	var world: Node = load("res://scenes/game.tscn").instantiate()
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(world != null and world.name == "Game", "Game scene did not instantiate")
	if world != null:
		_check(int(world.get("current_map_seed")) == GameManager.map_seed, "World did not use the round map seed")
		world.call("regenerate_map", 424242)
		var seeded_signature := str(world.call("get_layout_signature"))
		world.call("regenerate_map", 424242)
		_check(str(world.call("get_layout_signature")) == seeded_signature, "Same seed produced a different layout")
		world.call("regenerate_map", 424243)
		_check(str(world.call("get_layout_signature")) != seeded_signature, "Different seeds produced the same layout")
		var player := world.get_node_or_null("1")
		_check(player != null, "Local player was not spawned")
		_check(world.has_node("CanvasLayer/HUD/AmmoLabel"), "Ammo HUD is missing")
		_check(world.get_tree().get_nodes_in_group("players").size() == NetworkManager.MAX_PLAYERS, "Bot player nodes were not spawned")
		var region := world.get_node("NavigationRegion3D") as NavigationRegion3D
		_check(region.navigation_mesh.get_polygon_count() > 0, "Procedural navigation mesh was not generated")
		var bot_positions: Dictionary = {}
		for node: Node in world.get_tree().get_nodes_in_group("players"):
			if bool(node.get("is_bot")):
				bot_positions[int(node.get("peer_id"))] = node.global_position
		if player != null:
			_check(player.get_multiplayer_authority() == 1, "Player authority is incorrect")
			var weapons := player.get_node("Head/WeaponSystem")
			_check(int(weapons.call("get_current_ammo")) == 12, "Initial pistol ammo is incorrect")
			weapons.call("shoot")
			weapons.call("switch_weapon", 1)
			weapons.call("switch_weapon", 0)
			_check(int(weapons.call("get_current_ammo")) == 11, "Switching weapons refilled ammo")
		await get_tree().create_timer(1.5).timeout
		var moved_bot := false
		for node: Node in world.get_tree().get_nodes_in_group("players"):
			var bot_id := int(node.get("peer_id"))
			if bool(node.get("is_bot")) and bot_positions.has(bot_id):
				if node.global_position.distance_to(bot_positions[bot_id]) > 0.25:
					moved_bot = true
					break
		_check(moved_bot, "AI players did not move")

	NetworkManager.leave_game()
	if failures.is_empty():
		print("SMOKE_TEST_OK")
		get_tree().quit(0)
	else:
		for message in failures:
			push_error(message)
		get_tree().quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
