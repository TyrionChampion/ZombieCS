extends Node3D
## 为所有已注册玩家创建同名节点，并连接本地玩家 HUD。

@onready var spawn_points: Node3D = $SpawnPoints
@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var countdown_label: Label = $CanvasLayer/HUD/CountdownLabel
@onready var time_label: Label = $CanvasLayer/HUD/TimeLabel
@onready var role_label: Label = $CanvasLayer/HUD/RoleLabel
@onready var health_label: Label = $CanvasLayer/HUD/HealthLabel
@onready var weapon_label: Label = $CanvasLayer/HUD/WeaponLabel
@onready var ammo_label: Label = $CanvasLayer/HUD/AmmoLabel
@onready var notification_label: Label = $CanvasLayer/HUD/NotificationLabel
@onready var crosshair: Label = $CanvasLayer/HUD/Crosshair
@onready var game_over_panel: Panel = $CanvasLayer/HUD/GameOverPanel
@onready var game_over_label: Label = $CanvasLayer/HUD/GameOverPanel/GameOverLabel
@onready var restart_button: Button = $CanvasLayer/HUD/GameOverPanel/RestartButton

var player_scene: PackedScene = preload("res://scenes/player.tscn")
var local_player: CharacterBody3D
var _notification_serial := 0
var current_map_seed: int = 0
var current_module_ids: Array[int] = []
var _procedural_map: Node3D
var _wall_material: Material
var _crate_material: Material
var _plaster_material: Material
var _site_a_material: Material
var _site_b_material: Material

const MODULE_SOCKETS := [
	Vector3(-13.5, 0.0, -13.0),
	Vector3(13.5, 0.0, -13.0),
	Vector3(-13.5, 0.0, 13.0),
	Vector3(13.5, 0.0, 13.0),
]
const MODULE_POOLS := [
	[5, 8],
	[0, 1, 6, 9],
	[4, 10, 11],
	[2, 3, 7],
]

# Every module stays inside an 8 x 8 metre socket. The outer ring and the
# north/south/east/west roads remain open, so every layout is connected.
const MAP_MODULES := [
	[["wall", Vector3(-2.8, 1.5, 0.0), Vector3(0.6, 3.0, 6.0)], ["crate", Vector3(1.6, 1.0, 1.8), Vector3(2.0, 2.0, 2.0)]],
	[["wall", Vector3(-2.4, 1.5, -1.8), Vector3(4.8, 3.0, 0.5)], ["wall", Vector3(2.4, 1.5, 1.8), Vector3(4.8, 3.0, 0.5)]],
	[["wall", Vector3(0.0, 1.5, -2.8), Vector3(6.0, 3.0, 0.5)], ["wall", Vector3(-2.8, 1.5, 0.0), Vector3(0.5, 3.0, 5.5)], ["crate", Vector3(1.6, 0.75, 1.5), Vector3(1.5, 1.5, 1.5)]],
	[["plaster", Vector3(-1.8, 2.0, -1.8), Vector3(1.4, 4.0, 1.4)], ["plaster", Vector3(1.8, 2.0, 1.8), Vector3(1.4, 4.0, 1.4)], ["crate", Vector3(1.8, 0.65, -1.8), Vector3(1.3, 1.3, 1.3)]],
	[["crate", Vector3(-2.4, 0.8, 2.2), Vector3(1.6, 1.6, 1.6)], ["crate", Vector3(0.0, 1.0, 0.0), Vector3(2.0, 2.0, 2.0)], ["crate", Vector3(2.4, 0.8, -2.2), Vector3(1.6, 1.6, 1.6)]],
	[["plaster", Vector3(0.0, 2.0, 0.0), Vector3(4.5, 4.0, 4.5)], ["crate", Vector3(-2.8, 0.8, 2.6), Vector3(1.6, 1.6, 1.6)]],
	[["wall", Vector3(-2.4, 1.4, 0.0), Vector3(0.45, 2.8, 6.0)], ["wall", Vector3(2.4, 1.4, 0.0), Vector3(0.45, 2.8, 6.0)], ["crate", Vector3(0.0, 0.7, 0.0), Vector3(1.4, 1.4, 1.4)]],
	[["wall", Vector3(-1.8, 1.2, -2.5), Vector3(4.0, 2.4, 0.45)], ["wall", Vector3(1.8, 1.2, 0.0), Vector3(4.0, 2.4, 0.45)], ["wall", Vector3(-1.8, 1.2, 2.5), Vector3(4.0, 2.4, 0.45)]],
	[["plaster", Vector3(0.0, 2.5, 0.0), Vector3(3.2, 5.0, 3.2)], ["crate", Vector3(-2.7, 0.75, 0.0), Vector3(1.5, 1.5, 1.5)], ["crate", Vector3(2.7, 0.75, 0.0), Vector3(1.5, 1.5, 1.5)]],
	[["wall", Vector3(-2.6, 1.5, 0.0), Vector3(0.5, 3.0, 6.5)], ["wall", Vector3(2.6, 1.5, 0.0), Vector3(0.5, 3.0, 6.5)]],
	[["crate", Vector3(0.0, 0.8, 0.0), Vector3(1.6, 1.6, 5.5)], ["crate", Vector3(-2.2, 0.8, 0.0), Vector3(1.4, 1.6, 1.4)], ["crate", Vector3(2.2, 0.8, 0.0), Vector3(1.4, 1.6, 1.4)]],
	[["plaster", Vector3(-2.4, 0.6, -2.4), Vector3(2.0, 1.2, 2.0)], ["plaster", Vector3(2.4, 0.6, 2.4), Vector3(2.0, 1.2, 2.0)], ["crate", Vector3(2.4, 0.8, -2.4), Vector3(1.6, 1.6, 1.6)]],
]


func _ready() -> void:
	if multiplayer.multiplayer_peer == null:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
		return

	NetworkManager.player_joined.connect(_on_player_joined)
	NetworkManager.player_left.connect(_on_player_left)
	GameManager.state_changed.connect(_on_state_changed)
	GameManager.countdown_updated.connect(_on_countdown)
	GameManager.game_time_updated.connect(_on_time)
	GameManager.zombie_chosen.connect(_on_zombie_chosen)
	GameManager.player_infected.connect(_on_player_infected)
	GameManager.player_respawned.connect(_on_player_respawned)
	GameManager.player_reset.connect(_on_player_reset)
	GameManager.game_over.connect(_on_game_over)
	GameManager.map_seed_changed.connect(_on_map_seed_changed)
	restart_button.pressed.connect(_on_restart_pressed)
	restart_button.visible = NetworkManager.is_host
	_prepare_procedural_map()
	regenerate_map(GameManager.map_seed)

	var ids: Array = NetworkManager.players.keys()
	ids.sort()
	for pid: int in ids:
		_spawn_player(pid)
	_on_time(GameManager.game_timer)


func _prepare_procedural_map() -> void:
	_wall_material = ($Terrain/Mid_Wall_W as CSGBox3D).material
	_crate_material = ($Terrain/A_Box1 as CSGBox3D).material
	_plaster_material = ($Terrain/A_Plat as CSGBox3D).material
	_site_a_material = ($Terrain/SiteAColor as CSGCylinder3D).material
	_site_b_material = ($Terrain/SiteBColor as CSGCylinder3D).material
	for node: Node in $Terrain.find_children("*", "CSGBox3D", true, false):
		(node as CSGBox3D).use_collision = false
	$Terrain.visible = false
	_procedural_map = Node3D.new()
	_procedural_map.name = "ProceduralMap"
	add_child(_procedural_map)


func regenerate_map(map_seed: int) -> void:
	if _procedural_map == null:
		return
	current_map_seed = map_seed
	for child: Node in _procedural_map.get_children():
		child.free()
	current_module_ids.clear()

	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed
	for socket_index in range(MODULE_SOCKETS.size()):
		var pool: Array = MODULE_POOLS[socket_index]
		var module_id: int = int(pool[rng.randi_range(0, pool.size() - 1)])
		current_module_ids.append(module_id)
		var turns := rng.randi_range(0, 3)
		_create_module(module_id, MODULE_SOCKETS[socket_index], turns)

	_create_fixed_landmarks()
	_update_spawn_points(rng)
	_build_navigation_grid()


func _create_module(module_id: int, origin: Vector3, quarter_turns: int) -> void:
	var module_root := Node3D.new()
	module_root.name = "Module_%02d_%02d" % [current_module_ids.size(), module_id]
	module_root.position = origin
	module_root.rotation.y = quarter_turns * PI * 0.5
	_procedural_map.add_child(module_root)
	for part: Array in MAP_MODULES[module_id]:
		_create_box(module_root, str(part[0]), part[1], part[2])


func _create_box(parent: Node3D, material_key: String, local_position: Vector3, size: Vector3) -> CSGBox3D:
	var box := CSGBox3D.new()
	box.name = "%s_%02d" % [material_key.capitalize(), parent.get_child_count()]
	box.position = local_position
	box.size = size
	box.use_collision = true
	match material_key:
		"crate":
			box.material = _crate_material
		"plaster":
			box.material = _plaster_material
		_:
			box.material = _wall_material
	parent.add_child(box)
	return box


func _create_fixed_landmarks() -> void:
	# Four split gates create a readable cross-shaped mid while keeping 3 m openings.
	for gate_data: Array in [
		[Vector3(-5.0, 1.5, -7.0), Vector3(6.5, 3.0, 0.55)],
		[Vector3(5.0, 1.5, -7.0), Vector3(6.5, 3.0, 0.55)],
		[Vector3(-5.0, 1.5, 7.0), Vector3(6.5, 3.0, 0.55)],
		[Vector3(5.0, 1.5, 7.0), Vector3(6.5, 3.0, 0.55)],
		[Vector3(-7.0, 1.5, -5.0), Vector3(0.55, 3.0, 6.5)],
		[Vector3(-7.0, 1.5, 5.0), Vector3(0.55, 3.0, 6.5)],
		[Vector3(7.0, 1.5, -5.0), Vector3(0.55, 3.0, 6.5)],
		[Vector3(7.0, 1.5, 5.0), Vector3(0.55, 3.0, 6.5)],
	]:
		_create_box(_procedural_map, "wall", gate_data[0], gate_data[1])

	# Low platforms remain walkable in the grid and make both sites visible at distance.
	_create_box(_procedural_map, "plaster", Vector3(-18.0, 0.15, 18.0), Vector3(7.0, 0.3, 7.0))
	_create_box(_procedural_map, "plaster", Vector3(18.0, 0.15, -18.0), Vector3(7.0, 0.3, 7.0))
	_create_site_disc(Vector3(-18.0, 0.34, 18.0), _site_a_material)
	_create_site_disc(Vector3(18.0, 0.34, -18.0), _site_b_material)
	_create_site_label("A", Vector3(-18.0, 3.1, 18.0), Color(1.0, 0.2, 0.12))
	_create_site_label("B", Vector3(18.0, 3.1, -18.0), Color(0.15, 0.55, 1.0))
	_create_site_label("MID", Vector3(0.0, 3.8, 0.0), Color(1.0, 0.82, 0.2), 64)


func _create_site_disc(disc_position: Vector3, disc_material: Material) -> void:
	var disc := CSGCylinder3D.new()
	disc.position = disc_position
	disc.radius = 2.8
	disc.height = 0.08
	disc.sides = 24
	disc.use_collision = false
	disc.material = disc_material
	_procedural_map.add_child(disc)


func _create_site_label(label_text: String, label_position: Vector3, color: Color, size: int = 130) -> void:
	var label := Label3D.new()
	label.text = label_text
	label.position = label_position
	label.font_size = size
	label.outline_size = 12
	label.modulate = color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_procedural_map.add_child(label)


func _update_spawn_points(rng: RandomNumberGenerator) -> void:
	var candidates := [
		Vector3(-21, 2, -20), Vector3(-17, 2, -21), Vector3(-9, 2, -21),
		Vector3(0, 2, -21), Vector3(9, 2, -21), Vector3(17, 2, -21),
		Vector3(21, 2, -20), Vector3(21, 2, -10), Vector3(21, 2, 0),
		Vector3(21, 2, 10), Vector3(21, 2, 20), Vector3(12, 2, 21),
		Vector3(4, 2, 21), Vector3(-4, 2, 21), Vector3(-12, 2, 21),
		Vector3(-21, 2, 20), Vector3(-21, 2, 10), Vector3(-21, 2, 0),
		Vector3(-21, 2, -10), Vector3(0, 2, -7), Vector3(0, 2, 7),
		Vector3(-7, 2, 0), Vector3(7, 2, 0), Vector3(0, 2, 0),
	]
	# A deterministic shuffle prevents one team from always receiving the same landmark.
	for i in range(candidates.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var temp: Vector3 = candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = temp
	var points := spawn_points.get_children()
	for i in range(mini(points.size(), candidates.size())):
		(points[i] as Marker3D).position = candidates[i]


func get_layout_signature() -> String:
	return "%d:%s" % [current_map_seed, str(current_module_ids)]


func _on_map_seed_changed(map_seed: int) -> void:
	regenerate_map(map_seed)


func _build_navigation_grid() -> void:
	# CSG 自动烘焙在无界面服务器不可用，因此从碰撞盒生成确定性的平面导航网格。
	const MIN_COORD := -24
	const MAX_COORD := 24
	const GRID_SIZE := MAX_COORD - MIN_COORD + 1
	var navigation_mesh := NavigationMesh.new()
	navigation_mesh.agent_height = 1.8
	navigation_mesh.agent_radius = 0.55
	navigation_mesh.agent_max_climb = 0.55
	navigation_mesh.agent_max_slope = 46.0

	var vertices := PackedVector3Array()
	for z in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			vertices.append(Vector3(float(MIN_COORD + x), 0.08, float(MIN_COORD + z)))
	navigation_mesh.set_vertices(vertices)

	var blockers: Array[AABB] = []
	for root: Node in [$Walls, _procedural_map]:
		for node: Node in root.find_children("*", "CSGBox3D", true, false):
			var shape := node as CSGBox3D
			var world_bounds: AABB = shape.global_transform * shape.get_aabb()
			if world_bounds.end.y > 0.7:
				blockers.append(world_bounds.grow(0.58))

	for z in range(GRID_SIZE - 1):
		for x in range(GRID_SIZE - 1):
			var center := Vector3(float(MIN_COORD + x) + 0.5, 1.0, float(MIN_COORD + z) + 0.5)
			var blocked := false
			for bounds: AABB in blockers:
				if bounds.has_point(center):
					blocked = true
					break
			if blocked:
				continue
			var row := GRID_SIZE
			var i0 := z * row + x
			var polygon := PackedInt32Array([i0, i0 + 1, i0 + row + 1, i0 + row])
			navigation_mesh.add_polygon(polygon)

	navigation_region.navigation_mesh = navigation_mesh


func _spawn_player(peer_id: int) -> void:
	if get_node_or_null(str(peer_id)) != null:
		return
	var player := player_scene.instantiate() as CharacterBody3D
	player.name = str(peer_id)
	player.position = to_local(_get_spawn_position(peer_id))
	var info: Dictionary = NetworkManager.players.get(peer_id, {})
	var bot := bool(info.get("is_bot", false))
	player.set("peer_id", peer_id)
	player.set("is_bot", bot)
	player.set("is_zombie", bool(info.get("is_zombie", false)))
	player.set("is_alive", bool(info.get("alive", true)))
	player.set("health", float(info.get("health", 100.0)))
	player.set("max_health", float(info.get("max_health", 100.0)))
	player.set_multiplayer_authority(1 if bot else peer_id)
	add_child(player)
	_orient_player_toward_center(player)

	if peer_id == multiplayer.get_unique_id():
		local_player = player
		var weapon_system: Node = player.get_node("Head/WeaponSystem")
		weapon_system.connect("ammo_changed", _on_ammo_changed)
		weapon_system.connect("weapon_changed", _on_weapon_changed)
		player.connect("health_changed", _on_local_health_changed)
		player.connect("role_changed", _on_local_role_changed)
		player.connect("notification_requested", _show_notification)
		player.connect("hit_confirmed", _on_hit_confirmed)
		_refresh_local_hud()


func _get_spawn_position(peer_id: int) -> Vector3:
	var points := spawn_points.get_children()
	if points.is_empty():
		return Vector3(0, 2, 0)
	var index := posmod(peer_id - 1, points.size())
	return (points[index] as Marker3D).global_position


func _orient_player_toward_center(player: CharacterBody3D) -> void:
	var target := Vector3(0.0, player.global_position.y, 0.0)
	if player.global_position.distance_squared_to(target) > 1.0:
		player.look_at(target, Vector3.UP)


func _on_player_joined(peer_id: int, _player_name: String) -> void:
	_spawn_player(peer_id)


func _on_player_left(peer_id: int) -> void:
	var node := get_node_or_null(str(peer_id))
	if node != null:
		node.queue_free()


func _on_state_changed(new_state: int) -> void:
	if new_state == GameManager.GameState.COUNTDOWN:
		game_over_panel.visible = false
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _on_countdown(seconds: int) -> void:
	countdown_label.text = str(seconds) if seconds > 0 else "GO!"
	countdown_label.visible = true
	if seconds == 0:
		await get_tree().create_timer(0.8).timeout
		countdown_label.visible = false


func _on_time(seconds: float) -> void:
	var total := maxi(0, int(ceil(seconds)))
	time_label.text = "%02d:%02d" % [total / 60, total % 60]


func _on_zombie_chosen(peer_id: int, player_name: String) -> void:
	if peer_id == multiplayer.get_unique_id():
		_show_notification("你成为了初始僵尸！感染所有人类！")
	else:
		_show_notification("%s 成为了初始僵尸" % player_name)
	_refresh_local_hud()


func _on_player_infected(peer_id: int) -> void:
	var info: Dictionary = NetworkManager.players.get(peer_id, {})
	_show_notification("🦠 %s 被感染！" % str(info.get("name", "玩家")))
	_refresh_local_hud()


func _on_player_respawned(peer_id: int, _health: float) -> void:
	var player := get_node_or_null(str(peer_id)) as CharacterBody3D
	if player != null:
		player.global_position = _get_spawn_position(peer_id)
		player.set("velocity", Vector3.ZERO)
		_orient_player_toward_center(player)
	_refresh_local_hud()


func _on_player_reset(peer_id: int, _health: float) -> void:
	var player := get_node_or_null(str(peer_id))
	if player != null:
		player.call("reset_for_round", _get_spawn_position(peer_id))
		_orient_player_toward_center(player)
	_refresh_local_hud()


func _on_game_over(winner: String) -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	game_over_panel.visible = true
	restart_button.visible = NetworkManager.is_host
	if winner == "humans":
		game_over_label.text = "🎉 人类胜利！\n成功坚持到回合结束"
	else:
		game_over_label.text = "💀 僵尸胜利！\n所有人类都已被感染"


func _on_restart_pressed() -> void:
	if NetworkManager.is_host:
		GameManager.start_game()


func _refresh_local_hud() -> void:
	if local_player == null:
		return
	var weapon_system: Node = local_player.get_node("Head/WeaponSystem")
	_on_local_role_changed(bool(local_player.get("is_zombie")))
	_on_local_health_changed(float(local_player.get("health")), float(local_player.get("max_health")))
	_on_weapon_changed(str(weapon_system.call("get_current_weapon_name")))
	_on_ammo_changed(int(weapon_system.call("get_current_ammo")), int(weapon_system.call("get_reserve_ammo")))


func _on_local_role_changed(is_zombie: bool) -> void:
	role_label.text = "阵营：僵尸" if is_zombie else "阵营：人类"
	weapon_label.visible = not is_zombie
	ammo_label.visible = not is_zombie


func _on_local_health_changed(current: float, maximum: float) -> void:
	health_label.text = "生命：%d / %d" % [int(ceil(current)), int(maximum)]


func _on_weapon_changed(weapon_name: String) -> void:
	weapon_label.text = weapon_name


func _on_ammo_changed(current: int, reserve: int) -> void:
	ammo_label.text = "%d / %d" % [current, reserve]


func _on_hit_confirmed() -> void:
	crosshair.text = "×"
	crosshair.modulate = Color(1.0, 0.22, 0.18)
	await get_tree().create_timer(0.12).timeout
	crosshair.text = "+"
	crosshair.modulate = Color.WHITE


func _show_notification(message: String) -> void:
	_notification_serial += 1
	var serial := _notification_serial
	notification_label.text = message
	notification_label.visible = true
	await get_tree().create_timer(2.0).timeout
	if serial == _notification_serial:
		notification_label.visible = false
