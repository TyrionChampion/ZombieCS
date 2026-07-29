extends Control
## CS-style center damage ring with an arrow pointing toward the shot source.

var _source_angle := 0.0
var _life := 0.0
const DISPLAY_TIME := 0.72


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_process(false)


func show_hit(source_angle: float) -> void:
	_source_angle = source_angle
	_life = DISPLAY_TIME
	visible = true
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	_life = maxf(0.0, _life - delta)
	if _life <= 0.0:
		visible = false
		set_process(false)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var alpha := clampf(_life / DISPLAY_TIME, 0.0, 1.0)
	var ring_color := Color(0.95, 0.08, 0.06, 0.32 * alpha)
	var bright_color := Color(1.0, 0.16, 0.1, 0.95 * alpha)
	draw_arc(center, 52.0, 0.0, TAU, 64, ring_color, 5.0, true)
	draw_arc(center, 61.0, 0.0, TAU, 64, Color(0.7, 0.0, 0.0, 0.18 * alpha), 2.0, true)

	var direction := Vector2(sin(_source_angle), -cos(_source_angle))
	var tangent := Vector2(-direction.y, direction.x)
	var arrow_tip := center + direction * 82.0
	var arrow_base := center + direction * 59.0
	var arrow := PackedVector2Array([
		arrow_tip,
		arrow_base + tangent * 12.0,
		arrow_base - tangent * 12.0,
	])
	draw_colored_polygon(arrow, bright_color)
