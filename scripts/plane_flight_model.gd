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


func get_turn_performance(gamma_deg := 0.0) -> Dictionary:
	return _get_turn_performance(gamma_deg)


func build_sustained_turn_aoa_surface(
	gamma_min_deg := -30.0,
	gamma_max_deg := 30.0,
	gamma_sample_count := 61,
	speed_min := -1.0,
	speed_max := -1.0
) -> Dictionary:
	return _build_sustained_turn_surface(
		gamma_min_deg, gamma_max_deg, gamma_sample_count, "aoa_deg", speed_min, speed_max
	)


func build_sustained_turn_rate_surface(
	gamma_min_deg := -30.0,
	gamma_max_deg := 30.0,
	gamma_sample_count := 61,
	speed_min := -1.0,
	speed_max := -1.0
) -> Dictionary:
	return _build_sustained_turn_surface(
		gamma_min_deg, gamma_max_deg, gamma_sample_count, "rate_deg_s", speed_min, speed_max
	)


## Look up the nearest sampled value in a surface produced by the sustained-turn
## surface builders (an aoa_deg or rate_deg_s grid over speed × gamma). Returns
## the value stored at the grid cell closest to the queried (speed, gamma_deg).
func find_nearest_surface_value(surface: Dictionary, speed: float, gamma_deg: float) -> float:
	var cell := find_nearest_surface_cell(surface, speed, gamma_deg)
	return float(cell.get("value", 0.0))


## As find_nearest_surface_value, but returns the full cell: the resolved grid
## speed_index/gamma_index, their sampled speed/gamma_deg, and the stored value.
func find_nearest_surface_cell(surface: Dictionary, speed: float, gamma_deg: float) -> Dictionary:
	var speed_values: PackedFloat32Array = surface.get("speed_values", PackedFloat32Array())
	var gamma_values: PackedFloat32Array = surface.get("gamma_values", PackedFloat32Array())
	var value_values: PackedFloat32Array = surface.get("value_values", PackedFloat32Array())
	var speed_count := int(surface.get("speed_count", speed_values.size()))
	if speed_values.is_empty() or gamma_values.is_empty() or value_values.is_empty() or speed_count <= 0:
		return {}

	var speed_index := _nearest_sorted_index(speed_values, speed)
	var gamma_index := _nearest_sorted_index(gamma_values, gamma_deg)
	if speed_index < 0 or gamma_index < 0:
		return {}

	var flat_index := gamma_index * speed_count + speed_index
	if flat_index < 0 or flat_index >= value_values.size():
		return {}

	return {
		"speed_index": speed_index,
		"gamma_index": gamma_index,
		"speed": speed_values[speed_index],
		"gamma_deg": gamma_values[gamma_index],
		"value": value_values[flat_index],
	}


# Nearest index into an ascending-sorted array; -1 when empty.
func _nearest_sorted_index(values: PackedFloat32Array, target: float) -> int:
	var count := values.size()
	if count == 0:
		return -1
	if count == 1:
		return 0
	var hi := values.bsearch(target)
	if hi <= 0:
		return 0
	if hi >= count:
		return count - 1
	var lo := hi - 1
	if absf(values[hi] - target) < absf(values[lo] - target):
		return hi
	return lo


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
	var limited := _get_max_lift_limited_pitch_input(raw_pitch_input)
	return _get_sustained_turn_limited_pitch_input(limited)


# Caps AoA at the sustainable value sampled from the plane's cached AoA surface
# for the current airspeed and flight-path angle. Mirrors the max-lift limiter,
# but the upper/lower AoA bounds are the (tighter) sustainable AoA rather than
# the static stall limit.
func _get_sustained_turn_limited_pitch_input(raw_pitch_input: float) -> float:
	var limited_pitch_input := clampf(raw_pitch_input, -1.0, 1.0)
	if not _plane._pitch_assist_enabled:
		return limited_pitch_input
	if not _plane.is_sustain_turn_limiter_active():
		return limited_pitch_input
	if _plane._frame_air_speed < maxf(_plane.sustain_turn_limiter_min_airspeed, 0.0):
		return limited_pitch_input
	var max_airspeed := _plane.sustain_turn_limiter_max_airspeed
	if max_airspeed > 0.0 and _plane._frame_air_speed > max_airspeed:
		return limited_pitch_input

	var surface: Dictionary = _plane.get_sustained_aoa_surface()
	if surface.is_empty():
		return limited_pitch_input

	var gamma_deg := _get_air_flight_path_angle_deg()
	var sustained_aoa := find_nearest_surface_value(surface, _plane._frame_air_speed, gamma_deg)
	if sustained_aoa <= 0.0:
		return limited_pitch_input

	# Never exceed the static stall limit even if the table says otherwise.
	var upper_limit := minf(sustained_aoa, _plane._positive_max_lift_aoa_deg)
	var lower_limit := maxf(-sustained_aoa, _plane._negative_max_lift_aoa_deg)
	var fade_degrees := maxf(_plane.sustain_turn_limiter_fade_deg, 0.0)

	if limited_pitch_input < 0.0 or _plane.aoa_deg > upper_limit:
		return _limit_pitch_input_below_upper_aoa_limit(limited_pitch_input, upper_limit, fade_degrees)
	if limited_pitch_input > 0.0 or _plane.aoa_deg < lower_limit:
		return _limit_pitch_input_above_lower_aoa_limit(limited_pitch_input, lower_limit, fade_degrees)
	return limited_pitch_input


# Flight-path angle (climb positive) of the air-relative velocity, in degrees.
func _get_air_flight_path_angle_deg() -> float:
	var speed := _plane._frame_air_speed
	if speed <= 0.0001:
		return 0.0
	return rad_to_deg(asin(clampf(_plane._frame_air_velocity_world.y / speed, -1.0, 1.0)))


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


func _get_weight_force_magnitude() -> float:
	var default_gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	var gravity_magnitude := default_gravity * _plane.gravity_scale
	return _plane.mass * gravity_magnitude


# Highest airspeed at which available pitch torque can still sustain the body pitch
# rate required to hold CL_max AoA in a turn. Above it the control-authority curve
# compresses below what the turn demands, so the jet is control-limited, not
# lift-limited. Deterministic monotone sweep: τ_avail collapses with speed while the
# required rate (hence angular-drag torque) rises, so they cross once.
func _calculate_corner_speed() -> float:
	if not _plane.corner_speed_enabled:
		return 0.0
	if _plane.control_authority_coefficient_table.is_empty():
		return 0.0

	var cl_max := _sample_aero_table(_plane.lift_coefficient_table, _plane._positive_max_lift_aoa_deg)
	if cl_max <= 0.0:
		return 0.0
	var weight := _get_weight_force_magnitude()
	if weight <= 0.0:
		return 0.0

	var gravity := weight / maxf(_plane.mass, 0.0001)
	var pitch_linear_drag := maxf(_plane.extra_angular_drag_linear_coefficients.x, 0.0)
	var pitch_quadratic_drag := maxf(_plane.extra_angular_drag_quadratic_coefficients.x, 0.0)
	# n = q·S·CL_max / W = (½·ρ·S·CL_max)·V² / W
	var load_factor_scale := 0.5 * _plane.air_density * _plane.reference_area * cl_max

	var sample_count := maxi(_plane.corner_speed_sample_count, 1)
	var min_speed := maxf(_plane.corner_speed_sample_min_speed, 0.1)
	var max_speed := maxf(_plane.corner_speed_sample_max_speed, min_speed)

	var corner_speed := 0.0
	for sample_index in range(sample_count + 1):
		var sample_ratio := float(sample_index) / float(sample_count)
		var speed := lerpf(min_speed, max_speed, sample_ratio)
		var load_factor := (load_factor_scale * speed * speed) / weight
		# Pitch rate the nose must sustain to hold AoA as lift curves the flightpath.
		var required_pitch_rate := load_factor * gravity / speed
		var required_torque := (
			pitch_linear_drag * required_pitch_rate
			+ pitch_quadratic_drag * required_pitch_rate * required_pitch_rate
		)
		var control_coefficient := maxf(_sample_aero_table(_plane.control_authority_coefficient_table, speed), 0.0)
		var available_torque := _plane.base_control_torque * control_coefficient * _plane.max_pitch
		if available_torque >= required_torque:
			corner_speed = speed

	return corner_speed


func _get_turn_performance(gamma_deg := 0.0) -> Dictionary:
	var gamma_rad := deg_to_rad(gamma_deg)
	var cos_gamma := cos(gamma_rad)
	if absf(cos_gamma) <= 0.0001:
		return {}

	var weight := _get_weight_force_magnitude()
	if weight <= 0.0:
		return {}

	var gravity := weight / maxf(_plane.mass, 0.0001)
	var cl_max_aoa := maxf(_plane._positive_max_lift_aoa_deg, 0.0)
	var cl_max := maxf(_sample_aero_table(_plane.lift_coefficient_table, cl_max_aoa), 0.0)
	if cl_max <= 0.0:
		return {}

	var speed_range := _get_turn_performance_speed_range()
	var min_speed := speed_range.x
	var max_speed := speed_range.y
	var sample_count := maxi(maxi(_plane.corner_speed_sample_count, _plane.turn_performance_speed_sample_count), 64) * 5
	var aoa_sample_count := maxi(_plane.turn_performance_aoa_sample_count, 48)
	var aoa_step := cl_max_aoa / float(aoa_sample_count)

	var instantaneous_rate_curve: Array[Vector2] = []
	var instantaneous_radius_curve: Array[Vector2] = []
	var sustained_rate_curve: Array[Vector2] = []
	var sustained_radius_curve: Array[Vector2] = []

	var max_instantaneous_rate := -INF
	var max_instantaneous_rate_speed := 0.0
	var min_instantaneous_radius := INF
	var min_instantaneous_radius_speed := 0.0
	var max_sustained_rate := -INF
	var max_sustained_rate_speed := 0.0
	var min_sustained_radius := INF
	var min_sustained_radius_speed := 0.0

	for sample_index in range(sample_count + 1):
		var sample_ratio := float(sample_index) / float(sample_count)
		var speed := lerpf(min_speed, max_speed, sample_ratio)
		if speed <= 0.0:
			continue

		var instantaneous_load_factor := _get_instantaneous_load_factor(speed, weight, gravity, cl_max)
		var instantaneous_solution := _get_turn_solution(speed, instantaneous_load_factor, gamma_rad, cos_gamma, gravity)
		if not instantaneous_solution.is_empty():
			var rate_deg := float(instantaneous_solution["rate_deg_s"])
			var radius_m := float(instantaneous_solution["radius_m"])
			instantaneous_rate_curve.append(Vector2(speed, rate_deg))
			instantaneous_radius_curve.append(Vector2(speed, radius_m))
			if rate_deg > max_instantaneous_rate:
				max_instantaneous_rate = rate_deg
				max_instantaneous_rate_speed = speed
			if radius_m < min_instantaneous_radius:
				min_instantaneous_radius = radius_m
				min_instantaneous_radius_speed = speed
		else:
			instantaneous_rate_curve.append(Vector2(speed, 0.0))

		var sustained_state := _get_sustained_turn_state(speed, gamma_rad, weight, cl_max_aoa, aoa_step, aoa_sample_count)
		var sustained_load_factor := float(sustained_state.get("load_factor", 0.0))
		var sustained_solution := _get_turn_solution(speed, sustained_load_factor, gamma_rad, cos_gamma, gravity)
		if not sustained_solution.is_empty():
			var sustained_rate_deg := float(sustained_solution["rate_deg_s"])
			var sustained_radius_m := float(sustained_solution["radius_m"])
			sustained_rate_curve.append(Vector2(speed, sustained_rate_deg))
			sustained_radius_curve.append(Vector2(speed, sustained_radius_m))
			if sustained_rate_deg > max_sustained_rate:
				max_sustained_rate = sustained_rate_deg
				max_sustained_rate_speed = speed
			if sustained_radius_m < min_sustained_radius:
				min_sustained_radius = sustained_radius_m
				min_sustained_radius_speed = speed
		else:
			sustained_rate_curve.append(Vector2(speed, 0.0))

	var corner_speed := _calculate_corner_speed()
	return {
		"gamma_deg": gamma_deg,
		"corner_speed": corner_speed,
		"instantaneous_rate_curve": instantaneous_rate_curve,
		"instantaneous_radius_curve": instantaneous_radius_curve,
		"sustained_rate_curve": sustained_rate_curve,
		"sustained_radius_curve": sustained_radius_curve,
		"max_instantaneous_rate_deg_s": max_instantaneous_rate if is_finite(max_instantaneous_rate) else 0.0,
		"max_instantaneous_rate_speed": max_instantaneous_rate_speed,
		"min_instantaneous_radius_m": min_instantaneous_radius if is_finite(min_instantaneous_radius) else 0.0,
		"min_instantaneous_radius_speed": min_instantaneous_radius_speed,
		"max_sustained_rate_deg_s": max_sustained_rate if is_finite(max_sustained_rate) else 0.0,
		"max_sustained_rate_speed": max_sustained_rate_speed,
		"min_sustained_radius_m": min_sustained_radius if is_finite(min_sustained_radius) else 0.0,
		"min_sustained_radius_speed": min_sustained_radius_speed,
	}


func _build_sustained_turn_surface(
	gamma_min_deg: float,
	gamma_max_deg: float,
	gamma_sample_count: int,
	value_key: String,
	speed_min_override := -1.0,
	speed_max_override := -1.0
) -> Dictionary:
	var clamped_gamma_count := maxi(gamma_sample_count, 1)
	var speed_range := _get_turn_performance_speed_range()
	var min_speed := speed_range.x
	var max_speed := speed_range.y
	if speed_min_override >= 0.0:
		min_speed = speed_min_override
	if speed_max_override >= 0.0:
		max_speed = maxf(speed_max_override, min_speed)
	var speed_sample_count := maxi(maxi(_plane.corner_speed_sample_count, _plane.turn_performance_speed_sample_count), 64) * 5
	var aoa_sample_count := maxi(_plane.turn_performance_aoa_sample_count, 48)

	var weight := _get_weight_force_magnitude()
	if weight <= 0.0:
		return {}

	var gravity := weight / maxf(_plane.mass, 0.0001)
	var cl_max_aoa := maxf(_plane._positive_max_lift_aoa_deg, 0.0)
	if maxf(_sample_aero_table(_plane.lift_coefficient_table, cl_max_aoa), 0.0) <= 0.0:
		return {}

	var aoa_step := cl_max_aoa / float(aoa_sample_count)
	var speed_values := PackedFloat32Array()
	var gamma_values := PackedFloat32Array()
	var value_values := PackedFloat32Array()
	var points: Array[Vector3] = []

	for speed_index in range(speed_sample_count + 1):
		var speed_ratio := float(speed_index) / float(speed_sample_count)
		speed_values.append(lerpf(min_speed, max_speed, speed_ratio))

	for gamma_index in range(clamped_gamma_count):
		var gamma_ratio := 0.0
		if clamped_gamma_count > 1:
			gamma_ratio = float(gamma_index) / float(clamped_gamma_count - 1)
		var gamma_deg := lerpf(gamma_min_deg, gamma_max_deg, gamma_ratio)
		gamma_values.append(gamma_deg)
		var gamma_rad := deg_to_rad(gamma_deg)
		var cos_gamma := cos(gamma_rad)

		for speed in speed_values:
			var value := 0.0
			if absf(cos_gamma) > 0.0001:
				var sustained_state := _get_sustained_turn_state(
					speed,
					gamma_rad,
					weight,
					cl_max_aoa,
					aoa_step,
					aoa_sample_count
				)
				if value_key == "aoa_deg":
					value = float(sustained_state.get("aoa_deg", 0.0))
				else:
					var load_factor := float(sustained_state.get("load_factor", 0.0))
					var turn_solution := _get_turn_solution(speed, load_factor, gamma_rad, cos_gamma, gravity)
					value = float(turn_solution.get("rate_deg_s", 0.0))
			value_values.append(value)
			points.append(Vector3(speed, value, gamma_deg))

	return {
		"speed_values": speed_values,
		"gamma_values": gamma_values,
		"value_values": value_values,
		"points": points,
		"value_key": value_key,
		"speed_count": speed_values.size(),
		"gamma_count": gamma_values.size(),
	}


func _get_turn_performance_speed_range() -> Vector2:
	var min_speed := maxf(maxf(_plane.corner_speed_sample_min_speed, _plane.turn_performance_sample_min_speed), 10.0)
	var max_speed := maxf(maxf(_plane.corner_speed_sample_max_speed, _plane.turn_performance_sample_max_speed), min_speed)
	for point in _plane.thrust_coefficient_table:
		min_speed = minf(min_speed, point.x)
		max_speed = maxf(max_speed, point.x)
	for point in _plane.control_authority_coefficient_table:
		min_speed = minf(min_speed, point.x)
		max_speed = maxf(max_speed, point.x)
	min_speed = maxf(min_speed, 0.1)
	max_speed = maxf(max_speed, min_speed)
	return Vector2(min_speed, max_speed)


func _get_instantaneous_load_factor(speed: float, weight: float, gravity: float, cl_max: float) -> float:
	var dynamic_pressure := 0.5 * _plane.air_density * speed * speed
	var lift_limit := (dynamic_pressure * _plane.reference_area * cl_max) / weight

	var control_coefficient := maxf(_sample_aero_table(_plane.control_authority_coefficient_table, speed), 0.0)
	var available_torque := _plane.base_control_torque * control_coefficient * _plane.max_pitch
	var pitch_linear_drag := maxf(_plane.extra_angular_drag_linear_coefficients.x, 0.0)
	var pitch_quadratic_drag := maxf(_plane.extra_angular_drag_quadratic_coefficients.x, 0.0)
	var max_pitch_rate := _solve_max_rate_from_torque(available_torque, pitch_linear_drag, pitch_quadratic_drag)
	var control_limit := max_pitch_rate * speed / gravity
	return minf(lift_limit, control_limit)


func _get_sustained_load_factor(
	speed: float,
	gamma_rad: float,
	weight: float,
	_max_aoa: float,
	aoa_step: float,
	aoa_sample_count: int
) -> float:
	return float(_get_sustained_turn_state(speed, gamma_rad, weight, _max_aoa, aoa_step, aoa_sample_count).get("load_factor", 0.0))


func _get_sustained_turn_state(
	speed: float,
	gamma_rad: float,
	weight: float,
	_max_aoa: float,
	aoa_step: float,
	aoa_sample_count: int
) -> Dictionary:
	var dynamic_pressure := 0.5 * _plane.air_density * speed * speed
	var lift_scale := dynamic_pressure * _plane.reference_area
	if lift_scale <= 0.0001:
		return {}

	var drag_budget := _get_available_thrust_at_speed(speed) - weight * sin(gamma_rad)
	if drag_budget <= 0.0:
		return {}

	var best_cl := 0.0
	var best_aoa := 0.0
	for aoa_index in range(aoa_sample_count + 1):
		var aoa := float(aoa_index) * aoa_step
		var drag_coefficient := maxf(_sample_aero_table(_plane.drag_coefficient_table, aoa), 0.0)
		var total_drag := dynamic_pressure * _plane.reference_area * drag_coefficient
		total_drag += maxf(_plane.extra_linear_drag_quadratic_coefficient, 0.0) * speed * speed
		if total_drag > drag_budget:
			continue
		var lift_coefficient := _sample_aero_table(_plane.lift_coefficient_table, aoa)
		if lift_coefficient > best_cl:
			best_cl = lift_coefficient
			best_aoa = aoa

	return {
		"load_factor": (lift_scale * best_cl) / weight,
		"aoa_deg": best_aoa,
	}


func _get_turn_solution(speed: float, load_factor: float, gamma_rad: float, cos_gamma: float, gravity: float) -> Dictionary:
	var threshold := cos(gamma_rad)
	if load_factor <= threshold:
		return {}
	var radical := load_factor * load_factor - threshold * threshold
	if radical <= 0.0:
		return {}
	var rate_rad_s := gravity * sqrt(radical) / (speed * cos_gamma)
	if rate_rad_s <= 0.0 or not is_finite(rate_rad_s):
		return {}
	return {
		"rate_deg_s": rad_to_deg(rate_rad_s),
		"radius_m": speed * cos_gamma / rate_rad_s,
	}


func _solve_max_rate_from_torque(available_torque: float, linear_drag: float, quadratic_drag: float) -> float:
	if available_torque <= 0.0:
		return 0.0
	if quadratic_drag <= 0.0:
		if linear_drag <= 0.0:
			return INF
		return available_torque / linear_drag
	var discriminant := linear_drag * linear_drag + 4.0 * quadratic_drag * available_torque
	if discriminant <= 0.0:
		return 0.0
	return (-linear_drag + sqrt(discriminant)) / (2.0 * quadratic_drag)


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
