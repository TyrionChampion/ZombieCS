extends Control
## 大厅 UI — 玩家列表、开始游戏

@onready var player_list: ItemList = $Panel/VBoxContainer/PlayerList
@onready var start_button: Button = $Panel/VBoxContainer/StartButton
@onready var status_label: Label = $Panel/VBoxContainer/StatusLabel
@onready var back_button: Button = $Panel/VBoxContainer/BackButton


func _ready() -> void:
	if not NetworkManager.is_host:
		start_button.visible = false
	else:
		start_button.visible = true

	update_status()
	NetworkManager.player_joined.connect(_on_player_joined)
	NetworkManager.player_left.connect(_on_player_left)
	GameManager.state_changed.connect(_on_game_state_changed)
	GameManager.countdown_updated.connect(_on_countdown)
	refresh_list()


func update_status() -> void:
	var count: int = NetworkManager.players.size()
	status_label.text = "房间中: %d/%d 人" % [count, NetworkManager.MAX_PLAYERS]
	start_button.disabled = false  # 允许单人测试


func _on_player_joined(_pid: int, _pname: String) -> void:
	refresh_list()
	update_status()


func _on_player_left(_pid: int) -> void:
	refresh_list()
	update_status()


func refresh_list() -> void:
	player_list.clear()
	for pid: int in NetworkManager.players:
		var info: Dictionary = NetworkManager.players[pid]
		var tag: String = " [僵尸]" if info["is_zombie"] else ""
		tag += " [AI]" if info.get("is_bot", false) else ""
		tag += " (房主)" if pid == 1 else ""
		player_list.add_item(info["name"] + tag)


func _on_start_button_pressed() -> void:
	if NetworkManager.is_host:
		GameManager.start_game()


func _on_back_button_pressed() -> void:
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_game_state_changed(new_state: int) -> void:
	match new_state:
		GameManager.GameState.COUNTDOWN:
			start_button.disabled = true
		GameManager.GameState.PLAYING:
			get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_countdown(seconds: int) -> void:
	status_label.text = "游戏即将开始: %d 秒" % seconds
