extends Control
class_name GraphPlotBase

## Shared 2D plotting framework: margins, view state, pan/zoom, grid and axis
## rendering. Subclasses provide their own data and draw it via `_draw_content`,
## and handle their own mouse buttons via `_handle_mouse_button`.

@export var x_axis_label: String = "X"
@export var y_axis_label: String = "Value"
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
const COLOR_TEXT := Color(0.85, 0.91, 0.96, 1.0)

var _view_x_min := 0.0
var _view_x_max := 1.0
var _view_y_min := 0.0
var _view_y_max := 1.0
var _is_panning := false
var _pan_button_index := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


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
	_draw_content(plot_rect)


# --- Virtuals for subclasses ------------------------------------------------

func _handle_mouse_button(_event: InputEventMouseButton) -> void:
	pass


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	_process_pan_motion(event)


func _draw_content(_plot_rect: Rect2) -> void:
	pass


func _format_x_tick(value: float) -> String:
	return _format_tick(value, 2)


func _format_y_tick(value: float) -> String:
	return _format_tick(value, 2)


# --- Coordinate mapping ------------------------------------------------------

func _get_plot_rect() -> Rect2:
	var min_corner := Vector2(PLOT_MARGIN_LEFT_PX, PLOT_MARGIN_TOP_PX)
	var max_corner := size - Vector2(PLOT_MARGIN_RIGHT_PX, PLOT_MARGIN_BOTTOM_PX)
	if max_corner.x <= min_corner.x:
		max_corner.x = min_corner.x + 1.0
	if max_corner.y <= min_corner.y:
		max_corner.y = min_corner.y + 1.0
	return Rect2(min_corner, max_corner - min_corner)


func _graph_to_screen(graph_point: Vector2, plot_rect: Rect2) -> Vector2:
	var x_span := maxf(_view_x_max - _view_x_min, SORT_EPSILON)
	var y_span := maxf(_view_y_max - _view_y_min, SORT_EPSILON)
	var x_blend := (graph_point.x - _view_x_min) / x_span
	var y_blend := (graph_point.y - _view_y_min) / y_span
	return Vector2(
		lerpf(plot_rect.position.x, plot_rect.end.x, x_blend),
		lerpf(plot_rect.end.y, plot_rect.position.y, y_blend)
	)


func _screen_to_graph(screen_point: Vector2, plot_rect: Rect2) -> Vector2:
	var x_span := maxf(_view_x_max - _view_x_min, SORT_EPSILON)
	var y_span := maxf(_view_y_max - _view_y_min, SORT_EPSILON)
	var x_blend := inverse_lerp(plot_rect.position.x, plot_rect.end.x, screen_point.x)
	var y_blend := inverse_lerp(plot_rect.end.y, plot_rect.position.y, screen_point.y)
	return Vector2(_view_x_min + x_blend * x_span, _view_y_min + y_blend * y_span)


# --- Grid / axes / text ------------------------------------------------------

func _draw_grid(plot_rect: Rect2) -> void:
	for x_value: float in _build_axis_ticks(_view_x_min, _view_x_max, GRID_DIVISIONS):
		var x_pos := _graph_to_screen(Vector2(x_value, _view_y_min), plot_rect).x
		draw_line(Vector2(x_pos, plot_rect.position.y), Vector2(x_pos, plot_rect.end.y), COLOR_GRID, 1.0)
	for y_value: float in _build_axis_ticks(_view_y_min, _view_y_max, GRID_DIVISIONS):
		var y_pos := _graph_to_screen(Vector2(_view_x_min, y_value), plot_rect).y
		draw_line(Vector2(plot_rect.position.x, y_pos), Vector2(plot_rect.end.x, y_pos), COLOR_GRID, 1.0)


func _draw_axes(plot_rect: Rect2) -> void:
	if _view_x_min < 0.0 and _view_x_max > 0.0:
		var axis_x := _graph_to_screen(Vector2(0.0, 0.0), plot_rect).x
		draw_line(Vector2(axis_x, plot_rect.position.y), Vector2(axis_x, plot_rect.end.y), COLOR_AXIS, 1.0)
	if _view_y_min < 0.0 and _view_y_max > 0.0:
		var axis_y := _graph_to_screen(Vector2(0.0, 0.0), plot_rect).y
		draw_line(Vector2(plot_rect.position.x, axis_y), Vector2(plot_rect.end.x, axis_y), COLOR_AXIS, 1.0)


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
		var x_text := _format_x_tick(x_value)
		var x_text_width := font.get_string_size(x_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var x_pos := Vector2(
			clampf(x_screen - x_text_width * 0.5, plot_rect.position.x, plot_rect.end.x - x_text_width),
			x_tick_baseline
		)
		draw_string(font, x_pos, x_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, COLOR_TEXT)

	for y_value: float in y_ticks:
		var y_screen := _graph_to_screen(Vector2(_view_x_min, y_value), plot_rect).y
		var y_text := _format_y_tick(y_value)
		var y_text_width := font.get_string_size(y_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var y_baseline := y_screen + (ascent - descent) * 0.5
		var y_text_x := plot_rect.position.x - y_text_width - TICK_TEXT_GAP_PX
		if _view_x_min <= 0.0 and _view_x_max >= 0.0:
			if draw_y_left_of_axis:
				y_text_x = y_axis_screen_x - y_text_width - TICK_TEXT_GAP_PX
			else:
				y_text_x = y_axis_screen_x + TICK_TEXT_GAP_PX
		draw_string(font, Vector2(y_text_x, y_baseline), y_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, COLOR_TEXT)

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


func _format_tick(value: float, decimals: int) -> String:
	var d := maxi(decimals, 0)
	if absf(value) < pow(10.0, -float(d)) * 0.5:
		value = 0.0
	return ("%." + str(d) + "f") % value


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
	var nice_normalized: float = 10.0
	if normalized <= 1.0:
		nice_normalized = 1.0
	elif normalized <= 2.0:
		nice_normalized = 2.0
	elif normalized <= 5.0:
		nice_normalized = 5.0
	return nice_normalized * magnitude


# --- Series drawing helpers --------------------------------------------------

## Draws a polyline clipped to `plot_rect`. Unlike clamping each vertex to the
## rect (which crams off-view points onto the border), this clips every segment
## against the rect so lines leave/enter the plot at the correct boundary point
## and fully off-view segments are dropped.
func _draw_clipped_polyline(screen_points: PackedVector2Array, plot_rect: Rect2, color: Color, width: float) -> void:
	for i in range(screen_points.size() - 1):
		var segment := _clip_segment_to_rect(screen_points[i], screen_points[i + 1], plot_rect)
		if segment.is_empty():
			continue
		draw_line(segment[0], segment[1], color, width, true)


## Liang-Barsky line clip. Returns [a, b] clipped to the rect, or [] if the
## segment lies entirely outside it.
func _clip_segment_to_rect(a: Vector2, b: Vector2, rect: Rect2) -> Array[Vector2]:
	var delta := b - a
	var p := [-delta.x, delta.x, -delta.y, delta.y]
	var q := [a.x - rect.position.x, rect.end.x - a.x, a.y - rect.position.y, rect.end.y - a.y]
	var t0 := 0.0
	var t1 := 1.0
	for i in range(4):
		if absf(p[i]) < 1e-9:
			if q[i] < 0.0:
				return []
		else:
			var t: float = q[i] / p[i]
			if p[i] < 0.0:
				t0 = maxf(t0, t)
			else:
				t1 = minf(t1, t)
	if t0 > t1:
		return []
	return [a + delta * t0, a + delta * t1]


# --- Pan / zoom --------------------------------------------------------------

func _handle_wheel_zoom(event: InputEventMouseButton) -> void:
	var zoom_scale := maxf(wheel_zoom_factor, 1.01)
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		zoom_scale = 1.0 / zoom_scale
	var zoom_x := not event.alt_pressed
	var zoom_y := not event.shift_pressed
	_zoom_view_at(event.position, zoom_scale, zoom_x, zoom_y)


func _zoom_view_at(anchor_screen_position: Vector2, zoom_scale: float, zoom_x: bool, zoom_y: bool) -> void:
	var plot_rect := _get_plot_rect()
	if not plot_rect.has_point(anchor_screen_position):
		return
	var anchor := _screen_to_graph(anchor_screen_position, plot_rect)
	if zoom_x:
		_view_x_min = anchor.x - (anchor.x - _view_x_min) * zoom_scale
		_view_x_max = anchor.x + (_view_x_max - anchor.x) * zoom_scale
	if zoom_y:
		_view_y_min = anchor.y - (anchor.y - _view_y_min) * zoom_scale
		_view_y_max = anchor.y + (_view_y_max - anchor.y) * zoom_scale
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


## Span-only clamp; subclasses may override to also clamp the view position.
func _clamp_view_bounds() -> void:
	var x_span := clampf(_view_x_max - _view_x_min, min_view_x_span, max_view_x_span)
	var y_span := clampf(_view_y_max - _view_y_min, min_view_y_span, max_view_y_span)
	var x_center := (_view_x_min + _view_x_max) * 0.5
	var y_center := (_view_y_min + _view_y_max) * 0.5
	_view_x_min = x_center - x_span * 0.5
	_view_x_max = x_center + x_span * 0.5
	_view_y_min = y_center - y_span * 0.5
	_view_y_max = y_center + y_span * 0.5


func _process_pan_motion(event: InputEventMouseMotion) -> bool:
	if not _is_panning:
		return false
	if _is_pan_button_pressed():
		_pan_view_by_screen_delta(event.relative)
		accept_event()
	else:
		_stop_panning()
	return true


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


func _is_screen_position_in_plot(screen_position: Vector2) -> bool:
	return _get_plot_rect().has_point(screen_position)
