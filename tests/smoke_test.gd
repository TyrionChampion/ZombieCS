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
		var ground := world.get_node("Ground") as CSGBox3D
		_check(ground.size.x >= 120.0 and ground.size.z >= 120.0, "Map footprint was not expanded")
		_check((world.get("current_module_ids") as Array).size() == 25, "Expanded procedural module grid is incomplete")
		world.call("regenerate_map", 424242)
		var seeded_signature := str(world.call("get_layout_signature"))
		world.call("regenerate_map", 424242)
		_check(str(world.call("get_layout_signature")) == seeded_signature, "Same seed produced a different layout")
		world.call("regenerate_map", 424243)
		_check(str(world.call("get_layout_signature")) != seeded_signature, "Different seeds produced the same layout")
		var player := world.get_node_or_null("1")
		_check(player != null, "Local player was not spawned")
		_check(world.has_node("CanvasLayer/HUD/AmmoLabel"), "Ammo HUD is missing")
		_check(world.has_node("CanvasLayer/HUD/KillFeedMargin/KillFeed"), "Infection kill feed is missing")
		_check(world.has_node("CanvasLayer/HUD/DamageIndicator"), "Zombie damage direction indicator is missing")
		world.call("_on_countdown", 5)
		var announcer := world.get_node("CountdownAnnouncer") as AudioStreamPlayer
		var reveal_sound := world.get_node("ZombieRevealSound") as AudioStreamPlayer
		_check(announcer.stream != null, "Countdown announcement audio is missing")
		_check(reveal_sound.stream != null, "Zombie reveal audio is missing")
		world.call("_add_kill_feed_entry", "Zombie", "Human")
		await get_tree().process_frame
		var feed := world.get_node("CanvasLayer/HUD/KillFeedMargin/KillFeed")
		_check(feed.get_child_count() == 1, "Infection kill feed entry was not created")
		_check(world.get_tree().get_nodes_in_group("players").size() == NetworkManager.MAX_PLAYERS, "Bot player nodes were not spawned")
		var initial_zombie_count := 0
		var visible_zombie_count := 0
		for node: Node in world.get_tree().get_nodes_in_group("players"):
			if bool(node.get("is_zombie")):
				initial_zombie_count += 1
				if bool(node.get("is_alive")) and node.visible and node.get_node("ZombieModel").visible:
					visible_zombie_count += 1
		_check(initial_zombie_count >= 3, "Expanded room did not select enough initial zombies")
		_check(visible_zombie_count >= 3, "Initial zombies are dead or invisible")
		var region := world.get_node("NavigationRegion3D") as NavigationRegion3D
		_check(region.navigation_mesh.get_polygon_count() > 0, "Procedural navigation mesh was not generated")
		await get_tree().create_timer(1.0).timeout
		if player != null:
			var player_collider := player.get_node("CollisionShape3D") as CollisionShape3D
			var capsule := player_collider.shape as CapsuleShape3D
			_check(
				absf(player_collider.position.y - capsule.height * 0.5) < 0.01,
				"Character collision capsule is not aligned with the feet"
			)
			_check(absf(player.global_position.y) < 0.15, "Character model is floating above the ground")
		var bot_positions: Dictionary = {}
		for node: Node in world.get_tree().get_nodes_in_group("players"):
			if bool(node.get("is_bot")):
				bot_positions[int(node.get("peer_id"))] = Vector2(node.global_position.x, node.global_position.z)
		if player != null:
			_check(player.has_node("HumanModel"), "Human character model is missing")
			_check(player.has_node("ZombieModel"), "Zombie character model is missing")
			_check(player.collision_layer == 2 and player.collision_mask == 1, "Players still physically collide with each other")
			_check((player.get_node("Head/AttackRay") as RayCast3D).collision_mask == 3, "Zombie attacks cannot detect player layer")
			_check(
				not player.get_node("HumanModel").find_children("*", "AnimationPlayer", true, false).is_empty(),
				"Human character animations are missing"
			)
			_check(
				not player.get_node("ZombieModel").find_children("*", "AnimationPlayer", true, false).is_empty(),
				"Zombie character animations are missing"
			)
			_check(player.get_multiplayer_authority() == 1, "Player authority is incorrect")
			var weapons := player.get_node("Head/WeaponSystem")
			_check(str(weapons.call("get_current_weapon_name")) == "AK-47", "AK-47 is not the default weapon")
			_check(bool((weapons.call("get_current_weapon") as WeaponData).is_automatic), "AK-47 is not automatic")
			_check(int(weapons.call("get_current_ammo")) == 30, "Initial AK-47 ammo is incorrect")
			var player_head := player.get_node("Head") as Node3D
			player_head.rotation.x = 0.0
			weapons.call("shoot")
			_check(player_head.rotation.x > 0.0, "Weapon recoil pushes the crosshair downward")
			var fire_sound := weapons.get_node("FireSound") as AudioStreamPlayer3D
			_check(fire_sound.stream != null and fire_sound.stream.get_length() >= 0.15, "Gunshot audio is missing or inaudible")
			_check(fire_sound.playing, "Human gunshot audio did not play")
			weapons.call("switch_weapon", 1)
			weapons.call("switch_weapon", 0)
			_check(int(weapons.call("get_current_ammo")) == 29, "Switching weapons refilled AK-47 ammo")
		await get_tree().create_timer(1.5).timeout
		var moved_bot := false
		var bot_vertical_aim_checked := false
		for node: Node in world.get_tree().get_nodes_in_group("players"):
			var bot_id := int(node.get("peer_id"))
			if bool(node.get("is_bot")) and bot_positions.has(bot_id):
				if not bot_vertical_aim_checked:
					var bot_head := node.get_node("Head") as Node3D
					bot_head.rotation.x = 0.0
					node.get_node("BotController").call("_aim_at", node.global_position + Vector3(0.0, 5.0, -10.0))
					_check(bot_head.rotation.x > 0.0, "Bot vertical aim direction is inverted")
					bot_vertical_aim_checked = true
				var current_xz := Vector2(node.global_position.x, node.global_position.z)
				if current_xz.distance_to(bot_positions[bot_id]) > 0.25:
					moved_bot = true
					break
		_check(moved_bot, "AI players did not move")
		var zombie_bot: CharacterBody3D
		for node: Node in world.get_tree().get_nodes_in_group("players"):
			if bool(node.get("is_bot")) and bool(node.get("is_zombie")):
				zombie_bot = node as CharacterBody3D
				break
		_check(zombie_bot != null, "No zombie bot was selected")
		if zombie_bot != null and player != null:
			zombie_bot.velocity = Vector3(0.0, 0.0, -float(zombie_bot.get("zombie_speed")))
			zombie_bot.call(
				"_on_player_health_changed",
				int(zombie_bot.get("peer_id")),
				float(zombie_bot.get("health")) - 1.0,
				float(zombie_bot.get("max_health")),
				zombie_bot.global_position + Vector3(0.0, 0.0, -5.0),
				4.5
			)
			zombie_bot.call("apply_pending_knockback", 0.016)
			_check(zombie_bot.velocity.z > 0.0, "Zombie chase velocity overrides weapon knockback")
			zombie_bot.global_position = Vector3(48.0, 0.9, 48.0)
			zombie_bot.velocity = Vector3.ZERO
			player.global_position = Vector3(49.5, 0.9, 48.0)
			player.velocity = Vector3.ZERO
			await get_tree().create_timer(1.0).timeout
			for turn_step in range(10):
				zombie_bot.get_node("BotController").call("_aim_at", player.global_position + Vector3.UP)
			var visual_forward: Vector3 = zombie_bot.get_node("ZombieModel").global_basis.z.normalized()
			var target_direction: Vector3 = (player.global_position - zombie_bot.global_position).normalized()
			_check(visual_forward.dot(target_direction) > 0.5, "Zombie model is facing away from its target")
			_check(bool(player.get("is_zombie")), "Zombie bot did not chase and infect a nearby human")
			var zombie_hands := player.get_node("Head/ZombieFirstPersonHands") as Node3D
			_check(zombie_hands.visible, "First-person zombie hands are hidden")
			var right_hand := zombie_hands.get_node("RightHand") as Node3D
			var hand_start := right_hand.position
			player.call("_play_zombie_attack_feedback")
			await get_tree().create_timer(0.12).timeout
			_check(right_hand.position.distance_to(hand_start) > 0.05, "First-person zombie attack animation did not move")
			_check((player.get_node("Head/ZombieAttackSound") as AudioStreamPlayer).playing, "Zombie attack sound did not play")
			var human_target: CharacterBody3D
			for node: Node in world.get_tree().get_nodes_in_group("players"):
				if node is CharacterBody3D and not bool(node.get("is_zombie")) and bool(node.get("is_alive")):
					human_target = node as CharacterBody3D
					break
			_check(human_target != null, "No human target was available for player infection test")
			if human_target != null:
				human_target.set_physics_process(false)
				player.global_position = human_target.global_position + Vector3(2.0, 0.0, 0.0)
				player.look_at(Vector3(
					human_target.global_position.x,
					player.global_position.y,
					human_target.global_position.z
				))
				(player.get_node("Head") as Node3D).rotation.x = 0.0
				human_target.velocity = Vector3.ZERO
				player.set_physics_process(false)
				await get_tree().physics_frame
				player.set("infection_timer", 0.0)
				player.call("_perform_zombie_attack")
				await get_tree().process_frame
				_check(bool(human_target.get("is_zombie")), "Local player zombie attack did not infect a human")
			player.call(
				"_on_player_health_changed",
				int(player.get("peer_id")),
				float(player.get("health")) - 1.0,
				float(player.get("max_health")),
				player.global_position + Vector3(5.0, 0.0, 0.0),
				4.5
			)
			_check(
				(world.get_node("CanvasLayer/HUD/DamageIndicator") as Control).visible,
				"Zombie damage direction indicator did not appear"
			)

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
