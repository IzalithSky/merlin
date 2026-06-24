class_name PlaneBotPilot
extends Node

const BOT_DEBUG_RENDERER_SCRIPT := preload("res://scripts/bot_debug_renderer_3d.gd")
const PLANE_BOT_DEBUG_ADAPTER_SCRIPT := preload("res://scripts/plane_bot_debug_adapter.gd")
const PLANE_BOT_ENGAGEMENT_MODEL_SCRIPT := preload("res://scripts/plane_bot_engagement_model.gd")

# Four global modes. Selection (the conditions below) decides which one is active;
# execution is intentionally left as placeholders to be rebuilt.
enum Mode {
	AVOIDANCE,
	SPEED_MANAGEMENT,
	GOTO,
	FINETRACK,
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
const SPEED_REDUCTION_MIN_THROTTLE_INPUT := -1.0
const SPEED_REDUCTION_PITCH_RESPONSE_RATE := 0.16
const SPEED_REDUCTION_MAX_NOSE_UP_INPUT := 0.6
# Attitude targets for speed management, scaled by how far out of the speed band the
# bot is: dive to regain speed when too slow, climb to bleed it when too fast.
const SPEED_RECOVERY_MAX_DIVE_ANGLE_RAD := PI / 4.0
const SPEED_REDUCTION_MAX_CLIMB_ANGLE_RAD := PI / 4.0
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
const TURN_ROLLOUT_ANGLE_RAD := PI / 12.0
const FINE_TRACKING_HYSTERESIS_RAD := 2.0 * PI / 180.0
const FINE_TRACKING_BANK_GAIN := 1.5
const FINE_TRACKING_MAX_BANK_RAD := PI / 4.0
const WINGS_LEVEL_DEADBAND_RAD := PI / 180.0
const MIN_DIRECTION_LENGTH_SQUARED := 0.000001
const PLAYER_TARGET_REACQUIRE_INTERVAL := 0.5
const GROUP_CACHE_REFRESH_INTERVAL := 0.25
const GROUND_PROBE_EXCLUSION_REFRESH_INTERVAL := 1.0
const GROUND_PROBE_SAFE_INTERVAL := 0.25
const GROUND_PROBE_NEAR_CLEARANCE_MULTIPLIER := 2.0
const GROUND_PROBE_FAST_CLOSURE_RATIO := 0.25
# Forward (flight-path) terrain probe: the down ray can't see a mountain or upslope
# the bot is flying level into, so also cast along the velocity vector.
const GROUND_PROBE_TERRAIN_URGENT_FACTOR := 2.0
const GROUND_AVOIDANCE_TERRAIN_EXIT_FACTOR := 1.5
const GROUND_ESCAPE_CANDIDATES: Array[Vector2] = [
	Vector2(0.0, 30.0),
	Vector2(0.0, 55.0),
	Vector2(-40.0, 25.0),
	Vector2(40.0, 25.0),
	Vector2(-75.0, 15.0),
	Vector2(75.0, 15.0),
]
const GROUND_ESCAPE_YAW_PENALTY := 1.5
const CONTROL_INPUT_LIMIT := 1.0
# Proportional control foundation: input magnitude scales with the error, reaching
# full deflection at ~0.5 rad (~29 deg) of error with a gain of 2.0.
const PROPORTIONAL_ROLL_GAIN := 2.0
const PROPORTIONAL_PITCH_GAIN := 2.0
# GOTO steers by rolling the lift vector onto the target, then pulling (pitch up).
# It never blends the two: roll until aligned within ALIGN, then pitch; when the
# bank drifts past REALIGN, stop pitching and roll again.
const GOTO_ROLL_ALIGN_RAD := PI / 36.0
const GOTO_ROLL_REALIGN_RAD := PI / 15.0
# Upward slope of the climb direction when seeking a higher altitude with no target.
const GOTO_CLIMB_SLOPE := 0.5
const FOLLOW_LEAD_MAX_TIME := 3.0
const FOLLOW_LEAD_MIN_CLOSING_SPEED := 1.0
const FOLLOW_THROTTLE_BRAKE_DISTANCE_SCALE := 2.0
# Planes are a 10 m box, and the constant-velocity CPA prediction underestimates
# the real miss because both planes keep curving toward each other while pursuing,
# so keep a generous miss-distance and look further ahead to start the break early.
const COLLISION_AVOIDANCE_RADIUS := 50.0
const COLLISION_AVOIDANCE_LOOKAHEAD := 3.0
const COLLISION_AVOIDANCE_MIN_DURATION := 0.5
const COLLISION_AVOIDANCE_RESPONSE_RATE := 1.5
const COLLISION_AVOIDANCE_BANK_DEG := 90.0
# Only treat a nearby plane as a collision threat when the gap is actually shrinking
# fast. Managed pursuit keeps the bot parked in its killzone at near-zero closing
# speed, so without this gate the bot would jink at every plane it is tailing.
const COLLISION_AVOIDANCE_MIN_CLOSING_SPEED := 40.0

@export var min_acceptable_forward_speed: float = 70.0
@export var reserve_forward_speed: float = 85.0
@export var max_acceptable_forward_speed: float = 150.0
@export var speed_reduction_reserve_forward_speed: float = 130.0
@export var default_altitude: float = 5000.0
@export var min_ground_clearance: float = 300.0
@export var ground_clearance_tolerance: float = 25.0
@export var ground_avoidance_time_to_impact: float = 4.0
@export var ground_avoidance_closure_rate_for_max_pull: float = 120.0
@export var ground_avoidance_dive_angle_for_max_pull_deg: float = 35.0
@export var ground_probe_distance: float = 1000.0
@export var checkpoint_orbit_radius: float = 500.0
@export var checkpoint_orbit_direction: float = 1.0
@export var fine_tracking_angle_deg: float = 8.0
@export var overshoot_closure_tolerance: float = 0.5
@export var overshoot_throttle_gain: float = 0.08
@export var killzone_distance: float = 250.0
@export var killzone_tolerance: float = 150.0
@export var autocannon_fire_max_range: float = 650.0
@export var avoid_missiles: bool = true
@export var debug_bot_visuals_enabled := true
@export var checkpoints: Array[Vector3] = [
	Vector3(0.0, 1500.0, 0.0),
]

var _plane: PlaneCharacter
var _altitude_target_active := false
var _target_altitude := 0.0
var _mode: int = Mode.GOTO
var _roll_input := 0.0
var _pitch_input := 0.0
var _yaw_input := 0.0
var _ground_clearance := INF
var _terrain_ahead_distance := INF
var _next_ground_probe_time := 0.0
var _checkpoint_index := 0
var _fine_tracking_active := false
var _goto_pitching := false
var _debug_adapter
var _engagement
var _frame_position := Vector3.ZERO
var _frame_velocity := Vector3.ZERO
var _frame_speed := 0.0
var _frame_basis := Basis.IDENTITY
var _frame_inverse_basis := Basis.IDENTITY
var _frame_forward_axis := Vector3.FORWARD
var _frame_forward_speed := 0.0
var _frame_local_angular_velocity := Vector3.ZERO


func _ready() -> void:
	_plane = get_parent() as PlaneCharacter
	if _plane == null:
		set_physics_process(false)
		return
	_debug_adapter = PLANE_BOT_DEBUG_ADAPTER_SCRIPT.new(self)
	_engagement = PLANE_BOT_ENGAGEMENT_MODEL_SCRIPT.new(self)

	_update_frame_cache()
	climb_to_altitude(default_altitude)
	_ensure_bot_debug_renderer()
	_update_bot_debug_renderer_state()


func _physics_process(delta: float) -> void:
	if _plane.is_shot_down:
		_debug_adapter.handle_shot_down()
		return
	_update_frame_cache()
	_update_follow_target_velocity(delta)
	_update_flight_controls(delta)
	_update_weapon_targeting()
	_update_bot_debug_visuals()


func _update_frame_cache() -> void:
	var plane_transform: Transform3D = _plane.global_transform
	_frame_position = plane_transform.origin
	_frame_velocity = _plane.linear_velocity
	_frame_speed = _frame_velocity.length()
	_frame_basis = plane_transform.basis.orthonormalized()
	_frame_inverse_basis = _frame_basis.transposed()
	_frame_forward_axis = -_frame_basis.z
	_frame_forward_speed = _frame_velocity.dot(_frame_forward_axis)
	_frame_local_angular_velocity = _frame_inverse_basis * _plane.angular_velocity


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
	_engagement.set_follow_target(target, use_killzone)


func _ensure_bot_debug_renderer() -> void:
	_debug_adapter.ensure_renderer()


func _update_bot_debug_renderer_state() -> void:
	_debug_adapter.update_renderer_state()


func _update_bot_debug_visuals() -> void:
	_debug_adapter.update_visuals()


func get_flight_state_name() -> String:
	match _mode:
		Mode.AVOIDANCE:
			return "AVOIDANCE"
		Mode.SPEED_MANAGEMENT:
			return "SPEEDMANAGEMENT"
		Mode.FINETRACK:
			return "FINETRACK"
		_:
			return "GOTO"


func get_engagement_debug_snapshot() -> Dictionary:
	return _engagement.get_debug_snapshot()


func get_follow_target_debug_label() -> String:
	return _engagement.get_follow_target_debug_label()


# ---------------------------------------------------------------------------
# Mode selection (conditions). Execution is dispatched to placeholders below.
# ---------------------------------------------------------------------------
func _update_flight_controls(delta: float) -> void:
	var forward_speed := _get_forward_speed()
	_update_collision_threat()
	_mode = _select_mode(forward_speed)

	match _mode:
		Mode.AVOIDANCE:
			_execute_avoidance(delta)
		Mode.SPEED_MANAGEMENT:
			_execute_speed_management(delta)
		Mode.FINETRACK:
			_execute_finetrack(delta)
		_:
			_execute_goto(delta)


func _select_mode(forward_speed: float) -> int:
	_update_ground_clearance()
	if _should_avoid_ground(_ground_clearance):
		return Mode.AVOIDANCE

	if _engagement.get_collision_avoidance_direction() != 0.0:
		return Mode.AVOIDANCE

	if _should_recover_speed(forward_speed):
		return Mode.SPEED_MANAGEMENT

	if _should_reduce_speed(forward_speed):
		return Mode.SPEED_MANAGEMENT

	if _should_fine_track(forward_speed):
		return Mode.FINETRACK

	return Mode.GOTO


# ---------------------------------------------------------------------------
# Execution placeholders. Conditions above pick the mode; the actual control
# inputs are intentionally not driven yet -- to be reworked.
# ---------------------------------------------------------------------------
func _execute_avoidance(_delta: float) -> void:
	# TODO: ground + plane collision avoidance.
	pass


func _execute_speed_management(_delta: float) -> void:
	# Blending is allowed here (unlike GOTO): wings-leveling roll runs together with
	# pitch, and pitch may go down (dive) to regain speed when too slow.
	var forward_speed := _get_forward_speed()
	if _should_reduce_speed(forward_speed):
		_execute_speed_reduction(forward_speed)
	else:
		_execute_speed_recovery(forward_speed)


func _execute_speed_recovery(forward_speed: float) -> void:
	# Too slow: dive proportionally to the deficit (full throttle) to trade altitude
	# for airspeed, keeping the wings level for a clean dive.
	var ratio := _get_speed_recovery_ratio(forward_speed)
	var desired_pitch := -ratio * SPEED_RECOVERY_MAX_DIVE_ANGLE_RAD
	var pitch_input := _proportional_pitch(desired_pitch - _get_pitch_angle())
	_apply_controls(
		_wings_level_roll(),
		pitch_input,
		0.0,
		SPEED_RECOVERY_FULL_THROTTLE_INPUT
	)


func _execute_speed_reduction(forward_speed: float) -> void:
	# Too fast: climb proportionally to the excess and cut throttle so the climb
	# bleeds airspeed via gravity and induced drag.
	var ratio := _get_speed_reduction_ratio(forward_speed)
	var desired_pitch := ratio * SPEED_REDUCTION_MAX_CLIMB_ANGLE_RAD
	var pitch_input := _proportional_pitch(desired_pitch - _get_pitch_angle())
	var throttle := lerpf(HALF_THROTTLE_INPUT, SPEED_REDUCTION_MIN_THROTTLE_INPUT, ratio)
	_apply_controls(_wings_level_roll(), pitch_input, 0.0, throttle)


func _execute_goto(_delta: float) -> void:
	# Single-axis control: roll the lift vector onto the target, then pull toward it.
	# Never roll and pitch at once, and only ever pitch up (pull). To reach a target
	# below, the bot banks/rolls so the lift points down and still pulls.
	var desired_direction := _get_safe_world_direction(_get_goto_desired_direction())
	var local_direction := _frame_inverse_basis * desired_direction
	var turn_angle := _get_local_turn_angle(local_direction)
	var throttle := _get_goto_throttle()

	var roll_input := 0.0
	var pitch_input := 0.0

	if turn_angle <= TURN_ANGLE_DEADBAND_RAD:
		# Already pointed at the target; hold attitude.
		_goto_pitching = true
	else:
		var lift_vector_error := atan2(local_direction.x, local_direction.y)
		_update_goto_phase(lift_vector_error)
		if _goto_pitching:
			# Pull toward the target. _proportional_pitch already returns nose-up
			# (negative) for a positive error; clamp guarantees we never push down.
			pitch_input = minf(_proportional_pitch(turn_angle), 0.0)
		else:
			# Roll so the lift vector (local up) points at the target, then we pitch.
			roll_input = _proportional_roll(-lift_vector_error)

	_apply_controls(roll_input, pitch_input, 0.0, throttle)


func _update_goto_phase(lift_vector_error: float) -> void:
	var misalignment := absf(lift_vector_error)
	if _goto_pitching:
		if misalignment > GOTO_ROLL_REALIGN_RAD:
			_goto_pitching = false
	elif misalignment <= GOTO_ROLL_ALIGN_RAD:
		_goto_pitching = true


func _get_goto_desired_direction() -> Vector3:
	if _has_follow_target():
		var target_point := _get_follow_destination_point()
		if _is_in_follow_killzone(target_point):
			return _get_follow_alignment_direction()

		return _get_follow_steering_point(target_point) - _frame_position

	if _altitude_target_active:
		return _get_altitude_seek_direction(_target_altitude)

	return _get_altitude_seek_direction(_frame_position.y)


func _get_altitude_seek_direction(target_altitude: float) -> Vector3:
	var heading := Vector3(_frame_forward_axis.x, 0.0, _frame_forward_axis.z)
	if heading.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		heading = Vector3.FORWARD
	else:
		heading = heading.normalized()

	# Climb toward a higher target; otherwise stay level (never command a descent).
	if target_altitude - _frame_position.y <= ALTITUDE_CAPTURE_TOLERANCE:
		return heading

	return (heading + Vector3.UP * GOTO_CLIMB_SLOPE).normalized()


func _get_goto_throttle() -> float:
	if _has_follow_target():
		return _get_follow_throttle_target(_get_follow_destination_point())

	return HALF_THROTTLE_INPUT


func _execute_finetrack(_delta: float) -> void:
	# TODO: precise close-in target tracking.
	pass


# ---------------------------------------------------------------------------
# Proportional control foundation. Each returns a control input proportional to
# the supplied error, clamped to the input limit. Not wired up yet -- the basis
# the executors above will be built on. Signs follow the plane's convention.
# ---------------------------------------------------------------------------
func _proportional_roll(roll_error: float) -> float:
	# roll_error is the bank error (target_bank - current_bank). Positive roll input
	# rolls left, which increases the bank, so the sign is direct.
	return clampf(roll_error * PROPORTIONAL_ROLL_GAIN, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT)


func _proportional_pitch(pitch_error: float) -> float:
	# pitch_error is positive when the nose must come up. Nose-up is negative input,
	# so the error is negated.
	return clampf(-pitch_error * PROPORTIONAL_PITCH_GAIN, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT)


func _apply_controls(roll_value: float, pitch_value: float, yaw_value: float, throttle_value: float) -> void:
	_plane.set_bot_control_inputs(
		clampf(roll_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT),
		clampf(pitch_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT),
		clampf(yaw_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT),
		clampf(throttle_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT)
	)


# ---------------------------------------------------------------------------
# Avoidance conditions (ground + forward terrain probing).
# ---------------------------------------------------------------------------
func _should_avoid_ground(clearance: float) -> bool:
	var min_clearance := maxf(min_ground_clearance, 0.0)
	if min_clearance <= 0.0:
		return false

	if _will_hit_terrain_ahead():
		return true

	if not is_finite(clearance):
		return false

	var descending_rate := _get_ground_closure_rate()
	if _mode == Mode.AVOIDANCE:
		var exit_clearance := min_clearance + maxf(ground_clearance_tolerance, 0.0)
		return clearance < exit_clearance or _will_hit_ground_soon(clearance, descending_rate)

	return clearance < min_clearance or _will_hit_ground_soon(clearance, descending_rate)


func _update_ground_clearance() -> void:
	if maxf(min_ground_clearance, 0.0) <= 0.0:
		_ground_clearance = INF
		_terrain_ahead_distance = INF
		return

	var now_seconds := Time.get_ticks_msec() / 1000.0
	if not _should_probe_ground(now_seconds):
		return

	_ground_clearance = _measure_ground_clearance()
	_terrain_ahead_distance = _measure_terrain_ahead()
	_next_ground_probe_time = now_seconds + _get_next_ground_probe_interval()


func _should_probe_ground(now_seconds: float) -> bool:
	if now_seconds >= _next_ground_probe_time:
		return true

	if _mode == Mode.AVOIDANCE:
		return true

	if not is_finite(_ground_clearance):
		return _has_fast_ground_closure() or _has_terrain_ahead_threat()

	return _is_ground_probe_urgent(_ground_clearance)


func _get_next_ground_probe_interval() -> float:
	if _mode == Mode.AVOIDANCE:
		return 0.0

	if not is_finite(_ground_clearance):
		return GROUND_PROBE_SAFE_INTERVAL

	if _is_ground_probe_urgent(_ground_clearance):
		return 0.0

	return GROUND_PROBE_SAFE_INTERVAL


func _is_ground_probe_urgent(clearance: float) -> bool:
	if _has_fast_ground_closure():
		return true

	if _has_terrain_ahead_threat():
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


func _will_hit_ground_soon(clearance: float, descending_rate: float) -> bool:
	if descending_rate <= 0.0:
		return false

	var lookahead := maxf(ground_avoidance_time_to_impact, 0.0)
	if lookahead <= 0.0:
		return false

	return clearance / descending_rate <= lookahead


func _get_ground_closure_rate() -> float:
	return maxf(-_frame_velocity.y, 0.0)


func _get_terrain_ahead_time_to_impact() -> float:
	if not is_finite(_terrain_ahead_distance) or _frame_speed <= 0.001:
		return INF

	return _terrain_ahead_distance / _frame_speed


func _will_hit_terrain_ahead() -> bool:
	var lookahead := maxf(ground_avoidance_time_to_impact, 0.0)
	if lookahead <= 0.0:
		return false

	# Hold the avoidance longer once engaged so the climb-out doesn't immediately
	# re-detect/release the obstacle and chatter the mode.
	if _mode == Mode.AVOIDANCE:
		lookahead *= GROUND_AVOIDANCE_TERRAIN_EXIT_FACTOR

	return _get_terrain_ahead_time_to_impact() <= lookahead


func _has_terrain_ahead_threat() -> bool:
	var lookahead := maxf(ground_avoidance_time_to_impact, 0.0)
	if lookahead <= 0.0:
		return false

	return _get_terrain_ahead_time_to_impact() <= lookahead * GROUND_PROBE_TERRAIN_URGENT_FACTOR


func _get_downward_flight_path_angle_deg() -> float:
	if _frame_speed <= 0.001:
		return 0.0

	return rad_to_deg(asin(clampf(-_frame_velocity.y / _frame_speed, 0.0, 1.0)))


# ---------------------------------------------------------------------------
# Speed-management conditions (too slow -> recover, too fast -> reduce).
# ---------------------------------------------------------------------------
func _should_recover_speed(forward_speed: float) -> bool:
	var min_speed := maxf(min_acceptable_forward_speed, 0.0)
	if min_speed <= 0.0:
		return false

	if _mode == Mode.SPEED_MANAGEMENT:
		return forward_speed < _get_recovery_exit_speed()

	return forward_speed < min_speed


func _should_reduce_speed(forward_speed: float) -> bool:
	var max_speed := max_acceptable_forward_speed
	if max_speed <= 0.0:
		return false

	if _mode == Mode.SPEED_MANAGEMENT:
		return forward_speed > _get_reduction_exit_speed()

	return forward_speed > max_speed


func _get_recovery_exit_speed() -> float:
	return maxf(reserve_forward_speed, min_acceptable_forward_speed)


func _get_reduction_exit_speed() -> float:
	return minf(speed_reduction_reserve_forward_speed, max_acceptable_forward_speed)


func _get_speed_recovery_ratio(forward_speed: float) -> float:
	# 0 at the recovery exit speed, 1 at (or below) the minimum acceptable speed.
	var min_speed := maxf(min_acceptable_forward_speed, 0.0)
	var exit_speed := _get_recovery_exit_speed()
	var speed_span := maxf(exit_speed - min_speed, 1.0)
	return clampf((exit_speed - forward_speed) / speed_span, 0.0, 1.0)


func _get_speed_reduction_ratio(forward_speed: float) -> float:
	# 0 at the reduction exit speed, 1 at (or above) the maximum acceptable speed.
	var max_speed := max_acceptable_forward_speed
	var exit_speed := _get_reduction_exit_speed()
	var speed_span := maxf(max_speed - exit_speed, 1.0)
	return clampf((forward_speed - exit_speed) / speed_span, 0.0, 1.0)


func _can_track_level(forward_speed: float) -> bool:
	return forward_speed >= maxf(min_acceptable_forward_speed, 0.0)


# ---------------------------------------------------------------------------
# Fine-track condition (close, well-aligned on the follow target).
# ---------------------------------------------------------------------------
func _should_fine_track(forward_speed: float) -> bool:
	if not _can_track_level(forward_speed):
		_fine_tracking_active = false
		return false

	if not _has_follow_target():
		_fine_tracking_active = false
		return false

	var desired_direction := _get_fine_track_desired_direction()
	var local_direction := _frame_inverse_basis * _get_safe_world_direction(desired_direction)
	var turn_angle := _get_local_turn_angle(local_direction)
	return _should_use_fine_tracking(local_direction, turn_angle)


func _get_fine_track_desired_direction() -> Vector3:
	var target_point := _get_follow_destination_point()
	if _is_in_follow_killzone(target_point):
		return _get_follow_alignment_direction()

	return _get_follow_steering_point(target_point) - _frame_position


func _should_use_fine_tracking(local_direction: Vector3, turn_angle: float) -> bool:
	var threshold := deg_to_rad(maxf(fine_tracking_angle_deg, 0.0))
	if threshold <= 0.0:
		_fine_tracking_active = false
		return false

	# Only fine-track a target ahead of the nose; large/rear angles still roll to turn.
	if -local_direction.z <= 0.0:
		_fine_tracking_active = false
		return false

	if _fine_tracking_active:
		if turn_angle < threshold + FINE_TRACKING_HYSTERESIS_RAD:
			return true

		_fine_tracking_active = false
		return false

	if turn_angle < threshold:
		_fine_tracking_active = true
		return true

	return false


# ---------------------------------------------------------------------------
# Shared geometry / engagement / sensing helpers used by the conditions.
# ---------------------------------------------------------------------------
func _get_safe_world_direction(direction: Vector3) -> Vector3:
	if direction.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return _frame_forward_axis

	return direction.normalized()


func _get_local_turn_angle(local_direction: Vector3) -> float:
	var forward_alignment := clampf(-local_direction.z, -1.0, 1.0)
	return acos(forward_alignment)


func _get_pitch_angle() -> float:
	# Nose elevation above the horizon (positive up).
	return asin(clampf(_frame_forward_axis.y, -1.0, 1.0))


func _get_current_bank() -> float:
	var local_world_up := _frame_inverse_basis * Vector3.UP
	return atan2(local_world_up.x, local_world_up.y)


func _wings_level_roll() -> float:
	# Roll back to wings level: drive the bank toward zero.
	return _proportional_roll(-_get_current_bank())


func _has_checkpoint() -> bool:
	return not checkpoints.is_empty()


func _get_clamped_checkpoint_index() -> int:
	if checkpoints.is_empty():
		return 0

	_checkpoint_index = clampi(_checkpoint_index, 0, checkpoints.size() - 1)
	return _checkpoint_index


func _update_collision_threat() -> void:
	_engagement.update_collision_threat()


func _update_follow_target_velocity(delta: float) -> void:
	_engagement.update_follow_target_velocity(delta)


func _has_follow_target() -> bool:
	return _engagement.has_follow_target()


func _get_follow_throttle_target(destination_point: Vector3) -> float:
	return _engagement.get_follow_throttle_target(destination_point)


func _get_follow_destination_point() -> Vector3:
	return _engagement.get_follow_destination_point()


func _is_in_follow_killzone(killzone_point: Vector3) -> bool:
	return _engagement.is_in_follow_killzone(killzone_point)


func _get_follow_alignment_direction() -> Vector3:
	return _engagement.get_follow_alignment_direction()


func _get_follow_steering_point(destination_point: Vector3) -> Vector3:
	return _engagement.get_follow_steering_point(destination_point)


func _update_weapon_targeting() -> void:
	_engagement.update_weapon_targeting()


func _get_forward_speed() -> float:
	return _frame_forward_speed


func _measure_ground_clearance() -> float:
	if _plane == null or not _plane.is_inside_tree():
		return INF

	var world_ref: World3D = _plane.get_world_3d()
	if world_ref == null:
		return INF

	var ray_distance: float = maxf(ground_probe_distance, min_ground_clearance)
	if ray_distance <= 0.0:
		return INF

	var from_point: Vector3 = _frame_position
	var to_point: Vector3 = from_point + Vector3.DOWN * ray_distance
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from_point, to_point)
	query.exclude = _get_ground_probe_exclusions()
	query.collide_with_areas = false

	var hit: Dictionary = world_ref.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return INF

	var hit_position: Vector3 = hit.get("position", to_point)
	return from_point.distance_to(hit_position)


func _measure_terrain_ahead() -> float:
	if _frame_speed <= 0.001:
		return INF

	return _probe_terrain_distance(_frame_velocity / _frame_speed, _get_terrain_probe_lookahead())


func _get_terrain_probe_lookahead() -> float:
	# Look ahead along the flight path far enough to react in time, bounded by the
	# configured probe budget.
	return clampf(
		_frame_speed * maxf(ground_avoidance_time_to_impact, 0.0),
		maxf(min_ground_clearance, 1.0),
		maxf(ground_probe_distance, min_ground_clearance)
	)


func _probe_terrain_distance(direction: Vector3, max_distance: float) -> float:
	if _plane == null or not _plane.is_inside_tree():
		return INF

	var world_ref: World3D = _plane.get_world_3d()
	if world_ref == null:
		return INF

	if max_distance <= 0.0 or direction.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return INF

	var from_point: Vector3 = _frame_position
	var to_point: Vector3 = from_point + direction.normalized() * max_distance
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from_point, to_point)
	query.exclude = _get_ground_probe_exclusions()
	query.collide_with_areas = false

	var hit: Dictionary = world_ref.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return INF

	var hit_position: Vector3 = hit.get("position", to_point)
	return from_point.distance_to(hit_position)


func _get_ground_probe_exclusions() -> Array[RID]:
	return _engagement.get_ground_probe_exclusions()
