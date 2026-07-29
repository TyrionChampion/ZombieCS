extends Control
## Main menu and local settings UI.

@onready var menu_panel: Panel = $MenuPanel
@onready var host_button: Button = $MenuPanel/Margin/VBox/HostButton
@onready var join_button: Button = $MenuPanel/Margin/VBox/JoinButton
@onready var address_input: LineEdit = $MenuPanel/Margin/VBox/AddressInput
@onready var name_input: LineEdit = $MenuPanel/Margin/VBox/NameInput
@onready var status_label: Label = $MenuPanel/Margin/VBox/StatusLabel
@onready var settings_overlay: Control = $SettingsOverlay
@onready var resolution_option: OptionButton = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/ResolutionOption
@onready var display_mode_option: OptionButton = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/DisplayModeOption
@onready var refresh_value: Label = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/RefreshValue
@onready var vsync_check: CheckButton = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/VsyncCheck
@onready var fps_option: OptionButton = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/FpsOption
@onready var master_slider: HSlider = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/MasterRow/MasterSlider
@onready var master_value: Label = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/MasterRow/MasterValue
@onready var effects_slider: HSlider = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/EffectsRow/EffectsSlider
@onready var effects_value: Label = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/EffectsRow/EffectsValue
@onready var sensitivity_slider: HSlider = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/SensitivityRow/SensitivitySlider
@onready var sensitivity_value: Label = $SettingsOverlay/Center/Panel/Margin/VBox/Grid/SensitivityRow/SensitivityValue

var _fps_values: Array[int] = []


func _ready() -> void:
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.server_started.connect(_on_server_started)
	name_input.text = "玩家" + str(randi() % 1000)
	master_slider.value_changed.connect(_update_slider_labels)
	effects_slider.value_changed.connect(_update_slider_labels)
	sensitivity_slider.value_changed.connect(_update_slider_labels)
	_populate_settings()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and settings_overlay.visible:
		_close_settings()
		get_viewport().set_input_as_handled()


func _populate_settings() -> void:
	resolution_option.clear()
	var resolutions := SettingsManager.get_available_resolutions()
	for value: Vector2i in resolutions:
		resolution_option.add_item("%d × %d" % [value.x, value.y])
		resolution_option.set_item_metadata(resolution_option.item_count - 1, value)
		if value == SettingsManager.resolution:
			resolution_option.select(resolution_option.item_count - 1)

	display_mode_option.clear()
	display_mode_option.add_item("窗口模式", SettingsManager.DisplayMode.WINDOWED)
	display_mode_option.add_item("无边框全屏", SettingsManager.DisplayMode.BORDERLESS)
	display_mode_option.add_item("独占全屏", SettingsManager.DisplayMode.EXCLUSIVE_FULLSCREEN)
	display_mode_option.select(SettingsManager.display_mode)

	var refresh_rate := SettingsManager.get_refresh_rate()
	refresh_value.text = "%.0f Hz（由 Windows 管理）" % refresh_rate if refresh_rate > 1.0 else "无法检测"
	vsync_check.button_pressed = SettingsManager.vsync_enabled
	_populate_fps_options(refresh_rate)
	master_slider.value = SettingsManager.master_volume * 100.0
	effects_slider.value = SettingsManager.effects_volume * 100.0
	sensitivity_slider.value = SettingsManager.mouse_sensitivity
	_update_slider_labels(0.0)


func _populate_fps_options(refresh_rate: float) -> void:
	_fps_values = [0, 60, 90, 120, 144, 165, 240]
	var detected := int(round(refresh_rate))
	if detected > 30 and detected not in _fps_values:
		_fps_values.append(detected)
		_fps_values.sort()
	fps_option.clear()
	for value: int in _fps_values:
		fps_option.add_item("不限制" if value == 0 else "%d FPS" % value)
		if value == SettingsManager.max_fps:
			fps_option.select(fps_option.item_count - 1)


func _update_slider_labels(_unused: float) -> void:
	master_value.text = "%d%%" % int(round(master_slider.value))
	effects_value.text = "%d%%" % int(round(effects_slider.value))
	sensitivity_value.text = "%.1fx" % sensitivity_slider.value


func _on_host_button_pressed() -> void:
	host_button.disabled = true
	join_button.disabled = true
	status_label.text = "正在创建房间……"
	NetworkManager.host_game(name_input.text.strip_edges())


func _on_join_button_pressed() -> void:
	var address := address_input.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	host_button.disabled = true
	join_button.disabled = true
	status_label.text = "正在连接 %s……" % address
	NetworkManager.join_game(address, name_input.text.strip_edges())


func _on_settings_button_pressed() -> void:
	_populate_settings()
	settings_overlay.visible = true
	menu_panel.visible = false


func _on_apply_settings_pressed() -> void:
	var resolution_index := resolution_option.selected
	var selected_resolution: Vector2i = resolution_option.get_item_metadata(resolution_index)
	var fps_index := fps_option.selected
	var selected_fps := _fps_values[fps_index] if fps_index >= 0 and fps_index < _fps_values.size() else 0
	SettingsManager.set_settings(
		selected_resolution,
		display_mode_option.get_selected_id(),
		vsync_check.button_pressed,
		selected_fps,
		master_slider.value / 100.0,
		effects_slider.value / 100.0,
		sensitivity_slider.value
	)
	status_label.text = "设置已保存"
	_close_settings()


func _on_reset_settings_pressed() -> void:
	resolution_option.select(_find_resolution(Vector2i(1280, 720)))
	display_mode_option.select(SettingsManager.DisplayMode.WINDOWED)
	vsync_check.button_pressed = true
	fps_option.select(_fps_values.find(0))
	master_slider.value = 85.0
	effects_slider.value = 90.0
	sensitivity_slider.value = 1.0
	_update_slider_labels(0.0)


func _find_resolution(value: Vector2i) -> int:
	for index in range(resolution_option.item_count):
		if resolution_option.get_item_metadata(index) == value:
			return index
	return 0


func _on_close_settings_pressed() -> void:
	_close_settings()


func _close_settings() -> void:
	settings_overlay.visible = false
	menu_panel.visible = true


func _on_server_started() -> void:
	_go_to_lobby()


func _on_connection_succeeded() -> void:
	_go_to_lobby()


func _on_connection_failed(reason: String) -> void:
	host_button.disabled = false
	join_button.disabled = false
	status_label.text = "错误：" + reason


func _go_to_lobby() -> void:
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")
