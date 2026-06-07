class_name KillzoneCone
extends RefCounted
## Truncated-cone "killzone" volume trailing a target along its rearward axis.
##
## The cone apex is at the target. It is truncated at `min_distance` and reaches
## `base_radius` at `max_distance`; the radius grows linearly with axis distance.
## Shared by the bot pilot (steering/scoring) and the debug scenes/renderer
## (visualization) so the volume geometry stays defined in one place.

const MIN_DIRECTION_LENGTH_SQUARED := 0.000001

var min_distance: float
var max_distance: float
var base_radius: float


func _init(min_distance_value: float, max_distance_value: float, base_radius_value: float) -> void:
	min_distance = maxf(min_distance_value, 0.0)
	max_distance = maxf(max_distance_value, min_distance)
	base_radius = maxf(base_radius_value, 0.0)


static func behind_direction(target: Node3D) -> Vector3:
	var behind := target.global_transform.basis.z
	if behind.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return Vector3.BACK

	return behind.normalized()


func min_point(target: Node3D) -> Vector3:
	return target.global_position + behind_direction(target) * min_distance


func max_point(target: Node3D) -> Vector3:
	return target.global_position + behind_direction(target) * max_distance


func center_point(target: Node3D) -> Vector3:
	return target.global_position + behind_direction(target) * ((min_distance + max_distance) * 0.5)


func radius_at(axis_distance: float) -> float:
	if max_distance <= 0.0:
		return 0.0

	return base_radius * clampf(axis_distance / max_distance, 0.0, 1.0)


func contains(point: Vector3, target: Node3D) -> bool:
	var behind := behind_direction(target)
	var offset := point - target.global_position
	var axis_distance := offset.dot(behind)
	if axis_distance < min_distance or axis_distance > max_distance:
		return false

	var radial_offset := offset - behind * axis_distance
	return radial_offset.length() <= radius_at(axis_distance)


func nearest_point(point: Vector3, target: Node3D) -> Vector3:
	var target_position := target.global_position
	var behind := behind_direction(target)
	var offset := point - target_position
	var axis_distance := offset.dot(behind)
	var clamped_axis_distance := clampf(axis_distance, min_distance, max_distance)
	var radial_offset := offset - behind * axis_distance
	var radial_length := radial_offset.length()
	var radial_direction := Vector3.ZERO
	if radial_offset.length_squared() > MIN_DIRECTION_LENGTH_SQUARED:
		radial_direction = radial_offset / radial_length

	var clamped_radial_distance := minf(radial_length, radius_at(clamped_axis_distance))
	return target_position + behind * clamped_axis_distance + radial_direction * clamped_radial_distance


func distance_to(point: Vector3, target: Node3D) -> float:
	return point.distance_to(nearest_point(point, target))


## Appends frustum outline line segments (two rings plus connecting ribs) to an
## ImmediateMesh whose PRIMITIVE_LINES surface is already begun by the caller.
static func append_frustum_lines(
	mesh: ImmediateMesh,
	min_center: Vector3,
	max_center: Vector3,
	min_radius: float,
	max_radius: float,
	color: Color,
	segment_count: int = 24
) -> void:
	var segments := maxi(segment_count, 3)
	var axis := max_center - min_center
	if axis.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		_append_cross_lines(mesh, max_center, maxf(max_radius, 0.0), color)
		return

	var axis_direction := axis.normalized()
	var side_axis := axis_direction.cross(Vector3.UP)
	if side_axis.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		side_axis = axis_direction.cross(Vector3.RIGHT)
	if side_axis.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return
	side_axis = side_axis.normalized()
	var up_axis := side_axis.cross(axis_direction).normalized()

	@warning_ignore("integer_division")
	var rib_step := maxi(segments / 4, 1)
	var first_min := Vector3.ZERO
	var first_max := Vector3.ZERO
	var previous_min := Vector3.ZERO
	var previous_max := Vector3.ZERO
	for index in range(segments):
		var angle := TAU * float(index) / float(segments)
		var ring_direction := side_axis * cos(angle) + up_axis * sin(angle)
		var min_ring_point := min_center + ring_direction * maxf(min_radius, 0.0)
		var max_ring_point := max_center + ring_direction * maxf(max_radius, 0.0)
		if index == 0:
			first_min = min_ring_point
			first_max = max_ring_point
		else:
			_append_line(mesh, previous_min, min_ring_point, color)
			_append_line(mesh, previous_max, max_ring_point, color)

		if index % rib_step == 0:
			_append_line(mesh, min_ring_point, max_ring_point, color)

		previous_min = min_ring_point
		previous_max = max_ring_point

	_append_line(mesh, previous_min, first_min, color)
	_append_line(mesh, previous_max, first_max, color)


static func _append_cross_lines(mesh: ImmediateMesh, center: Vector3, radius: float, color: Color) -> void:
	if radius <= 0.0:
		return

	_append_line(mesh, center - Vector3.RIGHT * radius, center + Vector3.RIGHT * radius, color)
	_append_line(mesh, center - Vector3.UP * radius, center + Vector3.UP * radius, color)
	_append_line(mesh, center - Vector3.FORWARD * radius, center + Vector3.FORWARD * radius, color)


static func _append_line(mesh: ImmediateMesh, from_point: Vector3, to_point: Vector3, color: Color) -> void:
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(from_point)
	mesh.surface_add_vertex(to_point)
