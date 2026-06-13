class_name PlaneInputCollector
extends RefCounted

var _plane


func _init(plane) -> void:
	_plane = plane


func collect_inputs(delta: float) -> void:
	_handle_assist_toggle_inputs()

	var rotation_rate: float = _plane.rot_rate * delta
	var rotation_decay: float = _plane.rot_decay * delta

	_collect_roll_input(delta, rotation_rate, rotation_decay)

	var pitch_analog := KeybindingsSettings.get_analog_value("pitch_axis")
	var keyboard_pitch := 0.0
	keyboard_pitch += Input.get_action_strength("pitch_up")
	keyboard_pitch -= Input.get_action_strength("pitch_down")

	var yaw_analog := KeybindingsSettings.get_analog_value("yaw_axis")
	var keyboard_yaw := 0.0
	keyboard_yaw += Input.get_action_strength("yaw_left")
	keyboard_yaw -= Input.get_action_strength("yaw_right")

	var desired_pitch: float = clampf(keyboard_pitch + pitch_analog, -1.0, 1.0)
	var desired_yaw: float = clampf(keyboard_yaw + yaw_analog, -1.0, 1.0)
	var pitch_analog_active := absf(pitch_analog) > 0.001
	var yaw_analog_active := absf(yaw_analog) > 0.001
	_plane._player_pitch_control_active = absf(desired_pitch) > 0.001
	_plane._player_yaw_control_active = absf(desired_yaw) > 0.001

	if pitch_analog_active:
		_plane.pitch_input = desired_pitch
	elif _plane._player_pitch_control_active:
		_plane.pitch_input = move_toward(_plane.pitch_input, desired_pitch, rotation_rate)
	elif _plane._input_decay_enabled:
		_plane.pitch_input = move_toward(_plane.pitch_input, 0.0, rotation_decay)

	if yaw_analog_active:
		_plane.yaw_input = desired_yaw
	elif _plane._player_yaw_control_active:
		_plane.yaw_input = move_toward(_plane.yaw_input, desired_yaw, rotation_rate)
	elif _plane._input_decay_enabled:
		_plane.yaw_input = move_toward(_plane.yaw_input, 0.0, rotation_decay)

	_plane.pitch_input = clamp(_plane.pitch_input, -1.0, 1.0)
	_plane.yaw_input = clamp(_plane.yaw_input, -1.0, 1.0)

	var throttle_rate: float = _plane.thr_rate * delta
	if Input.is_action_pressed("throttle_up"):
		_plane.throttle_input += throttle_rate
	if Input.is_action_pressed("throttle_down"):
		_plane.throttle_input -= throttle_rate
	_plane.throttle_input = clamp(_plane.throttle_input, -1.0, 1.0)

	_plane.throttle_percent = ((_plane.throttle_input + 1.0) * 0.5) * 100.0


func build_local_input_payload(seq: int) -> Dictionary:
	return {
		"seq": seq,
		"roll": _plane.roll_input,
		"pitch": _plane.pitch_input,
		"yaw": _plane.yaw_input,
		"throttle": _plane.throttle_input,
		"effective_pitch": _plane._get_turn_limited_pitch_input(_plane.pitch_input),
		"pitch_control_active": _plane._player_pitch_control_active,
		"yaw_control_active": _plane._player_yaw_control_active,
		"direct_roll_control_active": _plane._player_direct_roll_control_active,
		"relative_roll_target_active": _plane.relative_roll_target_active,
		"pitch_assist_enabled": _plane._pitch_assist_enabled,
		"stabilization_assist_enabled": _plane._stabilization_assist_enabled,
		"limiter_override_active": Input.is_action_pressed("limiter_override"),
	}


func _collect_roll_input(delta: float, rotation_rate: float, rotation_decay: float) -> void:
	var roll_analog := KeybindingsSettings.get_analog_value("roll_axis")
	var direct_roll_direction := _get_direct_roll_direction(roll_analog)
	var relative_roll_direction := _get_relative_roll_direction()
	_plane._player_direct_roll_control_active = absf(direct_roll_direction) > 0.001

	if _plane._player_direct_roll_control_active:
		_reset_relative_roll_target()
		_plane.relative_roll_input = move_toward(_plane.relative_roll_input, 0.0, rotation_decay)
		if absf(roll_analog) > 0.001:
			_plane.roll_input = direct_roll_direction
		else:
			_plane.roll_input = move_toward(_plane.roll_input, direct_roll_direction, rotation_rate)
		_plane.roll_input = clampf(_plane.roll_input, -1.0, 1.0)
		return

	_update_relative_roll_target(delta, relative_roll_direction)

	if _plane.relative_roll_target_active:
		var target_roll_input: float = _plane.get_roll_input_for_error(
			_plane.relative_roll_error,
			_plane.relative_roll_error_to_rate_gain,
			_plane.relative_roll_max_desired_rate,
			_plane.relative_roll_rate_response_gain
		)

		_plane.relative_roll_input = move_toward(_plane.relative_roll_input, target_roll_input, rotation_rate)
		_plane.roll_input = clampf(_plane.relative_roll_input, -1.0, 1.0)

		if _is_relative_roll_settled() and absf(relative_roll_direction) <= 0.001:
			_reset_relative_roll_target()

		return

	if _plane._input_decay_enabled:
		_plane.relative_roll_input = move_toward(_plane.relative_roll_input, 0.0, rotation_decay)
		_plane.roll_input = move_toward(_plane.roll_input, 0.0, rotation_decay)
	_plane.roll_input = clampf(_plane.roll_input, -1.0, 1.0)


func _get_direct_roll_direction(roll_analog: float = 0.0) -> float:
	var direction := 0.0

	direction += Input.get_action_strength("roll_left")
	direction -= Input.get_action_strength("roll_right")
	direction += roll_analog

	return clampf(direction, -1.0, 1.0)


func _get_relative_roll_direction() -> float:
	var direction := 0.0

	direction -= Input.get_action_strength("relative_roll_left")
	direction += Input.get_action_strength("relative_roll_right")

	return clampf(direction, -1.0, 1.0)


func _update_relative_roll_target(delta: float, input_direction: float) -> void:
	if not _plane.relative_roll_target_active:
		_plane.relative_roll_target_up_world = _plane.get_frame_up_axis()
		_plane.relative_roll_error = 0.0

	if absf(input_direction) > 0.001:
		_plane.relative_roll_target_active = true
		var cursor_angle_step: float = input_direction * _plane.relative_roll_cursor_speed * delta
		_plane.relative_roll_target_up_world = _plane.relative_roll_target_up_world.rotated(
			_plane.get_frame_forward_axis(),
			cursor_angle_step
		).normalized()

	if not _plane.relative_roll_target_active:
		return

	_update_relative_roll_error()


func _update_relative_roll_error() -> void:
	var roll_error: float = _plane.get_roll_error_for_target_up(_plane.relative_roll_target_up_world)
	if not is_finite(roll_error):
		_reset_relative_roll_target()
		return

	var max_error := deg_to_rad(maxf(_plane.relative_roll_max_error_deg, 1.0))
	_plane.relative_roll_error = clampf(roll_error, -max_error, max_error)

	_plane.relative_roll_target_up_world = _plane.get_frame_up_axis().rotated(
		_plane.get_frame_forward_axis(),
		_plane.relative_roll_error
	).normalized()


func _reset_relative_roll_target() -> void:
	_plane.relative_roll_target_active = false
	_plane.relative_roll_target_up_world = _plane.get_frame_up_axis()
	_plane.relative_roll_error = 0.0
	_plane.relative_roll_input = 0.0


func _is_relative_roll_settled() -> bool:
	var error_deadband := deg_to_rad(maxf(_plane.relative_roll_deadband_deg, 0.0))
	return (
		absf(_plane.relative_roll_error) <= error_deadband and
		absf(_plane.get_local_roll_rate()) <= maxf(_plane.relative_roll_rate_deadband, 0.0)
	)


func _handle_assist_toggle_inputs() -> void:
	if not _plane.is_local_player:
		return
	var ds := DisplaySettings
	if Input.is_action_just_pressed("toggle_pitch_assist"):
		_plane._pitch_assist_enabled = not _plane._pitch_assist_enabled
		if ds != null:
			ds.set_pitch_assist_enabled(_plane._pitch_assist_enabled)
	if Input.is_action_just_pressed("toggle_stabilization_assist"):
		_plane._stabilization_assist_enabled = not _plane._stabilization_assist_enabled
		if ds != null:
			ds.set_stabilization_assist_enabled(_plane._stabilization_assist_enabled)
	if Input.is_action_just_pressed("toggle_input_decay"):
		_plane._input_decay_enabled = not _plane._input_decay_enabled
		if ds != null:
			ds.set_input_decay_enabled(_plane._input_decay_enabled)
