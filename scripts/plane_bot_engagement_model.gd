class_name PlaneBotEngagementModel
extends RefCounted

var _pilot: PlaneBotPilot
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
var _collision_avoidance_direction := 0.0
var _collision_avoidance_exit_time := 0.0
var _cached_player_characters: Array[Node3D] = []
var _cached_missiles: Array[Node3D] = []
var _next_group_cache_refresh_time := 0.0


func _init(pilot: PlaneBotPilot) -> void:
	_pilot = pilot


func set_follow_target(target: Node3D = null, use_killzone: bool = false) -> void:
	_fallback_follow_target = target
	_fallback_follow_target_uses_killzone = use_killzone
	if not _follow_target_is_player:
		_set_active_follow_target(target, false, use_killzone)


func get_collision_avoidance_direction() -> float:
	return _collision_avoidance_direction


func update_collision_threat() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var threat_direction := _find_collision_threat()
	if threat_direction != 0.0:
		_collision_avoidance_direction = threat_direction
		_collision_avoidance_exit_time = now + _pilot.COLLISION_AVOIDANCE_MIN_DURATION
	elif now >= _collision_avoidance_exit_time:
		_collision_avoidance_direction = 0.0


func update_follow_target_velocity(delta: float) -> void:
	_update_player_target_acquisition(delta)
	if not has_follow_target():
		return

	var target_position := _follow_target.global_position
	if _follow_target is RigidBody3D:
		_follow_target_velocity = _get_node_velocity(_follow_target)
	elif _has_follow_target_sample and delta > 0.0:
		_follow_target_velocity = (target_position - _last_follow_target_position) / delta
	else:
		_follow_target_velocity = Vector3.ZERO

	_last_follow_target_position = target_position
	_has_follow_target_sample = true


func has_follow_target() -> bool:
	if is_instance_valid(_follow_target):
		return true

	_follow_target = null
	_follow_target_is_player = false
	_follow_target_uses_killzone = false
	_has_follow_target_sample = false
	_follow_target_velocity = Vector3.ZERO
	return false


func get_follow_throttle_target(destination_point: Vector3) -> float:
	var horizontal_offset := Vector2(
		destination_point.x - _pilot._frame_position.x,
		destination_point.z - _pilot._frame_position.z
	)
	var closure_speed := _get_follow_horizontal_closure_speed(horizontal_offset)
	if not _is_in_follow_brake_zone(destination_point, closure_speed):
		return _pilot.SPEED_RECOVERY_FULL_THROTTLE_INPUT

	var tolerance := maxf(_pilot.overshoot_closure_tolerance, 0.0)
	if closure_speed <= tolerance:
		return _pilot.SPEED_RECOVERY_FULL_THROTTLE_INPUT

	return clampf(-((closure_speed - tolerance) * maxf(_pilot.overshoot_throttle_gain, 0.0)), -1.0, 0.0)


func get_follow_destination_point() -> Vector3:
	if not has_follow_target():
		return Vector3.ZERO
	if _follow_target_uses_killzone:
		return _get_target_killzone_point(_follow_target)
	return _follow_target.global_position


func is_in_follow_killzone(killzone_point: Vector3) -> bool:
	var tolerance := maxf(_pilot.killzone_tolerance, 0.0)
	if tolerance <= 0.0:
		return false
	return _pilot._frame_position.distance_to(killzone_point) <= tolerance


func get_follow_alignment_direction() -> Vector3:
	if _follow_target_velocity.length_squared() > _pilot.MIN_DIRECTION_LENGTH_SQUARED:
		return _follow_target_velocity.normalized()
	if has_follow_target():
		return -_follow_target.global_transform.basis.z.normalized()
	return _pilot._frame_forward_axis


func get_follow_steering_point(destination_point: Vector3) -> Vector3:
	if not has_follow_target() or is_in_follow_killzone(destination_point):
		return destination_point
	if _follow_target_velocity.length_squared() <= _pilot.MIN_DIRECTION_LENGTH_SQUARED:
		return destination_point

	var offset := destination_point - _pilot._frame_position
	if offset.length_squared() <= _pilot.MIN_DIRECTION_LENGTH_SQUARED:
		return destination_point

	var range_to_slot := offset.length()
	var closing_speed := _get_follow_closing_speed(offset / range_to_slot)
	var time_to_go := clampf(
		range_to_slot / maxf(closing_speed, _pilot.FOLLOW_LEAD_MIN_CLOSING_SPEED),
		0.0,
		_pilot.FOLLOW_LEAD_MAX_TIME
	)
	return destination_point + _follow_target_velocity * time_to_go


func update_weapon_targeting() -> void:
	var weapon_lock = _pilot._plane.get_weapon_lock_component()
	if weapon_lock == null:
		return
	var raw_target: Node3D = _follow_target if has_follow_target() else null
	var plane_target := raw_target as PlaneCharacter
	if plane_target != null and plane_target.is_shot_down:
		raw_target = null
	var desired_target: Node3D = raw_target
	weapon_lock.set_desired_target(desired_target)
	if weapon_lock.is_locked():
		var launcher = _pilot._plane.get_missile_launcher_component()
		if launcher != null:
			launcher.try_fire()

	if _should_fire_autocannon(desired_target):
		var autocannon = _pilot._plane.get_autocannon_component()
		if autocannon != null:
			autocannon.try_fire()


func get_ground_probe_exclusions() -> Array[RID]:
	var now_seconds := Time.get_ticks_msec() / 1000.0
	if not _ground_probe_exclusions.is_empty() and now_seconds < _next_ground_probe_exclusion_refresh_time:
		return _ground_probe_exclusions

	_next_ground_probe_exclusion_refresh_time = now_seconds + _pilot.GROUND_PROBE_EXCLUSION_REFRESH_INTERVAL
	_ground_probe_exclusions = [_pilot._plane.get_rid()]
	_refresh_group_caches()
	for candidate in _cached_player_characters:
		if candidate is CollisionObject3D:
			_ground_probe_exclusions.append((candidate as CollisionObject3D).get_rid())

	return _ground_probe_exclusions


func get_debug_snapshot() -> Dictionary:
	var has_target := has_follow_target()
	var intent_position := Vector3.ZERO
	var source_target_position := Vector3.ZERO
	var has_killzone := false
	var killzone_position := Vector3.ZERO

	if has_target:
		source_target_position = _follow_target.global_position
		var destination_point := get_follow_destination_point()
		intent_position = get_follow_steering_point(destination_point)
		if _follow_target_uses_killzone:
			has_killzone = true
			killzone_position = destination_point

	return {
		"has_target": has_target,
		"intent_position": intent_position,
		"has_killzone": has_killzone,
		"killzone_position": killzone_position,
		"source_target_position": source_target_position,
	}


func get_follow_target_debug_label() -> String:
	if not has_follow_target():
		return "none"

	var identity := _follow_target.name
	var peer_id = _follow_target.get("peer_id")
	if peer_id != null:
		identity = "%s #%d" % [identity, peer_id]

	if _follow_target_uses_killzone:
		return "%s (killzone)" % identity
	return identity


func _set_active_follow_target(target: Node3D, target_is_player: bool, use_killzone: bool = false) -> void:
	_follow_target = target
	_follow_target_is_player = target_is_player
	_follow_target_uses_killzone = target_is_player or use_killzone
	_follow_target_velocity = Vector3.ZERO
	_has_follow_target_sample = false
	if _follow_target != null:
		_last_follow_target_position = _follow_target.global_position if _follow_target.is_inside_tree() else _follow_target.position
		_has_follow_target_sample = true


func _find_collision_threat() -> float:
	var scene_tree := _pilot.get_tree()
	if scene_tree == null or _pilot._plane == null:
		return 0.0

	_refresh_group_caches()
	var best_tca := INF
	var best_direction := 0.0

	for other in _cached_player_characters:
		if not is_instance_valid(other):
			continue
		if other == _pilot._plane:
			continue
		var other_vel := _get_node_velocity(other)

		var threat_direction := _get_collision_threat_direction(other, other_vel, best_tca)
		if threat_direction["detected"]:
			best_tca = threat_direction["tca"]
			best_direction = threat_direction["direction"]

	if _pilot.avoid_missiles:
		for missile in _cached_missiles:
			if not is_instance_valid(missile):
				continue
			var missile_vel := Vector3.ZERO
			if missile is RigidBody3D:
				missile_vel = (missile as RigidBody3D).linear_velocity

			var threat_direction := _get_collision_threat_direction(missile, missile_vel, best_tca)
			if threat_direction["detected"]:
				best_tca = threat_direction["tca"]
				best_direction = threat_direction["direction"]

	return best_direction


func _get_collision_threat_direction(other: Node3D, other_vel: Vector3, current_best_tca: float) -> Dictionary:
	if not is_instance_valid(other):
		return {"detected": false}

	var offset := other.global_position - _pilot._frame_position
	var distance := offset.length()
	var rel_vel := other_vel - _pilot._frame_velocity
	var closing_speed := rel_vel.length() if distance <= _pilot.MIN_DIRECTION_LENGTH_SQUARED else -offset.dot(rel_vel) / distance
	if closing_speed < _pilot.COLLISION_AVOIDANCE_MIN_CLOSING_SPEED:
		return {"detected": false}

	var rel_speed_sq := rel_vel.length_squared()
	if rel_speed_sq <= _pilot.MIN_DIRECTION_LENGTH_SQUARED:
		return {"detected": false}
	var tca := -offset.dot(rel_vel) / rel_speed_sq
	if tca < 0.0 or tca > _pilot.COLLISION_AVOIDANCE_LOOKAHEAD or tca >= current_best_tca:
		return {"detected": false}

	var cpa_offset := offset + rel_vel * tca
	if cpa_offset.length() > _pilot.COLLISION_AVOIDANCE_RADIUS:
		return {"detected": false}

	# Always break to the bot's own right (standard head-on avoidance). A fixed
	# handedness makes two converging planes diverge to opposite global sides;
	# choosing the side from the threat's bearing instead makes them mirror each
	# other into the same global direction and still collide.
	var direction := -1.0
	return {
		"detected": true,
		"tca": tca,
		"direction": direction,
	}


func _get_node_velocity(body: Node3D) -> Vector3:
	if not is_instance_valid(body):
		return Vector3.ZERO
	var plane := body as PlaneCharacter
	if plane != null:
		return plane.get_replicated_velocity()
	if body is RigidBody3D:
		return (body as RigidBody3D).linear_velocity
	return Vector3.ZERO


func _is_in_follow_brake_zone(destination_point: Vector3, closure_speed: float) -> bool:
	if closure_speed <= maxf(_pilot.overshoot_closure_tolerance, 0.0):
		return false

	var tolerance := maxf(_pilot.killzone_tolerance, 0.0)
	var brake_distance := tolerance * _pilot.FOLLOW_THROTTLE_BRAKE_DISTANCE_SCALE
	return _pilot._frame_position.distance_to(destination_point) <= brake_distance


func _get_follow_horizontal_closure_speed(horizontal_offset: Vector2) -> float:
	if horizontal_offset.length_squared() <= _pilot.MIN_DIRECTION_LENGTH_SQUARED:
		return 0.0

	var line_direction := horizontal_offset.normalized()
	var plane_velocity := Vector2(_pilot._frame_velocity.x, _pilot._frame_velocity.z)
	var target_velocity := Vector2(_follow_target_velocity.x, _follow_target_velocity.z)
	return (plane_velocity - target_velocity).dot(line_direction)


func _update_player_target_acquisition(delta: float) -> void:
	_player_target_reacquire_timer -= delta
	if _player_target_reacquire_timer > 0.0 and (_follow_target_is_player and has_follow_target()):
		return

	_player_target_reacquire_timer = _pilot.PLAYER_TARGET_REACQUIRE_INTERVAL
	var player_target := _find_player_target()
	if player_target != null:
		if player_target != _follow_target:
			_set_active_follow_target(player_target, true)
		return

	if _follow_target_is_player:
		_set_active_follow_target(_fallback_follow_target, false, _fallback_follow_target_uses_killzone)


func _find_player_target() -> Node3D:
	var scene_tree := _pilot.get_tree()
	if scene_tree == null or _pilot._plane == null:
		return null

	_refresh_group_caches()
	var best_target: Node3D
	var best_distance_squared := INF
	for candidate_node in _cached_player_characters:
		if not is_instance_valid(candidate_node):
			continue
		if candidate_node == _pilot._plane:
			continue
		if not _pilot._plane.is_hostile_to(candidate_node):
			continue
		if bool(candidate_node.get("is_shot_down")):
			continue

		var distance_squared := _pilot._frame_position.distance_squared_to(candidate_node.global_position)
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_target = candidate_node

	return best_target


func _is_bot_character(candidate: Node3D) -> bool:
	if not is_instance_valid(candidate):
		return false
	var plane := candidate as PlaneCharacter
	return plane != null and plane.is_bot_controlled


func _get_target_killzone_point(target: Node3D) -> Vector3:
	return target.global_position + _get_target_behind_direction(target) * maxf(_pilot.killzone_distance, 0.0)


func _get_target_behind_direction(target: Node3D) -> Vector3:
	var behind := target.global_transform.basis.z
	if behind.length_squared() <= _pilot.MIN_DIRECTION_LENGTH_SQUARED:
		return Vector3.BACK
	return behind.normalized()


func _get_follow_closing_speed(line_of_sight: Vector3) -> float:
	return (_pilot._frame_velocity - _follow_target_velocity).dot(line_of_sight)


func _should_fire_autocannon(target: Node3D) -> bool:
	if target == null or not is_instance_valid(target):
		return false

	var max_range: float = maxf(_pilot.autocannon_fire_max_range, 0.0)
	if max_range <= 0.0:
		return false

	var to_target: Vector3 = target.global_position - _pilot._frame_position
	var distance: float = to_target.length()
	if distance <= 0.001 or distance > max_range:
		return false

	var autocannon = _pilot._plane.get_autocannon_component()
	if autocannon == null:
		return false

	var cone_half_angle_deg: float = autocannon.lead_cone_half_angle_deg
	var forward_axis: Vector3 = _pilot._frame_forward_axis.normalized()
	var target_velocity := _get_node_velocity(target)
	var plane_velocity := _pilot._frame_velocity
	var relative_position := target.global_position - _pilot._frame_position
	var relative_velocity := target_velocity - plane_velocity
	var raw_direction: Vector3 = Autocannon._compute_intercept_direction(
		_pilot._frame_position,
		target.global_position,
		relative_position,
		relative_velocity,
		autocannon.bullet_speed
	)
	var angle: float = acos(clampf(forward_axis.dot(raw_direction), -1.0, 1.0))
	return angle <= deg_to_rad(cone_half_angle_deg)


func _refresh_group_caches() -> void:
	var scene_tree := _pilot.get_tree()
	if scene_tree == null:
		_cached_player_characters.clear()
		_cached_missiles.clear()
		return

	var now_seconds := Time.get_ticks_msec() / 1000.0
	if now_seconds < _next_group_cache_refresh_time:
		return

	_next_group_cache_refresh_time = now_seconds + _pilot.GROUP_CACHE_REFRESH_INTERVAL
	_cached_player_characters.clear()
	for candidate in scene_tree.get_nodes_in_group("player_character"):
		if candidate is Node3D and is_instance_valid(candidate):
			_cached_player_characters.append(candidate as Node3D)

	_cached_missiles.clear()
	if not _pilot.avoid_missiles:
		return

	for candidate in scene_tree.get_nodes_in_group("missile"):
		if candidate is Node3D and is_instance_valid(candidate):
			_cached_missiles.append(candidate as Node3D)
