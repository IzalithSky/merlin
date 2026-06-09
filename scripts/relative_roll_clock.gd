extends Control

@export var clock_radius: float = 28.0
@export var needle_width: float = 2.0

var roll_error := 0.0:
	set(value):
		roll_error = value
		queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(clock_radius, minf(size.x, size.y) * 0.5)

	draw_arc(center, radius, 0.0, TAU, 64, Color.WHITE, 1.0)

	var twelve_position := center + Vector2(0.0, -radius)
	draw_line(center, twelve_position, Color(1.0, 1.0, 1.0, 0.35), 1.0)

	var needle_direction := Vector2(sin(roll_error), -cos(roll_error))
	var needle_end := center + needle_direction * radius * 0.85

	draw_line(center, needle_end, Color.WHITE, needle_width)
	draw_circle(center, 2.5, Color.WHITE)
