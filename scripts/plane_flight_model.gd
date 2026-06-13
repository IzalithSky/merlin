class_name PlaneFlightModel
extends RefCounted

var _plane: PlaneCharacter


func _init(plane: PlaneCharacter) -> void:
	_plane = plane


func compute_control_state(delta: float) -> void:
	_compute_control_state(delta)


func compute_aoa() -> void:
	_compute_aoa()


func apply_thrust() -> void:
	var thrust_force := _get_thrust_force_world()
	if thrust_force.length_squared() <= 0.0:
		return

	_plane.apply_central_force(thrust_force)
	_plane.set_debug_thrust_force_world(thrust_force)
	_plane._push_debug_force(_plane.global_position, thrust_force, _plane.DEBUG_COLOR_THRUST)


func apply_plane_torque() -> void:
	var control_coefficient := maxf(_sample_aero_table(_plane.control_authority_coefficient_table, _plane._frame_air_speed), 0.0)
	var limited_pitch_input := _get_effective_pitch_input()
	var p_in := -limited_pitch_input
	var y_in := _plane.yaw_input
	var r_in := _plane.roll_input

	var control_torque := _plane.base_control_torque * control_coefficient
	var pitch_torque := p_in * control_torque * _plane.max_pitch
	var yaw_torque := y_in * control_torque * _plane.max_yaw
	var roll_torque := r_in * control_torque * _plane.max_roll
	var pitch_yaw_torque_world := _plane._frame_body_basis * Vector3(pitch_torque, yaw_torque, 0.0)
	var roll_torque_world := _plane._frame_body_basis * Vector3(0.0, 0.0, roll_torque)
	var control_torque_world := pitch_yaw_torque_world + roll_torque_world
	if control_torque_world.length_squared() <= 0.000001 or not control_torque_world.is_finite():
		return

	_plane.apply_torque(control_torque_world)
	_plane._push_debug_torque(_plane.global_position, pitch_yaw_torque_world, _plane.DEBUG_COLOR_PITCH_YAW_FORCE)
	_plane._push_debug_torque(_plane.global_position, roll_torque_world, _plane.DEBUG_COLOR_ROLL_FORCE)


func apply_aerodynamic_forces() -> void:
	if _plane._frame_air_speed_squared < _plane.MIN_AERODYNAMIC_SPEED_SQUARED:
		return

	if _plane._frame_air_speed <= 0.0:
		return
	var airflow_direction := _plane._frame_airflow_direction
	var dynamic_pressure := _plane._frame_dynamic_pressure

	var lift_coefficient := _sample_aero_table(_plane.lift_coefficient_table, _plane.aoa_deg)
	var drag_coefficient := maxf(_sample_aero_table(_plane.drag_coefficient_table, _plane.aoa_deg), 0.0)
	var side_force_coefficient := _sample_aero_table(_plane.side_force_coefficient_table, _plane.sideslip_deg)

	var drag_force_magnitude := dynamic_pressure * _plane.reference_area * drag_coefficient
	var lift_force_magnitude := dynamic_pressure * _plane.reference_area * lift_coefficient
	var side_force_magnitude := dynamic_pressure * _plane.reference_area * side_force_coefficient
	var drag_force := -airflow_direction * drag_force_magnitude

	var right_axis := _plane._frame_right_axis
	var lift_axis := right_axis.cross(airflow_direction)
	if lift_axis.length_squared() < _plane.MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		lift_axis = _plane._frame_up_axis
	else:
		lift_axis = lift_axis.normalized()

	var side_axis := airflow_direction.cross(lift_axis)
	if side_axis.length_squared() < _plane.MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		side_axis = right_axis
	else:
		side_axis = side_axis.normalized()
	var lift_force := lift_axis * lift_force_magnitude
	var side_force := side_axis * side_force_magnitude

	var aerodynamic_force := drag_force + lift_force + side_force
	_plane.set_debug_drag_force_world(drag_force)
	_plane.set_debug_lift_force_world(lift_force)
	_plane.set_debug_side_force_world(side_force)

	if aerodynamic_force.is_finite():
		_plane.apply_central_force(aerodynamic_force)
		_plane._push_debug_force(_plane.global_position, lift_force, _plane.DEBUG_COLOR_LIFT)
		_plane._push_debug_force(_plane.global_position, drag_force, _plane.DEBUG_COLOR_DRAG)


func apply_directional_alignment() -> void:
	if _plane._frame_air_speed_squared < _plane.MIN_AERODYNAMIC_SPEED_SQUARED:
		return
	if not _plane.is_bot_controlled and not _plane._stabilization_assist_enabled:
		return

	var stabilization_torque := Vector3.ZERO
	var yaw_stabilization_active := _plane.is_bot_controlled or not _plane._player_yaw_control_active
	if yaw_stabilization_active:
		var yaw_error := _get_signed_direction_error_about_axis(
			_plane._frame_forward_axis,
			_plane._frame_airflow_direction,
			_plane._frame_up_axis
		)
		stabilization_torque += _get_stabilization_torque_for_axis(
			yaw_error,
			_plane.get_local_yaw_rate(),
			_plane._frame_up_axis,
			1.0,
			_plane.alignment_angle_to_rate_gain,
			_plane.alignment_max_desired_axis_rate,
			_plane.alignment_rate_response_gain,
			_plane.alignment_deadband_deg,
			_plane.alignment_rate_deadband
		)

	if not _plane.is_bot_controlled and not _plane._player_pitch_control_active:
		stabilization_torque += _get_rate_damping_torque_for_axis(
			_plane.get_local_pitch_rate(),
			_plane._frame_right_axis,
			1.0,
			_plane.alignment_rate_response_gain,
			_plane.alignment_rate_deadband
		)

	if not _plane.is_bot_controlled and not _plane._player_direct_roll_control_active and not _plane.relative_roll_target_active:
		stabilization_torque += _get_rate_damping_torque_for_axis(
			_plane.get_local_roll_rate(),
			_plane._frame_forward_axis,
			-1.0,
			_plane.relative_roll_rate_response_gain,
			_plane.relative_roll_rate_deadband
		)

	if stabilization_torque.length_squared() <= 0.0 or not stabilization_torque.is_finite():
		return
	_plane.apply_torque(stabilization_torque)
	_plane._push_debug_torque(_plane.global_position, stabilization_torque, _plane.DEBUG_COLOR_ALIGNMENT_TORQUE)


func apply_extra_drag_forces() -> void:
	var extra_linear_drag_force := _get_extra_linear_drag_force_world()
	if extra_linear_drag_force.length_squared() > 0.0 and extra_linear_drag_force.is_finite():
		_plane.apply_central_force(extra_linear_drag_force)

	var angular_drag_torque := _get_extra_angular_drag_torque_world()
	if angular_drag_torque.length_squared() > 0.0 and angular_drag_torque.is_finite():
		_plane.apply_torque(angular_drag_torque)
		_plane._push_debug_torque(_plane.global_position, angular_drag_torque, _plane.DEBUG_COLOR_DAMPING)

	var damping_force := _get_engine_damping_force_world() + extra_linear_drag_force
	_plane.set_debug_damping_force_world(damping_force)
	if damping_force.length_squared() > 0.0 and damping_force.is_finite():
		_plane._push_debug_force(_plane.global_position, damping_force, _plane.DEBUG_COLOR_DAMPING)


func get_roll_input_for_error(
	roll_error: float,
	angle_to_rate_gain: float,
	max_desired_rate: float,
	rate_response_gain: float,
	rate_scale: float = 1.0
) -> float:
	return get_rate_stabilized_axis_input(
		roll_error,
		angle_to_rate_gain,
		max_desired_rate,
		_plane.get_local_roll_rate(),
		rate_response_gain,
		-1.0,
		1.0,
		rate_scale
	)


func get_roll_error_for_target_up(target_up_world: Vector3) -> float:
	return _get_roll_error_for_target_up(target_up_world)


func get_rate_stabilized_axis_input(
	angle_error: float,
	angle_to_rate_gain: float,
	max_desired_rate: float,
	local_rate: float,
	rate_response_gain: float,
	error_to_rate_sign: float,
	input_sign: float,
	rate_scale: float = 1.0
) -> float:
	var desired_rate := clampf(
		angle_error * angle_to_rate_gain * clampf(rate_scale, 0.0, 1.0) * error_to_rate_sign,
		-max_desired_rate,
		max_desired_rate
	)
	return get_rate_stabilized_input_for_desired_rate(
		desired_rate,
		local_rate,
		rate_response_gain,
		input_sign
	)


func get_rate_stabilized_input_for_desired_rate(
	desired_rate: float,
	local_rate: float,
	rate_response_gain: float,
	input_sign: float
) -> float:
	var rate_error := desired_rate - local_rate
	return clampf(rate_error * rate_response_gain * input_sign, -1.0, 1.0)


func get_best_climb_speed_vy() -> float:
	return _plane.get_cached_best_climb_speed_vy()


func is_best_climb_speed_vy_valid() -> bool:
	return _plane.is_cached_best_climb_speed_vy_valid()


func is_sustain_turn_using_vy() -> bool:
	return _plane.is_using_sustain_turn_vy()


func update_best_climb_speed_vy(delta: float) -> void:
	_update_best_climb_speed_vy(delta)


func get_effective_pitch_input() -> float:
	return _get_effective_pitch_input()


func get_turn_limited_pitch_input(raw_pitch_input: float) -> float:
	return _get_turn_limited_pitch_input(raw_pitch_input)


func _get_signed_direction_error_about_axis(
	reference_direction: Vector3,
	target_direction: Vector3,
	axis: Vector3
) -> float:
	var projected_reference := reference_direction - axis * reference_direction.dot(axis)
	var projected_target := target_direction - axis * target_direction.dot(axis)
	if projected_reference.length_squared() <= _plane.MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		return NAN
	if projected_target.length_squared() <= _plane.MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		return NAN

	projected_reference = projected_reference.normalized()
	projected_target = projected_target.normalized()
	var cross_axis := projected_reference.cross(projected_target)
	return projected_reference.angle_to(projected_target) * signf(cross_axis.dot(axis))


func _get_roll_error_for_target_up(target_up_world: Vector3) -> float:
	var projected_target_up := target_up_world
	projected_target_up -= _plane._frame_forward_axis * projected_target_up.dot(_plane._frame_forward_axis)
	if projected_target_up.length_squared() <= _plane.MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		return NAN

	projected_target_up = projected_target_up.normalized()
	return atan2(
		projected_target_up.dot(_plane._frame_right_axis),
		projected_target_up.dot(_plane._frame_up_axis)
	)


func _get_stabilization_torque_for_axis(
	angle_error: float,
	local_rate: float,
	axis_world: Vector3,
	torque_sign: float,
	angle_to_rate_gain: float,
	max_desired_rate: float,
	rate_response_gain: float,
	angle_deadband_deg: float,
	rate_deadband: float
) -> Vector3:
	if not is_finite(angle_error):
		return Vector3.ZERO

	var angle_deadband := deg_to_rad(maxf(angle_deadband_deg, 0.0))
	var stabilized_rate_deadband := maxf(rate_deadband, 0.0)
	if absf(angle_error) <= angle_deadband and absf(local_rate) <= stabilized_rate_deadband:
		return Vector3.ZERO

	var desired_rate := clampf(
		angle_error * maxf(angle_to_rate_gain, 0.0),
		-maxf(max_desired_rate, 0.0),
		maxf(max_desired_rate, 0.0)
	)
	var rate_error := desired_rate - local_rate
	if absf(rate_error) <= 0.000001:
		return Vector3.ZERO

	var torque := (
		axis_world *
		rate_error *
		torque_sign *
		maxf(rate_response_gain, 0.0) *
		maxf(_plane.alignment_strength, 0.0) *
		_plane._frame_air_speed
	)
	if _plane.alignment_max_torque > 0.0:
		torque = torque.limit_length(_plane.alignment_max_torque)
	if torque.length_squared() <= 0.0 or not torque.is_finite():
		return Vector3.ZERO
	return torque


func _get_rate_damping_torque_for_axis(
	local_rate: float,
	axis_world: Vector3,
	torque_sign: float,
	rate_response_gain: float,
	rate_deadband: float
) -> Vector3:
	var stabilized_rate_deadband := maxf(rate_deadband, 0.0)
	if absf(local_rate) <= stabilized_rate_deadband:
		return Vector3.ZERO

	var torque := (
		axis_world *
		(-local_rate) *
		torque_sign *
		maxf(rate_response_gain, 0.0) *
		maxf(_plane.alignment_strength, 0.0) *
		_plane._frame_air_speed
	)
	if _plane.alignment_max_torque > 0.0:
		torque = torque.limit_length(_plane.alignment_max_torque)
	if torque.length_squared() <= 0.0 or not torque.is_finite():
		return Vector3.ZERO
	return torque


func _compute_control_state(_delta: float) -> void:
	_compute_aoa()


func _compute_aoa() -> void:
	if _plane._frame_air_speed_squared < _plane.MIN_AERODYNAMIC_SPEED_SQUARED:
		_plane.aoa_deg = 0.0
		_plane.sideslip_deg = 0.0
		return

	var air_velocity_local := _plane._frame_air_velocity_local
	var flow_forward := -air_velocity_local.z
	var flow_up := air_velocity_local.y
	var flow_right := air_velocity_local.x
	var forward_plane_speed := maxf(sqrt(flow_forward * flow_forward + flow_up * flow_up), 0.0001)

	_plane.aoa_deg = rad_to_deg(-atan2(flow_up, flow_forward))
	_plane.sideslip_deg = rad_to_deg(atan2(flow_right, forward_plane_speed))


func _get_gravity_force_world() -> Vector3:
	var gravity_direction: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector")
	var gravity_magnitude: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	return gravity_direction * gravity_magnitude * _plane.gravity_scale * _plane.mass


func _get_thrust_force_world() -> Vector3:
	var throttle := clampf((_plane.throttle_input + 1.0) * 0.5, 0.0, 1.0)
	if throttle <= 0.0:
		return Vector3.ZERO

	var forward_speed := absf(_plane._frame_air_velocity_world.dot(_plane._frame_forward_axis))
	var thrust_scale := maxf(_sample_aero_table(_plane.thrust_coefficient_table, forward_speed), 0.0)
	return _plane._frame_forward_axis * throttle * _plane.max_thrust * thrust_scale


func _get_engine_damping_force_world() -> Vector3:
	if _plane._last_total_linear_damp <= 0.0:
		return Vector3.ZERO
	return -_plane.linear_velocity * _plane.mass * _plane._last_total_linear_damp


func _get_extra_linear_drag_force_world() -> Vector3:
	if _plane._frame_air_speed_squared < _plane.MIN_AERODYNAMIC_SPEED_SQUARED:
		return Vector3.ZERO
	if _plane._frame_air_speed <= 0.0:
		return Vector3.ZERO

	var direction := _plane._frame_airflow_direction
	var linear_component := maxf(_plane.extra_linear_drag_linear_coefficient, 0.0) * _plane._frame_air_speed
	var quadratic_component := maxf(_plane.extra_linear_drag_quadratic_coefficient, 0.0) * _plane._frame_air_speed_squared
	return -direction * (linear_component + quadratic_component)


func _get_extra_angular_drag_torque_world() -> Vector3:
	if _plane.angular_velocity.length_squared() < _plane.MIN_ANGULAR_SPEED_SQUARED:
		return Vector3.ZERO

	var body_basis := _plane._frame_body_basis
	var local_angular_velocity := body_basis.transposed() * _plane.angular_velocity
	var local_drag_torque := Vector3(
		_compute_axis_drag_torque_component(local_angular_velocity.x, _plane.extra_angular_drag_linear_coefficients.x, _plane.extra_angular_drag_quadratic_coefficients.x),
		_compute_axis_drag_torque_component(local_angular_velocity.y, _plane.extra_angular_drag_linear_coefficients.y, _plane.extra_angular_drag_quadratic_coefficients.y),
		_compute_axis_drag_torque_component(local_angular_velocity.z, _plane.extra_angular_drag_linear_coefficients.z, _plane.extra_angular_drag_quadratic_coefficients.z)
	)

	return body_basis * local_drag_torque


func _compute_axis_drag_torque_component(axis_rate: float, linear_coefficient: float, quadratic_coefficient: float) -> float:
	var rate_magnitude := absf(axis_rate)
	if rate_magnitude <= 0.000001:
		return 0.0

	var torque_magnitude := (
		maxf(linear_coefficient, 0.0) * rate_magnitude +
		maxf(quadratic_coefficient, 0.0) * rate_magnitude * rate_magnitude
	)
	return -sign(axis_rate) * torque_magnitude


func _sample_aero_table(points: Array[Vector2], x_value: float) -> float:
	if points.is_empty():
		return 0.0
	if points.size() == 1:
		return points[0].y
	if x_value <= points[0].x:
		return points[0].y

	var last_index := points.size() - 1
	if x_value >= points[last_index].x:
		return points[last_index].y

	for index in range(last_index):
		var left := points[index]
		var right := points[index + 1]
		if x_value > right.x:
			continue
		var span := right.x - left.x
		if absf(span) <= _plane.TABLE_SORT_EPSILON:
			return right.y
		var t := (x_value - left.x) / span
		return lerpf(left.y, right.y, t)

	return points[last_index].y


func _find_aero_table_segment_index(points: Array[Vector2], x_value: float) -> int:
	if points.size() < 2:
		return 0
	var last_segment_index := points.size() - 2
	if x_value <= points[0].x:
		return 0
	if x_value >= points[points.size() - 1].x:
		return last_segment_index
	for index in range(last_segment_index + 1):
		if x_value <= points[index + 1].x:
			return index
	return last_segment_index


func _advance_aero_table_segment_index(points: Array[Vector2], x_value: float, current_segment_index: int) -> int:
	if points.size() < 2:
		return 0
	var last_segment_index := points.size() - 2
	var segment_index := clampi(current_segment_index, 0, last_segment_index)
	while segment_index < last_segment_index and x_value > points[segment_index + 1].x:
		segment_index += 1
	while segment_index > 0 and x_value < points[segment_index].x:
		segment_index -= 1
	return segment_index


func _sample_aero_table_segment(points: Array[Vector2], x_value: float, segment_index: int) -> float:
	if points.is_empty():
		return 0.0
	if points.size() == 1:
		return points[0].y
	if x_value <= points[0].x:
		return points[0].y

	var last_index := points.size() - 1
	if x_value >= points[last_index].x:
		return points[last_index].y

	var left_index := clampi(segment_index, 0, last_index - 1)
	var left := points[left_index]
	var right := points[left_index + 1]
	var span := right.x - left.x
	if absf(span) <= _plane.TABLE_SORT_EPSILON:
		return right.y
	var t := (x_value - left.x) / span
	return lerpf(left.y, right.y, t)


func _get_turn_limited_pitch_input(raw_pitch_input: float) -> float:
	var limited_pitch_input := _get_max_lift_limited_pitch_input(raw_pitch_input)
	return _get_sustain_turn_limited_pitch_input(limited_pitch_input)


func _get_effective_pitch_input() -> float:
	if _plane._is_net_input_driven():
		return _plane._net_effective_pitch_input
	return _get_turn_limited_pitch_input(_plane.pitch_input)


func _get_max_lift_limited_pitch_input(raw_pitch_input: float) -> float:
	var limited_pitch_input := clampf(raw_pitch_input, -1.0, 1.0)
	if not _plane._pitch_assist_enabled:
		return limited_pitch_input
	if not _plane.max_lift_turn_limiter_enabled:
		return limited_pitch_input
	if _plane._frame_air_speed < maxf(_plane.max_lift_turn_limiter_min_airspeed, 0.0):
		return limited_pitch_input
	if _plane._positive_max_lift_aoa_deg <= _plane._negative_max_lift_aoa_deg:
		return limited_pitch_input

	var fade_degrees := maxf(_plane.max_lift_turn_limiter_fade_deg, 0.0)
	if limited_pitch_input < 0.0 or _plane.aoa_deg > _plane._positive_max_lift_aoa_deg:
		return _limit_pitch_input_below_upper_aoa_limit(
			limited_pitch_input,
			_plane._positive_max_lift_aoa_deg,
			fade_degrees
		)
	if limited_pitch_input > 0.0 or _plane.aoa_deg < _plane._negative_max_lift_aoa_deg:
		return _limit_pitch_input_above_lower_aoa_limit(
			limited_pitch_input,
			_plane._negative_max_lift_aoa_deg,
			fade_degrees
		)
	return limited_pitch_input


func _get_sustain_turn_limited_pitch_input(raw_pitch_input: float) -> float:
	var limited_pitch_input := clampf(raw_pitch_input, -1.0, 1.0)
	if not _should_apply_sustain_turn_limiter():
		return limited_pitch_input

	var fade_degrees := maxf(_plane.sustain_turn_limiter_fade_deg, 0.0)
	if limited_pitch_input < 0.0 or _plane.aoa_deg > 0.0:
		var positive_limit := _get_sustainable_aoa_limit(true)
		return _limit_pitch_input_below_upper_aoa_limit(limited_pitch_input, positive_limit, fade_degrees)
	if limited_pitch_input > 0.0 or _plane.aoa_deg < 0.0:
		var negative_limit := _get_sustainable_aoa_limit(false)
		return _limit_pitch_input_above_lower_aoa_limit(limited_pitch_input, negative_limit, fade_degrees)
	return limited_pitch_input


func _should_apply_sustain_turn_limiter() -> bool:
	if not _plane._pitch_assist_enabled:
		return false
	if not _plane.sustain_turn_limiter_enabled:
		return false
	if not _plane._sustain_turn_limiter_runtime_enabled:
		return false
	if _is_limiter_override_active():
		return false
	if _plane._frame_air_speed < maxf(_plane.max_lift_turn_limiter_min_airspeed, 0.0):
		return false
	if _plane._frame_air_speed_squared < _plane.MIN_AERODYNAMIC_SPEED_SQUARED:
		return false
	if _plane._positive_max_lift_aoa_deg <= _plane._negative_max_lift_aoa_deg:
		return false
	return true


func _is_limiter_override_active() -> bool:
	if _plane._is_net_input_driven():
		return _plane._net_limiter_override_active
	return _plane.is_local_player and Input.is_action_pressed("limiter_override")


func _get_sustainable_aoa_limit(positive_limit: bool) -> float:
	var bound := _plane._positive_max_lift_aoa_deg if positive_limit else _plane._negative_max_lift_aoa_deg
	if positive_limit and _should_use_vy_speed_margin_limit():
		_plane.set_sustain_turn_using_vy(true)
		return _get_vy_speed_margin_aoa_limit(bound)
	_plane.set_sustain_turn_using_vy(false)

	var sample_count := maxi(_plane.sustain_turn_limiter_samples, 1)
	var available_force := _get_sustain_available_forward_force()
	if available_force <= 0.0:
		return 0.0

	var target_speed := _get_sustain_turn_target_speed()
	var target_speed_squared := target_speed * target_speed
	var dynamic_pressure := 0.5 * _plane.air_density * target_speed_squared
	var aero_drag_scale := dynamic_pressure * _plane.reference_area
	var extra_linear_drag := maxf(_plane.extra_linear_drag_linear_coefficient, 0.0) * target_speed
	var extra_quadratic_drag := maxf(_plane.extra_linear_drag_quadratic_coefficient, 0.0) * target_speed_squared
	var engine_damping_drag := maxf(_plane._last_total_linear_damp, 0.0) * _plane.mass * target_speed
	var non_aoa_drag := extra_linear_drag + extra_quadratic_drag + engine_damping_drag
	var drag_margin := maxf(_plane.sustain_turn_limiter_drag_margin, 0.0)
	var drag_segment_index := _find_aero_table_segment_index(_plane.drag_coefficient_table, 0.0)
	var allowed_aoa := 0.0

	for index in range(sample_count + 1):
		var weight := float(index) / float(sample_count)
		var candidate_aoa := lerpf(0.0, bound, weight)
		drag_segment_index = _advance_aero_table_segment_index(_plane.drag_coefficient_table, candidate_aoa, drag_segment_index)
		var drag_coefficient := maxf(_sample_aero_table_segment(_plane.drag_coefficient_table, candidate_aoa, drag_segment_index), 0.0)
		var required_force := (aero_drag_scale * drag_coefficient + non_aoa_drag) * drag_margin
		if required_force <= available_force:
			allowed_aoa = candidate_aoa

	return allowed_aoa


func _get_sustain_available_forward_force() -> float:
	var thrust_force := _get_thrust_force_world()
	var gravity_force := _get_gravity_force_world()
	return thrust_force.dot(_plane._frame_airflow_direction) + gravity_force.dot(_plane._frame_airflow_direction)


func _should_use_vy_speed_margin_limit() -> bool:
	if not _plane.sustain_turn_vy_enabled:
		return false
	if not _plane.is_cached_best_climb_speed_vy_valid():
		return false
	return _plane._altitude_rising or _has_sustain_turn_climb_intent()


func _get_vy_speed_margin_aoa_limit(bound: float) -> float:
	var vy_speed := maxf(_plane.get_cached_best_climb_speed_vy(), 0.1)
	var margin_speed := maxf(_plane.sustain_turn_vy_margin_speed, 0.0)
	var speed_above_vy := _plane._frame_air_speed - vy_speed
	if margin_speed <= 0.0001:
		if speed_above_vy > 0.0:
			return bound
		return 0.0
	var speed_margin_authority := clampf(speed_above_vy / margin_speed, 0.0, 1.0)
	return lerpf(0.0, bound, speed_margin_authority)


func _update_best_climb_speed_vy(delta: float) -> void:
	var update_timer := _plane.get_sustain_turn_vy_update_timer() - delta
	_plane.set_sustain_turn_vy_update_timer(update_timer)
	if update_timer > 0.0:
		return
	_plane.set_sustain_turn_vy_update_timer(maxf(_plane.sustain_turn_vy_update_interval, 0.01))
	var best_climb_speed_vy := _calculate_best_climb_speed_vy()
	_plane.set_cached_best_climb_speed_vy(best_climb_speed_vy, best_climb_speed_vy > 0.0)


func _calculate_best_climb_speed_vy() -> float:
	if not _plane.sustain_turn_vy_enabled:
		return 0.0
	var sample_count := maxi(_plane.sustain_turn_vy_sample_count, 1)
	var min_speed := maxf(_plane.sustain_turn_vy_sample_min_speed, 0.1)
	var max_speed := maxf(_plane.sustain_turn_vy_sample_max_speed, min_speed)
	var load_factor := _get_current_bank_load_factor()
	if not is_finite(load_factor):
		return 0.0
	load_factor = minf(load_factor, maxf(_plane.sustain_turn_vy_max_load_factor, 1.0))

	var best_speed := 0.0
	var best_excess_power := -INF
	var required_lift := _get_weight_force_magnitude() * load_factor

	for sample_index in range(sample_count + 1):
		var sample_ratio := float(sample_index) / float(sample_count)
		var speed := lerpf(min_speed, max_speed, sample_ratio)
		var required_drag := _get_drag_required_for_lift_at_speed(required_lift, speed)
		if required_drag < 0.0:
			continue
		var available_thrust := _get_available_thrust_at_speed(speed)
		var excess_power := (available_thrust - required_drag) * speed
		if excess_power > best_excess_power:
			best_excess_power = excess_power
			best_speed = speed

	if best_excess_power <= 0.0:
		return 0.0
	return best_speed


func _get_weight_force_magnitude() -> float:
	var default_gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	var gravity_magnitude := default_gravity * _plane.gravity_scale
	return _plane.mass * gravity_magnitude


func _get_current_bank_load_factor() -> float:
	var local_world_up := _plane._frame_body_basis.transposed() * Vector3.UP
	var bank_angle := atan2(local_world_up.x, local_world_up.y)
	var bank_cosine := cos(bank_angle)
	if bank_cosine <= 0.05:
		return INF
	return 1.0 / bank_cosine


func _get_available_thrust_at_speed(speed: float) -> float:
	var thrust_coefficient := maxf(_sample_aero_table(_plane.thrust_coefficient_table, speed), 0.0)
	return _plane.max_thrust * thrust_coefficient


func _get_drag_required_for_lift_at_speed(required_lift: float, speed: float) -> float:
	var speed_squared := speed * speed
	if speed_squared <= 0.001:
		return -1.0
	var dynamic_pressure := 0.5 * _plane.air_density * speed_squared
	var lift_scale := dynamic_pressure * _plane.reference_area
	if lift_scale <= 0.001:
		return -1.0

	var required_lift_coefficient := required_lift / lift_scale
	if not _can_reach_lift_coefficient(required_lift_coefficient):
		return -1.0

	var required_aoa := _find_aoa_for_lift_coefficient(required_lift_coefficient)
	if not is_finite(required_aoa):
		return -1.0

	var drag_coefficient := maxf(_sample_aero_table(_plane.drag_coefficient_table, required_aoa), 0.0)
	var aerodynamic_drag := dynamic_pressure * _plane.reference_area * drag_coefficient
	var extra_drag := (
		maxf(_plane.extra_linear_drag_linear_coefficient, 0.0) * speed +
		maxf(_plane.extra_linear_drag_quadratic_coefficient, 0.0) * speed_squared +
		maxf(_plane._last_total_linear_damp, 0.0) * _plane.mass * speed
	)
	return aerodynamic_drag + extra_drag


func _can_reach_lift_coefficient(target_lift_coefficient: float) -> bool:
	if _plane.lift_coefficient_table.is_empty():
		return false
	var min_lift_coefficient := INF
	var max_lift_coefficient := -INF
	for point in _plane.lift_coefficient_table:
		min_lift_coefficient = minf(min_lift_coefficient, point.y)
		max_lift_coefficient = maxf(max_lift_coefficient, point.y)
	return (
		target_lift_coefficient >= min_lift_coefficient and
		target_lift_coefficient <= max_lift_coefficient
	)


func _find_aoa_for_lift_coefficient(target_lift_coefficient: float) -> float:
	if _plane.lift_coefficient_table.is_empty():
		return INF
	var best_aoa := INF
	var best_abs_aoa := INF
	for index in range(_plane.lift_coefficient_table.size() - 1):
		var left := _plane.lift_coefficient_table[index]
		var right := _plane.lift_coefficient_table[index + 1]
		var min_lift := minf(left.y, right.y)
		var max_lift := maxf(left.y, right.y)
		if target_lift_coefficient < min_lift or target_lift_coefficient > max_lift:
			continue
		var lift_span := right.y - left.y
		var candidate_aoa := left.x
		if absf(lift_span) > _plane.TABLE_SORT_EPSILON:
			var t := clampf((target_lift_coefficient - left.y) / lift_span, 0.0, 1.0)
			candidate_aoa = lerpf(left.x, right.x, t)
		var candidate_abs_aoa := absf(candidate_aoa)
		if candidate_abs_aoa < best_abs_aoa:
			best_abs_aoa = candidate_abs_aoa
			best_aoa = candidate_aoa
	return best_aoa


func _get_vertical_pull_intent() -> float:
	var pull_strength := -_plane.pitch_input
	return pull_strength * _plane._frame_up_axis.y


func _has_sustain_turn_climb_intent() -> bool:
	return _get_vertical_pull_intent() > _plane.sustain_turn_vy_min_vertical_pull_intent


func _get_sustain_turn_target_speed() -> float:
	return maxf(_plane._frame_air_speed, _plane.sustain_turn_limiter_min_target_airspeed)


func _limit_pitch_input_below_upper_aoa_limit(raw_pitch_input: float, upper_limit_deg: float, fade_degrees: float) -> float:
	var limited_pitch_input := clampf(raw_pitch_input, -1.0, 1.0)
	if limited_pitch_input >= 0.0 and _plane.aoa_deg <= upper_limit_deg:
		return limited_pitch_input
	limited_pitch_input *= _get_pitch_authority_below_upper_aoa_limit(upper_limit_deg, fade_degrees)
	if _plane.aoa_deg <= upper_limit_deg:
		return limited_pitch_input
	var recovery_span := maxf(fade_degrees, 1.0)
	var recovery_input := clampf((_plane.aoa_deg - upper_limit_deg) / recovery_span, 0.0, 1.0)
	return maxf(limited_pitch_input, recovery_input)


func _limit_pitch_input_above_lower_aoa_limit(raw_pitch_input: float, lower_limit_deg: float, fade_degrees: float) -> float:
	var limited_pitch_input := clampf(raw_pitch_input, -1.0, 1.0)
	if limited_pitch_input <= 0.0 and _plane.aoa_deg >= lower_limit_deg:
		return limited_pitch_input
	limited_pitch_input *= _get_pitch_authority_above_lower_aoa_limit(lower_limit_deg, fade_degrees)
	if _plane.aoa_deg >= lower_limit_deg:
		return limited_pitch_input
	var recovery_span := maxf(fade_degrees, 1.0)
	var recovery_input := -clampf((lower_limit_deg - _plane.aoa_deg) / recovery_span, 0.0, 1.0)
	return minf(limited_pitch_input, recovery_input)


func _get_pitch_authority_below_upper_aoa_limit(upper_limit_deg: float, fade_degrees: float) -> float:
	if fade_degrees <= 0.0001:
		if _plane.aoa_deg >= upper_limit_deg:
			return 0.0
		return 1.0
	return clampf((upper_limit_deg - _plane.aoa_deg) / fade_degrees, 0.0, 1.0)


func _get_pitch_authority_above_lower_aoa_limit(lower_limit_deg: float, fade_degrees: float) -> float:
	if fade_degrees <= 0.0001:
		if _plane.aoa_deg <= lower_limit_deg:
			return 0.0
		return 1.0
	return clampf((_plane.aoa_deg - lower_limit_deg) / fade_degrees, 0.0, 1.0)
