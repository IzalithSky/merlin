extends MeshInstance3D

const MIN_VECTOR_LENGTH_SQUARED := 0.000001
const MIN_ARROW_HEAD_LENGTH := 0.08

@export var force_scale: float = 0.001
@export var torque_scale: float = 0.0004
@export var min_arrow_length: float = 0.2
@export var max_arrow_length: float = 80.0
@export var head_length_ratio: float = 0.18
@export var head_angle_deg: float = 24.0

var _immediate_mesh := ImmediateMesh.new()
var _line_material := StandardMaterial3D.new()
var _arrows: Array[Dictionary] = []


func _ready() -> void:
	mesh = _immediate_mesh
	top_level = true
	global_transform = Transform3D.IDENTITY
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.vertex_color_use_as_albedo = true
	_line_material.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
	material_override = _line_material


func begin_frame() -> void:
	_arrows.clear()
	global_transform = Transform3D.IDENTITY


func push_force(origin_world: Vector3, force_world: Vector3, color: Color) -> void:
	_push_arrow_scaled(origin_world, force_world, color, force_scale)


func push_torque(origin_world: Vector3, torque_world: Vector3, color: Color) -> void:
	_push_arrow_scaled(origin_world, torque_world, color, torque_scale)


func end_frame() -> void:
	_immediate_mesh.clear_surfaces()
	if _arrows.is_empty():
		return

	_immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material_override)
	for arrow_data in _arrows:
		var origin: Vector3 = arrow_data["origin"]
		var arrow_vector: Vector3 = arrow_data["vector"]
		var color: Color = arrow_data["color"]
		_append_arrow(origin, arrow_vector, color)
	_immediate_mesh.surface_end()


func clear_frame() -> void:
	_arrows.clear()
	_immediate_mesh.clear_surfaces()


func _push_arrow_scaled(origin_world: Vector3, world_vector: Vector3, color: Color, vector_scale: float) -> void:
	if world_vector.length_squared() < MIN_VECTOR_LENGTH_SQUARED:
		return

	var scaled_vector := world_vector * vector_scale
	var length := scaled_vector.length()
	if length <= 0.0:
		return

	var clamped_length := clampf(length, min_arrow_length, max_arrow_length)
	var arrow_vector := scaled_vector.normalized() * clamped_length
	_arrows.append({
		"origin": origin_world,
		"vector": arrow_vector,
		"color": color
	})


func _append_arrow(origin: Vector3, arrow_vector: Vector3, color: Color) -> void:
	var arrow_length := arrow_vector.length()
	if arrow_length <= 0.0:
		return

	var direction := arrow_vector / arrow_length
	var tip := origin + arrow_vector
	var head_length := maxf(min(arrow_length * head_length_ratio, arrow_length * 0.5), MIN_ARROW_HEAD_LENGTH)
	var head_base := tip - direction * head_length

	var side_axis := direction.cross(Vector3.UP)
	if side_axis.length_squared() < MIN_VECTOR_LENGTH_SQUARED:
		side_axis = direction.cross(Vector3.RIGHT)
	if side_axis.length_squared() < MIN_VECTOR_LENGTH_SQUARED:
		return
	side_axis = side_axis.normalized()

	var wing_offset := side_axis * (head_length * tan(deg_to_rad(head_angle_deg)))
	var head_left := head_base + wing_offset
	var head_right := head_base - wing_offset

	_immediate_mesh.surface_set_color(color)
	_immediate_mesh.surface_add_vertex(origin)
	_immediate_mesh.surface_add_vertex(tip)
	_immediate_mesh.surface_add_vertex(tip)
	_immediate_mesh.surface_add_vertex(head_left)
	_immediate_mesh.surface_add_vertex(tip)
	_immediate_mesh.surface_add_vertex(head_right)
