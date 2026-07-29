extends Node3D
## 三把独立保存弹药的原型武器，并生成轻量占位音效。

signal ammo_changed(current: int, reserve: int)
signal weapon_changed(weapon_name: String)
signal shot_fired()

@export var weapons: Array[WeaponData] = []

var current_weapon_index := 0
var magazine_ammo: Array[int] = []
var reserve_ammo: Array[int] = []
var fire_timer := 0.0
var reload_timer := 0.0
var is_reloading := false

@onready var muzzle_flash: MeshInstance3D = $MuzzleFlash
@onready var fire_sound: AudioStreamPlayer3D = $FireSound
@onready var reload_sound: AudioStreamPlayer3D = $ReloadSound
@onready var gun_model: Node3D = $GunModel

var _gun_base_position := Vector3.ZERO
var _gun_base_rotation := Vector3.ZERO


func _ready() -> void:
	if weapons.is_empty():
		weapons.assign([WeaponData.pistol(), WeaponData.rifle(), WeaponData.shotgun()])
	_initialize_ammo()
	if fire_sound.stream == null:
		fire_sound.stream = _make_tone(110.0, 0.055, 0.42)
	if reload_sound.stream == null:
		reload_sound.stream = _make_tone(520.0, 0.1, 0.2)
	_gun_base_position = gun_model.position
	_gun_base_rotation = gun_model.rotation
	_emit_current_state()


func _process(delta: float) -> void:
	fire_timer = maxf(0.0, fire_timer - delta)
	if is_reloading:
		reload_timer -= delta
		if reload_timer <= 0.0:
			_finish_reload()
	if muzzle_flash.visible:
		muzzle_flash.visible = false
	gun_model.position = gun_model.position.lerp(_gun_base_position, minf(1.0, delta * 18.0))
	gun_model.rotation = gun_model.rotation.lerp(_gun_base_rotation, minf(1.0, delta * 20.0))


func _initialize_ammo() -> void:
	magazine_ammo.clear()
	reserve_ammo.clear()
	for weapon: WeaponData in weapons:
		magazine_ammo.append(weapon.magazine_size)
		reserve_ammo.append(weapon.reserve_ammo)


func reset_ammo() -> void:
	_initialize_ammo()
	current_weapon_index = 0
	is_reloading = false
	reload_timer = 0.0
	_emit_current_state()


func get_current_weapon() -> WeaponData:
	return weapons[current_weapon_index] if not weapons.is_empty() else null


func get_current_weapon_index() -> int:
	return current_weapon_index


func get_current_weapon_name() -> String:
	var weapon := get_current_weapon()
	return weapon.weapon_name if weapon != null else ""


func get_current_ammo() -> int:
	return magazine_ammo[current_weapon_index] if not magazine_ammo.is_empty() else 0


func get_reserve_ammo() -> int:
	return reserve_ammo[current_weapon_index] if not reserve_ammo.is_empty() else 0


func shoot() -> bool:
	if is_reloading or fire_timer > 0.0:
		return false
	if get_current_ammo() <= 0:
		start_reload()
		return false
	var weapon := get_current_weapon()
	if weapon == null:
		return false

	magazine_ammo[current_weapon_index] -= 1
	fire_timer = 1.0 / maxf(0.1, weapon.fire_rate)
	ammo_changed.emit(get_current_ammo(), get_reserve_ammo())
	muzzle_flash.visible = true
	gun_model.position.z += 0.07
	gun_model.rotation.x += 0.045
	fire_sound.pitch_scale = randf_range(0.94, 1.06)
	fire_sound.play()
	shot_fired.emit()
	if get_current_ammo() <= 0:
		start_reload()
	return true


func start_reload() -> void:
	var weapon := get_current_weapon()
	if weapon == null or is_reloading or get_reserve_ammo() <= 0 or get_current_ammo() >= weapon.magazine_size:
		return
	is_reloading = true
	reload_timer = weapon.reload_time
	reload_sound.play()


func _finish_reload() -> void:
	is_reloading = false
	var weapon := get_current_weapon()
	var needed := weapon.magazine_size - get_current_ammo()
	var amount := mini(needed, get_reserve_ammo())
	magazine_ammo[current_weapon_index] += amount
	reserve_ammo[current_weapon_index] -= amount
	ammo_changed.emit(get_current_ammo(), get_reserve_ammo())


func switch_weapon(index: int) -> void:
	if is_reloading or index == current_weapon_index or index < 0 or index >= weapons.size():
		return
	current_weapon_index = index
	fire_timer = 0.0
	_emit_current_state()


func _emit_current_state() -> void:
	var weapon := get_current_weapon()
	if weapon == null:
		return
	weapon_changed.emit(weapon.weapon_name)
	ammo_changed.emit(get_current_ammo(), get_reserve_ammo())


func _make_tone(frequency: float, duration: float, volume: float) -> AudioStreamWAV:
	var sample_rate := 22050
	var sample_count := int(sample_rate * duration)
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	for i in range(sample_count):
		var envelope := 1.0 - float(i) / float(sample_count)
		var value := sin(TAU * frequency * float(i) / float(sample_rate))
		bytes.encode_s16(i * 2, int(value * envelope * volume * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = bytes
	return stream
