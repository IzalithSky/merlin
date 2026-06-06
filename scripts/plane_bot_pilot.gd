extends Node

const BOT_DEBUG_RENDERER_SCRIPT := preload("res://scripts/bot_debug_renderer_3d.gd")

enum FlightState {
	IDLE,
	SPEED_RECOVERY,
	ALTITUDE_HOLD,
	LEVEL_FLIGHT,
	GROUND_AVOIDANCE,
	FOLLOW_TARGET,
}

const GROUND_AVOIDANCE_MIN_NOSE_UP_INPUT := 0.25
const GROUND_AVOIDANCE_PITCH_RESPONSE_RATE := 1.2
const SPEED_RECOVERY_PITCH_RESPONSE_RATE := 0.35
const SPEED_RECOVERY_FULL_THROTTLE_INPUT := 1.0
const SPEED_RECOVERY_TARGET_ABOVE_MAX_NADIR_BLEND := 0.15
const SPEED_RECOVERY_PITCH_ANGLE_TO_RATE_GAIN := 1.2
const SPEED_RECOVERY_PITCH_RATE_RESPONSE_GAIN := 0.75
const SPEED_RECOVERY_MAX_DESIRED_PITCH_RATE := 1.4
const SPEED_RECOVERY_YAW_ANGLE_TO_RATE_GAIN := 0.8
const SPEED_RECOVERY_YAW_RATE_RESPONSE_GAIN := 0.5
const SPEED_RECOVERY_MAX_DESIRED_YAW_RATE := 0.8
const SPEED_RECOVERY_WINGS_LEVEL_MIN_FORWARD_SPEED := 60.0
const SPEED_RECOVERY_WINGS_LEVEL_MAX_DIVE_ANGLE_DEG := 20.0
const HALF_THROTTLE_INPUT := 0.0
const LEVEL_FLIGHT_PITCH_RESPONSE_RATE := 0.6
const LEVEL_FLIGHT_VERTICAL_SPEED_GAIN := 0.012
const ALTITUDE_CAPTURE_TOLERANCE := 10.0
const ALTITUDE_HOLD_PITCH_RESPONSE_RATE := 0.45
const ALTITUDE_HOLD_MAX_VERTICAL_SPEED := 20.0
const ALTITUDE_HOLD_ALTITUDE_GAIN := 0.08
const ALTITUDE_HOLD_VERTICAL_SPEED_GAIN := 0.025
const LEVEL_TURN_ROLL_RESPONSE_RATE := 0.9
const LEVEL_TURN_YAW_RESPONSE_RATE := 0.5
const LEVEL_TURN_ROLL_GAIN := 1.4
const WINGS_LEVEL_ROLL_GAIN := 1.2
const ROLL_RATE_RESPONSE_GAIN := 0.75
const ROLL_MAX_DESIRED_RATE := 1.8
const ROLL_RATE_DEADBAND := 2.0 * PI / 180.0
const CHECKPOINT_ORBIT_RADIAL_CORRECTION := 0.7
const CHECKPOINT_ORBIT_RADIUS_DEADBAND := 0.05
const TURN_FULL_PULL_ANGLE_RAD := PI * 0.5
const TURN_PITCH_ANGLE_TO_RATE_GAIN := 0.85
const TURN_PITCH_RATE_RESPONSE_GAIN := 0.75
const TURN_MAX_DESIRED_PITCH_RATE := 1.4
const TURN_MIN_PULL_ANGLE_RAD := 0.02
const TURN_ANGLE_DEADBAND_RAD := PI / 180.0
const CORRECTION_TURN_PITCH_DOWN_RATE := 0.47
const CORRECTION_TURN_MIN_LATERAL_ANGLE_RAD := 0.08
const CORRECTION_TURN_HYSTERESIS_RAD := 2.0 * PI / 180.0
const WINGS_LEVEL_DEADBAND_RAD := PI / 180.0
const MIN_DIRECTION_LENGTH_SQUARED := 0.000001
const PLAYER_TARGET_REACQUIRE_INTERVAL := 0.5
const GROUND_PROBE_EXCLUSION_REFRESH_INTERVAL := 1.0
const GROUND_PROBE_SAFE_INTERVAL := 0.25
const GROUND_PROBE_NEAR_CLEARANCE_MULTIPLIER := 2.0
const GROUND_PROBE_FAST_CLOSURE_RATIO := 0.25
const CONTROL_INPUT_LIMIT := 1.0

@export var telemetry_sample_interval: float = 0.2
@export var telemetry_max_samples: int = 25
@export var min_acceptable_forward_speed: float = 80.0
@export var reserve_forward_speed: float = 120.0
@export var max_lift_turn_min_forward_speed: float = 120.0
@export var default_altitude: float = 5000.0
@export var min_ground_clearance: float = 300.0
@export var ground_clearance_tolerance: float = 25.0
@export var ground_avoidance_time_to_impact: float = 4.0
@export var ground_avoidance_closure_rate_for_max_pull: float = 120.0
@export var ground_avoidance_dive_angle_for_max_pull_deg: float = 35.0
@export var ground_probe_distance: float = 1000.0
@export var checkpoint_orbit_radius: float = 500.0
@export var checkpoint_orbit_direction: float = 1.0
@export var correction_turn_small_angle_deg: float = 12.0
@export var overshoot_closure_tolerance: float = 0.5
@export var overshoot_throttle_gain: float = 0.08
@export var killzone_distance: float = 250.0
@export var killzone_tolerance: float = 150.0
@export var debug_bot_visuals_enabled := true
@export var checkpoints: Array[Vector3] = [
	Vector3(0.0, 1500.0, 0.0),
]

var telemetry_samples: Array[Dictionary] = []

var _plane: RigidBody3D
var _telemetry_timer := 0.0
var _altitude_target_active := false
var _target_altitude := 0.0
var _flight_state: int = FlightState.IDLE
var _roll_input := 0.0
var _pitch_input := 0.0
var _yaw_input := 0.0
var _ground_clearance := INF
var _next_ground_probe_time := 0.0
var _checkpoint_index := 0
var _correction_turn_active := false
var _follow_target: Node3D
var _fallback_follow_target: Node3D
var _fallback_follow_target_uses_killzone := false
var _follow_target_velocity := Vector3.ZERO
var _last_follow_target_position := Vector3.ZERO
var _has_follow_target_sample := false
var _follow_target_is_player := false
var _follow_target_uses_killzone := false
var _player_target_reacquire_timer := 0.0
var _ground_probe_exclusions: Array[RID] = []
var _next_ground_probe_exclusion_refresh_time := 0.0
var _last_sustain_turn_limiter_enabled := true
var _has_applied_turn_limiter_mode := false
var _bot_debug_renderer: Node
var _frame_position := Vector3.ZERO
var _frame_velocity := Vector3.ZERO
var _frame_speed := 0.0
var _frame_basis := Basis.IDENTITY
var _frame_inverse_basis := Basis.IDENTITY
var _frame_forward_axis := Vector3.FORWARD
var _frame_forward_speed := 0.0
var _frame_local_angular_velocity := Vector3.ZERO


func _ready() -> void:
	_plane = get_parent() as RigidBody3D
	if _plane == null:
		set_physics_process(false)
		return

	_update_frame_cache()
	climb_to_altitude(default_altitude)
	_record_telemetry_sample()
	_ensure_bot_debug_renderer()
	_update_bot_debug_renderer_state()


func _physics_process(delta: float) -> void:
	_update_frame_cache()
	_update_follow_target_velocity(delta)
	_update_flight_controls(delta)
	_update_bot_debug_visuals()

	var sample_interval := maxf(telemetry_sample_interval, 0.001)
	_telemetry_timer += delta
	if _telemetry_timer < sample_interval:
		return

	_telemetry_timer = fmod(_telemetry_timer, sample_interval)
	_record_telemetry_sample()


func _update_frame_cache() -> void:
	var plane_transform := _plane.global_transform
	_frame_position = plane_transform.origin
	_frame_velocity = _plane.linear_velocity
	_frame_speed = _frame_velocity.length()
	_frame_basis = plane_transform.basis.orthonormalized()
	_frame_inverse_basis = _frame_basis.transposed()
	_frame_forward_axis = -_frame_basis.z
	_frame_forward_speed = _frame_velocity.dot(_frame_forward_axis)
	_frame_local_angular_velocity = _frame_inverse_basis * _plane.angular_velocity


func get_motion_trend(window_seconds: float = 2.0) -> Dictionary:
	if telemetry_samples.size() < 2:
		return _make_unknown_motion_trend()

	var latest: Dictionary = telemetry_samples[telemetry_samples.size() - 1]
	var reference: Dictionary = _find_reference_sample(float(latest["time"]), window_seconds)
	var elapsed := maxf(float(latest["time"]) - float(reference["time"]), 0.001)
	var speed_delta := float(latest["forward_speed"]) - float(reference["forward_speed"])
	var altitude_delta := float(latest["altitude"]) - float(reference["altitude"])

	return {
		"has_enough_data": true,
		"sample_count": telemetry_samples.size(),
		"elapsed_seconds": elapsed,
		"forward_speed": float(latest["forward_speed"]),
		"altitude": float(latest["altitude"]),
		"speed_delta": speed_delta,
		"altitude_delta": altitude_delta,
		"acceleration": speed_delta / elapsed,
		"vertical_speed": altitude_delta / elapsed,
	}


func get_flight_state() -> int:
	return _flight_state


func climb_to_altitude(target_altitude: float) -> void:
	_target_altitude = target_altitude
	_altitude_target_active = true


func _is_climbing_to_altitude() -> bool:
	if not _altitude_target_active or _plane == null:
		return false

	return absf(_target_altitude - _frame_position.y) > ALTITUDE_CAPTURE_TOLERANCE


func _get_current_checkpoint() -> Vector3:
	if not _has_checkpoint():
		return Vector3.ZERO

	return checkpoints[_get_clamped_checkpoint_index()]


func set_follow_target(target: Node3D = null, use_killzone: bool = false) -> void:
	_fallback_follow_target = target
	_fallback_follow_target_uses_killzone = use_killzone
	if not _follow_target_is_player:
		_set_active_follow_target(target, false, use_killzone)


func _set_active_follow_target(target: Node3D, target_is_player: bool, use_killzone: bool = false) -> void:
	_follow_target = target
	_follow_target_is_player = target_is_player
	_follow_target_uses_killzone = target_is_player or use_killzone
	_follow_target_velocity = Vector3.ZERO
	_has_follow_target_sample = false
	if _follow_target != null:
		_last_follow_target_position = _follow_target.global_position if _follow_target.is_inside_tree() else _follow_target.position
		_has_follow_target_sample = true


func get_follow_target() -> Node3D:
	return _follow_target


func _ensure_bot_debug_renderer() -> void:
	if not debug_bot_visuals_enabled:
		return

	if _bot_debug_renderer != null:
		return

	_bot_debug_renderer = BOT_DEBUG_RENDERER_SCRIPT.new()
	_bot_debug_renderer.name = "BotDebugRenderer3D"
	add_child(_bot_debug_renderer)
	_update_bot_debug_renderer_state()


func _update_bot_debug_renderer_state() -> void:
	if _bot_debug_renderer == null:
		return

	var should_show := debug_bot_visuals_enabled and _plane != null and _plane.is_inside_tree()
	_bot_debug_renderer.visible = should_show
	if not should_show and _bot_debug_renderer.has_method("clear"):
		_bot_debug_renderer.call("clear")


func _update_bot_debug_visuals() -> void:
	if not debug_bot_visuals_enabled:
		_update_bot_debug_renderer_state()
		return

	_ensure_bot_debug_renderer()
	_update_bot_debug_renderer_state()
	if _bot_debug_renderer == null or not _bot_debug_renderer.visible:
		return

	var has_target := _has_follow_target()
	var intent_position := Vector3.ZERO
	var source_target_position := Vector3.ZERO
	var has_killzone := false
	var killzone_position := Vector3.ZERO

	if has_target:
		source_target_position = _follow_target.global_position
		intent_position = _get_follow_destination_point()
		if _follow_target_uses_killzone:
			has_killzone = true
			killzone_position = intent_position

	_bot_debug_renderer.call(
		"update_visuals",
		_frame_position,
		_frame_forward_axis,
		_frame_basis.y,
		has_target,
		intent_position,
		has_killzone,
		killzone_position,
		has_target,
		source_target_position,
		_get_bot_debug_label_text()
	)


func _get_bot_debug_label_text() -> String:
	var target_text := "none"
	if _has_follow_target():
		if _follow_target_is_player:
			target_text = "player"
		elif _follow_target_uses_killzone:
			target_text = "killzone"
		else:
			target_text = "static"

	return "BOT %s\nTARGET %s" % [_get_flight_state_name(), target_text]


func _get_flight_state_name() -> String:
	match _flight_state:
		FlightState.SPEED_RECOVERY:
			return "SPEED_RECOVERY"
		FlightState.ALTITUDE_HOLD:
			return "ALTITUDE_HOLD"
		FlightState.LEVEL_FLIGHT:
			return "LEVEL_FLIGHT"
		FlightState.GROUND_AVOIDANCE:
			return "GROUND_AVOIDANCE"
		FlightState.FOLLOW_TARGET:
			return "FOLLOW_TARGET"
		_:
			return "IDLE"


func _update_flight_controls(delta: float) -> void:
	var forward_speed := _get_forward_speed()
	_update_turn_limiter_mode(forward_speed)
	_flight_state = _select_flight_state(forward_speed)

	match _flight_state:
		FlightState.GROUND_AVOIDANCE:
			avoid_ground(delta)
		FlightState.SPEED_RECOVERY:
			_update_speed_recovery_controls(delta, forward_speed)
		FlightState.FOLLOW_TARGET:
			_update_follow_target_controls(delta)
		FlightState.ALTITUDE_HOLD:
			_update_altitude_hold_controls(delta)
		FlightState.LEVEL_FLIGHT:
			_update_level_flight_controls(delta)
		_:
			_update_idle_controls(delta)


func _select_flight_state(forward_speed: float) -> int:
	_update_ground_clearance()
	if _should_avoid_ground(_ground_clearance):
		return FlightState.GROUND_AVOIDANCE

	if _should_recover_speed(forward_speed):
		return FlightState.SPEED_RECOVERY

	if not _can_track_level(forward_speed):
		return FlightState.IDLE

	if _has_follow_target():
		return FlightState.FOLLOW_TARGET

	if _altitude_target_active and _is_climbing_to_altitude():
		return FlightState.ALTITUDE_HOLD

	if _has_checkpoint():
		return FlightState.IDLE

	if _altitude_target_active:
		return FlightState.ALTITUDE_HOLD

	return FlightState.LEVEL_FLIGHT


func avoid_ground(delta: float) -> void:
	_apply_pitch_behavior(
		delta,
		_get_ground_avoidance_pitch_target(),
		GROUND_AVOIDANCE_PITCH_RESPONSE_RATE,
		SPEED_RECOVERY_FULL_THROTTLE_INPUT
	)


func _update_speed_recovery_controls(delta: float, forward_speed: float) -> void:
	var recovery_direction := _get_speed_recovery_direction(forward_speed)
	_apply_control_behavior(
		delta,
		_get_speed_recovery_roll_target(forward_speed),
		_get_speed_recovery_pitch_target(recovery_direction),
		_get_speed_recovery_yaw_target(recovery_direction),
		SPEED_RECOVERY_PITCH_RESPONSE_RATE,
		SPEED_RECOVERY_FULL_THROTTLE_INPUT
	)


func _update_altitude_hold_controls(delta: float) -> void:
	_apply_pitch_behavior(
		delta,
		_get_altitude_pitch_target(_target_altitude),
		ALTITUDE_HOLD_PITCH_RESPONSE_RATE,
		HALF_THROTTLE_INPUT
	)


func _update_level_flight_controls(delta: float) -> void:
	_apply_pitch_behavior(
		delta,
		_get_level_flight_pitch_target(),
		LEVEL_FLIGHT_PITCH_RESPONSE_RATE,
		HALF_THROTTLE_INPUT
	)


func _update_follow_target_controls(delta: float) -> void:
	if not _has_follow_target():
		_update_idle_controls(delta)
		return

	var target_point := _get_follow_destination_point()
	var throttle_target := _get_follow_throttle_target(target_point)

	var desired_direction := target_point - _frame_position
	if _is_in_follow_killzone(target_point):
		desired_direction = _get_follow_alignment_direction()

	turn_toward_direction(
		delta,
		desired_direction,
		target_point.y,
		throttle_target,
		LEVEL_TURN_ROLL_RESPONSE_RATE
	)


func _update_idle_controls(delta: float) -> void:
	if _has_checkpoint():
		level_turn(delta, _get_current_checkpoint())
		return

	_apply_pitch_behavior(
		delta,
		0.0,
		LEVEL_FLIGHT_PITCH_RESPONSE_RATE,
		HALF_THROTTLE_INPUT
	)


func level_turn(delta: float, turn_center: Vector3) -> void:
	var desired_direction := _get_checkpoint_orbit_direction(turn_center)
	turn_toward_direction(delta, desired_direction, turn_center.y)


func turn_toward_point(delta: float, target_point: Vector3) -> void:
	var target_offset := target_point - _frame_position
	turn_toward_direction(delta, target_offset, target_point.y)


func turn_toward_direction(
	delta: float,
	desired_direction: Vector3,
	target_altitude: float = INF,
	throttle_target: float = HALF_THROTTLE_INPUT,
	response_rate: float = LEVEL_TURN_ROLL_RESPONSE_RATE
) -> void:
	var direction := _get_safe_world_direction(desired_direction)
	var local_direction := _frame_inverse_basis * direction
	var turn_angle := _get_local_turn_angle(local_direction)
	if _should_use_correction_turn(local_direction, turn_angle):
		_apply_correction_turn(delta, throttle_target, response_rate)
		return

	if turn_angle <= TURN_ANGLE_DEADBAND_RAD:
		_apply_pitch_behavior(
			delta,
			_get_turn_altitude_pitch_target(target_altitude),
			LEVEL_FLIGHT_PITCH_RESPONSE_RATE,
			throttle_target
		)
		return

	var roll_target := _get_lift_vector_roll_target(local_direction, turn_angle)
	var pitch_target := _get_turn_pitch_target(turn_angle, target_altitude)
	_apply_control_behavior(
		delta,
		roll_target,
		pitch_target,
		0.0,
		response_rate,
		throttle_target
	)


func _apply_correction_turn(delta: float, throttle_target: float, response_rate: float) -> void:
	_apply_control_behavior(
		delta,
		_get_wings_level_roll_target(),
		_get_correction_turn_pitch_target(),
		0.0,
		response_rate,
		throttle_target
	)


func _apply_pitch_behavior(delta: float, pitch_target: float, response_rate: float, throttle_target: float) -> void:
	_apply_control_behavior(
		delta,
		_get_wings_level_roll_target(),
		pitch_target,
		0.0,
		response_rate,
		throttle_target
	)


func _apply_control_behavior(
	delta: float,
	roll_target: float,
	pitch_target: float,
	yaw_target: float,
	response_rate: float,
	throttle_target: float
) -> void:
	var clamped_roll_target := clampf(roll_target, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT)
	var clamped_pitch_target := clampf(pitch_target, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT)
	var clamped_yaw_target := clampf(yaw_target, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT)
	var pitch_step := maxf(response_rate * delta, 0.0)
	var roll_step := maxf(LEVEL_TURN_ROLL_RESPONSE_RATE * delta, pitch_step)
	var yaw_step := maxf(LEVEL_TURN_YAW_RESPONSE_RATE * delta, pitch_step)
	_roll_input = move_toward(_roll_input, clamped_roll_target, roll_step)
	_pitch_input = move_toward(_pitch_input, clamped_pitch_target, pitch_step)
	_yaw_input = move_toward(_yaw_input, clamped_yaw_target, yaw_step)
	_apply_controls(_roll_input, _pitch_input, _yaw_input, throttle_target)


func _should_avoid_ground(clearance: float) -> bool:
	var min_clearance := maxf(min_ground_clearance, 0.0)
	if min_clearance <= 0.0:
		return false

	if not is_finite(clearance):
		return false

	var descending_rate := _get_ground_closure_rate()
	if _flight_state == FlightState.GROUND_AVOIDANCE:
		var exit_clearance := min_clearance + maxf(ground_clearance_tolerance, 0.0)
		return clearance < exit_clearance or _will_hit_ground_soon(clearance, descending_rate)

	return clearance < min_clearance or _will_hit_ground_soon(clearance, descending_rate)


func _update_ground_clearance() -> void:
	if maxf(min_ground_clearance, 0.0) <= 0.0:
		_ground_clearance = INF
		return

	var now_seconds := Time.get_ticks_msec() / 1000.0
	if not _should_probe_ground(now_seconds):
		return

	_ground_clearance = _measure_ground_clearance()
	_next_ground_probe_time = now_seconds + _get_next_ground_probe_interval()


func _should_probe_ground(now_seconds: float) -> bool:
	if now_seconds >= _next_ground_probe_time:
		return true

	if _flight_state == FlightState.GROUND_AVOIDANCE:
		return true

	if not is_finite(_ground_clearance):
		return _has_fast_ground_closure()

	return _is_ground_probe_urgent(_ground_clearance)


func _get_next_ground_probe_interval() -> float:
	if _flight_state == FlightState.GROUND_AVOIDANCE:
		return 0.0

	if not is_finite(_ground_clearance):
		return GROUND_PROBE_SAFE_INTERVAL

	if _is_ground_probe_urgent(_ground_clearance):
		return 0.0

	return GROUND_PROBE_SAFE_INTERVAL


func _is_ground_probe_urgent(clearance: float) -> bool:
	if _has_fast_ground_closure():
		return true

	if not is_finite(clearance):
		return false

	var min_clearance := maxf(min_ground_clearance, 0.0)
	var near_clearance := min_clearance * GROUND_PROBE_NEAR_CLEARANCE_MULTIPLIER
	near_clearance += maxf(ground_clearance_tolerance, 0.0)
	if clearance <= near_clearance:
		return true

	return _will_hit_ground_soon(clearance, _get_ground_closure_rate())


func _has_fast_ground_closure() -> bool:
	var threshold := maxf(
		ground_avoidance_closure_rate_for_max_pull * GROUND_PROBE_FAST_CLOSURE_RATIO,
		1.0
	)
	return _get_ground_closure_rate() >= threshold


func _get_ground_avoidance_pitch_target() -> float:
	var min_clearance := maxf(min_ground_clearance, 1.0)
	var clearance := clampf(_ground_clearance, 0.0, min_clearance)
	var clearance_urgency := 1.0 - (clearance / min_clearance)
	var closure_urgency := clampf(
		_get_ground_closure_rate() / maxf(ground_avoidance_closure_rate_for_max_pull, 1.0),
		0.0,
		1.0
	)
	var dive_angle_urgency := clampf(
		_get_downward_flight_path_angle_deg() / maxf(ground_avoidance_dive_angle_for_max_pull_deg, 1.0),
		0.0,
		1.0
	)
	var urgency := maxf(clearance_urgency, maxf(closure_urgency, dive_angle_urgency))
	var nose_up_input := lerpf(
		GROUND_AVOIDANCE_MIN_NOSE_UP_INPUT,
		CONTROL_INPUT_LIMIT,
		urgency
	)
	return -nose_up_input


func _will_hit_ground_soon(clearance: float, descending_rate: float) -> bool:
	if descending_rate <= 0.0:
		return false

	var lookahead := maxf(ground_avoidance_time_to_impact, 0.0)
	if lookahead <= 0.0:
		return false

	return clearance / descending_rate <= lookahead


func _get_ground_closure_rate() -> float:
	return maxf(-_frame_velocity.y, 0.0)


func _get_downward_flight_path_angle_deg() -> float:
	if _frame_speed <= 0.001:
		return 0.0

	return rad_to_deg(asin(clampf(-_frame_velocity.y / _frame_speed, 0.0, 1.0)))


func _should_recover_speed(forward_speed: float) -> bool:
	var min_speed := maxf(min_acceptable_forward_speed, 0.0)
	if min_speed <= 0.0:
		return false

	if _flight_state == FlightState.SPEED_RECOVERY:
		return forward_speed < _get_recovery_exit_speed()

	return forward_speed < min_speed


func _get_speed_recovery_ratio(forward_speed: float) -> float:
	var min_speed := maxf(min_acceptable_forward_speed, 0.0)
	var exit_speed := _get_recovery_exit_speed()
	var speed_span := maxf(exit_speed - min_speed, 1.0)
	return clampf((exit_speed - forward_speed) / speed_span, 0.0, 1.0)


func _get_speed_recovery_direction(forward_speed: float) -> Vector3:
	var recovery_ratio := _get_speed_recovery_ratio(forward_speed)
	var horizontal_direction := _get_speed_recovery_horizontal_direction()
	if not _has_follow_target():
		return _blend_directions(horizontal_direction, Vector3.DOWN, recovery_ratio)

	var destination_point := _get_follow_destination_point()
	var destination_offset := destination_point - _frame_position
	var horizontal_to_destination := Vector3(destination_offset.x, 0.0, destination_offset.z)
	if horizontal_to_destination.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		horizontal_to_destination = horizontal_direction
	else:
		horizontal_to_destination = horizontal_to_destination.normalized()

	if destination_offset.y < 0.0:
		var destination_direction := _get_safe_world_direction(destination_offset)
		return _blend_directions(horizontal_to_destination, destination_direction, recovery_ratio)

	return _blend_directions(
		horizontal_to_destination,
		Vector3.DOWN,
		recovery_ratio * SPEED_RECOVERY_TARGET_ABOVE_MAX_NADIR_BLEND
	)


func _get_speed_recovery_horizontal_direction() -> Vector3:
	var horizontal_direction := _frame_forward_axis
	horizontal_direction.y = 0.0
	if horizontal_direction.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return Vector3.FORWARD

	return horizontal_direction.normalized()


func _blend_directions(from_direction: Vector3, to_direction: Vector3, weight: float) -> Vector3:
	var blended_direction := from_direction.lerp(to_direction, clampf(weight, 0.0, 1.0))
	if blended_direction.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return _get_safe_world_direction(to_direction)

	return blended_direction.normalized()


func _get_speed_recovery_pitch_target(recovery_direction: Vector3) -> float:
	var local_direction := _get_local_direction(recovery_direction)
	var pitch_error := atan2(local_direction.y, -local_direction.z)
	return _get_pitch_input_for_error(pitch_error)


func _get_speed_recovery_yaw_target(recovery_direction: Vector3) -> float:
	var local_direction := _get_local_direction(recovery_direction)
	var yaw_error := atan2(local_direction.x, -local_direction.z)
	return _get_yaw_input_for_error(yaw_error)


func _get_speed_recovery_roll_target(forward_speed: float) -> float:
	if _has_follow_target():
		return _get_roll_target_toward_point(_get_follow_destination_point())

	if forward_speed < SPEED_RECOVERY_WINGS_LEVEL_MIN_FORWARD_SPEED:
		return 0.0

	if _get_downward_flight_path_angle_deg() > SPEED_RECOVERY_WINGS_LEVEL_MAX_DIVE_ANGLE_DEG:
		return 0.0

	return _get_wings_level_roll_target()


func _get_roll_target_toward_point(target_point: Vector3) -> float:
	var direction := _get_safe_world_direction(target_point - _frame_position)
	var local_direction := _get_local_direction(direction)
	var turn_angle := _get_local_turn_angle(local_direction)
	return _get_lift_vector_roll_target(local_direction, turn_angle)


func _can_track_level(forward_speed: float) -> bool:
	return forward_speed >= maxf(min_acceptable_forward_speed, 0.0)


func _get_level_flight_pitch_target() -> float:
	var vertical_speed := _frame_velocity.y
	return vertical_speed * LEVEL_FLIGHT_VERTICAL_SPEED_GAIN


func _get_altitude_pitch_target(target_altitude: float) -> float:
	var altitude_error := target_altitude - _frame_position.y
	var desired_vertical_speed := clampf(
		altitude_error * ALTITUDE_HOLD_ALTITUDE_GAIN,
		-ALTITUDE_HOLD_MAX_VERTICAL_SPEED,
		ALTITUDE_HOLD_MAX_VERTICAL_SPEED
	)
	var vertical_speed_error := desired_vertical_speed - _frame_velocity.y
	return -vertical_speed_error * ALTITUDE_HOLD_VERTICAL_SPEED_GAIN


func _get_recovery_exit_speed() -> float:
	return maxf(reserve_forward_speed, min_acceptable_forward_speed)


func _update_turn_limiter_mode(forward_speed: float) -> void:
	if not _plane.has_method("set_sustain_turn_limiter_runtime_enabled"):
		return

	var threshold := maxf(max_lift_turn_min_forward_speed, 0.0)
	var sustain_limiter_enabled := forward_speed < threshold
	if _has_applied_turn_limiter_mode and sustain_limiter_enabled == _last_sustain_turn_limiter_enabled:
		return

	_has_applied_turn_limiter_mode = true
	_last_sustain_turn_limiter_enabled = sustain_limiter_enabled
	_plane.call("set_sustain_turn_limiter_runtime_enabled", sustain_limiter_enabled)


func _update_follow_target_velocity(delta: float) -> void:
	_update_player_target_acquisition(delta)
	if not _has_follow_target():
		return

	var target_position := _follow_target.global_position
	if _follow_target is RigidBody3D:
		_follow_target_velocity = (_follow_target as RigidBody3D).linear_velocity
	elif _has_follow_target_sample and delta > 0.0:
		_follow_target_velocity = (target_position - _last_follow_target_position) / delta
	else:
		_follow_target_velocity = Vector3.ZERO

	_last_follow_target_position = target_position
	_has_follow_target_sample = true


func _has_follow_target() -> bool:
	if is_instance_valid(_follow_target):
		return true

	_follow_target = null
	_follow_target_is_player = false
	_follow_target_uses_killzone = false
	_has_follow_target_sample = false
	_follow_target_velocity = Vector3.ZERO
	return false


func _get_follow_throttle_target(destination_point: Vector3) -> float:
	if not _is_in_follow_killzone(destination_point):
		return SPEED_RECOVERY_FULL_THROTTLE_INPUT

	var horizontal_offset := Vector2(
		destination_point.x - _frame_position.x,
		destination_point.z - _frame_position.z
	)

	var closure_speed := _get_follow_horizontal_closure_speed(horizontal_offset)
	var tolerance := maxf(overshoot_closure_tolerance, 0.0)
	if closure_speed <= tolerance:
		return SPEED_RECOVERY_FULL_THROTTLE_INPUT

	return clampf(-((closure_speed - tolerance) * maxf(overshoot_throttle_gain, 0.0)), -1.0, 0.0)


func _get_follow_horizontal_closure_speed(horizontal_offset: Vector2) -> float:
	if horizontal_offset.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return 0.0

	var line_direction := horizontal_offset.normalized()
	var plane_velocity := Vector2(_frame_velocity.x, _frame_velocity.z)
	var target_velocity := Vector2(_follow_target_velocity.x, _follow_target_velocity.z)
	return (plane_velocity - target_velocity).dot(line_direction)


func _update_player_target_acquisition(delta: float) -> void:
	_player_target_reacquire_timer -= delta
	if _player_target_reacquire_timer > 0.0 and (_follow_target_is_player and _has_follow_target()):
		return

	_player_target_reacquire_timer = PLAYER_TARGET_REACQUIRE_INTERVAL
	var player_target := _find_player_target()
	if player_target != null:
		if player_target != _follow_target:
			_set_active_follow_target(player_target, true)
		return

	if _follow_target_is_player:
		_set_active_follow_target(_fallback_follow_target, false, _fallback_follow_target_uses_killzone)


func _find_player_target() -> Node3D:
	var scene_tree := get_tree()
	if scene_tree == null or _plane == null:
		return null

	var best_target: Node3D
	var best_distance_squared := INF
	for candidate in scene_tree.get_nodes_in_group("player_character"):
		if candidate == _plane or not candidate is Node3D:
			continue

		var candidate_node := candidate as Node3D
		if _is_bot_character(candidate_node):
			continue

		var distance_squared := _frame_position.distance_squared_to(candidate_node.global_position)
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_target = candidate_node

	return best_target


func _is_bot_character(candidate: Node3D) -> bool:
	var bot_value: Variant = candidate.get("is_bot_controlled")
	return bot_value != null and bool(bot_value)


func _get_follow_destination_point() -> Vector3:
	if not _has_follow_target():
		return Vector3.ZERO

	if _follow_target_uses_killzone:
		return _get_target_killzone_point(_follow_target)

	return _follow_target.global_position


func _get_target_killzone_point(target: Node3D) -> Vector3:
	return target.global_position + _get_target_behind_direction(target) * maxf(killzone_distance, 0.0)


func _get_target_behind_direction(target: Node3D) -> Vector3:
	var behind := target.global_transform.basis.z
	if behind.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return Vector3.BACK

	return behind.normalized()


func _is_in_follow_killzone(killzone_point: Vector3) -> bool:
	var tolerance := maxf(killzone_tolerance, 0.0)
	if tolerance <= 0.0:
		return false

	return _frame_position.distance_to(killzone_point) <= tolerance


func _get_follow_alignment_direction() -> Vector3:
	if _follow_target_velocity.length_squared() > MIN_DIRECTION_LENGTH_SQUARED:
		return _follow_target_velocity.normalized()

	if _has_follow_target():
		return -_follow_target.global_transform.basis.z.normalized()

	return _frame_forward_axis


func _get_safe_world_direction(direction: Vector3) -> Vector3:
	if direction.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return _frame_forward_axis

	return direction.normalized()


func _get_local_direction(world_direction: Vector3) -> Vector3:
	return _frame_inverse_basis * world_direction


func _get_local_turn_angle(local_direction: Vector3) -> float:
	var forward_alignment := clampf(-local_direction.z, -1.0, 1.0)
	return acos(forward_alignment)


func _get_lift_vector_roll_target(local_direction: Vector3, turn_angle: float) -> float:
	var transverse_length_squared := local_direction.x * local_direction.x + local_direction.y * local_direction.y
	if transverse_length_squared <= MIN_DIRECTION_LENGTH_SQUARED:
		return _get_wings_level_roll_target()

	var lift_vector_error := atan2(local_direction.x, local_direction.y)
	var turn_ratio := clampf(turn_angle / TURN_FULL_PULL_ANGLE_RAD, 0.0, 1.0)
	return _get_roll_input_for_error(lift_vector_error, LEVEL_TURN_ROLL_GAIN, turn_ratio)


func _should_use_correction_turn(local_direction: Vector3, turn_angle: float) -> bool:
	var threshold := deg_to_rad(maxf(correction_turn_small_angle_deg, 0.0))
	if threshold <= 0.0:
		_correction_turn_active = false
		return false

	if -local_direction.z <= 0.0:
		_correction_turn_active = false
		return false

	var lateral_angle := absf(atan2(local_direction.x, -local_direction.z))
	if lateral_angle < CORRECTION_TURN_MIN_LATERAL_ANGLE_RAD:
		_correction_turn_active = false
		return false

	if absf(local_direction.y) > absf(local_direction.x):
		_correction_turn_active = false
		return false

	if _correction_turn_active:
		if turn_angle < threshold + CORRECTION_TURN_HYSTERESIS_RAD:
			return true

		_correction_turn_active = false
		return false

	if turn_angle < threshold:
		_correction_turn_active = true
		return true

	return false


func _get_wings_level_roll_target() -> float:
	var local_world_up := _frame_inverse_basis * Vector3.UP
	var bank_error := atan2(local_world_up.x, local_world_up.y)
	if absf(bank_error) <= WINGS_LEVEL_DEADBAND_RAD and absf(_get_local_roll_rate()) <= ROLL_RATE_DEADBAND:
		return 0.0

	return _get_roll_input_for_error(bank_error, WINGS_LEVEL_ROLL_GAIN)


func _get_roll_input_for_error(roll_error: float, angle_to_rate_gain: float, rate_scale: float = 1.0) -> float:
	return _get_rate_stabilized_axis_input(
		roll_error,
		angle_to_rate_gain,
		ROLL_MAX_DESIRED_RATE,
		_get_local_roll_rate(),
		ROLL_RATE_RESPONSE_GAIN,
		-1.0,
		1.0,
		rate_scale
	)


func _get_local_roll_rate() -> float:
	return _get_local_angular_velocity().z


func _get_pitch_input_for_error(pitch_error: float) -> float:
	return _get_rate_stabilized_axis_input(
		pitch_error,
		SPEED_RECOVERY_PITCH_ANGLE_TO_RATE_GAIN,
		SPEED_RECOVERY_MAX_DESIRED_PITCH_RATE,
		_get_local_pitch_rate(),
		SPEED_RECOVERY_PITCH_RATE_RESPONSE_GAIN,
		1.0,
		-1.0
	)


func _get_yaw_input_for_error(yaw_error: float) -> float:
	return _get_rate_stabilized_axis_input(
		yaw_error,
		SPEED_RECOVERY_YAW_ANGLE_TO_RATE_GAIN,
		SPEED_RECOVERY_MAX_DESIRED_YAW_RATE,
		_get_local_yaw_rate(),
		SPEED_RECOVERY_YAW_RATE_RESPONSE_GAIN,
		-1.0,
		1.0
	)


func _get_rate_stabilized_axis_input(
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
	return _get_rate_stabilized_input_for_desired_rate(
		desired_rate,
		local_rate,
		rate_response_gain,
		input_sign
	)


func _get_rate_stabilized_input_for_desired_rate(
	desired_rate: float,
	local_rate: float,
	rate_response_gain: float,
	input_sign: float
) -> float:
	var rate_error := desired_rate - local_rate
	return clampf(
		rate_error * rate_response_gain * input_sign,
		-CONTROL_INPUT_LIMIT,
		CONTROL_INPUT_LIMIT
	)


func _get_local_pitch_rate() -> float:
	return _get_local_angular_velocity().x


func _get_local_yaw_rate() -> float:
	return _get_local_angular_velocity().y


func _get_local_angular_velocity() -> Vector3:
	return _frame_local_angular_velocity


func _get_turn_pitch_target(turn_angle: float, target_altitude: float) -> float:
	return _get_turn_pull_pitch_target(turn_angle) + _get_turn_altitude_pitch_target(target_altitude)


func _get_turn_pull_pitch_target(turn_angle: float) -> float:
	if turn_angle <= TURN_MIN_PULL_ANGLE_RAD:
		return 0.0

	return _get_rate_stabilized_axis_input(
		turn_angle,
		TURN_PITCH_ANGLE_TO_RATE_GAIN,
		TURN_MAX_DESIRED_PITCH_RATE,
		_get_local_pitch_rate(),
		TURN_PITCH_RATE_RESPONSE_GAIN,
		1.0,
		-1.0
	)


func _get_correction_turn_pitch_target() -> float:
	return _get_rate_stabilized_input_for_desired_rate(
		-CORRECTION_TURN_PITCH_DOWN_RATE,
		_get_local_pitch_rate(),
		TURN_PITCH_RATE_RESPONSE_GAIN,
		-1.0
	)


func _get_turn_altitude_pitch_target(target_altitude: float) -> float:
	if target_altitude >= INF:
		return 0.0

	return _get_altitude_pitch_target(target_altitude)


func _has_checkpoint() -> bool:
	return not checkpoints.is_empty()


func _get_clamped_checkpoint_index() -> int:
	if checkpoints.is_empty():
		return 0

	_checkpoint_index = clampi(_checkpoint_index, 0, checkpoints.size() - 1)
	return _checkpoint_index


func _get_checkpoint_orbit_direction(turn_center: Vector3) -> Vector3:
	var plane_position := _frame_position
	var radial_from_center := Vector3(
		plane_position.x - turn_center.x,
		0.0,
		plane_position.z - turn_center.z
	)

	if radial_from_center.length_squared() <= 0.000001:
		radial_from_center = _get_horizontal_forward_axis()
	else:
		radial_from_center = radial_from_center.normalized()

	var orbit_sign := 1.0 if checkpoint_orbit_direction >= 0.0 else -1.0
	var tangent := Vector3.UP.cross(radial_from_center).normalized() * orbit_sign
	var horizontal_distance := Vector2(
		plane_position.x - turn_center.x,
		plane_position.z - turn_center.z
	).length()
	var radius := maxf(checkpoint_orbit_radius, 1.0)
	var radial_error := clampf(
		(horizontal_distance - radius) / radius,
		-1.0,
		1.0
	)
	if absf(radial_error) <= CHECKPOINT_ORBIT_RADIUS_DEADBAND:
		radial_error = 0.0

	var radial_correction := -radial_from_center * radial_error * CHECKPOINT_ORBIT_RADIAL_CORRECTION
	var desired_direction := tangent + radial_correction
	if desired_direction.length_squared() <= 0.000001:
		return tangent

	return desired_direction.normalized()


func _get_horizontal_forward_axis() -> Vector3:
	var forward_axis := _frame_forward_axis
	forward_axis.y = 0.0
	if forward_axis.length_squared() <= 0.000001:
		return Vector3.FORWARD

	return forward_axis.normalized()


func _apply_controls(roll_value: float, pitch_value: float, yaw_value: float, throttle_value: float) -> void:
	if _plane.has_method("set_bot_control_inputs"):
		_plane.call(
			"set_bot_control_inputs",
			clampf(roll_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT),
			clampf(pitch_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT),
			clampf(yaw_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT),
			clampf(throttle_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT)
		)


func _record_telemetry_sample() -> void:
	if _plane == null:
		return

	telemetry_samples.append({
		"time": Time.get_ticks_msec() / 1000.0,
		"forward_speed": _get_forward_speed(),
		"altitude": _frame_position.y,
	})
	_trim_telemetry_samples()


func _trim_telemetry_samples() -> void:
	var max_samples := maxi(telemetry_max_samples, 2)
	while telemetry_samples.size() > max_samples:
		telemetry_samples.remove_at(0)


func _get_forward_speed() -> float:
	return _frame_forward_speed


func _measure_ground_clearance() -> float:
	if _plane == null or not _plane.is_inside_tree():
		return INF

	var world_ref := _plane.get_world_3d()
	if world_ref == null:
		return INF

	var ray_distance := maxf(ground_probe_distance, min_ground_clearance)
	if ray_distance <= 0.0:
		return INF

	var from_point := _frame_position
	var to_point := from_point + Vector3.DOWN * ray_distance
	var query := PhysicsRayQueryParameters3D.create(from_point, to_point)
	query.exclude = _get_ground_probe_exclusions()
	query.collide_with_areas = false

	var hit := world_ref.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return INF

	var hit_position: Vector3 = hit.get("position", to_point)
	return from_point.distance_to(hit_position)


func _get_ground_probe_exclusions() -> Array[RID]:
	var now_seconds := Time.get_ticks_msec() / 1000.0
	if not _ground_probe_exclusions.is_empty() and now_seconds < _next_ground_probe_exclusion_refresh_time:
		return _ground_probe_exclusions

	_next_ground_probe_exclusion_refresh_time = now_seconds + GROUND_PROBE_EXCLUSION_REFRESH_INTERVAL
	_ground_probe_exclusions = [_plane.get_rid()]
	var scene_tree := get_tree()
	if scene_tree == null:
		return _ground_probe_exclusions

	for candidate in scene_tree.get_nodes_in_group("player_character"):
		if candidate is CollisionObject3D:
			_ground_probe_exclusions.append((candidate as CollisionObject3D).get_rid())

	return _ground_probe_exclusions


func _find_reference_sample(latest_time: float, window_seconds: float) -> Dictionary:
	var target_time := latest_time - maxf(window_seconds, telemetry_sample_interval)
	var reference: Dictionary = telemetry_samples[0]
	for sample: Dictionary in telemetry_samples:
		if float(sample["time"]) > target_time:
			break
		reference = sample

	return reference


func _make_unknown_motion_trend() -> Dictionary:
	return {
		"has_enough_data": false,
		"sample_count": telemetry_samples.size(),
		"elapsed_seconds": 0.0,
		"forward_speed": 0.0,
		"altitude": 0.0,
		"speed_delta": 0.0,
		"altitude_delta": 0.0,
		"acceleration": 0.0,
		"vertical_speed": 0.0,
	}
