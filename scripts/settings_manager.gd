extends Node
## Local display, audio, and control settings persisted in user://settings.cfg.

signal settings_changed()

const CONFIG_PATH := "user://settings.cfg"
const BASE_MOUSE_SENSITIVITY := 0.002
const RESOLUTION_PRESETS := [
	Vector2i(1024, 576),
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]

enum DisplayMode {
	WINDOWED,
	BORDERLESS,
	EXCLUSIVE_FULLSCREEN,
}

var resolution := Vector2i(1280, 720)
var display_mode := DisplayMode.WINDOWED
var vsync_enabled := true
var max_fps := 0
var master_volume := 0.85
var effects_volume := 0.9
var mouse_sensitivity := 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_audio_buses()
	load_settings()
	apply_settings()


func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	resolution = _sanitize_resolution(config.get_value("display", "resolution", resolution))
	display_mode = clampi(int(config.get_value("display", "mode", display_mode)), DisplayMode.WINDOWED, DisplayMode.EXCLUSIVE_FULLSCREEN)
	vsync_enabled = bool(config.get_value("display", "vsync", vsync_enabled))
	max_fps = maxi(0, int(config.get_value("display", "max_fps", max_fps)))
	master_volume = clampf(float(config.get_value("audio", "master_volume", master_volume)), 0.0, 1.0)
	effects_volume = clampf(float(config.get_value("audio", "effects_volume", effects_volume)), 0.0, 1.0)
	mouse_sensitivity = clampf(float(config.get_value("controls", "mouse_sensitivity", mouse_sensitivity)), 0.25, 3.0)


func save_settings() -> Error:
	var config := ConfigFile.new()
	config.set_value("display", "resolution", resolution)
	config.set_value("display", "mode", display_mode)
	config.set_value("display", "vsync", vsync_enabled)
	config.set_value("display", "max_fps", max_fps)
	config.set_value("audio", "master_volume", master_volume)
	config.set_value("audio", "effects_volume", effects_volume)
	config.set_value("controls", "mouse_sensitivity", mouse_sensitivity)
	return config.save(CONFIG_PATH)


func set_settings(
	new_resolution: Vector2i,
	new_display_mode: int,
	new_vsync: bool,
	new_max_fps: int,
	new_master_volume: float,
	new_effects_volume: float,
	new_mouse_sensitivity: float,
	persist: bool = true
) -> void:
	resolution = _sanitize_resolution(new_resolution)
	display_mode = clampi(new_display_mode, DisplayMode.WINDOWED, DisplayMode.EXCLUSIVE_FULLSCREEN)
	vsync_enabled = new_vsync
	max_fps = maxi(0, new_max_fps)
	master_volume = clampf(new_master_volume, 0.0, 1.0)
	effects_volume = clampf(new_effects_volume, 0.0, 1.0)
	mouse_sensitivity = clampf(new_mouse_sensitivity, 0.25, 3.0)
	apply_settings()
	if persist:
		save_settings()
	settings_changed.emit()


func reset_to_defaults(persist: bool = true) -> void:
	set_settings(Vector2i(1280, 720), DisplayMode.WINDOWED, true, 0, 0.85, 0.9, 1.0, persist)


func apply_settings() -> void:
	Engine.max_fps = max_fps
	_apply_audio()
	if DisplayServer.get_name().to_lower() == "headless":
		return
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync_enabled else DisplayServer.VSYNC_DISABLED
	)
	match display_mode:
		DisplayMode.WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_size(resolution)
			_center_window()
		DisplayMode.BORDERLESS:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		DisplayMode.EXCLUSIVE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)


func get_available_resolutions() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var screen_size := Vector2i(3840, 2160)
	if DisplayServer.get_name().to_lower() != "headless":
		screen_size = DisplayServer.screen_get_size()
	for preset: Vector2i in RESOLUTION_PRESETS:
		if preset.x <= screen_size.x and preset.y <= screen_size.y:
			result.append(preset)
	if resolution not in result:
		result.append(resolution)
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x * a.y < b.x * b.y)
	return result


func get_refresh_rate() -> float:
	if DisplayServer.get_name().to_lower() == "headless":
		return 0.0
	return DisplayServer.screen_get_refresh_rate()


func get_effective_mouse_sensitivity() -> float:
	return BASE_MOUSE_SENSITIVITY * mouse_sensitivity


func _sanitize_resolution(value: Variant) -> Vector2i:
	var candidate := Vector2i(1280, 720)
	if value is Vector2i:
		candidate = value
	elif value is Vector2:
		candidate = Vector2i(value)
	candidate.x = clampi(candidate.x, 800, 7680)
	candidate.y = clampi(candidate.y, 450, 4320)
	return candidate


func _ensure_audio_buses() -> void:
	if AudioServer.get_bus_index("SFX") < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, "SFX")


func _apply_audio() -> void:
	_set_bus_linear_volume("Master", master_volume)
	_set_bus_linear_volume("SFX", effects_volume)


func _set_bus_linear_volume(bus_name: String, volume: float) -> void:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return
	AudioServer.set_bus_mute(bus_index, volume <= 0.001)
	AudioServer.set_bus_volume_db(bus_index, linear_to_db(maxf(volume, 0.001)))


func _center_window() -> void:
	var screen := DisplayServer.window_get_current_screen()
	var screen_position := DisplayServer.screen_get_position(screen)
	var screen_size := DisplayServer.screen_get_size(screen)
	DisplayServer.window_set_position(screen_position + (screen_size - resolution) / 2)
