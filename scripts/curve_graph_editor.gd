extends Control
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
@export var x_axis_label: String = "AoA (deg)"
@export var y_axis_label: String = "Value"
@export var tick_decimals: int = 2
@export_range(1.01, 2.0, 0.01) var wheel_zoom_factor: float = 1.12
@export var min_view_x_span: float = 1.0
@export var min_view_y_span: float = 0.01
@export var max_view_x_span: float = 5000.0
@export var max_view_y_span: float = 500.0

const PLOT_MARGIN_LEFT_PX := 72.0
const PLOT_MARGIN_RIGHT_PX := 24.0
const PLOT_MARGIN_TOP_PX := 24.0
const PLOT_MARGIN_BOTTOM_PX := 52.0
const GRID_DIVISIONS := 8
const SAMPLE_STEPS := 96
const POINT_RADIUS_PX := 5.0
const HIT_RADIUS_PX := 10.0
const SORT_EPSILON := 0.0001
const TICK_TEXT_GAP_PX := 6.0
const X_LABEL_GAP_PX := 8.0
const Y_LABEL_GAP_PX := 12.0
const MIN_FONT_SIZE := 10
const MAX_AXIS_TICKS := 128

const COLOR_BACKGROUND := Color(0.05, 0.07, 0.09, 0.92)
const COLOR_BORDER := Color(0.47, 0.68, 0.78, 0.8)
const COLOR_GRID := Color(0.23, 0.31, 0.35, 0.75)
const COLOR_AXIS := Color(0.65, 0.76, 0.84, 0.7)
const COLOR_CURVE := Color(1.0, 0.72, 0.25, 1.0)
const COLOR_POINT := Color(0.93, 0.94, 0.96, 1.0)
const COLOR_POINT_SELECTED := Color(1.0, 0.52, 0.22, 1.0)
const COLOR_TEXT := Color(0.85, 0.91, 0.96, 1.0)

var _points: Array[Vector2] = []
var _drag_point_index := -1
var _view_x_min: float = -40.0
var _view_x_max: float = 40.0
var _view_y_min: float = -1.0
var _view_y_max: float = 1.5
var _is_panning := false
var _pan_button_index := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_initialize_view_bounds()


func set_points(points: Array[Vector2]) -> void:
	if _view_x_max <= _view_x_min or _view_y_max <= _view_y_min:
		_initialize_view_bounds()
	_points = _normalize_points(points)
	_drag_point_index = -1
	queue_redraw()


func get_points() -> Array[Vector2]:
	return _points.duplicate()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
		return

	if event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _draw() -> void:
	var plot_rect := _get_plot_rect()
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BACKGROUND, true)
	draw_rect(plot_rect, COLOR_BORDER, false, 1.0)
	_draw_grid(plot_rect)
	_draw_axes(plot_rect)
	_draw_axis_text(plot_rect)
	_draw_curve(plot_rect)
	_draw_points(plot_rect)


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
	if _is_panning:
		if _is_pan_button_pressed():
			_pan_view_by_screen_delta(event.relative)
			accept_event()
		else:
			_stop_panning()
		return

	if _drag_point_index < 0 or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return

	var graph_point := _clamp_graph_point(_screen_to_graph(event.position))
	if _drag_point_index >= _points.size():
		_drag_point_index = _points.size() - 1
	if _drag_point_index < 0:
		return

	_points[_drag_point_index] = graph_point
	_points = _normalize_points(_points)
	_drag_point_index = _find_nearest_point_index(_graph_to_screen(graph_point))
	_emit_points_changed()
	queue_redraw()
	accept_event()


func _insert_point_at_screen_position(screen_position: Vector2) -> void:
	var graph_point := _clamp_graph_point(_screen_to_graph(screen_position))
	_points.append(graph_point)
	_points = _normalize_points(_points)
	_emit_points_changed()
	queue_redraw()


func _draw_grid(plot_rect: Rect2) -> void:
	var x_ticks := _build_axis_ticks(_view_x_min, _view_x_max, GRID_DIVISIONS)
	var y_ticks := _build_axis_ticks(_view_y_min, _view_y_max, GRID_DIVISIONS)

	for x_value in x_ticks:
		var x_pos := _graph_to_screen(Vector2(x_value, _view_y_min)).x
		draw_line(Vector2(x_pos, plot_rect.position.y), Vector2(x_pos, plot_rect.end.y), COLOR_GRID, 1.0)

	for y_value in y_ticks:
		var y_pos := _graph_to_screen(Vector2(_view_x_min, y_value)).y
		draw_line(Vector2(plot_rect.position.x, y_pos), Vector2(plot_rect.end.x, y_pos), COLOR_GRID, 1.0)


func _draw_axes(plot_rect: Rect2) -> void:
	if _view_x_min < 0.0 and _view_x_max > 0.0:
		var axis_x := _graph_to_screen(Vector2(0.0, 0.0)).x
		draw_line(Vector2(axis_x, plot_rect.position.y), Vector2(axis_x, plot_rect.end.y), COLOR_AXIS, 1.0)

	if _view_y_min < 0.0 and _view_y_max > 0.0:
		var axis_y := _graph_to_screen(Vector2(0.0, 0.0)).y
		draw_line(Vector2(plot_rect.position.x, axis_y), Vector2(plot_rect.end.x, axis_y), COLOR_AXIS, 1.0)


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
		var screen_point := _graph_to_screen(graph_point)
		if not plot_rect.has_point(screen_point):
			screen_point.x = clampf(screen_point.x, plot_rect.position.x, plot_rect.end.x)
			screen_point.y = clampf(screen_point.y, plot_rect.position.y, plot_rect.end.y)
		sampled_points.append(screen_point)

	draw_polyline(sampled_points, COLOR_CURVE, 2.0, true)


func _draw_points(plot_rect: Rect2) -> void:
	var visible_rect := plot_rect.grow(POINT_RADIUS_PX + 1.0)
	for point_index in range(_points.size()):
		var screen_point := _graph_to_screen(_points[point_index])
		if not visible_rect.has_point(screen_point):
			continue
		var color := COLOR_POINT
		if point_index == _drag_point_index:
			color = COLOR_POINT_SELECTED
		draw_circle(screen_point, POINT_RADIUS_PX, color)


func _get_plot_rect() -> Rect2:
	var min_corner := Vector2(PLOT_MARGIN_LEFT_PX, PLOT_MARGIN_TOP_PX)
	var max_corner := size - Vector2(PLOT_MARGIN_RIGHT_PX, PLOT_MARGIN_BOTTOM_PX)
	if max_corner.x <= min_corner.x:
		max_corner.x = min_corner.x + 1.0
	if max_corner.y <= min_corner.y:
		max_corner.y = min_corner.y + 1.0
	return Rect2(min_corner, max_corner - min_corner)


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
		var axis_y := _graph_to_screen(Vector2(0.0, 0.0)).y
		x_tick_baseline = clampf(
			axis_y + ascent + TICK_TEXT_GAP_PX,
			plot_rect.position.y + ascent + 2.0,
			plot_rect.end.y - 2.0
		)

	var y_axis_screen_x := plot_rect.position.x
	var draw_y_left_of_axis := true
	if _view_x_min <= 0.0 and _view_x_max >= 0.0:
		y_axis_screen_x = _graph_to_screen(Vector2(0.0, 0.0)).x
		draw_y_left_of_axis = y_axis_screen_x >= (plot_rect.position.x + plot_rect.size.x * 0.35)

	for x_value in x_ticks:
		var x_screen := _graph_to_screen(Vector2(x_value, _view_y_min)).x
		var x_text := _format_tick(x_value)
		var x_text_width := font.get_string_size(x_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var x_pos := Vector2(x_screen - x_text_width * 0.5, x_tick_baseline)
		draw_string(font, x_pos, x_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, COLOR_TEXT)

	for y_value in y_ticks:
		var y_screen := _graph_to_screen(Vector2(_view_x_min, y_value)).y
		var y_text := _format_tick(y_value)
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


func _format_tick(value: float) -> String:
	var decimals := maxi(tick_decimals, 0)
	var format := "%." + str(decimals) + "f"
	if absf(value) < pow(10.0, -float(decimals)) * 0.5:
		value = 0.0
	return format % value


func _build_axis_ticks(range_min: float, range_max: float, target_divisions: int) -> Array[float]:
	var ticks: Array[float] = []
	var min_value: float = minf(range_min, range_max)
	var max_value: float = maxf(range_min, range_max)
	var span: float = maxf(max_value - min_value, SORT_EPSILON)
	var step: float = _get_nice_tick_step(span / float(maxi(target_divisions, 1)))
	var epsilon: float = step * 0.0005

	var first_tick: float = floor((min_value + epsilon) / step) * step
	var last_tick: float = ceil((max_value - epsilon) / step) * step
	var tick_value: float = first_tick
	var guard: int = 0
	while tick_value <= last_tick + epsilon and guard < MAX_AXIS_TICKS:
		var snapped_tick: float = tick_value
		if absf(snapped_tick) <= epsilon:
			snapped_tick = 0.0
		if snapped_tick >= min_value - epsilon and snapped_tick <= max_value + epsilon:
			if ticks.is_empty() or absf(snapped_tick - ticks[ticks.size() - 1]) > epsilon:
				ticks.append(snapped_tick)
		tick_value += step
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
	var magnitude: float = pow(10.0, exponent)
	var normalized: float = safe_step / magnitude

	var nice_normalized: float = 1.0
	if normalized <= 1.0:
		nice_normalized = 1.0
	elif normalized <= 2.0:
		nice_normalized = 2.0
	elif normalized <= 5.0:
		nice_normalized = 5.0
	else:
		nice_normalized = 10.0

	return nice_normalized * magnitude


func _graph_to_screen(graph_point: Vector2) -> Vector2:
	var plot_rect := _get_plot_rect()
	var x_span := maxf(_view_x_max - _view_x_min, SORT_EPSILON)
	var y_span := maxf(_view_y_max - _view_y_min, SORT_EPSILON)
	var x_blend := (graph_point.x - _view_x_min) / x_span
	var y_blend := (graph_point.y - _view_y_min) / y_span
	var x_pos := lerpf(plot_rect.position.x, plot_rect.end.x, x_blend)
	var y_pos := lerpf(plot_rect.end.y, plot_rect.position.y, y_blend)
	return Vector2(x_pos, y_pos)


func _screen_to_graph(screen_point: Vector2) -> Vector2:
	var plot_rect := _get_plot_rect()
	var x_span := maxf(_view_x_max - _view_x_min, SORT_EPSILON)
	var y_span := maxf(_view_y_max - _view_y_min, SORT_EPSILON)
	var x_blend := inverse_lerp(plot_rect.position.x, plot_rect.end.x, screen_point.x)
	var y_blend := inverse_lerp(plot_rect.end.y, plot_rect.position.y, screen_point.y)
	var x_value := _view_x_min + x_blend * x_span
	var y_value := _view_y_min + y_blend * y_span
	return Vector2(x_value, y_value)


func _find_nearest_point_index(screen_point: Vector2) -> int:
	var nearest_index := -1
	var nearest_distance_sq := HIT_RADIUS_PX * HIT_RADIUS_PX
	for point_index in range(_points.size()):
		var candidate := _graph_to_screen(_points[point_index])
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


func _handle_wheel_zoom(event: InputEventMouseButton) -> void:
	var zoom_scale := maxf(wheel_zoom_factor, 1.01)
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		zoom_scale = 1.0 / zoom_scale

	var zoom_x := true
	var zoom_y := true
	if event.shift_pressed and not event.alt_pressed:
		zoom_y = false
	elif event.alt_pressed and not event.shift_pressed:
		zoom_x = false

	_zoom_view_at(event.position, zoom_scale, zoom_x, zoom_y)


func _zoom_view_at(anchor_screen_position: Vector2, zoom_scale: float, zoom_x: bool, zoom_y: bool) -> void:
	var anchor_graph := _screen_to_graph(anchor_screen_position)

	if zoom_x:
		var x_span := maxf(_view_x_max - _view_x_min, SORT_EPSILON)
		var target_x_span := clampf(x_span * zoom_scale, min_view_x_span, max_view_x_span)
		var x_blend := inverse_lerp(_view_x_min, _view_x_max, anchor_graph.x)
		_view_x_min = anchor_graph.x - x_blend * target_x_span
		_view_x_max = _view_x_min + target_x_span

	if zoom_y:
		var y_span := maxf(_view_y_max - _view_y_min, SORT_EPSILON)
		var target_y_span := clampf(y_span * zoom_scale, min_view_y_span, max_view_y_span)
		var y_blend := inverse_lerp(_view_y_min, _view_y_max, anchor_graph.y)
		_view_y_min = anchor_graph.y - y_blend * target_y_span
		_view_y_max = _view_y_min + target_y_span

	_clamp_view_bounds()
	queue_redraw()


func _pan_view_by_screen_delta(screen_delta: Vector2) -> void:
	var plot_rect := _get_plot_rect()
	if plot_rect.size.x <= 1.0 or plot_rect.size.y <= 1.0:
		return

	var x_span := _view_x_max - _view_x_min
	var y_span := _view_y_max - _view_y_min
	var graph_delta := Vector2(
		-(screen_delta.x / plot_rect.size.x) * x_span,
		(screen_delta.y / plot_rect.size.y) * y_span
	)

	_view_x_min += graph_delta.x
	_view_x_max += graph_delta.x
	_view_y_min += graph_delta.y
	_view_y_max += graph_delta.y
	_clamp_view_bounds()
	queue_redraw()


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


func _start_panning(button_index: int) -> void:
	_is_panning = true
	_pan_button_index = button_index


func _stop_panning() -> void:
	_is_panning = false
	_pan_button_index = -1


func _is_pan_button_pressed() -> bool:
	match _pan_button_index:
		MOUSE_BUTTON_LEFT:
			return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		MOUSE_BUTTON_MIDDLE:
			return Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)
		_:
			return false


func _is_screen_position_in_plot(screen_position: Vector2) -> bool:
	return _get_plot_rect().has_point(screen_position)
