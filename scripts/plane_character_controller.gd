extends RigidBody3D

signal local_state_changed(peer_id: int, snapshot: Dictionary)

const AERO_TABLES_STORE := preload("res://scripts/plane_aero_tables_store.gd")
const FORCE_DEBUG_RENDERER_SCRIPT := preload("res://scripts/force_debug_renderer_3d.gd")

@export var rot_rate: float = 2.4
@export var rot_decay: float = 3.0
@export var thr_rate: float = 1.2
@export var relative_roll_cursor_speed: float = 2.0
@export var relative_roll_max_error_deg: float = 180.0
@export var relative_roll_error_to_rate_gain: float = 1.4
@export var relative_roll_max_desired_rate: float = 2.0
@export var relative_roll_rate_response_gain: float = 0.8
@export var relative_roll_deadband_deg: float = 1.0
@export var relative_roll_rate_deadband: float = 0.03

@export var max_thrust: float = 14_000.0
@export var max_pitch: float = 1.0
@export var max_yaw: float = 0.5
@export var max_roll: float = 2.5
@export var base_control_torque: float = 32_000.0
@export var max_lift_turn_limiter_enabled: bool = true
@export var max_lift_turn_limiter_min_airspeed: float = 5.0
@export var max_lift_turn_limiter_fade_deg: float = 10.0
@export var sustain_turn_limiter_enabled: bool = true
@export var sustain_turn_limiter_min_target_airspeed: float = 100.0
@export var sustain_turn_limiter_fade_deg: float = 10.0
@export var sustain_turn_limiter_samples: int = 48
@export var sustain_turn_limiter_drag_margin: float = 1.05
@export var sustain_turn_vy_enabled: bool = true
@export var sustain_turn_vy_update_interval: float = 0.25
@export var sustain_turn_vy_sample_min_speed: float = 10.0
@export var sustain_turn_vy_sample_max_speed: float = 250.0
@export var sustain_turn_vy_sample_count: int = 64
@export var sustain_turn_vy_max_load_factor: float = 4.0
# Vy speed-margin limiter: when altitude is rising, pitch authority fades to zero
# over this speed band as airspeed drops from (Vy + margin) down to Vy.
@export var sustain_turn_vy_margin_speed: float = 20.0
# Hysteresis dead-band (m/s) around zero world-vertical-speed for the climb switch.
@export var sustain_turn_vy_climb_speed_threshold: float = 0.5
# Min world-vertical pull intent (-pitch * up.y) to engage the Vy gate on a climb
# entry before altitude has started rising.
@export var sustain_turn_vy_min_vertical_pull_intent: float = 0.1

@export var air_density: float = 1.225
@export var reference_area: float = 12.0
@export var ambient_wind_velocity_world: Vector3 = Vector3.ZERO
@export var lift_coefficient_table: Array[Vector2] = [
	Vector2(-27.63, -0.1506),
	Vector2(-20.13, -0.9907),
	Vector2(-10.18, -0.7980),
	Vector2(-5.06, -0.3982),
	Vector2(0.0, 0.0),
	Vector2(4.98, 0.3937),
	Vector2(9.94, 0.7979),
	Vector2(14.98, 1.1985),
	Vector2(19.88, 1.6027),
	Vector2(24.06, 1.3809),
	Vector2(29.73, 0.1696),
]
@export var drag_coefficient_table: Array[Vector2] = [
	Vector2(-29.83, 0.5989),
	Vector2(-25.42, 0.3963),
	Vector2(-21.38, 0.2701),
	Vector2(-15.0, 0.1171),
	Vector2(-10.04, 0.0495),
	Vector2(-5.13, 0.0212),
	Vector2(0.17, 0.0027),
	Vector2(4.96, 0.0207),
	Vector2(10.03, 0.0500),
	Vector2(14.99, 0.1171),
	Vector2(20.22, 0.2487),
	Vector2(25.01, 0.3989),
	Vector2(29.91, 0.6010),
]
@export var side_force_coefficient_table: Array[Vector2] = [
	Vector2(-40.0, 0.0),
	Vector2(0.0, 0.0),
	Vector2(40.0, 0.0),
]
@export var control_authority_coefficient_table: Array[Vector2] = [
	Vector2(0.77, 0.5008),
	Vector2(24.32, 0.7643),
	Vector2(65.02, 0.9982),
	Vector2(114.65, 1.0037),
	Vector2(152.36, 0.7573),
	Vector2(175.44, 0.4232),
	Vector2(200.45, 0.2607),
	Vector2(250.47, 0.1438),
	Vector2(500.67, 0.0689),
]
@export var thrust_coefficient_table: Array[Vector2] = [
	Vector2(0.0, 1.0),
	Vector2(22.30, 0.8621),
	Vector2(38.64, 0.7771),
	Vector2(55.66, 0.6795),
	Vector2(73.29, 0.5910),
	Vector2(97.13, 0.4855),
	Vector2(124.82, 0.3779),
	Vector2(158.05, 0.2854),
	Vector2(202.43, 0.1934),
	Vector2(391.29, 0.0411),
]
@export var alignment_strength: float = 400.0
@export var alignment_max_torque: float = 10_000.0
@export var extra_linear_drag_linear_coefficient: float = 0.0
@export var extra_linear_drag_quadratic_coefficient: float = 0.16
@export var extra_angular_drag_linear_coefficients: Vector3 = Vector3(20000.0, 12000.0, 20000.0)
@export var extra_angular_drag_quadratic_coefficients: Vector3 = Vector3(2500.0, 1200.0, 2500.0)
@export var network_sync_interval: float = 0.033
@export var debug_force_vectors_enabled: bool = true

const TABLE_SORT_EPSILON := 0.0001
const MIN_AERODYNAMIC_SPEED_SQUARED := 0.0001
const MIN_DIRECTION_VECTOR_LENGTH_SQUARED := 0.000001
const MIN_ANGULAR_SPEED_SQUARED := 0.000001
const DEBUG_COLOR_THRUST := Color(1.0, 0.58, 0.12, 1.0)
const DEBUG_COLOR_LIFT := Color(0.2, 0.9, 0.2, 1.0)
const DEBUG_COLOR_DRAG := Color(0.95, 0.23, 0.23, 1.0)
const DEBUG_COLOR_GRAVITY := Color(0.35, 0.55, 1.0, 1.0)
const DEBUG_COLOR_DAMPING := Color(0.8, 0.8, 0.8, 1.0)
const DEBUG_COLOR_ROLL_FORCE := Color(0.97, 0.35, 0.95, 1.0)
const DEBUG_COLOR_PITCH_YAW_FORCE := Color(0.1, 0.95, 0.95, 1.0)
const DEBUG_COLOR_ALIGNMENT_TORQUE := Color(1.0, 0.95, 0.3, 1.0)
const REMOTE_INTERPOLATION_DELAY := 0.1
const REMOTE_MAX_SNAPSHOTS := 4

@export var flame_trail_scene: PackedScene

var peer_id := 1
var is_local_player := false
var is_bot_controlled := false
var is_shot_down := false

var roll_input := 0.0
var pitch_input := 0.0
var yaw_input := 0.0
var throttle_input := 0.0

var relative_roll_target_up_world := Vector3.UP
var relative_roll_target_active := false
var relative_roll_error := 0.0
var relative_roll_input := 0.0

var _bot_target_roll_input := 0.0
var _bot_target_pitch_input := 0.0
var _bot_target_yaw_input := 0.0
var _bot_target_throttle_input := -1.0

var aoa_deg := 0.0
var sideslip_deg := 0.0
var throttle_percent := 0.0

var _sync_timer := 0.0
var _force_debug_renderer: Node
var _last_total_linear_damp := 0.0
var _debug_last_thrust_force_world := Vector3.ZERO
var _debug_last_lift_force_world := Vector3.ZERO
var _debug_last_drag_force_world := Vector3.ZERO
var _debug_last_side_force_world := Vector3.ZERO
var _debug_last_gravity_force_world := Vector3.ZERO
var _debug_last_damping_force_world := Vector3.ZERO
var _frame_body_basis := Basis.IDENTITY
var _frame_forward_axis := Vector3.FORWARD
var _frame_right_axis := Vector3.RIGHT
var _frame_up_axis := Vector3.UP
var _frame_air_velocity_world := Vector3.ZERO
var _frame_air_velocity_local := Vector3.ZERO
var _frame_air_speed_squared := 0.0
var _frame_air_speed := 0.0
var _frame_airflow_direction := Vector3.ZERO
var _frame_dynamic_pressure := 0.0
var _positive_max_lift_aoa_deg := 15.0
var _negative_max_lift_aoa_deg := -15.0
var _sustain_turn_limiter_runtime_enabled := true
var _best_climb_speed_vy := 0.0
var _best_climb_speed_vy_valid := false
var _sustain_turn_vy_update_timer := 0.0
var _sustain_turn_using_vy := false
var _altitude_rising := false
var _flame_trail: Node3D
var _snapshot_tick: int = 0
var _remote_snapshots: Array[Dictionary] = []


func _ready() -> void:
	add_to_group("player_character")
	_apply_spawn_control_defaults()
	_sanitize_aero_tables()
	_apply_persisted_aero_tables()
	_ensure_force_debug_renderer()
	_apply_local_player_mode()
	var health := get_node_or_null("Health")
	if health != null:
		health.shot_down.connect(_on_shot_down)


func configure(new_peer_id: int, local_player: bool) -> void:
	var was_local_player := is_local_player
	peer_id = new_peer_id
	is_local_player = local_player

	if is_node_ready():
		if is_local_player and not was_local_player:
			_apply_spawn_control_defaults()
		_apply_local_player_mode()


func _physics_process(delta: float) -> void:
	if not _is_simulated_locally():
		_clear_force_debug_frame()
		return

	if is_shot_down:
		_clear_force_debug_frame()
		_sync_timer += delta
		if _sync_timer >= max(network_sync_interval, 0.001):
			_sync_timer = 0.0
			_emit_local_state()
		return

	_begin_force_debug_frame()
	_update_physics_frame_cache()
	_update_altitude_rising_state()
	_update_best_climb_speed_vy(delta)

	if is_bot_controlled:
		_apply_bot_inputs(delta)
	else:
		_collect_inputs(delta)
	compute_control_state(delta)
	apply_thrust()
	apply_plane_torque()
	apply_aerodynamic_forces()
	apply_extra_drag_forces()
	apply_directional_alignment()
	_end_force_debug_frame()

	_sync_timer += delta
	if _sync_timer >= max(network_sync_interval, 0.001):
		_sync_timer = 0.0
		_emit_local_state()


func _process(_delta: float) -> void:
	if _is_simulated_locally():
		return

	_update_remote_interpolation()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	_last_total_linear_damp = maxf(state.total_linear_damp, 0.0)


func _is_simulated_locally() -> bool:
	return is_local_player or is_bot_controlled


func _update_physics_frame_cache() -> void:
	_frame_body_basis = global_transform.basis.orthonormalized()
	_frame_forward_axis = -_frame_body_basis.z
	_frame_right_axis = _frame_body_basis.x
	_frame_up_axis = _frame_body_basis.y

	_frame_air_velocity_world = _get_air_relative_velocity_world()
	_frame_air_speed_squared = _frame_air_velocity_world.length_squared()
	_frame_air_speed = 0.0
	_frame_airflow_direction = Vector3.ZERO
	if _frame_air_speed_squared >= MIN_AERODYNAMIC_SPEED_SQUARED:
		_frame_air_speed = sqrt(_frame_air_speed_squared)
		if _frame_air_speed > 0.0:
			_frame_airflow_direction = _frame_air_velocity_world / _frame_air_speed

	_frame_air_velocity_local = _frame_body_basis.transposed() * _frame_air_velocity_world
	_frame_dynamic_pressure = 0.5 * air_density * _frame_air_speed_squared


func _update_altitude_rising_state() -> void:
	var climb_speed_threshold := maxf(sustain_turn_vy_climb_speed_threshold, 0.0)
	var world_vertical_speed := linear_velocity.y

	if climb_speed_threshold <= 0.0001:
		_altitude_rising = world_vertical_speed > 0.0
		return

	if world_vertical_speed > climb_speed_threshold:
		_altitude_rising = true
	elif world_vertical_speed < -climb_speed_threshold:
		_altitude_rising = false


func _apply_spawn_control_defaults() -> void:
	roll_input = 0.0
	pitch_input = 0.0
	yaw_input = 0.0
	throttle_input = 0.0
	throttle_percent = 50.0
	relative_roll_target_active = false
	relative_roll_target_up_world = Vector3.UP
	relative_roll_error = 0.0
	relative_roll_input = 0.0


func _apply_bot_inputs(delta: float) -> void:
	var rotation_step := maxf(rot_rate * delta, 0.0)
	var throttle_step := maxf(thr_rate * delta, 0.0)

	roll_input = move_toward(roll_input, _bot_target_roll_input, rotation_step)
	pitch_input = move_toward(pitch_input, _bot_target_pitch_input, rotation_step)
	yaw_input = move_toward(yaw_input, _bot_target_yaw_input, rotation_step)
	throttle_input = move_toward(throttle_input, _bot_target_throttle_input, throttle_step)

	roll_input = clampf(roll_input, -1.0, 1.0)
	pitch_input = clampf(pitch_input, -1.0, 1.0)
	yaw_input = clampf(yaw_input, -1.0, 1.0)
	throttle_input = clampf(throttle_input, -1.0, 1.0)

	throttle_percent = ((throttle_input + 1.0) * 0.5) * 100.0


func _collect_inputs(delta: float) -> void:
	var rotation_rate := rot_rate * delta
	var rotation_decay := rot_decay * delta

	_collect_roll_input(delta, rotation_rate, rotation_decay)

	var keyboard_pitch := 0.0
	keyboard_pitch += Input.get_action_strength("pitch_up")
	keyboard_pitch -= Input.get_action_strength("pitch_down")

	var keyboard_yaw := 0.0
	keyboard_yaw += Input.get_action_strength("yaw_left")
	keyboard_yaw -= Input.get_action_strength("yaw_right")

	var desired_pitch: float = clampf(keyboard_pitch, -1.0, 1.0)
	var desired_yaw: float = clampf(keyboard_yaw, -1.0, 1.0)

	if absf(desired_pitch) > 0.001:
		pitch_input = move_toward(pitch_input, desired_pitch, rotation_rate)
	else:
		pitch_input = move_toward(pitch_input, 0.0, rotation_decay)

	if absf(desired_yaw) > 0.001:
		yaw_input = move_toward(yaw_input, desired_yaw, rotation_rate)
	else:
		yaw_input = move_toward(yaw_input, 0.0, rotation_decay)

	pitch_input = clamp(pitch_input, -1.0, 1.0)
	yaw_input = clamp(yaw_input, -1.0, 1.0)

	var throttle_rate := thr_rate * delta
	if Input.is_action_pressed("throttle_up"):
		throttle_input += throttle_rate
	if Input.is_action_pressed("throttle_down"):
		throttle_input -= throttle_rate
	throttle_input = clamp(throttle_input, -1.0, 1.0)

	throttle_percent = ((throttle_input + 1.0) * 0.5) * 100.0


func _collect_roll_input(delta: float, rotation_rate: float, rotation_decay: float) -> void:
	var direct_roll_direction := _get_direct_roll_direction()
	var relative_roll_direction := _get_relative_roll_direction()

	if absf(direct_roll_direction) > 0.001:
		_reset_relative_roll_target()
		relative_roll_input = move_toward(relative_roll_input, 0.0, rotation_decay)
		roll_input = move_toward(roll_input, direct_roll_direction, rotation_rate)
		roll_input = clampf(roll_input, -1.0, 1.0)
		return

	_update_relative_roll_target(delta, relative_roll_direction)

	if relative_roll_target_active:
		var target_roll_input := get_roll_input_for_error(
			relative_roll_error,
			relative_roll_error_to_rate_gain,
			relative_roll_max_desired_rate,
			relative_roll_rate_response_gain
		)

		relative_roll_input = move_toward(relative_roll_input, target_roll_input, rotation_rate)
		roll_input = clampf(relative_roll_input, -1.0, 1.0)

		if _is_relative_roll_settled() and absf(relative_roll_direction) <= 0.001:
			_reset_relative_roll_target()

		return

	relative_roll_input = move_toward(relative_roll_input, 0.0, rotation_decay)
	roll_input = move_toward(roll_input, 0.0, rotation_decay)
	roll_input = clampf(roll_input, -1.0, 1.0)


func _get_direct_roll_direction() -> float:
	var direction := 0.0

	direction += Input.get_action_strength("roll_left")
	direction -= Input.get_action_strength("roll_right")

	return clampf(direction, -1.0, 1.0)


func _get_relative_roll_direction() -> float:
	var direction := 0.0

	direction -= Input.get_action_strength("relative_roll_left")
	direction += Input.get_action_strength("relative_roll_right")

	return clampf(direction, -1.0, 1.0)


func _update_relative_roll_target(delta: float, input_direction: float) -> void:
	if not relative_roll_target_active:
		relative_roll_target_up_world = _frame_up_axis
		relative_roll_error = 0.0

	if absf(input_direction) > 0.001:
		relative_roll_target_active = true
		var cursor_angle_step := input_direction * relative_roll_cursor_speed * delta
		relative_roll_target_up_world = relative_roll_target_up_world.rotated(
			_frame_forward_axis,
			cursor_angle_step
		).normalized()

	if not relative_roll_target_active:
		return

	_update_relative_roll_error()


func _update_relative_roll_error() -> void:
	var target_up := relative_roll_target_up_world
	target_up -= _frame_forward_axis * target_up.dot(_frame_forward_axis)

	if target_up.length_squared() <= MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		_reset_relative_roll_target()
		return

	target_up = target_up.normalized()

	relative_roll_error = atan2(
		target_up.dot(_frame_right_axis),
		target_up.dot(_frame_up_axis)
	)

	var max_error := deg_to_rad(maxf(relative_roll_max_error_deg, 1.0))
	relative_roll_error = clampf(relative_roll_error, -max_error, max_error)

	relative_roll_target_up_world = _frame_up_axis.rotated(
		_frame_forward_axis,
		relative_roll_error
	).normalized()


func _reset_relative_roll_target() -> void:
	relative_roll_target_active = false
	relative_roll_target_up_world = _frame_up_axis
	relative_roll_error = 0.0
	relative_roll_input = 0.0


func _is_relative_roll_settled() -> bool:
	var error_deadband := deg_to_rad(maxf(relative_roll_deadband_deg, 0.0))
	return (
		absf(relative_roll_error) <= error_deadband and
		absf(get_local_roll_rate()) <= maxf(relative_roll_rate_deadband, 0.0)
	)


func compute_control_state(_delta: float) -> void:
	compute_aoa()


func compute_aoa() -> void:
	if _frame_air_speed_squared < MIN_AERODYNAMIC_SPEED_SQUARED:
		aoa_deg = 0.0
		sideslip_deg = 0.0
		return

	var air_velocity_local := _frame_air_velocity_local
	var flow_forward := -air_velocity_local.z
	var flow_up := air_velocity_local.y
	var flow_right := air_velocity_local.x
	var forward_plane_speed := maxf(sqrt(flow_forward * flow_forward + flow_up * flow_up), 0.0001)

	aoa_deg = rad_to_deg(-atan2(flow_up, flow_forward))
	sideslip_deg = rad_to_deg(atan2(flow_right, forward_plane_speed))


func apply_thrust() -> void:
	var thrust_force := _get_thrust_force_world()
	if thrust_force.length_squared() <= 0.0:
		return

	apply_central_force(thrust_force)
	_debug_last_thrust_force_world = thrust_force
	_push_debug_force(global_position, thrust_force, DEBUG_COLOR_THRUST)


func apply_plane_torque() -> void:
	var control_coefficient := maxf(_sample_aero_table(control_authority_coefficient_table, _frame_air_speed), 0.0)
	var limited_pitch_input := _get_turn_limited_pitch_input(pitch_input)
	var p_in := -limited_pitch_input
	var y_in := yaw_input
	var r_in := roll_input

	var control_torque := base_control_torque * control_coefficient
	var pitch_torque := p_in * control_torque * max_pitch
	var yaw_torque := y_in * control_torque * max_yaw
	var roll_torque := r_in * control_torque * max_roll
	var pitch_yaw_torque_world := _frame_body_basis * Vector3(pitch_torque, yaw_torque, 0.0)
	var roll_torque_world := _frame_body_basis * Vector3(0.0, 0.0, roll_torque)
	var control_torque_world := pitch_yaw_torque_world + roll_torque_world
	if control_torque_world.length_squared() <= 0.000001 or not control_torque_world.is_finite():
		return

	apply_torque(control_torque_world)
	_push_debug_torque(global_position, pitch_yaw_torque_world, DEBUG_COLOR_PITCH_YAW_FORCE)
	_push_debug_torque(global_position, roll_torque_world, DEBUG_COLOR_ROLL_FORCE)


func apply_aerodynamic_forces() -> void:
	if _frame_air_speed_squared < MIN_AERODYNAMIC_SPEED_SQUARED:
		return

	if _frame_air_speed <= 0.0:
		return
	var airflow_direction := _frame_airflow_direction
	var dynamic_pressure := _frame_dynamic_pressure

	var lift_coefficient := _sample_aero_table(lift_coefficient_table, aoa_deg)
	var drag_coefficient := maxf(_sample_aero_table(drag_coefficient_table, aoa_deg), 0.0)
	var side_force_coefficient := _sample_aero_table(side_force_coefficient_table, sideslip_deg)

	var drag_force_magnitude := dynamic_pressure * reference_area * drag_coefficient
	var lift_force_magnitude := dynamic_pressure * reference_area * lift_coefficient
	var side_force_magnitude := dynamic_pressure * reference_area * side_force_coefficient
	var drag_force := -airflow_direction * drag_force_magnitude

	var right_axis := _frame_right_axis
	var lift_axis := right_axis.cross(airflow_direction)
	if lift_axis.length_squared() < MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		lift_axis = _frame_up_axis
	else:
		lift_axis = lift_axis.normalized()

	var side_axis := airflow_direction.cross(lift_axis)
	if side_axis.length_squared() < MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		side_axis = right_axis
	else:
		side_axis = side_axis.normalized()
	var lift_force := lift_axis * lift_force_magnitude
	var side_force := side_axis * side_force_magnitude

	var aerodynamic_force := (
		drag_force +
		lift_force +
		side_force
	)
	_debug_last_drag_force_world = drag_force
	_debug_last_lift_force_world = lift_force
	_debug_last_side_force_world = side_force

	if aerodynamic_force.is_finite():
		apply_central_force(aerodynamic_force)
		_push_debug_force(global_position, lift_force, DEBUG_COLOR_LIFT)
		_push_debug_force(global_position, drag_force, DEBUG_COLOR_DRAG)

func apply_directional_alignment() -> void:
	if _frame_air_speed_squared < MIN_AERODYNAMIC_SPEED_SQUARED:
		return

	var yaw_axis := _frame_up_axis
	var forward := _frame_forward_axis
	var velocity_direction := _frame_airflow_direction
	velocity_direction -= yaw_axis * velocity_direction.dot(yaw_axis)

	if velocity_direction.length_squared() < MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		return

	velocity_direction = velocity_direction.normalized()
	var axis := forward.cross(velocity_direction)
	var yaw_angle := forward.angle_to(velocity_direction) * signf(axis.dot(yaw_axis))

	if absf(yaw_angle) > 0.01:
		var torque := yaw_axis * yaw_angle * alignment_strength * _frame_air_speed
		if alignment_max_torque > 0.0:
			torque = torque.limit_length(alignment_max_torque)
		apply_torque(torque)
		_push_debug_torque(global_position, torque, DEBUG_COLOR_ALIGNMENT_TORQUE)


func apply_extra_drag_forces() -> void:
	var extra_linear_drag_force := _get_extra_linear_drag_force_world()
	if extra_linear_drag_force.length_squared() > 0.0 and extra_linear_drag_force.is_finite():
		apply_central_force(extra_linear_drag_force)

	var angular_drag_torque := _get_extra_angular_drag_torque_world()
	if angular_drag_torque.length_squared() > 0.0 and angular_drag_torque.is_finite():
		apply_torque(angular_drag_torque)
		_push_debug_torque(global_position, angular_drag_torque, DEBUG_COLOR_DAMPING)

	_debug_last_damping_force_world = _get_engine_damping_force_world() + extra_linear_drag_force
	if _debug_last_damping_force_world.length_squared() > 0.0 and _debug_last_damping_force_world.is_finite():
		_push_debug_force(global_position, _debug_last_damping_force_world, DEBUG_COLOR_DAMPING)


func apply_remote_state(snapshot: Dictionary) -> void:
	if is_local_player:
		return

	var tick := int(snapshot.get("tick", -1))
	if tick >= 0 and not _remote_snapshots.is_empty():
		var latest_tick := int(_remote_snapshots.back().get("tick", -1))
		if tick <= latest_tick:
			return

	var received_at := Time.get_ticks_usec() * 0.000001
	var stored_snapshot := {
		"tick": tick,
		"position": snapshot.get("position", global_position),
		"rotation": snapshot.get("rotation", global_transform.basis.get_rotation_quaternion()),
		"linear_velocity": snapshot.get("linear_velocity", Vector3.ZERO),
		"received_at": received_at,
	}
	_remote_snapshots.append(stored_snapshot)
	while _remote_snapshots.size() > REMOTE_MAX_SNAPSHOTS:
		_remote_snapshots.pop_front()


func apply_spawn_state(character_position: Vector3, yaw: float) -> void:
	global_position = character_position
	rotation = Vector3(0.0, yaw, 0.0)
	_remote_snapshots.clear()


func _apply_local_player_mode() -> void:
	freeze = not _is_simulated_locally()

	if _is_simulated_locally():
		sleeping = false
		can_sleep = false
		_remote_snapshots.clear()
	else:
		roll_input = 0.0
		pitch_input = 0.0
		yaw_input = 0.0
		throttle_input = -1.0

	_update_force_debug_renderer_state()


func _on_shot_down() -> void:
	if is_shot_down:
		return
	is_shot_down = true
	throttle_input = -1.0
	if _force_debug_renderer != null and _force_debug_renderer.has_method("clear_frame"):
		_force_debug_renderer.call("clear_frame")
	if _force_debug_renderer != null:
		_force_debug_renderer.visible = false
	if flame_trail_scene != null and _flame_trail == null:
		_flame_trail = flame_trail_scene.instantiate() as Node3D
		add_child(_flame_trail)


func apply_remote_shot_down() -> void:
	_on_shot_down()


func set_bot_controlled(enabled: bool) -> void:
	is_bot_controlled = enabled
	if not is_bot_controlled:
		_bot_target_roll_input = 0.0
		_bot_target_pitch_input = 0.0
		_bot_target_yaw_input = 0.0
		_bot_target_throttle_input = -1.0
		_sustain_turn_limiter_runtime_enabled = true

	if is_node_ready():
		_apply_local_player_mode()


func set_bot_control_inputs(roll_value: float, pitch_value: float, yaw_value: float, throttle_value: float) -> void:
	if not is_bot_controlled:
		set_bot_controlled(true)

	_bot_target_roll_input = clampf(roll_value, -1.0, 1.0)
	_bot_target_pitch_input = clampf(pitch_value, -1.0, 1.0)
	_bot_target_yaw_input = clampf(yaw_value, -1.0, 1.0)
	_bot_target_throttle_input = clampf(throttle_value, -1.0, 1.0)


func set_sustain_turn_limiter_runtime_enabled(enabled: bool) -> void:
	_sustain_turn_limiter_runtime_enabled = enabled


func _emit_local_state() -> void:
	_snapshot_tick += 1
	local_state_changed.emit(peer_id, _build_snapshot())


func _build_snapshot() -> Dictionary:
	return {
		"tick": _snapshot_tick,
		"position": global_position,
		"rotation": global_transform.basis.orthonormalized().get_rotation_quaternion(),
		"linear_velocity": linear_velocity,
	}


func _update_remote_interpolation() -> void:
	if _remote_snapshots.is_empty():
		return

	var now := Time.get_ticks_usec() * 0.000001
	var render_time := now - REMOTE_INTERPOLATION_DELAY
	while _remote_snapshots.size() >= 2 and float(_remote_snapshots[1]["received_at"]) <= render_time:
		_remote_snapshots.pop_front()

	if _remote_snapshots.size() >= 2:
		var from_snapshot := _remote_snapshots[0]
		var to_snapshot := _remote_snapshots[1]
		var from_time := float(from_snapshot["received_at"])
		var to_time := float(to_snapshot["received_at"])
		var alpha := 1.0
		if to_time > from_time:
			alpha = clampf((render_time - from_time) / (to_time - from_time), 0.0, 1.0)
		_apply_remote_pose(
			Vector3(from_snapshot["position"]).lerp(Vector3(to_snapshot["position"]), alpha),
			Quaternion(from_snapshot["rotation"]).slerp(Quaternion(to_snapshot["rotation"]), alpha)
		)
		return

	var latest_snapshot := _remote_snapshots[0]
	var latest_position := Vector3(latest_snapshot["position"])
	var latest_velocity := Vector3(latest_snapshot["linear_velocity"])
	var extrapolation := maxf(now - float(latest_snapshot["received_at"]), 0.0)
	_apply_remote_pose(
		latest_position + latest_velocity * extrapolation,
		Quaternion(latest_snapshot["rotation"])
	)


func _apply_remote_pose(position: Vector3, rotation_quaternion: Quaternion) -> void:
	global_position = position
	global_basis = Basis(rotation_quaternion.normalized())
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func _ensure_force_debug_renderer() -> void:
	if not debug_force_vectors_enabled:
		return

	if _force_debug_renderer != null:
		return

	_force_debug_renderer = FORCE_DEBUG_RENDERER_SCRIPT.new()
	_force_debug_renderer.name = "ForceDebugRenderer3D"
	add_child(_force_debug_renderer)
	_update_force_debug_renderer_state()


func _update_force_debug_renderer_state() -> void:
	if _force_debug_renderer == null:
		return

	var should_show := debug_force_vectors_enabled and _is_simulated_locally()
	_force_debug_renderer.visible = should_show
	if not should_show and _force_debug_renderer.has_method("clear_frame"):
		_force_debug_renderer.call("clear_frame")


func _begin_force_debug_frame() -> void:
	_debug_last_thrust_force_world = Vector3.ZERO
	_debug_last_lift_force_world = Vector3.ZERO
	_debug_last_drag_force_world = Vector3.ZERO
	_debug_last_side_force_world = Vector3.ZERO
	_debug_last_gravity_force_world = Vector3.ZERO
	_debug_last_damping_force_world = Vector3.ZERO

	if _force_debug_renderer == null:
		return

	_force_debug_renderer.call("begin_frame")
	var gravity_force := _get_gravity_force_world()
	_debug_last_gravity_force_world = gravity_force
	_push_debug_force(global_position, gravity_force, DEBUG_COLOR_GRAVITY)


func _end_force_debug_frame() -> void:
	if _force_debug_renderer == null:
		return

	_force_debug_renderer.call("end_frame")


func _clear_force_debug_frame() -> void:
	if _force_debug_renderer == null:
		return

	_force_debug_renderer.call("clear_frame")


func _push_debug_force(origin_world: Vector3, force_world: Vector3, color: Color) -> void:
	if _force_debug_renderer == null:
		return

	_force_debug_renderer.call("push_force", origin_world, force_world, color)


func _push_debug_torque(origin_world: Vector3, torque_world: Vector3, color: Color) -> void:
	if _force_debug_renderer == null:
		return

	_force_debug_renderer.call("push_torque", origin_world, torque_world, color)


func _get_gravity_force_world() -> Vector3:
	var gravity_direction: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector")
	var gravity_magnitude: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	return gravity_direction * gravity_magnitude * gravity_scale * mass


func _get_thrust_force_world() -> Vector3:
	var throttle := clampf((throttle_input + 1.0) * 0.5, 0.0, 1.0)
	if throttle <= 0.0:
		return Vector3.ZERO

	var forward_speed := absf(_frame_air_velocity_world.dot(_frame_forward_axis))
	var thrust_scale := maxf(_sample_aero_table(thrust_coefficient_table, forward_speed), 0.0)
	return _frame_forward_axis * throttle * max_thrust * thrust_scale


func _get_engine_damping_force_world() -> Vector3:
	if _last_total_linear_damp <= 0.0:
		return Vector3.ZERO

	# Equivalent linear force for dv/dt = -damp * v.
	return -linear_velocity * mass * _last_total_linear_damp


func _get_extra_linear_drag_force_world() -> Vector3:
	if _frame_air_speed_squared < MIN_AERODYNAMIC_SPEED_SQUARED:
		return Vector3.ZERO

	if _frame_air_speed <= 0.0:
		return Vector3.ZERO

	var direction := _frame_airflow_direction
	var linear_component := maxf(extra_linear_drag_linear_coefficient, 0.0) * _frame_air_speed
	var quadratic_component := maxf(extra_linear_drag_quadratic_coefficient, 0.0) * _frame_air_speed_squared
	return -direction * (linear_component + quadratic_component)


func _get_extra_angular_drag_torque_world() -> Vector3:
	if angular_velocity.length_squared() < MIN_ANGULAR_SPEED_SQUARED:
		return Vector3.ZERO

	var body_basis := _frame_body_basis
	var local_angular_velocity := body_basis.transposed() * angular_velocity
	var local_drag_torque := Vector3(
		_compute_axis_drag_torque_component(local_angular_velocity.x, extra_angular_drag_linear_coefficients.x, extra_angular_drag_quadratic_coefficients.x),
		_compute_axis_drag_torque_component(local_angular_velocity.y, extra_angular_drag_linear_coefficients.y, extra_angular_drag_quadratic_coefficients.y),
		_compute_axis_drag_torque_component(local_angular_velocity.z, extra_angular_drag_linear_coefficients.z, extra_angular_drag_quadratic_coefficients.z)
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


func get_force_balance_snapshot() -> Dictionary:
	var velocity := linear_velocity
	var speed := velocity.length()
	var velocity_dir := Vector3.ZERO
	if speed > 0.001:
		velocity_dir = velocity / speed

	var thrust_force := _debug_last_thrust_force_world
	var drag_force := _debug_last_drag_force_world
	var gravity_force := _debug_last_gravity_force_world
	var damping_force := _debug_last_damping_force_world
	var net_force := (
		thrust_force +
		_debug_last_lift_force_world +
		_debug_last_side_force_world +
		drag_force +
		gravity_force +
		damping_force
	)

	return {
		"speed": speed,
		"thrust_along_velocity": thrust_force.dot(velocity_dir),
		"drag_along_velocity": drag_force.dot(velocity_dir),
		"gravity_along_velocity": gravity_force.dot(velocity_dir),
		"damping_along_velocity": damping_force.dot(velocity_dir),
		"net_along_velocity": net_force.dot(velocity_dir),
	}


func is_hostile_to(other: Node) -> bool:
	return other != null and is_instance_valid(other)


func get_throttle_percent() -> float:
	return throttle_percent


func get_aoa_deg() -> float:
	return aoa_deg


func get_pitch_input() -> float:
	return pitch_input


func get_yaw_input() -> float:
	return yaw_input


func get_roll_input() -> float:
	return roll_input


func get_relative_roll_error() -> float:
	return relative_roll_error


func get_relative_roll_input() -> float:
	return relative_roll_input


func is_relative_roll_active() -> bool:
	return relative_roll_target_active


func get_local_angular_velocity() -> Vector3:
	return _frame_body_basis.transposed() * angular_velocity


func get_local_roll_rate() -> float:
	return get_local_angular_velocity().z


func get_best_climb_speed_vy() -> float:
	return _best_climb_speed_vy


func is_best_climb_speed_vy_valid() -> bool:
	return _best_climb_speed_vy_valid


func is_sustain_turn_using_vy() -> bool:
	return _sustain_turn_using_vy


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
		get_local_roll_rate(),
		rate_response_gain,
		-1.0,
		1.0,
		rate_scale
	)


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


func get_throttle_input() -> float:
	return throttle_input


func get_lift_table() -> Array[Vector2]:
	return lift_coefficient_table.duplicate()


func get_drag_table() -> Array[Vector2]:
	return drag_coefficient_table.duplicate()


func get_side_force_table() -> Array[Vector2]:
	return side_force_coefficient_table.duplicate()


func get_control_authority_table() -> Array[Vector2]:
	return control_authority_coefficient_table.duplicate()


func set_lift_table(points: Array[Vector2]) -> void:
	lift_coefficient_table = _normalize_table(points)
	_refresh_max_lift_aoa_limits()


func set_drag_table(points: Array[Vector2]) -> void:
	drag_coefficient_table = _normalize_table(points)


func set_side_force_table(points: Array[Vector2]) -> void:
	side_force_coefficient_table = _normalize_table(points)


func set_control_authority_table(points: Array[Vector2]) -> void:
	control_authority_coefficient_table = _normalize_table(points)


func get_thrust_table() -> Array[Vector2]:
	return thrust_coefficient_table.duplicate()


func set_thrust_table(points: Array[Vector2]) -> void:
	thrust_coefficient_table = _normalize_table(points)


func get_sideslip_deg() -> float:
	return sideslip_deg


func _get_air_relative_velocity_world() -> Vector3:
	return linear_velocity - ambient_wind_velocity_world


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
		if absf(span) <= TABLE_SORT_EPSILON:
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
	if absf(span) <= TABLE_SORT_EPSILON:
		return right.y

	var t := (x_value - left.x) / span
	return lerpf(left.y, right.y, t)


func _get_turn_limited_pitch_input(raw_pitch_input: float) -> float:
	var limited_pitch_input := _get_max_lift_limited_pitch_input(raw_pitch_input)
	return _get_sustain_turn_limited_pitch_input(limited_pitch_input)


func _get_max_lift_limited_pitch_input(raw_pitch_input: float) -> float:
	var limited_pitch_input := clampf(raw_pitch_input, -1.0, 1.0)
	if not max_lift_turn_limiter_enabled:
		return limited_pitch_input

	if _frame_air_speed < maxf(max_lift_turn_limiter_min_airspeed, 0.0):
		return limited_pitch_input

	if _positive_max_lift_aoa_deg <= _negative_max_lift_aoa_deg:
		return limited_pitch_input

	var fade_degrees := maxf(max_lift_turn_limiter_fade_deg, 0.0)
	if limited_pitch_input < 0.0 or aoa_deg > _positive_max_lift_aoa_deg:
		return _limit_pitch_input_below_upper_aoa_limit(
			limited_pitch_input,
			_positive_max_lift_aoa_deg,
			fade_degrees
		)

	if limited_pitch_input > 0.0 or aoa_deg < _negative_max_lift_aoa_deg:
		return _limit_pitch_input_above_lower_aoa_limit(
			limited_pitch_input,
			_negative_max_lift_aoa_deg,
			fade_degrees
		)

	return limited_pitch_input


func _get_sustain_turn_limited_pitch_input(raw_pitch_input: float) -> float:
	var limited_pitch_input := clampf(raw_pitch_input, -1.0, 1.0)
	if not _should_apply_sustain_turn_limiter():
		return limited_pitch_input

	var fade_degrees := maxf(sustain_turn_limiter_fade_deg, 0.0)
	if limited_pitch_input < 0.0 or aoa_deg > 0.0:
		var positive_limit := _get_sustainable_aoa_limit(true)
		return _limit_pitch_input_below_upper_aoa_limit(
			limited_pitch_input,
			positive_limit,
			fade_degrees
		)

	if limited_pitch_input > 0.0 or aoa_deg < 0.0:
		var negative_limit := _get_sustainable_aoa_limit(false)
		return _limit_pitch_input_above_lower_aoa_limit(
			limited_pitch_input,
			negative_limit,
			fade_degrees
		)

	return limited_pitch_input


func _should_apply_sustain_turn_limiter() -> bool:
	if not sustain_turn_limiter_enabled:
		return false

	if not _sustain_turn_limiter_runtime_enabled:
		return false

	if is_local_player and Input.is_key_pressed(KEY_CTRL):
		return false

	if _frame_air_speed < maxf(max_lift_turn_limiter_min_airspeed, 0.0):
		return false

	if _frame_air_speed_squared < MIN_AERODYNAMIC_SPEED_SQUARED:
		return false

	if _positive_max_lift_aoa_deg <= _negative_max_lift_aoa_deg:
		return false

	return true


func _get_sustainable_aoa_limit(positive_limit: bool) -> float:
	var bound := _positive_max_lift_aoa_deg if positive_limit else _negative_max_lift_aoa_deg

	# Pull-up while altitude is rising: gate on speed margin above Vy instead of the
	# current-speed drag balance, which collapses during a climb (gravity along the
	# climbing airflow turns negative). This lets the pilot trade speed down to Vy.
	if positive_limit and _should_use_vy_speed_margin_limit():
		_sustain_turn_using_vy = true
		return _get_vy_speed_margin_aoa_limit(bound)

	_sustain_turn_using_vy = false

	var sample_count := maxi(sustain_turn_limiter_samples, 1)
	var available_force := _get_sustain_available_forward_force()
	if available_force <= 0.0:
		return 0.0

	var target_speed := _get_sustain_turn_target_speed()
	var target_speed_squared := target_speed * target_speed
	var dynamic_pressure := 0.5 * air_density * target_speed_squared
	var aero_drag_scale := dynamic_pressure * reference_area
	var extra_linear_drag := maxf(extra_linear_drag_linear_coefficient, 0.0) * target_speed
	var extra_quadratic_drag := maxf(extra_linear_drag_quadratic_coefficient, 0.0) * target_speed_squared
	var engine_damping_drag := maxf(_last_total_linear_damp, 0.0) * mass * target_speed
	var non_aoa_drag := extra_linear_drag + extra_quadratic_drag + engine_damping_drag
	var drag_margin := maxf(sustain_turn_limiter_drag_margin, 0.0)
	var drag_segment_index := _find_aero_table_segment_index(drag_coefficient_table, 0.0)
	var allowed_aoa := 0.0

	for index in range(sample_count + 1):
		var weight := float(index) / float(sample_count)
		var candidate_aoa := lerpf(0.0, bound, weight)
		drag_segment_index = _advance_aero_table_segment_index(drag_coefficient_table, candidate_aoa, drag_segment_index)
		var drag_coefficient := maxf(_sample_aero_table_segment(drag_coefficient_table, candidate_aoa, drag_segment_index), 0.0)
		var required_force := (aero_drag_scale * drag_coefficient + non_aoa_drag) * drag_margin
		if required_force <= available_force:
			allowed_aoa = candidate_aoa

	return allowed_aoa


func _get_sustain_available_forward_force() -> float:
	var thrust_force := _get_thrust_force_world()
	var gravity_force := _get_gravity_force_world()
	return thrust_force.dot(_frame_airflow_direction) + gravity_force.dot(_frame_airflow_direction)


func _should_use_vy_speed_margin_limit() -> bool:
	if not sustain_turn_vy_enabled:
		return false

	if not _best_climb_speed_vy_valid:
		return false

	# Engage while actually climbing, or the instant the pilot commands a wings-level
	# pull-up, so a climb entry isn't choked by the current-speed drag check before
	# altitude has started to rise.
	return _altitude_rising or _has_sustain_turn_climb_intent()


func _get_vy_speed_margin_aoa_limit(bound: float) -> float:
	# Bleed toward the actual computed Vy (already validated > 0), not the drag-check
	# floor -- the floor only guards the current-speed path, not this gate.
	var vy_speed := maxf(_best_climb_speed_vy, 0.1)
	var margin_speed := maxf(sustain_turn_vy_margin_speed, 0.0)
	var speed_above_vy := _frame_air_speed - vy_speed

	if margin_speed <= 0.0001:
		if speed_above_vy > 0.0:
			return bound
		return 0.0

	var speed_margin_authority := clampf(speed_above_vy / margin_speed, 0.0, 1.0)
	return lerpf(0.0, bound, speed_margin_authority)


func _update_best_climb_speed_vy(delta: float) -> void:
	_sustain_turn_vy_update_timer -= delta
	if _sustain_turn_vy_update_timer > 0.0:
		return

	_sustain_turn_vy_update_timer = maxf(sustain_turn_vy_update_interval, 0.01)
	_best_climb_speed_vy = _calculate_best_climb_speed_vy()
	_best_climb_speed_vy_valid = _best_climb_speed_vy > 0.0


func _calculate_best_climb_speed_vy() -> float:
	if not sustain_turn_vy_enabled:
		return 0.0

	var sample_count := maxi(sustain_turn_vy_sample_count, 1)
	var min_speed := maxf(sustain_turn_vy_sample_min_speed, 0.1)
	var max_speed := maxf(sustain_turn_vy_sample_max_speed, min_speed)

	var load_factor := _get_current_bank_load_factor()
	if not is_finite(load_factor):
		return 0.0

	load_factor = minf(load_factor, maxf(sustain_turn_vy_max_load_factor, 1.0))

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
	var gravity_magnitude := default_gravity * gravity_scale
	return mass * gravity_magnitude


func _get_current_bank_load_factor() -> float:
	var local_world_up := _frame_body_basis.transposed() * Vector3.UP
	var bank_angle := atan2(local_world_up.x, local_world_up.y)
	var bank_cosine := cos(bank_angle)

	if bank_cosine <= 0.05:
		return INF

	return 1.0 / bank_cosine


func _get_available_thrust_at_speed(speed: float) -> float:
	var thrust_coefficient := maxf(_sample_aero_table(thrust_coefficient_table, speed), 0.0)
	return max_thrust * thrust_coefficient


func _get_drag_required_for_lift_at_speed(required_lift: float, speed: float) -> float:
	var speed_squared := speed * speed
	if speed_squared <= 0.001:
		return -1.0

	var dynamic_pressure := 0.5 * air_density * speed_squared
	var lift_scale := dynamic_pressure * reference_area
	if lift_scale <= 0.001:
		return -1.0

	var required_lift_coefficient := required_lift / lift_scale
	if not _can_reach_lift_coefficient(required_lift_coefficient):
		return -1.0

	var required_aoa := _find_nearest_aoa_for_lift_coefficient(required_lift_coefficient)
	if not is_finite(required_aoa):
		return -1.0

	var drag_coefficient := maxf(_sample_aero_table(drag_coefficient_table, required_aoa), 0.0)
	var aerodynamic_drag := dynamic_pressure * reference_area * drag_coefficient

	var extra_drag := (
		maxf(extra_linear_drag_linear_coefficient, 0.0) * speed +
		maxf(extra_linear_drag_quadratic_coefficient, 0.0) * speed_squared +
		maxf(_last_total_linear_damp, 0.0) * mass * speed
	)

	return aerodynamic_drag + extra_drag


func _can_reach_lift_coefficient(target_lift_coefficient: float) -> bool:
	if lift_coefficient_table.is_empty():
		return false

	var min_lift_coefficient := INF
	var max_lift_coefficient := -INF

	for point in lift_coefficient_table:
		min_lift_coefficient = minf(min_lift_coefficient, point.y)
		max_lift_coefficient = maxf(max_lift_coefficient, point.y)

	return (
		target_lift_coefficient >= min_lift_coefficient and
		target_lift_coefficient <= max_lift_coefficient
	)


func _find_nearest_aoa_for_lift_coefficient(target_lift_coefficient: float) -> float:
	if lift_coefficient_table.is_empty():
		return INF

	var best_aoa := INF
	var best_error := INF

	for point in lift_coefficient_table:
		var error := absf(point.y - target_lift_coefficient)
		if error < best_error:
			best_error = error
			best_aoa = point.x

	return best_aoa


func _get_vertical_pull_intent() -> float:
	var pull_strength := -pitch_input
	return pull_strength * _frame_up_axis.y


func _has_sustain_turn_climb_intent() -> bool:
	return _get_vertical_pull_intent() > sustain_turn_vy_min_vertical_pull_intent


func _get_sustain_turn_target_speed() -> float:
	return maxf(_frame_air_speed, sustain_turn_limiter_min_target_airspeed)


func _limit_pitch_input_below_upper_aoa_limit(raw_pitch_input: float, upper_limit_deg: float, fade_degrees: float) -> float:
	var limited_pitch_input := clampf(raw_pitch_input, -1.0, 1.0)
	if limited_pitch_input >= 0.0 and aoa_deg <= upper_limit_deg:
		return limited_pitch_input

	limited_pitch_input *= _get_pitch_authority_below_upper_aoa_limit(upper_limit_deg, fade_degrees)

	if aoa_deg <= upper_limit_deg:
		return limited_pitch_input

	var recovery_span := maxf(fade_degrees, 1.0)
	var recovery_input := clampf((aoa_deg - upper_limit_deg) / recovery_span, 0.0, 1.0)
	return maxf(limited_pitch_input, recovery_input)


func _limit_pitch_input_above_lower_aoa_limit(raw_pitch_input: float, lower_limit_deg: float, fade_degrees: float) -> float:
	var limited_pitch_input := clampf(raw_pitch_input, -1.0, 1.0)
	if limited_pitch_input <= 0.0 and aoa_deg >= lower_limit_deg:
		return limited_pitch_input

	limited_pitch_input *= _get_pitch_authority_above_lower_aoa_limit(lower_limit_deg, fade_degrees)

	if aoa_deg >= lower_limit_deg:
		return limited_pitch_input

	var recovery_span := maxf(fade_degrees, 1.0)
	var recovery_input := -clampf((lower_limit_deg - aoa_deg) / recovery_span, 0.0, 1.0)
	return minf(limited_pitch_input, recovery_input)


func _get_pitch_authority_below_upper_aoa_limit(upper_limit_deg: float, fade_degrees: float) -> float:
	if fade_degrees <= 0.0001:
		if aoa_deg >= upper_limit_deg:
			return 0.0
		return 1.0

	return clampf((upper_limit_deg - aoa_deg) / fade_degrees, 0.0, 1.0)


func _get_pitch_authority_above_lower_aoa_limit(lower_limit_deg: float, fade_degrees: float) -> float:
	if fade_degrees <= 0.0001:
		if aoa_deg <= lower_limit_deg:
			return 0.0
		return 1.0

	return clampf((aoa_deg - lower_limit_deg) / fade_degrees, 0.0, 1.0)


func _sanitize_aero_tables() -> void:
	lift_coefficient_table = _normalize_table(lift_coefficient_table)
	drag_coefficient_table = _normalize_table(drag_coefficient_table)
	side_force_coefficient_table = _normalize_table(side_force_coefficient_table)
	control_authority_coefficient_table = _normalize_table(control_authority_coefficient_table)
	thrust_coefficient_table = _normalize_table(thrust_coefficient_table)
	_refresh_max_lift_aoa_limits()


func _normalize_table(points: Array[Vector2]) -> Array[Vector2]:
	var normalized := points.duplicate()
	normalized.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)

	var deduped: Array[Vector2] = []
	for point in normalized:
		if deduped.is_empty():
			deduped.append(point)
			continue

		if absf(point.x - deduped[deduped.size() - 1].x) <= TABLE_SORT_EPSILON:
			deduped[deduped.size() - 1] = point
		else:
			deduped.append(point)

	return deduped


func _apply_persisted_aero_tables() -> void:
	var payload: Dictionary = AERO_TABLES_STORE.load_payload()
	if payload.is_empty():
		return

	var lift_points := AERO_TABLES_STORE.decode_points(payload.get("lift_table", []))
	if not lift_points.is_empty():
		set_lift_table(lift_points)

	var drag_points := AERO_TABLES_STORE.decode_points(payload.get("drag_table", []))
	if not drag_points.is_empty():
		set_drag_table(drag_points)

	var control_authority_points := AERO_TABLES_STORE.decode_points(payload.get("control_authority_table", []))
	if not control_authority_points.is_empty():
		set_control_authority_table(control_authority_points)

	var thrust_points := AERO_TABLES_STORE.decode_points(payload.get("thrust_table", []))
	if not thrust_points.is_empty():
		set_thrust_table(thrust_points)


func _refresh_max_lift_aoa_limits() -> void:
	var positive_found := false
	var negative_found := false
	var positive_best_coefficient := 0.0
	var negative_best_coefficient := 0.0
	var positive_limit := 15.0
	var negative_limit := -15.0

	for point in lift_coefficient_table:
		if point.x > 0.0 and (not positive_found or point.y > positive_best_coefficient):
			positive_found = true
			positive_best_coefficient = point.y
			positive_limit = point.x

		if point.x < 0.0 and (not negative_found or point.y < negative_best_coefficient):
			negative_found = true
			negative_best_coefficient = point.y
			negative_limit = point.x

	if positive_found:
		_positive_max_lift_aoa_deg = positive_limit
	else:
		_positive_max_lift_aoa_deg = absf(negative_limit)

	if negative_found:
		_negative_max_lift_aoa_deg = negative_limit
	else:
		_negative_max_lift_aoa_deg = -absf(positive_limit)
