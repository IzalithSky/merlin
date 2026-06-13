class_name PlaneCharacter
extends RigidBody3D

signal local_input_produced(peer_id: int, input: PackedByteArray)

const AERO_TABLES_STORE := preload("res://scripts/plane_aero_tables_store.gd")
const FORCE_DEBUG_RENDERER_SCRIPT := preload("res://scripts/force_debug_renderer_3d.gd")
const PLANE_BOT_PILOT_SCRIPT := preload("res://scripts/plane_bot_pilot.gd")
const PLANE_CRASH_DAMAGE_MODEL_SCRIPT := preload("res://scripts/plane_crash_damage_model.gd")
const PLANE_FLIGHT_MODEL_SCRIPT := preload("res://scripts/plane_flight_model.gd")
const PLANE_FORCE_DEBUG_ADAPTER_SCRIPT := preload("res://scripts/plane_force_debug_adapter.gd")
const PLANE_INPUT_COLLECTOR_SCRIPT := preload("res://scripts/plane_input_collector.gd")
const PLANE_NET_ADAPTER_SCRIPT := preload("res://scripts/plane_net_adapter.gd")

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
@export var alignment_angle_to_rate_gain: float = 1.2
@export var alignment_max_desired_axis_rate: float = 1.4
@export var alignment_rate_response_gain: float = 0.8
@export var alignment_deadband_deg: float = 1.0
@export var alignment_rate_deadband: float = 0.03
@export var extra_linear_drag_linear_coefficient: float = 0.0
@export var extra_linear_drag_quadratic_coefficient: float = 0.16
@export var extra_angular_drag_linear_coefficients: Vector3 = Vector3(20000.0, 12000.0, 20000.0)
@export var extra_angular_drag_quadratic_coefficients: Vector3 = Vector3(2500.0, 1200.0, 2500.0)
@export var server_net_tick_hz: float = 30.0
@export var reconcile_position_tolerance: float = 3.0
@export var reconcile_hard_snap_distance: float = 60.0
@export var reconcile_correction_rate: float = 8.0
@export var reconcile_rotation_blend: float = 0.25
@export var reconcile_velocity_blend: float = 0.25
@export var debug_force_vectors_enabled: bool = true
@export var shot_down_roll_spin_min_deg: float = 180.0
@export var shot_down_roll_spin_max_deg: float = 540.0
@export var team_id: int = 0
@export var ground_impact_damage_speed_threshold: float = 35.0
@export var ground_impact_fatal_speed_threshold: float = 50.0
@export var ground_impact_fatal_surface_angle_deg: float = 25.0
@export var ground_impact_max_damage: float = 80.0

const TABLE_SORT_EPSILON := 0.0001
const MIN_AERODYNAMIC_SPEED_SQUARED := 0.0001
const MIN_DIRECTION_VECTOR_LENGTH_SQUARED := 0.000001
const MIN_ANGULAR_SPEED_SQUARED := 0.000001
const GROUND_IMPACT_COOLDOWN_SECONDS := 0.16
const DEBUG_COLOR_THRUST := Color(1.0, 0.58, 0.12, 1.0)
const DEBUG_COLOR_LIFT := Color(0.2, 0.9, 0.2, 1.0)
const DEBUG_COLOR_DRAG := Color(0.95, 0.23, 0.23, 1.0)
const DEBUG_COLOR_GRAVITY := Color(0.35, 0.55, 1.0, 1.0)
const DEBUG_COLOR_DAMPING := Color(0.8, 0.8, 0.8, 1.0)
const DEBUG_COLOR_ROLL_FORCE := Color(0.97, 0.35, 0.95, 1.0)
const DEBUG_COLOR_PITCH_YAW_FORCE := Color(0.1, 0.95, 0.95, 1.0)
const DEBUG_COLOR_ALIGNMENT_TORQUE := Color(1.0, 0.95, 0.3, 1.0)
@export var flame_trail_scene: PackedScene

@onready var _health = $Health
@onready var _lockable_target = $LockableTarget
@onready var _weapon_lock = $PlaneWeaponLock
@onready var _missile_launcher = $MissileLauncher
@onready var _autocannon = $Autocannon

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
var _player_pitch_control_active := false
var _player_yaw_control_active := false
var _player_direct_roll_control_active := false
var _pitch_assist_enabled := true
var _stabilization_assist_enabled := true
var _input_decay_enabled := true

var aoa_deg := 0.0
var sideslip_deg := 0.0
var throttle_percent := 0.0

var _force_debug_renderer
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
var _net_limiter_override_active := false
var _net_effective_pitch_input := 0.0
var _shot_down_random := RandomNumberGenerator.new()
var _last_ground_impact_time: float = -INF
var _input_collector
var _crash_damage
var _force_debug
var _net
var _flight_model
var _preserve_remote_wreck_velocities := false


func _ready() -> void:
	add_to_group("player_character")
	add_to_group("plane_character")
	_input_collector = PLANE_INPUT_COLLECTOR_SCRIPT.new(self)
	_crash_damage = PLANE_CRASH_DAMAGE_MODEL_SCRIPT.new(self)
	_force_debug = PLANE_FORCE_DEBUG_ADAPTER_SCRIPT.new(self)
	_net = PLANE_NET_ADAPTER_SCRIPT.new(self)
	_flight_model = PLANE_FLIGHT_MODEL_SCRIPT.new(self)
	_shot_down_random.randomize()
	_apply_spawn_control_defaults()
	_sanitize_aero_tables()
	if _is_aero_table_authority():
		_apply_persisted_aero_tables()
	_ensure_force_debug_renderer()
	_apply_local_player_mode()
	if _health != null:
		_health.shot_down.connect(_on_shot_down)


func configure(new_peer_id: int, local_player: bool) -> void:
	var was_local_player := is_local_player
	peer_id = new_peer_id
	is_local_player = local_player

	if is_node_ready():
		if is_local_player and not was_local_player:
			_apply_spawn_control_defaults()
		_apply_local_player_mode()


func get_health_component():
	return _health


func get_lockable_target_component():
	return _lockable_target


func get_weapon_lock_component():
	return _weapon_lock


func get_missile_launcher_component():
	return _missile_launcher


func get_autocannon_component():
	return _autocannon


func get_bot_pilot():
	return get_node_or_null("PlaneBotPilot")


func ensure_bot_pilot():
	var pilot = get_bot_pilot()
	if pilot != null:
		return pilot

	pilot = PLANE_BOT_PILOT_SCRIPT.new()
	pilot.name = "PlaneBotPilot"
	add_child(pilot)
	return pilot


func clear_bot_pilot() -> void:
	var pilot = get_bot_pilot()
	if pilot != null:
		pilot.queue_free()


func _physics_process(delta: float) -> void:
	if not _is_simulated_locally():
		_clear_force_debug_frame()
		return

	_net.record_prediction_state()
	_net.apply_pending_correction(delta)

	if is_shot_down:
		_clear_force_debug_frame()
		return

	_begin_force_debug_frame()
	_update_physics_frame_cache()
	_update_altitude_rising_state()
	_update_best_climb_speed_vy(delta)

	if is_bot_controlled:
		_apply_bot_inputs(delta)
	elif _is_net_input_driven():
		_apply_net_inputs()
	else:
		_input_collector.collect_inputs(delta)
		_emit_local_input()
	compute_control_state(delta)
	apply_thrust()
	apply_plane_torque()
	apply_aerodynamic_forces()
	apply_extra_drag_forces()
	apply_directional_alignment()
	_end_force_debug_frame()


func _process(delta: float) -> void:
	if _is_simulated_locally():
		return

	_net.update_remote_interpolation(delta)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	_last_total_linear_damp = maxf(state.total_linear_damp, 0.0)
	_handle_ground_impact_contacts(state)


func _is_simulated_locally() -> bool:
	if multiplayer.multiplayer_peer == null:
		return is_local_player or is_bot_controlled
	if multiplayer.is_server():
		return true
	# Pure client: predict own plane while alive; wrecks are interpolated like remotes.
	return is_local_player and not is_shot_down


func _is_predicting_client() -> bool:
	return (
		multiplayer.multiplayer_peer != null
		and not multiplayer.is_server()
		and is_local_player
	)


func _is_net_input_driven() -> bool:
	return (
		multiplayer.multiplayer_peer != null
		and multiplayer.is_server()
		and not is_local_player
		and not is_bot_controlled
	)


func _is_aero_table_authority() -> bool:
	return multiplayer.multiplayer_peer == null or multiplayer.is_server()


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
	_player_pitch_control_active = false
	_player_yaw_control_active = false
	_player_direct_roll_control_active = false
	_net_limiter_override_active = false
	_net_effective_pitch_input = 0.0
	if is_local_player:
		var ds := DisplaySettings
		_pitch_assist_enabled = ds.pitch_assist_enabled if ds != null else true
		_stabilization_assist_enabled = ds.stabilization_assist_enabled if ds != null else true
		_input_decay_enabled = ds.input_decay_enabled if ds != null else true
	else:
		_pitch_assist_enabled = true
		_stabilization_assist_enabled = true
		_input_decay_enabled = true


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
	_player_pitch_control_active = false
	_player_yaw_control_active = false
	_player_direct_roll_control_active = false

	throttle_percent = ((throttle_input + 1.0) * 0.5) * 100.0


func apply_net_control_input(input: Dictionary) -> void:
	_net.apply_net_control_input(input)


func _apply_net_inputs() -> void:
	var input: Dictionary = _net.consume_pending_input()
	if not input.is_empty():
		# The owning client already applied rate/decay smoothing; apply directly.
		roll_input = clampf(float(input.get("roll", 0.0)), -1.0, 1.0)
		pitch_input = clampf(float(input.get("pitch", 0.0)), -1.0, 1.0)
		yaw_input = clampf(float(input.get("yaw", 0.0)), -1.0, 1.0)
		throttle_input = clampf(float(input.get("throttle", -1.0)), -1.0, 1.0)
		_player_pitch_control_active = bool(input.get("pitch_control_active", false))
		_player_yaw_control_active = bool(input.get("yaw_control_active", false))
		_player_direct_roll_control_active = bool(input.get("direct_roll_control_active", false))
		relative_roll_target_active = bool(input.get("relative_roll_target_active", false))
		_pitch_assist_enabled = bool(input.get("pitch_assist_enabled", true))
		_stabilization_assist_enabled = bool(input.get("stabilization_assist_enabled", true))
		_net_limiter_override_active = bool(input.get("limiter_override_active", false))
		_net_effective_pitch_input = clampf(float(input.get("effective_pitch", pitch_input)), -1.0, 1.0)
	throttle_percent = ((throttle_input + 1.0) * 0.5) * 100.0


func _emit_local_input() -> void:
	var input: PackedByteArray = _net.build_local_input_payload()
	if input.is_empty():
		return
	local_input_produced.emit(peer_id, input)


func compute_control_state(_delta: float) -> void:
	_flight_model.compute_control_state(_delta)


func compute_aoa() -> void:
	_flight_model.compute_aoa()


func apply_thrust() -> void:
	_flight_model.apply_thrust()


func apply_plane_torque() -> void:
	_flight_model.apply_plane_torque()


func apply_aerodynamic_forces() -> void:
	_flight_model.apply_aerodynamic_forces()

func apply_directional_alignment() -> void:
	_flight_model.apply_directional_alignment()


func apply_extra_drag_forces() -> void:
	_flight_model.apply_extra_drag_forces()


func apply_remote_state(snapshot: Dictionary) -> void:
	_net.apply_remote_state(snapshot)


func apply_authoritative_state(snapshot: Dictionary) -> void:
	# Server echo of this client's own plane (carries ack_seq for reconciliation).
	_net.apply_authoritative_state(snapshot)


func apply_spawn_state(character_position: Vector3, yaw: float) -> void:
	_preserve_remote_wreck_velocities = false
	_net.apply_spawn_state(character_position, yaw)


func build_state_for_batch(world_tick: int) -> Dictionary:
	return _net.build_state_for_batch(world_tick)


func set_server_net_tick_hz(value: float) -> void:
	server_net_tick_hz = maxf(value, 0.001)


func get_server_net_tick_hz() -> float:
	return server_net_tick_hz


func _apply_local_player_mode() -> void:
	# Remote planes are frozen and posed from code; KINEMATIC (not the default
	# STATIC) is the engine-recommended freeze mode for code-moved bodies so they
	# derive velocity from transform deltas and produce correct contacts.
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = not _is_simulated_locally()

	if _is_simulated_locally():
		_preserve_remote_wreck_velocities = false
		sleeping = false
		can_sleep = false
		_net.clear_remote_snapshots()
	else:
		roll_input = 0.0
		pitch_input = 0.0
		yaw_input = 0.0
		throttle_input = -1.0

	_update_force_debug_renderer_state()


func _handle_ground_impact_contacts(state: PhysicsDirectBodyState3D) -> void:
	_crash_damage.handle_ground_impact_contacts(state)


func apply_ground_impact_damage(impact_speed: float, impact_angle_deg: float) -> void:
	_crash_damage.apply_ground_impact_damage(impact_speed, impact_angle_deg)


func _get_surface_impact_angle_deg(surface_normal_world: Vector3, movement_velocity_world: Vector3) -> float:
	return _crash_damage.get_surface_impact_angle_deg(surface_normal_world, movement_velocity_world)


func _on_shot_down() -> void:
	if is_shot_down:
		return
	var was_predicting_client := _is_predicting_client()
	is_shot_down = true
	throttle_input = -1.0
	angular_damp = 0.0
	if _force_debug_renderer != null:
		_force_debug_renderer.clear_frame()
		_force_debug_renderer.visible = false
	if flame_trail_scene != null and _flame_trail == null:
		_flame_trail = flame_trail_scene.instantiate() as Node3D
		add_child(_flame_trail)
	# The simulation authority rolls the wreck spin; a predicting client stops
	# simulating at shot-down (handover to interpolation), so the spin is only
	# ever applied once.
	if _is_simulated_locally():
		var roll_axis := -global_transform.basis.orthonormalized().z
		var roll_spin_deg := _shot_down_random.randf_range(
			shot_down_roll_spin_min_deg,
			shot_down_roll_spin_max_deg
		)
		if _shot_down_random.randf() < 0.5:
			roll_spin_deg *= -1.0
		angular_velocity += roll_axis * deg_to_rad(roll_spin_deg)
	else:
		_net.clear_prediction_correction()
	if was_predicting_client:
		_preserve_remote_wreck_velocities = true
		_net.begin_shot_down_remote_handoff()
	_apply_local_player_mode()


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


func _apply_remote_pose(remote_position: Vector3, rotation_quaternion: Quaternion) -> void:
	global_position = remote_position
	global_basis = Basis(rotation_quaternion.normalized())
	if not _preserve_remote_wreck_velocities:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO


func get_replicated_velocity() -> Vector3:
	return _net.get_replicated_velocity()


func _ensure_force_debug_renderer() -> void:
	_force_debug.ensure_renderer()


func _update_force_debug_renderer_state() -> void:
	_force_debug.update_renderer_state()


func _begin_force_debug_frame() -> void:
	_force_debug.begin_frame()


func _end_force_debug_frame() -> void:
	_force_debug.end_frame()


func _clear_force_debug_frame() -> void:
	_force_debug.clear_frame()


func _push_debug_force(origin_world: Vector3, force_world: Vector3, color: Color) -> void:
	_force_debug.push_force(origin_world, force_world, color)


func _push_debug_torque(origin_world: Vector3, torque_world: Vector3, color: Color) -> void:
	_force_debug.push_torque(origin_world, torque_world, color)


func reset_debug_force_accumulators() -> void:
	_debug_last_thrust_force_world = Vector3.ZERO
	_debug_last_lift_force_world = Vector3.ZERO
	_debug_last_drag_force_world = Vector3.ZERO
	_debug_last_side_force_world = Vector3.ZERO
	_debug_last_gravity_force_world = Vector3.ZERO
	_debug_last_damping_force_world = Vector3.ZERO


func set_debug_thrust_force_world(value: Vector3) -> void:
	_debug_last_thrust_force_world = value


func set_debug_lift_force_world(value: Vector3) -> void:
	_debug_last_lift_force_world = value


func set_debug_drag_force_world(value: Vector3) -> void:
	_debug_last_drag_force_world = value


func set_debug_side_force_world(value: Vector3) -> void:
	_debug_last_side_force_world = value


func set_debug_gravity_force_world(value: Vector3) -> void:
	_debug_last_gravity_force_world = value


func set_debug_damping_force_world(value: Vector3) -> void:
	_debug_last_damping_force_world = value


func get_debug_force_balance_terms() -> Dictionary:
	return {
		"thrust": _debug_last_thrust_force_world,
		"lift": _debug_last_lift_force_world,
		"drag": _debug_last_drag_force_world,
		"side": _debug_last_side_force_world,
		"gravity": _debug_last_gravity_force_world,
		"damping": _debug_last_damping_force_world,
	}


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
	return _force_debug.get_force_balance_snapshot()


func is_hostile_to(other: Node) -> bool:
	if other == null or not is_instance_valid(other):
		return true
	if other == self:
		return false
	if not ("team_id" in other):
		return true
	var other_team_id := int(other.get("team_id"))
	if team_id <= 0 or other_team_id <= 0:
		return true
	return other_team_id != team_id


func get_throttle_percent() -> float:
	return throttle_percent


func get_aoa_deg() -> float:
	return aoa_deg


func get_max_lift_aoa_exceedance_ratio() -> float:
	if _positive_max_lift_aoa_deg <= _negative_max_lift_aoa_deg:
		return 0.0

	var fade_degrees := maxf(max_lift_turn_limiter_fade_deg, 0.001)
	if aoa_deg > _positive_max_lift_aoa_deg:
		return clampf((aoa_deg - _positive_max_lift_aoa_deg) / fade_degrees, 0.0, 1.0)
	if aoa_deg < _negative_max_lift_aoa_deg:
		return clampf((_negative_max_lift_aoa_deg - aoa_deg) / fade_degrees, 0.0, 1.0)
	return 0.0


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


func get_frame_forward_axis() -> Vector3:
	return _frame_forward_axis


func get_frame_up_axis() -> Vector3:
	return _frame_up_axis


func get_local_angular_velocity() -> Vector3:
	return _frame_body_basis.transposed() * angular_velocity


func get_local_roll_rate() -> float:
	return get_local_angular_velocity().z


func get_local_pitch_rate() -> float:
	return get_local_angular_velocity().x


func get_local_yaw_rate() -> float:
	return get_local_angular_velocity().y


func get_best_climb_speed_vy() -> float:
	return _flight_model.get_best_climb_speed_vy()


func is_best_climb_speed_vy_valid() -> bool:
	return _flight_model.is_best_climb_speed_vy_valid()


func is_sustain_turn_using_vy() -> bool:
	return _flight_model.is_sustain_turn_using_vy()


func get_cached_best_climb_speed_vy() -> float:
	return _best_climb_speed_vy


func is_cached_best_climb_speed_vy_valid() -> bool:
	return _best_climb_speed_vy_valid


func is_using_sustain_turn_vy() -> bool:
	return _sustain_turn_using_vy


func set_cached_best_climb_speed_vy(value: float, valid: bool) -> void:
	_best_climb_speed_vy = value
	_best_climb_speed_vy_valid = valid


func get_sustain_turn_vy_update_timer() -> float:
	return _sustain_turn_vy_update_timer


func set_sustain_turn_vy_update_timer(value: float) -> void:
	_sustain_turn_vy_update_timer = value


func set_sustain_turn_using_vy(value: bool) -> void:
	_sustain_turn_using_vy = value


func get_last_ground_impact_time() -> float:
	return _last_ground_impact_time


func set_last_ground_impact_time(value: float) -> void:
	_last_ground_impact_time = value


func get_roll_input_for_error(
	roll_error: float,
	angle_to_rate_gain: float,
	max_desired_rate: float,
	rate_response_gain: float,
	rate_scale: float = 1.0
) -> float:
	return _flight_model.get_roll_input_for_error(
		roll_error,
		angle_to_rate_gain,
		max_desired_rate,
		rate_response_gain,
		rate_scale
	)


func get_roll_error_for_target_up(target_up_world: Vector3) -> float:
	return _flight_model.get_roll_error_for_target_up(target_up_world)


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
	return _flight_model.get_rate_stabilized_axis_input(
		angle_error,
		angle_to_rate_gain,
		max_desired_rate,
		local_rate,
		rate_response_gain,
		error_to_rate_sign,
		input_sign,
		rate_scale
	)


func get_rate_stabilized_input_for_desired_rate(
	desired_rate: float,
	local_rate: float,
	rate_response_gain: float,
	input_sign: float
) -> float:
	return _flight_model.get_rate_stabilized_input_for_desired_rate(
		desired_rate,
		local_rate,
		rate_response_gain,
		input_sign
	)


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
	return _flight_model.get_turn_limited_pitch_input(raw_pitch_input)


func _get_effective_pitch_input() -> float:
	return _flight_model.get_effective_pitch_input()


func is_pitch_assist_enabled() -> bool:
	return _pitch_assist_enabled


func is_stabilization_assist_enabled() -> bool:
	return _stabilization_assist_enabled


func is_input_decay_enabled() -> bool:
	return _input_decay_enabled


func _update_best_climb_speed_vy(delta: float) -> void:
	_flight_model.update_best_climb_speed_vy(delta)


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
	apply_aero_tables_payload(AERO_TABLES_STORE.load_payload())


func get_aero_tables_payload() -> Dictionary:
	return {
		"lift_table": AERO_TABLES_STORE.encode_points(lift_coefficient_table),
		"drag_table": AERO_TABLES_STORE.encode_points(drag_coefficient_table),
		"control_authority_table": AERO_TABLES_STORE.encode_points(control_authority_coefficient_table),
		"thrust_table": AERO_TABLES_STORE.encode_points(thrust_coefficient_table),
	}


func apply_aero_tables_payload(payload: Dictionary) -> void:
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
