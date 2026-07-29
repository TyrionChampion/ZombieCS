extends CharacterBody3D
## 本地权威角色控制、远端插值、射线武器和感染攻击。

signal health_changed(current: float, maximum: float)
signal role_changed(is_zombie: bool)
signal notification_requested(message: String)
signal hit_confirmed()

@export var move_speed := 5.0
@export var sprint_speed := 7.5
@export var jump_velocity := 4.5
@export var zombie_speed := 6.5
@export var zombie_jump_velocity := 5.5
@export var infection_cooldown := 0.8

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var is_zombie := false
var is_alive := true
var is_bot := false
var health := 100.0
var max_health := 100.0
var peer_id := 0
var infection_timer := 0.0
var _sync_timer := 0.0
var _remote_position := Vector3.ZERO
var _remote_yaw := 0.0
var _remote_pitch := 0.0
var _shot_sequence := 0

@onready var camera: Camera3D = $Head/Camera3D
@onready var head: Node3D = $Head
@onready var human_model: Node3D = $HumanModel
@onready var zombie_model: Node3D = $ZombieModel
@onready var attack_ray: RayCast3D = $Head/AttackRay
@onready var weapon_system: Node3D = $Head/WeaponSystem
@onready var bot_controller: Node = $BotController
@onready var zombie_hands: Node3D = $Head/ZombieFirstPersonHands
@onready var zombie_left_hand: Node3D = $Head/ZombieFirstPersonHands/LeftHand
@onready var zombie_right_hand: Node3D = $Head/ZombieFirstPersonHands/RightHand
@onready var zombie_attack_sound: AudioStreamPlayer = $Head/ZombieAttackSound
var _human_animation: AnimationPlayer
var _zombie_animation: AnimationPlayer
var _zombie_left_hand_base := Transform3D.IDENTITY
var _zombie_right_hand_base := Transform3D.IDENTITY
var _zombie_attack_time := 0.0
var _zombie_attacks_right := false
const ZOMBIE_ATTACK_ANIMATION_DURATION := 0.34


func _ready() -> void:
	add_to_group("players")
	if peer_id <= 0:
		peer_id = get_multiplayer_authority()
	_remote_position = global_position
	_remote_yaw = rotation.y
	_remote_pitch = head.rotation.x

	if is_multiplayer_authority() and not is_bot:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		camera.current = true
	else:
		camera.current = false
		camera.queue_free()

	GameManager.zombie_chosen.connect(_on_zombie_chosen)
	GameManager.player_infected.connect(_on_player_infected)
	GameManager.player_health_changed.connect(_on_player_health_changed)
	GameManager.player_died.connect(_on_player_died)
	GameManager.player_respawned.connect(_on_player_respawned)
	GameManager.player_reset.connect(_on_player_reset)
	GameManager.game_over.connect(_on_game_over)
	weapon_system.connect("shot_fired", _on_shot_fired)
	var human_players := human_model.find_children("*", "AnimationPlayer", true, false)
	var zombie_players := zombie_model.find_children("*", "AnimationPlayer", true, false)
	if not human_players.is_empty():
		_human_animation = human_players[0] as AnimationPlayer
	if not zombie_players.is_empty():
		_zombie_animation = zombie_players[0] as AnimationPlayer
	_zombie_left_hand_base = zombie_left_hand.transform
	_zombie_right_hand_base = zombie_right_hand.transform
	if zombie_attack_sound.stream == null:
		zombie_attack_sound.stream = _make_zombie_attack_sound()
	_update_appearance()


func _process(delta: float) -> void:
	_update_model_animation()
	_update_zombie_attack_animation(delta)


func _input(event: InputEvent) -> void:
	if is_bot or not is_multiplayer_authority() or not is_alive:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventMouseButton and event.pressed and Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var sensitivity := SettingsManager.get_effective_mouse_sensitivity()
		rotate_y(-event.relative.x * sensitivity)
		head.rotate_x(-event.relative.y * sensitivity)
		head.rotation.x = clampf(head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))

	if is_zombie:
		return
	if event.is_action_pressed("weapon_1"):
		weapon_system.call("switch_weapon", 0)
	elif event.is_action_pressed("weapon_2"):
		weapon_system.call("switch_weapon", 1)
	elif event.is_action_pressed("weapon_3"):
		weapon_system.call("switch_weapon", 2)
	elif event.is_action_pressed("player_reload"):
		weapon_system.call("start_reload")


func _physics_process(delta: float) -> void:
	infection_timer = maxf(0.0, infection_timer - delta)
	if not is_multiplayer_authority():
		global_position = global_position.lerp(_remote_position, minf(1.0, delta * 14.0))
		rotation.y = lerp_angle(rotation.y, _remote_yaw, minf(1.0, delta * 14.0))
		head.rotation.x = lerp_angle(head.rotation.x, _remote_pitch, minf(1.0, delta * 14.0))
		return
	if is_bot:
		if is_alive and GameManager.state == GameManager.GameState.PLAYING:
			bot_controller.call("tick", delta)
		else:
			velocity = Vector3.ZERO
		_sync_transform_if_due(delta)
		return
	if not is_alive or GameManager.state != GameManager.GameState.PLAYING:
		velocity = Vector3.ZERO
		return

	if not is_on_floor():
		velocity.y -= gravity * delta
	if Input.is_action_just_pressed("player_jump") and is_on_floor():
		velocity.y = zombie_jump_velocity if is_zombie else jump_velocity

	var input_dir := Input.get_vector("player_left", "player_right", "player_forward", "player_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var speed := zombie_speed if is_zombie else (sprint_speed if Input.is_action_pressed("player_sprint") else move_speed)
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)
	move_and_slide()

	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if is_zombie:
			_zombie_attack()
		else:
			_human_shoot()

	_sync_transform_if_due(delta)


func _sync_transform_if_due(delta: float) -> void:
	_sync_timer += delta
	var interval := 0.1 if is_bot else 0.05
	if _sync_timer >= interval:
		_sync_timer = 0.0
		rpc("_receive_transform", global_position, rotation.y, head.rotation.x)


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_transform(new_position: Vector3, yaw: float, pitch: float) -> void:
	_remote_position = new_position
	_remote_yaw = yaw
	_remote_pitch = pitch


func _zombie_attack() -> void:
	if not Input.is_action_pressed("attack") or infection_timer > 0.0:
		return
	_perform_zombie_attack()


func _perform_zombie_attack() -> void:
	infection_timer = infection_cooldown
	_play_zombie_attack_feedback()
	var target := _find_zombie_attack_target()
	if target != null:
		GameManager.request_infection(int(target.get("peer_id")), peer_id)


func _find_zombie_attack_target() -> CharacterBody3D:
	var nearest: CharacterBody3D
	var nearest_distance := INF
	var forward := -head.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	for node: Node in get_tree().get_nodes_in_group("players"):
		if node == self or not node is CharacterBody3D:
			continue
		if bool(node.get("is_zombie")) or not bool(node.get("is_alive")):
			continue
		var target := node as CharacterBody3D
		var offset := target.global_position - global_position
		var flat_offset := Vector3(offset.x, 0.0, offset.z)
		var distance := flat_offset.length()
		if distance > 3.0 or distance >= nearest_distance or distance < 0.01:
			continue
		if forward.dot(flat_offset / distance) < 0.45:
			continue
		var origin := global_position + Vector3.UP * 1.4
		var destination := target.global_position + Vector3.UP * 0.85
		var query := PhysicsRayQueryParameters3D.create(origin, destination)
		query.exclude = [get_rid()]
		query.collision_mask = 3
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty() and hit.get("collider") == target:
			nearest = target
			nearest_distance = distance
	return nearest


func _human_shoot() -> void:
	var weapon := weapon_system.call("get_current_weapon") as WeaponData
	if weapon == null:
		return
	var wants_shot := Input.is_action_pressed("attack") if weapon.is_automatic else Input.is_action_just_pressed("attack")
	if not wants_shot or not bool(weapon_system.call("shoot")):
		return
	_shot_sequence += 1

	var hit_counts: Dictionary = {}
	var hit_positions: Dictionary = {}
	var space := get_world_3d().direct_space_state
	for pellet_index in range(weapon.pellet_count):
		var direction := -camera.global_basis.z
		direction = direction.rotated(camera.global_basis.x, randf_range(-weapon.spread, weapon.spread))
		direction = direction.rotated(camera.global_basis.y, randf_range(-weapon.spread, weapon.spread)).normalized()
		var origin := camera.global_position
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * weapon.range)
		query.exclude = [get_rid()]
		query.collision_mask = 3
		var result := space.intersect_ray(query)
		if result.is_empty():
			if pellet_index == 0:
				_spawn_tracer(origin, origin + direction * weapon.range, weapon.bullet_trail_color)
			continue
		var impact_position: Vector3 = result.get("position", origin + direction * weapon.range)
		if pellet_index == 0:
			_spawn_tracer(origin, impact_position, weapon.bullet_trail_color)
			_spawn_impact(impact_position)
		var target: Object = result.get("collider")
		if target is CharacterBody3D:
			var target_id := int(target.get("peer_id"))
			hit_counts[target_id] = int(hit_counts.get(target_id, 0)) + 1
			hit_positions[target_id] = impact_position

	for target_id: int in hit_counts:
		hit_confirmed.emit()
		GameManager.request_weapon_hit(
			target_id,
			int(weapon_system.call("get_current_weapon_index")),
			hit_positions[target_id],
			hit_counts[target_id],
			peer_id,
			_shot_sequence
		)


func _on_shot_fired() -> void:
	if not is_multiplayer_authority():
		return
	rpc("_play_remote_shot_feedback")
	if is_bot:
		return
	var weapon := weapon_system.call("get_current_weapon") as WeaponData
	if weapon == null:
		return
	head.rotation.x = clampf(
		head.rotation.x + weapon.recoil,
		deg_to_rad(-89.0),
		deg_to_rad(89.0)
	)
	rotation.y += randf_range(-weapon.recoil * 0.25, weapon.recoil * 0.25)


@rpc("authority", "call_remote", "unreliable")
func _play_remote_shot_feedback() -> void:
	weapon_system.call("play_remote_shot_feedback")


func _spawn_tracer(start: Vector3, finish: Vector3, color: Color) -> void:
	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	immediate.surface_set_color(color)
	immediate.surface_add_vertex(start)
	immediate.surface_set_color(color)
	immediate.surface_add_vertex(finish)
	immediate.surface_end()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	var tracer := MeshInstance3D.new()
	tracer.mesh = immediate
	tracer.material_override = material
	get_tree().current_scene.add_child(tracer)
	await get_tree().create_timer(0.075).timeout
	if is_instance_valid(tracer):
		tracer.queue_free()


func _spawn_impact(position: Vector3) -> void:
	var impact_mesh := SphereMesh.new()
	impact_mesh.radius = 0.035
	impact_mesh.height = 0.07
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.72, 0.2)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.35, 0.05)
	var impact := MeshInstance3D.new()
	impact.mesh = impact_mesh
	impact.material_override = material
	impact.global_position = position
	get_tree().current_scene.add_child(impact)
	await get_tree().create_timer(0.22).timeout
	if is_instance_valid(impact):
		impact.queue_free()


func _on_zombie_chosen(pid: int, _player_name: String) -> void:
	if pid == peer_id:
		set_zombie(true)


func _on_player_infected(pid: int, _attacker_id: int) -> void:
	if pid == peer_id:
		set_zombie(true)


func _on_player_health_changed(pid: int, new_health: float, new_max: float, hit_pos: Vector3, knockback: float) -> void:
	if pid != peer_id:
		return
	health = new_health
	max_health = new_max
	health_changed.emit(health, max_health)
	if is_multiplayer_authority() and knockback > 0.0:
		var direction := (global_position - hit_pos).normalized()
		direction.y = maxf(direction.y, 0.25)
		velocity += direction.normalized() * knockback


func _on_player_died(pid: int) -> void:
	if pid != peer_id:
		return
	is_alive = false
	visible = false
	$CollisionShape3D.set_deferred("disabled", true)
	if is_multiplayer_authority() and not is_bot:
		notification_requested.emit("你被击倒，3 秒后重生")


func _on_player_respawned(pid: int, new_health: float) -> void:
	if pid != peer_id:
		return
	is_alive = true
	health = new_health
	max_health = GameManager.ZOMBIE_HEALTH
	visible = true
	$CollisionShape3D.set_deferred("disabled", false)
	health_changed.emit(health, max_health)


func _on_player_reset(pid: int, new_health: float) -> void:
	if pid != peer_id:
		return
	is_alive = true
	health = new_health
	max_health = GameManager.HUMAN_HEALTH
	set_zombie(false)
	visible = true
	$CollisionShape3D.set_deferred("disabled", false)
	weapon_system.call("reset_ammo")
	health_changed.emit(health, max_health)


func reset_for_round(spawn_position: Vector3) -> void:
	global_position = spawn_position
	_remote_position = spawn_position
	velocity = Vector3.ZERO


func set_zombie(value: bool) -> void:
	is_zombie = value
	max_health = GameManager.ZOMBIE_HEALTH if value else GameManager.HUMAN_HEALTH
	health = max_health
	_update_appearance()
	role_changed.emit(is_zombie)
	health_changed.emit(health, max_health)


func _update_appearance() -> void:
	if not is_node_ready():
		return
	var show_third_person := is_bot or not is_multiplayer_authority()
	human_model.visible = show_third_person and not is_zombie
	zombie_model.visible = show_third_person and is_zombie
	zombie_hands.visible = is_multiplayer_authority() and not is_bot and is_zombie
	weapon_system.visible = not is_zombie and is_multiplayer_authority() and not is_bot


func _update_model_animation() -> void:
	var animation_player := _zombie_animation if is_zombie else _human_animation
	if animation_player == null:
		return
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var requested := "Idle"
	if horizontal_speed > 0.35:
		if is_zombie:
			requested = "Run_Arms" if horizontal_speed > 5.5 else "Walk"
		else:
			requested = "Run_Gun" if horizontal_speed > 6.0 else "Walk_Gun"
	elif not is_zombie:
		requested = "Idle_Gun"
	if animation_player.has_animation(requested) and animation_player.current_animation != requested:
		animation_player.play(requested, 0.18)


func _play_zombie_attack_feedback() -> void:
	_zombie_attacks_right = not _zombie_attacks_right
	_zombie_attack_time = ZOMBIE_ATTACK_ANIMATION_DURATION
	zombie_attack_sound.pitch_scale = randf_range(0.9, 1.08)
	zombie_attack_sound.play()


func _update_zombie_attack_animation(delta: float) -> void:
	zombie_left_hand.transform = _zombie_left_hand_base
	zombie_right_hand.transform = _zombie_right_hand_base
	if _zombie_attack_time <= 0.0:
		return
	_zombie_attack_time = maxf(0.0, _zombie_attack_time - delta)
	var progress := 1.0 - _zombie_attack_time / ZOMBIE_ATTACK_ANIMATION_DURATION
	var thrust := sin(progress * PI)
	var attacking_hand := zombie_right_hand if _zombie_attacks_right else zombie_left_hand
	var base := _zombie_right_hand_base if _zombie_attacks_right else _zombie_left_hand_base
	attacking_hand.position = base.origin + Vector3(
		-0.08 * thrust if _zombie_attacks_right else 0.08 * thrust,
		0.1 * thrust,
		-0.42 * thrust
	)
	var base_rotation := base.basis.get_euler()
	attacking_hand.rotation = base_rotation + Vector3(
		deg_to_rad(-38.0) * thrust,
		deg_to_rad(8.0 if _zombie_attacks_right else -8.0) * thrust,
		deg_to_rad(-18.0 if _zombie_attacks_right else 18.0) * thrust
	)


func _make_zombie_attack_sound() -> AudioStreamWAV:
	var sample_rate := 22050
	var duration := 0.24
	var sample_count := int(sample_rate * duration)
	var bytes := PackedByteArray()
	var noise := RandomNumberGenerator.new()
	noise.seed = 131313
	bytes.resize(sample_count * 2)
	for i in range(sample_count):
		var time := float(i) / float(sample_rate)
		var envelope := exp(-time * 10.0)
		var growl := sin(TAU * (72.0 - time * 45.0) * time)
		var scrape := noise.randf_range(-1.0, 1.0)
		var value := clampf((growl * 0.62 + scrape * 0.38) * envelope * 0.75, -1.0, 1.0)
		bytes.encode_s16(i * 2, int(value * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = bytes
	return stream


func _on_game_over(_winner: String) -> void:
	if is_multiplayer_authority() and not is_bot:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
