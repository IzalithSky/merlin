class_name VisualTrail3D
extends MeshInstance3D


@export var permanent := true
@export var trail_enabled := true
@export var from_width := 0.35
@export var to_width := 0.05
@export_range(0.5, 2.0) var width_fade_power := 1.0
@export var motion_delta := 1.0
@export var lifespan := 1.5
@export var max_points := 96
@export var scale_texture := false
@export var start_color := Color(1.0, 1.0, 1.0, 0.75)
@export var end_color := Color(1.0, 1.0, 1.0, 0.0)
@export var sample_smoothing_rate := 0.0
@export var max_sample_lag := 0.0

var node_ttl := -1.0

var _trail_visible := true
var _points: Array[Vector3] = []
var _widths: Array[Array] = []
var _life_points: Array[float] = []
var _last_position := Vector3.ZERO
var _sample_position := Vector3.ZERO
var _immediate_mesh: ImmediateMesh
var _renderer: MeshInstance3D


func configure(
	enabled: bool,
	is_permanent: bool,
	color_start: Color,
	color_end: Color,
	width_start: float,
	width_end: float,
	trail_motion_delta: float = motion_delta,
	trail_lifespan: float = lifespan
) -> void:
	trail_enabled = enabled
	permanent = is_permanent
	start_color = color_start
	end_color = color_end
	from_width = width_start
	to_width = width_end
	motion_delta = trail_motion_delta
	lifespan = trail_lifespan


func finish(ttl: float) -> void:
	trail_enabled = false
	permanent = false
	node_ttl = ttl


func _ready() -> void:
	_last_position = global_position
	_sample_position = global_position
	_create_world_renderer()


func _exit_tree() -> void:
	if is_instance_valid(_renderer):
		_renderer.queue_free()


func _process(delta: float) -> void:
	if _renderer == null or not _renderer.is_inside_tree():
		return

	if not permanent and node_ttl >= 0.0:
		node_ttl -= delta
		if node_ttl <= 0.0:
			queue_free()
			return

	var emitter_position := _get_emitter_position(delta)
	var moved := _last_position.distance_to(emitter_position) >= maxf(motion_delta, 0.001)
	if trail_enabled and moved:
		_append_point(emitter_position)
		_last_position = emitter_position
	elif not trail_enabled:
		_last_position = emitter_position

	var point_index := 0
	while point_index < _points.size():
		_life_points[point_index] += delta
		if _life_points[point_index] > maxf(lifespan, 0.001):
			_remove_point(point_index)
			continue
		point_index += 1

	_build_mesh()


func set_trail_visible(is_trail_visible: bool) -> void:
	_trail_visible = is_trail_visible
	if _renderer != null and is_instance_valid(_renderer):
		_renderer.visible = is_trail_visible
	if not is_trail_visible:
		clear_trail()


func clear_trail() -> void:
	_points.clear()
	_widths.clear()
	_life_points.clear()
	_last_position = global_position
	_sample_position = global_position
	if _immediate_mesh != null:
		_immediate_mesh.clear_surfaces()


func _append_point(emitter_position: Vector3) -> void:
	var width_axis := _get_stable_width_axis(emitter_position)
	var width_from := width_axis * from_width
	var width_to := width_axis * to_width

	_points.append(emitter_position)
	_widths.append([width_from, width_from - width_to])
	_life_points.append(0.0)

	while _points.size() > max_points:
		_remove_point(0)


func _remove_point(point_index: int) -> void:
	_points.remove_at(point_index)
	_widths.remove_at(point_index)
	_life_points.remove_at(point_index)


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
		var color := start_color.lerp(end_color, 1.0 - t)
		var width_scale := pow(1.0 - t, width_fade_power)
		var width_from := _widths[point_index][0] as Vector3
		var width_delta := _widths[point_index][1] as Vector3
		var half_width := width_from - width_scale * width_delta

		_immediate_mesh.surface_set_color(color)
		if scale_texture:
			_immediate_mesh.surface_set_uv(Vector2(motion_delta * point_index, 0.0))
			_immediate_mesh.surface_add_vertex(_renderer.to_local(_points[point_index] + half_width))
			_immediate_mesh.surface_set_uv(Vector2(motion_delta * (point_index + 1), 1.0))
			_immediate_mesh.surface_add_vertex(_renderer.to_local(_points[point_index] - half_width))
		else:
			_immediate_mesh.surface_set_uv(Vector2(t, 0.0))
			_immediate_mesh.surface_add_vertex(_renderer.to_local(_points[point_index] + half_width))
			_immediate_mesh.surface_set_uv(Vector2(t, 1.0))
			_immediate_mesh.surface_add_vertex(_renderer.to_local(_points[point_index] - half_width))
	_immediate_mesh.surface_end()


func _create_world_renderer() -> void:
	_immediate_mesh = ImmediateMesh.new()
	_renderer = MeshInstance3D.new()
	_renderer.name = "%sWorldTrail" % name
	_renderer.top_level = true
	_renderer.global_transform = Transform3D.IDENTITY
	_renderer.material_override = material_override
	_renderer.mesh = _immediate_mesh
	_renderer.visible = _trail_visible
	get_tree().root.add_child.call_deferred(_renderer)
	mesh = null


func _get_emitter_position(delta: float) -> Vector3:
	var current_position := global_position
	if sample_smoothing_rate <= 0.0:
		_sample_position = current_position
		return current_position

	var blend := clampf(sample_smoothing_rate * delta, 0.0, 1.0)
	_sample_position = _sample_position.lerp(current_position, blend)
	if max_sample_lag > 0.0:
		var offset := current_position - _sample_position
		if offset.length() > max_sample_lag:
			_sample_position = current_position - offset.normalized() * max_sample_lag
	return _sample_position


func _get_stable_width_axis(emitter_position: Vector3) -> Vector3:
	var movement_direction := Vector3.ZERO
	if not _points.is_empty():
		movement_direction = emitter_position - _points[_points.size() - 1]
	elif emitter_position.distance_squared_to(_last_position) > 0.000001:
		movement_direction = emitter_position - _last_position

	if movement_direction.length_squared() > 0.000001:
		movement_direction = movement_direction.normalized()
		var world_up_width_axis := movement_direction.cross(Vector3.UP)
		if world_up_width_axis.length_squared() > 0.000001:
			return world_up_width_axis.normalized()

		var world_right_width_axis := movement_direction.cross(Vector3.RIGHT)
		if world_right_width_axis.length_squared() > 0.000001:
			return world_right_width_axis.normalized()

	return global_transform.basis.x.normalized()
