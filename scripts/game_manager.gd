extends Node
## 服务器权威的回合、感染、伤害和重生状态机。

enum GameState { WAITING, COUNTDOWN, PLAYING, GAME_OVER }

signal state_changed(new_state: GameState)
signal countdown_updated(seconds: int)
signal game_time_updated(seconds: float)
signal zombie_chosen(peer_id: int, player_name: String)
signal player_infected(victim_id: int, attacker_id: int)
signal player_health_changed(peer_id: int, health: float, max_health: float, hit_pos: Vector3, knockback: float)
signal player_died(peer_id: int)
signal player_respawned(peer_id: int, health: float)
signal player_reset(peer_id: int, health: float)
signal game_over(winner: String)
signal map_seed_changed(map_seed: int)

const COUNTDOWN_SECONDS := 5.0
const ROUND_SECONDS := 240.0
const HUMAN_HEALTH := 100.0
const ZOMBIE_HEALTH := 300.0
const ZOMBIE_RESPAWN_SECONDS := 3.0

var state: GameState = GameState.WAITING
var countdown_timer := COUNTDOWN_SECONDS
var game_timer := ROUND_SECONDS
var playing_elapsed := 0.0
var _last_countdown_second := -1
var _time_sync_accumulator := 0.0
var _last_shot_time: Dictionary = {}
var _last_shot_sequence: Dictionary = {}
var map_seed: int = 1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	match state:
		GameState.COUNTDOWN:
			_update_countdown(delta)
		GameState.PLAYING:
			_update_playing(delta)


func _update_countdown(delta: float) -> void:
	countdown_timer -= delta
	var seconds := maxi(0, int(ceil(countdown_timer)))
	if seconds != _last_countdown_second:
		_last_countdown_second = seconds
		rpc("_sync_countdown", seconds)

	if countdown_timer <= 0.0:
		_choose_zombies()
		_set_state_server(GameState.PLAYING)


func _update_playing(delta: float) -> void:
	game_timer = maxf(0.0, game_timer - delta)
	playing_elapsed += delta
	_time_sync_accumulator += delta
	if _time_sync_accumulator >= 0.2:
		_time_sync_accumulator = 0.0
		rpc("_sync_game_time", game_timer)

	if playing_elapsed >= 2.0 and NetworkManager.players.size() > 1 and NetworkManager.all_are_zombies():
		_end_game("zombies")
	elif game_timer <= 0.0:
		_end_game("humans")


func start_game() -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	var next_seed := int(Time.get_unix_time_from_system()) ^ Time.get_ticks_msec() ^ randi()
	if next_seed == map_seed:
		next_seed += 1
	rpc("_sync_map_seed", next_seed)
	for pid: int in NetworkManager.players:
		var info: Dictionary = NetworkManager.players[pid].duplicate(true)
		info["is_zombie"] = false
		info["alive"] = true
		info["health"] = HUMAN_HEALTH
		info["max_health"] = HUMAN_HEALTH
		NetworkManager.update_player_info(pid, info)
		rpc("_sync_player_reset", pid, HUMAN_HEALTH)

	countdown_timer = COUNTDOWN_SECONDS
	game_timer = ROUND_SECONDS
	playing_elapsed = 0.0
	_last_countdown_second = -1
	_time_sync_accumulator = 0.0
	_last_shot_time.clear()
	_last_shot_sequence.clear()
	_set_state_server(GameState.COUNTDOWN)


func sync_state_to_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	rpc_id(peer_id, "_sync_state", int(state), countdown_timer, game_timer, map_seed)


func _choose_zombies() -> void:
	# 单人模式保留为武器和地图测试，不会把唯一玩家变成僵尸。
	if NetworkManager.players.size() < 2:
		return
	var candidates: Array[int] = []
	var bot_candidates: Array[int] = []
	for pid: int in NetworkManager.players:
		candidates.append(pid)
		if bool(NetworkManager.players[pid].get("is_bot", false)):
			bot_candidates.append(pid)
	var pool := bot_candidates if not bot_candidates.is_empty() else candidates
	pool.shuffle()
	_set_zombie_server(pool[0], true)


func request_infection(victim_id: int, attacker_id: int) -> void:
	if multiplayer.is_server():
		_server_infect(victim_id, attacker_id)
	else:
		rpc_id(1, "_request_infection", victim_id)


@rpc("any_peer", "reliable")
func _request_infection(victim_id: int) -> void:
	_server_infect(victim_id, multiplayer.get_remote_sender_id())


func _server_infect(victim_id: int, attacker_id: int) -> void:
	if not multiplayer.is_server() or state != GameState.PLAYING:
		return
	if not NetworkManager.players.has(victim_id) or not NetworkManager.players.has(attacker_id):
		return
	var attacker: Dictionary = NetworkManager.players[attacker_id]
	var victim: Dictionary = NetworkManager.players[victim_id]
	if not attacker.get("is_zombie", false) or not attacker.get("alive", true):
		return
	if victim.get("is_zombie", false) or not victim.get("alive", true):
		return
	var attacker_node := _find_player(attacker_id)
	var victim_node := _find_player(victim_id)
	if attacker_node == null or victim_node == null:
		return
	if attacker_node.global_position.distance_to(victim_node.global_position) > 3.2:
		return
	_set_zombie_server(victim_id, false, attacker_id)


func _set_zombie_server(peer_id: int, initially_chosen: bool, attacker_id: int = -1) -> void:
	var info: Dictionary = NetworkManager.players[peer_id].duplicate(true)
	info["is_zombie"] = true
	info["alive"] = true
	info["health"] = ZOMBIE_HEALTH
	info["max_health"] = ZOMBIE_HEALTH
	NetworkManager.update_player_info(peer_id, info)
	if initially_chosen:
		rpc("_sync_zombie_chosen", peer_id, str(info.get("name", "玩家")))
	else:
		rpc("_sync_player_infected", peer_id, attacker_id)


func request_weapon_hit(victim_id: int, weapon_index: int, hit_pos: Vector3, pellet_hits: int, attacker_id: int, shot_sequence: int) -> void:
	if multiplayer.is_server():
		_server_weapon_hit(victim_id, weapon_index, hit_pos, pellet_hits, attacker_id, shot_sequence)
	else:
		rpc_id(1, "_request_weapon_hit", victim_id, weapon_index, hit_pos, pellet_hits, shot_sequence)


@rpc("any_peer", "reliable")
func _request_weapon_hit(victim_id: int, weapon_index: int, hit_pos: Vector3, pellet_hits: int, shot_sequence: int) -> void:
	_server_weapon_hit(victim_id, weapon_index, hit_pos, pellet_hits, multiplayer.get_remote_sender_id(), shot_sequence)


func _server_weapon_hit(victim_id: int, weapon_index: int, hit_pos: Vector3, pellet_hits: int, attacker_id: int, shot_sequence: int) -> void:
	if not multiplayer.is_server() or state != GameState.PLAYING:
		return
	if not NetworkManager.players.has(victim_id) or not NetworkManager.players.has(attacker_id):
		return
	var attacker: Dictionary = NetworkManager.players[attacker_id]
	var victim: Dictionary = NetworkManager.players[victim_id]
	if attacker.get("is_zombie", false) or not attacker.get("alive", true):
		return
	if not victim.get("is_zombie", false) or not victim.get("alive", true):
		return
	var weapon := WeaponData.from_index(weapon_index)
	if weapon == null:
		return
	var now := Time.get_ticks_msec()
	var previous_sequence := int(_last_shot_sequence.get(attacker_id, -1))
	if shot_sequence != previous_sequence:
		var previous_time := int(_last_shot_time.get(attacker_id, 0))
		var minimum_interval := int((1000.0 / maxf(weapon.fire_rate, 0.1)) * 0.72)
		if now - previous_time < minimum_interval:
			return
		_last_shot_time[attacker_id] = now
		_last_shot_sequence[attacker_id] = shot_sequence
	var attacker_node := _find_player(attacker_id)
	var victim_node := _find_player(victim_id)
	if attacker_node == null or victim_node == null:
		return
	if attacker_node.global_position.distance_to(victim_node.global_position) > weapon.range + 3.0:
		return
	var query := PhysicsRayQueryParameters3D.create(
		attacker_node.global_position + Vector3.UP * 1.55,
		hit_pos
	)
	query.exclude = [attacker_node.get_rid()]
	query.collision_mask = 1
	var ray_result := attacker_node.get_world_3d().direct_space_state.intersect_ray(query)
	if ray_result.is_empty() or ray_result.get("collider") != victim_node:
		return

	var hits := clampi(pellet_hits, 1, weapon.pellet_count)
	var damage := weapon.damage * hits
	var health := maxf(0.0, float(victim.get("health", ZOMBIE_HEALTH)) - damage)
	victim["health"] = health
	NetworkManager.update_player_info(victim_id, victim)
	rpc("_sync_damage", victim_id, health, float(victim.get("max_health", ZOMBIE_HEALTH)), hit_pos, weapon.knockback)
	if health <= 0.0:
		_kill_zombie(victim_id)


func _kill_zombie(peer_id: int) -> void:
	if not NetworkManager.players.has(peer_id):
		return
	var info: Dictionary = NetworkManager.players[peer_id].duplicate(true)
	if not info.get("alive", true):
		return
	info["alive"] = false
	NetworkManager.update_player_info(peer_id, info)
	rpc("_sync_player_died", peer_id)
	_respawn_zombie_after_delay(peer_id)


func _respawn_zombie_after_delay(peer_id: int) -> void:
	await get_tree().create_timer(ZOMBIE_RESPAWN_SECONDS).timeout
	if state != GameState.PLAYING or not NetworkManager.players.has(peer_id):
		return
	var info: Dictionary = NetworkManager.players[peer_id].duplicate(true)
	info["alive"] = true
	info["health"] = ZOMBIE_HEALTH
	info["max_health"] = ZOMBIE_HEALTH
	NetworkManager.update_player_info(peer_id, info)
	rpc("_sync_player_respawned", peer_id, ZOMBIE_HEALTH)


func _find_player(peer_id: int) -> CharacterBody3D:
	for node: Node in get_tree().get_nodes_in_group("players"):
		if node is CharacterBody3D and int(node.get("peer_id")) == peer_id:
			return node
	return null


func _end_game(winner: String) -> void:
	if state == GameState.GAME_OVER:
		return
	_set_state_server(GameState.GAME_OVER)
	rpc("_sync_game_over", winner)


func _set_state_server(new_state: GameState) -> void:
	rpc("_sync_state", int(new_state), countdown_timer, game_timer, map_seed)


@rpc("authority", "call_local", "reliable")
func _sync_state(new_state: int, synced_countdown: float, synced_game_time: float, synced_map_seed: int) -> void:
	state = new_state
	countdown_timer = synced_countdown
	game_timer = synced_game_time
	if map_seed != synced_map_seed:
		map_seed = synced_map_seed
		map_seed_changed.emit(map_seed)
	state_changed.emit(state)


@rpc("authority", "call_local", "reliable")
func _sync_map_seed(synced_map_seed: int) -> void:
	map_seed = synced_map_seed
	map_seed_changed.emit(map_seed)


@rpc("authority", "call_local", "reliable")
func _sync_countdown(seconds: int) -> void:
	countdown_timer = float(seconds)
	countdown_updated.emit(seconds)


@rpc("authority", "call_local", "unreliable_ordered")
func _sync_game_time(seconds: float) -> void:
	game_timer = seconds
	game_time_updated.emit(seconds)


@rpc("authority", "call_local", "reliable")
func _sync_zombie_chosen(peer_id: int, player_name: String) -> void:
	if NetworkManager.players.has(peer_id):
		var info: Dictionary = NetworkManager.players[peer_id]
		info["is_zombie"] = true
		info["alive"] = true
		info["health"] = ZOMBIE_HEALTH
		info["max_health"] = ZOMBIE_HEALTH
	zombie_chosen.emit(peer_id, player_name)


@rpc("authority", "call_local", "reliable")
func _sync_player_infected(peer_id: int, attacker_id: int) -> void:
	if NetworkManager.players.has(peer_id):
		var info: Dictionary = NetworkManager.players[peer_id]
		info["is_zombie"] = true
		info["alive"] = true
		info["health"] = ZOMBIE_HEALTH
		info["max_health"] = ZOMBIE_HEALTH
	player_infected.emit(peer_id, attacker_id)


@rpc("authority", "call_local", "reliable")
func _sync_damage(peer_id: int, health: float, max_health: float, hit_pos: Vector3, knockback: float) -> void:
	if NetworkManager.players.has(peer_id):
		NetworkManager.players[peer_id]["health"] = health
	player_health_changed.emit(peer_id, health, max_health, hit_pos, knockback)


@rpc("authority", "call_local", "reliable")
func _sync_player_died(peer_id: int) -> void:
	if NetworkManager.players.has(peer_id):
		NetworkManager.players[peer_id]["alive"] = false
	player_died.emit(peer_id)


@rpc("authority", "call_local", "reliable")
func _sync_player_respawned(peer_id: int, health: float) -> void:
	if NetworkManager.players.has(peer_id):
		NetworkManager.players[peer_id]["alive"] = true
		NetworkManager.players[peer_id]["health"] = health
	player_respawned.emit(peer_id, health)


@rpc("authority", "call_local", "reliable")
func _sync_player_reset(peer_id: int, health: float) -> void:
	if NetworkManager.players.has(peer_id):
		var info: Dictionary = NetworkManager.players[peer_id]
		info["is_zombie"] = false
		info["alive"] = true
		info["health"] = health
		info["max_health"] = health
	player_reset.emit(peer_id, health)


@rpc("authority", "call_local", "reliable")
func _sync_game_over(winner: String) -> void:
	game_over.emit(winner)
