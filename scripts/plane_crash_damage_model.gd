class_name PlaneCrashDamageModel
extends RefCounted

var _plane: PlaneCharacter


func _init(plane: PlaneCharacter) -> void:
	_plane = plane


func handle_ground_impact_collision(collision: KinematicCollision3D, movement_velocity_world: Vector3) -> void:
	if _plane.is_shot_down or not _plane._is_simulated_locally():
		return

	var now_seconds := Time.get_ticks_msec() / 1000.0
	if now_seconds - _plane.get_last_ground_impact_time() < _plane.GROUND_IMPACT_COOLDOWN_SECONDS:
		return

	var impact_speed := movement_velocity_world.length()
	if impact_speed <= _plane.ground_impact_damage_speed_threshold:
		return

	if collision == null:
		return

	var collider := collision.get_collider() as Node
	if not is_instance_valid(collider) or not _is_ground_body(collider):
		return

	var impact_angle_deg := get_surface_impact_angle_deg(collision.get_normal(), movement_velocity_world)
	if impact_angle_deg < 0.0:
		return

	_plane.set_last_ground_impact_time(now_seconds)

	if _plane.multiplayer.multiplayer_peer == null or _plane.multiplayer.is_server():
		apply_ground_impact_damage(impact_speed, impact_angle_deg)


func apply_ground_impact_damage(impact_speed: float, impact_angle_deg: float) -> void:
	if _plane.is_shot_down:
		return

	var health = _plane.get_health_component()
	if health == null:
		return

	var fatal_speed_threshold := maxf(
		_plane.ground_impact_fatal_speed_threshold,
		_plane.ground_impact_damage_speed_threshold
	)
	if (
		impact_speed >= fatal_speed_threshold and
		impact_angle_deg >= maxf(_plane.ground_impact_fatal_surface_angle_deg, 0.0)
	):
		health.take_damage(health.max_hp)
		return

	if impact_speed <= _plane.ground_impact_damage_speed_threshold:
		return

	var speed_span := maxf(
		fatal_speed_threshold - _plane.ground_impact_damage_speed_threshold,
		0.001
	)
	var damage_ratio := clampf(
		(impact_speed - _plane.ground_impact_damage_speed_threshold) / speed_span,
		0.0,
		1.0
	)
	var damage_amount := _plane.ground_impact_max_damage * damage_ratio
	if damage_amount > 0.0:
		health.take_damage(damage_amount)


func get_surface_impact_angle_deg(
	surface_normal_world: Vector3,
	movement_velocity_world: Vector3
) -> float:
	var normal_length_squared := surface_normal_world.length_squared()
	var speed_squared := movement_velocity_world.length_squared()
	if normal_length_squared <= 0.000001 or speed_squared <= 0.000001:
		return -1.0

	var normalized_surface_normal := surface_normal_world / sqrt(normal_length_squared)
	var movement_direction := movement_velocity_world / sqrt(speed_squared)
	var perpendicular_ratio := clampf(absf(normalized_surface_normal.dot(movement_direction)), 0.0, 1.0)
	return rad_to_deg(asin(perpendicular_ratio))


func _is_ground_body(body: Node) -> bool:
	return body is StaticBody3D
