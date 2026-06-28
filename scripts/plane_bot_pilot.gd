class_name PlaneBotPilot
extends Node

const BOT_DEBUG_RENDERER_SCRIPT := preload("res://scripts/bot_debug_renderer_3d.gd")
const PLANE_BOT_DEBUG_ADAPTER_SCRIPT := preload("res://scripts/plane_bot_debug_adapter.gd")
const PLANE_BOT_ENGAGEMENT_MODEL_SCRIPT := preload("res://scripts/plane_bot_engagement_model.gd")

enum FlightState {
	IDLE,
	SPEED_RECOVERY,
	SPEED_REDUCTION,
	ALTITUDE_HOLD,
	LEVEL_FLIGHT,
	GROUND_AVOIDANCE,
	COLLISION_AVOIDANCE,
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
const SPEED_REDUCTION_MIN_THROTTLE_INPUT := -1.0
const SPEED_REDUCTION_PITCH_RESPONSE_RATE := 0.16
const SPEED_REDUCTION_MAX_NOSE_UP_INPUT := 0.6
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
# Below this nose-to-target angle, blend the turn roll toward wings level so the
# bot rolls out of its bank as it aligns instead of holding bank and overshooting.
const TURN_ROLLOUT_ANGLE_RAD := PI / 4.0
# While the lift vector is not yet aimed toward the desired turn direction, keep
# only this fraction of the pitch pull so the bot rolls first instead of pulling
# in the wrong direction.
const TURN_MIN_UNALIGNED_PULL_RATIO := 0.25
# Max pitch authority the altitude-hold trim may add inside a bank-to-turn, so it
# cannot overpower the turn pull (see _get_turn_altitude_pitch_target).
const TURN_ALTITUDE_PITCH_LIMIT := 0.25
const CORRECTION_TURN_PITCH_DOWN_RATE := 0.47
const CORRECTION_TURN_MIN_LATERAL_ANGLE_RAD := 0.08
const CORRECTION_TURN_HYSTERESIS_RAD := 2.0 * PI / 180.0
const WINGS_LEVEL_DEADBAND_RAD := PI / 180.0
const MIN_DIRECTION_LENGTH_SQUARED := 0.000001
const GROUP_CACHE_REFRESH_INTERVAL := 0.25
const GROUND_PROBE_EXCLUSION_REFRESH_INTERVAL := 1.0
const GROUND_PROBE_SAFE_INTERVAL := 0.25
const GROUND_PROBE_NEAR_CLEARANCE_MULTIPLIER := 2.0
const GROUND_PROBE_FAST_CLOSURE_RATIO := 0.25
# Forward (flight-path) terrain probe: the down ray can't see a mountain or upslope
# the bot is flying level into, so also cast along the velocity vector.
const GROUND_PROBE_TERRAIN_URGENT_FACTOR := 2.0
const GROUND_AVOIDANCE_TERRAIN_EXIT_FACTOR := 1.5
# Escape candidates probed when terrain is ahead, as Vector2(yaw_deg, pitch_up_deg)
# relative to the horizontal flight heading. The bot steers toward whichever has the
# most open air, so it climbs over a shallow rise but turns away from a steep wall.
const GROUND_ESCAPE_CANDIDATES: Array[Vector2] = [
	Vector2(0.0, 30.0),
	Vector2(0.0, 55.0),
	Vector2(-40.0, 25.0),
	Vector2(40.0, 25.0),
	Vector2(-75.0, 15.0),
	Vector2(75.0, 15.0),
]
# Clearance (m) subtracted per degree of yaw so the bot prefers climbing/least turn
# when escape paths are similarly open.
const GROUND_ESCAPE_YAW_PENALTY := 1.5
const CONTROL_INPUT_LIMIT := 1.0
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

@export var min_acceptable_forward_speed: float = 50.0
@export var reserve_forward_speed: float = 70.0
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
@export var correction_turn_small_angle_deg: float = 6.0
@export var overshoot_closure_tolerance: float = 0.5
@export var overshoot_throttle_gain: float = 0.08
@export var killzone_distance: float = 250.0
@export var killzone_tolerance: float = 150.0
@export var autocannon_fire_max_range: float = 650.0
@export var hostile_aggro_radius: float = 1000.0
@export var hostile_aggro_threshold: float = 30.0
@export var hostile_aggro_gain_per_second: float = 1.0
@export var hostile_aggro_decay_per_second: float = 1.0
@export var avoid_missiles: bool = true
@export var debug_bot_visuals_enabled := true
# Throttled logging of the bank-to-turn pitch/roll command vs. orientation, to
# diagnose the "rolls lift vector on target then pitches down away from it" case.
@export var debug_turn_logging := false
@export var checkpoints: Array[Vector3] = [
	Vector3(0.0, 1500.0, 0.0),
]

var _plane: PlaneCharacter
var _altitude_target_active := false
var _target_altitude := 0.0
var _flight_state: int = FlightState.IDLE
var _roll_input := 0.0
var _pitch_input := 0.0
var _yaw_input := 0.0
var _throttle_input := 0.0
var _ground_clearance := INF
var _terrain_ahead_distance := INF
var _next_ground_probe_time := 0.0
var _checkpoint_index := 0
var _correction_turn_active := false
var _turn_log_cooldown := 0.0
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
	match _flight_state:
		FlightState.SPEED_RECOVERY:
			return "SPEED_RECOVERY"
		FlightState.SPEED_REDUCTION:
			return "SPEED_REDUCTION"
		FlightState.ALTITUDE_HOLD:
			return "ALTITUDE_HOLD"
		FlightState.LEVEL_FLIGHT:
			return "LEVEL_FLIGHT"
		FlightState.GROUND_AVOIDANCE:
			return "GROUND_AVOIDANCE"
		FlightState.COLLISION_AVOIDANCE:
			return "COLLISION_AVOIDANCE"
		FlightState.FOLLOW_TARGET:
			return "FOLLOW_TARGET"
		_:
			return "IDLE"


func get_engagement_debug_snapshot() -> Dictionary:
	return _engagement.get_debug_snapshot()


func get_follow_target_debug_label() -> String:
	return _engagement.get_follow_target_debug_label()


func get_highest_aggro_debug_label() -> String:
	return _engagement.get_highest_aggro_debug_label()


func _update_flight_controls(delta: float) -> void:
	var forward_speed := _get_forward_speed()
	_update_collision_threat()
	_flight_state = _select_flight_state(forward_speed)

	match _flight_state:
		FlightState.GROUND_AVOIDANCE:
			avoid_ground(delta)
		FlightState.COLLISION_AVOIDANCE:
			_update_collision_avoidance_controls(delta)
		FlightState.SPEED_RECOVERY:
			_update_speed_recovery_controls(delta, forward_speed)
		FlightState.SPEED_REDUCTION:
			_update_speed_reduction_controls(delta, forward_speed)
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

	if _engagement.get_collision_avoidance_direction() != 0.0:
		return FlightState.COLLISION_AVOIDANCE

	if _should_recover_speed(forward_speed):
		return FlightState.SPEED_RECOVERY

	if _should_reduce_speed(forward_speed):
		return FlightState.SPEED_REDUCTION

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
	# Terrain in the flight path: steer toward the most open escape direction
	# (climb, or turn away when a pure pull-up can't clear the rise). A descent
	# toward ground below with nothing ahead falls through to the nose-up pull.
	if _will_hit_terrain_ahead():
		turn_toward_direction(
			delta,
			_get_terrain_escape_direction(),
			INF,
			SPEED_RECOVERY_FULL_THROTTLE_INPUT,
			GROUND_AVOIDANCE_PITCH_RESPONSE_RATE
		)
		return

	_apply_pitch_behavior(
		delta,
		_get_ground_avoidance_pitch_target(),
		GROUND_AVOIDANCE_PITCH_RESPONSE_RATE,
		SPEED_RECOVERY_FULL_THROTTLE_INPUT
	)


func _update_collision_avoidance_controls(delta: float) -> void:
	var local_world_up := _frame_inverse_basis * Vector3.UP
	var current_bank := atan2(local_world_up.x, local_world_up.y)
	var target_bank: float = _engagement.get_collision_avoidance_direction() * deg_to_rad(COLLISION_AVOIDANCE_BANK_DEG)
	var bank_error: float = target_bank - current_bank
	var roll_target := _get_roll_input_for_error(bank_error, WINGS_LEVEL_ROLL_GAIN)
	_apply_control_behavior(
		delta,
		roll_target,
		-CONTROL_INPUT_LIMIT,
		0.0,
		COLLISION_AVOIDANCE_RESPONSE_RATE,
		SPEED_RECOVERY_FULL_THROTTLE_INPUT
	)


func _update_speed_recovery_controls(delta: float, forward_speed: float) -> void:
	var recovery_direction := _get_speed_recovery_direction(forward_speed)
	_apply_control_behavior(
		delta,
		_get_speed_recovery_roll_target(forward_speed),
		_get_speed_recovery_pitch_target(recovery_direction),
		0.0,
		SPEED_RECOVERY_PITCH_RESPONSE_RATE,
		SPEED_RECOVERY_FULL_THROTTLE_INPUT
	)


func _update_speed_reduction_controls(delta: float, forward_speed: float) -> void:
	var reduction_ratio := _get_speed_reduction_ratio(forward_speed)
	# Mirror of SPEED_RECOVERY: cut throttle and pitch up proportionally to the
	# overspeed so the climb bleeds airspeed via gravity and induced drag instead
	# of waiting on throttle alone.
	var throttle_target := lerpf(HALF_THROTTLE_INPUT, SPEED_REDUCTION_MIN_THROTTLE_INPUT, reduction_ratio)
	# Negative pitch input is nose-up (see _get_ground_avoidance_pitch_target).
	var pitch_up_target := -reduction_ratio * SPEED_REDUCTION_MAX_NOSE_UP_INPUT
	_apply_pitch_behavior(
		delta,
		pitch_up_target,
		SPEED_REDUCTION_PITCH_RESPONSE_RATE,
		throttle_target
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

	var desired_direction: Vector3
	var target_altitude: float
	if _is_in_follow_killzone(target_point):
		desired_direction = _get_follow_alignment_direction()
		target_altitude = target_point.y
	else:
		var steering_point := _get_follow_steering_point(target_point)
		desired_direction = steering_point - _frame_position
		target_altitude = steering_point.y

	turn_toward_direction(
		delta,
		desired_direction,
		target_altitude,
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
		_apply_correction_turn(delta, local_direction, turn_angle, target_altitude, throttle_target, response_rate)
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
	var pitch_target := _get_lift_aligned_pitch_target(turn_angle, target_altitude, local_direction)
	_log_turn_command(delta, local_direction, turn_angle, target_altitude, roll_target, pitch_target)
	_apply_control_behavior(
		delta,
		roll_target,
		pitch_target,
		0.0,
		response_rate,
		throttle_target
	)


func _apply_correction_turn(
	delta: float,
	local_direction: Vector3,
	turn_angle: float,
	target_altitude: float,
	throttle_target: float,
	response_rate: float
) -> void:
	var roll_target := _get_lift_vector_roll_target(local_direction, turn_angle)
	var pitch_target := _get_lift_aligned_pitch_target(turn_angle, target_altitude, local_direction)
	_log_turn_command(delta, local_direction, turn_angle, target_altitude, roll_target, pitch_target)
	_apply_control_behavior(
		delta,
		roll_target,
		pitch_target,
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

	if _will_hit_terrain_ahead():
		return true

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

	if _flight_state == FlightState.GROUND_AVOIDANCE:
		return true

	if not is_finite(_ground_clearance):
		return _has_fast_ground_closure() or _has_terrain_ahead_threat()

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
	var terrain_ahead_urgency := _get_terrain_ahead_urgency()
	var urgency := maxf(
		maxf(clearance_urgency, closure_urgency),
		maxf(dive_angle_urgency, terrain_ahead_urgency)
	)
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


func _get_terrain_ahead_time_to_impact() -> float:
	if not is_finite(_terrain_ahead_distance) or _frame_speed <= 0.001:
		return INF

	return _terrain_ahead_distance / _frame_speed


func _will_hit_terrain_ahead() -> bool:
	var lookahead := maxf(ground_avoidance_time_to_impact, 0.0)
	if lookahead <= 0.0:
		return false

	# Hold the avoidance longer once engaged so the climb-out doesn't immediately
	# re-detect/release the obstacle and chatter the state.
	if _flight_state == FlightState.GROUND_AVOIDANCE:
		lookahead *= GROUND_AVOIDANCE_TERRAIN_EXIT_FACTOR

	return _get_terrain_ahead_time_to_impact() <= lookahead


func _has_terrain_ahead_threat() -> bool:
	var lookahead := maxf(ground_avoidance_time_to_impact, 0.0)
	if lookahead <= 0.0:
		return false

	return _get_terrain_ahead_time_to_impact() <= lookahead * GROUND_PROBE_TERRAIN_URGENT_FACTOR


func _get_terrain_ahead_urgency() -> float:
	var lookahead := maxf(ground_avoidance_time_to_impact, 0.0)
	if lookahead <= 0.0:
		return 0.0

	var time_to_impact := _get_terrain_ahead_time_to_impact()
	if not is_finite(time_to_impact):
		return 0.0

	return clampf(1.0 - time_to_impact / lookahead, 0.0, 1.0)


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


func _should_reduce_speed(forward_speed: float) -> bool:
	var max_speed := max_acceptable_forward_speed
	if max_speed <= 0.0:
		return false

	if _flight_state == FlightState.SPEED_REDUCTION:
		return forward_speed > _get_reduction_exit_speed()

	return forward_speed > max_speed


func _get_reduction_exit_speed() -> float:
	return minf(speed_reduction_reserve_forward_speed, max_acceptable_forward_speed)


func _get_speed_reduction_ratio(forward_speed: float) -> float:
	var max_speed := max_acceptable_forward_speed
	var exit_speed := _get_reduction_exit_speed()
	var speed_span := maxf(max_speed - exit_speed, 1.0)
	return clampf((forward_speed - exit_speed) / speed_span, 0.0, 1.0)


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
	var lift_vector_roll := _get_roll_input_for_error(lift_vector_error, LEVEL_TURN_ROLL_GAIN, turn_ratio)

	# As the nose closes onto the target, roll out to wings level instead of holding
	# the bank. Scaling only the roll rate (turn_ratio) toward zero makes the bot coast
	# at its current bank while it keeps pulling, curving the nose past the target
	# (slalom). Blend toward the wings-level target over the final approach so the lift
	# vector comes upright as the pull relaxes.
	var rollout := 1.0 - clampf(turn_angle / TURN_ROLLOUT_ANGLE_RAD, 0.0, 1.0)
	if rollout <= 0.0:
		return lift_vector_roll

	return lerpf(lift_vector_roll, _get_wings_level_roll_target(), rollout)


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
	return _plane.get_roll_input_for_error(
		roll_error,
		angle_to_rate_gain,
		ROLL_MAX_DESIRED_RATE,
		ROLL_RATE_RESPONSE_GAIN,
		rate_scale
	)


func _get_local_roll_rate() -> float:
	return _get_local_angular_velocity().z


func _get_pitch_input_for_error(pitch_error: float) -> float:
	return _plane.get_rate_stabilized_axis_input(
		pitch_error,
		SPEED_RECOVERY_PITCH_ANGLE_TO_RATE_GAIN,
		SPEED_RECOVERY_MAX_DESIRED_PITCH_RATE,
		_get_local_pitch_rate(),
		SPEED_RECOVERY_PITCH_RATE_RESPONSE_GAIN,
		1.0,
		-1.0
	)


func _get_local_pitch_rate() -> float:
	return _get_local_angular_velocity().x


func _get_local_angular_velocity() -> Vector3:
	return _frame_local_angular_velocity


func _get_turn_pitch_target(turn_angle: float, target_altitude: float) -> float:
	return _get_turn_pull_pitch_target(turn_angle) + _get_turn_altitude_pitch_target(target_altitude)


# How well the current lift vector (local +Y) points toward the desired turn
# direction. 1.0 means pull normally; 0.0 means the target is sideways (roll
# first); below the lift vector clamps to 0.0 so the bot does not pull into the
# wrong turn. Uses raw local_direction, independent of the roll rollout blend.
func _get_lift_alignment_factor(local_direction: Vector3) -> float:
	var transverse_length := sqrt(
		local_direction.x * local_direction.x +
		local_direction.y * local_direction.y
	)

	if transverse_length <= MIN_DIRECTION_LENGTH_SQUARED:
		return 1.0

	return clampf(local_direction.y / transverse_length, 0.0, 1.0)


func _get_lift_aligned_pitch_target(turn_angle: float, target_altitude: float, local_direction: Vector3) -> float:
	var pitch_target := _get_turn_pitch_target(turn_angle, target_altitude)
	var lift_alignment := _get_lift_alignment_factor(local_direction)
	var curved_alignment := lift_alignment * lift_alignment
	var pitch_scale := lerpf(TURN_MIN_UNALIGNED_PULL_RATIO, 1.0, curved_alignment)

	return pitch_target * pitch_scale


# Throttled diagnostic: fires only while hard-banked (>60 deg) so we can see
# what the bank-to-turn controller commands vs. the plane's actual orientation
# during the "pitch down away from target" case. Sign: pitch<0 nose-up, >0 nose-down.
func _log_turn_command(
	delta: float,
	local_direction: Vector3,
	turn_angle: float,
	target_altitude: float,
	roll_target: float,
	pitch_target: float
) -> void:
	if not debug_turn_logging:
		return

	var local_world_up := _frame_inverse_basis * Vector3.UP
	var bank := atan2(local_world_up.x, local_world_up.y)
	if absf(bank) < deg_to_rad(60.0):
		return

	_turn_log_cooldown -= delta
	if _turn_log_cooldown > 0.0:
		return
	_turn_log_cooldown = 0.2

	var commanded_roll_err := atan2(local_direction.x, local_direction.y)
	var alignment := _get_lift_alignment_factor(local_direction)
	var pull_term := _get_turn_pull_pitch_target(turn_angle)
	var altitude_term := _get_turn_altitude_pitch_target(target_altitude)
	print(
		"[turn] bank=%+.0f inv=%s | local_dir=(%+.2f,%+.2f,%+.2f) turn=%.0f" % [
			rad_to_deg(bank),
			str(local_world_up.y < 0.0),
			local_direction.x, local_direction.y, local_direction.z,
			rad_to_deg(turn_angle),
		]
		+ " | align=%.2f roll_cmd=%+.0f roll_out=%+.2f | pull=%+.3f alt=%+.3f pitch=%+.3f" % [
			alignment,
			rad_to_deg(commanded_roll_err),
			roll_target,
			pull_term,
			altitude_term,
			pitch_target,
		]
	)


func _get_turn_pull_pitch_target(turn_angle: float) -> float:
	if turn_angle <= TURN_MIN_PULL_ANGLE_RAD:
		return 0.0

	return _plane.get_rate_stabilized_axis_input(
		turn_angle,
		TURN_PITCH_ANGLE_TO_RATE_GAIN,
		TURN_MAX_DESIRED_PITCH_RATE,
		_get_local_pitch_rate(),
		TURN_PITCH_RATE_RESPONSE_GAIN,
		1.0,
		-1.0
	)


func _get_turn_altitude_pitch_target(target_altitude: float) -> float:
	if target_altitude >= INF:
		return 0.0

	# During a bank-to-turn the pull must own the pitch axis. Altitude hold is
	# allowed only a small trim authority; otherwise the vertical-speed term
	# (e.g. arresting a zoom-climb that left a large climb rate) saturates nose-down
	# and overwhelms the pull, so the bot pitches away from the target until the
	# climb bleeds off.
	return clampf(
		_get_altitude_pitch_target(target_altitude),
		-TURN_ALTITUDE_PITCH_LIMIT,
		TURN_ALTITUDE_PITCH_LIMIT
	)


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


func _update_weapon_targeting() -> void:
	_engagement.update_weapon_targeting()


func _apply_controls(roll_value: float, pitch_value: float, yaw_value: float, throttle_value: float) -> void:
	_throttle_input = clampf(throttle_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT)
	_plane.set_bot_control_inputs(
		clampf(roll_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT),
		clampf(pitch_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT),
		clampf(yaw_value, -CONTROL_INPUT_LIMIT, CONTROL_INPUT_LIMIT),
		_throttle_input
	)


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


func _get_terrain_escape_direction() -> Vector3:
	var heading := _get_escape_heading()
	var lookahead := _get_terrain_probe_lookahead()
	var best_direction := _build_escape_candidate(heading, 0.0, 55.0)
	var best_score := -INF

	# Pick the candidate with the most open air, penalizing yaw so the bot climbs
	# straight ahead when that path is clear and only turns away when it isn't.
	for candidate in GROUND_ESCAPE_CANDIDATES:
		var direction := _build_escape_candidate(heading, candidate.x, candidate.y)
		var clearance := _probe_terrain_distance(direction, lookahead)
		var clear_value: float = lookahead if not is_finite(clearance) else clearance
		var score := clear_value - GROUND_ESCAPE_YAW_PENALTY * absf(candidate.x)
		if score > best_score:
			best_score = score
			best_direction = direction

	return best_direction


func _get_escape_heading() -> Vector3:
	var heading := Vector3(_frame_velocity.x, 0.0, _frame_velocity.z)
	if heading.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return _get_horizontal_forward_axis()

	return heading.normalized()


func _build_escape_candidate(horizontal_heading: Vector3, yaw_deg: float, pitch_up_deg: float) -> Vector3:
	var yawed := horizontal_heading.rotated(Vector3.UP, deg_to_rad(yaw_deg))
	var pitch_rad := deg_to_rad(pitch_up_deg)
	return (yawed * cos(pitch_rad) + Vector3.UP * sin(pitch_rad)).normalized()


func _get_ground_probe_exclusions() -> Array[RID]:
	return _engagement.get_ground_probe_exclusions()
