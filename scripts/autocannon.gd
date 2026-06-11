extends Node

const BULLET_SCENE := preload("res://scenes/bullet.tscn")

@export var bullet_speed: float = 1000.0
@export var fire_cooldown: float = 0.125
@export var lead_cone_half_angle_deg: float = 30.0
@export var damage: float = 2.0

var _cooldown_remaining: float = 0.0
var _projectiles_container: Node = null


func _ready() -> void:
	_projectiles_container = get_tree().current_scene.get_node_or_null("projectiles")
	if _projectiles_container == null:
		push_warning("Autocannon: no 'projectiles' node found in scene root; bullets will be added to scene root")
		_projectiles_container = get_tree().current_scene


func _process(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining -= delta

	var plane := get_parent() as Node3D
	if plane == null or not is_instance_valid(plane):
		return
	if not _is_local_player(plane):
		return
	if plane.get("is_shot_down") == true:
		return
	if Input.is_action_pressed("fire_autocannon") and _cooldown_remaining <= 0.0:
		_try_fire(plane)


func try_fire() -> void:
	if _cooldown_remaining > 0.0:
		return
	var plane := get_parent() as Node3D
	if plane == null or not is_instance_valid(plane):
		return
	if plane.get("is_shot_down") == true:
		return
	_try_fire(plane)


func _try_fire(plane: Node3D) -> void:
	var desired_target: Node3D = null
	var weapon_lock := plane.get_node_or_null("PlaneWeaponLock")
	if weapon_lock != null and is_instance_valid(weapon_lock) and weapon_lock.has_method("get_desired_target"):
		desired_target = weapon_lock.call("get_desired_target") as Node3D

	var aim_direction := compute_aim_direction(
		plane,
		desired_target,
		bullet_speed,
		lead_cone_half_angle_deg
	)

	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		var spawner := get_tree().current_scene
		if spawner.has_method("sv_request_fire_autocannon"):
			spawner.sv_request_fire_autocannon.rpc_id(1, multiplayer.get_unique_id())
		else:
			_fire_local(plane, aim_direction)
	elif multiplayer.multiplayer_peer != null and multiplayer.is_server():
		var spawner := get_tree().current_scene
		if spawner.has_method("_server_fire_autocannon"):
			spawner.call("_server_fire_autocannon", plane, multiplayer.get_unique_id())
		else:
			_fire_local(plane, aim_direction)
	else:
		_fire_local(plane, aim_direction)

	_cooldown_remaining = fire_cooldown


func _fire_local(plane: Node3D, aim_direction: Vector3) -> void:
	var bullet := BULLET_SCENE.instantiate() as RigidBody3D
	if "shooter" in bullet:
		bullet.set("shooter", plane)
	if "damage" in bullet:
		bullet.set("damage", damage)
	_projectiles_container.add_child(bullet)
	var inherited_velocity := Vector3.ZERO
	if plane is RigidBody3D:
		inherited_velocity = (plane as RigidBody3D).linear_velocity
	var launch_velocity := aim_direction * bullet_speed + inherited_velocity
	if bullet.has_method("initialize_launch"):
		bullet.call("initialize_launch", plane.global_position, launch_velocity)
	else:
		bullet.global_position = plane.global_position
		bullet.look_at(plane.global_position + aim_direction, Vector3.UP)
		bullet.linear_velocity = launch_velocity


static func compute_aim_direction(
	plane: Node3D,
	target: Node3D,
	projectile_speed: float,
	lead_cone_limit_deg: float
) -> Vector3:
	var nose := -plane.global_transform.basis.z
	if target == null or not is_instance_valid(target):
		return nose

	var target_velocity := Vector3.ZERO
	if target is RigidBody3D:
		target_velocity = (target as RigidBody3D).linear_velocity

	var plane_velocity := Vector3.ZERO
	if plane is RigidBody3D:
		plane_velocity = (plane as RigidBody3D).linear_velocity

	var relative_position := target.global_position - plane.global_position
	var relative_velocity := target_velocity - plane_velocity
	var raw_direction := _compute_intercept_direction(
		plane.global_position,
		target.global_position,
		relative_position,
		relative_velocity,
		projectile_speed
	)
	return _clamp_direction_to_cone(nose, raw_direction, lead_cone_limit_deg)


static func _compute_intercept_direction(
	plane_position: Vector3,
	target_position: Vector3,
	relative_position: Vector3,
	relative_velocity: Vector3,
	projectile_speed: float
) -> Vector3:
	var aim_position := target_position
	var speed_sq := projectile_speed * projectile_speed
	var a := speed_sq - relative_velocity.length_squared()
	var b := -2.0 * relative_position.dot(relative_velocity)
	var c := -relative_position.length_squared()
	var discriminant := b * b - 4.0 * a * c

	if absf(a) > 0.0001 and discriminant >= 0.0:
		var sqrt_discriminant := sqrt(discriminant)
		var t0 := (-b - sqrt_discriminant) / (2.0 * a)
		var t1 := (-b + sqrt_discriminant) / (2.0 * a)
		var intercept_time := INF
		if t0 > 0.0:
			intercept_time = t0
		if t1 > 0.0:
			intercept_time = minf(intercept_time, t1)
		if is_finite(intercept_time):
			aim_position = target_position + relative_velocity * intercept_time

	var direction := aim_position - plane_position
	if direction.length_squared() <= 0.000001:
		return Vector3.FORWARD
	return direction.normalized()


static func _clamp_direction_to_cone(
	nose: Vector3,
	raw_direction: Vector3,
	lead_cone_limit_deg: float
) -> Vector3:
	var normalized_nose := nose.normalized()
	var normalized_direction := raw_direction.normalized()
	var max_angle := deg_to_rad(lead_cone_limit_deg)
	var angle := normalized_nose.angle_to(normalized_direction)
	if angle <= max_angle:
		return normalized_direction

	var axis := normalized_nose.cross(normalized_direction)
	if axis.length_squared() <= 0.000001:
		return normalized_nose
	return normalized_nose.rotated(axis.normalized(), max_angle).normalized()


func _is_local_player(plane: Node3D) -> bool:
	var lp: Variant = plane.get("is_local_player")
	if lp != null:
		return bool(lp)
	return true
