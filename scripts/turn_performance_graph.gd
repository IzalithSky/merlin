extends Control
class_name TurnPerformanceGraph

@export var x_axis_label: String = "Speed (m/s)"
@export var y_axis_label: String = "Value"
@export var y_decimals: int = 1
@export var x_decimals: int = 0
@export_range(1.01, 2.0, 0.01) var wheel_zoom_factor: float = 1.12
@export var default_view_x_min: float = 0.0
@export var default_view_x_max: float = 200.0
@export var min_view_x_span: float = 5.0
@export var min_view_y_span: float = 0.1
@export var max_view_x_span: float = 5000.0
@export var max_view_y_span: float = 100000.0

const PLOT_MARGIN_LEFT_PX := 72.0
const PLOT_MARGIN_RIGHT_PX := 20.0
const PLOT_MARGIN_TOP_PX := 20.0
const PLOT_MARGIN_BOTTOM_PX := 48.0
const GRID_DIVISIONS := 8
const TICK_TEXT_GAP_PX := 6.0
const X_LABEL_GAP_PX := 8.0
const Y_LABEL_GAP_PX := 12.0
const MIN_FONT_SIZE := 10
const MAX_AXIS_TICKS := 128
const SERIES_WIDTH_PX := 2.0
const MARKER_RADIUS_PX := 4.0
const SORT_EPSILON := 0.0001

const COLOR_BACKGROUND := Color(0.05, 0.07, 0.09, 0.92)
const COLOR_BORDER := Color(0.47, 0.68, 0.78, 0.8)
const COLOR_GRID := Color(0.23, 0.31, 0.35, 0.75)
const COLOR_AXIS := Color(0.65, 0.76, 0.84, 0.7)
const COLOR_TEXT := Color(0.85, 0.91, 0.96, 1.0)
const COLOR_SERIES_A := Color(1.0, 0.72, 0.25, 1.0)
const COLOR_SERIES_B := Color(0.3, 0.9, 0.95, 1.0)
const COLOR_MARKER := Color(1.0, 0.97, 0.55, 1.0)

var _series: Array[Dictionary] = []
var _view_x_min := 0.0
var _view_x_max := 1.0
var _view_y_min := 0.0
var _view_y_max := 1.0
var _data_x_min := 0.0
var _data_x_max := 1.0
var _data_y_min := 0.0
var _data_y_max := 1.0
var _is_panning := false
var _pan_button_index := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_series(series: Array[Dictionary]) -> void:
	_series = []
	for entry in series:
		if not (entry is Dictionary):
			continue
		_series.append(entry.duplicate(true))
	_recalculate_bounds()
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
		return
	if event is InputEventMouseMotion:
		_handle_mouse_motion(event)


static func get_series_a_color() -> Color:
	return COLOR_SERIES_A


static func get_series_b_color() -> Color:
	return COLOR_SERIES_B


static func get_marker_color() -> Color:
	return COLOR_MARKER


func _draw() -> void:
	var plot_rect := _get_plot_rect()
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BACKGROUND, true)
	draw_rect(plot_rect, COLOR_BORDER, false, 1.0)
	_draw_grid(plot_rect)
	_draw_axes(plot_rect)
	_draw_axis_text(plot_rect)
	_draw_series(plot_rect)


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
	_reset_view_bounds()


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed and event.double_click:
		_reset_view_bounds()
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			if _get_plot_rect().has_point(event.position):
				_start_panning(MOUSE_BUTTON_MIDDLE)
				accept_event()
		elif _pan_button_index == MOUSE_BUTTON_MIDDLE:
			_stop_panning()
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _get_plot_rect().has_point(event.position):
				_start_panning(MOUSE_BUTTON_LEFT)
				accept_event()
		elif _pan_button_index == MOUSE_BUTTON_LEFT:
			_stop_panning()
		return
	if not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not _get_plot_rect().has_point(event.position):
			return
		var zoom_scale := 1.0 / wheel_zoom_factor if event.button_index == MOUSE_BUTTON_WHEEL_UP else wheel_zoom_factor
		var zoom_x := not event.alt_pressed
		var zoom_y := not event.shift_pressed
		_zoom_view_at(event.position, zoom_scale, zoom_x, zoom_y)
		accept_event()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if not _is_panning:
		return
	if _is_pan_button_pressed():
		_pan_view_by_screen_delta(event.relative)
		accept_event()
	else:
		_stop_panning()


func _zoom_view_at(anchor_screen_position: Vector2, zoom_scale: float, zoom_x: bool, zoom_y: bool) -> void:
	var plot_rect := _get_plot_rect()
	if not plot_rect.has_point(anchor_screen_position):
		return
	var anchor_graph := _screen_to_graph(anchor_screen_position, plot_rect)

	if zoom_x:
		var left_span := anchor_graph.x - _view_x_min
		var right_span := _view_x_max - anchor_graph.x
		_view_x_min = anchor_graph.x - left_span * zoom_scale
		_view_x_max = anchor_graph.x + right_span * zoom_scale

	if zoom_y:
		var lower_span := anchor_graph.y - _view_y_min
		var upper_span := _view_y_max - anchor_graph.y
		_view_y_min = anchor_graph.y - lower_span * zoom_scale
		_view_y_max = anchor_graph.y + upper_span * zoom_scale

	_clamp_view_bounds()
	queue_redraw()


func _reset_view_bounds() -> void:
	_view_x_min = minf(default_view_x_min, _data_x_min)
	_view_x_max = maxf(default_view_x_max, _view_x_min + min_view_x_span)
	_view_y_min = _data_y_min
	_view_y_max = maxf(_data_y_max, _view_y_min + min_view_y_span)
	_clamp_view_bounds()
	queue_redraw()


func _clamp_view_bounds() -> void:
	var x_span := clampf(_view_x_max - _view_x_min, min_view_x_span, max_view_x_span)
	var y_span := clampf(_view_y_max - _view_y_min, min_view_y_span, max_view_y_span)
	var x_center := (_view_x_min + _view_x_max) * 0.5
	var y_center := (_view_y_min + _view_y_max) * 0.5
	_view_x_min = x_center - x_span * 0.5
	_view_x_max = x_center + x_span * 0.5
	_view_y_min = y_center - y_span * 0.5
	_view_y_max = y_center + y_span * 0.5


func _pan_view_by_screen_delta(screen_delta: Vector2) -> void:
	var plot_rect := _get_plot_rect()
	if plot_rect.size.x <= 0.0 or plot_rect.size.y <= 0.0:
		return
	var x_units_per_pixel := (_view_x_max - _view_x_min) / plot_rect.size.x
	var y_units_per_pixel := (_view_y_max - _view_y_min) / plot_rect.size.y
	_view_x_min -= screen_delta.x * x_units_per_pixel
	_view_x_max -= screen_delta.x * x_units_per_pixel
	_view_y_min += screen_delta.y * y_units_per_pixel
	_view_y_max += screen_delta.y * y_units_per_pixel
	queue_redraw()


func _screen_to_graph(screen_point: Vector2, plot_rect: Rect2) -> Vector2:
	var x_t := inverse_lerp(plot_rect.position.x, plot_rect.end.x, screen_point.x)
	var y_t := inverse_lerp(plot_rect.end.y, plot_rect.position.y, screen_point.y)
	return Vector2(
		lerpf(_view_x_min, _view_x_max, x_t),
		lerpf(_view_y_min, _view_y_max, y_t)
	)


func _start_panning(button_index: int) -> void:
	_is_panning = true
	_pan_button_index = button_index


func _stop_panning() -> void:
	_is_panning = false
	_pan_button_index = -1


func _is_pan_button_pressed() -> bool:
	if _pan_button_index == MOUSE_BUTTON_LEFT:
		return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if _pan_button_index == MOUSE_BUTTON_MIDDLE:
		return Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)
	return false


func _draw_grid(plot_rect: Rect2) -> void:
	for division in range(GRID_DIVISIONS + 1):
		var t := float(division) / float(GRID_DIVISIONS)
		var x := lerpf(plot_rect.position.x, plot_rect.end.x, t)
		var y := lerpf(plot_rect.position.y, plot_rect.end.y, t)
		draw_line(Vector2(x, plot_rect.position.y), Vector2(x, plot_rect.end.y), COLOR_GRID, 1.0)
		draw_line(Vector2(plot_rect.position.x, y), Vector2(plot_rect.end.x, y), COLOR_GRID, 1.0)


func _draw_axes(plot_rect: Rect2) -> void:
	draw_line(Vector2(plot_rect.position.x, plot_rect.end.y), plot_rect.end, COLOR_AXIS, 1.0)
	draw_line(plot_rect.position, Vector2(plot_rect.position.x, plot_rect.end.y), COLOR_AXIS, 1.0)


func _draw_axis_text(plot_rect: Rect2) -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		return
	var font_size: int = maxi(get_theme_default_font_size() - 1, MIN_FONT_SIZE)
	var ascent: float = font.get_ascent(font_size)
	var descent: float = font.get_descent(font_size)
	var x_ticks := _build_axis_ticks(_view_x_min, _view_x_max, GRID_DIVISIONS)
	var y_ticks := _build_axis_ticks(_view_y_min, _view_y_max, GRID_DIVISIONS)

	var x_tick_baseline := plot_rect.end.y + ascent + TICK_TEXT_GAP_PX
	if _view_y_min <= 0.0 and _view_y_max >= 0.0:
		var axis_y := _graph_to_screen(Vector2(0.0, 0.0), plot_rect).y
		x_tick_baseline = clampf(
			axis_y + ascent + TICK_TEXT_GAP_PX,
			plot_rect.position.y + ascent + 2.0,
			plot_rect.end.y - 2.0
		)

	var y_axis_screen_x := plot_rect.position.x
	var draw_y_left_of_axis := true
	if _view_x_min <= 0.0 and _view_x_max >= 0.0:
		y_axis_screen_x = _graph_to_screen(Vector2(0.0, 0.0), plot_rect).x
		draw_y_left_of_axis = y_axis_screen_x >= (plot_rect.position.x + plot_rect.size.x * 0.35)

	for x_value: float in x_ticks:
		var x_screen := _graph_to_screen(Vector2(x_value, _view_y_min), plot_rect).x
		var x_text := _format_tick(x_value, x_decimals)
		var x_text_width := font.get_string_size(x_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var x_pos := Vector2(
			clampf(x_screen - x_text_width * 0.5, plot_rect.position.x, plot_rect.end.x - x_text_width),
			x_tick_baseline
		)
		draw_string(font, x_pos, x_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, COLOR_TEXT)

	for y_value: float in y_ticks:
		var y_screen := _graph_to_screen(Vector2(_view_x_min, y_value), plot_rect).y
		var y_text := _format_tick(y_value, y_decimals)
		var y_text_width := font.get_string_size(y_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var y_baseline := y_screen + (ascent - descent) * 0.5
		var y_text_x := plot_rect.position.x - y_text_width - TICK_TEXT_GAP_PX
		if _view_x_min <= 0.0 and _view_x_max >= 0.0:
			if draw_y_left_of_axis:
				y_text_x = y_axis_screen_x - y_text_width - TICK_TEXT_GAP_PX
			else:
				y_text_x = y_axis_screen_x + TICK_TEXT_GAP_PX
		var y_pos := Vector2(y_text_x, y_baseline)
		draw_string(font, y_pos, y_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, COLOR_TEXT)

	if not x_axis_label.is_empty():
		var x_label_size := font.get_string_size(x_axis_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var x_label_pos := Vector2(
			plot_rect.position.x + (plot_rect.size.x - x_label_size.x) * 0.5,
			size.y - descent - X_LABEL_GAP_PX
		)
		draw_string(font, x_label_pos, x_axis_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, COLOR_TEXT)

	if not y_axis_label.is_empty():
		var y_label_pos := Vector2(
			maxf(Y_LABEL_GAP_PX, plot_rect.position.x - PLOT_MARGIN_LEFT_PX + Y_LABEL_GAP_PX),
			plot_rect.position.y + ascent
		)
		draw_string(font, y_label_pos, y_axis_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, COLOR_TEXT)


func _draw_series(plot_rect: Rect2) -> void:
	var fallback_colors := [COLOR_SERIES_A, COLOR_SERIES_B]
	for index in range(_series.size()):
		var entry := _series[index]
		var points: Array[Vector2] = entry.get("points", [])
		if points.size() < 2:
			continue
		var color: Color = entry.get("color", fallback_colors[min(index, fallback_colors.size() - 1)])
		var clipped_points := PackedVector2Array()
		for point: Vector2 in points:
			var screen_point := _graph_to_screen(point, plot_rect)
			if not plot_rect.has_point(screen_point):
				screen_point.x = clampf(screen_point.x, plot_rect.position.x, plot_rect.end.x)
				screen_point.y = clampf(screen_point.y, plot_rect.position.y, plot_rect.end.y)
			if not clipped_points.is_empty():
				var previous_point := clipped_points[clipped_points.size() - 1]
				if previous_point.distance_squared_to(screen_point) <= 0.0001:
					continue
			clipped_points.append(screen_point)
		if clipped_points.size() < 2:
			continue
		draw_polyline(clipped_points, color, SERIES_WIDTH_PX, true)
		if entry.has("marker") and entry["marker"] is Vector2:
			var marker_point := _graph_to_screen(entry["marker"], plot_rect)
			if plot_rect.has_point(marker_point):
				draw_circle(marker_point, MARKER_RADIUS_PX, COLOR_MARKER)


func _get_plot_rect() -> Rect2:
	return Rect2(
		Vector2(PLOT_MARGIN_LEFT_PX, PLOT_MARGIN_TOP_PX),
		Vector2(
			maxf(size.x - PLOT_MARGIN_LEFT_PX - PLOT_MARGIN_RIGHT_PX, 1.0),
			maxf(size.y - PLOT_MARGIN_TOP_PX - PLOT_MARGIN_BOTTOM_PX, 1.0)
		)
	)


func _graph_to_screen(graph_point: Vector2, plot_rect: Rect2) -> Vector2:
	var x_t := inverse_lerp(_view_x_min, _view_x_max, graph_point.x)
	var y_t := inverse_lerp(_view_y_min, _view_y_max, graph_point.y)
	return Vector2(
		lerpf(plot_rect.position.x, plot_rect.end.x, x_t),
		lerpf(plot_rect.end.y, plot_rect.position.y, y_t)
	)


func _format_tick(value: float, decimals: int) -> String:
	if absf(value) < pow(10.0, -float(maxi(decimals, 0))) * 0.5:
		value = 0.0
	return ("%0." + str(decimals) + "f") % value


func _build_axis_ticks(range_min: float, range_max: float, target_divisions: int) -> Array[float]:
	var ticks: Array[float] = []
	var min_value: float = minf(range_min, range_max)
	var max_value: float = maxf(range_min, range_max)
	var span: float = maxf(max_value - min_value, SORT_EPSILON)
	var step: float = _get_nice_tick_step(span / float(maxi(target_divisions, 1)))
	var epsilon: float = step * 0.0005
	var first_tick: float = floor((min_value + epsilon) / step) * step
	var last_tick: float = ceil((max_value - epsilon) / step) * step
	var value: float = first_tick
	var guard: int = 0
	while value <= last_tick + epsilon and guard < MAX_AXIS_TICKS:
		var snapped_tick: float = value
		if absf(snapped_tick) <= epsilon:
			snapped_tick = 0.0
		if snapped_tick >= min_value - epsilon and snapped_tick <= max_value + epsilon:
			if ticks.is_empty() or absf(snapped_tick - ticks[ticks.size() - 1]) > epsilon:
				ticks.append(snapped_tick)
		value += step
		guard += 1
	if min_value <= 0.0 and max_value >= 0.0:
		var has_zero := false
		for existing_tick: float in ticks:
			if absf(existing_tick) <= epsilon:
				has_zero = true
				break
		if not has_zero:
			ticks.append(0.0)
			ticks.sort()
	return ticks


func _get_nice_tick_step(raw_step: float) -> float:
	var safe_step: float = maxf(raw_step, SORT_EPSILON)
	var exponent: float = floor(log(safe_step) / log(10.0))
	var fraction: float = safe_step / pow(10.0, exponent)
	var nice_fraction: float = 1.0
	if fraction <= 1.0:
		nice_fraction = 1.0
	elif fraction <= 2.0:
		nice_fraction = 2.0
	elif fraction <= 5.0:
		nice_fraction = 5.0
	else:
		nice_fraction = 10.0
	return nice_fraction * pow(10.0, exponent)
