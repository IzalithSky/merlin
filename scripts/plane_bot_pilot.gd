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
@export var speed_recovery_enter_speed: float = 100.0
@export var speed_recovery_exit_speed: float = 150.0
@export var speed_recovery_min_nose_down_input: float = 0.25
@export var speed_recovery_max_nose_down_input: float = 0.95
@export var speed_recovery_base_throttle_input: float = 0.55
@export var speed_recovery_throttle_boost_input: float = 0.35
@export var speed_recovery_pitch_response_rate: float = 1.2
@export var speed_recovery_max_descent_speed: float = 35.0
@export var speed_recovery_altitude_soft_floor: float = 240.0
@export var speed_recovery_altitude_hard_floor: float = 150.0
@export var speed_recovery_max_dive_angle_deg: float = 24.0
@export var speed_recovery_flight_path_kp: float = 2.1
@export var speed_recovery_flight_path_kd: float = 0.9
@export var speed_recovery_pitch_rate_damping: float = 0.35
@export var speed_recovery_speed_trend_damping: float = 0.15
@export var speed_recovery_max_nose_up_input: float = 0.35
@export var speed_recovery_accel_smoothing: float = 0.25

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
var _speed_recovery_active := false
var _speed_recovery_pitch_command := 0.0
var _last_forward_speed := 0.0
var _speed_recovery_forward_accel := 0.0
var _speed_recovery_last_dive_angle := 0.0


func _ready() -> void:
	_plane = get_parent() as RigidBody3D
	if _plane == null:
		set_physics_process(false)
		return

	_exclude_rids = [_plane.get_rid()]
	_last_forward_speed = _get_forward_speed()
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

	var forward_speed := _get_forward_speed()
	_update_forward_speed_trend(forward_speed, delta)
	_update_sustain_turn_limiter_mode(forward_speed)

	var terrain_response := _get_terrain_avoidance_response()
	if terrain_response["active"]:
		_speed_recovery_pitch_command = 0.0
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

	_update_speed_recovery_state(forward_speed)
	if _speed_recovery_active:
		_apply_speed_recovery_controls(forward_speed, delta)
		return

	if _follow_target == null:
		_apply_controls(0.0, 0.0, 0.0, 0.1)
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


func _update_speed_recovery_state(forward_speed: float) -> void:
	if _speed_recovery_active:
		if forward_speed >= speed_recovery_exit_speed:
			_speed_recovery_active = false
			_speed_recovery_pitch_command = 0.0
			_speed_recovery_last_dive_angle = 0.0
		return

	if forward_speed < speed_recovery_enter_speed:
		_speed_recovery_active = true
		_speed_recovery_pitch_command = 0.0
		_speed_recovery_last_dive_angle = _get_dive_angle_rad()


func _update_sustain_turn_limiter_mode(forward_speed: float) -> void:
	if not _plane.has_method("set_sustain_turn_limiter_runtime_enabled"):
		return

	# Above recovery speed the bot may pull to max-lift AoA; below it, preserve energy.
	var should_use_sustain_turns := forward_speed <= speed_recovery_exit_speed
	_plane.call("set_sustain_turn_limiter_runtime_enabled", should_use_sustain_turns)


func _apply_speed_recovery_controls(forward_speed: float, delta: float) -> void:
	var span := maxf(speed_recovery_exit_speed - speed_recovery_enter_speed, 1.0)
	var speed_deficit := maxf(speed_recovery_exit_speed - forward_speed, 0.0)
	var recovery_ratio := clampf(speed_deficit / span, 0.0, 1.0)
	var eased_ratio := _ease_in_out(recovery_ratio)

	# Positive pitch input drives the plane nose down in this controller.
	var target_dive_angle := deg_to_rad(maxf(speed_recovery_max_dive_angle_deg, 0.0)) * eased_ratio
	var current_dive_angle := _get_dive_angle_rad()
	var dive_rate := 0.0
	if delta > 0.0:
		dive_rate = (current_dive_angle - _speed_recovery_last_dive_angle) / delta
	_speed_recovery_last_dive_angle = current_dive_angle

	var dive_error := target_dive_angle - current_dive_angle
	var local_pitch_rate := _get_local_pitch_rate_rad_per_s()
	var pitch_command := (
		dive_error * maxf(speed_recovery_flight_path_kp, 0.0) -
		dive_rate * maxf(speed_recovery_flight_path_kd, 0.0) -
		local_pitch_rate * maxf(speed_recovery_pitch_rate_damping, 0.0) -
		_speed_recovery_forward_accel * maxf(speed_recovery_speed_trend_damping, 0.0)
	)

	var min_pitch_input := -maxf(speed_recovery_max_nose_up_input, 0.0)
	var max_pitch_input := lerpf(
		maxf(speed_recovery_min_nose_down_input, 0.0),
		maxf(speed_recovery_max_nose_down_input, 0.0),
		eased_ratio
	)
	pitch_command = clampf(pitch_command, min_pitch_input, max_pitch_input)

	# Reduce nose-down authority if already descending hard.
	var downward_speed := maxf(-_plane.linear_velocity.y, 0.0)
	if downward_speed > speed_recovery_max_descent_speed:
		var descent_excess := downward_speed - speed_recovery_max_descent_speed
		var descent_scale := 1.0 / (1.0 + (descent_excess / maxf(speed_recovery_max_descent_speed, 1.0)))
		if pitch_command > 0.0:
			pitch_command *= clampf(descent_scale, 0.0, 1.0)

	# Fade nose-down command close to terrain.
	var ground_clearance := _estimate_ground_clearance(maxf(speed_recovery_altitude_soft_floor, speed_recovery_altitude_hard_floor))
	if ground_clearance <= speed_recovery_altitude_hard_floor:
		pitch_command = minf(pitch_command, 0.0)
	elif ground_clearance < speed_recovery_altitude_soft_floor:
		var clearance_span := maxf(speed_recovery_altitude_soft_floor - speed_recovery_altitude_hard_floor, 1.0)
		var clearance_t := (ground_clearance - speed_recovery_altitude_hard_floor) / clearance_span
		if pitch_command > 0.0:
			pitch_command *= clampf(clearance_t, 0.0, 1.0)

	var pitch_step := maxf(speed_recovery_pitch_response_rate * delta, 0.0)
	_speed_recovery_pitch_command = move_toward(_speed_recovery_pitch_command, pitch_command, pitch_step)
	var throttle_ratio := clampf(recovery_ratio * (1.0 - maxf(current_dive_angle, 0.0) / deg_to_rad(45.0)), 0.0, 1.0)
	var throttle_value := speed_recovery_base_throttle_input + (speed_recovery_throttle_boost_input * throttle_ratio)

	_apply_controls(0.0, _speed_recovery_pitch_command, 0.0, throttle_value)


func _update_forward_speed_trend(forward_speed: float, delta: float) -> void:
	if delta <= 0.0:
		_last_forward_speed = forward_speed
		return

	var accel := (forward_speed - _last_forward_speed) / delta
	var smoothing := clampf(speed_recovery_accel_smoothing, 0.0, 1.0)
	_speed_recovery_forward_accel = lerpf(_speed_recovery_forward_accel, accel, smoothing)
	_last_forward_speed = forward_speed


func _get_dive_angle_rad() -> float:
	var velocity := _plane.linear_velocity
	var speed := velocity.length()
	if speed <= 0.1:
		return 0.0

	var flight_path_angle := asin(clampf(velocity.y / speed, -1.0, 1.0))
	return -flight_path_angle


func _get_local_pitch_rate_rad_per_s() -> float:
	var basis := _plane.global_transform.basis.orthonormalized()
	var local_angular_velocity := basis.transposed() * _plane.angular_velocity
	return local_angular_velocity.x


func _ease_in_out(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


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


func _estimate_ground_clearance(max_distance: float) -> float:
	var sample_distance := maxf(max_distance, 1.0)
	var from_point := _plane.global_position
	var to_point := from_point + Vector3.DOWN * sample_distance
	var hit := _intersect_ray(from_point, to_point)
	if hit.is_empty():
		return sample_distance

	var hit_position: Vector3 = hit.get("position", to_point)
	return from_point.distance_to(hit_position)


func _get_forward_speed() -> float:
	var forward_axis := -_plane.global_transform.basis.z
	return _plane.linear_velocity.dot(forward_axis)


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
