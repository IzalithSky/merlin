extends Node

@export var desired_range: float = 100.0
@export var range_tolerance: float = 50.0
@export var orbit_direction: float = 1.0
@export var orbit_radial_pull: float = 0.35
@export var orbit_vertical_correction: float = 0.002

@export var max_speed: float = 250.0
@export var max_lift_turn_min_speed: float = 160.0
@export var speed_recovery_enter_speed: float = 80.0
@export var speed_recovery_exit_speed: float = 120.0
@export var speed_recovery_min_nose_down_input: float = 0.25
@export var speed_recovery_max_nose_down_input: float = 0.95
@export var speed_recovery_pitch_response_rate: float = 1.2
@export var speed_recovery_max_descent_speed: float = 80.0
@export var speed_recovery_altitude_soft_floor: float = 240.0
@export var speed_recovery_altitude_hard_floor: float = 150.0
@export var speed_recovery_max_dive_angle_deg: float = 60.0
@export var speed_recovery_flight_path_kp: float = 2.1
@export var speed_recovery_flight_path_kd: float = 0.9
@export var speed_recovery_pitch_rate_damping: float = 0.2
@export var speed_recovery_speed_trend_damping: float = 0.1
@export var speed_recovery_max_nose_up_input: float = 0.35
@export var speed_recovery_accel_smoothing: float = 0.1

@export var minimum_safe_altitude: float = 180.0
@export var terrain_prediction_time: float = 2.4
@export var terrain_probe_min_distance: float = 180.0
@export var terrain_escape_pitch_up_input: float = -0.85
@export var terrain_escape_yaw_weight: float = 0.7
@export var terrain_parallel_escape_max_forward_speed: float = 80.0

@export var roll_gain: float = 1.8
@export var pitch_gain: float = 1.2
@export var yaw_gain: float = 1.0
@export var pursuit_lag_max_range: float = 300.0
@export var pursuit_lead_min_range: float = 600.0
@export var pursuit_high_closure_speed: float = 35.0
@export var pursuit_low_closure_speed: float = -25.0
@export var pursuit_tail_aspect_for_pure_deg: float = 35.0
@export var pursuit_lead_time_scale: float = 0.35
@export var pursuit_min_lead_time: float = 0.05
@export var pursuit_max_lead_time: float = 0.9
@export var pursuit_lag_offset_min: float = 100.0
@export var pursuit_lag_offset_max: float = 420.0
@export var target_reacquire_interval: float = 0.4
@export var prefer_singleplayer_player_target := true
@export var bot_peer_id_base := 1000000
@export var debug_label_enabled := true
@export var debug_label_height: float = -16.0
@export var debug_label_pixel_size: float = 0.001

@export var follow_target_path: NodePath

const INTENT_TYPE_DIRECTION := "direction"
const INTENT_TYPE_CONTROLS := "controls"
const BOT_MODE_TERRAIN_ESCAPE := "terrain_escape"
const BOT_MODE_SPEED_RECOVERY := "speed_recovery"
const BOT_MODE_IDLE := "idle"
const BOT_MODE_APPROACH := "approach"
const BOT_MODE_ORBIT := "orbit"
const BOT_MODE_TARGET_STATIONARY := "target_stationary"
const PURSUIT_MODE_LAG := "lag"
const PURSUIT_MODE_PURE := "pure"
const PURSUIT_MODE_LEAD := "lead"
const MIN_REFERENCE_MOVEMENT_SPEED := 1.0
const MIN_DIRECTION_VECTOR_LENGTH_SQUARED := 0.000001
const FULL_THROTTLE_INPUT := 1.0
const CUT_THROTTLE_INPUT := -1.0

var _plane: RigidBody3D
var _follow_target: Node3D
var _fallback_follow_target: Node3D
var _follow_target_is_player := false
var _reacquire_timer := 0.0
var _exclude_rids: Array[RID] = []
var _speed_recovery_active := false
var _speed_recovery_pitch_command := 0.0
var _last_forward_speed := 0.0
var _speed_recovery_forward_accel := 0.0
var _speed_recovery_last_dive_angle := 0.0
var _debug_label: Label3D
var _debug_player_target: Node3D


func _ready() -> void:
	_plane = get_parent() as RigidBody3D
	if _plane == null:
		set_physics_process(false)
		return

	_exclude_rids = [_plane.get_rid()]
	_last_forward_speed = _get_forward_speed()
	_resolve_follow_target(true)


func set_follow_target(target: Node3D = null) -> void:
	_fallback_follow_target = target
	_follow_target = target
	_follow_target_is_player = false


func _physics_process(delta: float) -> void:
	if _plane == null:
		return

	var perception := _build_perception(delta)
	var forward_speed: float = perception["forward_speed"]
	_update_forward_speed_trend(forward_speed, delta)
	_update_sustain_turn_limiter_mode(forward_speed)

	var safety_intent := _build_safety_intent(perception)
	if not safety_intent.is_empty():
		_apply_intent_and_update_label(safety_intent, perception)
		return

	_update_speed_recovery_state(forward_speed)
	if _speed_recovery_active:
		_apply_intent_and_update_label(_build_speed_recovery_intent(perception, delta), perception)
		return

	var tactical_mode := _choose_tactical_mode(perception)
	var guidance_intent := _build_guidance_intent(tactical_mode, perception)
	_apply_intent_and_update_label(guidance_intent, perception)


func _build_perception(delta: float) -> Dictionary:
	_update_follow_target(delta)

	var forward_speed := _get_forward_speed()
	var linear_velocity := _plane.linear_velocity
	var linear_speed := linear_velocity.length()
	var nose_forward := -_plane.global_transform.basis.z.normalized()
	var has_target := is_instance_valid(_follow_target)
	var target_offset := Vector3.ZERO
	var target_distance: float = INF
	var target_direction := Vector3.ZERO
	var target_velocity := Vector3.ZERO
	var target_speed := 0.0
	var target_forward := Vector3.FORWARD
	var closure_speed := 0.0
	var target_aspect_deg := 0.0
	var target_tail_angle_deg := 180.0

	if has_target:
		target_offset = _follow_target.global_position - _plane.global_position
		target_distance = target_offset.length()
		if target_distance > 0.001:
			target_direction = target_offset / target_distance
			target_velocity = _get_target_linear_velocity(_follow_target)
			target_speed = target_velocity.length()
			target_forward = (-_follow_target.global_transform.basis.z).normalized()
			var relative_velocity := target_velocity - linear_velocity
			closure_speed = -relative_velocity.dot(target_direction)
			var target_to_bot := -target_direction
			target_aspect_deg = rad_to_deg(target_forward.angle_to(target_to_bot))
			target_tail_angle_deg = 180.0 - target_aspect_deg

	return {
		"forward_speed": forward_speed,
		"linear_velocity": linear_velocity,
		"linear_speed": linear_speed,
		"nose_forward": nose_forward,
		"has_target": has_target,
		"target_offset": target_offset,
		"target_distance": target_distance,
		"target_direction": target_direction,
		"target_is_player": _follow_target_is_player,
		"target_velocity": target_velocity,
		"target_speed": target_speed,
		"target_forward": target_forward,
		"closure_speed": closure_speed,
		"target_aspect_deg": target_aspect_deg,
		"target_tail_angle_deg": target_tail_angle_deg,
	}


func _build_safety_intent(perception: Dictionary) -> Dictionary:
	var terrain_response := _get_terrain_avoidance_response(perception)
	if terrain_response["active"]:
		_speed_recovery_pitch_command = 0.0
		var intent: Dictionary = {
			"type": INTENT_TYPE_DIRECTION,
			"mode": BOT_MODE_TERRAIN_ESCAPE,
			"desired_direction": terrain_response["direction"],
		}
		if terrain_response.has("pitch_upper_limit"):
			intent["pitch_upper_limit"] = terrain_response["pitch_upper_limit"]
		if terrain_response.has("yaw_multiplier"):
			intent["yaw_multiplier"] = terrain_response["yaw_multiplier"]
		return intent

	return {}


func _choose_tactical_mode(perception: Dictionary) -> String:
	if not bool(perception["has_target"]):
		return BOT_MODE_IDLE

	var target_distance: float = perception["target_distance"]
	if target_distance <= 0.001:
		return BOT_MODE_TARGET_STATIONARY

	if bool(perception["target_is_player"]):
		return BOT_MODE_APPROACH

	if target_distance <= desired_range + range_tolerance:
		return BOT_MODE_ORBIT

	return BOT_MODE_APPROACH


func _build_guidance_intent(tactical_mode: String, perception: Dictionary) -> Dictionary:
	match tactical_mode:
		BOT_MODE_APPROACH:
			return _build_approach_intent(perception)
		BOT_MODE_ORBIT:
			return _build_orbit_intent(perception)
		BOT_MODE_TARGET_STATIONARY:
			return _make_controls_intent(BOT_MODE_TARGET_STATIONARY, 0.0, 0.0, 0.0)
		_:
			return _make_controls_intent(BOT_MODE_IDLE, 0.0, 0.0, 0.0)


func _build_approach_intent(perception: Dictionary) -> Dictionary:
	var pursuit_mode := _choose_pursuit_mode(perception)
	var target_direction := _get_pursuit_direction(pursuit_mode, perception)

	var intent := _make_direction_intent(BOT_MODE_APPROACH, target_direction)
	intent["pursuit_mode"] = pursuit_mode
	return intent


func _choose_pursuit_mode(perception: Dictionary) -> String:
	var target_distance: float = perception["target_distance"]
	var closure_speed: float = perception["closure_speed"]
	var target_tail_angle_deg: float = perception["target_tail_angle_deg"]
	var target_speed: float = perception["target_speed"]
	var high_aspect := target_tail_angle_deg > pursuit_tail_aspect_for_pure_deg
	var close_range := target_distance <= pursuit_lag_max_range
	var far_range := target_distance >= pursuit_lead_min_range
	var closing_fast := closure_speed >= pursuit_high_closure_speed
	var opening := closure_speed <= pursuit_low_closure_speed

	if target_speed <= MIN_REFERENCE_MOVEMENT_SPEED:
		return PURSUIT_MODE_PURE

	if close_range and (closing_fast or high_aspect):
		return PURSUIT_MODE_LAG

	if opening:
		return PURSUIT_MODE_LEAD

	if far_range and high_aspect:
		return PURSUIT_MODE_LEAD

	return PURSUIT_MODE_PURE


func _get_pursuit_direction(pursuit_mode: String, perception: Dictionary) -> Vector3:
	var target_offset: Vector3 = perception["target_offset"]
	var target_direction: Vector3 = perception["target_direction"]
	if target_offset.length_squared() <= MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		return target_direction

	var aim_point := _plane.global_position + target_offset
	match pursuit_mode:
		PURSUIT_MODE_LEAD:
			aim_point = _get_lead_pursuit_aim_point(perception)
		PURSUIT_MODE_LAG:
			aim_point = _get_lag_pursuit_aim_point(perception)
		_:
			pass

	var aim_offset := aim_point - _plane.global_position
	if aim_offset.length_squared() <= MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		return target_direction

	return aim_offset.normalized()


func _get_lead_pursuit_aim_point(perception: Dictionary) -> Vector3:
	var target_offset: Vector3 = perception["target_offset"]
	var target_velocity: Vector3 = perception["target_velocity"]
	var target_distance: float = perception["target_distance"]
	var linear_speed: float = perception["linear_speed"]
	var target_speed: float = perception["target_speed"]
	var closure_speed: float = perception["closure_speed"]
	var reference_speed := maxf(maxf(linear_speed, target_speed), 1.0)
	if closure_speed > 0.0:
		reference_speed += closure_speed

	var min_lead_time := maxf(pursuit_min_lead_time, 0.0)
	var max_lead_time := maxf(pursuit_max_lead_time, min_lead_time)
	var lead_time := clampf(
		(target_distance / reference_speed) * maxf(pursuit_lead_time_scale, 0.0),
		min_lead_time,
		max_lead_time
	)

	return _plane.global_position + target_offset + target_velocity * lead_time


func _get_lag_pursuit_aim_point(perception: Dictionary) -> Vector3:
	var target_offset: Vector3 = perception["target_offset"]
	var target_distance: float = perception["target_distance"]
	var target_velocity: Vector3 = perception["target_velocity"]
	var target_forward: Vector3 = perception["target_forward"]
	var closure_speed: float = perception["closure_speed"]
	var lag_axis := target_forward
	if target_velocity.length_squared() > MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		lag_axis = target_velocity.normalized()

	var closure_ratio := 0.0
	if pursuit_high_closure_speed > 0.0:
		closure_ratio = clampf(closure_speed / pursuit_high_closure_speed, 0.0, 1.0)

	var lag_fraction := lerpf(0.45, 0.75, closure_ratio)
	var min_lag_offset := maxf(pursuit_lag_offset_min, 0.0)
	var max_lag_offset := maxf(pursuit_lag_offset_max, min_lag_offset)
	var lag_offset := clampf(
		target_distance * lag_fraction,
		min_lag_offset,
		max_lag_offset
	)

	return _plane.global_position + target_offset - lag_axis * lag_offset


func _build_orbit_intent(perception: Dictionary) -> Dictionary:
	var target_direction: Vector3 = perception["target_direction"]
	var target_distance: float = perception["target_distance"]
	var radial_from_target := -target_direction
	var tangent := Vector3.UP.cross(radial_from_target)
	if tangent.length_squared() < 0.00001:
		tangent = _plane.global_transform.basis.x
	else:
		tangent = tangent.normalized()

	var outward_error := clampf((desired_range - target_distance) / maxf(range_tolerance, 1.0), -1.0, 1.0)
	var inward_pull := radial_from_target * (orbit_radial_pull * outward_error)
	var target_offset: Vector3 = perception["target_offset"]
	var altitude_error := target_offset.y * orbit_vertical_correction
	var altitude_adjust := Vector3.UP * altitude_error
	var orbit_sign := 1.0 if orbit_direction >= 0.0 else -1.0
	var orbit_direction_world := ((tangent * orbit_sign) + inward_pull + altitude_adjust).normalized()
	return _make_direction_intent(BOT_MODE_ORBIT, orbit_direction_world)


func _make_direction_intent(intent_mode: String, desired_direction: Vector3) -> Dictionary:
	return {
		"type": INTENT_TYPE_DIRECTION,
		"mode": intent_mode,
		"desired_direction": desired_direction,
	}


func _make_controls_intent(intent_mode: String, roll_value: float, pitch_value: float, yaw_value: float) -> Dictionary:
	return {
		"type": INTENT_TYPE_CONTROLS,
		"mode": intent_mode,
		"roll": roll_value,
		"pitch": pitch_value,
		"yaw": yaw_value,
	}


func _update_follow_target(delta: float) -> void:
	if not is_instance_valid(_follow_target):
		_follow_target = null
		_follow_target_is_player = false

	if not is_instance_valid(_fallback_follow_target):
		_fallback_follow_target = null

	_reacquire_timer += delta
	if _reacquire_timer < maxf(target_reacquire_interval, 0.0) and _follow_target != null:
		return

	_reacquire_timer = 0.0
	var player_target := _find_singleplayer_player_target()
	if player_target != null:
		_follow_target = player_target
		_follow_target_is_player = true
		return

	_follow_target_is_player = false
	if _fallback_follow_target != null:
		_follow_target = _fallback_follow_target
		return

	_resolve_follow_target(false)


func _find_singleplayer_player_target() -> Node3D:
	if not prefer_singleplayer_player_target:
		return null

	if multiplayer.multiplayer_peer != null:
		return null

	if _plane == null:
		return null

	var search_root := _plane.get_parent()
	if search_root == null:
		return null

	var best_target: Node3D = null
	var best_distance := INF
	for candidate in search_root.get_children():
		if candidate == _plane:
			continue

		if not candidate is Node3D:
			continue

		if _is_bot_character(candidate):
			continue

		var candidate_node := candidate as Node3D
		var distance := candidate_node.global_position.distance_to(_plane.global_position)
		if distance < best_distance:
			best_distance = distance
			best_target = candidate_node

	return best_target


func _is_bot_character(candidate: Node) -> bool:
	var candidate_peer_id_value: Variant = candidate.get("peer_id")
	if candidate_peer_id_value == null:
		return false

	return int(candidate_peer_id_value) >= bot_peer_id_base


func _get_target_linear_velocity(target: Node3D) -> Vector3:
	if target is RigidBody3D:
		var rigid_body := target as RigidBody3D
		return rigid_body.linear_velocity

	if target is CharacterBody3D:
		var character_body := target as CharacterBody3D
		return character_body.velocity

	return Vector3.ZERO


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

	# Above this independent threshold the bot may pull to max-lift AoA; below it, preserve energy.
	var should_use_sustain_turns := forward_speed <= max_lift_turn_min_speed
	_plane.call("set_sustain_turn_limiter_runtime_enabled", should_use_sustain_turns)


func _build_speed_recovery_intent(perception: Dictionary, delta: float) -> Dictionary:
	var forward_speed: float = perception["forward_speed"]
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
	return _make_controls_intent(BOT_MODE_SPEED_RECOVERY, 0.0, _speed_recovery_pitch_command, 0.0)


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
	if desired_direction.length_squared() <= MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
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


func _get_terrain_avoidance_response(perception: Dictionary) -> Dictionary:
	var current_velocity: Vector3 = perception["linear_velocity"]
	var current_speed: float = perception["linear_speed"]
	var nose_forward: Vector3 = perception["nose_forward"]
	var use_parallel_escape := _should_use_terrain_parallel_escape(perception)

	var probe_direction := nose_forward
	if current_speed > 1.0:
		probe_direction = current_velocity / current_speed

	var probe_distance := maxf(terrain_probe_min_distance, current_speed * terrain_prediction_time)
	var forward_start := _plane.global_position + Vector3.UP * 3.0
	var forward_end := forward_start + (probe_direction * probe_distance)
	var forward_hit := _intersect_ray(forward_start, forward_end)
	if not forward_hit.is_empty():
		var hit_normal: Vector3 = forward_hit.get("normal", Vector3.UP)
		if use_parallel_escape:
			return _make_terrain_parallel_response(perception, hit_normal)

		var avoid_direction := (hit_normal + Vector3.UP * 0.7).normalized()
		return {
			"active": true,
			"direction": avoid_direction,
			"pitch_upper_limit": terrain_escape_pitch_up_input,
			"yaw_multiplier": terrain_escape_yaw_weight,
		}

	var down_start := _plane.global_position
	var down_end := down_start + Vector3.DOWN * minimum_safe_altitude
	var down_hit := _intersect_ray(down_start, down_end)
	if not down_hit.is_empty():
		if use_parallel_escape:
			var ground_normal: Vector3 = down_hit.get("normal", Vector3.UP)
			return _make_terrain_parallel_response(perception, ground_normal)

		var climb_direction := (nose_forward + Vector3.UP * 1.6).normalized()
		return {
			"active": true,
			"direction": climb_direction,
			"pitch_upper_limit": terrain_escape_pitch_up_input,
			"yaw_multiplier": terrain_escape_yaw_weight,
		}

	return {
		"active": false,
		"direction": Vector3.ZERO,
	}


func _should_use_terrain_parallel_escape(perception: Dictionary) -> bool:
	var max_parallel_speed := maxf(terrain_parallel_escape_max_forward_speed, 0.0)
	if max_parallel_speed <= 0.0:
		return false

	var forward_speed: float = perception["forward_speed"]
	return absf(forward_speed) <= max_parallel_speed


func _make_terrain_parallel_response(perception: Dictionary, terrain_normal: Vector3) -> Dictionary:
	return {
		"active": true,
		"direction": _get_terrain_parallel_direction(perception, terrain_normal),
		"yaw_multiplier": terrain_escape_yaw_weight,
	}


func _get_terrain_parallel_direction(perception: Dictionary, terrain_normal: Vector3) -> Vector3:
	var normal := terrain_normal
	if normal.length_squared() <= MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		normal = Vector3.UP
	else:
		normal = normal.normalized()

	var current_velocity: Vector3 = perception["linear_velocity"]
	var current_speed: float = perception["linear_speed"]
	var reference_direction: Vector3 = perception["nose_forward"]
	if current_speed > MIN_REFERENCE_MOVEMENT_SPEED:
		reference_direction = current_velocity / current_speed

	var tangent_direction := _project_direction_on_plane(reference_direction, normal)
	if tangent_direction.length_squared() > MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		return tangent_direction.normalized()

	var plane_right := _plane.global_transform.basis.x.normalized()
	tangent_direction = _project_direction_on_plane(plane_right, normal)
	if tangent_direction.length_squared() > MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		var nose_forward: Vector3 = perception["nose_forward"]
		if tangent_direction.dot(nose_forward) < 0.0:
			tangent_direction = -tangent_direction
		return tangent_direction.normalized()

	tangent_direction = normal.cross(Vector3.UP)
	if tangent_direction.length_squared() <= MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		tangent_direction = normal.cross(Vector3.RIGHT)

	return tangent_direction.normalized()


func _project_direction_on_plane(direction: Vector3, plane_normal: Vector3) -> Vector3:
	return direction - plane_normal * direction.dot(plane_normal)


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


func _apply_intent_and_update_label(intent: Dictionary, perception: Dictionary) -> void:
	_apply_intent(intent)
	_update_debug_label(intent, perception)


func _apply_intent(intent: Dictionary) -> void:
	var intent_type: String = intent.get("type", INTENT_TYPE_CONTROLS)
	var throttle_input := _get_bot_throttle_input()

	if intent_type == INTENT_TYPE_CONTROLS:
		_apply_controls(
			float(intent.get("roll", 0.0)),
			float(intent.get("pitch", 0.0)),
			float(intent.get("yaw", 0.0)),
			throttle_input
		)
		return

	var desired_direction: Vector3 = intent.get("desired_direction", -_plane.global_transform.basis.z)
	var controls := _controls_from_world_direction(desired_direction)
	var roll_value: float = controls["roll"]
	var pitch_value: float = controls["pitch"]
	var yaw_value: float = controls["yaw"]

	if intent.has("pitch_upper_limit"):
		pitch_value = minf(pitch_value, float(intent["pitch_upper_limit"]))

	if intent.has("yaw_multiplier"):
		yaw_value *= float(intent["yaw_multiplier"])

	_apply_controls(roll_value, pitch_value, yaw_value, throttle_input)


func _get_bot_throttle_input() -> float:
	if max_speed > 0.0 and _plane.linear_velocity.length() > max_speed:
		return CUT_THROTTLE_INPUT

	return FULL_THROTTLE_INPUT


func _ensure_debug_label() -> void:
	if not debug_label_enabled:
		if _debug_label != null:
			_debug_label.visible = false
		return

	if _debug_label != null:
		if not _debug_label.is_inside_tree():
			if not _plane.is_inside_tree():
				return
			_plane.add_child(_debug_label)
		_debug_label.visible = true
		return

	if not _plane.is_inside_tree():
		return

	_debug_label = Label3D.new()
	_debug_label.name = "BotDebugLabel"
	_debug_label.set_as_top_level(true)
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.fixed_size = true
	_debug_label.no_depth_test = true
	_debug_label.pixel_size = debug_label_pixel_size
	_debug_label.font_size = 18
	_debug_label.outline_size = 8
	_debug_label.modulate = Color(0.55, 1.0, 0.0, 1.0)
	_debug_label.outline_modulate = Color(0.02, 0.02, 0.02, 0.95)
	_debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_debug_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_plane.add_child(_debug_label)


func _update_debug_label(intent: Dictionary, perception: Dictionary) -> void:
	_ensure_debug_label()
	if _debug_label == null or not _debug_label.visible or not _debug_label.is_inside_tree():
		return

	var logic_state := _get_debug_logic_state(intent)
	var forward_speed: float = perception["forward_speed"]
	var player_distance := _get_debug_player_distance(perception)
	var distance_text := "--"
	if player_distance < INF:
		distance_text = "%.0f m" % player_distance

	_debug_label.global_position = _plane.global_position + Vector3.UP * debug_label_height
	_debug_label.text = "State: %s\nFwd: %.1f m/s\nMe: %s" % [
		logic_state,
		forward_speed,
		distance_text,
	]


func _get_debug_logic_state(intent: Dictionary) -> String:
	var logic_state := str(intent.get("mode", "unknown"))
	if intent.has("pursuit_mode"):
		logic_state = "%s/%s" % [logic_state, str(intent["pursuit_mode"])]

	if _get_bot_throttle_input() == CUT_THROTTLE_INPUT:
		logic_state = "%s/cut" % logic_state

	return logic_state


func _get_debug_player_distance(perception: Dictionary) -> float:
	if bool(perception["target_is_player"]):
		var target_distance: float = perception["target_distance"]
		if target_distance < INF:
			return target_distance

	if not is_instance_valid(_debug_player_target):
		_debug_player_target = _find_local_player_character()

	if _debug_player_target == null:
		return INF

	return _plane.global_position.distance_to(_debug_player_target.global_position)


func _find_local_player_character() -> Node3D:
	for candidate in get_tree().get_nodes_in_group("player_character"):
		if candidate == _plane:
			continue

		if not candidate is Node3D:
			continue

		var local_player_value: Variant = candidate.get("is_local_player")
		if local_player_value != null and bool(local_player_value):
			return candidate as Node3D

	return null


func _apply_controls(roll_value: float, pitch_value: float, yaw_value: float, throttle_value: float) -> void:
	if _plane.has_method("set_bot_control_inputs"):
		_plane.call(
			"set_bot_control_inputs",
			clampf(roll_value, -1.0, 1.0),
			clampf(pitch_value, -1.0, 1.0),
			clampf(yaw_value, -1.0, 1.0),
			clampf(throttle_value, -1.0, 1.0)
		)
