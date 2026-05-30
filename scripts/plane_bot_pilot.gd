extends Node

@export var desired_range: float = 100.0
@export var range_tolerance: float = 50.0
@export var orbit_direction: float = 1.0
@export var orbit_radial_pull: float = 0.35
@export var orbit_vertical_correction: float = 0.002

@export var approach_throttle_input: float = 0.9
@export var orbit_throttle_input: float = 0.45
@export var retreat_throttle_input: float = 0.2
@export var minimum_forward_speed: float = 35.0

@export var minimum_safe_altitude: float = 180.0
@export var terrain_prediction_time: float = 2.4
@export var terrain_probe_min_distance: float = 180.0
@export var terrain_escape_pitch_up_input: float = -0.85
@export var terrain_escape_yaw_weight: float = 0.7

@export var roll_gain: float = 1.8
@export var pitch_gain: float = 1.2
@export var yaw_gain: float = 1.0
@export var target_reacquire_interval: float = 0.4

@export var follow_target_path: NodePath

var _plane: RigidBody3D
var _follow_target: Node3D
var _reacquire_timer := 0.0
var _exclude_rids: Array[RID] = []


func _ready() -> void:
	_plane = get_parent() as RigidBody3D
	if _plane == null:
		set_physics_process(false)
		return

	_exclude_rids = [_plane.get_rid()]
	_resolve_follow_target(true)


func set_follow_target(target: Node3D = null) -> void:
	_follow_target = target


func _physics_process(delta: float) -> void:
	if _plane == null:
		return

	if not is_instance_valid(_follow_target):
		_follow_target = null

	_reacquire_timer += delta
	if _follow_target == null and _reacquire_timer >= target_reacquire_interval:
		_reacquire_timer = 0.0
		_resolve_follow_target(false)

	if _follow_target == null:
		_apply_controls(0.0, 0.0, 0.0, 0.1)
		return

	var terrain_response := _get_terrain_avoidance_response()
	if terrain_response["active"]:
		var avoid_direction: Vector3 = terrain_response["direction"]
		var avoid_controls := _controls_from_world_direction(avoid_direction)
		var avoid_yaw: float = avoid_controls["yaw"] * terrain_escape_yaw_weight
		_apply_controls(
			avoid_controls["roll"],
			minf(avoid_controls["pitch"], terrain_escape_pitch_up_input),
			avoid_yaw,
			0.9
		)
		return

	var target_offset := _follow_target.global_position - _plane.global_position
	var target_distance := target_offset.length()
	if target_distance <= 0.001:
		_apply_controls(0.0, 0.0, 0.0, orbit_throttle_input)
		return

	var control_mode := "approach"
	if target_distance <= desired_range + range_tolerance:
		control_mode = "orbit"

	var target_direction := target_offset / target_distance
	var target_throttle: float = approach_throttle_input

	if control_mode == "approach":
		target_throttle = approach_throttle_input
		if _plane.linear_velocity.length() < minimum_forward_speed:
			target_throttle = 1.0
	elif control_mode == "orbit":
		var radial_from_target := -target_direction
		var up_axis := Vector3.UP
		var tangent := up_axis.cross(radial_from_target)
		if tangent.length_squared() < 0.00001:
			tangent = _plane.global_transform.basis.x
		else:
			tangent = tangent.normalized()

		var outward_error := clampf((desired_range - target_distance) / maxf(range_tolerance, 1.0), -1.0, 1.0)
		var inward_pull := radial_from_target * (orbit_radial_pull * outward_error)
		var altitude_error := (_follow_target.global_position.y - _plane.global_position.y) * orbit_vertical_correction
		var altitude_adjust := Vector3.UP * altitude_error
		var orbit_sign := 1.0 if orbit_direction >= 0.0 else -1.0
		target_direction = (tangent * orbit_sign) + inward_pull + altitude_adjust
		target_direction = target_direction.normalized()

		target_throttle = orbit_throttle_input
		if target_distance < desired_range - range_tolerance:
			target_throttle = retreat_throttle_input

	var controls := _controls_from_world_direction(target_direction)
	_apply_controls(controls["roll"], controls["pitch"], controls["yaw"], target_throttle)


func _controls_from_world_direction(world_direction: Vector3) -> Dictionary:
	var desired_direction := world_direction
	if desired_direction.length_squared() <= 0.00001:
		desired_direction = -_plane.global_transform.basis.z
	else:
		desired_direction = desired_direction.normalized()

	var plane_basis := _plane.global_transform.basis.orthonormalized()
	var local_direction := plane_basis.transposed() * desired_direction

	var target_roll := clampf(-local_direction.x * roll_gain, -1.0, 1.0)
	var target_pitch := clampf(-local_direction.y * pitch_gain, -1.0, 1.0)
	var target_yaw := clampf(local_direction.x * yaw_gain, -1.0, 1.0)

	return {
		"roll": target_roll,
		"pitch": target_pitch,
		"yaw": target_yaw,
	}


func _get_terrain_avoidance_response() -> Dictionary:
	var current_velocity := _plane.linear_velocity
	var current_speed := current_velocity.length()
	var nose_forward := -_plane.global_transform.basis.z.normalized()

	var probe_direction := nose_forward
	if current_speed > 1.0:
		probe_direction = current_velocity / current_speed

	var probe_distance := maxf(terrain_probe_min_distance, current_speed * terrain_prediction_time)
	var forward_start := _plane.global_position + Vector3.UP * 3.0
	var forward_end := forward_start + (probe_direction * probe_distance)
	var forward_hit := _intersect_ray(forward_start, forward_end)
	if not forward_hit.is_empty():
		var hit_normal: Vector3 = forward_hit.get("normal", Vector3.UP)
		var avoid_direction := (hit_normal + Vector3.UP * 0.7).normalized()
		return {
			"active": true,
			"direction": avoid_direction,
		}

	var down_start := _plane.global_position
	var down_end := down_start + Vector3.DOWN * minimum_safe_altitude
	var down_hit := _intersect_ray(down_start, down_end)
	if not down_hit.is_empty():
		var climb_direction := (nose_forward + Vector3.UP * 1.6).normalized()
		return {
			"active": true,
			"direction": climb_direction,
		}

	return {
		"active": false,
		"direction": Vector3.ZERO,
	}


func _intersect_ray(from_point: Vector3, to_point: Vector3) -> Dictionary:
	var world_ref := _plane.get_world_3d()
	if world_ref == null:
		return {}

	var query := PhysicsRayQueryParameters3D.create(from_point, to_point)
	query.exclude = _exclude_rids
	query.collide_with_areas = false
	return world_ref.direct_space_state.intersect_ray(query)


func _resolve_follow_target(force: bool) -> void:
	if _follow_target != null and not force:
		return
	if follow_target_path.is_empty():
		return

	_follow_target = get_node_or_null(follow_target_path) as Node3D


func _apply_controls(roll_value: float, pitch_value: float, yaw_value: float, throttle_value: float) -> void:
	if _plane.has_method("set_bot_control_inputs"):
		_plane.call(
			"set_bot_control_inputs",
			clampf(roll_value, -1.0, 1.0),
			clampf(pitch_value, -1.0, 1.0),
			clampf(yaw_value, -1.0, 1.0),
			clampf(throttle_value, -1.0, 1.0)
		)
