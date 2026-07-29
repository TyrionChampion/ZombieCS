extends Node
## Headless validation for settings values and menu controls.

var failures: Array[String] = []


func _ready() -> void:
	var previous := {
		"resolution": SettingsManager.resolution,
		"mode": SettingsManager.display_mode,
		"vsync": SettingsManager.vsync_enabled,
		"max_fps": SettingsManager.max_fps,
		"master": SettingsManager.master_volume,
		"effects": SettingsManager.effects_volume,
		"sensitivity": SettingsManager.mouse_sensitivity,
	}

	_check(not SettingsManager.get_available_resolutions().is_empty(), "No resolution presets were returned")
	_check(AudioServer.get_bus_index("SFX") >= 0, "SFX audio bus was not created")
	SettingsManager.set_settings(
		Vector2i(1600, 900),
		SettingsManager.DisplayMode.BORDERLESS,
		false,
		144,
		0.5,
		0.4,
		1.75,
		false
	)
	_check(SettingsManager.resolution == Vector2i(1600, 900), "Resolution setting was not stored")
	_check(SettingsManager.display_mode == SettingsManager.DisplayMode.BORDERLESS, "Display mode was not stored")
	_check(Engine.max_fps == 144, "FPS limit was not applied")
	_check(is_equal_approx(SettingsManager.get_effective_mouse_sensitivity(), 0.0035), "Mouse sensitivity was not applied")

	var menu: Node = load("res://scenes/main_menu.tscn").instantiate()
	add_child(menu)
	await get_tree().process_frame
	var resolution_option := menu.get_node_or_null("SettingsOverlay/Center/Panel/Margin/VBox/Grid/ResolutionOption") as OptionButton
	var fps_option := menu.get_node_or_null("SettingsOverlay/Center/Panel/Margin/VBox/Grid/FpsOption") as OptionButton
	_check(menu.get_node_or_null("MenuPanel/Margin/VBox/SettingsButton") != null, "Settings button is missing")
	_check(resolution_option != null and resolution_option.item_count > 0, "Resolution selector is empty")
	_check(fps_option != null and fps_option.item_count > 0, "FPS selector is empty")
	menu.queue_free()

	SettingsManager.set_settings(
		previous.resolution,
		previous.mode,
		previous.vsync,
		previous.max_fps,
		previous.master,
		previous.effects,
		previous.sensitivity,
		false
	)
	if failures.is_empty():
		print("SETTINGS_TEST_OK")
		get_tree().quit(0)
	else:
		for message in failures:
			push_error(message)
		get_tree().quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
