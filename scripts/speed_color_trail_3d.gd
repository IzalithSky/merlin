class_name SpeedColorTrail3D
extends VisualTrail3D


@export var slow_color := Color(0.0, 0.05, 0.8, 0.75)
@export var fast_color := Color(1.0, 0.45, 0.0, 0.75)
@export var min_speed := 80.0
@export var max_speed := 180.0

var _current_speed := 0.0
var _point_speeds: Array[float] = []


func set_current_speed(speed: float) -> void:
	_current_speed = speed


func clear_trail() -> void:
	super.clear_trail()
	_point_speeds.clear()


func _append_point(emitter_position: Vector3) -> void:
	super._append_point(emitter_position)
	_point_speeds.append(_current_speed)


func _remove_point(point_index: int) -> void:
	super._remove_point(point_index)
	if point_index < _point_speeds.size():
		_point_speeds.remove_at(point_index)


func _build_mesh() -> void:
	if _immediate_mesh == null:
		return

	_immediate_mesh.clear_surfaces()
	if _points.size() < 2:
		return

	_immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var point_count := _points.size()
	for point_index in range(point_count):
		var t := float(point_index) / float(point_count - 1)
		var speed := _point_speeds[point_index] if point_index < _point_speeds.size() else 0.0
		var speed_t := clampf((speed - min_speed) / (max_speed - min_speed), 0.0, 1.0)
		var color := slow_color.lerp(fast_color, speed_t)
		color.a = lerpf(end_color.a, start_color.a, t)

		var width_scale := pow(1.0 - t, width_fade_power)
		var width_from := _widths[point_index][0] as Vector3
		var width_delta := _widths[point_index][1] as Vector3
		var half_width := width_from - width_scale * width_delta

		_immediate_mesh.surface_set_color(color)
		_immediate_mesh.surface_set_uv(Vector2(t, 0.0))
		_immediate_mesh.surface_add_vertex(_renderer.to_local(_points[point_index] + half_width))
		_immediate_mesh.surface_set_uv(Vector2(t, 1.0))
		_immediate_mesh.surface_add_vertex(_renderer.to_local(_points[point_index] - half_width))
	_immediate_mesh.surface_end()
