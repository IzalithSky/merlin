extends MeshInstance3D

@export var outer_radius: float = 12.0
@export var velocity_radius: float = 10.0
@export var horizon_radius: float = 8.0
@export var outer_down_offset: float = 1.5
@export var ring_segments: int = 64
@export var tube_segments: int = 8
@export var guide_arc_span_deg: float = 30.0
@export var outer_ring_thickness: float = 0.18
@export var velocity_ring_thickness: float = 0.18
@export var horizon_ring_thickness: float = 0.18
@export var outer_ring_color: Color = Color(1.0, 1.0, 1.0, 0.55)
@export var velocity_ring_color: Color = Color(0.55, 0.8, 1.0, 0.55)
@export var horizon_ring_color: Color = Color(0.35, 1.0, 0.45, 0.55)

const MIN_DIRECTION_LENGTH_SQUARED := 0.000001

var _plane: RigidBody3D
var _immediate_mesh := ImmediateMesh.new()


func _ready() -> void:
	_plane = get_parent() as RigidBody3D
	mesh = _immediate_mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color.WHITE
	material.no_depth_test = false
	material.vertex_color_use_as_albedo = true
	material_override = material


func _process(_delta: float) -> void:
	_redraw_rings()


func _redraw_rings() -> void:
	_immediate_mesh.clear_surfaces()
	if _plane == null or not is_instance_valid(_plane):
		return

	var plane_basis := _plane.global_transform.basis.orthonormalized()
	var plane_right := plane_basis.x
	var plane_up := plane_basis.y
	var plane_forward := -plane_basis.z
	var center := _plane.global_position
	var lowered_center := center - plane_up * outer_down_offset

	_append_ring(
		lowered_center,
		outer_radius,
		plane_right,
		plane_forward,
		outer_ring_thickness,
		outer_ring_color
	)
	_append_guide_arcs(
		lowered_center,
		outer_radius,
		plane_forward,
		plane_up,
		outer_ring_thickness,
		outer_ring_color
	)

	var velocity := _plane.linear_velocity
	var velocity_forward := plane_forward
	if velocity.length_squared() > MIN_DIRECTION_LENGTH_SQUARED:
		velocity_forward = velocity.normalized()
	var velocity_plane_tangent := velocity_forward - plane_right * velocity_forward.dot(plane_right)
	if velocity_plane_tangent.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		velocity_plane_tangent = plane_forward
	else:
		velocity_plane_tangent = velocity_plane_tangent.normalized()
	var velocity_ring_normal := plane_right.cross(velocity_plane_tangent).normalized()
	_append_ring(
		lowered_center,
		velocity_radius,
		plane_right,
		velocity_plane_tangent,
		velocity_ring_thickness,
		velocity_ring_color
	)
	_append_guide_arcs(
		lowered_center,
		velocity_radius,
		velocity_forward,
		velocity_ring_normal,
		velocity_ring_thickness,
		velocity_ring_color
	)

	_append_ring(
		lowered_center,
		horizon_radius,
		Vector3.RIGHT,
		Vector3.FORWARD,
		horizon_ring_thickness,
		horizon_ring_color
	)


func _append_ring(
	center: Vector3,
	radius: float,
	axis_a: Vector3,
	axis_b: Vector3,
	thickness: float,
	color: Color
) -> void:
	_append_arc(center, radius, axis_a, axis_b, thickness, color, 0.0, TAU)


func _append_guide_arcs(
	center: Vector3,
	radius: float,
	attach_direction: Vector3,
	ring_normal: Vector3,
	thickness: float,
	color: Color
) -> void:
	var half_span := 0.5 * deg_to_rad(guide_arc_span_deg)
	_append_arc(center, radius, attach_direction, ring_normal, thickness, color, -half_span, half_span)
	_append_arc(center, radius, attach_direction, ring_normal, thickness, color, PI - half_span, PI + half_span)


func _append_arc(
	center: Vector3,
	radius: float,
	axis_a: Vector3,
	axis_b: Vector3,
	thickness: float,
	color: Color,
	angle_from: float,
	angle_to: float
) -> void:
	var resolved_radius := maxf(radius, 0.0)
	var major_segments := maxi(int(round(float(ring_segments) * absf(angle_to - angle_from) / TAU)), 4)
	var minor_segments := maxi(tube_segments, 3)
	var axis_a_normalized := axis_a.normalized()
	var axis_b_normalized := axis_b.normalized()
	var tube_binormal := axis_a_normalized.cross(axis_b_normalized).normalized()
	var half_thickness := maxf(thickness, 0.001) * 0.5

	_immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	_immediate_mesh.surface_set_color(color)

	for major_index in range(major_segments):
		var major_angle_from := lerpf(angle_from, angle_to, float(major_index) / float(major_segments))
		var major_angle_to := lerpf(angle_from, angle_to, float(major_index + 1) / float(major_segments))
		var tube_normal_from := axis_a_normalized * cos(major_angle_from) + axis_b_normalized * sin(major_angle_from)
		var tube_normal_to := axis_a_normalized * cos(major_angle_to) + axis_b_normalized * sin(major_angle_to)
		var center_from := center + tube_normal_from * resolved_radius
		var center_to := center + tube_normal_to * resolved_radius

		for minor_index in range(minor_segments):
			var minor_angle_from := (TAU * float(minor_index)) / float(minor_segments)
			var minor_angle_to := (TAU * float(minor_index + 1)) / float(minor_segments)
			var offset_from_a := (
				tube_normal_from * cos(minor_angle_from) + tube_binormal * sin(minor_angle_from)
			) * half_thickness
			var offset_from_b := (
				tube_normal_from * cos(minor_angle_to) + tube_binormal * sin(minor_angle_to)
			) * half_thickness
			var offset_to_a := (
				tube_normal_to * cos(minor_angle_from) + tube_binormal * sin(minor_angle_from)
			) * half_thickness
			var offset_to_b := (
				tube_normal_to * cos(minor_angle_to) + tube_binormal * sin(minor_angle_to)
			) * half_thickness

			_append_triangle(center_from + offset_from_a, center_to + offset_to_a, center_from + offset_from_b)
			_append_triangle(center_from + offset_from_b, center_to + offset_to_a, center_to + offset_to_b)

	_immediate_mesh.surface_end()


func _append_triangle(point_a: Vector3, point_b: Vector3, point_c: Vector3) -> void:
	_immediate_mesh.surface_add_vertex(to_local(point_a))
	_immediate_mesh.surface_add_vertex(to_local(point_b))
	_immediate_mesh.surface_add_vertex(to_local(point_c))
