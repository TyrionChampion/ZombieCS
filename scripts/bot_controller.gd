extends Node
## 服务器端机器人：战术点巡逻、视线检查、简单避障和阵营战斗。

const THINK_INTERVAL := 0.25
const DEFENSE_POINTS: Array[Vector3] = [
	Vector3(-17, 2, 15),
	Vector3(-10, 3, 19),
	Vector3(-4, 2, 8),
	Vector3(5, 2, 5),
	Vector3(12, 2, -12),
	Vector3(18, 2, -17),
	Vector3(8, 3, -5),
	Vector3(-14, 2, 5),
	Vector3(0, 2, -15),
	Vector3(15, 2, 2),
]

var actor: CharacterBody3D
var target: CharacterBody3D
var navigation_agent: NavigationAgent3D
var think_timer := 0.0
var strafe_direction := 1.0
var shot_sequence := 0


func _ready() -> void:
	actor = get_parent() as CharacterBody3D
	navigation_agent = actor.get_node("NavigationAgent3D") as NavigationAgent3D
	strafe_direction = -1.0 if int(actor.get("peer_id")) % 2 == 0 else 1.0
	think_timer = float(posmod(int(actor.get("peer_id")), 8)) * 0.035


func tick(delta: float) -> void:
	if actor == null or not multiplayer.is_server():
		return
	think_timer -= delta
	if think_timer <= 0.0 or not _target_is_valid():
		think_timer = THINK_INTERVAL + randf_range(0.0, 0.15)
		target = _find_nearest_enemy()

	_apply_gravity(delta)
	if target == null:
		_move_toward_defense(delta)
	elif bool(actor.get("is_zombie")):
		_tick_zombie(delta)
	else:
		_tick_human(delta)
	actor.call("apply_pending_knockback", delta)
	actor.move_and_slide()


func _target_is_valid() -> bool:
	if not is_instance_valid(target) or not target.is_inside_tree():
		return false
	if not bool(target.get("is_alive")):
		return false
	return bool(target.get("is_zombie")) != bool(actor.get("is_zombie"))


func _find_nearest_enemy() -> CharacterBody3D:
	var nearest: CharacterBody3D
	var nearest_distance := INF
	for node: Node in get_tree().get_nodes_in_group("players"):
		if node == actor or not node is CharacterBody3D:
			continue
		if not bool(node.get("is_alive")):
			continue
		if bool(node.get("is_zombie")) == bool(actor.get("is_zombie")):
			continue
		var distance := actor.global_position.distance_squared_to(node.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = node
	return nearest


func _tick_zombie(delta: float) -> void:
	var offset := target.global_position - actor.global_position
	var flat := Vector3(offset.x, 0.0, offset.z)
	_aim_at(target.global_position + Vector3.UP)
	var path_direction := _navigation_direction(target.global_position)
	_set_horizontal_velocity(_avoid_obstacles(path_direction), float(actor.get("zombie_speed")))
	if flat.length() <= 2.8 and _has_line_of_sight(target):
		var cooldown := float(actor.get("infection_timer"))
		if cooldown <= 0.0:
			actor.set("infection_timer", float(actor.get("infection_cooldown")))
			GameManager.request_infection(int(target.get("peer_id")), int(actor.get("peer_id")))
	_try_jump_over_obstacle(flat.normalized())


func _tick_human(_delta: float) -> void:
	var offset := target.global_position - actor.global_position
	var flat := Vector3(offset.x, 0.0, offset.z)
	var distance := flat.length()
	var can_see := _has_line_of_sight(target)
	_aim_at(target.global_position + Vector3.UP)

	var desired := Vector3.ZERO
	if distance < 8.0:
		desired = -flat.normalized()
	elif not can_see or distance > 26.0:
		desired = _navigation_direction(target.global_position)
	else:
		desired = flat.normalized().cross(Vector3.UP) * strafe_direction
	_set_horizontal_velocity(_avoid_obstacles(desired), float(actor.get("sprint_speed")))
	_try_jump_over_obstacle(desired)

	if can_see:
		_fire_at_target(distance)


func _move_toward_defense(_delta: float) -> void:
	var peer_id := int(actor.get("peer_id"))
	var destination := DEFENSE_POINTS[posmod(peer_id, DEFENSE_POINTS.size())]
	var offset := destination - actor.global_position
	var flat := Vector3(offset.x, 0.0, offset.z)
	if flat.length() < 1.5:
		var tangent := Vector3(cos(Time.get_ticks_msec() * 0.001), 0.0, sin(Time.get_ticks_msec() * 0.001))
		_set_horizontal_velocity(tangent * strafe_direction, float(actor.get("move_speed")) * 0.35)
	else:
		_aim_at(destination)
		_set_horizontal_velocity(_avoid_obstacles(_navigation_direction(destination)), float(actor.get("move_speed")))
		_try_jump_over_obstacle(flat.normalized())


func _set_horizontal_velocity(direction: Vector3, speed: float) -> void:
	if direction.length_squared() < 0.01:
		actor.velocity.x = move_toward(actor.velocity.x, 0.0, speed)
		actor.velocity.z = move_toward(actor.velocity.z, 0.0, speed)
		return
	actor.velocity.x = direction.x * speed
	actor.velocity.z = direction.z * speed


func _navigation_direction(destination: Vector3) -> Vector3:
	var direct := destination - actor.global_position
	direct.y = 0.0
	if navigation_agent == null or not navigation_agent.is_inside_tree():
		return direct.normalized()
	if navigation_agent.target_position.distance_squared_to(destination) > 0.5:
		navigation_agent.target_position = destination
	if navigation_agent.is_navigation_finished():
		return direct.normalized()
	var next_position := navigation_agent.get_next_path_position()
	var path_direction := next_position - actor.global_position
	path_direction.y = 0.0
	return path_direction.normalized() if path_direction.length_squared() > 0.01 else direct.normalized()


func _apply_gravity(delta: float) -> void:
	if not actor.is_on_floor():
		actor.velocity.y -= float(actor.get("gravity")) * delta


func _avoid_obstacles(direction: Vector3) -> Vector3:
	if direction.length_squared() < 0.01:
		return direction
	var origin := actor.global_position + Vector3.UP * 0.7
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 2.2)
	query.exclude = [actor.get_rid()]
	query.collision_mask = 1
	var result := actor.get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return direction
	var collider: Object = result.get("collider")
	if collider == target:
		return direction
	var side := direction.cross(Vector3.UP).normalized() * strafe_direction
	return (side + direction * 0.2).normalized()


func _try_jump_over_obstacle(direction: Vector3) -> void:
	if not actor.is_on_floor() or direction.length_squared() < 0.01:
		return
	var low_origin := actor.global_position + Vector3.UP * 0.35
	var high_origin := actor.global_position + Vector3.UP * 1.6
	var low_query := PhysicsRayQueryParameters3D.create(low_origin, low_origin + direction * 1.1)
	var high_query := PhysicsRayQueryParameters3D.create(high_origin, high_origin + direction * 1.1)
	low_query.exclude = [actor.get_rid()]
	high_query.exclude = [actor.get_rid()]
	low_query.collision_mask = 1
	high_query.collision_mask = 1
	if not actor.get_world_3d().direct_space_state.intersect_ray(low_query).is_empty() \
			and actor.get_world_3d().direct_space_state.intersect_ray(high_query).is_empty():
		actor.velocity.y = float(actor.get("zombie_jump_velocity" if bool(actor.get("is_zombie")) else "jump_velocity"))


func _has_line_of_sight(enemy: CharacterBody3D) -> bool:
	var origin := actor.global_position + Vector3.UP * 1.4
	var destination := enemy.global_position + Vector3.UP * 0.85
	var query := PhysicsRayQueryParameters3D.create(origin, destination)
	query.exclude = [actor.get_rid()]
	query.collision_mask = 3
	var result := actor.get_world_3d().direct_space_state.intersect_ray(query)
	return not result.is_empty() and result.get("collider") == enemy


func _aim_at(world_point: Vector3) -> void:
	var direction := (world_point - (actor.global_position + Vector3.UP * 1.55)).normalized()
	if direction.length_squared() < 0.01:
		return
	var desired_yaw := atan2(-direction.x, -direction.z)
	actor.rotation.y = lerp_angle(actor.rotation.y, desired_yaw, 0.22)
	var head: Node3D = actor.get_node("Head")
	head.rotation.x = lerp_angle(head.rotation.x, asin(clampf(direction.y, -1.0, 1.0)), 0.28)


func _fire_at_target(distance: float) -> void:
	var weapons: Node = actor.get_node("Head/WeaponSystem")
	var weapon_index := 2 if distance < 10.0 else 0
	weapons.call("switch_weapon", weapon_index)
	if not bool(weapons.call("shoot")):
		return
	shot_sequence += 1
	var weapon := weapons.call("get_current_weapon") as WeaponData
	var pellet_hits := 1
	if weapon.pellet_count > 1:
		var accuracy := clampf(1.0 - distance / weapon.range, 0.15, 0.85)
		pellet_hits = clampi(int(round(weapon.pellet_count * accuracy)), 1, weapon.pellet_count)
	GameManager.request_weapon_hit(
		int(target.get("peer_id")),
		weapon_index,
		target.global_position + Vector3.UP,
		pellet_hits,
		int(actor.get("peer_id")),
		shot_sequence
	)
