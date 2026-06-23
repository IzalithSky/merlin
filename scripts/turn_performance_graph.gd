extends GraphPlotBase
class_name TurnPerformanceGraph

@export var y_decimals: int = 1
@export var x_decimals: int = 0
@export var default_view_x_min: float = 0.0
@export var default_view_x_max: float = 200.0

const SERIES_WIDTH_PX := 2.0
const MARKER_RADIUS_PX := 4.0

const COLOR_SERIES_A := Color(1.0, 0.72, 0.25, 1.0)
const COLOR_SERIES_B := Color(0.3, 0.9, 0.95, 1.0)
const COLOR_MARKER := Color(1.0, 0.97, 0.55, 1.0)

var _series: Array[Dictionary] = []
var _data_x_min := 0.0
var _data_x_max := 1.0
var _data_y_min := 0.0
var _data_y_max := 1.0
var _view_initialized := false


func _ready() -> void:
	# Turn-performance values span far wider ranges than the curve editor.
	min_view_x_span = 5.0
	min_view_y_span = 0.1
	max_view_y_span = 100000.0
	super._ready()


static func get_series_a_color() -> Color:
	return COLOR_SERIES_A


static func get_series_b_color() -> Color:
	return COLOR_SERIES_B


static func get_marker_color() -> Color:
	return COLOR_MARKER


func set_series(series: Array[Dictionary]) -> void:
	_series = []
	for entry in series:
		if not (entry is Dictionary):
			continue
		_series.append(entry.duplicate(true))
	_recalculate_bounds()
	queue_redraw()


func _format_x_tick(value: float) -> String:
	return _format_tick(value, x_decimals)


func _format_y_tick(value: float) -> String:
	return _format_tick(value, y_decimals)


func _recalculate_bounds() -> void:
	var min_x := INF
	var max_x := -INF
	var min_y := INF
	var max_y := -INF
	for entry in _series:
		var points: Array[Vector2] = entry.get("points", [])
		for point in points:
			min_x = minf(min_x, point.x)
			max_x = maxf(max_x, point.x)
			min_y = minf(min_y, point.y)
			max_y = maxf(max_y, point.y)

	if not is_finite(min_x) or not is_finite(max_x):
		_data_x_min = 0.0
		_data_x_max = 1.0
		_data_y_min = 0.0
		_data_y_max = 1.0
		if not _view_initialized:
			_view_x_min = 0.0
			_view_x_max = 1.0
			_view_y_min = 0.0
			_view_y_max = 1.0
		return

	if absf(max_x - min_x) <= 0.001:
		max_x = min_x + 1.0
	if not is_finite(min_y) or not is_finite(max_y) or absf(max_y - min_y) <= 0.001:
		min_y = 0.0
		max_y = maxf(max_y, 1.0)

	var y_padding := maxf((max_y - min_y) * 0.08, 0.5)
	_data_x_min = min_x
	_data_x_max = max_x
	_data_y_min = minf(0.0, min_y - y_padding)
	_data_y_max = max_y + y_padding
	# Auto-fit only on first data; afterwards keep the user's zoom/pan across
	# refreshes (middle-double-click re-fits to the current data).
	if _view_initialized:
		_clamp_view_bounds()
		queue_redraw()
	else:
		_reset_view_bounds()
		_view_initialized = true


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed and event.double_click:
		_reset_view_bounds()
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			if _is_screen_position_in_plot(event.position):
				_start_panning(MOUSE_BUTTON_MIDDLE)
				accept_event()
		elif _pan_button_index == MOUSE_BUTTON_MIDDLE:
			_stop_panning()
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _is_screen_position_in_plot(event.position):
				_start_panning(MOUSE_BUTTON_LEFT)
				accept_event()
		elif _pan_button_index == MOUSE_BUTTON_LEFT:
			_stop_panning()
		return
	if not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_handle_wheel_zoom(event)
		accept_event()


func _reset_view_bounds() -> void:
	_view_x_min = minf(default_view_x_min, _data_x_min)
	_view_x_max = maxf(default_view_x_max, _view_x_min + min_view_x_span)
	_view_y_min = _data_y_min
	_view_y_max = maxf(_data_y_max, _view_y_min + min_view_y_span)
	_clamp_view_bounds()
	queue_redraw()


func _draw_axes(plot_rect: Rect2) -> void:
	draw_line(Vector2(plot_rect.position.x, plot_rect.end.y), plot_rect.end, COLOR_AXIS, 1.0)
	draw_line(plot_rect.position, Vector2(plot_rect.position.x, plot_rect.end.y), COLOR_AXIS, 1.0)


func _draw_content(plot_rect: Rect2) -> void:
	var fallback_colors := [COLOR_SERIES_A, COLOR_SERIES_B]
	for index in range(_series.size()):
		var entry := _series[index]
		var points: Array[Vector2] = entry.get("points", [])
		if points.size() < 2:
			continue
		var color: Color = entry.get("color", fallback_colors[min(index, fallback_colors.size() - 1)])
		var screen_points := PackedVector2Array()
		for point: Vector2 in points:
			screen_points.append(_graph_to_screen(point, plot_rect))
		_draw_clipped_polyline(screen_points, plot_rect, color, SERIES_WIDTH_PX)
		if entry.has("marker") and entry["marker"] is Vector2:
			var marker_point := _graph_to_screen(entry["marker"], plot_rect)
			if plot_rect.has_point(marker_point):
				draw_circle(marker_point, MARKER_RADIUS_PX, COLOR_MARKER)
