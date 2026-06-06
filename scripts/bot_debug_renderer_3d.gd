extends Node3D

const MIN_VECTOR_LENGTH_SQUARED := 0.000001
const MIN_ARROW_HEAD_LENGTH := 1.5

@export var forward_axis_length: float = 90.0
@export var up_axis_length: float = 60.0
@export var killzone_marker_radius: float = 28.0
@export var label_min_height: float = 18.0
@export var label_max_height: float = 90.0
@export var label_offset_far_range: float = 1000.0
@export var arrow_head_length_ratio: float = 0.18
@export var arrow_head_angle_deg: float = 24.0

var _immediate_mesh := ImmediateMesh.new()
var _line_material := StandardMaterial3D.new()
var _line_mesh_instance := MeshInstance3D.new()
var _label := Label3D.new()


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_setup_line_mesh()
	_setup_label()


func update_visuals(
	bot_position: Vector3,
	forward_direction: Vector3,
	up_direction: Vector3,
	has_target: bool,
	intent_position: Vector3,
	has_killzone: bool,
	killzone_position: Vector3,
	has_source_target: bool,
	source_target_position: Vector3,
	mode_text: String
) -> void:
	if not visible:
		clear()
		return

	global_transform = Transform3D.IDENTITY
	_label.visible = true
	_label.text = mode_text
	_label.global_position = bot_position + Vector3.UP * _get_label_offset_height(bot_position)

	_immediate_mesh.clear_surfaces()
	_immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _line_material)
	_append_arrow(bot_position, _safe_direction(forward_direction) * forward_axis_length, Color(0.2, 0.95, 1.0, 1.0))
	_append_arrow(bot_position, _safe_direction(up_direction) * up_axis_length, Color(0.35, 1.0, 0.25, 1.0))

	if has_target:
		_append_line(bot_position, intent_position, Color(1.0, 0.92, 0.2, 1.0))

	if has_killzone:
		_append_cross(killzone_position, killzone_marker_radius, Color(1.0, 0.42, 0.05, 1.0))
		if has_source_target:
			_append_line(source_target_position, killzone_position, Color(1.0, 0.42, 0.05, 0.9))

	_immediate_mesh.surface_end()


func clear() -> void:
	_immediate_mesh.clear_surfaces()
	_label.visible = false


func _setup_line_mesh() -> void:
	_line_mesh_instance.mesh = _immediate_mesh
	_line_mesh_instance.top_level = true
	_line_mesh_instance.global_transform = Transform3D.IDENTITY
	_line_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.vertex_color_use_as_albedo = true
	_line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_line_material.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
	_line_mesh_instance.material_override = _line_material
	add_child(_line_mesh_instance)


func _setup_label() -> void:
	_label.top_level = true
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.no_depth_test = true
	_label.pixel_size = 0.00075
	_label.modulate = Color(0.75, 1.0, 0.35, 1.0)
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 1.0)
	_label.outline_size = 2
	_label.text = ""
	add_child(_label)


func _get_label_offset_height(bot_position: Vector3) -> float:
	var viewport := get_viewport()
	if viewport == null:
		return label_min_height

	var camera := viewport.get_camera_3d()
	if camera == null:
		return label_min_height

	var distance := bot_position.distance_to(camera.global_position)
	var far_range := maxf(label_offset_far_range, 1.0)
	var close_weight := 1.0 - clampf(distance / far_range, 0.0, 1.0)
	return lerpf(label_min_height, label_max_height, close_weight)


func _safe_direction(direction: Vector3) -> Vector3:
	if direction.length_squared() <= MIN_VECTOR_LENGTH_SQUARED:
		return Vector3.FORWARD

	return direction.normalized()


func _append_arrow(origin: Vector3, arrow_vector: Vector3, color: Color) -> void:
	var arrow_length := arrow_vector.length()
	if arrow_length <= 0.0:
		return

	var direction := arrow_vector / arrow_length
	var tip := origin + arrow_vector
	var head_length := maxf(min(arrow_length * arrow_head_length_ratio, arrow_length * 0.5), MIN_ARROW_HEAD_LENGTH)
	var head_base := tip - direction * head_length

	var side_axis := direction.cross(Vector3.UP)
	if side_axis.length_squared() < MIN_VECTOR_LENGTH_SQUARED:
		side_axis = direction.cross(Vector3.RIGHT)
	if side_axis.length_squared() < MIN_VECTOR_LENGTH_SQUARED:
		return
	side_axis = side_axis.normalized()

	var wing_offset := side_axis * (head_length * tan(deg_to_rad(arrow_head_angle_deg)))
	_append_line(origin, tip, color)
	_append_line(tip, head_base + wing_offset, color)
	_append_line(tip, head_base - wing_offset, color)


func _append_cross(center: Vector3, radius: float, color: Color) -> void:
	var marker_radius := maxf(radius, 0.0)
	if marker_radius <= 0.0:
		return

	_append_line(center - Vector3.RIGHT * marker_radius, center + Vector3.RIGHT * marker_radius, color)
	_append_line(center - Vector3.UP * marker_radius, center + Vector3.UP * marker_radius, color)
	_append_line(center - Vector3.FORWARD * marker_radius, center + Vector3.FORWARD * marker_radius, color)


func _append_line(from_point: Vector3, to_point: Vector3, color: Color) -> void:
	_immediate_mesh.surface_set_color(color)
	_immediate_mesh.surface_add_vertex(from_point)
	_immediate_mesh.surface_add_vertex(to_point)
