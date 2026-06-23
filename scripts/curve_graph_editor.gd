extends GraphPlotBase
class_name CurveGraphEditor

signal points_changed(points: Array[Vector2])

@export var x_min: float = -40.0
@export var x_max: float = 40.0
@export var y_min: float = -1.0
@export var y_max: float = 1.5
@export var edit_x_min: float = -720.0
@export var edit_x_max: float = 720.0
@export var edit_y_min: float = -20.0
@export var edit_y_max: float = 20.0
@export var min_points: int = 2
@export var tick_decimals: int = 2

const SAMPLE_STEPS := 96
const POINT_RADIUS_PX := 5.0
const HIT_RADIUS_PX := 10.0

const COLOR_CURVE := Color(1.0, 0.72, 0.25, 1.0)
const COLOR_POINT := Color(0.93, 0.94, 0.96, 1.0)
const COLOR_POINT_SELECTED := Color(1.0, 0.52, 0.22, 1.0)

var _points: Array[Vector2] = []
var _drag_point_index := -1


func _ready() -> void:
	super._ready()
	_initialize_view_bounds()


func set_points(points: Array[Vector2]) -> void:
	if _view_x_max <= _view_x_min or _view_y_max <= _view_y_min:
		_initialize_view_bounds()
	_points = _normalize_points(points)
	_drag_point_index = -1
	queue_redraw()


func get_points() -> Array[Vector2]:
	return _points.duplicate()


func _format_x_tick(value: float) -> String:
	return _format_tick(value, tick_decimals)


func _format_y_tick(value: float) -> String:
	return _format_tick(value, tick_decimals)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		_handle_wheel_zoom(event)
		accept_event()
		return

	if event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			if event.double_click:
				_reset_view_bounds()
			elif _is_screen_position_in_plot(event.position):
				_start_panning(MOUSE_BUTTON_MIDDLE)
			accept_event()
		else:
			if _pan_button_index == MOUSE_BUTTON_MIDDLE:
				_stop_panning()
		return

	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.double_click:
				if _is_screen_position_in_plot(event.position):
					_insert_point_at_screen_position(event.position)
					accept_event()
				return

			_drag_point_index = _find_nearest_point_index(event.position)
			if _drag_point_index >= 0:
				accept_event()
				return

			if _is_screen_position_in_plot(event.position):
				_start_panning(MOUSE_BUTTON_LEFT)
				accept_event()
		else:
			_drag_point_index = -1
			if _pan_button_index == MOUSE_BUTTON_LEFT:
				_stop_panning()
		return

	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var remove_index := _find_nearest_point_index(event.position)
		if remove_index >= 0 and _points.size() > max(min_points, 1):
			_points.remove_at(remove_index)
			_points = _normalize_points(_points)
			_emit_points_changed()
			queue_redraw()
			accept_event()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if _process_pan_motion(event):
		return

	if _drag_point_index < 0 or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return

	var plot_rect := _get_plot_rect()
	var graph_point := _clamp_graph_point(_screen_to_graph(event.position, plot_rect))
	if _drag_point_index >= _points.size():
		_drag_point_index = _points.size() - 1
	if _drag_point_index < 0:
		return

	_points[_drag_point_index] = graph_point
	_points = _normalize_points(_points)
	_drag_point_index = _find_nearest_point_index(_graph_to_screen(graph_point, plot_rect))
	_emit_points_changed()
	queue_redraw()
	accept_event()


func _insert_point_at_screen_position(screen_position: Vector2) -> void:
	var graph_point := _clamp_graph_point(_screen_to_graph(screen_position, _get_plot_rect()))
	_points.append(graph_point)
	_points = _normalize_points(_points)
	_emit_points_changed()
	queue_redraw()


func _draw_content(plot_rect: Rect2) -> void:
	_draw_curve(plot_rect)
	_draw_points(plot_rect)


func _draw_curve(plot_rect: Rect2) -> void:
	if _points.size() < 2:
		return

	var sampled_points := PackedVector2Array()
	for sample_index in range(SAMPLE_STEPS + 1):
		var blend := float(sample_index) / float(SAMPLE_STEPS)
		var x_value := lerpf(_view_x_min, _view_x_max, blend)
		var y_value := _sample_points(_points, x_value)
		var graph_point := Vector2(
			x_value,
			clampf(y_value, minf(_view_y_min, _view_y_max), maxf(_view_y_min, _view_y_max))
		)
		var screen_point := _graph_to_screen(graph_point, plot_rect)
		if not plot_rect.has_point(screen_point):
			screen_point.x = clampf(screen_point.x, plot_rect.position.x, plot_rect.end.x)
			screen_point.y = clampf(screen_point.y, plot_rect.position.y, plot_rect.end.y)
		sampled_points.append(screen_point)

	draw_polyline(sampled_points, COLOR_CURVE, 2.0, true)


func _draw_points(plot_rect: Rect2) -> void:
	var visible_rect := plot_rect.grow(POINT_RADIUS_PX + 1.0)
	for point_index in range(_points.size()):
		var screen_point := _graph_to_screen(_points[point_index], plot_rect)
		if not visible_rect.has_point(screen_point):
			continue
		var color := COLOR_POINT
		if point_index == _drag_point_index:
			color = COLOR_POINT_SELECTED
		draw_circle(screen_point, POINT_RADIUS_PX, color)


func _find_nearest_point_index(screen_point: Vector2) -> int:
	var plot_rect := _get_plot_rect()
	var nearest_index := -1
	var nearest_distance_sq := HIT_RADIUS_PX * HIT_RADIUS_PX
	for point_index in range(_points.size()):
		var candidate := _graph_to_screen(_points[point_index], plot_rect)
		var distance_sq := candidate.distance_squared_to(screen_point)
		if distance_sq <= nearest_distance_sq:
			nearest_distance_sq = distance_sq
			nearest_index = point_index
	return nearest_index


func _clamp_graph_point(point: Vector2) -> Vector2:
	return Vector2(
		clampf(point.x, minf(edit_x_min, edit_x_max), maxf(edit_x_min, edit_x_max)),
		clampf(point.y, minf(edit_y_min, edit_y_max), maxf(edit_y_min, edit_y_max))
	)


func _normalize_points(points: Array[Vector2]) -> Array[Vector2]:
	var normalized := points.duplicate()
	normalized.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)

	var deduped: Array[Vector2] = []
	for raw_point in normalized:
		var point := _clamp_graph_point(raw_point)
		if deduped.is_empty():
			deduped.append(point)
			continue

		if absf(point.x - deduped[deduped.size() - 1].x) <= SORT_EPSILON:
			deduped[deduped.size() - 1] = point
		else:
			deduped.append(point)

	return deduped


func _sample_points(points: Array[Vector2], x_value: float) -> float:
	if points.is_empty():
		return 0.0

	if points.size() == 1:
		return points[0].y

	if x_value <= points[0].x:
		return points[0].y

	var last_index := points.size() - 1
	if x_value >= points[last_index].x:
		return points[last_index].y

	for point_index in range(last_index):
		var left := points[point_index]
		var right := points[point_index + 1]
		if x_value > right.x:
			continue

		var span := right.x - left.x
		if absf(span) <= SORT_EPSILON:
			return right.y

		var blend := (x_value - left.x) / span
		return lerpf(left.y, right.y, blend)

	return points[last_index].y


func _reset_view_bounds() -> void:
	_view_x_min = minf(x_min, x_max)
	_view_x_max = maxf(x_min, x_max)
	_view_y_min = minf(y_min, y_max)
	_view_y_max = maxf(y_min, y_max)
	_clamp_view_bounds()
	queue_redraw()


func _initialize_view_bounds() -> void:
	var initial_x_min := minf(x_min, x_max)
	var initial_x_max := maxf(x_min, x_max)
	if initial_x_max - initial_x_min <= SORT_EPSILON:
		initial_x_max = initial_x_min + 1.0
	_view_x_min = initial_x_min
	_view_x_max = initial_x_max

	var initial_y_min := minf(y_min, y_max)
	var initial_y_max := maxf(y_min, y_max)
	if initial_y_max - initial_y_min <= SORT_EPSILON:
		initial_y_max = initial_y_min + 1.0
	_view_y_min = initial_y_min
	_view_y_max = initial_y_max

	_clamp_view_bounds()


func _clamp_view_bounds() -> void:
	var bounded_x_min := minf(edit_x_min, edit_x_max)
	var bounded_x_max := maxf(edit_x_min, edit_x_max)
	var bounded_y_min := minf(edit_y_min, edit_y_max)
	var bounded_y_max := maxf(edit_y_min, edit_y_max)

	var span_x := clampf(_view_x_max - _view_x_min, min_view_x_span, max_view_x_span)
	var span_y := clampf(_view_y_max - _view_y_min, min_view_y_span, max_view_y_span)
	if bounded_x_max - bounded_x_min > SORT_EPSILON:
		span_x = minf(span_x, bounded_x_max - bounded_x_min)
	else:
		span_x = min_view_x_span
	if bounded_y_max - bounded_y_min > SORT_EPSILON:
		span_y = minf(span_y, bounded_y_max - bounded_y_min)
	else:
		span_y = min_view_y_span

	var center_x := (_view_x_min + _view_x_max) * 0.5
	var center_y := (_view_y_min + _view_y_max) * 0.5

	_view_x_min = center_x - span_x * 0.5
	_view_x_max = center_x + span_x * 0.5
	_view_y_min = center_y - span_y * 0.5
	_view_y_max = center_y + span_y * 0.5

	if _view_x_min < bounded_x_min:
		var shift_x_min := bounded_x_min - _view_x_min
		_view_x_min += shift_x_min
		_view_x_max += shift_x_min
	if _view_x_max > bounded_x_max:
		var shift_x_max := _view_x_max - bounded_x_max
		_view_x_min -= shift_x_max
		_view_x_max -= shift_x_max

	if _view_y_min < bounded_y_min:
		var shift_y_min := bounded_y_min - _view_y_min
		_view_y_min += shift_y_min
		_view_y_max += shift_y_min
	if _view_y_max > bounded_y_max:
		var shift_y_max := _view_y_max - bounded_y_max
		_view_y_min -= shift_y_max
		_view_y_max -= shift_y_max


func _emit_points_changed() -> void:
	points_changed.emit(_points.duplicate())
