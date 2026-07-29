extends Resource
class_name WeaponData
## 武器数据资源

@export var weapon_name: String = "手枪"
@export var damage: float = 25.0
@export var fire_rate: float = 2.0          # 每秒射速
@export var magazine_size: int = 12
@export var reserve_ammo: int = 60
@export var reload_time: float = 1.8
@export var knockback: float = 3.0           # 击退力度
@export var is_automatic: bool = false
@export var spread: float = 0.02             # 散布（弧度）
@export var range: float = 100.0             # 射程
@export var pellet_count: int = 1
@export var recoil: float = 0.018
@export var bullet_trail_color: Color = Color.YELLOW

## 预定义武器
static func pistol() -> WeaponData:
	var w := WeaponData.new()
	w.weapon_name = "USP 手枪"
	w.damage = 22.0
	w.fire_rate = 3.0
	w.magazine_size = 12
	w.reserve_ammo = 60
	w.reload_time = 1.8
	w.knockback = 2.5
	w.is_automatic = false
	w.spread = 0.015
	w.range = 80.0
	w.pellet_count = 1
	w.recoil = 0.014
	w.bullet_trail_color = Color.YELLOW
	return w

static func ak47() -> WeaponData:
	var w := WeaponData.new()
	w.weapon_name = "AK-47"
	w.damage = 28.0
	w.fire_rate = 10.0
	w.magazine_size = 30
	w.reserve_ammo = 90
	w.reload_time = 2.7
	w.knockback = 4.5
	w.is_automatic = true
	w.spread = 0.025
	w.range = 120.0
	w.pellet_count = 1
	w.recoil = 0.032
	w.bullet_trail_color = Color.ORANGE
	return w

static func rifle() -> WeaponData:
	return ak47()

static func shotgun() -> WeaponData:
	var w := WeaponData.new()
	w.weapon_name = "M3 霰弹枪"
	w.damage = 12.0
	w.fire_rate = 1.0
	w.magazine_size = 8
	w.reserve_ammo = 32
	w.reload_time = 3.0
	w.knockback = 8.0
	w.is_automatic = false
	w.spread = 0.1
	w.range = 40.0
	w.pellet_count = 8
	w.recoil = 0.045
	w.bullet_trail_color = Color.RED
	return w

static func from_index(index: int) -> WeaponData:
	match index:
		0:
			return ak47()
		1:
			return pistol()
		2:
			return shotgun()
		_:
			return null
